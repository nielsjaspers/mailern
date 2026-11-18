#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
simulator_id=${1:?Usage: scripts/check-composer-ui.sh DISPOSABLE_SIMULATOR_ID}
shift
exec scripts/check-ui.sh "$simulator_id" "$@" \
  --only-testing MailernTests \
  --only-testing MailernUITests/RecipientSearchUITests/testSearchRecipientsAndPreserveSelection \
  --only-testing MailernUITests/ComposerSelectionHandleDragKeepsEditingUITests/testComposerSelectionHandleDragKeepsEditing \
  --only-testing MailernUITests/AttachmentMenuDismissalKeepsEditorUsableUITests/testAttachmentMenuDismissalKeepsEditorUsable \
  --only-testing MailernUITests/InboxDraftPreviewEditAndDiscardUITests/testInboxDraftPreviewEditAndDiscard \
  --only-testing MailernUITests/SettledReplyDraftStaysInSettledAndSendsUITests/testSettledReplyDraftStaysInSettledAndSends \
  --only-testing MailernUITests/ComposerDragDismissesKeyboardAndKeepsContentUITests/testComposerDragDismissesKeyboardAndKeepsContent \
  --only-testing MailernUITests/ComposerPhotoAttachmentUITests/testComposerPhotoAttachment \
  --only-testing MailernUITests/ComposerRevertedHeadersPersistAndStayProtectedUITests/testComposerRevertedHeadersPersistAndStayProtected \
  --only-testing MailernUITests/ComposerCleanupFailureClosesAfterAcknowledgementUITests/testComposerCleanupFailureClosesAfterAcknowledgement \
  --only-testing MailernUITests/ComposerDraftSaveFailureKeepsEditorUITests/testComposerDraftSaveFailureKeepsEditor \
  --only-testing MailernUITests/ComposerFileAttachmentUITests/testComposerFileAttachment \
  --only-testing MailernUITests/ComposerFormattingDraftAndSendUITests/testComposerFormattingDraftAndSend \
  --only-testing MailernUITests/ComposerReplyAndForwardSendUITests/testComposerReplyAndForwardSend \
  --only-testing MailernUITests/ComposerSwipeSavesDraftUITests/testComposerSwipeSavesDraft
