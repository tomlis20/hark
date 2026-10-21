--- Hark: Proximity voice chat for WoW Forever
-- Core: namespace, saved variables, settings API, callbacks, lifecycle, slash commands.
-- See CONTRACT.md for the public surface other files may rely on.

local ADDON_NAME, ns = ...

-- The one intentional global. Every module hangs off this table.
local Hark = {
	version = "0.3.0",
	db = nil, -- HarkDB once ADDON_LOADED has fired. Read freely, write only through Hark:Set().
}
_G.Hark = Hark
ns.Hark = Hark

-- Full volume used for restores and as the ceiling of maxVolume.
Hark.FULL_VOLUME = 100

---------------------------------------------------------------------------
-- Settings schema and defaults
---------------------------------------------------------------------------

-- type, default, and validation for every user-facing saved variable.
-- Options.lua can build its controls from this table.
Hark.SETTINGS = {
	enabled        = { type = "boolean", default = true },
	autoJoin       = { type = "boolean", default = true },
	communityId    = { type = "string",  default = nil, nilable = true },
	streamId       = { type = "string",  default = nil, nilable = true },
	fullVoiceRange = { type = "number",  default = 15, min = 0, max = 100, step = 1 },
	silentRange    = { type = "number",  default = 40, min = 5, max = 200, step = 1 },
	minVolume      = { type = "number",  default = 30, min = 0, max = 100, step = 1 },
	maxVolume      = { type = "number",  default = 100, min = 0, max = 100, step = 1 },
	fadeCurve      = { type = "string",  default = "smooth", choices = { "linear", "natural", "smooth" } },
	hearUnknown    = { type = "boolean", default = false },
	layerAware     = { type = "boolean", default = true },
	debug          = { type = "boolean", default = false },
}

Hark.DB_VERSION = 2

local function IsChoice(spec, value)
	for _, choice in ipairs(spec.choices) do
		if choice == value then return true end
	end
	return false
end

-- Returns the cleaned value, or nil plus an error string.
local function Validate(key, value)
	local spec = Hark.SETTINGS[key]
	if not spec then return nil, "unknown setting " .. tostring(key) end
	if value == nil then
		if spec.nilable then return nil end
		return nil, key .. " cannot be nil"
	end
	if spec.type == "number" then
		value = tonumber(value)
		if not value or value ~= value then return nil, key .. " must be a number" end
		if value < spec.min then value = spec.min end
		if value > spec.max then value = spec.max end
		return value
	elseif spec.type == "boolean" then
		if type(value) ~= "boolean" then return nil, key .. " must be true or false" end
		return value
	elseif spec.type == "string" then
		if type(value) == "number" then value = tostring(value) end
		if type(value) ~= "string" then return nil, key .. " must be a string" end
		value = strtrim(value)
		if value == "" then
			if spec.nilable then return nil end
			return nil, key .. " cannot be empty"
		end
		if spec.choices and not IsChoice(spec, value) then
			return nil, key .. " must be one of " .. table.concat(spec.choices, ", ")
		end
		return value
	end
	return nil, "bad schema for " .. key
end

-- Cross-field rules: fullVoiceRange < silentRange, minVolume <= maxVolume.
local function EnforceRelations(db, changedKey)
	if db.fullVoiceRange >= db.silentRange then
		if changedKey == "fullVoiceRange" then
			db.silentRange = math.min(Hark.SETTINGS.silentRange.max, db.fullVoiceRange + 5)
			if db.fullVoiceRange >= db.silentRange then db.fullVoiceRange = db.silentRange - 5 end
		else
			db.fullVoiceRange = math.max(0, db.silentRange - 5)
		end
	end
	if db.minVolume > db.maxVolume then
		if changedKey == "maxVolume" then
			db.minVolume = db.maxVolume
		else
			db.maxVolume = db.minVolume
		end
	end
end

local function LoadDB()
	local db = type(HarkDB) == "table" and HarkDB or {}
	HarkDB = db

	-- Migrate v1 (0.1.0) keys
	if db.joinOnZoneChange ~= nil and db.autoJoin == nil then
		db.autoJoin = db.joinOnZoneChange and true or false
	end
	db.joinOnZoneChange = nil
	db.leaveOnZoneExit = nil

	for key, spec in pairs(Hark.SETTINGS) do
		local raw = db[key]
		if raw == nil then
			db[key] = spec.default
		else
			local clean = Validate(key, raw)
			if clean == nil and not spec.nilable then clean = spec.default end
			db[key] = clean
		end
	end
	EnforceRelations(db)

	-- Internal: GUIDs whose volume Hark has lowered and not yet restored.
	if type(db.lowered) ~= "table" then db.lowered = {} end
	-- Owned by UI.lua (CONTRACT.md 10.1): guaranteed to be a table, contents never validated or cleared.
	if type(db.ui) ~= "table" then db.ui = {} end
	-- Internal diagnostics (errors, selftest, trace): plain data for reading
	-- the SavedVariables file outside the game. Never validated beyond type.
	if type(db.errors) ~= "table" then db.errors = {} end
	if db.trace ~= nil and type(db.trace) ~= "table" then db.trace = nil end
	if db.selftest ~= nil and type(db.selftest) ~= "table" then db.selftest = nil end
	if db.joinlog ~= nil and type(db.joinlog) ~= "table" then db.joinlog = nil end
	if db.joindiag ~= nil and type(db.joindiag) ~= "table" then db.joindiag = nil end
	db.dbVersion = Hark.DB_VERSION
	Hark.db = db
	if Hark._diag then Hark._diag.FlushPendingErrors() end
end

---------------------------------------------------------------------------
-- Saved-variables fallback (WoW Forever beta)
---------------------------------------------------------------------------
-- On the Forever beta, SavedVariables survive a /reload but are not read back
-- after a relog or a client restart (reported by the ForeverVoice addon). Hark
-- keeps two extra copies of every schema setting plus Hark.db.ui:
--
-- * Addon-registered CVars HarkSave1..HarkSaveN. Per warcraft.wiki.gg these
--   are game-wide and survive a reload or relog, but not closing the game.
-- * One general (account) macro named HarkSettings whose body is a comment
--   holding the same data. Macros are stored server-side, so this is the only
--   copy that survives a client restart. A macro body holds 255 characters, so
--   the ui table is dropped from this copy when it does not fit. Hark only ever
--   edits a macro with that exact name whose first line is MACRO_TAG, so it
--   never overwrites a macro it did not create.
--
-- Load order: SavedVariables win whenever HarkDB carries dbVersion. Otherwise
-- the newest fallback copy is restored, at ADDON_LOADED if it is already
-- readable, else when it shows up (PLAYER_LOGIN, PLAYER_ENTERING_WORLD,
-- UPDATE_MACROS). Nothing is written to the fallback until that decision is
-- made, so a session that came up with defaults never overwrites a good copy.
-- Hark.db.loadedFrom records the path: savedvariables, cvar, macro or defaults.

local PERSIST = {
	CVAR_PREFIX = "HarkSave",  -- HarkSave1 .. HarkSave<MAX_CHUNKS>
	CHUNK = 200,               -- characters per CVar (no limit is documented; stay well under 255)
	MAX_CHUNKS = 12,
	MACRO_NAME = "HarkSettings", -- 16-character limit
	MACRO_TAG = "#Hark settings backup. Keep this macro.",
	MACRO_ICON = 134227,       -- Interface\Icons\INV_Misc_Horn_01
	MACRO_MAX = 255,
	FLUSH_DELAY = 3,           -- a Set is written at most this many seconds later
	TICK = 10,                 -- catches Hark.db.ui changes, which do not go through Set
	SETTLE = 3,                -- after PLAYER_ENTERING_WORLD, last chance for a late copy
	MACRO_WAIT = 15,           -- longest wait for the server to send the macros
	MAX_DEPTH = 8,
}

-- Short codes keep the macro copy small. "u" is reserved for the ui table.
-- A setting without a code is stored under its full name.
local KEY_CODES = {
	enabled = "e", autoJoin = "a", communityId = "c", streamId = "s",
	fullVoiceRange = "f", silentRange = "r", minVolume = "n", maxVolume = "x",
	fadeCurve = "k", hearUnknown = "h", layerAware = "l", debug = "d",
}

local persist = {
	ready = false,      -- true once the load path is decided; writing starts then
	source = nil,       -- "savedvariables", "cvar", "macro" or "defaults"
	touched = {},       -- keys the user changed before a late restore arrived
	applying = false,
	loadedFired = false,
	macrosLoaded = false,
	macroState = "waiting",
	lastCVarBody = nil,
	lastMacroBody = nil,
	flushTimer = nil,
	ticker = nil,
	enteredWorld = false,
}

-- Encoding. Grammar: T | F | #<number> | '<string> | ( key=value , ... )
-- Strings keep [%w_.] and escape everything else as ~XX, so the result has no
-- quotes, spaces, pipes or newlines and is safe in a CVar and in a macro line.
local function EscapeString(s)
	return (s:gsub("[^%w_%.]", function(c) return string.format("~%02X", c:byte()) end))
end

local function EncodeValue(v, depth)
	local kind = type(v)
	if kind == "boolean" then
		return v and "T" or "F"
	elseif kind == "number" then
		if v ~= v or v == math.huge or v == -math.huge then return nil end
		local s = tostring(v)
		if tonumber(s) ~= v then s = string.format("%.17g", v) end
		return "#" .. s
	elseif kind == "string" then
		return "'" .. EscapeString(v)
	elseif kind == "table" then
		if depth >= PERSIST.MAX_DEPTH or Hark.IsSecret(v) then return nil end
		local keys = {}
		for k in pairs(v) do
			local kt = type(k)
			if kt == "string" or (kt == "number" and k == k and k ~= math.huge and k ~= -math.huge) then
				keys[#keys + 1] = k
			end
		end
		table.sort(keys, function(a, b)
			local ta, tb = type(a), type(b)
			if ta ~= tb then return ta < tb end
			return a < b
		end)
		local parts = {}
		for _, k in ipairs(keys) do
			local ev = EncodeValue(v[k], depth + 1)
			if ev then parts[#parts + 1] = EncodeValue(k, depth + 1) .. "=" .. ev end
		end
		return "(" .. table.concat(parts, ",") .. ")"
	end
	return nil -- functions, userdata: not saved
end

-- Raises on malformed input; always called through pcall.
local function DecodeValue(s, pos, depth)
	local c = s:sub(pos, pos)
	if c == "T" then
		return true, pos + 1
	elseif c == "F" then
		return false, pos + 1
	elseif c == "#" then
		local raw = s:match("^[%d%.eE%+%-]+", pos + 1)
		local n = raw and tonumber(raw)
		if not n then error("bad number") end
		return n, pos + 1 + #raw
	elseif c == "'" then
		local raw = s:match("^[%w_%.~]*", pos + 1)
		if raw:gsub("~%x%x", ""):find("~", 1, true) then error("bad escape") end
		local str = raw:gsub("~(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
		return str, pos + 1 + #raw
	elseif c == "(" then
		if depth >= PERSIST.MAX_DEPTH then error("too deep") end
		local t = {}
		pos = pos + 1
		if s:sub(pos, pos) == ")" then return t, pos + 1 end
		while true do
			local k, v
			k, pos = DecodeValue(s, pos, depth + 1)
			if type(k) ~= "string" and type(k) ~= "number" then error("bad key") end
			if s:sub(pos, pos) ~= "=" then error("expected =") end
			v, pos = DecodeValue(s, pos + 1, depth + 1)
			t[k] = v
			local sep = s:sub(pos, pos)
			if sep == ")" then return t, pos + 1 end
			if sep ~= "," then error("expected , or )") end
			pos = pos + 1
		end
	end
	error("bad token")
end

local function Checksum(s)
	local a, b = 1, 0
	for i = 1, #s do
		a = (a + s:byte(i)) % 65521
		b = (b + a) % 65521
	end
	return b * 65536 + a
end

local function Now()
	if GetServerTime then return GetServerTime() or 0 end
	if time then return time() or 0 end
	return 0
end

-- Payload: HK1:<stamp>:<length>:<checksum>:<body>. Anything after <length>
-- characters of body is ignored (stale CVar chunks from a longer save).
local function Pack(body)
	-- %.0f, not %d: the checksum can exceed 2^31 and this client's %d refuses that.
	return string.format("HK1:%.0f:%d:%.0f:", Now(), #body, Checksum(body)) .. body
end

--- Returns the decoded table and its timestamp, or nil for anything corrupt.
local function Unpack(payload)
	if type(payload) ~= "string" then return nil end
	local stamp, len, sum, start = payload:match("^HK1:(%d+):(%d+):(%d+):()")
	if not stamp then return nil end
	len = tonumber(len)
	local body = payload:sub(start, start + len - 1)
	if #body ~= len or Checksum(body) ~= tonumber(sum) then return nil end
	local ok, t, stop = pcall(DecodeValue, body, 1, 0)
	if not ok or type(t) ~= "table" or stop ~= #body + 1 then return nil end
	return t, tonumber(stamp)
end

local function Snapshot(db, withUI)
	local t = {}
	for key in pairs(Hark.SETTINGS) do
		if db[key] ~= nil then t[KEY_CODES[key] or key] = db[key] end
	end
	if withUI and type(db.ui) == "table" then t.u = db.ui end
	return t
end

local function IsDefaultState(db)
	for key, spec in pairs(Hark.SETTINGS) do
		if db[key] ~= spec.default then return false end
	end
	return type(db.ui) ~= "table" or next(db.ui) == nil
end

-- CVar copy ------------------------------------------------------------------

local function HasCVarAPI()
	return type(C_CVar) == "table" and C_CVar.RegisterCVar and C_CVar.GetCVar and C_CVar.SetCVar and true or false
end

local registeredCVars = {}
local function EnsureCVar(name)
	if not registeredCVars[name] then
		-- Registering again keeps an existing value (that is how they survive a relog).
		local ok, err = pcall(C_CVar.RegisterCVar, name, "")
		if not ok then Hark._RecordError("C_CVar.RegisterCVar", err) end
		registeredCVars[name] = true
	end
end

local function ReadCVars()
	if not HasCVarAPI() then return nil end
	local parts = {}
	for i = 1, PERSIST.MAX_CHUNKS do
		local name = PERSIST.CVAR_PREFIX .. i
		EnsureCVar(name)
		local ok, value = pcall(C_CVar.GetCVar, name)
		if not ok then Hark._RecordError("C_CVar.GetCVar", value) end
		if not ok or type(value) ~= "string" or value == "" then break end
		parts[#parts + 1] = value
	end
	if #parts == 0 then return nil, 0 end
	local t, stamp = Unpack(table.concat(parts))
	return t, stamp, #parts
end

local function WriteCVars(payload)
	if not HasCVarAPI() then return false end
	local count = math.ceil(#payload / PERSIST.CHUNK)
	if count > PERSIST.MAX_CHUNKS then return false end
	for i = 1, count do
		local name = PERSIST.CVAR_PREFIX .. i
		EnsureCVar(name)
		local ok, res = pcall(C_CVar.SetCVar, name, payload:sub((i - 1) * PERSIST.CHUNK + 1, i * PERSIST.CHUNK))
		if not ok then Hark._RecordError("C_CVar.SetCVar", res) end
		if not ok or res == false then return false end
	end
	if count < PERSIST.MAX_CHUNKS then -- end marker; Unpack ignores anything past the length anyway
		local name = PERSIST.CVAR_PREFIX .. (count + 1)
		EnsureCVar(name)
		pcall(C_CVar.SetCVar, name, "")
	end
	return true
end

-- Macro copy -------------------------------------------------------------------

local function HasMacroAPI()
	return GetMacroIndexByName and GetMacroInfo and CreateMacro and EditMacro and GetNumMacros and true or false
end

-- Macros arrive from the server shortly after login; before that the list is
-- empty and creating one could duplicate an existing copy.
local function MacrosReady()
	if not HasMacroAPI() then return false end
	if persist.macrosLoaded then return true end
	local ok, n = pcall(GetNumMacros)
	return ok and (n or 0) > 0
end

local function MaxAccountMacros()
	return tonumber(MAX_ACCOUNT_MACROS) or 120
end

--- index, body of Hark's own macro; nil when absent; nil, "taken" when a macro
-- with that name exists that Hark did not create (never touched).
local function FindOwnMacro()
	local ok, index = pcall(GetMacroIndexByName, PERSIST.MACRO_NAME)
	if not ok or type(index) ~= "number" or index <= 0 then return nil end
	local ok2, name, _, body = pcall(GetMacroInfo, index)
	if ok2 and name == PERSIST.MACRO_NAME and index <= MaxAccountMacros() and type(body) == "string"
		and body:sub(1, #PERSIST.MACRO_TAG) == PERSIST.MACRO_TAG then
		return index, body
	end
	return nil, "taken"
end

local function ReadMacro()
	if not MacrosReady() then return nil end
	local _, body = FindOwnMacro()
	if not body then return nil end
	return Unpack(body:match("\n#(HK1:[^\n]*)"))
end

-- true when the macro holds this payload (or there is nothing worth saving yet).
local function WriteMacro(payload, db)
	if not MacrosReady() then persist.macroState = HasMacroAPI() and "waiting" or "unavailable" return false end
	local text = PERSIST.MACRO_TAG .. "\n#" .. payload
	if #text > PERSIST.MACRO_MAX then return false end
	if InCombatLockdown and InCombatLockdown() then return false end
	local index, state = FindOwnMacro()
	if state == "taken" then
		persist.macroState = "name taken by another macro"
		return false
	end
	if index then
		local _, _, current = GetMacroInfo(index)
		if current == text then persist.macroState = "ok" return true end
		local ok, err = pcall(EditMacro, index, nil, nil, text)
		if not ok then Hark._RecordError("EditMacro", err) end
		persist.macroState = ok and "ok" or "edit failed"
		return ok
	end
	if IsDefaultState(db) then persist.macroState = "not needed (default settings)" return true end
	if (GetNumMacros() or 0) >= MaxAccountMacros() then
		if persist.macroState ~= "no free account macro slot" then
			Hark:Print("All general macro slots are in use, so settings cannot survive a game restart. Free one and /reload.")
		end
		persist.macroState = "no free account macro slot"
		return false
	end
	local ok, err = pcall(CreateMacro, PERSIST.MACRO_NAME, PERSIST.MACRO_ICON, text, nil)
	if not ok then Hark._RecordError("CreateMacro", err) end
	persist.macroState = ok and "ok" or "create failed"
	return ok
end

-- Saving -------------------------------------------------------------------------

local function Flush()
	local db = Hark.db
	if not persist.ready or not db then return end
	local okFull, full = pcall(EncodeValue, Snapshot(db, true), 0)
	local okSlim, slim = pcall(EncodeValue, Snapshot(db, false), 0)
	if not okFull or not full or not okSlim or not slim then return end
	if full ~= persist.lastCVarBody then
		if WriteCVars(Pack(full)) or WriteCVars(Pack(slim)) then persist.lastCVarBody = full end
	end
	if full ~= persist.lastMacroBody and HasMacroAPI() then
		if WriteMacro(Pack(full), db) or WriteMacro(Pack(slim), db) then persist.lastMacroBody = full end
	end
end

-- Called after every change. Writes are coalesced into one per FLUSH_DELAY.
local function ScheduleFlush()
	if not persist.ready or persist.flushTimer then return end
	if not (C_Timer and C_Timer.NewTimer) then Flush() return end
	persist.flushTimer = C_Timer.NewTimer(PERSIST.FLUSH_DELAY, function()
		persist.flushTimer = nil
		Flush()
	end)
end

local function NoteChange(key)
	if persist.ready then
		ScheduleFlush()
	elseif not persist.applying and key then
		persist.touched[key] = true
	end
end

-- Restoring ------------------------------------------------------------------------

local function ApplySnapshot(snap)
	local db = Hark.db
	local before = {}
	for k in pairs(Hark.SETTINGS) do before[k] = db[k] end
	local wantEnabled = db.enabled
	for key, spec in pairs(Hark.SETTINGS) do
		if not persist.touched[key] then
			local raw = snap[KEY_CODES[key] or key]
			local clean
			if raw == nil then
				if spec.nilable then clean = nil else clean = db[key] end
			else
				clean = Validate(key, raw)
				if clean == nil and not spec.nilable then clean = db[key] end
			end
			if key == "enabled" then wantEnabled = clean else db[key] = clean end
		end
	end
	EnforceRelations(db)
	if type(snap.u) == "table" then
		-- Same table, new contents: anything holding a reference to db.ui stays valid.
		if type(db.ui) ~= "table" then db.ui = {} end
		for k in pairs(db.ui) do db.ui[k] = nil end
		for k, v in pairs(snap.u) do db.ui[k] = v end
	end
	if not persist.loadedFired then
		db.enabled = wantEnabled
		return
	end
	persist.applying = true
	for k in pairs(Hark.SETTINGS) do
		if k ~= "enabled" and db[k] ~= before[k] then Hark:Fire("SETTING_CHANGED", k, db[k]) end
	end
	if wantEnabled ~= db.enabled then Hark:SetEnabled(wantEnabled) end
	persist.applying = false
	Hark:Fire("SETTINGS_RESTORED", persist.source)
end

local function FinishRestore(source)
	if persist.ready then return end
	persist.source = source
	persist.ready = true
	if Hark.db then Hark.db.loadedFrom = source end
	if source == "cvar" or source == "macro" then
		Hark:Print("The game did not load Hark's saved settings, so they were restored from the backup ("
			.. (source == "cvar" and "CVar" or "macro") .. " copy).")
	end
	if C_Timer and C_Timer.NewTicker and not persist.ticker then
		persist.ticker = C_Timer.NewTicker(PERSIST.TICK, Flush)
	end
	ScheduleFlush()
end

--- Restores the newest fallback copy if one is readable. Returns true when done.
local function TryRestore()
	if persist.ready then return true end
	local best, bestStamp, from = nil, -1, nil
	local fromCVar, cvarStamp = ReadCVars()
	if fromCVar then best, bestStamp, from = fromCVar, cvarStamp or 0, "cvar" end
	local fromMacro, macroStamp = ReadMacro()
	if fromMacro and (macroStamp or 0) > bestStamp then best, from = fromMacro, "macro" end
	if not best then return false end
	persist.source = from
	local ok, err = pcall(ApplySnapshot, best)
	if not ok then
		geterrorhandler()(err)
		return false
	end
	FinishRestore(from)
	return true
end

-- Last chance after entering the world: restore if possible, else settle on defaults.
local function FinalRestore(force)
	if persist.ready then return end
	if TryRestore() then return end
	if force or not HasMacroAPI() or MacrosReady() then FinishRestore("defaults") end
end

local function PersistStatusLines()
	local lines = {}
	lines[#lines + 1] = "Settings loaded from: " .. tostring(persist.source or "pending")
		.. (persist.ready and "" or " (waiting for a backup copy)")
	if HasCVarAPI() then
		local t, stamp, parts = ReadCVars()
		lines[#lines + 1] = string.format("CVar backup: %s (%d part(s)%s)", t and "ok" or "missing", parts or 0,
			(t and stamp and stamp > 0 and date) and (", saved " .. date("%d/%m %H:%M:%S", stamp)) or "")
	else
		lines[#lines + 1] = "CVar backup: unavailable on this client"
	end
	if HasMacroAPI() then
		local t = ReadMacro()
		lines[#lines + 1] = "Macro backup (" .. PERSIST.MACRO_NAME .. "): " .. (t and "ok" or "missing")
			.. ", " .. tostring(persist.macroState)
	else
		lines[#lines + 1] = "Macro backup: unavailable on this client"
	end
	return lines
end

-- Exposed for the headless tests only (not part of CONTRACT.md).
Hark._persist = {
	Encode = function(v) return EncodeValue(v, 0) end,
	Decode = function(s) local ok, v, stop = pcall(DecodeValue, s, 1, 0) if ok and stop == #s + 1 then return v end end,
	Pack = Pack, Unpack = Unpack, Flush = Flush, State = persist, Status = PersistStatusLines,
	CONFIG = PERSIST,
}


---------------------------------------------------------------------------
-- Callbacks
---------------------------------------------------------------------------

local callbacks = {} -- [event] = { [owner] = fn }

--- Register fn(event, ...) for an internal Hark event. owner is any unique key
-- (usually the module table); registering again with the same owner replaces.
function Hark:RegisterCallback(event, owner, fn)
	assert(type(event) == "string" and owner ~= nil and type(fn) == "function", "Usage: Hark:RegisterCallback(event, owner, fn)")
	callbacks[event] = callbacks[event] or {}
	callbacks[event][owner] = fn
end

function Hark:UnregisterCallback(event, owner)
	if callbacks[event] then callbacks[event][owner] = nil end
end

--- Fire an internal event. Errors in one listener do not stop the others.
function Hark:Fire(event, ...)
	local list = callbacks[event]
	if not list then return end
	for _, fn in pairs(list) do
		local ok, err = pcall(fn, event, ...)
		if not ok then geterrorhandler()(err) end
	end
end

---------------------------------------------------------------------------
-- Settings API
---------------------------------------------------------------------------

function Hark:Get(key)
	if not self.db then
		local spec = self.SETTINGS[key]
		return spec and spec.default
	end
	return self.db[key]
end

--- Validate and store a setting. Returns true, or false plus an error string.
-- Fires SETTING_CHANGED(key, value) for every key that actually changed
-- (cross-field rules may change a second key).
function Hark:Set(key, value)
	if not self.db then return false, "not loaded yet" end
	if key == "enabled" then return self:SetEnabled(value) end
	local clean, err = Validate(key, value)
	if err then return false, err end

	local before = {}
	for k in pairs(self.SETTINGS) do before[k] = self.db[k] end
	self.db[key] = clean
	EnforceRelations(self.db, key)
	for k in pairs(self.SETTINGS) do
		if self.db[k] ~= before[k] then
			NoteChange(k)
			self:Fire("SETTING_CHANGED", k, self.db[k])
		end
	end
	NoteChange(key)
	return true
end

function Hark:ResetSettings()
	if not self.db then return end
	local wasEnabled = self.db.enabled
	for key, spec in pairs(self.SETTINGS) do
		if key ~= "enabled" and self.db[key] ~= spec.default then
			self.db[key] = spec.default
			NoteChange(key)
			self:Fire("SETTING_CHANGED", key, spec.default)
		end
	end
	if not wasEnabled then self:SetEnabled(true) end
end

function Hark:GetDefault(key)
	local spec = self.SETTINGS[key]
	return spec and spec.default
end

function Hark:IsEnabled()
	return self.db ~= nil and self.db.enabled == true
end

--- The only way to turn proximity on or off. Disabling restores every volume.
function Hark:SetEnabled(on)
	if not self.db then return false, "not loaded yet" end
	on = on and true or false
	if self.db.enabled == on then return true end
	self.db.enabled = on
	NoteChange("enabled")
	if not on and self.Voice then self.Voice:RestoreAllVolumes() end
	self:Fire("SETTING_CHANGED", "enabled", on)
	self:Fire("ENABLED_CHANGED", on)
	return true
end

---------------------------------------------------------------------------
-- Volume curve (pure; UI can call it for a preview)
---------------------------------------------------------------------------

Hark.CURVES = {
	linear  = function(t) return t end,
	natural = function(t) return t * t end,             -- drops quickly, lingers quietly
	smooth  = function(t) return t * t * (3 - 2 * t) end, -- smoothstep: gentle at both ends
}

--- Volume (0-100) for a distance in yards using the current settings.
-- Within fullVoiceRange: maxVolume. Between fullVoiceRange and silentRange:
-- from maxVolume down to minVolume along fadeCurve. At or beyond silentRange: 0.
function Hark:GetVolumeForDistance(distance)
	local db = self.db or {}
	local full = db.fullVoiceRange or self.SETTINGS.fullVoiceRange.default
	local silent = db.silentRange or self.SETTINGS.silentRange.default
	local maxVol = db.maxVolume or self.SETTINGS.maxVolume.default
	local minVol = db.minVolume or self.SETTINGS.minVolume.default
	if not distance or distance ~= distance then return 0 end
	if distance <= full then return maxVol end
	if distance >= silent then return 0 end
	local t = (silent - distance) / (silent - full) -- 1 at full range, 0 at silent range
	local curve = self.CURVES[db.fadeCurve] or self.CURVES.smooth
	local v = minVol + (maxVol - minVol) * curve(t)
	return math.floor(v + 0.5)
end

---------------------------------------------------------------------------
-- Helpers shared by modules
---------------------------------------------------------------------------

--- true when v is a Midnight-era "secret value" that addon code must not inspect.
function Hark.IsSecret(v)
	if issecretvalue and issecretvalue(v) then return true end
	if type(v) == "table" and issecrettable and issecrettable(v) then return true end
	return false
end

function Hark:Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF96[Hark]|r " .. tostring(msg))
end

function Hark:Debug(msg)
	if self.db and self.db.debug then
		DEFAULT_CHAT_FRAME:AddMessage("|cFF808080[Hark debug]|r " .. tostring(msg))
	end
end

---------------------------------------------------------------------------
-- Diagnostics: error capture and trace buffer (internal, not in CONTRACT.md)
---------------------------------------------------------------------------
-- Every Lua error any addon raises goes to the client's error handler, whether
-- or not the scriptErrors CVar shows it. Hark wraps that handler and appends
-- each error to HarkDB.errors, so it can be read from the SavedVariables file
-- after a /reload or logout. Hark's own protected calls, which swallow their
-- errors, report them through Hark._RecordError. Diagnostics.lua adds the
-- /hark selftest and /hark trace commands on top.

local DIAG = {
	ERRORS_MAX = 50,     -- newest kept
	MESSAGE_MAX = 600,   -- characters
	STACK_MAX = 1200,
	TRACE_MAX = 600,     -- rows, newest kept
}

local diag = {
	traceOn = false,     -- session only, never saved
	pending = {},        -- errors raised before HarkDB is loaded
	inHandler = false,
	wrapper = nil,       -- our error handler, once installed
	traceWho = {},       -- [guid] = name already written as a "who" row this trace
	CONFIG = DIAG,
}
Hark._diag = diag

--- GetTime() rounded to 0.1 s (nil if unreadable). Trace rows and errors carry it.
local function ClockNow()
	if type(GetTime) ~= "function" then return nil end
	local ok, t = pcall(GetTime)
	if not ok or Hark.IsSecret(t) or type(t) ~= "number" then return nil end
	return math.floor(t * 10 + 0.5) / 10
end
diag.ClockNow = ClockNow

local function Clip(v, max)
	if v == nil then return nil end
	if Hark.IsSecret(v) then return "<secret>" end
	local ok, s = pcall(tostring, v)
	if not ok or type(s) ~= "string" then return "<unprintable>" end
	if #s > max then s = s:sub(1, max) .. "..." end
	return s
end

local function ErrorBuffer()
	local db = Hark.db
	if db then
		if type(db.errors) ~= "table" then db.errors = {} end
		return db.errors
	end
	return diag.pending
end

local function AppendError(where, message, stack)
	local buf = ErrorBuffer()
	local msg = Clip(message, DIAG.MESSAGE_MAX) or "nil"
	where = Clip(where, 80) or "?"
	-- The same error repeating (an OnUpdate, a ticker) is one entry with a count.
	for _, e in ipairs(buf) do
		if type(e) == "table" and e.message == msg and e.where == where then
			e.count = (tonumber(e.count) or 1) + 1
			e.lastTime, e.lastT = Now(), ClockNow()
			return
		end
	end
	buf[#buf + 1] = { time = Now(), t = ClockNow(), where = where, message = msg,
		stack = Clip(stack, DIAG.STACK_MAX), count = 1 }
	while #buf > DIAG.ERRORS_MAX do table.remove(buf, 1) end
end

--- Internal: record an error a protected call swallowed. Never raises.
-- where: the function that failed, e.g. "C_VoiceChat.GetChannel".
function Hark._RecordError(where, message)
	local stack
	if type(debugstack) == "function" then
		local ok, s = pcall(debugstack, 2)
		if ok then stack = s end
	end
	pcall(AppendError, where, message, stack)
end

function diag.FlushPendingErrors()
	if not Hark.db or #diag.pending == 0 then return end
	local list = diag.pending
	diag.pending = {}
	for _, e in ipairs(list) do
		local buf = ErrorBuffer()
		buf[#buf + 1] = e
		while #buf > DIAG.ERRORS_MAX do table.remove(buf, 1) end
	end
end

--- Wrap the client's error handler (again, if something replaced ours). The
-- original handler still runs for every error, so the client's own display
-- and other error addons behave exactly as before.
function diag.InstallErrorHandler()
	if type(geterrorhandler) ~= "function" or type(seterrorhandler) ~= "function" then return false end
	local ok, original = pcall(geterrorhandler)
	if not ok then return false end
	if original ~= nil and original == diag.wrapper then return true end
	local wrapper = function(message, ...)
		if not diag.inHandler then
			diag.inHandler = true
			local stack
			if type(debugstack) == "function" then
				local okStack, s = pcall(debugstack, 2)
				if okStack then stack = s end
			end
			pcall(AppendError, "error handler", message, stack)
			diag.inHandler = false
		end
		if type(original) == "function" then return original(message, ...) end
	end
	if pcall(seterrorhandler, wrapper) then
		diag.wrapper = wrapper
		return true
	end
	return false
end

--- Plain, typed copy of a client value for the join log and /hark joindiag:
-- { t = luaType, v = value }. A secret value becomes { t = "secret",
-- v = "<secret>" } and is never stored raw. nil is { t = "nil" }. Tables are
-- copied field by field to `maxDepth` levels (default 3), at most 24 fields each.
local TYPED_FIELDS = 24
function diag.Typed(v, maxDepth, depth)
	if v == nil then return { t = "nil" } end
	if Hark.IsSecret(v) then return { t = "secret", v = "<secret>" } end
	local kind = type(v)
	if kind == "number" then
		if v ~= v then return { t = kind, v = "nan" } end
		if v == math.huge or v == -math.huge then return { t = kind, v = v > 0 and "inf" or "-inf" } end
		return { t = kind, v = v }
	elseif kind == "string" then
		if #v > 120 then v = v:sub(1, 120) .. "..." end
		return { t = kind, v = v }
	elseif kind == "boolean" then
		return { t = kind, v = v }
	elseif kind == "table" then
		depth = depth or 0
		if depth >= (maxDepth or 3) then return { t = kind, v = "<table>" } end
		local out, count = {}, 0
		for k, val in pairs(v) do
			count = count + 1
			if count > TYPED_FIELDS then out["(truncated)"] = { t = "note", v = "more fields not kept" } break end
			local key = k
			if Hark.IsSecret(k) then
				key = "<secret>" .. count
			elseif type(k) ~= "string" and not (type(k) == "number" and k == k and k ~= math.huge and k ~= -math.huge) then
				key = "<" .. type(k) .. ">" .. count
			end
			out[key] = diag.Typed(val, maxDepth, depth + 1)
		end
		return { t = kind, v = out }
	end
	return { t = kind, v = "<" .. kind .. ">" }
end

--- "Player-4184-0A1B2C3D" -> "0A1B2C3D" (nil stays nil).
function diag.ShortGUID(guid)
	if type(guid) ~= "string" or Hark.IsSecret(guid) then return nil end
	return guid:match("%-(%x+)$") or guid
end

--- Internal: append one row to HarkDB.trace while /hark trace is on.
function Hark._Trace(row)
	if not diag.traceOn or not Hark.db or type(row) ~= "table" then return end
	local buf = Hark.db.trace
	if type(buf) ~= "table" then
		buf = {}
		Hark.db.trace = buf
	end
	if row.t == nil then row.t = ClockNow() end
	buf[#buf + 1] = row
	while #buf > DIAG.TRACE_MAX do table.remove(buf, 1) end
end

--- Internal: a "who" row the first time a GUID (or its name) shows up in a trace.
function Hark._TraceWho(guid, name)
	if not diag.traceOn or type(guid) ~= "string" then return end
	if Hark.IsSecret(name) or type(name) ~= "string" then name = nil end
	local known = diag.traceWho[guid]
	if known ~= nil and (known == name or name == nil) then return end
	diag.traceWho[guid] = name or false
	Hark._Trace({ k = "who", g = diag.ShortGUID(guid), guid = guid, n = name })
end

diag.InstallErrorHandler()

local function SafeInit(module, name)
	if module and type(module.Init) == "function" then
		local ok, err = pcall(module.Init, module)
		if not ok then
			geterrorhandler()(err)
			Hark:Print(name .. " failed to start: " .. tostring(err))
		end
	end
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------

local function PrintHelp()
	Hark:Print("Commands:")
	Hark:Print("  /hark on | off                 Enable or disable proximity volumes")
	Hark:Print("  /hark join | leave             Join or leave the community voice channel")
	Hark:Print("  /hark status                   Channel, members, distances and volumes")
	Hark:Print("  /hark communities              List your communities and their ids")
	Hark:Print("  /hark setcommunity <clubId> [streamId]")
	Hark:Print("  /hark layer                    Show the detected layer (zone copy) id")
	Hark:Print("  /hark debug                    Toggle debug output (also shows the settings backup)")
	Hark:Print("  /hark backup                   Where settings were loaded from, and the backup copies")
	Hark:Print("  /hark show | hide | toggle     Show or hide the member panel")
	Hark:Print("  /hark options                  Open settings")
	Hark:Print("  /hark selftest                 Probe the client and save the results (then /reload)")
	Hark:Print("  /hark trace on | off | clear   Record volumes and messages to the saved variables")
	Hark:Print("  /hark joindiag                 Record a voice join attempt for 20 s (then /reload)")
end

local function OnSlashCommand(msg)
	msg = strtrim(msg or "")
	local cmd, rest = msg:match("^(%S*)%s*(.-)$")
	cmd = (cmd or ""):lower()

	if cmd == "" or cmd == "help" then
		PrintHelp()
	elseif cmd == "on" then
		Hark:SetEnabled(true)
		Hark:Print("Proximity voice enabled.")
	elseif cmd == "off" then
		Hark:SetEnabled(false)
		Hark:Print("Proximity voice disabled. Everyone is back to full volume.")
	elseif cmd == "join" then
		local ok, err = Hark.Voice:Join()
		if not ok then Hark:Print(err) end
	elseif cmd == "leave" then
		Hark.Voice:Leave()
	elseif cmd == "status" then
		Hark.Voice:PrintStatus()
	elseif cmd == "communities" then
		local list = Hark.Voice:ListCommunities()
		if #list == 0 then
			Hark:Print("No communities found (the community list may still be loading).")
		end
		for _, c in ipairs(list) do
			Hark:Print(string.format("  %s  id %s%s", c.name, c.clubId,
				c.clubId == Hark.db.communityId and "  (selected)" or ""))
		end
	elseif cmd == "setcommunity" then
		local clubId, streamId = rest:match("^(%S+)%s*(%S*)$")
		if not clubId then
			Hark:Print("Usage: /hark setcommunity <clubId> [streamId]")
			Hark:Print("Example: /hark setcommunity 23111161")
			return
		end
		local ok, err = Hark:Set("communityId", clubId)
		if ok then ok, err = Hark:Set("streamId", streamId ~= "" and streamId or nil) end
		if not ok then Hark:Print(err) return end
		Hark:Print("Community set to " .. clubId .. (streamId ~= "" and (" stream " .. streamId) or "") .. ".")
	elseif cmd == "layer" then
		local layer, confident, zone = Hark.Positions:GetLayer()
		Hark:Print(string.format("Zone %s, layer %s (%s).", tostring(zone or "?"), tostring(layer or "unknown"),
			confident and "confirmed" or (layer and "unconfirmed" or "target or mouse over an NPC to detect")))
	elseif cmd == "debug" then
		Hark:Set("debug", not Hark.db.debug)
		Hark:Print("Debug " .. (Hark.db.debug and "on" or "off") .. ".")
		for _, line in ipairs(PersistStatusLines()) do Hark:Print("  " .. line) end
	elseif cmd == "backup" then
		Flush()
		for _, line in ipairs(PersistStatusLines()) do Hark:Print(line) end
	elseif cmd == "show" or cmd == "hide" or cmd == "toggle" then
		if Hark.UI and type(Hark.UI.Show) == "function" then
			if cmd == "show" then
				Hark.UI:Show()
			elseif cmd == "hide" then
				Hark.UI:Hide()
			else
				Hark.UI:Toggle()
			end
			-- Confirm in chat: these commands exist to recover a panel that is
			-- hidden or stranded off-screen, where there is nothing to see.
			local state
			if type(Hark.UI.IsShown) == "function" then
				state = Hark.UI:IsShown() and "shown" or "hidden"
			else
				state = (cmd == "hide") and "hidden" or "shown"
			end
			Hark:Print("Panel " .. state .. ".")
		else
			Hark:Print("The panel is not available on this client.")
		end
	elseif cmd == "selftest" or cmd == "trace" or cmd == "joindiag" then
		if Hark.Diagnostics and type(Hark.Diagnostics.OnSlash) == "function" then
			Hark.Diagnostics:OnSlash(cmd, rest)
		else
			Hark:Print("Diagnostics are not available.")
		end
	elseif cmd == "options" or cmd == "config" then
		if Hark.Options and type(Hark.Options.Open) == "function" then
			Hark.Options:Open()
		else
			Hark:Print("Options panel is not available yet.")
		end
	else
		PrintHelp()
	end
end

-- Required framework globals (the slash system reads these from _G).
SLASH_HARK1 = "/hark"
SLASH_HARK2 = "/ha"
SlashCmdList["HARK"] = OnSlashCommand

-- Required by "## AddonCompartmentFunc" in Hark.toc, which the client looks up in _G.
function Hark_OnAddonCompartmentClick()
	if Hark.UI and type(Hark.UI.Toggle) == "function" then
		Hark.UI:Toggle()
	elseif Hark.Options and type(Hark.Options.Open) == "function" then
		Hark.Options:Open()
	else
		PrintHelp()
	end
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
-- Optional: the saved-settings fallback also works without it (MacrosReady polls).
pcall(frame.RegisterEvent, frame, "UPDATE_MACROS")

frame:SetScript("OnEvent", function(self, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 ~= ADDON_NAME then return end
		self:UnregisterEvent("ADDON_LOADED")
		-- SavedVariables count as loaded only when they carry the dbVersion marker.
		local hadSavedVariables = type(HarkDB) == "table" and HarkDB.dbVersion ~= nil
		LoadDB()
		if hadSavedVariables then
			FinishRestore("savedvariables")
		else
			TryRestore()
		end
		SafeInit(Hark.Positions, "Positions")
		SafeInit(Hark.Voice, "Voice")
		SafeInit(Hark.UI, "UI")
		SafeInit(Hark.Options, "Options")
		persist.loadedFired = true
		Hark:Fire("LOADED")
	elseif event == "PLAYER_LOGIN" then
		-- An error addon loaded after Hark may have replaced the handler: wrap it too.
		diag.InstallErrorHandler()
		TryRestore()
		Hark:Print("Loaded (v" .. Hark.version .. "). Type /hark help for commands.")
		if Hark.Voice then Hark.Voice:OnLogin() end
		if Hark.Positions then Hark.Positions:OnLogin() end
	elseif event == "PLAYER_ENTERING_WORLD" then
		if persist.enteredWorld then return end
		persist.enteredWorld = true
		TryRestore()
		if C_Timer and C_Timer.After then
			C_Timer.After(PERSIST.SETTLE, function() FinalRestore(false) end)
			C_Timer.After(PERSIST.MACRO_WAIT, function()
				-- An account with no macros may never get UPDATE_MACROS: stop waiting.
				persist.macrosLoaded = true
				FinalRestore(true)
				ScheduleFlush()
			end)
		else
			FinalRestore(true)
		end
	elseif event == "UPDATE_MACROS" then
		persist.macrosLoaded = true
		if not persist.ready then TryRestore() end
	elseif event == "PLAYER_LOGOUT" then
		-- The client may remember per-player volumes: never leave anyone quiet.
		if Hark.Voice then Hark.Voice:RestoreAllVolumes() end
		pcall(Flush)
	end
end)
