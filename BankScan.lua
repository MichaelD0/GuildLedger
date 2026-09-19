local ADDON_NAME, ns = ...
local GuildLedger = ns.addon

-- NOTE ON API SURFACE: this file uses the long-standing global guild bank
-- functions (QueryGuildBankTab, GetGuildBankTabInfo, GetGuildBankItemInfo,
-- GetNumGuildBankTabs). These have been stable for a long time, but Blizzard
-- periodically migrates old globals into C_ namespaces - if any of these are
-- nil when you load the addon in-game, check the current signatures on
-- Warcraft Wiki before anything else.

local scanning = false
local scanTicker

-- Guild bank tab queries are asynchronous; the server pushes data down over
-- a second or so. Rather than track exactly which tab a given
-- GUILDBANKBAGSLOTS_CHANGED event refers to (that event carries no tab
-- index), we just re-read everything a few times over ~3 seconds and take
-- the last read as truth. Simple, and self-correcting if a read lands mid-tab.
local RESCAN_TICKS = 6
local RESCAN_INTERVAL = 0.5

function GuildLedger:StartBankScan()
    if not self.guildData or scanning then return end
    scanning = true

    local numTabs = GetNumGuildBankTabs()
    for tabIndex = 1, numTabs do
        QueryGuildBankTab(tabIndex)
    end

    local ticksLeft = RESCAN_TICKS
    scanTicker = C_Timer.NewTicker(RESCAN_INTERVAL, function()
        self:ReadAllTabs(numTabs)
        ticksLeft = ticksLeft - 1
        if ticksLeft <= 0 then
            self:FinishBankScan()
        end
    end, RESCAN_TICKS)
end

function GuildLedger:ReadAllTabs(numTabs)
    if not self.guildData then return end
    for tabIndex = 1, numTabs do
        self:ReadTab(tabIndex)
    end
end

function GuildLedger:ReadTab(tabIndex)
    local name, icon, isViewable = GetGuildBankTabInfo(tabIndex)
    if not name then return end

    local tabData = { name = name, icon = icon, slots = {} }
    for slot = 1, MAX_GUILDBANK_SLOTS_PER_TAB do
        local itemLink, itemCount = GetGuildBankItemInfo(tabIndex, slot)
        if itemLink then
            local itemID = C_Item.GetItemInfoInstant(itemLink)
            tabData.slots[slot] = {
                itemLink = itemLink,
                itemID = itemID,
                count = itemCount or 0,
            }
        end
    end
    self.guildData.bank.tabs[tabIndex] = tabData
end

function GuildLedger:FinishBankScan()
    scanning = false
    if scanTicker then
        scanTicker:Cancel()
        scanTicker = nil
    end

    self.guildData.bank.lastScan = time()
    self.guildData.bank.lastScannedBy = UnitName("player")
    self:SendMessage("GuildLedger_BankUpdated")

    if self.db.profile.autoSyncOnBankOpen then
        self:BroadcastBankSnapshot()
    end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("GUILDBANKFRAME_OPENED")
frame:RegisterEvent("GUILDBANKFRAME_CLOSED")
frame:SetScript("OnEvent", function(_, event)
    if event == "GUILDBANKFRAME_OPENED" then
        GuildLedger:StartBankScan()
    elseif event == "GUILDBANKFRAME_CLOSED" then
        scanning = false
        if scanTicker then
            scanTicker:Cancel()
            scanTicker = nil
        end
    end
end)
