package main

import (
	"bytes"
	"errors"
	"net"
	"net/http"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/emersion/go-imap/v2"
	"github.com/emersion/go-imap/v2/imapserver"
)

func serveProvider(t *testing.T, h *harness, caps imap.CapSet, wrap func(imapserver.Session) imapserver.Session) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	server := imapserver.New(&imapserver.Options{
		Caps: caps, InsecureAuth: true, Logger: quietLogger{},
		NewSession: func(*imapserver.Conn) (imapserver.Session, *imapserver.GreetingData, error) {
			session := h.lab.imap.NewSession()
			if wrap != nil {
				session = wrap(session)
			}
			return session, nil, nil
		},
	})
	go server.Serve(listener)
	t.Cleanup(func() { server.Close() })
	h.lab.IMAP = endpointFor(listener)
	h.account.cfg.IMAP = &h.lab.IMAP
}

func appendOldProviderMail(t *testing.T, h *harness, mailbox, subject string) {
	t.Helper()
	date := time.Now().Add(-200 * 24 * time.Hour)
	raw := LabMessage("sam@example.com", labAddress, subject, "Hello.", "", date)
	if _, err := h.lab.users[labAddress].Append(mailbox, bytes.NewReader(raw), &imap.AppendOptions{Time: date}); err != nil {
		t.Fatal(err)
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

func TestProviderDeleteCancelsWhenThreadChanges(t *testing.T) {
	for _, replyMailbox := range []string{"INBOX", "Trash", "Sent"} {
		t.Run(replyMailbox, func(t *testing.T) {
			h := newHarness(t)
			parent := h.deliver("Trash", "Trashed thread", "")
			h.sync()
			c := h.conversations()["Trashed thread"]
			if code := h.delete(c, c.Removal); code != http.StatusNoContent {
				t.Fatalf("delete: %d", code)
			}
			h.deliver(replyMailbox, "New reply", parent)
			h.sync()
			got := h.conversations()["Trashed thread"]
			if got.ID != c.ID || len(got.Messages) != 2 {
				t.Fatalf("changed thread should survive pending delete: %+v", got)
			}
			if _, ok := h.mailbox(replyMailbox)["New reply"]; !ok {
				t.Fatal("pending delete removed the new reply")
			}
		})
	}
}

func TestProviderDeleteCancelsWhenMessageLeavesTrash(t *testing.T) {
	h := newHarness(t)
	parent := h.deliver("Trash", "Trashed thread", "")
	h.sync()
	h.deliver("Trash", "Existing reply", parent)
	h.sync()
	c := h.conversations()["Trashed thread"]
	if code := h.delete(c, c.Removal); code != http.StatusNoContent {
		t.Fatalf("delete: %d", code)
	}
	client, err := h.account.dial()
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	if _, err := client.Select("Trash", nil).Wait(); err != nil {
		t.Fatal(err)
	}
	if _, err := client.Move(imap.SeqSetNum(1), "INBOX").Wait(); err != nil {
		t.Fatal(err)
	}
	h.sync()
	if got := h.conversations()[c.Subject]; got.ID != c.ID || len(got.Messages) != 2 || got.Removal != "" {
		t.Fatalf("provider restore should cancel permanent deletion: %+v", got)
	}
	if _, ok := h.mailbox("Trash")["Existing reply"]; !ok {
		t.Fatal("permanent deletion continued after a move out of Trash")
	}
}

func TestProviderCopyFromAllMailKeepsOldSource(t *testing.T) {
	h := newHarness(t)
	user := h.lab.users[labAddress]
	if err := user.Create("Everything", nil); err != nil {
		t.Fatal(err)
	}
	h.account.cfg.Mailboxes = map[Role]string{RoleArchive: "Everything"}
	serveProvider(t, h, imap.CapSet{
		imap.CapIMAP4rev1: {}, imap.CapIMAP4rev2: {}, imap.CapSpecialUse: {},
	}, func(s imapserver.Session) imapserver.Session {
		return allMailSession{s.(imapserver.SessionIMAP4rev2)}
	})
	appendOldProviderMail(t, h, "INBOX", "Old mail")
	h.sync()
	h.set(h.conversations()["Old mail"], func(s *ConversationState) { s.Workflow = WorkflowSettled })
	h.sync()
	h.set(h.conversations()["Old mail"], func(s *ConversationState) { s.Removal = RoleTrash })
	h.sync()
	if len(h.mailbox("Everything")) != 1 || len(h.mailbox("Trash")) != 1 {
		t.Fatal("leaving All Mail should copy the message and keep the source")
	}
	if got := h.conversations()["Old mail"]; got.Removal != RoleTrash {
		t.Fatalf("old copy was not associated with its thread: %+v", got)
	}
}

type allMailSession struct {
	imapserver.SessionIMAP4rev2
}

func (s allMailSession) List(w *imapserver.ListWriter, ref string, patterns []string, options *imap.ListOptions) error {
	// The in-memory backend does not assign special-use flags to created mailboxes.
	if options.ReturnSpecialUse {
		if err := w.WriteList(&imap.ListData{Mailbox: "Everything", Delim: '/', Attrs: []imap.MailboxAttr{imap.MailboxAttrAll}}); err != nil {
			return err
		}
	}
	return s.SessionIMAP4rev2.List(w, ref, patterns, options)
}

func TestProviderPinPreservesReadFlagsOnSettledMail(t *testing.T) {
	h := newHarness(t)
	h.deliver("Archive", "Unread archive mail", "")
	h.sync()
	c := h.conversations()["Unread archive mail"]
	h.set(c, func(s *ConversationState) { s.Pinned = true })
	h.sync()
	flags := h.mailbox("Archive")[c.Subject]
	if !slices.Contains(flags, imap.FlagFlagged) || slices.Contains(flags, imap.FlagSeen) {
		t.Fatalf("pin should only set Flagged, got %v", flags)
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
			if err := h.lab.users[labAddress].Delete("Archive"); err != nil {
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

func TestProviderNativeMovePreservesUnrelatedDeletedMail(t *testing.T) {
	for _, targeted := range []bool{true, false} {
		name := "UIDPLUS"
		if !targeted {
			name = "no UIDPLUS"
		}
		t.Run(name, func(t *testing.T) {
			h := newHarness(t)
			caps := imap.CapSet{imap.CapIMAP4rev1: {}, imap.CapMove: {}}
			if targeted {
				caps[imap.CapUIDPlus] = struct{}{}
			}
			serveProvider(t, h, caps, nil)
			h.deliver("INBOX", "Move me", "")
			h.deliver("INBOX", "Unrelated deleted message", "", imap.FlagDeleted)
			h.sync()
			h.set(h.conversations()["Move me"], func(s *ConversationState) { s.Workflow = WorkflowSettled })
			err := h.account.Sync()
			inbox, archive := h.mailbox("INBOX"), h.mailbox("Archive")
			if !slices.Contains(inbox["Unrelated deleted message"], imap.FlagDeleted) {
				t.Fatalf("MOVE expunged an unrelated UID: %v", inbox)
			}
			if err != nil || len(inbox) != 1 || len(archive) != 1 {
				t.Fatalf("MOVE should move one message: %v, inbox %v, archive %v", err, inbox, archive)
			}
		})
	}
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

type failingCopySession struct {
	imapserver.Session
}

func (s failingCopySession) Copy(imap.NumSet, string) (*imap.CopyData, error) {
	return nil, &imap.Error{Type: imap.StatusResponseTypeNo, Text: "test copy refused"}
}

func TestProviderFailedAllMailCopyLeavesSourceUndeleted(t *testing.T) {
	h := newHarness(t)
	if err := h.lab.users[labAddress].Create("Everything", nil); err != nil {
		t.Fatal(err)
	}
	h.account.cfg.Mailboxes = map[Role]string{RoleArchive: "Everything"}
	serveProvider(t, h, imap.CapSet{imap.CapIMAP4rev1: {}, imap.CapSpecialUse: {}, imap.CapListExtended: {}},
		func(s imapserver.Session) imapserver.Session {
			return failingCopySession{allMailSession{s.(imapserver.SessionIMAP4rev2)}}
		})
	h.deliver("Everything", "Keep on failed copy", "")
	h.sync()
	h.set(h.conversations()["Keep on failed copy"], func(s *ConversationState) { s.Workflow = WorkflowInbox })
	// Keep the connection open after the error so a queued STORE or EXPUNGE reaches the server.
	err := h.account.sync()
	var status *imap.Error
	if !errors.As(err, &status) || status.Text != "test copy refused" {
		t.Fatalf("expected the COPY failure, got %v", err)
	}
	if err := h.account.client.Noop().Wait(); err != nil {
		t.Fatal(err)
	}
	got := h.mailbox("Everything")
	if flags, ok := got["Keep on failed copy"]; !ok || slices.Contains(flags, imap.FlagDeleted) {
		t.Fatalf("failed COPY touched the source: %v", got)
	}
}
