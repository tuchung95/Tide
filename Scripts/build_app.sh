#!/bin/bash
# Builds Tide, packages it as Tide.app, installs it to /Applications, and
# (unless SKIP_RELEASE=1) publishes it as a GitHub Release so installed
# copies can auto-update (see Sources/Tide/UpdateChecker.swift +
# UpdateInstaller.swift).
#
# Run `SKIP_RELEASE=1 ./Scripts/build_app.sh` for a local-only build+install
# while iterating on small tweaks, without bumping Resources/VERSION or
# publishing a public release each time.
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
SKIP_RELEASE="${SKIP_RELEASE:-0}"

echo "Compiling release binary..."
mkdir -p .build/release
swiftc -O -whole-module-optimization \
    -o ".build/release/${APP_NAME}" \
    "${SOURCES[@]}"

# Bump the patch version on every build so each published release has a
# strictly newer CFBundleShortVersionString for UpdateChecker to compare
# against — skipped when just building+installing locally (SKIP_RELEASE=1),
# so VERSION stays pinned to whatever was last actually published.
VERSION_FILE="Resources/VERSION"
CURRENT_VERSION=$(cat "${VERSION_FILE}" 2>/dev/null || echo "1.0.0")
if [ "${SKIP_RELEASE}" = "1" ]; then
    NEW_VERSION="${CURRENT_VERSION}"
    echo "SKIP_RELEASE=1: local build+install only, version stays ${NEW_VERSION}"
else
    IFS='.' read -r VMAJOR VMINOR VPATCH <<< "${CURRENT_VERSION}"
    NEW_VERSION="${VMAJOR}.${VMINOR}.$((VPATCH + 1))"
    echo "${NEW_VERSION}" > "${VERSION_FILE}"
    echo "Version: ${CURRENT_VERSION} -> ${NEW_VERSION}"
fi

echo "Assembling ${APP_BUNDLE}..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp ".build/release/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "Resources/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"
cp "Resources/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
cp "Resources/CaptureSound.mp3" "${APP_BUNDLE}/Contents/Resources/CaptureSound.mp3"
cp "Resources/SidebarGeneralIcon.png" "${APP_BUNDLE}/Contents/Resources/SidebarGeneralIcon.png"
cp "Resources/SidebarScreenshotIcon.png" "${APP_BUNDLE}/Contents/Resources/SidebarScreenshotIcon.png"
cp "Resources/SidebarSpeedMeterIcon.png" "${APP_BUNDLE}/Contents/Resources/SidebarSpeedMeterIcon.png"
cp "Resources/SidebarScrollingIcon.png" "${APP_BUNDLE}/Contents/Resources/SidebarScrollingIcon.png"
cp "Resources/SidebarDisplayIcon.png" "${APP_BUNDLE}/Contents/Resources/SidebarDisplayIcon.png"

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

if [ "${SKIP_RELEASE}" = "1" ]; then
    echo ""
    echo "SKIP_RELEASE=1: not publishing a release (local build+install only)."
else
    # Publish as a GitHub Release so other installed copies can find and
    # download this build via UpdateChecker. Best-effort: a network hiccup
    # or missing `gh` auth here shouldn't fail the local build+install
    # above, which already succeeded.
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

            # Only the current version is kept: every older release (and
            # its tag) is deleted right after the new one publishes, so
            # the releases page never accumulates the patch versions this
            # script bumps on every build. Runs only once the new release
            # exists, so a failed publish can never leave the repo with no
            # release at all.
            OLD_RELEASES=$(gh release list --repo "${REPO}" --limit 200 \
                --json tagName --jq ".[].tagName | select(. != \"v${NEW_VERSION}\")" 2>/dev/null || true)
            for OLD_TAG in ${OLD_RELEASES}; do
                if gh release delete "${OLD_TAG}" --repo "${REPO}" --cleanup-tag --yes >/dev/null 2>&1; then
                    echo "Removed old release ${OLD_TAG}."
                else
                    echo "Warning: failed to remove old release ${OLD_TAG}."
                fi
            done
        else
            echo "Warning: failed to create GitHub release v${NEW_VERSION}."
        fi
    fi
fi
