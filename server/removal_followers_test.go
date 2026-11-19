package main

import (
	"net/http"
	"testing"

	"github.com/google/uuid"
)

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
	if err := h.lab.Deliver(labAddress, "Sent", h.lab.Submitted[0]); err != nil {
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
