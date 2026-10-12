--- Scenario helpers shared by the specs. They talk to the addon only through
-- the game client (slash commands, events, the voice engine), except where a
-- function is explicitly named for the addon's namespace (Sim.NS).

local Sim = {}

-- Long enough for at least one idle position broadcast and a volume pass,
-- short enough that nothing goes stale. Adjust if the addon's cadence changes.
Sim.SETTLE = 20

function Sim.NS(client)
	return client:NS()
end

--- fullVoiceRange, silentRange, minVolume, maxVolume as the addon sees them.
function Sim.Ranges(client)
	local ns = client:NS()
	local db = (ns and ns.db) or client:Global("HarkDB") or {}
	return db.fullVoiceRange or 15, db.silentRange or 40, db.minVolume or 30, db.maxVolume or 100
end

--- Put a player into the community voice channel. Tries the addon first
-- (/hark setcommunity + /hark join); if that has not produced a joined,
-- active channel within 3 seconds, joins at the engine level as the user
-- would from the Communities window, and returns false so a test can tell.
function Sim.JoinVoice(world, name, clubId, streamId)
	local c = world:Get(name)
	clubId, streamId = clubId or "23111161", streamId or "1"
	c:Slash("/hark setcommunity " .. clubId .. " " .. streamId)
	c:Slash("/hark join")
	world:Advance(3)
	if world:InVoice(name) then return true end
	world:UserJoinsVoice(name, clubId, streamId)
	world:Advance(1)
	return false
end

--- Standard scenario: listener Bob at (bx, by), speakers placed by the
-- caller, everyone in one guild, one community, one voice channel.
-- opts.players = { {name=..., x=..., y=...}, ... }   (first is the listener)
function Sim.Scenario(t, opts)
	opts = opts or {}
	local world = t:world(opts.world)
	local players = opts.players or { { name = "Bob", x = 0, y = 0 }, { name = "Alice", x = 5, y = 0 } }
	local names = {}
	for _, p in ipairs(players) do names[#names + 1] = p.name end
	world:CreateCommunity({ clubId = "23111161", streamId = "1", members = names })
	for _, p in ipairs(players) do world:AddPlayer(p) end
	world:Advance(1)
	local viaAddon = true
	for _, p in ipairs(players) do
		if not Sim.JoinVoice(world, p.name) then viaAddon = false end
	end
	if not viaAddon then t:note("addon did not join voice by itself; joined via Communities UI instead") end
	world:Advance(Sim.SETTLE)
	return world
end

--- Volume `listener` hears `speaker` at after placing speaker at distance d
-- on the +x axis from the listener, and settling.
function Sim.VolumeAt(world, listener, speaker, d, settle)
	local l = world:Get(listener)
	world:SetPosition(speaker, l.x + d, l.y)
	world:Advance(settle or Sim.SETTLE)
	return world:Hears(listener, speaker)
end

return Sim
