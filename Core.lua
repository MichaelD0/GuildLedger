local ADDON_NAME, ns = ...

-- AceComm-3.0 must be mixed in here, not just loaded: RegisterComm,
-- SendCommMessage and OnCommReceived are all methods on the addon object.
local GuildLedger = LibStub("AceAddon-3.0"):NewAddon("GuildLedger", "AceConsole-3.0", "AceEvent-3.0", "AceComm-3.0")
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
        debug = false,
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
    self:RegisterEvent("PLAYER_ENTERING_WORLD", "RefreshGuildData")
    self:RegisterEvent("GUILD_ROSTER_UPDATE", "RefreshGuildData")
    self:RegisterMessage("GuildLedger_BankUpdated", "OnDataUpdated")
    self:RegisterMessage("GuildLedger_ListUpdated", "OnDataUpdated")
    self:RefreshGuildData()
end

function GuildLedger:OnDataUpdated()
    if self.ui then
        self.ui:Refresh()
    end
end

-- For a second or two after login the client knows you're in a guild
-- (IsInGuild() is already true) but GetGuildInfo("player") still returns nil,
-- because the guild name arrives with the roster rather than with the player.
-- Taking that nil at face value permanently strands guildData, so we poll
-- until the name lands instead.
local GUILD_INFO_RETRY_INTERVAL = 1
local GUILD_INFO_MAX_RETRIES = 15
local guildInfoTicker
local guildInfoRetries = 0

function GuildLedger:StopGuildInfoRetry()
    if guildInfoTicker then
        guildInfoTicker:Cancel()
        guildInfoTicker = nil
    end
    guildInfoRetries = 0
end

function GuildLedger:StartGuildInfoRetry()
    if guildInfoTicker then return end
    guildInfoRetries = 0

    -- Nudge the server for the roster; the name usually arrives with it.
    if C_GuildInfo and C_GuildInfo.GuildRoster then
        C_GuildInfo.GuildRoster()
    end

    guildInfoTicker = C_Timer.NewTicker(GUILD_INFO_RETRY_INTERVAL, function()
        guildInfoRetries = guildInfoRetries + 1
        if guildInfoRetries >= GUILD_INFO_MAX_RETRIES then
            self:StopGuildInfoRetry()
            return
        end
        self:RefreshGuildData()
    end)
end

-- (Re)binds self.guildData to the current guild's saved table, creating it on
-- first sight of a guild. Called on login and whenever guild info changes
-- (covers realm/faction changes and switching characters between guilds).
function GuildLedger:RefreshGuildData()
    local guildName = GetGuildInfo("player")

    if not guildName then
        self.guildName = nil
        self.guildData = nil
        -- IsInGuild() without a name means "not loaded yet", not "no guild".
        -- A genuinely guildless character falls through and simply stops here.
        if IsInGuild() then
            self:StartGuildInfoRetry()
        end
        return
    end

    self:StopGuildInfoRetry()
    self.guildName = guildName

    local guilds = self.db.factionrealm.guilds
    guilds[guildName] = guilds[guildName] or {
        bank = { tabs = {}, lastScan = 0, lastScannedBy = nil },
        shoppingList = {},
    }
    self.guildData = guilds[guildName]

    -- The window may already be open showing "You're not in a guild."
    self:OnDataUpdated()
end

-- True if the player currently holds a guild rank allowed to edit the shared
-- shopping list (rank 0 is the Guild Master; lower index = higher rank).
function GuildLedger:IsOfficer()
    if not self.guildName then return false end
    if IsGuildLeader() then return true end
    local _, _, rankIndex = GetGuildInfo("player")
    return rankIndex ~= nil and rankIndex <= self.db.profile.officerRankThreshold
end

-- Prints only when tracing is on (/gledger debug). Kept cheap so Debug calls
-- can sit on hot-ish paths like the bank scan without costing anything when
-- tracing is off.
function GuildLedger:Debug(fmt, ...)
    if not self.db or not self.db.profile.debug then return end
    local msg = fmt
    if select("#", ...) > 0 then
        msg = fmt:format(...)
    end
    self:Print("|cff888888[trace]|r " .. msg)
end

-- Dumps everything worth knowing when the addon appears to be doing nothing:
-- whether the guild is bound, what the last scan produced, and whether the
-- guild bank APIs this addon depends on actually exist on this client.
function GuildLedger:PrintStatus()
    self:Print("guild: " .. tostring(self.guildName))
    self:Print("guildData: " .. (self.guildData and "bound" or "nil"))
    self:Print("officer: " .. tostring(self:IsOfficer()))

    if self.guildData then
        local bank = self.guildData.bank
        local tabs, stacks = 0, 0
        for _, tab in pairs(bank.tabs) do
            tabs = tabs + 1
            for _ in pairs(tab.slots) do stacks = stacks + 1 end
        end
        self:Print(("cached: %d tab(s), %d item stack(s)"):format(tabs, stacks))
        if bank.lastScan and bank.lastScan > 0 then
            self:Print(("last scan: %s by %s"):format(
                date("%Y-%m-%d %H:%M:%S", bank.lastScan), tostring(bank.lastScannedBy)))
        else
            self:Print("last scan: never")
        end

        local listed = 0
        for _ in pairs(self.guildData.shoppingList) do listed = listed + 1 end
        self:Print(("shopping list: %d entry(ies)"):format(listed))
    end

    local atBanker = C_PlayerInteractionManager
        and C_PlayerInteractionManager.IsInteractingWithNpcOfType
        and C_PlayerInteractionManager.IsInteractingWithNpcOfType(Enum.PlayerInteractionType.GuildBanker)
    self:Print("at guild banker: " .. tostring(atBanker))
    self:Print(("api: GetNumGuildBankTabs=%s GetGuildBankItemLink=%s tabs=%s"):format(
        tostring(GetNumGuildBankTabs ~= nil),
        tostring(GetGuildBankItemLink ~= nil),
        tostring(GetNumGuildBankTabs and GetNumGuildBankTabs() or "?")))
end

function GuildLedger:SlashCommand(input)
    input = input and input:trim() or ""
    if input == "debug" then
        self.db.profile.debug = not self.db.profile.debug
        self:Print("Tracing " .. (self.db.profile.debug and "ON" or "OFF") .. ".")
    elseif input == "status" then
        self:PrintStatus()
    elseif input == "scan" then
        self:Print("Forcing a bank scan (must be at a guild banker).")
        self:StartBankScan()
    elseif input == "sync" then
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
