--- Hark: voice channel management and distance-based volumes
-- Joins the configured community's voice stream and sets each member's volume
-- from their distance. Voice members carry no name (member.name is nil on
-- Forever), so identity is always the GUID from C_VoiceChat.GetMemberGUID.
-- Every C_VoiceChat call goes through Call() so a missing function degrades.

local _, ns = ...
local Hark = ns.Hark

local Voice = {}
Hark.Voice = Voice

local PASS_FAST = 0.5          -- seconds between volume passes while anyone moves
local PASS_SLOW = 1.5          -- otherwise
local JOIN_TIMEOUT = 10        -- seconds before a join counts as failed
local LOGIN_DELAY = 5          -- the voice service needs a moment after login
local MIN_STEP = 2             -- smaller volume changes are not sent to the client
local AUTOJOIN_MIN_GAP = 30    -- seconds between automatic join attempts

local STATUS = Enum and Enum.VoiceChatStatusCode or {}
local STATUS_SUCCESS = STATUS.Success or 0

local channelID = nil          -- active voice channel id (VoiceChatID), only when it is ours
local state = "idle"           -- "idle" | "joining" | "active"
local members = {}             -- [guid] = info, see Voice:GetMembers
local memberGUIDs = {}         -- [memberID] = guid cache for the current channel
local overrides = {}           -- [guid] = volume 0-100, session only
local leftByHand = false
local lastAutoJoin = 0
local passTimer, nextPassAt = nil, 0
local joinTimer = nil
local rejoinTimer = nil        -- delayed Join after a community change; cancelled by Leave
local pendingJoin = nil        -- { key = "club:stream", untilT = t }: our latest request, until adopted or failed
local abandoned = {}           -- ["club:stream"] = GetTime() expiry: join requests we gave up on
local ignoredChannels = {}     -- [channelID] = expiry: channels from abandoned requests, never adopted
local ABANDON_TTL = 15          -- seconds; also how long a timed-out request may still be adopted

---------------------------------------------------------------------------
-- Protected API access
---------------------------------------------------------------------------

local function PassResults(ok, ...)
	if ok then return ... end
	return nil
end

--- Call C_VoiceChat[name](...) protected. Missing function or error -> nil.
local function Call(name, ...)
	local vc = C_VoiceChat
	if not vc or type(vc[name]) ~= "function" then return nil end
	return PassResults(pcall(vc[name], ...))
end

local function MakeLocationFromVoice(memberID, chanID)
	if memberID and chanID and PlayerLocation and PlayerLocation.CreateFromVoiceID then
		local ok, loc = pcall(PlayerLocation.CreateFromVoiceID, PlayerLocation, memberID, chanID)
		if ok and loc then return loc end
	end
	return nil
end

local function MakeLocationFromGUID(guid)
	if guid and PlayerLocation and PlayerLocation.CreateFromGUID then
		local ok, loc = pcall(PlayerLocation.CreateFromGUID, PlayerLocation, guid)
		if ok and loc then return loc end
	end
	return nil
end

local function Clamp(v)
	v = tonumber(v) or 0
	if v < 0 then v = 0 end
	if v > Hark.FULL_VOLUME then v = Hark.FULL_VOLUME end
	return math.floor(v + 0.5)
end

-- A client value addon code may inspect: nil when it is a secret value
-- (secrets cannot be compared, tested or used as table keys by addon code).
local function Plain(v)
	if v == nil or Hark.IsSecret(v) then return nil end
	return v
end

local function SameId(a, b)
	a, b = Plain(a), Plain(b)
	return a ~= nil and b ~= nil and tostring(a) == tostring(b)
end

local function JoinKey(clubId, streamId)
	return tostring(clubId) .. ":" .. tostring(streamId)
end

local function IsAbandoned(key)
	local untilT = key and abandoned[key]
	if not untilT then return false end
	if GetTime() > untilT then abandoned[key] = nil return false end
	return true
end

local function IsIgnoredChannel(id)
	local untilT = id and ignoredChannels[id]
	if not untilT then return false end
	if GetTime() > untilT then ignoredChannels[id] = nil return false end
	return true
end

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

local function SetState(newState)
	if state == newState then return end
	state = newState
	Hark:Fire("VOICE_STATE_CHANGED", state, channelID)
end

function Voice:IsAvailable()
	return C_VoiceChat ~= nil and type(C_VoiceChat.SetMemberVolume) == "function"
		and PlayerLocation ~= nil and PlayerLocation.CreateFromVoiceID ~= nil
end

--- true while we are in, and have activated, the configured community channel.
function Voice:IsActive()
	return state == "active" and channelID ~= nil
end

function Voice:GetState()
	return state
end

function Voice:GetChannelID()
	return channelID
end

-- Old name kept for anything still calling it.
Voice.GetActiveChannelID = Voice.GetChannelID

---------------------------------------------------------------------------
-- Community / stream resolution
---------------------------------------------------------------------------

--- Stream to use for a club: the saved streamId, else the club's General
-- stream, else "1" (the id the live test used).
function Voice:ResolveStreamId(clubId)
	if Hark.db.streamId then return Hark.db.streamId end
	if clubId and C_Club and C_Club.GetStreams then
		local ok, streams = pcall(C_Club.GetStreams, clubId)
		if ok and type(streams) == "table" and not Hark.IsSecret(streams) then
			local general = Enum and Enum.ClubStreamType and Enum.ClubStreamType.General or 0
			local best
			for _, s in ipairs(streams) do
				local sType = type(s) == "table" and not Hark.IsSecret(s) and Plain(s.streamType)
				local sId = sType ~= nil and Plain(s.streamId)
				if sType == general and sId ~= nil and (not best or (tonumber(sId) or 0) < (tonumber(best) or 0)) then
					best = sId
				end
			end
			if best then return tostring(best) end
		end
	end
	return "1"
end

local function IsOurChannel(channel)
	if type(channel) ~= "table" or Hark.IsSecret(channel) then return false end
	local clubId = Hark.db.communityId
	if not clubId or not SameId(channel.clubId, clubId) then return false end
	return SameId(channel.streamId, Voice:ResolveStreamId(clubId))
end

--- Communities the player belongs to: array of { clubId = string, name = string, clubType = number }.
function Voice:ListCommunities()
	local list = {}
	if not (C_Club and C_Club.GetSubscribedClubs) then return list end
	local ok, clubs = pcall(C_Club.GetSubscribedClubs)
	if not ok or type(clubs) ~= "table" or Hark.IsSecret(clubs) then return list end
	for _, club in ipairs(clubs) do
		local id = type(club) == "table" and not Hark.IsSecret(club) and Plain(club.clubId)
		if id then
			local name = Plain(club.name)
			list[#list + 1] = { clubId = tostring(id), name = type(name) == "string" and name or "?", clubType = Plain(club.clubType) }
		end
	end
	table.sort(list, function(a, b) return a.name < b.name end)
	return list
end

---------------------------------------------------------------------------
-- Volumes
---------------------------------------------------------------------------

--- The single place that calls C_VoiceChat.SetMemberVolume.
-- guid: member GUID (required). volume: 0-100. memberID: optional voice member id
-- in the current channel (preferred location; the GUID form is the fallback).
-- Note: the proximity pass recomputes volumes every 0.5-1.5 s, so a value set
-- here is overwritten unless an override is set with Voice:SetOverride.
-- allLocations: try every location form rather than stopping at the first that
-- builds. CreateFromVoiceID still returns a location after the channel has gone
-- away, and SetMemberVolume on it then silently does nothing, so a plain
-- "voice id or else guid" fallback never fires and the member stays quiet.
-- Restores pass true so that whichever form the client honours gets through.
--
-- Hark.db.lowered (crash recovery) is only cleared when the restore is known
-- to have landed: the voice-id location belonged to a member of the live
-- channel, or GetMemberVolume reads the new value back. A call that "succeeds"
-- on a stale location, or on a GUID location the client may not honour, keeps
-- the entry, so the next login (or the next pass that sees them) tries again.
-- An extra restore to 100 is harmless; a lost one leaves someone quiet.
local function ReadsBack(loc, volume)
	local v = Plain(Call("GetMemberVolume", loc))
	return type(v) == "number" and math.abs(v - volume) < 0.5
end

function Voice:SetVolumeFor(guid, volume, memberID, allLocations)
	if not guid then return false end
	volume = Clamp(volume)
	local vc = C_VoiceChat
	if not vc or type(vc.SetMemberVolume) ~= "function" then return false end

	-- The voice-id form is only meaningful while that member is in our channel.
	local liveVoice = memberID ~= nil and channelID ~= nil
		and Plain(Call("GetMemberGUID", memberID, channelID)) == guid
	local locVoice = MakeLocationFromVoice(memberID, channelID)
	local locGUID
	if allLocations or not liveVoice then locGUID = MakeLocationFromGUID(guid) end
	if not locVoice and not locGUID then return false end

	-- Record before calling, so nothing lowered is ever unlisted.
	if Hark.db and volume < Hark.FULL_VOLUME then Hark.db.lowered[guid] = true end

	local okVoice = locVoice ~= nil and pcall(vc.SetMemberVolume, locVoice, volume)
	local okGUID = locGUID ~= nil and pcall(vc.SetMemberVolume, locGUID, volume)
	if not okVoice and not okGUID then return false end

	local info = members[guid]
	if info then info.volume = volume end
	if Hark.db and volume >= Hark.FULL_VOLUME then
		local landed = (okVoice and liveVoice)
			or (okGUID and ReadsBack(locGUID, volume))
			or (okVoice and ReadsBack(locVoice, volume))
		if landed then Hark.db.lowered[guid] = nil end
	end
	return true
end

--- Set every member we know of, and everyone lowered in an earlier session,
-- back to full volume. Safe to call at any time, including logout.
function Voice:RestoreAllVolumes()
	for guid, info in pairs(members) do
		self:SetVolumeFor(guid, Hark.FULL_VOLUME, info.memberID, true)
		info.volume = Hark.FULL_VOLUME
		info.target = Hark.FULL_VOLUME
	end
	if Hark.db then
		for guid in pairs(Hark.db.lowered) do
			if not members[guid] then self:SetVolumeFor(guid, Hark.FULL_VOLUME, nil, true) end
		end
	end
	Hark:Fire("MEMBERS_UPDATED")
end

--- Pin a member to a fixed volume (0 = muted by the user, 100 = always heard),
-- or pass nil to return them to proximity. Session only.
function Voice:SetOverride(guid, volume)
	if not guid then return end
	overrides[guid] = volume ~= nil and Clamp(volume) or nil
	self:RequestPass(0)
end

function Voice:GetOverride(guid)
	return overrides[guid]
end

local function TargetVolume(guid)
	local db = Hark.db
	if overrides[guid] then return overrides[guid], nil, "override" end
	local distance, reason = Hark.Positions:GetDistance(guid)
	if reason == "near" or reason == "seen" or reason == "instance" then
		return Hark:GetVolumeForDistance(distance), distance, reason
	elseif reason == "unknown" then
		return db.hearUnknown and db.maxVolume or 0, nil, reason
	end
	return 0, distance, reason -- "elsewhere", "layer"
end

local function ResolveName(guid, memberID)
	local name = Hark.Positions:GetName(guid)
	if name then return name end
	local ok, _, _, _, _, _, n, realm = pcall(GetPlayerInfoByGUID, guid)
	n, realm = Plain(n), Plain(realm)
	if ok and type(n) == "string" and n ~= "" then
		if type(realm) == "string" and realm ~= "" then return n .. "-" .. realm end
		return n
	end
	local voiceName = Plain(Call("GetMemberName", memberID, channelID))
	if type(voiceName) == "string" and voiceName ~= "" then return voiceName end
	return nil
end

local function ScheduleNext()
	local fast = Hark.Positions:AnyoneMovingRecently()
	if not fast then
		local speed = Plain(GetUnitSpeed("player"))
		fast = type(speed) == "number" and speed > 0
	end
	Voice:RequestPass(fast and PASS_FAST or PASS_SLOW)
end

local function RunPass()
	passTimer = nil
	if not Voice:IsActive() or not Hark:IsEnabled() then return end

	local channel = Call("GetChannel", channelID)
	if type(channel) ~= "table" or Hark.IsSecret(channel) or type(channel.members) ~= "table" then
		ScheduleNext()
		return
	end

	local myGUID = Plain(UnitGUID("player"))
	local seen = {}
	for _, member in ipairs(channel.members) do
		local memberID = type(member) == "table" and not Hark.IsSecret(member) and Plain(member.memberID) or nil
		local guid = memberID and memberGUIDs[memberID]
		if memberID and not guid then
			guid = Plain(Call("GetMemberGUID", memberID, channelID))
			if type(guid) == "string" then memberGUIDs[memberID] = guid else guid = nil end
		end
		local isMe = guid ~= nil and (guid == myGUID or Plain(Call("IsMemberLocalPlayer", memberID, channelID)) == true)
		if guid and not isMe then
			seen[guid] = true
			local info = members[guid]
			if not info then
				info = { guid = guid }
				members[guid] = info
			end
			info.memberID = memberID
			info.isActive = Plain(member.isActive) and true or false
			info.isSpeaking = Plain(member.isSpeaking) and true or false
			info.name = info.name or ResolveName(guid, memberID)

			local target, distance, reason = TargetVolume(guid)
			info.target, info.distance, info.reason = target, distance, reason

			local applied = info.volume
			if applied == nil or math.abs(target - applied) >= MIN_STEP
				or (target ~= applied and (target == 0 or target == Hark.db.maxVolume)) then
				Voice:SetVolumeFor(guid, target, memberID)
			end
		end
	end

	-- Anyone who left the channel goes back to full volume.
	for guid, info in pairs(members) do
		if not seen[guid] then
			Voice:SetVolumeFor(guid, Hark.FULL_VOLUME, nil)
			members[guid] = nil
		end
	end

	Hark:Fire("MEMBERS_UPDATED")
	ScheduleNext()
end

--- Run a volume pass within `delay` seconds (default 0). Calls coalesce.
function Voice:RequestPass(delay)
	delay = delay or 0
	if not self:IsActive() then return end
	local now = GetTime()
	if passTimer and nextPassAt <= now + delay then return end
	if passTimer then passTimer:Cancel() end
	nextPassAt = now + delay
	passTimer = C_Timer.NewTimer(delay, RunPass)
end

local function StopPasses()
	if passTimer then passTimer:Cancel() end
	passTimer = nil
end

--- Snapshot of the channel's other members for display, sorted by distance.
-- Array of { guid, memberID, name, distance, reason, volume, target, override,
-- isSpeaking, isActive }. Fresh copies; safe to keep or modify.
function Voice:GetMembers()
	local list = {}
	for guid, info in pairs(members) do
		list[#list + 1] = {
			guid = guid, memberID = info.memberID, name = info.name,
			distance = info.distance, reason = info.reason,
			volume = info.volume, target = info.target, override = overrides[guid],
			isSpeaking = info.isSpeaking, isActive = info.isActive,
		}
	end
	table.sort(list, function(a, b)
		local da, db = a.distance or math.huge, b.distance or math.huge
		if da ~= db then return da < db end
		return (a.name or a.guid) < (b.name or b.guid)
	end)
	return list
end

---------------------------------------------------------------------------
-- Joining and leaving
---------------------------------------------------------------------------

local function CancelJoinTimer()
	if joinTimer then joinTimer:Cancel() end
	joinTimer = nil
end

local function CancelRejoin()
	if rejoinTimer then rejoinTimer:Cancel() end
	rejoinTimer = nil
end

-- A join we started is no longer wanted (Leave, community change). Its result
-- may still arrive; when it does, the channel is left instead of adopted.
local function AbandonPendingJoin()
	if pendingJoin and GetTime() <= pendingJoin.untilT then
		abandoned[pendingJoin.key] = GetTime() + ABANDON_TTL
	end
	pendingJoin = nil
end

-- Leave a channel that an abandoned request produced.
local function DropChannel(id)
	ignoredChannels[id] = GetTime() + ABANDON_TTL
	Call("DeactivateChannel", id)
	Call("LeaveChannel", id)
end

local function Adopt(id)
	CancelJoinTimer()
	pendingJoin = nil
	if channelID ~= id then
		wipe(memberGUIDs)
		wipe(members)
	end
	channelID = id
	SetState("active")
	Hark:Print("Joined proximity voice.")
	Voice:RequestPass(0)
end

-- Our channel went away or was deactivated: nobody stays quiet.
local function Detach(message)
	AbandonPendingJoin()
	CancelJoinTimer()
	StopPasses()
	Voice:RestoreAllVolumes()
	wipe(members)
	wipe(memberGUIDs)
	channelID = nil
	SetState("idle")
	if message then Hark:Print(message) end
	Hark:Fire("MEMBERS_UPDATED")
end

--- Join (and activate) the configured community voice stream.
-- Returns true when a join was started or we are already in, else false plus a message.
function Voice:Join()
	if not Hark.db then return false, "Not loaded yet." end
	if not self:IsAvailable() then return false, "Voice chat is not available on this client." end
	local clubId = Hark.db.communityId
	if not clubId then return false, "No community configured. Use /hark communities, then /hark setcommunity <id>." end
	leftByHand = false
	CancelRejoin()
	if self:IsActive() then return true end

	local streamId = self:ResolveStreamId(clubId)
	local key = JoinKey(clubId, streamId)
	-- One request at a time: a second Join while the first is in flight would
	-- send a duplicate request and restart the timeout.
	if state == "joining" and pendingJoin and pendingJoin.key == key then return true end
	if pendingJoin and pendingJoin.key ~= key then AbandonPendingJoin() end
	abandoned[key] = nil -- wanted again: a late result for it may be adopted

	if Plain(Call("IsLoggedIn")) == false then Call("Login") end

	local channel = Call("GetChannelForCommunityStream", clubId, streamId)
	local chanID = type(channel) == "table" and not Hark.IsSecret(channel) and Plain(channel.channelID) or nil
	if chanID then
		ignoredChannels[chanID] = nil
		if Plain(channel.isActive) then
			Adopt(chanID)
			return true
		end
		Call("ActivateChannel", chanID)
	else
		-- Returns nothing; the outcome arrives as VOICE_CHAT_CHANNEL_JOINED / ACTIVATED.
		Call("RequestJoinAndActivateCommunityStreamChannel", clubId, streamId)
	end

	pendingJoin = { key = key, untilT = GetTime() + JOIN_TIMEOUT + ABANDON_TTL }
	SetState("joining")
	CancelJoinTimer()
	joinTimer = C_Timer.NewTimer(JOIN_TIMEOUT, function()
		joinTimer = nil
		if state == "joining" then
			-- The request may have completed without an event we recognised.
			local ch = Call("GetChannelForCommunityStream", clubId, streamId)
			local id = type(ch) == "table" and not Hark.IsSecret(ch) and Plain(ch.channelID) or nil
			if id and Plain(ch.isActive) then
				Adopt(id)
			else
				-- pendingJoin stays for a while: a late success is still adopted
				-- unless the player leaves or switches community first.
				SetState("idle")
				Hark:Print("Could not join the community voice channel. Check that the community has voice enabled.")
			end
		end
	end)
	return true
end

--- Leave the community voice channel. Restores every volume first.
function Voice:Leave()
	leftByHand = true
	CancelRejoin()
	AbandonPendingJoin() -- also a request that already timed out but may still complete
	local id = channelID
	self:RestoreAllVolumes()
	if id then
		Call("DeactivateChannel", id)
		Call("LeaveChannel", id)
	end
	if id or state ~= "idle" then
		Detach("Left proximity voice.")
	else
		Hark:Print("Not in proximity voice.")
	end
end

local function AutoJoin()
	local db = Hark.db
	if not db or not db.enabled or not db.autoJoin or not db.communityId then return end
	if leftByHand or Voice:IsActive() or state == "joining" then return end
	local now = GetTime()
	if now - lastAutoJoin < AUTOJOIN_MIN_GAP then return end
	lastAutoJoin = now
	Voice:Join()
end

-- After a /reload the channel may already be active.
local function AdoptExisting()
	local id = Plain(Call("GetActiveChannelID"))
	if id then
		local channel = Call("GetChannel", id)
		if IsOurChannel(channel) then
			Adopt(id)
			return true
		end
	end
	return false
end

---------------------------------------------------------------------------
-- Status output
---------------------------------------------------------------------------

function Voice:PrintStatus()
	if not self:IsAvailable() then
		Hark:Print("Voice chat API not available on this client.")
		return
	end
	local layer, confident = Hark.Positions:GetLayer()
	Hark:Print(string.format("Proximity %s, voice %s, %d position(s) known, layer %s%s.",
		Hark:IsEnabled() and "on" or "off", state, Hark.Positions:Count(),
		tostring(layer or "unknown"), layer and (confident and "" or " (unconfirmed)") or ""))
	if not self:IsActive() then return end
	local list = self:GetMembers()
	Hark:Print("Members: " .. #list)
	for _, m in ipairs(list) do
		local dist
		local yards = type(m.distance) == "number" and m.distance ~= math.huge and m.distance
		if m.reason == "near" then dist = yards and string.format("%.0f yd", yards) or "in range"
		elseif m.reason == "seen" then dist = yards and string.format("%.0f yd (seen)", yards) or "seen"
		elseif m.reason == "instance" then dist = "same instance"
		elseif m.reason == "layer" then dist = "other layer"
		elseif m.reason == "elsewhere" then dist = "far away"
		elseif m.reason == "override" then dist = "fixed"
		else dist = "no position" end
		Hark:Print(string.format("  %s - %s - volume %s", m.name or m.guid, dist, tostring(m.volume or "?")))
	end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local function OnEvent(_, event, ...)
	-- Event payloads come from the client: ignore any carrying a secret value
	-- (it could not be compared or used as a key anyway).
	for i = 1, select("#", ...) do
		if Hark.IsSecret((select(i, ...))) then return end
	end
	if event == "VOICE_CHAT_CHANNEL_JOINED" then
		local status, id, _, clubId, streamId = ...
		if clubId == nil or streamId == nil then return end
		local key = JoinKey(clubId, streamId)
		if IsAbandoned(key) then
			-- The result of a join we gave up on (left, switched community, timed out).
			if status == STATUS_SUCCESS then
				abandoned[key] = nil
				if id and id ~= channelID then DropChannel(id) end
			end
			return
		end
		if not SameId(clubId, Hark.db.communityId) then return end
		if not SameId(streamId, Voice:ResolveStreamId(clubId)) then return end
		if status ~= STATUS_SUCCESS then
			-- Only a join we are waiting for can fail; a stray failure (e.g. the
			-- user retrying in the Communities window) must not drop an active channel.
			if state ~= "joining" then return end
			CancelJoinTimer()
			pendingJoin = nil
			SetState("idle")
			Hark:Print("Joining community voice failed (status " .. tostring(status) .. ").")
			return
		end
		if not id then return end
		local channel = Call("GetChannel", id)
		if type(channel) == "table" and not Hark.IsSecret(channel) and Plain(channel.isActive) then Adopt(id) end
	elseif event == "VOICE_CHAT_CHANNEL_ACTIVATED" then
		local id = ...
		if id == nil then return end
		if id == channelID and state == "active" then return end
		if IsIgnoredChannel(id) then
			Call("DeactivateChannel", id)
			return
		end
		if IsOurChannel(Call("GetChannel", id)) then Adopt(id) end
	elseif event == "VOICE_CHAT_CHANNEL_DEACTIVATED" or event == "VOICE_CHAT_CHANNEL_REMOVED" then
		local id = ...
		if event == "VOICE_CHAT_CHANNEL_REMOVED" and id ~= nil then ignoredChannels[id] = nil end
		if id ~= nil and id == channelID then
			-- Something else (the player, another channel) took voice: do not auto-join back over it.
			leftByHand = true
			Detach("Proximity voice channel closed. Everyone is back to full volume. /hark join to return.")
		end
	elseif event == "VOICE_CHAT_LOGOUT" then
		if channelID or state ~= "idle" then Detach("Voice chat logged out.") end
	elseif event == "VOICE_CHAT_ERROR" then
		local platformCode, statusCode = ...
		if state == "joining" then
			Hark:Print(string.format("Voice error %s (%s).", tostring(statusCode), tostring(platformCode)))
		end
	elseif event == "VOICE_CHAT_CHANNEL_MEMBER_REMOVED" then
		local memberID, id = ...
		if id ~= channelID or memberID == nil then return end
		local guid = memberGUIDs[memberID]
		memberGUIDs[memberID] = nil
		if guid and members[guid] then
			Voice:SetVolumeFor(guid, Hark.FULL_VOLUME, nil)
			members[guid] = nil
			Hark:Fire("MEMBERS_UPDATED")
		end
	elseif event == "VOICE_CHAT_CHANNEL_MEMBER_GUID_UPDATED" then
		local memberID, id = ...
		if id ~= channelID or memberID == nil then return end
		memberGUIDs[memberID] = nil
		Voice:RequestPass(0.2)
	elseif event == "VOICE_CHAT_CHANNEL_MEMBER_ADDED" or event == "VOICE_CHAT_CHANNEL_MEMBER_ACTIVE_STATE_CHANGED" then
		local _, id = ...
		if id == channelID then Voice:RequestPass(0.2) end
	elseif event == "VOICE_CHAT_CHANNEL_MEMBER_SPEAKING_STATE_CHANGED" then
		local memberID, id, isSpeaking = ...
		if id ~= channelID or memberID == nil then return end
		local guid = memberGUIDs[memberID]
		local info = guid and members[guid]
		if info then
			info.isSpeaking = isSpeaking and true or false
			Hark:Fire("MEMBER_SPEAKING", guid, info.isSpeaking)
		end
	elseif event == "PLAYER_STARTED_MOVING" or event == "PLAYER_STOPPED_MOVING" then
		Voice:RequestPass(0.3)
	elseif event == "ZONE_CHANGED_NEW_AREA" then
		Voice:RequestPass(0.5)
		AutoJoin()
	end
end

function Voice:Init()
	local frame = CreateFrame("Frame")
	local events = {
		"VOICE_CHAT_CHANNEL_JOINED",
		"VOICE_CHAT_CHANNEL_ACTIVATED",
		"VOICE_CHAT_CHANNEL_DEACTIVATED",
		"VOICE_CHAT_CHANNEL_REMOVED",
		"VOICE_CHAT_CHANNEL_MEMBER_ADDED",
		"VOICE_CHAT_CHANNEL_MEMBER_REMOVED",
		"VOICE_CHAT_CHANNEL_MEMBER_GUID_UPDATED",
		"VOICE_CHAT_CHANNEL_MEMBER_ACTIVE_STATE_CHANGED",
		"VOICE_CHAT_CHANNEL_MEMBER_SPEAKING_STATE_CHANGED",
		"VOICE_CHAT_LOGOUT",
		"VOICE_CHAT_ERROR",
		"PLAYER_STARTED_MOVING",
		"PLAYER_STOPPED_MOVING",
		"ZONE_CHANGED_NEW_AREA",
	}
	for _, event in ipairs(events) do
		-- RegisterEvent throws on an event this client does not know; skip it instead.
		if not pcall(frame.RegisterEvent, frame, event) then
			Hark:Debug("event not available: " .. event)
		end
	end
	frame:SetScript("OnEvent", OnEvent)
	self.frame = frame

	Hark:RegisterCallback("SETTING_CHANGED", Voice, function(_, key)
		if key == "communityId" or key == "streamId" then
			if Voice:IsActive() or state == "joining" then
				local id = channelID
				Voice:RestoreAllVolumes()
				if id then
					Call("DeactivateChannel", id)
					Call("LeaveChannel", id)
				end
				Detach(nil) -- also marks an in-flight join as abandoned
				CancelRejoin()
				if Hark.db.communityId then
					-- Cancellable: /hark leave within this second must win.
					rejoinTimer = C_Timer.NewTimer(1, function()
						rejoinTimer = nil
						Voice:Join()
					end)
				end
			end
		elseif key == "enabled" then
			return -- handled by ENABLED_CHANGED
		else
			Voice:RequestPass(0)
		end
	end)
	Hark:RegisterCallback("ENABLED_CHANGED", Voice, function(_, on)
		if on then
			Voice:RequestPass(0)
			AutoJoin()
		else
			StopPasses()
			Voice:RestoreAllVolumes() -- Hark:SetEnabled already did this; harmless to repeat
		end
	end)
end

function Voice:OnLogin()
	if not self:IsAvailable() then
		Hark:Print("Blizzard voice chat API not found: Hark cannot change volumes on this client.")
		return
	end
	C_Timer.After(LOGIN_DELAY, function()
		AdoptExisting()
		-- Anyone left quiet by a previous session (crash, disconnect) goes back to full.
		for guid in pairs(Hark.db.lowered) do
			if not members[guid] then Voice:SetVolumeFor(guid, Hark.FULL_VOLUME) end
		end
		AutoJoin()
	end)
end

ns.Voice = Voice
