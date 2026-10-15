#!/usr/bin/env bash
# Build build/angl.app on the Mac: release arm64 binary, resources, bundled block
# lists, Developer ID signature with hardened runtime.
# Usage: scripts/bundle.sh [--install]   (--install copies to /Applications/angl.app)
# ANGL_SIGN_IDENTITY, ANGL_VERSION, ANGL_BUILD_NUMBER and ANGL_RELEASE (secure timestamp)
# are set by scripts/build-release.py for published builds.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin

identity="${ANGL_SIGN_IDENTITY:-Developer ID Application: Briggs Craig (7F3KV9WTNW)}"
version="${ANGL_VERSION:-$(tr -d '[:space:]' <VERSION)}"
build_number="${ANGL_BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"
app=build/angl.app

scripts/bitwarden.sh
swift build -c release --arch arm64 --product angl
swift build -c release --arch arm64 --product angl-lists
bin="$(swift build -c release --arch arm64 --show-bin-path)"

# Block lists: refresh the bundled snapshot at most once a day, or when the converter changed.
lists=Resources/lists
if [ ! -f "$lists/.stamp" ] || [ -n "$(find "$lists/.stamp" -mtime +0 2>/dev/null)" ] || [ "$bin/angl-lists" -nt "$lists/.stamp" ]; then
  fresh="$(mktemp -d)" && chmod 755 "$fresh"
  if "$bin/angl-lists" --out "$fresh"; then
    rm -rf "$lists" && mv "$fresh" "$lists" && touch "$lists/.stamp"
  else
    rm -rf "$fresh"
  fi
fi

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/angl" "$app/Contents/MacOS/angl"
sed -e "s/@VERSION@/$version/" -e "s/@BUILD@/$build_number/" packaging/Info.plist >"$app/Contents/Info.plist"
rsync -a --exclude .stamp --exclude .DS_Store Resources/ "$app/Contents/Resources/"
# SwiftPM resource bundles of dependencies (swift-psl's public suffix list, used by the blocker).
for b in "$bin"/*.bundle; do if [ -e "$b" ]; then rsync -a "$b" "$app/Contents/Resources/"; fi; done
scripts/icon.sh "$app/Contents/Resources"

scripts/sign.sh "$identity" "$app"
codesign --verify --strict "$app"
echo "built $app ($version, $build_number)"

if [ "${1:-}" = "--install" ]; then
  osascript -e 'tell application id "dev.btuckerc.angl" to quit' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x angl >/dev/null || break; sleep 0.5; done
  rm -rf /Applications/angl.app
  ditto "$app" /Applications/angl.app
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/angl.app
  echo "installed /Applications/angl.app"
fi
