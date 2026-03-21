----------------------------------------------------------------------
-- Deadpool - Alerts.lua
-- On-screen alerts for KOS sightings and kill notifications
-- Big flashy "TARGET ACQUIRED" when a KOS target is spotted
----------------------------------------------------------------------

local Alerts = {}
Deadpool:RegisterModule("Alerts", Alerts)

local alertFrame, alertText, alertSubText, alertGlow
local fadeTimer

function Alerts:Init()
    self:CreateAlertFrame()
end

----------------------------------------------------------------------
-- Alert frame: centered, large text overlay
----------------------------------------------------------------------
function Alerts:CreateAlertFrame()
    alertFrame = CreateFrame("Frame", "DeadpoolAlertFrame", UIParent)
    alertFrame:SetSize(500, 100)
    alertFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 180)
    alertFrame:SetFrameStrata("TOOLTIP")
    alertFrame:Hide()

    -- Red glow background
    alertGlow = alertFrame:CreateTexture(nil, "BACKGROUND")
    alertGlow:SetAllPoints()
    alertGlow:SetColorTexture(0.5, 0, 0, 0.35)

    -- Main alert text
    alertText = alertFrame:CreateFontString(nil, "OVERLAY")
    alertText:SetFont("Fonts\\FRIZQT__.TTF", 30, "OUTLINE")
    alertText:SetPoint("CENTER", alertFrame, "CENTER", 0, 12)
    alertText:SetTextColor(1, 0.1, 0.1)

    -- Sub text (target name, bounty info)
    alertSubText = alertFrame:CreateFontString(nil, "OVERLAY")
    alertSubText:SetFont("Fonts\\FRIZQT__.TTF", 16, "OUTLINE")
    alertSubText:SetPoint("CENTER", alertFrame, "CENTER", 0, -16)
    alertSubText:SetTextColor(1, 0.85, 0)

    -- Fade-out animation via OnUpdate
    local elapsed = 0
    local duration = 4
    local fadeStart = 2.5

    alertFrame:SetScript("OnUpdate", function(self, dt)
        elapsed = elapsed + dt
        if elapsed >= duration then
            self:Hide()
            return
        end
        -- Fade out in the last portion
        if elapsed > fadeStart then
            local alpha = 1 - ((elapsed - fadeStart) / (duration - fadeStart))
            self:SetAlpha(math.max(0, alpha))
        end
    end)

    -- Store elapsed reset function
    alertFrame.Show_Custom = function()
        elapsed = 0
        alertFrame:SetAlpha(1)
        alertFrame:Show()
    end
end

----------------------------------------------------------------------
-- Show KOS Alert
----------------------------------------------------------------------
function Deadpool:ShowKOSAlert(fullName, entry)
    if not alertFrame then return end
    if not Deadpool.db.settings.announceKOSSighted then return end

    local nameDisplay = entry.name or Deadpool:ShortName(fullName)
    if entry.class then
        -- Use plain colored text for the alert
        nameDisplay = entry.class and Deadpool:ClassColor(entry.class, nameDisplay) or nameDisplay
    end

    alertText:SetText("TARGET ACQUIRED")

    -- Build subtitle
    local sub = nameDisplay
    if Deadpool:HasActiveBounty(fullName) then
        local bounty = Deadpool:GetBounty(fullName)
        sub = sub .. "  |cFFFFD700[BOUNTY: " .. bounty.bountyGold .. "g]|r"
    end
    if entry.level and entry.level > 0 then
        sub = sub .. "  |cFFAAAAAALv" .. entry.level .. "|r"
    end
    alertSubText:SetText(sub)

    alertFrame.Show_Custom()
end

----------------------------------------------------------------------
-- Show Kill Notification (smaller, brief)
----------------------------------------------------------------------
function Deadpool:ShowKillNotification(killerName, victimName, killType)
    if not alertFrame then return end

    if killType == "bounty" then
        alertText:SetText("BOUNTY KILL!")
        alertText:SetTextColor(1, 0.84, 0)
    elseif killType == "kos" then
        alertText:SetText("KOS ELIMINATED!")
        alertText:SetTextColor(1, 0.1, 0.1)
    else
        return  -- Don't show alert for random kills
    end

    alertSubText:SetText(killerName .. " -> " .. victimName)
    alertFrame.Show_Custom()

    -- Reset color for next use
    C_Timer.After(4, function()
        alertText:SetTextColor(1, 0.1, 0.1)
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
