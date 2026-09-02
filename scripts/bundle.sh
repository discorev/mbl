#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer

cd "$ROOT"
swift build -c release
BIN_DIR=$(swift build -c release --show-bin-path)
APP="$ROOT/build/Voice.app"
CONTENTS="$APP/Contents"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN_DIR/Voice" "$CONTENTS/MacOS/Voice"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Voice</string>
    <key>CFBundleIdentifier</key>
    <string>dev.ollie.voice</string>
    <key>CFBundleName</key>
    <string>Voice</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Voice needs microphone access to transcribe your speech.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
printf '%s\n' "$APP"
