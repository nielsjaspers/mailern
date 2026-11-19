package mailsync

import (
	"bytes"
	"fmt"
	"net/http"
	"testing"
	"time"
)

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

func TestSyncWaitsForChanges(t *testing.T) {
	h := newHarness(t)
	h.sync()
	var first syncResponse
	h.request("GET", "/v1/sync?since=0", nil, &first)
	done := make(chan syncResponse)
	go func() {
		var resp syncResponse
		h.request("GET", fmt.Sprintf("/v1/sync?since=%d&wait=5", first.Revision), nil, &resp)
		done <- resp
	}()
	time.Sleep(100 * time.Millisecond)
	h.deliver("INBOX", "Dinner", "")
	h.sync()
	select {
	case resp := <-done:
		if len(resp.Conversations) != 1 || resp.Reset {
			t.Fatalf("expected one new conversation, got %+v", resp)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("the waiting sync did not return")
	}
}

func TestHTMLIsFetchedOnDemand(t *testing.T) {
	h := newHarness(t)
	raw := "From: News <news@example.com>\r\nTo: " + labAddress + "\r\nSubject: Weekly\r\nMessage-ID: <weekly@example.com>\r\n" +
		"MIME-Version: 1.0\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<p>Hello <b>there</b></p>\r\n"
	h.lab.Deliver(labAddress, "INBOX", []byte(raw))
	h.sync()
	m := h.conversations()["Weekly"].Messages[0]
	if !m.HasHTML || m.Body != "Hello there" {
		t.Fatalf("HTML-only mail should have text made from it: %+v", m)
	}
	resp, err := http.Get(h.http.URL + "/v1/messages/" + m.ID + "/html")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.Header.Get("Content-Type") != "text/plain; charset=utf-8" || resp.Header.Get("X-Content-Type-Options") != "nosniff" || resp.Header.Get("Cache-Control") != "no-store" {
		t.Fatalf("unsafe mail response headers: %v", resp.Header)
	}
	var body bytes.Buffer
	body.ReadFrom(resp.Body)
	if !bytes.Contains(body.Bytes(), []byte("<b>there</b>")) {
		t.Fatalf("expected the HTML part, got %q", body.String())
	}
}

func TestHTMLRejectsStaleMailboxIdentity(t *testing.T) {
	h := newHarness(t)
	h.deliver("INBOX", "Original", "")
	h.sync()
	var at location
	var validity uint32
	h.account.store.Read(func(st *State) {
		account := st.Accounts[h.account.cfg.ID]
		for _, m := range account.Messages {
			at, _ = placeOf(m)
			validity = account.UIDValidity[at.role]
		}
	})
	if _, err := h.account.FetchHTML(at, "INBOX", validity+1); err != errNotFound {
		t.Fatalf("stale mailbox identity returned %v", err)
	}
}

func TestDeliveryAddressReachesThePhone(t *testing.T) {
	h := newHarness(t)
	raw := "Delivered-To: gh@example.org\r\nFrom: List <list@example.com>\r\nTo: list@example.com\r\nSubject: Release\r\n" +
		"Message-ID: <release@example.com>\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nHello\r\n"
	if err := h.lab.Deliver(labAddress, "INBOX", []byte(raw)); err != nil {
		t.Fatal(err)
	}
	h.sync()
	var resp syncResponse
	h.request("GET", "/v1/sync?since=0", nil, &resp)
	if m := resp.Conversations[0].Messages[0]; len(m.DeliveredTo) != 1 || m.DeliveredTo[0] != "gh@example.org" {
		t.Fatalf("the phone should learn where the message was delivered, got %v", m.DeliveredTo)
	}
}
