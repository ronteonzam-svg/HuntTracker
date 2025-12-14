local HuntTracker = CreateFrame("Frame", "HuntTrackerFrame")

-- Проверяем класс персонажа
local _, playerClass = UnitClass("player")
if playerClass ~= "HUNTER" then
    return
end

-- Настройки
local settings
local defaults = {
    enabled = true,
    minimapButtonAngle = 200,
}

-- Таблицы типов существ
local creatureTypeKey = {
    ["Beast"] = "Beast", ["Humanoid"] = "Humanoid", ["Undead"] = "Undead",
    ["Elemental"] = "Elemental", ["Demon"] = "Demon", ["Giant"] = "Giant",
    ["Dragonkin"] = "Dragonkin",
    ["Зверь"] = "Beast", ["Животное"] = "Beast", ["Животные"] = "Beast",
    ["Гуманоид"] = "Humanoid", ["Нежить"] = "Undead",
    ["Элементаль"] = "Elemental", ["Демон"] = "Demon",
    ["Великан"] = "Giant", ["Драконид"] = "Dragonkin",
    ["Дракон"] = "Dragonkin", ["Драконы"] = "Dragonkin",
}

local trackingNamePatterns = {
    Beast = { "beast", "звер", "животн" },
    Humanoid = { "humanoid", "гуманоид" },
    Undead = { "undead", "нежит" },
    Elemental = { "elemental", "элементал" },
    Demon = { "demon", "демон" },
    Giant = { "giant", "великан" },
    Dragonkin = { "dragon", "дракон" },
}

local trackIndexByKey = {}

-- === ПЕРЕМЕННЫЕ СОСТОЯНИЯ ===
local savedTrackingIndex = nil 
local targetTrackingID = nil
local checkTimer = 0

-- === ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ===

local function GetCurrentTrackingID()
    local count = GetNumTrackingTypes()
    for i = 1, count do
        local _, _, active = GetTrackingInfo(i)
        if active then return i end
    end
    return 0 
end

local function BuildTrackingTable()
    wipe(trackIndexByKey)
    local count = GetNumTrackingTypes()
    for i = 1, count do
        local name, _, _, category = GetTrackingInfo(i)
        if name and category == "spell" then
            local lowerName = string.lower(name)
            for key, patterns in pairs(trackingNamePatterns) do
                for _, pat in ipairs(patterns) do
                    if string.find(lowerName, pat) then
                        trackIndexByKey[key] = i
                        break
                    end
                end
            end
        end
    end
end

local function GetWantedIndexForTarget()
    if not UnitExists("target") then return nil end
    if UnitIsDead("target") then return nil end
    if not UnitCanAttack("player", "target") then return nil end

    local cType = UnitCreatureType("target")
    if not cType then return nil end
    
    local key = creatureTypeKey[cType]
    if not key then return nil end
    
    return trackIndexByKey[key]
end

-- === ОСНОВНАЯ ЛОГИКА ===

local function UpdateLogic()
    if not settings or not settings.enabled then return end

    local currentID = GetCurrentTrackingID()
    local wantedID = GetWantedIndexForTarget()

    if wantedID then
        if savedTrackingIndex == nil then
            savedTrackingIndex = currentID 
        end
        targetTrackingID = wantedID
    else
        if savedTrackingIndex ~= nil then
            targetTrackingID = savedTrackingIndex
        else
            targetTrackingID = nil
        end
    end
end

-- === МИНИКАРТА ===
local minimapButton = CreateFrame("Button", "HuntTrackerMinimapButton", Minimap)
minimapButton:SetFrameStrata("MEDIUM")
minimapButton:SetSize(31, 31)
minimapButton:SetFrameLevel(8)
minimapButton:RegisterForClicks("RightButtonUp")
minimapButton:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

local icon = minimapButton:CreateTexture(nil, "BACKGROUND")
icon:SetSize(20, 20)
icon:SetPoint("CENTER", 0, 1)
icon:SetTexture("Interface\\Icons\\Ability_Hunter_FocusedAim")

local overlay = minimapButton:CreateTexture(nil, "OVERLAY")
overlay:SetSize(53, 53)
overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
overlay:SetPoint("TOPLEFT")

local function UpdateMinimapButtonPosition()
    local angle = math.rad(settings.minimapButtonAngle)
    local x = math.cos(angle) * 80
    local y = math.sin(angle) * 80
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function UpdateMinimapIcon()
    if settings.enabled then
        icon:SetDesaturated(false)
    else
        icon:SetDesaturated(true)
        savedTrackingIndex = nil 
        targetTrackingID = nil
    end
end

minimapButton:SetScript("OnClick", function(self, button)
    if button == "RightButton" then
        if not settings then return end
        settings.enabled = not settings.enabled
        UpdateMinimapIcon()
        if settings.enabled then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00HuntTracker: Включено|r")
            UpdateLogic()
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffff0000HuntTracker: Выключено|r")
        end
    end
end)

minimapButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("HuntTracker")
    if settings.enabled then
        GameTooltip:AddLine("|cff00ff00ВКЛЮЧЕНО|r")
    else
        GameTooltip:AddLine("|cffff0000ВЫКЛЮЧЕНО|r")
    end
    GameTooltip:Show()
end)

minimapButton:SetScript("OnLeave", function(self) GameTooltip:Hide() end)

minimapButton:SetScript("OnMouseDown", function(self, button)
    if button == "LeftButton" and IsShiftKeyDown() then self.dragging = true end
end)

minimapButton:SetScript("OnMouseUp", function(self, button)
    if button == "LeftButton" then
        self.dragging = false
        if settings then settings.minimapButtonAngle = math.deg(math.atan2(GetCursorPosition())) end
    end
end)

-- === ON UPDATE: СЕРДЦЕ АДДОНА (SILENT MODE) ===
minimapButton:SetScript("OnUpdate", function(self, elapsed)
    if self.dragging then
        local mx, my = Minimap:GetCenter()
        local px, py = GetCursorPosition()
        local scale = Minimap:GetEffectiveScale()
        px, py = px / scale, py / scale
        local angle = math.deg(math.atan2(py - my, px - mx))
        settings.minimapButtonAngle = angle
        UpdateMinimapButtonPosition()
    end

    if not settings or not settings.enabled then return end

    if targetTrackingID then
        checkTimer = checkTimer + elapsed
        if checkTimer >= 0.5 then
            checkTimer = 0
            
            local currentID = GetCurrentTrackingID()
            
            if currentID ~= targetTrackingID then
                -- Глушим ошибки UI и Звуки
                local origSFX = GetCVar("Sound_EnableSFX")
                UIErrorsFrame:UnregisterEvent("UI_ERROR_MESSAGE")
                SetCVar("Sound_EnableSFX", "0") -- Выключаем звук ошибок
                
                -- Пытаемся сменить
                if targetTrackingID == 0 then
                    if currentID ~= 0 then SetTracking(currentID) end
                    savedTrackingIndex = nil
                    targetTrackingID = nil
                else
                    SetTracking(targetTrackingID)
                end
                
                -- Возвращаем все обратно
                SetCVar("Sound_EnableSFX", origSFX)
                UIErrorsFrame:RegisterEvent("UI_ERROR_MESSAGE")
            else
                if savedTrackingIndex == currentID then
                    savedTrackingIndex = nil
                    targetTrackingID = nil 
                end
            end
        end
    else
        checkTimer = 0
    end
end)

-- === СОБЫТИЯ ===
HuntTracker:SetScript("OnEvent", function(self, event, unit)
    if event == "PLAYER_LOGIN" then
        if not HuntTrackerDB then HuntTrackerDB = {} end
        for k, v in pairs(defaults) do
            if HuntTrackerDB[k] == nil then HuntTrackerDB[k] = v end
        end
        settings = HuntTrackerDB
        BuildTrackingTable()
        UpdateMinimapButtonPosition()
        UpdateMinimapIcon()
    elseif event == "PLAYER_ENTERING_WORLD" then
        BuildTrackingTable()
    elseif event == "PLAYER_TARGET_CHANGED" or event == "PLAYER_REGEN_ENABLED" then
        UpdateLogic()
        checkTimer = 1 -- форсируем немедленную проверку
    end
end)

HuntTracker:RegisterEvent("PLAYER_LOGIN")
HuntTracker:RegisterEvent("PLAYER_ENTERING_WORLD")
HuntTracker:RegisterEvent("PLAYER_TARGET_CHANGED")
HuntTracker:RegisterEvent("PLAYER_REGEN_ENABLED")
