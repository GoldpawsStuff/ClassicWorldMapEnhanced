local ADDON,ns = ...
if (not ns.isCompatible) then
	return
end

local zoneData = ns.zoneData
local zoneReveal = ns.zoneReveal

local Private = CreateFrame("Frame")
Private:SetScript("OnEvent", function(self, event, ...) self:OnEvent(event, ...) end)
Private:RegisterEvent("ADDON_LOADED")

-- Lua API
local ipairs = ipairs
local math_ceil = math.ceil
local math_floor = math.floor
local math_mod = math.fmod
local pairs = pairs
local select = select
local string_format = string.format
local string_gsub = string.gsub
local string_lower = string.lower
local string_split = string.split
local table_insert = table.insert
local table_wipe = table.wipe
local tonumber = tonumber
local unpack = unpack

-- WoW API
local GetAddOnEnableState = GetAddOnEnableState
local GetAddOnInfo = GetAddOnInfo
local GetBestMapForUnit = C_Map.GetBestMapForUnit
local GetExploredMapTextures = C_MapExplorationInfo.GetExploredMapTextures
local GetMapArtID = C_Map.GetMapArtID
local GetMapArtLayers = C_Map.GetMapArtLayers
local GetNumAddOns = GetNumAddOns
local GetPlayerMapPosition = C_Map.GetPlayerMapPosition
local GetQuestGreenRange = GetQuestGreenRange
local IsAddOnLoaded = IsAddOnLoaded
local IsPlayerMoving = IsPlayerMoving
local Saturate = Saturate
local TexturePool_HideAndClearAnchors = TexturePool_HideAndClearAnchors
local UnitLevel = UnitLevel
local UnitName = UnitName

-- Texture caches for map exploration reveal
local overlayTextureCache, tileExists = {}, {}

-- Simplest and hackiest localization system to date.
local gameLocale = GetLocale()
local L = (function(tbl)
	-- Retrieve the correct locale table
	local L = tbl[gameLocale] or tbl.enUS
	-- Replace any 'true' values with the key name
	for i in pairs(L) do
		if (L[i] == true) then
			L[i] = i
		end
	end
	-- If this is a non-default locale,
	-- make sure any missing entries
	-- are copied from the enUS fallback.
	if (gameLocale ~= "enUS") then
		for i in pairs(tbl.enUS) do
			if (not L[i]) then
				L[i] = i
			end
		end
	end
	return L
end)({
	-- This is the default locale.
	-- Any other localed will use this one
	-- as a fallback in cases where entries are missing.
	enUS = {
		["Fog of War"] = true,
		["Fade when moving"] = true
	}
})

-- Default settings
-- These will be overwritten by saved settings,
-- so don't edit anything here.
ClassicWorldMapEnhanced_DB = {
	fadeWhenMoving = true,
	revealUnexploredAreas = true
}

-- Utility
----------------------------------------------------
-- Convert a Blizzard Color or RGB value set
-- into our own custom color table format.
local createColor = function(...)
	local tbl
	if (select("#", ...) == 1) then
		local old = ...
		if (old.r) then
			tbl = { old.r or 1, old.g or 1, old.b or 1 }
		else
			tbl = { unpack(old) }
		end
	else
		tbl = { ... }
	end
	if (#tbl == 3) then
		tbl.colorCode = string_format("|cff%02x%02x%02x", math_floor(tbl[1]*255), math_floor(tbl[2]*255), math_floor(tbl[3]*255))
	end
	return tbl
end

-- Create our color table
local Colors = {
	normal = createColor(229/255, 178/255, 38/255),
	highlight = createColor(250/255, 250/255, 250/255),
	title = createColor(255/255, 234/255, 137/255),
	offwhite = createColor(196/255, 196/255, 196/255),
	faction = {
		friendly = createColor(64/255, 211/255, 38/255),
		contested = createColor(249/255, 188/255, 65/255),
		hostile = createColor(245/255, 46/255, 36/255)
	},
	quest = {

		red = createColor(204/255, 26/255, 26/255),
		orange = createColor(255/255, 128/255, 64/255),
		yellow = createColor(229/255, 178/255, 38/255),
		green = createColor(89/255, 201/255, 89/255),
		gray = createColor(120/255, 120/255, 120/255)
	}
}

local CalculateScale = function()
	local min, max = 0.65, 0.95 -- our own scale limits
	local uiMin, uiMax = 0.65, 1.15 -- blizzard uiScale slider limits
	local uiScale = UIParent:GetEffectiveScale() -- current blizzard uiScale
	-- Calculate and return a relative scale
	-- that is user adjustable through graphics settings,
	-- but still keeps itself within our intended limits.
	if (uiScale < uiMin) then
		return min
	elseif (uiScale > uiMax) then
		return max
	else
		return ((uiScale - uiMin) / (uiMax - uiMin)) * (max - min) + min
	end
end

-- ScrollContainer API
----------------------------------------------------
local Container = {
	GetCanvasScale = function(self)
		return self.currentScale or self.targetScale or self:GetScale() or 1
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
	end,
	OnMouseWheel = function(self, delta)
		if (self.mouseWheelZoomMode == MAP_CANVAS_MOUSE_WHEEL_ZOOM_BEHAVIOR_NONE) then
			return
		end

		if (self:ShouldAdjustTargetPanOnMouseWheel(delta)) then
			local cursorX, cursorY = self:GetCursorPosition()
			local normalizedCursorX = self:NormalizeHorizontalSize(cursorX / self:GetCanvasScale() - self.Child:GetLeft())
			local normalizedCursorY = self:NormalizeVerticalSize(self.Child:GetTop() - cursorY / self:GetCanvasScale())

			if (not self:ShouldZoomInstantly()) then
				local nextZoomOutScale, nextZoomInScale = self:GetCurrentZoomRange()
				local minX, maxX, minY, maxY = self:CalculateScrollExtentsAtScale(nextZoomInScale)
				normalizedCursorX, normalizedCursorY = Clamp(normalizedCursorX, minX, maxX), Clamp(normalizedCursorY, minY, maxY)
			end

			self:SetPanTarget(normalizedCursorX, normalizedCursorY)
		end

		if (self.mouseWheelZoomMode == MAP_CANVAS_MOUSE_WHEEL_ZOOM_BEHAVIOR_SMOOTH) then
			self:SetZoomTarget(self:GetCanvasScale() + self.zoomAmountPerMouseWheelDelta * delta)

		elseif (self.mouseWheelZoomMode == MAP_CANVAS_MOUSE_WHEEL_ZOOM_BEHAVIOR_FULL) then
			if (delta > 0) then
				self:ZoomIn()
			else
				self:ZoomOut()
			end
		end
	end,
	ZoomIn = function(self)
		local nextZoomOutScale, nextZoomInScale = self:GetCurrentZoomRange()
		if (nextZoomInScale > self:GetCanvasScale()) then
			if self:ShouldZoomInstantly() then
				self:InstantPanAndZoom(nextZoomInScale, self.targetScrollX, self.targetScrollY)
			else
				self:SetZoomTarget(nextZoomInScale)
			end
		end
	end,
	ZoomOut = function(self)
		local nextZoomOutScale, nextZoomInScale = self:GetCurrentZoomRange()
		if (nextZoomOutScale < self:GetCanvasScale()) then
			if self:ShouldZoomInstantly() then
				self:InstantPanAndZoom(nextZoomOutScale, self.targetScrollX, self.targetScrollY)
			else
				self:SetZoomTarget(nextZoomOutScale)
				self:SetPanTarget(.5, .5)
			end
		end
	end
}

-- Callbacks
----------------------------------------------------
-- Returns coordinates as a nice string
local GetFormattedCoordinates = function(x, y)
	return string_gsub(string_format("%.1f", x*100), "%.(.+)", "|cff888888.%1|r"),
	       string_gsub(string_format("%.1f", y*100), "%.(.+)", "|cff888888.%1|r")
end

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

-- Reset the vertex colors of map overlays
local Overlay_ResetVertexColor = function(pool, texture)
	texture:SetVertexColor(1, 1, 1)
	texture:SetAlpha(1)
	return TexturePool_HideAndClearAnchors(pool, texture)
end

-- Refreshes map overlay textures
local Overlay_RefreshTextures = function(pin, fullUpdate)
	table_wipe(overlayTextureCache)
	table_wipe(tileExists)

	local uiMapID = WorldMapFrame.mapID
	if (not uiMapID) then
		return
	end

	local artID = GetMapArtID(uiMapID)
	if ((not artID) or (not zoneReveal[artID])) then
		return
	end

	local layers = GetMapArtLayers(uiMapID)
	local layerInfo = layers and layers[pin.layerIndex]
	if (not layerInfo) then
		return
	end

	local zoneMaps = zoneReveal[artID]
	local exploredMapTextures = GetExploredMapTextures(uiMapID)
	if (exploredMapTextures) then
		for _,info in ipairs(exploredMapTextures) do
			tileExists[info.textureWidth..":"..info.textureHeight..":"..info.offsetX..":"..info.offsetY] = true
		end
	end

	pin.layerIndex = pin:GetMap():GetCanvasContainer():GetCurrentLayerIndex()

	local TILE_SIZE_WIDTH = layerInfo.tileWidth
	local TILE_SIZE_HEIGHT = layerInfo.tileHeight

	-- Show textures if they are in database and have not been explored
	for key, files in pairs(zoneMaps) do
		if (not tileExists[key]) then
			local width, height, offsetX, offsetY = string_split(":", key)
			local fileDataIDs = { string_split(",", files) }
			local numTexturesWide = math_ceil(width/TILE_SIZE_WIDTH)
			local numTexturesTall = math_ceil(height/TILE_SIZE_HEIGHT)
			local texturePixelWidth, textureFileWidth, texturePixelHeight, textureFileHeight
			for j = 1, numTexturesTall do
				if (j < numTexturesTall) then
					texturePixelHeight = TILE_SIZE_HEIGHT
					textureFileHeight = TILE_SIZE_HEIGHT
				else
					texturePixelHeight = math_mod(height, TILE_SIZE_HEIGHT)
					if (texturePixelHeight == 0) then
						texturePixelHeight = TILE_SIZE_HEIGHT
					end
					textureFileHeight = 16
					while (textureFileHeight < texturePixelHeight) do
						textureFileHeight = textureFileHeight * 2
					end
				end
				for k = 1, numTexturesWide do
					local texture = pin.overlayTexturePool:Acquire()
					if (k < numTexturesWide) then
						texturePixelWidth = TILE_SIZE_WIDTH
						textureFileWidth = TILE_SIZE_WIDTH
					else
						texturePixelWidth = math_mod(width, TILE_SIZE_WIDTH)
						if (texturePixelWidth == 0) then
							texturePixelWidth = TILE_SIZE_WIDTH
						end
						textureFileWidth = 16
						while (textureFileWidth < texturePixelWidth) do
							textureFileWidth = textureFileWidth * 2
						end
					end

					texture:SetSize(texturePixelWidth, texturePixelHeight)
					texture:SetTexCoord(0, texturePixelWidth/textureFileWidth, 0, texturePixelHeight/textureFileHeight)
					texture:SetPoint("TOPLEFT", offsetX + (TILE_SIZE_WIDTH * (k-1)), -(offsetY + (TILE_SIZE_HEIGHT * (j - 1))))
					texture:SetTexture(tonumber(fileDataIDs[((j - 1) * numTexturesWide) + k]), nil, nil, "TRILINEAR")
					texture:SetDrawLayer("ARTWORK", -1)

					if (ClassicWorldMapEnhanced_DB.revealUnexploredAreas) then
						texture:Show()
						if fullUpdate then
							pin.textureLoadGroup:AddTexture(texture)
						end
					else
						texture:Hide()
					end
					texture:SetVertexColor(0.6, 0.6, 0.6)

					table_insert(overlayTextureCache, texture)
				end
			end
		end
	end
end

-- Update all map overlay textures
local Overlay_UpdateTextures = function(self)
	for i = 1, #overlayTextureCache do
		overlayTextureCache[i]:SetShown(ClassicWorldMapEnhanced_DB.revealUnexploredAreas)
	end
end

-- Update the worldmap area text
local OnUpdate_MapAreaLabel = function(self)
	self:ClearLabel(MAP_AREA_LABEL_TYPE.AREA_NAME)
	local map = self.dataProvider:GetMap()
	if (map:IsCanvasMouseFocus()) then
		local name, description, descriptionColor
		local uiMapID = map:GetMapID()
		local normalizedCursorX, normalizedCursorY = map:GetNormalizedCursorPosition()
		local positionMapInfo = C_Map.GetMapInfoAtPosition(uiMapID, normalizedCursorX, normalizedCursorY)
		if (positionMapInfo and (positionMapInfo.mapID ~= uiMapID)) then
			name = positionMapInfo.name
			local playerMinLevel, playerMaxLevel, playerFaction
			if (zoneData[positionMapInfo.mapID]) then
				playerMinLevel = zoneData[positionMapInfo.mapID].min
				playerMaxLevel = zoneData[positionMapInfo.mapID].max
				playerFaction = zoneData[positionMapInfo.mapID].faction
			end
			if (playerFaction) then
				local englishFaction, localizedFaction = UnitFactionGroup("player")
				if (playerFaction == "Alliance") then
					description = string_format(FACTION_CONTROLLED_TERRITORY, FACTION_ALLIANCE)
				elseif (playerFaction == "Horde") then
					description = string_format(FACTION_CONTROLLED_TERRITORY, FACTION_HORDE)
				end
				if (englishFaction == playerFaction) then
					description = Colors.faction.friendly.colorCode .. description .. FONT_COLOR_CODE_CLOSE
				else
					description = Colors.faction.hostile.colorCode .. description .. FONT_COLOR_CODE_CLOSE
				end
			end
			if (name and playerMinLevel and playerMaxLevel and (playerMinLevel > 0) and (playerMaxLevel > 0)) then
				local playerLevel = UnitLevel("player")
				local color
				if (playerLevel < playerMinLevel) then
					color = GetQuestDifficultyColor(playerMinLevel, playerLevel)
				elseif (playerLevel > playerMaxLevel) then
					--subtract 2 from the maxLevel so zones entirely below the player's level won't be yellow
					color = GetQuestDifficultyColor(playerMaxLevel - 2, playerLevel)
				else
					color = Colors.quest.yellow
				end
				if (playerMinLevel ~= playerMaxLevel) then
					name = name..color.colorCode.." ("..playerMinLevel.."-"..playerMaxLevel..")"..FONT_COLOR_CODE_CLOSE
				else
					name = name..color.colorCode.." ("..playerMaxLevel..")"..FONT_COLOR_CODE_CLOSE
				end
			end
		else
			name = MapUtil.FindBestAreaNameAtMouse(uiMapID, normalizedCursorX, normalizedCursorY)
		end
		if name then
			self:SetLabel(MAP_AREA_LABEL_TYPE.AREA_NAME, name, description)
		end
	end
	self:EvaluateLabels()
end

-- Update worldmap player- and cursor coordinates
local OnUpdate_MapCoordinates = function(self, elapsed)
	self.elapsed = self.elapsed + elapsed
	if (self.elapsed < .05) then
		return
	end
	local pX, pY, cX, cY
	local uiMapID = GetBestMapForUnit("player")
	if (uiMapID) then
		local mapPosObject = GetPlayerMapPosition(uiMapID, "player")
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
		if (ns.HasQuestHelper) then
			self.CursorCoordinates:SetFormattedText(Colors.title.colorCode.."%1$s|r %2$s %3$s", MOUSE_LABEL, GetFormattedCoordinates(cX, cY))
		else
			self.CursorCoordinates:SetFormattedText("%2$s %3$s "..Colors.title.colorCode.."%1$s|r", MOUSE_LABEL, GetFormattedCoordinates(cX, cY))
		end
	else
		self.CursorCoordinates:SetText("")
	end
end

-- Update map opacity based on player movement
local OnUpdate_MapMovementFader = function(self, elapsed)
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

local WorldMapFrame_UpdatePositions = function()
	local WorldMapFrame = WorldMapFrame

	WorldMapTrackQuest:ClearAllPoints()
	WorldMapTrackQuest:SetPoint("LEFT", WorldMapQuestShowObjectives, "LEFT", -(10 + WorldMapTrackQuestText:GetWidth() + 24), 0)

	if (Private.PlayerCoordinates) then
		if (WorldMapFrame.isMaximized) then
			Private.PlayerCoordinates:SetPoint("BOTTOMLEFT", WorldMapFrame.BorderFrame, "BOTTOMLEFT", 4 + 11, 10)
		else
			Private.PlayerCoordinates:SetPoint("BOTTOMLEFT", WorldMapFrame.BorderFrame, "BOTTOMLEFT", 4 + 20, 10)
		end
	end

	if (Private.FadeWhenMovingButton) then
		if (WorldMapFrame.isMaximized) then
			Private.FadeWhenMovingButton:SetParent(WorldMapFrame.BorderFrame)
			Private.FadeWhenMovingButton:SetPoint("TOPLEFT", 6, 0)
		else
			Private.FadeWhenMovingButton:SetParent(WorldMapFrame.MiniBorderFrame)
			Private.FadeWhenMovingButton:SetPoint("TOPLEFT", 6 + 12, -28)
		end
	end
end

local WorldMapFrame_Maximize = function()
	local WorldMapFrame = WorldMapFrame
	WorldMapFrame:SetParent(UIParent)
	WorldMapFrame:SetScale(1)
	WorldMapFrame:OnFrameSizeChanged()
	WorldMapFrame_UpdatePositions()
end

local WorldMapFrame_Minimize = function()
	local WorldMapFrame = WorldMapFrame
	if (not WorldMapFrame:IsMaximized()) then
		WorldMapFrame:ClearAllPoints()
		WorldMapFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 16, -94)
		WorldMapFrame_UpdatePositions()
	end
end

local WorldMapFrame_SyncState = function()
	local WorldMapFrame = WorldMapFrame
	if (WorldMapFrame:IsMaximized()) then
		WorldMapFrame:ClearAllPoints()
		WorldMapFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 30)
		WorldMapFrame_UpdatePositions()
	end
end

local WorldMapFrame_UpdateMaximizedSize = function()
	local WorldMapFrame = WorldMapFrame
	local width, height = WorldMapFrame:GetSize()
	local scale = CalculateScale()
	local magicNumber = (1 - scale) * 100
	WorldMapFrame:SetSize((width * scale) - (magicNumber + 2), (height * scale) - 2)
end

-- Addon API
----------------------------------------------------
-- Set up the main worldmap frame.
Private.SetUpCanvas = function(self)

	self.Canvas.BlackoutFrame:Hide()

	if (ns.HasQuestHelper) then
		self.Canvas.BlackoutFrame:HookScript("OnShow", self.Canvas.BlackoutFrame.Hide)
	end

	self.Canvas:SetIgnoreParentScale(false)
	self.Canvas:SetFrameStrata("MEDIUM")
	self.Canvas:ClearAllPoints()
	self.Canvas:SetPoint("CENTER")
	self.Canvas.BorderFrame:SetFrameStrata("MEDIUM")
	self.Canvas.BorderFrame:SetFrameLevel(1)
	self.Canvas:RefreshDetailLayers()

	if (ns.HasQuestHelper) then
		hooksecurefunc(self.Canvas, "Maximize", WorldMapFrame_Maximize)
		hooksecurefunc(self.Canvas, "Minimize", WorldMapFrame_Minimize)
		hooksecurefunc(self.Canvas, "SynchronizeDisplayState", WorldMapFrame_SyncState)
		hooksecurefunc("WorldMapQuestShowObjectives_Toggle", WorldMapFrame_UpdatePositions)

		if (self.Canvas:IsMaximized()) then
			WorldMapFrame_UpdateMaximizedSize()
			WorldMapFrame_Maximize()
		end

		WorldMapFrame_UpdatePositions()
	end
end

-- Add our own API to the WorldMap.
-- This is needed for the mouseover to align.
-- We're also adding Classic mouse zoom here.
Private.SetUpContainer = function(self)
	for name,method in pairs(Container) do
		self.Container[name] = method
	end
	-- Fix scroll zooming in classic
	self.Container:SetScript("OnMouseWheel", self.Container.OnMouseWheel)
end

-- Set up the movement fader.
Private.SetUpFading = function(self)

	self.FadeTimer = CreateFrame("Frame")
	self.FadeTimer.elapsed = 0
	self.FadeTimer.stopAlpha = .9
	self.FadeTimer.moveAlpha = .5
	self.FadeTimer.stepIn = .05
	self.FadeTimer.stepOut = .05
	self.FadeTimer.throttle = .02
	self.FadeTimer.Canvas = self.Canvas

	local button = CreateFrame("CheckButton", nil, WorldMapFrame.BorderFrame, "OptionsCheckButtonTemplate")
	button:SetPoint("TOPLEFT", 6, 0)
	button:SetSize(24, 24)

	self.FadeWhenMovingButton = button

	button.msg = button:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	button.msg:SetPoint("LEFT", 24, 0)
	button.msg:SetText(L["Fade when moving"])

	button:SetHitRectInsets(0, 0 - button.msg:GetWidth(), 0, 0)
	button:SetChecked(ClassicWorldMapEnhanced_DB.fadeWhenMoving)
	button:SetScript("OnClick", function()
		ClassicWorldMapEnhanced_DB.fadeWhenMoving = button:GetChecked()
		if (ClassicWorldMapEnhanced_DB.fadeWhenMoving) then
			if (IsPlayerMoving()) then
				self:OnEvent("PLAYER_STARTED_MOVING")
			else
				self:OnEvent("PLAYER_STOPPED_MOVING")
			end
		else
			self:OnEvent("PLAYER_STOPPED_MOVING")
		end
	end)

	button:Show()

	self:RegisterEvent("PLAYER_ENTERING_WORLD")
	self:RegisterEvent("PLAYER_STARTED_MOVING")
	self:RegisterEvent("PLAYER_STOPPED_MOVING")
end

-- Set up the coordinate display.
Private.SetUpCoordinates = function(self)
	local PlayerCoordinates = self.Container:CreateFontString()
	PlayerCoordinates:SetFontObject(Game12Font_o1)

	if (ns.HasQuestHelper) then
		WorldMapFrame_UpdatePositions()
	else
		PlayerCoordinates:SetPoint("TOPLEFT", self.Canvas, "BOTTOMLEFT", 10, -7)
	end

	PlayerCoordinates:SetDrawLayer("OVERLAY")
	PlayerCoordinates:SetJustifyH("LEFT")

	self.PlayerCoordinates = PlayerCoordinates

	local CursorCoordinates = self.Container:CreateFontString()
	CursorCoordinates:SetFontObject(Game12Font_o1)

	if (ns.HasQuestHelper) then
		CursorCoordinates:SetPoint("TOPLEFT", PlayerCoordinates, "TOPRIGHT", 10, 0)
	else
		CursorCoordinates:SetPoint("TOPRIGHT", self.Container, "BOTTOMRIGHT", -10, -7)
	end

	CursorCoordinates:SetDrawLayer("OVERLAY")
	CursorCoordinates:SetJustifyH("RIGHT")

	self.CursorCoordinates = CursorCoordinates

	local CoordinateTimer = CreateFrame("Frame", nil, self.Canvas)
	CoordinateTimer.elapsed = 0
	CoordinateTimer.Canvas = self.Canvas
	CoordinateTimer.Coordinates = Coordinates
	CoordinateTimer.PlayerCoordinates = PlayerCoordinates
	CoordinateTimer.CursorCoordinates = CursorCoordinates
	CoordinateTimer:SetScript("OnUpdate", OnUpdate_MapCoordinates)

	WorldMapFrame_UpdatePositions()
end

-- Set up the zone level display.
Private.SetUpZoneLevels = function(self)
	for provider in next, WorldMapFrame.dataProviders do
		if provider.setAreaLabelCallback then
			provider.Label:SetScript("OnUpdate", OnUpdate_MapAreaLabel)
		end
	end
end

-- Set up the Fog of War removal.
Private.SetUpMapReveal = function(self)
	local button = CreateFrame("CheckButton", nil, WorldMapFrame.BorderFrame, "OptionsCheckButtonTemplate")
	button:SetPoint("TOPRIGHT", -260, 0)
	button:SetSize(24, 24)

	button.msg = button:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	button.msg:SetPoint("LEFT", 24, 0)
	button.msg:SetText(L["Fog of War"])

	button:SetHitRectInsets(0, 0 - button.msg:GetWidth(), 0, 0)
	button:SetChecked(not ClassicWorldMapEnhanced_DB.revealUnexploredAreas)
	button:SetScript("OnClick", function(self)
		ClassicWorldMapEnhanced_DB.revealUnexploredAreas = not button:GetChecked()
		Overlay_UpdateTextures()
	end)

	if Private:IsAddOnEnabled("Questie") then
		local isHooked

		local UpdatePosition = function()
			local qbutton = _G.Questie_Toggle
			if (qbutton) then
				local point, anchor, rpoint, x, y = qbutton:GetPoint()
				if (point == "RIGHT" and rpoint == "LEFT" and anchor == _G.WorldMapFrameCloseButton) then
					button:ClearAllPoints()
					button:SetPoint("TOPRIGHT", -(24 + 10 + button.msg:GetWidth() + 10 + qbutton:GetWidth()), 0)
				end
			end
		end

		local Update = function()
			local qbutton = _G.Questie_Toggle
			if (qbutton) then
				if (not isHooked) then
					hooksecurefunc(qbutton, "SetPoint", UpdatePosition)
					isHooked = true
				end
				UpdatePosition()
			end
		end
		button:HookScript("OnShow", Update)
	end

	button:Show()

	for pin in WorldMapFrame:EnumeratePinsByTemplate("MapExplorationPinTemplate") do
		hooksecurefunc(pin, "RefreshOverlays", Overlay_RefreshTextures)
		pin.overlayTexturePool.resetterFunc = Overlay_ResetVertexColor
	end
end

-- Fix BC Bugs
----------------------------------------------------
Private.FixBlizzardBugs = function(self)
	if (ns.Version == 2) then
		if (_G.WorldMapZoneMinimapDropDown) then
			_G.WorldMapZoneMinimapDropDown:SetScript("OnEnter", function(self)
				-- Blizzard don't check for a key (yet), so this bugs out with no bind.
				local key = GetBindingKey("TOGGLEBATTLEFIELDMINIMAP")
				if (key) then
					_G.WorldMapZoneMinimapDropDown_OnEnter(self)
				end
			end)
		end
	end
end

-- Addon Init & Events
----------------------------------------------------
-- Our addon's event handler. Handles all events.
Private.OnEvent = function(self, event, ...)
	if (event == "ADDON_LOADED") then
		local addon = ...
		if (addon == ADDON) then
			if (IsAddOnLoaded("Blizzard_WorldMap")) then
				self:UnregisterEvent("ADDON_LOADED")
			end

			self:OnInit()

		elseif (addon == "Blizzard_WorldMap") then
			if (IsAddOnLoaded(ADDON)) then
				self:UnregisterEvent("ADDON_LOADED")
			end

			self:OnEnable()

		end

	elseif (event == "PLAYER_STARTED_MOVING") then

		self.FadeTimer.alpha = self.Canvas:GetAlpha()
		self.FadeTimer.fadeDirection = ClassicWorldMapEnhanced_DB.fadeWhenMoving and "OUT" or "IN"
		self.FadeTimer.isFading = true
		self.FadeTimer:SetScript("OnUpdate", OnUpdate_MapMovementFader)

	elseif (event == "PLAYER_STOPPED_MOVING") or (event == "PLAYER_ENTERING_WORLD") then

		self.FadeTimer.alpha = self.Canvas:GetAlpha()
		self.FadeTimer.fadeDirection = "IN"
		self.FadeTimer.isFading = true
		self.FadeTimer:SetScript("OnUpdate", OnUpdate_MapMovementFader)

	end
end

-- This is called whenever our own addon
-- and its variables are fully loaded.
Private.OnInit = function(self)
	if Private:IsAddOnEnabled("Leatrix_Maps") then
		return
	end

	-- Check whether or not the worldmap addon has been loaded,
	-- and if its ADDON_LOADED event has fired.
	local loaded, finished = IsAddOnLoaded("Blizzard_WorldMap")
	if (loaded and finished) then
		self:OnEnable()
	else
		self:RegisterEvent("ADDON_LOADED")
	end
end

-- This is called after both our addon
-- and the worldmap addon has been fully loaded.
Private.OnEnable = function(self)
	if Private:IsAddOnEnabled("Leatrix_Maps") then
		return
	end

	self.Canvas = WorldMapFrame

	if (ns.HasQuestHelper) then
		self.Canvas:HookScript("OnShow", function() self:OnEvent("PLAYER_ENTERING_WORLD") end)
	end

	self.Container = WorldMapFrame.ScrollContainer
	self:SetUpCanvas()
	self:SetUpContainer()
	self:SetUpFading()
	self:SetUpCoordinates()
	self:SetUpZoneLevels()
	self:SetUpMapReveal()
	self:FixBlizzardBugs()
end

-- Retrieve addon info the way we prefer it.
-- This is mostly a convenience method copied from
-- my own private library set to keep APIs consistent.
Private.GetAddOnInfo = function(self, index)
	local name, title, notes, loadable, reason, security, newVersion = GetAddOnInfo(index)
	local enabled = not(GetAddOnEnableState(UnitName("player"), index) == 0)
	return name, title, notes, enabled, loadable, reason, security
end

-- Check if an addon is enabled	in the addon listing,
-- to avoid relying on addon dependency and loading order.
Private.IsAddOnEnabled = function(self, target)
	local target = string_lower(target)
	for i = 1,GetNumAddOns() do
		local name, title, notes, enabled, loadable, reason, security = self:GetAddOnInfo(i)
		if (string_lower(name) == target) then
			return (enabled and loadable)
		end
	end
end
