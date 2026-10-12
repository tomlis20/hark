--- Loads an addon the way the client does.
--
-- Reads <Addon>.toc, then runs each listed .lua file in order inside the
-- client's sandboxed global environment, passing (addonName, privateTable)
-- as the file's varargs. Nothing about the addon's global names is assumed.
-- A file that fails to compile or errors while running is recorded as a Lua
-- error and loading continues with the next file, as in game.

local Loader = {}

function Loader.DeepCopy(v, seen)
	if type(v) ~= "table" then return v end
	seen = seen or {}
	if seen[v] then return seen[v] end
	local out = {}
	seen[v] = out
	for k, x in pairs(v) do out[Loader.DeepCopy(k, seen)] = Loader.DeepCopy(x, seen) end
	return out
end

local function readFile(path)
	local f = io.open(path, "rb")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end
Loader.ReadFile = readFile

function Loader.ReadToc(dir, name)
	local tocPath = dir .. "/" .. name .. ".toc"
	local text = readFile(tocPath)
	assert(text, "cannot read " .. tocPath)
	local toc = { name = name, dir = dir, path = tocPath, meta = {}, files = {}, savedVariables = {}, savedVariablesPerCharacter = {} }
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		line = line:gsub("\r$", "")
		local key, value = line:match("^##%s*([^:]+):%s*(.-)%s*$")
		if key then
			toc.meta[key] = value
		elseif line:match("^%s*#") or line:match("^%s*$") then
			-- comment / blank
		else
			local file = line:gsub("^%s+", ""):gsub("%s+$", ""):gsub("\\", "/")
			toc.files[#toc.files + 1] = file
		end
	end
	local function list(v, into)
		for item in (v or ""):gmatch("[^,%s]+") do into[#into + 1] = item end
	end
	list(toc.meta.SavedVariables, toc.savedVariables)
	list(toc.meta.SavedVariablesPerCharacter, toc.savedVariablesPerCharacter)
	for _, v in ipairs(toc.savedVariablesPerCharacter) do toc.savedVariables[#toc.savedVariables + 1] = v end
	return toc
end

--- Compile source text with env as its global table (Lua 5.1/LuaJIT and 5.2+).
function Loader.Compile(src, chunkname, env)
	if setfenv then
		local fn, err = loadstring(src, chunkname)
		if not fn then return nil, err end
		setfenv(fn, env)
		return fn
	end
	return load(src, chunkname, "t", env)
end

function Loader.LoadAddon(client, toc)
	client.ns = {}
	for _, var in ipairs(toc.savedVariables) do
		rawset(client.env, var, Loader.DeepCopy(client.saved[var]))
	end
	for _, file in ipairs(toc.files) do
		local path = toc.dir .. "/" .. file
		if file:match("%.xml$") then
			client.world:Warn("XML file in TOC not loaded by harness: " .. file)
		else
			local src = readFile(path)
			if not src then
				client.errors[#client.errors + 1] = { client = client.name, context = "load " .. file, message = "TOC lists missing file " .. file, time = client.world.clock.now }
			else
				local fn, err = Loader.Compile(src, "@" .. toc.name .. "/" .. file, client.env)
				if not fn then
					client.errors[#client.errors + 1] = { client = client.name, context = "compile " .. file, message = err, time = client.world.clock.now }
				else
					client:Call("load " .. file, fn, toc.name, client.ns)
				end
			end
		end
	end
end

return Loader
