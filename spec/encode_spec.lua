local simdjson = require("simdjson")

describe("simdjson.encode", function()
    local original_max_depth
    local original_buffer_size

    before_each(function()
        original_max_depth = simdjson.getMaxEncodeDepth()
        original_buffer_size = simdjson.getEncodeBufferSize()
    end)

    after_each(function()
        simdjson.setMaxEncodeDepth(original_max_depth)
        simdjson.setEncodeBufferSize(original_buffer_size)
    end)

    it("encodes scalar values", function()
        assert.are.equal('"value"', simdjson.encode("value"))
        assert.are.equal(42, simdjson.parse(simdjson.encode(42)))
        assert.are.equal("1.5", simdjson.encode(1.5))
        assert.are.equal("true", simdjson.encode(true))
        assert.are.equal("false", simdjson.encode(false))
        assert.are.equal("null", simdjson.encode(simdjson.null))
    end)

    it("uses simdjson's shortest number formatting", function()
        local values = {0.0, 3.14159265358979, 1.23e-10, 1.23e10, -123.456}

        for _, value in ipairs(values) do
            local encoded = simdjson.encode(value)
            assert.are.equal(value, simdjson.parse(encoded))
        end

        assert.are.equal("1.5", simdjson.encode(1.5))
        assert.are.equal("2.7", simdjson.encode(2.7))
    end)

    it("preserves Lua integers on Lua 5.3 and newer", function()
        if math.type then
            local encoded = simdjson.encode(9223372036854775807)
            assert.are.equal("9223372036854775807", encoded)
            assert.are.equal("integer", math.type(simdjson.parse(encoded)))
        end
    end)

    it("encodes booleans at every nesting position", function()
        assert.are.equal("[true,false,true]", simdjson.encode({true, false, true}))

        local decoded = simdjson.parse(simdjson.encode({
            enabled = true,
            nested = {disabled = false},
            values = {false, true}
        }))

        assert.is_true(decoded.enabled)
        assert.is_false(decoded.nested.disabled)
        assert.is_false(decoded.values[1])
        assert.is_true(decoded.values[2])
    end)

    it("encodes arrays, objects, and numeric object keys", function()
        local decoded = simdjson.parse(simdjson.encode({
            items = {1, "two", true},
            object = {answer = 42},
            keyed = {[0] = "zero", value = "other"}
        }))

        assert.are.equal(1, decoded.items[1])
        assert.are.equal("two", decoded.items[2])
        assert.is_true(decoded.items[3])
        assert.are.equal(42, decoded.object.answer)
        assert.are.equal("zero", decoded.keyed[simdjson.encode(0)])
        assert.are.equal("{}", simdjson.encode({}))
    end)

    it("encodes sparse numeric tables without output amplification", function()
        local encoded = simdjson.encode({[1] = "first", [1000000] = "last"})
        local decoded = simdjson.parse(encoded)

        assert.is_true(#encoded < 100)
        assert.are.equal("first", decoded[simdjson.encode(1)])
        assert.are.equal("last", decoded[simdjson.encode(1000000)])
    end)

    it("supports per-call options", function()
        local value = {child = {value = true}}
        assert.has_error(function()
            simdjson.encode(value, {maxDepth = 1})
        end)

        local encoded = simdjson.encode(value, {maxDepth = 2, bufferSize = 8})
        assert.is_true(simdjson.parse(encoded).child.value)
    end)

    it("supports global encode settings", function()
        simdjson.setMaxEncodeDepth(64)
        simdjson.setEncodeBufferSize(1024)
        assert.are.equal(64, simdjson.getMaxEncodeDepth())
        assert.are.equal(1024, simdjson.getEncodeBufferSize())
    end)

    it("grows beyond the initial string builder capacity", function()
        local value = string.rep("abcdef", 4096)
        local encoded = simdjson.encode({value = value}, {bufferSize = 8})
        assert.are.equal(value, simdjson.parse(encoded).value)
    end)

    it("rejects unsupported values and invalid options", function()
        assert.has_error(function()
            simdjson.encode(function() end)
        end)
        assert.has_error(function()
            simdjson.encode({}, {maxDepth = 0})
        end)
        assert.has_error(function()
            simdjson.encode({}, {bufferSize = 0})
        end)
        assert.has_error(function()
            simdjson.encode({}, {max_depth = 10})
        end)
        assert.has_error(function()
            simdjson.encode({}, {maxDepth = 1.5})
        end)
        assert.has_error(function()
            simdjson.encode({}, {bufferSize = 1.5})
        end)
        assert.has_error(function()
            simdjson.encode({}, {maxDepth = "10"})
        end)
        assert.has_error(function()
            simdjson.encode({}, {bufferSize = 64 * 1024 * 1024 + 1})
        end)
    end)

    it("preserves embedded NUL bytes", function()
        local value = "before\0after"
        assert.are.equal(value, simdjson.parse(simdjson.encode(value)))
    end)

    it("rejects non-finite numbers", function()
        for _, value in ipairs({0 / 0, math.huge, -math.huge}) do
            assert.has_error(function()
                simdjson.encode(value)
            end)
        end
    end)

    it("rejects direct and indirect table cycles", function()
        local direct = {}
        direct.self = direct

        local first = {}
        local second = {first = first}
        first.second = second

        assert.has_error(function()
            simdjson.encode(direct)
        end)
        assert.has_error(function()
            simdjson.encode(first)
        end)
    end)

    it("recovers after encoding errors", function()
        local cyclic = {}
        cyclic.self = cyclic

        assert.has_error(function()
            simdjson.encode(cyclic)
        end)
        assert.has_error(function()
            simdjson.encode("\255")
        end)
        assert.are.equal('{"valid":true}', simdjson.encode({valid = true}))
    end)

    it("rejects overflowing configuration values", function()
        assert.has_error(function()
            simdjson.setMaxEncodeDepth(4294967297)
        end)
        assert.has_error(function()
            simdjson.encode({}, {maxDepth = 4294967297})
        end)
    end)
end)
