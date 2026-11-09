-- Tests for the preset block. Drift-guarded copy in grouping, culling and tagging:
-- change all three. Called from each test_assisted_<plugin>.lua as
-- require("test_preset_block")(module, check).

return function(P, check)
    -- decode -------------------------------------------------
    local d = P.preset_decode('{"version": 1, "a": "x", "b": true, "c": 2.5, "d": false, "e": -3}')
    check("preset decode string", d and d.a, "x")
    check("preset decode true", d and d.b, true)
    check("preset decode float", d and d.c, 2.5)
    check("preset decode false", d and d.d, false)
    check("preset decode negative", d and d.e, -3)
    check("preset decode version", d and d.version, 1)
    check("preset decode BOM", (P.preset_decode('\239\187\191{"a": 1}') or {}).a, 1)
    check("preset decode empty object", next(P.preset_decode(" { } \n")), nil)
    check("preset decode null drops key", (P.preset_decode('{"a": null}') or { a = 1 }).a, nil)
    check("preset decode \\u escape", (P.preset_decode('{"a": "caf\\u00e9"}') or {}).a, "café")
    check("preset decode surrogate pair", (P.preset_decode('{"a": "\\ud83d\\ude00"}') or {}).a, "\240\159\152\128")
    check("preset decode escapes", (P.preset_decode('{"a": "q\\"b\\\\s\\/\\n\\t"}') or {}).a, 'q"b\\s/\n\t')
    local function fails(name, text)
        local v, err = P.preset_decode(text)
        check("preset decode rejects " .. name, v == nil and type(err) == "string", true)
    end
    fails("trailing comma", '{"a": 1,}')
    fails("nested object", '{"a": {"b": 1}}')
    fails("array", '{"a": [1]}')
    fails("trailing junk", '{"a": 1} x')
    fails("empty text", "")
    fails("missing colon", '{"a" 1}')
    fails("unterminated string", '{"a": "x}')
    fails("bare word", '{"a": yes}')
    fails("not an object", '"a"')

    -- encode / round trip -----------------------------------
    local schema = {
        { key = "name", kind = "string", default = "" },
        { key = "on", kind = "bool", default = true },
        { key = "gap", kind = "number", default = 2 },
        { key = "mode", kind = "choice", default = "native", choices = { "native", "tags", "none" } },
    }
    local tricky = 'q"b\\s|n\né\t\1'
    local text = P.preset_encode(schema, { name = tricky, on = false, gap = 0.5, mode = "tags" })
    check("preset encode version first", text:match('^{\n  "version": 1,\n  "name"') ~= nil, true)
    check("preset encode schema order",
        text:find('"name"', 1, true) < text:find('"on"', 1, true)
        and text:find('"on"', 1, true) < text:find('"gap"', 1, true)
        and text:find('"gap"', 1, true) < text:find('"mode"', 1, true), true)
    check("preset encode ends with newline", text:sub(-2), "}\n")
    local back = P.preset_decode(text) or {}
    check("preset round trip string", back.name, tricky)
    check("preset round trip bool", back.on, false)
    check("preset round trip number", back.gap, 0.5)
    check("preset round trip choice", back.mode, "tags")
    check("preset encode whole number", P.preset_encode(schema, { name = "", on = true, gap = 5, mode = "none" })
        :find('"gap": 5,\n', 1, true) ~= nil, true)

    -- merge --------------------------------------------------
    local s, problems = P.preset_merge(schema, { gap = "2", mode = "Native groups", zzz = 1, on = false })
    check("preset merge missing key uses default", s.name, "")
    check("preset merge keeps valid value", s.on, false)
    check("preset merge string for number falls back", s.gap, 2)
    check("preset merge label for choice falls back", s.mode, "native")
    check("preset merge drops unknown key", s.zzz, nil)
    table.sort(problems)
    check("preset merge lists problems", table.concat(problems, ","), "gap,mode")
    local _, none = P.preset_merge(schema, {})
    check("preset merge missing keys are not problems", #none, 0)
    local dflt = P.preset_defaults(schema)
    check("preset defaults", dflt.mode .. tostring(dflt.on) .. dflt.gap, "nativetrue2")

    -- equal --------------------------------------------------
    local a = { name = "x", on = true, gap = 2, mode = "none" }
    local b = { name = "x", on = true, gap = 2, mode = "none", extra = 9 }
    check("preset equal same values", P.preset_equal(schema, a, b), true)
    b.on = false
    check("preset equal bool flipped", P.preset_equal(schema, a, b), false)

    -- names --------------------------------------------------
    check("preset name trimmed", P.preset_name_ok("  F1 2026 "), "F1 2026")
    check("preset name empty", select(2, P.preset_name_ok("")), "empty")
    check("preset name blank", select(2, P.preset_name_ok("   ")), "empty")
    check("preset name nil", select(2, P.preset_name_ok(nil)), "empty")
    check("preset name reserved", select(2, P.preset_name_ok("Template")), "reserved")
    check("preset name slash", select(2, P.preset_name_ok("a/b")), "bad character")
    check("preset name colon", select(2, P.preset_name_ok("a:b")), "bad character")
    check("preset name quote", select(2, P.preset_name_ok('a"b')), "bad character")

    -- order --------------------------------------------------
    check("preset order", table.concat(P.preset_order({ "b", "A", "template", "b", "TEMPLATE" }), ","), "template,A,b")
    check("preset order empty", table.concat(P.preset_order({}), ","), "template")
end
