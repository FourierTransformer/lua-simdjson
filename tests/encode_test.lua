local simdjson = require("simdjson")

local tested = require("tested")
t = tested.new()

local major, minor = _VERSION:match('([%d]+)%.(%d+)')

local original_max_depth
local original_buffer_size

t:before_each(function()
    original_max_depth = simdjson.getMaxEncodeDepth()
    original_buffer_size = simdjson.getEncodeBufferSize()
end)

t:after_each(function()
    simdjson.setMaxEncodeDepth(original_max_depth)
    simdjson.setEncodeBufferSize(original_buffer_size)
end)

t:test("encodes scalar values", function()
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
    local value = "before\0after"
    tested.assert{actual = value, expected = simdjson.parse(simdjson.encode(value))}
end)

t:test("rejects non-finite numbers", function()
    for _, value in ipairs({0 / 0, math.huge, -math.huge}) do
        tested.assert_throws_exception{actual = function()
            simdjson.encode(value)
        end}
    end
end)

t:test("rejects direct and indirect table cycles", function()
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

t:test("rejects NaN and infinity in scalar form", function()
    local test_values = {
        {value = 0 / 0, name = "NaN"},
        {value = math.huge, name = "positive infinity"},
        {value = -math.huge, name = "negative infinity"},
    }

    for _, test in ipairs(test_values) do
        local success, err = pcall(function()
            simdjson.encode(test.value)
        end)
        tested.assert{expected = false, actual = success}
        tested.assert{expected = true, actual = tostring(err):match("cannot encode NaN or infinity as JSON") ~= nil}
    end
end)

t:test("rejects NaN and infinity nested in arrays", function()
    local test_values = {
        {1, 0 / 0, 3},
        {0 / 0},
        {1, 2, math.huge},
        {1, 2, -math.huge},
    }

    for _, array in ipairs(test_values) do
        local success, err = pcall(function()
            simdjson.encode(array)
        end)
        tested.assert{expected = false, actual = success}
        tested.assert{expected = true, actual = tostring(err):match("cannot encode NaN or infinity as JSON") ~= nil}
    end
end)

t:test("rejects NaN and infinity nested in objects", function()
    local test_values = {
        {a = 1, b = 0 / 0, c = 3},
        {nan = 0 / 0},
        {inf = math.huge},
        {ninf = -math.huge},
    }

    for _, obj in ipairs(test_values) do
        local success, err = pcall(function()
            simdjson.encode(obj)
        end)
        tested.assert{expected = false, actual = success}
        tested.assert{expected = true, actual = tostring(err):match("cannot encode NaN or infinity as JSON") ~= nil}
    end
end)

t:test("rejects non-finite numeric object keys", function()
    local success1, err1 = pcall(function()
        simdjson.encode({[math.huge] = "value"})
    end)
    tested.assert{expected = false, actual = success1}
    tested.assert{expected = true, actual = tostring(err1):match("cannot encode NaN or infinity as JSON") ~= nil}

    local success2, err2 = pcall(function()
        simdjson.encode({[-math.huge] = "value"})
    end)
    tested.assert{expected = false, actual = success2}
    tested.assert{expected = true, actual = tostring(err2):match("cannot encode NaN or infinity as JSON") ~= nil}
end)

t:test("recovers after NaN/infinity errors", function()
    -- Single error recovery
    tested.assert_throws_exception{actual = function()
        simdjson.encode(0 / 0)
    end}
    tested.assert{expected = '{"valid":true}', actual = simdjson.encode({valid = true})}

    -- Multiple distinct errors in sequence
    tested.assert_throws_exception{actual = function()
        simdjson.encode(math.huge)
    end}
    tested.assert{expected = '{"valid":true}', actual = simdjson.encode({valid = true})}

    tested.assert_throws_exception{actual = function()
        simdjson.encode({nested = 0 / 0})
    end}
    tested.assert{expected = '{"valid":true}', actual = simdjson.encode({valid = true})}
end)

t:test("rejects unsupported keys, values, and depth with a recoverable error", function()
    -- Every encoder error is raised from inside the serializer's C++ frames.
    -- Exercise each distinct error site so the native Windows (MSVC) runs
    -- also cover Lua errors raised after builder appends (issue #117).
    local function nested_object(depth, leaf)
        local root = {}
        local current = root
        for _ = 1, depth do
            current.child = {}
            current = current.child
        end
        current.leaf = leaf
        return root
    end

    local function nested_array(depth, leaf)
        local root = {}
        local current = root
        for _ = 1, depth do
            current[1] = {}
            current = current[1]
        end
        current[1] = leaf
        return root
    end

    local cases = {
        {name = "boolean key", pattern = "unsupported key type",
         build = function() return {[true] = 1} end},
        {name = "table key", pattern = "unsupported key type",
         build = function() return {[{}] = 1} end},
        {name = "function key", pattern = "unsupported key type",
         build = function() return {[print] = 1} end},
        {name = "function value", pattern = "unsupported Lua data type",
         build = function() return {value = print} end},
        {name = "userdata value", pattern = "unsupported Lua data type",
         build = function() return {value = io.stdout} end},
        {name = "thread value", pattern = "unsupported Lua data type",
         build = function() return {value = coroutine.create(function() end)} end},
        {name = "function in array", pattern = "unsupported Lua data type",
         build = function() return {1, 2, print} end},
        {name = "boolean key after valid entries", pattern = "unsupported key type",
         build = function() return {a = 1, b = 2, [false] = 3} end},
        {name = "boolean key nested in object", pattern = "unsupported key type",
         build = function() return nested_object(5, {[true] = 1}) end},
        {name = "function nested in array", pattern = "unsupported Lua data type",
         build = function() return nested_array(5, print) end},
        {name = "cycle nested in object", pattern = "cyclic table",
         build = function()
             local root = nested_object(3, nil)
             root.child.child.child.loop = root
             return root
         end},
        {name = "depth exceeded in objects", pattern = "maximum nesting depth exceeded",
         options = {maxDepth = 4},
         build = function() return nested_object(10, 1) end},
        {name = "depth exceeded in arrays", pattern = "maximum nesting depth exceeded",
         options = {maxDepth = 4},
         build = function() return nested_array(10, 1) end},
    }

    for _, case in ipairs(cases) do
        -- Repeat so one bad unwind or leaked builder state cannot hide.
        for _ = 1, 50 do
            local success, err = pcall(function()
                if case.options then
                    return simdjson.encode(case.build(), case.options)
                end
                return simdjson.encode(case.build())
            end)
            tested.assert{expected = false, actual = success, message = case.name}
            tested.assert{
                expected = true,
                actual = tostring(err):find(case.pattern, 1, true) ~= nil,
                message = case.name .. ": " .. tostring(err),
            }
        end
        tested.assert{expected = '{"valid":true}', actual = simdjson.encode({valid = true})}
    end
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
