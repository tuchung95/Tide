#!/bin/bash
# Builds Tide, packages it as Tide.app, installs it to /Applications, and
# publishes it as a GitHub Release so installed copies can auto-update
# (see Sources/Tide/UpdateChecker.swift + UpdateInstaller.swift).
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
REPO="tuchung95/Tide"

echo "Compiling release binary..."
mkdir -p .build/release
swiftc -O -whole-module-optimization \
    -o ".build/release/${APP_NAME}" \
    "${SOURCES[@]}"

# Bump the patch version on every build so each published release has a
# strictly newer CFBundleShortVersionString for UpdateChecker to compare
# against.
VERSION_FILE="Resources/VERSION"
CURRENT_VERSION=$(cat "${VERSION_FILE}" 2>/dev/null || echo "1.0.0")
IFS='.' read -r VMAJOR VMINOR VPATCH <<< "${CURRENT_VERSION}"
NEW_VERSION="${VMAJOR}.${VMINOR}.$((VPATCH + 1))"
echo "${NEW_VERSION}" > "${VERSION_FILE}"
echo "Version: ${CURRENT_VERSION} -> ${NEW_VERSION}"

echo "Assembling ${APP_BUNDLE}..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp ".build/release/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "Resources/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"
cp "Resources/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
cp "Resources/CaptureSound.mp3" "${APP_BUNDLE}/Contents/Resources/CaptureSound.mp3"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${NEW_VERSION}" "${APP_BUNDLE}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${NEW_VERSION}" "${APP_BUNDLE}/Contents/Info.plist"

# A stable local signing identity, if one has been set up (see README's
# "Giữ quyền Screen Recording qua các lần rebuild" section), keeps macOS's
# privacy permissions (Screen Recording) intact across rebuilds. Plain
# ad-hoc signing (`--sign -`) re-derives its identity from the binary's
# hash every time, so each rebuild looks like a brand new, unauthorized app
# to TCC and the Screen Recording prompt reappears.
SIGN_IDENTITY="Tide Local Dev"
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "\"${SIGN_IDENTITY}\""; then
    echo "No '${SIGN_IDENTITY}' signing identity found; falling back to ad-hoc signing."
    echo "(Screen Recording permission will need to be re-granted after each rebuild.)"
    SIGN_IDENTITY="-"
fi

echo "Code signing (${SIGN_IDENTITY})..."
codesign --force --deep --sign "${SIGN_IDENTITY}" "${APP_BUNDLE}"

echo "Done: ${APP_BUNDLE}"

# Installed to /Applications on every build, not just left in this dev
# folder: running two separate copies (dev folder vs /Applications) is how
# a stale, differently-signed /Applications copy silently keeps eating
# Screen Recording grants meant for the copy actually being rebuilt.
INSTALL_PATH="/Applications/${APP_BUNDLE}"
echo "Installing to ${INSTALL_PATH}..."
pkill -x "${APP_NAME}" 2>/dev/null || true
sleep 0.5
rm -rf "${INSTALL_PATH}"
cp -R "${APP_BUNDLE}" "${INSTALL_PATH}"
open "${INSTALL_PATH}"

echo "Launched ${INSTALL_PATH}."
echo "First screenshot capture will prompt for Screen Recording permission"
echo "in System Settings > Privacy & Security."

# Publish as a GitHub Release so other installed copies can find and
# download this build via UpdateChecker. Best-effort: a network hiccup or
# missing `gh` auth here shouldn't fail the local build+install above,
# which already succeeded.
echo ""
echo "Publishing release v${NEW_VERSION}..."
PUBLISH_OK=true
ZIP_PATH=".build/${APP_NAME}-v${NEW_VERSION}.zip"
rm -f "${ZIP_PATH}"

if ! ditto -c -k --keepParent "${APP_BUNDLE}" "${ZIP_PATH}"; then
    echo "Warning: failed to zip ${APP_BUNDLE}; skipping release publish."
    PUBLISH_OK=false
fi

if [ "${PUBLISH_OK}" = true ]; then
    git add "${VERSION_FILE}"
    if ! git commit -m "Bump version to v${NEW_VERSION}" >/dev/null; then
        echo "Warning: failed to commit version bump; skipping release publish."
        PUBLISH_OK=false
    fi
fi

if [ "${PUBLISH_OK}" = true ] && ! git push >/dev/null; then
    echo "Warning: failed to push version bump commit; skipping release publish."
    PUBLISH_OK=false
fi

if [ "${PUBLISH_OK}" = true ]; then
    if gh release create "v${NEW_VERSION}" "${ZIP_PATH}" \
        --repo "${REPO}" \
        --title "v${NEW_VERSION}" \
        --notes "Automated build."; then
        echo "Published: https://github.com/${REPO}/releases/tag/v${NEW_VERSION}"
    else
        echo "Warning: failed to create GitHub release v${NEW_VERSION}."
    fi
fi
