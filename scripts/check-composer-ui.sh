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
  -only-testing:MailernUITests/ComposerSelectionHandleDragKeepsEditingUITests/testComposerSelectionHandleDragKeepsEditing \
  -only-testing:MailernUITests/AttachmentMenuDismissalKeepsEditorUsableUITests/testAttachmentMenuDismissalKeepsEditorUsable \
  -only-testing:MailernUITests/InboxDraftPreviewEditAndDiscardUITests/testInboxDraftPreviewEditAndDiscard \
  -only-testing:MailernUITests/SettledReplyDraftStaysInSettledAndSendsUITests/testSettledReplyDraftStaysInSettledAndSends \
  -only-testing:MailernUITests/ComposerDragDismissesKeyboardAndKeepsContentUITests/testComposerDragDismissesKeyboardAndKeepsContent \
  -only-testing:MailernUITests/ComposerPhotoAttachmentUITests/testComposerPhotoAttachment \
  -only-testing:MailernUITests/ComposerRevertedHeadersPersistAndStayProtectedUITests/testComposerRevertedHeadersPersistAndStayProtected \
  -only-testing:MailernUITests/ComposerCleanupFailureClosesAfterAcknowledgementUITests/testComposerCleanupFailureClosesAfterAcknowledgement \
  -only-testing:MailernUITests/ComposerDraftSaveFailureKeepsEditorUITests/testComposerDraftSaveFailureKeepsEditor \
  -only-testing:MailernUITests/ComposerFileAttachmentUITests/testComposerFileAttachment \
  -only-testing:MailernUITests/ComposerFormattingDraftAndSendUITests/testComposerFormattingDraftAndSend \
  -only-testing:MailernUITests/ComposerReplyAndForwardSendUITests/testComposerReplyAndForwardSend \
  -only-testing:MailernUITests/ComposerSwipeSavesDraftUITests/testComposerSwipeSavesDraft
