#!/bin/bash
# Builds LiveBloom.app as a universal app (Apple silicon + Intel). Only needs the Xcode Command Line Tools.
#   ./build.sh            → build LiveBloom.app
#   ./build.sh --install  → also install it to /Applications and launch it
#   ./build.sh --dmg      → also create LiveBloom.dmg for sharing
set -euo pipefail
cd "$(dirname "$0")"
APP="LiveBloom.app"
NAME="LiveBloom"
VERSION="1.0"
mkdir -p .build/manual

# Strip source paths from the app (no personal folder names in the binary).
FLAGS=(-O -parse-as-library -file-prefix-map "$(pwd)=LiveBloom")
for ARCH in arm64 x86_64; do
  # Remove the old build and stop on compiler errors – otherwise a stale build would end up in the app.
  rm -f ".build/manual/$NAME-$ARCH"
  if ! swiftc "${FLAGS[@]}" -target "$ARCH-apple-macosx15.0" Sources/LiveBloom/*.swift -o ".build/manual/$NAME-$ARCH" > ".build/manual/swiftc-$ARCH.log" 2>&1; then
    grep -E "error" ".build/manual/swiftc-$ARCH.log" || cat ".build/manual/swiftc-$ARCH.log"
    echo "Compiling for $ARCH failed." >&2
    exit 1
  fi
done
lipo -create ".build/manual/$NAME-arm64" ".build/manual/$NAME-x86_64" -output ".build/manual/$NAME"

# Generate the app icon from the template.
ICONSET=".build/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s*2)); sips -z $d $d Resources/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/manual/$NAME" "$APP/Contents/MacOS/$NAME"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Translations (German is the source language in the code; the other languages ship as .strings files).
cp -R Resources/Localization/*.lproj "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>LiveBloom</string>
  <key>CFBundleDisplayName</key><string>LiveBloom</string>
  <key>CFBundleIdentifier</key><string>local.livebloom.app</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>LiveBloom</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array>$(for d in Resources/Localization/*.lproj; do n=$(basename "$d" .lproj); printf "<string>%s</string>" "$n"; done)</array>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 SerMonchi</string>
</dict></plist>
PLIST
# Signing:
#   Without variables → ad-hoc (for testing; Gatekeeper warns other users).
#   With an Apple Developer account (recommended for distribution):
#     DEVELOPER_ID="Developer ID Application: First Last (TEAMID)"
#     NOTARY_PROFILE="livebloom"   # create once: xcrun notarytool store-credentials livebloom
#     DEVELOPER_ID=… NOTARY_PROFILE=… ./build.sh --dmg
if [[ -n "${DEVELOPER_ID:-}" ]]; then
  codesign --force --options runtime --timestamp -s "$DEVELOPER_ID" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
else
  echo "Note: no DEVELOPER_ID set – ad-hoc signed (not notarized)."
  codesign --force --options runtime --timestamp=none -s - "$APP"
fi
echo "Done: $(pwd)/$APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Wallscape 2>/dev/null || true
  pkill -x MacScape 2>/dev/null || true
  pkill -x LiveBloom 2>/dev/null && sleep 1 || true
  rm -rf "/Applications/$APP"
  cp -R "$APP" "/Applications/$APP"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/$APP"
  echo "Installed: /Applications/$APP"
  open "/Applications/$APP"
fi

if [[ "${1:-}" == "--dmg" ]]; then
  STAGE=".build/dmg"
  rm -rf "$STAGE"; mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  cp "Resources/Read Me First.txt" "$STAGE/Read Me First – Bitte zuerst lesen.txt"
  rm -f LiveBloom.dmg
  hdiutil create -volname "LiveBloom $VERSION" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ LiveBloom.dmg >/dev/null
  if [[ -n "${DEVELOPER_ID:-}" ]]; then
    codesign --force --timestamp -s "$DEVELOPER_ID" LiveBloom.dmg
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
      echo "Notarizing with Apple (usually takes a few minutes) …"
      xcrun notarytool submit LiveBloom.dmg --keychain-profile "$NOTARY_PROFILE" --wait
      xcrun stapler staple LiveBloom.dmg
      spctl -a -vvv -t open --context context:primary-signature LiveBloom.dmg || true
    else
      echo "Note: NOTARY_PROFILE missing – DMG signed but not notarized."
    fi
  fi
  echo "DMG: $(pwd)/LiveBloom.dmg"
fi
