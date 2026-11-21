local addonName, ns = ...
local events = CreateFrame("Frame")
local guildIdentityReady = false
local pendingStateAt, pendingHello, pendingPresence = nil, false, false
local lastAttempt, lastSent, lastHello, lastPresence, lastHelloReply = -100, -100, -100, -100, -100
local presence = {}
local registered, started = false, false
local transportError
local lastPartyInviteAt = -100
local lastMemberInviteAt = {}
local pendingRoleNotices, receivedRoleNotices = {}, {}
local availableRoles
local send, updateGuild, nextRevision, refreshFormationIndexes
local queueRecordNames, matchupByGroup, matchupByKey, matchupByPlayer = {}, {}, {}, {}
local formationClaims, formationByOwner, formationWatermarks, pendingFormationReleases = {}, {}, {}, {}
local formationWatermarkCount, lastFormationFailure = 0, -100
local FORMATION_CACHE_LIMIT, FORMATION_RACE_WINDOW = 256, 5
ns.FORMATION_TIMEOUT = 10
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

-- Class capabilities, not the current assigned party role or specialization.
-- Keep the last valid answer through loading screens; class cannot change in-session.
function ns.AllowedRoles()
    if type(UnitGetAvailableRoles) == "function" then
        local ok, tank, healer, damage = pcall(UnitGetAvailableRoles, "player")
        if ok and not secret(tank, healer, damage) and type(tank) == "boolean"
            and type(healer) == "boolean" and type(damage) == "boolean" then
            local mask = (tank and 1 or 0) + (healer and 2 or 0) + (damage and 4 or 0)
            if mask > 0 then availableRoles = mask end
        end
    end
    return availableRoles
end

function ns.RoleDisabledReason(role)
    local allowed = ns.AllowedRoles()
    if not allowed then return "Waiting for your class role information." end
    if not ns.HasRole(allowed, role) then
        return "Your class cannot queue as " .. (ns.ROLE_NAMES[role] or "this role") .. "."
    end
end

local function restrictRoles()
    local allowed = ns.AllowedRoles()
    if not allowed or not ns.prefs then return false end
    local selected = ns.FilterRoles(ns.prefs.roles, allowed)
    if selected == ns.prefs.roles then return false end
    ns.prefs.roles = selected
    return true
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
    refreshFormationIndexes()
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
    local allowed = ns.AllowedRoles()
    if not allowed then return "Waiting for your class role information." end
    if ns.FilterRoles(ns.prefs.roles, allowed) ~= ns.prefs.roles then
        return "Select only roles available for your class."
    end
    if not ns.Protocol.ValidSelections(ns.prefs.roles, ns.prefs.dungeons) then
        return "Select at least one role and one dungeon."
    end
end

local function ownSelectionsMatch(record)
    if not record or not ns.prefs or record.roles ~= ns.prefs.roles
        or type(record.dungeons) ~= "table" or type(ns.prefs.dungeons) ~= "table" then return false end
    for id, selected in pairs(record.dungeons) do
        if selected and not ns.prefs.dungeons[id] then return false end
    end
    for id, selected in pairs(ns.prefs.dungeons) do
        if selected and not record.dungeons[id] then return false end
    end
    return true
end

function ns.QueueUpdatePending()
    return ns.queued == true and not ownSelectionsMatch(ns.state.records[ns.playerName or ""])
end

local function queueRecordFresh(record, now)
    return type(record) == "table" and type(record.name) == "string"
        and boundedNumber(record.sentAt, 1, math.min(now + 5, 9999999999)) and now - record.sentAt < ns.TIMEOUT
        and ns.Protocol.ValidSelections(record.roles, record.dungeons)
end

local function freshQueueRecord(name, now)
    -- Keep canonical record names rather than references: an ordinary heartbeat
    -- replaces a record without rebuilding unchanged matcher suggestions.
    local recordName = queueRecordNames[name:lower()]
    local record = recordName and ns.state.records[recordName]
    if not queueRecordFresh(record, now) or record.name:lower() ~= name:lower() then return nil end
    return record
end

local function matchupFingerprint(group, now)
    if type(group) ~= "table" or type(group.members) ~= "table"
        or #group.members < 2 or #group.members > 5 then return nil end
    local members, seen = {}, {}
    for _, member in ipairs(group.members) do
        local name = type(member) == "table" and normalize(member.name)
        local record = name and freshQueueRecord(name, now)
        if not record or #name > 128 or name:find("[%c%s|]") or seen[name:lower()]
            or not boundedNumber(record.joinedAt, 1, record.sentAt) then return nil end
        local key = name:lower()
        seen[key] = true
        members[#members + 1] = { name = key, record = record }
    end
    table.sort(members, function(a, b) return a.name < b.name end)
    local parts = { tostring(#members) }
    for _, member in ipairs(members) do
        local record, ids = member.record, {}
        for id, selected in pairs(record.dungeons) do
            if selected then ids[#ids + 1] = id end
        end
        table.sort(ids)
        parts[#parts + 1] = tostring(#member.name) .. ":" .. member.name
        parts[#parts + 1] = string.format("%.0f", record.joinedAt)
        parts[#parts + 1] = tostring(record.roles)
        parts[#parts + 1] = table.concat(ids, ",")
    end
    local text, first, second = table.concat(parts, "|"), 0, 0
    for index = 1, #text do
        local byte = text:byte(index)
        -- Both products stay below 2^53, including on Lua's double numbers.
        first = (first * 131 + byte) % 2147483647
        second = (second * 65599 + byte) % 2147483647
    end
    return string.format("%08x%08x", first, second), seen
end

local function currentMatchup(subject, now)
    local entry
    if type(subject) == "table" then
        entry = matchupByGroup[subject]
    elseif type(subject) == "string" then
        local name = normalize(subject)
        entry = name and matchupByPlayer[name:lower()]
    end
    if entry and matchupByKey[entry.key] == entry
        and matchupFingerprint(entry.group, now) == entry.key then return entry end
end

function ns.MatchupKey(group)
    local entry = currentMatchup(group, GetServerTime())
    return entry and entry.key
end

local function formationWinner(entry, now)
    local winner
    for _, claim in pairs(formationClaims[entry.key] or {}) do
        if claim.deadline > now and not claim.released and entry.members[claim.owner:lower()]
            and (not winner or claim.sentAt < winner.sentAt
                or (claim.sentAt == winner.sentAt and (claim.owner:lower() < winner.owner:lower()
                    or (claim.owner:lower() == winner.owner:lower() and claim.claimID < winner.claimID)))) then
            winner = claim
        end
    end
    return winner
end

function ns.FormationStatus(subject)
    if not ns.IsReady() then return nil end
    local now = GetServerTime()
    local entry = currentMatchup(subject, now)
    local winner = entry and formationWinner(entry, now)
    if winner then
        return { owner = winner.owner, remaining = math.ceil(winner.deadline - now),
            isOwner = winner.owner:lower() == ns.playerName:lower(), key = entry.key }
    end
end

function ns.FormationDisabledReason(subject)
    local status = ns.FormationStatus(subject)
    if status and not status.isOwner then
        return ns.SafeText(status.owner) .. " is inviting this matchup (" .. status.remaining .. "s remaining).", status
    end
    return nil, status
end

local function retireFormation(claim)
    claim.released = true
    local owner = claim.owner:lower()
    local claims = formationClaims[claim.key]
    if claims and claims[owner] == claim then
        claims[owner] = nil
        if not next(claims) then formationClaims[claim.key] = nil end
    end
    if formationByOwner[owner] == claim then formationByOwner[owner] = nil end
    local watermark = formationWatermarks[owner]
    if watermark and watermark.claimID == claim.claimID and watermark.key == claim.key then
        watermark.released = true
    end
end

local function pruneFormations(now)
    for _, claim in pairs(formationByOwner) do
        local entry = matchupByKey[claim.key]
        if claim.deadline <= now or not entry or not currentMatchup(entry.group, now) then
            retireFormation(claim)
        end
    end
    for owner, watermark in pairs(formationWatermarks) do
        if watermark.expiresAt <= now then
            formationWatermarks[owner] = nil
            formationWatermarkCount = formationWatermarkCount - 1
        end
    end
    for index = #pendingFormationReleases, 1, -1 do
        if pendingFormationReleases[index].expiresAt <= now then table.remove(pendingFormationReleases, index) end
    end
end

refreshFormationIndexes = function()
    queueRecordNames, matchupByGroup, matchupByKey, matchupByPlayer = {}, {}, {}, {}
    for name in pairs(ns.state.records) do
        local lower = name:lower()
        if queueRecordNames[lower] ~= nil then queueRecordNames[lower] = false
        else queueRecordNames[lower] = name end
    end
    local now = GetServerTime()
    for _, group in ipairs(ns.groups) do
        local key, members = matchupFingerprint(group, now)
        if key then
            local entry = { group = group, key = key, members = members }
            matchupByGroup[group] = entry
            if matchupByKey[key] ~= nil then matchupByKey[key] = false
            else matchupByKey[key] = entry end
            for name in pairs(members) do matchupByPlayer[name] = entry end
        end
    end
    pruneFormations(now)
end

local function activateFormation(owner, packet, entry)
    local winner = formationWinner(entry, GetServerTime())
    if winner and packet.sentAt > winner.sentAt + FORMATION_RACE_WINDOW then return nil end
    local lower = owner:lower()
    local claim = { owner = owner, claimID = packet.claimID, sentAt = packet.sentAt,
        key = packet.matchupKey, deadline = packet.sentAt + ns.FORMATION_TIMEOUT, guildKey = ns.guildKey }
    formationClaims[claim.key] = formationClaims[claim.key] or {}
    formationClaims[claim.key][lower], formationByOwner[lower] = claim, claim
    if winner and claim.sentAt < winner.sentAt then
        for _, contender in pairs(formationClaims[claim.key]) do
            if contender.sentAt > claim.sentAt + FORMATION_RACE_WINDOW then retireFormation(contender) end
        end
    end
    return claim
end

-- The sender comes exclusively from GUILD transport (or our local identity).
-- Watermarks outlive any fresh replay, are capped, and never evict live entries.
local function applyFormation(owner, packet, now)
    if packet.sentAt > now + 5 or now - packet.sentAt >= ns.FORMATION_TIMEOUT then return nil end
    local entry = matchupByKey[packet.matchupKey]
    if not entry or not currentMatchup(entry.group, now) or not entry.members[owner:lower()] then return nil end
    local lower = owner:lower()
    local previous = formationWatermarks[lower]
    local active = formationByOwner[lower]
    if packet.kind == "U" and active and active.claimID == packet.claimID and active.key == packet.matchupKey then
        retireFormation(active)
    end
    if previous and packet.claimID < previous.claimID then return nil end
    if previous and packet.claimID == previous.claimID then
        if previous.key ~= packet.matchupKey then return nil end
        if packet.kind == "U" then previous.released = true return nil end
        if previous.released or previous.sentAt ~= packet.sentAt then return nil end
        return active and active.claimID == packet.claimID and active or nil
    end
    if not previous and formationWatermarkCount >= FORMATION_CACHE_LIMIT then return nil end
    local watermark = { claimID = packet.claimID, key = packet.matchupKey, sentAt = packet.sentAt,
        released = packet.kind == "U", expiresAt = math.max(now, packet.sentAt) + ns.FORMATION_TIMEOUT + 5 }
    formationWatermarks[lower] = watermark
    if not previous then formationWatermarkCount = formationWatermarkCount + 1 end
    if packet.kind == "U" then return nil end
    -- A new token cannot silently renew a live window. A second explicit
    -- click after a failed submission names the retired token it replaces,
    -- so reordered/lost release packets cannot unlock its successful retry.
    -- Non-overlapping windows also tolerate small peer clock differences.
    if active and not active.released and active.deadline > now and packet.sentAt < active.deadline
        and packet.replacesID ~= active.claimID then
        watermark.released = true
        return nil
    end
    if active then retireFormation(active) end
    local claim = activateFormation(owner, packet, entry)
    if not claim then watermark.released = true end
    return claim
end

local function releaseFormation(claim)
    if not claim or claim.releaseQueued or claim.guildKey ~= ns.guildKey then return end
    retireFormation(claim)
    if claim.deadline <= GetServerTime() then return end
    claim.releaseQueued = true
    if #pendingFormationReleases >= 5 then table.remove(pendingFormationReleases, 1) end
    pendingFormationReleases[#pendingFormationReleases + 1] = { kind = "U", sentAt = GetServerTime(),
        claimID = claim.claimID, matchupKey = claim.key, expiresAt = claim.deadline }
end

local function actionMatchup(subject)
    local now = GetServerTime()
    local entry = currentMatchup(subject, now)
    local own = ns.playerName and currentMatchup(ns.playerName, now)
    if entry and entry == own then return entry end
end

local function formationActionDisabledReason(subject)
    local reason, status = ns.FormationDisabledReason(subject)
    if reason then return reason end
    if not actionMatchup(subject) or (status and status.isOwner) then return nil end
    local remaining = 5 - (GetTime() - lastFormationFailure)
    if remaining > 0 then
        return "Matchup announcement could not be sent. Retry in " .. math.ceil(remaining) .. "s."
    end
    if safeCall(C_ChatInfo and C_ChatInfo.InChatMessagingLockdown) == true then
        return "Addon messaging is restricted. Wait until your matchup invitation can be announced."
    end
end

local function beginFormation(subject)
    local reason = formationActionDisabledReason(subject)
    if reason then return nil, false, reason end
    local entry = actionMatchup(subject)
    if not entry then return nil, false end
    local winner = formationWinner(entry, GetServerTime())
    if winner and winner.owner:lower() == ns.playerName:lower() then return winner, false end
    pruneFormations(GetServerTime())
    local previous = formationWatermarks[ns.playerName:lower()]
    local replacesID = previous and previous.key == entry.key and previous.released and previous.claimID or 0
    local packet = { kind = "F", sentAt = GetServerTime(), claimID = nextRevision(), matchupKey = entry.key,
        replacesID = replacesID }
    -- Install before sending: a synchronous delivery may introduce a competing
    -- claim while SendAddonMessage is on the stack. This is not an atomic lock.
    local claim = applyFormation(ns.playerName, packet, GetServerTime())
    if not claim then return nil, false, "Matchup coordination is unavailable. Wait for the queue to refresh." end
    lastAttempt = GetTime() -- Urgent clicks may bypass the background one-message/second limit.
    if not send(ns.Protocol.Encode(packet)) then
        lastFormationFailure = GetTime()
        releaseFormation(claim)
        return nil, false, "Matchup announcement could not be sent. No invitations were requested; retry in 5s."
    end
    local status = ns.FormationStatus(subject)
    if not status or not status.isOwner or status.key ~= claim.key or claim.guildKey ~= ns.guildKey then
        releaseFormation(claim)
        return nil, false, ns.FormationDisabledReason(subject) or "This suggested matchup changed. Try again."
    end
    return claim, true
end

-- Dungeon recruitment needs a normal home party. Quests can additionally
-- inspect a home raid without imposing dungeon or queued-preference rules.
local function actualPartyMembers(allowRaid)
    local homeGroup = safeCall(IsInGroup, LE_PARTY_CATEGORY_HOME)
    local instanceGroup = safeCall(IsInGroup, LE_PARTY_CATEGORY_INSTANCE)
    if type(homeGroup) ~= "boolean" or type(instanceGroup) ~= "boolean" then
        return nil, "Your party status is unavailable right now."
    end
    if instanceGroup then return nil, "You cannot send these party invitations from an instance group." end
    local self = normalize(ns.playerName)
    if not self then return nil, "Your party identity is unavailable right now." end
    local snapshot = { homeGroup = homeGroup, present = { [self:lower()] = true }, members = {} }
    if not homeGroup then return snapshot end
    local raid = safeCall(IsInRaid, LE_PARTY_CATEGORY_HOME)
    if type(raid) ~= "boolean" then return nil, "Your party status is unavailable right now." end
    if raid and not allowRaid then return nil, "You cannot send these party invitations from a raid." end
    local counter = GetNumSubgroupMembers
    if raid then counter = GetNumGroupMembers end
    local count = safeCall(counter, LE_PARTY_CATEGORY_HOME)
    if not boundedNumber(count, 1, raid and 40 or 4) or type(UnitFullName) ~= "function" then
        return nil, "Your party roster is unavailable right now. Wait for it to update."
    end
    local seenSelf = false
    for index = 1, count do
        local ok, name, realm = pcall(UnitFullName, (raid and "raid" or "party") .. index)
        if not ok or secret(name, realm) or type(name) ~= "string"
            or (realm ~= nil and type(realm) ~= "string") then
            return nil, "Your party roster is unavailable right now. Wait for it to update."
        end
        -- Keep the queue's realm-qualified convention, including APIs that
        -- already provide a qualified first return value.
        name = name:match("^%s*(.-)%s*$")
        if realm and realm ~= "" and not name:find("[%s%-]") then name = name .. "-" .. realm end
        local target = normalize(name)
        if raid and target and target:lower() == self:lower() and not seenSelf then
            seenSelf = true
        else
            if not target or snapshot.present[target:lower()] then
                return nil, "Your party roster is unavailable right now. Wait for it to update."
            end
            snapshot.present[target:lower()] = true
            snapshot.members[#snapshot.members + 1] = target
        end
    end
    if raid and not seenSelf then return nil, "Your raid roster is unavailable right now." end
    return snapshot
end

local function partyQueuePreferences(snapshot, now)
    if not ns.Protocol.ValidSelections(ns.prefs.roles, ns.prefs.dungeons) then
        return nil, nil, "Select valid roles and dungeons for your party."
    end
    local players = { { name = ns.playerName, roles = ns.prefs.roles } }
    local shared = ns.CommonDungeons(ns.prefs.dungeons, ns.prefs.dungeons)
    for _, name in ipairs(snapshot.members) do
        local record = freshQueueRecord(name, now)
        if not record then
            return nil, nil, "Every party member needs fresh queued roles and dungeon preferences."
        end
        players[#players + 1] = record
        shared = ns.CommonDungeons(shared, record.dungeons)
    end
    if not next(shared) then return nil, nil, "Your party does not share a selected dungeon." end
    return players, shared
end

local function partyCanFitCandidate(players, candidate, role)
    local combined = {}
    for _, player in ipairs(players) do combined[#combined + 1] = player end
    -- A role-column click tests that role alone, not an agreed role inferred
    -- from a flexible candidate's full offered mask.
    combined[#combined + 1] = { name = candidate.name, roles = role or candidate.roles }
    return ns.CanFitRoleSlots(combined)
end

-- Also returns a snapshot of missing targets and whether the party qualifies
-- for Invite Others. Rendering and clicking use the same read-only checks.
function ns.CreatePartyDisabledReason(group)
    local snapshot, partyReason = actualPartyMembers()
    if not snapshot then return partyReason end
    local homeGroup = snapshot.homeGroup
    if not ns.IsReady() then
        return "Your guild queue is not ready yet."
    end
    if not matchupByGroup[group] then
        return "This suggested group has changed. Wait for the queue to refresh."
    end
    local formationReason = ns.FormationDisabledReason(group)
    if formationReason then return formationReason end
    local includesPlayer, names, records = false, {}, {}
    local now = GetServerTime()
    if type(group.members) ~= "table" or #group.members < 2 or #group.members > #ns.SLOTS then
        return "This suggested group must contain two to five compatible players."
    end
    for _, player in ipairs(group.members) do
        local name = type(player) == "table" and normalize(player.name)
        local record = name and freshQueueRecord(name, now)
        if not record or names[name:lower()] then
            return "This suggested group is no longer available. Wait for the queue to refresh."
        end
        names[name:lower()], records[name:lower()] = true, record
        includesPlayer = includesPlayer or name:lower() == ns.playerName:lower()
    end
    if not includesPlayer then
        return "You can only create a party for your own suggested group."
    end
    if not ns.queued or ns.QueueUpdatePending() or ns.JoinQueueDisabledReason() then
        return "Your queued selections have changed. Wait for your latest queue update."
    end
    local shared, assigned = ns.CommonDungeons(ns.prefs.dungeons, ns.prefs.dungeons), {}
    if type(group.slots) ~= "table" then return "This suggested group's roles have changed." end
    for slot, role in ipairs(ns.SLOTS) do
        local player = group.slots[slot]
        if player then
            local name = type(player) == "table" and normalize(player.name)
            local key = name and name:lower()
            local record = key and records[key]
            if not record or assigned[key] or not ns.HasRole(record.roles, role) then
                return "This suggested group's roles have changed. Wait for the queue to refresh."
            end
            assigned[key] = true
            shared = ns.CommonDungeons(shared, record.dungeons)
        end
    end
    for key in pairs(names) do
        if not assigned[key] then return "This suggested group's roles have changed." end
    end
    if type(group.dungeons) ~= "table" or not shared[group.dungeonID]
        or not next(ns.CommonDungeons(shared, group.dungeons)) then
        return "This suggested group no longer shares a current selected dungeon."
    end
    for _, name in ipairs(snapshot.members) do
        if not names[name:lower()] then
            return "Your party includes a player outside your current suggested group."
        end
    end
    local present = snapshot.present
    local targets = {}
    for _, player in ipairs(group.members) do
        if not present[player.name:lower()] then targets[#targets + 1] = player.name end
    end
    if #targets == 0 then
        return "All suggested members are already in your party.", nil, homeGroup
    end
    if InCombatLockdown() then
        return "You cannot send invitations during combat.", nil, homeGroup
    end
    if not C_PartyInfo or type(C_PartyInfo.InviteUnit) ~= "function" then
        return "Party invitations are unavailable on this client.", nil, homeGroup
    end
    if homeGroup then
        local full = safeCall(C_PartyInfo.IsPartyFull, LE_PARTY_CATEGORY_HOME)
        local allowed = safeCall(C_PartyInfo.CanInvite)
        if type(full) ~= "boolean" or type(allowed) ~= "boolean" then
            return "Your party status is unavailable right now.", nil, true
        end
        if full then return "Your party is full.", nil, true end
        if not allowed then
            return "You do not have permission to invite players to this group.", nil, true
        end
    end
    local coordinationReason = formationActionDisabledReason(group)
    if coordinationReason then return coordinationReason, nil, homeGroup end
    if GetTime() - lastPartyInviteAt < 5 then
        return "Invitations were just requested. Wait a few seconds before trying again.", nil, homeGroup
    end
    for _, name in ipairs(targets) do
        if GetTime() - (lastMemberInviteAt[name:lower()] or -100) < 5 then
            return "An invitation was just requested for a suggested member. Wait a few seconds before trying again.", nil, homeGroup
        end
    end
    return nil, targets, homeGroup
end

-- Called only by the explicit group-action click, never by matching or timers.
-- Snapshot once: a party may appear after the first request in this batch.
function ns.CreateParty(group)
    updateGuild()
    local reason, targets = ns.CreatePartyDisabledReason(group)
    if reason then
        printMessage(reason)
        ns.RefreshUI()
        return false
    end
    local claim, isNew
    claim, isNew, reason = beginFormation(group)
    if not reason and not claim then reason = "This suggested matchup changed. Wait for the queue to refresh." end
    -- Announcement delivery can synchronously change queue or native party state.
    if not reason then reason, targets = ns.CreatePartyDisabledReason(group) end
    if reason then
        if isNew then releaseFormation(claim) end
        printMessage(reason)
        ns.RefreshUI()
        return false
    end
    lastPartyInviteAt = GetTime()
    local requested = 0
    for _, name in ipairs(targets) do
        if ns.FormationDisabledReason(group) or ns.MatchupKey(group) ~= claim.key
            or not ns.IsReady() or not ns.queued or ns.QueueUpdatePending() then break end
        lastMemberInviteAt[name:lower()] = GetTime()
        local ok, result = pcall(C_PartyInfo.InviteUnit, name)
        if ok and result ~= false then requested = requested + 1 end
    end
    if isNew and requested == 0 then releaseFormation(claim) end
    if requested == #targets then
        printMessage("Party invitations requested. Players must accept; leave the queue when finished forming your party.")
    else
        printMessage("Some invitation requests could not be submitted. Check WoW's messages before trying again.")
    end
    ns.RefreshUI()
    return requested == #targets
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
        printMessage("Queue requested. Use Create party or Invite Others on your suggested group to invite its missing members.")
    else
        local claim = ns.playerName and formationByOwner[ns.playerName:lower()]
        releaseFormation(claim)
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
    restrictRoles()
    if ns.queued then
        if ns.AllowedRoles() and ns.Protocol.ValidSelections(ns.prefs.roles, ns.prefs.dungeons) then
            if ns.QueueUpdatePending() then
                -- Keep queue age and the sticky scheduled retry, but never use
                -- an obsolete local advertisement to authorize invitations.
                ns.state.records[ns.playerName or ""] = nil
                rebuild()
            end
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
        presence, guildMembers, lastMemberInviteAt = {}, {}, {}
        pendingRoleNotices, receivedRoleNotices = {}, {}
        formationClaims, formationByOwner, formationWatermarks, pendingFormationReleases = {}, {}, {}, {}
        formationWatermarkCount, lastFormationFailure = 0, -100
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

updateGuild = function(clearIfUnresolved)
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

-- Role lists read the queue directly, never the matcher's assigned groups.
-- Ascending joinedAt means descending time spent waiting (longest first).
function ns.GetRoleLists()
    local lists = { [1] = {}, [2] = {}, [4] = {} }
    if not ns.IsReady() then return lists, "Your guild information is not ready yet." end
    local snapshot, reason = actualPartyMembers()
    if not snapshot then return lists, reason end
    local now, players, selected = GetServerTime(), nil, ns.prefs.dungeons
    if snapshot.homeGroup then
        players, selected, reason = partyQueuePreferences(snapshot, now)
        if reason then return lists, reason end
    end
    if type(selected) ~= "table" then return lists end
    for _, player in ipairs(ns.state:Sorted()) do
        local shared = queueRecordFresh(player, now) and ns.CommonDungeons(player.dungeons, selected)
        local inParty = snapshot.present[player.name:lower()] == true
        if shared and next(shared) then
            for _, role in ipairs({ 1, 2, 4 }) do
                if ns.HasRole(player.roles, role) and (not snapshot.homeGroup or inParty
                    or partyCanFitCandidate(players, player, role)) then
                    local column = lists[role]
                    column[#column + 1] = { player = player, dungeons = shared, inParty = inParty }
                end
            end
        end
    end
    return lists
end

-- Shared native-party restrictions and per-person cooldown across both views.
local function memberInviteDisabledReason(target, snapshot)
    local reason
    if not snapshot then snapshot, reason = actualPartyMembers(true) end
    if not snapshot then return reason end
    if snapshot.present[target:lower()] then return "This member is already in your party.", true end
    if InCombatLockdown() then return "You cannot send invitations during combat." end
    if not C_PartyInfo or type(C_PartyInfo.InviteUnit) ~= "function"
        or type(C_PartyInfo.CanInvite) ~= "function" or type(C_PartyInfo.IsPartyFull) ~= "function" then
        return "Party invitations are unavailable on this client."
    end
    local instanceGroup = safeCall(IsInGroup, LE_PARTY_CATEGORY_INSTANCE)
    local full = safeCall(C_PartyInfo.IsPartyFull, LE_PARTY_CATEGORY_HOME)
    local allowed = safeCall(C_PartyInfo.CanInvite)
    if type(instanceGroup) ~= "boolean" or type(full) ~= "boolean" or type(allowed) ~= "boolean" then
        return "Your party status is unavailable right now."
    end
    if instanceGroup then return "You cannot send these invitations from an instance group." end
    if full then return "Your party or raid is full." end
    if not allowed then return "You do not have permission to invite players to this group." end
    if GetTime() - (lastMemberInviteAt[target:lower()] or -100) < 5 then
        return "An invitation was just requested for this member. Wait a few seconds before trying again."
    end
end

-- Read-only eligibility for the same-zone card button and its hover tooltip.
function ns.QuestInviteDisabledReason(name)
    if not ns.IsReady() then return "Your guild information is not ready yet." end
    local target = normalize(name)
    if not target then return "Select another guild member to invite." end
    if target:lower() == ns.playerName:lower() then
        return "You cannot invite your own character.", target, true
    end
    local formationReason = formationActionDisabledReason(target)
    if formationReason then return formationReason, target end
    local member = guildMembers[target:lower()]
    if not member or localZoneName == "" or member.area ~= localZoneName then
        return "The guild roster cannot confirm this member is online in your zone. Try refreshing the Guild window."
    end
    local reason, inParty = memberInviteDisabledReason(target)
    return reason, member.name, inParty
end

function ns.QueueInviteDisabledReason(name, requestedRole)
    if not ns.IsReady() then return "Your guild information is not ready yet." end
    local target = normalize(name)
    if not target then return "Select another guild member to invite." end
    if target:lower() == ns.playerName:lower() then
        return "You cannot invite your own character.", target, true
    end
    local formationReason = formationActionDisabledReason(target)
    if formationReason then return formationReason, target end
    local snapshot, reason = actualPartyMembers()
    if not snapshot then return reason, target end
    if snapshot.present[target:lower()] then
        return "This member is already in your party.", target, true
    end
    if requestedRole ~= nil and requestedRole ~= 1 and requestedRole ~= 2 and requestedRole ~= 4 then
        return "Select a valid role column before inviting this player.", target
    end
    local now = GetServerTime()
    local player = freshQueueRecord(target, now)
    if not player then
        return "This player needs fresh queued roles and dungeon preferences. Wait for the queue to refresh.", target
    end
    if requestedRole and not ns.HasRole(player.roles, requestedRole) then
        return "This player no longer offers the selected role.", player.name
    end
    local players, selected = nil, ns.prefs.dungeons
    if snapshot.homeGroup then
        players, selected, reason = partyQueuePreferences(snapshot, now)
        if reason then return reason, player.name end
    end
    if type(selected) ~= "table" or not next(ns.CommonDungeons(player.dungeons, selected)) then
        return "You do not share a selected dungeon with this player and your whole party.", player.name
    end
    if snapshot.homeGroup and not partyCanFitCandidate(players, player, requestedRole) then
        return "This role cannot fit your party's Tank, Healer and three Damage slots.", player.name
    end
    reason = memberInviteDisabledReason(player.name, snapshot)
    return reason, player.name
end

-- Called only after the explicit click has revalidated its target.
local function requestMemberInvite(target, requestedRole, questInvite)
    local claim, isNew, reason = beginFormation(target)
    -- Revalidate after the synchronous announcement, including foreign winners.
    if not reason then
        if questInvite then reason = ns.QuestInviteDisabledReason(target)
        else reason = ns.QueueInviteDisabledReason(target, requestedRole) end
    end
    if reason then
        if isNew then releaseFormation(claim) end
        printMessage(reason)
        ns.RefreshUI()
        return false
    end
    lastMemberInviteAt[target:lower()] = GetTime()
    local ok, result = pcall(C_PartyInfo.InviteUnit, target)
    local requested = ok and result ~= false
    if not requested and isNew then releaseFormation(claim) end
    if requested and requestedRole then
        -- A bounded, short-lived informational outbox, not a reservation or
        -- role agreement. Old addon versions safely ignore this optional packet.
        for index = #pendingRoleNotices, 1, -1 do
            if pendingRoleNotices[index].target:lower() == target:lower() then
                table.remove(pendingRoleNotices, index)
            end
        end
        if #pendingRoleNotices >= 5 then table.remove(pendingRoleNotices, 1) end
        pendingRoleNotices[#pendingRoleNotices + 1] = { kind = "R", target = target,
            role = requestedRole, sentAt = GetServerTime() }
        printMessage("Party invitation requested as " .. ns.ROLE_NAMES[requestedRole]
            .. ". A role notice is queued for updated addons; confirm the role with the player.")
    else
        printMessage(requested and "Party invitation requested. The player must accept."
            or "The invitation request could not be submitted. Check WoW's messages before trying again.")
    end
    ns.RefreshUI()
    return requested
end

-- Role-list invitations have no same-zone or complete-group requirement.
function ns.InviteQueuedPlayer(name, requestedRole)
    updateGuild()
    local reason, target = ns.QueueInviteDisabledReason(name, requestedRole)
    if reason then
        printMessage(reason)
        ns.RefreshUI()
        return false
    end
    return requestMemberInvite(target, requestedRole)
end

-- Only the explicit Invite click calls this. Never retry from timers or messages.
function ns.InviteQuestingPlayer(name)
    updateGuild()
    if localDirty then scanLocalQuests() end
    scanGuildMembers()
    local reason, target = ns.QuestInviteDisabledReason(name)
    if reason then
        printMessage(reason)
        ns.RefreshUI()
        return false
    end
    return requestMemberInvite(target, nil, true)
end

send = function(message)
    if safeCall(C_ChatInfo and C_ChatInfo.InChatMessagingLockdown) == true then
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
    if ns.queued then
        if not ns.AllowedRoles() then return false end
        if restrictRoles() then ns.PreferencesChanged() end
        if ns.queued and not ns.Protocol.ValidSelections(ns.prefs.roles, ns.prefs.dungeons) then ns.SetQueued(false) end
    end
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

nextRevision = function()
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
    if restrictRoles() then ns.PreferencesChanged() end
    if localDirty or clock - lastLocalScan >= ns.HEARTBEAT then scanLocalQuests() end
    local serverNow = GetServerTime()
    pruneFormations(serverNow)
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
    while pendingRoleNotices[1] and serverNow - pendingRoleNotices[1].sentAt >= 30 do
        table.remove(pendingRoleNotices, 1)
    end
    -- Background traffic stays at one message/second; failures back off five.
    -- Only an explicit click's urgent F can bypass this scheduler.
    local interval = transportError and 5 or 1
    if clock - lastAttempt >= interval then
        if pendingFormationReleases[1] then
            lastAttempt = clock
            if send(ns.Protocol.Encode(pendingFormationReleases[1])) then table.remove(pendingFormationReleases, 1) end
        elseif pendingStateAt and pendingStateAt <= clock then
            lastAttempt = clock
            sendState()
        elseif questStopPending then
            lastAttempt = clock
            sendQuestPart(clock)
        elseif pendingRoleNotices[1] then
            lastAttempt = clock
            if send(ns.Protocol.Encode(pendingRoleNotices[1])) then table.remove(pendingRoleNotices, 1) end
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
    if packet.kind == "F" or packet.kind == "U" then
        pruneFormations(now)
        applyFormation(name, packet, now)
        ns.RefreshUI()
        return
    end
    if packet.kind == "R" then
        if packet.sentAt <= now + 5 and now - packet.sentAt < 30 then
            presence[name] = now
            local previous = receivedRoleNotices[name:lower()]
            if packet.target:lower() == ns.playerName:lower() and ns.queued
                and ns.HasRole(ns.prefs.roles, packet.role)
                and (not previous or (packet.sentAt > previous.sentAt and GetTime() - previous.shownAt >= 5)) then
                receivedRoleNotices[name:lower()] = { sentAt = packet.sentAt, shownAt = GetTime() }
                printMessage(ns.SafeText(name) .. " requests you as " .. ns.ROLE_NAMES[packet.role]
                    .. ". Confirm the role with them and accept WoW's invitation if you agree. No role is assigned automatically.")
            end
        end
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
    restrictRoles()
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
