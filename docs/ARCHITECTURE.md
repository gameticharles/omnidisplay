# OmniDisplay — Architecture

How the plugin is put together, as built. For the threat model see
[SECURITY.md](SECURITY.md); for the original plan and feature sources see
[PLAN.md](PLAN.md).

## Pieces

```
omarchy-shell (Quickshell)
  Service.qml          one instance (kind: service, keepLoaded)
    · live state: hyprctl monitors/workspaces, monitors.lua, profiles.json
    · the draft being edited and every edit function
    · apply → verify → keep / revert engine and its countdown
    · profile restore on monitoradded/removed and configreloaded
    · IPC targets "omnidisplay" and "omarchy.monitor"
    · overlays on every screen: KeepOverlay, IdentifyOverlay, ModeOsd
    · cast and VNC polling, DDC, EDID, brightness, night light
  Panel.qml            one per bar (kind: bar-widget, clonedFrom omarchy.monitor)
    · renders the service's state; views/*.qml are its six tabs
  components/Runner.qml
    · one Process per call: stdin payload, exit marker, then destroys itself

bin/omnidisplay-ctl    every change and file write, arguments validated
  └─ watchdog          detached (setsid) copy of itself that reverts on timeout
bin/omnidisplay-cast   Miracast (waycast) and AirPlay (doubletake), ported
bin/omnidisplay-vnc    headless output + wayvnc for tablets

lib/ (pure .pragma library JS, loaded by QML and by Node in tests/)
  Model.js     parse hyprctl JSON, modes, clean scales, PPI, EDID, insights
  Layout.js    geometry: snap, close gaps, reflow, place, staging, canvas fit
  Lua.js       rules, selectors, the managed block, eval safety, cleanup
  Profiles.js  store, matching, draft ↔ profile, laptop modes, workspaces
  Plan.js      buildPlan: validation, apply/revert Lua, block, preview, verify
  Cast.js      wireless state model
```

The bar builds a widget per monitor, so nothing that must exist once lives
in `Panel.qml`. Widgets find the service with `bar.shell.serviceFor("omnidisplay")`
and push their `shell.json` settings to it.

## An apply, step by step

1. The panel edits `service.draft` (a copy of the live displays). Every edit
   repositions the arranged displays with `Layout.reflow`, so neighbours
   stay attached.
2. `Plan.buildPlan` validates the draft and produces the live Lua (by
   connector, with staging moves first when a direct move would overlap),
   the revert Lua (the current session by connector), Omarchy toggle
   commands for laptop modes and their reverse, workspace moves, and the new
   `monitors.lua` (by panel selector).
3. Apply checks the plan at once, then reads the displays again and
   rebuilds the plan from that fresh state, so the revert snapshot is what
   is on screen at that moment.
4. `omnidisplay-ctl apply <token> <seconds>` reads the plan on stdin, refuses
   anything that is not a plain `hl.monitor`/`hl.workspace_rule` line or one
   of Omarchy's internal-monitor toggles, writes the revert to owner-only
   token files, starts the watchdog, waits until it is alive, and only then
   runs `hyprctl eval`. A failed eval reverts at once.
5. 900 ms later (2.2 s after a laptop-mode change) the service reads `hyprctl monitors` and compares it with the
   draft (`Plan.verifyApplied`). A refused or rounded setting reverts.
6. The countdown runs in the service and in the KeepOverlay on every screen.
   - **Keep**: `omnidisplay-ctl keep` checks the sha256 the file had when
     read, backs it up, writes the new text to a temp file, checks it with
     `luac -p`, renames it into place, then touches `<token>.keep`; the
     watchdog stands down. The profile is saved through `store-write`.
   - **Revert / timeout**: `omnidisplay-ctl revert` reads the token files
     into memory, touches `<token>.done` (the watchdog stands down), runs
     the toggle reverse, `hyprctl reload`, then the snapshot Lua, and repeats
     the snapshot (up to three times) until `hyprctl monitors` matches the
     expected state sent with the apply: Hyprland lands a reload's rules a
     moment after `reload` returns. The service re-reads and reports any
     difference.
   - A step that does not finish in 25 s releases the engine with a message.
   - **Shell gone**: the watchdog does the same revert after
     `confirmSeconds + 3` seconds and sends a notification.

## Profiles and hotplug

A profile is keyed by the sorted identities of the connected displays
(`Model.identityKeys`: the description when it is unique, else the
connector). On `monitoradded`, `monitorremoved` and `configreloaded`, after
a 450 ms settle, the service builds the profile's plan; when anything
differs it applies it with `eval-rules` (no countdown, no watchdog), runs
the laptop-mode toggles and moves workspaces. Two attempts per 30 s at most,
so a setting Hyprland keeps refusing cannot loop.

Requests Hyprland does not report back (adaptive sync, bit depth, colour
preset, SDR levels) live in the profile and are merged into the draft from
there; geometry always comes from the live state.

## The saved block

Rules for the displays connected now, rules for remembered monitors that are
not (mode, scale, rotation, automatic position), the global options, and
`Lua.profilesLua`: every profile as data plus a handler that picks the one
matching the connected displays (enabled ones from `hl.get_monitors()`, off
ones from sysfs by connector) at load and on `monitor.added`/`monitor.removed`,
and applies it only when the match changes. All of it runs under `pcall`.
`tests/lua-profiles.test.js` runs it in a real Lua with a fake `hl`.

## Other events

- **Resume**: `gdbus monitor` on logind's `PrepareForSleep`; on wake the
  profile is checked again and HDR panels get their metadata resent (sRGB
  and back).
- **Focus**: from `Hyprland.focusedMonitor`, no process.
- **Cast**: the cast state file is watched; `omnidisplay-cast state` runs
  every 5 s while casting or on the Cast tab, to reconcile AirPlay and
  notice dead sessions.

## Laptop modes

The built-in panel's on/off and mirroring belong to Omarchy's
`omarchy-hyprland-monitor-internal` and `-internal-mirror` toggles, because
its clamshell watcher reads them. OmniDisplay calls those and never writes
`disabled` for the internal panel; external displays are switched with
ordinary rules.

## Tests

- `tests/lib.test.js`: every lib module, against `hyprctl` captures and
  `edid-decode` output in `tests/fixtures/`.
- `tests/ctl.test.sh`: `omnidisplay-ctl` against a stub `hyprctl` in a
  temporary HOME, watchdog timing included.
- `tests/live.sh`: the engine against the running session on a virtual
  output, `monitors.lua` and the profiles restored byte for byte afterwards.
  22 checks; `--restart` includes the watchdog across a shell restart.
