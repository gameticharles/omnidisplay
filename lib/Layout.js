.pragma library
.import "Model.js" as Model

// Arrangement geometry on logical pixels. A layout is a list of display
// entries (Model.parseMonitors shape) that are on the desktop; every
// function returns a new list and leaves its input alone.
//
// The snapping, gap closing and reflow follow Steve Derico's
// omarchy-displays (DisplaysLogic.js, MIT); the staging move follows
// Krzysztof Golab Magalhaes' monitor-layout (MIT). See NOTICE.

// Neighbours must share at least this much edge, so the pointer always has
// room to cross.
var MIN_SHARED_EDGE = 64
var SIDES = ["right", "left", "below", "above"]

function rectOf(entry) {
  var size = Model.logicalSize(entry)
  return { x: entry.x, y: entry.y, w: size.width, h: size.height }
}

function rectsOverlap(a, b) {
  return a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h
}

function sharedLength(aStart, aLength, bStart, bLength) {
  return Math.min(aStart + aLength, bStart + bLength) - Math.max(aStart, bStart)
}

// Which side of `anchor` the rect sits flush against, or "".
function sideOfRect(rect, anchor) {
  if (sharedLength(rect.y, rect.h, anchor.y, anchor.h) > 0) {
    if (rect.x === anchor.x + anchor.w) return "right"
    if (rect.x + rect.w === anchor.x) return "left"
  }
  if (sharedLength(rect.x, rect.w, anchor.x, anchor.w) > 0) {
    if (rect.y === anchor.y + anchor.h) return "below"
    if (rect.y + rect.h === anchor.y) return "above"
  }
  return ""
}

function indexOfName(layout, name) {
  for (var i = 0; i < (layout || []).length; i++) if (layout[i].name === name) return i
  return -1
}

function sideOf(layout, name, anchorName) {
  var a = Model.entryByName(layout, name)
  var b = Model.entryByName(layout, anchorName)
  if (!a || !b || name === anchorName) return ""
  return sideOfRect(rectOf(a), rectOf(b))
}

function layoutBounds(layout) {
  if (!layout || layout.length === 0) return { x: 0, y: 0, w: 0, h: 0 }
  var minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity
  for (var i = 0; i < layout.length; i++) {
    var r = rectOf(layout[i])
    minX = Math.min(minX, r.x)
    minY = Math.min(minY, r.y)
    maxX = Math.max(maxX, r.x + r.w)
    maxY = Math.max(maxY, r.y + r.h)
  }
  return { x: minX, y: minY, w: maxX - minX, h: maxY - minY }
}

// Shift everything so the top-left corner is 0x0.
function normalizeLayout(layout) {
  var out = Model.cloneList(layout)
  var bounds = layoutBounds(out)
  for (var i = 0; i < out.length; i++) {
    out[i].x = Math.round(out[i].x - bounds.x)
    out[i].y = Math.round(out[i].y - bounds.y)
  }
  return out
}

function overlappingPairs(layout) {
  var pairs = []
  for (var i = 0; i < layout.length; i++)
    for (var j = i + 1; j < layout.length; j++)
      if (rectsOverlap(rectOf(layout[i]), rectOf(layout[j]))) pairs.push([layout[i].name, layout[j].name])
  return pairs
}

function isConnected(layout) {
  if (!layout || layout.length <= 1) return true
  var seen = { 0: true }
  var queue = [0]
  var count = 1
  while (queue.length) {
    var current = rectOf(layout[queue.shift()])
    for (var i = 0; i < layout.length; i++) {
      if (seen[i] || sideOfRect(rectOf(layout[i]), current) === "") continue
      seen[i] = true
      count++
      queue.push(i)
    }
  }
  return count === layout.length
}

// Slide along a neighbour's edge, staying within reach, and snap to its
// start, end or centre when close enough.
function alignAlong(position, length, anchorStart, anchorLength, threshold) {
  var shared = Math.min(MIN_SHARED_EDGE, length, anchorLength)
  var low = anchorStart - length + shared
  var high = anchorStart + anchorLength - shared
  var value = Math.max(low, Math.min(high, position))
  var stops = [anchorStart, anchorStart + anchorLength - length, anchorStart + (anchorLength - length) / 2]
  var best = value
  var bestDistance = Number(threshold) >= 0 ? Number(threshold) : 0
  for (var i = 0; i < stops.length; i++) {
    var distance = Math.abs(value - stops[i])
    if (distance <= bestDistance) {
      best = stops[i]
      bestDistance = distance
    }
  }
  return Math.round(best)
}

function sidePosition(size, anchor, side, along) {
  if (side === "right") return { x: anchor.x + anchor.w, y: along }
  if (side === "left") return { x: anchor.x - size.w, y: along }
  if (side === "below") return { x: along, y: anchor.y + anchor.h }
  return { x: along, y: anchor.y - size.h }
}

// Land flush against whichever free edge is closest to the drop. Never
// overlaps. null when every edge is blocked.
function nearestSlot(size, proposed, others, threshold) {
  if (!others || others.length === 0) return { x: 0, y: 0, side: "", anchor: -1 }
  var best = null
  var bestDistance = Infinity
  for (var i = 0; i < others.length; i++) {
    var anchor = others[i]
    for (var s = 0; s < SIDES.length; s++) {
      var side = SIDES[s]
      var horizontal = side === "right" || side === "left"
      var along = horizontal
        ? alignAlong(proposed.y, size.h, anchor.y, anchor.h, threshold)
        : alignAlong(proposed.x, size.w, anchor.x, anchor.w, threshold)
      var spot = sidePosition(size, anchor, side, along)
      var rect = { x: spot.x, y: spot.y, w: size.w, h: size.h }
      var blocked = false
      for (var j = 0; j < others.length; j++) {
        if (rectsOverlap(rect, others[j])) { blocked = true; break }
      }
      if (blocked) continue
      var dx = spot.x - proposed.x
      var dy = spot.y - proposed.y
      var distance = dx * dx + dy * dy
      if (distance < bestDistance) {
        bestDistance = distance
        best = { x: spot.x, y: spot.y, side: side, anchor: i }
      }
    }
  }
  return best
}

function otherRects(layout, name) {
  var out = []
  for (var i = 0; i < layout.length; i++) if (layout[i].name !== name) out.push(rectOf(layout[i]))
  return out
}

function rectDistance(a, b) {
  var dx = Math.max(0, a.x - (b.x + b.w), b.x - (a.x + a.w))
  var dy = Math.max(0, a.y - (b.y + b.h), b.y - (a.y + a.h))
  return dx * dx + dy * dy
}

// Re-seat every display that no longer touches the group, nearest first,
// starting from `anchorName`. A connected layout comes back unchanged.
function closeGaps(layout, anchorName) {
  var out = Model.cloneList(layout)
  if (out.length <= 1) return out
  var rects = []
  for (var i = 0; i < out.length; i++) rects.push(rectOf(out[i]))
  var inGroup = {}
  var groupSize = 0
  function join(index) { inGroup[index] = true; groupSize++ }
  function grow() {
    var grew = true
    while (grew) {
      grew = false
      for (var c = 0; c < out.length; c++) {
        if (inGroup[c]) continue
        var touches = false
        var clashes = false
        for (var m = 0; m < out.length; m++) {
          if (!inGroup[m]) continue
          if (rectsOverlap(rects[c], rects[m])) clashes = true
          else if (sideOfRect(rects[c], rects[m]) !== "") touches = true
        }
        if (touches && !clashes) { join(c); grew = true }
      }
    }
  }
  join(Math.max(0, indexOfName(out, anchorName)))
  grow()
  while (groupSize < out.length) {
    var group = []
    for (var g = 0; g < out.length; g++) if (inGroup[g]) group.push(rects[g])
    var nearest = -1
    var nearestDistance = Infinity
    for (var o = 0; o < out.length; o++) {
      if (inGroup[o]) continue
      for (var k = 0; k < group.length; k++) {
        var d = rectDistance(rects[o], group[k])
        if (d < nearestDistance) { nearestDistance = d; nearest = o }
      }
    }
    var slot = nearestSlot({ w: rects[nearest].w, h: rects[nearest].h },
                           { x: rects[nearest].x, y: rects[nearest].y }, group, 0)
    if (slot) {
      rects[nearest].x = slot.x
      rects[nearest].y = slot.y
      out[nearest].x = slot.x
      out[nearest].y = slot.y
    }
    join(nearest)
    grow()
  }
  return out
}

// Drop `name` at a proposed logical position. Returns a normalised layout.
function dropMonitor(layout, name, proposedX, proposedY, threshold) {
  var out = Model.cloneList(layout)
  var index = indexOfName(out, name)
  if (index < 0) return normalizeLayout(out)
  var size = Model.logicalSize(out[index])
  var slot = nearestSlot({ w: size.width, h: size.height },
                         { x: Number(proposedX) || 0, y: Number(proposedY) || 0 },
                         otherRects(out, name), threshold)
  if (slot) {
    out[index].x = slot.x
    out[index].y = slot.y
  }
  return normalizeLayout(closeGaps(out, name))
}

// Keyboard move: shift by (dx, dy) and stay flush with the neighbours.
function nudge(layout, name, dx, dy) {
  var entry = Model.entryByName(layout, name)
  if (!entry) return layout
  return dropMonitor(layout, name, entry.x + (Number(dx) || 0), entry.y + (Number(dy) || 0), 0)
}

// Put `name` on one side of `anchorName`, aligned "start", "center" or "end".
function placeOnSide(layout, name, anchorName, side, align) {
  var out = Model.cloneList(layout)
  var index = indexOfName(out, name)
  var anchorEntry = Model.entryByName(out, anchorName)
  if (index < 0 || !anchorEntry || name === anchorName || SIDES.indexOf(side) < 0) return normalizeLayout(out)
  var size = Model.logicalSize(out[index])
  var box = { w: size.width, h: size.height }
  var anchor = rectOf(anchorEntry)
  var horizontal = side === "right" || side === "left"
  var start = horizontal ? anchor.y : anchor.x
  var room = horizontal ? anchor.h - box.h : anchor.w - box.w
  var along = start
  if (align === "center") along = start + Math.round(room / 2)
  else if (align === "end") along = start + room
  var spot = sidePosition(box, anchor, side, along)
  var others = otherRects(out, name)
  var rect = { x: spot.x, y: spot.y, w: box.w, h: box.h }
  for (var i = 0; i < others.length; i++) {
    if (!rectsOverlap(rect, others[i])) continue
    var slot = nearestSlot(box, spot, others, 0)
    if (slot) spot = slot
    break
  }
  out[index].x = spot.x
  out[index].y = spot.y
  return normalizeLayout(closeGaps(out, name))
}

// Line `name` up along the edge it shares with its neighbour.
function alignWithNeighbour(layout, name, align) {
  for (var i = 0; i < layout.length; i++) {
    if (layout[i].name === name) continue
    var side = sideOf(layout, name, layout[i].name)
    if (side) return placeOnSide(layout, name, layout[i].name, side, align)
  }
  return layout
}

function relationBetween(parent, child) {
  var side = sideOfRect(child, parent)
  if (!side) return null
  var horizontal = side === "right" || side === "left"
  var offset = horizontal ? child.y - parent.y : child.x - parent.x
  var room = horizontal ? parent.h - child.h : parent.w - child.w
  var align = "offset"
  if (offset === 0) align = "start"
  else if (offset === room) align = "end"
  else if (Math.abs(offset * 2 - room) <= 1) align = "center"
  return { side: side, align: align, offset: offset }
}

function placeRelative(parent, size, relation) {
  var horizontal = relation.side === "right" || relation.side === "left"
  var start = horizontal ? parent.y : parent.x
  var parentLength = horizontal ? parent.h : parent.w
  var length = horizontal ? size.h : size.w
  var along
  if (relation.align === "start") along = start
  else if (relation.align === "end") along = start + parentLength - length
  else if (relation.align === "center") along = start + Math.round((parentLength - length) / 2)
  else along = alignAlong(start + relation.offset, length, start, parentLength, 0)
  return sidePosition(size, parent, relation.side, along)
}

// A scale, mode or rotation change resizes a display. Rebuild positions so
// every display keeps the neighbour, side and alignment it had.
// `before` and `after` hold the same displays.
function reflow(before, after) {
  var out = Model.cloneList(after)
  if (out.length === 0) return out
  if (out.length === 1) {
    out[0].x = 0
    out[0].y = 0
    return out
  }
  var oldRects = []
  for (var i = 0; i < out.length; i++) oldRects.push(rectOf(Model.entryByName(before, out[i].name) || out[i]))
  var placed = {}
  var order = []
  function sizeAt(index) {
    var size = Model.logicalSize(out[index])
    return { w: size.width, h: size.height }
  }
  function settle(index, x, y) {
    var size = sizeAt(index)
    placed[index] = { x: x, y: y, w: size.w, h: size.h }
    order.push(index)
  }
  for (var root = 0; root < out.length; root++) {
    if (placed[root]) continue
    settle(root, oldRects[root].x, oldRects[root].y)
    var queue = [root]
    while (queue.length) {
      var parent = queue.shift()
      for (var child = 0; child < out.length; child++) {
        if (placed[child]) continue
        var relation = relationBetween(oldRects[parent], oldRects[child])
        if (!relation) continue
        var spot = placeRelative(placed[parent], sizeAt(child), relation)
        settle(child, spot.x, spot.y)
        queue.push(child)
      }
    }
  }
  var settled = []
  for (var k = 0; k < order.length; k++) {
    var rect = placed[order[k]]
    var clash = false
    for (var p = 0; p < settled.length; p++) {
      if (rectsOverlap(rect, settled[p])) { clash = true; break }
    }
    if (clash) {
      var slot = nearestSlot({ w: rect.w, h: rect.h }, { x: rect.x, y: rect.y }, settled, 0)
      if (slot) { rect.x = slot.x; rect.y = slot.y }
    }
    settled.push(rect)
    out[order[k]].x = rect.x
    out[order[k]].y = rect.y
  }
  return normalizeLayout(closeGaps(out, out[order[0]].name))
}

// Places displays that just joined the desktop (turned on, or no longer
// mirroring) to the right of the arrangement, top-aligned.
function placeNewcomers(layout, names) {
  var out = Model.cloneList(layout)
  var fixed = out.filter(function(e) { return names.indexOf(e.name) < 0 })
  var right = fixed.length ? layoutBounds(fixed).x + layoutBounds(fixed).w : 0
  for (var i = 0; i < out.length; i++) {
    if (names.indexOf(out[i].name) < 0) continue
    out[i].x = right
    out[i].y = 0
    right += Model.logicalSize(out[i]).width
  }
  return normalizeLayout(out)
}

// Whether moving straight from `before` to `after` would make Hyprland see
// two displays overlapping on the way, as it applies rules one at a time.
function needsStaging(before, after) {
  for (var i = 0; i < after.length; i++) {
    var target = rectOf(after[i])
    for (var j = 0; j < before.length; j++) {
      if (before[j].name === after[i].name) continue
      if (rectsOverlap(target, rectOf(before[j]))) return true
    }
  }
  return false
}

// A parking column past the right edge of both layouts. Each display is
// parked there first, then moved to its target, so no step overlaps.
function stagingX(before, after) {
  var a = layoutBounds(before)
  var b = layoutBounds(after)
  return Math.max(a.x + a.w, b.x + b.w) + 1000
}

// ---------------------------------------------------------- canvas fitting

// Scale and offset that fit the layout's bounds into a canvas of the given
// size with padding, centred.
function fitTransform(layout, canvasWidth, canvasHeight, padding) {
  var bounds = layoutBounds(layout)
  var pad = Number(padding) || 0
  var w = Math.max(1, canvasWidth - 2 * pad)
  var h = Math.max(1, canvasHeight - 2 * pad)
  if (bounds.w <= 0 || bounds.h <= 0) return { scale: 1, offsetX: pad, offsetY: pad, bounds: bounds }
  var scale = Math.min(w / bounds.w, h / bounds.h)
  return {
    scale: scale,
    offsetX: pad + (w - bounds.w * scale) / 2 - bounds.x * scale,
    offsetY: pad + (h - bounds.h * scale) / 2 - bounds.y * scale,
    bounds: bounds
  }
}
