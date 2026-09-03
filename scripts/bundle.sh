#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export DEVELOPER_DIR=$(xcode-select -p)

IDENTITY=${VOICE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)}
if [ -z "$IDENTITY" ]; then
    if [ "${VOICE_ALLOW_ADHOC_SIGNING:-0}" = "1" ]; then
        IDENTITY=-
    else
        printf '%s\n' \
            'ERROR: No Apple Development signing identity found.' \
            'Install a signing certificate or set VOICE_SIGN_IDENTITY to a valid identity.' \
            'To deliberately use an unstable ad-hoc signature, rerun with:' \
            '  VOICE_ALLOW_ADHOC_SIGNING=1 scripts/bundle.sh' >&2
        exit 1
    fi
fi
if [ "$IDENTITY" = "-" ]; then
    printf '%s\n' \
        'WARNING: Voice.app will be ad-hoc signed.' \
        'macOS privacy permissions will need to be granted again after each rebuild.' >&2
fi

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
    <string>com.olliespage.mbl-voice</string>
    <key>CFBundleName</key>
    <string>Voice</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Voice needs microphone access to transcribe your speech.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign "$IDENTITY" "$APP"
printf '%s\n' "$APP"
