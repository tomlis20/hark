--- Hark: self-test and trace (internal; not part of CONTRACT.md)
-- /hark selftest probes everything the build could not verify without a real
-- client and stores the raw answers in HarkDB.selftest. /hark trace records
-- volume passes and position messages in HarkDB.trace. Both are plain data,
-- written to WTF/Account/<account>/SavedVariables/Hark.lua on /reload or
-- logout, and read with Tests/readselftest.lua. Error capture lives in Core.

local _, ns = ...
local Hark = ns.Hark

local Diagnostics = {}
Hark.Diagnostics = Diagnostics

local diag = Hark._diag
local SECRET = "<secret>"
local SEND_WAIT = 6        -- seconds to wait for the position send probe
local MAX_NAMEPLATES = 40

---------------------------------------------------------------------------
-- Probe kit
---------------------------------------------------------------------------

local function Now()
	local ok, t = false, nil
	if type(GetServerTime) == "function" then ok, t = pcall(GetServerTime) end
	if ok and not Hark.IsSecret(t) and type(t) == "number" then return t end
	return 0
end

local function Pack(...)
	return { n = select("#", ...), ... }
end

--- Plain-data copy of a client value, safe to save: secrets become "<secret>",
-- inf and nan become strings, functions and userdata their type name.
-- Returns value, sawSecret.
local function Clean(v, depth)
	if v == nil then return nil, false end
	if Hark.IsSecret(v) then return SECRET, true end
	local kind = type(v)
	if kind == "number" then
		if v ~= v then return "nan", false end
		if v == math.huge then return "inf", false end
		if v == -math.huge then return "-inf", false end
		return v, false
	elseif kind == "string" then
		if #v > 300 then return v:sub(1, 300) .. "...", false end
		return v, false
	elseif kind == "boolean" then
		return v, false
	elseif kind == "table" then
		depth = depth or 0
		if depth >= 3 then return "<table>", false end
		local out, count, secret = {}, 0, false
		for k, val in pairs(v) do
			count = count + 1
			if count > 40 then out["(truncated)"] = true break end
			local key = k
			if Hark.IsSecret(k) then
				key, secret = SECRET .. count, true
			elseif type(k) ~= "string" and not (type(k) == "number" and k == k and k ~= math.huge and k ~= -math.huge) then
				key = "<" .. type(k) .. ">" .. count
			end
			local c, s = Clean(val, depth + 1)
			out[key] = c
			secret = secret or s
		end
		return out, secret
	end
	return "<" .. kind .. ">", false
end

local function AnySecret(...)
	for i = 1, select("#", ...) do
		if Hark.IsSecret((select(i, ...))) then return true end
		local _, s = Clean((select(i, ...)))
		if s then return true end
	end
	return false
end

local run -- the self-test in progress: { st, count }

--- Calls fn(...) protected and returns the record plus the raw results
-- ({ n = count, ... }; nil when absent or failed). The record holds what was
-- called, a status (ok / absent / error), the cleaned results and whether
-- any result was a secret value.
local function Run(id, call, fn, ...)
	local rec = { id = id, call = call }
	if run then run.count = run.count + 1 end
	if type(fn) ~= "function" then
		rec.status = "absent"
		return rec, nil
	end
	local all = Pack(pcall(fn, ...))
	if not all[1] then
		rec.status = "error"
		rec.err = (Clean(all[2]))
		Hark._RecordError("selftest " .. tostring(call), all[2])
		return rec, nil
	end
	local raw = { n = all.n - 1 }
	local results = { n = raw.n }
	local secret = false
	for i = 1, raw.n do
		raw[i] = all[i + 1]
		local c, s = Clean(raw[i])
		results[i] = c
		secret = secret or s
	end
	rec.status, rec.results, rec.secret = "ok", results, secret or nil
	return rec, raw
end

local D = { Run = Run, Clean = function(v) return (Clean(v)) end, AnySecret = AnySecret }

local function Lookup(path)
	local v = _G
	for part in path:gmatch("[^%.]+") do
		if type(v) ~= "table" then return nil end
		v = v[part]
	end
	return v
end

---------------------------------------------------------------------------
-- Probes
---------------------------------------------------------------------------

local API_PATHS = {
	-- C_VoiceChat, as used by Voice.lua
	"C_VoiceChat.GetActiveChannelID", "C_VoiceChat.GetChannel", "C_VoiceChat.GetChannelForCommunityStream",
	"C_VoiceChat.GetMemberGUID", "C_VoiceChat.GetMemberName", "C_VoiceChat.GetMemberVolume",
	"C_VoiceChat.SetMemberVolume", "C_VoiceChat.IsMemberLocalPlayer", "C_VoiceChat.IsLoggedIn",
	"C_VoiceChat.Login", "C_VoiceChat.ActivateChannel", "C_VoiceChat.DeactivateChannel",
	"C_VoiceChat.LeaveChannel", "C_VoiceChat.RequestJoinAndActivateCommunityStreamChannel",
	"C_Club.GetSubscribedClubs", "C_Club.GetStreams",
	"C_Map.GetBestMapForUnit", "C_Map.GetMapInfo",
	"GetPlayerInfoByGUID", "UnitPosition", "UnitIsVisible", "GetUnitSpeed",
	"PlayerLocation.CreateFromVoiceID", "PlayerLocation.CreateFromGUID",
	"C_ChatInfo.SendAddonMessage", "C_ChatInfo.RegisterAddonMessagePrefix",
	"C_CVar.RegisterCVar", "C_CVar.SetCVar", "C_CVar.GetCVar", "SetCVar", "GetCVar",
	"CreateMacro", "EditMacro", "GetMacroIndexByName", "GetMacroInfo", "GetNumMacros",
	"Settings.RegisterCanvasLayoutCategory", "Settings.RegisterAddOnCategory", "Settings.OpenToCategory",
	"InterfaceOptions_AddCategory", "InterfaceOptionsFrame_OpenToCategory", "UISpecialFrames",
	"C_Timer.NewTimer", "C_Timer.NewTicker", "AddonCompartmentFrame",
	"issecretvalue", "issecrettable", "geterrorhandler", "seterrorhandler", "debugstack", "GetBuildInfo",
}

local function ProbeAPIs(add)
	for _, path in ipairs(API_PATHS) do
		if run then run.count = run.count + 1 end
		local ok, v = pcall(Lookup, path)
		local rec = { id = "api", call = path }
		if not ok or v == nil then
			rec.status = "absent"
		else
			rec.status = "present"
			rec.type = Hark.IsSecret(v) and SECRET or type(v)
		end
		add(rec)
	end
end

local function UnitRecord(unit)
	local u = { id = "pos.unit", unit = unit, calls = {} }
	local function Add(r, raw) u.calls[#u.calls + 1] = r return r, raw end
	local _, raw = Add(Run("pos.exists", "UnitExists(" .. unit .. ")", UnitExists, unit))
	u.exists = raw and (Clean(raw[1]))
	local r
	r, raw = Add(Run("pos.guid", "UnitGUID(" .. unit .. ")", UnitGUID, unit))
	local guid = raw and raw[1]
	u.guid = r.results and r.results[1]
	r, raw = Add(Run("pos.name", "UnitName(" .. unit .. ")", UnitName, unit))
	if r.results then u.name, u.realm = r.results[1], r.results[2] end
	r = Add(Run("pos.isPlayer", "UnitIsPlayer(" .. unit .. ")", UnitIsPlayer, unit))
	u.isPlayer = r.results and r.results[1]
	r = Add(Run("pos.inParty", "UnitInParty(" .. unit .. ")", UnitInParty, unit))
	local inParty = r.results and r.results[1]
	r = Add(Run("pos.inRaid", "UnitInRaid(" .. unit .. ")", UnitInRaid, unit))
	local inRaid = r.results and r.results[1]
	if inParty == SECRET or inRaid == SECRET then
		u.inGroup = SECRET
	else
		u.inGroup = (inParty == true or (inRaid ~= nil and inRaid ~= false)) and true or false
	end
	r = Add(Run("pos.isUnitPlayer", "UnitIsUnit(" .. unit .. ", player)", UnitIsUnit, unit, "player"))
	u.isSelf = r.results and r.results[1]
	r = Add(Run("pos.visible", "UnitIsVisible(" .. unit .. ")", UnitIsVisible, unit))
	u.visible = r.results and r.results[1]
	r = Add(Run("pos.position", "UnitPosition(" .. unit .. ")", UnitPosition, unit))
	u.position = r.results
	u.positionSecret = r.secret
	if r.results then
		local a, b = r.results[1], r.results[2]
		if a == SECRET or b == SECRET then
			u.positionVerdict = "SECRET"
		elseif type(a) == "number" and type(b) == "number" then
			u.positionVerdict = "READABLE"
		else
			u.positionVerdict = "NIL"
		end
	else
		u.positionVerdict = r.status == "absent" and "ABSENT" or "ERROR"
	end
	-- What Hark itself makes of this player.
	if type(guid) == "string" and not Hark.IsSecret(guid) and Hark.Positions then
		local ok, d, reason = pcall(Hark.Positions.GetDistance, Hark.Positions, guid)
		if ok then u.harkDistance, u.harkReason = (Clean(d)), reason end
	end
	for _, c in ipairs(u.calls) do
		if c.secret then u.secret = true end
	end
	return u, guid
end

local function ProbePositions(add)
	local r = Run("pos.player", "UnitPosition(player)", UnitPosition, "player")
	add(r)
	add((UnitRecord("target")))
	add((UnitRecord("mouseover")))
	-- Nameplate tokens can have gaps, so every slot is checked; empty ones are skipped.
	local plates = 0
	for i = 1, MAX_NAMEPLATES do
		local unit = "nameplate" .. i
		local ok, guid = pcall(UnitGUID, unit)
		if ok and (Hark.IsSecret(guid) or guid ~= nil) then
			plates = plates + 1
			add((UnitRecord(unit)))
		end
	end
	add({ id = "pos.nameplateCount", value = plates })
end

local function ProbeLayer(add)
	local P = Hark.Positions
	local r = Run("layer.get", "Positions:GetLayer()", P and P.GetLayer, P)
	add(r)
	if P and type(P._Diag) == "function" then
		local ok, info = pcall(P._Diag)
		if ok and type(info) == "table" then
			add({ id = "layer.samples", samples = (Clean(info.samples)), cache = (Clean(info.layerCache)),
				zoneKey = info.zoneKey, knownPositions = info.knownCount, seenPlayers = info.seenCount })
		end
	end
end

local function ProbePersistence(add)
	local db = Hark.db
	local rec = { id = "persist", loadedFrom = db and db.loadedFrom }
	local p = Hark._persist
	if type(p) == "table" then
		if type(p.Flush) == "function" then
			local ok, err = pcall(p.Flush)
			if not ok then rec.flushError = (Clean(err)) end
		end
		if type(p.Status) == "function" then
			local ok, lines = pcall(p.Status)
			rec.status = ok and (Clean(lines)) or ("error: " .. tostring(Clean(lines)))
		end
		if type(p.State) == "table" then
			rec.ready, rec.source, rec.macroState = p.State.ready, p.State.source, p.State.macroState
		end
	end
	add(rec)
end

local function ProbeSettings(add)
	local rec = { id = "settings" }
	local O = Hark.Options
	if O and type(O._DiagState) == "function" then
		local ok, state = pcall(O._DiagState)
		if ok and type(state) == "table" then
			rec.registered, rec.buildError, rec.built = state.registered, state.buildError, state.built
		end
	else
		rec.registered = "unknown (no Options module)"
	end
	local special = _G.UISpecialFrames
	if type(special) == "table" then
		rec.specialFramesPresent = true
		rec.inSpecialFrames = false
		for _, name in ipairs(special) do
			if name == "HarkOptionsFrame" then rec.inSpecialFrames = true end
		end
	else
		rec.specialFramesPresent = false
	end
	rec.namedFrameExists = _G.HarkOptionsFrame ~= nil
	add(rec)
end

local function ProbeClient(add)
	add((Run("client.build", "GetBuildInfo()", GetBuildInfo)))
	add((Run("client.locale", "GetLocale()", GetLocale)))
	add((Run("client.player", "UnitName(player)", UnitName, "player")))
	add((Run("client.guid", "UnitGUID(player)", UnitGUID, "player")))
	add((Run("client.realm", "GetRealmName()", GetRealmName)))
	add((Run("client.normalizedRealm", "GetNormalizedRealmName()", GetNormalizedRealmName)))
	local getCVar = (type(C_CVar) == "table" and C_CVar.GetCVar) or GetCVar
	add((Run("client.nameplateShowFriends", "GetCVar(nameplateShowFriends)", getCVar, "nameplateShowFriends")))
	add((Run("client.scriptErrors", "GetCVar(scriptErrors)", getCVar, "scriptErrors")))
	add((Run("client.inGuild", "IsInGuild()", IsInGuild)))
	add((Run("client.inGroup", "IsInGroup()", IsInGroup)))
	add((Run("client.inRaid", "IsInRaid()", IsInRaid)))
	add({ id = "client.enumSendResult", value = (Clean(type(Enum) == "table" and Enum.SendAddonMessageResult or nil)) })
	add({ id = "client.hark", version = Hark.version, enabled = Hark:IsEnabled(),
		voiceState = Hark.Voice and Hark.Voice:GetState(), communityId = Hark.db and Hark.db.communityId,
		errorHandlerWrapped = diag.wrapper ~= nil and type(geterrorhandler) == "function" and geterrorhandler() == diag.wrapper })
end

-- Positions sends only from its tick, so the result arrives a few seconds later.
local function StartSendProbe(rec, done)
	local P = Hark.Positions
	if not (P and type(P._Diag) == "function" and type(P.RequestBroadcast) == "function") then
		rec.status = "absent"
		return done()
	end
	local okBefore, before = pcall(P._Diag)
	if not okBefore then rec.status = "error" return done() end
	rec.before = before.sendCount
	rec.targets = Clean(before.targets)
	rec.voiceActive = Hark.Voice and Hark.Voice:IsActive() or false
	rec.enabled = Hark:IsEnabled()
	P:RequestBroadcast()
	local waited = 0
	local function Check()
		local ok, now = pcall(P._Diag)
		if ok and now.sendCount > before.sendCount then
			rec.status = "sent"
			rec.lastSend = Clean(now.lastSend)
			return done()
		end
		waited = waited + 1
		if waited >= SEND_WAIT or not (C_Timer and C_Timer.NewTimer) then
			rec.status = "not sent"
			rec.reason = (not rec.enabled and "proximity is off")
				or (not rec.voiceActive and "not in the voice channel (Hark only sends while in it)")
				or (ok and #now.targets == 0 and "no guild or group to send to")
				or "no send within " .. SEND_WAIT .. " s (send budget?)"
			rec.lastSend = ok and Clean(now.lastSend) or nil
			return done()
		end
		C_Timer.NewTimer(1, Check)
	end
	if C_Timer and C_Timer.NewTimer then C_Timer.NewTimer(1, Check) else Check() end
end

---------------------------------------------------------------------------
-- /hark selftest
---------------------------------------------------------------------------

local function Summarise(st)
	local absent, secrets = 0, 0
	local function Visit(rec)
		if type(rec) ~= "table" then return end
		if rec.id == "api" and rec.status == "absent" then absent = absent + 1 end
		if rec.secret then secrets = secrets + 1 end
		if type(rec.calls) == "table" then for _, c in ipairs(rec.calls) do Visit(c) end end
	end
	for _, rec in ipairs(st.results) do Visit(rec) end
	local errors = 0
	for _, e in ipairs(Hark.db.errors or {}) do errors = errors + (tonumber(e.count) or 1) end
	st.summary = { probes = st.probes, absent = absent, secrets = secrets, errors = errors }
	return absent, secrets, errors
end

function Diagnostics:SelfTest()
	if not Hark.db then
		Hark:Print("Not loaded yet.")
		return
	end
	if run then
		Hark:Print("Self-test is already running.")
		return
	end
	diag.InstallErrorHandler()
	local st = { time = Now(), t = diag.ClockNow(), version = Hark.version, results = {}, complete = false }
	Hark.db.selftest = st
	run = { st = st, count = 0 }
	local function add(rec) st.results[#st.results + 1] = rec end

	-- Each section is guarded: one failing section is recorded, the rest still run.
	local sections = {
		{ "a.api", ProbeAPIs },
		{ "h.client", ProbeClient },
		{ "b.positions", ProbePositions },
		{ "c.voice", function(addRec)
			local V = Hark.Voice
			if not (V and type(V._SelfTest) == "function") then
				addRec({ id = "voice.activeChannel", status = "absent" })
				return
			end
			for _, rec in ipairs(V._SelfTest(D)) do addRec(rec) end
		end },
		{ "d.layer", ProbeLayer },
		{ "e.persistence", ProbePersistence },
		{ "f.settings", ProbeSettings },
	}
	for _, section in ipairs(sections) do
		local ok, err = pcall(section[2], add)
		if not ok then
			add({ id = "section.error", section = section[1], err = (Clean(err)) })
			Hark._RecordError("selftest " .. section[1], err)
		end
	end

	Hark:Print("Self-test running, a few seconds...")
	local sendRec = { id = "msg.send", call = "Positions:RequestBroadcast()" }
	add(sendRec)
	run.count = run.count + 1
	StartSendProbe(sendRec, function()
		st.probes = run.count
		st.complete = true
		st.duration = diag.ClockNow() and st.t and (diag.ClockNow() - st.t) or nil
		run = nil
		local absent, secrets, errors = Summarise(st)
		Hark:Print(string.format("Self-test done: %d probes, %d APIs absent, %d secret values, %d errors captured. Type /reload to save the results.",
			st.probes, absent, secrets, errors))
	end)
end

---------------------------------------------------------------------------
-- /hark joindiag
---------------------------------------------------------------------------
-- Records the pre-join facts, listens to every VOICE_CHAT_* event the client
-- accepts for JOINDIAG_SECONDS, calls Voice:Join(), and stores it all in
-- HarkDB.joindiag (CONTRACT.md 13). Voice's own step log (HarkDB.joinlog)
-- runs regardless; the entries from this window are copied in as well.

local JOINDIAG_SECONDS = 20
local JOINDIAG_EVENTS_MAX = 200
local JOINDIAG_RETRY_AT = 6   -- seconds: one string-form retry if the numeric request drew no event at all

-- Every VOICE_CHAT_* event in the Forever 1.60.1 API docs. Names the client
-- refuses are recorded as rejected, not raised.
local VOICE_EVENTS = {
	"VOICE_CHAT_ACTIVE_INPUT_DEVICE_UPDATED", "VOICE_CHAT_ACTIVE_OUTPUT_DEVICE_UPDATED",
	"VOICE_CHAT_AUDIO_CAPTURE_ENERGY", "VOICE_CHAT_AUDIO_CAPTURE_STARTED", "VOICE_CHAT_AUDIO_CAPTURE_STOPPED",
	"VOICE_CHAT_CHANNEL_ACTIVATED", "VOICE_CHAT_CHANNEL_DEACTIVATED", "VOICE_CHAT_CHANNEL_DISPLAY_NAME_CHANGED",
	"VOICE_CHAT_CHANNEL_JOINED", "VOICE_CHAT_CHANNEL_MEMBER_ACTIVE_STATE_CHANGED", "VOICE_CHAT_CHANNEL_MEMBER_ADDED",
	"VOICE_CHAT_CHANNEL_MEMBER_ENERGY_CHANGED", "VOICE_CHAT_CHANNEL_MEMBER_GUID_UPDATED",
	"VOICE_CHAT_CHANNEL_MEMBER_MUTE_FOR_ALL_CHANGED", "VOICE_CHAT_CHANNEL_MEMBER_MUTE_FOR_ME_CHANGED",
	"VOICE_CHAT_CHANNEL_MEMBER_REMOVED", "VOICE_CHAT_CHANNEL_MEMBER_SILENCED_CHANGED",
	"VOICE_CHAT_CHANNEL_MEMBER_SPEAKING_STATE_CHANGED", "VOICE_CHAT_CHANNEL_MEMBER_STT_MESSAGE",
	"VOICE_CHAT_CHANNEL_MEMBER_VOLUME_CHANGED", "VOICE_CHAT_CHANNEL_MUTE_STATE_CHANGED", "VOICE_CHAT_CHANNEL_PTT_CHANGED",
	"VOICE_CHAT_CHANNEL_REMOVED", "VOICE_CHAT_CHANNEL_TRANSCRIBING_CHANGED", "VOICE_CHAT_CHANNEL_TRANSMIT_CHANGED",
	"VOICE_CHAT_CHANNEL_VOLUME_CHANGED", "VOICE_CHAT_COMMUNICATION_MODE_CHANGED", "VOICE_CHAT_CONNECTION_SUCCESS",
	"VOICE_CHAT_DEAFENED_CHANGED", "VOICE_CHAT_ERROR", "VOICE_CHAT_INPUT_DEVICES_UPDATED", "VOICE_CHAT_LOGIN",
	"VOICE_CHAT_LOGOUT", "VOICE_CHAT_MUTED_CHANGED", "VOICE_CHAT_OUTPUT_DEVICES_UPDATED",
	"VOICE_CHAT_PENDING_CHANNEL_JOIN_STATE", "VOICE_CHAT_PTT_BUTTON_PRESSED_STATE_CHANGED", "VOICE_CHAT_SILENCED_CHANGED",
	"VOICE_CHAT_SPEAK_FOR_ME_ACTIVE_STATUS_UPDATED", "VOICE_CHAT_SPEAK_FOR_ME_FEATURE_STATUS_UPDATED",
	"VOICE_CHAT_TTS_PLAYBACK_BOOKMARK", "VOICE_CHAT_TTS_PLAYBACK_FAILED", "VOICE_CHAT_TTS_PLAYBACK_FINISHED",
	"VOICE_CHAT_TTS_PLAYBACK_STARTED", "VOICE_CHAT_TTS_SPEAK_TEXT_UPDATE", "VOICE_CHAT_TTS_VOICES_UPDATE",
	"VOICE_CHAT_VAD_SETTINGS_UPDATED",
}
-- Fire constantly while anyone talks: counted, not stored one by one.
local NOISY_EVENTS = {
	VOICE_CHAT_AUDIO_CAPTURE_ENERGY = true, VOICE_CHAT_CHANNEL_MEMBER_ENERGY_CHANGED = true,
}

local joinDiag      -- the run in progress: { rec, frame }
local joinDiagFrame -- one hidden listener frame, reused by every run

local function VoiceCall(name, ...)
	local vc = C_VoiceChat
	if type(vc) ~= "table" or type(vc[name]) ~= "function" then return { absent = true } end
	local ok, ret = pcall(vc[name], ...)
	if not ok then return { err = (Clean(ret)) } end
	return diag.Typed(ret)
end

local function ShortEvent(e)
	local label = e.event:gsub("^VOICE_CHAT_", "")
	if e.event == "VOICE_CHAT_CHANNEL_JOINED" or e.event == "VOICE_CHAT_LOGIN" then
		local a = e.args and e.args[1]
		if a and a.v ~= nil then label = label .. "(" .. tostring(a.v) .. ")" end
	elseif e.event == "VOICE_CHAT_ERROR" then
		local a = e.args and e.args[2]
		if a and a.v ~= nil then label = label .. "(" .. tostring(a.v) .. ")" end
	end
	return label
end

local function FinishJoinDiag()
	local run = joinDiag
	if not run then return end
	joinDiag = nil
	local rec = run.rec
	pcall(run.frame.UnregisterAllEvents, run.frame)
	run.frame:SetScript("OnEvent", nil)
	local V = Hark.Voice
	rec.final = {
		t = diag.ClockNow(),
		voiceState = V:GetState(), harkChannelID = diag.Typed(V:GetChannelID()), joined = V:IsActive(),
		GetActiveChannelID = VoiceCall("GetActiveChannelID"),
		IsLoggedIn = VoiceCall("IsLoggedIn"),
	}
	local okFacts, facts = pcall(V._JoinFacts)
	rec.final.facts = okFacts and facts or { err = (Clean(facts)) }
	-- Voice's own step log for this window.
	rec.joinlog = {}
	for _, e in ipairs(type(Hark.db.joinlog) == "table" and Hark.db.joinlog or {}) do
		if type(e) == "table" and type(e.t) == "number" and e.t >= (rec.t0 or 0) - 0.01 then rec.joinlog[#rec.joinlog + 1] = e end
	end
	rec.complete = true
	local order = {}
	for i, e in ipairs(rec.events) do
		if i > 12 then order[#order + 1] = "... (" .. #rec.events .. " in all)" break end
		order[#order + 1] = ShortEvent(e)
	end
	local active = rec.final.GetActiveChannelID
	local activeText = active.absent and "absent" or tostring(active.v == nil and "nil" or active.v)
	local retry = rec.stringRetry and (" (string-id retry at " .. JOINDIAG_RETRY_AT .. " s: "
		.. (#rec.events >= rec.stringRetry.eventIndex and "events followed" or "still no events") .. ")") or ""
	Hark:Print(string.format("Join diagnostic: %s%s; events: %s; GetActiveChannelID %s. Type /reload to save it.",
		rec.final.joined and "JOINED" or "NOT joined", retry,
		#order == 0 and "none" or table.concat(order, ", "), activeText))
end

function Diagnostics:JoinDiag()
	if not Hark.db then
		Hark:Print("Not loaded yet.")
		return
	end
	if joinDiag then
		Hark:Print("Join diagnostic is already running.")
		return
	end
	if not (C_Timer and C_Timer.NewTimer) then
		Hark:Print("Join diagnostic needs C_Timer, which this client lacks.")
		return
	end
	diag.InstallErrorHandler()
	local okClock, t0 = pcall(GetTime)
	local rec = { time = Now(), t = diag.ClockNow(), t0 = okClock and type(t0) == "number" and not Hark.IsSecret(t0) and t0 or 0,
		version = Hark.version, seconds = JOINDIAG_SECONDS, complete = false,
		accepted = {}, rejected = {}, events = {}, counts = {} }
	Hark.db.joindiag = rec
	local V = Hark.Voice
	local okFacts, facts = pcall(V._JoinFacts)
	rec.pre = okFacts and facts or { err = (Clean(facts)) }
	if not okFacts then Hark._RecordError("joindiag facts", facts) end

	joinDiagFrame = joinDiagFrame or CreateFrame("Frame")
	local frame = joinDiagFrame
	for _, event in ipairs(VOICE_EVENTS) do
		if pcall(frame.RegisterEvent, frame, event) then
			rec.accepted[#rec.accepted + 1] = event
		else
			rec.rejected[#rec.rejected + 1] = event
		end
	end
	frame:SetScript("OnEvent", function(_, event, ...)
		rec.counts[event] = (rec.counts[event] or 0) + 1
		if NOISY_EVENTS[event] or #rec.events >= JOINDIAG_EVENTS_MAX then return end
		local n = select("#", ...)
		local args = { n = n }
		local secret
		for i = 1, n do
			local v = (select(i, ...))
			args[i] = diag.Typed(v)
			if Hark.IsSecret(v) and not secret then secret = i end
		end
		local okNow, now = pcall(GetTime)
		rec.events[#rec.events + 1] = { t = okNow and not Hark.IsSecret(now) and now or nil, event = event, args = args, secretArg = secret }
	end)
	joinDiag = { rec = rec, frame = frame }

	local okJoin, r1, r2 = pcall(V.Join, V)
	rec.join = { ok = okJoin, ret = diag.Typed(r1), message = diag.Typed(r2) }
	if not okJoin then Hark._RecordError("joindiag Voice:Join", r1) end
	if okJoin and r1 == false and type(r2) == "string" then Hark:Print(r2) end
	Hark:Print("Join diagnostic running for " .. JOINDIAG_SECONDS .. " s (" .. #rec.accepted .. " voice events hooked)...")
	-- The request returns nothing, so a client that silently ignores numeric ids
	-- looks like "no event". Settle it in the same run: one retry with the
	-- strings (the form a hand call proved), only when nothing at all came back.
	C_Timer.NewTimer(JOINDIAG_RETRY_AT, function()
		if joinDiag == nil or joinDiag.rec ~= rec or #rec.events > 0 or V:IsActive() then return end
		local lastRequest
		for _, e in ipairs(type(Hark.db.joinlog) == "table" and Hark.db.joinlog or {}) do
			if type(e) == "table" and e.step == "request" and type(e.t) == "number" and e.t >= rec.t0 - 0.01 then lastRequest = e end
		end
		if not (lastRequest and lastRequest.form == "number" and lastRequest.ok) then return end
		local clubId = Hark.db.communityId
		local streamId = clubId and V:ResolveStreamId(clubId)
		local fn = C_VoiceChat and C_VoiceChat.RequestJoinAndActivateCommunityStreamChannel
		if not (clubId and streamId and type(fn) == "function") then return end
		local okCall, err = pcall(fn, tostring(clubId), tostring(streamId))
		if not okCall then Hark._RecordError("joindiag string retry", err) end
		local okNow, now = pcall(GetTime)
		rec.stringRetry = { t = okNow and not Hark.IsSecret(now) and now or nil, eventIndex = #rec.events + 1,
			args = { diag.Typed(tostring(clubId)), diag.Typed(tostring(streamId)) }, ok = okCall, err = not okCall and (Clean(err)) or nil }
	end)
	C_Timer.NewTimer(JOINDIAG_SECONDS, FinishJoinDiag)
end

---------------------------------------------------------------------------
-- /hark trace
---------------------------------------------------------------------------

function Diagnostics:SetTrace(on)
	on = on and true or false
	if diag.traceOn == on then return end
	if on then
		diag.traceOn = true
		wipe(diag.traceWho)
		local layer, confident, zone = Hark.Positions:GetLayer()
		Hark._Trace({ k = "on", v = Hark.version, st = Hark.Voice:GetState(), l = layer, c = confident, z = zone })
	else
		Hark._Trace({ k = "off" })
		diag.traceOn = false
	end
end

function Diagnostics:ClearTrace()
	if Hark.db then Hark.db.trace = {} end
	wipe(diag.traceWho)
end

function Diagnostics:OnSlash(cmd, rest)
	if cmd == "selftest" then
		self:SelfTest()
		return
	end
	if cmd == "joindiag" then
		self:JoinDiag()
		return
	end
	local arg = (rest or ""):lower()
	if arg == "on" then
		self:SetTrace(true)
		Hark:Print("Trace on (this session only). /reload saves it.")
	elseif arg == "off" then
		self:SetTrace(false)
		Hark:Print("Trace off.")
	elseif arg == "clear" then
		self:ClearTrace()
		Hark:Print("Trace cleared.")
	else
		local rows = Hark.db and type(Hark.db.trace) == "table" and #Hark.db.trace or 0
		Hark:Print(string.format("Trace is %s, %d row(s). Usage: /hark trace on | off | clear", diag.traceOn and "on" or "off", rows))
	end
end

-- Layer and voice state changes become trace rows (callbacks are cheap when off).
Hark:RegisterCallback("LAYER_CHANGED", Diagnostics, function(_, layer, confident)
	if not diag.traceOn then return end
	local _, _, zone = Hark.Positions:GetLayer()
	Hark._Trace({ k = "layer", l = layer, c = confident, z = zone })
end)
Hark:RegisterCallback("VOICE_STATE_CHANGED", Diagnostics, function(_, state, channelID)
	if not diag.traceOn then return end
	Hark._Trace({ k = "voice", st = state, ch = channelID })
end)

ns.Diagnostics = Diagnostics
