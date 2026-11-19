package main

import (
	"net"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/emersion/go-imap/v2"
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
