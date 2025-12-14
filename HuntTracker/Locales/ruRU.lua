local addonName, addon = ...
local L = addon.L

if GetLocale() ~= "ruRU" then return end

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