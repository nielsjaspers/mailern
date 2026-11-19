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
	deleteAt Role
	expunges []imap.UID
}

func (p plan) empty() bool { return len(p.moves)+len(p.flags)+len(p.expunges) == 0 }

// placeOf is where a message counts as being. Gmail lists inbox and sent mail in All Mail too; Inbox and Sent win,
// so a move starts from the mailbox Gmail documents for it.
func placeOf(m *Message) (location, bool) {
	// A partial copy to Trash must not hide the source before its cleanup finishes.
	if pending := m.PendingMove; pending != nil && pending.From.UID != 0 && imap.UID(m.Locations[pending.From.Role]) == pending.From.UID {
		return location{pending.From.Role, pending.From.UID}, true
	}
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
		if c.Deleting && (c.Removal != RoleTrash && c.Removal != RoleJunk ||
			!slices.Equal(c.Keys, c.DeleteKeys) || len(msgs) != len(c.DeleteKeys) ||
			slices.ContainsFunc(msgs, func(m *Message) bool {
				at, ok := placeOf(m)
				return !ok || at.uid == 0 || at.role != c.Removal
			})) {
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
		p.deleteAt = c.Removal
		for _, m := range msgs {
			p.expunges = append(p.expunges, imap.UID(m.Locations[p.deleteAt]))
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

func (a *Account) checkMove(m move, caps imap.CapSet) error {
	if m.from.uid == 0 {
		return fmt.Errorf("move requires a source UID")
	}
	if a.mailboxes[m.to] == "" || a.mailboxes[m.to] == a.mailboxes[m.from.role] {
		return fmt.Errorf("no distinct destination mailbox for %s", m.to)
	}
	if !(m.from.role == RoleArchive && a.archiveIsAll) && !caps.Has(imap.CapMove) && !caps.Has(imap.CapUIDPlus) {
		return fmt.Errorf("move requires MOVE or UIDPLUS")
	}
	return nil
}

var errDeleteUnsupported = fmt.Errorf("permanent delete requires UIDPLUS")

// Keep unsupported operations pending while allowing other writes in the same sync to proceed.
func (a *Account) supportedPlans(plans []plan, caps imap.CapSet) ([]plan, error) {
	var blocked error
	var sources map[location]copyMoveSource
	if caps.Has(imap.CapMove) && !caps.Has(imap.CapUIDPlus) {
		sources = a.copyMoveSources(plans)
	}
	for i := range plans {
		p := &plans[i]
		p.moves = slices.DeleteFunc(p.moves, func(m move) bool {
			if err := a.checkMove(m, caps); err != nil {
				blocked = err
				return true
			}
			if sources[m.from].pending {
				blocked = fmt.Errorf("unfinished move requires UIDPLUS")
				return true
			}
			return false
		})
		if len(p.expunges) > 0 && !caps.Has(imap.CapUIDPlus) {
			p.expunges = nil
			blocked = errDeleteUnsupported
		}
	}
	return slices.DeleteFunc(plans, plan.empty), blocked
}

// apply carries out plans grouped by mailbox. Flags go first, because a move gives a message a new UID.
func (a *Account) apply(c *imapclient.Client, plans []plan, identities map[Role]mailboxIdentity) error {
	return a.applyPlans(c, plans, identities, nil)
}

func (a *Account) applyConfirmedMoves(c *imapclient.Client, p plan, identities map[Role]mailboxIdentity, validate func(*State) error) error {
	return a.applyPlans(c, []plan{p}, identities, validate)
}

func (a *Account) applyPlans(c *imapclient.Client, plans []plan, identities map[Role]mailboxIdentity, validate func(*State) error) error {
	flags := map[Role]map[flagChange][]imap.UID{}
	moves := map[Role]map[Role][]imap.UID{}
	expunges := map[Role][][]imap.UID{}
	var copies []move
	caps := c.Caps()
	sources := a.copyMoveSources(plans)
	for _, p := range plans {
		if len(p.expunges) > 0 && !caps.Has(imap.CapUIDPlus) {
			return errDeleteUnsupported
		}
		for _, f := range p.flags {
			key := flagChange{flag: f.flag, add: f.add}
			if flags[f.at.role] == nil {
				flags[f.at.role] = map[flagChange][]imap.UID{}
			}
			flags[f.at.role][key] = append(flags[f.at.role][key], f.at.uid)
		}
		for _, m := range p.moves {
			if err := a.checkMove(m, caps); err != nil {
				return err
			}
			if !(m.from.role == RoleArchive && a.archiveIsAll) && (!caps.Has(imap.CapMove) || sources[m.from].pending) {
				if !caps.Has(imap.CapUIDPlus) {
					return fmt.Errorf("unfinished move requires UIDPLUS")
				}
				copies = append(copies, m)
				continue
			}
			if moves[m.from.role] == nil {
				moves[m.from.role] = map[Role][]imap.UID{}
			}
			moves[m.from.role][m.to] = append(moves[m.from.role][m.to], m.from.uid)
		}
		if len(p.expunges) > 0 {
			expunges[p.deleteAt] = append(expunges[p.deleteAt], p.expunges)
		}
	}
	for _, role := range syncedRoles {
		if len(flags[role])+len(moves[role])+len(expunges[role]) == 0 {
			continue
		}
		if _, err := a.selectMailbox(c, role, identities[role], false); err != nil {
			return err
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
			if validate != nil {
				var err error
				a.store.Read(func(st *State) { err = validate(st) })
				if err != nil {
					return err
				}
			}
			set := imap.UIDSetNum(uids...)
			var err error
			if role == RoleArchive && a.archiveIsAll {
				// COPY from Gmail's All Mail adds the destination label while retaining the message.
				_, err = c.Copy(set, a.mailboxes[to]).Wait()
			} else {
				_, err = c.Move(set, a.mailboxes[to]).Wait()
			}
			if err != nil {
				return fmt.Errorf("move to %s: %w", a.mailboxes[to], err)
			}
		}
		for _, uids := range expunges[role] {
			set := imap.UIDSetNum(uids...)
			found, err := c.UIDSearch(&imap.SearchCriteria{UID: []imap.UIDSet{set}}, nil).Wait()
			if err != nil {
				return fmt.Errorf("revalidate delete in %s: %w", a.mailboxes[role], err)
			}
			present, _ := found.All.(imap.UIDSet)
			if slices.ContainsFunc(uids, func(uid imap.UID) bool { return !present.Contains(uid) }) {
				// A restore may leave only some members here. Let the next scan reconcile the whole thread.
				continue
			}
			if err := expungeUIDs(c, set); err != nil {
				return err
			}
		}
	}
	return a.applyCopyMoves(c, copies, sources, identities, validate)
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
