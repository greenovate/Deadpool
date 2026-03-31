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

    -- Check KOS list cap (skip if already on list — we're updating, not adding)
    if not self.db.kosList[fullName] then
        local maxKOS = self.db.guildConfig.maxKOSEntries or 100
        if self:TableCount(self.db.kosList) >= maxKOS then
            if not silent then
                self:Print(self.colors.red .. "KOS list is full (" .. maxKOS .. " targets). Remove someone first.|r")
            end
            return false
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
function Deadpool:PlaceBounty(nameOrFullName, amount, maxKills, bountyType)
    bountyType = bountyType or "gold"
    local fullName = self:NormalizeName(nameOrFullName)
    if not fullName then
        self:Print("Invalid player name.")
        return false
    end

    if not amount or amount <= 0 then
        self:Print("Bounty amount must be greater than 0.")
        return false
    end

    maxKills = maxKills or 10
    if maxKills < 1 then maxKills = 1 end

    -- If points bounty, deduct from placer's score
    if bountyType == "points" then
        local myName = self:GetPlayerFullName()
        local score = self:GetOrCreateScore(myName)
        if (score.totalPoints or 0) < amount then
            self:Print(self.colors.red .. "Not enough points!|r You have " .. (score.totalPoints or 0) .. " pts.")
            return false
        end
        score.totalPoints = score.totalPoints - amount
    end

    -- Auto-add to KOS if not already
    if not self:IsKOS(fullName) then
        self:AddToKOS(fullName, "Bounty target", true)
    end

    -- Check for existing active bounty
    if self:HasActiveBounty(fullName) then
        local existing = self.db.bounties[fullName]
        -- Stack bounties: add amount and extend kills
        if bountyType == "gold" then
            existing.bountyGold = (existing.bountyGold or 0) + amount
        else
            existing.bountyPoints = (existing.bountyPoints or 0) + amount
        end
        existing.maxKills = existing.maxKills + maxKills
        existing.lastUpdated = time()
        local reward = bountyType == "gold" and self:FormatGold(existing.bountyGold or 0) or ((existing.bountyPoints or 0) .. " pts")
        self:Print(self.colors.gold .. "Bounty STACKED|r on " .. self:ShortName(fullName) ..
            " — now " .. reward .. " for " .. existing.maxKills .. " kills.")
    else
        self.db.bounties[fullName] = {
            target = fullName,
            bountyGold = bountyType == "gold" and amount or 0,
            bountyPoints = bountyType == "points" and amount or 0,
            bountyType = bountyType,
            placedBy = self:GetPlayerFullName(),
            placedDate = time(),
            maxKills = maxKills,
            currentKills = 0,
            expired = false,
            expiredReason = nil,
            claims = {},
        }
        local reward = bountyType == "gold" and self:FormatGold(amount) or (amount .. " pts")
        self:Print(self.colors.gold .. "CONTRACT PLACED|r — " ..
            self.colors.red .. self:ShortName(fullName) .. "|r — " ..
            reward .. " for " .. maxKills .. " kills.")
    end

    self:BumpSyncVersion()

    -- Broadcast
    self:BroadcastBountyAdd(fullName)

    if self.RefreshUI then self:RefreshUI() end
    return true
end

----------------------------------------------------------------------
-- Contribute to an existing bounty (add gold or points, no kill change)
----------------------------------------------------------------------
function Deadpool:ContributeToBounty(fullName, amount, bountyType)
    bountyType = bountyType or "gold"
    local bounty = self.db.bounties[fullName]
    if not bounty or bounty.expired then
        self:Print("No active bounty on " .. self:ShortName(fullName))
        return false
    end
    if not amount or amount <= 0 then
        self:Print("Amount must be greater than 0.")
        return false
    end

    -- If points, deduct from contributor's score
    if bountyType == "points" then
        local myName = self:GetPlayerFullName()
        local score = self:GetOrCreateScore(myName)
        if (score.totalPoints or 0) < amount then
            self:Print(self.colors.red .. "Not enough points!|r You have " .. (score.totalPoints or 0) .. " pts.")
            return false
        end
        score.totalPoints = score.totalPoints - amount
    end

    if bountyType == "gold" then
        bounty.bountyGold = (bounty.bountyGold or 0) + amount
    else
        bounty.bountyPoints = (bounty.bountyPoints or 0) + amount
    end
    bounty.lastUpdated = time()

    local display = bountyType == "gold" and self:FormatGold(amount) or (amount .. " pts")
    self:Print(self.colors.gold .. "Bounty contribution|r — " .. display ..
        " added to " .. self:ShortName(fullName) .. "'s bounty.")

    self:BumpSyncVersion()
    self:BroadcastBountyAdd(fullName)
    if self.RefreshUI then self:RefreshUI() end
    return true
end

----------------------------------------------------------------------
-- Edit bounty max kills (placer or manager only)
----------------------------------------------------------------------
function Deadpool:EditBountyKills(fullName, newMaxKills)
    local bounty = self.db.bounties[fullName]
    if not bounty or bounty.expired then
        self:Print("No active bounty on " .. self:ShortName(fullName))
        return false
    end
    newMaxKills = tonumber(newMaxKills)
    if not newMaxKills or newMaxKills < 1 then
        self:Print("Max kills must be at least 1.")
        return false
    end

    local myName = self:GetPlayerFullName()
    if bounty.placedBy ~= myName and not self:IsManager() then
        self:Print(self.colors.red .. "Only the bounty placer or a manager can edit this.|r")
        return false
    end

    if newMaxKills < (bounty.currentKills or 0) then
        newMaxKills = bounty.currentKills
    end

    bounty.maxKills = newMaxKills
    bounty.lastUpdated = time()
    self:Print(self.colors.gold .. "Bounty updated|r — " .. self:ShortName(fullName) ..
        " now requires " .. newMaxKills .. " kills.")

    self:BumpSyncVersion()
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

    -- Award bounty points to killer if this is a points bounty
    if (bounty.bountyType == "points" or (bounty.bountyPoints or 0) > 0) and (bounty.maxKills or 1) > 0 then
        local ptsPerKill = math.floor((bounty.bountyPoints or 0) / bounty.maxKills)
        if ptsPerKill > 0 then
            local killerScore = self:GetOrCreateScore(killerFullName)
            killerScore.totalPoints = (killerScore.totalPoints or 0) + ptsPerKill
            self:Print(self.colors.cyan .. self:ShortName(killerFullName) .. "|r earned " ..
                self.colors.yellow .. ptsPerKill .. " bounty pts|r")
        end
    end

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
    local gc = self:GetPointsConfig()
    local points = 0

    if killType == "bounty" then
        points = gc.pointsPerBountyKill or 100
        score.bountyKills = score.bountyKills + 1
    elseif killType == "kos" then
        points = gc.pointsPerKOSKill or 25
        score.kosKills = score.kosKills + 1
    else
        points = gc.pointsPerKill or 5
        score.randomKills = (score.randomKills or 0) + 1
    end

    -- Level-based modifier: relative to YOUR level
    local myLevel = UnitLevel("player") or 0
    local lowbieRange = gc.pointsLowbieRange or 5
    local lowbieReduction = gc.pointsLowbieReduction or 0.5
    local lowbieFloor = gc.pointsLowbieFloor or 1
    local lowbieTier2 = gc.pointsLowbieTier2 or 10

    if victimLevel and victimLevel > 0 and myLevel > 0 then
        local levelDiff = myLevel - victimLevel  -- positive = victim is lower
        if levelDiff > lowbieTier2 then
            -- Far below: floor points
            points = lowbieFloor
        elseif levelDiff > lowbieRange then
            -- Somewhat below: reduced points
            points = math.max(lowbieFloor, math.floor(points * lowbieReduction))
        end
        -- Within range or higher: full points (no reduction)
    end

    -- Underdog bonus: killing someone higher level than you
    if victimLevel and victimLevel > 0 and myLevel > 0 and victimLevel > myLevel then
        local levelDiff = victimLevel - myLevel
        if levelDiff >= 6 then
            points = math.floor(points * (gc.pointsUnderdogMultiplier6 or 3.0))
        elseif levelDiff >= 3 then
            points = math.floor(points * (gc.pointsUnderdogMultiplier3 or 2.0))
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
        local lvlStr = victimLevel and victimLevel > 0 and (self.colors.grey .. " [" .. victimLevel .. "]|r") or ""
        local typeTag = ""
        if hasBounty then
            typeTag = self.colors.gold .. " [BOUNTY]|r"
        elseif isKOS then
            typeTag = self.colors.red .. " [KOS]|r"
        end
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
