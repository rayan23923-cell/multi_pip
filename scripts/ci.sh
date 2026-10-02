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
(cd Packages/TaskLensKit && swift test 2>&1 | tee "$LOG_DIR/kit-host.log")

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
APP_TEST_FILTER=()
if [[ "${UI_TESTS:-false}" != "true" ]]; then
  APP_TEST_FILTER=(-skip-testing:TaskLensAppUITests)
fi

step "App + share extension: build and test on iPhone 11 simulator (UI tests: ${UI_TESTS:-false})"
xcodebuild test \
  -project TaskLens.xcodeproj \
  -scheme TaskLens \
  -destination "$DESTINATION" \
  -derivedDataPath "$ROOT/build/DerivedData" \
  ${APP_TEST_FILTER[@]+"${APP_TEST_FILTER[@]}"} \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | tee "$LOG_DIR/app-ios.log" | grep -E "error:|✔|✘|passed|failed|TEST (SUCCEEDED|FAILED)" || true
require_success "$LOG_DIR/app-ios.log"

step "All builds and tests passed on $DEVICE_NAME ($RUNTIME)"
