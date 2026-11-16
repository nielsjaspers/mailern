#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
simulator_id=${1:?Usage: scripts/check-composer-ui.sh SIMULATOR_ID}
derived_data=build/composer-ui
xcodebuild -project Mailern.xcodeproj -scheme Mailern -destination "id=$simulator_id" -derivedDataPath "$derived_data" build-for-testing
xcrun simctl install "$simulator_id" "$derived_data/Build/Products/Debug-iphonesimulator/Mailern.app"
app_data=$(xcrun simctl get_app_container "$simulator_id" com.example.mailern data)
mkdir -p "$app_data/Documents"
cp 'Tests/Fixtures/Sample attachment.txt' "$app_data/Documents/Sample attachment.txt"
xcrun simctl addmedia "$simulator_id" 'Tests/Fixtures/Sample photo.png'
xcodebuild -project Mailern.xcodeproj -scheme Mailern -destination "id=$simulator_id" -derivedDataPath "$derived_data" test-without-building -parallel-testing-enabled NO \
  -only-testing:MailernTests \
  -only-testing:MailernUITests/ComposerInteractionUITests/testComposerSelectionHandleDragKeepsEditing \
  -only-testing:MailernUITests/ComposerInteractionUITests/testAttachmentMenuDismissalKeepsEditorUsable \
  -only-testing:MailernUITests/DraftReaderUITests/testInboxDraftPreviewEditAndDiscard \
  -only-testing:MailernUITests/DraftReaderUITests/testSettledReplyDraftStaysInSettledAndSends \
  -only-testing:MailernUITests/ComposerInteractionUITests/testComposerDragDismissesKeyboardAndKeepsContent \
  -only-testing:MailernUITests/ComposerUITests/testComposerPhotoAttachment \
  -only-testing:MailernUITests/ComposerUITests/testComposerRevertedHeadersPersistAndStayProtected \
  -only-testing:MailernUITests/ComposerUITests/testComposerCleanupFailureClosesAfterAcknowledgement \
  -only-testing:MailernUITests/ComposerUITests/testComposerDraftSaveFailureKeepsEditor \
  -only-testing:MailernUITests/ComposerUITests/testComposerFileAttachment \
  -only-testing:MailernUITests/ComposerUITests/testComposerFormattingDraftAndSend \
  -only-testing:MailernUITests/ComposerUITests/testComposerReplyAndForwardSend \
  -only-testing:MailernUITests/ComposerUITests/testComposerSwipeSavesDraft
