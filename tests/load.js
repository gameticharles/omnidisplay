// Loads a lib/*.js QML resource in Node. The files carry `.pragma library`
// and `.import "Other.js" as Other` lines and no export block, so the shipped
// code stays exactly what QML runs: the lines are stripped here, each import
// is loaded the same way and handed in under its alias, and every top-level
// function and var comes back on one object.

const fs = require("fs")
const path = require("path")

const cache = {}

function load(file) {
  const full = path.resolve(__dirname, "..", "lib", file)
  if (cache[full]) return cache[full]
  let source = fs.readFileSync(full, "utf8")
  const imports = []
  source = source.replace(/^\.pragma library\s*$/m, "")
  source = source.replace(/^\.import "([^"]+)" as ([A-Za-z_]\w*)\s*$/gm, (_, dep, alias) => {
    imports.push({ dep, alias })
    return ""
  })
  const names = [
    ...source.matchAll(/^function ([A-Za-z_$][\w$]*)/gm),
    ...source.matchAll(/^var ([A-Za-z_$][\w$]*)/gm)
  ].map(m => m[1])
  const args = imports.map(i => i.alias)
  const values = imports.map(i => load(i.dep))
  const body = source + "\nreturn {" + names.map(n => `${n}: ${n}`).join(",") + "};"
  const api = new Function(...args, body)(...values)
  cache[full] = api
  return api
}

let failures = 0
let passes = 0
function test(name, fn) {
  try {
    fn()
    passes++
    console.log("  ok   " + name)
  } catch (error) {
    failures++
    console.log("  FAIL " + name + "\n       " + (error && error.stack ? error.stack.split("\n").slice(0, 3).join("\n       ") : error))
  }
}

function fixture(name) {
  return fs.readFileSync(path.join(__dirname, "fixtures", name), "utf8")
}

function finish() {
  console.log(`\n${passes} passed, ${failures} failed`)
  if (failures) process.exitCode = 1
}

module.exports = { load, test, fixture, finish }
