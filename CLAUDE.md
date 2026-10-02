# Project notes for AI assistants

Omarchy shell plugin `omnidisplay`: every display setting in one bar widget
that replaces the built-in Display widget. README.md is the user-facing
description; docs/ARCHITECTURE.md explains the pieces.

## Conventions

- English everywhere: code, comments, docs, commits.
- Logic that can be tested lives in `lib/*.js` as plain functions with
  `.pragma library` and `.import` lines and no export block;
  `tests/load.js` loads them in Node. Cover new logic in `tests/lib.test.js`.
- Everything that changes the system goes through `bin/omnidisplay-ctl`,
  which validates every argument itself. Payloads go on stdin. Cover it in
  `tests/ctl.test.sh` (stub hyprctl, temp HOME).
- State and actions live in `Service.qml` (one instance). `Panel.qml` and
  `views/` only render and call service functions: the bar builds a widget
  per monitor.
- QML follows Omarchy's first-party panels: `qs.Ui` components, `Style` and
  `Color` tokens, no hard-coded colours. Avoid property names that clash with
  QML (`state`) or generated signals (`<prop>Changed`).
- Never edit `/usr/share/omarchy/`; read it for reference.

## Hyprland facts relied on

- The Lua config rejects `hyprctl keyword`; use `hyprctl eval '<lua>'`
  (exit 7 and an `error:` line on failure).
- `hl.monitor({ output, … })` merges into the existing rule; `disabled = false`
  turns a display back on live.
- `hyprctl reload` re-applies `monitors.lua` (and drops eval'd rules);
  Hyprland reloads by itself when `monitors.lua` is saved.
- Omarchy's toggles (`~/.local/state/omarchy/toggles/hypr`) load after
  `monitors.lua`, so the internal-monitor toggles win over the block.
- `/usr/share/hypr/stubs/hl.meta.lua` lists the `hl.monitor` fields.

## Workflow

- `scripts/check.sh` before every commit.
- `scripts/dev-sync.sh` copies into `~/.config/omarchy/plugins/omnidisplay`
  and restarts the shell (the keepLoaded service reloads only then).
- `bash tests/live.sh [--restart]` runs the engine against the session on a
  virtual output and restores everything; run it after engine changes.
- Test by hand on a virtual output too, never the real screen:
  `bin/omnidisplay-ctl headless create OMNI-T1 1280x720@60`, then
  `omarchy-shell omnidisplay scale OMNI-T1 2`, then keep or revert;
  `bin/omnidisplay-ctl headless remove OMNI-T1` afterwards.
- Shell log: `/run/user/$UID/quickshell/by-id/*/log.log`.

## Marketplace

- Listing goes through an issue in `omacom/omarchy-plugin-marketplace`.
  The plugin id `omnidisplay` is permanent once listed.
- Its static scan flags privilege escalation, system service management,
  bundled binaries, installers and download-to-shell, even when only
  mentioned in docs or CI. Keep all of them out of the repository.
- Must pass `omarchy plugin validate`: no symlinks, relative entry points.
