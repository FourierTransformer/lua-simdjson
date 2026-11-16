local simdjson = require("simdjson")
local tested = require("tested")

t = tested.new()

local original_max_depth
local original_buffer_size
local is_windows = package.config:sub(1, 1) == "\\"

local function make_temp_path()
    local name = os.tmpname()
    if is_windows and not name:match("^[A-Za-z]:") then
        local dir = os.getenv("TEMP") or os.getenv("TMP") or "."
        if name:sub(1, 1) ~= "\\" and name:sub(1, 1) ~= "/" then
            name = "\\" .. name
        end
        name = dir .. name
    end
    return name
end

t:before_each(function()
    if simdjson.getMaxDecodeDepth then
        original_max_depth = simdjson.getMaxDecodeDepth()
    end
    if simdjson.getDecodeBufferSize then
        original_buffer_size = simdjson.getDecodeBufferSize()
    end
end)

t:after_each(function()
    if simdjson.setMaxDecodeDepth and original_max_depth then
        simdjson.setMaxDecodeDepth(original_max_depth)
    end
    if simdjson.setDecodeBufferSize and original_buffer_size then
        simdjson.setDecodeBufferSize(original_buffer_size)
    end
end)

t:test("supports global decode settings and defaults", function()
    tested.assert({expected = 1024, actual = simdjson.getMaxDecodeDepth()})
    tested.assert({expected = 16 * 1024, actual = simdjson.getDecodeBufferSize()})

    simdjson.setMaxDecodeDepth(64)
    simdjson.setDecodeBufferSize(32 * 1024)
    tested.assert({expected = 64, actual = simdjson.getMaxDecodeDepth()})
    tested.assert({expected = 32 * 1024, actual = simdjson.getDecodeBufferSize()})
end)

t:test("rejects invalid decode options and overflowing configuration values", function()
    local opened = simdjson.open('{"a": 1}')

    local ok_depth_zero, err_depth_zero = pcall(simdjson.setMaxDecodeDepth, 0)
    tested.assert({expected = false, actual = ok_depth_zero})
    tested.assert({
        expected = true,
        actual = tostring(err_depth_zero):find(
            "maximum decode depth must be an integer between 1 and 1024",
            1,
            true
        ) ~= nil,
        message = tostring(err_depth_zero),
    })
    tested.assert_throws_exception({actual = function() simdjson.setMaxDecodeDepth(1025) end})
    tested.assert_throws_exception({actual = function() simdjson.setMaxDecodeDepth(1.5) end})
    tested.assert_throws_exception({actual = function() simdjson.setMaxDecodeDepth("10") end})
    tested.assert_throws_exception({actual = function() simdjson.setMaxDecodeDepth(4294967297) end})
    tested.assert_throws_exception({actual = function() simdjson.setMaxDecodeDepth(0/0) end})

    local ok_buf_zero, err_buf_zero = pcall(simdjson.setDecodeBufferSize, 0)
    tested.assert({expected = false, actual = ok_buf_zero})
    tested.assert({
        expected = true,
        actual = tostring(err_buf_zero):find(
            "decode buffer size must be an integer between 1 and 67108864",
            1,
            true
        ) ~= nil,
        message = tostring(err_buf_zero),
    })
    tested.assert_throws_exception({actual = function() simdjson.setDecodeBufferSize(64 * 1024 * 1024 + 1) end})
    tested.assert_throws_exception({actual = function() simdjson.setDecodeBufferSize(1.5) end})
    tested.assert_throws_exception({actual = function() simdjson.setDecodeBufferSize("1024") end})

    for _, fn in ipairs({
        function() simdjson.parse("{}", {maxDepth = 0}) end,
        function() simdjson.parse("{}", {maxDepth = 1025}) end,
        function() simdjson.parse("{}", {maxDepth = 1.5}) end,
        function() simdjson.parse("{}", {maxDepth = "10"}) end,
        function() simdjson.parse("{}", {maxDepth = 0/0}) end,
        function() simdjson.parse("{}", {bufferSize = 0}) end,
        function() simdjson.parse("{}", {bufferSize = 64 * 1024 * 1024 + 1}) end,
        function() simdjson.parse("{}", {bufferSize = 1.5}) end,
        function() simdjson.parse("{}", {max_depth = 10}) end,
        function() simdjson.parse("{}", 123) end,
        function() simdjson.parse("{}", {}, {}) end,
        function() simdjson.parseFile("jsonexamples/small/demo.json", {max_depth = 10}) end,
        function() simdjson.parseFile("jsonexamples/small/demo.json", {maxDepth = 0}) end,
        function() opened:atPointer("/a", {max_depth = 10}) end,
        function() opened:atPointer("/a", {maxDepth = 0}) end,
    }) do
        tested.assert_throws_exception({actual = fn})
    end
end)

t:test("rejects trailing content after root objects, arrays, and scalars", function()
    for _, input in ipairs({
        '{"role":"user"}{"role":"admin"}',
        '{"a":1} trailing }',
        '[1,2][3,4]',
        '[1,2] trailing ]',
        'true false',
        '123 456',
        '"a" "b"',
        'null 1',
    }) do
        local ok, err = pcall(simdjson.parse, input)
        tested.assert({expected = false, actual = ok, message = input})
        tested.assert({
            expected = true,
            actual = tostring(err):find("TRAILING_CONTENT", 1, true) ~= nil,
            message = input .. ": " .. tostring(err),
        })
    end

    for _, path in ipairs({
        "jsonexamples/invalid/bool_trailing.json",
    }) do
        local ok, err = pcall(simdjson.parseFile, path)
        tested.assert({expected = false, actual = ok, message = path})
        tested.assert({
            expected = true,
            actual = tostring(err):find("TRAILING_CONTENT", 1, true) ~= nil,
            message = path .. ": " .. tostring(err),
        })
    end
end)

t:test("rejects file paths with embedded NUL bytes", function()
    local ok, err = pcall(simdjson.parseFile, "jsonexamples/small/demo.json\0extra")
    tested.assert({expected = false, actual = ok})
    tested.assert_truthy({actual = err})
end)

t:test("enforces maxDepth in parse and parseFile and recovers cleanly", function()
    local deep_obj = string.rep('{"a":', 5) .. '1' .. string.rep('}', 5)
    local deep_arr = string.rep('[', 5) .. '1' .. string.rep(']', 5)

    local tmp_obj = make_temp_path()
    local tmp_arr = make_temp_path()
    local tmp_invalid = make_temp_path()

    local function write_file(path, content)
        local f = assert(io.open(path, "wb"))
        f:write(content)
        f:close()
    end

    local function read_file(path)
        local f = assert(io.open(path, "rb"))
        local content = f:read("*all")
        f:close()
        return content
    end

    local ok_run, run_err = pcall(function()
        write_file(tmp_obj, deep_obj)
        write_file(tmp_arr, deep_arr)

        for _ = 1, 50 do
            for _, call in ipairs({
                function() return simdjson.parse(deep_obj, {maxDepth = 4}) end,
                function() return simdjson.parse(deep_arr, {maxDepth = 4}) end,
                function() return simdjson.parseFile(tmp_obj, {maxDepth = 4}) end,
                function() return simdjson.parseFile(tmp_arr, {maxDepth = 4}) end,
            }) do
                local n_ret = select("#", pcall(call))
                tested.assert({expected = 2, actual = n_ret})
                local ok, err = pcall(call)
                tested.assert({expected = false, actual = ok})
                tested.assert({
                    expected = true,
                    actual = tostring(err):find("maximum nesting depth exceeded (limit: 4)", 1, true) ~= nil,
                    message = tostring(err),
                })
            end
        end

        simdjson.setMaxDecodeDepth(4)
        for _ = 1, 50 do
            for _, call in ipairs({
                function() return simdjson.parse(deep_obj) end,
                function() return simdjson.parse(deep_arr) end,
                function() return simdjson.parseFile(tmp_obj) end,
                function() return simdjson.parseFile(tmp_arr) end,
            }) do
                local ok, err = pcall(call)
                tested.assert({expected = false, actual = ok})
                tested.assert({
                    expected = true,
                    actual = tostring(err):find("maximum nesting depth exceeded (limit: 4)", 1, true) ~= nil,
                    message = tostring(err),
                })
            end
        end
        simdjson.setMaxDecodeDepth(1024)

        tested.assert({expected = {valid = true}, actual = simdjson.parse('{"valid":true}')})

        local invalid_payloads = {
            read_file("jsonexamples/invalid/nil_token.json"),
            read_file("jsonexamples/invalid/unknown_type.json"),
            "NaN",
            '{"a": NaN}',
            "[NaN]",
            '{"a":"unterminated}',
            "\255",
            "",
        }

        for _, payload in ipairs(invalid_payloads) do
            write_file(tmp_invalid, payload)
            for _ = 1, 50 do
                local n_parse = select("#", pcall(simdjson.parse, payload))
                tested.assert({expected = 2, actual = n_parse})
                local ok_p, err_p = pcall(simdjson.parse, payload)
                tested.assert({expected = false, actual = ok_p})
                tested.assert_truthy({actual = err_p})

                local n_file = select("#", pcall(simdjson.parseFile, tmp_invalid))
                tested.assert({expected = 2, actual = n_file})
                local ok_f, err_f = pcall(simdjson.parseFile, tmp_invalid)
                tested.assert({expected = false, actual = ok_f})
                tested.assert_truthy({actual = err_f})
            end
            tested.assert({expected = {valid = true}, actual = simdjson.parse('{"valid":true}')})
            tested.assert({expected = 800, actual = simdjson.parseFile("jsonexamples/small/demo.json").Image.Width})
        end
    end)

    os.remove(tmp_obj)
    os.remove(tmp_arr)
    os.remove(tmp_invalid)
    if not ok_run then
        error(run_err, 0)
    end
end)

t:test("decodes nesting up to the depth limit (1024) without exhausting the Lua stack", function()
    local limit = simdjson.getMaxDecodeDepth()
    tested.assert({expected = 1024, actual = limit})

    for _, d in ipairs({10, 25, 64, 128, 512, limit}) do
        local obj_json = string.rep('{"a":', d) .. '1' .. string.rep('}', d)
        local obj = simdjson.parse(obj_json)
        local cur_obj = obj
        for _ = 1, d do
            cur_obj = cur_obj.a
        end
        tested.assert({expected = 1, actual = cur_obj, message = "object depth " .. d})

        local arr_json = string.rep('[', d) .. '1' .. string.rep(']', d)
        local arr = simdjson.parse(arr_json)
        local cur_arr = arr
        for _ = 1, d do
            cur_arr = cur_arr[1]
        end
        tested.assert({expected = 1, actual = cur_arr, message = "array depth " .. d})
    end

    local too_deep_obj = string.rep('{"a":', limit + 1) .. '1' .. string.rep('}', limit + 1)
    local ok_obj, err_obj = pcall(simdjson.parse, too_deep_obj)
    tested.assert({expected = false, actual = ok_obj})
    tested.assert({
        expected = true,
        actual = tostring(err_obj):find("maximum nesting depth exceeded (limit: 1024)", 1, true) ~= nil,
        message = tostring(err_obj),
    })

    local too_deep_arr = string.rep('[', limit + 1) .. '1' .. string.rep(']', limit + 1)
    local ok_arr, err_arr = pcall(simdjson.parse, too_deep_arr)
    tested.assert({expected = false, actual = ok_arr})
    tested.assert({
        expected = true,
        actual = tostring(err_arr):find("maximum nesting depth exceeded (limit: 1024)", 1, true) ~= nil,
        message = tostring(err_arr),
    })
end)

local function get_rss_kb()
    if is_windows or os.getenv("ASAN_OPTIONS") then
        return nil
    end

    local status_file = io.open("/proc/self/status", "r")
    if status_file then
        local content = status_file:read("*all")
        status_file:close()
        local vm_rss = content:match("VmRSS:%s*(%d+)%s*kB")
        if vm_rss then
            return tonumber(vm_rss)
        end
    end

    local statm_file = io.open("/proc/self/statm", "r")
    if statm_file then
        local content = statm_file:read("*all")
        statm_file:close()
        local resident_pages = content:match("^%d+%s+(%d+)")
        if resident_pages then
            return tonumber(resident_pages) * 4
        end
    end

    local pipe = io.popen('sh -c "ps -o rss= -p $PPID"')
    if pipe then
        local output = pipe:read("*all")
        pipe:close()
        local rss = tonumber(output)
        if rss then
            return rss
        end
    end

    error("unable to determine process RSS")
end

t:test("shrinks oversized decode buffers back to bufferSize after large valid or invalid inputs", function()
    local payload_size = 4 * 1024 * 1024
    local big_valid = '{"data":"' .. string.rep("x", payload_size) .. '"}'
    local big_invalid = '{"bad": nil, "data":"' .. string.rep("x", payload_size) .. '"}'
    local tmp_valid = make_temp_path()
    local tmp_invalid = make_temp_path()

    local ok_run, run_err = pcall(function()
        local f_valid = assert(io.open(tmp_valid, "wb"))
        f_valid:write(big_valid)
        f_valid:close()

        local f_invalid = assert(io.open(tmp_invalid, "wb"))
        f_invalid:write(big_invalid)
        f_invalid:close()

        -- Verify retained vs released native buffer capacities directly
        local retained_parsed = simdjson.parse(big_valid, {bufferSize = 5 * 1024 * 1024})
        tested.assert({expected = payload_size, actual = #retained_parsed.data})
        retained_parsed = nil
        local caps_retained = simdjson._debugDecodeCapacities()
        tested.assert({expected = true, actual = caps_retained.parseBuffer >= 5 * 1024 * 1024})
        tested.assert({expected = 0, actual = caps_retained.fileBuffer})
        tested.assert({expected = true, actual = caps_retained.parserCapacity >= 5 * 1024 * 1024})

        for _ = 1, 3 do
            local warmup_parsed = simdjson.parse(big_valid, {bufferSize = 16384})
            assert(#warmup_parsed.data == payload_size)
            warmup_parsed = nil
            local caps_after_parse = simdjson._debugDecodeCapacities()
            tested.assert({expected = 0, actual = caps_after_parse.parseBuffer})
            tested.assert({expected = 0, actual = caps_after_parse.fileBuffer})
            tested.assert({expected = 0, actual = caps_after_parse.parserCapacity})
            collectgarbage("collect")

            local warmup_file = simdjson.parseFile(tmp_valid, {bufferSize = 16384})
            assert(#warmup_file.data == payload_size)
            warmup_file = nil
            local caps_after_file = simdjson._debugDecodeCapacities()
            tested.assert({expected = 0, actual = caps_after_file.parseBuffer})
            tested.assert({expected = 0, actual = caps_after_file.fileBuffer})
            tested.assert({expected = 0, actual = caps_after_file.parserCapacity})
            collectgarbage("collect")

            pcall(simdjson.parse, big_invalid, {bufferSize = 16384})
            local caps_after_bad_parse = simdjson._debugDecodeCapacities()
            tested.assert({expected = 0, actual = caps_after_bad_parse.parseBuffer})
            tested.assert({expected = 0, actual = caps_after_bad_parse.fileBuffer})
            tested.assert({expected = 0, actual = caps_after_bad_parse.parserCapacity})

            pcall(simdjson.parseFile, tmp_invalid, {bufferSize = 16384})
            local caps_after_bad_file = simdjson._debugDecodeCapacities()
            tested.assert({expected = 0, actual = caps_after_bad_file.parseBuffer})
            tested.assert({expected = 0, actual = caps_after_bad_file.fileBuffer})
            tested.assert({expected = 0, actual = caps_after_bad_file.parserCapacity})
        end
        for _ = 1, 20 do
            simdjson.parse('{"warmup":1}', {bufferSize = 16384})
        end
        local caps_primed = simdjson._debugDecodeCapacities()
        tested.assert({expected = 16384 + 64, actual = caps_primed.parseBuffer})
        tested.assert({expected = 0, actual = caps_primed.fileBuffer})
        tested.assert({expected = 16384, actual = caps_primed.parserCapacity})
        collectgarbage("collect")
        collectgarbage("collect")
        local rss_before = get_rss_kb()

        local unexpected_errors = 0
        for _ = 1, 20 do
            local decoded = simdjson.parse(big_valid, {bufferSize = 16384})
            if #decoded.data ~= payload_size then
                unexpected_errors = unexpected_errors + 1
            end
            decoded = nil
            collectgarbage("collect")

            local ok_parse, err_parse = pcall(simdjson.parse, big_invalid, {bufferSize = 16384})
            if ok_parse or not err_parse then
                unexpected_errors = unexpected_errors + 1
            end

            local decoded_file = simdjson.parseFile(tmp_valid, {bufferSize = 16384})
            if #decoded_file.data ~= payload_size then
                unexpected_errors = unexpected_errors + 1
            end
            decoded_file = nil
            collectgarbage("collect")

            local ok_file, err_file = pcall(simdjson.parseFile, tmp_invalid, {bufferSize = 16384})
            if ok_file or not err_file then
                unexpected_errors = unexpected_errors + 1
            end
        end

        for _ = 1, 20 do
            local small = simdjson.parse('{"small":true}', {bufferSize = 16384})
            if small.small ~= true then
                unexpected_errors = unexpected_errors + 1
            end
        end

        collectgarbage("collect")
        collectgarbage("collect")
        local rss_after = get_rss_kb()
        tested.assert({expected = 0, actual = unexpected_errors})
        if rss_before and rss_after then
            local rss_delta = rss_after - rss_before
            tested.assert({
                expected = true,
                actual = rss_delta < 2048,
                debug_var = string.format(
                    "expected oversized decode buffers to shrink (< 2048 KiB delta), got %d KiB (before=%d, after=%d)",
                    rss_delta,
                    rss_before,
                    rss_after
                ),
            })
        end
    end)

    os.remove(tmp_valid)
    os.remove(tmp_invalid)
    if not ok_run then
        error(run_err, 0)
    end
end)

t:test("does not leak memory across repeated parse and parseFile errors", function()
    local padding = string.rep("x", 10 * 1024)
    local invalid_syntax = '{"bad": nil, "pad":"' .. padding .. '"}'
    local invalid_unknown = '{"bad": NaN, "pad":"' .. padding .. '"}'
    local tmp_syntax = make_temp_path()
    local tmp_unknown = make_temp_path()

    local ok_run, run_err = pcall(function()
        local f_syntax = assert(io.open(tmp_syntax, "wb"))
        f_syntax:write(invalid_syntax)
        f_syntax:close()

        local f_unknown = assert(io.open(tmp_unknown, "wb"))
        f_unknown:write(invalid_unknown)
        f_unknown:close()

        for _ = 1, 100 do
            pcall(simdjson.parse, invalid_syntax)
            pcall(simdjson.parse, invalid_unknown)
            pcall(simdjson.parseFile, tmp_syntax)
            pcall(simdjson.parseFile, tmp_unknown)
        end
        collectgarbage("collect")
        collectgarbage("collect")
        local rss_before = get_rss_kb()

        local unexpected_successes = 0
        for i = 1, 15000 do
            if pcall(simdjson.parse, invalid_syntax) then
                unexpected_successes = unexpected_successes + 1
            end
            if pcall(simdjson.parse, invalid_unknown) then
                unexpected_successes = unexpected_successes + 1
            end
            if i % 500 == 0 then
                collectgarbage("collect")
            end
        end

        for i = 1, 2500 do
            if pcall(simdjson.parseFile, tmp_syntax) then
                unexpected_successes = unexpected_successes + 1
            end
            if pcall(simdjson.parseFile, tmp_unknown) then
                unexpected_successes = unexpected_successes + 1
            end
            if i % 500 == 0 then
                collectgarbage("collect")
            end
        end

        collectgarbage("collect")
        collectgarbage("collect")
        local rss_after = get_rss_kb()
        tested.assert({expected = 0, actual = unexpected_successes})
        if rss_before and rss_after then
            local rss_delta = rss_after - rss_before
            tested.assert({
                expected = true,
                actual = rss_delta < 2048,
                debug_var = string.format(
                    "expected error-path RSS growth < 2048 KiB, got %d KiB (before=%d, after=%d)",
                    rss_delta,
                    rss_before,
                    rss_after
                ),
            })
        end
    end)

    os.remove(tmp_syntax)
    os.remove(tmp_unknown)
    if not ok_run then
        error(run_err, 0)
    end
end)

t:test("supports empty root JSON pointer on scalars, objects, and arrays", function()
    local impl = simdjson.activeImplementation()
    tested.assert({expected = "string", actual = type(impl)})
    tested.assert({
        expected = true,
        actual = impl:match("^.+ %(.+%)$") ~= nil,
        message = "unexpected activeImplementation format: " .. tostring(impl),
    })

    local num_doc = simdjson.open("42")
    tested.assert({expected = 42, actual = num_doc:atPointer("")})
    tested.assert({expected = 42, actual = num_doc:atPointer("")})

    tested.assert({expected = "hello", actual = simdjson.open('"hello"'):atPointer("")})
    tested.assert({expected = true, actual = simdjson.open("true"):atPointer("")})
    tested.assert({expected = simdjson.null, actual = simdjson.open("null"):atPointer("")})
    tested.assert({expected = 1, actual = simdjson.open('{"a":1}'):atPointer("").a})
    tested.assert({expected = {1, 2, 3}, actual = simdjson.open("[1,2,3]"):atPointer("")})

    -- Empty root pointer must reject trailing content after root containers/scalars
    for _, payload in ipairs({
        '{"role":"user"}{"role":"admin"}',
        '[1,2][3,4]',
        '42 99',
        'true false',
    }) do
        local doc = simdjson.open(payload)
        local ok, err = pcall(function() return doc:atPointer("") end)
        tested.assert({expected = false, actual = ok, message = "expected trailing content error for: " .. payload})
        tested.assert_truthy({actual = err})
    end

    -- Calling atPointer("") again after a fatal traversal error must raise a Lua error cleanly
    for _, payload in ipairs({
        '{"a":1',
        '{"a":nil}',
    }) do
        local doc = simdjson.open(payload)
        local ok1, err1 = pcall(function() return doc:atPointer("") end)
        tested.assert({expected = false, actual = ok1, message = "first atPointer('') should fail for: " .. payload})
        tested.assert_truthy({actual = err1})

        local ok2, err2 = pcall(function() return doc:atPointer("") end)
        tested.assert({expected = false, actual = ok2, message = "second atPointer('') should fail for: " .. payload})
        tested.assert_truthy({actual = err2})
    end

    -- Raising maxDepth after a smaller shrink/re-prime must succeed on deep documents
    simdjson.setDecodeBufferSize(256)
    simdjson.setMaxDecodeDepth(4)
    local large_shallow = '{"pad":"' .. string.rep("x", 4096) .. '"}'
    tested.assert({expected = 4096, actual = #simdjson.parse(large_shallow).pad})
    local nested_12 = string.rep("[", 12) .. "1" .. string.rep("]", 12)
    local decoded_12 = simdjson.parse(nested_12, {maxDepth = 16})
    tested.assert({expected = "table", actual = type(decoded_12)})
end)

t:test("rejects invalid open, openFile, and atPointer inputs and enforces maxDepth on atPointer", function()
    local decoded = simdjson.openFile("jsonexamples/small/demo.json")
    local deep_doc = simdjson.open('{"deep":{"a":{"b":{"c":1}}}}')

    for _, call in ipairs({
        function() return simdjson.open('{"a":"unterminated}') end,
        function() return simdjson.openFile("jsonexamples/invalid/does_not_exist.json") end,
        function() return simdjson.openFile("jsonexamples/small/demo.json\0extra") end,
        function() return decoded:atPointer("/missing") end,
        function() return decoded:atPointer("/Image/IDs/99") end,
        function() return decoded:atPointer("no_leading_slash") end,
        function() return decoded:atPointer("/Image/Width/sub") end,
    }) do
        local n_ret = select("#", pcall(call))
        tested.assert({expected = 2, actual = n_ret})
        local ok, err = pcall(call)
        tested.assert({expected = false, actual = ok})
        tested.assert_truthy({actual = err})
    end

    local ok_deep, err_deep = pcall(function()
        return deep_doc:atPointer("/deep", {maxDepth = 2})
    end)
    tested.assert({expected = false, actual = ok_deep})
    tested.assert({
        expected = true,
        actual = tostring(err_deep):find("maximum nesting depth exceeded (limit: 2)", 1, true) ~= nil,
        message = tostring(err_deep),
    })

    tested.assert({
        expected = {a = {b = {c = 1}}},
        actual = deep_doc:atPointer("/deep", {maxDepth = 3}),
    })
end)

t:test("does not leak memory across repeated open, openFile, and atPointer errors", function()
    local padding = string.rep("x", 10 * 1024)
    local invalid_open = '{"pad":"' .. padding .. '", "bad": "unterminated}'
    local decoded = simdjson.openFile("jsonexamples/small/demo.json")
    local deep_doc = simdjson.open('{"deep":{"a":{"b":{"c":1}}}}')

    for _ = 1, 100 do
        pcall(simdjson.open, invalid_open)
        pcall(simdjson.openFile, "jsonexamples/invalid/does_not_exist.json")
        pcall(simdjson.openFile, "jsonexamples/small/demo.json\0extra")
        pcall(decoded.atPointer, decoded, "/missing")
        pcall(decoded.atPointer, decoded, "/Image/IDs/99")
        pcall(decoded.atPointer, decoded, "no_leading_slash")
        pcall(decoded.atPointer, decoded, "/Image/Width/sub")
        pcall(deep_doc.atPointer, deep_doc, "/deep", {maxDepth = 2})
        simdjson.activeImplementation()
    end
    collectgarbage("collect")
    collectgarbage("collect")
    local rss_before = get_rss_kb()

    local unexpected_successes = 0
    for i = 1, 5000 do
        if pcall(simdjson.open, invalid_open) then
            unexpected_successes = unexpected_successes + 1
        end
        if pcall(simdjson.openFile, "jsonexamples/invalid/does_not_exist.json") then
            unexpected_successes = unexpected_successes + 1
        end
        if pcall(decoded.atPointer, decoded, "/missing") then
            unexpected_successes = unexpected_successes + 1
        end
        if pcall(decoded.atPointer, decoded, "/Image/IDs/99") then
            unexpected_successes = unexpected_successes + 1
        end
        if pcall(decoded.atPointer, decoded, "no_leading_slash") then
            unexpected_successes = unexpected_successes + 1
        end
        if pcall(deep_doc.atPointer, deep_doc, "/deep", {maxDepth = 2}) then
            unexpected_successes = unexpected_successes + 1
        end
        simdjson.activeImplementation()
        if i % 500 == 0 then
            collectgarbage("collect")
        end
    end

    collectgarbage("collect")
    collectgarbage("collect")
    local rss_after = get_rss_kb()
    tested.assert({expected = 0, actual = unexpected_successes})
    if rss_before and rss_after then
        local rss_delta = rss_after - rss_before
        tested.assert({
            expected = true,
            actual = rss_delta < 2048,
            debug_var = string.format(
                "expected open/openFile/atPointer error-path RSS growth < 2048 KiB, got %d KiB (before=%d, after=%d)",
                rss_delta,
                rss_before,
                rss_after
            ),
        })
    end
end)

t:test("isolates active decoder state from reentrant parse and parseFile calls in __gc finalizers", function()
    local newproxy_fn = rawget(_G, "newproxy")
    local function make_gc_canary(callback)
        if newproxy_fn then
            local proxy = newproxy_fn(true)
            getmetatable(proxy).__gc = callback
            return proxy
        end
        return setmetatable({}, {__gc = callback})
    end

    local items = {}
    for i = 1, 400 do
        items[i] = string.format('{"idx":%d,"label":"item_%04d_%s"}', i, i, string.rep("z", 64))
    end
    local outer_json = "[" .. table.concat(items, ",") .. "]"
    local tmp_outer = make_temp_path()

    local ok_run, run_err = pcall(function()
        local f = assert(io.open(tmp_outer, "wb"))
        f:write(outer_json)
        f:close()

        local reentrant_calls = 0
        local mid_decode_file_calls = 0
        local mid_decode_str_calls = 0
        local active_mode = nil
        local function gc_callback()
            reentrant_calls = reentrant_calls + 1
            if simdjson._debugDecodeCapacities().inUse then
                if active_mode == "file" then
                    mid_decode_file_calls = mid_decode_file_calls + 1
                elseif active_mode == "str" then
                    mid_decode_str_calls = mid_decode_str_calls + 1
                end
            end
            local ok_missing = pcall(simdjson.parseFile, "jsonexamples/invalid/does_not_exist.json")
            assert(not ok_missing)
            local small_file = simdjson.parseFile("jsonexamples/small/demo.json", {bufferSize = 64})
            assert(small_file.Image.Width == 800)
            local ok_bad = pcall(simdjson.parse, '{"bad": nil}', {bufferSize = 64})
            assert(not ok_bad)
            local small_str = simdjson.parse('{"nested":42}', {bufferSize = 64})
            assert(small_str.nested == 42)
        end

        local ok_inc, prev_gc_mode = pcall(collectgarbage, "incremental")
        local ok_pause, old_pause = pcall(collectgarbage, "setpause", 50)
        local ok_step, old_step = pcall(collectgarbage, "setstepmul", 1000)
        local ok_param_pause, old_param_pause = pcall(collectgarbage, "param", "pause", 50)
        local ok_param_step, old_param_step = pcall(collectgarbage, "param", "stepmul", 1000)
        collectgarbage("collect")

        local decode_opts = {bufferSize = 1024}
        local unexpected_errors = 0
        local file_iters = 0
        while mid_decode_file_calls == 0 and file_iters < 50 do
            file_iters = file_iters + 1
            collectgarbage("stop")
            local batch = {}
            for i = 1, 200 do
                batch[i] = make_gc_canary(gc_callback)
            end
            batch = nil
            collectgarbage("restart")
            active_mode = "file"
            local parsed_file = simdjson.parseFile(tmp_outer, decode_opts)
            active_mode = nil
            if #parsed_file ~= 400 or parsed_file[1].idx ~= 1 or parsed_file[400].idx ~= 400 then
                unexpected_errors = unexpected_errors + 1
            end
        end

        collectgarbage("collect")

        local str_iters = 0
        while mid_decode_str_calls == 0 and str_iters < 50 do
            str_iters = str_iters + 1
            collectgarbage("stop")
            local batch = {}
            for i = 1, 200 do
                batch[i] = make_gc_canary(gc_callback)
            end
            batch = nil
            collectgarbage("restart")
            active_mode = "str"
            local parsed_str = simdjson.parse(outer_json, decode_opts)
            active_mode = nil
            if #parsed_str ~= 400 or parsed_str[1].idx ~= 1 or parsed_str[400].idx ~= 400 then
                unexpected_errors = unexpected_errors + 1
            end
        end

        do
            local co_abort_active = false
            local co = coroutine.create(function()
                collectgarbage("stop")
                local batch = {}
                for i = 1, 200 do
                    batch[i] = make_gc_canary(function()
                        if co_abort_active then
                            co_abort_active = false
                            error("abort from finalizer")
                        end
                    end)
                end
                batch = nil
                co_abort_active = true
                collectgarbage("restart")
                return simdjson.parse(outer_json, decode_opts)
            end)
            coroutine.resume(co)
            co_abort_active = false
            local caps_before_reclaim = simdjson._debugDecodeCapacities()
            if caps_before_reclaim.inUse ~= false then
                unexpected_errors = unexpected_errors + 1
            end
            local reclaimed = simdjson.parse('{"reclaimed":true}', {bufferSize = 2048})
            local caps_live_err_co = simdjson._debugDecodeCapacities()
            if reclaimed.reclaimed ~= true or caps_live_err_co.inUse ~= false or caps_live_err_co.parseBuffer ~= 2048 + 64 then
                unexpected_errors = unexpected_errors + 1
            end
            co = nil
            collectgarbage("collect")
            collectgarbage("collect")
            local after_co = simdjson.parse(outer_json, decode_opts)
            if #after_co ~= 400 or after_co[1].idx ~= 1 or after_co[400].idx ~= 400 then
                unexpected_errors = unexpected_errors + 1
            end
            local caps_after_co = simdjson._debugDecodeCapacities()
            if caps_after_co.inUse ~= false or caps_after_co.parseBuffer ~= 0 then
                unexpected_errors = unexpected_errors + 1
            end
        end

        if ok_pause and type(old_pause) == "number" and old_pause > 0 then
            pcall(collectgarbage, "setpause", old_pause)
        end
        if ok_step and type(old_step) == "number" and old_step > 0 then
            pcall(collectgarbage, "setstepmul", old_step)
        end
        if ok_param_pause and type(old_param_pause) == "number" and old_param_pause > 0 then
            pcall(collectgarbage, "param", "pause", old_param_pause)
        end
        if ok_param_step and type(old_param_step) == "number" and old_param_step > 0 then
            pcall(collectgarbage, "param", "stepmul", old_param_step)
        end
        if ok_inc and prev_gc_mode == "generational" then
            pcall(collectgarbage, "generational")
        end
        collectgarbage("collect")
        tested.assert({expected = 0, actual = unexpected_errors})
        tested.assert({expected = true, actual = reentrant_calls > 0})
        tested.assert({expected = true, actual = mid_decode_file_calls > 0})
        tested.assert({expected = true, actual = mid_decode_str_calls > 0})
    end)

    os.remove(tmp_outer)
    if not ok_run then
        error(run_err, 0)
    end
end)

t:test("decodes big integers beyond 64-bit range as floats and preserves 53-bit integer precision", function()
    local pos_big = simdjson.parse("18446744073709551616")
    tested.assert({expected = 18446744073709551616.0, actual = pos_big})
    local neg_big = simdjson.parse("-9223372036854775809")
    tested.assert({expected = -9223372036854775809.0, actual = neg_big})

    local nested_big = simdjson.parse(
        '{"pos":18446744073709551616,"neg":-9223372036854775809,"arr":[10000000000000000000000000,1.5]}'
    )
    tested.assert({expected = 18446744073709551616.0, actual = nested_big.pos})
    tested.assert({expected = -9223372036854775809.0, actual = nested_big.neg})
    tested.assert({expected = 1e25, actual = nested_big.arr[1]})
    tested.assert({expected = 1.5, actual = nested_big.arr[2]})

    local opened_big = simdjson.open('{"big":18446744073709551616}')
    tested.assert({expected = 18446744073709551616.0, actual = opened_big:atPointer("/big")})
    tested.assert({expected = 18446744073709551616.0, actual = opened_big:atPointer("").big})

    if math.type then
        tested.assert({expected = "float", actual = math.type(pos_big)})
        tested.assert({expected = "float", actual = math.type(neg_big)})
        tested.assert({expected = "float", actual = math.type(nested_big.arr[1])})
    end

    -- Exact 53-bit integer boundaries across all Lua versions (5.1-5.5 and LuaJIT)
    local exact_53 = simdjson.parse(
        '{"p53":9007199254740992,"p53m1":9007199254740991,"n53":-9007199254740992,"n53p1":-9007199254740991,"i33":5000000000}'
    )
    tested.assert({expected = 9007199254740992, actual = exact_53.p53})
    tested.assert({expected = 9007199254740991, actual = exact_53.p53m1})
    tested.assert({expected = -9007199254740992, actual = exact_53.n53})
    tested.assert({expected = -9007199254740991, actual = exact_53.n53p1})
    tested.assert({expected = 5000000000, actual = exact_53.i33})

    -- Overflowing >308-digit integer must still fail as NUMBER_ERROR
    local huge_overflow = string.rep("9", 400)
    tested.assert_throws_exception({actual = function() simdjson.parse(huge_overflow) end})
    tested.assert_throws_exception({actual = function() simdjson.parse("[" .. huge_overflow .. "]") end})
end)

t:test("guards ParsedObject:atPointer against reentrant traversal in __gc finalizers", function()
    local newproxy_fn = rawget(_G, "newproxy")
    local function make_gc_canary(callback)
        if newproxy_fn then
            local proxy = newproxy_fn(true)
            getmetatable(proxy).__gc = callback
            return proxy
        end
        return setmetatable({}, {__gc = callback})
    end

    local items = {}
    for i = 1, 400 do
        items[i] = string.format('{"idx":%d,"label":"item_%04d_%s"}', i, i, string.rep("z", 64))
    end
    local valid_json = "[" .. table.concat(items, ",") .. "]"
    local partially_invalid_json =
        '[{"items":[' .. table.concat(items, ",") .. ']},{"x":[1},{"after":"crash"}]'

    local doc = simdjson.open(valid_json)
    local bad_doc = simdjson.open(partially_invalid_json)
    local other_doc = simdjson.openFile("jsonexamples/small/demo.json")

    local ok_inc, prev_gc_mode = pcall(collectgarbage, "incremental")
    local ok_pause, old_pause = pcall(collectgarbage, "setpause", 50)
    local ok_step, old_step = pcall(collectgarbage, "setstepmul", 150)
    local ok_param_pause, old_param_pause = pcall(collectgarbage, "param", "pause", 50)
    local ok_param_step, old_param_step = pcall(collectgarbage, "param", "stepmul", 150)
    collectgarbage("collect")

    local ok_run, run_err = pcall(function()
        local active_target = nil
        local active_ptr = nil
        local reentrant_rejected = 0
        local bad_reentrant_rejected = 0
        local unexpected_errors = 0

        local function gc_callback()
            if active_target then
                local ok_re, err_re = pcall(active_target.atPointer, active_target, active_ptr)
                if not ok_re and tostring(err_re):find("ParsedObject is already being traversed", 1, true) then
                    if active_target == doc then
                        reentrant_rejected = reentrant_rejected + 1
                    elseif active_target == bad_doc then
                        bad_reentrant_rejected = bad_reentrant_rejected + 1
                    end
                end
            end
            local width = other_doc:atPointer("/Image/Width")
            if width ~= 800 then
                unexpected_errors = unexpected_errors + 1
            end
        end

        local valid_iters = 0
        while reentrant_rejected == 0 and valid_iters < 50 do
            valid_iters = valid_iters + 1
            collectgarbage("stop")
            local batch = {}
            for i = 1, 200 do
                batch[i] = make_gc_canary(gc_callback)
            end
            batch = nil
            active_target = doc
            active_ptr = "/0/idx"
            collectgarbage("restart")
            local ok_outer, res_outer = pcall(doc.atPointer, doc, "")
            active_target = nil
            if not ok_outer or #res_outer ~= 400 or res_outer[1].idx ~= 1 or res_outer[400].idx ~= 400 then
                unexpected_errors = unexpected_errors + 1
            end
        end

        collectgarbage("collect")

        local bad_iters = 0
        while bad_reentrant_rejected == 0 and bad_iters < 50 do
            bad_iters = bad_iters + 1
            collectgarbage("stop")
            local batch = {}
            for i = 1, 200 do
                batch[i] = make_gc_canary(gc_callback)
            end
            batch = nil
            active_target = bad_doc
            active_ptr = "/1/x"
            collectgarbage("restart")
            local ok_outer, res_outer = pcall(bad_doc.atPointer, bad_doc, "/0/items")
            active_target = nil
            if not ok_outer or #res_outer ~= 400 or res_outer[1].idx ~= 1 or res_outer[400].idx ~= 400 then
                unexpected_errors = unexpected_errors + 1
            end
        end

        do
            local co_abort_active = false
            local co = coroutine.create(function()
                collectgarbage("stop")
                local batch = {}
                for i = 1, 200 do
                    batch[i] = make_gc_canary(function()
                        if co_abort_active then
                            co_abort_active = false
                            error("abort atPointer from finalizer")
                        end
                    end)
                end
                batch = nil
                co_abort_active = true
                collectgarbage("restart")
                return doc:atPointer("")
            end)
            coroutine.resume(co)
            co_abort_active = false
            local after_co = doc:atPointer("/0/idx")
            if after_co ~= 1 then
                unexpected_errors = unexpected_errors + 1
            end
            co = nil
            collectgarbage("collect")
            collectgarbage("collect")
            local full_after_co = doc:atPointer("")
            if #full_after_co ~= 400 or full_after_co[400].idx ~= 400 then
                unexpected_errors = unexpected_errors + 1
            end
        end

        tested.assert({expected = 0, actual = unexpected_errors})
        tested.assert({expected = true, actual = reentrant_rejected > 0})
        tested.assert({expected = true, actual = bad_reentrant_rejected > 0})
    end)

    if ok_pause and type(old_pause) == "number" and old_pause > 0 then
        pcall(collectgarbage, "setpause", old_pause)
    end
    if ok_step and type(old_step) == "number" and old_step > 0 then
        pcall(collectgarbage, "setstepmul", old_step)
    end
    if ok_param_pause and type(old_param_pause) == "number" and old_param_pause > 0 then
        pcall(collectgarbage, "param", "pause", old_param_pause)
    end
    if ok_param_step and type(old_param_step) == "number" and old_param_step > 0 then
        pcall(collectgarbage, "param", "stepmul", old_param_step)
    end
    if ok_inc and prev_gc_mode == "generational" then
        pcall(collectgarbage, "generational")
    end
    collectgarbage("collect")

    if not ok_run then
        error(run_err, 0)
    end
end)

t:test("repairs partially initialized internal metatables and safely formats activeImplementation", function()
    local reg = debug.getregistry()
    local fallback_meta = reg["simdjson.fallback_decode_state"]
    local lease_meta = reg["simdjson.decode_vm_lease"]
    tested.assert({expected = "table", actual = type(fallback_meta)})
    tested.assert({expected = "table", actual = type(lease_meta)})

    local lease_key = nil
    local saved_lease_ud = nil
    for k, v in pairs(reg) do
        if type(k) == "userdata" and type(v) == "userdata" and debug.getmetatable(v) == lease_meta then
            lease_key = k
            saved_lease_ud = v
            break
        end
    end
    tested.assert_truthy({actual = lease_key})

    -- Simulate LUA_ERRMEM interrupting ensure_decode_vm_lease after luaL_newmetatable
    -- registered the tables in LUA_REGISTRYINDEX but before __gc was assigned
    fallback_meta.__gc = nil
    lease_meta.__gc = nil
    reg[lease_key] = nil

    local ok_parse, parsed = pcall(simdjson.parse, '{"ok":true}')
    if not reg[lease_key] and saved_lease_ud then
        reg[lease_key] = saved_lease_ud
    end
    tested.assert({expected = true, actual = ok_parse})
    tested.assert({expected = true, actual = parsed.ok})
    tested.assert({expected = "function", actual = type(reg["simdjson.fallback_decode_state"].__gc)})
    tested.assert({expected = "function", actual = type(reg["simdjson.decode_vm_lease"].__gc)})

    local impl = simdjson.activeImplementation()
    tested.assert({expected = "string", actual = type(impl)})
    tested.assert({expected = true, actual = impl:match("^.+ %(.+%)$") ~= nil})
end)

t:test("prevents finalized VM lease from re-binding TLS decoder state during LIFO shutdown", function()
    local reg = debug.getregistry()
    local lease_meta = reg["simdjson.decode_vm_lease"]
    tested.assert({expected = "table", actual = type(lease_meta)})

    -- Reset TLS buffer to 0 then prime it to 1024 + 64
    local big = '{"pad":"' .. string.rep("a", 4096) .. '"}'
    simdjson.parse(big, {bufferSize = 1024})
    simdjson.parse('{"prime":true}', {bufferSize = 1024})
    tested.assert({expected = 1024 + 64, actual = simdjson._debugDecodeCapacities().parseBuffer})

    local lease_key = nil
    local lease_ud = nil
    for k, v in pairs(reg) do
        if type(k) == "userdata" and type(v) == "userdata" and debug.getmetatable(v) == lease_meta then
            lease_key = k
            lease_ud = v
            break
        end
    end
    tested.assert_truthy({actual = lease_ud})

    -- Simulate lua_close LIFO finalization where decode_vm_lease_gc runs before
    -- an earlier-created object's __gc finalizer calls simdjson.parse
    lease_meta.__gc(lease_ud)

    local post_gc = simdjson.parse('{"post_gc":true}', {bufferSize = 2048})
    tested.assert({expected = true, actual = post_gc.post_gc})
    -- Because lease_ud was finalized, the decode must use the fallback state
    -- and leave tls_decode_state untouched (parseBuffer still 1024 + 64)
    local caps_after_finalized = simdjson._debugDecodeCapacities()
    tested.assert({expected = false, actual = caps_after_finalized.inUse})
    tested.assert({expected = 1024 + 64, actual = caps_after_finalized.parseBuffer})

    -- Re-initialize a fresh VM lease and verify normal TLS leasing resumes
    reg[lease_key] = nil
    local resumed = simdjson.parse('{"resumed":true}', {bufferSize = 2048})
    tested.assert({expected = true, actual = resumed.resumed})
    tested.assert({expected = 2048 + 64, actual = simdjson._debugDecodeCapacities().parseBuffer})
end)

return t
