local simdjson = require("simdjson")
local cjson = require("cjson")


describe("encode numbers correctly", function()
    it("should encode numbers the same as cjson", function()
        local testData = {
            float = 1.2,
            min_signed_integer = -9223372036854775808,
            max_signed_integer = 9223372036854775807,
            one_above_max_signed_integer = 9223372036854775808,
            min_unsigned_integer = 0,
            max_unsigned_integer = 18446744073709551615
        }

        for k, v in pairs(testData) do
            local td = { [k] = v }
            local simdjsonEncoded = simdjson.encode(td)
            local cjsonEncoded = cjson.encode(td)
            assert.are.same(cjsonEncoded, simdjsonEncoded)
        end

        local cjsonEncode = cjson.encode(testData)
        local simdjsonEncode = simdjson.encode(testData)
        assert.are.same(cjsonEncode, simdjsonEncode)
    end)

    it("should encode special float values", function()
        local testCases = {
            { value = 0.0,               name = "zero" },
            { value = 3.14159265358979,  name = "pi" },
            { value = 2.718281828459045, name = "e" },
            { value = 1.23e-10,          name = "small scientific" },
            { value = 1.23e10,           name = "large scientific" },
            { value = -123.456,          name = "negative float" },
        }

        for _, test in ipairs(testCases) do
            local data = { value = test.value }
            local simdjsonEncoded = simdjson.encode(data)
            local cjsonEncoded = cjson.encode(data)
            assert.are.same(cjsonEncoded, simdjsonEncoded)
        end
    end)

    it("should encode array of numbers", function()
        local numbers = { 1, 2, 3, 4, 5, -1, -2, 0, 1.5, 2.7 }
        local data = { numbers = numbers }
        local simdjsonEncoded = simdjson.encode(data)
        local cjsonEncoded = cjson.encode(data)
        assert.are.same(cjsonEncoded, simdjsonEncoded)
    end)
end)

describe("encode strings correctly", function()
    it("should encode simple strings", function()
        local testCases = {
            { str = "hello",       name = "simple" },
            { str = "",            name = "empty" },
            { str = "hello world", name = "with space" },
            { str = "123",         name = "numeric string" },
        }

        for _, test in ipairs(testCases) do
            local data = { str = test.str }
            local simdjsonEncoded = simdjson.encode(data)
            local cjsonEncoded = cjson.encode(data)
            assert.are.same(cjsonEncoded, simdjsonEncoded)
        end
    end)

    it("should encode strings with special characters", function()
        local testCases = {
            { str = "hello\nworld", name = "newline" },
            { str = "hello\tworld", name = "tab" },
            { str = "hello\rworld", name = "carriage return" },
            { str = "hello\"world", name = "quote" },
            { str = "hello\\world", name = "backslash" },
        }

        for _, test in ipairs(testCases) do
            local data = { str = test.str }
            local simdjsonEncoded = simdjson.encode(data)
            local cjsonEncoded = cjson.encode(data)
            assert.are.same(cjsonEncoded, simdjsonEncoded)
        end
    end)

    it("should encode forward slash without escaping", function()
        -- simdjson doesn't escape forward slashes (which is valid JSON)
        local data = { str = "hello/world" }
        local simdjsonEncoded = simdjson.encode(data)
        assert.are.same('{"str":"hello/world"}', simdjsonEncoded)
    end)

    it("should encode unicode strings", function()
        local testCases = {
            { str = "Hello 世界", name = "chinese" },
            { str = "Hello मुndi", name = "hindi" },
            { str = "Hello 🌍", name = "emoji" },
            { str = "café", name = "accented" },
        }

        for _, test in ipairs(testCases) do
            local data = { str = test.str }
            local simdjsonEncoded = simdjson.encode(data)
            local cjsonEncoded = cjson.encode(data)
            assert.are.same(cjsonEncoded, simdjsonEncoded)
        end
    end)

    it("should encode array of strings", function()
        local strings = { "one", "two", "three", "", "with space" }
        local data = { strings = strings }
        local simdjsonEncoded = simdjson.encode(data)
        local cjsonEncoded = cjson.encode(data)
        assert.are.same(cjsonEncoded, simdjsonEncoded)
    end)
end)

describe("encode booleans correctly", function()
    it("should encode boolean values", function()
        local data1 = { value = true }
        assert.are.same(cjson.encode(data1), simdjson.encode(data1))

        local data2 = { value = false }
        assert.are.same(cjson.encode(data2), simdjson.encode(data2))
    end)

    it("should encode boolean arrays", function()
        local bools = { true, false, true, false }
        local data = { bools = bools }
        local simdjsonEncoded = simdjson.encode(data)
        local cjsonEncoded = cjson.encode(data)
        assert.are.same(cjsonEncoded, simdjsonEncoded)
    end)

    it("should encode mixed boolean and other types", function()
        local mixed = { true, 1, "test", false, 2.5 }
        local data = { mixed = mixed }
        local simdjsonEncoded = simdjson.encode(data)
        local cjsonEncoded = cjson.encode(data)
        assert.are.same(cjsonEncoded, simdjsonEncoded)
    end)
end)

describe("encode arrays correctly", function()
    it("should encode empty arrays", function()
        local data = { arr = {} }
        local simdjsonEncoded = simdjson.encode(data)
        local cjsonEncoded = cjson.encode(data)
        assert.are.same(cjsonEncoded, simdjsonEncoded)
    end)

    it("should encode nested arrays", function()
        local data = {
            nested = {
                { 1, 2, 3 },
                { 4, 5, 6 },
                { 7, 8, 9 }
            }
        }
        local simdjsonEncoded = simdjson.encode(data)
        local cjsonEncoded = cjson.encode(data)
        assert.are.same(cjsonEncoded, simdjsonEncoded)
    end)

    it("should encode deeply nested arrays", function()
        local data = { arr = { { { { { 1 } } } } } }
        local simdjsonEncoded = simdjson.encode(data)
        local cjsonEncoded = cjson.encode(data)
        assert.are.same(cjsonEncoded, simdjsonEncoded)
    end)

    it("should encode arrays with mixed types", function()
        local data = {
            mixed = { 1, "two", 3.0, true, false, { nested = "value" } }
        }
        local simdjsonEncoded = simdjson.encode(data)
        local cjsonEncoded = cjson.encode(data)
        assert.are.same(cjsonEncoded, simdjsonEncoded)
    end)
end)

describe("encode objects correctly", function()
    it("should encode empty objects", function()
        local data = {}
        local simdjsonEncoded = simdjson.encode(data)
        local cjsonEncoded = cjson.encode(data)
        assert.are.same(cjsonEncoded, simdjsonEncoded)
    end)

    it("should encode objects with string keys", function()
        local data = {
            key1 = "value1",
            key2 = "value2",
            key3 = "value3"
        }
        local simdjsonEncoded = simdjson.encode(data)
        local cjsonEncoded = cjson.encode(data)
        -- Note: key order may differ, so we decode and compare
        local simdjsonDecoded = simdjson.parse(simdjsonEncoded)
        local cjsonDecoded = cjson.decode(cjsonEncoded)
        assert.are.same(cjsonDecoded, simdjsonDecoded)
    end)

    it("should encode objects with numeric keys", function()
        local data = {
            ["1"] = "one",
            ["2"] = "two",
            ["3"] = "three"
        }
        local simdjsonEncoded = simdjson.encode(data)
        local cjsonEncoded = cjson.encode(data)
        local simdjsonDecoded = simdjson.parse(simdjsonEncoded)
        local cjsonDecoded = cjson.decode(cjsonEncoded)
        assert.are.same(cjsonDecoded, simdjsonDecoded)
    end)

    it("should encode nested objects", function()
        local data = {
            outer = {
                middle = {
                    inner = {
                        value = "deep"
                    }
                }
            }
        }
        local simdjsonEncoded = simdjson.encode(data)
        local cjsonEncoded = cjson.encode(data)
        assert.are.same(cjsonEncoded, simdjsonEncoded)
    end)

    it("should encode objects with mixed value types", function()
        local data = {
            string = "value",
            number = 42,
            float = 3.14,
            bool_true = true,
            bool_false = false,
            array = { 1, 2, 3 },
            object = { nested = "value" }
        }
        local simdjsonEncoded = simdjson.encode(data)
        local cjsonEncoded = cjson.encode(data)
        local simdjsonDecoded = simdjson.parse(simdjsonEncoded)
        local cjsonDecoded = cjson.decode(cjsonEncoded)
        assert.are.same(cjsonDecoded, simdjsonDecoded)
    end)
end)

describe("encode complex json types", function()
    it("should encode complex json types the same as cjson", function()
        local testData = {
            object = {
                key1 = "value1",
                key2 = 2,
                key3 = { nestedKey = "nestedValue" }
            },
            mixed = {
                "string",
                123,
                true,
                { nestedArray = { 1, 2, 3 } },
                { nestedObject = { key = "value" } }
            },
            mixed_complex = {
                array = { "abc", 123, true },
                object = { key = "value", number = 456 },
                nested_object = {
                    inner_key = { 1, 2, 3, { deep_key = "deep_value" } }
                }
            },
            bools = { true, false, true, false }
        }

        for k, v in pairs(testData) do
            local td = { [k] = v }
            local simdjsonEncoded = simdjson.encode(td)
            local cjsonEncoded = cjson.encode(td)
            assert.are.same(cjsonEncoded, simdjsonEncoded)
        end
    end)

    it("should encode complex nested structures", function()
        local data = {
            users = {
                {
                    id = 1,
                    name = "Alice",
                    active = true,
                    scores = { 95, 87, 92 }
                },
                {
                    id = 2,
                    name = "Bob",
                    active = false,
                    scores = { 78, 85, 90 }
                }
            },
            metadata = {
                version = "1.0",
                count = 2
            }
        }
        local simdjsonEncoded = simdjson.encode(data)
        local cjsonEncoded = cjson.encode(data)
        assert.are.same(cjsonEncoded, simdjsonEncoded)
    end)

    it("should handle arrays of objects", function()
        local data = {
            items = {
                { id = 1, name = "Item 1" },
                { id = 2, name = "Item 2" },
                { id = 3, name = "Item 3" }
            }
        }
        local simdjsonEncoded = simdjson.encode(data)
        local cjsonEncoded = cjson.encode(data)
        assert.are.same(cjsonEncoded, simdjsonEncoded)
    end)

    it("should handle objects with array values", function()
        local data = {
            numbers = { 1, 2, 3, 4, 5 },
            strings = { "a", "b", "c" },
            booleans = { true, false, true }
        }
        local simdjsonEncoded = simdjson.encode(data)
        local cjsonEncoded = cjson.encode(data)
        local simdjsonDecoded = simdjson.parse(simdjsonEncoded)
        local cjsonDecoded = cjson.decode(cjsonEncoded)
        assert.are.same(cjsonDecoded, simdjsonDecoded)
    end)
end)

describe("encode edge cases", function()
    it("should handle very long strings", function()
        local longString = string.rep("a", 10000)
        local data = { str = longString }
        local simdjsonEncoded = simdjson.encode(data)
        local cjsonEncoded = cjson.encode(data)
        assert.are.same(cjsonEncoded, simdjsonEncoded)
    end)

    it("should handle large arrays", function()
        local largeArray = {}
        for i = 1, 1000 do
            largeArray[i] = i
        end
        local data = { arr = largeArray }
        local simdjsonEncoded = simdjson.encode(data)
        local cjsonEncoded = cjson.encode(data)
        assert.are.same(cjsonEncoded, simdjsonEncoded)
    end)

    it("should handle sparse arrays as objects", function()
        local sparseArray = {}
        sparseArray[1] = "first"
        sparseArray[5] = "fifth"
        sparseArray[10] = "tenth"
        local data = { sparse = sparseArray }

        -- simdjson treats sparse arrays as objects
        local simdjsonEncoded = simdjson.encode(data)
        assert.is_true(simdjsonEncoded:find('"sparse"') ~= nil)

        -- Verify it can be decoded back
        local decoded = simdjson.parse(simdjsonEncoded)
        assert.is_not_nil(decoded.sparse)
    end)

    it("should encode keys with special characters", function()
        local data = {
            ["key with spaces"] = "value1",
            ["key-with-dashes"] = "value2",
            ["key_with_underscores"] = "value3",
            ["key.with.dots"] = "value4"
        }
        local simdjsonEncoded = simdjson.encode(data)
        local cjsonEncoded = cjson.encode(data)
        local simdjsonDecoded = simdjson.parse(simdjsonEncoded)
        local cjsonDecoded = cjson.decode(cjsonEncoded)
        assert.are.same(cjsonDecoded, simdjsonDecoded)
    end)

    it("should roundtrip encode and decode", function()
        local original = {
            name = "Test",
            value = 42,
            active = true,
            items = { 1, 2, 3 },
            nested = { key = "value" }
        }
        local encoded = simdjson.encode(original)
        local decoded = simdjson.parse(encoded)

        -- Compare individual fields since table equality is by reference
        assert.are.same(original.name, decoded.name)
        assert.are.same(original.value, decoded.value)
        assert.are.same(original.active, decoded.active)
        assert.are.same(original.items[1], decoded.items[1])
        assert.are.same(original.nested.key, decoded.nested.key)
    end)

    it("basic string", function()
        local original = "test string"
        local simdjsonEncoded = simdjson.encode(original)
        local cjsonEncoded = cjson.encode(original)
        assert.are.same(cjsonEncoded, simdjsonEncoded)
    end)
end)
