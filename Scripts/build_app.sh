#!/bin/bash
# Builds Tide and packages it as Tide.app so it can be double-clicked,
# added to Login Items, and shows no Dock icon.
#
# Compiles directly with swiftc rather than `swift build`: SwiftPM's
# manifest resolution needs the platform SDK path from a full Xcode.app
# install (`xcrun --show-sdk-platform-path`), which isn't available with
# just the Command Line Tools. swiftc doesn't need it.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Tide"
APP_BUNDLE="${APP_NAME}.app"
SOURCES=(Sources/Tide/*.swift)

echo "Compiling release binary..."
mkdir -p .build/release
swiftc -O -whole-module-optimization \
    -o ".build/release/${APP_NAME}" \
    "${SOURCES[@]}"

echo "Assembling ${APP_BUNDLE}..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp ".build/release/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "Resources/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"
cp "Resources/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"

echo "Ad-hoc code signing..."
codesign --force --deep --sign - "${APP_BUNDLE}"

echo "Done: ${APP_BUNDLE}"
echo "Move it to /Applications and double-click to launch."
echo "First screenshot capture will prompt for Screen Recording permission"
echo "in System Settings > Privacy & Security."
