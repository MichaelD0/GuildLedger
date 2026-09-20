local ADDON_NAME, ns = ...
local GuildLedger = ns.addon

-- A side panel pinned to the auction house window listing what the guild
-- still needs, so you can shop without alt-tabbing back to /gledger. Clicking
-- a row searches the auction house for that item.
--
-- Blizzard_AuctionHouseUI is load-on-demand: none of AuctionHouseFrame exists
-- until the player first opens an auctioneer, so everything here is built the
-- first time that addon loads rather than at our own load time.

local AH = {}
GuildLedger.ah = AH

local AH_ADDON = "Blizzard_AuctionHouseUI"

-- Opening and closing the auction house repeatedly shouldn't spray sync
-- requests at the guild channel.
local SYNC_REQUEST_COOLDOWN = 60
local lastSyncRequest = 0

-- Wide enough that an item name, its icon and "35 / 200" all fit on one line
-- without the name being clipped to guesswork. The panel flips to the left of
-- the auction house window when there isn't room on the right.
local PANEL_WIDTH = 340
local ROW_PADDING = 8
local MIN_ROW_HEIGHT = 20

local panel, scrollChild, headerText
local rows = {}

local PanelBackdrop = {
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
}

local function IsAHLoaded()
    if C_AddOns and C_AddOns.IsAddOnLoaded then
        return C_AddOns.IsAddOnLoaded(AH_ADDON)
    end
    -- Pre-11.0 clients still had the global. Harmless to keep as a fallback.
    return IsAddOnLoaded and IsAddOnLoaded(AH_ADDON)
end

local function RowHeight()
    local size = (GuildLedger.db and GuildLedger.db.profile.fontSize) or 14
    return math.max(MIN_ROW_HEIGHT, size + ROW_PADDING)
end

--[[--------------------------------------------------------------------------
Searching
----------------------------------------------------------------------------]]

-- Drive the auction house's own search rather than reimplementing one. Each
-- step is pcall'd because these are Blizzard internals: a patch that renames
-- one should degrade to "the name is in the search box, press Enter", not
-- throw a Lua error in the middle of the player's shopping trip.
local function SearchAuctionHouse(itemLink)
    local itemName = ns.ItemNameFromLink(itemLink)
    if not itemName or itemName == "" then return false end

    local ahFrame = _G.AuctionHouseFrame
    local searchBar = ahFrame and ahFrame.SearchBar
    local searchBox = searchBar and searchBar.SearchBox

    -- Do this first and unconditionally: even if every way of triggering the
    -- search below fails, the player can press Enter themselves.
    if searchBox then
        searchBox:SetText(itemName)
    end

    if searchBar and searchBar.StartSearch then
        if pcall(searchBar.StartSearch, searchBar) then return true end
    end

    if searchBox then
        local onEnterPressed = searchBox:GetScript("OnEnterPressed")
        if onEnterPressed and pcall(onEnterPressed, searchBox) then return true end
    end

    if C_AuctionHouse and C_AuctionHouse.SendBrowseQuery then
        local ok = pcall(C_AuctionHouse.SendBrowseQuery, {
            searchString = itemName,
            sorts = {},
            filters = {},
            itemClassFilters = {},
        })
        if ok then return true end
    end

    GuildLedger:Print(("Couldn't start the auction house search. %s is in the search box - press Enter."):format(itemName))
    return false
end

--[[--------------------------------------------------------------------------
Panel construction
----------------------------------------------------------------------------]]

local function AcquireRow(index)
    local row = rows[index]
    if row then return row end

    row = CreateFrame("Button", nil, scrollChild)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetPoint("LEFT", 2, 0)

    row.name = row:CreateFontString(nil, "OVERLAY")
    row.name:SetFontObject(ns.bodyFont)
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    row.need = row:CreateFontString(nil, "OVERLAY")
    row.need:SetFontObject(ns.bodyFont)
    row.need:SetPoint("RIGHT", -2, 0)
    row.need:SetJustifyH("RIGHT")
    row.need:SetWordWrap(false)

    row:SetScript("OnEnter", function(self)
        if not self.itemLink then return end
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetHyperlink(self.itemLink)
        GameTooltip:AddLine("Click to search the auction house.", 0.6, 0.8, 1)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row:SetScript("OnClick", function(self)
        if self.itemLink then
            SearchAuctionHouse(self.itemLink)
        end
    end)

    rows[index] = row
    return row
end

local function CreatePanel()
    if panel then return panel end

    local ahFrame = _G.AuctionHouseFrame
    if not ahFrame then return nil end

    panel = CreateFrame("Frame", "GuildLedgerAHPanel", ahFrame, "BackdropTemplate")
    panel:SetWidth(PANEL_WIDTH)
    panel:SetBackdrop(PanelBackdrop)
    panel:SetFrameStrata(ahFrame:GetFrameStrata())
    panel:Hide()

    local title = panel:CreateFontString(nil, "OVERLAY")
    title:SetFontObject(ns.headerFont)
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("GuildLedger shopping list")
    panel.title = title

    local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -6, -6)
    close:SetScript("OnClick", function()
        AH.dismissed = true
        panel:Hide()
    end)

    headerText = panel:CreateFontString(nil, "OVERLAY")
    headerText:SetFontObject(ns.bodyFont)
    headerText:SetPoint("TOPLEFT", 16, -38)
    headerText:SetPoint("TOPRIGHT", -16, -38)
    headerText:SetJustifyH("LEFT")

    -- Hung off the bottom of the subtitle rather than off the panel, so the
    -- breathing room under it stays the same however tall the font is.
    local scroll = CreateFrame("ScrollFrame", "GuildLedgerAHPanelScroll", panel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", headerText, "BOTTOMLEFT", -2, -14)
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -30, 14)
    panel.scroll = scroll

    scrollChild = CreateFrame("Frame", nil, scroll)
    scrollChild:SetSize(PANEL_WIDTH - 46, 1)
    scroll:SetScrollChild(scrollChild)

    return panel
end

--[[--------------------------------------------------------------------------
Contents
----------------------------------------------------------------------------]]

-- The panel hangs off the right of the auction house window, except when
-- there isn't room there - a low resolution or a UI scale that puts the AH
-- frame near the right edge - in which case it flips to the left.
local function AnchorPanel()
    local ahFrame = _G.AuctionHouseFrame
    if not (panel and ahFrame) then return end

    panel:ClearAllPoints()

    local right = ahFrame:GetRight()
    local screenRight = UIParent:GetRight()
    local fitsRight = not (right and screenRight) or (right + PANEL_WIDTH + 4) <= screenRight

    if fitsRight then
        panel:SetPoint("TOPLEFT", ahFrame, "TOPRIGHT", 2, -12)
        panel:SetPoint("BOTTOMLEFT", ahFrame, "BOTTOMRIGHT", 2, 12)
    else
        panel:SetPoint("TOPRIGHT", ahFrame, "TOPLEFT", -2, -12)
        panel:SetPoint("BOTTOMRIGHT", ahFrame, "BOTTOMLEFT", -2, 12)
    end
end

function AH:Refresh()
    if not panel or not panel:IsShown() then return end

    panel.title:SetFontObject(ns.headerFont)
    headerText:SetFontObject(ns.bodyFont)

    local entries = GuildLedger:GetShoppingListStatus()
    headerText:SetText("Click to search.")

    local height = RowHeight()
    local width = scrollChild:GetWidth()

    for index, entry in ipairs(entries) do
        local row = AcquireRow(index)
        row.itemLink = entry.itemLink

        row:SetSize(width, height)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, -(index - 1) * height)

        row.name:SetFontObject(ns.bodyFont)
        row.need:SetFontObject(ns.bodyFont)

        local iconSize = height - 4
        row.icon:SetSize(iconSize, iconSize)
        row.icon:SetTexture(ns.ItemIcon(entry.itemLink))

        -- A full item link in a FontString renders as the coloured item name,
        -- so quality colouring comes for free; no GetItemInfo cache dance.
        row.name:SetText(entry.itemLink)

        -- Same readout as the shopping list tab: stock over target, green once
        -- the target is met and red while it isn't. Narrow on purpose - the
        -- item name gets whatever this doesn't use.
        local color = entry.missing == 0 and "|cff40ff40" or "|cffff5555"
        row.need:SetText(("%s%d|r / %d"):format(color, entry.have, entry.desired))

        -- Leave the name room for the icon and the count, whatever the font size.
        row.name:SetWidth(math.max(20, width - iconSize - 6 - row.need:GetStringWidth() - 10))
        row:Show()
    end

    for index = #entries + 1, #rows do
        rows[index].itemLink = nil
        rows[index]:Hide()
    end

    scrollChild:SetHeight(math.max(1, #entries * height))
end

-- Also the "should this panel exist at all right now" check, so an item added
-- while the auction house is open makes the panel appear rather than waiting
-- for the next visit. An empty list shows nothing: a panel that only says
-- "nothing here" is in the way.
function AH:UpdateVisibility()
    local ahFrame = _G.AuctionHouseFrame
    if not ahFrame then return end

    local hasEntries = GuildLedger.guildData ~= nil
        and next(GuildLedger.guildData.shoppingList) ~= nil

    local wanted = ahFrame:IsShown()
        and hasEntries
        and GuildLedger.db and GuildLedger.db.profile.showOnAuctionHouse
        and not self.dismissed

    if not wanted then
        if panel then panel:Hide() end
        return
    end

    if not CreatePanel() then return end
    AnchorPanel()
    panel:Show()
    self:Refresh()
end

--[[--------------------------------------------------------------------------
Wiring
----------------------------------------------------------------------------]]

function AH:HookAuctionHouse()
    local ahFrame = _G.AuctionHouseFrame
    if not ahFrame or self.hooked then return end
    self.hooked = true

    ahFrame:HookScript("OnShow", function()
        GuildLedger:Debug("auction house opened")
        -- An X on the panel dismisses it for this visit only.
        AH.dismissed = false
        AH:UpdateVisibility()
        -- Ask the guild for the current list on arrival so you aren't shopping
        -- from whatever snapshot you happened to have at login.
        if GuildLedger.guildData and (GetTime() - lastSyncRequest) > SYNC_REQUEST_COOLDOWN then
            lastSyncRequest = GetTime()
            GuildLedger:RequestSync()
        end
    end)

    ahFrame:HookScript("OnHide", function()
        AH.dismissed = false
        if panel then panel:Hide() end
    end)

    -- Already open when the addon loaded (first visit loads Blizzard's addon
    -- and shows the frame in the same frame we get here).
    if ahFrame:IsShown() then
        self:UpdateVisibility()
    end
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(_, _, name)
    if name ~= AH_ADDON then return end
    loader:UnregisterEvent("ADDON_LOADED")
    AH:HookAuctionHouse()
end)

if IsAHLoaded() then
    loader:UnregisterEvent("ADDON_LOADED")
    AH:HookAuctionHouse()
end
