package main

import (
	"bufio"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"net/textproto"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestSubmissionEndsAtSMTPAcceptance(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		conn.SetDeadline(time.Now().Add(5 * time.Second))
		reader := textproto.NewReader(bufio.NewReader(conn))
		fmt.Fprint(conn, "220 localhost ESMTP\r\n")
		for {
			line, err := reader.ReadLine()
			if err != nil {
				return
			}
			if strings.EqualFold(line, "DATA") {
				fmt.Fprint(conn, "354 Send message\r\n")
				if _, err := reader.ReadDotBytes(); err == nil {
					fmt.Fprint(conn, "250 Accepted\r\n")
				}
				return
			}
			fmt.Fprint(conn, "250 OK\r\n")
		}
	}()
	endpoint := endpointFor(listener)
	store, err := OpenStore(filepath.Join(t.TempDir(), "state.json"))
	if err != nil {
		t.Fatal(err)
	}
	account := Account{store: store, cfg: AccountConfig{Address: labAddress, SMTP: &endpoint}}
	if err := account.submit(SendRequest{To: []string{"sam@example.com"}}, []byte("Subject: Hello\r\n\r\nHi")); err != nil {
		t.Fatalf("accepted delivery reported as failed: %v", err)
	}
}

func TestRestartAfterSMTPAcceptanceDoesNotResubmit(t *testing.T) {
	h := newHarness(t)
	h.sync()
	req := SendRequest{ID: "a2a16159-c8b5-47b0-8df8-d09fa58cccb0", ConversationID: "773d0952-7399-4227-91c4-438e25311b1b", To: []string{"sam@example.com"}, Subject: "Delivery"}
	raw, err := h.account.compose(req, h.account.messageID(req))
	if err != nil {
		t.Fatal(err)
	}
	if err := h.account.submit(req, raw); err != nil {
		t.Fatal(err)
	}
	// Reopen exactly at the boundary between SMTP acceptance and receipt persistence.
	store, err := OpenStore(h.account.store.path)
	if err != nil {
		t.Fatal(err)
	}
	restarted := NewAccount(h.account.cfg, store, time.Hour)
	if err := restarted.Send(req); err != uncertainDelivery || len(h.lab.Submitted) != 1 {
		t.Fatalf("restart after acceptance: %v, deliveries %d", err, len(h.lab.Submitted))
	}
}

func TestSentCopyAfterInterruptedSendKeepsClientIDs(t *testing.T) {
	h := newHarness(t)
	h.sync()
	req := SendRequest{ID: "d0f877cc-fd2d-4d45-b159-303799cf83e3", ConversationID: "8777e255-4038-4f3f-8f78-c4b2efcff783", To: []string{"sam@example.com"}, Subject: "Delivery"}
	raw, err := h.account.compose(req, h.account.messageID(req))
	if err != nil {
		t.Fatal(err)
	}
	if err := h.account.submit(req, raw); err != nil {
		t.Fatal(err)
	}
	if err := h.lab.Deliver(labAddress, "Sent", raw); err != nil {
		t.Fatal(err)
	}
	store, err := OpenStore(h.account.store.path)
	if err != nil {
		t.Fatal(err)
	}
	restarted := NewAccount(h.account.cfg, store, time.Hour)
	if err := restarted.Sync(); err != nil {
		t.Fatal(err)
	}
	if err := restarted.Send(req); err != nil {
		t.Fatal(err)
	}
	store.Read(func(st *State) {
		c := st.Conversations[req.ConversationID]
		if c == nil || len(st.Conversations) != 1 || len(c.Keys) != 1 || st.messages(c)[0].ID != req.ID || len(h.lab.Submitted) != 1 {
			t.Error("the synced Sent copy must resolve the original submission with its original IDs")
		}
	})
}

func TestRecoveredSentReplacesDeletedConversationInIncrementalSync(t *testing.T) {
	for _, syncFirst := range []bool{true, false} {
		t.Run(fmt.Sprintf("syncFirst=%t", syncFirst), func(t *testing.T) {
			h := newHarness(t)
			parent := h.deliver("Trash", "Fictional itinerary", "")
			h.sync()
			var initial syncResponse
			h.request("GET", "/v1/sync?since=0", nil, &initial)
			source := h.conversations()["Fictional itinerary"]
			req := SendRequest{ID: uuid.NewString(), ConversationID: source.ID, InReplyTo: parent, To: []string{"sam@example.com"}, Subject: "Re: Fictional itinerary"}
			raw, err := h.account.compose(req, h.account.messageID(req))
			if err != nil {
				t.Fatal(err)
			}
			if err := h.account.submit(req, raw); err != nil {
				t.Fatal(err)
			}
			if code := h.delete(source, RoleTrash); code != http.StatusNoContent {
				t.Fatalf("source delete returned %d", code)
			}
			h.sync()
			path := fmt.Sprintf("/v1/sync?since=%d", initial.Revision)
			var deleted syncResponse
			h.request("GET", path, nil, &deleted)
			if len(deleted.Deleted) != 1 || deleted.Deleted[0] != source.ID || len(deleted.Conversations) != 0 {
				t.Fatalf("expected only the source tombstone, got %+v", deleted)
			}
			if err := h.lab.Deliver(labAddress, "Sent", raw); err != nil {
				t.Fatal(err)
			}
			if syncFirst {
				h.sync()
			}
			if err := h.account.Send(req); err != nil {
				t.Fatal(err)
			}
			var recovered syncResponse
			h.request("GET", path, nil, &recovered)
			if len(recovered.Deleted) != 0 || len(recovered.Conversations) != 1 || recovered.Conversations[0].ID != source.ID {
				t.Fatalf("expected the recovered conversation without a tombstone, got %+v", recovered)
			}
			if messages := recovered.Conversations[0].Messages; len(messages) != 1 || messages[0].ID != req.ID || !messages[0].Outgoing || len(h.lab.Submitted) != 1 {
				t.Fatalf("expected the original outgoing message and one delivery, got %+v", messages)
			}
		})
	}
}

func TestQueuedSendCannotUseReplacementAccount(t *testing.T) {
	h := newHarness(t)
	old := h.account.cfg
	h.account.cfg.Username = "replacement@example.com"
	h.account.cfg.ID = mailboxAccountID(h.account.cfg)
	req := SendRequest{AccountID: mailboxAccountID(old), To: []string{"sam@example.com"}}
	if code := h.request("POST", "/v1/send", req, nil); code != 400 || len(h.lab.Submitted) != 0 {
		t.Fatalf("stale account accepted: status %d, deliveries %d", code, len(h.lab.Submitted))
	}
}

func TestAmbiguousDeliveryPreservesClientSubmission(t *testing.T) {
	response := httptest.NewRecorder()
	writeError(response, uncertainDelivery)
	if response.Code != 409 {
		t.Fatalf("ambiguous delivery returned status %d", response.Code)
	}
}

func TestUncertainReplyWithDeletingSource(t *testing.T) {
	h := newHarness(t)
	parent := h.deliver("INBOX", "Question", "")
	h.sync()
	thread := h.conversations()["Question"]
	req := SendRequest{ID: "a2a16159-c8b5-47b0-8df8-d09fa58cccb0", ConversationID: thread.ID, AccountID: h.account.cfg.ID, InReplyTo: parent, To: []string{"sam@example.com"}, Text: "Reply"}
	raw, err := h.account.compose(req, h.account.messageID(req))
	if err != nil {
		t.Fatal(err)
	}
	if err := h.account.submit(req, raw); err != nil {
		t.Fatal(err)
	}
	if err := h.account.store.Update(func(st *State) error {
		st.Conversations[thread.ID].Deleting = true
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if code := h.request("POST", "/v1/send", req, nil); code != 409 || len(h.lab.Submitted) != 1 {
		t.Fatalf("retry with pending delete: status %d, deliveries %d", code, len(h.lab.Submitted))
	}
}
