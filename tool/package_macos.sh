#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

VERSION="$(sed -n 's/^version: //p' pubspec.yaml | head -1)"
APP_PATH="$PROJECT_ROOT/build/macos/Build/Products/Release/拷贝漫画阅读器.app"
RELEASE_DIR="$PROJECT_ROOT/build/releases"
ZIP_PATH="$RELEASE_DIR/拷贝漫画阅读器_macOS_$VERSION.zip"
DMG_PATH="$RELEASE_DIR/拷贝漫画阅读器_macOS_$VERSION.dmg"
SIGN_IDENTITY="${MACOS_SIGN_IDENTITY:--}"

flutter build macos --release --no-pub

# Flutter native-asset hooks can re-sign App.framework after Xcode sealed the
# outer app during an incremental build. Sign nested code and the outer bundle
# together once more so the delivered artifact always passes strict validation.
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign \
    --force \
    --deep \
    --sign - \
    --entitlements macos/Runner/Release.entitlements \
    "$APP_PATH"
else
  codesign \
    --force \
    --deep \
    --options runtime \
    --timestamp \
    --sign "$SIGN_IDENTITY" \
    --entitlements macos/Runner/Release.entitlements \
    "$APP_PATH"
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"

mkdir -p "$RELEASE_DIR"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
hdiutil create \
  -volname "拷贝漫画阅读器" \
  -srcfolder "$APP_PATH" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

unzip -t "$ZIP_PATH" >/dev/null
hdiutil verify "$DMG_PATH" >/dev/null
echo "ZIP 与 DMG 完整性校验通过"
shasum -a 256 "$ZIP_PATH" "$DMG_PATH"
