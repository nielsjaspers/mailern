package mailsync

import (
	"path/filepath"
	"testing"
)

func TestConfigRefusesAnAddressListedTwice(t *testing.T) {
	t.Setenv("MAILERN_TEST_PASSWORD", "secret")
	for name, accounts := range map[string][]AccountConfig{
		"two accounts": {
			{ID: "a", Address: "me@example.com", Provider: "gmail", PasswordEnv: "MAILERN_TEST_PASSWORD"},
			{ID: "b", Address: "other@example.com", Aliases: []string{"Me@example.com"}, Provider: "icloud", PasswordEnv: "MAILERN_TEST_PASSWORD"},
		},
		"one account": {
			{ID: "a", Address: "me@example.com", Aliases: []string{"me@example.com"}, Provider: "gmail", PasswordEnv: "MAILERN_TEST_PASSWORD"},
		},
	} {
		cfg := Config{StateDir: t.TempDir(), Accounts: accounts}
		if err := cfg.resolve(t.TempDir()); err == nil {
			t.Errorf("%s: an address listed twice must be refused", name)
		}
	}
}

func TestConfigResolvesARelativeStateDirFromTheConfigFile(t *testing.T) {
	t.Setenv("MAILERN_TEST_PASSWORD", "secret")
	base := t.TempDir()
	cfg := Config{StateDir: "state", Accounts: []AccountConfig{
		{ID: "a", Address: "me@example.com", Provider: "gmail", PasswordEnv: "MAILERN_TEST_PASSWORD"},
	}}
	if err := cfg.resolve(base); err != nil {
		t.Fatal(err)
	}
	if want := filepath.Join(base, "state"); cfg.StateDir != want {
		t.Errorf("stateDir = %q, want %q", cfg.StateDir, want)
	}
}
