#!/usr/bin/env bash
# Builds the app and runs the screenshot tour on an iPhone 11 simulator.
# PNGs land in docs/screenshots/.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-11"
OUT="$ROOT/docs/screenshots"
LOG_DIR="$ROOT/build/logs"
mkdir -p "$LOG_DIR"
rm -rf "$OUT" && mkdir -p "$OUT"

RUNTIME=$(xcrun simctl list runtimes --json | python3 -c '
import json, sys
device = sys.argv[1]
runtimes = [r for r in json.load(sys.stdin)["runtimes"]
            if r.get("platform") == "iOS" and r.get("isAvailable")
            and any(d.get("identifier") == device for d in r.get("supportedDeviceTypes", []))]
runtimes.sort(key=lambda r: [int(p) for p in r["version"].split(".")])
print(runtimes[-1]["identifier"] if runtimes else "")
' "$DEVICE_TYPE")
UDID=$(xcrun simctl create "TaskLens Screenshots" "$DEVICE_TYPE" "$RUNTIME")
trap 'xcrun simctl delete "$UDID" >/dev/null 2>&1 || true' EXIT
xcrun simctl boot "$UDID"
# A clean status bar: 9:41, full battery and signal.
xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 \
  --cellularBars 4 --wifiBars 3 || true

xcodegen generate
run_tour() {
  TEST_RUNNER_TASKLENS_SCREENSHOT_DIR="$OUT" xcodebuild test \
    -project TaskLens.xcodeproj \
    -scheme TaskLens \
    -destination "platform=iOS Simulator,id=$UDID" \
    -derivedDataPath "$ROOT/build/DerivedData" \
    CODE_SIGNING_ALLOWED=NO \
    "$@" \
    2>&1 | tee -a "$LOG_DIR/screenshots.log" | grep --line-buffered -E "error:|Test Case|TEST (SUCCEEDED|FAILED)" || true
}
# Light pass, then a dark pass: XCUIDevice.appearance does not reliably switch
# the simulator, so the dark screens run after simctl changes the appearance.
xcrun simctl ui "$UDID" appearance light || true
run_tour -only-testing:TaskLensAppUITests/ScreenshotTour -skip-testing:TaskLensAppUITests/ScreenshotTour/test07DarkMode
xcrun simctl ui "$UDID" appearance dark
run_tour -only-testing:TaskLensAppUITests/ScreenshotTour/test07DarkMode

COUNT=$(find "$OUT" -name '*.png' | wc -l | tr -d ' ')
echo "Saved $COUNT screenshots"
ls -1 "$OUT"
[[ "$COUNT" -gt 0 ]]
