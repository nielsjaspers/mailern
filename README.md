# Mailern

A native SwiftUI mail app for iPhone, built around reading, snoozing, and settling conversations. It ships with fictional demo mail, and can show your own Gmail, iCloud, and Proton Mail through [mailern-server](server/README.md) on your Tailscale network.

Requires iOS 18 or later and Xcode 26 or later.

## Run it

Open `Mailern.xcodeproj`, choose your development team under Signing & Capabilities, and run the Mailern scheme. The demo needs no packages or credentials.

```sh
scripts/check-workflow.sh                  # store and persistence checks, runs in seconds
scripts/check-ui.sh DISPOSABLE_SIMULATOR_ID # full UI suite on one disposable simulator
python3 scripts/create-project.py          # regenerate the Xcode project after adding files
```

```sh
cd server
go test ./...
go run ./cmd/mailern-server demo           # fictional mail on http://127.0.0.1:8025
```

To read your own mail, set up the server with [server/README.md](server/README.md), then enter its address under More → Settings → Mail Server.

## More

- [How Mailern behaves](docs/behavior.md)
- [Development and tests](docs/development.md)
- [Releasing development builds](docs/releasing.md)
