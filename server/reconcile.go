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
	to   Role // The source role means undo an unfinished COPY on that source.
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

// placeOf picks the default source for an IMAP operation. Gmail lists Inbox and Sent
// messages in All Mail too, so prefer Inbox and Sent to All Mail.
func placeOf(m *Message) (location, bool) {
	// A partial copy to Trash must not hide the source before its cleanup finishes.
	if pending := m.PendingMove; pending != nil && pending.From.UID != 0 && imap.UID(m.Locations[pending.From.Role]) == pending.From.UID {
		return pending.From.location(), true
	}
	return firstLocation(m, RoleTrash, RoleJunk, RoleInbox, RoleSent, RoleArchive)
}

func firstLocation(m *Message, roles ...Role) (location, bool) {
	for _, role := range roles {
		if uid := imap.UID(m.Locations[role]); uid != 0 {
			return location{role, uid}, true
		}
	}
	return location{}, false
}

// When several mailboxes still hold a copy, keep the conversation's current
// removal state as long as a copy supports it.
func observedPlace(c *Conversation, m *Message, archiveIsAll bool) (location, bool) {
	at, ok := placeOf(m)
	if !ok || c == nil || m.PendingMove != nil && m.PendingMove.From.location() == at {
		return at, ok
	}
	var preferred location
	var found bool
	if c.Removal == "" && m.Outgoing {
		preferred, found = firstLocation(m, RoleSent, RoleInbox, RoleArchive)
	} else if c.Removal == "" && c.Workflow == WorkflowSettled && !archiveIsAll {
		preferred, found = firstLocation(m, RoleArchive, RoleSent, RoleInbox)
	} else if c.Removal == "" {
		preferred, found = firstLocation(m, RoleInbox, RoleSent, RoleArchive)
	} else {
		preferred, found = firstLocation(m, c.Removal)
	}
	if found {
		return preferred, true
	}
	return at, true
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
				at, ok := observedPlace(c, m, a.archiveIsAll)
				return !ok || at.uid == 0 || at.role != c.Removal
			})) {
			cancelDelete(c)
			st.Touch(c)
		}
		if !c.Pending {
			if adopt(c, msgs, a.archiveIsAll) {
				st.Touch(c)
			}
			continue
		}
		p := planForMailboxes(c, msgs, a.archiveIsAll)
		if !p.empty() {
			plans = append(plans, p)
			continue
		}
		// A just-sent reply has no provider copy yet. Trash, Junk, delete, and Pin apply to it once its Sent copy appears.
		if slices.ContainsFunc(msgs, func(m *Message) bool {
			return m.Outgoing && m.SentAt != nil && len(m.Locations) == 0
		}) {
			continue
		}
		if c.Deleting {
			st.removeConversation(c.ID)
			continue
		}
		c.MoveFromRemoval = ""
		c.Pending, c.PendingPlacement, c.PendingRead, c.PendingPin = false, false, false, false
		adopt(c, msgs, a.archiveIsAll)
		st.Touch(c)
	}
	return plans
}

func cancelDelete(c *Conversation) {
	c.MoveFromRemoval = ""
	c.Deleting, c.Pending = false, false
	c.PendingPlacement, c.PendingRead, c.PendingPin = false, false, false
	c.DeleteKeys = nil
}

func incoming(msgs []*Message) []*Message {
	return slices.DeleteFunc(slices.Clone(msgs), func(m *Message) bool { return m.Outgoing })
}

// adopt takes over changes made in other mail clients. Snooze has no server state: snoozed mail stays in
// the inbox, so a snoozed conversation only changes when its mail leaves the inbox.
func adopt(c *Conversation, msgs []*Message, archiveIsAll bool) bool {
	before := *c
	in := incoming(msgs)
	placed := in
	if len(placed) == 0 {
		placed = msgs
	}
	var places []Role
	for _, m := range placed {
		if at, ok := observedPlace(c, m, archiveIsAll); ok {
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
	return planForMailboxes(c, msgs, false)
}

func planForMailboxes(c *Conversation, msgs []*Message, archiveIsAll bool) plan {
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
		p.moves = planMoves(c, msgs, in, archiveIsAll)
		if len(p.moves) != 0 {
			// Re-read the destination before deciding which copy needs flag changes.
			return p
		}
	}
	if c.PendingRead {
		placed := slices.DeleteFunc(in, func(m *Message) bool { return len(m.Locations) == 0 })
		if c.Unread {
			if len(placed) > 0 && !slices.ContainsFunc(placed, func(m *Message) bool { return !m.Seen }) {
				p.flags = appendFlag(p.flags, archiveIsAll, c, placed[len(placed)-1], imap.FlagSeen, false)
			}
		} else {
			for _, m := range placed {
				if !m.Seen {
					p.flags = appendFlag(p.flags, archiveIsAll, c, m, imap.FlagSeen, true)
				}
			}
		}
	}
	if c.PendingPin {
		placed := slices.DeleteFunc(slices.Clone(msgs), func(m *Message) bool { return len(m.Locations) == 0 })
		if c.Pinned {
			if len(placed) > 0 && !slices.ContainsFunc(placed, func(m *Message) bool { return m.Flagged }) {
				p.flags = appendFlag(p.flags, archiveIsAll, c, placed[len(placed)-1], imap.FlagFlagged, true)
			}
		} else {
			for _, m := range placed {
				if m.Flagged {
					p.flags = appendFlag(p.flags, archiveIsAll, c, m, imap.FlagFlagged, false)
				}
			}
		}
	}
	return p
}

func planMoves(c *Conversation, msgs, in []*Message, archiveIsAll bool) []move {
	var moves []move
	var primary *Message
	for _, m := range in {
		// The Inbox copy must be one placement can still move: not one another client marked deleted.
		if _, ok := placeOf(m); ok && !m.Deleted {
			primary = m
		}
	}
	for _, m := range msgs {
		if m.Deleted && m.PendingMove == nil {
			continue
		}
		at, ok := observedPlace(c, m, archiveIsAll)
		settleInbox := c.MoveFromRemoval == "" && c.Removal == "" && c.Workflow == WorkflowSettled && !m.Outgoing && m.Locations[RoleInbox] != 0
		if m.PendingMove == nil && settleInbox {
			at, ok = firstLocation(m, RoleInbox)
		} else if m.PendingMove == nil && c.MoveFromRemoval != "" {
			if previous, found := firstLocation(m, c.MoveFromRemoval); found {
				at, ok = previous, true
			}
		}
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
		targetExists := m.Locations[target] != 0 && !(archiveIsAll && (target == RoleArchive || at.role == RoleArchive))
		if pending := m.PendingMove; pending != nil && pending.From.location() == at {
			if pending.To.Role != target && targetExists {
				// The requested placement already exists. Only retire the superseded COPY.
				target = at.role
			}
			moves = append(moves, move{at, target})
			continue
		}
		// Once the target has a copy, another mailbox can still hold an independent copy.
		// Gmail's All Mail overlaps with other mailboxes.
		if target != at.role && (!targetExists || settleInbox) {
			moves = append(moves, move{at, target})
		}
	}
	return moves
}

func appendFlag(changes []flagChange, archiveIsAll bool, c *Conversation, m *Message, flag imap.Flag, add bool) []flagChange {
	if at, ok := observedPlace(c, m, archiveIsAll); ok {
		return append(changes, flagChange{at, flag, add})
	}
	return changes
}

func (a *Account) checkMove(m move, caps imap.CapSet) error {
	if m.from.uid == 0 {
		return fmt.Errorf("move requires a source UID")
	}
	if m.to == m.from.role {
		if !caps.Has(imap.CapUIDPlus) {
			return fmt.Errorf("unfinished move requires UIDPLUS")
		}
		return nil
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
		if a.sentUnavailable {
			p.flags = slices.DeleteFunc(p.flags, func(f flagChange) bool { return f.at.role == RoleSent })
			p.expunges = nil
		}
		p.moves = slices.DeleteFunc(p.moves, func(m move) bool {
			if a.sentUnavailable && (m.from.role == RoleSent || m.to == RoleSent) {
				return true
			}
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
			// A target that already holds a copy goes through the copy path, which reuses it instead of adding a duplicate.
			hasCopy := !a.archiveIsAll && caps.Has(imap.CapUIDPlus) && sources[m.from].copies[m.to] != 0
			if m.to == m.from.role || (!(m.from.role == RoleArchive && a.archiveIsAll) && (!caps.Has(imap.CapMove) || sources[m.from].pending || hasCopy)) {
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
		sel, err := a.selectMailbox(c, role, identities[role], false)
		if err != nil {
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
		if len(expunges[role]) == 0 {
			continue
		}
		for _, uids := range expunges[role] {
			unchanged, err := a.deleteScanCurrent(c, role, sel.UIDNext, identities)
			if err != nil {
				return err
			}
			if !unchanged {
				break
			}
			set := imap.UIDSetNum(uids...)
			found, err := c.Fetch(set, &imap.FetchOptions{UID: true, Flags: true}).Collect()
			if err != nil {
				return fmt.Errorf("revalidate delete in %s: %w", a.mailboxes[role], err)
			}
			if len(found) != len(uids) {
				// A restore may leave only some members here. Let the next scan reconcile the whole thread.
				continue
			}
			if err := a.expungeOwned(c, identities[role], set, found); err != nil {
				return err
			}
		}
	}
	return a.applyCopyMoves(c, copies, sources, identities, validate)
}

func (a *Account) deleteScanCurrent(c *imapclient.Client, selected Role, uidNext imap.UID, identities map[Role]mailboxIdentity) (bool, error) {
	// A new member can arrive in any scanned mailbox, including one outside the delete target.
	if uidNext == 0 || uidNext != a.scannedUIDNext[selected] {
		return false, nil
	}
	for _, role := range syncedRoles {
		expected, ok := a.scannedUIDNext[role]
		identity := identities[role]
		if !ok || identity.name == identities[selected].name {
			continue
		}
		status, err := c.Status(identity.name, &imap.StatusOptions{UIDNext: true, UIDValidity: true}).Wait()
		if err != nil {
			return false, fmt.Errorf("revalidate scan of %s: %w", identity.name, err)
		}
		if expected == 0 || status.UIDNext != expected || status.UIDValidity != identity.validity {
			return false, nil
		}
	}
	mailboxes, _, err := a.discover(c)
	if err != nil {
		return false, err
	}
	for _, role := range syncedRoles {
		if mailboxes[role] != identities[role].name {
			return false, nil
		}
	}
	// Check the target again after the other mailboxes. A reply can arrive during STATUS.
	current, err := a.selectMailbox(c, selected, identities[selected], false)
	if err != nil {
		return false, err
	}
	return current.UIDNext == uidNext, nil
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
