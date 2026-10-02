#!/bin/bash
# Tests for bin/omnidisplay-ctl. Run with: bash tests/ctl.test.sh
#
# Never talks to Hyprland: hyprctl is a stub that records its arguments, and
# HOME and XDG_RUNTIME_DIR are temp folders, so nothing outside them is read
# or written. The watchdog tests wait for real seconds (the minimum is 3).

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CTL="$ROOT/bin/omnidisplay-ctl"
WORK=$(mktemp -d)
trap 'pkill -f "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

export HOME="$WORK/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_RUNTIME_DIR="$WORK/run"
mkdir -p "$HOME/.config/hypr" "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
LOG="$WORK/hyprctl.log"
export OMNIDISPLAY_HYPRCTL="$WORK/hyprctl"
cat >"$OMNIDISPLAY_HYPRCTL" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$LOG"
case "\$1" in
  monitors) cat "$ROOT/tests/fixtures/monitors-desk.json" ;;
  workspaces) echo '[{"id":1,"monitor":"eDP-1"}]' ;;
  getoption) echo '{"option": "x", "int": 1, "set": true }' ;;
  clients) echo '[{"address":"0xabc123","class":"zen","title":"t","workspace":{"id":2},"monitor":0,"fullscreen":0,"mapped":true}]' ;;
  eval) if [[ \$2 == *FAILME* ]]; then echo "error: hl.monitor: unknown field 'FAILME'"; exit 7; fi; echo ok ;;
  *) echo ok ;;
esac
EOF
chmod +x "$OMNIDISPLAY_HYPRCTL"
# Notifications from the watchdog are not part of the test.
mkdir -p "$WORK/bin"
printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/notify-send"
chmod +x "$WORK/bin/notify-send"
export PATH="$WORK/bin:$PATH"

LUA_FILE="$HOME/.config/hypr/monitors.lua"
RULE='hl.monitor({ output = "DP-2", mode = "2560x1440@59.95", position = "0x0", scale = 1, transform = 0, disabled = false })'
REVERT='hl.monitor({ output = "DP-2", mode = "2560x1440@59.95", position = "1920x0", scale = 1, transform = 0, disabled = false })'

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "  ok   $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL $1"; [[ -n ${2:-} ]] && echo "       $2"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

payload() {
  jq -cn --arg apply "$1" --arg revert "$2" --argjson commands "${3:-[]}" --argjson revertCommands "${4:-[]}" \
    '{apply: $apply, revert: $revert, commands: $commands, revertCommands: $revertCommands, moves: [{workspace: 2, name: "DP-2"}, {workspace: "1; rm", name: "x"}]}'
}

reset_log() { : >"$LOG"; }

echo "snapshot"
printf 'local x = 1\n' >"$LUA_FILE"
out=$("$CTL" snapshot)
IFS=$'\036' read -r -d '' monitors workspaces file <<<"$out"
check "monitors JSON comes first" '[[ $(jq length <<<"$monitors") == 3 ]]'
check "then workspaces" '[[ $(jq -r ".[0].monitor" <<<"$workspaces") == eDP-1 ]]'
check "then status, sha and the file" '[[ $(sed -n 1p <<<"$file") == present && $(sed -n 2p <<<"$file") == "$(sha256sum "$LUA_FILE" | cut -d" " -f1)" && $(sed -n 3p <<<"$file") == "local x = 1" ]]'
rm -f "$LUA_FILE"
check "a missing file says so" '[[ $("$CTL" snapshot | tr "\036" "\n" | tail -n 2 | head -n1) == missing ]]'

echo
echo "apply"
reset_log
out=$(payload 'os.execute("x")' "$REVERT" | "$CTL" apply t1 5 2>&1)
check "refuses Lua that is not a plain rule" '[[ $out == *refusing* ]] && ! grep -q eval "$LOG"'
out=$(payload "$RULE" "$REVERT" '[["rm","-rf","/"]]' | "$CTL" apply t1 5 2>&1)
check "refuses commands outside Omarchy's toggles" '[[ $out == *"refusing command"* ]]'
out=$(payload "$RULE" "$REVERT" | "$CTL" apply t1 bogus 2>&1)
check "refuses a bad countdown" '[[ $out == *usage* ]]'

reset_log
out=$(payload "$RULE" "$REVERT" | "$CTL" apply t2 3)
check "applies with eval and reports exit 0" '[[ $out == *"__omnidisplay_exit=0"* ]] && grep -qF "eval $RULE" "$LOG"'
check "runs only valid workspace moves" 'grep -qF "workspace = \"2\", monitor = \"DP-2\"" "$LOG" && ! grep -qF "1; rm" "$LOG"'
check "the watchdog is armed" '[[ $("$CTL" armed) == 1 ]]'
out=$(payload "$RULE" "$REVERT" | "$CTL" apply t3 3 2>&1)
check "a second apply waits for the first" '[[ $out == *"still waiting"* ]]'
sleep 4
check "the watchdog reverts with a reload when nobody keeps" 'grep -qx reload "$LOG"'
check "and disarms" '[[ $("$CTL" armed) == 0 ]]'

reset_log
out=$(payload 'hl.monitor({ output = "DP-2", FAILME = 1 })' "$REVERT" | "$CTL" apply t4 3)
check "a refused eval reverts at once and reports its code" '[[ $out == *"__omnidisplay_exit=7"* && $out == *reverted* ]]'
sleep 0.5
check "and stands its watchdog down" '[[ $("$CTL" armed) == 0 ]]'

echo
echo "keep"
printf 'local x = 1\n' >"$LUA_FILE"
sha=$(sha256sum "$LUA_FILE" | cut -d' ' -f1)
reset_log
payload "$RULE" "$REVERT" | "$CTL" apply t5 3 >/dev/null
out=$(printf 'local x = 1\n\n-- omnidisplay: begin\n%s\n-- omnidisplay: end\n' "$RULE" | "$CTL" keep t5 "$sha" 3)
check "keep saves the file" '[[ $out == *"__omnidisplay_exit=0"* ]] && grep -qF "$RULE" "$LUA_FILE"'
check "after a backup of the old one" '[[ $(cat "$HOME"/.config/hypr/monitors.lua.omnidisplay.* | head -n1) == "local x = 1" ]]'
sleep 4
check "and the watchdog does not revert" '! grep -qx reload "$LOG"'

payload "$RULE" "$REVERT" | "$CTL" apply t6 3 >/dev/null
out=$(printf 'local y = 2\n' | "$CTL" keep t6 "$sha" 3)
check "keep refuses a file that changed since it was read" '[[ $out == *"__omnidisplay_exit=4"* ]] && ! grep -q "local y" "$LUA_FILE"'
out=$(printf 'this is not lua (\n' | "$CTL" keep t6 "$(sha256sum "$LUA_FILE" | cut -d" " -f1)" 3)
if command -v luac >/dev/null 2>&1; then
  check "keep refuses a file that does not parse" '[[ $out == *"__omnidisplay_exit=5"* ]] && grep -qF "$RULE" "$LUA_FILE"'
fi
"$CTL" revert t6 >/dev/null
sleep 0.3

ln -sf /etc/hostname "$WORK/link.lua"
mv "$LUA_FILE" "$WORK/real.lua"
ln -s "$WORK/link.lua" "$LUA_FILE"
payload "$RULE" "$REVERT" | "$CTL" apply t7 3 >/dev/null
out=$(printf 'local z = 3\n' | "$CTL" keep t7 - 3)
check "keep will not write through a link to a file it does not own" '[[ $out == *"__omnidisplay_exit=6"* ]]'
"$CTL" revert t7 >/dev/null
sleep 0.5
rm -f "$LUA_FILE"
mv "$WORK/real.lua" "$LUA_FILE"

echo
echo "revert"
reset_log
payload "$RULE" "$REVERT" '[["omarchy-hyprland-monitor-internal","off"]]' '[["omarchy-hyprland-monitor-internal","on"]]' | "$CTL" apply t8 10 >/dev/null
out=$("$CTL" revert t8)
check "revert reloads, then restores the snapshot" '[[ $out == *reverted* ]] && grep -qx reload "$LOG" && grep -qF "eval $REVERT" "$LOG"'
sleep 0.5
check "and the watchdog stands down" '[[ $("$CTL" armed) == 0 ]]'

reset_log
jq -cn --arg apply "$RULE" --arg revert "$REVERT" \
  '{apply: $apply, revert: $revert, expect: [{name: "DP-2", width: 2560, height: 1440, scale: 1, transform: 0, x: 1920, y: 0}]}' |
  "$CTL" apply ex1 10 >/dev/null
out=$("$CTL" revert ex1)
check "a revert that lands applies the snapshot once" '[[ $out == *reverted* && $(grep -c "^eval $REVERT" "$LOG") == 1 ]]'
sleep 0.5
reset_log
jq -cn --arg apply "$RULE" --arg revert "$REVERT" \
  '{apply: $apply, revert: $revert, expect: [{name: "DP-2", width: 2560, height: 1440, scale: 1, transform: 0, x: 0, y: 0}]}' |
  "$CTL" apply ex2 10 >/dev/null
out=$("$CTL" revert ex2)
check "a revert that does not land is retried, then reported" '[[ $(grep -c "^eval $REVERT" "$LOG") == 3 && $out == *"did not settle"* ]]'
sleep 0.5

echo
echo "backups"
for i in 1 2 3 4; do
  sha=$(sha256sum "$LUA_FILE" | cut -d' ' -f1)
  payload "$RULE" "$REVERT" | "$CTL" apply "b$i" 3 >/dev/null
  printf 'local v = %s\n' "$i" | "$CTL" keep "b$i" "$sha" 2 >/dev/null
  sleep 1.1
done
check "keeps only the newest N" '[[ $("$CTL" backups list | wc -l) == 2 ]]'
stamp=$("$CTL" backups list | tail -n1 | cut -f1)
check "show prints a backup" '[[ $("$CTL" backups show "$stamp") == "local v = 2" ]]'
"$CTL" backups restore "$stamp" >/dev/null
check "restore puts it back and reloads" '[[ $(cat "$LUA_FILE") == "local v = 2" ]] && grep -qx reload "$LOG"'
check "show refuses a path" '! "$CTL" backups show "../../etc/passwd" >/dev/null 2>&1'

echo
echo "others"
check "headless only touches OMNI- outputs" '! "$CTL" headless remove eDP-1 >/dev/null 2>&1'
check "headless validates the mode" '! "$CTL" headless create OMNI-1 "1920x1080@60;x" >/dev/null 2>&1'
reset_log
check "eval-rules applies without a watchdog" '[[ $(printf "%s" "$RULE" | "$CTL" eval-rules) == *"exit=0"* && $("$CTL" armed) == 0 ]]'
check "eval-rules refuses other Lua" '! printf "hl.dsp.exec_cmd(\"x\")" | "$CTL" eval-rules >/dev/null 2>&1'
check "edid refuses a path" '! "$CTL" edid "../x" >/dev/null 2>&1'
check "night refuses a silly temperature" '! "$CTL" night temperature 99 >/dev/null 2>&1'
check "terminal-font refuses an unknown terminal" '! "$CTL" terminal-font set xterm 11 >/dev/null 2>&1'
mkdir -p "$HOME/.config/kitty"
printf 'font_family JetBrains\nfont_size 9.0\n' >"$HOME/.config/kitty/kitty.conf"
"$CTL" terminal-font set kitty 12 >/dev/null
check "terminal-font changes only the size line" '[[ $(cat "$HOME/.config/kitty/kitty.conf") == $'"'"'font_family JetBrains\nfont_size 12'"'"' ]]'
check "and lists it" '[[ $("$CTL" terminal-font list | jq -r ".[0].size") == 12 ]]'
check "report removes serials" '! "$CTL" report | grep -q TESTDELL01'

check "options reads the four globals" '[[ $("$CTL" options | jq "keys | length") == 4 ]]'
check "eval-rules takes a known global option" '[[ $(printf "hl.config({ general = { allow_tearing = true } })" | "$CTL" eval-rules) == *exit=0* ]]'
check "eval-rules refuses any other hl.config" '! printf "hl.config({ misc = { disable_splash = true } })" | "$CTL" eval-rules >/dev/null 2>&1'
reset_log
jq -cn --arg apply "$RULE" --arg revert "$REVERT" '{apply: $apply, revert: $revert, reloadFirst: true}' | "$CTL" apply rf1 3 >/dev/null
check "reloadFirst reloads before the rules" '[[ $(grep -nx reload "$LOG" | head -1 | cut -d: -f1) -lt $(grep -n "^eval" "$LOG" | head -1 | cut -d: -f1) ]]'
"$CTL" revert rf1 >/dev/null
sleep 0.5
check "windows lists clients" '[[ $("$CTL" windows | jq -r ".[0].address") == 0xabc123 ]]'
reset_log
"$CTL" send-window 0xabc123 7 >/dev/null
check "send-window moves, then makes it fullscreen" 'grep -qF "workspace = \"7\", window = \"address:0xabc123\"" "$LOG" && grep -q "window.fullscreen" "$LOG"'
check "send-window refuses a bad address" '! "$CTL" send-window "0xabc; rm" 7 >/dev/null 2>&1'
check "resend-hdr refuses other presets" '! "$CTL" resend-hdr DP-2 srgb >/dev/null 2>&1'
check "store-write saves a profiles store" '[[ $(printf "{\"version\":1,\"profiles\":[]}" | "$CTL" store-write) == *exit=0* && -f "$HOME/.config/omarchy/omnidisplay/profiles.json" ]]'
check "store-write refuses anything else" '! printf "[1,2]" | "$CTL" store-write >/dev/null 2>&1'

echo
echo "$pass passed, $fail failed"
(( fail == 0 ))
