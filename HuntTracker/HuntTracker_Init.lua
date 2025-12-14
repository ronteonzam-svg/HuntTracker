local addonName, addon = ...

addon.L = setmetatable({}, {
    __index = function(tbl, key)
        tbl[key] = key
        return key
    end
})