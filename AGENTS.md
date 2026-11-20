# Docs

`docs/behavior.md` describes how the app behaves. Update it in the same change when behavior changes. Test details are in `docs/development.md`, and the build registry is in `docs/releasing.md`.

# Simulator tests

Run `scripts/check-ui.sh <disposable-simulator-id> [--only-testing <Target/Class/test>]`. Never use a simulator the user works in; create a disposable one with `xcrun simctl create` if none exists. The runner uses only that simulator. Prefer focused runs while iterating. The composer suite has a `scripts/check-composer-ui.sh` shortcut.

Run the full suite once after the first implementation of a feature and once on the final rebased head. Between review rounds, run only the focused tests for the changed code.

Script runs turn off UIKit animations. After changing a transition or animation, also run the affected tests with `MAILERN_TEST_ANIMATIONS=on`. Passing tests and still screenshots do not show transition bugs, so record the simulator (`xcrun simctl io <id> recordVideo`) while a test drives the interaction and check the frames for ghosted text, overlap, and layout jumps.

Runs shut down their simulator. Pass `--keep-booted` only when the user asks for it. After a killed run, use `--stop` to shut the simulator down.

The runner keeps the 10 newest result bundles and logs in `build/` and removes older ones.

# Build links

Publish with `scripts/serve-demo.py` into its default `build/install`. Each publish replaces the previous build there, so serve that one folder from one server and one Tailscale route. Don't create numbered install folders.
