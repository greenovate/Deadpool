----------------------------------------------------------------------
-- Deadpool - Sync.lua
-- Guild addon channel communication protocol
-- Syncs KOS list, bounties, and kill reports across guild members
----------------------------------------------------------------------

local Sync = {}
Deadpool:RegisterModule("Sync", Sync)

-- Message types
local MSG = {
    KILL        = "KILL",       -- kill report
    KOS_ADD     = "KOS_ADD",    -- add to KOS list
    KOS_REM     = "KOS_REM",    -- remove from KOS
    BOUNTY_ADD  = "BNT_ADD",   -- bounty placed
    BOUNTY_CLM  = "BNT_CLM",   -- bounty kill claimed
    SYNC_REQ    = "SYNC_REQ",   -- request full sync
    SYNC_KOS    = "SYNC_KOS",   -- sync KOS entry
    SYNC_BNT    = "SYNC_BNT",   -- sync bounty entry
    SYNC_SCR    = "SYNC_SCR",   -- sync scoreboard entry
    SYNC_KILL   = "SYNC_KIL",   -- sync kill log entry
    SYNC_END    = "SYNC_END",   -- sync complete
    VERSION     = "VERSION",    -- version announcement
    HEARTBEAT   = "HB",        -- periodic version heartbeat
    PUSH        = "PUSH",      -- "I have data for you" (version-aware)
    SIGHTING    = "SIGHT",     -- KOS target spotted by a guild member
    GM_CONFIG   = "GMCFG",    -- GM config push (point values, timestamps)
}

local SEPARATOR = "|"
local syncThrottle = 0
local SYNC_COOLDOWN = 30  -- minimum seconds between full syncs
local HEARTBEAT_INTERVAL = 300  -- broadcast sync version every 5 minutes
local onlineGuildMembers = {}   -- track who's online for new-login detection

----------------------------------------------------------------------
-- Init
----------------------------------------------------------------------
function Sync:Init()
    Deadpool:RegisterEvent("CHAT_MSG_ADDON", function(event, prefix, message, channel, sender)
        if prefix == Deadpool.prefix then
            Sync:OnAddonMessage(message, channel, sender)
        end
    end)

    -- Request sync from guild on login (delayed)
    Deadpool:RegisterEvent("PLAYER_ENTERING_WORLD", function(event, isInitialLogin, isReloadingUi)
        if Deadpool.db.settings.syncEnabled then
            -- Delay sync request to let other addons load
            C_Timer.After(5, function()
                Sync:BroadcastVersion()
                C_Timer.After(2, function()
                    Deadpool:RequestSync()
                end)
            end)

            -- Snapshot current online roster for new-login detection
            C_Timer.After(8, function()
                Sync:SnapshotOnlineRoster()
            end)
        end
    end)

    ---------------------------------------------------------------
    -- Detect guild members coming online
    -- When someone new appears, push our data to them
    ---------------------------------------------------------------
    Deadpool:RegisterEvent("GUILD_ROSTER_UPDATE", function()
        if not Deadpool.db.settings.syncEnabled then return end
        Sync:CheckForNewOnlineMembers()
    end)

    ---------------------------------------------------------------
    -- Pre-logout: broadcast full state to guild so anyone online
    -- captures our data before we disappear
    ---------------------------------------------------------------
    Deadpool:RegisterEvent("PLAYER_LOGOUT", function()
        if Deadpool.db.settings.syncEnabled and IsInGuild() then
            Sync:PushFullStateToGuild()
        end
    end)

    ---------------------------------------------------------------
    -- Heartbeat: every 5 minutes broadcast our sync version
    -- Anyone behind will auto-request a sync
    ---------------------------------------------------------------
    if C_Timer and C_Timer.NewTicker then
        C_Timer.NewTicker(HEARTBEAT_INTERVAL, function()
            if Deadpool.db.settings.syncEnabled and IsInGuild() then
                Sync:Send(MSG.HEARTBEAT, tostring(Deadpool.db.syncVersion or 0))
            end
        end)
    end
end

----------------------------------------------------------------------
-- Send message to guild
----------------------------------------------------------------------
function Sync:Send(msgType, data, target)
    if not Deadpool.db.settings.syncEnabled then return end
    if not IsInGuild() then return end

    local payload = msgType .. ":" .. (data or "")

    -- Truncate to 255 bytes (WoW limit)
    if #payload > 255 then
        payload = payload:sub(1, 255)
    end

    -- Always use GUILD channel — never whisper to prevent cross-guild data leaks
    if C_ChatInfo and C_ChatInfo.SendAddonMessage then
        C_ChatInfo.SendAddonMessage(Deadpool.prefix, payload, "GUILD")
    end
end

----------------------------------------------------------------------
-- Receive handler
----------------------------------------------------------------------
function Sync:OnAddonMessage(message, channel, sender)
    -- Only accept messages from the GUILD channel
    if channel ~= "GUILD" then return end

    -- Don't process our own messages
    local myName = UnitName("player")
    local senderName = sender:match("^(.-)%-") or sender
    if senderName == myName then return end

    local msgType, data = message:match("^(.-):(.*)")
    if not msgType then return end

    Deadpool:Debug("Sync recv [" .. msgType .. "] from " .. sender)

    if msgType == MSG.KILL then
        self:HandleKillReport(data, sender)
    elseif msgType == MSG.KOS_ADD then
        self:HandleKOSAdd(data, sender)
    elseif msgType == MSG.KOS_REM then
        self:HandleKOSRemove(data, sender)
    elseif msgType == MSG.BOUNTY_ADD then
        self:HandleBountyAdd(data, sender)
    elseif msgType == MSG.BOUNTY_CLM then
        self:HandleBountyClaim(data, sender)
    elseif msgType == MSG.SYNC_REQ then
        self:HandleSyncRequest(sender)
    elseif msgType == MSG.SYNC_KOS then
        self:HandleSyncKOS(data, sender)
    elseif msgType == MSG.SYNC_BNT then
        self:HandleSyncBounty(data, sender)
    elseif msgType == MSG.SYNC_SCR then
        self:HandleSyncScore(data, sender)
    elseif msgType == MSG.SYNC_KILL then
        self:HandleSyncKill(data, sender)
    elseif msgType == MSG.SYNC_END then
        Deadpool:Debug("Sync complete from " .. sender)
    elseif msgType == MSG.VERSION then
        self:HandleVersion(data, sender)
    elseif msgType == MSG.HEARTBEAT then
        self:HandleHeartbeat(data, sender)
    elseif msgType == MSG.PUSH then
        -- Another client is offering to push data to us
        -- Respond with a sync request targeted to them
        Deadpool:Debug("Push offer from " .. sender .. " — requesting their data")
        Sync:Send(MSG.SYNC_REQ, tostring(Deadpool.db.syncVersion or 0), sender)
    elseif msgType == MSG.SIGHTING then
        self:HandleSighting(data, sender)
    elseif msgType == MSG.GM_CONFIG then
        self:HandleGMConfig(data, sender)
    end
end

----------------------------------------------------------------------
-- Encoding/Decoding helpers
----------------------------------------------------------------------
local function encode(...)
    local parts = {}
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        table.insert(parts, tostring(v or ""))
    end
    return table.concat(parts, SEPARATOR)
end

local function decode(data)
    local parts = {}
    for part in (data .. SEPARATOR):gmatch("(.-)" .. "%" .. SEPARATOR) do
        table.insert(parts, part)
    end
    return parts
end

----------------------------------------------------------------------
-- Broadcast functions (called by BountyManager/KillTracker)
----------------------------------------------------------------------
function Deadpool:BroadcastKill(killerFull, victimFull, victimClass, victimRace, victimLevel, zone)
    local data = encode(killerFull, victimFull, victimClass or "", victimRace or "", victimLevel or 0, zone or "")
    Sync:Send(MSG.KILL, data)
end

function Deadpool:BroadcastKOSAdd(fullName)
    local entry = Deadpool.db.kosList[fullName]
    if not entry then return end
    local data = encode(fullName, entry.class or "", entry.race or "",
        entry.level or 0, entry.reason or "", entry.addedBy or "", entry.addedDate or 0)
    Sync:Send(MSG.KOS_ADD, data)
end

function Deadpool:BroadcastKOSRemove(fullName)
    Sync:Send(MSG.KOS_REM, fullName)
end

function Deadpool:BroadcastBountyAdd(fullName)
    local bounty = Deadpool.db.bounties[fullName]
    if not bounty then return end
    local data = encode(fullName, bounty.bountyGold or 0, bounty.maxKills,
        bounty.placedBy or "", bounty.placedDate or 0,
        bounty.bountyType or "gold", bounty.bountyPoints or 0)
    Sync:Send(MSG.BOUNTY_ADD, data)
end

function Deadpool:BroadcastBountyClaim(targetFull, killerFull, zone)
    local data = encode(targetFull, killerFull, zone or "")
    Sync:Send(MSG.BOUNTY_CLM, data)
end

function Deadpool:RequestSync()
    if not IsInGuild() then
        Deadpool:Print("You must be in a guild to sync.")
        return
    end
    local now = time()
    if (now - syncThrottle) < SYNC_COOLDOWN then
        Deadpool:Debug("Sync throttled")
        return
    end
    syncThrottle = now
    Deadpool:Print(Deadpool.colors.cyan .. "Requesting sync from guild...|r")
    Sync:Send(MSG.SYNC_REQ, tostring(Deadpool.db.syncVersion or 0))
end

function Sync:BroadcastVersion()
    Sync:Send(MSG.VERSION, Deadpool.version)
end

----------------------------------------------------------------------
-- Handle incoming messages
----------------------------------------------------------------------
function Sync:HandleKillReport(data, sender)
    local parts = decode(data)
    local killerFull = parts[1]
    local victimFull = parts[2]
    local victimClass = parts[3] ~= "" and parts[3] or nil
    local victimRace = parts[4] ~= "" and parts[4] or nil
    local victimLevel = tonumber(parts[5]) or 0
    local zone = parts[6] or "Unknown"

    if not killerFull or not victimFull then return end

    -- Record the kill from the remote player
    -- This handles points, KOS tracking, bounty claims, and logging
    Deadpool:RecordKill(killerFull, victimFull, victimClass, victimRace, victimLevel, zone)
end

function Sync:HandleKOSAdd(data, sender)
    local parts = decode(data)
    local fullName = parts[1]
    local class = parts[2] ~= "" and parts[2] or nil
    local race = parts[3] ~= "" and parts[3] or nil
    local level = tonumber(parts[4]) or 0
    local reason = parts[5] ~= "" and parts[5] or nil
    local addedBy = parts[6] ~= "" and parts[6] or sender
    local addedDate = tonumber(parts[7]) or time()

    if not fullName then return end

    -- Add or update silently
    if not Deadpool:IsKOS(fullName) then
        Deadpool.db.kosList[fullName] = {
            name = Deadpool:ShortName(fullName),
            realm = fullName:match("%-(.+)$") or GetRealmName(),
            class = class,
            race = race,
            level = level > 0 and level or nil,
            addedBy = addedBy,
            addedDate = addedDate,
            reason = reason,
            totalKills = 0,
            lastKilledBy = nil,
            lastKilledTime = 0,
            lastSeenZone = nil,
            lastSeenTime = 0,
        }
        local display = class and Deadpool:ClassColor(class, Deadpool:ShortName(fullName)) or Deadpool:ShortName(fullName)
        Deadpool:Print(display .. " added to KOS by " .. Deadpool:ShortName(addedBy))
        if Deadpool.RefreshUI then Deadpool:RefreshUI() end
    end
end

function Sync:HandleKOSRemove(data, sender)
    local fullName = data
    if fullName and Deadpool:IsKOS(fullName) then
        Deadpool.db.kosList[fullName] = nil
        Deadpool:Print(Deadpool:ShortName(fullName) .. " removed from KOS by " .. (sender:match("^(.-)%-") or sender))
        if Deadpool.RefreshUI then Deadpool:RefreshUI() end
    end
end

function Sync:HandleBountyAdd(data, sender)
    local parts = decode(data)
    local fullName = parts[1]
    local gold = tonumber(parts[2]) or 0
    local maxKills = tonumber(parts[3]) or 10
    local placedBy = parts[4] ~= "" and parts[4] or sender
    local placedDate = tonumber(parts[5]) or time()
    local bountyType = (parts[6] and parts[6] ~= "") and parts[6] or "gold"
    local bountyPoints = tonumber(parts[7]) or 0

    if not fullName or (gold <= 0 and bountyPoints <= 0) then return end

    -- Auto-add to KOS if not there
    if not Deadpool:IsKOS(fullName) then
        Deadpool:AddToKOS(fullName, "Bounty target", true)
    end

    if not Deadpool:HasActiveBounty(fullName) then
        Deadpool.db.bounties[fullName] = {
            target = fullName,
            bountyGold = gold,
            bountyPoints = bountyPoints,
            bountyType = bountyType,
            placedBy = placedBy,
            placedDate = placedDate,
            maxKills = maxKills,
            currentKills = 0,
            expired = false,
            claims = {},
        }
        local reward = bountyType == "points" and (bountyPoints .. " pts") or Deadpool:FormatGold(gold)
        Deadpool:Print(Deadpool.colors.gold .. "NEW CONTRACT|r — " ..
            Deadpool:ShortName(fullName) .. " — " .. reward ..
            " placed by " .. Deadpool:ShortName(placedBy))
    end
    if Deadpool.RefreshUI then Deadpool:RefreshUI() end
end

function Sync:HandleBountyClaim(data, sender)
    local parts = decode(data)
    local targetFull = parts[1]
    local killerFull = parts[2]
    local zone = parts[3] or "Unknown"
    if targetFull and killerFull then
        Deadpool:ClaimBountyKill(targetFull, killerFull, zone)
    end
end

----------------------------------------------------------------------
-- Full sync: respond to sync requests
----------------------------------------------------------------------
function Sync:HandleSyncRequest(sender)
    Deadpool:Debug("Sync request from " .. sender .. " — sending data")

    local delay = 0
    local BATCH_DELAY = 0.5  -- stagger messages (0.5s to prevent disconnect)

    -- Send KOS entries (stripped: no race, reason truncated to 20 chars)
    for fullName, entry in pairs(Deadpool.db.kosList) do
        C_Timer.After(delay, function()
            local reason = entry.reason or ""
            if #reason > 20 then reason = reason:sub(1, 20) end
            local data = encode(fullName, entry.class or "", entry.level or 0,
                reason, entry.addedBy or "", entry.addedDate or 0, entry.totalKills or 0)
            Sync:Send(MSG.SYNC_KOS, data)
        end)
        delay = delay + BATCH_DELAY
    end

    -- Send bounties (stripped: no placedBy, infer bountyType)
    for fullName, bounty in pairs(Deadpool.db.bounties) do
        C_Timer.After(delay, function()
            local data = encode(fullName, bounty.bountyGold or 0, bounty.maxKills or 10,
                bounty.currentKills or 0, bounty.placedDate or 0,
                bounty.expired and "1" or "0", bounty.bountyPoints or 0)
            Sync:Send(MSG.SYNC_BNT, data)
        end)
        delay = delay + BATCH_DELAY
    end

    -- Send scoreboard (skip during 24hr reset window to prevent old data spreading)
    local resetAt = Deadpool.db.guildConfig.scoreboardResetAt or 0
    local inResetWindow = resetAt > 0 and (time() - resetAt) < 86400
    if not inResetWindow then
        for fullName, score in pairs(Deadpool.db.scoreboard) do
            C_Timer.After(delay, function()
                local data = encode(fullName, score.totalKills or 0, score.bountyKills or 0,
                    score.kosKills or 0, score.totalPoints or 0)
                Sync:Send(MSG.SYNC_SCR, data)
            end)
            delay = delay + BATCH_DELAY
        end
    end

    -- Send kill log (last 10 entries, stripped: no class or points)
    local killLog = Deadpool.db.killLog
    local maxSync = math.min(#killLog, 10)
    for i = 1, maxSync do
        local k = killLog[i]
        C_Timer.After(delay, function()
            local data = encode(k.killer or "", k.victim or "",
                k.victimLevel or 0, k.zone or "", k.time or 0, k.killType or "random")
            Sync:Send(MSG.SYNC_KILL, data)
        end)
        delay = delay + BATCH_DELAY
    end

    -- Send guild config (stripped: no managers/warGuilds — those sync via BroadcastGMConfig)
    C_Timer.After(delay, function()
        local gc = Deadpool.db.guildConfig
        local data = table.concat({
            gc.pointsPerKill or 5, gc.pointsPerKOSKill or 25, gc.pointsPerBountyKill or 100,
            gc.pointsUnderdogMultiplier3 or 2.0, gc.pointsUnderdogMultiplier6 or 3.0,
            gc.pointsLowbieFloor or 1, gc.updatedBy or "", gc.updatedAt or 0,
        }, "|")
        Sync:Send(MSG.GM_CONFIG, data)
    end)
    delay = delay + BATCH_DELAY

    -- Send end marker
    C_Timer.After(delay + BATCH_DELAY, function()
        Sync:Send(MSG.SYNC_END, "", sender)
    end)
end

function Sync:HandleSyncKOS(data, sender)
    local parts = decode(data)
    local fullName = parts[1]
    if not fullName or fullName == "" then return end

    local class = parts[2] ~= "" and parts[2] or nil
    local level = tonumber(parts[3]) or 0
    local reason = parts[4] ~= "" and parts[4] or nil
    local addedBy = parts[5] ~= "" and parts[5] or nil
    local addedDate = tonumber(parts[6]) or 0
    local totalKills = tonumber(parts[7]) or 0

    local existing = Deadpool.db.kosList[fullName]
    if not existing then
        Deadpool.db.kosList[fullName] = {
            name = Deadpool:ShortName(fullName),
            realm = fullName:match("%-(.+)$") or "",
            class = class,
            level = level > 0 and level or nil,
            addedBy = addedBy,
            addedDate = addedDate,
            reason = reason,
            totalKills = totalKills,
            lastKilledBy = nil,
            lastKilledTime = 0,
            lastSeenZone = nil,
            lastSeenTime = 0,
        }
    else
        if totalKills > (existing.totalKills or 0) then
            existing.totalKills = totalKills
        end
        if class and not existing.class then existing.class = class end
        if level > 0 and (not existing.level or existing.level == 0) then
            existing.level = level
        end
    end
end

function Sync:HandleSyncBounty(data, sender)
    local parts = decode(data)
    local fullName = parts[1]
    if not fullName or fullName == "" then return end

    local gold = tonumber(parts[2]) or 0
    local maxKills = tonumber(parts[3]) or 10
    local currentKills = tonumber(parts[4]) or 0
    local placedDate = tonumber(parts[5]) or 0
    local expired = parts[6] == "1"
    local bountyPoints = tonumber(parts[7]) or 0
    local bountyType = (bountyPoints > 0 and gold == 0) and "points" or "gold"

    local existing = Deadpool.db.bounties[fullName]
    if not existing then
        Deadpool.db.bounties[fullName] = {
            target = fullName,
            bountyGold = gold,
            bountyPoints = bountyPoints,
            bountyType = bountyType,
            placedDate = placedDate,
            maxKills = maxKills,
            currentKills = currentKills,
            expired = expired,
            claims = {},
        }
    else
        if currentKills > (existing.currentKills or 0) then
            existing.currentKills = currentKills
        end
        if gold > (existing.bountyGold or 0) then
            existing.bountyGold = gold
        end
        if bountyPoints > (existing.bountyPoints or 0) then
            existing.bountyPoints = bountyPoints
        end
        if expired and not existing.expired then
            existing.expired = true
        end
    end
end

function Sync:HandleSyncScore(data, sender)
    local parts = decode(data)
    local fullName = parts[1]
    if not fullName or fullName == "" then return end

    if not Deadpool:IsGuildMember(fullName) then return end

    local totalKills = tonumber(parts[2]) or 0
    local bountyKills = tonumber(parts[3]) or 0
    local kosKills = tonumber(parts[4]) or 0
    local totalPoints = tonumber(parts[5]) or 0

    -- Block score sync for 24 hours after a reset to prevent old data merging back
    local resetAt = Deadpool.db.guildConfig.scoreboardResetAt or 0
    if resetAt > 0 and (time() - resetAt) < 86400 then
        return
    end

    local score = Deadpool:GetOrCreateScore(fullName)
    if totalKills > (score.totalKills or 0) then score.totalKills = totalKills end
    if bountyKills > (score.bountyKills or 0) then score.bountyKills = bountyKills end
    if kosKills > (score.kosKills or 0) then score.kosKills = kosKills end
    if totalPoints > (score.totalPoints or 0) then score.totalPoints = totalPoints end
end

function Sync:HandleSyncKill(data, sender)
    local parts = decode(data)
    local killer = parts[1]
    local victim = parts[2]
    if not killer or killer == "" or not victim or victim == "" then return end

    local victimLevel = tonumber(parts[3]) or 0
    local zone = parts[4] or "Unknown"
    local killTime = tonumber(parts[5]) or 0
    local killType = parts[6] or "random"

    -- Deduplicate
    for _, existing in ipairs(Deadpool.db.killLog) do
        if existing.killer == killer and existing.victim == victim
            and existing.time and killTime > 0 and math.abs((existing.time or 0) - killTime) < 10 then
            return
        end
    end

    Deadpool:AddKillLogEntry({
        killer = killer,
        victim = victim,
        victimLevel = victimLevel > 0 and victimLevel or nil,
        zone = zone,
        time = killTime,
        isKOS = (killType == "kos" or killType == "bounty"),
        isBounty = (killType == "bounty"),
        killType = killType,
    })
end

----------------------------------------------------------------------
-- KOS sighting broadcast: alert all guild members when someone
-- spots a KOS target in the combat log
----------------------------------------------------------------------
function Deadpool:BroadcastSighting(fullName, zone)
    local entry = self:GetKOSEntry(fullName)
    if not entry then return end
    local data = table.concat({
        fullName,
        entry.class or "",
        zone or "",
        self:HasActiveBounty(fullName) and tostring(self:GetBounty(fullName).bountyGold) or "0",
    }, "|")
    Sync:Send(MSG.SIGHTING, data)
end

function Sync:HandleSighting(data, sender)
    local parts = {}
    for part in (data .. "|"):gmatch("(.-)|" ) do
        table.insert(parts, part)
    end
    local fullName = parts[1]
    local class = parts[2] ~= "" and parts[2] or nil
    local zone = parts[3] ~= "" and parts[3] or "Unknown"
    local bountyGold = tonumber(parts[4]) or 0

    if not fullName or fullName == "" then return end

    local senderShort = sender:match("^(.-)%-") or sender

    -- Update sighting data
    if Deadpool:IsKOS(fullName) then
        Deadpool:UpdateKOSSighting(fullName, zone)
    end

    -- Show alert to this player
    local display = class and Deadpool:ClassColor(class, Deadpool:ShortName(fullName)) or Deadpool:ShortName(fullName)
    local bountyTag = ""
    if bountyGold > 0 then
        bountyTag = Deadpool.colors.gold .. " [BOUNTY: " .. bountyGold .. "g]|r"
    end

    Deadpool:Print(Deadpool.colors.red .. "GUILD ALERT|r — " ..
        Deadpool.colors.cyan .. senderShort .. "|r spotted " ..
        display .. bountyTag .. " in " ..
        Deadpool.colors.yellow .. zone .. "|r")

    -- Play sound
    if Deadpool.db.settings.alertSound then
        PlaySound(8959)
    end

    -- Show visual alert
    if Deadpool.ShowKOSAlert and Deadpool:IsKOS(fullName) then
        local entry = Deadpool:GetKOSEntry(fullName)
        if entry then
            Deadpool:ShowKOSAlert(fullName, entry)
        end
    end

    if Deadpool.RefreshUI then Deadpool:RefreshUI() end
end

function Sync:HandleVersion(data, sender)
    if data and data ~= Deadpool.version then
        Deadpool:Debug(sender .. " is running Deadpool v" .. data .. " (we have v" .. Deadpool.version .. ")")
    end
end

----------------------------------------------------------------------
-- GM Config sync: point values managed by GM, timestamp-based resolution
----------------------------------------------------------------------
function Deadpool:BroadcastGMConfig()
    if not self:IsManager() then
        self:Print(Deadpool.colors.red .. "Only managers can push config changes.|r")
        return
    end
    local gc = self.db.guildConfig
    gc.updatedBy = self:GetPlayerFullName()
    gc.updatedAt = time()
    -- Serialize managers list
    local mgrList = ""
    if gc.managers then
        local names = {}
        for n in pairs(gc.managers) do names[#names + 1] = n end
        mgrList = table.concat(names, ",")
    end
    -- Serialize war guilds list
    local warList = ""
    if gc.warGuilds then
        local guilds = {}
        for g in pairs(gc.warGuilds) do guilds[#guilds + 1] = g end
        warList = table.concat(guilds, ",")
    end
    local data = table.concat({
        gc.pointsPerKill or 5,
        gc.pointsPerKOSKill or 25,
        gc.pointsPerBountyKill or 100,
        gc.pointsUnderdogMultiplier3 or 2.0,
        gc.pointsUnderdogMultiplier6 or 3.0,
        gc.pointsLowbieFloor or 1,
        gc.updatedBy or "",
        gc.updatedAt or 0,
        mgrList,
        warList,
        gc.scoreboardResetAt or 0,
        gc.killLogResetAt or 0,
    }, "|")
    Sync:Send(MSG.GM_CONFIG, data)
    self:Print(Deadpool.colors.gold .. "Guild config pushed to all members.|r")
end

function Sync:HandleGMConfig(data, sender)
    local parts = {}
    for part in (data .. "|"):gmatch("(.-)|") do
        table.insert(parts, part)
    end

    local remoteTimestamp = tonumber(parts[8]) or 0
    local localTimestamp = Deadpool.db.guildConfig.updatedAt or 0

    -- Only accept if remote is newer
    if remoteTimestamp <= localTimestamp then
        Deadpool:Debug("GM config from " .. sender .. " is older than ours, ignoring")
        return
    end

    Deadpool.db.guildConfig.pointsPerKill = tonumber(parts[1]) or 5
    Deadpool.db.guildConfig.pointsPerKOSKill = tonumber(parts[2]) or 25
    Deadpool.db.guildConfig.pointsPerBountyKill = tonumber(parts[3]) or 100
    Deadpool.db.guildConfig.pointsUnderdogMultiplier3 = tonumber(parts[4]) or 2.0
    Deadpool.db.guildConfig.pointsUnderdogMultiplier6 = tonumber(parts[5]) or 3.0
    Deadpool.db.guildConfig.pointsLowbieFloor = tonumber(parts[6]) or 1
    Deadpool.db.guildConfig.updatedBy = parts[7] or sender
    Deadpool.db.guildConfig.updatedAt = remoteTimestamp

    -- Deserialize managers list
    local mgrStr = parts[9] or ""
    Deadpool.db.guildConfig.managers = {}
    if mgrStr ~= "" then
        for name in mgrStr:gmatch("([^,]+)") do
            Deadpool.db.guildConfig.managers[name] = true
        end
    end

    -- Deserialize war guilds list
    local warStr = parts[10] or ""
    Deadpool.db.guildConfig.warGuilds = {}
    if warStr ~= "" then
        for guild in warStr:gmatch("([^,]+)") do
            Deadpool.db.guildConfig.warGuilds[guild] = true
        end
    end

    -- Check for scoreboard reset signal
    local remoteScoreReset = tonumber(parts[11]) or 0
    local localScoreReset = Deadpool.db.guildConfig.scoreboardResetAt or 0
    if remoteScoreReset > localScoreReset then
        Deadpool.db.guildConfig.scoreboardResetAt = remoteScoreReset
        Deadpool.db.scoreboard = {}
        Deadpool:Print(Deadpool.colors.red .. "Scoreboard reset by GM — scores wiped.|r")
    end

    -- Check for kill log reset signal
    local remoteKillReset = tonumber(parts[12]) or 0
    local localKillReset = Deadpool.db.guildConfig.killLogResetAt or 0
    if remoteKillReset > localKillReset then
        Deadpool.db.guildConfig.killLogResetAt = remoteKillReset
        Deadpool.db.killLog = {}
        Deadpool.db.deathLog = {}
        Deadpool:Print(Deadpool.colors.red .. "Kill log reset by GM — logs wiped.|r")
    end

    local senderShort = sender:match("^(.-)%-") or sender
    Deadpool:Print(Deadpool.colors.gold .. "Guild config updated by " .. senderShort .. "|r")
    if Deadpool.RefreshUI then Deadpool:RefreshUI() end
end

----------------------------------------------------------------------
-- Heartbeat: if someone's sync version is higher than ours,
-- we're behind and need to pull from them
----------------------------------------------------------------------
function Sync:HandleHeartbeat(data, sender)
    local remoteVersion = tonumber(data) or 0
    local myVersion = Deadpool.db.syncVersion or 0
    if remoteVersion > myVersion then
        Deadpool:Debug("Heartbeat from " .. sender .. " has v" .. remoteVersion .. " (we have v" .. myVersion .. ") — requesting sync")
        -- Targeted sync request to that specific person
        local now = time()
        if (now - syncThrottle) >= SYNC_COOLDOWN then
            syncThrottle = now
            Sync:Send(MSG.SYNC_REQ, tostring(myVersion), sender)
        end
    end
end

----------------------------------------------------------------------
-- Roster tracking: detect new guild members coming online
----------------------------------------------------------------------
function Sync:SnapshotOnlineRoster()
    onlineGuildMembers = {}
    local numTotal = GetNumGuildMembers()
    for i = 1, numTotal do
        local name, _, _, _, _, _, _, _, online = GetGuildRosterInfo(i)
        if name and online then
            onlineGuildMembers[name] = true
        end
    end
end

function Sync:CheckForNewOnlineMembers()
    local numTotal = GetNumGuildMembers()
    local currentOnline = {}
    for i = 1, numTotal do
        local name, _, _, _, _, _, _, _, online = GetGuildRosterInfo(i)
        if name and online then
            currentOnline[name] = true
            -- If this member wasn't online before, they just logged in
            if not onlineGuildMembers[name] then
                local myName = Deadpool:GetPlayerFullName()
                if name ~= UnitName("player") and name ~= myName then
                    Deadpool:Debug(name .. " came online — sending push offer")
                    -- Send them a push offer with our version
                    -- They'll respond with SYNC_REQ if they want our data
                    C_Timer.After(3, function()
                        Sync:Send(MSG.PUSH, tostring(Deadpool.db.syncVersion or 0), name)
                    end)
                end
            end
        end
    end
    onlineGuildMembers = currentOnline
end

----------------------------------------------------------------------
-- Pre-logout: blast our full state to guild channel
-- Anyone online absorbs it; nobody online = data safe in our
-- SavedVariables and we'll push on next login
----------------------------------------------------------------------
function Sync:PushFullStateToGuild()
    -- Can't use C_Timer here (we're logging out), so send synchronously
    for fullName, entry in pairs(Deadpool.db.kosList) do
        local reason = entry.reason or ""
        if #reason > 20 then reason = reason:sub(1, 20) end
        local data = encode(fullName, entry.class or "", entry.level or 0,
            reason, entry.addedBy or "", entry.addedDate or 0, entry.totalKills or 0)
        Sync:Send(MSG.SYNC_KOS, data)
    end
    -- Skip scoreboard during 24hr reset window
    local resetAt = Deadpool.db.guildConfig.scoreboardResetAt or 0
    if resetAt == 0 or (time() - resetAt) >= 86400 then
        for fullName, score in pairs(Deadpool.db.scoreboard) do
            local data = encode(fullName, score.totalKills or 0, score.bountyKills or 0,
                score.kosKills or 0, score.totalPoints or 0)
            Sync:Send(MSG.SYNC_SCR, data)
        end
    end
end
