#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="$PROJECT_ROOT/build"
APP_NAME="MacEnvManager"
APP_BUNDLE="$BUILD_ROOT/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"
ICONSET="$BUILD_ROOT/AppIcon.iconset"
DMG_STAGE="$BUILD_ROOT/dmg-stage"
DIST_DIR="$PROJECT_ROOT/dist"
DMG_PATH="$DIST_DIR/MacEnvManager-1.4.0-universal.dmg"
COMPATIBLE_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"

if [[ -d "$COMPATIBLE_SDK" ]]; then
  SDK_PATH="$COMPATIBLE_SDK"
else
  SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
fi

rm -rf "$APP_BUNDLE" "$ICONSET" "$DMG_STAGE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$ICONSET" "$DMG_STAGE" "$DIST_DIR"

mkdir -p "$BUILD_ROOT/module-cache-icon"
swiftc \
  -sdk "$SDK_PATH" \
  -target "$(uname -m)-apple-macosx13.0" \
  -module-cache-path "$BUILD_ROOT/module-cache-icon" \
  "$PROJECT_ROOT/Scripts/generate_icon.swift" \
  -o "$BUILD_ROOT/generate-icon"
"$BUILD_ROOT/generate-icon" "$BUILD_ROOT/AppIcon-1024.png"

sips -z 16 16 "$BUILD_ROOT/AppIcon-1024.png" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32 "$BUILD_ROOT/AppIcon-1024.png" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$BUILD_ROOT/AppIcon-1024.png" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64 "$BUILD_ROOT/AppIcon-1024.png" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$BUILD_ROOT/AppIcon-1024.png" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256 "$BUILD_ROOT/AppIcon-1024.png" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$BUILD_ROOT/AppIcon-1024.png" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512 "$BUILD_ROOT/AppIcon-1024.png" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$BUILD_ROOT/AppIcon-1024.png" --out "$ICONSET/icon_512x512.png" >/dev/null
cp "$BUILD_ROOT/AppIcon-1024.png" "$ICONSET/icon_512x512@2x.png"
swiftc \
  -sdk "$SDK_PATH" \
  -target "$(uname -m)-apple-macosx13.0" \
  -module-cache-path "$BUILD_ROOT/module-cache-icon" \
  "$PROJECT_ROOT/Scripts/make_icns.swift" \
  -o "$BUILD_ROOT/make-icns"
"$BUILD_ROOT/make-icns" "$ICONSET" "$RESOURCES_DIR/AppIcon.icns"

SOURCE_FILES=("$PROJECT_ROOT"/Sources/*.swift)
for ARCH in arm64 x86_64; do
  mkdir -p "$BUILD_ROOT/module-cache-$ARCH"
  swiftc \
    -parse-as-library \
    -O \
    -whole-module-optimization \
    -swift-version 5 \
    -sdk "$SDK_PATH" \
    -target "$ARCH-apple-macosx13.0" \
    -module-cache-path "$BUILD_ROOT/module-cache-$ARCH" \
    -framework AppKit \
    -framework SwiftUI \
    -framework Combine \
    "${SOURCE_FILES[@]}" \
    -o "$BUILD_ROOT/$APP_NAME-$ARCH"
done

lipo -create \
  "$BUILD_ROOT/$APP_NAME-arm64" \
  "$BUILD_ROOT/$APP_NAME-x86_64" \
  -output "$MACOS_DIR/$APP_NAME"

cp "$PROJECT_ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
chmod 755 "$MACOS_DIR/$APP_NAME"
codesign --force --deep --sign - --timestamp=none "$APP_BUNDLE"

plutil -lint "$CONTENTS/Info.plist"
codesign --verify --deep --strict "$APP_BUNDLE"
lipo -info "$MACOS_DIR/$APP_NAME"

ditto "$APP_BUNDLE" "$DMG_STAGE/$APP_NAME.app"
ln -s /Applications "$DMG_STAGE/Applications"
rm -f "$DMG_PATH"
hdiutil create \
  -volname "Mac Env Manager" \
  -srcfolder "$DMG_STAGE" \
  -ov \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$DMG_PATH"
hdiutil verify "$DMG_PATH"

echo "$DMG_PATH"
