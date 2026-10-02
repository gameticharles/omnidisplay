# OmniDisplay — Plan

Every display setting in one Omarchy bar widget: arrange, modes, scale,
rotation, mirroring, brightness, HDR and colour, profiles, workspaces,
wireless casting and tablet screens, with every change kept only after you
confirm it.

- **Plugin id:** `omnidisplay` (permanent once listed)
- **Name:** OmniDisplay · **Bar label:** Displays
- **Author:** Charles Gameti · **License:** MIT
- **Replaces:** Omarchy's built-in Display widget (`omarchy.clonedFrom: omarchy.monitor`),
  so it takes the bar slot and `SUPER + CTRL + D`. Disabling it brings the stock widget back.
- **Targets:** Omarchy Quattro (4.x), Hyprland 0.56+ with the Lua config, Quickshell.

---

## 1. Why another display plugin

Planned 2026-10-02 after reviewing the five display plugins installed on this
machine and the display plugins in the marketplace.

### 1.1 What is wrong with the installed ones

| Plugin                                           | Problems confirmed in its code                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| ------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `azterisk.display-manager` 1.2.0               | `scripts/omarchy-display-apply` **replaces all of `monitors.lua`** when no sentinel block exists yet. Forces `GDK_SCALE = 1` and `omarchy_monitor_scale = "auto"`. Live apply uses `hyprctl keyword`, which the Lua config rejects. Canvas models only primary/secondary. One `.bak`, overwritten every save. Layout JSON passed in argv. Ships `install.sh` and a PKGBUILD (flagged by the marketplace scan).                                                                                                            |
| `better.displays` 1.0.0                        | `persist_to_lua` appends loose `hl.monitor` lines outside any managed block (the stray `HDMI-A-1 … scale = 3` line in `monitors.lua` came from it). No confirm/revert, so a bad mode sticks. CLI reads `.modes`, but Hyprland emits `availableModes`, so the mode picker is always empty. `pick_scale` has a bash syntax error (`local presets="1" "1.25" …`). Monitors are keyed by connector, so settings are lost when a cable moves. Symlinks scripts into `~/.local/bin`. Edits terminal configs with blind `sed`. |
| `io.github.stevederico.omarchy-displays` 0.5.1 | Best safety design (detached watchdog, atomic write, rotated backups,`desc:` selectors). But it is a separate window, rotation is read-only, disabled/mirrored outputs cannot be edited, and it has no brightness, text size, mirroring or toggles.                                                                                                                                                                                                                                                                                         |
| `monitor-layout` 0.7.1                         | Hand-synced copy of the built-in panel. Never writes`monitors.lua`, so the layout is wrong at boot until the shell loads and flashes for ~300 ms after every reload. Stacked displays can only be centred. No colour, profiles or workspaces.                                                                                                                                                                                                                                                                                               |
| `omarchy-wireless-display` 1.1.0               | Solid, but casting only.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |

They also **fight each other**: `monitor-layout`'s service re-applies positions on
every `configreloaded`, while Azterisk and Better Displays rewrite
`monitors.lua` and reload. State is split across `monitors.lua`,
`displays.json`, `monitor-layout.json` and the backups.

### 1.2 What the marketplace competitors add

Vista (formerly Panorama), Better Displays Pro, hyprmoncfg/Display+, Display
Control, Display Toggle, Virtual Display, Tablet Display. Features they have
that none of the five installed plugins have: HDR/colour management,
auto-switching profiles, DDC/CI, EDID capabilities, native-mode insights,
workspace planning, virtual and VNC screens. Most of them need extra
daemons (hyprmoncfg) or are separate windows. **None does all of it in the
bar with no extra daemon.** That is the gap OmniDisplay fills.

---

## 2. Feature list

Legend: **Source** is where the idea comes from. **Ours** marks something no
reviewed plugin does.

### 2.1 Core (parity with the built-in Display widget, fixed)

| Feature                                | Source                          | Notes                                                                                                                                                                               |
| -------------------------------------- | ------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Brightness slider (internal backlight) | built-in                        | `omarchy-brightness-display --no-osd`, OSD on release                                                                                                                             |
| Text size stops                        | built-in                        | `omarchy-display-text-size`                                                                                                                                                       |
| Scale presets, only valid ones offered | built-in, Vista                 | 1/120-step whole-pixel check (`cleanScale`)                                                                                                                                       |
| Universal scale (all outputs at once)  | Display+                        | one action, confirm/revert like everything else                                                                                                                                     |
| Display on/off toggles                 | built-in, Display Toggle        | `hyprctl eval`, never `keyword` (omacom/omarchy#7036). **The last enabled display cannot be turned off.** Laptop panel goes through `omarchy-hyprland-monitor-internal` |
| Keyboard navigation everywhere         | built-in, monitor-layout, Vista | `h/j/k/l`, `Enter`, `Esc`, tab shortcuts `1`–`6`                                                                                                                         |

### 2.2 Arrange

| Feature                                                  | Source                                                      | Notes                                                                |
| -------------------------------------------------------- | ----------------------------------------------------------- | -------------------------------------------------------------------- |
| Drag-and-drop canvas,**any number** of displays    | Steve, monitor-layout, Azterisk                             | tiles at logical size (resolution ÷ scale, rotation-aware)          |
| Edge snapping, flush, no overlaps, no gaps               | Steve (`nearestSlot`, `closeGaps`, `MIN_SHARED_EDGE`) | snapping threshold in settings                                       |
| Above/below with**free offset** (not only centred) | monitor-layout (centred only)                               | **ours**: align start/centre/end or drag freely along the edge |
| Neighbours follow when a display changes size            | hyprmoncfg (`reflow`)                                     | change scale or mode and the displays beside it stay flush           |
| Place left of / right of / above / below another         | Steve, Better Displays                                      | buttons plus keyboard                                                |
| Snap presets: centre, align left, align bottom           | Azterisk                                                    |                                                                      |
| Move by keyboard, 100 px / 10 px fine                    | Vista, monitor-layout                                       | `Alt+arrows`, `Shift+Alt`                                        |
| Staging move so Hyprland never sees an overlap           | monitor-layout (`stagingX`)                               |                                                                      |
| Identify overlay: big number and name on each screen     | monitor-layout, hyprmoncfg                                  | also shown on open, if enabled in settings                           |
| Workspace chips drawn on tiles                           | hyprmoncfg                                                  |                                                                      |

### 2.3 Per-display inspector

| Feature                                                                                                          | Source                 |
| ---------------------------------------------------------------------------------------------------------------- | ---------------------- |
| Resolution and refresh rate from`availableModes`, plus `preferred`, `highres`, `highrr` and custom modes | all, Vista             |
| Scale (valid-only) with a**PPI-based suggestion**                                                          | Better Displays Pro    |
| Rotation**and flips** (all 8 transforms)                                                                   | Vista (others have 4)  |
| Mirror of another display, per display (mirror one, extend two)                                                  | Azterisk               |
| VRR: off / on / fullscreen only                                                                                  | monitor-layout, Vista  |
| Enabled switch on off/mirrored displays (they stay selectable)                                                   | hyprmoncfg             |
| Details: make, model, serial, port, physical size, diagonal, PPI                                                 | monitor-layout         |
| Copy any value on click                                                                                          | Storage Drives (yours) |

### 2.4 Quick modes (Win+P style)

| Feature                                                                                           | Source                              |
| ------------------------------------------------------------------------------------------------- | ----------------------------------- |
| Extend · Mirror · External only · Built-in only                                                | monitor-layout, Better Displays Pro |
| Laptop rule "with an external display" remembered, applied on every connect                       | monitor-layout (`withExternal`)   |
| **Cycle the modes from a keybinding with an OSD** (`omarchy-shell omnidisplay cycleMode`) | **ours**                      |
| Lid/clamshell aware: closing the lid with an external connected behaves like External only        | Vista, hyprmoncfg                   |

### 2.5 Safe apply (the engine everything goes through)

| Feature                                                                                                                              | Source                                                   |
| ------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------- |
| Live apply via`hyprctl eval`; nothing written until **Keep**                                                                 | Steve                                                    |
| Keep/Revert countdown (default 15 s, configurable)                                                                                   | Steve, monitor-layout                                    |
| **Detached watchdog** that reverts even if the shell or screen dies; owner-only token dir in `$XDG_RUNTIME_DIR/omnidisplay/` | Steve                                                    |
| Revert by`hyprctl reload`, fall back to `eval` of the snapshot; report a revert only after `hyprctl monitors` shows it         | Steve                                                    |
| Verify Hyprland actually took the change; a refused or rounded setting reverts at once with a message                                | monitor-layout, Steve                                    |
| Dry run plus exact Lua preview (apply / revert / save)                                                                               | Steve                                                    |
| **Emergency revert keybinding**: restores the last kept profile, or the last backup, without the panel                         | Better Displays Pro (idea),**ours** (bound to IPC) |
| One change in flight at a time; a second Apply waits for the watchdog                                                                | Steve                                                    |

### 2.6 Persistence

| Feature                                                                                                                                                             | Source                       |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------- |
| One managed block at the**end** of `monitors.lua`, one complete rule per line, `-- omnidisplay: begin/end`                                                | Steve, Vista                 |
| Displays matched by`desc:` (make/model/serial); identical twins fall back to connector                                                                            | Steve, monitor-layout        |
| Selectors already used in the user's own rules are reused; a configured`@60` kept on a 59.95 Hz panel                                                             | Steve                        |
| Rules for unplugged displays are kept; a display that is off is saved`disabled = true` with its settings                                                          | Vista                        |
| Everything outside the block kept byte for byte, including`GDK_SCALE`                                                                                             | Steve (Azterisk breaks this) |
| Timestamped backups, newest N kept; atomic temp-file rename; symlinked dotfile stays a symlink; refuse if the file changed since it was read                        | Steve                        |
| `luac -p` checks the new file before it replaces the old one                                                                                                      | Vista                        |
| **Backups browser**: list, diff and restore any backup from the panel                                                                                         | **ours**               |
| **First-run cleanup**: find loose `hl.monitor` lines and blocks left by other display plugins, show them, offer to fold them into our block (with a backup) | **ours**               |

### 2.7 Profiles (auto-switching)

| Feature                                                                                                                                                              | Source                                 |
| -------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------- |
| A profile per set of connected displays (home desk, office, projector)                                                                                               | Vista, hyprmoncfg, Better Displays Pro |
| Auto-apply on hotplug,`configreloaded`, lid and resume, after a 300 ms settle                                                                                      | monitor-layout (service), hyprmoncfg   |
| Same monitors on other ports or a dock still match                                                                                                                   | Better Displays Pro, monitor-layout    |
| New combination: start from the nearest known profile                                                                                                                | Better Displays Pro                    |
| Rename, duplicate, delete (with confirm), set default, try a profile with a preview countdown                                                                        | hyprmoncfg                             |
| Profile stores layout, modes, scale, transform, VRR, colour, mirror, enabled, workspace plan and laptop mode. Brightness stays live hardware state, not profile data | hyprmoncfg                             |
| Bounded retry with backoff on a failed auto-apply                                                                                                                    | hyprmoncfg                             |
| Store:`~/.config/omarchy/omnidisplay/profiles.json` (hand-editable; the service follows changes to it)                                                             |                                        |

### 2.8 Workspaces

| Feature                                                                       | Source               |
| ----------------------------------------------------------------------------- | -------------------- |
| Planner: sequential, interleaved (odd/even), manual or off                    | hyprmoncfg, Azterisk |
| Set the workspace count and grouping; move single workspaces between displays | hyprmoncfg           |
| "Workspace 1 lives here" / swap primary role                                  | Azterisk             |
| Off when another tool (hyprsplit) manages workspaces                          | hyprmoncfg           |
| Written as a separate marked block of workspace rules, saved with the profile | Display Layout       |

### 2.9 Colour and HDR

| Feature                                                                                                        | Source                          |
| -------------------------------------------------------------------------------------------------------------- | ------------------------------- |
| Colour-management presets (`srgb`, `wide`, `hdr`, `hdredid`, …), live from `colorManagementPreset`  | Vista, hyprmoncfg               |
| 8 / 10-bit depth (`currentFormat`)                                                                           | Vista, hyprmoncfg               |
| SDR brightness, saturation, black/white levels; luminance overrides                                            | hyprmoncfg                      |
| EDID capabilities via`edid-decode`: HDR metadata, peak luminance, VRR range; hide settings a panel cannot do | Vista                           |
| ICC profile path                                                                                               | hyprmoncfg                      |
| Night light quick toggle and temperature (`hyprsunset`, through Omarchy's own toggle)                        | **ours** (in this bundle) |

### 2.10 Hardware and health

| Feature                                                                                                                                        | Source                                |
| ---------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------- |
| External brightness, contrast and**input source** over DDC/CI (`ddcutil`, optional)                                                    | Vista                                 |
| One brightness row per display: backlight or DDC, chosen automatically                                                                         | hyprmoncfg                            |
| Native-mode insights: "not at native resolution", "a higher refresh rate is available", "limited by the connection", each with a one-click fix | Better Displays Pro                   |
| Copy a sanitized diagnostic report (serials removed)                                                                                           | Better Displays Pro, wireless-display |

### 2.11 Cast (wireless displays)

Ported from `omarchy-wireless-display` (MIT, attribution in NOTICE), as the Cast tab.

| Feature                                                                                                         | Source           |
| --------------------------------------------------------------------------------------------------------------- | ---------------- |
| Miracast via`waycast`, AirPlay via `doubletake`                                                             | wireless-display |
| Mirror or Extend switch per receiver; capability read from the running daemon                                   | wireless-display |
| PIN/password entry over stdin, never argv                                                                       | wireless-display |
| Bounded logs and event caps, process-group teardown                                                             | wireless-display |
| Missing backend shows a "copy install command" line                                                             | wireless-display |
| Animated bar glyph as a status light                                                                            | wireless-display |
| **A cast screen extended to the right appears on the Arrange canvas and can be dragged like any display** | **ours**   |

### 2.12 Tablet and virtual displays

| Feature                                                                                          | Source                                        |
| ------------------------------------------------------------------------------------------------ | --------------------------------------------- |
| Create a headless virtual output at a preset or custom resolution, placed left/right/above/below | Virtual Display                               |
| Serve it (or mirror the main screen) with`wayvnc`                                              | Virtual Display, Tablet Display               |
| Local-only by default; network access with TLS and a generated password                          | Virtual Display, Tablet Display               |
| QR code pairing (`qrencode`), password show/copy/regenerate                                    | Virtual Display (QR style shared with ReClip) |
| Resolution read from the tablet's browser                                                        | Tablet Display                                |
| Firewall: never changes ufw itself. Shows the exact command to copy (marketplace rule)           |                                               |

### 2.13 Our own extras

| Feature                               | What it does                                                                                                                                                                |
| ------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Presentation mode**           | When a projector or cast connects: mirror (or extend), turn Do Not Disturb on, block idle and lock, and restore everything on disconnect. Opt-in.                           |
| **Per-terminal font overrides** | Better Displays' idea, done safely: alacritty, kitty, ghostty and foot each get their own size on top of the global text size. Edits are anchored, backed up and validated. |
| **Bar label**                   | Icon only, display count, active profile name, or cast status.                                                                                                              |
| **Changelog toast**             | After an update, one line saying what changed.                                                                                                                              |

---

## 3. Architecture

House style follows Storage Drives and Aurora Pulse: pure logic in `.pragma library` JS with Node tests, thin QML, one validated control script, docs in
`docs/`.

```
omnidisplay/
├── manifest.json          kinds: service + bar-widget, keepLoaded, clonedFrom omarchy.monitor
├── Service.qml            always loaded: Hyprland raw events (monitoradded/removed v2,
│                          configreloaded), lid and resume → profile match → Applier;
│                          follows profiles.json; owns the IpcHandler
├── Panel.qml              bar icon and popup; tab host
├── Applier.qml            the safe-apply engine: eval → verify → watchdog → keep/revert → persist
├── views/                 one file per tab
│   ├── DisplaysView.qml   brightness, text size, scale, quick modes, on/off (the built-in's content)
│   ├── ArrangeView.qml    canvas and inspector
│   ├── ColorView.qml      HDR, colour, bit depth, VRR, night light
│   ├── WorkspacesView.qml
│   ├── ProfilesView.qml   profiles and backups browser
│   └── CastView.qml       wireless and tablet/virtual
├── components/ (qmldir)   Canvas, MonitorTile, Inspector, KeepDialog, IdentifyOverlay,
│                          ModeOsd, CastRow, WirelessGlyph, QrCode, rows (reuse Aurora Pulse's)
├── lib/
│   ├── Model.js           parse hyprctl JSON, modes, cleanScale, PPI, transforms
│   ├── Layout.js          geometry: snap, closeGaps, reflow, staging, stack offsets
│   ├── Lua.js             rule rendering, selector choice, block upsert, comment-aware parsing
│   ├── Profiles.js        identity keys, matching, nearest-profile
│   ├── Workspaces.js      planner strategies → rules
│   ├── Health.js          native-mode / connection-limit insights, EDID parse helpers
│   └── Cast.js            wireless state model (from wireless-display Model.js)
├── bin/
│   ├── omnidisplay-ctl    one bash entry point, every argument validated:
│   │                      state | apply | keep | revert | watchdog | persist | backups |
│   │                      ddc get/set | edid | report | terminal-font
│   ├── omnidisplay-cast   Miracast/AirPlay driver (ported wireless-display-ctl)
│   └── omnidisplay-vnc    headless output and wayvnc lifecycle
├── tests/
│   ├── model.test.js  layout.test.js  lua.test.js  profiles.test.js  workspaces.test.js
│   ├── ctl.test.sh        runs bin/* against a stub hyprctl that only records arguments
│   └── fixtures/          hyprctl captures (1, 2, 3 displays, rotated, mirrored, HDR), monitors.lua samples
├── scripts/  check.sh (tests + validate + qmllint), dev-sync.sh (copy to plugins dir + restart shell)
├── docs/     PLAN.md, ARCHITECTURE.md, SECURITY.md, FEATURES.md
├── .github/workflows/ci.yml
└── README.md  LICENSE  NOTICE  CHANGELOG.md  preview.png
```

### 3.1 Data flow

1. **Read:** `hyprctl monitors all -j` + `monitors.lua` + `profiles.json`, once per open/event.
2. **Edit:** the panel edits a draft in memory. Nothing runs yet.
3. **Apply:** `omnidisplay-ctl apply` arms the watchdog **first**, then runs `hyprctl eval`, then reads `hyprctl monitors` back and diffs it against the request.
4. **Keep:** write the profile, then persist the block (backup → `luac -p` → atomic rename), then stand the watchdog down.
5. **Revert / timeout / panel closed:** `hyprctl reload`; fall back to `eval` of the snapshot; confirm by reading back.
6. **Service:** on events, match the profile; if the live state differs, apply it with the same engine (a keep is implied for an already-kept profile).

### 3.2 Persistence decision

The installed plugins disagree: Steve and Vista write a block, while
monitor-layout and Better Displays Pro never touch `monitors.lua`. **We do
both:** the managed block gives a correct layout at boot and survives removing
the plugin. The service corrects the layout per profile on hotplug. Setting
`persistMode`: `block+service` (default) or `service-only` for people who
keep `monitors.lua` under their own control.

Note: `omarchy refresh hyprland` resets `monitors.lua`. The service notices
the block is missing and offers to write it again.

### 3.3 Marketplace rules we design for

- No installer, no privilege escalation, no system services, no bundled
  binaries, no download-to-shell, and none of those even named in docs
  (the marketplace's static scan flags mentions too).
- Nothing is put on `PATH`. Scripts are called by absolute path from the plugin folder.
  The CLI goes through `omarchy-shell omnidisplay <verb>` (IPC).
- No symlinks inside the plugin, relative entry points, passes `omarchy plugin validate`.
- Optional dependencies are detected at runtime. A missing one shows a
  "copy install command" line rather than failing.

---

## 4. Settings (manifest `barWidget.schema`)

| Key                       | Type                                      | Default           | Purpose                                          |
| ------------------------- | ----------------------------------------- | ----------------- | ------------------------------------------------ |
| `barLabel`              | enum`none/count/profile/cast`           | `none`          | text beside the icon                             |
| `confirmSeconds`        | integer 5–60                             | 15                | keep/revert countdown                            |
| `persistMode`           | enum`block+service/service-only`        | `block+service` | see 3.2                                          |
| `autoProfiles`          | boolean                                   | true              | switch profiles on hotplug/lid/resume            |
| `backupsKept`           | integer 1–50                             | 10                | `monitors.lua` backups                         |
| `snapThreshold`         | integer                                   | 48                | canvas snapping, logical px                      |
| `identifyOnOpen`        | boolean                                   | false             | flash identify badges when the Arrange tab opens |
| `workspaceStrategy`     | enum`off/sequential/interleaved/manual` | `off`           | default for new profiles                         |
| `ddc`                   | boolean                                   | true              | use DDC/CI when`ddcutil` is present            |
| `showColor`             | boolean                                   | true              | Colour tab                                       |
| `showCast`              | boolean                                   | true              | Cast tab                                         |
| `presentationMode`      | boolean                                   | false             | §2.13                                           |
| `notifications`         | boolean                                   | true              | profile switched, revert happened                |
| `terminalFontOverrides` | boolean                                   | false             | per-terminal font rows                           |

## 5. IPC (`omarchy-shell omnidisplay <verb>`)

`open` `close` `toggle` · `state` (JSON) · `identify` · `cycleMode` ·
`mode <extend|mirror|external|internal>` · `profile <name>` · `revert` ·
`emergency` · `brightness <±n%|n%>` · `cast <id>` · `castStop`.
The README gives optional keybinding snippets (for example `SUPER+P` → `cycleMode`,
`SUPER+CTRL+SHIFT+D` → `emergency`). We document them; nothing is bound automatically.

---

## 6. Security

- Every value that reaches Lua or a shell is validated against a strict
  pattern first (connector, `desc:`, mode, position, scale, transform 0–7,
  CM preset whitelist, bit depth 8/10). Strings are Lua-escaped. jq uses `--arg`.
  Ported from Better Displays' and Steve's validators.
- QML calls `Process` with argv arrays, never `bash -c` with interpolation.
- Large payloads travel on stdin, not argv (the 128 KiB limit, and argv is visible to `ps`).
- The token dir is owner-only (700); refuse a symlink or another owner; write tokens to a temp file and rename them into place.
- Only `~/.config/hypr/monitors.lua` (and its backups) and our own config dir are ever written.
- VNC: local-only by default; TLS and a password are required for network mode.
- Cast credentials go over stdin to the daemon socket.
- Full threat model in `docs/SECURITY.md`.

## 7. Testing

- **Node unit tests** for all of `lib/` (same `new Function` loader as Storage Drives), fixtures from real `hyprctl` captures.
- **Script tests**: `bin/*` against a stub `hyprctl`/`ddcutil`/`waycast` that records arguments; every write goes to a temp HOME.
- **Lua round-trip**: the generated block parses with `luac -p`; upserting twice is idempotent; bytes outside the block are unchanged.
- **qmllint** in `scripts/check.sh` (CI runs tests + validate).
- **Manual release checklist** (in README): 1/2/3 displays, rotate, mirror, unplug/replug, dock port swap, lid close, suspend/resume, let a revert expire, kill the shell mid-countdown (the watchdog must revert), HDR on/off, a cast session, a VNC tablet.

---

## 8. Milestones

| #  | Milestone                                                                                                                                              | Done when                                                                                        |
| -- | ------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------ |
| M0 | Scaffold: manifest, LICENSE/NOTICE,`lib/` stubs, test loader, `check.sh`, `dev-sync.sh`, CI                                                      | `omarchy plugin validate` passes, empty tests run                                              |
| M1 | Safe-apply engine and core panel: brightness, text size, scale, universal scale, on/off toggles, block writer, backups                                 | the built-in widget's features work with Keep/Revert; watchdog survives`omarchy restart shell` |
| M2 | Arrange and inspector: canvas for N displays, snapping, stack offsets, keyboard, identify, modes, 8 transforms, mirror, VRR, dry-run preview           | drag 3 displays on fixtures, and for real with the HDMI monitor                                  |
| M3 | Service and profiles: hotplug, lid, resume, quick modes, cycle-mode OSD, workspace planner, first-run cleanup                                          | unplug/replug and dock port swap restore the right profile                                       |
| M4 | Colour and hardware: CM presets, bit depth, SDR controls, EDID capabilities, DDC brightness/contrast/input, health insights, night light               | HDR toggles verified by read-back; DDC on the external monitor                                   |
| M5 | Cast: port the wireless-display ctl, Cast tab, glyph, extended cast screens on the canvas                                                              | Miracast and AirPlay mirror + extend                                                             |
| M6 | Tablet/virtual: headless output, wayvnc lifecycle, TLS, password, QR                                                                                   | tablet connects over LAN with TLS                                                                |
| M7 | Polish and publish: presentation mode, terminal font overrides, diagnostics report, backups browser, README, preview.png, CHANGELOG, marketplace issue | listed on plugins.omarchy.org                                                                    |

## 9. Migrating this machine

Done once OmniDisplay reaches M3 (until then the old plugins stay):

1. `omarchy plugin disable` for `azterisk.display-manager`, `better.displays`,
   `monitor-layout`, `io.github.stevederico.omarchy-displays`,
   `omarchy-wireless-display` (after M5).
2. `~/.config/omarchy/plugins/better.displays/uninstall` to drop the
   `~/.local/bin/omarchy-display-*` symlinks.
3. Let OmniDisplay's first-run cleanup fold the loose `HDMI-A-1` / `eDP-1`
   lines into its block (with a backup). Note that `HDMI-A-1` is currently saved at `scale = 3`.
4. Retire `~/.config/omarchy/displays.json` and `monitor-layout.json` once
   their content is imported as a profile.
5. Keep `omarchy.monitor` disabled; `clonedFrom` handles the swap.

## 10. Credits and licensing

All sources are MIT. Code we port keeps its copyright line in `NOTICE`:
Omarchy (built-in Display widget), Azteriisk, nightdevil00 (Better
Displays), Steve Derico (Displays), Krzysztof Golab Magalhaes (Monitor
Layout), Filippo Veneri (Wireless Display). Features inspired by Vista,
Better Displays Pro, hyprmoncfg, Virtual Display and Tablet Display are
reimplemented, not copied, and credited in the README.

## 11. Open questions

- Should the GitHub repo be `gameticharles/omnidisplay` (like
  `gameticharles/drives`)?
- Keep the stock widget's icon (`󰍹`) or design an OmniDisplay glyph that also
  carries cast state (like WirelessGlyph)?
- Should presentation mode also be offered for HDMI projectors detected by EDID name, or only for cast sessions?

---

## 12. Status (2026-10-02, 1.0.0)

1.0.0 took hyprmoncfg's look and workflow: the stage with lit cards, chips
that glide when the workspace plan changes, the workspace planner with
steppers, persistence and monitor order, profile pictures and details, field
resets, and a wider panel (600 px by default). Rendered and checked live on a
virtual output; `tests/live.sh` has 24 checks.

### 0.3.0

0.3.0 implemented the three tiers from comparing Better Displays Pro, Vista
and Virtual Display (see CHANGELOG): correctness (complete rules, VRR,
configerrors, drift, hotplug during apply), boot-time profiles in Lua, the
state-file mode, per-monitor memory with Undo, EDID modelines, full HDR,
HDR-aware brightness, and the Tier 3 profile, layout, menu, tablet and
calibration features. Not verifiable here: HDR calibration and HDR presets
(no HDR panel), DDC, a real cast and tablet session, a real second monitor.

### 0.2.0

0.2.0 added what the 0.1.0 review found missing: phase timeouts, an exact
revert (snapshot re-applied until it matches, read fresh at Apply), resume
handling with an HDR resend, the missing-block notice, custom modes, ICC,
global options, show-one-window on casts and tablets, start from the
nearest profile, lighter polling, and `tests/live.sh` (22 checks, passing
twice in a row with `--restart`).

### 0.1.0

Milestones M0–M7 are implemented in 0.1.0. Verified:

- 48 library tests and 39 control-script tests pass (`scripts/check.sh`);
  `omarchy plugin validate` passes; qmllint is clean of real errors.
- Live on Hyprland 0.56.2 (Omarchy 4), with a headless test output:
  apply → revert on timeout (exact, including state that never came from
  the file); the watchdog reverting across `omarchy restart shell`; Keep
  writing the managed block after a backup and saving the profile, with no
  flapping on Hyprland's auto-reload; restoring the backup byte for byte;
  Identify, the Keep card on every screen, all six tabs rendering live data.

Not yet verified on real hardware (none attached while building):

- A real external monitor: hotplug restore, a dock or port change matching
  by `desc:`, laptop modes, mirroring.
- HDR presets and 10-bit on an HDR panel; DDC/CI contrast and input.
- A Miracast or AirPlay session; a VNC tablet session (`wayvnc` is not
  installed here).
- Lid close with an external display.

Next:

1. Test the list above with the HDMI monitor, then fold the two loose rules
   Better Displays left in `monitors.lua` (Profiles tab).
2. Disable the remaining display plugins (see README, Moving from other
   display plugins).
3. Push to `github.com/gameticharles/omnidisplay`, then open the
   marketplace issue.
