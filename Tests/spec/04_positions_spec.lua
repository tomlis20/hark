--- Position sharing, end to end: Alice's client broadcasts, Bob's client
-- decodes and sets Alice's voice volume. Everything is observed from the
-- voice engine (what Bob actually hears), not from addon internals.
local T = ...
local Sim = T.helpers

local function expected(c, d)
	local ns = c:NS()
	if ns and type(ns.GetVolumeForDistance) == "function" then return ns:GetVolumeForDistance(d) end
	local full, silent, minV, maxV = Sim.Ranges(c)
	if d <= full then return maxV end
	if d >= silent then return 0 end
	return nil
end

-- Volume Bob hears Alice at, with Bob at (bx, by) and Alice d yards along +x.
local function measure(t, bx, by, d, worldOpts)
	local w = Sim.Scenario(t, { world = worldOpts, players = {
		{ name = "Bob", x = bx, y = by }, { name = "Alice", x = bx + d, y = by } } })
	return w:Hears("Bob", "Alice"), w
end

T.test("near player at positive coordinates is heard at full volume", function(t)
	local v, w = measure(t, 100, 200, 5)
	t:eq(v, expected(w:Get("Bob"), 5), "Bob hears Alice")
end)

T.test("far player at positive coordinates is silent", function(t)
	local v = measure(t, 100, 200, 300)
	t:eq(v, 0, "Bob hears Alice")
end)

for _, q in ipairs({ { -1, 1 }, { 1, -1 }, { -1, -1 } }) do
	T.test(string.format("NEGATIVE coordinates decode (quadrant %d,%d): far is silent", q[1], q[2]), function(t)
		local v = measure(t, q[1] * 3456.5, q[2] * 1234.25, 300)
		t:eq(v, 0, "Bob hears Alice 300 yd away")
	end)
	T.test(string.format("NEGATIVE coordinates decode (quadrant %d,%d): mid-fade matches positive", q[1], q[2]), function(t)
		local full, silent = 15, 40
		local d = (full + silent) / 2
		local pos = measure(t, 3456.5, 1234.25, d)
		local neg, w = measure(t, q[1] * 3456.5, q[2] * 1234.25, d)
		t:ok(neg ~= nil and neg > 0 and neg < 100, "negative mid-fade volume strictly between 0 and 100, got " .. tostring(neg))
		t:near(neg, pos or -1, 3, "negative-quadrant volume vs positive-quadrant volume")
	end)
end

T.test("crossing zero: Bob at x=-10, Alice at x=+20 (30 yd apart)", function(t)
	local w = Sim.Scenario(t, { players = { { name = "Bob", x = -10, y = -0.5 }, { name = "Alice", x = 20, y = 0.5 } } })
	local exp = expected(w:Get("Bob"), w:Distance("Bob", "Alice"))
	local v = w:Hears("Bob", "Alice")
	if exp then t:near(v, exp, 4, "volume at 30 yd") else t:ok(v and v > 0 and v < 100, "mid-fade volume, got " .. tostring(v)) end
end)

T.test("fractional coordinates: quantisation error stays under ~1.5 yd", function(t)
	local w = Sim.Scenario(t, { players = { { name = "Bob", x = -2000.9, y = -300.1 }, { name = "Alice", x = -2000.9 + 27.4, y = -300.1 + 0.6 } } })
	local d = w:Distance("Bob", "Alice")
	local bob = w:Get("Bob")
	local lo, hi = expected(bob, d + 1.5), expected(bob, d - 1.5)
	if not (lo and hi) then t:skip("needs Hark:GetVolumeForDistance") end
	t:between(w:Hears("Bob", "Alice"), lo, hi, "volume at " .. string.format("%.2f", d) .. " yd")
end)

T.test("different continent (instanceID) is silenced even at equal coordinates", function(t)
	local w = Sim.Scenario(t, { players = { { name = "Bob", x = 50, y = 50, instanceID = 0 },
		{ name = "Alice", x = 52, y = 50, instanceID = 1, zone = "Durotar", mapID = 1411 } } })
	t:eq(w:Hears("Bob", "Alice"), 0, "Bob hears Alice")
end)

-- CONTRACT.md 3: distance is continent-wide; zone only scopes layer ids.
-- (The original brief asked for "different zone = silenced"; the contract
-- chose real distance across zone borders. These tests follow the contract.)
T.test("adjacent zones: 5 yd apart across a border are heard (CONTRACT 3)", function(t)
	local w = Sim.Scenario(t, { players = { { name = "Bob", x = 50, y = 50, zone = "Elwynn Forest", mapID = 1429 },
		{ name = "Alice", x = 55, y = 50, zone = "Westfall", mapID = 1436 } } })
	t:eq(w:Hears("Bob", "Alice"), 100, "Bob hears Alice")
end)

T.test("different zone far away is silent", function(t)
	local w = Sim.Scenario(t, { players = { { name = "Bob", x = 50, y = 50, zone = "Elwynn Forest", mapID = 1429 },
		{ name = "Alice", x = -1500, y = 900, zone = "Westfall", mapID = 1436 } } })
	t:eq(w:Hears("Bob", "Alice"), 0, "Bob hears Alice")
end)

T.test("zone change mid-session silences, returning restores", function(t)
	local w = Sim.Scenario(t, { players = { { name = "Bob", x = 50, y = 50 }, { name = "Alice", x = 55, y = 50 } } })
	t:eq(w:Hears("Bob", "Alice"), 100, "same zone first")
	w:ChangeZone("Alice", { zone = "Westfall", mapID = 1436, x = -1500, y = 900 })
	w:Advance(Sim.SETTLE)
	t:eq(w:Hears("Bob", "Alice"), 0, "after Alice travels to Westfall")
	w:ChangeZone("Alice", { zone = "Elwynn Forest", mapID = 1429, x = 55, y = 50 })
	w:Advance(Sim.SETTLE)
	t:eq(w:Hears("Bob", "Alice"), 100, "after Alice comes back")
end)

T.test("continent change (loading screen) silences", function(t)
	local w = Sim.Scenario(t, { players = { { name = "Bob", x = 50, y = 50 }, { name = "Alice", x = 55, y = 50 } } })
	w:ChangeZone("Alice", { zone = "Durotar", mapID = 1411, instanceID = 1, x = 52, y = 50 })
	w:Advance(Sim.SETTLE)
	t:eq(w:Hears("Bob", "Alice"), 0, "Alice on Kalimdor at nearly the same coordinates")
end)

T.test("grouped players inside the same dungeon hear each other (CONTRACT 3 'instance')", function(t)
	local w = Sim.Scenario(t, { players = {
		{ name = "Bob", x = 0, y = 0, group = "g" }, { name = "Alice", x = 300, y = 0, group = "g" },
		{ name = "Carol", x = 0, y = 5 } } })
	local dungeon = { zone = "The Deadmines", mapID = 291, instanceID = 36, inInstance = true, instanceType = "party", x = 0, y = 0 }
	for _, n in ipairs({ "Bob", "Alice", "Carol" }) do w:ChangeZone(n, dungeon) end
	w:Advance(Sim.SETTLE)
	t:eq(w:Hears("Bob", "Alice"), 100, "grouped Alice in the same dungeon")
	t:eq(w:Hears("Bob", "Carol"), 0, "ungrouped Carol in the same dungeon map (not grouped, so no shared position)")
end)

T.test("group members with no guild still hear each other", function(t)
	local w = Sim.Scenario(t, { players = {
		{ name = "Bob", x = 0, y = 0, group = "g", noGuild = true }, { name = "Alice", x = 5, y = 0, group = "g", noGuild = true },
		{ name = "Carol", x = 300, y = 0, group = "g", noGuild = true } } })
	t:eq(w:Hears("Bob", "Alice"), 100, "Alice 5 yd")
	t:eq(w:Hears("Bob", "Carol"), 0, "Carol 300 yd")
end)

T.test("a message claiming someone else's GUID is ignored", function(t)
	local w = Sim.Scenario(t, { players = { { name = "Bob", x = 0, y = 0 }, { name = "Alice", x = 300, y = 0 }, { name = "Mallory", x = 999, y = 999 } } })
	local alice = w:Get("Alice")
	for i = 1, 5 do
		w:InjectAddonMessage("Bob", "Mallory", "Hark", string.format("P1,%d,%s,0,0,1,1429,0,", 900000 + i, alice.guid), "GUILD")
		w:Advance(0.5)
	end
	t:eq(w:Hears("Bob", "Alice"), 0, "Bob still has far-away Alice silent")
end)

T.test("same layer control: both see NPCs on layer 1, 5 yd apart, full volume", function(t)
	local w = Sim.Scenario(t, { players = { { name = "Bob", x = 0, y = 0, layer = 1 }, { name = "Alice", x = 5, y = 0, layer = 1 } } })
	w:ShowCreature("Bob", "target", 299)
	w:ShowCreature("Alice", "target", 299)
	w:ShowCreature("Bob", "mouseover", 61)
	w:ShowCreature("Alice", "mouseover", 61)
	w:Advance(Sim.SETTLE)
	t:eq(w:Hears("Bob", "Alice"), 100, "Bob hears Alice on the same layer")
end)

T.test("different layer is silenced even 5 yd apart", function(t)
	local w = Sim.Scenario(t, { players = { { name = "Bob", x = 0, y = 0, layer = 1 }, { name = "Alice", x = 5, y = 0, layer = 2 } } })
	w:ShowCreature("Bob", "target", 299)
	w:ShowCreature("Alice", "target", 299)
	w:ShowCreature("Bob", "mouseover", 61)
	w:ShowCreature("Alice", "mouseover", 61)
	w:Advance(Sim.SETTLE)
	t:eq(w:Hears("Bob", "Alice"), 0, "Bob hears Alice on another layer")
end)

T.test("layer change is picked up after seeing a new NPC", function(t)
	local w = Sim.Scenario(t, { players = { { name = "Bob", x = 0, y = 0, layer = 1 }, { name = "Alice", x = 5, y = 0, layer = 1 } } })
	-- Two NPCs each: the addon needs two agreeing samples to trust a layer.
	w:ShowCreature("Bob", "target", 299); w:ShowCreature("Alice", "target", 299)
	w:ShowCreature("Bob", "mouseover", 61); w:ShowCreature("Alice", "mouseover", 61)
	w:Advance(Sim.SETTLE)
	t:eq(w:Hears("Bob", "Alice"), 100, "same layer first")
	w:SetLayer("Alice", 2)
	-- Realistic evidence after a hop: a target, a mouseover and a nameplate.
	w:ShowCreature("Alice", "target", 300)
	w:ShowCreature("Alice", "mouseover", 301)
	w:ShowCreature("Alice", "nameplate1", 302)
	w:Advance(Sim.SETTLE)
	t:eq(w:Hears("Bob", "Alice"), 0, "after Alice hops to layer 2")
end)

T.test("stale positions are dropped", function(t)
	local cut = false
	local w = Sim.Scenario(t, {
		world = { latency = function(from) if cut and from.name == "Alice" then return nil end return 0.1 end },
		players = { { name = "Bob", x = 0, y = 0 }, { name = "Alice", x = 27, y = 0 } } })
	local before = w:Hears("Bob", "Alice")
	t:ok(before and before > 0 and before < 100, "precondition: mid-fade volume, got " .. tostring(before))
	cut = true
	w:Advance(180)
	local db = w:Get("Bob"):Global("HarkDB") or {}
	local unknown = db.hearUnknown and (db.maxVolume or 100) or 0
	t:eq(w:Hears("Bob", "Alice"), unknown, "after 3 minutes with no position from Alice (hearUnknown=" .. tostring(db.hearUnknown) .. ")")
end)

T.test("positions delayed by 5 s still apply (and GetTime differs per client)", function(t)
	local w = Sim.Scenario(t, { world = { latency = function() return 5 end },
		players = { { name = "Bob", x = 0, y = 0 }, { name = "Alice", x = 5, y = 0 } } })
	w:Advance(10)
	t:eq(w:Hears("Bob", "Alice"), 100, "Bob hears Alice")
end)

T.test("an old position arriving after a newer one does not win", function(t)
	local slow = true
	local w = Sim.Scenario(t, {
		world = { latency = function(from) if slow and from.name == "Alice" then return 20 end return 0.1 end },
		players = { { name = "Bob", x = 0, y = 0 }, { name = "Alice", x = 80, y = 0 } } })
	w:Advance(25) -- slow messages from the far position are now flowing
	t:eq(w:Hears("Bob", "Alice"), 0, "precondition: far and silent")
	-- Alice's heartbeat is shorter than 20 s, so at least one far-position
	-- message is still in flight. From now on her messages are fast, so the
	-- near position arrives first and the old far one lands afterwards.
	local inFlight = 0
	for _, m in ipairs(w:Get("Alice").sent) do
		if m.time > w:Now() - 20 then inFlight = inFlight + 1 end
	end
	t:require(inFlight > 0, "test setup: no far-position message in flight")
	slow = false
	w:SetPosition("Alice", 5, 0)
	w:Advance(4)
	t:eq(w:Hears("Bob", "Alice"), 100, "near position applied")
	local worst, trace = 100, {}
	for _ = 1, 44 do
		w:Advance(0.5)
		local v = w:Hears("Bob", "Alice") or -1
		trace[#trace + 1] = tostring(v)
		if v < worst then worst = v end
	end
	t:eq(worst, 100, "lowest volume while " .. inFlight .. " late far-away position(s) landed (Alice is 5 yd away): " .. table.concat(trace, " "))
end)

T.test("a player never adjusts their own volume (echoed messages ignored)", function(t)
	local w = Sim.Scenario(t)
	local a = w:Get("Alice")
	t:eq(a.voice.volumes[a.guid], nil, "Alice's volume setting for herself")
end)

T.test("malformed and foreign messages are ignored without errors", function(t)
	local w = Sim.Scenario(t)
	local junk = { "", "P", "P:::", "P:0:a:b", "P:0:1e999:5", "\0\1\2", string.rep("x", 255), "P:-0:-:-", "V:9:9:9:9:9:9" }
	for _, prefix in ipairs({ "Hark", "HarkV2", "Other" }) do
		for _, msg in ipairs(junk) do w:InjectAddonMessage("Bob", "Mallory", prefix, msg, "GUILD") end
	end
	w:Advance(5)
	t:eq(w:Hears("Bob", "Alice"), 100, "Bob still hears nearby Alice")
end)
