----------------------------------------------------------------------
-- Deadpool - Achievements.lua
-- Account-wide PvP achievements with backup/restore
-- Stored in DeadpoolDB (account-wide SavedVariables)
----------------------------------------------------------------------

local Achievements = {}
Deadpool:RegisterModule("Achievements", Achievements)

----------------------------------------------------------------------
-- Achievement definitions
-- type: "score" (scoreboard field), "counter" (our tracker),
--       "set_size" (unique set count), "best_streak" (scoreboard)
----------------------------------------------------------------------
local ACHIEVEMENT_LIST = {
    -- MILESTONES
    { id=1,  cat="MILESTONES", name="First Blood",       desc="Get your first PvP kill",              pts=10,  type="score",  key="totalKills",    goal=1 },
    { id=2,  cat="MILESTONES", name="Bounty Collector",  desc="Kill a bounty target",                 pts=25,  type="score",  key="bountyKills",   goal=1 },
    { id=3,  cat="MILESTONES", name="Target Acquired",   desc="Kill a KOS target",                    pts=25,  type="score",  key="kosKills",      goal=1 },
    { id=4,  cat="MILESTONES", name="Hired Gun",         desc="Complete your first daily quest",       pts=15,  type="counter", key="quests_daily",  goal=1 },

    -- KILL COUNT
    { id=10, cat="KILL COUNT", name="Getting Started",   desc="Get 10 PvP kills",                     pts=25,  type="score",  key="totalKills",    goal=10 },
    { id=11, cat="KILL COUNT", name="Body Count",        desc="Get 50 PvP kills",                     pts=50,  type="score",  key="totalKills",    goal=50 },
    { id=12, cat="KILL COUNT", name="Serial Killer",     desc="Get 100 PvP kills",                    pts=100, type="score",  key="totalKills",    goal=100 },
    { id=13, cat="KILL COUNT", name="Mass Murderer",     desc="Get 250 PvP kills",                    pts=150, type="score",  key="totalKills",    goal=250 },
    { id=14, cat="KILL COUNT", name="Genocide",          desc="Get 500 PvP kills",                    pts=250, type="score",  key="totalKills",    goal=500 },
    { id=15, cat="KILL COUNT", name="The Deadpool",      desc="Get 1,000 PvP kills",                  pts=500, type="score",  key="totalKills",    goal=1000 },

    -- STREAKS
    { id=20, cat="STREAKS",    name="Double Tap",        desc="Achieve a 2-kill streak",              pts=10,  type="score",  key="bestStreak",    goal=2 },
    { id=21, cat="STREAKS",    name="Hat Trick",         desc="Achieve a 3-kill streak",              pts=25,  type="score",  key="bestStreak",    goal=3 },
    { id=22, cat="STREAKS",    name="Rampage",           desc="Achieve a 5-kill streak",              pts=50,  type="score",  key="bestStreak",    goal=5 },
    { id=23, cat="STREAKS",    name="Unstoppable",       desc="Achieve an 8-kill streak",             pts=100, type="score",  key="bestStreak",    goal=8 },
    { id=24, cat="STREAKS",    name="Godlike",           desc="Achieve a 10-kill streak",             pts=200, type="score",  key="bestStreak",    goal=10 },
    { id=25, cat="STREAKS",    name="Are You Cheating?", desc="Achieve a 15-kill streak",             pts=500, type="score",  key="bestStreak",    goal=15 },

    -- CLASS MASTERY
    { id=30, cat="CLASS",      name="Jack of All Trades",desc="Kill every enemy class at least once", pts=50,  type="set_size", key="classes_killed", goal=9 },
    { id=31, cat="CLASS",      name="Class Specialist",  desc="Kill 50 of any single class",          pts=75,  type="counter", key="best_class_kills", goal=50 },
    { id=32, cat="CLASS",      name="Equal Opportunity", desc="Kill 10 of every enemy class",         pts=200, type="counter", key="min_class_kills", goal=10 },
    { id=33, cat="CLASS",      name="Rogue Stomper",     desc="Kill 25 Rogues",                       pts=50,  type="counter", key="kills_ROGUE",   goal=25 },
    { id=34, cat="CLASS",      name="Mage Melter",       desc="Kill 25 Mages",                        pts=50,  type="counter", key="kills_MAGE",    goal=25 },
    { id=35, cat="CLASS",      name="Priest Punisher",   desc="Kill 25 Priests",                      pts=50,  type="counter", key="kills_PRIEST",  goal=25 },
    { id=36, cat="CLASS",      name="Warrior Wrecker",   desc="Kill 25 Warriors",                     pts=50,  type="counter", key="kills_WARRIOR", goal=25 },
    { id=37, cat="CLASS",      name="Hunter Hunted",     desc="Kill 25 Hunters",                      pts=50,  type="counter", key="kills_HUNTER",  goal=25 },
    { id=38, cat="CLASS",      name="Totem Stomper",     desc="Kill 25 Shamans",                      pts=50,  type="counter", key="kills_SHAMAN",  goal=25 },
    { id=39, cat="CLASS",      name="Demon Slayer",      desc="Kill 25 Warlocks",                     pts=50,  type="counter", key="kills_WARLOCK", goal=25 },
    { id=110,cat="CLASS",      name="Bear Trap",         desc="Kill 25 Druids",                       pts=50,  type="counter", key="kills_DRUID",   goal=25 },
    { id=111,cat="CLASS",      name="Bubble Popper",     desc="Kill 25 Paladins",                     pts=50,  type="counter", key="kills_PALADIN", goal=25 },

    -- BOUNTY
    { id=40, cat="BOUNTY",     name="Contract Killer",   desc="Complete 1 bounty contract",           pts=50,  type="counter", key="bounties_completed", goal=1 },
    { id=41, cat="BOUNTY",     name="Bounty Hunter",     desc="Complete 5 bounty contracts",          pts=100, type="counter", key="bounties_completed", goal=5 },
    { id=42, cat="BOUNTY",     name="Dead or Alive",     desc="Complete 10 bounty contracts",         pts=200, type="counter", key="bounties_completed", goal=10 },
    { id=43, cat="BOUNTY",     name="Place a Hit",       desc="Place your first bounty",              pts=25,  type="counter", key="bounties_placed",    goal=1 },

    -- KOS
    { id=50, cat="KOS",        name="Watchlist",         desc="Add your first KOS target",            pts=10,  type="counter", key="kos_added",          goal=1 },
    { id=51, cat="KOS",        name="Executioner",       desc="Kill 10 unique KOS targets",           pts=75,  type="set_size", key="unique_kos_killed", goal=10 },
    { id=52, cat="KOS",        name="The Punisher",      desc="Kill 25 unique KOS targets",           pts=150, type="set_size", key="unique_kos_killed", goal=25 },
    { id=53, cat="KOS",        name="Clean Sweep",       desc="Kill 50 unique KOS targets",           pts=300, type="set_size", key="unique_kos_killed", goal=50 },
    { id=54, cat="KOS",        name="KOS Veteran",       desc="Kill 100 KOS targets (total)",         pts=150, type="score",   key="kosKills",          goal=100 },

    -- ZONES
    { id=60, cat="ZONES",      name="World Traveler",    desc="Get kills in 5 different zones",       pts=50,  type="set_size", key="zones_killed_in",   goal=5 },
    { id=61, cat="ZONES",      name="Continental",       desc="Get kills in 10 different zones",      pts=100, type="set_size", key="zones_killed_in",   goal=10 },
    { id=62, cat="ZONES",      name="Both Worlds",       desc="Get kills in Outland and Azeroth",     pts=50,  type="set_size", key="continents_killed",  goal=2 },
    { id=63, cat="ZONES",      name="Hellfire Veteran",  desc="Kill 10 players in Hellfire Peninsula",pts=50,  type="counter", key="kills_z_Hellfire Peninsula", goal=10 },
    { id=64, cat="ZONES",      name="Nagrand Champion",  desc="Kill 10 players in Nagrand",           pts=50,  type="counter", key="kills_z_Nagrand",    goal=10 },
    { id=65, cat="ZONES",      name="Terokkar Terror",   desc="Kill 10 players in Terokkar Forest",   pts=50,  type="counter", key="kills_z_Terokkar Forest", goal=10 },
    { id=66, cat="ZONES",      name="Zangarmarsh Menace",desc="Kill 10 players in Zangarmarsh",       pts=50,  type="counter", key="kills_z_Zangarmarsh", goal=10 },
    { id=67, cat="ZONES",      name="Edge Lord",         desc="Kill 10 players in Blade's Edge Mtns", pts=50,  type="counter", key="kills_z_Blade's Edge Mountains", goal=10 },
    { id=68, cat="ZONES",      name="Shadow Walker",     desc="Kill 10 players in Shadowmoon Valley", pts=50,  type="counter", key="kills_z_Shadowmoon Valley", goal=10 },
    { id=69, cat="ZONES",      name="Netherstorm Raider", desc="Kill 10 players in Netherstorm",      pts=50,  type="counter", key="kills_z_Netherstorm", goal=10 },
    { id=100,cat="ZONES",      name="Outland Assassin",  desc="Kill players in all 7 Outland zones",  pts=300, type="set_size", key="outland_zones_killed", goal=7 },
    { id=101,cat="ZONES",      name="World Wide Assassin",desc="Kill players in 15 different zones",  pts=500, type="set_size", key="zones_killed_in",   goal=15 },

    -- REVENGE
    { id=70, cat="REVENGE",    name="Payback",           desc="Kill someone who has killed you",      pts=25,  type="counter", key="revenge_kills",      goal=1 },
    { id=71, cat="REVENGE",    name="Grudge Match",      desc="Kill the same player 10 times",        pts=75,  type="counter", key="grudge_kill_max",    goal=10 },
    { id=72, cat="REVENGE",    name="Eye for an Eye",    desc="Get 10 revenge kills",                 pts=75,  type="counter", key="revenge_kills",      goal=10 },
    { id=73, cat="REVENGE",    name="Nemesis Slayer",    desc="Kill the same player 25 times",        pts=200, type="counter", key="grudge_kill_max",    goal=25 },
    { id=74, cat="REVENGE",    name="Vendetta",          desc="Get 50 revenge kills",                 pts=200, type="counter", key="revenge_kills",      goal=50 },

    -- QUESTS
    { id=80, cat="QUESTS",     name="Merc Work",         desc="Complete 5 daily quests",              pts=25,  type="counter", key="quests_daily",       goal=5 },
    { id=81, cat="QUESTS",     name="Contract Employee", desc="Complete 25 daily quests",             pts=75,  type="counter", key="quests_daily",       goal=25 },
    { id=82, cat="QUESTS",     name="Full-Time Merc",    desc="Complete 50 daily quests",             pts=150, type="counter", key="quests_daily",       goal=50 },
    { id=83, cat="QUESTS",     name="Weekend Warrior",   desc="Complete 3 weekly quests",             pts=50,  type="counter", key="quests_weekly",      goal=3 },
    { id=84, cat="QUESTS",     name="Overachiever",      desc="Complete all 3 dailies in one day",    pts=100, type="counter", key="all_dailies_days",   goal=1 },

    -- UNDERDOG
    { id=90, cat="UNDERDOG",   name="Underdog",          desc="Kill a player 6+ levels above you",    pts=50,  type="counter", key="underdog_kills",     goal=1 },
    { id=91, cat="UNDERDOG",   name="David vs Goliath",  desc="Kill a player 10+ levels above you",   pts=150, type="counter", key="goliath_kills",      goal=1 },
    { id=92, cat="UNDERDOG",   name="Giant Slayer",      desc="Kill 10 players 6+ levels above you",  pts=200, type="counter", key="underdog_kills",     goal=10 },
    { id=93, cat="UNDERDOG",   name="Lowbie Protector",  desc="Kill 5 players who are 10+ levels above a guildmate", pts=150, type="counter", key="protector_kills", goal=5 },

    -- DEDICATION
    { id=120,cat="DEDICATION", name="Dedicated",         desc="Log in 7 different days with kills",   pts=50,  type="counter", key="days_with_kills",    goal=7 },
    { id=121,cat="DEDICATION", name="Committed",         desc="Log in 30 different days with kills",  pts=150, type="counter", key="days_with_kills",    goal=30 },
    { id=122,cat="DEDICATION", name="No Life",           desc="Log in 100 different days with kills", pts=500, type="counter", key="days_with_kills",    goal=100 },
    { id=123,cat="DEDICATION", name="Completionist",     desc="Earn 25 achievements",                 pts=200, type="counter", key="total_achievements", goal=25 },
    { id=124,cat="DEDICATION", name="True Deadpool",     desc="Earn 50 achievements",                 pts=500, type="counter", key="total_achievements", goal=50 },
}

-- Category display order
local CATEGORY_ORDER = { "MILESTONES", "KILL COUNT", "STREAKS", "CLASS", "BOUNTY", "KOS", "ZONES", "REVENGE", "QUESTS", "UNDERDOG", "DEDICATION" }

-- Build lookup by id
local ACH_BY_ID = {}
for _, a in ipairs(ACHIEVEMENT_LIST) do ACH_BY_ID[a.id] = a end

----------------------------------------------------------------------
-- Data accessors (account-wide DeadpoolDB)
----------------------------------------------------------------------
function Achievements:GetData()
    if not DeadpoolDB then DeadpoolDB = {} end
    if not DeadpoolDB.achievements then
        DeadpoolDB.achievements = { earned = {}, counters = {}, sets = {} }
    end
    return DeadpoolDB.achievements
end

function Achievements:GetCounter(key)
    return self:GetData().counters[key] or 0
end

function Achievements:IncrementCounter(key, amount)
    local data = self:GetData()
    data.counters[key] = (data.counters[key] or 0) + (amount or 1)
end

function Achievements:SetCounter(key, value)
    self:GetData().counters[key] = value
end

function Achievements:AddToSet(setKey, value)
    local data = self:GetData()
    if not data.sets[setKey] then data.sets[setKey] = {} end
    data.sets[setKey][value] = true
end

function Achievements:GetSetSize(setKey)
    local s = self:GetData().sets[setKey]
    if not s then return 0 end
    local c = 0; for _ in pairs(s) do c = c + 1 end
    return c
end

function Achievements:IsEarned(achId)
    return self:GetData().earned[achId] ~= nil
end

----------------------------------------------------------------------
-- Get progress for an achievement
----------------------------------------------------------------------
function Achievements:GetProgress(ach)
    if ach.type == "score" then
        local score = Deadpool:GetOrCreateScore(Deadpool:GetPlayerFullName())
        return math.min(score[ach.key] or 0, ach.goal)
    elseif ach.type == "counter" then
        -- Special computed counters
        if ach.key == "best_class_kills" then
            return math.min(self:GetBestClassKills(), ach.goal)
        elseif ach.key == "min_class_kills" then
            return math.min(self:GetMinClassKills(), ach.goal)
        end
        return math.min(self:GetCounter(ach.key), ach.goal)
    elseif ach.type == "set_size" then
        return math.min(self:GetSetSize(ach.key), ach.goal)
    end
    return 0
end

function Achievements:GetBestClassKills()
    local best = 0
    for _, class in ipairs({"WARRIOR","PALADIN","HUNTER","ROGUE","PRIEST","SHAMAN","MAGE","WARLOCK","DRUID"}) do
        local kills = self:GetCounter("kills_" .. class)
        if kills > best then best = kills end
    end
    return best
end

function Achievements:GetMinClassKills()
    local min = 999999
    for _, class in ipairs({"WARRIOR","PALADIN","HUNTER","ROGUE","PRIEST","SHAMAN","MAGE","WARLOCK","DRUID"}) do
        local kills = self:GetCounter("kills_" .. class)
        if kills < min then min = kills end
    end
    return min == 999999 and 0 or min
end

----------------------------------------------------------------------
-- Check and award achievements
----------------------------------------------------------------------
function Achievements:CheckAll()
    for _, ach in ipairs(ACHIEVEMENT_LIST) do
        if not self:IsEarned(ach.id) then
            local progress = self:GetProgress(ach)
            if progress >= ach.goal then
                self:Award(ach)
            end
        end
    end
end

function Achievements:Award(ach)
    if self:IsEarned(ach.id) then return end

    local data = self:GetData()
    data.earned[ach.id] = time()

    -- Add achievement points to scoreboard
    local myName = Deadpool:GetPlayerFullName()
    local score = Deadpool:GetOrCreateScore(myName)
    score.totalPoints = (score.totalPoints or 0) + ach.pts

    -- Track total achievements earned for meta-achievements
    self:SetCounter("total_achievements", self:GetEarnedCount())

    Deadpool:Print(Deadpool.colors.gold .. "ACHIEVEMENT UNLOCKED!|r " ..
        Deadpool.colors.yellow .. ach.name .. "|r — " .. ach.desc ..
        " (+" .. ach.pts .. " pts)")
    Deadpool:PlaySoundByKey("coin")

    -- Backup after every award
    self:Backup()

    if Deadpool.RefreshUI then Deadpool:RefreshUI() end
end

----------------------------------------------------------------------
-- Kill hook: increment counters and check achievements
----------------------------------------------------------------------
function Achievements:OnKill(killerFullName, victimFullName, victimClass, victimRace, victimLevel, zone, killType)
    if killerFullName ~= Deadpool:GetPlayerFullName() then return end

    -- Class kill counter
    if victimClass and victimClass ~= "" then
        self:IncrementCounter("kills_" .. victimClass:upper())
        self:AddToSet("classes_killed", victimClass:upper())
    end

    -- Race kill counter
    if victimRace and victimRace ~= "" then
        self:IncrementCounter("kills_" .. victimRace)
    end

    -- Zone tracking
    if zone and zone ~= "" then
        self:AddToSet("zones_killed_in", zone)
        self:IncrementCounter("kills_z_" .. zone)
        -- Outland zones for nested achievement
        local outlandZones = {
            ["Hellfire Peninsula"]=true, ["Zangarmarsh"]=true, ["Terokkar Forest"]=true,
            ["Nagrand"]=true, ["Blade's Edge Mountains"]=true, ["Shadowmoon Valley"]=true,
            ["Netherstorm"]=true,
        }
        if outlandZones[zone] then
            self:AddToSet("outland_zones_killed", zone)
        end
        -- Continent tracking
        local cont = outlandZones[zone] and "Outland" or "Azeroth"
        self:AddToSet("continents_killed", cont)
    end

    -- KOS kill: track unique KOS targets killed
    if Deadpool:IsKOS(victimFullName) then
        self:AddToSet("unique_kos_killed", victimFullName)
    end

    -- Revenge kill: did this victim ever kill us?
    local enemy = Deadpool.db.enemySheet[victimFullName]
    if enemy and (enemy.timesKilledUs or 0) > 0 then
        self:IncrementCounter("revenge_kills")
    end

    -- Grudge match: track max kills vs any single enemy
    if enemy then
        local weKilled = (enemy.timesWeKilledThem or 0)
        local current = self:GetCounter("grudge_kill_max")
        if weKilled > current then
            self:SetCounter("grudge_kill_max", weKilled)
        end
    end

    -- Underdog kills (level difference)
    local myLevel = UnitLevel("player") or 0
    if victimLevel and victimLevel > 0 and myLevel > 0 then
        local diff = victimLevel - myLevel
        if diff >= 10 then
            self:IncrementCounter("goliath_kills")
            self:IncrementCounter("underdog_kills")
        elseif diff >= 6 then
            self:IncrementCounter("underdog_kills")
        end
    end

    -- Track unique days with kills
    local dayKey = "day_" .. math.floor(time() / 86400)
    if not self:GetData().sets["kill_days"] or not self:GetData().sets["kill_days"][dayKey] then
        self:AddToSet("kill_days", dayKey)
        self:SetCounter("days_with_kills", self:GetSetSize("kill_days"))
    end

    -- Check all achievements after updating counters
    self:CheckAll()
end

----------------------------------------------------------------------
-- Quest completion hooks
----------------------------------------------------------------------
function Achievements:OnQuestComplete(questType)
    if questType == "daily" then
        self:IncrementCounter("quests_daily")
    elseif questType == "weekly" then
        self:IncrementCounter("quests_weekly")
    end
    self:CheckAll()
end

function Achievements:OnAllDailiesComplete()
    self:IncrementCounter("all_dailies_days")
    self:CheckAll()
end

----------------------------------------------------------------------
-- Bounty/KOS hooks (called from BountyManager)
----------------------------------------------------------------------
function Achievements:OnBountyPlaced()
    self:IncrementCounter("bounties_placed")
    self:CheckAll()
end

function Achievements:OnBountyCompleted()
    self:IncrementCounter("bounties_completed")
    self:CheckAll()
end

function Achievements:OnKOSAdded()
    self:IncrementCounter("kos_added")
    self:CheckAll()
end

----------------------------------------------------------------------
-- Backup / Restore
----------------------------------------------------------------------
function Achievements:Backup()
    local data = self:GetData()
    local backup = { earned = {}, counters = {}, sets = {}, backedUpAt = time() }

    for k, v in pairs(data.earned) do backup.earned[k] = v end
    for k, v in pairs(data.counters) do backup.counters[k] = v end
    for k, v in pairs(data.sets) do
        backup.sets[k] = {}
        for sk, sv in pairs(v) do backup.sets[k][sk] = sv end
    end

    DeadpoolDB.achievementBackup = backup
end

function Achievements:Restore()
    if not DeadpoolDB or not DeadpoolDB.achievementBackup then
        Deadpool:Print(Deadpool.colors.red .. "No achievement backup found.|r")
        return false
    end

    local backup = DeadpoolDB.achievementBackup
    local data = self:GetData()

    data.earned = {}
    for k, v in pairs(backup.earned or {}) do data.earned[k] = v end
    data.counters = {}
    for k, v in pairs(backup.counters or {}) do data.counters[k] = v end
    data.sets = {}
    for k, v in pairs(backup.sets or {}) do
        data.sets[k] = {}
        for sk, sv in pairs(v) do data.sets[k][sk] = sv end
    end

    local ago = backup.backedUpAt and Deadpool:TimeAgo(backup.backedUpAt) or "unknown"
    Deadpool:Print(Deadpool.colors.green .. "Achievements restored from backup (" .. ago .. ").|r")
    if Deadpool.RefreshUI then Deadpool:RefreshUI() end
    return true
end

----------------------------------------------------------------------
-- Accessors for UI
----------------------------------------------------------------------
function Achievements:GetAllForDisplay()
    local result = {}
    for _, cat in ipairs(CATEGORY_ORDER) do
        result[#result+1] = { isHeader = true, category = cat }
        for _, ach in ipairs(ACHIEVEMENT_LIST) do
            if ach.cat == cat then
                local progress = self:GetProgress(ach)
                local earned = self:IsEarned(ach.id)
                result[#result+1] = {
                    id = ach.id, name = ach.name, desc = ach.desc,
                    category = ach.cat, points = ach.pts, goal = ach.goal,
                    progress = progress, earned = earned,
                    earnedAt = earned and self:GetData().earned[ach.id] or nil,
                }
            end
        end
    end
    return result
end

function Achievements:GetTotalPoints()
    local total = 0
    for _, ach in ipairs(ACHIEVEMENT_LIST) do
        if self:IsEarned(ach.id) then total = total + ach.pts end
    end
    return total
end

function Achievements:GetEarnedCount()
    local c = 0
    for _ in pairs(self:GetData().earned) do c = c + 1 end
    return c
end

function Achievements:GetTotalCount()
    return #ACHIEVEMENT_LIST
end

----------------------------------------------------------------------
-- Init
----------------------------------------------------------------------
function Achievements:Init()
    self._initialized = true

    -- Ensure account-wide storage exists
    if not DeadpoolDB then DeadpoolDB = {} end
    if not DeadpoolDB.achievements then
        DeadpoolDB.achievements = { earned = {}, counters = {}, sets = {} }
    end
    local data = DeadpoolDB.achievements
    if not data.earned then data.earned = {} end
    if not data.counters then data.counters = {} end
    if not data.sets then data.sets = {} end

    -- Initial backup if none exists
    if not DeadpoolDB.achievementBackup then
        self:Backup()
    end

    -- Check achievements on load (catch up on any progress made)
    C_Timer.After(5, function()
        Achievements:CheckAll()
    end)

    -- Hook chat hyperlinks for achievement link clicks
    self:HookChatLinks()
end

----------------------------------------------------------------------
-- Achievement Links: shift-click to insert, click in chat to preview
-- Uses garrmission: prefix so WoW passes unknown subtypes to hooks
----------------------------------------------------------------------
local ACH_LINK_PREFIX = "garrmission"
local ACH_LINK_SUBTYPE = "dpach"

-- Category icons (reused from UI.lua, kept here for popup)
local ACH_ICONS = {
    MILESTONES     = "Interface\\Icons\\Ability_Creature_Cursed_03",
    ["KILL COUNT"] = "Interface\\Icons\\INV_Axe_03",
    STREAKS        = "Interface\\Icons\\Spell_Fire_Incinerate",
    CLASS          = "Interface\\Icons\\Spell_Nature_WispSplode",
    BOUNTY         = "Interface\\Icons\\INV_Misc_Coin_02",
    KOS            = "Interface\\Icons\\Ability_Rogue_MasterOfSubtlety",
    ZONES          = "Interface\\Icons\\INV_Misc_Map_01",
    REVENGE        = "Interface\\Icons\\Ability_Warrior_Revenge",
    QUESTS         = "Interface\\Icons\\INV_Scroll_03",
    UNDERDOG       = "Interface\\Icons\\Ability_Warrior_StrengthOfArms",
}

function Achievements:GetLink(achId)
    local ach = ACH_BY_ID[achId]
    if not ach then return nil end
    local earned = self:IsEarned(achId)
    -- Use plain colored text with brackets — WoW blocks custom hyperlink types from chat
    if earned then
        return Deadpool.colors.gold .. "[" .. ach.name .. "]|r"
    else
        return "|cFF888888[" .. ach.name .. "]|r"
    end
end

function Achievements:InsertLink(achId)
    local link = self:GetLink(achId)
    if not link then return end

    -- Insert into active chat edit box
    local editBox = ChatFrame1EditBox or (LAST_ACTIVE_CHAT_EDIT_BOX and _G[LAST_ACTIVE_CHAT_EDIT_BOX])
    if not editBox then
        -- Try to find any active edit box
        for i = 1, 10 do
            local box = _G["ChatFrame" .. i .. "EditBox"]
            if box and box:IsVisible() then editBox = box; break end
        end
    end

    if editBox then
        if not editBox:IsVisible() then
            ChatFrame_OpenChat("")
            editBox = ChatFrame1EditBox
        end
        editBox:Insert(link)
    else
        -- Fallback: just open chat with the link
        ChatFrame_OpenChat(link)
    end
end

function Achievements:HookChatLinks()
    -- Hook hyperlink clicks in chat frames
    local origSetItemRef = SetItemRef
    if not origSetItemRef then return end  -- safety
    SetItemRef = function(link, text, button, chatFrame)
        -- Parse our custom achievement links: garrmission:dpach:ID:playerName:earnedFlag
        local achIdStr, playerName, earnFlag = link:match(
            "^garrmission:dpach:(%d+):([^:]+):([01])$"
        )

        if achIdStr then
            local achId = tonumber(achIdStr)
            if achId then
                Achievements:ShowPopup(achId, playerName, earnFlag == "1")
                return
            end
        end

        -- Not ours, pass through to original handler
        return origSetItemRef(link, text, button, chatFrame)
    end
end

----------------------------------------------------------------------
-- Achievement Popup: themed frame mimicking retail achievement toast
----------------------------------------------------------------------
local popupFrame = nil

function Achievements:ShowPopup(achId, linkedPlayer, linkedEarned)
    local ach = ACH_BY_ID[achId]
    if not ach then return end

    local TM = Deadpool.modules.Theme
    local t = TM.active
    local accentHex = TM:AccentHex()

    local isLinked = linkedPlayer ~= nil
    local myEarned = self:IsEarned(achId)
    local myProgress = self:GetProgress(ach)
    local earnedAt = self:GetData().earned[achId]
    local showEarned = isLinked and linkedEarned or myEarned

    -- Destroy old popup and rebuild fresh
    if popupFrame then
        popupFrame:Hide()
        popupFrame:SetParent(nil)
        popupFrame = nil
    end

    popupFrame = CreateFrame("Frame", "DeadpoolAchPopup", UIParent, "BackdropTemplate")
    popupFrame:SetSize(380, 240)
    popupFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
    popupFrame:SetFrameStrata("DIALOG")
    popupFrame:SetMovable(true)
    popupFrame:EnableMouse(true)
    popupFrame:RegisterForDrag("LeftButton")
    popupFrame:SetScript("OnDragStart", popupFrame.StartMoving)
    popupFrame:SetScript("OnDragStop", popupFrame.StopMovingOrSizing)
    popupFrame:SetClampedToScreen(true)
    popupFrame:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then self:Hide() end
    end)
    tinsert(UISpecialFrames, "DeadpoolAchPopup")
    popupFrame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 2,
    })

    if showEarned then
        popupFrame:SetBackdropColor(t.bg[1], t.bg[2] + 0.02, t.bg[3], 0.96)
        popupFrame:SetBackdropBorderColor(t.gold[1], t.gold[2], t.gold[3], 0.8)
    else
        popupFrame:SetBackdropColor(t.bg[1], t.bg[2], t.bg[3], 0.96)
        popupFrame:SetBackdropBorderColor(t.border[1], t.border[2], t.border[3], 0.8)
    end

    -- Top accent bar
    local topBar = popupFrame:CreateTexture(nil, "ARTWORK")
    topBar:SetHeight(3); topBar:SetPoint("TOPLEFT", 2, -2); topBar:SetPoint("TOPRIGHT", -2, -2)
    if showEarned then
        topBar:SetColorTexture(t.gold[1], t.gold[2], t.gold[3], 0.9)
    else
        topBar:SetColorTexture(t.accent[1], t.accent[2], t.accent[3], 0.6)
    end

    -- Close button
    local closeBtn = CreateFrame("Button", nil, popupFrame)
    closeBtn:SetSize(20, 20); closeBtn:SetPoint("TOPRIGHT", -4, -4)
    closeBtn:Show()
    local xText = closeBtn:CreateFontString(nil, "OVERLAY")
    xText:SetFont("Fonts\\FRIZQT__.TTF", 14, "OUTLINE"); xText:SetPoint("CENTER")
    xText:SetText("X"); xText:SetTextColor(0.8, 0.2, 0.2)
    closeBtn:SetScript("OnClick", function() popupFrame:Hide() end)
    closeBtn:SetScript("OnEnter", function() xText:SetTextColor(1, 0.4, 0.4) end)
    closeBtn:SetScript("OnLeave", function() xText:SetTextColor(0.8, 0.2, 0.2) end)

    -- Header: "ACHIEVEMENT EARNED" or "ACHIEVEMENT"
    local headerText = popupFrame:CreateFontString(nil, "OVERLAY")
    headerText:SetFont(TM:GetFont(10, "OUTLINE")); headerText:SetPoint("TOP", 0, -10)
    if showEarned then
        headerText:SetText(Deadpool.colors.gold .. "ACHIEVEMENT EARNED|r")
    else
        headerText:SetText(accentHex .. "ACHIEVEMENT|r")
    end
    headerText:Show()

    -- Icon (large, centered)
    local iconBg = CreateFrame("Frame", nil, popupFrame, "BackdropTemplate")
    iconBg:SetSize(54, 54); iconBg:SetPoint("TOP", 0, -28)
    iconBg:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1,
    })
    iconBg:Show()

    if showEarned then
        iconBg:SetBackdropColor(0.2, 0.15, 0, 0.8)
        iconBg:SetBackdropBorderColor(t.gold[1], t.gold[2], t.gold[3], 0.8)
    else
        iconBg:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
        iconBg:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.5)
    end

    local icon = iconBg:CreateTexture(nil, "ARTWORK")
    icon:SetSize(48, 48); icon:SetPoint("CENTER")
    icon:SetTexture(ACH_ICONS[ach.cat] or "Interface\\Icons\\INV_Misc_QuestionMark")
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    if showEarned then
        icon:SetDesaturated(false); icon:SetAlpha(1)
        -- Earned checkmark
        local check = iconBg:CreateTexture(nil, "OVERLAY")
        check:SetSize(20, 20); check:SetPoint("BOTTOMRIGHT", iconBg, "BOTTOMRIGHT", 4, -4)
        check:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
    else
        icon:SetDesaturated(true); icon:SetAlpha(0.5)
    end

    -- Achievement name
    local nameText = popupFrame:CreateFontString(nil, "OVERLAY")
    nameText:SetFont(TM:GetFont(16, "OUTLINE")); nameText:SetPoint("TOP", iconBg, "BOTTOM", 0, -8)
    nameText:Show()
    if showEarned then
        nameText:SetText(Deadpool.colors.gold .. ach.name .. "|r")
    else
        nameText:SetText("|cFFDDDDDD" .. ach.name .. "|r")
    end

    -- Description
    local descText = popupFrame:CreateFontString(nil, "OVERLAY")
    descText:SetFont(TM:GetFont(11, "")); descText:SetPoint("TOP", nameText, "BOTTOM", 0, -6)
    descText:SetWidth(320); descText:SetJustifyH("CENTER")
    descText:SetTextColor(t.textDim[1], t.textDim[2], t.textDim[3])
    descText:SetText(ach.desc)
    descText:Show()

    -- Points
    local ptsText = popupFrame:CreateFontString(nil, "OVERLAY")
    ptsText:SetFont(TM:GetFont(12, "OUTLINE")); ptsText:SetPoint("TOP", descText, "BOTTOM", 0, -8)
    ptsText:Show()
    if showEarned then
        ptsText:SetText(Deadpool.colors.gold .. ach.pts .. " Achievement Points|r")
    else
        ptsText:SetText("|cFF888888" .. ach.pts .. " Achievement Points|r")
    end

    -- Progress bar
    local barBg = CreateFrame("Frame", nil, popupFrame, "BackdropTemplate")
    barBg:SetSize(280, 14); barBg:SetPoint("TOP", ptsText, "BOTTOM", 0, -10)
    barBg:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
    barBg:SetBackdropColor(t.barBg[1], t.barBg[2], t.barBg[3], 0.8)
    barBg:Show()

    local barFill = barBg:CreateTexture(nil, "ARTWORK")
    barFill:SetPoint("TOPLEFT"); barFill:SetPoint("BOTTOMLEFT")
    barFill:SetTexture("Interface\\Buttons\\WHITE8x8")
    local pct = ach.goal > 0 and math.min(myProgress / ach.goal, 1) or 0
    barFill:SetWidth(math.max(1, 280 * pct))
    if showEarned then
        barFill:SetVertexColor(t.gold[1], t.gold[2], t.gold[3], 1)
    else
        barFill:SetVertexColor(t.accent[1], t.accent[2], t.accent[3], 0.8)
    end

    local barLabel = barBg:CreateFontString(nil, "OVERLAY")
    barLabel:SetFont(TM:GetFont(10, "OUTLINE")); barLabel:SetPoint("CENTER")
    barLabel:SetText(myProgress .. " / " .. ach.goal)
    barLabel:SetShadowOffset(1, -1); barLabel:SetShadowColor(0, 0, 0, 1)

    -- Earned date or linked player info
    local footerText = popupFrame:CreateFontString(nil, "OVERLAY")
    footerText:SetFont(TM:GetFont(10, "")); footerText:SetPoint("TOP", barBg, "BOTTOM", 0, -8)
    footerText:SetJustifyH("CENTER")
    footerText:Show()

    if isLinked and linkedPlayer then
        local shortPlayer = linkedPlayer:match("^(.-)%-") or linkedPlayer
        if linkedEarned then
            footerText:SetText(Deadpool.colors.cyan .. shortPlayer .. "|r " ..
                Deadpool.colors.green .. "has earned this achievement|r")
        else
            footerText:SetText(Deadpool.colors.cyan .. shortPlayer .. "|r " ..
                Deadpool.colors.grey .. "has not earned this yet|r")
        end
    elseif myEarned and earnedAt then
        footerText:SetText(Deadpool.colors.green .. "Earned on " ..
            Deadpool:FormatDate(earnedAt) .. "|r")
    else
        footerText:SetText(Deadpool.colors.grey .. "Not yet earned|r")
    end

    -- Category label (bottom)
    local catText = popupFrame:CreateFontString(nil, "OVERLAY")
    catText:SetFont(TM:GetFont(9, "")); catText:SetPoint("BOTTOM", popupFrame, "BOTTOM", 0, 8)
    catText:SetText(accentHex .. ach.cat .. "|r")
    catText:Show()

    popupFrame:Show()
end
