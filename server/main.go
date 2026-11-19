// Command mailern-server syncs mail accounts for the Mailern app and serves them over a Tailscale network.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"slices"
	"strings"
	"syscall"

	"github.com/emersion/go-imap/v2"
	"tailscale.com/tsnet"
)

const usage = `usage:
  mailern-server serve -config FILE [-listen 127.0.0.1:PORT]
  mailern-server check -config FILE
  mailern-server demo [-listen 127.0.0.1:8025]

serve   syncs the configured accounts and joins your tailnet as its own device.
        -listen serves plain HTTP on this machine instead, for development.
check   signs in to each account and prints its mailboxes and message counts.
demo    serves fictional mail from a built-in mail server, for development.`

func main() {
	log.SetFlags(log.Ltime)
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, usage)
		os.Exit(2)
	}
	flags := flag.NewFlagSet(os.Args[1], flag.ExitOnError)
	configPath := flags.String("config", "", "config file")
	listen := flags.String("listen", "", "local address for plain HTTP")
	flags.Parse(os.Args[2:])
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	var err error
	switch os.Args[1] {
	case "serve":
		err = serve(ctx, *configPath, *listen)
	case "check":
		err = check(*configPath)
	case "demo":
		err = demo(ctx, orDefault(*listen, "127.0.0.1:8025"))
	default:
		fmt.Fprintln(os.Stderr, usage)
		os.Exit(2)
	}
	if err != nil {
		log.Fatal(err)
	}
}

func orDefault(value, fallback string) string {
	if value == "" {
		return fallback
	}
	return value
}

func serve(ctx context.Context, configPath, listen string) error {
	if configPath == "" {
		return errors.New("pass -config")
	}
	cfg, err := LoadConfig(configPath)
	if err != nil {
		return err
	}
	if listen != "" {
		return serveLocal(ctx, cfg, listen)
	}
	if len(cfg.Tailscale.AllowedUsers) == 0 {
		return errors.New("set tailscale.allowedUsers to the Tailscale login names that may use this service")
	}
	ts := &tsnet.Server{Hostname: cfg.Tailscale.Hostname, Dir: filepath.Join(cfg.StateDir, "tailscale"), UserLogf: log.Printf}
	defer ts.Close()
	if _, err := ts.Up(ctx); err != nil {
		return err
	}
	who, err := ts.LocalClient()
	if err != nil {
		return err
	}
	ln, err := ts.ListenTLS("tcp", ":443")
	if err != nil {
		return err
	}
	defer ln.Close()
	service, err := start(ctx, cfg)
	if err != nil {
		return err
	}
	service.authorize = func(r *http.Request) error {
		peer, err := who.WhoIs(r.Context(), r.RemoteAddr)
		if err != nil {
			return err
		}
		if peer.UserProfile == nil || !slices.Contains(cfg.Tailscale.AllowedUsers, peer.UserProfile.LoginName) {
			return errors.New("this Tailscale user may not use this service")
		}
		return nil
	}
	if domains := ts.CertDomains(); len(domains) > 0 {
		log.Printf("serving https://%s", domains[0])
	}
	return serveHTTP(ctx, service, ln)
}

// start opens the state file and starts one sync loop per account, plus the snooze timer.
func start(ctx context.Context, cfg Config) (*Service, error) {
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

func serveLocal(ctx context.Context, cfg Config, listen string) error {
	host, _, err := net.SplitHostPort(listen)
	if err != nil {
		return err
	}
	if ip := net.ParseIP(host); host != "localhost" && (ip == nil || !ip.IsLoopback()) {
		return errors.New("-listen serves without encryption or sign-in, so it accepts only a loopback address")
	}
	ln, err := net.Listen("tcp", listen)
	if err != nil {
		return err
	}
	defer ln.Close()
	service, err := start(ctx, cfg)
	if err != nil {
		return err
	}
	log.Printf("serving http://%s", listen)
	return serveHTTP(ctx, service, ln)
}

func serveHTTP(ctx context.Context, service *Service, ln net.Listener) error {
	server := &http.Server{Handler: service.Handler()}
	go func() {
		<-ctx.Done()
		server.Close()
	}()
	if err := server.Serve(ln); !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}

// check prints what the service would sync, without message content, so a new config can be tested safely.
func check(configPath string) error {
	if configPath == "" {
		return errors.New("pass -config")
	}
	cfg, err := LoadConfig(configPath)
	if err != nil {
		return err
	}
	failed := false
	for _, ac := range cfg.Accounts {
		fmt.Printf("%s (%s)\n", ac.ID, ac.Provider)
		if err := checkAccount(ac); err != nil {
			fmt.Printf("  error: %v\n", err)
			failed = true
		}
	}
	if failed {
		return errors.New("some accounts failed")
	}
	return nil
}

func checkAccount(ac AccountConfig) error {
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
	fmt.Printf("  imap capabilities: %s\n", strings.Join(caps, " "))
	mailboxes, archiveIsAll, err := a.discover(c)
	if err != nil {
		return err
	}
	for _, role := range syncedRoles {
		name := mailboxes[role]
		if name == "" {
			fmt.Printf("  %-8s (none)\n", role)
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
		fmt.Printf("  %-8s %q%s: %d messages, %d unread\n", role, name, note, *status.NumMessages, *status.NumUnseen)
	}
	if err := a.checkSMTP(); err != nil {
		return fmt.Errorf("smtp: %w", err)
	}
	fmt.Println("  smtp: signed in")
	return nil
}

func demo(ctx context.Context, listen string) error {
	lab, err := StartMailLab(demoPersonal, demoWork)
	if err != nil {
		return err
	}
	defer lab.Close()
	if err := seedDemo(lab); err != nil {
		return err
	}
	dir, err := os.MkdirTemp("", "mailern-demo-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(dir)
	cfg := Config{StateDir: dir, PollSeconds: 5, WindowDays: 90, Accounts: []AccountConfig{
		lab.Account("personal", "Personal", demoPersonal),
		lab.Account("work", "Work", demoWork),
	}}
	service, err := start(ctx, cfg)
	if err != nil {
		return err
	}
	handler := service.Handler()
	mux := http.NewServeMux()
	mux.Handle("/", handler)
	mux.Handle("POST /demo/receive", demoReceive(lab))
	host, _, _ := net.SplitHostPort(listen)
	if ip := net.ParseIP(host); host != "localhost" && (ip == nil || !ip.IsLoopback()) {
		return errors.New("demo accepts only a loopback address")
	}
	ln, err := net.Listen("tcp", listen)
	if err != nil {
		return err
	}
	log.Printf("serving fictional mail on http://%s", listen)
	server := &http.Server{Handler: mux}
	go func() {
		<-ctx.Done()
		server.Close()
	}()
	if err := server.Serve(ln); !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}
