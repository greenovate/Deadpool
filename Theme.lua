----------------------------------------------------------------------
-- Deadpool - Theme.lua
-- Theme engine with ElvUI auto-detection, preset themes, and accent
-- color system. Provides backdrop/font/color helpers used by UI.lua.
----------------------------------------------------------------------

local Theme = {}
Deadpool:RegisterModule("Theme", Theme)

----------------------------------------------------------------------
-- ElvUI detection
----------------------------------------------------------------------
Theme.isElvUI = false
Theme.elvModule = nil

function Theme:DetectElvUI()
    -- ElvUI exposes: _G.ElvUI = Engine table, ElvUI[1] = E (the AceAddon object)
    -- E.media has resolved colors/fonts after E:UpdateMedia() runs
    if ElvUI and ElvUI[1] then
        self.isElvUI = true
        self.elvModule = ElvUI[1]
        return true
    end
    self.isElvUI = false
    self.elvModule = nil
    return false
end

----------------------------------------------------------------------
-- Preset themes
----------------------------------------------------------------------
Theme.presets = {
    deadpool = {
        name = "Deadpool",
        accent       = { 0.80, 0.00, 0.00 },  -- Red
        accentDark   = { 0.50, 0.00, 0.00 },
        accentLight  = { 1.00, 0.30, 0.30 },
        bg           = { 0.06, 0.06, 0.06, 0.92 },
        bgAlt        = { 0.10, 0.10, 0.10, 0.95 },
        headerBg     = { 0.12, 0.03, 0.03, 0.95 },
        rowAlt       = { 0.10, 0.04, 0.04, 0.40 },
        border       = { 0.40, 0.00, 0.00, 0.80 },
        text         = { 0.90, 0.90, 0.90 },
        textDim      = { 0.55, 0.55, 0.55 },
        tabActive    = { 0.50, 0.05, 0.05, 0.95 },
        tabInactive  = { 0.12, 0.12, 0.12, 0.90 },
        tabTextActive   = { 1, 0.35, 0.35 },
        tabTextInactive = { 0.65, 0.65, 0.65 },
        positive     = { 0.20, 0.85, 0.20 },
        negative     = { 0.90, 0.20, 0.20 },
        gold         = { 1.00, 0.84, 0.00 },
        barBg        = { 0.15, 0.15, 0.15, 0.80 },
        barFill      = { 0.80, 0.10, 0.10, 1.00 },
    },
    shadow = {
        name = "Shadow",
        accent       = { 0.40, 0.20, 0.65 },
        accentDark   = { 0.25, 0.10, 0.45 },
        accentLight  = { 0.60, 0.40, 0.85 },
        bg           = { 0.05, 0.04, 0.08, 0.94 },
        bgAlt        = { 0.08, 0.06, 0.12, 0.95 },
        headerBg     = { 0.08, 0.04, 0.14, 0.95 },
        rowAlt       = { 0.08, 0.04, 0.12, 0.40 },
        border       = { 0.35, 0.15, 0.55, 0.80 },
        text         = { 0.88, 0.88, 0.92 },
        textDim      = { 0.50, 0.50, 0.58 },
        tabActive    = { 0.30, 0.12, 0.50, 0.95 },
        tabInactive  = { 0.10, 0.08, 0.15, 0.90 },
        tabTextActive   = { 0.80, 0.60, 1.00 },
        tabTextInactive = { 0.55, 0.50, 0.65 },
        positive     = { 0.40, 0.80, 0.40 },
        negative     = { 0.85, 0.25, 0.25 },
        gold         = { 1.00, 0.84, 0.00 },
        barBg        = { 0.12, 0.08, 0.18, 0.80 },
        barFill      = { 0.50, 0.20, 0.75, 1.00 },
    },
    military = {
        name = "Military",
        accent       = { 0.35, 0.50, 0.25 },
        accentDark   = { 0.20, 0.30, 0.12 },
        accentLight  = { 0.50, 0.70, 0.35 },
        bg           = { 0.06, 0.07, 0.05, 0.94 },
        bgAlt        = { 0.09, 0.10, 0.07, 0.95 },
        headerBg     = { 0.06, 0.10, 0.04, 0.95 },
        rowAlt       = { 0.06, 0.09, 0.04, 0.40 },
        border       = { 0.30, 0.45, 0.20, 0.80 },
        text         = { 0.85, 0.88, 0.80 },
        textDim      = { 0.50, 0.55, 0.45 },
        tabActive    = { 0.25, 0.38, 0.15, 0.95 },
        tabInactive  = { 0.10, 0.12, 0.08, 0.90 },
        tabTextActive   = { 0.60, 0.85, 0.40 },
        tabTextInactive = { 0.50, 0.55, 0.45 },
        positive     = { 0.40, 0.80, 0.30 },
        negative     = { 0.85, 0.30, 0.20 },
        gold         = { 0.95, 0.80, 0.20 },
        barBg        = { 0.10, 0.12, 0.08, 0.80 },
        barFill      = { 0.35, 0.55, 0.20, 1.00 },
    },
    frost = {
        name = "Frost",
        accent       = { 0.20, 0.55, 0.80 },
        accentDark   = { 0.10, 0.35, 0.55 },
        accentLight  = { 0.40, 0.75, 1.00 },
        bg           = { 0.04, 0.06, 0.09, 0.94 },
        bgAlt        = { 0.06, 0.08, 0.12, 0.95 },
        headerBg     = { 0.04, 0.08, 0.14, 0.95 },
        rowAlt       = { 0.04, 0.08, 0.12, 0.40 },
        border       = { 0.15, 0.45, 0.70, 0.80 },
        text         = { 0.85, 0.90, 0.95 },
        textDim      = { 0.45, 0.55, 0.65 },
        tabActive    = { 0.10, 0.35, 0.55, 0.95 },
        tabInactive  = { 0.08, 0.10, 0.15, 0.90 },
        tabTextActive   = { 0.50, 0.85, 1.00 },
        tabTextInactive = { 0.45, 0.55, 0.65 },
        positive     = { 0.30, 0.80, 0.45 },
        negative     = { 0.85, 0.25, 0.25 },
        gold         = { 1.00, 0.84, 0.00 },
        barBg        = { 0.06, 0.10, 0.16, 0.80 },
        barFill      = { 0.20, 0.55, 0.85, 1.00 },
    },
    blood = {
        name = "Blood & Gold",
        accent       = { 0.75, 0.15, 0.10 },
        accentDark   = { 0.50, 0.08, 0.05 },
        accentLight  = { 0.95, 0.30, 0.25 },
        bg           = { 0.07, 0.04, 0.03, 0.94 },
        bgAlt        = { 0.10, 0.06, 0.04, 0.95 },
        headerBg     = { 0.14, 0.06, 0.03, 0.95 },
        rowAlt       = { 0.12, 0.05, 0.03, 0.40 },
        border       = { 0.70, 0.55, 0.10, 0.80 },
        text         = { 0.92, 0.88, 0.82 },
        textDim      = { 0.58, 0.52, 0.45 },
        tabActive    = { 0.55, 0.10, 0.05, 0.95 },
        tabInactive  = { 0.12, 0.08, 0.06, 0.90 },
        tabTextActive   = { 1.00, 0.75, 0.15 },
        tabTextInactive = { 0.60, 0.52, 0.42 },
        positive     = { 0.50, 0.85, 0.30 },
        negative     = { 0.90, 0.15, 0.10 },
        gold         = { 1.00, 0.80, 0.10 },
        barBg        = { 0.14, 0.08, 0.04, 0.80 },
        barFill      = { 0.80, 0.20, 0.10, 1.00 },
    },
    elvui = {
        name = "ElvUI",
        accent       = { 0.00, 0.70, 0.90 },
        accentDark   = { 0.00, 0.45, 0.60 },
        accentLight  = { 0.30, 0.85, 1.00 },
        bg           = { 0.05, 0.05, 0.05, 0.92 },
        bgAlt        = { 0.08, 0.08, 0.08, 0.95 },
        headerBg     = { 0.04, 0.08, 0.12, 0.95 },
        rowAlt       = { 0.06, 0.06, 0.08, 0.40 },
        border       = { 0.00, 0.00, 0.00, 1.00 },
        text         = { 0.84, 0.84, 0.84 },
        textDim      = { 0.50, 0.50, 0.50 },
        tabActive    = { 0.00, 0.50, 0.65, 0.95 },
        tabInactive  = { 0.10, 0.10, 0.10, 0.90 },
        tabTextActive   = { 0.30, 0.90, 1.00 },
        tabTextInactive = { 0.55, 0.55, 0.55 },
        positive     = { 0.30, 0.85, 0.30 },
        negative     = { 0.85, 0.25, 0.25 },
        gold         = { 1.00, 0.84, 0.00 },
        barBg        = { 0.08, 0.08, 0.08, 0.80 },
        barFill      = { 0.00, 0.65, 0.85, 1.00 },
    },
}

-- Ordered list for dropdown
Theme.presetOrder = { "deadpool", "shadow", "military", "frost", "blood", "elvui" }

----------------------------------------------------------------------
-- Active theme (populated on Init)
----------------------------------------------------------------------
Theme.active = nil

function Theme:Init()
    self:DetectElvUI()
    self:ApplyTheme()
end

function Theme:ApplyTheme()
    local key = Deadpool.db.settings.theme or "deadpool"
    if not self.presets[key] then key = "deadpool" end

    -- Deep copy the preset so we don't mutate originals
    self.active = {}
    for k, v in pairs(self.presets[key]) do
        if type(v) == "table" then
            self.active[k] = {}
            for i, val in ipairs(v) do self.active[k][i] = val end
        else
            self.active[k] = v
        end
    end

    -- If theme is "elvui" and ElvUI is present, pull live colors from E.media
    if key == "elvui" and self.isElvUI and self.elvModule then
        local E = self.elvModule
        -- E.media is populated after E:UpdateMedia()
        if E.media then
            if E.media.backdropcolor then
                local c = E.media.backdropcolor
                self.active.bg = { c.r or c[1] or 0.05, c.g or c[2] or 0.05, c.b or c[3] or 0.05, 0.92 }
            end
            if E.media.backdropfadecolor then
                local c = E.media.backdropfadecolor
                self.active.bgAlt = { c.r or c[1] or 0.08, c.g or c[2] or 0.08, c.b or c[3] or 0.08, c.a or c[4] or 0.85 }
            end
            if E.media.bordercolor then
                local c = E.media.bordercolor
                self.active.border = { c.r or c[1] or 0, c.g or c[2] or 0, c.b or c[3] or 0, 1 }
            end
            if E.media.rgbvaluecolor then
                local c = E.media.rgbvaluecolor
                self.active.accent = { c.r or c[1] or 0, c.g or c[2] or 0.7, c.b or c[3] or 0.9 }
                self.active.tabTextActive = { c.r or c[1] or 0.3, c.g or c[2] or 0.9, c.b or c[3] or 1 }
                self.active.barFill = { c.r or c[1] or 0, c.g or c[2] or 0.65, c.b or c[3] or 0.85, 1 }
            end
        end
    end
end

function Theme:GetThemeName()
    return self.active and self.active.name or "Deadpool"
end

function Theme:CycleTheme(direction)
    local current = Deadpool.db.settings.theme or "deadpool"
    local idx = 1
    for i, key in ipairs(self.presetOrder) do
        if key == current then idx = i; break end
    end
    if direction > 0 then
        idx = idx + 1
        if idx > #self.presetOrder then idx = 1 end
    else
        idx = idx - 1
        if idx < 1 then idx = #self.presetOrder end
    end
    Deadpool.db.settings.theme = self.presetOrder[idx]
    self:ApplyTheme()
    Deadpool:Print("Theme: " .. self.active.name)
    if Deadpool.RefreshUI then Deadpool:RefreshUI() end
end

----------------------------------------------------------------------
-- Backdrop helpers (ElvUI-aware)
----------------------------------------------------------------------
function Theme:CreateBackdrop(frame)
    local t = self.active
    if not t then return end

    if self.isElvUI and frame.CreateBackdrop then
        -- Use ElvUI's own backdrop system
        frame:CreateBackdrop("Transparent")
        if frame.backdrop then
            frame.backdrop:SetBackdropBorderColor(t.accent[1], t.accent[2], t.accent[3], 0.8)
        end
    else
        -- Standard Blizzard backdrop
        if frame.SetBackdrop then
            frame:SetBackdrop({
                bgFile = "Interface\\Buttons\\WHITE8x8",
                edgeFile = "Interface\\Buttons\\WHITE8x8",
                edgeSize = 1,
                insets = { left = 0, right = 0, top = 0, bottom = 0 },
            })
            frame:SetBackdropColor(t.bg[1], t.bg[2], t.bg[3], t.bg[4])
            frame:SetBackdropBorderColor(t.border[1], t.border[2], t.border[3], t.border[4])
        end
    end
end

function Theme:StyleButton(btn)
    local t = self.active
    if not t then return end

    if self.isElvUI and btn.CreateBackdrop then
        btn:CreateBackdrop("Default")
    elseif btn.SetBackdrop then
        btn:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
        })
        btn:SetBackdropColor(t.accent[1] * 0.4, t.accent[2] * 0.4, t.accent[3] * 0.4, 0.85)
        btn:SetBackdropBorderColor(t.accent[1], t.accent[2], t.accent[3], 0.6)
    end
end

----------------------------------------------------------------------
-- Font helpers (uses ElvUI's resolved font when available)
----------------------------------------------------------------------
function Theme:GetFont(size, flags)
    size = size or 12
    flags = flags or ""
    if self.isElvUI and self.elvModule then
        -- E.media.normFont is the resolved font path from LSM
        local font = self.elvModule.media and self.elvModule.media.normFont
        if font then return font, size, flags end
    end
    return "Fonts\\FRIZQT__.TTF", size, flags
end

function Theme:GetHeaderFont()
    return self:GetFont(13, "OUTLINE")
end

function Theme:GetBodyFont()
    return self:GetFont(11, "")
end

function Theme:GetTitleFont()
    return self:GetFont(18, "OUTLINE")
end

----------------------------------------------------------------------
-- Color accessors with hex string generation
----------------------------------------------------------------------
function Theme:Accent()
    return self.active.accent[1], self.active.accent[2], self.active.accent[3]
end

function Theme:AccentHex()
    local r, g, b = self:Accent()
    return string.format("|cFF%02X%02X%02X", r * 255, g * 255, b * 255)
end

function Theme:ColorText(text, colorKey)
    local c = self.active[colorKey]
    if not c then return text end
    return string.format("|cFF%02X%02X%02X%s|r", c[1] * 255, c[2] * 255, c[3] * 255, text)
end
