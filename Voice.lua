--- Hark: Voice chat management
-- Handles joining/leaving voice channels and distance-based volume attenuation

Voice = {
	channelID = nil,
	streamID = nil,
	volumeUpdateTimer = nil,
}

local function Call(func, ...)
	-- Protected wrapper for voice API calls (Forever beta compatibility)
	local ok, result = pcall(func, ...)
	if not ok then
		Hark:Print("Voice API error: " .. tostring(result))
		return nil
	end
	return result
end

function Voice:Init()
	local frame = CreateFrame("Frame")
	frame:RegisterEvent("VOICE_CHANNEL_JOIN")
	frame:RegisterEvent("VOICE_CHANNEL_LEAVE")
	frame:RegisterEvent("VOICE_CHANNEL_ACTIVE_CHANGED")
	frame:RegisterEvent("VOICE_CHANNEL_MEMBER_JOINED")
	frame:RegisterEvent("VOICE_CHANNEL_MEMBER_LEFT")
	frame:RegisterEvent("VOICE_CHANNEL_MEMBER_UPDATED")
	frame:RegisterEvent("PLAYER_MOVING_START")
	frame:RegisterEvent("PLAYER_MOVING_STOP")

	frame:SetScript("OnEvent", function(self, event, ...)
		Voice:OnVoiceEvent(event, ...)
	end)

	self.frame = frame
end

--- Handle zone change: prompt to join proximity voice
function Voice:HandleZoneChange()
	if not Hark.enabled then return end
	if not Hark.db.joinOnZoneChange then return end

	local zoneName = GetZoneText()

	-- If we have a configured community, try to join it
	if Hark.db.communityId then
		Hark:Print("Entering " .. zoneName .. ". Joining proximity voice...")
		self:JoinCommunity(Hark.db.communityId, Hark.db.streamId or "")
	else
		Hark:Print("Entered " .. zoneName .. ". Type /hark setcommunity <id> to enable.")
	end
end

--- Join a community voice channel
function Voice:JoinCommunity(clubId, streamId)
	if not clubId or clubId == "" then
		Hark:Print("No community configured.")
		return
	end

	-- If already in this channel, do nothing
	if self.channelID == clubId then
		return
	end

	-- Leave old channel if any
	if self.channelID then
		Call(C_VoiceChat.LeaveChannel, self.channelID)
	end

	-- Join the new channel
	local ok = Call(C_VoiceChat.RequestJoinAndActivateCommunityStreamChannel, clubId, streamId)
	if ok then
		self.channelID = clubId
		self.streamID = streamId
		Hark:Print("Joined proximity voice.")
		self:ScheduleVolumeUpdates()
	else
		Hark:Print("Failed to join voice channel.")
	end
end

--- Leave the active voice channel
function Voice:Leave()
	if self.channelID then
		Call(C_VoiceChat.LeaveChannel, self.channelID)
		self.channelID = nil
		self.streamID = nil
		self:CancelVolumeUpdates()
		Hark:Print("Left proximity voice.")
	end
end

--- Schedule periodic volume updates (every 0.5 seconds while moving, 2 seconds idle)
function Voice:ScheduleVolumeUpdates()
	if self.volumeUpdateTimer then
		self.volumeUpdateTimer:Cancel()
	end

	local interval = IsMovingTime() and 0.5 or 2
	self.volumeUpdateTimer = C_Timer.After(interval, function()
		self:UpdateVolumes()
		self:ScheduleVolumeUpdates()
	end)
end

--- Cancel volume update loop
function Voice:CancelVolumeUpdates()
	if self.volumeUpdateTimer then
		self.volumeUpdateTimer:Cancel()
		self.volumeUpdateTimer = nil
	end
end

--- Update member volumes based on distance
function Voice:UpdateVolumes()
	if not Hark.enabled or not self.channelID then return end

	local channel = Call(C_VoiceChat.GetChannel, self.channelID)
	if not channel or not channel.members then return end

	local playerRange = Hark.db.fullVoiceRange
	local silentRange = Hark.db.silentRange
	local minVol = Hark.db.minVolume

	for _, member in ipairs(channel.members) do
		-- Skip self
		if member.name ~= UnitName("player") then
			-- Get distance from tracked positions
			local distance = Positions:GetDistance(member.name)

			-- Compute volume: full up close, fade to minVol, then silent beyond range
			local volume = 100
			if distance then
				if distance == math.huge then
					-- Different instance/layer/zone
					volume = 0
				elseif distance > silentRange then
					volume = 0
				elseif distance > playerRange then
					local fade = (silentRange - distance) / (silentRange - playerRange)
					volume = math.max(minVol, math.floor(100 * fade))
				end
			end

			-- Set volume: use PlayerLocation API with voice ID
			Call(C_VoiceChat.SetMemberVolume, PlayerLocation:CreateFromVoiceID(member.memberID, self.channelID), volume)
		end
	end
end

--- Get the active channel ID
function Voice:GetActiveChannelID()
	return self.channelID
end

--- Print current voice status
function Voice:PrintStatus()
	if self.channelID then
		local channel = Call(C_VoiceChat.GetChannel, self.channelID)
		local memberCount = channel and #channel.members or 0
		Hark:Print("Voice channel active. Members: " .. memberCount)
		if channel then
			for _, member in ipairs(channel.members) do
				local dist = Positions:GetDistance(member.name)
				local distStr = dist and (dist == math.huge and "∞" or string.format("%.0f yd", dist)) or "?"
				Hark:Print("  " .. member.name .. " - " .. distStr)
			end
		end
	else
		Hark:Print("Not in a voice channel.")
	end
end

--- Handle voice channel events
function Voice:OnVoiceEvent(event, ...)
	if event == "VOICE_CHANNEL_MEMBER_UPDATED" then
		-- Member moved or spoke; update volumes
		self:UpdateVolumes()
	elseif event == "VOICE_CHANNEL_MEMBER_JOINED" then
		self:UpdateVolumes()
	elseif event == "VOICE_CHANNEL_MEMBER_LEFT" then
		self:UpdateVolumes()
	elseif event == "VOICE_CHANNEL_JOIN" then
		self:ScheduleVolumeUpdates()
	elseif event == "VOICE_CHANNEL_LEAVE" then
		self:CancelVolumeUpdates()
	elseif event == "PLAYER_MOVING_START" or event == "PLAYER_MOVING_STOP" then
		-- Reschedule at different interval
		self:ScheduleVolumeUpdates()
	end
end
