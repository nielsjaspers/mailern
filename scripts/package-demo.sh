#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
team_id=${1:?Usage: scripts/package-demo.sh TEAM_ID}
bundle_id=${2:-com.example.mailern}
mkdir -p build
xcodebuild -project Mailern.xcodeproj -scheme Mailern -configuration Release -destination 'generic/platform=iOS' -archivePath build/Mailern.xcarchive -derivedDataPath build/device "DEVELOPMENT_TEAM=$team_id" "PRODUCT_BUNDLE_IDENTIFIER=$bundle_id" -allowProvisioningUpdates archive
python3 - "$team_id" <<'PY'
import plistlib,sys
with open('build/ExportOptions.plist','wb') as f:
    plistlib.dump({'method':'debugging','teamID':sys.argv[1],'signingStyle':'automatic'},f)
PY
xcodebuild -exportArchive -archivePath build/Mailern.xcarchive -exportPath build/export -exportOptionsPlist build/ExportOptions.plist
