package main

import (
	"bytes"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/emersion/go-imap/v2"
	"github.com/emersion/go-imap/v2/imapserver"
	"github.com/emersion/go-imap/v2/imapserver/imapmemserver"
	"github.com/emersion/go-sasl"
	"github.com/emersion/go-smtp"
	"github.com/google/uuid"
)

// MailLab runs a fictional IMAP and SMTP server on this machine. The demo command and the tests use it,
// so neither needs a real account. Mail sent to one of its addresses lands in that account's inbox.
type MailLab struct {
	imap  *imapmemserver.Server
	users map[string]*imapmemserver.User
	IMAP  Endpoint
	SMTP  Endpoint
	close []func() error
	mu    sync.Mutex
	// Every message the SMTP server accepted, for tests.
	Submitted [][]byte
}

var labMailboxes = map[string]imap.MailboxAttr{
	"Archive": imap.MailboxAttrArchive, "Sent": imap.MailboxAttrSent,
	"Junk": imap.MailboxAttrJunk, "Trash": imap.MailboxAttrTrash,
}

func StartMailLab(addresses ...string) (*MailLab, error) {
	lab := &MailLab{imap: imapmemserver.New(), users: map[string]*imapmemserver.User{}}
	for _, address := range addresses {
		user := imapmemserver.NewUser(address, "lab")
		if err := user.Create("INBOX", nil); err != nil {
			return nil, err
		}
		for name, attr := range labMailboxes {
			if err := user.Create(name, &imap.CreateOptions{SpecialUse: []imap.MailboxAttr{attr}}); err != nil {
				return nil, err
			}
		}
		lab.imap.AddUser(user)
		lab.users[address] = user
	}
	imapListener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	server := imapserver.New(&imapserver.Options{
		NewSession: func(*imapserver.Conn) (imapserver.Session, *imapserver.GreetingData, error) {
			return lab.imap.NewSession(), nil, nil
		},
		Caps:         imap.CapSet{imap.CapIMAP4rev1: {}, imap.CapIMAP4rev2: {}},
		InsecureAuth: true,
		Logger:       quietLogger{},
	})
	go server.Serve(imapListener)
	smtpListener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	smtpServer := smtp.NewServer(labBackend{lab})
	smtpServer.Domain = "localhost"
	smtpServer.AllowInsecureAuth = true
	go smtpServer.Serve(smtpListener)
	lab.IMAP = endpointFor(imapListener)
	lab.SMTP = endpointFor(smtpListener)
	lab.close = []func() error{server.Close, smtpServer.Close}
	return lab, nil
}

type quietLogger struct{}

func (quietLogger) Printf(string, ...any) {}

func endpointFor(l net.Listener) Endpoint {
	addr := l.Addr().(*net.TCPAddr)
	return Endpoint{Host: "127.0.0.1", Port: addr.Port, Security: "none"}
}

func (lab *MailLab) Close() {
	for _, f := range lab.close {
		f()
	}
}

// Account returns a config for one of the lab's addresses.
func (lab *MailLab) Account(id, name, address string) AccountConfig {
	imapEndpoint, smtpEndpoint := lab.IMAP, lab.SMTP
	appendSent := true
	return AccountConfig{ID: id, Name: name, Address: address, Provider: "imap", Username: address, SenderName: "Morgan",
		IMAP: &imapEndpoint, SMTP: &smtpEndpoint, AppendSent: &appendSent, password: "lab"}
}

// Deliver puts a message straight into a mailbox, as if it arrived from outside.
func (lab *MailLab) Deliver(address, mailbox string, raw []byte, flags ...imap.Flag) error {
	user := lab.users[address]
	if user == nil {
		return fmt.Errorf("no lab account %s", address)
	}
	_, err := user.Append(mailbox, bytes.NewReader(raw), &imap.AppendOptions{Flags: flags, Time: time.Now()})
	return err
}

type labBackend struct{ lab *MailLab }

func (b labBackend) NewSession(*smtp.Conn) (smtp.Session, error) { return &labSession{lab: b.lab}, nil }

type labSession struct {
	lab *MailLab
	to  []string
}

func (s *labSession) AuthMechanisms() []string { return []string{"PLAIN"} }
func (s *labSession) Auth(string) (sasl.Server, error) {
	return sasl.NewPlainServer(func(identity, username, password string) error { return nil }), nil
}
func (s *labSession) Reset()                                    { s.to = nil }
func (s *labSession) Logout() error                             { return nil }
func (s *labSession) Mail(string, *smtp.MailOptions) error      { return nil }
func (s *labSession) Rcpt(to string, _ *smtp.RcptOptions) error { s.to = append(s.to, to); return nil }
func (s *labSession) Data(r io.Reader) error {
	raw, err := io.ReadAll(r)
	if err != nil {
		return err
	}
	s.lab.mu.Lock()
	s.lab.Submitted = append(s.lab.Submitted, raw)
	s.lab.mu.Unlock()
	for _, to := range s.to {
		if s.lab.users[to] != nil {
			s.lab.Deliver(to, "INBOX", raw)
		}
	}
	return nil
}

// LabMessage writes a plain fictional message. replyTo is the Message-ID it answers, if any.
func LabMessage(from, to, subject, body, replyTo string, date time.Time) []byte {
	var b strings.Builder
	fmt.Fprintf(&b, "From: %s\r\nTo: %s\r\nSubject: %s\r\nDate: %s\r\nMessage-ID: <%s@lab.example.com>\r\n",
		from, to, subject, date.Format(time.RFC1123Z), uuid.NewString())
	if replyTo != "" {
		fmt.Fprintf(&b, "In-Reply-To: %s\r\nReferences: %s\r\n", replyTo, replyTo)
	}
	fmt.Fprintf(&b, "Content-Type: text/plain; charset=utf-8\r\n\r\n%s\r\n", strings.ReplaceAll(body, "\n", "\r\n"))
	return []byte(b.String())
}

func labMessageID(raw []byte) string {
	for _, line := range strings.Split(string(raw), "\r\n") {
		if id, ok := strings.CutPrefix(line, "Message-ID: "); ok {
			return id
		}
	}
	return ""
}

const (
	demoPersonal = "morgan@personal.example.com"
	demoWork     = "morgan@work.example.com"
)

// seedDemo fills the lab with a small fictional mailbox.
func seedDemo(lab *MailLab) error {
	now := time.Now()
	dinner := LabMessage("Sam Rivera <sam@example.com>", demoPersonal, "Dinner on Saturday?",
		"Hi Morgan,\n\nWe're having a few people over on Saturday around seven. Would you like to come?\n\nSam", "", now.Add(-3*time.Hour))
	notes := LabMessage("Alex Chen <alex@example.org>", demoWork, "Workshop notes",
		"Hi Morgan,\n\nHere are the notes from Tuesday's workshop. The next session is on the 14th.\n\nAlex", "", now.Add(-26*time.Hour))
	invoice := LabMessage("Billing <billing@example.net>", demoPersonal, "Your receipt",
		"Thanks for your order. Your receipt number is 1042.", "", now.Add(-72*time.Hour))
	prize := LabMessage("Prize Desk <winner@prizes.example.net>", demoWork, "You have been selected",
		"Congratulations! Confirm your details within 24 hours.", "", now.Add(-5*time.Hour))
	for _, m := range []struct {
		to, mailbox string
		raw         []byte
		flags       []imap.Flag
	}{
		{demoPersonal, "INBOX", dinner, nil},
		{demoWork, "INBOX", notes, []imap.Flag{imap.FlagSeen}},
		{demoPersonal, "Archive", invoice, []imap.Flag{imap.FlagSeen}},
		{demoWork, "Junk", prize, nil},
	} {
		if err := lab.Deliver(m.to, m.mailbox, m.raw, m.flags...); err != nil {
			return err
		}
	}
	return nil
}

// demoReceive adds a fictional reply to the newest inbox thread of an account, so the demo can show arrivals.
func demoReceive(lab *MailLab) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		address := demoPersonal
		if r.URL.Query().Get("account") == "work" {
			address = demoWork
		}
		replyTo := r.URL.Query().Get("inReplyTo")
		subject := r.URL.Query().Get("subject")
		if subject == "" {
			subject = "Coffee this week?"
		}
		raw := LabMessage("Riley Park <riley@example.com>", address, subject,
			"Hi Morgan,\n\nA quick follow-up. Do you have time this week?\n\nRiley", replyTo, time.Now())
		if err := lab.Deliver(address, "INBOX", raw); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}
}
