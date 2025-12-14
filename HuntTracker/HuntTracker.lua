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
local GetSpellCooldown     = GetSpellCooldown

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
    ["beast"] = "Beast",
    ["humanoid"] = "Humanoid",
    ["undead"] = "Undead",
    ["elemental"] = "Elemental",
    ["demon"] = "Demon",
    ["giant"] = "Giant",
    ["dragonkin"] = "Dragonkin",
    ["зверь"] = "Beast",
    ["животное"] = "Beast",
    ["животные"] = "Beast",
    ["гуманоид"] = "Humanoid",
    ["нежить"] = "Undead",
    ["элементаль"] = "Elemental",
    ["демон"] = "Demon",
    ["великан"] = "Giant",
    ["драконид"] = "Dragonkin",
    ["дракон"] = "Dragonkin",
    ["драконы"] = "Dragonkin",
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
local checkTimer = TRACK_ATTEMPT_INTERVAL
local isDragging = false
local suppressErrors = false
local lastCastTime = 0
local currentTrackingID = 0

-- =========================================================
-- ПЕРЕХВАТЧИК ОШИБОК
-- =========================================================
local suppressedErrorMessages = {
    [ERR_SPELL_COOLDOWN] = true,
    [SPELL_FAILED_SPELL_IN_PROGRESS] = true,
}

if not UIErrorsFrame.__HuntTrackerAddMessageHooked then
    local originalAddMessage = UIErrorsFrame.AddMessage
    UIErrorsFrame.AddMessage = function(self, message, ...)
        if suppressErrors and suppressedErrorMessages[message] then
            return
        end
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

local function RefreshCurrentTrackingID()
    currentTrackingID = 0
    local count = GetNumTrackingTypes()
    for i = 1, count do
        local _, _, active = GetTrackingInfo(i)
        if active then
            currentTrackingID = i
            break
        end
    end
end

local function BuildTrackingTable()
    wipe(trackIndexByKey)
    local count = GetNumTrackingTypes()
    for i = 1, count do
        local name, _, _, category = GetTrackingInfo(i)
        if name and category == "spell" then
            local lowerName = string_lower(name)
            for key, patterns in pairs(trackingNamePatterns) do
                if not trackIndexByKey[key] then
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
    RefreshCurrentTrackingID()
end

local function GetWantedIndexForTarget()
    if not UnitExists("target") then return nil end
    if UnitIsDead("target") then return nil end
    if HuntTrackerDB.onlyHostile and not UnitCanAttack("player", "target") then
        return nil
    end

    local cType = UnitCreatureType("target")
    if not cType then return nil end

    local key = creatureTypeKey[string_lower(cType)]
    if not key then return nil end

    return trackIndexByKey[key]
end

-- =========================================================
-- ONUPDATE ДЛЯ ЛОГИКИ
-- =========================================================
local logicTicker = CreateFrame("Frame")
logicTicker:Hide()
logicTicker:SetScript("OnUpdate", function(_, elapsed)
    checkTimer = checkTimer - elapsed
    if checkTimer <= 0 then
        checkTimer = TRACK_ATTEMPT_INTERVAL
        ApplyTrackingChange()
    end
end)

local function UpdateLogicTickerState()
    if HuntTrackerDB and HuntTrackerDB.enabled and targetTrackingID then
        checkTimer = 0
        logicTicker:Show()
    else
        logicTicker:Hide()
    end
end

-- =========================================================
-- МИНИКАРТА: ПЕРЕТАСКИВАНИЕ
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

local function MinimapButtonDragOnUpdate()
    if not HuntTrackerDB then return end
    local mx, my = Minimap:GetCenter()
    local px, py = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    px, py = px / scale, py / scale
    local angle = math_deg(math_atan2(py - my, px - mx))
    HuntTrackerDB.minimapButtonAngle = angle
    UpdateMinimapButtonPosition()
end

local function UpdateMinimapDragState()
    if isDragging then
        minimapButton:SetScript("OnUpdate", MinimapButtonDragOnUpdate)
    else
        minimapButton:SetScript("OnUpdate", nil)
    end
end

local function UpdateMinimapIcon()
    if not HuntTrackerDB then return end
    icon:SetDesaturated(not HuntTrackerDB.enabled)
    if not HuntTrackerDB.enabled then
        HuntTrackerDB.savedTrackingIndex = nil
        targetTrackingID = nil
        UpdateLogicTickerState()
    end
end

-- =========================================================
-- УПРАВЛЕНИЕ ЦЕЛЕВЫМ ТРЕКАМИНГОМ
-- =========================================================
local function SetTargetTracking(id)
    targetTrackingID = id
    suppressErrors = id ~= nil
    UpdateLogicTickerState()
end

function ApplyTrackingChange()
    if not targetTrackingID then return end

    if (GetTime() - lastCastTime) < 1.0 then
        return
    end

    if currentTrackingID == targetTrackingID then
        if HuntTrackerDB.savedTrackingIndex == currentTrackingID then
            HuntTrackerDB.savedTrackingIndex = nil
        end
        SetTargetTracking(nil)
        return
    end

    local checkID = targetTrackingID
    if checkID and checkID > 0 then
        local name = GetTrackingInfo(checkID)
        if name then
            local start, duration = GetSpellCooldown(name)
            if start and duration and start > 0 and duration > 0 then
                checkTimer = 0.2
                return
            end
        end
    end

    local origSFX = GetCVar("Sound_EnableSFX")
    local hadSFX = origSFX ~= "0"
    if hadSFX then SetCVar("Sound_EnableSFX", "0") end

    SetTracking(targetTrackingID)
    lastCastTime = GetTime()
    RefreshCurrentTrackingID()

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

    local currentID = currentTrackingID
    local wantedID = GetWantedIndexForTarget()

    if wantedID then
        if HuntTrackerDB.savedTrackingIndex == nil then
            HuntTrackerDB.savedTrackingIndex = currentID ~= 0 and currentID or nil
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
-- МЕНЮ НАСТРОЕК
-- =========================================================
local configFrame

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
    chkEnable:SetScript("OnClick", function(self)
        HuntTrackerDB.enabled = not not self:GetChecked()
        if HuntTrackerDB.enabled then
            PrintStatus("ENABLED")
            UpdateLogic()
        else
            PrintStatus("DISABLED")
            SetTargetTracking(nil)
        end
        UpdateMinimapIcon()
    end)
    configFrame.chkEnable = chkEnable

    local chkHostile = CreateFrame("CheckButton", "HuntTrackerOptHostile", configFrame, "UICheckButtonTemplate")
    chkHostile:SetPoint("TOPLEFT", 30, -80)
    _G[chkHostile:GetName() .. "Text"]:SetText(L["OPT_ONLYHOSTILE"])
    chkHostile:SetScript("OnClick", function(self)
        HuntTrackerDB.onlyHostile = not not self:GetChecked()
        UpdateLogic()
    end)
    configFrame.chkHostile = chkHostile

    local chkReturn = CreateFrame("CheckButton", "HuntTrackerOptReturn", configFrame, "UICheckButtonTemplate")
    chkReturn:SetPoint("TOPLEFT", 30, -110)
    _G[chkReturn:GetName() .. "Text"]:SetText(L["OPT_AUTORETURN"])
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
        configFrame.chkEnable:SetChecked(HuntTrackerDB.enabled)
        configFrame.chkHostile:SetChecked(HuntTrackerDB.onlyHostile)
        configFrame.chkReturn:SetChecked(HuntTrackerDB.autoReturn)
        configFrame:Show()
    end
end

SLASH_HUNTTRACKER1 = "/ht"
SLASH_HUNTTRACKER2 = "/hunttracker"
SlashCmdList["HUNTTRACKER"] = ToggleConfigMenu

-- =========================================================
-- УПРАВЛЕНИЕ МИНИКАРТОЙ
-- =========================================================
minimapButton:SetScript("OnClick", function(_, button)
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

minimapButton:SetScript("OnMouseDown", function(_, button)
    if button == "LeftButton" then
        isDragging = true
        UpdateMinimapDragState()
    end
end)

minimapButton:SetScript("OnMouseUp", function(_, button)
    if button == "LeftButton" then
        isDragging = false
        UpdateMinimapDragState()
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

HuntTracker:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        InitializeDefaults()
        BuildTrackingTable()
        UpdateMinimapButtonPosition()
        UpdateMinimapIcon()
        UpdateLogic()
    elseif event == "PLAYER_ENTERING_WORLD" then
        BuildTrackingTable()
        UpdateMinimapButtonPosition()
        UpdateLogic()
    elseif event == "PLAYER_TARGET_CHANGED" or event == "PLAYER_REGEN_ENABLED" then
        UpdateLogic()
    elseif event == "MINIMAP_UPDATE_TRACKING" then
        RefreshCurrentTrackingID()
        UpdateLogic()
    elseif event == "SPELLS_CHANGED" or event == "LEARNED_SPELL_IN_TAB" then
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