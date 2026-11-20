# mailern-server

One program that syncs your mail accounts for Mailern and serves them on your Tailscale network. It joins the tailnet as its own device, so you need no port forwarding, no public server, and no Tailscale setup on the host beyond signing the device in once.

It speaks IMAP and SMTP, so it works with Gmail and iCloud Mail through app passwords, and with Proton Mail through Proton Mail Bridge on the same computer. Requires Go 1.27 or later.

## How your mail maps to Mailern

| Mailern | On the mail server |
| --- | --- |
| Inbox | the message is in the inbox |
| Settle | archived: moved to Archive, or out of the inbox on Gmail |
| Snooze | nothing changes; snoozed mail stays in the inbox until the service returns it in Mailern |
| Pin | flagged (a star in Gmail) |
| Read and unread | the read flag on each message |
| Trash and Junk | the whole thread moves to Trash or Junk |
| Delete permanently | expunges the confirmed copies in Trash or Junk |

Changes you make in other mail apps come back to Mailern: archiving a thread in Gmail on the web settles it, and moving it back to the inbox returns it. A new reply returns a settled or snoozed thread to Inbox, unless the thread is muted. Snoozes, mutes, and reminders exist only in Mailern.

The service keeps your inbox and the last 90 days of archived, sent, junk, and deleted mail. It loads HTML only when you open a message.

Before permanent deletion, Mailern checks the thread members and their mailbox. IMAP handles these checks and deletion as separate commands. A reply that arrives after the last check can survive while the confirmed messages are deleted.

## Set up

1. Create an app password for each account:
   - Gmail: turn on 2-Step Verification, then create one at [App passwords](https://myaccount.google.com/apppasswords). Some work, school, and Advanced Protection accounts cannot create them.
   - iCloud: create one at [account.apple.com](https://account.apple.com) under Sign-In and Security, App-Specific Passwords. iCloud signs in only with your `@icloud.com`, `@me.com`, or `@mac.com` address. If you send from a custom domain, set `address` to that domain's address and `username` to your iCloud Mail address.
   - Proton: run Proton Mail Bridge on the same computer and copy the username and password it shows for your account. Bridge requires a paid plan. Match the IMAP and SMTP ports and connection security in Bridge’s Mailbox details. If SMTP uses SSL/TLS, set the account’s `smtp` endpoint to the displayed host and port with `"security": "tls"`.
2. Save each password in its own file, readable only by you (`chmod 600`).
3. Copy `config.example.json` to `config.json` and fill in your addresses, password files, and your Tailscale login name in `allowedUsers`. Relative paths are relative to the config file.
4. Check the config: `go run ./cmd/mailern-server check -config config.json`. It signs in to each account and prints its mailboxes and message counts, without message content.
5. Start the service: `go run ./cmd/mailern-server serve -config config.json`. The first start prints a link to add the device to your tailnet; after that it prints the address to use, such as `https://mailern.example.ts.net`. Your tailnet needs MagicDNS and HTTPS certificates turned on.
6. In Mailern, open More → Settings → Mail Server and enter that address.

Only the Tailscale users in `allowedUsers` can use the service. Keep the service running for snoozes to return on time and for sync to continue while the app is closed.

## Config

| Key | Meaning |
| --- | --- |
| `stateDir` | Where the service keeps its state and its Tailscale device. Defaults to `mailern-server` in your user config directory. A relative path is relative to the config file. |
| `pollSeconds` | How often each account checks for changes. Defaults to 60. Changes from Mailern sync at once. |
| `windowDays` | How many days back the service looks for archived and sent mail it has not seen yet. Mail it already tracks stays. Defaults to 90. |
| `accounts[].provider` | `gmail`, `icloud`, `proton-bridge`, or `imap` with `imap` and `smtp` endpoints (`host`, `port`, `security`: `tls` or `starttls`). |
| `accounts[].aliases` | Other addresses of the account, such as Proton addresses on your own domain. Mail from them counts as yours, and Mailern can send from them. Bridge delivers mail for all of them to the same inbox. |
| `accounts[].username` | Defaults to the address. iCloud needs its own iCloud Mail address here when `address` is a custom domain. |
| `accounts[].passwordFile`, `passwordEnv` | Where to read the app password. |
| `accounts[].appendSent` | Saves a copy of sent mail in Sent. On by default for iCloud, which does not save mail sent over SMTP. |
| `accounts[].mailboxes` | Mailbox names for `archive`, `sent`, `junk`, and `trash`, for servers that do not mark them. |

## Development

`go run ./cmd/mailern-server demo` serves fictional mail from a built-in mail server on `http://127.0.0.1:8025`, with no accounts or Tailscale. In the iOS Simulator, enter that address in Mailern. `POST /demo/receive` delivers a fictional message; pass `inReplyTo` with a Message-ID to reply to a thread.

`go test ./...` runs the sync, workflow, send, and API tests against the same fictional mail server.

`serve -listen 127.0.0.1:PORT` serves real accounts over plain HTTP on this computer only, without Tailscale or sign-in.
