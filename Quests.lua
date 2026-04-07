----------------------------------------------------------------------
-- Deadpool - Quests.lua
-- Deterministic daily/weekly PvP quests. Zero sync overhead.
-- Same seed per guild per day = identical quests for all members.
----------------------------------------------------------------------

local Quests = {}
Deadpool:RegisterModule("Quests", Quests)

-- Populated on Init based on player faction
local ENEMY_RACES = {}
local PLAYER_FACTION = nil

local ENEMY_CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }

local CLASS_DISPLAY = {
    WARRIOR = "Warriors", PALADIN = "Paladins", HUNTER = "Hunters",
    ROGUE = "Rogues", PRIEST = "Priests", SHAMAN = "Shamans",
    MAGE = "Mages", WARLOCK = "Warlocks", DRUID = "Druids",
}

local RACE_DISPLAY = {
    Orc = "Orcs", Undead = "Undead", Tauren = "Tauren", Troll = "Trolls",
    ["Blood Elf"] = "Blood Elves",
    Human = "Humans", Dwarf = "Dwarves", ["Night Elf"] = "Night Elves",
    Gnome = "Gnomes", Draenei = "Draenei",
}

local OUTLAND_ZONES = {
    "Hellfire Peninsula", "Zangarmarsh", "Terokkar Forest",
    "Nagrand", "Blade's Edge Mountains", "Shadowmoon Valley", "Netherstorm",
}
local EK_ZONES = {
    "Stranglethorn Vale", "Hillsbrad Foothills", "Arathi Highlands",
    "Western Plaguelands", "Eastern Plaguelands", "Burning Steppes",
}
local KALIMDOR_ZONES = {
    "Ashenvale", "The Barrens", "Dustwallow Marsh",
    "Tanaris", "Silithus", "Winterspring", "Felwood",
}

local ALL_ZONES = {}
local ZONE_TO_CONTINENT = {}

local CLASS_FLAVORS = {
    WARRIOR = {"Warrior Slayer", "Shield Wall Smasher", "Arms Race"},
    PALADIN = {"Bubble Popper", "Holy Roller", "Hammer Time"},
    HUNTER  = {"Pet Groomer", "Hunter Hunted", "Trap Disarmer"},
    ROGUE   = {"Rogue Roundup", "Unstealthed", "Shadow Stomper"},
    PRIEST  = {"Priest Punisher", "Shadow Purge", "No Heals For You"},
    SHAMAN  = {"Totem Stomper", "Shock Therapy", "Chain Breaker"},
    MAGE    = {"Spell Breaker", "Mage Melter", "Frost Bite"},
    WARLOCK = {"Demon Slayer", "Fear Factor", "DoT Eraser"},
    DRUID   = {"Bear Trap", "Shape Shifted", "Moonfire Sale"},
}
local RACE_FLAVORS = {
    Orc         = {"Orc Chopper", "Green Machine"},
    Undead      = {"Double Dead", "Re-Dead"},
    Tauren      = {"Bull Run", "Steak Dinner"},
    Troll       = {"Troll Toll", "Hex Breaker"},
    ["Blood Elf"] = {"Elf Poacher", "Mana Tap Out"},
    Human       = {"Humanity's End", "Common Problem"},
    Dwarf       = {"Short Circuit", "Beard Trimmer"},
    ["Night Elf"] = {"Elf Hunter", "Shadowmeld This"},
    Gnome       = {"Gnome Punting", "Fun Size Kill"},
    Draenei     = {"Space Invader", "Crash Landing"},
}
local ZONE_FLAVORS = {"Chaos in", "Terror of", "Rampage in", "Blood in", "Domination of"}

----------------------------------------------------------------------
-- Deterministic RNG (consistent across all guild members)
----------------------------------------------------------------------
local _qseed = 0
local function seedRNG(s)
    _qseed = s % 2147483647
    if _qseed == 0 then _qseed = 1 end
end
local function nextRand(n)
    _qseed = (_qseed * 1103515245 + 12345) % 2147483648
    return (_qseed % n) + 1
end
local function pick(tbl) return tbl[nextRand(#tbl)] end

local function getGuildHash()
    local guildName = GetGuildInfo("player") or "NoGuild"
    local hash = 5381
    for i = 1, #guildName do
        hash = ((hash * 33) + string.byte(guildName, i)) % 2147483647
    end
    return hash
end

function Quests:GetDaySeed()
    return (math.floor(time() / 86400) * 7919 + getGuildHash()) % 2147483647
end

function Quests:GetWeekSeed()
    return (math.floor((time() - 345600) / 604800) * 6271 + getGuildHash()) % 2147483647
end

----------------------------------------------------------------------
-- Time helpers
----------------------------------------------------------------------
function Quests:GetDailyResetTime()
    -- Use WoW's built-in daily reset timer (server time accurate)
    if GetQuestResetTime then
        local reset = GetQuestResetTime()
        if reset and reset > 0 then return reset end
    end
    -- Fallback to UTC midnight
    return (math.floor(time() / 86400) + 1) * 86400 - time()
end

function Quests:GetWeeklyResetTime()
    return (math.floor((time() - 345600) / 604800) + 1) * 604800 + 345600 - time()
end

function Quests:FormatDuration(sec)
    local h = math.floor(sec / 3600)
    local m = math.floor((sec % 3600) / 60)
    if h >= 24 then return math.floor(h / 24) .. "d " .. (h % 24) .. "h"
    elseif h > 0 then return h .. "h " .. m .. "m"
    else return m .. "m" end
end

----------------------------------------------------------------------
-- Quest generators (each returns a quest table)
----------------------------------------------------------------------
local function genClassKill(count, reward)
    local class = pick(ENEMY_CLASSES)
    return {
        type = "CLASS_KILL", name = pick(CLASS_FLAVORS[class] or {"Hunt"}),
        desc = "Kill " .. count .. " " .. (CLASS_DISPLAY[class] or class),
        target = class, count = count, reward = reward,
    }
end

local function genRaceKill(count, reward)
    if #ENEMY_RACES == 0 then return genClassKill(count, reward) end
    local race = pick(ENEMY_RACES)
    return {
        type = "RACE_KILL", name = pick(RACE_FLAVORS[race] or {"Hunt"}),
        desc = "Kill " .. count .. " " .. (RACE_DISPLAY[race] or race),
        target = race, count = count, reward = reward,
    }
end

local function genZoneKill(count, reward)
    local zone = pick(ALL_ZONES)
    return {
        type = "ZONE_KILL", name = pick(ZONE_FLAVORS) .. " " .. zone,
        desc = "Kill " .. count .. " players in " .. zone,
        target = zone, count = count, reward = reward,
    }
end

local function genKOSKill(count, reward)
    return {
        type = "KOS_KILL", name = pick({"Hit List", "Mark 'Em Off", "Contract Work", "Target Practice"}),
        desc = "Kill " .. count .. " KOS targets",
        target = nil, count = count, reward = reward,
    }
end

local function genTotalKill(count, reward)
    return {
        type = "TOTAL_KILL", name = pick({"Body Count", "Blood and Thunder", "Open Season", "Free For All"}),
        desc = "Kill " .. count .. " enemy players",
        target = nil, count = count, reward = reward,
    }
end

local function genStreakQuest(count, reward)
    return {
        type = "STREAK", name = pick({"Rampage Mode", "Unstoppable", "Kill Streak", "On A Roll"}),
        desc = "Achieve a " .. count .. "-kill streak",
        target = nil, count = count, reward = reward,
    }
end

local function genMultiZone(count, reward)
    return {
        type = "MULTI_ZONE", name = pick({"World Tour", "Moving Target", "Globe Trotter", "Road Warrior"}),
        desc = "Get kills in " .. count .. " different zones",
        target = nil, count = count, reward = reward,
    }
end

local function genContinentKill(count, reward)
    local cont = pick({"Outland", "Eastern Kingdoms", "Kalimdor"})
    return {
        type = "CONTINENT_KILL", name = cont .. " Assault",
        desc = "Kill " .. count .. " players in " .. cont,
        target = cont, count = count, reward = reward,
    }
end

----------------------------------------------------------------------
-- Generate daily (3) and weekly (2) quest sets from seed
----------------------------------------------------------------------
local DAILY_EASY = { genClassKill, genRaceKill, genTotalKill }
local DAILY_MED  = { genZoneKill, genKOSKill, genClassKill, genRaceKill }
local DAILY_HARD = { genStreakQuest, genMultiZone, genZoneKill }

local WEEKLY_VOLUME    = { genClassKill, genContinentKill, genTotalKill }
local WEEKLY_CHALLENGE = { genStreakQuest, genMultiZone, genKOSKill }

function Quests:GenerateDailies(seed)
    seedRNG(seed)
    local q = {}
    q[1] = DAILY_EASY[nextRand(#DAILY_EASY)](nextRand(2) + 1, 25)   -- 2-3 kills, 25 pts
    q[2] = DAILY_MED[nextRand(#DAILY_MED)](nextRand(2) + 2, 35)     -- 3-4 kills, 35 pts
    local gen3 = DAILY_HARD[nextRand(#DAILY_HARD)]
    if gen3 == genStreakQuest then     q[3] = gen3(nextRand(2) + 2, 50)
    elseif gen3 == genMultiZone then  q[3] = gen3(nextRand(2) + 1, 50)
    else                              q[3] = gen3(nextRand(3) + 3, 50) end
    return q
end

function Quests:GenerateWeeklies(seed)
    seedRNG(seed + 999999)
    local q = {}
    q[1] = WEEKLY_VOLUME[nextRand(#WEEKLY_VOLUME)](nextRand(10) + 15, 150)    -- 16-25, 150 pts
    q[1].isWeekly = true
    local gen2 = WEEKLY_CHALLENGE[nextRand(#WEEKLY_CHALLENGE)]
    if gen2 == genStreakQuest then     q[2] = gen2(nextRand(3) + 3, 200)
    elseif gen2 == genMultiZone then  q[2] = gen2(nextRand(3) + 3, 200)
    else                              q[2] = gen2(nextRand(5) + 5, 200) end
    q[2].isWeekly = true
    return q
end

----------------------------------------------------------------------
-- Ensure quests are current (reset on new day/week)
----------------------------------------------------------------------
function Quests:EnsureCurrent()
    if not Deadpool.db.quests then
        Deadpool.db.quests = {}
    end
    local data = Deadpool.db.quests
    local daySeed = self:GetDaySeed()
    local weekSeed = self:GetWeekSeed()

    if data.dailySeed ~= daySeed then
        data.dailySeed = daySeed
        data.dailyProgress = {0, 0, 0}
        data.dailyCompleted = {false, false, false}
        data.dailyZones = {}
    end
    if data.weeklySeed ~= weekSeed then
        data.weeklySeed = weekSeed
        data.weeklyProgress = {0, 0}
        data.weeklyCompleted = {false, false}
        data.weeklyZones = {}
    end

    self.dailyQuests = self:GenerateDailies(daySeed)
    self.weeklyQuests = self:GenerateWeeklies(weekSeed)
end

----------------------------------------------------------------------
-- Check a single kill against a quest
----------------------------------------------------------------------
function Quests:KillMatchesQuest(quest, victimClass, victimRace, zone, isKOS, isBounty)
    local t = quest.type
    if t == "CLASS_KILL"     then return victimClass and victimClass:upper() == quest.target
    elseif t == "RACE_KILL"  then return victimRace and victimRace == quest.target
    elseif t == "ZONE_KILL"  then return zone and zone == quest.target
    elseif t == "KOS_KILL"   then return isKOS
    elseif t == "BOUNTY_KILL" then return isBounty
    elseif t == "TOTAL_KILL" then return true
    elseif t == "CONTINENT_KILL" then return zone and ZONE_TO_CONTINENT[zone] == quest.target
    end
    return false
end

----------------------------------------------------------------------
-- Kill hook (called from RecordKill)
----------------------------------------------------------------------
function Quests:OnKill(killerFullName, victimFullName, victimClass, victimRace, victimLevel, zone, killType)
    if killerFullName ~= Deadpool:GetPlayerFullName() then return end
    self:EnsureCurrent()

    local data = Deadpool.db.quests
    local isKOS = Deadpool:IsKOS(victimFullName)
    local isBounty = Deadpool:HasActiveBounty(victimFullName)
    local score = Deadpool:GetOrCreateScore(killerFullName)
    local streak = score.killStreak or 0

    -- Check dailies
    for i, quest in ipairs(self.dailyQuests) do
        if not data.dailyCompleted[i] then
            if quest.type == "STREAK" then
                if streak >= quest.count then data.dailyProgress[i] = quest.count end
            elseif quest.type == "MULTI_ZONE" then
                if zone and zone ~= "" then
                    data.dailyZones[zone] = true
                    local c = 0; for _ in pairs(data.dailyZones) do c = c + 1 end
                    data.dailyProgress[i] = c
                end
            elseif self:KillMatchesQuest(quest, victimClass, victimRace, zone, isKOS, isBounty) then
                data.dailyProgress[i] = (data.dailyProgress[i] or 0) + 1
            end
            if (data.dailyProgress[i] or 0) >= quest.count then
                data.dailyCompleted[i] = true
                data.totalDailiesCompleted = (data.totalDailiesCompleted or 0) + 1
                self:OnComplete(quest, "daily")
            end
        end
    end

    -- Check weeklies
    for i, quest in ipairs(self.weeklyQuests) do
        if not data.weeklyCompleted[i] then
            if quest.type == "STREAK" then
                if streak >= quest.count then data.weeklyProgress[i] = quest.count end
            elseif quest.type == "MULTI_ZONE" then
                if zone and zone ~= "" then
                    data.weeklyZones[zone] = true
                    local c = 0; for _ in pairs(data.weeklyZones) do c = c + 1 end
                    data.weeklyProgress[i] = c
                end
            elseif self:KillMatchesQuest(quest, victimClass, victimRace, zone, isKOS, isBounty) then
                data.weeklyProgress[i] = (data.weeklyProgress[i] or 0) + 1
            end
            if (data.weeklyProgress[i] or 0) >= quest.count then
                data.weeklyCompleted[i] = true
                data.totalWeekliesCompleted = (data.totalWeekliesCompleted or 0) + 1
                self:OnComplete(quest, "weekly")
            end
        end
    end
end

----------------------------------------------------------------------
-- Quest completion: award points, announce, notify achievements
----------------------------------------------------------------------
function Quests:OnComplete(quest, questType)
    local myName = Deadpool:GetPlayerFullName()
    local score = Deadpool:GetOrCreateScore(myName)
    score.totalPoints = (score.totalPoints or 0) + quest.reward

    Deadpool:Print(Deadpool.colors.gold .. "QUEST COMPLETE!|r " ..
        quest.name .. " — " .. Deadpool.colors.yellow .. "+" .. quest.reward .. " pts|r")
    Deadpool:PlaySoundByKey("coin")

    -- Check if all 3 dailies done today
    local data = Deadpool.db.quests
    if questType == "daily" then
        local allDone = data.dailyCompleted[1] and data.dailyCompleted[2] and data.dailyCompleted[3]
        if allDone and Deadpool.modules.Achievements then
            Deadpool.modules.Achievements:OnAllDailiesComplete()
        end
    end

    if Deadpool.modules.Achievements and Deadpool.modules.Achievements.OnQuestComplete then
        Deadpool.modules.Achievements:OnQuestComplete(questType)
    end

    if Deadpool.RefreshUI then Deadpool:RefreshUI() end
end

----------------------------------------------------------------------
-- Accessors for UI
----------------------------------------------------------------------
function Quests:GetDailies()
    self:EnsureCurrent()
    local d = Deadpool.db.quests
    return self.dailyQuests, d.dailyProgress, d.dailyCompleted
end

function Quests:GetWeeklies()
    self:EnsureCurrent()
    local d = Deadpool.db.quests
    return self.weeklyQuests, d.weeklyProgress, d.weeklyCompleted
end

----------------------------------------------------------------------
-- Init
----------------------------------------------------------------------
function Quests:Init()
    self._initialized = true

    PLAYER_FACTION = UnitFactionGroup("player")
    if PLAYER_FACTION == "Alliance" then
        ENEMY_RACES = {"Orc", "Undead", "Tauren", "Troll", "Blood Elf"}
    else
        ENEMY_RACES = {"Human", "Dwarf", "Night Elf", "Gnome", "Draenei"}
    end

    -- Build zone tables
    ALL_ZONES = {}; ZONE_TO_CONTINENT = {}
    for _, z in ipairs(OUTLAND_ZONES) do ALL_ZONES[#ALL_ZONES+1] = z; ZONE_TO_CONTINENT[z] = "Outland" end
    for _, z in ipairs(EK_ZONES) do ALL_ZONES[#ALL_ZONES+1] = z; ZONE_TO_CONTINENT[z] = "Eastern Kingdoms" end
    for _, z in ipairs(KALIMDOR_ZONES) do ALL_ZONES[#ALL_ZONES+1] = z; ZONE_TO_CONTINENT[z] = "Kalimdor" end

    -- Init storage
    if not Deadpool.db.quests then Deadpool.db.quests = {} end
    local d = Deadpool.db.quests
    d.dailyProgress  = d.dailyProgress  or {0, 0, 0}
    d.dailyCompleted = d.dailyCompleted or {false, false, false}
    d.weeklyProgress  = d.weeklyProgress  or {0, 0}
    d.weeklyCompleted = d.weeklyCompleted or {false, false}
    d.dailyZones  = d.dailyZones  or {}
    d.weeklyZones = d.weeklyZones or {}
    d.dailySeed  = d.dailySeed  or 0
    d.weeklySeed = d.weeklySeed or 0
    d.totalDailiesCompleted  = d.totalDailiesCompleted  or 0
    d.totalWeekliesCompleted = d.totalWeekliesCompleted or 0

    self:EnsureCurrent()
end
