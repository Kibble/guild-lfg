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
        for slot, player in ipairs(group.slots) do
            values[#values + 1] = slot .. ":" .. player.name
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
test("no complete group without all five role slots", function()
    local state = ns.State.New()
    for i = 1, 6 do add(state, "D" .. i, 4) end
    local groups, individuals = ns.Match(state)
    equal(#groups, 0)
    equal(#individuals, 6)
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
    equal(#groups, 0)
    equal(#individuals, 5)
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
    equal(#groups, 2)
    equal(#individuals, 3)
    for _, group in ipairs(groups) do
        for _, player in ipairs(group.slots) do
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
    equal(individuals[1].name, "Player11")
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
test("matcher agrees with brute-force feasibility on 200 generated queues", function()
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
        equal(#groups > 0, feasible)
        local seen = {}
        for _, group in ipairs(groups) do
            for slot, player in ipairs(group.slots) do
                assert(not seen[player.name])
                seen[player.name] = true
                assert(ns.HasRole(player.roles, ns.SLOTS[slot]))
                assert(player.dungeons[group.dungeonID])
            end
        end
        for _, player in ipairs(individuals) do
            assert(not seen[player.name])
            seen[player.name] = true
        end
        local count = 0
        for _ in pairs(seen) do count = count + 1 end
        equal(count, #players)
        for id = 1, 3 do assert(not possible(individuals, id, 1, {})) end
    end
end)

-- Minimal simulated clients exercise real Core code, not a second implementation.
-- UI is separately syntax-checked and smoke-tested below with widget stubs.
local function client(options)
    options = options or {}
    local c = { now = 1800000000, clock = 0, sent = {}, messages = {}, invites = {},
        guild = "Test Guild", roster = options.roster or { "Self-TestRealm", "Friend-TestRealm" },
        result = 0, locked = false, homeGroup = false, instanceGroup = false, combat = false }
    c.guildInfoUnavailable, c.nameUnavailable = options.guildInfoUnavailable, options.nameUnavailable
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
    env.UnitFullName = function()
        if c.nameUnavailable then return nil end
        return options.characterName or "Self", options.characterRealm or "Test Realm"
    end
    env.IsInGuild = function() return c.guild ~= nil end
    env.LE_PARTY_CATEGORY_HOME, env.LE_PARTY_CATEGORY_INSTANCE = 1, 2
    env.IsInGroup = function(category)
        if category == 2 then return c.instanceGroup end
        return c.homeGroup
    end
    env.InCombatLockdown = function() return c.combat end
    env.C_PartyInfo = { InviteUnit = function(name)
        if c.failInvite == name then error("Simulated invitation failure") end
        c.invites[#c.invites + 1] = name
        if c.inviteCreatesParty then c.homeGroup = true end
    end }
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
    assert(c.ns.CreatePartyDisabledReason(group):find("already in a party or raid", 1, true))
    assert(not c.ns.CreateParty(group))
    equal(#c.invites, 4)
end)
test("home parties, raids, and instance groups block Create party", function()
    local c = client()
    local group = suggestedGroup(c)
    for _, category in ipairs({ "homeGroup", "instanceGroup" }) do
        c[category] = true
        equal(c.ns.CreatePartyDisabledReason(group),
            "You are already in a party or raid. Leave your current group to create a new party.")
        assert(not c.ns.CreateParty(group))
        c[category] = false
    end
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
    function methods:GetWidth() return self.width end
    function methods:GetHeight() return self.height end
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
    function methods:SetAtlas(atlas) self.atlas = atlas end
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
    for _, name in ipairs({ "ClearAllPoints", "SetJustifyH", "SetJustifyV", "SetSpacing",
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
        end
        return control
    end
    local ui = assert(loadfile("GuildQueue/UI.lua"))
    setfenv(ui, c.env)
    ui("GuildQueue", c.ns)
    c.ns.ToggleUI()
    equal(c.env.UISpecialFrames[1], "GuildQueueFrame")
    return widgets
end

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
    c.homeGroup = true
    c:fire("GROUP_ROSTER_UPDATE")
    assert(not control.enabled)
    control.scripts.OnEnter(control)
    assert(c.tooltip.shown)
    equal(c.tooltip.text,
        "You are already in a party or raid. Leave your current group to create a new party.")
    -- Leaving the party updates both the button and an already-visible tooltip.
    c.homeGroup = false
    c:fire("GROUP_ROSTER_UPDATE")
    assert(control.enabled)
    assert(c.tooltip.text:find("Invite the other four", 1, true))
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
    assert(not control.shown)
    assert(not c.tooltip.shown)
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
    c:receive("Friend-TestRealm", packet(1, 4, nil, c.now, c.now))
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
            assert(point and point[1] == "TOPLEFT" and parent)
            assert(control:GetWidth() > 0 and control:GetHeight() > 0)
            assert(point[2] + control:GetWidth() <= parent:GetWidth(), control.text)
            assert(-point[3] + control:GetHeight() <= parent:GetHeight(), control.text)
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
    c:receive("Friend-TestRealm", packet(1, 3, nil, c.now, c.now))
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
    c:receive("Friend-TestRealm", packet(2, 4, nil, c.now, c.now))
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
