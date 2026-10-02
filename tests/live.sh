#!/bin/bash
# Live tests against the running Hyprland session and the installed plugin.
# Run with: bash tests/live.sh [--restart]
#
# Only a virtual output (OMNI-T1) is ever changed; the real displays are not
# touched. monitors.lua and profiles.json are copied first and put back at
# the end, checked byte for byte. --restart also restarts the shell mid-
# countdown to prove the detached watchdog reverts without it (the bar
# blinks once).
#
# Needs: a graphical Omarchy session with OmniDisplay enabled and synced
# (scripts/dev-sync.sh), and nothing waiting to be kept.

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CTL="$ROOT/bin/omnidisplay-ctl"
OUT=OMNI-T1
LUA="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/monitors.lua"
STORE="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/omnidisplay/profiles.json"
SAVE=$(mktemp -d)
pass=0
fail=0

ok() { pass=$((pass + 1)); echo "  ok   $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL $1"; [[ -n ${2:-} ]] && echo "       $2"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

# The shell builds a whole bar for a new output, which keeps it busy for a
# few seconds; a call that times out may still run later, so wait instead.
export OMARCHY_SHELL_IPC_TIMEOUT=10s
ipc() { omarchy-shell omnidisplay "$@"; }
settle() { # until the shell answers quickly again
  local i=0 t
  while (( i < 30 )); do
    t=$(date +%s%N); ipc state >/dev/null 2>&1
    (( ($(date +%s%N) - t) / 1000000 < 400 )) && return 0
    sleep 0.5; i=$((i + 1))
  done
}
live() { hyprctl monitors -j | jq -c --arg n "$OUT" '.[] | select(.name == $n) | {scale, transform, x, y}'; }
field() { hyprctl monitors -j | jq -r --arg n "$OUT" --arg f "$1" '.[] | select(.name == $n) | .[$f]'; }
pending() { ipc state | jq -r .pending; }
wait_for() { # wait_for <seconds> <condition>
  local i=0 limit=$(( $1 * 5 ))
  while (( i < limit )); do eval "$2" && return 0; sleep 0.2; i=$((i + 1)); done
  return 1
}

cleanup() {
  # Never leave the desktop without its shell.
  if ! omarchy-shell shell ping >/dev/null 2>&1; then
    echo "  (the shell was not answering; restarting it)"
    omarchy restart shell >/dev/null 2>&1
    sleep 4
  fi
  [[ $(pending 2>/dev/null) == confirm ]] && ipc revert >/dev/null 2>&1 && sleep 2
  "$CTL" headless remove "$OUT" >/dev/null 2>&1
  if [[ -f $SAVE/monitors.lua ]]; then
    cmp -s "$SAVE/monitors.lua" "$LUA" || cp -p "$SAVE/monitors.lua" "$LUA"
  fi
  if [[ -f $SAVE/profiles.json ]]; then
    cmp -s "$SAVE/profiles.json" "$STORE" || cp -p "$SAVE/profiles.json" "$STORE"
  elif [[ -f $SAVE/no-store ]]; then
    rm -f "$STORE"
  fi
  local f
  for f in "$(dirname "$LUA")"/monitors.lua.omnidisplay.*; do
    [[ -e $f && ${f##*.} =~ ^[0-9]+$ && ${f##*.} -ge $STARTED ]] && rm -f -- "$f"
  done
  rm -rf "$SAVE"
  # The run's notes ("Kept and saved…") no longer describe the files.
  ipc clearMessages >/dev/null 2>&1
}
trap cleanup EXIT

echo "preflight"
settle
ipc state >/dev/null 2>&1 || { echo "OmniDisplay is not running in omarchy-shell"; exit 2; }
[[ $(pending) == "" ]] || { echo "a change is waiting to be kept or reverted; finish it first"; exit 2; }
touch "$SAVE/stamp"
STARTED=$(date +%s)
cp -p "$LUA" "$SAVE/monitors.lua" 2>/dev/null
if [[ -f $STORE ]]; then cp -p "$STORE" "$SAVE/profiles.json"; else touch "$SAVE/no-store"; fi
"$CTL" headless create "$OUT" 1280x720@60 >/dev/null || { echo "could not create $OUT"; exit 2; }
hyprctl eval "hl.monitor({ output = \"$OUT\", mode = \"1280x720@60\", position = \"auto-right\", scale = 1, transform = 0, mirror = \"\", disabled = false })" >/dev/null
settle
wait_for 5 '[[ $(ipc state | jq --arg n "$OUT" "[.displays[] | select(.name == \$n)] | length") == 1 ]]'
check "the service sees the virtual output" '[[ $(field scale) == 1 ]]'
before=$(live)

echo
echo "revert when nobody keeps"
check "scale is accepted" '[[ $(ipc scale "$OUT" 2) == applying ]]'
check "and waits for Keep" 'wait_for 5 "[[ \$(pending) == confirm ]]"'
check "the change is live" '[[ $(field scale) == 2 ]]'
check "it reverts on its own" 'wait_for 25 "[[ \$(pending) == \"\" ]]"'
sleep 1.5
check "exactly to what it was" '[[ $(live) == "$before" ]]' "got $(live), wanted $before"
check "and the watchdog is disarmed" '[[ $("$CTL" armed) == 0 ]]'

echo
echo "revert on request"
ipc rotate "$OUT" 1 >/dev/null
wait_for 5 '[[ $(pending) == confirm ]]'
check "rotation is live" '[[ $(field transform) == 1 ]]'
ipc revert >/dev/null
check "Revert puts it back" 'wait_for 5 "[[ \$(pending) == \"\" ]]" && wait_for 4 "[[ \$(live) == \"\$before\" ]]"' "got $(live)"

echo
echo "mirror and back"
ipc mirror "$OUT" eDP-1 >/dev/null
wait_for 6 '[[ $(pending) == confirm ]]'
check "mirroring goes live" '[[ $(hyprctl monitors all -j | jq -r --arg n "$OUT" ".[] | select(.name == \$n) | .mirrorOf") != none ]]'
ipc keep >/dev/null
wait_for 10 '[[ $(pending) == "" ]]'
ipc mirror "$OUT" "" >/dev/null
wait_for 6 '[[ $(pending) == confirm ]]'
check "and extending again clears it" 'wait_for 4 "[[ \$(hyprctl monitors all -j | jq -r --arg n \"\$OUT\" \".[] | select(.name == \\\$n) | .mirrorOf\") == none ]]"'
ipc keep >/dev/null
wait_for 10 '[[ $(pending) == "" ]]'
cp -p "$SAVE/monitors.lua" "$LUA" 2>/dev/null
sleep 1.5
hyprctl eval "hl.monitor({ output = \"$OUT\", mode = \"1280x720@60\", position = \"auto-right\", scale = 1, transform = 0, mirror = \"\", disabled = false })" >/dev/null
sleep 1
before=$(live)

echo
echo "refused changes"
check "a mode the display does not offer is refused before anything runs" '[[ $(ipc setMode "$OUT" 1234x567@60) == refused ]]' "$(ipc messages)"
check "nothing is pending after a refusal" '[[ $(pending) == "" ]]'

echo
echo "workspace planner"
plan=$(ipc workspaces interleaved 4)
check "interleaved deals workspaces out in turn" '[[ $plan == *"$OUT: 2,4"* ]]' "$plan"
check "off writes no rules" '[[ $(ipc workspaces off 0) == "no rules" ]]'
ipc resetDraft >/dev/null

echo
echo "global option"
tearing=$(hyprctl getoption general:allow_tearing -j | jq .bool)
flip=$([[ $tearing == true ]] && echo false || echo true)
ipc option general.allow_tearing "$flip" >/dev/null
wait_for 5 '[[ $(pending) == confirm ]]'
check "the option goes live" '[[ $(hyprctl getoption general:allow_tearing -j | jq .bool) == "$flip" ]]' "pending=$(pending) $(ipc messages)"
ipc revert >/dev/null
wait_for 5 '[[ $(pending) == "" ]]'
sleep 1
check "and comes back on revert" '[[ $(hyprctl getoption general:allow_tearing -j | jq .bool) == "$tearing" ]]'

if [[ ${1:-} == --restart ]]; then
  echo
  echo "watchdog without the shell"
  ipc scale "$OUT" 2 >/dev/null
  wait_for 5 '[[ $(pending) == confirm ]]'
  omarchy restart shell >/dev/null 2>&1
  check "the shell is gone but the watchdog is armed" '[[ $("$CTL" armed) == 1 ]]'
  check "it reverts by itself" 'wait_for 30 "[[ \$(\"\$CTL\" armed) == 0 ]]" && wait_for 4 "[[ \$(field scale) == 1 ]]"' "armed=$("$CTL" armed) scale=$(field scale)"
  wait_for 20 'ipc state >/dev/null 2>&1'
  settle
fi

echo
echo "keep"
backups_before=$("$CTL" backups list | wc -l)
ipc scale "$OUT" 2 >/dev/null
wait_for 5 '[[ $(pending) == confirm ]]'
ipc keep >/dev/null
check "Keep finishes" 'wait_for 10 "[[ \$(pending) == \"\" ]]"'
check "the block is written" 'grep -qF "output = \"$OUT\"" "$LUA" && grep -qx -- "-- omnidisplay: end" "$LUA"'
check "after a backup" '[[ $("$CTL" backups list | wc -l) -gt $backups_before || $backups_before -ge 10 ]]'
check "the profile is saved" 'wait_for 5 "jq -e --arg n \"\$OUT\" \"any(.profiles[]; .displays | index(\\\$n))\" \"\$STORE\" >/dev/null 2>&1"'
sleep 2
check "Hyprland's reload keeps it" '[[ $(field scale) == 2 ]]'
check "the profile is active" '[[ -n $(ipc state | jq -r .profile) ]]'

echo
echo "restore after hotplug"
hyprctl eval "hl.monitor({ output = \"$OUT\", scale = 1 })" >/dev/null
"$CTL" headless remove "$OUT" >/dev/null
sleep 1
"$CTL" headless create "$OUT" 1280x720@60 >/dev/null
settle
check "the kept profile comes back on reconnect" 'wait_for 8 "[[ \$(field scale) == 2 ]]"'

echo
echo "$pass passed, $fail failed"
(( fail == 0 ))
