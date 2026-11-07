local simdjson = require("simdjson")
local tested = require("tested")

t = tested.new()

local function random_string()
    local bytes = {}
    for _ = 1, math.random(0, 32) do
        bytes[#bytes + 1] = string.char(math.random(0, 127))
    end
    return table.concat(bytes)
end

local function random_value(depth)
    local kind = math.random(1, depth > 0 and 6 or 4)
    if kind == 1 then
        return math.random(-1000000, 1000000) / math.random(1, 100)
    elseif kind == 2 then
        return random_string()
    elseif kind == 3 then
        return math.random(0, 1) == 1
    elseif kind == 4 then
        return simdjson.null
    elseif kind == 5 then
        local array = {}
        for i = 1, math.random(1, 8) do
            array[i] = random_value(depth - 1)
        end
        return array
    else
        local object = {}
        for _ = 1, math.random(1, 8) do
            object[random_string()] = random_value(depth - 1)
        end
        return object
    end
end

t:test("simdjson.encode randomized inputs", function()
    math.randomseed(109)
    for _ = 1, 1000 do
        local encoded = simdjson.encode(random_value(4))
        local ok, error_message = pcall(simdjson.parse, encoded)
        tested.assert({given="randomized input", should="pcall should return true", actual=ok, expected=true})
        tested.assert_truthy({given="randomized input", should="emit parseable JSON for supported acyclic values", actual=error_message ~= nil})
    end
end)

return t