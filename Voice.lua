--- Hark: Voice chat management
-- Handles joining/leaving voice channels and distance-based volume attenuation

Voice = {
	channelID = nil,
	streamID = nil,
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

	frame:SetScript("OnEvent", function(self, event, ...)
		Voice:OnVoiceEvent(event, ...)
	end)

	self.frame = frame

	-- Try to join on load if in a zone with a community
	C_Timer.After(1, function()
		Voice:HandleZoneChange()
	end)
end

--- Handle zone change: prompt to join proximity voice
function Voice:HandleZoneChange()
	if not Hark.enabled then return end

	local zoneName = GetZoneText()
	Hark:Print("Entered " .. zoneName .. ". Type /hark to join proximity voice.")
end

--- Join a community voice channel
function Voice:JoinCommunity(clubId, streamId)
	if not clubId then
		Hark:Print("No community configured. Type /hark options to set one.")
		return
	end

	local ok = Call(C_VoiceChat.RequestJoinAndActivateCommunityStreamChannel, clubId, streamId)
	if ok then
		self.channelID = clubId
		self.streamID = streamId
		Hark:Print("Joining proximity voice...")
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
		Hark:Print("Left proximity voice.")
	end
end

--- Update member volumes based on distance
function Voice:UpdateVolumes()
	if not self.channelID then return end

	local channel = Call(C_VoiceChat.GetChannel, self.channelID)
	if not channel or not channel.members then return end

	local playerRange = Hark.db.fullVoiceRange
	local silentRange = Hark.db.silentRange
	local minVol = Hark.db.minVolume

	for _, member in ipairs(channel.members) do
		local memberGUID = Call(C_VoiceChat.GetMemberGUID, member.memberID, self.channelID)
		if memberGUID then
			-- Try to get position from the GUID or unit
			local distance = Positions:GetDistance(memberGUID)

			-- Compute volume: full up close, fade to minVol, then silent beyond range
			local volume = 100
			if distance and distance ~= math.huge then
				if distance > silentRange then
					volume = 0
				elseif distance > playerRange then
					local fade = (silentRange - distance) / (silentRange - playerRange)
					volume = math.max(minVol, math.floor(100 * fade))
				end
			end

			Call(C_VoiceChat.SetMemberVolume, member.memberID, self.channelID, volume)
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
		Hark:Print("Voice channel active: " .. tostring(self.channelID))
	else
		Hark:Print("Not in a voice channel.")
	end
end

--- Handle voice channel events
function Voice:OnVoiceEvent(event, ...)
	if event == "VOICE_CHANNEL_MEMBER_UPDATED" then
		-- Member moved or spoke; update all volumes
		Voice:UpdateVolumes()
	elseif event == "VOICE_CHANNEL_MEMBER_JOINED" then
		Hark:Print("Player entered voice range.")
		Voice:UpdateVolumes()
	elseif event == "VOICE_CHANNEL_MEMBER_LEFT" then
		Hark:Print("Player left voice range.")
		Voice:UpdateVolumes()
	end
end
