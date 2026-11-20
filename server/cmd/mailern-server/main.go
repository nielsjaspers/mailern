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
	"strconv"
	"syscall"

	"github.com/nielsjaspers/mailern/server/internal/maillab"
	"github.com/nielsjaspers/mailern/server/internal/mailsync"
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
		if *listen == "" {
			*listen = "127.0.0.1:8025"
		}
		err = demo(ctx, *listen)
	default:
		fmt.Fprintln(os.Stderr, usage)
		os.Exit(2)
	}
	if err != nil {
		log.Fatal(err)
	}
}

func loadConfig(path string) (mailsync.Config, error) {
	if path == "" {
		return mailsync.Config{}, errors.New("pass -config")
	}
	return mailsync.LoadConfig(path)
}

func serve(ctx context.Context, configPath, listen string) error {
	cfg, err := loadConfig(configPath)
	if err != nil {
		return err
	}
	if listen != "" {
		ln, err := listenLoopback(listen)
		if err != nil {
			return err
		}
		defer ln.Close()
		service, err := mailsync.Start(ctx, cfg)
		if err != nil {
			return err
		}
		log.Printf("serving http://%s", listen)
		return serveHTTP(ctx, service.Handler(), ln)
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
	service, err := mailsync.Start(ctx, cfg)
	if err != nil {
		return err
	}
	service.Authorize = func(r *http.Request) error {
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
	return serveHTTP(ctx, service.Handler(), ln)
}

// listenLoopback refuses other addresses: plain HTTP has no encryption or sign-in.
func listenLoopback(addr string) (net.Listener, error) {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return nil, err
	}
	if ip := net.ParseIP(host); host != "localhost" && (ip == nil || !ip.IsLoopback()) {
		return nil, errors.New("-listen serves without encryption or sign-in, so it accepts only a loopback address")
	}
	return net.Listen("tcp", addr)
}

func serveHTTP(ctx context.Context, handler http.Handler, ln net.Listener) error {
	server := &http.Server{Handler: handler}
	go func() {
		<-ctx.Done()
		server.Close()
	}()
	if err := server.Serve(ln); !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}

func check(configPath string) error {
	cfg, err := loadConfig(configPath)
	if err != nil {
		return err
	}
	return mailsync.Check(cfg, os.Stdout)
}

// demo serves the fictional lab accounts. Mail sent between them arrives, and POST /demo/receive delivers more.
func demo(ctx context.Context, listen string) error {
	ln, err := listenLoopback(listen)
	if err != nil {
		return err
	}
	defer ln.Close()
	lab, err := maillab.Start(maillab.DemoPersonal, maillab.DemoWork)
	if err != nil {
		return err
	}
	defer lab.Close()
	if err := maillab.SeedDemo(lab); err != nil {
		return err
	}
	dir, err := os.MkdirTemp("", "mailern-demo-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(dir)
	cfg := mailsync.Config{StateDir: dir, PollSeconds: 5, WindowDays: 90, Accounts: []mailsync.AccountConfig{
		labAccount(lab, "personal", "Personal", maillab.DemoPersonal),
		labAccount(lab, "work", "Work", maillab.DemoWork),
	}}
	service, err := mailsync.Start(ctx, cfg)
	if err != nil {
		return err
	}
	mux := http.NewServeMux()
	mux.Handle("/", service.Handler())
	mux.Handle("POST /demo/receive", maillab.ReceiveHandler(lab))
	log.Printf("serving fictional mail on http://%s", listen)
	return serveHTTP(ctx, mux, ln)
}

func labAccount(lab *maillab.Lab, id, name, address string) mailsync.AccountConfig {
	appendSent := true
	return mailsync.AccountConfig{ID: id, Name: name, Address: address, Provider: "imap", Username: address,
		SenderName: "Morgan", IMAP: endpoint(lab.IMAPAddr), SMTP: endpoint(lab.SMTPAddr), AppendSent: &appendSent,
		Password: maillab.Password}
}

func endpoint(addr string) *mailsync.Endpoint {
	host, port, _ := net.SplitHostPort(addr)
	n, _ := strconv.Atoi(port)
	return &mailsync.Endpoint{Host: host, Port: n, Security: "none"}
}
