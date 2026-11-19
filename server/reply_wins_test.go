package main

import (
	"net/http"
	"testing"
	"time"

	"github.com/emersion/go-imap/v2"
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
