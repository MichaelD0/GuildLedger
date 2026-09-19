local ADDON_NAME, ns = ...
local GuildLedger = ns.addon
local AceConfig = LibStub("AceConfig-3.0")
local AceConfigDialog = LibStub("AceConfigDialog-3.0")

local options = {
    type = "group",
    name = "GuildLedger",
    args = {
        autoSyncOnBankOpen = {
            type = "toggle",
            name = "Auto-broadcast after scanning",
            desc = "Send your bank scan to the guild automatically after you visit the guild bank.",
            order = 1,
            width = "full",
            get = function() return GuildLedger.db.profile.autoSyncOnBankOpen end,
            set = function(_, value) GuildLedger.db.profile.autoSyncOnBankOpen = value end,
        },
        officerRankThreshold = {
            type = "range",
            name = "Officer rank threshold",
            desc = "Guild rank index (0 = Guild Master) at or above which a member can edit the shared shopping list. Lower number = fewer people can edit.",
            order = 2,
            min = 0,
            max = 9,
            step = 1,
            width = "full",
            get = function() return GuildLedger.db.profile.officerRankThreshold end,
            set = function(_, value) GuildLedger.db.profile.officerRankThreshold = value end,
        },
        lowStockThreshold = {
            type = "range",
            name = "Low stock threshold",
            desc = "Reserved for a future low-stock warning feature.",
            order = 3,
            min = 0,
            max = 50,
            step = 1,
            width = "full",
            get = function() return GuildLedger.db.profile.lowStockThreshold end,
            set = function(_, value) GuildLedger.db.profile.lowStockThreshold = value end,
        },
    },
}

AceConfig:RegisterOptionsTable("GuildLedger", options)
GuildLedger.optionsCategoryID = LibStub("AceConfigDialog-3.0"):AddToBlizOptions("GuildLedger", "GuildLedger")
