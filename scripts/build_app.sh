#!/bin/bash
# Builds PrivateWhisper.app: swift build → assemble bundle → embed
# whisper.framework → codesign with the Apple Development identity so the
# TCC (Accessibility/Microphone) grants survive rebuilds.
set -euo pipefail

cd "$(dirname "$0")/.."
PROJECT_DIR="$PWD"
APP_NAME="PrivateWhisper"
BUILD_DIR="$PROJECT_DIR/.build/arm64-apple-macosx/release"
APP_DIR="$PROJECT_DIR/build/$APP_NAME.app"
SIGN_IDENTITY="${SIGN_IDENTITY:-Apple Development: REDACTED-IDENTITY}"

echo "==> swift build -c release"
swift build -c release --arch arm64

echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Frameworks" "$APP_DIR/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/"

# Embedded cleanup sidecar (llama.cpp server, static build)
if [ -f "$PROJECT_DIR/vendor/llama-server" ]; then
    cp "$PROJECT_DIR/vendor/llama-server" "$APP_DIR/Contents/MacOS/"
fi

# Embed the whisper dynamic framework (macOS slice of the xcframework).
cp -R "$PROJECT_DIR/Frameworks/whisper.xcframework/macos-arm64_x86_64/whisper.framework" \
      "$APP_DIR/Contents/Frameworks/"

echo "==> Codesigning"
codesign --force --sign "$SIGN_IDENTITY" \
    "$APP_DIR/Contents/Frameworks/whisper.framework"
if [ -f "$APP_DIR/Contents/MacOS/llama-server" ]; then
    codesign --force --sign "$SIGN_IDENTITY" "$APP_DIR/Contents/MacOS/llama-server"
fi
codesign --force --sign "$SIGN_IDENTITY" \
    --identifier ch.simonschwarz.PrivateWhisper \
    "$APP_DIR"

codesign --verify --deep --strict "$APP_DIR"
echo "==> Done: $APP_DIR"
