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
    SYNC_END    = "SYNC_END",   -- sync complete
    VERSION     = "VERSION",    -- version announcement
    HEARTBEAT   = "HB",        -- periodic version heartbeat
    PUSH        = "PUSH",      -- "I have data for you" (version-aware)
    SIGHTING    = "SIGHT",     -- KOS target spotted by a guild member
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

    local channel = target and "WHISPER" or "GUILD"
    if C_ChatInfo and C_ChatInfo.SendAddonMessage then
        C_ChatInfo.SendAddonMessage(Deadpool.prefix, payload, channel, target)
    end
end

----------------------------------------------------------------------
-- Receive handler
----------------------------------------------------------------------
function Sync:OnAddonMessage(message, channel, sender)
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
    local data = encode(fullName, bounty.bountyGold, bounty.maxKills,
        bounty.placedBy or "", bounty.placedDate or 0)
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

    if not fullName or gold <= 0 then return end

    -- Auto-add to KOS if not there
    if not Deadpool:IsKOS(fullName) then
        Deadpool:AddToKOS(fullName, "Bounty target", true)
    end

    if not Deadpool:HasActiveBounty(fullName) then
        Deadpool.db.bounties[fullName] = {
            target = fullName,
            bountyGold = gold,
            placedBy = placedBy,
            placedDate = placedDate,
            maxKills = maxKills,
            currentKills = 0,
            expired = false,
            claims = {},
        }
        Deadpool:Print(Deadpool.colors.gold .. "NEW CONTRACT|r — " ..
            Deadpool:ShortName(fullName) .. " — " .. Deadpool:FormatGold(gold) ..
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
    -- Send our KOS list, bounties, and scoreboard to the requester
    Deadpool:Debug("Sync request from " .. sender .. " — sending data")

    local delay = 0
    local BATCH_DELAY = 0.1  -- stagger messages

    -- Send KOS entries
    for fullName, entry in pairs(Deadpool.db.kosList) do
        C_Timer.After(delay, function()
            local data = encode(fullName, entry.class or "", entry.race or "",
                entry.level or 0, entry.reason or "", entry.addedBy or "",
                entry.addedDate or 0, entry.totalKills or 0)
            Sync:Send(MSG.SYNC_KOS, data, sender)
        end)
        delay = delay + BATCH_DELAY
    end

    -- Send bounties
    for fullName, bounty in pairs(Deadpool.db.bounties) do
        C_Timer.After(delay, function()
            local data = encode(fullName, bounty.bountyGold or 0, bounty.maxKills or 10,
                bounty.currentKills or 0, bounty.placedBy or "", bounty.placedDate or 0,
                bounty.expired and "1" or "0")
            Sync:Send(MSG.SYNC_BNT, data, sender)
        end)
        delay = delay + BATCH_DELAY
    end

    -- Send scoreboard
    for fullName, score in pairs(Deadpool.db.scoreboard) do
        C_Timer.After(delay, function()
            local data = encode(fullName, score.totalKills or 0, score.bountyKills or 0,
                score.kosKills or 0, score.totalPoints or 0, score.bestStreak or 0)
            Sync:Send(MSG.SYNC_SCR, data, sender)
        end)
        delay = delay + BATCH_DELAY
    end

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
    local race = parts[3] ~= "" and parts[3] or nil
    local level = tonumber(parts[4]) or 0
    local reason = parts[5] ~= "" and parts[5] or nil
    local addedBy = parts[6] ~= "" and parts[6] or nil
    local addedDate = tonumber(parts[7]) or 0
    local totalKills = tonumber(parts[8]) or 0

    -- Merge: add if missing, or update if remote has more kills
    local existing = Deadpool.db.kosList[fullName]
    if not existing then
        Deadpool.db.kosList[fullName] = {
            name = Deadpool:ShortName(fullName),
            realm = fullName:match("%-(.+)$") or "",
            class = class,
            race = race,
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
        -- Merge: take highest kill count, update info if we have better data
        if totalKills > (existing.totalKills or 0) then
            existing.totalKills = totalKills
        end
        if class and not existing.class then existing.class = class end
        if race and not existing.race then existing.race = race end
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
    local placedBy = parts[5] ~= "" and parts[5] or nil
    local placedDate = tonumber(parts[6]) or 0
    local expired = parts[7] == "1"

    local existing = Deadpool.db.bounties[fullName]
    if not existing then
        Deadpool.db.bounties[fullName] = {
            target = fullName,
            bountyGold = gold,
            placedBy = placedBy,
            placedDate = placedDate,
            maxKills = maxKills,
            currentKills = currentKills,
            expired = expired,
            claims = {},
        }
    else
        -- Merge: take higher kill/gold counts
        if currentKills > (existing.currentKills or 0) then
            existing.currentKills = currentKills
        end
        if gold > (existing.bountyGold or 0) then
            existing.bountyGold = gold
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

    local totalKills = tonumber(parts[2]) or 0
    local bountyKills = tonumber(parts[3]) or 0
    local kosKills = tonumber(parts[4]) or 0
    local totalPoints = tonumber(parts[5]) or 0
    local bestStreak = tonumber(parts[6]) or 0

    local score = Deadpool:GetOrCreateScore(fullName)
    -- Merge: take highest values
    if totalKills > (score.totalKills or 0) then score.totalKills = totalKills end
    if bountyKills > (score.bountyKills or 0) then score.bountyKills = bountyKills end
    if kosKills > (score.kosKills or 0) then score.kosKills = kosKills end
    if totalPoints > (score.totalPoints or 0) then score.totalPoints = totalPoints end
    if bestStreak > (score.bestStreak or 0) then score.bestStreak = bestStreak end
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
    -- Could check for version mismatches and warn
    if data and data ~= Deadpool.version then
        Deadpool:Debug(sender .. " is running Deadpool v" .. data .. " (we have v" .. Deadpool.version .. ")")
    end
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
    -- Send KOS entries
    for fullName, entry in pairs(Deadpool.db.kosList) do
        local data = encode(fullName, entry.class or "", entry.race or "",
            entry.level or 0, entry.reason or "", entry.addedBy or "",
            entry.addedDate or 0, entry.totalKills or 0)
        Sync:Send(MSG.SYNC_KOS, data)
    end
    -- Send bounties
    for fullName, bounty in pairs(Deadpool.db.bounties) do
        local data = encode(fullName, bounty.bountyGold or 0, bounty.maxKills or 10,
            bounty.currentKills or 0, bounty.placedBy or "", bounty.placedDate or 0,
            bounty.expired and "1" or "0")
        Sync:Send(MSG.SYNC_BNT, data)
    end
    -- Send scoreboard
    for fullName, score in pairs(Deadpool.db.scoreboard) do
        local data = encode(fullName, score.totalKills or 0, score.bountyKills or 0,
            score.kosKills or 0, score.totalPoints or 0, score.bestStreak or 0)
        Sync:Send(MSG.SYNC_SCR, data)
    end
end
