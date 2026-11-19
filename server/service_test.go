package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"slices"
	"testing"
	"time"

	"github.com/emersion/go-imap/v2"
	"github.com/emersion/go-imap/v2/imapclient"
	"github.com/google/uuid"
)

const labAddress = "morgan@lab.example.com"

type harness struct {
	t       *testing.T
	lab     *MailLab
	service *Service
	account *Account
	http    *httptest.Server
	since   uint64
}

// newHarness starts a service over a fictional mail server. Sync passes run only when a test calls sync,
// so each step sees a known server state.
func newHarness(t *testing.T) *harness {
	lab, err := StartMailLab(labAddress)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(lab.Close)
	store, err := OpenStore(filepath.Join(t.TempDir(), "state.json"))
	if err != nil {
		t.Fatal(err)
	}
	account := NewAccount(lab.Account("lab", "Lab", labAddress), store, 90*24*time.Hour)
	service := &Service{store: store, accounts: []*Account{account}}
	server := httptest.NewServer(service.Handler())
	t.Cleanup(server.Close)
	return &harness{t: t, lab: lab, service: service, account: account, http: server}
}

func (h *harness) deliver(mailbox, subject, replyTo string, flags ...imap.Flag) string {
	h.t.Helper()
	raw := LabMessage("Sam Rivera <sam@example.com>", labAddress, subject, "Hello from the lab.", replyTo, time.Now())
	if err := h.lab.Deliver(labAddress, mailbox, raw, flags...); err != nil {
		h.t.Fatal(err)
	}
	return labMessageID(raw)
}

func (h *harness) sync() {
	h.t.Helper()
	if err := h.account.Sync(); err != nil {
		h.t.Fatal(err)
	}
}

// conversations returns every conversation the phone would hold, keyed by subject.
func (h *harness) conversations() map[string]wireConversation {
	h.t.Helper()
	var resp syncResponse
	h.request("GET", "/v1/sync?since=0", nil, &resp)
	out := map[string]wireConversation{}
	for _, c := range resp.Conversations {
		out[c.Subject] = c
	}
	return out
}

func (h *harness) request(method, path string, body any, out any) int {
	h.t.Helper()
	var payload bytes.Buffer
	if body != nil {
		json.NewEncoder(&payload).Encode(body)
	}
	req, _ := http.NewRequest(method, h.http.URL+path, &payload)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		h.t.Fatal(err)
	}
	defer resp.Body.Close()
	if out != nil && resp.StatusCode < 300 {
		if err := json.NewDecoder(resp.Body).Decode(out); err != nil {
			h.t.Fatal(err)
		}
	}
	return resp.StatusCode
}

func (h *harness) set(c wireConversation, change func(*ConversationState)) {
	h.t.Helper()
	state := ConversationState{Workflow: c.Workflow, SnoozedUntil: c.SnoozedUntil, Removal: c.Removal,
		Unread: c.Unread, Pinned: c.Pinned, Muted: c.Muted}
	change(&state)
	if c.Workflow != state.Workflow || !sameTime(c.SnoozedUntil, state.SnoozedUntil) {
		state.Fields = append(state.Fields, "workflow")
	}
	if c.Removal != state.Removal {
		state.Fields = append(state.Fields, "removal")
	}
	if c.Unread != state.Unread {
		state.Fields = append(state.Fields, "unread")
	}
	if c.Pinned != state.Pinned {
		state.Fields = append(state.Fields, "pinned")
	}
	if c.Muted != state.Muted {
		state.Fields = append(state.Fields, "muted")
	}
	if code := h.request("PUT", "/v1/conversations/"+c.ID, state, nil); code != http.StatusOK {
		h.t.Fatalf("set state: %d", code)
	}
}

// mailbox lists the subjects and flags in one lab mailbox, read with a separate client the way another
// mail app would see them.
func (h *harness) mailbox(name string) map[string][]imap.Flag {
	h.t.Helper()
	c, err := imapclient.DialInsecure(h.lab.IMAP.Address(), nil)
	if err != nil {
		h.t.Fatal(err)
	}
	defer c.Close()
	if err := c.Login(labAddress, "lab").Wait(); err != nil {
		h.t.Fatal(err)
	}
	sel, err := c.Select(name, nil).Wait()
	if err != nil {
		h.t.Fatal(err)
	}
	out := map[string][]imap.Flag{}
	if sel.NumMessages == 0 {
		return out
	}
	msgs, err := c.Fetch(imap.SeqSetNum(seqRange(sel.NumMessages)...), &imap.FetchOptions{Envelope: true, Flags: true}).Collect()
	if err != nil {
		h.t.Fatal(err)
	}
	for _, m := range msgs {
		out[m.Envelope.Subject] = m.Flags
	}
	return out
}

func seqRange(n uint32) []uint32 {
	out := make([]uint32, n)
	for i := range out {
		out[i] = uint32(i + 1)
	}
	return out
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
	c, _ := imapclient.DialInsecure(h.lab.IMAP.Address(), nil)
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

func (h *harness) delete(c wireConversation, target Role) int {
	h.t.Helper()
	ids := make([]string, 0, len(c.Messages))
	for _, m := range c.Messages {
		ids = append(ids, m.ID)
	}
	return h.request("DELETE", "/v1/conversations/"+c.ID, map[string]any{
		"messageIDs": ids, "expectedWorkflow": c.Workflow, "expectedRemoval": c.Removal, "removal": target,
	}, nil)
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

func TestDeleteOutsideTrashIsRefused(t *testing.T) {
	h := newHarness(t)
	h.deliver("INBOX", "Dinner", "")
	h.sync()
	if code := h.delete(h.conversations()["Dinner"], RoleInbox); code != http.StatusUnprocessableEntity {
		t.Fatalf("deleting inbox mail should fail, got %d", code)
	}
}

func TestDeleteRejectsStaleConfirmation(t *testing.T) {
	for _, change := range []string{"reply", "different ID", "restore", "junk"} {
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
	if len(h.lab.Submitted) != 1 {
		t.Fatalf("a retried send should go out once, went out %d times", len(h.lab.Submitted))
	}
	if !bytes.Contains(h.lab.Submitted[0], []byte("In-Reply-To: "+parent)) {
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
	if len(h.lab.Submitted) != 1 {
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

func TestReconfiguredMailboxDropsOldMailFromSync(t *testing.T) {
	h := newHarness(t)
	h.deliver("INBOX", "Old account", "")
	h.sync()
	var before syncResponse
	h.request("GET", "/v1/sync?since=0", nil, &before)
	id := before.Conversations[0].ID
	err := h.account.store.Update(func(st *State) error {
		st.configureAccounts([]AccountConfig{{ID: "lab", Address: "new@example.com", IMAP: h.account.cfg.IMAP}})
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	var after syncResponse
	h.request("GET", fmt.Sprintf("/v1/sync?since=%d", before.Revision), nil, &after)
	if !slices.Contains(after.Deleted, id) || len(h.conversations()) != 0 {
		t.Fatal("reconfigured mailbox still exposes old mail")
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
	if _, ok := h.mailbox("Sent")[req.Subject]; !ok || len(h.lab.Submitted) != 1 {
		t.Fatal("retry must file the accepted message without a second SMTP delivery")
	}
}
