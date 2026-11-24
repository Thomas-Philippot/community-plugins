--!nonstrict
-- Turns a lib/json.luau tree into display lines for the virtualized code view.
-- Pure Luau: the panel maps roles to palette colors and only builds the rows
-- of the lines in the viewport.
--
-- A line is { n, depth, segs, path?, fold?, closes? }:
--   n       line number in the fully unfolded document, so folding never
--           renumbers anything; nil on a wrapped continuation row
--   depth   indent level (a continuation row is one level deeper)
--   segs    { { text, role }, ... }; role is "key", "string", "number",
--           "punct" or "summary" (the "3 keys" pill of a folded node)
--   path    "$.a[0]" style path of the container a foldable line opens
--   fold    "open" or "closed" on the first row of a non-empty container
--   closes  path of the container whose closing bracket ends this row
-- A foldable row also keeps what toggle() needs to rebuild that node alone.

local M = {}

local INDENT_COLS = 2 -- columns one indent level takes in the wrap budget

local function defaultSummary(kind, count)
  if kind == "object" then
    return count == 1 and "1 key" or (count .. " keys")
  end
  return count == 1 and "1 item" or (count .. " items")
end

-- Path step for an object key: `.name` for identifier-like keys, else `["raw"]`.
local function keyStep(rawKey)
  local name = string.sub(rawKey, 2, -2)
  if string.match(name, "^[%a_][%w_]*$") then
    return "." .. name
  end
  return "[" .. rawKey .. "]"
end

local function roleOf(node)
  if node.kind == "string" then
    return "string"
  end
  return "number" -- numbers, true, false, null
end

local function children(node)
  if node.kind == "object" then
    return node.entries
  elseif node.kind == "array" then
    return node.items
  end
  return nil
end

-- Lines the node takes fully unfolded, cached on the node as `size`.
local function size(node)
  if node.size then
    return node.size
  end
  local list = children(node)
  local s = 1
  if list and #list > 0 then
    s = 2
    if node.kind == "object" then
      for _, e in ipairs(list) do
        s += size(e.node)
      end
    else
      for _, item in ipairs(list) do
        s += size(item)
      end
    end
  end
  node.size = s
  return s
end

local function charLen(text)
  return utf8.len(text) or #text
end

-- Splits `text` into pieces of at most `n` characters (UTF-8 aware).
local function splitChars(text, n)
  local len = utf8.len(text)
  if len == nil or len <= n then
    return { text }
  end
  local out, pos = {}, 1
  while pos <= #text do
    local nextPos = utf8.offset(text, n + 1, pos) or (#text + 1)
    out[#out + 1] = string.sub(text, pos, nextPos - 1)
    pos = nextPos
  end
  return out
end

-- Appends `line` to `out`, wrapped so no row exceeds `maxCols` columns
-- (indent included). Continuation rows carry no number and one more indent,
-- or the same indent when `flat`. Fold data stays on the first row, `closes`
-- moves to the last.
local function pushWrapped(out, line, maxCols, flat)
  if maxCols == nil or maxCols <= 0 then
    out[#out + 1] = line
    return
  end
  local total = line.depth * INDENT_COLS
  for _, seg in ipairs(line.segs) do
    total += charLen(seg[1])
  end
  if total <= maxCols then
    out[#out + 1] = line
    return
  end

  local closes = line.closes
  line.closes = nil
  local segs = line.segs
  line.segs = {}
  local row = line
  local room = math.max(8, maxCols - line.depth * INDENT_COLS)
  local contDepth = flat and line.depth or line.depth + 1
  local contRoom = math.max(8, maxCols - contDepth * INDENT_COLS)
  for _, seg in ipairs(segs) do
    local text, role = seg[1], seg[2]
    while text ~= "" do
      local len = charLen(text)
      if len <= room then
        row.segs[#row.segs + 1] = { text, role }
        room -= len
        text = ""
      else
        if room > 0 then
          local pieces = splitChars(text, room)
          row.segs[#row.segs + 1] = { pieces[1], role }
          text = string.sub(text, #pieces[1] + 1)
        end
        out[#out + 1] = row
        row = { depth = contDepth, segs = {} }
        room = contRoom
      end
    end
  end
  if #row.segs > 0 or row == line then
    out[#out + 1] = row
  end
  out[#out].closes = closes
end

-- Writes the lines of `node` into `out`. ctx: { isFolded, maxCols, summary, step, stepEvery }.
local tick

local function walk(ctx, out, node, depth, head, path, comma, n)
  tick(ctx)
  local list = children(node)
  local segs = table.clone(head)
  if list == nil then
    segs[#segs + 1] = { node.raw, roleOf(node) }
    if comma then
      segs[#segs + 1] = { ",", "punct" }
    end
    pushWrapped(out, { n = n, depth = depth, segs = segs }, ctx.maxCols)
    return
  end

  local isObject = node.kind == "object"
  local open, close = isObject and "{" or "[", isObject and "}" or "]"
  if #list == 0 then
    segs[#segs + 1] = { open .. close, "punct" }
    if comma then
      segs[#segs + 1] = { ",", "punct" }
    end
    pushWrapped(out, { n = n, depth = depth, segs = segs }, ctx.maxCols)
    return
  end

  local line = { n = n, depth = depth, path = path, node = node, head = head, comma = comma }
  if ctx.isFolded(path, depth) then
    segs[#segs + 1] = { open, "punct" }
    segs[#segs + 1] = { ctx.summary(node.kind, #list), "summary" }
    segs[#segs + 1] = { close, "punct" }
    if comma then
      segs[#segs + 1] = { ",", "punct" }
    end
    line.segs, line.fold, line.closes = segs, "closed", path
    pushWrapped(out, line, ctx.maxCols)
    return
  end

  segs[#segs + 1] = { open, "punct" }
  line.segs, line.fold = segs, "open"
  pushWrapped(out, line, ctx.maxCols)
  local next = n + 1
  local last = #list
  if isObject then
    for i, e in ipairs(list) do
      walk(ctx, out, e.node, depth + 1, { { e.key, "key" }, { ": ", "punct" } }, path .. keyStep(e.key), i < last, next)
      next += size(e.node)
    end
  else
    for i, item in ipairs(list) do
      walk(ctx, out, item, depth + 1, {}, path .. "[" .. (i - 1) .. "]", i < last, next)
      next += size(item)
    end
  end
  local closing = { { close, "punct" } }
  if comma then
    closing[2] = { ",", "punct" }
  end
  pushWrapped(out, { n = next, depth = depth, segs = closing, closes = path }, ctx.maxCols)
end

local function context(opts)
  opts = opts or {}
  local foldDepth = opts.foldDepth or 0
  local toggled = opts.toggled or {}
  return {
    isFolded = function(path, depth)
      local t = toggled[path]
      if t ~= nil then
        return t
      end
      return foldDepth > 0 and depth >= foldDepth
    end,
    maxCols = opts.maxCols,
    summary = opts.summary or defaultSummary,
    step = opts.step,
    stepEvery = opts.stepEvery or 2000,
    counter = 0,
  }
end

-- Pretty lines of the whole document. `opts`:
--   foldDepth  containers this deep or deeper start folded (0: never); root is depth 0
--   toggled    { [path] = true (folded) | false (open) }, overrides foldDepth
--   maxCols    wrap width in columns (nil: no wrap)
--   summary    function(kind, count) -> text of a folded node's pill
--   step       called every `stepEvery` nodes, so the caller can yield
function M.pretty(root, opts)
  local out = {}
  walk(context(opts), out, root, 0, {}, "$", false, 1)
  return out
end

-- Calls ctx.step every ctx.stepEvery loop turns (for the long loops below).
tick = function(ctx)
  if ctx.step then
    ctx.counter += 1
    if ctx.counter >= ctx.stepEvery then
      ctx.counter = 0
      ctx.step()
    end
  end
end

-- Index of the last row of the node opened at `index`.
local function nodeEnd(ctx, lines, index)
  local path = lines[index].path
  for i = index, #lines do
    if lines[i].closes == path then
      return i
    end
    tick(ctx)
  end
  return index
end

-- Folds or unfolds the node opened at `index`, in place, rebuilding only that
-- node with `opts` (whose `toggled` the caller has already updated). The tail
-- of the list is shifted by hand rather than with table.move, so a `step`
-- hook can yield in the middle of a large shift.
-- Returns the number of rows the list grew by (negative when it shrank).
function M.toggle(lines, index, opts)
  local line = lines[index]
  if line == nil or line.fold == nil then
    return 0
  end
  local ctx = context(opts)
  local last = nodeEnd(ctx, lines, index)
  local fresh = {}
  walk(ctx, fresh, line.node, line.depth, line.head, line.path, line.comma, line.n)
  local removed = last - index + 1
  local delta = #fresh - removed
  local total = #lines
  if delta > 0 then
    for i = total, last + 1, -1 do
      lines[i + delta] = lines[i]
      tick(ctx)
    end
  elseif delta < 0 then
    for i = last + 1, total do
      lines[i + delta] = lines[i]
      tick(ctx)
    end
    for i = total + delta + 1, total do
      lines[i] = nil
      tick(ctx)
    end
  end
  for i, row in ipairs(fresh) do
    lines[index + i - 1] = row
  end
  return delta
end

-- The minified document as one logical line, colored and wrapped.
function M.minified(root, opts)
  opts = opts or {}
  local segs = {}
  local function emit(node)
    if node.kind == "object" then
      segs[#segs + 1] = { "{", "punct" }
      for i, e in ipairs(node.entries) do
        if i > 1 then
          segs[#segs + 1] = { ",", "punct" }
        end
        segs[#segs + 1] = { e.key, "key" }
        segs[#segs + 1] = { ":", "punct" }
        emit(e.node)
      end
      segs[#segs + 1] = { "}", "punct" }
    elseif node.kind == "array" then
      segs[#segs + 1] = { "[", "punct" }
      for i, item in ipairs(node.items) do
        if i > 1 then
          segs[#segs + 1] = { ",", "punct" }
        end
        emit(item)
      end
      segs[#segs + 1] = { "]", "punct" }
    else
      segs[#segs + 1] = { node.raw, roleOf(node) }
    end
  end
  emit(root)
  local out = {}
  pushWrapped(out, { n = 1, depth = 0, segs = segs }, opts.maxCols, true)
  return out
end

-- Index of the row that opens `path`, or nil when it is not visible.
function M.find(lines, path)
  for i, line in ipairs(lines) do
    if line.path == path then
      return i
    end
  end
  return nil
end

-- The rows first..first+count-1, clamped to the list.
function M.slice(lines, first, count)
  local out = {}
  local last = math.min(#lines, first + count - 1)
  for i = math.max(1, first), last do
    out[#out + 1] = lines[i]
  end
  return out
end

return M
