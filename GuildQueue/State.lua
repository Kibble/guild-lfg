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

function ns.State.New()
    return setmetatable({ records = {}, seen = {} }, ns.State)
end

-- Only call after protocol validation and current-guild sender authentication.
-- Highest revisions survive expiry/withdrawal, so old messages cannot resurrect users.
function ns.State:Apply(sender, packet, now)
    if packet.kind == "H" or packet.sentAt > now + 5
        or now - packet.sentAt >= ns.TIMEOUT
        or packet.revision <= (self.seen[sender] or 0) then
        return false
    end
    self.seen[sender] = packet.revision
    local old = self.records[sender]
    if packet.kind == "X" then
        self.records[sender] = nil
        return old ~= nil
    end
    local dungeons = {}
    for id, selected in pairs(packet.dungeons) do
        if selected then
            dungeons[id] = true
        end
    end
    self.records[sender] = {
        name = sender, roles = packet.roles, dungeons = dungeons,
        joinedAt = packet.joinedAt, sentAt = packet.sentAt,
    }
    return not old or old.roles ~= packet.roles or old.joinedAt ~= packet.joinedAt
        or not sameSelection(old.dungeons, dungeons)
end

function ns.State:Prune(now, members)
    local changed = false
    for name, record in pairs(self.records) do
        if now - record.sentAt >= ns.TIMEOUT or (members and not members[name]) then
            self.records[name], changed = nil, true
        end
    end
    return changed
end

function ns.State:Sorted()
    local players = {}
    for _, player in pairs(self.records) do
        players[#players + 1] = player
    end
    table.sort(players, function(left, right)
        if left.joinedAt ~= right.joinedAt then
            return left.joinedAt < right.joinedAt
        end
        return left.name < right.name
    end)
    return players
end
