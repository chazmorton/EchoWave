#!/usr/bin/env bash
# Builds build/EchoWave.app from the Swift package.
#   CONFIG=debug scripts/build-app.sh            # debug build
#   CODESIGN_IDENTITY="Apple Development: …"     # sign with a specific certificate
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-release}"
APP="$ROOT/build/EchoWave.app"
cd "$ROOT"

echo "▸ Compiling ($CONFIG)…"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/EchoWave" "$APP/Contents/MacOS/EchoWave"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# A real certificate keeps macOS permissions (Accessibility, Microphone) across rebuilds.
# Without one the app is signed ad hoc, and permissions must be re-granted after each rebuild.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Apple Development|Developer ID Application/ { print $2; exit }')"
fi
if [[ -n "$IDENTITY" ]]; then
  echo "▸ Signing with \"$IDENTITY\""
  codesign --force --sign "$IDENTITY" "$APP"
else
  echo "▸ Signing ad hoc (no developer certificate found)"
  codesign --force --sign - "$APP"
fi

echo "✓ Built $APP"
