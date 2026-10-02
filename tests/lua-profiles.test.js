// Runs the Lua OmniDisplay writes into monitors.lua in a real Lua interpreter,
// with a fake `hl` and a fake sysfs, to check the boot-time profile handler:
// the matching profile at load, switching on hotplug, no re-apply for the
// same set, a disabled display matched by port, and no error escaping.
// Run with: node tests/lua-profiles.test.js   (skipped without `lua`)

const assert = require("assert")
const fs = require("fs")
const os = require("os")
const path = require("path")
const { execFileSync } = require("child_process")
const { load, test, fixture, finish } = require("./load")

const Model = load("Model.js")
const Profiles = load("Profiles.js")
const Plan = load("Plan.js")
const Lua = load("Lua.js")

let lua = null
for (const bin of ["lua", "lua5.4", "lua5.3"]) {
  try { execFileSync(bin, ["-v"], { stdio: "ignore" }); lua = bin; break } catch (e) {}
}
if (!lua) { console.log("lua not installed: skipped"); process.exit(0) }

const desk = Model.parseMonitors(fixture("monitors-desk.json"))
const laptop = desk.filter(m => m.internal)
const byName = (l, n) => Model.entryByName(l, n)

// Two profiles: the laptop alone at 1.25x, and the desk with the Dell at 1.5x.
let store = Profiles.emptyStore()
const alone = Model.cloneList(laptop)
alone[0].scale = 1.25
store = Profiles.upsertProfile(store, alone, { name: "Laptop" }, 1).store
const atDesk = Model.cloneList(desk)
byName(atDesk, "DP-2").scale = 1.5
store = Profiles.upsertProfile(store, Profiles.normalizeDraft(atDesk), { name: "Desk", workspaces: { strategy: "sequential", count: 4 } }, 2).store
store = Profiles.rememberMonitors(store, atDesk, 2)

const plan = Plan.buildPlan({ snapshot: laptop, draft: laptop, persist: true, fileState: "missing", store })
assert.ok(plan.ok, JSON.stringify(plan.errors))

const dir = fs.mkdtempSync(path.join(os.tmpdir(), "omnidisplay-lua-"))
const blockFile = path.join(dir, "block.lua")
fs.writeFileSync(blockFile, plan.block)

function run(script) {
  const harness = path.join(dir, "harness.lua")
  fs.writeFileSync(harness, `
local applied, workspaces, handlers = {}, {}, {}
monitors = {}
sysfs = ""
hl = {
  get_monitors = function() return monitors end,
  monitor = function(r) applied[#applied + 1] = r end,
  workspace_rule = function(w) workspaces[#workspaces + 1] = w end,
  on = function(ev, fn) handlers[ev] = fn end,
  env = function() end, config = function() end,
}
io.popen = function()
  local lines, i = {}, 0
  for l in sysfs:gmatch("[^\\n]+") do lines[#lines + 1] = l end
  return { lines = function() return function() i = i + 1 return lines[i] end end, close = function() end }
end
function show(tag)
  for _, r in ipairs(applied) do print(tag .. " " .. tostring(r.output) .. " scale=" .. tostring(r.scale) .. " pos=" .. tostring(r.position) .. " disabled=" .. tostring(r.disabled)) end
  for _, w in ipairs(workspaces) do print(tag .. "-ws " .. tostring(w.workspace) .. " " .. tostring(w.monitor)) end
  applied, workspaces = {}, {}
end
function fire(ev) if handlers[ev] then handlers[ev]() end end
${script}
`)
  return execFileSync(lua, [harness], { encoding: "utf8" })
}

const EDP = '{ name = "eDP-1", description = "Chimei Innolux Corporation 0x1521" }'
const DELL = '{ name = "DP-2", description = "Dell Inc. DELL U2719D TESTDELL01" }'
const SAMS = '{ name = "HDMI-A-1", description = "Samsung Electric Company U28H75x TESTSAMS01" }'

console.log("boot-time profiles in Lua")

test("the block parses and runs with nothing connected", () => {
  const out = run(`sysfs = "" monitors = {} dofile("${blockFile}") show("load")`)
  assert.ok(!/error/i.test(out))
})

test("at load, the profile for the connected set is applied", () => {
  const out = run(`sysfs = "eDP-1 connected\\nDP-2 connected\\nHDMI-A-1 connected\\n"
    monitors = { ${EDP}, ${DELL}, ${SAMS} } dofile("${blockFile}") show("load")`)
  assert.ok(/load desc:Dell Inc. DELL U2719D TESTDELL01 scale=1.5 pos=\d+x\d+/.test(out), out)
  assert.ok(/load-ws 1 /.test(out), out)
})

test("unplugging switches to the laptop profile, once", () => {
  const out = run(`sysfs = "eDP-1 connected\\nDP-2 connected\\nHDMI-A-1 connected\\n"
    monitors = { ${EDP}, ${DELL}, ${SAMS} } dofile("${blockFile}") show("load")
    sysfs = "eDP-1 connected\\nDP-2 disconnected\\nHDMI-A-1 disconnected\\n" monitors = { ${EDP} }
    fire("monitor.removed") show("unplug") fire("monitor.removed") show("again")`)
  assert.ok(/unplug desc:Chimei Innolux Corporation 0x1521 scale=1.25 pos=\d+x\d+/.test(out), out)
  assert.ok(!/^again /m.test(out), "re-applied for the same set:\n" + out)
})

test("a set with no profile applies nothing", () => {
  const out = run(`sysfs = "eDP-1 connected\\nDP-2 connected\\n" monitors = { ${EDP}, ${DELL} } dofile("${blockFile}") show("load")`)
  // Only the remembered-monitor rule (position auto) and the base rules run.
  assert.ok(!/^load desc:Dell[^\n]* pos=\d+x\d+/m.test(out), out)
  assert.ok(!/^load-ws/m.test(out), out)
})

test("a connected display that is off is matched by its port", () => {
  const out = run(`sysfs = "eDP-1 connected\\nDP-2 connected\\nHDMI-A-1 connected\\n"
    monitors = { ${DELL}, ${SAMS} } dofile("${blockFile}") show("load")`)
  assert.ok(/load desc:Dell Inc. DELL U2719D TESTDELL01 scale=1.5 pos=\d+x\d+/.test(out), out)
})

test("remembered monitors that are not connected get a rule", () => {
  assert.ok(/-- Remembered displays/.test(plan.block))
  assert.ok(/hl\.monitor\(\{ output = "desc:Dell Inc\. DELL U2719D TESTDELL01", mode = "2560x1440@59\.95", position = "auto", scale = 1\.5/.test(plan.block))
})

test("an error inside the handler never escapes", () => {
  const out = run(`sysfs = "eDP-1 connected\\n" monitors = nil hl.get_monitors = function() error("boom") end
    dofile("${blockFile}") fire("monitor.added") print("survived")`)
  assert.ok(/survived/.test(out), out)
})

test("luac accepts the block", () => {
  let luac = null
  for (const bin of ["luac", "luac5.4"]) { try { execFileSync(bin, ["-v"], { stdio: "ignore" }); luac = bin; break } catch (e) {} }
  if (!luac) return
  execFileSync(luac, ["-p", blockFile])
})

test("names that could break out of a Lua string are refused", () => {
  const bad = Profiles.parseStore(JSON.stringify({ profiles: [{ id: "x\"); os.exit(", displays: ["a"], ports: { a: "DP-2" },
                                                                settings: { a: { mode: "1920x1080@60" } } }] }))
  const text = Lua.profilesLua(Profiles.luaProfiles(bad))
  assert.ok(text === null || !/\nos\.exit/.test(text))
})

fs.rmSync(dir, { recursive: true, force: true })
finish()
