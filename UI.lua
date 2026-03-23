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
    titleBar:SetPoint("TOPLEFT", 2, -2)
    titleBar:SetPoint("TOPRIGHT", -2, -2)
    mainFrame.titleBar = titleBar

    local titleBg = titleBar:CreateTexture(nil, "BACKGROUND")
    titleBg:SetAllPoints()
    local t = Deadpool.modules.Theme.active
    titleBg:SetColorTexture(t.accent[1] * 0.3, t.accent[2] * 0.3, t.accent[3] * 0.3, 0.95)
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

    -- Bottom status bar (proper anchored panel)
    local bottomBar = CreateFrame("Frame", nil, mainFrame, "BackdropTemplate")
    bottomBar:SetHeight(26)
    bottomBar:SetPoint("BOTTOMLEFT", mainFrame, "BOTTOMLEFT", 2, 2)
    bottomBar:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -2, 2)
    bottomBar:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
    })
    local t = Deadpool.modules.Theme.active
    bottomBar:SetBackdropColor(t.headerBg[1], t.headerBg[2], t.headerBg[3], 0.95)
    mainFrame.bottomBar = bottomBar

    -- Status text (left side)
    statusText = bottomBar:CreateFontString(nil, "OVERLAY")
    statusText:SetFont(Deadpool.modules.Theme:GetFont(11, ""))
    statusText:SetPoint("LEFT", bottomBar, "LEFT", 10, 0)
    statusText:SetTextColor(t.textDim[1], t.textDim[2], t.textDim[3])

    -- Custom themed buttons (right side of bottom bar)
    local function CreateThemedButton(parent, width, text, onClick)
        local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
        btn:SetSize(width, 20)
        btn:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
        })
        btn:SetBackdropColor(t.accent[1] * 0.3, t.accent[2] * 0.3, t.accent[3] * 0.3, 0.9)
        btn:SetBackdropBorderColor(t.accent[1], t.accent[2], t.accent[3], 0.6)
        btn._label = btn:CreateFontString(nil, "OVERLAY")
        btn._label:SetFont(Deadpool.modules.Theme:GetFont(11, ""))
        btn._label:SetPoint("CENTER")
        btn._label:SetText(text)
        btn._label:SetTextColor(t.text[1], t.text[2], t.text[3])
        btn:SetScript("OnEnter", function(self)
            self:SetBackdropColor(t.accent[1] * 0.5, t.accent[2] * 0.5, t.accent[3] * 0.5, 1)
            self:SetBackdropBorderColor(t.accent[1], t.accent[2], t.accent[3], 1)
        end)
        btn:SetScript("OnLeave", function(self)
            self:SetBackdropColor(t.accent[1] * 0.3, t.accent[2] * 0.3, t.accent[3] * 0.3, 0.9)
            self:SetBackdropBorderColor(t.accent[1], t.accent[2], t.accent[3], 0.6)
        end)
        btn:SetScript("OnClick", onClick)
        return btn
    end

    local addBtn = CreateThemedButton(bottomBar, 90, "Add Target", function()
        if UnitExists("target") and UnitIsPlayer("target") and UnitIsEnemy("player", "target") then
            local fullName = Deadpool:GetUnitFullName("target")
            if fullName then Deadpool:AddToKOS(fullName, "") end
        else
            StaticPopup_Show("DEADPOOL_ADD_KOS")
        end
    end)
    addBtn:SetPoint("RIGHT", bottomBar, "RIGHT", -8, 0)
    mainFrame.addBtn = addBtn

    local syncBtn = CreateThemedButton(bottomBar, 55, "Sync", function()
        Deadpool:RequestSync()
    end)
    syncBtn:SetPoint("RIGHT", addBtn, "LEFT", -6, 0)
    mainFrame.syncBtn = syncBtn

    -- Popup dialogs
    StaticPopupDialogs["DEADPOOL_ADD_KOS"] = {
        text = "Enter player name to add to Kill on Sight:",
        button1 = "Add", button2 = "Cancel",
        hasEditBox = true, maxLetters = 64,
        OnAccept = function(self)
            local name = self.EditBox:GetText()
            if name and name ~= "" then Deadpool:AddToKOS(name, "") end
        end,
        EditBoxOnEnterPressed = function(self)
            local name = self:GetParent().EditBox:GetText()
            if name and name ~= "" then Deadpool:AddToKOS(name, "") end
            self:GetParent():Hide()
        end,
        timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
    }

    StaticPopupDialogs["DEADPOOL_PLACE_BOUNTY"] = {
        text = "Place bounty on %s\nEnter amount (gold or points):",
        button1 = "Gold Bounty", button2 = "Cancel", button3 = "Points Bounty",
        hasEditBox = true, maxLetters = 10,
        OnAccept = function(self, data)
            local val = tonumber(self.EditBox:GetText())
            if val and val > 0 and data then Deadpool:PlaceBounty(data, val, 10, "gold") end
        end,
        OnAlt = function(self, data)
            local val = tonumber(self.EditBox:GetText())
            if val and val > 0 and data then Deadpool:PlaceBounty(data, val, 10, "points") end
        end,
        EditBoxOnEnterPressed = function(self)
            local val = tonumber(self:GetParent().EditBox:GetText())
            local data = self:GetParent().data
            if val and val > 0 and data then Deadpool:PlaceBounty(data, val, 10, "gold") end
            self:GetParent():Hide()
        end,
        timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
    }

    StaticPopupDialogs["DEADPOOL_CONTRIBUTE_BOUNTY"] = {
        text = "Contribute to bounty on %s\nEnter amount:",
        button1 = "Add Gold", button2 = "Cancel", button3 = "Add Points",
        hasEditBox = true, maxLetters = 10,
        OnAccept = function(self, data)
            local val = tonumber(self.EditBox:GetText())
            if val and val > 0 and data then Deadpool:ContributeToBounty(data, val, "gold") end
        end,
        OnAlt = function(self, data)
            local val = tonumber(self.EditBox:GetText())
            if val and val > 0 and data then Deadpool:ContributeToBounty(data, val, "points") end
        end,
        EditBoxOnEnterPressed = function(self)
            local val = tonumber(self:GetParent().EditBox:GetText())
            local data = self:GetParent().data
            if val and val > 0 and data then Deadpool:ContributeToBounty(data, val, "gold") end
            self:GetParent():Hide()
        end,
        timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
    }

    StaticPopupDialogs["DEADPOOL_EDIT_BOUNTY_KILLS"] = {
        text = "Edit max kills for bounty on %s\nEnter new kill target:",
        button1 = "Save", button2 = "Cancel",
        hasEditBox = true, maxLetters = 6,
        OnAccept = function(self, data)
            local val = tonumber(self.EditBox:GetText())
            if val and val >= 1 and data then Deadpool:EditBountyKills(data, val) end
        end,
        EditBoxOnEnterPressed = function(self)
            local val = tonumber(self:GetParent().EditBox:GetText())
            local data = self:GetParent().data
            if val and val >= 1 and data then Deadpool:EditBountyKills(data, val) end
            self:GetParent():Hide()
        end,
        OnShow = function(self, data)
            local bounty = data and Deadpool.db.bounties[data]
            if bounty then self.EditBox:SetText(tostring(bounty.maxKills or 10)) end
        end,
        timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
    }

    StaticPopupDialogs["DEADPOOL_WIPE_SCOREBOARD"] = {
        text = "RESET SCOREBOARD?\n\nThis will wipe all guild member scores and points.\nThis cannot be undone.",
        button1 = "Reset", button2 = "Cancel",
        OnAccept = function()
            if not Deadpool:IsGM() then return end
            Deadpool.db.scoreboard = {}
            Deadpool:BumpSyncVersion()
            Deadpool:Print(Deadpool.colors.red .. "Scoreboard has been reset.|r")
            if Deadpool.RefreshUI then Deadpool:RefreshUI() end
        end,
        timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
    }

    StaticPopupDialogs["DEADPOOL_WIPE_KILLLOG"] = {
        text = "RESET KILL LOG?\n\nThis will wipe all recorded kills.\nThis cannot be undone.",
        button1 = "Reset", button2 = "Cancel",
        OnAccept = function()
            if not Deadpool:IsGM() then return end
            Deadpool.db.killLog = {}
            Deadpool.db.deathLog = {}
            Deadpool:BumpSyncVersion()
            Deadpool:Print(Deadpool.colors.red .. "Kill log and death log have been reset.|r")
            if Deadpool.RefreshUI then Deadpool:RefreshUI() end
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
    local totalWidth = FRAME_WIDTH - 2  -- 1px padding each side
    local gap = 1
    local totalGaps = (#TABS - 1) * gap
    local tabWidth = math.floor((totalWidth - totalGaps) / #TABS)
    for _, tabDef in ipairs(TABS) do
        local btn = tabButtons[tabDef.key]
        local i = btn._index
        btn:ClearAllPoints()
        btn:SetSize(tabWidth, TAB_HEIGHT)
        btn:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 1 + (i - 1) * (tabWidth + gap), -26)
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

    -- Reset scroll on tab switch
    scrollOffset = 0
    if contentArea and contentArea.scrollBar then
        contentArea.scrollBar:SetValue(0)
    end

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
local filterBar  -- stored so we can show/hide per tab
function UI:CreateFilterBar()
    filterBar = CreateFrame("Frame", nil, mainFrame)
    filterBar:SetSize(FRAME_WIDTH - 20, 24)
    filterBar:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 10, -56)

    filterBox = CreateFrame("EditBox", "DeadpoolFilterBox", filterBar, "InputBoxTemplate")
    filterBox:SetSize(240, 20)
    filterBox:SetPoint("LEFT", filterBar, "LEFT", 4, 0)
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

    -- "Show Mine" toggle button
    local mineBtn = CreateFrame("Button", nil, filterBar)
    mineBtn:SetSize(80, 20)
    mineBtn:SetPoint("LEFT", filterBox, "RIGHT", 10, 0)
    local TM = Deadpool.modules.Theme
    local t = TM.active

    mineBtn.text = mineBtn:CreateFontString(nil, "OVERLAY")
    mineBtn.text:SetFont(TM:GetFont(11, ""))
    mineBtn.text:SetPoint("CENTER")
    mineBtn.text:SetText("Show Mine")
    mineBtn.text:SetTextColor(t.textDim[1], t.textDim[2], t.textDim[3])

    mineBtn:SetScript("OnClick", function()
        UI.showMineOnly = not UI.showMineOnly
        if UI.showMineOnly then
            mineBtn.text:SetTextColor(t.accent[1], t.accent[2], t.accent[3])
            mineBtn.text:SetText("Mine Only")
        else
            mineBtn.text:SetTextColor(t.textDim[1], t.textDim[2], t.textDim[3])
            mineBtn.text:SetText("Show Mine")
        end
        scrollOffset = 0
        UI:RefreshContent()
    end)
    UI.showMineOnly = false
    filterBar._mineBtn = mineBtn
end

----------------------------------------------------------------------
-- Content area with proper scroll bar
----------------------------------------------------------------------
local scrollOffset = 0
local scrollMaxOffset = 0

function UI:CreateContentArea()
    contentArea = CreateFrame("Frame", nil, mainFrame)
    contentArea:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 10, -80)
    contentArea:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -10, 32)

    -- Column headers
    contentArea.headerFrame = CreateFrame("Frame", nil, contentArea)
    contentArea.headerFrame:SetHeight(HEADER_HEIGHT)
    contentArea.headerFrame:SetPoint("TOPLEFT", contentArea, "TOPLEFT", 0, 0)
    contentArea.headerFrame:SetPoint("TOPRIGHT", contentArea, "TOPRIGHT", -16, 0)
    local hdrBg = contentArea.headerFrame:CreateTexture(nil, "BACKGROUND")
    hdrBg:SetAllPoints()
    hdrBg:SetColorTexture(0.1, 0.1, 0.1, 0.8)

    -- Row container (between header and bottom, with space for scrollbar)
    local rowContainer = CreateFrame("Frame", nil, contentArea)
    rowContainer:SetPoint("TOPLEFT", contentArea.headerFrame, "BOTTOMLEFT", 0, -1)
    rowContainer:SetPoint("BOTTOMRIGHT", contentArea, "BOTTOMRIGHT", -16, 0)
    rowContainer:SetClipsChildren(true)  -- CLIP rows that extend past bounds
    contentArea.rowContainer = rowContainer

    -- Scroll bar (Slider on the right edge)
    local scrollBar = CreateFrame("Slider", nil, contentArea, "BackdropTemplate")
    scrollBar:SetWidth(14)
    scrollBar:SetPoint("TOPRIGHT", contentArea, "TOPRIGHT", 0, -HEADER_HEIGHT - 1)
    scrollBar:SetPoint("BOTTOMRIGHT", contentArea, "BOTTOMRIGHT", 0, 0)
    scrollBar:SetOrientation("VERTICAL")
    scrollBar:SetMinMaxValues(0, 1)
    scrollBar:SetValue(0)
    scrollBar:SetValueStep(1)
    scrollBar:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    local t = Deadpool.modules.Theme.active
    scrollBar:SetBackdropColor(t.bg[1], t.bg[2], t.bg[3], 0.5)
    scrollBar:SetBackdropBorderColor(t.border[1], t.border[2], t.border[3], 0.3)

    -- Scroll bar thumb
    local thumb = scrollBar:CreateTexture(nil, "OVERLAY")
    thumb:SetSize(12, 40)
    thumb:SetColorTexture(t.accent[1], t.accent[2], t.accent[3], 0.6)
    scrollBar:SetThumbTexture(thumb)

    scrollBar:SetScript("OnValueChanged", function(self, value)
        scrollOffset = math.floor(value + 0.5)
        UI:RenderCurrentTab()
    end)

    -- Mouse wheel on row container
    rowContainer:EnableMouseWheel(true)
    rowContainer:SetScript("OnMouseWheel", function(self, delta)
        scrollOffset = scrollOffset - delta
        if scrollOffset < 0 then scrollOffset = 0 end
        if scrollOffset > scrollMaxOffset then scrollOffset = scrollMaxOffset end
        scrollBar:SetValue(scrollOffset)
    end)

    contentArea.scrollBar = scrollBar
    contentArea.rows = {}

    -- Create row pool
    local visibleRows = math.floor((FRAME_HEIGHT - 146) / ROW_HEIGHT) + 1
    for i = 1, visibleRows do
        contentArea.rows[i] = self:CreateRow(rowContainer, i)
    end

    -- Create dashboard frame
    self:CreateDashboardFrame()
end

----------------------------------------------------------------------
-- Row template
----------------------------------------------------------------------
function UI:CreateRow(parent, index)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(FRAME_WIDTH - 50, ROW_HEIGHT)
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

    -- Mouse wheel propagation to scrollbar
    row:EnableMouseWheel(true)
    row:SetScript("OnMouseWheel", function(_, delta)
        scrollOffset = scrollOffset - delta
        if scrollOffset < 0 then scrollOffset = 0 end
        if scrollOffset > scrollMaxOffset then scrollOffset = scrollMaxOffset end
        if contentArea.scrollBar then contentArea.scrollBar:SetValue(scrollOffset) end
    end)

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
            table.insert(menuList, { text = "Add Gold / Points", notCheckable = true, func = function()
                local d = StaticPopup_Show("DEADPOOL_CONTRIBUTE_BOUNTY", Deadpool:ShortName(fullName))
                if d then d.data = fullName end
            end })
            local myName = Deadpool:GetPlayerFullName()
            if data.placedBy == myName or Deadpool:IsManager() then
                table.insert(menuList, { text = "Edit Max Kills", notCheckable = true, func = function()
                    local d = StaticPopup_Show("DEADPOOL_EDIT_BOUNTY_KILLS", Deadpool:ShortName(fullName))
                    if d then d.data = fullName end
                end })
            end
            table.insert(menuList, { text = "Expire Bounty", notCheckable = true, func = function()
                local b = Deadpool.db.bounties[fullName]
                if b then
                    local placerOrManager = b.placedBy == Deadpool:GetPlayerFullName() or Deadpool:IsManager()
                    if placerOrManager then
                        b.expired = true
                        b.expiredReason = "Manually expired"
                        Deadpool:BumpSyncVersion()
                        Deadpool:RefreshUI()
                    else
                        Deadpool:Print(Deadpool.colors.red .. "Only the placer or a manager can expire this bounty.|r")
                    end
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

    -- TBC Classic doesn't have EasyMenu — use UIDropDownMenu_Initialize
    UIDropDownMenu_Initialize(ctxMenu, function(self, level)
        for _, item in ipairs(menuList) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = item.text
            info.isTitle = item.isTitle
            info.notCheckable = item.notCheckable ~= false
            info.func = item.func
            UIDropDownMenu_AddButton(info, level or 1)
        end
    end, "MENU")
    ToggleDropDownMenu(1, nil, ctxMenu, "cursor", 0, 0)
end

----------------------------------------------------------------------
-- Refresh dispatcher
----------------------------------------------------------------------
function UI:RefreshContent()
    if not contentArea then return end
    self:LayoutTabs()

    if activeTab == "dashboard" or activeTab == "settings" then
        if filterBar then filterBar:Hide() end
        return
    end

    if dashboardFrame then dashboardFrame:Hide() end
    if UI.settingsPanel then UI.settingsPanel:Hide() end

    -- Filter bar: show only on filterable tabs, reposition content accordingly
    local showFilter = (activeTab == "kos" or activeTab == "bounties" or activeTab == "enemies"
        or activeTab == "killlog")
    -- Show Mine button: only on tabs where it makes sense
    local showMine = (activeTab == "bounties" or activeTab == "killlog")
    if filterBar then
        if showFilter then
            filterBar:Show()
            -- Show/hide the Show Mine button within the filter bar
            if filterBar._mineBtn then
                if showMine then
                    filterBar._mineBtn:Show()
                else
                    filterBar._mineBtn:Hide()
                end
            end
        else
            filterBar:Hide()
        end
    end
    if contentArea then
        contentArea:ClearAllPoints()
        if showFilter then
            contentArea:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 10, -80)
        else
            contentArea:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 10, -56)
        end
        contentArea:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -10, 32)
    end

    contentArea:Show()

    self:RenderCurrentTab()
end

-- Render without resetting scroll (called by scrollbar and mouse wheel)
function UI:RenderCurrentTab()
    if not contentArea then return end

    -- Reset row click handlers
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

    -- Update scrollbar range
    if contentArea.scrollBar then
        contentArea.scrollBar:SetMinMaxValues(0, math.max(0, scrollMaxOffset))
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
        { text = "Our Kills", x = 270, w = 60 },
        { text = "Their Kills", x = 332, w = 65 },
        { text = "Last Seen", x = 399, w = 140 },
        { text = "Bounty",    x = 541, w = 65 },
        { text = "Reason",    x = 608, w = 305 }
    )
    local data = Deadpool:GetKOSSorted("totalKills", false)
    local myName = Deadpool:GetPlayerFullName()
    if UI.showMineOnly then
        local f = {}
        for _, e in ipairs(data) do
            if e.addedBy == myName or e.lastKilledBy == myName then table.insert(f, e) end
        end
        data = f
    end
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
    scrollMaxOffset = math.max(0, numRows - visibleRows)
    if scrollOffset > scrollMaxOffset then scrollOffset = scrollMaxOffset end
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
            SetCol(row, 4, 270, 60, Deadpool.colors.green .. tostring(e.totalKills or 0) .. "|r")
            -- Their kills on us from enemy sheet
            local enemy = Deadpool.demoData:GetMergedEnemySheet()[e._key]
            local theirKills = enemy and enemy.timesKilledUs or 0
            local theirColor = theirKills > 0 and Deadpool.colors.red or Deadpool.colors.grey
            SetCol(row, 5, 332, 65, theirColor .. tostring(theirKills) .. "|r")
            local seenText = e.lastSeenZone and (e.lastSeenZone .. " " .. Deadpool:TimeAgo(e.lastSeenTime)) or "-"
            SetCol(row, 6, 399, 140, seenText)
            local bText = ""
            if Deadpool:HasActiveBounty(e._key) then
                local b = Deadpool:GetBounty(e._key)
                if (b.bountyPoints or 0) > 0 and (b.bountyGold or 0) > 0 then
                    bText = Deadpool.colors.gold .. (b.bountyGold or 0) .. "g|r+" .. Deadpool.colors.yellow .. (b.bountyPoints or 0) .. "p|r"
                elseif (b.bountyPoints or 0) > 0 then
                    bText = Deadpool.colors.yellow .. (b.bountyPoints or 0) .. "pts|r"
                else
                    bText = Deadpool.colors.gold .. (b.bountyGold or 0) .. "g|r"
                end
            end
            SetCol(row, 7, 541, 65, bText)
            SetCol(row, 8, 608, 305, Deadpool.colors.grey .. (e.reason or "") .. "|r")
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
    scrollMaxOffset = math.max(0, numRows - visibleRows)
    if scrollOffset > scrollMaxOffset then scrollOffset = scrollMaxOffset end
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
            local reward
            if (e.bountyType == "points" or (e.bountyPoints or 0) > 0) and (e.bountyGold or 0) == 0 then
                reward = Deadpool.colors.yellow .. (e.bountyPoints or 0) .. " pts|r"
            elseif (e.bountyPoints or 0) > 0 then
                reward = Deadpool.colors.gold .. (e.bountyGold or 0) .. "g|r" .. " + " .. Deadpool.colors.yellow .. (e.bountyPoints or 0) .. " pts|r"
            else
                reward = Deadpool.colors.gold .. (e.bountyGold or 0) .. "g|r"
            end
            SetCol(row, 2, 186, 110, reward)
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
                local tipReward = ""
                if (e.bountyGold or 0) > 0 then tipReward = Deadpool:FormatGold(e.bountyGold) end
                if (e.bountyPoints or 0) > 0 then
                    tipReward = tipReward .. (tipReward ~= "" and " + " or "") .. (e.bountyPoints or 0) .. " pts"
                end
                GameTooltip:AddLine(tipReward .. " for " .. (e.maxKills or 10) .. " kills", 0.7, 0.7, 0.7)
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
    scrollMaxOffset = math.max(0, numRows - visibleRows)
    if scrollOffset > scrollMaxOffset then scrollOffset = scrollMaxOffset end
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
    statusText:SetText(Deadpool:TableCount(Deadpool.demoData:GetMergedEnemySheet()) .. " enemy players tracked")
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
    scrollMaxOffset = math.max(0, numRows - visibleRows)
    if scrollOffset > scrollMaxOffset then scrollOffset = scrollMaxOffset end
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
    statusText:SetText(Deadpool:TableCount(Deadpool.demoData:GetMergedScoreboard()) .. " guild members ranked")
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
    table.insert(lines, { label = "Total Deaths", value = Deadpool.colors.red .. #(Deadpool.demoData:GetMergedDeathLog()) .. "|r" })
    local nemesis, nemesisCount = nil, 0
    local myDeaths = {}
    for _, d in ipairs(Deadpool.demoData:GetMergedDeathLog()) do
        if d.victim == myName then myDeaths[d.killer] = (myDeaths[d.killer] or 0) + 1 end
    end
    for k, v in pairs(myDeaths) do if v > nemesisCount then nemesis = k; nemesisCount = v end end
    if nemesis then
        table.insert(lines, { label = "Personal Nemesis", value = Deadpool.colors.red .. Deadpool:ShortName(nemesis) .. " (" .. nemesisCount .. "x)|r" })
    end
    local favTarget, favCount = nil, 0
    local myKills = {}
    for _, k in ipairs(Deadpool.demoData:GetMergedKillLog()) do
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
    table.insert(lines, { label = "Kills Logged", value = tostring(#(Deadpool.demoData:GetMergedKillLog())) })
    table.insert(lines, { label = "Enemies Tracked", value = tostring(Deadpool:TableCount(Deadpool.demoData:GetMergedEnemySheet())) })

    local numRows = #lines
    local visibleRows = #contentArea.rows
    scrollMaxOffset = math.max(0, numRows - visibleRows)
    if scrollOffset > scrollMaxOffset then scrollOffset = scrollMaxOffset end
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
    local myName = Deadpool:GetPlayerFullName()
    -- Show Mine filter
    if UI.showMineOnly then
        local f = {}
        for _, e in ipairs(data) do
            if e.killer == myName then table.insert(f, e) end
        end
        data = f
    end
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
    scrollMaxOffset = math.max(0, numRows - visibleRows)
    if scrollOffset > scrollMaxOffset then scrollOffset = scrollMaxOffset end
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
    -- Always rebuild to pick up current GM status
    if UI.settingsPanel then
        UI.settingsPanel:Hide()
        UI.settingsPanel:SetParent(nil)
        UI.settingsPanel = nil
    end
    self:BuildSettingsPanel()
    UI.settingsPanel:Show()
    self:UpdateSettingsValues()
end

function UI:BuildSettingsPanel()
    UI.settingsBuilt = true
    local TM = Deadpool.modules.Theme
    local t = TM.active

    -- Outer container (clips content)
    UI.settingsPanel = CreateFrame("Frame", nil, mainFrame)
    UI.settingsPanel:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 20, -82)
    UI.settingsPanel:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -20, 30)
    UI.settingsPanel:Hide()

    -- ScrollFrame for settings content
    local scrollFrame = CreateFrame("ScrollFrame", nil, UI.settingsPanel)
    scrollFrame:SetPoint("TOPLEFT", 0, 0)
    scrollFrame:SetPoint("BOTTOMRIGHT", -12, 0)  -- leave room for scrollbar
    scrollFrame:EnableMouseWheel(true)
    scrollFrame:SetScript("OnMouseWheel", function(self, delta)
        local current = self:GetVerticalScroll()
        local maxScroll = math.max(0, (self:GetScrollChild():GetHeight() or 0) - self:GetHeight())
        local newScroll = math.max(0, math.min(maxScroll, current - (delta * 30)))
        self:SetVerticalScroll(newScroll)
        if UI.settingsPanel._scrollBar then
            UI.settingsPanel._scrollBar:SetValue(newScroll)
        end
    end)
    UI.settingsPanel._scrollFrame = scrollFrame

    -- Scroll bar
    local scrollBar = CreateFrame("Slider", nil, UI.settingsPanel, "BackdropTemplate")
    scrollBar:SetWidth(8)
    scrollBar:SetPoint("TOPRIGHT", UI.settingsPanel, "TOPRIGHT", 0, -2)
    scrollBar:SetPoint("BOTTOMRIGHT", UI.settingsPanel, "BOTTOMRIGHT", 0, 2)
    scrollBar:SetOrientation("VERTICAL")
    scrollBar:SetMinMaxValues(0, 1)
    scrollBar:SetValue(0)
    scrollBar:SetValueStep(1)
    scrollBar:SetBackdrop({bgFile = "Interface\\Buttons\\WHITE8x8"})
    scrollBar:SetBackdropColor(t.bg[1], t.bg[2], t.bg[3], 0.3)
    local thumb = scrollBar:CreateTexture(nil, "OVERLAY")
    thumb:SetColorTexture(t.accent[1], t.accent[2], t.accent[3], 0.5)
    thumb:SetSize(8, 40)
    scrollBar:SetThumbTexture(thumb)
    scrollBar:SetScript("OnValueChanged", function(self, value)
        scrollFrame:SetVerticalScroll(value)
    end)
    scrollBar:EnableMouseWheel(true)
    scrollBar:SetScript("OnMouseWheel", function(self, delta)
        local current = scrollFrame:GetVerticalScroll()
        local maxScroll = math.max(0, (scrollFrame:GetScrollChild():GetHeight() or 0) - scrollFrame:GetHeight())
        local newScroll = math.max(0, math.min(maxScroll, current - (delta * 30)))
        scrollFrame:SetVerticalScroll(newScroll)
        self:SetValue(newScroll)
    end)
    UI.settingsPanel._scrollBar = scrollBar

    -- Scrollable content child
    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetWidth((UI.settingsPanel:GetWidth() or 900) - 14)
    content:SetHeight(800)  -- will be resized at the end
    scrollFrame:SetScrollChild(content)

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

    -- UI SCALE (opens popup so slider doesn't fight with the scaling frame)
    Header("UI SCALE", 0, ly); ly = ly - 24
    local scaleBtn = CreateFrame("Button", nil, content, "BackdropTemplate")
    scaleBtn:SetSize(220, 22)
    scaleBtn:SetPoint("TOPLEFT", content, "TOPLEFT", 10, ly)
    scaleBtn:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    scaleBtn:SetBackdropColor(t.accent[1] * 0.3, t.accent[2] * 0.3, t.accent[3] * 0.3, 0.9)
    scaleBtn:SetBackdropBorderColor(t.accent[1], t.accent[2], t.accent[3], 0.6)
    scaleBtn._label = scaleBtn:CreateFontString(nil, "OVERLAY")
    scaleBtn._label:SetFont(TM:GetFont(11, ""))
    scaleBtn._label:SetPoint("CENTER")
    scaleBtn._label:SetText("Scale: " .. math.floor((Deadpool.db.settings.uiScale or 1.0) * 100) .. "%  (click to adjust)")
    scaleBtn._label:SetTextColor(t.text[1], t.text[2], t.text[3])
    scaleBtn:SetScript("OnClick", function() UI:ShowScalePopup() end)
    UI.settingsPanel._scaleBtn = scaleBtn
    ly = ly - 30

    -- NOTIFICATIONS
    Header("NOTIFICATIONS", 0, ly); ly = ly - 24
    Check("Announce kills in chat", "announceKills", 0, ly); ly = ly - 26
    Check("KOS sighting alerts", "announceKOSSighted", 0, ly); ly = ly - 26
    Check("Alert sound on KOS spotted", "alertSound", 0, ly); ly = ly - 26
    Check("Broadcast sightings to guild", "broadcastSightings", 0, ly); ly = ly - 34

    -- ALERTS
    Header("ALERT FRAME", 0, ly); ly = ly - 24
    Check("Show on-screen alerts", "showAlertFrame", 0, ly); ly = ly - 26

    -- Position alert button (toggle unlock/lock)
    local alertPosBtn = CreateFrame("Button", nil, content, "BackdropTemplate")
    alertPosBtn:SetSize(150, 20)
    alertPosBtn:SetPoint("TOPLEFT", content, "TOPLEFT", 10, ly)
    alertPosBtn:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8x8",edgeFile="Interface\\Buttons\\WHITE8x8",edgeSize=1})
    alertPosBtn:SetBackdropColor(t.accent[1]*0.3, t.accent[2]*0.3, t.accent[3]*0.3, 0.9)
    alertPosBtn:SetBackdropBorderColor(t.accent[1], t.accent[2], t.accent[3], 0.6)
    local alertPosLbl = alertPosBtn:CreateFontString(nil, "OVERLAY")
    alertPosLbl:SetFont(TM:GetFont(10, "")); alertPosLbl:SetPoint("CENTER")
    alertPosLbl:SetTextColor(t.text[1], t.text[2], t.text[3])

    local alertsMod = Deadpool.modules.Alerts
    local isUnlocked = alertsMod and alertsMod._unlocked
    alertPosLbl:SetText(isUnlocked and "Lock Position" or "Unlock Position")
    alertPosBtn:SetScript("OnClick", function()
        if not alertsMod then return end
        if alertsMod._unlocked then
            alertsMod:LockPosition()
            alertsMod._unlocked = false
            alertPosLbl:SetText("Unlock Position")
        else
            alertsMod:UnlockPosition()
            alertsMod._unlocked = true
            alertPosLbl:SetText("Lock Position")
        end
    end)
    ly = ly - 34

    -- KILL SOUNDS
    Header("KILL SOUNDS", 0, ly); ly = ly - 24
    Check("Play sound on killing blow", "killSoundEnabled", 0, ly); ly = ly - 26
    Check("Streak announcer sounds", "streakSoundsEnabled", 0, ly); ly = ly - 28

    -- Sound rows: clean table layout (label | dropdown | play button)
    local ddCounter = 0
    local COL_LABEL = 10     -- label starts here
    local COL_DD    = 110    -- dropdown starts here
    local COL_PLAY  = 290    -- play button starts here
    local DD_W      = 170    -- dropdown width

    local function SoundRow(label, settingsKey, y)
        ddCounter = ddCounter + 1

        -- Label column
        local lbl = content:CreateFontString(nil, "OVERLAY")
        lbl:SetFont(TM:GetFont(11, ""))
        lbl:SetPoint("TOPLEFT", content, "TOPLEFT", COL_LABEL, y)
        lbl:SetText(label)
        lbl:SetTextColor(t.text[1], t.text[2], t.text[3])

        -- Value button (acts as dropdown trigger)
        local valBtn = CreateFrame("Button", nil, content, "BackdropTemplate")
        valBtn:SetSize(DD_W, 20)
        valBtn:SetPoint("TOPLEFT", content, "TOPLEFT", COL_DD, y + 2)
        valBtn:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8x8",edgeFile="Interface\\Buttons\\WHITE8x8",edgeSize=1})
        valBtn:SetBackdropColor(t.bgAlt[1], t.bgAlt[2], t.bgAlt[3], t.bgAlt[4] or 0.8)
        valBtn:SetBackdropBorderColor(t.border[1], t.border[2], t.border[3], t.border[4] or 0.5)

        local valText = valBtn:CreateFontString(nil, "OVERLAY")
        valText:SetFont(TM:GetFont(11, ""))
        valText:SetPoint("LEFT", 8, 0)
        valText:SetText(Deadpool:GetKillSoundName(Deadpool.db.settings[settingsKey] or "none"))
        valText:SetTextColor(t.tabTextActive[1], t.tabTextActive[2], t.tabTextActive[3])

        local arrow = valBtn:CreateFontString(nil, "OVERLAY")
        arrow:SetFont(TM:GetFont(10, ""))
        arrow:SetPoint("RIGHT", -6, 0)
        arrow:SetText("v")
        arrow:SetTextColor(t.textDim[1], t.textDim[2], t.textDim[3])

        -- Dropdown menu (hidden, shown on click)
        local ddName = "DeadpoolSoundDD" .. ddCounter
        if _G[ddName] then _G[ddName]:Hide(); _G[ddName]:SetParent(nil) end
        local ddMenu = CreateFrame("Frame", ddName, UIParent, "UIDropDownMenuTemplate")
        UIDropDownMenu_Initialize(ddMenu, function(self, level)
            for _, key in ipairs(Deadpool:GetKillSoundOptions()) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = Deadpool:GetKillSoundName(key)
                info.value = key
                info.checked = (Deadpool.db.settings[settingsKey] == key)
                info.func = function(btn)
                    Deadpool.db.settings[settingsKey] = btn.value
                    valText:SetText(Deadpool:GetKillSoundName(btn.value))
                end
                UIDropDownMenu_AddButton(info, level)
            end
        end, "MENU")

        valBtn:SetScript("OnClick", function(self)
            ToggleDropDownMenu(1, nil, ddMenu, self, 0, 0)
        end)
        valBtn:SetScript("OnEnter", function(self)
            self:SetBackdropBorderColor(t.accent[1], t.accent[2], t.accent[3], 0.8)
        end)
        valBtn:SetScript("OnLeave", function(self)
            self:SetBackdropBorderColor(t.border[1], t.border[2], t.border[3], t.border[4] or 0.5)
        end)

        -- Play button column
        local playBtn = CreateFrame("Button", nil, content, "BackdropTemplate")
        playBtn:SetSize(22, 20)
        playBtn:SetPoint("TOPLEFT", content, "TOPLEFT", COL_PLAY, y + 2)
        playBtn:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8x8",edgeFile="Interface\\Buttons\\WHITE8x8",edgeSize=1})
        playBtn:SetBackdropColor(t.accent[1]*0.2, t.accent[2]*0.2, t.accent[3]*0.2, 0.8)
        playBtn:SetBackdropBorderColor(t.border[1], t.border[2], t.border[3], 0.5)
        local playIcon = playBtn:CreateFontString(nil, "OVERLAY")
        playIcon:SetFont(TM:GetFont(12, "OUTLINE"))
        playIcon:SetPoint("CENTER", 1, 0)
        playIcon:SetText("|cFFFFFFFF>|r")
        playBtn:SetScript("OnClick", function()
            Deadpool:PlaySoundByKey(Deadpool.db.settings[settingsKey])
        end)
        playBtn:SetScript("OnEnter", function(self)
            self:SetBackdropColor(t.accent[1]*0.4, t.accent[2]*0.4, t.accent[3]*0.4, 1)
            self:SetBackdropBorderColor(t.accent[1], t.accent[2], t.accent[3], 1)
        end)
        playBtn:SetScript("OnLeave", function(self)
            self:SetBackdropColor(t.accent[1]*0.2, t.accent[2]*0.2, t.accent[3]*0.2, 0.8)
            self:SetBackdropBorderColor(t.border[1], t.border[2], t.border[3], 0.5)
        end)
    end

    SoundRow("Kill Sound", "killSound", ly); ly = ly - 26
    SoundRow("Death", "deathSound", ly); ly = ly - 26
    SoundRow("Party Death", "partyDeathSound", ly); ly = ly - 26
    SoundRow("Party Attack", "partyAttackSound", ly); ly = ly - 26
    SoundRow("KOS Alert", "kosAlertSound", ly); ly = ly - 30

    -- Custom sound: add from Sounds folder
    local csHeader = content:CreateFontString(nil, "OVERLAY")
    csHeader:SetFont(TM:GetFont(10, ""))
    csHeader:SetPoint("TOPLEFT", content, "TOPLEFT", 10, ly)
    csHeader:SetText("Add custom: drop file in Deadpool/Sounds/ then type filename below")
    csHeader:SetTextColor(t.textDim[1], t.textDim[2], t.textDim[3])
    ly = ly - 18

    local csEdit = CreateFrame("EditBox", nil, content, "InputBoxTemplate")
    csEdit:SetSize(200, 18)
    csEdit:SetPoint("TOPLEFT", content, "TOPLEFT", 10, ly)
    csEdit:SetAutoFocus(false)
    csEdit:SetMaxLetters(64)

    local csAddBtn = CreateFrame("Button", nil, content, "BackdropTemplate")
    csAddBtn:SetSize(60, 18)
    csAddBtn:SetPoint("LEFT", csEdit, "RIGHT", 6, 0)
    csAddBtn:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8x8",edgeFile="Interface\\Buttons\\WHITE8x8",edgeSize=1})
    csAddBtn:SetBackdropColor(t.accent[1]*0.3, t.accent[2]*0.3, t.accent[3]*0.3, 0.9)
    csAddBtn:SetBackdropBorderColor(t.accent[1], t.accent[2], t.accent[3], 0.6)
    local csAddLbl = csAddBtn:CreateFontString(nil, "OVERLAY")
    csAddLbl:SetFont(TM:GetFont(10, "")); csAddLbl:SetPoint("CENTER"); csAddLbl:SetText("Add")
    csAddLbl:SetTextColor(t.text[1], t.text[2], t.text[3])
    csAddBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(t.accent[1]*0.5, t.accent[2]*0.5, t.accent[3]*0.5, 1)
    end)
    csAddBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(t.accent[1]*0.3, t.accent[2]*0.3, t.accent[3]*0.3, 0.9)
    end)
    csAddBtn:SetScript("OnClick", function()
        local filename = csEdit:GetText()
        if filename and filename ~= "" then
            filename = filename:match("([^\\]+)$") or filename
            local displayName = filename:match("(.+)%..+$") or filename
            local key = Deadpool:AddCustomSound(displayName, filename)
            Deadpool.db.settings.killSound = key
            csEdit:SetText("")
            Deadpool:Print(Deadpool.colors.green .. "Custom sound added:|r " .. displayName)
            Deadpool:PreviewKillSound(key)
            UI:ShowSettingsPanel()
        end
    end)
    ly = ly - 26

    -- DEMO DATA
    Header("DEMO DATA", 0, ly); ly = ly - 24
    Check("Show demo data (sample entries)", "showDemoData", 0, ly); ly = ly - 26

    -- ========================
    -- RIGHT COLUMN
    -- ========================
    local ry = -10

    -- AUTO-KOS
    Header("AUTO-KOS", COL2, ry); ry = ry - 24
    Check("Auto-KOS players who kill you", "autoKOSOnAttack", COL2, ry); ry = ry - 34

    -- GUILD CONFIG (GM/Manager-managed point values)
    local isGM = Deadpool:IsGM()
    local isManager = Deadpool:IsManager()
    local gc = Deadpool.db.guildConfig
    local configLabel = isGM and "GUILD CONFIG (GM)" or (isManager and "GUILD CONFIG (Manager)" or "GUILD CONFIG")
    Header(configLabel, COL2, ry); ry = ry - 24

    -- Helper: editable number field for managers, read-only for others
    local function ConfigField(label, configKey, x, y)
        local lbl = content:CreateFontString(nil, "OVERLAY")
        lbl:SetFont(TM:GetFont(12, ""))
        lbl:SetPoint("TOPLEFT", content, "TOPLEFT", x + 8, y)
        lbl:SetText(label)
        lbl:SetTextColor(t.textDim[1], t.textDim[2], t.textDim[3])

        if isManager then
            local editBox = CreateFrame("EditBox", nil, content, "InputBoxTemplate")
            editBox:SetSize(50, 18)
            editBox:SetPoint("LEFT", lbl, "RIGHT", 8, 0)
            editBox:SetAutoFocus(false)
            editBox:SetMaxLetters(6)
            editBox:SetText(tostring(gc[configKey] or 0))
            editBox:SetScript("OnEnterPressed", function(self)
                local val = tonumber(self:GetText())
                if val then
                    Deadpool.db.guildConfig[configKey] = val
                end
                self:ClearFocus()
            end)
            editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
            if not UI.settingsPanel._configEdits then UI.settingsPanel._configEdits = {} end
            UI.settingsPanel._configEdits[configKey] = editBox
        else
            local val = content:CreateFontString(nil, "OVERLAY")
            val:SetFont(TM:GetFont(12, ""))
            val:SetPoint("LEFT", lbl, "RIGHT", 8, 0)
            val:SetText(Deadpool.colors.yellow .. tostring(gc[configKey] or 0) .. "|r")
            val:SetTextColor(t.text[1], t.text[2], t.text[3])
        end
    end

    ConfigField("PvP Kill:", "pointsPerKill", COL2, ry); ry = ry - 22
    ConfigField("KOS Kill:", "pointsPerKOSKill", COL2, ry); ry = ry - 22
    ConfigField("Bounty Kill:", "pointsPerBountyKill", COL2, ry); ry = ry - 22
    ConfigField("Underdog 3-5 (x):", "pointsUnderdogMultiplier3", COL2, ry); ry = ry - 22
    ConfigField("Underdog 6+ (x):", "pointsUnderdogMultiplier6", COL2, ry); ry = ry - 22
    ConfigField("Full Pts Range:", "pointsLowbieRange", COL2, ry); ry = ry - 22
    ConfigField("Low Reduction:", "pointsLowbieReduction", COL2, ry); ry = ry - 22
    ConfigField("Floor Tier (lvls):", "pointsLowbieTier2", COL2, ry); ry = ry - 22
    ConfigField("Floor Pts:", "pointsLowbieFloor", COL2, ry); ry = ry - 26

    -- Manager/GM: Push Config button
    if isManager then
        local pushBtn = CreateFrame("Button", nil, content, "BackdropTemplate")
        pushBtn:SetSize(140, 22)
        pushBtn:SetPoint("TOPLEFT", content, "TOPLEFT", COL2 + 8, ry)
        pushBtn:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
        })
        pushBtn:SetBackdropColor(t.accent[1] * 0.3, t.accent[2] * 0.3, t.accent[3] * 0.3, 0.9)
        pushBtn:SetBackdropBorderColor(t.accent[1], t.accent[2], t.accent[3], 0.6)
        local btnLabel = pushBtn:CreateFontString(nil, "OVERLAY")
        btnLabel:SetFont(TM:GetFont(11, ""))
        btnLabel:SetPoint("CENTER")
        btnLabel:SetText(Deadpool.colors.gold .. "Push to Guild|r")
        pushBtn:SetScript("OnEnter", function(self)
            self:SetBackdropColor(t.accent[1] * 0.5, t.accent[2] * 0.5, t.accent[3] * 0.5, 1)
        end)
        pushBtn:SetScript("OnLeave", function(self)
            self:SetBackdropColor(t.accent[1] * 0.3, t.accent[2] * 0.3, t.accent[3] * 0.3, 0.9)
        end)
        pushBtn:SetScript("OnClick", function()
            -- Read values from edit boxes
            if UI.settingsPanel._configEdits then
                for key, editBox in pairs(UI.settingsPanel._configEdits) do
                    local val = tonumber(editBox:GetText())
                    if val then Deadpool.db.guildConfig[key] = val end
                end
            end
            Deadpool:BroadcastGMConfig()
        end)
        ry = ry - 28
    end

    -- Show who last updated config
    if gc.updatedBy and gc.updatedBy ~= "" then
        local infoLbl = content:CreateFontString(nil, "OVERLAY")
        infoLbl:SetFont(TM:GetFont(10, ""))
        infoLbl:SetPoint("TOPLEFT", content, "TOPLEFT", COL2 + 8, ry)
        infoLbl:SetTextColor(t.textDim[1], t.textDim[2], t.textDim[3])
        infoLbl:SetText("Last updated by " .. Deadpool:ShortName(gc.updatedBy) .. " " .. Deadpool:TimeAgo(gc.updatedAt))
    end
    ry = ry - 26

    -- SYNC
    Header("SYNC", COL2, ry); ry = ry - 24
    Check("Guild sync enabled", "syncEnabled", COL2, ry); ry = ry - 34

    -- MANAGERS (GM-only: delegate access)
    if isGM then
        Header("MANAGERS", COL2, ry); ry = ry - 24
        local managers = gc.managers or {}
        local mgrNames = {}
        for n in pairs(managers) do mgrNames[#mgrNames + 1] = Deadpool:ShortName(n) end
        local mgrText = #mgrNames > 0 and table.concat(mgrNames, ", ") or Deadpool.colors.grey .. "None assigned|r"
        local mgrLbl = content:CreateFontString(nil, "OVERLAY")
        mgrLbl:SetFont(TM:GetFont(11, ""))
        mgrLbl:SetPoint("TOPLEFT", content, "TOPLEFT", COL2 + 8, ry)
        mgrLbl:SetTextColor(t.text[1], t.text[2], t.text[3])
        mgrLbl:SetText(mgrText)
        ry = ry - 20

        -- Add manager edit box
        local mgrEdit = CreateFrame("EditBox", nil, content, "InputBoxTemplate")
        mgrEdit:SetSize(130, 18)
        mgrEdit:SetPoint("TOPLEFT", content, "TOPLEFT", COL2 + 8, ry)
        mgrEdit:SetAutoFocus(false)
        mgrEdit:SetMaxLetters(32)

        local addMgrBtn = CreateFrame("Button", nil, content, "BackdropTemplate")
        addMgrBtn:SetSize(30, 18)
        addMgrBtn:SetPoint("LEFT", mgrEdit, "RIGHT", 4, 0)
        addMgrBtn:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8x8",edgeFile="Interface\\Buttons\\WHITE8x8",edgeSize=1})
        addMgrBtn:SetBackdropColor(0.1, 0.5, 0.1, 0.9)
        addMgrBtn:SetBackdropBorderColor(0.2, 0.7, 0.2, 0.6)
        local addLbl = addMgrBtn:CreateFontString(nil, "OVERLAY")
        addLbl:SetFont(TM:GetFont(10, "OUTLINE")); addLbl:SetPoint("CENTER"); addLbl:SetText("+")
        addMgrBtn:SetScript("OnClick", function()
            local name = mgrEdit:GetText()
            if name and name ~= "" then
                local fullName = Deadpool:NormalizeName(name)
                if fullName then
                    if not Deadpool.db.guildConfig.managers then Deadpool.db.guildConfig.managers = {} end
                    Deadpool.db.guildConfig.managers[fullName] = true
                    Deadpool:Print(Deadpool.colors.green .. Deadpool:ShortName(fullName) .. " added as manager.|r")
                    mgrEdit:SetText("")
                    UI:ShowSettingsPanel()  -- rebuild to reflect
                end
            end
        end)

        local remMgrBtn = CreateFrame("Button", nil, content, "BackdropTemplate")
        remMgrBtn:SetSize(30, 18)
        remMgrBtn:SetPoint("LEFT", addMgrBtn, "RIGHT", 4, 0)
        remMgrBtn:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8x8",edgeFile="Interface\\Buttons\\WHITE8x8",edgeSize=1})
        remMgrBtn:SetBackdropColor(0.5, 0.1, 0.1, 0.9)
        remMgrBtn:SetBackdropBorderColor(0.7, 0.2, 0.2, 0.6)
        local remLbl = remMgrBtn:CreateFontString(nil, "OVERLAY")
        remLbl:SetFont(TM:GetFont(10, "OUTLINE")); remLbl:SetPoint("CENTER"); remLbl:SetText("-")
        remMgrBtn:SetScript("OnClick", function()
            local name = mgrEdit:GetText()
            if name and name ~= "" then
                local fullName = Deadpool:NormalizeName(name)
                if fullName and Deadpool.db.guildConfig.managers then
                    Deadpool.db.guildConfig.managers[fullName] = nil
                    Deadpool:Print(Deadpool.colors.red .. Deadpool:ShortName(fullName) .. " removed as manager.|r")
                    mgrEdit:SetText("")
                    UI:ShowSettingsPanel()
                end
            end
        end)
        ry = ry - 30
    end

    -- WAR GUILDS (Manager: declare war on enemy guilds)
    if isManager then
        Header("GUILD WARS", COL2, ry); ry = ry - 24
        local wars = gc.warGuilds or {}
        local warNames = {}
        for g in pairs(wars) do warNames[#warNames + 1] = g end
        local warText = #warNames > 0 and Deadpool.colors.red .. table.concat(warNames, ", ") .. "|r" or Deadpool.colors.grey .. "None declared|r"
        local warLbl = content:CreateFontString(nil, "OVERLAY")
        warLbl:SetFont(TM:GetFont(11, ""))
        warLbl:SetPoint("TOPLEFT", content, "TOPLEFT", COL2 + 8, ry)
        warLbl:SetTextColor(t.text[1], t.text[2], t.text[3])
        warLbl:SetText(warText)
        ry = ry - 20

        local warEdit = CreateFrame("EditBox", nil, content, "InputBoxTemplate")
        warEdit:SetSize(130, 18)
        warEdit:SetPoint("TOPLEFT", content, "TOPLEFT", COL2 + 8, ry)
        warEdit:SetAutoFocus(false)
        warEdit:SetMaxLetters(48)

        local addWarBtn = CreateFrame("Button", nil, content, "BackdropTemplate")
        addWarBtn:SetSize(30, 18)
        addWarBtn:SetPoint("LEFT", warEdit, "RIGHT", 4, 0)
        addWarBtn:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8x8",edgeFile="Interface\\Buttons\\WHITE8x8",edgeSize=1})
        addWarBtn:SetBackdropColor(0.5, 0.1, 0.1, 0.9)
        addWarBtn:SetBackdropBorderColor(0.7, 0.2, 0.2, 0.6)
        local addWarLbl = addWarBtn:CreateFontString(nil, "OVERLAY")
        addWarLbl:SetFont(TM:GetFont(10, "OUTLINE")); addWarLbl:SetPoint("CENTER"); addWarLbl:SetText("+")
        addWarBtn:SetScript("OnClick", function()
            local guildName = warEdit:GetText()
            if guildName and guildName ~= "" then
                if not Deadpool.db.guildConfig.warGuilds then Deadpool.db.guildConfig.warGuilds = {} end
                Deadpool.db.guildConfig.warGuilds[guildName] = true
                Deadpool:Print(Deadpool.colors.red .. "WAR DECLARED|r against <" .. guildName .. ">!")
                warEdit:SetText("")
                Deadpool:BroadcastGMConfig()
                UI:ShowSettingsPanel()
            end
        end)

        local remWarBtn = CreateFrame("Button", nil, content, "BackdropTemplate")
        remWarBtn:SetSize(30, 18)
        remWarBtn:SetPoint("LEFT", addWarBtn, "RIGHT", 4, 0)
        remWarBtn:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8x8",edgeFile="Interface\\Buttons\\WHITE8x8",edgeSize=1})
        remWarBtn:SetBackdropColor(0.1, 0.4, 0.1, 0.9)
        remWarBtn:SetBackdropBorderColor(0.2, 0.6, 0.2, 0.6)
        local remWarLbl = remWarBtn:CreateFontString(nil, "OVERLAY")
        remWarLbl:SetFont(TM:GetFont(10, "OUTLINE")); remWarLbl:SetPoint("CENTER"); remWarLbl:SetText("-")
        remWarBtn:SetScript("OnClick", function()
            local guildName = warEdit:GetText()
            if guildName and guildName ~= "" and Deadpool.db.guildConfig.warGuilds then
                Deadpool.db.guildConfig.warGuilds[guildName] = nil
                Deadpool:Print(Deadpool.colors.green .. "Peace declared|r with <" .. guildName .. ">.")
                warEdit:SetText("")
                Deadpool:BroadcastGMConfig()
                UI:ShowSettingsPanel()
            end
        end)
        ry = ry - 30
    elseif next(gc.warGuilds or {}) then
        Header("GUILD WARS", COL2, ry); ry = ry - 24
        local warNames = {}
        for g in pairs(gc.warGuilds or {}) do warNames[#warNames + 1] = g end
        local warLbl = content:CreateFontString(nil, "OVERLAY")
        warLbl:SetFont(TM:GetFont(11, ""))
        warLbl:SetPoint("TOPLEFT", content, "TOPLEFT", COL2 + 8, ry)
        warLbl:SetTextColor(t.text[1], t.text[2], t.text[3])
        warLbl:SetText(Deadpool.colors.red .. table.concat(warNames, ", ") .. "|r")
        ry = ry - 26
    end

    -- DEBUG
    Header("DEBUG", COL2, ry); ry = ry - 24
    Check("Debug mode", "debug", COL2, ry); ry = ry - 34

    -- GM TOOLS
    if isGM then
        Header("GM TOOLS", COL2, ry); ry = ry - 26

        local wipeScoreBtn = CreateFrame("Button", nil, content, "BackdropTemplate")
        wipeScoreBtn:SetSize(160, 20)
        wipeScoreBtn:SetPoint("TOPLEFT", content, "TOPLEFT", COL2 + 8, ry)
        wipeScoreBtn:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8x8",edgeFile="Interface\\Buttons\\WHITE8x8",edgeSize=1})
        wipeScoreBtn:SetBackdropColor(0.5, 0.05, 0.05, 0.9)
        wipeScoreBtn:SetBackdropBorderColor(0.8, 0.1, 0.1, 0.6)
        local wipeLbl = wipeScoreBtn:CreateFontString(nil, "OVERLAY")
        wipeLbl:SetFont(TM:GetFont(10, "")); wipeLbl:SetPoint("CENTER")
        wipeLbl:SetText(Deadpool.colors.red .. "Reset Scoreboard|r")
        wipeScoreBtn:SetScript("OnEnter", function(self)
            self:SetBackdropColor(0.7, 0.1, 0.1, 1)
        end)
        wipeScoreBtn:SetScript("OnLeave", function(self)
            self:SetBackdropColor(0.5, 0.05, 0.05, 0.9)
        end)
        wipeScoreBtn:SetScript("OnClick", function()
            StaticPopup_Show("DEADPOOL_WIPE_SCOREBOARD")
        end)
        ry = ry - 26

        local wipeKillsBtn = CreateFrame("Button", nil, content, "BackdropTemplate")
        wipeKillsBtn:SetSize(160, 20)
        wipeKillsBtn:SetPoint("TOPLEFT", content, "TOPLEFT", COL2 + 8, ry)
        wipeKillsBtn:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8x8",edgeFile="Interface\\Buttons\\WHITE8x8",edgeSize=1})
        wipeKillsBtn:SetBackdropColor(0.5, 0.05, 0.05, 0.9)
        wipeKillsBtn:SetBackdropBorderColor(0.8, 0.1, 0.1, 0.6)
        local wipeKLbl = wipeKillsBtn:CreateFontString(nil, "OVERLAY")
        wipeKLbl:SetFont(TM:GetFont(10, "")); wipeKLbl:SetPoint("CENTER")
        wipeKLbl:SetText(Deadpool.colors.red .. "Reset Kill Log|r")
        wipeKillsBtn:SetScript("OnEnter", function(self)
            self:SetBackdropColor(0.7, 0.1, 0.1, 1)
        end)
        wipeKillsBtn:SetScript("OnLeave", function(self)
            self:SetBackdropColor(0.5, 0.05, 0.05, 0.9)
        end)
        wipeKillsBtn:SetScript("OnClick", function()
            StaticPopup_Show("DEADPOOL_WIPE_KILLLOG")
        end)
        ry = ry - 26
    end

    -- Set scroll content height based on deepest column
    local maxDepth = math.max(math.abs(ly), math.abs(ry)) + 40
    content:SetHeight(maxDepth)

    -- Update scrollbar range after content is built
    C_Timer.After(0.05, function()
        if UI.settingsPanel and UI.settingsPanel._scrollFrame and UI.settingsPanel._scrollBar then
            local frameH = UI.settingsPanel._scrollFrame:GetHeight() or 0
            local maxScroll = math.max(0, maxDepth - frameH)
            UI.settingsPanel._scrollBar:SetMinMaxValues(0, maxScroll)
            UI.settingsPanel._scrollBar:SetValue(0)
        end
    end)
end

function UI:UpdateSettingsValues()
    if not UI.settingsPanel then return end
    local s = Deadpool.db.settings

    -- Update checkboxes
    for key, cb in pairs(UI.settingsPanel._checkboxes) do
        cb:SetChecked(s[key] and true or false)
    end

    -- Update GM config edit boxes (if GM)
    if UI.settingsPanel._configEdits then
        local gc = Deadpool.db.guildConfig
        for key, editBox in pairs(UI.settingsPanel._configEdits) do
            editBox:SetText(tostring(gc[key] or 0))
        end
    end

    -- Update theme dropdown text
    if UI.settingsPanel._themeDD then
        UIDropDownMenu_SetText(UI.settingsPanel._themeDD, Deadpool.modules.Theme:GetThemeName())
    end

    local isGM = Deadpool:IsGM()
    local isMgr = Deadpool:IsManager()
    local roleTag = isGM and (" | " .. Deadpool.colors.gold .. "GM|r") or (isMgr and (" | " .. Deadpool.colors.cyan .. "Manager|r") or "")
    statusText:SetText("Settings | " .. Deadpool.modules.Theme:GetThemeName() .. roleTag)
end

----------------------------------------------------------------------
-- Scale popup (separate window so the slider doesn't fight the scaling)
----------------------------------------------------------------------
function UI:ShowScalePopup()
    if UI._scalePopup then
        UI._scalePopup:Show()
        return
    end

    local TM = Deadpool.modules.Theme
    local t = TM.active

    local popup = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    popup:SetSize(300, 100)
    popup:SetPoint("CENTER", UIParent, "CENTER", 0, 100)
    popup:SetFrameStrata("DIALOG")
    popup:SetMovable(true)
    popup:EnableMouse(true)
    popup:RegisterForDrag("LeftButton")
    popup:SetScript("OnDragStart", popup.StartMoving)
    popup:SetScript("OnDragStop", popup.StopMovingOrSizing)
    popup:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 2,
    })
    popup:SetBackdropColor(t.bg[1], t.bg[2], t.bg[3], 0.95)
    popup:SetBackdropBorderColor(t.accent[1], t.accent[2], t.accent[3], 0.8)

    local title = popup:CreateFontString(nil, "OVERLAY")
    title:SetFont(TM:GetFont(13, "OUTLINE"))
    title:SetPoint("TOP", 0, -10)
    title:SetText(TM:AccentHex() .. "UI Scale|r")

    local slider = CreateFrame("Slider", nil, popup, "OptionsSliderTemplate")
    slider:SetPoint("CENTER", 0, -5)
    slider:SetSize(220, 16)
    slider:SetMinMaxValues(0.7, 1.3)
    slider:SetValueStep(0.05)
    slider:SetObeyStepOnDrag(true)
    slider:SetValue(Deadpool.db.settings.uiScale or 1.0)
    slider.Low:SetText("70%")
    slider.High:SetText("130%")

    local valueText = popup:CreateFontString(nil, "OVERLAY")
    valueText:SetFont(TM:GetFont(14, "OUTLINE"))
    valueText:SetPoint("TOP", slider, "BOTTOM", 0, -8)
    valueText:SetText(math.floor((Deadpool.db.settings.uiScale or 1.0) * 100) .. "%")
    valueText:SetTextColor(t.text[1], t.text[2], t.text[3])

    slider:SetScript("OnValueChanged", function(self, value)
        value = math.floor(value * 20 + 0.5) / 20
        Deadpool.db.settings.uiScale = value
        if mainFrame then mainFrame:SetScale(value) end
        valueText:SetText(math.floor(value * 100) .. "%")
        -- Update the settings button label if it exists
        if UI.settingsPanel and UI.settingsPanel._scaleBtn then
            UI.settingsPanel._scaleBtn._label:SetText("Scale: " .. math.floor(value * 100) .. "%  (click to adjust)")
        end
    end)

    -- Close button
    local closeBtn = CreateFrame("Button", nil, popup)
    closeBtn:SetSize(20, 20)
    closeBtn:SetPoint("TOPRIGHT", -4, -4)
    local xText = closeBtn:CreateFontString(nil, "OVERLAY")
    xText:SetFont("Fonts\\FRIZQT__.TTF", 14, "OUTLINE")
    xText:SetPoint("CENTER")
    xText:SetText("X")
    xText:SetTextColor(0.8, 0.2, 0.2)
    closeBtn:SetScript("OnClick", function() popup:Hide() end)

    UI._scalePopup = popup
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
        mainFrame.titleBarBg:SetColorTexture(t.accent[1] * 0.3, t.accent[2] * 0.3, t.accent[3] * 0.3, 0.95)
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

    -- Bottom bar
    if mainFrame.bottomBar then
        mainFrame.bottomBar:SetBackdropColor(t.headerBg[1], t.headerBg[2], t.headerBg[3], 0.95)
    end

    -- Scroll bar
    if contentArea and contentArea.scrollBar then
        contentArea.scrollBar:SetBackdropColor(t.bg[1], t.bg[2], t.bg[3], 0.5)
        contentArea.scrollBar:SetBackdropBorderColor(t.border[1], t.border[2], t.border[3], 0.3)
        local thumb = contentArea.scrollBar:GetThumbTexture()
        if thumb then thumb:SetColorTexture(t.accent[1], t.accent[2], t.accent[3], 0.6) end
    end

    -- Themed buttons
    local function ReThemeBtn(btn)
        if not btn then return end
        btn:SetBackdropColor(t.accent[1] * 0.3, t.accent[2] * 0.3, t.accent[3] * 0.3, 0.9)
        btn:SetBackdropBorderColor(t.accent[1], t.accent[2], t.accent[3], 0.6)
        if btn._label then btn._label:SetTextColor(t.text[1], t.text[2], t.text[3]) end
    end
    ReThemeBtn(mainFrame.addBtn)
    ReThemeBtn(mainFrame.syncBtn)
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
    for _, sc in pairs(Deadpool.demoData:GetMergedScoreboard()) do
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
    dashboardFrame.cards.rank.subtitle:SetText("of " .. Deadpool:TableCount(Deadpool.demoData:GetMergedScoreboard()))

    dashboardFrame.cards.enemies.value:SetText(Deadpool.colors.red .. Deadpool:TableCount(Deadpool.demoData:GetMergedEnemySheet()) .. "|r")
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
            local lvlStr = k.victimLevel and k.victimLevel > 0 and (Deadpool.colors.grey .. " [" .. k.victimLevel .. "]|r") or ""
            local typeTag = ""
            if k.isBounty then typeTag = Deadpool.colors.gold .. " [BOUNTY]|r"
            elseif k.isKOS then typeTag = Deadpool.colors.red .. " [KOS]|r" end
            local timeStr = Deadpool.colors.grey .. Deadpool:TimeAgo(k.time) .. "|r"
            line:SetText(timeStr .. "  " .. Deadpool.colors.green .. killer .. "|r killed " .. victim .. lvlStr .. typeTag .. " in " .. Deadpool.colors.yellow .. (k.zone or "?") .. "|r")
            line:Show()
        else
            line:SetText("")
        end
    end

    -- Session stats
    local nemesis, nemesisCount = nil, 0
    local myDeaths = {}
    for _, d in ipairs(Deadpool.demoData:GetMergedDeathLog()) do
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
        "     Deaths: " .. Deadpool.colors.red .. #(Deadpool.demoData:GetMergedDeathLog()) .. "|r")
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
