# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

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
