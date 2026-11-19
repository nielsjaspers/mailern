package main

import (
	"bytes"
	"encoding/json"
	"net"
	"net/http"
	"testing"
	"time"

	"github.com/emersion/go-imap/v2"
	"github.com/google/uuid"
)

func TestAccountSendsAndRecognizesAliases(t *testing.T) {
	h := newHarness(t)
	const alias = "morgan@alias.example.com"
	h.account.cfg.Aliases = []string{alias}
	parent := h.deliver("INBOX", "Plans", "")
	// Mail sent as the alias from another client counts as the user's own.
	other := LabMessage("Morgan <"+alias+">", "sam@example.com", "Sent elsewhere", "Hi.", "", time.Now())
	if err := h.lab.Deliver(labAddress, "Sent", other, imap.FlagSeen); err != nil {
		t.Fatal(err)
	}
	h.sync()
	if m := h.conversations()["Sent elsewhere"].Messages[0]; !m.Outgoing {
		t.Fatal("mail from an alias should be outgoing")
	}
	c := h.conversations()["Plans"]
	req := SendRequest{ID: uuid.NewString(), ConversationID: c.ID, AccountID: "lab", To: []string{"sam@example.com"},
		Subject: "Re: Plans", Text: "Yes.", InReplyTo: parent, References: []string{parent}, From: "Morgan@Alias.example.com"}
	if code := h.request("POST", "/v1/send", req, nil); code != http.StatusNoContent {
		t.Fatalf("send: %d", code)
	}
	if len(h.lab.Submitted) != 1 || !bytes.Contains(h.lab.Submitted[0], []byte("<"+alias+">")) {
		t.Fatal("the reply should go out from the alias")
	}
	if !bytes.Contains(h.lab.Submitted[0], []byte("Message-Id: <"+req.ID+"@alias.example.com>")) {
		t.Fatalf("the Message-ID should use the alias's domain:\n%s", h.lab.Submitted[0])
	}
	h.sync()
	if m := h.conversations()["Plans"].Messages[1]; !m.Outgoing || m.Address != alias {
		t.Fatalf("the sent reply should be outgoing from the alias, got %+v", m)
	}
	req.ID, req.From = uuid.NewString(), "stranger@example.com"
	if code := h.request("POST", "/v1/send", req, nil); code != http.StatusUnprocessableEntity {
		t.Fatalf("an address outside the account must be refused, got %d", code)
	}
	var resp syncResponse
	h.request("GET", "/v1/sync?since=0", nil, &resp)
	if len(resp.Accounts) != 1 || len(resp.Accounts[0].Aliases) != 1 || resp.Accounts[0].Aliases[0] != alias {
		t.Fatalf("the phone should learn the aliases, got %+v", resp.Accounts)
	}
}

func TestConfigRefusesAnAddressListedTwice(t *testing.T) {
	t.Setenv("MAILERN_TEST_PASSWORD", "secret")
	for name, accounts := range map[string][]AccountConfig{
		"two accounts": {
			{ID: "a", Address: "me@example.com", Provider: "gmail", PasswordEnv: "MAILERN_TEST_PASSWORD"},
			{ID: "b", Address: "other@example.com", Aliases: []string{"Me@example.com"}, Provider: "icloud", PasswordEnv: "MAILERN_TEST_PASSWORD"},
		},
		"one account": {
			{ID: "a", Address: "me@example.com", Aliases: []string{"me@example.com"}, Provider: "gmail", PasswordEnv: "MAILERN_TEST_PASSWORD"},
		},
	} {
		cfg := Config{StateDir: t.TempDir(), Accounts: accounts}
		if err := cfg.resolve(t.TempDir()); err == nil {
			t.Errorf("%s: an address listed twice must be refused", name)
		}
	}
}

func TestRetryAcceptedDraftAfterRemovingAlias(t *testing.T) {
	h := newHarness(t)
	h.account.cfg.Aliases = []string{"morgan@alias.example.com"}
	req := SendRequest{ID: uuid.NewString(), ConversationID: uuid.NewString(), AccountID: "lab", To: []string{"sam@example.com"}, From: h.account.cfg.Aliases[0]}
	if code := h.request("POST", "/v1/send", req, nil); code != 204 {
		t.Fatalf("initial send: %d", code)
	}
	h.account.cfg.Aliases = nil
	for _, address := range []string{req.From, labAddress} {
		req.From = address
		if code := h.request("POST", "/v1/send", req, nil); code != 204 || len(h.lab.Submitted) != 1 {
			t.Fatalf("retry: status %d, deliveries %d", code, len(h.lab.Submitted))
		}
	}
}

func TestProviderConnectionRefusedIsConfirmedUnsent(t *testing.T) {
	for _, protocol := range []string{"imap", "smtp"} {
		t.Run(protocol, func(t *testing.T) {
			h := newHarness(t)
			socket, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			endpoint := endpointFor(socket)
			socket.Close()
			if protocol == "smtp" {
				h.account.cfg.SMTP = &endpoint
			} else {
				h.account.cfg.IMAP = &endpoint
			}
			req := SendRequest{ID: uuid.NewString(), ConversationID: uuid.NewString(), AccountID: "lab", To: []string{"sam@example.com"}}
			body, err := json.Marshal(req)
			if err != nil {
				t.Fatal(err)
			}
			resp, err := h.http.Client().Post(h.http.URL+"/v1/send", "application/json", bytes.NewReader(body))
			if err != nil {
				t.Fatal(err)
			}
			defer resp.Body.Close()
			if resp.StatusCode != 503 || resp.Header.Get("Mailern-Submission") != "not-accepted" || len(h.lab.Submitted) != 0 {
				t.Fatalf("unexpected submission result: %d %q", resp.StatusCode, resp.Header.Get("Mailern-Submission"))
			}
		})
	}
}
