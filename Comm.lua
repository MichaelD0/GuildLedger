local ADDON_NAME, ns = ...
local GuildLedger = ns.addon
local AceSerializer = LibStub("AceSerializer-3.0")

local MSG_BANK_SNAPSHOT = "BANK"
local MSG_SYNC_REQUEST = "REQ"

-- Only the bank travels between clients. Bank snapshots are accepted from
-- anyone: a scan is just an observation, and whoever is standing at the banker
-- is the only one who can make it. The shopping list is deliberately not
-- shared - it lives in each character's saved variables and never goes on the
-- wire, which is what keeps it free of merge conflicts and rank checks.
--
-- Broadcasts are last-writer-wins: whoever has the newest lastScan timestamp
-- wins on every client that receives it. Good enough for a guild bank that
-- isn't scanned by two people in the same second; revisit with merge-by-item
-- if that becomes a real problem.

function GuildLedger:BroadcastBankSnapshot()
    if not self.guildData then return end
    local payload = AceSerializer:Serialize(MSG_BANK_SNAPSHOT, self.guildData.bank)
    self:SendCommMessage(self.COMM_PREFIX, payload, "GUILD")
end

-- Asks the guild for a newer bank snapshot than ours, if anyone has one.
-- Without this a player who was offline for the last scan keeps their stale
-- saved copy until someone happens to scan again, since snapshots are only
-- broadcast at the moment they're taken.
function GuildLedger:RequestSync()
    if not self.guildData then return end
    local payload = AceSerializer:Serialize(MSG_SYNC_REQUEST, self.guildData.bank.lastScan or 0)
    self:SendCommMessage(self.COMM_PREFIX, payload, "GUILD")
end

function GuildLedger:OnCommReceived(prefix, message, distribution, sender)
    if prefix ~= self.COMM_PREFIX or not self.guildData then return end

    local ok, msgType, data = AceSerializer:Deserialize(message)
    if not ok then return end

    if msgType == MSG_BANK_SNAPSHOT then
        if (data.lastScan or 0) > (self.guildData.bank.lastScan or 0) then
            self.guildData.bank = data
            self:SendMessage("GuildLedger_BankUpdated")
        end
    elseif msgType == MSG_SYNC_REQUEST then
        local theirLastScan = data or 0
        if (self.guildData.bank.lastScan or 0) > theirLastScan then
            self:BroadcastBankSnapshot()
        end
    end
end
