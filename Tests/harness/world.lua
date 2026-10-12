--- The simulated world: several game clients sharing one realm, one clock,
-- one addon-message bus and one voice service.
--
-- Each player is a Client with its own Lua environment, so every player runs
-- its own independent copy of the addon, exactly as in game. Addon messages
-- one client sends are delivered (after a configurable delay, possibly out of
-- order) to the other clients' CHAT_MSG_ADDON handlers.
--
-- See Tests/README.md for what is and is not simulated.

local Clock = require("harness.clock")
local Loader = require("harness.loader")
local WowApi = require("harness.wowapi")

local World = {}
World.__index = World

local Client = {}
Client.__index = Client
World.Client = Client

-- Built-in CVars the mock knows, with client defaults. Add as needed.
local BUILTIN_CVARS = {
	nameplateShowFriends = "0",
	nameplateShowEnemies = "1",
}
World.BUILTIN_CVARS = BUILTIN_CVARS

local DEFAULT_OPTIONS = {
	realm = "Test Realm",          -- has a space, like many real realm names
	-- CHAT_MSG_ADDON's sender is "Name-Realm" on modern clients, even for
	-- players on your own realm. Set false to model the old bare-name form.
	senderIncludesRealm = true,
	-- On the Forever beta, C_VoiceChat.GetChannel().members[i].name is nil.
	-- Set to true to pretend the client fills it in.
	voiceMemberNames = false,
	-- Seconds from RequestJoin... to VOICE_CHAT_CHANNEL_JOINED.
	voiceJoinDelay = 0.3,
	-- Addon message latency. function(fromClient, toClient, message) -> seconds
	-- or nil to drop the message. Default: fixed 100 ms (so in-order).
	latency = function() return 0.1 end,
	-- Token-bucket throttle per prefix per client, as measured on the beta:
	-- burst of 10, then 1 message per second.
	throttleBurst = 10,
	throttleRate = 1,
	-- Raise errors on RegisterEvent of unknown events, as the client does.
	strictEvents = true,
	-- Deliver CHANNEL addon messages to other players in the same custom
	-- channel. Unconfirmed on the beta (it echoes to the sender; cross-player
	-- delivery was not yet proven). Tests can turn it off.
	channelAddonDelivery = true,
	-- Baseline per-member voice volume before any addon touches it.
	baselineMemberVolume = 100,
	addonName = "Hark",
	addonDir = nil,
	frameStep = 0.05,
	echo = false,                  -- print every addon print() to stdout
}

function World.new(opts)
	opts = opts or {}
	local self = setmetatable({}, World)
	self.options = {}
	for k, v in pairs(DEFAULT_OPTIONS) do self.options[k] = v end
	for k, v in pairs(opts) do self.options[k] = v end
	self.realm = self.options.realm
	self.normalizedRealm = self.realm:gsub("[%s%-]", "")
	self.clock = Clock.new(1000, self.options.frameStep)
	self.serverEpoch = 1791763200 -- 2026-10-12 00:00:00 UTC, arbitrary
	self.clients, self.byName, self.byGUID = {}, {}, {}
	self.communities = {}          -- [clubId] = { clubId, name, streams = { [streamId] = {...} }, members = { [name]=true } }
	self.voiceChannels = {}        -- [key] = { key, members = { {memberID, client} }, nextMemberID }
	self.chatChannels = {}         -- [lowername] = { name, members = { client, ... } }
	self.errors = {}
	self.warnings = {}
	self.wire = {}                 -- every addon message accepted for delivery
	self.guidCounter = 0x0A000000
	self.addon = Loader.ReadToc(self.options.addonDir, self.options.addonName)
	self.clock:AddFrameHook(function(elapsed) self:OnFrame(elapsed) end)
	return self
end

function World:Warn(msg)
	if not self.warnings[msg] then
		self.warnings[msg] = true
		self.warnings[#self.warnings + 1] = msg
	end
end

function World:NewGUID()
	self.guidCounter = self.guidCounter + 1
	return string.format("Player-5000-%08X", self.guidCounter)
end

-- ---------------------------------------------------------------------------
-- Players

--- Add a player (a game client). Fields (all optional except name):
--   x, y            world coordinates in yards (may be negative)
--   instanceID      continent / map instance (0 Eastern Kingdoms, 1 Kalimdor)
--   zone, subzone, mapID
--   layer           integer layer id; invisible to UnitPosition, visible only
--                   through creature GUIDs (see World:ShowCreature)
--   guild           guild name or nil
--   group           any value; players with equal group values are grouped
--   dead, inInstance, instanceType
--   savedVariables  table of SavedVariables to start with
--   login           default true: load the addon and fire login events
function World:AddPlayer(spec)
	assert(spec and spec.name, "AddPlayer needs a name")
	assert(not self.byName[spec.name], "duplicate player " .. spec.name)
	local c = setmetatable({}, Client)
	c.world = self
	c.name = spec.name
	c.guid = self:NewGUID()
	c.index = #self.clients + 1
	c.x, c.y = spec.x or 0, spec.y or 0
	c.instanceID = spec.instanceID or 0
	c.zone = spec.zone or "Elwynn Forest"
	c.subzone = spec.subzone or ""
	c.mapID = spec.mapID or 1429
	c.layer = spec.layer or 1
	c.guild = spec.guild
	if spec.guild == nil and spec.noGuild ~= true then c.guild = "Hark Testers" end
	c.group = spec.group
	c.dead = spec.dead or false
	c.inInstance = spec.inInstance or false
	c.instanceType = spec.instanceType or "none"
	c.class, c.race = spec.class or "WARRIOR", spec.race or "Human"
	c.moving = false
	-- Each client's GetTime() is seconds since ITS OWN boot, so two clients
	-- never agree. An addon that sends GetTime() over the wire is wrong.
	c.timeOffset = spec.timeOffset or (c.index - 1) * 3600.25
	c.saved = spec.savedVariables or {}
	c.prints, c.errors, c.sent, c.received = {}, {}, {}, {}
	c.missingGlobals, c.definedGlobals = {}, {}
	c.units = {}
	c.prefixes = {}
	c.bucket = { tokens = self.options.throttleBurst, t = self.clock.now }
	c.voice = { channels = {}, active = nil, nextChannelID = 1 + c.index * 7, volumes = {}, muted = {} }
	c.chatChannels = {}
	c.cvars, c.registeredCVars = {}, {}
	for k, v in pairs(BUILTIN_CVARS) do c.cvars[k] = v end
	for k, v in pairs(spec.cvars or {}) do c.cvars[k] = tostring(v) end
	c.macros = spec.macros or { account = {}, char = {} } -- server side
	c.online = false
	self.clients[#self.clients + 1] = c
	self.byName[c.name] = c
	self.byGUID[c.guid] = c
	c.hasAddon = spec.addon ~= false
	if spec.login ~= false then c:Login() end
	return c
end

function World:Get(nameOrClient)
	if type(nameOrClient) == "table" then return nameOrClient end
	local c = self.byName[nameOrClient]
	assert(c, "no such player: " .. tostring(nameOrClient))
	return c
end

function World:Advance(seconds)
	self.clock:Advance(seconds)
end

function World:Now() return self.clock.now end

function World:Distance(a, b)
	a, b = self:Get(a), self:Get(b)
	return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2)
end

--- Teleport without any event (the client polls UnitPosition and sees it).
function World:SetPosition(name, x, y)
	local c = self:Get(name)
	c.x, c.y = x, y
	c.path = nil
end

--- Walk in a straight line to (x, y) at speed yards/second (default 7, run
-- speed). Fires PLAYER_STARTED_MOVING now and PLAYER_STOPPED_MOVING on arrival.
function World:MoveTo(name, x, y, speed)
	local c = self:Get(name)
	speed = speed or 7
	c.path = { x = x, y = y, speed = speed }
	if not c.moving then
		c.moving = true
		c:FireEvent("PLAYER_STARTED_MOVING")
	end
end

function World:OnFrame(elapsed)
	for _, c in ipairs(self.clients) do
		if c.path then
			local dx, dy = c.path.x - c.x, c.path.y - c.y
			local d = math.sqrt(dx * dx + dy * dy)
			local step = c.path.speed * elapsed
			if step >= d then
				c.x, c.y = c.path.x, c.path.y
				c.path = nil
				c.moving = false
				c:FireEvent("PLAYER_STOPPED_MOVING")
			else
				c.x, c.y = c.x + dx / d * step, c.y + dy / d * step
			end
		end
		if c.online then c:RunOnUpdate(elapsed) end
	end
end

--- Change zone. fields: zone, subzone, mapID, instanceID, x, y, inInstance,
-- instanceType. A change of instanceID is a loading screen and also fires
-- PLAYER_ENTERING_WORLD.
function World:ChangeZone(name, fields)
	local c = self:Get(name)
	local loading = fields.instanceID ~= nil and fields.instanceID ~= c.instanceID
	for k, v in pairs(fields) do c[k] = v end
	c.path, c.moving = nil, false
	if loading then
		c:FireEvent("PLAYER_LEAVING_WORLD")
		c:FireEvent("PLAYER_ENTERING_WORLD", false, false)
	end
	c:FireEvent("ZONE_CHANGED_NEW_AREA")
end

--- Move a player to another layer. Nothing in the client API changes except
-- the zone-UID field of creature GUIDs they see afterwards. No event fires.
function World:SetLayer(name, layer)
	self:Get(name).layer = layer
end

function World:SetDead(name, dead)
	local c = self:Get(name)
	c.dead = dead
	c:FireEvent(dead and "PLAYER_DEAD" or "PLAYER_ALIVE")
end

--- Enter or leave combat (fires PLAYER_REGEN_DISABLED / _ENABLED).
-- Protected actions such as CreateMacro raise while in combat.
function World:SetCombat(name, on)
	local c = self:Get(name)
	c.inCombat = on and true or false
	c:FireEvent(on and "PLAYER_REGEN_DISABLED" or "PLAYER_REGEN_ENABLED")
end

function World:SetGroup(name, group)
	local c = self:Get(name)
	c.group = group
	for _, o in ipairs(self.clients) do
		if o.online then o:FireEvent("GROUP_ROSTER_UPDATE") end
	end
end

--- Make a creature appear to a player as "target", "mouseover" or a
-- "nameplateN" unit. The creature's GUID encodes the player's CURRENT layer
-- in field 5 (the zone UID), which is how layers are detected in practice.
-- Fires the matching event.
function World:ShowCreature(name, unit, npcID, creatureName)
	local c = self:Get(name)
	npcID = npcID or 299
	local guid = string.format("Creature-0-5000-%d-%d-%d-%010X",
		c.instanceID, self:LayerZoneUID(c.instanceID, c.layer), npcID, 0x1000 + npcID)
	c.units[unit:lower()] = { creature = true, guid = guid, name = creatureName or "Young Wolf", npcID = npcID }
	if unit == "target" then
		c:FireEvent("PLAYER_TARGET_CHANGED")
	elseif unit == "mouseover" then
		c:FireEvent("UPDATE_MOUSEOVER_UNIT")
	elseif unit:match("^nameplate%d+$") then
		c:FireEvent("NAME_PLATE_UNIT_ADDED", unit)
	end
	return guid
end

function World:LayerZoneUID(instanceID, layer)
	-- Arbitrary but stable: different per (continent, layer).
	return 100 + instanceID * 1000 + layer * 17
end

-- ---------------------------------------------------------------------------
-- Communities and voice

--- Create a community with a voice-enabled stream. members: list of names.
function World:CreateCommunity(spec)
	local clubId = tostring(spec.clubId or "23111161")
	local streamId = tostring(spec.streamId or "1")
	local club = self.communities[clubId] or { clubId = clubId, name = spec.name or "Proximity", streams = {}, members = {} }
	club.streams[streamId] = { streamId = streamId, name = spec.streamName or "General", voice = true }
	for _, n in ipairs(spec.members or {}) do club.members[n] = true end
	self.communities[clubId] = club
	return club
end

function World:VoiceKey(clubId, streamId)
	return "club:" .. tostring(clubId) .. ":" .. tostring(streamId)
end

function World:VoiceChannel(key, meta)
	local ch = self.voiceChannels[key]
	if not ch then
		ch = { key = key, members = {}, nextMemberID = 1 }
		for k, v in pairs(meta or {}) do ch[k] = v end
		self.voiceChannels[key] = ch
	end
	return ch
end

--- Client c joins world voice channel ch (engine side). Fires the real event
-- sequence on c and on the existing members.
function World:VoiceJoin(c, ch, activate)
	for localID, wch in pairs(c.voice.channels) do
		if wch == ch then return localID end
	end
	local memberID = ch.nextMemberID
	ch.nextMemberID = ch.nextMemberID + 1
	ch.members[#ch.members + 1] = { memberID = memberID, client = c }
	local localID = c.voice.nextChannelID
	c.voice.nextChannelID = c.voice.nextChannelID + 1
	c.voice.channels[localID] = ch
	c:FireEvent("VOICE_CHAT_CHANNEL_JOINED", 0, localID, ch.channelType, ch.clubId, ch.streamId)
	for _, m in ipairs(ch.members) do
		local o = m.client
		if o ~= c then
			local oid = o:LocalChannelID(ch)
			o:FireEvent("VOICE_CHAT_CHANNEL_MEMBER_ADDED", memberID, oid)
			o:FireEvent("VOICE_CHAT_CHANNEL_MEMBER_GUID_UPDATED", memberID, oid)
			o:FireEvent("VOICE_CHAT_CHANNEL_MEMBER_ACTIVE_STATE_CHANGED", memberID, oid, true)
		end
	end
	if activate ~= false then c:VoiceActivate(localID) end
	return localID
end

--- Client c leaves channel localID. Normal order (as the client does it):
-- VOICE_CHAT_CHANNEL_DEACTIVATED while the channel and its members are still
-- queryable, then the channel is removed and VOICE_CHAT_CHANNEL_REMOVED fires.
-- abrupt = true models the channel vanishing first (server-side removal,
-- disconnect): nothing is queryable by the time any event fires.
function World:VoiceLeave(c, localID, abrupt)
	local ch = c.voice.channels[localID]
	if not ch then return false end
	if not abrupt and c.voice.active == localID then
		c:FireEvent("VOICE_CHAT_CHANNEL_DEACTIVATED", localID)
		c.voice.active = nil
	end
	local memberID
	for i, m in ipairs(ch.members) do
		if m.client == c then
			memberID = m.memberID
			table.remove(ch.members, i)
			break
		end
	end
	c.voice.channels[localID] = nil
	if c.voice.active == localID then
		c.voice.active = nil
		c:FireEvent("VOICE_CHAT_CHANNEL_DEACTIVATED", localID)
	end
	c:FireEvent("VOICE_CHAT_CHANNEL_REMOVED", localID)
	for _, m in ipairs(ch.members) do
		local o = m.client
		o:FireEvent("VOICE_CHAT_CHANNEL_MEMBER_REMOVED", memberID, o:LocalChannelID(ch))
	end
	return true
end

--- Join the configured community voice channel at the engine level, as if
-- the user clicked "Join Voice" in the Communities window. Use this when a
-- test needs a player in voice independently of the addon's join code.
function World:UserJoinsVoice(name, clubId, streamId)
	local c = self:Get(name)
	clubId, streamId = tostring(clubId or "23111161"), tostring(streamId or "1")
	local ch = self:VoiceChannel(self:VoiceKey(clubId, streamId),
		{ clubId = clubId, streamId = streamId, channelType = 4, name = "Proximity" })
	return self:VoiceJoin(c, ch, true)
end

function World:UserLeavesVoice(name, abrupt)
	local c = self:Get(name)
	for localID in pairs(c.voice.channels) do self:VoiceLeave(c, localID, abrupt) end
end

--- The volume `listener` has set for `speaker` (0-100), as stored by the
-- voice engine. Volumes are keyed by the speaker's GUID and survive leaving
-- the channel (see README). Returns baseline if never set.
function World:VolumeSetting(listener, speaker)
	listener, speaker = self:Get(listener), self:Get(speaker)
	local v = listener.voice.volumes[speaker.guid]
	if v == nil then v = self.options.baselineMemberVolume end
	return v
end

--- What listener actually hears of speaker: nil if they do not share the
-- listener's active voice channel, else the volume setting (0 if muted).
function World:Hears(listener, speaker)
	listener, speaker = self:Get(listener), self:Get(speaker)
	local ch = listener.voice.active and listener.voice.channels[listener.voice.active]
	if not ch then return nil end
	local present = false
	for _, m in ipairs(ch.members) do
		if m.client == speaker then present = true end
	end
	if not present then return nil end
	if listener.voice.muted[speaker.guid] then return 0 end
	return self:VolumeSetting(listener, speaker)
end

function World:InVoice(name)
	local c = self:Get(name)
	return c.voice.active ~= nil
end

-- ---------------------------------------------------------------------------
-- Addon message bus

function World:Throttle(c)
	local b = c.bucket
	local now = self.clock.now
	b.tokens = math.min(self.options.throttleBurst, b.tokens + (now - b.t) * self.options.throttleRate)
	b.t = now
	if b.tokens >= 1 then
		b.tokens = b.tokens - 1
		return true
	end
	return false
end

function World:Recipients(from, chatType, target)
	local out = {}
	for _, o in ipairs(self.clients) do
		if o.online then
			local ok = false
			if chatType == "GUILD" or chatType == "OFFICER" then
				ok = from.guild ~= nil and o.guild == from.guild
			elseif chatType == "PARTY" or chatType == "RAID" or chatType == "INSTANCE_CHAT" then
				ok = from.group ~= nil and o.group == from.group
			elseif chatType == "WHISPER" then
				local tname = tostring(target):match("^([^%-]+)")
				ok = o.name == tname and o ~= from
			elseif chatType == "CHANNEL" then
				local chname = from.chatChannels[tonumber(target)]
				if chname then
					local mine = o.chatChannels.byName and o.chatChannels.byName[chname:lower()]
					ok = mine ~= nil and (o == from or self.options.channelAddonDelivery)
				end
			end
			if ok then out[#out + 1] = o end
		end
	end
	return out
end

function World:Deliver(from, prefix, text, chatType, target)
	local entry = { from = from.name, prefix = prefix, text = text, chatType = chatType, target = target, time = self.clock.now }
	self.wire[#self.wire + 1] = entry
	local sender = from.name
	if self.options.senderIncludesRealm then sender = sender .. "-" .. self.normalizedRealm end
	for _, o in ipairs(self:Recipients(from, chatType, target)) do
		local delay = self.options.latency(from, o, entry)
		if delay ~= nil and o.prefixes[prefix] then
			local channelName = chatType == "CHANNEL" and from.chatChannels[tonumber(target)] or ""
			self.clock:Schedule(delay, function()
				if not o.online then return end
				o.received[#o.received + 1] = { prefix = prefix, text = text, chatType = chatType, sender = sender, time = self.clock.now }
				o:FireEvent("CHAT_MSG_ADDON", prefix, text, chatType, sender,
					o.name .. "-" .. self.normalizedRealm, 0, 0, channelName, 0)
			end, function(fn) fn() end)
		end
	end
end

--- Inject a raw addon message into a client, as if `fromName` sent it.
function World:InjectAddonMessage(toName, fromName, prefix, text, chatType)
	local o = self:Get(toName)
	local sender = fromName
	if self.options.senderIncludesRealm and not sender:find("-", 1, true) then
		sender = sender .. "-" .. self.normalizedRealm
	end
	o:FireEvent("CHAT_MSG_ADDON", prefix, text, chatType or "GUILD", sender,
		o.name .. "-" .. self.normalizedRealm, 0, 0, "", 0)
end

-- ---------------------------------------------------------------------------
-- Diagnostics

function World:AllErrors()
	local out = {}
	for _, c in ipairs(self.clients) do
		for _, e in ipairs(c.errors) do out[#out + 1] = e end
	end
	return out
end

-- ---------------------------------------------------------------------------
-- Client

function Client:Login()
	assert(not self.online, self.name .. " already logged in")
	self.frames = {}
	self.eventFrames = {}
	self.onUpdateFrames = {}
	self.slashCache = nil
	self.generation = (self.generation or 0) + 1
	self.env = WowApi.Build(self)
	self.online = true
	if self.hasAddon then Loader.LoadAddon(self, self.world.addon) end
	self:FireEvent("ADDON_LOADED", self.world.addon.name)
	self:FireEvent("ADDON_LOADED", "Blizzard_CommunitiesUI")
	self:FireEvent("VARIABLES_LOADED")
	self:FireEvent("PLAYER_LOGIN")
	self:FireEvent("PLAYER_ENTERING_WORLD", true, false)
	self:FireEvent("ZONE_CHANGED_NEW_AREA")
end

--- Save SavedVariables and tear the Lua state down. Voice-engine state
-- (channel membership, member volumes) belongs to the client, not to Lua,
-- and survives a /reload, as in game. A full logout leaves voice.
function Client:Logout(reload)
	if not self.online then return end
	self:FireEvent("PLAYER_LOGOUT")
	for _, var in ipairs(self.world.addon.savedVariables) do
		self.saved[var] = Loader.DeepCopy(rawget(self.env, var))
	end
	self.online = false
	self.frames, self.eventFrames, self.onUpdateFrames = {}, {}, {}
	if not reload then
		for localID in pairs(self.voice.channels) do self.world:VoiceLeave(self, localID) end
	end
end

function Client:Reload()
	self:Logout(true)
	self:Login()
end

--- Quit the game and start it again: registered CVars are lost (they live
-- in process memory), SavedVariables and server-side macros survive.
function Client:RestartClient()
	self:Logout()
	for name in pairs(self.registeredCVars) do self.cvars[name] = nil end
	self.registeredCVars = {}
	self:Login()
end

function Client:LocalChannelID(ch)
	for id, wch in pairs(self.voice.channels) do
		if wch == ch then return id end
	end
end

function Client:VoiceActivate(localID)
	if self.voice.active == localID then return end
	local prev = self.voice.active
	if prev then self:FireEvent("VOICE_CHAT_CHANNEL_DEACTIVATED", prev) end
	self.voice.active = localID
	self:FireEvent("VOICE_CHAT_CHANNEL_ACTIVATED", localID)
end

--- Run fn(...) the way the client runs addon code: errors do not propagate;
-- they go to the error handler (here: recorded in c.errors and world.errors).
function Client:Call(context, fn, ...)
	local args, n = { ... }, select("#", ...)
	local ok, err = xpcall(function() return fn(unpack(args, 1, n)) end, function(e)
		return { message = tostring(e), trace = debug.traceback("", 2) }
	end)
	if not ok then
		local rec = { client = self.name, context = context, message = err.message, trace = err.trace, time = self.world.clock.now }
		self.errors[#self.errors + 1] = rec
		-- As in game, an uncaught error goes to the current error handler, so an
		-- addon that wrapped it (seterrorhandler) sees it too. The default
		-- handler does not record it a second time.
		local api = self.api
		local handler = api and type(api.geterrorhandler) == "function" and api.geterrorhandler()
		if type(handler) == "function" and handler ~= self.defaultErrorHandler then
			self.dispatchingError = true
			pcall(handler, err.message)
			self.dispatchingError = false
		end
		if self.world.options.echo then
			io.stdout:write("    [lua error] ", self.name, " ", context, ": ", rec.message, "\n")
		end
	end
	return ok
end

function Client:FireEvent(event, ...)
	if not self.online then return end
	local list = self.eventFrames and self.eventFrames[event]
	if not list then return end
	local snapshot = {}
	for i, f in ipairs(list) do snapshot[i] = f end
	for _, f in ipairs(snapshot) do
		if f._events[event] then
			local h = f._scripts.OnEvent
			if h then self:Call("OnEvent " .. event, h, f, event, ...) end
		end
	end
end

function Client:RunOnUpdate(elapsed)
	for _, f in ipairs(self.frames) do
		local h = f._scripts.OnUpdate
		if h and f:IsVisible() then self:Call("OnUpdate", h, f, elapsed) end
	end
end

--- Type a slash command as the user would, e.g. c:Slash("/hark join").
-- Returns the lines printed while it ran.
function Client:Slash(text)
	local before = #self.prints
	local ok = WowApi.DispatchSlash(self, text)
	if not ok then
		self.prints[#self.prints + 1] = "[unknown slash command] " .. text
	end
	local out = {}
	for i = before + 1, #self.prints do out[#out + 1] = self.prints[i] end
	return out, ok
end

function Client:Print(line)
	local clean = tostring(line):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
	self.prints[#self.prints + 1] = clean
	if self.world.options.echo then io.stdout:write("    [", self.name, "] ", clean, "\n") end
end

--- The addon's namespace: the global named like the addon if present,
-- otherwise the private table passed as the second vararg.
function Client:NS()
	if not self.env then return nil end
	return rawget(self.env, self.world.addon.name) or self.ns
end

function Client:Global(name)
	return self.env and rawget(self.env, name)
end

function Client:SentBy(prefix)
	local out = {}
	for _, m in ipairs(self.sent) do
		if prefix == nil or m.prefix == prefix then out[#out + 1] = m end
	end
	return out
end

return World
