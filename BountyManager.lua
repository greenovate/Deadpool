----------------------------------------------------------------------
-- Deadpool - BountyManager.lua
-- KOS list management, bounty contracts, and point calculations
----------------------------------------------------------------------

local BountyManager = {}
Deadpool:RegisterModule("BountyManager", BountyManager)

function BountyManager:Init()
    -- Nothing special on init yet
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

    -- Also expire any bounty
    if self.db.bounties[fullName] and not self.db.bounties[fullName].expired then
        self.db.bounties[fullName].expired = true
        self.db.bounties[fullName].expiredReason = "KOS removed"
    end

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
-- Bounty Contracts
----------------------------------------------------------------------
function Deadpool:PlaceBounty(nameOrFullName, goldAmount, maxKills)
    local fullName = self:NormalizeName(nameOrFullName)
    if not fullName then
        self:Print("Invalid player name.")
        return false
    end

    if not goldAmount or goldAmount <= 0 then
        self:Print("Bounty amount must be greater than 0.")
        return false
    end

    maxKills = maxKills or 10
    if maxKills < 1 then maxKills = 1 end

    -- Auto-add to KOS if not already
    if not self:IsKOS(fullName) then
        self:AddToKOS(fullName, "Bounty target", true)
    end

    -- Check for existing active bounty
    if self:HasActiveBounty(fullName) then
        local existing = self.db.bounties[fullName]
        -- Stack bounties: add gold and extend kills
        existing.bountyGold = existing.bountyGold + goldAmount
        existing.maxKills = existing.maxKills + maxKills
        existing.lastUpdated = time()
        self:Print(self.colors.gold .. "Bounty STACKED|r on " .. self:ShortName(fullName) ..
            " — now " .. self:FormatGold(existing.bountyGold) .. " for " .. existing.maxKills .. " kills.")
    else
        self.db.bounties[fullName] = {
            target = fullName,
            bountyGold = goldAmount,
            placedBy = self:GetPlayerFullName(),
            placedDate = time(),
            maxKills = maxKills,
            currentKills = 0,
            expired = false,
            expiredReason = nil,
            claims = {},
        }
        self:Print(self.colors.gold .. "CONTRACT PLACED|r — " ..
            self.colors.red .. self:ShortName(fullName) .. "|r — " ..
            self:FormatGold(goldAmount) .. " for " .. maxKills .. " kills.")
    end

    self:BumpSyncVersion()

    -- Broadcast
    self:BroadcastBountyAdd(fullName)

    if self.RefreshUI then self:RefreshUI() end
    return true
end

function Deadpool:ClaimBountyKill(targetFullName, killerFullName, zone)
    local bounty = self.db.bounties[targetFullName]
    if not bounty or bounty.expired then return false end

    bounty.currentKills = bounty.currentKills + 1
    table.insert(bounty.claims, {
        killer = killerFullName,
        time = time(),
        zone = zone or "Unknown",
    })

    -- Check if bounty is now complete
    if bounty.currentKills >= bounty.maxKills then
        bounty.expired = true
        bounty.expiredReason = "Completed (" .. bounty.maxKills .. "/" .. bounty.maxKills .. " kills)"
        self:Print(self.colors.gold .. "CONTRACT COMPLETE|r — " ..
            self:ShortName(targetFullName) .. " bounty fulfilled!")
    else
        self:Print(self.colors.gold .. "BOUNTY KILL|r — " ..
            self:ShortName(targetFullName) .. " (" ..
            bounty.currentKills .. "/" .. bounty.maxKills .. ")")
    end

    self:BumpSyncVersion()
    return true
end

----------------------------------------------------------------------
-- Points System
----------------------------------------------------------------------
function Deadpool:AwardKillPoints(killerFullName, victimFullName, killType, victimLevel)
    local score = self:GetOrCreateScore(killerFullName)
    local points = 0

    if killType == "bounty" then
        points = self.db.settings.pointsPerBountyKill
        score.bountyKills = score.bountyKills + 1
    elseif killType == "kos" then
        points = self.db.settings.pointsPerKOSKill
        score.kosKills = score.kosKills + 1
    else
        points = self.db.settings.pointsPerKill
        score.randomKills = (score.randomKills or 0) + 1
    end

    -- Level-based modifier: killing lowbies is worth less
    if victimLevel and victimLevel > 0 and victimLevel < 60 then
        if victimLevel < 20 then
            points = 1  -- lowbie kill = 1 pt regardless
        elseif victimLevel < 40 then
            points = math.max(1, math.floor(points * 0.25))
        elseif victimLevel < 55 then
            points = math.max(1, math.floor(points * 0.5))
        end
    end

    -- Underdog bonus: killing someone higher level than you = bonus points
    local myLevel = UnitLevel("player") or 0
    if victimLevel and victimLevel > 0 and myLevel > 0 and victimLevel > myLevel then
        local levelDiff = victimLevel - myLevel
        if levelDiff >= 6 then
            points = points * 3  -- 6+ levels higher = triple points
        elseif levelDiff >= 3 then
            points = points * 2  -- 3-5 levels higher = double points
        else
            points = math.floor(points * 1.5)  -- 1-2 levels = 50% bonus
        end
        points = math.floor(points)
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
    local hasBounty = self:HasActiveBounty(victimFullName)

    -- Determine kill type for points
    local killType = "random"
    if hasBounty then
        killType = "bounty"
    elseif isKOS then
        killType = "kos"
    end

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

    -- Claim bounty if applicable
    if hasBounty then
        self:ClaimBountyKill(victimFullName, killerFullName, zone)
    end

    -- Log the kill
    self:AddKillLogEntry({
        killer = killerFullName,
        victim = victimFullName,
        victimClass = victimClass,
        victimRace = victimRace,
        victimLevel = victimLevel,
        zone = zone,
        time = time(),
        isKOS = isKOS,
        isBounty = hasBounty,
        points = points,
        killType = killType,
    })

    -- Announce
    if self.db.settings.announceKills then
        local display = victimClass and self:ClassColor(victimClass, self:ShortName(victimFullName)) or self:ShortName(victimFullName)
        local typeTag = ""
        if hasBounty then
            typeTag = self.colors.gold .. " [BOUNTY]|r"
        elseif isKOS then
            typeTag = self.colors.red .. " [KOS]|r"
        end
        local killerName = self:ShortName(killerFullName)
        self:Print(self.colors.green .. killerName .. "|r killed " .. display .. typeTag ..
            " in " .. self.colors.yellow .. zone .. "|r (+" .. points .. " pts)")
    end

    -- Show kill streak messages
    local score = self:GetOrCreateScore(killerFullName)
    if score.killStreak == 3 then
        self:Print(self.colors.orange .. self:ShortName(killerFullName) .. " is on a KILLING SPREE!|r")
    elseif score.killStreak == 5 then
        self:Print(self.colors.red .. self:ShortName(killerFullName) .. " is UNSTOPPABLE!|r")
    elseif score.killStreak == 10 then
        self:Print(self.colors.deadpool .. self:ShortName(killerFullName) .. " is GODLIKE! Maximum effort!|r")
    end

    -- Broadcast to guild
    self:BroadcastKill(killerFullName, victimFullName, victimClass, victimRace, victimLevel, zone)

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
