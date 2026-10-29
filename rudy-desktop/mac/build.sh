#!/usr/bin/env bash
#
# Builds ../dist/Rudy.app from source, on the machine it will run on.
#
#   ./build.sh
#
# Needs only the Xcode Command Line Tools (xcode-select --install). Because
# the app is compiled locally it carries no quarantine flag, so macOS opens it
# with no "unidentified developer" dialog at all.
#
# Universal: tries arm64 + x86_64 and lipo's them together; falls back to the
# native architecture if a cross-build is unavailable.

set -euo pipefail
cd "$(dirname "$0")"

ROOT="$(cd .. && pwd)"
APP="$ROOT/dist/Rudy.app"
BIN="$APP/Contents/MacOS/Rudy"

if ! command -v swiftc >/dev/null 2>&1; then
    echo "swiftc not found. Install the Command Line Tools first:" >&2
    echo "  xcode-select --install" >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

build_arch() { # <target-triple> <output>
    swiftc -O -swift-version 5 \
        -target "$1" \
        -o "$2" \
        Rudy.swift \
        -framework AppKit -framework QuartzCore
}

if build_arch arm64-apple-macos11.0 "$TMP/arm64" >/dev/null 2>&1 &&
   build_arch x86_64-apple-macos11.0 "$TMP/x86_64" >/dev/null 2>&1; then
    lipo -create -output "$BIN" "$TMP/arm64" "$TMP/x86_64"
    echo "built universal (arm64 + x86_64)"
else
    swiftc -O -swift-version 5 -o "$BIN" Rudy.swift -framework AppKit -framework QuartzCore
    echo "built native ($(uname -m))"
fi

cp Info.plist "$APP/Contents/Info.plist"
cp "$ROOT/shared/spritesheet.png" "$APP/Contents/Resources/spritesheet.png"

# Ad-hoc signature: mandatory on Apple Silicon, and keeps macOS happy about
# the bundle after we rewrite it.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "$APP"
echo "Run it with:  open \"$APP\""
