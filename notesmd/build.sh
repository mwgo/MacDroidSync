#!/bin/zsh
# Builds Notes MD for the Mac into build/Notes MD.app and puts it in /Applications.
# ./build.sh [debug|release]   (release by default)
set -euo pipefail
cd "$(dirname "$0")"
configuration=${1:-release}
configuration=${(C)configuration}
echo "==> Building Notes MD ($configuration)"
xcodebuild -project NotesMD.xcodeproj -scheme NotesMD -destination 'platform=macOS' \
    -configuration "$configuration" -derivedDataPath build/dd -allowProvisioningUpdates build | grep -E "error:|BUILD" || true
app="build/dd/Build/Products/$configuration/Notes MD.app"
[[ -d "$app" ]] || { echo "Build failed"; exit 1; }
rm -rf "build/Notes MD.app"
cp -R "$app" "build/Notes MD.app"
echo "==> Installing into /Applications"
rm -rf "/Applications/Notes MD.app"
cp -R "build/Notes MD.app" "/Applications/Notes MD.app"
echo "==> Done: /Applications/Notes MD.app"
