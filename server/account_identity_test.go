package main

import (
	"testing"

	"github.com/emersion/go-imap/v2"
)

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
