// Package maillab runs a fictional IMAP and SMTP server on this machine. The demo command and the tests use it,
// so neither needs a real account.
package maillab

import (
	"bytes"
	"fmt"
	"io"
	"net"
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

// Password signs in to every lab account.
const Password = "lab"

// Lab is a running fictional mail server. Mail sent to one of its addresses lands in that account's inbox.
type Lab struct {
	imap  *imapmemserver.Server
	users map[string]*imapmemserver.User
	// IMAPAddr and SMTPAddr are host:port on the loopback interface, without TLS.
	IMAPAddr string
	SMTPAddr string
	close    []func() error

	mu        sync.Mutex
	submitted [][]byte
}

// The in-memory server ignores special-use attributes, so mail clients find these mailboxes by name.
var mailboxes = []string{"INBOX", "Archive", "Sent", "Junk", "Trash"}

// Start runs a lab with one account per address.
func Start(addresses ...string) (*Lab, error) {
	lab := &Lab{imap: imapmemserver.New(), users: map[string]*imapmemserver.User{}}
	for _, address := range addresses {
		user := imapmemserver.NewUser(address, Password)
		for _, name := range mailboxes {
			if err := user.Create(name, nil); err != nil {
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
		Logger:       QuietLogger{},
	})
	go server.Serve(imapListener)
	smtpListener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		imapListener.Close()
		return nil, err
	}
	smtpServer := smtp.NewServer(backend{lab})
	smtpServer.Domain = "localhost"
	smtpServer.AllowInsecureAuth = true
	go smtpServer.Serve(smtpListener)
	lab.IMAPAddr = imapListener.Addr().String()
	lab.SMTPAddr = smtpListener.Addr().String()
	lab.close = []func() error{server.Close, smtpServer.Close}
	return lab, nil
}

// QuietLogger discards IMAP server logs.
type QuietLogger struct{}

func (QuietLogger) Printf(string, ...any) {}

func (lab *Lab) Close() {
	for _, f := range lab.close {
		f()
	}
}

// NewSession opens a session on the lab's mailboxes, for tests that serve them through their own IMAP server.
func (lab *Lab) NewSession() imapserver.Session { return lab.imap.NewSession() }

// User returns the mailboxes of one lab address.
func (lab *Lab) User(address string) *imapmemserver.User { return lab.users[address] }

// Submitted returns every message the SMTP server accepted, oldest first.
func (lab *Lab) Submitted() [][]byte {
	lab.mu.Lock()
	defer lab.mu.Unlock()
	return append([][]byte(nil), lab.submitted...)
}

// Deliver puts a message straight into a mailbox, as if it arrived from outside.
func (lab *Lab) Deliver(address, mailbox string, raw []byte, flags ...imap.Flag) error {
	user := lab.users[address]
	if user == nil {
		return fmt.Errorf("no lab account %s", address)
	}
	_, err := user.Append(mailbox, bytes.NewReader(raw), &imap.AppendOptions{Flags: flags, Time: time.Now()})
	return err
}

type backend struct{ lab *Lab }

func (b backend) NewSession(*smtp.Conn) (smtp.Session, error) { return &session{lab: b.lab}, nil }

type session struct {
	lab *Lab
	to  []string
}

func (s *session) AuthMechanisms() []string { return []string{"PLAIN"} }
func (s *session) Auth(string) (sasl.Server, error) {
	return sasl.NewPlainServer(func(identity, username, password string) error { return nil }), nil
}
func (s *session) Reset()                                    { s.to = nil }
func (s *session) Logout() error                             { return nil }
func (s *session) Mail(string, *smtp.MailOptions) error      { return nil }
func (s *session) Rcpt(to string, _ *smtp.RcptOptions) error { s.to = append(s.to, to); return nil }
func (s *session) Data(r io.Reader) error {
	raw, err := io.ReadAll(r)
	if err != nil {
		return err
	}
	s.lab.mu.Lock()
	s.lab.submitted = append(s.lab.submitted, raw)
	s.lab.mu.Unlock()
	for _, to := range s.to {
		if s.lab.users[to] != nil {
			s.lab.Deliver(to, "INBOX", raw)
		}
	}
	return nil
}

// Message writes a plain fictional message. replyTo is the Message-ID it answers, if any.
func Message(from, to, subject, body, replyTo string, date time.Time) []byte {
	var b strings.Builder
	fmt.Fprintf(&b, "From: %s\r\nTo: %s\r\nSubject: %s\r\nDate: %s\r\nMessage-ID: <%s@lab.example.com>\r\n",
		from, to, subject, date.Format(time.RFC1123Z), uuid.NewString())
	if replyTo != "" {
		fmt.Fprintf(&b, "In-Reply-To: %s\r\nReferences: %s\r\n", replyTo, replyTo)
	}
	fmt.Fprintf(&b, "Content-Type: text/plain; charset=utf-8\r\n\r\n%s\r\n", strings.ReplaceAll(body, "\n", "\r\n"))
	return []byte(b.String())
}

// MessageID returns the Message-ID header of a message written by Message.
func MessageID(raw []byte) string {
	for _, line := range strings.Split(string(raw), "\r\n") {
		if id, ok := strings.CutPrefix(line, "Message-ID: "); ok {
			return id
		}
	}
	return ""
}
