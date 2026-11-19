package main

import (
	"slices"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/emersion/go-imap/v2"
	"github.com/emersion/go-imap/v2/imapserver"
)

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

func queueProviderDelete(t *testing.T, h *harness, id string) {
	t.Helper()
	if err := h.account.store.Update(func(st *State) error {
		c := st.Conversations[id]
		c.DeleteKeys = slices.Clone(c.Keys)
		c.Deleting, c.Pending = true, true
		st.Touch(c)
		return nil
	}); err != nil {
		t.Fatal(err)
	}
}

func TestProviderRevalidatesEveryDeleteMemberAfterScan(t *testing.T) {
	h := newHarness(t)
	root := h.deliver("Trash", "Parent stays in Trash", "")
	armed := interleaveProviderMove(t, h, "Trash", 2, false)
	h.sync()
	h.deliver("Trash", "Restored sibling", root)
	h.deliver("Trash", "Separate confirmed delete", "")
	h.sync()
	initial := h.conversations()
	parent := initial["Parent stays in Trash"]
	if len(parent.Messages) != 2 {
		t.Fatalf("expected both members before the delete, got %+v", parent.Messages)
	}
	queueProviderDelete(t, h, parent.ID)
	queueProviderDelete(t, h, initial["Separate confirmed delete"].ID)
	armed.Store(true)
	h.sync()
	if armed.Load() {
		t.Fatal("restore did not interleave with the write")
	}
	inbox := h.mailbox("INBOX")
	if _, ok := inbox["Restored sibling"]; !ok || len(inbox) != 1 {
		t.Fatalf("expected restored sibling in Inbox, got %v", inbox)
	}
	trash := h.mailbox("Trash")
	if flags, ok := trash[parent.Subject]; !ok || slices.Contains(flags, imap.FlagDeleted) || len(trash) != 1 {
		t.Fatalf("only the unrelated confirmed delete should be expunged, got Trash %v", trash)
	}
	if got := h.conversations()[parent.Subject]; got.ID != parent.ID || len(got.Messages) != 2 || got.Removal != "" {
		t.Fatalf("restored conversation should keep both messages: %+v", got)
	}
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
	if err := h.lab.users[labAddress].Create("Other Trash", nil); err != nil {
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
