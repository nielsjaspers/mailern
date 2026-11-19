package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"slices"
	"strconv"
	"time"

	"github.com/emersion/go-imap/v2"
)

type Service struct {
	store    *Store
	accounts []*Account
	// authorize rejects requests from people outside the allowed list. Nil allows every request.
	authorize func(*http.Request) error
}

type wireAccount struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	Address string `json:"address"`
}

type wireMessage struct {
	ID         string    `json:"id"`
	Sender     string    `json:"sender"`
	Address    string    `json:"address"`
	To         []string  `json:"to"`
	Cc         []string  `json:"cc"`
	Date       time.Time `json:"date"`
	Body       string    `json:"body"`
	Outgoing   bool      `json:"outgoing"`
	Subject    string    `json:"subject"`
	HasHTML    bool      `json:"hasHTML"`
	MessageID  string    `json:"messageID,omitempty"`
	InReplyTo  string    `json:"inReplyTo,omitempty"`
	References []string  `json:"references,omitempty"`
}

type wireConversation struct {
	ID                   string        `json:"id"`
	AccountID            string        `json:"accountID"`
	Subject              string        `json:"subject"`
	Workflow             Workflow      `json:"workflow"`
	SnoozedUntil         *time.Time    `json:"snoozedUntil,omitempty"`
	ReturnedFromSnoozeAt *time.Time    `json:"returnedFromSnoozeAt,omitempty"`
	Removal              Role          `json:"removal,omitempty"`
	TrashSince           *time.Time    `json:"trashSince,omitempty"`
	Unread               bool          `json:"unread"`
	Pinned               bool          `json:"pinned"`
	Muted                bool          `json:"muted"`
	Revision             uint64        `json:"revision"`
	Messages             []wireMessage `json:"messages"`
}

type syncResponse struct {
	Revision uint64 `json:"revision"`
	// Set when the phone must drop everything it has, such as after the service lost its state.
	Reset         bool               `json:"reset"`
	Accounts      []wireAccount      `json:"accounts"`
	Conversations []wireConversation `json:"conversations"`
	Deleted       []string           `json:"deleted"`
}

// ConversationState is what the phone sets on a conversation. The service changes the server to match.
type ConversationState struct {
	Workflow     Workflow   `json:"workflow"`
	SnoozedUntil *time.Time `json:"snoozedUntil,omitempty"`
	Removal      Role       `json:"removal,omitempty"`
	Unread       bool       `json:"unread"`
	Pinned       bool       `json:"pinned"`
	Muted        bool       `json:"muted"`
}

func (s *Service) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/sync", s.sync)
	mux.HandleFunc("PUT /v1/conversations/{id}", s.setState)
	mux.HandleFunc("DELETE /v1/conversations/{id}", s.delete)
	mux.HandleFunc("GET /v1/messages/{id}/html", s.html)
	mux.HandleFunc("POST /v1/send", s.send)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		if s.authorize != nil {
			if err := s.authorize(r); err != nil {
				http.Error(w, err.Error(), http.StatusForbidden)
				return
			}
		}
		mux.ServeHTTP(w, r)
	})
}

// wireTime sends times in UTC with whole seconds, the form Foundation's ISO 8601 decoder reads.
func wireTime(t time.Time) time.Time { return t.UTC().Truncate(time.Second) }

func wireTimePtr(t *time.Time) *time.Time {
	if t == nil {
		return nil
	}
	out := wireTime(*t)
	return &out
}

func wire(st *State, c *Conversation) wireConversation {
	out := wireConversation{
		ID: c.ID, AccountID: c.AccountID, Subject: c.Subject, Workflow: c.Workflow, SnoozedUntil: wireTimePtr(c.SnoozedUntil),
		ReturnedFromSnoozeAt: wireTimePtr(c.ReturnedFromSnoozeAt), Removal: c.Removal, TrashSince: wireTimePtr(c.TrashSince),
		Unread: c.Unread, Pinned: c.Pinned, Muted: c.Muted, Revision: c.Revision, Messages: []wireMessage{},
	}
	for _, m := range st.messages(c) {
		out.Messages = append(out.Messages, wireMessage{
			ID: m.ID, Sender: m.Sender, Address: m.Address, To: m.To, Cc: m.Cc, Date: wireTime(m.Date), Body: m.Text,
			Outgoing: m.Outgoing, Subject: m.Subject, HasHTML: m.HasHTML, MessageID: m.MessageID,
			InReplyTo: m.InReplyTo, References: m.References,
		})
	}
	return out
}

// sync returns the conversations that changed after revision `since`. With `wait`, it holds the request open
// until something changes or the wait ends, so an open app sees new mail without polling.
func (s *Service) sync(w http.ResponseWriter, r *http.Request) {
	since, _ := strconv.ParseUint(r.URL.Query().Get("since"), 10, 64)
	wait, _ := strconv.Atoi(r.URL.Query().Get("wait"))
	deadline := time.After(time.Duration(min(max(wait, 0), 50)) * time.Second)
	for {
		var resp syncResponse
		changed := s.store.Read(func(st *State) {
			resp = s.changes(st, since)
		})
		if resp.Reset || len(resp.Conversations)+len(resp.Deleted) > 0 || wait <= 0 {
			writeJSON(w, resp)
			return
		}
		select {
		case <-changed:
		case <-deadline:
			writeJSON(w, resp)
			return
		case <-r.Context().Done():
			return
		}
	}
}

func (s *Service) changes(st *State, since uint64) syncResponse {
	resp := syncResponse{Revision: st.Revision, Reset: since == 0 || since > st.Revision,
		Conversations: []wireConversation{}, Deleted: []string{}}
	if resp.Reset {
		since = 0
	}
	for _, a := range s.accounts {
		resp.Accounts = append(resp.Accounts, wireAccount{a.cfg.ID, a.cfg.Name, a.cfg.Address})
	}
	for _, c := range st.Conversations {
		if c.Revision > since && !c.Deleting && len(c.Keys) > 0 {
			resp.Conversations = append(resp.Conversations, wire(st, c))
		}
	}
	if !resp.Reset {
		for id, revision := range st.Tombstones {
			if revision > since {
				resp.Deleted = append(resp.Deleted, id)
			}
		}
	}
	return resp
}

func (s *Service) account(id string) *Account {
	for _, a := range s.accounts {
		if a.cfg.ID == id {
			return a
		}
	}
	return nil
}

func (s *Service) setState(w http.ResponseWriter, r *http.Request) {
	var state ConversationState
	if err := json.NewDecoder(r.Body).Decode(&state); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if !slices.Contains([]Workflow{WorkflowInbox, WorkflowSnoozed, WorkflowSettled}, state.Workflow) ||
		!slices.Contains([]Role{"", RoleTrash, RoleJunk}, state.Removal) ||
		(state.Workflow == WorkflowSnoozed) != (state.SnoozedUntil != nil) {
		http.Error(w, "invalid conversation state", http.StatusBadRequest)
		return
	}
	var out wireConversation
	var account *Account
	err := s.store.Update(func(st *State) error {
		c := st.Conversations[r.PathValue("id")]
		if c == nil || c.Deleting {
			return errNotFound
		}
		if c.Workflow != state.Workflow || !sameTime(c.SnoozedUntil, state.SnoozedUntil) {
			c.ReturnedFromSnoozeAt = nil
		}
		if state.Removal == RoleTrash && c.Removal != RoleTrash {
			now := time.Now()
			c.TrashSince = &now
		} else if state.Removal != RoleTrash {
			c.TrashSince = nil
		}
		c.PendingRead = c.PendingRead || c.Unread != state.Unread || (c.Workflow != WorkflowSettled && state.Workflow == WorkflowSettled)
		c.PendingPin = c.PendingPin || c.Pinned != state.Pinned
		c.PendingPlacement = c.PendingPlacement || c.Workflow != state.Workflow || c.Removal != state.Removal
		c.Workflow, c.SnoozedUntil, c.Removal = state.Workflow, state.SnoozedUntil, state.Removal
		c.Unread, c.Pinned, c.Muted = state.Unread, state.Pinned, state.Muted
		c.Pending = c.Pending || c.PendingRead || c.PendingPin || c.PendingPlacement
		st.Touch(c)
		out = wire(st, c)
		account = s.account(c.AccountID)
		return nil
	})
	if err != nil {
		writeError(w, err)
		return
	}
	if account != nil {
		account.Trigger()
	}
	writeJSON(w, out)
}

// delete removes a conversation from Trash or Junk for good.
func (s *Service) delete(w http.ResponseWriter, r *http.Request) {
	var account *Account
	err := s.store.Update(func(st *State) error {
		c := st.Conversations[r.PathValue("id")]
		if c == nil || c.Deleting {
			return errNotFound
		}
		if c.Removal == "" {
			return badRequest{errors.New("only mail in Trash or Junk can be deleted")}
		}
		c.DeleteKeys = slices.Clone(c.Keys)
		c.Deleting, c.Pending = true, true
		st.Touch(c)
		account = s.account(c.AccountID)
		return nil
	})
	if err != nil {
		writeError(w, err)
		return
	}
	if account != nil {
		account.Trigger()
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Service) html(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var account *Account
	var at location
	var validity uint32
	var mailbox string
	found := false
	s.store.Read(func(st *State) {
		for accountID, state := range st.Accounts {
			for _, m := range state.Messages {
				if m.ID == id {
					account = s.account(accountID)
					at, found = placeOf(m)
					validity = state.UIDValidity[at.role]
					mailbox = state.Mailboxes[at.role]
				}
			}
		}
	})
	if account == nil || !found {
		writeError(w, errNotFound)
		return
	}
	html, err := account.FetchHTML(at, mailbox, validity)
	if err != nil {
		writeError(w, err)
		return
	}
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	fmt.Fprint(w, html)
}

func (s *Service) send(w http.ResponseWriter, r *http.Request) {
	var req SendRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 40<<20)).Decode(&req); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	account := s.account(req.AccountID)
	if account == nil {
		http.Error(w, "unknown account", http.StatusBadRequest)
		return
	}
	if err := account.Send(req); err != nil {
		writeError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

var errNotFound = errors.New("not found")

func writeError(w http.ResponseWriter, err error) {
	var bad badRequest
	switch {
	case errors.Is(err, errNotFound):
		http.Error(w, err.Error(), http.StatusNotFound)
	case errors.As(err, &bad):
		http.Error(w, err.Error(), http.StatusUnprocessableEntity)
	default:
		log.Printf("request failed: %v", err)
		http.Error(w, err.Error(), http.StatusBadGateway)
	}
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(v)
}

// WakeSnoozed returns due snoozed conversations to Inbox. Snoozed mail never left the server's inbox,
// so this changes only the service state.
func (s *Service) WakeSnoozed(ctx context.Context) {
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	for {
		now := time.Now()
		s.store.Update(func(st *State) error {
			for _, c := range st.Conversations {
				if c.Workflow == WorkflowSnoozed && c.SnoozedUntil != nil && !c.SnoozedUntil.After(now) {
					c.Workflow, c.ReturnedFromSnoozeAt, c.SnoozedUntil = WorkflowInbox, c.SnoozedUntil, nil
					st.Touch(c)
				}
			}
			return nil
		})
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

// FetchHTML reads one message's HTML on its own connection, so opening mail does not wait for a sync pass.
func (a *Account) FetchHTML(at location, name string, validity uint32) (string, error) {
	c, err := a.dial()
	if err != nil {
		return "", err
	}
	defer c.Close()
	if name == "" {
		return "", errNotFound
	}
	selected, err := c.Select(name, &imap.SelectOptions{ReadOnly: true}).Wait()
	if err != nil {
		return "", err
	}
	if selected.UIDValidity != validity {
		a.Trigger()
		return "", errNotFound
	}
	section := &imap.FetchItemBodySection{Peek: true}
	msgs, err := c.Fetch(imap.UIDSetNum(at.uid), &imap.FetchOptions{UID: true, BodySection: []*imap.FetchItemBodySection{section}}).Collect()
	if err != nil {
		return "", err
	}
	if len(msgs) == 0 {
		return "", errNotFound
	}
	p, err := parseMessage(msgs[0].FindBodySection(section))
	if err != nil {
		return "", err
	}
	return p.HTML, nil
}
