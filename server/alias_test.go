package main

import (
	"bytes"
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
