.pragma library

// Display facts: parsing `hyprctl monitors all -j`, modes, clean scales,
// rotation, pixel density, EDID capabilities and the native-mode insights.
// Pure functions over plain data, no QML. Loaded by the panel, the service
// and by Node in tests/ (see tests/load.js).
//
// Parts of the mode and scale handling follow Omarchy's built-in Display
// widget (shell/plugins/panels/monitor/Model.js) and Steve Derico's
// omarchy-displays (DisplaysLogic.js), both MIT. See NOTICE.

var SCALE_PRESETS = ["1", "1.25", "1.5", "1.6", "2", "3", "4"]

// Hyprland's transform values. Odd ones are quarter turns, 4-7 are flipped.
var TRANSFORMS = [
  { value: 0, label: "Normal", short: "0°" },
  { value: 1, label: "90°", short: "90°" },
  { value: 2, label: "180°", short: "180°" },
  { value: 3, label: "270°", short: "270°" },
  { value: 4, label: "Flipped", short: "F" },
  { value: 5, label: "Flipped 90°", short: "F90°" },
  { value: 6, label: "Flipped 180°", short: "F180°" },
  { value: 7, label: "Flipped 270°", short: "F270°" }
]

// Colour-management presets hl.monitor accepts as `cm`.
var CM_PRESETS = [
  { value: "auto", label: "Auto" },
  { value: "srgb", label: "sRGB" },
  { value: "wide", label: "Wide gamut" },
  { value: "edid", label: "From EDID" },
  { value: "dcip3", label: "DCI-P3" },
  { value: "dp3", label: "Display P3" },
  { value: "adobe", label: "Adobe RGB" },
  { value: "hdr", label: "HDR" },
  { value: "hdredid", label: "HDR (EDID)" }
]

// hl.monitor `vrr`. -1 means "no rule": the global misc.vrr applies.
var VRR_MODES = [
  { value: -1, label: "Default" },
  { value: 0, label: "Off" },
  { value: 1, label: "On" },
  { value: 2, label: "Fullscreen" },
  { value: 3, label: "Games & video" }
]

// Connector names end up in Lua and in shell arguments.
var SAFE_NAME = /^[A-Za-z0-9._-]+$/
var INTERNAL_NAME = /^(eDP|LVDS|DSI)-/

// ---------------------------------------------------------------- numbers

function roundTo(value, places) {
  var factor = Math.pow(10, places)
  return Math.round(Number(value) * factor) / factor
}

function formatRefresh(refresh) {
  return String(roundTo(refresh, 2))
}

function formatScale(scale) {
  return String(roundTo(scale, 6))
}

function gcd(a, b) {
  while (b) {
    var remainder = a % b
    a = b
    b = remainder
  }
  return a
}

// Hyprland only takes scales where the mode divides into whole logical
// pixels in 1/120 steps. Rounds up to the nearest clean value, as
// omarchy-hyprland-monitor-scaling does. 0 for unusable input.
function cleanScale(scale, width, height) {
  var requested = Number(scale)
  var w = Number(width)
  var h = Number(height)
  if (!isFinite(requested) || !isFinite(w) || !isFinite(h) || requested <= 0 || w <= 0 || h <= 0) return 0
  var divisor = gcd(Math.round(w * 120), Math.round(h * 120))
  var units = Math.round(requested * 120)
  if (units < 1) units = 1
  if (units > divisor) units = divisor
  while (divisor % units !== 0) units++
  return roundTo(units / 120, 6)
}

function sameScale(a, b) {
  return Math.abs(Number(a) - Number(b)) < 0.005
}

// Two-decimal string, as the built-in widget shows scales.
function normalizeScale(scale) {
  var n = parseFloat(String(scale === undefined || scale === null ? "" : scale))
  if (!isFinite(n)) return ""
  return String(Math.round(n * 100) / 100)
}

// The presets that land on distinct clean scales for this mode, in preset
// order. Same contract as the built-in widget's availableScales.
function availableScales(presets, width, height) {
  if (!Array.isArray(presets) || !(Number(width) > 0) || !(Number(height) > 0)) return presets || []
  var byEffective = {}
  for (var i = 0; i < presets.length; i++) {
    var requested = Number(presets[i])
    var effective = cleanScale(requested, width, height)
    if (!isFinite(requested) || !(effective > 0)) continue
    var key = normalizeScale(effective)
    var distance = Math.abs(requested - effective)
    if (!byEffective[key] || distance < byEffective[key].distance)
      byEffective[key] = { value: String(presets[i]), index: i, distance: distance }
  }
  return Object.keys(byEffective)
    .map(function(key) { return byEffective[key] })
    .sort(function(a, b) { return a.index - b.index })
    .map(function(c) { return c.value })
}

function matchingScaleIndex(presets, current, width, height) {
  var wanted = normalizeScale(current)
  if (!Array.isArray(presets) || wanted === "") return -1
  for (var i = 0; i < presets.length; i++)
    if (normalizeScale(cleanScale(presets[i], width, height)) === wanted) return i
  return -1
}

function clampBrightness(value) {
  var n = Number(value)
  if (!isFinite(n)) return 1
  return Math.max(1, Math.min(100, Math.round(n)))
}

// The built-in widget's mood names, kept so the hero line reads the same.
function brightnessName(percent) {
  var p = Math.round(percent)
  if (p >= 95) return "Sun blast"
  if (p >= 80) return "Solar flare"
  if (p >= 65) return "Golden hour"
  if (p >= 45) return "Even day"
  if (p >= 30) return "Soft glow"
  if (p >= 20) return "Lamp light"
  if (p >= 10) return "Candlelit"
  return "Night owl"
}

// ------------------------------------------------------------------ modes

function modeKey(width, height, refresh) {
  return width + "x" + height + "@" + formatRefresh(refresh)
}

function parseMode(text) {
  var match = /^\s*(\d+)x(\d+)@(\d+(?:\.\d+)?)(?:Hz)?\s*$/.exec(String(text || ""))
  if (!match) return null
  var width = parseInt(match[1], 10)
  var height = parseInt(match[2], 10)
  var refresh = roundTo(parseFloat(match[3]), 2)
  if (!(width > 0) || !(height > 0) || !(refresh > 0)) return null
  return { width: width, height: height, refresh: refresh, key: modeKey(width, height, refresh) }
}

// Deduped, in hyprctl order (the preferred mode first).
function parseModes(list) {
  var out = []
  var seen = {}
  if (!Array.isArray(list)) return out
  for (var i = 0; i < list.length; i++) {
    var mode = parseMode(list[i])
    if (!mode || seen[mode.key]) continue
    seen[mode.key] = true
    out.push(mode)
  }
  return out
}

// Unique resolutions, largest first, each with its rates high to low.
function resolutionOptions(entry) {
  var modes = (entry && entry.modes) || []
  var byKey = {}
  var out = []
  for (var i = 0; i < modes.length; i++) {
    var key = modes[i].width + "x" + modes[i].height
    if (!byKey[key]) {
      byKey[key] = { key: key, label: modes[i].width + " × " + modes[i].height,
                     width: modes[i].width, height: modes[i].height, refreshRates: [] }
      out.push(byKey[key])
    }
    if (byKey[key].refreshRates.indexOf(modes[i].refresh) < 0) byKey[key].refreshRates.push(modes[i].refresh)
  }
  for (var j = 0; j < out.length; j++) out[j].refreshRates.sort(function(a, b) { return b - a })
  out.sort(function(a, b) { return (b.width * b.height - a.width * a.height) || (b.width - a.width) })
  return out
}

function refreshOptions(entry, width, height) {
  var options = resolutionOptions(entry)
  for (var i = 0; i < options.length; i++)
    if (options[i].width === Number(width) && options[i].height === Number(height))
      return options[i].refreshRates.slice()
  return []
}

function hasMode(entry, width, height, refresh) {
  var key = modeKey(width, height, refresh)
  var modes = (entry && entry.modes) || []
  for (var i = 0; i < modes.length; i++) if (modes[i].key === key) return true
  return false
}

function nearestRefresh(rates, wanted) {
  var best = null
  var bestDistance = Infinity
  for (var i = 0; i < rates.length; i++) {
    var distance = Math.abs(rates[i] - wanted)
    if (distance < bestDistance || (distance === bestDistance && rates[i] > best)) {
      best = rates[i]
      bestDistance = distance
    }
  }
  return best
}

// The mode the panel prefers: hyprctl lists it first.
function preferredMode(entry) {
  var modes = (entry && entry.modes) || []
  return modes.length ? modes[0] : null
}

// The largest resolution the display offers, at its highest rate.
function nativeMode(entry) {
  var options = resolutionOptions(entry)
  if (!options.length) return null
  return { width: options[0].width, height: options[0].height, refresh: options[0].refreshRates[0] }
}

// Every sharp scale for a mode between 1x and 4x (the divisors Hyprland
// accepts), for the scale picker's "More" list.
function sharpScales(width, height) {
  var w = Number(width), h = Number(height)
  if (!(w > 0) || !(h > 0)) return []
  var g = gcd(Math.round(w * 120), Math.round(h * 120))
  var out = []
  for (var u = 120; u <= 480; u++) if (g % u === 0) out.push(roundTo(u / 120, 6))
  return out
}

function inchesLabel(entry) {
  var d = diagonalInches(entry.physicalWidth, entry.physicalHeight)
  return d > 0 ? Math.round(d) + "\"" : ""
}

// Clean scale presets for the entry's mode, ascending, with the current
// scale always present so its pill can light up.
function scaleOptions(entry, presets) {
  var out = []
  var seen = {}
  function add(value) {
    var key = formatScale(value)
    if (!(value > 0) || seen[key]) return
    seen[key] = true
    out.push({ value: value, label: normalizeScale(value) + "x" })
  }
  if (!entry) return out
  var list = presets || SCALE_PRESETS
  for (var i = 0; i < list.length; i++) add(cleanScale(list[i], entry.width, entry.height))
  add(roundTo(entry.scale, 6))
  out.sort(function(a, b) { return a.value - b.value })
  return out
}

// --------------------------------------------------------------- monitors

function isInternalName(name) {
  return INTERNAL_NAME.test(String(name || ""))
}

// hyprctl reports the pixel format; 10-bit formats carry "2101010".
function bitDepthOf(format) {
  return /2101010/.test(String(format || "")) ? 10 : 8
}

function parseMonitors(raw) {
  var data = raw
  if (typeof raw === "string") {
    try { data = JSON.parse(raw) } catch (e) { data = [] }
  }
  if (!Array.isArray(data)) return []

  // hyprctl reports mirrorOf as a monitor id ("0"), not a name.
  var nameById = {}
  for (var d = 0; d < data.length; d++)
    if (data[d] && data[d].name !== undefined && data[d].id !== undefined) nameById[String(data[d].id)] = String(data[d].name)

  var out = []
  for (var i = 0; i < data.length; i++) {
    var m = data[i]
    if (!m || typeof m !== "object") continue
    var name = String(m.name || "")
    if (!name) continue

    var modes = parseModes(m.availableModes)
    var width = Math.round(Number(m.width) || 0)
    var height = Math.round(Number(m.height) || 0)
    var liveRefresh = Number(m.refreshRate) || 0
    var refresh = roundTo(liveRefresh, 2)
    // Snap the live rate (59.95100) onto the advertised mode (59.95Hz).
    var listed = nearestRefresh(refreshOptions({ modes: modes }, width, height), liveRefresh)
    if (listed !== null && Math.abs(listed - liveRefresh) < 0.5) refresh = listed

    // The live mode always counts as offered: virtual outputs and custom
    // modes run modes their list does not carry.
    if (width > 0 && height > 0 && refresh > 0) {
      var liveKey = modeKey(width, height, refresh)
      var listedLive = false
      for (var k = 0; k < modes.length; k++) if (modes[k].key === liveKey) listedLive = true
      if (!listedLive) modes.push({ width: width, height: height, refresh: refresh, key: liveKey, custom: true })
    }

    var scale = Number(m.scale)
    if (!isFinite(scale) || scale <= 0) scale = 1
    var transform = Math.round(Number(m.transform) || 0)
    if (transform < 0 || transform > 7) transform = 0
    var mirrorOf = String(m.mirrorOf === undefined || m.mirrorOf === null ? "none" : m.mirrorOf)
    if (mirrorOf !== "none" && mirrorOf !== "" && nameById[mirrorOf] !== undefined) mirrorOf = nameById[mirrorOf]
    var disabled = m.disabled === true

    out.push({
      id: Number(m.id) || 0,
      name: name,
      description: String(m.description || ""),
      make: String(m.make || ""),
      model: String(m.model || ""),
      serial: String(m.serial || ""),
      internal: isInternalName(name),
      width: width,
      height: height,
      refresh: refresh,
      x: Math.round(Number(m.x) || 0),
      y: Math.round(Number(m.y) || 0),
      scale: roundTo(scale, 6),
      transform: transform,
      enabled: !disabled,
      disabled: disabled,
      mirror: mirrorOf === "none" ? "" : mirrorOf,
      mirrorOf: mirrorOf,
      focused: m.focused === true,
      // What the display is doing now, as Hyprland reports it.
      vrrActive: m.vrr === true,
      cm: String(m.colorManagementPreset || ""),
      format: String(m.currentFormat || ""),
      liveBitdepth: bitDepthOf(m.currentFormat),
      sdrBrightness: Number(m.sdrBrightness) || 1,
      sdrSaturation: Number(m.sdrSaturation) || 1,
      // What a rule asks for. Unset until a profile or the user sets them;
      // Lua.ruleFields writes only the ones that are set.
      vrr: -1,
      bitdepth: 0,
      cmSet: "",
      sdrbrightness: 0,
      sdrsaturation: 0,
      icc: "",
      // HDR details; null means no request (Lua.HDR_FIELDS has the ranges).
      sdrEotf: "",
      supportsHdr: null,
      supportsWideColor: null,
      sdrMaxLuminance: null,
      sdrMinLuminance: null,
      maxLuminance: null,
      maxAvgLuminance: null,
      minLuminance: null,
      // A mode keyword (preferred, highres, highrr) and an automatic position
      // (auto, auto-right, ...) instead of exact values; "" for exact.
      modeKeyword: "",
      positionAuto: "",
      // A mode only the EDID lists, applied as the monitor's own timing.
      modeline: "",
      // A mode typed in by hand rather than picked from the list: Hyprland
      // tries it as a custom mode, and the apply check catches a refusal.
      customMode: false,
      physicalWidth: Number(m.physicalWidth) || 0,
      physicalHeight: Number(m.physicalHeight) || 0,
      dpms: m.dpmsStatus !== false,
      workspace: m.activeWorkspace && isFinite(m.activeWorkspace.id) ? Number(m.activeWorkspace.id) : 0,
      modes: modes
    })
  }

  out.sort(function(a, b) {
    return (a.disabled - b.disabled) || (a.x - b.x) || (a.y - b.y) || (a.name < b.name ? -1 : a.name > b.name ? 1 : 0)
  })
  return out
}

function cloneEntry(entry) {
  var copy = {}
  for (var key in entry) copy[key] = entry[key]
  return copy
}

function cloneList(list) {
  var out = []
  for (var i = 0; i < (list || []).length; i++) out.push(cloneEntry(list[i]))
  return out
}

function entryByName(list, name) {
  for (var i = 0; i < (list || []).length; i++) if (list[i].name === name) return list[i]
  return null
}

// On the desktop: enabled, not mirroring, with a size.
function isArrangeable(entry) {
  return !!entry && entry.enabled !== false && !entry.mirror && entry.width > 0 && entry.height > 0
}

function enabledCount(list) {
  var count = 0
  for (var i = 0; i < (list || []).length; i++) if (list[i].enabled !== false) count++
  return count
}

function internalDisplay(list) {
  for (var i = 0; i < (list || []).length; i++) if (list[i].internal) return list[i]
  return null
}

function externalDisplays(list) {
  return (list || []).filter(function(e) { return !e.internal })
}

// How a display is remembered: by its description (make, model, serial),
// which survives a cable moving to another port. Falls back to the
// connector when the description is empty or shared by identical twins.
function identityKeys(list) {
  var counts = {}
  var i
  for (i = 0; i < (list || []).length; i++) {
    var d = list[i].description
    if (d) counts[d] = (counts[d] || 0) + 1
  }
  var out = {}
  for (i = 0; i < (list || []).length; i++) {
    var e = list[i]
    out[e.name] = e.description && counts[e.description] === 1 ? e.description : e.name
  }
  return out
}

function displayLabel(entry) {
  if (!entry) return ""
  if (entry.internal) return "Built-in display"
  var model = String(entry.model || "").trim()
  if (model && !/^0x[0-9a-f]+$/i.test(model)) return model
  return entry.description || entry.name
}

function modeLabel(entry) {
  if (!entry) return ""
  return entry.width + " × " + entry.height + " @ " + formatRefresh(entry.refresh) + " Hz"
}

function transformLabel(transform) {
  var t = Number(transform) || 0
  return t >= 0 && t < TRANSFORMS.length ? TRANSFORMS[t].label : "Normal"
}

function isQuarterTurn(transform) {
  return (Number(transform) || 0) % 2 === 1
}

// Size on the desktop in logical pixels: mode over scale, swapped for the
// quarter turns.
function logicalSize(entry) {
  var scale = Number(entry.scale) > 0 ? Number(entry.scale) : 1
  var width = Math.round(entry.width / scale)
  var height = Math.round(entry.height / scale)
  if (isQuarterTurn(entry.transform)) return { width: height, height: width }
  return { width: width, height: height }
}

// --------------------------------------------------------------- density

function diagonalInches(physicalWidthMm, physicalHeightMm) {
  var w = Number(physicalWidthMm)
  var h = Number(physicalHeightMm)
  if (!(w > 0) || !(h > 0)) return 0
  return roundTo(Math.sqrt(w * w + h * h) / 25.4, 1)
}

function pixelDensity(entry) {
  if (!entry) return 0
  var mode = nativeMode(entry) || entry
  var inches = diagonalInches(entry.physicalWidth, entry.physicalHeight)
  if (!(inches > 0)) return 0
  return Math.round(Math.sqrt(mode.width * mode.width + mode.height * mode.height) / inches)
}

// A scale that puts the desktop near a comfortable logical density: about
// 110 logical px per inch on a monitor, a little denser on a laptop held
// closer. Snapped to a clean preset for the current mode. 0 when the panel
// reports no physical size (projectors, TVs, virtual outputs).
function suggestedScale(entry) {
  var ppi = pixelDensity(entry)
  if (!(ppi > 0)) return 0
  var target = entry.internal ? 125 : 110
  var raw = ppi / target
  var best = 0
  var bestDistance = Infinity
  for (var i = 0; i < SCALE_PRESETS.length; i++) {
    var value = cleanScale(SCALE_PRESETS[i], entry.width, entry.height)
    if (!(value > 0)) continue
    var distance = Math.abs(value - raw)
    if (distance < bestDistance) {
      best = value
      bestDistance = distance
    }
  }
  return best < 1 ? 1 : best
}

// ------------------------------------------------------------------ EDID

// What `edid-decode` says the panel can do. Fields stay at their zero value
// when the EDID does not mention them.
function parseEdid(text) {
  var s = String(text || "")
  var out = {
    productName: "", bitsPerColor: 0, hdr: false, eotfs: [], wideColor: false,
    maxLuminance: 0, maxAvgLuminance: 0, minLuminance: 0,
    vrrMin: 0, vrrMax: 0, rangeMinHz: 0, rangeMaxHz: 0, timings: []
  }
  var m
  if ((m = /Display Product Name:\s*'([^']*)'/.exec(s))) out.productName = m[1].trim()
  if ((m = /Bits per primary color channel:\s*(\d+)/.exec(s))) out.bitsPerColor = parseInt(m[1], 10)
  if (/SMPTE ST2084|Hybrid Log-Gamma/.test(s)) out.hdr = true
  if (/SMPTE ST2084/.test(s)) out.eotfs.push("PQ")
  if (/Hybrid Log-Gamma/.test(s)) out.eotfs.push("HLG")
  if (/BT2020RGB|BT2020YCC|DCI-P3/.test(s)) out.wideColor = true
  if ((m = /content max luminance:\s*\d+\s*\(([\d.]+) cd\/m\^2\)/.exec(s))) out.maxLuminance = Math.round(parseFloat(m[1]))
  if ((m = /max frame-average luminance:\s*\d+\s*\(([\d.]+) cd\/m\^2\)/.exec(s))) out.maxAvgLuminance = Math.round(parseFloat(m[1]))
  if ((m = /content min luminance:\s*\d+\s*\(([\d.]+) cd\/m\^2\)/.exec(s))) out.minLuminance = parseFloat(m[1])
  if ((m = /Monitor ranges[^:]*:\s*(\d+)-(\d+) Hz V/.exec(s))) {
    out.rangeMinHz = parseInt(m[1], 10)
    out.rangeMaxHz = parseInt(m[2], 10)
  }
  if ((m = /Minimum Refresh Rate:\s*(\d+)/.exec(s))) out.vrrMin = parseInt(m[1], 10)
  if ((m = /Maximum Refresh Rate:\s*(\d+)/.exec(s))) out.vrrMax = parseInt(m[1], 10)
  // A range-limits block with a span wider than a few Hz is the VRR window
  // on panels that carry no vendor block.
  if (!out.vrrMin && out.rangeMinHz && out.rangeMaxHz - out.rangeMinHz > 20) {
    out.vrrMin = out.rangeMinHz
    out.vrrMax = out.rangeMaxHz
  }
  var timing = /DTD \d+:\s+(\d+)x(\d+)\s+([\d.]+) Hz/g
  while ((m = timing.exec(s)) !== null)
    out.timings.push({ width: parseInt(m[1], 10), height: parseInt(m[2], 10), refresh: roundTo(parseFloat(m[3]), 2) })
  return out
}

// Modes the EDID describes, from `edid-decode -X`, as Hyprland modelines:
// [{ width, height, refresh, key, modeline, edid: true }]. Docks and
// adapters often hide some of these from the driver's own list.
function parseModelines(text) {
  var out = []
  var seen = {}
  var re = /Modeline "[^"]*"\s+([\d.]+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)((?:\s+[+-](?:HSync|VSync)|\s+Interlace|\s+DoubleScan)*)/gi
  var m
  while ((m = re.exec(String(text || ""))) !== null) {
    var clock = parseFloat(m[1])
    var h = [2, 3, 4, 5].map(function(i) { return parseInt(m[i], 10) })
    var v = [6, 7, 8, 9].map(function(i) { return parseInt(m[i], 10) })
    if (!(clock > 0) || !(h[3] > 0) || !(v[3] > 0)) continue
    var interlace = /interlace/i.test(m[10])
    var refresh = roundTo(clock * 1e6 / (h[3] * v[3]) * (interlace ? 2 : 1), 2)
    var flags = String(m[10] || "").trim().split(/\s+/).filter(function(f) { return f }).map(function(f) { return f.toLowerCase() })
    var modeline = [String(roundTo(clock, 4))].concat(h, v).join(" ") + (flags.length ? " " + flags.join(" ") : "")
    var key = modeKey(h[0], v[0], refresh)
    if (seen[key]) continue
    seen[key] = true
    out.push({ width: h[0], height: v[0], refresh: refresh, key: key, modeline: modeline, edid: true })
  }
  return out
}

// Adds the EDID's modes the driver did not list, and maps a live refresh that
// drifted from an EDID timing (a custom modeline reports 59.83 for 59.97)
// back onto it, so later changes and profiles refer to one mode.
function withEdidModes(entry, edidModes) {
  if (!entry || !edidModes || !edidModes.length) return entry
  var e = cloneEntry(entry)
  var modes = (e.modes || []).slice()
  for (var i = 0; i < edidModes.length; i++) {
    var em = edidModes[i]
    var listed = false
    for (var k = 0; k < modes.length; k++) {
      if (modes[k].width === em.width && modes[k].height === em.height && Math.abs(modes[k].refresh - em.refresh) < 0.5 && !modes[k].custom) {
        listed = true
        break
      }
    }
    if (!listed) modes.push(em)
  }
  e.modes = modes
  if (!e.modeline) {
    for (var j = 0; j < edidModes.length; j++) {
      var t = edidModes[j]
      if (t.width === e.width && t.height === e.height && Math.abs(t.refresh - e.refresh) < 0.5 && Math.abs(t.refresh - e.refresh) > 0.001
          && !hasMode({ modes: entry.modes.filter(function(x) { return !x.custom }) }, e.width, e.height, e.refresh)) {
        e.refresh = t.refresh
        e.modeline = t.modeline
      }
    }
  }
  return e
}

// The EDID modeline for a mode, or "" when the driver lists the mode itself.
function modelineFor(entry, width, height, refresh) {
  var modes = (entry && entry.modes) || []
  for (var i = 0; i < modes.length; i++)
    if (modes[i].width === Number(width) && modes[i].height === Number(height) && Math.abs(modes[i].refresh - Number(refresh)) < 0.01)
      return modes[i].edid ? modes[i].modeline : ""
  return ""
}

function isEdidOnly(entry, width, height) {
  var modes = (entry && entry.modes) || []
  var any = false
  for (var i = 0; i < modes.length; i++) {
    if (modes[i].width !== width || modes[i].height !== height) continue
    any = true
    if (!modes[i].edid) return false
  }
  return any
}

// The best mode two displays share for mirroring: the largest resolution
// both offer, at the highest rate both can do (within half a hertz).
// null when they share none.
function commonMode(a, b) {
  var ra = resolutionOptions(a)
  for (var i = 0; i < ra.length; i++) {
    var rb = refreshOptions(b, ra[i].width, ra[i].height)
    if (!rb.length) continue
    var best = null
    for (var k = 0; k < ra[i].refreshRates.length; k++) {
      var near = nearestRefresh(rb, ra[i].refreshRates[k])
      if (near !== null && Math.abs(near - ra[i].refreshRates[k]) < 0.5) { best = { a: ra[i].refreshRates[k], b: near }; break }
    }
    if (!best) best = { a: ra[i].refreshRates[0], b: rb[0] }
    return { width: ra[i].width, height: ra[i].height, refreshA: best.a, refreshB: best.b }
  }
  return null
}

function capabilityLines(caps) {
  if (!caps) return []
  var lines = []
  if (caps.productName) lines.push({ label: "Panel", value: caps.productName })
  if (caps.bitsPerColor) lines.push({ label: "Colour depth", value: caps.bitsPerColor + "-bit" })
  lines.push({ label: "HDR", value: caps.hdr ? "Yes (" + caps.eotfs.join(", ") + ")" : "No" })
  lines.push({ label: "Wide colour", value: caps.wideColor ? "Yes" : "No" })
  if (caps.maxLuminance) lines.push({ label: "Peak luminance", value: caps.maxLuminance + " nits" })
  if (caps.maxAvgLuminance) lines.push({ label: "Frame-average", value: caps.maxAvgLuminance + " nits" })
  if (caps.vrrMin) lines.push({ label: "VRR range", value: caps.vrrMin + "–" + caps.vrrMax + " Hz" })
  return lines
}

// ---------------------------------------------------------------- health

// What could be better about a display's current mode, each with a fix the
// panel can offer as one click. `caps` is parseEdid's result or null.
function healthInsights(entry, caps) {
  var out = []
  if (!entry || !entry.enabled || entry.mirror || !entry.modes || !entry.modes.length) return out
  var native = nativeMode(entry)
  if (native && (entry.width !== native.width || entry.height !== native.height)) {
    // Native only from the EDID: start at the gentlest rate at or above
    // 50 Hz, the one most likely to fit a limited link.
    var fixRate = native.refresh
    var edidOnly = isEdidOnly(entry, native.width, native.height)
    if (edidOnly) {
      var rates = refreshOptions(entry, native.width, native.height).filter(function(r) { return r >= 50 }).sort(function(a, b) { return a - b })
      if (rates.length) fixRate = rates[0]
    }
    out.push({
      code: "not-native", level: "warning",
      message: "Not at native resolution (" + native.width + " × " + native.height + ")" + (edidOnly ? ", which only the EDID lists" : ""),
      fix: { width: native.width, height: native.height, refresh: fixRate },
      fixLabel: "Use " + native.width + " × " + native.height
    })
  }
  var rates = refreshOptions(entry, entry.width, entry.height)
  if (rates.length && rates[0] > entry.refresh + 0.5) {
    out.push({
      code: "faster-rate", level: "info",
      message: "A higher refresh rate is available (" + formatRefresh(rates[0]) + " Hz)",
      fix: { width: entry.width, height: entry.height, refresh: rates[0] },
      fixLabel: "Use " + formatRefresh(rates[0]) + " Hz"
    })
  }
  if (caps && native) {
    var edidMax = 0
    for (var i = 0; i < caps.timings.length; i++)
      if (caps.timings[i].width === native.width && caps.timings[i].height === native.height)
        edidMax = Math.max(edidMax, caps.timings[i].refresh)
    if (caps.vrrMax) edidMax = Math.max(edidMax, caps.vrrMax)
    var offered = refreshOptions(entry, native.width, native.height)
    if (edidMax && offered.length && edidMax > offered[0] + 1) {
      out.push({
        code: "link-limited", level: "warning",
        message: "Limited by the connection: the panel does " + Math.round(edidMax) + " Hz, the link carries " + formatRefresh(offered[0]) + " Hz",
        fix: null, fixLabel: "Try another cable or port"
      })
    }
  }
  var suggested = suggestedScale(entry)
  if (suggested && Math.abs(suggested - entry.scale) >= 0.25) {
    out.push({
      code: "scale", level: "info",
      message: "Suggested scale for " + pixelDensity(entry) + " PPI: " + normalizeScale(suggested) + "x",
      fix: { scale: suggested },
      fixLabel: "Use " + normalizeScale(suggested) + "x"
    })
  }
  return out
}

