package main

import (
	"bufio"
	"fmt"
	"net"
	"net/textproto"
	"strings"
	"testing"
	"time"
)

func TestSubmissionEndsAtSMTPAcceptance(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		conn.SetDeadline(time.Now().Add(5 * time.Second))
		reader := textproto.NewReader(bufio.NewReader(conn))
		fmt.Fprint(conn, "220 localhost ESMTP\r\n")
		for {
			line, err := reader.ReadLine()
			if err != nil {
				return
			}
			if strings.EqualFold(line, "DATA") {
				fmt.Fprint(conn, "354 Send message\r\n")
				if _, err := reader.ReadDotBytes(); err == nil {
					fmt.Fprint(conn, "250 Accepted\r\n")
				}
				return
			}
			fmt.Fprint(conn, "250 OK\r\n")
		}
	}()
	endpoint := endpointFor(listener)
	account := Account{cfg: AccountConfig{Address: labAddress, SMTP: &endpoint}}
	if err := account.submit(SendRequest{To: []string{"sam@example.com"}}, []byte("Subject: Hello\r\n\r\nHi")); err != nil {
		t.Fatalf("accepted delivery reported as failed: %v", err)
	}
}
