#!/bin/bash
# Build, sign, install and launch Private Whisper on a USB-connected iPhone.
#   ios/scripts/deploy.sh [device-name-or-id]
# Team: $PW_TEAM, or the first line of ios/.team (gitignored). A free Personal
# Team works; its builds stop launching after 7 days — just re-run this script.
set -euo pipefail
cd "$(dirname "$0")/.."
TEAM="${PW_TEAM:-$(head -1 .team 2>/dev/null || true)}"
[ -n "$TEAM" ] || { echo "Set PW_TEAM or write your team ID to ios/.team"; exit 1; }
DEVICE="${1:-}"
if [ -z "$DEVICE" ]; then
  DEVICE=$(xcrun devicectl list devices 2>/dev/null | awk '/physical/ && /iPhone/ && /(available|connected)/ {print $3; exit}')
fi
[ -n "$DEVICE" ] || { echo "No connected iPhone found"; exit 1; }
echo "==> Device: $DEVICE  Team: $TEAM"
xcodegen generate >/dev/null
xcodebuild -project PrivateWhisper.xcodeproj -scheme PrivateWhisper -configuration Debug \
  -destination "id=$DEVICE" -derivedDataPath build/dd \
  DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic \
  PW_GIT_COMMIT="$(git rev-parse --short HEAD)$(git diff --quiet HEAD -- . ../shared || echo -modified)" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build \
  | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
APP=build/dd/Build/Products/Debug-iphoneos/PrivateWhisper.app
xcrun devicectl device install app --device "$DEVICE" "$APP" | tail -3
xcrun devicectl device process launch --device "$DEVICE" ch.simonschwarz.privatewhisper.ios | tail -2 || \
  echo "Launch blocked: on the iPhone open Settings > General > VPN & Device Management and trust your developer profile, then run again."
