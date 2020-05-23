local simdjson = require("simdjson")
local cjson = require("cjson")
local dkjson = require("dkjson")
local rapidjson = require("rapidjson")
local ftcsv = require("ftcsv")

local inspect = require("inspect")

-- load an entire file into memory
local function loadFile(textFile)
    local file = io.open(textFile, "r")
    if not file then error("ftcsv: File not found at " .. textFile) end
    local lines = file:read("*all")
    file:close()
    return lines
end

local csvfiles = {
	"twitter_api_response.json",
	"twitter_timeline.json",
	"numbers.json",
	"update-center.json",
	"mesh.json",
	"canada.json",
	"gsoc-2018.json",
}

local function set(t)
	local newSet = {}
	for _, v in ipairs(t) do
		newSet[v] = true
	end
	return newSet
end

local jsonchecker = {
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

local function sum(t)
	local totalTime = 0
	for _, time in ipairs(t) do
		totalTime = totalTime + time
	end
	return totalTime
end

local function average(t)
	return sum(t) / #t
end

local function timeIt(fn, contents)
	local times = {}
	local start, elapsed
	for i=1,100 do
		start = os.clock()
		fn(contents)
		elapsed = os.clock() - start 
		table.insert(times, elapsed)
	end
	
	return average(times)
end

local totalTimes = {
	simdjson = 0,
	cjson = 0,
	dkjson = 0,
	rapidjson = 0
}


local csvFileSet = set(csvfiles)
local outputCsv = {}
for i,filename in ipairs(jsonchecker) do
	local row = {}
	local testFile = "jsonexamples/" .. filename
	local json_contents = loadFile(testFile)
	local time

	print(testFile, "Bytes: " .. #json_contents)
	row["filename"] = filename

	time = timeIt(simdjson.parse, json_contents)
	print("simd", time)
	row["simdjson"] = time
	totalTimes["simdjson"] = totalTimes["simdjson"] + time

	time = timeIt(cjson.decode, json_contents)
	print("cjson", time)
	row["cjson"] = time
	totalTimes["cjson"] = totalTimes["cjson"] + time

	time = timeIt(dkjson.decode, json_contents)
	print("dkjson", time)
	row["dkjson"] = time
	totalTimes["dkjson"] = totalTimes["dkjson"] + time

	time = timeIt(rapidjson.decode, json_contents)
	print("rapidjson", time)
	row["rapidjson"] = time
	totalTimes["rapidjson"] = totalTimes["rapidjson"] + time

	print("")

	if csvFileSet[filename] then
		table.insert(outputCsv, row)
	end

end

local fileOutput = ftcsv.encode(outputCsv, ",")
local file = assert(io.open("lua_test.csv", "w"))
file:write(fileOutput)
file:close()

print("Totals:")
print(inspect(totalTimes))