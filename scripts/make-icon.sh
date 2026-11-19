#!/bin/bash
# Builds AppIcon.icns from the generated 1024px PNG using only tools in the Command Line Tools.
# Usage: scripts/make-icon.sh <output.icns>
set -euo pipefail
out="${1:?usage: make-icon.sh <output.icns>}"
here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
swift "$here/make-icon.swift" "$work/AppIcon-1024.png"
set_dir="$work/AppIcon.iconset"
mkdir "$set_dir"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" "$work/AppIcon-1024.png" --out "$set_dir/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z "$d" "$d" "$work/AppIcon-1024.png" --out "$set_dir/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$set_dir" -o "$out"
