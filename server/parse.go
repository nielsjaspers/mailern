package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"html"
	"io"
	"regexp"
	"strings"
	"time"

	_ "github.com/emersion/go-message/charset"
	"github.com/emersion/go-message/mail"
)

type parsed struct {
	Message
	HTML string
}

// parseMessage reads the parts Mailern shows: headers, a plain-text body, and whether an HTML body exists.
// Mail without a text part gets text made from its HTML, so snippets, search, and quotes still work.
func parseMessage(raw []byte) (parsed, error) {
	var p parsed
	r, err := mail.CreateReader(bytes.NewReader(raw))
	if err != nil && r == nil {
		return p, err
	}
	h := r.Header
	if from, _ := h.AddressList("From"); len(from) > 0 {
		p.Sender, p.Address = from[0].Name, from[0].Address
	}
	if p.Sender == "" {
		p.Sender = p.Address
	}
	p.To = addresses(h, "To")
	p.Cc = addresses(h, "Cc")
	p.Date, _ = h.Date()
	p.Subject, _ = h.Subject()
	if id, _ := h.MessageID(); id != "" {
		p.MessageID = "<" + id + ">"
	}
	if ids, _ := h.MsgIDList("In-Reply-To"); len(ids) > 0 {
		p.InReplyTo = "<" + ids[0] + ">"
	}
	if ids, _ := h.MsgIDList("References"); len(ids) > 0 {
		for _, id := range ids {
			p.References = append(p.References, "<"+id+">")
		}
	}
	for {
		part, err := r.NextPart()
		if err == io.EOF {
			break
		}
		if err != nil {
			break
		}
		inline, ok := part.Header.(*mail.InlineHeader)
		if !ok {
			continue
		}
		kind, _, _ := inline.ContentType()
		body, err := io.ReadAll(part.Body)
		if err != nil {
			continue
		}
		switch {
		case kind == "text/plain" && p.Text == "":
			p.Text = string(body)
		case kind == "text/html" && p.HTML == "":
			p.HTML = string(body)
		}
	}
	p.HasHTML = p.HTML != ""
	if p.Text == "" && p.HasHTML {
		p.Text = htmlText(p.HTML)
	}
	p.Text = strings.ReplaceAll(p.Text, "\r\n", "\n")
	return p, nil
}

func addresses(h mail.Header, key string) []string {
	list, _ := h.AddressList(key)
	out := make([]string, 0, len(list))
	for _, a := range list {
		out = append(out, a.Address)
	}
	return out
}

var (
	invisibleBlocks = regexp.MustCompile(`(?is)<(style|script|head)\b.*?</(style|script|head)>`)
	breaks          = regexp.MustCompile(`(?i)<(br|/p|/div|/tr|/h[1-6]|/li)\b[^>]*>`)
	tags            = regexp.MustCompile(`(?s)<[^>]*>`)
	blankLines      = regexp.MustCompile(`\n\s*\n\s*\n+`)
	spaces          = regexp.MustCompile(`[ \t\f\v]+`)
)

func htmlText(s string) string {
	s = invisibleBlocks.ReplaceAllString(s, "")
	s = breaks.ReplaceAllString(s, "\n")
	s = tags.ReplaceAllString(s, "")
	s = html.UnescapeString(s)
	s = spaces.ReplaceAllString(s, " ")
	s = blankLines.ReplaceAllString(s, "\n\n")
	return strings.TrimSpace(s)
}

// messageKey identifies a message within an account. Gmail lists one message in several mailboxes,
// and a move gives it a new UID, but its Message-ID stays the same.
func messageKey(messageID string, date time.Time, from, subject string) string {
	if messageID != "" {
		return messageID
	}
	sum := sha256.Sum256(fmt.Appendf(nil, "%d\x00%s\x00%s", date.Unix(), strings.ToLower(from), subject))
	return "sha256:" + hex.EncodeToString(sum[:16])
}
