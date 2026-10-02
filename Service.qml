import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "lib/Model.js" as Model
import "lib/Layout.js" as Layout
import "lib/Lua.js" as Lua
import "lib/Profiles.js" as Profiles
import "lib/Plan.js" as Plan
import "lib/Cast.js" as Cast
import "lib/Menu.js" as Menu
import "components"

// OmniDisplay's one instance. Omarchy builds a bar, and so a widget, per
// monitor; everything that must exist once lives here: the live state, the
// draft being edited, the apply/keep/revert engine and its countdown, the
// profile restore on hotplug, the IPC targets, cast and tablet sessions, and
// the overlays drawn on every screen. The widgets only render this state and
// call these functions.
Item {
  id: root
  width: 0
  height: 0
  visible: false

  // Injected by omarchy-shell.
  property var shell: null
  property var manifest: null

  readonly property string pluginId: "omnidisplay"
  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string ctl: pluginDir + "/bin/omnidisplay-ctl"
  readonly property string castCtl: pluginDir + "/bin/omnidisplay-cast"
  readonly property string vncCtl: pluginDir + "/bin/omnidisplay-vnc"
  readonly property string home: Quickshell.env("HOME")
  readonly property string storePath: home + "/.config/omarchy/omnidisplay/profiles.json"
  readonly property string runDir: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/omnidisplay"

  // ------------------------------------------------------------- settings
  // Pushed by the bar widget from its shell.json entry (see manifest schema).

  property int confirmSeconds: 15
  property string persistMode: "block+service"
  property bool autoProfilesSetting: true
  // The Profiles tab's switch overrides the widget setting when used.
  readonly property bool autoProfiles: store.prefs && store.prefs.autoProfiles !== undefined ? store.prefs.autoProfiles : autoProfilesSetting

  function setAutoProfiles(on) {
    var next = Object.assign({}, store.prefs || {})
    next.autoProfiles = !!on
    writeStore(Profiles.setPrefs(store, next))
    if (on) scheduleRestore()
  }
  property int backupsKept: 10
  property bool notifications: true
  property bool presentationAuto: false
  property bool useDdc: true
  property int snapThreshold: 48
  property bool identifyOnOpen: false
  property int panelWidth: 600

  function applySettings(s) {
    function get(k, d) { return s && s[k] !== undefined && s[k] !== null ? s[k] : d }
    confirmSeconds = Math.max(5, Math.min(60, Number(get("confirmSeconds", 15)) || 15))
    var pm = get("persistMode", "block+service")
    persistMode = pm === "service-only" || pm === "state-file" ? pm : "block+service"
    autoProfilesSetting = get("autoProfiles", true) !== false
    backupsKept = Math.max(1, Math.min(50, Number(get("backupsKept", 10)) || 10))
    notifications = get("notifications", true) !== false
    presentationAuto = get("presentationMode", false) === true
    useDdc = get("ddc", true) !== false
    snapThreshold = Math.max(0, Math.min(400, Number(get("snapThreshold", 48)) || 0))
    identifyOnOpen = get("identifyOnOpen", false) === true
    panelWidth = ({ compact: 480, comfortable: 600, wide: 720 })[get("panelWidth", "comfortable")] || 600
  }

  // ----------------------------------------------------------- live state

  property var monitors: []
  property var workspaces: []
  property string fileText: ""
  property string fileState: "missing"
  property string fileSha: "-"
  // Connectors the kernel reports plugged in. One Hyprland does not list at
  // all has no usable signal (it failed to come up).
  property var connectedPorts: []
  readonly property var noSignal: connectedPorts.filter(function(p) { return !Model.entryByName(monitors, p) })

  // The state-file save target (Omarchy's toggles folder), when used.
  property string stateText: ""
  property string stateState: "missing"
  property string stateSha: "-"
  property bool loaded: false
  property var store: Profiles.emptyStore()
  property bool storeLoaded: false

  readonly property var activeProfile: Profiles.profileFor(store, monitors)
  readonly property string laptopMode: Profiles.currentLaptopMode(monitors)
  readonly property bool hasLaptopChoice: !!Model.internalDisplay(monitors) && Model.externalDisplays(monitors).length > 0
  // Focus comes from Quickshell's Hyprland model, so a focus change needs no
  // new read of the monitors.
  readonly property string focusedName: Hyprland.focusedMonitor ? String(Hyprland.focusedMonitor.name || "") : ""
  readonly property var focusedMonitor: {
    var byName = Model.entryByName(monitors, focusedName)
    if (byName) return byName
    for (var i = 0; i < monitors.length; i++) if (monitors[i].focused) return monitors[i]
    return monitors.length ? monitors[0] : null
  }
  readonly property int enabledCount: Model.enabledCount(monitors)
  readonly property bool blockInMonitors: Lua.managedBlockText(fileText) !== ""
  readonly property bool blockInState: stateState === "present" && Lua.managedBlockText(stateText) !== ""
  readonly property bool blockPresent: persistMode === "state-file" ? blockInState : blockInMonitors
  // Left over after switching where kept settings go.
  readonly property bool staleMonitorsBlock: persistMode !== "block+service" && blockInMonitors
  readonly property bool staleStateFile: persistMode !== "state-file" && stateState === "present"
  // The block went missing (`omarchy refresh hyprland` resets monitors.lua)
  // while a profile is in force: offered back in the panel.
  property bool blockNoticeDismissed: false
  readonly property bool blockMissing: loaded && persistMode !== "service-only" && !!activeProfile
                                       && (fileState === "present" || fileState === "missing") && !blockPresent
                                       && !blockNoticeDismissed
  readonly property var nearestProfile: activeProfile ? null : Profiles.nearestProfile(store, monitors)
  readonly property var foreignRules: fileState === "present" ? Lua.findForeignRules(fileText) : []

  // ---------------------------------------------------------------- draft

  property var draft: []
  property string selected: ""
  property var draftWorkspaces: null
  property string draftLaptopMode: ""
  property var draftGlobals: ({})
  property var liveGlobals: ({})
  readonly property var selectedEntry: Model.entryByName(draft, selected)
  readonly property var draftPlan: draft.length ? planFor(draft, { workspaces: draftWorkspaces, laptopMode: draftLaptopMode }) : null
  readonly property bool dirty: !!draftPlan && (draftPlan.changes.length > 0 || draftPlan.moves.length > 0 || workspacePlanEdited())

  // ------------------------------------------------------- pending change

  property string phase: ""          // "", "applying", "confirm", "keeping", "reverting"
  property var pendingPlan: null
  property string token: ""
  property double startedMs: 0
  property int remaining: 0
  property real progress: 0
  property var problems: []
  property bool keepFailed: false
  property var messages: []          // [{ level: "error"|"info", text }]

  // ------------------------------------------------------- other surfaces

  property var castState: Cast.parseState("")
  property bool castViewOpen: false
  property var vncState: ({ installed: false, qrencode: false, running: false, session: {}, addresses: [], port: 5900 })
  property string qrPath: ""
  property int qrRevision: 0
  property var backups: []
  property var edidCaps: ({})
  property var edidModes: ({})
  property var ddcBuses: ({})
  property var ddcValues: ({})
  property bool ddcDetected: false
  property var nightState: ({ available: false, enabled: false, temperature: 6500 })
  property bool presenting: false
  property var terminalFonts: []
  property int panelsOpen: 0

  // ============================================================== running

  Component {
    id: runnerComponent
    Runner {}
  }

  // Runs argv once; `input` (when not undefined) goes to stdin.
  function run(argv, input, callback) {
    var p = runnerComponent.createObject(root, {
      command: argv,
      input: input === undefined || input === null ? "" : String(input),
      hasInput: input !== undefined && input !== null,
      callback: callback || null
    })
    if (p) p.running = true
    return p
  }

  function say(level, text) {
    if (!text) return
    var next = [{ level: level, text: String(text) }].concat(messages)
    messages = next.slice(0, 5)
  }

  function clearMessages() { messages = [] }

  function notify(title, body) {
    if (!notifications) return
    Quickshell.execDetached(["notify-send", "-a", "OmniDisplay", "-i", "video-display", title, body || ""])
  }

  // ============================================================== reading

  property bool _refreshQueued: false
  property var _afterRefresh: []

  function refresh(then) {
    if (typeof then === "function") _afterRefresh.push(then)
    if (_refreshBusy) { _refreshQueued = true; return }
    _refreshBusy = true
    run([ctl, "snapshot"], undefined, function(code, out) {
      _refreshBusy = false
      var parts = String(out || "").split("\u001e")
      var parsed = Model.parseMonitors(parts[0] || "[]")
      if (parsed.length || parts[0] === "[]") monitors = parsed
      try { workspaces = JSON.parse(parts[1] || "[]") } catch (e) { workspaces = [] }
      var file = String(parts[2] || "")
      var nl1 = file.indexOf("\n")
      var nl2 = nl1 >= 0 ? file.indexOf("\n", nl1 + 1) : -1
      fileState = nl1 >= 0 ? file.substring(0, nl1) : "unreadable"
      fileSha = nl2 >= 0 ? file.substring(nl1 + 1, nl2) : "-"
      fileText = nl2 >= 0 ? file.substring(nl2 + 1) : ""
      var st = String(parts[3] || "")
      var s1 = st.indexOf("\n")
      var s2 = s1 >= 0 ? st.indexOf("\n", s1 + 1) : -1
      stateState = s1 >= 0 ? st.substring(0, s1) : "missing"
      stateSha = s2 >= 0 ? st.substring(s1 + 1, s2) : "-"
      stateText = s2 >= 0 ? st.substring(s2 + 1) : ""
      for (var mi = 0; mi < monitors.length; mi++) loadEdid(monitors[mi].name)
      var conn = []
      String(parts[4] || "").split("\n").forEach(function(line) {
        var p2 = line.split(" ")
        if (p2.length === 2 && p2[1] === "connected" && !/^Writeback/.test(p2[0])) conn.push(p2[0])
      })
      connectedPorts = conn
      loaded = true
      if (phase === "" && (!dirtyByUser || draft.length === 0)) resetDraft()
      else reconcileDraft()
      var callbacks = _afterRefresh
      _afterRefresh = []
      for (var i = 0; i < callbacks.length; i++) callbacks[i]()
      if (_refreshQueued) { _refreshQueued = false; refresh() }
    })
  }
  property bool _refreshBusy: false
  property bool dirtyByUser: false

  // ================================================================ draft

  // Requests (sync, depth, colour) are not readable from Hyprland, so they
  // come from the active profile; geometry comes from the live state.
  function withProfileRequests(list) {
    var out = Model.cloneList(list)
    var profile = activeProfile
    if (!profile) return out
    var ids = Model.identityKeys(out)
    var keys = Lua.REQUEST_KEYS.concat(["icc", "modeKeyword", "positionAuto"])
    for (var i = 0; i < out.length; i++) {
      var s = profile.settings[ids[out[i].name]]
      if (!s) continue
      for (var k = 0; k < keys.length; k++) if (s[keys[k]] !== undefined) out[i][keys[k]] = s[keys[k]]
    }
    return out
  }

  // The live displays with the modes their EDIDs add, and the requests from
  // the active profile: what every draft and plan starts from.
  function liveBase() {
    var withEdid = monitors.map(function(m) { return Model.withEdidModes(m, edidModes[m.name]) })
    return withProfileRequests(withEdid)
  }

  function resetDraft() {
    draft = liveBase()
    draftWorkspaces = activeProfile ? activeProfile.workspaces : null
    draftLaptopMode = ""
    draftGlobals = Object.assign({}, store.globals || {})
    dirtyByUser = false
    if (!Model.entryByName(draft, selected)) selected = focusedMonitor ? focusedMonitor.name : (draft.length ? draft[0].name : "")
  }

  // A display came or went while editing: keep the edits for the ones that
  // are still here, add the newcomers as they are.
  function reconcileDraft() {
    var base = liveBase()
    var out = []
    for (var i = 0; i < base.length; i++) out.push(Model.entryByName(draft, base[i].name) || base[i])
    draft = out
    if (!Model.entryByName(draft, selected)) selected = draft.length ? draft[0].name : ""
  }

  function workspacePlanEdited() {
    var current = activeProfile ? activeProfile.workspaces : null
    var a = JSON.stringify(Profiles.cleanWorkspaces(draftWorkspaces))
    var b = JSON.stringify(Profiles.cleanWorkspaces(current))
    return draftWorkspaces !== null && a !== b
  }

  function setDraft(next) {
    draft = next
    dirtyByUser = true
  }

  function select(name) { if (Model.entryByName(draft, name)) selected = name }

  // Applies a change to one entry, then repositions the arranged displays so
  // neighbours stay attached (Layout.reflow) and newcomers join on the right.
  function editEntry(name, change) {
    var before = draft
    var after = Model.cloneList(draft)
    var e = Model.entryByName(after, name)
    if (!e) return
    var wasArranged = Model.isArrangeable(e)
    change(e)
    var arrBefore = before.filter(Model.isArrangeable)
    var arrAfter = after.filter(Model.isArrangeable)
    var placed
    if (!wasArranged && Model.isArrangeable(e)) placed = Layout.placeNewcomers(arrAfter, [e.name])
    else if (arrAfter.length) placed = Layout.reflow(arrBefore.filter(function(x) { return !!Model.entryByName(arrAfter, x.name) }), arrAfter)
    else placed = []
    for (var i = 0; i < after.length; i++) {
      var p = Model.entryByName(placed, after[i].name)
      if (p) { after[i].x = p.x; after[i].y = p.y }
    }
    setDraft(after)
  }

  function setResolution(name, width, height) {
    editEntry(name, function(e) {
      var rates = Model.refreshOptions(e, width, height)
      if (!rates.length) return
      e.width = Number(width)
      e.height = Number(height)
      e.refresh = Model.nearestRefresh(rates, e.refresh)
      e.modeline = Model.modelineFor(e, e.width, e.height, e.refresh)
      e.customMode = false
      e.modeKeyword = ""
      var clean = Model.cleanScale(e.scale, e.width, e.height)
      if (clean > 0) e.scale = clean
    })
  }

  function setRefresh(name, refresh) {
    editEntry(name, function(e) {
      if (!Model.hasMode(e, e.width, e.height, Number(refresh))) return
      e.refresh = Number(refresh)
      e.modeline = Model.modelineFor(e, e.width, e.height, e.refresh)
      e.modeKeyword = ""
    })
  }

  function setMode(name, width, height, refresh) {
    editEntry(name, function(e) {
      if (!Model.hasMode(e, width, height, refresh)) return
      e.width = Number(width); e.height = Number(height); e.refresh = Number(refresh)
      e.modeline = Model.modelineFor(e, e.width, e.height, e.refresh)
      e.customMode = false
      e.modeKeyword = ""
      var clean = Model.cleanScale(e.scale, e.width, e.height)
      if (clean > 0) e.scale = clean
    })
  }

  // preferred, highres or highrr: Hyprland picks the mode. "" for exact.
  function setModeKeyword(name, keyword) {
    editEntry(name, function(e) { e.modeKeyword = ["preferred", "highres", "highrr"].indexOf(keyword) >= 0 ? keyword : "" })
  }

  // auto, auto-right, ...: Hyprland places the display. "" for the canvas.
  function setPositionAuto(name, value) {
    editEntry(name, function(e) {
      e.positionAuto = ["auto", "auto-right", "auto-left", "auto-up", "auto-down"].indexOf(value) >= 0 ? value : ""
    })
  }

  // One HDR detail (Lua.HDR_FIELDS key); null clears it.
  function setHdrField(name, key, value) {
    editEntry(name, function(e) {
      for (var i = 0; i < Lua.HDR_FIELDS.length; i++) {
        var f = Lua.HDR_FIELDS[i]
        if (f.key !== key) continue
        e[key] = value === null || value === undefined || value === "" ? null : (Lua.hdrValueOk(f, Number(value)) ? Number(value) : e[key])
      }
    })
  }

  function setSdrEotf(name, v) { editEntry(name, function(e) { e.sdrEotf = Lua.SDR_EOTFS.indexOf(v) >= 0 ? v : "" }) }

  function setScale(name, scale) {
    editEntry(name, function(e) { var c = Model.cleanScale(scale, e.width, e.height); if (c > 0) e.scale = c })
  }

  function setTransform(name, t) { editEntry(name, function(e) { e.transform = Math.max(0, Math.min(7, Number(t) || 0)) }) }
  function setEnabled(name, on) { editEntry(name, function(e) { e.enabled = !!on; if (on) e.mirror = e.mirror || "" }) }
  // Mirroring shows the target's picture: the mirroring display takes a mode
  // both offer (the largest they share), so it is not scaled to a mode it
  // cannot show crisply.
  function setMirror(name, target) {
    var src = target && target !== name ? Model.entryByName(draft, target) : null
    editEntry(name, function(e) {
      e.mirror = src ? String(target) : ""
      if (!src) return
      var c = Model.commonMode(src, e)
      if (c && Model.hasMode(e, c.width, c.height, c.refreshB)) {
        e.width = c.width; e.height = c.height; e.refresh = c.refreshB
        e.modeline = Model.modelineFor(e, e.width, e.height, e.refresh)
        e.modeKeyword = ""
        var clean = Model.cleanScale(e.scale, e.width, e.height)
        e.scale = clean > 0 ? clean : 1
      }
    })
  }
  function setIcc(name, path) { editEntry(name, function(e) { e.icc = String(path || "").trim() }) }
  function setVrr(name, v) { editEntry(name, function(e) { e.vrr = Number(v) }) }
  function setBitdepth(name, b) { editEntry(name, function(e) { e.bitdepth = Number(b) === 10 ? 10 : Number(b) === 8 ? 8 : 0 }) }
  function setCm(name, cm) {
    editEntry(name, function(e) {
      e.cmSet = String(cm || "")
      // Hyprland's default SDR white level (80 nits) looks dim in HDR; start
      // at the BT.2408 reference, as Windows and Vista do.
      if (/^hdr/.test(e.cmSet) && (e.sdrMaxLuminance === null || e.sdrMaxLuminance === undefined)) e.sdrMaxLuminance = 203
    })
  }
  function setSdr(name, brightness, saturation) {
    editEntry(name, function(e) {
      if (brightness !== undefined) e.sdrbrightness = Number(brightness) || 0
      if (saturation !== undefined) e.sdrsaturation = Number(saturation) || 0
    })
  }

  function universalScale(scale) {
    var after = Model.cloneList(draft)
    for (var i = 0; i < after.length; i++) {
      var c = Model.cleanScale(scale, after[i].width, after[i].height)
      if (c > 0) after[i].scale = c
    }
    var placed = Layout.reflow(draft.filter(Model.isArrangeable), after.filter(Model.isArrangeable))
    for (var k = 0; k < after.length; k++) {
      var p = Model.entryByName(placed, after[k].name)
      if (p) { after[k].x = p.x; after[k].y = p.y }
    }
    setDraft(after)
  }

  function mergePositions(placed) {
    var after = Model.cloneList(draft)
    for (var i = 0; i < after.length; i++) {
      var p = Model.entryByName(placed, after[i].name)
      if (p) { after[i].x = p.x; after[i].y = p.y }
    }
    setDraft(after)
  }

  function drop(name, x, y) { mergePositions(Layout.dropMonitor(draft.filter(Model.isArrangeable), name, x, y, snapThreshold)) }
  function nudge(name, dx, dy) { mergePositions(Layout.nudge(draft.filter(Model.isArrangeable), name, dx, dy)) }
  function place(name, anchor, side, align) { mergePositions(Layout.placeOnSide(draft.filter(Model.isArrangeable), name, anchor, side, align || "start")) }
  function alignSelected(align) { mergePositions(Layout.alignWithNeighbour(draft.filter(Model.isArrangeable), selected, align)) }

  function setWorkspacePlan(plan) {
    draftWorkspaces = Profiles.cleanWorkspaces(plan)
    dirtyByUser = true
  }

  function setGlobal(key, value) {
    var next = Object.assign({}, draftGlobals)
    next[key] = value
    draftGlobals = next
    dirtyByUser = true
  }

  // A mode typed in by hand. Hyprland tries it as a custom mode; the check
  // after Apply reverts it if the display or driver refuses.
  function setCustomMode(name, width, height, refresh) {
    editEntry(name, function(e) {
      e.width = Math.round(Number(width))
      e.height = Math.round(Number(height))
      e.refresh = Model.roundTo(Number(refresh), 2)
      e.customMode = !Model.hasMode(e, e.width, e.height, e.refresh)
      var c = Model.cleanScale(e.scale, e.width, e.height)
      e.scale = c > 0 ? c : 1
    })
  }

  function applyFix(name, fix) {
    if (!fix) return
    if (fix.scale) setScale(name, fix.scale)
    else if (fix.width) setMode(name, fix.width, fix.height, fix.refresh)
  }

  // ================================================================ plans

  // The store as it will be once this draft is kept: its profile updated and
  // its monitors remembered. The saved block is written from it.
  function futureStore(nextDraft, o) {
    var now = Math.round(Date.now() / 1000)
    var next = Profiles.upsertProfile(store, nextDraft, {
      workspaces: o.workspaces || null,
      laptop: o.laptopMode || Profiles.currentLaptopMode(nextDraft) || ""
    }, now).store
    next = Profiles.rememberMonitors(next, nextDraft, now)
    if (o.globals) next = Profiles.setGlobals(next, o.globals)
    return next
  }

  function planFor(nextDraft, opts) {
    var o = opts || {}
    return Plan.buildPlan({
      store: persistMode !== "service-only" ? futureStore(nextDraft, o) : null,
      snapshot: monitors,
      draft: nextDraft,
      fileText: fileText,
      fileState: fileState,
      persist: persistMode !== "service-only",
      workspaces: o.workspaces || null,
      liveWorkspaces: workspaces,
      laptopMode: o.laptopMode || "",
      base: liveBase(),
      globals: o.globals !== undefined ? o.globals : draftGlobals,
      liveGlobals: liveGlobals,
      previousWorkspaces: activeProfile ? activeProfile.workspaces : null,
      note: o.note || (activeProfile ? activeProfile.name : Profiles.suggestName(monitors))
    })
  }

  function previewText() {
    return draftPlan ? Plan.planPreview(draftPlan, confirmSeconds) : ""
  }

  // ========================================================= apply engine

  function applyDraft() {
    var build = function() { return planFor(draft, { workspaces: draftWorkspaces, laptopMode: draftLaptopMode }) }
    return applyPlan(build(), { workspaces: draftWorkspaces, laptop: draftLaptopMode, globals: draftGlobals }, build)
  }

  // Quick actions from the Basics tab and IPC: build the change from the
  // live state and send it through the same engine and countdown.
  function applyNow(change, opts) {
    var o = opts || {}
    // Built from the live state each time, so the fresh read before the
    // apply (see applyPlan) is what it changes.
    var build = function() {
      var next = liveBase()
      if (typeof change === "function") change(next)
      var placed = Layout.reflow(monitors.filter(Model.isArrangeable), next.filter(Model.isArrangeable))
      for (var i = 0; i < next.length; i++) {
        var p = Model.entryByName(placed, next[i].name)
        if (p) { next[i].x = p.x; next[i].y = p.y }
      }
      return planFor(next, { workspaces: activeProfile ? activeProfile.workspaces : null, laptopMode: o.laptopMode || "", globals: store.globals || {} })
    }
    return applyPlan(build(), { workspaces: activeProfile ? activeProfile.workspaces : null, laptop: o.laptopMode || "" }, build)
  }

  function scaleNow(name, scale) {
    return applyNow(function(list) {
      var e = Model.entryByName(list, name)
      if (e) { var c = Model.cleanScale(scale, e.width, e.height); if (c > 0) e.scale = c }
    })
  }

  function universalScaleNow(scale) {
    return applyNow(function(list) {
      for (var i = 0; i < list.length; i++) {
        var c = Model.cleanScale(scale, list[i].width, list[i].height)
        if (c > 0) list[i].scale = c
      }
    })
  }

  function toggleDisplayNow(name) {
    var e = Model.entryByName(monitors, name)
    if (!e) return false
    if (e.enabled !== false && enabledCount <= 1) { say("error", "The last display that is on cannot be turned off"); return false }
    if (e.internal) return laptopModeNow(e.enabled !== false ? "external-only" : "extend")
    return applyNow(function(list) {
      var x = Model.entryByName(list, name)
      x.enabled = !(x.enabled !== false)
      x.mirror = ""
    })
  }

  // Each laptop mode keeps its own arrangement in the profile in force;
  // switching mode brings that one back when there is one.
  function laptopModeNow(mode) {
    if (!hasLaptopChoice) { say("error", "Connect an external display to choose what the laptop screen does"); return false }
    var p = activeProfile
    if (p && p.variants && p.variants[mode]) {
      var build = function() {
        return planFor(Profiles.variantDraft(liveBase(), p, mode), { workspaces: p.workspaces, laptopMode: mode, note: p.name })
      }
      return applyPlan(build(), { workspaces: p.workspaces, laptop: mode, profileId: p.id }, build)
    }
    return applyNow(null, { laptopMode: mode })
  }

  // Checks the plan at once (so a refusal is immediate), then reads the
  // displays again and, given `rebuild`, builds the plan from that fresh
  // state: the revert snapshot must be what is on screen now, not what was
  // read a moment ago.
  function applyPlan(plan, extra, rebuild) {
    if (phase !== "") { say("error", "Finish the change that is waiting first"); return false }
    if (!plan) return false
    if (!plan.ok) {
      for (var i = plan.errors.length - 1; i >= 0; i--) say("error", plan.errors[i].message)
      return false
    }
    if (plan.changes.length === 0 && plan.moves.length === 0 && !(extra && extra.workspaces && workspacePlanEdited())) {
      say("info", "Nothing to apply")
      return false
    }
    phase = "applying"
    problems = []
    keepFailed = false
    refresh(function() {
      if (phase !== "applying") return
      var fresh = typeof rebuild === "function" ? rebuild() : plan
      if (!fresh || !fresh.ok) {
        phase = ""
        var errs = fresh ? fresh.errors : []
        for (var k = errs.length - 1; k >= 0; k--) say("error", errs[k].message)
        return
      }
      startApply(fresh, extra)
    })
    return true
  }

  function startApply(plan, extra) {
    pendingPlan = plan
    pendingExtra = extra || {}
    pendingSnapshot = Model.cloneList(monitors)
    token = "t" + Date.now()
    var payload = JSON.stringify({
      apply: plan.applyLua, revert: plan.revertLua,
      commands: plan.commands, revertCommands: plan.revertCommands, moves: plan.moves,
      reloadFirst: plan.reloadFirst,
      applyLater: plan.applyLater || "",
      revertLater: plan.revertLater || "",
      // What a revert must end with; the script re-applies the snapshot
      // until the displays show it.
      expect: pendingSnapshot.map(function(m) {
        return { name: m.name, width: m.width, height: m.height, scale: m.scale, transform: m.transform,
                 x: m.x, y: m.y, enabled: m.enabled !== false, internal: !!m.internal, mirror: m.mirror || "" }
      })
    })
    run([ctl, "apply", token, String(Plan.watchdogSeconds(confirmSeconds))], payload, function(code, out, err) {
      if (code !== 0) {
        phase = ""
        pendingPlan = null
        say("error", (String(err || "").trim() || String(out || "").trim() || ("Apply failed (" + code + ")")).split("\n")[0])
        refresh()
        return
      }
      phase = "confirm"
      startedMs = Date.now()
      remaining = confirmSeconds
      progress = 0
      countdown.start()
      // Omarchy's laptop toggles reload Hyprland; give that time to land.
      verifyTimer.interval = pendingExtra.laptop ? 2200 : 900
      verifyTimer.restart()
    })
    return true
  }
  property var pendingExtra: ({})
  property var pendingSnapshot: []

  // A step that never answers (hyprctl hung, the script killed) must not
  // lock the panel. The display itself is the watchdog's job; this only
  // frees the engine and says so.
  onPhaseChanged: {
    if (phase === "applying" || phase === "keeping" || phase === "reverting") phaseGuard.restart()
    else phaseGuard.stop()
  }

  Timer {
    id: phaseGuard
    interval: 25000
    onTriggered: {
      var was = root.phase
      countdown.stop()
      verifyTimer.stop()
      root.phase = ""
      root.pendingPlan = null
      root.say("error", "The " + was + " step did not finish in time. If the display changed, the watchdog puts it back; check the layout before trying again.")
      root.refresh(function() { root.resetDraft() })
    }
  }

  // Shortly after Apply: what did Hyprland actually do? A refused or
  // rounded setting reverts at once instead of asking to be kept.
  Timer {
    id: verifyTimer
    interval: 900
    onTriggered: {
      if (root.phase !== "confirm" || !root.pendingPlan) return
      root.refresh(function() {
        if (root.phase !== "confirm" || !root.pendingPlan) return
        var found = Plan.verifyApplied(root.pendingPlan.draft, root.monitors, { laptopMode: root.pendingExtra.laptop || "" })
        root.problems = found
        if (found.length) {
          root.say("error", "Hyprland did not take the change: " + found[0])
          root.revert()
        }
      })
    }
  }

  Timer {
    id: countdown
    interval: 200
    repeat: true
    onTriggered: {
      if (root.phase !== "confirm") { stop(); return }
      var s = Plan.confirmState(root.startedMs, Date.now(), root.confirmSeconds)
      root.remaining = s.remaining
      root.progress = s.progress
      if (s.expired) {
        stop()
        root.revert()
      }
    }
  }

  function keep(saveFile) {
    if (phase !== "confirm" || !pendingPlan) return
    countdown.stop()
    phase = "keeping"
    var plan = pendingPlan
    var toState = persistMode === "state-file"
    var writeFile = saveFile !== false && persistMode !== "service-only" && (toState ? !!plan.block : plan.canPersist)
    var text = writeFile ? (toState ? plan.block + "\n" : plan.fileText) : ""
    run([ctl, "keep", token, writeFile ? (toState ? stateSha : fileSha) : "-", String(backupsKept), toState ? "state" : "monitors"], text, function(code, out) {
      if (code !== 0) {
        keepFailed = true
        phase = "confirm"
        startedMs = Date.now() - 1000
        countdown.start()
        say("error", (String(out || "").trim() || "Saving failed") + ". Revert, or keep it live without saving.")
        return
      }
      saveProfileFrom(plan.draft, pendingExtra)
      if (pendingExtra.profileId) runPostApply(Profiles.profileById(store, pendingExtra.profileId))
      phase = ""
      pendingPlan = null
      dirtyByUser = false
      draftLaptopMode = ""
      say("info", writeFile ? (toState ? "Kept and saved to Omarchy's toggles folder" : "Kept and saved to monitors.lua") : "Kept")
      refresh()
      readOptions()
    })
  }

  function revert() {
    if (phase !== "confirm" && phase !== "applying") return
    countdown.stop()
    verifyTimer.stop()
    phase = "reverting"
    run([ctl, "revert", token], undefined, function(code, out) {
      phase = ""
      pendingPlan = null
      draftLaptopMode = ""
      if (code !== 0) say("error", "Revert reported a problem: " + String(out || "").split("\n").pop())
      revertCheck.snapshot = pendingSnapshot
      revertCheck.failed = code !== 0
      revertCheck.restart()
    })
  }

  // A revert is reported only once the displays show the layout from
  // before the change; anything still different is named.
  Timer {
    id: revertCheck
    interval: 700
    property var snapshot: []
    property bool failed: false
    onTriggered: root.refresh(function() {
      var off = Plan.verifyApplied(revertCheck.snapshot, root.monitors)
      if (off.length) root.say("error", "After the revert, " + off.join("; "))
      else if (!revertCheck.failed) root.say("info", "Reverted to the previous settings")
      root.readOptions()
      root.resetDraft()
    })
  }

  Timer {
    id: settleRefresh
    interval: 600
    onTriggered: root.refresh(function() { root.resetDraft() })
  }

  // ============================================================== profiles

  FileView {
    id: storeFile
    path: root.storePath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      root.store = Profiles.parseStore(text())
      root.storeLoaded = true
      root.scheduleRestore()
    }
    onLoadFailed: {
      root.store = Profiles.emptyStore()
      root.storeLoaded = true
    }
  }

  function writeStore(next) {
    store = next
    run([ctl, "store-write"], Profiles.serializeStore(next), function(code, out, err) {
      if (code !== 0) say("error", "Could not save profiles: " + String(err || out).trim())
    })
  }

  function saveProfileFrom(list, extra) {
    var x = extra || {}
    var result = Profiles.upsertProfile(store, list, {
      id: x.profileId || "",
      workspaces: x.workspaces || null,
      laptop: x.laptop || Profiles.currentLaptopMode(list) || ""
    }, Math.round(Date.now() / 1000))
    var next = Profiles.rememberMonitors(result.store, list, Math.round(Date.now() / 1000))
    writeStore(x.globals ? Profiles.setGlobals(next, x.globals) : next)
  }

  function saveCurrentAsProfile(name) {
    var result = Profiles.upsertProfile(store, liveBase(), { name: name || "" }, Math.round(Date.now() / 1000))
    writeStore(result.store)
    say("info", "Saved \"" + result.profile.name + "\"")
  }

  function renameProfile(id, name) { writeStore(Profiles.renameProfile(store, id, name)) }
  function deleteProfile(id) { writeStore(Profiles.deleteProfile(store, id)) }
  function setProfileLaptop(id, mode) { writeStore(Profiles.setProfileField(store, id, "laptop", mode)) }

  // Applies a saved profile through the countdown (only the one for the
  // displays connected now can be applied).
  // Any profile for the connected set: applied through the countdown, and
  // in force once kept (several can exist for one set).
  readonly property var profilesHere: Profiles.profilesFor(store, monitors)

  function applyProfile(id) {
    var p = Profiles.profileById(store, id)
    if (!p) return false
    if (!profilesHere.some(function(x) { return x.id === p.id })) { say("error", "\"" + p.name + "\" is for other displays than the ones connected"); return false }
    var build = function() {
      return planFor(Profiles.draftFromProfile(liveBase(), p),
                     { workspaces: p.workspaces, laptopMode: p.laptop !== Profiles.currentLaptopMode(monitors) ? p.laptop : "", note: p.name })
    }
    var started = applyPlan(build(), { workspaces: p.workspaces, laptop: p.laptop, profileId: p.id }, build)
    // Nothing to change: it is the same layout, so selecting is enough.
    if (!started && phase === "") writeStore(Profiles.selectProfile(store, p.id, Math.round(Date.now() / 1000)))
    return started
  }

  function duplicateProfile(id) {
    var r = Profiles.duplicateProfile(store, id, Math.round(Date.now() / 1000))
    if (r.profile) { writeStore(r.store); say("info", "\"" + r.profile.name + "\" is now in force; rename it to tell them apart") }
  }

  function setProfileAnchor(id, identity) { writeStore(Profiles.setProfileField(store, id, "anchor", identity)) }
  function setProfilePostApply(id, cmd) { writeStore(Profiles.setProfileField(store, id, "postApply", cmd)) }

  // The user's own command for a profile, run after it is applied.
  function runPostApply(profile) {
    if (!profile || !profile.postApply) return
    Quickshell.execDetached(["bash", "-lc", profile.postApply])
  }

  // ------------------------------------------------- per-field reset

  // The value a draft field had when the draft was made (live, with the
  // profile's requests): what its reset button goes back to.
  function baseValue(name, key) {
    var b = Model.entryByName(liveBase(), name)
    return b ? b[key] : undefined
  }

  function fieldChanged(name, keys) {
    var e = Model.entryByName(draft, name)
    var b = Model.entryByName(liveBase(), name)
    if (!e || !b) return false
    for (var i = 0; i < keys.length; i++) if (JSON.stringify(e[keys[i]]) !== JSON.stringify(b[keys[i]])) return true
    return false
  }

  // Puts fields of one display back, through the same reflow as an edit.
  function resetFields(name, keys) {
    var b = Model.entryByName(liveBase(), name)
    if (!b) return
    editEntry(name, function(e) { for (var i = 0; i < keys.length; i++) e[keys[i]] = b[keys[i]] })
  }

  function setPosition(name, x, y) {
    var after = Model.cloneList(draft)
    var e = Model.entryByName(after, name)
    if (!e) return
    e.x = Math.round(Number(x)) || 0
    e.y = Math.round(Number(y)) || 0
    e.positionAuto = ""
    setDraft(after)
  }

  // ------------------------------------------------- restore on hotplug

  property double _lastRestoreMs: 0
  property string _lastRestoreKey: ""
  property int _restoreCount: 0

  function scheduleRestore() { restoreTimer.restart() }

  Timer {
    id: restoreTimer
    interval: 450
    onTriggered: root.refresh(function() { root.autoRestore() })
  }

  // A known set of displays gets its kept profile back, without a
  // countdown: it was confirmed when it was kept. Bounded, so a setting
  // Hyprland keeps refusing cannot loop.
  function autoRestore() {
    if (!autoProfiles || phase !== "" || !storeLoaded) return
    var profile = activeProfile
    var base = liveBase()
    var memoryDraft = profile ? null : Profiles.draftFromMemory(base, store)
    if (!profile && !memoryDraft) return
    var key = (profile ? profile.id : "memory") + ":" + Profiles.connectedKey(monitors).join("|")
    var now = Date.now()
    if (key === _lastRestoreKey && now - _lastRestoreMs < 30000) {
      if (_restoreCount >= 2) return
    } else {
      _restoreCount = 0
    }
    var want = profile ? Profiles.draftFromProfile(base, profile) : memoryDraft
    var laptop = profile && profile.laptop && hasLaptopChoice && profile.laptop !== laptopMode ? profile.laptop : ""
    var plan = Plan.buildPlan({ snapshot: monitors, base: base, draft: want, persist: false, workspaces: profile ? profile.workspaces : null,
                                liveWorkspaces: workspaces, laptopMode: laptop,
                                // Unknown live values would read as changes every time.
                                globals: Object.keys(liveGlobals).length ? (store.globals || {}) : {},
                                liveGlobals: liveGlobals })
    if (!plan.ok) return
    var geometryChanged = plan.changes.some(function(c) { return c.name !== "Laptop" })
    if (!geometryChanged && !laptop && plan.moves.length === 0) return
    _lastRestoreKey = key
    _lastRestoreMs = now
    _restoreCount++
    var label = profile ? "\"" + profile.name + "\"" : "remembered settings"
    run([ctl, "eval-rules"], geometryChanged ? plan.applyLua : "", function(code, out) {
      if (code !== 0) { say("error", "Restoring " + label + " failed: " + String(out).split("\n")[0]); return }
      if (profile) runPostApply(profile)
      offerUndo(profile ? "Restored " + profile.name : "Restored remembered display settings",
                plan.changes.map(function(c) { return c.name + ": " + c.changes.join(", ") }).join("; "), plan)
      if (plan.applyLater) {
        laterTimer.later = plan.applyLater
        laterTimer.restart()
      }
      for (var i = 0; i < plan.commands.length; i++) Quickshell.execDetached(plan.commands[i])
      if (plan.moves.length) run([ctl, "workspace-moves"], JSON.stringify(plan.moves))
      settleRefresh.restart()
    })
  }

  // A silent restore says what it did, with Undo: the layout from before the
  // restore comes back (by snapshot rules, as a revert does).
  property var _undoRunner: null

  function offerUndo(title, body, plan) {
    if (!notifications) return
    if (_undoRunner) { try { _undoRunner.signal(15) } catch (e) {} }
    _undoRunner = run(["notify-send", "-a", "OmniDisplay", "-i", "video-display", "-A", "undo=Undo", "-w", title, body],
                      undefined, function(code, out) {
      _undoRunner = null
      if (String(out || "").trim() !== "undo" || phase !== "") return
      run([ctl, "eval-rules"], plan.revertLua, function() {
        if (plan.revertLater) {
          laterTimer.later = plan.revertLater
          laterTimer.restart()
        }
        say("info", "Undid the automatic restore")
        settleRefresh.restart()
      })
    })
  }

  // The second half of an adaptive-sync change made without a countdown.
  Timer {
    id: laterTimer
    interval: 500
    property string later: ""
    onTriggered: if (later) root.run([root.ctl, "eval-rules"], later)
  }

  // ------------------------------------------------- drift from the profile

  // What the live state does differently from the active profile, e.g. after
  // Omarchy's scale hotkey or another tool. Offered back in the panel:
  // restore the profile, or keep the live state as the profile.
  readonly property var profileDrift: {
    if (!loaded || phase !== "" || !activeProfile || restoreTimer.running) return []
    var want = Profiles.draftFromProfile(monitors, activeProfile)
    return Plan.draftChanges(monitors, want).filter(function(c) { return c.name !== "Laptop" && c.name !== "Global" })
  }
  property bool driftDismissed: false

  // Per display, how it runs differently from the profile in force, for the
  // card on the canvas: "Running at 60 Hz, saved 144 Hz".
  readonly property var displayNotes: {
    var out = {}
    if (!loaded || !activeProfile || phase !== "") return out
    var want = Profiles.draftFromProfile(monitors, activeProfile)
    for (var i = 0; i < monitors.length; i++) {
      var m = monitors[i]
      var w = Model.entryByName(want, m.name)
      if (!w || m.enabled === false || w.enabled === false) continue
      if (m.width !== w.width || m.height !== w.height)
        out[m.name] = "Running at " + m.width + "×" + m.height + ", saved " + w.width + "×" + w.height
      else if (Math.abs(m.refresh - w.refresh) > 0.6)
        out[m.name] = "Running at " + Model.formatRefresh(m.refresh) + " Hz, saved " + Model.formatRefresh(w.refresh) + " Hz"
      else if (!Model.sameScale(m.scale, w.scale))
        out[m.name] = "Running at " + Model.normalizeScale(m.scale) + "x, saved " + Model.normalizeScale(w.scale) + "x"
    }
    return out
  }
  onActiveProfileChanged: driftDismissed = false

  function restoreProfileNow() {
    _restoreCount = 0
    _lastRestoreKey = ""
    autoRestore()
  }

  function keepLiveAsProfile() {
    saveProfileFrom(liveBase(), {})
    if (persistMode === "block+service") writeBlockNow()
    say("info", "The live layout is now \"" + (activeProfile ? activeProfile.name : "the profile") + "\"")
  }

  property var _knownKeys: []

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!event || !event.name) return
      switch (String(event.name)) {
      case "monitoradded":
      case "monitoraddedv2":
      case "monitorremoved":
      case "monitorremovedv2":
        // Another monitor can come up on the same connector.
        root.edidCaps = ({})
        root.edidModes = ({})
        // fall through
      case "configreloaded":
        if (root.phase === "") root.scheduleRestore()
        else if (root.phase === "confirm" || root.phase === "applying") {
          var before0 = Profiles.connectedKey(root.pendingSnapshot.length ? root.pendingSnapshot : root.monitors).join("|")
          root.refresh(function() {
            if ((root.phase === "confirm" || root.phase === "applying")
                && Profiles.connectedKey(root.monitors).join("|") !== before0) {
              root.say("error", "A display was connected or removed during the change, so it was reverted")
              root.revert()
            }
          })
        }
        else root.refresh()
        hotplugNotice.restart()
        break
      }
    }
  }

  // A set of displays never seen before: say where to set it up, once.
  Timer {
    id: hotplugNotice
    interval: 1500
    onTriggered: {
      if (!root.loaded || !root.storeLoaded) return
      var key = Profiles.connectedKey(root.monitors).join("|")
      if (root._knownKeys.indexOf(key) >= 0) return
      root._knownKeys = root._knownKeys.concat([key])
      if (root._knownKeys.length > 1 && !root.activeProfile && root.monitors.length > 1)
        root.notify("New display arrangement", "Open Displays (Super + Ctrl + D) to arrange it. It is remembered once you keep it.")
      root.updatePresentation()
    }
  }

  // ============================================================== backups

  function loadBackups() {
    run([ctl, "backups", "list"], undefined, function(code, out) {
      var list = []
      String(out || "").split("\n").forEach(function(line) {
        var parts = line.split("\t")
        if (/^\d+$/.test(parts[0] || "")) list.push({ stamp: parts[0], size: Number(parts[1]) || 0 })
      })
      backups = list
    })
  }

  function restoreBackup(stamp) {
    if (phase !== "") { say("error", "Finish the change that is waiting first"); return }
    run([ctl, "backups", "restore", String(stamp)], undefined, function(code, out, err) {
      if (code !== 0) say("error", "Restore failed: " + String(err || out).trim())
      else say("info", "Restored the backup and reloaded Hyprland")
      loadBackups()
      settleRefresh.restart()
    })
  }

  // Undo for when the screen is unusable: revert a pending change, else put
  // back the monitors.lua from before the last Keep.
  function emergency() {
    if (phase === "confirm" || phase === "applying") { revert(); return "reverted" }
    run([ctl, "backups", "list"], undefined, function(code, out) {
      var first = String(out || "").split("\n")[0].split("\t")[0]
      if (/^\d+$/.test(first)) restoreBackup(first)
      else Quickshell.execDetached(["hyprctl", "reload"])
    })
    return "restoring"
  }

  // Writes the live layout as the managed block and folds the chosen rules
  // other display plugins left behind into it, after a backup.
  function cleanupForeign(items) {
    if (phase !== "" || fileState !== "present") return
    var plan = planFor(liveBase(), {})
    if (!plan.ok) return
    var base = Lua.removeForeign(fileText, items || foreignRules)
    var upsert = Lua.upsertManagedBlock(base, plan.block)
    if (!upsert.ok) { say("error", upsert.error); return }
    run([ctl, "keep", "cleanup" + Date.now(), fileSha, String(backupsKept)], upsert.text, function(code, out) {
      if (code !== 0) say("error", "Cleanup failed: " + String(out).trim())
      else {
        say("info", "Cleaned up monitors.lua (a backup was kept)")
        saveProfileFrom(liveBase(), {})
      }
      refresh()
    })
  }

  // ================================================================= EDID

  function loadEdid(name) {
    if (!name || edidCaps[name] !== undefined) return
    var marked = Object.assign({}, edidCaps)
    marked[name] = null
    edidCaps = marked
    run([ctl, "edid", name], undefined, function(code, out) {
      var next = Object.assign({}, edidCaps)
      var text = String(out || "").trim()
      next[name] = text === "no-edid" || text === "edid-decode-missing" || text === "" ? { missing: text } : Model.parseEdid(text)
      edidCaps = next
      var modes = Object.assign({}, edidModes)
      modes[name] = next[name].missing !== undefined ? [] : Model.parseModelines(text)
      edidModes = modes
      if (phase === "" && !dirtyByUser) resetDraft()
      else reconcileDraft()
    })
  }

  // ================================================================== DDC

  function detectDdc() {
    if (!useDdc || ddcDetected) return
    ddcDetected = true
    run([ctl, "ddc", "detect"], undefined, function(code, out) {
      var data
      try { data = JSON.parse(out) } catch (e) { data = null }
      var map = {}
      if (data && Array.isArray(data.displays)) data.displays.forEach(function(d) { map[d.connector] = d.bus })
      ddcBuses = map
      for (var name in map) readDdc(name)
    })
  }

  function readDdc(name) {
    var bus = ddcBuses[name]
    if (bus === undefined) return
    run([ctl, "ddc", "get", String(bus)], undefined, function(code, out) {
      var v
      try { v = JSON.parse(out) } catch (e) { v = null }
      if (!v) return
      var next = Object.assign({}, ddcValues)
      next[name] = v
      ddcValues = next
    })
  }

  property var _ddcPending: ({})
  property var _ddcBusy: ({})

  // Newest value wins; one write per bus at a time (DDC is slow).
  function setDdc(name, vcp, value) {
    var bus = ddcBuses[name]
    if (bus === undefined) return
    var next = Object.assign({}, ddcValues)
    var current = Object.assign({}, next[name] || {})
    if (vcp === "10") current.brightness = Number(value)
    if (vcp === "12") current.contrast = Number(value)
    next[name] = current
    ddcValues = next
    var pending = Object.assign({}, _ddcPending)
    pending[name + ":" + vcp] = { bus: bus, vcp: vcp, value: String(value) }
    _ddcPending = pending
    pumpDdc(name + ":" + vcp)
  }

  function pumpDdc(key) {
    var job = _ddcPending[key]
    if (!job || _ddcBusy[job.bus]) return
    var busy = Object.assign({}, _ddcBusy)
    busy[job.bus] = true
    _ddcBusy = busy
    var pending = Object.assign({}, _ddcPending)
    delete pending[key]
    _ddcPending = pending
    run([ctl, "ddc", "set", String(job.bus), job.vcp, job.value], undefined, function() {
      var b = Object.assign({}, _ddcBusy)
      delete b[job.bus]
      _ddcBusy = b
      for (var k in _ddcPending) pumpDdc(k)
    })
  }

  // ============================================================ brightness

  // Brightness for every display goes through Omarchy's own command, which
  // picks the laptop backlight, an Apple display or DDC/CI per monitor, so
  // the panel, the brightness keys and the OSD always agree.
  property var brightness: ({})        // name -> percent, -1 when not adjustable
  property var _brightPending: ({})
  property var _brightBusy: ({})

  function readBrightness(name) {
    if (!name) return
    run(["omarchy-brightness-display", "--monitor", String(name)], undefined, function(code, out) {
      var n = parseInt(String(out || "").trim(), 10)
      var next = Object.assign({}, brightness)
      next[name] = code === 0 && isFinite(n) ? Math.max(0, Math.min(100, n)) : -1
      brightness = next
    })
  }

  // DDC reads take about a second each, so a display read in the last
  // 30 s is not read again when the panel opens; the backlight is cheap.
  property var _brightReadAt: ({})

  function readAllBrightness() {
    var now = Date.now()
    var stamps = Object.assign({}, _brightReadAt)
    for (var i = 0; i < monitors.length; i++) {
      var m = monitors[i]
      if (m.enabled === false) continue
      if (!m.internal && stamps[m.name] && now - stamps[m.name] < 30000 && brightness[m.name] !== undefined) continue
      stamps[m.name] = now
      readBrightness(m.name)
    }
    _brightReadAt = stamps
  }

  // Newest value wins; the command drops overlapping calls, so one at a
  // time per display.
  function setBacklight(name, percent) {
    var p = Model.clampBrightness(percent)
    if (!name) return p
    var next = Object.assign({}, brightness)
    next[name] = p
    brightness = next
    var pending = Object.assign({}, _brightPending)
    pending[name] = p
    _brightPending = pending
    pumpBrightness(name)
    return p
  }

  function pumpBrightness(name) {
    if (_brightBusy[name] || _brightPending[name] === undefined) return
    var value = _brightPending[name]
    var pending = Object.assign({}, _brightPending)
    delete pending[name]
    _brightPending = pending
    var busy = Object.assign({}, _brightBusy)
    busy[name] = true
    _brightBusy = busy
    run(["omarchy-brightness-display", "--no-osd", "--monitor", String(name), value + "%"], undefined, function() {
      var b = Object.assign({}, _brightBusy)
      delete b[name]
      _brightBusy = b
      pumpBrightness(name)
    })
  }

  // ========================================================== night light

  function readNight() {
    run([ctl, "night", "status"], undefined, function(code, out) {
      try { nightState = JSON.parse(out) } catch (e) {}
    })
  }

  function setNight(on) {
    run([ctl, "night", on ? "on" : "off"], undefined, function() { readNight() })
  }

  function setTemperature(k) {
    var next = Object.assign({}, nightState)
    next.temperature = Math.round(k)
    next.enabled = k < 6000
    nightState = next
    nightDebounce.restart()
  }

  Timer {
    id: nightDebounce
    interval: 200
    onTriggered: root.run([root.ctl, "night", "temperature", String(root.nightState.temperature)])
  }

  // ===================================================== presentation mode

  function setPresenting(on) {
    run([ctl, "present", on ? "on" : "off"], undefined, function() { readPresenting() })
  }

  function readPresenting() {
    run([ctl, "present", "status"], undefined, function(code, out) { presenting = String(out).trim() === "on" })
  }

  // Automatic presentation mode: on while a cast streams or the laptop
  // mirrors onto a projector, off again once neither is true.
  function updatePresentation() {
    if (!presentationAuto) return
    var want = Cast.hasConnected(castState) || laptopMode === "mirror"
    if (want !== presenting) setPresenting(want)
  }

  onLaptopModeChanged: updatePresentation()

  // ================================================================= cast

  readonly property bool castLive: castState.connected.length > 0 || castState.pending.length > 0

  function readCast() {
    run([castCtl, "state"], undefined, function(code, out) {
      castState = Cast.parseState(out)
      updatePresentation()
    })
  }

  function castCommand(args, input, then) {
    run([castCtl].concat(args), input, function(code, out, err) {
      readCast()
      if (typeof then === "function") then(code, out, err)
    })
  }

  // Miracast events land in the cast state file as they happen: watch it.
  // The slower poll is still needed for AirPlay, whose daemon is asked, and
  // to notice a session whose process died.
  FileView {
    path: root.runDir.replace(/\/omnidisplay$/, "") + "/omnidisplay-cast/state.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var parsed = Cast.parseState(text())
      if (root.castState.backends && !parsed.backends.miracast) parsed.backends = root.castState.backends
      root.castState = parsed
    }
  }

  Timer {
    interval: 5000
    repeat: true
    running: root.castViewOpen || root.castLive
    triggeredOnStart: true
    onTriggered: root.readCast()
  }

  // ========================================================= tablet / VNC

  function readVnc() {
    run([vncCtl, "status"], undefined, function(code, out) {
      try { vncState = JSON.parse(out) } catch (e) {}
    })
  }

  function vncStart(mode, size, side, access) {
    run([vncCtl, "start", mode, size, side, access], undefined, function(code, out, err) {
      if (code !== 0) say("error", String(err || out).trim().split("\n").pop() || "The tablet session did not start")
      readVnc()
      refresh()
      if (access === "network") makeQr()
    })
  }

  function vncStop() {
    run([vncCtl, "stop"], undefined, function() { readVnc(); refresh() })
  }

  function vncRegenerate() {
    run([vncCtl, "regenerate"], undefined, function(code, out, err) {
      if (code !== 0) say("error", String(err || out).trim())
      else say("info", "New password. Restart the session to use it.")
      readVnc()
    })
  }

  function makeQr() {
    var path = runDir + "/qr.png"
    run([vncCtl, "qr", path], undefined, function(code) {
      if (code === 0) { qrPath = path; qrRevision++ }
    })
  }

  Timer {
    interval: 3000
    repeat: true
    running: root.castViewOpen || root.vncState.running === true
    triggeredOnStart: true
    onTriggered: root.readVnc()
  }

  // ======================================================= terminal fonts

  function readTerminalFonts() {
    run([ctl, "terminal-font", "list"], undefined, function(code, out) {
      try { terminalFonts = JSON.parse(out) } catch (e) { terminalFonts = [] }
    })
  }

  function setTerminalFont(terminal, size) {
    run([ctl, "terminal-font", "set", terminal, String(size)], undefined, function() { readTerminalFonts() })
  }

  // =============================================================== report

  function copyReport() {
    run([ctl, "report"], undefined, function(code, out) {
      run(["wl-copy"], String(out || ""))
      say("info", "Diagnostic report copied to the clipboard")
    })
  }

  // ========================================================= global options

  function readOptions() {
    run([ctl, "options"], undefined, function(code, out) {
      try { liveGlobals = JSON.parse(out) } catch (e) {}
    })
    run(["hyprctl", "getoption", "animations:enabled", "-j"], undefined, function(code, out) {
      try { var o = JSON.parse(out); animationsEnabled = (o.int !== undefined ? o.int : o.bool) ? true : false } catch (e) {}
    })
  }

  // Hyprland's own animations switch: the canvas does not glide when it is off.
  property bool animationsEnabled: true

  // ======================================================== cast a window

  // Wireless protocols here capture whole screens. To show one window, it
  // is moved onto the screen being cast (an extended cast, or the tablet's
  // virtual screen) and made fullscreen there; Return puts it back.
  property var windows: []
  property var sentWindows: ({})       // address -> { workspace, output }

  readonly property var castTargets: {
    var out = Cast.castOutputs(castState).slice()
    var s = vncState.session || {}
    if (vncState.running && s.mode === "extend" && s.output && out.indexOf(s.output) < 0) out.push(s.output)
    return out.filter(function(n) { return !!Model.entryByName(monitors, n) })
  }

  function loadWindows() {
    run([ctl, "windows"], undefined, function(code, out) {
      try { windows = JSON.parse(out) } catch (e) { windows = [] }
    })
  }

  function sendWindow(address, output) {
    var target = Model.entryByName(monitors, output)
    var win = null
    for (var i = 0; i < windows.length; i++) if (windows[i].address === address) win = windows[i]
    if (!target || !win || !(target.workspace > 0)) { say("error", "That screen has no workspace to show the window on"); return }
    run([ctl, "send-window", address, String(target.workspace)], undefined, function(code) {
      if (code !== 0) { say("error", "Could not move the window"); return }
      var next = Object.assign({}, sentWindows)
      next[address] = { workspace: win.workspace, output: output, title: win.title || win["class"] }
      sentWindows = next
      loadWindows()
    })
  }

  function returnWindow(address) {
    var info = sentWindows[address]
    if (!info) return
    run([ctl, "return-window", address, String(info.workspace)], undefined, function() {
      var next = Object.assign({}, sentWindows)
      delete next[address]
      sentWindows = next
      loadWindows()
    })
  }

  // A cast or tablet screen that went away takes its windows back first.
  onCastTargetsChanged: {
    for (var address in sentWindows) {
      if (castTargets.indexOf(sentWindows[address].output) < 0) returnWindow(address)
    }
  }

  // ===================================================== missing block

  function writeBlockNow() {
    if (phase !== "") return
    var plan = planFor(liveBase(), { globals: store.globals || {} })
    if (!plan.ok) { say("error", plan.errors.length ? plan.errors[0].message : "Cannot build the block"); return }
    if (persistMode === "state-file") {
      run([ctl, "keep", "block" + Date.now(), stateSha, String(backupsKept), "state"], plan.block + "\n", function(code, out) {
        if (code !== 0) say("error", "Could not write the state file: " + String(out).trim())
        else say("info", "OmniDisplay's file in Omarchy's toggles folder is written")
        refresh()
      })
      return
    }
    var upsert = Lua.upsertManagedBlock(fileState === "present" ? fileText : "", plan.block)
    if (!upsert.ok) { say("error", upsert.error); return }
    run([ctl, "keep", "block" + Date.now(), fileSha, String(backupsKept)], upsert.text, function(code, out) {
      if (code !== 0) say("error", "Could not write the block: " + String(out).trim())
      else say("info", "OmniDisplay's block is back in monitors.lua")
      refresh()
    })
  }

  // After switching where kept settings go: drop what the other place holds.
  function removeMonitorsBlock() {
    if (phase !== "" || fileState !== "present") return
    var removed = Lua.removeManagedBlock(fileText)
    if (!removed.ok) { say("error", removed.error); return }
    run([ctl, "keep", "unblock" + Date.now(), fileSha, String(backupsKept)], removed.text, function(code, out) {
      if (code !== 0) say("error", "Could not remove the block: " + String(out).trim())
      else say("info", "Removed OmniDisplay's block from monitors.lua (a backup was kept)")
      refresh()
    })
  }

  function removeStateFile() {
    run([ctl, "state-remove"], undefined, function() {
      say("info", "Removed OmniDisplay's file from Omarchy's toggles folder")
      refresh()
    })
  }

  // ================================================== brightness in HDR

  // In HDR the panel ignores its backlight: what changes how bright the
  // desktop looks is SDR brightness. Applied at once (no countdown, like
  // the backlight), and kept in the active profile.
  function inHdr(m) { return !!m && m.enabled !== false && /^hdr/.test(m.cm) }

  function setSdrBrightnessNow(name, value) {
    var v = Math.max(0.5, Math.min(2, Model.roundTo(Number(value) || 1, 2)))
    if (!Model.SAFE_NAME.test(name)) return v
    run([ctl, "eval-rules"], "hl.monitor({ output = \"" + name + "\", sdrbrightness = " + v + " })")
    var next = Model.cloneList(monitors)
    var e = Model.entryByName(next, name)
    if (e) { e.sdrBrightness = v; monitors = next }
    _sdrPending = { name: name, value: v }
    sdrSave.restart()
    return v
  }
  property var _sdrPending: null

  Timer {
    id: sdrSave
    interval: 900
    onTriggered: {
      var p = root._sdrPending
      if (!p || !root.activeProfile) return
      var next = Profiles.copyStore(root.store)
      var prof = Profiles.profileById(next, root.activeProfile.id)
      var ids = Model.identityKeys(root.monitors)
      if (prof && prof.settings[ids[p.name]]) {
        prof.settings[ids[p.name]].sdrbrightness = p.value
        root.writeStore(next)
      }
    }
  }

  // What a brightness key runs: "+5%", "5%-" or "40%". HDR displays step
  // SDR brightness; the rest go through Omarchy's own brightness command,
  // which shows its OSD.
  function brightnessStep(arg) {
    var a = String(arg || "").trim()
    if (!/^(\+\d{1,3}%|\d{1,3}%-|\d{1,3}%)$/.test(a)) return "use +5%, 5%- or 40%"
    var m = focusedMonitor
    if (inHdr(m)) {
      var cur = Number(m.sdrBrightness) || 1
      var n = parseInt(a.replace(/[^0-9]/g, ""), 10)
      var v = a.charAt(0) === "+" ? cur + n / 100 : (/-$/.test(a) ? cur - n / 100 : 0.5 + 1.5 * n / 100)
      v = setSdrBrightnessNow(m.name, v)
      Quickshell.execDetached(["omarchy-osd", "-i", "brightness", "-p", String(Math.round((v - 0.5) / 1.5 * 100))])
      return "sdr " + v
    }
    Quickshell.execDetached(["omarchy-brightness-display", a])
    return "backlight " + a
  }

  // ============================================ start from nearest profile

  // A set of displays never seen before, sharing some with a saved profile:
  // start from that profile's settings for the shared ones, through the
  // countdown. Keeping it makes the new set's own profile.
  function startFromNearest() {
    var p = nearestProfile
    if (!p) return false
    var build = function() { return planFor(Profiles.draftFromProfile(monitors, p), { globals: store.globals || {} }) }
    return applyPlan(build(), { globals: store.globals || {} }, build)
  }

  // ================================================= resume and HDR

  // logind says when the machine wakes; displays come back then without a
  // hotplug event, so the profile is checked again, and HDR panels get
  // their metadata resent.
  Process {
    id: sleepWatch
    running: true
    command: ["gdbus", "monitor", "--system", "--dest", "org.freedesktop.login1", "--object-path", "/org/freedesktop/login1"]
    stdout: SplitParser {
      onRead: function(line) {
        if (/PrepareForSleep \(false/.test(String(line))) resumeTimer.restart()
      }
    }
    onExited: sleepWatchRestart.start()
  }

  Timer {
    id: sleepWatchRestart
    interval: 10000
    onTriggered: sleepWatch.running = true
  }

  Timer {
    id: resumeTimer
    interval: 2500
    onTriggered: {
      root.scheduleRestore()
      root.resendHdr()
    }
  }

  function resendHdr() {
    var count = 0
    for (var i = 0; i < monitors.length; i++) {
      var m = monitors[i]
      if (m.enabled === false || !/^hdr/.test(m.cm)) continue
      run([ctl, "resend-hdr", m.name, m.cm === "hdredid" ? "hdredid" : "hdr"])
      count++
    }
    return count
  }

  // ======================================================== layout health

  readonly property var layoutIssues: loaded ? Plan.layoutHealth(monitors) : []

  function repairLayout() {
    var build = function() { return planFor(Plan.repairDraft(liveBase()), {}) }
    return applyPlan(build(), {}, build)
  }

  // Everything read again from scratch: EDIDs, DDC buses, brightness.
  function rescan() {
    edidCaps = ({})
    edidModes = ({})
    ddcDetected = false
    ddcBuses = ({})
    _brightReadAt = ({})
    refresh(function() { root.readAllBrightness() })
    detectDdc()
    loadBackups()
    readOptions()
    say("info", "Displays read again")
  }

  // While the panel is open the laptop backlight is re-read, so the slider
  // follows the brightness keys (DDC is too slow for this; it is read on open).
  Timer {
    interval: 2000
    repeat: true
    running: root.panelsOpen > 0
    onTriggered: {
      for (var i = 0; i < root.monitors.length; i++)
        if (root.monitors[i].internal && root.monitors[i].enabled !== false) root.readBrightness(root.monitors[i].name)
    }
  }

  // ============================================================ menu row

  property bool menuRowPresent: false

  function readMenu(then) {
    run([ctl, "menu", "read"], undefined, function(code, out) {
      menuRowPresent = Menu.hasRow(out)
      if (typeof then === "function") then(String(out || ""))
    })
  }

  function setMenuRow(on) {
    readMenu(function(text) {
      var r = on ? Menu.addRow(text) : Menu.removeRow(text)
      if (!r.ok) { say("error", r.error); return }
      if (r.unchanged) return
      run([ctl, "menu", "write"], r.text, function(code) {
        if (code !== 0) say("error", "Could not write Omarchy's menu file")
        else say("info", on ? "Added Setup › Displays to the Omarchy menu" : "Removed the Omarchy menu row")
        readMenu()
      })
    })
  }

  // ===================================================== HDR calibration

  // Shows a test pattern fullscreen (q closes it); the panel then asks what
  // was seen, and the answer goes into the draft like any other change.
  readonly property string hdrPattern: pluginDir + "/bin/omnidisplay-hdr-pattern"
  property string calibrating: ""      // "", "peak", "full", "black" while a pattern shows
  property string calibrated: ""       // the last pattern shown, waiting for an answer
  property var calibrationLevels: []

  function calibrate(kind, name) {
    var e = Model.entryByName(monitors, name)
    if (!e || !inHdr(e)) { say("error", "Switch the display to HDR first: the patterns need it"); return }
    var caps = edidCaps[name]
    var max = caps && caps.maxLuminance ? Math.max(400, Math.min(10000, caps.maxLuminance * 2)) : 4000
    var png = runDir + "/hdr-" + kind + ".png"
    calibrating = kind
    run([hdrPattern, "levels", kind, String(max)], undefined, function(c, out) {
      calibrationLevels = String(out || "").split("\n").filter(function(l) { return l !== "" }).map(Number)
      run([hdrPattern, "draw", kind, String(max), png], undefined, function(code, o2, err) {
        if (code !== 0) { calibrating = ""; say("error", String(err || o2).trim() || "Could not draw the pattern"); return }
        run([hdrPattern, "show", png], undefined, function() {
          calibrating = ""
          calibrated = kind
        })
      })
    })
  }

  function answerCalibration(name, kind, nits) {
    var key = kind === "peak" ? "maxLuminance" : kind === "full" ? "maxAvgLuminance" : "minLuminance"
    setHdrField(name, key, Number(nits))
    calibrated = ""
  }

  // ================================================================ prefs

  readonly property var prefs: store.prefs || ({})

  function setTabletPrefs(t) {
    var next = Object.assign({}, store.prefs || {})
    next.tablet = t
    writeStore(Profiles.setPrefs(store, next))
  }

  function vncResize(size) {
    run([vncCtl, "resize", size], undefined, function(code, out, err) {
      if (code !== 0) say("error", String(err || out).trim().split("\n").pop() || "Could not change the size")
      readVnc()
      refresh()
    })
  }

  // ===================================================== full-screen editor

  property bool fullArrangeOpen: false

  FullArrange {
    service: root
  }

  // ======================================================= panel lifecycle

  function panelOpened() {
    panelsOpen++
    refresh(function() { root.readAllBrightness() })
    readOptions()
    loadBackups()
    readNight()
    readPresenting()
    detectDdc()
    for (var name in ddcBuses) readDdc(name)
    readMenu()
    if (identifyOnOpen) identify()
  }

  function panelClosed() {
    panelsOpen = Math.max(0, panelsOpen - 1)
    if (panelsOpen === 0) castViewOpen = false
  }

  function togglePanel() {
    if (shell && typeof shell.toggle === "function") shell.toggle(pluginId, "{}")
  }

  // Asked for by IPC (`omarchy-shell omnidisplay show arrange`); the open
  // widget follows it.
  property string requestedTab: ""
  property int tabRequest: 0

  function showTab(tab) {
    requestedTab = String(tab || "basics")
    tabRequest++
    if (panelsOpen === 0 && shell && typeof shell.summon === "function") shell.summon(pluginId, "{}")
  }

  // ============================================================= overlays

  IdentifyOverlay {
    id: identifyOverlay
  }

  function identifyOne(name) {
    var n = displayNumber(name)
    var e = Model.entryByName(monitors, name)
    if (e) identifyOverlay.show([{ output: name, number: n || 1, label: Model.displayLabel(e) }])
  }

  function identify() {
    var list = monitors.filter(function(m) { return m.enabled !== false })
    var entries = []
    for (var i = 0; i < list.length; i++)
      entries.push({ output: list[i].name, number: i + 1, label: Model.displayLabel(list[i]) })
    identifyOverlay.show(entries)
  }

  function displayNumber(name) {
    var list = monitors.filter(function(m) { return m.enabled !== false })
    for (var i = 0; i < list.length; i++) if (list[i].name === name) return i + 1
    return 0
  }

  KeepOverlay {
    service: root
  }

  ModeOsd {
    id: modeOsd
  }

  function cycleMode() {
    if (!hasLaptopChoice) return "no external display"
    var next = Profiles.nextLaptopMode(laptopMode || "extend")
    modeOsd.show(Profiles.LAPTOP_MODES.map(function(m) { return { value: m, label: Profiles.laptopModeLabel(m) } }), next)
    laptopModeNow(next)
    return next
  }

  // ================================================================== IPC

  IpcHandler {
    target: "omnidisplay"

    function open(): void { root.togglePanel() }
    function toggle(): void { root.togglePanel() }
    function show(tab: string): void { root.showTab(tab) }
    function state(): string {
      return JSON.stringify({
        displays: root.monitors.map(function(m) {
          return { name: m.name, description: m.description, enabled: m.enabled, mirror: m.mirror,
                   mode: Model.modeKey(m.width, m.height, m.refresh), scale: m.scale, transform: m.transform,
                   x: m.x, y: m.y, focused: m.focused }
        }),
        profile: root.activeProfile ? root.activeProfile.name : "",
        laptopMode: root.laptopMode,
        pending: root.phase,
        remaining: root.remaining
      })
    }
    function identify(): void { root.identify() }
    function cycleMode(): string { return root.cycleMode() }
    function mode(name: string): string {
      if (Profiles.LAPTOP_MODES.indexOf(name) < 0) return "unknown mode: use " + Profiles.LAPTOP_MODES.join(", ")
      return root.laptopModeNow(name) ? "applying" : "refused"
    }
    function profile(name: string): string {
      var list = root.store.profiles
      for (var i = 0; i < list.length; i++) if (list[i].name === name) return root.applyProfile(list[i].id) ? "applying" : "refused"
      return "no profile named " + name
    }
    // Scripting: each goes through the same countdown as the panel.
    function scale(output: string, value: string): string {
      return root.scaleNow(output, Number(value)) ? "applying" : "refused"
    }
    function rotate(output: string, transform: string): string {
      return root.applyNow(function(list) {
        var e = Model.entryByName(list, output)
        if (e) e.transform = Math.max(0, Math.min(7, Number(transform) || 0))
      }) ? "applying" : "refused"
    }
    function setMode(output: string, mode: string): string {
      var m = Model.parseMode(mode)
      if (!m) return "mode must look like 1920x1080@60"
      return root.applyNow(function(list) {
        var e = Model.entryByName(list, output)
        if (!e) return
        var r = Model.nearestRefresh(Model.refreshOptions(e, m.width, m.height), m.refresh)
        if (r === null) return
        e.width = m.width; e.height = m.height; e.refresh = r
        var c = Model.cleanScale(e.scale, e.width, e.height)
        if (c > 0) e.scale = c
      }) ? "applying" : "refused"
    }
    function mirror(output: string, target: string): string {
      if (!Model.entryByName(root.monitors, output)) return "no such display"
      if (target && !Model.entryByName(root.monitors, target)) return "no such display: " + target
      return root.applyNow(function(list) {
        var e = Model.entryByName(list, output)
        if (e) e.mirror = target && target !== output ? target : ""
      }) ? "applying" : "refused"
    }
    function enable(output: string): string {
      var e = Model.entryByName(root.monitors, output)
      if (!e) return "no such display"
      return e.enabled !== false ? "already on" : (root.toggleDisplayNow(output) ? "applying" : "refused")
    }
    function disable(output: string): string {
      var e = Model.entryByName(root.monitors, output)
      if (!e) return "no such display"
      return e.enabled === false ? "already off" : (root.toggleDisplayNow(output) ? "applying" : "refused")
    }
    function option(key: string, value: string): string {
      var g = Lua.globalOption(key)
      if (!g) return "unknown option: use " + Lua.GLOBAL_OPTIONS.map(function(o) { return o.key }).join(", ")
      var v = g.type === "bool" ? (value === "true" || value === "on" || value === "1") : Number(value)
      if (!Lua.globalValueOk(key, v)) return "bad value for " + key
      var globals = Object.assign({}, root.store.globals || {})
      globals[key] = v
      var ws = root.activeProfile ? root.activeProfile.workspaces : null
      var build = function() { return root.planFor(root.liveBase(), { globals: globals, workspaces: ws }) }
      return root.applyPlan(build(), { globals: globals, workspaces: ws }, build) ? "applying" : "refused"
    }
    function options(): string { return JSON.stringify(root.liveGlobals) }
    // Drafts a workspace plan (off, sequential, interleaved, manual) and
    // returns it per display; Apply in the panel puts it into force.
    function workspaces(strategy: string, count: string): string {
      if (["off", "sequential", "interleaved", "manual"].indexOf(strategy) < 0) return "use off, sequential, interleaved or manual"
      var next = Profiles.cleanWorkspaces(root.draftWorkspaces)
      next.strategy = strategy
      if (Number(count) > 0) next.count = Number(count)
      root.setWorkspacePlan(next)
      var byName = {}
      Profiles.planWorkspaces(root.draft, root.draftWorkspaces).forEach(function(r) { (byName[r.name] = byName[r.name] || []).push(r.workspace) })
      return Object.keys(byName).map(function(n) { return n + ": " + byName[n].join(",") }).join("; ") || "no rules"
    }
    function resetDraft(): void { root.resetDraft() }
    function keep(): string { root.keep(true); return root.phase }
    function revert(): string { root.revert(); return "reverting" }
    function emergency(): string { return root.emergency() }
    function messages(): string { return JSON.stringify(root.messages) }
    function clearMessages(): void { root.clearMessages() }
    function resendHdr(): string { return root.resendHdr() + " display(s)" }
    function brightnessStep(arg: string): string { return root.brightnessStep(arg) }
    function writeBlock(): void { root.writeBlockNow() }
    function present(on: string): string { root.setPresenting(on === "on" || on === "true"); return on }
    function castStop(): void { root.castCommand(["disconnect", ""]) }
  }

  // The built-in Display widget's target, for scripts that call it.
  IpcHandler {
    target: "omarchy.monitor"

    // So a binding written for the built-in widget's replacements works here.
    function revert(): string { root.revert(); return "reverting" }
    function keep(): string { root.keep(true); return root.phase }
    function emergency(): string { return root.emergency() }
    function open(): void { root.togglePanel() }
    function toggle(): void { root.togglePanel() }
    function show(): void { root.togglePanel() }
    function brightness(percent: string): string {
      var name = root.focusedMonitor ? root.focusedMonitor.name : ""
      return "got " + root.setBacklight(name, Number(percent))
    }
    function state(): string {
      return JSON.stringify({ focusedMonitor: root.focusedMonitor ? root.focusedMonitor.name : "",
                              displays: root.monitors.map(function(m) { return { name: m.name, enabled: m.enabled, focused: m.focused, width: m.width, height: m.height } }) })
    }
  }

  Component.onCompleted: {
    refresh()
    readOptions()
    readCast()
    readVnc()
    readPresenting()
  }
}
