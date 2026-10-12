--- Diagnostics: error capture, /hark selftest, /hark trace, and the reader
-- (Tests/readselftest.lua) run on a SavedVariables file written from the mock.
local T = ...
local Sim = T.helpers

local here = (arg and arg[0] and arg[0]:match("^(.*)/[^/]*$")) or "Tests"

local function db(c) return c:Global("HarkDB") end

local function findError(c, pattern)
	for _, e in ipairs(db(c).errors or {}) do
		if tostring(e.message):find(pattern) then return e end
	end
end

local function rows(c, kind)
	local out = {}
	for _, r in ipairs(db(c).trace or {}) do
		if kind == nil or r.k == kind then out[#out + 1] = r end
	end
	return out
end

local function byId(st, id)
	local out = {}
	for _, r in ipairs(st.results) do if r.id == id then out[#out + 1] = r end end
	return out
end

-- Serialise a table as a SavedVariables file (the client writes the same shape).
local function serialise(v, indent)
	indent = indent or ""
	local kind = type(v)
	if kind == "string" then return string.format("%q", v) end
	if kind == "number" or kind == "boolean" then return tostring(v) end
	if kind ~= "table" then return "nil" end
	local parts = { "{" }
	for k, val in pairs(v) do
		local key = type(k) == "number" and ("[" .. k .. "]") or ("[" .. string.format("%q", tostring(k)) .. "]")
		parts[#parts + 1] = indent .. "\t" .. key .. " = " .. serialise(val, indent .. "\t") .. ","
	end
	parts[#parts + 1] = indent .. "}"
	return table.concat(parts, "\n")
end

local function runReader(dbTable)
	local file = os.tmpname()
	local f = assert(io.open(file, "w"))
	f:write("HarkDB = ", serialise(dbTable), "\n")
	f:close()
	local lua = (arg and arg[-1]) or "lua5.1"
	local p = io.popen(lua .. " " .. here .. "/readselftest.lua " .. file .. " 2>&1; echo \"exit=$?\"")
	local text = p:read("*a")
	p:close()
	os.remove(file)
	return text
end

T.test("errors: a throwing timer callback lands in HarkDB.errors and still reaches the client", function(t)
	t:allowLuaErrors()
	local w = t:world()
	local c = w:AddPlayer({ name = "Alice" })
	w:Advance(2)
	local function boom() error("boom from a timer") end
	c.env.C_Timer.After(1, boom)
	w:Advance(2)
	local e = findError(c, "boom from a timer")
	t:require(e ~= nil, "error recorded in HarkDB.errors")
	t:ok(type(e.time) == "number" and e.time > 0, "has a time")
	t:eq(e.where, "error handler", "recorded by the wrapped handler")
	t:ok(type(e.stack) == "string" and #e.stack <= c:NS()._diag.CONFIG.STACK_MAX + 3, "stack kept and truncated")
	local forwarded = false
	for _, ce in ipairs(c.errors) do if ce.message:find("boom from a timer") then forwarded = true end end
	t:ok(forwarded, "original handler still saw the error")
	-- The same error again is one entry with a count.
	c.env.C_Timer.After(1, boom)
	w:Advance(2)
	t:eq(findError(c, "boom from a timer").count, 2, "repeat counted")
end)

T.test("errors: swallowed protected calls are recorded with the function name, return behaviour unchanged", function(t)
	local w = Sim.Scenario(t, { players = { { name = "Bob", x = 0, y = 0 }, { name = "Alice", x = 5, y = 0 } } })
	local bob = w:Get("Bob")
	t:require(w:Hears("Bob", "Alice") == 100, "baseline")
	local before = #bob.errors
	bob.api.C_VoiceChat.GetChannel = function() error("GetChannel exploded") end
	bob.api.C_Map.GetBestMapForUnit = function() error("map exploded") end
	bob:FireEvent("ZONE_CHANGED_NEW_AREA")
	w:Advance(3)
	local e = findError(bob, "GetChannel exploded")
	t:require(e ~= nil, "Voice Call error recorded")
	t:eq(e.where, "C_VoiceChat.GetChannel", "function name")
	local m = findError(bob, "map exploded")
	t:require(m ~= nil, "Positions Call error recorded")
	t:eq(m.where, "C_Map.GetBestMapForUnit", "function name")
	t:eq(#bob.errors, before, "still swallowed: no error reached the client")
	t:eq(bob:NS().Voice:GetState(), "active", "voice keeps running")
end)

T.test("errors: buffer keeps the newest 50", function(t)
	local w = t:world()
	local c = w:AddPlayer({ name = "Alice" })
	w:Advance(1)
	for i = 1, 60 do c:NS()._RecordError("test", "distinct error " .. i) end
	local list = db(c).errors
	t:eq(#list, 50, "capped")
	t:eq(list[#list].message, "distinct error 60", "newest kept")
	t:eq(list[1].message, "distinct error 11", "oldest dropped")
end)

T.test("selftest: runs on the mock and records every probe, without changing volumes", function(t)
	local w = Sim.Scenario(t, { players = { { name = "Bob", x = 0, y = 0 }, { name = "Alice", x = 20, y = 0 },
		{ name = "Carol", x = 10, y = 0 } } })
	local bob, alice, carol = w:Get("Bob"), w:Get("Alice"), w:Get("Carol")
	-- Alice is grouped with Bob; Carol is a stranger on a nameplate (slot 3: slots have gaps).
	w:SetGroup("Bob", 1)
	w:SetGroup("Alice", 1)
	bob.units.target = { client = alice }
	bob.units.nameplate3 = { client = carol }
	w:ShowCreature("Bob", "nameplate1", 301)
	w:ShowCreature("Bob", "nameplate2", 302)
	w:Advance(5)
	local heardBefore = w:Hears("Bob", "Alice")

	local out = bob:Slash("/hark selftest")
	t:ok(table.concat(out, "\n"):find("running"), "says it is running")
	w:Advance(8)
	local st = db(bob).selftest
	t:require(type(st) == "table" and st.complete == true, "selftest completed")
	t:eq(st.version, bob:NS().version, "version")
	t:ok(st.probes and st.probes > 50, "probe count recorded: " .. tostring(st.probes))
	local done = false
	for _, line in ipairs(bob.prints) do
		if line:find("Self%-test done") and line:find("Type /reload to save the results.", 1, true) then done = true end
	end
	t:ok(done, "summary line printed")

	-- a. APIs
	local api = {}
	for _, r in ipairs(byId(st, "api")) do api[r.call] = r.status end
	t:eq(api["C_VoiceChat.SetMemberVolume"], "present", "SetMemberVolume present")
	t:eq(api["UISpecialFrames"], "absent", "UISpecialFrames absent in the mock")
	t:eq(api["AddonCompartmentFrame"], "absent", "compartment absent in the mock")
	-- b. Positions
	t:eq(byId(st, "pos.player")[1].results.n, 4, "UnitPosition(player) four returns")
	local units = {}
	for _, u in ipairs(byId(st, "pos.unit")) do units[u.unit] = u end
	t:require(units.nameplate3 ~= nil, "nameplate3 probed despite the gap")
	t:eq(units.nameplate3.isPlayer, true, "stranger is a player")
	t:eq(units.nameplate3.inGroup, false, "stranger not in group")
	t:eq(units.nameplate3.positionVerdict, "NIL", "mock: no position for non-group players")
	t:eq(units.target.inGroup, true, "target is grouped")
	t:eq(units.target.positionVerdict, "READABLE", "group member position readable")
	t:eq(units.nameplate1 and units.nameplate1.isPlayer, false, "creature nameplate probed")
	-- c. Voice
	local members = byId(st, "voice.member")
	t:eq(#members, 3, "three voice members (including self)")
	local am
	for _, m in ipairs(members) do if m.guid == alice.guid then am = m end end
	t:require(am ~= nil, "Alice found by GUID")
	t:eq(am.infoName, "Alice", "GetPlayerInfoByGUID name")
	t:eq(am.volVoice, heardBefore, "volume via voice id")
	t:eq(am.volGUID, heardBefore, "volume via GUID")
	t:eq(am.matchVoice, true, "write-back matched (voice id)")
	t:eq(am.matchGUID, true, "write-back matched (GUID)")
	t:eq(w:Hears("Bob", "Alice"), heardBefore, "volume unchanged by the self-test")
	-- d-f
	t:ok(#byId(st, "layer.get") == 1 and #byId(st, "layer.samples") == 1, "layer probes")
	t:eq(byId(st, "persist")[1].loadedFrom, "defaults", "persistence source")
	t:eq(byId(st, "settings")[1].registered, "settings", "options registered in Settings")
	-- g. messaging
	local send = byId(st, "msg.send")[1]
	t:eq(send.status, "sent", "position send happened")
	t:eq(send.lastSend and send.lastSend.GUILD and send.lastSend.GUILD.result, 0, "GUILD result code")
	-- h. client
	t:eq(byId(st, "client.locale")[1].results[1], "enUS", "locale")
	t:eq(byId(st, "client.build")[1].status, "absent", "GetBuildInfo absent in the mock")
	t:eq(byId(st, "client.nameplateShowFriends")[1].results[1], "0", "CVar read")

	-- Survives a /reload, and the reader turns it into a report.
	bob:Reload()
	w:Advance(1)
	t:require(type(db(bob).selftest) == "table", "selftest saved across /reload")
	local report = runReader(db(bob))
	t:ok(report:find("exit=0", 1, true), "reader exits cleanly:\n" .. report:sub(-400))
	t:ok(report:find("UnitPosition for non-group player: NIL", 1, true), "non-group verdict in report")
	t:ok(report:find("UnitPosition for group member: READABLE", 1, true), "group verdict in report")
	t:ok(report:find("GUID location WORKS", 1, true), "GUID location verdict in report")
	t:ok(report:find("Volume scale: 0-100", 1, true), "scale verdict in report")
end)

T.test("selftest: reader handles a file where the selftest never ran", function(t)
	local w = t:world()
	local c = w:AddPlayer({ name = "Alice" })
	w:Advance(1)
	local report = runReader(db(c))
	t:ok(report:find("exit=0", 1, true), "reader exits cleanly:\n" .. report:sub(-400))
	t:ok(report:find("never run", 1, true), "says the selftest never ran")
end)

T.test("trace: records volume passes, messages and events, and respects the cap", function(t)
	local w = Sim.Scenario(t, { players = { { name = "Bob", x = 0, y = 0 }, { name = "Alice", x = 5, y = 0 } } })
	local bob, alice = w:Get("Bob"), w:Get("Alice")
	t:eq(#rows(bob), 0, "off by default")
	bob:Slash("/hark trace on")
	w:MoveTo("Alice", 30, 0, 7)
	w:ShowCreature("Bob", "nameplate1", 301)
	w:ShowCreature("Bob", "nameplate2", 302)
	w:Advance(10)
	local short = alice.guid:match("%-(%x+)$")
	local vol = rows(bob, "vol")
	t:ok(#vol >= 5, "volume rows: " .. #vol)
	local last = vol[#vol]
	t:eq(last.g, short, "short GUID")
	t:eq(last.r, "near", "reason")
	t:eq(last.d, 30, "distance rounded")
	t:eq(last.a, w:Hears("Bob", "Alice"), "applied volume")
	t:eq(last.s, "message", "source")
	t:ok(type(last.t) == "number", "time")
	t:ok(#rows(bob, "rx") >= 2, "received messages")
	t:ok(rows(bob, "rx")[1].g == short and rows(bob, "rx")[1].seq ~= nil, "rx row fields")
	t:ok(#rows(bob, "tx") >= 1 and rows(bob, "tx")[1].res == 0, "sent messages with result code")
	local who = rows(bob, "who")[1]
	t:ok(who and who.g == short and tostring(who.n):find("^Alice") ~= nil, "who row names the member")
	t:ok(#rows(bob, "layer") >= 1, "layer change row")
	bob:Slash("/hark leave")
	w:Advance(1)
	local voice = rows(bob, "voice")
	t:ok(#voice >= 1 and voice[#voice].st == "idle", "voice state row")

	-- Cap: 600 newest.
	local Hark = bob:NS()
	for i = 1, 700 do Hark._Trace({ k = "test", i = i }) end
	local all = rows(bob)
	t:eq(#all, 600, "capped at 600")
	t:eq(all[#all].i, 700, "newest kept")

	bob:Slash("/hark trace off")
	local n = #rows(bob)
	Hark._Trace({ k = "test" })
	t:eq(#rows(bob), n, "nothing recorded while off")
	bob:Slash("/hark trace clear")
	t:eq(#rows(bob), 0, "cleared")
	bob:Slash("/hark trace on")
	bob:Reload()
	w:Advance(1)
	t:eq(bob:NS()._diag.traceOn, false, "trace is off after /reload")
end)
