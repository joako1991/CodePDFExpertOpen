#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v xcodebuild >/dev/null; then
  echo 'Xcode on macOS is required: SwiftUI, UIKit, PDFKit and Vision are Apple SDKs.' >&2
  exit 2
fi
if [[ -n "${IOS_TEST_DESTINATION:-}" ]]; then
  destination="$IOS_TEST_DESTINATION"
else
  device_id=$(xcrun simctl list devices available -j | python3 -c '
import json,sys
data=json.load(sys.stdin)
devices=[device for runtime,items in data["devices"].items() if "iOS" in runtime for device in items if "iPad" in device["name"] and device.get("isAvailable",False)]
if not devices:
    sys.exit("No available iPad simulator. Install an iOS runtime in Xcode Settings > Components.")
print(devices[0]["udid"])
')
  destination="platform=iOS Simulator,id=$device_id"
fi
result_path="${IOS_TEST_RESULT_BUNDLE:-$PWD/build/TestResults-$(date -u +%Y%m%dT%H%M%SZ).xcresult}"
mkdir -p "$(dirname "$result_path")"
xcodebuild -project PaperStudio.xcodeproj -scheme PaperStudio \
  -destination "$destination" -derivedDataPath DerivedData \
  -resultBundlePath "$result_path" -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO test
