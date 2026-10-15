#!/usr/bin/env bash
# Compile packaging/AppIcon.icon (Icon Composer format: white fill, vector angl triangle) into
# DEST (an .app's Contents/Resources): Assets.car for macOS 26+ and AppIcon.icns for older
# systems. Cached in build/icon until the script or the .icon bundle changes.
# Usage: scripts/icon.sh DEST
set -euo pipefail
cd "$(dirname "$0")/.."
dest="$1"
cache=build/icon
if [ ! -f "$cache/Assets.car" ] || [ "$0" -nt "$cache/Assets.car" ] ||
  [ -n "$(find packaging/AppIcon.icon -newer "$cache/Assets.car" 2>/dev/null)" ]; then
  rm -rf "$cache" && mkdir -p "$cache"
  xcrun actool packaging/AppIcon.icon --compile "$cache" --app-icon AppIcon \
    --platform macosx --target-device mac --minimum-deployment-target 14.0 \
    --output-partial-info-plist "$cache/partial.plist" >/dev/null
fi
cp "$cache/Assets.car" "$cache/AppIcon.icns" "$dest/"
