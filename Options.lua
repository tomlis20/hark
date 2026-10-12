--- Hark: Options panel
-- Settings controls built from Hark.SETTINGS. They are shown either in Hark's
-- own movable window or, when the client has the Settings API, on a canvas
-- page in the game's AddOns settings list (see "hosts" below).
-- Stores nothing of its own: every option is a schema key written via Hark:Set.

local _, ns = ...
local Hark = ns.Hark
local Options = {}
Hark.Options = Options

---------------------------------------------------------------------------
-- Layout constants
---------------------------------------------------------------------------

local PAD = 16
local LEFT_W = 280
local RIGHT_W = 290
local GAP = 22
local PANEL_W = PAD + LEFT_W + GAP + RIGHT_W + PAD
local RIGHT_X = PAD + LEFT_W + GAP
local COLUMNS_TOP = 84
local FOOTER_H = 48

local LIST_ROWS = 6
local ROW_H = 18

local GRAPH_W = RIGHT_W
local GRAPH_H = 84
local GRAPH_BARS = 57 -- (GRAPH_W - 4) / 5 bars of 4 px plus a 1 px gap

---------------------------------------------------------------------------
-- Labels. Keys without an entry still get a control with a generated label.
---------------------------------------------------------------------------

local LABELS = {
	autoJoin = { "Join voice automatically",
		"Join the community voice channel after login and on zone change, unless you left it by hand." },
	layerAware = { "Silence other layers",
		"Players confirmed to be on a different layer (zone copy) are silenced." },
	hearUnknown = { "Hear players without position",
		"Members whose position is unknown (no addon, not in your guild or group) play at maximum volume. Off: they are silent." },
	fullVoiceRange = { "Full voice range", "Within this distance players are at maximum volume." },
	silentRange = { "Silent range", "At or beyond this distance players are silent." },
	maxVolume = { "Maximum volume", "Volume within the full voice range." },
	minVolume = { "Minimum volume",
		"Volume just inside the silent range. Above 0 makes a step down to silence at the silent range." },
	fadeCurve = { "Fade curve",
		"Linear fades evenly. Natural drops quickly then lingers quietly. Smooth is gentle at both ends." },
	debug = { "Debug output", "Print diagnostic messages to chat." },
}

-- Preferred order; keys not listed follow alphabetically.
local ORDER = {
	"autoJoin", "layerAware", "hearUnknown",
	"fullVoiceRange", "silentRange", "maxVolume", "minVolume",
	"fadeCurve",
}

-- Handled by dedicated controls, not by the generic loop.
local SPECIAL = { enabled = true, communityId = true, streamId = true }
-- Shown under the "Advanced" heading.
local ADVANCED = { debug = true }

local function Humanize(key)
	local s = tostring(key):gsub("(%l)(%u)", "%1 %2"):lower()
	return (s:gsub("^%l", string.upper))
end

local function LabelFor(key)
	local l = LABELS[key]
	return l and l[1] or Humanize(key), l and l[2]
end

local function ChoiceLabel(value)
	return (tostring(value):gsub("^%l", string.upper))
end

local function FormatValue(key, value)
	if type(value) ~= "number" then return tostring(value) end
	local text = (value == math.floor(value)) and string.format("%d", value) or string.format("%.2f", value)
	if key:find("Range$") then return text .. " yd" end
	if key:find("Volume$") then return text .. "%" end
	return text
end

---------------------------------------------------------------------------
-- Widget helpers (each template has a plain fallback)
---------------------------------------------------------------------------

local BACKDROP_TEMPLATE = BackdropTemplateMixin and "BackdropTemplate" or nil

-- CreateFrame with an optional template; falls back to no template if the
-- template is missing on this client. Returns frame, usedTemplate.
local function Create(ftype, parent, template)
	if template then
		local ok, f = pcall(CreateFrame, ftype, nil, parent, template)
		if ok and f then return f, true end
	end
	return CreateFrame(ftype, nil, parent), false
end

-- Applies a backdrop when the frame supports it, else a flat colour texture.
local function SetBox(frame, backdrop, r, g, b, a, br, bg, bb, ba)
	if frame.SetBackdrop then
		local ok = pcall(frame.SetBackdrop, frame, backdrop)
		if ok then
			if r and frame.SetBackdropColor then frame:SetBackdropColor(r, g, b, a) end
			if br and frame.SetBackdropBorderColor then frame:SetBackdropBorderColor(br, bg, bb, ba) end
			return
		end
	end
	if backdrop and not frame.hkFlat then
		frame.hkFlat = frame:CreateTexture(nil, "BACKGROUND")
		frame.hkFlat:SetAllPoints()
	end
	if frame.hkFlat then
		frame.hkFlat:SetColorTexture(r or 0, g or 0, b or 0, a or 0.8)
		frame.hkFlat:SetShown(backdrop ~= nil)
	end
end

local BOX = {
	bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true, tileSize = 16, edgeSize = 12,
	insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

local PANEL_BOX = {
	bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true, tileSize = 16, edgeSize = 16,
	insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

local SLIDER_BOX = {
	bgFile = "Interface\\Buttons\\UI-SliderBar-Background",
	edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
	tile = true, tileSize = 8, edgeSize = 8,
	insets = { left = 3, right = 3, top = 6, bottom = 6 },
}

local function Text(parent, font, text, layer)
	local fs = parent:CreateFontString(nil, layer or "OVERLAY", font)
	if text then fs:SetText(text) end
	return fs
end

local function Click()
	if PlaySound and SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON then
		pcall(PlaySound, SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
	end
end

local function AttachTooltip(frame, title, body)
	if not body or not GameTooltip then return end
	frame:HookScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(title, 1, 1, 1)
		GameTooltip:AddLine(body, nil, nil, nil, true)
		GameTooltip:Show()
	end)
	frame:HookScript("OnLeave", function() GameTooltip:Hide() end)
end

local function NewButton(parent, label, w, h)
	local b, templated = Create("Button", parent, "UIPanelButtonTemplate")
	b:SetSize(w, h or 22)
	if not templated then
		local fb = Create("Button", parent, BACKDROP_TEMPLATE)
		b:Hide()
		b = fb
		b:SetSize(w, h or 22)
		SetBox(b, BOX, 0.15, 0.15, 0.18, 0.95, 0.6, 0.6, 0.6, 1)
		local fs = Text(b, "GameFontNormalSmall")
		fs:SetPoint("CENTER")
		b:SetFontString(fs)
		local hl = b:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints()
		hl:SetColorTexture(1, 1, 1, 0.12)
	end
	b:SetText(label)
	return b
end

local function NewCheck(parent, label, font)
	local cb, templated = Create("CheckButton", parent, "UICheckButtonTemplate")
	cb:SetSize(24, 24)
	if not templated then
		cb:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
		cb:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down")
		cb:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight", "ADD")
		cb:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
	end
	-- The template's own label is named or keyed differently across clients; use ours.
	if type(cb.Text) == "table" and cb.Text.Hide then cb.Text:Hide() end
	local fs = Text(cb, font or "GameFontHighlight", label)
	fs:SetPoint("LEFT", cb, "RIGHT", 2, 1)
	cb.hkLabel = fs
	cb:SetHitRectInsets(0, -(LEFT_W - 30), 0, 0)
	return cb
end

local function Heading(parent, label, x, y, w)
	local fs = Text(parent, "GameFontNormal", label)
	fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
	local line = parent:CreateTexture(nil, "ARTWORK")
	line:SetColorTexture(1, 0.82, 0, 0.25)
	line:SetHeight(1)
	line:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -(y + 16))
	line:SetWidth(w)
	return fs
end

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

-- The controls live on one content frame that moves between two hosts:
--   standalone  our own movable window under UIParent (chrome, close buttons)
--   canvas      a bare frame registered with the game's Settings window
-- Whichever host is shown last adopts the content, so the two can never
-- both show it, and neither host's chrome leaks into the other.
local panel            -- the content frame, built at Init
local standalone       -- host: own window
local canvas           -- host: Settings canvas
local category         -- Settings category when registered (or "legacy")
local buildError       -- set when Build failed, so Open can report it
local controls = {}    -- [key] = { kind, refresh = fn }
local refreshing = false

local communities = {} -- cached Voice:ListCommunities()
local listOffset = 0
local listRows = {}
local community = {}   -- widgets of the community section

local graph = {}       -- widgets of the curve preview
local enabledUI = {}
local resetUI = {}

local function Snap(value, spec)
	local step = spec.step
	if type(step) ~= "number" or not (step > 0) or step == math.huge then step = 1 end
	if type(value) ~= "number" or value ~= value then return spec.min end
	value = math.floor((value - spec.min) / step + 0.5) * step + spec.min
	if value < spec.min then value = spec.min end
	if value > spec.max then value = spec.max end
	return value
end

local function RefreshKey(key)
	local c = controls[key]
	if c then c.refresh() end
end

---------------------------------------------------------------------------
-- Generic controls built from the schema
---------------------------------------------------------------------------

local function BuildCheck(parent, key, x, y)
	local label, tip = LabelFor(key)
	local cb = NewCheck(parent, label)
	cb:SetPoint("TOPLEFT", parent, "TOPLEFT", x - 3, -y)
	AttachTooltip(cb, label, tip)
	cb:SetScript("OnClick", function(self)
		if refreshing then return end
		Click()
		Hark:Set(key, self:GetChecked() and true or false)
		RefreshKey(key) -- from Hark:Get, so a rejected write snaps back
	end)
	controls[key] = {
		kind = "boolean",
		refresh = function() cb:SetChecked(Hark:Get(key) and true or false) end,
	}
	return 26
end

local function BuildSlider(parent, key, spec, x, y, w)
	local label, tip = LabelFor(key)
	local box = CreateFrame("Frame", nil, parent)
	box:SetSize(w, 46)
	box:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)

	local title = Text(box, "GameFontNormalSmall", label)
	title:SetPoint("TOPLEFT", 0, 0)
	local valueText = Text(box, "GameFontHighlight")
	valueText:SetPoint("TOPRIGHT", 0, 0)

	local s = Create("Slider", box, BACKDROP_TEMPLATE)
	s:SetOrientation("HORIZONTAL")
	s:SetSize(w, 16)
	s:SetPoint("TOPLEFT", 0, -15)
	SetBox(s, SLIDER_BOX, 0.1, 0.1, 0.1, 0.8)
	s:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
	local thumb = s.GetThumbTexture and s:GetThumbTexture()
	if thumb then thumb:SetSize(32, 32) end
	s:SetMinMaxValues(spec.min, spec.max)
	s:SetValueStep((type(spec.step) == "number" and spec.step > 0) and spec.step or 1)
	if spec.min == spec.max and s.Disable then s:Disable() end
	-- Wiki name is SetObeyStepOnDrag; older docs say SetObeyStepDuringDrag.
	if s.SetObeyStepOnDrag then
		s:SetObeyStepOnDrag(true)
	elseif s.SetObeyStepDuringDrag then
		s:SetObeyStepDuringDrag(true)
	end
	s:EnableMouse(true)
	s:EnableMouseWheel(true)

	local low = Text(box, "GameFontHighlightSmall", FormatValue(key, spec.min))
	low:SetPoint("TOPLEFT", s, "BOTTOMLEFT", 2, 0)
	low:SetTextColor(0.6, 0.6, 0.6)
	local high = Text(box, "GameFontHighlightSmall", FormatValue(key, spec.max))
	high:SetPoint("TOPRIGHT", s, "BOTTOMRIGHT", -2, 0)
	high:SetTextColor(0.6, 0.6, 0.6)

	local function refresh()
		local v = Hark:Get(key)
		local was = refreshing
		refreshing = true
		if type(v) == "number" then s:SetValue(v) end
		refreshing = was
		valueText:SetText(FormatValue(key, v))
	end

	s:SetScript("OnValueChanged", function(_, value)
		if refreshing then return end
		value = Snap(value, spec)
		if value ~= Hark:Get(key) then Hark:Set(key, value) end
		refresh()
	end)
	s:SetScript("OnMouseWheel", function(_, delta)
		local cur = Hark:Get(key)
		if type(cur) ~= "number" then return end
		local step = (type(spec.step) == "number" and spec.step > 0) and spec.step or 1
		Hark:Set(key, Snap(cur + delta * step, spec))
		refresh()
	end)
	AttachTooltip(s, label, tip)

	controls[key] = { kind = "number", refresh = refresh }
	return 50
end

local function BuildChoices(parent, key, spec, x, y, w)
	local label, tip = LabelFor(key)
	local title = Text(parent, "GameFontNormalSmall", label)
	title:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)

	local n = #spec.choices
	if n == 0 then return 0 end
	local bw = math.max(24, math.floor((w - (n - 1) * 4) / n))
	local buttons = {}
	for i, choice in ipairs(spec.choices) do
		local b = NewButton(parent, ChoiceLabel(choice), bw, 22)
		b:SetPoint("TOPLEFT", parent, "TOPLEFT", x + (i - 1) * (bw + 4), -(y + 15))
		local mark = b:CreateTexture(nil, "OVERLAY")
		mark:SetColorTexture(0.3, 0.85, 0.45, 1)
		mark:SetHeight(2)
		mark:SetPoint("BOTTOMLEFT", 4, 2)
		mark:SetPoint("BOTTOMRIGHT", -4, 2)
		b.hkMark = mark
		b:SetScript("OnClick", function()
			Click()
			Hark:Set(key, choice)
			RefreshKey(key)
		end)
		AttachTooltip(b, label, tip)
		buttons[i] = b
	end

	controls[key] = {
		kind = "choice",
		refresh = function()
			local cur = Hark:Get(key)
			for i, b in ipairs(buttons) do
				local active = spec.choices[i] == cur
				b.hkMark:SetShown(active)
				if active then b:LockHighlight() else b:UnlockHighlight() end
				local fs = b.GetFontString and b:GetFontString()
				if fs then
					if active then fs:SetTextColor(1, 1, 1) else fs:SetTextColor(1, 0.82, 0) end
				end
			end
		end,
	}
	return 44
end

-- Schema keys for the generic loop, in display order.
local function OrderedKeys()
	local rank = {}
	for i, k in ipairs(ORDER) do rank[k] = i end
	local keys = {}
	for k, spec in pairs(Hark.SETTINGS) do
		if type(k) == "string" and not SPECIAL[k] and type(spec) == "table" and type(spec.type) == "string" then
			keys[#keys + 1] = k
		end
	end
	table.sort(keys, function(a, b)
		local ra, rb = rank[a] or 1000, rank[b] or 1000
		if ra ~= rb then return ra < rb end
		return a < b
	end)
	return keys
end

---------------------------------------------------------------------------
-- Enabled toggle (top of the panel)
---------------------------------------------------------------------------

local function RefreshEnabled()
	local on = Hark:IsEnabled()
	enabledUI.check:SetChecked(on)
	if on then
		enabledUI.status:SetText("|cff4ddc6aOn|r  volumes follow distance")
	else
		enabledUI.status:SetText("|cffff5a5aOff|r  everyone is at full volume")
	end
end

local function BuildEnabled(parent)
	local cb = NewCheck(parent, "Proximity voice", "GameFontNormalLarge")
	cb:SetSize(30, 30)
	cb:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD - 4, -38)
	cb:SetHitRectInsets(0, -160, 0, 0)
	AttachTooltip(cb, "Proximity voice",
		"Master switch. Off restores everyone in the channel to full volume immediately.")
	cb:SetScript("OnClick", function(self)
		if refreshing then return end
		Click()
		Hark:SetEnabled(self:GetChecked() and true or false)
		RefreshEnabled()
	end)
	local status = Text(parent, "GameFontHighlight")
	status:SetPoint("LEFT", cb, "RIGHT", 170, 0)
	enabledUI.check, enabledUI.status = cb, status
	controls.enabled = { kind = "enabled", refresh = RefreshEnabled }
end

---------------------------------------------------------------------------
-- Community picker
---------------------------------------------------------------------------

local function VoiceModule()
	local v = Hark.Voice
	if type(v) == "table" and type(v.ListCommunities) == "function" then return v end
end

local function ClubApiAvailable()
	return type(C_Club) == "table" and type(C_Club.GetSubscribedClubs) == "function"
end

local function LoadCommunities()
	local v = VoiceModule()
	local list
	if v then
		local ok, result = pcall(v.ListCommunities, v)
		if ok and type(result) == "table" then list = result end
	end
	communities = list or {}
	local maxOffset = math.max(0, #communities - LIST_ROWS)
	if listOffset > maxOffset then listOffset = maxOffset end
end

local function RenderCommunities()
	local selected = Hark:Get("communityId")
	for i, row in ipairs(listRows) do
		local c = communities[i + listOffset]
		if c then
			row.clubId = c.clubId
			row.name:SetText(c.name)
			row.id:SetText(c.clubId)
			row.sel:SetShown(c.clubId == selected)
			if c.clubId == selected then row.name:SetTextColor(1, 1, 1) else row.name:SetTextColor(1, 0.82, 0) end
			row:Show()
		else
			row.clubId = nil
			row:Hide()
		end
	end
	community.up:SetShown(listOffset > 0)
	community.down:SetShown(listOffset + LIST_ROWS < #communities)

	-- Empty-list / unavailable message inside the box
	local empty = community.empty
	if not VoiceModule() then
		empty:SetText("|cffff5a5aHark's voice module is not loaded.|r")
	elseif not ClubApiAvailable() then
		empty:SetText("|cffff5a5aCommunities are not available on this client.|r")
	elseif #communities == 0 then
		empty:SetText("No communities found yet. The list can take a\nmoment to load after login: press Refresh.")
	else
		empty:SetText("")
	end

	-- Selection and stream
	local selName
	for _, c in ipairs(communities) do
		if c.clubId == selected then selName = c.name end
	end
	if not selected then
		community.selected:SetText("Community: |cffaaaaaanone selected|r")
	elseif selName then
		community.selected:SetText("Community: |cffffffff" .. selName .. "|r")
	else
		community.selected:SetText("Community: |cffffffffid " .. selected .. "|r |cffaaaaaa(not in your list)|r")
	end

	local stream
	local v = VoiceModule()
	if selected and v and type(v.ResolveStreamId) == "function" then
		local ok, s = pcall(v.ResolveStreamId, v, selected)
		if ok and s ~= nil then stream = tostring(s) end
	end
	if stream then
		local how = Hark:Get("streamId") and "saved" or "auto"
		community.stream:SetText("Voice stream: |cffffffff" .. stream .. "|r |cffaaaaaa(" .. how .. ")|r")
	else
		community.stream:SetText("Voice stream: |cffaaaaaa-|r")
	end

	-- Join / leave
	local avail = v and type(v.IsAvailable) == "function" and v:IsAvailable()
	local state = v and type(v.GetState) == "function" and v:GetState() or "idle"
	if not avail then
		community.join:SetText("No voice API")
		community.join:Disable()
	elseif state == "idle" then
		community.join:SetText("Join voice")
		if selected then community.join:Enable() else community.join:Disable() end
	elseif state == "joining" then
		community.join:SetText("Joining...")
		community.join:Enable()
	else
		community.join:SetText("Leave voice")
		community.join:Enable()
	end
end

local function Scroll(delta)
	local maxOffset = math.max(0, #communities - LIST_ROWS)
	listOffset = math.min(maxOffset, math.max(0, listOffset - delta))
	RenderCommunities()
end

local function BuildCommunity(parent, x, y)
	Heading(parent, "Community", x, y, RIGHT_W)
	y = y + 22

	local box = Create("Frame", parent, BACKDROP_TEMPLATE)
	box:SetSize(RIGHT_W, LIST_ROWS * ROW_H + 8)
	box:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
	SetBox(box, BOX, 0, 0, 0, 0.5, 0.4, 0.4, 0.4, 1)
	box:EnableMouseWheel(true)
	box:SetScript("OnMouseWheel", function(_, delta) Scroll(delta) end)

	for i = 1, LIST_ROWS do
		local row = CreateFrame("Button", nil, box)
		row:SetSize(RIGHT_W - 28, ROW_H)
		row:SetPoint("TOPLEFT", box, "TOPLEFT", 4, -4 - (i - 1) * ROW_H)
		local sel = row:CreateTexture(nil, "BACKGROUND")
		sel:SetAllPoints()
		sel:SetColorTexture(0.3, 0.85, 0.45, 0.25)
		row.sel = sel
		local hl = row:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints()
		hl:SetColorTexture(1, 1, 1, 0.08)
		row.name = Text(row, "GameFontNormalSmall")
		row.name:SetPoint("LEFT", 4, 0)
		row.name:SetPoint("RIGHT", -70, 0)
		row.name:SetJustifyH("LEFT")
		row.id = Text(row, "GameFontDisableSmall")
		row.id:SetPoint("RIGHT", -4, 0)
		row:SetScript("OnClick", function(self)
			local id = self.clubId
			if not id then return end
			Click()
			if id ~= Hark:Get("communityId") then
				Hark:Set("communityId", id)
				-- A saved stream id belonged to the previous community.
				if Hark:Get("streamId") ~= nil then Hark:Set("streamId", nil) end
			end
			RenderCommunities()
		end)
		listRows[i] = row
	end

	local up = CreateFrame("Button", nil, box)
	up:SetSize(20, 20)
	up:SetPoint("TOPRIGHT", -3, -3)
	up:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollUp-Up")
	up:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollUp-Down")
	up:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
	up:SetScript("OnClick", function() Scroll(1) end)
	local down = CreateFrame("Button", nil, box)
	down:SetSize(20, 20)
	down:SetPoint("BOTTOMRIGHT", -3, 3)
	down:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up")
	down:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Down")
	down:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
	down:SetScript("OnClick", function() Scroll(-1) end)
	community.up, community.down = up, down

	local empty = Text(box, "GameFontHighlightSmall")
	empty:SetPoint("CENTER")
	empty:SetWidth(RIGHT_W - 20)
	empty:SetJustifyH("CENTER")
	community.empty = empty
	y = y + LIST_ROWS * ROW_H + 8 + 4

	local selected = Text(parent, "GameFontNormalSmall")
	selected:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
	selected:SetWidth(RIGHT_W)
	selected:SetJustifyH("LEFT")
	community.selected = selected
	y = y + 14
	local stream = Text(parent, "GameFontNormalSmall")
	stream:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
	stream:SetJustifyH("LEFT")
	community.stream = stream
	y = y + 18

	local refresh = NewButton(parent, "Refresh", 86, 22)
	refresh:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
	refresh:SetScript("OnClick", function()
		Click()
		LoadCommunities()
		RenderCommunities()
	end)
	AttachTooltip(refresh, "Refresh", "Reload your community list from the client.")

	local clear = NewButton(parent, "Clear", 70, 22)
	clear:SetPoint("LEFT", refresh, "RIGHT", 4, 0)
	clear:SetScript("OnClick", function()
		Click()
		Hark:Set("communityId", nil)
		Hark:Set("streamId", nil)
		RenderCommunities()
	end)
	AttachTooltip(clear, "Clear", "Forget the selected community and stream.")

	local join = NewButton(parent, "Join voice", RIGHT_W - 86 - 70 - 8, 22)
	join:SetPoint("LEFT", clear, "RIGHT", 4, 0)
	join:SetScript("OnClick", function()
		local v = VoiceModule()
		if not v then return end
		Click()
		local state = type(v.GetState) == "function" and v:GetState() or "idle"
		if state == "idle" then
			local ok, err = v:Join()
			if not ok and err then Hark:Print(err) end
		else
			v:Leave()
		end
		RenderCommunities()
	end)
	community.join = join
	return y + 26
end

---------------------------------------------------------------------------
-- Fade-curve preview
---------------------------------------------------------------------------

local function GraphMaxDistance()
	local silent = Hark:Get("silentRange") or 40
	return math.max(10, math.ceil(silent * 1.2 / 5) * 5)
end

local function RedrawGraph()
	if not graph.bars then return end
	local full = Hark:Get("fullVoiceRange") or 0
	local silent = Hark:Get("silentRange") or 1
	local maxD = GraphMaxDistance()
	local innerH = GRAPH_H - 6
	for i, bar in ipairs(graph.bars) do
		local d = (i - 0.5) / GRAPH_BARS * maxD
		local ok, v = pcall(Hark.GetVolumeForDistance, Hark, d)
		v = ok and tonumber(v) or 0
		if v > 0 then
			bar:SetHeight(math.max(1, v / 100 * innerH))
			if d <= full then
				bar:SetColorTexture(0.3, 0.85, 0.45, 0.9)
			else
				bar:SetColorTexture(1, 0.75, 0.2, 0.9)
			end
		else
			bar:SetHeight(1)
			bar:SetColorTexture(0.6, 0.25, 0.25, 0.6)
		end
	end
	local plotW = GRAPH_W - 6
	local function place(line, label, dist, text)
		local px = math.min(plotW, math.max(0, dist / maxD * plotW))
		line:ClearAllPoints()
		line:SetPoint("TOPLEFT", graph.frame, "TOPLEFT", 3 + px, -3)
		line:SetPoint("BOTTOMLEFT", graph.frame, "BOTTOMLEFT", 3 + px, 3)
		label:ClearAllPoints()
		label:SetPoint("TOP", graph.frame, "BOTTOMLEFT", 3 + px, -1)
		label:SetText(text)
	end
	place(graph.fullLine, graph.fullLabel, full, full .. "")
	place(graph.silentLine, graph.silentLabel, silent, silent .. "")
	graph.maxLabel:SetText(maxD .. " yd")
end

local function BuildGraph(parent, x, y)
	Heading(parent, "Volume by distance", x, y, RIGHT_W)
	y = y + 22
	local f = Create("Frame", parent, BACKDROP_TEMPLATE)
	f:SetSize(GRAPH_W, GRAPH_H)
	f:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
	SetBox(f, BOX, 0, 0, 0, 0.6, 0.4, 0.4, 0.4, 1)
	graph.frame = f

	-- 50% guide
	local mid = f:CreateTexture(nil, "BACKGROUND", nil, 1)
	mid:SetColorTexture(1, 1, 1, 0.08)
	mid:SetHeight(1)
	mid:SetPoint("LEFT", f, "BOTTOMLEFT", 3, 3 + (GRAPH_H - 6) / 2)
	mid:SetPoint("RIGHT", f, "BOTTOMRIGHT", -3, 3 + (GRAPH_H - 6) / 2)

	local slot = (GRAPH_W - 6) / GRAPH_BARS
	local barW = math.max(1, math.floor(slot) - 1)
	graph.bars = {}
	for i = 1, GRAPH_BARS do
		local bar = f:CreateTexture(nil, "ARTWORK")
		bar:SetWidth(barW)
		bar:SetHeight(1)
		bar:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 3 + math.floor((i - 1) * slot), 3)
		graph.bars[i] = bar
	end

	local function marker(r, g, b)
		local line = f:CreateTexture(nil, "OVERLAY")
		line:SetColorTexture(r, g, b, 0.7)
		line:SetWidth(1)
		local label = Text(parent, "GameFontHighlightSmall")
		label:SetTextColor(r, g, b)
		return line, label
	end
	graph.fullLine, graph.fullLabel = marker(0.3, 0.85, 0.45)
	graph.silentLine, graph.silentLabel = marker(1, 0.4, 0.4)

	local top = Text(f, "GameFontDisableSmall", "100%")
	top:SetPoint("TOPLEFT", 5, -4)
	local zero = Text(parent, "GameFontDisableSmall", "0")
	zero:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 0, -1)
	graph.maxLabel = Text(parent, "GameFontDisableSmall")
	graph.maxLabel:SetPoint("TOPRIGHT", f, "BOTTOMRIGHT", 0, -1)
	return y + GRAPH_H + 18
end

---------------------------------------------------------------------------
-- Reset with confirmation (inline: no StaticPopupDialogs global entry)
---------------------------------------------------------------------------

local function DisarmReset()
	if resetUI.timer then resetUI.timer:Cancel() end
	resetUI.timer = nil
	resetUI.armed = false
	if resetUI.button then resetUI.button:SetText("Reset to defaults") end
	if resetUI.cancel then resetUI.cancel:Hide() end
	if resetUI.hint then resetUI.hint:SetText("") end
end

local function BuildReset(parent)
	local b = NewButton(parent, "Reset to defaults", 140, 22)
	b:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", PAD, 14)
	local cancel = NewButton(parent, "Cancel", 70, 22)
	cancel:SetPoint("LEFT", b, "RIGHT", 4, 0)
	cancel:Hide()
	local hint = Text(parent, "GameFontHighlightSmall")
	hint:SetPoint("LEFT", cancel, "RIGHT", 8, 0)
	resetUI.button, resetUI.cancel, resetUI.hint = b, cancel, hint

	b:SetScript("OnClick", function()
		Click()
		if resetUI.armed then
			DisarmReset()
			Hark:ResetSettings()
			Options:Refresh()
			return
		end
		resetUI.armed = true
		b:SetText("Confirm reset")
		cancel:Show()
		hint:SetText("|cffff8080Every setting goes back to its default.|r")
		if C_Timer and C_Timer.NewTimer then
			resetUI.timer = C_Timer.NewTimer(6, DisarmReset)
		end
	end)
	cancel:SetScript("OnClick", function() Click() DisarmReset() end)
end

---------------------------------------------------------------------------
-- On-screen panel visibility (Hark.UI). Not a schema key: UI.lua owns it.
---------------------------------------------------------------------------

local panelUI = {}

local function UIModule()
	local ui = Hark.UI
	if type(ui) == "table" and type(ui.IsShown) == "function" then return ui end
end

local function RefreshPanelRow()
	if not panelUI.check then return end
	local ui = UIModule()
	panelUI.check:SetChecked(ui ~= nil and ui:IsShown() and true or false)
	if ui then panelUI.check:Enable() else panelUI.check:Disable() end
	if ui and type(ui.ResetPosition) == "function" then panelUI.reset:Enable() else panelUI.reset:Disable() end
end

local function BuildPanelRow(parent, x, y)
	local cb = NewCheck(parent, "Show the Hark panel")
	cb:SetPoint("TOPLEFT", parent, "TOPLEFT", x - 3, -y)
	cb:SetHitRectInsets(0, -150, 0, 0)
	AttachTooltip(cb, "Hark panel",
		"The small on-screen list of voice members. Also /hark show, /hark hide and /hark toggle.")
	cb:SetScript("OnClick", function(self)
		local ui = UIModule()
		if not ui then return end
		Click()
		if self:GetChecked() then
			if type(ui.Show) == "function" then ui:Show() end
		elseif type(ui.Hide) == "function" then
			ui:Hide()
		end
		RefreshPanelRow()
	end)
	local reset = NewButton(parent, "Reset position", 104, 20)
	reset:SetPoint("TOPRIGHT", parent, "TOPLEFT", x + LEFT_W, -(y + 2))
	reset:SetScript("OnClick", function()
		local ui = UIModule()
		if not ui or type(ui.ResetPosition) ~= "function" then return end
		Click()
		ui:ResetPosition()
		RefreshPanelRow()
	end)
	AttachTooltip(reset, "Reset position", "Moves the Hark panel back to its default place and size, and shows it.")
	panelUI.check, panelUI.reset = cb, reset
	return 26
end

---------------------------------------------------------------------------
-- Panel
---------------------------------------------------------------------------

-- A number key gets a slider only when its range is usable.
local function IsSliderSpec(spec)
	local lo, hi = spec.min, spec.max
	return type(lo) == "number" and type(hi) == "number" and lo == lo and hi == hi
		and lo > -math.huge and hi < math.huge and lo <= hi
end

-- Keys whose change moves the curve preview.
local CURVE_KEYS = { fullVoiceRange = true, silentRange = true, minVolume = true, maxVolume = true, fadeCurve = true }

-- Hides GameTooltip only when one of our frames owns it, so hiding a panel
-- never closes a tooltip another addon (or the world) is showing.
local function HideTooltipIfOwnedBy(root)
	local tip = GameTooltip
	if not tip or type(tip.GetOwner) ~= "function" then return end
	local owner = tip:GetOwner()
	local depth = 0
	while owner and depth < 20 do
		if owner == root then tip:Hide() return end
		owner = type(owner.GetParent) == "function" and owner:GetParent() or nil
		depth = depth + 1
	end
end

local function SettingsPanelShown()
	local sp = SettingsPanel
	if type(sp) == "table" and type(sp.IsShown) == "function" and sp:IsShown() then return true end
	local legacy = InterfaceOptionsFrame
	return type(legacy) == "table" and type(legacy.IsShown) == "function" and legacy:IsShown() and true or false
end

local function HideSettingsPanel()
	local sp = (type(SettingsPanel) == "table" and SettingsPanel:IsShown() and SettingsPanel)
		or (type(InterfaceOptionsFrame) == "table" and InterfaceOptionsFrame:IsShown() and InterfaceOptionsFrame)
	if not sp then return end
	if type(HideUIPanel) == "function" then
		if pcall(HideUIPanel, sp) and not sp:IsShown() then return end
	end
	pcall(sp.Hide, sp)
end

--- Moves the controls into `host` and redraws them.
local function Adopt(host)
	if panel:GetParent() ~= host then
		panel:SetParent(host)
		panel:ClearAllPoints()
		panel:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0)
		panel:SetSize(PANEL_W, panel.hkHeight)
	end
	panel:Show()
	panel.hkCloseBottom:SetShown(host == standalone)
	canvas.hkAway:SetShown(host ~= canvas)
	LoadCommunities()
	Options:Refresh()
end

local function BuildContent()
	local p = CreateFrame("Frame", nil, UIParent)
	p:Hide()

	local title = Text(p, "GameFontNormalLarge", "Hark")
	title:SetPoint("TOPLEFT", PAD, -14)
	local sub = Text(p, "GameFontDisableSmall", "proximity voice  v" .. tostring(Hark.version or ""))
	sub:SetPoint("LEFT", title, "RIGHT", 8, -1)

	BuildEnabled(p)
	local sep = p:CreateTexture(nil, "ARTWORK")
	sep:SetColorTexture(1, 1, 1, 0.1)
	sep:SetHeight(1)
	sep:SetPoint("TOPLEFT", PAD, -74)
	sep:SetPoint("TOPRIGHT", -PAD, -74)

	-- Left column: booleans, numbers, then advanced
	local keys = OrderedKeys()
	local ly = COLUMNS_TOP
	local function section(label, filter, extra)
		local any = false
		for _, k in ipairs(keys) do
			local spec = Hark.SETTINGS[k]
			if filter(k, spec) then
				if not any then
					Heading(p, label, PAD, ly, LEFT_W)
					ly = ly + 24
					any = true
				end
				if spec.type == "boolean" then
					ly = ly + BuildCheck(p, k, PAD, ly)
				elseif spec.type == "number" then
					ly = ly + BuildSlider(p, k, spec, PAD, ly, LEFT_W)
				end
			end
		end
		if extra then
			if not any then
				Heading(p, label, PAD, ly, LEFT_W)
				ly = ly + 24
				any = true
			end
			ly = ly + extra(p, PAD, ly)
		end
		if any then ly = ly + 6 end
	end
	section("General", function(k, s) return not ADVANCED[k] and s.type == "boolean" end, BuildPanelRow)
	section("Distance and volume", function(k, s)
		return not ADVANCED[k] and s.type == "number" and IsSliderSpec(s)
	end)
	section("Advanced", function(k, s)
		return ADVANCED[k] and (s.type == "boolean" or (s.type == "number" and IsSliderSpec(s)))
	end)

	-- Right column: community, curve preview, choice settings
	local ry = BuildCommunity(p, RIGHT_X, COLUMNS_TOP)
	ry = ry + 8
	ry = BuildGraph(p, RIGHT_X, ry)
	for _, k in ipairs(keys) do
		local spec = Hark.SETTINGS[k]
		if spec.type == "string" and type(spec.choices) == "table" and #spec.choices > 0 then
			ry = ry + BuildChoices(p, k, spec, RIGHT_X, ry, RIGHT_W)
		end
	end

	BuildReset(p)
	local done = NewButton(p, "Close", 90, 22)
	done:SetPoint("BOTTOMRIGHT", -PAD, 14)
	done:SetScript("OnClick", function() Options:Close() end)
	p.hkCloseBottom = done

	p.hkHeight = math.max(ly, ry) + FOOTER_H
	p:SetSize(PANEL_W, p.hkHeight)

	-- Club list changes. Each name is registered on its own so a missing event
	-- on this client does not stop the others (RegisterEvent raises on unknown names).
	for _, ev in ipairs({ "INITIAL_CLUBS_LOADED", "CLUB_ADDED", "CLUB_REMOVED", "CLUB_UPDATED" }) do
		pcall(p.RegisterEvent, p, ev)
	end
	p:SetScript("OnEvent", function(self)
		if self:IsVisible() then
			LoadCommunities()
			RenderCommunities()
		end
	end)
	return p
end

local function OnHostHide(host)
	DisarmReset()
	HideTooltipIfOwnedBy(host)
end

local function BuildStandalone()
	-- The one named frame (CONTRACT.md 1): UISpecialFrames closes frames by
	-- global name on Escape. Escape calls f:Hide(), the same path as the X and
	-- Close buttons, so OnHostHide runs either way.
	local FRAME_NAME = "HarkOptionsFrame"
	local f
	if BACKDROP_TEMPLATE then
		local ok, made = pcall(CreateFrame, "Frame", FRAME_NAME, UIParent, BACKDROP_TEMPLATE)
		if ok then f = made end
	end
	f = f or CreateFrame("Frame", FRAME_NAME, UIParent)
	-- rawget: a plain existence probe, so a client without the table reads nothing.
	local special = rawget(_G, "UISpecialFrames")
	if type(special) == "table" then
		local listed = false
		for _, name in ipairs(special) do
			if name == FRAME_NAME then listed = true end
		end
		if not listed then table.insert(special, FRAME_NAME) end
	end
	f:Hide()
	f:SetFrameStrata("DIALOG")
	f:SetToplevel(true)
	f:SetClampedToScreen(true)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", function(self) self:StartMoving() end)
	f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
	f:SetSize(PANEL_W, panel.hkHeight)
	f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
	SetBox(f, PANEL_BOX, 0.05, 0.05, 0.07, 0.95, 0.5, 0.5, 0.55, 1)

	local close, templated = Create("Button", f, "UIPanelCloseButton")
	if not templated then
		close:Hide()
		close = NewButton(f, "X", 22, 22)
	end
	close:SetPoint("TOPRIGHT", -4, -4)
	close:SetScript("OnClick", function() f:Hide() end)
	if close.SetFrameLevel and f.GetFrameLevel then
		local level = f:GetFrameLevel()
		if type(level) == "number" then close:SetFrameLevel(level + 10) end
	end
	f.hkClose = close

	f:SetScript("OnShow", function(self) Adopt(self) end)
	f:SetScript("OnHide", OnHostHide)
	return f
end

local function BuildCanvas()
	-- Parent, points and visibility belong to the Settings window from here on.
	local f = CreateFrame("Frame", nil, UIParent)
	f:Hide()
	f:SetSize(PANEL_W, panel.hkHeight)
	f.name = "Hark" -- category name for the legacy InterfaceOptions_AddCategory

	-- Shown in the canvas while the controls are open in their own window.
	local away = Text(f, "GameFontHighlight", "Hark settings are open in their own window.")
	away:SetPoint("TOPLEFT", PAD, -16)
	away:Hide()
	f.hkAway = away

	f:SetScript("OnShow", function(self)
		-- Exactly one place shows the controls: the Settings window wins.
		if standalone:IsShown() then standalone:Hide() end
		Adopt(self)
	end)
	-- OnShow covers the Settings window showing the page; this covers a client
	-- that re-shows an already-shown page without firing it.
	f.hkClaim = function(self)
		if standalone:IsShown() then standalone:Hide() end
		if panel:GetParent() ~= self or not panel:IsVisible() then Adopt(self) end
	end
	f:SetScript("OnHide", OnHostHide)

	-- Hooks the Settings window may call (as methods).
	f.OnCommit = function() end
	f.OnRefresh = function() if panel:IsVisible() then Options:Refresh() end end
	f.OnDefault = function() Hark:ResetSettings() Options:Refresh() end
	f.OnCancel = function() end
	return f
end

local function Build()
	if panel or buildError then return panel ~= nil end
	local ok, err = pcall(function()
		panel = BuildContent()
		standalone = BuildStandalone()
		canvas = BuildCanvas()
	end)
	if not ok then
		buildError = tostring(err)
		for _, f in ipairs({ panel, standalone, canvas }) do
			if f then pcall(f.Hide, f) end
		end
		panel, standalone, canvas = nil, nil, nil
		error(err, 0)
	end
	return true
end

local function RegisterWithSettings()
	if category then return end
	if type(Settings) == "table" and type(Settings.RegisterCanvasLayoutCategory) == "function"
		and type(Settings.RegisterAddOnCategory) == "function" then
		local ok, cat = pcall(Settings.RegisterCanvasLayoutCategory, canvas, "Hark")
		if not ok then Hark._RecordError("Settings.RegisterCanvasLayoutCategory", cat) end
		if ok and cat then
			local okAdd, err = pcall(Settings.RegisterAddOnCategory, cat)
			if okAdd then category = cat else Hark._RecordError("Settings.RegisterAddOnCategory", err) end
		end
		return
	end
	-- Older clients: the legacy Interface Options list.
	if type(InterfaceOptions_AddCategory) == "function" then
		local ok, err = pcall(InterfaceOptions_AddCategory, canvas)
		if ok then category = "legacy" else Hark._RecordError("InterfaceOptions_AddCategory", err) end
	end
end

--- Internal, for /hark selftest only (Diagnostics.lua).
function Options._DiagState()
	local kind = false
	if category == "legacy" then kind = "legacy" elseif category ~= nil then kind = "settings" end
	return { registered = kind, buildError = buildError, built = panel ~= nil }
end

-- Asks the game's settings window to show our page. True if the call did not raise.
local function OpenInSettings()
	if category == "legacy" then
		return type(InterfaceOptionsFrame_OpenToCategory) == "function"
			and pcall(InterfaceOptionsFrame_OpenToCategory, canvas)
	end
	if type(Settings) ~= "table" or type(Settings.OpenToCategory) ~= "function" then return false end
	local id
	if type(category.GetID) == "function" then
		local ok, v = pcall(category.GetID, category)
		if ok then id = v end
	end
	if id == nil then id = category.ID end
	if id == nil then return false end
	return pcall(Settings.OpenToCategory, id)
end

local function ShowStandalone()
	if standalone:IsShown() then
		-- Already open: make sure it holds the controls and is on top.
		Adopt(standalone)
	else
		standalone:Show()
	end
	if standalone.Raise then standalone:Raise() end
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

function Options:Init()
	Build()
	RegisterWithSettings()

	Hark:RegisterCallback("SETTING_CHANGED", Options, function(_, key)
		-- Hidden: every host redraws everything when it is shown.
		if not panel or not panel:IsVisible() then return end
		if refreshing then return end
		if controls[key] then RefreshKey(key) else Options:Refresh() return end
		if CURVE_KEYS[key] then RedrawGraph() end
		if key == "communityId" or key == "streamId" then RenderCommunities() end
	end)
	Hark:RegisterCallback("SETTINGS_RESTORED", Options, function()
		if panel and panel:IsVisible() then Options:Refresh() end
	end)
	Hark:RegisterCallback("VOICE_STATE_CHANGED", Options, function()
		if panel and panel:IsVisible() then RenderCommunities() end
	end)
end

--- Re-read every control from Hark:Get. Called on SETTING_CHANGED and on show.
function Options:Refresh()
	if not panel then return end
	local was = refreshing
	refreshing = true
	for _, c in pairs(controls) do
		local ok, err = pcall(c.refresh)
		if not ok then geterrorhandler()(err) end
	end
	refreshing = was
	RedrawGraph()
	RenderCommunities()
	RefreshPanelRow()
end

function Options:Open()
	local ok = pcall(Build)
	if not ok or not panel then
		Hark:Print("The options panel failed to load: " .. tostring(buildError))
		return
	end
	if canvas:IsVisible() then canvas:hkClaim() return end
	-- The Settings window is not used in combat; our own window works there.
	local combat = type(InCombatLockdown) == "function" and InCombatLockdown()
	if category and not combat then
		local wasOpen = SettingsPanelShown()
		-- Some clients open the window on the wrong page the first time: try twice.
		for _ = 1, 2 do
			if OpenInSettings() and canvas:IsVisible() then canvas:hkClaim() return end
		end
		-- It did not show our page. Do not leave a window open that we opened.
		if not wasOpen and SettingsPanelShown() then HideSettingsPanel() end
	end
	ShowStandalone()
end

function Options:Close()
	if not panel then return end
	if standalone:IsShown() then standalone:Hide() end
	if canvas:IsVisible() and SettingsPanelShown() then HideSettingsPanel() end
end

function Options:Toggle()
	if self:IsShown() then
		self:Close()
	else
		self:Open()
	end
end

function Options:IsShown()
	return panel ~= nil and panel:IsVisible() and true or false
end
