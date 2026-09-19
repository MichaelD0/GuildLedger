local ADDON_NAME, ns = ...

local GuildLedger = LibStub("AceAddon-3.0"):NewAddon("GuildLedger", "AceConsole-3.0", "AceEvent-3.0")
ns.addon = GuildLedger

GuildLedger.COMM_PREFIX = "GuildLedger1"

local defaults = {
    factionrealm = {
        guilds = {
            -- [guildName] = { bank = { tabs = {}, lastScan = 0, lastScannedBy = nil }, shoppingList = {} }
        },
    },
    profile = {
        -- Guild rank index (0 = Guild Master) at or below which a player may edit
        -- the shared shopping list. Lower index = higher rank.
        officerRankThreshold = 1,
        autoSyncOnBankOpen = true,
        lowStockThreshold = 5,
    },
}

function GuildLedger:OnInitialize()
    self.db = LibStub("AceDB-3.0"):New("GuildLedgerDB", defaults, true)
    self:RegisterChatCommand("gledger", "SlashCommand")
    self:RegisterChatCommand("guildledger", "SlashCommand")
end

function GuildLedger:OnEnable()
    self:RegisterComm(self.COMM_PREFIX)
    self:RegisterEvent("PLAYER_GUILD_UPDATE", "RefreshGuildData")
    self:RegisterMessage("GuildLedger_BankUpdated", "OnDataUpdated")
    self:RegisterMessage("GuildLedger_ListUpdated", "OnDataUpdated")
    self:RefreshGuildData()
end

function GuildLedger:OnDataUpdated()
    if self.ui then
        self.ui:Refresh()
    end
end

-- (Re)binds self.guildData to the current guild's saved table, creating it on
-- first sight of a guild. Called on login and whenever guild info changes
-- (covers realm/faction changes and switching characters between guilds).
function GuildLedger:RefreshGuildData()
    local guildName = GetGuildInfo("player")
    self.guildName = guildName
    if not guildName then
        self.guildData = nil
        return
    end

    local guilds = self.db.factionrealm.guilds
    guilds[guildName] = guilds[guildName] or {
        bank = { tabs = {}, lastScan = 0, lastScannedBy = nil },
        shoppingList = {},
    }
    self.guildData = guilds[guildName]
end

-- True if the player currently holds a guild rank allowed to edit the shared
-- shopping list (rank 0 is the Guild Master; lower index = higher rank).
function GuildLedger:IsOfficer()
    if not self.guildName then return false end
    if IsGuildLeader() then return true end
    local _, _, rankIndex = GetGuildInfo("player")
    return rankIndex ~= nil and rankIndex <= self.db.profile.officerRankThreshold
end

function GuildLedger:SlashCommand(input)
    input = input and input:trim() or ""
    if input == "sync" then
        if not self.guildData then
            self:Print("You're not in a guild.")
            return
        end
        self:RequestBankSync()
        self:Print("Requested a bank sync from the guild.")
    elseif input == "config" then
        Settings.OpenToCategory(self.optionsCategoryID or "GuildLedger")
    else
        if not self.ui then
            self:Print("UI not ready yet.")
            return
        end
        self.ui:Toggle()
    end
end
