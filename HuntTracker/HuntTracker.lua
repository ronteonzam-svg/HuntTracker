local HuntTracker = CreateFrame("Frame", "HuntTrackerFrame")

local _, playerClass = UnitClass("player")
if playerClass ~= "HUNTER" then return end

-- =========================================================
-- ЛОКАЛИЗАЦИЯ
-- =========================================================
local addonName, addon = ...
local L = addon.L

-- Кэшируем часто используемые API
local UnitExists           = UnitExists
local UnitIsDead           = UnitIsDead
local UnitCanAttack        = UnitCanAttack
local UnitCreatureType     = UnitCreatureType
local GetNumTrackingTypes  = GetNumTrackingTypes
local GetTrackingInfo      = GetTrackingInfo
local SetTracking          = SetTracking
local GetCursorPosition    = GetCursorPosition
local math_sin, math_cos   = math.sin, math.cos
local math_rad, math_deg   = math.rad, math.deg
local math_atan2           = math.atan2
local string_lower         = string.lower
local string_find          = string.find
local GetSpellCooldown       = GetSpellCooldown

local TRACK_ATTEMPT_INTERVAL = 0.05

-- =========================================================
-- ЗНАЧЕНИЯ ПО УМОЛЧАНИЮ
-- =========================================================
local defaults = {
    enabled = true,
    autoReturn = true,
    onlyHostile = true,
    minimapButtonAngle = 225,
}

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
local targetTrackingID = nil
local checkTimer = 0
local isDragging = false
local suppressErrors = false

local lastCastTime = 0 -- Запоминаем время последнего нажатия

-- =========================================================
-- ПЕРЕХВАТЧИК ОШИБОК (новая, более надёжная версия)
-- =========================================================
local suppressedErrorMessages = {
    [ERR_SPELL_COOLDOWN] = true,
    [SPELL_FAILED_SPELL_IN_PROGRESS] = true,
}

if not UIErrorsFrame.__HuntTrackerAddMessageHooked then
    local originalAddMessage = UIErrorsFrame.AddMessage
    UIErrorsFrame.AddMessage = function(self, message, ...)
        -- Если аддон пытается сменить трекинг и ошибка в нашем "чёрном списке", просто ничего не делаем
        if suppressErrors and suppressedErrorMessages[message] then
            return
        end
        -- В остальных случаях вызываем оригинальную функцию, чтобы другие ошибки отображались
        return originalAddMessage(self, message, ...)
    end
    UIErrorsFrame.__HuntTrackerAddMessageHooked = true
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

-- =========================================================
-- ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
-- =========================================================
local function PrintStatus(key)
    DEFAULT_CHAT_FRAME:AddMessage(L[key])
end

local function GetCurrentTrackingID()
    local count = GetNumTrackingTypes()
    for i = 1, count do
        local _, _, active = GetTrackingInfo(i)
        if active then
            return i
        end
    end
    return 0
end

local function BuildTrackingTable()
    wipe(trackIndexByKey)
    local count = GetNumTrackingTypes()
    for i = 1, count do
        local name, _, _, category = GetTrackingInfo(i)
        if name and category == "spell" then
            local lowerName = string_lower(name)
            for key, patterns in pairs(trackingNamePatterns) do
                for _, pat in ipairs(patterns) do
                    if string_find(lowerName, pat) then
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
-- УПРАВЛЕНИЕ ONUPDATE
-- =========================================================
local MinimapButtonOnUpdate

local function SetOnUpdate(enabled)
    if enabled then
        if not minimapButton:GetScript("OnUpdate") then
            minimapButton:SetScript("OnUpdate", MinimapButtonOnUpdate)
        end
    else
        minimapButton:SetScript("OnUpdate", nil)
        checkTimer = 0
    end
end

local function RefreshOnUpdateState()
    if HuntTrackerDB and HuntTrackerDB.enabled and (isDragging or targetTrackingID) then
        SetOnUpdate(true)
    else
        SetOnUpdate(false)
    end
end

local function SetTargetTracking(id)
    targetTrackingID = id
    suppressErrors = id ~= nil -- Включаем или выключаем глушилку
    checkTimer = 0
    RefreshOnUpdateState()
end

local function ApplyTrackingChange()
    if not targetTrackingID then return end

    -- 1. ЗАЩИТА ОТ ДВОЙНОГО НАЖАТИЯ (НОВОЕ)
    -- Если мы нажали кнопку меньше 1 секунды назад, не пытаемся снова,
    -- даже если игра говорит, что КД нет. Даем серверу время отреагировать.
    if (GetTime() - lastCastTime) < 1.0 then
        return
    end

    local currentID = GetCurrentTrackingID()

    -- Если уже включено то, что нужно
    if currentID == targetTrackingID then
        if HuntTrackerDB.savedTrackingIndex == currentID then
            HuntTrackerDB.savedTrackingIndex = nil
        end
        SetTargetTracking(nil)
        return
    end

    -- 2. ПРОВЕРКА КУЛДАУНА (ИЗ ПРОШЛОГО ШАГА)
    local checkID = targetTrackingID
    if checkID == 0 then checkID = currentID end

    if checkID and checkID > 0 then
        local name = GetTrackingInfo(checkID)
        if name then
            local start, duration, enabled = GetSpellCooldown(name)
            if start and duration and (start > 0 and duration > 0) then
                return -- Ждем окончания КД
            end
        end
    end

    -- 3. ПРИМЕНЕНИЕ
    local origSFX = GetCVar("Sound_EnableSFX")
    local hadSFX = origSFX ~= "0"
    if hadSFX then SetCVar("Sound_EnableSFX", "0") end

    if targetTrackingID == 0 then
        if currentID ~= 0 then
            SetTracking(currentID)
            lastCastTime = GetTime() -- Запоминаем время нажатия
        end
        HuntTrackerDB.savedTrackingIndex = nil
        SetTargetTracking(nil)
    else
        SetTracking(targetTrackingID)
        lastCastTime = GetTime() -- Запоминаем время нажатия
    end

    if hadSFX then SetCVar("Sound_EnableSFX", origSFX) end
end



-- =========================================================
-- ЛОГИКА
-- =========================================================
local function UpdateLogic()
    if not HuntTrackerDB or not HuntTrackerDB.enabled then
        SetTargetTracking(nil)
        return
    end

    local currentID = GetCurrentTrackingID()
    local wantedID = GetWantedIndexForTarget()

    if wantedID then
        if HuntTrackerDB.savedTrackingIndex == nil then
            HuntTrackerDB.savedTrackingIndex = currentID
        end

        if wantedID ~= currentID then
            SetTargetTracking(wantedID)
        else
            SetTargetTracking(nil)
        end
    else
        if HuntTrackerDB.autoReturn and HuntTrackerDB.savedTrackingIndex ~= nil then
            if HuntTrackerDB.savedTrackingIndex ~= currentID then
                SetTargetTracking(HuntTrackerDB.savedTrackingIndex)
            else
                HuntTrackerDB.savedTrackingIndex = nil
                SetTargetTracking(nil)
            end
        else
            HuntTrackerDB.savedTrackingIndex = nil
            SetTargetTracking(nil)
        end
    end
end

-- =========================================================
-- ФУНКЦИИ МИНИКАРТЫ
-- =========================================================
local function UpdateMinimapButtonPosition()
    if not HuntTrackerDB then return end
    if not HuntTrackerDB.minimapButtonAngle then
        HuntTrackerDB.minimapButtonAngle = defaults.minimapButtonAngle
    end

    local angle = math_rad(HuntTrackerDB.minimapButtonAngle)
    local x = math_cos(angle) * 80
    local y = math_sin(angle) * 80
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function UpdateMinimapIcon()
    if not HuntTrackerDB then return end
    if HuntTrackerDB.enabled then
        icon:SetDesaturated(false)
    else
        icon:SetDesaturated(true)
        HuntTrackerDB.savedTrackingIndex = nil
        SetTargetTracking(nil)
    end
end

-- =========================================================
-- МЕНЮ НАСТРОЕК
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

    local chkEnable = CreateFrame("CheckButton", "HuntTrackerOptEnable", configFrame, "UICheckButtonTemplate")
    chkEnable:SetPoint("TOPLEFT", 30, -50)
    _G[chkEnable:GetName() .. "Text"]:SetText(L["OPT_ENABLE"])
    chkEnable:SetChecked(HuntTrackerDB.enabled)
    chkEnable:SetScript("OnClick", function(self)
        HuntTrackerDB.enabled = not not self:GetChecked()
        if HuntTrackerDB.enabled then
            PrintStatus("ENABLED")
            UpdateLogic()
        else
            PrintStatus("DISABLED")
        end
        UpdateMinimapIcon()
        RefreshOnUpdateState()
    end)
    configFrame.chkEnable = chkEnable

    local chkHostile = CreateFrame("CheckButton", "HuntTrackerOptHostile", configFrame, "UICheckButtonTemplate")
    chkHostile:SetPoint("TOPLEFT", 30, -80)
    _G[chkHostile:GetName() .. "Text"]:SetText(L["OPT_ONLYHOSTILE"])
    chkHostile:SetChecked(HuntTrackerDB.onlyHostile)
    chkHostile:SetScript("OnClick", function(self)
        HuntTrackerDB.onlyHostile = not not self:GetChecked()
        UpdateLogic()
    end)
    configFrame.chkHostile = chkHostile

    local chkReturn = CreateFrame("CheckButton", "HuntTrackerOptReturn", configFrame, "UICheckButtonTemplate")
    chkReturn:SetPoint("TOPLEFT", 30, -110)
    _G[chkReturn:GetName() .. "Text"]:SetText(L["OPT_AUTORETURN"])
    chkReturn:SetChecked(HuntTrackerDB.autoReturn)
    chkReturn:SetScript("OnClick", function(self)
        HuntTrackerDB.autoReturn = not not self:GetChecked()
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
        if configFrame.chkEnable then configFrame.chkEnable:SetChecked(HuntTrackerDB.enabled) end
        if configFrame.chkHostile then configFrame.chkHostile:SetChecked(HuntTrackerDB.onlyHostile) end
        if configFrame.chkReturn then configFrame.chkReturn:SetChecked(HuntTrackerDB.autoReturn) end
        configFrame:Show()
    end
end

SLASH_HUNTTRACKER1 = "/ht"
SLASH_HUNTTRACKER2 = "/hunttracker"
SlashCmdList["HUNTTRACKER"] = function()
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
                PrintStatus("ENABLED")
                UpdateLogic()
            else
                PrintStatus("DISABLED")
                SetTargetTracking(nil)
            end
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
        isDragging = true
        SetOnUpdate(true)
    end
end)

minimapButton:SetScript("OnMouseUp", function(self, button)
    if button == "LeftButton" then
        isDragging = false
        RefreshOnUpdateState()
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

minimapButton:SetScript("OnLeave", function()
    GameTooltip:Hide()
end)

-- =========================================================
-- ON UPDATE
-- =========================================================
MinimapButtonOnUpdate = function(self, elapsed)
    if isDragging and HuntTrackerDB then
        local mx, my = Minimap:GetCenter()
        local px, py = GetCursorPosition()
        local scale = Minimap:GetEffectiveScale()
        px, py = px / scale, py / scale
        local angle = math_deg(math_atan2(py - my, px - mx))
        HuntTrackerDB.minimapButtonAngle = angle
        UpdateMinimapButtonPosition()
    end

    if not HuntTrackerDB or not HuntTrackerDB.enabled or not targetTrackingID then
        RefreshOnUpdateState()
        return
    end

    checkTimer = checkTimer - elapsed
    if checkTimer <= 0 then
        checkTimer = TRACK_ATTEMPT_INTERVAL
        ApplyTrackingChange()
    end
end

-- =========================================================
-- СОБЫТИЯ
-- =========================================================
local function InitializeDefaults()
    if not HuntTrackerDB then HuntTrackerDB = {} end
    for k, v in pairs(defaults) do
        if HuntTrackerDB[k] == nil then
            HuntTrackerDB[k] = v
        end
    end
end

HuntTracker:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_LOGIN" then
        InitializeDefaults()
        BuildTrackingTable()
        UpdateMinimapButtonPosition()
        UpdateMinimapIcon()
        UpdateLogic()
    elseif event == "PLAYER_ENTERING_WORLD" then
        BuildTrackingTable()
        UpdateLogic()
    elseif event == "PLAYER_TARGET_CHANGED" or event == "PLAYER_REGEN_ENABLED" then
        UpdateLogic()
    elseif event == "MINIMAP_UPDATE_TRACKING" or event == "SPELLS_CHANGED" or event == "LEARNED_SPELL_IN_TAB" then
        BuildTrackingTable()
        UpdateLogic()
    end
end)

HuntTracker:RegisterEvent("PLAYER_LOGIN")
HuntTracker:RegisterEvent("PLAYER_ENTERING_WORLD")
HuntTracker:RegisterEvent("PLAYER_TARGET_CHANGED")
HuntTracker:RegisterEvent("PLAYER_REGEN_ENABLED")
HuntTracker:RegisterEvent("MINIMAP_UPDATE_TRACKING")
HuntTracker:RegisterEvent("SPELLS_CHANGED")
HuntTracker:RegisterEvent("LEARNED_SPELL_IN_TAB")
