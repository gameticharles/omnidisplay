.pragma library

// The opt-in "Setup › Displays" row in Omarchy's menu, in
// ~/.config/omarchy/extensions/omarchy-menu.jsonc. The menu reads that file
// all or nothing (one bad edit empties every custom row), so the row is
// written only when the file, comments and all, still parses afterwards and
// reads exactly as before plus this one key. Anything else is refused.

var KEY = "setup.omnidisplay"
var ROW = {
  icon: "󰍺",
  label: "Displays",
  aliases: ["displays", "monitors", "screens", "omnidisplay"],
  description: "Arrange displays, modes, colour, profiles and casting",
  action: "omarchy-shell shell toggle omnidisplay"
}

// JSONC to JSON: comments and trailing commas out, strings left alone.
function stripJsonc(text) {
  var s = String(text || "")
  var out = ""
  var i = 0
  while (i < s.length) {
    var c = s.charAt(i)
    if (c === "\"") {
      var j = i + 1
      while (j < s.length && s.charAt(j) !== "\"") j += s.charAt(j) === "\\" ? 2 : 1
      out += s.substring(i, j + 1)
      i = j + 1
    } else if (c === "/" && s.charAt(i + 1) === "/") {
      while (i < s.length && s.charAt(i) !== "\n") i++
    } else if (c === "/" && s.charAt(i + 1) === "*") {
      var end = s.indexOf("*/", i + 2)
      i = end < 0 ? s.length : end + 2
    } else {
      out += c
      i++
    }
  }
  return out.replace(/,(\s*[}\]])/g, "$1")
}

function parse(text) {
  if (String(text || "").trim() === "") return {}
  try {
    var v = JSON.parse(stripJsonc(text))
    return v && typeof v === "object" && !Array.isArray(v) ? v : null
  } catch (e) {
    return null
  }
}

function hasRow(text) {
  var v = parse(text)
  return !!v && v[KEY] !== undefined
}

function sameExcept(a, b, key) {
  var ka = Object.keys(a).filter(function(k) { return k !== key }).sort()
  var kb = Object.keys(b).filter(function(k) { return k !== key }).sort()
  return JSON.stringify(ka) === JSON.stringify(kb)
      && ka.every(function(k) { return JSON.stringify(a[k]) === JSON.stringify(b[k]) })
}

// { ok, text, error }. Adds the row after the opening brace.
function addRow(text) {
  var before = parse(text)
  if (before === null) return { ok: false, error: "The menu file does not read as JSONC as it stands; it is left alone" }
  if (before[KEY] !== undefined) return { ok: true, text: String(text), unchanged: true }
  var src = String(text || "")
  var row = "  " + JSON.stringify(KEY) + ": " + JSON.stringify(ROW)
  var next
  if (src.trim() === "") next = "{\n" + row + "\n}\n"
  else {
    var at = src.indexOf("{")
    if (at < 0) return { ok: false, error: "The menu file has no object to add to" }
    var empty = Object.keys(before).length === 0
    next = src.substring(0, at + 1) + "\n" + row + (empty ? "\n" : ",") + src.substring(at + 1)
  }
  var after = parse(next)
  if (!after || JSON.stringify(after[KEY]) !== JSON.stringify(ROW) || !sameExcept(before, after, KEY))
    return { ok: false, error: "Adding the row would change more than the row; the file is left alone" }
  return { ok: true, text: next }
}

// Removes the line addRow wrote (it is always a single line).
function removeRow(text) {
  var before = parse(text)
  if (before === null) return { ok: false, error: "The menu file does not read as JSONC as it stands; it is left alone" }
  if (before[KEY] === undefined) return { ok: true, text: String(text), unchanged: true }
  var lines = String(text).split("\n")
  var out = lines.filter(function(l) { return l.indexOf(JSON.stringify(KEY) + ":") < 0 })
  var next = out.join("\n").replace(/\{\s*\n(\s*\})/, "{\n$1")
  var after = parse(next)
  if (!after || after[KEY] !== undefined || !sameExcept(before, after, KEY)) {
    // The last entry before a closing brace keeps a dangling comma: try without it.
    next = next.replace(/,(\s*\n\s*\})/, "$1")
    after = parse(next)
    if (!after || after[KEY] !== undefined || !sameExcept(before, after, KEY))
      return { ok: false, error: "The row is not where OmniDisplay put it; remove it by hand" }
  }
  return { ok: true, text: next }
}
