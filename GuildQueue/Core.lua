local addonName, ns = ...
local events = CreateFrame("Frame")
local guildIdentityReady = false
local pendingStateAt, pendingHello, pendingPresence = nil, false, false
local lastAttempt, lastSent, lastHello, lastPresence, lastHelloReply = -100, -100, -100, -100, -100
local presence = {}
local registered, started = false, false
local transportError
local lastPartyInviteAt = -100
ns.queued = false
ns.state = ns.State.New()
ns.groups, ns.individuals = {}, {}
ns.questing = ns.Questing.New()
local guildMembers, localQuests, questTitles = {}, nil, {}
local localZoneID, localZoneName, localLevel = 0, "", 0
local localDirty, lastLocalScan, lastRosterRequest = true, -100, -100
local questBatch, questBatchIndex, questBatchSignature = nil, 1, nil
local questSentSignature, questStopPending = nil, false
local lastQuestSent, lastQuestPrepared = -100, -100

local function secret(...)
    return hasanysecretvalues and hasanysecretvalues(...)
end

local function printMessage(message)
    DEFAULT_CHAT_FRAME:AddMessage("|cffffd100Guild Queue:|r " .. message)
end

local function normalize(name)
    if secret(name) or type(name) ~= "string" or name == "" then
        return nil
    end
    name = name:match("^%s*(.-)%s*$")
    local character, realm = name:match("^([^%s%-]+)%-(.+)$")
    if not character then
        -- Some client name surfaces use "Character Realm" instead of a hyphen.
        -- Character names contain no spaces; keep the entire remaining realm.
        character, realm = name:match("^([^%s%-]+)%s+(.+)$")
    end
    if not character then
        character, realm = name, ns.realm
    end
    if character == "" or character:find("[%s%-]") or not realm then
        return nil
    end
    realm = realm:gsub("%s", "")
    if realm == "" then return nil end
    return character .. "-" .. realm
end

-- Optional APIs must not gate the dungeon queue or expose secret values.
local function safeCall(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(fn, ...)
    if ok and not secret(value) then return value end
end

local function boundedNumber(value, minimum, maximum)
    return type(value) == "number" and value >= minimum and value <= maximum and value % 1 == 0
end

local function scanLocalQuests()
    localDirty, lastLocalScan = false, GetTime()
    localZoneID = safeCall(C_Map and C_Map.GetBestMapForUnit, "player")
    if not boundedNumber(localZoneID, 1, 2147483647) then localZoneID = 0 end
    -- A cave/micro-map belongs to its parent zone. Never compare continent IDs.
    if C_Map and C_Map.GetMapInfo then
        for _ = 1, 8 do
            local info = safeCall(C_Map.GetMapInfo, localZoneID)
            if type(info) ~= "table" or secret(info.mapType, info.parentMapID) then break end
            local zoneType = Enum and Enum.UIMapType and Enum.UIMapType.Zone or 3
            if boundedNumber(info.mapType, 0, zoneType - 1) then localZoneID = 0 break end
            if not boundedNumber(info.mapType, zoneType + 1, 100)
                or not boundedNumber(info.parentMapID, 1, 2147483647) then break end
            localZoneID = info.parentMapID
        end
    end
    local info = localZoneID > 0 and safeCall(C_Map and C_Map.GetMapInfo, localZoneID)
    localZoneName = type(info) == "table" and not secret(info.name) and info.name or nil
    if type(localZoneName) ~= "string" or localZoneName == "" then
        localZoneName = safeCall(GetRealZoneText) or ""
    end
    localLevel = safeCall(UnitLevel, "player")
    if not boundedNumber(localLevel, 0, 1000) then localLevel = 0 end
    localQuests, questTitles = nil, {}
    if not C_QuestLog or type(C_QuestLog.GetInfo) ~= "function"
        or type(C_QuestLog.IsComplete) ~= "function" then return end
    local count = safeCall(C_QuestLog.GetNumQuestLogEntries)
    if not boundedNumber(count, 0, 1000) then return end
    local quests, titles, total = {}, {}, 0
    for index = 1, count do
        local quest = safeCall(C_QuestLog.GetInfo, index)
        if type(quest) ~= "table" or secret(quest.isHeader, quest.isHidden, quest.questID, quest.title) then return end
        if not quest.isHeader and not quest.isHidden then
            if not boundedNumber(quest.questID, 1, 2147483647) then return end
            local complete = safeCall(C_QuestLog.IsComplete, quest.questID)
            if type(complete) ~= "boolean" then return end
            quests[quest.questID] = complete
            titles[quest.questID] = type(quest.title) == "string" and quest.title or ("Quest " .. quest.questID)
            total = total + 1
            if total > 200 then return end
        end
    end
    localQuests, questTitles = quests, titles
end

local function scanGuildMembers()
    guildMembers = {}
    if not ns.IsReady() or type(GetGuildRosterInfo) ~= "function" then return end
    local count = safeCall(GetNumGuildMembers)
    if not boundedNumber(count, 0, 10000) then return end
    for index = 1, count do
        local ok, name, _, _, level, _, area, _, _, online = pcall(GetGuildRosterInfo, index)
        if ok and not secret(name, level, area, online) and online then
            name = normalize(name)
            if name and name:lower() ~= ns.playerName:lower() then
                guildMembers[name:lower()] = { name = name,
                    level = boundedNumber(level, 0, 1000) and level or 0,
                    area = type(area) == "string" and area or "" }
            end
        end
    end
end

function ns.QuestingZoneText()
    return localZoneName ~= "" and localZoneName or "Unknown zone"
end

function ns.GetQuestingPlayers()
    if not ns.IsReady() then return {} end
    local now, rows, byName = GetServerTime(), {}, {}
    for key, member in pairs(guildMembers) do
        byName[key] = { name = member.name, level = member.level,
            sameZone = localZoneName ~= "" and member.area == localZoneName }
    end
    for name, peer in pairs(ns.questing.peers) do
        if now - peer.sentAt < ns.TIMEOUT and name:lower() ~= ns.playerName:lower() then
            local key = name:lower()
            local row = byName[key] or { name = name }
            byName[key] = row
            row.level, row.peer = peer.level, peer
            if localZoneID > 0 and peer.zoneID > 0 then
                row.sameZone = peer.zoneID == localZoneID
            end
        end
    end
    for _, row in pairs(byName) do
        if row.sameZone then
            if row.peer and localQuests then
                row.shared = ns.Questing.Common(localQuests, row.peer.quests)
                for _, quest in ipairs(row.shared) do
                    quest.title = questTitles[quest.questID] or ("Quest " .. quest.questID)
                end
            end
            rows[#rows + 1] = row
        end
    end
    table.sort(rows, function(a, b) return a.name < b.name end)
    return rows
end

function ns.SetQuestSharing(wanted)
    wanted = wanted == true
    if ns.prefs.shareQuests == wanted then return end
    ns.prefs.shareQuests = wanted
    -- Never let an already prepared snapshot escape after consent is withdrawn.
    questBatch, questBatchSignature, questSentSignature = nil, nil, nil
    questStopPending = not wanted
    lastQuestSent, lastQuestPrepared, localDirty = -100, -100, true
    ns.RefreshUI()
end

local function rebuild()
    ns.groups, ns.individuals = ns.Match(ns.state)
    ns.RefreshUI()
end

local function requestState(delay)
    local due = GetTime() + (delay or 0)
    pendingStateAt = math.min(pendingStateAt or due, due)
end

function ns.IsReady()
    return registered and IsInGuild() and guildIdentityReady and ns.playerName ~= nil
end

function ns.OnlineAddonCount()
    if not ns.IsReady() then
        return 0
    end
    local now, count = GetServerTime(), 1
    for _, seenAt in pairs(presence) do
        if now - seenAt < ns.TIMEOUT then
            count = count + 1
        end
    end
    return count
end

function ns.StatusText()
    if not registered then
        return "Addon messaging could not be registered."
    elseif not IsInGuild() then
        return "Join a guild to use the queue."
    elseif not ns.playerName then
        return "Waiting for your character name and realm."
    elseif not guildIdentityReady then
        return "Waiting for guild information. Try opening the Guild window."
    elseif transportError then
        return transportError
    end
    return "Guild members with this addon only. Select roles and dungeons, then join."
end

function ns.JoinQueueDisabledReason()
    if not ns.IsReady() then
        return ns.StatusText()
    end
    if not ns.Protocol.ValidSelections(ns.prefs.roles, ns.prefs.dungeons) then
        return "Select at least one role and one dungeon."
    end
end

-- Used both by the disabled-button tooltip and immediately before a click action.
function ns.CreatePartyDisabledReason(group)
    local homeGroup = IsInGroup(LE_PARTY_CATEGORY_HOME)
    local instanceGroup = IsInGroup(LE_PARTY_CATEGORY_INSTANCE)
    if secret(homeGroup, instanceGroup) then
        return "Your party status is unavailable right now."
    end
    if homeGroup or instanceGroup then
        return "You are already in a party or raid. Leave your current group to create a new party."
    end
    if InCombatLockdown() then
        return "You cannot create a party during combat."
    end
    if not C_PartyInfo or not C_PartyInfo.InviteUnit then
        return "Party invitations are unavailable on this client."
    end
    if not ns.IsReady() then
        return "Your guild queue is not ready yet."
    end
    local current = false
    for _, suggestion in ipairs(ns.groups) do
        if suggestion == group then
            current = true
            break
        end
    end
    if not current then
        return "This suggested group has changed. Wait for the queue to refresh."
    end
    local includesPlayer, names = false, {}
    if #group.slots ~= 5 then
        return "This suggested group is incomplete."
    end
    for _, player in ipairs(group.slots) do
        local record = ns.state.records[player.name]
        if names[player.name] or not record
            or GetServerTime() - record.sentAt >= ns.TIMEOUT then
            return "This suggested group is no longer available. Wait for the queue to refresh."
        end
        names[player.name] = true
        includesPlayer = includesPlayer or player.name == ns.playerName
    end
    if not includesPlayer then
        return "You can only create a party for your own suggested group."
    end
    if GetTime() - lastPartyInviteAt < 5 then
        return "Invitations were just requested. Wait a few seconds before trying again."
    end
end

-- Called only by the Create party button's OnClick, never by matching or timers.
-- Submit all four requests together; the party may appear after the first request.
function ns.CreateParty(group)
    local reason = ns.CreatePartyDisabledReason(group)
    if reason then
        printMessage(reason)
        ns.RefreshUI()
        return false
    end
    local targets = {}
    for _, player in ipairs(group.slots) do
        if player.name ~= ns.playerName then
            targets[#targets + 1] = player.name
        end
    end
    lastPartyInviteAt = GetTime()
    local requested = 0
    for _, name in ipairs(targets) do
        if pcall(C_PartyInfo.InviteUnit, name) then
            requested = requested + 1
        end
    end
    if requested == 4 then
        printMessage("Party invitations requested. Players must accept; leave the queue once grouped.")
    else
        printMessage("Some invitation requests could not be submitted. Check WoW's messages before trying again.")
    end
    ns.RefreshUI()
    return requested == 4
end

function ns.SetQueued(wanted)
    if wanted then
        local reason = ns.JoinQueueDisabledReason()
        if reason then
            printMessage(reason)
            return
        end
        if not ns.queued then
            ns.joinedAt = GetServerTime()
        end
        ns.queued = true
        printMessage("Queue requested. Use Create party on your suggested group to invite its members.")
    else
        ns.queued, ns.joinedAt = false, nil
        -- Withdraw locally immediately, even if transport is currently blocked.
        ns.state.records[ns.playerName or ""] = nil
        rebuild()
        printMessage("Left the queue. Other clients update on delivery or within 75 seconds.")
    end
    requestState(0)
    ns.RefreshUI()
end

function ns.PreferencesChanged()
    if ns.queued then
        if ns.Protocol.ValidSelections(ns.prefs.roles, ns.prefs.dungeons) then
            requestState(0)
        else
            ns.SetQueued(false)
        end
    end
    ns.RefreshUI()
end

local function identifyPlayer()
    local name, realm = UnitFullName("player")
    if secret(name, realm) or not name then
        return
    end
    realm = realm ~= "" and realm or GetNormalizedRealmName()
    if secret(realm) or not realm or realm == "" then
        return
    end
    ns.realm = realm:gsub("%s", "")
    -- UnitFullName normally returns a short name, but do not double-qualify
    -- clients that already include the realm in the first return value.
    ns.playerName = normalize(name)
    if ns.playerName then
        ns.realm = ns.playerName:match("^[^%-]+%-(.+)$")
    end
end

local function applyGuildIdentity(guildName, guildRealm)
    local key = guildName and (guildName .. "-" .. (guildRealm or ns.realm or "")) or nil
    if key ~= ns.guildKey then
        ns.guildKey, ns.guildName = key, guildName
        ns.queued, ns.joinedAt = false, nil
        ns.state = ns.State.New()
        pendingStateAt, pendingHello, pendingPresence = nil, key ~= nil, key ~= nil
        lastHello, lastPresence, lastHelloReply = -100, -100, -100
        presence, guildMembers = {}, {}
        ns.questing = ns.Questing.New()
        questBatch, questBatchSignature, questSentSignature = nil, nil, nil
        questStopPending, localDirty = false, true
        lastQuestSent, lastQuestPrepared, lastRosterRequest = -100, -100, -100
        transportError = nil
        if key then
            -- A new revision tombstone clears any pre-reload queue entry.
            requestState(0)
        end
        rebuild()
    end
end

local function updateGuild(clearIfUnresolved)
    if not ns.playerName then
        identifyPlayer()
    end
    guildIdentityReady = false
    if not IsInGuild() then
        applyGuildIdentity(nil)
        return
    end
    local guildName, _, _, guildRealm = GetGuildInfo("player")
    if secret(guildName, guildRealm) or not guildName then
        -- Preserve state through a transient loading screen, but do not send or
        -- accept messages until we can confirm which guild we belong to.
        -- A membership-change event with unresolved identity must discard old data.
        if clearIfUnresolved then
            applyGuildIdentity(nil)
        end
        return
    end
    guildIdentityReady = true
    applyGuildIdentity(guildName, guildRealm)
end

local function send(message)
    if C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() then
        transportError = "Addon messaging is restricted right now; retrying when allowed."
        return false
    end
    local ok, result = pcall(C_ChatInfo.SendAddonMessage, ns.PREFIX, message, "GUILD")
    local success = Enum and Enum.SendAddonMessageResult and Enum.SendAddonMessageResult.Success or 0
    if not ok or result ~= success then
        -- Do not print raw API error strings or payloads.
        transportError = "Guild message could not be sent (account/server restriction or throttling); retrying."
        return false
    end
    transportError = nil
    return true
end

local function sendState()
    local now = GetServerTime()
    -- Persist only preferences and an ordering counter, never active queue membership.
    -- Server-time seeding also helps when the character logs in on another computer.
    ns.prefs.revision = math.max(ns.prefs.revision, now * 1000) + 1
    local packet = { kind = ns.queued and "S" or "X", revision = ns.prefs.revision, sentAt = now }
    if ns.queued then
        packet.joinedAt, packet.roles, packet.dungeons = ns.joinedAt, ns.prefs.roles, ns.prefs.dungeons
    end
    if send(ns.Protocol.Encode(packet)) then
        pendingStateAt, lastSent, lastPresence = nil, GetTime(), GetTime()
        pendingPresence = false
        if ns.state:Apply(ns.playerName, packet, now) then
            rebuild()
        end
        return true
    end
    return false
end

local function nextRevision()
    ns.prefs.revision = math.max(ns.prefs.revision, GetServerTime() * 1000) + 1
    return ns.prefs.revision
end

local function prepareQuestBatch(clock)
    if questBatch or not ns.prefs.shareQuests or not localQuests
        or clock - lastQuestPrepared < 5 then return end
    local ids, parts = {}, { tostring(localZoneID), tostring(localLevel) }
    for id in pairs(localQuests) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        parts[#parts + 1] = tostring(id) .. (localQuests[id] and ":1" or ":0")
    end
    local signature = table.concat(parts, ",")
    if signature ~= questSentSignature or clock - lastQuestSent >= ns.HEARTBEAT then
        questBatch = ns.Questing.Encode(nextRevision(), GetServerTime(), localZoneID, localLevel, localQuests)
        questBatchIndex, questBatchSignature, lastQuestPrepared = 1, signature, clock
    end
end

local function sendQuestPart(clock)
    if questStopPending then
        if send(ns.Questing.EncodeStop(nextRevision(), GetServerTime())) then
            questStopPending = false
        end
    elseif questBatch then
        -- Do not retry an expired multipart snapshot indefinitely after a restriction.
        local packet = ns.Questing.Decode(questBatch[questBatchIndex])
        if GetServerTime() - packet.sentAt >= ns.TIMEOUT then
            questBatch = nil
            return
        end
        if send(questBatch[questBatchIndex]) then
            questBatchIndex = questBatchIndex + 1
            if questBatchIndex > #questBatch then
                questBatch, questSentSignature, lastQuestSent = nil, questBatchSignature, clock
            end
        end
    end
end

local function tick()
    if not started then
        return
    end
    local clock = GetTime()
    updateGuild()
    if localDirty or clock - lastLocalScan >= ns.HEARTBEAT then scanLocalQuests() end
    local serverNow = GetServerTime()
    ns.questing:Prune(serverNow)
    if ns.state:Prune(serverNow) then
        rebuild()
    end
    for name, seenAt in pairs(presence) do
        if serverNow - seenAt >= ns.TIMEOUT then
            presence[name] = nil
        end
    end
    if not ns.IsReady() then
        ns.RefreshUI()
        return
    end
    if clock - lastRosterRequest >= 30 then
        lastRosterRequest = clock
        safeCall(C_GuildInfo and C_GuildInfo.GuildRoster)
    end
    prepareQuestBatch(clock)
    if ns.queued and clock - lastSent >= ns.HEARTBEAT then
        requestState(0)
    elseif not ns.queued and clock - lastPresence >= ns.HEARTBEAT then
        pendingPresence = true
    end
    -- At most one outgoing message per second; failures back off for five seconds.
    local interval = transportError and 5 or 1
    if clock - lastAttempt >= interval then
        if pendingStateAt and pendingStateAt <= clock then
            lastAttempt = clock
            sendState()
        elseif questStopPending then
            lastAttempt = clock
            sendQuestPart(clock)
        elseif pendingHello and clock - lastHello >= 15 then
            lastAttempt = clock
            if send(ns.Protocol.Encode({ kind = "H" })) then
                pendingHello, lastHello = false, clock
            end
        elseif pendingPresence then
            lastAttempt = clock
            if send(ns.Protocol.Encode({ kind = "P" })) then
                pendingPresence, lastPresence = false, clock
            end
        elseif questBatch then
            lastAttempt = clock
            sendQuestPart(clock)
        end
    end
    ns.RefreshUI()
end

local function receive(prefix, message, channel, sender)
    if secret(prefix, message, channel, sender)
        or prefix ~= ns.PREFIX or channel ~= "GUILD" then
        return
    end
    -- WoW's server restricts GUILD addon delivery to guild members. Use that
    -- transport boundary, never a claimed payload identity or another channel.
    -- A separate GetGuildRosterInfo cache is not required to join or synchronize.
    updateGuild()
    if not ns.IsReady() then
        return
    end
    local name = normalize(sender)
    if not name or name:lower() == ns.playerName:lower() then
        return
    end
    local now = GetServerTime()
    local questPacket = ns.Questing.Decode(message)
    if questPacket then
        if questPacket.sentAt <= now + 5 and now - questPacket.sentAt < ns.TIMEOUT then
            presence[name] = now
            ns.questing:Apply(name, questPacket, now)
            ns.RefreshUI()
        end
        return
    end
    local packet = ns.Protocol.Decode(message)
    if not packet then
        return
    end
    if packet.kind == "H" or packet.kind == "P" then
        presence[name] = now
        if packet.kind == "H" and GetTime() - lastHelloReply >= 5 then
            lastHelloReply = GetTime()
            if ns.queued then requestState(math.random(1, 5)) end
            if ns.prefs.shareQuests then lastQuestSent = -100 end
        end
        ns.RefreshUI()
    elseif packet.sentAt <= now + 5 and now - packet.sentAt < ns.TIMEOUT then
        presence[name] = now
        if ns.state:Apply(name, packet, now) then
            rebuild()
        else
            ns.RefreshUI()
        end
    end
end

local function initialize()
    if type(GuildQueueDB) ~= "table" then
        GuildQueueDB = {}
    end
    ns.prefs = GuildQueueDB
    ns.prefs.shareQuests = ns.prefs.shareQuests == true
    if type(ns.prefs.roles) ~= "number" or ns.prefs.roles ~= ns.prefs.roles
        or ns.prefs.roles < 0 or ns.prefs.roles > 7 or ns.prefs.roles % 1 ~= 0 then
        ns.prefs.roles = 4
    end
    local dungeons = {}
    if type(ns.prefs.dungeons) == "table" then
        for _, dungeon in ipairs(ns.DUNGEONS) do
            if ns.prefs.dungeons[dungeon.id] == true then
                dungeons[dungeon.id] = true
            end
        end
    end
    ns.prefs.dungeons = dungeons
    if type(ns.prefs.revision) ~= "number" or ns.prefs.revision ~= ns.prefs.revision
        or ns.prefs.revision < 0 or ns.prefs.revision > 8000000000000000
        or ns.prefs.revision % 1 ~= 0 then
        ns.prefs.revision = 0
    end
    local ok = pcall(C_ChatInfo.RegisterAddonMessagePrefix, ns.PREFIX)
    registered = ok and C_ChatInfo.IsAddonMessagePrefixRegistered(ns.PREFIX)
end

local function start()
    if started or not ns.prefs then
        return
    end
    started = true
    identifyPlayer()
    updateGuild()
    scanLocalQuests()
    scanGuildMembers()
    ns.ticker = C_Timer.NewTicker(1, tick)
    printMessage("Loaded. Use /gq to open the guild dungeon queue.")
end

events:SetScript("OnEvent", function(_, event, ...)
    if secret(...) then
        return
    end
    if event == "ADDON_LOADED" then
        if ... == addonName then
            initialize()
        end
    elseif event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        start()
    elseif event == "CHAT_MSG_ADDON" then
        receive(...)
    elseif event == "GUILD_ROSTER_UPDATE" then
        if started then
            updateGuild()
            scanGuildMembers()
            ns.RefreshUI()
        end
    elseif event == "QUEST_LOG_UPDATE" or event == "ZONE_CHANGED_NEW_AREA"
        or event == "ZONE_CHANGED" or event == "ZONE_CHANGED_INDOORS" or event == "PLAYER_LEVEL_UP" then
        localDirty = true
    elseif event == "PLAYER_GUILD_UPDATE" then
        local unit = ...
        if started and unit == "player" then
            updateGuild(true)
            ns.RefreshUI()
        end
    elseif event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_REGEN_DISABLED"
        or event == "PLAYER_REGEN_ENABLED" then
        if started then
            ns.RefreshUI()
        end
    elseif event == "PLAYER_LOGOUT" then
        if ns.IsReady() then
            ns.queued = false
            -- Best effort only: peers also expire entries if logout delivery is lost.
            sendState()
        end
    end
end)
for _, event in ipairs({ "ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "CHAT_MSG_ADDON",
    "GUILD_ROSTER_UPDATE", "PLAYER_GUILD_UPDATE", "GROUP_ROSTER_UPDATE",
    "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "PLAYER_LOGOUT", "QUEST_LOG_UPDATE",
    "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED", "ZONE_CHANGED_INDOORS", "PLAYER_LEVEL_UP" }) do
    events:RegisterEvent(event)
end

SLASH_GUILDQUEUE1, SLASH_GUILDQUEUE2 = "/gq", "/guildqueue"
SlashCmdList.GUILDQUEUE = function(command)
    if not started then
        return
    end
    command = command:lower():match("^%s*(.-)%s*$")
    if command == "leave" then
        ns.SetQueued(false)
    elseif command == "join" then
        ns.SetQueued(true)
    elseif command == "status" then
        updateGuild()
        local reason = ns.JoinQueueDisabledReason()
        printMessage(ns.queued and "You have requested to queue. " .. ns.StatusText()
            or reason or "Ready to join. Click Join queue or type /gq join.")
        printMessage("Guild member: " .. (IsInGuild() and "yes" or "no")
            .. "; guild information: " .. (guildIdentityReady and "ready" or "waiting")
            .. "; character information: " .. (ns.playerName and "ready" or "waiting")
            .. "; addon messaging: " .. (registered and "ready" or "unavailable") .. ".")
        ns.RefreshUI()
    else
        ns.ToggleUI()
    end
end
