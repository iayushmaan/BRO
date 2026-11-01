#!/bin/bash
# Builds BRO.app (with the built-in brain) from this folder and puts it in ~/Applications
# Needs Xcode (from the App Store) and the Metal Toolchain: xcodebuild -downloadComponent MetalToolchain
set -e
set -o pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/BRO.app"
PROJ="$DIR"
LOG="$PROJ/build.log"

echo "1/6 Preparing the project..."
echo "2/6 Building BRO with xcodebuild (the first time takes 10 to 25 minutes, please wait)..."
cd "$PROJ"
if ! xcodebuild -scheme BRO -destination 'platform=OS X' -configuration Release \
     -derivedDataPath "$PROJ/build" -skipMacroValidation -skipPackagePluginValidation build > "$LOG" 2>&1; then
  echo ""
  echo "BUILD FAILED. The error lines:"
  grep -E "error:" "$LOG" | head -20 || true
  echo "---- last lines of the log ----"
  tail -n 25 "$LOG"
  exit 1
fi
PRODUCTS="$PROJ/build/Build/Products/Release"
BIN="$PRODUCTS/BRO"
if [ ! -f "$BIN" ]; then
  echo "The built program was not found in $PRODUCTS. These files are there:"
  ls "$PRODUCTS"
  exit 1
fi

echo "3/6 Creating BRO.app..."
rm -rf "$APP"
mkdir -p "$HOME/Applications"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/BRO"
# Resource bundles (the Metal library of the brain lives in mlx-swift_Cmlx.bundle) go into Contents/Resources
for b in "$PRODUCTS"/*.bundle; do
  if [ -e "$b" ]; then cp -R "$b" "$APP/Contents/Resources/"; fi
done
METALLIB="$APP/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
if [ -f "$METALLIB" ]; then
  echo "(the brain's Metal library is inside the app: OK)"
else
  echo "WARNING: the brain's Metal library was not found inside the app. Resource bundles found:"
  ls "$APP/Contents/Resources"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>BRO</string>
  <key>CFBundleDisplayName</key><string>BRO</string>
  <key>CFBundleIdentifier</key><string>com.bro.assistant</string>
  <key>CFBundleExecutable</key><string>BRO</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>BRO</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSMicrophoneUsageDescription</key><string>BRO listens through the microphone only while the orb is visible.</string>
  <key>NSAppleEventsUsageDescription</key><string>BRO uses this to add reminders and notes, and to switch dark mode when you ask.</string>
</dict>
</plist>
PLIST

echo "4/6 Adding the icon..."
if [ -f "$DIR/BRO_icon.png" ]; then
  ICONSET="$(mktemp -d)/BRO.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$DIR/BRO_icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$DIR/BRO_icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/BRO.icns" || echo "(icon skipped)"
else
  echo "(BRO_icon.png not found, continuing without an icon)"
fi

echo "5/6 Signing..."
if security find-identity -v -p codesigning 2>/dev/null | grep -q "BRO Dev"; then
  codesign --force --deep --sign "BRO Dev" "$APP"
  echo "(signed with your BRO Dev certificate, so permissions will stay ON after rebuilds)"
else
  codesign --force --deep --sign - "$APP"
  echo "(no BRO Dev certificate found: permissions may need to be switched ON again after each rebuild)"
fi
touch "$APP"

echo "6/6 Done!"
echo "BRO.app is in your Applications folder (inside your home folder)."
open -R "$APP"
