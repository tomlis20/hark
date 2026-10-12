--- Minimal test runner. See Tests/README.md.
local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/?.lua;" .. package.path

local verbose, filter = false, nil
for _, a in ipairs(arg) do
	if a == "-v" or a == "--verbose" then verbose = true else filter = a end
end

local World = require("harness.world")
local addonDir = os.getenv("HARK_ADDON_DIR") or (here .. "/..")

local function listSpecs()
	local files = {}
	local p = io.popen('ls "' .. here .. '/spec"')
	for line in p:lines() do
		if line:match("_spec%.lua$") then files[#files + 1] = line end
	end
	p:close()
	table.sort(files)
	return files
end

local function fmt(v)
	if type(v) == "string" then return string.format("%q", v) end
	if type(v) == "number" and v ~= math.floor(v) then return string.format("%.2f", v) end
	return tostring(v)
end

local T = { tests = {} }
local currentFile
function T.test(name, fn) T.tests[#T.tests + 1] = { name = name, fn = fn, file = currentFile } end

local Ctx = {}
Ctx.__index = Ctx
local SKIP = {}
local ABORT = {}

function Ctx:fail(msg) self.failures[#self.failures + 1] = msg end
function Ctx:ok(cond, msg) if not cond then self:fail(msg or "expected a true value") end return cond end
function Ctx:eq(actual, expected, msg)
	if actual ~= expected then self:fail(string.format("%s: expected %s, got %s", msg or "value", fmt(expected), fmt(actual))) return false end
	return true
end
function Ctx:near(actual, expected, tol, msg)
	if type(actual) ~= "number" or math.abs(actual - expected) > tol then
		self:fail(string.format("%s: expected %s +/- %s, got %s", msg or "value", fmt(expected), fmt(tol), fmt(actual))) return false
	end
	return true
end
function Ctx:between(actual, lo, hi, msg)
	if type(actual) ~= "number" or actual < lo or actual > hi then
		self:fail(string.format("%s: expected within [%s, %s], got %s", msg or "value", fmt(lo), fmt(hi), fmt(actual))) return false
	end
	return true
end
--- Hard assertion: stop the test here if it fails.
function Ctx:require(cond, msg) if not cond then self:fail(msg or "requirement failed"); error(ABORT) end return cond end
function Ctx:skip(reason) self.skipped = reason; error(SKIP) end
function Ctx:note(msg) self.notes[#self.notes + 1] = msg end
function Ctx:allowLuaErrors() self.luaErrorsAllowed = true end
function Ctx:world(opts)
	opts = opts or {}
	opts.addonDir = opts.addonDir or addonDir
	if verbose then opts.echo = true end
	local w = World.new(opts)
	self.worlds[#self.worlds + 1] = w
	return w
end

T.helpers = require("harness.sim")

local specs = listSpecs()
for _, f in ipairs(specs) do
	currentFile = f
	local chunk, err = loadfile(here .. "/spec/" .. f)
	if not chunk then
		T.test("(load " .. f .. ")", function(t) t:fail(err) end)
	else
		local ok, e = pcall(chunk, T)
		if not ok then T.test("(load " .. f .. ")", function(t) t:fail(tostring(e)) end) end
	end
end

local passed, failed, skipped = 0, 0, 0
local lastFile
local useColour = os.getenv("NO_COLOR") == nil and os.getenv("TERM") ~= "dumb"
local function c(code, s) return useColour and ("\27[" .. code .. "m" .. s .. "\27[0m") or s end

for _, test in ipairs(T.tests) do
	if not filter or test.name:find(filter, 1, true) or test.file:find(filter, 1, true) then
		if test.file ~= lastFile then
			print(c("1", test.file))
			lastFile = test.file
		end
		local ctx = setmetatable({ failures = {}, notes = {}, worlds = {} }, Ctx)
		local ok, err = xpcall(function() test.fn(ctx) end, function(e)
			if e == SKIP or e == ABORT then return e end
			return tostring(e) .. "\n" .. debug.traceback("", 2)
		end)
		if not ok and err ~= SKIP and err ~= ABORT then ctx:fail("test code error: " .. err) end
		if not ctx.luaErrorsAllowed then
			local seen = {}
			for _, w in ipairs(ctx.worlds) do
				for _, e in ipairs(w:AllErrors()) do
					local key = e.context .. e.message
					if not seen[key] then
						seen[key] = true
						ctx:fail(string.format("addon Lua error [%s, %s]: %s", e.client, e.context, e.message))
					end
				end
			end
		end
		if ctx.skipped and #ctx.failures == 0 then
			skipped = skipped + 1
			print("  " .. c("33", "SKIP") .. "  " .. test.name .. "  (" .. ctx.skipped .. ")")
		elseif #ctx.failures == 0 then
			passed = passed + 1
			print("  " .. c("32", "PASS") .. "  " .. test.name)
		else
			failed = failed + 1
			print("  " .. c("31", "FAIL") .. "  " .. test.name)
			for _, m in ipairs(ctx.failures) do print("        - " .. m:gsub("\n", "\n          ")) end
		end
		for _, n in ipairs(ctx.notes) do print("        note: " .. n) end
	end
end

print(string.format("\n%d passed, %d failed, %d skipped  (%s)", passed, failed, skipped, _VERSION .. (jit and (" / " .. jit.version) or "")))
os.exit(failed == 0 and 0 or 1)
