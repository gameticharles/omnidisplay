.pragma library
.import "Model.js" as Model

// Lua for Hyprland: the hl.monitor and hl.workspace_rule lines OmniDisplay
// applies with `hyprctl eval` and keeps in one managed block at the end of
// ~/.config/hypr/monitors.lua. Reading the user's own rules, so the block can
// reuse their selectors, also lives here.
//
// The comment-aware rule reader, selector choice and block upsert follow
// Steve Derico's omarchy-displays (DisplaysLogic.js, MIT). See NOTICE.

var BLOCK_BEGIN = "-- omnidisplay: begin"
var BLOCK_END = "-- omnidisplay: end"

// Blocks other display plugins leave in monitors.lua. Offered for cleanup.
var FOREIGN_BLOCKS = [
  { plugin: "Display Manager (Azteriisk)", begin: "-- BEGIN OMARCHY DISPLAY MANAGER (AUTO-GENERATED)", end: "-- END OMARCHY DISPLAY MANAGER" },
  { plugin: "Displays (Steve Derico)", begin: "-- omarchy-displays: begin", end: "-- omarchy-displays: end" }
]

// The Linux single-argument limit is 128 KiB; files are passed on stdin, but
// a monitors.lua this large is not something to rewrite blindly either.
var MAX_FILE_BYTES = 120 * 1024

var CM_VALUES = ["auto", "srgb", "wide", "edid", "dcip3", "dp3", "adobe", "hdr", "hdredid"]

// A double-quoted Lua literal, or null for text that has no business in a
// config file (control characters), so callers refuse rather than guess.
function luaQuote(text) {
  var s = String(text)
  if (/[\u0000-\u001f\u007f]/.test(s)) return null
  return "\"" + s.replace(/\\/g, "\\\\").replace(/"/g, "\\\"") + "\""
}

function stripLuaComments(text) {
  var source = String(text || "").replace(/--\[\[[\s\S]*?\]\]/g, "")
  var lines = source.split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    var quote = ""
    for (var c = 0; c < line.length; c++) {
      var ch = line.charAt(c)
      if (quote) {
        if (ch === "\\") c++
        else if (ch === quote) quote = ""
      } else if (ch === "\"" || ch === "'") {
        quote = ch
      } else if (ch === "-" && line.charAt(c + 1) === "-") {
        lines[i] = line.substring(0, c)
        break
      }
    }
  }
  return lines.join("\n")
}

function unquoteLua(literal) {
  return literal.substring(1, literal.length - 1).replace(/\\(.)/g, "$1")
}

var LUA_STRING = "\"(?:[^\"\\\\\\n]|\\\\.)*\"|'(?:[^'\\\\\\n]|\\\\.)*'"

function lineIndexes(text, marker) {
  var lines = String(text || "").split("\n")
  var hits = []
  for (var i = 0; i < lines.length; i++) if (lines[i].replace(/\s+$/, "") === marker) hits.push(i)
  return hits
}

// Cuts a marked block out. ok is false when the markers are damaged (one
// without the other, repeated, out of order); the text then comes back
// untouched. The one blank line upsertManagedBlock adds in front goes too.
function removeBlock(text, begin, end) {
  var source = String(text || "")
  var begins = lineIndexes(source, begin)
  var ends = lineIndexes(source, end)
  if (begins.length === 0 && ends.length === 0) return { ok: true, found: false, text: source }
  if (begins.length !== 1 || ends.length !== 1 || ends[0] < begins[0])
    return { ok: false, found: true, text: source, error: "monitors.lua has damaged \"" + begin + "\" markers. Fix or remove them by hand" }
  var lines = source.split("\n")
  var head = lines.slice(0, begins[0])
  var tail = lines.slice(ends[0] + 1)
  if (head.length && head[head.length - 1].replace(/\s+$/, "") === "") head.pop()
  return { ok: true, found: true, text: head.concat(tail).join("\n") }
}

function removeManagedBlock(text) {
  return removeBlock(text, BLOCK_BEGIN, BLOCK_END)
}

// The managed block always goes last: Hyprland lets the last matching rule
// win. Everything outside it is kept byte for byte.
function upsertManagedBlock(text, block) {
  var removed = removeManagedBlock(text)
  if (!removed.ok) return { ok: false, text: String(text || ""), error: removed.error }
  var base = removed.text
  if (base !== "" && base.charAt(base.length - 1) !== "\n") base += "\n"
  if (base !== "") base += "\n"
  return { ok: true, text: base + block + "\n", replaced: removed.found }
}

function managedBlockText(text) {
  var source = String(text || "")
  var begins = lineIndexes(source, BLOCK_BEGIN)
  var ends = lineIndexes(source, BLOCK_END)
  if (begins.length !== 1 || ends.length !== 1 || ends[0] < begins[0]) return ""
  return source.split("\n").slice(begins[0], ends[0] + 1).join("\n")
}

// The user's own hl.monitor rules outside our block, in file order:
// [{ selector, mode }]. Resolves `local left = "desc:..."` variables.
// The catch-all (output = "") is left out.
// Parsing the file is the most expensive thing a plan does, and the plan is
// rebuilt on every edit while the file rarely changes: remember the last one.
var _rulesText = null
var _rulesValue = []

function findMonitorRules(luaText) {
  var key = String(luaText || "")
  if (key === _rulesText) return _rulesValue
  _rulesValue = readMonitorRules(key)
  _rulesText = key
  return _rulesValue
}

function readMonitorRules(luaText) {
  var source = stripLuaComments(removeManagedBlock(luaText).text)
  var locals = {}
  var assign = new RegExp("(?:^|[\\s;])local\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*=\\s*(" + LUA_STRING + ")", "g")
  var match
  while ((match = assign.exec(source)) !== null) locals[match[1]] = unquoteLua(match[2])
  var out = []
  var table = /hl\.monitor\s*\(\s*\{([^}]*)\}/g
  var outputField = new RegExp("\\boutput\\s*=\\s*(" + LUA_STRING + "|[A-Za-z_][A-Za-z0-9_]*)")
  var modeField = new RegExp("\\bmode\\s*=\\s*(" + LUA_STRING + ")")
  while ((match = table.exec(source)) !== null) {
    var output = outputField.exec(match[1])
    if (!output) continue
    var token = output[1]
    var first = token.charAt(0)
    var selector = (first === "\"" || first === "'") ? unquoteLua(token) : locals[token]
    if (typeof selector !== "string" || selector === "") continue
    var mode = modeField.exec(match[1])
    out.push({ selector: selector, mode: mode ? unquoteLua(mode[1]) : "" })
  }
  return out
}

function findMonitorSelectors(luaText) {
  var rules = findMonitorRules(luaText)
  var out = []
  var seen = {}
  for (var i = 0; i < rules.length; i++) {
    if (seen[rules[i].selector]) continue
    seen[rules[i].selector] = true
    out.push(rules[i].selector)
  }
  return out
}

// Hyprland matches desc: by prefix and everything else by connector.
function selectorMatches(selector, entry) {
  var s = String(selector || "")
  if (s === "") return false
  if (s.indexOf("desc:") === 0) {
    var wanted = s.substring(5).replace(/^\s+|\s+$/g, "")
    return wanted !== "" && String(entry.description || "").indexOf(wanted) === 0
  }
  return s === entry.name
}

function countMatches(selector, entries) {
  var count = 0
  for (var i = 0; i < entries.length; i++) if (selectorMatches(selector, entries[i])) count++
  return count
}

// Match by panel, not connector, which can change between boots:
//   1. a selector the user's rules already use for this display
//   2. desc:<description> when it singles out one display
//   3. the connector name
function selectorFor(entry, entries, knownSelectors) {
  var all = entries || [entry]
  var known = knownSelectors || []
  var byName = ""
  for (var i = 0; i < known.length; i++) {
    if (!selectorMatches(known[i], entry) || countMatches(known[i], all) !== 1) continue
    if (luaQuote(known[i]) === null) continue
    if (known[i].indexOf("desc:") === 0) return known[i]
    if (!byName) byName = known[i]
  }
  if (byName) return byName
  var byDescription = "desc:" + entry.description
  if (entry.description && luaQuote(byDescription) !== null && countMatches(byDescription, all) === 1)
    return byDescription
  return entry.name
}

// A configured rate within this of the chosen mode is kept as written:
// configs say @60 for a 59.95 Hz panel.
var CONFIGURED_REFRESH_TOLERANCE = 0.1

function configuredRefresh(entry, configuredRules) {
  var rules = configuredRules || []
  var kept = ""
  for (var i = 0; i < rules.length; i++) {
    if (!selectorMatches(rules[i].selector, entry)) continue
    var written = /^\s*(\d+)x(\d+)@(\d+(?:\.\d+)?)(?:Hz)?\s*$/.exec(String(rules[i].mode || ""))
    if (!written) continue
    if (parseInt(written[1], 10) !== entry.width || parseInt(written[2], 10) !== entry.height) continue
    if (Math.abs(parseFloat(written[3]) - entry.refresh) > CONFIGURED_REFRESH_TOLERANCE + 1e-9) continue
    kept = written[3]
  }
  return kept
}

function number(value) {
  return String(Model.roundTo(value, 4))
}

// The fields of one display's rule. Optional colour and sync settings are
// written only when the draft sets them, so the user's own rule keeps
// deciding everything OmniDisplay was not asked about.
//   opts.refreshText  rate as written in the user's own rule
//   opts.skipDisabled leave `disabled` out (the laptop panel: its on/off
//                     state belongs to Omarchy's internal-monitor toggle)
//   opts.reset        names of requests that were set and are not any more:
//                     Hyprland merges rules by output, so leaving a field out
//                     keeps the old value; these are written as the default
//   opts.sdrsaturation overrides the saturation (the VRR nudge, see Plan)
function ruleFields(entry, opts) {
  var o = opts || {}
  var fields = []
  if (entry.enabled === false) {
    if (!o.skipDisabled) fields.push("disabled = true")
    return fields
  }
  var refresh = /^\d+(?:\.\d+)?$/.test(String(o.refreshText || "")) ? String(o.refreshText) : Model.formatRefresh(entry.refresh)
  if (MODE_KEYWORDS.indexOf(entry.modeKeyword) >= 0) fields.push("mode = \"" + entry.modeKeyword + "\"")
  else if (modelineOk(entry.modeline)) fields.push("mode = \"modeline " + entry.modeline + "\"")
  else fields.push("mode = \"" + entry.width + "x" + entry.height + "@" + refresh + "\"")
  if (entry.mirror) {
    fields.push("position = \"auto\"")
    fields.push("scale = " + Model.formatScale(entry.scale))
    fields.push("mirror = " + luaQuote(entry.mirror))
  } else {
    fields.push("position = \"" + (POSITION_KEYWORDS.indexOf(entry.positionAuto) >= 0 ? entry.positionAuto
                                     : Math.round(entry.x) + "x" + Math.round(entry.y)) + "\"")
    fields.push("scale = " + Model.formatScale(entry.scale))
    fields.push("transform = " + (Number(entry.transform) || 0))
    // Hyprland merges rules by output: without this a display that was
    // mirroring keeps mirroring. Not for the laptop panel, whose mirroring
    // belongs to Omarchy's internal-monitor-mirror toggle.
    if (!o.skipMirror) fields.push("mirror = \"\"")
  }
  var reset = o.reset || []
  function resetting(name) { return reset.indexOf(name) >= 0 }
  if (isFinite(entry.vrr) && entry.vrr >= 0 && entry.vrr <= 3) fields.push("vrr = " + Math.round(entry.vrr))
  else if (resetting("vrr")) fields.push("vrr = -1")
  if (entry.bitdepth === 8 || entry.bitdepth === 10) fields.push("bitdepth = " + entry.bitdepth)
  else if (resetting("bitdepth")) fields.push("bitdepth = 8")
  if (entry.cmSet && CM_VALUES.indexOf(entry.cmSet) >= 0) fields.push("cm = \"" + entry.cmSet + "\"")
  else if (resetting("cmSet")) fields.push("cm = \"auto\"")
  if (Number(entry.sdrbrightness) > 0) fields.push("sdrbrightness = " + number(entry.sdrbrightness))
  else if (resetting("sdrbrightness")) fields.push("sdrbrightness = 1")
  if (o.sdrsaturation !== undefined) fields.push("sdrsaturation = " + String(Model.roundTo(o.sdrsaturation, 6)))
  else if (Number(entry.sdrsaturation) > 0) fields.push("sdrsaturation = " + number(entry.sdrsaturation))
  else if (resetting("sdrsaturation")) fields.push("sdrsaturation = 1")
  hdrFields(entry, resetting).forEach(function(f) { fields.push(f) })
  if (iccPathOk(entry.icc)) fields.push("icc = " + luaQuote(entry.icc))
  if (!o.skipDisabled) fields.push("disabled = false")
  return fields
}

var MODE_KEYWORDS = ["preferred", "highres", "highrr"]
var POSITION_KEYWORDS = ["auto", "auto-right", "auto-left", "auto-up", "auto-down"]

// A modeline as Hyprland takes it after the word "modeline": the pixel clock
// in MHz, eight timings, then sync flags. Numbers and known flags only.
function modelineOk(text) {
  return typeof text === "string"
    && /^\d{1,4}(\.\d{1,4})?( \d{1,5}){8}( [+-](hsync|vsync)| interlace| doublescan)*$/.test(text)
}

// HDR details, each with Hyprland's default for a reset. Kept in one table
// so the panel, the rules and the profiles agree on names and ranges.
var HDR_FIELDS = [
  { key: "supportsHdr", lua: "supports_hdr", min: -1, max: 1, int: true, def: -1 },
  { key: "supportsWideColor", lua: "supports_wide_color", min: -1, max: 1, int: true, def: -1 },
  { key: "sdrMaxLuminance", lua: "sdr_max_luminance", min: 1, max: 10000, int: true, def: 80 },
  { key: "sdrMinLuminance", lua: "sdr_min_luminance", min: 0, max: 50, int: false, def: 0.2 },
  { key: "maxLuminance", lua: "max_luminance", min: 1, max: 10000, int: true, def: -1 },
  { key: "maxAvgLuminance", lua: "max_avg_luminance", min: 1, max: 10000, int: true, def: -1 },
  { key: "minLuminance", lua: "min_luminance", min: 0, max: 50, int: false, def: -1 }
]
var SDR_EOTFS = ["default", "auto", "srgb", "gamma22", "gamma22force"]

// "Unset" is null for these (0 and -1 are real values for some).
function hdrValueOk(f, v) {
  return typeof v === "number" && isFinite(v) && v >= f.min && v <= f.max && (!f.int || Math.round(v) === v)
}

function hdrFields(entry, resetting) {
  var out = []
  for (var i = 0; i < HDR_FIELDS.length; i++) {
    var f = HDR_FIELDS[i]
    var v = entry[f.key]
    if (v !== null && v !== undefined && hdrValueOk(f, v)) out.push(f.lua + " = " + String(Model.roundTo(v, 4)))
    else if (resetting(f.key)) out.push(f.lua + " = " + String(f.def))
  }
  if (entry.sdrEotf && SDR_EOTFS.indexOf(entry.sdrEotf) >= 0) out.push("sdr_eotf = \"" + entry.sdrEotf + "\"")
  else if (resetting("sdrEotf")) out.push("sdr_eotf = \"default\"")
  return out
}

// The requests (sync, depth, colour, HDR details, ICC) set in `before` and
// not in `after`: these are written as defaults. ICC cannot be reset that
// way (Hyprland refuses an empty path), so it is reported separately.
var REQUEST_KEYS = ["vrr", "bitdepth", "cmSet", "sdrbrightness", "sdrsaturation", "sdrEotf",
                    "supportsHdr", "supportsWideColor", "sdrMaxLuminance", "sdrMinLuminance",
                    "maxLuminance", "maxAvgLuminance", "minLuminance"]

function isSet(key, v) {
  if (key === "vrr") return typeof v === "number" && v >= 0
  if (key === "bitdepth" || key === "sdrbrightness" || key === "sdrsaturation") return Number(v) > 0
  if (key === "cmSet" || key === "sdrEotf" || key === "icc") return typeof v === "string" && v !== ""
  return v !== null && v !== undefined
}

function resetsBetween(before, after) {
  var out = []
  if (!before || !after) return out
  for (var i = 0; i < REQUEST_KEYS.length; i++) {
    var k = REQUEST_KEYS[i]
    if (isSet(k, before[k]) && !isSet(k, after[k])) out.push(k)
  }
  return out
}

// An absolute path to an .icc or .icm file, nothing that could leave a Lua
// string or a line.
function iccPathOk(path) {
  return typeof path === "string" && /^\/[^\u0000-\u001f"\\]{1,250}\.(icc|icm)$/i.test(path)
}

function monitorRule(entry, selector, opts) {
  var output = luaQuote(selector)
  if (output === null) return null
  var fields = ruleFields(entry, opts)
  if (fields.length === 0) return ""
  return "hl.monitor({ output = " + output + ", " + fields.join(", ") + " })"
}

// Position only: merges into the display's existing rule. Used for the
// staging step and by the service when only positions drifted.
function positionRule(name, x, y) {
  return "hl.monitor({ output = " + luaQuote(name) + ", position = \"" + Math.round(x) + "x" + Math.round(y) + "\" })"
}

// Global options OmniDisplay offers, applied with hl.config and kept in the
// block like everything else.
var GLOBAL_OPTIONS = [
  { key: "misc.vrr", option: "misc:vrr", section: "misc", name: "vrr", type: "int", values: [0, 1, 2, 3],
    label: "Adaptive sync (default)", labels: ["Off", "On", "Fullscreen", "Games & video"],
    hint: "For displays without their own setting" },
  { key: "general.allow_tearing", option: "general:allow_tearing", section: "general", name: "allow_tearing", type: "bool",
    label: "Allow tearing", hint: "Lower latency for games that ask for it" },
  { key: "render.direct_scanout", option: "render:direct_scanout", section: "render", name: "direct_scanout", type: "int", values: [0, 1, 2],
    label: "Direct scan-out", labels: ["Off", "On", "Games only"], hint: "Fullscreen apps skip compositing" },
  { key: "render.cm_auto_hdr", option: "render:cm_auto_hdr", section: "render", name: "cm_auto_hdr", type: "int", values: [0, 1, 2],
    label: "Automatic HDR", labels: ["Off", "HDR", "HDR (EDID)"], hint: "Switch to HDR for fullscreen HDR content" },
  { key: "render.cm_enabled", option: "render:cm_enabled", section: "render", name: "cm_enabled", type: "bool",
    label: "Colour management", hint: "Off disables HDR and colour presets entirely" },
  { key: "render.cm_sdr_eotf", option: "render:cm_sdr_eotf", section: "render", name: "cm_sdr_eotf", type: "string",
    values: ["default", "srgb", "gamma22", "gamma22force"], labels: ["Default", "sRGB", "Gamma 2.2", "Gamma 2.2 (forced)"],
    label: "SDR transfer (default)", hint: "How SDR content is decoded in HDR" },
  { key: "render.non_shader_cm", option: "render:non_shader_cm", section: "render", name: "non_shader_cm", type: "int", values: [0, 1, 2, 3],
    label: "Hardware colour management", labels: ["Off", "Always", "On demand", "Ignore"], hint: "Let the display hardware convert colour when it can" },
  { key: "render.icc_vcgt_enabled", option: "render:icc_vcgt_enabled", section: "render", name: "icc_vcgt_enabled", type: "bool",
    label: "ICC calibration curves", hint: "Load the VCGT curves from ICC profiles" },
  { key: "cursor.no_hardware_cursors", option: "cursor:no_hardware_cursors", section: "cursor", name: "no_hardware_cursors", type: "int", values: [0, 1, 2],
    label: "Software cursor", labels: ["Off", "On", "Auto"], hint: "Draw the cursor in software (fixes glitches on some GPUs)" },
  { key: "cursor.no_break_fs_vrr", option: "cursor:no_break_fs_vrr", section: "cursor", name: "no_break_fs_vrr", type: "int", values: [0, 1, 2],
    label: "Keep VRR while the cursor moves", labels: ["Off", "On", "Games only"], hint: "Do not drop adaptive sync in fullscreen when the cursor moves" },
  { key: "quirks.prefer_hdr", option: "quirks:prefer_hdr", section: "quirks", name: "prefer_hdr", type: "int", values: [0, 1, 2],
    label: "Prefer HDR for apps", labels: ["Off", "Always", "Gamescope only"], hint: "Report HDR to apps that check before asking for it" }
]

function globalOption(key) {
  for (var i = 0; i < GLOBAL_OPTIONS.length; i++) if (GLOBAL_OPTIONS[i].key === key) return GLOBAL_OPTIONS[i]
  return null
}

function globalValueOk(key, value) {
  var g = globalOption(key)
  if (!g) return false
  if (g.type === "bool") return value === true || value === false
  return g.values.indexOf(value) >= 0
}

function globalLua(key, value) {
  var g = globalOption(key)
  if (!g || !globalValueOk(key, value)) return null
  return "hl.config({ " + g.section + " = { " + g.name + " = " + (g.type === "string" ? "\"" + value + "\"" : String(value)) + " } })"
}

function workspaceRule(rule) {
  var fields = ["workspace = " + luaQuote(String(rule.workspace)), "monitor = " + luaQuote(rule.monitor)]
  if (rule.isDefault) fields.push("default = true")
  if (rule.persistent) fields.push("persistent = true")
  return "hl.workspace_rule({ " + fields.join(", ") + " })"
}

// Rules for a whole draft. `entries` is every connected display; the
// internal panel's on/off is left to Omarchy's toggle.
function rulesFor(entries, knownSelectors, configuredRules, forFile, resets) {
  var lines = []
  for (var i = 0; i < entries.length; i++) {
    var e = entries[i]
    var selector = forFile ? selectorFor(e, entries, knownSelectors) : e.name
    var line = monitorRule(e, selector, {
      refreshText: forFile ? configuredRefresh(e, configuredRules) : "",
      skipDisabled: e.internal,
      skipMirror: e.internal,
      reset: forFile ? [] : ((resets && resets[e.name]) || [])
    })
    if (line === null) return null
    if (line !== "") lines.push(line)
  }
  return lines
}

// The current session by connector, for the fallback revert. The primary
// revert is `hyprctl reload`, which restores every option the file sets.
function revertLua(snapshot) {
  var lines = []
  for (var i = 0; i < (snapshot || []).length; i++) {
    var e = snapshot[i]
    if (!Model.SAFE_NAME.test(e.name)) return null
    var line = monitorRule(e, e.name, { skipDisabled: e.internal })
    if (line) lines.push(line)
  }
  return lines.join("\n")
}

// The table a rule line carries: `hl.monitor({ ... })` → `{ ... }`.
function ruleTable(line) {
  var m = /^hl\.(?:monitor|workspace_rule)\((\{ .* \})\)$/.exec(String(line || ""))
  return m ? m[1] : null
}

// Profiles for the other sets of displays, as Lua that Hyprland runs
// itself: at load, and whenever a display comes or goes, the profile whose
// displays are exactly the connected ones is applied. So every desk gets its
// layout at boot, before the shell starts, and after the plugin is removed.
// Everything runs under pcall: an error here must never break the config.
// `profiles`: [{ id, displays: [{ match, port }], rules: [line], workspaces: [line] }]
var PROFILES_HANDLER = [
  "-- Profiles for each set of displays. Hyprland applies the matching one at",
  "-- load and when a display comes or goes. Written by OmniDisplay.",
  "local function omnidisplay_profiles(profiles)",
  "  local function selects(sel, m)",
  "    if sel:sub(1, 5) == \"desc:\" then",
  "      local want = sel:sub(6)",
  "      return want ~= \"\" and (m.description or \"\"):sub(1, #want) == want",
  "    end",
  "    return m.name == sel",
  "  end",
  "  -- Enabled displays come from Hyprland; connected but disabled ones only",
  "  -- from sysfs. A virtual output has no connector, so unknown is not unplugged.",
  "  local function connected()",
  "    local known, plugged = {}, {}",
  "    local h = io.popen(\"for f in /sys/class/drm/card*-*/status; do c=${f%/status}; c=${c##*/}; read -r s < \\\"$f\\\"; echo \\\"${c#card*-} $s\\\"; done 2>/dev/null\")",
  "    if h then",
  "      for line in h:lines() do",
  "        local name, status = line:match(\"^(%S+) (%S+)$\")",
  "        if name then",
  "          known[name] = true",
  "          if status == \"connected\" then plugged[name] = true end",
  "        end",
  "      end",
  "      h:close()",
  "    end",
  "    local list, seen = {}, {}",
  "    for _, m in ipairs(hl.get_monitors()) do",
  "      if plugged[m.name] or not known[m.name] then",
  "        list[#list + 1] = { name = m.name, description = m.description, enabled = true }",
  "        seen[m.name] = true",
  "      end",
  "    end",
  "    for name in pairs(plugged) do",
  "      if not seen[name] then list[#list + 1] = { name = name, enabled = false } end",
  "    end",
  "    return list",
  "  end",
  "  local function matches(p, list)",
  "    if #p.displays ~= #list then return false end",
  "    local used = {}",
  "    for _, want in ipairs(p.displays) do",
  "      local found = false",
  "      for i, m in ipairs(list) do",
  "        if not used[i] and ((m.enabled and selects(want.match, m)) or (not m.enabled and m.name == want.port)) then",
  "          used[i] = true",
  "          found = true",
  "          break",
  "        end",
  "      end",
  "      if not found then return false end",
  "    end",
  "    return true",
  "  end",
  "  -- Applied only when the matching profile changes: turning a display off",
  "  -- fires the same events, and re-applying would undo that.",
  "  local current = nil",
  "  local function apply(force)",
  "    local list = connected()",
  "    for _, p in ipairs(profiles) do",
  "      if matches(p, list) then",
  "        if force or p.id ~= current then",
  "          current = p.id",
  "          for _, r in ipairs(p.rules) do hl.monitor(r) end",
  "          for _, w in ipairs(p.workspaces) do hl.workspace_rule(w) end",
  "        end",
  "        return",
  "      end",
  "    end",
  "    current = nil",
  "  end",
  "  pcall(apply, true)",
  "  if hl.on then",
  "    hl.on(\"monitor.added\", function() pcall(apply, false) end)",
  "    hl.on(\"monitor.removed\", function() pcall(apply, false) end)",
  "  end",
  "end"
].join("\n")

function profilesLua(profiles) {
  if (!profiles || !profiles.length) return ""
  var items = []
  for (var i = 0; i < profiles.length; i++) {
    var p = profiles[i]
    var id = luaQuote(p.id)
    if (id === null) return null
    var displays = []
    for (var d = 0; d < p.displays.length; d++) {
      var match = luaQuote(p.displays[d].match)
      var port = luaQuote(p.displays[d].port || "")
      if (match === null || port === null) return null
      displays.push("{ match = " + match + ", port = " + port + " }")
    }
    var rules = []
    for (var r = 0; r < p.rules.length; r++) {
      var t = ruleTable(p.rules[r])
      if (t === null) return null
      rules.push(t)
    }
    var ws = []
    for (var w = 0; w < p.workspaces.length; w++) {
      var wt = ruleTable(p.workspaces[w])
      if (wt === null) return null
      ws.push(wt)
    }
    items.push("  { id = " + id + ",\n    displays = { " + displays.join(", ") + " },\n    rules = {\n      "
               + rules.join(",\n      ") + "\n    },\n    workspaces = { " + ws.join(", ") + " } }")
  }
  return PROFILES_HANDLER + "\npcall(omnidisplay_profiles, {\n" + items.join(",\n") + "\n})"
}

function managedBlock(lines, note) {
  var head = [
    BLOCK_BEGIN,
    "-- Written by OmniDisplay. Edits inside this block are overwritten.",
    "-- Delete the whole block to fall back to the rules above it."
  ]
  if (note) head.push("-- " + String(note).replace(/[\r\n]+/g, " "))
  return head.concat(lines, [BLOCK_END]).join("\n")
}

// ------------------------------------------------------------ eval safety

// Every line handed to `hyprctl eval` must be one of ours. The control
// script repeats this check; both refuse anything else.
var EVAL_LINE = /^hl\.(monitor|workspace_rule)\(\{ [^\n]* \}\)$|^hl\.config\(\{ (general|render|misc|cursor|quirks) = \{ [a-z_]+ = (true|false|[0-9]|"[a-z0-9]+") \} \}\)$/
var EVAL_DENY = /\b(os|io|require|dofile|loadfile|load|loadstring|package|debug|exec_cmd)\b|\bhl\.dsp\b/

function isKnownGlobalLine(line) {
  for (var i = 0; i < GLOBAL_OPTIONS.length; i++) {
    var g = GLOBAL_OPTIONS[i]
    var values = g.type === "bool" ? [true, false] : g.values
    for (var k = 0; k < values.length; k++) if (globalLua(g.key, values[k]) === line) return true
  }
  return false
}

function evalLinesOk(text) {
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    if (lines[i] === "") continue
    var unquoted = lines[i].replace(new RegExp(LUA_STRING, "g"), "\"\"")
    if (!EVAL_LINE.test(lines[i]) || EVAL_DENY.test(unquoted)) return false
    if (lines[i].indexOf("hl.config(") === 0 && !isKnownGlobalLine(lines[i])) return false
  }
  return true
}

// ---------------------------------------------------------- foreign rules

// What other display plugins left in monitors.lua: their marked blocks, and
// single-line hl.monitor rules for one display (Better Displays appends
// these). Each item: { kind, label, start, end (line indexes), text }.
function findForeignRules(luaText) {
  var source = String(luaText || "")
  var lines = source.split("\n")
  var items = []
  var covered = {}
  var ours = removeManagedBlock(source)
  var oursBegin = lineIndexes(source, BLOCK_BEGIN)
  var oursEnd = lineIndexes(source, BLOCK_END)
  if (ours.found && oursBegin.length === 1 && oursEnd.length === 1)
    for (var o = oursBegin[0]; o <= oursEnd[0]; o++) covered[o] = true

  for (var f = 0; f < FOREIGN_BLOCKS.length; f++) {
    var b = lineIndexes(source, FOREIGN_BLOCKS[f].begin)
    var e = lineIndexes(source, FOREIGN_BLOCKS[f].end)
    if (b.length === 1 && e.length === 1 && e[0] > b[0]) {
      for (var k = b[0]; k <= e[0]; k++) covered[k] = true
      items.push({ kind: "block", label: FOREIGN_BLOCKS[f].plugin + " block", start: b[0], end: e[0],
                   text: lines.slice(b[0], e[0] + 1).join("\n") })
    }
  }
  var single = new RegExp("^\\s*hl\\.monitor\\(\\s*\\{[^}]*\\boutput\\s*=\\s*(" + LUA_STRING + ")[^}]*\\}\\s*\\)\\s*$")
  for (var i = 0; i < lines.length; i++) {
    if (covered[i]) continue
    var m = single.exec(lines[i])
    if (!m || unquoteLua(m[1]) === "") continue
    items.push({ kind: "rule", label: "Rule for " + unquoteLua(m[1]), start: i, end: i, text: lines[i] })
  }
  return items
}

// Removes the chosen items (by start line). Blank lines left doubled are
// collapsed so the file does not grow holes.
function removeForeign(luaText, items) {
  var lines = String(luaText || "").split("\n")
  var drop = {}
  for (var i = 0; i < (items || []).length; i++)
    for (var k = items[i].start; k <= items[i].end; k++) drop[k] = true
  var out = []
  for (var j = 0; j < lines.length; j++) {
    if (drop[j]) continue
    if (lines[j].trim() === "" && out.length && out[out.length - 1].trim() === "" && (drop[j - 1] || drop[j + 1])) continue
    out.push(lines[j])
  }
  return out.join("\n")
}

function utf8Length(text) {
  var s = String(text || "")
  var n = 0
  for (var i = 0; i < s.length; i++) {
    var c = s.charCodeAt(i)
    if (c < 0x80) n += 1
    else if (c < 0x800) n += 2
    else if (c >= 0xd800 && c <= 0xdbff) { n += 4; i++ }
    else n += 3
  }
  return n
}
