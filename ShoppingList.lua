local ADDON_NAME, ns = ...
local GuildLedger = ns.addon

-- Adds or updates an entry on the guild-shared shopping list. itemLink can be
-- a full item link (e.g. shift-clicked from a bag/bank slot) or anything
-- C_Item.GetItemInfoInstant can resolve to an itemID.
function GuildLedger:AddShoppingListItem(itemLink, desiredCount, note)
    if not self:IsOfficer() then
        self:Print("Only officers can edit the guild shopping list.")
        return false
    end
    if not self.guildData then
        self:Print("You're not in a guild.")
        return false
    end

    local itemID = C_Item.GetItemInfoInstant(itemLink)
    if not itemID then
        self:Print("Could not resolve that item.")
        return false
    end

    self.guildData.shoppingList[itemID] = {
        itemLink = itemLink,
        desired = desiredCount or 1,
        note = note,
        addedBy = UnitName("player"),
        addedAt = time(),
    }
    self:SendMessage("GuildLedger_ListUpdated")
    self:BroadcastShoppingList()
    return true
end

function GuildLedger:RemoveShoppingListItem(itemID)
    if not self:IsOfficer() then
        self:Print("Only officers can edit the guild shopping list.")
        return false
    end
    if not self.guildData then return false end

    self.guildData.shoppingList[itemID] = nil
    self:SendMessage("GuildLedger_ListUpdated")
    self:BroadcastShoppingList()
    return true
end

-- Total count of itemID currently seen across all scanned bank tabs.
function GuildLedger:GetBankCount(itemID)
    local total = 0
    if not self.guildData then return total end
    for _, tab in pairs(self.guildData.bank.tabs) do
        for _, slot in pairs(tab.slots) do
            if slot.itemID == itemID then
                total = total + (slot.count or 0)
            end
        end
    end
    return total
end

-- Returns a display-ready array of
-- { itemID, itemLink, desired, have, missing, note }, sorted so the items
-- most short of their target come first.
function GuildLedger:GetShoppingListStatus()
    local results = {}
    if not self.guildData then return results end

    for itemID, entry in pairs(self.guildData.shoppingList) do
        local have = self:GetBankCount(itemID)
        table.insert(results, {
            itemID = itemID,
            itemLink = entry.itemLink,
            desired = entry.desired,
            have = have,
            missing = math.max(0, entry.desired - have),
            note = entry.note,
        })
    end

    table.sort(results, function(a, b) return a.missing > b.missing end)
    return results
end
