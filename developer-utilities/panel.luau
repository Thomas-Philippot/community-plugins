--!nonstrict
-- Developer Utilities panel: a rail of tools on the left, the active tool on
-- the right. v1 ships the JSON formatter; the other tools show a "coming
-- soon" page.
--
-- JSON input comes from the clipboard, read when the panel opens and on
-- reload. There is no editor: the shell's multiline field gets very slow with
-- a few hundred lines. Parsing, line building and copy output run as a
-- background job: a coroutine resumed for a few milliseconds per frame, so a
-- large document never trips the shell's per-callback CPU budget. The code view is
-- virtualized: only the rows around the viewport are built, with spacer boxes
-- above and below (a container keeps at most 256 children).
--
-- Nothing is written to disk and no process is started. The clipboard is read
-- on open and on reload, and written only by Copy.

local json = require("./lib/json.luau")
local view = require("./lib/view.luau")

local ROW_H = 20 -- px per code row
local WINDOW = 80 -- rows built around the viewport
local SLICE_S = 0.008 -- seconds of background work per frame
local STEP_EVERY = 200 -- nodes between two budget checks
local MAX_COLS = 80 -- wrap width of the code view, in characters
-- The parsed tree and its display lines take about 100 times the text size,
-- and the shell caps a plugin's memory: 5 MB of JSON runs out of it.
local MAX_BYTES = 1024 * 1024

local TOOLS = {
  { id = "json", glyph = "braces" },
  { id = "base64", glyph = "binary" },
  { id = "url", glyph = "link" },
  { id = "time", glyph = "clock" },
  { id = "jwt", glyph = "key" },
  { id = "uuid", glyph = "hash" },
  { id = "base", glyph = "number" },
}

local ROLE_COLOR = {
  key = "primary",
  string = "tertiary",
  number = "secondary",
  punct = "outline",
  summary = "on_surface_variant",
}

local function tr(key, args)
  return noctalia.tr("panel." .. key, args)
end

-- ── State ────────────────────────────────────────────────────

local state = {
  tool = "json",
  source = "clipboard", -- "clipboard" | "fixed" (after Remove trailing comma)
  input = "", -- the text being formatted
  mode = "pretty", -- "pretty" | "minify"
  root = nil, -- last valid document
  err = nil, -- parse error of the current input
  empty = nil, -- nil, "clipboard_empty", "not_json" or "too_large"
  lines = {},
  toggled = {},
  foldDepth = nil, -- overrides the fold_depth setting after Fold all / Unfold all
  firstRow = 1,
  scrollRev = 0, -- new scroll key: back to the top after a new document
  copied = false,
  loadedInput = nil, -- text the current view was built from
}


local render

-- ── Background jobs ──────────────────────────────────────────

local job = nil -- { co, onDone }
local sliceStart = 0

local function step()
  if os.clock() - sliceStart > SLICE_S then
    coroutine.yield()
  end
end

-- Runs `fn` in slices across frames, then calls onDone(ok, errOrNil).
-- A new job replaces the running one.
local function startJob(fn, onDone)
  job = { co = coroutine.create(fn), onDone = onDone }
  panel.setNeedsFrameTick(true)
end

function onFrameTick(_deltaMs)
  if job == nil then
    panel.setNeedsFrameTick(false)
    return
  end
  local current = job
  sliceStart = os.clock()
  local ok, err = coroutine.resume(current.co)
  if job ~= current then
    return -- replaced from inside the slice
  end
  if not ok or coroutine.status(current.co) == "dead" then
    job = nil
    panel.setNeedsFrameTick(false)
    if not ok then
      noctalia.log("developer-utilities: job failed: " .. tostring(err))
    end
    current.onDone(ok, not ok and err or nil)
  end
end

-- ── JSON tool ────────────────────────────────────────────────

local function setting(key, fallback)
  local v = noctalia.getConfig(key)
  if v == nil then
    return fallback
  end
  return v
end

local function foldDepth()
  return state.foldDepth or tonumber(setting("fold_depth", 1)) or 1
end

local function summary(kind, count)
  if kind == "object" then
    return noctalia.trp("panel.json.keys", count, { count = count })
  end
  return noctalia.trp("panel.json.items", count, { count = count })
end

local function viewOpts()
  return {
    foldDepth = foldDepth(),
    toggled = state.toggled,
    maxCols = MAX_COLS,
    summary = summary,
    step = step,
    stepEvery = STEP_EVERY,
  }
end

local function buildLines()
  if state.mode == "minify" then
    return view.minified(state.root, { maxCols = MAX_COLS })
  end
  return view.pretty(state.root, viewOpts())
end

local function formatBytes(n)
  if n < 1024 then
    return tr("size.bytes", { n = n })
  elseif n < 1024 * 1024 then
    return tr("size.kb", { n = string.format("%.1f", n / 1024) })
  end
  return tr("size.mb", { n = string.format("%.1f", n / (1024 * 1024)) })
end

-- Text that does not even start like JSON is "not JSON" rather than an error.
local function looksLikeJson(text)
  local first = string.match(text, "^%s*(.)")
  return first ~= nil and string.find('{["-0123456789tfn', first, 1, true) ~= nil
end

-- Parses `text` and rebuilds the view. Keeps the last valid document (shown
-- dimmed) while the input is invalid.
local function load(text, source)
  state.input = text
  state.loadedInput = text
  state.source = source
  state.copied = false
  state.empty = nil
  if source == "clipboard" and string.match(text, "^%s*$") then
    state.root, state.err, state.lines = nil, nil, {}
    state.empty = "clipboard_empty"
    job = nil
    render()
    return
  end
  if #text > MAX_BYTES then
    state.root, state.err, state.lines = nil, nil, {}
    state.empty = "too_large"
    job = nil
    render()
    return
  end
  local root, err
  startJob(function()
    root, err = json.parse(text, { step = step, stepEvery = STEP_EVERY })
    if root ~= nil then
      state.root = root
      state.err = nil
      state.toggled = {}
      state.foldDepth = nil
      state.firstRow = 1
      state.scrollRev += 1
      state.lines = buildLines()
    end
  end, function(ok, failure)
    if not ok then
      state.err = { message = tostring(failure), line = 0, col = 0 }
    elseif root == nil then
      state.err = err
      if source == "clipboard" and not looksLikeJson(text) then
        state.empty = "not_json"
        state.root, state.lines = nil, {}
      end
    end
    render()
  end)
  render()
end

local function reloadClipboard()
  load(noctalia.clipboardText() or "", "clipboard")
end

local function rebuild()
  if state.root == nil then
    return
  end
  startJob(function()
    state.lines = buildLines()
  end, function()
    render()
  end)
  render()
end

local function setMode(mode)
  if state.mode ~= mode then
    state.mode = mode
    state.firstRow = 1
    state.scrollRev += 1
    rebuild()
  end
end

local function foldAll(depth)
  state.foldDepth = depth
  state.toggled = {}
  rebuild()
end

local function toggleAt(index)
  local line = state.lines[index]
  if line == nil or line.fold == nil or job ~= nil then
    return
  end
  state.toggled[line.path] = line.fold == "open"
  startJob(function()
    view.toggle(state.lines, index, viewOpts())
  end, function()
    render()
  end)
end

local INDENTS = { "2", "4", "tab" } -- ui.select order; indexes are 0-based

local function indentSetting()
  local v = tostring(setting("indent", "2"))
  return table.find(INDENTS, v) and v or "2"
end

local indentOverride = nil

local function currentIndent()
  return indentOverride or indentSetting()
end

local function copyOutput()
  if state.root == nil or job ~= nil then
    return
  end
  local text
  startJob(function()
    if state.mode == "minify" then
      text = json.minify(state.root, step, STEP_EVERY)
    else
      text = json.pretty(state.root, json.indentUnit(currentIndent()), step, STEP_EVERY)
    end
  end, function(ok)
    if ok and text then
      state.copied = noctalia.copyToClipboard(text, "text/plain")
    end
    render()
  end)
end

local function fixTrailingComma()
  local fixed = json.fixTrailingComma(state.input, state.err)
  if fixed == nil then
    return
  end
  load(fixed, "fixed")
end

-- ── Building blocks ──────────────────────────────────────────

local function iconButton(key, glyph, tooltip, onClick, opts)
  opts = opts or {}
  return ui.button({
    key = key,
    glyph = glyph,
    tooltip = tooltip,
    variant = opts.variant or "ghost",
    controlSize = "sm",
    enabled = opts.enabled ~= false,
    onClick = onClick,
  })
end

local function emptyState(glyph, title, message, actions)
  local children = {
    ui.glyph({ name = glyph, size = 42, color = "on_surface_variant" }),
    ui.label({ text = title, fontSize = 16, fontWeight = "bold", color = "on_surface", textAlign = "center" }),
    ui.label({ text = message, fontSize = 13, color = "on_surface_variant", textAlign = "center", maxWidth = 420, maxLines = 3 }),
  }
  if actions then
    children[#children + 1] = ui.row({ gap = 8, justify = "center" }, actions)
  end
  return ui.column({
    key = "empty",
    flexGrow = 1,
    gap = 12,
    padding = 24,
    align = "center",
    justify = "center",
    fill = "surface_container",
    radius = 10,
  }, children)
end

local function errorBanner()
  local err = state.err
  local title = err.line > 0 and tr("json.error_at", { line = err.line, col = err.col }) or tr("json.error")
  local children = {
    ui.glyph({ name = "alert-circle", size = 16, color = "error" }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = title, fontSize = 13, fontWeight = "bold", color = "on_surface" }),
      ui.label({ text = err.message, fontSize = 11, fontFamily = "monospace", color = "on_surface_variant", maxLines = 2 }),
    }),
  }
  if err.kind == "trailing_comma" then
    children[#children + 1] = ui.button({
      key = "fix-comma",
      text = tr("json.fix_comma"),
      controlSize = "sm",
      variant = "default",
      onClick = fixTrailingComma,
    })
  end
  return ui.row({
    key = "error",
    gap = 8,
    align = "center",
    padding = 8,
    radius = 8,
    fill = "surface_container",
    border = "error/0.32",
    borderWidth = 1,
  }, children)
end

-- ── Code view ────────────────────────────────────────────────

local function codeRow(index, line)
  -- A label sizes to its text whatever its width, so the number sits in a
  -- fixed-width row: 1-digit and 3-digit numbers keep the code aligned.
  local cells = {
    ui.row({ width = 44, justify = "end", align = "center" }, {
      ui.label({
        text = line.n and tostring(line.n) or "",
        fontSize = 11,
        fontFamily = "monospace",
        color = "outline",
      }),
    }),
    ui.box({ width = 6 + line.depth * 16 }),
  }
  if line.fold then
    cells[#cells + 1] = ui.row({
      key = "fold",
      width = 18,
      height = 18,
      align = "center",
      justify = "center",
      radius = 4,
      onClick = function()
        toggleAt(index)
      end,
    }, {
      ui.glyph({
        name = line.fold == "open" and "chevron-down" or "chevron-right",
        size = 12,
        color = line.fold == "open" and "on_surface_variant" or "primary",
      }),
    })
  else
    cells[#cells + 1] = ui.box({ width = 18 })
  end
  cells[#cells + 1] = ui.box({ width = 4 })
  for _, seg in ipairs(line.segs) do
    if seg[2] == "summary" then
      cells[#cells + 1] = ui.row({ fill = "surface_container_high", radius = 4, paddingH = 5 }, {
        ui.label({ text = seg[1], fontSize = 11, color = ROLE_COLOR.summary }),
      })
    else
      cells[#cells + 1] = ui.label({ text = seg[1], fontSize = 12, fontFamily = "monospace", color = ROLE_COLOR[seg[2]] })
    end
  end
  return ui.row({ key = "r" .. index, gap = 0, height = ROW_H, align = "center" }, cells)
end

local function onScroll(offset, _maxOffset)
  local top = math.floor((tonumber(offset) or 0) / ROW_H) + 1
  local wanted = math.max(1, top - math.floor(WINDOW / 4))
  if math.abs(wanted - state.firstRow) >= math.floor(WINDOW / 4) then
    state.firstRow = wanted
    render()
  end
end

local function codeRows()
  local total = #state.lines
  local first = math.max(1, math.min(state.firstRow, total))
  local last = math.min(total, first + WINDOW - 1)
  local rows = { ui.box({ key = "top", height = math.max(0, first - 1) * ROW_H }) }
  for i = first, last do
    rows[#rows + 1] = codeRow(i, state.lines[i])
  end
  rows[#rows + 1] = ui.box({ key = "bottom", height = math.max(0, total - last) * ROW_H })
  return rows
end

-- One view tab: a clickable label with a 2 px accent bar under the active one
-- (the shell has no one-sided border).
local function viewTab(mode)
  local active = state.mode == mode
  return ui.column({
    key = "tab-" .. mode,
    gap = 0,
    align = "center",
    onClick = function()
      setMode(mode)
    end,
  }, {
    ui.row({ height = 38, paddingH = 12, align = "center" }, {
      ui.label({
        text = tr("json." .. mode),
        fontSize = 12,
        fontWeight = active and "bold" or "medium",
        color = active and "on_surface" or "on_surface_variant",
      }),
    }),
    ui.box({ height = 2, fill = active and "primary" or "outline_variant/0" }),
  })
end

-- Top of the code card: what the code area shows, and actions on that view.
local function viewBar()
  local busy = job ~= nil
  local children = {
    viewTab("pretty"),
    viewTab("minify"),
    ui.spacer({}),
  }
  if state.mode == "pretty" then
    children[#children + 1] = iconButton("fold-all", "fold-up", tr("json.fold_all"), function() foldAll(1) end, { enabled = not busy })
    children[#children + 1] = iconButton("unfold-all", "fold-down", tr("json.unfold_all"), function() foldAll(0) end, { enabled = not busy })
  end
  return ui.row({ key = "view-bar", gap = 2, align = "end", paddingH = 8, height = 40 }, children)
end

-- Bottom of the code card: document status on the left, copy on the right.
local function footer()
  local busy = job ~= nil
  local status
  if busy then
    status = ui.label({ text = tr("json.working"), fontSize = 11, color = "on_surface_variant" })
  elseif state.err then
    status = ui.row({ gap = 4, align = "center" }, {
      ui.glyph({ name = "alert-circle", size = 14, color = "error" }),
      ui.label({ text = tr("json.invalid"), fontSize = 11, fontWeight = "medium", color = "error" }),
    })
  else
    status = ui.row({ gap = 4, align = "center" }, {
      ui.glyph({ name = "check", size = 14, color = "primary" }),
      ui.label({ text = tr("json.valid"), fontSize = 11, fontWeight = "medium", color = "primary" }),
    })
  end

  local copyGroup = {}
  if state.mode == "pretty" then
    local options = {}
    for i, v in ipairs(INDENTS) do
      options[i] = tr("json.indent." .. v)
    end
    copyGroup[#copyGroup + 1] = ui.select({
      key = "indent",
      options = options,
      selectedIndex = (table.find(INDENTS, currentIndent()) or 1) - 1,
      controlSize = "sm",
      width = 116,
      height = 32, -- same height as the Copy button
      onChange = function(index)
        indentOverride = INDENTS[(tonumber(index) or 0) + 1]
        state.copied = false
        render()
      end,
    })
  end
  copyGroup[#copyGroup + 1] = ui.button({
    key = "copy",
    text = state.copied and tr("json.copied") or tr("json.copy"),
    glyph = state.copied and "check" or "copy",
    controlSize = "sm",
    variant = "primary",
    enabled = not busy and state.err == nil,
    onClick = copyOutput,
  })

  return ui.row({ key = "footer", gap = 8, align = "center", paddingH = 12, paddingV = 6 }, {
    status,
    ui.spacer({}),
    ui.row({ gap = 6, align = "center" }, copyGroup),
  })
end

local function codeCard()
  return ui.column({
    key = "code-card",
    flexGrow = 1,
    gap = 0,
    radius = 10,
    fill = "surface",
    border = "outline_variant",
    borderWidth = 1,
  }, {
    viewBar(),
    ui.separator({}),
    ui.scroll({
      key = "code-" .. state.scrollRev,
      flexGrow = 1,
      paddingV = 6,
      opacity = state.err and 0.55 or 1, -- last valid document, kept while the input is invalid
      onScroll = onScroll,
    }, codeRows()),
    ui.separator({}),
    footer(),
  })
end

local function jsonBody()
  if state.empty then
    local tooLarge = state.empty == "too_large"
    return emptyState(tooLarge and "alert-circle" or "braces", tr(tooLarge and "json.too_large_title" or "json.empty_title"), tr("json.empty_" .. state.empty, {
      size = formatBytes(#state.input),
      limit = formatBytes(MAX_BYTES),
    }), {
      ui.button({ key = "reload", text = tr("reload"), glyph = "refresh", variant = "primary", onClick = reloadClipboard }),
    })
  end
  if state.root == nil then
    if state.err then
      return ui.column({ key = "error-only", flexGrow = 1, gap = 10 }, { errorBanner() })
    end
    return emptyState("braces", tr("json.working"), "", nil)
  end
  local children = {}
  if state.err then
    children[#children + 1] = errorBanner()
  end
  children[#children + 1] = codeCard()
  return ui.column({ key = "json-body", flexGrow = 1, gap = 10 }, children)
end

local function sourceChip()
  local fromClipboard = state.source == "clipboard"
  local children = {
    ui.glyph({ name = fromClipboard and "clipboard" or "wand", size = 14, color = fromClipboard and "primary" or "on_surface_variant" }),
    ui.label({ text = fromClipboard and tr("source.clipboard") or tr("source.fixed"), fontSize = 12, fontWeight = "medium", color = "on_surface" }),
  }
  if state.input ~= "" then
    children[#children + 1] = ui.label({ text = formatBytes(#state.input), fontSize = 11, color = "on_surface_variant" })
  end
  children[#children + 1] = iconButton("reload-chip", "refresh", tr("reload_tooltip"), reloadClipboard)
  return ui.row({
    key = "source",
    gap = 6,
    align = "center",
    paddingH = 8,
    height = 32,
    radius = 8,
    fill = "surface_container",
    border = "outline_variant",
    borderWidth = 1,
  }, children)
end

-- ── Layout ───────────────────────────────────────────────────

local function rail()
  local children = {
    ui.row({ height = 40, justify = "center", align = "center" }, {
      ui.glyph({ name = "code", size = 24, color = "primary" }),
    }),
  }
  for _, tool in ipairs(TOOLS) do
    local selected = tool.id == state.tool
    children[#children + 1] = ui.column({
      key = "tool-" .. tool.id,
      width = 44,
      height = 44,
      gap = 1,
      align = "center",
      justify = "center",
      radius = 10,
      fill = selected and "primary/0.18" or nil,
      onClick = function()
        state.tool = tool.id
        render()
      end,
    }, {
      ui.glyph({ name = tool.glyph, size = 18, color = selected and "primary" or "on_surface_variant" }),
      ui.label({
        text = tr("tools." .. tool.id .. ".short"),
        fontSize = 9,
        fontWeight = selected and "bold" or "normal",
        color = selected and "primary" or "on_surface_variant",
      }),
    })
  end
  return ui.column({
    key = "rail",
    width = 60,
    gap = 4,
    align = "center",
    paddingV = 10,
  }, children)
end

local function header()
  local children = {
    ui.label({ text = tr("title"), fontSize = 18, fontWeight = "bold", color = "on_surface" }),
    ui.glyph({ name = "chevron-right", size = 14, color = "outline" }),
    ui.label({ text = tr("tools." .. state.tool .. ".name"), fontSize = 13, fontWeight = "medium", color = "on_surface_variant" }),
    ui.spacer({}),
  }
  if state.tool == "json" then
    children[#children + 1] = sourceChip()
  end
  children[#children + 1] = iconButton("close", "x", tr("close"), function()
    panel.close()
  end)
  return ui.row({ key = "header", gap = 8, align = "center", height = 32 }, children)
end

local function comingSoon()
  local glyph = "tools"
  for _, tool in ipairs(TOOLS) do
    if tool.id == state.tool then
      glyph = tool.glyph
    end
  end
  return emptyState(glyph, tr("tools." .. state.tool .. ".name"), tr("coming_soon", { tool = tr("tools." .. state.tool .. ".name") }), nil)
end

render = function()
  local body = state.tool == "json" and jsonBody() or comingSoon()
  panel.render(ui.row({ key = "root", flexGrow = 1, gap = 0 }, {
    rail(),
    ui.column({ key = "main", flexGrow = 1, gap = 10, padding = 14 }, {
      header(),
      body,
    }),
  }))
end

-- ── Lifecycle ────────────────────────────────────────────────

function onOpen(_context)
  if job ~= nil then
    panel.setNeedsFrameTick(true) -- frame ticks stop while the panel is closed
  end
  if state.tool == "json" and setting("read_clipboard_on_open", true) ~= false then
    local text = noctalia.clipboardText() or ""
    if text ~= state.input or state.source ~= "clipboard" then
      reloadClipboard()
      return
    end
  end
  render()
end

function onClose()
  state.copied = false
end
