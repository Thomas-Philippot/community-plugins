--!nonstrict
-- JSON parser and printer that keeps the document as written: object keys stay
-- in source order and numbers and strings keep their source text, so nothing
-- is reordered or rounded. noctalia.json decodes into Luau tables, which loses
-- both. Pure Luau: no noctalia API is used here.
--
-- A node is one of:
--   { kind = "object", entries = { { key = <raw key>, node = <node> }, ... } }
--   { kind = "array", items = { <node>, ... } }
--   { kind = "string" | "number" | "true" | "false" | "null", raw = <source text> }
-- `raw` of a string and `key` include their quotes.

local M = {}

local MAX_DEPTH = 512

local B_SPACE, B_TAB, B_LF, B_CR = 32, 9, 10, 13
local B_QUOTE, B_BACKSLASH = 34, 92
local B_LBRACE, B_RBRACE, B_LBRACKET, B_RBRACKET = 123, 125, 91, 93
local B_COMMA, B_COLON, B_MINUS, B_PLUS, B_DOT = 44, 58, 45, 43, 46
local B_0, B_1, B_9 = 48, 49, 57
local B_E, B_e = 69, 101

local ESCAPES = { [34] = true, [92] = true, [47] = true, [98] = true, [102] = true, [110] = true, [114] = true, [116] = true }

local function isDigit(b)
  return b ~= nil and b >= B_0 and b <= B_9
end

local function isHex(b)
  return b ~= nil and ((b >= 48 and b <= 57) or (b >= 65 and b <= 70) or (b >= 97 and b <= 102))
end

-- 1-based line and column of byte `pos`; columns count UTF-8 characters.
local function lineCol(text, pos)
  local line, lineStart = 1, 1
  local i = 1
  while true do
    local nl = string.find(text, "\n", i, true)
    if nl == nil or nl >= pos then
      break
    end
    line += 1
    lineStart = nl + 1
    i = nl + 1
  end
  local col = utf8.len(text, lineStart, math.max(lineStart, pos) - 1) or (pos - lineStart)
  return line, col + 1
end

-- How a byte reads in an error message.
local function describe(text, pos)
  if pos > #text then
    return "end of input"
  end
  local b = string.byte(text, pos)
  local ok, nextPos = pcall(utf8.offset, text, 2, pos)
  local ch = string.sub(text, pos, (ok and nextPos or pos + 1) - 1)
  if b < 32 then
    return string.format("control character U+%04X", b)
  end
  return '"' .. ch .. '"'
end

-- Parses `text`. Returns the root node, or nil and an error table
-- { kind, message, line, col, pos } (plus `commaPos` for a trailing comma).
-- `opts.step` (optional) is called every `opts.stepEvery` values, so a caller
-- running the parse in a coroutine can yield between frames.
function M.parse(text, opts)
  local pos = 1
  local len = #text
  local step = opts and opts.step
  local stepEvery = (opts and opts.stepEvery) or 2000
  local counter = 0

  -- A leading UTF-8 byte order mark is allowed and ignored.
  if string.sub(text, 1, 3) == "\239\187\191" then
    pos = 4
  end

  local function fail(kind, message, at, extra)
    local line, col = lineCol(text, at)
    local err = { kind = kind, message = message, pos = at, line = line, col = col }
    if extra then
      for k, v in pairs(extra) do
        err[k] = v
      end
    end
    error(err, 0)
  end

  local function skipWs()
    while pos <= len do
      local b = string.byte(text, pos)
      if b == B_SPACE or b == B_LF or b == B_CR or b == B_TAB then
        pos += 1
      else
        return
      end
    end
  end

  local function parseString()
    local start = pos
    pos += 1 -- opening quote
    while true do
      if pos > len then
        fail("unterminated_string", "Unterminated string", start)
      end
      local b = string.byte(text, pos)
      if b == B_QUOTE then
        pos += 1
        return string.sub(text, start, pos - 1)
      elseif b == B_BACKSLASH then
        local e = string.byte(text, pos + 1)
        if e == 117 then -- \uXXXX
          for k = 2, 5 do
            if not isHex(string.byte(text, pos + k)) then
              fail("invalid_escape", "Invalid unicode escape, expected \\u and 4 hex digits", pos)
            end
          end
          pos += 6
        elseif e ~= nil and ESCAPES[e] then
          pos += 2
        elseif e == nil then
          fail("unterminated_string", "Unterminated string", start)
        else
          fail("invalid_escape", "Invalid escape \\" .. string.char(e) .. " in string", pos)
        end
      elseif b < 32 then
        local what = b == B_LF and "line break" or string.format("control character U+%04X", b)
        fail("control_char", "Unescaped " .. what .. " in string", pos)
      else
        pos += 1
      end
    end
  end

  local function parseNumber()
    local start = pos
    if string.byte(text, pos) == B_MINUS then
      pos += 1
    end
    local b = string.byte(text, pos)
    if b == B_0 then
      pos += 1
      if isDigit(string.byte(text, pos)) then
        fail("invalid_number", "Numbers cannot have leading zeros", start)
      end
    elseif b ~= nil and b >= B_1 and b <= B_9 then
      while isDigit(string.byte(text, pos)) do
        pos += 1
      end
    else
      fail("invalid_number", "Invalid number", start)
    end
    if string.byte(text, pos) == B_DOT then
      pos += 1
      if not isDigit(string.byte(text, pos)) then
        fail("invalid_number", "Expected a digit after the decimal point", pos)
      end
      while isDigit(string.byte(text, pos)) do
        pos += 1
      end
    end
    b = string.byte(text, pos)
    if b == B_E or b == B_e then
      pos += 1
      b = string.byte(text, pos)
      if b == B_PLUS or b == B_MINUS then
        pos += 1
      end
      if not isDigit(string.byte(text, pos)) then
        fail("invalid_number", "Expected a digit in the exponent", pos)
      end
      while isDigit(string.byte(text, pos)) do
        pos += 1
      end
    end
    return string.sub(text, start, pos - 1)
  end

  local parseValue

  local function parseObject(depth)
    local open = pos
    pos += 1
    local entries = {}
    skipWs()
    if string.byte(text, pos) == B_RBRACE then
      pos += 1
      return { kind = "object", entries = entries }
    end
    while true do
      skipWs()
      local b = string.byte(text, pos)
      if b ~= B_QUOTE then
        if b == nil then
          fail("unexpected_end", "Unexpected end of input: object opened here is not closed", open)
        end
        fail("unquoted_key", "Expected a double-quoted key, found " .. describe(text, pos), pos)
      end
      local key = parseString()
      skipWs()
      if string.byte(text, pos) ~= B_COLON then
        fail("expected_colon", "Expected \":\" after key " .. key .. ", found " .. describe(text, pos), pos)
      end
      pos += 1
      local node = parseValue(depth + 1)
      entries[#entries + 1] = { key = key, node = node }
      skipWs()
      b = string.byte(text, pos)
      if b == B_COMMA then
        local commaPos = pos
        pos += 1
        skipWs()
        if string.byte(text, pos) == B_RBRACE then
          fail("trailing_comma", "Trailing comma before \"}\": remove the last \",\"", commaPos, { commaPos = commaPos })
        end
      elseif b == B_RBRACE then
        pos += 1
        return { kind = "object", entries = entries }
      elseif b == nil then
        fail("unexpected_end", "Unexpected end of input: object opened here is not closed", open)
      else
        fail("expected_comma", "Expected \",\" or \"}\" after a value, found " .. describe(text, pos), pos)
      end
    end
  end

  local function parseArray(depth)
    local open = pos
    pos += 1
    local items = {}
    skipWs()
    if string.byte(text, pos) == B_RBRACKET then
      pos += 1
      return { kind = "array", items = items }
    end
    while true do
      items[#items + 1] = parseValue(depth + 1)
      skipWs()
      local b = string.byte(text, pos)
      if b == B_COMMA then
        local commaPos = pos
        pos += 1
        skipWs()
        if string.byte(text, pos) == B_RBRACKET then
          fail("trailing_comma", "Trailing comma before \"]\": remove the last \",\"", commaPos, { commaPos = commaPos })
        end
      elseif b == B_RBRACKET then
        pos += 1
        return { kind = "array", items = items }
      elseif b == nil then
        fail("unexpected_end", "Unexpected end of input: array opened here is not closed", open)
      else
        fail("expected_comma", "Expected \",\" or \"]\" after a value, found " .. describe(text, pos), pos)
      end
    end
  end

  parseValue = function(depth)
    if depth > MAX_DEPTH then
      fail("too_deep", "Nesting is deeper than " .. MAX_DEPTH .. " levels", pos)
    end
    if step then
      counter += 1
      if counter >= stepEvery then
        counter = 0
        step()
      end
    end
    skipWs()
    local b = string.byte(text, pos)
    if b == B_LBRACE then
      return parseObject(depth)
    elseif b == B_LBRACKET then
      return parseArray(depth)
    elseif b == B_QUOTE then
      return { kind = "string", raw = parseString() }
    elseif b == B_MINUS or isDigit(b) then
      return { kind = "number", raw = parseNumber() }
    elseif string.sub(text, pos, pos + 3) == "true" then
      pos += 4
      return { kind = "true", raw = "true" }
    elseif string.sub(text, pos, pos + 4) == "false" then
      pos += 5
      return { kind = "false", raw = "false" }
    elseif string.sub(text, pos, pos + 3) == "null" then
      pos += 4
      return { kind = "null", raw = "null" }
    elseif b == nil then
      fail("unexpected_end", "Unexpected end of input, expected a value", pos)
    elseif b == 39 then -- single quote
      fail("single_quote", "Strings must use double quotes", pos)
    end
    fail("unexpected_char", "Unexpected " .. describe(text, pos) .. ", expected a value", pos)
  end

  local ok, result = pcall(function()
    skipWs()
    if pos > len then
      fail("empty", "The input is empty", pos)
    end
    local root = parseValue(1)
    skipWs()
    if pos <= len then
      fail("trailing_content", "Unexpected " .. describe(text, pos) .. " after the end of the JSON value", pos)
    end
    return root
  end)
  if ok then
    return result, nil
  end
  if type(result) == "table" and result.kind then
    return nil, result
  end
  error(result, 0) -- not a parse error: let it surface
end

-- Indent unit for a setting value: "2", "4" or "tab".
function M.indentUnit(setting)
  if setting == "tab" then
    return "\t"
  end
  return string.rep(" ", tonumber(setting) or 2)
end

-- Returns a function that calls `step` every `every` calls (or does nothing).
local function ticker(step, every)
  if step == nil then
    return function() end
  end
  local counter = 0
  every = every or 2000
  return function()
    counter += 1
    if counter >= every then
      counter = 0
      step()
    end
  end
end

-- Pretty-prints a node with `unit` per level ("  " by default). `step` is
-- called every `stepEvery` nodes, as in parse().
function M.pretty(root, unit, step, stepEvery)
  unit = unit or "  "
  local tick = ticker(step, stepEvery)
  local out = {}
  local function emit(node, depth)
    tick()
    local kind = node.kind
    if kind == "object" then
      if #node.entries == 0 then
        out[#out + 1] = "{}"
        return
      end
      local inner = string.rep(unit, depth + 1)
      out[#out + 1] = "{\n"
      for i, e in ipairs(node.entries) do
        out[#out + 1] = inner
        out[#out + 1] = e.key
        out[#out + 1] = ": "
        emit(e.node, depth + 1)
        out[#out + 1] = i < #node.entries and ",\n" or "\n"
      end
      out[#out + 1] = string.rep(unit, depth) .. "}"
    elseif kind == "array" then
      if #node.items == 0 then
        out[#out + 1] = "[]"
        return
      end
      local inner = string.rep(unit, depth + 1)
      out[#out + 1] = "[\n"
      for i, item in ipairs(node.items) do
        out[#out + 1] = inner
        emit(item, depth + 1)
        out[#out + 1] = i < #node.items and ",\n" or "\n"
      end
      out[#out + 1] = string.rep(unit, depth) .. "]"
    else
      out[#out + 1] = node.raw
    end
  end
  emit(root, 0)
  return table.concat(out)
end

-- Prints a node with no whitespace at all.
function M.minify(root, step, stepEvery)
  local tick = ticker(step, stepEvery)
  local out = {}
  local function emit(node)
    tick()
    if node.kind == "object" then
      out[#out + 1] = "{"
      for i, e in ipairs(node.entries) do
        if i > 1 then
          out[#out + 1] = ","
        end
        out[#out + 1] = e.key
        out[#out + 1] = ":"
        emit(e.node)
      end
      out[#out + 1] = "}"
    elseif node.kind == "array" then
      out[#out + 1] = "["
      for i, item in ipairs(node.items) do
        if i > 1 then
          out[#out + 1] = ","
        end
        emit(item)
      end
      out[#out + 1] = "]"
    else
      out[#out + 1] = node.raw
    end
  end
  emit(root)
  return table.concat(out)
end

-- Removes the comma a "trailing_comma" error points at. Returns nil for any
-- other error.
function M.fixTrailingComma(text, err)
  if err == nil or err.kind ~= "trailing_comma" or err.commaPos == nil then
    return nil
  end
  return string.sub(text, 1, err.commaPos - 1) .. string.sub(text, err.commaPos + 1)
end

return M
