#!/usr/bin/env bash
# Runs the A8 PowerPoint probe on an iPhone 11 simulator and prints PROBE lines.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
DECKS="$ROOT/build/pptx-probe"
mkdir -p "$DECKS"
python3 -m venv "$ROOT/build/pptx-venv"
"$ROOT/build/pptx-venv/bin/pip" install --quiet python-pptx==1.0.2 pillow
"$ROOT/build/pptx-venv/bin/python" "$ROOT/Tools/PPTXAudit/make_test_deck.py" "$DECKS/audit.pptx"
"$ROOT/build/pptx-venv/bin/python" "$ROOT/Tools/PPTXAudit/make_probe_decks.py" "$DECKS/audit.pptx" "$DECKS"
ls -l "$DECKS"

DEVICE_TYPE=com.apple.CoreSimulator.SimDeviceType.iPhone-11
RUNTIME=$(xcrun simctl list runtimes --json | python3 -c '
import json, sys
runtimes = [r for r in json.load(sys.stdin)["runtimes"]
            if r.get("platform") == "iOS" and r.get("isAvailable")
            and any(d.get("identifier") == sys.argv[1] for d in r.get("supportedDeviceTypes", []))]
runtimes.sort(key=lambda r: [int(p) for p in r["version"].split(".")])
print(runtimes[-1]["identifier"])
' "$DEVICE_TYPE")
UDID=$(xcrun simctl create "PPTX probe" "$DEVICE_TYPE" "$RUNTIME")
trap 'xcrun simctl delete "$UDID" >/dev/null 2>&1 || true' EXIT
echo "Runtime $RUNTIME, simulator $UDID"

cd "$ROOT/Tools/PPTXAudit/Probe"
xcodegen generate
TEST_RUNNER_PPTX_DIR="$DECKS" xcodebuild test \
  -project PPTXProbe.xcodeproj -scheme PPTXProbe \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$ROOT/build/pptx-dd" 2>&1 | tee "$ROOT/build/pptx-probe.log" | grep -E "PROBE|error:|Test Case|\*\* TEST" || true
grep -q "\*\* TEST SUCCEEDED \*\*" "$ROOT/build/pptx-probe.log"
