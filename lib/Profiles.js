.pragma library
.import "Model.js" as Model
.import "Layout.js" as Layout
.import "Lua.js" as Lua

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
  return { version: VERSION, profiles: [], globals: {}, monitors: {}, prefs: {} }
}

// Small remembered choices (the tablet's mode, size, side and access, the
// menu row), so the panel opens the way it was left.
function cleanPrefs(raw) {
  var out = {}
  if (!raw || typeof raw !== "object") return out
  if (raw.autoProfiles === true || raw.autoProfiles === false) out.autoProfiles = raw.autoProfiles
  var t = raw.tablet
  if (t && typeof t === "object") {
    out.tablet = {
      mode: t.mode === "mirror" ? "mirror" : "extend",
      size: /^\d{3,4}x\d{3,4}@\d{2,3}$/.test(t.size) ? t.size : "1920x1200@60",
      side: ["left", "right", "above", "below"].indexOf(t.side) >= 0 ? t.side : "right",
      access: t.access === "network" ? "network" : "local"
    }
  }
  return out
}

function setPrefs(store, prefs) {
  var out = copyStore(store)
  out.prefs = cleanPrefs(prefs)
  return out
}

// Per-monitor memory: what each monitor was last kept with, wherever it was,
// and the display it sat next to. Used for a set never seen before.
function cleanMemory(raw) {
  var out = {}
  if (!raw || typeof raw !== "object") return out
  for (var id in raw) {
    var m = raw[id]
    if (!m || typeof m !== "object" || typeof id !== "string" || id === "") continue
    var mode = Model.parseMode(m.mode)
    if (!mode) continue
    out[id] = {
      port: str(m.port), mode: mode.key, modeline: Lua.modelineOk(m.modeline) ? m.modeline : "",
      scale: num(m.scale, 0) > 0 ? Model.roundTo(num(m.scale, 1), 6) : 1,
      transform: Math.max(0, Math.min(7, Math.round(num(m.transform, 0)))),
      internal: m.internal === true,
      neighbor: str(m.neighbor), side: ["left", "right", "above", "below"].indexOf(m.side) >= 0 ? m.side : "",
      offset: Math.round(num(m.offset, 0)), updated: Math.round(num(m.updated, 0))
    }
  }
  return out
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
    customMode: s.customMode === true,
    sdrEotf: Lua.SDR_EOTFS.indexOf(s.sdrEotf) >= 0 ? s.sdrEotf : "",
    modeKeyword: ["preferred", "highres", "highrr"].indexOf(s.modeKeyword) >= 0 ? s.modeKeyword : "",
    positionAuto: ["auto", "auto-right", "auto-left", "auto-up", "auto-down"].indexOf(s.positionAuto) >= 0 ? s.positionAuto : "",
    modeline: typeof s.modeline === "string" && Lua.modelineOk(s.modeline) ? s.modeline : ""
  }
  for (var h = 0; h < Lua.HDR_FIELDS.length; h++) {
    var f = Lua.HDR_FIELDS[h]
    out[f.key] = Lua.hdrValueOk(f, s[f.key]) ? s[f.key] : null
  }
  return out
}

function cleanWorkspaces(raw) {
  var w = raw && typeof raw === "object" ? raw : {}
  var manual = {}
  if (w.manual && typeof w.manual === "object")
    for (var k in w.manual) if (/^\d+$/.test(k) && typeof w.manual[k] === "string") manual[k] = w.manual[k]
  // Persistence: none, the first workspace of each display, or all of them.
  // (`persistent: true` from 0.1/0.2 stores means all.)
  var persistence = ["none", "first", "all"].indexOf(w.persistence) >= 0 ? w.persistence : (w.persistent === true ? "all" : "none")
  return {
    strategy: STRATEGIES.indexOf(w.strategy) >= 0 ? w.strategy : "off",
    count: Math.max(1, Math.min(MAX_WORKSPACES, Math.round(num(w.count, 10)))),
    groupSize: Math.max(0, Math.min(MAX_WORKSPACES, Math.round(num(w.groupSize, 0)))),
    manual: manual,
    persistence: persistence,
    persistent: persistence === "all",
    // Which display gets the first group: identities in order. Left to right
    // for the ones not listed.
    order: Array.isArray(w.order) ? w.order.filter(function(x) { return typeof x === "string" && x !== "" }).slice(0, 16) : []
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
  var ports = {}
  if (raw.ports && typeof raw.ports === "object")
    for (var pi = 0; pi < displays.length; pi++)
      if (typeof raw.ports[displays[pi]] === "string" && Model.SAFE_NAME.test(raw.ports[displays[pi]])) ports[displays[pi]] = raw.ports[displays[pi]]
  // Arrangements kept per laptop mode, so Extend and Mirror each keep their own.
  var variants = {}
  if (raw.variants && typeof raw.variants === "object") {
    for (var vi = 0; vi < LAPTOP_MODES.length; vi++) {
      var vs = raw.variants[LAPTOP_MODES[vi]]
      if (!vs || typeof vs !== "object") continue
      var clean = {}
      for (var vd = 0; vd < displays.length; vd++) if (vs[displays[vd]]) clean[displays[vd]] = cleanSettings(vs[displays[vd]])
      if (Object.keys(clean).length === displays.length) variants[LAPTOP_MODES[vi]] = clean
    }
  }
  return {
    ports: ports,
    variants: variants,
    // A command of the user's own, run after this profile is applied (e.g. to
    // restart something that caches the screen layout).
    postApply: typeof raw.postApply === "string" ? raw.postApply.replace(/[\u0000-\u001f]/g, " ").substring(0, 300) : "",
    anchor: displays.indexOf(raw.anchor) >= 0 ? raw.anchor : "",
    used: Math.round(num(raw.used, num(raw.updated, 0))),
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
  out.monitors = cleanMemory(data.monitors)
  out.prefs = cleanPrefs(data.prefs)
  var list = Array.isArray(data.profiles) ? data.profiles : []
  for (var i = 0; i < list.length; i++) {
    var p = cleanProfile(list[i])
    if (p) out.profiles.push(p)
  }
  return out
}

function serializeStore(store) {
  return JSON.stringify({ version: VERSION, globals: (store && store.globals) || {}, monitors: (store && store.monitors) || {},
                          prefs: (store && store.prefs) || {},
                          profiles: (store && store.profiles) || [] }, null, 2) + "\n"
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

// Every profile for the connected set, most recently used first.
function profilesFor(store, entries) {
  var key = connectedKey(entries)
  var list = (store && store.profiles) || []
  return list.filter(function(p) { return sameSet(p.displays, key) })
             .sort(function(a, b) { return (b.used - a.used) || (b.updated - a.updated) })
}

// The one in force: several can match the same set (a duplicate for
// presenting, say); the one selected or kept last wins.
function profileFor(store, entries) {
  var list = profilesFor(store, entries)
  return list.length ? list[0] : null
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
    e.sdrEotf = s.sdrEotf
    e.modeKeyword = s.modeKeyword
    e.positionAuto = s.positionAuto
    e.modeline = s.modeline
    for (var h = 0; h < Lua.HDR_FIELDS.length; h++) e[Lua.HDR_FIELDS[h].key] = s[Lua.HDR_FIELDS[h].key]
  }
  return normalizeDraft(out, profile.anchor ? nameOf[profile.anchor] : "")
}

// Keeps a draft's arranged displays flush and starting at 0x0, without
// moving the ones that are off or mirroring.
// The anchor display, when given, is the one the others are measured from:
// gaps close towards it.
function normalizeDraft(draft, anchorName) {
  var arranged = draft.filter(Model.isArrangeable)
  var anchor = anchorName && Model.entryByName(arranged, anchorName) ? anchorName : (arranged.length ? arranged[0].name : "")
  var placed = Layout.normalizeLayout(Layout.closeGaps(arranged, anchor))
  var out = Model.cloneList(draft)
  for (var i = 0; i < out.length; i++) {
    var p = Model.entryByName(placed, out[i].name)
    if (p) { out[i].x = p.x; out[i].y = p.y }
  }
  return out
}

// identity -> connector: where each display was when the profile was kept.
// Hyprland's `mirror` wants a connector, and a display that is off is only
// visible to Lua by its connector.
function portsFromDraft(draft) {
  var ids = Model.identityKeys(draft)
  var out = {}
  for (var i = 0; i < draft.length; i++) out[ids[draft[i].name]] = draft[i].name
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
      icc: e.icc, customMode: !!e.customMode, sdrEotf: e.sdrEotf,
      modeKeyword: e.modeKeyword, positionAuto: e.positionAuto, modeline: e.modeline,
      supportsHdr: e.supportsHdr, supportsWideColor: e.supportsWideColor,
      sdrMaxLuminance: e.sdrMaxLuminance, sdrMinLuminance: e.sdrMinLuminance,
      maxLuminance: e.maxLuminance, maxAvgLuminance: e.maxAvgLuminance, minLuminance: e.minLuminance
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
  // The profile kept into: the one asked for, else the one in force for
  // this set (most recently used), else a new one.
  var existing = null
  if (x.id) existing = profileById(out, x.id)
  if (existing && !sameSet(existing.displays, key)) existing = null
  if (!existing) existing = profileFor(out, draft)
  var mode = x.laptop || (existing ? existing.laptop : "extend")
  var settings = settingsFromDraft(draft)
  var variants = existing ? JSON.parse(JSON.stringify(existing.variants || {})) : {}
  if (LAPTOP_MODES.indexOf(mode) >= 0 && key.length > 1) variants[mode] = settings
  var profile = cleanProfile({
    postApply: existing ? existing.postApply : "",
    variants: variants,
    anchor: x.anchor !== undefined ? x.anchor : (existing ? existing.anchor : ""),
    used: nowSeconds || 0,
    id: existing ? existing.id : ("p" + Math.round(nowSeconds || 0) + "-" + out.profiles.length),
    name: x.name || (existing ? existing.name : suggestName(draft)),
    displays: key,
    ports: portsFromDraft(draft),
    settings: settings,
    workspaces: x.workspaces || (existing ? existing.workspaces : null),
    laptop: x.laptop || (existing ? existing.laptop : "extend"),
    updated: nowSeconds || 0
  })
  if (existing) out.profiles[out.profiles.indexOf(existing)] = profile
  else out.profiles.push(profile)
  return { store: out, profile: profile }
}

function selectProfile(store, id, nowSeconds) {
  var out = copyStore(store)
  var p = profileById(out, id)
  if (p) p.used = Math.max(nowSeconds || 0, maxUsed(out) + 1)
  return out
}

function maxUsed(store) {
  var m = 0
  for (var i = 0; i < store.profiles.length; i++) m = Math.max(m, store.profiles[i].used || 0)
  return m
}

// A copy of a profile, in force from now on (rename it to tell them apart).
function duplicateProfile(store, id, nowSeconds) {
  var out = copyStore(store)
  var p = profileById(out, id)
  if (!p) return { store: out, profile: null }
  var copy = JSON.parse(JSON.stringify(p))
  copy.id = "p" + Math.round(nowSeconds || 0) + "-" + out.profiles.length
  copy.name = ("Copy of " + p.name).substring(0, 60)
  copy.used = Math.max(nowSeconds || 0, maxUsed(out) + 1)
  copy.updated = nowSeconds || 0
  var clean = cleanProfile(copy)
  out.profiles.push(clean)
  return { store: out, profile: clean }
}

// The arrangement a profile kept for a laptop mode, over what is connected
// now; null when it has none for that mode.
function variantDraft(entries, profile, mode) {
  if (!profile || !profile.variants || !profile.variants[mode]) return null
  var p = JSON.parse(JSON.stringify(profile))
  p.settings = profile.variants[mode]
  return draftFromProfile(entries, p)
}

function setGlobals(store, globals) {
  var out = copyStore(store)
  out.globals = cleanGlobals(globals)
  return out
}

// Remembers each kept display's settings and where it sat, for sets of
// displays never seen before.
function rememberMonitors(store, draft, nowSeconds) {
  var out = copyStore(store)
  var ids = Model.identityKeys(draft)
  var arranged = draft.filter(Model.isArrangeable)
  for (var i = 0; i < draft.length; i++) {
    var e = draft[i]
    if (e.enabled === false || e.mirror) continue
    var neighbor = "", side = "", offset = 0
    for (var k = 0; k < arranged.length; k++) {
      if (arranged[k].name === e.name) continue
      var rel = Layout.relationBetween(Layout.rectOf(arranged[k]), Layout.rectOf(e))
      if (rel) { neighbor = ids[arranged[k].name]; side = rel.side; offset = rel.offset; break }
    }
    out.monitors[ids[e.name]] = cleanMemory({ x: {
      port: e.name, mode: Model.modeKey(e.width, e.height, e.refresh), modeline: e.modeline || "",
      scale: e.scale, transform: e.transform, internal: !!e.internal,
      neighbor: neighbor, side: side, offset: offset, updated: nowSeconds || 0 } }).x
  }
  return out
}

// A set of displays with no profile: each remembered monitor gets the mode,
// scale and rotation it was last kept with and its old place next to a
// display that is connected too; others keep what Hyprland gave them.
// Returns null when memory has nothing to add.
function draftFromMemory(entries, store) {
  var memory = (store && store.monitors) || {}
  var ids = Model.identityKeys(entries)
  var nameOf = {}
  for (var n in ids) nameOf[ids[n]] = n
  var out = Model.cloneList(entries)
  var used = false
  for (var i = 0; i < out.length; i++) {
    var mem = memory[ids[out[i].name]]
    if (!mem || out[i].enabled === false) continue
    var e = out[i]
    var mode = Model.parseMode(mem.mode)
    if (mode && (Model.hasMode(e, mode.width, mode.height, mode.refresh) || mem.modeline)) {
      e.width = mode.width; e.height = mode.height; e.refresh = mode.refresh
      e.modeline = Model.hasMode(e, mode.width, mode.height, mode.refresh) ? Model.modelineFor(e, mode.width, mode.height, mode.refresh) : mem.modeline
    }
    var c = Model.cleanScale(mem.scale, e.width, e.height)
    if (c > 0) e.scale = c
    e.transform = mem.transform
    used = true
  }
  if (!used) return null
  // Places: next to the remembered neighbour when it is here, else as is.
  var arranged = out.filter(Model.isArrangeable)
  arranged = Layout.reflow(entries.filter(Model.isArrangeable), arranged)
  for (var j = 0; j < arranged.length; j++) {
    var m2 = memory[ids[arranged[j].name]]
    if (!m2 || !m2.neighbor || !m2.side || !nameOf[m2.neighbor]) continue
    var anchor = Model.entryByName(arranged, nameOf[m2.neighbor])
    if (!anchor) continue
    var size = Model.logicalSize(arranged[j])
    var spot = Layout.placeRelative(Layout.rectOf(anchor), { w: size.width, h: size.height },
                                    { side: m2.side, align: "offset", offset: m2.offset })
    arranged = Layout.dropMonitor(arranged, arranged[j].name, spot.x, spot.y, 0)
  }
  for (var k = 0; k < out.length; k++) {
    var p = Model.entryByName(arranged, out[k].name)
    if (p) { out[k].x = p.x; out[k].y = p.y }
  }
  return out
}

// Display entries a saved profile describes, named by the connector each
// display had; for the Lua profiles and the boot-time rules.
function entriesFromProfile(profile) {
  var out = []
  for (var i = 0; i < profile.displays.length; i++) {
    var id = profile.displays[i]
    var s = profile.settings[id]
    var port = (profile.ports && profile.ports[id]) || (Model.SAFE_NAME.test(id) ? id : "")
    if (!s || !port) continue
    var mode = Model.parseMode(s.mode) || { width: 0, height: 0, refresh: 0 }
    var e = {
      name: port, description: id !== port ? id : "", internal: Model.isInternalName(port),
      width: mode.width, height: mode.height, refresh: mode.refresh,
      x: s.x, y: s.y, scale: s.scale > 0 ? s.scale : 1, transform: s.transform,
      enabled: s.enabled, mirror: s.mirror ? ((profile.ports && profile.ports[s.mirror]) || "") : "",
      vrr: s.vrr, bitdepth: s.bitdepth, cmSet: s.cmSet, sdrbrightness: s.sdrbrightness, sdrsaturation: s.sdrsaturation,
      icc: s.icc, sdrEotf: s.sdrEotf, modeKeyword: s.modeKeyword, positionAuto: s.positionAuto, modeline: s.modeline
    }
    for (var h = 0; h < Lua.HDR_FIELDS.length; h++) e[Lua.HDR_FIELDS[h].key] = s[Lua.HDR_FIELDS[h].key]
    if (!(e.width > 0)) e.modeKeyword = e.modeKeyword || "preferred"
    out.push(e)
  }
  return out
}

// Every saved profile as { id, displays: [{ match, port }], rules, workspaces }
// for Lua.profilesLua.
function luaProfiles(store) {
  var out = []
  // Most recently used first: Hyprland applies the first match.
  var list = ((store && store.profiles) || []).slice().sort(function(a, b) { return (b.used - a.used) || (b.updated - a.updated) })
  for (var i = 0; i < list.length; i++) {
    var p = list[i]
    var entries = entriesFromProfile(p)
    if (entries.length !== p.displays.length) continue
    var selectorOf = {}
    var displays = []
    for (var d = 0; d < entries.length; d++) {
      var sel = entries[d].description ? "desc:" + entries[d].description : entries[d].name
      selectorOf[entries[d].name] = sel
      displays.push({ match: sel, port: entries[d].name })
    }
    var rules = []
    for (var r = 0; r < entries.length; r++) {
      var line = Lua.monitorRule(entries[r], selectorOf[entries[r].name], { skipDisabled: entries[r].internal, skipMirror: entries[r].internal })
      if (line) rules.push(line)
    }
    var ws = planWorkspaces(entries, p.workspaces).map(function(w) {
      return Lua.workspaceRule({ workspace: w.workspace, monitor: selectorOf[w.name], isDefault: w.isDefault, persistent: w.persistent })
    })
    out.push({ id: p.id, displays: displays, rules: rules, workspaces: ws })
  }
  return out
}

// Rules for remembered monitors that are not connected now: mode, scale and
// rotation, with an automatic position, so one plugged in later starts out
// right even with no profile for that set (and before the shell starts).
function memoryRules(store, connected) {
  var memory = (store && store.monitors) || {}
  var ids = Model.identityKeys(connected || [])
  var here = {}
  for (var n in ids) here[ids[n]] = true
  var lines = []
  var keys = Object.keys(memory).sort()
  for (var i = 0; i < keys.length; i++) {
    var id = keys[i]
    var m = memory[id]
    if (here[id] || m.internal) continue
    var sel = m.port && id !== m.port ? "desc:" + id : id
    var q = Lua.luaQuote(sel)
    var mode = Model.parseMode(m.mode)
    if (q === null || !mode) continue
    var modeText = Lua.modelineOk(m.modeline) ? "modeline " + m.modeline : mode.key
    lines.push("hl.monitor({ output = " + q + ", mode = \"" + modeText + "\", position = \"auto\", scale = "
               + Model.formatScale(m.scale) + ", transform = " + m.transform + " })")
  }
  return lines
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
  else if (field === "anchor" && (value === "" || p.displays.indexOf(value) >= 0)) p.anchor = value
  else if (field === "postApply" && typeof value === "string") p.postApply = value.replace(/[\u0000-\u001f]/g, " ").trim().substring(0, 300)
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
// Displays in the order workspaces are dealt to them: the plan's own order
// (by identity) first, the rest left to right, then top to bottom.
function workspaceOrder(draft, plan) {
  var arranged = draft.filter(Model.isArrangeable).slice().sort(function(a, b) {
    return (a.x - b.x) || (a.y - b.y) || (a.name < b.name ? -1 : 1)
  })
  var order = plan && Array.isArray(plan.order) ? plan.order : []
  if (!order.length) return arranged
  var ids = Model.identityKeys(draft)
  function rank(e) { var i = order.indexOf(ids[e.name]); return i < 0 ? 1000 : i }
  return arranged.map(function(e, i) { return { e: e, i: i } })
                 .sort(function(a, b) { return (rank(a.e) - rank(b.e)) || (a.i - b.i) })
                 .map(function(x) { return x.e })
}

// The plan with display `name` moved one place earlier (-1) or later (+1).
function moveInOrder(draft, plan, name, delta) {
  var p = cleanWorkspaces(plan)
  var ids = Model.identityKeys(draft)
  var list = workspaceOrder(draft, p).map(function(e) { return ids[e.name] })
  var i = list.indexOf(ids[name])
  var j = i + delta
  if (i < 0 || j < 0 || j >= list.length) return p
  var t = list[i]; list[i] = list[j]; list[j] = t
  p.order = list
  return p
}

// Workspace numbers that change display between two plans, for the canvas
// to glide them: [{ workspace, from, to }].
function chipMoves(before, after) {
  var was = {}
  for (var i = 0; i < (before || []).length; i++) was[before[i].workspace] = before[i].name
  var out = []
  for (var k = 0; k < (after || []).length; k++) {
    var w = after[k]
    if (was[w.workspace] && was[w.workspace] !== w.name) out.push({ workspace: w.workspace, from: was[w.workspace], to: w.name })
  }
  return out
}

// How well a saved profile matches what is connected: a score and the
// reasons, as the Profiles tab shows them. Exact sets score 100 per display.
function matchInfo(profile, entries) {
  var key = connectedKey(entries)
  var shared = profile.displays.filter(function(d) { return key.indexOf(d) >= 0 }).length
  var exact = sameSet(profile.displays, key)
  var reasons = []
  if (exact) reasons.push("+" + (100 * shared) + "  " + shared + " display" + (shared === 1 ? "" : "s") + " connected")
  else {
    if (shared) reasons.push("+" + (50 * shared) + "  " + shared + " of " + profile.displays.length + " saved displays connected")
    var missing = profile.displays.length - shared
    if (missing) reasons.push("−" + (25 * missing) + "  " + missing + " not connected")
    var extra = key.length - shared
    if (extra) reasons.push("−" + (25 * extra) + "  " + extra + " connected but not in it")
  }
  var score = exact ? 100 * shared : Math.max(0, 50 * shared - 25 * (profile.displays.length - shared) - 25 * (key.length - shared))
  return { score: score, exact: exact, shared: shared, reasons: reasons }
}

// [{ workspace, name, isDefault, persistent }] for a plan, or [] for "off".
function planWorkspaces(draft, plan) {
  var p = cleanWorkspaces(plan)
  if (p.strategy === "off") return []
  var order = workspaceOrder(draft, p)
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
    out.push({ workspace: ws, name: target, isDefault: !seen[target],
               persistent: p.persistence === "all" || (p.persistence === "first" && !seen[target]) })
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
