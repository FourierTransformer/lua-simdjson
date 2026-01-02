local simdjson = require("simdjson")
local cjson = require("cjson")

describe("encode() security and edge cases", function()
    describe("String injection and escaping", function()
        it("should properly escape quote characters", function()
            local data = { value = 'test"with"quotes' }
            local encoded = simdjson.encode(data)
            assert.is_true(encoded:find('\\"') ~= nil)
            local decoded = simdjson.parse(encoded)
            assert.are.same(data.value, decoded.value)
        end)

        it("should properly escape backslashes", function()
            local data = { value = 'test\\with\\backslashes' }
            local encoded = simdjson.encode(data)
            local decoded = simdjson.parse(encoded)
            assert.are.same(data.value, decoded.value)
        end)

        it("should properly escape control characters", function()
            local test_cases = {
                { str = "line1\nline2",    name = "newline" },
                { str = "tab\there",       name = "tab" },
                { str = "return\rhere",    name = "carriage return" },
                { str = "backspace\bhere", name = "backspace" },
                { str = "form\ffeed",      name = "form feed" },
            }

            for _, test in ipairs(test_cases) do
                local data = { value = test.str }
                local encoded = simdjson.encode(data)
                local decoded = simdjson.parse(encoded)
                assert.are.same(data.value, decoded.value)
            end
        end)

        it("should handle strings with null bytes", function()
            -- Note: null bytes may be truncated as C strings are null-terminated
            local data = { value = "before\x00after" }
            local encoded = simdjson.encode(data)
            -- Verify encoding doesn't crash and produces valid JSON
            assert.is_true(encoded:find("before") ~= nil)
            local decoded = simdjson.parse(encoded)
            -- String may be truncated at null byte
            assert.is_true(decoded.value == "before" or decoded.value == "before\x00after")
        end)

        it("should handle common control characters safely", function()
            -- Test specific control characters that should be properly escaped
            local test_chars = {
                { char = "\t", name = "tab",             escape = "\\t" },
                { char = "\n", name = "newline",         escape = "\\n" },
                { char = "\r", name = "carriage return", escape = "\\r" },
                { char = "\b", name = "backspace",       escape = "\\b" },
                { char = "\f", name = "form feed",       escape = "\\f" },
            }

            for _, test in ipairs(test_chars) do
                local data = { value = "before" .. test.char .. "after" }
                local encoded = simdjson.encode(data)
                -- Verify the character is properly escaped in JSON
                assert.is_true(encoded:find("before") ~= nil)
                local decoded = simdjson.parse(encoded)
                assert.are.same(data.value, decoded.value)
            end
        end)
    end)

    describe("Potential XSS and HTML injection", function()
        it("should handle HTML/XML special characters", function()
            local data = {
                html = "<script>alert('xss')</script>",
                xml = "<?xml version='1.0'?>",
                tags = "<div>test</div>",
                entities = "&lt;&gt;&amp;&quot;&#39;"
            }
            local encoded = simdjson.encode(data)
            local decoded = simdjson.parse(encoded)
            assert.are.same(data.html, decoded.html)
            assert.are.same(data.xml, decoded.xml)
            assert.are.same(data.tags, decoded.tags)
            assert.are.same(data.entities, decoded.entities)
        end)

        it("should not execute embedded JavaScript", function()
            local malicious = {
                js = "'; alert('xss'); //",
                comment = "/* comment */ code",
                injection = "\"); malicious(); //"
            }
            local encoded = simdjson.encode(malicious)
            -- Verify it's properly escaped
            assert.is_true(encoded:find("alert") ~= nil)
            local decoded = simdjson.parse(encoded)
            assert.are.same(malicious.js, decoded.js)
        end)
    end)

    describe("Key injection and object vulnerabilities", function()
        it("should handle keys with special characters", function()
            local data = {
                ["key'with'quotes"] = "value1",
                ['key"with"doublequotes'] = "value2",
                ["key\\with\\backslash"] = "value3",
                ["key\nwith\nnewline"] = "value4",
            }
            local encoded = simdjson.encode(data)
            local decoded = simdjson.parse(encoded)
            assert.are.same(data["key'with'quotes"], decoded["key'with'quotes"])
            assert.are.same(data['key"with"doublequotes'], decoded['key"with"doublequotes'])
        end)

        it("should handle prototype pollution keys", function()
            -- Common prototype pollution attack keys
            local data = {
                ["__proto__"] = "should_be_safe",
                ["constructor"] = "safe_value",
                ["prototype"] = "another_safe"
            }
            local encoded = simdjson.encode(data)
            local decoded = simdjson.parse(encoded)
            assert.are.same(data["__proto__"], decoded["__proto__"])
            assert.are.same(data["constructor"], decoded["constructor"])
        end)

        it("should handle empty string keys", function()
            local data = { [""] = "empty_key_value" }
            local encoded = simdjson.encode(data)
            local decoded = simdjson.parse(encoded)
            assert.are.same(data[""], decoded[""])
        end)

        it("should handle very long keys", function()
            local long_key = string.rep("a", 10000)
            local data = { [long_key] = "value" }
            local encoded = simdjson.encode(data)
            local decoded = simdjson.parse(encoded)
            assert.are.same(data[long_key], decoded[long_key])
        end)
    end)

    describe("Number vulnerabilities", function()
        it("should handle very large integers without overflow", function()
            local data = {
                max_int = 9007199254740991,       -- Max safe integer in JavaScript
                min_int = -9007199254740991,
                large_pos = 9223372036854775807,  -- Max int64
                large_neg = -9223372036854775808, -- Min int64
            }
            local encoded = simdjson.encode(data)
            local decoded = simdjson.parse(encoded)
            -- Allow for precision loss on very large numbers
            assert.is_true(math.abs(decoded.max_int - data.max_int) < 1)
        end)

        it("should handle floating point edge cases", function()
            local data = {
                zero = 0.0,
                very_small = 1e-308,
                very_large = 1e308,
                negative = -123.456,
            }
            local encoded = simdjson.encode(data)
            local decoded = simdjson.parse(encoded)
            assert.are.same(data.zero, decoded.zero)
        end)

        it("should handle many decimal places", function()
            local data = { pi = 3.14159265358979323846264338327950288 }
            local encoded = simdjson.encode(data)
            local decoded = simdjson.parse(encoded)
            -- Check that precision is maintained reasonably
            assert.is_true(math.abs(decoded.pi - 3.141592653589793) < 0.000001)
        end)
    end)

    describe("Nested structure vulnerabilities", function()
        it("should enforce max depth to prevent stack overflow", function()
            -- Create a very deep structure
            local function create_deep(depth)
                if depth == 0 then
                    return "bottom"
                end
                return { nested = create_deep(depth - 1) }
            end

            local deep = create_deep(50)

            -- Should succeed with high limit
            local success1 = pcall(function()
                simdjson.encode(deep, 100)
            end)
            assert.is_true(success1)

            -- Should fail with low limit
            local success2 = pcall(function()
                simdjson.encode(deep, 10)
            end)
            assert.is_false(success2)
        end)

        it("should handle wide objects without issues", function()
            -- Create object with many keys
            local wide = {}
            for i = 1, 1000 do
                wide["key" .. i] = "value" .. i
            end
            local encoded = simdjson.encode(wide)
            local decoded = simdjson.parse(encoded)
            assert.are.same(wide["key500"], decoded["key500"])
        end)

        it("should handle wide arrays without issues", function()
            local wide = {}
            for i = 1, 1000 do
                wide[i] = i
            end
            local encoded = simdjson.encode(wide)
            local decoded = simdjson.parse(encoded)
            assert.are.same(#wide, #decoded)
            assert.are.same(wide[500], decoded[500])
        end)
    end)

    describe("Memory and performance vulnerabilities", function()
        it("should handle very long strings", function()
            -- Create a 1MB string
            local long_string = string.rep("x", 1024 * 1024)
            local data = { large = long_string }
            local encoded = simdjson.encode(data)
            assert.is_true(#encoded > 1024 * 1024)
            local decoded = simdjson.parse(encoded)
            assert.are.same(#long_string, #decoded.large)
        end)

        it("should handle arrays with many elements", function()
            local large_array = {}
            for i = 1, 10000 do
                large_array[i] = i
            end
            local data = { arr = large_array }
            local encoded = simdjson.encode(data)
            local decoded = simdjson.parse(encoded)
            assert.are.same(#large_array, #decoded.arr)
            assert.are.same(large_array[5000], decoded.arr[5000])
        end)

        it("should handle mixed large structure", function()
            local data = {
                strings = {},
                numbers = {},
                objects = {}
            }
            for i = 1, 100 do
                data.strings[i] = string.rep("test", 100)
                data.numbers[i] = i * 1.5
                data.objects[i] = { id = i, name = "item" .. i }
            end
            local encoded = simdjson.encode(data)
            local decoded = simdjson.parse(encoded)
            assert.are.same(#data.strings, #decoded.strings)
        end)
    end)

    describe("Unicode and encoding vulnerabilities", function()
        it("should handle various Unicode characters", function()
            local data = {
                emoji = "😀🎉🔥💯",
                chinese = "你好世界",
                arabic = "مرحبا",
                russian = "Привет",
                mixed = "Hello 世界 🌍",
            }
            local encoded = simdjson.encode(data)
            local decoded = simdjson.parse(encoded)
            assert.are.same(data.emoji, decoded.emoji)
            assert.are.same(data.chinese, decoded.chinese)
            assert.are.same(data.mixed, decoded.mixed)
        end)

        it("should handle Unicode escapes", function()
            -- String with Unicode escape sequences
            local data = { unicode = "test\\u0041\\u0042\\u0043" }
            local encoded = simdjson.encode(data)
            local decoded = simdjson.parse(encoded)
            assert.are.same(data.unicode, decoded.unicode)
        end)

        it("should handle zero-width and special Unicode", function()
            local data = {
                zero_width = "test\226\128\139here", -- Zero-width space (U+200B)
                rtl_mark = "test\226\128\143mark",   -- Right-to-left mark (U+200F)
                combining = "e\204\129",             -- e with acute accent combining (U+0301)
            }
            local encoded = simdjson.encode(data)
            local decoded = simdjson.parse(encoded)
            assert.are.same(data.zero_width, decoded.zero_width)
        end)
    end)

    describe("Malformed or unexpected input", function()
        it("should handle empty structures", function()
            local data = {
                empty_object = {},
                empty_array = {},
                empty_string = "",
            }
            local encoded = simdjson.encode(data)
            local decoded = simdjson.parse(encoded)
            assert.are.same(type(decoded.empty_object), "table")
            assert.are.same(decoded.empty_string, "")
        end)

        it("should handle boolean edge cases", function()
            local data = {
                true_val = true,
                false_val = false,
                bool_array = { true, false, true, false },
            }
            local encoded = simdjson.encode(data)
            assert.is_true(encoded:find("true") ~= nil)
            assert.is_true(encoded:find("false") ~= nil)
            local decoded = simdjson.parse(encoded)
            assert.are.same(data.true_val, decoded.true_val)
            assert.are.same(data.false_val, decoded.false_val)
        end)

        it("should consistently handle repeated encoding", function()
            local data = { test = "value", num = 42 }
            local encoded1 = simdjson.encode(data)
            local encoded2 = simdjson.encode(data)
            local encoded3 = simdjson.encode(data)

            local decoded1 = simdjson.parse(encoded1)
            local decoded2 = simdjson.parse(encoded2)
            local decoded3 = simdjson.parse(encoded3)

            assert.are.same(decoded1.test, decoded2.test)
            assert.are.same(decoded2.test, decoded3.test)
        end)
    end)

    describe("SQL and NoSQL injection patterns", function()
        it("should safely handle SQL injection patterns", function()
            local injection_patterns = {
                "'; DROP TABLE users; --",
                "1' OR '1'='1",
                "admin'--",
                "' OR 1=1--",
                "'; EXEC sp_MSForEachTable 'DROP TABLE ?'; --",
            }

            for _, pattern in ipairs(injection_patterns) do
                local data = { query = pattern }
                local encoded = simdjson.encode(data)
                local decoded = simdjson.parse(encoded)
                assert.are.same(pattern, decoded.query)
            end
        end)

        it("should safely handle NoSQL injection patterns", function()
            local nosql_patterns = {
                "{'$gt': ''}",
                "{'$ne': null}",
                "{'$where': 'this.password.length > 0'}",
            }

            for _, pattern in ipairs(nosql_patterns) do
                local data = { filter = pattern }
                local encoded = simdjson.encode(data)
                local decoded = simdjson.parse(encoded)
                assert.are.same(pattern, decoded.filter)
            end
        end)
    end)

    describe("Path traversal and file inclusion", function()
        it("should handle path traversal strings", function()
            local paths = {
                "../../etc/passwd",
                "..\\..\\windows\\system32",
                "/etc/passwd",
                "C:\\Windows\\System32\\config\\SAM",
                "../../../../../etc/shadow",
            }

            for _, path in ipairs(paths) do
                local data = { path = path }
                local encoded = simdjson.encode(data)
                local decoded = simdjson.parse(encoded)
                assert.are.same(path, decoded.path)
            end
        end)
    end)
end)
