----------------------------------------------------------------------
-- Deadpool - ArenaAnalytics.lua
-- Phase 1 clone of ArenaAnalytics: standalone popout window with full
-- match history, filters, tokenized search, comp builder, scoreboard
-- detail popup, session stats, and CSV export.
----------------------------------------------------------------------

local AA = {}
Deadpool:RegisterModule("ArenaAnalytics", AA)

local FRAME_NAME      = "DeadpoolArenaAnalytics"
local TOOLBAR_HEIGHT  = 118
local HEADER_HEIGHT   = 24
local ROW_HEIGHT      = 22
local STATS_HEIGHT    = 32
local BOTTOM_HEIGHT   = 22

-- UI state (not persisted)
AA.state = {
    bracket   = "all",   -- "all" | "2v2" | "3v3" | "5v5"
    map       = "all",
    comp      = "all",
    date      = "all",   -- "today" | "week" | "month" | "season" | "all"
    mode      = "all",   -- "all" | "rated" | "skirmish"
    search    = "",
    view      = "history", -- "history" | "stats"
    sessionThreshold = 30 * 60, -- 30 minutes between matches starts a new session
}

----------------------------------------------------------------------
-- Class icon helper (sprite sheet via inline texture)
-- Uses Blizzard's built-in CLASS_ICON_TCOORDS table. Inline texture
-- escape works inside any FontString, so we can render icons in
-- regular row cells without making a per-class Frame.
----------------------------------------------------------------------
local CLASS_SPRITE = "Interface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES"

-- Hardcoded fallback in case CLASS_ICON_TCOORDS isn't present
local FALLBACK_TCOORDS = {
    WARRIOR = { 0,           0.25,        0,    0.25 },
    MAGE    = { 0.25,        0.49609375,  0,    0.25 },
    ROGUE   = { 0.49609375,  0.7421875,   0,    0.25 },
    DRUID   = { 0.7421875,   0.98828125,  0,    0.25 },
    HUNTER  = { 0,           0.25,        0.25, 0.5  },
    SHAMAN  = { 0.25,        0.49609375,  0.25, 0.5  },
    PRIEST  = { 0.49609375,  0.7421875,   0.25, 0.5  },
    WARLOCK = { 0.7421875,   0.98828125,  0.25, 0.5  },
    PALADIN = { 0,           0.25,        0.5,  0.75 },
}

local function classIcon(class, size)
    size = size or 14
    if not class then return "" end
    local c = (CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[class]) or FALLBACK_TCOORDS[class]
    if not c then return "" end
    local l = math.floor(c[1] * 256 + 0.5)
    local r = math.floor(c[2] * 256 + 0.5)
    local t = math.floor(c[3] * 256 + 0.5)
    local b = math.floor(c[4] * 256 + 0.5)
    return string.format("|T%s:%d:%d:0:0:256:256:%d:%d:%d:%d|t",
        CLASS_SPRITE, size, size, l, r, t, b)
end

-- Build a stable-ordered icon string for one team in a match
local function compIcons(scoreList, isEnemy, size)
    if not scoreList then return "" end
    local classes = {}
    for _, s in ipairs(scoreList) do
        if (s.isEnemy and isEnemy) or (not s.isEnemy and not isEnemy) then
            classes[#classes + 1] = s.class or "?"
        end
    end
    table.sort(classes)
    local out = {}
    for _, c in ipairs(classes) do
        local icon = classIcon(c, size)
        if icon ~= "" then out[#out + 1] = icon
        else out[#out + 1] = "?" end
    end
    return table.concat(out, " ")
end

----------------------------------------------------------------------
-- Class shorthand for search tokens
----------------------------------------------------------------------
local CLASS_ALIASES = {
    -- canonical class token -> { aliases }
    WARRIOR  = { "warrior", "war", "warr" },
    PALADIN  = { "paladin", "pal", "pala" },
    HUNTER   = { "hunter", "hun", "hunt" },
    ROGUE    = { "rogue", "rog", "rogu" },
    PRIEST   = { "priest", "pri", "prie" },
    SHAMAN   = { "shaman", "sha", "sham" },
    MAGE     = { "mage", "mag" },
    WARLOCK  = { "warlock", "wl", "wlk", "lock" },
    DRUID    = { "druid", "dru", "drud" },
}

local ALIAS_TO_CLASS = {}
for canon, aliases in pairs(CLASS_ALIASES) do
    ALIAS_TO_CLASS[canon:lower()] = canon
    for _, a in ipairs(aliases) do ALIAS_TO_CLASS[a:lower()] = canon end
end

local RACE_TOKENS = {
    human = true, dwarf = true, gnome = true, nightelf = true, ["night elf"] = true,
    draenei = true, orc = true, undead = true, scourge = true, tauren = true,
    troll = true, bloodelf = true, ["blood elf"] = true,
}

----------------------------------------------------------------------
-- Comp utility: build a sorted class string for a team
----------------------------------------------------------------------
local CLASS_SHORT = {
    WARRIOR = "War", PALADIN = "Pal", HUNTER = "Hun", ROGUE = "Rog",
    PRIEST = "Pri", SHAMAN = "Sha", MAGE = "Mag", WARLOCK = "Wlk", DRUID = "Dru",
}

local function buildComp(scoreList, isEnemy)
    if not scoreList then return "?" end
    local classes = {}
    for _, s in ipairs(scoreList) do
        if (s.isEnemy and isEnemy) or (not s.isEnemy and not isEnemy) then
            local c = s.class
            if c and CLASS_SHORT[c] then
                classes[#classes + 1] = CLASS_SHORT[c]
            else
                classes[#classes + 1 ] = "?"
            end
        end
    end
    table.sort(classes)
    return table.concat(classes, "/")
end

function AA:GetMatchComp(entry, enemy)
    -- Cache on the entry for stability
    if entry._compCache and entry._compCache[enemy and "enemy" or "team"] then
        return entry._compCache[enemy and "enemy" or "team"]
    end
    entry._compCache = entry._compCache or {}
    local comp = buildComp(entry.scores, enemy)
    entry._compCache[enemy and "enemy" or "team"] = comp
    return comp
end

----------------------------------------------------------------------
-- Search parser (tokenized segments, ArenaAnalytics-style)
----------------------------------------------------------------------
-- Segment = comma-separated; tokens within = space-separated.
-- Tokens may be prefixed (n:, c:, r:, t:, f:) or implicit.
-- Quote-wrapped tokens are exact name matches.
-- Prefix "!" or "-" negates a single token.
-- Prefix "no" or "not" at start of segment inverts the segment.
-- Keywords "team" / "enemy" force the segment to one team.

local function tokenize(segment)
    local tokens = {}
    -- Extract quoted strings first
    local working = segment
    for quoted in working:gmatch('"([^"]+)"') do
        tokens[#tokens + 1] = { type = "name_exact", value = quoted:lower() }
    end
    working = working:gsub('"[^"]+"', "")
    for word in working:gmatch("%S+") do
        tokens[#tokens + 1] = { raw = word }
    end
    return tokens
end

local function classifyToken(raw)
    local negated = false
    if raw:sub(1, 1) == "!" or raw:sub(1, 1) == "-" then
        negated = true
        raw = raw:sub(2)
    end
    if raw == "" then return nil end

    local lower = raw:lower()
    -- Explicit prefix
    local prefix, val = lower:match("^([a-z]+):(.+)$")
    if prefix and val then
        if prefix == "n" or prefix == "name" then
            return { type = "name", value = val, negated = negated }
        elseif prefix == "c" or prefix == "class" then
            local canon = ALIAS_TO_CLASS[val]
            return { type = "class", value = canon or val:upper(), negated = negated }
        elseif prefix == "r" or prefix == "race" then
            return { type = "race", value = val, negated = negated }
        elseif prefix == "t" or prefix == "team" then
            return { type = "team", value = val, negated = negated }
        elseif prefix == "f" or prefix == "faction" then
            return { type = "faction", value = val, negated = negated }
        end
    end

    -- Team keywords (segment-level scope tag)
    if lower == "team" then
        return { type = "team", value = "team", negated = negated }
    elseif lower == "enemy" then
        return { type = "team", value = "enemy", negated = negated }
    end

    -- Class shorthand
    if ALIAS_TO_CLASS[lower] then
        return { type = "class", value = ALIAS_TO_CLASS[lower], negated = negated }
    end

    -- Race
    if RACE_TOKENS[lower] then
        return { type = "race", value = lower, negated = negated }
    end

    -- Default: name substring
    return { type = "name", value = lower, negated = negated }
end

function AA:ParseSearch(text)
    if not text or text == "" then return nil end
    local segments = {}
    for raw in text:gmatch("[^,]+") do
        raw = raw:gsub("^%s+", ""):gsub("%s+$", "")
        if raw ~= "" then
            local inverted = false
            -- "no " / "not " inversion prefix
            local lower = raw:lower()
            if lower:sub(1, 3) == "no " then
                inverted = true; raw = raw:sub(4)
            elseif lower:sub(1, 4) == "not " then
                inverted = true; raw = raw:sub(5)
            end
            local rawTokens = tokenize(raw)
            local tokens = {}
            local teamScope = nil
            for _, t in ipairs(rawTokens) do
                if t.type == "name_exact" then
                    tokens[#tokens + 1] = t
                else
                    local classified = classifyToken(t.raw)
                    if classified then
                        if classified.type == "team" and not classified.negated then
                            teamScope = classified.value
                        else
                            tokens[#tokens + 1] = classified
                        end
                    end
                end
            end
            if #tokens > 0 or teamScope then
                segments[#segments + 1] = { tokens = tokens, inverted = inverted, teamScope = teamScope }
            end
        end
    end
    if #segments == 0 then return nil end
    return segments
end

----------------------------------------------------------------------
-- Filtering pipeline
----------------------------------------------------------------------
local function playerMatchesTokens(s, tokens)
    -- s = score record { name, fullName, class, race, ... }
    for _, tok in ipairs(tokens) do
        local hit = false
        if tok.type == "name" then
            local name = (s.name or ""):lower()
            local full = (s.fullName or ""):lower()
            hit = name:find(tok.value, 1, true) ~= nil or full:find(tok.value, 1, true) ~= nil
        elseif tok.type == "name_exact" then
            local name = (s.name or ""):lower()
            local full = (s.fullName or ""):lower()
            hit = (name == tok.value) or (full == tok.value)
        elseif tok.type == "class" then
            hit = (s.class == tok.value)
        elseif tok.type == "race" then
            hit = s.race and s.race:lower():gsub("%s", "") == tok.value:gsub("%s", "")
        end
        if tok.negated then hit = not hit end
        if not hit then return false end
    end
    return true
end

local function segmentMatches(entry, segment)
    local pool = {}
    if segment.teamScope == "team" then
        for _, s in ipairs(entry.scores or {}) do if not s.isEnemy then pool[#pool + 1] = s end end
    elseif segment.teamScope == "enemy" then
        for _, s in ipairs(entry.scores or {}) do if s.isEnemy then pool[#pool + 1] = s end end
    else
        for _, s in ipairs(entry.scores or {}) do pool[#pool + 1] = s end
    end
    for _, s in ipairs(pool) do
        if playerMatchesTokens(s, segment.tokens) then return true end
    end
    return false
end

function AA:EntryMatchesSearch(entry, segments)
    if not segments then return true end
    for _, seg in ipairs(segments) do
        local found = segmentMatches(entry, seg)
        if seg.inverted then found = not found end
        if not found then return false end
    end
    return true
end

----------------------------------------------------------------------
-- Date filters
----------------------------------------------------------------------
local function inDateWindow(entry, key)
    if not entry or not entry.time then return false end
    local now = time()
    if key == "today" then
        return (now - entry.time) <= 86400
    elseif key == "week" then
        return (now - entry.time) <= 86400 * 7
    elseif key == "month" then
        return (now - entry.time) <= 86400 * 30
    elseif key == "season" then
        return (now - entry.time) <= 86400 * 90
    end
    return true
end

----------------------------------------------------------------------
-- Main filtered + sorted dataset
----------------------------------------------------------------------
function AA:GetFilteredMatches()
    local raw = Deadpool.db.arenaLog or {}
    local segments = AA:ParseSearch(self.state.search)
    local results = {}
    for _, e in ipairs(raw) do
        local ok = true
        if self.state.bracket ~= "all" and (e.bracket or "") ~= self.state.bracket then ok = false end
        if ok and self.state.map ~= "all" and (e.map or "") ~= self.state.map then ok = false end
        if ok and self.state.comp ~= "all" then
            local mc = AA:GetMatchComp(e, false)
            local ec = AA:GetMatchComp(e, true)
            if mc ~= self.state.comp and ec ~= self.state.comp then ok = false end
        end
        if ok and self.state.date ~= "all" and not inDateWindow(e, self.state.date) then ok = false end
        -- Rated / Skirmish filter.
        -- Modern entries have e.isRated set explicitly. For legacy entries
        -- with no flag, infer from rating data: if anyone has ratingChange
        -- on their row, the match was rated.
        if ok and self.state.mode ~= "all" then
            local isRated = e.isRated
            if isRated == nil then
                -- Infer
                if (e.oldRating or 0) > 0 or (e.newRating or 0) > 0 then
                    isRated = true
                end
                if not isRated and e.scores then
                    for _, s in ipairs(e.scores) do
                        if s.ratingChange ~= nil or (s.rating or 0) > 0 then isRated = true; break end
                    end
                end
            end
            if self.state.mode == "rated"    and not isRated then ok = false end
            if self.state.mode == "skirmish" and isRated     then ok = false end
        end
        if ok and segments and not AA:EntryMatchesSearch(e, segments) then ok = false end
        if ok then results[#results + 1] = e end
    end
    return results
end

----------------------------------------------------------------------
-- Session calculation
----------------------------------------------------------------------
function AA:GetCurrentSessionStats()
    local matches = Deadpool.db.arenaLog or {}
    if #matches == 0 then return { wins = 0, losses = 0, mmrDelta = 0, count = 0 } end
    local sessionEntries = {}
    local lastTime = matches[1].time or 0
    for _, e in ipairs(matches) do
        if math.abs((e.time or 0) - lastTime) > self.state.sessionThreshold then break end
        sessionEntries[#sessionEntries + 1] = e
        lastTime = e.time or lastTime
    end
    local wins, losses, mmrDelta = 0, 0, 0
    for _, e in ipairs(sessionEntries) do
        if e.won then wins = wins + 1 else losses = losses + 1 end
        if (e.newRating or 0) > 0 and (e.oldRating or 0) > 0 then
            mmrDelta = mmrDelta + (e.newRating - e.oldRating)
        end
    end
    return { wins = wins, losses = losses, mmrDelta = mmrDelta, count = #sessionEntries }
end

----------------------------------------------------------------------
-- Build sorted unique lists for dropdowns
----------------------------------------------------------------------
function AA:GetUniqueMaps()
    local seen = {}
    for _, e in ipairs(Deadpool.db.arenaLog or {}) do
        if e.map and e.map ~= "" then seen[e.map] = true end
    end
    local list = { "all" }
    for m in pairs(seen) do list[#list + 1] = m end
    table.sort(list, function(a, b) if a == "all" then return true elseif b == "all" then return false else return a < b end end)
    return list
end

function AA:GetUniqueComps()
    local seen = {}
    for _, e in ipairs(Deadpool.db.arenaLog or {}) do
        local mc = AA:GetMatchComp(e, false)
        if mc and mc ~= "" then seen[mc] = true end
        local ec = AA:GetMatchComp(e, true)
        if ec and ec ~= "" then seen[ec] = true end
    end
    local list = { "all" }
    for c in pairs(seen) do list[#list + 1] = c end
    table.sort(list, function(a, b) if a == "all" then return true elseif b == "all" then return false else return a < b end end)
    return list
end

----------------------------------------------------------------------
-- Arena unit-info tracker (enrich match entries with race + class for
-- arenaN units, capture first death, and track combat-log truth for
-- per-player damage, healing, deaths, and kills since TBC arena
-- scoreboard returns junk for those columns).
----------------------------------------------------------------------
AA.tracker = {
    inArena   = false,
    units     = {},   -- [shortName] = { class, race, faction }
    firstDeath = nil, -- { name, fullName, time, isEnemy=nil (resolved later) }
    pendingEntry = false,
    -- Combat-log ground truth (keyed by short player name):
    cl_damage  = {},  -- [name] = total damage dealt to enemy players
    cl_healing = {},  -- [name] = total healing done to friendly players (incl. self)
    cl_deaths  = {},  -- [name] = death count
    cl_kills   = {},  -- [name] = killing blow count
    guidToName = {},  -- [guid] = shortName (resolved as units appear)
}

local function shortName(n)
    if not n then return nil end
    return n:match("^(.-)%-") or n
end

local function sweepArenaUnits()
    local t = AA.tracker
    if not t.inArena then return end
    -- player + party
    local units = { "player" }
    for i = 1, 4 do units[#units + 1] = "party" .. i end
    for i = 1, 5 do units[#units + 1] = "arena" .. i end
    for _, u in ipairs(units) do
        if UnitExists(u) and UnitIsPlayer(u) then
            local name = UnitName(u)
            if name then
                local _, class = UnitClass(u)
                local _, race  = UnitRace(u)
                local faction  = UnitFactionGroup(u)
                local key = shortName(name)
                if key then
                    t.units[key] = {
                        class   = class,
                        race    = race,
                        faction = faction,
                    }
                    local guid = UnitGUID(u)
                    if guid then t.guidToName[guid] = key end
                end
            end
        end
    end
end

local COMBATLOG_OBJECT_TYPE_PLAYER = 0x00000400
local COMBATLOG_OBJECT_REACTION_HOSTILE = 0x00000040
local COMBATLOG_OBJECT_REACTION_FRIENDLY = 0x00000010

local function trackerOnCombatLog()
    local t = AA.tracker
    if not t.inArena then return end
    local _, subevent, _, sourceGUID, sourceName, sourceFlags, _,
              destGUID, destName, destFlags = CombatLogGetCurrentEventInfo()

    -- Resolve short names; prefer GUID cache, then derive from event name
    local function resolveName(guid, fullName, flags)
        if guid and t.guidToName[guid] then return t.guidToName[guid] end
        if fullName and flags and bit.band(flags, COMBATLOG_OBJECT_TYPE_PLAYER) > 0 then
            local sn = shortName(fullName)
            if sn and t.units[sn] then
                if guid then t.guidToName[guid] = sn end
                return sn
            end
        end
        return nil
    end

    local sName = resolveName(sourceGUID, sourceName, sourceFlags)
    local dName = resolveName(destGUID, destName, destFlags)

    -- Death tracking
    if subevent == "UNIT_DIED" or subevent == "PARTY_KILL" then
        if dName then
            t.cl_deaths[dName] = (t.cl_deaths[dName] or 0) + 1
            -- First death (only once)
            if not t.firstDeath then
                t.firstDeath = {
                    name = dName,
                    fullName = destName or dName,
                    time = time(),
                }
            end
        end
        -- Killing blow credit: PARTY_KILL fires for our group; for non-group
        -- kills we approximate via "last damager" (handled below). For arena
        -- this is good enough — the scoreboard's KB column is mostly correct
        -- for our team via PARTY_KILL.
        if subevent == "PARTY_KILL" and sName then
            t.cl_kills[sName] = (t.cl_kills[sName] or 0) + 1
        end
        return
    end

    -- Damage / healing tracking (use sub-event suffix)
    if not subevent then return end
    local isDamage = (subevent == "SWING_DAMAGE")
        or subevent:sub(-7) == "_DAMAGE"
    local isHeal = subevent:sub(-5) == "_HEAL" and subevent:sub(-12) ~= "ABSORBED_HEAL"

    if isDamage then
        local amount
        if subevent == "SWING_DAMAGE" then
            amount = select(12, CombatLogGetCurrentEventInfo())
        else
            -- _DAMAGE family: amount at param 15
            amount = select(15, CombatLogGetCurrentEventInfo())
        end
        amount = tonumber(amount) or 0
        if amount > 0 and sName and destGUID then
            -- Only count damage to PLAYERS (skip pet damage targets and NPCs)
            local destIsPlayer = (destGUID:sub(1, 6) == "Player")
                or (destFlags and bit.band(destFlags, COMBATLOG_OBJECT_TYPE_PLAYER) > 0)
            if destIsPlayer then
                t.cl_damage[sName] = (t.cl_damage[sName] or 0) + amount
            end
        end
        return
    end

    if isHeal then
        local amount, overheal
        if subevent:sub(1, 5) == "SPELL" then
            -- SPELL_HEAL / SPELL_PERIODIC_HEAL: amount at param 15, overheal at 16
            amount, overheal = select(15, CombatLogGetCurrentEventInfo())
        end
        amount = tonumber(amount) or 0
        overheal = tonumber(overheal) or 0
        local effective = amount - overheal
        if effective > 0 and sName then
            t.cl_healing[sName] = (t.cl_healing[sName] or 0) + effective
        end
        return
    end
end

function AA:InitTracker()
    Deadpool:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        local inInstance, instanceType = IsInInstance()
        local wasInArena = self.tracker.inArena
        if inInstance and instanceType == "arena" then
            -- Fresh state for new match
            self.tracker.inArena    = true
            self.tracker.units      = {}
            self.tracker.firstDeath = nil
            self.tracker.pendingEntry = true
            self.tracker.cl_damage  = {}
            self.tracker.cl_healing = {}
            self.tracker.cl_deaths  = {}
            self.tracker.cl_kills   = {}
            self.tracker.guidToName = {}
            -- Initial unit sweep
            sweepArenaUnits()
        else
            self.tracker.inArena = false
        end
        if wasInArena and not self.tracker.inArena then
            -- left arena: clear after a tick (capture may still happen)
            C_Timer.After(8, function()
                self.tracker.units      = {}
                self.tracker.firstDeath = nil
                self.tracker.pendingEntry = false
                self.tracker.cl_damage  = {}
                self.tracker.cl_healing = {}
                self.tracker.cl_deaths  = {}
                self.tracker.cl_kills   = {}
                self.tracker.guidToName = {}
            end)
        end
    end)

    Deadpool:RegisterEvent("ARENA_OPPONENT_UPDATE", function() sweepArenaUnits() end)
    Deadpool:RegisterEvent("UNIT_NAME_UPDATE",     function() sweepArenaUnits() end)
    Deadpool:RegisterEvent("GROUP_ROSTER_UPDATE",  function() sweepArenaUnits() end)
    Deadpool:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED", trackerOnCombatLog)

    if C_Timer and C_Timer.NewTicker then
        C_Timer.NewTicker(2, function() sweepArenaUnits() end)
    end

    -- Hook KillTracker:CaptureArenaResult so we can enrich the entry it
    -- just inserted into arenaLog[1]. We wrap the original to run our
    -- enrichment immediately after.
    local KT = Deadpool.modules.KillTracker
    if KT and KT.CaptureArenaResult and not KT._aaWrapped then
        local original = KT.CaptureArenaResult
        KT.CaptureArenaResult = function(selfRef, ...)
            local beforeCount = #(Deadpool.db.arenaLog or {})
            local ret = original(selfRef, ...)
            local log = Deadpool.db.arenaLog
            if log and #log > beforeCount then
                AA:EnrichEntry(log[1])
            end
            return ret
        end
        KT._aaWrapped = true
    end
end

function AA:EnrichEntry(entry)
    if not entry then return end
    local t = self.tracker
    -- Merge class/race info from arena sweep into scores AND override
    -- damage/healing/deaths/kills with combat-log truth.
    if entry.scores then
        for _, s in ipairs(entry.scores) do
            local info = t.units[s.name]
            if info then
                if (not s.class or s.class == "") and info.class then s.class = info.class end
                if not s.race and info.race then s.race = info.race end
                if not s.faction_name and info.faction then s.faction_name = info.faction end
            end
            -- Combat-log overrides — only override when CL has data, since
            -- bench/spectator-like edge cases could leave CL empty
            local cd = t.cl_damage[s.name]
            if cd and cd > 0 then s.damage = cd end
            local ch = t.cl_healing[s.name]
            if ch and ch > 0 then s.healing = ch end
            local dd = t.cl_deaths[s.name]
            if dd and dd > 0 then s.deaths = dd end
            local ck = t.cl_kills[s.name]
            if ck and ck > 0 then s.kills = ck end
        end
        -- Recompute the player's headline stats from the overridden scores
        local myName = UnitName("player")
        for _, s in ipairs(entry.scores) do
            if s.name == myName then
                entry.myDamage  = s.damage  or entry.myDamage
                entry.myHealing = s.healing or entry.myHealing
                entry.myKills   = s.kills   or entry.myKills
                entry.myDeaths  = s.deaths  or entry.myDeaths
                break
            end
        end
    end
    -- First death
    if t.firstDeath then
        local fd = t.firstDeath
        -- Resolve enemy/team membership from scores
        local isEnemy = nil
        if entry.scores then
            for _, s in ipairs(entry.scores) do
                if s.name == fd.name then isEnemy = s.isEnemy; break end
            end
        end
        entry.firstDeath = {
            name = fd.name,
            fullName = fd.fullName,
            isEnemy = isEnemy,
            time = fd.time,
        }
    end
    -- Pre-compute comps for filter dropdowns
    AA:GetMatchComp(entry, false)
    AA:GetMatchComp(entry, true)
    if AA.frame and AA.frame:IsShown() then AA:Refresh() end
end

----------------------------------------------------------------------
-- UI helpers
----------------------------------------------------------------------
local function fmtNum(n)
    n = tonumber(n) or 0
    if n >= 1000000 then return string.format("%.1fM", n / 1000000)
    elseif n >= 1000 then return string.format("%.1fK", n / 1000)
    else return tostring(n) end
end

local function fmtDuration(d)
    d = tonumber(d) or 0
    if d <= 0 then return "-" end
    local m = math.floor(d / 60)
    local s = d % 60
    return string.format("%d:%02d", m, s)
end

local function classColored(name, class)
    if class and Deadpool.classColors[class] then
        return Deadpool.classColors[class] .. (name or "?") .. "|r"
    end
    return name or "?"
end

local function compColored(comp)
    -- Color each class chunk by class color
    if not comp or comp == "" or comp == "?" then return comp or "" end
    local CLASS_BY_SHORT = {}
    for canon, short in pairs(CLASS_SHORT) do CLASS_BY_SHORT[short] = canon end
    local out = {}
    for part in comp:gmatch("[^/]+") do
        local canon = CLASS_BY_SHORT[part]
        if canon and Deadpool.classColors[canon] then
            out[#out + 1] = Deadpool.classColors[canon] .. part .. "|r"
        else
            out[#out + 1] = part
        end
    end
    return table.concat(out, "/")
end

----------------------------------------------------------------------
-- Window construction
----------------------------------------------------------------------
local function styleBackdrop(frame, t, alpha)
    frame:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    frame:SetBackdropColor(t.bg[1], t.bg[2], t.bg[3], alpha or t.bg[4] or 0.95)
    frame:SetBackdropBorderColor(t.border[1], t.border[2], t.border[3], t.border[4] or 0.8)
end

local function makeButton(parent, label, w, h, onClick)
    local TM = Deadpool.modules.Theme
    local t = TM.active
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(w, h)
    b:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    b:SetBackdropColor(t.accent[1] * 0.25, t.accent[2] * 0.25, t.accent[3] * 0.25, 0.9)
    b:SetBackdropBorderColor(t.accent[1], t.accent[2], t.accent[3], 0.55)
    b._label = b:CreateFontString(nil, "OVERLAY")
    b._label:SetFont(TM:GetFont(11, ""))
    b._label:SetPoint("CENTER")
    b._label:SetText(label)
    b._label:SetTextColor(t.text[1], t.text[2], t.text[3])
    b:SetScript("OnEnter", function(self) self:SetBackdropColor(t.accent[1] * 0.5, t.accent[2] * 0.5, t.accent[3] * 0.5, 1) end)
    b:SetScript("OnLeave", function(self) self:SetBackdropColor(t.accent[1] * 0.25, t.accent[2] * 0.25, t.accent[3] * 0.25, 0.9) end)
    if onClick then b:SetScript("OnClick", onClick) end
    return b
end

local function makePillButton(parent, label, isActive, onClick)
    local TM = Deadpool.modules.Theme
    local t = TM.active
    local b = makeButton(parent, label, 56, 24, onClick)
    b.SetActive = function(self, active)
        if active then
            self:SetBackdropColor(t.accent[1] * 0.7, t.accent[2] * 0.7, t.accent[3] * 0.7, 0.95)
            self:SetBackdropBorderColor(t.accent[1], t.accent[2], t.accent[3], 1)
            self._label:SetTextColor(1, 1, 1)
        else
            self:SetBackdropColor(t.accent[1] * 0.2, t.accent[2] * 0.2, t.accent[3] * 0.2, 0.85)
            self:SetBackdropBorderColor(t.accent[1], t.accent[2], t.accent[3], 0.4)
            self._label:SetTextColor(t.textDim[1], t.textDim[2], t.textDim[3])
        end
    end
    b:SetActive(isActive)
    return b
end

local function makeDropdown(parent, label, valueGetter, optionsGetter, onChange)
    local TM = Deadpool.modules.Theme
    local t = TM.active

    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(116, 36)

    local lbl = container:CreateFontString(nil, "OVERLAY")
    lbl:SetFont(TM:GetFont(9, ""))
    lbl:SetPoint("TOPLEFT", 4, 0)
    lbl:SetTextColor(t.textDim[1], t.textDim[2], t.textDim[3])
    lbl:SetText(label:upper())

    local btn = CreateFrame("Button", nil, container, "BackdropTemplate")
    btn:SetSize(116, 22)
    btn:SetPoint("BOTTOMLEFT", 0, 0)
    btn:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    btn:SetBackdropColor(0.08, 0.08, 0.08, 0.95)
    btn:SetBackdropBorderColor(t.accent[1], t.accent[2], t.accent[3], 0.45)

    btn._value = btn:CreateFontString(nil, "OVERLAY")
    btn._value:SetFont(TM:GetFont(11, ""))
    btn._value:SetPoint("LEFT", 8, 0)
    btn._value:SetTextColor(t.text[1], t.text[2], t.text[3])

    local arrow = btn:CreateFontString(nil, "OVERLAY")
    arrow:SetFont(TM:GetFont(9, ""))
    arrow:SetPoint("RIGHT", -6, 0)
    arrow:SetText("v")
    arrow:SetTextColor(t.accent[1], t.accent[2], t.accent[3])

    btn.Refresh = function(self)
        local v = valueGetter()
        self._value:SetText(v == "all" and (label .. ": All") or tostring(v))
    end
    btn:Refresh()

    btn:SetScript("OnClick", function(self)
        if not AA._dropdownMenu then
            AA._dropdownMenu = CreateFrame("Frame", "DeadpoolAADropdownMenu", UIParent, "UIDropDownMenuTemplate")
        end
        local menu = AA._dropdownMenu
        UIDropDownMenu_Initialize(menu, function(_, level)
            for _, opt in ipairs(optionsGetter()) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = (opt == "all") and (label .. ": All") or tostring(opt)
                info.notCheckable = true
                info.func = function()
                    onChange(opt)
                    btn:Refresh()
                end
                UIDropDownMenu_AddButton(info, level or 1)
            end
        end, "MENU")
        ToggleDropDownMenu(1, nil, menu, self, 0, 0)
    end)

    container.btn = btn
    return container
end

----------------------------------------------------------------------
-- Build into the Deadpool main window's Arena tab area
----------------------------------------------------------------------
function AA:CreateFrame()
    if self.frame then return self.frame end
    local mainFrame = _G["DeadpoolMainFrame"]
    if not mainFrame then
        -- Main UI not built yet; bail. Caller will retry on next Show.
        return nil
    end
    local TM = Deadpool.modules.Theme
    local t = TM.active

    -- Integrated panel: anchored exactly where contentArea sits in other tabs.
    local f = CreateFrame("Frame", FRAME_NAME, mainFrame, "BackdropTemplate")
    f:SetPoint("TOPLEFT",     mainFrame.sidebar, "TOPRIGHT", 2, -6)
    f:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -10, 28)
    f:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    f:SetBackdropColor(t.bg[1], t.bg[2], t.bg[3], 0.4)
    f:SetBackdropBorderColor(t.accent[1], t.accent[2], t.accent[3], 0.35)
    f:Hide()
    self.frame = f

    -- Toolbar (top of the integrated panel)
    local toolbar = CreateFrame("Frame", nil, f, "BackdropTemplate")
    toolbar:SetHeight(TOOLBAR_HEIGHT)
    toolbar:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    toolbar:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
    toolbar:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
    toolbar:SetBackdropColor(t.bgAlt[1], t.bgAlt[2], t.bgAlt[3], 0.9)
    f.toolbar = toolbar

    -- HISTORY / STATS view tabs (top-right of toolbar)
    local function makeViewTab(label, key, anchor, anchorPoint, xOffset)
        local b = CreateFrame("Button", nil, toolbar, "BackdropTemplate")
        b:SetSize(80, 22)
        if anchor then
            b:SetPoint("RIGHT", anchor, anchorPoint or "LEFT", xOffset or -4, 0)
        else
            b:SetPoint("TOPRIGHT", toolbar, "TOPRIGHT", -10, -6)
        end
        b:SetBackdrop({
            bgFile   = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
        })
        b._txt = b:CreateFontString(nil, "OVERLAY")
        b._txt:SetFont(TM:GetFont(11, "OUTLINE"))
        b._txt:SetPoint("CENTER")
        b._txt:SetText(label)
        b.key = key
        b.SetActive = function(self, active)
            if active then
                self:SetBackdropColor(t.accent[1] * 0.7, t.accent[2] * 0.7, t.accent[3] * 0.7, 0.95)
                self:SetBackdropBorderColor(t.accent[1], t.accent[2], t.accent[3], 1)
                self._txt:SetTextColor(1, 1, 1)
            else
                self:SetBackdropColor(t.accent[1] * 0.18, t.accent[2] * 0.18, t.accent[3] * 0.18, 0.85)
                self:SetBackdropBorderColor(t.accent[1], t.accent[2], t.accent[3], 0.35)
                self._txt:SetTextColor(t.textDim[1], t.textDim[2], t.textDim[3])
            end
        end
        b:SetScript("OnClick", function()
            AA.state.view = key
            AA:Refresh()
        end)
        return b
    end
    f._tabStats   = makeViewTab("STATS",   "stats",   nil, nil, nil)
    f._tabHistory = makeViewTab("HISTORY", "history", f._tabStats, "LEFT", -4)

    -- Bracket pills
    local pillX = 12
    local pillY = -34
    f.pills = {}
    local brackets = { { "All", "all" }, { "2v2", "2v2" }, { "3v3", "3v3" }, { "5v5", "5v5" } }
    for i, def in ipairs(brackets) do
        local p = makePillButton(toolbar, def[1], AA.state.bracket == def[2], function()
            AA.state.bracket = def[2]
            for _, pp in ipairs(f.pills) do pp:SetActive(pp.key == def[2]) end
            AA:Refresh()
        end)
        p:SetPoint("TOPLEFT", pillX + (i - 1) * 62, pillY)
        p.key = def[2]
        f.pills[#f.pills + 1] = p
    end

    -- Mode pills (Rated / Skirmish / All)
    f.modePills = {}
    local modes = { { "All",  "all" }, { "Rated", "rated" }, { "Skirm", "skirmish" } }
    local modeStartX = 12 + 4 * 62 + 14
    for i, def in ipairs(modes) do
        local p = makePillButton(toolbar, def[1], AA.state.mode == def[2], function()
            AA.state.mode = def[2]
            for _, pp in ipairs(f.modePills) do pp:SetActive(pp.key == def[2]) end
            AA:Refresh()
        end)
        p:SetSize(54, 24)
        p:SetPoint("TOPLEFT", modeStartX + (i - 1) * 58, pillY)
        p.key = def[2]
        f.modePills[#f.modePills + 1] = p
    end

    -- Date dropdown
    f.dateDD = makeDropdown(toolbar, "Date",
        function() return AA.state.date end,
        function() return { "all", "today", "week", "month", "season" } end,
        function(v) AA.state.date = v; AA:Refresh() end)
    f.dateDD:SetPoint("TOPLEFT", modeStartX + 3 * 58 + 12, pillY)

    -- Map dropdown
    f.mapDD = makeDropdown(toolbar, "Map",
        function() return AA.state.map end,
        function() return AA:GetUniqueMaps() end,
        function(v) AA.state.map = v; AA:Refresh() end)
    f.mapDD:SetPoint("TOPLEFT", f.dateDD, "TOPRIGHT", 8, 0)

    -- Comp dropdown
    f.compDD = makeDropdown(toolbar, "Comp",
        function() return AA.state.comp end,
        function() return AA:GetUniqueComps() end,
        function(v) AA.state.comp = v; AA:Refresh() end)
    f.compDD:SetPoint("TOPLEFT", f.mapDD, "TOPRIGHT", 8, 0)

    -- Search box (row below pills/dropdowns)
    local sBg = CreateFrame("Frame", nil, toolbar, "BackdropTemplate")
    sBg:SetSize(560, 24)
    sBg:SetPoint("BOTTOMLEFT", 12, 8)
    sBg:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    sBg:SetBackdropColor(0.04, 0.04, 0.04, 0.95)
    sBg:SetBackdropBorderColor(t.accent[1], t.accent[2], t.accent[3], 0.4)

    local sLbl = sBg:CreateFontString(nil, "OVERLAY")
    sLbl:SetFont(TM:GetFont(10, ""))
    sLbl:SetPoint("LEFT", 8, 0)
    sLbl:SetText(TM:AccentHex() .. "SEARCH|r")

    local sBox = CreateFrame("EditBox", nil, sBg)
    sBox:SetFont(TM:GetFont(11, ""))
    sBox:SetPoint("LEFT", sLbl, "RIGHT", 8, 0)
    sBox:SetPoint("RIGHT", -8, 0)
    sBox:SetHeight(20)
    sBox:SetAutoFocus(false)
    sBox:SetMaxLetters(256)
    sBox:SetTextColor(t.text[1], t.text[2], t.text[3])

    local placeholder = sBg:CreateFontString(nil, "OVERLAY")
    placeholder:SetFont(TM:GetFont(11, ""))
    placeholder:SetPoint("LEFT", sLbl, "RIGHT", 8, 0)
    placeholder:SetTextColor(t.textDim[1], t.textDim[2], t.textDim[3])
    placeholder:SetText('enemy mage rogue, "Hydra", no priest, rage healer')

    sBox:SetScript("OnTextChanged", function(self)
        AA.state.search = self:GetText() or ""
        if AA.state.search == "" then placeholder:Show() else placeholder:Hide() end
        AA:Refresh()
    end)
    sBox:SetScript("OnEditFocusGained", function() placeholder:Hide() end)
    sBox:SetScript("OnEditFocusLost", function(self)
        if (self:GetText() or "") == "" then placeholder:Show() end
    end)
    sBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    sBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    f._searchBox = sBox
    f._searchPlaceholder = placeholder

    -- Search help tooltip on hover
    sBg:EnableMouse(true)
    sBg:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
        GameTooltip:AddLine("ARENA ANALYTICS SEARCH", 1, 1, 1)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Comma-separated player segments, tokens space-separated.", 0.8, 0.8, 0.8, true)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Tokens: name, class, race, or prefix n: c: r: t: f:", 0.7, 0.9, 1)
        GameTooltip:AddLine("Team scope: 'team' or 'enemy' inside a segment.", 0.7, 0.9, 1)
        GameTooltip:AddLine('Exact match: "Hydra" or "Hydra-Firemaw"', 0.7, 0.9, 1)
        GameTooltip:AddLine("Negate token: !mage or -mage", 0.7, 0.9, 1)
        GameTooltip:AddLine("Invert segment: 'no priest' or 'not warrior'", 0.7, 0.9, 1)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Class shortcuts: war pal hun rog pri sha mag wlk dru", 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end)
    sBg:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Reset button + Export
    local resetBtn = makeButton(toolbar, "Reset Filters", 110, 24, function()
        AA.state.bracket = "all"
        AA.state.mode    = "all"
        AA.state.map     = "all"
        AA.state.comp    = "all"
        AA.state.date    = "all"
        AA.state.search  = ""
        sBox:SetText("")
        for _, p in ipairs(f.pills)     do p:SetActive(p.key == "all") end
        for _, p in ipairs(f.modePills) do p:SetActive(p.key == "all") end
        f.dateDD.btn:Refresh()
        f.mapDD.btn:Refresh()
        f.compDD.btn:Refresh()
        AA:Refresh()
    end)
    resetBtn:SetPoint("BOTTOMRIGHT", -130, 8)

    local exportBtn = makeButton(toolbar, "Export CSV", 110, 24, function() AA:Export() end)
    exportBtn:SetPoint("BOTTOMRIGHT", -12, 8)

    -- Stats summary bar
    local stats = CreateFrame("Frame", nil, f, "BackdropTemplate")
    stats:SetHeight(STATS_HEIGHT)
    stats:SetPoint("TOPLEFT", toolbar, "BOTTOMLEFT", 0, -1)
    stats:SetPoint("TOPRIGHT", toolbar, "BOTTOMRIGHT", 0, -1)
    stats:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
    stats:SetBackdropColor(t.headerBg[1], t.headerBg[2], t.headerBg[3], 0.85)
    f.stats = stats

    stats.label = stats:CreateFontString(nil, "OVERLAY")
    stats.label:SetFont(TM:GetFont(12, "OUTLINE"))
    stats.label:SetPoint("LEFT", 14, 0)
    stats.label:SetText("")

    -- Header row
    local headerFrame = CreateFrame("Frame", nil, f)
    headerFrame:SetHeight(HEADER_HEIGHT)
    headerFrame:SetPoint("TOPLEFT", stats, "BOTTOMLEFT", 0, -1)
    headerFrame:SetPoint("TOPRIGHT", stats, "BOTTOMRIGHT", -16, -1)
    local hBg = headerFrame:CreateTexture(nil, "BACKGROUND")
    hBg:SetAllPoints()
    hBg:SetColorTexture(0.10, 0.10, 0.10, 0.85)
    f.headerFrame = headerFrame
    f.headerFonts = {}

    -- Row container
    local rowContainer = CreateFrame("Frame", nil, f)
    rowContainer:SetPoint("TOPLEFT", headerFrame, "BOTTOMLEFT", 0, -1)
    rowContainer:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -18, BOTTOM_HEIGHT + 2)
    rowContainer:SetClipsChildren(true)
    f.rowContainer = rowContainer

    -- Scrollbar
    local scrollBar = CreateFrame("Slider", nil, f, "BackdropTemplate")
    scrollBar:SetWidth(14)
    scrollBar:SetPoint("TOPRIGHT", headerFrame, "TOPRIGHT", 16, 0)
    scrollBar:SetPoint("BOTTOMRIGHT", rowContainer, "BOTTOMRIGHT", 16, 0)
    scrollBar:SetOrientation("VERTICAL")
    scrollBar:SetMinMaxValues(0, 1)
    scrollBar:SetValueStep(1)
    scrollBar:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    scrollBar:SetBackdropColor(t.bg[1], t.bg[2], t.bg[3], 0.5)
    scrollBar:SetBackdropBorderColor(t.border[1], t.border[2], t.border[3], 0.3)
    local thumb = scrollBar:CreateTexture(nil, "OVERLAY")
    thumb:SetSize(12, 40)
    thumb:SetColorTexture(t.accent[1], t.accent[2], t.accent[3], 0.65)
    scrollBar:SetThumbTexture(thumb)
    scrollBar:SetScript("OnValueChanged", function(self, value)
        AA._scrollOffset = math.floor(value + 0.5)
        AA:RenderHistory()
    end)
    f.scrollBar = scrollBar
    AA._scrollOffset = 0
    AA._scrollMax = 0

    rowContainer:EnableMouseWheel(true)
    rowContainer:SetScript("OnMouseWheel", function(_, delta)
        AA._scrollOffset = AA._scrollOffset - delta
        if AA._scrollOffset < 0 then AA._scrollOffset = 0 end
        if AA._scrollOffset > AA._scrollMax then AA._scrollOffset = AA._scrollMax end
        scrollBar:SetValue(AA._scrollOffset)
    end)

    -- Row pool: size based on actual frame height after first frame paint.
    -- Create a generous pool; extra rows just stay hidden.
    f.rows = {}
    for i = 1, 28 do
        f.rows[i] = AA:CreateRow(rowContainer, i)
    end

    -- Stats panel (alternate view container)
    local statsPanel = CreateFrame("Frame", nil, f, "BackdropTemplate")
    statsPanel:SetPoint("TOPLEFT", headerFrame, "TOPLEFT", 0, 0)
    statsPanel:SetPoint("BOTTOMRIGHT", rowContainer, "BOTTOMRIGHT", 16, 0)
    statsPanel:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
    statsPanel:SetBackdropColor(t.bg[1], t.bg[2], t.bg[3], 0.6)
    statsPanel:Hide()
    f.statsPanel = statsPanel

    -- Bottom bar
    local bottom = CreateFrame("Frame", nil, f, "BackdropTemplate")
    bottom:SetHeight(BOTTOM_HEIGHT - 4)
    bottom:SetPoint("BOTTOMLEFT", 2, 2)
    bottom:SetPoint("BOTTOMRIGHT", -2, 2)
    bottom:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
    bottom:SetBackdropColor(t.headerBg[1], t.headerBg[2], t.headerBg[3], 0.85)
    f.bottom = bottom

    bottom.label = bottom:CreateFontString(nil, "OVERLAY")
    bottom.label:SetFont(TM:GetFont(10, ""))
    bottom.label:SetPoint("LEFT", 10, 0)
    bottom.label:SetTextColor(t.textDim[1], t.textDim[2], t.textDim[3])

    bottom.help = bottom:CreateFontString(nil, "OVERLAY")
    bottom.help:SetFont(TM:GetFont(10, ""))
    bottom.help:SetPoint("RIGHT", -10, 0)
    bottom.help:SetTextColor(t.textDim[1], t.textDim[2], t.textDim[3])
    bottom.help:SetText("Left-click row: details   |   Right-click row: actions")

    return f
end

----------------------------------------------------------------------
-- Columns
----------------------------------------------------------------------
local COLUMNS = {
    { key = "date",       label = "Date",     x = 6,    w = 84 },
    { key = "bracket",    label = "Bkt",      x = 92,   w = 32 },
    { key = "map",        label = "Map",      x = 126,  w = 110 },
    { key = "dur",        label = "Dur",      x = 238,  w = 42 },
    { key = "comp",       label = "Team",     x = 282,  w = 116 },
    { key = "enemyComp",  label = "Enemy",    x = 400,  w = 116 },
    { key = "firstDeath", label = "1st Death",x = 518,  w = 88 },
    { key = "kd",         label = "K/D",      x = 608,  w = 44 },
    { key = "dmg",        label = "Dmg",      x = 654,  w = 50 },
    { key = "heal",       label = "Heal",     x = 706,  w = 50 },
    { key = "rating",     label = "Rating",   x = 758,  w = 52 },
    { key = "delta",      label = "+/-",      x = 812,  w = 44 },
    { key = "result",     label = "Result",   x = 858,  w = 52 },
}

function AA:CreateRow(parent, index)
    local TM = Deadpool.modules.Theme
    local t = TM.active
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
    row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -(index - 1) * ROW_HEIGHT)

    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row.bg:SetColorTexture(0, 0, 0, 0)

    row.highlight = row:CreateTexture(nil, "HIGHLIGHT")
    row.highlight:SetAllPoints()
    row.highlight:SetColorTexture(0.30, 0.10, 0.10, 0.35)

    row.cells = {}
    for i, col in ipairs(COLUMNS) do
        local fs = row:CreateFontString(nil, "OVERLAY")
        fs:SetFont(TM:GetFont(11, ""))
        fs:SetPoint("LEFT", col.x, 0)
        fs:SetWidth(col.w - 4)
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(false)
        row.cells[i] = fs
    end

    row:EnableMouseWheel(true)
    row:SetScript("OnMouseWheel", function(_, delta)
        AA._scrollOffset = AA._scrollOffset - delta
        if AA._scrollOffset < 0 then AA._scrollOffset = 0 end
        if AA._scrollOffset > AA._scrollMax then AA._scrollOffset = AA._scrollMax end
        AA.frame.scrollBar:SetValue(AA._scrollOffset)
    end)

    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetScript("OnClick", function(self, button)
        if not self.data then return end
        if button == "LeftButton" then
            AA:ShowMatchPopup(self.data)
        elseif button == "RightButton" then
            AA:ShowRowMenu(self.data)
        end
    end)

    row:SetScript("OnEnter", function(self)
        if not self.data then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        local e = self.data
        local rc = e.won and Deadpool.colors.green or Deadpool.colors.red
        GameTooltip:AddLine(rc .. (e.won and "VICTORY" or "DEFEAT") .. "|r  " .. (e.bracket or "?"))
        if e.map and e.map ~= "" then GameTooltip:AddLine(e.map, 0.8, 0.8, 0.8) end
        GameTooltip:AddLine("Duration: " .. fmtDuration(e.duration), 0.7, 0.7, 0.7)
        if e.firstDeath and e.firstDeath.name then
            local who = e.firstDeath.isEnemy and (Deadpool.colors.green .. "Enemy") or (Deadpool.colors.red .. "Team")
            GameTooltip:AddLine("First death: " .. who .. "|r " .. e.firstDeath.name, 1, 1, 1)
        end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Click for full scoreboard", 0.5, 0.5, 0.5)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)

    return row
end

----------------------------------------------------------------------
-- Header rendering
----------------------------------------------------------------------
function AA:RenderHeader()
    local TM = Deadpool.modules.Theme
    local t = TM.active
    local f = self.frame
    for _, fs in ipairs(f.headerFonts) do fs:Hide() end
    f.headerFonts = {}
    for _, col in ipairs(COLUMNS) do
        local fs = f.headerFrame:CreateFontString(nil, "OVERLAY")
        fs:SetFont(TM:GetFont(10, "OUTLINE"))
        fs:SetPoint("LEFT", col.x, 0)
        fs:SetWidth(col.w - 4)
        fs:SetJustifyH("LEFT")
        fs:SetText(col.label)
        fs:SetTextColor(TM.active.accent[1], TM.active.accent[2], TM.active.accent[3])
        f.headerFonts[#f.headerFonts + 1] = fs
    end
end

----------------------------------------------------------------------
-- History rendering
----------------------------------------------------------------------
function AA:RenderHistory()
    local f = self.frame
    if not f then return end
    local data = self:GetFilteredMatches()
    local n = #data
    local visible = #f.rows
    self._scrollMax = math.max(0, n - visible)
    if self._scrollOffset > self._scrollMax then self._scrollOffset = self._scrollMax end
    f.scrollBar:SetMinMaxValues(0, math.max(1, self._scrollMax))

    for i = 1, visible do
        local row = f.rows[i]
        local idx = i + self._scrollOffset
        local e = data[idx]
        if e then
            row.data = e
            row:Show()
            if e.won then
                row.bg:SetColorTexture(0.05, 0.22, 0.05, 0.30)
            else
                row.bg:SetColorTexture(0.22, 0.05, 0.05, 0.30)
            end
            row.cells[1]:SetText(Deadpool.colors.grey .. (e.time and date("%m/%d %H:%M", e.time) or "?") .. "|r")
            -- Bracket cell: append small "S" tag for skirmish matches
            local bktTxt = Deadpool.colors.yellow .. (e.bracket or "?") .. "|r"
            local _isRated = e.isRated
            if _isRated == nil then
                _isRated = ((e.oldRating or 0) > 0 or (e.newRating or 0) > 0)
                if not _isRated and e.scores then
                    for _, s in ipairs(e.scores) do
                        if s.ratingChange ~= nil or (s.rating or 0) > 0 then _isRated = true; break end
                    end
                end
            end
            if _isRated == false then
                bktTxt = bktTxt .. Deadpool.colors.grey .. " skirm|r"
            end
            row.cells[2]:SetText(bktTxt)
            row.cells[3]:SetText(Deadpool.colors.white .. (e.map ~= "" and (e.map or "-") or "-") .. "|r")
            row.cells[4]:SetText(Deadpool.colors.grey .. fmtDuration(e.duration) .. "|r")
            row.cells[5]:SetText(compIcons(e.scores, false, 16))
            row.cells[6]:SetText(compIcons(e.scores, true,  16))
            if e.firstDeath and e.firstDeath.name then
                local color = (e.firstDeath.isEnemy and Deadpool.colors.green) or (e.firstDeath.isEnemy == false and Deadpool.colors.red) or Deadpool.colors.grey
                row.cells[7]:SetText(color .. e.firstDeath.name .. "|r")
            else
                row.cells[7]:SetText(Deadpool.colors.grey .. "-|r")
            end
            row.cells[8]:SetText((e.myKills or 0) .. "/" .. (e.myDeaths or 0))
            -- Legacy-corrupted entries stored ratingChange (-50..+50) in
            -- damage and rating (1000..3000) in healing. Detect and grey
            -- those values out so we don't display nonsense.
            local md = tonumber(e.myDamage) or 0
            local mh = tonumber(e.myHealing) or 0
            local dmgLooksLegacy  = (md < 1000)   -- real arena dmg is always thousands
            local healLooksLegacy = (mh >= 1000 and mh <= 3500 and mh > 0)
            if dmgLooksLegacy then
                row.cells[9]:SetText(Deadpool.colors.grey .. "-|r")
            else
                row.cells[9]:SetText(Deadpool.colors.orange .. fmtNum(md) .. "|r")
            end
            if healLooksLegacy then
                row.cells[10]:SetText(Deadpool.colors.grey .. "-|r")
            else
                row.cells[10]:SetText(Deadpool.colors.green .. fmtNum(mh) .. "|r")
            end
            local rating = (e.newRating or 0) > 0 and tostring(e.newRating) or (Deadpool.colors.grey .. "-|r")
            row.cells[11]:SetText(rating)
            -- +/- column: prefer the per-player ratingChange captured on
            -- the player's scoreboard row (s.ratingChange). Fall back to
            -- the match-level newRating-oldRating diff only when both are
            -- present AND the delta is plausible (<200), to avoid the old
            -- garbage like "+1475" when oldRating was 0.
            local myName = UnitName("player")
            local pc = nil
            if e.scores then
                for _, s in ipairs(e.scores) do
                    if s.name == myName then
                        pc = tonumber(s.ratingChange)
                        break
                    end
                end
            end
            if pc == nil then
                local change = (e.newRating or 0) - (e.oldRating or 0)
                if (e.newRating or 0) > 0 and (e.oldRating or 0) > 0 and math.abs(change) < 200 then
                    pc = change
                end
            end
            if pc and pc ~= 0 then
                local cc = pc >= 0 and Deadpool.colors.green or Deadpool.colors.red
                row.cells[12]:SetText(cc .. (pc >= 0 and ("+" .. pc) or tostring(pc)) .. "|r")
            else
                row.cells[12]:SetText(Deadpool.colors.grey .. "-|r")
            end
            local rc = e.won and Deadpool.colors.green or Deadpool.colors.red
            row.cells[13]:SetText(rc .. (e.won and "WIN" or "LOSS") .. "|r")
        else
            row.data = nil
            row:Hide()
        end
    end

    -- Stats banner
    local raw = Deadpool.db.arenaLog or {}
    local fW, fL = 0, 0
    for _, e in ipairs(data) do
        if e.won then fW = fW + 1 else fL = fL + 1 end
    end
    local fwr = (fW + fL) > 0 and math.floor(fW / (fW + fL) * 100) or 0
    local sess = self:GetCurrentSessionStats()
    local peak = 0
    for _, e in ipairs(raw) do if (e.newRating or 0) > peak then peak = e.newRating end end
    local sMmrColor = sess.mmrDelta >= 0 and Deadpool.colors.green or Deadpool.colors.red
    local sMmrStr = sess.mmrDelta >= 0 and ("+" .. sess.mmrDelta) or tostring(sess.mmrDelta)
    f.stats.label:SetText(
        Deadpool.colors.green .. fW .. "W|r / " .. Deadpool.colors.red .. fL .. "L|r  " ..
        Deadpool.colors.grey .. "(" .. fwr .. "%)|r" ..
        Deadpool.colors.grey .. "   |   |r" ..
        "Peak: " .. Deadpool.modules.Theme:AccentHex() .. (peak > 0 and peak or "-") .. "|r" ..
        Deadpool.colors.grey .. "   |   |r" ..
        "Session: " .. sess.wins .. "W/" .. sess.losses .. "L  " .. sMmrColor .. sMmrStr .. " MMR|r" ..
        Deadpool.colors.grey .. "   |   |r" ..
        "Total: " .. #raw .. "  |  Shown: " .. n
    )
    f.bottom.label:SetText(Deadpool.colors.grey .. n .. " of " .. #raw .. " matches|r")
end

----------------------------------------------------------------------
-- Stats panel rendering
----------------------------------------------------------------------
function AA:RenderStats()
    local TM = Deadpool.modules.Theme
    local t = TM.active
    local f = self.frame
    local panel = f.statsPanel

    -- wipe previous
    if panel._children then
        for _, c in ipairs(panel._children) do c:Hide(); c:SetParent(nil) end
    end
    panel._children = {}

    local function add(child) panel._children[#panel._children + 1] = child end

    local raw = self:GetFilteredMatches()
    local total = #raw
    local wins, losses = 0, 0
    local mmrPeak, mmrLow = 0, 99999
    local mmrFirst, mmrLast = nil, nil
    local dmgTotal, healTotal = 0, 0
    local kTotal, dTotal = 0, 0
    local compStats = {}
    local enemyCompStats = {}
    local mapStats = {}
    local bracketStats = { ["2v2"] = { w = 0, l = 0 }, ["3v3"] = { w = 0, l = 0 }, ["5v5"] = { w = 0, l = 0 } }
    local longest = 0
    local shortest = 999999
    local winStreak, lossStreak = 0, 0
    local curStreak, curStreakIsWin = 0, nil
    local bestWinStreak, bestLossStreak = 0, 0

    -- iterate newest-first; track streak from newest
    local dmgCount, healCount = 0, 0
    for i, e in ipairs(raw) do
        if e.won then wins = wins + 1 else losses = losses + 1 end
        if (e.newRating or 0) > mmrPeak then mmrPeak = e.newRating end
        if (e.newRating or 0) > 0 and e.newRating < mmrLow then mmrLow = e.newRating end
        if i == 1 then mmrLast = e.newRating end
        mmrFirst = e.newRating ~= 0 and e.newRating or mmrFirst
        -- Skip corrupted legacy values (dmg < 1000 or heal in rating range)
        local md = tonumber(e.myDamage) or 0
        local mh = tonumber(e.myHealing) or 0
        if md >= 1000 then dmgTotal = dmgTotal + md; dmgCount = dmgCount + 1 end
        if mh > 0 and not (mh >= 1000 and mh <= 3500) then healTotal = healTotal + mh; healCount = healCount + 1 end
        kTotal = kTotal + (e.myKills or 0)
        dTotal = dTotal + (e.myDeaths or 0)
        local mc = AA:GetMatchComp(e, false)
        local ec = AA:GetMatchComp(e, true)
        compStats[mc] = compStats[mc] or { w = 0, l = 0 }
        if e.won then compStats[mc].w = compStats[mc].w + 1 else compStats[mc].l = compStats[mc].l + 1 end
        enemyCompStats[ec] = enemyCompStats[ec] or { w = 0, l = 0 }
        if e.won then enemyCompStats[ec].w = enemyCompStats[ec].w + 1 else enemyCompStats[ec].l = enemyCompStats[ec].l + 1 end
        if e.map and e.map ~= "" then
            mapStats[e.map] = mapStats[e.map] or { w = 0, l = 0 }
            if e.won then mapStats[e.map].w = mapStats[e.map].w + 1 else mapStats[e.map].l = mapStats[e.map].l + 1 end
        end
        if bracketStats[e.bracket or ""] then
            if e.won then bracketStats[e.bracket].w = bracketStats[e.bracket].w + 1
            else bracketStats[e.bracket].l = bracketStats[e.bracket].l + 1 end
        end
        if (e.duration or 0) > longest then longest = e.duration end
        if (e.duration or 0) > 0 and e.duration < shortest then shortest = e.duration end

        -- streak from newest
        if curStreakIsWin == nil then
            curStreakIsWin = e.won; curStreak = 1
        elseif curStreakIsWin == e.won then
            curStreak = curStreak + 1
        end
    end
    if mmrLow == 99999 then mmrLow = 0 end
    if shortest == 999999 then shortest = 0 end
    if curStreakIsWin then bestWinStreak = curStreak else bestLossStreak = curStreak end

    -- Compute full best streaks across history (chronological)
    do
        local chronological = {}
        for i = #raw, 1, -1 do chronological[#chronological + 1] = raw[i] end
        local run = 0; local runWin = nil
        for _, e in ipairs(chronological) do
            if runWin == nil or runWin ~= e.won then
                run = 1; runWin = e.won
            else
                run = run + 1
            end
            if e.won and run > bestWinStreak then bestWinStreak = run end
            if (not e.won) and run > bestLossStreak then bestLossStreak = run end
        end
    end

    local wr = (wins + losses) > 0 and math.floor(wins / (wins + losses) * 100) or 0

    local yCursor = -16
    local function row(label, value, color)
        local lbl = panel:CreateFontString(nil, "OVERLAY")
        lbl:SetFont(TM:GetFont(11, ""))
        lbl:SetPoint("TOPLEFT", 24, yCursor)
        lbl:SetTextColor(t.textDim[1], t.textDim[2], t.textDim[3])
        lbl:SetText(label)
        add(lbl)
        local val = panel:CreateFontString(nil, "OVERLAY")
        val:SetFont(TM:GetFont(11, "OUTLINE"))
        val:SetPoint("TOPLEFT", 220, yCursor)
        val:SetText(color and (color .. value .. "|r") or value)
        add(val)
        yCursor = yCursor - 18
    end

    local function header(label)
        yCursor = yCursor - 8
        local h = panel:CreateFontString(nil, "OVERLAY")
        h:SetFont(TM:GetFont(12, "OUTLINE"))
        h:SetPoint("TOPLEFT", 16, yCursor)
        h:SetText(TM:AccentHex() .. label .. "|r")
        add(h)
        yCursor = yCursor - 22
    end

    header("OVERALL")
    row("Total matches", tostring(total))
    row("Record", wins .. "W / " .. losses .. "L")
    row("Win rate", wr .. "%", wr >= 50 and Deadpool.colors.green or Deadpool.colors.red)
    row("Current streak", curStreak .. " " .. (curStreakIsWin and "Wins" or "Losses"),
        curStreakIsWin and Deadpool.colors.green or Deadpool.colors.red)
    row("Best win streak", tostring(bestWinStreak), Deadpool.colors.green)
    row("Worst loss streak", tostring(bestLossStreak), Deadpool.colors.red)

    header("RATING")
    row("Peak", tostring(mmrPeak), TM:AccentHex())
    row("Low", tostring(mmrLow))
    row("Current", tostring(mmrLast or 0))

    header("PERFORMANCE")
    row("Total kills", tostring(kTotal), Deadpool.colors.green)
    row("Total deaths", tostring(dTotal), Deadpool.colors.red)
    row("K/D ratio", dTotal > 0 and string.format("%.2f", kTotal / dTotal) or "INF")
    row("Avg damage / match", dmgCount > 0 and fmtNum(math.floor(dmgTotal / dmgCount)) or "0", Deadpool.colors.orange)
    row("Avg healing / match", healCount > 0 and fmtNum(math.floor(healTotal / healCount)) or "0", Deadpool.colors.green)

    -- Right column: per-bracket
    local rightY = -16
    local function rRow(label, value, color)
        local lbl = panel:CreateFontString(nil, "OVERLAY")
        lbl:SetFont(TM:GetFont(11, ""))
        lbl:SetPoint("TOPLEFT", 520, rightY)
        lbl:SetTextColor(t.textDim[1], t.textDim[2], t.textDim[3])
        lbl:SetText(label)
        add(lbl)
        local val = panel:CreateFontString(nil, "OVERLAY")
        val:SetFont(TM:GetFont(11, "OUTLINE"))
        val:SetPoint("TOPLEFT", 700, rightY)
        val:SetText(color and (color .. value .. "|r") or value)
        add(val)
        rightY = rightY - 18
    end
    local function rHeader(label)
        rightY = rightY - 8
        local h = panel:CreateFontString(nil, "OVERLAY")
        h:SetFont(TM:GetFont(12, "OUTLINE"))
        h:SetPoint("TOPLEFT", 512, rightY)
        h:SetText(TM:AccentHex() .. label .. "|r")
        add(h)
        rightY = rightY - 22
    end

    rHeader("BY BRACKET")
    for _, b in ipairs({ "2v2", "3v3", "5v5" }) do
        local s = bracketStats[b]
        local r = (s.w + s.l) > 0 and math.floor(s.w / (s.w + s.l) * 100) or 0
        rRow(b, s.w .. "W / " .. s.l .. "L  (" .. r .. "%)")
    end

    rHeader("DURATIONS")
    rRow("Longest", fmtDuration(longest))
    rRow("Shortest", fmtDuration(shortest))
    rRow("Total time", fmtDuration(math.floor((function()
        local tt = 0; for _, e in ipairs(raw) do tt = tt + (e.duration or 0) end; return tt
    end)())))

    rHeader("TOP COMPS (yours)")
    local compList = {}
    for c, s in pairs(compStats) do compList[#compList + 1] = { c = c, w = s.w, l = s.l, t = s.w + s.l } end
    table.sort(compList, function(a, b) return a.t > b.t end)
    for i = 1, math.min(4, #compList) do
        local c = compList[i]
        local r = math.floor(c.w / c.t * 100)
        rRow(compColored(c.c), c.w .. "W/" .. c.l .. "L  (" .. r .. "%)")
    end

    rHeader("TOP ENEMY COMPS")
    local ecList = {}
    for c, s in pairs(enemyCompStats) do ecList[#ecList + 1] = { c = c, w = s.w, l = s.l, t = s.w + s.l } end
    table.sort(ecList, function(a, b) return a.t > b.t end)
    for i = 1, math.min(4, #ecList) do
        local c = ecList[i]
        local r = math.floor(c.w / c.t * 100)
        rRow(compColored(c.c), c.w .. "W/" .. c.l .. "L  (" .. r .. "%)")
    end
end

----------------------------------------------------------------------
-- Match detail popup
----------------------------------------------------------------------
function AA:ShowMatchPopup(match)
    local TM = Deadpool.modules.Theme
    local t = TM.active

    if self._popup then self._popup:Hide(); self._popup:SetParent(nil) end
    local popup = CreateFrame("Frame", "DeadpoolAAMatchPopup", UIParent, "BackdropTemplate")
    popup:SetSize(640, 440)
    popup:SetPoint("CENTER", 0, 0)
    popup:SetFrameStrata("TOOLTIP")
    popup:SetToplevel(true)
    popup:SetMovable(true); popup:EnableMouse(true)
    popup:RegisterForDrag("LeftButton")
    popup:SetScript("OnDragStart", popup.StartMoving)
    popup:SetScript("OnDragStop", popup.StopMovingOrSizing)
    popup:SetClampedToScreen(true)
    tinsert(UISpecialFrames, "DeadpoolAAMatchPopup")
    self._popup = popup

    local resultColor = match.won and { 0.30, 0.85, 0.30 } or { 0.85, 0.25, 0.25 }
    popup:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 2,
    })
    popup:SetBackdropColor(t.bg[1], t.bg[2], t.bg[3], 0.97)
    popup:SetBackdropBorderColor(resultColor[1], resultColor[2], resultColor[3], 0.95)

    local topBar = popup:CreateTexture(nil, "ARTWORK")
    topBar:SetHeight(3)
    topBar:SetPoint("TOPLEFT", 2, -2); topBar:SetPoint("TOPRIGHT", -2, -2)
    topBar:SetColorTexture(resultColor[1], resultColor[2], resultColor[3], 0.95)

    local close = CreateFrame("Button", nil, popup)
    close:SetSize(24, 24); close:SetPoint("TOPRIGHT", -6, -6)
    local x = close:CreateFontString(nil, "OVERLAY")
    x:SetFont(TM:GetFont(14, "OUTLINE")); x:SetPoint("CENTER"); x:SetText("X")
    x:SetTextColor(0.8, 0.2, 0.2)
    close:SetScript("OnClick", function() popup:Hide() end)

    local rc = match.won and Deadpool.colors.green or Deadpool.colors.red
    local header = popup:CreateFontString(nil, "OVERLAY")
    header:SetFont(TM:GetFont(16, "OUTLINE")); header:SetPoint("TOP", 0, -12)
    header:SetText(rc .. (match.won and "VICTORY" or "DEFEAT") .. "|r  " ..
        Deadpool.colors.yellow .. (match.bracket or "?") .. "|r")

    local subhead = popup:CreateFontString(nil, "OVERLAY")
    subhead:SetFont(TM:GetFont(10, "")); subhead:SetPoint("TOP", 0, -32)
    subhead:SetTextColor(t.textDim[1], t.textDim[2], t.textDim[3])
    subhead:SetText((match.map ~= "" and match.map or "Unknown map") .. "  |  " ..
        fmtDuration(match.duration) .. "  |  " .. (match.time and date("%Y-%m-%d %H:%M", match.time) or "?"))

    -- Comp lines
    local cy = -54
    local function infoRow(label, value, color)
        local lbl = popup:CreateFontString(nil, "OVERLAY")
        lbl:SetFont(TM:GetFont(10, "")); lbl:SetPoint("TOPLEFT", 20, cy)
        lbl:SetTextColor(t.textDim[1], t.textDim[2], t.textDim[3])
        lbl:SetText(label)
        local val = popup:CreateFontString(nil, "OVERLAY")
        val:SetFont(TM:GetFont(11, "")); val:SetPoint("TOPLEFT", 110, cy)
        val:SetText(color and (color .. value .. "|r") or value)
        cy = cy - 16
    end

    infoRow("Your comp", compIcons(match.scores, false, 18))
    infoRow("Enemy comp", compIcons(match.scores, true, 18))
    infoRow("Type", match.isRated == false and (Deadpool.colors.grey .. "Skirmish|r") or (Deadpool.colors.yellow .. "Rated|r"))
    if (match.newRating or 0) > 0 then
        -- Pull authoritative rating change from the player's row, same as
        -- the history list. Match-level oldRating is often 0 on legacy
        -- entries so newRating-oldRating produces nonsense like "+1466".
        local myName = UnitName("player")
        local pc = nil
        if match.scores then
            for _, s in ipairs(match.scores) do
                if s.name == myName then pc = tonumber(s.ratingChange); break end
            end
        end
        if pc == nil and (match.oldRating or 0) > 0 then
            local diff = match.newRating - match.oldRating
            if math.abs(diff) < 200 then pc = diff end
        end
        if pc and pc ~= 0 then
            local cc = pc >= 0 and Deadpool.colors.green or Deadpool.colors.red
            infoRow("Rating",  match.newRating .. " (" .. cc .. (pc >= 0 and ("+" .. pc) or tostring(pc)) .. "|r)")
        else
            infoRow("Rating", tostring(match.newRating))
        end
    end
    if match.firstDeath and match.firstDeath.name then
        local color = (match.firstDeath.isEnemy and Deadpool.colors.green) or (match.firstDeath.isEnemy == false and Deadpool.colors.red) or Deadpool.colors.grey
        infoRow("First death", color .. match.firstDeath.name .. "|r")
    end

    -- Scoreboard header
    cy = cy - 8
    local sbHeader = popup:CreateFontString(nil, "OVERLAY")
    sbHeader:SetFont(TM:GetFont(11, "OUTLINE")); sbHeader:SetPoint("TOPLEFT", 20, cy)
    sbHeader:SetText(TM:AccentHex() .. "SCOREBOARD|r")
    cy = cy - 16
    local hdrs = { { "Player", 20 }, { "Race", 160 }, { "K", 230 }, { "D", 258 }, { "Dmg", 290 }, { "Heal", 360 }, { "Rating", 430 }, { "+/-", 490 } }
    for _, h in ipairs(hdrs) do
        local fs = popup:CreateFontString(nil, "OVERLAY")
        fs:SetFont(TM:GetFont(9, "OUTLINE")); fs:SetPoint("TOPLEFT", h[2], cy)
        fs:SetText(h[1])
        fs:SetTextColor(t.textDim[1], t.textDim[2], t.textDim[3])
    end
    cy = cy - 14

    -- Rows: team first, then enemy
    local sorted = {}
    for _, s in ipairs(match.scores or {}) do sorted[#sorted + 1] = s end
    table.sort(sorted, function(a, b)
        if a.isEnemy ~= b.isEnemy then return not a.isEnemy end
        return (a.damage or 0) > (b.damage or 0)
    end)
    local lastTeam = nil
    for _, s in ipairs(sorted) do
        if lastTeam ~= nil and lastTeam ~= s.isEnemy then
            cy = cy - 4
            local div = popup:CreateTexture(nil, "ARTWORK")
            div:SetHeight(1); div:SetPoint("TOPLEFT", 20, cy); div:SetPoint("TOPRIGHT", -20, cy)
            div:SetColorTexture(t.border[1], t.border[2], t.border[3], 0.4)
            cy = cy - 6
        end
        lastTeam = s.isEnemy
        local name = s.name or "?"
        if s.name == UnitName("player") then
            name = Deadpool.colors.cyan .. name .. "|r"
        else
            name = classColored(name, s.class)
        end
        if s.isEnemy then name = name .. " " .. Deadpool.colors.red .. "(E)|r" end
        local fName = popup:CreateFontString(nil, "OVERLAY")
        fName:SetFont(TM:GetFont(11, "")); fName:SetPoint("TOPLEFT", 20, cy); fName:SetText(name)

        local fRace = popup:CreateFontString(nil, "OVERLAY")
        fRace:SetFont(TM:GetFont(10, "")); fRace:SetPoint("TOPLEFT", 160, cy)
        fRace:SetText(Deadpool.colors.grey .. (s.race or "-") .. "|r")

        local fK = popup:CreateFontString(nil, "OVERLAY")
        fK:SetFont(TM:GetFont(11, "")); fK:SetPoint("TOPLEFT", 230, cy); fK:SetText(tostring(s.kills or 0))
        local fD = popup:CreateFontString(nil, "OVERLAY")
        fD:SetFont(TM:GetFont(11, "")); fD:SetPoint("TOPLEFT", 258, cy); fD:SetText(tostring(s.deaths or 0))
        local fDmg = popup:CreateFontString(nil, "OVERLAY")
        fDmg:SetFont(TM:GetFont(11, "")); fDmg:SetPoint("TOPLEFT", 290, cy)
        local sd = tonumber(s.damage) or 0
        if sd < 1000 then
            fDmg:SetText(Deadpool.colors.grey .. "-|r")
        else
            fDmg:SetText(Deadpool.colors.orange .. fmtNum(sd) .. "|r")
        end
        local fHeal = popup:CreateFontString(nil, "OVERLAY")
        fHeal:SetFont(TM:GetFont(11, "")); fHeal:SetPoint("TOPLEFT", 360, cy)
        local sh = tonumber(s.healing) or 0
        if sh > 0 and sh >= 1000 and sh <= 3500 then
            fHeal:SetText(Deadpool.colors.grey .. "-|r")
        else
            fHeal:SetText(Deadpool.colors.green .. fmtNum(sh) .. "|r")
        end

        -- Per-player rating + change
        local fRating = popup:CreateFontString(nil, "OVERLAY")
        fRating:SetFont(TM:GetFont(11, "")); fRating:SetPoint("TOPLEFT", 430, cy)
        local sr = tonumber(s.rating) or 0
        if sr > 0 then
            fRating:SetText(sr)
        else
            -- Fall back to match-level rating for the player only
            if s.name == UnitName("player") and (match.newRating or 0) > 0 then
                fRating:SetText(match.newRating)
            else
                fRating:SetText(Deadpool.colors.grey .. "-|r")
            end
        end

        local fDelta = popup:CreateFontString(nil, "OVERLAY")
        fDelta:SetFont(TM:GetFont(11, "")); fDelta:SetPoint("TOPLEFT", 490, cy)
        local pc = tonumber(s.ratingChange)
        if pc == nil and s.name == UnitName("player") and (match.newRating or 0) > 0 and (match.oldRating or 0) > 0 then
            pc = match.newRating - match.oldRating
        end
        if pc and pc ~= 0 then
            local cc = pc >= 0 and Deadpool.colors.green or Deadpool.colors.red
            fDelta:SetText(cc .. (pc >= 0 and ("+" .. pc) or tostring(pc)) .. "|r")
        else
            fDelta:SetText(Deadpool.colors.grey .. "-|r")
        end

        -- Quick search click
        fName:SetJustifyH("LEFT")
        local clickArea = CreateFrame("Button", nil, popup)
        clickArea:SetSize(160, 14); clickArea:SetPoint("TOPLEFT", 20, cy)
        clickArea:SetScript("OnClick", function(_, btn)
            if not AA.frame then return end
            local segment = s.name
            if btn == "RightButton" and s.class then
                segment = ALIAS_TO_CLASS[s.class:lower()] and s.class:lower() or s.name
            end
            if IsShiftKeyDown() then
                local cur = AA.state.search
                AA.state.search = (cur ~= "" and cur .. ", " or "") .. segment
            elseif IsAltKeyDown() then
                AA.state.search = "no " .. segment
            elseif IsControlKeyDown() and s.class then
                AA.state.search = s.class:lower()
            else
                AA.state.search = segment
            end
            AA.frame._searchBox:SetText(AA.state.search)
            AA:Refresh()
        end)
        clickArea:RegisterForClicks("LeftButtonUp", "RightButtonUp")

        cy = cy - 16
    end

    popup:SetHeight(math.max(280, math.abs(cy) + 24))
    popup:Show()
end

----------------------------------------------------------------------
-- Row right-click menu
----------------------------------------------------------------------
function AA:ShowRowMenu(match)
    if not self._rowMenu then
        self._rowMenu = CreateFrame("Frame", "DeadpoolAARowMenu", UIParent, "UIDropDownMenuTemplate")
    end
    local items = {
        { text = "Match Actions", isTitle = true, notCheckable = true },
        { text = "View full details", notCheckable = true, func = function() AA:ShowMatchPopup(match) end },
        { text = "Add enemy team to KOS", notCheckable = true, func = function()
            for _, s in ipairs(match.scores or {}) do
                if s.isEnemy and s.fullName then
                    Deadpool:AddToKOS(s.fullName, "Arena opponent")
                end
            end
        end },
        { text = "Delete this match", notCheckable = true, func = function()
            local log = Deadpool.db.arenaLog
            for i = #log, 1, -1 do if log[i] == match then table.remove(log, i); break end end
            AA:Refresh()
        end },
        { text = "Cancel", notCheckable = true },
    }
    UIDropDownMenu_Initialize(self._rowMenu, function(_, level)
        for _, item in ipairs(items) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = item.text
            info.isTitle = item.isTitle
            info.notCheckable = item.notCheckable
            info.func = item.func
            UIDropDownMenu_AddButton(info, level or 1)
        end
    end, "MENU")
    ToggleDropDownMenu(1, nil, self._rowMenu, "cursor", 0, 0)
end

----------------------------------------------------------------------
-- Export to CSV (printed in a copyable popup)
----------------------------------------------------------------------
function AA:Export()
    local data = self:GetFilteredMatches()
    local lines = { "date,bracket,map,duration,result,team_comp,enemy_comp,first_death,my_kills,my_deaths,my_dmg,my_heal,old_rating,new_rating" }
    for _, e in ipairs(data) do
        lines[#lines + 1] = table.concat({
            (e.time and date("%Y-%m-%d %H:%M:%S", e.time) or ""),
            e.bracket or "",
            e.map or "",
            tostring(e.duration or 0),
            e.won and "WIN" or "LOSS",
            AA:GetMatchComp(e, false),
            AA:GetMatchComp(e, true),
            (e.firstDeath and e.firstDeath.name) or "",
            tostring(e.myKills or 0),
            tostring(e.myDeaths or 0),
            tostring(e.myDamage or 0),
            tostring(e.myHealing or 0),
            tostring(e.oldRating or 0),
            tostring(e.newRating or 0),
        }, ",")
    end
    self:ShowExportPopup(table.concat(lines, "\n"))
end

function AA:ShowExportPopup(text)
    if self._exportPopup then self._exportPopup:Hide(); self._exportPopup:SetParent(nil) end
    local TM = Deadpool.modules.Theme
    local t = TM.active
    local p = CreateFrame("Frame", "DeadpoolAAExport", UIParent, "BackdropTemplate")
    p:SetSize(640, 460); p:SetPoint("CENTER")
    p:SetFrameStrata("TOOLTIP"); p:SetToplevel(true); p:EnableMouse(true); p:SetMovable(true)
    p:RegisterForDrag("LeftButton")
    p:SetScript("OnDragStart", p.StartMoving); p:SetScript("OnDragStop", p.StopMovingOrSizing)
    tinsert(UISpecialFrames, "DeadpoolAAExport")
    p:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 2,
    })
    p:SetBackdropColor(t.bg[1], t.bg[2], t.bg[3], 0.97)
    p:SetBackdropBorderColor(t.accent[1], t.accent[2], t.accent[3], 0.9)
    self._exportPopup = p

    local title = p:CreateFontString(nil, "OVERLAY")
    title:SetFont(TM:GetFont(14, "OUTLINE")); title:SetPoint("TOP", 0, -10)
    title:SetText(TM:AccentHex() .. "EXPORT CSV|r")

    local hint = p:CreateFontString(nil, "OVERLAY")
    hint:SetFont(TM:GetFont(10, "")); hint:SetPoint("TOP", 0, -30)
    hint:SetTextColor(t.textDim[1], t.textDim[2], t.textDim[3])
    hint:SetText("Click in the box, Ctrl-A to select all, Ctrl-C to copy")

    local scroll = CreateFrame("ScrollFrame", nil, p, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 16, -50)
    scroll:SetPoint("BOTTOMRIGHT", -36, 50)

    local eb = CreateFrame("EditBox", nil, scroll)
    eb:SetMultiLine(true)
    eb:SetFont(TM:GetFont(10, ""))
    eb:SetWidth(580)
    eb:SetAutoFocus(false)
    eb:SetText(text)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    scroll:SetScrollChild(eb)

    local close = makeButton(p, "Close", 80, 24, function() p:Hide() end)
    close:SetPoint("BOTTOM", 0, 14)
end

----------------------------------------------------------------------
-- Show / hide / refresh (tab-integrated)
----------------------------------------------------------------------
function AA:Toggle()
    -- Open main UI and switch to arena tab; if already on arena tab, close UI.
    local mainFrame = _G["DeadpoolMainFrame"]
    if mainFrame and mainFrame:IsShown() and self.frame and self.frame:IsShown() then
        mainFrame:Hide()
        return
    end
    Deadpool:ShowTab("arena")
end

function AA:Show()
    -- Render-only; visibility is owned by UI:SelectTab. Will create the frame
    -- on first call (main UI must already exist).
    if not self.frame then self:CreateFrame() end
    if not self.frame then return end
    self.frame:Show()
    self:Refresh()
end

function AA:Hide()
    if self.frame then self.frame:Hide() end
end

function AA:Refresh()
    if not self.frame then return end
    self.frame._tabHistory:SetActive(self.state.view == "history")
    self.frame._tabStats:SetActive(self.state.view == "stats")
    if self.state.view == "history" then
        self.frame.statsPanel:Hide()
        self.frame.headerFrame:Show()
        self.frame.rowContainer:Show()
        self.frame.scrollBar:Show()
        self:RenderHeader()
        self:RenderHistory()
    else
        self.frame.headerFrame:Hide()
        self.frame.rowContainer:Hide()
        self.frame.scrollBar:Hide()
        self.frame.statsPanel:Show()
        self:RenderStats()
    end
    -- Refresh dropdowns (map / comp may have grown)
    self.frame.dateDD.btn:Refresh()
    self.frame.mapDD.btn:Refresh()
    self.frame.compDD.btn:Refresh()
end

----------------------------------------------------------------------
-- Init
----------------------------------------------------------------------
function AA:Init()
    self:InitTracker()
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------
function Deadpool:ToggleArenaAnalytics() AA:Toggle() end
function Deadpool:ShowArenaAnalytics()   AA:Show()   end
