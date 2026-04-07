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
        announceKills = true,
        announceKOSSighted = true,
        alertSound = true,
        autoKOSOnAttack = true,
        broadcastSightings = true,
        suppressInSanctuary = true,  -- suppress local KOS alerts in sanctuary zones (Shatt, etc)
        pointsPerKill = 5,
        pointsPerKOSKill = 25,
        pointsPerBountyKill = 100,
        officerRank = 1,
        syncEnabled = true,
        maxKillLogSize = 500,
        maxDeathLogSize = 500,
        minimapIcon = { hide = false, minimapPos = 220 },
        theme = "deadpool",
        uiScale = 1.0,
        showDemoData = false,
        nearbyWidgetPos = nil,
        killSoundEnabled = true,
        killSound = "gunshot",           -- gunshot, none, or custom
        streakSoundsEnabled = true,    -- play announcer on kill streaks
        deathSound = "gameover1",      -- sound when YOU die to a player
        partyDeathSound = "partydeath", -- sound when party/raid member dies
        partyAttackSound = "warning",    -- sound when party/raid member is attacked
        kosAlertSound = "siren",       -- sound when KOS target spotted
        showAlertFrame = true,
        alertFramePos = nil,          -- {point, relPoint, x, y}
    },
    -- GM-managed guild config (syncs to all members, latest timestamp wins)
    guildConfig = {
        pointsPerKill = 10,
        pointsPerKOSKill = 25,
        pointsPerBountyKill = 100,
        pointsUnderdogMultiplier3 = 2.0,   -- 3-5 levels higher
        pointsUnderdogMultiplier6 = 3.0,   -- 6+ levels higher
        pointsLowbieRange = 5,             -- within this many levels = full points
        pointsLowbieReduction = 0.5,       -- 50% for 1 tier below range
        pointsLowbieFloor = 1,             -- kills far below level
        pointsLowbieTier2 = 10,            -- 2nd tier: this many levels below = floor
        managers = {},                     -- ["Name-Realm"] = true, delegated by GM
        warGuilds = {},                    -- ["Guild Name"] = true, guild-wide war declarations
        scoreboardResetAt = 0,             -- timestamp of last scoreboard reset
        killLogResetAt = 0,                -- timestamp of last kill log reset
        kosResetAt = 0,                    -- timestamp of last KOS list purge
        maxKOSEntries = 100,               -- max KOS list size
        kosExpireDays = 14,                -- auto-expire KOS entries after this many days (0 = never)
        updatedBy = "",
        updatedAt = 0,                     -- unix timestamp, latest wins
    },
    syncVersion = 0,    -- incremented on KOS/bounty changes for sync protocol
    lastSync = 0,       -- timestamp of last full sync
}

function Deadpool:InitDB()
    -- Per-character saved data (primary store)
    if not DeadpoolCharDB then
        DeadpoolCharDB = {}
    end
    self:MergeDefaults(DeadpoolCharDB, DEFAULTS)
    self.db = DeadpoolCharDB

    -- Migrate from old account-wide DeadpoolDB if this character hasn't been migrated
    self:MigrateFromAccountDB()
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
-- Guild identity: detect guild changes and wipe stale data
-- Prevents contamination when a player leaves one guild and joins
-- another. On guild change, local guild data is wiped and the addon
-- re-syncs fresh from the new guild.
--
-- CRITICAL: This must NEVER run before guild info is available from
-- the server. GetGuildInfo() and IsInGuild() return nil/false during
-- early loading (ADDON_LOADED). Only call after PLAYER_ENTERING_WORLD
-- with a delay.
----------------------------------------------------------------------
function Deadpool:CheckGuildIdentity()
    local guildName = GetGuildInfo("player")

    -- If guild info isn't available yet, do nothing and retry later.
    -- NEVER make wipe decisions without confirmed guild data.
    if not guildName or guildName == "" then
        if not IsInGuild() then
            -- Confirmed not in a guild (not just loading).
            -- But only wipe if we had a guild AND we can confirm we truly
            -- have no guild (double-check with GetNumGuildMembers).
            local numMembers = GetNumGuildMembers()
            if numMembers == 0 and self.db._guildName and self.db._guildName ~= "" then
                self:WipeGuildData("left guild")
                self.db._guildName = ""
            end
        end
        -- If IsInGuild() is true but GetGuildInfo returned nil, guild info
        -- is still loading. Do NOT wipe. Schedule a retry.
        if IsInGuild() then
            C_Timer.After(3, function()
                Deadpool:CheckGuildIdentity()
            end)
        end
        return false
    end

    local realm = GetRealmName() or "Unknown"
    local currentKey = guildName .. "-" .. realm

    -- First time setting guild (fresh install or migration) — just record it
    if not self.db._guildName or self.db._guildName == "" then
        self.db._guildName = currentKey
        return true
    end

    -- Guild changed: confirmed positive mismatch (both old and new are real)
    if self.db._guildName ~= currentKey then
        self:WipeGuildData("guild changed from " .. self.db._guildName .. " to " .. currentKey)
        self.db._guildName = currentKey
    end

    return true
end

function Deadpool:WipeGuildData(reason)
    local guildTables = {
        "kosList", "bounties", "killLog", "deathLog",
        "enemySheet", "scoreboard", "guildConfig",
    }
    for _, key in ipairs(guildTables) do
        if type(DEFAULTS[key]) == "table" then
            self.db[key] = {}
            self:MergeDefaults(self.db[key], DEFAULTS[key])
        else
            self.db[key] = DEFAULTS[key]
        end
    end
    self.db.syncVersion = 0
    self.db.lastSync = 0
    self:Print(self.colors.yellow .. "Guild data reset (" .. reason .. "). Syncing fresh...|r")
end

----------------------------------------------------------------------
-- Migration: one-time move from old account-wide DeadpoolDB
-- Copies data to this character's DeadpoolCharDB, then marks done.
----------------------------------------------------------------------
function Deadpool:MigrateFromAccountDB()
    if self.db._migratedFromAccount then return end
    if not DeadpoolDB then return end

    -- Check for old flat-format data at top level
    local oldDataKeys = {
        "kosList", "bounties", "killLog", "deathLog",
        "enemySheet", "scoreboard", "guildConfig",
        "syncVersion", "lastSync",
    }

    -- Try old flat format first
    local migrated = 0
    for _, key in ipairs(oldDataKeys) do
        if DeadpoolDB[key] ~= nil then
            local src = DeadpoolDB[key]
            if type(src) == "table" then
                if type(self.db[key]) ~= "table" or not next(self.db[key]) then
                    self.db[key] = src
                    migrated = migrated + 1
                end
            else
                self.db[key] = src
                migrated = migrated + 1
            end
        end
    end

    -- Also try guild-keyed format (from the previous guild-bucket system)
    if DeadpoolDB.guilds and next(DeadpoolDB.guilds) then
        -- Find the bucket matching our current guild, or take the only one
        local guildName = GetGuildInfo("player")
        local realm = GetRealmName() or "Unknown"
        local currentKey = guildName and (guildName .. "-" .. realm) or nil

        local sourceKey = currentKey and DeadpoolDB.guilds[currentKey] and currentKey
        if not sourceKey then
            -- Take the first (and likely only) guild bucket
            for k in pairs(DeadpoolDB.guilds) do
                sourceKey = k
                break
            end
        end

        if sourceKey and DeadpoolDB.guilds[sourceKey] then
            local bucket = DeadpoolDB.guilds[sourceKey]
            for _, key in ipairs(oldDataKeys) do
                if bucket[key] ~= nil then
                    local src = bucket[key]
                    if type(src) == "table" then
                        if type(self.db[key]) ~= "table" or not next(self.db[key]) then
                            self.db[key] = src
                            migrated = migrated + 1
                        end
                    else
                        self.db[key] = src
                        migrated = migrated + 1
                    end
                end
            end
        end
    end

    -- Migrate settings
    if DeadpoolDB.settings then
        self:MergeDefaults(self.db.settings, DeadpoolDB.settings)
        -- Copy existing values that differ from defaults
        for k, v in pairs(DeadpoolDB.settings) do
            if self.db.settings[k] == nil or (type(v) ~= "table") then
                self.db.settings[k] = v
            end
        end
    end

    self.db._migratedFromAccount = true

    if migrated > 0 then
        self:Print(self.colors.green .. "Data migrated to per-character storage.|r")
    end
end

----------------------------------------------------------------------
-- KOS data helpers
----------------------------------------------------------------------
function Deadpool:GetKOSEntry(fullName)
    return self.db.kosList[fullName]
end

function Deadpool:IsKOS(fullName)
    if self.db.kosList[fullName] ~= nil then return true end
    -- Check war guilds: if we know this player's guild and it's on the war list
    local warGuilds = self.db.guildConfig and self.db.guildConfig.warGuilds
    if warGuilds and next(warGuilds) then
        -- Check enemy sheet for guild info
        local enemy = self.db.enemySheet[fullName]
        if enemy and enemy.guild and warGuilds[enemy.guild] then return true end
        -- Also check KOS entry (shouldn't exist if purely war, but safety)
    end
    return false
end

function Deadpool:IsWarGuild(guildName)
    if not guildName or guildName == "" then return false end
    local warGuilds = self.db.guildConfig and self.db.guildConfig.warGuilds
    return warGuilds and warGuilds[guildName] == true
end

function Deadpool:IsAggressive(fullName)
    local enemy = self.db.enemySheet[fullName]
    if not enemy then return false end
    if not enemy.isAggressive then return false end
    if enemy.aggressiveUntil and time() > enemy.aggressiveUntil then
        enemy.isAggressive = false
        return false
    end
    return true
end

function Deadpool:IsWarGuildKOS(fullName)
    -- Returns true ONLY if this player is KOS because of a guild war (not manually added)
    if self.db.kosList[fullName] then return false end  -- manually on KOS, not war-based
    return self:IsKOS(fullName)  -- if IsKOS returns true but not on kosList, it's war guild
end

function Deadpool:GetKOSCount()
    return self:TableCount(self.db.kosList)
end

function Deadpool:GetKOSSorted(sortField, ascending)
    sortField = sortField or "addedDate"
    local list = {}
    local source = Deadpool.demoData:GetMergedKOS()
    for fullName, entry in pairs(source) do
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
    local source = Deadpool.demoData:GetMergedBounties()
    for fullName, bounty in pairs(source) do
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
    local source = Deadpool.demoData:GetMergedBounties()
    for fullName, bounty in pairs(source) do
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
    local source = Deadpool.demoData:GetMergedKillLog()
    if not filter or filter == "all" then
        return source
    end
    local filtered = {}
    for _, entry in ipairs(source) do
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
    local source = Deadpool.demoData:GetMergedEnemySheet()
    for fullName, enemy in pairs(source) do
        -- Only include enemies who have actually killed guild members
        if (enemy.timesKilledUs or 0) > 0 then
            enemy._key = fullName
            table.insert(list, enemy)
        end
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
    local source = Deadpool.demoData:GetMergedScoreboard()
    for fullName, score in pairs(source) do
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
