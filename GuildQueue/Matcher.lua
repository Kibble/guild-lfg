local _, ns = ...

-- Unlike Match, every supplied player must fit. This does not assign or agree
-- on anyone's role; callers can restrict one copy to a clicked role column.
function ns.CanFitRoleSlots(players)
    if type(players) ~= "table" then return false end
    local count = 0
    for index in pairs(players) do
        if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > 5 then return false end
        count = count + 1
    end
    if count < 1 or count > 5 or #players ~= count then return false end
    local slots, names = {}, {}
    local function place(player, visited)
        for slot, role in ipairs(ns.SLOTS) do
            if not visited[slot] and ns.HasRole(player.roles, role) then
                visited[slot] = true
                if not slots[slot] or place(slots[slot], visited) then
                    slots[slot] = player
                    return true
                end
            end
        end
        return false
    end
    for _, player in ipairs(players) do
        if type(player) ~= "table" or type(player.name) ~= "string" or player.name == ""
            or names[player.name:lower()] or type(player.roles) ~= "number"
            or player.roles % 1 ~= 0 or player.roles < 1 or player.roles > 7 then return false end
        names[player.name:lower()] = true
        if not place(player, {}) then return false end
    end
    return true
end

local function candidateForDungeon(players, used, dungeonID)
    local slots, count = {}, 0
    -- Augmenting paths can move an already assigned multi-role player to another
    -- slot. A greedy "pick tank first" implementation would miss valid groups.
    local function place(player, visited)
        for slot, role in ipairs(ns.SLOTS) do
            if not visited[slot] and ns.HasRole(player.roles, role) then
                visited[slot] = true
                if not slots[slot] or place(slots[slot], visited) then
                    slots[slot] = player
                    return true
                end
            end
        end
        return false
    end
    for _, player in ipairs(players) do
        if not used[player.name] and player.dungeons[dungeonID] and place(player, {}) then
            count = count + 1
            if count == #ns.SLOTS then break end
        end
    end
    if count < 2 then return end
    -- Fixed role slots may have holes. Keep a separate dense member list for
    -- iteration: ipairs(slots) would miss a healer/Damage pair with no tank.
    local members, order, included = {}, {}, {}
    for slot = 1, #ns.SLOTS do
        local member = slots[slot]
        if member then
            members[#members + 1] = member
            included[member.name] = true
        end
    end
    for index, member in ipairs(players) do
        if included[member.name] then order[#order + 1] = index end
    end
    return { dungeonID = dungeonID, slots = slots, members = members, order = order }
end

local function earlier(left, right)
    if not right then
        return true
    end
    -- Complete groups first, then the largest compatible partial matches.
    if #left.members ~= #right.members then return #left.members > #right.members end
    for index = 1, #left.order do
        if left.order[index] ~= right.order[index] then
            return left.order[index] < right.order[index]
        end
    end
    return left.dungeonID < right.dungeonID
end

-- Pure, deterministic function: same live queue -> same suggestions on every client.
-- Prefer larger groups, then older feasible candidates. Not a global packing optimizer.
function ns.Match(state)
    local players, used, groups, individuals = state:Sorted(), {}, {}, {}
    while true do
        local best
        for _, dungeon in ipairs(ns.DUNGEONS) do
            local candidate = candidateForDungeon(players, used, dungeon.id)
            if candidate and earlier(candidate, best) then
                best = candidate
            end
        end
        if not best then
            break
        end
        best.dungeons = {}
        for _, dungeon in ipairs(ns.DUNGEONS) do
            local common = true
            for _, player in ipairs(best.members) do
                if not player.dungeons[dungeon.id] then
                    common = false
                    break
                end
            end
            if common then
                best.dungeons[dungeon.id] = true
            end
        end
        for _, player in ipairs(best.members) do
            used[player.name] = true
        end
        groups[#groups + 1] = best
    end
    for _, player in ipairs(players) do
        if not used[player.name] then
            individuals[#individuals + 1] = player
        end
    end
    return groups, individuals
end
