#!/bin/bash
# Copies this working copy into ~/.config/omarchy/plugins/omnidisplay and
# restarts the shell (plugin hot-reload can serve stale QML, and the
# keepLoaded service only reloads on a restart).
#   scripts/dev-sync.sh            copy and restart
#   scripts/dev-sync.sh --enable   also enable the plugin

set -euo pipefail
cd "$(dirname "$0")/.."
target="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/omnidisplay"
mkdir -p "$target"
rsync -a --delete \
  --exclude .git --exclude tests --exclude scripts --exclude .github --exclude docs \
  ./ "$target/"
echo "synced to $target"
if [[ ${1:-} == --enable ]]; then
  omarchy plugin enable omnidisplay
fi
omarchy restart shell >/dev/null 2>&1 || omarchy-restart-shell
