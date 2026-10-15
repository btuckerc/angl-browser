#!/usr/bin/env bash
# Sign an app bundle with hardened runtime. Over SSH the login keychain is locked, so
# codesign runs as a one-shot launchd job in the user's GUI session, where it is unlocked.
# Usage: scripts/sign.sh IDENTITY APP   (ANGL_RELEASE=1 adds Apple's secure timestamp)
set -euo pipefail
identity="$1"
app="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
entitlements="$(cd "$(dirname "$0")/../packaging" && pwd)/angl.entitlements"
timestamp=--timestamp=none
if [ -n "${ANGL_RELEASE:-}" ]; then timestamp=--timestamp; fi
args=(/usr/bin/codesign --force "$timestamp" --options runtime --entitlements "$entitlements" --sign "$identity" "$app")

if [ -z "${SSH_CONNECTION:-}" ]; then
  "${args[@]}"
  exit 0
fi

label="dev.btuckerc.angl.sign.$$"
tmp="$(mktemp -d)"
plist="$tmp/$label.plist"
{
  echo '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>'
  echo "<key>Label</key><string>$label</string><key>ProgramArguments</key><array>"
  for a in "${args[@]}"; do printf '<string>%s</string>' "$(printf '%s' "$a" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g')"; done
  echo "</array><key>StandardOutPath</key><string>$tmp/log</string><key>StandardErrorPath</key><string>$tmp/log</string>"
  echo '<key>RunAtLoad</key><true/></dict></plist>'
} >"$plist"
launchctl bootstrap "gui/$(id -u)" "$plist"
for _ in $(seq 1 120); do
  launchctl print "gui/$(id -u)/$label" 2>/dev/null | grep -Eq 'last exit code = -?[0-9]' && break
  sleep 0.5
done
status="$(launchctl print "gui/$(id -u)/$label" 2>/dev/null | awk -F'= ' '/last exit code/ {print $2; exit}')"
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
cat "$tmp/log" 2>/dev/null || true
rm -rf "$tmp"
[ "$status" = "0" ] || { echo "codesign failed (exit ${status:-unknown})" >&2; exit 1; }
