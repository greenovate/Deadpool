----------------------------------------------------------------------
-- Deadpool - DRTracker.lua
-- Diminishing Returns tracker. Per-enemy table of active DR categories.
-- Each entry: spell icon + diminish tier (Full / 1/2 / 1/4 / Immune) +
-- reverse loading bar counting down to DR reset. Tracks CCs cast by
-- the player AND any party member.
----------------------------------------------------------------------

local DR = {}
Deadpool:RegisterModule("DRTracker", DR)

----------------------------------------------------------------------
-- Combat log flag bits
----------------------------------------------------------------------
local AFFILIATION_MINE  = 0x00000001
local AFFILIATION_PARTY = 0x00000002
local AFFILIATION_RAID  = 0x00000004
local TYPE_PLAYER       = 0x00000400
local REACTION_HOSTILE  = 0x00000040

local DR_RESET_WINDOW = 15  -- seconds after aura ends before tier resets to 1

----------------------------------------------------------------------
-- Category map (spell name -> DR category) — TBC validated
-- Groups confirmed against TBC arena DR documentation (Diminish-TBC
-- addon and community references). Several CCs have their OWN DR
-- (Cyclone, Mind Control, Banish, Horror/Death Coil) and don't share
-- with the broader incap bucket.
----------------------------------------------------------------------
local DR_CATEGORY = {
    -- Incapacitate (shared DR bucket)
    ["Sap"]                    = "incap",
    ["Gouge"]                  = "incap",
    ["Polymorph"]              = "incap",
    ["Polymorph: Pig"]         = "incap",
    ["Polymorph: Turtle"]      = "incap",
    ["Polymorph: Black Cat"]   = "incap",
    ["Hibernate"]              = "incap",
    ["Repentance"]             = "incap",
    ["Wyvern Sting"]           = "incap",
    ["Freezing Trap Effect"]   = "incap",

    -- Solo-DR CCs (each is its OWN diminishing return)
    ["Cyclone"]                = "cyclone",
    ["Mind Control"]           = "mindcontrol",
    ["Banish"]                 = "banish",
    ["Death Coil"]             = "horror",

    -- Fear (shared)
    ["Fear"]                   = "fear",
    ["Howl of Terror"]         = "fear",
    ["Psychic Scream"]         = "fear",
    ["Intimidating Shout"]     = "fear",
    ["Scare Beast"]            = "fear",
    ["Turn Evil"]              = "fear",
    ["Seduction"]              = "fear",

    -- Stun (shared)
    ["Cheap Shot"]             = "stun",
    ["Kidney Shot"]            = "stun",
    ["Pounce"]                 = "stun",
    ["Maim"]                   = "stun",   -- Druid Maim is a stun in TBC
    ["Bash"]                   = "stun",
    ["Hammer of Justice"]      = "stun",
    ["Concussion Blow"]        = "stun",
    ["War Stomp"]              = "stun",
    ["Intimidation"]           = "stun",
    ["Charge Stun"]            = "stun",
    ["Intercept Stun"]         = "stun",
    ["Shadowfury"]             = "stun",
    ["Impact"]                 = "stun",
    ["Blackout"]               = "stun",
    ["Mace Stun Effect"]       = "stun",
    ["Feral Charge Effect"]    = "stun",
    ["Stoneclaw Stun"]         = "stun",
    ["Aftermath"]              = "stun",   -- destruction warlock talent proc

    -- Disorient (shared)
    ["Blind"]                  = "disorient",
    ["Scatter Shot"]           = "disorient",
    ["Dragon's Breath"]        = "disorient",

    -- Root (shared)
    ["Entangling Roots"]       = "root",
    ["Frost Nova"]             = "root",
    ["Frostbite"]              = "root",
    ["Improved Wing Clip"]     = "root",
    ["Improved Hamstring"]     = "root",

    -- Silence (shared)
    ["Silence"]                = "silence",
    ["Garrote - Silence"]      = "silence",
    ["Silencing Shot"]         = "silence",
    ["Improved Counterspell"]  = "silence",

    -- Disarm (shared)
    ["Disarm"]                 = "disarm",
    ["Riposte"]                = "disarm",
    ["Dismantle"]              = "disarm",
}

-- Spell -> class owner (which class CAN cast this CC, regardless of spec/talent).
-- Racials and certain procs use "*" meaning "anyone can have it".
local SPELL_CLASS = {
    -- Stun
    ["Cheap Shot"]            = "ROGUE",
    ["Kidney Shot"]           = "ROGUE",
    ["Pounce"]                = "DRUID",
    ["Maim"]                  = "DRUID",
    ["Bash"]                  = "DRUID",
    ["Hammer of Justice"]     = "PALADIN",
    ["Concussion Blow"]       = "WARRIOR",
    ["War Stomp"]             = "*",       -- Tauren racial
    ["Intimidation"]          = "HUNTER",
    ["Charge Stun"]           = "WARRIOR",
    ["Intercept Stun"]        = "WARRIOR",
    ["Shadowfury"]            = "WARLOCK",
    ["Impact"]                = "MAGE",
    ["Blackout"]              = "PRIEST",
    ["Mace Stun Effect"]      = "*",       -- mace spec proc (rogue/warrior)
    ["Feral Charge Effect"]   = "DRUID",
    ["Stoneclaw Stun"]        = "SHAMAN",
    ["Aftermath"]             = "WARLOCK",
    -- Incapacitate
    ["Sap"]                   = "ROGUE",
    ["Gouge"]                 = "ROGUE",
    ["Polymorph"]             = "MAGE",
    ["Hibernate"]             = "DRUID",
    ["Repentance"]            = "PALADIN",
    ["Wyvern Sting"]          = "HUNTER",
    ["Freezing Trap Effect"]  = "HUNTER",
    -- Solo DRs
    ["Cyclone"]               = "DRUID",
    ["Mind Control"]          = "PRIEST",
    ["Banish"]                = "WARLOCK",
    ["Death Coil"]            = "WARLOCK",
    -- Fear
    ["Fear"]                  = "WARLOCK",
    ["Howl of Terror"]        = "WARLOCK",
    ["Psychic Scream"]        = "PRIEST",
    ["Intimidating Shout"]    = "WARRIOR",
    ["Scare Beast"]           = "HUNTER",
    ["Turn Evil"]             = "PALADIN",
    ["Seduction"]             = "WARLOCK",
    -- Disorient
    ["Blind"]                 = "ROGUE",
    ["Scatter Shot"]          = "HUNTER",
    ["Dragon's Breath"]       = "MAGE",
    -- Root
    ["Entangling Roots"]      = "DRUID",
    ["Frost Nova"]            = "MAGE",
    ["Frostbite"]             = "MAGE",
    ["Improved Wing Clip"]    = "HUNTER",
    ["Improved Hamstring"]    = "WARRIOR",
    -- Silence
    ["Silence"]               = "PRIEST",
    ["Garrote - Silence"]     = "ROGUE",
    ["Silencing Shot"]        = "HUNTER",
    ["Improved Counterspell"] = "MAGE",
    -- Disarm
    ["Disarm"]                = "WARRIOR",
    ["Riposte"]               = "ROGUE",
    ["Dismantle"]             = "ROGUE",
}

-- Build category -> sorted spell list lookup (now that DR_CATEGORY exists).
-- Dedupe polymorph variants because the icons are nearly identical.
local POLY_VARIANTS = {
    ["Polymorph: Pig"]       = true,
    ["Polymorph: Turtle"]    = true,
    ["Polymorph: Black Cat"] = true,
}
local CATEGORY_SPELLS = {}
do
    for spell, cat in pairs(DR_CATEGORY) do
        if not POLY_VARIANTS[spell] then
            CATEGORY_SPELLS[cat] = CATEGORY_SPELLS[cat] or {}
            table.insert(CATEGORY_SPELLS[cat], spell)
        end
    end
    for _, list in pairs(CATEGORY_SPELLS) do table.sort(list) end
end

----------------------------------------------------------------------
-- Active class set: which classes are in the player's current party.
-- The DR strip shows ONLY spells castable by these classes (plus "*"
-- spells like racials). Refreshed on roster updates.
----------------------------------------------------------------------
local ACTIVE_CLASSES = {}  -- [classToken] = true
local function refreshActiveClasses()
    local s = {}
    -- Always include player's own class
    local _, myClass = UnitClass("player")
    if myClass then s[myClass] = true end
    if IsInGroup and IsInGroup() then
        for i = 1, 4 do
            local u = "party" .. i
            if UnitExists(u) then
                local _, c = UnitClass(u)
                if c then s[c] = true end
            end
        end
    end
    -- Arena opponents count too — useful to see the spells they might use
    for i = 1, 5 do
        local u = "arena" .. i
        if UnitExists(u) then
            local _, c = UnitClass(u)
            if c then s[c] = true end
        end
    end
    ACTIVE_CLASSES = s
end

-- Preview-mode override (set in SetPreview); when set, takes priority.
local PREVIEW_CLASSES = nil

local function isSpellInActiveSet(spellName)
    local owner = SPELL_CLASS[spellName]
    if not owner or owner == "*" then return true end
    local set = PREVIEW_CLASSES or ACTIVE_CLASSES
    return set[owner] == true
end

-- Cached spell icons. Look up by spell ID first (works for all spells
-- regardless of whether the player knows them), fall back to name.
-- Without IDs, GetSpellInfo("Kidney Shot") on a mage returns nil and
-- you only see your own class's icons in the DR strip.
local SPELL_ID = {
    -- Stun
    ["Cheap Shot"]            = 1833,    -- Rogue
    ["Kidney Shot"]           = 408,     -- Rogue
    ["Pounce"]                = 9005,    -- Druid (cat)
    ["Maim"]                  = 22570,   -- Druid (cat) - TBC stun
    ["Bash"]                  = 5211,    -- Druid (bear)
    ["Hammer of Justice"]     = 853,     -- Paladin
    ["Concussion Blow"]       = 12809,   -- Warrior
    ["War Stomp"]             = 20549,   -- Tauren racial
    ["Intimidation"]          = 19577,   -- Hunter
    ["Charge Stun"]           = 7922,    -- Warrior charge stun
    ["Intercept Stun"]        = 20253,   -- Warrior intercept stun
    ["Shadowfury"]            = 30283,   -- Warlock
    ["Impact"]                = 12355,   -- Mage talent proc
    ["Blackout"]              = 15269,   -- Priest talent proc
    ["Mace Stun Effect"]      = 5530,    -- Mace specialization
    ["Feral Charge Effect"]   = 16979,   -- Druid (bear)
    ["Stoneclaw Stun"]        = 39796,   -- Shaman stoneclaw totem
    ["Aftermath"]             = 18118,   -- Warlock talent proc
    -- Incapacitate
    ["Sap"]                   = 6770,    -- Rogue
    ["Gouge"]                 = 1776,    -- Rogue
    ["Polymorph"]             = 118,     -- Mage
    ["Hibernate"]             = 2637,    -- Druid
    ["Repentance"]            = 20066,   -- Paladin Ret
    ["Wyvern Sting"]          = 19386,   -- Hunter Survival
    ["Freezing Trap Effect"]  = 3355,    -- Hunter
    -- Solo DRs
    ["Cyclone"]               = 33786,   -- Druid Resto
    ["Mind Control"]          = 605,     -- Priest
    ["Banish"]                = 710,     -- Warlock
    ["Death Coil"]            = 6789,    -- Warlock
    -- Fear
    ["Fear"]                  = 5782,    -- Warlock
    ["Howl of Terror"]        = 5484,    -- Warlock
    ["Psychic Scream"]        = 8122,    -- Priest
    ["Intimidating Shout"]    = 5246,    -- Warrior
    ["Scare Beast"]           = 1513,    -- Hunter
    ["Turn Evil"]             = 10326,   -- Paladin
    ["Seduction"]             = 6358,    -- Warlock Succubus
    -- Disorient
    ["Blind"]                 = 2094,    -- Rogue
    ["Scatter Shot"]          = 19503,   -- Hunter
    ["Dragon's Breath"]       = 31661,   -- Mage
    -- Root
    ["Entangling Roots"]      = 339,     -- Druid
    ["Frost Nova"]            = 122,     -- Mage
    ["Frostbite"]             = 12494,   -- Mage talent proc
    ["Improved Wing Clip"]    = 19229,   -- Hunter Survival
    ["Improved Hamstring"]    = 23693,   -- Warrior Arms talent
    -- Silence
    ["Silence"]               = 15487,   -- Priest Shadow
    ["Garrote - Silence"]     = 1330,    -- Rogue (Improved Garrote)
    ["Silencing Shot"]        = 34490,   -- Hunter Marks
    ["Improved Counterspell"] = 18469,   -- Mage talent
    -- Disarm
    ["Disarm"]                = 676,     -- Warrior
    ["Riposte"]               = 14251,   -- Rogue
    ["Dismantle"]             = 51722,   -- Rogue (later expansion)
}

local SPELL_ICON_CACHE = {}
local function getSpellIcon(spellName)
    local cached = SPELL_ICON_CACHE[spellName]
    if cached then return cached end
    local icon
    local id = SPELL_ID[spellName]
    if id then
        icon = select(3, GetSpellInfo(id))
    end
    if not icon then
        icon = select(3, GetSpellInfo(spellName))
    end
    if icon then SPELL_ICON_CACHE[spellName] = icon end
    return icon or "Interface\\Icons\\INV_Misc_QuestionMark"
end

-- Fallback durations (seconds) when we can't read the live aura
local FALLBACK_DURATION = {
    ["Sap"]                  = 10,
    ["Gouge"]                = 4,
    ["Polymorph"]            = 8,
    ["Polymorph: Pig"]       = 8,
    ["Polymorph: Turtle"]    = 8,
    ["Hibernate"]            = 8,
    ["Cyclone"]              = 6,
    ["Repentance"]           = 6,
    ["Wyvern Sting"]         = 12,
    ["Freezing Trap Effect"] = 10,
    ["Maim"]                 = 5,
    ["Shackle Undead"]       = 8,
    ["Mind Control"]         = 8,
    ["Banish"]               = 8,
    ["Seduction"]            = 8,
    ["Hex"]                  = 8,
    ["Fear"]                 = 8,
    ["Howl of Terror"]       = 8,
    ["Psychic Scream"]       = 8,
    ["Intimidating Shout"]   = 8,
    ["Scare Beast"]          = 8,
    ["Turn Evil"]            = 8,
    ["Cheap Shot"]           = 4,
    ["Kidney Shot"]          = 6,
    ["Pounce"]               = 3,
    ["Bash"]                 = 4,
    ["Hammer of Justice"]    = 6,
    ["Concussion Blow"]      = 5,
    ["War Stomp"]            = 2,
    ["Intimidation"]         = 3,
    ["Charge Stun"]          = 1.5,
    ["Blackout"]             = 3,
    ["Shadowfury"]           = 3,
    ["Mace Stun Effect"]     = 3,
    ["Feral Charge Effect"]  = 4,
    ["Impact"]               = 2,
    ["Blind"]                = 10,
    ["Scatter Shot"]         = 4,
    ["Dragon's Breath"]      = 3,
    ["Entangling Roots"]     = 9,
    ["Frost Nova"]           = 8,
    ["Frostbite"]            = 5,
    ["Improved Wing Clip"]   = 5,
    ["Silence"]              = 5,
    ["Garrote - Silence"]    = 3,
    ["Counterspell - Silenced"] = 4,
    ["Improved Counterspell"]   = 4,
    ["Silencing Shot"]       = 3,
    ["Spell Lock"]           = 3,
    ["Death Coil"]           = 3,
    ["Disarm"]               = 10,
    ["Riposte"]              = 6,
    ["Dismantle"]            = 10,
}

----------------------------------------------------------------------
-- Tier display
----------------------------------------------------------------------
local TIER_TEXT = { [1] = "1",  [2] = "\194\189",  [3] = "\194\188",  [4] = "X" } -- 1, ½, ¼, X
local TIER_COLOR = {
    [1] = { 0.50, 1.00, 0.50 },
    [2] = { 1.00, 0.95, 0.30 },
    [3] = { 1.00, 0.55, 0.20 },
    [4] = { 1.00, 0.20, 0.20 },
}

local CATEGORY_INFO = {
    stun        = { label = "STUN",       color = { 1.00, 0.50, 0.20 } },
    incap       = { label = "INCAP",      color = { 1.00, 0.85, 0.30 } },
    fear        = { label = "FEAR",       color = { 0.65, 0.40, 1.00 } },
    disorient   = { label = "DISORIENT",  color = { 0.50, 0.85, 1.00 } },
    silence     = { label = "SILENCE",    color = { 0.75, 0.75, 1.00 } },
    root        = { label = "ROOT",       color = { 0.40, 1.00, 0.60 } },
    horror      = { label = "HORROR",     color = { 0.85, 0.30, 0.85 } },
    disarm      = { label = "DISARM",     color = { 1.00, 0.50, 0.50 } },
    cyclone     = { label = "CYCLONE",    color = { 0.40, 0.90, 0.40 } },
    mindcontrol = { label = "MIND CTRL",  color = { 0.95, 0.30, 0.95 } },
    banish      = { label = "BANISH",     color = { 0.55, 0.70, 1.00 } },
}

local CATEGORY_ORDER = { "stun", "incap", "fear", "horror", "disorient", "silence", "root", "disarm", "cyclone", "mindcontrol", "banish" }

----------------------------------------------------------------------
-- State
-- DR.state[destGUID] = {
--     name = "Player",
--     class = "ROGUE",
--     drs = {
--         [category] = { tier, resetTime, expirationTime, icon, spellName }
--     },
-- }
----------------------------------------------------------------------
DR.state = {}
DR.preview = false

----------------------------------------------------------------------
-- Settings defaults
----------------------------------------------------------------------
local function ensureSettings()
    local s = Deadpool.db.settings
    if s.drTrackerEnabled   == nil then s.drTrackerEnabled   = false end
    if s.drTrackerLocked    == nil then s.drTrackerLocked    = false end
    if s.drTrackerScale     == nil then s.drTrackerScale     = 1.0   end
    if s.drTrackerPartyOnly == nil then s.drTrackerPartyOnly = true  end
    if s.drTrackerPos       == nil then s.drTrackerPos       = nil   end
    -- Per-context toggles (all on by default)
    if s.drTrackerInArena   == nil then s.drTrackerInArena   = true  end
    if s.drTrackerInBG      == nil then s.drTrackerInBG      = true  end
    if s.drTrackerInParty   == nil then s.drTrackerInParty   = true  end
    if s.drTrackerAnnounce  == nil then s.drTrackerAnnounce  = false end
end

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------
local function shortName(name)
    if not name then return nil end
    return name:match("^(.-)%-") or name
end

-- Try to find a unit token whose GUID matches the given GUID, so we
-- can read the live aura duration/expiration.
local SCAN_UNITS = {
    "target", "focus", "mouseover",
    "arena1", "arena2", "arena3", "arena4", "arena5",
    "arenapet1", "arenapet2", "arenapet3", "arenapet4", "arenapet5",
    "nameplate1", "nameplate2", "nameplate3", "nameplate4", "nameplate5",
    "nameplate6", "nameplate7", "nameplate8", "nameplate9", "nameplate10",
}

local function findUnitByGUID(guid)
    if not guid then return nil end
    for _, u in ipairs(SCAN_UNITS) do
        if UnitExists(u) and UnitGUID(u) == guid then return u end
    end
    return nil
end

-- Scan a unit's debuffs for a specific spell name. Returns icon, duration, expirationTime.
local function getAuraInfo(unit, spellName)
    if not unit then return nil end
    for i = 1, 40 do
        local name, _, icon, _, _, duration, expirationTime = UnitDebuff(unit, i)
        if not name then return nil end
        if name == spellName then return icon, duration, expirationTime end
    end
    return nil
end

----------------------------------------------------------------------
-- Apply a DR event (CC was applied to target)
----------------------------------------------------------------------
local function applyDR(destGUID, destName, destFlags, spellName, spellIcon)
    local cat = DR_CATEGORY[spellName]
    if not cat then return end
    if not destGUID then return end

    local now = GetTime()
    local entry = DR.state[destGUID]
    if not entry then
        entry = { name = shortName(destName) or "?", class = nil, drs = {} }
        DR.state[destGUID] = entry
    end
    -- Pull class via unit lookup if we can find it
    local unit = findUnitByGUID(destGUID)
    if unit then
        local _, cls = UnitClass(unit)
        if cls then entry.class = cls end
    end

    -- Determine tier
    local prev = entry.drs[cat]
    local tier = 1
    if prev and prev.resetTime and prev.resetTime > now then
        tier = math.min((prev.tier or 1) + 1, 4)
    end

    -- Read actual aura duration if possible
    local icon, duration, expiration
    if unit then
        icon, duration, expiration = getAuraInfo(unit, spellName)
    end
    if not duration then
        local fallback = FALLBACK_DURATION[spellName] or 4
        -- Apply tier reduction to fallback so the bar isn't wildly off
        local mult = (tier == 1) and 1 or (tier == 2) and 0.5 or (tier == 3) and 0.25 or 0
        duration = fallback * mult
        expiration = now + duration
    end
    -- Tier 4 = immune: no aura applied, but DR is still on cooldown
    if tier >= 4 then
        duration = 0
        expiration = now
    end

    entry.drs[cat] = {
        tier           = tier,
        spellName      = spellName,
        icon           = spellIcon or icon,
        expirationTime = expiration,
        resetTime      = expiration + DR_RESET_WINDOW,
    }

    if DR.frame and DR.frame:IsShown() then DR:Refresh() end
end

----------------------------------------------------------------------
-- Context gate: only show in arenas, party groups, or BGs.
-- Returns: allowed (bool), meOnly (bool) — in BGs only the player's
-- own CCs are tracked to avoid raid-wide spam.
----------------------------------------------------------------------
local function getContext()
    local s = Deadpool.db.settings
    local inInstance, instanceType = IsInInstance()
    if inInstance and instanceType == "arena" then
        if not s.drTrackerInArena then return false, false end
        return true, false
    end
    if inInstance and instanceType == "pvp"   then
        if not s.drTrackerInBG then return false, false end
        return true, true  -- BG: me only
    end
    if IsInGroup and IsInGroup() then
        if IsInRaid and IsInRaid() then return false, false end
        if not s.drTrackerInParty then return false, false end
        return true, false
    end
    return false, false
end

----------------------------------------------------------------------
-- Combat log hook
----------------------------------------------------------------------
local function onCombatLog()
    if not Deadpool.db.settings.drTrackerEnabled then return end
    local allowed, meOnly = getContext()
    if not allowed then return end

    local _, subevent, _, sourceGUID, sourceName, sourceFlags, _,
              destGUID, destName, destFlags, _,
              spellId, spellName = CombatLogGetCurrentEventInfo()

    -- We only care about aura application / refresh / dispel
    if subevent ~= "SPELL_AURA_APPLIED"
       and subevent ~= "SPELL_AURA_REFRESH"
       and subevent ~= "SPELL_AURA_APPLIED_DOSE" then
        return
    end

    -- Skip if not a tracked DR spell
    if not spellName or not DR_CATEGORY[spellName] then return end

    -- Source filter:
    --   In BGs (meOnly): only player's own CCs
    --   Otherwise: respect drTrackerPartyOnly setting (default = party/raid)
    if not sourceFlags then return end
    if meOnly then
        if bit.band(sourceFlags, AFFILIATION_MINE) == 0 then return end
    elseif Deadpool.db.settings.drTrackerPartyOnly then
        local fromUs = (bit.band(sourceFlags, AFFILIATION_MINE)  > 0)
                    or (bit.band(sourceFlags, AFFILIATION_PARTY) > 0)
                    or (bit.band(sourceFlags, AFFILIATION_RAID)  > 0)
        if not fromUs then return end
    end

    -- Destination filter: hostile player target
    if not destFlags then return end
    if bit.band(destFlags, TYPE_PLAYER) == 0 then return end
    if bit.band(destFlags, REACTION_HOSTILE) == 0 then return end

    -- Look up icon via spellId
    local icon = spellId and (select(3, GetSpellInfo(spellId))) or nil
    if not icon then icon = select(3, GetSpellInfo(spellName)) end

    applyDR(destGUID, destName, destFlags, spellName, icon)
end

----------------------------------------------------------------------
-- Announce a DR reset to party chat (suppressed in BGs and solo).
-- Only fires for DRs that actually mattered (tier 2+), to avoid spam.
-- Per-target+category cooldown so we never double-announce.
----------------------------------------------------------------------
local lastAnnounce = {}  -- [guid..cat] = GetTime()
local function announceReset(guid, entry, category, dr)
    if not Deadpool.db.settings.drTrackerAnnounce then return end
    if (dr.tier or 1) < 2 then return end  -- skip Full -> reset, no value

    -- Channel selection: party in party, instance-party in arena, never in BG/solo
    local inInstance, instanceType = IsInInstance()
    local channel
    if inInstance and instanceType == "arena" then
        channel = "INSTANCE_CHAT"
    elseif inInstance and instanceType == "pvp" then
        return  -- never spam BGs
    elseif IsInGroup and IsInGroup() and not (IsInRaid and IsInRaid()) then
        channel = "PARTY"
    else
        return
    end

    -- Dedup
    local key = (guid or "?") .. "|" .. category
    local now = GetTime()
    if lastAnnounce[key] and (now - lastAnnounce[key]) < 5 then return end
    lastAnnounce[key] = now

    local info = CATEGORY_INFO[category] or { label = category:upper() }
    local target = entry.name or "target"
    local msg = string.format("[Deadpool] %s DR reset on %s", info.label, target)
    SendChatMessage(msg, channel)
end

----------------------------------------------------------------------
-- Cleanup expired entries
----------------------------------------------------------------------
local function cleanExpired()
    local now = GetTime()
    local removed = false
    for guid, entry in pairs(DR.state) do
        local any = false
        for cat, dr in pairs(entry.drs) do
            if dr.resetTime <= now then
                -- Skip announcing preview fakes
                if type(guid) ~= "string" or guid:sub(1, 3) ~= "PV-" then
                    announceReset(guid, entry, cat, dr)
                end
                entry.drs[cat] = nil
                removed = true
            else
                any = true
            end
        end
        if not any then
            DR.state[guid] = nil
            removed = true
        end
    end
    return removed
end

----------------------------------------------------------------------
-- UI: aura-bar style. One full-width bar per active DR.
-- Layout per bar:   [icon 28px] [status bar fills rest] [time text]
-- Bar text shows: PlayerName  -  SpellName  (tier)
----------------------------------------------------------------------
local BAR_HEIGHT  = 38   -- tall enough for label + icon strip
local BAR_SPACING = 3
local ICON_SIZE   = BAR_HEIGHT
local FRAME_WIDTH = 420  -- accommodate longest strip (stun bucket has many spells)

function DR:CreateFrame()
    if self.frame then return self.frame end
    local s = Deadpool.db.settings

    local f = CreateFrame("Frame", "DeadpoolDRTracker", UIParent, "BackdropTemplate")
    f:SetSize(FRAME_WIDTH, BAR_HEIGHT * 8 + 24)
    if s.drTrackerPos then
        f:SetPoint(s.drTrackerPos.point or "CENTER", UIParent,
                   s.drTrackerPos.relPoint or "CENTER",
                   s.drTrackerPos.x or 280, s.drTrackerPos.y or 0)
    else
        f:SetPoint("CENTER", UIParent, "CENTER", 280, 0)
    end
    f:SetMovable(true); f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self)
        if not Deadpool.db.settings.drTrackerLocked then self:StartMoving() end
    end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local p, _, rp, x, y = self:GetPoint()
        Deadpool.db.settings.drTrackerPos = { point = p, relPoint = rp, x = x, y = y }
    end)
    f:SetClampedToScreen(true)
    f:SetFrameStrata("HIGH")
    f:SetScale(s.drTrackerScale or 1.0)

    f:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    f:SetBackdropColor(0.04, 0.04, 0.04, 0.6)
    f:SetBackdropBorderColor(0.6, 0.05, 0.05, 0.85)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetPoint("TOP", 0, -3)
    title:SetText("|cFFCC0000DR Tracker|r")
    f.title = title

    f.bars = {}
    f:Hide()
    self.frame = f
    return f
end

----------------------------------------------------------------------
-- Build one DR-group bar.
-- Layout:
--   [trigger icon 30px] [GROUP LABEL + tier word]            [time]
--                       [icon strip of all spells in group]
--   Background bar depletes left->right as the DR window counts down.
-- Hover any icon in the strip = tooltip for that spell.
----------------------------------------------------------------------
local STRIP_ICON_SIZE = 18
local STRIP_SPACING   = 2

local function makeStripIcon(parent, spellName)
    local b = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    b:SetSize(STRIP_ICON_SIZE, STRIP_ICON_SIZE)
    b:EnableMouse(true)
    b:SetBackdrop({
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    b:SetBackdropBorderColor(0, 0, 0, 0.9)

    local tex = b:CreateTexture(nil, "ARTWORK")
    tex:SetPoint("TOPLEFT", 1, -1)
    tex:SetPoint("BOTTOMRIGHT", -1, 1)
    tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    tex:SetTexture(getSpellIcon(spellName))
    b._tex = tex
    b._spellName = spellName

    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOPRIGHT")
        local icon = getSpellIcon(self._spellName)
        if icon then
            GameTooltip:AddLine("|T" .. icon .. ":18|t " .. self._spellName, 1, 1, 1)
        else
            GameTooltip:AddLine(self._spellName, 1, 1, 1)
        end
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end

local function createBar(parent, index)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(BAR_HEIGHT)
    row:SetPoint("TOPLEFT",  parent, "TOPLEFT",  6, -16 - (index - 1) * (BAR_HEIGHT + BAR_SPACING))
    row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -6, -16 - (index - 1) * (BAR_HEIGHT + BAR_SPACING))

    -- Trigger icon (the spell that was actually applied)
    row.iconHolder = CreateFrame("Frame", nil, row, "BackdropTemplate")
    row.iconHolder:SetSize(BAR_HEIGHT - 2, BAR_HEIGHT - 2)
    row.iconHolder:SetPoint("LEFT", 0, 0)
    row.iconHolder:SetBackdrop({
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    row.icon = row.iconHolder:CreateTexture(nil, "ARTWORK")
    row.icon:SetPoint("TOPLEFT", 1, -1)
    row.icon:SetPoint("BOTTOMRIGHT", -1, 1)
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    -- Background bar (depletes)
    row.bar = CreateFrame("StatusBar", nil, row)
    row.bar:SetPoint("LEFT", row.iconHolder, "RIGHT", 4, 0)
    row.bar:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    row.bar:SetHeight(BAR_HEIGHT)
    row.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    row.bar:SetMinMaxValues(0, 1)
    row.bar:SetValue(1)

    row.barBg = row.bar:CreateTexture(nil, "BACKGROUND")
    row.barBg:SetAllPoints()
    row.barBg:SetTexture("Interface\\Buttons\\WHITE8x8")
    row.barBg:SetVertexColor(0, 0, 0, 0.65)

    row.barBorder = CreateFrame("Frame", nil, row.bar, "BackdropTemplate")
    row.barBorder:SetAllPoints()
    row.barBorder:SetBackdrop({
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    row.barBorder:SetBackdropBorderColor(0, 0, 0, 0.85)

    -- Top label inside the bar: PLAYER  CATEGORY  next-cast tier
    row.label = row.bar:CreateFontString(nil, "OVERLAY")
    row.label:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    row.label:SetPoint("TOPLEFT", 6, -2)
    row.label:SetPoint("TOPRIGHT", -40, -2)
    row.label:SetJustifyH("LEFT")
    row.label:SetWordWrap(false)

    -- Time text
    row.timeText = row.bar:CreateFontString(nil, "OVERLAY")
    row.timeText:SetFont("Fonts\\FRIZQT__.TTF", 12, "OUTLINE")
    row.timeText:SetPoint("RIGHT", -6, 0)
    row.timeText:SetTextColor(1, 1, 1)

    -- Strip container (icons of all spells in this DR group)
    row.strip = CreateFrame("Frame", nil, row.bar)
    row.strip:SetPoint("BOTTOMLEFT", 6, 2)
    row.strip:SetHeight(STRIP_ICON_SIZE)
    row.strip._slots = {}

    return row
end

local function ensureBar(index)
    local b = DR.frame.bars[index]
    if b then return b end
    b = createBar(DR.frame, index)
    DR.frame.bars[index] = b
    return b
end

-- Populate the icon strip for a given category, highlighting the spell that triggered.
-- Filters to only spells castable by active classes (party + arena opponents),
-- plus the trigger spell itself (in case the caster's class isn't in the set yet).
local function fillStrip(strip, category, triggerSpell, categoryColor, dimmed)
    -- Hide existing slots
    for _, slot in ipairs(strip._slots) do slot:Hide() end

    local all = CATEGORY_SPELLS[category] or {}
    local spells = {}
    for _, spellName in ipairs(all) do
        if isSpellInActiveSet(spellName) or spellName == triggerSpell then
            spells[#spells + 1] = spellName
        end
    end

    for i, spellName in ipairs(spells) do
        local slot = strip._slots[i]
        if not slot then
            slot = makeStripIcon(strip, spellName)
            strip._slots[i] = slot
        else
            slot._spellName = spellName
            slot._tex:SetTexture(getSpellIcon(spellName))
        end
        slot:ClearAllPoints()
        slot:SetPoint("LEFT", strip, "LEFT", (i - 1) * (STRIP_ICON_SIZE + STRIP_SPACING), 0)

        local isTrigger = (spellName == triggerSpell)
            or (POLY_VARIANTS[triggerSpell or ""] and spellName == "Polymorph")
        if isTrigger then
            slot:SetBackdropBorderColor(1, 1, 1, 1)
            slot._tex:SetDesaturated(false)
            slot._tex:SetVertexColor(1, 1, 1, 1)
        else
            slot:SetBackdropBorderColor(0, 0, 0, 0.85)
            slot._tex:SetDesaturated(true)
            slot._tex:SetVertexColor(0.6, 0.6, 0.6, 0.8)
        end
        slot:Show()
    end

    return #spells
end

----------------------------------------------------------------------
-- Refresh: flatten state into a sorted list and render each as a
-- DR-group bar with icon strip + tier badge.
----------------------------------------------------------------------
function DR:Refresh()
    if not self.frame then return end
    cleanExpired()

    local now = GetTime()
    local list = {}
    for _, entry in pairs(self.state) do
        for cat, dr in pairs(entry.drs) do
            list[#list + 1] = {
                playerName = entry.name,
                class      = entry.class,
                category   = cat,
                dr         = dr,
                remaining  = dr.resetTime - now,
            }
        end
    end
    table.sort(list, function(a, b) return a.remaining < b.remaining end)

    for _, b in pairs(self.frame.bars) do b:Hide() end

    local maxShown = math.min(#list, 8)
    for i = 1, maxShown do
        local item = list[i]
        local b    = ensureBar(i)
        local dr   = item.dr
        local cat  = item.category

        b.icon:SetTexture(getSpellIcon(dr.spellName))

        local ci = CATEGORY_INFO[cat] or { label = cat:upper(), color = { 0.7, 0.7, 0.7 } }
        b.iconHolder:SetBackdropBorderColor(ci.color[1], ci.color[2], ci.color[3], 0.95)
        b.bar:SetStatusBarColor(ci.color[1] * 0.45, ci.color[2] * 0.45, ci.color[3] * 0.45, 0.9)
        b.barBorder:SetBackdropBorderColor(ci.color[1], ci.color[2], ci.color[3], 0.85)

        -- Next-cast tier (what the NEXT CC in this group will land at)
        -- dr.tier reflects the last applied tier. If we're still in the
        -- DR window, the NEXT cast will be at min(dr.tier+1, 4).
        local nextTier = math.min((dr.tier or 1) + 1, 4)
        local tc = TIER_COLOR[nextTier]
        local tierWord = (nextTier == 2) and "1/2"
                       or (nextTier == 3) and "1/4"
                       or "IMMUNE"

        local nameColor = item.class and Deadpool.classColors[item.class] or "|cFFFFFFFF"
        local catHex = string.format("|cFF%02x%02x%02x", math.floor(ci.color[1]*255), math.floor(ci.color[2]*255), math.floor(ci.color[3]*255))
        local tierHex = string.format("|cFF%02x%02x%02x", math.floor(tc[1]*255), math.floor(tc[2]*255), math.floor(tc[3]*255))
        b.label:SetText(string.format("%s%s|r  %s%s|r  %sNEXT: %s|r",
            nameColor, item.playerName,
            catHex, ci.label,
            tierHex, tierWord))

        -- Fill the icon strip with spells the active party classes can cast
        local shown = fillStrip(b.strip, cat, dr.spellName, ci.color) or 0
        b.strip:SetWidth(math.max(1, shown) * (STRIP_ICON_SIZE + STRIP_SPACING))

        b._dr = dr
        b._cat = cat
        b:Show()
    end

    local h = math.max(28, maxShown * (BAR_HEIGHT + BAR_SPACING) + 22)
    self.frame:SetHeight(h)
end

----------------------------------------------------------------------
-- Per-frame countdown updates
----------------------------------------------------------------------
local function onUpdate(self)
    if not Deadpool.db.settings.drTrackerEnabled and not DR.preview then return end
    local now = GetTime()
    local needsRelayout = false
    for _, b in pairs(self.bars or {}) do
        if b:IsShown() and b._dr then
            local remaining = b._dr.resetTime - now
            if remaining <= 0 then
                b:Hide()
                needsRelayout = true
            else
                local origDuration = FALLBACK_DURATION[b._dr.spellName] or 4
                local fullWindow   = origDuration + DR_RESET_WINDOW
                b.bar:SetMinMaxValues(0, fullWindow)
                b.bar:SetValue(remaining)
                -- Time text
                if remaining >= 10 then
                    b.timeText:SetText(string.format("%d", remaining))
                else
                    b.timeText:SetText(string.format("%.1f", remaining))
                end
            end
        end
    end
    DR._sweep = (DR._sweep or 0) + 1
    if DR._sweep > 30 or needsRelayout then
        DR._sweep = 0
        if cleanExpired() or needsRelayout then DR:Refresh() end
    end
end

----------------------------------------------------------------------
-- Enable / preview / lock / scale
----------------------------------------------------------------------
function DR:SetEnabled(on)
    Deadpool.db.settings.drTrackerEnabled = on and true or false
    if on then
        self:CreateFrame()
        self.frame:Show()
        self.frame:SetScript("OnUpdate", onUpdate)
    else
        self:SetPreview(false)
        self.state = {}
        if self.frame then
            self.frame:Hide()
            self.frame:SetScript("OnUpdate", nil)
        end
    end
end

function DR:SetLocked(on)
    Deadpool.db.settings.drTrackerLocked = on and true or false
    if self.frame then
        if on then
            self.frame:SetBackdropBorderColor(0.6, 0.05, 0.05, 0.5)
            if self.frame.title then self.frame.title:Hide() end
        else
            self.frame:SetBackdropBorderColor(0.8, 0.1, 0.1, 0.95)
            if self.frame.title then self.frame.title:Show() end
        end
    end
end

function DR:SetScale(s)
    s = tonumber(s) or 1.0
    if s < 0.5 then s = 0.5 elseif s > 2.0 then s = 2.0 end
    Deadpool.db.settings.drTrackerScale = s
    if self.frame then self.frame:SetScale(s) end
end

function DR:SetPreview(on)
    self.preview = on and true or false
    if not on then
        -- Remove preview fakes (any with guid prefix PV-) + clear preview class set
        for k in pairs(self.state) do
            if type(k) == "string" and k:sub(1, 3) == "PV-" then self.state[k] = nil end
        end
        PREVIEW_CLASSES = nil
        refreshActiveClasses()
        if not Deadpool.db.settings.drTrackerEnabled then
            if self.frame then self.frame:Hide() end
        else
            self:Refresh()
        end
        return
    end
    self:CreateFrame()
    self.frame:Show()
    self.frame:SetScript("OnUpdate", onUpdate)

    -- Fake party for the preview: player + rogue + priest (sample 3v3 comp).
    -- This determines which spells appear in the icon strip.
    local _, myClass = UnitClass("player")
    PREVIEW_CLASSES = {
        [myClass or "MAGE"] = true,
        ROGUE  = true,
        PRIEST = true,
    }

    -- Inject fake entries showing two enemies under various DRs
    local now = GetTime()
    self.state["PV-1"] = {
        name = "Stormydanels", class = "SHAMAN",
        drs = {
            stun = {
                tier = 2, spellName = "Kidney Shot",
                icon = select(3, GetSpellInfo(408)) or "Interface\\Icons\\Ability_Rogue_KidneyShot",
                expirationTime = now + 3, resetTime = now + 18,
            },
            incap = {
                tier = 1, spellName = "Polymorph",
                icon = select(3, GetSpellInfo(118)) or "Interface\\Icons\\Spell_Nature_Polymorph",
                expirationTime = now + 8, resetTime = now + 23,
            },
        },
    }
    self.state["PV-2"] = {
        name = "Tuggies", class = "ROGUE",
        drs = {
            fear = {
                tier = 3, spellName = "Psychic Scream",
                icon = select(3, GetSpellInfo(8122)) or "Interface\\Icons\\Spell_Shadow_PsychicScream",
                expirationTime = now + 2, resetTime = now + 17,
            },
            silence = {
                tier = 1, spellName = "Silence",
                icon = select(3, GetSpellInfo(15487)) or "Interface\\Icons\\Spell_Shadow_ImpPhaseShift",
                expirationTime = now + 5, resetTime = now + 20,
            },
            disorient = {
                tier = 4, spellName = "Blind",
                icon = select(3, GetSpellInfo(2094)) or "Interface\\Icons\\Spell_Shadow_MindSteal",
                expirationTime = now, resetTime = now + 15,
            },
        },
    }
    self:Refresh()
end

----------------------------------------------------------------------
-- Init
----------------------------------------------------------------------
function DR:Init()
    ensureSettings()
    Deadpool:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED", onCombatLog)
    Deadpool:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        self.state = {}
        refreshActiveClasses()
        if self.frame then self:Refresh() end
    end)
    Deadpool:RegisterEvent("GROUP_ROSTER_UPDATE", function()
        refreshActiveClasses()
        if self.frame and self.frame:IsShown() then self:Refresh() end
    end)
    Deadpool:RegisterEvent("ARENA_OPPONENT_UPDATE", function()
        refreshActiveClasses()
        if self.frame and self.frame:IsShown() then self:Refresh() end
    end)
    refreshActiveClasses()
    if Deadpool.db.settings.drTrackerEnabled then
        self:CreateFrame()
        if self.frame then
            self.frame:Show()
            self.frame:SetScript("OnUpdate", onUpdate)
        end
        self:SetLocked(Deadpool.db.settings.drTrackerLocked)
    end
end
