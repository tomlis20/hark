--- The addon loads in a clean client, like a fresh install.
local T = ...
local Loader = require("harness.loader")

T.test("loads and logs in with no Lua errors", function(t)
	local w = t:world()
	local c = w:AddPlayer({ name = "Alice" })
	w:Advance(5)
	t:ok(c:NS() ~= nil, "addon namespace (global 'Hark' or private table) exists after load")
	t:ok(#c.prints > 0, "addon printed a login message")
end)

T.test("every file listed in the TOC exists", function(t)
	local w = t:world()
	for _, f in ipairs(w.addon.files) do
		t:ok(Loader.ReadFile(w.addon.dir .. "/" .. f) ~= nil, "TOC lists missing file " .. f)
	end
end)

T.test("TOC IconTexture points at a file that exists", function(t)
	local w = t:world()
	local icon = w.addon.meta.IconTexture
	if not icon then t:skip("no IconTexture") end
	local path = icon:gsub("\\", "/")
	if tonumber(path) then t:skip("file ID " .. path .. " (game-provided)") end
	local own = "^Interface/AddOns/" .. w.addon.name .. "/"
	if not path:lower():match(own:lower()) then
		-- Game-provided texture (e.g. Interface/Icons/...): cannot check on disk.
		t:ok(path:match("^Interface/") ~= nil, "IconTexture " .. icon .. " is neither the addon's own file nor a game texture path")
		t:ok(not path:lower():match("^interface/addons/"), "IconTexture points into another addon: " .. icon)
		t:note("game-provided texture, not checked on disk: " .. icon)
		return
	end
	local rel = path:sub(#("Interface/AddOns/" .. w.addon.name .. "/") + 1)
	local found = Loader.ReadFile(w.addon.dir .. "/" .. rel) or Loader.ReadFile(w.addon.dir .. "/" .. rel .. ".blp")
		or Loader.ReadFile(w.addon.dir .. "/" .. rel:gsub("%.%a+$", "") .. ".tga")
	t:ok(found ~= nil, "icon file " .. rel .. " not found (game shows a green/missing texture)")
end)

T.test("TOC AddonCompartmentFunc is a global function", function(t)
	local w = t:world()
	local c = w:AddPlayer({ name = "Alice" })
	local fname = w.addon.meta.AddonCompartmentFunc
	if not fname then t:skip("no AddonCompartmentFunc") end
	t:eq(type(c:Global(fname)), "function", "global " .. fname)
	if type(c:Global(fname)) == "function" then
		c:Call("compartment click", c:Global(fname), "Hark", "LeftButton")
	end
end)

T.test("defines no stray globals (single namespace)", function(t)
	local w = t:world()
	local c = w:AddPlayer({ name = "Alice" })
	local allowed = { Hark = true, Hark_OnAddonCompartmentClick = true }
	for _, v in ipairs(w.addon.savedVariables) do allowed[v] = true end
	local stray = {}
	for k in pairs(c.definedGlobals) do
		-- CONTRACT.md 1: named frames must be prefixed "Hark" (and listed there).
		if tostring(k):match("^Hark%u") and type(c:Global(k)) == "table" and c:Global(k)._type then
			t:note("named frame global: " .. tostring(k) .. " (must be listed in CONTRACT.md)")
		elseif not allowed[k] and not tostring(k):match("^SLASH_") and not tostring(k):match("^BINDING_") then
			stray[#stray + 1] = tostring(k)
		end
	end
	table.sort(stray)
	t:eq(#stray, 0, "stray globals: " .. table.concat(stray, ", "))
end)

T.test("calls no API the client lacks", function(t)
	-- Reads of undefined globals during a normal session. Some are legitimate
	-- feature probes (e.g. `if issecretvalue then`); those are listed here.
	local probes = { issecretvalue = true, issecrettable = true, canaccessvalue = true, canaccesstable = true,
		C_RestrictedActions = true, LibStub = true, C_AddOns = true }
	local w = t:world()
	for _, v in ipairs(w.addon.savedVariables) do probes[v] = true end -- nil on first login
	w:CreateCommunity({ members = { "Alice", "Bob" } })
	local a = w:AddPlayer({ name = "Alice", x = 0, y = 0 })
	local b = w:AddPlayer({ name = "Bob", x = 5, y = 0 })
	local Sim = T.helpers
	Sim.JoinVoice(w, "Alice"); Sim.JoinVoice(w, "Bob")
	w:MoveTo("Alice", 20, 0)
	w:Advance(30)
	for _, c in ipairs({ a, b }) do
		for _, cmd in ipairs({ "/hark status", "/hark layer", "/hark communities", "/hark off", "/hark on" }) do c:Slash(cmd) end
	end
	w:Advance(5)
	local missing = {}
	for _, c in ipairs({ a, b }) do
		for k in pairs(c.missingGlobals) do
			if not probes[k] then missing[k] = true end
		end
	end
	local list = {}
	for k in pairs(missing) do list[#list + 1] = k end
	table.sort(list)
	t:eq(#list, 0, "globals read but not provided by the client mock (real API missing, or mock gap): " .. table.concat(list, ", "))
end)

T.test("SavedVariables survive /reload", function(t)
	local w = t:world()
	local c = w:AddPlayer({ name = "Alice" })
	c:Slash("/hark setcommunity 999 2")
	c:Reload()
	w:Advance(1)
	local db = c:Global("HarkDB")
	t:require(type(db) == "table", "HarkDB is a table after reload")
	t:eq(tostring(db.communityId), "999", "communityId persisted")
end)

T.test("no per-frame OnUpdate work while idle (CONTRACT rule 4)", function(t)
	local w = t:world()
	local c = w:AddPlayer({ name = "Alice" })
	w:Advance(2)
	local calls = 0
	for _, f in ipairs(c.frames) do
		local h = f._scripts.OnUpdate
		if h then f._scripts.OnUpdate = function(...) calls = calls + 1; return h(...) end end
	end
	w:Advance(10)
	t:eq(calls, 0, "OnUpdate calls in 10 idle seconds (200 frames)")
end)
