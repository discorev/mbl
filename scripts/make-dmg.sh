#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export DEVELOPER_DIR=$(xcode-select -p)

APP=${1:-"$ROOT/build/mbl.app"}
case "$APP" in
    /*) ;;
    *) APP="$PWD/$APP" ;;
esac

if [ ! -d "$APP" ]; then
    printf 'ERROR: App bundle not found: %s\n' "$APP" >&2
    exit 1
fi
if [ ! -f "$APP/Contents/Info.plist" ]; then
    printf 'ERROR: App bundle has no Info.plist: %s\n' "$APP" >&2
    exit 1
fi

VERSION=$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")
if [ -z "$VERSION" ]; then
    printf 'ERROR: CFBundleShortVersionString is empty in %s\n' "$APP/Contents/Info.plist" >&2
    exit 1
fi

OUTPUT=${2:-"$ROOT/build/mbl-$VERSION.dmg"}
case "$OUTPUT" in
    /*) ;;
    *) OUTPUT="$PWD/$OUTPUT" ;;
esac
OUTPUT_DIR=$(dirname -- "$OUTPUT")
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(CDPATH= cd -- "$OUTPUT_DIR" && pwd)
OUTPUT="$OUTPUT_DIR/$(basename -- "$OUTPUT")"

RELEASE=${VOICE_RELEASE:-0}
SKIP_SIGN=${VOICE_DMG_SKIP_SIGN:-0}
if [ "$RELEASE" = "1" ] && [ "$SKIP_SIGN" = "1" ]; then
    printf 'ERROR: VOICE_DMG_SKIP_SIGN=1 is only allowed for local, non-release builds.\n' >&2
    exit 1
fi
SVG="$ROOT/assets/dmg/background.svg"
if [ ! -f "$SVG" ]; then
    printf 'ERROR: DMG background not found: %s\n' "$SVG" >&2
    exit 1
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/mbl-dmg.XXXXXX")
STAGE="$WORK/stage"
MOUNT="$WORK/mount"
READ_WRITE_DMG="$WORK/mbl-read-write.dmg"
DEVICE=
cleanup() {
    if [ -n "$DEVICE" ]; then
        hdiutil detach "$DEVICE" -force >/dev/null 2>&1 || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT HUP INT TERM
mkdir -p "$STAGE/.background" "$MOUNT"

cat > "$WORK/render.swift" <<'SWIFT'
import AppKit

let svgURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputs = [
    (URL(fileURLWithPath: CommandLine.arguments[2]), 660, 400),
    (URL(fileURLWithPath: CommandLine.arguments[3]), 1320, 800),
]
guard let image = NSImage(contentsOf: svgURL) else {
    fputs("make-dmg: cannot load \(svgURL.path)\n", stderr)
    exit(1)
}
for (outputURL, width, height) in outputs {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: rep) else {
        fputs("make-dmg: cannot create \(width)x\(height) bitmap\n", stderr)
        exit(1)
    }
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.interpolationQuality = .high
    image.draw(
        in: NSRect(x: 0, y: 0, width: width, height: height),
        from: .zero, operation: .copy, fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fputs("make-dmg: cannot encode \(outputURL.path)\n", stderr)
        exit(1)
    }
    do {
        try png.write(to: outputURL)
    } catch {
        fputs("make-dmg: cannot write \(outputURL.path): \(error)\n", stderr)
        exit(1)
    }
}
SWIFT

swift "$WORK/render.swift" "$SVG" "$WORK/background.png" "$WORK/background@2x.png"
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" \
    -out "$STAGE/.background/background.tiff" >/dev/null

ditto "$APP" "$STAGE/mbl.app"
ln -s /Applications "$STAGE/Applications"
chflags hidden "$STAGE/.background"

hdiutil create -quiet -ov -format UDRW -fs HFS+ -volname mbl \
    -srcfolder "$STAGE" "$READ_WRITE_DMG"
ATTACH_OUTPUT=$(hdiutil attach -readwrite -noverify -noautoopen \
    -mountpoint "$MOUNT" "$READ_WRITE_DMG")
DEVICE=$(printf '%s\n' "$ATTACH_OUTPUT" | awk '/^\/dev\// { print $1; exit }')
if [ -z "$DEVICE" ]; then
    printf 'ERROR: Could not determine the device for %s\n' "$READ_WRITE_DMG" >&2
    exit 1
fi
chflags hidden "$MOUNT/.background"

cat > "$WORK/layout.applescript" <<'APPLESCRIPT'
on run argv
    set mountPath to item 1 of argv
    tell application "Finder"
        set targetDisk to disk of (POSIX file mountPath as alias)
        open targetDisk
        delay 1
        set targetWindow to container window of targetDisk
        set current view of targetWindow to icon view
        set toolbar visible of targetWindow to false
        set statusbar visible of targetWindow to false
        -- Finder's bounds include its 32-point title bar on macOS 26.
        set bounds of targetWindow to {100, 100, 760, 532}
        set viewOptions to icon view options of targetWindow
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set text size of viewOptions to 13
        set backgroundFile to POSIX file (mountPath & "/.background/background.tiff") as alias
        set background picture of viewOptions to backgroundFile
        set position of item "mbl.app" of targetDisk to {165, 190}
        set position of item "Applications" of targetDisk to {495, 190}
        update targetDisk without registering applications
        delay 1
        close targetWindow
        open targetDisk
        delay 1
    end tell
end run
APPLESCRIPT

cat > "$WORK/verify.applescript" <<'APPLESCRIPT'
on run argv
    set mountPath to item 1 of argv
    tell application "Finder"
        set targetDisk to disk of (POSIX file mountPath as alias)
        set targetWindow to container window of targetDisk
        set viewOptions to icon view options of targetWindow
        set appPosition to position of item "mbl.app" of targetDisk
        set applicationsPosition to position of item "Applications" of targetDisk
        if appPosition is not {165, 190} then error "mbl.app position is " & (appPosition as text)
        if applicationsPosition is not {495, 190} then error "Applications position is " & (applicationsPosition as text)

        set backgroundVerified to false
        try
            set backgroundFile to background picture of viewOptions
            if backgroundFile is not missing value and name of backgroundFile is "background.tiff" then
                set backgroundVerified to true
            end if
        end try
        -- Finder 26 displays the background but reports this property as missing value.
        -- In that case, verify its persisted image alias in Finder's metadata instead.
        if backgroundVerified is false then
            set storePath to mountPath & "/.DS_Store"
            try
                do shell script "/usr/bin/grep -a -F -q background.tiff " & quoted form of storePath
                set backgroundVerified to true
            end try
        end if
        if backgroundVerified is false then error "background picture is not background.tiff"
        return "background.tiff; mbl.app=165,190; Applications=495,190"
    end tell
end run
APPLESCRIPT

LAYOUT_OK=0
ATTEMPT=1
while [ "$ATTEMPT" -le 3 ]; do
    if osascript "$WORK/layout.applescript" "$MOUNT" && \
        osascript "$WORK/verify.applescript" "$MOUNT" >/dev/null; then
        LAYOUT_OK=1
        break
    fi
    if [ "$ATTEMPT" -lt 3 ]; then
        printf 'WARNING: Finder layout attempt %s of 3 failed; retrying.\n' "$ATTEMPT" >&2
        sleep 2
    fi
    ATTEMPT=$((ATTEMPT + 1))
done
if [ "$LAYOUT_OK" -ne 1 ]; then
    printf '%s\n' \
        'ERROR: Finder did not retain the DMG background and icon positions after 3 attempts.' >&2
    exit 1
fi

sync
sleep 1
hdiutil detach "$DEVICE" >/dev/null
DEVICE=

rm -f "$OUTPUT"
hdiutil convert -quiet "$READ_WRITE_DMG" -format UDZO \
    -imagekey zlib-level=9 -o "$OUTPUT"

if [ "$SKIP_SIGN" = "1" ]; then
    printf 'WARNING: DMG signing was skipped because VOICE_DMG_SKIP_SIGN=1.\n' >&2
else
    if [ "$RELEASE" = "1" ]; then
        IDENTITY=${VOICE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}
        if [ -z "$IDENTITY" ] || [ "$IDENTITY" = "-" ]; then
            printf '%s\n' \
                'ERROR: No valid Developer ID Application signing identity found for the DMG.' \
                'Install a signing certificate or set VOICE_SIGN_IDENTITY to a valid identity.' \
                'Ad-hoc signing is not allowed when VOICE_RELEASE=1.' >&2
            exit 1
        fi
    else
        IDENTITY=${VOICE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)}
        if [ -z "$IDENTITY" ] || [ "$IDENTITY" = "-" ]; then
            printf '%s\n' \
                'ERROR: No valid Apple Development signing identity found for the DMG.' \
                'Install a signing certificate, set VOICE_SIGN_IDENTITY, or deliberately skip local DMG signing with:' \
                '  VOICE_DMG_SKIP_SIGN=1 scripts/make-dmg.sh' >&2
            exit 1
        fi
    fi
    codesign --sign "$IDENTITY" --timestamp "$OUTPUT"
fi

printf '%s\n' "$OUTPUT"
