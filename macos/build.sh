#!/bin/bash
# Builds MacDroidSync.app, a menu bar only application bundle.
#
#   ./build.sh              release build into build/MacDroidSync.app
#   ./build.sh debug        debug build
#
set -euo pipefail
cd "$(dirname "$0")"

CONFIGURATION="${1:-release}"
case "${CONFIGURATION}" in
    debug|release) ;;
    *)
        echo "Unknown configuration '${CONFIGURATION}'." >&2
        echo "Usage: ./build.sh [debug|release]" >&2
        exit 2
        ;;
esac

APP_NAME="MacDroidSync"
EXTENSION_NAME="ShareExtension"
BUNDLE="build/${APP_NAME}.app"
APPEX="${BUNDLE}/Contents/PlugIns/${EXTENSION_NAME}.appex"

echo "==> Building ${APP_NAME} (${CONFIGURATION})"
swift build -c "${CONFIGURATION}" --product "${APP_NAME}"
swift build -c "${CONFIGURATION}" --product "${EXTENSION_NAME}"
BIN_PATH="$(swift build -c "${CONFIGURATION}" --show-bin-path)"

echo "==> Assembling ${BUNDLE}"
rm -rf "${BUNDLE}"
mkdir -p "${BUNDLE}/Contents/MacOS" "${BUNDLE}/Contents/Resources"
cp "${BIN_PATH}/${APP_NAME}" "${BUNDLE}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${BUNDLE}/Contents/Info.plist"
cp Resources/AppIcon.icns "${BUNDLE}/Contents/Resources/AppIcon.icns"

echo "==> Assembling ${APPEX}"
mkdir -p "${APPEX}/Contents/MacOS"
cp "${BIN_PATH}/${EXTENSION_NAME}" "${APPEX}/Contents/MacOS/${EXTENSION_NAME}"
cp Resources/ShareExtension-Info.plist "${APPEX}/Contents/Info.plist"

# Ad-hoc signature: macOS only shows the local network prompt for signed bundles.
# The extension is signed first and with its entitlements, then the app, so that
# the outer signature covers the finished plug-in.
#
# The app carries entitlements too, for the Photos library: PhotoKit reports
# .authorized and then sees nothing at all without it. An ad-hoc signature can
# carry entitlements, and this one needs no provisioning profile.
echo "==> Signing (ad-hoc)"
codesign --force --sign - --timestamp=none \
    --entitlements Resources/ShareExtension.entitlements "${APPEX}" >/dev/null
codesign --force --sign - --timestamp=none \
    --entitlements Resources/MacDroidSync.entitlements "${BUNDLE}" >/dev/null

echo "==> Done: ${BUNDLE}"
echo
echo "To run it:"
echo "    open ${BUNDLE}"
echo "To run it with logs on stdout:"
echo "    MDS_VERBOSE=1 ${BUNDLE}/Contents/MacOS/${APP_NAME}"
echo
echo "To let the system pick up the Share extension and the Services entry:"
echo "    pluginkit -a ${APPEX}"
echo "    /System/Library/CoreServices/pbs -flush"
echo "Then enable MacDroidSync under System Settings, General, Login Items and Extensions, Sharing."
