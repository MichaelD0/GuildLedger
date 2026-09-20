local ADDON_NAME, ns = ...

-- AceComm-3.0 must be mixed in here, not just loaded: RegisterComm,
-- SendCommMessage and OnCommReceived are all methods on the addon object.
local GuildLedger = LibStub("AceAddon-3.0"):NewAddon("GuildLedger", "AceConsole-3.0", "AceEvent-3.0", "AceComm-3.0")
ns.addon = GuildLedger

GuildLedger.COMM_PREFIX = "GuildLedger1"

local defaults = {
    global = {
        -- Ring buffer of recent trace lines; see GuildLedger:Trace.
        trace = {},
    },
    factionrealm = {
        guilds = {
            -- [guildName] = { bank = { tabs = {}, lastScan = 0, lastScannedBy = nil } }
        },
    },
    -- The shopping list is yours alone: per character, never broadcast, never
    -- overwritten by a guildmate. Only the bank is shared.
    char = {
        shoppingList = {},
    },
    profile = {
        autoSyncOnBankOpen = true,
        autoOpenOnBankOpen = true,
        showOnAuctionHouse = true,
        lowStockThreshold = 5,
        fontSize = 14,
        debug = false,
        -- AceGUI's own status table for the main window (width/height/top/left).
        -- Living in the profile is what makes the window stay where you parked
        -- it across sessions, which matters now that it opens itself at the bank.
        window = { width = 620, height = 560 },
    },
}

function GuildLedger:OnInitialize()
    self.db = LibStub("AceDB-3.0"):New("GuildLedgerDB", defaults, true)
    self:RegisterChatCommand("gledger", "SlashCommand")
    self:RegisterChatCommand("guildledger", "SlashCommand")
end

function GuildLedger:OnEnable()
    self:Trace(("--- session start: GuildLedger %s, client %s ---"):format(
        (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version")) or "?",
        tostring(select(4, GetBuildInfo()))))

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
    if self.ah then
        -- UpdateVisibility, not Refresh: a first item added while the auction
        -- house is open has to make the panel appear, not just repopulate it.
        self.ah:UpdateVisibility()
    end
end

-- True while the guild bank window is open. GUILDBANKFRAME_OPENED is dead on
-- retail (see BankScan.lua), so the interaction manager is the only honest
-- answer; the nil guards keep this working if that API moves again.
function GuildLedger:IsAtGuildBanker()
    local mgr = C_PlayerInteractionManager
    if not (mgr and mgr.IsInteractingWithNpcOfType and Enum and Enum.PlayerInteractionType) then
        return false
    end
    return mgr.IsInteractingWithNpcOfType(Enum.PlayerInteractionType.GuildBanker) and true or false
end

-- For a second or two after login the client knows you're in a guild
-- (IsInGuild() is already true) but GetGuildInfo("player") still returns nil,
-- because the guild name arrives with the roster rather than with the player.
-- Taking that nil at face value permanently strands guildData, so we poll
-- until the name lands instead.
-- Long enough after login that the guild channel is up and we aren't adding
-- to the addon message burst everything else makes on arrival.
local INITIAL_SYNC_DELAY = 8

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
    }
    self.guildData = guilds[guildName]

    -- Carry over a list saved back when it was guild-shared, so nobody loses
    -- what they had typed in. Entries already on this character win.
    if self.guildData.shoppingList then
        for itemID, entry in pairs(self.guildData.shoppingList) do
            if self.db.char.shoppingList[itemID] == nil then
                self.db.char.shoppingList[itemID] = entry
            end
        end
        self.guildData.shoppingList = nil
    end

    -- Catch up once per session, a few seconds after the guild resolves, so a
    -- member who was offline for the last scan doesn't sit on a stale bank
    -- until someone happens to scan again. RefreshGuildData runs on every
    -- roster update, hence the guard.
    if not self.requestedInitialSync then
        self.requestedInitialSync = true
        C_Timer.After(INITIAL_SYNC_DELAY, function()
            if self.guildData then
                self:Debug("requesting initial sync from the guild")
                self:RequestSync()
            end
        end)
    end

    -- The window may already be open showing "You're not in a guild."
    self:OnDataUpdated()
end

-- Trace lines go to saved variables whether or not tracing is being printed,
-- so a problem can be read back afterwards rather than needing /gledger debug
-- to have been switched on before it happened. Capped at TRACE_MAX lines - a
-- few tens of kilobytes at worst - and flushed to
-- WTF/Account/<account>/SavedVariables/GuildLedger.lua on logout or /reload,
-- the only moments WoW writes saved variables at all.
local TRACE_MAX = 200

function GuildLedger:Trace(msg)
    if not self.db then return end

    local trace = self.db.global.trace
    trace[#trace + 1] = ("%s  %s  %s"):format(
        date("%Y-%m-%d %H:%M:%S"), UnitName("player") or "?", msg)

    -- Oldest-first so the file reads in order. A shift costs O(n) on a 200
    -- entry table, which is nothing next to how rarely Debug is called.
    while #trace > TRACE_MAX do
        table.remove(trace, 1)
    end
end

-- Records always, prints only when tracing is on (/gledger debug).
function GuildLedger:Debug(fmt, ...)
    local msg = fmt
    if select("#", ...) > 0 then
        msg = fmt:format(...)
    end

    self:Trace(msg)

    if not self.db or not self.db.profile.debug then return end
    self:Print("|cff888888[trace]|r " .. msg)
end

-- Dumps everything worth knowing when the addon appears to be doing nothing:
-- whether the guild is bound, what the last scan produced, and whether the
-- guild bank APIs this addon depends on actually exist on this client.
function GuildLedger:PrintStatus()
    self:Print("guild: " .. tostring(self.guildName))
    self:Print("guildData: " .. (self.guildData and "bound" or "nil"))

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
    end

    local listed = 0
    for _ in pairs(self:GetShoppingList()) do listed = listed + 1 end
    self:Print(("shopping list: %d entry(ies) (this character only)"):format(listed))

    self:Print(("trace: %d/%d line(s) buffered"):format(#self.db.global.trace, TRACE_MAX))

    self:Print("at guild banker: " .. tostring(self:IsAtGuildBanker()))
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
        self:RequestSync()
        self:Print("Requested a fresh bank snapshot from the guild.")
    elseif input == "trace" then
        self:Print(("%d of %d trace line(s) buffered."):format(#self.db.global.trace, TRACE_MAX))
        -- Forward slashes on purpose: Lua 5.1 drops the backslash on an
        -- unknown escape, so a Windows path written the Windows way in a
        -- string literal silently loses its separators.
        self:Print("Written to WTF/Account/<account>/SavedVariables/GuildLedger.lua on logout or /reload.")
    elseif input == "trace clear" then
        wipe(self.db.global.trace)
        self:Print("Trace buffer cleared.")
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
