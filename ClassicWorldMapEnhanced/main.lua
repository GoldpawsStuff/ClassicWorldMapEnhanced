local ADDON = ...

local Private = CreateFrame("Frame")
Private:SetScript("OnEvent", function(self, event, ...) self:OnEvent(event, ...) end)
Private:RegisterEvent("ADDON_LOADED")

-- Lua API
local math_floor = math.floor
local select = select
local string_format = string.format
local string_gsub = string.gsub
local string_lower = string.lower
local unpack = unpack

-- WoW API
local GetAddOnEnableState = GetAddOnEnableState
local GetAddOnInfo = GetAddOnInfo 
local GetBestMapForUnit = C_Map.GetBestMapForUnit
local GetNumAddOns = GetNumAddOns
local GetPlayerMapPosition = C_Map.GetPlayerMapPosition
local GetQuestGreenRange = GetQuestGreenRange
local IsAddOnLoaded = IsAddOnLoaded
local Saturate = Saturate
local UnitLevel = UnitLevel
local UnitName = UnitName

-- Utility
----------------------------------------------------
-- Convert a Blizzard Color or RGB value set 
-- into our own custom color table format. 
local createColor = function(...)
	local tbl
	if (select("#", ...) == 1) then
		local old = ...
		if (old.r) then 
			tbl = {}
			tbl[1] = old.r or 1
			tbl[2] = old.g or 1
			tbl[3] = old.b or 1
		else
			tbl = { unpack(old) }
		end
	else
		tbl = { ... }
	end
	if (#tbl == 3) then
		tbl.colorCode = ("|cff%02x%02x%02x"):format(math_floor(tbl[1]*255), math_floor(tbl[2]*255), math_floor(tbl[3]*255))
	end
	return tbl
end

-- Create our color table
local Colors = {
	normal = createColor(229/255, 178/255, 38/255),
	highlight = createColor(250/255, 250/255, 250/255),
	title = createColor(255/255, 234/255, 137/255),
	offwhite = createColor(196/255, 196/255, 196/255),
	quest = {
		red = createColor(204/255, 26/255, 26/255),
		orange = createColor(255/255, 128/255, 64/255),
		yellow = createColor(229/255, 178/255, 38/255),
		green = createColor(89/255, 201/255, 89/255),
		gray = createColor(120/255, 120/255, 120/255)
	}
}

-- Returns the correct difficulty color compared to the player
local GetQuestDifficultyColor = function(level, playerLevel)
	level = level - (playerLevel or UnitLevel("player"))
	if (level > 4) then
		return Colors.quest.red
	elseif (level > 2) then
		return Colors.quest.orange
	elseif (level >= -2) then
		return Colors.quest.yellow
	elseif (level >= -GetQuestGreenRange()) then
		return Colors.quest.green
	else
		return Colors.quest.gray
	end
end

-- ScrollContainer API 
----------------------------------------------------
local Container = {
	GetCanvasScale = function(self)
		return self:GetScale()
	end,
	GetCursorPosition = function(self)
		local currentX, currentY = GetCursorPosition()
		local scale = UIParent:GetScale()
		if not(currentX and currentY and scale) then 
			return 0,0
		end 
		local scaledX, scaledY = currentX/scale, currentY/scale
		return scaledX, scaledY
	end,
	GetNormalizedCursorPosition = function(self)
		local x,y = self:GetCursorPosition()
		return self:NormalizeUIPosition(x,y)
	end,
	NormalizeUIPosition = function(self, x, y)
		return Saturate(self:NormalizeHorizontalSize(x / self:GetCanvasScale() - self.Child:GetLeft())),
		       Saturate(self:NormalizeVerticalSize(self.Child:GetTop() - y / self:GetCanvasScale()))
	end
}

-- Zone Levels
local zoneData = {
	-- Eastern Kingdoms
	[1416] = { min = 27, max = 39 }, -- Alterac Mountains
	[1417] = { min = 30, max = 40 }, -- Arathi Highlands
	[1418] = { min = 36, max = 45 }, -- Badlands
	[1419] = { min = 46, max = 63 }, -- Blasted Lands
	[1428] = { min = 50, max = 59 }, -- Burning Steppes
	[1430] = { min = 50, max = 60 }, -- Deadwind Pass
	[1426] = { min =  1, max = 12 }, -- Dun Morogh
	[1431] = { min = 10, max = 30 }, -- Duskwood
	[1423] = { min = 54, max = 59 }, -- Eastern Plaguelands
	[1429] = { min =  1, max = 10 }, -- Elwynn Forest
	[1448] = { min = 47, max = 54 }, -- Felwood
	[1424] = { min = 20, max = 31 }, -- Hillsbrad Foothills
	[1432] = { min = 10, max = 18 }, -- Loch Modan
	[1433] = { min = 15, max = 25 }, -- Redridge Mountains
	[1427] = { min = 43, max = 56 }, -- Searing Gorge
	[1421] = { min = 10, max = 20 }, -- Silverpine Forest
	[1434] = { min = 30, max = 50 }, -- Stranglethorn Vale
	[1435] = { min = 36, max = 43 }, -- Swamp of Sorrows
	[1425] = { min = 41, max = 49 }, -- The Hinterlands
	[1420] = { min =  1, max = 12 }, -- Tirisfal Glades
	[1436] = { min =  9, max = 18 }, -- Westfall
	[1422] = { min = 46, max = 57 }, -- Western Plaguelands
	[1437] = { min = 20, max = 30 }, -- Wetlands

	-- Kalimdor
	[1440] = { min = 19, max = 30 }, -- Ashenvale
	[1447] = { min = 42, max = 55 }, -- Azshara
	[1439] = { min = 11, max = 19 }, -- Darkshore
	[1443] = { min = 30, max = 39 }, -- Desolace
	[1411] = { min =  1, max = 10 }, -- Durotar
	[1445] = { min = 36, max = 61 }, -- Dustwallow Marsh
	[1444] = { min = 41, max = 60 }, -- Feralas
	[1450] = { min = 15, max = 15 }, -- Moonglade
	[1412] = { min =  1, max = 10 }, -- Mulgore
	[1451] = { min = 55, max = 59 }, -- Silithus
	[1442] = { min = 15, max = 25 }, -- Stonetalon Mountains
	[1446] = { min = 40, max = 50 }, -- Tanaris
	[1438] = { min =  1, max = 11 }, -- Teldrassil
	[1413] = { min = 10, max = 33 }, -- The Barrens
	[1441] = { min = 24, max = 35 }, -- Thousand Needles
	[1449] = { min = 48, max = 55 }, -- Un'Goro Crater
	[1452] = { min = 55, max = 60 }  -- Winterspring
}

-- Callbacks
----------------------------------------------------
local GetFormattedCoordinates = function(x, y)
	return string_gsub(string_format("%.1f", x*100), "%.(.+)", "|cff888888.%1|r"),
	       string_gsub(string_format("%.1f", y*100), "%.(.+)", "|cff888888.%1|r")
end 

-- OnUpdate Handlers
----------------------------------------------------
local AreaLabel_OnUpdate = function(self)
	self:ClearLabel(MAP_AREA_LABEL_TYPE.AREA_NAME)
	local map = self.dataProvider:GetMap()
	if map:IsCanvasMouseFocus() then
		local name, description
		local mapID = map:GetMapID()
		local normalizedCursorX, normalizedCursorY = map:GetNormalizedCursorPosition()
		local positionMapInfo = C_Map.GetMapInfoAtPosition(mapID, normalizedCursorX, normalizedCursorY)		
		if positionMapInfo and positionMapInfo.mapID ~= mapID then
			name = positionMapInfo.name

			local playerMinLevel, playerMaxLevel 
			if zoneData[positionMapInfo.mapID] then
				playerMinLevel = zoneData[positionMapInfo.mapID].min
				playerMaxLevel = zoneData[positionMapInfo.mapID].max
			end

			if name and playerMinLevel and playerMaxLevel and playerMinLevel > 0 and playerMaxLevel > 0 then
				local playerLevel = UnitLevel("player")
				local color
				if playerLevel < playerMinLevel then
					color = GetQuestDifficultyColor(playerMinLevel, playerLevel)
				elseif playerLevel > playerMaxLevel then
					--subtract 2 from the maxLevel so zones entirely below the player's level won't be yellow
					color = GetQuestDifficultyColor(playerMaxLevel - 2, playerLevel)
				else
					color = Colors.quest.yellow
				end
				--color = ConvertRGBtoColorString(color)
				if playerMinLevel ~= playerMaxLevel then
					name = name..color.colorCode.." ("..playerMinLevel.."-"..playerMaxLevel..")"..FONT_COLOR_CODE_CLOSE
				else
					name = name..color.colorCode.." ("..playerMaxLevel..")"..FONT_COLOR_CODE_CLOSE
				end
			end
		else
			name = MapUtil.FindBestAreaNameAtMouse(mapID, normalizedCursorX, normalizedCursorY)
		end
		if name then
			self:SetLabel(MAP_AREA_LABEL_TYPE.AREA_NAME, name, description)
		end
	end
	self:EvaluateLabels()
end

local Coordinates_OnUpdate = function(self, elapsed)
	self.elapsed = self.elapsed + elapsed
	if (self.elapsed < .05) then 
		return 
	end 
	local pX, pY, cX, cY
	local mapID = GetBestMapForUnit("player")
	if (mapID) then 
		local mapPosObject = GetPlayerMapPosition(mapID, "player")
		if (mapPosObject) then 
			pX, pY = mapPosObject:GetXY()
		end 
	end 
	if (self.Canvas:IsMouseOver(0, 0, 0, 0)) then 
		cX, cY = self.Canvas:GetNormalizedCursorPosition()
	end
	if (pX and pY) then 
		self.PlayerCoordinates:SetFormattedText(Colors.title.colorCode.."%1$s|r %2$s %3$s", PLAYER, GetFormattedCoordinates(pX, pY))
	else 
		self.PlayerCoordinates:SetText("")
	end 
	if (cX and cY) then 
		self.CursorCoordinates:SetFormattedText("%2$s %3$s "..Colors.title.colorCode.."%1$s|r", MOUSE_LABEL, GetFormattedCoordinates(cX, cY))
	else
		self.CursorCoordinates:SetText("")
	end 
end

local FadeTimer_OnUpdate = function(self, elapsed) 
	self.elapsed = self.elapsed + elapsed
	if (self.elapsed < self.throttle) then
		return 
	end 
	if (self.isFading) then 
		if (self.fadeDirection == "IN") then 
			if (self.alpha + self.stepIn < self.stopAlpha) then 
				self.alpha = self.alpha + self.stepIn
			else 
				self.alpha = self.stopAlpha
				self.fadeDirection = nil
				self.isFading = nil
				self:SetScript("OnUpdate", nil)
			end 
		elseif (self.fadeDirection == "OUT") then 
			if (self.alpha - self.stepOut > self.moveAlpha) then 
				self.alpha = self.alpha - self.stepOut
			else 
				self.alpha = self.moveAlpha
				self.fadeDirection = nil
				self.isFading = nil
				self:SetScript("OnUpdate", nil)
			end 
		end 
		self.Canvas:SetAlpha(self.alpha)
	end 
end

-- Addon Init & Events
----------------------------------------------------
Private.OnEvent = function(self, event, ...)
	if (event == "ADDON_LOADED") then 
		local addon = ...
		if (addon == ADDON) then 
			self:UnregisterEvent("ADDON_LOADED")
			self:OnInit()
		elseif (addon == "Blizzard_WorldMap") then 
			self:UnregisterEvent("ADDON_LOADED")
			self:OnEnable()
		end
	elseif (event == "PLAYER_STARTED_MOVING") then 
		self.FadeTimer.alpha = self.Canvas:GetAlpha()
		self.FadeTimer.fadeDirection = "OUT"
		self.FadeTimer.isFading = true
		self.FadeTimer:SetScript("OnUpdate", FadeTimer_OnUpdate)

	elseif (event == "PLAYER_STOPPED_MOVING") or (event == "PLAYER_ENTERING_WORLD") then 
		self.FadeTimer.alpha = self.Canvas:GetAlpha()
		self.FadeTimer.fadeDirection = "IN"
		self.FadeTimer.isFading = true
		self.FadeTimer:SetScript("OnUpdate", FadeTimer_OnUpdate)
	end
end

Private.OnInit = function(self)
	self.limitedMode = Private:IsAddOnEnabled("AzeriteUI_Classic")

	-- Check whether or not the addon has been loaded, 
	-- and if its addon's ADDON_LOADED event has fired.
	local loaded, finished = IsAddOnLoaded("Blizzard_WorldMap")
	if (loaded and finished) then 
		self:OnEnable()
	else
		self:RegisterEvent("ADDON_LOADED")
	end 
end

Private.OnEnable = function(self)
	self.Canvas = WorldMapFrame
	self.Container = WorldMapFrame.ScrollContainer

	self:SetUpCanvas()
	self:SetUpContainer()
	self:SetUpFading()
	self:SetUpCoordinates()
	self:SetUpZoneLevels()
end 

-- Addon API
----------------------------------------------------
Private.SetUpCanvas = function(self)
	if (self.limitedMode) then 
		return 
	end 
	-- Bring the map down to size.
	self.Canvas.BlackoutFrame:Hide()
	self.Canvas:SetIgnoreParentScale(false)
	self.Canvas:RefreshDetailLayers()
end

Private.SetUpContainer = function(self)
	if (self.limitedMode) then 
		return 
	end 
	-- Add our own API to the WorldMap.
	-- This is needed for the mouseover to align. 
	for name,method in pairs(Container) do 
		self.Container[name] = method
	end 
end

Private.SetUpFading = function(self)
	if (self.limitedMode) then 
		return 
	end 

	self.FadeTimer = CreateFrame("Frame")
	self.FadeTimer.elapsed = 0
	self.FadeTimer.stopAlpha = .9
	self.FadeTimer.moveAlpha = .65
	self.FadeTimer.stepIn = .05
	self.FadeTimer.stepOut = .05
	self.FadeTimer.throttle = .02
	self.FadeTimer.Canvas = self.Canvas

	self:RegisterEvent("PLAYER_ENTERING_WORLD")
	self:RegisterEvent("PLAYER_STARTED_MOVING")
	self:RegisterEvent("PLAYER_STOPPED_MOVING")
end

Private.SetUpCoordinates = function(self)
	local PlayerCoordinates = self.Container:CreateFontString()
	PlayerCoordinates:SetFontObject(Game12Font_o1)
	PlayerCoordinates:SetPoint("TOPLEFT", self.Container, "BOTTOMLEFT", 10, -7)
	PlayerCoordinates:SetDrawLayer("OVERLAY")
	PlayerCoordinates:SetJustifyH("LEFT")

	local CursorCoordinates = self.Container:CreateFontString()
	CursorCoordinates:SetFontObject(Game12Font_o1)
	CursorCoordinates:SetPoint("TOPRIGHT", self.Container, "BOTTOMRIGHT", -10, -7)
	CursorCoordinates:SetDrawLayer("OVERLAY")
	CursorCoordinates:SetJustifyH("RIGHT")

	local CoordinateTimer = CreateFrame("Frame", nil, self.Canvas)
	CoordinateTimer.elapsed = 0
	CoordinateTimer.Canvas = self.Canvas
	CoordinateTimer.Coordinates = Coordinates
	CoordinateTimer.PlayerCoordinates = PlayerCoordinates
	CoordinateTimer.CursorCoordinates = CursorCoordinates
	CoordinateTimer:SetScript("OnUpdate", Coordinates_OnUpdate)
end

Private.SetUpZoneLevels = function(self)
	for provider in next, WorldMapFrame.dataProviders do
		if provider.setAreaLabelCallback then
			provider.Label:SetScript("OnUpdate", AreaLabel_OnUpdate)
		end
	end
end

-- Retrieve addon info the way we prefer it
Private.GetAddOnInfo = function(self, index)
	local name, title, notes, loadable, reason, security, newVersion = GetAddOnInfo(index)
	local enabled = not(GetAddOnEnableState(UnitName("player"), index) == 0) 
	return name, title, notes, enabled, loadable, reason, security
end

-- Check if an addon is enabled	in the addon listing
Private.IsAddOnEnabled = function(self, target)
	local target = string_lower(target)
	for i = 1,GetNumAddOns() do
		local name, title, notes, enabled, loadable, reason, security = self:GetAddOnInfo(i)
		if string_lower(name) == target then
			if enabled then
				return true
			end
		end
	end
end
