package mailsync

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/textproto"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/emersion/go-imap/v2"
	"github.com/google/uuid"
	"github.com/nielsjaspers/mailern/server/internal/maillab"
)

func TestSentFilingFailureAllowsIncomingMail(t *testing.T) {
	h := newHarness(t)
	h.sync()
	if err := h.account.store.Update(func(st *State) error {
		st.account(h.account.cfg.ID).Receipts = map[string][]byte{"<pending@example.com>": []byte("Subject: Pending\r\n\r\nhello")}
		st.Revision++
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	// The provider has an inbox but no Sent folder in which to file the pending copy.
	if err := h.lab.User(labAddress).Delete("Sent"); err != nil {
		t.Fatal(err)
	}
	h.account.disconnect()
	h.deliver("INBOX", "New mail", "", imap.FlagSeen)
	if err := h.account.Sync(); err == nil {
		t.Fatal("expected the pending Sent filing to fail")
	}
	if _, ok := h.conversations()["New mail"]; !ok {
		t.Fatal("filing blocked incoming mail")
	}
}

func TestAccountSendsAndRecognizesAliases(t *testing.T) {
	h := newHarness(t)
	const alias = "morgan@alias.example.com"
	h.account.cfg.Aliases = []string{alias}
	parent := h.deliver("INBOX", "Plans", "")
	// Mail sent as the alias from another client counts as the user's own.
	other := maillab.Message("Morgan <"+alias+">", "sam@example.com", "Sent elsewhere", "Hi.", "", time.Now())
	if err := h.lab.Deliver(labAddress, "Sent", other, imap.FlagSeen); err != nil {
		t.Fatal(err)
	}
	h.sync()
	if m := h.conversations()["Sent elsewhere"].Messages[0]; !m.Outgoing {
		t.Fatal("mail from an alias should be outgoing")
	}
	c := h.conversations()["Plans"]
	req := SendRequest{ID: uuid.NewString(), ConversationID: c.ID, AccountID: "lab", To: []string{"sam@example.com"},
		Subject: "Re: Plans", Text: "Yes.", InReplyTo: parent, References: []string{parent}, From: "Morgan@Alias.example.com"}
	if code := h.request("POST", "/v1/send", req, nil); code != http.StatusNoContent {
		t.Fatalf("send: %d", code)
	}
	if len(h.lab.Submitted()) != 1 || !bytes.Contains(h.lab.Submitted()[0], []byte("<"+alias+">")) {
		t.Fatal("the reply should go out from the alias")
	}
	if !bytes.Contains(h.lab.Submitted()[0], []byte("Message-Id: <"+req.ID+"@alias.example.com>")) {
		t.Fatalf("the Message-ID should use the alias's domain:\n%s", h.lab.Submitted()[0])
	}
	h.sync()
	if m := h.conversations()["Plans"].Messages[1]; !m.Outgoing || m.Address != alias {
		t.Fatalf("the sent reply should be outgoing from the alias, got %+v", m)
	}
	req.ID, req.From = uuid.NewString(), "stranger@example.com"
	if code := h.request("POST", "/v1/send", req, nil); code != http.StatusUnprocessableEntity {
		t.Fatalf("an address outside the account must be refused, got %d", code)
	}
	var resp syncResponse
	h.request("GET", "/v1/sync?since=0", nil, &resp)
	if len(resp.Accounts) != 1 || len(resp.Accounts[0].Aliases) != 1 || resp.Accounts[0].Aliases[0] != alias {
		t.Fatalf("the phone should learn the aliases, got %+v", resp.Accounts)
	}
}

func TestRetryAcceptedDraftAfterRemovingAlias(t *testing.T) {
	h := newHarness(t)
	h.account.cfg.Aliases = []string{"morgan@alias.example.com"}
	req := SendRequest{ID: uuid.NewString(), ConversationID: uuid.NewString(), AccountID: "lab", To: []string{"sam@example.com"}, From: h.account.cfg.Aliases[0]}
	if code := h.request("POST", "/v1/send", req, nil); code != 204 {
		t.Fatalf("initial send: %d", code)
	}
	h.account.cfg.Aliases = nil
	for _, address := range []string{req.From, labAddress} {
		req.From = address
		if code := h.request("POST", "/v1/send", req, nil); code != 204 || len(h.lab.Submitted()) != 1 {
			t.Fatalf("retry: status %d, deliveries %d", code, len(h.lab.Submitted()))
		}
	}
}

func TestProviderConnectionRefusedIsConfirmedUnsent(t *testing.T) {
	for _, protocol := range []string{"imap", "smtp"} {
		t.Run(protocol, func(t *testing.T) {
			h := newHarness(t)
			socket, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			endpoint := endpointFor(socket)
			socket.Close()
			if protocol == "smtp" {
				h.account.cfg.SMTP = &endpoint
			} else {
				h.account.cfg.IMAP = &endpoint
			}
			req := SendRequest{ID: uuid.NewString(), ConversationID: uuid.NewString(), AccountID: "lab", To: []string{"sam@example.com"}}
			body, err := json.Marshal(req)
			if err != nil {
				t.Fatal(err)
			}
			resp, err := h.http.Client().Post(h.http.URL+"/v1/send", "application/json", bytes.NewReader(body))
			if err != nil {
				t.Fatal(err)
			}
			defer resp.Body.Close()
			if resp.StatusCode != 503 || resp.Header.Get("Mailern-Submission") != "not-accepted" || len(h.lab.Submitted()) != 0 {
				t.Fatalf("unexpected submission result: %d %q", resp.StatusCode, resp.Header.Get("Mailern-Submission"))
			}
		})
	}
}

func TestSubmissionEndsAtSMTPAcceptance(t *testing.T) {
	for _, code := range []int{250, 251} {
		t.Run(fmt.Sprint(code), func(t *testing.T) {
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
							fmt.Fprintf(conn, "%d Reply\r\n", code)
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
			err = account.submit(SendRequest{To: []string{"sam@example.com"}}, []byte("Subject: Hello\r\n\r\nHi"))
			if code == 250 && err != nil {
				t.Fatalf("accepted delivery reported as failed: %v", err)
			}
			if code == 251 {
				var pending bool
				account.store.Read(func(st *State) { pending = len(st.account(account.cfg.ID).Submitting) == 1 })
				// The phone must keep retrying, so the answer is not the final one.
				if !errors.Is(err, uncertainDelivery) || err == uncertainDelivery || !pending {
					t.Fatalf("unexpected final reply lost submission: %v, pending %v", err, pending)
				}
			}
		})
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
	if err := restarted.Send(req); err != uncertainDelivery || len(h.lab.Submitted()) != 1 {
		t.Fatalf("restart after acceptance: %v, deliveries %d", err, len(h.lab.Submitted()))
	}
}

func TestSentCopyAfterInterruptedSendKeepsClientIDs(t *testing.T) {
	h := newHarness(t)
	const alias = "morgan@old.example.com"
	h.account.cfg.Aliases = []string{alias}
	h.sync()
	req := SendRequest{From: alias, ID: "d0f877cc-fd2d-4d45-b159-303799cf83e3", ConversationID: "8777e255-4038-4f3f-8f78-c4b2efcff783", To: []string{"sam@example.com"}, Subject: "Delivery"}
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
	h.account.cfg.Aliases = nil
	restarted := NewAccount(h.account.cfg, store, time.Hour)
	if err := restarted.Sync(); err != nil {
		t.Fatal(err)
	}
	if err := restarted.Send(req); err != nil {
		t.Fatal(err)
	}
	store.Read(func(st *State) {
		c := st.Conversations[req.ConversationID]
		if c == nil || len(st.Conversations) != 1 || len(c.Keys) != 1 || st.messages(c)[0].ID != req.ID || !st.messages(c)[0].Outgoing || len(h.lab.Submitted()) != 1 {
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
			if messages := recovered.Conversations[0].Messages; len(messages) != 1 || messages[0].ID != req.ID || !messages[0].Outgoing || len(h.lab.Submitted()) != 1 {
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
	body, err := json.Marshal(req)
	if err != nil {
		t.Fatal(err)
	}
	response, err := h.http.Client().Post(h.http.URL+"/v1/send", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != 400 || response.Header.Get("Mailern-Submission") != "" || len(h.lab.Submitted()) != 0 {
		t.Fatalf("unknown account must leave earlier submission unresolved: status %d, marker %q", response.StatusCode, response.Header.Get("Mailern-Submission"))
	}
}

func TestAmbiguousDeliveryPreservesClientSubmission(t *testing.T) {
	response := httptest.NewRecorder()
	writeError(response, uncertainDelivery)
	if response.Code != 409 || response.Header().Get("Mailern-Submission") != "unconfirmable" {
		t.Fatalf("ambiguous delivery returned status %d, marker %q", response.Code, response.Header().Get("Mailern-Submission"))
	}
	// A failed check can still confirm on a retry, so the phone keeps retrying.
	retry := httptest.NewRecorder()
	writeError(retry, errors.Join(uncertainDelivery, errors.New("imap: connection reset")))
	if retry.Code != 409 || retry.Header().Get("Mailern-Submission") != "" {
		t.Fatalf("a failed check returned status %d, marker %q", retry.Code, retry.Header().Get("Mailern-Submission"))
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
	if code := h.request("POST", "/v1/send", req, nil); code != 409 || len(h.lab.Submitted()) != 1 {
		t.Fatalf("retry with pending delete: status %d, deliveries %d", code, len(h.lab.Submitted()))
	}
}

func TestSendRepliesOnceAndFilesSent(t *testing.T) {
	h := newHarness(t)
	parent := h.deliver("INBOX", "Dinner", "")
	h.sync()
	c := h.conversations()["Dinner"]
	req := SendRequest{ID: uuid.NewString(), ConversationID: c.ID, AccountID: "lab", To: []string{"sam@example.com"},
		Subject: "Re: Dinner", Text: "Sounds good.", InReplyTo: parent, References: []string{parent}}
	for range 2 {
		if code := h.request("POST", "/v1/send", req, nil); code != http.StatusNoContent {
			t.Fatalf("send: %d", code)
		}
	}
	if len(h.lab.Submitted()) != 1 {
		t.Fatalf("a retried send should go out once, went out %d times", len(h.lab.Submitted()))
	}
	if !bytes.Contains(h.lab.Submitted()[0], []byte("In-Reply-To: "+parent)) {
		t.Fatal("the reply should answer its parent")
	}
	h.sync()
	if _, ok := h.mailbox("Sent")["Re: Dinner"]; !ok {
		t.Fatal("the account saves sent mail, so Sent should hold a copy")
	}
	got := h.conversations()["Dinner"]
	if len(got.Messages) != 2 || got.Messages[1].ID != req.ID || !got.Messages[1].Outgoing {
		t.Fatalf("the sent reply should join its thread with the draft's ID: %+v", got.Messages)
	}
	// A new service without the record finds the Sent copy instead of sending again.
	store, _ := OpenStore(filepath.Join(t.TempDir(), "state.json"))
	fresh := NewAccount(h.account.cfg, store, time.Hour)
	if err := fresh.Send(req); err != nil {
		t.Fatal(err)
	}
	if len(h.lab.Submitted()) != 1 {
		t.Fatal("a send found in Sent must not go out again")
	}
}

func TestNewMessageStartsItsConversation(t *testing.T) {
	h := newHarness(t)
	h.sync()
	req := SendRequest{ID: uuid.NewString(), ConversationID: uuid.NewString(), AccountID: "lab",
		To: []string{"alex@example.org"}, Subject: "Plans", Text: "Are you free?"}
	if code := h.request("POST", "/v1/send", req, nil); code != http.StatusNoContent {
		t.Fatalf("send: %d", code)
	}
	h.sync()
	got := h.conversations()["Plans"]
	if got.ID != req.ConversationID || got.Workflow != WorkflowSettled || len(got.Messages) != 1 {
		t.Fatalf("a new message should keep the phone's conversation ID and settle: %+v", got)
	}
}

func TestAcceptedMailFilesAfterReceiptWriteRecovers(t *testing.T) {
	h := newHarness(t)
	h.sync()
	store := h.account.store
	path := store.path
	store.path = t.TempDir() // rename cannot replace the directory
	req := SendRequest{ID: uuid.NewString(), ConversationID: uuid.NewString(), AccountID: "lab",
		To: []string{"alex@example.org"}, Subject: "One delivery", Text: "Hello"}
	if err := h.account.Send(req); err == nil {
		t.Fatal("expected receipt write to fail")
	}
	store.path = path
	if err := h.account.Send(req); err != nil {
		t.Fatal(err)
	}
	h.sync()
	if _, ok := h.mailbox("Sent")[req.Subject]; !ok || len(h.lab.Submitted()) != 1 {
		t.Fatal("retry must file the accepted message without a second SMTP delivery")
	}
}

func TestUnsavedSubmissionRecordIsConfirmedUnsent(t *testing.T) {
	h := newHarness(t)
	h.sync()
	dir := filepath.Dir(h.account.store.path)
	if err := os.Chmod(dir, 0o500); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(dir, 0o700) })
	req := SendRequest{ID: uuid.NewString(), ConversationID: uuid.NewString(), AccountID: "lab", To: []string{"sam@example.com"}}
	body, err := json.Marshal(req)
	if err != nil {
		t.Fatal(err)
	}
	resp, err := h.http.Client().Post(h.http.URL+"/v1/send", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 503 || resp.Header.Get("Mailern-Submission") != "not-accepted" || len(h.lab.Submitted()) != 0 {
		t.Fatalf("a send whose record could not be saved never reached the provider, got %d %q",
			resp.StatusCode, resp.Header.Get("Mailern-Submission"))
	}
}

func TestOversizedSendIsNotAccepted(t *testing.T) {
	h := newHarness(t)
	body := `{"attachments":[{"data":"` + strings.Repeat("A", 41<<20) + `"}]}`
	response, err := h.http.Client().Post(h.http.URL+"/v1/send", "application/json", strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	message, _ := io.ReadAll(response.Body)
	if response.StatusCode != 400 || response.Header.Get("Mailern-Submission") != "not-accepted" || !strings.Contains(string(message), "too large") {
		t.Fatalf("oversized send: status %d, marker %q, %s", response.StatusCode, response.Header.Get("Mailern-Submission"), message)
	}
}
