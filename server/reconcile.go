package main

import (
	"fmt"
	"slices"
	"time"

	"github.com/emersion/go-imap/v2"
	"github.com/emersion/go-imap/v2/imapclient"
)

type location struct {
	role Role
	uid  imap.UID
}

type move struct {
	from location
	to   Role
}

type flagChange struct {
	at   location
	flag imap.Flag
	add  bool
}

// plan lists the server changes that make one conversation match the state Mailern wants.
type plan struct {
	moves    []move
	flags    []flagChange
	expunges []location
}

func (p plan) empty() bool { return len(p.moves)+len(p.flags)+len(p.expunges) == 0 }

// placeOf is where a message counts as being. Gmail lists inbox and sent mail in All Mail too; Inbox and Sent win,
// so a move starts from the mailbox Gmail documents for it.
func placeOf(m *Message) (location, bool) {
	for _, role := range []Role{RoleTrash, RoleJunk, RoleInbox, RoleSent, RoleArchive} {
		if uid, ok := m.Locations[role]; ok {
			return location{role, imap.UID(uid)}, true
		}
	}
	return location{}, false
}

// reconcile runs after each read. A conversation without pending changes adopts what the server shows.
// A pending one gets a plan; once the server matches, it is no longer pending.
func (a *Account) reconcile(st *State) []plan {
	var plans []plan
	for _, c := range st.Conversations {
		if c.AccountID != a.cfg.ID {
			continue
		}
		msgs := st.messages(c)
		if c.Deleting && (!slices.Equal(c.Keys, c.DeleteKeys) || slices.ContainsFunc(msgs, outsideRemoval)) {
			cancelDelete(c)
			st.Touch(c)
		}
		if !c.Pending {
			if adopt(c, msgs) {
				st.Touch(c)
			}
			continue
		}
		p := planFor(c, msgs)
		if !p.empty() {
			plans = append(plans, p)
			continue
		}
		if c.Deleting {
			st.removeConversation(c.ID)
			continue
		}
		c.Pending, c.PendingPlacement, c.PendingRead, c.PendingPin = false, false, false, false
		adopt(c, msgs)
		st.Touch(c)
	}
	return plans
}

func outsideRemoval(m *Message) bool {
	at, ok := placeOf(m)
	return !ok || at.role != RoleTrash && at.role != RoleJunk
}

func cancelDelete(c *Conversation) {
	c.Deleting, c.Pending = false, false
	c.PendingPlacement, c.PendingRead, c.PendingPin = false, false, false
	c.DeleteKeys = nil
}

func incoming(msgs []*Message) []*Message {
	return slices.DeleteFunc(slices.Clone(msgs), func(m *Message) bool { return m.Outgoing })
}

// adopt takes over changes made in other mail clients. Snooze has no server state: snoozed mail stays in
// the inbox, so a snoozed conversation only changes when its mail leaves the inbox.
func adopt(c *Conversation, msgs []*Message) bool {
	before := *c
	in := incoming(msgs)
	placed := in
	if len(placed) == 0 {
		placed = msgs
	}
	var places []Role
	for _, m := range placed {
		if at, ok := placeOf(m); ok {
			places = append(places, at.role)
		}
	}
	if len(places) > 0 {
		removal := Role("")
		if !slices.ContainsFunc(places, func(r Role) bool { return r != RoleTrash }) {
			removal = RoleTrash
		} else if !slices.ContainsFunc(places, func(r Role) bool { return r != RoleJunk }) {
			removal = RoleJunk
		}
		if removal != c.Removal {
			c.Removal, c.TrashSince = removal, nil
			if removal == RoleTrash {
				now := time.Now()
				c.TrashSince = &now
			}
		}
	}
	if c.Removal == "" && len(in) > 0 && len(places) > 0 {
		inInbox := slices.Contains(places, RoleInbox)
		if inInbox && c.Workflow == WorkflowSettled {
			c.Workflow = WorkflowInbox
		}
		if !inInbox && c.Workflow != WorkflowSettled {
			c.Workflow, c.SnoozedUntil = WorkflowSettled, nil
		}
	}
	// Mailern shows settled conversations as read, whatever their messages say.
	c.Unread = c.Workflow != WorkflowSettled && slices.ContainsFunc(in, func(m *Message) bool { return !m.Seen })
	c.Pinned = slices.ContainsFunc(msgs, func(m *Message) bool { return m.Flagged })
	return c.Workflow != before.Workflow || c.Removal != before.Removal || c.Unread != before.Unread ||
		c.Pinned != before.Pinned || !sameTime(c.SnoozedUntil, before.SnoozedUntil)
}

func sameTime(a, b *time.Time) bool {
	return (a == nil) == (b == nil) && (a == nil || a.Equal(*b))
}

// planFor moves and flags messages so the server shows the conversation the way Mailern does.
// Settle archives the conversation's incoming mail. Inbox and Snoozed keep the latest incoming message in the
// inbox. Trash and Junk take every message, including sent ones, the way Gmail trashes a whole thread.
func planFor(c *Conversation, msgs []*Message) plan {
	var p plan
	if c.Deleting {
		for _, m := range msgs {
			for _, role := range []Role{RoleTrash, RoleJunk} {
				if uid, ok := m.Locations[role]; ok {
					p.expunges = append(p.expunges, location{role, imap.UID(uid)})
				}
			}
		}
		return p
	}
	in := incoming(msgs)
	if c.PendingPlacement {
		p.moves = planMoves(c, msgs, in)
	}
	if c.PendingRead {
		placed := slices.DeleteFunc(in, func(m *Message) bool { return len(m.Locations) == 0 })
		if c.Unread {
			if len(placed) > 0 && !slices.ContainsFunc(placed, func(m *Message) bool { return !m.Seen }) {
				p.flags = appendFlag(p.flags, placed[len(placed)-1], imap.FlagSeen, false)
			}
		} else {
			for _, m := range placed {
				if !m.Seen {
					p.flags = appendFlag(p.flags, m, imap.FlagSeen, true)
				}
			}
		}
	}
	if c.PendingPin {
		placed := slices.DeleteFunc(slices.Clone(msgs), func(m *Message) bool { return len(m.Locations) == 0 })
		if c.Pinned {
			if len(placed) > 0 && !slices.ContainsFunc(placed, func(m *Message) bool { return m.Flagged }) {
				p.flags = appendFlag(p.flags, placed[len(placed)-1], imap.FlagFlagged, true)
			}
		} else {
			for _, m := range placed {
				if m.Flagged {
					p.flags = appendFlag(p.flags, m, imap.FlagFlagged, false)
				}
			}
		}
	}
	return p
}

func planMoves(c *Conversation, msgs, in []*Message) []move {
	var moves []move
	var primary *Message
	for _, m := range in {
		if _, ok := placeOf(m); ok {
			primary = m
		}
	}
	for _, m := range msgs {
		at, ok := placeOf(m)
		if !ok {
			continue
		}
		target := at.role
		switch {
		case c.Removal != "":
			target = c.Removal
		case m.Outgoing:
			if at.role == RoleTrash || at.role == RoleJunk {
				target = RoleSent
			}
		case m == primary && c.Workflow != WorkflowSettled:
			target = RoleInbox
		case at.role != RoleArchive && (at.role != RoleInbox || c.Workflow == WorkflowSettled):
			target = RoleArchive
		}
		if target != at.role {
			moves = append(moves, move{at, target})
		}
	}
	return moves
}

func appendFlag(changes []flagChange, m *Message, flag imap.Flag, add bool) []flagChange {
	if at, ok := placeOf(m); ok {
		return append(changes, flagChange{at, flag, add})
	}
	return changes
}

// apply carries out plans grouped by mailbox. Flags go first, because a move gives a message a new UID.
// Gmail's All Mail holds every message, so mail leaves it by a copy that adds a label, not by a move.
func (a *Account) apply(c *imapclient.Client, plans []plan, validity map[Role]uint32) error {
	flags := map[Role]map[flagChange][]imap.UID{}
	moves := map[Role]map[Role][]imap.UID{}
	expunges := map[Role][]imap.UID{}
	caps := c.Caps()
	for _, p := range plans {
		if len(p.expunges) > 0 && !caps.Has(imap.CapUIDPlus) {
			return fmt.Errorf("permanent delete requires UIDPLUS")
		}
		for _, f := range p.flags {
			key := flagChange{flag: f.flag, add: f.add}
			if flags[f.at.role] == nil {
				flags[f.at.role] = map[flagChange][]imap.UID{}
			}
			flags[f.at.role][key] = append(flags[f.at.role][key], f.at.uid)
		}
		for _, m := range p.moves {
			if a.mailboxes[m.to] == "" || a.mailboxes[m.to] == a.mailboxes[m.from.role] {
				return fmt.Errorf("no distinct destination mailbox for %s", m.to)
			}
			if !(m.from.role == RoleArchive && a.archiveIsAll) && !caps.Has(imap.CapMove) && !caps.Has(imap.CapUIDPlus) {
				return fmt.Errorf("move requires MOVE or UIDPLUS")
			}
			if moves[m.from.role] == nil {
				moves[m.from.role] = map[Role][]imap.UID{}
			}
			moves[m.from.role][m.to] = append(moves[m.from.role][m.to], m.from.uid)
		}
		for _, at := range p.expunges {
			expunges[at.role] = append(expunges[at.role], at.uid)
		}
	}
	for _, role := range syncedRoles {
		if len(flags[role])+len(moves[role])+len(expunges[role]) == 0 {
			continue
		}
		name := a.mailboxes[role]
		sel, err := c.Select(name, nil).Wait()
		if err != nil {
			return fmt.Errorf("select %s: %w", name, err)
		}
		if validity[role] == 0 || validity[role] != sel.UIDValidity {
			return fmt.Errorf("UIDVALIDITY changed for %s", name)
		}
		for change, uids := range flags[role] {
			op := imap.StoreFlagsDel
			if change.add {
				op = imap.StoreFlagsAdd
			}
			store := &imap.StoreFlags{Op: op, Silent: true, Flags: []imap.Flag{change.flag}}
			if err := c.Store(imap.UIDSetNum(uids...), store, nil).Close(); err != nil {
				return fmt.Errorf("store %s: %w", change.flag, err)
			}
		}
		for to, uids := range moves[role] {
			set := imap.UIDSetNum(uids...)
			if err := moveUIDs(c, set, a.mailboxes[to], role == RoleArchive && a.archiveIsAll, caps); err != nil {
				return fmt.Errorf("move to %s: %w", a.mailboxes[to], err)
			}
		}
		if uids := expunges[role]; len(uids) > 0 {
			if err := expungeUIDs(c, imap.UIDSetNum(uids...)); err != nil {
				return err
			}
		}
	}
	return nil
}

func moveUIDs(c *imapclient.Client, set imap.UIDSet, dest string, copyOnly bool, caps imap.CapSet) error {
	if !copyOnly && caps.Has(imap.CapMove) {
		_, err := c.Move(set, dest).Wait()
		return err
	}
	// The client's MOVE fallback queues deletion before it knows whether COPY succeeded.
	if _, err := c.Copy(set, dest).Wait(); err != nil || copyOnly {
		return err
	}
	return expungeUIDs(c, set)
}

func expungeUIDs(c *imapclient.Client, set imap.UIDSet) error {
	deleted := &imap.StoreFlags{Op: imap.StoreFlagsAdd, Silent: true, Flags: []imap.Flag{imap.FlagDeleted}}
	if err := c.Store(set, deleted, nil).Close(); err != nil {
		return fmt.Errorf("delete: %w", err)
	}
	if err := c.UIDExpunge(set).Close(); err != nil {
		return fmt.Errorf("expunge: %w", err)
	}
	return nil
}
