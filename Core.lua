local ADDON_NAME, ns = ...

-- AceComm-3.0 must be mixed in here, not just loaded: RegisterComm,
-- SendCommMessage and OnCommReceived are all methods on the addon object.
local GuildLedger = LibStub("AceAddon-3.0"):NewAddon("GuildLedger", "AceConsole-3.0", "AceEvent-3.0", "AceComm-3.0")
ns.addon = GuildLedger

GuildLedger.COMM_PREFIX = "GuildLedger1"

-- Characters who may always edit the shared shopping list, whatever their
-- guild rank. This is baked into the addon rather than kept in saved
-- variables on purpose: every client validates incoming edits against this
-- same table, so an entry only one person has would be rejected by everyone
-- else.
--
-- A key of "Drakktar" matches that name on any realm; "Drakktar-Ravencrest"
-- matches only that character. Prefer the suffixed form if the name is at all
-- common - the realm suffix is the only thing separating you from a guildmate
-- who picked the same name on a connected realm.
GuildLedger.ALWAYS_ALLOWED_EDITORS = {
    ["Drakktar-Illidan"] = true,
}

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
        autoOpenOnBankOpen = true,
        showOnAuctionHouse = true,
        lowStockThreshold = 5,
        fontSize = 14,
        debug = false,
        -- AceGUI's own status table for the main window (width/height/top/left).
        -- Living in the profile is what makes the window stay where you parked
        -- it across sessions, which matters now that it opens itself at the bank.
        window = { width = 560, height = 560 },
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
        shoppingList = {},
    }
    self.guildData = guilds[guildName]

    -- Catch up once per session, a few seconds after the guild resolves, so a
    -- member who was offline for the last edits doesn't sit on a stale list
    -- until someone happens to change something. RefreshGuildData runs on
    -- every roster update, hence the guard.
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

-- Addon message senders arrive as "Name" or "Name-Realm" depending on whether
-- the realm is connected, while the roster always reports "Name-Realm".
-- Comparing on the character name alone makes both forms line up.
local function ShortName(name)
    if not name then return nil end
    return name:match("^[^-]+") or name
end

-- The reverse of ShortName: "Drakktar" becomes "Drakktar-YourRealm". Bare
-- names only ever reach us from our own realm (connected-realm senders always
-- carry a suffix), so filling in the local realm is correct.
local function FullName(name)
    if not name then return nil end
    if name:find("-", 1, true) then return name end
    local realm = GetNormalizedRealmName()
    if not realm then return name end
    return name .. "-" .. realm
end

-- Accepts either style of allowlist key: "Drakktar" matches that name on any
-- realm, "Drakktar-Ravencrest" matches only that character. Both are checked
-- against both forms of the incoming name, since the local player arrives
-- bare (UnitName) and the roster arrives suffixed.
function GuildLedger:IsAlwaysAllowedEditor(name)
    if not name then return false end
    if self.ALWAYS_ALLOWED_EDITORS[name] then return true end

    local full = FullName(name)
    if full and self.ALWAYS_ALLOWED_EDITORS[full] then return true end

    local short = ShortName(name)
    return short ~= nil and self.ALWAYS_ALLOWED_EDITORS[short] == true
end

-- Guild rank of another player, from the roster. Only ever called for someone
-- who just sent an addon message, so they are online and therefore present in
-- the roster regardless of the show-offline setting.
function GuildLedger:GetGuildRankIndexFor(name)
    local short = ShortName(name)
    if not short then return nil end

    local numTotal = GetNumGuildMembers()
    for i = 1, (numTotal or 0) do
        local rosterName, _, rankIndex = GetGuildRosterInfo(i)
        if rosterName and ShortName(rosterName) == short then
            return rankIndex
        end
    end
    return nil
end

-- True if the named player may edit the shared shopping list (rank 0 is the
-- Guild Master; lower index = higher rank). Pass nil for the local player.
-- Senders of addon messages are supplied by the server and can't be forged,
-- so this is meaningful for remote players too, not just a UI courtesy.
function GuildLedger:CanEditList(sender)
    if not self.guildName then return false end

    if not sender then
        if self:IsAlwaysAllowedEditor(UnitName("player")) then return true end
        if IsGuildLeader() then return true end
        local _, _, rankIndex = GetGuildInfo("player")
        return rankIndex ~= nil and rankIndex <= self.db.profile.officerRankThreshold
    end

    if self:IsAlwaysAllowedEditor(sender) then return true end
    local rankIndex = self:GetGuildRankIndexFor(sender)
    return rankIndex ~= nil and rankIndex <= self.db.profile.officerRankThreshold
end

function GuildLedger:IsOfficer()
    return self:CanEditList()
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
        self:Print("Requested a bank and shopping list sync from the guild.")
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
