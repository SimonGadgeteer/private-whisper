#!/bin/bash
# Packages PrivateWhisper.app into a shareable DMG. Models are NOT bundled —
# the app downloads them on first run.
#
# Signing note: with only an "Apple Development" certificate, recipients must
# right-click → Open (or System Settings → Privacy & Security → Open Anyway)
# on first launch. Gatekeeper-clean distribution needs a paid Developer ID
# certificate + notarization (add here when available).
set -euo pipefail

cd "$(dirname "$0")/.."
./scripts/build_app.sh

VERSION=$(defaults read "$PWD/build/PrivateWhisper.app/Contents/Info.plist" CFBundleShortVersionString)
STAGING="build/dmg-staging"
DMG="build/PrivateWhisper-$VERSION.dmg"

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R build/PrivateWhisper.app "$STAGING/"
ln -s /Applications "$STAGING/Applications"

cat > "$STAGING/READ ME FIRST.txt" <<'EOF'
Private Whisper — local push-to-talk dictation
==============================================

1. Drag PrivateWhisper.app into Applications.
2. FIRST LAUNCH: right-click the app → Open → Open.
   (If macOS still refuses: System Settings → Privacy & Security → scroll
   down → "Open Anyway".)
3. Grant Microphone when prompted, and enable the app under
   System Settings → Privacy & Security → Accessibility.
4. On first run the app shows two one-click downloads with progress bars:
   - Transcription model (required, ~1.5 GB)
   - Cleanup model (optional, ~2.7 GB) — polishes your dictation into
     clean text, fully on your Mac (no other software needed)
   Then dictate: hold RIGHT OPTION, speak, release.

Advanced: if LM Studio is running (locally or on another machine on your
network), the app uses it automatically instead of the embedded model.

Everything runs on your Mac. No audio or text ever leaves it.

UNINSTALL: open the app window (menu bar icon → Open Private Whisper) →
Settings → "Remove Downloaded Models…", then quit the app and drag it from
Applications to the Trash. (The models live in ~/Library/Application
Support/PrivateWhisper — that button deletes them; dragging the app alone
would leave ~4 GB behind.)
EOF

hdiutil create -volname "Private Whisper" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

echo "==> $DMG"
shasum -a 256 "$DMG"
