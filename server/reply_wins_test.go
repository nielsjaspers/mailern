package main

import (
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
