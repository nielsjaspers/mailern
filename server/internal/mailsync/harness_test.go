package mailsync

import (
	"bytes"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"github.com/emersion/go-imap/v2"
	"github.com/emersion/go-imap/v2/imapclient"
	"github.com/emersion/go-imap/v2/imapserver"
	"github.com/nielsjaspers/mailern/server/internal/maillab"
)

func restartCopyMoveAccount(t *testing.T, h *harness) {
	t.Helper()
	h.account.disconnect()
	store, err := OpenStore(h.account.store.path)
	if err != nil {
		t.Fatal(err)
	}
	h.account = NewAccount(h.account.cfg, store, h.account.window)
}

func (h *harness) count(mailbox string) uint32 {
	h.t.Helper()
	c, err := imapclient.DialInsecure(h.imap.Address(), nil)
	if err != nil {
		h.t.Fatal(err)
	}
	defer c.Close()
	if err := c.Login(labAddress, "lab").Wait(); err != nil {
		h.t.Fatal(err)
	}
	status, err := c.Status(mailbox, &imap.StatusOptions{NumMessages: true}).Wait()
	if err != nil {
		h.t.Fatal(err)
	}
	return *status.NumMessages
}

func serveProvider(t *testing.T, h *harness, caps imap.CapSet, wrap func(imapserver.Session) imapserver.Session) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	server := imapserver.New(&imapserver.Options{
		Caps: caps, InsecureAuth: true, Logger: maillab.QuietLogger{},
		NewSession: func(*imapserver.Conn) (imapserver.Session, *imapserver.GreetingData, error) {
			session := h.lab.NewSession()
			if wrap != nil {
				session = wrap(session)
			}
			return session, nil, nil
		},
	})
	go server.Serve(listener)
	t.Cleanup(func() { server.Close() })
	h.imap = endpointFor(listener)
	h.account.cfg.IMAP = &h.imap
}

func appendOldProviderMail(t *testing.T, h *harness, mailbox, subject string) {
	t.Helper()
	date := time.Now().Add(-200 * 24 * time.Hour)
	raw := maillab.Message("sam@example.com", labAddress, subject, "Hello.", "", date)
	if _, err := h.lab.User(labAddress).Append(mailbox, bytes.NewReader(raw), &imap.AppendOptions{Time: date}); err != nil {
		t.Fatal(err)
	}
}

func markSeen(t *testing.T, h *harness, mailbox, subject string, flag imap.Flag) {
	t.Helper()
	c, err := imapclient.DialInsecure(h.imap.Address(), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	c.Login(labAddress, "lab").Wait()
	c.Select(mailbox, nil).Wait()
	found, _ := c.UIDSearch(&imap.SearchCriteria{Header: []imap.SearchCriteriaHeaderField{{Key: "Subject", Value: subject}}}, nil).Wait()
	c.Store(imap.UIDSetNum(found.AllUIDs()...), &imap.StoreFlags{Op: imap.StoreFlagsAdd, Flags: []imap.Flag{flag}}, nil).Close()
}

const labAddress = "morgan@lab.example.com"

type harness struct {
	t   *testing.T
	lab *maillab.Lab
	// imap is where the account reaches the lab. Tests that wrap the lab in their own IMAP server change it.
	imap    Endpoint
	service *Service
	account *Account
	http    *httptest.Server
	since   uint64
}

// newHarness starts a service over a fictional mail server. Sync passes run only when a test calls sync,
// so each step sees a known server state.
func newHarness(t *testing.T) *harness {
	lab, err := maillab.Start(labAddress)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(lab.Close)
	store, err := OpenStore(filepath.Join(t.TempDir(), "state.json"))
	if err != nil {
		t.Fatal(err)
	}
	account := NewAccount(labAccount(lab, "lab", "Lab", labAddress), store, 90*24*time.Hour)
	service := &Service{store: store, accounts: []*Account{account}}
	server := httptest.NewServer(service.Handler())
	t.Cleanup(server.Close)
	return &harness{t: t, lab: lab, imap: *account.cfg.IMAP, service: service, account: account, http: server}
}

// labAccount configures an account for one of the lab's addresses.
func labAccount(lab *maillab.Lab, id, name, address string) AccountConfig {
	imapEndpoint, smtpEndpoint := labEndpoint(lab.IMAPAddr), labEndpoint(lab.SMTPAddr)
	appendSent := true
	return AccountConfig{ID: id, Name: name, Address: address, Provider: "imap", Username: address, SenderName: "Morgan",
		IMAP: &imapEndpoint, SMTP: &smtpEndpoint, AppendSent: &appendSent, Password: maillab.Password}
}

func labEndpoint(addr string) Endpoint {
	host, port, _ := net.SplitHostPort(addr)
	n, _ := strconv.Atoi(port)
	return Endpoint{Host: host, Port: n, Security: "none"}
}

// endpointFor reaches a test's own IMAP server on the loopback interface.
func endpointFor(l net.Listener) Endpoint { return labEndpoint(l.Addr().String()) }

func (h *harness) deliver(mailbox, subject, replyTo string, flags ...imap.Flag) string {
	h.t.Helper()
	raw := maillab.Message("Sam Rivera <sam@example.com>", labAddress, subject, "Hello from the lab.", replyTo, time.Now())
	if err := h.lab.Deliver(labAddress, mailbox, raw, flags...); err != nil {
		h.t.Fatal(err)
	}
	return maillab.MessageID(raw)
}

func (h *harness) sync() {
	h.t.Helper()
	if err := h.account.Sync(); err != nil {
		h.t.Fatal(err)
	}
}

type observedConversation struct {
	wireConversation
	mailboxIdentities map[Role]string
}

// conversations returns every conversation the phone would hold, keyed by subject.
func (h *harness) conversations() map[string]observedConversation {
	h.t.Helper()
	var resp syncResponse
	h.request("GET", "/v1/sync?since=0", nil, &resp)
	identities := map[string]map[Role]string{}
	for _, a := range resp.Accounts {
		identities[a.ID] = a.MailboxIdentities
	}
	out := map[string]observedConversation{}
	for _, c := range resp.Conversations {
		out[c.Subject] = observedConversation{c, identities[c.AccountID]}
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

func (h *harness) set(c observedConversation, change func(*ConversationState)) {
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
	c, err := imapclient.DialInsecure(h.imap.Address(), nil)
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

func (h *harness) delete(c observedConversation, target Role) int {
	h.t.Helper()
	ids := make([]string, 0, len(c.Messages))
	for _, m := range c.Messages {
		ids = append(ids, m.ID)
	}
	return h.request("DELETE", "/v1/conversations/"+c.ID, map[string]any{
		"messageIDs": ids, "expectedWorkflow": c.Workflow, "expectedRemoval": c.Removal, "removal": target,
		"mailboxIdentity": c.mailboxIdentities[target],
	}, nil)
}
