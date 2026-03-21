----------------------------------------------------------------------
-- Deadpool - Data.lua
-- SavedVariables defaults, initialization, and data access helpers
----------------------------------------------------------------------

local DEFAULTS = {
    kosList = {},       -- ["Name-Realm"] = { KOS entry data }
    bounties = {},      -- ["Name-Realm"] = { bounty contract data }
    killLog = {},       -- ordered list of kills (newest first)
    deathLog = {},      -- ordered list of deaths (newest first)
    enemySheet = {},    -- ["Name-Realm"] = { enemy player aggregated data }
    scoreboard = {},    -- ["Name-Realm"] = { guild member score data }
    settings = {
        debug = false,
        announceKills = true,           -- announce kills in guild chat
        announceKOSSighted = true,      -- alert when KOS target spotted
        alertSound = true,              -- play sound on KOS spotted
        autoKOSOnAttack = true,         -- auto-add any player who attacks you to KOS
        broadcastSightings = true,      -- broadcast KOS sightings to guild
        pointsPerKill = 5,             -- points for a random world PvP kill
        pointsPerKOSKill = 25,         -- points for killing a KOS target
        pointsPerBountyKill = 100,     -- points for killing a bounty target
        officerRank = 1,               -- guild rank index that can manage KOS / bounties (0=GM, 1=officer)
        syncEnabled = true,
        maxKillLogSize = 500,          -- max kill log entries to store
        maxDeathLogSize = 500,
        minimapIcon = { hide = false, minimapPos = 220 },
        theme = "deadpool",             -- active theme preset
        uiScale = 1.0,                  -- UI scale (0.8 to 1.3)
    },
    syncVersion = 0,    -- incremented on KOS/bounty changes for sync protocol
    lastSync = 0,       -- timestamp of last full sync
}

function Deadpool:InitDB()
    if not DeadpoolDB then
        DeadpoolDB = {}
    end

    -- Merge defaults into saved data (preserves existing values)
    self:MergeDefaults(DeadpoolDB, DEFAULTS)
    self.db = DeadpoolDB
end

function Deadpool:MergeDefaults(target, defaults)
    for k, v in pairs(defaults) do
        if target[k] == nil then
            if type(v) == "table" then
                target[k] = {}
                self:MergeDefaults(target[k], v)
            else
                target[k] = v
            end
        elseif type(v) == "table" and type(target[k]) == "table" then
            self:MergeDefaults(target[k], v)
        end
    end
end

----------------------------------------------------------------------
-- KOS data helpers
----------------------------------------------------------------------
function Deadpool:GetKOSEntry(fullName)
    return self.db.kosList[fullName]
end

function Deadpool:IsKOS(fullName)
    return self.db.kosList[fullName] ~= nil
end

function Deadpool:GetKOSCount()
    return self:TableCount(self.db.kosList)
end

function Deadpool:GetKOSSorted(sortField, ascending)
    sortField = sortField or "addedDate"
    local list = {}
    for fullName, entry in pairs(self.db.kosList) do
        entry._key = fullName
        table.insert(list, entry)
    end
    table.sort(list, function(a, b)
        local va, vb = a[sortField] or 0, b[sortField] or 0
        if ascending then return va < vb else return va > vb end
    end)
    return list
end

----------------------------------------------------------------------
-- Bounty data helpers
----------------------------------------------------------------------
function Deadpool:GetBounty(fullName)
    return self.db.bounties[fullName]
end

function Deadpool:HasActiveBounty(fullName)
    local b = self.db.bounties[fullName]
    return b and not b.expired
end

function Deadpool:GetActiveBounties()
    local list = {}
    for fullName, bounty in pairs(self.db.bounties) do
        if not bounty.expired then
            bounty._key = fullName
            table.insert(list, bounty)
        end
    end
    table.sort(list, function(a, b) return (a.bountyGold or 0) > (b.bountyGold or 0) end)
    return list
end

function Deadpool:GetAllBounties()
    local list = {}
    for fullName, bounty in pairs(self.db.bounties) do
        bounty._key = fullName
        table.insert(list, bounty)
    end
    table.sort(list, function(a, b) return (a.placedDate or 0) > (b.placedDate or 0) end)
    return list
end

----------------------------------------------------------------------
-- Kill log helpers
----------------------------------------------------------------------
function Deadpool:AddKillLogEntry(entry)
    table.insert(self.db.killLog, 1, entry)  -- newest first
    -- Trim log
    local max = self.db.settings.maxKillLogSize
    while #self.db.killLog > max do
        table.remove(self.db.killLog)
    end
end

function Deadpool:GetKillLog(filter)
    if not filter or filter == "all" then
        return self.db.killLog
    end
    local filtered = {}
    for _, entry in ipairs(self.db.killLog) do
        if filter == "kos" and entry.isKOS then
            table.insert(filtered, entry)
        elseif filter == "bounty" and entry.isBounty then
            table.insert(filtered, entry)
        end
    end
    return filtered
end

function Deadpool:GetKillCountForVictim(victimFullName)
    local count = 0
    for _, entry in ipairs(self.db.killLog) do
        if entry.victim == victimFullName then
            count = count + 1
        end
    end
    return count
end

----------------------------------------------------------------------
-- Death log helpers
----------------------------------------------------------------------
function Deadpool:AddDeathLogEntry(entry)
    table.insert(self.db.deathLog, 1, entry)
    local max = self.db.settings.maxDeathLogSize
    while #self.db.deathLog > max do
        table.remove(self.db.deathLog)
    end
end

----------------------------------------------------------------------
-- Enemy sheet helpers (Public Enemy tracking)
----------------------------------------------------------------------
function Deadpool:GetOrCreateEnemy(fullName)
    if not self.db.enemySheet[fullName] then
        self.db.enemySheet[fullName] = {
            name = fullName,
            class = nil,
            race = nil,
            level = 0,
            guild = nil,
            timesKilledUs = 0,       -- times they killed guild members
            timesWeKilledThem = 0,   -- times guild killed them
            lastKilledUsTime = 0,
            lastKilledUsBy = nil,    -- which guild member they killed last
            lastWeKilledTime = 0,
            lastWeKilledBy = nil,
            firstSeen = time(),
        }
    end
    return self.db.enemySheet[fullName]
end

function Deadpool:GetPublicEnemiesSorted(sortField)
    sortField = sortField or "timesKilledUs"
    local list = {}
    for fullName, enemy in pairs(self.db.enemySheet) do
        enemy._key = fullName
        table.insert(list, enemy)
    end
    table.sort(list, function(a, b) return (a[sortField] or 0) > (b[sortField] or 0) end)
    return list
end

function Deadpool:GetMyDeathsBy(killerFullName)
    local count = 0
    local myName = self:GetPlayerFullName()
    for _, entry in ipairs(self.db.deathLog) do
        if entry.killer == killerFullName and entry.victim == myName then
            count = count + 1
        end
    end
    return count
end

function Deadpool:GetMyKillsOf(victimFullName)
    local count = 0
    local myName = self:GetPlayerFullName()
    for _, entry in ipairs(self.db.killLog) do
        if entry.victim == victimFullName and entry.killer == myName then
            count = count + 1
        end
    end
    return count
end

----------------------------------------------------------------------
-- Scoreboard helpers
----------------------------------------------------------------------
function Deadpool:GetOrCreateScore(playerFullName)
    if not self.db.scoreboard[playerFullName] then
        self.db.scoreboard[playerFullName] = {
            name = playerFullName,
            totalKills = 0,
            bountyKills = 0,
            kosKills = 0,
            randomKills = 0,
            totalPoints = 0,
            lastKill = 0,
            killStreak = 0,
            bestStreak = 0,
        }
    end
    return self.db.scoreboard[playerFullName]
end

function Deadpool:GetScoreboardSorted(sortField)
    sortField = sortField or "totalPoints"
    local list = {}
    for fullName, score in pairs(self.db.scoreboard) do
        score._key = fullName
        table.insert(list, score)
    end
    table.sort(list, function(a, b) return (a[sortField] or 0) > (b[sortField] or 0) end)
    return list
end

function Deadpool:GetPlayerRank(playerFullName)
    local sorted = self:GetScoreboardSorted("totalPoints")
    for i, score in ipairs(sorted) do
        if score._key == playerFullName then return i end
    end
    return 0
end

----------------------------------------------------------------------
-- Version bumping for sync
----------------------------------------------------------------------
function Deadpool:BumpSyncVersion()
    self.db.syncVersion = (self.db.syncVersion or 0) + 1
end
