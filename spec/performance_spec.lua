local simdjson = require("simdjson")
local cjson = require("cjson")

-- Track wins
local simdjson_wins = 0
local cjson_wins = 0
local total_tests = 0
local iterations = 10000

-- Helper function to measure time
local function measure_time(func, iterations)
    iterations = iterations or 1
    collectgarbage("collect") -- Clean up before measurement
    local start = os.clock()
    for i = 1, iterations do func() end
    local elapsed = os.clock() - start
    return elapsed, elapsed / iterations
end

-- Helper to format numbers
local function format_number(num)
    if num < 0.001 then
        return string.format("%.6f ms", num * 1000)
    elseif num < 1 then
        return string.format("%.3f ms", num * 1000)
    else
        return string.format("%.3f s", num)
    end
end

-- Helper to show comparison
local function show_comparison(name, simdjson_time, cjson_time)
    local speedup = cjson_time / simdjson_time
    local winner = speedup > 1 and "simdjson" or "cjson"
    local ratio = speedup > 1 and speedup or (1 / speedup)

    -- Track wins
    total_tests = total_tests + 1
    if winner == "simdjson" then
        simdjson_wins = simdjson_wins + 1
    else
        cjson_wins = cjson_wins + 1
    end

    -- Add newline before first result to separate from test marker
    if total_tests == 1 then print() end

    print(string.format(
        "  %-30s | simdjson: %s | cjson: %s | %s is %.2fx faster", name,
        format_number(simdjson_time), format_number(cjson_time), winner,
        ratio))
end

describe("Performance Comparison: simdjson vs cjson", function()
    it(string.format("Simple Object Encoding (%s iterations)", iterations),
        function()
            local simple_data = { name = "test", value = 42, active = true }

            local simdjson_time = measure_time(function()
                simdjson.encode(simple_data)
            end, iterations)

            local cjson_time = measure_time(function()
                cjson.encode(simple_data)
            end, iterations)
            show_comparison("Simple object", simdjson_time, cjson_time)
        end)

    it(string.format("Array Encoding (%s iterations)", iterations), function()
        local array_data = {}
        for i = 1, 100 do array_data[i] = i end
        array_data = { numbers = array_data }

        local simdjson_time = measure_time(function()
            simdjson.encode(array_data)
        end, iterations)

        local cjson_time = measure_time(function()
            cjson.encode(array_data)
        end, iterations)
        show_comparison("100-element array", simdjson_time, cjson_time)
    end)

    it(string.format("Nested Object Encoding (%s iterations)", iterations),
        function()
            local nested_data = {
                level1 = { level2 = { level3 = { level4 = { value = "deep" } } } }
            }

            local simdjson_time = measure_time(function()
                simdjson.encode(nested_data)
            end, iterations)

            local cjson_time = measure_time(function()
                cjson.encode(nested_data)
            end, iterations)
            show_comparison("5-level nesting", simdjson_time, cjson_time)
        end)

    it(string.format("Nested Object Encoding (%s iterations)", iterations),
        function()
            local nested_data = {
                level1 = {
                    level2 = {
                        level3 = {
                            level4 = {
                                level5 = {
                                    level6 = {
                                        level7 = {
                                            level8 = {
                                                level9 = {
                                                    level10 = { value = "deep" }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            local simdjson_time = measure_time(function()
                simdjson.encode(nested_data)
            end, iterations)

            local cjson_time = measure_time(function()
                cjson.encode(nested_data)
            end, iterations)
            show_comparison("10-level nesting", simdjson_time, cjson_time)
        end)

    it(string.format("String-Heavy Data (%s iterations)", iterations),
        function()
            local string_data = {
                str1 = "The quick brown fox jumps over the lazy dog",
                str2 = "Lorem ipsum dolor sit amet, consectetur adipiscing elit",
                str3 = "Pack my box with five dozen liquor jugs"
            }

            local simdjson_time = measure_time(function()
                simdjson.encode(string_data)
            end, iterations)

            local cjson_time = measure_time(function()
                cjson.encode(string_data)
            end, iterations)
            show_comparison("String-heavy object", simdjson_time, cjson_time)
        end)

    it(string.format("Mixed Type Array (%s iterations)", iterations), function()
        local mixed_array = {
            data = { 1, "two", 3.0, true, false, { nested = "value" } }
        }

        local simdjson_time = measure_time(function()
            simdjson.encode(mixed_array)
        end, iterations)

        local cjson_time = measure_time(function()
            cjson.encode(mixed_array)
        end, iterations)
        show_comparison("Mixed type array", simdjson_time, cjson_time)
    end)

    it(string.format("Large Object (%s iterations)", iterations), function()
        local large_object = {}
        for i = 1, 100 do large_object["key" .. i] = "value" .. i end
        large_object = { data = large_object }

        local simdjson_time = measure_time(function()
            simdjson.encode(large_object)
        end, iterations)

        local cjson_time = measure_time(function()
            cjson.encode(large_object)
        end, iterations)
        show_comparison("100-key object", simdjson_time, cjson_time)
    end)

    it(string.format("Large Array (%s iterations)", iterations), function()
        local large_array = {}
        for i = 1, 1000 do large_array[i] = i end
        large_array = { data = large_array }

        local simdjson_time = measure_time(function()
            simdjson.encode(large_array)
        end, iterations)

        local cjson_time = measure_time(function()
            cjson.encode(large_array)
        end, iterations)

        show_comparison("1000-element array", simdjson_time, cjson_time)
    end)

    it(string.format("Large Objects (%s iterations)", iterations), function()
        local large_array = {}
        for i = 1, 1000 do large_array["a" .. i] = i end
        large_array = { data = large_array }

        local simdjson_time = measure_time(function()
            simdjson.encode(large_array)
        end, iterations)

        local cjson_time = measure_time(function()
            cjson.encode(large_array)
        end, iterations)

        show_comparison("1000-K/V pair object", simdjson_time, cjson_time)
    end)

    it(string.format("Complex Realistic Data (%s iterations)", iterations),
        function()
            local realistic_data = {
                users = {
                    {
                        id = 1,
                        name = "Alice Smith",
                        email = "alice@example.com",
                        active = true,
                        score = 95.5
                    }, {
                    id = 2,
                    name = "Bob Jones",
                    email = "bob@example.com",
                    active = false,
                    score = 87.3
                }, {
                    id = 3,
                    name = "Carol White",
                    email = "carol@example.com",
                    active = true,
                    score = 92.1
                }
                },
                metadata = { version = "1.0", timestamp = 1704197400, count = 3 },
                settings = { theme = "dark", language = "en", notifications = true }
            }

            local simdjson_time = measure_time(function()
                simdjson.encode(realistic_data)
            end, iterations)

            local cjson_time = measure_time(function()
                cjson.encode(realistic_data)
            end, iterations)
            show_comparison("Realistic complex data", simdjson_time, cjson_time)
        end)

    it(string.format("Simple JSON Parsing (%s iterations)", iterations),
        function()
            local simple_json = '{"name":"test","value":42,"active":true}'

            local simdjson_time = measure_time(function()
                simdjson.parse(simple_json)
            end, iterations)

            local cjson_time = measure_time(function()
                cjson.decode(simple_json)
            end, 10000)

            show_comparison("Simple parsing", simdjson_time, cjson_time)
        end)

    it(string.format("Array Parsing (%s iterations)", iterations), function()
        local array_json =
        '{"numbers":[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20]}'

        local simdjson_time = measure_time(function()
            simdjson.parse(array_json)
        end, iterations)

        local cjson_time = measure_time(function()
            cjson.decode(array_json)
        end, iterations)

        show_comparison("Array parsing", simdjson_time, cjson_time)
    end)

    it(string.format("Nested Object Parsing (%s iterations)", iterations),
        function()
            local nested_json =
            '{"level1":{"level2":{"level3":{"level4":{"value":"deep"}}}}}'

            local simdjson_time = measure_time(function()
                simdjson.parse(nested_json)
            end, iterations)

            local cjson_time = measure_time(function()
                cjson.decode(nested_json)
            end, iterations)
            show_comparison("Nested parsing", simdjson_time, cjson_time)
        end)

    it(string.format("Large JSON Parsing (%s iterations)", iterations),
        function()
            local large_json_data = {}
            for i = 1, 100 do large_json_data["key" .. i] = "value" .. i end
            local large_json = cjson.encode({ data = large_json_data })

            local simdjson_time = measure_time(function()
                simdjson.parse(large_json)
            end, iterations)

            local cjson_time = measure_time(function()
                cjson.decode(large_json)
            end, iterations)
            show_comparison("Large object parsing", simdjson_time, cjson_time)
        end)

    it(string.format("Round-trip: Encode + Parse (%s iterations)", iterations),
        function()
            local roundtrip_data = {
                id = 123,
                name = "Test User",
                values = { 1, 2, 3, 4, 5 },
                metadata = { active = true, score = 95.5 }
            }

            local simdjson_time = measure_time(function()
                local encoded = simdjson.encode(roundtrip_data)
                simdjson.parse(encoded)
            end, iterations)

            local cjson_time = measure_time(function()
                local encoded = cjson.encode(roundtrip_data)
                cjson.decode(encoded)
            end, iterations)

            show_comparison("Round-trip", simdjson_time, cjson_time)
        end)

    it(string.format("Special Characters (%s iterations)", iterations),
        function()
            local special_chars_data = {
                escaped = 'test"with"quotes\nand\nnewlines\ttabs',
                unicode = "Hello 世界 🌍"
            }

            local simdjson_time = measure_time(function()
                simdjson.encode(special_chars_data)
            end, iterations)

            local cjson_time = measure_time(function()
                cjson.encode(special_chars_data)
            end, iterations)
            show_comparison("Special characters", simdjson_time, cjson_time)
        end)

    it(string.format("Boolean Arrays (%s iterations)", iterations), function()
        local bool_data = {
            flags = { true, false, true, false, true, false, true, false }
        }

        local simdjson_time = measure_time(function()
            simdjson.encode(bool_data)
        end, iterations)

        local cjson_time = measure_time(function()
            cjson.encode(bool_data)
        end, iterations)

        show_comparison("Boolean arrays", simdjson_time, cjson_time)
    end)

    it(string.format("Large Boolean Array (%s iterations)", iterations), function()
        local bool_data = {}
        local choices = { true, false }
        for i = 1, 1000 do bool_data[i] = choices[math.random(2)] end


        local simdjson_time = measure_time(function()
            simdjson.encode(bool_data)
        end, iterations)

        local cjson_time = measure_time(function()
            cjson.encode(bool_data)
        end, iterations)

        show_comparison("Large boolean arrays", simdjson_time, cjson_time)
    end)

    -- Print summary after all tests
    after_each(function() end) -- No-op to ensure we're in test context

    teardown(function()
        print("\n" .. string.rep("=", 80))
        print("Using SIMD implementation: " .. simdjson.activeImplementation())
        print(string.format("Performance Summary: %d total tests", total_tests))
        print(string.rep("=", 80))
        print(string.format("  simdjson wins: %d (%.1f%%)", simdjson_wins,
            (simdjson_wins / total_tests) * 100))
        print(string.format("  cjson wins:    %d (%.1f%%)", cjson_wins,
            (cjson_wins / total_tests) * 100))
        print(string.rep("=", 80))
    end)
end)
