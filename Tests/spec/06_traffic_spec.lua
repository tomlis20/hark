--- Addon-message traffic stays inside what the server allows.
local T = ...
local Sim = T.helpers

local function stats(c)
	local n, bad, types = 0, {}, {}
	for _, m in ipairs(c.sent) do
		n = n + 1
		types[m.chatType] = true
		if m.result ~= 0 then bad[#bad + 1] = m.chatType .. "->" .. m.result end
	end
	return n, bad, types
end

T.test("10 minutes of play: never throttled, never a rejected chat type", function(t)
	local w = Sim.Scenario(t, { players = {
		{ name = "Bob", x = 0, y = 0, group = "g1" }, { name = "Alice", x = 10, y = 0, group = "g1" },
		{ name = "Carol", x = -40, y = 20, noGuild = true, group = "g1" } } })
	for i = 1, 20 do
		w:MoveTo("Alice", (i % 2 == 0) and 10 or 60, i, 7)
		w:MoveTo("Carol", -40 + (i % 3) * 20, 20, 7)
		w:ShowCreature("Bob", "nameplate" .. (i % 5 + 1), 1000 + i)
		w:Advance(30)
	end
	for _, name in ipairs({ "Bob", "Alice", "Carol" }) do
		local n, bad, types = stats(w:Get(name))
		t:eq(#bad, 0, name .. " sends with a non-success result: " .. table.concat(bad, ", "))
		t:ok(not types.SAY and not types.YELL, name .. " used SAY/YELL")
		t:ok(n > 0, name .. " sent nothing in 10 minutes")
	end
end)

T.test("idle player sends at a bounded rate", function(t)
	local w = Sim.Scenario(t)
	local a = w:Get("Alice")
	local before = #a.sent
	w:Advance(300)
	local perMinute = (#a.sent - before) / 5
	t:between(perMinute, 1, 12, "idle messages per minute")
	t:note(string.format("idle rate %.1f msgs/min", perMinute))
end)

T.test("moving player sends at a bounded rate", function(t)
	local w = Sim.Scenario(t)
	local a = w:Get("Alice")
	local before = #a.sent
	for i = 1, 10 do w:MoveTo("Alice", (i % 2) * 200, 0, 7); w:Advance(30) end
	local perMinute = (#a.sent - before) / 5
	t:between(perMinute, 6, 40, "moving messages per minute")
	t:note(string.format("moving rate %.1f msgs/min", perMinute))
end)

T.test("timers do not multiply over repeated events", function(t)
	-- Every event that reschedules a loop must cancel the previous one.
	local w = Sim.Scenario(t)
	local before = w.clock:Pending()
	local a = w:Get("Alice")
	for _ = 1, 50 do
		a:FireEvent("GROUP_ROSTER_UPDATE"); a:FireEvent("PLAYER_GUILD_UPDATE")
		a:FireEvent("ZONE_CHANGED_NEW_AREA"); a:FireEvent("PLAYER_ENTERING_WORLD", false, false)
		w:MoveTo("Alice", math.random(0, 30), 0); w:Advance(0.2)
	end
	w:Advance(10)
	local after = w.clock:Pending()
	t:ok(after <= before + 4, string.format("pending timers grew from %d to %d", before, after))
end)

T.test("messages fit the 255-byte limit", function(t)
	local w = Sim.Scenario(t)
	for _, m in ipairs(w.wire) do
		t:ok(#m.text <= 255, "message of " .. #m.text .. " bytes")
	end
	t:ok(#w.wire > 0, "something was sent")
end)
