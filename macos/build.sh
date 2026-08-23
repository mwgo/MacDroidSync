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
BUNDLE="build/${APP_NAME}.app"

echo "==> Building ${APP_NAME} (${CONFIGURATION})"
swift build -c "${CONFIGURATION}" --product "${APP_NAME}"
BIN_PATH="$(swift build -c "${CONFIGURATION}" --show-bin-path)"

echo "==> Assembling ${BUNDLE}"
rm -rf "${BUNDLE}"
mkdir -p "${BUNDLE}/Contents/MacOS" "${BUNDLE}/Contents/Resources"
cp "${BIN_PATH}/${APP_NAME}" "${BUNDLE}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${BUNDLE}/Contents/Info.plist"
cp Resources/AppIcon.icns "${BUNDLE}/Contents/Resources/AppIcon.icns"

# Ad-hoc signature: macOS only shows the local network prompt for signed bundles.
echo "==> Signing (ad-hoc)"
codesign --force --sign - --timestamp=none "${BUNDLE}" >/dev/null

echo "==> Done: ${BUNDLE}"
echo
echo "To run it:"
echo "    open ${BUNDLE}"
echo "To run it with logs on stdout:"
echo "    MDS_VERBOSE=1 ${BUNDLE}/Contents/MacOS/${APP_NAME}"
