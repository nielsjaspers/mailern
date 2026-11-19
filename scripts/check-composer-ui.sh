#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
simulator_id=${1:?Usage: scripts/check-composer-ui.sh DISPOSABLE_SIMULATOR_ID}
shift
exec scripts/check-ui.sh "$simulator_id" "$@" \
  --only-testing MailernUITests/MinimizedDraftUITests \
  --only-testing MailernTests \
  --only-testing MailernUITests/RecipientSearchUITests \
  --only-testing MailernUITests/ComposerSelectionHandleDragKeepsEditingUITests \
  --only-testing MailernUITests/ComposerDragDismissesKeyboardAndKeepsContentUITests \
  --only-testing MailernUITests/FormattingKeepsSelectionAbovePanelUITests \
  --only-testing MailernUITests/InboxDraftPreviewEditAndDiscardUITests \
  --only-testing MailernUITests/ComposerDraftSaveFailureKeepsEditorUITests \
  --only-testing MailernUITests/ComposerCleanupFailureClosesAfterAcknowledgementUITests \
  --only-testing MailernUITests/UndoSendReopensTheReplyUITests \
  --only-testing MailernUITests/ComposerPhotoAttachmentUITests \
  --only-testing MailernUITests/ComposerFileAttachmentUITests
