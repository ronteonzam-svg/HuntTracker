local HuntTracker = CreateFrame("Frame", "HuntTrackerFrame")

-- Проверяем класс персонажа
local _, playerClass = UnitClass("player")
if playerClass ~= "HUNTER" then return end

-- =========================================================
-- ЛОКАЛИЗАЦИЯ
-- =========================================================
local L = {}
local locale = GetLocale()

if locale == "ruRU" then
    L["ENABLED"] = "|cff00ff00HuntTracker: Включено|r"
    L["DISABLED"] = "|cffff0000HuntTracker: Выключено|r"
    L["TOOLTIP_TITLE"] = "HuntTracker"
    L["STATUS_ON"] = "Состояние: |cff00ff00ВКЛ|r"
    L["STATUS_OFF"] = "Состояние: |cffff0000ВЫКЛ|r"
    L["HINT_LCLICK"] = "|cffffffffЛКМ (Зажать):|r"
    L["HINT_LCLICK_TEXT"] = "Передвинуть"
    L["HINT_RCLICK"] = "|cffffffffПКМ:|r"
    L["HINT_RCLICK_TEXT"] = "Настройки"
    L["HINT_SHIFT_RCLICK"] = "|cffffffffShift + ПКМ:|r"
    L["HINT_SHIFT_RCLICK_TEXT"] = "Вкл/Выкл Аддон"
    
    L["MENU_TITLE"] = "Настройки HuntTracker"
    L["OPT_ENABLE"] = "Включить аддон"
    L["OPT_ONLYHOSTILE"] = "Только враги"
    L["OPT_AUTORETURN"] = "Возвращать выслеживание"
    L["OPT_DESC"] = "Если 'Только враги' выключено, аддон будет реагировать и на дружественных НПС."
else
    L["ENABLED"] = "|cff00ff00HuntTracker: Enabled|r"
    L["DISABLED"] = "|cffff0000HuntTracker: Disabled|r"
    L["TOOLTIP_TITLE"] = "HuntTracker"
    L["STATUS_ON"] = "Status: |cff00ff00ON|r"
    L["STATUS_OFF"] = "Status: |cffff0000OFF|r"
    L["HINT_LCLICK"] = "|cffffffffLeft Click (Hold):|r"
    L["HINT_LCLICK_TEXT"] = "Move"
    L["HINT_RCLICK"] = "|cffffffffRight Click:|r"
    L["HINT_RCLICK_TEXT"] = "Menu"
    L["HINT_SHIFT_RCLICK"] = "|cffffffffShift + Right Click:|r"
    L["HINT_SHIFT_RCLICK_TEXT"] = "Toggle On/Off"

    L["MENU_TITLE"] = "HuntTracker Settings"
    L["OPT_ENABLE"] = "Enable Addon"
    L["OPT_ONLYHOSTILE"] = "Only Hostile Targets"
    L["OPT_AUTORETURN"] = "Auto Return Tracking"
    L["OPT_DESC"] = "If 'Only Hostile' is unchecked, it will trigger on friendly NPCs too."
end

-- =========================================================
-- ЗНАЧЕНИЯ ПО УМОЛЧАНИЮ
-- =========================================================
local defaults = {
    enabled = true,
    autoReturn = true,
    onlyHostile = true,
    minimapButtonAngle = 225,
}

-- Вместо локальной settings будем обращаться к HuntTrackerDB напрямую, 
-- чтобы исключить путаницу ссылок.

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
--local savedTrackingIndex = nil 
local targetTrackingID = nil
local checkTimer = 0

-- =========================================================
-- ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
-- =========================================================

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
    
    -- Используем HuntTrackerDB напрямую
    if HuntTrackerDB.onlyHostile and not UnitCanAttack("player", "target") then 
        return nil 
    end

    local cType = UnitCreatureType("target")
    if not cType then return nil end
    
    local key = creatureTypeKey[cType]
    if not key then return nil end
    
    return trackIndexByKey[key]
end

-- =========================================================
-- ЛОГИКА
-- =========================================================

local function UpdateLogic()
    if not HuntTrackerDB or not HuntTrackerDB.enabled then return end

    local currentID = GetCurrentTrackingID()
    local wantedID = GetWantedIndexForTarget()

    if wantedID then
        -- Если мы еще ничего не запомнили в базе, запоминаем текущее
        if HuntTrackerDB.savedTrackingIndex == nil then
            HuntTrackerDB.savedTrackingIndex = currentID 
        end
        targetTrackingID = wantedID
    else
        -- Цели нет или она нам не интересна
        if HuntTrackerDB.autoReturn then
            if HuntTrackerDB.savedTrackingIndex ~= nil then
                targetTrackingID = HuntTrackerDB.savedTrackingIndex
            else
                targetTrackingID = nil
            end
        else
            -- Если автовозврат выключен, стираем память
            HuntTrackerDB.savedTrackingIndex = nil
            targetTrackingID = nil
        end
    end
end

-- =========================================================
-- МИНИКАРТА
-- =========================================================
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
    if not HuntTrackerDB then return end
    if not HuntTrackerDB.minimapButtonAngle then HuntTrackerDB.minimapButtonAngle = defaults.minimapButtonAngle end
    
    local angle = math.rad(HuntTrackerDB.minimapButtonAngle)
    local x = math.cos(angle) * 80
    local y = math.sin(angle) * 80
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function UpdateMinimapIcon()
    if not HuntTrackerDB then return end
    if HuntTrackerDB.enabled then
        icon:SetDesaturated(false)
    else
        icon:SetDesaturated(true)
        HuntTrackerDB.savedTrackingIndex = nil -- Сброс в базе
        targetTrackingID = nil
    end
end

-- =========================================================
-- МЕНЮ НАСТРОЕК (GUI)
-- =========================================================
local configFrame = nil

local function CreateConfigMenu()
    if configFrame then return end
    
    configFrame = CreateFrame("Frame", "HuntTrackerConfigFrame", UIParent)
    configFrame:SetSize(300, 220)
    configFrame:SetPoint("CENTER")
    configFrame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 }
    })
    configFrame:Hide()
    configFrame:EnableMouse(true)
    configFrame:SetMovable(true)
    configFrame:RegisterForDrag("LeftButton")
    configFrame:SetScript("OnDragStart", configFrame.StartMoving)
    configFrame:SetScript("OnDragStop", configFrame.StopMovingOrSizing)

    local title = configFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -20)
    title:SetText(L["MENU_TITLE"])

    -- 1. Enable
    local chkEnable = CreateFrame("CheckButton", "HuntTrackerOptEnable", configFrame, "UICheckButtonTemplate")
    chkEnable:SetPoint("TOPLEFT", 30, -50)
    _G[chkEnable:GetName().."Text"]:SetText(L["OPT_ENABLE"])
    chkEnable:SetChecked(HuntTrackerDB.enabled) -- Читаем из DB
    chkEnable:SetScript("OnClick", function(self)
        HuntTrackerDB.enabled = not not self:GetChecked() -- Пишем в DB
        if HuntTrackerDB.enabled then
            DEFAULT_CHAT_FRAME:AddMessage(L["ENABLED"])
            UpdateLogic()
        else
            DEFAULT_CHAT_FRAME:AddMessage(L["DISABLED"])
        end
        UpdateMinimapIcon()
    end)
    configFrame.chkEnable = chkEnable

    -- 2. Hostile Only
    local chkHostile = CreateFrame("CheckButton", "HuntTrackerOptHostile", configFrame, "UICheckButtonTemplate")
    chkHostile:SetPoint("TOPLEFT", 30, -80)
    _G[chkHostile:GetName().."Text"]:SetText(L["OPT_ONLYHOSTILE"])
    chkHostile:SetChecked(HuntTrackerDB.onlyHostile) -- Читаем из DB
    chkHostile:SetScript("OnClick", function(self)
        HuntTrackerDB.onlyHostile = not not self:GetChecked() -- Пишем в DB
        UpdateLogic() 
    end)
    configFrame.chkHostile = chkHostile
    
    -- 3. Auto Return
    local chkReturn = CreateFrame("CheckButton", "HuntTrackerOptReturn", configFrame, "UICheckButtonTemplate")
    chkReturn:SetPoint("TOPLEFT", 30, -110)
    _G[chkReturn:GetName().."Text"]:SetText(L["OPT_AUTORETURN"])
    chkReturn:SetChecked(HuntTrackerDB.autoReturn) -- Читаем из DB
    chkReturn:SetScript("OnClick", function(self)
        HuntTrackerDB.autoReturn = not not self:GetChecked() -- Пишем в DB
    end)
    configFrame.chkReturn = chkReturn
    
    local desc = configFrame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    desc:SetPoint("TOPLEFT", 40, -150)
    desc:SetWidth(220)
    desc:SetJustifyH("LEFT")
    desc:SetText(L["OPT_DESC"])

    local closeBtn = CreateFrame("Button", "HuntTrackerCloseBtn", configFrame, "UIPanelButtonTemplate")
    closeBtn:SetSize(80, 25)
    closeBtn:SetPoint("BOTTOM", 0, 20)
    closeBtn:SetText(CLOSE)
    closeBtn:SetScript("OnClick", function() configFrame:Hide() end)
end

local function ToggleConfigMenu()
    CreateConfigMenu()
    if configFrame:IsShown() then
        configFrame:Hide()
    else
        -- ОБЯЗАТЕЛЬНО: Обновляем галочки визуально перед показом окна
        -- Это исправляет баг "залипания" старых значений
        if configFrame.chkEnable then configFrame.chkEnable:SetChecked(HuntTrackerDB.enabled) end
        if configFrame.chkHostile then configFrame.chkHostile:SetChecked(HuntTrackerDB.onlyHostile) end
        if configFrame.chkReturn then configFrame.chkReturn:SetChecked(HuntTrackerDB.autoReturn) end
        
        configFrame:Show()
    end
end

SLASH_HUNTTRACKER1 = "/ht"
SLASH_HUNTTRACKER2 = "/hunttracker"
SlashCmdList["HUNTTRACKER"] = function(msg)
    ToggleConfigMenu()
end

-- =========================================================
-- УПРАВЛЕНИЕ МИНИКАРТОЙ
-- =========================================================

minimapButton:SetScript("OnClick", function(self, button)
    if button == "RightButton" then
        if IsShiftKeyDown() then
            if not HuntTrackerDB then return end
            HuntTrackerDB.enabled = not HuntTrackerDB.enabled
            UpdateMinimapIcon()
            if HuntTrackerDB.enabled then
                DEFAULT_CHAT_FRAME:AddMessage(L["ENABLED"])
                UpdateLogic()
            else
                DEFAULT_CHAT_FRAME:AddMessage(L["DISABLED"])
            end
            -- Обновляем чекбокс, если окно открыто
            if configFrame and configFrame:IsShown() then
                configFrame.chkEnable:SetChecked(HuntTrackerDB.enabled)
            end
        else
            ToggleConfigMenu()
        end
    end
end)

minimapButton:SetScript("OnMouseDown", function(self, button)
    if button == "LeftButton" then
        self.dragging = true
    end
end)

minimapButton:SetScript("OnMouseUp", function(self, button)
    if button == "LeftButton" then
        self.dragging = false
    end
end)

minimapButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine(L["TOOLTIP_TITLE"])
    GameTooltip:AddLine(" ")
    if HuntTrackerDB and HuntTrackerDB.enabled then
        GameTooltip:AddLine(L["STATUS_ON"])
    else
        GameTooltip:AddLine(L["STATUS_OFF"])
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddDoubleLine(L["HINT_LCLICK"], L["HINT_LCLICK_TEXT"], 1, 1, 1, 1, 1, 1)
    GameTooltip:AddDoubleLine(L["HINT_RCLICK"], L["HINT_RCLICK_TEXT"], 1, 1, 1, 1, 1, 1)
    GameTooltip:AddDoubleLine(L["HINT_SHIFT_RCLICK"], L["HINT_SHIFT_RCLICK_TEXT"], 1, 1, 1, 1, 1, 1)
    GameTooltip:Show()
end)

minimapButton:SetScript("OnLeave", function(self) GameTooltip:Hide() end)

-- =========================================================
-- ON UPDATE
-- =========================================================
minimapButton:SetScript("OnUpdate", function(self, elapsed)
    if self.dragging then
        local mx, my = Minimap:GetCenter()
        local px, py = GetCursorPosition()
        local scale = Minimap:GetEffectiveScale()
        px, py = px / scale, py / scale
        local angle = math.deg(math.atan2(py - my, px - mx))
        
        if HuntTrackerDB then HuntTrackerDB.minimapButtonAngle = angle end
        UpdateMinimapButtonPosition()
    end

    if not HuntTrackerDB or not HuntTrackerDB.enabled then return end

    if targetTrackingID then
        checkTimer = checkTimer + elapsed
        if checkTimer >= 0.5 then
            checkTimer = 0
            
            local currentID = GetCurrentTrackingID()
            
            if currentID ~= targetTrackingID then
                local origSFX = GetCVar("Sound_EnableSFX")
                UIErrorsFrame:UnregisterEvent("UI_ERROR_MESSAGE")
                SetCVar("Sound_EnableSFX", "0") 
                
                if targetTrackingID == 0 then
                    -- Если нужно выключить выслеживание
                    if currentID ~= 0 then SetTracking(currentID) end -- Тут нюанс API 3.3.5, иногда 0 работает специфично, но оставим как было у тебя
                    HuntTrackerDB.savedTrackingIndex = nil -- Очищаем память в базе
                    targetTrackingID = nil
                else
                    SetTracking(targetTrackingID)
                end
                
                SetCVar("Sound_EnableSFX", origSFX)
                UIErrorsFrame:RegisterEvent("UI_ERROR_MESSAGE")
            else
                -- Если мы уже переключились на то, что хотели (например, вернулись к исходному)
                -- Проверяем, вернулись ли мы к "запомненному" состоянию
                if HuntTrackerDB.savedTrackingIndex == currentID then
                    HuntTrackerDB.savedTrackingIndex = nil -- Очищаем память, миссия выполнена
                    targetTrackingID = nil 
                end
            end
        end
    else
        checkTimer = 0
    end
end)

-- =========================================================
-- СОБЫТИЯ
-- =========================================================
HuntTracker:SetScript("OnEvent", function(self, event, unit)
    if event == "PLAYER_LOGIN" then
        if not HuntTrackerDB then HuntTrackerDB = {} end
        
        for k, v in pairs(defaults) do
            if HuntTrackerDB[k] == nil then 
                HuntTrackerDB[k] = v 
            end
        end

        BuildTrackingTable()
        UpdateMinimapButtonPosition()
        UpdateMinimapIcon()
        UpdateLogic()             -- <--- добавь сюда

    elseif event == "PLAYER_ENTERING_WORLD" then
        BuildTrackingTable()
        UpdateLogic()             -- <--- и сюда

    elseif event == "PLAYER_TARGET_CHANGED" or event == "PLAYER_REGEN_ENABLED" then
        UpdateLogic()
        checkTimer = 1
    end
end)

HuntTracker:RegisterEvent("PLAYER_LOGIN")
HuntTracker:RegisterEvent("PLAYER_ENTERING_WORLD")
HuntTracker:RegisterEvent("PLAYER_TARGET_CHANGED")
HuntTracker:RegisterEvent("PLAYER_REGEN_ENABLED")
