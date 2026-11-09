#!/bin/bash
# Builds "Audio Router Lite.app" into ./build using SwiftPM (works with Command Line Tools only; Xcode not required).
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Audio Router Lite"
EXEC="AudioRouterLite"
VERSION="0.1.0"
OUT="build/${APP_NAME}.app"

# Universal binary (Apple Silicon + Intel) by default. ARCHS="arm64" ./scripts/build-app.sh builds one slice only.
ARCHS="${ARCHS:-arm64 x86_64}"
SLICES=()
for ARCH in $ARCHS; do
    echo "==> Compiling (release, $ARCH)"
    swift build -c release --product "$EXEC" --triple "$ARCH-apple-macosx15.0"
    SLICES+=("$(swift build -c release --triple "$ARCH-apple-macosx15.0" --show-bin-path)/$EXEC")
done

echo "==> Assembling bundle"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
lipo -create "${SLICES[@]}" -output "$OUT/Contents/MacOS/$EXEC"
lipo -info "$OUT/Contents/MacOS/$EXEC"
cp Assets/macOS/AppIcon.icns "$OUT/Contents/Resources/AppIcon.icns"

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>io.github.rexcain.audiorouterlite</string>
    <key>CFBundleExecutable</key><string>${EXEC}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon.icns</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Audio Router Lite reads audio from the input devices you select in order to route it to an output device. Audio is never recorded or sent anywhere.</string>
</dict>
</plist>
PLIST

echo "==> Signing (ad-hoc)"
codesign --force --sign - "$OUT"
codesign --verify --verbose=1 "$OUT"

echo "==> Done: $OUT"
