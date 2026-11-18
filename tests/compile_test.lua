local simdjson = require("simdjson")
local cjson = require("cjson")

local tested = require("tested")
t = tested.new()

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

t:test("Make sure it parses strings correctly", function()
    for _, file in ipairs(files) do
        local fileContents = loadFile("jsonexamples/" .. file)
        local cjsonDecodedValues = cjson.decode(fileContents)
        tested.assert({
            given = file,
            should = "parse the file as a string",
            expected = cjsonDecodedValues,
            actual = simdjson.parse(fileContents)
        })
    end
end)

t:test("Make sure it parses files correctly", function()
    for _, file in ipairs(files) do
        local fileContents = loadFile("jsonexamples/" .. file)
        local cjsonDecodedValues = cjson.decode(fileContents)
        tested.assert({
            given = file,
            should = "parse the file with the filename",
            expected = cjsonDecodedValues,
            actual = simdjson.parseFile("jsonexamples/" .. file)
        })
    end
end)

t:test("Make sure json pointer works with a string", function()
    local fileContents = loadFile("jsonexamples/small/demo.json")
    local decodedFile = simdjson.open(fileContents)
    tested.assert({expected=800, actual=decodedFile:atPointer("/Image/Width")})
    tested.assert({expected=600, actual=decodedFile:atPointer("/Image/Height")})
    tested.assert({expected=125, actual=decodedFile:atPointer("/Image/Thumbnail/Height")})
    tested.assert({expected=943, actual=decodedFile:atPointer("/Image/IDs/1")})
end)

t:test("Make sure json pointer works with openfile", function()
    local decodedFile = simdjson.openFile("jsonexamples/small/demo.json")
    tested.assert({expected=800, actual=decodedFile:atPointer("/Image/Width")})
    tested.assert({expected=600, actual=decodedFile:atPointer("/Image/Height")})
    tested.assert({expected=125, actual=decodedFile:atPointer("/Image/Thumbnail/Height")})
    tested.assert({expected=943, actual=decodedFile:atPointer("/Image/IDs/1")})
end)

local major, minor = _VERSION:match('([%d]+)%.(%d+)')
t:test("Make sure ints and floats parse correctly", {run_when=tonumber(major) >= 5 and tonumber(minor) >= 3}, function()
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

    tested.assert({expected="float", actual=math.type(numberCheck["float"])})
    tested.assert({expected="integer", actual=math.type(numberCheck["max_signed_integer"])})
    tested.assert({expected="integer", actual=math.type(numberCheck["min_signed_integer"])})
    tested.assert({expected="float", actual=math.type(numberCheck["one_above_max_signed_integer"])})
    tested.assert({expected="integer", actual=math.type(numberCheck["min_unsigned_integer"])})
    tested.assert({expected="float", actual=math.type(numberCheck["max_unsigned_integer"])})
end)

local invalid_files = {
    "bool_trailing.json",
    "nully_trailing.json",
    "nil_token.json",
    "nil_token_scalar.json",
    "nully_token.json",
    "nully_token_scalar.json",
    "unknown_type.json"
}

t:test("Make sure invalid files are not accepted", function()
    for _, file in ipairs(invalid_files) do
        local fileContents = loadFile("jsonexamples/invalid/" .. file)
        local cjsonValue, cjsonError = pcall(function() cjson.decode(fileContents) end)
        local simdjsonValue, simdjsonError = pcall(function() simdjson.parse(fileContents) end)
        tested.assert({actual=cjsonValue, expected=false, given=file, should="pcall should return false"})
        tested.assert({actual=simdjsonValue, expected=false, given=file, should="pcall should return false"})

        -- probably should check for specific errors being returned...
        tested.assert_truthy({actual=cjsonError, given=file, should="return an error message on failure"})
        tested.assert_truthy({actual=simdjsonError, given=file, should="return an error message on failure"})

        local simdjsonFileValue, simdjsonFileError = pcall(function() simdjson.parseFile("jsonexamples/invalid/" .. file) end)
        tested.assert({actual=simdjsonFileValue, expected=false, given=file, should="parseFile pcall should return false"})
        tested.assert_truthy({actual=simdjsonFileError, given=file, should="parseFile should return an error message on failure"})
    end
end)

return t