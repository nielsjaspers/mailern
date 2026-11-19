package main

import (
	"crypto/sha256"
	"errors"
	"fmt"
	"log"
	"slices"

	"github.com/emersion/go-imap/v2"
	"github.com/emersion/go-imap/v2/imapclient"
	"github.com/google/uuid"
)

type copyMailbox struct {
	Role     Role     `json:"role"`
	Name     string   `json:"name"`
	Validity uint32   `json:"validity"`
	UID      imap.UID `json:"uid,omitempty"`
}

func (m copyMailbox) identity() mailboxIdentity {
	return mailboxIdentity{m.Name, m.Validity}
}

func (m copyMailbox) location() location {
	return location{m.Role, m.UID}
}

// copyMove records the attempt before COPY. To.UID can also come from a content match
// when resuming a move, so only HasCopyUID authorizes cleanup of the destination.
type copyMove struct {
	From       copyMailbox       `json:"from"`
	To         copyMailbox       `json:"to"`
	UIDNext    imap.UID          `json:"uidNext"`
	Digest     [sha256.Size]byte `json:"digest"`
	HasCopyUID bool              `json:"hasCopyUID,omitempty"`
}

type copyMoveSource struct {
	key     string
	pending bool
}

func (a *Account) copyMoveSources(plans []plan) map[location]copyMoveSource {
	wanted := map[location]copyMoveSource{}
	for _, p := range plans {
		for _, m := range p.moves {
			wanted[m.from] = copyMoveSource{}
		}
	}
	if len(wanted) == 0 {
		return nil
	}
	a.store.Read(func(st *State) {
		for key, msg := range st.account(a.cfg.ID).Messages {
			at, ok := placeOf(msg)
			if _, need := wanted[at]; ok && need {
				wanted[at] = copyMoveSource{key, msg.PendingMove != nil}
			}
		}
	})
	return wanted
}

var errMoveChanged = errors.New("move placement changed")
var errCopyUnconfirmed = errors.New("could not confirm the destination copy")

func (a *Account) applyCopyMoves(c *imapclient.Client, moves []move, sources map[location]copyMoveSource, identities map[Role]mailboxIdentity, validate func(*State) error) error {
	if len(moves) == 0 {
		return nil
	}
	// Keep the source selected for writing while checking the copy on a second connection.
	destination, err := a.dial()
	if err != nil {
		return err
	}
	defer destination.Close()
	for _, m := range moves {
		if err := a.applyCopyMove(c, destination, sources[m.from].key, m, identities, validate); err != nil {
			if validate == nil && errors.Is(err, errMoveChanged) {
				continue
			}
			return fmt.Errorf("move to %s: %w", a.mailboxes[m.to], err)
		}
	}
	return nil
}

func (a *Account) applyCopyMove(source, destination *imapclient.Client, key string, m move, identities map[Role]mailboxIdentity, validate func(*State) error) error {
	from, to := identities[m.from.role], identities[m.to]
	check := func(st *State) (*Message, error) {
		account := st.account(a.cfg.ID)
		msg := account.Messages[key]
		if msg == nil || imap.UID(msg.Locations[m.from.role]) != m.from.uid ||
			identityFor(account, m.from.role) != from || identityFor(account, m.to) != to {
			return nil, errMoveChanged
		}
		if validate != nil {
			return msg, validate(st)
		}
		thread := st.Conversations[msg.ConversationID]
		if thread == nil || !slices.Contains(planForMailboxes(thread, st.messages(thread), a.archiveIsAll).moves, m) {
			return nil, errMoveChanged
		}
		return msg, nil
	}

	if _, err := a.selectMailbox(source, m.from.role, from, false); err != nil {
		return err
	}
	sourceUIDs := imap.UIDSetNum(m.from.uid)
	var pending *copyMove
	var checkErr error
	a.store.Read(func(st *State) {
		var msg *Message
		msg, checkErr = check(st)
		if checkErr == nil {
			pending = msg.PendingMove
		}
	})
	if checkErr != nil {
		return checkErr
	}
	if pending != nil && (pending.From.location() != m.from || pending.From.identity() != from) {
		return errMoveChanged
	}
	save := func(value *copyMove) error {
		return a.store.Update(func(st *State) error {
			msg := st.account(a.cfg.ID).Messages[key]
			if msg == nil {
				return errMoveChanged
			}
			msg.PendingMove = value
			st.Revision++
			return nil
		})
	}

	if pending != nil && pending.To.Role != m.to {
		// Retire the previous copy while its original is still available.
		if err := a.discardSupersededCopy(source, destination, pending); err != nil {
			return err
		}
		if err := save(nil); err != nil {
			return err
		}
		pending = nil
	}
	if m.to == m.from.role {
		return nil
	}
	if pending == nil {
		data, err := a.selectMailbox(destination, m.to, to, true)
		if err != nil {
			return err
		}
		if data.UIDNext == 0 {
			return fmt.Errorf("missing UIDNEXT for %s", to.name)
		}
		section := &imap.FetchItemBodySection{Peek: true}
		msgs, err := source.Fetch(sourceUIDs, &imap.FetchOptions{UID: true, Flags: true, BodySection: []*imap.FetchItemBodySection{section}}).Collect()
		if err != nil {
			return err
		}
		if len(msgs) != 1 || msgs[0].UID != m.from.uid || len(msgs[0].FindBodySection(section)) == 0 {
			return errMoveChanged
		}
		if slices.Contains(msgs[0].Flags, imap.FlagDeleted) {
			return fmt.Errorf("source is marked deleted")
		}
		pending = &copyMove{
			From:    copyMailbox{m.from.role, from.name, from.validity, m.from.uid},
			To:      copyMailbox{m.to, to.name, to.validity, 0},
			UIDNext: data.UIDNext,
			Digest:  sha256.Sum256(msgs[0].FindBodySection(section)),
		}
		if err := save(pending); err != nil {
			return err
		}
		receipt, err := source.Copy(sourceUIDs, to.name).Wait()
		if err != nil {
			var status *imap.Error
			if errors.As(err, &status) && (status.Type == imap.StatusResponseTypeNo || status.Type == imap.StatusResponseTypeBad) {
				// A tagged rejection guarantees that COPY did not add a message.
				return errors.Join(err, save(nil))
			}
			return err
		}
		if receipt.UIDValidity != 0 && receipt.UIDValidity != to.validity {
			return fmt.Errorf("COPY reports changed UIDVALIDITY for %s", to.name)
		}
		if receipt.UIDValidity == to.validity && slices.Equal(receipt.SourceUIDs, sourceUIDs) &&
			len(receipt.DestUIDs) == 1 && receipt.DestUIDs[0].Start == receipt.DestUIDs[0].Stop &&
			receipt.DestUIDs[0].Start >= pending.UIDNext {
			confirmed := *pending
			confirmed.To.UID = receipt.DestUIDs[0].Start
			confirmed.HasCopyUID = true
			pending = &confirmed
			if err := save(pending); err != nil {
				return err
			}
		}
	}
	if pending.To.identity() != to {
		return errMoveChanged
	}
	flags, err := source.Fetch(sourceUIDs, &imap.FetchOptions{UID: true, Flags: true}).Collect()
	if err != nil || len(flags) == 0 {
		return err
	}
	if len(flags) != 1 || flags[0].UID != m.from.uid {
		return errMoveChanged
	}

	data, err := a.selectMailbox(destination, m.to, to, true)
	if err != nil {
		return err
	}
	uid, err := pending.confirmCopy(destination, data.UIDNext)
	if err != nil {
		return err
	}
	if pending.To.UID == 0 {
		confirmed := *pending
		confirmed.To.UID = uid
		if err := save(&confirmed); err != nil {
			return err
		}
	}
	a.store.Read(func(st *State) { _, checkErr = check(st) })
	if checkErr != nil {
		return checkErr
	}
	return a.expungeOwned(source, from, sourceUIDs, flags)
}

func (a *Account) discardSupersededCopy(source, destination *imapclient.Client, pending *copyMove) error {
	if !pending.HasCopyUID || pending.To.UID == 0 {
		return nil
	}
	// Expunging from All Mail can also remove the original.
	if pending.To.Role == RoleArchive && a.archiveIsAll {
		return nil
	}
	section := &imap.FetchItemBodySection{Peek: true}
	msgs, err := source.Fetch(imap.UIDSetNum(pending.From.UID), &imap.FetchOptions{
		UID: true, Flags: true, BodySection: []*imap.FetchItemBodySection{section},
	}).Collect()
	if err != nil {
		return err
	}
	if len(msgs) != 1 || msgs[0].UID != pending.From.UID || slices.Contains(msgs[0].Flags, imap.FlagDeleted) ||
		sha256.Sum256(msgs[0].FindBodySection(section)) != pending.Digest {
		return errMoveChanged
	}
	if _, err := a.selectMailbox(destination, pending.To.Role, pending.To.identity(), false); err != nil {
		return err
	}
	uid := pending.To.UID
	set := imap.UIDSetNum(uid)
	flags, err := destination.Fetch(set, &imap.FetchOptions{UID: true, Flags: true}).Collect()
	if err != nil {
		return err
	}
	if len(flags) != 1 || flags[0].UID != uid || slices.Contains(flags[0].Flags, imap.FlagDeleted) {
		return nil
	}
	return a.expungeOwned(destination, pending.To.identity(), set, flags)
}

func (p *copyMove) confirmCopy(c *imapclient.Client, uidNext imap.UID) (imap.UID, error) {
	uids := []imap.UID{p.To.UID}
	if p.To.UID == 0 {
		// Without COPYUID, only a unique byte-for-byte match created after the attempt is usable.
		if uidNext <= p.UIDNext {
			return 0, errCopyUnconfirmed
		}
		set := imap.UIDSet{{Start: p.UIDNext, Stop: uidNext - 1}}
		found, err := c.UIDSearch(&imap.SearchCriteria{UID: []imap.UIDSet{set}}, nil).Wait()
		if err != nil {
			return 0, err
		}
		uids = found.AllUIDs()
	}
	var match imap.UID
	for batch := range slices.Chunk(uids, 16) {
		section := &imap.FetchItemBodySection{Peek: true}
		msgs, err := c.Fetch(imap.UIDSetNum(batch...), &imap.FetchOptions{UID: true, Flags: true, BodySection: []*imap.FetchItemBodySection{section}}).Collect()
		if err != nil {
			return 0, err
		}
		for _, msg := range msgs {
			if !slices.Contains(batch, msg.UID) || sha256.Sum256(msg.FindBodySection(section)) != p.Digest {
				continue
			}
			if match != 0 || slices.Contains(msg.Flags, imap.FlagDeleted) {
				return 0, fmt.Errorf("%w: ambiguous or marked deleted", errCopyUnconfirmed)
			}
			match = msg.UID
		}
	}
	if match == 0 {
		return 0, errCopyUnconfirmed
	}
	return match, nil
}

// deletedFlags records an interrupted STORE or EXPUNGE independently of the placement intent.
// When the mailbox supports new permanent keywords, Keyword follows the flag through a MOVE
// that preserves flags. UIDs are only valid in the original mailbox and UIDVALIDITY.
type deletedFlags struct {
	Mailbox  string      `json:"mailbox"`
	Validity uint32      `json:"validity"`
	UIDs     imap.UIDSet `json:"uids"`
	Keyword  imap.Flag   `json:"keyword,omitempty"`
}

func (a *Account) saveOwnedDeleted(mark *deletedFlags) error {
	return a.store.Update(func(st *State) error {
		st.account(a.cfg.ID).OwnedDeleted = mark
		st.Revision++
		return nil
	})
}

func (a *Account) expungeOwned(c *imapclient.Client, mailbox mailboxIdentity, set imap.UIDSet, present []*imapclient.FetchMessageBuffer) error {
	var owned imap.UIDSet
	for _, msg := range present {
		if set.Contains(msg.UID) && !slices.Contains(msg.Flags, imap.FlagDeleted) {
			owned.AddNum(msg.UID)
		}
	}
	if len(owned) == 0 {
		if err := c.UIDExpunge(set).Close(); err != nil {
			return fmt.Errorf("expunge: %w", err)
		}
		return nil
	}
	mark := &deletedFlags{Mailbox: mailbox.name, Validity: mailbox.validity, UIDs: owned}
	flags := []imap.Flag{imap.FlagDeleted}
	if selected := c.Mailbox(); selected != nil && slices.Contains(selected.PermanentFlags, imap.FlagWildcard) {
		mark.Keyword = imap.Flag("Mailern-" + uuid.NewString())
		flags = append(flags, mark.Keyword)
	}
	if err := a.saveOwnedDeleted(mark); err != nil {
		return err
	}
	// Add the keyword and Deleted together so a disconnect between commands cannot separate them.
	add := &imap.StoreFlags{Op: imap.StoreFlagsAdd, Silent: true, Flags: flags}
	err := c.Store(owned, add, nil).Close()
	if err != nil {
		err = fmt.Errorf("delete: %w", err)
	} else if err = c.UIDExpunge(set).Close(); err != nil {
		err = fmt.Errorf("expunge: %w", err)
	}
	if err != nil {
		select {
		case <-c.Closed():
			return err
		default:
			return errors.Join(err, a.recoverOwnedDeleted(c))
		}
	}
	return a.saveOwnedDeleted(nil)
}

func clearOwnedDeleted(c *imapclient.Client, set imap.UIDSet, flags []imap.Flag) error {
	if len(set) == 0 {
		return nil
	}
	restore := &imap.StoreFlags{Op: imap.StoreFlagsDel, Silent: true, Flags: flags}
	if err := c.Store(set, restore, nil).Close(); err != nil {
		return fmt.Errorf("clear interrupted delete flags: %w", err)
	}
	return nil
}

func (a *Account) recoverOwnedDeleted(c *imapclient.Client) error {
	var mark *deletedFlags
	a.store.Read(func(st *State) { mark = st.account(a.cfg.ID).OwnedDeleted })
	if mark == nil {
		return nil
	}
	if mark.Keyword != "" {
		if err := restoreMarkedDeleted(c, mark); err != nil {
			return err
		}
	} else if err := a.restoreLocalDeleted(c, mark); err != nil {
		return err
	}
	return a.saveOwnedDeleted(nil)
}

func restoreMarkedDeleted(c *imapclient.Client, mark *deletedFlags) error {
	boxes, err := c.List("", "*", nil).Collect()
	if err != nil {
		return fmt.Errorf("list mailboxes to recover delete flags: %w", err)
	}
	// Search by the exact operation keyword. Message-ID and EMAILID can identify several
	// copies with independent flags. IMAP cannot locate a moved flag if MOVE drops its keyword.
	criteria := &imap.SearchCriteria{Flag: []imap.Flag{mark.Keyword}}
	flags := []imap.Flag{imap.FlagDeleted, mark.Keyword}
	names := []string{mark.Mailbox}
	for _, box := range boxes {
		if box.Mailbox == mark.Mailbox || slices.Contains(box.Attrs, imap.MailboxAttrNoSelect) || slices.Contains(box.Attrs, imap.MailboxAttrNonExistent) {
			continue
		}
		names = append(names, box.Mailbox)
	}
	for _, name := range names {
		// The original write targets one mailbox. Searching elsewhere can recover
		// flags moved by another client when those mailboxes are accessible.
		ignore := func(err error) bool {
			var status *imap.Error
			return mailboxMissing(err) || name != mark.Mailbox && errors.As(err, &status) && status.Type == imap.StatusResponseTypeNo
		}
		if _, err := c.Select(name, nil).Wait(); err != nil {
			if ignore(err) {
				continue
			}
			return fmt.Errorf("recover delete flags in %s: %w", name, err)
		}
		found, err := c.UIDSearch(criteria, nil).Wait()
		if err != nil {
			if ignore(err) {
				continue
			}
			return fmt.Errorf("recover delete flags in %s: %w", name, err)
		}
		if err := clearOwnedDeleted(c, imap.UIDSetNum(found.AllUIDs()...), flags); err != nil {
			return fmt.Errorf("recover delete flags in %s: %w", name, err)
		}
	}
	return nil
}

func mailboxMissing(err error) bool {
	var status *imap.Error
	return errors.As(err, &status) && status.Code == imap.ResponseCodeNonExistent
}

func (a *Account) restoreLocalDeleted(c *imapclient.Client, mark *deletedFlags) error {
	// Use the original mailbox even if the provider has reassigned its special-use role.
	sel, err := c.Select(mark.Mailbox, nil).Wait()
	var remaining imap.UIDSet
	switch {
	case err == nil && mark.Validity != 0 && sel.UIDValidity == mark.Validity:
		found, err := c.UIDSearch(&imap.SearchCriteria{UID: []imap.UIDSet{mark.UIDs}}, nil).Wait()
		if err != nil {
			return fmt.Errorf("recover delete flags in %s: %w", mark.Mailbox, err)
		}
		for _, uid := range found.AllUIDs() {
			if mark.UIDs.Contains(uid) {
				remaining.AddNum(uid)
			}
		}
	case err != nil && !mailboxMissing(err):
		return fmt.Errorf("recover delete flags in %s: %w", mark.Mailbox, err)
	}
	if !slices.Equal(mark.UIDs, remaining) {
		log.Printf("%s: some interrupted delete UIDs in %s no longer resolve. Without a persistent keyword, IMAP cannot distinguish moved messages from expunged messages", a.cfg.ID, mark.Mailbox)
	}
	return clearOwnedDeleted(c, remaining, []imap.Flag{imap.FlagDeleted})
}
