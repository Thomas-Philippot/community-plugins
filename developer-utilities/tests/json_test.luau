--!nonstrict
-- Tests for lib/json.luau. Run from the plugin directory: `make test`.

local json = require("../lib/json")

local passed, failed = 0, 0

local function check(name, cond, detail)
  if cond then
    passed += 1
  else
    failed += 1
    print("FAIL " .. name .. (detail and (": " .. detail) or ""))
  end
end

local function roundTrip(name, input, pretty, minified)
  local root, err = json.parse(input)
  if root == nil then
    check(name, false, "parse error: " .. err.message)
    return
  end
  if pretty ~= nil then
    local got = json.pretty(root, "  ")
    check(name .. " (pretty)", got == pretty, "got:\n" .. got)
  end
  if minified ~= nil then
    local got = json.minify(root)
    check(name .. " (minify)", got == minified, "got: " .. got)
  end
end

local function rejects(name, input, kind, line, col)
  local root, err = json.parse(input)
  if root ~= nil then
    check(name, false, "parsed but should not")
    return
  end
  check(name .. " (kind)", err.kind == kind, "kind " .. tostring(err.kind) .. ", message " .. err.message)
  if line then
    check(name .. " (position)", err.line == line and err.col == col, string.format("got %d:%d, want %d:%d", err.line, err.col, line, col))
  end
end

-- Valid documents keep key order and source text.
roundTrip("key order", '{"z":1,"a":2,"m":3}', '{\n  "z": 1,\n  "a": 2,\n  "m": 3\n}', '{"z":1,"a":2,"m":3}')
roundTrip("big integer kept", '{"id": 12345678901234567890}', nil, '{"id":12345678901234567890}')
roundTrip("float kept", "[1.50, -0.0, 2e10, 3E-2]", nil, "[1.50,-0.0,2e10,3E-2]")
roundTrip("escapes kept", '["a\\"b", "\\u00e9", "\\n\\t\\/"]', nil, '["a\\"b","\\u00e9","\\n\\t\\/"]')
roundTrip("utf8 kept", '{"é": "日本"}', '{\n  "é": "日本"\n}', nil)
roundTrip("empty containers", '{"a": {}, "b": [], "c": [{}]}', '{\n  "a": {},\n  "b": [],\n  "c": [\n    {}\n  ]\n}', '{"a":{},"b":[],"c":[{}]}')
roundTrip("scalar root", "  42  ", "42", "42")
roundTrip("literals", "[true,false,null]", "[\n  true,\n  false,\n  null\n]", "[true,false,null]")
roundTrip("bom ignored", "\239\187\191{}", "{}", "{}")
roundTrip("duplicate keys kept", '{"a":1,"a":2}', nil, '{"a":1,"a":2}')

do
  check("tab indent", json.pretty(json.parse("[1]"), json.indentUnit("tab")) == "[\n\t1\n]")
  check("4 spaces indent", json.indentUnit("4") == "    ")
end

-- Invalid documents report what and where.
rejects("trailing comma object", '{\n  "a": 1,\n}', "trailing_comma", 2, 9)
rejects("trailing comma array", "[1, 2, ]", "trailing_comma", 1, 6)
rejects("unquoted key", "{a: 1}", "unquoted_key", 1, 2)
rejects("single quotes", "['a']", "single_quote", 1, 2)
rejects("missing colon", '{"a" 1}', "expected_colon", 1, 6)
rejects("missing comma", '{"a": 1 "b": 2}', "expected_comma", 1, 9)
rejects("unterminated string", '{"a": "b', "unterminated_string", 1, 7)
rejects("raw newline in string", '"a\nb"', "control_char", 1, 3)
rejects("bad escape", '"\\x"', "invalid_escape", 1, 2)
rejects("bad unicode escape", '"\\u12G4"', "invalid_escape", 1, 2)
rejects("leading zero", "[01]", "invalid_number", 1, 2)
rejects("bare dot", "[1.]", "invalid_number", 1, 4)
rejects("unclosed object", '{"a": 1', "unexpected_end", 1, 1)
rejects("unclosed array", "[1, 2", "unexpected_end", 1, 1)
rejects("empty input", "   ", "empty")
rejects("trailing content", "{} {}", "trailing_content", 1, 4)
rejects("plain text", "hello", "unexpected_char", 1, 1)
rejects("column counts characters", '{"é": x}', "unexpected_char", 1, 7)
rejects("too deep", string.rep("[", 600) .. string.rep("]", 600), "too_deep")

do
  local text = '{"a": [1, 2,],}'
  local _, err = json.parse(text)
  local fixed = json.fixTrailingComma(text, err)
  check("fix trailing comma", fixed == '{"a": [1, 2],}', tostring(fixed))
  check("fix only trailing comma", json.fixTrailingComma("x", { kind = "unquoted_key" }) == nil)
end

do
  local steps = 0
  json.parse("[" .. string.rep("1,", 4999) .. "1]", { step = function() steps += 1 end, stepEvery = 1000 })
  check("step hook", steps == 5, tostring(steps))
end

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then
  error("json tests failed", 0)
end
