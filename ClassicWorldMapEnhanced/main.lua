local ADDON = ...

local Private = CreateFrame("Frame")
Private:SetScript("OnEvent", function(self, event, ...) self:OnEvent(event, ...) end)
Private:RegisterEvent("ADDON_LOADED")

-- Lua API
local string_format = string.format
local string_gsub = string.gsub
local string_lower = string.lower

-- WoW API
local GetAddOnEnableState = GetAddOnEnableState
local GetAddOnInfo = GetAddOnInfo 
local GetBestMapForUnit = C_Map.GetBestMapForUnit
local GetNumAddOns = GetNumAddOns
local GetPlayerMapPosition = C_Map.GetPlayerMapPosition
local IsAddOnLoaded = IsAddOnLoaded
local Saturate = Saturate
local UnitName = UnitName

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

-- Callbacks
----------------------------------------------------
local GetFormattedCoordinates = function(x, y)
	return string_gsub(string_format("%.1f", x*100), "%.(.+)", "|cff888888.%1|r"),
	       string_gsub(string_format("%.1f", y*100), "%.(.+)", "|cff888888.%1|r")
end 

local OnUpdate = function(self, elapsed) 
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

-- Addon
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
		self.FadeTimer:SetScript("OnUpdate", OnUpdate)

	elseif (event == "PLAYER_STOPPED_MOVING") or (event == "PLAYER_ENTERING_WORLD") then 
		self.FadeTimer.alpha = self.Canvas:GetAlpha()
		self.FadeTimer.fadeDirection = "IN"
		self.FadeTimer.isFading = true
		self.FadeTimer:SetScript("OnUpdate", OnUpdate)
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
end 

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
	local Coordinates = self.Container.Child:CreateFontString()
	Coordinates:SetFontObject(Game13Font_o1)
	Coordinates:SetAlpha(.85)
	Coordinates:SetPoint("BOTTOM", 0, 20)

	local CoordinateTimer = CreateFrame("Frame", nil, self.Canvas)
	CoordinateTimer.elapsed = 0
	CoordinateTimer.Canvas = self.Canvas
	CoordinateTimer.Coordinates = Coordinates
	CoordinateTimer:SetScript("OnUpdate", function(self, elapsed)
		self.elapsed = self.elapsed + elapsed
		if (self.elapsed < .05) then 
			return 
		end 

		local x, y, pos
		if (self.Canvas:IsMouseOver(0, 0, 0, 0)) then 
			pos = MOUSE_LABEL
			x, y = self.Canvas:GetNormalizedCursorPosition()
		else
			local mapID = GetBestMapForUnit("player")
			if mapID then 
				pos = PLAYER
				local mapPosObject = GetPlayerMapPosition(mapID, "player")
				if mapPosObject then 
					x, y = mapPosObject:GetXY()
				end 
			end 
		end 
		if (x and y and pos) then 
			self.Coordinates:SetFormattedText("%s %s", GetFormattedCoordinates(x, y))
		else 
			self.Coordinates:SetText("")
		end 
	end)
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
