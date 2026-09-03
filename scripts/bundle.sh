#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export DEVELOPER_DIR=$(xcode-select -p)

VERSION=${VOICE_VERSION:-0.0.0}
RELEASE=${VOICE_RELEASE:-0}

if [ "$RELEASE" = "1" ]; then
    IDENTITY=${VOICE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}
    if [ -z "$IDENTITY" ]; then
        printf '%s\n' \
            'ERROR: No Developer ID Application signing identity found.' \
            'Install a signing certificate or set VOICE_SIGN_IDENTITY to a valid identity.' >&2
        exit 1
    fi
else
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
fi
if [ "$IDENTITY" = "-" ]; then
    printf '%s\n' \
        'WARNING: mbl.app will be ad-hoc signed.' \
        'macOS privacy permissions will need to be granted again after each rebuild.' >&2
fi

sign_code() {
    if [ "$RELEASE" = "1" ]; then
        codesign --force --sign "$IDENTITY" --options runtime --timestamp "$@"
    else
        codesign --force --sign "$IDENTITY" "$@"
    fi
}

cd "$ROOT"
swift build -c release
BIN_DIR=$(swift build -c release --show-bin-path)
APP="$ROOT/build/mbl.app"
CONTENTS="$APP/Contents"
SPARKLE_FRAMEWORK="$CONTENTS/Frameworks/Sparkle.framework"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Frameworks"
cp "$BIN_DIR/Voice" "$CONTENTS/MacOS/Voice"
cp -R "$BIN_DIR/Sparkle.framework" "$CONTENTS/Frameworks/"
cp "$ROOT/assets/icon/Voice.icns" "$CONTENTS/Resources/Voice.icns"
cp "$ROOT/assets/icon/Assets.car" "$CONTENTS/Resources/Assets.car"
cp "$ROOT/assets/icon/Assets.car" "$CONTENTS/Resources/Assets.car"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Voice</string>
    <key>CFBundleIconFile</key>
    <string>Voice</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.olliespage.mbl-voice</string>
    <key>CFBundleName</key>
    <string>mbl</string>
    <key>CFBundleDisplayName</key>
    <string>mbl</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>mbl needs microphone access to transcribe your speech.</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>SUScheduledCheckInterval</key>
    <integer>86400</integer>
    <key>SUAutomaticallyUpdate</key>
    <false/>
</dict>
</plist>
PLIST

if [ "$RELEASE" = "1" ]; then
    /usr/libexec/PlistBuddy -c \
        'Add :SUFeedURL string https://github.com/discorev/mbl/releases/latest/download/appcast.xml' \
        "$CONTENTS/Info.plist"
fi

for XPC_SERVICE in "$SPARKLE_FRAMEWORK/Versions/B/XPCServices/"*.xpc; do
    [ -d "$XPC_SERVICE" ] || continue
    if [ "$(basename "$XPC_SERVICE")" = "Downloader.xpc" ]; then
        sign_code --preserve-metadata=entitlements "$XPC_SERVICE"
    else
        sign_code "$XPC_SERVICE"
    fi
done
sign_code "$SPARKLE_FRAMEWORK/Versions/B/Autoupdate"
sign_code "$SPARKLE_FRAMEWORK/Versions/B/Updater.app"
sign_code "$SPARKLE_FRAMEWORK"
sign_code --entitlements "$ROOT/Voice.entitlements" "$APP"
printf '%s\n' "$APP"
