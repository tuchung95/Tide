#!/bin/bash
# Builds Tide in release mode and packages it as Tide.app so it can be
# double-clicked, added to Login Items, and shows no Dock icon.
set -euo pipefail

cd "$(dirname "$0")/.."

echo "Building release binary..."
swift build -c release

APP_NAME="Tide"
BUILD_DIR=".build/release"
APP_BUNDLE="${APP_NAME}.app"

echo "Assembling ${APP_BUNDLE}..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${BUILD_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "Resources/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"

echo "Ad-hoc code signing..."
codesign --force --deep --sign - "${APP_BUNDLE}"

echo "Done: ${APP_BUNDLE}"
echo "Move it to /Applications and double-click to launch."
echo "First screenshot capture will prompt for Screen Recording permission"
echo "in System Settings > Privacy & Security."
