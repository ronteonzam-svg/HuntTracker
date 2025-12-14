local HuntTracker = CreateFrame("Frame", "HuntTrackerFrame")

-- Проверяем класс персонажа
local _, playerClass = UnitClass("player")
if playerClass ~= "HUNTER" then
    return -- Если не охотник, выходим и не грузим аддон
end

-- SavedVariables (будет сохранено между /reload и выходом)
local settings -- ссылка на HuntTrackerDB после загрузки
local defaults = {
    enabled = true,
    minimapButtonAngle = 200,
}

-- Приводим локализованные типы существ к общему ключу
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
local wantedTrackingIndex = nil
local retryTimer = 0

local function BuildTrackingTable()
    wipe(trackIndexByKey)
    local count = GetNumTrackingTypes()
    for i = 1, count do
        local name, texture, active, category = GetTrackingInfo(i)
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
    if UnitIsFriend("player", "target") then return nil end
    if UnitIsDead("target") then return nil end
    local cType = UnitCreatureType("target")
    if not cType then return nil end
    local key = creatureTypeKey[cType]
    if not key then return nil end
    return trackIndexByKey[key]
end

local function TrySetTracking(idx)
    if not idx then return false end
    local currentTexture = GetTrackingTexture()
    local _, wantedTexture = GetTrackingInfo(idx)
    if currentTexture == wantedTexture then
        wantedTrackingIndex = nil
        return true
    end
    SetTracking(idx)
    currentTexture = GetTrackingTexture()
    if currentTexture == wantedTexture then
        wantedTrackingIndex = nil
        return true
    else
        wantedTrackingIndex = idx
        return false
    end
end

local function UpdateTracking()
    if not settings or not settings.enabled then return end
    local idx = GetWantedIndexForTarget()
    if idx then
        TrySetTracking(idx)
    else
        wantedTrackingIndex = nil
    end
end

local function RetryTracking()
    if wantedTrackingIndex and settings.enabled then
        TrySetTracking(wantedTrackingIndex)
    end
end

-- Создание миникарт кнопки
local minimapButton = CreateFrame("Button", "HuntTrackerMinimapButton", Minimap)
minimapButton:SetFrameStrata("MEDIUM")
minimapButton:SetSize(31, 31)
minimapButton:SetFrameLevel(8)
minimapButton:RegisterForClicks("RightButtonUp")
minimapButton:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

-- Иконка специализации Стрельба
local icon = minimapButton:CreateTexture(nil, "BACKGROUND")
icon:SetSize(20, 20)
icon:SetPoint("CENTER", 0, 1)
icon:SetTexture("Interface\\Icons\\Ability_Hunter_FocusedAim")

-- Граница кнопки
local overlay = minimapButton:CreateTexture(nil, "OVERLAY")
overlay:SetSize(53, 53)
overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
overlay:SetPoint("TOPLEFT")

local minimapButtonAngle = defaults.minimapButtonAngle

local function UpdateMinimapButtonPosition()
    local angle = math.rad(minimapButtonAngle)
    local x = math.cos(angle) * 80
    local y = math.sin(angle) * 80
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function UpdateMinimapIcon()
    if settings.enabled then
        icon:SetDesaturated(false)
    else
        icon:SetDesaturated(true)
    end
end

-- ПКМ - включить/выключить
minimapButton:SetScript("OnClick", function(self, button)
    if button == "RightButton" then
        if not settings then return end
        settings.enabled = not settings.enabled
        UpdateMinimapIcon()
        if settings.enabled then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00HuntTracker: Включено|r")
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffff0000HuntTracker: Выключено|r")
            wantedTrackingIndex = nil
        end
    end
end)

-- Тултип
minimapButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("HuntTracker")
    GameTooltip:AddLine(" ")
    if settings.enabled then
        GameTooltip:AddLine("|cff00ff00Автоотслеживание: ВКЛ|r")
    else
        GameTooltip:AddLine("|cffff0000Автоотслеживание: ВЫКЛ|r")
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddDoubleLine("|cffffffffПКМ:|r", "Вкл/Выкл", 1, 1, 1, 1, 1, 1)
    GameTooltip:AddDoubleLine("|cffffffffShift+ЛКМ:|r", "Перетащить", 1, 1, 1, 1, 1, 1)
    GameTooltip:Show()
end)

minimapButton:SetScript("OnLeave", function(self)
    GameTooltip:Hide()
end)

-- Перетаскивание
minimapButton:SetScript("OnMouseDown", function(self, button)
    if button == "LeftButton" and IsShiftKeyDown() then
        self.dragging = true
    end
end)

minimapButton:SetScript("OnMouseUp", function(self, button)
    if button == "LeftButton" then
        self.dragging = false
        if settings then
            settings.minimapButtonAngle = minimapButtonAngle
        end
    end
end)

-- OnUpdate
minimapButton:SetScript("OnUpdate", function(self, elapsed)
    if self.dragging then
        local mx, my = Minimap:GetCenter()
        local px, py = GetCursorPosition()
        local scale = Minimap:GetEffectiveScale()
        px, py = px / scale, py / scale
        minimapButtonAngle = math.deg(math.atan2(py - my, px - mx))
        UpdateMinimapButtonPosition()
    end
    
    if wantedTrackingIndex and settings.enabled then
        retryTimer = retryTimer + elapsed
        if retryTimer >= 0.2 then
            retryTimer = 0
            RetryTracking()
        end
    else
        retryTimer = 0
    end
end)

HuntTracker:SetScript("OnEvent", function(self, event, unit)
    if event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        -- Инициализация SavedVariables
        if not HuntTrackerDB then HuntTrackerDB = {} end
        for k, v in pairs(defaults) do
            if HuntTrackerDB[k] == nil then
                HuntTrackerDB[k] = v
            end
        end
        settings = HuntTrackerDB

        -- применяем сохранённые значения
        minimapButtonAngle = settings.minimapButtonAngle or defaults.minimapButtonAngle

        BuildTrackingTable()
        UpdateMinimapButtonPosition()
        UpdateMinimapIcon()
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" or event == "UNIT_SPELLCAST_STOP" or 
           event == "UNIT_SPELLCAST_FAILED" or event == "UNIT_SPELLCAST_INTERRUPTED" then
        if unit == "player" and settings.enabled then
            RetryTracking()
        end
    else
        UpdateTracking()
    end
end)

HuntTracker:RegisterEvent("PLAYER_LOGIN")
HuntTracker:RegisterEvent("PLAYER_ENTERING_WORLD")
HuntTracker:RegisterEvent("PLAYER_TARGET_CHANGED")
HuntTracker:RegisterEvent("PLAYER_REGEN_DISABLED")
HuntTracker:RegisterEvent("PLAYER_REGEN_ENABLED")
HuntTracker:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
HuntTracker:RegisterEvent("UNIT_SPELLCAST_STOP")
HuntTracker:RegisterEvent("UNIT_SPELLCAST_FAILED")
HuntTracker:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
