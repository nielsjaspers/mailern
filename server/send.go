package main

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"log"
	"strings"
	"time"

	"github.com/emersion/go-imap/v2"
	"github.com/emersion/go-imap/v2/imapclient"
	"github.com/emersion/go-message/mail"
	"github.com/emersion/go-sasl"
	"github.com/emersion/go-smtp"
	"github.com/google/uuid"
)

type OutgoingAttachment struct {
	Name        string `json:"name"`
	ContentType string `json:"contentType"`
	Data        []byte `json:"data"`
}

// SendRequest is a message from the phone. ID is the draft's ID; it also names the Message-ID, so a retry
// after a lost response finds the first copy instead of sending a second one.
type SendRequest struct {
	ID             string               `json:"id"`
	ConversationID string               `json:"conversationID"`
	AccountID      string               `json:"accountID"`
	To             []string             `json:"to"`
	Cc             []string             `json:"cc"`
	Bcc            []string             `json:"bcc"`
	Subject        string               `json:"subject"`
	Text           string               `json:"text"`
	HTML           string               `json:"html,omitempty"`
	InReplyTo      string               `json:"inReplyTo,omitempty"`
	References     []string             `json:"references,omitempty"`
	Attachments    []OutgoingAttachment `json:"attachments,omitempty"`
}

func (r SendRequest) validate() error {
	if _, err := uuid.Parse(r.ID); err != nil {
		return errors.New("id must be a UUID")
	}
	if _, err := uuid.Parse(r.ConversationID); err != nil {
		return errors.New("conversationID must be a UUID")
	}
	if len(r.To)+len(r.Cc)+len(r.Bcc) == 0 {
		return errors.New("add a recipient")
	}
	return nil
}

func (a *Account) messageID(draftID string) string {
	domain := a.cfg.Address[strings.LastIndex(a.cfg.Address, "@")+1:]
	return "<" + strings.ToLower(draftID) + "@" + domain + ">"
}

// Send delivers a message and files it in its conversation. A message that already went out, according to this
// service or to the account's Sent mailbox, is not sent again.
func (a *Account) Send(req SendRequest) error {
	if err := req.validate(); err != nil {
		return badRequest{err}
	}
	key := a.messageID(req.ID)
	a.mu.Lock()
	defer a.mu.Unlock()
	known := false
	a.store.Read(func(st *State) { known = st.account(a.cfg.ID).Messages[key] != nil })
	if known {
		return nil
	}
	c, err := a.connect()
	if err != nil {
		return err
	}
	if sent := a.mailboxes[RoleSent]; sent != "" {
		if _, err := c.Select(sent, nil).Wait(); err != nil {
			a.disconnect()
			return err
		}
		criteria := &imap.SearchCriteria{Header: []imap.SearchCriteriaHeaderField{{Key: "Message-ID", Value: key}}}
		found, err := c.UIDSearch(criteria, nil).Wait()
		if err != nil {
			a.disconnect()
			return err
		}
		if len(found.AllUIDs()) > 0 {
			return a.record(req, key)
		}
	}
	raw, err := a.compose(req, key)
	if err != nil {
		return badRequest{err}
	}
	if err := a.submit(req, raw); err != nil {
		return err
	}
	if *a.cfg.AppendSent && a.mailboxes[RoleSent] != "" {
		if err := appendMessage(c, a.mailboxes[RoleSent], raw, []imap.Flag{imap.FlagSeen}); err != nil {
			// The mail went out, so the send succeeds. Without a Sent copy, the message leaves its
			// conversation when its wait for one ends.
			a.disconnect()
			log.Printf("%s: saving to Sent failed: %v", a.cfg.ID, err)
		}
	}
	err = a.record(req, key)
	a.Trigger()
	return err
}

func appendMessage(c *imapclient.Client, mailbox string, raw []byte, flags []imap.Flag) error {
	cmd := c.Append(mailbox, int64(len(raw)), &imap.AppendOptions{Flags: flags, Time: time.Now()})
	if _, err := cmd.Write(raw); err != nil {
		cmd.Close()
		return err
	}
	if err := cmd.Close(); err != nil {
		return err
	}
	_, err := cmd.Wait()
	return err
}

// record adds a sent message to the service state, so the phone sees it before the Sent copy syncs.
func (a *Account) record(req SendRequest, key string) error {
	now := time.Now()
	return a.store.Update(func(st *State) error {
		account := st.account(a.cfg.ID)
		if account.Messages[key] != nil {
			return nil
		}
		m := &Message{
			ID: strings.ToLower(req.ID), Key: key, ConversationID: req.ConversationID, Sender: a.cfg.Name,
			Address: a.cfg.Address, To: req.To, Cc: req.Cc, Date: now, Subject: req.Subject, Text: req.Text,
			HasHTML: req.HTML != "", MessageID: key, InReplyTo: req.InReplyTo, References: req.References,
			Outgoing: true, Seen: true, Locations: map[Role]uint32{}, SentAt: &now,
		}
		account.Messages[key] = m
		c := st.Conversations[req.ConversationID]
		if c == nil || c.AccountID != a.cfg.ID {
			c = &Conversation{ID: req.ConversationID, AccountID: a.cfg.ID, Subject: req.Subject, Workflow: WorkflowSettled}
			if c.Subject == "" {
				c.Subject = "(No Subject)"
			}
			m.ConversationID = c.ID
			st.Conversations[c.ID] = c
		}
		c.Keys = append(c.Keys, key)
		sortMessages(c, account)
		st.Touch(c)
		return nil
	})
}

func (a *Account) compose(req SendRequest, key string) ([]byte, error) {
	var h mail.Header
	h.SetDate(time.Now())
	h.SetAddressList("From", []*mail.Address{{Name: a.cfg.SenderName, Address: a.cfg.Address}})
	h.SetAddressList("To", mailAddresses(req.To))
	if len(req.Cc) > 0 {
		h.SetAddressList("Cc", mailAddresses(req.Cc))
	}
	h.SetSubject(req.Subject)
	h.SetMessageID(strings.Trim(key, "<>"))
	if req.InReplyTo != "" {
		h.SetMsgIDList("In-Reply-To", []string{strings.Trim(req.InReplyTo, "<>")})
	}
	if len(req.References) > 0 {
		ids := make([]string, len(req.References))
		for i, r := range req.References {
			ids[i] = strings.Trim(r, "<>")
		}
		h.SetMsgIDList("References", ids)
	}
	var buf bytes.Buffer
	w, err := mail.CreateWriter(&buf, h)
	if err != nil {
		return nil, err
	}
	body, err := w.CreateInline()
	if err != nil {
		return nil, err
	}
	parts := [][2]string{{"text/plain", req.Text}}
	if req.HTML != "" {
		parts = append(parts, [2]string{"text/html", req.HTML})
	}
	for _, part := range parts {
		var ph mail.InlineHeader
		ph.SetContentType(part[0], map[string]string{"charset": "utf-8"})
		pw, err := body.CreatePart(ph)
		if err != nil {
			return nil, err
		}
		io.WriteString(pw, part[1])
		pw.Close()
	}
	body.Close()
	for _, file := range req.Attachments {
		var ah mail.AttachmentHeader
		kind := file.ContentType
		if kind == "" {
			kind = "application/octet-stream"
		}
		ah.SetContentType(kind, nil)
		ah.SetFilename(file.Name)
		aw, err := w.CreateAttachment(ah)
		if err != nil {
			return nil, err
		}
		aw.Write(file.Data)
		aw.Close()
	}
	if err := w.Close(); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func mailAddresses(list []string) []*mail.Address {
	out := make([]*mail.Address, len(list))
	for i, address := range list {
		out[i] = &mail.Address{Address: address}
	}
	return out
}

func (a *Account) smtpClient() (*smtp.Client, error) {
	e := *a.cfg.SMTP
	var c *smtp.Client
	var err error
	switch e.Security {
	case "starttls":
		c, err = smtp.DialStartTLS(e.Address(), a.tlsConfig(e))
	case "none":
		if !e.Loopback() {
			return nil, errors.New("unencrypted SMTP is allowed only on this machine")
		}
		c, err = smtp.Dial(e.Address())
	default:
		c, err = smtp.DialTLS(e.Address(), a.tlsConfig(e))
	}
	if err != nil {
		return nil, err
	}
	if e.Security != "none" {
		if err := c.Auth(sasl.NewPlainClient("", a.cfg.Username, a.cfg.password)); err != nil {
			c.Close()
			return nil, fmt.Errorf("smtp login: %w", err)
		}
	}
	return c, nil
}

func (a *Account) checkSMTP() error {
	c, err := a.smtpClient()
	if err != nil {
		return err
	}
	defer c.Close()
	return c.Quit()
}

func (a *Account) submit(req SendRequest, raw []byte) error {
	c, err := a.smtpClient()
	if err != nil {
		return err
	}
	defer c.Close()
	recipients := append(append(append([]string{}, req.To...), req.Cc...), req.Bcc...)
	if err := c.SendMail(a.cfg.Address, recipients, bytes.NewReader(raw)); err != nil {
		var smtpErr *smtp.SMTPError
		if errors.As(err, &smtpErr) && smtpErr.Code >= 500 {
			return badRequest{err}
		}
		return err
	}
	return c.Quit()
}

// badRequest marks errors that a retry cannot fix, such as a rejected recipient.
type badRequest struct{ error }
