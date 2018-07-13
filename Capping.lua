
local addonName, mod = ...
local frame = CreateFrame("Frame", "CappingFrame", UIParent)
local L = mod.L

local activeBars = { }
frame.bars = activeBars

-- LIBRARIES
local candy = LibStub("LibCandyBar-3.0")
local media = LibStub("LibSharedMedia-3.0")

do
	frame:SetPoint("CENTER", UIParent, "CENTER")
	frame:SetWidth(180)
	frame:SetHeight(15)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetClampedToScreen(true)
	frame:Show()
	frame:SetScript("OnDragStart", function(f) f:StartMoving() end)
	frame:SetScript("OnDragStop", function(f) f:StopMovingOrSizing() end)
	local function openOpts()
		LoadAddOn("Capping_Options")
		LibStub("AceConfigDialog-3.0"):Open(addonName)
	end
	SlashCmdList.Capping = openOpts
	SLASH_Capping1 = "/capping"
	frame:SetScript("OnMouseUp", function(_, btn)
		if btn == "RightButton" then
			openOpts()
		end
	end)
end

local format, type = format, type
local db

-- Event Handlers
local elist = {}
frame:SetScript("OnEvent", function(_, event, ...)
	mod[elist[event] or event](mod, ...)
end)
function mod:RegisterTempEvent(event, other)
	frame:RegisterEvent(event)
	elist[event] = other or event
end
function mod:RegisterEvent(event)
	frame:RegisterEvent(event)
end
function mod:UnregisterEvent(event)
	frame:UnregisterEvent(event)
end

function mod:START_TIMER(timerType, timeSeconds, totalTime)
	local _, t = GetInstanceInfo()
	if t == "pvp" or t == "arena" then
		--if db.hideblizztime then
		--	for a, timer in pairs(TimerTracker.timerList) do
		--		timer:Hide()
		--	end
		--end
		local faction = GetPlayerFactionGroup()
		if faction and faction ~= "Neutral" then
			local bar = self:GetBar(L["Battle Begins"])
			if not bar or timeSeconds > bar.remaining+3 or timeSeconds < bar.remaining-3 then -- Don't restart bars for subtle changes +/- 3s
				-- 516953 = Interface/Timer/Horde-Logo || 516949 = Interface/Timer/Alliance-Logo
				mod:StartBar(L["Battle Begins"], timeSeconds, faction == "Horde" and 516953 or 516949, "colorOther")
			end
		end
	end
end

function mod:PLAYER_LOGIN()
	-- saved variables database setup
	if type(CappingSettingsTmp) ~= "table" then
		CappingSettingsTmp = {
			lock = false,
			fontSize = 10,
			barTexture = "Blizzard Raid Bar",
			outline = "NONE",
			font = media:GetDefault("font"),
			width = 200,
			height = 20,
			icon = true,
			timeText = true,
			spacing = 0,
			alignText = "LEFT",
			alignTime = "RIGHT",
			alignIcon = "LEFT",
			colorText = {1,1,1,1},
			colorAlliance = {0,0,1,1},
			colorHorde = {1,0,0,1},
			colorQueue = {0.6,0.6,0.6,1},
			colorOther = {1,1,0,1},
			colorBarBackground = {0,0,0,0.75},
		}
	end
	db = CappingSettingsTmp2
	CappingFrame.db = db

	local bg = frame:CreateTexture(nil, "PARENT")
	bg:SetAllPoints(frame)
	bg:SetColorTexture(0, 1, 0, 0.3)
	frame.bg = bg
	local header = frame:CreateFontString(nil, "OVERLAY", "TextStatusBarText")
	header:SetAllPoints(frame)
	header:SetText(addonName)
	frame.header = header

	if db.lock then
		frame:EnableMouse(false)
		frame.bg:Hide()
		frame.header:Hide()
	end

	self:RegisterEvent("ZONE_CHANGED_NEW_AREA")
	self:RegisterEvent("UPDATE_BATTLEFIELD_STATUS")
	self:RegisterEvent("START_TIMER")
	self:ZONE_CHANGED_NEW_AREA()
end
mod:RegisterEvent("PLAYER_LOGIN")

do
	local zoneIds = {}
	function mod:AddBG(id, func)
		zoneIds[id] = func
	end

	local wasInBG = false
	local GetBestMapForUnit = C_Map and C_Map.GetBestMapForUnit -- XXX 8.0
	function mod:ZONE_CHANGED_NEW_AREA()
		if wasInBG then
			wasInBG = false
			for event in pairs(elist) do -- unregister all temp events
				elist[event] = nil
				self:UnregisterEvent(event)
			end
			for bar in next, activeBars do -- close all temp timerbars
				local separate = bar:Get("capping:separate")
				if not separate then
					bar:Stop()
				end
			end
		end

		local _, zoneType, _, _, _, _, _, id = GetInstanceInfo()
		if zoneType == "pvp" then
			local func = zoneIds[id]
			if func then
				wasInBG = true
				func(self)
			end
		elseif zoneType == "arena" then
			local func = zoneIds[id]
			if func then
				wasInBG = true
				func(self)
			else
				print(format("Capping found a new id '%d' at '%s' tell us on GitHub.", id, GetRealZoneText(id)))
			end
		else
			local id
			if GetPlayerMapAreaID then -- XXX 8.0
				id = -(GetPlayerMapAreaID("player") or 0)
			else
				id = -(GetBestMapForUnit("player"))
			end
			local func = zoneIds[id]
			if func then
				wasInBG = true
				func(self)
			end
		end
	end
end

do -- estimated wait timer and port timer
	local GetBattlefieldStatus = GetBattlefieldStatus
	local GetBattlefieldPortExpiration = GetBattlefieldPortExpiration
	local GetBattlefieldEstimatedWaitTime, GetBattlefieldTimeWaited = GetBattlefieldEstimatedWaitTime, GetBattlefieldTimeWaited
	local ARENA = ARENA

	local function cleanupQueue()
		for bar in next, activeBars do
			-- If we joined two queues, join and finish the first BG, zone out and they shuffle upwards so queue 2 becomes queue 1.
			-- We check every running bar to cancel any that might have changed to a different queue slot and left the bar in the previous slot running.
			-- This is only an issue for casual arenas where we change the name to be unique. The "Arena 2" bar will start an "Arena 1" bar, leaving behind the previous.
			-- This isn't an issue anywhere else as they all have unique names (e.g. Warsong Gultch) that we don't modify.
			-- If a WSG bar went from queue 2 to queue 1 another bar wouldn't spawn, we just update the queue id of the bar.
			--
			-- This messyness is purely down to Blizzard calling both casual arenas the same name... which would screw with our bars if we were queued for both at the same time.
			local id = bar:Get("capping:queueid")
			if id and GetBattlefieldStatus(id) == "none" then
				bar:Stop()
			end
		end
	end

	function mod:UPDATE_BATTLEFIELD_STATUS(queueId)
		--if not db.port and not db.wait then return end

		local status, map, _, _, _, size = GetBattlefieldStatus(queueId)
		if size == "ARENASKIRMISH" then
			map = format("%s (%d)", ARENA, queueId) -- No size or name distinction given for casual arena 2v2/3v3, separate them manually. Messy :(
		end

		if status == "confirm" then -- BG has popped, time until cancelled
			local bar = self:GetBar(map)
			if bar and bar:Get("capping:colorid") == "colorQueue" then
				self:StopBar(map)
				bar = nil
			end

			if not bar then --and db.port then
				bar = self:StartBar(map, GetBattlefieldPortExpiration(queueId), 132327, "colorOther", true) -- 132327 = Interface/Icons/Ability_TownWatch
				bar:Set("capping:queueid", queueId)
			end
		elseif status == "queued" then --and db.wait then -- Waiting for BG to pop
			if size == "ARENASKIRMISH" then
				cleanupQueue()
			end

			local esttime = GetBattlefieldEstimatedWaitTime(queueId) / 1000 -- 0 when queue is paused
			local waited = GetBattlefieldTimeWaited(queueId) / 1000
			local estremain = esttime - waited
			local bar = self:GetBar(map)
			if bar and bar:Get("capping:queueid") ~= queueId then
				bar:Set("capping:queueid", queueId) -- The queues shuffle upwards after finishing a BG, update
			end

			if estremain > 1 then -- Not a paused queue (0) and not a negative queue (in queue longer than estimated time).
				if not bar or estremain > bar.remaining+10 or estremain < bar.remaining-10 then -- Don't restart bars for subtle changes +/- 10s
					local icon
					for i = 1, GetNumBattlegroundTypes() do
						local name,_,_,_,_,_,_,_,_,bgIcon = GetBattlegroundInfo(i)
						if name == map then
							icon = bgIcon
							break
						end
					end
					bar = self:StartBar(map, estremain, icon or 134400, "colorQueue", true) -- Question mark icon for random battleground (134400) Interface/Icons/INV_Misc_QuestionMark
					bar:Set("capping:queueid", queueId)
				end
			else -- Negative queue (in queue longer than estimated time) or 0 queue (paused)
				if not bar or bar.remaining ~= 1 then
					local icon
					for i = 1, GetNumBattlegroundTypes() do
						local name,_,_,_,_,_,_,_,_,bgIcon = GetBattlegroundInfo(i)
						if name == map then
							icon = bgIcon
							break
						end
					end
					bar = self:StartBar(map, 1, icon or 134400, "colorQueue", true) -- Question mark icon for random battleground (134400) Interface/Icons/INV_Misc_QuestionMark
					bar:Pause()
					bar.remaining = 1
					bar:SetTimeVisibility(false)
					bar:Set("capping:queueid", queueId)
				end
			end
		elseif status == "active" then -- Inside BG
			-- We can't directly call :StopBar(map) as it doesn't work for random BGs.
			-- A random BG will adopt the zone name when it changes to "active" E.g. Random Battleground > Arathi Basin
			for bar in next, activeBars do
				local id = bar:Get("capping:queueid")
				if id == queueId then
					bar:Stop()
					break
				end
			end
		elseif status == "none" then -- Leaving queue
			cleanupQueue()
		end
	end
end

function mod:Test()
	-- 236396 = Interface/Icons/Achievement_BG_winWSG
	mod:StartBar(L["Test"].." - ".._G.OTHER.."1", 100, 236396, "colorQueue")
	mod:StartBar(L["Test"].." - ".._G.OTHER.."2", 75, 236396, "colorOther")
	mod:StartBar(L["Test"].." - ".._G.FACTION_ALLIANCE, 45, 236396, "colorAlliance")
	mod:StartBar(L["Test"].." - ".._G.FACTION_HORDE, 100, 236396, "colorHorde")
	mod:StartBar(L["Test"], 75, 236396, "colorOther")
end
frame.Test = mod.Test

do
	local BarOnClick
	do
		local function ReportBar(bar, channel)
			if not activeBars[bar] then return end
			local colorid = bar:Get("capping:colorid")
			local faction = colorid == "colorHorde" and _G.FACTION_HORDE or colorid == "colorAlliance" and _G.FACTION_ALLIANCE or ""
			local timeLeft = bar.candyBarDuration:GetText()
			if not timeLeft:find("[:%.]") then timeLeft = "0:"..timeLeft end
			SendChatMessage(format("Capping: %s - %s %s", bar:GetLabel(), timeLeft, faction == "" and faction or "("..faction..")"), channel)
		end
		function BarOnClick(bar)
			if IsShiftKeyDown() then
				ReportBar(bar, "SAY")
			elseif IsControlKeyDown() then
				ReportBar(bar, IsInGroup(2) and "INSTANCE_CHAT" or "RAID") -- LE_PARTY_CATEGORY_INSTANCE = 2
			end
		end
	end

	local RearrangeBars
	do
		-- Ripped from BigWigs bar sorter
		local function barSorter(a, b)
			local idA = a:Get("capping:priority")
			local idB = b:Get("capping:priority")
			if idA and not idB then
				return true
			elseif idB and not idA then
				return
			else
				return a.remaining < b.remaining
			end
		end
		local tmp = {}
		RearrangeBars = function()
			wipe(tmp)
			for bar in next, activeBars do
				tmp[#tmp + 1] = bar
			end
			table.sort(tmp, barSorter)
			local lastBar = nil
			local up = db.growUp
			for i = 1, #tmp do
				local bar = tmp[i]
				local spacing = db.spacing
				bar:ClearAllPoints()
				if up then
					if lastBar then -- Growing from a bar
						bar:SetPoint("BOTTOMLEFT", lastBar, "TOPLEFT", 0, spacing)
						bar:SetPoint("BOTTOMRIGHT", lastBar, "TOPRIGHT", 0, spacing)
					else -- Growing from the anchor
						bar:SetPoint("BOTTOM", frame, "TOP")
					end
					lastBar = bar
				else
					if lastBar then -- Growing from a bar
						bar:SetPoint("TOPLEFT", lastBar, "BOTTOMLEFT", 0, -spacing)
						bar:SetPoint("TOPRIGHT", lastBar, "BOTTOMRIGHT", 0, -spacing)
					else -- Growing from the anchor
						bar:SetPoint("TOP", frame, "BOTTOM")
					end
					lastBar = bar
				end
			end
		end
		frame.RearrangeBars = RearrangeBars
	end

	function mod:StartBar(name, remaining, icon, colorid, priority)
		self:StopBar(name)
		local bar = candy:New(media:Fetch("statusbar", db.texture), db.width, db.height)
		activeBars[bar] = true

		bar:Set("capping:colorid", colorid)
		if priority then
			bar:Set("capping:priority", priority)
		end

		bar:SetParent(frame)
		bar:SetLabel(name)
		bar.candyBarLabel:SetJustifyH(db.alignText)
		bar.candyBarDuration:SetJustifyH(db.alignTime)
		bar:SetDuration(remaining)
		bar:SetColor(unpack(db[colorid]))
		bar.candyBarBackground:SetVertexColor(unpack(db.colorBarBackground))
		bar:SetTextColor(unpack(db.colorText))
		if db.icon then
			if type(icon) == "table" then
				bar:SetIcon(icon[1], icon[2], icon[3], icon[4], icon[5])
			else
				bar:SetIcon(icon)
			end
			bar:SetIconPosition(db.alignIcon)
		end
		bar:SetTimeVisibility(db.timeText)
		bar:SetFill(db.fill)
		local flags = nil
		if db.monochrome and db.outline ~= "NONE" then
			flags = "MONOCHROME," .. db.outline
		elseif db.monochrome then
			flags = "MONOCHROME"
		elseif db.outline ~= "NONE" then
			flags = db.outline
		end
		bar.candyBarLabel:SetFont(media:Fetch("font", db.font), db.fontSize, flags)
		bar.candyBarDuration:SetFont(media:Fetch("font", db.font), db.fontSize, flags)
		bar:SetScript("OnMouseUp", BarOnClick)
		bar:Start()
		RearrangeBars()
		return bar
	end

	function mod:StopBar(text)
		local dirty = nil
		for bar in next, activeBars do
			if bar:GetLabel() == text then
				bar:Stop()
				dirty = true
			end
		end
		if dirty then RearrangeBars() end
	end

	candy.RegisterCallback(mod, "LibCandyBar_Stop", function(_, bar)
		if activeBars[bar] then
			activeBars[bar] = nil
			RearrangeBars()
		end
	end)
end

function mod:GetBar(text)
	for bar in next, activeBars do
		if bar:GetLabel() == text then
			return bar
		end
	end
end
