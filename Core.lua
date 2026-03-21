----------------------------------------------------------------------
-- Deadpool - Kill on Sight Bounty Tracker & World PvP Scoreboard
-- Core.lua - Namespace, event system, utilities, slash commands
----------------------------------------------------------------------

Deadpool = {}
Deadpool.version = "1.0.0"
Deadpool.prefix = "DEADPOOL"
Deadpool.modules = {}

-- Color palette
Deadpool.colors = {
    red       = "|cFFFF0000",
    green     = "|cFF00FF00",
    yellow    = "|cFFFFFF00",
    orange    = "|cFFFF8800",
    white     = "|cFFFFFFFF",
    grey      = "|cFF888888",
    gold      = "|cFFFFD700",
    deadpool  = "|cFFCC0000",
    header    = "|cFFFF4444",
    cyan      = "|cFF00FFFF",
}

Deadpool.classColors = {
    WARRIOR   = "|cFFC79C6E",
    PALADIN   = "|cFFF58CBA",
    HUNTER    = "|cFFABD473",
    ROGUE     = "|cFFFFF569",
    PRIEST    = "|cFFFFFFFF",
    SHAMAN    = "|cFF0070DE",
    MAGE      = "|cFF69CCF0",
    WARLOCK   = "|cFF9482C9",
    DRUID     = "|cFFFF7D0A",
}

----------------------------------------------------------------------
-- Event system
----------------------------------------------------------------------
local eventFrame = CreateFrame("Frame", "DeadpoolEventFrame", UIParent)
local eventHandlers = {}

function Deadpool:RegisterEvent(event, handler)
    eventFrame:RegisterEvent(event)
    if not eventHandlers[event] then
        eventHandlers[event] = {}
    end
    table.insert(eventHandlers[event], handler)
end

function Deadpool:UnregisterEvent(event)
    eventFrame:UnregisterEvent(event)
    eventHandlers[event] = nil
end

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if eventHandlers[event] then
        for _, handler in ipairs(eventHandlers[event]) do
            handler(event, ...)
        end
    end
end)

----------------------------------------------------------------------
-- Module system
----------------------------------------------------------------------
function Deadpool:RegisterModule(name, mod)
    self.modules[name] = mod
    mod.addon = self
end

----------------------------------------------------------------------
-- Utility functions
----------------------------------------------------------------------
function Deadpool:Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage(self.colors.deadpool .. "[Deadpool]|r " .. tostring(msg))
end

function Deadpool:Debug(msg)
    if self.db and self.db.settings and self.db.settings.debug then
        DEFAULT_CHAT_FRAME:AddMessage(self.colors.grey .. "[DP Debug]|r " .. tostring(msg))
    end
end

function Deadpool:GetPlayerName()
    return UnitName("player")
end

function Deadpool:GetPlayerFullName()
    local name = UnitName("player")
    local realm = GetRealmName()
    return name .. "-" .. realm
end

function Deadpool:GetUnitFullName(unit)
    local name, realm = UnitName(unit)
    if not name then return nil end
    realm = (realm and realm ~= "") and realm or GetRealmName()
    return name .. "-" .. realm, name, realm
end

function Deadpool:NormalizeName(input)
    -- Accept "Name", "Name-Realm", or just a name; always return "Name-Realm"
    if not input or input == "" then return nil end
    input = input:gsub("^%s+", ""):gsub("%s+$", "")
    if input:find("-") then
        local n, r = input:match("^(.-)%-(.+)$")
        if n and r then
            return n:sub(1,1):upper() .. n:sub(2):lower() .. "-" .. r
        end
    end
    -- No realm given, use player's realm
    local name = input:sub(1,1):upper() .. input:sub(2):lower()
    return name .. "-" .. GetRealmName()
end

function Deadpool:ShortName(fullName)
    if not fullName then return "?" end
    return fullName:match("^(.-)%-") or fullName
end

function Deadpool:FormatGold(gold)
    if type(gold) ~= "number" or gold <= 0 then return "0g" end
    return gold .. self.colors.gold .. "g|r"
end

function Deadpool:GetZone()
    return GetZoneText() or "Unknown"
end

function Deadpool:GetSubZone()
    return GetSubZoneText() or ""
end

function Deadpool:TimeAgo(timestamp)
    if not timestamp or timestamp == 0 then return "never" end
    local diff = time() - timestamp
    if diff < 60 then return diff .. "s ago"
    elseif diff < 3600 then return math.floor(diff / 60) .. "m ago"
    elseif diff < 86400 then return math.floor(diff / 3600) .. "h ago"
    else return math.floor(diff / 86400) .. "d ago" end
end

function Deadpool:FormatDate(timestamp)
    if not timestamp or timestamp == 0 then return "N/A" end
    return date("%m/%d %H:%M", timestamp)
end

function Deadpool:ClassColor(class, text)
    if class and self.classColors[class:upper()] then
        return self.classColors[class:upper()] .. text .. "|r"
    end
    return text
end

function Deadpool:TableCount(t)
    if not t then return 0 end
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count
end

function Deadpool:GetGuildRank()
    if not IsInGuild() then return nil, nil end
    local _, _, rankIndex = GetGuildInfo("player")
    return rankIndex or 99
end

function Deadpool:IsOfficer()
    local rank = self:GetGuildRank()
    if not rank then return false end
    return rank <= (self.db.settings.officerRank or 1)
end

----------------------------------------------------------------------
-- Slash commands
----------------------------------------------------------------------
SLASH_DEADPOOL1 = "/deadpool"
SLASH_DEADPOOL2 = "/dp"
SlashCmdList["DEADPOOL"] = function(msg)
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()
    rest = rest or ""

    if cmd == "" or cmd == "show" or cmd == "toggle" then
        Deadpool:ToggleUI()
    elseif cmd == "add" or cmd == "kos" then
        if rest ~= "" then
            local name, reason = rest:match("^(%S+)%s*(.-)$")
            Deadpool:AddToKOS(name, reason)
        elseif UnitExists("target") and UnitIsPlayer("target") and UnitIsEnemy("player", "target") then
            local fullName = Deadpool:GetUnitFullName("target")
            if fullName then
                Deadpool:AddToKOS(fullName, "")
            end
        else
            Deadpool:Print("Usage: /dp add <PlayerName> [reason] — or target an enemy player")
        end
    elseif cmd == "remove" or cmd == "rem" then
        if rest ~= "" then
            Deadpool:RemoveFromKOS(rest)
        else
            Deadpool:Print("Usage: /dp remove <PlayerName>")
        end
    elseif cmd == "bounty" then
        local name, gold, maxKills = rest:match("^(%S+)%s+(%d+)%s*(%d*)$")
        if name and gold then
            maxKills = tonumber(maxKills) or 10
            Deadpool:PlaceBounty(name, tonumber(gold), maxKills)
        else
            Deadpool:Print("Usage: /dp bounty <PlayerName> <gold> [maxKills]")
        end
    elseif cmd == "score" or cmd == "leaderboard" or cmd == "lb" then
        Deadpool:ShowTab("scoreboard")
    elseif cmd == "list" then
        Deadpool:PrintKOSList()
    elseif cmd == "log" then
        Deadpool:ShowTab("killlog")
    elseif cmd == "sync" then
        Deadpool:RequestSync()
    elseif cmd == "help" then
        Deadpool:PrintHelp()
    elseif cmd == "diag" then
        Deadpool:Print("=== DIAGNOSTIC ===")
        Deadpool:Print("KOS entries: " .. Deadpool:TableCount(Deadpool.db.kosList))
        Deadpool:Print("Bounties: " .. Deadpool:TableCount(Deadpool.db.bounties))
        Deadpool:Print("Scoreboard: " .. Deadpool:TableCount(Deadpool.db.scoreboard))
        Deadpool:Print("Enemies: " .. Deadpool:TableCount(Deadpool.db.enemySheet))
        Deadpool:Print("Kill Log: " .. #Deadpool.db.killLog)
        Deadpool:Print("Death Log: " .. #(Deadpool.db.deathLog or {}))
        Deadpool:Print("Placeholder loaded: " .. tostring(Deadpool.db._placeholderLoaded))
        Deadpool:Print("Placeholder version: " .. tostring(Deadpool.db._placeholderVersion))
        for name, _ in pairs(Deadpool.db.kosList) do
            Deadpool:Print("First KOS: " .. name)
            break
        end
        -- UI diagnostics
        local ui = Deadpool.modules.UI
        if ui then
            local ca = rawget(ui, "_contentArea")
            Deadpool:Print("--- UI STATE ---")
            -- Try to access contentArea through the render functions
            -- Call GetKOSSorted to verify data access works
            local sorted = Deadpool:GetKOSSorted("totalKills", false)
            Deadpool:Print("GetKOSSorted returned: " .. #sorted .. " entries")
            if sorted[1] then
                Deadpool:Print("First sorted: " .. (sorted[1].name or "?") .. " key=" .. (sorted[1]._key or "?"))
            end
        end
    elseif cmd == "debug" then
        Deadpool.db.settings.debug = not Deadpool.db.settings.debug
        Deadpool:Print("Debug mode: " .. (Deadpool.db.settings.debug and "ON" or "OFF"))
    elseif cmd == "demo" then
        -- Force wipe and regenerate demo data
        Deadpool.db._placeholderLoaded = nil
        Deadpool.db._placeholderVersion = nil
        Deadpool.db.kosList = {}
        Deadpool.db.bounties = {}
        Deadpool.db.scoreboard = {}
        Deadpool.db.enemySheet = {}
        Deadpool.db.killLog = {}
        Deadpool.db.deathLog = {}
        Deadpool:LoadPlaceholderData()
        Deadpool:Print(Deadpool.colors.green .. "Demo data regenerated:|r")
        Deadpool:Print("  KOS: " .. Deadpool:TableCount(Deadpool.db.kosList))
        Deadpool:Print("  Bounties: " .. Deadpool:TableCount(Deadpool.db.bounties))
        Deadpool:Print("  Scoreboard: " .. Deadpool:TableCount(Deadpool.db.scoreboard))
        Deadpool:Print("  Enemies: " .. Deadpool:TableCount(Deadpool.db.enemySheet))
        Deadpool:Print("  Kill Log: " .. #Deadpool.db.killLog)
        Deadpool:Print("  Death Log: " .. #Deadpool.db.deathLog)
        if Deadpool.RefreshUI then Deadpool:RefreshUI() end
    elseif cmd == "wipe" then
        Deadpool.db._placeholderLoaded = nil
        Deadpool.db._placeholderVersion = nil
        Deadpool.db.kosList = {}
        Deadpool.db.bounties = {}
        Deadpool.db.scoreboard = {}
        Deadpool.db.enemySheet = {}
        Deadpool.db.killLog = {}
        Deadpool.db.deathLog = {}
        Deadpool:Print("All data wiped.")
        if Deadpool.RefreshUI then Deadpool:RefreshUI() end
    else
        Deadpool:Print("Unknown command. Type " .. Deadpool.colors.yellow .. "/dp help|r for commands.")
    end
end

function Deadpool:PrintHelp()
    self:Print(self.colors.header .. "=== The Merc's Handbook ===|r")
    self:Print("/dp " .. self.colors.yellow .. "show|r — Toggle the Deadpool window")
    self:Print("/dp " .. self.colors.yellow .. "add <name> [reason]|r — Add to Kill on Sight (or target enemy)")
    self:Print("/dp " .. self.colors.yellow .. "remove <name>|r — Remove from KOS")
    self:Print("/dp " .. self.colors.yellow .. "bounty <name> <gold> [maxKills]|r — Place a bounty contract")
    self:Print("/dp " .. self.colors.yellow .. "list|r — Print KOS list to chat")
    self:Print("/dp " .. self.colors.yellow .. "score|r — Show scoreboard")
    self:Print("/dp " .. self.colors.yellow .. "log|r — Show kill log")
    self:Print("/dp " .. self.colors.yellow .. "sync|r — Force guild sync")
    self:Print("/dp " .. self.colors.yellow .. "help|r — This help")
end

function Deadpool:PrintKOSList()
    local count = self:TableCount(self.db.kosList)
    if count == 0 then
        self:Print("The list is empty. How boring.")
        return
    end
    self:Print(self.colors.header .. "=== Kill on Sight (" .. count .. ") ===|r")
    for fullName, entry in pairs(self.db.kosList) do
        local line = "  " .. self:ClassColor(entry.class or "", self:ShortName(fullName))
        if entry.totalKills > 0 then
            line = line .. " — " .. self.colors.green .. entry.totalKills .. " kills|r"
        end
        if entry.reason and entry.reason ~= "" then
            line = line .. " — " .. self.colors.grey .. entry.reason .. "|r"
        end
        self:Print(line)
    end
end

----------------------------------------------------------------------
-- Initialization
----------------------------------------------------------------------
function Deadpool:Init()
    -- Register addon message prefix for guild sync
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        C_ChatInfo.RegisterAddonMessagePrefix(self.prefix)
    end

    -- Initialize modules in dependency order (Theme before UI)
    local initOrder = { "Theme", "BountyManager", "KillTracker", "Sync", "UI", "Alerts" }
    for _, name in ipairs(initOrder) do
        local mod = self.modules[name]
        if mod and mod.Init then
            mod:Init()
        end
    end
    -- Init any remaining modules not in the explicit list
    for name, mod in pairs(self.modules) do
        if mod.Init and not mod._initialized then
            mod:Init()
        end
    end

    self:Print(self.colors.yellow .. "v" .. self.version .. "|r loaded. " ..
        self.colors.grey .. "Type /dp to open the hit list.|r")

    -- Populate demo data for testing (remove before shipping)
    -- Force regenerate if old demo data version
    if self.db._placeholderVersion ~= 3 then
        self.db._placeholderLoaded = nil
        self.db.kosList = {}
        self.db.bounties = {}
        self.db.scoreboard = {}
        self.db.enemySheet = {}
        self.db.killLog = {}
        self.db.deathLog = {}
        self.db._placeholderVersion = 3
    end
    self:LoadPlaceholderData()
end

----------------------------------------------------------------------
-- Placeholder data for testing
----------------------------------------------------------------------
function Deadpool:LoadPlaceholderData()
    if self.db._placeholderLoaded then return end
    self.db._placeholderLoaded = true

    local realm = GetRealmName()
    local fakeEnemies = {
        { name = "Gankerface", class = "ROGUE", race = "Undead", level = 70, guild = "Wrath of Noobs" },
        { name = "Cheesewheel", class = "MAGE", race = "Undead", level = 70, guild = "Lowbie Terrorz" },
        { name = "Stabbymcstab", class = "ROGUE", race = "Orc", level = 68, guild = nil },
        { name = "Darkshdow", class = "WARLOCK", race = "Undead", level = 70, guild = "Shadow Council" },
        { name = "Griefdaddy", class = "WARRIOR", race = "Tauren", level = 70, guild = "Ganksquad" },
        { name = "Frostitute", class = "MAGE", race = "Troll", level = 69, guild = "Ice Cold Killaz" },
        { name = "Dotsndots", class = "WARLOCK", race = "Undead", level = 70, guild = "Shadow Council" },
        { name = "Healznope", class = "PRIEST", race = "Undead", level = 70, guild = "Wrath of Noobs" },
        { name = "Moonpunter", class = "DRUID", race = "Tauren", level = 70, guild = "Ganksquad" },
        { name = "Critsworth", class = "HUNTER", race = "Orc", level = 70, guild = "Lowbie Terrorz" },
        { name = "Shockadin", class = "PALADIN", race = "Blood Elf", level = 70, guild = "Wrath of Noobs" },
        { name = "Sneakypeek", class = "ROGUE", race = "Blood Elf", level = 67, guild = nil },
        { name = "Frostshawk", class = "SHAMAN", race = "Orc", level = 70, guild = "Ice Cold Killaz" },
        { name = "Felburner", class = "WARLOCK", race = "Blood Elf", level = 70, guild = "Shadow Council" },
    }

    local fakeGuildies = {
        { name = "Evildz" },
        { name = "Thunderbro" },
        { name = "Slapmage" },
        { name = "Holycrit" },
        { name = "Tankenstein" },
        { name = "Arrowstorm" },
        { name = "Dotweaver" },
        { name = "Critmachine" },
        { name = "Bubbleboy" },
        { name = "Wrathchild" },
    }

    local zones = {
        "Hellfire Peninsula", "Nagrand", "Terokkar Forest", "Zangarmarsh",
        "Blade's Edge Mountains", "Shadowmoon Valley", "Netherstorm",
        "Shattrath City", "Halaa", "Auchindoun",
    }
    local reasons = {
        "Ganked at summoning stone", "Camped our alt", "Killed quest NPCs",
        "Corpse camped 5x", "Wiped our dungeon group", "Killed lowbie guildies",
        "Stole our ore node", "Ganked at flight path", "General scumbaggery",
        "Jumped me at half HP", "Killed me during a quest turn-in",
    }

    -- KOS entries (all enemies)
    for _, e in ipairs(fakeEnemies) do
        local fullName = e.name .. "-" .. realm
        if not self.db.kosList[fullName] then
            self.db.kosList[fullName] = {
                name = e.name, realm = realm, class = e.class, race = e.race,
                level = e.level, guild = e.guild,
                addedBy = fakeGuildies[math.random(#fakeGuildies)].name .. "-" .. realm,
                addedDate = time() - math.random(86400, 604800),
                reason = reasons[math.random(#reasons)],
                totalKills = math.random(2, 25),
                lastKilledBy = fakeGuildies[math.random(#fakeGuildies)].name .. "-" .. realm,
                lastKilledTime = time() - math.random(600, 172800),
                lastSeenZone = zones[math.random(#zones)],
                lastSeenTime = time() - math.random(60, 7200),
            }
        end
    end

    -- Bounties: 5 active, 3 expired
    for i = 1, 8 do
        local e = fakeEnemies[i]
        local fullName = e.name .. "-" .. realm
        if not self.db.bounties[fullName] then
            local gold = math.random(1, 10) * 25
            local maxK = math.random(5, 20)
            local curK = math.random(0, maxK)
            local expired = (i > 5)
            if expired then curK = maxK end
            local claims = {}
            for c = 1, curK do
                table.insert(claims, {
                    killer = fakeGuildies[math.random(#fakeGuildies)].name .. "-" .. realm,
                    time = time() - math.random(600, 259200),
                    zone = zones[math.random(#zones)],
                })
            end
            self.db.bounties[fullName] = {
                target = fullName, bountyGold = gold,
                placedBy = fakeGuildies[math.random(#fakeGuildies)].name .. "-" .. realm,
                placedDate = time() - math.random(3600, 432000),
                maxKills = maxK, currentKills = curK,
                expired = expired,
                expiredReason = expired and "Completed" or nil,
                claims = claims,
            }
        end
    end

    -- Scoreboard: all guild members with varied stats
    for i, g in ipairs(fakeGuildies) do
        local fullName = g.name .. "-" .. realm
        if not self.db.scoreboard[fullName] then
            local kills = math.random(10, 150)
            local kosK = math.random(5, math.floor(kills * 0.4))
            local bountyK = math.random(0, math.floor(kills * 0.15))
            local randomK = kills - kosK - bountyK
            self.db.scoreboard[fullName] = {
                name = fullName, totalKills = kills,
                bountyKills = bountyK, kosKills = kosK,
                randomKills = randomK,
                totalPoints = randomK * 5 + kosK * 25 + bountyK * 100 + math.random(0, 200),
                lastKill = time() - math.random(300, 86400 * 2),
                killStreak = 0, bestStreak = math.random(2, 12),
            }
        end
    end

    -- Enemy sheet: all enemies
    for _, e in ipairs(fakeEnemies) do
        local fullName = e.name .. "-" .. realm
        if not self.db.enemySheet[fullName] then
            self.db.enemySheet[fullName] = {
                name = fullName, class = e.class, race = e.race, level = e.level, guild = e.guild,
                timesKilledUs = math.random(2, 18),
                timesWeKilledThem = math.random(3, 30),
                lastKilledUsTime = time() - math.random(600, 172800),
                lastKilledUsBy = fakeGuildies[math.random(#fakeGuildies)].name .. "-" .. realm,
                lastWeKilledTime = time() - math.random(300, 86400),
                lastWeKilledBy = fakeGuildies[math.random(#fakeGuildies)].name .. "-" .. realm,
                firstSeen = time() - math.random(86400, 604800),
            }
        end
    end

    -- Kill log: 40 KOS/bounty entries + 20 random PvP kills
    for i = 1, 40 do
        local killer = fakeGuildies[math.random(#fakeGuildies)]
        local victim = fakeEnemies[math.random(#fakeEnemies)]
        local vFullName = victim.name .. "-" .. realm
        local isKOS = self:IsKOS(vFullName)
        local isBounty = self:HasActiveBounty(vFullName)
        local pts = isBounty and 100 or (isKOS and 25 or 5)
        table.insert(self.db.killLog, {
            killer = killer.name .. "-" .. realm,
            victim = vFullName,
            victimClass = victim.class, victimRace = victim.race, victimLevel = victim.level,
            zone = zones[math.random(#zones)],
            time = time() - math.random(60, 86400 * 5),
            isKOS = isKOS, isBounty = isBounty, points = pts,
            killType = isBounty and "bounty" or (isKOS and "kos" or "random"),
        })
    end

    -- Random PvP kills (not on KOS list)
    local randomEnemies = {
        { name = "Randogank", class = "WARRIOR", race = "Orc", level = 70 },
        { name = "Justpassing", class = "HUNTER", race = "Troll", level = 68 },
        { name = "Whoopsidied", class = "MAGE", race = "Blood Elf", level = 66 },
        { name = "Flagrunner", class = "DRUID", race = "Tauren", level = 70 },
        { name = "Notaganker", class = "PALADIN", race = "Blood Elf", level = 70 },
        { name = "Wpvpandy", class = "SHAMAN", race = "Orc", level = 69 },
        { name = "Oopsifell", class = "PRIEST", race = "Undead", level = 67 },
        { name = "Wasntme", class = "ROGUE", race = "Blood Elf", level = 70 },
    }
    for i = 1, 20 do
        local killer = fakeGuildies[math.random(#fakeGuildies)]
        local victim = randomEnemies[math.random(#randomEnemies)]
        table.insert(self.db.killLog, {
            killer = killer.name .. "-" .. realm,
            victim = victim.name .. "-" .. realm,
            victimClass = victim.class, victimRace = victim.race, victimLevel = victim.level,
            zone = zones[math.random(#zones)],
            time = time() - math.random(60, 86400 * 5),
            isKOS = false, isBounty = false, points = 5,
            killType = "random",
        })
    end

    table.sort(self.db.killLog, function(a, b) return (a.time or 0) > (b.time or 0) end)

    -- Death log: 20 entries (enemies killing guild members)
    local myName = self:GetPlayerFullName()
    for i = 1, 20 do
        local killer = fakeEnemies[math.random(#fakeEnemies)]
        local victim = (i <= 12) and myName or (fakeGuildies[math.random(#fakeGuildies)].name .. "-" .. realm)
        table.insert(self.db.deathLog, {
            killer = killer.name .. "-" .. realm,
            victim = victim,
            killerClass = killer.class, killerRace = killer.race,
            zone = zones[math.random(#zones)],
            time = time() - math.random(600, 86400 * 4),
        })
    end
    table.sort(self.db.deathLog, function(a, b) return (a.time or 0) > (b.time or 0) end)

    self:Print(self.colors.grey .. "Demo data loaded for testing (14 KOS, 8 bounties, 10 scoreboard, 40 kills, 20 deaths).|r")
end

Deadpool:RegisterEvent("ADDON_LOADED", function(event, addonName)
    if addonName == "Deadpool" then
        Deadpool:InitDB()
        Deadpool:Init()
    end
end)
