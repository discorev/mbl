#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
swift build --build-tests
products_dir="$(swift build --show-bin-path)"
sparkle_framework="$PWD/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
# The Xcode SwiftPM runner doesn't embed binary dependency frameworks in test bundles.
# Its generated rpath already includes PackageFrameworks beside the test products.
mkdir -p "$products_dir/PackageFrameworks"
ditto "$sparkle_framework" "$products_dir/PackageFrameworks/Sparkle.framework"
swift test --skip-build
