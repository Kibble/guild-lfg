local _, ns = ...
ns.State = {}
ns.State.__index = ns.State

local function sameSelection(left, right)
    for _, dungeon in ipairs(ns.DUNGEONS) do
        if (left[dungeon.id] == true) ~= (right[dungeon.id] == true) then
            return false
        end
    end
    return true
end

-- One revision per owner, at most six fragments each. Expiry/eviction never
-- resets the watermark, so a discarded transaction cannot be restarted.
local PENDING_LIMIT = 64

local function ownerKey(self, sender)
    if self.seen[sender] or self.records[sender] or self.pending[sender] then return sender end
    local lower = sender:lower()
    for name in pairs(self.seen) do
        if name:lower() == lower then return name end
    end
    for name in pairs(self.records) do
        if name:lower() == lower then return name end
    end
    return sender
end

local function copySelection(selected)
    local copy = {}
    for id, value in pairs(selected) do
        if value then copy[id] = true end
    end
    return copy
end

local function sameRecord(left, right)
    if not left or left.roles ~= right.roles or left.joinedAt ~= right.joinedAt
        or left.partySize ~= right.partySize or not sameSelection(left.dungeons, right.dungeons) then return false end
    if right.partyMembers then
        if not left.partyMembers or #left.partyMembers ~= #right.partyMembers then return false end
        for index, member in ipairs(right.partyMembers) do
            local old = left.partyMembers[index]
            if old.name:lower() ~= member.name:lower() or old.roles ~= member.roles then return false end
        end
    elseif left.partyMembers then
        return false
    end
    return true
end

local function isMember(members, name)
    if not members or members[name] then return true end
    for member, present in pairs(members) do
        if present and member:lower() == name:lower() then return true end
    end
    return false
end

local function prunePending(self, now, members)
    for owner, pending in pairs(self.pending) do
        if now - pending.startedAt >= ns.TIMEOUT or now - pending.sentAt >= ns.TIMEOUT
            or not isMember(members, owner) then self.pending[owner] = nil end
    end
end

local function reservePending(self)
    local count, oldest, oldestAt = 0
    for owner, pending in pairs(self.pending) do
        count = count + 1
        if not oldestAt or pending.startedAt < oldestAt
            or (pending.startedAt == oldestAt and owner < oldest) then
            oldest, oldestAt = owner, pending.startedAt
        end
    end
    if count >= PENDING_LIMIT then self.pending[oldest] = nil end
end

function ns.State.New()
    return setmetatable({ records = {}, seen = {}, pending = {} }, ns.State)
end

-- Only call after current-guild sender authentication. Delegated names never
-- own records or watermarks. Keep the last complete snapshot during assembly.
function ns.State:Apply(sender, packet, now)
    local kind = packet.kind
    if kind ~= "S" and kind ~= "X" and kind ~= "B" and kind ~= "C" then return false end
    if kind == "B" or kind == "C" then
        local encoded = ns.Protocol.Encode(packet)
        if not encoded then return false end
        packet = ns.Protocol.Decode(encoded)
    end
    if packet.sentAt > now + 5 or now - packet.sentAt >= ns.TIMEOUT then return false end
    sender = ownerKey(self, sender)
    prunePending(self, now)
    local watermark = self.seen[sender] or 0
    if packet.revision < watermark then return false end
    local pending = self.pending[sender]
    if packet.revision == watermark then
        if (kind ~= "B" and kind ~= "C") or not pending then return false end
    else
        self.seen[sender] = packet.revision
        self.pending[sender], pending = nil, nil
    end
    local old = self.records[sender]
    if kind == "X" then
        self.records[sender] = nil
        return old ~= nil
    end
    if kind == "S" then
        local record = { name = sender, roles = packet.roles, dungeons = copySelection(packet.dungeons),
            joinedAt = packet.joinedAt, sentAt = packet.sentAt }
        self.records[sender] = record
        return not sameRecord(old, record)
    end
    if not pending then
        reservePending(self)
        pending = { revision = packet.revision, sentAt = packet.sentAt, total = packet.total,
            startedAt = now, members = {} }
        self.pending[sender] = pending
    end
    -- Conflicting fragments poison this revision instead of leaving a valid
    -- subset that could later be combined into a different advertisement.
    if pending.sentAt ~= packet.sentAt or pending.total ~= packet.total then
        self.pending[sender] = nil
        return false
    end
    if kind == "B" then
        if pending.header and (pending.header.joinedAt ~= packet.joinedAt
            or not sameSelection(pending.header.dungeons, packet.dungeons)) then
            self.pending[sender] = nil
            return false
        end
        pending.header = packet
    else
        local oldMember = pending.members[packet.index]
        if oldMember and (oldMember.name ~= packet.name or oldMember.roles ~= packet.roles) then
            self.pending[sender] = nil
            return false
        end
        for index, member in pairs(pending.members) do
            if index ~= packet.index and member.name:lower() == packet.name:lower() then
                self.pending[sender] = nil
                return false
            end
        end
        pending.members[packet.index] = { name = packet.name, roles = packet.roles }
    end
    if not pending.header then return false end
    local members, capacities, senderRole = {}, { [1] = 1, [2] = 1, [4] = 3 }
    for index = 1, pending.total do
        local member = pending.members[index]
        if not member then return false end
        capacities[member.roles] = capacities[member.roles] - 1
        if capacities[member.roles] < 0 then
            self.pending[sender] = nil
            return false
        end
        local name = member.name
        if name:lower() == sender:lower() then name, senderRole = sender, member.roles end
        members[#members + 1] = { name = name, roles = member.roles }
    end
    self.pending[sender] = nil
    if not senderRole then return false end
    table.sort(members, function(left, right) return left.name:lower() < right.name:lower() end)
    local record = { name = sender, roles = senderRole, dungeons = copySelection(pending.header.dungeons),
        joinedAt = pending.header.joinedAt, sentAt = pending.sentAt,
        partyLeader = sender, partySize = pending.total, partyMembers = members }
    self.records[sender] = record
    return not sameRecord(old, record)
end

function ns.State:Prune(now, members)
    prunePending(self, now, members)
    local changed = false
    for name, record in pairs(self.records) do
        if now - record.sentAt >= ns.TIMEOUT or not isMember(members, name) then
            self.records[name], changed = nil, true
        end
    end
    return changed
end

-- Local snapshot invalidation is not a wire withdrawal: preserve the watermark.
function ns.State:Remove(sender)
    sender = ownerKey(self, sender)
    local existed = self.records[sender] ~= nil
    self.records[sender], self.pending[sender] = nil, nil
    return existed
end

function ns.State:Sorted()
    local players, claims, conflicts = {}, {}, {}
    -- All claims shadow solos, even when the claiming parties conflict. Never
    -- salvage only part of an overlapping party or depend on pairs() order.
    for owner, record in pairs(self.records) do
        if record.partyMembers then
            for _, member in ipairs(record.partyMembers) do
                local name = member.name:lower()
                if claims[name] and claims[name] ~= owner then
                    conflicts[owner], conflicts[claims[name]] = true, true
                else
                    claims[name] = owner
                end
            end
        end
    end
    for owner, record in pairs(self.records) do
        if record.partyMembers then
            if not conflicts[owner] then
                for _, member in ipairs(record.partyMembers) do
                    players[#players + 1] = { name = member.name, roles = member.roles, dungeons = record.dungeons,
                        joinedAt = record.joinedAt, sentAt = record.sentAt,
                        partyLeader = record.partyLeader, partySize = record.partySize }
                end
            end
        elseif not claims[record.name:lower()] then
            players[#players + 1] = record
        end
    end
    table.sort(players, function(left, right)
        if left.joinedAt ~= right.joinedAt then return left.joinedAt < right.joinedAt end
        return left.name < right.name
    end)
    local unique, names = {}, {}
    for _, player in ipairs(players) do
        local name = player.name:lower()
        if not names[name] then
            unique[#unique + 1], names[name] = player, true
        end
    end
    return unique
end

function ns.State:Get(name)
    if type(name) ~= "string" then return nil end
    for _, player in ipairs(self:Sorted()) do
        if player.name:lower() == name:lower() then return player end
    end
end
