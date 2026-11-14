local _, ns = ...
local Q = {}
ns.Questing = Q
Q.__index = Q

local MAX_REVISION, MAX_ID = 9007199254740990, 2147483647
local MAX_QUESTS, MAX_PARTS, MAX_MESSAGE = 200, 32, 255

local function validInteger(value, minimum, maximum)
    return type(value) == "number" and value >= minimum and value <= maximum
        and value % 1 == 0
end

local function integer(text, minimum, maximum)
    if type(text) ~= "string" or not text:match("^%d+$") then return nil end
    local value = tonumber(text)
    if validInteger(value, minimum, maximum) then return value end
end

local function decimal(value)
    return string.format("%.0f", value)
end

function Q.New()
    return setmetatable({ peers = {}, buffers = {}, seen = {} }, Q)
end

function Q.Encode(revision, sentAt, zoneID, level, quests)
    assert(validInteger(revision, 1, MAX_REVISION), "invalid revision")
    assert(validInteger(sentAt, 1, 9999999999), "invalid timestamp")
    assert(validInteger(zoneID, 0, MAX_ID), "invalid zone ID")
    assert(validInteger(level, 0, 1000), "invalid level")
    assert(type(quests) == "table", "invalid quest map")
    local ids = {}
    for id, complete in pairs(quests) do
        assert(validInteger(id, 1, MAX_ID), "invalid quest ID")
        assert(type(complete) == "boolean", "invalid quest status")
        ids[#ids + 1] = id
        assert(#ids <= MAX_QUESTS, "too many quests")
    end
    table.sort(ids)
    local entries = {}
    for index, id in ipairs(ids) do
        entries[index] = decimal(id) .. ":" .. (quests[id] and "1" or "0")
    end
    local prefix = "1|Q|" .. decimal(revision) .. "|" .. decimal(sentAt)
        .. "|" .. decimal(zoneID) .. "|" .. decimal(level) .. "|"
    local function header(part, parts)
        return prefix .. decimal(part) .. "|" .. decimal(parts) .. "|"
    end
    -- Repack when the part count changes, including its number of digits.
    local parts = 1
    while true do
        local messages, part = {}, 1
        local message, hasEntry = header(part, parts), false
        for _, entry in ipairs(entries) do
            local suffix = (hasEntry and "," or "") .. entry
            if #message + #suffix > MAX_MESSAGE then
                messages[#messages + 1] = message
                part = part + 1
                message, hasEntry = header(part, parts), false
                suffix = entry
            end
            message, hasEntry = message .. suffix, true
        end
        messages[#messages + 1] = message
        assert(#messages <= MAX_PARTS, "too many parts")
        if #messages == parts then return messages end
        parts = #messages
    end
end

function Q.EncodeStop(revision, sentAt)
    assert(validInteger(revision, 1, MAX_REVISION), "invalid revision")
    assert(validInteger(sentAt, 1, 9999999999), "invalid timestamp")
    return "1|QX|" .. decimal(revision) .. "|" .. decimal(sentAt)
end

function Q.Decode(message)
    if type(message) ~= "string" or #message > MAX_MESSAGE or message:find("%z") then
        return nil
    end
    local fields = {}
    for field in (message .. "|"):gmatch("(.-)|") do
        fields[#fields + 1] = field
    end
    if fields[1] ~= "1" then return nil end
    local kind = fields[2]
    if not ((kind == "Q" and #fields == 9) or (kind == "QX" and #fields == 4)) then
        return nil
    end
    local revision = integer(fields[3], 1, MAX_REVISION)
    local sentAt = integer(fields[4], 1, 9999999999)
    if not revision or not sentAt then return nil end
    local packet = { kind = kind, revision = revision, sentAt = sentAt }
    if kind == "QX" then return packet end
    packet.zoneID = integer(fields[5], 0, MAX_ID)
    packet.level = integer(fields[6], 0, 1000)
    packet.part = integer(fields[7], 1, MAX_PARTS)
    packet.parts = integer(fields[8], 1, MAX_PARTS)
    if not packet.zoneID or not packet.level or not packet.part or not packet.parts
        or packet.part > packet.parts then
        return nil
    end
    packet.quests = {}
    if fields[9] ~= "" then
        local count = 0
        for entry in (fields[9] .. ","):gmatch("(.-),") do
            local idText, status = entry:match("^(%d+):([01])$")
            local id = integer(idText, 1, MAX_ID)
            if not id or packet.quests[id] ~= nil then return nil end
            count = count + 1
            if count > MAX_QUESTS then return nil end
            packet.quests[id] = status == "1"
        end
    end
    return packet
end

local function fresh(sentAt, now)
    return sentAt <= now + 5 and now - sentAt < (ns.TIMEOUT or 75)
end

-- Call only after Decode validation and guild-channel sender authentication.
-- Watermarks include in-progress snapshots and survive withdrawal and expiry.
function Q:Apply(sender, packet, now)
    if not fresh(packet.sentAt, now) then return false end
    local seen = self.seen[sender] or 0
    if packet.revision < seen then return false end
    local buffer = self.buffers[sender]
    if packet.revision == seen then
        if not buffer or packet.kind ~= "Q" then return false end
    else
        self.seen[sender] = packet.revision
        self.buffers[sender] = nil
        buffer = nil
        if packet.kind == "QX" then
            local changed = self.peers[sender] ~= nil
            self.peers[sender] = nil
            return changed
        end
    end
    if not buffer then
        buffer = { revision = packet.revision, sentAt = packet.sentAt,
            zoneID = packet.zoneID, level = packet.level, parts = packet.parts,
            chunks = {}, quests = {}, received = 0, count = 0 }
        self.buffers[sender] = buffer
    end
    if buffer.sentAt ~= packet.sentAt or buffer.zoneID ~= packet.zoneID
        or buffer.level ~= packet.level or buffer.parts ~= packet.parts
        or buffer.chunks[packet.part] then
        return false
    end
    local count = 0
    for id in pairs(packet.quests) do
        -- Test membership, not truthiness: incomplete quests also occupy IDs.
        if buffer.quests[id] ~= nil then return false end
        count = count + 1
    end
    if buffer.count + count > MAX_QUESTS then return false end
    for id, complete in pairs(packet.quests) do buffer.quests[id] = complete end
    buffer.count = buffer.count + count
    buffer.chunks[packet.part] = true
    buffer.received = buffer.received + 1
    if buffer.received ~= buffer.parts then return false end
    self.peers[sender] = { revision = buffer.revision, sentAt = buffer.sentAt,
        zoneID = buffer.zoneID, level = buffer.level, quests = buffer.quests }
    self.buffers[sender] = nil
    return true
end

function Q:Prune(now)
    local changed = false
    for sender, peer in pairs(self.peers) do
        if not fresh(peer.sentAt, now) then
            self.peers[sender], changed = nil, true
        end
    end
    for sender, buffer in pairs(self.buffers) do
        if not fresh(buffer.sentAt, now) then
            self.seen[sender] = math.max(self.seen[sender] or 0, buffer.revision)
            self.buffers[sender], changed = nil, true
        end
    end
    return changed
end

function Q.Common(ours, theirs)
    local common = {}
    for id, complete in pairs(ours or {}) do
        if theirs and theirs[id] ~= nil then
            common[#common + 1] = { questID = id, localComplete = complete,
                peerComplete = theirs[id] }
        end
    end
    table.sort(common, function(left, right) return left.questID < right.questID end)
    return common
end
