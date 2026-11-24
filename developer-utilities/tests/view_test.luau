--!nonstrict
-- Tests for lib/view.luau. Run from the plugin directory: `luau tests/view_test.luau`.

local json = require("../lib/json")
local view = require("../lib/view")

local passed, failed = 0, 0

local function check(name, cond, detail)
  if cond then
    passed += 1
  else
    failed += 1
    print("FAIL " .. name .. (detail and (": " .. detail) or ""))
  end
end

-- Renders lines as plain text: "<n>|<indent><text>", "~" for continuations,
-- "+"/"-" before a closed/open foldable line.
local function dump(lines)
  local out = {}
  for _, line in ipairs(lines) do
    local text = {}
    for _, seg in ipairs(line.segs) do
      text[#text + 1] = seg[2] == "summary" and ("<" .. seg[1] .. ">") or seg[1]
    end
    local mark = line.fold == "closed" and "+" or line.fold == "open" and "-" or " "
    out[#out + 1] = (line.n and tostring(line.n) or "~") .. mark .. string.rep("  ", line.depth) .. table.concat(text)
  end
  return table.concat(out, "\n")
end

local function expect(name, got, want)
  check(name, got == want, "\n--- got ---\n" .. got .. "\n--- want ---\n" .. want)
end

local doc = json.parse('{"id":1,"owner":{"login":"x","tags":["a","b"]},"empty":{},"list":[]}')

expect("all open", dump(view.pretty(doc)), table.concat({
  '1-{',
  '2   "id": 1,',
  '3-  "owner": {',
  '4     "login": "x",',
  '5-    "tags": [',
  '6       "a",',
  '7       "b"',
  '8     ]',
  '9   },',
  '10   "empty": {},',
  '11   "list": []',
  '12 }',
}, "\n"))

expect("fold depth 2", dump(view.pretty(doc, { foldDepth = 2 })), table.concat({
  '1-{',
  '2   "id": 1,',
  '3-  "owner": {',
  '4     "login": "x",',
  '5+    "tags": [<2 items>]',
  '9   },',
  '10   "empty": {},',
  '11   "list": []',
  '12 }',
}, "\n"))

expect("toggle overrides depth", dump(view.pretty(doc, { foldDepth = 2, toggled = { ["$.owner"] = true } })), table.concat({
  '1-{',
  '2   "id": 1,',
  '3+  "owner": {<2 keys>},',
  '10   "empty": {},',
  '11   "list": []',
  '12 }',
}, "\n"))

expect("toggle reopens", dump(view.pretty(doc, { foldDepth = 1, toggled = { ["$.owner"] = false } })), table.concat({
  '1-{',
  '2   "id": 1,',
  '3-  "owner": {',
  '4     "login": "x",',
  '5+    "tags": [<2 items>]',
  '9   },',
  '10   "empty": {},',
  '11   "list": []',
  '12 }',
}, "\n"))

do
  local lines = view.pretty(doc)
  check("paths", lines[3].path == "$.owner" and lines[5].path == "$.owner.tags", tostring(lines[5].path))
  check("find", view.find(lines, "$.owner.tags") == 5)
  check("slice", #view.slice(lines, 11, 10) == 2 and view.slice(lines, 11, 10)[1].n == 11)
  check("roles", lines[2].segs[1][2] == "key" and lines[2].segs[3][2] == "number" and lines[4].segs[3][2] == "string")
end

do
  local odd = json.parse('{"a b":{"x":1},"_ok":[[1]]}')
  local lines = view.pretty(odd)
  check("quoted key path", lines[2].path == '$["a b"]', tostring(lines[2].path))
  check("nested array path", lines[6].path == "$._ok[0]", tostring(lines[6].path))
end

do
  local long = json.parse('{"k":"' .. string.rep("x", 30) .. '"}')
  expect("wrap long value", dump(view.pretty(long, { maxCols = 20 })), table.concat({
    '1-{',
    '2   "k": "xxxxxxxxxxxx',
    '~     xxxxxxxxxxxxxxxx',
    '~     xx"',
    '3 }',
  }, "\n"))
  local utf = json.parse('"' .. string.rep("é", 30) .. '"')
  local lines = view.pretty(utf, { maxCols = 12 })
  local ok = true
  for _, line in ipairs(lines) do
    for _, seg in ipairs(line.segs) do
      ok = ok and utf8.len(seg[1]) ~= nil
    end
  end
  check("wrap keeps utf8 whole", ok and #lines == 3, tostring(#lines))
end

expect("minified wraps flat", dump(view.minified(doc, { maxCols = 24 })), table.concat({
  '1 {"id":1,"owner":{"login"',
  '~ :"x","tags":["a","b"]},"',
  '~ empty":{},"list":[]}',
}, "\n"))

do
  local lines = view.pretty(doc, { foldDepth = 1, summary = function(kind, count) return kind .. "=" .. count end })
  check("custom summary", lines[3].segs[4][1] == "object=2", lines[3].segs[4][1])
end

-- In-place toggle gives the same rows as a full rebuild.
do
  local toggled = {}
  local opts = { foldDepth = 0, toggled = toggled, maxCols = 20 }
  local big = json.parse('{"a":{"b":[1,2,{"c":"' .. string.rep("y", 40) .. '"}],"d":true},"e":[3]}')
  local lines = view.pretty(big, opts)
  local function same(name)
    expect(name, dump(lines), dump(view.pretty(big, opts)))
  end
  toggled["$.a.b"] = true
  local delta = view.toggle(lines, view.find(lines, "$.a.b"), opts)
  same("fold inner")
  check("fold delta", delta < 0, tostring(delta))
  toggled["$.a"] = true
  view.toggle(lines, view.find(lines, "$.a"), opts)
  same("fold outer")
  toggled["$.a"] = false
  view.toggle(lines, view.find(lines, "$.a"), opts)
  same("unfold outer keeps inner folded")
  toggled["$.a.b"] = false
  check("unfold delta", view.toggle(lines, view.find(lines, "$.a.b"), opts) > 0)
  same("unfold inner")
  check("toggle on leaf is a no-op", view.toggle(lines, 2, opts) == 0)
end

do
  local steps = 0
  local root = json.parse("[" .. string.rep("1,", 4999) .. "1]")
  view.pretty(root, { step = function() steps += 1 end, stepEvery = 1000 })
  check("step hook", steps == 5, tostring(steps))
end

-- Rough timings, to compare with the shell's per-callback CPU budget.
do
  local items = {}
  for i = 1, 20000 do
    items[i] = string.format('{"id":%d,"name":"item %d","tags":["a","b"],"ok":true}', i, i)
  end
  local text = "[" .. table.concat(items, ",") .. "]"
  local t0 = os.clock()
  local root = json.parse(text)
  local t1 = os.clock()
  local lines = view.pretty(root, { maxCols = 90 })
  local t2 = os.clock()
  local folded = view.pretty(root, { foldDepth = 2, maxCols = 90 })
  local t3 = os.clock()
  print(string.format("bench: %.1f KB, parse %.0f ms, %d lines in %.0f ms, folded %d lines in %.0f ms",
    #text / 1024, (t1 - t0) * 1000, #lines, (t2 - t1) * 1000, #folded, (t3 - t2) * 1000))
end

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then
  error("view tests failed", 0)
end
