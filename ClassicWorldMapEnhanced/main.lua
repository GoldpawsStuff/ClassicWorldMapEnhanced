-- Retrieve the folder name of this addon 
-- as used by events fired upon addon loading.
local ADDON = ...

-- Create a frame and use this as both 
-- the addon object and our event handler. 
local Private = CreateFrame("Frame")
Private:SetScript("OnEvent", function(self, event, ...) self:OnEvent(event, ...) end)
Private:RegisterEvent("ADDON_LOADED")

-- Lua API
local ipairs = ipairs
local math_ceil = math.ceil
local math_floor = math.floor
local math_mod = math.fmod
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
		["Fog of War"] = true
	}
})

-- Default settings
-- These will be overwritten by saved settings, 
-- so don't edit anything here. 
ClassicWorldMapEnhanced_DB = {
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

-- Zone Levels & Factions
-- Using: https://wow.gamepedia.com/Zones_by_level_(Classic)
----------------------------------------------------
local zoneData = {

	-- Eastern Kingdoms
	[1416] = { min = 30, max = 40 }, 						-- Alterac Mountains
	[1417] = { min = 30, max = 40 }, 						-- Arathi Highlands
	[1418] = { min = 35, max = 45 }, 						-- Badlands
	[1419] = { min = 45, max = 55 }, 						-- Blasted Lands
	[1428] = { min = 50, max = 58 }, 						-- Burning Steppes
	[1430] = { min = 55, max = 60 }, 						-- Deadwind Pass
	[1426] = { min =  1, max = 10, faction = "Alliance" }, 	-- Dun Morogh
	[1431] = { min = 18, max = 30 }, 						-- Duskwood
	[1423] = { min = 53, max = 60 }, 						-- Eastern Plaguelands
	[1429] = { min =  1, max = 10, faction = "Alliance" }, 	-- Elwynn Forest
	[1424] = { min = 20, max = 35 }, 						-- Hillsbrad Foothills
	[1432] = { min = 10, max = 20, faction = "Alliance" }, 	-- Loch Modan
	[1433] = { min = 15, max = 25 }, 						-- Redridge Mountains
	[1427] = { min = 45, max = 50 }, 						-- Searing Gorge
	[1421] = { min = 10, max = 20, faction = "Horde" }, 	-- Silverpine Forest
	[1434] = { min = 30, max = 45 }, 						-- Stranglethorn Vale
	[1435] = { min = 35, max = 45 }, 						-- Swamp of Sorrows
	[1425] = { min = 40, max = 50 }, 						-- The Hinterlands
	[1420] = { min =  1, max = 10, faction = "Horde" }, 	-- Tirisfal Glades
	[1436] = { min = 10, max = 20, faction = "Alliance" }, 	-- Westfall
	[1422] = { min = 51, max = 58 }, 						-- Western Plaguelands
	[1437] = { min = 20, max = 30 }, 						-- Wetlands

	-- Kalimdor
	[1440] = { min = 18, max = 30 }, 						-- Ashenvale
	[1447] = { min = 45, max = 55 }, 						-- Azshara
	[1439] = { min = 10, max = 20, faction = "Alliance" }, 	-- Darkshore
	[1443] = { min = 30, max = 40 }, 						-- Desolace
	[1411] = { min =  1, max = 10, faction = "Horde" }, 	-- Durotar
	[1445] = { min = 35, max = 45 }, 						-- Dustwallow Marsh
	[1448] = { min = 48, max = 55 }, 						-- Felwood
	[1444] = { min = 40, max = 50 }, 						-- Feralas
	[1450] = { min = 55, max = 60 }, 						-- Moonglade
	[1412] = { min =  1, max = 10, faction = "Horde" }, 	-- Mulgore
	[1451] = { min = 55, max = 60 }, 						-- Silithus
	[1442] = { min = 15, max = 27 }, 						-- Stonetalon Mountains
	[1446] = { min = 40, max = 50 }, 						-- Tanaris
	[1438] = { min =  1, max = 10, faction = "Alliance" }, 	-- Teldrassil
	[1413] = { min = 10, max = 25, faction = "Horde" }, 	-- The Barrens
	[1441] = { min = 24, max = 35 }, 						-- Thousand Needles
	[1449] = { min = 48, max = 55 }, 						-- Un'Goro Crater
	[1452] = { min = 55, max = 60 }  						-- Winterspring
}

----------------------------------------------------------------------
-- wow.tools/api/export/?name=worldmapoverlay&build=1.13.2.31727
-- wow.tools/api/export/?name=worldmapoverlaytile&build=1.13.2.31727
----------------------------------------------------------------------
local zoneReveal = {
	[1194] = {
		["128:110:464:33"] = "271427",
		["160:120:413:476"] = "2212659",
		["160:190:474:384"] = "271426",
		["190:180:462:286"] = "271440",
		["190:200:327:60"] = "271439",
		["200:240:549:427"] = "271437",
		["210:160:427:78"] = "271428",
		["215:215:355:320"] = "271443",
		["220:230:432:170"] = "271421",
		["230:230:301:189"] = "271422",
		["445:160:244:0"] = "271435, 271442"
	},
	[1200] = {
		["128:120:473:260"] = "272185",
		["128:155:379:242"] = "272178",
		["128:205:303:307"] = "272176",
		["170:128:458:369"] = "272180",
		["185:128:291:0"] = "272172",
		["205:128:395:0"] = "272179",
		["205:230:502:16"] = "272169",
		["210:180:255:214"] = "272181",
		["215:240:428:80"] = "272177",
		["225:235:532:238"] = "272186",
		["256:190:523:356"] = "272170",
		["256:200:367:303"] = "272173",
		["280:240:249:59"] = "272187, 272171",
		["470:243:270:425"] = "272168, 272165"
	},
	[1202] = {
		["100:165:564:52"] = "270569",
		["115:110:507:294"] = "852702",
		["120:110:555:0"] = "270553",
		["120:125:384:115"] = "270560",
		["125:115:492:63"] = "270584",
		["125:125:556:189"] = "270585",
		["125:165:442:298"] = "852696",
		["128:100:412:0"] = "852705",
		["128:105:419:63"] = "270554",
		["128:128:306:130"] = "852699",
		["128:128:341:537"] = "852704",
		["128:128:431:479"] = "852694",
		["140:128:498:119"] = "270574",
		["145:125:365:350"] = "852697",
		["150:120:527:307"] = "852701",
		["155:115:407:553"] = "852703",
		["155:128:335:462"] = "852695",
		["155:128:481:211"] = "270565",
		["155:155:431:118"] = "270559",
		["170:120:456:0"] = "270564",
		["175:185:365:177"] = "852700",
		["200:145:317:29"] = "270572",
		["200:185:340:234"] = "852693",
		["210:150:355:402"] = "852698",
		["95:100:581:247"] = "270573"
	},
	[1205] = {
		["160:175:225:478"] = "768731",
		["165:197:314:471"] = "768752",
		["190:170:317:372"] = "768732",
		["195:288:399:380"] = "768721, 768722",
		["200:200:406:279"] = "768730",
		["220:280:196:131"] = "768738, 769205",
		["235:200:462:77"] = "768753",
		["255:255:270:197"] = "768739",
		["255:320:462:307"] = "768744, 768745",
		["280:240:334:162"] = "768723, 769200",
		["285:230:276:0"] = "768728, 768729",
		["300:300:26:262"] = "769201, 769202, 769203, 769204",
		["330:265:44:403"] = "768734, 768735, 768736, 768737",
		["350:370:626:253"] = "768717, 768718, 768719, 768720",
		["370:300:549:105"] = "768748, 768749, 768750, 768751"
	},
	[1206] = {
		["160:230:558:112"] = "270360",
		["170:155:419:293"] = "2212546",
		["175:225:370:186"] = "270352",
		["180:210:472:165"] = "270350",
		["190:210:138:54"] = "270347",
		["190:240:87:138"] = "2212539",
		["200:220:355:412"] = "270348",
		["205:250:655:120"] = "270336",
		["210:185:286:310"] = "270346",
		["215:210:559:333"] = "270353",
		["215:235:432:362"] = "270342",
		["230:195:531:276"] = "270343",
		["230:240:192:90"] = "270351",
		["240:230:108:287"] = "270358",
		["245:245:232:145"] = "270349",
		["256:215:171:424"] = "270361"
	},
	[1207] = {
		["195:200:325:148"] = "270543",
		["200:195:445:120"] = "270532",
		["220:220:551:48"] = "270530",
		["230:230:349:256"] = "2212608",
		["240:255:0:148"] = "2212593",
		["245:205:389:7"] = "2212606",
		["245:205:498:209"] = "2212592",
		["255:205:17:310"] = "270529",
		["255:220:12:428"] = "270520",
		["255:280:501:341"] = "270540, 270527",
		["265:270:345:389"] = "270522, 270550, 270528, 270536",
		["270:275:159:199"] = "270525, 270521, 2212603, 2212605",
		["285:240:148:384"] = "2212599, 2212601",
		["370:455:611:110"] = "270534, 270551, 270546, 270535"
	},
	[1209] = {
		["170:145:405:123"] = "391431",
		["170:200:472:9"] = "391433",
		["185:155:310:133"] = "391425",
		["185:190:559:30"] = "391432",
		["195:180:361:15"] = "391435",
		["225:170:501:140"] = "391430",
		["245:195:361:195"] = "391434",
		["265:220:453:259"] = "391437, 391436",
		["384:450:212:178"] = "391429, 391428, 391427, 391426"
	},
	[1210] = {
		["128:158:537:299"] = "273015",
		["150:128:474:327"] = "273016",
		["173:128:694:289"] = "273000",
		["174:220:497:145"] = "273020",
		["175:247:689:104"] = "272996",
		["186:128:395:277"] = "2213434",
		["201:288:587:139"] = "273009, 273002",
		["211:189:746:125"] = "2213425",
		["216:179:630:326"] = "273006",
		["230:205:698:362"] = "2213418",
		["237:214:757:205"] = "272999",
		["243:199:363:349"] = "273003",
		["245:205:227:328"] = "273001",
		["256:156:239:250"] = "273017",
		["256:210:335:139"] = "273019",
		["315:235:463:361"] = "2213428, 2213430"
	},
	[1211] = {
		["140:125:391:446"] = "2213067",
		["160:170:470:261"] = "272598",
		["165:185:382:252"] = "272616",
		["175:165:402:65"] = "2213080",
		["180:128:323:128"] = "2213065",
		["180:185:457:144"] = "2213082",
		["185:165:286:37"] = "272610",
		["210:160:352:168"] = "272620",
		["210:215:379:447"] = "272609",
		["220:160:364:359"] = "272613",
		["240:180:491:417"] = "272599",
		["240:240:494:262"] = "272614",
		["250:215:593:74"] = "272600",
		["256:160:465:0"] = "2213063",
		["256:220:459:13"] = "2213084"
	},
	[1212] = {
		["160:125:300:311"] = "273113",
		["160:200:566:198"] = "273121",
		["170:165:600:412"] = "273107",
		["170:190:451:323"] = "273102",
		["180:205:520:250"] = "273094",
		["205:340:590:86"] = "273122, 273103",
		["220:150:381:265"] = "2212523",
		["220:180:382:164"] = "273114",
		["225:185:137:293"] = "273120",
		["285:230:260:355"] = "2212522, 2212521",
		["300:206:355:462"] = "273108, 273101",
		["340:288:307:16"] = "273095, 273111, 273100, 273090",
		["370:270:504:343"] = "273119, 273092, 273112, 273093"
	},
	[1213] = {
		["165:160:537:367"] = "271544",
		["175:245:716:299"] = "271533",
		["180:160:592:241"] = "271542",
		["185:150:172:477"] = "271512",
		["190:205:620:128"] = "271520",
		["190:205:79:98"] = "271522",
		["195:275:620:291"] = "271543, 271530",
		["200:205:156:360"] = "271551",
		["205:165:291:401"] = "271548",
		["205:165:614:30"] = "271554",
		["205:250:409:345"] = "2212700",
		["210:179:309:489"] = "271514",
		["210:210:271:261"] = "271536",
		["220:360:7:231"] = "2212705, 2212706",
		["225:215:722:166"] = "271537",
		["230:150:422:36"] = "271535",
		["230:235:442:199"] = "271523",
		["240:195:457:109"] = "271521",
		["240:200:194:9"] = "271529",
		["245:170:717:471"] = "271553",
		["250:175:537:463"] = "271532",
		["360:270:169:83"] = "271518, 271527, 2212703, 2212704"
	},
	[1214] = {
		["125:100:109:482"] = "271904",
		["165:200:175:275"] = "2212736",
		["205:155:414:154"] = "271897",
		["215:240:541:236"] = "2212742",
		["220:310:509:0"] = "271894, 2212744",
		["230:320:524:339"] = "2212737, 2212738",
		["235:270:418:201"] = "271905, 2212743",
		["240:275:637:294"] = "271885, 271877",
		["285:155:208:368"] = "2212746, 2212747",
		["288:225:2:192"] = "271876, 271881",
		["305:275:198:155"] = "271883, 271892, 2212739, 2212740",
		["384:365:605:75"] = "271872, 271898, 271882, 271891"
	},
	[1215] = {
		["145:220:158:149"] = "271927",
		["160:145:512:232"] = "271933",
		["170:170:319:302"] = "271934",
		["170:310:693:303"] = "271938, 271916",
		["180:170:408:260"] = "271929",
		["185:195:237:185"] = "271928",
		["195:185:240:387"] = "271937",
		["200:165:373:365"] = "271922",
		["205:195:374:164"] = "271910",
		["225:200:171:306"] = "770218",
		["235:285:505:333"] = "271912, 271920",
		["255:205:13:245"] = "271917",
		["275:275:509:19"] = "271908, 271935, 271936, 271909",
		["280:205:571:239"] = "271915, 271921"
	},
	[1216] = {
		["115:115:252:249"] = "2212640",
		["125:125:217:287"] = "271398",
		["128:120:792:279"] = "2212654",
		["128:128:573:280"] = "271389",
		["128:165:502:221"] = "2212651",
		["128:165:759:173"] = "2212653",
		["128:180:281:167"] = "271392",
		["128:190:347:163"] = "271418",
		["150:128:295:385"] = "271406",
		["155:128:522:322"] = "271401",
		["155:170:694:273"] = "271409",
		["165:165:608:291"] = "271408",
		["180:128:274:296"] = "2212641",
		["180:165:166:184"] = "2212644",
		["200:185:314:311"] = "271400",
		["200:200:386:294"] = "271417",
		["240:185:155:403"] = "2212639",
		["315:200:397:163"] = "271410, 271396"
	},
	[1220] = {
		["275:235:77:366"] = "254503, 254504",
		["305:220:494:300"] = "2201968, 2201949",
		["305:230:545:407"] = "254527, 254528",
		["360:280:247:388"] = "2201972, 2201970, 2201969, 2201971",
		["405:430:85:30"] = "254509, 254510, 254511, 254512",
		["425:325:250:170"] = "254529, 254530, 254531, 254532",
		["460:365:422:8"] = "254505, 254506, 254507, 254508"
	},
	[1224] = {
		["220:225:707:168"] = "270927",
		["225:220:36:109"] = "270938",
		["245:265:334:114"] = "270912, 270909",
		["256:280:173:101"] = "270919, 270911",
		["270:285:513:99"] = "270922, 270934, 270923, 270937",
		["270:310:589:279"] = "270920, 270914, 270908, 270929",
		["280:355:722:46"] = "270944, 270910, 270935, 270945",
		["294:270:708:311"] = "270906, 270918, 270936, 270942",
		["320:270:377:285"] = "270933, 270943, 270921, 270928",
		["415:315:56:258"] = "270941, 270925, 270926, 270917"
	},
	[1228] = {
		["225:220:422:332"] = "271560",
		["240:220:250:270"] = "271567",
		["255:250:551:292"] = "271573",
		["256:210:704:330"] = "271578",
		["256:237:425:431"] = "271582",
		["256:240:238:428"] = "271576",
		["256:249:577:419"] = "271559",
		["256:256:381:147"] = "271572",
		["256:341:124:327"] = "2212708, 2212709",
		["306:233:696:435"] = "271557, 271583",
		["310:256:587:190"] = "271584, 271565",
		["485:405:0:0"] = "2212713, 2212714, 2212715, 2212716"
	},
	[1233] = {
		["270:270:426:299"] = "271092, 271085, 271086, 271089",
		["300:245:269:337"] = "271095, 271079",
		["380:365:249:76"] = "271075, 271076, 271080, 271081"
	},
	[1235] = {
		["160:330:19:132"] = "271453, 271454",
		["195:145:102:302"] = "2212669",
		["200:175:653:120"] = "271466",
		["220:220:690:353"] = "2212676",
		["220:340:504:117"] = "271470, 271477",
		["235:250:390:382"] = "271449",
		["250:230:539:369"] = "271455",
		["255:285:243:348"] = "271448, 271456",
		["275:250:55:342"] = "271444, 271483",
		["315:280:631:162"] = "271471, 271461, 271450, 271451",
		["350:300:85:149"] = "271473, 271463, 271467, 271464",
		["360:420:298:79"] = "2212678, 2212679, 2212680, 2212681",
		["910:210:89:31"] = "271481, 271460, 271474, 271468"
	},
	[1236] = {
		["195:250:109:370"] = "252899",
		["230:300:125:12"] = "252882, 252883",
		["235:270:229:11"] = "252884, 2212852",
		["255:285:215:348"] = "252886, 252887",
		["256:230:217:203"] = "252898",
		["290:175:339:11"] = "2212855, 2212856",
		["295:358:309:310"] = "252862, 252863, 2212828, 2212829",
		["315:235:542:48"] = "252880, 252881",
		["320:410:352:87"] = "252894, 252895, 252896, 252897",
		["345:256:482:321"] = "252866, 252867",
		["370:295:546:199"] = "252890, 252891, 252892, 252893"
	},
	[1237] = {
		["235:270:399:129"] = "272334, 2212936",
		["250:250:654:161"] = "272372",
		["255:300:500:215"] = "2212977, 2212978",
		["275:256:277:0"] = "272357, 272342",
		["320:210:595:320"] = "272347, 272371",
		["340:195:83:197"] = "272351, 272340",
		["365:245:121:72"] = "272362, 272356",
		["365:350:0:284"] = "272364, 272348, 272358, 272359",
		["430:290:187:333"] = "272344, 272354, 272350, 272339",
		["465:255:484:361"] = "272369, 272363",
		["535:275:133:240"] = "272335, 272343, 2212940, 2212942, 2212943, 2212945"
	},
	[1238] = {
		["105:110:311:131"] = "2213161",
		["105:125:387:64"] = "2213191",
		["110:105:260:132"] = "2213150",
		["110:110:306:301"] = "2213171",
		["110:140:371:129"] = "2213145",
		["115:115:156:42"] = "2213197",
		["120:120:345:276"] = "2213148",
		["125:120:314:493"] = "2213152",
		["125:125:280:368"] = "2213159",
		["125:140:196:3"] = "2213173",
		["128:125:331:59"] = "2213158",
		["128:125:364:231"] = "2213194",
		["128:175:432:94"] = "2213162",
		["140:110:269:26"] = "2213165",
		["145:128:203:433"] = "2213147",
		["155:150:388:0"] = "2213156",
		["165:175:194:284"] = "2213146",
		["165:190:229:422"] = "2213192",
		["170:125:394:212"] = "2213174",
		["170:90:284:0"] = "2213168",
		["190:175:152:90"] = "2213188",
		["200:185:235:189"] = "2213187",
		["245:220:483:8"] = "2213196",
		["90:115:211:359"] = "2213164",
		["90:80:241:92"] = "2213143",
		["95:95:299:88"] = "2213154",
		["95:95:350:335"] = "2213170"
	},
	[1239] = {
		["215:365:724:120"] = "272739, 272746",
		["235:205:171:145"] = "272736",
		["240:245:0:262"] = "2213206",
		["245:305:0:140"] = "272759, 272750",
		["256:668:746:0"] = "272756, 272737, 272769",
		["275:240:129:236"] = "272747, 272763",
		["300:275:565:218"] = "272772, 272760, 2213215, 2213216",
		["315:235:286:110"] = "272768, 272770",
		["345:250:552:378"] = "272740, 272773",
		["360:315:279:237"] = "272742, 272751, 272752, 272764",
		["365:305:492:0"] = "2213200, 2213202, 2213203, 2213204"
	},
	[1240] = {
		["165:200:488:0"] = "273143",
		["195:240:442:241"] = "273137",
		["200:185:208:375"] = "273142",
		["200:240:524:252"] = "273125",
		["210:215:387:11"] = "273145",
		["215:215:307:29"] = "2212528",
		["220:200:317:331"] = "273130",
		["225:205:328:148"] = "273126",
		["225:210:459:105"] = "273146",
		["225:256:220:102"] = "273149",
		["256:175:339:418"] = "273124",
		["280:190:205:467"] = "273141, 2212527",
		["288:235:523:377"] = "273131, 273134",
		["305:210:204:260"] = "273129, 273133"
	},
	[1243] = {
		["175:128:13:314"] = "273156",
		["185:240:456:125"] = "2212531",
		["190:160:628:176"] = "273181",
		["195:185:247:205"] = "273155",
		["200:185:349:115"] = "273173",
		["200:240:237:41"] = "2212533",
		["205:180:401:21"] = "273164",
		["205:245:527:264"] = "273177",
		["225:185:347:218"] = "273159",
		["225:190:89:142"] = "273171",
		["230:190:470:371"] = "273174",
		["240:175:77:245"] = "273163",
		["256:250:507:115"] = "2212535",
		["300:240:92:82"] = "273178, 273167",
		["350:360:611:230"] = "2213613, 2213614, 2212532, 2212534"
	},
	[1244] = {
		["128:100:494:548"] = "2213328",
		["128:190:335:313"] = "272807",
		["160:210:382:281"] = "272826",
		["170:240:272:127"] = "272830",
		["180:256:377:93"] = "272822",
		["185:128:368:443"] = "272814",
		["190:128:462:323"] = "2213323",
		["200:200:561:292"] = "272815",
		["225:225:491:153"] = "272811",
		["256:185:436:380"] = "272810",
		["315:256:101:247"] = "272806, 272812"
	},
	[1247] = {
		["150:215:318:162"] = "769206",
		["170:195:468:85"] = "769211",
		["175:158:329:510"] = "271044",
		["175:183:229:485"] = "769210",
		["180:195:365:181"] = "769207",
		["190:205:324:306"] = "271045",
		["195:215:510:0"] = "271043",
		["200:170:305:412"] = "769209",
		["230:190:375:94"] = "769208"
	},
	[1248] = {
		["128:195:131:137"] = "270380",
		["146:200:856:151"] = "270387",
		["155:150:260:373"] = "270398",
		["165:175:189:324"] = "2212540",
		["180:245:520:238"] = "270402",
		["200:160:796:311"] = "270390",
		["200:205:392:218"] = "2212541",
		["205:185:272:251"] = "270386",
		["210:185:463:141"] = "270400",
		["215:305:205:38"] = "2212542, 2212543",
		["220:195:104:259"] = "2212548",
		["225:255:597:258"] = "270401",
		["235:205:547:426"] = "270375",
		["245:245:19:28"] = "270376",
		["245:255:713:344"] = "270405",
		["255:195:203:158"] = "270389",
		["275:240:356:347"] = "2212544, 2212545",
		["285:185:694:225"] = "270388, 2212547"
	},
	[1249] = {
		["190:190:31:155"] = "272968",
		["205:195:259:131"] = "272962",
		["210:180:205:70"] = "272963",
		["210:190:357:264"] = "272954",
		["210:195:391:192"] = "2213363",
		["240:220:492:250"] = "2213395",
		["250:240:179:200"] = "2213369",
		["305:310:0:0"] = "2213348, 2213349, 2213351, 2213352",
		["320:365:610:300"] = "2213371, 2213372, 2213374, 2213375"
	},
	[1250] = {
		["125:125:475:433"] = "2213093",
		["125:86:663:582"] = "272650",
		["145:107:572:561"] = "272628",
		["150:150:389:320"] = "272646",
		["190:97:718:571"] = "2213087",
		["200:215:390:145"] = "272624",
		["225:120:668:515"] = "2213088",
		["230:355:210:234"] = "272633, 272647",
		["270:205:247:0"] = "272632, 272641",
		["288:355:457:282"] = "272648, 272634, 272635, 272623",
		["320:275:553:197"] = "272630, 272649, 272642, 272636"
	},
	[1251] = {
		["100:100:241:6"] = "2212638",
		["170:160:555:181"] = "2212635",
		["190:220:447:102"] = "271111",
		["195:242:293:426"] = "271122",
		["200:250:554:0"] = "271114",
		["205:145:431:0"] = "271126",
		["205:195:690:444"] = "271105",
		["205:250:311:61"] = "2212632",
		["205:285:590:365"] = "2212636, 2212637",
		["220:220:607:215"] = "2212634",
		["230:230:167:389"] = "271125",
		["245:285:212:215"] = "271106, 271129",
		["275:250:387:244"] = "271127, 2212633",
		["285:245:625:33"] = "271104, 271124",
		["285:280:399:380"] = "271108, 271112, 271113, 271109"
	},
	[1252] = {
		["110:110:493:70"] = "2212732",
		["110:170:478:386"] = "2212728",
		["115:115:486:329"] = "2212726",
		["120:195:623:167"] = "2212729",
		["140:165:690:141"] = "271696",
		["145:320:404:256"] = "271700, 271682",
		["150:125:454:0"] = "2212721",
		["155:160:689:233"] = "271675",
		["180:180:208:234"] = "2212734",
		["190:155:305:0"] = "2212733",
		["190:250:540:320"] = "271699",
		["215:293:192:375"] = "2212730, 2212731",
		["225:180:751:198"] = "271680",
		["230:195:454:201"] = "271687",
		["240:220:618:298"] = "2212735",
		["285:245:319:75"] = "271705, 271686"
	},
	[1253] = {
		["200:195:660:21"] = "271494",
		["230:205:534:224"] = "271500",
		["250:315:422:0"] = "271507, 271504",
		["255:250:257:313"] = "2212689",
		["280:270:230:0"] = "2212685, 2212686, 2212687, 2212688",
		["285:240:367:381"] = "271503, 271509",
		["400:255:239:189"] = "2212683, 2212684"
	},
	[1254] = {
		["110:140:611:147"] = "2213315",
		["110:180:473:234"] = "272800",
		["120:135:533:104"] = "2213275",
		["150:160:291:434"] = "2213311",
		["155:150:561:256"] = "272789",
		["155:150:592:75"] = "2213281",
		["160:150:395:346"] = "272798",
		["160:190:629:220"] = "2213273",
		["165:180:509:168"] = "2213313",
		["175:165:421:91"] = "272774",
		["180:200:252:199"] = "272792",
		["185:250:203:286"] = "272781",
		["195:175:299:100"] = "272776",
		["195:210:323:359"] = "272784",
		["205:145:325:289"] = "272782",
		["205:157:445:511"] = "272801",
		["210:175:254:0"] = "272788",
		["215:175:499:293"] = "272795",
		["215:180:363:194"] = "272799",
		["220:210:449:372"] = "272805"
	},
	[1259] = {
		["120:155:818:107"] = "270434",
		["145:215:422:95"] = "2212573",
		["160:210:404:194"] = "270412",
		["190:200:681:153"] = "2212567",
		["200:150:77:331"] = "2212555",
		["215:175:84:229"] = "2212574",
		["220:255:191:369"] = "2212554",
		["225:180:35:422"] = "2212564",
		["235:140:478:44"] = "2212560",
		["235:270:250:106"] = "2212571, 2212572",
		["240:125:552:499"] = "270410",
		["240:155:499:119"] = "2212568",
		["245:185:644:40"] = "270432",
		["265:280:238:221"] = "270414, 2212561, 2212562, 2212563",
		["270:300:479:201"] = "2212550, 2212551, 2212552, 2212553",
		["315:200:296:429"] = "270409, 2212559",
		["370:220:389:353"] = "2212565, 2212566",
		["395:128:396:540"] = "2212569, 2212570",
		["570:170:366:0"] = "2212556, 2212557, 2212558"
	},
	[1260] = {
		["145:159:496:509"] = "271657",
		["160:145:548:90"] = "271653",
		["165:155:332:465"] = "271663",
		["175:135:408:533"] = "271658",
		["185:160:405:429"] = "271659",
		["195:170:330:29"] = "271652",
		["215:215:420:54"] = "271673",
		["235:145:292:263"] = "271666",
		["235:155:297:381"] = "271664",
		["235:200:307:123"] = "271665",
		["240:145:483:0"] = "271660",
		["245:128:271:331"] = "271669"
	},
	[1261] = {
		["285:285:582:67"] = "273051, 2213483, 2213484, 2213486",
		["295:270:367:178"] = "273042, 273065, 273050, 273036",
		["310:355:560:240"] = "273072, 273039, 273037, 273063",
		["315:345:121:151"] = "273043, 273075, 273069, 273061",
		["345:285:158:368"] = "273046, 273053, 273071, 273047",
		["345:285:367:380"] = "273059, 273066, 273073, 273054",
		["570:265:160:6"] = "273052, 273062, 273057, 273058, 2213490, 2213491"
	},
	[1263] = {
		["555:510:244:89"] = "252844, 252845, 252846, 252847, 2212870, 2212872"
	},
	[1264] = {
		["288:256:116:413"] = "272564, 272553",
		["320:256:344:197"] = "272573, 272545",
		["320:289:104:24"] = "272581, 272562, 2213052, 2213053",
		["384:384:500:65"] = "272580, 272544, 2213048, 2213049",
		["384:512:97:144"] = "272559, 272543, 272574, 272575",
		["512:320:265:12"] = "272565, 272566, 272577, 272546",
		["512:384:245:285"] = "272567, 272547, 272555, 272548"
	},
	[1266] = {
		["125:165:611:242"] = "273206",
		["145:125:617:158"] = "273200",
		["165:140:593:340"] = "273199",
		["165:200:509:107"] = "273191",
		["175:185:555:27"] = "273203",
		["185:160:392:137"] = "273207",
		["185:180:493:258"] = "273185",
		["200:160:523:376"] = "273198",
		["215:185:401:198"] = "273192",
		["230:120:229:243"] = "273187",
		["240:140:222:172"] = "273202",
		["250:180:368:7"] = "273184",
		["255:205:447:441"] = "2213650"
	},
	[1273] = {
		["235:290:399:375"] = "270314, 270315",
		["270:240:348:13"] = "270331, 270325",
		["300:300:335:172"] = "270320, 270321, 270322, 270323"
	}
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

	local mapID = WorldMapFrame.mapID
	if (not mapID) then
		return
	end

	local artID = GetMapArtID(mapID)
	if ((not artID) or (not zoneReveal[artID])) then
		return
	end

	local layers = GetMapArtLayers(mapID)
	local layerInfo = layers and layers[pin.layerIndex]
	if (not layerInfo) then
		return
	end

	local zoneMaps = zoneReveal[artID]
	local exploredMapTextures = GetExploredMapTextures(mapID)
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
		local mapID = map:GetMapID()
		local normalizedCursorX, normalizedCursorY = map:GetNormalizedCursorPosition()
		local positionMapInfo = C_Map.GetMapInfoAtPosition(mapID, normalizedCursorX, normalizedCursorY)	
		if (positionMapInfo and (positionMapInfo.mapID ~= mapID)) then
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
			name = MapUtil.FindBestAreaNameAtMouse(mapID, normalizedCursorX, normalizedCursorY)
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

-- Addon API
----------------------------------------------------
-- Set up the main worldmap frame.
Private.SetUpCanvas = function(self)
	-- Bring the map down to size.
	self.Canvas.BlackoutFrame:Hide()
	self.Canvas:SetIgnoreParentScale(false)
	self.Canvas:SetFrameStrata("MEDIUM")
	self.Canvas.BorderFrame:SetFrameStrata("MEDIUM")
	self.Canvas.BorderFrame:SetFrameLevel(1)
	self.Canvas:RefreshDetailLayers()
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
	self.FadeTimer.moveAlpha = .65
	self.FadeTimer.stepIn = .05
	self.FadeTimer.stepOut = .05
	self.FadeTimer.throttle = .02
	self.FadeTimer.Canvas = self.Canvas

	self:RegisterEvent("PLAYER_ENTERING_WORLD")
	self:RegisterEvent("PLAYER_STARTED_MOVING")
	self:RegisterEvent("PLAYER_STOPPED_MOVING")
end

-- Set up the coordinate display. 
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
	CoordinateTimer:SetScript("OnUpdate", OnUpdate_MapCoordinates)
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

	button:SetPoint("TOPRIGHT", -(24 + 10 + button.msg:GetWidth()), 0)
	button:SetHitRectInsets(0, 0 - button.msg:GetWidth(), 0, 0)
	button:SetChecked(not ClassicWorldMapEnhanced_DB.revealUnexploredAreas)
	button:SetScript("OnClick", function(self)
		ClassicWorldMapEnhanced_DB.revealUnexploredAreas = not button:GetChecked()
		Overlay_UpdateTextures()
	end)

	button:Show()

	for pin in WorldMapFrame:EnumeratePinsByTemplate("MapExplorationPinTemplate") do
		hooksecurefunc(pin, "RefreshOverlays", Overlay_RefreshTextures)
		pin.overlayTexturePool.resetterFunc = Overlay_ResetVertexColor
	end
end

-- Addon Init & Events
----------------------------------------------------
-- Our addon's event handler. Handles all events. 
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
	self.Container = WorldMapFrame.ScrollContainer
	self:SetUpCanvas()
	self:SetUpContainer()
	self:SetUpFading()
	self:SetUpCoordinates()
	self:SetUpZoneLevels()
	self:SetUpMapReveal()
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
		if string_lower(name) == target then
			if enabled then
				return true
			end
		end
	end
end
