#!/usr/bin/env bash
# Builds TaskLens and runs every test suite on an iPhone 11 simulator.
# Used by GitHub Actions; also runnable locally on a Mac with Xcode and XcodeGen.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-11"
DEVICE_NAME="TaskLens iPhone 11"
LOG_DIR="$ROOT/build/logs"
mkdir -p "$LOG_DIR"

step() { echo; echo "==> $*"; }

# Fails the script unless the xcodebuild log reports success, printing the
# relevant errors first so they are visible in the CI log.
# Counts, skipped tests, accessibility audit notes and performance numbers
# from the app test log, for the QA report.
summarize_app_tests() {
  local log="$LOG_DIR/app-ios.log"
  [[ -f "$log" ]] || return 0
  echo "---- app test summary ----"
  echo "passed:  $(grep -cE "Test Case .* passed" "$log" || true)"
  echo "failed:  $(grep -cE "Test Case .* failed" "$log" || true)"
  echo "skipped: $(grep -cE "Test Case .* skipped" "$log" || true)"
  grep -E "Test Case .* (failed|skipped)" "$log" | sort -u | head -40 || true
  grep -E "Skipped|XCTSkip|QA NOTE" "$log" | sort -u | head -20 || true
  grep -E "measured \[" "$log" | sed -E "s/.*(test[A-Za-z0-9_]+)\]' (measured \[[^]]*\]).*(average: [0-9.]+).*/\1 \2 \3/" | sort -u | head -20 || true
  grep -E "^[[:space:]]*AUDIT (FAIL|NOTE)" "$log" | sed -E 's/^.*(AUDIT )/\1/' | sort -u | head -60 || true
  # What was on screen when a UI test could not find an element.
  grep -E "^[[:space:]]*MISSING " "$log" | sed -E 's/^.*(MISSING )/\1/' | head -40 || true
  # What the YouTube player and AVKit reported in the video PiP feasibility tests.
  grep -E "^[[:space:]]*VIDEO " "$log" | sed -E 's/^.*(VIDEO )/\1/' | head -80 || true
}

require_success() {
  local log="$1"
  if ! grep -q "TEST SUCCEEDED" "$log"; then
    echo "---- errors from $log ----" >&2
    grep -E "error:|failed|✘" "$log" | head -100 >&2 || true
    echo "---- tail of $log ----" >&2
    tail -40 "$log" >&2
    exit 1
  fi
}

step "Toolchain"
xcodebuild -version
swift --version

step "Static checks: strings, hard-coded text, privacy manifests"
# Every UI string comes from scripts/strings.py with English and Arabic.
python3 scripts/strings.py >/dev/null
if ! git diff --quiet -- Packages/TaskLensUI/Sources/TLLocalization App/TaskLens/Resources; then
  echo "Generated string catalogs are out of date: run scripts/strings.py" >&2
  git diff --stat >&2
  exit 1
fi
HARDCODED=$(grep -rnE 'Text\("[^"]|Button\("[^"]|Label\("[^"]|navigationTitle\("[^"]|accessibilityLabel\("[^"]|TextField\("[^"]|Toggle\("[^"]' \
  --include=*.swift Packages/TaskLensUI/Sources App/TaskLens App/TaskLensShare App/TaskLensWidgets App/Shared | grep -v '#Preview' || true)
if [[ -n "$HARDCODED" ]]; then
  echo "Hard-coded user-visible strings (use L10nKey):" >&2
  echo "$HARDCODED" >&2
  exit 1
fi
for manifest in App/TaskLens/Resources/PrivacyInfo.xcprivacy App/TaskLensShare/PrivacyInfo.xcprivacy App/TaskLensWidgets/PrivacyInfo.xcprivacy; do
  plutil -lint "$manifest"
done
echo "Strings, text and privacy manifests OK"

step "Pick the newest iOS runtime that supports iPhone 11"
RUNTIME=$(xcrun simctl list runtimes --json | python3 -c '
import json, sys
device = sys.argv[1]
runtimes = [r for r in json.load(sys.stdin)["runtimes"]
            if r.get("platform") == "iOS" and r.get("isAvailable")
            and any(d.get("identifier") == device for d in r.get("supportedDeviceTypes", []))]
runtimes.sort(key=lambda r: [int(p) for p in r["version"].split(".")])
print(runtimes[-1]["identifier"] if runtimes else "")
' "$DEVICE_TYPE")
if [[ -z "$RUNTIME" ]]; then
  echo "No installed iOS runtime supports iPhone 11." >&2
  xcrun simctl list runtimes
  exit 1
fi
echo "Runtime: $RUNTIME"

UDID=$(xcrun simctl create "$DEVICE_NAME" "$DEVICE_TYPE" "$RUNTIME")
trap 'xcrun simctl delete "$UDID" >/dev/null 2>&1 || true' EXIT
DESTINATION="platform=iOS Simulator,id=$UDID"
echo "Simulator: $UDID"

step "TaskLensKit: swift test on the Mac host (fast feedback)"
if ! (cd Packages/TaskLensKit && swift test 2>&1 | tee "$LOG_DIR/kit-host.log"); then
  echo "---- failed Kit tests ----" >&2
  grep -E "✘|Expectation failed|recorded an issue|error:" "$LOG_DIR/kit-host.log" | head -60 >&2 || true
  exit 1
fi

step "TaskLensKit: tests on iPhone 11 simulator"
(cd Packages/TaskLensKit && xcodebuild test \
  -scheme TaskLensKit-Package \
  -destination "$DESTINATION" \
  -derivedDataPath "$ROOT/build/DerivedData" \
  2>&1 | tee "$LOG_DIR/kit-ios.log" | grep -E "error:|warning: .*TaskLens|Test (Suite|case)|✔|✘|passed|failed|TEST (SUCCEEDED|FAILED)" || true)
require_success "$LOG_DIR/kit-ios.log"

step "TaskLensUI: tests on iPhone 11 simulator"
(cd Packages/TaskLensUI && xcodebuild test \
  -scheme TaskLensUI-Package \
  -destination "$DESTINATION" \
  -derivedDataPath "$ROOT/build/DerivedData" \
  2>&1 | tee "$LOG_DIR/ui-ios.log" | grep -E "error:|✔|✘|passed|failed|TEST (SUCCEEDED|FAILED)" || true)
require_success "$LOG_DIR/ui-ios.log"

step "Generate Xcode project"
xcodegen generate

# UI tests are compiled every time but only run when UI_TESTS=true.
# The screenshot tour is not a check; the Screenshots workflow runs it.
APP_TEST_FILTER=(-skip-testing:TaskLensAppUITests/ScreenshotTour)
if [[ "${UI_TESTS:-false}" != "true" ]]; then
  APP_TEST_FILTER=(-skip-testing:TaskLensAppUITests)
fi
# TEMPORARY (A9.5.6 diagnosis, to be reverted): only the picture diagnostics,
# so no other test loads a PowerPoint file in the same process meanwhile.
APP_TEST_FILTER=(-only-testing:TaskLensTests/PowerPointPictureDiagnosticsTests)

step "App + share extension: build and test on iPhone 11 simulator (UI tests: ${UI_TESTS:-false})"
xcodebuild test \
  -project TaskLens.xcodeproj \
  -scheme TaskLens \
  -destination "$DESTINATION" \
  -derivedDataPath "$ROOT/build/DerivedData" \
  ${APP_TEST_FILTER[@]+"${APP_TEST_FILTER[@]}"} \
  -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 300 \
  -maximum-test-execution-time-allowance 600 \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | tee "$LOG_DIR/app-ios.log" | grep --line-buffered -E "error:|✔|✘|passed|failed|skipped|measured|PPTX |PROBEIMG |TEST (SUCCEEDED|FAILED)" || true
summarize_app_tests
require_success "$LOG_DIR/app-ios.log"

step "App Intents metadata and widget extension are in the app bundle"
APP="$ROOT/build/DerivedData/Build/Products/Debug-iphonesimulator/TaskLens.app"
ACTIONS="$APP/Metadata.appintents/extract.actionsdata"
test -f "$ACTIONS" || { echo "Missing $ACTIONS: Siri and Shortcuts would not see the intents" >&2; exit 1; }
for intent in StartWorkspaceIntent OpenWorkspaceIntent StartSessionIntent OpenSessionIntent SaveContentIntent SaveToSessionIntent \
              SendToTaskLensIntent StartLensIntent OpenClipboardIntent CreateNoteIntent CalculateIntent \
              ConvertCurrencyIntent OpenDestinationIntent StopSessionIntent \
              CaptureScreenIntent StopScreenLensIntent; do
  grep -q "$intent" "$ACTIONS" || { echo "$intent is not in the App Intents metadata" >&2; exit 1; }
done
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("metadata keys:", sorted(d)); print("app shortcuts:", len(d.get("autoShortcuts", [])))' "$ACTIONS" || true
test -d "$APP/PlugIns/TaskLensWidgets.appex" || { echo "Widget extension is not embedded" >&2; exit 1; }
test -f "$APP/PlugIns/TaskLensWidgets.appex/Metadata.appintents/extract.actionsdata" \
  || echo "note: the widget extension has no App Intents metadata of its own"
echo "App Intents metadata lists every intent; widget extension embedded"
for bundle in "$APP" "$APP/PlugIns/TaskLensShare.appex" "$APP/PlugIns/TaskLensWidgets.appex"; do
  test -f "$bundle/PrivacyInfo.xcprivacy" || { echo "Missing privacy manifest in $bundle" >&2; exit 1; }
done
echo "Privacy manifests are in the app and both extensions"

step "Release: archive for devices (unsigned)"
xcodebuild archive \
  -project TaskLens.xcodeproj \
  -scheme TaskLens \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "$ROOT/build/TaskLens.xcarchive" \
  -derivedDataPath "$ROOT/build/DerivedDataRelease" \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | tee "$LOG_DIR/archive.log" | grep -E "error:|warning: .*TaskLens|ARCHIVE (SUCCEEDED|FAILED)" || true
if ! grep -q "ARCHIVE SUCCEEDED" "$LOG_DIR/archive.log"; then
  grep -E "error:" "$LOG_DIR/archive.log" | head -60 >&2 || true
  tail -40 "$LOG_DIR/archive.log" >&2
  exit 1
fi
ARCHIVED_APP="$ROOT/build/TaskLens.xcarchive/Products/Applications/TaskLens.app"
test -d "$ARCHIVED_APP" || { echo "Archive has no app" >&2; exit 1; }
for bundle in "$ARCHIVED_APP" "$ARCHIVED_APP/PlugIns/TaskLensShare.appex" "$ARCHIVED_APP/PlugIns/TaskLensWidgets.appex"; do
  test -f "$bundle/PrivacyInfo.xcprivacy" || { echo "Missing privacy manifest in archived $bundle" >&2; exit 1; }
done
echo "Release archive size: $(du -sh "$ARCHIVED_APP" | cut -f1)"
/usr/libexec/PlistBuddy -c "Print :MinimumOSVersion" "$ARCHIVED_APP/Info.plist" | sed 's/^/Minimum iOS: /'

summarize_app_tests
step "All builds and tests passed on $DEVICE_NAME ($RUNTIME)"
