package main

import (
	"bytes"
	"errors"
	"fmt"
	"io"
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
	known, uncertain := false, false
	var invalidThread bool
	a.store.Read(func(st *State) {
		account := st.account(a.cfg.ID)
		_, known = account.Receipts[key]
		uncertain = account.Submitting[key]
		thread := st.Conversations[req.ConversationID]
		invalidThread = thread != nil && (thread.AccountID != a.cfg.ID || thread.Deleting)
	})
	if known {
		// An earlier state write might still need to reach disk.
		a.Trigger()
		return a.store.Update(func(*State) error { return nil })
	}
	if invalidThread {
		return badRequest{errors.New("the original conversation is unavailable")}
	}
	c, err := a.connect()
	if err != nil {
		return err
	}
	sent := a.mailboxes[RoleSent]
	if sent != "" {
		found, err := sentContains(c, sent, key)
		if err != nil {
			a.disconnect()
			return err
		}
		if found {
			return a.record(req, key, nil)
		}
	} else if *a.cfg.AppendSent {
		return errors.New("configure a Sent mailbox before sending")
	}
	if uncertain {
		return uncertainDelivery
	}
	if req.InReplyTo != "" {
		var present bool
		a.store.Read(func(st *State) {
			thread := st.Conversations[req.ConversationID]
			present = thread != nil && thread.AccountID == a.cfg.ID && !thread.Deleting
		})
		if !present {
			return badRequest{errors.New("the original message is unavailable")}
		}
	}
	raw, err := a.compose(req, key)
	if err != nil {
		return badRequest{err}
	}
	if err := a.submit(req, raw); err != nil {
		return err
	}
	var toFile []byte
	if *a.cfg.AppendSent {
		toFile = raw
	}
	err = a.record(req, key, toFile)
	a.Trigger()
	if err != nil || toFile == nil {
		return err
	}
	// SMTP accepted the message. A sync retries Sent filing if IMAP is unavailable.
	if err := a.fileSent(c); err != nil {
		a.disconnect()
	}
	return nil
}

func sentContains(c *imapclient.Client, sent, key string) (bool, error) {
	if _, err := c.Select(sent, &imap.SelectOptions{ReadOnly: true}).Wait(); err != nil {
		return false, err
	}
	criteria := &imap.SearchCriteria{Header: []imap.SearchCriteriaHeaderField{{Key: "Message-ID", Value: key}}}
	found, err := c.UIDSearch(criteria, nil).Wait()
	if err != nil {
		return false, err
	}
	return len(found.AllUIDs()) != 0, nil
}

func (a *Account) fileSent(c *imapclient.Client) error {
	pending := make(map[string][]byte)
	a.store.Read(func(st *State) {
		for key, raw := range st.account(a.cfg.ID).Receipts {
			if len(raw) > 0 {
				pending[key] = raw
			}
		}
	})
	for key, raw := range pending {
		sent := a.mailboxes[RoleSent]
		found, err := sentContains(c, sent, key)
		if err != nil {
			return err
		}
		if !found {
			if err := appendMessage(c, sent, raw, []imap.Flag{imap.FlagSeen}); err != nil {
				return err
			}
		}
		if err := a.store.Update(func(st *State) error {
			st.account(a.cfg.ID).Receipts[key] = nil
			st.Revision++
			return nil
		}); err != nil {
			return err
		}
	}
	return nil
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
func (a *Account) record(req SendRequest, key string, toFile []byte) error {
	now := time.Now()
	return a.store.Update(func(st *State) error {
		account := st.account(a.cfg.ID)
		if account.Receipts == nil {
			account.Receipts = make(map[string][]byte)
		}
		delete(account.Submitting, key)
		account.Receipts[key] = toFile
		if account.Messages[key] != nil {
			st.Revision++
			return nil
		}
		sender := a.cfg.SenderName
		if sender == "" {
			sender = a.cfg.Address
		}
		m := &Message{
			ID: strings.ToLower(req.ID), Key: key, ConversationID: req.ConversationID, Sender: sender,
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
	var utf8 bool
	for _, address := range append(recipients, a.cfg.Address) {
		if strings.ContainsFunc(address, func(r rune) bool { return r > 127 }) {
			utf8 = true
		}
	}
	if err := c.Mail(a.cfg.Address, &smtp.MailOptions{UTF8: utf8}); err != nil {
		return submissionError(err)
	}
	for _, addr := range recipients {
		if err := c.Rcpt(addr, nil); err != nil {
			return submissionError(err)
		}
	}
	data, err := c.Data()
	if err != nil {
		return submissionError(err)
	}
	if _, err := data.Write(raw); err != nil {
		return err
	}
	// DATA close sends the terminator that allows the server to accept the mail.
	key := a.messageID(req.ID)
	if err := a.markSubmitting(key, true); err != nil {
		return errors.Join(err, a.markSubmitting(key, false))
	}
	if err := data.Close(); err != nil {
		var rejection *smtp.SMTPError
		if errors.As(err, &rejection) {
			return errors.Join(submissionError(err), a.markSubmitting(key, false))
		}
		return uncertainDelivery
	}
	return nil
}

var uncertainDelivery = badRequest{errors.New("delivery could not be confirmed; check with the recipient before sending a new copy")}

func submissionError(err error) error {
	var rejection *smtp.SMTPError
	if errors.As(err, &rejection) && rejection.Code >= 500 {
		return badRequest{err}
	}
	return err
}

func (a *Account) markSubmitting(key string, active bool) error {
	return a.store.Update(func(st *State) error {
		account := st.account(a.cfg.ID)
		if active {
			if account.Submitting == nil {
				account.Submitting = make(map[string]bool)
			}
			account.Submitting[key] = true
		} else {
			delete(account.Submitting, key)
		}
		st.Revision++
		return nil
	})
}

// badRequest marks errors that a retry cannot fix, such as a rejected recipient.
type badRequest struct{ error }
