----------------------------------------------------------------------
-- Deadpool - Data.lua
-- SavedVariables defaults, initialization, and data access helpers
----------------------------------------------------------------------

local DEFAULTS = {
    kosList = {},       -- ["Name-Realm"] = { KOS entry data }
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
        nearbyEnabled = true,          -- show nearby enemy tracker widget
        nearbyWidgetPos = nil,
        killSoundEnabled = true,
        killSound = "gunshot",           -- gunshot, none, or custom
        streakSoundsEnabled = true,    -- play announcer on kill streaks
        deathSound = "gameover1",      -- sound when YOU die to a player
        partyDeathSound = "partydeath", -- sound when party/raid member dies
        partyAttackSound = "warning",    -- sound when party/raid member is attacked
        kosAlertSound = "siren",       -- sound when KOS target spotted
        stealthAlertEnabled = true,    -- alert when enemy stealths nearby
        stealthAlertSound = "warning", -- sound for stealth detection
        showAlertFrame = true,
        alertFramePos = nil,          -- {point, relPoint, x, y}
    },
    -- Guild config (syncs to all members, latest timestamp wins)
    guildConfig = {
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
    syncVersion = 0,    -- incremented on KOS changes for sync protocol
    lastSync = 0,       -- timestamp of last full sync
}

function Deadpool:InitDB()
    -- Per-character saved data (primary store — each character has own guild data)
    if not DeadpoolCharDB then
        DeadpoolCharDB = {}
    end
    -- Account-wide DB kept for achievements only
    if not DeadpoolDB then DeadpoolDB = {} end

    -- One-time migration: copy account-wide data DOWN to per-character
    if not DeadpoolCharDB._migratedFromAccountV2 then
        self:MigrateAccountToChar()
        DeadpoolCharDB._migratedFromAccountV2 = true
        -- CRITICAL: clear guild identity so CheckGuildIdentity treats this as
        -- a fresh install — it will SET the guild name without WIPING data.
        -- The account-wide _guildName may be from a different character's guild.
        DeadpoolCharDB._guildName = nil
    end

    self:MergeDefaults(DeadpoolCharDB, DEFAULTS)
    self.db = DeadpoolCharDB

    -- Ensure arena log exists
    if not self.db.arenaLog then self.db.arenaLog = {} end
end

----------------------------------------------------------------------
-- Migration: copy account-wide DeadpoolDB data into per-character
-- DeadpoolCharDB so each character keeps their own guild data.
-- Only runs once per character (flagged by _migratedFromAccountV2).
----------------------------------------------------------------------
function Deadpool:MigrateAccountToChar()
    if not DeadpoolDB or not next(DeadpoolDB) then return end

    -- Tables to copy from account → character
    local copyKeys = {
        "kosList", "killLog", "deathLog", "enemySheet",
        "scoreboard", "guildConfig", "settings",
    }

    local migrated = 0
    for _, key in ipairs(copyKeys) do
        local src = DeadpoolDB[key]
        if src and type(src) == "table" and next(src) then
            if not DeadpoolCharDB[key] or not next(DeadpoolCharDB[key]) then
                -- Character has no data for this key — copy from account
                DeadpoolCharDB[key] = {}
                for k, v in pairs(src) do
                    DeadpoolCharDB[key][k] = v
                end
                migrated = migrated + 1
            end
        end
    end

    -- Copy ordered lists (killLog, deathLog) properly
    for _, key in ipairs({"killLog", "deathLog"}) do
        local src = DeadpoolDB[key]
        if src and type(src) == "table" and #src > 0 then
            if not DeadpoolCharDB[key] or #DeadpoolCharDB[key] == 0 then
                DeadpoolCharDB[key] = {}
                for i, v in ipairs(src) do
                    DeadpoolCharDB[key][i] = v
                end
            end
        end
    end

    -- Copy guild identity
    if DeadpoolDB._guildName and (not DeadpoolCharDB._guildName or DeadpoolCharDB._guildName == "") then
        DeadpoolCharDB._guildName = DeadpoolDB._guildName
    end

    -- Copy sync version
    if (DeadpoolDB.syncVersion or 0) > (DeadpoolCharDB.syncVersion or 0) then
        DeadpoolCharDB.syncVersion = DeadpoolDB.syncVersion
    end

    -- Copy one-time flags
    if DeadpoolDB._enemySheetCleaned then DeadpoolCharDB._enemySheetCleaned = true end
    if DeadpoolDB._demoPurged then DeadpoolCharDB._demoPurged = true end
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
            local numMembers = GetNumGuildMembers()
            -- Only wipe if we've been stable for a while (not a fresh migration)
            -- and we definitely have no guild
            if numMembers == 0 and self.db._guildName and self.db._guildName ~= ""
                and not self.db._migratedFromAccountV2_justNow then
                self:WipeGuildData("left guild")
                self.db._guildName = ""
            end
        end
        if IsInGuild() then
            C_Timer.After(3, function()
                Deadpool:CheckGuildIdentity()
            end)
        end
        return false
    end

    local realm = GetRealmName() or "Unknown"
    local currentKey = guildName .. "-" .. realm

    -- First time setting guild (fresh install or migration) — just record it, NO WIPE
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
        "kosList", "killLog", "deathLog",
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
-- Migration: one-time merge of per-character DeadpoolCharDB into
-- the account-wide DeadpoolDB so all alts share the same data.
----------------------------------------------------------------------
function Deadpool:MigrateFromCharDB()
    if not DeadpoolCharDB then return end
    if DeadpoolCharDB._mergedToAccount then return end
    -- Nothing to migrate if the per-char DB is empty
    local hasData = false
    for k in pairs(DeadpoolCharDB) do
        if k ~= "_migratedFromAccount" and k ~= "_mergedToAccount" then
            hasData = true
            break
        end
    end
    if not hasData then
        DeadpoolCharDB._mergedToAccount = true
        return
    end

    local dataKeys = {
        "kosList", "enemySheet", "scoreboard",
    }
    local migrated = 0

    -- Merge key-value tables: union, preferring newest entry
    for _, key in ipairs(dataKeys) do
        local src = DeadpoolCharDB[key]
        if type(src) == "table" and next(src) then
            if type(self.db[key]) ~= "table" then self.db[key] = {} end
            for name, entry in pairs(src) do
                local existing = self.db[key][name]
                if not existing then
                    self.db[key][name] = entry
                    migrated = migrated + 1
                else
                    -- For KOS/bounties: keep whichever was added later
                    local srcTime = entry.addedDate or entry.placedDate or entry.firstSeen or 0
                    local dstTime = existing.addedDate or existing.placedDate or existing.firstSeen or 0
                    if srcTime > dstTime then
                        self.db[key][name] = entry
                        migrated = migrated + 1
                    end
                end
            end
        end
    end

    -- Merge ordered lists (killLog, deathLog): combine and deduplicate by timestamp+victim+killer
    for _, key in ipairs({"killLog", "deathLog"}) do
        local src = DeadpoolCharDB[key]
        if type(src) == "table" and #src > 0 then
            if type(self.db[key]) ~= "table" then self.db[key] = {} end
            -- Build index of existing entries for dedup
            local seen = {}
            for _, e in ipairs(self.db[key]) do
                local sig = tostring(e.time or 0) .. (e.victim or "") .. (e.killer or "")
                seen[sig] = true
            end
            for _, e in ipairs(src) do
                local sig = tostring(e.time or 0) .. (e.victim or "") .. (e.killer or "")
                if not seen[sig] then
                    table.insert(self.db[key], e)
                    migrated = migrated + 1
                end
            end
            -- Re-sort newest first
            table.sort(self.db[key], function(a, b)
                return (a.time or 0) > (b.time or 0)
            end)
            -- Trim to max size
            local max = (self.db.settings and self.db.settings.maxKillLogSize) or 500
            while #self.db[key] > max do
                table.remove(self.db[key])
            end
        end
    end

    -- Take higher syncVersion
    local charVer = DeadpoolCharDB.syncVersion or 0
    if charVer > (self.db.syncVersion or 0) then
        self.db.syncVersion = charVer
    end

    -- Merge guildConfig: take newest updatedAt
    if type(DeadpoolCharDB.guildConfig) == "table" then
        local charCfgTime = DeadpoolCharDB.guildConfig.updatedAt or 0
        local dbCfgTime = (self.db.guildConfig and self.db.guildConfig.updatedAt) or 0
        if charCfgTime > dbCfgTime then
            self.db.guildConfig = DeadpoolCharDB.guildConfig
            migrated = migrated + 1
        end
    end

    -- Merge settings (per-char settings win for personal prefs)
    if type(DeadpoolCharDB.settings) == "table" then
        for k, v in pairs(DeadpoolCharDB.settings) do
            if type(v) ~= "table" then
                self.db.settings[k] = v
            end
        end
    end

    -- Preserve guild identity from the character DB (authoritative source)
    if DeadpoolCharDB._guildName and DeadpoolCharDB._guildName ~= "" then
        self.db._guildName = DeadpoolCharDB._guildName
    end

    DeadpoolCharDB._mergedToAccount = true

    if migrated > 0 then
        self:Print(self.colors.green .. "Character data merged into shared account storage. All your alts now share KOS, bounties, and kill data.|r")
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
        -- Only show enemies with actual PvP interaction
        if (enemy.timesKilledUs or 0) > 0 or (enemy.timesWeKilledThem or 0) > 0 then
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
