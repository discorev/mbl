#!/bin/sh
# Renders assets/icon/mbl.svg with AppKit, packs an .icns with iconutil, and
# compiles an asset catalog with actool. macOS 26 only draws a legacy .icns
# shrunken inside a frame at small sizes; the catalog (Assets.car plus
# CFBundleIconName) is what Finder and the Dock actually use. Both outputs
# are committed, so scripts/bundle.sh does not depend on this script.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SVG="$ROOT/assets/icon/mbl.svg"
ICNS="$ROOT/assets/icon/Voice.icns"
CAR="$ROOT/assets/icon/Assets.car"
CAR="$ROOT/assets/icon/Assets.car"
WORK=$(mktemp -d)
ICONSET="$WORK/Voice.iconset"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$ICONSET"

cat > "$WORK/render.swift" <<'SWIFT'
import AppKit

let svgURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outDir = CommandLine.arguments[2]
guard let image = NSImage(contentsOf: svgURL) else {
    fputs("make-icon: cannot load \(svgURL.path)\n", stderr)
    exit(1)
}
let sizes: [(String, Int)] = [
    ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
    ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512),
    ("512x512", 512), ("512x512@2x", 1024),
]
for (name, px) in sizes {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: rep) else {
        fputs("make-icon: cannot create bitmap for \(name)\n", stderr)
        exit(1)
    }
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.interpolationQuality = .high
    image.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
    try png.write(to: URL(fileURLWithPath: "\(outDir)/icon_\(name).png"))
}
SWIFT

swift "$WORK/render.swift" "$SVG" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$ICNS"

CATALOG="$WORK/Icon.xcassets"
SET="$CATALOG/AppIcon.appiconset"
mkdir -p "$SET"
printf '{"info":{"author":"xcode","version":1}}\n' > "$CATALOG/Contents.json"
cp "$ICONSET"/icon_*.png "$SET/"
cat > "$SET/Contents.json" <<'JSON'
{"info":{"author":"xcode","version":1},"images":[
{"idiom":"mac","size":"16x16","scale":"1x","filename":"icon_16x16.png"},
{"idiom":"mac","size":"16x16","scale":"2x","filename":"icon_16x16@2x.png"},
{"idiom":"mac","size":"32x32","scale":"1x","filename":"icon_32x32.png"},
{"idiom":"mac","size":"32x32","scale":"2x","filename":"icon_32x32@2x.png"},
{"idiom":"mac","size":"128x128","scale":"1x","filename":"icon_128x128.png"},
{"idiom":"mac","size":"128x128","scale":"2x","filename":"icon_128x128@2x.png"},
{"idiom":"mac","size":"256x256","scale":"1x","filename":"icon_256x256.png"},
{"idiom":"mac","size":"256x256","scale":"2x","filename":"icon_256x256@2x.png"},
{"idiom":"mac","size":"512x512","scale":"1x","filename":"icon_512x512.png"},
{"idiom":"mac","size":"512x512","scale":"2x","filename":"icon_512x512@2x.png"}
]}
JSON
mkdir -p "$WORK/out"
xcrun actool "$CATALOG" --compile "$WORK/out" --platform macosx \
    --minimum-deployment-target 26.0 --app-icon AppIcon \
    --output-partial-info-plist "$WORK/out/partial.plist" > /dev/null
cp "$WORK/out/Assets.car" "$CAR"
printf '%s\n%s\n' "$ICNS" "$CAR"
