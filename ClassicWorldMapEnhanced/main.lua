local ADDON = ...

local Private = CreateFrame("Frame")
Private:SetScript("OnEvent", function(self, event, ...) self:OnEvent(event, ...) end)
Private:RegisterEvent("ADDON_LOADED")

-- Lua API
local string_lower = string.lower

-- WoW API
local GetAddOnEnableState = GetAddOnEnableState
local GetAddOnInfo = GetAddOnInfo 
local GetNumAddOns = GetNumAddOns
local IsAddOnLoaded = IsAddOnLoaded
local UnitName = UnitName

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
	end
end

Private.OnInit = function(self)
	-- Just bail out if AzeriteUI is enabled. 
	if Private:IsAddOnEnabled("AzeriteUI_Classic") then 
		return 
	end

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
	-- This is the real default size too
	local mapW,mapH = 1024,768 
	local canvasW,canvasH = mapW - (11 + 11), mapH - (-70-30)

	local Canvas = WorldMapFrame
	Canvas.BlackoutFrame:Hide()
	Canvas:SetSize(mapW,mapH)
	Canvas:SetIgnoreParentScale(false)
	Canvas:RefreshDetailLayers()

	-- Contains the actual map. 
	local Container = WorldMapFrame.ScrollContainer
	Container.GetCanvasScale = function(self)
		return self:GetScale()
	end

	local Saturate = Saturate
	Container.NormalizeUIPosition = function(self, x, y)
		return Saturate(self:NormalizeHorizontalSize(x / self:GetCanvasScale() - self.Child:GetLeft())),
		       Saturate(self:NormalizeVerticalSize(self.Child:GetTop() - y / self:GetCanvasScale()))
	end

	Container.GetCursorPosition = function(self)
		local currentX, currentY = GetCursorPosition()
		local scale = UIParent:GetScale()
		if not(currentX and currentY and scale) then 
			return 0,0
		end 
		local scaledX, scaledY = currentX/scale, currentY/scale
		return scaledX, scaledY
	end

	Container.GetNormalizedCursorPosition = function(self)
		local x,y = self:GetCursorPosition()
		return self:NormalizeUIPosition(x,y)
	end

	local frame = CreateFrame("Frame")
	frame.elapsed = 0
	frame.stopAlpha = .9
	frame.moveAlpha = .65
	frame.stepIn = .05
	frame.stepOut = .05
	frame.throttle = .02
	frame:SetScript("OnEvent", function(selv, event) 
		if (event == "PLAYER_STARTED_MOVING") then 
			frame.alpha = Canvas:GetAlpha()
			frame:SetScript("OnUpdate", frame.Starting)

		elseif (event == "PLAYER_STOPPED_MOVING") or (event == "PLAYER_ENTERING_WORLD") then 
			frame.alpha = Canvas:GetAlpha()
			frame:SetScript("OnUpdate", frame.Stopping)
		end
	end)

	frame.Stopping = function(self, elapsed) 
		self.elapsed = self.elapsed + elapsed
		if (self.elapsed < frame.throttle) then
			return 
		end 
		if (frame.alpha + frame.stepIn < frame.stopAlpha) then 
			frame.alpha = frame.alpha + frame.stepIn
		else 
			frame.alpha = frame.stopAlpha
			frame:SetScript("OnUpdate", nil)
		end 
		Canvas:SetAlpha(frame.alpha)
	end

	frame.Starting = function(self, elapsed) 
		self.elapsed = self.elapsed + elapsed
		if (self.elapsed < frame.throttle) then
			return 
		end 
		if (frame.alpha - frame.stepOut > frame.moveAlpha) then 
			frame.alpha = frame.alpha - frame.stepOut
		else 
			frame.alpha = frame.moveAlpha
			frame:SetScript("OnUpdate", nil)
		end 
		Canvas:SetAlpha(frame.alpha)
	end

	frame:RegisterEvent("PLAYER_ENTERING_WORLD")
	frame:RegisterEvent("PLAYER_STARTED_MOVING")
	frame:RegisterEvent("PLAYER_STOPPED_MOVING")

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
