--- Voice join observability: HarkDB.joinlog, the timeout diagnosis, id forms,
-- the login wait, /hark joindiag and the reader's verdict. Also the client's
-- 32-bit %d and the places Hark formats numbers that can exceed it.
local T = ...
local Sim = T.helpers

local here = (arg and arg[0] and arg[0]:match("^(.*)/[^/]*$")) or "Tests"
local CLUB = "23111161"

local function db(c) return c:Global("HarkDB") end

local function steps(c, name)
	local out = {}
	for _, e in ipairs(db(c).joinlog or {}) do
		if name == nil or e.step == name then out[#out + 1] = e end
	end
	return out
end

local function last(list) return list[#list] end

local function printed(c, pattern)
	for _, line in ipairs(c.prints) do
		if line:find(pattern) then return line end
	end
end

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

-- One player in the community, configured but not in voice yet. With
-- unconfigured = true Hark has no community yet, so it ignores voice events.
local function Solo(t, spec, unconfigured)
	local w = t:world()
	w:CreateCommunity({ clubId = CLUB, streamId = "1", members = { "Bob" } })
	spec = spec or {}
	spec.name = "Bob"
	local c = w:AddPlayer(spec)
	w:Advance(1)
	if not unconfigured then c:Slash("/hark setcommunity " .. CLUB) end
	return w, c
end

---------------------------------------------------------------------------
-- The client's %d
---------------------------------------------------------------------------

T.test("format: %d raises outside the signed 32-bit range, exactly like the client", function(t)
	local w = t:world()
	local c = w:AddPlayer({ name = "Alice" })
	w:Advance(1)
	local fmt = c.env.string.format
	t:eq(fmt("%d", 2147483647), "2147483647", "max int32 prints")
	t:eq(fmt("%d", -2147483648), "-2147483648", "min int32 prints")
	t:eq(fmt("%5.1f|%d|%%d|%s", 1.25, 7, "x"), "  1.2|7|%d|x", "other conversions and %% untouched")
	local ok, err = pcall(fmt, "%d", 2147483648)
	t:ok(not ok, "2^31 raises")
	t:eq(tostring(err):match("integer overflow attempting to store .*$"), "integer overflow attempting to store 2147483648", "message")
	ok = pcall(fmt, "a %s b %d", "x", -2147483649)
	t:ok(not ok, "below -2^31 raises, argument counting skips %s")
	ok = pcall(function() return ("%i"):format(4294967296) end)
	t:ok(not ok, "method syntax and %i raise too")
	t:eq(fmt("%.0f", 4294967296), "4294967296", "%.0f is the safe form")
end)

T.test("format: the settings backup Pack no longer trips it (checksum above 2^31)", function(t)
	local w = t:world()
	local c = w:AddPlayer({ name = "Alice" })
	w:Advance(1)
	local P = c:NS()._persist
	-- Adler-style checksum b * 65536 + a: find a real settings body whose b is past 32767.
	local body, payload, sum
	for pad = 1, 200 do
		body = P.Encode({ e = true, c = "23111161", u = { note = string.rep("x", pad), x = 123.5, y = -45 } })
		local ok, err = pcall(function() payload = P.Pack(body) end)
		t:require(ok, "Pack raised: " .. tostring(err))
		sum = tonumber(payload:match("^HK1:%d+:%d+:(%d+):"))
		if sum and sum > 2147483647 then break end
	end
	t:require(sum and sum > 2147483647, "checksum really is above 2^31: " .. tostring(sum))
	local back = P.Unpack(payload)
	t:ok(back ~= nil, "round-trips through Unpack")
	-- And the old form would have raised on this client.
	t:ok(not pcall(c.env.string.format, "%d", sum), "the old %d form raises on this checksum")
	-- The real save path too (CVar and macro writes), with no Lua error.
	c:Slash("/hark backup")
	w:Advance(4)
end)

T.test("format: a layer id above 2^31 is still sent (Positions uses %.0f for it)", function(t)
	local w = Sim.Scenario(t, { players = { { name = "Bob", x = 0, y = 0 }, { name = "Alice", x = 5, y = 0 } } })
	local bob = w:Get("Bob")
	w:SetLayer("Bob", 200000000) -- zone UID 100 + 1000 + 17 * 2e8 = 3,400,001,100
	for i = 1, 3 do w:ShowCreature("Bob", "nameplate" .. i, 300 + i) end
	w:Advance(5)
	local layer, confident = bob:NS().Positions:GetLayer()
	t:require(layer and layer > 2147483647, "layer above 2^31 detected: " .. tostring(layer))
	t:require(confident, "layer confirmed")
	local before = #bob:SentBy("Hark")
	bob:NS().Positions:RequestBroadcast()
	w:Advance(5)
	local sent = bob:SentBy("Hark")
	t:require(#sent > before, "a position message was sent")
	t:ok(sent[#sent].text:find("," .. string.format("%.0f", layer) .. ",", 1, true) ~= nil, "layer on the wire: " .. sent[#sent].text)
end)

---------------------------------------------------------------------------
-- Join log
---------------------------------------------------------------------------

T.test("joinlog: a normal join records every step, numeric ids first, typed values", function(t)
	local w, c = Solo(t)
	c:Slash("/hark join")
	w:Advance(2)
	t:require(c:NS().Voice:IsActive(), "joined")
	local join = last(steps(c, "join"))
	t:require(join ~= nil, "join step")
	t:eq(join.clubId.t, "string", "saved club id is a string")
	t:eq(join.clubId.v, CLUB, "club id value")
	local rs = last(steps(c, "resolveStream"))
	t:eq(rs.result.v, "1", "resolved stream")
	t:eq(rs.source, "general", "from the General stream")
	t:eq(rs.getStreams[1].form, "number", "GetStreams tried numeric first")
	t:eq(rs.getStreams[1].args[1].t, "number", "numeric arg recorded with its type")
	local list = rs.getStreams[1].ret.v
	t:eq(list[1].v.streamId.t, "number", "stream id typed")
	t:eq(list[1].v.streamType.v, 0, "stream type")
	t:eq(list[1].v.name.v, "General", "stream name")
	t:eq(last(steps(c, "isLoggedIn")).ret.v, true, "logged in")
	local lookup = last(steps(c, "lookup"))
	t:eq(#lookup.attempts, 2, "lookup tried both forms (nothing joined yet)")
	t:eq(lookup.attempts[1].form, "number", "number first")
	t:eq(lookup.attempts[2].form, "string", "then string")
	t:eq(lookup.attempts[1].ret.t, "nil", "nothing found")
	local req = last(steps(c, "request"))
	t:eq(req.form, "number", "request sent with numbers")
	t:eq(req.args[1].v, 23111161, "club as a number")
	t:eq(req.args[2].v, 1, "stream as a number")
	t:eq(req.ok, true, "call did not raise")
	local joined
	for _, e in ipairs(steps(c, "event")) do
		if e.event == "VOICE_CHAT_CHANNEL_JOINED" then joined = e end
	end
	t:require(joined ~= nil, "JOINED event logged")
	t:eq(joined.args.n, 5, "five payload values")
	t:eq(joined.args[1].v, 0, "status")
	t:eq(joined.args[4].t, "number", "clubId arrives as a number (Forever docs)")
	t:ok(#steps(c, "joinedDecision") >= 1, "decision recorded")
	t:ok(last(steps(c, "adopt")) ~= nil, "adopt recorded")
	t:eq(db(c).trace, nil, "nothing in the trace while it is off")

	-- With the trace on, the same rows go to the trace too.
	c:Slash("/hark leave")
	c:Slash("/hark trace on")
	c:Slash("/hark join")
	w:Advance(2)
	local rows = 0
	for _, r in ipairs(db(c).trace or {}) do if r.k == "join" then rows = rows + 1 end end
	t:ok(rows >= 6, "join rows in the trace: " .. rows)
end)

T.test("joinlog: capped at 40, newest kept", function(t)
	local w, c = Solo(t)
	for _ = 1, 30 do
		c:Slash("/hark join")
		w:Advance(1)
		c:Slash("/hark leave")
		w:Advance(1)
	end
	local log = db(c).joinlog
	t:eq(#log, 40, "capped")
	t:ok(log[#log].t >= log[1].t, "in time order")
end)

T.test("joinlog: an event carrying a secret value is dropped by the guard and logged as such", function(t)
	local w, c = Solo(t)
	local SECRET = setmetatable({}, { __tostring = function() return "RAW-SECRET" end })
	c.api.issecretvalue = function(v) return rawequal(v, SECRET) end
	c.api.C_VoiceChat.RequestJoinAndActivateCommunityStreamChannel = function() end
	c:Slash("/hark join")
	w:Advance(0.5)
	c:FireEvent("VOICE_CHAT_CHANNEL_JOINED", 0, 99, 4, SECRET, 1)
	w:Advance(11)
	local ev = last(steps(c, "event"))
	t:require(ev and ev.event == "VOICE_CHAT_CHANNEL_JOINED", "event logged")
	t:eq(ev.dropped, "secret value guard", "dropped by the guard")
	t:eq(ev.secretArg, 4, "argument index")
	t:eq(ev.args[4].t, "secret", "typed as secret")
	t:eq(ev.args[4].v, "<secret>", "never stored raw")
	t:eq(c:NS().Voice:GetState(), "idle", "guard not weakened: nothing adopted")
	t:ok(printed(c, "JOINED%(0 Success%)%[dropped: arg 4 secret%]"), "timeout diagnosis names it")
	local report = runReader(db(c))
	t:ok(report:find("FAILED AT the event guard", 1, true), "reader verdict:\n" .. report:sub(-600))
end)

---------------------------------------------------------------------------
-- Timeout diagnosis
---------------------------------------------------------------------------

T.test("timeout: the message is a short diagnosis of what was seen", function(t)
	local w, c = Solo(t)
	c.api.C_VoiceChat.RequestJoinAndActivateCommunityStreamChannel = function() end -- the client ignores it
	local out = c:Slash("/hark join")
	w:Advance(11)
	local lines = {}
	for i = 1, #c.prints do
		if c.prints[i]:find("Could not join", 1, true) then
			for j = i, #c.prints do lines[#lines + 1] = c.prints[j] end
		end
	end
	t:require(#lines >= 1, "diagnosis printed: " .. table.concat(c.prints, " | "))
	t:ok(#lines <= 3, "at most three lines")
	local text = table.concat(lines, "\n")
	t:ok(text:find("stream 1 (general), sent as number", 1, true), "stream and form: " .. text)
	t:ok(text:find("Voice logged in: yes", 1, true), "login state")
	t:ok(text:find("Voice events in 10 s: none", 1, true), "event count")
	t:ok(text:find("Channel lookup: nothing; active channel: none", 1, true), "lookup")
	t:eq(last(steps(c, "timeout")).decision, "failed", "timeout decision logged")
	t:eq(#out, 0, "nothing printed at the moment of /hark join")
	local report = runReader(db(c))
	t:ok(report:find("FAILED AT the request: RequestJoinAndActivateCommunityStreamChannel(23111161:number, 1:number) produced no voice event", 1, true),
		"reader verdict:\n" .. report:sub(-800))
end)

T.test("timeout: a wrong stream id is visible as a failure status and as missing from GetStreams", function(t)
	local w, c = Solo(t)
	c:Slash("/hark setcommunity " .. CLUB .. " 5")
	c:Slash("/hark join")
	w:Advance(2)
	t:ok(printed(c, "status 11 TargetNotFound"), "status name printed")
	local report = runReader(db(c))
	t:ok(report:find("status 11 TargetNotFound", 1, true) and report:find("Stream 5 is NOT in this club's GetStreams list", 1, true),
		"reader verdict:\n" .. report:sub(-800))
end)

---------------------------------------------------------------------------
-- Fixes: login wait, activation by id, Blizzard's "active" rule, id forms
---------------------------------------------------------------------------

T.test("login: when voice is logged out the request waits for VOICE_CHAT_LOGIN (as Blizzard's ChannelFrame does)", function(t)
	local w, c = Solo(t, { voiceLoggedIn = false })
	c:Slash("/hark join")
	w:Advance(3)
	t:ok(c:NS().Voice:IsActive(), "joined after the login completed")
	t:eq(last(steps(c, "isLoggedIn")).ret.v, false, "logged out at the start")
	t:eq(last(steps(c, "login")).status, "1 OperationPending", "Login status")
	local order = {}
	for _, e in ipairs(db(c).joinlog) do
		if e.step == "loginWait" or e.step == "request" or (e.step == "event" and e.event == "VOICE_CHAT_LOGIN") then
			order[#order + 1] = e.step == "event" and "LOGIN" or e.step
		end
	end
	t:eq(table.concat(order, ","), "loginWait,LOGIN,request", "request only after VOICE_CHAT_LOGIN")
end)

T.test("activation: a channel from our JOINED is adopted on ACTIVATED even if GetChannel lacks club and stream", function(t)
	local w, c = Solo(t)
	local real = c.api.C_VoiceChat.GetChannel
	c.api.C_VoiceChat.GetChannel = function(id)
		local ch = real(id)
		if ch then ch.clubId, ch.streamId = nil, nil end
		return ch
	end
	c:Slash("/hark join")
	w:Advance(2)
	t:ok(c:NS().Voice:IsActive(), "adopted")
	t:ok(last(steps(c, "activatedDecision")).decision:find("from our JOINED", 1, true), "matched by channel id")
end)

T.test("activation: GetActiveChannelID decides 'active' when the struct's isActive is stale", function(t)
	local w, c = Solo(t, nil, true)
	local api = c.api.C_VoiceChat
	local realGet, realLookup = api.GetChannel, api.GetChannelForCommunityStream
	local function stale(ch) if ch then ch.isActive = false end return ch end
	api.GetChannel = function(...) return stale(realGet(...)) end
	api.GetChannelForCommunityStream = function(...) return stale(realLookup(...)) end
	-- Already in the channel (joined from the Communities window) before Hark was configured.
	w:UserJoinsVoice("Bob", CLUB, "1")
	w:Advance(1)
	c:Slash("/hark setcommunity " .. CLUB)
	t:eq(c:NS().Voice:GetState(), "idle", "Hark not attached yet")
	c:Slash("/hark join")
	w:Advance(1)
	t:ok(c:NS().Voice:IsActive(), "adopted the active channel despite isActive = false")
	t:eq(#steps(c, "activate"), 0, "no ActivateChannel on a channel that is already active")
end)

T.test("id forms: a lookup that returns nothing for numbers is retried with strings", function(t)
	local w, c = Solo(t, nil, true)
	local api = c.api.C_VoiceChat
	local real = api.GetChannelForCommunityStream
	api.GetChannelForCommunityStream = function(clubId, streamId)
		if type(clubId) ~= "string" then return nil end
		return real(clubId, streamId)
	end
	w:UserJoinsVoice("Bob", CLUB, "1")
	w:Advance(1)
	c:Slash("/hark setcommunity " .. CLUB)
	c:Slash("/hark join")
	w:Advance(1)
	t:ok(c:NS().Voice:IsActive(), "joined through the string form")
	local lookup = last(steps(c, "lookup"))
	t:eq(lookup.form, "string", "string form recorded as the one that worked")
	t:eq(lookup.attempts[1].ret.t, "nil", "number form returned nothing")
	t:eq(c:NS().db.communityId, CLUB, "saved id still the string")
end)

T.test("id forms: a request the client refuses with numbers is retried with strings", function(t)
	local w, c = Solo(t)
	local api = c.api.C_VoiceChat
	local real = api.RequestJoinAndActivateCommunityStreamChannel
	api.RequestJoinAndActivateCommunityStreamChannel = function(clubId, streamId)
		if type(clubId) ~= "string" then error("bad argument #1 (string expected)") end
		return real(clubId, streamId)
	end
	c:Slash("/hark join")
	w:Advance(2)
	t:ok(c:NS().Voice:IsActive(), "joined with strings")
	local reqs = steps(c, "request")
	t:eq(reqs[#reqs - 1].form, "number", "number tried first")
	t:eq(reqs[#reqs - 1].ok, false, "and refused")
	t:eq(reqs[#reqs].form, "string", "string second")
end)

---------------------------------------------------------------------------
-- /hark joindiag
---------------------------------------------------------------------------

T.test("joindiag: records facts, every voice event for 20 s, the join, and a one-line summary", function(t)
	local w, c = Solo(t)
	local out = c:Slash("/hark joindiag")
	t:ok(table.concat(out, "\n"):find("Join diagnostic running for 20 s", 1, true), "announced")
	w:Advance(21)
	local jd = db(c).joindiag
	t:require(type(jd) == "table" and jd.complete, "complete")
	t:eq(jd.pre.IsLoggedIn.v, true, "pre: logged in")
	t:eq(jd.pre.resolvedStreamId.v, "1", "pre: resolved stream")
	t:eq(jd.pre.streamSource, "general", "pre: stream source")
	t:ok(type(jd.pre.getStreams) == "table" and jd.pre.getStreams[1].form == "number", "pre: GetStreams attempts")
	t:ok(type(jd.pre.lookup) == "table", "pre: lookup attempts")
	t:ok(#jd.accepted >= 10, "accepted events: " .. #jd.accepted)
	t:ok(#jd.rejected >= 1, "names the mock does not know are recorded as refused")
	local names = {}
	for _, e in ipairs(jd.events) do names[#names + 1] = e.event end
	t:eq(names[1], "VOICE_CHAT_CHANNEL_JOINED", "first event")
	t:eq(names[2], "VOICE_CHAT_CHANNEL_ACTIVATED", "second event")
	t:eq(jd.final.joined, true, "joined")
	t:eq(jd.final.GetActiveChannelID.t, "number", "final active channel")
	t:ok(#jd.joinlog >= 6, "join steps copied in")
	local line = printed(c, "^%[Hark%] Join diagnostic: ") or printed(c, "Join diagnostic: ")
	t:require(line, "summary printed")
	t:ok(line:find("JOINED; events: CHANNEL_JOINED(0), CHANNEL_ACTIVATED", 1, true), "summary: " .. line)
	t:ok(line:find("GetActiveChannelID " .. tostring(jd.final.GetActiveChannelID.v), 1, true), "summary has the final id")
	-- The listener is gone afterwards.
	local before = #jd.events
	c:FireEvent("VOICE_CHAT_CHANNEL_ACTIVATED", 1234)
	t:eq(#jd.events, before, "unhooked after 20 s")

	c:Reload()
	w:Advance(1)
	local report = runReader(db(c))
	t:ok(report:find("exit=0", 1, true), "reader exits cleanly:\n" .. report:sub(-600))
	t:ok(report:find("Join diagnostic (/hark joindiag)", 1, true), "joindiag section")
	t:ok(report:find("Verdict: JOINED", 1, true), "verdict:\n" .. report:sub(-1200))
	t:ok(report:find('stream 1:number  type 0:number  name "General":string', 1, true), "stream list printed")
end)

T.test("joindiag: a failed join is summarised and the reader names the failing step", function(t)
	local w, c = Solo(t)
	c.api.C_VoiceChat.RequestJoinAndActivateCommunityStreamChannel = function() end
	c:Slash("/hark joindiag")
	w:Advance(21)
	local jd = db(c).joindiag
	t:eq(jd.final.joined, false, "not joined")
	t:ok(printed(c, "Join diagnostic: NOT joined %(string%-id retry at 6 s: still no events%); events: none; GetActiveChannelID nil"),
		"summary: " .. tostring(printed(c, "Join diagnostic:")))
	t:eq(jd.stringRetry.args[1].t, "string", "retry used strings")
	local report = runReader(db(c))
	t:ok(report:find("Verdict: FAILED AT the request", 1, true), "verdict:\n" .. report:sub(-800))
	t:ok(report:find("the id form is not the cause", 1, true), "retry verdict")
end)

T.test("joindiag: a client that ignores numeric ids is caught by the string retry in the same run", function(t)
	local w, c = Solo(t)
	local api = c.api.C_VoiceChat
	local real = api.RequestJoinAndActivateCommunityStreamChannel
	api.RequestJoinAndActivateCommunityStreamChannel = function(clubId, streamId)
		if type(clubId) == "number" then return end -- silently ignored
		return real(clubId, streamId)
	end
	c:Slash("/hark joindiag")
	w:Advance(21)
	local jd = db(c).joindiag
	t:require(jd.stringRetry ~= nil, "retried with strings")
	t:eq(jd.final.joined, true, "the late success was adopted")
	t:ok(printed(c, "string%-id retry at 6 s: events followed"), "summary says so")
	local report = runReader(db(c))
	t:ok(report:find("ID FORM: the numeric-id request drew no event, the string-id retry did and joined", 1, true),
		"verdict:\n" .. report:sub(-900))
end)

T.test("joindiag: no retry when the numeric request drew events", function(t)
	local w, c = Solo(t)
	c:Slash("/hark joindiag")
	w:Advance(21)
	t:eq(db(c).joindiag.stringRetry, nil, "no retry")
end)
