package mailsync

import (
	"context"
	"crypto/sha256"
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
	// Authorize rejects requests from people outside the allowed list. Nil allows every request.
	Authorize func(*http.Request) error
}

type wireAccount struct {
	ID                string          `json:"id"`
	Name              string          `json:"name"`
	Address           string          `json:"address"`
	Aliases           []string        `json:"aliases,omitempty"`
	MailboxIdentities map[Role]string `json:"mailboxIdentities,omitempty"`
	SyncError         string          `json:"syncError,omitempty"`
}

func mailboxToken(identity mailboxIdentity) string {
	if identity.name == "" || identity.validity == 0 {
		return ""
	}
	return fmt.Sprintf("%x", sha256.Sum256([]byte(fmt.Sprintf("%d:%s", identity.validity, identity.name))))
}

type wireMessage struct {
	ID          string    `json:"id"`
	Sender      string    `json:"sender"`
	Address     string    `json:"address"`
	To          []string  `json:"to"`
	Cc          []string  `json:"cc"`
	ReplyTo     []string  `json:"replyTo,omitempty"`
	DeliveredTo []string  `json:"deliveredTo,omitempty"`
	Date        time.Time `json:"date"`
	Body        string    `json:"body"`
	Outgoing    bool      `json:"outgoing"`
	Subject     string    `json:"subject"`
	HasHTML     bool      `json:"hasHTML"`
	MessageID   string    `json:"messageID,omitempty"`
	InReplyTo   string    `json:"inReplyTo,omitempty"`
	References  []string  `json:"references,omitempty"`
	// Another client marked the message deleted. It still shows, but it is not a new reply.
	Deleted bool `json:"deleted,omitempty"`
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
	Fields       []string   `json:"fields"`
	Workflow     Workflow   `json:"workflow"`
	SnoozedUntil *time.Time `json:"snoozedUntil,omitempty"`
	Removal      Role       `json:"removal,omitempty"`
	Unread       bool       `json:"unread"`
	Pinned       bool       `json:"pinned"`
	Muted        bool       `json:"muted"`
	// The conversation's message IDs as the phone knew them. Nil skips the check.
	MessageIDs []string `json:"messageIDs,omitempty"`
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
		if s.Authorize != nil {
			if err := s.Authorize(r); err != nil {
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
			ID: m.ID, Sender: m.Sender, Address: m.Address, To: m.To, Cc: m.Cc, ReplyTo: m.ReplyTo, DeliveredTo: m.DeliveredTo, Date: wireTime(m.Date), Body: m.Text,
			Outgoing: m.Outgoing, Subject: m.Subject, HasHTML: m.HasHTML, MessageID: m.MessageID,
			InReplyTo: m.InReplyTo, References: m.References, Deleted: m.Deleted,
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
	resp := syncResponse{Revision: st.Revision, Reset: since == 0 || since < st.FirstRevision || since > st.Revision,
		Conversations: []wireConversation{}, Deleted: []string{}}
	if resp.Reset {
		since = 0
	}
	for _, a := range s.accounts {
		account := wireAccount{ID: a.cfg.ID, Name: a.cfg.Name, Address: a.cfg.Address, Aliases: a.cfg.Aliases}
		if message := a.syncError.Load(); message != nil {
			account.SyncError = *message
		}
		if state := st.Accounts[a.cfg.ID]; state != nil {
			account.MailboxIdentities = map[Role]string{}
			for _, role := range []Role{RoleTrash, RoleJunk} {
				if token := mailboxToken(identityFor(state, role)); token != "" {
					account.MailboxIdentities[role] = token
				}
			}
		}
		resp.Accounts = append(resp.Accounts, account)
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
	allowed := []string{"workflow", "removal", "unread", "pinned", "muted"}
	if len(state.Fields) == 0 || slices.ContainsFunc(state.Fields, func(field string) bool { return !slices.Contains(allowed, field) }) {
		http.Error(w, "specify the changed state fields", http.StatusBadRequest)
		return
	}
	var out wireConversation
	id := r.PathValue("id")
	var account *Account
	s.store.Read(func(st *State) {
		if c := st.Conversations[id]; c != nil {
			account = s.account(c.AccountID)
		}
	})
	if account == nil {
		writeError(w, errNotFound)
		return
	}
	// Serialize the placement change with IMAP writes and conditional deletes on this account.
	account.mu.Lock()
	err := s.store.Update(func(st *State) error {
		c := st.Conversations[id]
		if c == nil || c.Deleting || c.AccountID != account.cfg.ID {
			return errNotFound
		}
		previousRemoval, wasMoving := c.Removal, c.PendingPlacement
		// A reply the phone has not seen yet wins, as an arrival does in Mailern: the change neither moves the
		// thread out of Inbox or into Trash, nor marks it read. The response brings the reply to the phone. Replies to a muted
		// thread do not move it, so they do not stop the change either.
		muted := c.Muted
		if slices.Contains(state.Fields, "muted") {
			muted = state.Muted
		}
		if !muted && state.MessageIDs != nil && slices.ContainsFunc(st.messages(c), func(m *Message) bool {
			return !m.Outgoing && !m.Deleted && !slices.Contains(state.MessageIDs, m.ID)
		}) {
			state.Fields = slices.DeleteFunc(slices.Clone(state.Fields), func(field string) bool {
				return (field == "workflow" && state.Workflow != WorkflowInbox) || (field == "unread" && !state.Unread) ||
					(field == "removal" && state.Removal == RoleTrash)
			})
		}
		if slices.Contains(state.Fields, "workflow") && (c.Workflow != state.Workflow || !sameTime(c.SnoozedUntil, state.SnoozedUntil)) {
			c.PendingPlacement = true
			// The phone can wake a due snooze before the service does. That is still a wake, with its time.
			woke := c.Workflow == WorkflowSnoozed && state.Workflow == WorkflowInbox && c.SnoozedUntil != nil && !c.SnoozedUntil.After(time.Now())
			returned := (*time.Time)(nil)
			if woke {
				returned = c.SnoozedUntil
			}
			c.Workflow, c.SnoozedUntil, c.ReturnedFromSnoozeAt = state.Workflow, state.SnoozedUntil, returned
			if state.Workflow == WorkflowSettled {
				c.Unread, c.PendingRead = false, true
			}
		}
		if slices.Contains(state.Fields, "removal") && state.Removal != c.Removal {
			c.PendingPlacement = true
			c.Removal, c.TrashSince = state.Removal, nil
			if state.Removal == RoleTrash {
				now := time.Now()
				c.TrashSince = &now
			}
		}
		if c.PendingPlacement && !wasMoving {
			c.MoveFromRemoval = previousRemoval
		}
		if slices.Contains(state.Fields, "unread") {
			c.Unread, c.PendingRead = state.Unread && c.Workflow != WorkflowSettled, true
		}
		if slices.Contains(state.Fields, "pinned") {
			c.Pinned, c.PendingPin = state.Pinned, true
		}
		if slices.Contains(state.Fields, "muted") {
			c.Muted = state.Muted
		}
		c.Pending = c.Pending || c.PendingRead || c.PendingPin || c.PendingPlacement
		st.Touch(c)
		out = wire(st, c)
		return nil
	})
	account.mu.Unlock()
	if err != nil {
		writeError(w, err)
		return
	}
	account.Trigger()
	writeJSON(w, out)
}

// delete checks the confirmation against a fresh provider scan before moving or queuing any mail.
func (s *Service) delete(w http.ResponseWriter, r *http.Request) {
	var request struct {
		MessageIDs       []string `json:"messageIDs"`
		ExpectedWorkflow Workflow `json:"expectedWorkflow"`
		ExpectedRemoval  Role     `json:"expectedRemoval"`
		Removal          Role     `json:"removal"`
		MailboxIdentity  string   `json:"mailboxIdentity"`
	}
	if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if len(request.MessageIDs) == 0 ||
		!slices.Contains([]Workflow{WorkflowInbox, WorkflowSnoozed, WorkflowSettled}, request.ExpectedWorkflow) ||
		!slices.Contains([]Role{"", RoleTrash, RoleJunk}, request.ExpectedRemoval) ||
		(request.Removal != RoleTrash && request.Removal != RoleJunk) {
		writeError(w, badRequest{errors.New("delete requires confirmed messages and a valid placement")})
		return
	}
	slices.Sort(request.MessageIDs)
	id := r.PathValue("id")
	var account *Account
	s.store.Read(func(st *State) {
		if c := st.Conversations[id]; c != nil {
			account = s.account(c.AccountID)
		}
	})
	if account == nil {
		writeError(w, errNotFound)
		return
	}

	conflict := errors.New("the messages or their placement changed before deletion")
	matchesMailbox := func(identity mailboxIdentity) bool {
		return request.MailboxIdentity != "" && request.MailboxIdentity == mailboxToken(identity)
	}
	err := func() error {
		account.mu.Lock()
		defer account.mu.Unlock()

		previousLocations := map[string]location{}
		var previousIdentities map[Role]mailboxIdentity
		active := false
		s.store.Read(func(st *State) {
			if c := st.Conversations[id]; c != nil && c.AccountID == account.cfg.ID && !c.Deleting {
				active = true
				previousIdentities = mailboxIdentities(st.account(c.AccountID))
				for _, m := range st.messages(c) {
					at, _ := observedPlace(c, m, account.archiveIsAll)
					previousLocations[m.ID] = at
				}
			}
		})
		if !active {
			return errNotFound
		}
		if !matchesMailbox(previousIdentities[request.Removal]) {
			return conflict
		}
		// The first pass may move only the confirmed members. The second pass checks the
		// resulting placement and membership before making the expunge eligible to run.
		moveConflict := false
		var recoverKeys []string
		for moved := false; ; moved = true {
			client, err := account.connect()
			if err != nil {
				return err
			}
			if err := account.read(client, recoverKeys...); err != nil {
				account.disconnect()
				return err
			}
			if account.sentUnavailable {
				return conflict
			}
			queued := false
			var movement plan
			var identities map[Role]mailboxIdentity
			var movementRevision uint64
			err = s.store.Update(func(st *State) error {
				c := st.Conversations[id]
				if c == nil || c.Deleting || c.AccountID != account.cfg.ID {
					return errNotFound
				}
				messages := st.messages(c)
				identities = mailboxIdentities(st.account(c.AccountID))
				matchesConfirmation := func() bool {
					return c.Workflow == request.ExpectedWorkflow && (c.Removal == request.ExpectedRemoval || c.Removal == request.Removal)
				}
				matchesPlacement := matchesConfirmation()
				if !c.PendingPlacement {
					observed := *c
					adopt(&observed, messages, account.archiveIsAll)
					if c.PendingRead && observed.Workflow != WorkflowSettled {
						observed.Unread = c.Unread
					}
					if c.PendingPin {
						observed.Pinned = c.Pinned
					}
					if observed.Workflow != c.Workflow || observed.Removal != c.Removal ||
						observed.Unread != c.Unread || observed.Pinned != c.Pinned {
						*c = observed
						st.Touch(c)
					}
					if !moved {
						matchesPlacement = matchesPlacement && matchesConfirmation()
					}
				}
				ids := make([]string, 0, len(messages))
				for _, m := range messages {
					ids = append(ids, m.ID)
				}
				slices.Sort(ids)
				if moveConflict || !matchesPlacement || !slices.Equal(ids, request.MessageIDs) || len(ids) != len(c.Keys) ||
					!matchesMailbox(identities[request.Removal]) {
					return conflict
				}
				for _, m := range messages {
					at, ok := observedPlace(c, m, account.archiveIsAll)
					if moved {
						at, ok = firstLocation(m, request.Removal)
					}
					previous := previousLocations[m.ID]
					if !ok || ((!moved || previous.role == request.Removal) &&
						(at != previous || identities[at.role] != previousIdentities[at.role])) {
						return conflict
					}
					if at.role == request.Removal {
						continue
					}
					// Another client can trash a thread's incoming mail but leave your reply in Sent. Deleting the thread
					// takes that reply too, as Trash does; the pass after the move checks it arrived.
					sentReply := m.Outgoing && at.role == RoleSent
					if moved || (!c.PendingPlacement && request.ExpectedRemoval == request.Removal && !sentReply) {
						return conflict
					}
					movement.moves = append(movement.moves, move{at, request.Removal})
					if at.role == RoleArchive && account.archiveIsAll {
						recoverKeys = append(recoverKeys, m.Key)
					}
				}
				if !client.Caps().Has(imap.CapUIDPlus) {
					return errDeleteUnsupported
				}
				if !movement.empty() {
					movementRevision = c.Revision
					return nil
				}
				if c.Removal != request.Removal {
					c.Removal, c.TrashSince = request.Removal, nil
					if c.Removal == RoleTrash {
						now := time.Now()
						c.TrashSince = &now
					}
				}
				c.DeleteKeys = slices.Clone(c.Keys)
				c.PendingPlacement, c.PendingRead, c.PendingPin = false, false, false
				c.Deleting, c.Pending = true, true
				st.Touch(c)
				queued = true
				return nil
			})
			if err != nil || queued {
				return err
			}
			err = account.applyConfirmedMoves(client, movement, identities, func(st *State) error {
				c := st.Conversations[id]
				if c == nil || c.Deleting || c.Revision != movementRevision {
					return conflict
				}
				return nil
			})
			if err != nil {
				moveConflict = errors.Is(err, errMoveChanged) || errors.Is(err, conflict)
				if !moveConflict {
					return err
				}
			}
		}
	}()
	if errors.Is(err, conflict) {
		http.Error(w, err.Error(), http.StatusConflict)
		return
	}
	if err != nil {
		writeError(w, err)
		return
	}
	account.Trigger()
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
					at, found = observedPlace(st.Conversations[m.ConversationID], m, state.ArchiveIsAll)
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
		// Nothing reached SMTP, so the phone can return the message to Drafts.
		w.Header().Set("Mailern-Submission", "not-accepted")
		var tooLarge *http.MaxBytesError
		if errors.As(err, &tooLarge) {
			http.Error(w, "the message is too large to send", http.StatusBadRequest)
			return
		}
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	account := s.account(req.AccountID)
	if account == nil {
		// Without this account we cannot check the receipt for an earlier attempt.
		http.Error(w, "unknown account", http.StatusBadRequest)
		return
	}
	if err := account.Send(req); err != nil {
		var bad badRequest
		if errors.As(err, &bad) {
			w.Header().Set("Mailern-Submission", "not-accepted")
		}
		writeError(w, err)
		return
	}
	w.Header().Set("Mailern-Submission", "accepted")
	w.WriteHeader(http.StatusNoContent)
}

var errNotFound = errors.New("not found")

func writeError(w http.ResponseWriter, err error) {
	var bad badRequest
	var unsent notSubmitted
	switch {
	case errors.Is(err, errNotFound):
		http.Error(w, err.Error(), http.StatusNotFound)
	case errors.Is(err, uncertainDelivery):
		// Only a definite answer tells the phone to stop retrying. A dropped connection or a failed Sent check can
		// still confirm on a retry.
		if err == uncertainDelivery {
			w.Header().Set("Mailern-Submission", "unconfirmable")
		}
		http.Error(w, err.Error(), http.StatusConflict)
	case errors.As(err, &unsent):
		w.Header().Set("Mailern-Submission", "not-accepted")
		http.Error(w, err.Error(), http.StatusServiceUnavailable)
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
