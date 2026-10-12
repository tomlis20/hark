-- luacheck config for Hark (WoW Forever, interface 16001, Lua 5.1).
-- Run from the addon root:  luacheck .
-- Install per user:         luarocks --local install luacheck
--                           (then add ~/.luarocks/bin to PATH)

std = "lua51"
max_line_length = false
codes = true

exclude_files = { ".git/**", "Libs/**" }

-- unused self / varargs and shadowed loop vars are routine in WoW handlers
ignore = {
	"212/self",   -- unused argument self
	"212/event",  -- unused argument event
	"212/_.*",    -- unused arguments named _ or _foo
	"213/_.*",    -- unused loop variables named _ or _foo
	"542",        -- empty if branch (used for documented no-op cases)
}

-- Globals the addon itself defines. Everything else must be local or hang
-- off the Hark table. Do NOT add module tables (Positions, Voice, UI,
-- Options) here: being flagged for leaking them is the point.
globals = {
	"Hark",
	"HarkDB",
	"SLASH_HARK1", "SLASH_HARK2",
	"Hark_OnAddonCompartmentClick",
	"SlashCmdList",               -- framework table the addon writes into
}

-- WoW API the addon may read but must never assign.
read_globals = {
	-- added by orchestrator: used by UI.lua for the friendly-nameplate hint
	"C_CVar", "GetCVar", "IsControlKeyDown",
	-- WoW additions to the Lua library
	string = { fields = { "trim", "split", "join" } },
	table = { fields = { "wipe" } },
	"strtrim", "strsplit", "strjoin", "strlower", "strupper", "strlen", "strsub",
	"strfind", "strmatch", "strrep", "strbyte", "strchar", "strrev", "format",
	"gsub", "gmatch", "tinsert", "tremove", "tconcat", "sort", "wipe", "floor",
	"ceil", "abs", "max", "min", "sqrt", "random", "mod", "bit", "date", "time",
	"tContains", "tInvert", "CopyTable", "Mixin", "CreateFromMixins", "Round",
	"Clamp", "Lerp", "debugstack", "debugprofilestop", "geterrorhandler",
	"seterrorhandler", "securecallfunction", "hooksecurefunc", "issecure",
	"issecretvalue", "issecrettable", "canaccessvalue", "canaccesstable",

	-- frames and UI
	"CreateFrame", "UIParent", "WorldFrame", "DEFAULT_CHAT_FRAME", "ChatFrame1",
	"GameTooltip", "GameFontNormal", "GameFontHighlight", "GameFontNormalSmall",
	"GameFontHighlightSmall", "GameFontDisable", "BackdropTemplateMixin",
	"Settings", "InterfaceOptions_AddCategory", "InterfaceOptionsFrame_OpenToCategory",
	"SettingsPanel", "StaticPopupDialogs", "StaticPopup_Show", "PlaySound",
	"SOUNDKIT", "InCombatLockdown", "AddonCompartmentFrame", "MenuUtil",
	"UIDropDownMenu_Initialize", "UIDropDownMenu_CreateInfo", "UIDropDownMenu_AddButton",
	"UIDropDownMenu_SetText", "UIDropDownMenu_SetWidth", "ToggleDropDownMenu",
	"CloseDropDownMenus", "EasyMenu", "ColorPickerFrame", "RAID_CLASS_COLORS",
	"C_ClassColor", "GetLocale",

	-- timing
	"C_Timer", "GetTime", "GetServerTime", "GetTimePreciseSec",

	-- units and players
	"UnitPosition", "UnitName", "UnitFullName", "GetUnitName", "UnitGUID",
	"UnitExists", "UnitIsPlayer", "UnitIsUnit", "UnitIsDeadOrGhost", "UnitIsDead",
	"UnitIsGhost", "UnitIsConnected", "UnitClass", "UnitRace", "UnitLevel",
	"UnitFactionGroup", "UnitAffectingCombat", "UnitInParty", "UnitInRaid",
	"UnitIsGroupLeader", "UnitPlayerControlled", "UnitIsInMyGuild", "GetUnitSpeed",
	"IsFalling", "IsSwimming", "IsFlying", "IsMounted", "IsResting",
	"GetPlayerInfoByGUID", "PlayerLocation", "PlayerLocationMixin",

	-- group, guild, realm
	"IsInGuild", "GetGuildInfo", "IsInGroup", "IsInRaid", "GetNumGroupMembers",
	"GetNumSubgroupMembers", "LE_PARTY_CATEGORY_HOME", "LE_PARTY_CATEGORY_INSTANCE",
	"GetRealmName", "GetNormalizedRealmName", "Ambiguate",

	-- zones and maps
	"GetZoneText", "GetRealZoneText", "GetSubZoneText", "GetMinimapZoneText",
	"IsInInstance", "GetInstanceInfo", "C_Map",

	-- chat, addon messages, channels
	"C_ChatInfo", "JoinTemporaryChannel", "JoinChannelByName", "JoinPermanentChannel",
	"LeaveChannelByName", "GetChannelName", "ChatFrame_AddMessageEventFilter",

	-- communities and voice
	"C_Club", "C_VoiceChat",

	-- misc
	"Enum", "C_AddOns", "GetAddOnMetadata", "IsAddOnLoaded",
}

-- The test harness runs under plain Lua 5.1/LuaJIT, not inside WoW.
files["Tests/**"] = {
	std = "lua51",
	globals = { string = { fields = { "trim", "split", "join" } } },
	read_globals = { "jit", "bit" },
}
