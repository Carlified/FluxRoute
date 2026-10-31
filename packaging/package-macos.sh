#!/bin/sh
# Packages a macOS release bundle into dist/.
#
#   packaging/package-macos.sh OSXARM64/Release/PnRGUI.app 1.0.0 [arm64|x64]
#
# Build the macOS target in RAD Studio first (see docs/BUILDING.md).
# ditto preserves the bundle's metadata and symlinks; plain zip can corrupt it.

set -eu

APP="${1:-}"
VERSION="${2:-dev}"
ARCH="${3:-arm64}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ -z "$APP" ] || [ ! -d "$APP" ]; then
  echo "usage: $0 <path/to/PnRGUI.app> <version> [arm64|x64]" >&2
  exit 2
fi

NAME="FluxRoute-${VERSION}-macos-${ARCH}"
DIST="$ROOT/dist"
STAGE="$DIST/$NAME"
rm -rf "$STAGE"
mkdir -p "$STAGE"

cp -R "$APP" "$STAGE/"
cp -R "$ROOT/tools" "$STAGE/"
cp "$ROOT/README.md" "$ROOT/LICENSE" "$STAGE/"
rm -f "$STAGE/tools/config.json"

ZIP="$DIST/$NAME.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc "$STAGE" "$ZIP"
rm -rf "$STAGE"

echo "wrote $ZIP"