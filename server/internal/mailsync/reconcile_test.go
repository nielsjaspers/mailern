package mailsync

import (
	"context"
	"net/http"
	"slices"
	"testing"
	"time"

	"github.com/emersion/go-imap/v2"
	"github.com/emersion/go-imap/v2/imapclient"
	"github.com/google/uuid"
	"github.com/nielsjaspers/mailern/server/internal/maillab"
)

func TestStaleSettlePreservesProviderStar(t *testing.T) {
	h := newHarness(t)
	h.deliver("INBOX", "Starred", "", imap.FlagFlagged)
	h.sync()
	c := h.conversations()["Starred"]
	stale := ConversationState{Workflow: WorkflowSettled, Pinned: false, Fields: []string{"workflow", "unread"}}
	if code := h.request("PUT", "/v1/conversations/"+c.ID, stale, nil); code != 200 {
		t.Fatalf("Settle status %d", code)
	}
	h.sync()
	if got := h.conversations()["Starred"]; !got.Pinned || got.Workflow != WorkflowSettled {
		t.Fatal("Settle must preserve the provider's star")
	}
}

func TestRetargetFlagsOnlyTheJunkCopy(t *testing.T) {
	for _, fault := range []int32{loseCopyResponse, loseDeletedStoreResponse} {
		h := newHarness(t)
		serveCopyMoveProvider(t, h, fault)
		const subject = "Interrupted restore"
		raw := maillab.Message("sam@example.com", labAddress, subject, "Hello.", "", time.Now())
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
	raw := maillab.Message(labAddress, "sam@example.com", subject, "Hello.", "", time.Now())
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

func TestReplyToJunkThreadStaysInJunk(t *testing.T) {
	h := newHarness(t)
	parent := h.deliver("INBOX", "Prize", "")
	h.sync()
	h.set(h.conversations()["Prize"], func(s *ConversationState) { s.Removal = RoleJunk })
	h.sync()
	h.deliver("INBOX", "Re: Prize", parent)
	h.sync()
	h.sync()
	if c := h.conversations()["Prize"]; c.Removal != RoleJunk || len(c.Messages) != 2 {
		t.Fatalf("a reply must not restore a Junk thread: removal %q, %d messages", c.Removal, len(c.Messages))
	}
	if h.count("INBOX") != 0 || h.count("Junk") != 2 {
		t.Fatalf("the reply should follow its thread into Junk: Inbox %d, Junk %d", h.count("INBOX"), h.count("Junk"))
	}
}

func TestTrashTakesReplyWhoseSentCopyArrivesLater(t *testing.T) {
	h := newHarness(t)
	appendSent := false
	h.account.cfg.AppendSent = &appendSent
	parent := h.deliver("INBOX", "Dinner", "")
	h.sync()
	c := h.conversations()["Dinner"]
	req := SendRequest{ID: uuid.NewString(), ConversationID: c.ID, AccountID: "lab", To: []string{"sam@example.com"},
		Subject: "Re: Dinner", Text: "Sounds good.", InReplyTo: parent, References: []string{parent}}
	if code := h.request("POST", "/v1/send", req, nil); code != http.StatusNoContent {
		t.Fatalf("send: %d", code)
	}
	h.set(h.conversations()["Dinner"], func(s *ConversationState) { s.Removal = RoleTrash })
	h.sync()
	// The provider files its Sent copy only now.
	if err := h.lab.Deliver(labAddress, "Sent", h.lab.Submitted()[0]); err != nil {
		t.Fatal(err)
	}
	h.sync()
	h.sync()
	if h.count("Sent") != 0 || h.count("Trash") != 2 {
		t.Fatalf("Trash should take the late Sent copy too: Sent %d, Trash %d", h.count("Sent"), h.count("Trash"))
	}
	if code := h.delete(h.conversations()["Dinner"], RoleTrash); code != http.StatusNoContent {
		t.Fatalf("permanent delete: %d", code)
	}
	h.sync()
	if h.count("Trash") != 0 {
		t.Fatalf("permanent delete should empty Trash, %d left", h.count("Trash"))
	}
}

func TestPinWaitsForSentCopyOfNewThread(t *testing.T) {
	h := newHarness(t)
	appendSent := false
	h.account.cfg.AppendSent = &appendSent
	h.sync()
	req := SendRequest{ID: uuid.NewString(), ConversationID: uuid.NewString(), AccountID: "lab",
		To: []string{"alex@example.org"}, Subject: "Plans", Text: "Are you free?"}
	if code := h.request("POST", "/v1/send", req, nil); code != http.StatusNoContent {
		t.Fatalf("send: %d", code)
	}
	h.set(h.conversations()["Plans"], func(s *ConversationState) { s.Pinned = true })
	h.sync()
	if !h.conversations()["Plans"].Pinned {
		t.Fatal("the pin must survive a sync before the Sent copy exists")
	}
	if err := h.lab.Deliver(labAddress, "Sent", h.lab.Submitted()[0]); err != nil {
		t.Fatal(err)
	}
	h.sync()
	h.sync()
	if !slices.Contains(h.mailbox("Sent")["Plans"], imap.FlagFlagged) || !h.conversations()["Plans"].Pinned {
		t.Fatal("the Sent copy should take the pin once it appears")
	}
}

func TestReplyRescuesWholeThreadFromTrash(t *testing.T) {
	h := newHarness(t)
	root := h.deliver("INBOX", "Dinner", "")
	h.sync()
	h.set(h.conversations()["Dinner"], func(s *ConversationState) { s.Removal = RoleTrash })
	h.sync()
	h.deliver("INBOX", "Re: Dinner", root)
	h.sync()
	h.sync()
	if c := h.conversations()["Dinner"]; c.Removal != "" || c.Workflow != WorkflowInbox {
		t.Fatalf("the reply should return the thread to Inbox: %s/%q", c.Workflow, c.Removal)
	}
	if h.count("Trash") != 0 || h.count("Archive") != 1 || h.count("INBOX") != 1 {
		t.Fatalf("older mail must leave Trash before it expires: Trash %d, Archive %d, Inbox %d", h.count("Trash"), h.count("Archive"), h.count("INBOX"))
	}
}

func TestRestorePutsNewestLiveMessageInInbox(t *testing.T) {
	h := newHarness(t)
	root := h.deliver("INBOX", "Dinner", "")
	h.deliver("INBOX", "Re: Dinner", root)
	h.sync()
	h.set(h.conversations()["Dinner"], func(s *ConversationState) { s.Removal = RoleTrash })
	h.sync()
	// Another client marks the newest message deleted without expunging it.
	c, err := imapclient.DialInsecure(h.imap.Address(), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	c.Login(labAddress, "lab").Wait()
	c.Select("Trash", nil).Wait()
	found, _ := c.UIDSearch(&imap.SearchCriteria{Header: []imap.SearchCriteriaHeaderField{{Key: "Subject", Value: "Re: Dinner"}}}, nil).Wait()
	c.Store(imap.UIDSetNum(found.AllUIDs()...), &imap.StoreFlags{Op: imap.StoreFlagsAdd, Flags: []imap.Flag{imap.FlagDeleted}}, nil).Close()
	h.sync()
	h.set(h.conversations()["Dinner"], func(s *ConversationState) { s.Removal = "" })
	h.sync()
	if _, ok := h.mailbox("INBOX")["Dinner"]; !ok {
		t.Fatalf("Restore should put the newest live message in Inbox, Inbox: %v", h.mailbox("INBOX"))
	}
}

func TestDeletedReplyDoesNotReturnThread(t *testing.T) {
	h := newHarness(t)
	root := h.deliver("INBOX", "Dinner", "")
	h.sync()
	h.set(h.conversations()["Dinner"], func(s *ConversationState) { s.Workflow, s.Unread = WorkflowSettled, false })
	h.sync()
	h.deliver("INBOX", "Re: Dinner", root, imap.FlagDeleted)
	h.sync()
	h.sync()
	if c := h.conversations()["Dinner"]; c.Workflow != WorkflowSettled {
		t.Fatalf("a reply another client marked deleted must not return the thread, got %s", c.Workflow)
	}
}

func TestMutedInboxReplyStaysRead(t *testing.T) {
	h := newHarness(t)
	root := h.deliver("INBOX", "Dinner", "")
	h.sync()
	h.set(h.conversations()["Dinner"], func(s *ConversationState) { s.Unread, s.Muted = false, true })
	h.sync()
	h.deliver("INBOX", "Re: Dinner", root)
	h.sync()
	h.sync()
	if c := h.conversations()["Dinner"]; c.Unread || c.Workflow != WorkflowInbox {
		t.Fatalf("a reply to a read, muted thread must not make it unread: %s unread=%v", c.Workflow, c.Unread)
	}
}

func TestMutedReplyKeepsReadsFromOtherClients(t *testing.T) {
	h := newHarness(t)
	root := h.deliver("INBOX", "Dinner", "")
	h.sync()
	h.set(h.conversations()["Dinner"], func(s *ConversationState) { s.Muted = true })
	h.sync()
	// A reply arrives, and another client reads the whole thread before Mailern's next poll.
	h.deliver("INBOX", "Re: Dinner", root)
	markSeen(t, h, "INBOX", "Dinner", imap.FlagSeen)
	h.sync()
	h.sync()
	if inbox := h.mailbox("INBOX"); !slices.Contains(inbox["Dinner"], imap.FlagSeen) || !slices.Contains(inbox["Re: Dinner"], imap.FlagSeen) {
		t.Fatalf("Mailern must not undo reads made in another client: %v", inbox)
	}
}

func TestDeletedUnreadReplyDoesNotMakeThreadUnread(t *testing.T) {
	h := newHarness(t)
	root := h.deliver("INBOX", "Dinner", "")
	h.sync()
	h.set(h.conversations()["Dinner"], func(s *ConversationState) { s.Unread = false })
	h.sync()
	h.deliver("INBOX", "Re: Dinner", root, imap.FlagDeleted)
	h.sync()
	h.sync()
	if c := h.conversations()["Dinner"]; c.Unread {
		t.Fatal("a reply another client marked deleted must not make the thread unread")
	}
}

func TestSyncMapsMailboxesToWorkflow(t *testing.T) {
	h := newHarness(t)
	h.deliver("INBOX", "Dinner", "")
	h.deliver("Archive", "Receipt", "", imap.FlagSeen)
	h.deliver("Junk", "Prize", "")
	h.deliver("INBOX", "Starred", "", imap.FlagSeen, imap.FlagFlagged)
	h.sync()
	got := h.conversations()
	check := func(subject string, workflow Workflow, removal Role, unread, pinned bool) {
		t.Helper()
		c, ok := got[subject]
		if !ok {
			t.Fatalf("%s: missing", subject)
		}
		if c.Workflow != workflow || c.Removal != removal || c.Unread != unread || c.Pinned != pinned {
			t.Errorf("%s: got %s/%q unread=%v pinned=%v", subject, c.Workflow, c.Removal, c.Unread, c.Pinned)
		}
	}
	check("Dinner", WorkflowInbox, "", true, false)
	check("Receipt", WorkflowSettled, "", false, false)
	check("Prize", WorkflowSettled, RoleJunk, false, false)
	check("Starred", WorkflowInbox, "", false, true)
}

func TestSettleArchivesAndInboxRestores(t *testing.T) {
	h := newHarness(t)
	h.deliver("INBOX", "Dinner", "")
	h.sync()
	h.set(h.conversations()["Dinner"], func(s *ConversationState) { s.Workflow, s.Unread = WorkflowSettled, false })
	h.sync()
	archive := h.mailbox("Archive")
	if flags, ok := archive["Dinner"]; !ok || !slices.Contains(flags, imap.FlagSeen) {
		t.Fatalf("settle should archive the message as read, archive: %v", archive)
	}
	if _, ok := h.mailbox("INBOX")["Dinner"]; ok {
		t.Fatal("settled mail is still in the inbox")
	}
	c := h.conversations()["Dinner"]
	if c.Workflow != WorkflowSettled {
		t.Fatalf("settled conversation came back as %s", c.Workflow)
	}
	h.set(c, func(s *ConversationState) { s.Workflow = WorkflowInbox })
	h.sync()
	if _, ok := h.mailbox("INBOX")["Dinner"]; !ok {
		t.Fatal("restoring to Inbox should move the message back")
	}
}

func TestChangesFromOtherClientsAreAdopted(t *testing.T) {
	h := newHarness(t)
	h.deliver("INBOX", "Dinner", "")
	h.sync()
	// Another client archives the message and marks it read.
	c, _ := imapclient.DialInsecure(h.imap.Address(), nil)
	defer c.Close()
	c.Login(labAddress, "lab").Wait()
	c.Select("INBOX", nil).Wait()
	c.Store(imap.SeqSetNum(1), &imap.StoreFlags{Op: imap.StoreFlagsAdd, Flags: []imap.Flag{imap.FlagSeen}}, nil).Close()
	c.Move(imap.SeqSetNum(1), "Archive").Wait()
	h.sync()
	got := h.conversations()["Dinner"]
	if got.Workflow != WorkflowSettled || got.Unread {
		t.Fatalf("archive in another client should settle: %s unread=%v", got.Workflow, got.Unread)
	}
}

func TestSnoozeStaysInInboxAndReplyReturnsIt(t *testing.T) {
	h := newHarness(t)
	id := h.deliver("INBOX", "Dinner", "")
	h.sync()
	later := time.Now().Add(time.Hour)
	h.set(h.conversations()["Dinner"], func(s *ConversationState) {
		s.Workflow, s.SnoozedUntil, s.Unread = WorkflowSnoozed, &later, false
	})
	h.sync()
	if _, ok := h.mailbox("INBOX")["Dinner"]; !ok {
		t.Fatal("snoozed mail should stay in the server inbox")
	}
	if got := h.conversations()["Dinner"]; got.Workflow != WorkflowSnoozed {
		t.Fatalf("a sync should keep the snooze, got %s", got.Workflow)
	}
	h.deliver("INBOX", "Re: Dinner", id)
	h.sync()
	got := h.conversations()["Dinner"]
	if got.Workflow != WorkflowInbox || got.SnoozedUntil != nil || !got.Unread || len(got.Messages) != 2 {
		t.Fatalf("a reply should return the thread unread: %s until=%v unread=%v messages=%d",
			got.Workflow, got.SnoozedUntil, got.Unread, len(got.Messages))
	}
}

func TestDueSnoozeReturnsToInbox(t *testing.T) {
	h := newHarness(t)
	h.deliver("INBOX", "Dinner", "")
	h.sync()
	soon := time.Now().Add(50 * time.Millisecond)
	h.set(h.conversations()["Dinner"], func(s *ConversationState) { s.Workflow, s.SnoozedUntil = WorkflowSnoozed, &soon })
	h.sync()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	time.Sleep(100 * time.Millisecond)
	go h.service.WakeSnoozed(ctx)
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if got := h.conversations()["Dinner"]; got.Workflow == WorkflowInbox {
			if got.ReturnedFromSnoozeAt == nil {
				t.Fatal("a returned snooze should keep its return time")
			}
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("the snooze did not return")
}

func TestMutedReplyStaysSettled(t *testing.T) {
	h := newHarness(t)
	id := h.deliver("INBOX", "Dinner", "")
	h.sync()
	h.set(h.conversations()["Dinner"], func(s *ConversationState) { s.Workflow, s.Unread, s.Muted = WorkflowSettled, false, true })
	h.sync()
	h.deliver("INBOX", "Re: Dinner", id)
	h.sync()
	got := h.conversations()["Dinner"]
	if got.Workflow != WorkflowSettled || got.Unread {
		t.Fatalf("a muted thread should stay settled and read: %s unread=%v", got.Workflow, got.Unread)
	}
	if _, ok := h.mailbox("INBOX")["Re: Dinner"]; ok {
		t.Fatal("the muted reply should leave the inbox")
	}
}
