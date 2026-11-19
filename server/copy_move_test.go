package main

import (
	"net"
	"slices"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/emersion/go-imap/v2"
	"github.com/emersion/go-imap/v2/imapserver"
)

type copyMoveProvider struct {
	imapserver.Session
	conn   net.Conn
	fault  *atomic.Int32
	copies *atomic.Int32
}

const (
	failCopy = iota + 1
	failExpunge
	loseCopyResponse
	loseExpungeResponse
)

func (s copyMoveProvider) Copy(set imap.NumSet, dest string) (*imap.CopyData, error) {
	s.copies.Add(1)
	if s.fault.CompareAndSwap(failCopy, 0) {
		return nil, &imap.Error{Type: imap.StatusResponseTypeNo, Text: "test copy refused"}
	}
	data, err := s.Session.Copy(set, dest)
	if err == nil && s.fault.CompareAndSwap(loseCopyResponse, 0) {
		s.conn.Close()
	}
	return data, err
}

func (s copyMoveProvider) Expunge(w *imapserver.ExpungeWriter, set *imap.UIDSet) error {
	if set == nil {
		return &imap.Error{Type: imap.StatusResponseTypeBad, Text: "expected UID EXPUNGE"}
	}
	if s.fault.CompareAndSwap(failExpunge, 0) {
		return &imap.Error{Type: imap.StatusResponseTypeNo, Text: "test expunge refused"}
	}
	err := s.Session.Expunge(w, set)
	if err == nil && s.fault.CompareAndSwap(loseExpungeResponse, 0) {
		s.conn.Close()
	}
	return err
}

func serveCopyMoveProvider(t *testing.T, h *harness, fault int32) *atomic.Int32 {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	var pending, copies atomic.Int32
	pending.Store(fault)
	server := imapserver.New(&imapserver.Options{
		Caps: imap.CapSet{imap.CapIMAP4rev1: {}, imap.CapUIDPlus: {}}, InsecureAuth: true, Logger: quietLogger{},
		NewSession: func(conn *imapserver.Conn) (imapserver.Session, *imapserver.GreetingData, error) {
			return copyMoveProvider{h.lab.imap.NewSession(), conn.NetConn(), &pending, &copies}, nil, nil
		},
	})
	go server.Serve(listener)
	t.Cleanup(func() { server.Close() })
	h.lab.IMAP = endpointFor(listener)
	h.account.cfg.IMAP = &h.lab.IMAP
	return &copies
}

func restartCopyMoveAccount(t *testing.T, h *harness) {
	t.Helper()
	h.account.disconnect()
	store, err := OpenStore(h.account.store.path)
	if err != nil {
		t.Fatal(err)
	}
	h.account = NewAccount(h.account.cfg, store, h.account.window)
}

func TestProviderUIDPlusMoveRetriesAfterRestart(t *testing.T) {
	for _, destination := range []string{"Archive", "Trash"} {
		t.Run(destination, func(t *testing.T) {
			h := newHarness(t)
			copies := serveCopyMoveProvider(t, h, failExpunge)
			const subject = "Move me with UIDPLUS"
			appendOldProviderMail(t, h, "INBOX", subject)
			h.deliver("INBOX", "Unrelated deleted mail", "", imap.FlagDeleted)
			h.sync()
			thread := h.conversations()[subject]
			h.set(thread, func(state *ConversationState) {
				if destination == "Trash" {
					state.Removal = RoleTrash
				} else {
					state.Workflow = WorkflowSettled
				}
			})
			if err := h.account.Sync(); err == nil || !strings.Contains(err.Error(), "test expunge refused") {
				t.Fatalf("expected failed expunge, got %v", err)
			}
			if flags, ok := h.mailbox("INBOX")[subject]; !ok || slices.Contains(flags, imap.FlagDeleted) {
				t.Fatalf("failed expunge should leave the source available, got present=%v, flags=%v", ok, flags)
			}
			if _, ok := h.mailbox(destination)[subject]; !ok {
				t.Fatal("first COPY did not reach the destination")
			}
			restartCopyMoveAccount(t, h)
			h.sync()
			h.sync()
			if inbox := h.mailbox("INBOX"); len(inbox) != 1 || !slices.Contains(inbox["Unrelated deleted mail"], imap.FlagDeleted) {
				t.Fatalf("retry did not expunge exactly the source, got Inbox %v", inbox)
			}
			if copies.Load() != 1 || len(h.mailbox(destination)) != 1 {
				t.Fatalf("retry should reuse the destination UID, got %d COPY attempts", copies.Load())
			}
			h.account.store.Read(func(st *State) {
				if c := st.Conversations[thread.ID]; c == nil || c.Pending || len(c.Keys) != 1 {
					t.Fatalf("expected one reconciled message, got %+v", c)
				} else if msg := st.account(h.account.cfg.ID).Messages[c.Keys[0]]; msg.PendingMove != nil {
					t.Fatalf("completed move still has a journal entry: %+v", msg.PendingMove)
				}
			})
		})
	}
}

func TestProviderUIDPlusFailedCopyLeavesSourceUndeleted(t *testing.T) {
	h := newHarness(t)
	copies := serveCopyMoveProvider(t, h, failCopy)
	const subject = "Keep on failed fallback copy"
	h.deliver("INBOX", subject, "")
	h.sync()
	h.set(h.conversations()[subject], func(state *ConversationState) { state.Removal = RoleTrash })
	if err := h.account.sync(); err == nil || !strings.Contains(err.Error(), "test copy refused") {
		t.Fatalf("expected failed COPY, got %v", err)
	}
	if err := h.account.client.Noop().Wait(); err != nil {
		t.Fatal(err)
	}
	if flags, ok := h.mailbox("INBOX")[subject]; !ok || slices.Contains(flags, imap.FlagDeleted) {
		t.Fatalf("failed COPY touched the source, got present=%v, flags=%v", ok, flags)
	}
	if trash := h.mailbox("Trash"); len(trash) != 0 {
		t.Fatalf("failed COPY changed Trash: %v", trash)
	}
	h.sync()
	if copies.Load() != 2 || len(h.mailbox("INBOX")) != 0 || len(h.mailbox("Trash")) != 1 {
		t.Fatalf("retry did not complete a rejected COPY, got %d attempts", copies.Load())
	}
}

func TestProviderUIDPlusMoveRecoversLostResponses(t *testing.T) {
	for _, scenario := range []struct {
		name  string
		fault int32
	}{
		{"COPY", loseCopyResponse},
		{"UID EXPUNGE", loseExpungeResponse},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			h := newHarness(t)
			copies := serveCopyMoveProvider(t, h, scenario.fault)
			const subject = "Move despite a lost response"
			appendOldProviderMail(t, h, "INBOX", subject)
			h.sync()
			h.set(h.conversations()[subject], func(state *ConversationState) { state.Removal = RoleTrash })
			if err := h.account.Sync(); err == nil {
				t.Fatal("lost response should interrupt sync")
			}
			if len(h.mailbox("Trash")) != 1 {
				t.Fatal("COPY should have committed before the connection closed")
			}
			restartCopyMoveAccount(t, h)
			h.sync()
			if copies.Load() != 1 || len(h.mailbox("INBOX")) != 0 || len(h.mailbox("Trash")) != 1 {
				t.Fatalf("lost response triggered duplicate or incomplete move, got %d COPY attempts", copies.Load())
			}
		})
	}
}

func TestProviderUIDPlusMoveLeavesSourceAfterRestoreOrRemap(t *testing.T) {
	for _, change := range []string{"mailbox remap", "copy removed", "local restore"} {
		t.Run(change, func(t *testing.T) {
			h := newHarness(t)
			copies := serveCopyMoveProvider(t, h, failExpunge)
			const subject = "Keep source after placement changes"
			h.deliver("INBOX", subject, "")
			h.sync()
			h.set(h.conversations()[subject], func(state *ConversationState) { state.Removal = RoleTrash })
			if err := h.account.Sync(); err == nil || !strings.Contains(err.Error(), "test expunge refused") {
				t.Fatalf("expected failed expunge, got %v", err)
			}
			switch change {
			case "mailbox remap":
				if err := h.lab.users[labAddress].Create("Other Trash", nil); err != nil {
					t.Fatal(err)
				}
				h.deliver("Other Trash", "Unrelated mail", "")
				h.account.cfg.Mailboxes = map[Role]string{RoleTrash: "Other Trash"}
				h.account.disconnect()
			case "copy removed":
				c, err := h.account.dial()
				if err != nil {
					t.Fatal(err)
				}
				defer c.Close()
				if _, err := c.Select("Trash", nil).Wait(); err != nil {
					t.Fatal(err)
				}
				if err := expungeUIDs(c, imap.UIDSetNum(1)); err != nil {
					t.Fatal(err)
				}
			case "local restore":
				h.set(h.conversations()[subject], func(state *ConversationState) { state.Removal = "" })
			}
			h.sync()
			h.sync()
			if flags, ok := h.mailbox("INBOX")[subject]; copies.Load() != 1 || !ok || slices.Contains(flags, imap.FlagDeleted) {
				t.Fatalf("invalidated copy caused cleanup or another COPY, got %d attempts, source present=%v, flags=%v", copies.Load(), ok, flags)
			}
		})
	}
}
