.pragma library
.import "Model.js" as Model
.import "Layout.js" as Layout

// Profiles: one saved arrangement per set of connected displays (the desk,
// the office, the projector), found again by the displays' identities so a
// cable moving to another port or dock still matches. Also the laptop modes
// (extend, mirror, external only, built-in only) and the workspace planner.
//
// Store, ~/.config/omarchy/omnidisplay/profiles.json:
//   { version: 1, profiles: [ { id, name, displays: [identity],
//       settings: { identity: { enabled, mode, x, y, scale, transform,
//                               mirror, vrr, bitdepth, cmSet,
//                               sdrbrightness, sdrsaturation } },
//       workspaces: { strategy, count, groupSize, manual, persistent },
//       laptop: "extend" | "mirror" | "external-only" | "internal-only",
//       updated } ] }

var VERSION = 1
var LAPTOP_MODES = ["extend", "mirror", "external-only", "internal-only"]
var STRATEGIES = ["off", "sequential", "interleaved", "manual"]
var MAX_WORKSPACES = 99

function emptyStore() {
  return { version: VERSION, profiles: [], globals: {} }
}

// Global options (see Lua.GLOBAL_OPTIONS) the user set, by key. Only
// booleans and small integers are kept.
function cleanGlobals(raw) {
  var out = {}
  if (!raw || typeof raw !== "object") return out
  for (var k in raw) {
    if (!/^(general|render|misc)\.[a-z_]+$/.test(k)) continue
    var v = raw[k]
    if (v === true || v === false || (typeof v === "number" && v >= 0 && v <= 9 && Math.round(v) === v)) out[k] = v
  }
  return out
}

function str(v) { return typeof v === "string" ? v : "" }
function num(v, fallback) { var n = Number(v); return isFinite(n) ? n : fallback }

function cleanSettings(raw) {
  var s = raw && typeof raw === "object" ? raw : {}
  var mode = Model.parseMode(s.mode)
  var out = {
    enabled: s.enabled !== false,
    mode: mode ? mode.key : "",
    x: Math.round(num(s.x, 0)),
    y: Math.round(num(s.y, 0)),
    scale: num(s.scale, 0) > 0 ? Model.roundTo(num(s.scale, 1), 6) : 0,
    transform: Math.max(0, Math.min(7, Math.round(num(s.transform, 0)))),
    mirror: str(s.mirror),
    vrr: Math.max(-1, Math.min(3, Math.round(num(s.vrr, -1)))),
    bitdepth: s.bitdepth === 8 || s.bitdepth === 10 ? s.bitdepth : 0,
    cmSet: str(s.cmSet),
    sdrbrightness: num(s.sdrbrightness, 0) > 0 ? num(s.sdrbrightness, 0) : 0,
    sdrsaturation: num(s.sdrsaturation, 0) > 0 ? num(s.sdrsaturation, 0) : 0,
    icc: typeof s.icc === "string" && /^\/[^\u0000-\u001f"\\]{1,250}\.(icc|icm)$/i.test(s.icc) ? s.icc : "",
    customMode: s.customMode === true
  }
  return out
}

function cleanWorkspaces(raw) {
  var w = raw && typeof raw === "object" ? raw : {}
  var manual = {}
  if (w.manual && typeof w.manual === "object")
    for (var k in w.manual) if (/^\d+$/.test(k) && typeof w.manual[k] === "string") manual[k] = w.manual[k]
  return {
    strategy: STRATEGIES.indexOf(w.strategy) >= 0 ? w.strategy : "off",
    count: Math.max(1, Math.min(MAX_WORKSPACES, Math.round(num(w.count, 10)))),
    groupSize: Math.max(0, Math.min(MAX_WORKSPACES, Math.round(num(w.groupSize, 0)))),
    manual: manual,
    persistent: w.persistent === true
  }
}

function cleanProfile(raw) {
  if (!raw || typeof raw !== "object" || !Array.isArray(raw.displays)) return null
  var displays = raw.displays.filter(function(d) { return typeof d === "string" && d !== "" })
  if (!displays.length) return null
  displays.sort()
  var settings = {}
  for (var i = 0; i < displays.length; i++)
    settings[displays[i]] = cleanSettings(raw.settings ? raw.settings[displays[i]] : null)
  return {
    id: str(raw.id) || ("p" + displays.join("|").length + "-" + Math.round(num(raw.updated, 0))),
    name: str(raw.name) || "Profile",
    displays: displays,
    settings: settings,
    workspaces: cleanWorkspaces(raw.workspaces),
    laptop: LAPTOP_MODES.indexOf(raw.laptop) >= 0 ? raw.laptop : "extend",
    updated: Math.round(num(raw.updated, 0))
  }
}

function parseStore(text) {
  var data
  try { data = JSON.parse(String(text || "")) } catch (e) { data = null }
  if (!data || typeof data !== "object") return emptyStore()
  var out = emptyStore()
  out.globals = cleanGlobals(data.globals)
  var list = Array.isArray(data.profiles) ? data.profiles : []
  for (var i = 0; i < list.length; i++) {
    var p = cleanProfile(list[i])
    if (p) out.profiles.push(p)
  }
  return out
}

function serializeStore(store) {
  return JSON.stringify({ version: VERSION, globals: (store && store.globals) || {}, profiles: (store && store.profiles) || [] }, null, 2) + "\n"
}

function copyStore(store) {
  return parseStore(serializeStore(store))
}

// The identities of what is connected now, sorted: a profile's key.
function connectedKey(entries) {
  var ids = Model.identityKeys(entries)
  var out = []
  for (var name in ids) out.push(ids[name])
  out.sort()
  return out
}

function sameSet(a, b) {
  if (a.length !== b.length) return false
  for (var i = 0; i < a.length; i++) if (a[i] !== b[i]) return false
  return true
}

function profileFor(store, entries) {
  var key = connectedKey(entries)
  var list = (store && store.profiles) || []
  for (var i = 0; i < list.length; i++) if (sameSet(list[i].displays, key)) return list[i]
  return null
}

function profileById(store, id) {
  var list = (store && store.profiles) || []
  for (var i = 0; i < list.length; i++) if (list[i].id === id) return list[i]
  return null
}

// For a combination never seen before: the profile sharing the most
// displays with it, most recently updated first. null when none share any.
function nearestProfile(store, entries) {
  var key = connectedKey(entries)
  var best = null
  var bestShared = 0
  var list = (store && store.profiles) || []
  for (var i = 0; i < list.length; i++) {
    var shared = 0
    for (var j = 0; j < list[i].displays.length; j++) if (key.indexOf(list[i].displays[j]) >= 0) shared++
    if (shared > bestShared || (shared === bestShared && shared > 0 && best && list[i].updated > best.updated)) {
      best = list[i]
      bestShared = shared
    }
  }
  return best
}

function suggestName(entries) {
  var externals = Model.externalDisplays(entries)
  if (!externals.length) return "Laptop only"
  var names = externals.map(function(e) { return Model.displayLabel(e) })
  return (Model.internalDisplay(entries) ? "Laptop + " : "") + names.join(" + ")
}

// The draft a profile asks for, over what is connected now. Displays the
// profile does not know keep their live settings. Modes the display no
// longer offers fall back to the live one; scales are re-cleaned.
function draftFromProfile(entries, profile) {
  var out = Model.cloneList(entries)
  if (!profile) return out
  var ids = Model.identityKeys(entries)
  var nameOf = {}
  for (var n in ids) nameOf[ids[n]] = n
  for (var i = 0; i < out.length; i++) {
    var e = out[i]
    var s = profile.settings[ids[e.name]]
    if (!s) continue
    e.enabled = s.enabled
    var mode = Model.parseMode(s.mode)
    if (mode && (Model.hasMode(e, mode.width, mode.height, mode.refresh) || s.customMode)) {
      e.width = mode.width
      e.height = mode.height
      e.refresh = mode.refresh
      e.customMode = s.customMode && !Model.hasMode(e, mode.width, mode.height, mode.refresh)
    }
    var clean = s.scale > 0 ? Model.cleanScale(s.scale, e.width, e.height) : 0
    if (clean > 0) e.scale = clean
    e.transform = s.transform
    e.x = s.x
    e.y = s.y
    e.mirror = s.mirror && nameOf[s.mirror] && nameOf[s.mirror] !== e.name ? nameOf[s.mirror] : ""
    e.vrr = s.vrr
    e.bitdepth = s.bitdepth
    e.cmSet = s.cmSet
    e.sdrbrightness = s.sdrbrightness
    e.sdrsaturation = s.sdrsaturation
    e.icc = s.icc
  }
  return normalizeDraft(out)
}

// Keeps a draft's arranged displays flush and starting at 0x0, without
// moving the ones that are off or mirroring.
function normalizeDraft(draft) {
  var arranged = draft.filter(Model.isArrangeable)
  var placed = Layout.normalizeLayout(Layout.closeGaps(arranged, arranged.length ? arranged[0].name : ""))
  var out = Model.cloneList(draft)
  for (var i = 0; i < out.length; i++) {
    var p = Model.entryByName(placed, out[i].name)
    if (p) { out[i].x = p.x; out[i].y = p.y }
  }
  return out
}

function settingsFromDraft(draft) {
  var ids = Model.identityKeys(draft)
  var settings = {}
  for (var i = 0; i < draft.length; i++) {
    var e = draft[i]
    settings[ids[e.name]] = cleanSettings({
      enabled: e.enabled !== false,
      mode: Model.modeKey(e.width, e.height, e.refresh),
      x: e.x, y: e.y, scale: e.scale, transform: e.transform,
      mirror: e.mirror ? (ids[e.mirror] || "") : "",
      vrr: e.vrr, bitdepth: e.bitdepth, cmSet: e.cmSet,
      sdrbrightness: e.sdrbrightness, sdrsaturation: e.sdrsaturation,
      icc: e.icc, customMode: !!e.customMode
    })
  }
  return settings
}

// Saves the draft as the profile for its set of displays, keeping that
// profile's name, workspaces and laptop mode unless given.
function upsertProfile(store, draft, extra, nowSeconds) {
  var out = copyStore(store)
  var key = connectedKey(draft)
  var x = extra || {}
  var existing = null
  for (var i = 0; i < out.profiles.length; i++) if (sameSet(out.profiles[i].displays, key)) existing = out.profiles[i]
  var profile = cleanProfile({
    id: existing ? existing.id : ("p" + Math.round(nowSeconds || 0) + "-" + out.profiles.length),
    name: x.name || (existing ? existing.name : suggestName(draft)),
    displays: key,
    settings: settingsFromDraft(draft),
    workspaces: x.workspaces || (existing ? existing.workspaces : null),
    laptop: x.laptop || (existing ? existing.laptop : "extend"),
    updated: nowSeconds || 0
  })
  if (existing) out.profiles[out.profiles.indexOf(existing)] = profile
  else out.profiles.push(profile)
  return { store: out, profile: profile }
}

function setGlobals(store, globals) {
  var out = copyStore(store)
  out.globals = cleanGlobals(globals)
  return out
}

function renameProfile(store, id, name) {
  var out = copyStore(store)
  var p = profileById(out, id)
  if (p && String(name || "").trim()) p.name = String(name).trim().substring(0, 60)
  return out
}

function deleteProfile(store, id) {
  var out = copyStore(store)
  out.profiles = out.profiles.filter(function(p) { return p.id !== id })
  return out
}

function setProfileField(store, id, field, value) {
  var out = copyStore(store)
  var p = profileById(out, id)
  if (!p) return out
  if (field === "workspaces") p.workspaces = cleanWorkspaces(value)
  else if (field === "laptop" && LAPTOP_MODES.indexOf(value) >= 0) p.laptop = value
  return out
}

// ------------------------------------------------------------ laptop modes

// What a laptop mode means for a draft. The built-in panel's on/off and
// mirroring go through Omarchy's own toggles (`commands`), because its
// clamshell watcher and lid handling read them; external displays are
// switched with ordinary rules in the draft.
function applyLaptopMode(entries, mode) {
  var draft = Model.cloneList(entries)
  var internal = Model.internalDisplay(draft)
  var externals = Model.externalDisplays(draft)
  var commands = []
  if (!internal || !externals.length) return { draft: draft, commands: commands, ok: false }
  var joined = []
  for (var i = 0; i < draft.length; i++) {
    var e = draft[i]
    if (e.internal) continue
    var wasOff = e.enabled === false || !!e.mirror
    e.enabled = mode !== "internal-only"
    e.mirror = ""
    if (wasOff && e.enabled) joined.push(e.name)
  }
  if (mode === "extend") {
    commands.push(["omarchy-hyprland-monitor-internal-mirror", "off"])
    commands.push(["omarchy-hyprland-monitor-internal", "on"])
  } else if (mode === "mirror") {
    commands.push(["omarchy-hyprland-monitor-internal", "on"])
    commands.push(["omarchy-hyprland-monitor-internal-mirror", "on"])
  } else if (mode === "external-only") {
    commands.push(["omarchy-hyprland-monitor-internal-mirror", "off"])
    commands.push(["omarchy-hyprland-monitor-internal", "off"])
  } else if (mode === "internal-only") {
    commands.push(["omarchy-hyprland-monitor-internal-mirror", "off"])
    commands.push(["omarchy-hyprland-monitor-internal", "on"])
  }
  var arranged = draft.filter(Model.isArrangeable)
  var placed = joined.length ? Layout.placeNewcomers(arranged, joined) : arranged
  for (var k = 0; k < draft.length; k++) {
    var p = Model.entryByName(placed, draft[k].name)
    if (p) { draft[k].x = p.x; draft[k].y = p.y }
  }
  return { draft: draft, commands: commands, ok: true }
}

// The mode the live state is in, as close as it can be read.
function currentLaptopMode(entries) {
  var internal = Model.internalDisplay(entries)
  var externals = Model.externalDisplays(entries)
  if (!internal || !externals.length) return ""
  var anyExternalOn = externals.some(function(e) { return e.enabled !== false })
  if (!anyExternalOn) return "internal-only"
  if (internal.enabled === false) return "external-only"
  if (internal.mirror || externals.some(function(e) { return !!e.mirror })) return "mirror"
  return "extend"
}

function nextLaptopMode(mode) {
  var i = LAPTOP_MODES.indexOf(mode)
  return LAPTOP_MODES[(i + 1) % LAPTOP_MODES.length]
}

function laptopModeLabel(mode) {
  switch (mode) {
    case "extend": return "Extend"
    case "mirror": return "Mirror"
    case "external-only": return "External only"
    case "internal-only": return "Built-in only"
    default: return ""
  }
}

// -------------------------------------------------------------- workspaces

// Displays in reading order: left to right, then top to bottom.
function workspaceOrder(draft) {
  return draft.filter(Model.isArrangeable).slice().sort(function(a, b) {
    return (a.x - b.x) || (a.y - b.y) || (a.name < b.name ? -1 : 1)
  })
}

// [{ workspace, name, isDefault, persistent }] for a plan, or [] for "off".
function planWorkspaces(draft, plan) {
  var p = cleanWorkspaces(plan)
  if (p.strategy === "off") return []
  var order = workspaceOrder(draft)
  if (!order.length) return []
  var ids = Model.identityKeys(draft)
  var nameOf = {}
  for (var n in ids) nameOf[ids[n]] = n
  var count = p.count
  var group = p.groupSize > 0 ? p.groupSize : Math.ceil(count / order.length)
  var out = []
  var seen = {}
  for (var ws = 1; ws <= count; ws++) {
    var target
    if (p.strategy === "interleaved") target = order[(ws - 1) % order.length].name
    else target = order[Math.min(Math.floor((ws - 1) / group), order.length - 1)].name
    if (p.strategy === "manual" && p.manual[String(ws)] && nameOf[p.manual[String(ws)]]) {
      var manualName = nameOf[p.manual[String(ws)]]
      if (Model.isArrangeable(Model.entryByName(draft, manualName))) target = manualName
    }
    out.push({ workspace: ws, name: target, isDefault: !seen[target], persistent: p.persistent })
    seen[target] = true
  }
  return out
}

// Workspaces that exist now but sit on another display than the plan says.
function workspaceMoves(plan, liveWorkspaces) {
  var where = {}
  for (var i = 0; i < plan.length; i++) where[plan[i].workspace] = plan[i].name
  var out = []
  for (var j = 0; j < (liveWorkspaces || []).length; j++) {
    var w = liveWorkspaces[j]
    var id = Number(w.id)
    if (!(id > 0) || !where[id] || where[id] === w.monitor) continue
    out.push({ workspace: id, name: where[id] })
  }
  return out
}
