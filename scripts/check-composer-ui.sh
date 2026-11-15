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
xcodebuild -project Mailern.xcodeproj -scheme Mailern -destination "id=$simulator_id" -derivedDataPath "$derived_data" test-without-building \
  -only-testing:MailernUITests/MailernUITests/testComposerFileAttachment \
  -only-testing:MailernUITests/MailernUITests/testComposerFormattingDraftAndSend \
  -only-testing:MailernUITests/MailernUITests/testComposerReplyAndForwardSend \
  -only-testing:MailernUITests/MailernUITests/testComposerSwipeSavesDraft
