--- Hark: Proximity voice chat for WoW Forever
-- Entry point and lifecycle management

Hark = {
	version = "0.1.0",
	db = nil,
	enabled = true,
}

local ADDON_NAME = "Hark"
local frame = CreateFrame("Frame")

--- Initialize the addon
local function OnLoad()
	HarkDB = HarkDB or {
		enabled = true,
		joinOnZoneChange = true,
		leaveOnZoneExit = true,
		fullVoiceRange = 15,    -- yards
		silentRange = 40,       -- yards
		minVolume = 30,         -- 0-100
		fadeCurve = "smooth",   -- linear, natural, smooth
		communityId = nil,      -- set by /hark setcommunity
		streamId = nil,         -- voice stream ID in the community
	}

	Hark.db = HarkDB
	Hark:Print("Loaded (v" .. Hark.version .. "). Type /hark help for commands.")

	Positions:Init()
	Voice:Init()

	-- Prompt on zone change after a short delay
	C_Timer.After(0.5, function()
		Voice:HandleZoneChange()
	end)
end

--- Slash command handler
local function OnSlashCommand(msg)
	msg = msg:lower():trim()

	if msg == "" or msg == "help" then
		Hark:Print("Commands:")
		Hark:Print("  /hark on|off               Enable/disable proximity voice")
		Hark:Print("  /hark join                 Join proximity voice now")
		Hark:Print("  /hark leave                Leave proximity voice")
		Hark:Print("  /hark status               Show current channel and members")
		Hark:Print("  /hark setcommunity <id>   Set the community to join")
		Hark:Print("  /hark options              Open settings (coming soon)")
		return
	end

	if msg == "join" then
		if Hark.db.communityId then
			Voice:JoinCommunity(Hark.db.communityId, Hark.db.streamId or "")
		else
			Hark:Print("No community configured. Use /hark setcommunity <id>")
		end
		return
	end

	if msg == "leave" then
		Voice:Leave()
		return
	end

	if msg == "on" then
		Hark.enabled = true
		Hark:Print("Proximity voice enabled.")
		return
	end

	if msg == "off" then
		Hark.enabled = false
		Hark:Print("Proximity voice disabled.")
		return
	end

	if msg == "status" then
		Voice:PrintStatus()
		return
	end

	if msg == "setcommunity" then
		Hark:Print("Usage: /hark setcommunity <clubId> [streamId]")
		Hark:Print("Example: /hark setcommunity 23111161")
		return
	end

	-- /hark setcommunity <id> [stream]
	if msg:sub(1, 14) == "setcommunity " then
		local args = msg:sub(15)
		local clubId, streamId = args:match("^(%S+)%s*(.*)$")
		if not clubId then
			Hark:Print("Usage: /hark setcommunity <clubId> [streamId]")
			return
		end
		Hark.db.communityId = clubId
		Hark.db.streamId = streamId ~= "" and streamId or nil
		Hark:Print("Community set to " .. clubId .. (streamId and " stream " .. streamId or ""))
		return
	end

	if msg == "options" then
		Hark:Print("Options UI coming soon.")
		return
	end

	if msg == "test" then
		Hark:Print("Test: positions=" .. Positions:Count() .. ", channel=" .. (Voice:GetActiveChannelID() or "none"))
		return
	end
end

--- Print with addon prefix
function Hark:Print(msg)
	print("|cFF00FF96[Hark]|r " .. msg)
end

--- Register events and slash commands
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")

frame:SetScript("OnEvent", function(self, event, ...)
	if event == "ADDON_LOADED" and ... == ADDON_NAME then
		OnLoad()
	elseif event == "ZONE_CHANGED_NEW_AREA" then
		if Hark.enabled and Hark.db.joinOnZoneChange then
			Voice:HandleZoneChange()
		end
	end
end)

SLASH_HARK1 = "/hark"
SLASH_HARK2 = "/ha"
SlashCmdList["HARK"] = OnSlashCommand
