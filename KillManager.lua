----------------------------------------------------------------------
-- Deadpool - KillManager.lua
-- KOS list management, point calculations, kill recording
----------------------------------------------------------------------

local KillManager = {}
Deadpool:RegisterModule("KillManager", KillManager)

function KillManager:Init()
    -- No periodic tasks needed; KOS entries persist locally forever.
    -- Only recently-active entries are synced (filtered in Sync.lua).
end

----------------------------------------------------------------------
-- KOS Purge: GM/Officer can wipe the entire KOS list
----------------------------------------------------------------------
function Deadpool:PurgeKOSList()
    if not self:IsGM() and not self:IsOfficer() then
        self:Print(self.colors.red .. "Only GM or officers can purge the KOS list.|r")
        return false
    end

    local removed = 0
    for fullName in pairs(self.db.kosList) do
        self.db.kosList[fullName] = nil
        removed = removed + 1
    end

    self.db.guildConfig.kosResetAt = time()
    self:BumpSyncVersion()
    self:BroadcastGMConfig()

    self:Print(self.colors.red .. "KOS list purged:|r " .. removed .. " entries removed")
    if self.RefreshUI then self:RefreshUI() end
    return true
end

----------------------------------------------------------------------
-- User self-purge: remove only KOS entries YOU added
----------------------------------------------------------------------
function Deadpool:PurgeMyKOSEntries()
    local myName = self:GetPlayerFullName()
    local removed = 0
    for fullName, entry in pairs(self.db.kosList) do
        if entry.addedBy == myName then
            self.db.kosList[fullName] = nil
            self:BroadcastKOSRemove(fullName)
            removed = removed + 1
        end
    end

    if removed > 0 then
        self:BumpSyncVersion()
    end

    self:Print(self.colors.yellow .. "Removed " .. removed .. " KOS entries you added|r")
    if self.RefreshUI then self:RefreshUI() end
    return removed
end

----------------------------------------------------------------------
-- KOS List Management
----------------------------------------------------------------------
function Deadpool:AddToKOS(nameOrFullName, reason, silent)
    local fullName = self:NormalizeName(nameOrFullName)
    if not fullName then
        self:Print("Invalid player name.")
        return false
    end

    -- Check KOS list cap (skip if already on list — we're updating, not adding)
    if not self.db.kosList[fullName] then
        local maxKOS = self.db.guildConfig.maxKOSEntries or 100
        if self:TableCount(self.db.kosList) >= maxKOS then
            -- Auto-evict the oldest entry to make room
            local oldestName, oldestTime = nil, math.huge
            for fn, entry in pairs(self.db.kosList) do
                local t = entry.addedDate or 0
                if t < oldestTime then
                    oldestName = fn
                    oldestTime = t
                end
            end
            if oldestName then
                self.db.kosList[oldestName] = nil
                if not silent then
                    self:Print(self.colors.grey .. "Auto-removed oldest KOS entry: " .. self:ShortName(oldestName) .. "|r")
                end
            else
                if not silent then
                    self:Print(self.colors.red .. "KOS list is full (" .. maxKOS .. ").|r")
                end
                return false
            end
        end
    end

    -- Grab target info if we have the player targeted
    local class, race, level, guild
    if UnitExists("target") then
        local targetFull = self:GetUnitFullName("target")
        if targetFull and targetFull == fullName then
            local _, classFile = UnitClass("target")
            class = classFile
            race = UnitRace("target") -- returns localized but fine for display
            level = UnitLevel("target")
            guild = GetGuildInfo("target")
        end
    end

    if self.db.kosList[fullName] then
        -- Already on list — update info if we have better data
        local entry = self.db.kosList[fullName]
        if class then entry.class = class end
        if race then entry.race = race end
        if level and level > 0 then entry.level = level end
        if guild then entry.guild = guild end
        if reason and reason ~= "" then entry.reason = reason end
        if not silent then
            self:Print(self:ShortName(fullName) .. " is already on the list. Updated info.")
        end
        return false
    end

    self.db.kosList[fullName] = {
        name = self:ShortName(fullName),
        realm = fullName:match("%-(.+)$") or GetRealmName(),
        class = class,
        race = race,
        level = level,
        guild = guild,
        addedBy = self:GetPlayerFullName(),
        addedDate = time(),
        reason = (reason and reason ~= "") and reason or nil,
        totalKills = 0,
        lastKilledBy = nil,
        lastKilledTime = 0,
        lastSeenZone = nil,
        lastSeenTime = 0,
    }

    self:BumpSyncVersion()

    if not silent then
        local display = class and self:ClassColor(class, self:ShortName(fullName)) or self:ShortName(fullName)
        self:Print(display .. " added to the " .. self.colors.red .. "Kill on Sight|r list.")
        if reason and reason ~= "" then
            self:Print("  Reason: " .. self.colors.grey .. reason .. "|r")
        end
    end

    -- Broadcast to guild
    self:BroadcastKOSAdd(fullName)

    -- Notify achievements
    if self.modules.Achievements and self.modules.Achievements.OnKOSAdded then
        self.modules.Achievements:OnKOSAdded()
    end

    -- Refresh UI if visible
    if self.RefreshUI then self:RefreshUI() end

    return true
end

function Deadpool:RemoveFromKOS(nameOrFullName, silent)
    local fullName = self:NormalizeName(nameOrFullName)
    if not fullName then
        self:Print("Invalid player name.")
        return false
    end

    if not self.db.kosList[fullName] then
        if not silent then
            self:Print(self:ShortName(fullName) .. " is not on the list.")
        end
        return false
    end

    self.db.kosList[fullName] = nil

    self:BumpSyncVersion()

    if not silent then
        self:Print(self:ShortName(fullName) .. " removed from the list.")
    end

    -- Broadcast to guild
    self:BroadcastKOSRemove(fullName)

    if self.RefreshUI then self:RefreshUI() end
    return true
end

----------------------------------------------------------------------
-- Points System (fixed values — consistent across all guilds)
----------------------------------------------------------------------
local POINTS_PER_KILL = 10
local POINTS_PER_KOS_KILL = 25
local POINTS_UNDERDOG_MULT_3 = 2.0    -- 3-5 levels higher
local POINTS_UNDERDOG_MULT_6 = 3.0    -- 6+ levels higher
local POINTS_LOWBIE_RANGE = 5         -- within this many levels = full pts
local POINTS_LOWBIE_REDUCTION = 0.5   -- 50% for 1st tier below
local POINTS_LOWBIE_FLOOR = 1         -- minimum points per kill
local POINTS_LOWBIE_TIER2 = 10        -- below this = floor

function Deadpool:AwardKillPoints(killerFullName, victimFullName, killType, victimLevel)
    -- Only track scores for guild members
    if not self:IsGuildMember(killerFullName) then return 0 end

    local score = self:GetOrCreateScore(killerFullName)
    local points = 0

    if killType == "kos" then
        points = POINTS_PER_KOS_KILL
        score.kosKills = score.kosKills + 1
    else
        points = POINTS_PER_KILL
        score.randomKills = (score.randomKills or 0) + 1
    end

    -- Level-based modifier (local kills only — we know the killer's level)
    local isLocalKill = (killerFullName == self:GetPlayerFullName())
    local killerLevel = isLocalKill and (UnitLevel("player") or 0) or 0

    if victimLevel and victimLevel > 0 and killerLevel > 0 then
        local levelDiff = killerLevel - victimLevel  -- positive = victim is lower
        if levelDiff > POINTS_LOWBIE_TIER2 then
            points = POINTS_LOWBIE_FLOOR
        elseif levelDiff > POINTS_LOWBIE_RANGE then
            points = math.max(POINTS_LOWBIE_FLOOR, math.floor(points * POINTS_LOWBIE_REDUCTION))
        end
    end

    -- Underdog bonus (local kills only)
    if victimLevel and victimLevel > 0 and killerLevel > 0 and victimLevel > killerLevel then
        local levelDiff = victimLevel - killerLevel
        if levelDiff >= 6 then
            points = math.floor(points * POINTS_UNDERDOG_MULT_6)
        elseif levelDiff >= 3 then
            points = math.floor(points * POINTS_UNDERDOG_MULT_3)
        else
            points = math.floor(points * 1.5)
        end
    end

    score.totalKills = score.totalKills + 1
    score.totalPoints = score.totalPoints + points
    score.lastKill = time()

    -- Kill streak: resets if last kill was more than 5 minutes ago
    if score._lastKillTime and (time() - score._lastKillTime) < 300 then
        score.killStreak = (score.killStreak or 0) + 1
    else
        score.killStreak = 1
    end
    score._lastKillTime = time()
    if (score.killStreak or 0) > (score.bestStreak or 0) then
        score.bestStreak = score.killStreak
    end

    -- Streak bonus: +2 points per kill in streak beyond 3
    if score.killStreak >= 3 then
        local streakBonus = (score.killStreak - 2) * 2
        score.totalPoints = score.totalPoints + streakBonus
        points = points + streakBonus
    end

    return points
end

----------------------------------------------------------------------
-- Kill recording (called by KillTracker and Sync)
-- Deduplicates: same killer+victim within 10 seconds = skip
----------------------------------------------------------------------
local recentKills = {}  -- ["killer-victim"] = timestamp

function Deadpool:RecordKill(killerFullName, victimFullName, victimClass, victimRace, victimLevel, zone)
    -- Deduplicate: if we already recorded this exact kill in the last 10 seconds, skip
    local dedupKey = killerFullName .. ">" .. victimFullName
    local now = time()
    if recentKills[dedupKey] and (now - recentKills[dedupKey]) < 10 then
        return
    end
    recentKills[dedupKey] = now

    -- Clean old entries periodically
    if now % 30 == 0 then
        for k, t in pairs(recentKills) do
            if (now - t) > 30 then recentKills[k] = nil end
        end
    end

    local isKOS = self:IsKOS(victimFullName)

    -- Determine kill type for points
    local killType = isKOS and "kos" or "random"

    -- Award points (level-aware)
    local points = self:AwardKillPoints(killerFullName, victimFullName, killType, victimLevel)

    -- Update enemy sheet
    local enemy = self:GetOrCreateEnemy(victimFullName)
    enemy.timesWeKilledThem = (enemy.timesWeKilledThem or 0) + 1
    enemy.lastWeKilledTime = time()
    enemy.lastWeKilledBy = killerFullName
    if victimClass then enemy.class = victimClass end
    if victimRace then enemy.race = victimRace end
    if victimLevel and victimLevel > 0 then enemy.level = victimLevel end

    -- Update KOS entry if applicable
    if isKOS then
        local kosEntry = self.db.kosList[victimFullName]
        kosEntry.totalKills = (kosEntry.totalKills or 0) + 1
        kosEntry.lastKilledBy = killerFullName
        kosEntry.lastKilledTime = time()
    end

    -- Get killer's class if available
    local killerClass = nil
    if killerFullName == self:GetPlayerFullName() then
        local _, cf = UnitClass("player")
        killerClass = cf
    end

    -- Log the kill
    self:AddKillLogEntry({
        killer = killerFullName,
        victim = victimFullName,
        killerClass = killerClass,
        victimClass = victimClass,
        victimRace = victimRace,
        victimLevel = victimLevel,
        zone = zone,
        time = time(),
        isKOS = isKOS,
        points = points,
        killType = killType,
    })

    -- Announce
    if self.db.settings.announceKills then
        local display = victimClass and self:ClassColor(victimClass, self:ShortName(victimFullName)) or self:ShortName(victimFullName)
        local lvlStr = victimLevel and victimLevel > 0 and (self.colors.grey .. " [" .. victimLevel .. "]|r") or ""
        local typeTag = isKOS and (self.colors.red .. " [KOS]|r") or ""
        local killerName = self:ShortName(killerFullName)
        self:Print(self.colors.green .. killerName .. "|r killed " .. display .. lvlStr .. typeTag ..
            " in " .. self.colors.yellow .. zone .. "|r (+" .. points .. " pts)")
    end

    -- Kill streak + sound (only for YOUR kills)
    local score = self:GetOrCreateScore(killerFullName)
    if killerFullName == self:GetPlayerFullName() then
        Deadpool:PlayKillSound(killType, score.killStreak)
    end

    -- Broadcast to guild
    self:BroadcastKill(killerFullName, victimFullName, victimClass, victimRace, victimLevel, zone)

    -- Notify quest and achievement modules
    if self.modules.Quests and self.modules.Quests.OnKill then
        self.modules.Quests:OnKill(killerFullName, victimFullName, victimClass, victimRace, victimLevel, zone, killType)
    end
    if self.modules.Achievements and self.modules.Achievements.OnKill then
        self.modules.Achievements:OnKill(killerFullName, victimFullName, victimClass, victimRace, victimLevel, zone, killType)
    end

    -- Refresh UI
    if self.RefreshUI then self:RefreshUI() end
end

----------------------------------------------------------------------
-- KOS sighting tracking
----------------------------------------------------------------------
function Deadpool:UpdateKOSSighting(fullName, zone)
    local entry = self.db.kosList[fullName]
    if not entry then return end
    entry.lastSeenZone = zone
    entry.lastSeenTime = time()
end
