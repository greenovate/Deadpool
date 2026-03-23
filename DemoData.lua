----------------------------------------------------------------------
-- Deadpool - DemoData.lua
-- Runtime-only demo data for showcase/first-install experience
-- Never written to SavedVariables — generated fresh each session
----------------------------------------------------------------------

local DemoData = {}
Deadpool.demoData = DemoData

-- Cache: built once per session on first access
local cache = nil

local FAKE_ENEMIES = {
    { name = "Gankerface",   class = "ROGUE",   race = "Undead",    level = 70, guild = "Wrath of Noobs" },
    { name = "Cheesewheel",  class = "MAGE",    race = "Undead",    level = 70, guild = "Lowbie Terrorz" },
    { name = "Stabbymcstab", class = "ROGUE",   race = "Orc",       level = 68 },
    { name = "Darkshdow",    class = "WARLOCK", race = "Undead",    level = 70, guild = "Shadow Council" },
    { name = "Griefdaddy",   class = "WARRIOR", race = "Tauren",    level = 70, guild = "Ganksquad" },
    { name = "Frostitute",   class = "MAGE",    race = "Troll",     level = 69, guild = "Ice Cold Killaz" },
    { name = "Dotsndots",    class = "WARLOCK", race = "Undead",    level = 70, guild = "Shadow Council" },
    { name = "Healznope",    class = "PRIEST",  race = "Undead",    level = 70, guild = "Wrath of Noobs" },
    { name = "Moonpunter",   class = "DRUID",   race = "Tauren",    level = 70, guild = "Ganksquad" },
    { name = "Critsworth",   class = "HUNTER",  race = "Orc",       level = 70, guild = "Lowbie Terrorz" },
    { name = "Shockadin",    class = "PALADIN", race = "Blood Elf", level = 70, guild = "Wrath of Noobs" },
    { name = "Sneakypeek",   class = "ROGUE",   race = "Blood Elf", level = 67 },
    { name = "Frostshawk",   class = "SHAMAN",  race = "Orc",       level = 70, guild = "Ice Cold Killaz" },
    { name = "Felburner",    class = "WARLOCK", race = "Blood Elf", level = 70, guild = "Shadow Council" },
}

local FAKE_GUILDIES = {
    "Thunderbro", "Slapmage", "Holycrit", "Tankenstein", "Arrowstorm",
    "Dotweaver", "Critmachine", "Bubbleboy", "Wrathchild", "Evildemo",
}

local ZONES = {
    "Hellfire Peninsula", "Nagrand", "Terokkar Forest", "Zangarmarsh",
    "Blade's Edge Mountains", "Shadowmoon Valley", "Netherstorm",
    "Shattrath City", "Halaa", "Auchindoun",
}

local REASONS = {
    "Ganked at summoning stone", "Camped our alt", "Killed quest NPCs",
    "Corpse camped 5x", "Wiped our dungeon group", "Killed lowbie guildies",
    "Stole our ore node", "Ganked at flight path", "General scumbaggery",
    "Jumped me at half HP", "Killed me during a quest turn-in",
}

local RANDOM_ENEMIES = {
    { name = "Randogank",   class = "WARRIOR", race = "Orc",       level = 70 },
    { name = "Justpassing", class = "HUNTER",  race = "Troll",     level = 68 },
    { name = "Whoopsidied", class = "MAGE",    race = "Blood Elf", level = 66 },
    { name = "Flagrunner",  class = "DRUID",   race = "Tauren",    level = 70 },
    { name = "Notaganker",  class = "PALADIN", race = "Blood Elf", level = 70 },
    { name = "Wpvpandy",   class = "SHAMAN",  race = "Orc",       level = 69 },
    { name = "Oopsifell",   class = "PRIEST",  race = "Undead",    level = 67 },
    { name = "Wasntme",     class = "ROGUE",   race = "Blood Elf", level = 70 },
}

-- Deterministic "random" based on a seed string so demo data is stable per session
local _seed = 12345
local function dRand(n)
    _seed = (_seed * 1103515245 + 12345) % 2147483648
    return (_seed % n) + 1
end

local function pick(tbl) return tbl[dRand(#tbl)] end

local function buildCache()
    _seed = 12345  -- reset seed for deterministic output
    local realm = "DemoRealm"
    local now = time()
    local c = {
        kosList = {},
        bounties = {},
        scoreboard = {},
        enemySheet = {},
        killLog = {},
        deathLog = {},
    }

    -- KOS entries
    for _, e in ipairs(FAKE_ENEMIES) do
        local fn = e.name .. "-" .. realm
        c.kosList[fn] = {
            name = e.name, realm = realm, class = e.class, race = e.race,
            level = e.level, guild = e.guild,
            addedBy = pick(FAKE_GUILDIES) .. "-" .. realm,
            addedDate = now - dRand(604800),
            reason = pick(REASONS),
            totalKills = dRand(25),
            lastKilledBy = pick(FAKE_GUILDIES) .. "-" .. realm,
            lastKilledTime = now - dRand(172800),
            lastSeenZone = pick(ZONES),
            lastSeenTime = now - dRand(7200),
            _demo = true,
        }
    end

    -- Bounties: 5 active, 3 expired (mix of gold and points)
    for i = 1, 8 do
        local e = FAKE_ENEMIES[i]
        local fn = e.name .. "-" .. realm
        local isPointsBounty = (i % 3 == 0)  -- every 3rd bounty is points
        local gold = isPointsBounty and 0 or (dRand(10) * 25)
        local pts = isPointsBounty and (dRand(10) * 50) or 0
        local maxK = dRand(15) + 5
        local curK = dRand(maxK)
        local expired = (i > 5)
        if expired then curK = maxK end
        local claims = {}
        for j = 1, curK do
            claims[j] = {
                killer = pick(FAKE_GUILDIES) .. "-" .. realm,
                time = now - dRand(259200),
                zone = pick(ZONES),
            }
        end
        c.bounties[fn] = {
            target = fn,
            bountyGold = gold,
            bountyPoints = pts,
            bountyType = isPointsBounty and "points" or "gold",
            placedBy = pick(FAKE_GUILDIES) .. "-" .. realm,
            placedDate = now - dRand(432000),
            maxKills = maxK, currentKills = curK,
            expired = expired,
            expiredReason = expired and "Completed" or nil,
            claims = claims,
            _demo = true,
        }
    end

    -- Scoreboard
    for _, name in ipairs(FAKE_GUILDIES) do
        local fn = name .. "-" .. realm
        local kills = dRand(140) + 10
        local kosK = dRand(math.floor(kills * 0.4))
        local bountyK = dRand(math.floor(kills * 0.15))
        local randomK = kills - kosK - bountyK
        c.scoreboard[fn] = {
            name = fn, totalKills = kills,
            bountyKills = bountyK, kosKills = kosK, randomKills = randomK,
            totalPoints = randomK * 5 + kosK * 25 + bountyK * 100 + dRand(200),
            lastKill = now - dRand(172800),
            killStreak = 0, bestStreak = dRand(12),
            _demo = true,
        }
    end

    -- Enemy sheet
    for _, e in ipairs(FAKE_ENEMIES) do
        local fn = e.name .. "-" .. realm
        c.enemySheet[fn] = {
            name = fn, class = e.class, race = e.race, level = e.level, guild = e.guild,
            timesKilledUs = dRand(18),
            timesWeKilledThem = dRand(30),
            lastKilledUsTime = now - dRand(172800),
            lastKilledUsBy = pick(FAKE_GUILDIES) .. "-" .. realm,
            lastWeKilledTime = now - dRand(86400),
            lastWeKilledBy = pick(FAKE_GUILDIES) .. "-" .. realm,
            firstSeen = now - dRand(604800),
            _demo = true,
        }
    end

    -- Kill log: 40 KOS/bounty + 20 random
    for i = 1, 40 do
        local killer = pick(FAKE_GUILDIES)
        local victim = pick(FAKE_ENEMIES)
        local fn = victim.name .. "-" .. realm
        local isKOS = c.kosList[fn] ~= nil
        local isBounty = c.bounties[fn] ~= nil and not c.bounties[fn].expired
        local pts = isBounty and 100 or (isKOS and 25 or 5)
        c.killLog[#c.killLog + 1] = {
            killer = killer .. "-" .. realm, victim = fn,
            victimClass = victim.class, victimRace = victim.race, victimLevel = victim.level,
            zone = pick(ZONES), time = now - dRand(432000),
            isKOS = isKOS, isBounty = isBounty, points = pts,
            killType = isBounty and "bounty" or (isKOS and "kos" or "random"),
            _demo = true,
        }
    end
    for i = 1, 20 do
        local killer = pick(FAKE_GUILDIES)
        local victim = pick(RANDOM_ENEMIES)
        c.killLog[#c.killLog + 1] = {
            killer = killer .. "-" .. realm, victim = victim.name .. "-" .. realm,
            victimClass = victim.class, victimRace = victim.race, victimLevel = victim.level,
            zone = pick(ZONES), time = now - dRand(432000),
            isKOS = false, isBounty = false, points = 5, killType = "random",
            _demo = true,
        }
    end
    table.sort(c.killLog, function(a, b) return (a.time or 0) > (b.time or 0) end)

    -- Death log
    for i = 1, 20 do
        local killer = pick(FAKE_ENEMIES)
        local victim = pick(FAKE_GUILDIES)
        c.deathLog[#c.deathLog + 1] = {
            killer = killer.name .. "-" .. realm, victim = victim .. "-" .. realm,
            killerClass = killer.class, killerRace = killer.race,
            zone = pick(ZONES), time = now - dRand(345600),
            _demo = true,
        }
    end
    table.sort(c.deathLog, function(a, b) return (a.time or 0) > (b.time or 0) end)

    cache = c
end

function DemoData:IsEnabled()
    return Deadpool.db and Deadpool.db.settings.showDemoData
end

function DemoData:Get()
    if not cache then buildCache() end
    return cache
end

-- Merge a keyed table (kosList, bounties, scoreboard, enemySheet)
function DemoData:MergeKeyed(realTable)
    if not self:IsEnabled() then return realTable end
    local demo = self:Get()
    -- Return a shallow merged view (demo entries won't overwrite real ones)
    local merged = {}
    local src = demo.kosList  -- will be overridden by callers
    -- This is a generic helper; callers pass the demo sub-table
    return merged
end

-- Returns merged kosList (real + demo, real wins on conflicts)
function DemoData:GetMergedKOS()
    if not self:IsEnabled() then return Deadpool.db.kosList end
    local merged = {}
    for k, v in pairs(self:Get().kosList) do merged[k] = v end
    for k, v in pairs(Deadpool.db.kosList) do merged[k] = v end  -- real overwrites demo
    return merged
end

function DemoData:GetMergedBounties()
    if not self:IsEnabled() then return Deadpool.db.bounties end
    local merged = {}
    for k, v in pairs(self:Get().bounties) do merged[k] = v end
    for k, v in pairs(Deadpool.db.bounties) do merged[k] = v end
    return merged
end

function DemoData:GetMergedScoreboard()
    if not self:IsEnabled() then return Deadpool.db.scoreboard end
    local merged = {}
    for k, v in pairs(self:Get().scoreboard) do merged[k] = v end
    for k, v in pairs(Deadpool.db.scoreboard) do merged[k] = v end
    return merged
end

function DemoData:GetMergedEnemySheet()
    if not self:IsEnabled() then return Deadpool.db.enemySheet end
    local merged = {}
    for k, v in pairs(self:Get().enemySheet) do merged[k] = v end
    for k, v in pairs(Deadpool.db.enemySheet) do merged[k] = v end
    return merged
end

function DemoData:GetMergedKillLog()
    if not self:IsEnabled() then return Deadpool.db.killLog end
    local merged = {}
    for _, v in ipairs(Deadpool.db.killLog) do merged[#merged + 1] = v end
    for _, v in ipairs(self:Get().killLog) do merged[#merged + 1] = v end
    table.sort(merged, function(a, b) return (a.time or 0) > (b.time or 0) end)
    return merged
end

function DemoData:GetMergedDeathLog()
    if not self:IsEnabled() then return Deadpool.db.deathLog or {} end
    local merged = {}
    for _, v in ipairs(Deadpool.db.deathLog or {}) do merged[#merged + 1] = v end
    for _, v in ipairs(self:Get().deathLog) do merged[#merged + 1] = v end
    table.sort(merged, function(a, b) return (a.time or 0) > (b.time or 0) end)
    return merged
end
