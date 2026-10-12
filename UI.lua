--- Hark: on-screen panel
-- A small movable panel: voice state, on/off, join/leave, and one row per voice
-- member with a speaking light, distance and applied volume. Clicking a row
-- cycles a session override (proximity -> muted -> always heard) through
-- Voice:SetOverride. Redraws only on Hark callbacks, never per frame.
--
-- Saved state (Hark.db.ui, owned by this file, CONTRACT.md 10.1):
--   point, relativePoint, x, y   frame anchor to UIParent
--   scale                        0.6 .. 1.6
--   locked                       true disables dragging
--   collapsed                    true shows the header only
--   shown                        false once the player hides the panel

local _, ns = ...
local Hark = ns.Hark

local UI = {}
Hark.UI = UI

local WIDTH = 248
local PAD = 6
local HEADER_H = 20
local CONTROLS_H = 22
local HINT_H = 14
local ROW_H = 16
local MAX_ROWS = 12
local BAR_W = 34
local MIN_SCALE, MAX_SCALE = 0.6, 1.6

local DEFAULT_POS = { point = "LEFT", relativePoint = "LEFT", x = 24, y = 120 }

local STATE_COLOR = {
	idle    = { 0.55, 0.55, 0.55 },
	joining = { 1.00, 0.82, 0.20 },
	active  = { 0.30, 0.85, 0.35 },
	off     = { 1.00, 0.55, 0.15 },
}

local frame            -- the panel, created in Init
local rows = {}        -- MAX_ROWS row buttons, all created in Init and reused
local rowByGUID = {}   -- [guid] = row, for the current draw
local NO_MEMBERS = {}  -- shared empty list; never written to

-- While the cursor is on the member list, rows keep the order they had, so
-- the row under the cursor stays the same player between redraws (a click
-- that pauses proximity drops the player's distance, which would re-sort).
local hoverRow         -- the row the cursor is on, or nil
local frozenOrder = {} -- [guid] = position in the last draw
local sortScratch = {} -- reused by the frozen sort

local lastLayout = {}  -- inputs of the last Layout call, to skip identical ones

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function DB()
	local db = Hark.db
	if not db then return nil end
	if type(db.ui) ~= "table" then db.ui = {} end
	return db.ui
end

local function Voice()
	return Hark.Voice
end

local function VoiceAvailable()
	local v = Voice()
	return v ~= nil and type(v.IsAvailable) == "function" and v:IsAvailable()
end

local function VoiceState()
	local v = Voice()
	if v and type(v.GetState) == "function" then return v:GetState() or "idle" end
	return "idle"
end

local function OptionsAvailable()
	return Hark.Options ~= nil and type(Hark.Options.Open) == "function"
end

local function OpenOptions()
	if OptionsAvailable() then
		Hark.Options:Open()
	else
		Hark:Print("Options are not available yet. Use /hark communities and /hark setcommunity <id>.")
	end
end

-- "0" when friendly nameplates are off. Read only; Hark never changes this CVar.
local function FriendlyNameplatesOff()
	local value
	local cvar = C_CVar
	if cvar and type(cvar.GetCVar) == "function" then
		local ok, v = pcall(cvar.GetCVar, "nameplateShowFriends")
		if ok then value = v end
	elseif type(GetCVar) == "function" then
		local ok, v = pcall(GetCVar, "nameplateShowFriends")
		if ok then value = v end
	end
	if Hark.IsSecret(value) then return false end
	return value == "0"
end

local function ModifierDown(fn)
	return type(fn) == "function" and fn() and true or false
end

local function ShortGUID(guid)
	if type(guid) ~= "string" then return "?" end
	return guid:match("(%x%x%x%x)$") or guid
end

local function DisplayName(m)
	if m.name and m.name ~= "" then
		return (m.name:gsub("%-.*$", "")) -- drop the realm to save space; full name in the tooltip
	end
	return "Unknown (" .. ShortGUID(m.guid) .. ")"
end

local function IsHuge(d)
	return d == math.huge or d == -math.huge or d ~= d
end

--- Short label and colour for a member's distance. Never prints math.huge.
local function DistanceText(m)
	local reason, d = m.reason, m.distance
	if m.override ~= nil or reason == "override" then
		local o = m.override
		if o == 0 then return "muted", 1, 0.35, 0.35 end
		if o == Hark.FULL_VOLUME then return "always on", 0.45, 0.75, 1 end
		return "fixed", 0.45, 0.75, 1
	end
	if reason == "near" or reason == "seen" then
		if type(d) ~= "number" or IsHuge(d) then return "out of range", 0.6, 0.6, 0.6 end
		local silent = Hark:Get("silentRange")
		if type(silent) == "number" and d >= silent then return "out of range", 0.6, 0.6, 0.6 end
		return string.format("%d yd", math.floor(d + 0.5)), 0.9, 0.9, 0.9
	elseif reason == "instance" then
		return "same instance", 0.9, 0.9, 0.9
	elseif reason == "layer" then
		return "other layer", 0.75, 0.6, 1
	elseif reason == "elsewhere" then
		return "elsewhere", 0.6, 0.6, 0.6
	end
	if type(d) == "number" and IsHuge(d) then return "out of range", 0.6, 0.6, 0.6 end
	return "unknown", 0.6, 0.6, 0.6
end

local function DistanceDetail(m)
	local reason, d = m.reason, m.distance
	if m.override ~= nil then return "Proximity paused for this player." end
	if (reason == "near" or reason == "seen") and type(d) == "number" and not IsHuge(d) then
		local how = reason == "seen" and "seen nearby" or "from their position"
		return string.format("%d yards (%s).", math.floor(d + 0.5), how)
	elseif reason == "instance" then
		return "In the same dungeon or raid."
	elseif reason == "layer" then
		return "Same zone, different layer: silent."
	elseif reason == "elsewhere" then
		return "Another continent, instance or hidden: silent."
	end
	if Hark:Get("hearUnknown") then
		return "No position known: heard at full volume (setting)."
	end
	return "No position known (no Hark, or not in your guild or group): silent."
end

local function VolumeColor(v)
	if v >= 67 then return 0.30, 0.85, 0.35 end
	if v >= 34 then return 0.95, 0.80, 0.20 end
	if v > 0 then return 1.00, 0.50, 0.15 end
	return 0.45, 0.45, 0.45
end

local function NextOverride(current)
	if current == nil then return 0 end
	if current == 0 then return Hark.FULL_VOLUME end
	return nil
end

local function OverrideLabel(o)
	if o == nil then return "Proximity" end
	if o == 0 then return "Muted" end
	if o == Hark.FULL_VOLUME then return "Always heard" end
	return "Fixed at " .. tostring(o) .. "%"
end

---------------------------------------------------------------------------
-- Widget builders
---------------------------------------------------------------------------

local function SetSmallFont(button)
	if type(button.SetNormalFontObject) == "function" then
		-- Font objects are passed by name so no global is read here.
		pcall(button.SetNormalFontObject, button, "GameFontNormalSmall")
		pcall(button.SetHighlightFontObject, button, "GameFontHighlightSmall")
		pcall(button.SetDisabledFontObject, button, "GameFontDisableSmall")
	end
end

local function ShowTooltip(owner, title, ...)
	local tip = GameTooltip
	if not tip then return end
	tip:SetOwner(owner, "ANCHOR_RIGHT")
	tip:SetText(title, 1, 1, 1)
	for i = 1, select("#", ...) do
		local line = select(i, ...)
		if line then tip:AddLine(line, 0.85, 0.85, 0.85, true) end
	end
	tip:Show()
end

local function HideTooltip()
	if GameTooltip then GameTooltip:Hide() end
end

local function TooltipOwner()
	local tip = GameTooltip
	if tip and type(tip.GetOwner) == "function" and tip:IsShown() then return tip:GetOwner() end
end

-- Hides GameTooltip only when it belongs to `root` or one of its children.
local function HideTooltipIfOwnedBy(root)
	local owner, depth = TooltipOwner(), 0
	while owner and depth < 20 do
		if owner == root then HideTooltip() return end
		owner = type(owner.GetParent) == "function" and owner:GetParent() or nil
		depth = depth + 1
	end
end

local function MakeButton(parent, text, width, onClick, tooltipFn)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(width, 18)
	b:SetText(text)
	SetSmallFont(b)
	b:SetScript("OnClick", onClick)
	if tooltipFn then
		b:SetScript("OnEnter", function(self) tooltipFn(self) end)
		b:SetScript("OnLeave", HideTooltip)
	end
	return b
end

local function OnRowEnter(self)
	hoverRow = self
	local m = self.member
	if not m then return end
	local vol = m.volume ~= nil and (tostring(m.volume) .. "%") or "not set yet"
	local target = m.target ~= nil and (tostring(m.target) .. "%") or "?"
	ShowTooltip(self, m.name or ("Unknown player (" .. ShortGUID(m.guid) .. ")"),
		m.isActive == false and "Not connected to voice right now." or nil,
		DistanceDetail(m),
		"Volume: " .. vol .. (m.volume ~= m.target and (", heading to " .. target) or ""),
		"Mode: " .. OverrideLabel(m.override),
		" ",
		"|cffffd200Click|r to cycle Proximity, Muted, Always heard.",
		"|cffffd200Right-click|r to return to Proximity.",
		"Overrides last for this session only.")
end

local function OnRowLeave(self)
	if hoverRow == self then hoverRow = nil end
	HideTooltip()
end

local function OnRowClick(self, button)
	local m = self.member
	if not m or not m.guid then return end
	local v = Voice()
	if not v or type(v.SetOverride) ~= "function" then return end
	local nextValue
	if button == "RightButton" then
		nextValue = nil
	else
		nextValue = NextOverride(v:GetOverride(m.guid))
	end
	v:SetOverride(m.guid, nextValue)
	m.override = nextValue
	UI:Refresh() -- also redraws this row's tooltip, still for the same player
end

local function CreateRow(index)
	local row = CreateFrame("Button", nil, frame.body)
	row:SetHeight(ROW_H)
	row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	row:SetScript("OnClick", OnRowClick)
	row:SetScript("OnEnter", OnRowEnter)
	row:SetScript("OnLeave", OnRowLeave)
	row:Hide()

	local hl = row:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 1, 1, 0.06)

	local dot = row:CreateTexture(nil, "ARTWORK")
	dot:SetSize(6, 6)
	dot:SetPoint("LEFT", row, "LEFT", 2, 0)
	row.dot = dot

	local barBg = row:CreateTexture(nil, "BACKGROUND")
	barBg:SetSize(BAR_W, 4)
	barBg:SetPoint("RIGHT", row, "RIGHT", -2, 0)
	barBg:SetColorTexture(1, 1, 1, 0.12)
	row.barBg = barBg

	local bar = row:CreateTexture(nil, "ARTWORK")
	bar:SetHeight(4)
	bar:SetPoint("LEFT", barBg, "LEFT", 0, 0)
	row.bar = bar

	local dist = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	dist:SetPoint("RIGHT", barBg, "LEFT", -6, 0)
	dist:SetWidth(72)
	dist:SetJustifyH("RIGHT")
	dist:SetWordWrap(false)
	row.dist = dist

	local name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	name:SetPoint("LEFT", dot, "RIGHT", 5, 0)
	name:SetPoint("RIGHT", dist, "LEFT", -4, 0)
	name:SetJustifyH("LEFT")
	name:SetWordWrap(false)
	row.name = name

	rows[index] = row
	return row
end

-- Returns members reordered to match the previous draw (new players last).
local function FrozenOrder(members)
	local list = sortScratch
	for i = #list, 1, -1 do list[i] = nil end
	for i, m in ipairs(members) do
		list[i] = m
		m.hkIndex = i
	end
	table.sort(list, function(a, b)
		local pa, pb = frozenOrder[a.guid or ""] or 100000, frozenOrder[b.guid or ""] or 100000
		if pa ~= pb then return pa < pb end
		return a.hkIndex < b.hkIndex
	end)
	return list
end

local function SetSpeaking(row, speaking, active)
	if speaking then
		row.dot:SetColorTexture(0.35, 1, 0.45, 1)
	elseif active == false then
		row.dot:SetColorTexture(0.25, 0.25, 0.25, 0.8)
	else
		row.dot:SetColorTexture(0.5, 0.5, 0.5, 0.6)
	end
end

local function FillRow(row, m)
	row.member = m
	row.name:SetText(DisplayName(m))
	if m.isActive == false then
		row.name:SetTextColor(0.55, 0.55, 0.55)
	elseif m.name then
		row.name:SetTextColor(1, 1, 1)
	else
		row.name:SetTextColor(0.75, 0.75, 0.75)
	end
	SetSpeaking(row, m.isSpeaking, m.isActive)

	local text, r, g, b = DistanceText(m)
	row.dist:SetText(text)
	row.dist:SetTextColor(r, g, b)

	local v = tonumber(m.volume)
	if v and v > 0 then
		if v > 100 then v = 100 end
		row.bar:SetWidth(math.max(1, BAR_W * v / 100))
		row.bar:SetColorTexture(VolumeColor(v))
		row.bar:Show()
	else
		row.bar:Hide()
	end
end

---------------------------------------------------------------------------
-- Position, scale, lock
---------------------------------------------------------------------------

local VALID_POINT = {
	TOPLEFT = true, TOP = true, TOPRIGHT = true, LEFT = true, CENTER = true,
	RIGHT = true, BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true,
}

-- A saved offset is usable when it is a finite number of sane size.
local function Offset(v)
	v = tonumber(v)
	if not v or v ~= v or v > 10000 or v < -10000 then return nil end
	return v
end

local function SavePosition()
	local db = DB()
	if not db or not frame then return end
	local point, _, relativePoint, x, y = frame:GetPoint(1)
	if VALID_POINT[point] then
		db.point = point
		db.relativePoint = VALID_POINT[relativePoint] and relativePoint or point
		db.x, db.y = math.floor((Offset(x) or 0) + 0.5), math.floor((Offset(y) or 0) + 0.5)
	end
end

local function SetDefaultPoint()
	frame:ClearAllPoints()
	frame:SetPoint(DEFAULT_POS.point, UIParent, DEFAULT_POS.relativePoint, DEFAULT_POS.x, DEFAULT_POS.y)
end

local function RestorePosition()
	local db = DB() or {}
	local point, rel = db.point, db.relativePoint
	local x, y = Offset(db.x), Offset(db.y)
	if not (VALID_POINT[point] and x and y) then
		SetDefaultPoint()
		return
	end
	if not VALID_POINT[rel] then rel = point end
	frame:ClearAllPoints()
	if not pcall(frame.SetPoint, frame, point, UIParent, rel, x, y) then SetDefaultPoint() end
end

--- Brings the header back on screen if the panel ended up outside it.
-- SetClampedToScreen already does this for SetPoint and dragging on current
-- clients; this is the fallback for any client where it does not, and for a
-- position saved under another resolution or UI scale.
local function EnsureOnScreen()
	if not frame or not frame:IsShown() then return end
	local l, t = frame:GetLeft(), frame:GetTop()
	local w, h = frame:GetWidth(), frame:GetHeight()
	local sw, sh = UIParent:GetWidth(), UIParent:GetHeight()
	if type(l) ~= "number" or type(t) ~= "number" or type(sw) ~= "number" or type(sh) ~= "number"
		or type(w) ~= "number" or sw <= 0 or sh <= 0 then
		return -- layout not resolved yet
	end
	-- Convert from the panel's coordinates to UIParent's.
	local fs, ps = frame:GetEffectiveScale(), UIParent:GetEffectiveScale()
	local k = (type(fs) == "number" and type(ps) == "number" and ps > 0) and fs / ps or 1
	local left, top, width = l * k, t * k, w * k
	local headerH = (PAD + HEADER_H) * k
	local inside = left >= -1 and left + width <= sw + 1 and top <= sh + 1 and top - headerH >= -1
	if inside then return end
	if width > sw then width = sw end
	local newLeft = math.min(math.max(left, 0), sw - width)
	local newTop = math.min(math.max(top, math.min(sh, (type(h) == "number" and h or 0) * k)), sh)
	frame:ClearAllPoints()
	frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", newLeft / k, newTop / k)
	SavePosition()
end

local function ClampScale(s)
	s = tonumber(s) or 1
	if s ~= s then s = 1 end
	if s < MIN_SCALE then s = MIN_SCALE end
	if s > MAX_SCALE then s = MAX_SCALE end
	return math.floor(s * 20 + 0.5) / 20
end

-- Change scale while keeping the top-left corner where it is on screen.
local function ApplyScale(newScale)
	local db = DB()
	newScale = ClampScale(newScale)
	local old = frame:GetScale() or 1
	local left, top = frame:GetLeft(), frame:GetTop()
	frame:SetScale(newScale)
	if type(left) == "number" and type(top) == "number" and old > 0 then
		frame:ClearAllPoints()
		frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left * old / newScale, top * old / newScale)
		SavePosition()
	end
	if db then db.scale = newScale end
	EnsureOnScreen()
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------

local function CurrentHint()
	if not Hark.db then return nil end
	if not VoiceAvailable() then
		return "Voice chat is not available on this client.",
			"Hark needs Blizzard voice chat to change volumes. Check that voice chat is enabled in the game's settings."
	end
	if not Hark:Get("communityId") then
		return "No community set: open Options to pick one.",
			"Hark joins the voice channel of one community. Choose it in Options, or use /hark communities then /hark setcommunity <id>."
	end
	if not Hark:IsEnabled() then
		return "Proximity is off: everyone is at full volume.", nil
	end
	if not Hark:Get("hearUnknown") and FriendlyNameplatesOff() then
		return "Tip: turn on friendly nameplates to range more players.",
			"Members outside your guild and group do not send positions. With friendly nameplates on, Hark can range them when they are visible on screen. Toggle friendly nameplates in the game's Interface settings (default key: Shift+V). Hark never changes this setting itself."
	end
	return nil
end

local function UpdateHeader(state)
	state = state or VoiceState()
	local enabled = Hark:IsEnabled()
	local key = state
	if state == "active" and not enabled then key = "off" end
	local c = STATE_COLOR[key] or STATE_COLOR.idle
	frame.stateDot:SetColorTexture(c[1], c[2], c[3], 1)

	local label
	if state == "active" then
		label = enabled and "in voice" or "in voice, proximity off"
		if frame.memberCount and frame.memberCount > 0 then
			label = label .. "  |cff999999" .. frame.memberCount .. "|r"
		end
	elseif state == "joining" then
		label = "joining..."
	else
		label = "not in voice"
	end
	frame.stateText:SetText(label)
	frame.stateText:SetTextColor(c[1], c[2], c[3])

	frame.collapseButton:SetText(DB() and DB().collapsed and "+" or "-")

	frame.enableButton:SetText(enabled and "Proximity: on" or "Proximity: off")

	if state == "active" then
		frame.joinButton:SetText("Leave")
		frame.joinButton:Enable()
	elseif state == "joining" then
		frame.joinButton:SetText("Cancel")
		frame.joinButton:Enable()
	else
		frame.joinButton:SetText("Join")
		if VoiceAvailable() and Hark:Get("communityId") then
			frame.joinButton:Enable()
		else
			frame.joinButton:Disable()
		end
	end
	if OptionsAvailable() then frame.optionsButton:Enable() else frame.optionsButton:Disable() end
end

local function Layout(visibleRows, extraLine, hintShown)
	local db = DB() or {}
	local collapsed = db.collapsed and true or false
	local L = lastLayout
	if L.rows == visibleRows and L.extra == extraLine and L.hint == hintShown and L.collapsed == collapsed then
		return -- nothing moved; avoid re-anchoring every row twice a second
	end
	L.rows, L.extra, L.hint, L.collapsed = visibleRows, extraLine, hintShown, collapsed

	local h = PAD + HEADER_H
	if collapsed then
		frame.body:Hide()
		frame:SetHeight(h + PAD - 2)
		return
	end
	frame.body:Show()
	local y = CONTROLS_H
	if hintShown then
		frame.hint:ClearAllPoints()
		frame.hint:SetPoint("TOPLEFT", frame.body, "TOPLEFT", 0, -y)
		frame.hint:SetPoint("TOPRIGHT", frame.body, "TOPRIGHT", 0, -y)
		frame.hint:Show()
		y = y + HINT_H + 2
	else
		frame.hint:Hide()
	end
	for i = 1, visibleRows do
		local row = rows[i]
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", frame.body, "TOPLEFT", 0, -y)
		row:SetPoint("TOPRIGHT", frame.body, "TOPRIGHT", 0, -y)
		y = y + ROW_H
	end
	if extraLine then
		frame.extra:ClearAllPoints()
		frame.extra:SetPoint("TOPLEFT", frame.body, "TOPLEFT", 2, -y - 2)
		frame.extra:Show()
		y = y + ROW_H
	else
		frame.extra:Hide()
	end
	frame.body:SetHeight(math.max(1, y))
	frame:SetHeight(h + 4 + y + PAD)
end

--- Redraw everything. Cheap: one GetMembers call and at most MAX_ROWS rows,
-- no frames or textures created. Does nothing while the panel is not visible;
-- OnShow redraws.
function UI:Refresh()
	if not frame or not frame:IsVisible() then return end
	local state = VoiceState()
	local db = DB() or {}

	local members = NO_MEMBERS
	if state == "active" then
		local v = Voice()
		if v and type(v.GetMembers) == "function" then
			local ok, list = pcall(v.GetMembers, v)
			if ok and type(list) == "table" then members = list end
		end
	end
	if hoverRow and members ~= NO_MEMBERS then members = FrozenOrder(members) end
	frame.memberCount = #members

	local tipOwner = TooltipOwner()
	wipe(rowByGUID)
	wipe(frozenOrder)
	local visible = 0
	if not db.collapsed then
		visible = math.min(#members, MAX_ROWS)
		for i = 1, visible do
			local row, m = rows[i], members[i]
			FillRow(row, m)
			row:Show()
			if m.guid then
				rowByGUID[m.guid] = row
				frozenOrder[m.guid] = i
			end
			-- Keep an open tooltip in step with the row: same data a click acts on.
			if tipOwner == row then OnRowEnter(row) end
		end
	end
	for i = visible + 1, #rows do
		local row = rows[i]
		if row.member or row:IsShown() then
			if tipOwner == row then HideTooltip() end
			if hoverRow == row then hoverRow = nil end
			row.member = nil
			row:Hide()
		end
	end

	local extra
	if not db.collapsed then
		if #members > MAX_ROWS then
			extra = "+" .. (#members - MAX_ROWS) .. " more"
		elseif state == "active" and #members == 0 then
			extra = "Nobody else is in the channel."
		elseif state == "joining" then
			extra = "Joining the community voice channel..."
		elseif state == "idle" then
			extra = "Not in proximity voice."
		end
		frame.extra:SetText(extra or "")
	end

	local hint, detail = CurrentHint()
	frame.hint.text:SetText(hint or "")
	frame.hint.detail = detail
	if not hint and tipOwner == frame.hint then HideTooltip() end

	UpdateHeader(state)
	Layout(visible, extra ~= nil, hint ~= nil)
end

local function OnMemberSpeaking(_, guid, isSpeaking)
	if not frame or not frame:IsVisible() then return end
	local row = guid and rowByGUID[guid]
	if row and row.member and row.member.guid == guid then
		row.member.isSpeaking = isSpeaking and true or false
		SetSpeaking(row, row.member.isSpeaking, row.member.isActive)
	end
end

---------------------------------------------------------------------------
-- Frame construction
---------------------------------------------------------------------------

local function ApplyLock()
	local db = DB() or {}
	frame:SetMovable(not db.locked)
	if db.locked then
		frame.header:RegisterForDrag()
	else
		frame.header:RegisterForDrag("LeftButton")
	end
end

local function Build()
	frame = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
	frame:SetWidth(WIDTH)
	frame:SetHeight(80)
	frame:SetFrameStrata("MEDIUM")
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	if type(frame.SetBackdrop) == "function" then
		frame:SetBackdrop({
			bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			tile = true, tileSize = 16, edgeSize = 12,
			insets = { left = 3, right = 3, top = 3, bottom = 3 },
		})
		frame:SetBackdropColor(0.05, 0.05, 0.07, 0.75)
		frame:SetBackdropBorderColor(0.35, 0.35, 0.4, 0.9)
	else
		local bg = frame:CreateTexture(nil, "BACKGROUND")
		bg:SetAllPoints()
		bg:SetColorTexture(0.05, 0.05, 0.07, 0.75)
	end

	-- Header: drag handle, title, state, collapse and close.
	local header = CreateFrame("Frame", nil, frame)
	header:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -PAD)
	header:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD, -PAD)
	header:SetHeight(HEADER_H)
	header:EnableMouse(true)
	header:SetScript("OnDragStart", function()
		local db = DB()
		if db and db.locked then return end
		frame:StartMoving()
	end)
	header:SetScript("OnDragStop", function()
		frame:StopMovingOrSizing()
		SavePosition()
	end)
	header:SetScript("OnMouseUp", function(_, button)
		if button == "RightButton" then
			local db = DB()
			if not db then return end
			db.locked = not db.locked
			ApplyLock()
			Hark:Print(db.locked and "Panel locked." or "Panel unlocked.")
		end
	end)
	if type(header.EnableMouseWheel) == "function" then
		header:EnableMouseWheel(true)
		header:SetScript("OnMouseWheel", function(_, delta)
			if not ModifierDown(IsControlKeyDown) then return end
			ApplyScale((frame:GetScale() or 1) + (delta > 0 and 0.05 or -0.05))
		end)
	end
	header:SetScript("OnEnter", function(self)
		local db = DB() or {}
		ShowTooltip(self, "Hark",
			"Proximity voice: members fade with distance.",
			db.locked and "Locked. Right-click to unlock." or "Drag to move. Right-click to lock.",
			"Ctrl + mouse wheel to resize.")
	end)
	header:SetScript("OnLeave", HideTooltip)
	frame.header = header

	local stateDot = header:CreateTexture(nil, "ARTWORK")
	stateDot:SetSize(8, 8)
	stateDot:SetPoint("LEFT", header, "LEFT", 2, 0)
	frame.stateDot = stateDot

	local title = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("LEFT", stateDot, "RIGHT", 6, 0)
	title:SetText("Hark")
	frame.title = title

	local closeButton = MakeButton(header, "x", 20, function() UI:Hide() end, function(self)
		ShowTooltip(self, "Hide panel", "Voice keeps running. Reopen it with /hark show, from Hark's options, or from the addon compartment.")
	end)
	closeButton:SetPoint("RIGHT", header, "RIGHT", 0, 0)

	local collapseButton = MakeButton(header, "-", 20, function()
		local db = DB()
		if not db then return end
		db.collapsed = not db.collapsed
		UI:Refresh()
	end, function(self)
		ShowTooltip(self, (DB() or {}).collapsed and "Expand" or "Collapse")
	end)
	collapseButton:SetPoint("RIGHT", closeButton, "LEFT", -2, 0)
	frame.collapseButton = collapseButton

	local stateText = header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	stateText:SetPoint("LEFT", title, "RIGHT", 8, 0)
	stateText:SetPoint("RIGHT", collapseButton, "LEFT", -4, 0)
	stateText:SetJustifyH("LEFT")
	stateText:SetWordWrap(false)
	frame.stateText = stateText

	-- Body: controls, hint, member rows.
	local body = CreateFrame("Frame", nil, frame)
	body:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
	body:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, -4)
	body:SetHeight(1)
	frame.body = body

	local controls = CreateFrame("Frame", nil, body)
	controls:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
	controls:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, 0)
	controls:SetHeight(CONTROLS_H)
	frame.controls = controls

	local enableButton = MakeButton(controls, "Proximity: on", 98, function()
		Hark:SetEnabled(not Hark:IsEnabled())
	end, function(self)
		ShowTooltip(self, "Proximity volumes",
			Hark:IsEnabled() and "On: members fade with distance. Click to turn off and restore everyone to full volume."
				or "Off: everyone is at full volume. Click to turn proximity back on.")
	end)
	enableButton:SetPoint("LEFT", controls, "LEFT", 0, 0)
	frame.enableButton = enableButton

	local joinButton = MakeButton(controls, "Join", 64, function()
		local v = Voice()
		if not v then return end
		local state = VoiceState()
		if state == "idle" then
			local ok, err = v:Join()
			if not ok and err then Hark:Print(err) end
		else
			v:Leave()
		end
	end, function(self)
		local state = VoiceState()
		if state == "active" then
			ShowTooltip(self, "Leave voice", "Restores everyone to full volume, then leaves. Auto-join waits until you join again.")
		elseif state == "joining" then
			ShowTooltip(self, "Cancel join", "Stops joining the community voice channel.")
		else
			ShowTooltip(self, "Join voice", "Joins the configured community's voice channel.")
		end
	end)
	joinButton:SetPoint("LEFT", enableButton, "RIGHT", 4, 0)
	frame.joinButton = joinButton

	local optionsButton = MakeButton(controls, "Options", 64, OpenOptions, function(self)
		ShowTooltip(self, "Options", "Community, ranges, volumes and fade curve.")
	end)
	optionsButton:SetPoint("RIGHT", controls, "RIGHT", 0, 0)
	frame.optionsButton = optionsButton

	local hint = CreateFrame("Frame", nil, body)
	hint:SetHeight(HINT_H)
	hint:EnableMouse(true)
	local hintText = hint:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	hintText:SetAllPoints()
	hintText:SetJustifyH("LEFT")
	hintText:SetWordWrap(false)
	hintText:SetTextColor(1, 0.82, 0.3)
	hint.text = hintText
	hint:SetScript("OnEnter", function(self)
		if self.detail then ShowTooltip(self, hintText:GetText() or "Hark", self.detail) end
	end)
	hint:SetScript("OnLeave", HideTooltip)
	hint:SetScript("OnMouseUp", function()
		if not Hark:Get("communityId") then OpenOptions() end
	end)
	frame.hint = hint

	local extra = body:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	extra:SetJustifyH("LEFT")
	extra:SetTextColor(0.6, 0.6, 0.6)
	frame.extra = extra

	for i = 1, MAX_ROWS do CreateRow(i) end

	frame:SetScript("OnShow", function()
		EnsureOnScreen()
		UI:Refresh()
	end)
	frame:SetScript("OnHide", function()
		frame:StopMovingOrSizing()
		hoverRow = nil
		HideTooltipIfOwnedBy(frame)
	end)

	-- The nameplate hint depends on a CVar the player can flip at any time.
	-- Only that CVar: Core writes its backup CVars often, and each write fires CVAR_UPDATE.
	-- A resolution or UI scale change can leave a saved position off-screen.
	for _, ev in ipairs({ "CVAR_UPDATE", "DISPLAY_SIZE_CHANGED", "UI_SCALE_CHANGED" }) do
		pcall(frame.RegisterEvent, frame, ev)
	end
	frame:SetScript("OnEvent", function(_, event, name)
		if event == "CVAR_UPDATE" then
			if type(name) == "string" and not Hark.IsSecret(name) and name:lower() == "nameplateshowfriends" then
				UI:Refresh()
			end
		else
			EnsureOnScreen()
		end
	end)
end

---------------------------------------------------------------------------
-- Public
---------------------------------------------------------------------------

function UI:Show()
	if not frame then return end
	local db = DB()
	if db then db.shown = true end
	frame:Show()
	EnsureOnScreen() -- also when it was already shown, but stranded
end

function UI:Hide()
	if not frame then return end
	local db = DB()
	if db then db.shown = false end
	frame:Hide()
end

function UI:Toggle()
	if not frame then return end
	if frame:IsShown() then self:Hide() else self:Show() end
end

function UI:IsShown()
	return frame ~= nil and frame:IsShown() and true or false
end

--- Default place, scale 1, unlocked, expanded, shown. For a lost panel.
function UI:ResetPosition()
	if not frame then return end
	local db = DB()
	if db then
		db.point, db.relativePoint, db.x, db.y = nil, nil, nil, nil
		db.scale, db.locked, db.collapsed = nil, nil, nil
	end
	frame:SetScale(1)
	SetDefaultPoint()
	ApplyLock()
	self:Show()
	self:Refresh()
end

-- Applies everything stored in Hark.db.ui. At Init, and again when Core
-- restores a settings backup that arrived late (SETTINGS_RESTORED), which
-- rewrites Hark.db.ui in place.
local function ApplySavedState()
	local db = DB() or {}
	if db.scale ~= nil then db.scale = ClampScale(db.scale) end
	frame:SetScale(db.scale or 1)
	RestorePosition()
	ApplyLock()
	wipe(lastLayout)
	if db.shown == false then
		frame:Hide()
	else
		frame:Show()
		EnsureOnScreen()
		UI:Refresh()
	end
end

function UI:Init()
	if frame then return end
	local ok, err = pcall(Build)
	if not ok then
		if frame then pcall(frame.Hide, frame) end
		frame = nil
		error(err, 0)
	end

	local function refresh() UI:Refresh() end
	Hark:RegisterCallback("LOADED", UI, refresh)
	Hark:RegisterCallback("VOICE_STATE_CHANGED", UI, refresh)
	Hark:RegisterCallback("MEMBERS_UPDATED", UI, refresh)
	Hark:RegisterCallback("ENABLED_CHANGED", UI, refresh)
	Hark:RegisterCallback("SETTING_CHANGED", UI, function(_, key)
		-- Only keys the panel shows; the rest would be a wasted redraw.
		if key == "communityId" or key == "hearUnknown" or key == "silentRange" or key == "enabled" then
			UI:Refresh()
		end
	end)
	Hark:RegisterCallback("MEMBER_SPEAKING", UI, OnMemberSpeaking)
	Hark:RegisterCallback("SETTINGS_RESTORED", UI, ApplySavedState)

	-- Shown by default; stays hidden once the player hides it.
	ApplySavedState()
end
