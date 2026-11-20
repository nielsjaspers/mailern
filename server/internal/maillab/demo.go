package maillab

import (
	"net/http"
	"time"

	"github.com/emersion/go-imap/v2"
)

// The demo's two fictional accounts.
const (
	DemoPersonal = "morgan@personal.example.com"
	DemoWork     = "morgan@work.example.com"
)

// SeedDemo fills a lab started with the demo addresses with a small fictional mailbox.
func SeedDemo(lab *Lab) error {
	now := time.Now()
	dinner := Message("Sam Rivera <sam@example.com>", DemoPersonal, "Dinner on Saturday?",
		"Hi Morgan,\n\nWe're having a few people over on Saturday around seven. Would you like to come?\n\nSam", "", now.Add(-3*time.Hour))
	notes := Message("Alex Chen <alex@example.org>", DemoWork, "Workshop notes",
		"Hi Morgan,\n\nHere are the notes from Tuesday's workshop. The next session is on the 14th.\n\nAlex", "", now.Add(-26*time.Hour))
	invoice := Message("Billing <billing@example.net>", DemoPersonal, "Your receipt",
		"Thanks for your order. Your receipt number is 1042.", "", now.Add(-72*time.Hour))
	prize := Message("Prize Desk <winner@prizes.example.net>", DemoWork, "You have been selected",
		"Congratulations! Confirm your details within 24 hours.", "", now.Add(-5*time.Hour))
	for _, m := range []struct {
		to, mailbox string
		raw         []byte
		flags       []imap.Flag
	}{
		{DemoPersonal, "INBOX", dinner, nil},
		{DemoWork, "INBOX", notes, []imap.Flag{imap.FlagSeen}},
		{DemoPersonal, "Archive", invoice, []imap.Flag{imap.FlagSeen}},
		{DemoWork, "Junk", prize, nil},
	} {
		if err := lab.Deliver(m.to, m.mailbox, m.raw, m.flags...); err != nil {
			return err
		}
	}
	return nil
}

// ReceiveHandler delivers a fictional message to a demo inbox, so the demo can show arrivals. Query parameters:
// account=work picks the work account, subject sets the subject, and inReplyTo makes it a reply.
func ReceiveHandler(lab *Lab) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		address := DemoPersonal
		if r.URL.Query().Get("account") == "work" {
			address = DemoWork
		}
		subject := r.URL.Query().Get("subject")
		if subject == "" {
			subject = "Coffee this week?"
		}
		raw := Message("Riley Park <riley@example.com>", address, subject,
			"Hi Morgan,\n\nA quick follow-up. Do you have time this week?\n\nRiley", r.URL.Query().Get("inReplyTo"), time.Now())
		if err := lab.Deliver(address, "INBOX", raw); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}
}
