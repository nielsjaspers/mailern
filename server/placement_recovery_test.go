package main

import (
	"net"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/emersion/go-imap/v2"
	"github.com/emersion/go-imap/v2/imapclient"
	"github.com/emersion/go-imap/v2/imapserver"
)

func TestRestoreWithIndependentInboxAndTrashCopies(t *testing.T) {
	h := newHarness(t)
	const subject = "Two copies of a garden plan"
	raw := LabMessage("sam@example.com", labAddress, subject, "Hello.", "", time.Now())
	if err := h.lab.Deliver(labAddress, "INBOX", raw); err != nil {
		t.Fatal(err)
	}
	h.sync()
	h.set(h.conversations()[subject], func(s *ConversationState) { s.Removal = RoleTrash })
	if err := h.lab.Deliver(labAddress, "Trash", raw, imap.FlagSeen); err != nil {
		t.Fatal(err)
	}
	h.sync()
	thread := h.conversations()[subject]
	if thread.Removal != RoleTrash || thread.Workflow != WorkflowInbox {
		t.Fatalf("expected a trashed conversation with an Inbox workflow, got %+v", thread)
	}
	h.set(thread, func(s *ConversationState) { s.Removal = "" })
	h.sync()
	if len(h.mailbox("INBOX")) != 1 || !slices.Contains(h.mailbox("Trash")[subject], imap.FlagSeen) {
		t.Fatal("restore should preserve both existing copies")
	}
	restored := h.conversations()[subject]
	if !restored.Unread {
		t.Fatal("restored thread should show the unread Inbox copy")
	}
	h.set(restored, func(s *ConversationState) { s.Pinned = true })
	h.sync()
	if !slices.Contains(h.mailbox("INBOX")[subject], imap.FlagFlagged) || slices.Contains(h.mailbox("Trash")[subject], imap.FlagFlagged) {
		t.Fatal("pin should affect only the restored Inbox copy")
	}
	restartCopyMoveAccount(t, h)
	h.sync()
	checkReconciledPlacement(t, h, thread.ID, "")
}

func TestPlacementSurvivesUnconfirmedTrashCopy(t *testing.T) {
	for _, scenario := range []struct {
		name           string
		target         Role
		independent    bool
		wantInboxCount int
		wantCopies     int32
	}{
		{"Restore", "", false, 1, 1},
		{"Retarget to Junk", RoleJunk, false, 0, 2},
		{"Retarget to existing Junk", RoleJunk, true, 1, 1},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			h := newHarness(t)
			copies := serveCopyMoveProvider(t, h, loseCopyResponse)
			const subject = "Keep the requested placement"
			raw := LabMessage("sam@example.com", labAddress, subject, "Hello.", "", time.Now())
			if err := h.lab.Deliver(labAddress, "INBOX", raw); err != nil {
				t.Fatal(err)
			}
			h.sync()
			h.set(h.conversations()[subject], func(s *ConversationState) { s.Removal = RoleTrash })
			if err := h.account.Sync(); err == nil || len(h.mailbox("Trash")) != 1 {
				t.Fatalf("expected the provider to drop the response after copying to Trash, got %v", err)
			}
			if scenario.independent {
				if err := h.lab.Deliver(labAddress, "Junk", raw, imap.FlagFlagged); err != nil {
					t.Fatal(err)
				}
			}
			thread := h.conversations()[subject]
			h.set(thread, func(s *ConversationState) { s.Removal = scenario.target })
			h.sync()
			checkReconciledPlacement(t, h, thread.ID, scenario.target)
			restartCopyMoveAccount(t, h)
			h.sync()
			checkReconciledPlacement(t, h, thread.ID, scenario.target)
			if len(h.mailbox("Trash")) != 1 {
				t.Fatal("the unconfirmed Trash copy should survive")
			}
			if inbox := h.mailbox("INBOX"); len(inbox) != scenario.wantInboxCount || copies.Load() != scenario.wantCopies {
				t.Fatalf("unexpected Inbox %v after %d COPY commands", inbox, copies.Load())
			}
			if scenario.target == RoleJunk {
				junk := h.mailbox("Junk")
				if len(junk) != 1 || slices.Contains(junk[subject], imap.FlagFlagged) != scenario.independent {
					t.Fatalf("expected the requested Junk copy, got %v", junk)
				}
			}
		})
	}
}

func checkReconciledPlacement(t *testing.T, h *harness, id string, removal Role) {
	t.Helper()
	h.account.store.Read(func(st *State) {
		c := st.Conversations[id]
		if c == nil || c.Pending || c.Removal != removal || c.Workflow != WorkflowInbox || len(c.Keys) != 1 {
			t.Fatalf("expected reconciliation to keep Inbox workflow and removal %q, got %+v", removal, c)
		}
		m := st.account(c.AccountID).Messages[c.Keys[0]]
		if m == nil {
			t.Fatal("reconciled message is missing")
		}
		if m.PendingMove != nil {
			t.Fatalf("placement left an unfinished COPY: %+v", m.PendingMove)
		}
	})
}

type recoverySelectProvider struct {
	copyMoveProvider
	denySource *atomic.Bool
}

func (s recoverySelectProvider) Select(name string, opts *imap.SelectOptions) (*imap.SelectData, error) {
	if name == "Private folder" || name == "INBOX" && !opts.ReadOnly && s.denySource.Load() {
		return nil, &imap.Error{Type: imap.StatusResponseTypeNo, Text: "test mailbox inaccessible"}
	}
	return s.Session.Select(name, opts)
}

func TestUndoRecoversFlagsWhenUnrelatedFolderRejectsSelect(t *testing.T) {
	h := newHarness(t)
	if err := h.lab.users[labAddress].Create("Private folder", nil); err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	var fault, copies atomic.Int32
	var denySource atomic.Bool
	fault.Store(loseDeletedStoreResponse)
	server := imapserver.New(&imapserver.Options{
		Caps: imap.CapSet{imap.CapIMAP4rev1: {}, imap.CapUIDPlus: {}}, InsecureAuth: true, Logger: quietLogger{},
		NewSession: func(conn *imapserver.Conn) (imapserver.Session, *imapserver.GreetingData, error) {
			return recoverySelectProvider{copyMoveProvider{h.lab.imap.NewSession(), conn.NetConn(), &fault, &copies}, &denySource}, nil, nil
		},
	})
	go server.Serve(listener)
	t.Cleanup(func() { server.Close() })
	h.lab.IMAP = endpointFor(listener)
	h.account.cfg.IMAP = &h.lab.IMAP

	const subject = "Undo an interrupted move"
	h.deliver("INBOX", subject, "")
	h.sync()
	h.set(h.conversations()[subject], func(s *ConversationState) { s.Removal = RoleTrash })
	if err := h.account.Sync(); err == nil || !slices.Contains(h.mailbox("INBOX")[subject], imap.FlagDeleted) {
		t.Fatalf("expected the provider to drop the response after marking Inbox mail deleted, got %v", err)
	}
	h.set(h.conversations()[subject], func(s *ConversationState) { s.Removal = "" })
	denySource.Store(true)
	if err := h.account.Sync(); err == nil || !strings.Contains(err.Error(), "recover delete flags in INBOX") {
		t.Fatalf("an inaccessible source should block recovery, got %v", err)
	}
	denySource.Store(false)
	restartCopyMoveAccount(t, h)
	h.sync()
	if flags, ok := h.mailbox("INBOX")[subject]; !ok || slices.Contains(flags, imap.FlagDeleted) || len(h.mailbox("Trash")) != 0 {
		t.Fatalf("undo should recover the original and remove its confirmed copy, got Inbox flags %v", flags)
	}
	h.account.store.Read(func(st *State) {
		if st.account(h.account.cfg.ID).OwnedDeleted != nil {
			t.Fatal("undo left the interrupted delete in the journal")
		}
	})
}

func TestRestoreSettledWithIndependentInboxCopy(t *testing.T) {
	h := newHarness(t)
	const subject = "Settled with a second copy"
	raw := LabMessage("sam@example.com", labAddress, subject, "Hello.", "", time.Now())
	if err := h.lab.Deliver(labAddress, "Archive", raw); err != nil {
		t.Fatal(err)
	}
	h.sync()
	h.set(h.conversations()[subject], func(s *ConversationState) { s.Removal = RoleTrash })
	h.sync()
	if err := h.lab.Deliver(labAddress, "INBOX", raw); err != nil {
		t.Fatal(err)
	}
	h.sync()
	source := h.conversations()[subject]
	h.set(source, func(s *ConversationState) { s.Removal = "" })
	h.sync()
	restartCopyMoveAccount(t, h)
	h.sync()
	h.account.store.Read(func(st *State) {
		thread := st.Conversations[source.ID]
		if thread == nil || thread.Removal != "" || thread.Workflow != WorkflowSettled || thread.Unread {
			t.Fatalf("settled restore lost its archive placement: %+v", thread)
		}
	})
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

func TestRetargetFlagsOnlyTheJunkCopy(t *testing.T) {
	for _, fault := range []int32{loseCopyResponse, loseDeletedStoreResponse} {
		h := newHarness(t)
		serveCopyMoveProvider(t, h, fault)
		const subject = "Interrupted restore"
		raw := LabMessage("sam@example.com", labAddress, subject, "Hello.", "", time.Now())
		if err := h.lab.Deliver(labAddress, "Trash", raw); err != nil {
			t.Fatal(err)
		}
		h.sync()
		h.set(h.conversations()[subject], func(s *ConversationState) { s.Removal = "" })
		if err := h.account.Sync(); err == nil {
			t.Fatal("expected interrupted restore")
		}
		if err := h.lab.Deliver(labAddress, "Junk", raw); err != nil {
			t.Fatal(err)
		}
		thread := h.conversations()[subject]
		update := ConversationState{Workflow: thread.Workflow, Removal: RoleJunk, Pinned: true, Fields: []string{"removal", "unread", "pinned"}}
		if code := h.request("PUT", "/v1/conversations/"+thread.ID, update, nil); code != 200 {
			t.Fatalf("retarget returned %d", code)
		}
		h.sync()
		for _, flag := range []imap.Flag{imap.FlagSeen, imap.FlagFlagged} {
			if !slices.Contains(h.mailbox("Junk")[subject], flag) || slices.Contains(h.mailbox("Trash")[subject], flag) {
				t.Fatalf("flag %s: Trash %v Junk %v conversation %+v", flag, h.mailbox("Trash"), h.mailbox("Junk"), h.conversations()[subject])
			}
		}
	}
}

func TestRestoredSentCopyReceivesPin(t *testing.T) {
	h := newHarness(t)
	const subject = "Outgoing with an archive copy"
	raw := LabMessage(labAddress, "sam@example.com", subject, "Hello.", "", time.Now())
	for _, name := range []string{"Sent", "Archive"} {
		if err := h.lab.Deliver(labAddress, name, raw); err != nil {
			t.Fatal(err)
		}
	}
	h.sync()
	thread := h.conversations()[subject]
	h.set(thread, func(s *ConversationState) { s.Removal = RoleTrash })
	h.sync()
	h.set(h.conversations()[subject], func(s *ConversationState) { s.Removal = "" })
	h.sync()
	restartCopyMoveAccount(t, h)
	h.service.store, h.service.accounts = h.account.store, []*Account{h.account}
	h.set(h.conversations()[subject], func(s *ConversationState) { s.Pinned = true })
	h.sync()
	if !slices.Contains(h.mailbox("Sent")[subject], imap.FlagFlagged) || slices.Contains(h.mailbox("Archive")[subject], imap.FlagFlagged) {
		t.Fatal("expected Pin on the restored Sent copy only")
	}
}

func TestUIDPlusRestoreFromJunkWithTrashAndInboxCopies(t *testing.T) {
	h := newHarness(t)
	serveCopyMoveProvider(t, h, 0)
	const subject = "Restore from Junk"
	raw := LabMessage("sam@example.com", labAddress, subject, "Hello.", "", time.Now())
	if err := h.lab.Deliver(labAddress, "Junk", raw); err != nil {
		t.Fatal(err)
	}
	h.sync()
	for _, name := range []string{"INBOX", "Trash"} {
		if err := h.lab.Deliver(labAddress, name, raw); err != nil {
			t.Fatal(err)
		}
	}
	h.sync()
	thread := h.conversations()[subject]
	if thread.Removal != RoleJunk || thread.Workflow != WorkflowSettled {
		t.Fatal("expected a settled Junk thread")
	}
	h.set(thread, func(s *ConversationState) { s.Removal = "" })
	restartCopyMoveAccount(t, h)
	h.sync()
	if len(h.mailbox("Junk")) != 0 || len(h.mailbox("Archive")) != 1 || len(h.mailbox("Trash")) != 1 || len(h.mailbox("INBOX")) != 1 {
		t.Fatal("restore should move only the Junk UID to Archive")
	}
}

func TestSettleAfterUndoOfLostArchiveCopy(t *testing.T) {
	h := newHarness(t)
	copies := serveCopyMoveProvider(t, h, loseCopyResponse)
	const subject = "Settle after Undo"
	h.deliver("INBOX", subject, "")
	h.sync()
	setWorkflow := func(workflow Workflow) {
		h.set(h.conversations()[subject], func(s *ConversationState) { s.Workflow = workflow })
	}
	setWorkflow(WorkflowSettled)
	if err := h.account.Sync(); err == nil {
		t.Fatal("expected lost Archive COPY response")
	}
	setWorkflow(WorkflowInbox)
	h.sync()
	setWorkflow(WorkflowSettled)
	h.sync()
	if len(h.mailbox("INBOX")) != 0 || len(h.mailbox("Archive")) != 1 || copies.Load() != 1 || h.conversations()[subject].Workflow != WorkflowSettled {
		t.Fatal("second Settle must remove the Inbox source and reuse the verified Archive copy")
	}
}

func (h *harness) count(mailbox string) uint32 {
	h.t.Helper()
	c, err := imapclient.DialInsecure(h.lab.IMAP.Address(), nil)
	if err != nil {
		h.t.Fatal(err)
	}
	defer c.Close()
	if err := c.Login(labAddress, "lab").Wait(); err != nil {
		h.t.Fatal(err)
	}
	status, err := c.Status(mailbox, &imap.StatusOptions{NumMessages: true}).Wait()
	if err != nil {
		h.t.Fatal(err)
	}
	return *status.NumMessages
}

func TestResettleAfterLostCopyKeepsNewPin(t *testing.T) {
	h := newHarness(t)
	serveCopyMoveProvider(t, h, loseCopyResponse)
	const subject = "Pin before Settle"
	h.deliver("INBOX", subject, "")
	h.sync()
	set := func(change func(*ConversationState)) { h.set(h.conversations()[subject], change) }
	set(func(s *ConversationState) { s.Workflow = WorkflowSettled })
	if err := h.account.Sync(); err == nil {
		t.Fatal("expected lost Archive COPY response")
	}
	set(func(s *ConversationState) { s.Workflow = WorkflowInbox })
	h.sync()
	set(func(s *ConversationState) { s.Pinned = true })
	h.sync()
	set(func(s *ConversationState) { s.Workflow = WorkflowSettled })
	h.sync()
	restartCopyMoveAccount(t, h)
	h.sync()
	if !slices.Contains(h.mailbox("Archive")[subject], imap.FlagFlagged) || !h.conversations()[subject].Pinned {
		t.Fatal("the reused Archive copy must take the pin set after Undo")
	}
}

func TestNativeMoveReusesExistingArchiveCopy(t *testing.T) {
	h := newHarness(t)
	const subject = "Copy in Inbox and Archive"
	raw := LabMessage("sam@example.com", labAddress, subject, "Hello.", "", time.Now())
	for _, mailbox := range []string{"INBOX", "Archive"} {
		if err := h.lab.Deliver(labAddress, mailbox, raw); err != nil {
			t.Fatal(err)
		}
	}
	h.sync()
	h.set(h.conversations()[subject], func(s *ConversationState) { s.Workflow = WorkflowSettled })
	h.sync()
	if h.count("INBOX") != 0 || h.count("Archive") != 1 {
		t.Fatalf("Settle must leave one Archive copy: Inbox %d, Archive %d", h.count("INBOX"), h.count("Archive"))
	}
}
