-- Standalone backend tests: lua5.1 tests/party.lua (no WoW/Core fixtures).
local ns = {}
for _, module in ipairs({ "Config", "Catalog", "Protocol", "State", "Matcher" }) do
    assert(loadfile("GuildQueue/" .. module .. ".lua"))("GuildQueue", ns)
end
local passed, failed = 0, 0
local function test(name, run)
    local ok, err = pcall(run)
    if ok then passed = passed + 1; print("PASS " .. name)
    else failed = failed + 1; print("FAIL " .. name .. ": " .. tostring(err)) end
end
local function equal(actual, expected)
    assert(actual == expected, "expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local function member(name, roles) return { name = name, roles = roles } end
local defaultMembers = { member("Leader-Realm", 1), member("Friend-Realm", 2) }
local function transaction(members, revision, sentAt, joinedAt, dungeons)
    local messages = assert(ns.Protocol.EncodeParty(revision or 1, sentAt or 1000, joinedAt or 900,
        dungeons or { [1] = true }, members or defaultMembers))
    local packets = {}
    for _, message in ipairs(messages) do packets[#packets + 1] = assert(ns.Protocol.Decode(message)) end
    return packets
end
local function apply(state, packets, owner, now)
    local changed = false
    for _, packet in ipairs(packets) do
        if state:Apply(owner or "Leader-Realm", packet, now or packet.sentAt) then changed = true end
    end
    return changed
end
local function solo(state, name, roles, dungeons, joinedAt, revision, sentAt)
    return state:Apply(name, { kind = "S", revision = revision or 1, sentAt = sentAt or 1000,
        joinedAt = joinedAt or 900, roles = roles, dungeons = dungeons or { [1] = true } }, sentAt or 1000)
end
local function withdraw(state, owner, revision, now)
    return state:Apply(owner, { kind = "X", revision = revision, sentAt = now or 1001 }, now or 1001)
end
local function count(values)
    local total = 0
    for _ in pairs(values) do total = total + 1 end
    return total
end
local function names(players)
    local values = {}
    for _, player in ipairs(players) do values[#values + 1] = player.name end
    return table.concat(values, ",")
end
local function signature(groups, individuals)
    local parts = {}
    for _, group in ipairs(groups) do parts[#parts + 1] = group.dungeonID .. ":" .. names(group.members) end
    return table.concat(parts, ";") .. "/" .. names(individuals)
end
local function checkGroups(state)
    local groups, individuals = ns.Match(state)
    local seen, partyGroups = {}, {}
    for index, group in ipairs(groups) do
        local leaders, occupied = {}, 0
        for slot = 1, 5 do
            local player = group.slots[slot]
            if player then
                occupied = occupied + 1
                assert(ns.HasRole(player.roles, ns.SLOTS[slot]))
                if player.partyLeader then equal(player.roles, ns.SLOTS[slot]) end
            end
        end
        equal(occupied, #group.members)
        for _, player in ipairs(group.members) do
            assert(not seen[player.name:lower()]); seen[player.name:lower()] = true
            assert(player.dungeons[group.dungeonID])
            for id in pairs(group.dungeons) do assert(player.dungeons[id]) end
            if player.partyLeader then
                leaders[player.partyLeader] = true
                if partyGroups[player.partyLeader] then equal(partyGroups[player.partyLeader], index) end
                partyGroups[player.partyLeader] = index
            end
        end
        assert(count(leaders) <= 1)
    end
    for _, player in ipairs(individuals) do
        assert(not player.partyLeader, "split or unmatched valid party")
        assert(not seen[player.name:lower()]); seen[player.name:lower()] = true
    end
    equal(count(seen), #state:Sorted())
    return groups, individuals
end

test("B/C round trips preserve exact schemas and solo wire format", function()
    local messages = assert(ns.Protocol.EncodeParty(7, 1000, 900, { [1] = true, [2] = true }, defaultMembers))
    equal(#messages, 3)
    equal(messages[1], "1|B|7|1000|900|2|1,2")
    equal(messages[2], "1|C|7|1000|1|2|1|Leader-Realm")
    for _, text in ipairs(messages) do equal(ns.Protocol.Encode(ns.Protocol.Decode(text)), text) end
    local header, fragment = ns.Protocol.Decode(messages[1]), ns.Protocol.Decode(messages[2])
    equal(count(header), 6); equal(count(fragment), 7)
    equal(header.total, 2); equal(fragment.name, "Leader-Realm"); equal(fragment.roles, 1)
    equal(ns.Protocol.Encode({ kind = "S", revision = 7, sentAt = 1000, joinedAt = 900,
        roles = 7, dungeons = { [1] = true } }), "1|S|7|1000|900|7|1")
end)

test("all party sizes and dungeons fit messages with maximal names and numbers", function()
    local dungeons = {}
    for _, dungeon in ipairs(ns.DUNGEONS) do dungeons[dungeon.id] = true end
    for size = 2, 5 do
        local members = {}
        for index = 1, size do members[index] = member(string.rep("a", 125) .. index .. "-R", 4) end
        local messages = assert(ns.Protocol.EncodeParty(9007199254740990, 9999999999, 9999999999, dungeons, members))
        equal(#messages, size + 1)
        for _, text in ipairs(messages) do assert(#text <= 255); assert(ns.Protocol.Decode(text)) end
    end
end)

test("strict party decoder rejects malformed headers fragments and names", function()
    for _, text in ipairs({ "1|B|0|1000|900|2|1", "1|B|1.5|1000|900|2|1", "1|B|1|0|900|2|1",
        "1|B|1|1000|1001|2|1", "1|B|1|1000|0|2|1", "1|B|1|1000|900|1|1", "1|B|1|1000|900|6|1",
        "1|B|1|1000|900|2|", "1|B|1|1000|900|2|999", "1|B|1|1000|900|2|1,1",
        "1|B|1|1000|900|2|1,", "1|B|1|1000|900|2|1|extra", "1|B|1|1000|900|2",
        "1|C|1|1000|0|2|1|A-R", "1|C|1|1000|3|2|1|A-R", "1|C|1|1000|1|1|1|A-R",
        "1|C|1|1000|1|6|1|A-R", "1|C|1|1000|1|2|0|A-R", "1|C|1|1000|1|2|3|A-R",
        "1|C|1|1000|1|2|7|A-R", "1|C|1|1000|1|2|1.0|A-R", "1|C|1|1000|1|2|1|A-R|extra",
        "1|C|1|1000|1|2|1", "1|C|1|1000|1|2|1|A", "1|C|1|1000|1|2|1|-R",
        "1|C|1|1000|1|2|1|A-", "1|C|1|1000|1|2|1|A -R", "1|C|1|1000|1|2|1|A-R R",
        "1|C|1|1000|1|2|1|A-\tR", "1|C|1|1000|1|2|1|A-\127R", "1|C|1|1000|1|2|1|A-\0R" }) do
        assert(not ns.Protocol.Decode(text), "accepted " .. text)
    end
end)

test("name byte bounds and 255 byte transport bounds are enforced", function()
    local prefix, name = "1|C|1|1000|1|2|1|", string.rep("n", 126) .. "-R"
    equal(#name, 128); assert(ns.Protocol.Decode(prefix .. name))
    assert(not ns.Protocol.Decode(prefix .. "n" .. name))
    local padded = "1|C|" .. string.rep("0", 255 - #prefix - #name) .. "1|1000|1|2|1|" .. name
    equal(#padded, 255); assert(ns.Protocol.Decode(padded)); assert(not ns.Protocol.Decode(padded .. "a"))
    assert(not ns.Protocol.EncodeParty(1, 1000, 900, { [1] = true }, { member("n" .. name, 1), member("B-R", 2) }))
end)

test("EncodeParty refuses malformed arrays duplicates roles and header invariants", function()
    for _, members in ipairs({ {}, { member("A-R", 1) },
        { member("A-R", 1), member("a-r", 2) }, { member("A-R", 3), member("B-R", 2) },
        { member("A-R", 1), member("B R", 2) }, { member("A-R", 1), false },
        { [1] = member("A-R", 1), [3] = member("B-R", 2) },
        { member("A-R", 1), member("B-R", 2), extra = true },
        { member("A-R", 1), member("B-R", 2), member("C-R", 4), member("D-R", 4), member("E-R", 4), member("F-R", 4) } }) do
        assert(not ns.Protocol.EncodeParty(1, 1000, 900, { [1] = true }, members))
    end
    for _, args in ipairs({ { 0, 1000, 900 }, { 1, 0, 900 }, { 1, 1000, 1001 },
        { 1, 1000, 0 }, { 1.5, 1000, 900 }, { math.huge, 1000, 900 }, { 1, 0/0, 900 } }) do
        assert(not ns.Protocol.EncodeParty(args[1], args[2], args[3], { [1] = true }, defaultMembers))
    end
    assert(not ns.Protocol.EncodeParty(1, 1000, 900, {}, defaultMembers))
    assert(not ns.Protocol.EncodeParty(1, 1000, 900, { [999] = true }, defaultMembers))
    assert(not ns.Protocol.EncodeParty(1, 1000, 900, { [1] = true }, "members"))
end)

test("out-of-order duplicates expose only one complete owner record", function()
    local state, packets = ns.State.New(), transaction()
    assert(not state:Apply("Leader-Realm", packets[3], 1000))
    assert(not state:Apply("Leader-Realm", packets[3], 1000))
    equal(state.seen["Leader-Realm"], 1); equal(#state:Sorted(), 0)
    assert(not state:Apply("Leader-Realm", packets[2], 1000))
    assert(state:Apply("Leader-Realm", packets[1], 1000))
    equal(count(state.records), 1); equal(count(state.pending), 0)
    local record = state.records["Leader-Realm"]
    equal(record.name, "Leader-Realm"); equal(record.roles, 1); equal(record.partySize, 2)
    equal(record.partyLeader, "Leader-Realm"); equal(names(record.partyMembers), "Friend-Realm,Leader-Realm")
    equal(count(record), 8); equal(#state:Sorted(), 2); equal(state.records["Friend-Realm"], nil)
    for _, player in ipairs(state:Sorted()) do equal(count(player), 7) end
    for _, packet in ipairs(packets) do assert(not state:Apply("Leader-Realm", packet, 1000)) end
end)

test("all fragment permutations commit only at completion", function()
    for _, order in ipairs({ {1,2,3}, {1,3,2}, {2,1,3}, {2,3,1}, {3,1,2}, {3,2,1} }) do
        local state, packets = ns.State.New(), transaction()
        for index, part in ipairs(order) do
            equal(state:Apply("Leader-Realm", packets[part], 1000), index == 3)
            equal(#state:Sorted(), index == 3 and 2 or 0)
        end
    end
end)

test("assembly retains complete records and immediately blocks older S/X revisions", function()
    local state = ns.State.New(); assert(apply(state, transaction()))
    local old, newer = state.records["Leader-Realm"], transaction(nil, 3, 1020)
    assert(not state:Apply("Leader-Realm", newer[3], 1020))
    equal(state.records["Leader-Realm"], old); equal(state.seen["Leader-Realm"], 3)
    assert(not solo(state, "Leader-Realm", 4, nil, 900, 2, 1020))
    assert(not withdraw(state, "Leader-Realm", 2, 1020)); assert(not withdraw(state, "Leader-Realm", 3, 1020))
    assert(not state:Apply("Leader-Realm", newer[1], 1020))
    assert(not state:Apply("Leader-Realm", newer[2], 1020))
    equal(state.records["Leader-Realm"].sentAt, 1020); equal(#state:Sorted(), 2)
end)

test("withdrawals clear complete and partial state and prevent resurrection", function()
    local state = ns.State.New(); apply(state, transaction())
    local packets = transaction(nil, 2, 1020)
    state:Apply("Leader-Realm", packets[1], 1020)
    assert(withdraw(state, "leader-realm", 3, 1021))
    equal(#state:Sorted(), 0); equal(count(state.pending), 0)
    assert(not apply(state, packets, nil, 1021)); assert(not apply(state, transaction(nil, 3, 1021)))
    assert(apply(state, transaction(nil, 4, 1022)))
    local pending = ns.State.New(); pending:Apply("Leader-Realm", transaction()[2], 1000)
    assert(not withdraw(pending, "Leader-Realm", 2))
    assert(not apply(pending, transaction())); equal(#pending:Sorted(), 0)
end)

test("mismatched fragments poison the revision without changing the previous snapshot", function()
    for _, corrupt in ipairs({
        function(p) p[3].total = 3 end, function(p) p[3].sentAt = 1021 end,
        function(p) p[2].roles = 4 end, function(p) p[2].name = "Other-Realm" end,
        function(p) p[1].joinedAt = 901 end, function(p) p[1].dungeons = { [2] = true } end,
    }) do
        local state = ns.State.New(); apply(state, transaction())
        local old = state.records["Leader-Realm"]
        local original, bad = transaction(nil, 2, 1020), transaction(nil, 2, 1020)
        state:Apply("Leader-Realm", original[1], 1020); state:Apply("Leader-Realm", original[2], 1020)
        corrupt(bad)
        for index = 1, 3 do
            if ns.Protocol.Encode(bad[index]) ~= ns.Protocol.Encode(original[index]) then
                assert(not state:Apply("Leader-Realm", bad[index], 1021))
            end
        end
        assert(not apply(state, original, nil, 1021))
        equal(state.records["Leader-Realm"], old); equal(count(state.pending), 0)
        assert(apply(state, transaction({ member("Leader-Realm", 1), member("New-Realm", 4) }, 3, 1022)))
    end
end)

test("duplicate names missing leader and impossible native role capacity are rejected atomically", function()
    for _, members in ipairs({
        { member("Other-Realm", 1), member("Friend-Realm", 2) },
        { member("Leader-Realm", 1), member("Friend-Realm", 1) },
        { member("Leader-Realm", 2), member("Friend-Realm", 2) },
        { member("Leader-Realm", 4), member("B-R", 4), member("C-R", 4), member("D-R", 4) },
    }) do
        local state = ns.State.New(); assert(not apply(state, transaction(members)))
        equal(#state:Sorted(), 0); equal(count(state.pending), 0); equal(state.seen["Leader-Realm"], 1)
        assert(not apply(state, transaction()))
    end
    local state, packets = ns.State.New(), transaction(); packets[3].name = "leader-realm"
    assert(not apply(state, packets)); equal(#state:Sorted(), 0); equal(count(state.pending), 0)
    local case = ns.State.New()
    assert(apply(case, transaction({ member("friend-realm", 2), member("leader-realm", 1) })))
    equal(case:Get("LEADER-REALM").name, "Leader-Realm")
end)

test("heartbeats refresh freshness without matching changes despite reordered members", function()
    local state = ns.State.New(); assert(apply(state, transaction()))
    local old = state.records["Leader-Realm"]
    assert(not apply(state, transaction({ defaultMembers[2], defaultMembers[1] }, 2, 1020)))
    equal(old.sentAt, 1000); equal(state:Get("friend-realm").sentAt, 1020)
    assert(not state:Prune(1094)); assert(state:Prune(1095))
    equal(#state:Sorted(), 0); equal(state.seen["Leader-Realm"], 2)
end)

test("semantic changes return true and switching to solo clears party metadata", function()
    local state = ns.State.New(); apply(state, transaction())
    local swapped = { member("Leader-Realm", 2), member("Friend-Realm", 1) }
    assert(apply(state, transaction(swapped, 2, 1001))); assert(apply(state, transaction(swapped, 3, 1002, 901)))
    assert(apply(state, transaction(swapped, 4, 1003, 901, { [2] = true })))
    swapped[2].name = "New-Realm"
    assert(apply(state, transaction(swapped, 5, 1004, 901, { [2] = true })))
    assert(solo(state, "Leader-Realm", 2, { [2] = true }, 901, 6, 1005))
    equal(#state:Sorted(), 1); equal(state:Get("Leader-Realm").partyLeader, nil)
    assert(not solo(state, "Leader-Realm", 2, { [2] = true }, 901, 7, 1006))
end)

test("packet input cannot mutate staged or committed snapshots", function()
    local state, packets = ns.State.New(), transaction()
    state:Apply("Leader-Realm", packets[1], 1000); state:Apply("Leader-Realm", packets[2], 1000)
    packets[1].dungeons[2], packets[2].name = true, "Mutated-Realm"
    assert(state:Apply("Leader-Realm", packets[3], 1000))
    assert(not state:Get("Leader-Realm").dungeons[2]); assert(not state:Get("Mutated-Realm"))
end)

test("expired or future transactions cannot start and expired pending cannot restart", function()
    local state, packets = ns.State.New(), transaction()
    state:Apply("Leader-Realm", packets[2], 1000)
    assert(not state:Prune(1075)); equal(count(state.pending), 0)
    assert(not apply(state, transaction(nil, 1, 1075), nil, 1075))
    equal(count(state.pending), 0); equal(state.seen["Leader-Realm"], 1)
    assert(apply(state, transaction(nil, 2, 1075), nil, 1075))
    local stale = ns.State.New()
    assert(not stale:Apply("Leader-Realm", packets[1], 1075))
    assert(not stale:Apply("Leader-Realm", transaction(nil, 3, 1081)[1], 1075))
    equal(count(stale.pending), 0); equal(count(stale.seen), 0)
end)

test("pending cache has a fixed owner bound and eviction retains replay protection", function()
    local state = ns.State.New()
    for index = 1, 200 do assert(not state:Apply("Owner" .. index .. "-Realm", transaction()[1], 1000)) end
    assert(count(state.pending) <= 64); equal(count(state.records), 0)
    local evicted
    for owner in pairs(state.seen) do if not state.pending[owner] then evicted = owner; break end end
    assert(evicted); assert(not state:Apply(evicted, transaction()[1], 1001)); equal(state.pending[evicted], nil)
    assert(not state:Prune(1075)); equal(count(state.pending), 0)
end)

test("overlapping parties and all claimed solos are hidden independently of insertion order", function()
    local function setup(reverse)
        local state = ns.State.New()
        solo(state, "Shared-Realm", 4); solo(state, "Other-Realm", 4); solo(state, "Unaffected-Realm", 2)
        local advertisements = {
            { "A-Realm", { member("A-Realm", 1), member("Shared-Realm", 4) } },
            { "B-Realm", { member("B-Realm", 2), member("shared-realm", 4), member("Other-Realm", 4) } },
            { "C-Realm", { member("C-Realm", 1), member("other-realm", 4) } },
        }
        for i = 1, 3 do
            local ad = advertisements[reverse and 4 - i or i]; assert(apply(state, transaction(ad[2]), ad[1]))
        end
        return state
    end
    local forward, reverse = setup(false), setup(true)
    equal(names(forward:Sorted()), "Unaffected-Realm"); equal(names(reverse:Sorted()), names(forward:Sorted()))
    equal(forward:Get("A-Realm"), nil); equal(forward:Get("SHARED-REALM"), nil)
    assert(withdraw(forward, "B-Realm", 2)); equal(#forward:Sorted(), 5)
    equal(forward:Get("SHARED-REALM").partyLeader, "A-Realm")
    equal(forward:Get("OTHER-REALM").partyLeader, "C-Realm")
    assert(forward:Remove("a-realm")); equal(forward:Get("SHARED-REALM").partyLeader, nil)
    equal(forward.seen["A-Realm"], 1)
end)

test("Remove affects only owner records and pending without advancing revision", function()
    local state = ns.State.New(); apply(state, transaction())
    state:Apply("Leader-Realm", transaction(nil, 2, 1020)[2], 1020)
    assert(not state:Remove("Friend-Realm")); equal(#state:Sorted(), 2)
    assert(state:Remove("LEADER-REALM")); equal(#state:Sorted(), 0); equal(count(state.pending), 0)
    equal(state.seen["Leader-Realm"], 2); assert(not apply(state, transaction(nil, 2, 1020)))
    assert(apply(state, transaction(nil, 3, 1021)))
    state:Apply("Pending-Realm", transaction()[1], 1000)
    assert(not state:Remove("pending-realm")); equal(state.pending["Pending-Realm"], nil)
    equal(state.seen["Pending-Realm"], 1)
end)

test("Get reflects public mutation and solos retain record identity and shape", function()
    local state = ns.State.New(); solo(state, "Solo-Realm", 7)
    local record = state.records["Solo-Realm"]
    equal(state:Get("solo-realm"), record); equal(state:Sorted()[1], record); equal(count(record), 5)
    record.roles = 2; equal(state:Get("SOLO-REALM").roles, 2)
    state.records["Solo-Realm"] = nil; equal(state:Get("Solo-Realm"), nil)
    apply(state, transaction()); state.records["Leader-Realm"].partyMembers[1].roles = 4
    equal(state:Get("Friend-Realm").roles, 4)
    state.records["Leader-Realm"] = nil; equal(state:Get("Friend-Realm"), nil)
end)

test("membership pruning authenticates owners not delegated non-guild members", function()
    local state = ns.State.New(); apply(state, transaction())
    assert(not state:Prune(1001, { ["leader-realm"] = true })); equal(#state:Sorted(), 2)
    state:Apply("Pending-Realm", transaction()[1], 1000)
    assert(state:Prune(1001, { ["Friend-Realm"] = true }))
    equal(#state:Sorted(), 0); equal(count(state.pending), 0)
    equal(state.seen["Leader-Realm"], 1); equal(state.seen["Pending-Realm"], 1)
end)

test("every valid party size forms an indivisible partial or full suggestion", function()
    for size = 2, 5 do
        local state, members = ns.State.New(), {}
        for index = 1, size do members[index] = member("P" .. index .. "-Realm", ns.SLOTS[index]) end
        assert(apply(state, transaction(members), "P1-Realm"))
        local groups, individuals = checkGroups(state)
        equal(#groups, 1); equal(#groups[1].members, size); equal(#individuals, 0)
    end
end)

test("native roles stay locked while flexible solos augment into remaining slots", function()
    local state = ns.State.New()
    apply(state, transaction({ member("Leader-Realm", 4), member("Friend-Realm", 4) }))
    solo(state, "Flexible-Realm", 3, nil, 800); solo(state, "Tank-Realm", 1, nil, 801)
    solo(state, "Damage-Realm", 4, nil, 802); solo(state, "Extra-Realm", 2, nil, 803)
    local groups, individuals = checkGroups(state)
    equal(#groups, 1); equal(#groups[1].members, 5); equal(#individuals, 1)
    equal(groups[1].slots[1].name, "Tank-Realm"); equal(groups[1].slots[2].name, "Flexible-Realm")
    equal(individuals[1].name, "Extra-Realm")
end)

test("complementary native parties never merge", function()
    local state = ns.State.New()
    apply(state, transaction({ member("Leader-Realm", 1), member("D1-Realm", 4) }))
    apply(state, transaction({ member("Healer-Realm", 2), member("D2-Realm", 4) }), "Healer-Realm")
    solo(state, "D3-Realm", 4)
    local groups, individuals = checkGroups(state)
    equal(#groups, 2); equal(#groups[1].members, 3); equal(#groups[2].members, 2); equal(#individuals, 0)
end)

test("full then larger candidates beat older partial parties", function()
    local state = ns.State.New(); apply(state, transaction(nil, 1, 1000, 700))
    for index, role in ipairs(ns.SLOTS) do solo(state, "Solo" .. index .. "-Realm", role, { [2] = true }, 800 + index) end
    local groups = checkGroups(state)
    equal(#groups, 2); equal(#groups[1].members, 5); equal(groups[1].dungeonID, 2)
    equal(#groups[2].members, 2); equal(groups[2].dungeonID, 1)
    local partial = ns.State.New(); apply(partial, transaction(nil, 1, 1000, 700))
    for index, role in ipairs({ 2, 4, 4 }) do solo(partial, "Solo" .. index .. "-Realm", role, { [2] = true }, 800 + index) end
    local partialGroups = checkGroups(partial)
    equal(#partialGroups[1].members, 3); equal(partialGroups[1].dungeonID, 2)
end)

test("equal-size candidates use older player order then dungeon ID", function()
    local state = ns.State.New(); apply(state, transaction(nil, 1, 1000, 700, { [2] = true, [3] = true }))
    solo(state, "NewTank-Realm", 1, { [1] = true }, 800); solo(state, "NewHeal-Realm", 2, { [1] = true }, 801)
    local groups = checkGroups(state)
    equal(groups[1].dungeonID, 2); equal(groups[1].members[1].partyLeader, "Leader-Realm")
    local tied = ns.State.New(); apply(tied, transaction(nil, 1, 1000, 900, { [1] = true, [2] = true }))
    solo(tied, "A-Damage-Realm", 4, { [2] = true }, 800); solo(tied, "B-Damage-Realm", 4, { [1] = true }, 801)
    equal(checkGroups(tied)[1].dungeonID, 2)
end)

test("party dungeon intersections and global uniqueness are retained", function()
    local state = ns.State.New(); apply(state, transaction(nil, 1, 1000, 900, { [1] = true, [2] = true }))
    for i = 1, 7 do solo(state, "D" .. i .. "-Realm", 4, { [2] = true, [3] = true }, 800 + i) end
    local groups, individuals = checkGroups(state)
    equal(#groups[1].members, 5); equal(groups[1].dungeonID, 2)
    assert(groups[1].dungeons[2] and not groups[1].dungeons[1] and not groups[1].dungeons[3])
    equal(#groups, 2); equal(#groups[2].members, 3); equal(#individuals, 1)
end)

test("matching is deterministic across transaction and owner insertion orders", function()
    local function setup(reverse)
        local state = ns.State.New()
        local ads = {
            { "A-Realm", { member("A-Realm", 1), member("AD-Realm", 4) } },
            { "B-Realm", { member("B-Realm", 2), member("BD-Realm", 4) } },
        }
        for i = 1, 2 do
            local ad = ads[reverse and 3 - i or i]
            local packets = transaction(ad[2], 1, 1000, 900, { [1] = true, [2] = true })
            if reverse then packets[1], packets[3] = packets[3], packets[1] end
            apply(state, packets, ad[1])
        end
        for i = 1, 8 do solo(state, "Solo" .. (reverse and 9 - i or i) .. "-Realm", 7) end
        return state
    end
    equal(signature(checkGroups(setup(false))), signature(checkGroups(setup(true))))
end)

local function maximum(players, dungeon, slot, used)
    if slot > 5 then return 0 end
    local best = maximum(players, dungeon, slot + 1, used)
    for index, player in ipairs(players) do
        if not used[index] and player.dungeons[dungeon] and ns.HasRole(player.roles, ns.SLOTS[slot]) then
            used[index] = true
            best = math.max(best, 1 + maximum(players, dungeon, slot + 1, used))
            used[index] = nil
        end
    end
    return best
end

-- Independent subset oracle: include every member of at most one native party,
-- then exhaustively assign roles. Compare size, lexicographic age, and dungeon.
local function atomicBest(players)
    local best
    for mask = 1, 2 ^ #players - 1 do
        local subset, order, parties, valid = {}, {}, {}, true
        for index, player in ipairs(players) do
            if math.floor(mask / 2 ^ (index - 1)) % 2 == 1 then
                subset[#subset + 1], order[#order + 1] = player, index
                if player.partyLeader then parties[player.partyLeader] = (parties[player.partyLeader] or 0) + 1 end
            end
        end
        if count(parties) > 1 then valid = false end
        for _, player in ipairs(subset) do
            if player.partyLeader and parties[player.partyLeader] ~= player.partySize then valid = false end
        end
        if valid and #subset >= 2 and #subset <= 5 then
            for dungeon = 1, 3 do
                if maximum(subset, dungeon, 1, {}) == #subset then
                    local better = not best or #subset > #best.members
                    if best and #subset == #best.members then
                        for index, position in ipairs(order) do
                            if position ~= best.order[index] then
                                better = position < best.order[index]
                                break
                            elseif index == #order then better = dungeon < best.dungeonID end
                        end
                    end
                    if better then best = { members = subset, order = order, dungeonID = dungeon } end
                end
            end
        end
    end
    return best
end

test("atomic matcher agrees with exhaustive candidate size age and dungeon ordering", function()
    math.randomseed(161803)
    for iteration = 1, 35 do
        local state = ns.State.New()
        for party = 1, 2 do
            local members, owner = {}, "Party" .. party .. "-Realm"
            local firstSlot = math.random(1, 4)
            members[1], members[2] = member(owner, ns.SLOTS[firstSlot]), member("Peer" .. party .. "-Realm", ns.SLOTS[firstSlot + 1])
            local dungeons = { [math.random(1, 2)] = true, [3] = true }
            assert(apply(state, transaction(members, 1, 1000, 800 + math.random(1, 8), dungeons), owner))
        end
        for index = 1, 4 do
            solo(state, "Solo" .. index .. "-Realm", math.random(1, 7),
                { [math.random(1, 3)] = true }, 800 + math.random(1, 8))
        end
        local groups, remaining = checkGroups(state), state:Sorted()
        for _, group in ipairs(groups) do
            local expected, included, rest, actualOrder = assert(atomicBest(remaining)), {}, {}, {}
            equal(#group.members, #expected.members); equal(group.dungeonID, expected.dungeonID)
            for _, player in ipairs(group.members) do included[player.name] = true end
            for index, player in ipairs(remaining) do
                if included[player.name] then actualOrder[#actualOrder + 1] = index
                else rest[#rest + 1] = player end
            end
            equal(table.concat(actualOrder, ","), table.concat(expected.order, ","))
            remaining = rest
        end
        equal(atomicBest(remaining), nil)
    end
end)

test("party options retain matches for every dungeon without consuming primary suggestions", function()
    local state = ns.State.New()
    apply(state, transaction(nil, 1, 1000, 900, { [1] = true, [2] = true, [3] = true }))
    solo(state, "First-Realm", 4, { [1] = true })
    solo(state, "Second-Realm", 4, { [2] = true })
    local groups, individuals = checkGroups(state)
    local original = signature(groups, individuals)
    local options = ns.PartyMatchOptions(state)
    equal(#options, 2)
    local seen = {}
    for _, option in ipairs(options) do
        assert(option.dungeonOption) equal(option.partyLeader, "Leader-Realm")
        equal(#option.members, 3) equal(count(option.dungeons), 1)
        assert(option.dungeons[option.dungeonID])
        equal(option.slots[1].name, "Leader-Realm") equal(option.slots[2].name, "Friend-Realm")
        seen[option.dungeonID] = true
    end
    assert(seen[1] and seen[2] and not seen[3])
    equal(signature(ns.Match(state)), original)
end)

test("one roster can be a separate option for each common dungeon", function()
    local state = ns.State.New()
    apply(state, transaction(nil, 1, 1000, 900, { [1] = true, [2] = true }))
    solo(state, "Flexible-Realm", 7, { [1] = true, [2] = true })
    local options = ns.PartyMatchOptions(state)
    equal(#options, 2) equal(options[1].dungeonID, 1) equal(options[2].dungeonID, 2)
    equal(names(options[1].members), names(options[2].members))
    for _, option in ipairs(options) do
        equal(option.slots[1].name, "Leader-Realm") equal(option.slots[2].name, "Friend-Realm")
        assert(option.slots[3] and not option.slots[4] and not option.slots[5])
    end
end)

test("complete party options do not suppress partial options or manufacture incompatible matches", function()
    local state = ns.State.New()
    apply(state, transaction(nil, 1, 1000, 900, { [1] = true, [2] = true, [3] = true }))
    for i = 1, 3 do solo(state, "Damage" .. i .. "-Realm", 4, { [1] = true }) end
    solo(state, "Partial-Realm", 4, { [2] = true })
    solo(state, "ExtraTank-Realm", 1, { [3] = true })
    local options = ns.PartyMatchOptions(state)
    equal(#options, 2)
    equal(options[1].dungeonID, 1) equal(#options[1].members, 5)
    equal(options[2].dungeonID, 2) equal(#options[2].members, 3)
end)

test("party options never borrow members of another native party", function()
    local state = ns.State.New()
    apply(state, transaction())
    apply(state, transaction({ member("Other-Realm", 4), member("OtherPeer-Realm", 4) }), "Other-Realm")
    equal(#ns.PartyMatchOptions(state), 0)
    solo(state, "Solo-Realm", 4)
    local options = ns.PartyMatchOptions(state)
    equal(#options, 2)
    for _, option in ipairs(options) do
        local own, solos = 0, 0
        for _, player in ipairs(option.members) do
            if player.partyLeader then equal(player.partyLeader, option.partyLeader) own = own + 1
            else equal(player.name, "Solo-Realm") solos = solos + 1 end
        end
        equal(own, 2) equal(solos, 1)
    end
end)

test("full parties and malformed party units cannot produce outside-recruit options", function()
    local state = ns.State.New()
    apply(state, transaction({ member("Leader-Realm", 1), member("Friend-Realm", 2),
        member("One-Realm", 4), member("Two-Realm", 4), member("Three-Realm", 4) }))
    solo(state, "Extra-Realm", 7)
    equal(#ns.PartyMatchOptions(state), 0)
    table.remove(state.records["Leader-Realm"].partyMembers)
    equal(#ns.PartyMatchOptions(state), 0)
    local solos = ns.State.New() solo(solos, "Solo-Realm", 7)
    equal(#ns.PartyMatchOptions(solos), 0)
end)

test("party options are deterministic across queue insertion and fragment arrival order", function()
    local function setup(reverse)
        local state = ns.State.New()
        local advertisements = {
            { "Alpha-Realm", { member("Alpha-Realm", 1), member("PeerA-Realm", 2) } },
            { "Bravo-Realm", { member("Bravo-Realm", 1), member("PeerB-Realm", 4) } },
        }
        for i = 1, 2 do
            local ad = advertisements[reverse and 3 - i or i]
            local packets = transaction(ad[2], 1, 1000, 900, { [1] = true, [2] = true })
            if reverse then packets[1], packets[3] = packets[3], packets[1] end
            apply(state, packets, ad[1])
        end
        for i = 1, 4 do
            local index = reverse and 5 - i or i
            solo(state, "Solo" .. index .. "-Realm", 6, { [1] = true, [2] = true }, 900 + index)
        end
        return state
    end
    equal(signature(ns.PartyMatchOptions(setup(false)), {}), signature(ns.PartyMatchOptions(setup(true)), {}))
end)

test("per-dungeon party options agree with an independent mandatory-party subset oracle", function()
    math.randomseed(314159)
    for _ = 1, 30 do
        local state = ns.State.New()
        for p = 1, 2 do
            local owner = "Party" .. p .. "-Realm"
            local first = math.random(1, 4)
            apply(state, transaction({ member(owner, ns.SLOTS[first]),
                member("Peer" .. p .. "-Realm", ns.SLOTS[first + 1]) }, 1, 1000,
                800 + math.random(1, 8), { [1] = true, [2] = true, [3] = true }), owner)
        end
        for i = 1, 4 do
            solo(state, "Solo" .. i .. "-Realm", math.random(1, 7),
                { [math.random(1, 3)] = true }, 800 + math.random(1, 8))
        end
        local players, indexed = state:Sorted(), {}
        for _, option in ipairs(ns.PartyMatchOptions(state)) do
            local key = option.partyLeader .. ":" .. option.dungeonID
            assert(not indexed[key]) indexed[key] = option
        end
        for p = 1, 2 do
            local owner = "Party" .. p .. "-Realm"
            for dungeon = 1, 3 do
                local best, eligible = nil, {}
                for index, player in ipairs(players) do
                    if player.partyLeader == owner or not player.partyLeader then
                        eligible[#eligible + 1] = { index = index, player = player }
                    end
                end
                for mask = 1, 2 ^ #eligible - 1 do
                    local subset, order, partyCount = {}, {}, 0
                    for i, candidate in ipairs(eligible) do
                        if math.floor(mask / 2 ^ (i - 1)) % 2 == 1 then
                            subset[#subset + 1], order[#order + 1] = candidate.player, candidate.index
                            if candidate.player.partyLeader then partyCount = partyCount + 1 end
                        end
                    end
                    if partyCount == 2 and #subset >= 3 and #subset <= 5
                        and maximum(subset, dungeon, 1, {}) == #subset then
                        local better = not best or #subset > #best.members
                        if best and #subset == #best.members then
                            for i, position in ipairs(order) do
                                if position ~= best.order[i] then better = position < best.order[i] break end
                            end
                        end
                        if better then best = { members = subset, order = order } end
                    end
                end
                local actual = indexed[owner .. ":" .. dungeon]
                equal(actual ~= nil, best ~= nil)
                if best then
                    equal(#actual.members, #best.members)
                    equal(table.concat(actual.order, ","), table.concat(best.order, ","))
                    for slot = 1, 5 do
                        local player = actual.slots[slot]
                        if player then assert(ns.HasRole(player.roles, ns.SLOTS[slot])) end
                    end
                end
            end
        end
    end
end)

print(passed .. " passed; " .. failed .. " failed")
if failed > 0 then os.exit(1) end
