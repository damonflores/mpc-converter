#!/bin/bash
# Builds "MPC Converter.app" into ./build
#   ./build.sh              → native architecture (needs Xcode or Command Line Tools)
#   ./build.sh --universal  → Apple Silicon + Intel (needs full Xcode)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="MPC Converter"
EXE="MPCConverter"
OUT="build/${APP_NAME}.app"

if ! command -v swift >/dev/null 2>&1; then
  echo "Swift not found. Install Xcode from the App Store, or run: xcode-select --install"
  exit 1
fi

ARGS=(-c release)
if [[ "${1:-}" == "--universal" ]]; then
  ARGS+=(--arch arm64 --arch x86_64)
fi

echo "▸ Compiling (${ARGS[*]})…"
swift build "${ARGS[@]}"
BIN_DIR="$(swift build "${ARGS[@]}" --show-bin-path)"

echo "▸ Assembling ${OUT}"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN_DIR/$EXE" "$OUT/Contents/MacOS/$EXE"
cp Resources/Info.plist "$OUT/Contents/Info.plist"
cp Resources/AppIcon.icns "$OUT/Contents/Resources/AppIcon.icns"

echo "▸ Ad-hoc signing"
codesign --force --sign - --timestamp=none "$OUT"

echo "✓ Built: $(pwd)/$OUT"
echo "  Drag it to /Applications, or run: open \"$OUT\""
[ -z "${CI:-}" ] && open -R "$OUT" || true
