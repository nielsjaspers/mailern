package mailsync

import (
	"fmt"
	"net/http"
	"slices"
	"sync/atomic"
	"testing"
	"time"

	"github.com/emersion/go-imap/v2"
	"github.com/emersion/go-imap/v2/imapclient"
	"github.com/emersion/go-imap/v2/imapserver"
	"github.com/google/uuid"
	"github.com/nielsjaspers/mailern/server/internal/maillab"
)

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

func TestDeleteTakesReplyLeftInSentByAnotherClient(t *testing.T) {
	h := newHarness(t)
	parent := h.deliver("INBOX", "Dinner", "")
	h.sync()
	c := h.conversations()["Dinner"]
	req := SendRequest{ID: uuid.NewString(), ConversationID: c.ID, AccountID: "lab", To: []string{"sam@example.com"},
		Subject: "Re: Dinner", Text: "Sounds good.", InReplyTo: parent, References: []string{parent}}
	if code := h.request("POST", "/v1/send", req, nil); code != http.StatusNoContent {
		t.Fatalf("send: %d", code)
	}
	h.sync()
	// Another client trashes only the incoming message.
	other, err := imapclient.DialInsecure(h.imap.Address(), nil)
	if err != nil {
		t.Fatal(err)
	}
	other.Login(labAddress, "lab").Wait()
	other.Select("INBOX", nil).Wait()
	other.Move(imap.SeqSetNum(1), "Trash").Wait()
	other.Close()
	h.sync()
	trashed := h.conversations()["Dinner"]
	if trashed.Removal != RoleTrash {
		t.Fatalf("the thread should follow its incoming mail to Trash, got %q", trashed.Removal)
	}
	if code := h.delete(trashed, RoleTrash); code != http.StatusNoContent {
		t.Fatalf("permanent delete should take the reply left in Sent, got %d", code)
	}
	h.sync()
	h.sync()
	if h.count("Trash") != 0 || h.count("Sent") != 0 {
		t.Fatalf("delete should remove the whole thread: Trash %d, Sent %d", h.count("Trash"), h.count("Sent"))
	}
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
	// The reply rescues the thread, so the root leaves Trash without the service's flag. The copy another
	// client marked deleted stays as it was.
	trash, archive := h.mailbox("Trash"), h.mailbox("Archive")
	if len(trash) != 1 || !slices.Contains(trash["Already marked"], imap.FlagDeleted) {
		t.Fatalf("expected only the externally deleted copy in Trash, got %v", trash)
	}
	if flags, ok := archive[subject]; !ok || slices.Contains(flags, imap.FlagDeleted) {
		t.Fatalf("expected the rescued root in Archive without the service's flag, got %v", archive)
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
			reply := maillab.Message("sam@example.com", labAddress, "Reply during writable SELECT", "Hello.", root, time.Now())
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
			if err := h.lab.User(labAddress).Create("New Trash", nil); err != nil {
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

func TestProviderDeleteConfirmsOldAllMailCopyWithoutPendingPlacement(t *testing.T) {
	h := newHarness(t)
	if err := h.lab.User(labAddress).Create("Everything", nil); err != nil {
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
	reply := maillab.Message("sam@example.com", labAddress, "Late reply", "Hello", root, time.Now())
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
	if err := h.lab.User(labAddress).Create("New Trash", nil); err != nil {
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

func TestTrashRestoreAndDelete(t *testing.T) {
	h := newHarness(t)
	h.deliver("INBOX", "Dinner", "")
	h.sync()
	h.set(h.conversations()["Dinner"], func(s *ConversationState) { s.Removal = RoleTrash })
	h.sync()
	if _, ok := h.mailbox("Trash")["Dinner"]; !ok {
		t.Fatal("trash should move the message to Trash")
	}
	c := h.conversations()["Dinner"]
	if c.Removal != RoleTrash || c.Workflow != WorkflowInbox {
		t.Fatalf("trashed thread should keep its workflow: %s/%q", c.Workflow, c.Removal)
	}
	if code := h.delete(c, c.Removal); code != http.StatusNoContent {
		t.Fatalf("delete: %d", code)
	}
	if code := h.delete(c, c.Removal); code != http.StatusNotFound {
		t.Fatalf("retry after a lost delete acknowledgment: %d", code)
	}
	h.sync()
	if len(h.mailbox("Trash")) != 0 {
		t.Fatal("delete should expunge the message")
	}
	var resp syncResponse
	h.request("GET", fmt.Sprintf("/v1/sync?since=%d", c.Revision), nil, &resp)
	if !slices.Contains(resp.Deleted, c.ID) {
		t.Fatal("the phone should learn about the deletion")
	}
}

func TestDeleteRejectsRemapAlreadySeenByBackgroundSync(t *testing.T) {
	h := newHarness(t)
	var remapped atomic.Bool
	if err := h.lab.User(labAddress).Create("New Trash", nil); err != nil {
		t.Fatal(err)
	}
	serveProvider(t, h, imap.CapSet{imap.CapIMAP4rev2: {}, imap.CapSpecialUse: {}}, func(s imapserver.Session) imapserver.Session {
		return remappedTrashSession{fixedUIDValiditySession{s.(imapserver.SessionIMAP4rev2)}, &remapped}
	})
	h.deliver("INBOX", "Offline Trash", "")
	h.deliver("Trash", "Confirmed in Trash", "")
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
	observed := h.conversations()
	remapped.Store(true)
	h.sync()
	current := h.conversations()
	for subject, before := range observed {
		after := current[subject]
		if after.ID != before.ID || after.Removal != before.Removal || after.Messages[0].ID != before.Messages[0].ID {
			t.Fatalf("the same conversation and placement should survive the remap: %+v", after)
		}
		if token := before.mailboxIdentities[RoleTrash]; token == "" || after.mailboxIdentities[RoleTrash] == "" || after.mailboxIdentities[RoleTrash] == token {
			t.Fatalf("expected a different token after the folder changed for %q", subject)
		}
		if code := h.delete(before, RoleTrash); code != http.StatusConflict {
			t.Fatalf("stale delete of %q returned %d", subject, code)
		}
	}
	h.sync()
	if len(h.mailbox("INBOX")) != 1 || len(h.mailbox("Trash")) != 1 || len(h.mailbox("New Trash")) != 1 {
		t.Fatal("stale confirmations moved or deleted mail")
	}
}

func TestDeleteRejectsJunkUIDValidityChangeAlreadySeenByBackgroundSync(t *testing.T) {
	h := newHarness(t)
	h.deliver("Junk", "Confirmed in Junk", "")
	h.sync()
	before := h.conversations()["Confirmed in Junk"]
	user := h.lab.User(labAddress)
	if err := user.Rename("Junk", "Old Junk", nil); err != nil {
		t.Fatal(err)
	}
	if err := user.Create("Junk", nil); err != nil {
		t.Fatal(err)
	}
	client, err := h.account.dial()
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	if _, err := client.Select("Old Junk", nil).Wait(); err != nil {
		t.Fatal(err)
	}
	if _, err := client.Copy(imap.UIDSetNum(1), "Junk").Wait(); err != nil {
		t.Fatal(err)
	}
	h.sync()
	after := h.conversations()[before.Subject]
	if after.ID != before.ID || after.Removal != RoleJunk || after.Messages[0].ID != before.Messages[0].ID ||
		after.mailboxIdentities[RoleJunk] == before.mailboxIdentities[RoleJunk] {
		t.Fatalf("expected the same message in a new generation of Junk: %+v", after)
	}
	if code := h.delete(before, RoleJunk); code != http.StatusConflict {
		t.Fatalf("stale Junk delete returned %d", code)
	}
	if code := h.delete(after, RoleJunk); code != http.StatusNoContent {
		t.Fatalf("fresh Junk delete returned %d", code)
	}
	h.sync()
	if len(h.mailbox("Junk")) != 0 || len(h.mailbox("Old Junk")) != 1 {
		t.Fatal("fresh confirmation should delete only the tracked copy in Junk")
	}
}

func TestDeleteOutsideTrashIsRefused(t *testing.T) {
	h := newHarness(t)
	h.deliver("INBOX", "Dinner", "")
	h.sync()
	if code := h.delete(h.conversations()["Dinner"], RoleInbox); code != http.StatusUnprocessableEntity {
		t.Fatalf("deleting inbox mail should fail, got %d", code)
	}
}

func TestDeleteRejectsStaleConfirmation(t *testing.T) {
	for _, change := range []string{"reply", "different ID", "missing mailbox identity", "restore", "junk"} {
		t.Run(change, func(t *testing.T) {
			h := newHarness(t)
			parent := h.deliver("Trash", "Dinner", "")
			h.sync()
			c := h.conversations()["Dinner"]
			switch change {
			case "reply":
				h.deliver("Trash", "New reply", parent)
			case "different ID":
				c.Messages[0].ID = uuid.NewString()
			case "missing mailbox identity":
				delete(c.mailboxIdentities, RoleTrash)
			default:
				client, err := h.account.dial()
				if err != nil {
					t.Fatal(err)
				}
				defer client.Close()
				if _, err := client.Select("Trash", nil).Wait(); err != nil {
					t.Fatal(err)
				}
				name := "INBOX"
				if change == "junk" {
					name = "Junk"
				}
				if _, err := client.Move(imap.SeqSetNum(1), name).Wait(); err != nil {
					t.Fatal(err)
				}
			}
			if code := h.delete(c, RoleTrash); code != http.StatusConflict {
				t.Fatalf("stale delete: %d", code)
			}
			got := h.conversations()[c.Subject]
			if got.ID != c.ID || change == "reply" && len(got.Messages) != 2 ||
				change == "restore" && got.Removal != "" || change == "junk" && got.Removal != RoleJunk {
				t.Fatalf("conflict did not preserve the provider change: %+v", got)
			}
		})
	}
}

func TestDeleteAfterLocalMove(t *testing.T) {
	for _, test := range []struct {
		name                  string
		priorPUT, uidPlusOnly bool
	}{
		{name: "offline move"},
		{name: "acknowledged move", priorPUT: true},
		{name: "lost move acknowledgment", priorPUT: true},
		{name: "UIDPLUS fallback", uidPlusOnly: true},
	} {
		t.Run(test.name, func(t *testing.T) {
			h := newHarness(t)
			if test.uidPlusOnly {
				serveProvider(t, h, imap.CapSet{imap.CapIMAP4rev1: {}, imap.CapUIDPlus: {}}, nil)
			}
			h.deliver("INBOX", "Dinner", "")
			h.sync()
			c := h.conversations()["Dinner"]
			if test.priorPUT {
				h.set(c, func(s *ConversationState) { s.Removal = RoleTrash })
				if test.name != "lost move acknowledgment" {
					c = h.conversations()["Dinner"]
				}
			}
			if code := h.delete(c, RoleTrash); code != http.StatusNoContent {
				t.Fatalf("delete after local move: %d", code)
			}
			h.sync()
			if len(h.conversations()) != 0 || len(h.mailbox("INBOX")) != 0 || len(h.mailbox("Trash")) != 0 {
				t.Fatal("the confirmed message should be expunged")
			}
		})
	}
}
