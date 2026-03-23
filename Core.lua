----------------------------------------------------------------------
-- Deadpool - Kill on Sight Bounty Tracker & World PvP Scoreboard
-- Core.lua - Namespace, event system, utilities, slash commands
----------------------------------------------------------------------

Deadpool = {}
Deadpool.version = "1.1.2"
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
            return n .. "-" .. r
        end
    end
    -- No realm given, use player's realm
    return input .. "-" .. GetRealmName()
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
    if not IsInGuild() then return nil end
    local _, _, rankIndex = GetGuildInfo("player")
    return rankIndex or 99
end

function Deadpool:IsGM()
    local rank = self:GetGuildRank()
    return rank == 0
end

function Deadpool:IsOfficer()
    local rank = self:GetGuildRank()
    if not rank then return false end
    return rank <= (self.db.settings.officerRank or 1)
end

function Deadpool:IsManager()
    if self:IsGM() then return true end
    local myName = self:GetPlayerFullName()
    local managers = self.db.guildConfig and self.db.guildConfig.managers
    return managers and managers[myName] == true
end

function Deadpool:AwardPointsTo(targetName, amount, reason)
    if not self:IsManager() then
        self:Print(self.colors.red .. "Only managers can award points.|r")
        return false
    end
    local fullName = self:NormalizeName(targetName)
    if not fullName then
        self:Print("Invalid player name.")
        return false
    end
    if not amount or amount == 0 then
        self:Print("Amount must be non-zero.")
        return false
    end
    local score = self:GetOrCreateScore(fullName)
    score.totalPoints = (score.totalPoints or 0) + amount
    local verb = amount > 0 and "awarded" or "deducted"
    local display = amount > 0 and ("+" .. amount) or tostring(amount)
    self:Print(self.colors.gold .. display .. " pts|r " .. verb .. " to " .. self:ShortName(fullName) ..
        (reason and reason ~= "" and (" (" .. reason .. ")") or ""))
    if self.RefreshUI then self:RefreshUI() end
    return true
end

-- Get point values from guild config (GM-managed, synced)
function Deadpool:GetPointsConfig()
    return self.db.guildConfig
end

----------------------------------------------------------------------
-- Kill Sounds
----------------------------------------------------------------------
local SOUND_PATH = "Interface\\AddOns\\Deadpool\\Sounds\\"

-- All available sounds (any sound can be used for any feature)
local ALL_SOUNDS = {
    -- Kill sounds
    gunshot   = { name = "Gunshot",        file = SOUND_PATH .. "shot1.mp3",      category = "kill" },
    impact1   = { name = "Impact Stomp 1", file = SOUND_PATH .. "impact1.mp3",    category = "kill" },
    impact2   = { name = "Impact Stomp 2", file = SOUND_PATH .. "impact2.mp3",    category = "kill" },
    impact3   = { name = "Impact Stomp 3", file = SOUND_PATH .. "impact3.mp3",    category = "kill" },
    coin      = { name = "Coin",           file = SOUND_PATH .. "coin.mp3",       category = "kill" },
    explosion = { name = "Explosion",      file = SOUND_PATH .. "explosion.mp3",  category = "kill" },
    bomb      = { name = "Bomb",           file = SOUND_PATH .. "bomb.mp3",       category = "kill" },
    -- Death sounds
    partydeath = { name = "Oh Shit!",      file = SOUND_PATH .. "partydeath.mp3", category = "death" },
    gameover1  = { name = "Game Over 1",   file = SOUND_PATH .. "gameover1.mp3",  category = "death" },
    gameover2  = { name = "Game Over 2",   file = SOUND_PATH .. "gameover2.mp3",  category = "death" },
    -- PVP engage / alert sounds
    engage1   = { name = "Dark Logo",      file = SOUND_PATH .. "engage1.mp3",    category = "alert" },
    siren     = { name = "Dirty Siren",    file = SOUND_PATH .. "siren.mp3",      category = "alert" },
    laugh     = { name = "Scary Laugh",    file = SOUND_PATH .. "laugh.mp3",      category = "alert" },
    warning   = { name = "Horror Warning", file = SOUND_PATH .. "warning.mp3",    category = "alert" },
    maniac    = { name = "Maniac",         file = SOUND_PATH .. "maniac.mp3",     category = "alert" },
    -- Silent
    none      = { name = "None (silent)",  file = nil,                            category = "all" },
}

-- Streak announcer sounds
local STREAK_SOUNDS = {
    [2]  = { name = "DOUBLE KILL",     file = SOUND_PATH .. "doublekill.mp3" },
    [3]  = { name = "TRIPLE KILL",     file = SOUND_PATH .. "triplekill.mp3" },
    [4]  = { name = "QUAD KILL",       file = SOUND_PATH .. "quadkill.mp3" },
    [5]  = { name = "RAMPAGE",         file = SOUND_PATH .. "rampage.mp3" },
    [6]  = { name = "KILLING SPREE",   file = SOUND_PATH .. "killingspree.mp3" },
    [7]  = { name = "DOMINATING",      file = SOUND_PATH .. "dominating.mp3" },
    [8]  = { name = "UNSTOPPABLE",     file = SOUND_PATH .. "unstoppable.mp3" },
    [9]  = { name = "MEGA KILL",       file = SOUND_PATH .. "megakill.mp3" },
    [10] = { name = "GODLIKE",         file = SOUND_PATH .. "godlike.mp3" },
    [15] = { name = "HOLY SHIT",       file = SOUND_PATH .. "holyshit.mp3" },
    [20] = { name = "WICKED SICK",     file = SOUND_PATH .. "wickedsick.mp3" },
    [25] = { name = "MONSTER KILL",    file = SOUND_PATH .. "monsterkill.mp3" },
}

function Deadpool:PlaySoundByKey(soundKey)
    if not soundKey or soundKey == "none" then return end
    local customSounds = self.db.settings.customKillSounds
    if customSounds and customSounds[soundKey] then
        PlaySoundFile(SOUND_PATH .. customSounds[soundKey], "Master")
        return
    end
    local sound = ALL_SOUNDS[soundKey]
    if sound and sound.file then
        PlaySoundFile(sound.file, "Master")
    end
end

function Deadpool:PlayKillSound(killType, streak)
    if not self.db.settings.killSoundEnabled then return end
    self:PlaySoundByKey(self.db.settings.killSound or "gunshot")

    -- Streak announcer (plays AFTER the kill sound with a slight delay)
    if self.db.settings.streakSoundsEnabled and streak and streak >= 2 then
        C_Timer.After(0.3, function()
            Deadpool:PlayStreakSound(streak)
        end)
    end
end

function Deadpool:PlayDeathSound()
    local key = self.db.settings.deathSound
    if key and key ~= "none" then
        self:PlaySoundByKey(key)
    end
end

function Deadpool:PlayPartyDeathSound()
    local key = self.db.settings.partyDeathSound
    if key and key ~= "none" then
        self:PlaySoundByKey(key)
    end
end

function Deadpool:PlayKOSAlertSound()
    local key = self.db.settings.kosAlertSound
    if key and key ~= "none" then
        self:PlaySoundByKey(key)
    end
end

function Deadpool:PlayPartyAttackSound()
    local key = self.db.settings.partyAttackSound
    if key and key ~= "none" then
        self:PlaySoundByKey(key)
    end
end

function Deadpool:PlayStreakSound(streak)
    -- Find the highest matching streak tier
    local bestMatch = nil
    for threshold, data in pairs(STREAK_SOUNDS) do
        if streak >= threshold and (not bestMatch or threshold > bestMatch) then
            bestMatch = threshold
        end
    end

    if bestMatch and STREAK_SOUNDS[bestMatch] then
        local data = STREAK_SOUNDS[bestMatch]
        PlaySoundFile(data.file, "Master")

        -- Show streak text on screen if alert frame is enabled
        if self.db.settings.showAlertFrame and streak == bestMatch then
            self:ShowStreakAlert(data.name, streak)
        end
    end
end

function Deadpool:ShowStreakAlert(streakName, count)
    if not DeadpoolAlertFrame then return end
    local TM = self.modules.Theme
    local alertText = DeadpoolAlertFrame.alertText or _G["DeadpoolAlertFrame"] and select(1, DeadpoolAlertFrame:GetRegions())

    -- Use the existing alert system
    local colors = {
        [2] = "|cFFFFFF00",   -- yellow
        [3] = "|cFFFF8800",   -- orange
        [4] = "|cFFFF4400",   -- deep orange
        [5] = "|cFFFF0000",   -- red
        [6] = "|cFFFF0044",   -- crimson
        [7] = "|cFFCC00FF",   -- purple
        [8] = "|cFF8800FF",   -- violet
        [9] = "|cFF4400FF",   -- indigo
        [10] = "|cFFFF0000",  -- red
        [15] = "|cFFFF0000",  -- red
        [20] = "|cFFFF0000",  -- red
        [25] = "|cFFFF0000",  -- red
    }
    local bestColor = "|cFFFFFF00"
    for threshold, color in pairs(colors) do
        if count >= threshold then bestColor = color end
    end

    self:Print(bestColor .. streakName .. "|r  (" .. count .. " kill streak!)")
end

function Deadpool:PreviewKillSound(soundKey)
    soundKey = soundKey or self.db.settings.killSound or "gunshot"
    self:PlaySoundByKey(soundKey)
end

function Deadpool:PreviewStreakSound(streak)
    local data = STREAK_SOUNDS[streak]
    if data then
        PlaySoundFile(data.file, "Master")
        self:Print(data.name .. " (streak " .. streak .. ")")
    end
end

function Deadpool:AddCustomSound(displayName, filename)
    if not self.db.settings.customKillSounds then
        self.db.settings.customKillSounds = {}
    end
    local key = "custom_" .. displayName:lower():gsub("%s+", "_")
    self.db.settings.customKillSounds[key] = filename
    return key
end

function Deadpool:RemoveCustomSound(key)
    if self.db.settings.customKillSounds then
        self.db.settings.customKillSounds[key] = nil
    end
end

function Deadpool:GetKillSoundOptions()
    local options = {}
    for key, data in pairs(ALL_SOUNDS) do
        options[#options + 1] = key
    end
    -- Add custom sounds
    if self.db and self.db.settings and self.db.settings.customKillSounds then
        for key in pairs(self.db.settings.customKillSounds) do
            options[#options + 1] = key
        end
    end
    -- Sort: none last, rest alphabetical
    table.sort(options, function(a, b)
        if a == "none" then return false end
        if b == "none" then return true end
        local na = Deadpool:GetKillSoundName(a)
        local nb = Deadpool:GetKillSoundName(b)
        return na < nb
    end)
    return options
end

function Deadpool:GetKillSoundName(key)
    if ALL_SOUNDS[key] then return ALL_SOUNDS[key].name end
    if key:sub(1, 7) == "custom_" then
        local name = key:sub(8):gsub("_", " ")
        return name:sub(1,1):upper() .. name:sub(2) .. " *"
    end
    return key
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
    elseif cmd == "award" or cmd == "give" then
        local name, amount, reason = rest:match("^(%S+)%s+(%-?%d+)%s*(.-)$")
        if name and amount then
            Deadpool:AwardPointsTo(name, tonumber(amount), reason)
        else
            Deadpool:Print("Usage: /dp award <PlayerName> <points> [reason]")
        end
    elseif cmd == "manager" then
        if not Deadpool:IsGM() then
            Deadpool:Print(Deadpool.colors.red .. "Only the GM can manage the managers list.|r")
        elseif rest == "" then
            local mgrs = Deadpool.db.guildConfig.managers or {}
            local names = {}
            for n in pairs(mgrs) do names[#names + 1] = Deadpool:ShortName(n) end
            if #names == 0 then
                Deadpool:Print("No managers assigned. Usage: /dp manager add|remove <name>")
            else
                Deadpool:Print(Deadpool.colors.gold .. "Managers:|r " .. table.concat(names, ", "))
            end
        else
            local action, name = rest:match("^(%S+)%s+(.+)$")
            if action and name then
                action = action:lower()
                local fullName = Deadpool:NormalizeName(name)
                if not fullName then
                    Deadpool:Print("Invalid player name.")
                elseif action == "add" then
                    if not Deadpool.db.guildConfig.managers then Deadpool.db.guildConfig.managers = {} end
                    Deadpool.db.guildConfig.managers[fullName] = true
                    Deadpool:Print(Deadpool.colors.green .. Deadpool:ShortName(fullName) .. " added as manager.|r")
                elseif action == "remove" or action == "rem" then
                    if Deadpool.db.guildConfig.managers then
                        Deadpool.db.guildConfig.managers[fullName] = nil
                    end
                    Deadpool:Print(Deadpool.colors.red .. Deadpool:ShortName(fullName) .. " removed as manager.|r")
                else
                    Deadpool:Print("Usage: /dp manager add|remove <name>")
                end
            else
                Deadpool:Print("Usage: /dp manager add|remove <name>")
            end
        end
    elseif cmd == "war" then
        if not Deadpool:IsManager() then
            Deadpool:Print(Deadpool.colors.red .. "Only managers can declare guild wars.|r")
        elseif rest == "" then
            local wars = Deadpool.db.guildConfig.warGuilds or {}
            local names = {}
            for g in pairs(wars) do names[#names + 1] = g end
            if #names == 0 then
                Deadpool:Print("No guild wars active. Usage: /dp war add|remove <guild name>")
            else
                Deadpool:Print(Deadpool.colors.red .. "Guild Wars:|r " .. table.concat(names, ", "))
            end
        else
            local action, guildName = rest:match("^(%S+)%s+(.+)$")
            if action and guildName then
                action = action:lower()
                if action == "add" or action == "declare" then
                    if not Deadpool.db.guildConfig.warGuilds then Deadpool.db.guildConfig.warGuilds = {} end
                    Deadpool.db.guildConfig.warGuilds[guildName] = true
                    Deadpool:Print(Deadpool.colors.red .. "WAR DECLARED|r against <" .. guildName .. ">! All members are now KOS.")
                    Deadpool:BroadcastGMConfig()
                elseif action == "remove" or action == "end" or action == "peace" then
                    if Deadpool.db.guildConfig.warGuilds then
                        Deadpool.db.guildConfig.warGuilds[guildName] = nil
                    end
                    Deadpool:Print(Deadpool.colors.green .. "Peace declared|r with <" .. guildName .. ">. War guild KOS lifted.")
                    Deadpool:BroadcastGMConfig()
                else
                    Deadpool:Print("Usage: /dp war add|remove <guild name>")
                end
            else
                Deadpool:Print("Usage: /dp war add|remove <guild name>")
            end
        end
    elseif cmd == "bounty" then
        local name, amount, rest2 = rest:match("^(%S+)%s+(%d+)%s*(.*)$")
        if name and amount then
            local val = tonumber(amount)
            -- Check for "pts" or "points" keyword to determine type
            local bountyType = "gold"
            local maxKills = 10
            if rest2 then
                local r2lower = rest2:lower()
                if r2lower:find("pts") or r2lower:find("points") then
                    bountyType = "points"
                    maxKills = tonumber(rest2:match("(%d+)")) or 10
                else
                    maxKills = tonumber(rest2) or 10
                end
            end
            Deadpool:PlaceBounty(name, val, maxKills, bountyType)
        else
            Deadpool:Print("Usage: /dp bounty <PlayerName> <amount> [maxKills|pts]")
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
    elseif cmd == "dedup" then
        -- Remove duplicate kill log entries (same killer+victim within 10 seconds)
        local killLog = Deadpool.db.killLog
        local cleaned = {}
        local seen = {}
        local removed = 0
        -- Sort by time first to ensure consistent ordering
        table.sort(killLog, function(a, b) return (a.time or 0) < (b.time or 0) end)
        for _, entry in ipairs(killLog) do
            local key = (entry.killer or "") .. ">" .. (entry.victim or "")
            if seen[key] and entry.time and seen[key].time and math.abs(entry.time - seen[key].time) < 10 then
                removed = removed + 1
            else
                table.insert(cleaned, entry)
                seen[key] = entry
            end
        end
        -- Re-sort newest first
        table.sort(cleaned, function(a, b) return (a.time or 0) > (b.time or 0) end)
        Deadpool.db.killLog = cleaned

        -- Recalculate scoreboard from clean kill log
        Deadpool.db.scoreboard = {}
        for _, k in ipairs(cleaned) do
            local score = Deadpool:GetOrCreateScore(k.killer)
            score.totalKills = (score.totalKills or 0) + 1
            local pts = k.points or 5
            score.totalPoints = (score.totalPoints or 0) + pts
            if k.killType == "bounty" then
                score.bountyKills = (score.bountyKills or 0) + 1
            elseif k.killType == "kos" then
                score.kosKills = (score.kosKills or 0) + 1
            else
                score.randomKills = (score.randomKills or 0) + 1
            end
            if not score.lastKill or (k.time or 0) > score.lastKill then
                score.lastKill = k.time
            end
        end

        -- Also recalculate KOS kill counts
        for fullName, entry in pairs(Deadpool.db.kosList) do
            entry.totalKills = 0
        end
        for _, k in ipairs(cleaned) do
            if k.isKOS and Deadpool.db.kosList[k.victim] then
                Deadpool.db.kosList[k.victim].totalKills = (Deadpool.db.kosList[k.victim].totalKills or 0) + 1
            end
        end

        Deadpool:Print(Deadpool.colors.green .. "Dedup complete:|r removed " .. removed .. " duplicate kills. " .. #cleaned .. " remaining.")
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
    local initOrder = { "Theme", "BountyManager", "KillTracker", "Sync", "Nearby", "UI", "Alerts" }
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

    -- One-time cleanup: purge fake demo data from SavedVariables
    if not self.db._demoPurged then
        self:PurgeDemoData()
    end
end

----------------------------------------------------------------------
-- One-time demo data purge (remove after all accounts have loaded once)
----------------------------------------------------------------------
function Deadpool:PurgeDemoData()
    local fakeNames = {
        "Gankerface", "Cheesewheel", "Stabbymcstab", "Darkshdow", "Griefdaddy",
        "Frostitute", "Dotsndots", "Healznope", "Moonpunter", "Critsworth",
        "Shockadin", "Sneakypeek", "Frostshawk", "Felburner",
        "Thunderbro", "Slapmage", "Holycrit", "Tankenstein", "Arrowstorm",
        "Dotweaver", "Critmachine", "Bubbleboy", "Wrathchild",
        "Randogank", "Justpassing", "Whoopsidied", "Flagrunner", "Notaganker",
        "Wpvpandy", "Oopsifell", "Wasntme",
    }

    -- Build lookup set (match "Name-AnyRealm" keys)
    local isFake = {}
    for _, name in ipairs(fakeNames) do
        isFake[name] = true
    end

    local function isFakeKey(fullName)
        local shortName = fullName and fullName:match("^(.+)%-") or fullName
        return isFake[shortName]
    end

    local removed = { kos = 0, bounty = 0, score = 0, enemy = 0, kill = 0, death = 0 }

    -- Purge keyed tables (kosList, bounties, scoreboard, enemySheet)
    for fullName in pairs(self.db.kosList) do
        if isFakeKey(fullName) then
            self.db.kosList[fullName] = nil
            removed.kos = removed.kos + 1
        end
    end
    for fullName in pairs(self.db.bounties) do
        if isFakeKey(fullName) then
            self.db.bounties[fullName] = nil
            removed.bounty = removed.bounty + 1
        end
    end
    for fullName in pairs(self.db.scoreboard) do
        if isFakeKey(fullName) then
            self.db.scoreboard[fullName] = nil
            removed.score = removed.score + 1
        end
    end
    for fullName in pairs(self.db.enemySheet) do
        if isFakeKey(fullName) then
            self.db.enemySheet[fullName] = nil
            removed.enemy = removed.enemy + 1
        end
    end

    -- Purge kill log (remove entries where killer OR victim is fake)
    local cleanKills = {}
    for _, entry in ipairs(self.db.killLog) do
        if not isFakeKey(entry.killer) and not isFakeKey(entry.victim) then
            table.insert(cleanKills, entry)
        else
            removed.kill = removed.kill + 1
        end
    end
    self.db.killLog = cleanKills

    -- Purge death log (remove entries where killer OR victim is fake)
    local cleanDeaths = {}
    for _, entry in ipairs(self.db.deathLog or {}) do
        if not isFakeKey(entry.killer) and not isFakeKey(entry.victim) then
            table.insert(cleanDeaths, entry)
        else
            removed.death = removed.death + 1
        end
    end
    self.db.deathLog = cleanDeaths

    -- Clean up placeholder flags
    self.db._placeholderLoaded = nil
    self.db._placeholderVersion = nil
    self.db._demoPurged = true

    local total = removed.kos + removed.bounty + removed.score + removed.enemy + removed.kill + removed.death
    if total > 0 then
        self:Print(self.colors.green .. "Demo data purged:|r " ..
            removed.kos .. " KOS, " .. removed.bounty .. " bounties, " ..
            removed.score .. " scores, " .. removed.enemy .. " enemies, " ..
            removed.kill .. " kills, " .. removed.death .. " deaths removed.")
    end
end



Deadpool:RegisterEvent("ADDON_LOADED", function(event, addonName)
    if addonName == "Deadpool" then
        Deadpool:InitDB()
        Deadpool:Init()
    end
end)
