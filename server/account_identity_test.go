package main

import (
	"fmt"
	"testing"

	"github.com/emersion/go-imap/v2"
)

func TestSyncPersistsMailboxIdentityChangesWithoutConversationChanges(t *testing.T) {
	h := newHarness(t)
	h.deliver("INBOX", "Unchanged Inbox mail", "")
	h.sync()
	var before syncResponse
	h.request("GET", "/v1/sync?since=0", nil, &before)
	oldToken := before.Accounts[0].MailboxIdentities[RoleTrash]
	if oldToken == "" {
		t.Fatal("expected the original Trash identity")
	}
	if err := h.lab.users[labAddress].Create("New Trash", nil); err != nil {
		t.Fatal(err)
	}
	h.account.cfg.Mailboxes = map[Role]string{RoleTrash: "New Trash"}
	h.sync()
	var after syncResponse
	h.request("GET", fmt.Sprintf("/v1/sync?since=%d", before.Revision), nil, &after)
	newToken := after.Accounts[0].MailboxIdentities[RoleTrash]
	if newToken == "" || newToken == oldToken || len(after.Conversations) != 0 || len(after.Deleted) != 0 {
		t.Fatalf("expected only a Trash identity change, got %+v", after)
	}
	reopened, err := OpenStore(h.account.store.path)
	if err != nil {
		t.Fatal(err)
	}
	reopened.Read(func(st *State) {
		identity := identityFor(st.account(h.account.cfg.ID), RoleTrash)
		if st.Revision <= before.Revision || st.Revision != after.Revision || mailboxToken(identity) != newToken {
			t.Errorf("Trash identity change did not reach disk: revision %d, identity %+v", st.Revision, identity)
		}
	})
	h.sync()
	var unchanged syncResponse
	h.request("GET", fmt.Sprintf("/v1/sync?since=%d", after.Revision), nil, &unchanged)
	if unchanged.Revision != after.Revision {
		t.Fatalf("unchanged scan advanced revision from %d to %d", after.Revision, unchanged.Revision)
	}
}

func TestAccountCacheBelongsToTheConfiguredIMAPLogin(t *testing.T) {
	for _, change := range []string{"login", "endpoint"} {
		t.Run(change, func(t *testing.T) {
			h := newHarness(t)
			cfg := h.account.cfg
			configure := func() {
				t.Helper()
				if err := h.account.store.Update(func(st *State) error {
					st.configureAccounts([]AccountConfig{cfg})
					return nil
				}); err != nil {
					t.Fatal(err)
				}
			}
			configure()
			h.deliver("INBOX", "Original mailbox", "")
			h.sync()
			if len(h.conversations()) != 1 {
				t.Fatal("expected cached mail")
			}
			switch change {
			case "login":
				cfg.Username = "other@example.com"
			case "endpoint":
				endpoint := *cfg.IMAP
				endpoint.Port++
				cfg.IMAP = &endpoint
			}
			configure()
			if len(h.conversations()) != 0 {
				t.Fatal("old mailbox remained visible")
			}
		})
	}
}

func TestSentFilingFailureAllowsIncomingMail(t *testing.T) {
	h := newHarness(t)
	h.sync()
	if err := h.account.store.Update(func(st *State) error {
		st.account(h.account.cfg.ID).Receipts = map[string][]byte{"<pending@example.com>": []byte("Subject: Pending\r\n\r\nhello")}
		st.Revision++
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	// The provider has an inbox but no Sent folder in which to file the pending copy.
	if err := h.lab.users[labAddress].Delete("Sent"); err != nil {
		t.Fatal(err)
	}
	h.account.disconnect()
	h.deliver("INBOX", "New mail", "", imap.FlagSeen)
	if err := h.account.Sync(); err == nil {
		t.Fatal("expected the pending Sent filing to fail")
	}
	if _, ok := h.conversations()["New mail"]; !ok {
		t.Fatal("filing blocked incoming mail")
	}
}

func TestStaleSettlePreservesProviderStar(t *testing.T) {
	h := newHarness(t)
	h.deliver("INBOX", "Starred", "", imap.FlagFlagged)
	h.sync()
	c := h.conversations()["Starred"]
	stale := ConversationState{Workflow: WorkflowSettled, Pinned: false, Fields: []string{"workflow", "unread"}}
	if code := h.request("PUT", "/v1/conversations/"+c.ID, stale, nil); code != 200 {
		t.Fatalf("Settle status %d", code)
	}
	h.sync()
	if got := h.conversations()["Starred"]; !got.Pinned || got.Workflow != WorkflowSettled {
		t.Fatal("Settle must preserve the provider's star")
	}
}
