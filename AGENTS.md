# Simulator tests

Run `scripts/check-ui.sh <disposable-simulator-id> [--only-testing <Target/Class/test>]`. Never use a simulator the user works in; create a disposable one with `xcrun simctl create` if none exists. The runner uses only that simulator. Prefer focused runs while iterating; the full suite takes about five minutes. The composer suite has a `scripts/check-composer-ui.sh` shortcut.

Script runs turn off UIKit animations. After changing a transition, also run the affected tests with `MAILERN_TEST_ANIMATIONS=on`.

Runs shut down their simulator. Pass `--keep-booted` only when the user asks for it. After a killed run, use `--stop` to shut the simulator down.
