package mailsync

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"sync"
	"time"
)

// Role is the part a mailbox plays in the Mailern workflow. Each account maps every role to one server mailbox.
type Role string

const (
	RoleInbox   Role = "inbox"
	RoleArchive Role = "archive"
	RoleSent    Role = "sent"
	RoleJunk    Role = "junk"
	RoleTrash   Role = "trash"
)

var syncedRoles = []Role{RoleInbox, RoleArchive, RoleSent, RoleJunk, RoleTrash}

type Workflow string

const (
	WorkflowInbox   Workflow = "inbox"
	WorkflowSnoozed Workflow = "snoozed"
	WorkflowSettled Workflow = "settled"
)

// Message is one email as the service knows it. Locations holds its UID in each role mailbox that contains it.
// Gmail keeps an inbox message in both INBOX and All Mail, so one message can have several locations.
type Message struct {
	PendingMove    *copyMove `json:"pendingMove,omitempty"`
	ID             string    `json:"id"`
	Key            string    `json:"key"`
	ConversationID string    `json:"conversationID"`
	Sender         string    `json:"sender"`
	Address        string    `json:"address"`
	To             []string  `json:"to"`
	Cc             []string  `json:"cc"`
	// Where the sender wants replies, such as a contact form's visitor or a mailing list.
	ReplyTo []string `json:"replyTo,omitempty"`
	// The addresses the message was delivered to, from Delivered-To and X-Original-To.
	DeliveredTo []string  `json:"deliveredTo,omitempty"`
	Date        time.Time `json:"date"`
	Subject     string    `json:"subject"`
	Text        string    `json:"text"`
	HasHTML     bool      `json:"hasHTML"`
	MessageID   string    `json:"messageID,omitempty"`
	InReplyTo   string    `json:"inReplyTo,omitempty"`
	References  []string  `json:"references,omitempty"`
	Outgoing    bool      `json:"outgoing"`
	Seen        bool      `json:"seen"`
	Flagged     bool      `json:"flagged"`
	// Another client marked the observed copy deleted. Placement leaves it alone; the provider may expunge it.
	Deleted   bool            `json:"deleted,omitempty"`
	Locations map[Role]uint32 `json:"locations"`
	// SentAt marks mail this service submitted. It stays without a location until a sync finds the Sent copy.
	SentAt *time.Time `json:"sentAt,omitempty"`
}

// Conversation holds the state Mailern wants for a thread. While Pending is set, the service changes the
// server to match it. Otherwise each sync adopts what the server shows, such as an archive made in Gmail on the web.
// Snooze exists only here: snoozed mail stays in the server's inbox, and other mail clients keep showing it.
type Conversation struct {
	ID                   string     `json:"id"`
	AccountID            string     `json:"accountID"`
	Subject              string     `json:"subject"`
	Workflow             Workflow   `json:"workflow"`
	SnoozedUntil         *time.Time `json:"snoozedUntil,omitempty"`
	ReturnedFromSnoozeAt *time.Time `json:"returnedFromSnoozeAt,omitempty"`
	Removal              Role       `json:"removal,omitempty"`
	TrashSince           *time.Time `json:"trashSince,omitempty"`
	Unread               bool       `json:"unread"`
	Pinned               bool       `json:"pinned"`
	Muted                bool       `json:"muted"`
	Pending              bool       `json:"pending"`
	PendingRead          bool       `json:"pendingRead,omitempty"`
	PendingPin           bool       `json:"pendingPin,omitempty"`
	PendingPlacement     bool       `json:"pendingPlacement,omitempty"`
	MoveFromRemoval      Role       `json:"moveFromRemoval,omitempty"`
	DeleteKeys           []string   `json:"deleteKeys,omitempty"`
	// Set by a permanent delete. The service moves the thread to Trash, expunges it, and then forgets it.
	Deleting bool   `json:"deleting,omitempty"`
	Revision uint64 `json:"revision"`
	// Keys of the conversation's messages in its account, oldest first.
	Keys []string `json:"keys"`
}

type AccountState struct {
	ArchiveIsAll bool                  `json:"archiveIsAll,omitempty"`
	OwnedDeleted *deletedFlags         `json:"ownedDeleted,omitempty"`
	Submitting   map[string]submission `json:"submitting,omitempty"`
	Login        string                `json:"login"`
	IMAP         string                `json:"imap"`
	Mailboxes    map[Role]string       `json:"mailboxes"`
	// A receipt outlives the synced message. Its bytes are kept only until Sent filing succeeds.
	Receipts    map[string][]byte `json:"receipts,omitempty"`
	Address     string            `json:"address"`
	UIDValidity map[Role]uint32   `json:"uidValidity"`
	// Messages by key: the Message-ID header, or a stand-in for mail without one.
	Messages map[string]*Message `json:"messages"`
}

// State is everything the service keeps between restarts. Mail itself can be fetched again; this file keeps the
// IDs the phone already uses and the workflow state no server stores, such as snooze deadlines.
type State struct {
	Revision uint64 `json:"revision"`
	// The first revision of this state. A phone that synced with a state rebuilt since then holds a lower revision
	// and gets everything again, with its old conversations dropped.
	FirstRevision uint64                   `json:"firstRevision"`
	Conversations map[string]*Conversation `json:"conversations"`
	Accounts      map[string]*AccountState `json:"accounts"`
	// Deleted conversation IDs with the revision of their removal, so a phone that synced earlier drops them.
	Tombstones map[string]uint64 `json:"tombstones"`
}

type Store struct {
	mu      sync.Mutex
	path    string
	state   State
	changed chan struct{}
	dirty   bool
}

func OpenStore(path string) (*Store, error) {
	s := &Store{path: path, changed: make(chan struct{}), state: State{
		Conversations: map[string]*Conversation{},
		Accounts:      map[string]*AccountState{},
		Tombstones:    map[string]uint64{},
	}}
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		// Revisions start from the time, so they are above any revision a phone got from an earlier state at this
		// path. A state makes far fewer than 1024 changes per millisecond, and the value stays exact in JSON.
		s.state.Revision = uint64(time.Now().UnixMilli()) << 10
		s.state.FirstRevision = s.state.Revision
		return s, nil
	}
	if err != nil {
		return nil, err
	}
	if err := json.Unmarshal(data, &s.state); err != nil {
		return nil, err
	}
	return s, nil
}

// Update runs f with the state locked. It saves and wakes waiting sync requests when f bumped a revision.
func (s *Store) Update(f func(st *State) error) error {
	s.mu.Lock()
	before := s.state.Revision
	err := f(&s.state)
	changed := s.state.Revision != before
	if changed {
		s.dirty = true
	}
	var saveErr error
	if s.dirty {
		saveErr = s.saveLocked()
	}
	var wake chan struct{}
	if changed {
		wake = s.changed
		s.changed = make(chan struct{})
	}
	s.mu.Unlock()
	if wake != nil {
		close(wake)
	}
	return errors.Join(err, saveErr)
}

// Read runs f with the state locked. It returns a channel that closes on the next change.
func (s *Store) Read(f func(st *State)) <-chan struct{} {
	s.mu.Lock()
	defer s.mu.Unlock()
	f(&s.state)
	return s.changed
}

func (s *Store) saveLocked() error {
	data, err := json.Marshal(s.state)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(s.path), 0o700); err != nil {
		return err
	}
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	if err := os.Rename(tmp, s.path); err != nil {
		return err
	}
	s.dirty = false
	return nil
}

// Removed mailboxes must disappear from both the cache and clients that already synced them.
func (st *State) configureAccounts(accounts []AccountConfig) {
	active := make(map[string]AccountConfig, len(accounts))
	for _, cfg := range accounts {
		active[cfg.ID] = cfg
	}
	for id, cached := range st.Accounts {
		if cfg, ok := active[id]; ok && cached.Address == cfg.Address && cached.Login == cfg.Username && cached.IMAP == cfg.IMAP.Address() {
			continue
		}
		for threadID, c := range st.Conversations {
			if c.AccountID == id {
				st.removeConversation(threadID)
			}
		}
		delete(st.Accounts, id)
		st.Revision++
	}
	for id, cfg := range active {
		if st.Accounts[id] == nil {
			a := st.account(id)
			a.Address, a.Login, a.IMAP = cfg.Address, cfg.Username, cfg.IMAP.Address()
			st.Revision++
		}
	}
}

func (st *State) account(id string) *AccountState {
	a := st.Accounts[id]
	if a == nil {
		a = &AccountState{Mailboxes: map[Role]string{}, UIDValidity: map[Role]uint32{}, Messages: map[string]*Message{}}
		st.Accounts[id] = a
	}
	return a
}

// Touch gives a conversation a new revision, so the next sync request returns it.
func (st *State) Touch(c *Conversation) {
	delete(st.Tombstones, c.ID)
	st.Revision++
	c.Revision = st.Revision
}

func (st *State) messages(c *Conversation) []*Message {
	account := st.Accounts[c.AccountID]
	if account == nil {
		return nil
	}
	out := make([]*Message, 0, len(c.Keys))
	for _, key := range c.Keys {
		if m := account.Messages[key]; m != nil {
			out = append(out, m)
		}
	}
	return out
}

func (st *State) removeConversation(id string) {
	delete(st.Conversations, id)
	st.Revision++
	st.Tombstones[id] = st.Revision
}

// sortMessages orders a conversation's messages oldest first, the order the phone shows them in.
func sortMessages(c *Conversation, account *AccountState) {
	slices.SortStableFunc(c.Keys, func(a, b string) int {
		return account.Messages[a].Date.Compare(account.Messages[b].Date)
	})
}
