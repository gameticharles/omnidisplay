# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [1.0.1] - 2026-10-05

### Fixed

- Display modes with a TV cast as the second screen. Mirror, Built-in only,
  switching the screen off and the workspace plan all seemed to do nothing:
  - A kept "Built-in only" was written as a rule switching the cast's
    virtual screen (HEADLESS-1) off, and Hyprland and the automatic restore
    re-applied it at every reload and display change, so the TV went on
    showing its last frame of the desktop. A cast's screen is no longer
    kept off: the saved rules keep only its mirror, and the Hyprland-side
    profiles leave sets with a cast out (the plugin restores those).
  - The automatic restore no longer changes what is on, off or mirrored
    while a cast is live, or when the laptop mode already matches the
    profile's (it put an extended screen over a kept mirror, and switched
    the laptop panel back on after External only).
  - With a cast as the only second screen, the laptop modes act on the
    cast: Mirror and Extend change its screen with a live rule (no
    Hyprland reload, which crashed the shell and GTK 3 programs such as the
    browser), and Built-in only ends the cast.

### Security

- `omnidisplay-vnc status` handed the network session's VNC password to jq
  as a command-line argument (`--arg`), where any local user could read it
  through `ps` or `/proc`. jq now reads it from its owner-only file
  (`--rawfile`), so only the path is an argument. A test runs status with a
  jq that records its arguments and fails if the password is among them.

## [1.0.0] - 2026-10-02

Visuals and workflow adopted from crmne's hyprmoncfg (MIT).

### Added

- A new stage for the canvas: a dot grid, display cards with a bezel, a
  contact shadow and a lit panel (accent only on the selected one), showing
  the number, connector, model and size, mode, scale and position.
- Workspace chips in a row under each display's name, ending in +N when they
  do not fit; when the plan changes, the moving chips glide to their new
  display.
- Spaces tab: the plan drawn on the stage, steppers for the workspace count
  and group size (typed or −/+), persistent workspaces (none, the first per
  display, all), a monitor order that says which display gets workspace 1,
  a summary per display, and arrows on each workspace in manual mode.
- Profiles tab: a small picture of each profile's layout, its match score,
  expandable details (updated, why it matches, displays, workspaces), a
  command to run after it is applied, and a switch for automatic profiles.
- Arrange tab: typed X and Y, rotation and adaptive sync as button rows, a
  reset beside each field that differs from what is live, sharp scales
  under More, a hardware grid with Identify for one display, connected
  displays with no signal, and a note on a card when a display runs below
  what was saved.
- The Display tab opens with a compact picture of the layout; the Keep card
  shows the layout about to be kept.
- `panelWidth` setting: compact (480 px), comfortable (600 px, the new
  default) or wide (720 px).
- IPC: `workspaces <strategy> [count]` drafts a workspace plan;
  `resetDraft` drops unapplied edits.
- A new marketplace preview (Arrange, Spaces and Colour with the main
  features), rendered from `docs/preview/` by `scripts/preview.sh`.

## [0.3.0] - 2026-10-02

### Fixed

- Switching a display from Mirror back to Extend left it mirroring: rules now
  clear `mirror`. Mirrored layouts were refused, because Hyprland reports
  `mirrorOf` as an id; it is mapped to the name.
- Setting HDR, bit depth, adaptive sync, SDR levels or HDR details back to
  "Default" left the old value live (Hyprland merges rules); they are now
  written as Hyprland's defaults. Clearing an ICC profile reloads first.
- A change to adaptive sync alone was ignored by Hyprland (its rule compare
  skips `vrr`): it is now sent with a harmless nudge, then for real, for apply
  and revert alike.
- A new virtual output no longer inherits rules from an earlier one.

### Added

- Profiles at boot: the managed block carries every profile as guarded Lua
  that Hyprland runs itself at load and on hotplug, so every desk has its
  layout before the shell starts and after the plugin is removed. Remembered
  monitors that are not connected keep a rule too.
- A save mode that never edits `monitors.lua` (`state-file`): the same block in
  Omarchy's toggles folder.
- After saving, `hyprctl configerrors` is checked; new errors put the previous
  file back.
- Per-monitor memory: a known monitor in a new set gets its last mode,
  scale, rotation and place, with an Undo notification (also after a profile
  restore).
- Modes only the EDID lists (common behind docks and adapters), applied as
  the EDID's own modeline; a drifted refresh rate is mapped back to it.
- HDR details: force HDR or wide colour, SDR white and black levels (203 nits
  when HDR is turned on), peak, full-screen and black luminance prefilled
  from the EDID, SDR transfer; requested vs actual preset; HDR calibration by
  eye with PQ test patterns (mpv, ImageMagick).
- HDR-aware brightness: in HDR the slider and `brightnessStep` (for the
  brightness keys) set SDR brightness.
- Mode keywords (preferred, highest resolution, highest refresh) and automatic
  positions; seven more global options.
- Several profiles per set of displays (the last used wins), duplicate, an
  anchor display to measure from, and an arrangement kept per laptop mode.
- Mirroring picks a mode both displays offer.
- Layout health with Repair; Rescan; a full-screen arrangement editor (f).
- Notice when the live layout drifts from the profile, with Restore or Keep
  live; a display plugged in during a change reverts it.
- `?` shows the keys; opt-in Setup › Displays row in the Omarchy menu; the
  backlight slider follows the brightness keys; DDC colour preset;
  `revert`, `keep` and `emergency` on the `omarchy.monitor` target.
- Tablet: custom size, resize while running, listening state, Wi-Fi/Ethernet
  labels, the SSH tunnel command, a new password takes effect at once, and the
  last choices are remembered.
- `tests/lua-profiles.test.js` runs the boot-time Lua in a real interpreter.

## [0.2.0] - 2026-10-02

### Added

- Show one window on a TV or tablet: casts carry whole screens (both
  backends ask the portal for monitors only), so the chosen window moves
  onto the extended cast or tablet screen and goes fullscreen; Return puts
  it back, and it comes back by itself when that screen goes away.
- Custom modes: type `W×H@Hz` for a mode the display does not list; the
  check after Apply reverts it if the display refuses.
- ICC profile per display (Colour tab).
- Options for all displays: default adaptive sync, tearing, direct scan-out,
  automatic HDR. Applied with the same countdown and kept in the block.
- After resume, the profile is checked again and HDR panels get their
  metadata resent (`omarchy-shell omnidisplay resendHdr`).
- When `monitors.lua` loses OmniDisplay's block (an Omarchy refresh), the
  panel offers to write it again.
- A set of displays never seen before can start from the saved profile it
  shares most displays with.
- Arrange keys: `+`/`-` scale, `o` rotate, `e` on/off.
- IPC: `option`, `options`, `resendHdr`, `writeBlock`, `messages`,
  `clearMessages`.
- `tests/live.sh`: the engine tested against the running session on a
  virtual output (revert on timeout and on request, refusals, global
  options, the watchdog across a shell restart, Keep, restore on reconnect),
  putting `monitors.lua` and the profiles back byte for byte.

### Fixed

- A revert could land on the reload's catch-all rule instead of the
  previous state: Hyprland applies a reload's monitor rules after `reload`
  returns. The expected state now travels with the revert, and the snapshot
  is applied again until the displays show it.
- Standing the watchdog down could delete the revert files under a revert
  that was still reading them; they are read into memory first.
- The revert snapshot could be a few hundred milliseconds old. Apply now
  checks the plan at once, then reads the displays again and builds the
  final plan and snapshot from that.
- A step that never finishes (a hung `hyprctl`) no longer locks the panel:
  it is released after 25 seconds with a message.
- Laptop modes: the check after Apply no longer mistakes the moves
  Omarchy's toggles cause for a refused change.
- Changing the workspace plan now drops the old rules (they can only be
  removed by a reload, so the apply reloads first).

### Changed

- Focus changes no longer re-read the displays; focus comes from
  Quickshell's Hyprland model.
- Cast state follows the state file as it changes; the reconciling poll
  went from every 2 to every 5 seconds, and only while casting or on the
  Cast tab.
- Parsing `monitors.lua` is cached; external monitors' brightness (DDC, about
  a second each) is not re-read within 30 seconds.

## [0.1.0] - 2026-10-02

### Added

- One bar widget for every display setting, replacing Omarchy's Display
  widget (`SUPER + CTRL + D`), with six tabs: Display, Arrange, Colour,
  Spaces, Profiles, Cast.
- Safe apply: every change goes live with `hyprctl eval`, a Keep/Revert
  card appears on every screen, and a detached watchdog reverts exactly
  (reload, then the pre-change snapshot) if nothing is kept, even when the
  shell itself goes down.
- Arrangement canvas for any number of displays: drag and snap, place
  left/right/above/below with start, centre or end alignment, keyboard
  moves, Identify, neighbours kept attached when a display changes size.
- Per display: on/off, extend or mirror, resolution, refresh rate, clean
  scales with a density-based suggestion, all eight rotations and flips,
  adaptive sync.
- Colour: presets including HDR, 8/10-bit, SDR brightness and saturation,
  EDID capabilities; DDC/CI contrast and input source.
- Brightness for every display through Omarchy's own command (backlight,
  Apple displays and DDC/CI), text size, per-terminal font sizes, night
  light, presentation mode.
- Profiles per set of displays, matched by panel so a cable can change
  port, restored automatically on hotplug and config reloads; laptop modes
  (Extend, Mirror, External only, Built-in only) and a workspace planner
  (sequential, interleaved, manual) saved with them.
- The managed block at the end of `monitors.lua`, timestamped backups with
  restore, and cleanup of rules other display plugins left behind.
- Cast: Miracast and AirPlay (ported from Wireless Display) and tablets or
  phones as a screen over VNC, local only or TLS with a password.
- IPC for scripts and key bindings: `show`, `cycleMode`, `mode`, `profile`,
  `scale`, `rotate`, `setMode`, `enable`, `disable`, `keep`, `revert`,
  `emergency`, `identify`, `state`.
