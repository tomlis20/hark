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
	}

	Hark.db = HarkDB
	Hark:Print("Loaded (v" .. Hark.version .. "). Type /hark help for commands.")

	Positions:Init()
	Voice:Init()
end

--- Slash command handler
local function OnSlashCommand(msg)
	msg = msg:lower():trim()

	if msg == "" or msg == "help" then
		Hark:Print("Commands:")
		Hark:Print("  /hark on|off        Enable/disable proximity voice")
		Hark:Print("  /hark status        Show current channel and range")
		Hark:Print("  /hark options       Open settings (not yet)")
		Hark:Print("  /hark test          Run a quick test (dev)")
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
