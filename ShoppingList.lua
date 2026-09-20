local ADDON_NAME, ns = ...
local GuildLedger = ns.addon

-- The shopping list is per character and never leaves this client: it lives in
-- db.char, so two people can keep their own lists of what they mean to pick up
-- without either one overwriting the other. The guild bank half of the addon
-- is still shared; only the list is private.
function GuildLedger:GetShoppingList()
    return self.db.char.shoppingList
end

-- Adds or updates an entry on your shopping list. itemLink can be a full item
-- link (e.g. shift-clicked from a bag/bank slot) or anything
-- C_Item.GetItemInfoInstant can resolve to an itemID.
function GuildLedger:AddShoppingListItem(itemLink, desiredCount, note)
    local itemID = C_Item.GetItemInfoInstant(itemLink)
    if not itemID then
        self:Print("Could not resolve that item.")
        return false
    end

    self:GetShoppingList()[itemID] = {
        itemLink = itemLink,
        desired = desiredCount or 1,
        note = note,
        addedAt = time(),
    }
    self:SendMessage("GuildLedger_ListUpdated")
    return true
end

-- Changes how many of an item you want. Separated from AddShoppingListItem so
-- editing a quantity doesn't rewrite addedAt.
function GuildLedger:SetShoppingListQuantity(itemID, desired)
    local entry = self:GetShoppingList()[itemID]
    if not entry then return false end

    desired = tonumber(desired)
    if not desired then
        self:Print("That quantity isn't a number.")
        return false
    end

    -- A wanted count below 1 means the item shouldn't be listed at all.
    desired = math.floor(desired)
    if desired < 1 then
        return self:RemoveShoppingListItem(itemID)
    end

    entry.desired = desired
    self:SendMessage("GuildLedger_ListUpdated")
    return true
end

function GuildLedger:RemoveShoppingListItem(itemID)
    self:GetShoppingList()[itemID] = nil
    self:SendMessage("GuildLedger_ListUpdated")
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
-- most short of their target come first. Without a guild (or before the first
-- scan) every "have" is simply 0 - the list itself is still yours to keep.
function GuildLedger:GetShoppingListStatus()
    local results = {}

    for itemID, entry in pairs(self:GetShoppingList()) do
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
