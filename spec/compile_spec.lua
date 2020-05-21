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
	"twitter_api_compact_response.json",
	"twitter_api_response.json",
	"twitterescaped.json",
	"twitter.json",
	"twitter_timeline.json",
	"update-center.json",
	"small/adversarial.json",
	"small/demo.json",
	"small/flatadversarial.json",
	"small/smalldemo.json",
	"small/truenull.json"
}

describe("Make sure everything compiled correctly", function()
	for _, file in ipairs(files) do
		it("should parse the file: " .. file, function()
			local fileContents = loadFile("jsonexamples/" .. file)
			assert.are.same(cjson.decode(fileContents), simdjson.parse(fileContents))
		end)
	end
end)
