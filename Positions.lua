--- Hark: Position tracking and sharing
-- Tracks character positions and broadcasts them to group/guild

Positions = {
	data = {},           -- { [unit] = { x, y, instance, time, dead } }
	lastSent = {},       -- { instance, x, y, time }
	PREFIX = "Hark",
}

local SEND_MOVED = 2      -- seconds between updates while moving
local SEND_IDLE = 15      -- seconds between updates while idle
local MOVE_THRESHOLD = 2  -- yards to trigger "moved" state
local STALE_AFTER = 45    -- seconds to discard stale positions

function Positions:Init()
	C_ChatInfo.RegisterAddonMessagePrefix(self.PREFIX)

	local frame = CreateFrame("Frame")
	frame:RegisterEvent("PLAYER_MOVING_START")
	frame:RegisterEvent("PLAYER_MOVING_STOP")
	frame:RegisterEvent("PLAYER_REGEN_ENABLED")
	frame:RegisterEvent("PLAYER_REGEN_DISABLED")
	frame:RegisterEvent("CHAT_MSG_ADDON")
	frame:RegisterEvent("GROUP_ROSTER_UPDATE")

	frame:SetScript("OnEvent", function(self, event, ...)
		if event == "CHAT_MSG_ADDON" then
			Positions:OnAddonMessage(...)
		else
			Positions:ScheduleBroadcast()
		end
	end)

	self.frame = frame
	self:ScheduleBroadcast()
end

--- Schedule the next position broadcast
function Positions:ScheduleBroadcast()
	if self.broadcastTimer then
		self.broadcastTimer:Cancel()
	end

	local x, y, instance = UnitPosition("player")
	if not x then return end

	-- Check if we moved significantly
	local moved = instance ~= self.lastSent.instance or
		(x and self.lastSent.x and
		 ((x - self.lastSent.x) ^ 2 + (y - self.lastSent.y) ^ 2) > MOVE_THRESHOLD ^ 2)

	local interval = moved and SEND_MOVED or SEND_IDLE

	self.broadcastTimer = C_Timer.After(interval, function()
		self:Broadcast()
		self:ScheduleBroadcast()
	end)
end

--- Broadcast current position to group/guild
function Positions:Broadcast()
	if not Hark.enabled then return end

	local x, y, instance = UnitPosition("player")
	if not x then return end

	local dead = UnitIsDeadOrGhost("player") and "d" or ""
	local msg = string.format("P:%d:%d:%d%s", instance, math.floor(x), math.floor(y), dead)

	-- Send to guild if in one
	if IsInGuild() then
		C_ChatInfo.SendAddonMessage(self.PREFIX, msg, "GUILD")
	end

	-- Send to group if in one
	if IsInGroup() then
		local groupType = GetInstanceType() == "none" and "PARTY" or "INSTANCE_CHAT"
		C_ChatInfo.SendAddonMessage(self.PREFIX, msg, groupType)
	end

	self.lastSent = { instance = instance, x = x, y = y, time = GetTime() }
end

--- Handle incoming position message
function Positions:OnAddonMessage(prefix, msg, channel, sender)
	if prefix ~= self.PREFIX or sender == UnitName("player") then return end

	-- Parse: P:instance:x:y[d]
	local instance, x, y, dead = msg:match("^P:(%d+):(%d+):(%d+)(d?)$")
	if not instance then return end

	instance, x, y = tonumber(instance), tonumber(x), tonumber(y)

	self.data[sender] = {
		x = x,
		y = y,
		instance = instance,
		time = GetTime(),
		dead = dead == "d",
	}
end

--- Get distance from player to a given unit/sender
function Positions:GetDistance(unitOrName)
	local playerX, playerY, playerInstance = UnitPosition("player")
	if not playerX then return nil end

	-- If it's a unit token, try to get its position
	if unitOrName:match("^%a+%d*$") then
		local x, y, instance = UnitPosition(unitOrName)
		if x and instance == playerInstance then
			return math.sqrt((x - playerX) ^ 2 + (y - playerY) ^ 2)
		end
		return math.huge
	end

	-- Otherwise, look up in our data store
	local pos = self.data[unitOrName]
	if not pos then return nil end

	-- Check if stale
	if GetTime() - pos.time > STALE_AFTER then
		self.data[unitOrName] = nil
		return nil
	end

	-- Check if in different instance/zone
	if pos.instance ~= playerInstance then
		return math.huge
	end

	return math.sqrt((pos.x - playerX) ^ 2 + (pos.y - playerY) ^ 2)
end

--- Count tracked positions
function Positions:Count()
	local n = 0
	for _ in pairs(self.data) do
		n = n + 1
	end
	return n
end
