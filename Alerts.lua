----------------------------------------------------------------------
-- Deadpool - Alerts.lua
-- On-screen alerts for KOS sightings and kill notifications
-- Themed, draggable, toggleable via settings
----------------------------------------------------------------------

local Alerts = {}
Deadpool:RegisterModule("Alerts", Alerts)

local alertFrame, alertText, alertSubText, alertGlow, alertBorder
local isUnlocked = false  -- when true, frame is visible and draggable for positioning

function Alerts:Init()
    self._initialized = true
    self:CreateAlertFrame()
end

----------------------------------------------------------------------
-- Alert frame: themed, draggable, position saved
----------------------------------------------------------------------
function Alerts:CreateAlertFrame()
    local TM = Deadpool.modules.Theme
    local t = TM and TM.active

    alertFrame = CreateFrame("Frame", "DeadpoolAlertFrame", UIParent, "BackdropTemplate")
    alertFrame:SetSize(420, 70)
    alertFrame:SetFrameStrata("TOOLTIP")
    alertFrame:SetMovable(true)
    alertFrame:EnableMouse(false)  -- only enable when unlocked
    alertFrame:SetClampedToScreen(true)
    alertFrame:RegisterForDrag("LeftButton")
    alertFrame:SetScript("OnDragStart", alertFrame.StartMoving)
    alertFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        Deadpool.db.settings.alertFramePos = { point = point, relPoint = relPoint, x = x, y = y }
    end)
    alertFrame:Hide()

    -- Restore saved position or default
    local pos = Deadpool.db.settings.alertFramePos
    if pos then
        alertFrame:SetPoint(pos.point or "CENTER", UIParent, pos.relPoint or "CENTER",
            pos.x or 0, pos.y or 180)
    else
        alertFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 180)
    end

    -- Themed backdrop
    if t then
        alertFrame:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
        })
        alertFrame:SetBackdropColor(t.bg[1] * 0.8, t.bg[2] * 0.8, t.bg[3] * 0.8, 0.85)
        alertFrame:SetBackdropBorderColor(t.accent[1], t.accent[2], t.accent[3], 0.8)
    end

    -- Accent bar at top
    local accentBar = alertFrame:CreateTexture(nil, "ARTWORK")
    accentBar:SetHeight(2)
    accentBar:SetPoint("TOPLEFT", alertFrame, "TOPLEFT", 1, -1)
    accentBar:SetPoint("TOPRIGHT", alertFrame, "TOPRIGHT", -1, -1)
    if t then
        accentBar:SetColorTexture(t.accent[1], t.accent[2], t.accent[3], 0.9)
    else
        accentBar:SetColorTexture(0.8, 0.1, 0.1, 0.9)
    end
    alertFrame._accentBar = accentBar

    -- Main alert text
    alertText = alertFrame:CreateFontString(nil, "OVERLAY")
    if TM then
        alertText:SetFont(TM:GetFont(22, "OUTLINE"))
    else
        alertText:SetFont("Fonts\\FRIZQT__.TTF", 22, "OUTLINE")
    end
    alertText:SetPoint("CENTER", alertFrame, "CENTER", 0, 10)
    alertText:SetTextColor(1, 0.1, 0.1)

    -- Sub text (target name, bounty info)
    alertSubText = alertFrame:CreateFontString(nil, "OVERLAY")
    if TM then
        alertSubText:SetFont(TM:GetFont(12, "OUTLINE"))
    else
        alertSubText:SetFont("Fonts\\FRIZQT__.TTF", 12, "OUTLINE")
    end
    alertSubText:SetPoint("CENTER", alertFrame, "CENTER", 0, -12)
    alertSubText:SetTextColor(1, 0.85, 0)

    -- Unlock label (shown only when positioning)
    local unlockLabel = alertFrame:CreateFontString(nil, "OVERLAY")
    if TM then
        unlockLabel:SetFont(TM:GetFont(9, ""))
    else
        unlockLabel:SetFont("Fonts\\FRIZQT__.TTF", 9, "")
    end
    unlockLabel:SetPoint("BOTTOM", alertFrame, "BOTTOM", 0, 4)
    unlockLabel:SetText("|cFF888888Drag to reposition. Click Lock in Settings to save.|r")
    unlockLabel:Hide()
    alertFrame._unlockLabel = unlockLabel

    -- Fade-out animation via OnUpdate
    local elapsed = 0
    local duration = 4
    local fadeStart = 2.5

    alertFrame:SetScript("OnUpdate", function(self, dt)
        if isUnlocked then return end  -- don't fade while positioning
        elapsed = elapsed + dt
        if elapsed >= duration then
            self:Hide()
            return
        end
        if elapsed > fadeStart then
            local alpha = 1 - ((elapsed - fadeStart) / (duration - fadeStart))
            self:SetAlpha(math.max(0, alpha))
        end
    end)

    alertFrame.Show_Custom = function()
        if not Deadpool.db.settings.showAlertFrame then return end
        elapsed = 0
        alertFrame:SetAlpha(1)
        alertFrame:Show()
    end
end

----------------------------------------------------------------------
-- Unlock/Lock alert frame for positioning
----------------------------------------------------------------------
function Alerts:UnlockPosition()
    if not alertFrame then return end
    isUnlocked = true
    alertFrame:EnableMouse(true)
    alertText:SetText("ALERT POSITION")
    alertSubText:SetText("Drag me where you want alerts to appear")
    alertFrame._unlockLabel:Show()
    alertFrame:SetAlpha(1)
    alertFrame:Show()
end

function Alerts:LockPosition()
    if not alertFrame then return end
    isUnlocked = false
    alertFrame:EnableMouse(false)
    alertFrame._unlockLabel:Hide()
    alertFrame:Hide()
    Deadpool:Print(Deadpool.colors.green .. "Alert position saved.|r")
end

----------------------------------------------------------------------
-- Refresh theme
----------------------------------------------------------------------
function Alerts:ApplyTheme()
    if not alertFrame then return end
    local TM = Deadpool.modules.Theme
    local t = TM and TM.active
    if not t then return end

    alertFrame:SetBackdropColor(t.bg[1] * 0.8, t.bg[2] * 0.8, t.bg[3] * 0.8, 0.85)
    alertFrame:SetBackdropBorderColor(t.accent[1], t.accent[2], t.accent[3], 0.8)
    if alertFrame._accentBar then
        alertFrame._accentBar:SetColorTexture(t.accent[1], t.accent[2], t.accent[3], 0.9)
    end
end

----------------------------------------------------------------------
-- Show KOS Alert
----------------------------------------------------------------------
function Deadpool:ShowKOSAlert(fullName, entry)
    if not alertFrame then return end
    if not Deadpool.db.settings.showAlertFrame then return end
    if not Deadpool.db.settings.announceKOSSighted then return end

    local nameDisplay = entry.name or Deadpool:ShortName(fullName)
    if entry.class then
        nameDisplay = Deadpool:ClassColor(entry.class, nameDisplay)
    end

    alertText:SetText("TARGET ACQUIRED")
    alertText:SetTextColor(1, 0.1, 0.1)

    local sub = nameDisplay
    if Deadpool:HasActiveBounty(fullName) then
        local bounty = Deadpool:GetBounty(fullName)
        local reward = (bounty.bountyGold or 0) > 0 and (bounty.bountyGold .. "g") or ((bounty.bountyPoints or 0) .. "pts")
        sub = sub .. "  |cFFFFD700[BOUNTY: " .. reward .. "]|r"
    end
    if entry.level and entry.level > 0 then
        sub = sub .. "  |cFFAAAAAALv" .. entry.level .. "|r"
    end
    alertSubText:SetText(sub)

    alertFrame.Show_Custom()
    Deadpool:PlayKOSAlertSound()
end

----------------------------------------------------------------------
-- Show Kill Notification
----------------------------------------------------------------------
function Deadpool:ShowKillNotification(killerName, victimName, killType)
    if not alertFrame then return end
    if not Deadpool.db.settings.showAlertFrame then return end

    if killType == "bounty" then
        alertText:SetText("BOUNTY KILL!")
        alertText:SetTextColor(1, 0.84, 0)
    elseif killType == "kos" then
        alertText:SetText("KOS ELIMINATED!")
        alertText:SetTextColor(1, 0.1, 0.1)
    else
        return
    end

    alertSubText:SetText(killerName .. " -> " .. victimName)
    alertFrame.Show_Custom()

    C_Timer.After(4, function()
        if alertText then alertText:SetTextColor(1, 0.1, 0.1) end
    end)
end

----------------------------------------------------------------------
-- Flash screen border (combat flash effect)
----------------------------------------------------------------------
local flashFrame
function Deadpool:FlashScreen()
    if not flashFrame then
        flashFrame = CreateFrame("Frame", nil, UIParent)
        flashFrame:SetAllPoints(UIParent)
        flashFrame:SetFrameStrata("TOOLTIP")
        flashFrame:SetFrameLevel(100)

        local tex = flashFrame:CreateTexture(nil, "OVERLAY")
        tex:SetAllPoints()
        tex:SetColorTexture(0.6, 0, 0, 0.2)
        flashFrame.tex = tex
        flashFrame:Hide()

        local elapsed = 0
        flashFrame:SetScript("OnUpdate", function(self, dt)
            elapsed = elapsed + dt
            if elapsed > 0.4 then
                self:Hide()
                return
            end
            local alpha = 0.2 * (1 - elapsed / 0.4)
            self.tex:SetColorTexture(0.6, 0, 0, math.max(0, alpha))
        end)

        flashFrame.Show_Custom = function()
            elapsed = 0
            flashFrame:Show()
        end
    end

    flashFrame.Show_Custom()
end
