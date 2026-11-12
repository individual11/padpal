#!/bin/zsh
# Turns one of the logo SVGs into design/AppIcon.icns, which build.sh puts in the app.
# usage: design/make-icon.sh design/logos/06-rim-light.svg
set -euo pipefail
SVG="$1"
OUT="$(dirname "$0")/AppIcon.icns"
SET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$SET"
for size in 16 32 128 256 512; do
    sips -s format png -z $size $size "$SVG" --out "$SET/icon_${size}x${size}.png" >/dev/null
    sips -s format png -z $((size * 2)) $((size * 2)) "$SVG" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$OUT"
echo "Wrote $OUT from $SVG"
