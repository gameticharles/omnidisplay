#!/usr/bin/env bash
# Renders preview.png (the marketplace image) from docs/preview/preview.html.
# Refresh the three screenshots first: open each tab with
# `omarchy-shell omnidisplay show <tab>` and grab the 600 px panel with grim.
set -euo pipefail
cd "$(dirname "$0")/../docs/preview"
out=$(mktemp --suffix=.png)
chromium --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
  --window-size=2000,1400 --screenshot="$out" "file://$PWD/preview.html" 2>/dev/null
magick "$out" -strip -define png:compression-level=9 ../../preview.png
rm -f "$out"
echo "wrote preview.png"
