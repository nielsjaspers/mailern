package main

import (
	"slices"
	"testing"
	"time"

	"github.com/emersion/go-imap/v2"
)

func TestProviderRollsBackDeletedFlagAfterExternalMove(t *testing.T) {
	t.Run("keyword preserved", func(t *testing.T) { checkDeletedFlagExternalMove(t, false) })
	t.Run("keyword discarded", func(t *testing.T) { checkDeletedFlagExternalMove(t, true) })
}

func checkDeletedFlagExternalMove(t *testing.T, discardKeyword bool) {
	t.Helper()
	h := newHarness(t)
	// Use the lab's native MOVE connection for the other client. Mailern's connection
	// drops the response to the first STORE that adds Deleted.
	other, err := h.account.dial()
	if err != nil {
		t.Fatal(err)
	}
	defer other.Close()
	if !other.Caps().Has(imap.CapMove) {
		t.Fatal("test requires native MOVE")
	}
	serveCopyMoveProvider(t, h, loseDeletedStoreResponse)
	const dest = "Personal folder"
	if err := other.Create(dest, nil).Wait(); err != nil {
		t.Fatal(err)
	}
	raw := LabMessage("sam@example.com", labAddress, "Two identical messages", "Hello.", "", time.Now())
	if err := h.lab.Deliver(labAddress, "Trash", raw, imap.FlagSeen); err != nil {
		t.Fatal(err)
	}
	if err := h.lab.Deliver(labAddress, dest, raw, imap.FlagDeleted, imap.FlagFlagged); err != nil {
		t.Fatal(err)
	}
	c, err := h.account.dial()
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	sel, err := c.Select("Trash", nil).Wait()
	if err != nil {
		t.Fatal(err)
	}
	set := imap.UIDSetNum(1)
	fetch := &imap.FetchOptions{UID: true, Flags: true}
	present, err := c.Fetch(set, fetch).Collect()
	if err != nil {
		t.Fatal(err)
	}
	if err := h.account.expungeOwned(c, mailboxIdentity{"Trash", sel.UIDValidity}, set, present); err == nil {
		t.Fatal("expected the provider to disconnect during STORE")
	}
	if _, err := other.Select("Trash", nil).Wait(); err != nil {
		t.Fatal(err)
	}
	move, err := other.Move(set, dest).Wait()
	if err != nil {
		t.Fatal(err)
	}
	if uids, ok := move.DestUIDs.(imap.UIDSet); !ok || !slices.Equal(uids, imap.UIDSetNum(2)) {
		t.Fatalf("expected MOVE to assign UID 2 in the new mailbox, got %v", move.DestUIDs)
	}
	if _, err := other.Select(dest, nil).Wait(); err != nil {
		t.Fatal(err)
	}
	movedSet := imap.UIDSetNum(2)
	moved, err := other.Fetch(movedSet, fetch).Collect()
	if err != nil || len(moved) != 1 || !slices.Contains(moved[0].Flags, imap.FlagDeleted) {
		t.Fatalf("expected MOVE to carry the deletion flag, got %v, %v", moved, err)
	}
	wantMoved := []imap.Flag{imap.FlagSeen}
	if discardKeyword {
		// Simulate a MOVE that drops custom keywords while preserving system flags.
		wantMoved = append(wantMoved, imap.FlagDeleted)
		setFlags := &imap.StoreFlags{Op: imap.StoreFlagsSet, Silent: true, Flags: wantMoved}
		if err := other.Store(movedSet, setFlags, nil).Close(); err != nil {
			t.Fatal(err)
		}
	}
	restartCopyMoveAccount(t, h)
	recovery, err := h.account.dial()
	if err != nil {
		t.Fatal(err)
	}
	defer recovery.Close()
	if err := h.account.recoverOwnedDeleted(recovery); err != nil {
		t.Fatal(err)
	}
	h.account.store.Read(func(st *State) {
		if st.account(h.account.cfg.ID).OwnedDeleted != nil {
			t.Error("recovery left the interrupted delete in the journal")
		}
	})
	msgs, err := other.Fetch(imap.UIDSetNum(1, 2), fetch).Collect()
	if err != nil || len(msgs) != 2 {
		t.Fatalf("expected both copies to survive, got %v, %v", msgs, err)
	}
	for _, msg := range msgs {
		if msg.UID == 1 && (len(msg.Flags) != 2 || !slices.Contains(msg.Flags, imap.FlagDeleted) || !slices.Contains(msg.Flags, imap.FlagFlagged)) {
			t.Fatalf("changed flags on independently deleted copy: %v", msg.Flags)
		}
		if msg.UID == 2 {
			slices.Sort(msg.Flags)
			slices.Sort(wantMoved)
			if !slices.Equal(msg.Flags, wantMoved) {
				t.Fatalf("moved copy has flags %v, want %v", msg.Flags, wantMoved)
			}
		}
	}
}
