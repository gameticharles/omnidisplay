.pragma library
.import "Model.js" as Model
.import "Layout.js" as Layout
.import "Lua.js" as Lua
.import "Profiles.js" as Profiles

// Everything Apply and Keep will do, computed up front and side-effect free,
// so the panel can preview it, the tests can check it, and nothing runs that
// was not shown.

var CONFIRM_SECONDS = 15
// The detached watchdog outlives the countdown by this much, so the panel's
// own revert normally wins and the watchdog is only the dead-man's switch.
var WATCHDOG_GRACE_SECONDS = 3

function sameNumber(a, b) {
  return Math.abs(Number(a) - Number(b)) < 0.005
}

function entryChanges(before, after) {
  var out = []
  if (!before) return ["new display"]
  if ((before.enabled !== false) !== (after.enabled !== false))
    out.push(after.enabled === false ? "turned off" : "turned on")
  if (after.enabled === false) return out
  if ((before.mirror || "") !== (after.mirror || ""))
    out.push(after.mirror ? "mirrors " + after.mirror : "extends the desktop")
  if (before.width !== after.width || before.height !== after.height || !sameNumber(before.refresh, after.refresh))
    out.push("mode " + Model.modeKey(before.width, before.height, before.refresh) + " → " + Model.modeKey(after.width, after.height, after.refresh))
  if (!Model.sameScale(before.scale, after.scale))
    out.push("scale " + Model.normalizeScale(before.scale) + " → " + Model.normalizeScale(after.scale))
  if ((Number(before.transform) || 0) !== (Number(after.transform) || 0))
    out.push("rotation " + Model.transformLabel(before.transform) + " → " + Model.transformLabel(after.transform))
  if (!after.mirror && (before.x !== after.x || before.y !== after.y))
    out.push("position " + before.x + "x" + before.y + " → " + after.x + "x" + after.y)
  if (after.vrr >= 0 && after.vrr !== before.vrr) out.push("adaptive sync " + vrrLabel(after.vrr))
  if (after.bitdepth && after.bitdepth !== before.bitdepth) out.push(after.bitdepth + "-bit colour")
  if (after.cmSet && after.cmSet !== before.cmSet) out.push("colour " + after.cmSet)
  if (after.sdrbrightness > 0 && !sameNumber(after.sdrbrightness, before.sdrbrightness))
    out.push("SDR brightness " + Model.roundTo(after.sdrbrightness, 2))
  if (after.sdrsaturation > 0 && !sameNumber(after.sdrsaturation, before.sdrsaturation))
    out.push("SDR saturation " + Model.roundTo(after.sdrsaturation, 2))
  if ((after.icc || "") !== (before.icc || "")) out.push(after.icc ? "ICC profile " + after.icc.split("/").pop() : "no ICC profile")
  if ((after.modeKeyword || "") !== (before.modeKeyword || "")) out.push(after.modeKeyword ? "mode " + after.modeKeyword : "exact mode")
  if ((after.positionAuto || "") !== (before.positionAuto || "")) out.push(after.positionAuto ? "position " + after.positionAuto : "fixed position")
  if ((after.modeline || "") !== (before.modeline || "") && after.modeline) out.push("EDID timing")
  if ((after.sdrEotf || "") !== (before.sdrEotf || "")) out.push("SDR transfer " + (after.sdrEotf || "default"))
  for (var h = 0; h < Lua.HDR_FIELDS.length; h++) {
    var f = Lua.HDR_FIELDS[h]
    var a = after[f.key], b = before[f.key]
    if ((a === null || a === undefined) !== (b === null || b === undefined) || (a !== null && a !== undefined && a !== b))
      out.push(f.lua.replace(/_/g, " ") + " " + (a === null || a === undefined ? "default" : a))
  }
  return out
}

function vrrLabel(v) {
  for (var i = 0; i < Model.VRR_MODES.length; i++) if (Model.VRR_MODES[i].value === v) return Model.VRR_MODES[i].label.toLowerCase()
  return String(v)
}

function draftChanges(snapshot, draft) {
  var out = []
  for (var i = 0; i < (draft || []).length; i++) {
    var changes = entryChanges(Model.entryByName(snapshot, draft[i].name), draft[i])
    if (changes.length) out.push({ name: draft[i].name, changes: changes })
  }
  return out
}

function hasChanges(snapshot, draft) {
  return draftChanges(snapshot, draft).length > 0
}

// Errors block Apply; warnings are shown but do not.
function validateDraft(draft) {
  var errors = []
  var warnings = []
  if (!draft || draft.length === 0) {
    errors.push({ code: "empty", message: "No displays to arrange" })
    return { ok: false, errors: errors, warnings: warnings }
  }
  var names = {}
  var onCount = 0
  for (var i = 0; i < draft.length; i++) {
    var e = draft[i]
    if (!Model.SAFE_NAME.test(e.name)) errors.push({ code: "bad-name", message: "Unsafe output name: " + JSON.stringify(e.name) })
    if (names[e.name]) errors.push({ code: "duplicate", message: "Duplicate output: " + e.name })
    names[e.name] = true
    if (e.enabled === false) continue
    if (!e.mirror) onCount++
    if (e.modeKeyword) {
      // Hyprland picks the mode; nothing to check here.
    } else if (e.modeline) {
      if (!Lua.modelineOk(e.modeline)) errors.push({ code: "bad-mode", message: e.name + " has an unusable modeline" })
    } else if (e.customMode) {
      if (!(e.width >= 320 && e.width <= 16384 && e.height >= 200 && e.height <= 16384 && e.refresh >= 1 && e.refresh <= 500))
        errors.push({ code: "bad-mode", message: e.name + ": " + Model.modeKey(e.width, e.height, e.refresh) + " is not a usable custom mode" })
    } else if (e.modes && e.modes.length && !Model.hasMode(e, e.width, e.height, e.refresh))
      errors.push({ code: "bad-mode", message: e.name + " does not offer " + Model.modeKey(e.width, e.height, e.refresh) })
    var clean = Model.cleanScale(e.scale, e.width, e.height)
    if (!(clean > 0) || !Model.sameScale(clean, e.scale))
      errors.push({ code: "bad-scale", message: e.name + " scale " + Model.normalizeScale(e.scale) + " does not divide " + e.width + "x" + e.height + " cleanly" })
    if (e.mirror) {
      var target = Model.entryByName(draft, e.mirror)
      if (!target || target.name === e.name) errors.push({ code: "bad-mirror", message: e.name + " mirrors a display that is not connected" })
      else if (target.enabled === false || target.mirror) errors.push({ code: "bad-mirror", message: e.name + " mirrors " + target.name + ", which is " + (target.mirror ? "itself a mirror" : "off") })
    }
  }
  if (onCount === 0) errors.push({ code: "all-off", message: "At least one display has to stay on and show the desktop" })
  var arranged = draft.filter(Model.isArrangeable)
  var pairs = Layout.overlappingPairs(arranged)
  for (var p = 0; p < pairs.length; p++) errors.push({ code: "overlap", message: pairs[p][0] + " overlaps " + pairs[p][1] })
  if (!Layout.isConnected(arranged)) warnings.push({ code: "gap", message: "Some displays do not touch. The pointer cannot cross the gap" })
  return { ok: errors.length === 0, errors: errors, warnings: warnings }
}

// options:
//   snapshot        live entries (Model.parseMonitors)
//   draft           edited entries, same displays
//   fileText        monitors.lua as read
//   fileState       "present" | "missing" | "toolarge" | "unreadable"
//   persist         write the managed block on Keep
//   workspaces      a Profiles workspace plan, or null
//   liveWorkspaces  `hyprctl workspaces -j`
//   laptopMode      "" or a Profiles laptop mode to carry out with this apply
//   note            one line for the block header (the profile name)
function buildPlan(options) {
  var o = options || {}
  var snapshot = o.snapshot || []
  var draft = o.draft || []
  var commands = []
  var revertCommands = []
  if (o.laptopMode) {
    var mode = Profiles.applyLaptopMode(draft, o.laptopMode)
    draft = mode.draft
    commands = mode.commands
    revertCommands = revertCommandsFor(snapshot)
  }
  draft = Profiles.normalizeDraft(draft)
  var fileText = String(o.fileText || "")
  var fileState = String(o.fileState || "missing")
  var check = validateDraft(draft)
  var plan = {
    ok: false, errors: check.errors.slice(), warnings: check.warnings.slice(),
    draft: draft, changes: draftChanges(snapshot, draft),
    applyLua: "", moves: [], commands: commands, revertCommands: revertCommands, revertLua: "",
    block: "", fileText: "", fileOriginal: fileText, fileState: fileState,
    canPersist: false, workspaceRules: [], turnsOff: false, reloadFirst: false
  }

  // Global options: what changes now, how to put it back, and all of them
  // for the file.
  var globals = o.globals || {}
  var liveGlobals = o.liveGlobals || {}
  var globalLines = []
  var globalRevert = []
  var globalFile = []
  for (var gi = 0; gi < Lua.GLOBAL_OPTIONS.length; gi++) {
    var g = Lua.GLOBAL_OPTIONS[gi]
    if (globals[g.key] === undefined || !Lua.globalValueOk(g.key, globals[g.key])) continue
    globalFile.push(Lua.globalLua(g.key, globals[g.key]))
    if (liveGlobals[g.key] === globals[g.key]) continue
    globalLines.push(Lua.globalLua(g.key, globals[g.key]))
    if (Lua.globalValueOk(g.key, liveGlobals[g.key])) globalRevert.push(Lua.globalLua(g.key, liveGlobals[g.key]))
    plan.changes.push({ name: "Global", changes: [g.label + ": " + globalValueLabel(g, globals[g.key])] })
  }

  // Workspace rules cannot be taken back live, only by a reload: when a
  // plan replaces one that had rules, reload first, then apply.
  var previous = Profiles.cleanWorkspaces(o.previousWorkspaces)
  if (o.workspaces && previous.strategy !== "off"
      && JSON.stringify(Profiles.cleanWorkspaces(o.workspaces)) !== JSON.stringify(previous))
    plan.reloadFirst = true
  if (o.laptopMode && Profiles.currentLaptopMode(snapshot) !== o.laptopMode)
    plan.changes.push({ name: "Laptop", changes: [Profiles.laptopModeLabel(o.laptopMode)] })

  // A display going dark, or every external one, deserves the countdown
  // most; the panel uses this to say so.
  for (var i = 0; i < draft.length; i++) {
    var before = Model.entryByName(snapshot, draft[i].name)
    if (before && before.enabled !== false && draft[i].enabled === false) plan.turnsOff = true
  }

  var wsPlan = o.workspaces ? Profiles.planWorkspaces(draft, o.workspaces) : []
  plan.workspaceRules = wsPlan
  plan.moves = Profiles.workspaceMoves(wsPlan, o.liveWorkspaces)

  // Requests that were set and are not any more go out as defaults, and a
  // change to adaptive sync alone goes out twice: Hyprland treats a rule
  // that differs only in `vrr` as unchanged (its rule compare skips it), so
  // the first send carries a harmless saturation nudge and the second, half
  // a second later, the real values. The revert does the same.
  var base = o.base || snapshot
  var resets = {}
  var vrrChanged = []
  var iccCleared = false
  for (var ri = 0; ri < draft.length; ri++) {
    var was = Model.entryByName(base, draft[ri].name)
    if (!was || draft[ri].enabled === false) continue
    resets[draft[ri].name] = Lua.resetsBetween(was, draft[ri])
    if ((was.icc || "") !== "" && (draft[ri].icc || "") === "") iccCleared = true
    var wasVrr = isFinite(was.vrr) ? was.vrr : -1
    var nowVrr = isFinite(draft[ri].vrr) ? draft[ri].vrr : -1
    if (wasVrr !== nowVrr) vrrChanged.push(draft[ri].name)
  }
  if (iccCleared) plan.reloadFirst = true

  var configured = fileState === "present" ? Lua.findMonitorRules(fileText) : []
  var known = fileState === "present" ? Lua.findMonitorSelectors(fileText) : []

  // Live rules by connector; staging first when a direct move would make two
  // displays overlap on the way.
  var live = Lua.rulesFor(draft, [], [], false, resets)
  var revert = Lua.revertLua(snapshot)
  plan.applyLater = ""
  plan.revertLater = ""
  if (live !== null && vrrChanged.length) {
    var nudged = []
    var later = []
    var revertNudged = []
    var revertLater = []
    for (var vi = 0; vi < draft.length; vi++) {
      var e = draft[vi]
      if (vrrChanged.indexOf(e.name) < 0) { nudged.push(live[vi]); continue }
      var sat = Number(e.sdrsaturation) > 0 ? Number(e.sdrsaturation) : 1
      var opts = { skipDisabled: e.internal, skipMirror: e.internal, reset: resets[e.name] || [] }
      nudged.push(Lua.monitorRule(e, e.name, Object.assign({ sdrsaturation: sat + 0.0001 }, opts)))
      later.push(Lua.monitorRule(e, e.name, Object.assign({ sdrsaturation: sat }, opts)))
      var back = Model.entryByName(base, e.name)
      if (back) {
        var backEntry = Object.assign({}, Model.entryByName(snapshot, e.name) || back, { vrr: isFinite(back.vrr) ? back.vrr : -1 })
        var bsat = Number(back.sdrsaturation) > 0 ? Number(back.sdrsaturation) : 1
        var bopts = { skipDisabled: backEntry.internal, skipMirror: backEntry.internal, reset: backEntry.vrr < 0 ? ["vrr"] : [] }
        revertNudged.push(Lua.monitorRule(backEntry, e.name, Object.assign({ sdrsaturation: bsat + 0.0001 }, bopts)))
        revertLater.push(Lua.monitorRule(backEntry, e.name, Object.assign({ sdrsaturation: bsat }, bopts)))
      }
    }
    live = nudged
    plan.applyLater = later.join("\n")
    if (revert) revert = [revert].concat(revertNudged).join("\n")
    plan.revertLater = revertLater.join("\n")
  }
  if (live === null) plan.errors.push({ code: "bad-selector", message: "A display description cannot be written safely" })
  if (revert === null || revert === "") plan.errors.push({ code: "no-revert", message: "Cannot build a revert for the current session" })
  if (plan.errors.length) return plan

  var arrangedBefore = snapshot.filter(Model.isArrangeable)
  var arrangedAfter = draft.filter(Model.isArrangeable)
  var lines = []
  if (Layout.needsStaging(arrangedBefore, arrangedAfter)) {
    var park = Layout.stagingX(arrangedBefore, arrangedAfter)
    var y = 0
    for (var s = 0; s < arrangedAfter.length; s++) {
      lines.push(Lua.positionRule(arrangedAfter[s].name, park, y))
      y += Model.logicalSize(arrangedAfter[s]).height + 100
    }
  }
  lines = lines.concat(live).concat(globalLines)
  for (var w = 0; w < wsPlan.length; w++)
    lines.push(Lua.workspaceRule({ workspace: wsPlan[w].workspace, monitor: wsPlan[w].name,
                                   isDefault: wsPlan[w].isDefault, persistent: wsPlan[w].persistent }))
  plan.applyLua = lines.join("\n")
  plan.revertLua = [revert].concat(globalRevert).join("\n")
  if (!Lua.evalLinesOk(plan.applyLua) || !Lua.evalLinesOk(plan.revertLua)
      || !Lua.evalLinesOk(plan.applyLater) || !Lua.evalLinesOk(plan.revertLater)) {
    plan.errors.push({ code: "unsafe-lua", message: "Refusing to run Lua that is not a plain monitor rule" })
    return plan
  }

  // A cast's virtual output (Model.isVirtual) keeps a rule only
  // when it mirrors: saving it a reload brings the mirror back, while a kept
  // "off" switched the next cast's screen off under a streaming TV.
  var fileRules = Lua.rulesFor(draft.filter(function(e) { return !Model.isVirtual(e) || (e.enabled !== false && !!e.mirror) }), known, configured, true)
  var ids = Model.identityKeys(draft)
  for (var r = 0; r < wsPlan.length; r++) {
    var target = Model.entryByName(draft, wsPlan[r].name)
    fileRules.push(Lua.workspaceRule({ workspace: wsPlan[r].workspace,
                                       monitor: Lua.selectorFor(target, draft, known),
                                       isDefault: wsPlan[r].isDefault, persistent: wsPlan[r].persistent }))
  }
  // With the store, the block also carries every saved profile (applied by
  // Hyprland itself at load and on hotplug) and rules for remembered
  // monitors that are not connected; they go first, so the rules for the
  // displays here now win.
  var extra = []
  var profilesText = ""
  if (o.store) {
    extra = Profiles.memoryRules(o.store, draft)
    profilesText = Lua.profilesLua(Profiles.luaProfiles(o.store))
    if (profilesText === null) {
      plan.warnings.push({ code: "profiles-lua", message: "A saved profile cannot be written safely; profiles are left out of the file" })
      profilesText = ""
    }
  }
  var blockLines = extra.length ? ["-- Remembered displays that are not connected now"].concat(extra, [""], fileRules) : fileRules
  blockLines = blockLines.concat(globalFile)
  if (profilesText) blockLines = blockLines.concat(["", profilesText])
  plan.block = Lua.managedBlock(blockLines, o.note || "")

  if (!o.persist) {
    plan.ok = true
    return plan
  }
  if (fileState === "toolarge") {
    plan.warnings.push({ code: "file-too-large", message: "monitors.lua is over " + Math.floor(Lua.MAX_FILE_BYTES / 1024) + " KiB. Keep will not save it" })
  } else if (fileState !== "present" && fileState !== "missing") {
    plan.warnings.push({ code: "file-unreadable", message: "monitors.lua cannot be read. Keep will not save it" })
  } else {
    var upsert = Lua.upsertManagedBlock(fileState === "present" ? fileText : "", plan.block)
    if (!upsert.ok) plan.warnings.push({ code: "file-markers", message: upsert.error })
    else if (Lua.utf8Length(upsert.text) > Lua.MAX_FILE_BYTES)
      plan.warnings.push({ code: "file-too-large", message: "monitors.lua would grow past " + Math.floor(Lua.MAX_FILE_BYTES / 1024) + " KiB. Keep will not save it" })
    else {
      plan.fileText = upsert.text
      plan.canPersist = true
    }
  }
  plan.ok = true
  return plan
}

function globalValueLabel(g, value) {
  if (g.type === "bool") return value ? "on" : "off"
  var i = g.values.indexOf(value)
  return i >= 0 && g.labels ? g.labels[i].toLowerCase() : String(value)
}

// Puts Omarchy's laptop toggles back the way the snapshot had them.
function revertCommandsFor(snapshot) {
  var mode = Profiles.currentLaptopMode(snapshot)
  if (!mode) return []
  return Profiles.applyLaptopMode(snapshot, mode).commands
}

// ------------------------------------------------------------ layout health

// What is wrong with an arrangement as a whole, and a draft that repairs it:
// overlapping or stranded displays are re-seated flush, broken mirrors are
// turned into extended displays, and the layout starts at 0x0 again.
function layoutHealth(entries) {
  var issues = []
  var arranged = (entries || []).filter(Model.isArrangeable)
  var pairs = Layout.overlappingPairs(arranged)
  for (var i = 0; i < pairs.length; i++) issues.push({ code: "overlap", message: pairs[i][0] + " overlaps " + pairs[i][1] })
  if (!Layout.isConnected(arranged)) issues.push({ code: "gap", message: "Some displays do not touch, so the pointer cannot cross between them" })
  for (var k = 0; k < (entries || []).length; k++) {
    var e = entries[k]
    if (!e.mirror || e.enabled === false) continue
    var t = Model.entryByName(entries, e.mirror)
    if (!t || t.enabled === false || t.mirror) issues.push({ code: "mirror", message: e.name + " mirrors " + e.mirror + ", which is " + (!t ? "gone" : t.mirror ? "a mirror itself" : "off") })
  }
  if (arranged.length) {
    var b = Layout.layoutBounds(arranged)
    if (b.x !== 0 || b.y !== 0) issues.push({ code: "origin", message: "The layout does not start at 0×0 (some apps place windows wrongly)" })
  }
  return issues
}

function repairDraft(entries) {
  var out = Model.cloneList(entries || [])
  for (var k = 0; k < out.length; k++) {
    if (!out[k].mirror) continue
    var t = Model.entryByName(out, out[k].mirror)
    if (!t || t.enabled === false || t.mirror) out[k].mirror = ""
  }
  var arranged = out.filter(Model.isArrangeable)
  // Re-seat each display that overlaps one placed before it.
  for (var i = 1; i < arranged.length; i++) {
    var others = arranged.slice(0, i)
    var clash = false
    for (var j = 0; j < others.length; j++) if (Layout.rectsOverlap(Layout.rectOf(arranged[i]), Layout.rectOf(others[j]))) clash = true
    if (clash) arranged = Layout.dropMonitor(arranged, arranged[i].name, arranged[i].x, arranged[i].y, 0)
  }
  arranged = Layout.normalizeLayout(Layout.closeGaps(arranged, arranged.length ? arranged[0].name : ""))
  for (var m = 0; m < out.length; m++) {
    var p = Model.entryByName(arranged, out[m].name)
    if (p) { out[m].x = p.x; out[m].y = p.y }
  }
  return out
}

// ---------------------------------------------------------- what to verify

// Fields Hyprland may refuse or round. Compared after an apply, so a
// refused change reverts at once instead of asking to be kept.
// opts.laptopMode: Omarchy's toggles changed the built-in panel (off, or
// mirrored) and Hyprland moved the others to suit, so on/off, mirroring and
// positions are theirs to decide, not ours to check.
function verifyApplied(draft, live, opts) {
  var problems = []
  var mode = opts && opts.laptopMode ? opts.laptopMode : ""
  for (var i = 0; i < draft.length; i++) {
    var want = draft[i]
    var got = Model.entryByName(live, want.name)
    if (!got) continue
    if (mode && (want.internal || mode === "mirror" || mode === "external-only")) {
      if (want.enabled === false || got.enabled === false || got.mirror) continue
      if (got.width !== want.width || got.height !== want.height || Math.abs(got.refresh - want.refresh) > 0.6)
        problems.push(want.name + " runs " + Model.modeKey(got.width, got.height, got.refresh) + ", not " + Model.modeKey(want.width, want.height, want.refresh))
      continue
    }
    if (want.internal && (want.enabled === false) !== (got.enabled === false)) continue
    if ((want.enabled === false) !== (got.enabled === false)) {
      problems.push(want.name + " is " + (got.enabled === false ? "off" : "on"))
      continue
    }
    if (want.enabled === false) continue
    if (want.mirror && got.mirror !== want.mirror) problems.push(want.name + " is not mirroring " + want.mirror)
    if (!want.modeKeyword && (got.width !== want.width || got.height !== want.height
        || Math.abs(got.refresh - want.refresh) > (want.modeline ? 1.5 : 0.6)))
      problems.push(want.name + " runs " + Model.modeKey(got.width, got.height, got.refresh) + ", not " + Model.modeKey(want.width, want.height, want.refresh))
    if (!want.modeKeyword && !Model.sameScale(got.scale, want.scale))
      problems.push(want.name + " scale is " + Model.normalizeScale(got.scale) + ", not " + Model.normalizeScale(want.scale))
    if ((got.transform || 0) !== (want.transform || 0))
      problems.push(want.name + " rotation is " + Model.transformLabel(got.transform))
    if (!want.mirror && !want.positionAuto && !want.modeKeyword && (got.x !== want.x || got.y !== want.y))
      problems.push(want.name + " sits at " + got.x + "x" + got.y + ", not " + want.x + "x" + want.y)
    if (want.bitdepth && got.liveBitdepth !== want.bitdepth) problems.push(want.name + " stayed at " + got.liveBitdepth + "-bit")
    if (want.cmSet && want.cmSet !== "auto" && got.cm && got.cm !== want.cmSet) problems.push(want.name + " colour is " + got.cm + ", not " + want.cmSet)
  }
  return problems
}

// ------------------------------------------------------------- countdown

function confirmState(startedMs, nowMs, seconds) {
  var total = (Number(seconds) > 0 ? Number(seconds) : CONFIRM_SECONDS) * 1000
  var elapsed = Math.max(0, Number(nowMs) - Number(startedMs))
  var left = Math.max(0, total - elapsed)
  return { remaining: Math.ceil(left / 1000), expired: left <= 0, progress: Math.min(1, elapsed / total) }
}

function watchdogSeconds(seconds) {
  return (Number(seconds) > 0 ? Number(seconds) : CONFIRM_SECONDS) + WATCHDOG_GRACE_SECONDS
}

// ---------------------------------------------------------------- preview

function indent(text) {
  return String(text || "").split("\n").map(function(line) { return "  " + line }).join("\n")
}

function planPreview(plan, seconds) {
  if (!plan) return ""
  var out = []
  var i
  if (plan.errors.length) {
    out.push("BLOCKED")
    for (i = 0; i < plan.errors.length; i++) out.push("  " + plan.errors[i].message)
    out.push("")
  }
  for (i = 0; i < plan.warnings.length; i++) out.push("warning: " + plan.warnings[i].message)
  if (plan.warnings.length) out.push("")
  out.push("CHANGES")
  if (plan.changes.length === 0) out.push("  none")
  for (i = 0; i < plan.changes.length; i++) out.push("  " + plan.changes[i].name + ": " + plan.changes[i].changes.join(", "))
  if (!plan.ok) return out.join("\n")
  out.push("", "APPLY (hyprctl eval, live only)")
  if (plan.reloadFirst) out.push("  hyprctl reload   (clears the old workspace rules first)")
  out.push(indent(plan.applyLua))
  for (i = 0; i < plan.commands.length; i++) out.push("  " + plan.commands[i].join(" "))
  for (i = 0; i < plan.moves.length; i++) out.push("  move workspace " + plan.moves[i].workspace + " to " + plan.moves[i].name)
  out.push("", "REVERT (after " + (seconds || CONFIRM_SECONDS) + "s without Keep)", "  hyprctl reload")
  for (i = 0; i < plan.revertCommands.length; i++) out.push("  " + plan.revertCommands[i].join(" "))
  out.push("  if the reload fails, hyprctl eval:", indent(indent(plan.revertLua)))
  out.push("", "KEEP")
  out.push(plan.canPersist ? indent(plan.block) : "  saved as a profile only (monitors.lua is not written)")
  return out.join("\n")
}
