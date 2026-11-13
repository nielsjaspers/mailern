# Mailern

A native SwiftUI email workflow prototype for iPhone and iPad, with fictional mail across four accounts. Requires iOS 17 or later and Xcode 15 or later.

Open `Mailern.xcodeproj`, select the Mailern scheme and your device, then choose your development team under Signing & Capabilities and run. No packages or provider credentials are needed.

## Try the workflow

- Opening a conversation marks it read and keeps it in its current section.
- Swipe left for Settle or Snooze. In Settled, swipe left to restore.
- Swipe right for Pin and Read/Unread. Long press for more actions.
- Use the thread's Reply menu for Reply, Reply All, and Forward. Sending a reply adds a message and settles that conversation. New messages and forwards appear in Settled.
- Use Demo at the top left to receive new mail, receive a reply to any conversation, or reset all demo data.
- Snooze for 10 seconds to try automatic return. Expired snoozes return while the app is active, or when it next opens. The prototype does not run a background mail service or send notifications.
- Incoming replies immediately return a conversation to Inbox as unread, including from Snoozed and Settled. Pins and read status remain independent of workflow status.
- Undo reverses the most recent workflow move. Incoming mail and sending invalidate Undo so it cannot hide a newer message.
- Search covers the current section's subjects, senders, accounts, and message bodies.

Messages and workflow state are saved as atomic JSON in the app's Application Support directory. Cancel protects edited messages from accidental dismissal; drafts are not persisted. The message view renders local text and Markdown links, not arbitrary HTML email or attachments.

## Code

`Mailern/Core` contains conversation models, demo messages, and the observable store. `ConversationPersistence` separates storage from state changes. `Mailern/Views` contains the native SwiftUI screens. Workflow status does not map to a provider folder or label. No provider integrations or backend are included.

Run `scripts/check-workflow.sh` for isolated state and persistence checks. It creates a unique temporary data file, separate from the app's demo data.

The checked-in Xcode project works directly. After adding source files, regenerate it with `python3 scripts/create-project.py`. The icon can be regenerated with `swift scripts/create-icon.swift`.

## Remote development installation

`scripts/package-demo.sh TEAM_ID` archives and exports a development-signed IPA using an existing Xcode signing account/profile. The iPhone must be registered in that profile and have Developer Mode enabled. A development-signed app expires with its provisioning profile.

`scripts/serve-demo.py HTTPS_BASE_URL` creates an OTA manifest and install page in `build/install`. Serve only that directory over trusted HTTPS, such as a dedicated Tailscale Serve path. Open its page in Safari on the registered iPhone with Tailscale connected. The computer serving the files must remain awake and connected.
