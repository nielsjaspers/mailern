package mailsync

import (
	"strings"
	"testing"
)

func TestUnsupportedCharsetSkipsOnlyItsPart(t *testing.T) {
	raw := strings.Join([]string{
		"From: Sam <sam@example.com>",
		"To: morgan@example.com",
		"Subject: Mixed",
		"MIME-Version: 1.0",
		`Content-Type: multipart/alternative; boundary="b"`,
		"",
		"--b",
		"Content-Type: text/plain; charset=x-unknown-charset",
		"",
		"Plain",
		"--b",
		"Content-Type: text/html; charset=utf-8",
		"",
		"<p>Hello there</p>",
		"--b--",
		"",
	}, "\r\n")
	p, err := parseMessage([]byte(raw))
	if err != nil {
		t.Fatal(err)
	}
	if !p.HasHTML || p.Text != "Hello there" {
		t.Fatalf("the readable HTML part should still be used, got html=%v text=%q", p.HasHTML, p.Text)
	}
}
