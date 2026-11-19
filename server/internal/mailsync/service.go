package mailsync

import (
	"context"
	"errors"
	"fmt"
	"io"
	"path/filepath"
	"slices"
	"strings"

	"github.com/emersion/go-imap/v2"
	"github.com/google/uuid"
)

// The phone embeds this ID in queued sends. Replacing a login must invalidate those sends.
func mailboxAccountID(cfg AccountConfig) string {
	identity := strings.Join([]string{cfg.ID, cfg.Address, cfg.Username, cfg.IMAP.Address()}, "\x00")
	return uuid.NewSHA1(uuid.NameSpaceURL, []byte(identity)).String()
}

// Start opens the state file and starts one sync loop per account, plus the snooze timer. They run until ctx ends.
func Start(ctx context.Context, cfg Config) (*Service, error) {
	cfg.Accounts = slices.Clone(cfg.Accounts)
	for i, account := range cfg.Accounts {
		cfg.Accounts[i].ID = mailboxAccountID(account)
	}
	store, err := OpenStore(filepath.Join(cfg.StateDir, "state.json"))
	if err != nil {
		return nil, err
	}
	if err := store.Update(func(st *State) error {
		st.configureAccounts(cfg.Accounts)
		return nil
	}); err != nil {
		return nil, err
	}
	service := &Service{store: store}
	for _, ac := range cfg.Accounts {
		a := NewAccount(ac, store, cfg.window())
		service.accounts = append(service.accounts, a)
		go a.Run(ctx, cfg.poll())
	}
	go service.WakeSnoozed(ctx)
	return service, nil
}

// Check signs in to each account and writes its mailboxes and message counts to w, without message content,
// so a new config can be tested safely.
func Check(cfg Config, w io.Writer) error {
	failed := false
	for _, ac := range cfg.Accounts {
		fmt.Fprintf(w, "%s (%s)\n", ac.ID, ac.Provider)
		if err := checkAccount(ac, w); err != nil {
			fmt.Fprintf(w, "  error: %v\n", err)
			failed = true
		}
	}
	if failed {
		return errors.New("some accounts failed")
	}
	return nil
}

func checkAccount(ac AccountConfig, w io.Writer) error {
	a := &Account{cfg: ac}
	c, err := a.dial()
	if err != nil {
		return fmt.Errorf("imap: %w", err)
	}
	defer c.Close()
	caps := make([]string, 0)
	for cap := range c.Caps() {
		caps = append(caps, string(cap))
	}
	slices.Sort(caps)
	fmt.Fprintf(w, "  imap capabilities: %s\n", strings.Join(caps, " "))
	mailboxes, archiveIsAll, err := a.discover(c)
	if err != nil {
		return err
	}
	for _, role := range syncedRoles {
		name := mailboxes[role]
		if name == "" {
			fmt.Fprintf(w, "  %-8s (none)\n", role)
			continue
		}
		status, err := c.Status(name, &imap.StatusOptions{NumMessages: true, NumUnseen: true}).Wait()
		if err != nil {
			return fmt.Errorf("status %s: %w", name, err)
		}
		note := ""
		if role == RoleArchive && archiveIsAll {
			note = " (all mail)"
		}
		fmt.Fprintf(w, "  %-8s %q%s: %d messages, %d unread\n", role, name, note, *status.NumMessages, *status.NumUnseen)
	}
	if err := a.checkSMTP(); err != nil {
		return fmt.Errorf("smtp: %w", err)
	}
	fmt.Fprintln(w, "  smtp: signed in")
	return nil
}
