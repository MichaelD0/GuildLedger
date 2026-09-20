local ADDON_NAME, ns = ...
local GuildLedger = ns.addon

-- NOTE ON API SURFACE: verified against retail 12.1.0. QueryGuildBankTab,
-- GetGuildBankTabInfo, GetGuildBankItemInfo, GetGuildBankItemLink and
-- GetNumGuildBankTabs are all still globals. Two things that are easy to get
-- wrong and were wrong here:
--   * GetGuildBankItemInfo returns texture first, not a link. The item link
--     has its own getter, GetGuildBankItemLink.
--   * MAX_GUILDBANK_SLOTS_PER_TAB no longer exists; see SLOTS_PER_TAB below.

local scanning = false
local scanTicker

-- Guild bank tab queries are asynchronous; the server pushes data down over
-- a second or so. Rather than track exactly which tab a given
-- GUILDBANKBAGSLOTS_CHANGED event refers to (that event carries no tab
-- index), we just re-read everything a few times over ~3 seconds and take
-- the last read as truth. Simple, and self-correcting if a read lands mid-tab.
local RESCAN_TICKS = 6
local RESCAN_INTERVAL = 0.5

-- 98 slots per tab (14 columns x 7 rows). Blizzard removed the
-- MAX_GUILDBANK_SLOTS_PER_TAB global, so this is hardcoded the same way
-- current bank addons do it.
local SLOTS_PER_TAB = 98

function GuildLedger:StartBankScan()
    if not self.guildData then
        self:Debug("scan skipped: no guild data bound")
        return
    end
    if scanning then
        self:Debug("scan skipped: already scanning")
        return
    end
    scanning = true

    local numTabs = GetNumGuildBankTabs()
    self:Debug("scanning %d tab(s)", numTabs or 0)
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

    -- A tab this rank can't view reads back empty. Still record it, so the UI
    -- shows the tab with no items rather than pretending it doesn't exist.
    if isViewable then
        for slot = 1, SLOTS_PER_TAB do
            local itemLink = GetGuildBankItemLink(tabIndex, slot)
            if itemLink then
                local _, itemCount = GetGuildBankItemInfo(tabIndex, slot)
                local itemID = C_Item.GetItemInfoInstant(itemLink)
                tabData.slots[slot] = {
                    itemLink = itemLink,
                    itemID = itemID,
                    count = itemCount or 0,
                }
            end
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

    local tabs, stacks = 0, 0
    for _, tab in pairs(self.guildData.bank.tabs) do
        tabs = tabs + 1
        for _ in pairs(tab.slots) do stacks = stacks + 1 end
    end
    self:Debug("scan finished: %d tab(s), %d item stack(s)", tabs, stacks)

    self:SendMessage("GuildLedger_BankUpdated")

    if self.db.profile.autoSyncOnBankOpen then
        self:BroadcastBankSnapshot()
    end
end

-- GUILDBANKFRAME_OPENED / _CLOSED still exist as event names on retail (so
-- registering them raises no error) but nothing fires them for the guild bank
-- any more - open/close now arrives through the player interaction manager.
-- Listening for the old pair fails completely silently, which is exactly how
-- this went unnoticed.
local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
frame:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE")
frame:SetScript("OnEvent", function(_, event, interactionType)
    if interactionType ~= Enum.PlayerInteractionType.GuildBanker then return end

    if event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" then
        GuildLedger:Debug("guild banker opened, starting scan")
        GuildLedger:StartBankScan()
    else
        GuildLedger:Debug("guild banker closed")
        scanning = false
        if scanTicker then
            scanTicker:Cancel()
            scanTicker = nil
        end
    end
end)
