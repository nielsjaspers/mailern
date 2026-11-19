package main

import "testing"

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
