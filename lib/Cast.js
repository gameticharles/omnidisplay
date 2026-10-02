.pragma library

// Wireless display (Miracast and AirPlay) state for the Cast tab.
// Ported from Filippo Veneri's omarchy-wireless-display (Model.js, MIT); see
// NOTICE. The control script is bin/omnidisplay-cast.

// State shape produced by `omnidisplay-cast state`:
//
// {
//   "status": "idle" | "discovering" | "pairing" | "negotiating" | "streaming" | "error",
//   "errors": [ "..." ],        // newest first; only the user empties it
//   "notice": "",               // worth knowing, not a failure
//   "searched": false,          // a scan has run to completion
//   "backends": {
//     "miracast": { "installed": bool },
//     "airplay":  { "installed": bool, "extend": bool, "per_session_mode": bool }
//   },
//   "pending": [ { "id", "name", "protocol", "address", "mode", "output",
//                  "awaiting": "" | "pin" | "password" } ],
//   "connected": [ { "id", "name", "protocol", "address", "mode", "output" } ],
//   "peers": [ { "id", "name", "protocol", "address", "signal", "state" } ]
// }
//
// Both `pending` and `connected` are lists because more than one display can
// be up at once. What each protocol allows is the backend's business, not
// this file's: Miracast holds a Wi-Fi Direct interface and so runs one
// session, AirPlay fans one capture out to as many receivers as asked for.
// Nothing here counts sessions or knows which protocol is which — it reads
// the lists it is given.
//
// Display ids are namespaced by protocol ("miracast:<mac>", "airplay:<ip>"),
// so they are opaque strings to the panel and can never collide between
// backends.
//
// "protocol" is what makes this the *wireless display* panel rather than the
// *Miracast* panel. It picks a label and, for `supportsExtend`, decides
// whether a row's mode means anything.

function parseState(raw) {
  var parsed
  try {
    parsed = raw ? JSON.parse(String(raw)) : {}
  } catch (e) {
    parsed = {}
  }
  if (!parsed || typeof parsed !== "object") parsed = {}

  var connected = Array.isArray(parsed.connected)
    ? parsed.connected.filter(isValidPeer)
    : []
  var pending = Array.isArray(parsed.pending)
    ? parsed.pending.filter(isValidPeer)
    : []
  var peers = Array.isArray(parsed.peers) ? parsed.peers.filter(isValidPeer) : []

  return {
    // What each backend says it can do. Absent for a backend whose daemon has
    // not been asked yet, which every reader must treat as "cannot".
    backends: (parsed.backends && typeof parsed.backends === "object") ? parsed.backends : {},
    status: typeof parsed.status === "string" ? parsed.status : "idle",
    errors: Array.isArray(parsed.errors)
      ? parsed.errors.filter(function(e) { return typeof e === "string" && e !== "" })
      : [],
    notice: typeof parsed.notice === "string" ? parsed.notice : "",
    // Whether a scan has run to completion. Distinguishes an empty list
    // nobody has looked at from one that was looked at and came back empty.
    searched: parsed.searched === true,
    pending: pending,
    connected: connected,
    peers: sortPeers(peers)
  }
}

function isValidPeer(peer) {
  return !!peer && typeof peer === "object" && typeof peer.id === "string" && peer.id !== ""
}

// One list, in the order the displays were discovered in.
//
// A display's position never changes once it appears. Connecting used to lift
// it to the top, which meant a click moved the thing that was clicked and
// pushed every other row down under the pointer -- the list rearranging itself
// is a worse cost than any ordering it could buy, and the row marks itself as
// connected perfectly well where it stands.
//
// The connected display, the one being connected to, and the discovered peers
// are three separate fields in the state file, and the same display can
// legitimately be in more than one of them at once. Walking the peers and
// looking the other two up keeps discovery order authoritative while still
// showing each display once, with whatever it is currently doing.
//
// Anything not in `peers` is appended after them. That covers a session that
// outlived the scan that found it, and an AirPlay stream started by another
// client entirely, which the panel adopts and has never discovered itself.
function displays(state) {
  var out = []
  var seen = {}

  function entryFor(list, id) {
    for (var i = 0; i < list.length; i++) {
      if (list[i].id === id) return list[i]
    }
    return null
  }

  function push(entry, connected, pending) {
    if (!entry || seen[entry.id]) return
    seen[entry.id] = true
    out.push({
      id: entry.id,
      name: peerLabel(entry),
      protocol: entry.protocol,
      mode: entry.mode || "",
      output: entry.output || "",
      connected: !!connected,
      pending: !!pending,
      // Which credential the receiver is waiting on, if any. Only a pending
      // display can carry one, and only AirPlay produces them.
      awaiting: pending ? (entry.awaiting || "") : ""
    })
  }

  sortPeers(state.peers).forEach(function(peer) {
    // The session record wins over the peer record where they overlap: it is
    // the one carrying the negotiated mode and the output name.
    var live = entryFor(state.connected, peer.id)
    if (live) return push(live, true, false)
    live = entryFor(state.pending, peer.id)
    if (live) return push(live, false, true)
    push(peer, false, false)
  })

  state.connected.forEach(function(d) { push(d, true, false) })
  state.pending.forEach(function(d) { push(d, false, true) })
  return out
}

// Whether a display's mode is a real choice, and so whether its row carries a
// switch. The panel never offers a mode it cannot deliver.
//
// Miracast always can. AirPlay only recently could, and only where the daemon
// answering says so: it reports `session_modes` and `per_session_mode`, and
// both are required, because a daemon that takes a mode per connection but
// cannot extend would silently mirror instead. An older daemon reports
// nothing at all, which reads as "cannot" rather than "unknown" -- the panel
// has to decide whether to draw a control, and offering one that does nothing
// is the worse of the two mistakes.
// The AUR packages each protocol needs. Named here rather than in the panel
// so the string a user is told to run and the string that gets copied are the
// same string -- an install line that does not work is worse than none, and
// `waycast` is not a package: the binary one is `waycast-bin`.
var BACKENDS = [
  { protocol: "miracast", pkg: "waycast-bin" },
  { protocol: "airplay",  pkg: "doubletake-alchemy-bin" }
]

// Which protocols have no backend installed. Absent knowledge counts as
// missing, which is right only because the control script records presence on
// every read: by the time the panel has any state at all, it has this too.
function missingBackends(state) {
  var backends = (state && state.backends) || {}
  return BACKENDS.filter(function(b) {
    var known = backends[b.protocol]
    return !(known && known.installed === true)
  })
}

// What to put on the clipboard, and in the tooltip. One place, so the two
// cannot disagree.
function installCommand(pkg) {
  return "omarchy pkg aur add " + pkg
}

function missingBackendText(backend) {
  return protocolLabel(backend.protocol) + " unavailable — install " + backend.pkg
}

function supportsExtend(protocol, state) {
  if (protocol !== "airplay") return true
  var caps = (state && state.backends && state.backends.airplay) || {}
  return caps.extend === true && caps.per_session_mode === true
}

// The id of the display waiting on a credential, or "" if none is. At most one
// can be waiting, because only one connection is set up at a time.
function awaitingCredential(state) {
  for (var i = 0; i < state.pending.length; i++) {
    if (state.pending[i].awaiting) return state.pending[i].id
  }
  return ""
}

// What to call the thing being asked for. A PIN is the four digits the
// receiver puts on screen; a password is one configured on the device, and
// nothing appears on screen at all — saying "PIN" there sends people looking
// for a code that is never coming.
function credentialLabel(awaiting) {
  return awaiting === "password" ? "Password" : "PIN"
}

// What the panel puts on its error lines, one per message, newest first.
//
// Backend messages pass through untouched -- they are the useful thing in a
// log and usually readable enough. The exception is the one a user is most
// likely to cause: AirPlay's SRP exchange rejects a wrong code at its fourth
// message, and "pair-setup M4 error: 2" tells nobody they simply mistyped.
// Unrecognised wording falls through to the raw message, so a change upstream
// costs clarity rather than correctness.
function errorLines(state) {
  return state.errors.map(function(raw) {
    if (raw.indexOf("pair-setup M4 error") !== -1) {
      return "Wrong PIN or password. Connect again to retry."
    }
    return raw
  })
}

// What the copy button puts on the clipboard: everything the message block
// shows, in the order it shows it, one per line.
function messagesText(state) {
  var lines = errorLines(state)
  if (state.notice) lines.push(state.notice)
  return lines.join("\n")
}

function credentialHint(awaiting) {
  return awaiting === "password"
    ? "Enter the receiver's AirPlay password"
    : "Enter the code shown on the display"
}

function hasConnected(state) {
  return state.connected.length > 0
}

function sortPeers(peers) {
  return peers.slice().sort(function(a, b) {
    var aSignal = isFinite(a.signal) ? Number(a.signal) : -1
    var bSignal = isFinite(b.signal) ? Number(b.signal) : -1
    if (aSignal !== bSignal) return bSignal - aSignal
    var byName = peerLabel(a).localeCompare(peerLabel(b))
    if (byName !== 0) return byName
    // Two displays can carry the same name -- one TV answering on both
    // protocols does, which is not a corner case but the ordinary result of a
    // scan finding an LG. Falling back to the id makes the order total, so a
    // row cannot swap places with its twin between one poll and the next.
    return a.id < b.id ? -1 : (a.id > b.id ? 1 : 0)
  })
}

function peerLabel(peer) {
  if (!peer) return ""
  var name = String(peer.name || "").trim()
  return name !== "" ? name : String(peer.id || "").trim()
}

// Short, protocol-neutral badge text. Deliberately not "WFD"/"Miracast" as
// the only case handled forever — add a branch here, not a new field on the
// panel, when the AirPlay backend lands.
function protocolLabel(protocol) {
  switch (protocol) {
    case "miracast": return "Miracast"
    case "airplay": return "AirPlay"
    default: return protocol ? String(protocol) : "Wireless"
  }
}

function modeLabel(mode) {
  return mode === "mirror" ? "Mirroring" : "Extending"
}

// What a connected display is doing, and where. Extend mode names the output
// Hyprland created so it can be matched against `hyprctl monitors`; mirroring
// creates no output, so there is nothing to name.
function displayDetail(display) {
  if (!display) return ""
  var label = modeLabel(display.mode)
  var output = String(display.output || "").trim()
  return output !== "" ? label + " · " + output : label
}

// The line under the title. The mockup puts the connection state here, so
// this is what the panel shows instead of a fixed description once anything
// is happening.
function headerSubtitle(state) {
  switch (state.status) {
    case "discovering": return "Searching for displays…"
    case "pairing":
    case "negotiating":
      return state.pending.length === 1
        ? "Connecting to " + peerLabel(state.pending[0]) + "…"
        : "Connecting to " + state.pending.length + " displays…"
    case "streaming":
      return state.connected.length === 1
        ? "Connected to " + peerLabel(state.connected[0])
        : state.connected.length + " displays connected"
    // No case for "error". It used to say "Connection failed", which is a
    // claim about something having been attempted -- untrue of, say, a scan
    // that reports no backend is installed. The red line directly below the
    // hero carries the actual message, and the bar icon already marks the
    // state, so there is nothing for this line to add but a guess.
    //
    // Otherwise the line says what to do, and only while there is something
    // to do it to. It used to describe the plugin -- "Mirror or extend onto a
    // wireless display" -- which is the one thing a user who has already
    // opened the panel does not need telling. With nothing found yet there is
    // no next step to name, so it says nothing at all rather than filling the
    // space.
    //
    // U+F0337 is Nerd Font's md-link, the glyph on the pair button itself.
    // Not U+1F517: that one is absent from the bar font and falls back to a
    // colour emoji, which would be the only one on the panel.
    default:
      if (state.peers.length > 0) return "Click 󰌷 to pair"
      // Only after a scan has finished. Before that there is no news to
      // report and the line stays out of the way; saying "No display found"
      // on a panel that has not looked yet would be a claim, not a status.
      return state.searched ? "No display found" : ""
  }
}

// What a row says under the display's name. Disconnected rows carry just the
// protocol, as the mockup has it; a connected row also names the mode it
// actually negotiated. The row's own Extend switch reports the same thing
// while the display is live, so this is the second place it appears -- kept
// because the switch says "extend or not" and this says what that means.
function displaySubtitle(display) {
  var label = protocolLabel(display.protocol)
  if (display.connected && display.mode) {
    return label + " · " + modeLabel(display.mode)
  }
  return label
}

function statusText(state) {
  switch (state.status) {
    case "discovering": return "Looking for displays…"
    case "pairing": return "Pairing…"
    case "negotiating":
      return state.pending.length === 1
        ? "Connecting to " + peerLabel(state.pending[0]) + "…"
        : "Connecting to " + state.pending.length + " displays…"
    case "streaming":
      return state.connected.length === 1
        ? modeLabel(state.connected[0].mode) + " onto " + peerLabel(state.connected[0])
        : state.connected.length + " displays connected"
    case "error": return errorLines(state)[0] || "Connection failed"
    default:
      return state.peers.length > 0
        ? state.peers.length + " display" + (state.peers.length === 1 ? "" : "s") + " found"
        : "No wireless display connected"
  }
}

// What the status mark shows -- see WirelessGlyph.qml. One mark with five
// looks, rather than a different glyph per state: it used to switch between
// a cast icon, a search icon, a transfer icon, a monitor and a warning, so
// the widget changed its whole shape with every step and was never quite
// recognisable as the same thing.
function glyphMode(state) {
  switch (state.status) {
    case "discovering": return "scanning"
    case "pairing":
    case "negotiating": return "connecting"
    case "streaming": return "streaming"
    case "error": return "error"
    default: return "idle"
  }
}

// A session owns the backend when one is connected or being connected.
//
// Both of these read the same two fields the control script's own
// `session_active` reads, deliberately. They used to be phrased in terms of
// `status`, which made them a second, subtly different rule: "error" counted
// as scannable here and as not-scannable there, so the rescan button was
// offered after a failed connect and then did nothing when pressed.
function isBusy(state) {
  return state.pending.length > 0
}

// Discovery contends with an active session for the Wi-Fi radio, so
// rescanning yields to one -- but anything else, an error included, is a
// valid moment to look again.
function canScan(state) {
  return state.pending.length === 0 && state.connected.length === 0
}

// Outputs an extended cast created, so the arrangement canvas can show them
// as ordinary displays. Mirroring creates none.
function castOutputs(state) {
  var out = []
  var list = (state && state.connected) || []
  for (var i = 0; i < list.length; i++) {
    var name = String(list[i].output || "").trim()
    if (list[i].mode !== "mirror" && name && out.indexOf(name) < 0) out.push(name)
  }
  return out
}
