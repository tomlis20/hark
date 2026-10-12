--- Adversarial review of UI.lua and Options.lua.
-- The mock does not lay frames out, so these tests find the addon's frames in
-- client.frames and patch the few geometry/tooltip getters a check needs.
local T = ...
local Sim = T.helpers

local UI_WIDTH = 248

local function uiFrame(c)
	local api = c.env
	for _, f in ipairs(c.frames) do
		if f._w == UI_WIDTH and f._parent == api.UIParent and f.body and f.header then return f end
	end
end

local function uiRows(c)
	local f = uiFrame(c)
	local out = {}
	for _, r in ipairs(c.frames) do
		if r._type == "Button" and r._parent == f.body and r._h == 16 then out[#out + 1] = r end
	end
	return out
end

-- Options frames: content (has the bottom Close button), standalone host
-- (has the X), Settings canvas host (has OnDefault). Works before and after
-- the host split: on the old build all three are the same frame.
local function optionFrames(c)
	local content, standalone, canvas
	for _, f in ipairs(c.frames) do
		if rawget(f, "hkCloseBottom") then content = f end
		if rawget(f, "hkClose") then standalone = f end
		if rawget(f, "OnDefault") then canvas = f end
	end
	return content, standalone, canvas
end

-- GameTooltip in the mock has no GetOwner/SetText bookkeeping; add it.
local function instrumentTooltip(c)
	local tip = c.env.GameTooltip
	tip.GetOwner = function(self) return self._owner end
	tip.IsOwned = function(self, f) return self._owner == f end
	tip.SetText = function(self, text) self._title = text; self._lines = {} end
	return tip
end

-- A fake Settings window that behaves like the real one for a canvas category:
-- reparents the registered frame into itself and shows it.
local function fakeSettings(c, opts)
	opts = opts or {}
	local api = c.env
	local sp = api.CreateFrame("Frame", nil, api.UIParent)
	sp:Hide()
	api.SettingsPanel = sp
	local function display(cat)
		sp:Show()
		if opts.wrongPage then return end
		local f = cat.frame
		f:SetParent(sp)
		f:ClearAllPoints()
		f:SetAllPoints()
		f:Show()
	end
	api.Settings.OpenToCategory = function(id)
		local cat
		for _, x in ipairs(c.optionsCategories) do
			if type(x) == "table" and (x.ID == id or x == id) then cat = x end
		end
		if not cat then return end
		if opts.deferred then
			api.C_Timer.After(0, function() display(cat) end)
		else
			display(cat)
		end
	end
	return sp
end

local function scenario(t)
	return Sim.Scenario(t, { players = {
		{ name = "Bob", x = 0, y = 0 },
		{ name = "Alice", x = 5, y = 0 },
		{ name = "Carol", x = 10, y = 0 },
	} })
end

---------------------------------------------------------------------------
-- UI.lua
---------------------------------------------------------------------------

T.test("ui review: a late settings backup re-applies panel position, lock and visibility", function(t)
	local w = t:world()
	w:CreateCommunity({ members = { "Bob" } })
	local c = w:AddPlayer({ name = "Bob" })
	w:Advance(1)
	local Hark = c:NS()
	local f = uiFrame(c)
	t:require(f ~= nil, "UI panel frame not found")
	t:eq(f:IsShown(), true, "shown by default")
	-- What Core's ApplySnapshot does: same table, new contents, then the event.
	local ui = Hark.db.ui
	for k in pairs(ui) do ui[k] = nil end
	ui.point, ui.relativePoint, ui.x, ui.y = "TOPRIGHT", "TOPRIGHT", -40, -60
	ui.locked, ui.shown = true, false
	Hark:Fire("SETTINGS_RESTORED", "macro")
	local p = f._points[1] or {}
	t:eq(p[1], "TOPRIGHT", "restored anchor point")
	t:eq(p[4], -40, "restored x")
	t:eq(f:IsShown(), false, "restored hidden state")
	ui.shown = true
	Hark:Fire("SETTINGS_RESTORED", "cvar")
	t:eq(f:IsShown(), true, "restored shown state")
end)

T.test("ui review: Show brings a panel saved off-screen back into view", function(t)
	local w = t:world()
	w:CreateCommunity({ members = { "Bob" } })
	local c = w:AddPlayer({ name = "Bob" })
	w:Advance(1)
	local Hark, api = c:NS(), c.env
	local f = uiFrame(c)
	t:require(f ~= nil, "UI panel frame not found")
	-- 1365 x 768 is UIParent at 1280x720 with the default UI scale.
	api.UIParent.GetWidth = function() return 1365 end
	api.UIParent.GetHeight = function() return 768 end
	api.UIParent.GetEffectiveScale = function() return 1 end
	f.GetEffectiveScale = function() return 1 end
	-- Saved under a 2560-wide layout: the panel's left edge is past the right side.
	f.GetPoint = function(self, i) local q = self._points[i or 1] or {} return q[1], q[2], q[3], q[4], q[5] end
	f.GetLeft = function() return 2200 end
	f.GetTop = function() return 500 end
	Hark.UI:Hide()
	Hark.UI:Show()
	local p = f._points[1] or {}
	t:eq(p[1], "TOPLEFT", "re-anchored by its top-left corner")
	t:between(p[4], 0, 1365 - UI_WIDTH, "x on screen")
	t:between(p[5], 26, 768, "header on screen")
	t:eq(Hark.db.ui.x, p[4], "the corrected position is saved")
end)

T.test("ui review: nonsense saved coordinates fall back to the default place", function(t)
	local w = t:world()
	w:CreateCommunity({ members = { "Bob" } })
	local c = w:AddPlayer({ name = "Bob" })
	w:Advance(1)
	local Hark = c:NS()
	local f = uiFrame(c)
	local ui = Hark.db.ui
	ui.point, ui.relativePoint, ui.x, ui.y = "LEFT", "LEFT", 1 / 0, 0 / 0
	Hark:Fire("SETTINGS_RESTORED", "cvar")
	local p = f._points[1] or {}
	t:eq(p[4], 24, "default x")
	t:eq(p[5], 120, "default y")
end)

T.test("ui review: Core's backup CVar writes do not redraw the panel", function(t)
	local w = scenario(t)
	local c = w:Get("Bob")
	local Voice = c:NS().Voice
	local calls = 0
	local orig = Voice.GetMembers
	Voice.GetMembers = function(...) calls = calls + 1 return orig(...) end
	c:FireEvent("CVAR_UPDATE", "HarkSave1", "x")
	c:FireEvent("CVAR_UPDATE", "HarkSave2", "y")
	t:eq(calls, 0, "redraws caused by unrelated CVar writes")
	c:FireEvent("CVAR_UPDATE", "nameplateShowFriends", "1")
	t:eq(calls, 1, "redraw for the nameplate CVar the hint depends on")
end)

T.test("ui review: no redraw work while the panel is hidden", function(t)
	local w = scenario(t)
	local c = w:Get("Bob")
	local Hark = c:NS()
	local calls = 0
	local orig = Hark.Voice.GetMembers
	Hark.Voice.GetMembers = function(...) calls = calls + 1 return orig(...) end
	w:Advance(5)
	t:ok(calls > 0, "redraws while shown")
	Hark.UI:Hide()
	calls = 0
	w:MoveTo("Alice", 30, 0, 7)
	w:Advance(10)
	t:eq(calls, 0, "GetMembers calls while hidden")
end)

T.test("ui review: redraws reuse rows and create no frames", function(t)
	local w = scenario(t)
	local c = w:Get("Bob")
	local before = #c.frames
	w:MoveTo("Alice", 30, 0, 7)
	w:Advance(15)
	c:NS().UI:Refresh()
	t:eq(#c.frames, before, "frames or textures created by redraws")
	local shown = 0
	for _, r in ipairs(uiRows(c)) do if r:IsShown() then shown = shown + 1 end end
	t:eq(shown, 2, "one row per member")
end)

T.test("ui review: the hovered row keeps its player and its tooltip matches it", function(t)
	local w = scenario(t)
	local c = w:Get("Bob")
	local tip = instrumentTooltip(c)
	local rows = uiRows(c)
	t:require(rows[1] and rows[1].member, "first row not filled")
	local first = rows[1].member.guid
	rows[1]._scripts.OnEnter(rows[1])
	t:eq(tip._owner, rows[1], "row owns the tooltip")
	local title = tip._title
	-- Alice walks away: the list would re-sort and put Carol in row 1.
	w:SetPosition("Alice", 30, 0)
	w:Advance(Sim.SETTLE)
	t:eq(rows[1].member.guid, first, "row under the cursor still shows the same player")
	t:eq(tip._title, title, "tooltip still names that player")
	t:ok(tip._title == rows[1].member.name, "tooltip matches the row a click acts on")
	-- After leaving, normal sorting resumes.
	rows[1]._scripts.OnLeave(rows[1])
	c:NS().UI:Refresh()
	t:ok(rows[1].member.guid ~= first, "list re-sorts once the cursor leaves")
	t:eq(tip:IsShown(), false, "tooltip hidden on leave")
end)

T.test("ui review: a row hidden while its tooltip shows takes the tooltip with it", function(t)
	local w = scenario(t)
	local c = w:Get("Bob")
	local tip = instrumentTooltip(c)
	local rows = uiRows(c)
	rows[2]._scripts.OnEnter(rows[2])
	t:require(tip:IsShown(), "tooltip shown")
	w:UserLeavesVoice("Carol")
	w:UserLeavesVoice("Alice")
	w:Advance(Sim.SETTLE)
	t:eq(rows[2]:IsShown(), false, "row hidden")
	t:eq(tip:IsShown(), false, "tooltip of the hidden row is gone")
end)

T.test("ui review: clicking a row cycles proximity, muted, always heard; right-click resets", function(t)
	local w = scenario(t)
	local c = w:Get("Bob")
	local Voice = c:NS().Voice
	local rows = uiRows(c)
	local row = rows[1]
	t:require(row.member, "row filled")
	local guid = row.member.guid
	row._scripts.OnEnter(row)
	local click = row._scripts.OnClick
	click(row, "LeftButton"); w:Advance(2)
	t:eq(Voice:GetOverride(guid), 0, "first click mutes")
	t:eq(row.member.guid, guid, "row still the same player after muting")
	click(row, "LeftButton"); w:Advance(2)
	t:eq(Voice:GetOverride(guid), 100, "second click: always heard")
	click(row, "LeftButton"); w:Advance(2)
	t:eq(Voice:GetOverride(guid), nil, "third click: back to proximity")
	click(row, "LeftButton"); w:Advance(2)
	click(row, "RightButton"); w:Advance(2)
	t:eq(Voice:GetOverride(guid), nil, "right-click from muted resets")
	Voice:SetOverride(guid, 40); w:Advance(2)
	click(row, "LeftButton"); w:Advance(2)
	t:eq(Voice:GetOverride(guid), nil, "a fixed override set elsewhere cycles to proximity")
	t:eq(w:Hears("Bob", row.member.name and row.member.name:match("^[^-]+") or "Alice"), 100, "audible again")
end)

---------------------------------------------------------------------------
-- Options.lua
---------------------------------------------------------------------------

local function plain(t)
	local w = t:world()
	w:CreateCommunity({ members = { "Bob" } })
	local c = w:AddPlayer({ name = "Bob" })
	w:Advance(1)
	return w, c
end

T.test("options review: fits a 1280x720 screen", function(t)
	local _, c = plain(t)
	c:NS().Options:Open()
	local content, standalone = optionFrames(c)
	t:require(content and standalone, "options frames not found")
	t:ok(standalone._w <= 1280, "width " .. tostring(standalone._w))
	t:ok(standalone._h <= 740, "height " .. tostring(standalone._h) .. " fits 768 with margin")
end)

T.test("options review: without a working Settings window the own window opens, once", function(t)
	local _, c = plain(t)
	local Options = c:NS().Options
	Options:Open()
	local content, standalone = optionFrames(c)
	t:eq(Options:IsShown(), true, "open")
	t:eq(content:IsVisible(), true, "controls visible")
	t:eq(standalone.hkClose:IsShown(), true, "close button in the own window")
	Options:Toggle()
	t:eq(Options:IsShown(), false, "toggle closes")
	Options:Toggle()
	t:eq(Options:IsShown(), true, "toggle reopens")
end)

T.test("options review: Settings showing the page a frame later leaves one window, without own chrome", function(t)
	local w, c = plain(t)
	local sp = fakeSettings(c, { deferred = true })
	local Options = c:NS().Options
	Options:Open()
	w:Advance(0.2)
	local content, standalone, canvas = optionFrames(c)
	t:eq(sp:IsShown(), true, "Settings window open")
	t:eq(content:IsVisible(), true, "controls visible")
	t:ok(content:GetParent() ~= c.env.UIParent, "controls are inside the Settings window")
	t:eq(standalone:IsVisible() and standalone ~= content and standalone ~= canvas, false, "own window not also open")
	t:eq(content.hkCloseBottom:IsShown(), false, "own Close button not shown inside Settings")
	if standalone == content then
		t:eq(standalone.hkClose:IsShown(), false, "own X not shown inside Settings")
	end
end)

T.test("options review: Settings opening on another page is closed again, own window used", function(t)
	local _, c = plain(t)
	local sp = fakeSettings(c, { wrongPage = true })
	local Options = c:NS().Options
	Options:Open()
	t:eq(sp:IsShown(), false, "Settings window we opened is not left open")
	t:eq(Options:IsShown(), true, "own window open")
end)

T.test("options review: Settings page, Escape, reopen, and combat fallback", function(t)
	local w, c = plain(t)
	local sp = fakeSettings(c)
	local Options = c:NS().Options
	Options:Open()
	local content = optionFrames(c)
	t:eq(sp:IsShown(), true, "opened in Settings")
	t:eq(content:GetParent() ~= c.env.UIParent, true, "inside Settings")
	t:eq(Options:IsShown(), true, "IsShown in Settings")
	sp:Hide() -- Escape
	t:eq(Options:IsShown(), false, "closed with the Settings window")
	Options:Toggle()
	t:eq(Options:IsShown(), true, "Toggle reopens")
	Options:Close()
	t:eq(sp:IsShown(), false, "Close closes the Settings window")
	w:SetCombat("Bob", true)
	Options:Open()
	t:eq(sp:IsShown(), false, "Settings not used in combat")
	t:eq(Options:IsShown(), true, "own window in combat")
	local _, standalone = optionFrames(c)
	t:eq(standalone.hkClose:IsVisible(), true, "close button usable")
	standalone.hkClose._scripts.OnClick(standalone.hkClose)
	t:eq(Options:IsShown(), false, "X closes it")
	w:SetCombat("Bob", false)
	Options:Open()
	t:eq(sp:IsShown(), true, "Settings used again after combat")
	t:eq(content.hkCloseBottom:IsShown(), false, "own Close button hidden in Settings")
end)

T.test("options review: a hidden Hark panel can be shown again from options", function(t)
	local _, c = plain(t)
	local Hark = c:NS()
	Hark.UI:Hide()
	Hark.Options:Open()
	local check
	for _, f in ipairs(c.frames) do
		if f._type == "CheckButton" and f.hkLabel and f.hkLabel._text == "Show the Hark panel" then check = f end
	end
	t:require(check, "panel checkbox not found")
	t:eq(check:GetChecked(), false, "reflects the hidden panel")
	check:SetChecked(true)
	check:Click()
	t:eq(Hark.UI:IsShown(), true, "panel shown again")
	t:eq(Hark.db.ui.shown, true, "and remembered")
end)

T.test("options review: settings changed elsewhere update the open panel", function(t)
	local _, c = plain(t)
	local Hark = c:NS()
	Hark.Options:Open()
	Hark:Set("fullVoiceRange", 60) -- raises silentRange via the cross-field rule
	local found = 0
	for _, f in ipairs(c.frames) do
		if f._type == "Slider" then
			if f._value == Hark:Get("fullVoiceRange") or f._value == Hark:Get("silentRange") then found = found + 1 end
		end
	end
	t:ok(found >= 2, "both range sliders show the new values")
end)

T.test("options review: Escape (UISpecialFrames hiding HarkOptionsFrame) closes the own window cleanly", function(t)
	local w, c = plain(t)
	local Options = c:NS().Options
	local named = c:Global("HarkOptionsFrame")
	t:require(type(named) == "table" and named._type, "HarkOptionsFrame is a frame")
	local _, standalone, canvas = optionFrames(c)
	t:eq(named, standalone, "the named frame is Hark's own window")
	t:ok(named ~= canvas, "the Settings canvas is not named")
	Options:Open()
	t:eq(Options:IsShown(), true, "open")
	named:Hide() -- what CloseSpecialWindows does on Escape
	t:eq(Options:IsShown(), false, "closed by Escape")
	Options:Open()
	t:eq(Options:IsShown(), true, "reopens after Escape")
	-- Escape while Settings hosts the page is the Settings window's job.
	local sp = fakeSettings(c)
	Options:Close()
	Options:Open()
	t:eq(sp:IsShown(), true, "Settings hosts the page")
	t:eq(named:IsShown(), false, "own window not shown alongside Settings")
end)
