local ADDON_NAME, ns = ...
local GuildLedger = ns.addon
local AceGUI = LibStub("AceGUI-3.0")

local UI = {}
GuildLedger.ui = UI

local frame

local DEFAULT_FONT_SIZE = 14

-- One font object per role, shared by every widget the addon creates.
-- FontStrings track their font object, so resizing these restyles the whole
-- window; the rebuild on Refresh only exists to re-measure row heights.
local bodyFont = _G["GuildLedgerFontBody"] or CreateFont("GuildLedgerFontBody")
local headerFont = _G["GuildLedgerFontHeader"] or CreateFont("GuildLedgerFontHeader")

-- The auction house panel draws its own rows but shares these, so the font
-- size option applies there too.
ns.bodyFont = bodyFont
ns.headerFont = headerFont

local function CurrentFontSize()
    if GuildLedger.db then
        return GuildLedger.db.profile.fontSize or DEFAULT_FONT_SIZE
    end
    return DEFAULT_FONT_SIZE
end

function UI:ApplyFont()
    local size = CurrentFontSize()

    local path, _, flags = GameFontHighlight:GetFont()
    bodyFont:SetFont(path, size, flags)
    bodyFont:SetTextColor(GameFontHighlight:GetTextColor())
    bodyFont:SetJustifyH("LEFT")

    local hpath, _, hflags = GameFontNormal:GetFont()
    headerFont:SetFont(hpath, size + 2, hflags)
    headerFont:SetTextColor(GameFontNormal:GetTextColor())
    headerFont:SetJustifyH("LEFT")
end

-- Called from the options panel.
function UI:SetFontSize(size)
    GuildLedger.db.profile.fontSize = size
    self:ApplyFont()
    self:Refresh()
    if GuildLedger.ah then
        GuildLedger.ah:Refresh()
    end
end

-- AceGUI pools and reuses widget frames, so the stripe texture is created once
-- per frame and cached on it. Creating one per row would leak a texture on
-- every refresh. Pass no index to hide the stripe on a reused widget.
local function SetStripe(widget, index)
    local f = widget.frame
    if not f then return end

    local tex = f.guildLedgerStripe
    if not tex then
        tex = f:CreateTexture(nil, "BACKGROUND")
        tex:SetPoint("TOPLEFT")
        tex:SetPoint("BOTTOMRIGHT")
        f.guildLedgerStripe = tex
    end

    if not index then
        tex:Hide()
        return
    end

    if index % 2 == 1 then
        tex:SetColorTexture(1, 1, 1, 0.05)
    else
        tex:SetColorTexture(0, 0, 0, 0.22)
    end
    tex:Show()
end

-- Font before text, always: Label:SetText measures the string to set its own
-- height, so setting the font afterwards leaves the row the wrong size.
local function NewLabel(text, font)
    local widget = AceGUI:Create("Label")
    widget:SetFontObject(font or bodyFont)
    widget:SetText(text or "")
    SetStripe(widget, nil)
    return widget
end

local function NewInteractiveLabel(text)
    local widget = AceGUI:Create("InteractiveLabel")
    widget:SetFontObject(bodyFont)
    widget:SetText(text or "")
    SetStripe(widget, nil)
    return widget
end

local function AddTooltip(widget, itemLink)
    widget:SetCallback("OnEnter", function(w)
        GameTooltip:SetOwner(w.frame, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink(itemLink)
        GameTooltip:Show()
    end)
    widget:SetCallback("OnLeave", function() GameTooltip:Hide() end)
end

local function AddTextTooltip(widget, title, body)
    widget:SetCallback("OnEnter", function(w)
        GameTooltip:SetOwner(w.frame, "ANCHOR_RIGHT")
        GameTooltip:SetText(title, 1, 1, 1)
        if body then
            GameTooltip:AddLine(body, nil, nil, nil, true)
        end
        GameTooltip:Show()
    end)
    widget:SetCallback("OnLeave", function() GameTooltip:Hide() end)
end

-- Item links always carry the display name in brackets. Reading it from the
-- link avoids GetItemInfo, which returns nil for anything not in the client's
-- cache yet and would make matches come and go as the cache fills.
local function ItemNameFromLink(itemLink)
    if not itemLink then return "" end
    return itemLink:match("%[(.-)%]") or itemLink
end
ns.ItemNameFromLink = ItemNameFromLink

-- GetItemInfoInstant parses the link itself instead of consulting the item
-- cache, so the icon is there on the first draw. GetItemInfo would return nil
-- for anything the client hasn't seen yet and pop the icons in later.
-- Memoised because a redraw asks for the same few hundred links every time and
-- the answer can't change: the icon is a property of the link, not of what the
-- client happens to have cached. false means "parsed, no icon" - storing nil
-- would re-parse that link on every pass.
local iconCache = {}
local function ItemIcon(itemLink)
    if not itemLink then return nil end
    local cached = iconCache[itemLink]
    if cached ~= nil then
        return cached or nil
    end
    local _, _, _, _, icon = C_Item.GetItemInfoInstant(itemLink)
    iconCache[itemLink] = icon or false
    return icon
end
ns.ItemIcon = ItemIcon

-- Icons track the font size so a row stays one line of text tall.
local function IconSize()
    return math.max(16, CurrentFontSize() + 2)
end
ns.IconSize = IconSize

-- AceGUI's Label drops the image above the text, centred, once the text has
-- less than 200px to live in - so a squeezed window turns every row into two.
-- Left as-is: the threshold is Label's, the default window is nowhere near it,
-- and a window narrow enough to trip it is unreadable for other reasons.
local function SetItemIcon(widget, itemLink)
    widget:SetImageSize(IconSize(), IconSize())
    widget:SetImage(ItemIcon(itemLink))
end

-- AceGUI's AddChild lays the container out again for every single child, and
-- the List layout re-measures every row it has already placed - so filling a
-- scroll frame one row at a time costs O(rows^2) text measurements. A full
-- eight-tab bank is several hundred rows, which is where the freeze came from.
-- Pausing the layout for the fill and running it once at the end makes it
-- linear. pcall so an error mid-fill can't leave the container permanently
-- paused, which would silently stop it ever laying out again.
local function BulkFill(container, fill)
    container:PauseLayout()
    local ok, err = pcall(fill)
    container:ResumeLayout()
    container:DoLayout()
    if not ok then error(err, 0) end
end

-- A rebuild releases the scroll frame and builds a new one, which starts at
-- the top - that's why every refresh threw the list back to the beginning.
-- AceGUI keeps the scroll offset in a status table it doesn't own, so handing
-- the replacement the same table hands it the old position; FixScroll clamps
-- it on the layout that follows if the content got shorter.
local scrollPositions = {}
local function RememberScroll(scroll, key)
    scrollPositions[key] = scrollPositions[key] or {}
    scroll:SetStatusTable(scrollPositions[key])
end

-- needle must already be lowercased by the caller; this runs once per slot
-- per keystroke, so it stays off the hot path.
local function MatchesFilter(itemLink, needle)
    if needle == "" then return true end
    -- Plain find, so a filter like "Flask (" can't blow up as a Lua pattern.
    return ItemNameFromLink(itemLink):lower():find(needle, 1, true) ~= nil
end

-- AceGUI's List layout packs children flush against each other, so vertical
-- breathing room has to be an explicit widget. SetHeight must follow SetText,
-- which otherwise sizes the label to the string.
local function AddSpacer(parent, height)
    local spacer = AceGUI:Create("Label")
    spacer:SetFontObject(bodyFont)
    spacer:SetText(" ")
    spacer:SetFullWidth(true)
    spacer:SetHeight(height or 10)
    SetStripe(spacer, nil)
    parent:AddChild(spacer)
    return spacer
end

local function NewRow(parent, index)
    local row = AceGUI:Create("SimpleGroup")
    row:SetLayout("Flow")
    row:SetFullWidth(true)
    parent:AddChild(row)
    SetStripe(row, index)
    return row
end

-- Split out so a shopping-list edit can re-text a row that is already on
-- screen instead of the tab being rebuilt around it.
-- The annotation is grey and sits after the count, so it reads as a note on
-- the row rather than competing with the item link's own quality colour. It
-- says how many are wanted, so the bank tab answers "do I still need this?"
-- without a trip to the other tab.
local function BankRowText(item, desired)
    local text = ("%s  x%d"):format(item.itemLink, item.count or 0)
    if desired then
        text = text .. ("   |cff888888on list, %d wanted|r"):format(desired)
    end
    return text
end

-- One rebuild per keystroke made typing in a big bank feel like the window was
-- fighting back. The filter only has to be right once the typing stops.
local SEARCH_DEBOUNCE = 0.25

function UI:ScheduleFilterRefresh()
    if self.filterTimer then
        self.filterTimer:Cancel()
    end
    self.filterTimer = C_Timer.NewTimer(SEARCH_DEBOUNCE, function()
        UI.filterTimer = nil
        -- Refreshing rebuilds the tab and destroys the search box, so record
        -- where the cursor was and flag the box that replaces it to take focus
        -- back, so typing carries on uninterrupted and in the same place.
        -- Only if the box still has focus: the window can have been closed or
        -- the tab switched during the quarter second we waited, and grabbing
        -- focus then would be the addon typing over whatever came next.
        local box = UI.bankSearchBox
        local editbox = box and box.editbox
        if editbox and editbox:HasFocus() then
            UI.restoreBankSearchFocus = true
            UI.bankSearchCursor = editbox:GetCursorPosition()
        end
        UI:Refresh()
    end)
end

local function BuildBankTab(container)
    local scroll = AceGUI:Create("ScrollFrame")
    scroll:SetLayout("List")
    scroll:SetFullWidth(true)
    scroll:SetFullHeight(true)
    container:AddChild(scroll)

    -- Dropped on every rebuild: the widgets these point at have been released
    -- back to AceGUI's pool and will come back as somebody else's rows.
    UI.bankRows = nil
    UI.bankSearchBox = nil

    if not GuildLedger.guildData then
        scroll:AddChild(NewLabel("You're not in a guild."))
        return
    end

    RememberScroll(scroll, "bank")

    local filter = UI.bankFilter or ""

    BulkFill(scroll, function()

    local search = AceGUI:Create("EditBox")
    search.editbox:SetFontObject(bodyFont)
    search:SetLabel("Search items")
    search:DisableButton(true)
    search:SetFullWidth(true)
    search:SetText(filter)
    search:SetCallback("OnTextChanged", function(widget, event, text)
        UI.bankFilter = text
        UI:ScheduleFilterRefresh()
    end)
    scroll:AddChild(search)
    UI.bankSearchBox = search

    if UI.restoreBankSearchFocus then
        UI.restoreBankSearchFocus = nil
        search:SetFocus()
        search.editbox:SetCursorPosition(UI.bankSearchCursor or #filter)
        UI.bankSearchCursor = nil
    end

    AddSpacer(scroll, 12)

    local needle = filter:lower()

    local bank = GuildLedger.guildData.bank
    local list = GuildLedger:GetShoppingList()
    local header = NewLabel("")
    header:SetFullWidth(true)
    if bank.lastScan and bank.lastScan > 0 then
        header:SetText(("Last synced by %s, %d min ago. Click an item to add it to your shopping list."):format(
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

    local rows = {}
    local rowIndex, shown, total = 0, 0, 0
    for _, tabIndex in ipairs(tabIndices) do
        local tab = bank.tabs[tabIndex]

        local slotIndices = {}
        for slot, item in pairs(tab.slots) do
            total = total + 1
            if MatchesFilter(item.itemLink, needle) then
                table.insert(slotIndices, slot)
            end
        end
        table.sort(slotIndices)

        -- Skip the heading entirely for a tab with nothing matching, so a
        -- filtered view isn't padded out with empty tab names.
        if #slotIndices > 0 then
            local tabHeader = AceGUI:Create("Heading")
            tabHeader:SetText(tab.name or ("Tab " .. tabIndex))
            tabHeader:SetFullWidth(true)
            tabHeader.label:SetFontObject(headerFont)
            tabHeader:SetHeight(math.max(18, CurrentFontSize() + 10))
            scroll:AddChild(tabHeader)

            for _, slot in ipairs(slotIndices) do
                local item = tab.slots[slot]
                rowIndex = rowIndex + 1
                shown = shown + 1

                local itemID = item.itemID
                local entry = itemID and list[itemID]
                local desired = entry and entry.desired or nil

                local row = NewInteractiveLabel(BankRowText(item, desired))
                row:SetFullWidth(true)
                SetItemIcon(row, item.itemLink)
                SetStripe(row, rowIndex)
                AddTooltip(row, item.itemLink)
                row:SetCallback("OnClick", function()
                    -- Read the list now rather than trusting what it held when
                    -- the row was drawn. Rows outlive a list edit these days,
                    -- so an entry captured at build time goes stale the moment
                    -- the item is added from anywhere else.
                    local listed = itemID and GuildLedger:GetShoppingList()[itemID]
                    -- A click is shorthand for "add this", not "reset this":
                    -- it carries no quantity of its own, so it must not
                    -- clobber a target someone deliberately typed in.
                    if listed then
                        GuildLedger:Print(("%s is already on your list (%d wanted)."):format(
                            item.itemLink, listed.desired))
                        return
                    end
                    if GuildLedger:AddShoppingListItem(item.itemLink, 1, nil) then
                        GuildLedger:Print(("Added %s to your shopping list."):format(item.itemLink))
                    end
                end)
                scroll:AddChild(row)

                rows[#rows + 1] = {
                    widget = row,
                    item = item,
                    itemID = itemID,
                    desired = desired,
                }
            end
        end
    end

    UI.bankRows = rows

    if filter ~= "" then
        if shown == 0 then
            header:SetText(("Nothing in the bank matches that search (%d item stacks cached)."):format(total))
        else
            header:SetText(("Showing %d of %d item stacks."):format(shown, total))
        end
    end

    end)
end

-- The repaint that stands in for a rebuild when only the shopping list moved.
-- A list edit can't change which bank slots exist, only the annotation on the
-- rows drawn for them, so the rows stay put and the handful whose annotation
-- actually differs get new text. Label:SetText re-measures its own frame but
-- never asks the parent to lay out again, so nothing moves and the scroll
-- position is not touched at all.
-- Returns false when there are no rows to repaint - no guild, or the tab was
-- never built - so the caller can fall back to a rebuild.
function UI:RepaintBankRows()
    local rows = self.bankRows
    if not rows then return false end

    local list = GuildLedger:GetShoppingList()
    for i = 1, #rows do
        local row = rows[i]
        local entry = row.itemID and list[row.itemID]
        local desired = entry and entry.desired or nil
        if desired ~= row.desired then
            row.desired = desired
            row.widget:SetText(BankRowText(row.item, desired))
        end
    end

    return true
end

-- Shopping list column widths, as fractions of the row. AceGUI's Button insets
-- its label by 15px on each side, so 30px of any button is pure padding - which
-- is why the remove button says "X" rather than "Remove": at any width narrow
-- enough to leave the item name room, the word rendered as "Re...". The tooltip
-- carries the meaning instead.
-- Keep the total a little under 1.0 or Flow rounding wraps the last column.
local COL_ITEM, COL_HAVE, COL_WANT, COL_REMOVE = 0.60, 0.12, 0.15, 0.10

-- AceGUI sizes an EditBox to leave room for a label even when there is no
-- label to show - 26px of frame around 17px of text - and a Button to 24, and
-- Flow then sizes the row to the tallest thing in it. That made a shopping
-- list row 28px tall to hold one line. Sizing both controls to the text, the
-- way the icons already do, brings it to 23. 20 is the same floor the toolbar
-- buttons use, and is about as short as InputBoxTemplate's art reads at.
local function ControlHeight()
    return math.max(20, CurrentFontSize() + 6)
end

-- alignoffset is the line Flow centres a row on. AceGUI hardcodes it to 12 for
-- an EditBox, measured from the 26px frame, so it has to be re-centred with
-- the height or the row is padded back out to make room for the old one.
-- Both are reset by OnAcquire, so nothing leaks into the widget pool.
local function Compact(widget, height)
    widget:SetHeight(height)
    widget.alignoffset = height / 2
end

-- Stock against target, green once the target is met and red while it isn't.
-- Just "35 /" because the quantity box sitting next to it is the target, and
-- printing it twice helps nobody. Replaces "35  (need 165 more)" with the same
-- information in about a third of the width, which the item name takes.
local function StockText(entry)
    local color = entry.missing == 0 and "|cff40ff40" or "|cffff5555"
    return ("%s%d|r /"):format(color, entry.have)
end

local function BuildShoppingTab(container)
    local scroll = AceGUI:Create("ScrollFrame")
    scroll:SetLayout("List")
    scroll:SetFullWidth(true)
    scroll:SetFullHeight(true)
    container:AddChild(scroll)
    RememberScroll(scroll, "list")

    BulkFill(scroll, function()

    -- No guild check: the list is this character's own, and the bank column
    -- simply reads 0 until there's a scan to compare against.
    local addBox = AceGUI:Create("EditBox")
    addBox.editbox:SetFontObject(bodyFont)
    addBox:SetLabel("Shift-click an item here, optionally followed by a quantity, then press Enter")
    addBox:SetFullWidth(true)
    addBox:SetCallback("OnEnterPressed", function(widget, event, text)
        text = text and text:trim() or ""
        if text == "" then return end
        -- "<link> 20" sets the wanted quantity up front; a bare link wants 1.
        local link, qty = text:match("^(.-)%s+(%d+)%s*$")
        GuildLedger:AddShoppingListItem(link or text, tonumber(qty) or 1, nil)
        widget:SetText("")
        UI:Refresh()
    end)
    scroll:AddChild(addBox)

    AddSpacer(scroll, 12)

    local entries = GuildLedger:GetShoppingListStatus()
    if #entries == 0 then
        scroll:AddChild(NewLabel("Nothing on the shopping list yet."))
        return
    end

    local head = NewRow(scroll, nil)
    local hItem = NewLabel("Item", headerFont)
    hItem:SetRelativeWidth(COL_ITEM)
    head:AddChild(hItem)
    -- One heading over both halves of "35 / 200", whether the second half is a
    -- label or the quantity box.
    local hStock = NewLabel("In bank / wanted", headerFont)
    hStock:SetRelativeWidth(COL_HAVE + COL_WANT)
    head:AddChild(hStock)

    local controlHeight = ControlHeight()

    for index, entry in ipairs(entries) do
        local row = NewRow(scroll, index)

        local item = NewInteractiveLabel(entry.itemLink)
        item:SetRelativeWidth(COL_ITEM)
        SetItemIcon(item, entry.itemLink)
        AddTooltip(item, entry.itemLink)
        row:AddChild(item)

        local have = NewLabel(StockText(entry))
        have:SetRelativeWidth(COL_HAVE)
        -- Right-justified so "35 /" ends flush against the quantity box
        -- rather than floating at the left of a cell sized for four digits.
        have:SetJustifyH("RIGHT")
        row:AddChild(have)

        local qty = AceGUI:Create("EditBox")
        qty.editbox:SetFontObject(bodyFont)
        -- The default 3px top and bottom text insets are sized for the 26px
        -- box; at this height they would clip the descenders.
        qty.editbox:SetTextInsets(0, 0, 1, 1)
        qty:DisableButton(true)
        qty:SetText(tostring(entry.desired))
        qty:SetRelativeWidth(COL_WANT)
        Compact(qty, controlHeight)
        qty:SetCallback("OnEnterPressed", function(widget, event, text)
            GuildLedger:SetShoppingListQuantity(entry.itemID, tonumber(text))
            widget:ClearFocus()
            UI:Refresh()
        end)
        row:AddChild(qty)

        local remove = AceGUI:Create("Button")
        remove:SetText("X")
        remove:SetRelativeWidth(COL_REMOVE)
        Compact(remove, controlHeight)
        AddTextTooltip(remove, "Remove",
            ("Take %s off your shopping list."):format(ItemNameFromLink(entry.itemLink)))
        remove:SetCallback("OnClick", function()
            GuildLedger:RemoveShoppingListItem(entry.itemID)
            UI:Refresh()
        end)
        row:AddChild(remove)
    end

    end)
end

-- The AceGUI frame's status bar is decorative here - we never call
-- SetStatusText - so the toolbar lives inside it. Parenting to statusbg also
-- puts the buttons a frame level above it, so its OnEnter doesn't eat clicks.
local function NewToolbarButton(parent, text, width, tooltip, onClick)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetSize(width, 20)
    button:SetText(text)
    button:SetScript("OnClick", onClick)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(text, 1, 1, 1)
        GameTooltip:AddLine(tooltip, nil, nil, nil, true)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return button
end

function UI:CreateToolbar()
    -- AceGUI's Frame widget exposes statustext but not the status bar frame
    -- behind it; the fontstring's parent is that bar. Fall back to the window
    -- itself (same coordinates) if AceGUI ever restructures it.
    local bar = frame.statustext and frame.statustext:GetParent()
    local anchorX, anchorY = 4, 0
    if not bar then
        bar = frame.frame
        anchorX, anchorY = 19, 17
    end

    self.scanButton = NewToolbarButton(bar, "Scan bank", 100,
        "Re-read every guild bank tab. Only works while the guild bank window is open.",
        function()
            GuildLedger:StartBankScan()
            GuildLedger:Print("Scanning the guild bank...")
        end)
    if bar == frame.frame then
        self.scanButton:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", anchorX, anchorY)
    else
        self.scanButton:SetPoint("LEFT", bar, "LEFT", anchorX, anchorY)
    end

    self.syncButton = NewToolbarButton(bar, "Sync", 80,
        "Ask the guild for a newer bank snapshot.",
        function()
            if not GuildLedger.guildData then
                GuildLedger:Print("You're not in a guild.")
                return
            end
            GuildLedger:RequestSync()
            GuildLedger:Print("Requested a fresh bank snapshot from the guild.")
        end)
    self.syncButton:SetPoint("LEFT", self.scanButton, "RIGHT", 4, 0)
end

-- A scan outside the bank window silently does nothing (the API returns
-- empties), so the button says why instead of looking broken.
function UI:UpdateToolbar()
    if not self.scanButton then return end
    self.scanButton:SetEnabled(GuildLedger:IsAtGuildBanker())
    self.syncButton:SetEnabled(GuildLedger.guildData ~= nil)
end

function UI:Create()
    if frame then return end

    self:ApplyFont()

    frame = AceGUI:Create("Frame")
    frame:SetTitle("GuildLedger")
    frame:SetLayout("Fill")
    frame:SetCallback("OnClose", function(widget) widget:Hide() end)
    -- Size and position come from the profile, so the window stays where it was
    -- parked. It opens itself next to the guild bank now, and re-centring on
    -- top of the bank frame every time would make that worse, not better.
    frame:SetStatusTable(GuildLedger.db.profile.window)
    frame:Hide()

    self:CreateToolbar()

    local tabGroup = AceGUI:Create("TabGroup")
    tabGroup:SetLayout("Fill")
    tabGroup:SetTabs({
        { text = "Bank Inventory", value = "bank" },
        { text = "Shopping List", value = "list" },
    })
    tabGroup:SetCallback("OnGroupSelected", function(container, event, group)
        -- Track the selection ourselves. AceGUI keeps it in localstatus rather
        -- than on the widget, so reading tabGroup.selected always gave nil and
        -- every refresh snapped the user back to the first tab.
        UI.selectedTab = group
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

-- Two kinds of change reach the window, and they cost wildly different
-- amounts to draw:
--   "list"      a shopping-list edit. Which rows exist is unchanged; only the
--               "on list" annotation on bank rows moved, so the bank tab
--               repaints those in place.
--   anything else  a scan, a sync, a guild change, a font size change. The
--               rows themselves are different and have to be built again.
-- Rebuilding for a list edit is what froze the window on every click and threw
-- the scroll back to the top, which is the whole reason for the distinction.
local REBUILD_UNNEEDED = "list"

-- Bursts are the norm - a scan sends a message per tab, and RefreshGuildData
-- runs on every roster update - so the work is coalesced onto the next frame
-- and done once. A rebuild asked for anywhere in the burst wins over a
-- repaint: it is the strictly more thorough of the two.
function UI:Refresh(reason)
    if not frame or not frame:IsShown() then return end

    if reason ~= REBUILD_UNNEEDED then
        self.pendingRebuild = true
    end

    if self.refreshScheduled then return end
    self.refreshScheduled = true
    C_Timer.After(0, function() UI:RunRefresh() end)
end

function UI:RunRefresh()
    self.refreshScheduled = nil
    local rebuild = self.pendingRebuild
    self.pendingRebuild = nil

    -- The window can have been closed between the request and this frame.
    if not frame or not frame:IsShown() then return end

    self:UpdateToolbar()

    -- The shopping list tab is left to rebuild even for a list edit: there the
    -- rows really do appear, disappear and re-sort. It is tens of rows, not
    -- the hundreds the bank tab draws.
    if not rebuild and (self.selectedTab or "bank") == "bank" and self:RepaintBankRows() then
        return
    end

    self.tabGroup:SelectTab(self.selectedTab or "bank")
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

-- Auto-open at the guild bank. We only close again if we were the ones who
-- opened it: a window the player opened by hand before walking up to the
-- banker is theirs, and shutting it for them would be rude.
function UI:OnGuildBankOpened()
    if not GuildLedger.db.profile.autoOpenOnBankOpen then return end

    self:Create()
    if frame:IsShown() then
        self.openedForBank = false
    else
        self.openedForBank = true
        frame:Show()
    end
    self:Refresh()
end

function UI:OnGuildBankClosed()
    if not frame then return end
    if self.openedForBank then
        self.openedForBank = false
        frame:Hide()
        return
    end
    self:Refresh()
end

UI:ApplyFont()
