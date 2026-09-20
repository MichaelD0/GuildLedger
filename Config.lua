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
        autoOpenOnBankOpen = {
            type = "toggle",
            name = "Open the window at the guild bank",
            desc = "Show the GuildLedger window automatically when you open the guild bank, and close it again when you walk away. A window you opened yourself beforehand is left alone.",
            order = 2,
            width = "full",
            get = function() return GuildLedger.db.profile.autoOpenOnBankOpen end,
            set = function(_, value) GuildLedger.db.profile.autoOpenOnBankOpen = value end,
        },
        showOnAuctionHouse = {
            type = "toggle",
            name = "Show the shopping list at the auction house",
            desc = "Pin the guild shopping list beside the auction house window. Click a row to search for that item.",
            order = 3,
            width = "full",
            get = function() return GuildLedger.db.profile.showOnAuctionHouse end,
            set = function(_, value)
                GuildLedger.db.profile.showOnAuctionHouse = value
                if GuildLedger.ah then
                    GuildLedger.ah:UpdateVisibility()
                end
            end,
        },
        officerRankThreshold = {
            type = "range",
            name = "Officer rank threshold",
            desc = "Guild rank index (0 = Guild Master) at or above which a member can edit the shared shopping list. Lower number = fewer people can edit.",
            order = 4,
            min = 0,
            max = 9,
            step = 1,
            width = "full",
            get = function() return GuildLedger.db.profile.officerRankThreshold end,
            set = function(_, value) GuildLedger.db.profile.officerRankThreshold = value end,
        },
        fontSize = {
            type = "range",
            name = "Font size",
            desc = "Text size used throughout the GuildLedger window.",
            order = 5,
            min = 10,
            max = 24,
            step = 1,
            width = "full",
            get = function() return GuildLedger.db.profile.fontSize end,
            set = function(_, value)
                if GuildLedger.ui then
                    GuildLedger.ui:SetFontSize(value)
                else
                    GuildLedger.db.profile.fontSize = value
                end
            end,
        },
        lowStockThreshold = {
            type = "range",
            name = "Low stock threshold",
            desc = "Reserved for a future low-stock warning feature.",
            order = 6,
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
