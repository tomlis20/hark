--- Adversarial review of the engine (Positions.lua, Voice.lua): races,
-- forged messages, sequence restarts, layer hops and the crash-recovery list.
local T = ...
local Sim = T.helpers

local CLUB = "23111161"

local function voiceOf(c) return c:NS().Voice end

-- Seed 1: a restore that only reached a stale location must not be recorded
-- as done, or a crash leaves the member quiet with nothing to recover them.
T.test("review: lowered list survives a restore the client silently ignored", function(t)
	local w = Sim.Scenario(t, { players = { { name = "Bob", x = 0, y = 0 }, { name = "Alice", x = 300, y = 0 } } })
	local bob, alice = w:Get("Bob"), w:Get("Alice")
	t:require(w:Hears("Bob", "Alice") == 0, "precondition: far Alice silenced")
	t:require(bob:Global("HarkDB").lowered[alice.guid] == true, "precondition: Alice recorded as lowered")
	-- Model the unverified case: a GUID PlayerLocation is accepted but does nothing.
	local vc = bob.env.C_VoiceChat
	local orig = vc.SetMemberVolume
	vc.SetMemberVolume = function(loc, v)
		if type(loc) == "table" and loc.guid then return end
		return orig(loc, v)
	end
	w:UserLeavesVoice("Bob", true) -- channel gone first: the voice-id location is stale
	w:Advance(2)
	t:require(w:VolumeSetting("Bob", "Alice") == 0, "setup: neither location restored Alice")
	t:eq(bob:Global("HarkDB").lowered[alice.guid], true, "Alice still listed for recovery at next login")
end)

T.test("review: a verified restore clears the lowered list", function(t)
	local w = Sim.Scenario(t, { players = { { name = "Bob", x = 0, y = 0 }, { name = "Alice", x = 300, y = 0 } } })
	local bob, alice = w:Get("Bob"), w:Get("Alice")
	t:require(bob:Global("HarkDB").lowered[alice.guid] == true, "precondition: Alice lowered")
	w:UserLeavesVoice("Bob", true)
	w:Advance(2)
	t:eq(w:VolumeSetting("Bob", "Alice"), 100, "Alice restored")
	t:eq(bob:Global("HarkDB").lowered[alice.guid], nil, "and no longer listed")
	w:SetPosition("Alice", 3, 0)
	w:UserJoinsVoice("Bob")
	w:Advance(Sim.SETTLE)
	t:eq(bob:Global("HarkDB").lowered[alice.guid], nil, "near Alice at full volume is not listed")
end)

-- Seed 3: join races.
T.test("review: /hark leave while a join is in flight stays out", function(t)
	local w = t:world({ voiceJoinDelay = 2 })
	w:CreateCommunity({ members = { "Bob" } })
	local bob = w:AddPlayer({ name = "Bob" })
	w:Advance(1)
	bob:Slash("/hark setcommunity " .. CLUB .. " 1")
	bob:Slash("/hark join")
	w:Advance(0.5)
	t:require(voiceOf(bob):GetState() == "joining", "precondition: joining")
	bob:Slash("/hark leave")
	w:Advance(6)
	t:eq(voiceOf(bob):GetState(), "idle", "addon state after the late join result")
	t:ok(not w:InVoice("Bob"), "Bob is not left in the voice channel he cancelled")
end)

T.test("review: a second Join while one is in flight sends one request", function(t)
	local w = t:world({ voiceJoinDelay = 2 })
	w:CreateCommunity({ members = { "Bob" } })
	local bob = w:AddPlayer({ name = "Bob" })
	w:Advance(1)
	bob:Slash("/hark setcommunity " .. CLUB .. " 1")
	local vc = bob.env.C_VoiceChat
	local orig, calls = vc.RequestJoinAndActivateCommunityStreamChannel, 0
	vc.RequestJoinAndActivateCommunityStreamChannel = function(...) calls = calls + 1 return orig(...) end
	bob:Slash("/hark join")
	w:Advance(0.5)
	bob:Slash("/hark join")
	w:Advance(5)
	t:eq(calls, 1, "join requests")
	t:eq(voiceOf(bob):GetState(), "active", "joined")
end)

T.test("review: a failed JOINED event while active does not drop proximity", function(t)
	local w = Sim.Scenario(t, { players = { { name = "Bob", x = 0, y = 0 }, { name = "Alice", x = 300, y = 0 } } })
	local bob = w:Get("Bob")
	bob:FireEvent("VOICE_CHAT_CHANNEL_JOINED", 9, nil, 4, CLUB, "1")
	w:Advance(2)
	t:eq(voiceOf(bob):GetState(), "active", "state")
	w:SetPosition("Alice", 3, 0)
	w:Advance(Sim.SETTLE)
	t:eq(w:Hears("Bob", "Alice"), 100, "proximity still running")
end)

T.test("review: switching community mid-join does not leave Bob in the old channel", function(t)
	local w = t:world({ voiceJoinDelay = 2 })
	w:CreateCommunity({ clubId = CLUB, members = { "Bob" } })
	w:CreateCommunity({ clubId = "999", name = "Other", members = { "Bob" } })
	local bob = w:AddPlayer({ name = "Bob" })
	w:Advance(1)
	bob:Slash("/hark setcommunity " .. CLUB .. " 1")
	bob:Slash("/hark join")
	w:Advance(0.5)
	bob:Slash("/hark setcommunity 999 1")
	w:Advance(8)
	t:eq(voiceOf(bob):GetState(), "active", "joined the new community")
	local old = w.voiceChannels[w:VoiceKey(CLUB, "1")]
	local stillIn = false
	for _, m in ipairs(old and old.members or {}) do if m.client == bob then stillIn = true end end
	t:ok(not stillIn, "Bob is no longer a member of the old community's voice channel")
end)

T.test("review: /hark leave cancels the rejoin scheduled by a community change", function(t)
	local w = Sim.Scenario(t, { players = { { name = "Bob", x = 0, y = 0 }, { name = "Alice", x = 3, y = 0 } } })
	w:CreateCommunity({ clubId = "999", name = "Other", members = { "Bob" } })
	local bob = w:Get("Bob")
	bob:Slash("/hark setcommunity 999 1")
	bob:Slash("/hark leave")
	w:Advance(6)
	t:eq(voiceOf(bob):GetState(), "idle", "state after leaving")
	t:ok(not w:InVoice("Bob"), "not in any voice channel")
end)

T.test("review: a join that completes after the timeout is still adopted", function(t)
	local w = t:world({ voiceJoinDelay = 12 })
	w:CreateCommunity({ members = { "Bob" } })
	local bob = w:AddPlayer({ name = "Bob" })
	w:Advance(1)
	bob:Slash("/hark setcommunity " .. CLUB .. " 1")
	bob:Slash("/hark join")
	w:Advance(10.5)
	t:require(voiceOf(bob):GetState() == "idle", "precondition: timed out")
	w:Advance(3)
	t:eq(voiceOf(bob):GetState(), "active", "late success adopted")
end)

T.test("review: /hark leave after a timeout drops the late join result", function(t)
	local w = t:world({ voiceJoinDelay = 12 })
	w:CreateCommunity({ members = { "Bob" } })
	local bob = w:AddPlayer({ name = "Bob" })
	w:Advance(1)
	bob:Slash("/hark setcommunity " .. CLUB .. " 1")
	bob:Slash("/hark join")
	w:Advance(10.5)
	bob:Slash("/hark leave")
	w:Advance(4)
	t:eq(voiceOf(bob):GetState(), "idle", "state")
	t:ok(not w:InVoice("Bob"), "not in voice")
end)

-- Seed 4: a peer that reloads restarts its sequence.
T.test("review: a peer's position after /reload applies at once", function(t)
	local w = Sim.Scenario(t, { players = { { name = "Bob", x = 0, y = 0 }, { name = "Alice", x = 5, y = 0 } } })
	t:require(w:Hears("Bob", "Alice") == 100, "precondition: near")
	w:Advance(60)
	local alice = w:Get("Alice")
	local function seqOf(m) return tonumber((m.text:match("^P1,(%d+),"))) end
	local maxBefore, n = 0, #alice.sent
	for _, m in ipairs(alice.sent) do maxBefore = math.max(maxBefore, seqOf(m) or 0) end
	alice:Reload()
	w:SetPosition("Alice", 300, 0)
	w:Advance(15)
	t:eq(w:Hears("Bob", "Alice"), 0, "Bob applies Alice's post-reload far position")
	-- Receivers drop a sequence number at or below the last one for 45 s, so a
	-- restarted session must continue above the previous session's numbers.
	local low = {}
	for i = n + 1, #alice.sent do
		local s = seqOf(alice.sent[i])
		if s and s <= maxBefore then low[#low + 1] = s end
	end
	t:eq(#low, 0, "post-reload sequence numbers at or below " .. maxBefore .. ": " .. table.concat(low, " "))
end)

-- Seed 9: forged messages when the client cannot verify the GUID.
local function unverifiable(c)
	rawset(c.env, "GetPlayerInfoByGUID", function() return nil end)
end

T.test("review: unverifiable forged GUID cannot unsilence a third party", function(t)
	local w = Sim.Scenario(t, { players = { { name = "Bob", x = 0, y = 0 }, { name = "Alice", x = 300, y = 0 }, { name = "Mallory", x = 999, y = 999 } } })
	unverifiable(w:Get("Bob"))
	local alice = w:Get("Alice")
	for i = 1, 6 do
		w:InjectAddonMessage("Bob", "Mallory", "Hark", string.format("P1,%d,%s,0,0,1,1429,0,", 990000 + i, alice.guid), "GUILD")
		w:Advance(0.5)
	end
	t:eq(w:Hears("Bob", "Alice"), 0, "far Alice stays silent")
end)

T.test("review: unverifiable forged GUID cannot silence a third party", function(t)
	local w = Sim.Scenario(t, { players = { { name = "Bob", x = 0, y = 0 }, { name = "Alice", x = 3, y = 0 }, { name = "Mallory", x = 999, y = 999 } } })
	unverifiable(w:Get("Bob"))
	local alice = w:Get("Alice")
	for i = 1, 6 do
		w:InjectAddonMessage("Bob", "Mallory", "Hark", string.format("P1,%d,%s,0,9000,9000,1429,0,", 990000 + i, alice.guid), "GUILD")
		w:Advance(0.5)
	end
	t:eq(w:Hears("Bob", "Alice"), 100, "near Alice stays audible")
end)

T.test("review: hostile payloads with the sender's own GUID raise no error", function(t)
	local w = Sim.Scenario(t, { players = { { name = "Bob", x = 0, y = 0 }, { name = "Mallory", x = 3, y = 0 } } })
	local g = w:Get("Mallory").guid
	local bad = {
		"P1,nan,%s,0,1,1,1429,0,", "P1,inf,%s,0,1,1,1429,0,", "P1,0x10,%s,0,1,1,1429,0,", "P1,1e9,%s,0,1,1,1429,0,",
		"P1,5,%s,0,99999999999999999999,1,1429,0,", "P1,6,%s,0,1,1,nan,inf,", "P1,7,%s,,,,,,", "P1,8,%s,0,1,1,1429,0,dh,extra",
		"P1,9,%s,-0,-,-,1429,0,", "P1,10,%s,0,1,1,1429,99999999999999999999,",
	}
	for _, f in ipairs(bad) do w:InjectAddonMessage("Bob", "Mallory", "Hark", string.format(f, g), "GUILD") end
	w:InjectAddonMessage("Bob", "Mallory", "Hark", "P1,1,Player-1-ZZ,0,1,1,1,0,", "WHISPER")
	w:Advance(Sim.SETTLE)
	t:eq(w:Hears("Bob", "Mallory"), 100, "Mallory's real position still applies")
end)

T.test("review: absurd coordinates are rejected", function(t)
	local w = Sim.Scenario(t, { players = { { name = "Bob", x = 0, y = 0 }, { name = "Mallory", x = 3, y = 0 } } })
	local pos = w:Get("Bob"):NS().Positions
	local g = w:Get("Mallory").guid
	w:InjectAddonMessage("Bob", "Mallory", "Hark", string.format("P1,999999,%s,0,99999999999,2,1429,0,", g), "GUILD")
	local rec = pos:Get(g)
	t:ok(rec and rec.x ~= 99999999999 and rec.y ~= 99999999999, "absurd coordinate stored")
end)

-- Seed 6: a layer hop while the old layer still has more samples.
T.test("review: a layer hop is detected although older samples outnumber the new ones", function(t)
	local w = Sim.Scenario(t, { players = { { name = "Bob", x = 0, y = 0, layer = 1 }, { name = "Alice", x = 5, y = 0, layer = 1 } } })
	for _, n in ipairs({ "Bob", "Alice" }) do
		w:ShowCreature(n, "target", 299); w:ShowCreature(n, "mouseover", 61)
		w:ShowCreature(n, "nameplate1", 62); w:ShowCreature(n, "nameplate2", 63); w:ShowCreature(n, "nameplate3", 64)
	end
	w:Advance(Sim.SETTLE)
	t:require(w:Hears("Bob", "Alice") == 100, "precondition: same layer")
	local alice = w:Get("Alice")
	w:SetLayer("Alice", 2)
	-- The old layer's creatures are no longer drawn after the hop.
	for _, u in ipairs({ "nameplate1", "nameplate2", "nameplate3" }) do
		alice.units[u] = nil
		alice:FireEvent("NAME_PLATE_UNIT_REMOVED", u)
	end
	w:ShowCreature("Alice", "target", 300)
	w:ShowCreature("Alice", "mouseover", 301)
	w:ShowCreature("Alice", "nameplate1", 302)
	w:Advance(Sim.SETTLE)
	local layer, confident = alice:NS().Positions:GetLayer()
	t:eq(layer, w:LayerZoneUID(0, 2), "Alice's detected layer")
	t:eq(confident, true, "confirmed")
	t:eq(w:Hears("Bob", "Alice"), 0, "Bob silences Alice on the other layer")
end)

T.test("review: stale known records are pruned", function(t)
	local w = Sim.Scenario(t, { players = { { name = "Bob", x = 0, y = 0 }, { name = "Alice", x = 3, y = 0 } } })
	for i = 1, 50 do
		w:InjectAddonMessage("Bob", "Ghost" .. i, "Hark", string.format("P1,1,Player-5000-%08X,0,1,1,1429,0,", 0x0F000000 + i), "GUILD")
	end
	local pos = w:Get("Bob"):NS().Positions
	t:require(pos:Count() >= 50, "setup: ghosts recorded")
	w:Advance(120)
	t:ok(pos:Count() <= 2, "only live senders counted")
	local n = 0
	for i = 1, 50 do if pos:GetName(string.format("Player-5000-%08X", 0x0F000000 + i)) then n = n + 1 end end
	t:eq(n, 0, "ghost records still held")
end)
