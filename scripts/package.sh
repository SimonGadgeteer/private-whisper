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
4. The app offers to download the transcription model (~1.5 GB) on first
   run — one click, then you can dictate: hold RIGHT OPTION, speak, release.

Optional (better text quality): install LM Studio (lmstudio.ai), download
the model "qwen/qwen3.5-4b", and enable the local server (port 1234).
Without it the app still works and inserts the raw transcription.

Everything runs on your Mac. No audio or text ever leaves it.
EOF

hdiutil create -volname "Private Whisper" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

echo "==> $DMG"
shasum -a 256 "$DMG"
