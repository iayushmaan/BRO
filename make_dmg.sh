#!/bin/bash
# Makes dist/BRO.dmg from the BRO.app that build_app.sh put in ~/Applications.
# Run build_app.sh first.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/BRO.app"
OUT="$DIR/dist"
STAGE="$(mktemp -d)"

if [ ! -d "$APP" ]; then
  echo "BRO.app not found in ~/Applications. Run: bash build_app.sh first."
  exit 1
fi

echo "1/3 Copying the app..."
cp -R "$APP" "$STAGE/BRO.app"
# Re-sign without your private certificate, so the app can be shared with other Macs
codesign --force --deep --sign - "$STAGE/BRO.app"
ln -s /Applications "$STAGE/Applications"

echo "2/3 Making the .dmg..."
mkdir -p "$OUT"
rm -f "$OUT/BRO.dmg"
hdiutil create -volname "BRO" -srcfolder "$STAGE" -ov -format UDZO "$OUT/BRO.dmg" >/dev/null
rm -rf "$STAGE"

echo "3/3 Done! The file is: $OUT/BRO.dmg"
open -R "$OUT/BRO.dmg"
