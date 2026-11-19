package main

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"log"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/emersion/go-imap/v2"
	"github.com/emersion/go-imap/v2/imapclient"
	"github.com/google/uuid"
)

// Account syncs one mail account. One goroutine runs sync passes; API requests that need the server,
// such as sending or deleting, share its connection through mu.
type Account struct {
	cfg     AccountConfig
	store   *Store
	window  time.Duration
	trigger chan struct{}

	mu        sync.Mutex
	client    *imapclient.Client
	mailboxes map[Role]string
	// Gmail has no Archive mailbox. Its All Mail holds every message, so leaving it deletes the message,
	// and mail must be copied out of it instead of moved.
	archiveIsAll bool
}

func NewAccount(cfg AccountConfig, store *Store, window time.Duration) *Account {
	return &Account{cfg: cfg, store: store, window: window, trigger: make(chan struct{}, 1)}
}

// Trigger asks for a sync pass soon, such as after the phone changed a conversation.
func (a *Account) Trigger() {
	select {
	case a.trigger <- struct{}{}:
	default:
	}
}

func (a *Account) Run(ctx context.Context, poll time.Duration) {
	for {
		if err := a.Sync(); err != nil {
			log.Printf("%s: sync failed: %v", a.cfg.ID, err)
		}
		select {
		case <-ctx.Done():
			a.mu.Lock()
			a.disconnect()
			a.mu.Unlock()
			return
		case <-a.trigger:
		case <-time.After(poll):
		}
	}
}

func (a *Account) tlsConfig(e Endpoint) *tls.Config {
	return &tls.Config{ServerName: e.Host, InsecureSkipVerify: e.Loopback()}
}

func (a *Account) dial() (*imapclient.Client, error) {
	e := *a.cfg.IMAP
	options := &imapclient.Options{TLSConfig: a.tlsConfig(e)}
	var c *imapclient.Client
	var err error
	switch e.Security {
	case "starttls":
		c, err = imapclient.DialStartTLS(e.Address(), options)
	case "none":
		if !e.Loopback() {
			return nil, errors.New("unencrypted IMAP is allowed only on this machine")
		}
		c, err = imapclient.DialInsecure(e.Address(), options)
	default:
		c, err = imapclient.DialTLS(e.Address(), options)
	}
	if err != nil {
		return nil, err
	}
	if err := c.Login(a.cfg.Username, a.cfg.password).Wait(); err != nil {
		c.Close()
		return nil, fmt.Errorf("login: %w", err)
	}
	return c, nil
}

func (a *Account) connect() (*imapclient.Client, error) {
	if a.client != nil {
		select {
		case <-a.client.Closed():
			a.client = nil
		default:
			return a.client, nil
		}
	}
	c, err := a.dial()
	if err != nil {
		return nil, err
	}
	mailboxes, archiveIsAll, err := a.discover(c)
	if err != nil {
		c.Close()
		return nil, err
	}
	a.client, a.mailboxes, a.archiveIsAll = c, mailboxes, archiveIsAll
	return c, nil
}

func (a *Account) disconnect() {
	if a.client != nil {
		a.client.Close()
		a.client = nil
	}
}

var mailboxNames = map[Role][]string{
	RoleArchive: {"Archive", "Archives"},
	RoleSent:    {"Sent Messages", "Sent", "Sent Items", "Sent Mail"},
	RoleJunk:    {"Junk", "Spam", "Junk E-mail"},
	RoleTrash:   {"Deleted Messages", "Trash", "Deleted Items", "Bin"},
}

// discover finds the mailbox for each role: configured names first, then special-use attributes, then common names.
func (a *Account) discover(c *imapclient.Client) (map[Role]string, bool, error) {
	list, err := c.List("", "*", &imap.ListOptions{ReturnSpecialUse: c.Caps().Has(imap.CapSpecialUse)}).Collect()
	if err != nil {
		return nil, false, err
	}
	found := map[Role]string{RoleInbox: "INBOX"}
	var all string
	attrs := map[imap.MailboxAttr]Role{
		imap.MailboxAttrArchive: RoleArchive, imap.MailboxAttrSent: RoleSent,
		imap.MailboxAttrJunk: RoleJunk, imap.MailboxAttrTrash: RoleTrash,
	}
	names := map[string]bool{}
	for _, mb := range list {
		names[mb.Mailbox] = true
		for _, attr := range mb.Attrs {
			if role, ok := attrs[attr]; ok && found[role] == "" {
				found[role] = mb.Mailbox
			}
			if attr == imap.MailboxAttrAll {
				all = mb.Mailbox
			}
		}
	}
	for role, candidates := range mailboxNames {
		for _, name := range candidates {
			if found[role] == "" && names[name] {
				found[role] = name
			}
		}
	}
	if found[RoleArchive] == "" && all != "" {
		found[RoleArchive] = all
	}
	for role, name := range a.cfg.Mailboxes {
		found[role] = name
	}
	return found, all != "" && found[RoleArchive] == all, nil
}

func (a *Account) ensureArchive(c *imapclient.Client) error {
	if a.mailboxes[RoleArchive] != "" {
		return nil
	}
	var options imap.CreateOptions
	if c.Caps().Has(imap.CapCreateSpecialUse) {
		options.SpecialUse = []imap.MailboxAttr{imap.MailboxAttrArchive}
	}
	if err := c.Create("Archive", &options).Wait(); err != nil {
		return fmt.Errorf("create Archive: %w", err)
	}
	a.mailboxes[RoleArchive] = "Archive"
	return nil
}

// Sync reads the server, adopts changes made elsewhere, and then changes the server to match what Mailern wants.
// A pass that moved mail reads the server again, so the stored locations match the server when it returns.
func (a *Account) Sync() error {
	a.mu.Lock()
	defer a.mu.Unlock()
	err := a.sync()
	if err != nil {
		a.disconnect()
	}
	return err
}

func (a *Account) sync() error {
	for range 3 {
		c, err := a.connect()
		if err != nil {
			return err
		}
		if err := a.ensureArchive(c); err != nil {
			return err
		}
		if err := a.read(c); err != nil {
			return err
		}
		var plans []plan
		validity := make(map[Role]uint32)
		if err := a.store.Update(func(st *State) error {
			plans = a.reconcile(st)
			for role, value := range st.account(a.cfg.ID).UIDValidity {
				validity[role] = value
			}
			return nil
		}); err != nil {
			return err
		}
		if len(plans) == 0 {
			return a.fileSent(c)
		}
		if err := a.apply(c, plans, validity); err != nil {
			return err
		}
	}
	return nil
}

type mailboxSnapshot struct {
	name     string
	validity uint32
	flags    map[imap.UID][]imap.Flag
	// Messages new to this mailbox, by UID: their key, and the raw message when the account has never seen the key.
	keys map[imap.UID]string
	raw  map[imap.UID][]byte
}

func (a *Account) read(c *imapclient.Client) error {
	snapshots := make(map[Role]mailboxSnapshot)
	since := time.Now().Add(-a.window)
	for _, role := range syncedRoles {
		name := a.mailboxes[role]
		if name == "" {
			continue
		}
		snap, err := a.readMailbox(c, role, name, since)
		if err != nil {
			return fmt.Errorf("%s: %w", name, err)
		}
		snapshots[role] = snap
	}
	if err := a.findOldMoves(c, snapshots, since); err != nil {
		return err
	}
	return a.store.Update(func(st *State) error {
		a.merge(st, snapshots)
		return nil
	})
}

func (a *Account) readMailbox(c *imapclient.Client, role Role, name string, since time.Time) (mailboxSnapshot, error) {
	snap := mailboxSnapshot{name: name, flags: map[imap.UID][]imap.Flag{}, keys: map[imap.UID]string{}, raw: map[imap.UID][]byte{}}
	sel, err := c.Select(name, &imap.SelectOptions{ReadOnly: true}).Wait()
	if err != nil {
		return snap, err
	}
	snap.validity = sel.UIDValidity
	if sel.NumMessages == 0 {
		return snap, nil
	}
	criteria := &imap.SearchCriteria{}
	if role != RoleInbox {
		criteria.Since = since
	}
	found, err := c.UIDSearch(criteria, nil).Wait()
	if err != nil {
		return snap, err
	}
	known := map[imap.UID]bool{}
	keys := map[string]bool{}
	a.store.Read(func(st *State) {
		account := st.account(a.cfg.ID)
		current := account.Mailboxes[role] == snap.name && account.UIDValidity[role] == snap.validity
		for key, m := range account.Messages {
			keys[key] = true
			if uid, ok := m.Locations[role]; ok && current {
				known[imap.UID(uid)] = true
			}
		}
	})
	uids := found.AllUIDs()
	for uid := range known {
		uids = append(uids, uid)
	}
	if len(uids) == 0 {
		return snap, nil
	}
	slices.Sort(uids)
	flags, err := c.Fetch(imap.UIDSetNum(uids...), &imap.FetchOptions{UID: true, Flags: true}).Collect()
	if err != nil {
		return snap, err
	}
	var fresh []imap.UID
	for _, m := range flags {
		snap.flags[m.UID] = m.Flags
		if !known[m.UID] {
			fresh = append(fresh, m.UID)
		}
	}
	for batch := range slices.Chunk(fresh, 100) {
		envelopes, err := c.Fetch(imap.UIDSetNum(batch...), &imap.FetchOptions{UID: true, Envelope: true}).Collect()
		if err != nil {
			return snap, err
		}
		var unseen []imap.UID
		for _, m := range envelopes {
			key := envelopeKey(m.Envelope)
			snap.keys[m.UID] = key
			if !keys[key] {
				unseen = append(unseen, m.UID)
			}
		}
		for small := range slices.Chunk(unseen, 25) {
			section := &imap.FetchItemBodySection{Peek: true}
			bodies, err := c.Fetch(imap.UIDSetNum(small...), &imap.FetchOptions{UID: true, BodySection: []*imap.FetchItemBodySection{section}}).Collect()
			if err != nil {
				return snap, err
			}
			for _, m := range bodies {
				snap.raw[m.UID] = m.FindBodySection(section)
			}
		}
	}
	return snap, nil
}

// A move preserves INTERNALDATE, so a new UID can be older than the window.
// Look for previously known messages with a missing location before forgetting them.
func (a *Account) findOldMoves(c *imapclient.Client, snapshots map[Role]mailboxSnapshot, since time.Time) error {
	lost := map[string]bool{}
	var ids []string
	missingID := false
	a.store.Read(func(st *State) {
		account := st.account(a.cfg.ID)
		for key, m := range account.Messages {
			thread := st.Conversations[m.ConversationID]
			// Copying out of All Mail can add an old message without changing its source UID.
			copyingFromAll := a.archiveIsAll && m.Locations[RoleArchive] != 0 && thread != nil &&
				thread.PendingPlacement && thread.Removal != "" && m.Locations[thread.Removal] == 0
			missingLocation := false
			for role, uid := range m.Locations {
				snap, ok := snapshots[role]
				if !ok {
					continue
				}
				if _, present := snap.flags[imap.UID(uid)]; present && account.Mailboxes[role] == snap.name && account.UIDValidity[role] == snap.validity {
					continue
				}
				missingLocation = true
				break
			}
			if !copyingFromAll && !missingLocation {
				continue
			}
			lost[key] = true
			if m.MessageID == "" {
				missingID = true
			} else {
				ids = append(ids, m.MessageID)
			}
		}
	})
	if len(lost) == 0 {
		return nil
	}

	var searches []imap.SearchCriteria
	if missingID {
		// Messages without a usable Message-ID need their envelope to recover the key.
		searches = append(searches, imap.SearchCriteria{Before: since})
	} else {
		for batch := range slices.Chunk(ids, 32) {
			criteria := messageIDSearch(batch)
			criteria.Before = since
			searches = append(searches, criteria)
		}
	}
	for _, role := range syncedRoles {
		snap, ok := snapshots[role]
		if !ok || role == RoleInbox {
			continue
		}
		name := a.mailboxes[role]
		sel, err := c.Select(name, &imap.SelectOptions{ReadOnly: true}).Wait()
		if err != nil {
			return fmt.Errorf("select %s: %w", name, err)
		}
		if sel.UIDValidity != snap.validity {
			return fmt.Errorf("UIDVALIDITY changed for %s", name)
		}
		if sel.NumMessages == 0 {
			continue
		}
		for _, criteria := range searches {
			found, err := c.UIDSearch(&criteria, nil).Wait()
			if err != nil {
				return fmt.Errorf("search old mail in %s: %w", name, err)
			}
			uids := slices.DeleteFunc(found.AllUIDs(), func(uid imap.UID) bool {
				_, ok := snap.flags[uid]
				return ok
			})
			for batch := range slices.Chunk(uids, 100) {
				msgs, err := c.Fetch(imap.UIDSetNum(batch...), &imap.FetchOptions{UID: true, Envelope: true, Flags: true}).Collect()
				if err != nil {
					return fmt.Errorf("fetch old mail in %s: %w", name, err)
				}
				for _, m := range msgs {
					if key := envelopeKey(m.Envelope); lost[key] {
						snap.keys[m.UID], snap.flags[m.UID] = key, m.Flags
					}
				}
			}
		}
	}
	return nil
}

func messageIDSearch(ids []string) imap.SearchCriteria {
	if len(ids) == 1 {
		return imap.SearchCriteria{Header: []imap.SearchCriteriaHeaderField{{Key: "Message-ID", Value: ids[0]}}}
	}
	mid := len(ids) / 2
	return imap.SearchCriteria{Or: [][2]imap.SearchCriteria{{messageIDSearch(ids[:mid]), messageIDSearch(ids[mid:])}}}
}

func envelopeKey(e *imap.Envelope) string {
	if e == nil {
		return messageKey("", time.Time{}, "", "")
	}
	id := ""
	if e.MessageID != "" {
		id = "<" + e.MessageID + ">"
	}
	from := ""
	if len(e.From) > 0 {
		from = e.From[0].Addr()
	}
	return messageKey(id, e.Date, from, e.Subject)
}

// merge stores what read found: locations, flags, and new messages. New incoming mail in the inbox returns its
// conversation to Inbox, the way a reply does in Mailern. A muted conversation keeps its place, so the next
// reconcile moves the reply back out.
func (a *Account) merge(st *State, snapshots map[Role]mailboxSnapshot) {
	account := st.account(a.cfg.ID)
	changed := map[string]bool{}
	locationsChanged := map[string]bool{}
	arrived := map[string]bool{}
	byUID := func(role Role) map[imap.UID]*Message {
		out := map[imap.UID]*Message{}
		for _, m := range account.Messages {
			if uid, ok := m.Locations[role]; ok {
				out[imap.UID(uid)] = m
			}
		}
		return out
	}
	var fresh []*parsedArrival
	for _, role := range syncedRoles {
		snap, ok := snapshots[role]
		if !ok {
			continue
		}
		if account.Mailboxes[role] != snap.name || account.UIDValidity[role] != snap.validity {
			for _, m := range account.Messages {
				if _, ok := m.Locations[role]; ok {
					delete(m.Locations, role)
					locationsChanged[m.ConversationID] = true
					changed[m.ConversationID] = true
				}
			}
			account.Mailboxes[role] = snap.name
			account.UIDValidity[role] = snap.validity
		}
		located := byUID(role)
		for uid, m := range located {
			if _, ok := snap.flags[uid]; !ok {
				delete(m.Locations, role)
				locationsChanged[m.ConversationID] = true
				changed[m.ConversationID] = true
			}
		}
		for uid := range snap.flags {
			m := located[uid]
			if m == nil {
				key := snap.keys[uid]
				if m = account.Messages[key]; m == nil {
					raw, ok := snap.raw[uid]
					if !ok {
						continue
					}
					p, err := parseMessage(raw)
					if err != nil {
						log.Printf("%s: skipping unreadable message %d in %s: %v", a.cfg.ID, uid, role, err)
						continue
					}
					m = &p.Message
					m.ID, m.Key = uuid.NewString(), key
					m.Outgoing = strings.EqualFold(m.Address, a.cfg.Address)
					m.Locations = map[Role]uint32{}
					account.Messages[key] = m
					fresh = append(fresh, &parsedArrival{m, role})
					// Only mail new to the account counts as an arrival. A message Mailern moved back to the
					// inbox, such as a restored snoozed thread, must not clear the snooze.
					if role == RoleInbox && !m.Outgoing {
						arrived[key] = true
					}
				}
				m.Locations[role] = uint32(uid)
				m.SentAt = nil
				locationsChanged[m.ConversationID] = true
				changed[m.ConversationID] = true
			}
		}
	}
	for _, m := range account.Messages {
		at, ok := placeOf(m)
		if !ok {
			continue
		}
		flags, ok := snapshots[at.role].flags[at.uid]
		if !ok {
			continue
		}
		seen, flagged := slices.Contains(flags, imap.FlagSeen), slices.Contains(flags, imap.FlagFlagged)
		if m.Seen != seen || m.Flagged != flagged {
			m.Seen, m.Flagged = seen, flagged
			changed[m.ConversationID] = true
		}
	}
	slices.SortStableFunc(fresh, func(x, y *parsedArrival) int { return x.Date.Compare(y.Date) })
	for _, f := range fresh {
		a.thread(st, account, f.Message, f.role)
		locationsChanged[f.ConversationID] = true
		changed[f.ConversationID] = true
	}
	// Mail this service sent can wait briefly for its Sent copy before losing its place in a thread.
	for key, m := range account.Messages {
		if len(m.Locations) > 0 || (m.SentAt != nil && time.Since(*m.SentAt) < 10*time.Minute) {
			continue
		}
		delete(account.Messages, key)
		if c := st.Conversations[m.ConversationID]; c != nil {
			c.Keys = slices.DeleteFunc(c.Keys, func(k string) bool { return k == key })
			changed[c.ID] = true
		}
	}
	for id := range changed {
		c := st.Conversations[id]
		if c == nil {
			continue
		}
		if len(c.Keys) == 0 {
			st.removeConversation(id)
			continue
		}
		if c.Deleting && locationsChanged[id] {
			cancelDelete(c)
		}
		for _, key := range c.Keys {
			if arrived[key] && !c.Muted {
				c.Workflow, c.SnoozedUntil, c.ReturnedFromSnoozeAt = WorkflowInbox, nil, nil
				c.Unread = c.Unread || !account.Messages[key].Seen
				c.PendingRead = false
				// A reply rescues a thread from Trash. A conversation in Junk stays there until restored.
				if c.Removal == RoleTrash {
					c.Removal, c.TrashSince = "", nil
				}
			}
			if arrived[key] && c.Muted {
				c.Pending, c.PendingPlacement = true, true
			}
		}
		st.Touch(c)
	}
}

type parsedArrival struct {
	*Message
	role Role
}

// thread adds a new message to the conversation holding the message it answers, or starts one.
func (a *Account) thread(st *State, account *AccountState, m *Message, role Role) {
	parents := append(slices.Clone(m.References), m.InReplyTo)
	for i := len(parents) - 1; i >= 0; i-- {
		parent := account.Messages[parents[i]]
		if parent == nil || parent == m {
			continue
		}
		if c := st.Conversations[parent.ConversationID]; c != nil {
			m.ConversationID = c.ID
			c.Keys = append(c.Keys, m.Key)
			sortMessages(c, account)
			return
		}
	}
	c := &Conversation{ID: uuid.NewString(), AccountID: a.cfg.ID, Subject: m.Subject, Workflow: WorkflowSettled, Keys: []string{m.Key}}
	if c.Subject == "" {
		c.Subject = "(No Subject)"
	}
	switch role {
	case RoleInbox:
		c.Workflow = WorkflowInbox
		c.Unread = !m.Seen && !m.Outgoing
	case RoleJunk:
		c.Removal = RoleJunk
	case RoleTrash:
		now := time.Now()
		c.Removal, c.TrashSince = RoleTrash, &now
	}
	c.Pinned = m.Flagged
	m.ConversationID = c.ID
	st.Conversations[c.ID] = c
}
