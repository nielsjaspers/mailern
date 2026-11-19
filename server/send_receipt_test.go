package main

import (
	"bufio"
	"fmt"
	"net"
	"net/textproto"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestSubmissionEndsAtSMTPAcceptance(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		conn.SetDeadline(time.Now().Add(5 * time.Second))
		reader := textproto.NewReader(bufio.NewReader(conn))
		fmt.Fprint(conn, "220 localhost ESMTP\r\n")
		for {
			line, err := reader.ReadLine()
			if err != nil {
				return
			}
			if strings.EqualFold(line, "DATA") {
				fmt.Fprint(conn, "354 Send message\r\n")
				if _, err := reader.ReadDotBytes(); err == nil {
					fmt.Fprint(conn, "250 Accepted\r\n")
				}
				return
			}
			fmt.Fprint(conn, "250 OK\r\n")
		}
	}()
	endpoint := endpointFor(listener)
	store, err := OpenStore(filepath.Join(t.TempDir(), "state.json"))
	if err != nil {
		t.Fatal(err)
	}
	account := Account{store: store, cfg: AccountConfig{Address: labAddress, SMTP: &endpoint}}
	if err := account.submit(SendRequest{To: []string{"sam@example.com"}}, []byte("Subject: Hello\r\n\r\nHi")); err != nil {
		t.Fatalf("accepted delivery reported as failed: %v", err)
	}
}

func TestRestartAfterSMTPAcceptanceDoesNotResubmit(t *testing.T) {
	h := newHarness(t)
	h.sync()
	req := SendRequest{ID: "a2a16159-c8b5-47b0-8df8-d09fa58cccb0", ConversationID: "773d0952-7399-4227-91c4-438e25311b1b", To: []string{"sam@example.com"}, Subject: "Delivery"}
	raw, err := h.account.compose(req, h.account.messageID(req.ID))
	if err != nil {
		t.Fatal(err)
	}
	if err := h.account.submit(req, raw); err != nil {
		t.Fatal(err)
	}
	// Reopen exactly at the boundary between SMTP acceptance and receipt persistence.
	store, err := OpenStore(h.account.store.path)
	if err != nil {
		t.Fatal(err)
	}
	restarted := NewAccount(h.account.cfg, store, time.Hour)
	if err := restarted.Send(req); err != uncertainDelivery || len(h.lab.Submitted) != 1 {
		t.Fatalf("restart after acceptance: %v, deliveries %d", err, len(h.lab.Submitted))
	}
}
