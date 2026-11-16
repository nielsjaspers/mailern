#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
simulator_id=${1:?Usage: scripts/check-ui.sh DISPOSABLE_SIMULATOR_ID [WORKERS]}
workers=${2:-3}
case "$workers" in 1|2|3|4) ;; *) echo 'WORKERS must be 1, 2, 3, or 4' >&2; exit 2 ;; esac
derived_data=build/ui-tests
run_id=$(date +%Y%m%d-%H%M%S)-$$
xcodebuild -project Mailern.xcodeproj -scheme Mailern -destination "id=$simulator_id" \
  -derivedDataPath "$derived_data" build-for-testing
# Native pickers need fixtures in this Simulator, rather than in worker clones.
xcrun simctl bootstatus "$simulator_id" -b
xcrun simctl install "$simulator_id" "$derived_data/Build/Products/Debug-iphonesimulator/Mailern.app"
app_data=$(xcrun simctl get_app_container "$simulator_id" com.example.mailern data)
mkdir -p "$app_data/Documents"
cp 'Tests/Fixtures/Sample attachment.txt' "$app_data/Documents/Sample attachment.txt"
xcrun simctl addmedia "$simulator_id" 'Tests/Fixtures/Sample photo.png'
picker_file=MailernUITests/ComposerUITests/testComposerFileAttachment
picker_photo=MailernUITests/ComposerUITests/testComposerPhotoAttachment
xcodebuild -project Mailern.xcodeproj -scheme Mailern -destination "id=$simulator_id" \
  -derivedDataPath "$derived_data" -resultBundlePath "build/ui-pickers-$run_id.xcresult" \
  test-without-building -parallel-testing-enabled NO \
  "-only-testing:$picker_file" "-only-testing:$picker_photo"
xcodebuild -project Mailern.xcodeproj -scheme Mailern -destination "id=$simulator_id" \
  -derivedDataPath "$derived_data" -resultBundlePath "build/ui-parallel-$run_id.xcresult" \
  test-without-building -parallel-testing-enabled YES -parallel-testing-worker-count "$workers" \
  "-skip-testing:$picker_file" "-skip-testing:$picker_photo"
