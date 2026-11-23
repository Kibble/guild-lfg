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
local actualPartyMembers, nativeQueueSnapshot, reconcileQueued
local queueMode, queueRosterIdentity, queueSelectionSignature
local stateBatch, partyNeedsClear = nil, false
local partyUpdatePaused, partyWithdrawalPending = false, false
local soloInvitationBatch
local queueRecordNames, matchupByGroup, matchupByKey, matchupByPlayer = {}, {}, {}, {}
local formationClaims, formationByOwner, formationWatermarks, pendingFormationReleases = {}, {}, {}, {}
local formationWatermarkCount, lastFormationFailure = 0, -100
local FORMATION_CACHE_LIMIT, FORMATION_RACE_WINDOW = 256, 5
ns.FORMATION_TIMEOUT = 10
ns.queued = false
ns.state = ns.State.New()
ns.groups, ns.individuals, ns.matchOptions = {}, {}, {}
ns.questing = ns.Questing.New()
local guildMembers, localQuests, questTitles = {}, nil, {}
local localZoneID, localZoneName, localLevel = 0, "", 0
local localDirty, lastLocalScan, lastRosterRequest = true, -100, -100
local questBatch, questBatchIndex, questBatchSignature = nil, 1, nil
local questSentSignature, questStopPending = nil, false
local lastQuestSent, lastQuestPrepared = -100, -100
local pendingVersionLogin, pendingVersionReplyAt, newerVersion = false, nil, nil
local lastVersionSent, VERSION_REPLY_COOLDOWN = -100, 30
ns.UPDATE_URL = "https://github.com/Kibble/guild-lfg"

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

-- Guard API failures and secret values; required native party data fails closed.
local function safeCall(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(fn, ...)
    if ok and not secret(value) then return value end
end

local function unitName(unit)
    if type(UnitFullName) ~= "function" then return nil end
    local ok, name, realm = pcall(UnitFullName, unit)
    if not ok or secret(name, realm) or type(name) ~= "string"
        or (realm ~= nil and type(realm) ~= "string") then return nil end
    name = name:match("^%s*(.-)%s*$")
    if realm and realm ~= "" and not name:find("[%s%-]") then name = name .. "-" .. realm end
    name = normalize(name)
    if name and #name <= 128 and not name:find("[%c%s|]") then return name end
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

local function assignedRole(unit)
    local role = safeCall(UnitGroupRolesAssigned, unit)
    if role == "TANK" then return 1 end
    if role == "HEALER" then return 2 end
    if role == "DAMAGER" then return 4 end
    return 0
end

local function nativeGrouped()
    local home = safeCall(IsInGroup, LE_PARTY_CATEGORY_HOME)
    local instance = safeCall(IsInGroup, LE_PARTY_CATEGORY_INSTANCE)
    return home == true or instance == true
end

function ns.UsesPartyRoles()
    -- Unknown leadership stays read-only; confirmed nonleaders edit their own
    -- flexible selections, even while a leader's listing shadows their entry.
    return (ns.queued and queueMode == "party") or (nativeGrouped()
        and safeCall(UnitIsGroupLeader, "player", LE_PARTY_CATEGORY_HOME) ~= false)
end

function ns.QueueButtonText()
    if ns.queued then return queueMode == "party" and "Leave party queue" or "Leave queue" end
    return ns.UsesPartyRoles() and "Queue party" or "Join queue"
end

function ns.QueueRoles()
    if ns.UsesPartyRoles() then return assignedRole("player") end
    return ns.prefs and ns.prefs.roles or 0
end

function ns.RoleDisabledReason(role)
    if ns.UsesPartyRoles() then
        return "Party roles come from WoW's party controls. Assign roles there, including the leader's role."
    end
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
    ns.matchOptions = ns.PartyMatchOptions(ns.state)
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

function ns.GetUpdateVersion()
    return newerVersion
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
    return "Party leaders can queue their whole party. Other players can join individually with selected roles and dungeons."
end

function ns.JoinQueueDisabledReason()
    if not ns.IsReady() then return ns.StatusText() end
    local _, reason = nativeQueueSnapshot()
    return reason
end

local function ownSelectionsMatch(record)
    local snapshot = nativeQueueSnapshot()
    if not record or not snapshot or snapshot.mode ~= queueMode or snapshot.identity ~= queueRosterIdentity
        or not ns.prefs or type(record.dungeons) ~= "table"
        or type(ns.prefs.dungeons) ~= "table" then return false end
    if snapshot.mode == "party" then
        if type(record.partyMembers) ~= "table" or record.partyLeader ~= ns.playerName
            or record.partySize ~= #snapshot.players or record.roles ~= snapshot.ownRole
            or #record.partyMembers ~= #snapshot.players then return false end
        local roles = {}
        for _, member in ipairs(snapshot.players) do roles[member.name:lower()] = member.roles end
        for _, member in ipairs(record.partyMembers) do
            if type(member.name) ~= "string" or roles[member.name:lower()] ~= member.roles then return false end
            roles[member.name:lower()] = nil
        end
        if next(roles) then return false end
    elseif record.partyMembers or record.roles ~= ns.prefs.roles then
        return false
    end
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
    local record = recordName and ns.state:Get(recordName)
    if not queueRecordFresh(record, now) or record.name:lower() ~= name:lower() then return nil end
    return record
end

function ns.PartyQueueLeader()
    if not ns.IsReady() then return nil end
    local record = freshQueueRecord(ns.playerName, GetServerTime())
    if record and record.partyLeader and record.partyLeader:lower() ~= ns.playerName:lower() then
        return record.partyLeader
    end
end

local function matchupFingerprint(group, now, records, hashCache)
    if type(group) ~= "table" or type(group.members) ~= "table"
        or #group.members < 2 or #group.members > 5 then return nil end
    local members, seen = {}, {}
    for _, member in ipairs(group.members) do
        local name = type(member) == "table" and normalize(member.name)
        local record
        if name then
            if records then record = records[name:lower()]
            else record = freshQueueRecord(name, now) end
        end
        if not queueRecordFresh(record, now) or record.name:lower() ~= name:lower()
            or #name > 128 or name:find("[%c%s|]") or seen[name:lower()]
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
        -- Preserve the legacy all-solo key, but bind premades to their owner.
        if record.partyLeader then
            parts[#parts + 1] = record.partyLeader:lower()
            parts[#parts + 1] = tostring(record.partySize)
        end
        parts[#parts + 1] = table.concat(ids, ",")
    end
    local text, first, second = table.concat(parts, "|"), 0, 0
    if hashCache and hashCache[text] then return hashCache[text], seen, text end
    for index = 1, #text do
        local byte = text:byte(index)
        -- Both products stay below 2^53, including on Lua's double numbers.
        first = (first * 131 + byte) % 2147483647
        second = (second * 65599 + byte) % 2147483647
    end
    local key = string.format("%08x%08x", first, second)
    if hashCache then hashCache[text] = key end
    return key, seen, text
end

local function currentMatchup(subject, now)
    if type(subject) == "table" then
        local indexed = matchupByGroup[subject]
        local entry = indexed and indexed.entry
        if not entry or matchupByKey[entry.key] ~= entry
            or subject.dungeonID ~= indexed.dungeonID or subject.dungeonOption ~= indexed.dungeonOption
            or subject.partyLeader ~= indexed.partyLeader then return nil end
        local key, _, source = matchupFingerprint(subject, now)
        if key == entry.key and source == entry.source then return entry end
    elseif type(subject) == "string" then
        local name = normalize(subject)
        local entries = name and matchupByPlayer[name:lower()] or {}
        local own = ns.playerName and ns.playerName:lower()
        -- Main suggestions precede deterministic alternatives. Reuse an active
        -- own claim containing the target; otherwise prefer any own matchup.
        local fallback, containingOwn
        for _, entry in ipairs(entries) do
            if currentMatchup(entry.group, now) then
                fallback = fallback or entry
                if own and entry.members[own] then
                    containingOwn = containingOwn or entry
                    local active = formationByOwner[own]
                    if active and not active.released and active.deadline > now and active.key == entry.key then
                        return entry
                    end
                end
            end
        end
        return containingOwn or fallback
    end
end

function ns.MatchupKey(group)
    local entry = currentMatchup(group, GetServerTime())
    return entry and entry.key
end

local function overlaps(left, right)
    for name in pairs(left) do if right[name] then return true end end
    return false
end

local function earlierClaim(claim, winner)
    return not winner or claim.sentAt < winner.sentAt
        or (claim.sentAt == winner.sentAt and (claim.owner:lower() < winner.owner:lower()
            or (claim.owner:lower() == winner.owner:lower() and claim.claimID < winner.claimID)))
end

local function formationWinner(entry, now, extraMembers)
    local winner
    for _, claim in pairs(formationByOwner) do
        local claimed = matchupByKey[claim.key]
        if claim.deadline > now and not claim.released and claimed and currentMatchup(claimed.group, now)
            and ((entry and overlaps(entry.members, claimed.members))
                or (extraMembers and overlaps(extraMembers, claimed.members)))
            and earlierClaim(claim, winner) then winner = claim end
    end
    return winner
end

function ns.FormationStatus(subject)
    if not ns.IsReady() then return nil end
    local now = GetServerTime()
    local entry = currentMatchup(subject, now)
    local extraMembers
    if type(subject) == "string" then
        local name = normalize(subject)
        if name then extraMembers = { [name:lower()] = true, [ns.playerName:lower()] = true } end
    end
    local winner = formationWinner(entry, now, extraMembers)
    if winner then
        return { owner = winner.owner, remaining = math.ceil(winner.deadline - now),
            isOwner = winner.owner:lower() == ns.playerName:lower(), key = winner.key,
            -- Own alternative cards still form a conflict unless this key agrees.
            sameMatchup = entry ~= nil and entry.key == winner.key }
    end
end

function ns.FormationDisabledReason(subject)
    local entry = currentMatchup(subject, GetServerTime())
    if entry and entry.partyLeader and ns.playerName and entry.members[ns.playerName:lower()]
        and entry.partyLeader:lower() ~= ns.playerName:lower() then
        return "Only the queued party's leader can invite this matchup."
    end
    local status = ns.FormationStatus(subject)
    if status and (not status.isOwner or not status.sameMatchup) then
        return ns.SafeText(status.owner) .. (status.sameMatchup and " is inviting this matchup ("
            or " is inviting an overlapping match option (") .. status.remaining .. "s remaining).", status
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
    -- One immutable read for this synchronous indexing pass. Live click checks
    -- still reread state; many dungeon aliases need not repeatedly sort it.
    local records, hashCache = {}, {}
    for _, record in ipairs(ns.state:Sorted()) do
        local name = record.name
        local lower = name:lower()
        if queueRecordNames[lower] ~= nil then
            queueRecordNames[lower], records[lower] = false, false
        else
            queueRecordNames[lower], records[lower] = name, record
        end
    end
    local now = GetServerTime()
    for _, groups in ipairs({ ns.groups, ns.matchOptions }) do
        for _, group in ipairs(groups) do
            local key, members, source = matchupFingerprint(group, now, records, hashCache)
            if key then
                local entry = matchupByKey[key]
                -- Selected dungeon is intentionally absent from the legacy key.
                -- Identical semantic sources alias; real hash collisions fail closed.
                if entry ~= nil and (not entry or entry.source ~= source) then
                    matchupByKey[key] = false
                else
                    if not entry then
                        entry = { group = group, key = key, members = members, source = source }
                        for name in pairs(members) do
                            local record = records[name]
                            if record and record.partyLeader then entry.partyLeader = record.partyLeader end
                            matchupByPlayer[name] = matchupByPlayer[name] or {}
                            table.insert(matchupByPlayer[name], entry)
                        end
                        matchupByKey[key] = entry
                    end
                    matchupByGroup[group] = { entry = entry, dungeonID = group.dungeonID,
                        dungeonOption = group.dungeonOption, partyLeader = group.partyLeader }
                end
            end
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
        for _, contender in pairs(formationByOwner) do
            local other = matchupByKey[contender.key]
            if other and overlaps(entry.members, other.members)
                and contender.sentAt > claim.sentAt + FORMATION_RACE_WINDOW then retireFormation(contender) end
        end
    end
    return claim
end

-- The sender comes exclusively from GUILD transport (or our local identity).
-- Watermarks outlive any fresh replay, are capped, and never evict live entries.
local function applyFormation(owner, packet, now)
    if packet.sentAt > now + 5 or now - packet.sentAt >= ns.FORMATION_TIMEOUT then return nil end
    local entry = matchupByKey[packet.matchupKey]
    if not entry or not currentMatchup(entry.group, now) or not entry.members[owner:lower()]
        or (entry.partyLeader and entry.partyLeader:lower() ~= owner:lower()) then return nil end
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
    if entry and ns.playerName and entry.members[ns.playerName:lower()] then return entry end
end

local function formationActionDisabledReason(subject)
    local own = ns.playerName and currentMatchup(ns.playerName, GetServerTime())
    if own and own.partyLeader and own.partyLeader:lower() ~= ns.playerName:lower() then
        return "Only the queued party's leader can invite this matchup."
    end
    local reason, status = ns.FormationDisabledReason(subject)
    if reason then return reason end
    if not actionMatchup(subject) or (status and status.isOwner and status.sameMatchup) then return nil end
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
    -- A failed explicit click may retry a different option. Name its released
    -- token too, so a lost/reordered U cannot discard the successful retry.
    local replacesID = previous and previous.released and previous.claimID or 0
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
    if not status or not status.isOwner or not status.sameMatchup
        or status.key ~= claim.key or claim.guildKey ~= ns.guildKey then
        releaseFormation(claim)
        return nil, false, ns.FormationDisabledReason(subject) or "This suggested matchup changed. Try again."
    end
    return claim, true
end

-- Dungeon recruitment needs a normal home party. Quests can additionally
-- inspect a home raid without imposing dungeon or queued-preference rules.
actualPartyMembers = function(allowRaid, allowEmptyParty, allowIndividual)
    local homeGroup = safeCall(IsInGroup, LE_PARTY_CATEGORY_HOME)
    local instanceGroup = safeCall(IsInGroup, LE_PARTY_CATEGORY_INSTANCE)
    if type(homeGroup) ~= "boolean" or type(instanceGroup) ~= "boolean" then
        return nil, "Your party status is unavailable right now."
    end
    if instanceGroup then return nil, "You cannot send these party invitations from an instance group." end
    local self = normalize(ns.playerName)
    if not self or #self > 128 or self:find("[%c%s|]") then
        return nil, "Your party identity is unavailable right now."
    end
    local snapshot = { homeGroup = homeGroup, present = { [self:lower()] = true }, members = {},
        units = { [self:lower()] = "player" } }
    local raid = safeCall(IsInRaid, LE_PARTY_CATEGORY_HOME)
    if raid and not allowRaid then return nil, "A raid cannot queue or recruit for a dungeon party." end
    if not homeGroup then return snapshot end
    if type(raid) ~= "boolean" then return nil, "Your party status is unavailable right now." end
    local currentSelf = unitName("player")
    if not currentSelf or currentSelf:lower() ~= self:lower() then
        return nil, "Your party identity is unavailable right now."
    end
    -- An individual advertisement needs only this player's identity, not the
    -- other members' names or assigned roles. Invitations still require all of them.
    if allowIndividual and safeCall(UnitIsGroupLeader, "player", LE_PARTY_CATEGORY_HOME) == false then
        return snapshot
    end
    local counter = GetNumSubgroupMembers
    if raid then counter = GetNumGroupMembers end
    local count = safeCall(counter, LE_PARTY_CATEGORY_HOME)
    -- Only an explicit solo invitation batch may see its new party before
    -- the first member resolves. All ordinary queue/roster checks stay strict.
    local minimum = not raid and allowEmptyParty
        and safeCall(UnitIsGroupLeader, "player", LE_PARTY_CATEGORY_HOME) == true and 0 or 1
    if not boundedNumber(count, minimum, raid and 40 or 4) or type(UnitFullName) ~= "function" then
        return nil, "Your party roster is unavailable right now. Wait for it to update."
    end
    local seenSelf = false
    for index = 1, count do
        local unit = (raid and "raid" or "party") .. index
        -- Includes realm-qualified APIs and rejects unavailable/secret names.
        local target = unitName(unit)
        if raid and target and target:lower() == self:lower() and not seenSelf then
            seenSelf = true
        else
            if not target or #target > 128 or target:find("[%c%s|]") or snapshot.present[target:lower()] then
                return nil, "Your party roster is unavailable right now. Wait for it to update."
            end
            snapshot.present[target:lower()] = true
            snapshot.units[target:lower()] = unit
            snapshot.members[#snapshot.members + 1] = target
        end
    end
    if raid and not seenSelf then return nil, "Your raid roster is unavailable right now." end
    return snapshot
end

nativeQueueSnapshot = function(snapshot)
    local reason
    if not snapshot then snapshot, reason = actualPartyMembers(false, false, true) end
    if not snapshot then return nil, reason end
    snapshot.mode = "solo"
    if snapshot.homeGroup then
        local leader = safeCall(UnitIsGroupLeader, "player", LE_PARTY_CATEGORY_HOME)
        if type(leader) ~= "boolean" then
            return nil, "Your party leadership information is unavailable right now."
        end
        if leader then snapshot.mode = "party" end
    end
    if snapshot.mode == "solo" then
        local allowed = ns.AllowedRoles()
        if not allowed then return nil, "Waiting for your class role information." end
        if ns.FilterRoles(ns.prefs.roles, allowed) ~= ns.prefs.roles then
            return nil, "Select only roles available for your class."
        end
        if not ns.Protocol.ValidSelections(ns.prefs.roles, ns.prefs.dungeons) then
            return nil, "Select at least one role and one dungeon."
        end
        snapshot.identity = ns.playerName:lower()
        snapshot.selection = snapshot.identity .. ":" .. ns.prefs.roles .. "|"
            .. ns.Protocol.DungeonList(ns.prefs.dungeons)
        return snapshot
    end
    local players = { { name = ns.playerName } }
    for _, name in ipairs(snapshot.members) do players[#players + 1] = { name = name } end
    table.sort(players, function(a, b) return a.name:lower() < b.name:lower() end)
    local names, selections = {}, {}
    for _, player in ipairs(players) do
        local key = player.name:lower()
        local unit = snapshot.units[key]
        if type(UnitIsConnected) == "function" and safeCall(UnitIsConnected, unit) ~= true then
            return nil, "Every party member must be online, with available connection information."
        end
        player.roles = assignedRole(unit)
        if player.roles == 0 then
            return nil, "Assign a Tank, Healer or Damage role in WoW's party controls to everyone, including the leader."
        end
        names[#names + 1] = key
        selections[#selections + 1] = key .. ":" .. player.roles
        if key == ns.playerName:lower() then snapshot.ownRole = player.roles end
    end
    if not ns.CanFitRoleSlots(players) then
        return nil, "Party roles must fit one Tank, one Healer and three Damage slots."
    end
    if not ns.Protocol.ValidSelections(snapshot.ownRole, ns.prefs.dungeons) then
        return nil, "Select at least one valid dungeon for your party."
    end
    snapshot.players, snapshot.identity = players, table.concat(names, ",")
    snapshot.selection = table.concat(selections, ",") .. "|" .. ns.Protocol.DungeonList(ns.prefs.dungeons)
    return snapshot
end

local function partyQueuePreferences(snapshot, now)
    if queueMode ~= "party" then
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
    local current, reason = nativeQueueSnapshot(snapshot)
    if not current then return nil, nil, reason end
    if ns.queued and ns.QueueUpdatePending() then
        return nil, nil, "Your party queue has changed. Wait for its latest complete queue update."
    end
    return current.players, ns.CommonDungeons(ns.prefs.dungeons, ns.prefs.dungeons)
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
    if not currentMatchup(group, GetServerTime()) then
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
        if record.partyLeader and record.partyLeader:lower() ~= ns.playerName:lower() then
            return "Only the queued party's leader can invite this matchup."
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
        if safeCall(UnitIsGroupLeader, "player", LE_PARTY_CATEGORY_HOME) ~= true then
            return "Only your party leader can recruit for this party.", nil, true
        end
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
    if ns.queued then reconcileQueued() end
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
    local soloSelection = queueMode == "solo" and queueSelectionSignature
    local formedParty = false
    local authorized = {}
    for _, member in ipairs(group.members) do authorized[member.name:lower()] = true end
    if soloSelection then
        soloInvitationBatch = { selection = soloSelection, authorized = authorized, guildKey = ns.guildKey }
    end
    lastPartyInviteAt = GetTime()
    local requested = 0
    for index, name in ipairs(targets) do
        updateGuild()
        if ns.FormationDisabledReason(group) or ns.MatchupKey(group) ~= claim.key
            or claim.guildKey ~= ns.guildKey or not ns.IsReady() or not ns.queued
            or InCombatLockdown() or not C_PartyInfo or type(C_PartyInfo.InviteUnit) ~= "function" then break end
        local snapshot = actualPartyMembers(false, soloSelection and index > 1)
        if not snapshot then break end
        local valid = true
        for _, member in ipairs(snapshot.members) do
            if not authorized[member:lower()] then valid = false break end
        end
        if not valid then break end
        if soloSelection then
            if (index == 1 and snapshot.homeGroup) or (formedParty and not snapshot.homeGroup) then break end
            formedParty = snapshot.homeGroup
            -- Recheck this click's SOLO preferences, not the newly formed
            -- party's assigned roles. This exception never enrolls that party.
            local current = nativeQueueSnapshot({ homeGroup = false })
            if queueMode ~= "solo" or queueSelectionSignature ~= soloSelection
                or not current or current.selection ~= soloSelection then break end
        elseif ns.QueueUpdatePending() then
            break
        end
        if snapshot.homeGroup and (safeCall(UnitIsGroupLeader, "player", LE_PARTY_CATEGORY_HOME) ~= true
            or safeCall(C_PartyInfo.CanInvite) ~= true
            or safeCall(C_PartyInfo.IsPartyFull, LE_PARTY_CATEGORY_HOME) ~= false) then break end
        if snapshot.present[name:lower()] then
            requested = requested + 1
        else
            lastMemberInviteAt[name:lower()] = GetTime()
            local ok, result = pcall(C_PartyInfo.InviteUnit, name)
            if ok and result ~= false then requested = requested + 1 end
        end
    end
    -- A synchronous roster event may occur inside InviteUnit. Only this
    -- already-authorized transition waits until the explicit batch finishes.
    soloInvitationBatch = nil
    if ns.queued then reconcileQueued() end
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
        if ns.queued then reconcileQueued() end
        local reason = not ns.IsReady() and ns.StatusText() or nil
        local snapshot
        if not reason then snapshot, reason = nativeQueueSnapshot() end
        if reason then
            printMessage(reason)
            return
        end
        if not ns.queued then
            ns.joinedAt = GetServerTime()
            queueMode, queueRosterIdentity = snapshot.mode, snapshot.identity
            queueSelectionSignature = snapshot.selection
            stateBatch, partyNeedsClear = nil, snapshot.mode == "party"
            partyUpdatePaused, partyWithdrawalPending = false, false
        end
        ns.queued = true
        printMessage("Queue requested. Use Create party or Invite Others on your suggested group to invite its missing members.")
    else
        local claim = ns.playerName and formationByOwner[ns.playerName:lower()]
        releaseFormation(claim)
        ns.queued, ns.joinedAt = false, nil
        queueMode, queueRosterIdentity, queueSelectionSignature = nil, nil, nil
        stateBatch, partyNeedsClear, pendingRoleNotices = nil, false, {}
        partyUpdatePaused, partyWithdrawalPending = false, false
        soloInvitationBatch = nil
        -- Remove both the owner and unfinished fragments without losing replay protection.
        if ns.playerName then ns.state:Remove(ns.playerName) end
        rebuild()
        printMessage("Left the queue. Other clients update on delivery or within 75 seconds.")
    end
    requestState(0)
    ns.RefreshUI()
end

local function pauseQueueListing()
    if not partyUpdatePaused then
        partyUpdatePaused, partyWithdrawalPending, stateBatch = true, true, nil
        ns.state:Remove(ns.playerName)
        rebuild()
        requestState(0)
    end
end

reconcileQueued = function()
    if not ns.queued then return nil end
    if soloInvitationBatch and queueMode == "solo" and ns.IsReady()
        and soloInvitationBatch.guildKey == ns.guildKey then
        local forming = actualPartyMembers(false, true)
        local current = nativeQueueSnapshot({ homeGroup = false })
        local valid = forming and forming.homeGroup and current
            and current.selection == soloInvitationBatch.selection
            and queueSelectionSignature == soloInvitationBatch.selection
            and safeCall(UnitIsGroupLeader, "player", LE_PARTY_CATEGORY_HOME) == true
        if valid then
            for _, name in ipairs(forming.members) do
                if not soloInvitationBatch.authorized[name:lower()] then valid = false break end
            end
            if valid then return current end
        end
    end
    if queueMode == "party" then
        local home = safeCall(IsInGroup, LE_PARTY_CATEGORY_HOME)
        local instance = safeCall(IsInGroup, LE_PARTY_CATEGORY_INSTANCE)
        local raid = safeCall(IsInRaid, LE_PARTY_CATEGORY_HOME)
        local leader = safeCall(UnitIsGroupLeader, "player", LE_PARTY_CATEGORY_HOME)
        if home == false or instance == true or raid == true or leader == false
            or not ns.Protocol.ValidSelections(1, ns.prefs.dungeons) then
            ns.SetQueued(false)
            return nil
        end
        if home ~= true or instance ~= false or raid ~= false or leader ~= true then
            pauseQueueListing()
            return nil
        end
    end
    local roster = actualPartyMembers(false, false, true)
    if not roster then
        if queueMode == "party" or (safeCall(IsInGroup, LE_PARTY_CATEGORY_INSTANCE) ~= true
            and safeCall(IsInRaid, LE_PARTY_CATEGORY_HOME) ~= true) then
            pauseQueueListing()
        else
            ns.SetQueued(false)
        end
        return nil
    end
    local snapshot = nativeQueueSnapshot(roster)
    if not snapshot then
        -- Unknown leadership must not discard an individual queue or enroll a
        -- party. Keep intent unpublished until the native information resolves.
        if queueMode == "party" or (roster.homeGroup
            and type(safeCall(UnitIsGroupLeader, "player", LE_PARTY_CATEGORY_HOME)) ~= "boolean") then
            pauseQueueListing()
        elseif ns.AllowedRoles() then ns.SetQueued(false) end
        return nil
    end
    -- A change of leadership never automatically enrolls a whole party or
    -- turns a former leader's whole-party intent into an individual entry.
    if snapshot.mode ~= queueMode then
        ns.SetQueued(false)
        return nil
    end
    if snapshot.mode ~= "party" and snapshot.identity ~= queueRosterIdentity then
        ns.SetQueued(false)
        return nil
    end
    if partyUpdatePaused or snapshot.selection ~= queueSelectionSignature then
        partyUpdatePaused = false
        queueRosterIdentity, queueSelectionSignature, stateBatch = snapshot.identity, snapshot.selection, nil
        ns.state:Remove(ns.playerName)
        rebuild()
        requestState(0)
    end
    return snapshot
end

function ns.PreferencesChanged()
    restrictRoles()
    if ns.queued then
        if reconcileQueued() then requestState(0) end
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
        queueMode, queueRosterIdentity, queueSelectionSignature = nil, nil, nil
        stateBatch, partyNeedsClear = nil, false
        partyUpdatePaused, partyWithdrawalPending = false, false
        ns.state = ns.State.New()
        pendingStateAt, pendingHello, pendingPresence = nil, key ~= nil, key ~= nil
        lastHello, lastPresence, lastHelloReply = -100, -100, -100
        presence, guildMembers, lastMemberInviteAt = {}, {}, {}
        pendingRoleNotices, receivedRoleNotices = {}, {}
        pendingVersionLogin, pendingVersionReplyAt, newerVersion = key ~= nil and ns.addonVersion ~= nil, nil, nil
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
    if player.partyLeader then
        return "This player belongs to a queued party. Only its leader can recruit solo players; party members cannot be invited individually.", player.name
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
    local chosen = actionMatchup(target)
    local claim, isNew, reason = beginFormation(target)
    -- Bind the click to its chosen option even if a callback rematches the queue.
    if not reason and chosen and (not claim or claim.key ~= chosen.key
        or currentMatchup(chosen.group, GetServerTime()) ~= chosen) then
        reason = "This suggested matchup changed. Wait for the queue to refresh."
    end
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
    if ns.queued then reconcileQueued() end
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
    if ns.queued then reconcileQueued() end
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
    if ns.queued then
        local signature = queueSelectionSignature
        if (not reconcileQueued() and not partyUpdatePaused) or signature ~= queueSelectionSignature then return false end
        if partyUpdatePaused and type(message) == "string" then
            local kind = message:match("^1|([^|]+)")
            if kind == "S" or kind == "B" or kind == "C" or kind == "F" then return false end
        end
    end
    if not ns.IsReady() or type(message) ~= "string" then return false end
    if safeCall(C_ChatInfo and C_ChatInfo.InChatMessagingLockdown) == true then
        transportError = "Addon messaging is restricted right now; retrying when allowed."
        return false
    end
    local sender = C_ChatInfo and C_ChatInfo.SendAddonMessage
    local ok, result = pcall(sender, ns.PREFIX, message, "GUILD")
    local success = Enum and Enum.SendAddonMessageResult and Enum.SendAddonMessageResult.Success or 0
    if not ok or secret(result) or result ~= success then
        -- Do not print raw API error strings or payloads.
        transportError = "Guild message could not be sent (account/server restriction or throttling); retrying."
        return false
    end
    transportError = nil
    return true
end

local function sendState()
    -- Never publish a solo advertisement during a forming-party callback.
    if soloInvitationBatch then return false end
    if restrictRoles() then ns.PreferencesChanged() end
    local snapshot = ns.queued and reconcileQueued()
    if ns.queued and not snapshot and not partyWithdrawalPending then
        pendingStateAt = nil
        return false
    end
    if not ns.IsReady() then return false end
    local now = GetServerTime()
    if stateBatch and (now - stateBatch.sentAt >= ns.TIMEOUT or stateBatch.sentAt > now + 5
        or stateBatch.signature ~= queueSelectionSignature or stateBatch.guildKey ~= ns.guildKey) then
        stateBatch = nil
        ns.state:Remove(ns.playerName)
        rebuild()
    end
    if not stateBatch then
        local messages = {}
        if partyWithdrawalPending then
            messages[1] = ns.Protocol.Encode({ kind = "X", revision = nextRevision(), sentAt = now })
        elseif ns.queued and snapshot.mode == "party" then
            -- Old clients only understand X/S. Clear a legacy solo once, never
            -- during heartbeats: receivers retain their last complete party.
            if partyNeedsClear then
                messages[1] = ns.Protocol.Encode({ kind = "X", revision = nextRevision(), sentAt = now })
            end
            local fragments = ns.Protocol.EncodeParty(nextRevision(), now, ns.joinedAt,
                ns.prefs.dungeons, snapshot.players)
            if not fragments then
                ns.SetQueued(false)
                return false
            end
            for _, fragment in ipairs(fragments) do messages[#messages + 1] = fragment end
        else
            local packet = { kind = ns.queued and "S" or "X", revision = nextRevision(), sentAt = now }
            if ns.queued then
                packet.joinedAt, packet.roles, packet.dungeons = ns.joinedAt, ns.prefs.roles, ns.prefs.dungeons
            end
            messages[1] = ns.Protocol.Encode(packet)
        end
        stateBatch = { messages = messages, index = 1, sentAt = now,
            signature = queueSelectionSignature, guildKey = ns.guildKey, withdrawal = partyWithdrawalPending }
    end
    local batch = stateBatch
    local message = batch.messages[batch.index]
    local packet = ns.Protocol.Decode(message)
    if not packet or not send(message) then return false end
    lastPresence, pendingPresence = GetTime(), false
    -- A send callback can synchronously change guild, consent or native roster.
    if ns.queued then reconcileQueued() end
    if stateBatch ~= batch or batch.guildKey ~= ns.guildKey then return true end
    if packet.kind == "X" then partyNeedsClear = false end
    local changed = ns.state:Apply(ns.playerName, packet, GetServerTime())
    batch.index = batch.index + 1
    if batch.index > #batch.messages then
        stateBatch, pendingStateAt, lastSent = nil, nil, GetTime()
        if batch.withdrawal then
            partyWithdrawalPending = false
            if ns.queued and not partyUpdatePaused then requestState(0) end
        end
        if changed then rebuild() else ns.RefreshUI() end
    elseif changed then
        -- Only an initial withdrawal can change visible state before commit.
        rebuild()
    end
    return true
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
    if ns.queued then reconcileQueued() end
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
    if ns.queued and not partyUpdatePaused and clock - lastSent >= ns.HEARTBEAT then
        requestState(0)
    elseif (not ns.queued or partyUpdatePaused) and clock - lastPresence >= ns.HEARTBEAT then
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
        elseif ns.addonVersion and clock - lastVersionSent >= VERSION_REPLY_COOLDOWN
            and (pendingVersionLogin or (pendingVersionReplyAt and pendingVersionReplyAt <= clock)) then
            lastAttempt = clock
            if send(ns.Protocol.Encode({ kind = "V", sentAt = serverNow, version = newerVersion or ns.addonVersion })) then
                pendingVersionLogin, pendingVersionReplyAt, lastVersionSent = false, nil, clock
            end
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
    if packet.kind == "V" then
        if packet.sentAt <= now + 5 and now - packet.sentAt < ns.TIMEOUT then
            presence[name] = now
            -- Reports describe the highest known release, not the sender's installed build.
            local comparison = ns.Protocol.CompareVersions(packet.version, newerVersion or ns.addonVersion)
            if comparison then
                if comparison > 0 then
                    newerVersion = packet.version
                end
                if comparison >= 0 then
                    -- Cancel only when the newcomer can hear at least our highest known report.
                    pendingVersionReplyAt = nil
                elseif not pendingVersionLogin and not pendingVersionReplyAt then
                    pendingVersionReplyAt = math.max(GetTime() + math.random(2, 5), lastVersionSent + VERSION_REPLY_COOLDOWN)
                end
            end
            ns.RefreshUI()
        end
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
                and ns.HasRole(ns.QueueRoles(), packet.role)
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
            if ns.queued and not partyUpdatePaused then requestState(math.random(1, 5)) end
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
    local version = safeCall(C_AddOns and C_AddOns.GetAddOnMetadata, addonName, "Version")
    ns.addonVersion = ns.Protocol.VersionParts(version) and version or nil
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
    ns.InitializeMinimap()
    identifyPlayer()
    updateGuild()
    scanLocalQuests()
    scanGuildMembers()
    ns.ticker = C_Timer.NewTicker(1, tick)
    printMessage("Loaded. Click the minimap icon or use /gq to open Guild Queue.")
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
    elseif event == "GROUP_ROSTER_UPDATE" or event == "PARTY_LEADER_CHANGED"
        or event == "PLAYER_ROLES_ASSIGNED" or event == "ROLE_CHANGED_INFORM"
        or event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
        if started then
            if ns.queued then reconcileQueued() end
            ns.RefreshUI()
        end
    elseif event == "PLAYER_LOGOUT" then
        if ns.IsReady() then
            ns.queued, ns.joinedAt = false, nil
            queueMode, queueRosterIdentity, queueSelectionSignature = nil, nil, nil
            stateBatch, partyNeedsClear = nil, false
            partyUpdatePaused, partyWithdrawalPending = false, false
            ns.state:Remove(ns.playerName)
            -- Best effort only: peers also expire entries if logout delivery is lost.
            sendState()
        end
    end
end)
for _, event in ipairs({ "ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "CHAT_MSG_ADDON",
    "GUILD_ROSTER_UPDATE", "PLAYER_GUILD_UPDATE", "GROUP_ROSTER_UPDATE", "PARTY_LEADER_CHANGED",
    "PLAYER_ROLES_ASSIGNED", "ROLE_CHANGED_INFORM",
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
