--- Hark: position sharing and layer detection
-- Every Hark user broadcasts their own position over hidden addon messages
-- (GUILD and/or PARTY / RAID / INSTANCE_CHAT; custom channels and YELL do not
-- work on Forever). Received positions are keyed by player GUID, which is also
-- what the voice API gives us for each voice member.

local _, ns = ...
local Hark = ns.Hark

local Positions = {}
Hark.Positions = Positions

local PREFIX = "Hark"
local MSG_VERSION = "P1"

local TICK = 1              -- seconds between cheap "should I send?" checks
local SEND_MOVED = 2        -- min seconds between sends while moving
local SEND_IDLE = 15        -- heartbeat while standing still
local SEND_MIN_GAP = 1      -- never send twice within this, even when forced
local MOVE_THRESHOLD = 2    -- yards before a move counts
local STALE_AFTER = 45      -- seconds before a received position is forgotten
local MAX_COORD = 100000    -- yards; anything larger in a message is not a real position
local SEQ_MAX = 999999      -- sequence numbers wrap here (6 digits on the wire)
local RECENT_MOVE = 3       -- seconds a received move counts as "someone is moving"

-- Own send budget, well inside the server's 10-burst / 1-per-second per prefix.
local BUCKET_CAPACITY = 4
local BUCKET_RATE = 0.5     -- tokens per second (one message every 2 s sustained)

-- Layer (zone copy) detection
local LAYER_SAMPLE_TTL = 600   -- seconds a creature sample stays valid
local LAYER_MAX_SAMPLES = 30
local LAYER_SCAN_EVERY = 15    -- seconds between nameplate scans
local LAYER_CACHE_TTL = 1800   -- seconds a per-zone cached layer is offered as a hint
local MAX_NAMEPLATES = 40

local VALID_CHANNELS = { GUILD = true, PARTY = true, RAID = true, INSTANCE_CHAT = true }

-- Send results (Enum.SendAddonMessageResult), with literal fallbacks
local RESULT = Enum and Enum.SendAddonMessageResult or {}
local RESULT_SUCCESS = RESULT.Success or 0
local RESULT_THROTTLED = RESULT.AddonMessageThrottle or 3

local known = {}          -- [guid] = record, see Positions:Get
local lastSent = { time = 0 }
-- Receivers drop a sequence number at or below the last one they hold for
-- STALE_AFTER, so a /reload that restarted at 1 would be ignored for 45 s.
-- Start each session from the server clock instead: it advances 2 per second
-- while sends average at most 0.5 per second, so a new session always starts
-- above the last one. Wraps like the counter itself (receivers accept a
-- backwards jump of 1000 or more).
local seq = 0
do
	local ok, now = false, nil
	if type(GetServerTime) == "function" then ok, now = pcall(GetServerTime) end
	if not ok and now ~= nil then Hark._RecordError("GetServerTime", now) end
	now = ok and not Hark.IsSecret(now) and tonumber(now) or nil
	if now and now == now and now ~= math.huge then seq = math.floor(now * 2) % SEQ_MAX end
end
local pinnedName = {}     -- [guid] = sender name that first claimed it, when the client cannot verify GUIDs
local bucket = { tokens = BUCKET_CAPACITY, time = 0 }
local forcePending = false
local guidToUnit = {}     -- group members only, rebuilt on roster changes
local rosterDirty = true

-- Seen positions (CONTRACT 10.2): players we can see as a unit token, whether or
-- not they send messages. seen[guid] = { unit, x, y, instance, time, name, movedAt }.
-- `unit` is a token currently showing that player (nil once it is gone); x, y,
-- instance and time are the last live read, kept for STALE_AFTER after it.
local seen = {}
local unitGUID = {}       -- [token] = player GUID it showed when last tracked

-- layer state
local zoneKey = nil
local samples = {}        -- [creatureGUID] = { layer = n, time = t }
local layer, layerConfident = nil, false
local layerCache = {}     -- [zoneKey] = { layer = n, time = t }

local ticker, scanTicker

-- Diagnostics (/hark selftest): the last SendAddonMessage result per chat type.
local sendLog = { count = 0, last = {} } -- last[chatType] = { result, seq, t }

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------

local function Round(v)
	return math.floor(v + 0.5)
end

-- Names for the functions passed to Call, looked up only when one fails.
local CALL_NAMES = {
	"C_Map.GetBestMapForUnit", "C_Map.GetMapInfo", "GetPlayerInfoByGUID", "UnitIsVisible",
	"UnitIsDeadOrGhost", "C_ChatInfo.RegisterAddonMessagePrefix",
}

local function NameOf(fn)
	for _, path in ipairs(CALL_NAMES) do
		local owner, field = path:match("^([%w_]+)%.([%w_]+)$")
		local v
		if owner then
			local t = _G[owner]
			v = type(t) == "table" and t[field] or nil
		else
			v = _G[path]
		end
		if v == fn then return path end
	end
	return "Positions.Call"
end

-- A swallowed error still reaches HarkDB.errors (Core, diagnostics).
local function PassResults(fn, ok, ...)
	if ok then return ... end
	Hark._RecordError(NameOf(fn), (...))
	return nil
end

-- Protected call: a missing or failing function returns nil instead of erroring.
local function Call(fn, ...)
	if type(fn) ~= "function" then return nil end
	return PassResults(fn, pcall(fn, ...))
end

local function MyGUID()
	local guid = UnitGUID("player")
	if guid == nil or Hark.IsSecret(guid) then return nil end
	return guid
end

-- A client value addon code may inspect: nil when it is a secret value.
-- Secrets cannot be compared, tested, used as table keys or in arithmetic by
-- addon code (warcraft.wiki.gg/wiki/Secret_values), so every value read from
-- the client is passed through this before any of those.
local function Plain(v)
	if v == nil or Hark.IsSecret(v) then return nil end
	return v
end

-- Position of a unit in yards: a, b, instanceID. UnitPosition returns
-- (y, x, z, instanceID); only the 1st, 2nd and 4th values matter and we keep the
-- same order everywhere, so distances are correct whatever the axis naming.
local function UnitXY(unit)
	local a, b, _, instance = UnitPosition(unit)
	a, b, instance = Plain(a), Plain(b), Plain(instance)
	if type(a) ~= "number" or type(b) ~= "number" then return nil end
	return a, b, instance
end

-- Zone-level uiMapID for the player: the key under which layer ids are comparable.
local function CurrentZoneKey()
	if not (C_Map and C_Map.GetBestMapForUnit) then return nil end
	local mapID = Call(C_Map.GetBestMapForUnit, "player")
	if not mapID or Hark.IsSecret(mapID) then return nil end
	local zoneType = Enum and Enum.UIMapType and Enum.UIMapType.Zone or 3
	local guard = 0
	while mapID and guard < 6 do
		local info = C_Map.GetMapInfo and Call(C_Map.GetMapInfo, mapID)
		if type(info) ~= "table" or Hark.IsSecret(info) then break end
		local mapType, parent = Plain(info.mapType), Plain(info.parentMapID)
		if type(mapType) ~= "number" or mapType <= zoneType or type(parent) ~= "number" or parent == 0 then
			break
		end
		mapID = parent
		guard = guard + 1
	end
	return mapID
end

local function InInstance()
	local inInstance, instanceType = IsInInstance()
	inInstance, instanceType = Plain(inInstance), Plain(instanceType)
	return inInstance and instanceType ~= "none", instanceType
end

local function InstanceMapID()
	local id = Plain((select(8, GetInstanceInfo())))
	return tonumber(id)
end

local function SplitName(full)
	if type(full) ~= "string" then return nil end
	return (full:match("^([^%-]+)")) or full
end

local function RealmOf(full)
	if type(full) ~= "string" then return nil end
	return full:match("^[^%-]+%-(.+)$")
end

local function NormRealm(r)
	return (tostring(r or ""):gsub("[%s%-]", ""))
end

---------------------------------------------------------------------------
-- Group roster (for direct, always fresh UnitPosition reads)
---------------------------------------------------------------------------

local function GroupUnits()
	local units = {}
	if IsInRaid() then
		for i = 1, GetNumGroupMembers() do units[#units + 1] = "raid" .. i end
	elseif IsInGroup() then
		for i = 1, GetNumSubgroupMembers() do units[#units + 1] = "party" .. i end
	end
	return units
end

local function RebuildRoster()
	rosterDirty = false
	wipe(guidToUnit)
	for _, unit in ipairs(GroupUnits()) do
		local guid = Plain(UnitGUID(unit))
		if guid then guidToUnit[guid] = unit end
	end
end

local function UnitForGUID(guid)
	if rosterDirty then RebuildRoster() end
	local unit = guidToUnit[guid]
	if unit and Plain(UnitGUID(unit)) == guid then return unit end
	return nil
end

---------------------------------------------------------------------------
-- Seen positions (visible player units)
---------------------------------------------------------------------------

local function PlayerGUIDOf(unit)
	if not Plain(UnitExists(unit)) then return nil end
	if not Plain(UnitIsPlayer(unit)) then return nil end
	local guid = Plain(UnitGUID(unit))
	if type(guid) ~= "string" or guid == MyGUID() then return nil end
	return guid
end

-- Live read of a unit into the seen record. Returns true when it had coordinates.
local function Snapshot(s, unit)
	local x, y, instance = UnitXY(unit)
	if not x then return false end
	local now = GetTime()
	if s.x and instance == s.instance and ((x - s.x) ^ 2 + (y - s.y) ^ 2) > MOVE_THRESHOLD ^ 2 then
		s.movedAt = now
	end
	s.x, s.y, s.instance, s.time = x, y, instance, now
	return true
end

-- A token stopped showing its player: keep the last read, drop the token.
local function ReleaseUnit(unit)
	local guid = unitGUID[unit]
	if not guid then return end
	unitGUID[unit] = nil
	local s = seen[guid]
	if s and s.unit == unit then
		s.unit = nil
		-- Another token may still show the same player (target and nameplate).
		for other, g in pairs(unitGUID) do
			if g == guid then s.unit = other break end
		end
	end
end

-- (Re)read a token: called from events and the periodic scan.
local function TrackUnit(unit)
	if not unit then return end
	local guid = PlayerGUIDOf(unit)
	if unitGUID[unit] and unitGUID[unit] ~= guid then ReleaseUnit(unit) end
	if not guid then return end
	unitGUID[unit] = guid
	local s = seen[guid]
	if not s then
		s = { guid = guid }
		seen[guid] = s
	end
	s.unit = unit
	if not s.name then
		local name, realm = UnitName(unit)
		name, realm = Plain(name), Plain(realm)
		if type(name) == "string" and name ~= "" then
			if type(realm) == "string" and realm ~= "" then name = name .. "-" .. realm end
			s.name = name
		end
	end
	Snapshot(s, unit)
end

-- Token currently showing guid, verified (target and mouseover change without
-- a removal event), or nil.
local function SeenUnit(guid)
	local s = seen[guid]
	if not s then return nil end
	while s.unit do
		local unit = s.unit
		if PlayerGUIDOf(unit) == guid then return unit end
		if unitGUID[unit] == guid then ReleaseUnit(unit) else s.unit = nil end
	end
	return nil
end

-- true when the token proves the player is drawn by our client, so on our layer.
local function ProvesSameLayer(unit)
	if unit:find("^nameplate") then return true end
	local visible = Plain(Call(UnitIsVisible, unit))
	return visible == true
end

-- Fresh seen record for guid (live read when a token shows them), or nil.
local function FreshSeen(guid)
	local s = seen[guid]
	if not s then return nil end
	local unit = SeenUnit(guid)
	if unit then Snapshot(s, unit) end
	if not s.time or GetTime() - s.time > STALE_AFTER then
		if not unit then seen[guid] = nil end
		return nil
	end
	return s, unit
end

-- Drop received records nobody has refreshed within STALE_AFTER. GetDistance
-- only ever looks at voice members, so without this every guild member who
-- once sent a position would be held for the whole session.
local function PruneKnown()
	local now = GetTime()
	for guid, rec in pairs(known) do
		if now - rec.time > STALE_AFTER then known[guid] = nil end
	end
	-- Pins only matter while a record is held; this also bounds the table
	-- against a sender spraying made-up GUIDs.
	for guid in pairs(pinnedName) do
		if not known[guid] then pinnedName[guid] = nil end
	end
end

local function PruneSeen()
	for i = 1, MAX_NAMEPLATES do
		local unit = "nameplate" .. i
		if UnitExists(unit) then TrackUnit(unit) elseif unitGUID[unit] then ReleaseUnit(unit) end
	end
	TrackUnit("target")
	TrackUnit("mouseover")
	for guid in pairs(seen) do FreshSeen(guid) end
end

---------------------------------------------------------------------------
-- Layer detection
---------------------------------------------------------------------------

-- A layer hop: the newest samples all agree on one layer and at least two of
-- them are newer than every sample of any other layer. The old layer's
-- creatures are no longer drawn, so their samples only age; without this they
-- would outvote the new layer for up to LAYER_SAMPLE_TTL and keep a stale
-- layer "confirmed". Samples taken in the same scan share a timestamp, so
-- creatures of two layers seen together never trigger it.
local function DropSupersededSamples()
	local newest = {} -- [layer] = newest sample time
	for _, s in pairs(samples) do
		if not newest[s.layer] or s.time > newest[s.layer] then newest[s.layer] = s.time end
	end
	local top, topTime
	for id, t in pairs(newest) do
		if not topTime or t > topTime then top, topTime = id, t end
	end
	if not top then return end
	local others = nil
	for id, t in pairs(newest) do
		if id ~= top and (not others or t > others) then others = t end
	end
	if not others then return end
	local fresh = 0
	for _, s in pairs(samples) do
		if s.layer == top and s.time > others then fresh = fresh + 1 end
	end
	if fresh < 2 then return end
	for guid, s in pairs(samples) do
		if s.layer ~= top then samples[guid] = nil end
	end
end

local function RecomputeLayer()
	local now = GetTime()
	DropSupersededSamples()
	local votes, count = {}, 0
	for guid, s in pairs(samples) do
		if now - s.time > LAYER_SAMPLE_TTL then
			samples[guid] = nil
		else
			votes[s.layer] = (votes[s.layer] or 0) + 1
			count = count + 1
		end
	end

	local best, bestVotes, secondVotes = nil, 0, 0
	for id, n in pairs(votes) do
		if n > bestVotes then
			best, secondVotes, bestVotes = id, bestVotes, n
		elseif n > secondVotes then
			secondVotes = n
		end
	end

	local newLayer, newConfident
	if best then
		newLayer = best
		newConfident = bestVotes >= 2 and bestVotes > secondVotes
	else
		-- Nothing sampled during this visit: offer the cached value as a hint only.
		local cached = zoneKey and layerCache[zoneKey]
		if cached and now - cached.time < LAYER_CACHE_TTL then
			newLayer = cached.layer
		end
		newConfident = false
	end

	if newConfident and zoneKey then
		layerCache[zoneKey] = { layer = newLayer, time = now }
	end

	if newLayer ~= layer or newConfident ~= layerConfident then
		local hadConfidentLayer = layerConfident and layer
		layer, layerConfident = newLayer, newConfident
		Hark:Debug(string.format("layer %s (%s, %d samples)", tostring(layer), layerConfident and "confirmed" or "unconfirmed", count))
		Hark:Fire("LAYER_CHANGED", layer, layerConfident)
		if layerConfident or hadConfidentLayer then forcePending = true end
	end
end

local function PruneSamples()
	local n, oldestGUID, oldestTime = 0, nil, math.huge
	for guid, s in pairs(samples) do
		n = n + 1
		if s.time < oldestTime then oldestGUID, oldestTime = guid, s.time end
	end
	if n > LAYER_MAX_SAMPLES and oldestGUID then samples[oldestGUID] = nil end
end

-- Read the zone copy id from a unit's GUID, if it is a real world creature.
local function SampleUnit(unit)
	if not unit or not Plain(UnitExists(unit)) then return end
	local isPlayer, controlled = UnitIsPlayer(unit), UnitPlayerControlled(unit)
	if Hark.IsSecret(isPlayer) or Hark.IsSecret(controlled) then return end
	if isPlayer or controlled then return end -- skip players, pets, guardians
	if InInstance() then return end
	local guid = Plain(UnitGUID(unit))
	if type(guid) ~= "string" then return end
	-- Creature-0-[serverID]-[instanceID]-[zoneUID]-[npcID]-[spawnUID]
	local unitType, _, _, _, zoneUID = strsplit("-", guid)
	if unitType ~= "Creature" and unitType ~= "Vehicle" then return end
	zoneUID = tonumber(zoneUID)
	if not zoneUID or zoneUID <= 0 then return end
	local existing = samples[guid]
	if existing and existing.layer == zoneUID then
		existing.time = GetTime()
		return
	end
	samples[guid] = { layer = zoneUID, time = GetTime() }
	PruneSamples()
	RecomputeLayer()
end

local function ScanNameplates()
	SampleUnit("target")
	for i = 1, MAX_NAMEPLATES do
		local unit = "nameplate" .. i
		if UnitExists(unit) then SampleUnit(unit) end
	end
	RecomputeLayer() -- expires old samples even when nothing new was seen
	PruneSeen()
	PruneKnown()
end

local function OnZoneMaybeChanged()
	local key = CurrentZoneKey()
	if key == zoneKey then return end
	zoneKey = key
	wipe(samples)
	layer, layerConfident = nil, false
	RecomputeLayer()
	Hark:Fire("LAYER_CHANGED", layer, layerConfident)
	forcePending = true
end

---------------------------------------------------------------------------
-- Sending
---------------------------------------------------------------------------

local function RefillBucket()
	local now = GetTime()
	bucket.tokens = math.min(BUCKET_CAPACITY, bucket.tokens + (now - bucket.time) * BUCKET_RATE)
	bucket.time = now
end

-- Chat types to send on. Group copy is skipped when every group member is
-- already reached through GUILD.
local function Targets()
	local targets = {}
	local inGuild = IsInGuild()
	if inGuild then targets[#targets + 1] = "GUILD" end

	local groupType
	if LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
		groupType = "INSTANCE_CHAT"
	elseif IsInRaid() then
		groupType = "RAID"
	elseif IsInGroup() then
		groupType = "PARTY"
	end
	if groupType then
		local needed = not inGuild
		if not needed then
			for _, unit in ipairs(GroupUnits()) do
				if UnitExists(unit) and not UnitIsUnit(unit, "player") and not UnitIsInMyGuild(unit) then
					needed = true
					break
				end
			end
		end
		if needed then targets[#targets + 1] = groupType end
	end
	return targets
end

local function BuildMessage(x, y, instance)
	local flags = ""
	if Plain(UnitIsDeadOrGhost("player")) then flags = flags .. "d" end
	local sx, sy, sinst = "", "", ""
	if x then
		sx, sy, sinst = tostring(Round(x)), tostring(Round(y)), tostring(instance or 0)
	else
		flags = flags .. "h"
		local inInstance = InInstance()
		if inInstance then sinst = tostring(InstanceMapID() or "") end
	end
	local sendLayer = (Hark.db.layerAware and layerConfident and layer) or 0
	seq = seq + 1
	if seq > SEQ_MAX then seq = 1 end
	-- P1,<seq>,<guid>,<instance>,<x>,<y>,<zoneKey>,<layer>,<flags>
	-- %.0f for the layer: it is a creature-GUID zoneUID fragment with no documented
	-- bound, and this client's %d raises above 2^31. seq stays %d (wraps at SEQ_MAX).
	return string.format("%s,%d,%s,%s,%s,%s,%s,%.0f,%s", MSG_VERSION, seq, MyGUID() or "",
		sinst, sx, sy, tostring(zoneKey or 0), sendLayer, flags)
end

local function Send(force)
	local guid = MyGUID()
	if not guid then return false end
	local targets = Targets()
	if #targets == 0 then return true end -- nobody to tell; not an error

	RefillBucket()
	if bucket.tokens < #targets then return false end -- wait for budget, retried next tick

	local x, y, instance = UnitXY("player")
	local msg = BuildMessage(x, y, instance)
	for _, chatType in ipairs(targets) do
		bucket.tokens = bucket.tokens - 1
		-- Forever returns one result code; pre-11.0 clients returned (bool, code).
		local ok, r1, r2 = pcall(C_ChatInfo.SendAddonMessage, PREFIX, msg, chatType)
		if not ok then Hark._RecordError("C_ChatInfo.SendAddonMessage", r1) end
		local result = not ok and -1 or (type(r2) == "number" and r2 or r1)
		if Hark.IsSecret(result) then result = "secret" end
		sendLog.last[chatType] = { result = result, seq = seq, t = Hark._diag.ClockNow() }
		Hark._Trace({ k = "tx", ch = chatType, res = result, seq = seq })
		if result == RESULT_THROTTLED then
			bucket.tokens = 0
			Hark:Debug("send throttled on " .. chatType)
		elseif type(result) == "number" and result ~= RESULT_SUCCESS then
			Hark:Debug("send on " .. chatType .. " failed with result " .. result)
		end
	end
	lastSent.x, lastSent.y, lastSent.instance, lastSent.time = x, y, instance, GetTime()
	sendLog.count = sendLog.count + 1
	return true
end

-- Called every TICK seconds while enabled and in voice.
local function OnTick()
	if not Hark:IsEnabled() then return end
	if not (Hark.Voice and Hark.Voice:IsActive()) then return end

	local now = GetTime()
	if now - lastSent.time < SEND_MIN_GAP then return end

	local x, y, instance = UnitXY("player")
	local moved = instance ~= lastSent.instance
		or (x == nil) ~= (lastSent.x == nil)
		or (x and lastSent.x and ((x - lastSent.x) ^ 2 + (y - lastSent.y) ^ 2) > MOVE_THRESHOLD ^ 2)

	local due = forcePending
		or (moved and now - lastSent.time >= SEND_MOVED)
		or (now - lastSent.time >= SEND_IDLE)
	if due and Send() then forcePending = false end
end

--- Ask for a position send soon. Many calls in a burst collapse into one send,
-- which still goes through the send budget. Never sends synchronously.
function Positions:RequestBroadcast()
	forcePending = true
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------

-- Integer field: "" (allowed when emptyOK) or optional minus and at most
-- maxDigits digits. Rejects "nan", "inf", "0x10", "1e5", spaces.
local function IntField(s, maxDigits, emptyOK)
	if s == "" then return emptyOK and "" or nil end
	local digits = s:match("^%-?(%d+)$")
	if not digits or #digits > maxDigits then return nil end
	return tonumber(s)
end

-- Does the sender own the GUID it claims? Messages are attacker-controlled:
-- anyone in the guild or group can send on the prefix. The client names the
-- GUID's owner when it has seen that player; otherwise the GUID is pinned to
-- the first sender name that claimed it, so a later impostor cannot take over
-- an established record (and a verified owner always replaces an impostor).
local function SenderOwns(guid, sender)
	local senderName = SplitName(sender)
	if not senderName or senderName == "" then return false end
	local _, _, _, _, _, guidName, guidRealm = Call(GetPlayerInfoByGUID, guid)
	guidName, guidRealm = Plain(guidName), Plain(guidRealm)
	if type(guidName) == "string" and guidName ~= "" then
		if guidName ~= senderName then return false end
		local senderRealm = RealmOf(sender)
		if type(guidRealm) == "string" and guidRealm ~= "" and senderRealm
			and NormRealm(guidRealm) ~= NormRealm(senderRealm) then
			return false
		end
		pinnedName[guid] = senderName
		return true
	end
	local pinned = pinnedName[guid]
	if pinned and pinned ~= senderName then return false end
	pinnedName[guid] = senderName
	return true
end

local function OnAddonMessage(prefix, text, channel, sender)
	if Hark.IsSecret(prefix) or Hark.IsSecret(text) or Hark.IsSecret(channel) or Hark.IsSecret(sender) then return end
	if prefix ~= PREFIX or type(channel) ~= "string" or not VALID_CHANNELS[channel] then return end
	if not Hark:IsEnabled() then return end
	if type(text) ~= "string" or type(sender) ~= "string" or #text > 255 then return end

	local v, sSeq, guid, sInst, sx, sy, sZone, sLayer, flags =
		strsplit(",", text)
	if v ~= MSG_VERSION or not flags then return end
	if not guid or not guid:match("^Player%-%d+%-%x+$") or #guid > 40 then return end
	if guid == MyGUID() then return end -- our own echo

	sSeq = IntField(sSeq, 9, false)
	if not sSeq or sSeq < 0 then return end
	local inst = IntField(sInst, 9, true)
	local x, y = IntField(sx, 9, true), IntField(sy, 9, true)
	local zone = IntField(sZone, 9, true)
	local msgLayer = IntField(sLayer, 12, true)
	if not inst or not x or not y or not zone or not msgLayer then return end
	if not flags:match("^%a*$") or #flags > 8 then return end
	if x ~= "" and math.abs(x) > MAX_COORD then return end
	if y ~= "" and math.abs(y) > MAX_COORD then return end
	if (x == "") ~= (y == "") then return end

	if not SenderOwns(guid, sender) then return end

	local now = GetTime()
	local rec = known[guid]
	if rec and SplitName(rec.name) ~= SplitName(sender) then
		-- An earlier, unverifiable claim by someone else: the verified owner wins.
		rec = nil
		known[guid] = nil
	end
	if rec then
		-- The server reorders messages: drop anything older than what we hold.
		-- A big backwards jump means the sender's counter wrapped (or an old
		-- client restarted it at 1).
		if now - rec.time < STALE_AFTER and sSeq <= rec.seq and rec.seq - sSeq < 1000 then return end
	else
		rec = { guid = guid }
		known[guid] = rec
	end

	local hidden = flags:find("h", 1, true) ~= nil
	if x == "" or hidden then x, y = nil, nil end
	if x and rec.x and ((x - rec.x) ^ 2 + (y - rec.y) ^ 2) > MOVE_THRESHOLD ^ 2 then
		rec.movedAt = now
	end

	rec.name = sender
	rec.seq = sSeq
	rec.time = now
	rec.x, rec.y = x, y
	rec.instance = inst ~= "" and inst or nil
	rec.hidden = hidden or x == nil
	rec.zone = zone ~= "" and zone or 0
	rec.layer = msgLayer ~= "" and msgLayer or 0
	rec.dead = flags:find("d", 1, true) ~= nil
	rec.channel = channel

	if Hark._diag.traceOn then
		Hark._TraceWho(guid, sender)
		Hark._Trace({ k = "rx", g = Hark._diag.ShortGUID(guid), seq = sSeq, x = rec.x, y = rec.y,
			z = rec.zone, l = rec.layer, ch = channel, f = flags ~= "" and flags or nil })
	end
	Hark:Fire("POSITION_RECEIVED", guid)
end

---------------------------------------------------------------------------
-- Queries (public)
---------------------------------------------------------------------------

--- Distance in yards from the player to another player, by GUID.
-- Returns distance, reason:
--   number,     "near"      both positions known, same instance, not on another layer
--   0,          "instance"  both inside the same dungeon/raid map and grouped
--   math.huge,  "elsewhere" other continent/instance, or their position is hidden
--   math.huge,  "layer"     same zone but a confirmed different layer (zone copy)
--   number,     "seen"      no message, but the client shows them as a unit (live
--                           UnitPosition, or the last read up to STALE_AFTER ago)
--   nil,        "unknown"   no fresh data (no addon, not in guild/group, or stale)
-- A fresh message wins over a seen position for the reason; while the player is
-- visible the distance itself is read live.
function Positions:GetDistance(guid)
	if not guid then return nil, "unknown" end
	local now = GetTime()
	local rec = known[guid]
	if rec and now - rec.time > STALE_AFTER then
		known[guid] = nil
		rec = nil
	end

	local myX, myY, myInstance = UnitXY("player")
	local unit = UnitForGUID(guid)
	local s, seenUnit = FreshSeen(guid)

	-- Inside a dungeon/raid positions are hidden; grouped players in the same map are together.
	if not myX then
		if unit and rec and rec.hidden and rec.instance and rec.instance == InstanceMapID() then
			return 0, "instance"
		end
		if rec then return math.huge, "elsewhere" end
		return nil, "unknown"
	end

	-- Layer check, only when both sides are confident and in the same zone.
	-- A player our client draws is on our layer whatever their message says.
	local provenHere = seenUnit and ProvesSameLayer(seenUnit)
	if rec and not provenHere and Hark.db.layerAware and layerConfident and layer and rec.layer and rec.layer ~= 0
		and rec.zone and rec.zone ~= 0 and rec.zone == zoneKey and rec.layer ~= layer then
		return math.huge, "layer"
	end

	-- Group members and visible units: read live. With a message it is "near"
	-- (the message supplies zone and layer); without one it is "seen".
	local liveUnit = unit or seenUnit
	if liveUnit then
		local x, y, instance = UnitXY(liveUnit)
		if x then
			if not s then
				s = seen[guid] or { guid = guid }
				seen[guid] = s
			end
			Snapshot(s, liveUnit)
			if instance ~= myInstance then return math.huge, "elsewhere" end
			return math.sqrt((x - myX) ^ 2 + (y - myY) ^ 2), rec and "near" or "seen"
		end
	end

	if not rec then
		-- Recently visible: last read, same continent only.
		if s and s.x and s.instance == myInstance then
			return math.sqrt((s.x - myX) ^ 2 + (s.y - myY) ^ 2), "seen"
		end
		return nil, "unknown"
	end
	if rec.hidden or not rec.x or rec.instance ~= myInstance then return math.huge, "elsewhere" end
	return math.sqrt((rec.x - myX) ^ 2 + (rec.y - myY) ^ 2), "near"
end

--- Distance to a unit token (party1, raid5, target...). Same returns as GetDistance.
function Positions:GetDistanceToUnit(unit)
	if not unit or not UnitExists(unit) then return nil, "unknown" end
	local guid = Plain(UnitGUID(unit))
	if type(guid) ~= "string" then return nil, "unknown" end
	return self:GetDistance(guid)
end

--- Copy of what we know about a player, or nil.
-- { guid, name ("Name-Realm"), x, y, instance, zone, layer, hidden, dead, age, source }
-- source is "message" (received position) or "seen" (visible unit; zone and
-- layer are nil, name may be nil).
function Positions:Get(guid)
	local rec = known[guid]
	if rec and GetTime() - rec.time <= STALE_AFTER then
		return {
			guid = rec.guid, name = rec.name, x = rec.x, y = rec.y, instance = rec.instance,
			zone = rec.zone, layer = rec.layer, hidden = rec.hidden, dead = rec.dead,
			age = GetTime() - rec.time, source = "message",
		}
	end
	local s, unit = FreshSeen(guid)
	if not s or not s.x then return nil end
	local dead = unit and Plain(Call(UnitIsDeadOrGhost, unit))
	return {
		guid = guid, name = s.name, x = s.x, y = s.y, instance = s.instance,
		zone = nil, layer = nil, hidden = false, dead = dead == true,
		age = GetTime() - s.time, source = "seen",
	}
end

--- "Name-Realm" for a GUID from received positions, or nil.
function Positions:GetName(guid)
	local rec = known[guid]
	return rec and rec.name
end

--- Number of fresh positions held.
function Positions:Count()
	local n, now = 0, GetTime()
	for _, rec in pairs(known) do
		if now - rec.time <= STALE_AFTER then n = n + 1 end
	end
	return n
end

--- true when any received position moved within the last few seconds.
function Positions:AnyoneMovingRecently()
	local now = GetTime()
	for _, rec in pairs(known) do
		if rec.movedAt and now - rec.movedAt < RECENT_MOVE then return true end
	end
	for _, s in pairs(seen) do
		if s.movedAt and now - s.movedAt < RECENT_MOVE then return true end
	end
	return false
end

--- Player's current layer: layerId (number or nil), confident (bool), zoneKey (uiMapID or nil).
function Positions:GetLayer()
	return layer, layerConfident, zoneKey
end

--- Forget everything received (used when proximity is turned off).
function Positions:Clear()
	wipe(known)
	wipe(pinnedName)
	wipe(seen)
	wipe(unitGUID)
end

---------------------------------------------------------------------------
-- Init and events
---------------------------------------------------------------------------

function Positions:Init()
	if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
		Call(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX)
	end

	local frame = CreateFrame("Frame")
	frame:RegisterEvent("CHAT_MSG_ADDON")
	frame:RegisterEvent("GROUP_ROSTER_UPDATE")
	frame:RegisterEvent("PLAYER_GUILD_UPDATE")
	frame:RegisterEvent("PLAYER_ENTERING_WORLD")
	frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
	frame:RegisterEvent("PLAYER_TARGET_CHANGED")
	frame:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
	frame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
	frame:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
	frame:RegisterEvent("PLAYER_DEAD")
	frame:RegisterEvent("PLAYER_ALIVE")
	frame:RegisterEvent("PLAYER_UNGHOST")

	frame:SetScript("OnEvent", function(_, event, ...)
		if event == "CHAT_MSG_ADDON" then
			OnAddonMessage(...)
		elseif event == "PLAYER_TARGET_CHANGED" then
			SampleUnit("target")
			TrackUnit("target")
		elseif event == "UPDATE_MOUSEOVER_UNIT" then
			SampleUnit("mouseover")
			TrackUnit("mouseover")
		elseif event == "NAME_PLATE_UNIT_ADDED" then
			local unit = ...
			SampleUnit(unit)
			TrackUnit(unit)
		elseif event == "NAME_PLATE_UNIT_REMOVED" then
			ReleaseUnit((...))
		elseif event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_GUILD_UPDATE" then
			rosterDirty = true
			forcePending = true -- coalesced by the tick
		elseif event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
			OnZoneMaybeChanged()
			forcePending = true
		else -- death state changed
			forcePending = true
		end
	end)
	self.frame = frame

	Hark:RegisterCallback("ENABLED_CHANGED", Positions, function(_, on)
		if on then forcePending = true else Positions:Clear() end
	end)
	Hark:RegisterCallback("VOICE_STATE_CHANGED", Positions, function(_, state)
		if state == "active" then forcePending = true end
	end)
end

function Positions:OnLogin()
	bucket.time = GetTime()
	OnZoneMaybeChanged()
	if not ticker then ticker = C_Timer.NewTicker(TICK, OnTick) end
	if not scanTicker then scanTicker = C_Timer.NewTicker(LAYER_SCAN_EVERY, ScanNameplates) end
end

--- Internal, for /hark selftest only (Diagnostics.lua). Plain copies.
function Positions._Diag()
	local now = GetTime()
	local list = {}
	for guid, s in pairs(samples) do
		list[#list + 1] = { creature = guid, layer = s.layer, age = math.floor((now - s.time) * 10 + 0.5) / 10 }
	end
	local cache = {}
	for zone, c in pairs(layerCache) do cache[#cache + 1] = { zone = zone, layer = c.layer, age = math.floor(now - c.time) } end
	local last = {}
	for chatType, r in pairs(sendLog.last) do last[chatType] = { result = r.result, seq = r.seq, t = r.t } end
	local seenCount, knownCount = 0, 0
	for _ in pairs(seen) do seenCount = seenCount + 1 end
	for _ in pairs(known) do knownCount = knownCount + 1 end
	return {
		samples = list, layerCache = cache, zoneKey = zoneKey,
		sendCount = sendLog.count, lastSend = last, targets = Targets(),
		forcePending = forcePending, bucketTokens = bucket.tokens,
		seenCount = seenCount, knownCount = knownCount,
	}
end

ns.Positions = Positions
