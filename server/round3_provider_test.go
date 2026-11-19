package main

import (
	"net/http"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/emersion/go-imap/v2"
	"github.com/emersion/go-imap/v2/imapserver"
)

func TestProviderRollsBackSourceStoreAfterCopyRemoved(t *testing.T) {
	h := newHarness(t)
	copies := serveCopyMoveProvider(t, h, loseDeletedStoreResponse)
	const subject = "Keep the only remaining copy"
	h.deliver("INBOX", subject, "")
	h.sync()
	h.set(h.conversations()[subject], func(s *ConversationState) { s.Removal = RoleTrash })
	if err := h.account.Sync(); err == nil {
		t.Fatal("expected lost STORE response")
	}
	if !slices.Contains(h.mailbox("INBOX")[subject], imap.FlagDeleted) {
		t.Fatal("provider did not commit STORE")
	}
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
	restartCopyMoveAccount(t, h)
	h.sync()
	if flags, ok := h.mailbox("INBOX")[subject]; !ok || slices.Contains(flags, imap.FlagDeleted) || copies.Load() != 1 {
		t.Fatalf("expected the source to survive unmarked and no repeat COPY, got %v with flags %v and %d attempts", ok, flags, copies.Load())
	}
}

func TestProviderSupersedesPartialCopyWithExplicitTarget(t *testing.T) {
	for _, scenario := range []struct {
		name       string
		fault      int32
		trashCount int
	}{
		{"COPY response lost", loseCopyResponse, 1},
		{"STORE response lost after COPYUID", loseDeletedStoreResponse, 0},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			h := newHarness(t)
			copies := serveCopyMoveProvider(t, h, scenario.fault)
			const subject = "Send to Junk instead"
			h.deliver("INBOX", subject, "")
			h.sync()
			h.set(h.conversations()[subject], func(s *ConversationState) { s.Removal = RoleTrash })
			if err := h.account.Sync(); err == nil {
				t.Fatal("expected interrupted move")
			}
			h.set(h.conversations()[subject], func(s *ConversationState) { s.Removal = RoleJunk })
			h.sync()
			if len(h.mailbox("INBOX")) != 0 || len(h.mailbox("Trash")) != scenario.trashCount || len(h.mailbox("Junk")) != 1 || copies.Load() != 2 {
				t.Fatalf("expected the new Junk copy and %d retained Trash copies, got %d COPY attempts", scenario.trashCount, copies.Load())
			}
		})
	}
}

func TestProviderRollsBackInterruptedDeleteOnNewReply(t *testing.T) {
	h := newHarness(t)
	serveCopyMoveProvider(t, h, loseDeletedStoreResponse)
	const subject = "Thread survives with its new reply"
	root := h.deliver("Trash", subject, "")
	h.sync()
	h.deliver("Trash", "Already marked", root, imap.FlagDeleted)
	h.sync()
	thread := h.conversations()[subject]
	if code := h.delete(thread, RoleTrash); code != http.StatusNoContent {
		t.Fatalf("delete confirmation returned %d", code)
	}
	if err := h.account.Sync(); err == nil {
		t.Fatal("expected lost STORE response")
	}
	if !slices.Contains(h.mailbox("Trash")[subject], imap.FlagDeleted) {
		t.Fatal("provider did not commit STORE")
	}
	h.deliver("INBOX", "New reply cancels the delete", root)
	restartCopyMoveAccount(t, h)
	h.sync()
	trash := h.mailbox("Trash")
	if len(trash) != 2 || slices.Contains(trash[subject], imap.FlagDeleted) || !slices.Contains(trash["Already marked"], imap.FlagDeleted) {
		t.Fatalf("expected only the service's flag to be cleared, got %v", trash)
	}
	h.account.store.Read(func(st *State) {
		if c := st.Conversations[thread.ID]; c == nil || c.Deleting || len(c.Keys) != 3 {
			t.Fatalf("new reply did not cancel the delete: %+v", c)
		}
	})
}

func TestProviderRollsBackInterruptedExpungeWhenSiblingRestored(t *testing.T) {
	h := newHarness(t)
	other, err := h.account.dial()
	if err != nil {
		t.Fatal(err)
	}
	defer other.Close()
	serveCopyMoveProvider(t, h, loseExpungeBeforeCommit)
	const subject, sibling = "Thread awaiting deletion", "Sibling restored before retry"
	root := h.deliver("Trash", subject, "")
	h.sync()
	h.deliver("Trash", sibling, root)
	h.sync()
	thread := h.conversations()[subject]
	queueProviderDelete(t, h, thread.ID)
	if err := h.account.Sync(); err == nil {
		t.Fatal("expected interruption before expunge")
	}
	if flags := h.mailbox("Trash"); !slices.Contains(flags[subject], imap.FlagDeleted) || !slices.Contains(flags[sibling], imap.FlagDeleted) {
		t.Fatalf("expected both messages marked before the interrupted expunge, got %v", flags)
	}

	if _, err := other.Select("Trash", nil).Wait(); err != nil {
		t.Fatal(err)
	}
	if _, err := other.Move(imap.UIDSetNum(2), "INBOX").Wait(); err != nil {
		t.Fatal(err)
	}
	if _, err := other.Select("INBOX", nil).Wait(); err != nil {
		t.Fatal(err)
	}
	restore := &imap.StoreFlags{Op: imap.StoreFlagsDel, Silent: true, Flags: []imap.Flag{imap.FlagDeleted}}
	if err := other.Store(imap.UIDSetNum(1), restore, nil).Close(); err != nil {
		t.Fatal(err)
	}

	restartCopyMoveAccount(t, h)
	h.sync()
	if flags, exists := h.mailbox("Trash")[subject]; !exists || slices.Contains(flags, imap.FlagDeleted) {
		t.Fatalf("restore should keep the original and roll back its flag, got %v with flags %v", exists, flags)
	}
	h.account.store.Read(func(st *State) {
		if c := st.Conversations[thread.ID]; c == nil || c.Deleting || len(c.Keys) != 2 {
			t.Fatalf("restore should preserve the conversation: %+v", c)
		}
	})
}

func TestProviderRescansBeforeDeleteWhenMailboxGetsNewMail(t *testing.T) {
	for _, mailbox := range []string{"Trash", "INBOX"} {
		t.Run(mailbox, func(t *testing.T) {
			h := newHarness(t)
			var armed atomic.Bool
			const subject = "Keep the thread when a reply arrives"
			root := h.deliver("Trash", subject, "")
			reply := LabMessage("sam@example.com", labAddress, "Reply during writable SELECT", "Hello.", root, time.Now())
			serveProvider(t, h, imap.CapSet{imap.CapIMAP4rev2: {}, imap.CapIMAP4rev1: {}}, func(s imapserver.Session) imapserver.Session {
				return beforeSelectSession{s.(imapserver.SessionIMAP4rev2), func(name string, readOnly bool) error {
					if name == "Trash" && !readOnly && armed.CompareAndSwap(true, false) {
						return h.lab.Deliver(labAddress, mailbox, reply)
					}
					return nil
				}}
			})
			h.sync()
			thread := h.conversations()[subject]
			queueProviderDelete(t, h, thread.ID)
			armed.Store(true)
			h.sync()
			if got := h.conversations()[subject]; armed.Load() || got.ID != thread.ID || len(got.Messages) != 2 {
				t.Fatalf("expected both the original and reply, got %+v", got)
			}
		})
	}
}

type remappedTrashSession struct {
	imapserver.SessionIMAP4rev2
	remapped *atomic.Bool
}

func (s remappedTrashSession) List(w *imapserver.ListWriter, ref string, patterns []string, options *imap.ListOptions) error {
	if options.ReturnSpecialUse && s.remapped.Load() {
		if err := w.WriteList(&imap.ListData{Mailbox: "New Trash", Attrs: []imap.MailboxAttr{imap.MailboxAttrTrash}}); err != nil {
			return err
		}
	}
	return s.SessionIMAP4rev2.List(w, ref, patterns, options)
}

func TestProviderCancelsDeleteOnLiveSpecialUseRemap(t *testing.T) {
	for _, queued := range []bool{true, false} {
		name := "confirmation"
		if queued {
			name = "queued"
		}
		t.Run(name, func(t *testing.T) {
			h := newHarness(t)
			var remapped atomic.Bool
			if err := h.lab.users[labAddress].Create("New Trash", nil); err != nil {
				t.Fatal(err)
			}
			serveProvider(t, h, imap.CapSet{imap.CapIMAP4rev2: {}, imap.CapIMAP4rev1: {}, imap.CapSpecialUse: {}}, func(s imapserver.Session) imapserver.Session {
				return remappedTrashSession{s.(imapserver.SessionIMAP4rev2), &remapped}
			})
			const subject = "Message available in remapped Trash"
			h.deliver("Trash", subject, "")
			client, err := h.account.dial()
			if err != nil {
				t.Fatal(err)
			}
			defer client.Close()
			if _, err := client.Select("Trash", nil).Wait(); err != nil {
				t.Fatal(err)
			}
			if _, err := client.Copy(imap.UIDSetNum(1), "New Trash").Wait(); err != nil {
				t.Fatal(err)
			}
			h.sync()
			thread := h.conversations()[subject]
			if queued {
				queueProviderDelete(t, h, thread.ID)
			}
			remapped.Store(true)
			if queued {
				h.sync()
				if got := h.conversations()[subject]; got.ID != thread.ID {
					t.Fatalf("remap should cancel the delete and preserve the conversation: %+v", got)
				}
			} else if code := h.delete(thread, RoleTrash); code != http.StatusConflict {
				t.Fatalf("confirmation after remap returned %d", code)
			}
			if len(h.mailbox("Trash")) != 1 || len(h.mailbox("New Trash")) != 1 {
				t.Fatal("mailbox remap allowed permanent deletion")
			}
		})
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

func TestProviderDeleteConfirmsOldAllMailCopyWithoutPendingPlacement(t *testing.T) {
	h := newHarness(t)
	if err := h.lab.users[labAddress].Create("Everything", nil); err != nil {
		t.Fatal(err)
	}
	h.account.cfg.Mailboxes = map[Role]string{RoleArchive: "Everything"}
	serveProvider(t, h, imap.CapSet{imap.CapIMAP4rev2: {}, imap.CapIMAP4rev1: {}, imap.CapSpecialUse: {}}, func(s imapserver.Session) imapserver.Session {
		return allMailSession{s.(imapserver.SessionIMAP4rev2)}
	})
	const subject = "Old mail deleted directly from All Mail"
	appendOldProviderMail(t, h, "INBOX", subject)
	h.sync()
	h.set(h.conversations()[subject], func(s *ConversationState) { s.Workflow = WorkflowSettled })
	h.sync()
	thread := h.conversations()[subject]
	if thread.Workflow != WorkflowSettled || thread.Removal != "" || len(h.mailbox("Everything")) != 1 {
		t.Fatalf("expected a settled thread without pending placement: %+v", thread)
	}
	if code := h.delete(thread, RoleTrash); code != http.StatusNoContent {
		t.Fatalf("delete did not confirm the old copy: %d", code)
	}
	if len(h.mailbox("Trash")) != 1 {
		t.Fatal("expected exactly one verified copy in Trash")
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

type beforeStatusSession struct {
	imapserver.SessionIMAP4rev2
	before func(string) error
}

func (s beforeStatusSession) Status(name string, options *imap.StatusOptions) (*imap.StatusData, error) {
	if err := s.before(name); err != nil {
		return nil, err
	}
	return s.SessionIMAP4rev2.Status(name, options)
}

func TestProviderDeleteRechecksTrashAfterOtherMailboxStatus(t *testing.T) {
	h := newHarness(t)
	const subject = "Parent in Trash"
	root := h.deliver("Trash", subject, "")
	reply := LabMessage("sam@example.com", labAddress, "Late reply", "Hello", root, time.Now())
	var armed atomic.Bool
	serveProvider(t, h, imap.CapSet{imap.CapIMAP4rev1: {}, imap.CapIMAP4rev2: {}}, func(s imapserver.Session) imapserver.Session {
		return beforeStatusSession{s.(imapserver.SessionIMAP4rev2), func(name string) error {
			if name == "INBOX" && armed.CompareAndSwap(true, false) {
				return h.lab.Deliver(labAddress, "Trash", reply)
			}
			return nil
		}}
	})
	h.sync()
	queueProviderDelete(t, h, h.conversations()[subject].ID)
	armed.Store(true)
	h.sync()
	if armed.Load() || len(h.mailbox("Trash")) != 2 {
		t.Fatal("late reply must preserve both messages")
	}
}

func TestProviderRemapDuringWritableSelectKeepsFormerTrash(t *testing.T) {
	h := newHarness(t)
	if err := h.lab.users[labAddress].Create("New Trash", nil); err != nil {
		t.Fatal(err)
	}
	var armed, remapped atomic.Bool
	serveProvider(t, h, imap.CapSet{imap.CapIMAP4rev1: {}, imap.CapIMAP4rev2: {}, imap.CapSpecialUse: {}}, func(s imapserver.Session) imapserver.Session {
		return beforeSelectSession{remappedTrashSession{s.(imapserver.SessionIMAP4rev2), &remapped}, func(name string, readOnly bool) error {
			if name == "Trash" && !readOnly && armed.CompareAndSwap(true, false) {
				remapped.Store(true)
			}
			return nil
		}}
	})
	const subject = "Former Trash message"
	h.deliver("Trash", subject, "")
	h.sync()
	queueProviderDelete(t, h, h.conversations()[subject].ID)
	armed.Store(true)
	h.sync()
	if !remapped.Load() || len(h.mailbox("Trash")) != 1 {
		t.Fatal("expunged from the former Trash after a role remap")
	}
}
