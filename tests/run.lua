-- Run from the project root: lua5.1 tests/run.lua
local passed, failed = 0, 0
local function test(name, run)
    local ok, err = pcall(run)
    if ok then
        passed = passed + 1
        print("PASS " .. name)
    else
        failed = failed + 1
        print("FAIL " .. name .. ": " .. tostring(err))
    end
end
local function equal(actual, expected)
    assert(actual == expected, "expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local function loadModule(ns, name)
    assert(loadfile("GuildQueue/" .. name .. ".lua"))("GuildQueue", ns)
end
local function pure()
    local ns = {}
    for _, module in ipairs({ "Catalog", "Protocol", "State", "Matcher", "Questing" }) do
        loadModule(ns, module)
    end
    return ns
end
local ns = pure()
local function packet(revision, roles, dungeons, joinedAt, sentAt)
    return { kind = "S", revision = revision, roles = roles or 4, dungeons = dungeons or { [1] = true },
        joinedAt = joinedAt or 900, sentAt = sentAt or 1000 }
end
local function add(state, name, roles, dungeons, joinedAt)
    assert(state:Apply(name, packet(1, roles, dungeons, joinedAt), 1000))
end
local function signature(groups, individuals)
    local values = {}
    for _, group in ipairs(groups) do
        values[#values + 1] = tostring(group.dungeonID)
        for slot = 1, #ns.SLOTS do
            local player = group.slots[slot]
            if player then values[#values + 1] = slot .. ":" .. player.name end
        end
    end
    values[#values + 1] = "individuals"
    for _, player in ipairs(individuals) do
        values[#values + 1] = player.name
    end
    return table.concat(values, ";")
end

-- Serialization and input validation.
test("round trip all roles and all dungeons fits the wire limit", function()
    local selected = {}
    for _, dungeon in ipairs(ns.DUNGEONS) do selected[dungeon.id] = true end
    local text = ns.Protocol.Encode(packet(1800000000001, 7, selected))
    assert(#text <= 255)
    local decoded = assert(ns.Protocol.Decode(text))
    equal(decoded.roles, 7)
    equal(decoded.revision, 1800000000001)
    equal(ns.Protocol.DungeonList(decoded.dungeons), ns.Protocol.DungeonList(selected))
end)
test("hello and presence messages round trip with withdrawals", function()
    equal(ns.Protocol.Decode("1|H").kind, "H")
    equal(ns.Protocol.Decode(ns.Protocol.Encode({ kind = "P" })).kind, "P")
    equal(ns.Protocol.Decode(ns.Protocol.Encode({ kind = "X", revision = 2, sentAt = 1000 })).kind, "X")
end)
test("malformed or incompatible payloads are rejected", function()
    for _, text in ipairs({ "", "2|H", "1|H|extra", "1|S|1|1000|900|0|1",
        "1|S|1|1000|900|8|1", "1|S|nan|1000|900|4|1", "1|S|1|1000|1001|4|1",
        "1|S|1|1000|900|4|", "1|S|1|1000|900|4|999", "1|S|1|1000|900|4|1,1",
        "1|S|1|1000|900|4|1,", "1|S|1|1000|900|4|,1", "1|X|1|1000|extra",
        "1|X|0|1000", "1|X|1.5|1000", "1|H\0", string.rep("x", 256) }) do
        assert(ns.Protocol.Decode(text) == nil, "accepted invalid packet: " .. text)
    end
end)
test("selection validation requires at least one of each", function()
    assert(ns.Protocol.ValidSelections(3, { [1] = true, [2] = true }))
    assert(not ns.Protocol.ValidSelections(0, { [1] = true }))
    assert(not ns.Protocol.ValidSelections(4, {}))
    assert(not ns.Protocol.ValidSelections(4, { [999] = true }))
end)

test("role filtering preserves exactly the selected roles the class supports", function()
    for mask = 0, 7 do
        for allowed = 1, 7 do
            local filtered = ns.FilterRoles(mask, allowed)
            for _, role in ipairs({ 1, 2, 4 }) do
                equal(ns.HasRole(filtered, role), ns.HasRole(mask, role) and ns.HasRole(allowed, role))
            end
        end
    end
    equal(ns.FilterRoles("bad", 6), 0)
    equal(ns.FilterRoles(8, 6), 0)
end)

test("common dungeon selections are a new intersection without changing either input", function()
    local left, right = { [1] = true, [2] = true }, { [2] = true, [3] = true }
    local shared = ns.CommonDungeons(left, right)
    assert(shared[2] and not shared[1] and not shared[3])
    shared[2] = nil
    assert(left[2] and right[2])
    assert(next(ns.CommonDungeons({}, right)) == nil)
end)

test("all dungeon names display recommended ranges without changing permanent IDs or wire lists", function()
    equal(#ns.DUNGEONS, 34)
    for id, dungeon in ipairs(ns.DUNGEONS) do
        equal(dungeon.id, id)
        assert(dungeon.minLevel >= 1 and dungeon.minLevel <= dungeon.maxLevel and dungeon.maxLevel <= 60)
        assert(not dungeon.name:find("%(%d+%-%d+%)"))
        equal(ns.DungeonName(dungeon), dungeon.name .. " (" .. dungeon.minLevel .. "-" .. dungeon.maxLevel .. ")")
    end
    equal(ns.DungeonName(ns.DUNGEON_BY_ID[2]), "Hall of Thanes (13-20)")
    equal(ns.DungeonText({ [1] = true, [9] = true }), "Ragefire Chasm (13-18), Excavation Site (26-33)")
    equal(ns.Protocol.DungeonList({ [1] = true, [9] = true }), "1,9")
    equal(ns.DungeonName({ name = "Unknown" }), "Unknown")
end)
test("optional requested-role notices round trip and reject malformed targets roles and dates", function()
    local p = ns.Protocol.Decode(ns.Protocol.Encode({ kind = "R", sentAt = 1000, role = 2, target = "Friend-TestRealm" }))
    equal(p.kind, "R") equal(p.role, 2) equal(p.target, "Friend-TestRealm") equal(p.sentAt, 1000)
    for _, message in ipairs({ "1|R|1000|3|Friend-TestRealm", "1|R|1000|0|Friend-TestRealm",
        "1|R|0|1|Friend-TestRealm", "1|R|1000|1|Friend", "1|R|1000|1|Friend TestRealm",
        "1|R|1000|1|Friend-TestRealm|extra", "1|R|1000|1|Friend-\nRealm" }) do
        assert(ns.Protocol.Decode(message) == nil, message)
    end
end)

test("formation start and release packets round trip within the unchanged message size limit", function()
    for _, kind in ipairs({ "F", "U" }) do
        local text = ns.Protocol.Encode({ kind = kind, sentAt = 1000, claimID = 9007199254740990,
            matchupKey = "0123456789abcdef" })
        assert(#text <= 255)
        local p = ns.Protocol.Decode(text)
        equal(p.kind, kind) equal(p.sentAt, 1000) equal(p.claimID, 9007199254740990)
        equal(p.matchupKey, "0123456789abcdef")
    end
end)
test("formation packets reject invalid timestamps tokens fingerprints and extra fields", function()
    for _, text in ipairs({ "1|F|0|1|0123456789abcdef|0", "1|F|1000|0|0123456789abcdef|0",
        "1|U|1000|9007199254740991|0123456789abcdef", "1|F|1000|1|0123456789abcdeF|0",
        "1|F|1000|1|0123456789abcde|0", "1|U|1000|1|0123456789abcdef|extra", "2|F|1000|1|0123456789abcdef|0",
        "1|F|1000|2|0123456789abcdef|bad", "1|F|1000|2|0123456789abcdef|2", "1|F|1000|2|0123456789abcdef|-1" }) do
        assert(ns.Protocol.Decode(text) == nil, text)
    end
end)

-- Versioning, leases, tombstones and membership.
test("out of order and duplicate messages cannot change the live queue", function()
    local state = ns.State.New()
    assert(state:Apply("A-Realm", packet(2, 1), 1000))
    assert(not state:Apply("A-Realm", packet(1, 2), 1000))
    assert(not state:Apply("A-Realm", packet(2, 2), 1001))
    equal(state.records["A-Realm"].roles, 1)
    equal(state.records["A-Realm"].sentAt, 1000)
end)
test("withdrawal tombstone prevents resurrection", function()
    local state = ns.State.New()
    state:Apply("A", packet(1), 1000)
    assert(state:Apply("A", { kind = "X", revision = 3, sentAt = 1001 }, 1001))
    assert(not state:Apply("A", packet(2), 1002))
    equal(state.records.A, nil)
    assert(state:Apply("A", packet(4, 4, nil, 1003, 1003), 1003))
end)
test("heartbeats refresh freshness without triggering new matching", function()
    local state = ns.State.New()
    state:Apply("A", packet(1), 1000)
    assert(not state:Apply("A", packet(2, 4, nil, 900, 1020), 1020))
    equal(state.records.A.sentAt, 1020)
    equal(state.records.A.joinedAt, 900)
    assert(not state:Prune(1094))
    assert(state:Prune(1095))
    equal(state.records.A, nil)
    equal(state.seen.A, 2)
end)
test("stale and implausibly future packets are ignored", function()
    local state = ns.State.New()
    assert(not state:Apply("A", packet(1, 4, nil, 800, 925), 1000))
    assert(not state:Apply("A", packet(2, 4, nil, 900, 1006), 1000))
    equal(state.records.A, nil)
end)
test("expired revisions cannot revive from delayed packets", function()
    local state = ns.State.New()
    state:Apply("A", packet(10), 1000)
    state:Prune(1075)
    assert(not state:Apply("A", packet(9, 4, nil, 900, 1075), 1075))
    assert(not state:Apply("A", packet(11), 1075))
end)
test("optional membership pruning keeps the revision watermark", function()
    local state = ns.State.New()
    add(state, "A", 1)
    add(state, "B", 2)
    assert(state:Prune(1001, { A = true }))
    assert(state.records.A)
    equal(state.records.B, nil)
    equal(state.seen.B, 1)
end)
test("selection changes are copied and retain queue age", function()
    local state, selected = ns.State.New(), { [1] = true }
    state:Apply("A", packet(1, 3, selected), 1000)
    selected[2] = true
    equal(state.records.A.dungeons[2], nil)
    assert(state:Apply("A", packet(2, 3, selected), 1000))
    equal(state.records.A.joinedAt, 900)
end)

-- Matching constraints and deterministic fairness.
test("damage-only partial groups never fill nonexistent tank or healer slots", function()
    local state = ns.State.New()
    for i = 1, 6 do add(state, "D" .. i, 4) end
    local groups, individuals = ns.Match(state)
    equal(#groups, 2)
    equal(#individuals, 0)
    for _, group in ipairs(groups) do
        equal(#group.members, 3)
        assert(not group.slots[1] and not group.slots[2])
        for slot = 3, 5 do assert(group.slots[slot]) end
    end
end)
test("healer and damage form a partial match with a genuinely empty tank slot", function()
    local state = ns.State.New()
    add(state, "Healer", 2, { [1] = true, [2] = true })
    add(state, "Damage", 4, { [1] = true })
    local groups, individuals = ns.Match(state)
    equal(#groups, 1)
    equal(#individuals, 0)
    equal(#groups[1].members, 2)
    assert(not groups[1].slots[1])
    equal(groups[1].slots[2].name, "Healer")
    assert(groups[1].dungeons[1] and not groups[1].dungeons[2])
end)
test("partial matching reassigns flexible roles rather than rejecting a compatible peer", function()
    local state = ns.State.New()
    add(state, "A-Flexible", 3, nil, 800)
    add(state, "B-Tank", 1, nil, 801)
    local groups = ns.Match(state)
    equal(#groups[1].members, 2)
    equal(groups[1].slots[1].name, "B-Tank")
    equal(groups[1].slots[2].name, "A-Flexible")
    assert(not groups[1].slots[3])
end)
test("singletons incompatible roles and disjoint dungeons remain individuals", function()
    for _, pair in ipairs({ { 1, 1, 1 }, { 2, 2, 1 }, { 2, 4, 2 } }) do
        local state = ns.State.New()
        add(state, "First", pair[1], { [1] = true })
        local groups, individuals = ns.Match(state)
        equal(#groups, 0)
        equal(#individuals, 1)
        add(state, "Second", pair[2], { [pair[3]] = true })
        groups, individuals = ns.Match(state)
        equal(#groups, 0)
        equal(#individuals, 2)
    end
end)
test("complete matches take priority over older partial matches", function()
    local state = ns.State.New()
    add(state, "Old-Tank", 1, { [1] = true }, 800)
    add(state, "Old-Healer", 2, { [1] = true }, 801)
    for index, role in ipairs({ 1, 2, 4, 4, 4 }) do
        add(state, "New" .. index, role, { [2] = true }, 810 + index)
    end
    local groups, individuals = ns.Match(state)
    equal(#groups, 2)
    equal(#groups[1].members, 5)
    equal(groups[1].dungeonID, 2)
    equal(#groups[2].members, 2)
    equal(groups[2].dungeonID, 1)
    equal(#individuals, 0)
end)
test("partial matches prefer larger groups then oldest compatible candidates", function()
    local state = ns.State.New()
    add(state, "Old-Tank", 1, { [1] = true }, 800)
    add(state, "Old-Healer", 2, { [1] = true }, 801)
    for index, role in ipairs({ 2, 4, 4, 4 }) do
        add(state, "New" .. index, role, { [2] = true }, 810 + index)
    end
    local groups = ns.Match(state)
    equal(#groups[1].members, 4)
    equal(groups[1].dungeonID, 2)
    equal(#groups[2].members, 2)
    -- Equal-sized candidates: age wins, even when its dungeon ID is larger.
    local tied = ns.State.New()
    add(tied, "Tank", 1, { [1] = true, [2] = true }, 800)
    add(tied, "Older-Healer", 2, { [2] = true }, 801)
    add(tied, "Newer-Healer", 2, { [1] = true }, 802)
    local tiedGroups, individuals = ns.Match(tied)
    equal(tiedGroups[1].dungeonID, 2)
    equal(individuals[1].name, "Newer-Healer")
end)
test("multi-role tank/healer can be reassigned to make a valid group", function()
    local state = ns.State.New()
    add(state, "A-Flexible", 3, nil, 800)
    add(state, "B-Tank", 1, nil, 801)
    for i = 1, 3 do add(state, "D" .. i, 4, nil, 802 + i) end
    local groups, individuals = ns.Match(state)
    equal(#groups, 1)
    equal(#individuals, 0)
    equal(groups[1].slots[1].name, "B-Tank")
    equal(groups[1].slots[2].name, "A-Flexible")
end)
test("pairwise dungeon overlap is insufficient without a common dungeon", function()
    local state = ns.State.New()
    add(state, "Tank", 1, { [1] = true, [2] = true })
    add(state, "Heal", 2, { [2] = true, [3] = true })
    for i = 1, 3 do add(state, "D" .. i, 4, { [1] = true, [3] = true }) end
    local groups, individuals = ns.Match(state)
    equal(#groups, 1)
    equal(#groups[1].members, 4) -- No full five-player match from pairwise overlap.
    equal(#individuals, 1)
    for _, member in ipairs(groups[1].members) do assert(member.dungeons[groups[1].dungeonID]) end
end)
test("common dungeons and assigned roles are retained", function()
    local state, selected = ns.State.New(), { [1] = true, [2] = true }
    add(state, "Tank", 1, selected)
    add(state, "Heal", 2, selected)
    for i = 1, 3 do add(state, "D" .. i, 4, selected) end
    local groups = ns.Match(state)
    equal(groups[1].dungeonID, 1)
    assert(groups[1].dungeons[1] and groups[1].dungeons[2])
    for slot, player in ipairs(groups[1].slots) do
        assert(ns.HasRole(player.roles, ns.SLOTS[slot]))
    end
end)
test("each queued player appears exactly once across groups and individuals", function()
    local state, seen = ns.State.New(), {}
    for i = 1, 13 do add(state, "Player" .. i, 7, nil, 800 + i) end
    local groups, individuals = ns.Match(state)
    equal(#groups, 3)
    equal(#individuals, 0)
    for _, group in ipairs(groups) do
        for _, player in ipairs(group.members) do
            assert(not seen[player.name])
            seen[player.name] = true
        end
    end
    for _, player in ipairs(individuals) do
        assert(not seen[player.name])
        seen[player.name] = true
    end
    local count = 0
    for _ in pairs(seen) do count = count + 1 end
    equal(count, 13)
    equal(#groups[3].members, 3)
    local lastNames = {}
    for _, member in ipairs(groups[3].members) do lastNames[member.name] = true end
    assert(lastNames.Player11 and lastNames.Player12 and lastNames.Player13)
end)
test("input insertion order does not affect matching", function()
    local forward, reverse = ns.State.New(), ns.State.New()
    for i = 1, 12 do add(forward, "Player" .. i, 7, { [1] = true, [2] = true }, 900) end
    for i = 12, 1, -1 do add(reverse, "Player" .. i, 7, { [2] = true, [1] = true }, 900) end
    equal(signature(ns.Match(forward)), signature(ns.Match(reverse)))
end)
test("oldest feasible candidate wins across dungeon choices", function()
    local state = ns.State.New()
    add(state, "Old-Tank", 1, { [2] = true }, 800)
    add(state, "New-Tank", 1, { [1] = true }, 801)
    add(state, "Heal", 2, { [1] = true, [2] = true }, 802)
    for i = 1, 3 do add(state, "D" .. i, 4, { [1] = true, [2] = true }, 802 + i) end
    local groups, individuals = ns.Match(state)
    equal(groups[1].dungeonID, 2)
    equal(groups[1].slots[1].name, "Old-Tank")
    equal(individuals[1].name, "New-Tank")
end)

-- Small brute-force oracle validates existence, not just handpicked examples.
local function possible(players, dungeonID, slot, used)
    if slot > 5 then return true end
    for index, player in ipairs(players) do
        if not used[index] and player.dungeons[dungeonID] and ns.HasRole(player.roles, ns.SLOTS[slot]) then
            used[index] = true
            if possible(players, dungeonID, slot + 1, used) then return true end
            used[index] = nil
        end
    end
    return false
end
-- Independent exhaustive assignment with optional empty slots, for partial matches.
local function maximumMatch(players, dungeonID, slot, used)
    if slot > #ns.SLOTS then return 0 end
    local best = maximumMatch(players, dungeonID, slot + 1, used)
    for index, player in ipairs(players) do
        if not used[index] and player.dungeons[dungeonID] and ns.HasRole(player.roles, ns.SLOTS[slot]) then
            used[index] = true
            best = math.max(best, 1 + maximumMatch(players, dungeonID, slot + 1, used))
            used[index] = nil
        end
    end
    return best
end

test("matcher agrees with brute-force full and partial feasibility on 200 generated queues", function()
    math.randomseed(314159)
    for iteration = 1, 200 do
        local state = ns.State.New()
        for i = 1, math.random(5, 9) do
            local selected = {}
            if math.random(0, 1) == 1 then selected[1] = true end
            if math.random(0, 1) == 1 then selected[2] = true end
            if not next(selected) then selected[3] = true end
            add(state, "P" .. i, math.random(1, 7), selected, 800 + i)
        end
        local players = state:Sorted()
        local feasible = false
        for id = 1, 3 do feasible = feasible or possible(players, id, 1, {}) end
        local groups, individuals = ns.Match(state)
        equal(groups[1] ~= nil and #groups[1].members == 5, feasible)
        local seen, remaining = {}, players
        for _, group in ipairs(groups) do
            local best = 0
            for id = 1, 3 do best = math.max(best, maximumMatch(remaining, id, 1, {})) end
            equal(#group.members, best)
            local occupied = 0
            for slot = 1, #ns.SLOTS do
                local player = group.slots[slot]
                if player then
                    occupied = occupied + 1
                    assert(not seen[player.name])
                    seen[player.name] = true
                    assert(ns.HasRole(player.roles, ns.SLOTS[slot]))
                    assert(player.dungeons[group.dungeonID])
                    for id in pairs(group.dungeons) do assert(player.dungeons[id]) end
                end
            end
            equal(occupied, #group.members)
            local rest = {}
            for _, player in ipairs(remaining) do
                if not seen[player.name] then rest[#rest + 1] = player end
            end
            remaining = rest
        end
        for _, player in ipairs(individuals) do
            assert(not seen[player.name])
            seen[player.name] = true
        end
        local count = 0
        for _ in pairs(seen) do count = count + 1 end
        equal(count, #players)
        for id = 1, 3 do assert(maximumMatch(individuals, id, 1, {}) < 2) end
    end
end)

test("party role-slot checks agree with exhaustive assignment and never mutate offered roles", function()
    math.randomseed(1313)
    for iteration = 1, 200 do
        local players, masks = {}, {}
        for index = 1, math.random(1, 6) do
            local role = math.random(1, 7)
            players[index], masks[index] = { name = "P" .. index, roles = role, dungeons = { [1] = true } }, role
        end
        equal(ns.CanFitRoleSlots(players), maximumMatch(players, 1, 1, {}) == #players)
        for index, player in ipairs(players) do equal(player.roles, masks[index]) end
    end
    assert(not ns.CanFitRoleSlots({ { name = "Same", roles = 1 }, { name = "same", roles = 2 } }))
end)

-- Minimal simulated clients exercise real Core code, not a second implementation.
-- UI is separately syntax-checked and smoke-tested below with widget stubs.
local function client(options)
    options = options or {}
    local c = { now = 1800000000, clock = 0, sent = {}, messages = {}, invites = {},
        guild = "Test Guild", roster = options.roster or { "Self-TestRealm", "Friend-TestRealm" },
        result = 0, locked = false, homeGroup = false, instanceGroup = false, combat = false }
    c.guildInfoUnavailable, c.nameUnavailable = options.guildInfoUnavailable, options.nameUnavailable
    c.allowedRoles = options.allowedRoles == nil and 7 or options.allowedRoles
    c.rolesUnavailable, c.roleAPIError = options.rolesUnavailable, options.roleAPIError
    c.zoneID, c.zoneName, c.level = 37, "Elwynn Forest", 23
    c.questLog, c.rosterInfo, c.mapInfo = options.quests or {}, options.rosterInfo or {}, {}
    if options.noGuild then c.guild = nil end
    local env = setmetatable({}, { __index = _G })
    c.ns, c.env = pure(), env
    c.ns.RefreshUI = function() end
    c.ns.ToggleUI = function() c.toggled = true end
    env.GuildQueueDB = options.saved or { roles = 4, dungeons = { [1] = true } }
    env.GetTime = function() return c.clock end
    env.GetServerTime = function() return c.now end
    env.GetNormalizedRealmName = function() return "TestRealm" end
    env.UnitFullName = function(unit)
        local index = type(unit) == "string" and (unit:match("^party(%d+)$") or unit:match("^raid(%d+)$"))
        if index then
            local members = unit:match("^raid") and c.raidMembers or c.partyMembers
            local member = (members or {})[tonumber(index)]
            if type(member) == "table" then return member.name, member.realm end
            if type(member) ~= "string" then return nil end
            local name, realm = member:match("^(.-)%-(.+)$")
            return name or member, realm
        end
        if c.nameUnavailable then return nil end
        return options.characterName or "Self", options.characterRealm or "Test Realm"
    end
    if not options.noRoleAPI then
        env.UnitGetAvailableRoles = function(unit)
            equal(unit, "player")
            if c.roleAPIError then error("Role data unavailable") end
            if c.rolesUnavailable then return nil end
            return c.ns.HasRole(c.allowedRoles, 1), c.ns.HasRole(c.allowedRoles, 2), c.ns.HasRole(c.allowedRoles, 4)
        end
    end
    env.IsInGuild = function() return c.guild ~= nil end
    env.LE_PARTY_CATEGORY_HOME, env.LE_PARTY_CATEGORY_INSTANCE = 1, 2
    env.IsInGroup = function(category)
        if category == 2 then return c.instanceGroup end
        return c.homeGroup
    end
    env.IsInRaid = function() return c.raid == true end
    env.GetNumSubgroupMembers = function(category)
        equal(category, env.LE_PARTY_CATEGORY_HOME)
        return c.partyCount or #(c.partyMembers or {})
    end
    env.GetNumGroupMembers = function(category)
        equal(category, env.LE_PARTY_CATEGORY_HOME)
        return #(c.raidMembers or {})
    end
    env.InCombatLockdown = function() return c.combat end
    env.C_PartyInfo = {
        CanInvite = function() return c.canInvite ~= false end,
        IsPartyFull = function() return c.partyFull == true end,
        InviteUnit = function(name)
            if c.failInvite == name then error("Simulated invitation failure") end
            c.invites[#c.invites + 1] = name
            if c.inviteCreatesParty then c.homeGroup = true end
        end,
    }
    env.GetGuildInfo = function()
        if c.guildInfoUnavailable then return nil end
        return c.guild
    end
    env.GetNumGuildMembers = function() return #c.roster end
    env.GetGuildRosterInfo = function(index)
        local name = c.roster[index]
        local info = c.rosterInfo[name]
        if not info then return name end
        return name, nil, nil, info.level or 23, nil, info.area, nil, nil, info.online ~= false
    end
    env.UnitLevel = function() return c.level end
    env.GetRealZoneText = function() return c.zoneName end
    env.C_Map = {
        GetBestMapForUnit = function() return c.zoneID end,
        GetMapInfo = function(id)
            return c.mapInfo[id] or { mapID = id, name = c.zoneName, mapType = 3, parentMapID = 0 }
        end,
    }
    env.C_QuestLog = {
        GetNumQuestLogEntries = function() return #c.questLog end,
        GetInfo = function(index) if not c.questAPIUnavailable then return c.questLog[index] end end,
        IsComplete = function(id)
            for _, quest in ipairs(c.questLog) do
                if quest.questID == id then return quest.complete == true end
            end
            return false
        end,
    }
    env.hasanysecretvalues = function() return false end
    env.Enum = { SendAddonMessageResult = { Success = 0 } }
    env.DEFAULT_CHAT_FRAME = { AddMessage = function(_, text) c.messages[#c.messages + 1] = text end }
    if options.rosterAPIsMissing then
        env.GetNumGuildMembers, env.GetGuildRosterInfo = nil, nil
    else
        env.C_GuildInfo = { GuildRoster = function() end }
    end
    env.C_Timer = { NewTicker = function(_, callback) c.tick = callback return {} end }
    env.C_ChatInfo = {
        RegisterAddonMessagePrefix = function() return 0 end,
        IsAddonMessagePrefixRegistered = function() return true end,
        InChatMessagingLockdown = function() return c.locked end,
        SendAddonMessage = function(prefix, text, channel)
            c.sent[#c.sent + 1] = { prefix = prefix, text = text, channel = channel, clock = c.clock }
            return c.result
        end,
    }
    env.SlashCmdList = {}
    env.CreateFrame = function()
        return { RegisterEvent = function() end,
            SetScript = function(_, script, callback) if script == "OnEvent" then c.event = callback end end }
    end
    local core = assert(loadfile("GuildQueue/Core.lua"))
    setfenv(core, env)
    core("GuildQueue", c.ns)
    function c:fire(event, ...) self.event(nil, event, ...) end
    function c:advance(seconds)
        for _ = 1, seconds do
            self.now, self.clock = self.now + 1, self.clock + 1
            self.tick()
        end
    end
    function c:receive(sender, p, channel, prefix)
        self:fire("CHAT_MSG_ADDON", prefix or self.ns.PREFIX,
            self.ns.Protocol.Encode(p), channel or "GUILD", sender)
    end
    c:fire("ADDON_LOADED", "GuildQueue")
    c:fire("PLAYER_LOGIN")
    return c
end

local function receiveQuests(c, sender, quests, revision, zoneID, channel, prefix)
    local messages = c.ns.Questing.Encode(revision or 1, c.now, zoneID or 37, 24, quests)
    for _, message in ipairs(messages) do
        c:fire("CHAT_MSG_ADDON", prefix or c.ns.PREFIX, message, channel or "GUILD", sender)
    end
    return messages
end

local function suggestedGroup(c)
    c.roster = { "Self-TestRealm", "Friend-TestRealm", "D1-TestRealm", "D2-TestRealm", "D3-TestRealm" }
    c:fire("GUILD_ROSTER_UPDATE")
    c.ns.prefs.roles = 1
    c.ns.SetQueued(true)
    c:advance(1)
    for index = 2, 5 do
        c:receive(c.roster[index], packet(1, index == 2 and 2 or 4, nil, c.now, c.now))
    end
    equal(#c.ns.groups, 1)
    return c.ns.groups[1]
end

local function suggestedPartial(c, count)
    c.ns.prefs.roles = 2
    c.ns.SetQueued(true)
    c:advance(1)
    for index = 1, count - 1 do
        c:receive("PartialD" .. index .. "-TestRealm", packet(1, 4, nil, c.now, c.now))
    end
    equal(#c.ns.groups, 1)
    equal(#c.ns.groups[1].members, count)
    assert(not c.ns.groups[1].slots[1])
    return c.ns.groups[1]
end

local function formationClients(count)
    local names, roles, roster, rosterInfo = { "Alpha", "Bravo", "Charlie", "Delta", "Echo" }, { 1, 2, 4, 4, 4 }, {}, {}
    for index = 1, count do
        roster[index] = names[index] .. "-TestRealm"
        rosterInfo[roster[index]] = { area = "Elwynn Forest" }
    end
    local clients, packets = {}, {}
    for index = 1, count do
        local c = client({ characterName = names[index], roster = roster, rosterInfo = rosterInfo,
            saved = { roles = roles[index], dungeons = { [1] = true } } })
        c.ns.SetQueued(true)
        c:advance(1)
        clients[index] = c
        for _, message in ipairs(c.sent) do
            local p = c.ns.Protocol.Decode(message.text)
            if p.kind == "S" then packets[index] = p end
        end
    end
    for _, c in ipairs(clients) do
        for index, sender in ipairs(clients) do
            if c ~= sender then c:receive(sender.ns.playerName, packets[index]) end
        end
        equal(#c.ns.groups, 1)
        equal(#c.ns.groups[1].members, count)
    end
    return clients
end
local function relayFormations(clients)
    for _, c in ipairs(clients) do
        local sender, original = c, c.env.C_ChatInfo.SendAddonMessage
        c.env.C_ChatInfo.SendAddonMessage = function(prefix, text, channel)
            local result = original(prefix, text, channel)
            local p = sender.ns.Protocol.Decode(text)
            if result == 0 and p and (p.kind == "F" or p.kind == "U") then
                for _, peer in ipairs(clients) do
                    if peer ~= sender then peer:fire("CHAT_MSG_ADDON", prefix, text, channel, sender.ns.playerName) end
                end
            end
            return result
        end
    end
end
local function advanceFormations(clients, seconds)
    for _ = 1, seconds do for _, c in ipairs(clients) do c:advance(1) end end
end
local function lastFormation(c, kind)
    for index = #c.sent, 1, -1 do
        local p = c.ns.Protocol.Decode(c.sent[index].text)
        if p and p.kind == kind then return p end
    end
end

test("formation announcement disables peer actions before the first native invitation is submitted", function()
    local clients = formationClients(5)
    local a, b = clients[1], clients[2]
    relayFormations(clients)
    local native = a.env.C_PartyInfo.InviteUnit
    a.env.C_PartyInfo.InviteUnit = function(name)
        assert(b.ns.CreatePartyDisabledReason(b.ns.groups[1]):find("Alpha", 1, true))
        assert(b.ns.QueueInviteDisabledReason("Charlie-TestRealm", 4))
        assert(b.ns.QuestInviteDisabledReason("Charlie-TestRealm"))
        native(name)
    end
    assert(a.ns.CreateParty(a.ns.groups[1]))
    equal(#a.invites, 4)
    equal(#b.invites, 0)
    assert(not b.ns.CreateParty(b.ns.groups[1]))
    assert(not b.ns.InviteQueuedPlayer("Charlie-TestRealm", 4))
    assert(not b.ns.InviteQuestingPlayer("Charlie-TestRealm"))
    equal(#b.invites, 0)
    local status = b.ns.FormationStatus(b.ns.groups[1])
    equal(status.owner, a.ns.playerName) equal(status.remaining, 10) assert(not status.isOwner)
    equal(b.ns.FormationStatus("Charlie-TestRealm").key, status.key)
    equal(b.ns.state.records[a.ns.playerName].roles, 1)
end)
test("formation fingerprints ignore heartbeats and member iteration order and remain bounded", function()
    local clients = formationClients(5)
    local a, b = clients[1], clients[2]
    local key = a.ns.MatchupKey(a.ns.groups[1])
    equal(#key, 16)
    equal(key, b.ns.MatchupKey(b.ns.groups[1]))
    local group = a.ns.groups[1]
    group.members[1], group.members[5] = group.members[5], group.members[1]
    equal(a.ns.MatchupKey(group), key)
    group.members[1], group.members[5] = group.members[5], group.members[1]
    advanceFormations(clients, 21)
    equal(a.ns.MatchupKey(a.ns.groups[1]), key)
    equal(b.ns.MatchupKey(b.ns.groups[1]), key)
    a.ns.state.records["Charlie-TestRealm"].roles = 6
    equal(a.ns.MatchupKey(group), nil) -- Semantic preference changes invalidate the old fingerprint.
end)
test("formation expiry reenables peers without renewing on duplicate announcements or heartbeats", function()
    local clients = formationClients(2)
    local a, b = clients[1], clients[2]
    relayFormations(clients)
    assert(a.ns.CreateParty(a.ns.groups[1]))
    local start = lastFormation(a, "F")
    advanceFormations(clients, 6)
    assert(a.ns.CreateParty(a.ns.groups[1])) -- Owner may retry under native guards/cooldowns.
    equal(lastFormation(a, "F").claimID, start.claimID)
    advanceFormations(clients, 2)
    b:receive(a.ns.playerName, start)
    b:receive(a.ns.playerName, packet(start.claimID + 1, 1, { [1] = true }, a.ns.joinedAt, b.now))
    equal(b.ns.FormationStatus(b.ns.groups[1]).remaining, 2)
    advanceFormations(clients, 1)
    assert(b.ns.CreatePartyDisabledReason(b.ns.groups[1])) -- Still blocked at nine seconds.
    equal(b.ns.FormationStatus(b.ns.groups[1]).remaining, 1)
    advanceFormations(clients, 1)
    equal(b.ns.FormationStatus(b.ns.groups[1]), nil)
    assert(b.ns.CreatePartyDisabledReason(b.ns.groups[1]) == nil) -- Available at exactly ten seconds.
    equal(#b.invites, 0)
end)
test("new tokens from an already active inviter cannot renew the invitation window", function()
    local clients = formationClients(2)
    local a, b = clients[1], clients[2]
    local key = b.ns.MatchupKey(b.ns.groups[1])
    b:receive(a.ns.playerName, { kind = "F", sentAt = b.now, claimID = 100, matchupKey = key })
    advanceFormations(clients, 4)
    b:receive(a.ns.playerName, { kind = "F", sentAt = b.now, claimID = 101, matchupKey = key })
    equal(b.ns.FormationStatus(b.ns.groups[1]).remaining, 6)
    advanceFormations(clients, 6)
    equal(b.ns.FormationStatus(b.ns.groups[1]), nil)
    b:receive(a.ns.playerName, { kind = "F", sentAt = b.now - 6, claimID = 101, matchupKey = key })
    equal(b.ns.FormationStatus(b.ns.groups[1]), nil) -- Expiry alone never promotes a held start.
end)

test("formation protection applies to full partial and same-match individual invitations", function()
    for count = 2, 5 do
        local clients = formationClients(count)
        local a, b = clients[1], clients[2]
        relayFormations(clients)
        assert(a.ns.InviteQueuedPlayer(b.ns.playerName, 2))
        equal(#a.invites, 1)
        assert(lastFormation(a, "F"))
        assert(not b.ns.CreateParty(b.ns.groups[1]))
        equal(#b.invites, 0)
    end
end)
test("match announcements require a fresh participant exact fingerprint and the guild channel", function()
    local clients = formationClients(2)
    local a, b = clients[1], clients[2]
    local key = b.ns.MatchupKey(b.ns.groups[1])
    local p = { kind = "F", sentAt = b.now, claimID = 10, matchupKey = key }
    b:receive("Outsider-TestRealm", p)
    b:receive(a.ns.playerName, p, "WHISPER")
    b:receive(a.ns.playerName, p, "GUILD", "OtherAddon")
    b:receive(a.ns.playerName, { kind = "F", sentAt = b.now - b.ns.FORMATION_TIMEOUT, claimID = 10, matchupKey = key })
    b:receive(a.ns.playerName, { kind = "F", sentAt = b.now + 6, claimID = 10, matchupKey = key })
    b:receive(a.ns.playerName, { kind = "F", sentAt = b.now, claimID = 10, matchupKey = "0123456789abcdef" })
    equal(b.ns.FormationStatus(b.ns.groups[1]), nil)
    b:receive(a.ns.playerName, p)
    assert(b.ns.FormationStatus(b.ns.groups[1]))
    equal(#b.invites, 0)
end)
test("a claim only blocks its matchup while unrelated groups remain free to form", function()
    local clients = formationClients(5)
    local a = clients[1]
    a.ns.prefs.dungeons = { [1] = true, [2] = true }
    a.ns.PreferencesChanged()
    a:advance(1)
    a:receive("OtherHealer-TestRealm", packet(1, 2, { [2] = true }, a.now, a.now))
    a:receive("OtherDamage-TestRealm", packet(1, 4, { [2] = true }, a.now, a.now))
    equal(#a.ns.groups, 2)
    local own, other = a.ns.groups[1], a.ns.groups[2]
    equal(#own.members, 5) equal(#other.members, 2)
    assert(a.ns.QueueInviteDisabledReason("OtherDamage-TestRealm", 4) == nil)
    a:receive("OtherHealer-TestRealm", { kind = "F", sentAt = a.now, claimID = 200,
        matchupKey = a.ns.MatchupKey(other) })
    assert(a.ns.CreatePartyDisabledReason(own) == nil)
    equal(a.ns.FormationStatus(own), nil)
    assert(a.ns.QueueInviteDisabledReason("OtherDamage-TestRealm", 4):find("OtherHealer", 1, true))
    assert(not a.ns.InviteQueuedPlayer("OtherDamage-TestRealm", 4))
    equal(#a.invites, 0)
end)

test("only the authenticated owner token releases a claim and release-before-start prevents replay", function()
    local clients = formationClients(3)
    local a, b, c = clients[1], clients[2], clients[3]
    local key = b.ns.MatchupKey(b.ns.groups[1])
    local p = { kind = "F", sentAt = b.now, claimID = 100, matchupKey = key }
    b:receive(a.ns.playerName, p)
    b:receive(c.ns.playerName, { kind = "U", sentAt = b.now, claimID = 100, matchupKey = key })
    equal(b.ns.FormationStatus(b.ns.groups[1]).owner, a.ns.playerName)
    b:receive(a.ns.playerName, { kind = "U", sentAt = b.now, claimID = 99, matchupKey = key })
    assert(b.ns.FormationStatus(b.ns.groups[1]))
    b:receive(a.ns.playerName, { kind = "U", sentAt = b.now, claimID = 100, matchupKey = key })
    equal(b.ns.FormationStatus(b.ns.groups[1]), nil)
    b:receive(a.ns.playerName, p)
    equal(b.ns.FormationStatus(b.ns.groups[1]), nil)
    b:receive(a.ns.playerName, { kind = "U", sentAt = b.now, claimID = 101, matchupKey = key })
    b:receive(a.ns.playerName, { kind = "F", sentAt = b.now, claimID = 101, matchupKey = key })
    equal(b.ns.FormationStatus(b.ns.groups[1]), nil)
    equal(#b.invites, 0)
end)
test("failed announcements block native requests and retry only after another explicit click", function()
    for _, failure in ipairs({ "locked", "rejected" }) do
        local clients = formationClients(2)
        local a, b = clients[1], clients[2]
        relayFormations(clients)
        if failure == "locked" then a.locked = true else a.result = 11 end
        assert(not a.ns.CreateParty(a.ns.groups[1]))
        equal(#a.invites, 0)
        equal(b.ns.FormationStatus(b.ns.groups[1]), nil)
        advanceFormations(clients, 6)
        equal(#a.invites, 0)
        a.locked, a.result = false, 0
        advanceFormations(clients, 6)
        equal(#a.invites, 0)
        assert(a.ns.CreateParty(a.ns.groups[1]))
        equal(#a.invites, 1)
        assert(b.ns.FormationStatus(b.ns.groups[1]))
    end
end)
test("all native failures release a new claim but partial success keeps the invitation window", function()
    local clients = formationClients(3)
    local a, b = clients[1], clients[2]
    relayFormations(clients)
    a.env.C_PartyInfo.InviteUnit = function() error("Native request rejected") end
    assert(not a.ns.CreateParty(a.ns.groups[1]))
    assert(b.ns.FormationStatus(b.ns.groups[1]))
    advanceFormations(clients, 1)
    assert(lastFormation(a, "U"))
    equal(b.ns.FormationStatus(b.ns.groups[1]), nil)
    local partial = formationClients(3)
    local owner, peer = partial[1], partial[2]
    relayFormations(partial)
    owner.failInvite = peer.ns.playerName
    assert(not owner.ns.CreateParty(owner.ns.groups[1]))
    equal(#owner.invites, 1)
    advanceFormations(partial, 1)
    assert(peer.ns.FormationStatus(peer.ns.groups[1]))
    assert(not lastFormation(owner, "U"))
end)
test("a failed first individual invite cannot unlock a successful replacement when releases arrive out of order", function()
    for _, order in ipairs({ "startsFirst", "releaseFirst", "oldStartLast" }) do
        local clients = formationClients(3)
        local a, b = clients[1], clients[2]
        a.failInvite = b.ns.playerName
        assert(not a.ns.InviteQueuedPlayer(b.ns.playerName, 2))
        local first = lastFormation(a, "F")
        assert(a.ns.InviteQueuedPlayer("Charlie-TestRealm", 4))
        local second = lastFormation(a, "F")
        assert(second.claimID > first.claimID)
        equal(second.replacesID, first.claimID)
        a:advance(1)
        local release = lastFormation(a, "U")
        equal(release.claimID, first.claimID)
        local packets = order == "startsFirst" and { first, second, release }
            or order == "releaseFirst" and { first, release, second } or { release, second, first }
        for _, p in ipairs(packets) do b:receive(a.ns.playerName, p) end
        assert(b.ns.FormationStatus(b.ns.groups[1]), order)
        assert(b.ns.CreatePartyDisabledReason(b.ns.groups[1]), order)
        b:receive(a.ns.playerName, release)
        assert(b.ns.FormationStatus(b.ns.groups[1])) -- An old release cannot clear the replacement.
        b:receive(a.ns.playerName, { kind = "U", sentAt = b.now, claimID = second.claimID,
            matchupKey = second.matchupKey })
        equal(b.ns.FormationStatus(b.ns.groups[1]), nil)
        equal(#a.invites, 1) equal(#b.invites, 0)
    end
end)

test("a successful retry stays protected even when the first release is lost near its expiry", function()
    local clients = formationClients(3)
    local a, b = clients[1], clients[2]
    a.failInvite = b.ns.playerName
    assert(not a.ns.InviteQueuedPlayer(b.ns.playerName, 2))
    local first = lastFormation(a, "F")
    b:receive(a.ns.playerName, first)
    a.locked = true
    advanceFormations(clients, 8)
    a.locked = false
    assert(a.ns.InviteQueuedPlayer("Charlie-TestRealm", 4))
    local second = lastFormation(a, "F")
    equal(second.replacesID, first.claimID)
    b:receive(a.ns.playerName, second) -- Do not deliver the old release at all.
    equal(b.ns.FormationStatus(b.ns.groups[1]).remaining, 10)
    b:advance(3)
    equal(b.ns.FormationStatus(b.ns.groups[1]).remaining, 7)
    b:receive(a.ns.playerName, { kind = "U", sentAt = b.now, claimID = first.claimID, matchupKey = first.matchupKey })
    assert(b.ns.FormationStatus(b.ns.groups[1]))
    equal(#a.invites, 1) equal(#b.invites, 0)
end)
test("nonoverlapping fresh windows tolerate peer clock skew without treating a new click as renewal", function()
    local clients = formationClients(2)
    local a, b = clients[1], clients[2]
    local key, started = b.ns.MatchupKey(b.ns.groups[1]), b.now
    b:receive(a.ns.playerName, { kind = "F", sentAt = started, claimID = 100, matchupKey = key })
    a:advance(10)
    b:advance(5)
    b:receive(a.ns.playerName, { kind = "F", sentAt = a.now, claimID = 101, matchupKey = key })
    equal(b.ns.FormationStatus(b.ns.groups[1]).remaining, 15) -- Five-second accepted clock tolerance.
    b:advance(6)
    assert(b.ns.FormationStatus(b.ns.groups[1]))
    equal(#a.invites, 0) equal(#b.invites, 0)
end)
test("an explicitly released failed replacement never revives when its start arrives late", function()
    local clients = formationClients(3)
    local a, b = clients[1], clients[2]
    a.env.C_PartyInfo.InviteUnit = function() return false end
    assert(not a.ns.InviteQueuedPlayer(b.ns.playerName, 2))
    local first = lastFormation(a, "F")
    assert(not a.ns.InviteQueuedPlayer("Charlie-TestRealm", 4))
    local second = lastFormation(a, "F")
    a:advance(2)
    local releases = {}
    for _, message in ipairs(a.sent) do
        local p = a.ns.Protocol.Decode(message.text)
        if p and p.kind == "U" then releases[p.claimID] = p end
    end
    for _, p in ipairs({ first, releases[second.claimID], second, releases[first.claimID] }) do
        assert(p)
        b:receive(a.ns.playerName, p)
    end
    equal(b.ns.FormationStatus(b.ns.groups[1]), nil)
    equal(#a.invites, 0) equal(#b.invites, 0)
end)

test("an explicit failed retry cannot release an existing claim with outstanding earlier requests", function()
    local clients = formationClients(2)
    local a, b = clients[1], clients[2]
    relayFormations(clients)
    assert(a.ns.CreateParty(a.ns.groups[1]))
    advanceFormations(clients, 6)
    a.env.C_PartyInfo.InviteUnit = function() return false end
    assert(not a.ns.CreateParty(a.ns.groups[1]))
    assert(b.ns.FormationStatus(b.ns.groups[1]))
    assert(not lastFormation(a, "U"))
end)
test("queue withdrawal guild changes and semantic matchup changes remove obsolete invitation locks", function()
    local clients = formationClients(2)
    local a, b = clients[1], clients[2]
    relayFormations(clients)
    assert(a.ns.CreateParty(a.ns.groups[1]))
    a.ns.SetQueued(false)
    advanceFormations(clients, 1)
    assert(lastFormation(a, "U"))
    equal(b.ns.FormationStatus(b.ns.groups[1]), nil)
    local changed = formationClients(2)
    local owner, peer = changed[1], changed[2]
    relayFormations(changed)
    assert(owner.ns.CreateParty(owner.ns.groups[1]))
    local old = lastFormation(owner, "F")
    peer:receive(owner.ns.playerName, packet(old.claimID + 1, 4, { [2] = true }, owner.ns.joinedAt, peer.now))
    equal(peer.ns.FormationStatus(peer.ns.playerName), nil)
    peer:receive(owner.ns.playerName, old)
    equal(peer.ns.FormationStatus(peer.ns.playerName), nil)
    peer.guild = "Another Guild"
    peer:fire("PLAYER_GUILD_UPDATE", "player")
    equal(peer.ns.FormationStatus(peer.ns.playerName), nil)
    equal(#peer.invites, 0)
end)
test("simultaneous clicks converge deterministically without pretending to undo native requests", function()
    local clients = formationClients(2)
    local a, b = clients[1], clients[2]
    assert(a.ns.CreateParty(a.ns.groups[1]))
    assert(b.ns.CreateParty(b.ns.groups[1])) -- Neither announcement has arrived yet.
    local pa, pb = lastFormation(a, "F"), lastFormation(b, "F")
    a:receive(b.ns.playerName, pb)
    b:receive(a.ns.playerName, pa)
    equal(a.ns.FormationStatus(a.ns.groups[1]).owner, a.ns.playerName)
    equal(b.ns.FormationStatus(b.ns.groups[1]).owner, a.ns.playerName)
    equal(#a.invites, 1) equal(#b.invites, 1)
    assert(not b.ns.CreateParty(b.ns.groups[1]))
    advanceFormations(clients, 11)
    equal(#a.invites, 1) equal(#b.invites, 1)
end)

test("partial Create party requests only the other one to three matched players", function()
    for size = 2, 4 do
        local c = client({ roster = {} })
        local group = suggestedPartial(c, size)
        equal(#c.invites, 0)
        c.inviteCreatesParty = true -- Still submit the entire clicked batch.
        assert(c.ns.CreateParty(group))
        equal(#c.invites, size - 1)
        local seen = {}
        for _, name in ipairs(c.invites) do
            assert(name ~= c.ns.playerName and not seen[name])
            seen[name] = true
        end
        assert(c.ns.CreatePartyDisabledReason(group)) -- The simulated new party has no resolved roster yet.
        c:advance(20)
        equal(#c.invites, size - 1)
    end
end)
test("partial invitations reject stale or expired members before sending any request", function()
    local c = client()
    local old = suggestedPartial(c, 4)
    local last = old.members[#old.members]
    c.ns.state.records[last.name].sentAt = c.now - c.ns.TIMEOUT
    assert(not c.ns.CreateParty(old))
    equal(#c.invites, 0)
    c.ns.state.records[last.name].sentAt = c.now
    c:receive(last.name, { kind = "X", revision = 2, sentAt = c.now })
    assert(not c.ns.CreateParty(old))
    equal(#c.invites, 0)
end)
test("partial invitation failures and repeat clicks never cause automatic retries", function()
    local c = client()
    local group = suggestedPartial(c, 4)
    c.failInvite = "PartialD2-TestRealm"
    assert(not c.ns.CreateParty(group))
    equal(#c.invites, 2)
    assert(not c.ns.CreateParty(group))
    c:advance(20)
    equal(#c.invites, 2)
end)

test("queued preference changes invalidate old suggestions and retry only latest selections after lockdown", function()
    local c = client()
    local group = suggestedGroup(c)
    local age, sent = c.ns.joinedAt, #c.sent
    c.locked = true
    c.ns.prefs.roles, c.ns.prefs.dungeons = 4, { [2] = true }
    c.ns.PreferencesChanged()
    assert(c.ns.queued and c.ns.QueueUpdatePending())
    equal(c.ns.joinedAt, age)
    equal(c.ns.state.records[c.ns.playerName], nil)
    assert(not c.ns.CreateParty(group))
    c:advance(6)
    c.ns.prefs.roles, c.ns.prefs.dungeons = 2, { [3] = true }
    c.ns.PreferencesChanged()
    c.ns.prefs.roles, c.ns.prefs.dungeons = 4, { [2] = true }
    c.ns.PreferencesChanged()
    equal(#c.sent, sent)
    c.locked = false
    c:advance(6)
    local record = c.ns.state.records[c.ns.playerName]
    assert(record and record.roles == 4 and record.dungeons[2] and not record.dungeons[1])
    equal(record.joinedAt, age)
    assert(not c.ns.QueueUpdatePending())
    local updates = 0
    for index = sent + 1, #c.sent do
        local p = c.ns.Protocol.Decode(c.sent[index].text)
        if p.kind == "S" then
            updates = updates + 1
            assert(p.roles == 4 and p.dungeons[2] and not p.dungeons[3])
        end
    end
    equal(updates, 1)
    equal(#c.invites, 0)
end)
test("leaving overrides blocked queued preference changes and never replays a pending join", function()
    local c = client()
    suggestedGroup(c)
    c.locked = true
    c.ns.prefs.dungeons = { [2] = true }
    c.ns.PreferencesChanged()
    c.ns.SetQueued(false)
    local sent = #c.sent
    c:advance(6)
    c.locked = false
    c:advance(6)
    assert(not c.ns.queued and not c.ns.QueueUpdatePending())
    equal(c.ns.state.records[c.ns.playerName], nil)
    local withdrawals = 0
    for index = sent + 1, #c.sent do
        local p = c.ns.Protocol.Decode(c.sent[index].text)
        assert(p.kind ~= "S")
        if p.kind == "X" then withdrawals = withdrawals + 1 end
    end
    equal(withdrawals, 1)
end)
test("send failures keep changed selections pending until a successful newest-state broadcast", function()
    local c = client()
    local old = suggestedGroup(c)
    c.result = 11
    c.ns.prefs.roles, c.ns.prefs.dungeons = 2, { [2] = true }
    c.ns.PreferencesChanged()
    c:advance(6)
    assert(c.ns.queued and c.ns.QueueUpdatePending())
    assert(not c.ns.CreateParty(old))
    c.ns.prefs.dungeons = { [3] = true }
    c.ns.PreferencesChanged()
    local sent = #c.sent
    c.result = 0
    c:advance(5)
    assert(not c.ns.QueueUpdatePending())
    for index = sent + 1, #c.sent do
        local p = c.ns.Protocol.Decode(c.sent[index].text)
        if p.kind == "S" then assert(p.roles == 2 and p.dungeons[3] and not p.dungeons[2]) end
    end
    equal(#c.invites, 0)
end)
test("group clicks revalidate unsignalled local selection and assigned-role or dungeon changes", function()
    for _, change in ipairs({ "ownRoles", "ownDungeons", "peerRoles", "peerDungeons" }) do
        local c = client()
        local group = suggestedGroup(c)
        if change == "ownRoles" then c.ns.prefs.roles = 4
        elseif change == "ownDungeons" then c.ns.prefs.dungeons = { [2] = true }
        elseif change == "peerRoles" then c.ns.state.records["Friend-TestRealm"].roles = 4
        else c.ns.state.records["Friend-TestRealm"].dungeons = { [2] = true } end
        assert(c.ns.CreatePartyDisabledReason(group), change)
        assert(not c.ns.CreateParty(group), change)
        equal(#c.invites, 0)
    end
end)
test("party Role List intersects every member's dungeons and marks existing members", function()
    local c = client()
    c.ns.prefs.roles, c.ns.prefs.dungeons = 4, { [1] = true, [2] = true }
    c:receive("Tank-TestRealm", packet(1, 1, { [1] = true }, c.now, c.now))
    c:receive("WrongHealer-TestRealm", packet(1, 2, { [2] = true }, c.now, c.now))
    c:receive("GoodHealer-TestRealm", packet(1, 2, { [1] = true, [2] = true }, c.now, c.now))
    c.homeGroup, c.partyMembers = true, { "Tank-TestRealm" }
    local lists, reason = c.ns.GetRoleLists()
    assert(reason == nil)
    equal(#lists[1], 1)
    assert(lists[1][1].inParty)
    equal(#lists[2], 1)
    equal(lists[2][1].player.name, "GoodHealer-TestRealm")
    assert(lists[2][1].dungeons[1] and not lists[2][1].dungeons[2])
    local disabled, _, inParty = c.ns.QueueInviteDisabledReason("Tank-TestRealm", 1)
    assert(disabled and inParty)
    assert(not c.ns.InviteQueuedPlayer("Tank-TestRealm", 1))
    assert(not c.ns.InviteQueuedPlayer("WrongHealer-TestRealm", 2))
    assert(c.ns.InviteQueuedPlayer("GoodHealer-TestRealm", 2))
    equal(#c.invites, 1)
end)
test("party role columns and actual clicks constrain a flexible recruit to the requested remaining role", function()
    local c = client()
    c.ns.prefs.roles = 2
    c:receive("Tank-TestRealm", packet(1, 1, nil, c.now, c.now))
    c:receive("Flexible-TestRealm", packet(1, 7, nil, c.now, c.now))
    c.homeGroup, c.partyMembers = true, { "Tank-TestRealm" }
    local lists = c.ns.GetRoleLists()
    equal(#lists[1], 1) -- Existing tank stays visible; recruit cannot fill a second tank slot.
    equal(#lists[2], 0)
    equal(#lists[4], 1)
    assert(not c.ns.InviteQueuedPlayer("Flexible-TestRealm", 1))
    assert(not c.ns.InviteQueuedPlayer("Flexible-TestRealm", 2))
    assert(not c.ns.InviteQueuedPlayer("Flexible-TestRealm", 3))
    c.ns.state.records["Flexible-TestRealm"].roles = 1 -- Changes between rendering and clicking.
    assert(not c.ns.InviteQueuedPlayer("Flexible-TestRealm", 4))
    c.ns.state.records["Flexible-TestRealm"].roles = 7
    assert(c.ns.InviteQueuedPlayer("Flexible-TestRealm", 4))
    equal(#c.invites, 1)
end)
test("unverifiable expired or incompatible party preferences block recruitment instead of guessing", function()
    for _, condition in ipairs({ "missing", "expired", "disjoint", "unknownRoster" }) do
        local c = client()
        c:receive("Recruit-TestRealm", packet(1, 2, nil, c.now, c.now))
        c.homeGroup, c.partyMembers = true, { "Tank-TestRealm" }
        if condition ~= "missing" then
            c:receive("Tank-TestRealm", packet(1, 1, condition == "disjoint" and { [2] = true } or nil, c.now, c.now))
        end
        if condition == "expired" then c.ns.state.records["Tank-TestRealm"].sentAt = c.now - c.ns.TIMEOUT end
        if condition == "unknownRoster" then c.partyMembers = { {} } end
        local lists, reason = c.ns.GetRoleLists()
        assert(reason, condition)
        for _, role in ipairs({ 1, 2, 4 }) do equal(#lists[role], 0) end
        assert(not c.ns.InviteQueuedPlayer("Recruit-TestRealm", 2), condition)
        equal(#c.invites, 0)
    end
end)
test("role-column clicks queue one guild-only informational notice and never assign or auto-invite roles", function()
    local c = client()
    c:receive("Friend-TestRealm", packet(1, 7, nil, c.now, c.now))
    assert(c.ns.InviteQueuedPlayer("Friend-TestRealm", 1))
    c:advance(3)
    local notices = 0
    for _, message in ipairs(c.sent) do
        local p = c.ns.Protocol.Decode(message.text)
        if p.kind == "R" then
            notices = notices + 1
            equal(p.role, 1) equal(p.target, "Friend-TestRealm") equal(message.channel, "GUILD")
        end
    end
    equal(notices, 1)
    equal(#c.invites, 1)
    equal(c.ns.prefs.roles, 4)
    c:advance(6)
    equal(#c.invites, 1)
end)
test("role notices are recipient-only fresh offered-role messages with duplicate and channel protection", function()
    local c = client()
    c.ns.SetQueued(true)
    local before = #c.messages
    local p = { kind = "R", sentAt = c.now, role = 4, target = c.ns.playerName }
    c:receive("Leader-TestRealm", p)
    equal(#c.messages, before + 1)
    assert(c.messages[#c.messages]:find("requests you as Damage", 1, true))
    c:receive("Leader-TestRealm", p)
    c:receive("Leader-TestRealm", p, "WHISPER")
    c:receive("Leader-TestRealm", p, "GUILD", "OtherAddon")
    c:receive("Other-TestRealm", { kind = "R", sentAt = c.now, role = 4, target = "SomebodyElse-TestRealm" })
    c:receive("Other-TestRealm", { kind = "R", sentAt = c.now, role = 1, target = c.ns.playerName })
    c:receive("Other-TestRealm", { kind = "R", sentAt = c.now - 30, role = 4, target = c.ns.playerName })
    c:receive("Other-TestRealm", { kind = "R", sentAt = c.now + 6, role = 4, target = c.ns.playerName })
    equal(#c.messages, before + 1)
    equal(c.ns.state.records["Leader-TestRealm"], nil)
    equal(c.ns.prefs.roles, 4)
    equal(#c.invites, 0)
end)
test("failed expired and old-guild role notices are never delivered or retried as invitations", function()
    for _, condition in ipairs({ "failed", "expired", "guildChanged" }) do
        local c = client()
        c:receive("Friend-TestRealm", packet(1, 4, nil, c.now, c.now))
        if condition == "failed" then c.failInvite = "Friend-TestRealm" end
        local result = c.ns.InviteQueuedPlayer("Friend-TestRealm", 4)
        equal(result, condition ~= "failed")
        if condition == "expired" then c.locked = true c:advance(31) c.locked = false end
        if condition == "guildChanged" then c.guild = "Another Guild" c:fire("PLAYER_GUILD_UPDATE", "player") end
        c:advance(6)
        for _, message in ipairs(c.sent) do assert(c.ns.Protocol.Decode(message.text).kind ~= "R") end
        equal(#c.invites, condition == "failed" and 0 or 1)
    end
end)
test("Quest invitations skip existing party or raid members without requiring dungeon queue data", function()
    local c = client({ roster = { "Self-TestRealm", "Friend-TestRealm", "Other-TestRealm" },
        rosterInfo = { ["Friend-TestRealm"] = { area = "Elwynn Forest" }, ["Other-TestRealm"] = { area = "Elwynn Forest" } } })
    c.homeGroup, c.partyMembers = true, { "Friend-TestRealm" }
    assert(not c.ns.InviteQuestingPlayer("Friend-TestRealm"))
    c.raid, c.raidMembers = true, { "Self-TestRealm", "Friend-TestRealm" }
    assert(not c.ns.InviteQuestingPlayer("Friend-TestRealm"))
    assert(c.ns.InviteQuestingPlayer("Other-TestRealm"))
    equal(#c.invites, 1)
    equal(c.ns.state.records["Other-TestRealm"], nil)
    c.env.GetNumGroupMembers = nil
    assert(not c.ns.InviteQuestingPlayer("Other-TestRealm"))
end)

test("role lists use shared dungeons and longest queue time without assigning players to groups", function()
    local c = client({ roster = {} })
    for _, entry in ipairs({ { "Bflex", 7, 30, 1 }, { "OldTank", 1, 200, 1 },
        { "NewTank", 1, 10, 1 }, { "Aflex", 3, 30, 1 }, { "Hidden", 4, 300, 2 } }) do
        c:receive(entry[1] .. "-TestRealm", packet(1, entry[2], { [entry[4]] = true }, c.now - entry[3], c.now))
    end
    local groups = c.ns.groups
    c.ns.Match = function() error("Role list must not perform matchmaking") end
    local lists = c.ns.GetRoleLists()
    equal(#lists[1], 4)
    equal(#lists[2], 2)
    equal(#lists[4], 1)
    for index, name in ipairs({ "OldTank", "Aflex", "Bflex", "NewTank" }) do
        equal(lists[1][index].player.name, name .. "-TestRealm")
    end
    equal(lists[2][1].player.name, "Aflex-TestRealm")
    equal(lists[4][1].player.name, "Bflex-TestRealm")
    assert(lists[4][1].dungeons[1])
    equal(c.ns.groups, groups)
    assert(not c.ns.queued)
    equal(#c.invites, 0)
    c.ns.state.records["OldTank-TestRealm"].sentAt = c.now - c.ns.TIMEOUT
    equal(#c.ns.GetRoleLists()[1], 3)
    c.ns.prefs.dungeons = {}
    for _, role in ipairs({ 1, 2, 4 }) do equal(#c.ns.GetRoleLists()[role], 0) end
end)
test("queued-player invites work across zones without joining queue or having a full match", function()
    local c = client({ roster = {} })
    c:receive("Remote-TestRealm", packet(1, 1, nil, c.now, c.now))
    equal(#c.ns.groups, 0)
    c.homeGroup, c.partyMembers = true, { "Friend-TestRealm" }
    c:receive("Friend-TestRealm", packet(1, 2, nil, c.now, c.now))
    assert(c.ns.InviteQueuedPlayer("Remote-TestRealm"))
    equal(#c.invites, 1)
    equal(c.invites[1], "Remote-TestRealm")
    assert(not c.ns.queued and not c.ns.prefs.shareQuests)
    assert(not c.ns.InviteQueuedPlayer("Remote-TestRealm"))
    c:advance(6)
    equal(#c.invites, 1)
end)
test("queued-player invite guards block self unknown targets combat capacity and permission", function()
    local c = client()
    c:receive("Friend-TestRealm", packet(1, 4, nil, c.now, c.now))
    assert(not c.ns.InviteQueuedPlayer(c.ns.playerName))
    assert(not c.ns.InviteQueuedPlayer("Unknown-TestRealm"))
    for _, condition in ipairs({ { "combat", true }, { "partyFull", true },
        { "canInvite", false }, { "instanceGroup", true } }) do
        c[condition[1]] = condition[2]
        assert(c.ns.QueueInviteDisabledReason("Friend-TestRealm"))
        assert(not c.ns.InviteQueuedPlayer("Friend-TestRealm"))
        c[condition[1]] = nil
    end
    c.env.C_PartyInfo = nil
    assert(not c.ns.InviteQueuedPlayer("Friend-TestRealm"))
    equal(#c.invites, 0)
end)
test("queued-player invites recheck freshness selected dungeons withdrawal and guild at click time", function()
    local c = client()
    c:receive("Friend-TestRealm", packet(1, 4, nil, c.now, c.now))
    assert(c.ns.QueueInviteDisabledReason("Friend-TestRealm") == nil)
    local record = c.ns.state.records["Friend-TestRealm"]
    record.sentAt = c.now - c.ns.TIMEOUT
    assert(not c.ns.InviteQueuedPlayer(record.name))
    record.sentAt = c.now
    c.ns.prefs.dungeons = { [2] = true }
    assert(not c.ns.InviteQueuedPlayer(record.name))
    c.ns.prefs.dungeons = { [1] = true }
    c:receive(record.name, { kind = "X", revision = 2, sentAt = c.now })
    assert(not c.ns.InviteQueuedPlayer(record.name))
    c:receive(record.name, packet(3, 4, nil, c.now, c.now))
    c.guild = "Another Guild"
    assert(not c.ns.InviteQueuedPlayer(record.name))
    equal(#c.invites, 0)
end)
test("manual member cooldown is shared across role copies and the Quests view", function()
    local c = client({ rosterInfo = { ["Friend-TestRealm"] = { area = "Elwynn Forest" } } })
    c:advance(1)
    c:receive("Friend-TestRealm", packet(1, 7, nil, c.now, c.now))
    assert(c.ns.InviteQueuedPlayer("Friend-TestRealm"))
    assert(not c.ns.InviteQuestingPlayer("Friend-TestRealm"))
    c:advance(6)
    assert(c.ns.InviteQuestingPlayer("Friend-TestRealm"))
    assert(not c.ns.InviteQueuedPlayer("Friend-TestRealm"))
    equal(#c.invites, 2)
end)
test("failed queued-player invitations are contained and never retried automatically", function()
    local c, attempts = client(), 0
    c:receive("Friend-TestRealm", packet(1, 4, nil, c.now, c.now))
    c.env.C_PartyInfo.InviteUnit = function() attempts = attempts + 1 error("Simulated native failure") end
    assert(not c.ns.InviteQueuedPlayer("Friend-TestRealm"))
    assert(not c.ns.InviteQueuedPlayer("Friend-TestRealm"))
    c:advance(20)
    equal(attempts, 1)
end)

test("an empty guild roster does not block queuing or guild-only synchronization", function()
    local c = client({ roster = {} })
    assert(c.ns.IsReady(), "joining must not require a cached roster")
    c.ns.SetQueued(true)
    c:advance(1)
    assert(c.ns.state.records[c.ns.playerName])
    c:receive("Friend-TestRealm", packet(1, 2, nil, c.now, c.now))
    assert(c.ns.state.records["Friend-TestRealm"])
end)
test("legacy roster APIs are not required to join and match a full guild group", function()
    local c = client({ roster = {}, rosterAPIsMissing = true })
    suggestedGroup(c)
    equal(#c.ns.groups, 1)
    equal(#c.ns.individuals, 0)
    assert(c.ns.CreatePartyDisabledReason(c.ns.groups[1]) == nil)
end)

test("own guild-message echoes never create a second queue entry", function()
    local c = client()
    c.ns.SetQueued(true)
    c:advance(1)
    for index, sender in ipairs({ "Self", "Self-TestRealm", "Self-Test Realm", "Self Test Realm" }) do
        c:receive(sender, packet(100 + index, 4, nil, c.now, c.now))
        equal(#c.ns.state:Sorted(), 1)
    end
    c.ns.SetQueued(false)
    c:receive("Self Test Realm", packet(999, 4, nil, c.now, c.now))
    equal(#c.ns.state:Sorted(), 0)
end)
test("a peer's space-qualified and hyphen-qualified names share one identity", function()
    local c = client()
    c:receive("Friend Test Realm", packet(1, 4, nil, c.now, c.now))
    c:receive("Friend-TestRealm", packet(2, 2, nil, c.now, c.now))
    equal(#c.ns.state:Sorted(), 1)
    equal(c.ns.state.records["Friend-TestRealm"].roles, 2)
end)
test("already-qualified local names do not get the realm appended twice", function()
    for _, name in ipairs({ "Self-Test Realm", "Self Test Realm" }) do
        local c = client({ characterName = name })
        equal(c.ns.playerName, "Self-TestRealm")
        c.ns.SetQueued(true)
        c:advance(1)
        c:receive("Self-TestRealm", packet(9, 4, nil, c.now, c.now))
        equal(#c.ns.state:Sorted(), 1)
    end
end)
test("a same-named character from another realm remains a distinct guildmate", function()
    local c = client()
    c.ns.SetQueued(true)
    c:advance(1)
    c:receive("Self-OtherRealm", packet(1, 4, nil, c.now, c.now))
    equal(#c.ns.state:Sorted(), 2)
    assert(c.ns.state.records["Self-OtherRealm"])
end)

test("matching, messages, and heartbeats never send party invitations", function()
    local c = client()
    suggestedGroup(c)
    c:advance(20)
    c:receive("Friend-TestRealm", { kind = "H" })
    c:advance(6)
    equal(#c.invites, 0)
end)
test("Create party requests exactly four invitations and never invites yourself", function()
    local c = client()
    local group = suggestedGroup(c)
    assert(c.ns.CreatePartyDisabledReason(group) == nil)
    -- Even if the first request creates a party immediately, finish the four requests.
    c.inviteCreatesParty = true
    assert(c.ns.CreateParty(group))
    equal(#c.invites, 4)
    local seen = {}
    for _, name in ipairs(c.invites) do
        assert(name ~= c.ns.playerName and not seen[name])
        seen[name] = true
    end
    assert(c.ns.CreatePartyDisabledReason(group)) -- An unresolved roster cannot be extended.
    assert(not c.ns.CreateParty(group))
    equal(#c.invites, 4)
end)
test("unrelated home parties raids and instance groups still block the suggested-group action", function()
    local c = client()
    local group = suggestedGroup(c)
    c.homeGroup, c.partyMembers = true, { "Outsider-TestRealm" }
    assert(c.ns.CreatePartyDisabledReason(group):find("outside", 1, true))
    assert(not c.ns.CreateParty(group))
    c.partyMembers, c.raid = { "Friend-TestRealm" }, true
    assert(c.ns.CreatePartyDisabledReason(group):find("raid", 1, true))
    assert(not c.ns.CreateParty(group))
    c.homeGroup, c.raid, c.instanceGroup = false, false, true
    assert(c.ns.CreatePartyDisabledReason(group):find("instance group", 1, true))
    assert(not c.ns.CreateParty(group))
    equal(#c.invites, 0)
end)
test("Create party rechecks membership at click time, not just during rendering", function()
    local c = client()
    local group = suggestedGroup(c)
    assert(c.ns.CreatePartyDisabledReason(group) == nil)
    c.homeGroup = true
    assert(not c.ns.CreateParty(group))
    equal(#c.invites, 0)
end)
test("Invite Others skips all existing suggested party members and requests only the missing players", function()
    for joined = 1, 3 do
        local c = client()
        local group = suggestedGroup(c)
        c.homeGroup, c.partyMembers = true, {}
        local peers = { "Friend-TestRealm", "D1-TestRealm", "D2-TestRealm" }
        for i = 1, joined do c.partyMembers[i] = peers[i] end
        local reason, targets, existingParty = c.ns.CreatePartyDisabledReason(group)
        assert(reason == nil and existingParty)
        equal(#targets, 4 - joined)
        equal(#c.invites, 0) -- Eligibility and labels never invite.
        assert(c.ns.CreateParty(group))
        equal(#c.invites, 4 - joined)
        for _, name in ipairs(c.invites) do
            assert(name ~= c.ns.playerName)
            for _, present in ipairs(c.partyMembers) do assert(name ~= present) end
        end
        assert(not c.ns.CreateParty(group))
        c:advance(6)
        equal(#c.invites, 4 - joined) -- No automatic retry or filling.
    end
end)
test("Invite Others extends partial suggestions but disables when every suggested member has joined", function()
    local c = client()
    local group = suggestedPartial(c, 2)
    c.homeGroup, c.partyMembers = true, { "PartialD1-TestRealm" }
    local reason, _, existingParty = c.ns.CreatePartyDisabledReason(group)
    assert(reason:find("already in your party", 1, true) and existingParty)
    assert(not c.ns.CreateParty(group))
    c:receive("NewDamage-TestRealm", packet(1, 4, nil, c.now, c.now))
    local current = c.ns.groups[1]
    equal(#current.members, 3)
    assert(c.ns.CreateParty(current))
    equal(#c.invites, 1)
    equal(c.invites[1], "NewDamage-TestRealm")
    local full = client()
    local fullGroup = suggestedGroup(full)
    full.homeGroup, full.partyFull = true, true
    full.partyMembers = { "Friend-TestRealm", "D1-TestRealm", "D2-TestRealm", "D3-TestRealm" }
    assert(full.ns.CreatePartyDisabledReason(fullGroup):find("already in your party", 1, true))
    assert(not full.ns.CreateParty(fullGroup))
    equal(#full.invites, 0)
end)
test("Invite Others requires combat safety native invitation permission and available capacity", function()
    local c = client()
    local group = suggestedGroup(c)
    c.homeGroup, c.partyMembers = true, { "Friend-TestRealm" }
    for _, condition in ipairs({ { "combat", true }, { "partyFull", true }, { "canInvite", false } }) do
        c[condition[1]] = condition[2]
        local reason, _, existingParty = c.ns.CreatePartyDisabledReason(group)
        assert(reason and existingParty)
        assert(not c.ns.CreateParty(group))
        c[condition[1]] = nil
    end
    c.env.C_PartyInfo.CanInvite = function() error("Unavailable") end
    assert(not c.ns.CreateParty(group))
    c.env.C_PartyInfo.CanInvite = nil
    assert(not c.ns.CreateParty(group))
    equal(#c.invites, 0)
end)
test("Invite Others fails closed on missing duplicate restricted or invalid party identities", function()
    local c = client()
    local group = suggestedGroup(c)
    c.homeGroup = true
    for _, members in ipairs({ {}, { {} }, { "Friend-TestRealm", "Friend-TestRealm" },
        { { name = "Friend", realm = 12 } }, { "Self-TestRealm" } }) do
        c.partyMembers = members
        assert(c.ns.CreatePartyDisabledReason(group))
        assert(not c.ns.CreateParty(group))
    end
    c.partyMembers = { "Restricted-TestRealm" }
    c.env.hasanysecretvalues = function(name) return name == "Restricted" end
    assert(c.ns.CreatePartyDisabledReason(group):find("unavailable", 1, true))
    assert(not c.ns.CreateParty(group))
    c.env.hasanysecretvalues = function() return false end
    c.partyMembers, c.partyCount = { "Friend-TestRealm" }, 5
    assert(not c.ns.CreateParty(group))
    c.partyCount = nil
    c.env.GetNumSubgroupMembers = nil
    assert(not c.ns.CreateParty(group))
    equal(#c.invites, 0)
end)
test("Invite Others normalizes party identities without merging characters on different realms", function()
    local c = client()
    local group = suggestedGroup(c)
    c.homeGroup = true
    for _, identity in ipairs({ "Friend", { name = "friend", realm = "Test Realm" },
        { name = "Friend-TestRealm", realm = "IgnoredRealm" } }) do
        c.partyMembers = { identity }
        local reason, targets = c.ns.CreatePartyDisabledReason(group)
        assert(reason == nil)
        equal(#targets, 3)
        for _, name in ipairs(targets) do assert(name ~= "Friend-TestRealm") end
    end
    c.partyMembers = { "Friend-AnotherRealm" }
    assert(c.ns.CreatePartyDisabledReason(group):find("outside", 1, true))
    assert(not c.ns.CreateParty(group))
    equal(#c.invites, 0)
end)
test("Invite Others rechecks the party roster and current suggestion at the actual click", function()
    local c = client()
    local group = suggestedGroup(c)
    c.homeGroup, c.partyMembers = true, { "Friend-TestRealm" }
    assert(c.ns.CreatePartyDisabledReason(group) == nil)
    c.partyMembers[2] = "Outsider-TestRealm"
    assert(not c.ns.CreateParty(group))
    c.partyMembers = { "Friend-TestRealm" }
    c:receive("Friend-TestRealm", { kind = "X", revision = 2, sentAt = c.now })
    assert(not c.ns.CreateParty(group)) -- Replaced suggestion.
    assert(c.ns.CreatePartyDisabledReason(c.ns.groups[1]):find("outside", 1, true))
    assert(not c.ns.CreateParty(c.ns.groups[1])) -- Party member is no longer suggested.
    equal(#c.invites, 0)
end)
test("Invite Others shares member cooldowns with individual invitations", function()
    local c = client()
    local group = suggestedGroup(c)
    c.homeGroup, c.partyMembers = true, { "Friend-TestRealm" }
    assert(c.ns.InviteQueuedPlayer("D1-TestRealm"))
    assert(not c.ns.CreateParty(group))
    equal(#c.invites, 1)
    c:advance(6)
    assert(c.ns.CreateParty(group))
    assert(not c.ns.InviteQueuedPlayer("D2-TestRealm"))
    equal(#c.invites, 4)
end)
test("Invite Others contains request failures without retrying or reinviting current members", function()
    local c = client()
    local group = suggestedGroup(c)
    c.homeGroup, c.partyMembers, c.failInvite = true, { "Friend-TestRealm" }, "D1-TestRealm"
    assert(not c.ns.CreateParty(group))
    equal(#c.invites, 2)
    for _, name in ipairs(c.invites) do assert(name == "D2-TestRealm" or name == "D3-TestRealm") end
    c:advance(6)
    equal(#c.invites, 2)
end)

test("combat and stale suggestions block invitation requests", function()
    local c = client()
    local group = suggestedGroup(c)
    c.combat = true
    assert(c.ns.CreatePartyDisabledReason(group):find("during combat", 1, true))
    assert(not c.ns.CreateParty(group))
    c.combat = false
    c:receive("Friend-TestRealm", { kind = "X", revision = 2, sentAt = c.now })
    assert(c.ns.CreatePartyDisabledReason(group):find("has changed", 1, true))
    assert(not c.ns.CreateParty(group))
    equal(#c.invites, 0)
end)
test("expired suggestions, missing APIs, and other players' groups are rejected", function()
    local c = client()
    local group = suggestedGroup(c)
    local player = group.slots[1]
    local record = c.ns.state.records[player.name]
    record.sentAt = c.now - c.ns.TIMEOUT
    assert(not c.ns.CreateParty(group))
    record.sentAt = c.now
    c.env.C_PartyInfo = nil
    assert(c.ns.CreatePartyDisabledReason(group):find("unavailable", 1, true))
    c.env.C_PartyInfo = { InviteUnit = function() error("Unexpected invite") end }
    c.ns.playerName = "SomebodyElse-TestRealm"
    assert(c.ns.CreatePartyDisabledReason(group):find("your own suggested group", 1, true))
    assert(not c.ns.CreateParty(group))
    equal(#c.invites, 0)
end)
test("rapid repeat clicks are blocked without automatic retries", function()
    local c = client()
    local group = suggestedGroup(c)
    assert(c.ns.CreateParty(group))
    assert(not c.ns.CreateParty(group))
    equal(#c.invites, 4)
    c:advance(6)
    equal(#c.invites, 4)
    assert(c.ns.CreatePartyDisabledReason(group) == nil)
end)
test("invitation errors are contained and never retried by timers", function()
    local c = client()
    local group = suggestedGroup(c)
    c.failInvite = "D1-TestRealm"
    assert(not c.ns.CreateParty(group))
    equal(#c.invites, 3)
    c:advance(6)
    equal(#c.invites, 3)
end)
test("party and combat events refresh the UI without sending invitations", function()
    local c, refreshes = client(), 0
    c.ns.RefreshUI = function() refreshes = refreshes + 1 end
    for _, event in ipairs({ "GROUP_ROSTER_UPDATE", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED" }) do
        c:fire(event)
    end
    equal(refreshes, 3)
    equal(#c.invites, 0)
end)

test("same-zone invites work without addon peers or shared quests and never retry automatically", function()
    local c = client({ rosterInfo = { ["Friend-TestRealm"] = { area = "Elwynn Forest" } } })
    assert(not c.ns.prefs.shareQuests and next(c.ns.questing.peers) == nil)
    assert(c.ns.QuestInviteDisabledReason("Friend-TestRealm") == nil)
    assert(c.ns.InviteQuestingPlayer("Friend Test Realm"))
    equal(#c.invites, 1)
    equal(c.invites[1], "Friend-TestRealm")
    assert(not c.ns.InviteQuestingPlayer("Friend-TestRealm"))
    c:advance(6)
    equal(#c.invites, 1)
    c.homeGroup, c.partyMembers = true, { "Other-TestRealm" }
    assert(c.ns.QuestInviteDisabledReason("Friend-TestRealm") == nil)
    assert(c.ns.InviteQuestingPlayer("Friend-TestRealm")) -- Other need not be queued or share dungeons.
    equal(#c.invites, 2)
    assert(not c.ns.queued and not c.ns.prefs.shareQuests)
end)
test("same-zone invites recheck roster online status and both players' zones at click time", function()
    for _, change in ipairs({ "offline", "moved", "removed", "localMoved", "guildChanged" }) do
        local c = client({ rosterInfo = { ["Friend-TestRealm"] = { area = "Elwynn Forest" } } })
        receiveQuests(c, "Friend-TestRealm", {}) -- Old peer data must not override a fresh roster check.
        assert(c.ns.QuestInviteDisabledReason("Friend-TestRealm") == nil)
        if change == "offline" then c.rosterInfo["Friend-TestRealm"].online = false
        elseif change == "moved" then c.rosterInfo["Friend-TestRealm"].area = "Westfall"
        elseif change == "removed" then c.roster = { "Self-TestRealm" }
        elseif change == "guildChanged" then c.guild, c.roster = "Another Guild", { "Self-TestRealm" }
        else
            c.zoneID, c.zoneName = 52, "Westfall"
            c:fire("ZONE_CHANGED_NEW_AREA")
        end
        assert(not c.ns.InviteQuestingPlayer("Friend-TestRealm"), change)
        equal(#c.invites, 0)
    end
end)
test("same-zone invite guards block self unknown targets combat full groups and missing permissions", function()
    local c = client({ rosterInfo = { ["Friend-TestRealm"] = { area = "Elwynn Forest" } } })
    assert(not c.ns.InviteQuestingPlayer("Self-TestRealm"))
    assert(not c.ns.InviteQuestingPlayer("Unknown-TestRealm"))
    for _, field in ipairs({ "combat", "partyFull", "instanceGroup" }) do
        c[field] = true
        assert(not c.ns.InviteQuestingPlayer("Friend-TestRealm"))
        c[field] = false
    end
    c.canInvite = false
    assert(not c.ns.InviteQuestingPlayer("Friend-TestRealm"))
    c.canInvite = true
    c.env.C_PartyInfo.CanInvite = function() error("Party status unavailable") end
    assert(not c.ns.InviteQuestingPlayer("Friend-TestRealm"))
    c.env.C_PartyInfo = nil
    assert(not c.ns.InviteQuestingPlayer("Friend-TestRealm"))
    equal(#c.invites, 0)
end)
test("failed same-zone invitations are contained and not retried by timers", function()
    local c = client({ rosterInfo = { ["Friend-TestRealm"] = { area = "Elwynn Forest" } } })
    c.failInvite = "Friend-TestRealm"
    assert(not c.ns.InviteQuestingPlayer("Friend-TestRealm"))
    c.failInvite = nil
    assert(not c.ns.InviteQuestingPlayer("Friend-TestRealm"))
    c:advance(6)
    equal(#c.invites, 0)
end)
test("login withdraws previous queue state and never auto-rejoins", function()
    local c = client({ saved = { roles = 3, dungeons = { [1] = true }, revision = 1800000000999 } })
    assert(not c.ns.queued)
    c:advance(1)
    local p = assert(c.ns.Protocol.Decode(c.sent[1].text))
    equal(p.kind, "X")
    assert(p.revision > 1800000000999)
    equal(c.ns.prefs.roles, 3)
end)
test("delayed guild identity recovers automatically without a roster event", function()
    local c = client({ guildInfoUnavailable = true, roster = {} })
    c.ns.SetQueued(true)
    assert(not c.ns.queued)
    assert(c.ns.StatusText():find("Waiting for guild information", 1, true))
    c.guildInfoUnavailable = false
    c:advance(1)
    assert(c.ns.IsReady())
    c.ns.SetQueued(true)
    c:advance(1)
    assert(c.ns.state.records[c.ns.playerName])
end)
test("presence counts self and recent guild-addon peers, expires them, and resets on guild change", function()
    local c = client()
    equal(c.ns.OnlineAddonCount(), 1)
    c:receive("Friend-TestRealm", { kind = "P" })
    equal(c.ns.OnlineAddonCount(), 2)
    c:advance(c.ns.TIMEOUT - 1)
    equal(c.ns.OnlineAddonCount(), 2)
    c:advance(1)
    equal(c.ns.OnlineAddonCount(), 1)
    c:receive("Friend-TestRealm", packet(1, 4, nil, c.now, c.now))
    equal(c.ns.OnlineAddonCount(), 2)
    assert(c.ns.state.records["Friend-TestRealm"])
    c.guild = "Other Guild"
    c:fire("PLAYER_GUILD_UPDATE", "player")
    equal(c.ns.OnlineAddonCount(), 1)
    equal(c.ns.state.records["Friend-TestRealm"], nil)
    local noGuild = client({ noGuild = true })
    equal(noGuild.ns.OnlineAddonCount(), 0)
end)
test("idle addon users periodically broadcast guild-only presence without joining queue", function()
    local c = client()
    c:advance(22)
    assert(not c.ns.queued)
    local presences = 0
    for _, message in ipairs(c.sent) do
        if c.ns.Protocol.Decode(message.text).kind == "P" then
            presences = presences + 1
            equal(message.channel, "GUILD")
        end
    end
    assert(presences >= 1)
end)
test("same-zone roster members include non-addon users without claiming zero shared quests", function()
    local c = client({ roster = { "Self-TestRealm", "Friend-TestRealm", "Away-TestRealm", "Offline-TestRealm" },
        rosterInfo = {
            ["Self-TestRealm"] = { area = "Elwynn Forest" },
            ["Friend-TestRealm"] = { area = "Elwynn Forest", level = 26 },
            ["Away-TestRealm"] = { area = "Westfall" },
            ["Offline-TestRealm"] = { area = "Elwynn Forest", online = false },
        } })
    local members = c.ns.GetQuestingPlayers()
    equal(#members, 1)
    equal(members[1].name, "Friend-TestRealm")
    equal(members[1].level, 26)
    equal(members[1].shared, nil)
    assert(not c.ns.prefs.shareQuests)
    c:advance(25)
    for _, message in ipairs(c.sent) do assert(not c.ns.Questing.Decode(message.text)) end
end)
test("shared active quest IDs and completion states work independently of the dungeon queue", function()
    local c = client({ quests = { { questID = 10, title = "A shared quest" },
        { questID = 20, title = "Another shared quest", complete = true },
        { questID = 30, title = "Only mine" }, { isHeader = true, title = "Zone" } } })
    receiveQuests(c, "Friend-TestRealm", { [10] = true, [20] = false, [99] = true })
    local members = c.ns.GetQuestingPlayers()
    equal(#members, 1)
    equal(#members[1].shared, 2)
    equal(members[1].shared[1].title, "A shared quest")
    equal(members[1].shared[1].localComplete, false)
    equal(members[1].shared[1].peerComplete, true)
    equal(members[1].shared[2].localComplete, true)
    assert(not c.ns.queued)
    equal(next(c.ns.state.records), nil)
    equal(#c.invites, 0)
end)
test("quest snapshots require the exact guild channel, prefix, identity and freshness", function()
    local c = client()
    for _, channel in ipairs({ "WHISPER", "PARTY", "RAID", "OFFICER", "CHANNEL" }) do
        receiveQuests(c, "Friend-TestRealm", { [10] = false }, 1, 37, channel)
    end
    receiveQuests(c, "Friend-TestRealm", {}, 1, 37, "GUILD", "OtherAddon")
    receiveQuests(c, "Self Test Realm", { [10] = false })
    equal(next(c.ns.questing.peers), nil)
    local stale = c.ns.Questing.Encode(1, c.now - c.ns.TIMEOUT, 37, 23, {})[1]
    c:fire("CHAT_MSG_ADDON", c.ns.PREFIX, stale, "GUILD", "Friend-TestRealm")
    equal(next(c.ns.questing.peers), nil)
    receiveQuests(c, "Friend-TestRealm", {})
    assert(c.ns.questing.peers["Friend-TestRealm"])
    c.guild = "New Guild"
    c:fire("PLAYER_GUILD_UPDATE", "player")
    equal(next(c.ns.questing.peers), nil)
    equal(#c.ns.GetQuestingPlayers(), 0)
end)
test("opt-in publishes bounded guild-only quest snapshots and turning off cancels pending data", function()
    local c = client({ quests = { { questID = 10, title = "Not sent in payload" } } })
    c.ns.SetQuestSharing(true)
    c:advance(7)
    local snapshots = 0
    for _, message in ipairs(c.sent) do
        local p = c.ns.Questing.Decode(message.text)
        if p and p.kind == "Q" then
            snapshots = snapshots + 1
            equal(p.zoneID, 37)
            equal(p.quests[10], false)
            assert(#message.text <= 255)
            assert(not message.text:find("Not sent", 1, true))
            equal(message.channel, "GUILD")
        end
    end
    assert(snapshots > 0)
    c.ns.SetQuestSharing(false)
    local previous = #c.sent
    c:advance(7)
    local stopped = false
    for index = previous + 1, #c.sent do
        local p = c.ns.Questing.Decode(c.sent[index].text)
        if p then equal(p.kind, "QX") stopped = true end
    end
    assert(stopped)
    equal(#c.invites, 0)
end)
test("multipart publication is rate limited and consent withdrawal cancels unsent fragments", function()
    local quests = {}
    for id = 1, 200 do quests[id] = { questID = 2000000000 + id, title = "Quest " .. id } end
    local c = client({ quests = quests })
    c.ns.SetQueued(true)
    c.ns.SetQuestSharing(true)
    c:advance(4)
    local fragments = 0
    for _, message in ipairs(c.sent) do
        local p = c.ns.Questing.Decode(message.text)
        if p and p.kind == "Q" then
            fragments = fragments + 1
            assert(p.parts > 1)
        end
    end
    assert(fragments > 0)
    c.ns.SetQuestSharing(false)
    local previous = #c.sent
    c:advance(25)
    for index = previous + 1, #c.sent do
        local p = c.ns.Questing.Decode(c.sent[index].text)
        assert(not p or p.kind == "QX")
    end
    local lastClock = -1
    for _, message in ipairs(c.sent) do
        assert(message.clock > lastClock, "more than one scheduled message in a second")
        lastClock = message.clock
    end
    assert(c.ns.queued and c.ns.state.records[c.ns.playerName])
    equal(#c.invites, 0)
end)
test("quest completion, abandonment, additions and zone changes publish replacement snapshots", function()
    local c = client({ quests = { { questID = 10, title = "Old quest" } } })
    c.ns.SetQuestSharing(true)
    c:advance(7)
    c.questLog = { { questID = 20, title = "New quest", complete = true } }
    c.zoneID, c.zoneName = 52, "Westfall"
    c:fire("QUEST_LOG_UPDATE")
    c:fire("ZONE_CHANGED_NEW_AREA")
    c:advance(7)
    local receiver = c.ns.Questing.New()
    for _, message in ipairs(c.sent) do
        local p = c.ns.Questing.Decode(message.text)
        if p then receiver:Apply("Self-TestRealm", p, c.now) end
    end
    local peer = assert(receiver.peers["Self-TestRealm"])
    equal(peer.zoneID, 52)
    equal(peer.quests[10], nil)
    equal(peer.quests[20], true)
end)
test("quest log and zone changes replace the shared snapshot and expired data becomes unavailable", function()
    local c = client({ quests = { { questID = 10, title = "Shared" } }, rosterInfo = {
        ["Friend-TestRealm"] = { area = "Elwynn Forest" } } })
    receiveQuests(c, "Friend-TestRealm", { [10] = false })
    equal(#c.ns.GetQuestingPlayers()[1].shared, 1)
    c.questLog = {}
    c:fire("QUEST_LOG_UPDATE")
    c:advance(1)
    equal(#c.ns.GetQuestingPlayers()[1].shared, 0)
    c:advance(c.ns.TIMEOUT)
    equal(c.ns.GetQuestingPlayers()[1].shared, nil)
    c.zoneID, c.zoneName = 52, "Westfall"
    c:fire("ZONE_CHANGED_NEW_AREA")
    c:advance(1)
    equal(#c.ns.GetQuestingPlayers(), 0)
end)
test("local map normalization uses a zone parent without mistaking a continent for a zone", function()
    local c = client()
    receiveQuests(c, "Friend-TestRealm", {})
    c.zoneID = 1000
    c.mapInfo[1000] = { name = "Cave", mapType = 5, parentMapID = 37 }
    c:fire("ZONE_CHANGED_INDOORS")
    c:advance(1)
    equal(#c.ns.GetQuestingPlayers(), 1)
    c.mapInfo[37] = { name = "Continent", mapType = 2, parentMapID = 0 }
    c:fire("ZONE_CHANGED_NEW_AREA")
    c:advance(1)
    equal(#c.ns.GetQuestingPlayers(), 0)
end)
test("unavailable quest APIs never advertise an empty quest log or disable dungeon queuing", function()
    local c = client({ quests = { { questID = 10, title = "Shared" } } })
    c.env.C_QuestLog = nil
    c:fire("QUEST_LOG_UPDATE")
    c.ns.SetQuestSharing(true)
    c.ns.SetQueued(true)
    c:advance(7)
    assert(c.ns.state.records[c.ns.playerName])
    for _, message in ipairs(c.sent) do assert(not c.ns.Questing.Decode(message.text)) end
end)
test("only the server-enforced guild transport and exact prefix admit peer state and presence", function()
    local c = client({ roster = {} })
    local p = packet(1, 1, nil, c.now, c.now)
    -- WoW delivers GUILD traffic only from guild members. Outsiders cannot choose
    -- that receive channel; untrusted whispers/party traffic must never be relayed.
    for _, channel in ipairs({ "WHISPER", "PARTY", "RAID", "OFFICER", "INSTANCE_CHAT", "CHANNEL" }) do
        c:receive("Outsider-TestRealm", p, channel)
        c:receive("Outsider-TestRealm", { kind = "P" }, channel)
    end
    c:receive("Friend-TestRealm", p, "GUILD", "OtherAddon")
    c:receive("Friend-TestRealm", { kind = "P" }, "GUILD", "OtherAddon")
    equal(next(c.ns.state.records), nil)
    equal(c.ns.OnlineAddonCount(), 1)
    c:receive("Friend-TestRealm", p)
    equal(c.ns.state.records["Friend-TestRealm"].roles, 1)
    equal(c.ns.OnlineAddonCount(), 2)
end)
test("not being in a guild still blocks queuing and guild traffic", function()
    local c = client({ noGuild = true })
    assert(not c.ns.IsReady())
    equal(c.ns.JoinQueueDisabledReason(), "Join a guild to use the queue.")
    c.ns.SetQueued(true)
    c:receive("Friend-TestRealm", packet(1, 4, nil, c.now, c.now))
    c:advance(2)
    assert(not c.ns.queued)
    equal(next(c.ns.state.records), nil)
    equal(#c.sent, 0)
end)
test("unresolved character information has its own status and retries automatically", function()
    local c = client({ nameUnavailable = true, roster = {} })
    assert(not c.ns.IsReady())
    equal(c.ns.StatusText(), "Waiting for your character name and realm.")
    c.nameUnavailable = false
    c:advance(1)
    assert(c.ns.IsReady())
end)
test("a guild change with unresolved metadata immediately drops old guild state", function()
    local c = client({ roster = {} })
    c.ns.SetQueued(true)
    c:advance(1)
    c:receive("OldPeer-TestRealm", packet(1, 4, nil, c.now, c.now))
    c.guild, c.guildInfoUnavailable = "New Guild", true
    c:fire("PLAYER_GUILD_UPDATE", "player")
    assert(not c.ns.queued and not c.ns.IsReady())
    equal(next(c.ns.state.records), nil)
    c:receive("NewPeer-TestRealm", packet(1, 4, nil, c.now, c.now))
    equal(next(c.ns.state.records), nil)
    c.guildInfoUnavailable = false
    c:advance(1)
    equal(c.ns.guildName, "New Guild")
    assert(c.ns.IsReady() and not c.ns.queued)
end)
test("temporary guild metadata loss suspends messaging without losing same-guild queue state", function()
    local c = client({ roster = {} })
    c.ns.SetQueued(true)
    c:advance(2)
    local before = #c.sent
    c.guildInfoUnavailable = true
    c:advance(1)
    assert(not c.ns.IsReady() and c.ns.queued)
    c:receive("Friend-TestRealm", packet(1, 4, nil, c.now, c.now))
    equal(c.ns.state.records["Friend-TestRealm"], nil)
    equal(#c.sent, before)
    c.guildInfoUnavailable = false
    c:advance(1)
    assert(c.ns.IsReady() and c.ns.queued)
    assert(c.ns.state.records[c.ns.playerName])
end)
test("incoming guild traffic refreshes guild identity before accepting a peer", function()
    local c = client({ roster = {} })
    c:receive("OldPeer-TestRealm", packet(1, 4, nil, c.now, c.now))
    c.guild = "New Guild"
    -- Simulate delivery before PLAYER_GUILD_UPDATE or the next timer tick.
    c:receive("NewPeer-TestRealm", packet(1, 4, nil, c.now, c.now))
    equal(c.ns.guildName, "New Guild")
    equal(c.ns.state.records["OldPeer-TestRealm"], nil)
    assert(c.ns.state.records["NewPeer-TestRealm"])
end)
test("join readiness still requires selections and status reports actual blockers", function()
    local c = client({ saved = { roles = 0, dungeons = {} }, roster = {} })
    assert(c.ns.IsReady())
    equal(c.ns.JoinQueueDisabledReason(), "Select at least one role and one dungeon.")
    c.env.SlashCmdList.GUILDQUEUE("status")
    assert(c.messages[#c.messages]:find("guild information: ready", 1, true))
    assert(c.messages[#c.messages]:find("addon messaging: ready", 1, true))
    assert(not c.ns.queued)
    c.ns.prefs.roles, c.ns.prefs.dungeons = 4, { [1] = true }
    assert(c.ns.JoinQueueDisabledReason() == nil)
end)
test("saved selections lose unsupported roles without auto-selecting a replacement", function()
    for _, example in ipairs({ { 6, 7, 6 }, { 6, 1, 0 }, { 4, 7, 4 }, { 5, 7, 5 }, { 7, 7, 7 } }) do
        local c = client({ allowedRoles = example[1], saved = { roles = example[2], dungeons = { [1] = true } } })
        equal(c.ns.prefs.roles, example[3])
        assert(not c.ns.queued)
    end
end)
test("Priest-style class roles reject Tank and scrub queued updates before broadcasting", function()
    local c = client({ allowedRoles = 6 })
    c.ns.prefs.roles = 1
    assert(c.ns.JoinQueueDisabledReason():find("your class", 1, true))
    c.env.SlashCmdList.GUILDQUEUE("join")
    assert(not c.ns.queued)
    c.ns.prefs.roles = 6
    c.ns.SetQueued(true)
    c:advance(1)
    local joinedAt = c.ns.joinedAt
    c.ns.prefs.roles = 7 -- Also guard changes that bypass the checkbox callback.
    c:advance(1)
    equal(c.ns.prefs.roles, 6)
    equal(c.ns.state.records[c.ns.playerName].roles, 6)
    equal(c.ns.joinedAt, joinedAt)
    for _, sent in ipairs(c.sent) do
        local decoded = c.ns.Protocol.Decode(sent.text)
        if decoded and decoded.kind == "S" then assert(not c.ns.HasRole(decoded.roles, 1)) end
    end
end)
test("removing the final supported role immediately withdraws a queued player", function()
    local c = client({ allowedRoles = 6 })
    c.ns.SetQueued(true)
    c:advance(1)
    c.ns.prefs.roles = 1
    c.ns.PreferencesChanged()
    equal(c.ns.prefs.roles, 0)
    assert(not c.ns.queued and not c.ns.state.records[c.ns.playerName])
    c:advance(1)
    equal(c.ns.Protocol.Decode(c.sent[#c.sent].text).kind, "X")
end)
test("missing role data blocks only queue entry and recovers without auto-joining", function()
    for _, options in ipairs({ { noRoleAPI = true }, { rolesUnavailable = true },
        { roleAPIError = true }, { allowedRoles = 0 } }) do
        options.saved = { roles = 7, dungeons = { [1] = true } }
        local c = client(options)
        assert(c.ns.IsReady()) -- Never make the guild roster a class-data dependency.
        equal(c.ns.JoinQueueDisabledReason(), "Waiting for your class role information.")
        c.ns.SetQueued(true)
        assert(not c.ns.queued)
        c.env.UnitGetAvailableRoles = function() return false, true, true end
        c:advance(1)
        equal(c.ns.prefs.roles, 6)
        assert(c.ns.JoinQueueDisabledReason() == nil and not c.ns.queued)
    end
end)
test("temporary role API loss keeps the last valid class capabilities", function()
    local c = client({ allowedRoles = 6 })
    c.ns.SetQueued(true)
    c:advance(1)
    c.rolesUnavailable = true
    c:advance(20)
    equal(c.ns.AllowedRoles(), 6)
    assert(c.ns.queued and c.ns.RoleDisabledReason(1))
    equal(c.ns.state.records[c.ns.playerName].roles, 4)
end)
test("malformed or restricted native role values are never used as role selections", function()
    local c = client({ rolesUnavailable = true })
    local restricted = {}
    c.env.hasanysecretvalues = function(...) return select(1, ...) == restricted end
    c.env.UnitGetAvailableRoles = function() return restricted, true, true end
    assert(c.ns.AllowedRoles() == nil)
    c.env.UnitGetAvailableRoles = function() return 1, true, true end
    assert(c.ns.AllowedRoles() == nil)
    assert(c.ns.RoleDisabledReason(1))
    c.ns.SetQueued(true)
    assert(not c.ns.queued)
end)
test("join, heartbeat, selection update and manual withdrawal", function()
    local c = client()
    c.ns.SetQueued(true)
    c:advance(1)
    local record = assert(c.ns.state.records["Self-TestRealm"])
    local age = record.joinedAt
    c:advance(20)
    assert(c.ns.state.records["Self-TestRealm"].sentAt > record.sentAt)
    c.ns.prefs.roles = 3
    c.ns.PreferencesChanged()
    c:advance(1)
    equal(c.ns.state.records["Self-TestRealm"].roles, 3)
    equal(c.ns.state.records["Self-TestRealm"].joinedAt, age)
    c.ns.SetQueued(false)
    equal(c.ns.state.records["Self-TestRealm"], nil)
    c:advance(1)
    equal(c.ns.Protocol.Decode(c.sent[#c.sent].text).kind, "X")
    for _, message in ipairs(c.sent) do equal(message.channel, "GUILD") end
end)
test("messaging failure does not advertise a local successful join", function()
    local c = client()
    c.result = 11
    c.ns.SetQueued(true)
    c:advance(6)
    equal(c.ns.state.records["Self-TestRealm"], nil)
    assert(c.ns.StatusText():find("could not be sent", 1, true))
    assert(#c.sent <= 2)
    c.result = 0
    c:advance(5)
    assert(c.ns.state.records["Self-TestRealm"])
end)
test("chat lockdown sends nothing, then recovers", function()
    local c = client()
    c.locked = true
    c.ns.SetQueued(true)
    c:advance(6)
    equal(#c.sent, 0)
    c.locked = false
    c:advance(5)
    assert(c.ns.state.records["Self-TestRealm"])
end)
test("late joiner hello elicits the queued player's own state", function()
    local c = client()
    c.ns.SetQueued(true)
    c:advance(2)
    local before = #c.sent
    c:receive("Friend-TestRealm", { kind = "H" })
    c:advance(6)
    assert(#c.sent > before)
    equal(c.ns.Protocol.Decode(c.sent[#c.sent].text).kind, "S")
end)
test("remote disconnect expires and guild switching clears the queue", function()
    local c = client()
    c:receive("Friend-TestRealm", packet(1, 1, nil, c.now, c.now))
    c:advance(75)
    equal(c.ns.state.records["Friend-TestRealm"], nil)
    c.ns.SetQueued(true)
    c:advance(1)
    c.guild = "Different Guild"
    c:fire("PLAYER_GUILD_UPDATE", "player")
    equal(c.ns.queued, false)
    equal(next(c.ns.state.records), nil)
end)
test("removing the last selected role or dungeon leaves the queue", function()
    local c = client()
    c.ns.SetQueued(true)
    c:advance(1)
    c.ns.prefs.roles = 0
    c.ns.PreferencesChanged()
    assert(not c.ns.queued)
    equal(c.ns.state.records["Self-TestRealm"], nil)
end)
test("slash commands toggle UI and explicitly join/leave", function()
    local c = client()
    c.env.SlashCmdList.GUILDQUEUE("")
    assert(c.toggled)
    c.env.SlashCmdList.GUILDQUEUE(" JOIN ")
    assert(c.ns.queued)
    c.env.SlashCmdList.GUILDQUEUE("leave")
    assert(not c.ns.queued)
end)
test("corrupt saved preferences are sanitized", function()
    local c = client({ saved = { roles = 0 / 0, dungeons = { [1] = true, [999] = true },
        revision = math.huge, shareQuests = "yes" } })
    equal(c.ns.prefs.roles, 4)
    equal(c.ns.prefs.revision, 0)
    equal(c.ns.prefs.dungeons[999], nil)
    assert(c.ns.prefs.dungeons[1])
    equal(c.ns.prefs.shareQuests, false)
end)
local function openUI(c)
    local widgets, methods = {}, {}
    local function widget(template, kind, parent, name)
        local object = setmetatable({ template = template, frameType = kind, parent = parent,
            frameName = name, scripts = {}, shown = true, enabled = true,
            width = 0, height = 0, scroll = 0 }, { __index = methods })
        widgets[#widgets + 1] = object
        return object
    end
    function methods:SetSize(width, height)
        assert(width >= 0 and height >= 0, "widget dimensions must be non-negative")
        self.width, self.height = width, height
    end
    function methods:SetWidth(width)
        assert(width >= 0, "widget width must be non-negative")
        self.width = width
    end
    function methods:SetHeight(height)
        assert(height >= 0, "widget height must be non-negative")
        self.height = height
    end
    function methods:SetAllPoints(target) self.allPoints = target end
    function methods:GetWidth() return self.allPoints and self.allPoints:GetWidth() or self.width end
    function methods:GetHeight() return self.allPoints and self.allPoints:GetHeight() or self.height end
    function methods:ClearAllPoints() self.point, self.allPoints = nil, nil end
    function methods:SetText(text)
        self.text = tostring(text or "")
        if self.fontString then self.fontString.text = self.text end
    end
    function methods:SetFontString(fontString) self.fontString = fontString end
    function methods:SetPoint(...) self.point = { ... } end
    function methods:SetScale(scale) self.scale = scale end
    function methods:SetBackdrop(value) self.backdrop = value end
    function methods:SetBackdropColor(...) self.backdropColor = { ... } end
    function methods:SetBackdropBorderColor(...) self.borderColor = { ... } end
    function methods:SetColorTexture(...) self.color = { ... } end
    function methods:SetTextColor(...) self.textColor = { ... } end
    function methods:SetTexture(path) self.texture = path end
    function methods:SetAtlas(atlas, useAtlasSize)
        self.atlas = atlas
        if useAtlasSize then
            -- Deliberately model distinct native active/inactive atlas heights.
            self:SetSize(16, atlas:find("activetab", 1, true) and 32 or 26)
        end
    end
    function methods:SetDesaturated(value) self.desaturated = value end
    function methods:SetDrawLayer(layer, sublevel) self.layer, self.sublevel = layer, sublevel end
    function methods:SetButtonState(state, locked) self.buttonState, self.locked = state, locked end
    function methods:GetNormalTexture() return self.normalTexture end
    function methods:GetPushedTexture() return self.pushedTexture end
    function methods:GetHighlightTexture() return self.highlightTexture end
    function methods:GetCheckedTexture() return self.checkedTexture end
    function methods:GetDisabledCheckedTexture() return self.disabledCheckedTexture end
    function methods:CreateTexture(_, layer, _, sublevel)
        local texture = widget(nil, "Texture", self)
        texture.layer, texture.sublevel = layer, sublevel
        return texture
    end
    function methods:IsEnabled() return self.enabled end
    function methods:GetTop() return 1080 end
    function methods:GetEffectiveScale() return self.scale or 1 end
    function methods:SetScript(name, callback) self.scripts[name] = callback end
    function methods:SetChecked(value) self.checked = value end
    function methods:GetChecked() return self.checked end
    function methods:SetEnabled(value) self.enabled = value end
    function methods:IsShown() return self.shown end
    function methods:SetShown(value)
        self.shown = value
        if value and self.scripts.OnShow then self.scripts.OnShow(self) end
    end
    function methods:Show() self:SetShown(true) end
    function methods:Hide()
        self.shown = false
        if self.scripts.OnHide then self.scripts.OnHide(self) end
    end
    function methods:SetMotionScriptsWhileDisabled(value) self.motionWhileDisabled = value end
    function methods:CreateFontString(_, _, template) return widget(template, "FontString", self) end
    function methods:GetStringHeight() return #(self.text or "") / 5 + 16 end
    function methods:SetVerticalScroll(value) self.scroll = value end
    function methods:GetVerticalScroll() return self.scroll end
    for _, name in ipairs({ "SetJustifyH", "SetJustifyV", "SetSpacing",
        "SetFrameStrata", "SetClampedToScreen", "SetMovable", "EnableMouse", "EnableMouseWheel",
        "SetWordWrap", "SetNonSpaceWrap", "RegisterForDrag", "SetScrollChild", "StartMoving",
        "StopMovingOrSizing" }) do
        methods[name] = function() end
    end
    c.tooltip = {}
    c.env.GameTooltip = {
        SetOwner = function(_, owner) c.tooltip.owner = owner end,
        SetText = function(_, text) c.tooltip.title = text end,
        AddLine = function(_, text) c.tooltip.text = text end,
        IsOwned = function(_, owner) return c.tooltip.owner == owner end,
        Show = function() c.tooltip.shown = true end,
        Hide = function() c.tooltip.owner, c.tooltip.shown = nil, false end,
    }
    c.env.UIParent, c.env.UISpecialFrames = widget(nil, "Frame", nil, "UIParent"), {}
    c.env.UIParent:SetSize(1920, 1080)
    c.env.GetCursorPosition = function() return 0, 0 end
    c.env.CreateFrame = function(kind, name, parent, template)
        local control = widget(template, kind, parent, name)
        if template == "UICheckButtonTemplate" then
            for _, key in ipairs({ "normalTexture", "pushedTexture", "highlightTexture",
                "checkedTexture", "disabledCheckedTexture" }) do
                control[key] = control:CreateTexture(nil, "ARTWORK")
            end
        elseif template == "PanelTabButtonTemplate" then
            control:SetSize(10, 32)
            control.Text = control:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            control.Text:SetHeight(10)
            control:SetFontString(control.Text)
            for _, part in ipairs({ "Left", "Middle", "Right" }) do
                local suffix = part == "Middle" and "center" or part:lower()
                local prefix = part == "Middle" and "_" or ""
                for _, state in ipairs({ "", "Active", "Highlight" }) do
                    local texture = control:CreateTexture(nil, state == "Highlight" and "HIGHLIGHT" or "BACKGROUND")
                    texture:SetAtlas(prefix .. "uiframe-" .. (state == "Active" and "activetab-" or "tab-") .. suffix, true)
                    control[part .. state] = texture
                end
            end
            -- Actual outer anchors from Forever's PanelTabButtonTemplate:
            -- artwork extends beyond the button's clickable rectangle.
            control.Left:SetPoint("TOPLEFT", control, "TOPLEFT", -3, 0)
            control.Right:SetPoint("TOPRIGHT", control, "TOPRIGHT", 7, 0)
            control.LeftActive:SetPoint("TOPLEFT", control, "TOPLEFT", -1, 0)
            control.RightActive:SetPoint("TOPRIGHT", control, "TOPRIGHT", 8, 0)
        end
        return control
    end
    local function nativeTabState(control, selected)
        control.nativeSelected = selected
        control:SetEnabled(not selected)
        local textY = selected and (control.selectedTextY or -3) or (control.deselectedTextY or 2)
        control.Text:SetPoint("CENTER", control, "CENTER", 0, textY)
        for _, key in ipairs({ "Left", "Middle", "Right" }) do
            control[key]:SetShown(not selected)
            control[key .. "Active"]:SetShown(selected)
        end
    end
    c.env.PanelTemplates_SelectTab = function(control) nativeTabState(control, true) end
    c.env.PanelTemplates_DeselectTab = function(control) nativeTabState(control, false) end
    c.env.PanelTemplates_TabResize = function(control, padding, absolute, minimum)
        control.tabPadding, control.minTabWidth = padding, minimum
        local width = absolute or math.max(minimum, #control.text * 7 + 20 + padding)
        control:SetWidth(width)
        control.Text:SetWidth(width - 20 - padding)
    end
    local ui = assert(loadfile("GuildQueue/UI.lua"))
    setfenv(ui, c.env)
    ui("GuildQueue", c.ns)
    c.ns.ToggleUI()
    equal(c.env.UISpecialFrames[1], "GuildQueueFrame")
    return widgets
end

local function roleListUI(c)
    local widgets, views, tabs = openUI(c), {}, {}
    for _, control in ipairs(widgets) do
        if control.guildQueueKind == "viewSwitch" then views[control.viewMode] = control end
        if control.guildQueueKind == "tab" then tabs[control.mode] = control end
    end
    assert(views.default.selected and not views.roles.selected)
    views.roles.scripts.OnClick(views.roles)
    return widgets, views, tabs
end

test("Role List switch leaves Default matching intact and shows three role columns", function()
    local c = client()
    suggestedGroup(c)
    local original = c.ns.groups
    c.ns.Match = function() error("Switching views must not rematch") end
    local widgets, views, tabs = roleListUI(c)
    assert(views.roles.selected and not views.default.selected)
    assert(not tabs.groups.shown and not tabs.queue.shown)
    local counts, toolbar = { [1] = 0, [2] = 0, [4] = 0 }
    for _, control in ipairs(widgets) do
        if control.guildQueueKind == "rolePlayer" and control.shown then
            counts[control.role] = counts[control.role] + 1
            assert(control.invite.shown)
            equal(control.invite.enabled, control.player.name ~= c.ns.playerName)
        end
        if control.guildQueueKind == "roleToolbar" then toolbar = control end
        if control.guildQueueKind == "group" then assert(not control.shown) end
    end
    assert(toolbar.shown)
    equal(toolbar.columns[1].text, "Tank (1)")
    equal(toolbar.columns[2].text, "Healer (1)")
    equal(toolbar.columns[4].text, "Damage (3)")
    equal(counts[1], 1) equal(counts[2], 1) equal(counts[4], 3)
    equal(c.ns.groups, original)
    views.default.scripts.OnClick(views.default)
    assert(tabs.groups.shown and tabs.groups.selected and not toolbar.shown)
    equal(c.ns.groups, original)
    equal(#c.invites, 0)
end)
test("Role List cards duplicate selected roles filter shared dungeons and sort longest waiting first", function()
    local c = client()
    c:receive("Recent-TestRealm", packet(1, 7, nil, c.now - 10, c.now))
    c:receive("Old-TestRealm", packet(1, 1, { [1] = true, [2] = true }, c.now - 200, c.now))
    c:receive("Hidden-TestRealm", packet(1, 4, { [2] = true }, c.now - 300, c.now))
    local widgets = roleListUI(c)
    local rows = { [1] = {}, [2] = {}, [4] = {} }
    for _, card in ipairs(widgets) do
        if card.guildQueueKind == "rolePlayer" and card.shown then
            rows[card.role][#rows[card.role] + 1] = card
            assert(card.player.name ~= "Hidden-TestRealm")
            equal(card.dungeons.text, c.ns.DungeonName(c.ns.DUNGEON_BY_ID[1]))
            local expectedX = card.role == 1 and 0 or card.role == 2 and 246 or 492
            equal(card.point[2], expectedX)
            assert(card.point[2] + card:GetWidth() <= 728)
        end
    end
    equal(#rows[1], 2) equal(#rows[2], 1) equal(#rows[4], 1)
    equal(rows[1][1].player.name, "Old-TestRealm")
    equal(rows[1][1].wait.text, "Queued 3m 20s")
    equal(rows[1][2].player.name, "Recent-TestRealm")
    equal(rows[2][1].player.name, "Recent-TestRealm")
    equal(rows[4][1].player.name, "Recent-TestRealm")
    rows[2][1].invite.scripts.OnClick(rows[2][1].invite)
    equal(#c.invites, 1)
    equal(c.invites[1], "Recent-TestRealm")
    for _, role in ipairs({ 1, 2, 4 }) do
        for _, card in ipairs(rows[role]) do
            if card.player.name == "Recent-TestRealm" then assert(not card.invite.enabled) end
        end
    end
end)
test("Role List updates shared-dungeon filters and expiry without joining the queue", function()
    local c = client()
    c:receive("Friend-TestRealm", packet(1, 4, nil, c.now, c.now))
    local widgets = roleListUI(c)
    local card, toolbar
    for _, widget in ipairs(widgets) do
        if widget.guildQueueKind == "rolePlayer" then card = widget end
        if widget.guildQueueKind == "roleToolbar" then toolbar = widget end
    end
    assert(card.shown)
    c.ns.prefs.dungeons = { [2] = true }
    c.ns.PreferencesChanged()
    assert(not card.shown and card.invite.memberName == nil)
    equal(toolbar.columns[4].text, "Damage (0)")
    c:receive("Friend-TestRealm", packet(2, 4, { [1] = true, [2] = true }, c.now, c.now))
    assert(card.shown)
    equal(card.dungeons.text, c.ns.DungeonName(c.ns.DUNGEON_BY_ID[2]))
    c:advance(c.ns.TIMEOUT)
    assert(not card.shown)
    equal(toolbar.columns[4].text, "Damage (0)")
    assert(not c.ns.queued)
    equal(#c.invites, 0)
end)
test("Role List invitation buttons recheck live permissions and explain disabled states", function()
    local c = client()
    c:receive("Friend-TestRealm", packet(1, 4, nil, c.now, c.now))
    local widgets = roleListUI(c)
    local invite
    for _, widget in ipairs(widgets) do
        if widget.guildQueueKind == "queueInvite" then invite = widget end
    end
    assert(invite.enabled and invite.motionWhileDisabled)
    c.canInvite = false -- Change after rendering but before clicking.
    invite.scripts.OnClick(invite)
    equal(#c.invites, 0)
    assert(not invite.enabled)
    invite.scripts.OnEnter(invite)
    assert(c.tooltip.text:find("permission", 1, true))
    c.canInvite, c.partyFull = true, true
    c:fire("GROUP_ROSTER_UPDATE")
    assert(c.tooltip.text:find("full", 1, true))
end)
test("Role List pooled cards never invite a withdrawn former occupant", function()
    local c = client()
    c:receive("First-TestRealm", packet(1, 4, nil, c.now, c.now))
    local widgets = roleListUI(c)
    local card
    for _, widget in ipairs(widgets) do
        if widget.guildQueueKind == "rolePlayer" then card = widget end
    end
    card.invite.scripts.OnEnter(card.invite)
    c:receive("First-TestRealm", { kind = "X", revision = 2, sentAt = c.now })
    assert(not card.shown and card.invite.memberName == nil and not c.tooltip.shown)
    card.invite.scripts.OnClick(card.invite)
    equal(#c.invites, 0)
    local count = #widgets
    c:receive("Second-TestRealm", packet(1, 4, nil, c.now, c.now))
    equal(#widgets, count)
    assert(card.shown)
    equal(card.invite.memberName, "Second-TestRealm")
    card.invite.scripts.OnClick(card.invite)
    equal(c.invites[1], "Second-TestRealm")
end)
test("Role List Default and Quests retain independent scrolling and the last default subview", function()
    local c = client()
    for i = 1, 30 do c:receive("P" .. i .. "-TestRealm", packet(1, 4, nil, c.now, c.now)) end
    local widgets, views, tabs = roleListUI(c)
    local scroll
    for _, widget in ipairs(widgets) do
        if widget.guildQueueKind == "outputScroll" then scroll = widget end
    end
    scroll.scripts.OnMouseWheel(scroll, -3)
    local rolePosition = scroll:GetVerticalScroll()
    assert(rolePosition > 0)
    views.default.scripts.OnClick(views.default)
    tabs.queue.scripts.OnClick(tabs.queue)
    scroll.scripts.OnMouseWheel(scroll, -2)
    local defaultPosition = scroll:GetVerticalScroll()
    assert(defaultPosition > 0)
    views.roles.scripts.OnClick(views.roles)
    equal(scroll:GetVerticalScroll(), rolePosition)
    tabs.questing.scripts.OnClick(tabs.questing)
    assert(not views.roles.shown and not views.default.shown)
    tabs.dungeons.scripts.OnClick(tabs.dungeons)
    assert(views.roles.selected)
    equal(scroll:GetVerticalScroll(), rolePosition)
    views.default.scripts.OnClick(views.default)
    assert(tabs.queue.selected)
    equal(scroll:GetVerticalScroll(), defaultPosition)
    equal(#c.invites, 0)
end)
test("Role List uses party-wide shared dungeons role-specific clicks and already-in-party badges", function()
    local c = client()
    c.ns.prefs.roles = 2
    c.ns.SetQueued(true)
    c:advance(1)
    c:receive("Tank-TestRealm", packet(1, 1, nil, c.now, c.now))
    c:receive("Flexible-TestRealm", packet(1, 7, nil, c.now, c.now))
    c.homeGroup, c.partyMembers = true, { "Tank-TestRealm" }
    local widgets = roleListUI(c)
    local tank, selfCard, recruit
    for _, widget in ipairs(widgets) do
        if widget.guildQueueKind == "rolePlayer" and widget.shown then
            if widget.player.name == "Tank-TestRealm" then tank = widget end
            if widget.player.name == c.ns.playerName then selfCard = widget end
            if widget.player.name == "Flexible-TestRealm" then
                assert(recruit == nil) -- Only Damage fits; no misleading Tank or Healer copies.
                recruit = widget
            end
        end
    end
    assert(tank and selfCard and recruit)
    equal(tank.invite.text, "In party") assert(not tank.invite.enabled)
    equal(selfCard.invite.text, "You") assert(not selfCard.invite.enabled)
    equal(recruit.invite.text, "Invite as Damage")
    equal(recruit.invite.requestedRole, 4)
    recruit.invite.scripts.OnEnter(recruit.invite)
    assert(c.tooltip.text:find("Confirm the role", 1, true))
    recruit.invite.scripts.OnClick(recruit.invite)
    equal(#c.invites, 1)
    c:advance(3)
    local found = false
    for _, message in ipairs(c.sent) do
        local p = c.ns.Protocol.Decode(message.text)
        if p.kind == "R" then found = true equal(p.role, 4) end
    end
    assert(found)
end)
test("Role List explains unavailable party preferences instead of showing misleading candidates", function()
    local c = client()
    c:receive("Recruit-TestRealm", packet(1, 2, nil, c.now, c.now))
    c.homeGroup, c.partyMembers = true, { "Unknown-TestRealm" }
    local widgets = roleListUI(c)
    local toolbar
    for _, widget in ipairs(widgets) do
        if widget.guildQueueKind == "roleToolbar" then toolbar = widget end
        if widget.guildQueueKind == "rolePlayer" then assert(not widget.shown) end
    end
    assert(toolbar.hint.text:find("Every party member", 1, true))
    equal(#c.invites, 0)
end)
test("dungeon labels show ranges and filling guidance never tells users to withdraw early", function()
    local c = client()
    local widgets = openUI(c)
    local dungeons, guidance = 0, false
    for _, widget in ipairs(widgets) do
        if widget.guildQueueKind == "dungeon" then
            dungeons = dungeons + 1
            equal(widget.caption.text, c.ns.DungeonName(c.ns.DUNGEON_BY_ID[widget.id]))
        end
        if type(widget.text) == "string" then
            if widget.text:find("Stay queued while filling", 1, true) then guidance = true end
            assert(not widget.text:find("Leave the dungeon queue once your party is formed", 1, true))
        end
    end
    equal(dungeons, #c.ns.DUNGEONS)
    assert(guidance)
end)

test("formation receipt updates group and role-list buttons immediately and expiry restores them", function()
    local clients = formationClients(3)
    local a, b = clients[1], clients[2]
    local widgets, views = roleListUI(b)
    views.default.scripts.OnClick(views.default)
    local action, card
    for _, widget in ipairs(widgets) do
        if widget.guildQueueKind == "party" and widget.shown then action = widget end
        if widget.guildQueueKind == "group" and widget.shown and widget.createParty then card = widget end
    end
    assert(action and card and action.enabled)
    action.scripts.OnEnter(action)
    relayFormations(clients)
    assert(a.ns.CreateParty(a.ns.groups[1]))
    assert(not action.enabled)
    equal(action.text, "Forming...")
    assert(card.note.text:find("Alpha", 1, true))
    assert(b.tooltip.text:find("10s", 1, true))
    action.scripts.OnClick(action)
    equal(#b.invites, 0)
    views.roles.scripts.OnClick(views.roles)
    local recruit
    for _, widget in ipairs(widgets) do
        if widget.guildQueueKind == "rolePlayer" and widget.shown and widget.player.name == "Charlie-TestRealm" then recruit = widget end
    end
    assert(recruit and not recruit.invite.enabled)
    equal(recruit.invite.text, "Forming...")
    recruit.invite.scripts.OnEnter(recruit.invite)
    assert(b.tooltip.text:find("Alpha", 1, true))
    advanceFormations(clients, 10)
    assert(recruit.invite.enabled)
    equal(recruit.invite.text, "Invite as Damage")
    views.default.scripts.OnClick(views.default)
    assert(action.enabled)
    equal(action.text, "Create party")
    equal(#b.invites, 0)
end)
test("same-zone invite controls respect a matchup lock and recover after an authenticated release", function()
    local clients = formationClients(3)
    local a, b = clients[1], clients[2]
    local widgets = openUI(b)
    local quests
    for _, widget in ipairs(widgets) do if widget.mainTab and widget.mode == "questing" then quests = widget end end
    quests.scripts.OnClick(quests)
    local invite
    for _, widget in ipairs(widgets) do
        if widget.guildQueueKind == "questMember" and widget.member.name == "Charlie-TestRealm" then invite = widget.invite end
    end
    assert(invite and invite.enabled)
    relayFormations(clients)
    a.env.C_PartyInfo.InviteUnit = function() error("Failed native submission") end
    assert(not a.ns.CreateParty(a.ns.groups[1]))
    assert(not invite.enabled)
    equal(invite.text, "Forming...")
    invite.scripts.OnEnter(invite)
    assert(b.tooltip.text:find("Alpha", 1, true))
    advanceFormations(clients, 1)
    assert(invite.enabled)
    equal(invite.text, "Invite")
    equal(#b.invites, 0)
end)

test("Role List text fits its cards toolbar and native view selectors", function()
    local c = client()
    c.ns.SetQueued(true)
    c:advance(1)
    c:receive("Friend-TestRealm", packet(1, 7, nil, c.now, c.now))
    local widgets, views = roleListUI(c)
    local function visible(control)
        while control do
            if not control.shown then return false end
            control = control.parent
        end
        return true
    end
    assert(views.default.point[2] + views.default:GetWidth() < views.roles.point[2])
    assert(views.roles.point[2] + views.roles:GetWidth() <= 1042)
    for _, text in ipairs(widgets) do
        if text.frameType == "FontString" and visible(text) and not text.parent.mainTab then
            equal(text.point[1], "TOPLEFT")
            assert(text.point[2] + text:GetWidth() <= text.parent:GetWidth(), text.text)
            assert(-text.point[3] + text:GetHeight() <= text.parent:GetHeight(), text.text)
        end
    end
    local count = #widgets
    for _ = 1, 20 do c.ns.RefreshUI() end
    equal(#widgets, count)
end)

test("UI title displays the running addon version from metadata rather than a hardcoded release", function()
    local toc = assert(io.open("GuildQueue/GuildQueue.toc", "r"))
    local installed = toc:read("*a"):match("## Version:%s*([^\r\n]+)")
    toc:close()
    assert(installed)
    for _, version in ipairs({ installed, "9.8.7" }) do
        local c, calls = client(), 0
        c.env.C_AddOns = { GetAddOnMetadata = function(name, field)
            equal(name, "GuildQueue") equal(field, "Version")
            calls = calls + 1
            return version
        end }
        local title
        for _, control in ipairs(openUI(c)) do
            if control.text == "Guild Queue (v" .. version .. ")" then title = control end
        end
        assert(title)
        equal(calls, 1)
        equal(title.template, "GameFontNormalHuge")
        assert(title:GetWidth() > 0 and title:GetHeight() > 0)
        c.ns.RefreshUI()
        equal(calls, 1)
    end
end)
test("UI title reports an unknown version when the metadata API or version is unavailable", function()
    for _, metadata in ipairs({ false,
        { GetAddOnMetadata = function() return nil end },
        { GetAddOnMetadata = function() return "" end } }) do
        local c, found = client(), false
        c.env.C_AddOns = metadata or nil
        for _, control in ipairs(openUI(c)) do
            if control.text == "Guild Queue (vunknown)" then found = true end
        end
        assert(found)
    end
end)

test("UI header displays and refreshes the recent online-addon member count", function()
    local c = client()
    local widgets = openUI(c)
    local onlineCounter
    for _, control in ipairs(widgets) do
        if control.guildQueueKind == "counter" and control.counterName == "online" then
            onlineCounter = control
        end
    end
    assert(onlineCounter)
    equal(onlineCounter.text, "1") -- This character is included when guild identity is ready.
    c:receive("Friend-TestRealm", { kind = "P" })
    equal(onlineCounter.text, "2")
    c:advance(c.ns.TIMEOUT)
    equal(onlineCounter.text, "1")
end)
test("Quests prominently labels same-zone guildmates without overlapping controls or cards", function()
    local c = client({ rosterInfo = { ["Friend-TestRealm"] = { area = "Elwynn Forest" } } })
    local widgets, tabs, heading, zone, consent, hint = openUI(c), {}
    for _, control in ipairs(widgets) do
        if control.mainTab then tabs[control.mode] = control end
        if control.text == "Guild members in your zone" then heading = control end
        if control.guildQueueKind == "questSharing" then consent = control end
    end
    assert(heading and consent)
    equal(heading.template, "GameFontNormalLarge")
    tabs.questing.scripts.OnClick(tabs.questing)
    for _, control in ipairs(widgets) do
        if control.text == "Current zone: Elwynn Forest" then zone = control end
        if control.parent == heading.parent and control.text
            and control.text:find("Guild roster zones", 1, true) == 1 then hint = control end
    end
    assert(zone and hint and heading.parent.shown)
    local function bottom(control) return -control.point[3] + control:GetHeight() end
    assert(bottom(heading) <= -zone.point[3])
    assert(bottom(zone) <= -consent.point[3])
    assert(bottom(consent) <= -hint.point[3])
    assert(bottom(hint) <= heading.parent:GetHeight())
    local foundCard = false
    for _, control in ipairs(widgets) do
        if control.guildQueueKind == "questMember" and control.shown then
            foundCard = true
            assert(-control.point[3] > heading.parent:GetHeight())
        end
    end
    assert(foundCard)
    c.zoneID, c.zoneName = 52, "Westfall"
    c:fire("ZONE_CHANGED_NEW_AREA")
    c:advance(1)
    c.ns.RefreshUI()
    equal(zone.text, "Current zone: Westfall")
    equal(heading.text, "Guild members in your zone")
    tabs.dungeons.scripts.OnClick(tabs.dungeons)
    assert(not heading.parent.shown)
    assert(not c.ns.prefs.shareQuests and not c.ns.queued)
    equal(#c.invites, 0)
end)
test("Questing tab shows unknown versus zero shared quests and expands completion details", function()
    local c = client({ quests = { { questID = 10, title = "A shared quest" } },
        rosterInfo = { ["Friend-TestRealm"] = { area = "Elwynn Forest" } } })
    local widgets = openUI(c)
    local tabs, consent = {}
    for _, control in ipairs(widgets) do
        if control.guildQueueKind == "tab" then tabs[control.mode] = control end
        if control.guildQueueKind == "questSharing" then consent = control end
    end
    assert(tabs.questing and consent and not consent:GetChecked())
    tabs.questing.scripts.OnClick(tabs.questing)
    local card
    for _, control in ipairs(widgets) do
        if control.guildQueueKind == "questMember" then card = control end
    end
    assert(card)
    equal(card.summary.text, "Quest data unavailable")
    receiveQuests(c, "Friend-TestRealm", {})
    equal(card.summary.text, "0 shared active quests")
    receiveQuests(c, "Friend-TestRealm", { [10] = true }, 2)
    equal(card.summary.text, "1 shared active quest")
    card.expand.scripts.OnClick(card.expand)
    equal(card.lines[1].title.text, "A shared quest")
    assert(card.lines[1].status.text:find("You: In progress", 1, true))
    assert(card.lines[1].status.text:find("Guildmate: Ready to turn in", 1, true))
    local count = #widgets
    c.ns.RefreshUI()
    equal(#widgets, count)
    consent:SetChecked(true)
    consent.scripts.OnClick(consent)
    assert(c.ns.prefs.shareQuests)
    tabs.groups.scripts.OnClick(tabs.groups)
    assert(not card.shown)
    equal(#c.invites, 0)
end)
test("same-zone cards have independent click-only Invite buttons and the updated sharing caption", function()
    local c = client({ roster = { "Self-TestRealm", "Friend-TestRealm", "Other-TestRealm" },
        rosterInfo = { ["Friend-TestRealm"] = { area = "Elwynn Forest" },
            ["Other-TestRealm"] = { area = "Elwynn Forest" } } })
    local widgets, tabs, cards, consent = openUI(c), {}, {}
    for _, control in ipairs(widgets) do
        if control.mainTab then tabs[control.mode] = control end
        if control.guildQueueKind == "questSharing" then consent = control end
    end
    equal(consent.caption.text, "Share my active quests with my guild")
    tabs.questing.scripts.OnClick(tabs.questing)
    for _, control in ipairs(widgets) do
        if control.guildQueueKind == "questMember" and control.shown then cards[#cards + 1] = control end
    end
    equal(#cards, 2)
    c:advance(2)
    equal(#c.invites, 0)
    for index, card in ipairs(cards) do
        equal(card.invite.text, "Invite")
        assert(card.invite.enabled and card.invite.motionWhileDisabled)
        assert(card.level.point[2] + card.level:GetWidth() <= card.invite.point[2])
        assert(card.name.point[2] + card.name:GetWidth() <= card.level.point[2])
        assert(-card.invite.point[3] + card.invite:GetHeight() <= -card.expand.point[3])
        card.invite.scripts.OnClick(card.invite)
        equal(#c.invites, index)
        equal(c.invites[index], card.member.name)
        assert(not card.invite.enabled)
    end
    assert(not c.ns.queued and not c.ns.prefs.shareQuests)
    local count = #widgets
    c.ns.RefreshUI()
    equal(#widgets, count)
end)
test("same-zone Invite buttons explain disabled states and recheck permission at click time", function()
    local c = client({ rosterInfo = { ["Friend-TestRealm"] = { area = "Elwynn Forest" } } })
    local widgets, tab, card = openUI(c)
    for _, control in ipairs(widgets) do
        if control.mainTab and control.mode == "questing" then tab = control end
    end
    tab.scripts.OnClick(tab)
    for _, control in ipairs(widgets) do
        if control.guildQueueKind == "questMember" and control.shown then card = control end
    end
    assert(card.invite.enabled)
    c.canInvite = false -- No refresh/event between render and click.
    card.invite.scripts.OnClick(card.invite)
    equal(#c.invites, 0)
    assert(not card.invite.enabled)
    card.invite.scripts.OnEnter(card.invite)
    assert(c.tooltip.shown and c.tooltip.text:find("permission", 1, true))
    c.canInvite, c.combat = true, true
    c:fire("PLAYER_REGEN_DISABLED")
    assert(not card.invite.enabled)
    c.combat = false
    c:fire("PLAYER_REGEN_ENABLED")
    assert(card.invite.enabled)
    -- Reuse a pooled card for a different guildmate; never retain the old invite target.
    c.roster = { "Self-TestRealm", "Other-TestRealm" }
    c.rosterInfo["Other-TestRealm"] = { area = "Elwynn Forest" }
    c:fire("GUILD_ROSTER_UPDATE")
    equal(card.invite.memberName, "Other-TestRealm")
    card.invite.scripts.OnClick(card.invite)
    equal(c.invites[1], "Other-TestRealm")
end)
test("Questing tab retains independent scrolling and keeps expanded text within cards", function()
    local quests, peer = {}, {}
    for id = 1, 15 do
        quests[#quests + 1] = { questID = id, title = "Shared quest " .. id }
        peer[id] = false
    end
    local c = client({ quests = quests })
    receiveQuests(c, "Friend-TestRealm", peer)
    local widgets, tabs, scroll, card = openUI(c), {}
    for _, control in ipairs(widgets) do
        if control.guildQueueKind == "tab" then tabs[control.mode] = control end
        if control.guildQueueKind == "outputScroll" then scroll = control end
    end
    tabs.questing.scripts.OnClick(tabs.questing)
    for _, control in ipairs(widgets) do
        if control.guildQueueKind == "questMember" then card = control end
    end
    card.expand.scripts.OnClick(card.expand)
    scroll.scripts.OnMouseWheel(scroll, -4)
    local position = scroll:GetVerticalScroll()
    assert(position > 0)
    tabs.queue.scripts.OnClick(tabs.queue)
    equal(scroll:GetVerticalScroll(), 0)
    tabs.questing.scripts.OnClick(tabs.questing)
    equal(scroll:GetVerticalScroll(), position)
    for _, line in ipairs(card.lines) do
        assert(-line.status.point[3] + line.status:GetHeight() <= card:GetHeight())
    end
end)
test("UI opens and its multi-select controls drive the real queue", function()
    local c = client()
    local widgets = openUI(c)
    local checks, join, queueTab = {}
    for _, control in ipairs(widgets) do
        if control.guildQueueKind == "role" or control.guildQueueKind == "dungeon" then
            checks[#checks + 1] = control
        end
        if control.guildQueueKind == "queue" then join = control end
        if control.guildQueueKind == "tab" and control.mode == "queue" then queueTab = control end
    end
    equal(#checks, 3 + #c.ns.DUNGEONS)
    local function toggle(control, checked)
        control:SetChecked(checked)
        control.scripts.OnClick(control)
    end
    toggle(checks[1], true)
    toggle(checks[2], true)
    equal(c.ns.prefs.roles, 7)
    toggle(checks[3], false)
    equal(c.ns.prefs.roles, 3)
    toggle(checks[5], true)
    assert(c.ns.prefs.dungeons[1] and c.ns.prefs.dungeons[2])
    assert(join and join.enabled)
    join.scripts.OnClick(join)
    c:advance(1)
    assert(c.ns.state.records["Self-TestRealm"])
    equal(join.text, "Leave queue")
    queueTab.scripts.OnClick(queueTab)
    join.scripts.OnClick(join)
    assert(not c.ns.queued)
end)

test("dungeon controls omit Clear while Leave queue preserves selections and Select all still works", function()
    local c = client({ saved = { roles = 2, dungeons = { [1] = true, [2] = true } } })
    local widgets, join, selectAll = openUI(c)
    for _, control in ipairs(widgets) do
        assert(control.guildQueueKind ~= "clear" and control.text ~= "Clear")
        if control.guildQueueKind == "queue" then join = control end
        if control.guildQueueKind == "selectAll" then selectAll = control end
    end
    assert(join and selectAll)
    equal(selectAll:GetWidth(), join:GetWidth())
    local roles, dungeons = c.ns.prefs.roles, c.ns.Protocol.DungeonList(c.ns.prefs.dungeons)
    join.scripts.OnClick(join)
    c:advance(1)
    assert(c.ns.queued)
    equal(join.text, "Leave queue")
    join.scripts.OnClick(join)
    assert(not c.ns.queued)
    equal(c.ns.prefs.roles, roles)
    equal(c.ns.Protocol.DungeonList(c.ns.prefs.dungeons), dungeons)
    selectAll.scripts.OnClick(selectAll)
    for _, dungeon in ipairs(c.ns.DUNGEONS) do assert(c.ns.prefs.dungeons[dungeon.id]) end
    assert(not c.ns.queued)
    equal(#c.invites, 0)
end)

test("Create party button is hoverable when disabled and tracks party changes", function()
    local c = client()
    suggestedGroup(c)
    local widgets = openUI(c)
    local control
    for _, candidate in ipairs(widgets) do
        if candidate.guildQueueKind == "party" then control = candidate end
    end
    assert(control and control.enabled and control.shown)
    assert(control.motionWhileDisabled)
    equal(#c.invites, 0)
    c.homeGroup, c.partyMembers = true, { "Outsider-TestRealm" }
    c:fire("GROUP_ROSTER_UPDATE")
    assert(not control.enabled)
    equal(control.text, "Create party")
    control.scripts.OnEnter(control)
    assert(c.tooltip.shown)
    equal(c.tooltip.text, "Your party includes a player outside your current suggested group.")
    -- Leaving the party updates both the button and an already-visible tooltip.
    c.homeGroup = false
    c:fire("GROUP_ROSTER_UPDATE")
    assert(control.enabled)
    assert(c.tooltip.text:find("Invite the other matched", 1, true))
    c.combat = true
    c:fire("PLAYER_REGEN_DISABLED")
    assert(not control.enabled)
    assert(c.tooltip.text:find("during combat", 1, true))
    c.combat = false
    c:fire("PLAYER_REGEN_ENABLED")
    assert(control.enabled)
    control.scripts.OnClick(control)
    equal(#c.invites, 4)
    assert(not control.enabled)
    c:advance(6)
    assert(control.enabled)
    c:receive("Friend-TestRealm", { kind = "X", revision = 2, sentAt = c.now })
    assert(control.shown and control.enabled) -- Four-player partial match can still start a party.
    for _, name in ipairs({ "D1-TestRealm", "D2-TestRealm", "D3-TestRealm" }) do
        c:receive(name, { kind = "X", revision = 2, sentAt = c.now })
    end
    assert(not control.shown and not c.tooltip.shown)
end)
test("suggested-party action changes to Invite Others only for an eligible existing party", function()
    local c = client()
    suggestedGroup(c)
    local widgets = openUI(c)
    local control
    for _, widget in ipairs(widgets) do if widget.guildQueueKind == "party" then control = widget end end
    equal(control.text, "Create party")
    c.homeGroup, c.partyMembers = true, { "Friend-TestRealm" }
    c:fire("GROUP_ROSTER_UPDATE")
    assert(control.enabled)
    equal(control.text, "Invite Others")
    control.scripts.OnEnter(control)
    equal(c.tooltip.title, "Invite Others")
    assert(c.tooltip.text:find("not already in your party", 1, true))
    equal(#c.invites, 0)
    control.scripts.OnClick(control)
    equal(#c.invites, 3)
    for _, name in ipairs(c.invites) do assert(name ~= "Friend-TestRealm" and name ~= c.ns.playerName) end
    assert(not control.enabled)
    equal(control.text, "Invite Others")
    c:advance(6)
    assert(control.enabled)
    c.homeGroup = false
    c:fire("GROUP_ROSTER_UPDATE")
    assert(control.enabled)
    equal(control.text, "Create party")
    equal(c.tooltip.title, "Create party")
end)
test("Invite Others button tracks permission combat completed party and unrelated-party changes", function()
    local c = client()
    suggestedGroup(c)
    c.homeGroup, c.partyMembers = true, { "Friend-TestRealm" }
    local widgets = openUI(c)
    local control
    for _, widget in ipairs(widgets) do if widget.guildQueueKind == "party" then control = widget end end
    control.scripts.OnEnter(control)
    for _, condition in ipairs({ { "canInvite", false }, { "combat", true } }) do
        c[condition[1]] = condition[2]
        c:fire("GROUP_ROSTER_UPDATE")
        assert(not control.enabled)
        equal(control.text, "Invite Others")
        c[condition[1]] = nil
    end
    c.partyMembers = { "Friend-TestRealm", "D1-TestRealm", "D2-TestRealm", "D3-TestRealm" }
    c:fire("GROUP_ROSTER_UPDATE")
    assert(not control.enabled)
    equal(control.text, "Invite Others")
    assert(c.tooltip.text:find("already in your party", 1, true))
    c.partyMembers = { "Friend-TestRealm", "Outsider-TestRealm" }
    c:fire("GROUP_ROSTER_UPDATE")
    assert(not control.enabled)
    equal(control.text, "Create party")
    assert(c.tooltip.text:find("outside", 1, true))
    equal(#c.invites, 0)
end)
test("Invite Others does not trust eligibility rendered before a party change", function()
    local c = client()
    suggestedGroup(c)
    c.homeGroup, c.partyMembers = true, { "Friend-TestRealm" }
    local widgets = openUI(c)
    local control
    for _, widget in ipairs(widgets) do if widget.guildQueueKind == "party" then control = widget end end
    assert(control.enabled and control.text == "Invite Others")
    c.partyMembers[2] = "Outsider-TestRealm" -- No UI refresh before clicking.
    control.scripts.OnClick(control)
    equal(#c.invites, 0)
    assert(not control.enabled)
    equal(control.text, "Create party")
end)

test("Create party controls hide on the all-queued tab without issuing invites", function()
    local c = client()
    suggestedGroup(c)
    local widgets = openUI(c)
    local control, queueTab
    for _, candidate in ipairs(widgets) do
        if candidate.guildQueueKind == "party" then control = candidate end
        if candidate.guildQueueKind == "tab" and candidate.mode == "queue" then queueTab = candidate end
    end
    assert(control and queueTab)
    control.scripts.OnEnter(control)
    queueTab.scripts.OnClick(queueTab)
    assert(not control.shown and not c.tooltip.shown)
    equal(#c.invites, 0)
end)

test("Join queue stays usable without roster data and explains disabled states on hover", function()
    local c = client({ roster = {}, rosterAPIsMissing = true })
    local widgets = openUI(c)
    local control
    for _, candidate in ipairs(widgets) do
        if candidate.guildQueueKind == "queue" then control = candidate end
    end
    assert(control and control.enabled and control.motionWhileDisabled)
    c.ns.prefs.dungeons = {}
    c.ns.PreferencesChanged()
    assert(not control.enabled)
    control.scripts.OnEnter(control)
    equal(c.tooltip.text, "Select at least one role and one dungeon.")
    c.ns.prefs.dungeons[1] = true
    c.ns.PreferencesChanged()
    assert(control.enabled)
    assert(c.tooltip.text:find("Join the guild queue", 1, true))
    c.guildInfoUnavailable = true
    c:advance(1)
    assert(not control.enabled)
    assert(c.tooltip.text:find("Waiting for guild information", 1, true))
    c.guildInfoUnavailable = false
    c:advance(1)
    assert(control.enabled)
    control.scripts.OnClick(control)
    c:advance(1)
    equal(control.text, "Leave queue")
    assert(control.enabled and c.ns.state.records[c.ns.playerName])
end)

test("UI uses native WoW borders, buttons, checkboxes and close-button artwork", function()
    local c = client()
    local widgets = openUI(c)
    local surfaces, buttons, checks, main, close = 0, 0, 0
    for _, control in ipairs(widgets) do
        if control.frameName == "GuildQueueFrame" then main = control end
        if control.guildQueueKind == "close" then close = control end
        if control.template == "UIPanelButtonTemplate" then buttons = buttons + 1 end
        if control.template == "UICheckButtonTemplate" then checks = checks + 1 end
        if control.backdrop then
            surfaces = surfaces + 1
            equal(control.backdrop.bgFile, "Interface\\DialogFrame\\UI-DialogBox-Background")
            equal(control.backdropColor[4], 1)
            equal(control.borderColor[4], 1)
            assert(control.opaqueFill and control.opaqueFill.allPoints == control)
            equal(control.opaqueFill.color[4], 1)
        end
    end
    assert(surfaces > 3 and main and buttons >= 5)
    equal(checks, 4 + #c.ns.DUNGEONS) -- Roles, dungeons, and opt-in quest sharing.
    equal(close.template, "UIPanelCloseButton")
    equal(close.text, "") -- Native X texture, not a second text-based X.
    equal(main.backdrop.edgeFile, "Interface\\DialogFrame\\UI-DialogBox-Border")
    equal(main:GetWidth(), 1060)
    equal(main:GetHeight(), 740)
end)
test("a healer and damage pair render open slots and can create a party with one click", function()
    local c = client({ allowedRoles = 6 })
    local group = suggestedPartial(c, 2)
    local widgets = openUI(c)
    local card
    for _, widget in ipairs(widgets) do
        if widget.guildQueueKind == "group" and widget.group == group then card = widget end
    end
    assert(card and card.createParty.enabled and card.createParty.shown)
    equal(card.matched.text, "2 / 5 matched")
    equal(card.kicker.text, "YOUR PARTIAL MATCH")
    local open = 0
    for slot, tile in ipairs(card.tiles) do
        assert(tile.shown)
        if not group.slots[slot] then
            open = open + 1
            assert(tile.player == nil and tile.roleIcon.desaturated)
            equal(tile.name.text, "Needed")
            for _, role in ipairs({ 1, 2, 4 }) do assert(not tile.roleIcons[role].shown) end
        else
            equal(tile.player.name, group.slots[slot].name)
            assert(not tile.roleIcon.desaturated)
        end
    end
    equal(open, 3)
    card.tiles[1].scripts.OnEnter(card.tiles[1])
    equal(c.tooltip.title, "Tank needed")
    equal(#c.invites, 0)
    card.createParty.scripts.OnClick(card.createParty)
    equal(#c.invites, 1)
    equal(c.invites[1], "PartialD1-TestRealm")
end)
test("pooled group tiles reset occupied and needed states as a match shrinks and fills", function()
    local c = client()
    suggestedGroup(c)
    local widgets = openUI(c)
    local card
    for _, widget in ipairs(widgets) do
        if widget.guildQueueKind == "group" and widget.shown then card = widget end
    end
    local count = #widgets
    c:receive("Friend-TestRealm", { kind = "X", revision = 2, sentAt = c.now })
    equal(#widgets, count)
    equal(card.matched.text, "4 / 5 matched")
    assert(card.createParty.shown and card.createParty.enabled)
    equal(card.tiles[2].name.text, "Needed")
    assert(card.tiles[2].player == nil and card.tiles[2].roleIcon.desaturated)
    for _, role in ipairs({ 1, 2, 4 }) do assert(not card.tiles[2].roleIcons[role].shown) end
    c:receive("Friend-TestRealm", packet(3, 2, nil, c.now, c.now))
    equal(#widgets, count)
    equal(card.matched.text, "5 / 5 matched")
    equal(card.tiles[2].player.name, "Friend-TestRealm")
    assert(not card.tiles[2].roleIcon.desaturated and card.tiles[2].roleIcons[2].shown)
    card.tiles[2].scripts.OnEnter(card.tiles[2])
    assert(c.tooltip.title:find("Friend", 1, true))
    equal(#c.invites, 0)
end)
test("partial party actions hide on All queued and return without sending invitations", function()
    local c = client()
    suggestedPartial(c, 2)
    local widgets = openUI(c)
    local party, tabs = nil, {}
    for _, widget in ipairs(widgets) do
        if widget.guildQueueKind == "party" and widget.shown then party = widget end
        if widget.guildQueueKind == "tab" then tabs[widget.mode] = widget end
    end
    assert(party and party.enabled)
    tabs.queue.scripts.OnClick(tabs.queue)
    assert(not party.shown and party.group == nil)
    tabs.groups.scripts.OnClick(tabs.groups)
    assert(party.shown and party.enabled and #party.group.members == 2)
    equal(#c.invites, 0)
end)
test("other players partial groups are visible but never offer a Create party action", function()
    local c = client()
    c:receive("Healer-TestRealm", packet(1, 2, nil, c.now, c.now))
    c:receive("Damage-TestRealm", packet(1, 4, nil, c.now, c.now))
    local widgets = openUI(c)
    local card
    for _, widget in ipairs(widgets) do
        if widget.guildQueueKind == "group" and widget.shown then card = widget end
    end
    assert(card and card.createParty == nil)
    equal(card.matched.text, "2 / 5 matched")
    assert(not c.ns.CreateParty(card.group))
    equal(#c.invites, 0)
end)

test("own suggested group renders five assigned member tiles and a click-only action", function()
    local c = client()
    local group = suggestedGroup(c)
    local widgets = openUI(c)
    local card, tiles = nil, {}
    for _, control in ipairs(widgets) do
        if control.guildQueueKind == "group" and control.group == group then card = control end
        if control.guildQueueKind == "member" then tiles[#tiles + 1] = control end
    end
    assert(card and card.createParty and card.createParty.enabled)
    equal(#tiles, 5)
    local seen = {}
    for slot, tile in ipairs(card.tiles) do
        equal(tile.player, group.slots[slot])
        equal(tile.role, c.ns.SLOTS[slot])
        assert(not seen[tile.player.name])
        seen[tile.player.name] = true
    end
    card.tiles[1].scripts.OnEnter(card.tiles[1])
    assert(c.tooltip.title:find(group.slots[1].name, 1, true))
    assert(c.tooltip.text:find("Dungeons:", 1, true))
    equal(#c.invites, 0)
end)
test("unmatched and all-queued cards reuse widgets across repeated refreshes", function()
    local c = client()
    c.ns.SetQueued(true)
    c:advance(1)
    c:receive("Friend-TestRealm", packet(1, 4, { [2] = true }, c.now, c.now))
    local widgets = openUI(c)
    local cards, queueTab = {}, nil
    for _, control in ipairs(widgets) do
        if control.guildQueueKind == "individual" and control.shown then cards[#cards + 1] = control end
        if control.guildQueueKind == "tab" and control.mode == "queue" then queueTab = control end
    end
    equal(#cards, 2)
    local count = #widgets
    for _ = 1, 20 do c.ns.RefreshUI() end
    equal(#widgets, count)
    queueTab.scripts.OnClick(queueTab)
    local afterSwitch = #widgets
    for _ = 1, 20 do c.ns.RefreshUI() end
    equal(#widgets, afterSwitch)
    equal(#c.invites, 0)
end)
test("custom queue scrolling clamps to content and preserves each tab's position", function()
    local c = client()
    for i = 1, 30 do
        c:receive("Player" .. i .. "-TestRealm", packet(1, 4, nil, c.now, c.now))
    end
    local widgets = openUI(c)
    local scroll, queueTab, groupTab
    for _, control in ipairs(widgets) do
        if control.guildQueueKind == "outputScroll" then scroll = control end
        if control.guildQueueKind == "tab" and control.mode == "queue" then queueTab = control end
        if control.guildQueueKind == "tab" and control.mode == "groups" then groupTab = control end
    end
    assert(scroll and scroll.track.shown)
    scroll.scripts.OnMouseWheel(scroll, -4)
    local groupPosition = scroll:GetVerticalScroll()
    assert(groupPosition > 0)
    c.ns.RefreshUI()
    equal(scroll:GetVerticalScroll(), groupPosition)
    queueTab.scripts.OnClick(queueTab)
    equal(scroll:GetVerticalScroll(), 0)
    scroll.scripts.OnMouseWheel(scroll, -1000)
    local maximum = scroll.content:GetHeight() - scroll:GetHeight()
    equal(scroll:GetVerticalScroll(), maximum)
    groupTab.scripts.OnClick(groupTab)
    equal(scroll:GetVerticalScroll(), groupPosition)
    scroll.scripts.OnMouseWheel(scroll, 1000)
    equal(scroll:GetVerticalScroll(), 0)
end)
test("card labels have explicit bounds within their visible parent panels", function()
    local c = client()
    suggestedGroup(c)
    local widgets = openUI(c)
    local function visible(control)
        while control do
            if not control.shown then return false end
            control = control.parent
        end
        return true
    end
    for _, control in ipairs(widgets) do
        if control.frameType == "FontString" and visible(control) then
            local point, parent = control.point, control.parent
            assert(point and parent)
            assert(control:GetWidth() > 0 and control:GetHeight() > 0)
            if parent.template == "PanelTabButtonTemplate" then
                equal(point[1], "CENTER")
                assert(control == parent.Text)
                assert(control:GetWidth() <= parent:GetWidth())
                assert(control:GetHeight() + 2 * math.abs(point[5]) <= parent:GetHeight())
            else
                equal(point[1], "TOPLEFT")
                assert(point[2] + control:GetWidth() <= parent:GetWidth(), control.text)
                assert(-point[3] + control:GetHeight() <= parent:GetHeight(), control.text)
            end
        end
    end
end)

test("role selectors use native tank, healer and damage icons and remain multi-select", function()
    local c = client()
    local widgets = openUI(c)
    local checks = {}
    local atlases = { [1] = "UI-LFG-RoleIcon-Tank", [2] = "UI-LFG-RoleIcon-Healer",
        [4] = "UI-LFG-RoleIcon-DPS" }
    for _, control in ipairs(widgets) do
        if control.guildQueueKind == "role" then
            checks[control.role] = control
            equal(control.roleIcon.atlas, atlases[control.role])
            equal(control.roleIcon:GetWidth(), 48)
            equal(control:GetCheckedTexture():GetWidth(), 24)
            equal(control:GetCheckedTexture().layer, "OVERLAY")
        end
    end
    for _, role in ipairs({ 1, 2 }) do
        checks[role]:SetChecked(true)
        checks[role].scripts.OnClick(checks[role])
    end
    equal(c.ns.prefs.roles, 7)
    c.ns.RefreshUI()
    for _, role in ipairs({ 1, 2, 4 }) do
        assert(checks[role]:GetChecked())
        assert(checks[role].roleIcon.shown)
    end
    checks[2].scripts.OnEnter(checks[2])
    equal(c.tooltip.title, "Healer")
    checks[2]:SetChecked(false)
    checks[2].scripts.OnClick(checks[2])
    equal(c.ns.prefs.roles, 5)
    equal(#c.invites, 0)
end)
test("role selectors follow class capabilities and unavailable roles explain why on hover", function()
    for _, allowed in ipairs({ 4, 5, 6, 7 }) do
        local c = client({ allowedRoles = allowed })
        local widgets = openUI(c)
        for _, control in ipairs(widgets) do
            if control.guildQueueKind == "role" then
                local supported = c.ns.HasRole(allowed, control.role)
                equal(control.enabled, supported)
                equal(control.roleIcon.desaturated, not supported)
                if not supported then
                    assert(control.motionWhileDisabled)
                    control.scripts.OnEnter(control)
                    assert(c.tooltip.shown and c.tooltip.text:find("Your class cannot queue", 1, true))
                    control:SetChecked(true)
                    control.scripts.OnClick(control) -- Even a direct callback cannot bypass the restriction.
                    assert(not c.ns.HasRole(c.ns.prefs.roles, control.role))
                    assert(not control:GetChecked())
                end
            end
        end
    end
end)
test("Priest-style role selection retains Healer plus Damage and never enables Tank", function()
    local c = client({ allowedRoles = 6 })
    local controls = {}
    for _, control in ipairs(openUI(c)) do
        if control.guildQueueKind == "role" then controls[control.role] = control end
    end
    controls[2]:SetChecked(true)
    controls[2].scripts.OnClick(controls[2])
    equal(c.ns.prefs.roles, 6)
    assert(not controls[1].enabled)
    c.ns.SetQueued(true)
    c:advance(1)
    equal(c.ns.state.records[c.ns.playerName].roles, 6)
    equal(#c.invites, 0)
end)
test("group tiles show assigned-role icons separately from multi-role preferences", function()
    local c = client()
    suggestedGroup(c)
    c.ns.prefs.roles = 7
    c.ns.PreferencesChanged()
    c:advance(1)
    local widgets = openUI(c)
    local ownTile
    for _, tile in ipairs(widgets) do
        if tile.guildQueueKind == "member" and tile.player then
            equal(tile.roleIcon.role, tile.role)
            assert(tile.roleIcon.atlas)
            for _, role in ipairs({ 1, 2, 4 }) do
                equal(tile.roleIcons[role].shown, c.ns.HasRole(tile.player.roles, role))
            end
            if tile.player.name == c.ns.playerName then ownTile = tile end
        end
    end
    assert(ownTile)
    equal(ownTile.roleIcon.role, 1) -- Assigned tank, despite selecting all three roles.
    for _, role in ipairs({ 1, 2, 4 }) do assert(ownTile.roleIcons[role].shown) end
    equal(#c.invites, 0)
end)
test("pooled individual and all-queued cards update icons without stale selected roles", function()
    local c = client()
    c.ns.SetQueued(true)
    c:advance(1)
    c:receive("Friend-TestRealm", packet(1, 3, { [2] = true }, c.now, c.now))
    local widgets = openUI(c)
    local function friendCard()
        for _, card in ipairs(widgets) do
            if card.guildQueueKind == "individual" and card.shown
                and card.player.name == "Friend-TestRealm" then return card end
        end
        error("friend card not found")
    end
    local card = friendCard()
    assert(card.roleIcons[1].shown and card.roleIcons[2].shown)
    assert(not card.roleIcons[4].shown)
    c:receive("Friend-TestRealm", packet(2, 4, { [2] = true }, c.now, c.now))
    equal(friendCard(), card)
    assert(not card.roleIcons[1].shown and not card.roleIcons[2].shown)
    assert(card.roleIcons[4].shown)
    equal(card.roleIcons[4].point[2], 12) -- Remaining icon is packed to the row's start.
    for _, control in ipairs(widgets) do
        if control.guildQueueKind == "tab" and control.mode == "queue" then
            control.scripts.OnClick(control)
        end
    end
    card = friendCard()
    assert(card.roleIcons[4].shown)
    assert(not card.roleIcons[1].shown and not card.roleIcons[2].shown)
    card.scripts.OnEnter(card)
    assert(c.tooltip.text:find("Roles: Damage", 1, true))
end)
test("role icons stay inside their visible selectors and listing tiles", function()
    local c = client()
    suggestedGroup(c)
    local widgets = openUI(c)
    local function visible(control)
        while control do
            if not control.shown then return false end
            control = control.parent
        end
        return true
    end
    local count = 0
    for _, icon in ipairs(widgets) do
        if icon.guildQueueKind == "roleIcon" and visible(icon) then
            count = count + 1
            local x, y = icon.point[2], -icon.point[3]
            assert(x >= 0 and y >= 0)
            assert(x + icon:GetWidth() <= icon.parent:GetWidth())
            assert(y + icon:GetHeight() <= icon.parent:GetHeight())
        end
    end
    assert(count >= 13) -- Three selectors, five assigned icons, five preference icons.
end)
test("Auction House-style bottom tabs are Dungeons then Quests and swap entire pages", function()
    local c = client()
    c.ns.SetQueued(true)
    c:advance(1)
    local widgets, tabs, sidebar, scroll, mainTabs = openUI(c), {}, nil, nil, {}
    for _, control in ipairs(widgets) do
        if control.guildQueueKind == "tab" then tabs[control.mode] = control end
        if control.mainTab then mainTabs[#mainTabs + 1] = control end
        if control.guildQueueKind == "dungeonSidebar" then sidebar = control end
        if control.guildQueueKind == "outputScroll" then scroll = control end
    end
    equal(#mainTabs, 2)
    equal(mainTabs[1].text, "Dungeons")
    equal(mainTabs[2].text, "Quests")
    local first, second = mainTabs[1], mainTabs[2]
    equal(first.point[1], "BOTTOMLEFT")
    equal(first.point[2], first.parent)
    equal(first.point[3], "BOTTOMLEFT")
    equal(first.point[4], 20)
    equal(first.point[5], -28)
    equal(second.point[1], "LEFT")
    equal(second.point[2], first)
    equal(second.point[3], "RIGHT")
    equal(second.point[4], 12)
    equal(second.point[5], 0)
    assert(first:GetWidth() > second:GetWidth(), "Auction House tabs size to their text")
    for _, tab in ipairs(mainTabs) do
        equal(tab.template, "PanelTabButtonTemplate")
        equal(tab.tabPadding, 20)
        equal(tab.minTabWidth, 70)
        equal(tab:GetHeight(), 32)
    end
    assert(tabs.dungeons.nativeSelected and not tabs.questing.nativeSelected)
    tabs.questing.scripts.OnClick(tabs.questing)
    assert(tabs.questing.nativeSelected and not tabs.dungeons.nativeSelected)
    assert(not sidebar.shown and not tabs.groups.shown and not tabs.queue.shown)
    equal(scroll.point[2], 18)
    equal(scroll:GetHeight(), 574)
    equal(scroll.content:GetWidth(), 1006)
    tabs.dungeons.scripts.OnClick(tabs.dungeons)
    assert(sidebar.shown and tabs.groups.shown and tabs.queue.shown)
    equal(scroll.point[2], 296)
    equal(scroll:GetHeight(), 530)
    assert(c.ns.queued and not c.ns.prefs.shareQuests)
    equal(#c.invites, 0)
end)
test("bottom tab artwork never overlaps its neighbor in either selection state", function()
    local c = client()
    local tabs = {}
    for _, control in ipairs(openUI(c)) do
        if control.mainTab then tabs[control.mode] = control end
    end
    local first, second = tabs.dungeons, tabs.questing
    for _, selected in ipairs({ "dungeons", "questing", "dungeons" }) do
        tabs[selected].scripts.OnClick(tabs[selected])
        equal(first.nativeSelected, selected == "dungeons")
        equal(second.nativeSelected, selected == "questing")
        local right = first.nativeSelected and first.RightActive or first.Right
        local left = second.nativeSelected and second.LeftActive or second.Left
        assert(right.shown and left.shown)
        local firstRight = first:GetWidth() + (right.allPoints or right).point[4]
        local secondLeft = first:GetWidth() + second.point[4] + (left.allPoints or left).point[4]
        assert(secondLeft >= firstRight + 1, "Visible native tab artwork must have a gap, not overlap")
    end
    equal(#c.invites, 0)
end)
test("bottom tabs change color without changing artwork bounds or label position", function()
    local c = client()
    local tabs, original = {}, {}
    local function geometry(texture)
        local bounds = texture.allPoints or texture
        return { atlas = texture.atlas, width = texture:GetWidth(), height = texture:GetHeight(), point = bounds.point }
    end
    for _, control in ipairs(openUI(c)) do
        if control.mainTab then
            tabs[control.mode] = control
            original[control] = { width = control:GetWidth(), height = control:GetHeight(),
                anchor = control.point, textY = control.Text.point[5], parts = {} }
            for _, part in ipairs({ "Left", "Middle", "Right" }) do
                local shown = control[part .. (control.nativeSelected and "Active" or "")]
                original[control].parts[part] = geometry(shown)
            end
        end
    end
    for _, selected in ipairs({ "questing", "dungeons", "questing" }) do
        tabs[selected].scripts.OnClick(tabs[selected])
        c.ns.RefreshUI()
        for _, control in pairs(tabs) do
            local before = original[control]
            equal(control:GetWidth(), before.width)
            equal(control:GetHeight(), before.height)
            equal(control.point, before.anchor)
            equal(control.Text.point[5], before.textY)
            for _, part in ipairs({ "Left", "Middle", "Right" }) do
                local active = control[part .. "Active"]
                for _, state in ipairs({ "", "Active", "Highlight" }) do
                    local texture = control[part .. state]
                    local bounds, expected = geometry(texture), before.parts[part]
                    equal(bounds.atlas, expected.atlas)
                    equal(bounds.width, expected.width)
                    equal(bounds.height, expected.height)
                    equal(bounds.point, expected.point)
                    equal(texture.desaturated, state ~= "Active")
                end
                equal(control[part].shown, not control.nativeSelected)
                equal(active.shown, control.nativeSelected)
            end
        end
    end
    equal(#c.invites, 0)
end)
test("returning from Quests preserves the selected dungeon view and scroll position", function()
    local c = client()
    for index = 1, 30 do
        c:receive("D" .. index .. "-TestRealm", packet(1, 4, nil, c.now, c.now))
    end
    local widgets, tabs, scroll = openUI(c), {}, nil
    for _, control in ipairs(widgets) do
        if control.guildQueueKind == "tab" then tabs[control.mode] = control end
        if control.guildQueueKind == "outputScroll" then scroll = control end
    end
    tabs.queue.scripts.OnClick(tabs.queue)
    scroll.scripts.OnMouseWheel(scroll, -5)
    local previous = scroll:GetVerticalScroll()
    assert(previous > 0)
    tabs.questing.scripts.OnClick(tabs.questing)
    tabs.dungeons.scripts.OnClick(tabs.dungeons)
    assert(tabs.queue.selected and not tabs.groups.selected)
    equal(scroll:GetVerticalScroll(), previous)
    assert(tabs.dungeons.nativeSelected)
end)
test("native tab buttons keep the active view pressed", function()
    local c = client()
    local widgets = openUI(c)
    local tabs = {}
    for _, control in ipairs(widgets) do
        if control.guildQueueKind == "tab" then tabs[control.mode] = control end
    end
    equal(tabs.groups.buttonState, "PUSHED")
    assert(tabs.groups.locked)
    equal(tabs.queue.buttonState, "NORMAL")
    tabs.queue.scripts.OnClick(tabs.queue)
    equal(tabs.groups.buttonState, "NORMAL")
    assert(not tabs.groups.locked)
    equal(tabs.queue.buttonState, "PUSHED")
    assert(tabs.queue.locked)
end)

test("all addon chunks compile as Lua 5.1", function()
    for _, module in ipairs({ "Catalog", "Protocol", "State", "Matcher", "Questing", "UI", "Core" }) do
        assert(loadfile("GuildQueue/" .. module .. ".lua"))
    end
end)

print(string.format("\n%d passed; %d failed", passed, failed))
if failed > 0 then os.exit(1) end
