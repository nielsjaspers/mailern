package mailsync

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type Endpoint struct {
	Host string `json:"host"`
	Port int    `json:"port"`
	// "tls" connects with TLS. "starttls" upgrades a plain connection.
	Security string `json:"security"`
}

func (e Endpoint) Address() string { return net.JoinHostPort(e.Host, fmt.Sprint(e.Port)) }

// Loopback reports whether the endpoint stays on this machine. Proton Mail Bridge listens there with a
// self-signed certificate, and traffic that never leaves the machine needs no certificate check.
func (e Endpoint) Loopback() bool {
	ip := net.ParseIP(e.Host)
	return e.Host == "localhost" || (ip != nil && ip.IsLoopback())
}

type AccountConfig struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	Address string `json:"address"`
	// The name recipients see on mail from this account.
	SenderName string `json:"senderName,omitempty"`
	// Other addresses this account receives and sends as, such as Proton addresses on a custom domain.
	Aliases []string `json:"aliases,omitempty"`
	// "gmail", "icloud", "proton-bridge", or "imap" with explicit endpoints.
	Provider string `json:"provider"`
	// Defaults to Address.
	Username string `json:"username,omitempty"`
	// A file that holds the app password, or the environment variable that does.
	PasswordFile string    `json:"passwordFile,omitempty"`
	PasswordEnv  string    `json:"passwordEnv,omitempty"`
	IMAP         *Endpoint `json:"imap,omitempty"`
	SMTP         *Endpoint `json:"smtp,omitempty"`
	// Saves a copy of sent mail in Sent. iCloud does not file mail sent over SMTP; Gmail and Proton do.
	AppendSent *bool `json:"appendSent,omitempty"`
	// Overrides for servers that do not mark their mailboxes with special-use attributes.
	Mailboxes map[Role]string `json:"mailboxes,omitempty"`

	// Password is read from PasswordFile or PasswordEnv. It is never written to JSON.
	Password string `json:"-"`
}

type Config struct {
	// Holds the service state and the Tailscale node state. Defaults to the user's config directory.
	StateDir  string `json:"stateDir,omitempty"`
	Tailscale struct {
		Hostname string `json:"hostname"`
		// Tailscale login names allowed to use the service, such as "you@github".
		AllowedUsers []string `json:"allowedUsers"`
	} `json:"tailscale"`
	// How often each account checks its server for changes.
	PollSeconds int `json:"pollSeconds,omitempty"`
	// How far back the service keeps archived and sent mail. Inbox mail is always kept.
	WindowDays int             `json:"windowDays,omitempty"`
	Accounts   []AccountConfig `json:"accounts"`
}

func (c Config) poll() time.Duration   { return time.Duration(c.PollSeconds) * time.Second }
func (c Config) window() time.Duration { return time.Duration(c.WindowDays) * 24 * time.Hour }

var presets = map[string]struct {
	imap, smtp Endpoint
	appendSent bool
}{
	"gmail":         {Endpoint{"imap.gmail.com", 993, "tls"}, Endpoint{"smtp.gmail.com", 465, "tls"}, false},
	"icloud":        {Endpoint{"imap.mail.me.com", 993, "tls"}, Endpoint{"smtp.mail.me.com", 587, "starttls"}, true},
	"proton-bridge": {Endpoint{"127.0.0.1", 1143, "starttls"}, Endpoint{"127.0.0.1", 1025, "starttls"}, false},
}

func LoadConfig(path string) (Config, error) {
	var c Config
	data, err := os.ReadFile(path)
	if err != nil {
		return c, err
	}
	if err := json.Unmarshal(data, &c); err != nil {
		return c, fmt.Errorf("%s: %w", path, err)
	}
	return c, c.resolve(filepath.Dir(path))
}

// resolve fills in defaults and reads passwords. Relative password files are relative to the config file.
func (c *Config) resolve(base string) error {
	if c.StateDir == "" {
		dir, err := os.UserConfigDir()
		if err != nil {
			return err
		}
		c.StateDir = filepath.Join(dir, "mailern-server")
	}
	if c.Tailscale.Hostname == "" {
		c.Tailscale.Hostname = "mailern"
	}
	if c.PollSeconds <= 0 {
		c.PollSeconds = 60
	}
	if c.WindowDays <= 0 {
		c.WindowDays = 90
	}
	if len(c.Accounts) == 0 {
		return errors.New("add at least one account")
	}
	seen := map[string]bool{}
	addresses := map[string]string{}
	for i := range c.Accounts {
		a := &c.Accounts[i]
		if a.ID == "" || seen[a.ID] {
			return fmt.Errorf("account %d needs a unique id", i+1)
		}
		seen[a.ID] = true
		if !strings.Contains(a.Address, "@") {
			return fmt.Errorf("account %q needs an email address", a.ID)
		}
		for _, alias := range a.Aliases {
			if !strings.Contains(alias, "@") {
				return fmt.Errorf("account %q: alias %q must be an email address", a.ID, alias)
			}
		}
		// Mail from an address counts as the user's own in its account, so each address belongs to one account once.
		for _, address := range append([]string{a.Address}, a.Aliases...) {
			if owner, taken := addresses[strings.ToLower(address)]; taken {
				return fmt.Errorf("address %s is listed twice, in accounts %q and %q", address, owner, a.ID)
			}
			addresses[strings.ToLower(address)] = a.ID
		}
		if a.Name == "" {
			a.Name = a.ID
		}
		if a.Username == "" {
			a.Username = a.Address
		}
		if p, ok := presets[a.Provider]; ok {
			if a.IMAP == nil {
				a.IMAP = &p.imap
			}
			if a.SMTP == nil {
				a.SMTP = &p.smtp
			}
			if a.AppendSent == nil {
				a.AppendSent = &p.appendSent
			}
		} else if a.Provider != "imap" {
			return fmt.Errorf("account %q: unknown provider %q", a.ID, a.Provider)
		}
		if a.IMAP == nil || a.SMTP == nil {
			return fmt.Errorf("account %q needs imap and smtp endpoints", a.ID)
		}
		if a.AppendSent == nil {
			a.AppendSent = new(bool)
		}
		switch {
		case a.PasswordFile != "":
			path := a.PasswordFile
			if !filepath.IsAbs(path) {
				path = filepath.Join(base, path)
			}
			data, err := os.ReadFile(path)
			if err != nil {
				return fmt.Errorf("account %q: %w", a.ID, err)
			}
			a.Password = strings.TrimSpace(string(data))
		case a.PasswordEnv != "":
			a.Password = os.Getenv(a.PasswordEnv)
		}
		if a.Password == "" {
			return fmt.Errorf("account %q needs a password through passwordFile or passwordEnv", a.ID)
		}
	}
	return nil
}

// ownAddress returns the account's spelling of address when the account sends as it.
func (a AccountConfig) ownAddress(address string) (string, bool) {
	for _, own := range append([]string{a.Address}, a.Aliases...) {
		if strings.EqualFold(own, address) {
			return own, true
		}
	}
	return "", false
}
