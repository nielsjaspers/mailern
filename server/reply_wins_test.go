package main

import (
	"fmt"
	"net/http"
	"slices"
	"testing"
	"time"

	"github.com/emersion/go-imap/v2"
	"github.com/emersion/go-imap/v2/imapclient"
	"github.com/google/uuid"
)

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

func TestSettleDoesNotHideAReplyThePhoneHasNotSeen(t *testing.T) {
	h := newHarness(t)
	root := h.deliver("INBOX", "Dinner", "")
	h.sync()
	seen := h.conversations()["Dinner"]
	h.deliver("INBOX", "Re: Dinner", root)
	h.sync()
	state := ConversationState{Fields: []string{"workflow", "unread"}, Workflow: WorkflowSettled,
		MessageIDs: []string{seen.Messages[0].ID}}
	if code := h.request("PUT", "/v1/conversations/"+seen.ID, state, nil); code != http.StatusOK {
		t.Fatalf("set state: %d", code)
	}
	h.sync()
	if c := h.conversations()["Dinner"]; c.Workflow != WorkflowInbox || !c.Unread || len(c.Messages) != 2 {
		t.Fatalf("the unseen reply should keep the thread in Inbox, unread: %s unread=%v", c.Workflow, c.Unread)
	}
	if h.count("INBOX") == 0 {
		t.Fatal("the unseen reply should stay in the server inbox")
	}
}

func TestAddedAliasReclassifiesStoredMail(t *testing.T) {
	h := newHarness(t)
	const alias = "morgan@alias.example.com"
	raw := LabMessage("Morgan <"+alias+">", "sam@example.com", "Sent elsewhere", "Hi.", "", time.Now())
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

func TestUnseenReplyDoesNotStopSettlingAMutedThread(t *testing.T) {
	h := newHarness(t)
	root := h.deliver("INBOX", "Dinner", "")
	h.sync()
	seen := h.conversations()["Dinner"]
	h.deliver("INBOX", "Re: Dinner", root)
	h.sync()
	state := ConversationState{Fields: []string{"workflow", "unread", "muted"}, Workflow: WorkflowSettled, Muted: true,
		MessageIDs: []string{seen.Messages[0].ID}}
	if code := h.request("PUT", "/v1/conversations/"+seen.ID, state, nil); code != http.StatusOK {
		t.Fatalf("set state: %d", code)
	}
	h.sync()
	if c := h.conversations()["Dinner"]; c.Workflow != WorkflowSettled || c.Unread {
		t.Fatalf("a muted thread should settle despite an unseen reply: %s unread=%v", c.Workflow, c.Unread)
	}
}

func TestUnseenReplyStopsAStaleTrash(t *testing.T) {
	h := newHarness(t)
	root := h.deliver("INBOX", "Dinner", "")
	h.sync()
	seen := h.conversations()["Dinner"]
	h.deliver("INBOX", "Re: Dinner", root)
	h.sync()
	state := ConversationState{Fields: []string{"removal"}, Workflow: WorkflowInbox, Removal: RoleTrash,
		MessageIDs: []string{seen.Messages[0].ID}}
	if code := h.request("PUT", "/v1/conversations/"+seen.ID, state, nil); code != http.StatusOK {
		t.Fatalf("set state: %d", code)
	}
	h.sync()
	if c := h.conversations()["Dinner"]; c.Removal != "" || h.count("Trash") != 0 {
		t.Fatalf("an unseen reply must not go to Trash: removal %q, Trash %d", c.Removal, h.count("Trash"))
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
	c, err := imapclient.DialInsecure(h.lab.IMAP.Address(), nil)
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

func TestRemovedAliasKeepsSentMailOutgoing(t *testing.T) {
	h := newHarness(t)
	const alias = "morgan@alias.example.com"
	h.account.cfg.Aliases = []string{alias}
	raw := LabMessage("Morgan <"+alias+">", "sam@example.com", "Sent as alias", "Hi.", "", time.Now())
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

func TestPhoneWakeKeepsTheReturnTime(t *testing.T) {
	h := newHarness(t)
	h.deliver("INBOX", "Dinner", "")
	h.sync()
	soon := time.Now().Add(time.Second).Truncate(time.Second)
	h.set(h.conversations()["Dinner"], func(s *ConversationState) { s.Workflow, s.SnoozedUntil = WorkflowSnoozed, &soon })
	time.Sleep(time.Until(soon) + 100*time.Millisecond)
	// The phone wakes the snooze before the service's timer does.
	h.set(h.conversations()["Dinner"], func(s *ConversationState) { s.Workflow, s.SnoozedUntil = WorkflowInbox, nil })
	if c := h.conversations()["Dinner"]; c.ReturnedFromSnoozeAt == nil || !c.ReturnedFromSnoozeAt.Equal(soon) {
		t.Fatalf("an early wake should keep its return time, got %v", c.ReturnedFromSnoozeAt)
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

func markSeen(t *testing.T, h *harness, mailbox, subject string, flag imap.Flag) {
	t.Helper()
	c, err := imapclient.DialInsecure(h.lab.IMAP.Address(), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	c.Login(labAddress, "lab").Wait()
	c.Select(mailbox, nil).Wait()
	found, _ := c.UIDSearch(&imap.SearchCriteria{Header: []imap.SearchCriteriaHeaderField{{Key: "Subject", Value: subject}}}, nil).Wait()
	c.Store(imap.UIDSetNum(found.AllUIDs()...), &imap.StoreFlags{Op: imap.StoreFlagsAdd, Flags: []imap.Flag{flag}}, nil).Close()
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

func TestReplyDatedBeforeItsParentJoinsTheThread(t *testing.T) {
	h := newHarness(t)
	now := time.Now()
	parent := LabMessage("Sam <sam@example.com>", labAddress, "Plans", "Free Friday?", "", now)
	reply := LabMessage("Alex <alex@example.com>", labAddress, "Re: Plans", "Yes.", labMessageID(parent), now.Add(-2*time.Minute))
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
	other, err := imapclient.DialInsecure(h.lab.IMAP.Address(), nil)
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

func TestReplyToReachesThePhone(t *testing.T) {
	h := newHarness(t)
	raw := "From: Form <form@example.com>\r\nReply-To: visitor@example.org\r\nTo: " + labAddress + "\r\nSubject: Contact\r\n" +
		"Message-ID: <contact@example.com>\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nHello\r\n"
	if err := h.lab.Deliver(labAddress, "INBOX", []byte(raw)); err != nil {
		t.Fatal(err)
	}
	h.sync()
	var resp syncResponse
	h.request("GET", "/v1/sync?since=0", nil, &resp)
	if m := resp.Conversations[0].Messages[0]; len(m.ReplyTo) != 1 || m.ReplyTo[0] != "visitor@example.org" {
		t.Fatalf("the phone should learn Reply-To, got %v", m.ReplyTo)
	}
}
