--- Deterministic game clock.
--
-- Time only moves when a test calls Advance(). Advancing walks forward in
-- fixed "frames" (default 50 ms, i.e. 20 fps). On each frame, every scheduled
-- callback whose due time has arrived runs, in (due time, scheduling order)
-- order, then the per-frame hooks run (OnUpdate scripts, movement).
--
-- Faithful to the client in the ways that matter for addons:
--   * A callback is never run in the same pass that scheduled it, so
--     C_Timer.After(0, f) runs on the next frame, as in game.
--   * Timer resolution is one frame: a 0.01 s timer fires on the next frame.
-- Differences: real frame times jitter; here they are exact.

local Clock = {}
Clock.__index = Clock

function Clock.new(start, frameStep)
	return setmetatable({
		now = start or 1000,
		frameStep = frameStep or 0.05,
		seq = 0,
		queue = {},
		frameHooks = {},
		frames = 0,
	}, Clock)
end

--- Schedule fn after delay seconds. runner(fn) is used to invoke it (lets the
-- caller wrap it in the owning client's error handler). Returns the entry; set
-- entry.cancelled = true to cancel.
function Clock:Schedule(delay, fn, runner)
	delay = tonumber(delay) or 0
	if delay < 0 then delay = 0 end
	self.seq = self.seq + 1
	local e = { due = self.now + delay, seq = self.seq, fn = fn, runner = runner }
	self.queue[#self.queue + 1] = e
	return e
end

function Clock:AddFrameHook(fn)
	self.frameHooks[#self.frameHooks + 1] = fn
end

function Clock:Pending()
	local n = 0
	for _, e in ipairs(self.queue) do
		if not e.cancelled then n = n + 1 end
	end
	return n
end

local function byDue(a, b)
	if a.due ~= b.due then return a.due < b.due end
	return a.seq < b.seq
end

function Clock:RunDue()
	local horizon = self.seq
	local due, keep = {}, {}
	for _, e in ipairs(self.queue) do
		if e.cancelled then
			-- drop
		elseif e.due <= self.now + 1e-9 and e.seq <= horizon then
			due[#due + 1] = e
		else
			keep[#keep + 1] = e
		end
	end
	self.queue = keep
	table.sort(due, byDue)
	for _, e in ipairs(due) do
		if not e.cancelled then
			e.fired = true
			if e.runner then e.runner(e.fn) else e.fn() end
		end
	end
end

function Clock:Frame(elapsed)
	self.frames = self.frames + 1
	self:RunDue()
	for _, hook in ipairs(self.frameHooks) do
		hook(elapsed)
	end
end

--- Advance time by dt seconds, frame by frame.
function Clock:Advance(dt)
	local target = self.now + dt
	while self.now < target - 1e-9 do
		local step = math.min(self.frameStep, target - self.now)
		self.now = self.now + step
		self:Frame(step)
	end
end

return Clock
