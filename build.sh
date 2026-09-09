#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="ClipboardManager"
APP_BUNDLE="$APP_NAME.app"

echo "==> Stopping any running instance..."
pkill -x "$APP_NAME" 2>/dev/null || true

echo "==> Building (release)..."
swift build -c release

echo "==> Assembling $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp ".build/release/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "Packaging/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

if [ -f "Packaging/AppIcon.icns" ]; then
    cp "Packaging/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

echo "==> Signing (ad-hoc)..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo ""
echo "Build complete: $(pwd)/$APP_BUNDLE"
echo "Launching..."
open "$APP_BUNDLE"
