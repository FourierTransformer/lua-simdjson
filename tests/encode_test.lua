local simdjson = require("simdjson")

local tested = require("tested")
t = tested.new()

print("Getting _VERSION")
local major, minor = _VERSION:match('([%d]+)%.(%d+)')

local original_max_depth
local original_buffer_size

print("setting up before/after each methods")
t:before_each(function()
    print("inside before_each")
    original_max_depth = simdjson.getMaxEncodeDepth()
    original_buffer_size = simdjson.getEncodeBufferSize()
end)

t:after_each(function()
    simdjson.setMaxEncodeDepth(original_max_depth)
    simdjson.setEncodeBufferSize(original_buffer_size)
end)

t:test("encodes scalar values", function()
    print("Should be inside first test")
    tested.assert{expected = '"value"', actual = simdjson.encode("value")}
    tested.assert{expected = 42, actual = simdjson.parse(simdjson.encode(42))}
    tested.assert{expected = "1.5", actual = simdjson.encode(1.5)}
    tested.assert{expected = "true", actual = simdjson.encode(true)}
    tested.assert{expected = "false", actual = simdjson.encode(false)}
    tested.assert{expected = "null", actual = simdjson.encode(simdjson.null)}
end)

t:test("uses simdjson's shortest number formatting", function()
    local values = {0.0, 3.14159265358979, 1.23e-10, 1.23e10, -123.456}

    for _, value in ipairs(values) do
        local encoded = simdjson.encode(value)
        tested.assert{expected = value, actual = simdjson.parse(encoded)}
    end

    tested.assert{expected = "1.5", actual = simdjson.encode(1.5)}
    tested.assert{expected = "2.7", actual = simdjson.encode(2.7)}
end)

t:test("preserves Lua integers on Lua 5.3 and newer", {run_when=math.type ~= nil}, function()
    local encoded = simdjson.encode(9223372036854775807)
    tested.assert{expected = "9223372036854775807", actual = encoded}
    tested.assert{expected = "integer", actual = math.type(simdjson.parse(encoded))}
end)

t:test("encodes booleans at every nesting position", function()
    tested.assert{expected = "[true,false,true]", actual = simdjson.encode({true, false, true})}

    local decoded = simdjson.parse(simdjson.encode({
        enabled = true,
        nested = {disabled = false},
        values = {false, true}
    }))

    tested.assert{expected = true, actual = decoded.enabled}
    tested.assert{expected = false, actual = decoded.nested.disabled}
    tested.assert{expected = false, actual = decoded.values[1]}
    tested.assert{expected = true, actual = decoded.values[2]}
end)

t:test("encodes arrays, objects, and numeric object keys", function()
    local decoded = simdjson.parse(simdjson.encode({
        items = {1, "two", true},
        object = {answer = 42},
        keyed = {[0] = "zero", value = "other"}
    }))

    tested.assert{expected = 1, actual = decoded.items[1]}
    tested.assert{expected = "two", actual = decoded.items[2]}
    tested.assert{expected = true, actual = decoded.items[3]}
    tested.assert{expected = 42, actual = decoded.object.answer}
    tested.assert{expected = "zero", actual = decoded.keyed[simdjson.encode(0)]}
    tested.assert{expected = "{}", actual =  simdjson.encode({})}
end)

t:test("encodes sparse numeric tables without output amplification", function()
    local encoded = simdjson.encode({[1] = "first", [1000000] = "last"})
    local decoded = simdjson.parse(encoded)

    tested.assert{expected=true, actual = #encoded < 100}
    tested.assert{expected="first", actual = decoded[simdjson.encode(1)]}
    tested.assert{expected="last", actual = decoded[simdjson.encode(1000000)]}
end)


t:test("supports per-call options", function()
    local value = {child = {value = true}}
    tested.assert_throws_exception{actual=function()
        simdjson.encode(value, {maxDepth = 1})
    end}

    local encoded = simdjson.encode(value, {maxDepth = 2, bufferSize = 8})
    tested.assert{expected = true, actual = simdjson.parse(encoded).child.value}
end)


t:test("supports global encode settings", function()
    simdjson.setMaxEncodeDepth(64)
    simdjson.setEncodeBufferSize(1024)
    tested.assert{expected = 64, actual = simdjson.getMaxEncodeDepth()}
    tested.assert{expected = 1024, actual = simdjson.getEncodeBufferSize()}
end)

t:test("grows beyond the initial string builder capacity", function()
    local value = string.rep("abcdef", 4096)
    local encoded = simdjson.encode({value = value}, {bufferSize = 8})
    tested.assert{expected = value, actual = simdjson.parse(encoded).value}
end)

t:test("rejects unsupported values and invalid options", function()
    tested.assert_throws_exception{actual = function()
        simdjson.encode(function() end)
    end}
    tested.assert_throws_exception{actual = function()
        simdjson.encode({}, {maxDepth = 0})
    end}
    tested.assert_throws_exception{actual = function()
        simdjson.encode({}, {bufferSize = 0})
    end}
    tested.assert_throws_exception{actual = function()
        simdjson.encode({}, {max_depth = 10})
    end}
    tested.assert_throws_exception{actual = function()
        simdjson.encode({}, {maxDepth = 1.5})
    end}
    tested.assert_throws_exception{actual = function()
        simdjson.encode({}, {bufferSize = 1.5})
    end}
    tested.assert_throws_exception{actual = function()
        simdjson.encode({}, {maxDepth = "10"})
    end}
    tested.assert_throws_exception{actual = function()
        simdjson.encode({}, {bufferSize = 64 * 1024 * 1024 + 1})
    end}
end)

t:test("preserves embedded NUL bytes", function()
    print("NUL bytes test")
    local value = "before\0after"
    tested.assert{actual = value, expected = simdjson.parse(simdjson.encode(value))}
end)

t:test("rejects non-finite numbers", function()
    print("non-finite numbers test")
    local v = 0/0
    print("value:", v)
    print("tostring:", tostring(v))
    print("type:", type(v))
    print("is number:", type(v) == "number")
    if _VERSION == "Lua 5.3" or _VERSION == "Lua 5.4" or _VERSION == "Lua 5.5" then
        print("math type:", math.type(v))
    end
    print("raw tostring:", string.format("%.17g", v))

    for _, value in ipairs({0 / 0, math.huge, -math.huge}) do
        tested.assert_throws_exception{actual = function()
            simdjson.encode(value)
        end}
    end
end)

t:test("rejects direct and indirect table cycles", function()
    print("direct and indirect table cycles")
    local direct = {}
    direct.self = direct

    local first = {}
    local second = {first = first}
    first.second = second

    tested.assert_throws_exception{actual = function()
        simdjson.encode(direct)
    end}
    tested.assert_throws_exception{actual = function()
        simdjson.encode(first)
    end}
end)

t:test("recovers after encoding errors", function()
    local cyclic = {}
    cyclic.self = cyclic

    tested.assert_throws_exception{actual = function()
        simdjson.encode(cyclic)
    end}
    tested.assert_throws_exception{actual = function()
        simdjson.encode("\255")
    end}
    tested.assert{expected = '{"valid":true}', actual = simdjson.encode({valid = true})}
end)

t:test("rejects overflowing configuration values", function()
    tested.assert_throws_exception{actual = function()
        simdjson.setMaxEncodeDepth(4294967297)
    end}
    tested.assert_throws_exception{actual = function()
        simdjson.encode({}, {maxDepth = 4294967297})
    end}
end)

return t