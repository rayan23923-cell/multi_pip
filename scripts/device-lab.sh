#!/usr/bin/env bash
# Makes an Xcode project you can run on your own iPhone with your Apple ID
# (a free Personal Team works), for the Video PiP Lab and other device tests.
#
#   scripts/device-lab.sh <TEAM_ID> <bundle.id.prefix> [--minimal]
#
# TEAM_ID: Xcode > Settings > Accounts > your team (10 characters), or open
#          the generated project and pick the team in Signing & Capabilities.
# prefix:  any reverse-DNS name nobody else uses, e.g. com.yourname.tasklens
# --minimal: leaves out the share extension, the widget and the App Group,
#          which a free Personal Team may not be able to sign. The app and the
#          lab still work; data is stored in the app's own container.
#
# Writes project-device.yml and TaskLensDevice.xcodeproj; project.yml and the
# CI project are not changed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TEAM="${1:-}"
PREFIX="${2:-}"
MINIMAL="${3:-}"
if [[ -z "$TEAM" || -z "$PREFIX" ]]; then
  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
fi
command -v xcodegen >/dev/null || { echo "Install XcodeGen first: brew install xcodegen" >&2; exit 1; }

python3 - "$TEAM" "$PREFIX" "$MINIMAL" <<'PY'
import sys, pathlib
team, prefix, minimal = sys.argv[1], sys.argv[2], sys.argv[3] == "--minimal"
text = pathlib.Path("project.yml").read_text()
text = text.replace("name: TaskLens\n", "name: TaskLensDevice\n", 1)
text = text.replace("com.example.tasklens", prefix)
text = text.replace('    SWIFT_VERSION: "6.0"\n',
                    f'    SWIFT_VERSION: "6.0"\n    DEVELOPMENT_TEAM: {team}\n    CODE_SIGN_STYLE: Automatic\n', 1)
if minimal:
    text = text.replace("      - target: TaskLensShare\n", "", 1)
    text = text.replace("      - target: TaskLensWidgets\n", "", 1)
    text = text.replace("""    entitlements:
      path: App/TaskLens/TaskLens.entitlements
      properties:
        com.apple.security.application-groups:
          - $(APP_GROUP_IDENTIFIER)
""", "", 1)
pathlib.Path("project-device.yml").write_text(text)
PY

xcodegen generate --spec project-device.yml
echo
echo "Next:"
echo "  1. open TaskLensDevice.xcodeproj"
echo "  2. Connect the iPhone, pick it as the run destination, scheme TaskLens, press Run (Debug)."
echo "  3. First time on the iPhone: Settings > Privacy & Security > Developer Mode on (it restarts),"
echo "     then Settings > General > VPN & Device Management > trust your Apple ID."
echo "  4. In TaskLens: Settings tab > Developer > Video PiP Lab."
