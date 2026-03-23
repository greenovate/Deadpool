----------------------------------------------------------------------
-- Deadpool - Nearby.lua
-- Hostile player proximity tracker sidecar widget
-- Detects alliance players within ~50yd via combat log, nameplates,
-- target, mouseover. Displays a persistent themed sidebar.
----------------------------------------------------------------------

local Nearby = {}
Deadpool:RegisterModule("Nearby", Nearby)

-- Tracked players: [fullName] = { name, realm, class, race, level, guild, lastSeen, isStealth, guid, zone }
local tracked = {}

-- Constants
local EXPIRE_NORMAL = 60      -- seconds to keep a player on list after last seen
local EXPIRE_STEALTH = 300    -- 5 minutes for stealth detection
local UPDATE_INTERVAL = 1     -- refresh every 1 second
local MAX_ROWS = 8            -- max visible rows in the widget
local WIDGET_WIDTH = 220
local ROW_HEIGHT = 18
local scrollOffset = 0        -- for mouse wheel scrolling

-- Combat log flag constants
local COMBATLOG_OBJECT_REACTION_HOSTILE = 0x00000040
local COMBATLOG_OBJECT_REACTION_FRIENDLY = 0x00000020
local COMBATLOG_OBJECT_AFFILIATION_MINE = 0x00000001
local COMBATLOG_OBJECT_AFFILIATION_PARTY = 0x00000002
local COMBATLOG_OBJECT_AFFILIATION_RAID = 0x00000004

-- Throttle alerts per attacker (don't spam for repeated hits)
local alertCooldowns = {}  -- [attackerName] = timestamp
local ALERT_COOLDOWN = 30  -- seconds between alerts for the same attacker

-- UI references
local widget, titleBar, contentFrame, rows, countText
local isMinimized = false

----------------------------------------------------------------------
-- Detection: Add or refresh a tracked hostile player
----------------------------------------------------------------------
function Nearby:TrackPlayer(name, guid, class, race, level, guild, isStealth)
    if not name or name == "" then return end
    local fullName = Deadpool:NormalizeName(name)
    if not fullName then return end

    local isNew = not tracked[fullName]
    local existing = tracked[fullName]
    if existing then
        existing.lastSeen = time()
        if class then existing.class = class end
        if race then existing.race = race end
        if level and level > 0 then existing.level = level end
        if guild then existing.guild = guild end
        if guid then existing.guid = guid end
        if isStealth then existing.isStealth = true end
    else
        tracked[fullName] = {
            name = name:match("^(.-)%-") or name,
            fullName = fullName,
            class = class,
            race = race,
            level = level,
            guild = guild,
            guid = guid,
            lastSeen = time(),
            isStealth = isStealth or false,
            zone = Deadpool:GetZone(),
        }
    end

    -- Alert when an aggressive player appears nearby (first detection only)
    if isNew and Deadpool:IsAggressive(fullName) then
        local display = class and Deadpool:ClassColor(class, Deadpool:ShortName(fullName)) or Deadpool:ShortName(fullName)
        Deadpool:Print(Deadpool.colors.orange .. "WARNING|r " .. display .. Deadpool.colors.orange .. " spotted nearby! (hostile)|r")
        Deadpool:PlayPartyAttackSound()
    end
end

----------------------------------------------------------------------
-- Detection: Scan a unit (nameplate, target, mouseover)
----------------------------------------------------------------------
function Nearby:ScanUnit(unitId)
    if not unitId or not UnitExists(unitId) then return end
    if not UnitIsPlayer(unitId) then return end
    if not UnitIsEnemy("player", unitId) then return end

    local name, realm = UnitName(unitId)
    if not name then return end
    if realm and realm ~= "" then
        name = name .. "-" .. realm
    end

    local _, classFile = UnitClass(unitId)
    local race = UnitRace(unitId)
    local level = UnitLevel(unitId)
    local guild = GetGuildInfo(unitId)

    -- Estimate distance via CheckInteractDistance or range checks
    local dist = nil
    if CheckInteractDistance(unitId, 1) then
        dist = 10   -- inspect range ~10yd
    elseif CheckInteractDistance(unitId, 2) then
        dist = 11   -- trade range ~11yd
    elseif CheckInteractDistance(unitId, 3) then
        dist = 10   -- duel range ~10yd
    elseif CheckInteractDistance(unitId, 4) then
        dist = 28   -- follow range ~28yd
    else
        dist = 40   -- visible nameplate but far
    end

    local isStealth = false
    local fullName = Deadpool:NormalizeName(name)
    if fullName then
        self:TrackPlayer(name, UnitGUID(unitId), classFile, race, level, guild, isStealth)
        if tracked[fullName] then
            tracked[fullName].distance = dist
            tracked[fullName].unitId = unitId
        end
        -- Update enemy sheet with guild info for war guild detection
        if guild and guild ~= "" then
            local enemy = Deadpool:GetOrCreateEnemy(fullName)
            if not enemy.guild or enemy.guild ~= guild then
                enemy.guild = guild
            end
            if classFile then enemy.class = classFile end
            if race then enemy.race = race end
            if level and level > 0 then enemy.level = level end
        end
    end
end

----------------------------------------------------------------------
-- Detection: Combat log events (hostile players in ~50yd range)
----------------------------------------------------------------------
function Nearby:OnCombatLogEvent()
    local _, subevent, _, sourceGUID, sourceName, sourceFlags, _,
          destGUID, destName, destFlags = CombatLogGetCurrentEventInfo()

    -- Only care about damage/kill events for aggression detection
    local isDamage = subevent and (subevent:find("_DAMAGE") or subevent == "SWING_DAMAGE" or subevent == "PARTY_KILL")

    -- Check source: hostile player
    if sourceGUID and sourceName and sourceFlags then
        if sourceGUID:sub(1, 6) == "Player" and bit.band(sourceFlags, COMBATLOG_OBJECT_REACTION_HOSTILE) > 0 then
            local class, race = Deadpool.modules.KillTracker:GetInfoFromGUID(sourceGUID)
            -- Detect stealth abilities
            local isStealth = false
            if subevent and (subevent == "SPELL_AURA_APPLIED" or subevent == "SPELL_CAST_SUCCESS") then
                local _, spellName = select(12, CombatLogGetCurrentEventInfo())
                if spellName and (spellName == "Stealth" or spellName == "Prowl" or spellName == "Vanish"
                    or spellName == "Shadowmeld") then
                    isStealth = true
                end
            end
            self:TrackPlayer(sourceName, sourceGUID, class, race, nil, nil, isStealth)

            -- Aggression detection: hostile player damaging a friendly player
            if isDamage and destGUID and destGUID:sub(1, 6) == "Player" and destFlags then
                local destIsFriendly = bit.band(destFlags, COMBATLOG_OBJECT_REACTION_FRIENDLY) > 0
                if destIsFriendly then
                    local fullName = Deadpool:NormalizeName(sourceName)
                    if fullName and tracked[fullName] then
                        tracked[fullName].isAggressive = true
                        tracked[fullName].aggressiveTime = time()
                        tracked[fullName].lastVictim = destName
                    end

                    -- Alert if the victim is party/raid/guild member
                    local isPartyRaid = bit.band(destFlags, COMBATLOG_OBJECT_AFFILIATION_PARTY) > 0
                        or bit.band(destFlags, COMBATLOG_OBJECT_AFFILIATION_RAID) > 0
                    local isMe = bit.band(destFlags, COMBATLOG_OBJECT_AFFILIATION_MINE) > 0

                    if (isPartyRaid or isMe) and fullName then
                        local now = time()
                        if not alertCooldowns[fullName] or (now - alertCooldowns[fullName]) >= ALERT_COOLDOWN then
                            alertCooldowns[fullName] = now
                            local attackerDisplay = class and Deadpool:ClassColor(class, Deadpool:ShortName(fullName))
                                or Deadpool:ShortName(fullName)
                            if isMe and destName == UnitName("player") then
                                Deadpool:Print(Deadpool.colors.red .. "UNDER ATTACK!|r " ..
                                    attackerDisplay .. " is attacking you!")
                            else
                                Deadpool:Print(Deadpool.colors.red .. "ALLY ATTACKED!|r " ..
                                    attackerDisplay .. " is attacking " ..
                                    Deadpool.colors.cyan .. (destName or "?") .. "|r!")
                            end
                            -- Play alert sound
                            if Deadpool.db.settings.alertSound then
                                Deadpool:PlayPartyAttackSound()
                            end
                        end
                    end
                end
            end
        end
    end

    -- Check dest: hostile player
    if destGUID and destName and destFlags then
        if destGUID:sub(1, 6) == "Player" and bit.band(destFlags, COMBATLOG_OBJECT_REACTION_HOSTILE) > 0 then
            local class, race = Deadpool.modules.KillTracker:GetInfoFromGUID(destGUID)
            self:TrackPlayer(destName, destGUID, class, race, nil, nil, false)
        end
    end
end

----------------------------------------------------------------------
-- Purge expired entries
----------------------------------------------------------------------
function Nearby:PurgeExpired()
    local now = time()
    for fullName, data in pairs(tracked) do
        local expire = data.isStealth and EXPIRE_STEALTH or EXPIRE_NORMAL
        if (now - data.lastSeen) > expire then
            tracked[fullName] = nil
        end
    end
end

----------------------------------------------------------------------
-- Get sorted list of nearby hostiles (most recent first)
----------------------------------------------------------------------
function Nearby:GetSorted()
    self:PurgeExpired()
    local list = {}
    for fullName, data in pairs(tracked) do
        data._key = fullName
        list[#list + 1] = data
    end
    -- Sort by distance (closest first), unknown distance at the end
    table.sort(list, function(a, b)
        local da = a.distance or 999
        local db = b.distance or 999
        if da ~= db then return da < db end
        return (a.lastSeen or 0) > (b.lastSeen or 0)
    end)
    return list
end

----------------------------------------------------------------------
-- Widget: Build the sidecar frame
----------------------------------------------------------------------
function Nearby:BuildWidget()
    if widget then return end

    local TM = Deadpool.modules.Theme
    local t = TM.active

    widget = CreateFrame("Frame", "DeadpoolNearbyWidget", UIParent, "BackdropTemplate")
    widget:SetSize(WIDGET_WIDTH, 36)  -- starts collapsed to title bar
    widget:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -20, -200)
    widget:SetMovable(true)
    widget:EnableMouse(true)
    widget:SetClampedToScreen(true)
    widget:SetFrameStrata("MEDIUM")
    widget:SetFrameLevel(50)

    -- Restore saved position
    local pos = Deadpool.db.settings.nearbyWidgetPos
    if pos then
        widget:ClearAllPoints()
        widget:SetPoint(pos.point or "TOPRIGHT", UIParent, pos.relPoint or "TOPRIGHT",
            pos.x or -20, pos.y or -200)
    end

    -- Title bar (always visible, used for dragging + minimize)
    titleBar = CreateFrame("Frame", nil, widget, "BackdropTemplate")
    titleBar:SetHeight(20)
    titleBar:SetPoint("TOPLEFT", widget, "TOPLEFT", 1, -1)
    titleBar:SetPoint("TOPRIGHT", widget, "TOPRIGHT", -1, -1)
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function()
        widget:StartMoving()
    end)
    titleBar:SetScript("OnDragStop", function()
        widget:StopMovingOrSizing()
        -- Save position
        local point, _, relPoint, x, y = widget:GetPoint()
        Deadpool.db.settings.nearbyWidgetPos = {
            point = point, relPoint = relPoint, x = x, y = y
        }
    end)

    -- Title text
    local titleText = titleBar:CreateFontString(nil, "OVERLAY")
    titleText:SetFont(TM:GetFont(11, "OUTLINE"))
    titleText:SetPoint("LEFT", titleBar, "LEFT", 8, 0)
    titleText:SetText(TM:AccentHex() .. "NEARBY|r")
    widget._titleText = titleText

    -- Count badge
    countText = titleBar:CreateFontString(nil, "OVERLAY")
    countText:SetFont(TM:GetFont(10, "OUTLINE"))
    countText:SetPoint("RIGHT", titleBar, "RIGHT", -24, 0)
    countText:SetText("0")
    countText:SetTextColor(t.text[1], t.text[2], t.text[3])

    -- Minimize button
    local minBtn = CreateFrame("Button", nil, titleBar)
    minBtn:SetSize(16, 16)
    minBtn:SetPoint("RIGHT", titleBar, "RIGHT", -4, 0)
    local minText = minBtn:CreateFontString(nil, "OVERLAY")
    minText:SetFont(TM:GetFont(12, "OUTLINE"))
    minText:SetPoint("CENTER")
    minText:SetText("-")
    minText:SetTextColor(t.text[1], t.text[2], t.text[3])
    widget._minText = minText
    minBtn:SetScript("OnClick", function()
        isMinimized = not isMinimized
        if isMinimized then
            contentFrame:Hide()
            widget:SetHeight(22)
            minText:SetText("+")
        else
            contentFrame:Show()
            self:UpdateWidget()
            minText:SetText("-")
        end
    end)

    -- Content area
    contentFrame = CreateFrame("Frame", nil, widget)
    contentFrame:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", 0, 0)
    contentFrame:SetPoint("TOPRIGHT", titleBar, "BOTTOMRIGHT", 0, 0)
    contentFrame:SetHeight(1)  -- will grow dynamically
    contentFrame:EnableMouse(true)
    contentFrame:SetScript("OnMouseWheel", function(self, delta)
        scrollOffset = scrollOffset - delta
        if scrollOffset < 0 then scrollOffset = 0 end
        Nearby:UpdateWidget()
    end)

    -- Pre-create row frames
    rows = {}
    for i = 1, MAX_ROWS do
        local row = CreateFrame("Button", nil, contentFrame)
        row:SetHeight(ROW_HEIGHT)
        row:SetPoint("TOPLEFT", contentFrame, "TOPLEFT", 0, -((i - 1) * ROW_HEIGHT))
        row:SetPoint("TOPRIGHT", contentFrame, "TOPRIGHT", 0, -((i - 1) * ROW_HEIGHT))
        row:EnableMouse(true)
        -- Secure target button overlay (for left-click targeting)
        local secureBtn = CreateFrame("Button", "DeadpoolNearbySecure" .. i, row, "SecureActionButtonTemplate")
        secureBtn:SetAllPoints(row)
        secureBtn:SetAttribute("type", "macro")
        secureBtn:SetAttribute("macrotext", "")
        secureBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        secureBtn:SetScript("OnClick", function(self, button)
            if button == "RightButton" then
                local parentRow = self:GetParent()
                if parentRow and parentRow._data then
                    Nearby:ShowContextMenu(parentRow)
                end
            end
        end)
        secureBtn:SetScript("OnEnter", function(self)
            local parentRow = self:GetParent()
            if parentRow then
                local handler = parentRow:GetScript("OnEnter")
                if handler then handler(parentRow) end
            end
        end)
        secureBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row._secureBtn = secureBtn

        -- Background for alternating rows
        local bg = row:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        row._bg = bg

        -- KOS indicator (left edge)
        local kosBar = row:CreateTexture(nil, "ARTWORK")
        kosBar:SetSize(3, ROW_HEIGHT)
        kosBar:SetPoint("LEFT", row, "LEFT", 0, 0)
        kosBar:SetColorTexture(1, 0, 0, 1)
        kosBar:Hide()
        row._kosBar = kosBar

        -- Class icon placeholder (colored dot)
        local classDot = row:CreateTexture(nil, "ARTWORK")
        classDot:SetSize(8, 8)
        classDot:SetPoint("LEFT", row, "LEFT", 6, 0)
        classDot:SetColorTexture(1, 1, 1, 1)
        row._classDot = classDot

        -- Name text
        local nameText = row:CreateFontString(nil, "OVERLAY")
        nameText:SetFont(TM:GetFont(10, ""))
        nameText:SetPoint("LEFT", classDot, "RIGHT", 4, 0)
        nameText:SetJustifyH("LEFT")
        nameText:SetWidth(120)
        nameText:SetWordWrap(false)
        row._nameText = nameText

        -- Level text
        local lvlText = row:CreateFontString(nil, "OVERLAY")
        lvlText:SetFont(TM:GetFont(9, ""))
        lvlText:SetPoint("RIGHT", row, "RIGHT", -6, 0)
        lvlText:SetJustifyH("RIGHT")
        row._lvlText = lvlText

        -- Stealth icon
        local stealthText = row:CreateFontString(nil, "OVERLAY")
        stealthText:SetFont(TM:GetFont(9, ""))
        stealthText:SetPoint("RIGHT", lvlText, "LEFT", -4, 0)
        stealthText:Hide()
        row._stealthText = stealthText

        -- Timer text (seconds remaining)
        local timerText = row:CreateFontString(nil, "OVERLAY")
        timerText:SetFont(TM:GetFont(8, ""))
        timerText:SetPoint("RIGHT", stealthText, "LEFT", -2, 0)
        timerText:SetJustifyH("RIGHT")
        row._timerText = timerText

        row:SetScript("OnClick", function(self, button)
            if button == "RightButton" and self._data then
                Nearby:ShowContextMenu(self)
            end
        end)

        row:SetScript("OnEnter", function(self)
            if self._data then
                local d = self._data
                GameTooltip:SetOwner(self, "ANCHOR_LEFT")
                local nm = d.class and Deadpool:ClassColor(d.class, d.name or d.fullName) or (d.name or d.fullName)
                GameTooltip:AddLine(nm, 1, 1, 1)
                if d.class then GameTooltip:AddLine(d.class, 0.7, 0.7, 0.7) end
                if d.race then GameTooltip:AddLine(d.race, 0.7, 0.7, 0.7) end
                if d.guild then GameTooltip:AddLine("<" .. d.guild .. ">", 0.4, 0.6, 0.8) end
                if d.level and d.level > 0 then GameTooltip:AddLine("Level " .. d.level, 0.7, 0.7, 0.7) end
                if d.isStealth then GameTooltip:AddLine("STEALTHED", 1, 0.3, 1) end
                if d.isAggressive then
                    GameTooltip:AddLine("IN COMBAT — attacking players!", 1, 0.1, 0.1)
                    if d.lastVictim then
                        GameTooltip:AddLine("Last target: " .. d.lastVictim, 0.9, 0.5, 0.5)
                    end
                end
                local isKOS = Deadpool:IsKOS(d.fullName)
                if isKOS then GameTooltip:AddLine("KILL ON SIGHT", 1, 0, 0) end
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine("Left-click to target", 0.5, 0.5, 0.5)
                GameTooltip:AddLine("Right-click for options", 0.5, 0.5, 0.5)
                GameTooltip:Show()
            end
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)

        rows[i] = row
    end

    -- Context menu frame
    if DeadpoolNearbyContextMenu then
        DeadpoolNearbyContextMenu:Hide()
        DeadpoolNearbyContextMenu:SetParent(nil)
    end
    widget._ctxMenu = CreateFrame("Frame", "DeadpoolNearbyContextMenu", UIParent, "UIDropDownMenuTemplate")

    self:ApplyTheme()
end

----------------------------------------------------------------------
-- Context menu for right-clicking a row
----------------------------------------------------------------------
function Nearby:ShowContextMenu(row)
    local data = row._data
    if not data then return end
    local fullName = data.fullName
    local menuList = {}

    table.insert(menuList, { text = Deadpool:ShortName(fullName), isTitle = true, notCheckable = true })

    if not Deadpool:IsKOS(fullName) then
        table.insert(menuList, { text = "Add to KOS", notCheckable = true, func = function()
            Deadpool:AddToKOS(fullName, "Spotted nearby")
            -- Push tracked data into the KOS entry since we have it
            local entry = Deadpool:GetKOSEntry(fullName)
            if entry and data then
                if data.class then entry.class = data.class end
                if data.race then entry.race = data.race end
                if data.level and data.level > 0 then entry.level = data.level end
                if data.guild then entry.guild = data.guild end
                entry.lastSeenZone = data.zone or Deadpool:GetZone()
                entry.lastSeenTime = time()
            end
        end })
    else
        table.insert(menuList, { text = "|cFFFF4444[KOS]|r Remove from KOS", notCheckable = true, func = function()
            Deadpool:RemoveFromKOS(fullName)
        end })
    end

    table.insert(menuList, { text = "Place Bounty", notCheckable = true, func = function()
        local d = StaticPopup_Show("DEADPOOL_PLACE_BOUNTY", Deadpool:ShortName(fullName))
        if d then d.data = fullName end
    end })

    table.insert(menuList, { text = "Cancel", notCheckable = true })

    UIDropDownMenu_Initialize(widget._ctxMenu, function(self, level)
        for _, item in ipairs(menuList) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = item.text
            info.isTitle = item.isTitle
            info.notCheckable = item.notCheckable ~= false
            info.func = item.func
            UIDropDownMenu_AddButton(info, level or 1)
        end
    end, "MENU")
    ToggleDropDownMenu(1, nil, widget._ctxMenu, "cursor", 0, 0)
end

----------------------------------------------------------------------
-- Apply / refresh theme on widget
----------------------------------------------------------------------
function Nearby:ApplyTheme()
    if not widget then return end
    local TM = Deadpool.modules.Theme
    local t = TM.active
    if not t then return end

    -- Widget backdrop (covers entire frame including title bar)
    widget:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    widget:SetBackdropColor(t.bg[1], t.bg[2], t.bg[3], 0.85)
    widget:SetBackdropBorderColor(t.accent[1] * 0.6, t.accent[2] * 0.6, t.accent[3] * 0.6, 0.8)

    -- Title bar tint (no border, just a subtle accent fill inside the widget)
    titleBar:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
    })
    titleBar:SetBackdropColor(t.accent[1] * 0.15, t.accent[2] * 0.15, t.accent[3] * 0.15, 0.9)

    widget._titleText:SetText(TM:AccentHex() .. "NEARBY|r")
end

----------------------------------------------------------------------
-- Update widget display
----------------------------------------------------------------------
function Nearby:UpdateWidget()
    if not widget or isMinimized then return end
    -- Skip frame resizing during combat (protected function restriction)
    if InCombatLockdown() then return end

    local TM = Deadpool.modules.Theme
    local t = TM.active
    local data = self:GetSorted()
    local count = #data
    local now = time()

    -- Update count badge
    if count > 0 then
        countText:SetText(TM:AccentHex() .. count .. "|r")
    else
        countText:SetText(Deadpool.colors.grey .. "0|r")
    end

    -- Clamp scroll offset
    local maxOffset = math.max(0, count - MAX_ROWS)
    if scrollOffset > maxOffset then scrollOffset = maxOffset end

    -- Resize content to visible rows (not total)
    local visibleCount = math.min(count - scrollOffset, MAX_ROWS)
    if visibleCount < 0 then visibleCount = 0 end
    local contentHeight = math.max(visibleCount, 0) * ROW_HEIGHT
    contentFrame:SetHeight(math.max(contentHeight, 1))
    widget:SetHeight(22 + contentHeight)

    for i = 1, MAX_ROWS do
        local row = rows[i]
        local dataIdx = i + scrollOffset
        if dataIdx <= count then
            local d = data[dataIdx]
            row._data = d
            row:Show()

            -- Update secure target button macro (only out of combat)
            if row._secureBtn and not InCombatLockdown() then
                local targetName = d.name or Deadpool:ShortName(d.fullName)
                row._secureBtn:SetAttribute("macrotext", "/targetexact " .. targetName)
                row._secureBtn:Show()
            end

            -- KOS indicator (red bar) or Aggressive indicator (orange bar)
            local isKOS = Deadpool:IsKOS(d.fullName)
            local isAgg = Deadpool:IsAggressive(d.fullName)
            if isKOS then
                row._kosBar:SetColorTexture(1, 0, 0, 1)
                row._kosBar:Show()
            elseif isAgg then
                row._kosBar:SetColorTexture(1, 0.5, 0, 1)
                row._kosBar:Show()
            else
                row._kosBar:Hide()
            end

            -- Row background: red flash for active combat, orange tint for aggressive, default for others
            if d.isAggressive and d.aggressiveTime and (now - d.aggressiveTime) < 15 then
                row._bg:SetColorTexture(0.5, 0.05, 0.05, 0.5)
            elseif isAgg then
                row._bg:SetColorTexture(0.3, 0.15, 0, 0.3)
            elseif i % 2 == 0 then
                row._bg:SetColorTexture(t.bgAlt[1], t.bgAlt[2], t.bgAlt[3], t.bgAlt[4] or 0.3)
            else
                row._bg:SetColorTexture(0, 0, 0, 0)
            end

            -- Class dot color (parse from |cFFRRGGBB string)
            local ccStr = Deadpool.classColors and Deadpool.classColors[d.class]
            if ccStr then
                local r, g, b = ccStr:match("|cFF(%x%x)(%x%x)(%x%x)")
                if r then
                    row._classDot:SetColorTexture(tonumber(r, 16)/255, tonumber(g, 16)/255, tonumber(b, 16)/255, 1)
                else
                    row._classDot:SetColorTexture(0.5, 0.5, 0.5, 1)
                end
            else
                row._classDot:SetColorTexture(0.5, 0.5, 0.5, 1)
            end

            -- Name (class-colored)
            local shortName = d.name or Deadpool:ShortName(d.fullName)
            if d.class then
                row._nameText:SetText(Deadpool:ClassColor(d.class, shortName))
            else
                row._nameText:SetText(shortName)
            end
            row._nameText:SetTextColor(t.text[1], t.text[2], t.text[3])

            -- Level + distance display
            local lvlStr = ""
            if d.level and d.level > 0 then
                local myLevel = UnitLevel("player") or 60
                local lvlColor = Deadpool.colors.green
                if d.level >= myLevel + 5 then lvlColor = Deadpool.colors.red
                elseif d.level >= myLevel + 3 then lvlColor = Deadpool.colors.orange
                elseif d.level >= myLevel then lvlColor = Deadpool.colors.yellow end
                lvlStr = lvlColor .. d.level .. "|r"
            else
                lvlStr = Deadpool.colors.grey .. "?|r"
            end
            -- Show distance if known
            if d.distance and d.distance < 999 then
                lvlStr = lvlStr .. Deadpool.colors.grey .. " ~" .. d.distance .. "yd|r"
            end
            row._lvlText:SetText(lvlStr)

            -- Stealth indicator
            if d.isStealth then
                row._stealthText:SetText("|cFFFF66FF" .. "S" .. "|r")
                row._stealthText:Show()
            else
                row._stealthText:Hide()
            end

            -- Combat indicator (shows when player is actively attacking friendlies)
            if d.isAggressive and d.aggressiveTime and (now - d.aggressiveTime) < 15 then
                if not row._combatText then
                    row._combatText = row:CreateFontString(nil, "OVERLAY")
                    local TM = Deadpool.modules.Theme
                    row._combatText:SetFont(TM:GetFont(9, "OUTLINE"))
                    row._combatText:SetPoint("LEFT", row._classDot, "LEFT", -2, 0)
                end
                row._combatText:SetText("|cFFFF0000X|r")
                row._combatText:Show()
                row._classDot:Hide()
            else
                if row._combatText then row._combatText:Hide() end
                row._classDot:Show()
            end

            -- Timer (seconds remaining)
            local expire = d.isStealth and EXPIRE_STEALTH or EXPIRE_NORMAL
            local remaining = expire - (now - d.lastSeen)
            if remaining < 10 then
                row._timerText:SetText(Deadpool.colors.red .. remaining .. "s|r")
            elseif remaining < 30 then
                row._timerText:SetText(Deadpool.colors.yellow .. remaining .. "s|r")
            else
                row._timerText:SetText(Deadpool.colors.grey .. remaining .. "s|r")
            end
        else
            row:Hide()
            row._data = nil
            if row._secureBtn and not InCombatLockdown() then row._secureBtn:Hide() end
        end
    end
end

----------------------------------------------------------------------
-- Scan all current nameplates
----------------------------------------------------------------------
function Nearby:ScanAllNameplates()
    for i = 1, 40 do
        local unit = "nameplate" .. i
        if UnitExists(unit) then
            self:ScanUnit(unit)
        end
    end
end

----------------------------------------------------------------------
-- Module Init
----------------------------------------------------------------------
function Nearby:Init()
    self._initialized = true

    -- Register combat log event for detection
    Deadpool:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED", function()
        Nearby:OnCombatLogEvent()
    end)

    -- Register nameplate events
    Deadpool:RegisterEvent("NAME_PLATE_UNIT_ADDED", function(event, unitId)
        Nearby:ScanUnit(unitId)
    end)

    -- Register target/mouseover for enrichment
    Deadpool:RegisterEvent("PLAYER_TARGET_CHANGED", function()
        Nearby:ScanUnit("target")
    end)
    Deadpool:RegisterEvent("UPDATE_MOUSEOVER_UNIT", function()
        Nearby:ScanUnit("mouseover")
    end)

    -- Build the widget
    self:BuildWidget()

    -- Periodic update ticker
    if C_Timer and C_Timer.NewTicker then
        C_Timer.NewTicker(UPDATE_INTERVAL, function()
            Nearby:UpdateWidget()
            -- Also update count text even when minimized
            if isMinimized then
                local data = Nearby:GetSorted()
                local count = #data
                local TM = Deadpool.modules.Theme
                if count > 0 then
                    countText:SetText(TM:AccentHex() .. count .. "|r")
                else
                    countText:SetText(Deadpool.colors.grey .. "0|r")
                end
            end
        end)
    end

    -- Periodic nameplate re-scan every 3 seconds
    if C_Timer and C_Timer.NewTicker then
        C_Timer.NewTicker(3, function()
            Nearby:ScanAllNameplates()
        end)
    end
end
