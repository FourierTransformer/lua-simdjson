local simdjson = require("simdjson")
local cjson = require("cjson")

local function loadFile(textFile)
    local file = io.open(textFile, "r")
    if not file then error("File not found at " .. textFile) end
    local allLines = file:read("*all")
    file:close()
    return allLines
end


local files = {
    "apache_builds.json",
    "canada.json",
    "citm_catalog.json",
    "github_events.json",
    "google_maps_api_compact_response.json",
    "google_maps_api_response.json",
    "gsoc-2018.json",
    "instruments.json",
    "marine_ik.json",
    "mesh.json",
    "mesh.pretty.json",
    "numbers.json",
    "random.json",
    "repeat.json",
    "twitter_timeline.json",
    "update-center.json",
    "scalars/bool.json",
    "scalars/null.json",
    "scalars/number.json",
    "scalars/string.json",
    "small/adversarial.json",
    "small/demo.json",
    "small/flatadversarial.json",
    "small/smalldemo.json",
    "small/truenull.json"
}

describe("Make sure it parses strings correctly", function()
    for _, file in ipairs(files) do
        it("should parse the file: " .. file, function()
            local fileContents = loadFile("jsonexamples/" .. file)
            local cjsonDecodedValues = cjson.decode(fileContents)
            assert.are.same(cjsonDecodedValues, simdjson.parse(fileContents))
        end)
    end
end)

describe("Make sure it parses files correctly", function()
    for _, file in ipairs(files) do
        it("should parse the file: " .. file, function()
            local fileContents = loadFile("jsonexamples/" .. file)
            local cjsonDecodedValues = cjson.decode(fileContents)
            assert.are.same(cjsonDecodedValues, simdjson.parseFile("jsonexamples/" .. file))
        end)
    end
end)

describe("Make sure json pointer works with a string", function()
    it("should handle a string", function()
        local fileContents = loadFile("jsonexamples/small/demo.json")
        local decodedFile = simdjson.open(fileContents)
        assert.are.same(800, decodedFile:atPointer("/Image/Width"))
        assert.are.same(600, decodedFile:atPointer("/Image/Height"))
        assert.are.same(125, decodedFile:atPointer("/Image/Thumbnail/Height"))
        assert.are.same(943, decodedFile:atPointer("/Image/IDs/1"))
    end)
end)

describe("Make sure json pointer works with openfile", function()
    it("should handle opening a file", function()
        local decodedFile = simdjson.openFile("jsonexamples/small/demo.json")
        assert.are.same(800, decodedFile:atPointer("/Image/Width"))
        assert.are.same(600, decodedFile:atPointer("/Image/Height"))
        assert.are.same(125, decodedFile:atPointer("/Image/Thumbnail/Height"))
        assert.are.same(943, decodedFile:atPointer("/Image/IDs/1"))
    end)
end)

local major, minor = _VERSION:match('([%d]+)%.(%d+)')
if tonumber(major) >= 5 and tonumber(minor) >= 3 then
    describe("Make sure ints and floats parse correctly", function ()
        it("should handle decoding numbers appropriately", function()

            local numberCheck = simdjson.parse([[
{
    "float": 1.2,
    "min_signed_integer": -9223372036854775808,
    "max_signed_integer": 9223372036854775807,
    "one_above_max_signed_integer": 9223372036854775808,
    "min_unsigned_integer": 0,
    "max_unsigned_integer": 18446744073709551615
}
                ]])

            assert.are.same("float", math.type(numberCheck["float"]))
            assert.are.same("integer", math.type(numberCheck["max_signed_integer"]))
            assert.are.same("integer", math.type(numberCheck["min_signed_integer"]))
            assert.are.same("float", math.type(numberCheck["one_above_max_signed_integer"]))
            assert.are.same("integer", math.type(numberCheck["min_unsigned_integer"]))
            assert.are.same("float", math.type(numberCheck["max_unsigned_integer"]))

        end)
    end)
end
