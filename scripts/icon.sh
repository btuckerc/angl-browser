#!/usr/bin/env bash
# Compile packaging/AppIcon.icon (Icon Composer document) into DEST (an .app's
# Contents/Resources): Assets.car for macOS 26+ and AppIcon.icns for older systems. Its three
# layers are the chevrons of packaging/angl.svg redrawn bolder for icon sizes: on the 1024 canvas,
# 66-unit bands with 30-unit gaps (the previous icon had 38.5 and 22.4), corners rounded at r 8,
# 740 wide, centered horizontally and raised 38 units (halfway from box-centered to
# centroid-centered, so the triangle looks centered). Cached in build/icon until the script or the
# .icon bundle changes.
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
