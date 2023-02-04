local hex = {"0","1","2","3","4","5","6","7","8","9","a","b","c","d","e","f"}

Decoder = {}

local typeImage = 1
local typeVideo = 2
local typeVideoNoAudio = 3
local typeAudio = 4

local frameRate = 20
local dataRate = 48000 / 8
local startDelay = 1.25 * dataRate

function Decoder.new(monitors, file, driveA, driveB)
	local self = {monitors = monitors, file = file, frame = 0, driveA = driveA,
		driveB = driveB, writingDrive = driveA, playingDrive = driveA,
		audioBuffer = {}, transDuration = 3, transitionBuffer = {}}
	local magic = string.char(file.read()) .. string.char(file.read()) .. string.char(file.read())
	if magic ~= "JUF" then
		error("juroku: not a valid JUF file")
	end

	local version = file.read()
	if version ~= 1 then
		error("juroku: JUF file version " .. version .. " not supported")
	end

	self.type = file.read()

	if self.type ~= typeImage and self.type ~= typeVideo then
		error("juroku: this decoder does not support this JUF media type")
	end

	if self.type == typeVideo and ((not driveA) or (not driveB)) then
		error("juroku: two tape drives as arguments required for audio output")
	end

	local numMonitors = file.read()
	if numMonitors ~= #monitors then
		error("juroku: file requires " .. numMonitors ..
			" monitors, but only " .. #monitors .. " given")
	end

	setmetatable(self, {__index = Decoder})
	return self
end

function Decoder:hasAudio()
	return self.type == typeVideo or self.type == typeAudio
end

function Decoder:parseAudio(shouldBuffer)
	local f = self.file
	local size = f.read() * 0x1000000 + f.read() * 0x10000 + f.read() * 0x100 + f.read()

	if self.writingDrive == nil then
		-- if shouldBuffer then
			for i = 1, size do
		-- 		local result = f.read()
		-- 		table.insert(self.audioBuffer, result)
				table.insert(self.transitionBuffer, f.read())
			end
		-- else
		-- 	for i = 1, size do
		-- 		local result = f.read()
		-- 		table.insert(self.audioBuffer, result)
		-- 	end
		-- end
		return
	end

	-- if #self.audioBuffer > 0 then
	-- 	for i = 1, #self.audioBuffer do
	-- 		self.writingDrive.write(self.audioBuffer[i])
	-- 	end
	-- 	self.audioBuffer = {}
	-- end

	if shouldBuffer then
		for i = 1, size do
			local result = f.read()
			table.insert(self.transitionBuffer, result)
			self.writingDrive.write(result)

			if i % (60 * dataRate) == 0 then
				os.queueEvent("juroku_audio_yield")
				coroutine.yield()
			end
		end
	else
		for i = 1, size do
			self.writingDrive.write(f.read())

			if i % (60 * dataRate) == 0 then
				os.queueEvent("juroku_audio_yield")
				coroutine.yield()
			end
		end
	end
end

function Decoder:drawFrame(frame, shouldBuffer)
	local f = self.file

	if frame < 0 then
		return true
	end

	for i = self.frame, frame - 1 do
		for m = 1, #self.monitors do
			local first = f.read()
			if first == nil then
				return false
			end

			local width = first * 0x100 + f.read()
			local height = f.read() * 0x100 + f.read()

			for i = 1, height * width do
				f.read()
				f.read()
			end

			for i = 1, 16 do
				f.read()
				f.read()
				f.read()
			end
		end

		if self:hasAudio() then
			self:parseAudio(shouldBuffer)
		end
	end

	for m, t in pairs(self.monitors) do
		local first = f.read()
		if first == nil then
			return false
		end

		local width = first * 0x100 + f.read()
		local height = f.read() * 0x100 + f.read()
		local x, y = t.getCursorPos()
		local rows = {}

		for row = 1, height do
			local fg = ""
			local bg = ""
			local txt = ""
			for col = 1, width do
				local color = f.read()
				fg = fg .. hex[math.floor(color / 0x10) + 1]
				bg = bg .. hex[bit.band(color, 0xF) + 1]
				txt = txt .. string.char(f.read())
			end

			table.insert(rows, {fg, bg, txt})
		end

		for row = 1, height do
			t.setCursorPos(x, y + row - 1)
			t.blit(rows[row][3], rows[row][1], rows[row][2])
		end

		for i = 1, 16 do
			t.setPaletteColor(2^(i-1), f.read() * 0x10000 + f.read() * 0x100 + f.read())
		end

		t.setCursorPos(x, y)
	end

	if self:hasAudio() then
		self:parseAudio(shouldBuffer)
	end

	return true
end

function Decoder:writeTransitionBuffer()
	if #self.transitionBuffer < startDelay then
		return
	end

	for i = #self.transitionBuffer - startDelay + 1, #self.transitionBuffer do
		self.writingDrive.write(self.transitionBuffer[i])
	end

	self.transitionBuffer = {}
end

function Decoder:playVideo()
	self.driveA.setSpeed(1)
	self.driveB.setSpeed(1)
	self.driveA.stop()
	self.driveB.stop()
	self.driveA.seek(-self.driveA.getSize())
	self.driveB.seek(-self.driveB.getSize())
	self:parseAudio(true)
	for i = 1, 3000 do
		self.driveA.write(0xAA)
	end
	self.driveA.seek(-self.driveA.getSize())

	local bufferLength = #self.transitionBuffer * dataRate
	local tapeEndThreshold = #self.transitionBuffer - startDelay
	local tapeEndCanary = #self.transitionBuffer - (startDelay * 2)
	sleep(0)

	self.writingDrive = self.driveB
	self:writeTransitionBuffer()

	self.playingDrive.play()
	local tapeOffset = -startDelay
	local currentFrame = -1
	local nextPlaying = nil
	local endTransition = 0
	local lastPos = -1
	local targetFrame = -1
	local nextOffset = 0
	local interpolatePos = 0

	while true do
		local playPos = self.playingDrive.getPosition()

		local totalSamples = tapeOffset + playPos

		if playPos ~= lastPos then
			targetFrame = math.floor((totalSamples / dataRate) * frameRate + 0.5)
			interpolatePos = playPos
			print(tapeOffset .. " + " .. playPos .. " = " .. totalSamples .. " | frame: " .. targetFrame)
			lastPos = playPos
		else
			targetFrame = targetFrame + 1
			interpolatePos = interpolatePos + (dataRate / 20)
		end

		if not self:drawFrame(targetFrame - currentFrame - 1, false) then
			self.playingDrive.stop()
			return
		end

		if targetFrame > currentFrame then
			currentFrame = targetFrame
		end

		if interpolatePos >= tapeEndThreshold then
			if nextPlaying == nil and self.writingDrive.getPosition() > startDelay then
				-- Write 0.5 seconds of silence
				for i = 1, 3000 do
					self.writingDrive.write(0xAA)
				end

				nextPlaying = self.writingDrive
				self.writingDrive = nil
				nextPlaying.seek(-nextPlaying.getSize())
				nextPlaying.play()
				print("playing transition")
				endTransition = tapeEndThreshold + startDelay
				nextOffset = interpolatePos
			elseif nextPlaying ~= nil and interpolatePos >= endTransition then
				print("transitioning...")
				self.playingDrive.stop()
				self.playingDrive.seek(-self.playingDrive.getSize())
				self.writingDrive = self.playingDrive
				self:writeTransitionBuffer()
				self.playingDrive = nextPlaying
				print("done!")
				endTransition = 0
				nextPlaying = nil
				tapeOffset = tapeOffset + nextOffset
				playPos = self.playingDrive.getPosition()
			end
		end

		sleep(0)
	end
end

function Decoder:render()
	if self.type == typeImage then
		drawFrame(0)
		return
	elseif self.type == typeVideo then
		self:playVideo()
	end
end
