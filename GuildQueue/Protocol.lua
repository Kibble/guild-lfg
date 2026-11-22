local _, ns = ...
ns.Protocol = {}
local Protocol = ns.Protocol

local function integer(text, minimum, maximum)
    if type(text) ~= "string" or not text:match("^%d+$") then
        return nil
    end
    local value = tonumber(text)
    if not value or value < minimum or value > maximum or value % 1 ~= 0 then
        return nil
    end
    return value
end

-- Only canonical stable releases are advertised, never prereleases or URLs.
function Protocol.VersionParts(version)
    if type(version) ~= "string" or #version > 14 then return nil end
    local major, minor, patch = version:match("^(%d+)%.(%d+)%.(%d+)$")
    local parts = {}
    for index, part in ipairs({ major, minor, patch }) do
        local value = integer(part, 0, 9999)
        if not value or tostring(value) ~= part then return nil end
        parts[index] = value
    end
    if #parts ~= 3 then return nil end
    return parts
end

function Protocol.CompareVersions(left, right)
    local a, b = Protocol.VersionParts(left), Protocol.VersionParts(right)
    if not a or not b then return nil end
    for index = 1, 3 do
        if a[index] ~= b[index] then return a[index] > b[index] and 1 or -1 end
    end
    return 0
end

function Protocol.DungeonList(selected)
    local values = {}
    for _, dungeon in ipairs(ns.DUNGEONS) do
        if selected[dungeon.id] then
            values[#values + 1] = tostring(dungeon.id)
        end
    end
    return table.concat(values, ",")
end

function Protocol.DecodeDungeons(text)
    if type(text) ~= "string" or text == "" or text:find("[^%d,]") then
        return nil
    end
    local selected, count = {}, 0
    for token in (text .. ","):gmatch("(.-),") do
        local id = integer(token, 1, 9999)
        if not id or not ns.DUNGEON_BY_ID[id] or selected[id] then
            return nil
        end
        selected[id], count = true, count + 1
    end
    return selected, count
end

-- Queue state never carries a sender identity: the game-provided sender owns
-- it. Optional role notices carry only their intended recipient, not peer state.
function Protocol.Encode(packet)
    if packet.kind == "H" or packet.kind == "P" then
        return "1|" .. packet.kind
    end
    if packet.kind == "V" then
        return table.concat({ "1", "V", string.format("%.0f", packet.sentAt), packet.version }, "|")
    end
    if packet.kind == "F" or packet.kind == "U" then
        local parts = { "1", packet.kind, string.format("%.0f", packet.sentAt),
            string.format("%.0f", packet.claimID), packet.matchupKey }
        if packet.kind == "F" then parts[6] = string.format("%.0f", packet.replacesID or 0) end
        return table.concat(parts, "|")
    end
    if packet.kind == "R" then
        return table.concat({ "1", "R", string.format("%.0f", packet.sentAt),
            tostring(packet.role), packet.target }, "|")
    end
    local parts = { "1", packet.kind, string.format("%.0f", packet.revision),
        string.format("%.0f", packet.sentAt) }
    if packet.kind == "S" then
        parts[#parts + 1] = string.format("%.0f", packet.joinedAt)
        parts[#parts + 1] = tostring(packet.roles)
        parts[#parts + 1] = Protocol.DungeonList(packet.dungeons)
    end
    return table.concat(parts, "|")
end

function Protocol.Decode(message)
    if type(message) ~= "string" or #message > 255 or message:find("%z") then
        return nil
    end
    if message == "1|H" or message == "1|P" then
        return { kind = message:sub(3) }
    end
    local fields = {}
    for field in (message .. "|"):gmatch("(.-)|") do
        fields[#fields + 1] = field
    end
    if fields[1] ~= "1" then
        return nil
    end
    local kind = fields[2]
    if kind == "V" then
        local sentAt = integer(fields[3], 1, 9999999999)
        if #fields ~= 4 or not sentAt or not Protocol.VersionParts(fields[4]) then return nil end
        return { kind = kind, sentAt = sentAt, version = fields[4] }
    end
    if kind == "F" or kind == "U" then
        local sentAt = integer(fields[3], 1, 9999999999)
        local claimID = integer(fields[4], 1, 9007199254740990)
        local key = fields[5]
        local replacesID = 0
        if kind == "F" then replacesID = integer(fields[6], 0, 9007199254740990) end
        if #fields ~= (kind == "F" and 6 or 5) or not sentAt or not claimID or type(key) ~= "string"
            or #key ~= 16 or key:find("[^0-9a-f]") or replacesID == nil
            or replacesID >= claimID then return nil end
        return { kind = kind, sentAt = sentAt, claimID = claimID, matchupKey = key, replacesID = replacesID }
    end
    if kind == "R" then
        local sentAt = integer(fields[3], 1, 9999999999)
        local role = integer(fields[4], 1, 4)
        local target = fields[5]
        if #fields ~= 5 or not sentAt or (role ~= 1 and role ~= 2 and role ~= 4)
            or type(target) ~= "string" or #target > 128 or target:find("[%c%s|]")
            or not target:match("^[^%-]+%-.+$") then return nil end
        return { kind = "R", sentAt = sentAt, role = role, target = target }
    end
    if not ((kind == "X" and #fields == 4) or (kind == "S" and #fields == 7)) then
        return nil
    end
    local revision = integer(fields[3], 1, 9007199254740990)
    local sentAt = integer(fields[4], 1, 9999999999)
    if not revision or not sentAt then
        return nil
    end
    local packet = { kind = kind, revision = revision, sentAt = sentAt }
    if kind == "S" then
        packet.joinedAt = integer(fields[5], 1, sentAt)
        packet.roles = integer(fields[6], 1, 7)
        packet.dungeons = Protocol.DecodeDungeons(fields[7])
        if not packet.joinedAt or not packet.roles or not packet.dungeons then
            return nil
        end
    end
    return packet
end

function Protocol.ValidSelections(roles, dungeons)
    if type(roles) ~= "number" or roles % 1 ~= 0 or roles < 1 or roles > 7 then
        return false
    end
    if type(dungeons) ~= "table" then
        return false
    end
    local any = false
    for id, selected in pairs(dungeons) do
        if selected then
            if not ns.DUNGEON_BY_ID[id] then
                return false
            end
            any = true
        end
    end
    return any
end
