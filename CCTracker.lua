----------------------------------------------------------------------
-- Deadpool - CCTracker.lua
-- Crowd-control tracker: large movable icon + countdown when the
-- player is sapped/sheeped/feared/etc. PVP trinket indicator glows
-- when escape is available.
----------------------------------------------------------------------

local CC = {}
Deadpool:RegisterModule("CCTracker", CC)

----------------------------------------------------------------------
-- CC spell whitelist (TBC-relevant). Matched by spell name so we
-- don't break across rank IDs. Each entry can include a category
-- string (informational only).
----------------------------------------------------------------------
local CC_SPELLS = {
    -- Mage
    ["Polymorph"]            = "incap",
    ["Polymorph: Pig"]       = "incap",
    ["Polymorph: Turtle"]    = "incap",
    ["Frost Nova"]           = "root",
    ["Frostbite"]            = "root",
    ["Improved Counterspell"]= "silence",
    ["Counterspell - Silenced"] = "silence",
    ["Dragon's Breath"]      = "disorient",
    -- Priest
    ["Psychic Scream"]       = "fear",
    ["Mind Control"]         = "incap",
    ["Shackle Undead"]       = "incap",
    ["Blackout"]             = "stun",
    ["Silence"]              = "silence",
    -- Warlock
    ["Fear"]                 = "fear",
    ["Death Coil"]           = "horror",
    ["Howl of Terror"]       = "fear",
    ["Seduction"]            = "incap",
    ["Banish"]               = "incap",
    ["Curse of Tongues"]     = "silence",
    -- Warrior
    ["Intimidating Shout"]   = "fear",
    ["Hamstring"]            = "snare",
    ["Concussion Blow"]      = "stun",
    ["Charge Stun"]          = "stun",
    ["Disarm"]               = "disarm",
    -- Rogue
    ["Sap"]                  = "incap",
    ["Blind"]                = "incap",
    ["Cheap Shot"]           = "stun",
    ["Kidney Shot"]          = "stun",
    ["Gouge"]                = "incap",
    ["Garrote - Silence"]    = "silence",
    ["Riposte"]              = "disarm",
    -- Druid
    ["Hibernate"]            = "incap",
    ["Cyclone"]              = "incap",
    ["Maim"]                 = "stun",
    ["Pounce"]               = "stun",
    ["Bash"]                 = "stun",
    ["Entangling Roots"]     = "root",
    ["Feral Charge Effect"]  = "stun",
    -- Hunter
    ["Wyvern Sting"]         = "incap",
    ["Freezing Trap Effect"] = "incap",
    ["Scatter Shot"]         = "disorient",
    ["Intimidation"]         = "stun",
    ["Silencing Shot"]       = "silence",
    ["Concussive Shot"]      = "snare",
    -- Paladin
    ["Hammer of Justice"]    = "stun",
    ["Repentance"]           = "incap",
    ["Turn Evil"]            = "fear",
    -- Shaman
    ["Frost Shock"]          = "snare",
    ["Earthbind"]            = "snare",
    ["Hex"]                  = "incap",  -- not TBC, future-proof
    -- Death Knight (future)
    ["Strangulate"]          = "silence",
    ["Hungering Cold"]       = "incap",
    -- PvP racials
    ["War Stomp"]            = "stun",
    ["Stoneform"]            = nil,
    -- Engineering
    ["Net-o-Matic"]          = "root",
}

----------------------------------------------------------------------
-- PVP trinket item IDs (TBC era). We scan worn slot 13/14 every aura
-- update so we don't have to hardcode itemID exhaustively, but the
-- list lets us identify a trinket without ambiguity.
----------------------------------------------------------------------
local PVP_TRINKET_NAME_HINTS = {
    "Insignia of",         -- Insignia of the Alliance / Horde (TBC honor)
    "Medallion of",        -- Medallion of the Alliance / Horde (TBC arena)
    "PvP Trinket",
}

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------
CC.active = nil  -- { name, icon, expirationTime, duration }
CC.preview = false
CC.frame = nil

----------------------------------------------------------------------
-- Settings defaults (merged into DB via Init)
----------------------------------------------------------------------
local function ensureSettings()
    local s = Deadpool.db.settings
    if s.ccTrackerEnabled == nil then s.ccTrackerEnabled = false end
    if s.ccTrackerLocked  == nil then s.ccTrackerLocked  = false end
    if s.ccTrackerSize    == nil then s.ccTrackerSize    = 96 end
    if s.ccTrackerPos     == nil then s.ccTrackerPos     = nil end
end

----------------------------------------------------------------------
-- PVP trinket detection
----------------------------------------------------------------------
local function findPVPTrinketSlot()
    for _, slot in ipairs({ 13, 14 }) do
        local link = GetInventoryItemLink("player", slot)
        if link then
            local name = link:match("%[(.-)%]") or ""
            for _, hint in ipairs(PVP_TRINKET_NAME_HINTS) do
                if name:find(hint, 1, true) then return slot, name end
            end
        end
    end
    return nil, nil
end

local function getTrinketCooldownRemaining()
    local slot = findPVPTrinketSlot()
    if not slot then return nil end
    local start, dur, enabled = GetInventoryItemCooldown("player", slot)
    if not start or start == 0 or dur == 0 then return 0 end
    local remaining = (start + dur) - GetTime()
    if remaining <= 0 then return 0 end
    return remaining
end

----------------------------------------------------------------------
-- Frame
----------------------------------------------------------------------
function CC:CreateFrame()
    if self.frame then return self.frame end
    local s = Deadpool.db.settings

    local f = CreateFrame("Frame", "DeadpoolCCTracker", UIParent, "BackdropTemplate")
    f:SetSize(s.ccTrackerSize, s.ccTrackerSize)
    if s.ccTrackerPos then
        f:SetPoint(s.ccTrackerPos.point or "CENTER", UIParent,
                   s.ccTrackerPos.relPoint or "CENTER",
                   s.ccTrackerPos.x or 0,
                   s.ccTrackerPos.y or 100)
    else
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
    end
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self)
        if not Deadpool.db.settings.ccTrackerLocked then self:StartMoving() end
    end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local p, _, rp, x, y = self:GetPoint()
        Deadpool.db.settings.ccTrackerPos = { point = p, relPoint = rp, x = x, y = y }
    end)
    f:SetClampedToScreen(true)
    f:SetFrameStrata("HIGH")
    f:Hide()

    -- Backdrop / border
    f:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 2,
    })
    f:SetBackdropColor(0, 0, 0, 0.55)
    f:SetBackdropBorderColor(0.9, 0.1, 0.1, 0.9)

    -- Spell icon
    local icon = f:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", 3, -3)
    icon:SetPoint("BOTTOMRIGHT", -3, 3)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)  -- crop default border
    f.icon = icon

    -- Cooldown swipe
    local cd = CreateFrame("Cooldown", nil, f, "CooldownFrameTemplate")
    cd:SetAllPoints(icon)
    cd:SetReverse(true)
    cd:SetDrawEdge(false)
    cd:SetHideCountdownNumbers(true)
    f.cd = cd

    -- Spell name (top)
    local nameText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    nameText:SetPoint("BOTTOM", f, "TOP", 0, 4)
    nameText:SetShadowOffset(1, -1)
    nameText:SetTextColor(1, 0.9, 0.4)
    f.nameText = nameText

    -- Countdown (overlaid)
    local timerText = f:CreateFontString(nil, "OVERLAY", "NumberFontNormalHuge")
    timerText:SetPoint("CENTER", icon, "CENTER", 0, 0)
    timerText:SetShadowOffset(2, -2)
    timerText:SetTextColor(1, 1, 1)
    f.timerText = timerText

    -- Trinket indicator (bottom-right of icon)
    local trinket = CreateFrame("Frame", nil, f)
    trinket:SetSize(24, 24)
    trinket:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 8, -8)
    local tIcon = trinket:CreateTexture(nil, "ARTWORK")
    tIcon:SetAllPoints()
    tIcon:SetTexture("Interface\\Icons\\INV_Jewelry_TrinketPVP_01")
    tIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    local tBorder = trinket:CreateTexture(nil, "OVERLAY")
    tBorder:SetAllPoints()
    tBorder:SetTexture("Interface\\Buttons\\WHITE8x8")
    tBorder:SetVertexColor(0.2, 1, 0.2, 0)  -- alpha managed below
    -- Use a backdrop frame for the border so we can color it
    local tBg = CreateFrame("Frame", nil, trinket, "BackdropTemplate")
    tBg:SetAllPoints()
    tBg:SetBackdrop({
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 2,
    })
    tBg:SetBackdropBorderColor(0.2, 1, 0.2, 1)
    trinket.bg = tBg
    trinket.icon = tIcon
    trinket.cdText = trinket:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    trinket.cdText:SetPoint("CENTER")
    trinket.cdText:SetTextColor(1, 0.3, 0.3)
    f.trinket = trinket

    -- Glow overlay (pulses when active)
    local glow = f:CreateTexture(nil, "OVERLAY")
    glow:SetAllPoints()
    glow:SetTexture("Interface\\Buttons\\WHITE8x8")
    glow:SetBlendMode("ADD")
    glow:SetVertexColor(1, 0.2, 0.2, 0)
    f.glow = glow
    local ag = glow:CreateAnimationGroup()
    ag:SetLooping("BOUNCE")
    local a = ag:CreateAnimation("Alpha")
    a:SetFromAlpha(0)
    a:SetToAlpha(0.35)
    a:SetDuration(0.6)
    a:SetSmoothing("IN_OUT")
    f.glowAg = ag

    -- Updater
    f:SetScript("OnUpdate", function() CC:OnUpdate() end)

    self.frame = f
    return f
end

----------------------------------------------------------------------
-- Aura scan: walk player debuffs and stop at the first CC match.
-- Returns name, icon, expirationTime, duration  (or nil)
----------------------------------------------------------------------
local function scanForCC()
    for i = 1, 40 do
        local name, _, icon, _, _, duration, expirationTime = UnitDebuff("player", i)
        if not name then break end
        if CC_SPELLS[name] then
            return name, icon, expirationTime, duration
        end
    end
    return nil
end

----------------------------------------------------------------------
-- Show / Hide / Refresh
----------------------------------------------------------------------
function CC:SetCC(name, icon, expirationTime, duration)
    local f = self.frame
    if not f then return end
    f.icon:SetTexture(icon)
    f.nameText:SetText(name)
    if duration and duration > 0 and expirationTime then
        f.cd:SetCooldown(expirationTime - duration, duration)
    else
        f.cd:Clear()
    end
    self.active = {
        name = name, icon = icon,
        expirationTime = expirationTime, duration = duration,
    }
    f:Show()
    if f.glowAg and not f.glowAg:IsPlaying() then f.glowAg:Play() end
end

function CC:ClearCC()
    self.active = nil
    if not self.preview then
        if self.frame then
            if self.frame.glowAg and self.frame.glowAg:IsPlaying() then self.frame.glowAg:Stop() end
            self.frame.glow:SetVertexColor(1, 0.2, 0.2, 0)
            self.frame:Hide()
        end
    end
end

function CC:OnUpdate()
    local f = self.frame
    if not f then return end

    -- Countdown text
    if self.active and self.active.expirationTime then
        local r = self.active.expirationTime - GetTime()
        if r > 0 then
            if r >= 10 then f.timerText:SetText(string.format("%d", r))
            else            f.timerText:SetText(string.format("%.1f", r)) end
        else
            f.timerText:SetText("")
            self:ClearCC()
            return
        end
    elseif self.preview then
        f.timerText:SetText("4.2")
    else
        f.timerText:SetText("")
    end

    -- Trinket cooldown indicator
    local rem = getTrinketCooldownRemaining()
    if rem == nil then
        f.trinket:Hide()
    else
        f.trinket:Show()
        if rem <= 0 then
            -- Ready to escape — green pulse
            f.trinket.bg:SetBackdropBorderColor(0.2, 1, 0.2, 1)
            f.trinket.icon:SetDesaturated(false)
            f.trinket.cdText:SetText("")
        else
            -- On cooldown — red, show seconds
            f.trinket.bg:SetBackdropBorderColor(1, 0.2, 0.2, 0.95)
            f.trinket.icon:SetDesaturated(true)
            f.trinket.cdText:SetText(string.format("%d", math.ceil(rem)))
        end
    end
end

----------------------------------------------------------------------
-- Preview (forces icon to show for positioning)
----------------------------------------------------------------------
function CC:SetPreview(on)
    self.preview = on and true or false
    if self.preview then
        self:CreateFrame()
        self.frame:Show()
        self.frame.icon:SetTexture("Interface\\Icons\\Spell_Nature_Polymorph")
        self.frame.nameText:SetText("Polymorph (preview)")
        self.frame.cd:Clear()
        if self.frame.glowAg and not self.frame.glowAg:IsPlaying() then self.frame.glowAg:Play() end
    else
        self:ClearCC()
    end
end

----------------------------------------------------------------------
-- Size + lock
----------------------------------------------------------------------
function CC:SetSize(px)
    px = math.max(40, math.min(220, tonumber(px) or 96))
    Deadpool.db.settings.ccTrackerSize = px
    if self.frame then self.frame:SetSize(px, px) end
end

function CC:SetLocked(locked)
    Deadpool.db.settings.ccTrackerLocked = locked and true or false
end

----------------------------------------------------------------------
-- Enable / disable
----------------------------------------------------------------------
function CC:SetEnabled(on)
    Deadpool.db.settings.ccTrackerEnabled = on and true or false
    if on then
        self:CreateFrame()
        -- Initial scan in case we're already CCd
        local n, ic, exp, dur = scanForCC()
        if n then self:SetCC(n, ic, exp, dur) end
    else
        self:SetPreview(false)
        self:ClearCC()
        if self.frame then self.frame:Hide() end
    end
end

----------------------------------------------------------------------
-- Event hooks
----------------------------------------------------------------------
local function onAura(_, unit)
    if not Deadpool.db.settings.ccTrackerEnabled then return end
    if unit and unit ~= "player" then return end
    local n, ic, exp, dur = scanForCC()
    if n then
        -- If new spell or expiry shifted significantly, push update
        local a = CC.active
        if not a or a.name ~= n or math.abs((a.expirationTime or 0) - (exp or 0)) > 0.1 then
            CC:SetCC(n, ic, exp, dur)
        end
    else
        if CC.active then CC:ClearCC() end
    end
end

function CC:Init()
    ensureSettings()
    -- Hook unit aura (TBC: UNIT_AURA fires for "player" on debuff changes)
    Deadpool:RegisterEvent("UNIT_AURA", onAura)
    Deadpool:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        if Deadpool.db.settings.ccTrackerEnabled then
            self:CreateFrame()
            onAura("UNIT_AURA", "player")
        end
    end)

    -- If enabled persists from last session, build frame so it's ready
    if Deadpool.db.settings.ccTrackerEnabled then
        self:CreateFrame()
    end
end
