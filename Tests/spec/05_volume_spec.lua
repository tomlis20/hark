--- Volume control end to end: curve boundaries as heard through the voice
-- engine, moving players, nil member names, and restoring volumes.
local T = ...
local Sim = T.helpers

local function curveAt(c, d)
	local ns = c:NS()
	if ns and type(ns.GetVolumeForDistance) == "function" then return ns:GetVolumeForDistance(d) end
end

T.test("heard volume at the curve boundaries", function(t)
	local w = Sim.Scenario(t, { players = { { name = "Bob", x = -500, y = -800 }, { name = "Alice", x = -500, y = -800 } } })
	local bob = w:Get("Bob")
	local full, silent, minV, maxV = Sim.Ranges(bob)
	local mid = (full + silent) / 2
	local cases = {
		{ "touching (0 yd)", 0, maxV, 0 },
		{ "inside full range", full - 1, maxV, 0 },
		{ "at the full-voice edge", full, maxV, 0 },
		{ "mid-fade", mid, curveAt(bob, mid), 3 },
		{ "just inside silent edge", silent - 1, nil, 0 },
		{ "at the silent edge", silent, 0, 0 },
		{ "just beyond silent edge", silent + 1, 0, 0 },
		{ "far beyond", 5000, 0, 0 },
	}
	for _, case in ipairs(cases) do
		local label, d, exp, tol = case[1], case[2], case[3], case[4]
		local v = Sim.VolumeAt(w, "Bob", "Alice", d)
		if exp then
			t:near(v, exp, tol, label .. " (" .. d .. " yd)")
		else
			t:between(v, minV, maxV - 1, label .. " (" .. d .. " yd), fading but audible")
		end
	end
end)

T.test("walking away fades smoothly and ends silent", function(t)
	local w = Sim.Scenario(t, { players = { { name = "Bob", x = 0, y = 0 }, { name = "Alice", x = 3, y = 0 } } })
	t:eq(w:Hears("Bob", "Alice"), 100, "start: close")
	w:MoveTo("Alice", 80, 0, 7)
	local samples, prev, rises = {}, 100, 0
	for _ = 1, 30 do
		w:Advance(0.5)
		local v = w:Hears("Bob", "Alice")
		samples[#samples + 1] = tostring(v)
		if v and v > prev then rises = rises + 1 end
		prev = v or prev
	end
	w:Advance(5)
	t:eq(rises, 0, "volume never rises while walking away: " .. table.concat(samples, " "))
	t:eq(w:Hears("Bob", "Alice"), 0, "end: 80 yd away")
end)

T.test("walking closer is heard within 3 seconds of arrival", function(t)
	local w = Sim.Scenario(t, { players = { { name = "Bob", x = 0, y = 0 }, { name = "Alice", x = 100, y = 0 } } })
	t:eq(w:Hears("Bob", "Alice"), 0, "start: far")
	w:MoveTo("Alice", 5, 0, 7) -- 95 yd at 7 yd/s ~ 13.6 s
	w:Advance(13.6 + 3)
	t:eq(w:Hears("Bob", "Alice"), 100, "3 s after arriving 5 yd away")
end)

T.test("three players: near one loud, far one silent, at the same time", function(t)
	local w = Sim.Scenario(t, { players = {
		{ name = "Bob", x = 0, y = 0 }, { name = "Alice", x = 4, y = 3 }, { name = "Carol", x = -200, y = 50 } } })
	t:eq(w:Hears("Bob", "Alice"), 100, "Bob hears Alice (5 yd)")
	t:eq(w:Hears("Bob", "Carol"), 0, "Bob hears Carol (206 yd)")
	t:eq(w:Hears("Alice", "Bob"), 100, "Alice hears Bob")
	t:eq(w:Hears("Carol", "Bob"), 0, "Carol hears Bob")
end)

T.test("voice members with nil names are handled (beta behaviour)", function(t)
	local w = Sim.Scenario(t, { world = { voiceMemberNames = false },
		players = { { name = "Bob", x = 0, y = 0 }, { name = "Alice", x = 200, y = 0 } } })
	t:eq(w:Hears("Bob", "Alice"), 0, "far Alice silenced although members[i].name is nil")
	t:eq(#w:Get("Bob").voiceInvalid, 0, "SetMemberVolume calls with an unresolvable PlayerLocation")
end)

T.test("voice members with names also work", function(t)
	local w = Sim.Scenario(t, { world = { voiceMemberNames = true },
		players = { { name = "Bob", x = 0, y = 0 }, { name = "Alice", x = 200, y = 0 } } })
	t:eq(w:Hears("Bob", "Alice"), 0, "far Alice silenced")
end)

T.test("a member without the addon is silent by default (hearUnknown off)", function(t)
	local w = t:world()
	w:CreateCommunity({ members = { "Bob", "Zed" } })
	w:AddPlayer({ name = "Bob", x = 0, y = 0 })
	w:AddPlayer({ name = "Zed", x = 3, y = 0, addon = false }) -- plays without Hark installed
	w:Advance(1)
	Sim.JoinVoice(w, "Bob")
	w:UserJoinsVoice("Zed")
	w:Advance(Sim.SETTLE)
	local db = w:Get("Bob"):Global("HarkDB") or {}
	t:eq(w:Hears("Bob", "Zed"), db.hearUnknown and 100 or 0, "Bob hears addon-less Zed (hearUnknown=" .. tostring(db.hearUnknown) .. ")")
end)

-- Restoring ---------------------------------------------------------------

local function allRestored(t, w, listener, label)
	local l = w:Get(listener)
	local base = w.options.baselineMemberVolume
	for guid, v in pairs(l.voice.volumes) do
		local who = w.byGUID[guid] and w.byGUID[guid].name or guid
		t:eq(v, base, label .. ": " .. listener .. "'s volume for " .. who)
	end
	for guid in pairs(l.voice.muted) do
		t:fail(label .. ": " .. listener .. " still has " .. (w.byGUID[guid] and w.byGUID[guid].name or guid) .. " muted")
	end
end

local function farScenario(t)
	local w = Sim.Scenario(t, { players = { { name = "Bob", x = 0, y = 0 }, { name = "Alice", x = 300, y = 0 }, { name = "Carol", x = 27, y = 0 } } })
	t:require(w:Hears("Bob", "Alice") == 0, "precondition: Bob has Alice silenced, got " .. tostring(w:Hears("Bob", "Alice")))
	return w
end

T.test("/hark off restores every volume", function(t)
	local w = farScenario(t)
	w:Get("Bob"):Slash("/hark off")
	w:Advance(1)
	allRestored(t, w, "Bob", "after /hark off")
	w:Advance(Sim.SETTLE)
	allRestored(t, w, "Bob", "still, 20 s after /hark off")
end)

T.test("/hark leave restores every volume", function(t)
	local w = farScenario(t)
	w:Get("Bob"):Slash("/hark leave")
	w:Advance(2)
	t:ok(not w:InVoice("Bob"), "Bob left voice")
	allRestored(t, w, "Bob", "after /hark leave")
end)

T.test("leaving voice from the Blizzard UI restores every volume", function(t)
	local w = farScenario(t)
	w:UserLeavesVoice("Bob")
	w:Advance(2)
	allRestored(t, w, "Bob", "after leaving via the Communities UI")
end)

T.test("channel vanishing abruptly (no deactivate first) still restores", function(t)
	-- Depends on unverified client behaviour: whether a VoiceID PlayerLocation
	-- still resolves after its channel is gone. The mock says it does not;
	-- restoring by GUID works either way.
	local w = farScenario(t)
	w:UserLeavesVoice("Bob", true)
	w:Advance(2)
	allRestored(t, w, "Bob", "after the channel vanished")
end)

T.test("logging out restores every volume", function(t)
	local w = farScenario(t)
	w:Get("Bob"):Logout()
	allRestored(t, w, "Bob", "after logout")
end)

T.test("a silenced member who leaves the channel is restored", function(t)
	local w = farScenario(t)
	w:UserLeavesVoice("Alice")
	w:Advance(3)
	t:eq(w:VolumeSetting("Bob", "Alice"), w.options.baselineMemberVolume,
		"Bob's stored volume for Alice after she left (would otherwise stick if she rejoins without the addon)")
end)

T.test("/hark on after off re-applies proximity", function(t)
	local w = farScenario(t)
	local bob = w:Get("Bob")
	bob:Slash("/hark off")
	w:Advance(2)
	bob:Slash("/hark on")
	w:Advance(Sim.SETTLE)
	t:eq(w:Hears("Bob", "Alice"), 0, "far Alice silenced again")
end)

T.test("/reload while in voice keeps proximity working", function(t)
	local w = farScenario(t)
	w:Get("Bob"):Reload()
	w:Advance(Sim.SETTLE)
	t:eq(w:Hears("Bob", "Alice"), 0, "far Alice still silenced after Bob reloads")
	w:SetPosition("Alice", 5, 0)
	w:Advance(Sim.SETTLE)
	t:eq(w:Hears("Bob", "Alice"), 100, "and heard when she comes close")
end)
