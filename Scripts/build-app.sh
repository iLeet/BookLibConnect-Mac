#!/bin/zsh
# Builds "Book Lib Connect.app" from the Swift package.
#   Scripts/build-app.sh            release build for this Mac
#   UNIVERSAL=1 Scripts/build-app.sh   arm64 + x86_64
#   CONFIG=debug Scripts/build-app.sh
set -euo pipefail

cd "${0:A:h}/.."
CONFIG="${CONFIG:-release}"
APP_NAME="Book Lib Connect"
BUNDLE_ID="com.github.ileet.BookLibConnect-Mac"
VERSION="$(cat VERSION)"
OUT="build/${APP_NAME}.app"

ARCHS=()
[[ "${UNIVERSAL:-0}" == "1" ]] && ARCHS=(--arch arm64 --arch x86_64)

swift build -c "$CONFIG" "${ARCHS[@]}"
BIN="$(swift build -c "$CONFIG" "${ARCHS[@]}" --show-bin-path)/BookLibConnect"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/BookLibConnect"

# App icon: compile the Icon Composer document when available, else the prebuilt .icns.
ICON_KEYS=""
if [[ -d Resources/AppIcon.icon ]] && xcrun --find actool >/dev/null 2>&1; then
  TMP="$(mktemp -d)"
  if xcrun actool Resources/AppIcon.icon --compile "$TMP" --platform macosx \
      --minimum-deployment-target 26.0 --app-icon AppIcon --include-all-app-icons \
      --output-partial-info-plist "$TMP/partial.plist" >/dev/null 2>&1 && [[ -f "$TMP/Assets.car" ]]; then
    cp "$TMP/Assets.car" "$OUT/Contents/Resources/"
    [[ -f "$TMP/AppIcon.icns" ]] && cp "$TMP/AppIcon.icns" "$OUT/Contents/Resources/"
    ICON_KEYS='<key>CFBundleIconName</key><string>AppIcon</string><key>CFBundleIconFile</key><string>AppIcon</string>'
  fi
  rm -rf "$TMP"
fi
if [[ -z "$ICON_KEYS" && -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$OUT/Contents/Resources/AppIcon.icns"
  ICON_KEYS='<key>CFBundleIconFile</key><string>AppIcon</string>'
fi

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>BookLibConnect</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  ${ICON_KEYS}
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHumanReadableCopyright</key><string>Copyright © audiamus. macOS port released under the GNU GPL v3.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature with the hardened runtime; replace "-" with a Developer ID to distribute.
codesign --force --options runtime --sign "${SIGN_IDENTITY:--}" "$OUT" 2>&1 | grep -v "replacing existing signature" || true

echo "Built: $OUT"
