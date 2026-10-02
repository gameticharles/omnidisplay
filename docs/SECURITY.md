# OmniDisplay — Security

OmniDisplay runs inside `omarchy-shell` as the logged-in user, like every
shell plugin. It needs no elevated privileges, installs nothing, starts no
system service and opens no network connection of its own.

## What it runs

| Program | When |
|---|---|
| `hyprctl monitors/workspaces -j` | Reading state |
| `hyprctl eval` | Applying and reverting (`hl.monitor` and `hl.workspace_rule` lines only) |
| `hyprctl reload`, `hyprctl dispatch hl.dsp.workspace.move` | Reverting, moving workspaces |
| `hyprctl output create/remove headless OMNI-…` | Virtual displays (only `OMNI-` names) |
| `omarchy-brightness-display`, `omarchy-display-text-size`, `omarchy-hyprland-monitor-internal(-mirror)`, `omarchy-toggle-idle`, `omarchy-shell notifications` | Omarchy's own commands |
| `edid-decode`, `ddcutil`, `hyprsunset`, `wayvnc`, `qrencode`, `openssl`, `waycast`, `doubletake` | Optional features |

## Files it writes

- `~/.config/hypr/monitors.lua`: only on Keep or cleanup, only the managed
  block (plus removing rules you chose to fold in), after a backup. Refused
  when the file changed since it was read, when it is over 120 KiB, when the
  new text does not parse, or when it is a symlink to anything but a regular
  `.lua` file you own. Written to a private temp file and renamed.
- `~/.config/omarchy/omnidisplay/profiles.json`: only valid JSON with a
  `profiles` array.
- Terminal configs, only when you change a per-terminal font size: one size
  line, with a `.omnidisplay.bak` copy first.
- `$XDG_RUNTIME_DIR/omnidisplay/`: token files (mode 700 folder, refused if
  it is a symlink or not yours; files created under a random name and
  renamed into place).

## Input validation

Every value is checked in `bin/omnidisplay-ctl` whatever the panel already
checked: connector names `[A-Za-z0-9._-]`, modes `WxH@R`, integers, tokens,
backup stamps, DDC VCP codes from a fixed list, terminals from a fixed list,
temperatures in range.

Lua handed to `hyprctl eval` must be plain `hl.monitor({ … })` and
`hl.workspace_rule({ … })` lines. With every string literal blanked first, a
line mentioning `os`, `io`, `require`, `load`, `dofile`, `package`, `debug`,
`exec_cmd` or `hl.dsp` is refused, so a display description cannot smuggle a
call. Descriptions are quoted with control characters refused and quotes
and backslashes escaped. The same checks run in `lib/Lua.js` before a plan
is offered.

Payloads (Lua, file contents, profiles, PINs) travel on stdin, never in argv,
which is size-limited and readable by every local user through `ps`.

QML starts processes with argument arrays, never `bash -c` with
interpolated text.

## Casting and VNC

- AirPlay PINs and passwords go over stdin to the cast script and from there
  to doubletake's socket (as in Wireless Display).
- VNC listens on 127.0.0.1 unless network access is chosen; network access
  always uses TLS (a self-signed certificate) and a generated 16-character
  password, stored owner-only in `~/.config/omarchy/omnidisplay/vnc/`. The
  QR code carries the address only.
- OmniDisplay never changes the firewall; the Cast tab says which port to
  allow.
