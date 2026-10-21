#!/usr/bin/env lua5.1
--- Reads Hark's SavedVariables file and prints the self-test, the captured
-- errors and the trace as a report.
--
--   lua5.1 Tests/readselftest.lua "<WoW>/_classic_beta_/WTF/Account/<ACCOUNT>/SavedVariables/Hark.lua"
--
-- The file is executed in an empty sandbox (it only assigns HarkDB).

local path = arg and arg[1]
if not path then
	io.stderr:write("usage: lua5.1 readselftest.lua <path to SavedVariables/Hark.lua>\n")
	os.exit(2)
end

local chunk, loadErr = loadfile(path)
if not chunk then
	io.stderr:write("cannot load " .. path .. ": " .. tostring(loadErr) .. "\n")
	os.exit(1)
end
local sandbox = {}
setfenv(chunk, sandbox)
local okRun, runErr = pcall(chunk)
if not okRun then
	io.stderr:write("error running " .. path .. ": " .. tostring(runErr) .. "\n")
	os.exit(1)
end
local db = sandbox.HarkDB
if type(db) ~= "table" then
	print("No HarkDB in " .. path .. " (Hark never saved on this account, or the wrong file).")
	os.exit(0)
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local out = {}
local function P(...) out[#out + 1] = table.concat({ ... }) end
local function H(title) P("") P("== ", title, " ", string.rep("=", math.max(0, 66 - #title))) end

local function show(v, depth)
	depth = depth or 0
	local kind = type(v)
	if v == nil then return "nil" end
	if kind == "string" then return string.format("%q", v) end
	if kind ~= "table" then return tostring(v) end
	if depth >= 3 then return "{...}" end
	local parts, n = {}, tonumber(v.n)
	if n then
		for i = 1, n do parts[#parts + 1] = show(v[i], depth + 1) end
		return "(" .. table.concat(parts, ", ") .. ")"
	end
	local keys = {}
	for k in pairs(v) do keys[#keys + 1] = k end
	table.sort(keys, function(a, b)
		if type(a) == type(b) and (type(a) == "number" or type(a) == "string") then return a < b end
		return type(a) < type(b)
	end)
	for _, k in ipairs(keys) do
		local key = type(k) == "number" and ("[" .. k .. "]") or tostring(k)
		parts[#parts + 1] = key .. "=" .. show(v[k], depth + 1)
	end
	return "{" .. table.concat(parts, ", ") .. "}"
end

local function when(epoch)
	if type(epoch) ~= "number" or epoch <= 0 then return "?" end
	return os.date("%Y-%m-%d %H:%M:%S", epoch)
end

local function results(rec)
	if not rec then return "(no probe)" end
	if rec.status == "absent" then return "ABSENT" end
	if rec.status == "error" then return "ERROR " .. tostring(rec.err) end
	return show(rec.results) .. (rec.secret and "  [SECRET]" or "")
end

local function first(rec)
	return rec and rec.results and rec.results[1]
end

local SEND_RESULT = { [0] = "Success", "InvalidPrefix", "InvalidMessage", "AddonMessageThrottle", "InvalidChatType",
	"NotInGroup", "TargetRequired", "InvalidChannel", "ChannelThrottle", "GeneralError", [-1] = "call raised an error" }

---------------------------------------------------------------------------
-- Self-test
---------------------------------------------------------------------------

local st = db.selftest
P("Hark diagnostics from ", path)
P("Settings loaded from: ", tostring(db.loadedFrom), "   dbVersion ", tostring(db.dbVersion))

if type(st) ~= "table" or type(st.results) ~= "table" then
	H("Self-test")
	P("The self-test was never run (or not saved). In game: /hark selftest, wait for 'Self-test done', then /reload.")
else
	local byId = {}
	local function index(rec)
		if type(rec) ~= "table" or not rec.id then return end
		byId[rec.id] = byId[rec.id] or {}
		table.insert(byId[rec.id], rec)
	end
	for _, rec in ipairs(st.results) do index(rec) end
	local function one(id) return byId[id] and byId[id][1] end
	local function all(id) return byId[id] or {} end

	H("Self-test")
	P("Run at ", when(st.time), " (GetTime ", tostring(st.t), "), Hark ", tostring(st.version))
	if not st.complete then
		P("NOT COMPLETE: the /reload came before 'Self-test done'. The send probe is missing; the rest is here.")
	end
	if type(st.summary) == "table" then
		P(string.format("%s probes, %s absent, %s secret values, %s errors at the time",
			tostring(st.summary.probes), tostring(st.summary.absent), tostring(st.summary.secrets), tostring(st.summary.errors)))
	end

	H("Client facts")
	local build = one("client.build")
	if build and build.results then
		local r = build.results
		P("Build: version ", tostring(r[1]), ", build ", tostring(r[2]), ", date ", tostring(r[3]), ", interface ", tostring(r[4]))
	else
		P("Build: ", results(build))
	end
	P("Locale: ", tostring(first(one("client.locale"))))
	local player = one("client.player")
	P("Player: ", tostring(first(player)), "  realm ", tostring(first(one("client.realm"))),
		" (normalised ", tostring(first(one("client.normalizedRealm"))), ")  GUID ", tostring(first(one("client.guid"))))
	P("CVar nameplateShowFriends = ", show(first(one("client.nameplateShowFriends"))),
		"   scriptErrors = ", show(first(one("client.scriptErrors"))))
	P("In guild: ", show(first(one("client.inGuild"))), "   in group: ", show(first(one("client.inGroup"))),
		"   in raid: ", show(first(one("client.inRaid"))))
	local hark = one("client.hark")
	if hark then
		P("Hark ", tostring(hark.version), ": proximity ", hark.enabled and "on" or "off", ", voice ", tostring(hark.voiceState),
			", community ", tostring(hark.communityId), ", error handler wrapped: ", tostring(hark.errorHandlerWrapped))
	end
	local enum = one("client.enumSendResult")
	if enum and type(enum.value) == "table" then
		for name, code in pairs(enum.value) do if type(code) == "number" then SEND_RESULT[code] = name end end
		P("Enum.SendAddonMessageResult: ", show(enum.value))
	end

	H("Verdicts")
	-- Positions
	P("UnitPosition(player): ", results(one("pos.player")))
	local function verdictFor(filter, label)
		local counts, list = {}, {}
		for _, u in ipairs(all("pos.unit")) do
			if u.exists ~= false and u.isPlayer == true and u.isSelf ~= true and filter(u) then
				counts[u.positionVerdict or "?"] = (counts[u.positionVerdict or "?"] or 0) + 1
				list[#list + 1] = string.format("%s %s%s: %s", u.unit, tostring(u.name),
					u.realm and ("-" .. tostring(u.realm)) or "", results({ results = u.position, status = "ok" }))
			end
		end
		local keys = {}
		for k, n in pairs(counts) do keys[#keys + 1] = k .. (n > 1 and (" x" .. n) or "") end
		table.sort(keys)
		if #keys == 0 then
			P(label, ": NO DATA (no such player was visible as target, mouseover or nameplate)")
		else
			P(label, ": ", table.concat(keys, " / "))
			for _, line in ipairs(list) do P("    ", line) end
		end
	end
	verdictFor(function(u) return u.inGroup == false end, "UnitPosition for non-group player")
	verdictFor(function(u) return u.inGroup == true end, "UnitPosition for group member")
	verdictFor(function(u) return u.inGroup == "<secret>" end, "UnitPosition for player with secret group state")
	local plates = one("pos.nameplateCount")
	P("Nameplate units present: ", tostring(plates and plates.value),
		" (other players need friendly nameplates on: nameplateShowFriends = 1)")
	for _, u in ipairs(all("pos.unit")) do
		if u.exists ~= false and u.guid ~= nil then
			P(string.format("    %-11s %-24s player=%s group=%s self=%s visible=%s pos=%s -> Hark %s %s",
				u.unit, tostring(u.name), tostring(u.isPlayer), tostring(u.inGroup), tostring(u.isSelf), tostring(u.visible),
				tostring(u.positionVerdict), tostring(u.harkReason), show(u.harkDistance)))
		end
	end

	-- Voice
	local active = one("voice.activeChannel")
	P("Voice: GetActiveChannelID ", results(active), "; Hark sees ", active and active.hark and show(active.hark) or "?")
	local members = all("voice.member")
	if #members == 0 then
		P("Voice members: NO DATA (not in a voice channel when the self-test ran: /hark join first)")
	else
		local names, guids, infoNames, guidLocRead, voiceLocRead = 0, 0, 0, 0, 0
		local sets, matchVoice, matchGUID, guidTried = 0, 0, 0, 0
		local reads = {}
		for _, m in ipairs(members) do
			if m.name ~= nil then names = names + 1 end
			if m.guid ~= nil then guids = guids + 1 end
			if m.infoName ~= nil and m.infoName ~= "" then infoNames = infoNames + 1 end
			if type(m.volVoice) == "number" then voiceLocRead = voiceLocRead + 1 reads[#reads + 1] = m.volVoice end
			if type(m.volGUID) == "number" then guidLocRead = guidLocRead + 1 reads[#reads + 1] = m.volGUID end
			if m.setValue ~= nil then
				sets = sets + 1
				if m.matchVoice then matchVoice = matchVoice + 1 end
				if m.backGUID ~= nil or m.matchGUID ~= nil then guidTried = guidTried + 1 end
				if m.matchGUID then matchGUID = matchGUID + 1 end
			end
		end
		local n = #members
		P(string.format("Voice members: %d. member.name present for %d (nil expected on Forever)", n, names))
		P(string.format("GetMemberGUID: %s (%d of %d)", guids == n and "WORKS" or (guids == 0 and "NIL" or "PARTIAL"), guids, n))
		P(string.format("GetPlayerInfoByGUID name for member GUIDs: %d of %d", infoNames, guids))
		P(string.format("GetMemberVolume via voice-id location: %s (%d of %d)", voiceLocRead > 0 and "READABLE" or "NIL", voiceLocRead, n))
		P(string.format("GetMemberVolume via GUID location: %s (%d of %d)", guidLocRead > 0 and "READABLE" or "NIL", guidLocRead, guids))
		local maxRead
		for _, v in ipairs(reads) do if not maxRead or v > maxRead then maxRead = v end end
		if maxRead then
			local frac = false
			for _, v in ipairs(reads) do if v ~= math.floor(v) then frac = true end end
			P("Volume scale: ", (maxRead <= 1 and frac) and "looks like 0-1 (fractions, max " .. maxRead .. ")"
				or (maxRead > 1 and "0-100 (max read " .. maxRead .. ")" or "unclear (all reads 0 or 1)"))
		else
			P("Volume scale: NO DATA")
		end
		if sets == 0 then
			P("Write-back test: NOT RUN (no other member with a readable volume)")
		else
			P(string.format("Write-back via voice-id, read back via voice-id: %d of %d matched", matchVoice, sets))
			P(string.format("Write-back via voice-id, read back via GUID: %d of %d matched%s", matchGUID, guidTried,
				guidTried > 0 and (matchGUID == guidTried and "  => GUID location WORKS" or (matchGUID == 0 and "  => GUID location does NOT reflect it" or "")) or ""))
		end
		for _, m in ipairs(members) do
			P(string.format("    #%s id=%s guid=%s info=%s-%s local=%s active=%s speaking=%s vol(voice)=%s vol(guid)=%s set=%s back(voice)=%s back(guid)=%s hark=%s%s",
				tostring(m.index), show(m.memberID), tostring(m.guid), tostring(m.infoName), tostring(m.infoRealm),
				tostring(m.isLocal), show(m.isActive), show(m.isSpeaking), show(m.volVoice), show(m.volGUID),
				show(m.setValue), show(m.backVoice), show(m.backGUID), m.hark and show(m.hark) or "-",
				m.setSkipped and ("  (" .. m.setSkipped .. ")") or ""))
		end
	end

	-- Layer
	local layer = one("layer.get")
	P("Layer: ", results(layer), "  (layer id, confirmed, zone)")
	local samples = one("layer.samples")
	if samples then
		local count = type(samples.samples) == "table" and #samples.samples or 0
		P("    ", count, " creature sample(s); positions held ", tostring(samples.knownPositions),
			", seen players ", tostring(samples.seenPlayers))
	end

	-- Persistence
	local persist = one("persist")
	if persist then
		P("Persistence: loaded from ", tostring(persist.loadedFrom), ", ready ", tostring(persist.ready),
			", macro ", tostring(persist.macroState))
		if type(persist.status) == "table" then
			for _, line in ipairs(persist.status) do P("    ", tostring(line)) end
		end
	end

	-- Settings
	local settings = one("settings")
	if settings then
		P("Options registered: ", tostring(settings.registered), "   UISpecialFrames present: ", tostring(settings.specialFramesPresent),
			", HarkOptionsFrame listed: ", tostring(settings.inSpecialFrames), ", frame exists: ", tostring(settings.namedFrameExists),
			settings.buildError and ("   BUILD ERROR " .. tostring(settings.buildError)) or "")
	end

	-- Messaging
	local send = one("msg.send")
	if send then
		P("Position send: ", tostring(send.status), send.reason and (" (" .. send.reason .. ")") or "",
			"; targets ", show(send.targets), "; voice active ", tostring(send.voiceActive))
		if type(send.lastSend) == "table" then
			for chatType, r in pairs(send.lastSend) do
				P("    ", chatType, ": result ", tostring(r.result), " ", tostring(SEND_RESULT[r.result] or ""), ", seq ", tostring(r.seq))
			end
		end
	end

	-- APIs
	local absent, present = {}, 0
	for _, rec in ipairs(all("api")) do
		if rec.status == "absent" then absent[#absent + 1] = rec.call else present = present + 1 end
	end
	P("APIs present: ", present, "; absent (", #absent, "): ", #absent > 0 and table.concat(absent, ", ") or "none")

	local secrets = {}
	local function scan(rec, where)
		if type(rec) ~= "table" then return end
		if rec.secret then secrets[#secrets + 1] = (where and (where .. " ") or "") .. tostring(rec.call or rec.id) end
		if type(rec.calls) == "table" then for _, c in ipairs(rec.calls) do scan(c, rec.unit or ("member " .. tostring(rec.index))) end end
	end
	for _, rec in ipairs(st.results) do scan(rec) end
	P("Secret values seen: ", #secrets == 0 and "none" or (#secrets .. ": " .. table.concat(secrets, "; ")))
	for _, rec in ipairs(all("section.error")) do
		P("SECTION FAILED: ", tostring(rec.section), ": ", tostring(rec.err))
	end

	H("Every probe")
	local function dump(rec, indent)
		if type(rec) ~= "table" then return end
		if rec.call then
			P(indent, rec.id, "  ", rec.call, " -> ", results(rec))
		else
			local copy = {}
			for k, v in pairs(rec) do if k ~= "calls" and k ~= "id" then copy[k] = v end end
			P(indent, tostring(rec.id), "  ", show(copy))
		end
		if type(rec.calls) == "table" then
			for _, c in ipairs(rec.calls) do dump(c, indent .. "    ") end
		end
	end
	for _, rec in ipairs(st.results) do
		if rec.id ~= "api" then dump(rec, "") end
	end
end

---------------------------------------------------------------------------
-- Errors
---------------------------------------------------------------------------

H("Lua errors")
local errors = type(db.errors) == "table" and db.errors or {}
if #errors == 0 then
	P("None captured.")
else
	for i, e in ipairs(errors) do
		P(string.format("#%d  %s (GetTime %s)  x%s  [%s]", i, when(e.time), tostring(e.t), tostring(e.count or 1), tostring(e.where)))
		P("    ", tostring(e.message))
		if e.lastTime then P("    last at ", when(e.lastTime), " (GetTime ", tostring(e.lastT), ")") end
		if e.stack then
			for line in tostring(e.stack):gmatch("[^\n]+") do P("      | ", line) end
		end
	end
end

---------------------------------------------------------------------------
-- Trace
---------------------------------------------------------------------------

H("Trace")
local trace = type(db.trace) == "table" and db.trace or {}
if #trace == 0 then
	P("No trace rows (use /hark trace on, play, then /reload).")
else
	local names, order, byGuid = {}, {}, {}
	local rx, tx, events = {}, {}, {}
	for _, row in ipairs(trace) do
		local k = row.k
		if k == "who" and row.g then
			names[row.g] = row.n or names[row.g]
		elseif k == "vol" and row.g then
			if not byGuid[row.g] then byGuid[row.g] = {} order[#order + 1] = row.g end
			table.insert(byGuid[row.g], row)
		elseif k == "rx" and row.g then
			rx[row.g] = rx[row.g] or { n = 0 }
			rx[row.g].n = rx[row.g].n + 1
			rx[row.g].last = row
			if not byGuid[row.g] then byGuid[row.g] = {} order[#order + 1] = row.g end
		elseif k == "tx" then
			local key = tostring(row.ch) .. " " .. tostring(row.res) .. " " .. tostring(SEND_RESULT[row.res] or "")
			tx[key] = (tx[key] or 0) + 1
		else
			events[#events + 1] = row
		end
	end
	P(string.format("%d rows, GetTime %s to %s", #trace, tostring(trace[1].t), tostring(trace[#trace].t)))
	P("Sent: ")
	for key, n in pairs(tx) do P("    ", key, ": ", n) end
	P("Events:")
	for _, row in ipairs(events) do
		local copy = {}
		for k, v in pairs(row) do if k ~= "t" and k ~= "k" then copy[k] = v end end
		P(string.format("    %8s  %-6s %s", tostring(row.t), tostring(row.k), show(copy)))
	end
	for _, g in ipairs(order) do
		local rows = byGuid[g]
		local r = rx[g]
		P("")
		P(string.format("Member %s (%s): %d volume rows, %d position messages received%s", tostring(names[g] or "?"), g, #rows,
			r and r.n or 0, r and string.format(" (last seq %s at %s,%s zone %s layer %s)", tostring(r.last.seq), tostring(r.last.x),
				tostring(r.last.y), tostring(r.last.z), tostring(r.last.l)) or ""))
		-- Collapse runs where reason, distance, target and applied volume stay the same.
		local span
		local function flush()
			if not span then return end
			P(string.format("    %8s - %-8s  %-9s %-5s d=%-6s target=%-4s applied=%-4s%s",
				tostring(span.from), tostring(span.to), tostring(span.r), tostring(span.s), tostring(span.d), tostring(span.tg),
				tostring(span.a), span.sets > 0 and ("  (" .. span.sets .. " set)") or ""))
		end
		for _, row in ipairs(rows) do
			if span and span.r == row.r and span.d == row.d and span.tg == row.tg and span.a == row.a and span.s == row.s then
				span.to = row.t
				if row.set then span.sets = span.sets + 1 end
			else
				flush()
				span = { from = row.t, to = row.t, r = row.r, d = row.d, tg = row.tg, a = row.a, s = row.s, sets = row.set and 1 or 0 }
			end
		end
		flush()
	end
end

---------------------------------------------------------------------------
-- Voice join: HarkDB.joinlog and HarkDB.joindiag (CONTRACT.md 13)
---------------------------------------------------------------------------

-- A typed value { t = luaType, v = value } as `value:type`; "<secret>" for secrets.
local function tv(x, depth)
	depth = depth or 0
	if type(x) ~= "table" then return show(x) end
	if x.absent then return "ABSENT" end
	if x.err ~= nil and x.t == nil then return "ERROR " .. tv(x.err, depth + 1) end
	local t = x.t
	if t == nil then
		-- a plain table (attempt record, list): render its fields
		if depth >= 4 then return "{...}" end
		local keys = {}
		for k in pairs(x) do keys[#keys + 1] = k end
		table.sort(keys, function(a, b)
			if type(a) == type(b) and (type(a) == "number" or type(a) == "string") then return a < b end
			return type(a) < type(b)
		end)
		local parts = {}
		for _, k in ipairs(keys) do
			if k ~= "n" then
				parts[#parts + 1] = (type(k) == "number" and ("[" .. k .. "]") or tostring(k)) .. "=" .. tv(x[k], depth + 1)
			end
		end
		return "{" .. table.concat(parts, ", ") .. "}"
	end
	if t == "nil" then return "nil" end
	if t == "secret" then return "<secret>" end
	if t == "string" then return string.format("%q", tostring(x.v)) .. ":string" end
	if t == "table" then
		if type(x.v) ~= "table" then return tostring(x.v) end
		return tv(x.v, depth + 1)
	end
	return tostring(x.v) .. ":" .. t
end

local function plainOf(x) -- the value of a typed record, or nil
	if type(x) == "table" and x.t ~= nil and x.t ~= "secret" and x.t ~= "nil" then return x.v end
	return nil
end

local STATUS = { [0] = "Success", "OperationPending", "TooManyRequests", "LoginProhibited", "ClientNotInitialized",
	"ClientNotLoggedIn", "ClientAlreadyLoggedIn", "ChannelNameTooShort", "ChannelNameTooLong", "ChannelAlreadyExists",
	"AlreadyInChannel", "TargetNotFound", "Failure", "ServiceLost", "UnableToLaunchProxy", "ProxyConnectionTimeOut",
	"ProxyConnectionUnableToConnect", "ProxyConnectionUnexpectedDisconnect", "Disabled", "UnsupportedChatChannelType",
	"InvalidCommunityStream", "PlayerSilenced", "PlayerVoiceChatParentalDisabled", "InvalidInputDevice",
	"InvalidOutputDevice", "PlayerVoiceChatAgeVerificationRestricted" }
local function statusName(code) return tostring(code) .. (STATUS[code] and (" " .. STATUS[code]) or "") end

-- The streams GetStreams returned in a resolveStream/getStreams attempt list.
local function streamsFrom(attempts)
	if type(attempts) ~= "table" then return nil end
	for _, a in ipairs(attempts) do
		if type(a) == "table" and type(a.ret) == "table" and a.ret.t == "table" and type(a.ret.v) == "table" then
			local list = {}
			for _, s in pairs(a.ret.v) do
				if type(s) == "table" and type(s.v) == "table" then list[#list + 1] = s.v end
			end
			return list, a.form
		end
	end
	return nil
end

local function printJoinEntries(entries)
	for _, e in ipairs(entries) do
		local parts = {}
		local keys = {}
		for k in pairs(e) do if k ~= "t" and k ~= "step" then keys[#keys + 1] = k end end
		table.sort(keys)
		for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. tv(e[k]) end
		P(string.format("    %9s  %-16s %s", tostring(e.t), tostring(e.step), table.concat(parts, "  ")))
		if e.step == "resolveStream" then
			local list = streamsFrom(e.getStreams)
			if list then
				for _, s in ipairs(list) do
					local voice = {}
					for k, v in pairs(s) do
						if tostring(k):lower():find("voice") then voice[#voice + 1] = k .. "=" .. tv(v) end
					end
					P(string.format("               stream %s  type %s  name %s%s", tv(s.streamId), tv(s.streamType), tv(s.name),
						#voice > 0 and ("  " .. table.concat(voice, " ")) or "  (no voice field)"))
				end
			end
		end
	end
end

--- Which step of the latest join failed, from the log entries.
local function joinVerdict(entries)
	local start
	for i = #(entries or {}), 1, -1 do
		local e = entries[i]
		if type(e) == "table" and e.step == "join" and e.clubId ~= nil and e.outcome == nil then start = i break end
	end
	if not start then
		for i = #(entries or {}), 1, -1 do
			local e = entries[i]
			if type(e) == "table" and e.step == "join" and e.outcome then return "Join returned early: " .. tostring(e.outcome) .. "." end
		end
		return "No join attempt recorded (type /hark join or /hark joindiag, then /reload)."
	end
	local s = { events = {}, notes = {} }
	for i = start, #entries do
		local e = entries[i]
		if e.step == "join" then s.clubId, s.streamId = plainOf(e.clubId), plainOf(e.streamId)
		elseif e.step == "resolveStream" then s.source, s.streams = e.source, streamsFrom(e.getStreams)
			s.getStreamsTried = e.getStreams
		elseif e.step == "isLoggedIn" then s.loggedIn = plainOf(e.ret)
		elseif e.step == "login" then s.login = e.status
		elseif e.step == "loginFailed" then s.loginFailed = e.status
		elseif e.step == "lookup" then s.lookup = e
		elseif e.step == "request" then s.request = e
		elseif e.step == "activate" then s.activate = e
		elseif e.step == "event" then s.events[#s.events + 1] = e
		elseif e.step == "joinedDecision" then s.joined = e.decision
		elseif e.step == "activatedDecision" then s.activated = e.decision
		elseif e.step == "timeout" then s.timeout = e
		elseif e.step == "adopt" then s.adopt = e
		end
	end
	local streamNote = ""
	if s.streams then
		local found = false
		for _, st in ipairs(s.streams) do
			if tostring(plainOf(st.streamId)) == tostring(s.streamId) then found = true end
		end
		if #s.streams == 0 then
			streamNote = " GetStreams returned an empty list for this club."
		elseif not found then
			streamNote = " Stream " .. tostring(s.streamId) .. " is NOT in this club's GetStreams list."
		end
	elseif s.getStreamsTried then
		streamNote = " GetStreams returned nothing for this club (in either id form)."
	end
	if s.adopt then
		return "JOINED: adopted channel " .. tv(s.adopt.channelID)
			.. (s.timeout and (" (at the timeout: " .. tostring(s.timeout.decision) .. ")") or "") .. "."
	end
	for _, e in ipairs(s.events) do
		if e.dropped then
			return "FAILED AT the event guard: " .. tostring(e.event) .. " was dropped because argument "
				.. tostring(e.secretArg) .. " is a secret value."
		end
	end
	if s.loginFailed then return "FAILED AT voice login: VOICE_CHAT_LOGIN reported status " .. tostring(s.loginFailed) .. "." end
	for _, e in ipairs(s.events) do
		if e.event == "VOICE_CHAT_CHANNEL_JOINED" and type(e.args) == "table" then
			local status = plainOf(e.args[1])
			if status ~= nil and status ~= 0 then
				return "FAILED AT the join request: the client answered VOICE_CHAT_CHANNEL_JOINED with status "
					.. statusName(status) .. " for club " .. tv(e.args[4]) .. " stream " .. tv(e.args[5]) .. "." .. streamNote
			end
		end
	end
	if s.joined and s.joined:find("^ignored") then
		return "FAILED AT event matching: the JOINED event was " .. s.joined .. "." .. streamNote
	end
	if s.joined and s.joined:find("waiting for activation") then
		if s.activated then return "FAILED AT activation matching: ACTIVATED was " .. s.activated .. "." end
		return "FAILED AT activation: " .. s.joined .. ", but VOICE_CHAT_CHANNEL_ACTIVATED never came."
	end
	local sawLogin = false
	for _, e in ipairs(s.events) do if e.event == "VOICE_CHAT_LOGIN" then sawLogin = true end end
	if s.loggedIn == false and not sawLogin then
		return "FAILED AT voice login: voice chat was not logged in (Login said " .. tostring(s.login)
			.. ") and VOICE_CHAT_LOGIN never arrived."
	end
	if s.request and s.request.absent then return "FAILED: RequestJoinAndActivateCommunityStreamChannel is absent on this client." end
	if s.request and s.request.ok == false then
		return "FAILED AT the request call: it raised " .. tv(s.request.err) .. " (form " .. tostring(s.request.form) .. ")."
	end
	if #s.events == 0 and (s.request or s.activate) then
		local what = s.request and ("RequestJoinAndActivateCommunityStreamChannel(" .. tv(s.request.args and s.request.args[1])
			.. ", " .. tv(s.request.args and s.request.args[2]) .. ")") or ("ActivateChannel(" .. tv(s.activate.args and s.activate.args[1]) .. ")")
		return "FAILED AT the request: " .. what .. " produced no voice event at all. Stream "
			.. tostring(s.streamId) .. " came from " .. tostring(s.source) .. "." .. streamNote
	end
	if s.timeout then
		return "UNDETERMINED: timed out with " .. #s.events .. " voice event(s); timeout lookup: "
			.. tostring(s.timeout.decision) .. ", active channel " .. tv(s.timeout.activeChannelID) .. "." .. streamNote
	end
	return "IN PROGRESS or no outcome recorded (the /reload came before the 10 s timeout?)." .. streamNote
end

H("Voice join log")
local joinlog = type(db.joinlog) == "table" and db.joinlog or {}
if #joinlog == 0 then
	P("No join log (Hark records one on every /hark join; then /reload).")
else
	P(#joinlog, " entries (newest 40 kept)")
	printJoinEntries(joinlog)
	P("Verdict (latest join): ", joinVerdict(joinlog))
end

H("Join diagnostic (/hark joindiag)")
local jd = db.joindiag
if type(jd) ~= "table" then
	P("Never run. In game: /hark joindiag, wait for 'Join diagnostic:', then /reload.")
else
	P("Run at ", when(jd.time), " (GetTime ", tostring(jd.t), "), Hark ", tostring(jd.version), ", window ", tostring(jd.seconds), " s",
		jd.complete and "" or "   NOT COMPLETE: the /reload came before the window ended")
	if type(jd.pre) == "table" then
		P("Before the join:")
		local keys = {}
		for k in pairs(jd.pre) do keys[#keys + 1] = k end
		table.sort(keys)
		for _, k in ipairs(keys) do P("    ", k, " = ", tv(jd.pre[k])) end
		local list = streamsFrom(jd.pre.getStreams)
		if list then
			for _, s in ipairs(list) do
				P(string.format("    stream %s  type %s  name %s", tv(s.streamId), tv(s.streamType), tv(s.name)))
			end
		end
	end
	P("Voice:Join() returned ", tv(jd.join))
	P("Events hooked: ", #(jd.accepted or {}), "; refused by the client (", #(jd.rejected or {}), "): ",
		#(jd.rejected or {}) > 0 and table.concat(jd.rejected, ", ") or "none")
	local counts = {}
	for event, n in pairs(jd.counts or {}) do counts[#counts + 1] = event:gsub("^VOICE_CHAT_", "") .. " x" .. n end
	table.sort(counts)
	P("Event counts: ", #counts > 0 and table.concat(counts, ", ") or "none")
	P("Events in order:")
	if #(jd.events or {}) == 0 then P("    none") end
	for _, e in ipairs(jd.events or {}) do
		local args = {}
		for i = 1, tonumber(e.args and e.args.n) or 0 do args[i] = tv(e.args[i]) end
		P(string.format("    %9s  %s(%s)%s", tostring(e.t), tostring(e.event), table.concat(args, ", "),
			e.secretArg and ("  [arg " .. e.secretArg .. " secret]") or ""))
	end
	if type(jd.final) == "table" then
		P("At the end: joined ", tostring(jd.final.joined), ", Hark state ", tostring(jd.final.voiceState),
			", GetActiveChannelID ", tv(jd.final.GetActiveChannelID), ", IsLoggedIn ", tv(jd.final.IsLoggedIn))
		if type(jd.final.facts) == "table" then P("    lookup now: ", tv(jd.final.facts.lookup)) end
	end
	local retry = jd.stringRetry
	if type(retry) == "table" then
		local after = {}
		for i = tonumber(retry.eventIndex) or 1, #(jd.events or {}) do after[#after + 1] = tostring(jd.events[i].event):gsub("^VOICE_CHAT_", "") end
		P("String-id retry at GetTime ", tostring(retry.t), ": RequestJoinAndActivateCommunityStreamChannel(",
			tv(retry.args and retry.args[1]), ", ", tv(retry.args and retry.args[2]), ") ", retry.ok and "called" or ("raised " .. tostring(retry.err)),
			"; events after it: ", #after > 0 and table.concat(after, ", ") or "none")
	end
	if type(jd.joinlog) == "table" and #jd.joinlog > 0 then
		P("Join steps in the window:")
		printJoinEntries(jd.joinlog)
		local verdict = joinVerdict(jd.joinlog)
		if type(retry) == "table" and #(jd.events or {}) >= (tonumber(retry.eventIndex) or 1) then
			verdict = "ID FORM: the numeric-id request drew no event, the string-id retry did"
				.. (jd.final and jd.final.joined and " and joined" or "") .. ". The client ignores numeric ids for this call. ("
				.. verdict .. ")"
		elseif type(retry) == "table" then
			verdict = verdict .. " The string-id retry drew no event either, so the id form is not the cause."
		end
		P("Verdict: ", verdict)
	end
end

print(table.concat(out, "\n"))
