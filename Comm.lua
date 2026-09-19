local ADDON_NAME, ns = ...
local GuildLedger = ns.addon
local AceSerializer = LibStub("AceSerializer-3.0")

local MSG_BANK_SNAPSHOT = "BANK"
local MSG_LIST_SNAPSHOT = "LIST"
local MSG_SYNC_REQUEST = "REQ"

-- Broadcasts are last-writer-wins: whoever has the newest lastScan timestamp
-- (for the bank) wins on every client that receives it. Good enough for a
-- guild bank that isn't being edited by two officers in the same second;
-- revisit with vector clocks / merge-by-item if that becomes a real problem.

function GuildLedger:BroadcastBankSnapshot()
    if not self.guildData then return end
    local payload = AceSerializer:Serialize(MSG_BANK_SNAPSHOT, self.guildData.bank)
    self:SendCommMessage(self.COMM_PREFIX, payload, "GUILD")
end

function GuildLedger:BroadcastShoppingList()
    if not self.guildData then return end
    local payload = AceSerializer:Serialize(MSG_LIST_SNAPSHOT, self.guildData.shoppingList)
    self:SendCommMessage(self.COMM_PREFIX, payload, "GUILD")
end

-- Asks the guild "does anyone have a newer bank snapshot than mine?" so a
-- player who wasn't online for the last scan can catch up without needing
-- to visit the bank themselves.
function GuildLedger:RequestBankSync()
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
    elseif msgType == MSG_LIST_SNAPSHOT then
        self.guildData.shoppingList = data
        self:SendMessage("GuildLedger_ListUpdated")
    elseif msgType == MSG_SYNC_REQUEST then
        local theirLastScan = data or 0
        if (self.guildData.bank.lastScan or 0) > theirLastScan then
            self:BroadcastBankSnapshot()
        end
    end
end
