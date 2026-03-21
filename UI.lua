----------------------------------------------------------------------
-- Deadpool - UI.lua
-- Full UI: large resizable frames, 7 tabs, right-click menu hooks
----------------------------------------------------------------------

local UI = {}
Deadpool:RegisterModule("UI", UI)

-- Frame dimensions (fixed size, scale controlled by setting)
local FRAME_WIDTH = 950
local FRAME_HEIGHT = 620
local ROW_HEIGHT = 22
local HEADER_HEIGHT = 26
local TAB_HEIGHT = 28

-- Tab definitions
local TABS = {
    { key = "dashboard",  label = "Dashboard" },
    { key = "kos",        label = "Kill on Sight" },
    { key = "bounties",   label = "Bounties" },
    { key = "enemies",    label = "Public Enemies" },
    { key = "scoreboard", label = "Scoreboard" },
    { key = "mystats",    label = "My Stats" },
    { key = "killlog",    label = "Kill Log" },
    { key = "settings",   label = "Settings" },
}

-- Local references
local mainFrame, contentArea, tabButtons, statusText
local dashboardFrame  -- separate frame for dashboard (not row-based)
local activeTab = "dashboard"
local filterText = ""

----------------------------------------------------------------------
-- Init
----------------------------------------------------------------------
function UI:Init()
    -- Clean up stale globally-named frames from previous /reload
    local staleNames = {
        "DeadpoolMainFrame", "DeadpoolSettingsPanel", "DeadpoolThemeDD", "DeadpoolScaleDD",
        "DeadpoolScrollFrame", "DeadpoolFilterBox", "DeadpoolContextMenu",
    }
    -- Also clean up any checkbox globals
    local cbKeys = {"announceKills","announceKOSSighted","alertSound","broadcastSightings","autoKOSOnAttack","syncEnabled","debug"}
    for _, k in ipairs(cbKeys) do table.insert(staleNames, "DeadpoolCB_" .. k) end
    for _, name in ipairs(staleNames) do
        if _G[name] then
            _G[name]:Hide()
            _G[name]:SetParent(nil)
            _G[name] = nil
        end
    end

    self:CreateMainFrame()
    self:CreateMinimapButton()
    self:HookUnitMenus()
end

----------------------------------------------------------------------
-- Toggle / Show / Tab
----------------------------------------------------------------------
function Deadpool:ToggleUI()
    if not mainFrame then return end
    if mainFrame:IsShown() then mainFrame:Hide()
    else
        mainFrame:Show()
        UI:SelectTab(activeTab)
    end
end

function Deadpool:ShowTab(tabKey)
    if not mainFrame then return end
    mainFrame:Show()
    activeTab = tabKey
    UI:SelectTab(tabKey)
end

function Deadpool:RefreshUI()
    if not mainFrame or not mainFrame:IsShown() then return end
    UI:RefreshContent()
end

----------------------------------------------------------------------
-- Right-click unit popup menu hooks (TBC Classic 2.5.5 compatible)
----------------------------------------------------------------------
function UI:HookUnitMenus()
    -- In TBC Classic, unit context menus are built by UnitPopup_ShowMenu.
    -- We hook UIDropDownMenu_AddButton to detect when unit menus are being
    -- populated, and inject our items at the end.
    -- We also hook the dropdown's Show to capture the unit reference.

    local hookedUnit = nil

    -- Hook the initialize function to capture which unit the dropdown is for
    hooksecurefunc("UIDropDownMenu_Initialize", function(frame, initFunc, displayMode, level, menuList)
        -- Try to get unit from the frame itself
        local unit = frame and frame.unit
        if not unit then
            -- Check well-known dropdown frames
            if frame == (TargetFrameDropDown or false) then unit = "target"
            elseif frame == (FocusFrameDropDown or false) then unit = "focus"
            end
        end

        if not unit then hookedUnit = nil; return end
        if not UnitExists(unit) then hookedUnit = nil; return end
        if not UnitIsPlayer(unit) then hookedUnit = nil; return end

        hookedUnit = unit

        -- For enemy players, inject our menu items
        if UnitIsEnemy("player", unit) then
            -- Only inject at menu level 1
            if (level or 1) ~= 1 and UIDROPDOWNMENU_MENU_LEVEL ~= 1 then return end

            -- Add separator
            local sep = UIDropDownMenu_CreateInfo()
            sep.isTitle = true
            sep.notCheckable = true
            sep.text = "|cFFCC0000â€” Deadpool â€”|r"
            UIDropDownMenu_AddButton(sep)

            -- Add to KOS
            local capturedUnit = unit
            local info = UIDropDownMenu_CreateInfo()
            info.text = "Add to Kill on Sight"
            info.notCheckable = true
            info.colorCode = "|cFFFF4444"
            info.func = function()
                local fullName = Deadpool:GetUnitFullName(capturedUnit)
                if fullName then
                    Deadpool:AddToKOS(fullName, "")
                end
            end
            UIDropDownMenu_AddButton(info)

            -- Place Bounty
            info = UIDropDownMenu_CreateInfo()
            info.text = "Place Bounty"
            info.notCheckable = true
            info.colorCode = "|cFFFFD700"
            info.func = function()
                local fullName = Deadpool:GetUnitFullName(capturedUnit)
                if fullName then
                    local dialog = StaticPopup_Show("DEADPOOL_PLACE_BOUNTY", Deadpool:ShortName(fullName))
                    if dialog then dialog.data = fullName end
                end
            end
            UIDropDownMenu_AddButton(info)
        end
    end)
end

----------------------------------------------------------------------
-- Main frame (large, resizable)
----------------------------------------------------------------------
function UI:CreateMainFrame()
    -- Use a plain frame instead of BasicFrameTemplateWithInset so we can fully theme it
    mainFrame = CreateFrame("Frame", "DeadpoolMainFrame", UIParent, "BackdropTemplate")
    mainFrame:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
    mainFrame:SetPoint("CENTER")
    mainFrame:SetMovable(true)
    mainFrame:EnableMouse(true)
    mainFrame:RegisterForDrag("LeftButton")
    mainFrame:SetScript("OnDragStart", mainFrame.StartMoving)
    mainFrame:SetScript("OnDragStop", mainFrame.StopMovingOrSizing)
    mainFrame:SetClampedToScreen(true)
    mainFrame:SetFrameStrata("HIGH")
    mainFrame:Hide()

    -- Apply scale from settings
    mainFrame:SetScale(Deadpool.db.settings.uiScale or 1.0)

    -- Apply themed backdrop
    self:ApplyFrameTheme()

    -- Title bar
    local titleBar = CreateFrame("Frame", nil, mainFrame)
    titleBar:SetHeight(26)
    titleBar:SetPoint("TOPLEFT", 0, 0)
    titleBar:SetPoint("TOPRIGHT", 0, 0)
    mainFrame.titleBar = titleBar

    local titleBg = titleBar:CreateTexture(nil, "BACKGROUND")
    titleBg:SetAllPoints()
    local t = Deadpool.modules.Theme.active
    titleBg:SetColorTexture(t.accent[1] * 0.5, t.accent[2] * 0.5, t.accent[3] * 0.5, 0.95)
    mainFrame.titleBarBg = titleBg

    local titleText = titleBar:CreateFontString(nil, "OVERLAY")
    titleText:SetFont(Deadpool.modules.Theme:GetTitleFont())
    titleText:SetPoint("LEFT", titleBar, "LEFT", 10, 0)
    titleText:SetText(Deadpool.modules.Theme:AccentHex() .. "DEADPOOL|r")
    mainFrame.titleText = titleText

    -- ElvUI badge if detected
    if Deadpool.modules.Theme.isElvUI then
        local elvBadge = titleBar:CreateFontString(nil, "OVERLAY")
        elvBadge:SetFont(Deadpool.modules.Theme:GetBodyFont())
        elvBadge:SetPoint("LEFT", titleText, "RIGHT", 10, 0)
        elvBadge:SetText("|cFF00DDFF[ElvUI]|r")
    end

    -- Version label
    local verText = titleBar:CreateFontString(nil, "OVERLAY")
    verText:SetFont(Deadpool.modules.Theme:GetBodyFont())
    verText:SetPoint("RIGHT", titleBar, "RIGHT", -30, 0)
    verText:SetTextColor(t.textDim[1], t.textDim[2], t.textDim[3])
    verText:SetText("v" .. Deadpool.version)

    -- Close button â€” visible X
    local closeBtn = CreateFrame("Button", nil, titleBar)
    closeBtn:SetSize(26, 26)
    closeBtn:SetPoint("RIGHT", titleBar, "RIGHT", -2, 0)
    local xText = closeBtn:CreateFontString(nil, "OVERLAY")
    xText:SetFont("Fonts\\FRIZQT__.TTF", 16, "OUTLINE")
    xText:SetPoint("CENTER", 0, 0)
    xText:SetText("X")
    xText:SetTextColor(0.8, 0.2, 0.2)
    closeBtn:SetScript("OnEnter", function() xText:SetTextColor(1, 0.4, 0.4) end)
    closeBtn:SetScript("OnLeave", function() xText:SetTextColor(0.8, 0.2, 0.2) end)
    closeBtn:SetScript("OnClick", function() mainFrame:Hide() end)

    -- Title
    mainFrame.TitleText = mainFrame.titleText

    tinsert(UISpecialFrames, "DeadpoolMainFrame")

    -- Tabs
    self:CreateTabs()

    -- Filter bar
    self:CreateFilterBar()

    -- Content area
    self:CreateContentArea()

    -- Status bar
    statusText = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statusText:SetPoint("BOTTOMLEFT", mainFrame, "BOTTOMLEFT", 12, 8)
    statusText:SetTextColor(0.5, 0.5, 0.5)

    -- Bottom buttons
    local addBtn = CreateFrame("Button", nil, mainFrame, "UIPanelButtonTemplate")
    addBtn:SetSize(100, 22)
    addBtn:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -28, 6)
    addBtn:SetText("Add Target")
    addBtn:SetScript("OnClick", function()
        if UnitExists("target") and UnitIsPlayer("target") and UnitIsEnemy("player", "target") then
            local fullName = Deadpool:GetUnitFullName("target")
            if fullName then Deadpool:AddToKOS(fullName, "") end
        else
            StaticPopup_Show("DEADPOOL_ADD_KOS")
        end
    end)

    local syncBtn = CreateFrame("Button", nil, mainFrame, "UIPanelButtonTemplate")
    syncBtn:SetSize(60, 22)
    syncBtn:SetPoint("RIGHT", addBtn, "LEFT", -4, 0)
    syncBtn:SetText("Sync")
    syncBtn:SetScript("OnClick", function() Deadpool:RequestSync() end)

    -- Popup dialogs
    StaticPopupDialogs["DEADPOOL_ADD_KOS"] = {
        text = "Enter player name to add to Kill on Sight:",
        button1 = "Add", button2 = "Cancel",
        hasEditBox = true, maxLetters = 64,
        OnAccept = function(self)
            local name = self.editBox:GetText()
            if name and name ~= "" then Deadpool:AddToKOS(name, "") end
        end,
        EditBoxOnEnterPressed = function(self)
            local name = self:GetParent().editBox:GetText()
            if name and name ~= "" then Deadpool:AddToKOS(name, "") end
            self:GetParent():Hide()
        end,
        timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
    }

    StaticPopupDialogs["DEADPOOL_PLACE_BOUNTY"] = {
        text = "Place bounty on %s\nEnter gold amount:",
        button1 = "Place Bounty", button2 = "Cancel",
        hasEditBox = true, maxLetters = 10,
        OnAccept = function(self, data)
            local gold = tonumber(self.editBox:GetText())
            if gold and gold > 0 and data then Deadpool:PlaceBounty(data, gold, 10) end
        end,
        EditBoxOnEnterPressed = function(self)
            local gold = tonumber(self:GetParent().editBox:GetText())
            local data = self:GetParent().data
            if gold and gold > 0 and data then Deadpool:PlaceBounty(data, gold, 10) end
            self:GetParent():Hide()
        end,
        timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
    }
end

----------------------------------------------------------------------
-- Tab buttons
----------------------------------------------------------------------
function UI:CreateTabs()
    tabButtons = {}
    for i, tabDef in ipairs(TABS) do
        local btn = CreateFrame("Button", "DeadpoolTab" .. i, mainFrame)
        btn:SetSize(1, TAB_HEIGHT)
        btn:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 0, -26)

        btn.bg = btn:CreateTexture(nil, "BACKGROUND")
        btn.bg:SetAllPoints()
        btn.bg:SetColorTexture(0.15, 0.15, 0.15, 0.9)

        btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        btn.text:SetPoint("CENTER")
        btn.text:SetText(tabDef.label)

        btn.highlight = btn:CreateTexture(nil, "HIGHLIGHT")
        btn.highlight:SetAllPoints()
        btn.highlight:SetColorTexture(0.3, 0.1, 0.1, 0.4)

        btn:SetScript("OnClick", function() UI:SelectTab(tabDef.key) end)

        tabButtons[tabDef.key] = btn
        tabButtons[tabDef.key]._index = i
    end
    self:LayoutTabs()
end

function UI:LayoutTabs()
    local fw = mainFrame:GetWidth()
    local tabWidth = math.floor((fw - 20) / #TABS)
    for _, tabDef in ipairs(TABS) do
        local btn = tabButtons[tabDef.key]
        local i = btn._index
        btn:ClearAllPoints()
        btn:SetSize(tabWidth - 2, TAB_HEIGHT)
        btn:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 10 + (i - 1) * tabWidth, -26)
    end
end

function UI:SelectTab(key)
    activeTab = key
    local t = Deadpool.modules.Theme.active
    for k, btn in pairs(tabButtons) do
        if type(btn) == "table" and btn.bg then
            if k == key then
                btn.bg:SetColorTexture(t.tabActive[1], t.tabActive[2], t.tabActive[3], t.tabActive[4])
                btn.text:SetTextColor(t.tabTextActive[1], t.tabTextActive[2], t.tabTextActive[3])
            else
                btn.bg:SetColorTexture(t.tabInactive[1], t.tabInactive[2], t.tabInactive[3], t.tabInactive[4])
                btn.text:SetTextColor(t.tabTextInactive[1], t.tabTextInactive[2], t.tabTextInactive[3])
            end
        end
    end

    -- Hide ALL containers
    if contentArea then contentArea:Hide() end
    if dashboardFrame then dashboardFrame:Hide() end
    if UI.settingsPanel then UI.settingsPanel:Hide() end

    -- Show only the one we need
    if key == "dashboard" then
        if dashboardFrame then dashboardFrame:Show(); self:RenderDashboard() end
    elseif key == "settings" then
        self:ShowSettingsPanel()
    else
        if contentArea then contentArea:Show() end
    end
    self:RefreshContent()
end
----------------------------------------------------------------------
-- Filter bar
----------------------------------------------------------------------
local filterBox
function UI:CreateFilterBar()
    local bar = CreateFrame("Frame", nil, mainFrame)
    bar:SetSize(FRAME_WIDTH - 20, 24)
    bar:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 10, -56)

    filterBox = CreateFrame("EditBox", "DeadpoolFilterBox", bar, "InputBoxTemplate")
    filterBox:SetSize(240, 20)
    filterBox:SetPoint("LEFT", bar, "LEFT", 4, 0)
    filterBox:SetAutoFocus(false)
    filterBox:SetMaxLetters(64)

    local ph = filterBox:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    ph:SetPoint("LEFT", 6, 0)
    ph:SetText("Search / filter...")
    filterBox.placeholder = ph

    filterBox:SetScript("OnTextChanged", function(self)
        filterText = self:GetText():lower()
        if filterText == "" then ph:Show() else ph:Hide() end
        UI:RefreshContent()
    end)
    filterBox:SetScript("OnEditFocusGained", function() ph:Hide() end)
    filterBox:SetScript("OnEditFocusLost", function(self)
        if self:GetText() == "" then ph:Show() end
    end)
    filterBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
end

----------------------------------------------------------------------
-- Content area — simple frame with manual scroll offset (no FauxScrollFrame)
----------------------------------------------------------------------
local scrollOffset = 0  -- shared scroll offset, reset on tab switch

function UI:CreateContentArea()
    contentArea = CreateFrame("Frame", nil, mainFrame)
    contentArea:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 10, -80)
    contentArea:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -10, 28)

    -- Headers
    contentArea.headerFrame = CreateFrame("Frame", nil, contentArea)
    contentArea.headerFrame:SetSize(FRAME_WIDTH - 22, HEADER_HEIGHT)
    contentArea.headerFrame:SetPoint("TOPLEFT")
    local hdrBg = contentArea.headerFrame:CreateTexture(nil, "BACKGROUND")
    hdrBg:SetAllPoints()
    hdrBg:SetColorTexture(0.1, 0.1, 0.1, 0.8)

    -- Row container (direct child of contentArea, below header)
    local rowContainer = CreateFrame("Frame", nil, contentArea)
    rowContainer:SetPoint("TOPLEFT", contentArea.headerFrame, "BOTTOMLEFT", 0, -2)
    rowContainer:SetPoint("BOTTOMRIGHT", contentArea, "BOTTOMRIGHT", 0, 0)

    -- Mouse wheel scrolling
    rowContainer:EnableMouseWheel(true)
    rowContainer:SetScript("OnMouseWheel", function(self, delta)
        scrollOffset = scrollOffset - delta
        if scrollOffset < 0 then scrollOffset = 0 end
        -- Clamp handled in render functions
        UI:RefreshContent()
    end)

    contentArea.rowContainer = rowContainer
    contentArea.rows = {}

    local visibleRows = math.floor((FRAME_HEIGHT - 140) / ROW_HEIGHT) + 2
    for i = 1, visibleRows do
        contentArea.rows[i] = self:CreateRow(rowContainer, i)
    end

    -- Create dashboard frame (separate from scroll content)
    self:CreateDashboardFrame()
end

----------------------------------------------------------------------
-- Row template
----------------------------------------------------------------------
function UI:CreateRow(parent, index)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(FRAME_WIDTH - 44, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)

    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row.bg:SetColorTexture(0, 0, 0, 0)

    row.highlight = row:CreateTexture(nil, "HIGHLIGHT")
    row.highlight:SetAllPoints()
    row.highlight:SetColorTexture(0.3, 0.1, 0.1, 0.3)

    row.cols = {}
    for c = 1, 8 do
        row.cols[c] = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    end

    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetScript("OnClick", function(self, button)
        if button == "RightButton" and self.data then
            UI:ShowRowContextMenu(self)
        end
    end)

    row:SetScript("OnEnter", function(self)
        if self.tooltipFunc then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            self:tooltipFunc()
            GameTooltip:Show()
        end
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)

    return row
end

----------------------------------------------------------------------
-- Context menu
----------------------------------------------------------------------
if DeadpoolContextMenu then DeadpoolContextMenu:Hide(); DeadpoolContextMenu:SetParent(nil) end
local ctxMenu = CreateFrame("Frame", "DeadpoolContextMenu", UIParent, "UIDropDownMenuTemplate")

function UI:ShowRowContextMenu(row)
    local data = row.data
    if not data then return end
    local menuList = {}
    local fullName = data._key

    if activeTab == "kos" then
        table.insert(menuList, { text = Deadpool:ShortName(fullName), isTitle = true, notCheckable = true })
        table.insert(menuList, { text = "Place Bounty", notCheckable = true, func = function()
            local d = StaticPopup_Show("DEADPOOL_PLACE_BOUNTY", Deadpool:ShortName(fullName))
            if d then d.data = fullName end
        end })
        table.insert(menuList, { text = "Remove from KOS", notCheckable = true, func = function()
            Deadpool:RemoveFromKOS(fullName)
        end })
    elseif activeTab == "bounties" then
        table.insert(menuList, { text = "Bounty: " .. Deadpool:ShortName(fullName), isTitle = true, notCheckable = true })
        if not data.expired then
            table.insert(menuList, { text = "Expire Bounty", notCheckable = true, func = function()
                if Deadpool.db.bounties[fullName] then
                    Deadpool.db.bounties[fullName].expired = true
                    Deadpool.db.bounties[fullName].expiredReason = "Manually expired"
                    Deadpool:BumpSyncVersion()
                    Deadpool:RefreshUI()
                end
            end })
        end
    elseif activeTab == "enemies" then
        table.insert(menuList, { text = Deadpool:ShortName(fullName), isTitle = true, notCheckable = true })
        if not Deadpool:IsKOS(fullName) then
            table.insert(menuList, { text = "Add to KOS", notCheckable = true, func = function()
                Deadpool:AddToKOS(fullName, "Public Enemy")
            end })
        end
        table.insert(menuList, { text = "Place Bounty", notCheckable = true, func = function()
            local d = StaticPopup_Show("DEADPOOL_PLACE_BOUNTY", Deadpool:ShortName(fullName))
            if d then d.data = fullName end
        end })
    end

    table.insert(menuList, { text = "Cancel", notCheckable = true })
    EasyMenu(menuList, ctxMenu, "cursor", 0, 0, "MENU")
end

----------------------------------------------------------------------
----------------------------------------------------------------------
-- Refresh dispatcher
----------------------------------------------------------------------
function UI:RefreshContent()
    if not contentArea then return end
    self:LayoutTabs()

    if activeTab == "dashboard" or activeTab == "settings" then
        return
    end

    if dashboardFrame then dashboardFrame:Hide() end
    if UI.settingsPanel then UI.settingsPanel:Hide() end
    contentArea:Show()

    -- Reset scroll to top on tab switch
    scrollOffset = 0

    for _, row in ipairs(contentArea.rows) do
        row:SetScript("OnClick", function(self, button)
            if button == "RightButton" and self.data then
                UI:ShowRowContextMenu(self)
            end
        end)
    end

    if activeTab == "kos" then self:RenderKOSList()
    elseif activeTab == "bounties" then self:RenderBounties()
    elseif activeTab == "enemies" then self:RenderEnemies()
    elseif activeTab == "scoreboard" then self:RenderScoreboard()
    elseif activeTab == "mystats" then self:RenderMyStats()
    elseif activeTab == "killlog" then self:RenderKillLog()
    end
end

----------------------------------------------------------------------
-- Header utility
----------------------------------------------------------------------
function UI:SetHeaders(...)
    for _, child in pairs({contentArea.headerFrame:GetRegions()}) do
        if child.SetText then child:Hide() end
    end
    local cols = {...}
    if not contentArea.headerLabels then contentArea.headerLabels = {} end
    for i, def in ipairs(cols) do
        if not contentArea.headerLabels[i] then
            contentArea.headerLabels[i] = contentArea.headerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        end
        local label = contentArea.headerLabels[i]
        label:ClearAllPoints()
        label:SetPoint("LEFT", contentArea.headerFrame, "LEFT", def.x, 0)
        label:SetWidth(def.w or 100)
        label:SetJustifyH("LEFT")
        label:SetText(def.text)
        label:SetTextColor(Deadpool.modules.Theme:Accent())
        label:Show()
    end
    for i = #cols + 1, #(contentArea.headerLabels or {}) do
        if contentArea.headerLabels[i] then contentArea.headerLabels[i]:Hide() end
    end
end

----------------------------------------------------------------------
-- Row helpers
----------------------------------------------------------------------
local function SetCol(row, idx, x, w, text, justify)
    local col = row.cols[idx]
    if not col then return end
    col:ClearAllPoints()
    col:SetPoint("LEFT", row, "LEFT", x, 0)
    col:SetWidth(w)
    col:SetJustifyH(justify or "LEFT")
    col:SetText(text or "")
    col:Show()
end

local function HideCols(row, from, to)
    for i = from, to do
        if row.cols[i] then row.cols[i]:Hide() end
    end
end

local function RowBg(row, idx)
    local t = Deadpool.modules.Theme.active
    if idx % 2 == 0 then
        row.bg:SetColorTexture(t.rowAlt[1], t.rowAlt[2], t.rowAlt[3], t.rowAlt[4])
    else
        row.bg:SetColorTexture(0, 0, 0, 0)
    end
end

----------------------------------------------------------------------
-- KOS List tab
----------------------------------------------------------------------
function UI:RenderKOSList()
    self:SetHeaders(
        { text = "Name",      x = 4,   w = 150 },
        { text = "Class",     x = 156, w = 80 },
        { text = "Lvl",       x = 238, w = 30 },
        { text = "Kills",     x = 270, w = 50 },
        { text = "Last Kill", x = 322, w = 100 },
        { text = "Last Seen", x = 424, w = 140 },
        { text = "Bounty",    x = 566, w = 65 },
        { text = "Reason",    x = 633, w = 280 }
    )
    local data = Deadpool:GetKOSSorted("totalKills", false)
    if filterText ~= "" then
        local f = {}
        for _, e in ipairs(data) do
            local s = ((e.name or "") .. (e.class or "") .. (e.reason or "") .. (e._key or "")):lower()
            if s:find(filterText, 1, true) then table.insert(f, e) end
        end
        data = f
    end
    local numRows = #data
    local visibleRows = #contentArea.rows
    local offset = scrollOffset
    for i = 1, visibleRows do
        local row = contentArea.rows[i]
        local idx = i + offset
        if idx <= numRows then
            local e = data[idx]; row.data = e; row:Show(); RowBg(row, idx)
            local name = e.class and Deadpool:ClassColor(e.class, e.name or Deadpool:ShortName(e._key)) or (e.name or Deadpool:ShortName(e._key))
            SetCol(row, 1, 4, 150, name)
            SetCol(row, 2, 156, 80, e.class and Deadpool:ClassColor(e.class, e.class) or "?")
            SetCol(row, 3, 238, 30, e.level and tostring(e.level) or "?")
            SetCol(row, 4, 270, 50, tostring(e.totalKills or 0))
            SetCol(row, 5, 322, 100, Deadpool:TimeAgo(e.lastKilledTime))
            local seenText = e.lastSeenZone and (e.lastSeenZone .. " " .. Deadpool:TimeAgo(e.lastSeenTime)) or "-"
            SetCol(row, 6, 424, 140, seenText)
            local bText = ""
            if Deadpool:HasActiveBounty(e._key) then
                local b = Deadpool:GetBounty(e._key)
                bText = Deadpool.colors.gold .. b.bountyGold .. "g|r"
            end
            SetCol(row, 7, 566, 65, bText)
            SetCol(row, 8, 633, 280, Deadpool.colors.grey .. (e.reason or "") .. "|r")
            row.tooltipFunc = function()
                GameTooltip:AddLine(name, 1, 1, 1)
                if e.race then GameTooltip:AddLine("Race: " .. e.race, 0.7, 0.7, 0.7) end
                if e.level and e.level > 0 then GameTooltip:AddLine("Level: " .. e.level, 0.7, 0.7, 0.7) end
                if e.guild then GameTooltip:AddLine("Guild: <" .. e.guild .. ">", 0.4, 0.6, 0.8) end
                if e.lastKilledBy then GameTooltip:AddLine("Last killed by: " .. Deadpool:ShortName(e.lastKilledBy), 0.5, 0.9, 0.5) end
                GameTooltip:AddLine("Added: " .. Deadpool:FormatDate(e.addedDate), 0.5, 0.5, 0.5)
                GameTooltip:AddLine(" "); GameTooltip:AddLine("Right-click for options", 0.5, 0.5, 0.5)
            end
        else row:Hide(); row.data = nil end
    end
    statusText:SetText(Deadpool:GetKOSCount() .. " targets on Kill on Sight list")
end

----------------------------------------------------------------------
-- Bounties tab
----------------------------------------------------------------------
function UI:RenderBounties()
    self:SetHeaders(
        { text = "Target",    x = 4,   w = 180 },
        { text = "Bounty",    x = 186, w = 110 },
        { text = "Progress",  x = 298, w = 130 },
        { text = "Placed By", x = 430, w = 160 },
        { text = "Placed",    x = 592, w = 140 },
        { text = "Status",    x = 734, w = 180 }
    )
    local data = Deadpool:GetAllBounties()
    if filterText ~= "" then
        local f = {}
        for _, e in ipairs(data) do
            if ((e.target or "") .. (e.placedBy or "")):lower():find(filterText, 1, true) then table.insert(f, e) end
        end
        data = f
    end
    local numRows = #data
    local visibleRows = #contentArea.rows
    local offset = scrollOffset
    for i = 1, visibleRows do
        local row = contentArea.rows[i]
        local idx = i + offset
        if idx <= numRows then
            local e = data[idx]; row.data = e; row:Show(); RowBg(row, idx)
            local kos = Deadpool:GetKOSEntry(e.target)
            local cn = kos and kos.class
            local nm = cn and Deadpool:ClassColor(cn, Deadpool:ShortName(e.target)) or Deadpool:ShortName(e.target)
            SetCol(row, 1, 4, 180, nm)
            SetCol(row, 2, 186, 110, Deadpool.colors.gold .. (e.bountyGold or 0) .. "g|r")
            SetCol(row, 3, 298, 130, (e.currentKills or 0) .. " / " .. (e.maxKills or 10))
            SetCol(row, 4, 430, 160, Deadpool:ShortName(e.placedBy or "?"))
            SetCol(row, 5, 592, 140, Deadpool:TimeAgo(e.placedDate))
            local st
            if e.expired then st = Deadpool.colors.grey .. "EXPIRED|r"
            elseif (e.currentKills or 0) >= (e.maxKills or 10) then st = Deadpool.colors.green .. "COMPLETE|r"
            else st = Deadpool.colors.green .. "ACTIVE|r" end
            SetCol(row, 6, 734, 180, st)
            HideCols(row, 7, 8)
            row.tooltipFunc = function()
                GameTooltip:AddLine("Bounty: " .. Deadpool:ShortName(e.target), 1, 0.84, 0)
                GameTooltip:AddLine(Deadpool:FormatGold(e.bountyGold) .. " for " .. (e.maxKills or 10) .. " kills", 0.7, 0.7, 0.7)
                if e.claims and #e.claims > 0 then
                    GameTooltip:AddLine(" "); GameTooltip:AddLine("Claims:", 0.9, 0.5, 0.5)
                    for _, c in ipairs(e.claims) do
                        GameTooltip:AddLine("  " .. Deadpool:ShortName(c.killer) .. " in " .. (c.zone or "?") .. " (" .. Deadpool:TimeAgo(c.time) .. ")", 0.6, 0.8, 0.6)
                    end
                end
                GameTooltip:AddLine(" "); GameTooltip:AddLine("Right-click for options", 0.5, 0.5, 0.5)
            end
        else row:Hide(); row.data = nil end
    end
    local a = #Deadpool:GetActiveBounties()
    statusText:SetText(a .. " active bounties (" .. Deadpool:TableCount(Deadpool.db.bounties) .. " total)")
end

----------------------------------------------------------------------
-- Public Enemies tab
----------------------------------------------------------------------
function UI:RenderEnemies()
    self:SetHeaders(
        { text = "#",          x = 4,   w = 30 },
        { text = "Enemy",      x = 36,  w = 150 },
        { text = "Class",      x = 188, w = 90 },
        { text = "Lvl",        x = 280, w = 30 },
        { text = "Killed Us",  x = 312, w = 90 },
        { text = "We Killed",  x = 404, w = 90 },
        { text = "K/D",        x = 496, w = 60 },
        { text = "Last Attack", x = 558, w = 150 }
    )
    local data = Deadpool:GetPublicEnemiesSorted("timesKilledUs")
    if filterText ~= "" then
        local f = {}
        for _, e in ipairs(data) do
            if (e._key or ""):lower():find(filterText, 1, true) or (e.class or ""):lower():find(filterText, 1, true) then
                table.insert(f, e)
            end
        end
        data = f
    end
    local numRows = #data
    local visibleRows = #contentArea.rows
    local offset = scrollOffset
    for i = 1, visibleRows do
        local row = contentArea.rows[i]
        local idx = i + offset
        if idx <= numRows then
            local e = data[idx]; row.data = e; row:Show(); RowBg(row, idx)
            local rk = tostring(idx)
            if idx == 1 then rk = Deadpool.colors.red .. "1|r"
            elseif idx == 2 then rk = Deadpool.colors.orange .. "2|r"
            elseif idx == 3 then rk = Deadpool.colors.yellow .. "3|r" end
            SetCol(row, 1, 4, 30, rk, "CENTER")
            local nm = e.class and Deadpool:ClassColor(e.class, Deadpool:ShortName(e._key)) or Deadpool:ShortName(e._key)
            SetCol(row, 2, 36, 150, nm)
            SetCol(row, 3, 188, 90, e.class and Deadpool:ClassColor(e.class, e.class) or "?")
            SetCol(row, 4, 280, 30, e.level and tostring(e.level) or "?")
            SetCol(row, 5, 312, 90, Deadpool.colors.red .. (e.timesKilledUs or 0) .. "|r")
            SetCol(row, 6, 404, 90, Deadpool.colors.green .. (e.timesWeKilledThem or 0) .. "|r")
            local kd = "-"
            if (e.timesKilledUs or 0) > 0 then
                kd = string.format("%.1f", (e.timesWeKilledThem or 0) / e.timesKilledUs)
            elseif (e.timesWeKilledThem or 0) > 0 then
                kd = Deadpool.colors.green .. "INF|r"
            end
            SetCol(row, 7, 496, 60, kd)
            SetCol(row, 8, 558, 150, Deadpool:TimeAgo(e.lastKilledUsTime))
            row.tooltipFunc = function()
                GameTooltip:AddLine(Deadpool:ShortName(e._key), 1, 1, 1)
                if e.class then GameTooltip:AddLine("Class: " .. e.class, 0.7, 0.7, 0.7) end
                if e.race then GameTooltip:AddLine("Race: " .. e.race, 0.7, 0.7, 0.7) end
                if e.guild then GameTooltip:AddLine("Guild: <" .. e.guild .. ">", 0.4, 0.6, 0.8) end
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine("They killed guild: " .. (e.timesKilledUs or 0) .. " times", 0.9, 0.3, 0.3)
                GameTooltip:AddLine("Guild killed them: " .. (e.timesWeKilledThem or 0) .. " times", 0.3, 0.9, 0.3)
                GameTooltip:AddLine(" "); GameTooltip:AddLine("Right-click to add to KOS / Bounty", 0.5, 0.5, 0.5)
            end
        else row:Hide(); row.data = nil end
    end
    statusText:SetText(Deadpool:TableCount(Deadpool.db.enemySheet) .. " enemy players tracked")
end

----------------------------------------------------------------------
-- Scoreboard tab
----------------------------------------------------------------------
function UI:RenderScoreboard()
    self:SetHeaders(
        { text = "#",           x = 4,   w = 30 },
        { text = "Player",      x = 36,  w = 180 },
        { text = "Points",      x = 218, w = 100 },
        { text = "Total Kills", x = 320, w = 100 },
        { text = "KOS Kills",   x = 422, w = 100 },
        { text = "Bounty Kills", x = 524, w = 110 },
        { text = "PvP Kills",   x = 636, w = 100 },
        { text = "Best Streak", x = 738, w = 120 }
    )
    local data = Deadpool:GetScoreboardSorted("totalPoints")
    if filterText ~= "" then
        local f = {}
        for _, e in ipairs(data) do
            if (e._key or ""):lower():find(filterText, 1, true) then table.insert(f, e) end
        end
        data = f
    end
    local numRows = #data
    local visibleRows = #contentArea.rows
    local offset = scrollOffset
    for i = 1, visibleRows do
        local row = contentArea.rows[i]
        local idx = i + offset
        if idx <= numRows then
            local e = data[idx]; row.data = e; row:Show(); RowBg(row, idx)
            local rk = tostring(idx)
            if idx == 1 then rk = Deadpool.colors.gold .. "1|r"
            elseif idx == 2 then rk = "|cFFC0C0C02|r"
            elseif idx == 3 then rk = "|cFFCD7F323|r" end
            SetCol(row, 1, 4, 30, rk, "CENTER")
            local pn = Deadpool:ShortName(e._key)
            if e._key == Deadpool:GetPlayerFullName() then pn = Deadpool.colors.cyan .. pn .. "|r" end
            SetCol(row, 2, 36, 180, pn)
            SetCol(row, 3, 218, 100, Deadpool.colors.yellow .. (e.totalPoints or 0) .. "|r")
            SetCol(row, 4, 320, 100, tostring(e.totalKills or 0))
            SetCol(row, 5, 422, 100, tostring(e.kosKills or 0))
            SetCol(row, 6, 524, 110, tostring(e.bountyKills or 0))
            SetCol(row, 7, 636, 100, tostring(e.randomKills or 0))
            SetCol(row, 8, 738, 120, tostring(e.bestStreak or 0))
            row.tooltipFunc = function()
                GameTooltip:AddLine(Deadpool:ShortName(e._key), 1, 1, 1)
                GameTooltip:AddLine("Total Points: " .. (e.totalPoints or 0), 1, 1, 0)
                GameTooltip:AddLine("Total Kills: " .. (e.totalKills or 0), 0.7, 0.7, 0.7)
                GameTooltip:AddLine("Last Kill: " .. Deadpool:TimeAgo(e.lastKill), 0.5, 0.5, 0.5)
            end
        else row:Hide(); row.data = nil end
    end
    statusText:SetText(Deadpool:TableCount(Deadpool.db.scoreboard) .. " guild members ranked")
end

----------------------------------------------------------------------
-- My Stats tab
----------------------------------------------------------------------
function UI:RenderMyStats()
    self:SetHeaders({ text = "Personal Statistics", x = 4, w = 500 })
    local myName = Deadpool:GetPlayerFullName()
    local score = Deadpool:GetOrCreateScore(myName)
    local rank = Deadpool:GetPlayerRank(myName)
    local lines = {}
    table.insert(lines, { label = Deadpool.colors.header .. "=== YOUR STATS ===|r", value = "" })
    table.insert(lines, { label = "Rank", value = Deadpool.colors.gold .. "#" .. rank .. "|r" })
    table.insert(lines, { label = "Total Points", value = Deadpool.colors.yellow .. (score.totalPoints or 0) .. "|r" })
    table.insert(lines, { label = "Total Kills", value = Deadpool.colors.green .. (score.totalKills or 0) .. "|r" })
    table.insert(lines, { label = "KOS Kills", value = Deadpool.colors.red .. (score.kosKills or 0) .. "|r" })
    table.insert(lines, { label = "Bounty Kills", value = Deadpool.colors.gold .. (score.bountyKills or 0) .. "|r" })
    table.insert(lines, { label = "Random PvP Kills", value = tostring(score.randomKills or 0) })
    table.insert(lines, { label = "Best Streak", value = Deadpool.colors.orange .. (score.bestStreak or 0) .. "|r" })
    table.insert(lines, { label = "Last Kill", value = Deadpool:TimeAgo(score.lastKill) })
    table.insert(lines, { label = "", value = "" })
    table.insert(lines, { label = Deadpool.colors.header .. "=== DEATHS ===|r", value = "" })
    table.insert(lines, { label = "Total Deaths", value = Deadpool.colors.red .. #(Deadpool.db.deathLog or {}) .. "|r" })
    local nemesis, nemesisCount = nil, 0
    local myDeaths = {}
    for _, d in ipairs(Deadpool.db.deathLog or {}) do
        if d.victim == myName then myDeaths[d.killer] = (myDeaths[d.killer] or 0) + 1 end
    end
    for k, v in pairs(myDeaths) do if v > nemesisCount then nemesis = k; nemesisCount = v end end
    if nemesis then
        table.insert(lines, { label = "Personal Nemesis", value = Deadpool.colors.red .. Deadpool:ShortName(nemesis) .. " (" .. nemesisCount .. "x)|r" })
    end
    local favTarget, favCount = nil, 0
    local myKills = {}
    for _, k in ipairs(Deadpool.db.killLog or {}) do
        if k.killer == myName then myKills[k.victim] = (myKills[k.victim] or 0) + 1 end
    end
    for k, v in pairs(myKills) do if v > favCount then favTarget = k; favCount = v end end
    if favTarget then
        table.insert(lines, { label = "Favorite Victim", value = Deadpool.colors.green .. Deadpool:ShortName(favTarget) .. " (" .. favCount .. "x)|r" })
    end
    table.insert(lines, { label = "", value = "" })
    table.insert(lines, { label = Deadpool.colors.header .. "=== GUILD ===|r", value = "" })
    table.insert(lines, { label = "KOS List Size", value = tostring(Deadpool:GetKOSCount()) })
    table.insert(lines, { label = "Active Bounties", value = tostring(#Deadpool:GetActiveBounties()) })
    table.insert(lines, { label = "Kills Logged", value = tostring(#(Deadpool.db.killLog or {})) })
    table.insert(lines, { label = "Enemies Tracked", value = tostring(Deadpool:TableCount(Deadpool.db.enemySheet or {})) })

    local numRows = #lines
    local visibleRows = #contentArea.rows
    local offset = scrollOffset
    for i = 1, visibleRows do
        local row = contentArea.rows[i]
        local idx = i + offset
        if idx <= numRows then
            local line = lines[idx]; row.data = nil; row:Show(); RowBg(row, idx)
            SetCol(row, 1, 30, 350, line.label)
            SetCol(row, 2, 400, 400, line.value)
            HideCols(row, 3, 8)
            row.tooltipFunc = nil
        else row:Hide(); row.data = nil end
    end
    statusText:SetText("Personal stats for " .. Deadpool:ShortName(myName))
end

----------------------------------------------------------------------
-- Kill Log tab
----------------------------------------------------------------------
function UI:RenderKillLog()
    self:SetHeaders(
        { text = "Killer",  x = 4,   w = 140 },
        { text = "Victim",  x = 146, w = 140 },
        { text = "Class",   x = 288, w = 90 },
        { text = "Lvl",     x = 380, w = 30 },
        { text = "Zone",    x = 412, w = 180 },
        { text = "Type",    x = 594, w = 80 },
        { text = "Pts",     x = 676, w = 50 },
        { text = "When",    x = 728, w = 130 }
    )
    local data = Deadpool:GetKillLog("all")
    if filterText ~= "" then
        local f = {}
        for _, e in ipairs(data) do
            local s = ((e.killer or "") .. (e.victim or "") .. (e.victimClass or "") .. (e.zone or "")):lower()
            if s:find(filterText, 1, true) then table.insert(f, e) end
        end
        data = f
    end
    local numRows = #data
    local visibleRows = #contentArea.rows
    local offset = scrollOffset
    for i = 1, visibleRows do
        local row = contentArea.rows[i]
        local idx = i + offset
        if idx <= numRows then
            local e = data[idx]; row.data = e; row:Show(); RowBg(row, idx)
            SetCol(row, 1, 4, 140, Deadpool:ShortName(e.killer))
            local vn = e.victimClass and Deadpool:ClassColor(e.victimClass, Deadpool:ShortName(e.victim)) or Deadpool:ShortName(e.victim)
            SetCol(row, 2, 146, 140, vn)
            SetCol(row, 3, 288, 90, e.victimClass and Deadpool:ClassColor(e.victimClass, e.victimClass) or "?")
            SetCol(row, 4, 380, 30, e.victimLevel and tostring(e.victimLevel) or "?")
            SetCol(row, 5, 412, 180, Deadpool.colors.yellow .. (e.zone or "?") .. "|r")
            local tt
            if e.isBounty then tt = Deadpool.colors.gold .. "BOUNTY|r"
            elseif e.isKOS then tt = Deadpool.colors.red .. "KOS|r"
            else tt = Deadpool.colors.grey .. "PvP|r" end
            SetCol(row, 6, 594, 80, tt)
            SetCol(row, 7, 676, 50, "+" .. (e.points or 0))
            SetCol(row, 8, 728, 130, Deadpool:TimeAgo(e.time))
            HideCols(row, 8, 8)
            row.tooltipFunc = nil
        else row:Hide(); row.data = nil end
    end
    statusText:SetText(#Deadpool.db.killLog .. " kills logged")
end

----------------------------------------------------------------------
-- Settings Panel (dedicated frame, like Dashboard)
----------------------------------------------------------------------
UI.settingsBuilt = false

function UI:ShowSettingsPanel()
    if not UI.settingsBuilt then
        self:BuildSettingsPanel()
    end
    UI.settingsPanel:Show()
    self:UpdateSettingsValues()
end

function UI:BuildSettingsPanel()
    UI.settingsBuilt = true
    local TM = Deadpool.modules.Theme
    local t = TM.active

    UI.settingsPanel = CreateFrame("Frame", nil, mainFrame)
    UI.settingsPanel:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 20, -82)
    UI.settingsPanel:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -20, 30)
    UI.settingsPanel:Hide()

    local content = UI.settingsPanel
    UI.settingsPanel._checkboxes = {}
    UI.settingsPanel._infoValues = {}

    -- Two-column layout: left starts at x=0, right at x=460
    local COL2 = 460

    -- Helpers take an x offset for column positioning
    local function Header(text, x, y)
        local lbl = content:CreateFontString(nil, "OVERLAY")
        lbl:SetFont(TM:GetFont(14, "OUTLINE"))
        lbl:SetPoint("TOPLEFT", content, "TOPLEFT", x, y)
        lbl:SetText(text)
        lbl:SetTextColor(t.accent[1], t.accent[2], t.accent[3])
    end

    local function Check(label, key, x, y)
        local cb = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
        cb:SetPoint("TOPLEFT", content, "TOPLEFT", x + 8, y)
        cb:SetSize(24, 24)
        cb:SetScript("OnClick", function(self)
            Deadpool.db.settings[key] = self:GetChecked() and true or false
        end)
        local lbl = content:CreateFontString(nil, "OVERLAY")
        lbl:SetFont(TM:GetFont(12, ""))
        lbl:SetPoint("LEFT", cb, "RIGHT", 6, 0)
        lbl:SetText(label)
        lbl:SetTextColor(t.text[1], t.text[2], t.text[3])
        UI.settingsPanel._checkboxes[key] = cb
    end

    local function Info(label, key, x, y)
        local lbl = content:CreateFontString(nil, "OVERLAY")
        lbl:SetFont(TM:GetFont(12, ""))
        lbl:SetPoint("TOPLEFT", content, "TOPLEFT", x + 16, y)
        lbl:SetText(label)
        lbl:SetTextColor(t.textDim[1], t.textDim[2], t.textDim[3])
        local val = content:CreateFontString(nil, "OVERLAY")
        val:SetFont(TM:GetFont(12, ""))
        val:SetPoint("LEFT", lbl, "RIGHT", 8, 0)
        val:SetTextColor(t.text[1], t.text[2], t.text[3])
        UI.settingsPanel._infoValues[key] = val
    end

    -- ========================
    -- LEFT COLUMN
    -- ========================
    local ly = -10

    -- THEME
    Header("THEME", 0, ly); ly = ly - 24
    local ddName = "DeadpoolThemeDD"
    if _G[ddName] then _G[ddName]:Hide(); _G[ddName]:SetParent(nil) end
    local dd = CreateFrame("Frame", ddName, content, "UIDropDownMenuTemplate")
    dd:SetPoint("TOPLEFT", content, "TOPLEFT", -6, ly)
    UIDropDownMenu_SetWidth(dd, 200)
    UIDropDownMenu_Initialize(dd, function(self, level)
        for _, key in ipairs(TM.presetOrder) do
            local preset = TM.presets[key]
            local info = UIDropDownMenu_CreateInfo()
            info.text = preset.name
            info.value = key
            info.checked = (Deadpool.db.settings.theme == key)
            info.func = function(btn)
                Deadpool.db.settings.theme = btn.value
                TM:DetectElvUI()
                TM:ApplyTheme()
                UI:ApplyFrameTheme()
                UIDropDownMenu_SetText(dd, TM:GetThemeName())
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    UIDropDownMenu_SetText(dd, TM:GetThemeName())
    UI.settingsPanel._themeDD = dd
    local ddL = _G[ddName.."Left"]; if ddL then ddL:SetAlpha(0) end
    local ddM = _G[ddName.."Middle"]; if ddM then ddM:SetAlpha(0) end
    local ddR = _G[ddName.."Right"]; if ddR then ddR:SetAlpha(0) end
    local bg = CreateFrame("Frame", nil, dd, "BackdropTemplate")
    bg:SetPoint("TOPLEFT", 18, -2); bg:SetPoint("BOTTOMRIGHT", -18, 4)
    bg:SetFrameLevel(dd:GetFrameLevel())
    bg:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8x8",edgeFile="Interface\\Buttons\\WHITE8x8",edgeSize=1})
    bg:SetBackdropColor(t.bgAlt[1], t.bgAlt[2], t.bgAlt[3], t.bgAlt[4])
    bg:SetBackdropBorderColor(t.border[1], t.border[2], t.border[3], t.border[4])
    local ddTxt = _G[ddName.."Text"]; if ddTxt then ddTxt:SetTextColor(t.tabTextActive[1], t.tabTextActive[2], t.tabTextActive[3]) end
    ly = ly - 36

    -- UI SCALE
    Header("UI SCALE", 0, ly); ly = ly - 24
    local slider = CreateFrame("Slider", nil, content, "OptionsSliderTemplate")
    slider:SetPoint("TOPLEFT", content, "TOPLEFT", 10, ly - 4)
    slider:SetSize(220, 16)
    slider:SetMinMaxValues(0.7, 1.3)
    slider:SetValueStep(0.05)
    slider:SetObeyStepOnDrag(true)
    slider:SetValue(Deadpool.db.settings.uiScale or 1.0)
    slider.Low:SetText("70%")
    slider.High:SetText("130%")
    local scaleLabel = content:CreateFontString(nil, "OVERLAY")
    scaleLabel:SetFont(TM:GetFont(12, ""))
    scaleLabel:SetPoint("LEFT", slider, "RIGHT", 14, 0)
    scaleLabel:SetTextColor(t.text[1], t.text[2], t.text[3])
    scaleLabel:SetText(tostring(math.floor((Deadpool.db.settings.uiScale or 1.0) * 100)) .. "%")
    UI.settingsPanel._scaleLabel = scaleLabel
    slider:SetScript("OnValueChanged", function(self, value)
        value = math.floor(value * 20 + 0.5) / 20
        Deadpool.db.settings.uiScale = value
        if mainFrame then mainFrame:SetScale(value) end
        scaleLabel:SetText(tostring(math.floor(value * 100)) .. "%")
    end)
    UI.settingsPanel._scaleSlider = slider
    ly = ly - 40

    -- NOTIFICATIONS
    Header("NOTIFICATIONS", 0, ly); ly = ly - 24
    Check("Announce kills in chat", "announceKills", 0, ly); ly = ly - 26
    Check("KOS sighting alerts", "announceKOSSighted", 0, ly); ly = ly - 26
    Check("Alert sound on KOS spotted", "alertSound", 0, ly); ly = ly - 26
    Check("Broadcast sightings to guild", "broadcastSightings", 0, ly); ly = ly - 26

    -- ========================
    -- RIGHT COLUMN
    -- ========================
    local ry = -10

    -- AUTO-KOS
    Header("AUTO-KOS", COL2, ry); ry = ry - 24
    Check("Auto-add attackers to KOS", "autoKOSOnAttack", COL2, ry); ry = ry - 34

    -- POINTS
    Header("POINTS", COL2, ry); ry = ry - 24
    Info("Random PvP kill: ", "pointsPerKill", COL2, ry); ry = ry - 22
    Info("KOS kill: ", "pointsPerKOSKill", COL2, ry); ry = ry - 22
    Info("Bounty kill: ", "pointsPerBountyKill", COL2, ry); ry = ry - 34

    -- SYNC
    Header("SYNC", COL2, ry); ry = ry - 24
    Check("Guild sync enabled", "syncEnabled", COL2, ry); ry = ry - 26
    Info("Sync version: ", "syncVersion", COL2, ry); ry = ry - 34

    -- DEBUG
    Header("DEBUG", COL2, ry); ry = ry - 24
    Check("Debug mode", "debug", COL2, ry)
end

function UI:UpdateSettingsValues()
    if not UI.settingsPanel then return end
    local s = Deadpool.db.settings

    -- Update checkboxes
    for key, cb in pairs(UI.settingsPanel._checkboxes) do
        cb:SetChecked(s[key] and true or false)
    end

    -- Update info values
    local iv = UI.settingsPanel._infoValues
    if iv.pointsPerKill then iv.pointsPerKill:SetText(Deadpool.colors.yellow .. s.pointsPerKill .. "|r") end
    if iv.pointsPerKOSKill then iv.pointsPerKOSKill:SetText(Deadpool.colors.yellow .. s.pointsPerKOSKill .. "|r") end
    if iv.pointsPerBountyKill then iv.pointsPerBountyKill:SetText(Deadpool.colors.yellow .. s.pointsPerBountyKill .. "|r") end
    if iv.syncVersion then iv.syncVersion:SetText(tostring(Deadpool.db.syncVersion or 0)) end

    -- Update theme dropdown text
    if UI.settingsPanel._themeDD then
        UIDropDownMenu_SetText(UI.settingsPanel._themeDD, Deadpool.modules.Theme:GetThemeName())
    end

    statusText:SetText("Settings | " .. Deadpool.modules.Theme:GetThemeName())
end

----------------------------------------------------------------------
-- Apply theme to main frame (call on theme change)
----------------------------------------------------------------------
function UI:ApplyFrameTheme()
    if not mainFrame then return end
    local t = Deadpool.modules.Theme.active
    if not t then return end

    -- Main backdrop
    mainFrame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 2,
        insets = { left = 0, right = 0, top = 0, bottom = 0 },
    })
    mainFrame:SetBackdropColor(t.bg[1], t.bg[2], t.bg[3], t.bg[4])
    mainFrame:SetBackdropBorderColor(t.border[1], t.border[2], t.border[3], t.border[4])

    -- Title bar
    if mainFrame.titleBarBg then
        mainFrame.titleBarBg:SetColorTexture(t.accent[1] * 0.5, t.accent[2] * 0.5, t.accent[3] * 0.5, 0.95)
    end
    if mainFrame.titleText then
        mainFrame.titleText:SetText(Deadpool.modules.Theme:AccentHex() .. "DEADPOOL|r")
    end

    -- Header background
    if contentArea and contentArea.headerFrame then
        for _, child in pairs({contentArea.headerFrame:GetRegions()}) do
            if child.SetColorTexture then
                child:SetColorTexture(t.headerBg[1], t.headerBg[2], t.headerBg[3], t.headerBg[4])
                break
            end
        end
    end

    -- Dashboard
    if dashboardFrame then
        self:ThemeDashboard()
    end
end

----------------------------------------------------------------------
-- Dashboard frame (custom layout, not row-based)
----------------------------------------------------------------------
function UI:CreateDashboardFrame()
    dashboardFrame = CreateFrame("Frame", nil, mainFrame)
    dashboardFrame:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 10, -80)
    dashboardFrame:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -10, 28)
    dashboardFrame:Hide()

    -- We'll create child elements in ThemeDashboard/RenderDashboard
    dashboardFrame.cards = {}
    dashboardFrame.bars = {}
    dashboardFrame.labels = {}
    dashboardFrame.initialized = false
end

----------------------------------------------------------------------
-- Dashboard helper: create a stat card
----------------------------------------------------------------------
function UI:CreateStatCard(parent, x, y, w, h)
    local card = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    card:SetSize(w, h)
    card:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)

    local t = Deadpool.modules.Theme.active
    card:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    card:SetBackdropColor(t.bgAlt[1], t.bgAlt[2], t.bgAlt[3], t.bgAlt[4])
    card:SetBackdropBorderColor(t.border[1], t.border[2], t.border[3], 0.5)

    card.title = card:CreateFontString(nil, "OVERLAY")
    card.title:SetFont(Deadpool.modules.Theme:GetHeaderFont())
    card.title:SetPoint("TOPLEFT", 8, -6)

    card.value = card:CreateFontString(nil, "OVERLAY")
    card.value:SetFont(Deadpool.modules.Theme:GetFont(22, "OUTLINE"))
    card.value:SetPoint("CENTER", 0, -4)

    card.subtitle = card:CreateFontString(nil, "OVERLAY")
    card.subtitle:SetFont(Deadpool.modules.Theme:GetBodyFont())
    card.subtitle:SetPoint("BOTTOM", 0, 6)
    card.subtitle:SetTextColor(t.textDim[1], t.textDim[2], t.textDim[3])

    return card
end

----------------------------------------------------------------------
-- Dashboard helper: horizontal stat bar
----------------------------------------------------------------------
function UI:CreateStatBar(parent, y, w)
    local bar = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    bar:SetSize(w, 20)
    bar:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -y)

    local t = Deadpool.modules.Theme.active
    bar:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
    })
    bar:SetBackdropColor(t.barBg[1], t.barBg[2], t.barBg[3], t.barBg[4])

    bar.fill = bar:CreateTexture(nil, "ARTWORK")
    bar.fill:SetPoint("TOPLEFT", 0, 0)
    bar.fill:SetPoint("BOTTOMLEFT", 0, 0)
    bar.fill:SetTexture("Interface\\Buttons\\WHITE8x8")
    bar.fill:SetVertexColor(t.barFill[1], t.barFill[2], t.barFill[3], t.barFill[4])
    bar.fill:SetWidth(1)

    bar.label = bar:CreateFontString(nil, "OVERLAY")
    bar.label:SetFont(Deadpool.modules.Theme:GetFont(11, "OUTLINE"))
    bar.label:SetPoint("LEFT", 6, 0)
    bar.label:SetShadowOffset(1, -1)
    bar.label:SetShadowColor(0, 0, 0, 1)

    bar.valueText = bar:CreateFontString(nil, "OVERLAY")
    bar.valueText:SetFont(Deadpool.modules.Theme:GetFont(11, "OUTLINE"))
    bar.valueText:SetPoint("RIGHT", -6, 0)
    bar.valueText:SetShadowOffset(1, -1)
    bar.valueText:SetShadowColor(0, 0, 0, 1)

    bar.SetProgress = function(self, current, max, label, valueStr)
        local pct = max > 0 and (current / max) or 0
        if pct > 1 then pct = 1 end
        self.fill:SetWidth(math.max(1, self:GetWidth() * pct))
        self.label:SetText(label or "")
        self.valueText:SetText(valueStr or tostring(current))
    end

    return bar
end

----------------------------------------------------------------------
-- Theme the dashboard elements
----------------------------------------------------------------------
function UI:ThemeDashboard()
    if not dashboardFrame then return end
    local t = Deadpool.modules.Theme.active
    for _, card in pairs(dashboardFrame.cards) do
        card:SetBackdropColor(t.bgAlt[1], t.bgAlt[2], t.bgAlt[3], t.bgAlt[4])
        card:SetBackdropBorderColor(t.border[1], t.border[2], t.border[3], 0.5)
    end
    for _, bar in pairs(dashboardFrame.bars) do
        bar:SetBackdropColor(t.barBg[1], t.barBg[2], t.barBg[3], t.barBg[4])
        bar.fill:SetVertexColor(t.barFill[1], t.barFill[2], t.barFill[3], t.barFill[4])
    end
end

----------------------------------------------------------------------
-- Render the dashboard
----------------------------------------------------------------------
function UI:RenderDashboard()
    if not dashboardFrame then return end
    local t = Deadpool.modules.Theme.active
    local TM = Deadpool.modules.Theme
    local myName = Deadpool:GetPlayerFullName()
    local score = Deadpool:GetOrCreateScore(myName)

    -- Initialize static elements once
    if not dashboardFrame.initialized then
        dashboardFrame.initialized = true

        -- Row 1: Stat cards
        local cw = 130
        local ch = 80
        local gap = 10
        dashboardFrame.cards.kills = self:CreateStatCard(dashboardFrame, 0, 0, cw, ch)
        dashboardFrame.cards.kills.title:SetText("TOTAL KILLS")
        dashboardFrame.cards.kos = self:CreateStatCard(dashboardFrame, cw + gap, 0, cw, ch)
        dashboardFrame.cards.kos.title:SetText("KOS LIST")
        dashboardFrame.cards.bounties = self:CreateStatCard(dashboardFrame, (cw + gap) * 2, 0, cw, ch)
        dashboardFrame.cards.bounties.title:SetText("BOUNTIES")
        dashboardFrame.cards.points = self:CreateStatCard(dashboardFrame, (cw + gap) * 3, 0, cw, ch)
        dashboardFrame.cards.points.title:SetText("YOUR POINTS")
        dashboardFrame.cards.rank = self:CreateStatCard(dashboardFrame, (cw + gap) * 4, 0, cw, ch)
        dashboardFrame.cards.rank.title:SetText("YOUR RANK")
        dashboardFrame.cards.enemies = self:CreateStatCard(dashboardFrame, (cw + gap) * 5, 0, cw, ch)
        dashboardFrame.cards.enemies.title:SetText("ENEMIES")

        -- Section: Top Killers (left column bars)
        local lblTop = dashboardFrame:CreateFontString(nil, "OVERLAY")
        lblTop:SetFont(TM:GetHeaderFont())
        lblTop:SetPoint("TOPLEFT", 0, -95)
        lblTop:SetTextColor(t.accent[1], t.accent[2], t.accent[3])
        lblTop:SetText("TOP KILLERS")
        dashboardFrame.labels.topKillers = lblTop

        for i = 1, 5 do
            dashboardFrame.bars["topKiller" .. i] = self:CreateStatBar(dashboardFrame, 115 + (i - 1) * 24, 380)
        end

        -- Section: Public Enemies (right column bars)
        local lblEn = dashboardFrame:CreateFontString(nil, "OVERLAY")
        lblEn:SetFont(TM:GetHeaderFont())
        lblEn:SetPoint("TOPLEFT", 420, -95)
        lblEn:SetTextColor(t.accent[1], t.accent[2], t.accent[3])
        lblEn:SetText("MOST WANTED ENEMIES")
        dashboardFrame.labels.publicEnemies = lblEn

        for i = 1, 5 do
            local bar = self:CreateStatBar(dashboardFrame, 115 + (i - 1) * 24, 380)
            bar:ClearAllPoints()
            bar:SetPoint("TOPLEFT", dashboardFrame, "TOPLEFT", 420, -(115 + (i - 1) * 24))
            dashboardFrame.bars["enemy" .. i] = bar
        end

        -- Section: Recent Activity
        local lblRecent = dashboardFrame:CreateFontString(nil, "OVERLAY")
        lblRecent:SetFont(TM:GetHeaderFont())
        lblRecent:SetPoint("TOPLEFT", 0, -250)
        lblRecent:SetTextColor(t.accent[1], t.accent[2], t.accent[3])
        lblRecent:SetText("RECENT KILLS")
        dashboardFrame.labels.recent = lblRecent

        dashboardFrame.recentLines = {}
        for i = 1, 8 do
            local line = dashboardFrame:CreateFontString(nil, "OVERLAY")
            line:SetFont(TM:GetBodyFont())
            line:SetPoint("TOPLEFT", 10, -(270 + (i - 1) * 18))
            line:SetWidth(780)
            line:SetJustifyH("LEFT")
            dashboardFrame.recentLines[i] = line
        end

        -- Section: Your Stats quick view
        local lblYou = dashboardFrame:CreateFontString(nil, "OVERLAY")
        lblYou:SetFont(TM:GetHeaderFont())
        lblYou:SetPoint("TOPLEFT", 0, -(250 + 8 * 18 + 15))
        lblYou:SetTextColor(t.accent[1], t.accent[2], t.accent[3])
        lblYou:SetText("YOUR SESSION")
        dashboardFrame.labels.session = lblYou

        dashboardFrame.sessionLines = {}
        for i = 1, 3 do
            local line = dashboardFrame:CreateFontString(nil, "OVERLAY")
            line:SetFont(TM:GetBodyFont())
            line:SetPoint("TOPLEFT", 10, -(250 + 8 * 18 + 35 + (i - 1) * 18))
            line:SetWidth(780)
            line:SetJustifyH("LEFT")
            dashboardFrame.sessionLines[i] = line
        end
    end

    -- UPDATE dynamic data
    local accentHex = TM:AccentHex()

    -- Stat cards
    local totalGuildKills = 0
    for _, sc in pairs(Deadpool.db.scoreboard) do
        totalGuildKills = totalGuildKills + (sc.totalKills or 0)
    end
    dashboardFrame.cards.kills.value:SetText(accentHex .. totalGuildKills .. "|r")
    dashboardFrame.cards.kills.title:SetTextColor(t.accent[1], t.accent[2], t.accent[3])
    dashboardFrame.cards.kills.subtitle:SetText("guild total")

    dashboardFrame.cards.kos.value:SetText(accentHex .. Deadpool:GetKOSCount() .. "|r")
    dashboardFrame.cards.kos.title:SetTextColor(t.accent[1], t.accent[2], t.accent[3])
    dashboardFrame.cards.kos.subtitle:SetText("targets")

    local activeBounties = #Deadpool:GetActiveBounties()
    dashboardFrame.cards.bounties.value:SetText(Deadpool.colors.gold .. activeBounties .. "|r")
    dashboardFrame.cards.bounties.title:SetTextColor(t.accent[1], t.accent[2], t.accent[3])
    dashboardFrame.cards.bounties.subtitle:SetText("active")

    dashboardFrame.cards.points.value:SetText(Deadpool.colors.yellow .. (score.totalPoints or 0) .. "|r")
    dashboardFrame.cards.points.title:SetTextColor(t.accent[1], t.accent[2], t.accent[3])
    dashboardFrame.cards.points.subtitle:SetText("points")

    local rank = Deadpool:GetPlayerRank(myName)
    dashboardFrame.cards.rank.value:SetText(Deadpool.colors.gold .. "#" .. rank .. "|r")
    dashboardFrame.cards.rank.title:SetTextColor(t.accent[1], t.accent[2], t.accent[3])
    dashboardFrame.cards.rank.subtitle:SetText("of " .. Deadpool:TableCount(Deadpool.db.scoreboard))

    dashboardFrame.cards.enemies.value:SetText(Deadpool.colors.red .. Deadpool:TableCount(Deadpool.db.enemySheet) .. "|r")
    dashboardFrame.cards.enemies.title:SetTextColor(t.accent[1], t.accent[2], t.accent[3])
    dashboardFrame.cards.enemies.subtitle:SetText("tracked")

    -- Top Killers bars
    local topPlayers = Deadpool:GetScoreboardSorted("totalKills")
    local maxKills = (topPlayers[1] and topPlayers[1].totalKills or 1)
    if maxKills == 0 then maxKills = 1 end
    for i = 1, 5 do
        local bar = dashboardFrame.bars["topKiller" .. i]
        if topPlayers[i] then
            local p = topPlayers[i]
            local name = Deadpool:ShortName(p._key)
            if p._key == myName then name = Deadpool.colors.cyan .. name .. "|r" end
            bar:SetProgress(p.totalKills, maxKills, "#" .. i .. "  " .. name, tostring(p.totalKills) .. " kills")
            bar:Show()
        else
            bar:Hide()
        end
    end

    -- Public Enemies bars
    local topEnemies = Deadpool:GetPublicEnemiesSorted("timesKilledUs")
    local maxEnemyKills = (topEnemies[1] and topEnemies[1].timesKilledUs or 1)
    if maxEnemyKills == 0 then maxEnemyKills = 1 end
    for i = 1, 5 do
        local bar = dashboardFrame.bars["enemy" .. i]
        if topEnemies[i] then
            local e = topEnemies[i]
            local name = e.class and Deadpool:ClassColor(e.class, Deadpool:ShortName(e._key)) or Deadpool:ShortName(e._key)
            local kosTag = Deadpool:IsKOS(e._key) and (Deadpool.colors.red .. " [KOS]|r") or ""
            bar:SetProgress(e.timesKilledUs, maxEnemyKills, "#" .. i .. "  " .. name .. kosTag, (e.timesKilledUs or 0) .. " kills on us")
            bar.fill:SetVertexColor(0.8, 0.15, 0.10, 1)  -- red for enemies
            bar:Show()
        else
            bar:Hide()
        end
    end

    -- Recent kills feed
    local recentKills = Deadpool:GetKillLog("all")
    for i = 1, 8 do
        local line = dashboardFrame.recentLines[i]
        if recentKills[i] then
            local k = recentKills[i]
            local killer = Deadpool:ShortName(k.killer)
            local victim = k.victimClass and Deadpool:ClassColor(k.victimClass, Deadpool:ShortName(k.victim)) or Deadpool:ShortName(k.victim)
            local typeTag = ""
            if k.isBounty then typeTag = Deadpool.colors.gold .. " [BOUNTY]|r"
            elseif k.isKOS then typeTag = Deadpool.colors.red .. " [KOS]|r" end
            local timeStr = Deadpool.colors.grey .. Deadpool:TimeAgo(k.time) .. "|r"
            line:SetText(timeStr .. "  " .. Deadpool.colors.green .. killer .. "|r killed " .. victim .. typeTag .. " in " .. Deadpool.colors.yellow .. (k.zone or "?") .. "|r")
            line:Show()
        else
            line:SetText("")
        end
    end

    -- Session stats
    local nemesis, nemesisCount = nil, 0
    local myDeaths = {}
    for _, d in ipairs(Deadpool.db.deathLog or {}) do
        if d.victim == myName then
            myDeaths[d.killer] = (myDeaths[d.killer] or 0) + 1
        end
    end
    for k, v in pairs(myDeaths) do
        if v > nemesisCount then nemesis = k; nemesisCount = v end
    end

    dashboardFrame.sessionLines[1]:SetText(
        "Kills: " .. accentHex .. (score.totalKills or 0) .. "|r" ..
        "     Streak: " .. Deadpool.colors.orange .. (score.bestStreak or 0) .. "|r" ..
        "     Deaths: " .. Deadpool.colors.red .. #(Deadpool.db.deathLog or {}) .. "|r")
    dashboardFrame.sessionLines[2]:SetText(
        "Nemesis: " .. (nemesis and (Deadpool.colors.red .. Deadpool:ShortName(nemesis) .. " (" .. nemesisCount .. "x)|r") or Deadpool.colors.grey .. "none|r"))
    dashboardFrame.sessionLines[3]:SetText(
        "Theme: " .. TM:AccentHex() .. TM:GetThemeName() .. "|r" ..
        (TM.isElvUI and ("  |  " .. Deadpool.colors.cyan .. "ElvUI integrated|r") or ""))

    statusText:SetText("Dashboard | " .. TM:GetThemeName() .. " theme" .. (TM.isElvUI and " | ElvUI" or ""))
end

----------------------------------------------------------------------
-- Minimap Button â€” standard Classic/TBC pattern
-- Matches the built-in tracking button exactly
----------------------------------------------------------------------
function UI:CreateMinimapButton()
    -- Destroy existing button if reloading to prevent duplicates
    if DeadpoolMinimapButton then
        DeadpoolMinimapButton:Hide()
        DeadpoolMinimapButton:SetParent(nil)
    end

    local btn = CreateFrame("Button", "DeadpoolMinimapButton", Minimap)
    btn:SetSize(33, 33)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    btn:SetMovable(true)
    btn:EnableMouse(true)

    -- Layer 1 (BACKGROUND): The icon texture, cropped to remove default border
    local icon = btn:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(21, 21)
    icon:SetPoint("TOPLEFT", 7, -5)
    icon:SetTexture("Interface\\Icons\\Ability_Creature_Cursed_03")
    icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
    btn.icon = icon

    -- Layer 2 (OVERLAY): The gold tracking border ring
    -- This texture is 54x54 with built-in offset padding in the top-left corner
    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetSize(54, 54)
    border:SetPoint("TOPLEFT", 0, 0)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    -- Highlight glow on hover
    btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    -- Position: orbit around minimap edge
    local function UpdatePosition(angle)
        local rads = math.rad(angle)
        btn:ClearAllPoints()
        btn:SetPoint("CENTER", Minimap, "CENTER", math.cos(rads) * 80, math.sin(rads) * 80)
    end

    C_Timer.After(0.5, function()
        local angle = 220
        if Deadpool.db and Deadpool.db.settings then
            angle = Deadpool.db.settings.minimapIcon.minimapPos or 220
        end
        UpdatePosition(angle)
    end)

    -- Drag to reposition
    btn:RegisterForDrag("LeftButton")
    btn:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local s = UIParent:GetEffectiveScale()
            local angle = math.deg(math.atan2(cy / s - my, cx / s - mx))
            UpdatePosition(angle)
            if Deadpool.db and Deadpool.db.settings then
                Deadpool.db.settings.minimapIcon.minimapPos = angle
            end
        end)
    end)
    btn:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)

    -- Clicks
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:SetScript("OnClick", function(self, button)
        if button == "LeftButton" then Deadpool:ToggleUI()
        elseif button == "RightButton" then Deadpool:RequestSync() end
    end)

    -- Tooltip
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("|cFFCC0000Deadpool|r")
        GameTooltip:AddLine("Left-click: Toggle window", 0.7, 0.7, 0.7)
        GameTooltip:AddLine("Right-click: Force guild sync", 0.7, 0.7, 0.7)
        GameTooltip:AddLine("Drag: Move button", 0.7, 0.7, 0.7)
        local kc = Deadpool:GetKOSCount()
        local bc = #Deadpool:GetActiveBounties()
        if kc > 0 then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(kc .. " KOS targets | " .. bc .. " active bounties", 0.9, 0.3, 0.3)
        end
        local ms = Deadpool.db.scoreboard[Deadpool:GetPlayerFullName()]
        if ms then
            GameTooltip:AddLine("Rank: #" .. Deadpool:GetPlayerRank(Deadpool:GetPlayerFullName()) .. " (" .. ms.totalPoints .. " pts)", 1, 1, 0)
        end
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    C_Timer.After(1, function()
        if Deadpool.db and Deadpool.db.settings.minimapIcon.hide then btn:Hide() end
    end)
end
