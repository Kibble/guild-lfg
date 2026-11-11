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

-- No identity is carried in the payload: the game-provided sender owns this state.
function Protocol.Encode(packet)
    if packet.kind == "H" or packet.kind == "P" then
        return "1|" .. packet.kind
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
