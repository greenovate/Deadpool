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

-- Track recently scanned units to avoid spamming alerts
local recentKOSAlerts = {}
local ALERT_COOLDOWN = 30  -- seconds between re-alerting for same target

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
end

-- Track who last attacked us for auto-KOS
local lastAttackers = {}  -- [attackerName] = timestamp

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
    -- Skip ALL tracking in battlegrounds and arenas
    if self:IsInBGOrArena() then return end

    local timestamp, subevent, hideCaster,
          sourceGUID, sourceName, sourceFlags, sourceRaidFlags,
          destGUID, destName, destFlags, destRaidFlags = CombatLogGetCurrentEventInfo()

    -- Scan EVERY combat log event for KOS targets in range
    -- If a hostile player appears as source or dest and they're on our list, alert
    self:ScanCombatLogForKOS(sourceGUID, sourceName, sourceFlags, destGUID, destName, destFlags)

    -- Track enemy players attacking us (for auto-KOS)
    if Deadpool.db.settings.autoKOSOnAttack then
        self:CheckAutoKOS(subevent, sourceGUID, sourceName, sourceFlags, destGUID, destName, destFlags)
    end

    -- Track last hostile player who damaged us (for death attribution)
    if subevent and (subevent:find("_DAMAGE") or subevent == "SWING_DAMAGE") then
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

    -- Check if the killer is us or a guild member
    local isOurKill = false

    -- Check if it's us
    if sourceName == UnitName("player") then
        isOurKill = true
    else
        -- Check if source is in our guild by checking flags
        -- In groups: source should be affiliated with us
        -- For guild tracking outside groups, we rely on addon sync
        if bit.band(sourceFlags, COMBATLOG_OBJECT_AFFILIATION_MINE) > 0 then
            isOurKill = true
        elseif bit.band(sourceFlags, COMBATLOG_OBJECT_AFFILIATION_PARTY) > 0 then
            isOurKill = true
        elseif bit.band(sourceFlags, COMBATLOG_OBJECT_AFFILIATION_RAID) > 0 then
            isOurKill = true
        end
    end

    if not isOurKill then return end

    local zone = Deadpool:GetZone()

    Deadpool:Debug("Killing blow detected: " .. sourceName .. " killed " .. destName .. " in " .. zone)

    -- Record the kill
    Deadpool:RecordKill(killerFullName, victimFullName, victimClass, victimRace, victimLevel, zone)
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
    else
        -- Party/raid member died
        Deadpool:PlayPartyDeathSound()
    end

    -- Auto-KOS: they KILLED us — that's KOS-worthy
    if Deadpool.db.settings.autoKOSOnAttack then
        if not Deadpool:IsKOS(killerFullName) then
            Deadpool:AddToKOS(killerFullName, "Auto-KOS: killed " .. Deadpool:ShortName(victimFullName))
        end
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
                self:AlertKOSFromCombatLog(fullName, sourceGUID)
            end
        end
    end

    -- Check dest: hostile player on our KOS?
    if destGUID and destName and destFlags then
        if destGUID:sub(1, 6) == "Player" and bit.band(destFlags, COMBATLOG_OBJECT_REACTION_HOSTILE) > 0 then
            local fullName = Deadpool:NormalizeName(destName)
            if fullName and Deadpool:IsKOS(fullName) then
                self:AlertKOSFromCombatLog(fullName, destGUID)
            end
        end
    end
end

function KillTracker:AlertKOSFromCombatLog(fullName, guid)
    -- Reuse the same cooldown table so we don't spam
    local now = time()
    if recentKOSAlerts[fullName] and (now - recentKOSAlerts[fullName]) < ALERT_COOLDOWN then
        return
    end
    recentKOSAlerts[fullName] = now

    local entry = Deadpool:GetKOSEntry(fullName)
    if not entry then return end

    -- Try to get fresh info from GUID
    if guid then
        local class, race = self:GetInfoFromGUID(guid)
        if class then entry.class = class end
        if race then entry.race = race end
    end

    local zone = Deadpool:GetZone()
    Deadpool:UpdateKOSSighting(fullName, zone)

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

        local bountyTag = ""
        if Deadpool:HasActiveBounty(fullName) then
            local bounty = Deadpool:GetBounty(fullName)
            bountyTag = Deadpool.colors.gold .. " [BOUNTY: " .. bounty.bountyGold .. "g]|r"
        end

        Deadpool:Print(Deadpool.colors.red .. "TARGET ACQUIRED|r — " ..
            display .. bountyTag .. " spotted in " ..
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

-- Clean up old aggression tracking every 5 minutes
if C_Timer and C_Timer.NewTicker then
    C_Timer.NewTicker(300, function()
        local now = time()
        for name, t in pairs(playersWeAttacked) do
            if (now - t) > 300 then playersWeAttacked[name] = nil end
        end
    end)
end

----------------------------------------------------------------------
-- Get player info from GUID
----------------------------------------------------------------------
function KillTracker:GetInfoFromGUID(guid)
    if not guid then return nil, nil, nil end
    -- GetPlayerInfoByGUID returns: localizedClass, englishClass, localizedRace, englishRace, sex, name, realm
    local ok, localClass, engClass, localRace, engRace, sex, name, realm = pcall(GetPlayerInfoByGUID, guid)
    if ok and engClass then
        return engClass, localRace, nil  -- level not available from GUID
    end
    return nil, nil, nil
end

----------------------------------------------------------------------
-- KOS Detection: Scan visible units
----------------------------------------------------------------------
function KillTracker:ScanUnit(unitId)
    if not unitId then return end
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
        if classFile then entry.class = classFile end
        if race then entry.race = race end
        if level and level > 0 then entry.level = level end
        if guild then entry.guild = guild end
        Deadpool:UpdateKOSSighting(fullName, zone)

        -- Alert if not recently alerted
        self:AlertKOSSighted(fullName, unitId)
    end
end

----------------------------------------------------------------------
-- KOS Alert (delegates to Alerts.lua for visual)
----------------------------------------------------------------------
function KillTracker:AlertKOSSighted(fullName, unitId)
    -- Cooldown check
    local now = time()
    if recentKOSAlerts[fullName] and (now - recentKOSAlerts[fullName]) < ALERT_COOLDOWN then
        return
    end
    recentKOSAlerts[fullName] = now

    local entry = Deadpool:GetKOSEntry(fullName)
    if not entry then return end

    -- Play alert sound
    if Deadpool.db.settings.alertSound then
        PlaySound(8959)  -- PVP flag taken sound - urgent and noticeable
    end

    -- Try to kick off the visual alert (Alerts.lua)
    if Deadpool.ShowKOSAlert then
        Deadpool:ShowKOSAlert(fullName, entry)
    end

    -- Chat notification
    if Deadpool.db.settings.announceKOSSighted then
        local display = entry.class and Deadpool:ClassColor(entry.class, entry.name) or entry.name
        local zone = Deadpool:GetZone()
        local subZone = Deadpool:GetSubZone()
        local location = zone
        if subZone and subZone ~= "" then
            location = location .. " - " .. subZone
        end

        local bountyTag = ""
        if Deadpool:HasActiveBounty(fullName) then
            local bounty = Deadpool:GetBounty(fullName)
            bountyTag = Deadpool.colors.gold .. " [BOUNTY: " ..
                Deadpool:FormatGold(bounty.bountyGold) .. "]|r"
        end

        Deadpool:Print(Deadpool.colors.red .. "TARGET ACQUIRED|r — " ..
            display .. bountyTag .. " spotted in " ..
            Deadpool.colors.yellow .. location .. "|r")
    end
end

----------------------------------------------------------------------
-- Periodic cleanup of the alert cooldown table
----------------------------------------------------------------------
if C_Timer and C_Timer.NewTicker then
    C_Timer.NewTicker(60, function()
        local now = time()
        for name, t in pairs(recentKOSAlerts) do
            if (now - t) > ALERT_COOLDOWN * 2 then
                recentKOSAlerts[name] = nil
            end
        end
    end)
end
