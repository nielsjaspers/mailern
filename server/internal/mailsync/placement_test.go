package mailsync

import (
	"net"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/emersion/go-imap/v2"
	"github.com/emersion/go-imap/v2/imapserver"
	"github.com/nielsjaspers/mailern/server/internal/maillab"
)

func TestProviderRollsBackDeletedFlagAfterExternalMove(t *testing.T) {
	t.Run("keyword preserved", func(t *testing.T) { checkDeletedFlagExternalMove(t, false) })
	t.Run("keyword discarded", func(t *testing.T) { checkDeletedFlagExternalMove(t, true) })
}

func checkDeletedFlagExternalMove(t *testing.T, discardKeyword bool) {
	t.Helper()
	h := newHarness(t)
	// Use the lab's native MOVE connection for the other client. Mailern's connection
	// drops the response to the first STORE that adds Deleted.
	other, err := h.account.dial()
	if err != nil {
		t.Fatal(err)
	}
	defer other.Close()
	if !other.Caps().Has(imap.CapMove) {
		t.Fatal("test requires native MOVE")
	}
	serveCopyMoveProvider(t, h, loseDeletedStoreResponse)
	const dest = "Personal folder"
	if err := other.Create(dest, nil).Wait(); err != nil {
		t.Fatal(err)
	}
	raw := maillab.Message("sam@example.com", labAddress, "Two identical messages", "Hello.", "", time.Now())
	if err := h.lab.Deliver(labAddress, "Trash", raw, imap.FlagSeen); err != nil {
		t.Fatal(err)
	}
	if err := h.lab.Deliver(labAddress, dest, raw, imap.FlagDeleted, imap.FlagFlagged); err != nil {
		t.Fatal(err)
	}
	c, err := h.account.dial()
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	sel, err := c.Select("Trash", nil).Wait()
	if err != nil {
		t.Fatal(err)
	}
	set := imap.UIDSetNum(1)
	fetch := &imap.FetchOptions{UID: true, Flags: true}
	present, err := c.Fetch(set, fetch).Collect()
	if err != nil {
		t.Fatal(err)
	}
	if err := h.account.expungeOwned(c, mailboxIdentity{"Trash", sel.UIDValidity}, set, present); err == nil {
		t.Fatal("expected the provider to disconnect during STORE")
	}
	if _, err := other.Select("Trash", nil).Wait(); err != nil {
		t.Fatal(err)
	}
	move, err := other.Move(set, dest).Wait()
	if err != nil {
		t.Fatal(err)
	}
	if uids, ok := move.DestUIDs.(imap.UIDSet); !ok || !slices.Equal(uids, imap.UIDSetNum(2)) {
		t.Fatalf("expected MOVE to assign UID 2 in the new mailbox, got %v", move.DestUIDs)
	}
	if _, err := other.Select(dest, nil).Wait(); err != nil {
		t.Fatal(err)
	}
	movedSet := imap.UIDSetNum(2)
	moved, err := other.Fetch(movedSet, fetch).Collect()
	if err != nil || len(moved) != 1 || !slices.Contains(moved[0].Flags, imap.FlagDeleted) {
		t.Fatalf("expected MOVE to carry the deletion flag, got %v, %v", moved, err)
	}
	wantMoved := []imap.Flag{imap.FlagSeen}
	if discardKeyword {
		// Simulate a MOVE that drops custom keywords while preserving system flags.
		wantMoved = append(wantMoved, imap.FlagDeleted)
		setFlags := &imap.StoreFlags{Op: imap.StoreFlagsSet, Silent: true, Flags: wantMoved}
		if err := other.Store(movedSet, setFlags, nil).Close(); err != nil {
			t.Fatal(err)
		}
	}
	restartCopyMoveAccount(t, h)
	recovery, err := h.account.dial()
	if err != nil {
		t.Fatal(err)
	}
	defer recovery.Close()
	if err := h.account.recoverOwnedDeleted(recovery); err != nil {
		t.Fatal(err)
	}
	h.account.store.Read(func(st *State) {
		if st.account(h.account.cfg.ID).OwnedDeleted != nil {
			t.Error("recovery left the interrupted delete in the journal")
		}
	})
	msgs, err := other.Fetch(imap.UIDSetNum(1, 2), fetch).Collect()
	if err != nil || len(msgs) != 2 {
		t.Fatalf("expected both copies to survive, got %v, %v", msgs, err)
	}
	for _, msg := range msgs {
		if msg.UID == 1 && (len(msg.Flags) != 2 || !slices.Contains(msg.Flags, imap.FlagDeleted) || !slices.Contains(msg.Flags, imap.FlagFlagged)) {
			t.Fatalf("changed flags on independently deleted copy: %v", msg.Flags)
		}
		if msg.UID == 2 {
			slices.Sort(msg.Flags)
			slices.Sort(wantMoved)
			if !slices.Equal(msg.Flags, wantMoved) {
				t.Fatalf("moved copy has flags %v, want %v", msg.Flags, wantMoved)
			}
		}
	}
}

func TestRestoreWithIndependentInboxAndTrashCopies(t *testing.T) {
	h := newHarness(t)
	const subject = "Two copies of a garden plan"
	raw := maillab.Message("sam@example.com", labAddress, subject, "Hello.", "", time.Now())
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
			raw := maillab.Message("sam@example.com", labAddress, subject, "Hello.", "", time.Now())
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
	if err := h.lab.User(labAddress).Create("Private folder", nil); err != nil {
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
		Caps: imap.CapSet{imap.CapIMAP4rev1: {}, imap.CapUIDPlus: {}}, InsecureAuth: true, Logger: maillab.QuietLogger{},
		NewSession: func(conn *imapserver.Conn) (imapserver.Session, *imapserver.GreetingData, error) {
			return recoverySelectProvider{copyMoveProvider{h.lab.NewSession(), conn.NetConn(), &fault, &copies}, &denySource}, nil, nil
		},
	})
	go server.Serve(listener)
	t.Cleanup(func() { server.Close() })
	h.imap = endpointFor(listener)
	h.account.cfg.IMAP = &h.imap

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
	raw := maillab.Message("sam@example.com", labAddress, subject, "Hello.", "", time.Now())
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

func TestUIDPlusRestoreFromJunkWithTrashAndInboxCopies(t *testing.T) {
	h := newHarness(t)
	serveCopyMoveProvider(t, h, 0)
	const subject = "Restore from Junk"
	raw := maillab.Message("sam@example.com", labAddress, subject, "Hello.", "", time.Now())
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

func TestProviderAppliesSupportedWritesAlongsideUnsupportedWrites(t *testing.T) {
	for _, provider := range []struct {
		name    string
		move    bool
		uidPlus bool
	}{
		{name: "UIDPLUS only", uidPlus: true},
		{name: "MOVE only", move: true},
		{name: "neither"},
	} {
		t.Run(provider.name, func(t *testing.T) {
			h := newHarness(t)
			caps := imap.CapSet{imap.CapIMAP4rev1: {}}
			if provider.move {
				caps[imap.CapMove] = struct{}{}
			}
			if provider.uidPlus {
				caps[imap.CapUIDPlus] = struct{}{}
			}
			serveProvider(t, h, caps, nil)
			h.deliver("INBOX", "Pin me", "")
			h.deliver("INBOX", "Archive me", "")
			h.deliver("Trash", "Delete me", "")
			h.sync()
			threads := h.conversations()
			h.set(threads["Pin me"], func(s *ConversationState) { s.Pinned = true })
			h.set(threads["Archive me"], func(s *ConversationState) { s.Workflow = WorkflowSettled })
			queueProviderDelete(t, h, threads["Delete me"].ID)
			for range 2 {
				err := h.account.Sync()
				if !slices.Contains(h.mailbox("INBOX")["Pin me"], imap.FlagFlagged) {
					t.Fatalf("unrelated pin was blocked: %v", err)
				}
				if provider.uidPlus && err != nil || !provider.uidPlus && (err == nil || !strings.Contains(err.Error(), "UIDPLUS")) {
					t.Fatalf("unexpected sync error: %v", err)
				}
			}
			_, inInbox := h.mailbox("INBOX")["Archive me"]
			_, inArchive := h.mailbox("Archive")["Archive me"]
			_, inTrash := h.mailbox("Trash")["Delete me"]
			if inInbox != (!provider.move && !provider.uidPlus) || inArchive == inInbox || inTrash != !provider.uidPlus {
				t.Fatalf("unexpected provider state: moved source %v, destination %v, delete target %v", inInbox, inArchive, inTrash)
			}
		})
	}
}
