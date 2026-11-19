package main

import (
	"net"
	"sync/atomic"
	"testing"
	"time"

	"github.com/emersion/go-imap/v2"
	"github.com/emersion/go-imap/v2/imapserver"
)

// bodyCounter counts the message bodies a client downloads.
type bodyCounter struct {
	imapserver.Session
	bodies *atomic.Int32
}

func (s bodyCounter) Fetch(w *imapserver.FetchWriter, set imap.NumSet, options *imap.FetchOptions) error {
	if len(options.BodySection) > 0 {
		if uids, ok := set.(imap.UIDSet); ok {
			if nums, ok := uids.Nums(); ok {
				s.bodies.Add(int32(len(nums)))
			}
		}
	}
	return s.Session.Fetch(w, set, options)
}

func TestMessageInTwoMailboxesDownloadsOnce(t *testing.T) {
	h := newHarness(t)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	var bodies atomic.Int32
	server := imapserver.New(&imapserver.Options{
		Caps: imap.CapSet{imap.CapIMAP4rev1: {}, imap.CapUIDPlus: {}}, InsecureAuth: true, Logger: quietLogger{},
		NewSession: func(*imapserver.Conn) (imapserver.Session, *imapserver.GreetingData, error) {
			return bodyCounter{h.lab.imap.NewSession(), &bodies}, nil, nil
		},
	})
	go server.Serve(listener)
	t.Cleanup(func() { server.Close() })
	h.lab.IMAP = endpointFor(listener)
	h.account.cfg.IMAP = &h.lab.IMAP
	// Gmail lists an inbox message in All Mail too.
	raw := LabMessage("Sam <sam@example.com>", labAddress, "Dinner", "Saturday?", "", time.Now())
	for _, mailbox := range []string{"INBOX", "Archive"} {
		if err := h.lab.Deliver(labAddress, mailbox, raw); err != nil {
			t.Fatal(err)
		}
	}
	h.sync()
	if got := bodies.Load(); got != 1 {
		t.Fatalf("one message in two mailboxes should download once, downloaded %d times", got)
	}
	if c := h.conversations()["Dinner"]; len(c.Messages) != 1 || c.Workflow != WorkflowInbox {
		t.Fatalf("the message should sync once, in Inbox: %+v", c)
	}
}
