#!/bin/sh
# Builds Fusetta.app (host app + FSKit extension + fusermount3).
#
# Needs Extension/Config/Local.xcconfig with a DEVELOPMENT_TEAM that has the
# FSKit entitlement (any paid Apple Developer team). Without it the app builds
# unsigned and macOS will refuse to load the extension.
#
#   scripts/build-app.sh [Debug|Release]
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
config=${1:-Release}
cd "$root/Extension"
command -v xcodegen >/dev/null || { echo "xcodegen is required: brew install xcodegen" >&2; exit 1; }
xcodegen generate --quiet
signing="-allowProvisioningUpdates"
if ! grep -qs '^DEVELOPMENT_TEAM *= *[A-Z0-9]' Config/Local.xcconfig; then
  echo "warning: no DEVELOPMENT_TEAM in Extension/Config/Local.xcconfig; building unsigned" >&2
  signing="CODE_SIGNING_ALLOWED=NO"
fi
xcodebuild -project Fusetta.xcodeproj -scheme Fusetta -configuration "$config" \
  -derivedDataPath "$root/build/xcode" $signing build
app="$root/build/xcode/Build/Products/$config/Fusetta.app"
# Xcode registers the freshly built bundle with LaunchServices. A second copy
# with the same extension bundle id (e.g. the one in /Applications) makes the
# System Settings toggle for the extension refuse to turn on, so unregister it.
pluginkit -r "$app/Contents/Extensions/FusettaFS.appex" 2>/dev/null || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$app" 2>/dev/null || true
echo "built: $app (copy it to /Applications before enabling the extension)"
