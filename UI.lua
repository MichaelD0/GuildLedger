local ADDON_NAME, ns = ...
local GuildLedger = ns.addon
local AceGUI = LibStub("AceGUI-3.0")

local UI = {}
GuildLedger.ui = UI

local frame

local function AddTooltip(widget, itemLink)
    widget:SetCallback("OnEnter", function(w)
        GameTooltip:SetOwner(w.frame, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink(itemLink)
        GameTooltip:Show()
    end)
    widget:SetCallback("OnLeave", function() GameTooltip:Hide() end)
end

local function BuildBankTab(container)
    local scroll = AceGUI:Create("ScrollFrame")
    scroll:SetLayout("List")
    scroll:SetFullWidth(true)
    scroll:SetFullHeight(true)
    container:AddChild(scroll)

    if not GuildLedger.guildData then
        local label = AceGUI:Create("Label")
        label:SetText("You're not in a guild.")
        scroll:AddChild(label)
        return
    end

    local bank = GuildLedger.guildData.bank
    local header = AceGUI:Create("Label")
    header:SetFullWidth(true)
    if bank.lastScan and bank.lastScan > 0 then
        header:SetText(("Last synced by %s, %d min ago. Click an item to add it to the shopping list."):format(
            bank.lastScannedBy or "?", math.floor((time() - bank.lastScan) / 60)))
    else
        header:SetText("No bank data yet. Open the guild bank to scan it, or run /gledger sync.")
    end
    scroll:AddChild(header)

    local tabIndices = {}
    for tabIndex in pairs(bank.tabs) do
        table.insert(tabIndices, tabIndex)
    end
    table.sort(tabIndices)

    for _, tabIndex in ipairs(tabIndices) do
        local tab = bank.tabs[tabIndex]
        local tabHeader = AceGUI:Create("Heading")
        tabHeader:SetText(tab.name or ("Tab " .. tabIndex))
        tabHeader:SetFullWidth(true)
        scroll:AddChild(tabHeader)

        local slotIndices = {}
        for slot in pairs(tab.slots) do
            table.insert(slotIndices, slot)
        end
        table.sort(slotIndices)

        for _, slot in ipairs(slotIndices) do
            local item = tab.slots[slot]
            local row = AceGUI:Create("InteractiveLabel")
            row:SetText(("%s  x%d"):format(item.itemLink, item.count or 0))
            row:SetFullWidth(true)
            AddTooltip(row, item.itemLink)
            row:SetCallback("OnClick", function()
                if GuildLedger:AddShoppingListItem(item.itemLink, 1, nil) then
                    GuildLedger:Print(("Added %s to the shopping list."):format(item.itemLink))
                end
            end)
            scroll:AddChild(row)
        end
    end
end

local function BuildShoppingTab(container)
    local scroll = AceGUI:Create("ScrollFrame")
    scroll:SetLayout("List")
    scroll:SetFullWidth(true)
    scroll:SetFullHeight(true)
    container:AddChild(scroll)

    if not GuildLedger.guildData then
        local label = AceGUI:Create("Label")
        label:SetText("You're not in a guild.")
        scroll:AddChild(label)
        return
    end

    if GuildLedger:IsOfficer() then
        local addBox = AceGUI:Create("EditBox")
        addBox:SetLabel("Shift-click an item into this box, then press Enter")
        addBox:SetFullWidth(true)
        addBox:SetCallback("OnEnterPressed", function(widget, event, text)
            if text and text ~= "" then
                GuildLedger:AddShoppingListItem(text, 1, nil)
                widget:SetText("")
                UI:Refresh()
            end
        end)
        scroll:AddChild(addBox)
    else
        local label = AceGUI:Create("Label")
        label:SetText("Only officers can edit this list.")
        label:SetFullWidth(true)
        scroll:AddChild(label)
    end

    for _, entry in ipairs(GuildLedger:GetShoppingListStatus()) do
        local statusText
        if entry.missing == 0 then
            statusText = "|cff00ff00In stock|r"
        else
            statusText = ("|cffff5555Need %d more|r"):format(entry.missing)
        end

        local row = AceGUI:Create("InteractiveLabel")
        row:SetText(("%s  -  have %d / %d  -  %s"):format(entry.itemLink, entry.have, entry.desired, statusText))
        row:SetFullWidth(true)
        AddTooltip(row, entry.itemLink)
        if GuildLedger:IsOfficer() then
            row:SetCallback("OnClick", function()
                GuildLedger:RemoveShoppingListItem(entry.itemID)
                UI:Refresh()
            end)
        end
        scroll:AddChild(row)
    end
end

function UI:Create()
    if frame then return end

    frame = AceGUI:Create("Frame")
    frame:SetTitle("GuildLedger")
    frame:SetLayout("Fill")
    frame:SetWidth(420)
    frame:SetHeight(500)
    frame:SetCallback("OnClose", function(widget) widget:Hide() end)
    frame:Hide()

    local tabGroup = AceGUI:Create("TabGroup")
    tabGroup:SetLayout("Fill")
    tabGroup:SetTabs({
        { text = "Bank Inventory", value = "bank" },
        { text = "Shopping List", value = "list" },
    })
    tabGroup:SetCallback("OnGroupSelected", function(container, event, group)
        container:ReleaseChildren()
        if group == "bank" then
            BuildBankTab(container)
        else
            BuildShoppingTab(container)
        end
    end)
    tabGroup:SelectTab("bank")
    frame:AddChild(tabGroup)

    self.frame = frame
    self.tabGroup = tabGroup
end

function UI:Refresh()
    if not frame or not frame:IsShown() then return end
    self.tabGroup:SelectTab(self.tabGroup.selected or "bank")
end

function UI:Toggle()
    self:Create()
    if frame:IsShown() then
        frame:Hide()
    else
        frame:Show()
        self:Refresh()
    end
end
