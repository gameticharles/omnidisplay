// Unit tests for lib/. Run with: node tests/lib.test.js
// Nothing here talks to Hyprland: the fixtures are `hyprctl monitors all -j`
// captures (serials replaced) and edid-decode output.

const assert = require("assert")
const { load, test, fixture, finish } = require("./load")

const Model = load("Model.js")
const Layout = load("Layout.js")
const Lua = load("Lua.js")
const Profiles = load("Profiles.js")
const Plan = load("Plan.js")
const Cast = load("Cast.js")

const desk = Model.parseMonitors(fixture("monitors-desk.json"))
const laptop = Model.parseMonitors(fixture("monitors-laptop.json"))

function byName(list, name) { return Model.entryByName(list, name) }

console.log("Model")

test("parses every display with live facts and unset requests", () => {
  assert.strictEqual(desk.length, 3)
  const edp = byName(desk, "eDP-1")
  assert.strictEqual(edp.internal, true)
  assert.strictEqual(edp.refresh, 144)
  assert.strictEqual(edp.liveBitdepth, 8)
  assert.strictEqual(edp.bitdepth, 0)
  assert.strictEqual(edp.vrr, -1)
  assert.strictEqual(byName(desk, "DP-2").refresh, 59.95)
})

test("the live mode counts as offered even when the list lacks it", () => {
  const virtual = Model.parseMonitors(JSON.stringify([{ name: "OMNI-T1", width: 1280, height: 720, refreshRate: 60,
    scale: 1, availableModes: ["1920x1080@60.00Hz"] }]))[0]
  assert.ok(Model.hasMode(virtual, 1280, 720, 60))
  assert.ok(Plan.buildPlan({ snapshot: [virtual], draft: [virtual] }).ok)
})

test("mirrorOf ids become names, and extending clears a mirror", () => {
  const raw = JSON.parse(fixture("monitors-desk.json"))
  raw[2].mirrorOf = String(raw[0].id)
  const parsed = Model.parseMonitors(JSON.stringify(raw))
  assert.strictEqual(byName(parsed, "HDMI-A-1").mirror, "eDP-1")
  assert.ok(Plan.buildPlan({ snapshot: parsed, draft: parsed }).ok)
  const extend = Object.assign({}, byName(parsed, "HDMI-A-1"), { mirror: "" })
  assert.ok(/mirror = ""/.test(Lua.monitorRule(extend, "HDMI-A-1", {})))
})

test("cleanScale rounds up to whole logical pixels", () => {
  assert.strictEqual(Model.cleanScale(1.6, 1920, 1080), 1.6)
  assert.strictEqual(Model.cleanScale(1.3, 1920, 1080), 1.333333)
  assert.strictEqual(Model.cleanScale(0, 1920, 1080), 0)
})

test("availableScales collapses presets that land on the same scale", () => {
  const scales = Model.availableScales(Model.SCALE_PRESETS, 2560, 1440)
  assert.ok(scales.indexOf("1") >= 0)
  assert.strictEqual(new Set(scales.map(s => Model.cleanScale(s, 2560, 1440))).size, scales.length)
})

test("resolution options are unique, largest first, rates high to low", () => {
  const opts = Model.resolutionOptions(byName(desk, "DP-2"))
  assert.strictEqual(opts[0].key, "2560x1440")
  const fhd = opts.find(o => o.key === "1920x1080")
  assert.deepStrictEqual(fhd.refreshRates, [60, 59.94, 50])
})

test("logical size swaps on quarter turns", () => {
  const e = Object.assign({}, byName(desk, "DP-2"), { transform: 1 })
  assert.deepStrictEqual(Model.logicalSize(e), { width: 1440, height: 2560 })
  assert.deepStrictEqual(Model.logicalSize(byName(desk, "HDMI-A-1")), { width: 2560, height: 1440 })
})

test("identity prefers a unique description, falls back to the connector", () => {
  const twins = Model.cloneList(desk)
  twins[2].description = twins[1].description
  const ids = Model.identityKeys(twins)
  assert.strictEqual(ids["eDP-1"], "Chimei Innolux Corporation 0x1521")
  assert.strictEqual(ids["DP-2"], "DP-2")
  assert.strictEqual(ids["HDMI-A-1"], "HDMI-A-1")
})

test("pixel density and suggested scale", () => {
  const dell = byName(desk, "DP-2")
  assert.strictEqual(Model.diagonalInches(600, 340), 27.2)
  assert.strictEqual(Model.pixelDensity(dell), 108)
  assert.strictEqual(Model.suggestedScale(dell), 1)
  const edp = byName(laptop, "eDP-1")
  assert.ok(Model.suggestedScale(edp) >= 1)
})

test("EDID: HDR panel capabilities", () => {
  const caps = Model.parseEdid(fixture("edid-hdr.txt"))
  assert.strictEqual(caps.hdr, true)
  assert.deepStrictEqual(caps.eotfs, ["PQ"])
  assert.strictEqual(caps.wideColor, true)
  assert.strictEqual(caps.bitsPerColor, 10)
  assert.strictEqual(caps.maxLuminance, 604)
  assert.strictEqual(caps.vrrMin, 48)
  assert.strictEqual(caps.vrrMax, 165)
  assert.strictEqual(caps.productName, "LG ULTRAGEAR")
})

test("EDID: plain laptop panel", () => {
  const caps = Model.parseEdid(fixture("edid-laptop.txt"))
  assert.strictEqual(caps.hdr, false)
  assert.strictEqual(caps.bitsPerColor, 8)
  assert.strictEqual(caps.timings[0].refresh, 144)
})

test("health: not native, faster rate, link-limited", () => {
  const dell = Object.assign({}, byName(desk, "DP-2"), { width: 1920, height: 1080, refresh: 50 })
  const codes = Model.healthInsights(dell, null).map(i => i.code)
  assert.ok(codes.includes("not-native"))
  assert.ok(codes.includes("faster-rate"))
  const native = byName(desk, "DP-2")
  const caps = { timings: [{ width: 2560, height: 1440, refresh: 144 }], vrrMax: 0 }
  assert.ok(Model.healthInsights(native, caps).some(i => i.code === "link-limited"))
  assert.ok(!Model.healthInsights(native, null).some(i => i.code === "not-native"))
})

console.log("\nLayout")

const arranged = desk.filter(Model.isArrangeable)

test("fixture layout is connected and overlap-free", () => {
  assert.ok(Layout.isConnected(arranged))
  assert.deepStrictEqual(Layout.overlappingPairs(arranged), [])
})

test("dropping snaps flush to the nearest free edge", () => {
  const out = Layout.dropMonitor(arranged, "eDP-1", 2000, 1500, 48)
  const edp = byName(out, "eDP-1")
  assert.deepStrictEqual(Layout.overlappingPairs(out), [])
  assert.ok(Layout.isConnected(out))
  assert.ok(["below", "above", "left", "right"].includes(Layout.sideOf(out, "eDP-1", "DP-2")) || Layout.sideOf(out, "eDP-1", "HDMI-A-1"))
  assert.ok(edp.x >= 0 && edp.y >= 0)
})

test("pulling the middle display out closes the gap", () => {
  const out = Layout.dropMonitor(arranged, "DP-2", 9000, 0, 48)
  assert.ok(Layout.isConnected(out))
  assert.deepStrictEqual(Layout.overlappingPairs(out), [])
})

test("placeOnSide aligns start, centre and end", () => {
  const start = Layout.placeOnSide(arranged, "eDP-1", "DP-2", "left", "start")
  assert.strictEqual(byName(start, "eDP-1").y, byName(start, "DP-2").y)
  const end = Layout.placeOnSide(arranged, "eDP-1", "DP-2", "left", "end")
  assert.strictEqual(byName(end, "eDP-1").y + 1080, byName(end, "DP-2").y + 1440)
  const below = Layout.placeOnSide(arranged, "eDP-1", "DP-2", "below", "center")
  assert.strictEqual(Layout.sideOf(below, "eDP-1", "DP-2"), "below")
})

test("reflow keeps neighbours attached when a display grows", () => {
  const after = Model.cloneList(arranged)
  byName(after, "DP-2").scale = 2
  const out = Layout.reflow(arranged, after)
  assert.ok(Layout.isConnected(out))
  assert.deepStrictEqual(Layout.overlappingPairs(out), [])
  assert.strictEqual(Layout.sideOf(out, "HDMI-A-1", "DP-2"), "right")
})

test("rotation reflows to a portrait tile", () => {
  const after = Model.cloneList(arranged)
  byName(after, "DP-2").transform = 1
  const out = Layout.reflow(arranged, after)
  assert.deepStrictEqual(Layout.overlappingPairs(out), [])
  assert.strictEqual(Layout.rectOf(byName(out, "DP-2")).h, 2560)
})

test("nudge moves and stays flush", () => {
  const out = Layout.nudge(arranged, "eDP-1", 0, 100)
  assert.strictEqual(byName(out, "eDP-1").y, byName(arranged, "eDP-1").y + 100)
  assert.ok(Layout.isConnected(out))
})

test("staging is needed only when a move would overlap on the way", () => {
  const swapped = Layout.placeOnSide(arranged, "eDP-1", "HDMI-A-1", "right", "start")
  assert.strictEqual(Layout.needsStaging(arranged, swapped), true)
  assert.strictEqual(Layout.needsStaging(arranged, arranged), false)
})

test("fitTransform centres the layout in the canvas", () => {
  const fit = Layout.fitTransform(arranged, 500, 200, 10)
  assert.ok(fit.scale > 0 && fit.scale < 1)
  assert.ok(fit.offsetX >= 10)
})

console.log("\nLua")

const userLua = [
  "local omarchy_monitor_scale = 1.6",
  "hl.env(\"GDK_SCALE\", \"2\")",
  "hl.monitor({ output = \"\", mode = \"preferred\", position = \"auto\", scale = omarchy_monitor_scale })",
  "local dell = \"desc:Dell Inc. DELL U2719D\"",
  "hl.monitor({ output = dell, mode = \"2560x1440@60\", position = \"0x0\", scale = 1 })",
  "-- hl.monitor({ output = \"DP-9\", mode = \"1x1@1\" })",
  ""
].join("\n")

test("reads the user's rules, resolving locals and skipping comments", () => {
  const rules = Lua.findMonitorRules(userLua)
  assert.deepStrictEqual(rules, [{ selector: "desc:Dell Inc. DELL U2719D", mode: "2560x1440@60" }])
})

test("selector: reuses the user's, else a unique desc:, else the connector", () => {
  const known = Lua.findMonitorSelectors(userLua)
  assert.strictEqual(Lua.selectorFor(byName(desk, "DP-2"), desk, known), "desc:Dell Inc. DELL U2719D")
  assert.strictEqual(Lua.selectorFor(byName(desk, "HDMI-A-1"), desk, known), "desc:Samsung Electric Company U28H75x TESTSAMS01")
  const headless = Object.assign({}, byName(desk, "DP-2"), { name: "HEADLESS-2", description: "" })
  assert.strictEqual(Lua.selectorFor(headless, [headless], []), "HEADLESS-2")
})

test("keeps a configured @60 on a 59.95 Hz panel", () => {
  assert.strictEqual(Lua.configuredRefresh(byName(desk, "DP-2"), Lua.findMonitorRules(userLua)), "60")
})

test("rules write only the requests that are set", () => {
  const e = Object.assign({}, byName(desk, "DP-2"))
  assert.strictEqual(Lua.monitorRule(e, "DP-2", {}),
    "hl.monitor({ output = \"DP-2\", mode = \"2560x1440@59.95\", position = \"1920x0\", scale = 1, transform = 0, mirror = \"\", disabled = false })")
  e.vrr = 2; e.bitdepth = 10; e.cmSet = "hdr"; e.sdrbrightness = 1.2
  assert.ok(/vrr = 2, bitdepth = 10, cm = "hdr", sdrbrightness = 1.2, disabled = false/.test(Lua.monitorRule(e, "DP-2", {})))
})

test("off and mirror rules; the laptop panel's on/off is left to Omarchy", () => {
  const off = Object.assign({}, byName(desk, "HDMI-A-1"), { enabled: false })
  assert.strictEqual(Lua.monitorRule(off, "HDMI-A-1", {}), "hl.monitor({ output = \"HDMI-A-1\", disabled = true })")
  assert.strictEqual(Lua.monitorRule(Object.assign({}, byName(desk, "eDP-1"), { enabled: false }), "eDP-1", { skipDisabled: true }), "")
  const mirror = Object.assign({}, byName(desk, "HDMI-A-1"), { mirror: "eDP-1" })
  assert.ok(/position = "auto", scale = 1.5, mirror = "eDP-1"/.test(Lua.monitorRule(mirror, "HDMI-A-1", {})))
})

test("quoting refuses control characters and escapes quotes", () => {
  assert.strictEqual(Lua.luaQuote("a\"b\\c"), "\"a\\\"b\\\\c\"")
  assert.strictEqual(Lua.luaQuote("a\nb"), null)
})

test("managed block: insert at the end, replace in place, never stack", () => {
  const block = Lua.managedBlock(["hl.monitor({ output = \"DP-2\", position = \"0x0\" })"], "Desk")
  const once = Lua.upsertManagedBlock(userLua, block)
  assert.ok(once.ok && !once.replaced)
  assert.ok(once.text.startsWith(userLua))
  const twice = Lua.upsertManagedBlock(once.text, block)
  assert.ok(twice.replaced)
  assert.strictEqual(twice.text, once.text)
  assert.strictEqual(Lua.removeManagedBlock(twice.text).text.trimEnd(), userLua.trimEnd())
})

test("damaged markers are refused, not guessed at", () => {
  const broken = userLua + "\n" + Lua.BLOCK_BEGIN + "\n"
  assert.strictEqual(Lua.upsertManagedBlock(broken, "x").ok, false)
})

test("eval safety: only plain rules pass", () => {
  assert.ok(Lua.evalLinesOk("hl.monitor({ output = \"DP-2\", position = \"0x0\" })\nhl.workspace_rule({ workspace = \"1\", monitor = \"DP-2\" })"))
  assert.ok(!Lua.evalLinesOk("os.execute(\"rm -rf ~\")"))
  assert.ok(!Lua.evalLinesOk("hl.monitor({ output = os.getenv(\"X\") })"))
  assert.ok(!Lua.evalLinesOk("hl.monitor({ output = \"x\" }) hl.dsp.exec_cmd(\"y\")"))
  assert.ok(Lua.evalLinesOk("hl.monitor({ output = \"desc:os io require\", position = \"0x0\" })"))
})

test("finds what other display plugins left behind", () => {
  const text = userLua + [
    "hl.monitor({ output = \"HDMI-A-1\", mode = \"3840x2160@30.00000\", position = \"1920x0\", scale = 3, transform = 0 })",
    "-- BEGIN OMARCHY DISPLAY MANAGER (AUTO-GENERATED)",
    "hl.monitor({",
    "  output = \"eDP-1\",",
    "})",
    "-- END OMARCHY DISPLAY MANAGER",
    ""
  ].join("\n")
  const items = Lua.findForeignRules(text)
  // `output = dell` names a local: written by hand, so it is not offered.
  assert.deepStrictEqual(items.map(i => i.label), ["Display Manager (Azteriisk) block", "Rule for HDMI-A-1"])
  const cleaned = Lua.removeForeign(text, items)
  assert.ok(!/HDMI-A-1/.test(cleaned))
  assert.ok(!/BEGIN OMARCHY/.test(cleaned))
  assert.ok(/output = dell/.test(cleaned))
})

console.log("\nProfiles")

test("store round-trips and drops junk", () => {
  const store = Profiles.parseStore(JSON.stringify({ profiles: [{ displays: [] }, { displays: ["a"], name: "A", laptop: "bogus" }, 7] }))
  assert.strictEqual(store.profiles.length, 1)
  assert.strictEqual(store.profiles[0].laptop, "extend")
  assert.deepStrictEqual(Profiles.parseStore(Profiles.serializeStore(store)), store)
  assert.deepStrictEqual(Profiles.parseStore("not json"), Profiles.emptyStore())
})

test("a saved profile is found again after the cable moves to another port", () => {
  const saved = Profiles.upsertProfile(Profiles.emptyStore(), desk, { name: "Desk" }, 100)
  const moved = Model.cloneList(desk)
  byName(moved, "DP-2").name = "DP-3"
  const found = Profiles.profileFor(saved.store, moved)
  assert.ok(found)
  assert.strictEqual(found.name, "Desk")
  const draft = Profiles.draftFromProfile(moved, found)
  assert.strictEqual(byName(draft, "DP-3").x, byName(desk, "DP-2").x)
})

test("upsert replaces the profile for the same displays", () => {
  let s = Profiles.upsertProfile(Profiles.emptyStore(), desk, { name: "Desk" }, 100).store
  const edited = Model.cloneList(desk)
  byName(edited, "HDMI-A-1").scale = 2
  s = Profiles.upsertProfile(s, edited, null, 200).store
  assert.strictEqual(s.profiles.length, 1)
  assert.strictEqual(s.profiles[0].name, "Desk")
  assert.strictEqual(s.profiles[0].settings["Samsung Electric Company U28H75x TESTSAMS01"].scale, 2)
})

test("draftFromProfile ignores modes the display no longer offers", () => {
  const s = Profiles.upsertProfile(Profiles.emptyStore(), desk, null, 1).store
  s.profiles[0].settings["Dell Inc. DELL U2719D TESTDELL01"].mode = "5120x2880@60"
  const draft = Profiles.draftFromProfile(desk, s.profiles[0])
  assert.strictEqual(byName(draft, "DP-2").width, 2560)
})

test("nearest profile shares the most displays", () => {
  let s = Profiles.upsertProfile(Profiles.emptyStore(), laptop, { name: "Laptop" }, 1).store
  s = Profiles.upsertProfile(s, desk.filter(e => e.name !== "HDMI-A-1"), { name: "Dell" }, 2).store
  assert.strictEqual(Profiles.nearestProfile(s, desk).name, "Dell")
})

test("laptop modes", () => {
  const ext = Profiles.applyLaptopMode(desk, "external-only")
  assert.deepStrictEqual(ext.commands[1], ["omarchy-hyprland-monitor-internal", "off"])
  const only = Profiles.applyLaptopMode(desk, "internal-only")
  assert.strictEqual(byName(only.draft, "DP-2").enabled, false)
  assert.strictEqual(Profiles.currentLaptopMode(only.draft), "internal-only")
  assert.strictEqual(Profiles.currentLaptopMode(desk), "extend")
  assert.strictEqual(Profiles.nextLaptopMode("internal-only"), "extend")
  assert.strictEqual(Profiles.applyLaptopMode(laptop, "mirror").ok, false)
})

test("workspace plans: sequential, interleaved, manual", () => {
  const seq = Profiles.planWorkspaces(desk, { strategy: "sequential", count: 9 })
  assert.deepStrictEqual(seq.map(r => r.name), ["eDP-1", "eDP-1", "eDP-1", "DP-2", "DP-2", "DP-2", "HDMI-A-1", "HDMI-A-1", "HDMI-A-1"])
  assert.deepStrictEqual(seq.filter(r => r.isDefault).map(r => r.workspace), [1, 4, 7])
  const inter = Profiles.planWorkspaces(desk, { strategy: "interleaved", count: 4 })
  assert.deepStrictEqual(inter.map(r => r.name), ["eDP-1", "DP-2", "HDMI-A-1", "eDP-1"])
  const manual = Profiles.planWorkspaces(desk, { strategy: "manual", count: 2, manual: { "2": "Chimei Innolux Corporation 0x1521" } })
  assert.deepStrictEqual(manual.map(r => r.name), ["eDP-1", "eDP-1"])
  assert.deepStrictEqual(Profiles.planWorkspaces(desk, { strategy: "off" }), [])
})

test("workspace moves only for workspaces on the wrong display", () => {
  const plan = Profiles.planWorkspaces(desk, { strategy: "interleaved", count: 3 })
  const moves = Profiles.workspaceMoves(plan, [{ id: 1, monitor: "eDP-1" }, { id: 2, monitor: "eDP-1" }, { id: 7, monitor: "eDP-1" }])
  assert.deepStrictEqual(moves, [{ workspace: 2, name: "DP-2" }])
})

console.log("\nPlan")

test("an unchanged draft is valid and has no changes", () => {
  const plan = Plan.buildPlan({ snapshot: desk, draft: desk, fileText: userLua, fileState: "present", persist: true })
  assert.ok(plan.ok, JSON.stringify(plan.errors))
  assert.strictEqual(plan.changes.length, 0)
  assert.ok(plan.canPersist)
  assert.ok(plan.fileText.startsWith(userLua))
  assert.ok(Lua.evalLinesOk(plan.applyLua))
})

test("a scale change reflows, previews, and persists by desc:", () => {
  const draft = Model.cloneList(desk)
  byName(draft, "DP-2").scale = 1.25
  const plan = Plan.buildPlan({ snapshot: desk, draft: Layout.reflow(desk, draft), fileText: userLua, fileState: "present", persist: true, note: "Desk" })
  assert.ok(plan.ok, JSON.stringify(plan.errors))
  assert.ok(plan.changes.some(c => c.name === "DP-2" && c.changes.some(x => /scale 1 → 1.25/.test(x))))
  assert.ok(/output = "desc:Dell Inc. DELL U2719D", mode = "2560x1440@60"/.test(plan.block))
  assert.ok(/-- Desk/.test(plan.block))
  assert.ok(/CHANGES/.test(Plan.planPreview(plan, 15)))
})

test("refuses a draft with every display off or a broken mirror", () => {
  const off = Model.cloneList(desk).map(e => Object.assign(e, { enabled: false }))
  assert.ok(Plan.buildPlan({ snapshot: desk, draft: off }).errors.some(e => e.code === "all-off"))
  const loop = Model.cloneList(desk)
  byName(loop, "DP-2").mirror = "HDMI-A-1"
  byName(loop, "HDMI-A-1").mirror = "DP-2"
  assert.ok(Plan.buildPlan({ snapshot: desk, draft: loop }).errors.some(e => e.code === "bad-mirror"))
})

test("refuses an unclean scale and a mode the display does not offer", () => {
  const bad = Model.cloneList(desk)
  byName(bad, "DP-2").scale = 1.3
  byName(bad, "HDMI-A-1").width = 1234
  const codes = Plan.buildPlan({ snapshot: desk, draft: bad }).errors.map(e => e.code)
  assert.ok(codes.includes("bad-scale"))
  assert.ok(codes.includes("bad-mode"))
})

test("swapping displays stages through a parking column", () => {
  const swapped = Layout.placeOnSide(desk.filter(Model.isArrangeable), "eDP-1", "HDMI-A-1", "right", "start")
  const draft = Model.cloneList(desk).map(e => Object.assign(e, byName(swapped, e.name) ? { x: byName(swapped, e.name).x, y: byName(swapped, e.name).y } : {}))
  const plan = Plan.buildPlan({ snapshot: desk, draft })
  assert.ok(plan.ok, JSON.stringify(plan.errors))
  const first = plan.applyLua.split("\n")[0]
  assert.ok(/^hl\.monitor\(\{ output = "[^"]+", position = "\d+x\d+" \}\)$/.test(first))
})

test("laptop mode carries Omarchy's commands and their revert", () => {
  const plan = Plan.buildPlan({ snapshot: desk, draft: desk, laptopMode: "external-only" })
  assert.ok(plan.ok)
  assert.deepStrictEqual(plan.commands[1], ["omarchy-hyprland-monitor-internal", "off"])
  assert.deepStrictEqual(plan.revertCommands[1], ["omarchy-hyprland-monitor-internal", "on"])
  assert.ok(plan.changes.some(c => c.name === "Laptop"))
})

test("workspace rules go live by connector and into the file by panel", () => {
  const plan = Plan.buildPlan({ snapshot: desk, draft: desk, persist: true, fileState: "missing",
                                workspaces: { strategy: "sequential", count: 3 }, liveWorkspaces: [{ id: 3, monitor: "eDP-1" }] })
  assert.ok(/hl\.workspace_rule\(\{ workspace = "1", monitor = "eDP-1", default = true \}\)/.test(plan.applyLua))
  assert.ok(/hl\.workspace_rule\(\{ workspace = "2", monitor = "desc:Dell Inc. DELL U2719D TESTDELL01", default = true \}\)/.test(plan.block))
  assert.deepStrictEqual(plan.moves, [{ workspace: 3, name: "HDMI-A-1" }])
})

test("verify catches a refused or rounded setting", () => {
  const draft = Model.cloneList(desk)
  byName(draft, "DP-2").scale = 1.25
  const live = Model.cloneList(desk)
  assert.deepStrictEqual(Plan.verifyApplied(draft, live), ["DP-2 scale is 1, not 1.25"])
  assert.deepStrictEqual(Plan.verifyApplied(desk, live), [])
})

test("countdown and watchdog timing", () => {
  assert.deepStrictEqual(Plan.confirmState(0, 5000, 15), { remaining: 10, expired: false, progress: 1 / 3 })
  assert.strictEqual(Plan.confirmState(0, 16000, 15).expired, true)
  assert.strictEqual(Plan.watchdogSeconds(15), 18)
})

console.log("\nAdditions")

test("custom modes pass validation within sane bounds", () => {
  const draft = Model.cloneList(desk)
  Object.assign(byName(draft, "DP-2"), { width: 2560, height: 1080, refresh: 75, customMode: true })
  const plan = Plan.buildPlan({ snapshot: desk, draft: Layout.reflow(desk, draft) })
  assert.ok(plan.ok, JSON.stringify(plan.errors))
  assert.ok(/mode = "2560x1080@75"/.test(plan.applyLua))
  Object.assign(byName(draft, "DP-2"), { width: 99999 })
  assert.ok(Plan.buildPlan({ snapshot: desk, draft }).errors.some(e => e.code === "bad-mode"))
})

test("an ICC profile is written only for a safe absolute path", () => {
  const e = Object.assign({}, byName(desk, "DP-2"), { icc: "/home/me/dell.icc" })
  assert.ok(/icc = "\/home\/me\/dell.icc"/.test(Lua.monitorRule(e, "DP-2", {})))
  e.icc = "relative.icc"
  assert.ok(!/icc/.test(Lua.monitorRule(e, "DP-2", {})))
  e.icc = "/x\"); os.execute(\"y.icc"
  assert.ok(!/icc/.test(Lua.monitorRule(e, "DP-2", {})))
})

test("global options: only known keys and values, with a revert", () => {
  assert.strictEqual(Lua.globalLua("general.allow_tearing", true), "hl.config({ general = { allow_tearing = true } })")
  assert.strictEqual(Lua.globalLua("general.allow_tearing", 3), null)
  assert.strictEqual(Lua.globalLua("misc.bogus", 1), null)
  assert.ok(Lua.evalLinesOk("hl.config({ render = { direct_scanout = 2 } })"))
  assert.ok(!Lua.evalLinesOk("hl.config({ misc = { disable_hyprland_logo = true } })"))
  const plan = Plan.buildPlan({ snapshot: desk, draft: desk, persist: true, fileState: "missing",
    globals: { "general.allow_tearing": true }, liveGlobals: { "general.allow_tearing": false } })
  assert.ok(plan.ok, JSON.stringify(plan.errors))
  assert.ok(/allow_tearing = true/.test(plan.applyLua))
  assert.ok(/allow_tearing = false/.test(plan.revertLua))
  assert.ok(/allow_tearing = true/.test(plan.block))
  assert.ok(plan.changes.some(c => c.name === "Global"))
  const same = Plan.buildPlan({ snapshot: desk, draft: desk, globals: { "general.allow_tearing": false }, liveGlobals: { "general.allow_tearing": false } })
  assert.strictEqual(same.changes.length, 0)
})

test("a new workspace plan reloads first to drop the old rules", () => {
  const old = { strategy: "sequential", count: 6 }
  assert.strictEqual(Plan.buildPlan({ snapshot: desk, draft: desk, workspaces: { strategy: "interleaved", count: 6 }, previousWorkspaces: old }).reloadFirst, true)
  assert.strictEqual(Plan.buildPlan({ snapshot: desk, draft: desk, workspaces: old, previousWorkspaces: old }).reloadFirst, false)
  assert.strictEqual(Plan.buildPlan({ snapshot: desk, draft: desk, workspaces: old, previousWorkspaces: null }).reloadFirst, false)
})

test("verify leaves the built-in panel to Omarchy's toggles in laptop modes", () => {
  const live = Model.cloneList(desk)
  byName(live, "eDP-1").enabled = false
  byName(live, "DP-2").x = 0
  assert.ok(Plan.verifyApplied(desk, live).length > 0)
  assert.deepStrictEqual(Plan.verifyApplied(desk, live, { laptopMode: "external-only" }), [])
})

test("store keeps globals and per-display ICC and custom modes", () => {
  const draft = Model.cloneList(desk)
  Object.assign(byName(draft, "DP-2"), { icc: "/a/b.icc", width: 2560, height: 1080, refresh: 75, customMode: true })
  let s = Profiles.upsertProfile(Profiles.emptyStore(), draft, null, 1).store
  s = Profiles.setGlobals(s, { "general.allow_tearing": true, "bad key": 1, "render.direct_scanout": "x" })
  const back = Profiles.parseStore(Profiles.serializeStore(s))
  assert.deepStrictEqual(back.globals, { "general.allow_tearing": true })
  const p = Profiles.profileFor(back, desk)
  const d = Profiles.draftFromProfile(desk, p)
  assert.strictEqual(byName(d, "DP-2").icc, "/a/b.icc")
  assert.strictEqual(byName(d, "DP-2").width, 2560)
  assert.strictEqual(byName(d, "DP-2").customMode, true)
})

test("the rule reader caches by text", () => {
  const a = Lua.findMonitorRules(userLua)
  assert.strictEqual(Lua.findMonitorRules(userLua), a)
  assert.notStrictEqual(Lua.findMonitorRules(userLua + "\n"), a)
})

console.log("\nTier 1")

test("a request taken back is written as Hyprland's default", () => {
  const base = Model.cloneList(desk)
  Object.assign(byName(base, "DP-2"), { cmSet: "hdr", bitdepth: 10, vrr: 1, sdrbrightness: 1.4, maxLuminance: 600 })
  const draft = Model.cloneList(base)
  Object.assign(byName(draft, "DP-2"), { cmSet: "", bitdepth: 0, vrr: -1, sdrbrightness: 0, maxLuminance: null })
  assert.deepStrictEqual(Lua.resetsBetween(byName(base, "DP-2"), byName(draft, "DP-2")).sort(),
                         ["bitdepth", "cmSet", "maxLuminance", "sdrbrightness", "vrr"])
  const plan = Plan.buildPlan({ snapshot: desk, base, draft })
  assert.ok(plan.ok, JSON.stringify(plan.errors))
  const dp = plan.applyLua.split("\n").filter(l => /"DP-2"/.test(l)).join("\n")
  for (const f of ['cm = "auto"', "bitdepth = 8", "sdrbrightness = 1", "max_luminance = -1"]) assert.ok(dp.includes(f), f + " in " + dp)
  // the file never gets defaults: the user's own rules decide again
  assert.ok(!/cm = "auto"/.test(Plan.buildPlan({ snapshot: desk, base, draft, persist: true, fileState: "missing" }).block))
})

test("an adaptive-sync change goes out nudged, then for real", () => {
  const draft = Model.cloneList(desk)
  byName(draft, "DP-2").vrr = 2
  const plan = Plan.buildPlan({ snapshot: desk, draft })
  assert.ok(plan.ok, JSON.stringify(plan.errors))
  assert.ok(/output = "DP-2".*vrr = 2.*sdrsaturation = 1.0001/.test(plan.applyLua))
  assert.ok(/output = "DP-2".*vrr = 2.*sdrsaturation = 1\b/.test(plan.applyLater))
  assert.ok(/output = "DP-2".*vrr = -1.*sdrsaturation = 1\b/.test(plan.revertLater))
  assert.ok(Lua.evalLinesOk(plan.applyLater))
  assert.strictEqual(Plan.buildPlan({ snapshot: desk, draft: desk }).applyLater, "")
})

test("clearing an ICC profile reloads first (Hyprland refuses an empty path)", () => {
  const base = Model.cloneList(desk)
  byName(base, "DP-2").icc = "/a/b.icc"
  assert.strictEqual(Plan.buildPlan({ snapshot: desk, base, draft: desk }).reloadFirst, true)
})

test("the laptop panel's mirroring is left to Omarchy", () => {
  assert.ok(!/mirror/.test(Lua.monitorRule(byName(desk, "eDP-1"), "eDP-1", { skipMirror: true, skipDisabled: true })))
})

test("mode keywords, automatic positions and EDID modelines", () => {
  const e = Object.assign({}, byName(desk, "DP-2"), { modeKeyword: "highrr", positionAuto: "auto-right" })
  assert.ok(/mode = "highrr", position = "auto-right"/.test(Lua.monitorRule(e, "DP-2", {})))
  assert.ok(Lua.modelineOk("342.06 1920 1968 2000 2080 1080 1083 1088 1142 -hsync -vsync"))
  assert.ok(!Lua.modelineOk("342 1920; os.execute"))
  const m = Object.assign({}, byName(desk, "DP-2"), { modeline: "241.5 2560 2608 2640 2720 1440 1443 1448 1481 +hsync -vsync", width: 2560, height: 1440, refresh: 59.95 })
  assert.ok(/mode = "modeline 241.5 2560/.test(Lua.monitorRule(m, "DP-2", {})))
  assert.ok(Plan.buildPlan({ snapshot: desk, draft: desk.map(x => x.name === "DP-2" ? m : x) }).ok)
})

test("HDR details: valid ones written, junk dropped from profiles", () => {
  const e = Object.assign({}, byName(desk, "DP-2"), { supportsHdr: 1, sdrMaxLuminance: 203, sdrEotf: "gamma22", maxLuminance: 99999 })
  const rule = Lua.monitorRule(e, "DP-2", {})
  assert.ok(/supports_hdr = 1/.test(rule) && /sdr_max_luminance = 203/.test(rule) && /sdr_eotf = "gamma22"/.test(rule))
  assert.ok(!/max_luminance = 99999/.test(rule))
  const s = Profiles.cleanSettings({ supportsHdr: 1, maxLuminance: "x", sdrEotf: "bogus" })
  assert.strictEqual(s.supportsHdr, 1)
  assert.strictEqual(s.maxLuminance, null)
  assert.strictEqual(s.sdrEotf, "")
})

console.log("\nTier 2")

const edidX = [
  "    DTD 1:  2560x1440  165.000000 Hz  16:9",
  '      Modeline "2560x1440_165.00" 645.000  2560 2568 2600 2640  1440 1443 1448 1481  +HSync -VSync',
  '      Modeline "2560x1440_59.95" 241.500  2560 2608 2640 2720  1440 1443 1448 1481  +HSync -VSync'
].join("\n")

test("EDID modelines become Hyprland modelines", () => {
  const modes = Model.parseModelines(edidX)
  assert.strictEqual(modes.length, 2)
  assert.strictEqual(modes[0].refresh, 164.97)
  assert.strictEqual(modes[1].modeline, "241.5 2560 2608 2640 2720 1440 1443 1448 1481 +hsync -vsync")
  assert.ok(Lua.modelineOk(modes[0].modeline))
  assert.strictEqual(Model.parseModelines(fixture("edid-laptop.txt")).length, 0)
})

test("EDID-only modes join the list and a drifted rate maps back", () => {
  const dell = Object.assign({}, byName(desk, "DP-2"), { refresh: 59.83 })
  const withEdid = Model.withEdidModes(dell, Model.parseModelines(edidX))
  assert.ok(Model.hasMode(withEdid, 2560, 1440, 164.97))
  assert.strictEqual(Model.modelineFor(withEdid, 2560, 1440, 164.97).split(" ")[0], "645")
  assert.strictEqual(Model.modelineFor(withEdid, 2560, 1440, 59.95), "")
  const custom = Model.parseMonitors(JSON.stringify([{ name: "DP-9", width: 2560, height: 1440, refreshRate: 164.6, scale: 1,
                                                       availableModes: ["1920x1080@60.00Hz"] }]))[0]
  const mapped = Model.withEdidModes(custom, Model.parseModelines(edidX))
  assert.strictEqual(mapped.refresh, 164.97)
  assert.ok(mapped.modeline.startsWith("645"))
})

test("native only from the EDID: suggest the gentlest rate at 50 Hz or more", () => {
  const e = Model.withEdidModes(Object.assign({}, byName(desk, "DP-2"), {
    width: 1920, height: 1080, refresh: 60,
    modes: Model.parseModes(["1920x1080@60.00Hz"]) }), Model.parseModelines(edidX))
  const ins = Model.healthInsights(e, null).find(i => i.code === "not-native")
  assert.ok(ins && /only the EDID/.test(ins.message))
  assert.strictEqual(ins.fix.refresh, 59.95)
})

test("per-monitor memory: a known monitor in a new set gets its settings and place", () => {
  const kept = Model.cloneList(desk)
  byName(kept, "DP-2").scale = 1.25
  let s = Profiles.rememberMonitors(Profiles.emptyStore(), kept, 5)
  const mem = s.monitors["Dell Inc. DELL U2719D TESTDELL01"]
  assert.strictEqual(mem.scale, 1.25)
  assert.strictEqual(mem.neighbor, "Chimei Innolux Corporation 0x1521")
  s = Profiles.parseStore(Profiles.serializeStore(s))
  // A new set: the laptop and the Dell only, Dell back at 1x somewhere else.
  const now = Model.cloneList(desk.filter(m => m.name !== "HDMI-A-1"))
  Object.assign(byName(now, "DP-2"), { scale: 1, x: 0, y: 1080 })
  Object.assign(byName(now, "eDP-1"), { x: 0, y: 0 })
  const d = Profiles.draftFromMemory(now, s)
  assert.strictEqual(byName(d, "DP-2").scale, 1.25)
  assert.strictEqual(Layout.sideOf(d.filter(Model.isArrangeable), "DP-2", "eDP-1"), "right")
  assert.strictEqual(Profiles.draftFromMemory(laptop.map(m => Object.assign({}, m, { description: "Other 0x1" })), s), null)
})

test("profiles remember the connector each display was on", () => {
  const s = Profiles.upsertProfile(Profiles.emptyStore(), desk, null, 1).store
  assert.strictEqual(s.profiles[0].ports["Dell Inc. DELL U2719D TESTDELL01"], "DP-2")
  const entries = Profiles.entriesFromProfile(s.profiles[0])
  assert.deepStrictEqual(entries.map(e => e.name).sort(), ["DP-2", "HDMI-A-1", "eDP-1"])
  assert.strictEqual(byName(entries, "DP-2").description, "Dell Inc. DELL U2719D TESTDELL01")
})

test("string global options are quoted and checked", () => {
  assert.strictEqual(Lua.globalLua("render.cm_sdr_eotf", "gamma22"), 'hl.config({ render = { cm_sdr_eotf = "gamma22" } })')
  assert.strictEqual(Lua.globalLua("render.cm_sdr_eotf", "evil"), null)
  assert.ok(Lua.evalLinesOk(Lua.globalLua("cursor.no_hardware_cursors", 2)))
  assert.ok(!Lua.evalLinesOk('hl.config({ cursor = { inactive_timeout = 5 } })'))
})

console.log("\nTier 3")

test("several profiles for one set: the last used wins, duplicates start in force", () => {
  let s = Profiles.upsertProfile(Profiles.emptyStore(), desk, { name: "Desk" }, 10).store
  const desk1 = s.profiles[0]
  const dup = Profiles.duplicateProfile(s, desk1.id, 20)
  s = dup.store
  assert.strictEqual(s.profiles.length, 2)
  assert.strictEqual(Profiles.profileFor(s, desk).id, dup.profile.id)
  s = Profiles.selectProfile(s, desk1.id, 30)
  assert.strictEqual(Profiles.profileFor(s, desk).id, desk1.id)
  // Keeping goes into the one in force, not a new one.
  const edited = Model.cloneList(desk)
  byName(edited, "DP-2").scale = 1.25
  s = Profiles.upsertProfile(s, edited, null, 40).store
  assert.strictEqual(s.profiles.length, 2)
  assert.strictEqual(Profiles.profileById(s, desk1.id).settings["Dell Inc. DELL U2719D TESTDELL01"].scale, 1.25)
  assert.strictEqual(Profiles.luaProfiles(s)[0].id, desk1.id)
})

test("each laptop mode keeps its own arrangement", () => {
  let s = Profiles.upsertProfile(Profiles.emptyStore(), desk, { laptop: "extend" }, 1).store
  const mirrored = Model.cloneList(desk)
  byName(mirrored, "HDMI-A-1").scale = 2
  s = Profiles.upsertProfile(s, mirrored, { laptop: "mirror" }, 2).store
  const p = Profiles.profileFor(s, desk)
  assert.deepStrictEqual(Object.keys(p.variants).sort(), ["extend", "mirror"])
  assert.strictEqual(byName(Profiles.variantDraft(desk, p, "mirror"), "HDMI-A-1").scale, 2)
  assert.strictEqual(byName(Profiles.variantDraft(desk, p, "extend"), "HDMI-A-1").scale, 1.5)
  assert.strictEqual(Profiles.variantDraft(desk, p, "external-only"), null)
})

test("the anchor display is what the layout is measured from", () => {
  let s = Profiles.upsertProfile(Profiles.emptyStore(), desk, null, 1).store
  s = Profiles.setProfileField(s, s.profiles[0].id, "anchor", "Dell Inc. DELL U2719D TESTDELL01")
  assert.strictEqual(Profiles.parseStore(Profiles.serializeStore(s)).profiles[0].anchor, "Dell Inc. DELL U2719D TESTDELL01")
  assert.strictEqual(Profiles.setProfileField(s, s.profiles[0].id, "anchor", "nobody").profiles[0].anchor, "Dell Inc. DELL U2719D TESTDELL01")
})

test("mirroring picks a mode both displays offer", () => {
  const c = Model.commonMode(byName(desk, "HDMI-A-1"), byName(desk, "DP-2"))
  assert.ok(c && c.width === 2560 && c.height === 1440 || c && Model.hasMode(byName(desk, "DP-2"), c.width, c.height, c.refreshB))
  const lap = Model.commonMode(byName(desk, "DP-2"), byName(desk, "eDP-1"))
  assert.deepStrictEqual([lap.width, lap.height], [1920, 1080])
})

test("layout health: overlap, gap, broken mirror and origin, then repaired", () => {
  const bad = Model.cloneList(desk)
  byName(bad, "DP-2").x = 100
  byName(bad, "HDMI-A-1").x = 20000
  const issues = Plan.layoutHealth(bad).map(i => i.code)
  assert.ok(issues.includes("overlap") && issues.includes("gap"))
  const fixed = Plan.repairDraft(bad)
  assert.deepStrictEqual(Plan.layoutHealth(fixed), [])
  const mir = Model.cloneList(desk)
  byName(mir, "DP-2").mirror = "HDMI-A-1"
  byName(mir, "HDMI-A-1").enabled = false
  assert.ok(Plan.layoutHealth(mir).some(i => i.code === "mirror"))
  assert.strictEqual(byName(Plan.repairDraft(mir), "DP-2").mirror, "")
  assert.deepStrictEqual(Plan.layoutHealth(desk), [])
})

const Menu = load("Menu.js")

test("menu row: added and removed without touching anything else", () => {
  const original = '{\n  // my rows\n  "setup.foo": { "label": "Foo", "action": "foo" }, /* keep */\n  "x": [1, 2,],\n}\n'
  const added = Menu.addRow(original)
  assert.ok(added.ok, added.error)
  assert.ok(added.text.includes("// my rows") && added.text.includes("/* keep */"))
  assert.ok(Menu.hasRow(added.text))
  assert.ok(Menu.addRow(added.text).unchanged)
  const removed = Menu.removeRow(added.text)
  assert.ok(removed.ok, removed.error)
  assert.ok(!Menu.hasRow(removed.text))
  assert.deepStrictEqual(Menu.parse(removed.text), Menu.parse(original))
  assert.ok(Menu.addRow("").ok)
  assert.ok(Menu.addRow("{}").text.includes("setup.omnidisplay"))
  assert.strictEqual(Menu.addRow("{ broken").ok, false)
  assert.strictEqual(Menu.parse('{"a": "//not a comment"}').a, "//not a comment")
})

console.log("\nhyprmoncfg ideas")

test("workspace monitor order, persistence and chip moves", () => {
  const seq = { strategy: "sequential", count: 6 }
  const plain = Profiles.planWorkspaces(desk, seq)
  assert.deepStrictEqual(plain.filter(r => r.workspace === 1).map(r => r.name), ["eDP-1"])
  const moved = Profiles.moveInOrder(desk, seq, "HDMI-A-1", -1)
  const moved2 = Profiles.moveInOrder(desk, moved, "HDMI-A-1", -1)
  const after = Profiles.planWorkspaces(desk, moved2)
  assert.strictEqual(after.find(r => r.workspace === 1).name, "HDMI-A-1")
  const moves = Profiles.chipMoves(plain, after)
  assert.ok(moves.length > 0 && moves.every(m => m.from !== m.to))
  const first = Profiles.planWorkspaces(desk, { strategy: "sequential", count: 6, persistence: "first" })
  assert.deepStrictEqual(first.filter(r => r.persistent).map(r => r.workspace), [1, 3, 5])
  assert.strictEqual(Profiles.cleanWorkspaces({ persistent: true }).persistence, "all")
  assert.ok(/persistent = true/.test(Lua.workspaceRule({ workspace: 1, monitor: "DP-2", isDefault: true, persistent: true })))
})

test("match score and reasons", () => {
  const s = Profiles.upsertProfile(Profiles.emptyStore(), desk, null, 1).store
  const exact = Profiles.matchInfo(s.profiles[0], desk)
  assert.strictEqual(exact.score, 300)
  assert.ok(exact.exact && /3 displays connected/.test(exact.reasons[0]))
  const partial = Profiles.matchInfo(s.profiles[0], laptop)
  assert.ok(!partial.exact && partial.score >= 0 && partial.reasons.length === 2)
})

test("every sharp scale for a mode", () => {
  const s = Model.sharpScales(1920, 1080)
  assert.ok(s.includes(1) && s.includes(1.5) && s.includes(2) && s.includes(1.6))
  assert.ok(s.every(v => Model.cleanScale(v, 1920, 1080) === v))
  assert.strictEqual(Model.inchesLabel(byName(desk, "DP-2")), "27\"")
})

console.log("\nCast")

test("cast state: one list, sessions win over peers", () => {
  const state = Cast.parseState(JSON.stringify({
    status: "streaming",
    peers: [{ id: "miracast:aa", name: "LG", protocol: "miracast" }, { id: "airplay:1.2.3.4", name: "Apple TV", protocol: "airplay" }],
    connected: [{ id: "miracast:aa", name: "LG", protocol: "miracast", mode: "extend", output: "HEADLESS-3" }]
  }))
  const list = Cast.displays(state)
  assert.strictEqual(list.length, 2)
  assert.strictEqual(list.find(d => d.id === "miracast:aa").connected, true)
  assert.strictEqual(Cast.glyphMode(state), "streaming")
  assert.strictEqual(Cast.supportsExtend("airplay", state), false)
  assert.deepStrictEqual(Cast.castOutputs(state), ["HEADLESS-3"])
})

finish()
