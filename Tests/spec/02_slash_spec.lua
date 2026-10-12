--- Slash command parsing. The documented command list is read from the
-- addon's own /hark help output, so new commands are covered automatically.
local T = ...

local function setup(t)
	local w = t:world()
	w:CreateCommunity({ members = { "Alice" } })
	local c = w:AddPlayer({ name = "Alice" })
	w:Advance(1)
	return w, c
end

local function documented(c)
	local out = c:Slash("/hark help")
	local cmds, seen = {}, {}
	for _, line in ipairs(out) do
		local rest = line:match("/hark%s+(.*)$")
		if rest then
			-- "on | off   Enable..." / "on|off" / "setcommunity <clubId> [streamId]"
			local head = rest:match("^([%w|%s]-)%s%s") or rest:match("^(%S+)") or ""
			for word in head:gmatch("[%a]+") do
				if not seen[word] then seen[word] = true; cmds[#cmds + 1] = word end
			end
		end
	end
	return cmds
end

T.test("/hark help lists commands", function(t)
	local _, c = setup(t)
	local cmds = documented(c)
	t:ok(#cmds >= 5, "expected at least 5 documented commands, parsed: " .. table.concat(cmds, ", "))
	t:note("documented: " .. table.concat(cmds, " "))
end)

T.test("every documented command runs and responds", function(t)
	local w, c = setup(t)
	for _, cmd in ipairs(documented(c)) do
		local out, handled = c:Slash("/hark " .. cmd)
		w:Advance(1)
		t:ok(handled, "/hark " .. cmd .. " not routed to the addon")
		t:ok(#out > 0 or cmd == "options" or cmd == "join", "/hark " .. cmd .. " printed nothing")
	end
end)

T.test("README commands are all accepted", function(t)
	local w, c = setup(t)
	for _, cmd in ipairs({ "", "help", "on", "off", "status", "options", "join", "leave" }) do
		local out, handled = c:Slash(("/hark " .. cmd):gsub("%s+$", ""))
		w:Advance(1)
		t:ok(handled and (#out > 0 or cmd == "join" or cmd == "options"), "/hark " .. cmd .. " gave no response")
	end
end)

T.test("/ha alias, upper case and extra spaces", function(t)
	local _, c = setup(t)
	local out1 = c:Slash("/ha off")
	local out2 = c:Slash("/HARK   ON  ")
	t:ok(#out1 > 0, "/ha off printed nothing")
	t:ok(#out2 > 0, "/HARK   ON   printed nothing")
	local db = c:Global("HarkDB") or {}
	local ns = c:NS() or {}
	local enabled = db.enabled
	if enabled == nil then enabled = ns.enabled end
	t:eq(enabled, true, "enabled after /HARK   ON")
end)

T.test("off then on toggles the enabled state", function(t)
	local _, c = setup(t)
	local function enabled()
		local db = c:Global("HarkDB") or {}
		if db.enabled ~= nil then return db.enabled end
		return (c:NS() or {}).enabled
	end
	c:Slash("/hark off")
	t:eq(enabled(), false, "after /hark off")
	c:Slash("/hark on")
	t:eq(enabled(), true, "after /hark on")
end)

T.test("setcommunity stores club and stream ids", function(t)
	local _, c = setup(t)
	c:Slash("/hark setcommunity 23111161 7")
	local db = c:Global("HarkDB") or {}
	t:eq(tostring(db.communityId), "23111161", "communityId")
	t:eq(tostring(db.streamId), "7", "streamId")
	c:Slash("/hark setcommunity 555")
	t:eq(tostring(db.communityId), "555", "communityId without stream")
	t:eq(db.streamId, nil, "streamId cleared when omitted")
	local out = c:Slash("/hark setcommunity")
	t:ok(#out > 0, "bare setcommunity prints usage")
end)

T.test("unknown command gives feedback", function(t)
	local _, c = setup(t)
	local out = c:Slash("/hark frobnicate")
	t:ok(#out > 0, "unknown subcommand printed nothing")
end)

T.test("/hark join with a configured community joins voice", function(t)
	local w, c = setup(t)
	c:Slash("/hark setcommunity 23111161 1")
	c:Slash("/hark join")
	w:Advance(3)
	t:ok(w:InVoice("Alice"), "Alice is in an active voice channel 3 s after /hark join")
	c:Slash("/hark leave")
	w:Advance(3)
	t:ok(not w:InVoice("Alice"), "Alice left voice after /hark leave")
end)
