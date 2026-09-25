#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_DIR="$PROJECT_DIR/.build/Zoom Red Light.app"
CONTENTS_DIR="$APP_DIR/Contents"

cd "$PROJECT_DIR"
mkdir -p "$CONTENTS_DIR/MacOS"
xcrun clang \
    -fobjc-arc \
    -Wall \
    -Wextra \
    -arch arm64 \
    -arch x86_64 \
    -mmacosx-version-min=13.0 \
    -framework AppKit \
    -framework ApplicationServices \
    "$PROJECT_DIR/Sources/ZoomRedLight/main.m" \
    -o "$CONTENTS_DIR/MacOS/ZoomRedLight"

/usr/libexec/PlistBuddy -c "Clear dict" "$CONTENTS_DIR/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleName string Zoom Red Light" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string Zoom Red Light" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.local.ZoomRedLight" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string ZoomRedLight" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string 1.7" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string 8" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 13.0" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$CONTENTS_DIR/Info.plist"

# An ad-hoc signature normally gets a code-hash designated requirement. That
# hash changes on every rebuild, causing macOS to treat the rebuilt app as a
# different Accessibility client. Keep the local app's identity stable instead.
codesign \
    --force \
    --sign - \
    --requirements '=designated => identifier "com.local.ZoomRedLight"' \
    "$APP_DIR"
echo "$APP_DIR"
