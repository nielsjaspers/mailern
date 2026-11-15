# Mailern

A native SwiftUI email workflow prototype for iPhone and iPad, with fictional mail across four accounts. Requires iOS 17 or later and Xcode 26 or later.

Open `Mailern.xcodeproj`, select the Mailern scheme and your device, then choose your development team under Signing & Capabilities and run. No packages or provider credentials are needed.

## Try the workflow

- Inbox’s Filter button toggles between All and Unread first. Read conversations stay visible in Unread first; pinned conversations remain first, followed by unread then read, newest first within each group. Other sections keep their existing order.
- Opening a conversation marks it read and keeps it in its current section.
- Swipe left for Settle or Snooze. In Settled, swipe left to restore.
- Swipe right for Read/Unread and Pin. A full right swipe toggles read status.
- Hold a conversation for a compact, scrollable preview with the tools visible. Drag the tools downward to enlarge the card; drag upward to shrink it and reveal the menu again. Tap a reply shortcut or menu action. Reading the preview preserves read status; tapping it opens the conversation.
- Use the thread's Reply menu for Reply, Reply All, and Forward. Sending a reply adds a message and settles that conversation. New messages and forwards appear in Settled.
- Use More → Demo at the top left to receive new mail, receive a reply to any conversation, or reset all demo data.
- Snooze for one or three hours, this evening, tomorrow, next week, or a custom date. Options are sorted by return time; past evening times are hidden. Next week defaults to Monday at 09:00. Use Snooze settings in More or the snooze picker to change the presets. Settings persist across launches and only affect future snoozes. Expired snoozes return while the app is active, or when it next opens. The prototype does not run a background mail service or send notifications.
- Incoming replies immediately return a conversation to Inbox as unread, including from Snoozed and Settled. Pins and read status remain independent of workflow status.
- Undo reverses the most recent workflow move. Incoming mail and sending invalidate Undo so it cannot hide a newer message.
- Search covers the current section's subjects, senders, accounts, and message bodies.

Messages and workflow state are saved as atomic JSON in the app's Application Support directory. Cancel protects edited messages from accidental dismissal; drafts are not persisted. The message view renders local text and Markdown links, not arbitrary HTML email or attachments.

## Code

`Mailern/Core` contains conversation models, demo messages, and the observable store. `ConversationPersistence` separates storage from state changes. `Mailern/Views` contains the native SwiftUI screens. Workflow status does not map to a provider folder or label. No provider integrations or backend are included.

Run `scripts/check-workflow.sh` for isolated state and persistence checks. It creates a unique temporary data file, separate from the app's demo data.

Prototype refinements use patch versions. Increment the build number for each distributed build; reserve minor versions for larger milestones.

Run Product → Test in Xcode on a Simulator to check peek presentation across workflow sections. The UI test resets that Simulator’s demo messages.

The checked-in Xcode project works directly. After adding source files, regenerate it with `python3 scripts/create-project.py`. Edit `Mailern/AppIcon.icon` in Icon Composer. Its three vector groups separate the rounded upper wing, rear wing, and body, with the upper wing in front. Xcode compiles the layered icon and its appearance variants directly from this file. Building the icon requires Xcode 26 or later.

## Remote development installation

`scripts/package-demo.sh TEAM_ID` archives and exports a development-signed IPA using an existing Xcode signing account/profile. The iPhone must be registered in that profile and have Developer Mode enabled. A development-signed app expires with its provisioning profile.

`scripts/serve-demo.py HTTPS_BASE_URL` creates an OTA manifest and install page in `build/install`. Serve only that directory over trusted HTTPS, such as a dedicated Tailscale Serve path. Open its page in Safari on the registered iPhone with Tailscale connected. The computer serving the files must remain awake and connected.

Settings in the More menu includes snooze preferences and Labs. Labs can assign the Inbox pull-down gesture to Search or New email, and move Compose to the bottom while preserving native tabs. iOS 27 uses the system's prominent trailing tab; earlier versions use a native bottom toolbar. Both experiments are off by default and persist locally. Pull actions require iOS 18 or later. Start a pull while the Inbox is stationary at the very top. Pull farther to fill the ring; a soft tap and brief pulse indicate readiness. Move back up to cancel or pull down again to rearm before releasing. Search and Compose open on release without an opening animation.

Labs → Swipe actions configures the full-swipe action and an optional additional button separately for left and right swipes. Choose Settle / Restore, Read / Unread, Snooze, Pin / Unpin, or None. The same configuration applies in all mailboxes, persists locally, and can be reset to the defaults.

Use Select at the top of any mailbox for bulk actions. Select All selects the current search results. The bottom toolbar offers Settle or Restore, Snooze, and a Mark menu for read/unread and pin/unpin actions. In Snoozed, Mark also offers Restore to Inbox. Selection never marks mail read. Cancel exits selection; cancelling the snooze picker keeps the selection. Undo reverses the entire batch.
