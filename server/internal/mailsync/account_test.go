package mailsync

import (
	"fmt"
	"net"
	"net/http"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/emersion/go-imap/v2"
	"github.com/emersion/go-imap/v2/imapserver"
	"github.com/nielsjaspers/mailern/server/internal/maillab"
)

func TestSyncPersistsMailboxIdentityChangesWithoutConversationChanges(t *testing.T) {
	h := newHarness(t)
	h.deliver("INBOX", "Unchanged Inbox mail", "")
	h.sync()
	var before syncResponse
	h.request("GET", "/v1/sync?since=0", nil, &before)
	oldToken := before.Accounts[0].MailboxIdentities[RoleTrash]
	if oldToken == "" {
		t.Fatal("expected the original Trash identity")
	}
	if err := h.lab.User(labAddress).Create("New Trash", nil); err != nil {
		t.Fatal(err)
	}
	h.account.cfg.Mailboxes = map[Role]string{RoleTrash: "New Trash"}
	h.sync()
	var after syncResponse
	h.request("GET", fmt.Sprintf("/v1/sync?since=%d", before.Revision), nil, &after)
	newToken := after.Accounts[0].MailboxIdentities[RoleTrash]
	if newToken == "" || newToken == oldToken || len(after.Conversations) != 0 || len(after.Deleted) != 0 {
		t.Fatalf("expected only a Trash identity change, got %+v", after)
	}
	reopened, err := OpenStore(h.account.store.path)
	if err != nil {
		t.Fatal(err)
	}
	reopened.Read(func(st *State) {
		identity := identityFor(st.account(h.account.cfg.ID), RoleTrash)
		if st.Revision <= before.Revision || st.Revision != after.Revision || mailboxToken(identity) != newToken {
			t.Errorf("Trash identity change did not reach disk: revision %d, identity %+v", st.Revision, identity)
		}
	})
	h.sync()
	var unchanged syncResponse
	h.request("GET", fmt.Sprintf("/v1/sync?since=%d", after.Revision), nil, &unchanged)
	if unchanged.Revision != after.Revision {
		t.Fatalf("unchanged scan advanced revision from %d to %d", after.Revision, unchanged.Revision)
	}
}

func TestAccountCacheBelongsToTheConfiguredIMAPLogin(t *testing.T) {
	for _, change := range []string{"login", "endpoint"} {
		t.Run(change, func(t *testing.T) {
			h := newHarness(t)
			cfg := h.account.cfg
			configure := func() {
				t.Helper()
				if err := h.account.store.Update(func(st *State) error {
					st.configureAccounts([]AccountConfig{cfg})
					return nil
				}); err != nil {
					t.Fatal(err)
				}
			}
			configure()
			h.deliver("INBOX", "Original mailbox", "")
			h.sync()
			if len(h.conversations()) != 1 {
				t.Fatal("expected cached mail")
			}
			switch change {
			case "login":
				cfg.Username = "other@example.com"
			case "endpoint":
				endpoint := *cfg.IMAP
				endpoint.Port++
				cfg.IMAP = &endpoint
			}
			configure()
			if len(h.conversations()) != 0 {
				t.Fatal("old mailbox remained visible")
			}
		})
	}
}

// bodyCounter counts the message bodies a client downloads.
type bodyCounter struct {
	imapserver.Session
	bodies *atomic.Int32
}

func (s bodyCounter) Fetch(w *imapserver.FetchWriter, set imap.NumSet, options *imap.FetchOptions) error {
	if len(options.BodySection) > 0 {
		if uids, ok := set.(imap.UIDSet); ok {
			if nums, ok := uids.Nums(); ok {
				s.bodies.Add(int32(len(nums)))
			}
		}
	}
	return s.Session.Fetch(w, set, options)
}

func TestMessageInTwoMailboxesDownloadsOnce(t *testing.T) {
	h := newHarness(t)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	var bodies atomic.Int32
	server := imapserver.New(&imapserver.Options{
		Caps: imap.CapSet{imap.CapIMAP4rev1: {}, imap.CapUIDPlus: {}}, InsecureAuth: true, Logger: maillab.QuietLogger{},
		NewSession: func(*imapserver.Conn) (imapserver.Session, *imapserver.GreetingData, error) {
			return bodyCounter{h.lab.NewSession(), &bodies}, nil, nil
		},
	})
	go server.Serve(listener)
	t.Cleanup(func() { server.Close() })
	h.imap = endpointFor(listener)
	h.account.cfg.IMAP = &h.imap
	// Gmail lists an inbox message in All Mail too.
	raw := maillab.Message("Sam <sam@example.com>", labAddress, "Dinner", "Saturday?", "", time.Now())
	for _, mailbox := range []string{"INBOX", "Archive"} {
		if err := h.lab.Deliver(labAddress, mailbox, raw); err != nil {
			t.Fatal(err)
		}
	}
	h.sync()
	if got := bodies.Load(); got != 1 {
		t.Fatalf("one message in two mailboxes should download once, downloaded %d times", got)
	}
	if c := h.conversations()["Dinner"]; len(c.Messages) != 1 || c.Workflow != WorkflowInbox {
		t.Fatalf("the message should sync once, in Inbox: %+v", c)
	}
}

func TestGmailArchiveLabelDoesNotReplaceAllMail(t *testing.T) {
	// Gmail's mailboxes, plus a user label someone named Archive.
	list := []*imap.ListData{
		{Mailbox: "INBOX"},
		{Mailbox: "Archive"},
		{Mailbox: "[Gmail]/All Mail", Attrs: []imap.MailboxAttr{imap.MailboxAttrAll}},
		{Mailbox: "[Gmail]/Sent Mail", Attrs: []imap.MailboxAttr{imap.MailboxAttrSent}},
	}
	found, archiveIsAll := chooseMailboxes(list, true, nil)
	if found[RoleArchive] != "[Gmail]/All Mail" || !archiveIsAll {
		t.Fatalf("Gmail's archive must be All Mail, got %q (all mail %v)", found[RoleArchive], archiveIsAll)
	}
	// Elsewhere, such as Proton Mail Bridge, a mailbox named Archive is the archive.
	found, archiveIsAll = chooseMailboxes(list, false, nil)
	if found[RoleArchive] != "Archive" || archiveIsAll {
		t.Fatalf("outside Gmail the Archive mailbox should win, got %q", found[RoleArchive])
	}
	// A configured name always wins.
	found, _ = chooseMailboxes(list, true, map[Role]string{RoleArchive: "Archive"})
	if found[RoleArchive] != "Archive" {
		t.Fatalf("a configured archive must win, got %q", found[RoleArchive])
	}
}

type refuseSentHeaderSearch struct {
	imapserver.SessionIMAP4rev2
	selected string
	refusals *atomic.Int32
}

func (s *refuseSentHeaderSearch) Select(name string, options *imap.SelectOptions) (*imap.SelectData, error) {
	s.selected = name
	return s.SessionIMAP4rev2.Select(name, options)
}

func (s *refuseSentHeaderSearch) Search(kind imapserver.NumKind, criteria *imap.SearchCriteria, options *imap.SearchOptions) (*imap.SearchData, error) {
	if s.selected == "Sent" && len(criteria.Header) != 0 {
		s.refusals.Add(1)
		return nil, &imap.Error{Type: imap.StatusResponseTypeNo, Text: "Header search unavailable"}
	}
	return s.SessionIMAP4rev2.Search(kind, criteria, options)
}

func TestSentHeaderSearchRefusalAllowsInboxSync(t *testing.T) {
	h := newHarness(t)
	var refusals atomic.Int32
	serveProvider(t, h, imap.CapSet{imap.CapIMAP4rev1: {}, imap.CapIMAP4rev2: {}}, func(s imapserver.Session) imapserver.Session {
		return &refuseSentHeaderSearch{SessionIMAP4rev2: s.(imapserver.SessionIMAP4rev2), refusals: &refusals}
	})
	h.deliver("Sent", "Cached sent", "")
	h.deliver("INBOX", "To archive", "")
	h.sync()
	h.set(h.conversations()["To archive"], func(s *ConversationState) { s.Workflow = WorkflowSettled })
	h.sync()
	h.deliver("INBOX", "Later delivery", "")
	h.sync()
	got := h.conversations()
	if refusals.Load() == 0 || got["Cached sent"].ID == "" || got["Later delivery"].ID == "" || got["To archive"].Workflow != WorkflowSettled {
		t.Fatal("expected Inbox, cached Sent, and archived mail after the refused recovery search")
	}
}

func TestProviderTracksOldMailMovedAcrossCutoff(t *testing.T) {
	for _, external := range []bool{false, true} {
		name := "Mailern"
		if external {
			name = "other client"
		}
		t.Run(name, func(t *testing.T) {
			h := newHarness(t)
			appendOldProviderMail(t, h, "INBOX", "Old inbox mail")
			appendOldProviderMail(t, h, "Archive", "Untracked old archive mail")
			h.sync()
			thread := h.conversations()["Old inbox mail"]
			if external {
				c, err := h.account.dial()
				if err != nil {
					t.Fatal(err)
				}
				defer c.Close()
				if _, err := c.Select("INBOX", nil).Wait(); err != nil {
					t.Fatal(err)
				}
				if _, err := c.Move(imap.SeqSetNum(1), "Archive").Wait(); err != nil {
					t.Fatal(err)
				}
			} else {
				h.set(thread, func(s *ConversationState) { s.Workflow, s.Unread = WorkflowSettled, false })
			}
			h.sync()
			got := h.conversations()
			if c := got[thread.Subject]; c.ID != thread.ID || c.Workflow != WorkflowSettled {
				t.Fatalf("old mail lost its thread after the move: %+v", c)
			}
			if _, ok := got["Untracked old archive mail"]; ok {
				t.Fatal("discovered unrelated mail older than the cutoff")
			}
			h.set(got[thread.Subject], func(s *ConversationState) { s.Workflow = WorkflowInbox })
			h.sync()
			if len(h.mailbox("INBOX")) != 1 || h.conversations()[thread.Subject].ID != thread.ID {
				t.Fatal("old archived mail could not be restored")
			}
		})
	}
}

func TestProviderDiscoveryAndSyncArchiveCreation(t *testing.T) {
	for _, special := range []bool{false, true} {
		name := "plain CREATE"
		if special {
			name = "CREATE with USE"
		}
		t.Run(name, func(t *testing.T) {
			h := newHarness(t)
			if err := h.lab.User(labAddress).Delete("Archive"); err != nil {
				t.Fatal(err)
			}
			caps := imap.CapSet{imap.CapIMAP4rev1: {}}
			if special {
				caps[imap.CapCreateSpecialUse] = struct{}{}
				caps[imap.CapSpecialUse] = struct{}{}
				caps[imap.CapListExtended] = struct{}{}
			}
			creates := make(chan []imap.MailboxAttr, 2)
			serveProvider(t, h, caps, func(s imapserver.Session) imapserver.Session {
				return createRecordingSession{s, creates}
			})
			c, err := h.account.dial()
			if err != nil {
				t.Fatal(err)
			}
			defer c.Close()
			found, _, err := h.account.discover(c)
			if err != nil || found[RoleArchive] != "" {
				t.Fatalf("read-only discover should leave Archive missing, got %v, %v", found, err)
			}
			h.sync()
			found, _, err = h.account.discover(c)
			if err != nil || found[RoleArchive] != "Archive" {
				t.Fatalf("sync should create Archive, got %v, %v", found, err)
			}
			select {
			case attrs := <-creates:
				if slices.Contains(attrs, imap.MailboxAttrArchive) != special {
					t.Fatalf("Archive USE flag should match CREATE-SPECIAL-USE support, got %v", attrs)
				}
			default:
				t.Fatal("sync sent no CREATE")
			}
		})
	}
}

type createRecordingSession struct {
	imapserver.Session
	creates chan<- []imap.MailboxAttr
}

func (s createRecordingSession) Create(name string, options *imap.CreateOptions) error {
	s.creates <- options.SpecialUse
	return s.Session.Create(name, options)
}

type staleUIDSession struct {
	imapserver.SessionIMAP4rev2
}

func (s staleUIDSession) Select(name string, options *imap.SelectOptions) (*imap.SelectData, error) {
	data, err := s.SessionIMAP4rev2.Select(name, options)
	if err == nil && !options.ReadOnly {
		data.UIDValidity++
	}
	return data, err
}

func TestProviderValidatesUIDsBeforeWriting(t *testing.T) {
	for _, write := range []string{"flag", "move", "delete"} {
		t.Run(write, func(t *testing.T) {
			h := newHarness(t)
			serveProvider(t, h, imap.CapSet{imap.CapIMAP4rev1: {}, imap.CapIMAP4rev2: {}},
				func(s imapserver.Session) imapserver.Session {
					return staleUIDSession{s.(imapserver.SessionIMAP4rev2)}
				})
			mailbox := "INBOX"
			if write == "delete" {
				mailbox = "Trash"
			}
			h.deliver(mailbox, "Keep after UID reset", "")
			h.sync()
			c := h.conversations()["Keep after UID reset"]
			switch write {
			case "flag":
				h.set(c, func(s *ConversationState) { s.Pinned = true })
			case "move":
				h.set(c, func(s *ConversationState) { s.Removal = RoleTrash })
			case "delete":
				if code := h.delete(c, c.Removal); code != http.StatusNoContent {
					t.Fatalf("delete: %d", code)
				}
			}
			err := h.account.Sync()
			if err == nil || !strings.Contains(err.Error(), "UIDVALIDITY changed") {
				t.Fatalf("expected stale-UID error, got %v", err)
			}
			if flags, ok := h.mailbox(mailbox)[c.Subject]; !ok || len(flags) != 0 {
				t.Fatalf("stale-UID write touched the message: present=%v, flags=%v", ok, flags)
			}
		})
	}
}

func TestAddedAliasReclassifiesStoredMail(t *testing.T) {
	h := newHarness(t)
	const alias = "morgan@alias.example.com"
	raw := maillab.Message("Morgan <"+alias+">", "sam@example.com", "Sent elsewhere", "Hi.", "", time.Now())
	if err := h.lab.Deliver(labAddress, "Sent", raw, imap.FlagSeen); err != nil {
		t.Fatal(err)
	}
	h.sync()
	if h.conversations()["Sent elsewhere"].Messages[0].Outgoing {
		t.Fatal("without the alias, the message is incoming")
	}
	h.account.cfg.Aliases = []string{alias}
	h.sync()
	if !h.conversations()["Sent elsewhere"].Messages[0].Outgoing {
		t.Fatal("after adding the alias, stored mail from it should be outgoing")
	}
}

func TestRemovedAliasKeepsSentMailOutgoing(t *testing.T) {
	h := newHarness(t)
	const alias = "morgan@alias.example.com"
	h.account.cfg.Aliases = []string{alias}
	raw := maillab.Message("Morgan <"+alias+">", "sam@example.com", "Sent as alias", "Hi.", "", time.Now())
	if err := h.lab.Deliver(labAddress, "Sent", raw, imap.FlagSeen); err != nil {
		t.Fatal(err)
	}
	h.sync()
	h.account.cfg.Aliases = nil
	h.sync()
	if !h.conversations()["Sent as alias"].Messages[0].Outgoing {
		t.Fatal("removing an alias must not turn mail sent from it into incoming mail")
	}
}

func TestReplyDatedBeforeItsParentJoinsTheThread(t *testing.T) {
	h := newHarness(t)
	now := time.Now()
	parent := maillab.Message("Sam <sam@example.com>", labAddress, "Plans", "Free Friday?", "", now)
	reply := maillab.Message("Alex <alex@example.com>", labAddress, "Re: Plans", "Yes.", maillab.MessageID(parent), now.Add(-2*time.Minute))
	for _, raw := range [][]byte{parent, reply} {
		if err := h.lab.Deliver(labAddress, "INBOX", raw); err != nil {
			t.Fatal(err)
		}
	}
	h.sync()
	if c := h.conversations()["Plans"]; len(c.Messages) != 2 {
		t.Fatalf("a reply with an earlier date should join its parent, got %d messages", len(c.Messages))
	}
}

func TestDeletedFlagChangeReachesIncrementalSync(t *testing.T) {
	h := newHarness(t)
	root := h.deliver("INBOX", "Dinner", "")
	h.deliver("INBOX", "Re: Dinner", root)
	h.sync()
	var before syncResponse
	h.request("GET", "/v1/sync?since=0", nil, &before)
	markSeen(t, h, "INBOX", "Re: Dinner", imap.FlagDeleted)
	h.sync()
	var after syncResponse
	h.request("GET", fmt.Sprintf("/v1/sync?since=%d", before.Revision), nil, &after)
	if len(after.Conversations) != 1 {
		t.Fatalf("a change to the deleted flag should reach incremental sync, got %d conversations", len(after.Conversations))
	}
}

type beforeSelectSession struct {
	imapserver.SessionIMAP4rev2
	beforeSelect func(string, bool) error
}

func (s beforeSelectSession) Select(name string, options *imap.SelectOptions) (*imap.SelectData, error) {
	if err := s.beforeSelect(name, options.ReadOnly); err != nil {
		return nil, err
	}
	return s.SessionIMAP4rev2.Select(name, options)
}

func interleaveProviderMove(t *testing.T, h *harness, source string, seq uint32, readOnly bool) *atomic.Bool {
	t.Helper()
	other, err := h.account.dial()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { other.Close() })
	armed := &atomic.Bool{}
	serveProvider(t, h, imap.CapSet{imap.CapIMAP4rev1: {}, imap.CapIMAP4rev2: {}}, func(s imapserver.Session) imapserver.Session {
		return beforeSelectSession{s.(imapserver.SessionIMAP4rev2), func(name string, examine bool) error {
			if name != source || examine != readOnly || !armed.CompareAndSwap(true, false) {
				return nil
			}
			if _, err := other.Select(source, nil).Wait(); err != nil {
				return err
			}
			_, err := other.Move(imap.SeqSetNum(seq), "INBOX").Wait()
			return err
		}}
	})
	return armed
}

func TestProviderRecoversMailRestoredAfterInboxScan(t *testing.T) {
	for _, age := range []string{"old", "recent"} {
		t.Run(age, func(t *testing.T) {
			h := newHarness(t)
			const subject = "Mail restored during scan"
			if age == "old" {
				appendOldProviderMail(t, h, "INBOX", subject)
			} else {
				h.deliver("INBOX", subject, "")
			}
			h.sync()
			thread := h.conversations()[subject]
			h.set(thread, func(s *ConversationState) { s.Workflow = WorkflowSettled })
			h.sync()
			h.account.disconnect()
			armed := interleaveProviderMove(t, h, "Archive", 1, true)
			armed.Store(true)
			h.sync()
			if armed.Load() {
				t.Fatal("restore did not interleave with the scan")
			}
			if got := h.conversations()[subject]; got.ID != thread.ID || got.Workflow != WorkflowInbox {
				t.Fatalf("restore should preserve the thread ID and return it to Inbox: %+v", got)
			}
		})
	}
}

type fixedUIDValiditySession struct {
	imapserver.SessionIMAP4rev2
}

func (s fixedUIDValiditySession) Select(name string, options *imap.SelectOptions) (*imap.SelectData, error) {
	data, err := s.SessionIMAP4rev2.Select(name, options)
	if err == nil {
		data.UIDValidity = 42
	}
	return data, err
}

func TestProviderRejectsMailboxNameChangeWithSameUIDValidity(t *testing.T) {
	h := newHarness(t)
	if err := h.lab.User(labAddress).Create("Other Trash", nil); err != nil {
		t.Fatal(err)
	}
	serveProvider(t, h, imap.CapSet{imap.CapIMAP4rev1: {}, imap.CapIMAP4rev2: {}}, func(s imapserver.Session) imapserver.Session {
		return fixedUIDValiditySession{s.(imapserver.SessionIMAP4rev2)}
	})
	h.deliver("Trash", "Confirmed delete", "")
	h.deliver("Other Trash", "Unrelated mail with same UID", "")
	h.sync()
	queueProviderDelete(t, h, h.conversations()["Confirmed delete"].ID)
	var plans []plan
	var identities map[Role]mailboxIdentity
	if err := h.account.store.Update(func(st *State) error {
		plans = h.account.reconcile(st)
		identities = mailboxIdentities(st.account(h.account.cfg.ID))
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	h.account.mailboxes[RoleTrash] = "Other Trash"
	err := h.account.apply(h.account.client, plans, identities)
	if err == nil || !strings.Contains(err.Error(), "mailbox for trash changed") {
		t.Fatalf("expected mailbox name mismatch, got %v", err)
	}
	for mailbox, subject := range map[string]string{"Trash": "Confirmed delete", "Other Trash": "Unrelated mail with same UID"} {
		if flags, ok := h.mailbox(mailbox)[subject]; !ok || len(flags) != 0 {
			t.Fatalf("mismatched mailbox write touched %s: present=%v, flags=%v", mailbox, ok, flags)
		}
	}
}

func TestProviderRecoversRecentMailMovedToMailboxAlreadyScanned(t *testing.T) {
	h := newHarness(t)
	const subject = "Moved to Junk during Trash scan"
	h.deliver("Trash", subject, "")
	other, err := h.account.dial()
	if err != nil {
		t.Fatal(err)
	}
	defer other.Close()
	var armed atomic.Bool
	serveProvider(t, h, imap.CapSet{imap.CapIMAP4rev1: {}, imap.CapIMAP4rev2: {}}, func(s imapserver.Session) imapserver.Session {
		return beforeSelectSession{s.(imapserver.SessionIMAP4rev2), func(name string, readOnly bool) error {
			if name != "Trash" || !readOnly || !armed.CompareAndSwap(true, false) {
				return nil
			}
			if _, err := other.Select("Trash", nil).Wait(); err != nil {
				return err
			}
			_, err := other.Move(imap.UIDSetNum(1), "Junk").Wait()
			return err
		}}
	})
	h.sync()
	thread := h.conversations()[subject]
	armed.Store(true)
	h.sync()
	if got := h.conversations()[subject]; armed.Load() || got.ID != thread.ID || got.Removal != RoleJunk {
		t.Fatalf("expected existing conversation in Junk, got %+v", got)
	}
}

func TestProviderUnreadableSentPreservesCacheAndSyncsInbox(t *testing.T) {
	for _, configured := range []bool{true, false} {
		name := "autodiscovered"
		if configured {
			name = "configured"
		}
		t.Run(name, func(t *testing.T) { checkUnreadableSent(t, configured) })
	}
}

func checkUnreadableSent(t *testing.T, configured bool) {
	h := newHarness(t)
	if configured {
		h.account.cfg.Mailboxes = map[Role]string{RoleSent: "Sent"}
	}
	var unavailable atomic.Bool
	serveProvider(t, h, imap.CapSet{imap.CapIMAP4rev1: {}, imap.CapIMAP4rev2: {}}, func(s imapserver.Session) imapserver.Session {
		return beforeSelectSession{s.(imapserver.SessionIMAP4rev2), func(name string, _ bool) error {
			if strings.EqualFold(name, "Sent") && unavailable.Load() {
				return &imap.Error{Type: imap.StatusResponseTypeNo, Text: "Sent temporarily unavailable"}
			}
			return nil
		}}
	})
	const inbox, sent, trash = "Inbox mail", "Previously cached Sent mail", "Confirmed delete awaiting a complete scan"
	h.deliver("INBOX", inbox, "")
	h.deliver("Sent", sent, "")
	root := h.deliver("Trash", trash, "")
	h.sync()
	initial := h.conversations()
	h.set(initial[inbox], func(s *ConversationState) { s.Pinned = true })
	queueProviderDelete(t, h, initial[trash].ID)
	unavailable.Store(true)
	h.deliver("INBOX", "New incoming mail", "")
	h.deliver("Sent", "Reply outside the partial scan", root)
	h.sync()
	if got := h.conversations(); got["New incoming mail"].ID == "" || got[sent].ID != initial[sent].ID || !slices.Contains(h.mailbox("INBOX")[inbox], imap.FlagFlagged) {
		t.Fatalf("partial scan lost cached mail or missed Inbox changes: %+v", got)
	}
	if _, exists := h.mailbox("Trash")[trash]; !exists {
		t.Fatal("partial scan allowed a permanent delete")
	}
	unavailable.Store(false)
	h.sync()
	got := h.conversations()
	if got[sent].ID != initial[sent].ID || got[trash].ID != initial[trash].ID || len(got[trash].Messages) != 2 {
		t.Fatalf("Sent recovery lost a cached ID or missed the reply: %+v", got)
	}
}

func TestUnreadableSentDuringFlagRecoveryStillPublishesInbox(t *testing.T) {
	h := newHarness(t)
	h.account.cfg.Mailboxes = map[Role]string{RoleSent: "Sent"}
	var unavailable atomic.Bool
	serveProvider(t, h, imap.CapSet{imap.CapIMAP4rev1: {}, imap.CapIMAP4rev2: {}}, func(s imapserver.Session) imapserver.Session {
		return beforeSelectSession{s.(imapserver.SessionIMAP4rev2), func(name string, _ bool) error {
			if name == "Sent" && unavailable.Load() {
				return &imap.Error{Type: imap.StatusResponseTypeNo, Text: "Sent unavailable"}
			}
			return nil
		}}
	})
	h.deliver("Sent", "Interrupted move", "", imap.FlagDeleted)
	h.sync()
	var sent mailboxIdentity
	h.account.store.Read(func(st *State) { sent = identityFor(st.account(h.account.cfg.ID), RoleSent) })
	if err := h.account.saveOwnedDeleted(&deletedFlags{Mailbox: sent.name, Validity: sent.validity, UIDs: imap.UIDSetNum(1)}); err != nil {
		t.Fatal(err)
	}
	unavailable.Store(true)
	h.deliver("INBOX", "New during recovery", "")
	if err := h.account.Sync(); err == nil {
		t.Fatal("expected the pending recovery to report the Sent outage")
	}
	if h.conversations()["New during recovery"].ID == "" {
		t.Fatal("pending flag recovery blocked Inbox")
	}
	unavailable.Store(false)
	h.sync()
	if slices.Contains(h.mailbox("Sent")["Interrupted move"], imap.FlagDeleted) {
		t.Fatal("recovery did not resume when Sent became readable")
	}
}

func TestReconfiguredMailboxDropsOldMailFromSync(t *testing.T) {
	h := newHarness(t)
	h.deliver("INBOX", "Old account", "")
	h.sync()
	var before syncResponse
	h.request("GET", "/v1/sync?since=0", nil, &before)
	id := before.Conversations[0].ID
	err := h.account.store.Update(func(st *State) error {
		st.configureAccounts([]AccountConfig{{ID: "lab", Address: "new@example.com", IMAP: h.account.cfg.IMAP}})
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	var after syncResponse
	h.request("GET", fmt.Sprintf("/v1/sync?since=%d", before.Revision), nil, &after)
	if !slices.Contains(after.Deleted, id) || len(h.conversations()) != 0 {
		t.Fatal("reconfigured mailbox still exposes old mail")
	}
}
