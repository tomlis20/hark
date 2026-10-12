--- The volume curve as a pure function, through the addon's namespace.
-- Skipped if the addon does not expose Hark:GetVolumeForDistance.
local T = ...

local function curve(t)
	local w = t:world()
	local c = w:AddPlayer({ name = "Alice" })
	local ns = c:NS()
	if not (ns and type(ns.GetVolumeForDistance) == "function") then t:skip("no Hark:GetVolumeForDistance") end
	return function(d) return ns:GetVolumeForDistance(d) end, ns, c
end

T.test("curve: full volume from touching to the full-voice edge", function(t)
	local v, ns = curve(t)
	local full, maxV = ns.db.fullVoiceRange, ns.db.maxVolume
	t:eq(v(0), maxV, "touching (0 yd)")
	t:eq(v(full / 2), maxV, "half the full-voice range")
	t:eq(v(full), maxV, "exactly at the full-voice edge")
end)

T.test("curve: fades between the edges, never outside [min, max]", function(t)
	local v, ns = curve(t)
	local db = ns.db
	local prev = v(db.fullVoiceRange)
	for d = db.fullVoiceRange + 0.5, db.silentRange - 0.5, 0.5 do
		local x = v(d)
		t:between(x, db.minVolume, db.maxVolume, "volume at " .. d .. " yd")
		t:ok(x <= prev, string.format("not monotonic: %s yd -> %s after %s", d, tostring(x), tostring(prev)))
		prev = x
	end
	local mid = v((db.fullVoiceRange + db.silentRange) / 2)
	t:ok(mid > db.minVolume and mid < db.maxVolume, "mid-fade strictly between min and max, got " .. tostring(mid))
end)

T.test("curve: silent at and beyond the silent edge", function(t)
	local v, ns = curve(t)
	local silent = ns.db.silentRange
	t:eq(v(silent), 0, "exactly at the silent edge")
	t:eq(v(silent + 0.01), 0, "just beyond")
	t:eq(v(10000), 0, "far beyond")
	t:eq(v(math.huge), 0, "infinite distance")
end)

T.test("curve: nil and NaN distance are silent", function(t)
	local v = curve(t)
	t:eq(v(nil), 0, "nil distance")
	t:eq(v(0 / 0), 0, "NaN distance")
end)

T.test("curve: every fade curve hits the same end points", function(t)
	local v, ns = curve(t)
	for _, name in ipairs({ "linear", "natural", "smooth" }) do
		ns:Set("fadeCurve", name)
		t:eq(v(ns.db.fullVoiceRange), ns.db.maxVolume, name .. " at full edge")
		t:eq(v(ns.db.silentRange - 0.001) >= ns.db.minVolume, true, name .. " just inside silent edge is >= minVolume")
		t:eq(v(ns.db.silentRange), 0, name .. " at silent edge")
	end
end)

T.test("curve: respects changed ranges", function(t)
	local v, ns = curve(t)
	ns:Set("silentRange", 100)
	ns:Set("fullVoiceRange", 50)
	t:eq(v(50), ns.db.maxVolume, "new full edge")
	t:eq(v(100), 0, "new silent edge")
	t:ok(v(75) > 0 and v(75) < 100, "mid of new range")
end)
