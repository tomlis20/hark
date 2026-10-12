--- Builds the global environment one game client presents to addon code.
--
-- Every function here is written to match the real client's observable
-- behaviour (return values, argument order, nil-vs-error) as closely as is
-- known. Where the real behaviour is unknown or deliberately simplified, a
-- comment starting "MOCK:" says so. Keep it that way: a mock that is kinder
-- than the client hides exactly the bugs this harness exists to find.

local KNOWN_EVENTS = require("harness.events")
local Loader = require("harness.loader")

local WowApi = {}

local unpack = unpack or table.unpack

-- WoW extends the shared string library; addons call ("x"):trim().
local function strtrim(s, chars)
	s = tostring(s)
	if chars then
		local set = "[" .. chars:gsub("[%]%^%-]", "%%%0") .. "]"
		return (s:gsub("^" .. set .. "+", ""):gsub(set .. "+$", ""))
	end
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function strsplit(delim, str, pieces)
	str = tostring(str)
	local out, start = {}, 1
	local set = "[" .. delim:gsub("[%]%^%-]", "%%%0") .. "]"
	while true do
		if pieces and #out == pieces - 1 then
			out[#out + 1] = str:sub(start)
			break
		end
		local s, e = str:find(set, start)
		if not s then
			out[#out + 1] = str:sub(start)
			break
		end
		out[#out + 1] = str:sub(start, s - 1)
		start = e + 1
	end
	return unpack(out)
end

local function strjoin(delim, ...)
	return table.concat({ ... }, delim)
end

string.trim = string.trim or strtrim
string.split = string.split or strsplit
string.join = string.join or strjoin

-- Pure-Lua 32-bit bit library (WoW ships "bit" = LuaBitOp).
local bitlib = rawget(_G, "bit")
if not bitlib then
	local function tobit(x) x = math.floor(x) % 4294967296; return x end
	local function op(a, b, f)
		a, b = tobit(a), tobit(b)
		local r, m = 0, 1
		for _ = 1, 32 do
			local x, y = a % 2, b % 2
			if f(x, y) then r = r + m end
			a, b, m = (a - x) / 2, (b - y) / 2, m * 2
		end
		if r >= 2147483648 then r = r - 4294967296 end
		return r
	end
	bitlib = {
		band = function(a, b) return op(a, b, function(x, y) return x == 1 and y == 1 end) end,
		bor = function(a, b) return op(a, b, function(x, y) return x == 1 or y == 1 end) end,
		bxor = function(a, b) return op(a, b, function(x, y) return x ~= y end) end,
		lshift = function(a, n) return op(tobit(a) * 2 ^ n, 0, function(x) return x == 1 end) end,
		rshift = function(a, n) return op(math.floor(tobit(a) / 2 ^ n), 0, function(x) return x == 1 end) end,
	}
end

-- ---------------------------------------------------------------------------
-- Widgets

local VALID_SCRIPT = "^On%u%a+$"

local function makeFrame(client, ftype, name, parent, template)
	local world = client.world
	local f = { _type = ftype or "Frame", _name = name, _parent = parent or false, _events = {}, _scripts = {}, _shown = true, _points = {}, _attrs = {}, _w = 0, _h = 0, _text = nil }
	local methods = {}
	function methods:RegisterEvent(event)
		if world.options.strictEvents and not KNOWN_EVENTS[event] then
			error(string.format('%s:RegisterEvent(): Attempt to register unknown event "%s"', self._name or "Frame", tostring(event)), 2)
		end
		if not self._events[event] then
			self._events[event] = true
			local list = client.eventFrames[event] or {}
			list[#list + 1] = self
			client.eventFrames[event] = list
		end
		return true
	end
	function methods:RegisterUnitEvent(event) return self:RegisterEvent(event) end
	function methods:UnregisterEvent(event)
		self._events[event] = nil
		local list = client.eventFrames[event]
		if list then
			for i = #list, 1, -1 do if list[i] == self then table.remove(list, i) end end
		end
	end
	function methods:UnregisterAllEvents()
		for e in pairs(self._events) do self:UnregisterEvent(e) end
	end
	function methods:IsEventRegistered(event) return self._events[event] == true end
	function methods:SetScript(kind, fn)
		if type(kind) ~= "string" or not kind:match(VALID_SCRIPT) then
			error(string.format('%s doesn\'t have a "%s" script', self._type, tostring(kind)), 2)
		end
		self._scripts[kind] = fn
	end
	function methods:GetScript(kind) return self._scripts[kind] end
	function methods:HookScript(kind, fn)
		local old = self._scripts[kind]
		if old then
			self._scripts[kind] = function(...) old(...); return fn(...) end
		else
			self._scripts[kind] = fn
		end
	end
	function methods:Show()
		if not self._shown then
			self._shown = true
			if self._scripts.OnShow then client:Call("OnShow", self._scripts.OnShow, self) end
		end
	end
	function methods:Hide()
		if self._shown then
			self._shown = false
			if self._scripts.OnHide then client:Call("OnHide", self._scripts.OnHide, self) end
		end
	end
	function methods:SetShown(v) if v then self:Show() else self:Hide() end end
	function methods:IsShown() return self._shown end
	function methods:IsVisible()
		local p = self
		while p do
			if not rawget(p, "_shown") then return false end
			p = rawget(p, "_parent")
		end
		return true
	end
	function methods:GetName() return self._name end
	function methods:GetParent() return self._parent or nil end
	function methods:SetParent(p) self._parent = p end
	function methods:GetObjectType() return self._type end
	function methods:IsObjectType(t) return t == self._type or t == "Frame" or t == "Region" end
	function methods:SetSize(w, h) self._w, self._h = w, h end
	function methods:SetWidth(w) self._w = w end
	function methods:SetHeight(h) self._h = h end
	function methods:GetWidth() return self._w end
	function methods:GetHeight() return self._h end
	function methods:GetSize() return self._w, self._h end
	function methods:SetPoint(...) self._points[#self._points + 1] = { ... } end
	function methods:ClearAllPoints() self._points = {} end
	function methods:GetNumPoints() return #self._points end
	function methods:SetAllPoints() self._points = { { "ALL" } } end
	function methods:SetText(t) self._text = t end
	function methods:GetText() return self._text end
	function methods:SetFormattedText(fmt, ...) self._text = string.format(fmt, ...) end
	function methods:SetAttribute(k, v) self._attrs[k] = v end
	function methods:GetAttribute(k) return self._attrs[k] end
	function methods:SetChecked(v) self._checked = v and true or false end
	function methods:GetChecked() return self._checked end
	function methods:SetValue(v) self._value = v; if self._scripts.OnValueChanged then client:Call("OnValueChanged", self._scripts.OnValueChanged, self, v, true) end end
	function methods:GetValue() return self._value end
	function methods:SetMinMaxValues(a, b) self._min, self._max = a, b end
	function methods:GetMinMaxValues() return self._min, self._max end
	function methods:Click(...) if self._scripts.OnClick then client:Call("OnClick", self._scripts.OnClick, self, ...) end end
	function methods:CreateFontString(n) return makeFrame(client, "FontString", n, self) end
	function methods:CreateTexture(n) return makeFrame(client, "Texture", n, self) end
	function methods:CreateAnimationGroup(n) return makeFrame(client, "AnimationGroup", n, self) end
	-- Tooltip methods (GameTooltip and any GameTooltip-type frame).
	function methods:SetOwner(owner, anchor) self._owner = owner; self._lines = {} end
	function methods:ClearLines() self._lines = {} end
	function methods:AddLine(text) self._lines = self._lines or {}; self._lines[#self._lines + 1] = text end
	function methods:AddDoubleLine(a, b) self:AddLine(tostring(a) .. "  " .. tostring(b)) end
	function methods:NumLines() return #(self._lines or {}) end
	setmetatable(methods, { __index = function(_, k)
		-- Unset fields read as nil, like on a real frame table. Only names
		-- that look like methods (Capitalised) fall back to a no-op stub.
		-- MOCK: cosmetic widget methods not listed above are accepted and do
		-- nothing (logged once as a warning). The real client errors on a
		-- method a widget type does not have.
		if type(k) ~= "string" or not k:match("^%u%l") then return nil end
		world:Warn("unmocked widget method " .. tostring(ftype) .. ":" .. tostring(k))
		return function() end
	end })
	setmetatable(f, { __index = methods })
	-- Template-created children addons commonly touch.
	if type(template) == "string" and template:find("CheckButton") then
		f.Text = makeFrame(client, "FontString", nil, f)
	end
	client.frames[#client.frames + 1] = f
	return f
end
WowApi.MakeFrame = makeFrame

-- ---------------------------------------------------------------------------
-- Slash commands, dispatched like ChatEdit_ParseText.

function WowApi.DispatchSlash(client, text)
	local env = client.env
	local command = text:match("^(/[^%s]+)")
	if not command then return false end
	local msg = text:sub(#command + 2)
	command = command:upper()
	local list = client.api.SlashCmdList
	for key, handler in pairs(list) do
		local i = 1
		while true do
			local alias = rawget(env, "SLASH_" .. key .. i)
			if not alias then break end
			if tostring(alias):upper() == command then
				client:Call("slash " .. command, handler, msg, nil)
				return true
			end
			i = i + 1
		end
	end
	return false
end

-- ---------------------------------------------------------------------------

function WowApi.Build(client)
	local world = client.world
	local clock = world.clock
	local api = {}

	-- Lua standard library subset WoW exposes (no io, require, dofile, os.exit).
	for _, k in ipairs({ "assert", "error", "ipairs", "pairs", "next", "pcall", "xpcall", "select",
		"tonumber", "tostring", "type", "rawget", "rawset", "rawequal", "setmetatable",
		"getmetatable", "unpack", "setfenv", "getfenv", "collectgarbage" }) do
		api[k] = _G[k]
	end
	api.unpack = unpack
	api.string, api.table, api.math, api.coroutine = string, table, math, coroutine
	api.os = { time = os.time, date = os.date, clock = os.clock, difftime = os.difftime }
	api.bit = bitlib
	api.date = os.date
	api.loadstring = function(src, name)
		return Loader.Compile(src, name or "=(loadstring)", client.env)
	end
	api.strtrim, api.strsplit, api.strjoin = strtrim, strsplit, strjoin
	api.strlower, api.strupper, api.strlen, api.strsub = string.lower, string.upper, string.len, string.sub
	api.strfind, api.strmatch, api.gsub, api.gmatch = string.find, string.match, string.gsub, string.gmatch
	api.format, api.strrep, api.strbyte, api.strchar, api.strrev = string.format, string.rep, string.byte, string.char, string.reverse
	api.tinsert, api.tremove, api.tconcat, api.sort = table.insert, table.remove, table.concat, table.sort
	api.floor, api.ceil, api.abs, api.max, api.min, api.sqrt = math.floor, math.ceil, math.abs, math.max, math.min, math.sqrt
	api.random, api.mod = math.random, math.fmod
	api.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
	api.table.wipe = api.table.wipe or api.wipe
	api.tContains = function(t, v) for _, x in ipairs(t) do if x == v then return true end end return false end
	api.tInvert = function(t) local o = {} for k, v in pairs(t) do o[v] = k end return o end
	api.CopyTable = function(t) return Loader.DeepCopy(t) end
	api.Mixin = function(o, ...) for i = 1, select("#", ...) do for k, v in pairs((select(i, ...))) do o[k] = v end end return o end
	api.CreateFromMixins = function(...) return api.Mixin({}, ...) end
	api.Round = function(v) return math.floor(v + 0.5) end
	api.Clamp = function(v, a, b) return math.min(math.max(v, a), b) end
	api.Lerp = function(a, b, t) return a + (b - a) * t end
	api.GetLocale = function() return "enUS" end
	api.debugstack = function() return debug.traceback("", 2) end
	api.debugprofilestop = function() return clock.now * 1000 end
	api.issecure = function() return false end
	api.InCombatLockdown = function() return client.inCombat == true end
	api.hooksecurefunc = function(a, b, c)
		local tbl, name, fn = a, b, c
		if type(a) == "string" then tbl, name, fn = client.env, a, b end
		local old = tbl[name]
		tbl[name] = function(...) local r = { old(...) }; fn(...); return unpack(r) end
	end
	api.securecallfunction = function(fn, ...) return fn(...) end

	-- Output
	api.print = function(...)
		local parts = {}
		for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
		client:Print(table.concat(parts, " "))
	end
	api.DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) client:Print(m) end }
	api.ChatFrame1 = api.DEFAULT_CHAT_FRAME
	-- The default handler reports the error and returns; it does not throw.
	local errorHandler = function(e)
		-- Client:Call already recorded an error it is dispatching (see world.lua).
		if client.dispatchingError then return end
		client.errors[#client.errors + 1] = { client = client.name, context = "geterrorhandler", message = tostring(e), time = clock.now }
	end
	client.defaultErrorHandler = errorHandler
	api.geterrorhandler = function() return errorHandler end
	api.seterrorhandler = function(h) errorHandler = h end

	-- Frames
	api.CreateFrame = function(ftype, name, parent, template)
		local f = makeFrame(client, ftype, name, parent, template)
		-- A named frame becomes a global, and counts as one the addon defined.
		if name then client.env[name] = f end
		return f
	end
	api.UIParent = makeFrame(client, "Frame", "UIParent")
	api.WorldFrame = makeFrame(client, "Frame", "WorldFrame")
	api.GameTooltip = makeFrame(client, "GameTooltip", "GameTooltip", api.UIParent)
	api.GameTooltip._shown = false
	api.BackdropTemplateMixin = {}

	-- Timers. C_Timer.After returns NOTHING; only NewTimer/NewTicker return a
	-- handle with :Cancel(). Code that stores After's result gets nil.
	-- Timers belong to this Lua state. A /reload or relog starts a new
	-- generation, and the old state's timers never fire again (as in game).
	local gen = client.generation
	local function alive() return client.online and client.generation == gen end
	local function runner(fn) client:Call("timer", fn) end
	local function newTimer(seconds, callback, iterations)
		local handle = { _cancelled = false }
		local count = 0
		local function schedule()
			handle._entry = clock:Schedule(seconds, function()
				if handle._cancelled or not alive() then return end
				count = count + 1
				if iterations and count >= iterations then handle._cancelled = true end
				callback(handle)
				if not handle._cancelled and iterations ~= 1 then schedule() end
			end, runner)
		end
		function handle:Cancel()
			self._cancelled = true
			if self._entry then self._entry.cancelled = true end
		end
		function handle:IsCancelled() return self._cancelled end
		return handle, schedule
	end
	api.C_Timer = {
		After = function(seconds, callback)
			assert(type(callback) == "function", "Usage: C_Timer.After(seconds, callback)")
			clock:Schedule(seconds, function() if alive() then callback() end end, runner)
		end,
		NewTimer = function(seconds, callback)
			local h, schedule = newTimer(seconds, callback, 1)
			schedule()
			return h
		end,
		NewTicker = function(seconds, callback, iterations)
			local h, schedule = newTimer(seconds, callback, iterations)
			schedule()
			return h
		end,
	}

	-- Time
	api.GetTime = function() return clock.now + client.timeOffset end
	api.GetServerTime = function() return world.serverEpoch + math.floor(clock.now) end
	api.time = api.GetServerTime

	-- Units -----------------------------------------------------------------
	local function grouped(o) return o == client or (client.group ~= nil and o.group == client.group) end
	local function groupList()
		local list = {}
		for _, o in ipairs(world.clients) do
			if o.online and client.group ~= nil and o.group == client.group then list[#list + 1] = o end
		end
		return list
	end
	local function resolve(unit)
		if type(unit) ~= "string" then return nil end
		local u = unit:lower()
		if u == "player" then return client end
		local n = u:match("^party(%d)$")
		if n then
			local others = {}
			for _, o in ipairs(groupList()) do if o ~= client then others[#others + 1] = o end end
			return others[tonumber(n)]
		end
		n = u:match("^raid(%d+)$")
		if n then return groupList()[tonumber(n)] end
		if client.units[u] then
			local x = client.units[u]
			if x.client then return x.client end
			return x
		end
		-- A player's name is a valid unit token only for group members.
		local nm = unit:match("^([^%-]+)")
		local o = world.byName[nm]
		if o and o.online and grouped(o) then return o end
		return nil
	end
	local function isPlayer(o) return o ~= nil and getmetatable(o) == world.Client end

	api.UnitExists = function(u) return resolve(u) ~= nil end
	api.UnitIsPlayer = function(u) return isPlayer(resolve(u)) end
	api.UnitGUID = function(u) local o = resolve(u); return o and o.guid end
	api.UnitName = function(u)
		local o = resolve(u)
		if not o then return nil end
		return o.name, nil -- MOCK: everyone is on the same realm, so realm is nil
	end
	api.UnitFullName = function(u)
		local o = resolve(u)
		if not o then return nil end
		if o == client then return o.name, world.normalizedRealm end
		return o.name, nil
	end
	api.GetUnitName = function(u, showServer) return (api.UnitName(u)) end
	api.UnitIsUnit = function(a, b) local x, y = resolve(a), resolve(b); return x ~= nil and x == y end
	api.UnitIsDeadOrGhost = function(u) local o = resolve(u); return o ~= nil and o.dead == true end
	api.UnitIsDead = api.UnitIsDeadOrGhost
	api.UnitIsGhost = function() return false end
	api.UnitIsConnected = function(u) local o = resolve(u); return o ~= nil and (not isPlayer(o) or o.online) end
	api.UnitClass = function(u) local o = resolve(u); if isPlayer(o) then return o.class:sub(1, 1) .. o.class:sub(2):lower(), o.class, 1 end end
	api.UnitRace = function(u) local o = resolve(u); if isPlayer(o) then return o.race, o.race, 1 end end
	api.UnitLevel = function(u) return resolve(u) and 60 or 0 end
	api.UnitFactionGroup = function(u) if resolve(u) then return "Alliance", "Alliance" end end
	api.UnitAffectingCombat = function(u) return resolve(u) == client and client.inCombat == true end
	api.UnitInParty = function(u) local o = resolve(u); return o ~= nil and isPlayer(o) and grouped(o) and client.group ~= nil end
	api.UnitInRaid = function() return nil end
	-- Players, pets and guardians are "player controlled"; world creatures are not.
	api.UnitPlayerControlled = function(u) local o = resolve(u); return o ~= nil and (isPlayer(o) or o.playerControlled == true) end
	api.UnitIsInMyGuild = function(u)
		local o = resolve(u)
		return isPlayer(o) and o ~= client and client.guild ~= nil and o.guild == client.guild or false
	end
	api.UnitIsGroupLeader = function(u) local g = groupList(); return g[1] ~= nil and g[1] == resolve(u) end

	-- UnitPosition returns posY, posX, posZ, instanceID: FOUR values, Y first,
	-- and posZ is always 0 on Classic-era clients. An addon that writes
	-- `local x, y, instance = UnitPosition("player")` gets instance = 0.
	-- It returns nil inside instances, and for any unit that is not the
	-- player or a group member (creatures, strangers).
	api.UnitPosition = function(u)
		local o = resolve(u)
		if not isPlayer(o) or not grouped(o) or not o.online then return nil end
		if o.inInstance then return nil end
		if o ~= client and o.instanceID ~= client.instanceID then return nil end
		return o.y, o.x, 0, o.instanceID
	end
	-- currentSpeed, runSpeed, flightSpeed, swimSpeed (yards/second)
	api.GetUnitSpeed = function(u)
		local o = resolve(u)
		if not isPlayer(o) then return 0, 0, 0, 0 end
		return o.moving and 7 or 0, 7, 7, 4.722
	end
	api.IsFalling = function() return false end
	api.IsSwimming = function() return false end
	api.IsFlying = function() return false end
	api.IsMounted = function() return false end
	api.IsResting = function() return false end

	api.GetPlayerInfoByGUID = function(guid)
		local o = world.byGUID[guid]
		if not o then return nil end
		-- localizedClass, englishClass, localizedRace, englishRace, sex, name, realmName ("" = own realm)
		return o.class, o.class, o.race, o.race, 2, o.name, ""
	end

	-- Social
	api.IsInGuild = function() return client.guild ~= nil end
	api.GetGuildInfo = function(u) local o = resolve(u); if isPlayer(o) and o.guild then return o.guild, "Member", 1, nil end end
	-- MOCK: only home (manually formed) groups exist; instance groups
	-- (LFG/battleground, category 2) are never modelled.
	api.LE_PARTY_CATEGORY_HOME, api.LE_PARTY_CATEGORY_INSTANCE = 1, 2
	api.IsInGroup = function(category)
		if category == 2 then return false end
		return client.group ~= nil and #groupList() > 1
	end
	api.IsInRaid = function() return false end
	api.GetNumGroupMembers = function() local n = #groupList(); return n > 1 and n or 0 end
	api.GetNumSubgroupMembers = function() local n = #groupList(); return n > 1 and n - 1 or 0 end

	-- Realm and names
	api.GetRealmName = function() return world.realm end
	api.GetNormalizedRealmName = function() return world.normalizedRealm end
	api.Ambiguate = function(name, context)
		local base, realm = tostring(name):match("^([^%-]+)%-(.+)$")
		if not base then return name end
		if context == "short" or realm == world.normalizedRealm then return base end
		return name
	end

	-- Zones and maps
	api.GetZoneText = function() return client.zone end
	api.GetRealZoneText = function() return client.zone end
	api.GetSubZoneText = function() return client.subzone end
	api.GetMinimapZoneText = function() return client.subzone ~= "" and client.subzone or client.zone end
	api.IsInInstance = function() return client.inInstance, client.instanceType end
	api.GetInstanceInfo = function()
		-- name, instanceType, difficultyID, difficultyName, maxPlayers,
		-- dynamicDifficulty, isDynamic, instanceID, instanceGroupSize, LfgDungeonID
		local name = client.instanceID == 1 and "Kalimdor" or "Eastern Kingdoms"
		if client.inInstance then name = client.zone end
		return name, client.instanceType, 0, "", 0, 0, false, client.instanceID, 0, nil
	end
	api.C_Map = {
		GetBestMapForUnit = function(u)
			local o = resolve(u)
			if not isPlayer(o) or not grouped(o) then return nil end
			return o.mapID
		end,
		-- Zone maps (mapType 3) have a continent parent (mapType 2), which has
		-- the world (mapType 1) as parent. Any mapID not listed is a zone of
		-- the player's current continent.
		GetMapInfo = function(mapID)
			local continents = { [1414] = "Kalimdor", [1415] = "Eastern Kingdoms" }
			if mapID == 947 then return { mapID = 947, name = "Azeroth", mapType = 1, parentMapID = 0 } end
			if continents[mapID] then return { mapID = mapID, name = continents[mapID], mapType = 2, parentMapID = 947 } end
			local parent = client.instanceID == 1 and 1414 or 1415
			return { mapID = mapID, name = client.mapID == mapID and client.zone or ("Map " .. mapID), mapType = 3, parentMapID = parent }
		end,
		-- MOCK: real per-zone map rectangles are not modelled; positions are
		-- normalised against a fixed 10,000-yard square centred on 0,0.
		GetPlayerMapPosition = function(mapID, u)
			local o = resolve(u)
			if not isPlayer(o) or not grouped(o) or o.inInstance then return nil end
			local vx, vy = (o.x + 5000) / 10000, (o.y + 5000) / 10000
			return { x = vx, y = vy, GetXY = function() return vx, vy end }
		end,
	}

	-- Addon messages ----------------------------------------------------------
	api.Enum = {
		SendAddonMessageResult = { Success = 0, InvalidPrefix = 1, InvalidMessage = 2, AddonMessageThrottle = 3, InvalidChatType = 4, NotInGroup = 5, TargetRequired = 6, InvalidChannel = 7, ChannelThrottle = 8, GeneralError = 9 },
		RegisterAddonMessagePrefixResult = { Success = 0, DuplicatePrefix = 1, InvalidPrefix = 2, MaxPrefixes = 3 },
		ChatChannelType = { None = 0, Custom = 1, PrivateParty = 2, PublicParty = 3, Communities = 4 },
		VoiceChatStatusCode = { Success = 0, OperationPending = 1, TooManyRequests = 2, LoginProhibited = 3, ClientNotInitialized = 4, ClientNotLoggedIn = 5, ClientAlreadyLoggedIn = 6, ChannelNameTooShort = 7, ChannelNameTooLong = 8, ChannelAlreadyExists = 9, AlreadyInChannel = 10, TargetNotFound = 11, Failure = 12 },
		ClubType = { BattleNet = 0, Character = 1, Guild = 2, Other = 3 },
		ClubStreamType = { General = 0, Guild = 1, Officer = 2, Other = 3 },
		UIMapType = { Cosmic = 0, World = 1, Continent = 2, Zone = 3, Dungeon = 4, Micro = 5, Orphan = 6 },
	}
	local R = api.Enum.SendAddonMessageResult
	local function send(prefix, text, chatType, target)
		if type(prefix) ~= "string" or type(text) ~= "string" or type(chatType) ~= "string" then
			error("Usage: C_ChatInfo.SendAddonMessage(prefix, message [, chatType [, target]])", 3)
		end
		local result
		chatType = chatType:upper()
		if #prefix == 0 or #prefix > 16 then
			result = R.InvalidPrefix
		elseif #text > 255 then
			result = R.InvalidMessage
		elseif chatType == "SAY" or chatType == "YELL" then
			result = R.InvalidChatType      -- measured on the Forever beta (YELL -> 4)
		elseif (chatType == "GUILD" or chatType == "OFFICER") and not client.guild then
			result = R.NotInGroup
		elseif (chatType == "PARTY" or chatType == "RAID" or chatType == "INSTANCE_CHAT") and not api.IsInGroup() then
			result = R.NotInGroup
		elseif chatType == "WHISPER" and not target then
			result = R.TargetRequired
		elseif chatType == "CHANNEL" and not client.chatChannels[tonumber(target)] then
			result = R.InvalidChannel
		elseif not ({ GUILD = 1, OFFICER = 1, PARTY = 1, RAID = 1, INSTANCE_CHAT = 1, WHISPER = 1, CHANNEL = 1 })[chatType] then
			result = R.InvalidChatType
		elseif not world:Throttle(client) then
			result = R.AddonMessageThrottle
		else
			result = R.Success
		end
		client.sent[#client.sent + 1] = { prefix = prefix, text = text, chatType = chatType, target = target, result = result, time = clock.now }
		if result == R.Success then world:Deliver(client, prefix, text, chatType, target) end
		return result
	end
	api.C_ChatInfo = {
		RegisterAddonMessagePrefix = function(prefix)
			if type(prefix) ~= "string" or #prefix == 0 or #prefix > 16 then return 2 end
			if client.prefixes[prefix] then return 1 end
			client.prefixes[prefix] = true
			return 0
		end,
		IsAddonMessagePrefixRegistered = function(p) return client.prefixes[p] == true end,
		GetRegisteredAddonMessagePrefixes = function()
			local out = {}
			for p in pairs(client.prefixes) do out[#out + 1] = p end
			return out
		end,
		SendAddonMessage = send,
		SendAddonMessageLogged = send,
	}

	-- Custom chat channels (for CHANNEL addon messages).
	-- MOCK: General/Trade etc. are not pre-joined; numbering starts at 1.
	local function joinChannel(name)
		if not name then return nil end
		client.chatChannels.byName = client.chatChannels.byName or {}
		local key = name:lower()
		if client.chatChannels.byName[key] then return 1, name end
		local id = 1
		while client.chatChannels[id] do id = id + 1 end
		client.chatChannels[id] = name
		client.chatChannels.byName[key] = id
		return 1, name
	end
	api.JoinTemporaryChannel = joinChannel
	api.JoinChannelByName = joinChannel
	api.JoinPermanentChannel = joinChannel
	api.LeaveChannelByName = function(name)
		local by = client.chatChannels.byName
		local id = by and by[tostring(name):lower()]
		if id then client.chatChannels[id] = nil; by[name:lower()] = nil end
	end
	api.GetChannelName = function(q)
		local id
		if type(q) == "number" then
			id = client.chatChannels[q] and q
		else
			id = client.chatChannels.byName and client.chatChannels.byName[tostring(q):lower()]
		end
		if not id then return 0, nil, 0 end
		return id, client.chatChannels[id], 0
	end

	-- Communities --------------------------------------------------------------
	local function memberOf(club) return club.members[client.name] == true end
	api.C_Club = {
		GetSubscribedClubs = function()
			local out = {}
			for _, club in pairs(world.communities) do
				if memberOf(club) then out[#out + 1] = { clubId = club.clubId, name = club.name, clubType = 1, memberCount = 0 } end
			end
			return out
		end,
		GetClubInfo = function(clubId)
			local club = world.communities[tostring(clubId)]
			if club and memberOf(club) then return { clubId = club.clubId, name = club.name, clubType = 1 } end
		end,
		GetStreams = function(clubId)
			local club = world.communities[tostring(clubId)]
			local out = {}
			if club and memberOf(club) then
				for _, s in pairs(club.streams) do out[#out + 1] = { streamId = s.streamId, name = s.name, streamType = 0 } end
			end
			return out
		end,
	}

	-- Voice ------------------------------------------------------------------
	local function voiceChannelInfo(localID)
		local ch = client.voice.channels[localID]
		if not ch then return nil end
		local members = {}
		for _, m in ipairs(ch.members) do
			members[#members + 1] = {
				memberID = m.memberID,
				-- Real behaviour on the beta: no usable name on members.
				name = world.options.voiceMemberNames and m.client.name or nil,
				isActive = true, isSpeaking = false, energy = 0,
				isMutedForAll = false, isSilenced = false,
			}
		end
		return {
			name = ch.name or "Proximity", channelID = localID, channelType = ch.channelType or 4,
			clubId = ch.clubId, streamId = ch.streamId, volume = 1,
			isActive = client.voice.active == localID, isMuted = false, isTransmitting = false,
			isLocalProcess = false, members = members,
		}
	end
	local function memberGUID(memberID, localID)
		local ch = client.voice.channels[localID]
		if not ch then return nil end
		for _, m in ipairs(ch.members) do
			if m.memberID == memberID then return m.client.guid end
		end
	end
	local function locationGUID(loc, fname)
		if type(loc) ~= "table" or not loc._isPlayerLocation then
			error("bad argument #1 to '" .. fname .. "' (PlayerLocation expected)", 3)
		end
		if loc.guid then return loc.guid end
		if loc.voiceMemberID then return memberGUID(loc.voiceMemberID, loc.voiceChannelID) end
		if loc.unit then local o = resolve(loc.unit); return o and o.guid end
	end
	client.voiceInvalid = {}
	api.C_VoiceChat = {
		IsLoggedIn = function() return true end,
		CanPlayerUseVoiceChat = function() return true end,
		IsVoiceChatConnected = function() return true end,
		GetActiveChannelID = function() return client.voice.active end,
		GetActiveChannelType = function()
			local ch = client.voice.active and client.voice.channels[client.voice.active]
			return ch and ch.channelType
		end,
		GetChannel = function(channelID) return voiceChannelInfo(channelID) end,
		GetChannelForChannelType = function(channelType)
			for id, ch in pairs(client.voice.channels) do
				if ch.channelType == channelType then return voiceChannelInfo(id) end
			end
		end,
		GetChannelForCommunityStream = function(clubId, streamId)
			for id, ch in pairs(client.voice.channels) do
				if ch.clubId == tostring(clubId) and ch.streamId == tostring(streamId) then return voiceChannelInfo(id) end
			end
		end,
		GetMemberGUID = function(memberID, channelID) return memberGUID(memberID, channelID) end,
		GetMemberID = function(channelID, guid)
			local ch = client.voice.channels[channelID]
			if not ch then return nil end
			for _, m in ipairs(ch.members) do if m.client.guid == guid then return m.memberID end end
		end,
		GetMemberInfo = function(memberID, channelID)
			local info = voiceChannelInfo(channelID)
			if not info then return nil end
			for _, m in ipairs(info.members) do if m.memberID == memberID then return m end end
		end,
		GetLocalPlayerMemberID = function(channelID)
			local ch = client.voice.channels[channelID]
			if not ch then return nil end
			for _, m in ipairs(ch.members) do if m.client == client then return m.memberID end end
		end,
		-- MOCK: volume scale assumed 0-100. Settings are stored per speaker
		-- GUID and persist after leaving the channel (assumption, see README):
		-- a volume the addon forgets to restore stays applied.
		SetMemberVolume = function(loc, volume)
			local guid = locationGUID(loc, "SetMemberVolume")
			if type(volume) ~= "number" then error("bad argument #2 to 'SetMemberVolume' (number expected)", 2) end
			if not guid then
				client.voiceInvalid[#client.voiceInvalid + 1] = { fn = "SetMemberVolume", loc = loc, volume = volume }
				return
			end
			client.voice.volumes[guid] = math.max(0, math.min(100, volume))
		end,
		GetMemberVolume = function(loc)
			local guid = locationGUID(loc, "GetMemberVolume")
			if not guid then return nil end
			local v = client.voice.volumes[guid]
			if v == nil then v = world.options.baselineMemberVolume end
			return v
		end,
		SetMemberMuted = function(loc, muted)
			local guid = locationGUID(loc, "SetMemberMuted")
			if guid then client.voice.muted[guid] = muted and true or nil end
		end,
		IsMemberMuted = function(loc)
			local guid = locationGUID(loc, "IsMemberMuted")
			return guid ~= nil and client.voice.muted[guid] == true
		end,
		IsMemberLocalPlayer = function(memberID, channelID) return memberGUID(memberID, channelID) == client.guid end,
		-- Asynchronous: returns nothing. Success or failure arrives later as
		-- VOICE_CHAT_CHANNEL_JOINED(statusCode, channelID, channelType, clubId, streamId).
		RequestJoinAndActivateCommunityStreamChannel = function(clubId, streamId)
			clubId, streamId = tostring(clubId), tostring(streamId)
			clock:Schedule(world.options.voiceJoinDelay, function()
				if not client.online then return end
				local club = world.communities[clubId]
				local stream = club and club.streams[streamId]
				if not (club and stream and stream.voice and memberOf(club)) then
					client:FireEvent("VOICE_CHAT_CHANNEL_JOINED", api.Enum.VoiceChatStatusCode.TargetNotFound, nil, 4, clubId, streamId)
					return
				end
				local ch = world:VoiceChannel(world:VoiceKey(clubId, streamId), { clubId = clubId, streamId = streamId, channelType = 4, name = club.name })
				world:VoiceJoin(client, ch, true)
			end, function(fn) fn() end)
		end,
		RequestJoinChannelByChannelType = function(channelType, clubId, autoActivate)
			clock:Schedule(world.options.voiceJoinDelay, function()
				if not client.online then return end
				local key
				if channelType == 2 then
					if client.group == nil then
						client:FireEvent("VOICE_CHAT_CHANNEL_JOINED", api.Enum.VoiceChatStatusCode.TargetNotFound, nil, channelType)
						return
					end
					key = "party:" .. tostring(client.group)
				else
					key = "type:" .. tostring(channelType) .. ":" .. tostring(clubId)
				end
				local ch = world:VoiceChannel(key, { channelType = channelType, name = "Party" })
				world:VoiceJoin(client, ch, autoActivate ~= false)
			end, function(fn) fn() end)
		end,
		LeaveChannel = function(channelID)
			if not client.voice.channels[channelID] then return end
			clock:Schedule(0.05, function() world:VoiceLeave(client, channelID) end, function(fn) fn() end)
		end,
		ActivateChannel = function(channelID)
			if client.voice.channels[channelID] then client:VoiceActivate(channelID) end
		end,
		DeactivateChannel = function(channelID)
			if client.voice.active == channelID then
				client.voice.active = nil
				client:FireEvent("VOICE_CHAT_CHANNEL_DEACTIVATED", channelID)
			end
		end,
		IsMuted = function() return false end,
		IsDeafened = function() return false end,
		GetCommunicationMode = function() return 0 end,
	}

	local PlayerLocationMixin = {}
	PlayerLocationMixin.__index = PlayerLocationMixin
	function PlayerLocationMixin:IsValid() return true end
	function PlayerLocationMixin:IsGUID() return self.guid ~= nil end
	function PlayerLocationMixin:IsUnit() return self.unit ~= nil end
	function PlayerLocationMixin:IsVoiceID() return self.voiceMemberID ~= nil end
	function PlayerLocationMixin:GetGUID() return self.guid end
	function PlayerLocationMixin:GetUnit() return self.unit end
	function PlayerLocationMixin:GetVoiceID() return self.voiceMemberID, self.voiceChannelID end
	local function newLoc(fields)
		fields._isPlayerLocation = true
		return setmetatable(fields, PlayerLocationMixin)
	end
	api.PlayerLocation = {
		CreateFromVoiceID = function(_, memberID, channelID) return newLoc({ voiceMemberID = memberID, voiceChannelID = channelID }) end,
		CreateFromGUID = function(_, guid) return newLoc({ guid = guid }) end,
		CreateFromUnit = function(_, unit) return newLoc({ unit = unit }) end,
	}
	api.PlayerLocationMixin = PlayerLocationMixin

	-- Addon metadata and options panels -----------------------------------
	local function meta(name, field)
		if name == world.addon.name then return world.addon.meta[field] end
	end
	api.C_AddOns = {
		GetAddOnMetadata = meta,
		IsAddOnLoaded = function(n) return n == world.addon.name end,
		LoadAddOn = function() return false, "MISSING" end,
	}
	api.GetAddOnMetadata = meta
	api.IsAddOnLoaded = api.C_AddOns.IsAddOnLoaded
	client.optionsCategories = {}
	api.Settings = {
		RegisterCanvasLayoutCategory = function(frame, name)
			local cat = { frame = frame, name = name, ID = name }
			function cat:GetID() return self.ID end
			return cat
		end,
		RegisterVerticalLayoutCategory = function(name)
			local cat = { name = name, ID = name }
			function cat:GetID() return self.ID end
			return cat
		end,
		RegisterAddOnCategory = function(cat) client.optionsCategories[#client.optionsCategories + 1] = cat end,
		OpenToCategory = function(id) client.openedCategory = id end,
	}
	api.InterfaceOptions_AddCategory = function(frame) client.optionsCategories[#client.optionsCategories + 1] = frame end
	api.InterfaceOptionsFrame_OpenToCategory = function(f) client.openedCategory = f end

	-- CVars. Values are always strings. Built-in CVars (see BUILTIN_CVARS in
	-- world.lua) are saved to Config.wtf and survive a client restart;
	-- addon-registered ones live in process memory and survive /reload and
	-- relog but not a restart (client:RestartClient()). SetCVar fires
	-- CVAR_UPDATE.
	api.C_CVar = {
		RegisterCVar = function(name, default)
			if client.cvars[name] == nil then
				client.cvars[name] = default ~= nil and tostring(default) or ""
				client.registeredCVars[name] = true
			end
		end,
		GetCVar = function(name)
			return client.cvars[name]
		end,
		SetCVar = function(name, value)
			if client.cvars[name] == nil then return false end
			client.cvars[name] = value ~= nil and tostring(value) or ""
			client:FireEvent("CVAR_UPDATE", name, client.cvars[name])
			return true
		end,
		GetCVarDefault = function() return nil end,
	}
	api.GetCVar = api.C_CVar.GetCVar
	api.SetCVar = api.C_CVar.SetCVar

	-- Macros are stored server-side and survive everything. Account macros
	-- occupy indexes 1..120, character macros 121..138. Bodies truncate at
	-- 255 characters. Create/Edit are blocked in combat (nocombat).
	api.MAX_ACCOUNT_MACROS, api.MAX_CHARACTER_MACROS = 120, 18
	local macros = client.macros
	local function macroSlots(perChar)
		local list = perChar and macros.char or macros.account
		return list, perChar and 120 or 0, perChar and 18 or 120
	end
	local function macroAt(index)
		if type(index) ~= "number" then return nil end
		if index >= 1 and index <= 120 then return macros.account[index] end
		if index > 120 and index <= 138 then return macros.char[index - 120] end
	end
	local function noCombat(fname)
		if client.inCombat then
			error("Interface action failed because of an AddOn (" .. fname .. " is blocked in combat)", 3)
		end
	end
	local function macrosChanged()
		clock:Schedule(0, function() client:FireEvent("UPDATE_MACROS") end, function(fn) fn() end)
	end
	api.GetNumMacros = function() return #macros.account, #macros.char end
	api.GetMacroIndexByName = function(name)
		for i, m in ipairs(macros.account) do if m.name == name then return i end end
		for i, m in ipairs(macros.char) do if m.name == name then return 120 + i end end
		return 0
	end
	api.GetMacroInfo = function(index)
		local m = macroAt(index)
		if m then return m.name, m.icon, m.body end
	end
	api.GetMacroBody = function(index)
		local m = macroAt(index)
		return m and m.body
	end
	api.CreateMacro = function(name, icon, body, perCharacter)
		noCombat("CreateMacro")
		local list, offset, cap = macroSlots(perCharacter)
		if #list >= cap then error("Cannot create any more macros", 2) end
		list[#list + 1] = { name = tostring(name):sub(1, 16), icon = icon, body = tostring(body or ""):sub(1, 255) }
		macrosChanged()
		return offset + #list
	end
	api.EditMacro = function(index, name, icon, body)
		noCombat("EditMacro")
		local m = macroAt(index)
		if not m then return nil end
		if name then m.name = tostring(name):sub(1, 16) end
		if icon then m.icon = icon end
		if body then m.body = tostring(body):sub(1, 255) end
		macrosChanged()
		return index
	end
	api.DeleteMacro = function(index)
		noCombat("DeleteMacro")
		if type(index) == "string" then index = api.GetMacroIndexByName(index) end
		if macroAt(index) then
			if index <= 120 then table.remove(macros.account, index) else table.remove(macros.char, index - 120) end
			macrosChanged()
		end
	end

	-- Slash commands
	api.SlashCmdList = {}
	api.hash_SlashCmdList = {}

	-- Environment: raw table holds what the addon defines; lookups fall back
	-- to the API. Reads of names neither defines are recorded so a report can
	-- say "the addon called X, which the client does not have".
	local env = {}
	env._G = env
	setmetatable(env, {
		__index = function(_, k)
			local v = api[k]
			if v == nil then client.missingGlobals[k] = (client.missingGlobals[k] or 0) + 1 end
			return v
		end,
		__newindex = function(t, k, v)
			client.definedGlobals[k] = true
			rawset(t, k, v)
		end,
	})
	client.api = api
	return env
end

return WowApi
