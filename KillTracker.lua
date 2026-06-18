----------------------------------------------------------------------
-- Deadpool - KillTracker.lua
-- Combat log parsing for killing blows + KOS detection on sight
----------------------------------------------------------------------

local KillTracker = {}
Deadpool:RegisterModule("KillTracker", KillTracker)

-- Bitfield constants for combat log flags
local COMBATLOG_OBJECT_TYPE_PLAYER     = 0x00000400
local COMBATLOG_OBJECT_REACTION_HOSTILE = 0x00000040
local COMBATLOG_OBJECT_AFFILIATION_MINE = 0x00000001
local COMBATLOG_OBJECT_AFFILIATION_PARTY = 0x00000002
local COMBATLOG_OBJECT_AFFILIATION_RAID = 0x00000004

-- Shared sighting cooldown: lives on Deadpool namespace so Sync can also dedup.
-- Local reference for convenience; Sync.lua reads Deadpool._sightingCooldowns.
if not Deadpool._sightingCooldowns then Deadpool._sightingCooldowns = {} end
local SIGHTING_COOLDOWN = 60  -- seconds between re-alerting/re-broadcasting for same target

function KillTracker:Init()
    -- Register combat log events
    Deadpool:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED", function()
        KillTracker:OnCombatLogEvent()
    end)

    -- Register unit scanning events for KOS detection
    Deadpool:RegisterEvent("PLAYER_TARGET_CHANGED", function()
        KillTracker:ScanUnit("target")
    end)

    Deadpool:RegisterEvent("UPDATE_MOUSEOVER_UNIT", function()
        KillTracker:ScanUnit("mouseover")
    end)

    Deadpool:RegisterEvent("NAME_PLATE_UNIT_ADDED", function(event, unitId)
        KillTracker:ScanUnit(unitId)
    end)

    -- Arena match tracking
    KillTracker:InitArenaTracker()
end

----------------------------------------------------------------------
-- Arena Match Tracker (local only — no sync)
-- Records every arena match: bracket, result, rating, full scoreboard
----------------------------------------------------------------------
local arenaState = { inArena = false, recorded = false, enterTime = 0, isRated = false }

function KillTracker:InitArenaTracker()
    -- Detect arena entry
    Deadpool:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        local inInstance, instanceType = IsInInstance()
        if inInstance and instanceType == "arena" then
            if not arenaState.inArena then
                arenaState.inArena = true
                arenaState.recorded = false
                arenaState.enterTime = time()
                -- Detect rated vs skirmish (IsActiveBattlefieldArena returns isArena, isRated)
                arenaState.isRated = false
                if IsActiveBattlefieldArena then
                    local ok, _, rated = pcall(IsActiveBattlefieldArena)
                    if ok then arenaState.isRated = rated and true or false end
                end
                Deadpool:Debug("Arena entered (" .. (arenaState.isRated and "RATED" or "SKIRMISH") .. ")")
            end
        else
            if arenaState.inArena then
                -- Left arena — last chance to capture result
                if not arenaState.recorded then
                    KillTracker:CaptureArenaResult()
                end
                arenaState.inArena = false
            end
        end
    end)

    -- Match end detection — multiple events for reliability
    Deadpool:RegisterEvent("UPDATE_BATTLEFIELD_STATUS", function()
        if not arenaState.inArena or arenaState.recorded then return end
        KillTracker:CaptureArenaResult()
        C_Timer.After(1, function()
            if not arenaState.recorded then KillTracker:CaptureArenaResult() end
        end)
        C_Timer.After(3, function()
            if not arenaState.recorded then KillTracker:CaptureArenaResult() end
        end)
    end)

    -- Also check on CHAT_MSG_BG_SYSTEM_NEUTRAL (arena win/loss announcement)
    Deadpool:RegisterEvent("CHAT_MSG_BG_SYSTEM_NEUTRAL", function()
        if not arenaState.inArena or arenaState.recorded then return end
        C_Timer.After(0.5, function()
            if not arenaState.recorded then KillTracker:CaptureArenaResult() end
        end)
        C_Timer.After(2, function()
            if not arenaState.recorded then KillTracker:CaptureArenaResult() end
        end)
    end)

    -- Periodic check while in arena (fallback for missed events)
    if C_Timer and C_Timer.NewTicker then
        C_Timer.NewTicker(5, function()
            if arenaState.inArena and not arenaState.recorded then
                KillTracker:CaptureArenaResult()
            end
        end)
    end
end

function KillTracker:CaptureArenaResult()
    if arenaState.recorded then return end

    -- GetBattlefieldWinner: nil = ongoing, 0 = Green team, 1 = Gold team
    local winner = GetBattlefieldWinner and GetBattlefieldWinner()
    if winner == nil then return end  -- match still in progress

    local numScores = GetNumBattlefieldScores and GetNumBattlefieldScores() or 0
    if numScores == 0 then return end  -- scoreboard not ready

    arenaState.recorded = true

    -- Find which team we're on
    local myName = UnitName("player")
    local myTeam = nil
    local scores = {}

    -- Rating fields harvested off the player's row (TBC arena appends them
    -- after damage/healing — that's why the old "last two numbers" assumption
    -- gave us junk for damage/heal and showed ~1500 for everyone).
    local playerRowFields = nil

    for i = 1, numScores do
        -- TBC arena GetBattlefieldScore layout (after extensive testing):
        --   1=name, 2=killingBlows, 3=honorableKills, 4=deaths,
        --   5=honorGained, 6=faction, 7=rank, 8=race(localized),
        --   9=class(localized), 10=classToken(UPPER), 11=damageDone, 12=healingDone,
        --   13+ = rating/MMR/ratingChange (varies by build)
        -- The class fields can shift by ±1 depending on rank presence, so
        -- anchor on classToken (the only ALL-CAPS string ≥4 chars in the row)
        -- and read damage/healing as classToken+1, classToken+2.
        local fields = { GetBattlefieldScore(i) }
        local name = fields[1]
        if name then
            local shortName = name:match("^(.-)%-") or name
            local numFields = #fields

            local killingBlows = tonumber(fields[2]) or 0
            local deaths       = tonumber(fields[4]) or 0
            local faction      = tonumber(fields[6]) or 0

            -- Locate classToken (scan forward from field 7; first uppercase token wins)
            local classTokenIdx = nil
            local classToken = nil
            for fi = 7, math.min(numFields, 14) do
                local v = fields[fi]
                if type(v) == "string" and v:match("^%u[%u_]+$") and #v >= 4 then
                    classToken = v
                    classTokenIdx = fi
                    break
                end
            end

            -- Damage / healing live immediately after classToken
            local damageDone, healingDone = 0, 0
            if classTokenIdx then
                damageDone  = tonumber(fields[classTokenIdx + 1]) or 0
                healingDone = tonumber(fields[classTokenIdx + 2]) or 0
            end

            -- Fallback: if we didn't find a classToken (shouldn't happen),
            -- pick the two largest numeric fields after position 6 — damage
            -- and healing in arena are reliably the biggest numbers in the row
            -- (ratings cap ~3000, dmg/heal range 10k–500k+).
            if (damageDone == 0 and healingDone == 0) or not classTokenIdx then
                local nums = {}
                for fi = 7, numFields do
                    local n = tonumber(fields[fi])
                    if n and n >= 5000 then nums[#nums + 1] = { idx = fi, v = n } end
                end
                table.sort(nums, function(a, b) return a.v > b.v end)
                if nums[1] then
                    -- Pair them by index order so dmg comes before heal positionally
                    local pair = { nums[1], nums[2] }
                    if pair[2] and pair[1].idx > pair[2].idx then
                        pair[1], pair[2] = pair[2], pair[1]
                    end
                    damageDone  = pair[1] and pair[1].v or damageDone
                    healingDone = pair[2] and pair[2].v or healingDone
                end
            end

            -- Per-player rating / rating change extraction from trailing fields.
            -- After dmg/heal come the rating fields. We look for any number in
            -- the 1000-3500 range (plausible rating window) and the small
            -- signed delta that lives next to it (-50..+50).
            local pRating, pRatingChange = 0, nil
            do
                local ratings = {}
                local deltas = {}
                local scanStart = (classTokenIdx and classTokenIdx + 3) or 13
                for fi = scanStart, numFields do
                    local n = tonumber(fields[fi])
                    if n then
                        if n >= 1000 and n <= 3500 then
                            ratings[#ratings + 1] = { idx = fi, v = n }
                        elseif n >= -100 and n <= 100 and n ~= 0 then
                            deltas[#deltas + 1] = { idx = fi, v = n }
                        end
                    end
                end
                if #ratings > 0 then
                    -- Take the last rating in the row as post-match rating
                    pRating = ratings[#ratings].v
                end
                if #deltas > 0 then
                    -- The rating change is the small signed number nearest the rating
                    pRatingChange = deltas[#deltas].v
                end
            end

            scores[#scores + 1] = {
                name         = shortName,
                fullName     = name,
                class        = classToken,
                kills        = killingBlows,
                deaths       = deaths,
                damage       = damageDone,
                healing      = healingDone,
                faction      = faction,
                rating       = pRating,
                ratingChange = pRatingChange,
            }
            if shortName == myName or name == myName then
                myTeam = faction
                playerRowFields = fields
            end
        end
    end

    if myTeam == nil then
        Deadpool:Debug("Arena: couldn't determine team")
        return
    end

    -- Split into team + opponents
    local team, opponents = {}, {}
    local myKills, myDeaths, myDamage, myHealing = 0, 0, 0, 0
    for _, s in ipairs(scores) do
        s.isEnemy = (s.faction ~= myTeam)
        if s.isEnemy then
            opponents[#opponents + 1] = s.name
        else
            if s.name ~= myName then
                team[#team + 1] = s.name
            else
                myKills = s.kills
                myDeaths = s.deaths
                myDamage = s.damage
                myHealing = s.healing
            end
        end
    end

    local won = (winner == myTeam)
    local teamSize = #team + 1  -- us + teammates
    local bracket = teamSize .. "v" .. teamSize

    -- Rating: try multiple APIs (TBC Anniversary varies)
    local oldRating, newRating = 0, 0

    -- Method 0: pull rating off the player's row trailing fields.
    -- After classToken, dmg, heal come the rating fields. Pick the two
    -- numbers in the 1000-3500 range — those are the personal/team rating
    -- and pre-match rating. Ratings change (-50..+50) lives between them.
    if playerRowFields then
        local ratings = {}
        for fi = 11, #playerRowFields do
            local n = tonumber(playerRowFields[fi])
            -- Plausible rating window
            if n and n >= 1000 and n <= 3500 then
                ratings[#ratings + 1] = { idx = fi, v = n }
            end
        end
        -- Heuristic: if we got at least two rating-shaped numbers, the
        -- later one in the row is the post-match rating.
        if #ratings >= 2 then
            -- Sort by row position to identify "before" vs "after"
            table.sort(ratings, function(a, b) return a.idx < b.idx end)
            -- Look for an adjacent small signed delta between them
            oldRating = ratings[1].v
            newRating = ratings[#ratings].v
            -- Sanity: prefer pairs that are within +/- 80 of each other
            for i = 1, #ratings - 1 do
                local diff = math.abs(ratings[i].v - ratings[i + 1].v)
                if diff <= 80 then
                    oldRating = ratings[i].v
                    newRating = ratings[i + 1].v
                end
            end
        elseif #ratings == 1 then
            newRating = ratings[1].v
        end
    end

    -- Method 1: GetBattlefieldTeamInfo (0-indexed and 1-indexed)
    if (oldRating == 0 or newRating == 0) and GetBattlefieldTeamInfo then
        for teamIdx = 0, 2 do
            local ok, r1, r2, r3, r4 = pcall(GetBattlefieldTeamInfo, teamIdx)
            if ok then
                Deadpool:Debug("TeamInfo[" .. teamIdx .. "]: " .. tostring(r1) .. ", " .. tostring(r2) .. ", " .. tostring(r3) .. ", " .. tostring(r4))
                if type(r1) == "number" and type(r2) == "number" then
                    if teamIdx == myTeam or teamIdx == myTeam + 1 then
                        if oldRating == 0 then oldRating = r1 end
                        if newRating == 0 then newRating = r2 end
                    end
                elseif type(r2) == "number" and type(r3) == "number" then
                    if teamIdx == myTeam or teamIdx == myTeam + 1 then
                        if oldRating == 0 then oldRating = r2 end
                        if newRating == 0 then newRating = r3 end
                    end
                end
            end
        end
    end

    -- Method 4: GetPersonalRatedInfo (modern API)
    if newRating == 0 then
        if C_PvP and C_PvP.GetPersonalRatedInfo then
            local bracketIdx = (teamSize == 2) and 1 or (teamSize == 3) and 2 or 3
            local ok, info = pcall(C_PvP.GetPersonalRatedInfo, bracketIdx)
            if ok and info then
                newRating = info.personalRating or 0
            end
        elseif GetPersonalRatedInfo then
            local bracketIdx = (teamSize == 2) and 1 or (teamSize == 3) and 2 or 3
            local ok, rating = pcall(GetPersonalRatedInfo, bracketIdx)
            if ok and rating then newRating = rating or 0 end
        end
    end

    -- Get map name
    -- IMPORTANT: GetBattlefieldStatus(i) returns info for every queued
    -- battlefield slot, including BG queues like AV. If a BG was queued
    -- while playing arena, we'd grab the wrong map. Filter for active
    -- arena slots (teamSize > 0). Fall back to the current zone — we
    -- only call this from inside an arena instance anyway.
    local mapName = ""
    for i = 1, GetMaxBattlefieldID and GetMaxBattlefieldID() or 3 do
        local status, mName, _, _, _, slotTeamSize = GetBattlefieldStatus(i)
        if status == "active" and (slotTeamSize or 0) > 0 and mName and mName ~= "" then
            mapName = mName
            break
        end
    end
    if mapName == "" then
        -- Fallback: current zone text (we're inside the arena instance)
        local zone = GetRealZoneText() or GetZoneText()
        if zone and zone ~= "" then mapName = zone end
    end

    -- Duration
    local duration = time() - (arenaState.enterTime or time())

    -- Build entry
    -- Re-check rated state in case we missed it on entry
    if not arenaState.isRated and IsActiveBattlefieldArena then
        local ok, _, rated = pcall(IsActiveBattlefieldArena)
        if ok and rated then arenaState.isRated = true end
    end

    local entry = {
        time = time(),
        bracket = bracket,
        won = won,
        isRated = arenaState.isRated and true or false,
        oldRating = oldRating,
        newRating = newRating,
        team = team,
        opponents = opponents,
        map = mapName,
        duration = duration,
        myKills = myKills,
        myDeaths = myDeaths,
        myDamage = myDamage,
        myHealing = myHealing,
        scores = scores,
    }

    if not Deadpool.db.arenaLog then Deadpool.db.arenaLog = {} end
    table.insert(Deadpool.db.arenaLog, 1, entry)
    while #Deadpool.db.arenaLog > 500 do
        table.remove(Deadpool.db.arenaLog)
    end

    -- Stash the raw fields for /dp arenadebug to inspect post-match
    Deadpool._lastArenaRawFields = playerRowFields

    -- Announce
    local result = won and (Deadpool.colors.green .. "WIN") or (Deadpool.colors.red .. "LOSS")
    local ratingStr = ""
    if newRating > 0 then
        local change = newRating - oldRating
        local changeColor = change >= 0 and Deadpool.colors.green or Deadpool.colors.red
        local changeStr = change >= 0 and ("+" .. change) or tostring(change)
        ratingStr = " " .. newRating .. " (" .. changeColor .. changeStr .. "|r)"
    end
    Deadpool:Print(result .. "|r " .. bracket .. ratingStr ..
        "  " .. Deadpool.colors.grey .. myKills .. "/" .. myDeaths .. " K/D  " ..
        Deadpool.colors.orange .. (myDamage >= 1000 and string.format("%.1fk", myDamage/1000) or tostring(myDamage)) .. " dmg|r  " ..
        Deadpool.colors.green .. (myHealing >= 1000 and string.format("%.1fk", myHealing/1000) or tostring(myHealing)) .. " heal|r")

    if Deadpool.RefreshUI then Deadpool:RefreshUI() end
end

-- Track who last attacked us for auto-KOS
local lastAttackers = {}  -- [attackerName] = timestamp

-- Track recent damage to hostile players for assist credit
-- [victimGUID] = { [friendlyPlayerName] = timestamp }
local recentDamageToHostile = {}

-- Track the last hostile player who damaged us (for death attribution)
local lastHostileAttacker = {
    name = nil,
    guid = nil,
    class = nil,
    race = nil,
    flags = nil,
    time = 0,
}

----------------------------------------------------------------------
-- Check if we're in a BG or Arena (skip tracking in instances)
----------------------------------------------------------------------
function KillTracker:IsInBGOrArena()
    local inInstance, instanceType = IsInInstance()
    if inInstance and (instanceType == "pvp" or instanceType == "arena") then
        return true
    end
    return false
end

----------------------------------------------------------------------
-- Combat Log: Killing Blow Detection
----------------------------------------------------------------------
function KillTracker:OnCombatLogEvent()
    local timestamp, subevent, hideCaster,
          sourceGUID, sourceName, sourceFlags, sourceRaidFlags,
          destGUID, destName, destFlags, destRaidFlags = CombatLogGetCurrentEventInfo()

    -- Kill sound: play EVERYWHERE (including BGs/arenas) on YOUR killing blow only
    -- PARTY_KILL: fires when YOU get the killing blow in a group — always reliable
    if subevent == "PARTY_KILL" and sourceName == UnitName("player")
        and destGUID and destGUID:sub(1, 6) == "Player" then
        Deadpool:PlayKillSound("kos", nil)
    end

    -- Skip detailed tracking in battlegrounds, arenas, and sanctuary zones
    if self:IsInBGOrArena() then return end
    if Deadpool:IsInSanctuary() then return end

    -- Scan EVERY combat log event for KOS targets in range
    -- If a hostile player appears as source or dest and they're on our list, alert
    self:ScanCombatLogForKOS(sourceGUID, sourceName, sourceFlags, destGUID, destName, destFlags)

    -- Track enemy players attacking us (for auto-KOS)
    if Deadpool.db.settings.autoKOSOnAttack then
        self:CheckAutoKOS(subevent, sourceGUID, sourceName, sourceFlags, destGUID, destName, destFlags)
    end

    -- Track last hostile player who damaged us (for death attribution)
    -- Also track highest crit on enemy players and assist damage
    if subevent and (subevent:find("_DAMAGE") or subevent == "SWING_DAMAGE") then
        -- Get damage amount (position varies by subevent)
        local amount, overkill, school, resisted, blocked, absorbed, critical
        if subevent == "SWING_DAMAGE" then
            amount, overkill, school, resisted, blocked, absorbed, critical = select(12, CombatLogGetCurrentEventInfo())
        elseif subevent:find("_DAMAGE") then
            amount, overkill, school, resisted, blocked, absorbed, critical = select(15, CombatLogGetCurrentEventInfo())
        end

        -- Track OUR highest crit on enemy players
        if critical and amount and sourceName == UnitName("player") and destGUID and destGUID:sub(1, 6) == "Player" then
            if destFlags and bit.band(destFlags, COMBATLOG_OBJECT_REACTION_HOSTILE) > 0 then
                if not Deadpool.db.highestCrit then Deadpool.db.highestCrit = {} end
                if amount > (Deadpool.db.highestCrit.amount or 0) then
                    Deadpool.db.highestCrit = {
                        amount = amount,
                        victim = Deadpool:NormalizeName(destName) or destName,
                        time = time(),
                    }
                end
            end
        end

        -- Track friendly damage to hostile players for assist credit
        if sourceGUID and sourceGUID:sub(1, 6) == "Player" and sourceFlags then
            local isFriendly = bit.band(sourceFlags, COMBATLOG_OBJECT_AFFILIATION_MINE) > 0
                or bit.band(sourceFlags, COMBATLOG_OBJECT_AFFILIATION_PARTY) > 0
                or bit.band(sourceFlags, COMBATLOG_OBJECT_AFFILIATION_RAID) > 0
            if isFriendly and destGUID and destGUID:sub(1, 6) == "Player" and destFlags then
                if bit.band(destFlags, COMBATLOG_OBJECT_REACTION_HOSTILE) > 0 then
                    if not recentDamageToHostile[destGUID] then recentDamageToHostile[destGUID] = {} end
                    recentDamageToHostile[destGUID][sourceName] = time()
                end
            end
        end

        -- Track enemy damage to us (existing)
        if destName == UnitName("player") and sourceGUID and sourceGUID:sub(1, 6) == "Player" then
            if sourceFlags and bit.band(sourceFlags, COMBATLOG_OBJECT_REACTION_HOSTILE) > 0 then
                local aClass, aRace = self:GetInfoFromGUID(sourceGUID)
                lastHostileAttacker.name = sourceName
                lastHostileAttacker.guid = sourceGUID
                lastHostileAttacker.class = aClass
                lastHostileAttacker.race = aRace
                lastHostileAttacker.flags = sourceFlags
                lastHostileAttacker.time = time()
                -- Try to get level from target or nameplates
                lastHostileAttacker.level = nil
                if UnitExists("target") and UnitName("target") == sourceName then
                    lastHostileAttacker.level = UnitLevel("target")
                else
                    for i = 1, 40 do
                        local unit = "nameplate" .. i
                        if UnitExists(unit) and UnitName(unit) == sourceName then
                            lastHostileAttacker.level = UnitLevel(unit)
                            break
                        end
                    end
                end
            end
        end
    end

    -- Detect OUR death via UNIT_DIED — attribute to last hostile attacker
    if subevent == "UNIT_DIED" then
        if destGUID == UnitGUID("player") then
            -- We died. If a hostile player hit us in the last 15 seconds, they killed us.
            if lastHostileAttacker.name and (time() - lastHostileAttacker.time) < 15 then
                local killerFullName = Deadpool:NormalizeName(lastHostileAttacker.name)
                local victimFullName = Deadpool:GetPlayerFullName()
                if killerFullName and victimFullName then
                    self:RecordDeath(killerFullName, victimFullName,
                        lastHostileAttacker.class, lastHostileAttacker.race,
                        lastHostileAttacker.level)
                end
            end
            -- Reset attacker
            lastHostileAttacker.name = nil
            lastHostileAttacker.time = 0
        end
    end

    -- Track deaths of party/raid members via UNIT_DIED
    if subevent == "UNIT_DIED" then
        if destGUID and destGUID:sub(1, 6) == "Player" and destGUID ~= UnitGUID("player") then
            if destFlags then
                local isOurs = bit.band(destFlags, COMBATLOG_OBJECT_AFFILIATION_PARTY) > 0
                    or bit.band(destFlags, COMBATLOG_OBJECT_AFFILIATION_RAID) > 0
                if isOurs then
                    -- Check if last hostile attacker was targeting them too
                    -- (limited accuracy — best effort for group members)
                end
            end
        end
    end

    -- Track kills: PARTY_KILL for when we/guild get killing blows
    if subevent == "PARTY_KILL" then
        if destGUID and destGUID:sub(1, 6) == "Player" and sourceGUID and sourceGUID:sub(1, 6) == "Player" then
            -- Original kill tracking: check if source is us/guild
            self:ProcessKillingBlow(sourceGUID, sourceName, sourceFlags, destGUID, destName, destFlags)
        end
        return
    end
end

----------------------------------------------------------------------
-- Killing blow processing (extracted from old OnCombatLogEvent)
----------------------------------------------------------------------
function KillTracker:ProcessKillingBlow(sourceGUID, sourceName, sourceFlags, destGUID, destName, destFlags)
    -- Verify the victim is a player
    if not destGUID or destGUID:sub(1, 6) ~= "Player" then return end

    -- Verify the victim is hostile (enemy faction)
    if not destFlags or bit.band(destFlags, COMBATLOG_OBJECT_REACTION_HOSTILE) == 0 then return end

    -- Verify the source is a player (the killer)
    if not sourceGUID or sourceGUID:sub(1, 6) ~= "Player" then return end

    -- Get victim info from GUID
    local victimClass, victimRace, victimLevel = self:GetInfoFromGUID(destGUID)
    local victimFullName = Deadpool:NormalizeName(destName)
    local killerFullName = Deadpool:NormalizeName(sourceName)

    if not victimFullName or not killerFullName then return end

    -- Try to get victim level from target/nameplate if available
    -- GetPlayerInfoByGUID doesn't return level in TBC Classic
    if not victimLevel or victimLevel == 0 then
        -- Check if victim is our current target
        if UnitExists("target") and UnitName("target") == destName then
            victimLevel = UnitLevel("target")
        else
            -- Check nameplates
            for i = 1, 40 do
                local unit = "nameplate" .. i
                if UnitExists(unit) and UnitName(unit) == destName then
                    victimLevel = UnitLevel(unit)
                    break
                end
            end
        end
    end

    -- Check if the killer is us, in our party/raid, or in our guild
    local isOurKill = false

    -- Check if it's us
    if sourceName == UnitName("player") then
        isOurKill = true
    else
        -- Check party/raid affiliation flags AND verify guild membership
        -- Combat log flags alone are unreliable in TBC Anniversary
        if bit.band(sourceFlags, COMBATLOG_OBJECT_AFFILIATION_PARTY) > 0
            or bit.band(sourceFlags, COMBATLOG_OBJECT_AFFILIATION_RAID) > 0 then
            isOurKill = true
        else
            -- Not in our group — check if they're a guild member
            local killerFull = Deadpool:NormalizeName(sourceName)
            if killerFull and Deadpool:IsGuildMember(killerFull) then
                isOurKill = true
            end
        end
    end

    if not isOurKill then return end

    local zone = Deadpool:GetZone()

    Deadpool:Debug("Killing blow detected: " .. sourceName .. " killed " .. destName .. " in " .. zone)

    -- Record the kill for the killer
    Deadpool:RecordKill(killerFullName, victimFullName, victimClass, victimRace, victimLevel, zone)

    -- Award assist points (75%) to party/raid members who damaged the victim
    -- but didn't get the killing blow
    if destGUID and recentDamageToHostile[destGUID] then
        local isKOS = Deadpool:IsKOS(victimFullName)
        local basePoints = isKOS and 25 or 10
        local assistPoints = math.floor(basePoints * 0.75)
        if assistPoints > 0 then
            for playerName, timestamp in pairs(recentDamageToHostile[destGUID]) do
                if playerName ~= sourceName and (time() - timestamp) < 30 then
                    local assistFullName = Deadpool:NormalizeName(playerName)
                    if assistFullName and Deadpool:IsGuildMember(assistFullName) then
                        local assistScore = Deadpool:GetOrCreateScore(assistFullName)
                        assistScore.totalPoints = (assistScore.totalPoints or 0) + assistPoints
                        assistScore.assists = (assistScore.assists or 0) + 1
                        if assistFullName == Deadpool:GetPlayerFullName() then
                            Deadpool:Print(Deadpool.colors.cyan .. "ASSIST|r " ..
                                Deadpool:ShortName(victimFullName) .. " — " ..
                                Deadpool.colors.yellow .. "+" .. assistPoints .. " pts|r")
                        end
                    end
                end
            end
        end
        recentDamageToHostile[destGUID] = nil
    end
end

----------------------------------------------------------------------
-- Death recording: enemy players killing us/guildmates
----------------------------------------------------------------------
function KillTracker:RecordDeath(killerFullName, victimFullName, killerClass, killerRace, killerLevel)
    local zone = Deadpool:GetZone()

    -- Log the death
    Deadpool:AddDeathLogEntry({
        killer = killerFullName,
        victim = victimFullName,
        killerClass = killerClass,
        killerRace = killerRace,
        killerLevel = killerLevel,
        zone = zone,
        time = time(),
    })

    -- Update enemy sheet
    local enemy = Deadpool:GetOrCreateEnemy(killerFullName)
    enemy.timesKilledUs = (enemy.timesKilledUs or 0) + 1
    enemy.lastKilledUsTime = time()
    enemy.lastKilledUsBy = victimFullName
    if killerClass then enemy.class = killerClass end
    if killerRace then enemy.race = killerRace end
    if killerLevel and killerLevel > 0 then enemy.level = killerLevel end

    -- Announce
    local display = killerClass and Deadpool:ClassColor(killerClass, Deadpool:ShortName(killerFullName)) or Deadpool:ShortName(killerFullName)
    local lvlStr = (killerLevel and killerLevel > 0) and (Deadpool.colors.grey .. " [" .. killerLevel .. "]|r") or ((enemy.level and enemy.level > 0) and (Deadpool.colors.grey .. " [" .. enemy.level .. "]|r") or "")
    local wasMe = (victimFullName == Deadpool:GetPlayerFullName())
    if wasMe then
        Deadpool:Print(Deadpool.colors.red .. "KILLED BY|r " .. display .. lvlStr ..
            " in " .. Deadpool.colors.yellow .. zone .. "|r" ..
            " (" .. enemy.timesKilledUs .. "x total)")
        Deadpool:PlayDeathSound()

        -- Auto-KOS: they KILLED YOU — that's KOS-worthy (only for your own deaths)
        if Deadpool.db.settings.autoKOSOnAttack then
            if not Deadpool:IsKOS(killerFullName) then
                Deadpool:AddToKOS(killerFullName, "Auto-KOS: killed you")
            end
        end
    else
        -- Party/raid member died
        Deadpool:PlayPartyDeathSound()
    end

    if Deadpool.RefreshUI then Deadpool:RefreshUI() end
end

----------------------------------------------------------------------
-- Combat log KOS scanner: detect KOS targets from ANY combat event
-- No mouseover or targeting needed — if they cast, hit, heal, or
-- do anything within combat log range (~50yd), we catch them
----------------------------------------------------------------------
function KillTracker:ScanCombatLogForKOS(sourceGUID, sourceName, sourceFlags, destGUID, destName, destFlags)
    -- Check source: hostile player on our KOS?
    if sourceGUID and sourceName and sourceFlags then
        if sourceGUID:sub(1, 6) == "Player" and bit.band(sourceFlags, COMBATLOG_OBJECT_REACTION_HOSTILE) > 0 then
            local fullName = Deadpool:NormalizeName(sourceName)
            if fullName and Deadpool:IsKOS(fullName) then
                self:AlertKOS(fullName, sourceGUID)
            end
        end
    end

    -- Check dest: hostile player on our KOS?
    if destGUID and destName and destFlags then
        if destGUID:sub(1, 6) == "Player" and bit.band(destFlags, COMBATLOG_OBJECT_REACTION_HOSTILE) > 0 then
            local fullName = Deadpool:NormalizeName(destName)
            if fullName and Deadpool:IsKOS(fullName) then
                self:AlertKOS(fullName, destGUID)
            end
        end
    end
end

----------------------------------------------------------------------
-- Unified KOS alert: single function for all detection paths
-- (nameplate, target, mouseover, combat log). Deduplicates, alerts
-- locally, and broadcasts ONE sighting per cooldown window.
----------------------------------------------------------------------
function KillTracker:AlertKOS(fullName, guid)
    local now = time()
    local cooldowns = Deadpool._sightingCooldowns
    if cooldowns[fullName] and (now - cooldowns[fullName]) < SIGHTING_COOLDOWN then
        return
    end
    cooldowns[fullName] = now

    local entry = Deadpool:GetKOSEntry(fullName)
    if not entry then return end

    -- Enrich entry from GUID if available
    if guid then
        local class, race = self:GetInfoFromGUID(guid)
        if class then entry.class = class end
        if race then entry.race = race end
    end

    local zone = Deadpool:GetZone()
    Deadpool:UpdateKOSSighting(fullName, zone)

    -- Suppress local alerts in sanctuary zones (can't attack anyway)
    -- Guild sighting broadcasts from OTHER players are NOT affected by this.
    if Deadpool.db.settings.suppressInSanctuary and Deadpool:IsInSanctuary() then
        Deadpool:Debug("KOS alert suppressed in sanctuary: " .. fullName)
        return
    end

    -- Play alert sound
    if Deadpool.db.settings.alertSound then
        PlaySound(8959)
    end

    -- Visual alert
    if Deadpool.ShowKOSAlert then
        Deadpool:ShowKOSAlert(fullName, entry)
    end

    -- Chat notification
    if Deadpool.db.settings.announceKOSSighted then
        local display = entry.class and Deadpool:ClassColor(entry.class, entry.name) or entry.name
        local subZone = Deadpool:GetSubZone()
        local location = zone
        if subZone and subZone ~= "" then location = location .. " - " .. subZone end

        Deadpool:Print(Deadpool.colors.red .. "TARGET ACQUIRED|r — " ..
            display .. " spotted in " ..
            Deadpool.colors.yellow .. location .. "|r")
    end

    -- Broadcast sighting to guild so everyone knows
    if Deadpool.db.settings.broadcastSightings then
        Deadpool:BroadcastSighting(fullName, zone)
    end
end

----------------------------------------------------------------------
-- Auto-KOS: only if THEY attack YOU first (not if you ganked them)
-- Tracks who we attacked so we don't KOS people defending themselves
----------------------------------------------------------------------
local playersWeAttacked = {}  -- [name] = timestamp of when WE hit them first

function KillTracker:TrackOurAggression(subevent, sourceGUID, sourceName, destGUID, destName, destFlags)
    -- Track when WE damage a hostile player (we initiated)
    if not subevent then return end
    local isDamage = subevent:find("_DAMAGE") or subevent == "SWING_DAMAGE"
    if not isDamage then return end

    -- Source must be us
    if sourceName ~= UnitName("player") then return end

    -- Dest must be a hostile player
    if not destGUID or destGUID:sub(1, 6) ~= "Player" then return end
    if not destFlags or bit.band(destFlags, COMBATLOG_OBJECT_REACTION_HOSTILE) == 0 then return end

    -- Record that WE attacked this player (they're defending, not initiating)
    if not playersWeAttacked[destName] then
        playersWeAttacked[destName] = time()
    end
end

function KillTracker:CheckAutoKOS(subevent, sourceGUID, sourceName, sourceFlags, destGUID, destName, destFlags)
    -- Also track our own aggression
    self:TrackOurAggression(subevent, sourceGUID, sourceName, destGUID, destName, destFlags)

    -- Only care about damage events hitting us
    if not subevent then return end
    local isDamage = subevent:find("_DAMAGE") or subevent == "SWING_DAMAGE"
    if not isDamage then return end

    -- Dest must be us
    if destName ~= UnitName("player") then return end

    -- Source must be a hostile player
    if not sourceGUID or sourceGUID:sub(1, 6) ~= "Player" then return end
    if not sourceFlags or bit.band(sourceFlags, COMBATLOG_OBJECT_REACTION_HOSTILE) == 0 then return end

    -- Throttle: only process once per attacker per 60 seconds
    local now = time()
    if lastAttackers[sourceName] and (now - lastAttackers[sourceName]) < 60 then return end
    lastAttackers[sourceName] = now

    -- KEY CHECK: did WE attack them first? If so, they're defending — don't KOS
    if playersWeAttacked[sourceName] and (now - playersWeAttacked[sourceName]) < 120 then
        -- We hit them within the last 2 minutes — they're fighting back, not initiating
        return
    end

    -- They attacked us unprovoked — mark as aggressive (not KOS)
    local attackerFullName = Deadpool:NormalizeName(sourceName)
    if not attackerFullName then return end

    -- Mark in enemy sheet as aggressive with 24hr timer
    local enemy = Deadpool:GetOrCreateEnemy(attackerFullName)
    enemy.isAggressive = true
    enemy.aggressiveUntil = time() + 86400  -- 24 hours
    local class, race = Deadpool.modules.KillTracker:GetInfoFromGUID(sourceGUID)
    if class then enemy.class = class end
    if race then enemy.race = race end

    local display = class and Deadpool:ClassColor(class, Deadpool:ShortName(attackerFullName)) or Deadpool:ShortName(attackerFullName)
    Deadpool:Print(Deadpool.colors.orange .. "HOSTILE|r " .. display .. " attacked you!")
end

-- Clean up old aggression tracking and assist tracking every 5 minutes
if C_Timer and C_Timer.NewTicker then
    C_Timer.NewTicker(300, function()
        local now = time()
        for name, t in pairs(playersWeAttacked) do
            if (now - t) > 300 then playersWeAttacked[name] = nil end
        end
        -- Clean stale assist tracking entries (older than 60 seconds)
        for guid, players in pairs(recentDamageToHostile) do
            local hasActive = false
            for pname, t in pairs(players) do
                if (now - t) > 60 then players[pname] = nil
                else hasActive = true end
            end
            if not hasActive then recentDamageToHostile[guid] = nil end
        end
    end)
end

----------------------------------------------------------------------
-- Get player info from GUID
----------------------------------------------------------------------
local guidInfoCache = {}  -- [guid] = { class, race, time }
local GUID_CACHE_TTL = 300  -- cache GUID lookups for 5 minutes

function KillTracker:GetInfoFromGUID(guid)
    if not guid then return nil, nil, nil end
    -- Check cache first to avoid hammering GetPlayerInfoByGUID
    local cached = guidInfoCache[guid]
    if cached and (time() - cached.time) < GUID_CACHE_TTL then
        return cached.class, cached.race, nil
    end
    -- GetPlayerInfoByGUID returns: localizedClass, englishClass, localizedRace, englishRace, sex, name, realm
    local ok, localClass, engClass, localRace, engRace, sex, name, realm = pcall(GetPlayerInfoByGUID, guid)
    if ok and engClass then
        guidInfoCache[guid] = { class = engClass, race = localRace, time = time() }
        return engClass, localRace, nil  -- level not available from GUID
    end
    return nil, nil, nil
end

----------------------------------------------------------------------
-- KOS Detection: Scan visible units
----------------------------------------------------------------------
function KillTracker:ScanUnit(unitId)
    if not unitId then return end
    if Deadpool:IsInSanctuary() then return end
    if not UnitExists(unitId) then return end
    if not UnitIsPlayer(unitId) then return end
    if not UnitIsEnemy("player", unitId) then return end

    local fullName = Deadpool:GetUnitFullName(unitId)
    if not fullName then return end

    -- Update info on KOS targets whenever we see them
    if Deadpool:IsKOS(fullName) then
        -- Get fresh info
        local _, classFile = UnitClass(unitId)
        local race = UnitRace(unitId)
        local level = UnitLevel(unitId)
        local guild = GetGuildInfo(unitId)
        local zone = Deadpool:GetZone()

        -- Update the KOS entry with latest sighting info
        local entry = Deadpool:GetKOSEntry(fullName)
        if entry then
            if classFile then entry.class = classFile end
            if race then entry.race = race end
            if level and level > 0 then entry.level = level end
            if guild then entry.guild = guild end
        end
        Deadpool:UpdateKOSSighting(fullName, zone)

        -- Alert if not recently alerted (uses unified AlertKOS)
        self:AlertKOS(fullName, UnitGUID(unitId))
    end
end

----------------------------------------------------------------------
-- Periodic cleanup of the sighting cooldown table
----------------------------------------------------------------------
if C_Timer and C_Timer.NewTicker then
    C_Timer.NewTicker(120, function()
        if not Deadpool._sightingCooldowns then return end
        local now = time()
        for name, t in pairs(Deadpool._sightingCooldowns) do
            if (now - t) > SIGHTING_COOLDOWN * 2 then
                Deadpool._sightingCooldowns[name] = nil
            end
        end
    end)
end
