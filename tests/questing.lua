-- Run from the project root: lua5.1 tests/questing.lua
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
local function count(values)
    local total = 0
    for _ in pairs(values) do total = total + 1 end
    return total
end
local function sameMap(actual, expected)
    equal(count(actual), count(expected))
    for key, value in pairs(expected) do equal(actual[key], value) end
end
local ns = { TIMEOUT = 75 }
local module = assert(loadfile("GuildQueue/Questing.lua"))
setfenv(module, setmetatable({}, {
    __index = _G,
    __newindex = function(_, key) error("unexpected global write: " .. tostring(key)) end,
}))
module("GuildQueue", ns)
local Q = assert(ns.Questing)
local function fragment(revision, part, parts, quests, sentAt, zoneID, level)
    local ids, entries = {}, {}
    for id in pairs(quests) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        entries[#entries + 1] = id .. ":" .. (quests[id] and "1" or "0")
    end
    return assert(Q.Decode(table.concat({ "1", "Q", revision, sentAt or 1000,
        zoneID or 0, level or 60, part, parts, table.concat(entries, ",") }, "|")))
end
local function snapshot(revision, quests, sentAt, zoneID, level)
    return fragment(revision, 1, 1, quests, sentAt, zoneID, level)
end
local function stop(revision, sentAt)
    return assert(Q.Decode(Q.EncodeStop(revision, sentAt or 1000)))
end
local function questLog(size, first)
    local quests = {}
    for index = 1, size do quests[(first or 1) + index - 1] = index % 2 == 0 end
    return quests
end
local function reject(message)
    equal(Q.Decode(message), nil)
end

-- Wire format, numeric precision, and strict validation.
test("new objects own independent empty state", function()
    local first, second = Q.New(), Q.New()
    equal(count(first.peers), 0)
    equal(count(first.buffers), 0)
    equal(count(first.seen), 0)
    first.seen.A = 2
    equal(second.seen.A, nil)
    equal(second.peers.A, nil)
end)

test("encoding is deterministic and retains incomplete quests", function()
    local quests = { [40] = false, [2] = true, [13] = false }
    local messages = Q.Encode(7, 1000, 12, 60, quests)
    equal(#messages, 1)
    equal(messages[1], "1|Q|7|1000|12|60|1|1|2:1,13:0,40:0")
    local packet = assert(Q.Decode(messages[1]))
    equal(packet.kind, "Q")
    equal(packet.revision, 7)
    equal(packet.sentAt, 1000)
    equal(packet.zoneID, 12)
    equal(packet.level, 60)
    sameMap(packet.quests, quests)
    equal(Q.Encode(7, 1000, 12, 60, { [13] = false, [2] = true, [40] = false })[1], messages[1])
end)

test("empty snapshots and unknown zone and level round trip", function()
    local messages = Q.Encode(1, 1, 0, 0, {})
    equal(#messages, 1)
    equal(messages[1], "1|Q|1|1|0|0|1|1|")
    local packet = assert(Q.Decode(messages[1]))
    equal(packet.zoneID, 0)
    equal(packet.level, 0)
    equal(count(packet.quests), 0)
end)

test("maximum scalars preserve exact decimal precision", function()
    local message = Q.Encode(9007199254740990, 9999999999, 2147483647, 1000,
        { [2147483647] = false })[1]
    equal(message, "1|Q|9007199254740990|9999999999|2147483647|1000|1|1|2147483647:0")
    local packet = assert(Q.Decode(message))
    equal(packet.revision, 9007199254740990)
    equal(packet.sentAt, 9999999999)
    equal(packet.zoneID, 2147483647)
    equal(packet.level, 1000)
    equal(packet.quests[2147483647], false)
    local last = assert(Q.Decode("1|Q|1|1|0|0|32|32|"))
    equal(last.part, 32)
    equal(last.parts, 32)
end)

test("withdrawals have exactly four fields", function()
    equal(Q.EncodeStop(1, 1), "1|QX|1|1")
    local text = Q.EncodeStop(9007199254740990, 9999999999)
    equal(text, "1|QX|9007199254740990|9999999999")
    local packet = assert(Q.Decode(text))
    equal(packet.kind, "QX")
    equal(packet.revision, 9007199254740990)
    equal(packet.sentAt, 9999999999)
    equal(packet.quests, nil)
    equal(packet.zoneID, nil)
end)

test("a 255 byte packet is accepted and larger packets are rejected", function()
    local fields = { "1", "Q", "1", "1000", "0", "60", "1", "1", "" }
    local entries = {}
    for id = 100000001, 100000019 do entries[#entries + 1] = id .. ":0" end
    fields[9] = table.concat(entries, ",")
    local base = table.concat(fields, "|")
    fields[3] = string.rep("1", 256 - #base)
    local boundary = table.concat(fields, "|")
    equal(#boundary, 255)
    assert(Q.Decode(boundary))
    reject(boundary .. ",1:0")
    reject(boundary .. " ")
end)

test("logs of every size through 200 obey dynamic chunk bounds and sorted order", function()
    for size = 0, 200 do
        local quests = questLog(size, 2147483448)
        local messages = Q.Encode(9007199254740990, 9999999999, 2147483647, 1000, quests)
        assert(#messages >= 1 and #messages <= 32)
        if size == 200 then assert(#messages >= 10) end
        local decoded, previous = {}, 0
        for part, message in ipairs(messages) do
            assert(#message <= 255)
            local packet = assert(Q.Decode(message))
            equal(packet.part, part)
            equal(packet.parts, #messages)
            for idText in message:match("([^|]*)$"):gmatch("(%d+):[01]") do
                local id = tonumber(idText)
                assert(id > previous)
                previous = id
            end
            for id, complete in pairs(packet.quests) do
                equal(decoded[id], nil)
                decoded[id] = complete
            end
        end
        sameMap(decoded, quests)
    end
end)

test("chunking fills available bytes rather than using a fixed quest count", function()
    local short = Q.Encode(1, 1000, 0, 1, questLog(200))
    local long = Q.Encode(9007199254740990, 9999999999, 2147483647, 1000,
        questLog(200, 2147483448))
    assert(#short < #long)
    for _, messages in ipairs({ short, long }) do
        for part = 1, #messages - 1 do
            local nextEntry = messages[part + 1]:match("([^|]*)$"):match("^[^,]+")
            assert(#messages[part] + 1 + #nextEntry > 255)
        end
    end
end)

test("invalid versions kinds field counts and NUL are rejected", function()
    for _, text in ipairs({ "", "1", "1|Q", "1|QX", "1|H", "1|X|1|1000",
        "2|QX|1|1000", "01|QX|1|1000", "1|q|1|1000|0|60|1|1|",
        "1|QX|1|1000|", "1|QX|1|1000|extra", "1|Q|1|1000|0|60|1|1",
        "1|Q|1|1000|0|60|1|1||", "1|Q|1|1000|0|60|1|1|1:0|extra",
        "1|QX|1|1000\0", "1|Q|1|1000|0|60|1|1|1:0\0", "1|QX|1|1000\n" }) do
        reject(text)
    end
    reject(nil)
    reject(false)
    reject(1)
    reject({})
end)

test("all scalar fields enforce integer syntax and ranges", function()
    local invalid = {
        [3] = { "0", "-1", "9007199254740991", "9007199254740992" },
        [4] = { "0", "-1", "10000000000" },
        [5] = { "-1", "2147483648" },
        [6] = { "-1", "1001" },
        [7] = { "0", "-1", "33", "2" },
        [8] = { "0", "-1", "33" },
    }
    for field = 3, 8 do
        for _, bad in ipairs({ "", "+1", "1.0", "1e0", " 1", "1 ", "nan", "inf", "1\n" }) do
            invalid[field][#invalid[field] + 1] = bad
        end
        for _, bad in ipairs(invalid[field]) do
            local fields = { "1", "Q", "1", "1000", "0", "60", "1", "1", "1:0" }
            fields[field] = bad
            reject(table.concat(fields, "|"))
        end
    end
    reject("1|QX|0|1000")
    reject("1|QX|1|0")
    reject("1|QX|9007199254740991|1000")
    reject("1|QX|1|10000000000")
end)

test("malformed quest entries and false-valued duplicates are rejected", function()
    for _, entries in ipairs({ "0:0", "-1:0", "2147483648:0", "1.5:0", "1e1:0",
        "1:2", "1:true", "1:false", "1:", ":0", "1:00", "1:1:0", " 1:0", "1:0 ",
        ",", ",1:0", "1:0,", "1:0,,2:1", "1:0,1:1", "1:0,1:0", "1:1,1:0",
        "01:0,1:1", "1:0;2:1", "1:0\n" }) do
        reject("1|Q|1|1000|0|60|1|1|" .. entries)
    end
end)

test("encoders assert on invalid scalars maps statuses and oversized logs", function()
    local invalid = {
        { 0, 1000, 0, 60, {} }, { 9007199254740991, 1000, 0, 60, {} },
        { 1.5, 1000, 0, 60, {} }, { "1", 1000, 0, 60, {} },
        { 1, 0, 0, 60, {} }, { 1, 10000000000, 0, 60, {} },
        { 1, 1000.5, 0, 60, {} }, { 1, 1000, -1, 60, {} },
        { 1, 1000, 2147483648, 60, {} }, { 1, 1000, 0.5, 60, {} },
        { 1, 1000, 0, -1, {} }, { 1, 1000, 0, 1001, {} },
        { 1, 1000, 0, 1.5, {} }, { 1, 1000, 0, 60, false },
        { 1, 1000, 0, 60, { [0] = false } },
        { 1, 1000, 0, 60, { [2147483648] = true } },
        { 1, 1000, 0, 60, { [1.5] = true } },
        { 1, 1000, 0, 60, { ["1"] = false } },
        { 1, 1000, 0, 60, { [1] = 0 } },
        { 1, 1000, 0, 60, { [1] = "false" } },
        { 1, 1000, 0, 60, questLog(201) },
        { 0 / 0, 1000, 0, 60, {} }, { math.huge, 1000, 0, 60, {} },
    }
    for _, arguments in ipairs(invalid) do equal(pcall(Q.Encode, unpack(arguments)), false) end
    equal(pcall(Q.Encode, 1, 1000, 0, 60), false)
    for _, arguments in ipairs({ { 0, 1000 }, { 1, 0 }, { 1.5, 1000 },
        { 9007199254740991, 1000 }, { 1, 10000000000 }, { "1", 1000 } }) do
        equal(pcall(Q.EncodeStop, unpack(arguments)), false)
    end
end)

-- Atomic assembly, ordering watermarks, boundedness, and privacy withdrawal.
test("all four-fragment permutations expose only the completed snapshot", function()
    local parts = {
        fragment(1, 1, 4, { [1] = false }), fragment(1, 2, 4, { [2] = true }),
        fragment(1, 3, 4, { [3] = false }), fragment(1, 4, 4, { [4] = true }),
    }
    local used, order, permutations = {}, {}, 0
    local function visit()
        if #order == 4 then
            permutations = permutations + 1
            local state = Q.New()
            for index, part in ipairs(order) do
                equal(state:Apply("A", parts[part], 1000), index == 4)
                if index < 4 then equal(state.peers.A, nil) end
                equal(state.seen.A, 1)
            end
            sameMap(state.peers.A.quests, { [1] = false, [2] = true, [3] = false, [4] = true })
            equal(state.buffers.A, nil)
            return
        end
        for part = 1, 4 do
            if not used[part] then
                used[part], order[#order + 1] = true, part
                visit()
                used[part], order[#order] = nil, nil
            end
        end
    end
    visit()
    equal(permutations, 24)
end)

test("a maximum log reassembles in reverse order", function()
    local quests, state = questLog(200, 2147483448), Q.New()
    local messages = Q.Encode(9007199254740990, 1000, 2147483647, 1000, quests)
    for index = #messages, 1, -1 do
        equal(state:Apply("A", assert(Q.Decode(messages[index])), 1000), index == 1)
        if index > 1 then equal(state.peers.A, nil) end
    end
    sameMap(state.peers.A.quests, quests)
    equal(state.peers.A.revision, 9007199254740990)
    equal(state.peers.A.zoneID, 2147483647)
    equal(state.peers.A.level, 1000)
end)

test("partial replacement preserves the previous snapshot until completion", function()
    local state = Q.New()
    assert(state:Apply("A", snapshot(1, { [1] = false }), 1000))
    local old = state.peers.A
    equal(state:Apply("A", fragment(2, 2, 2, { [3] = false }), 1000), false)
    equal(state.peers.A, old)
    sameMap(state.peers.A.quests, { [1] = false })
    equal(state:Apply("A", fragment(2, 1, 2, { [2] = true }), 1000), true)
    assert(state.peers.A ~= old)
    sameMap(state.peers.A.quests, { [2] = true, [3] = false })
    sameMap(old.quests, { [1] = false })
end)

test("duplicate and conflicting copies of one part cannot replace accepted data", function()
    local state = Q.New()
    local first = fragment(1, 1, 2, { [1] = false })
    equal(state:Apply("A", first, 1000), false)
    equal(state:Apply("A", first, 1000), false)
    equal(state:Apply("A", fragment(1, 1, 2, { [1] = true, [9] = true }), 1000), false)
    equal(state.buffers.A.received, 1)
    equal(state.buffers.A.count, 1)
    assert(state:Apply("A", fragment(1, 2, 2, { [2] = true }), 1000))
    sameMap(state.peers.A.quests, { [1] = false, [2] = true })
    equal(state:Apply("A", first, 1000), false)
end)

test("conflicting headers never enter an assembly", function()
    local state = Q.New()
    equal(state:Apply("A", fragment(1, 1, 2, { [1] = false }), 1000), false)
    for _, packet in ipairs({
        fragment(1, 2, 2, { [2] = true }, 1001),
        fragment(1, 2, 2, { [2] = true }, 1000, 1),
        fragment(1, 2, 2, { [2] = true }, 1000, 0, 61),
        fragment(1, 2, 3, { [2] = true }),
    }) do
        equal(state:Apply("A", packet, 1000), false)
        equal(state.buffers.A.received, 1)
        equal(state.buffers.A.count, 1)
        equal(state.peers.A, nil)
    end
    assert(state:Apply("A", fragment(1, 2, 2, { [2] = true }), 1000))
end)

test("cross-part duplicate IDs reject the entire incoming part including false status", function()
    for _, complete in ipairs({ false, true }) do
        local state = Q.New()
        equal(state:Apply("A", fragment(1, 1, 2, { [10] = complete }), 1000), false)
        equal(state:Apply("A", fragment(1, 2, 2, { [1] = true, [10] = not complete }), 1000), false)
        equal(state.peers.A, nil)
        sameMap(state.buffers.A.quests, { [10] = complete })
        equal(state.buffers.A.received, 1)
        assert(state:Apply("A", fragment(1, 2, 2, { [20] = false }), 1000))
        sameMap(state.peers.A.quests, { [10] = complete, [20] = false })
    end
end)

test("newest in-progress revision blocks older snapshots and never mixes fragments", function()
    local state = Q.New()
    assert(state:Apply("A", snapshot(1, { [1] = false }), 1000))
    equal(state:Apply("A", fragment(3, 1, 2, { [30] = false }), 1000), false)
    equal(state:Apply("A", snapshot(2, { [2] = true }), 1000), false)
    equal(state:Apply("A", stop(2), 1000), false)
    equal(state:Apply("A", fragment(4, 2, 2, { [41] = true }), 1000), false)
    equal(state:Apply("A", fragment(3, 2, 2, { [31] = true }), 1000), false)
    equal(state.peers.A.revision, 1)
    equal(state.buffers.A.revision, 4)
    equal(state.seen.A, 4)
    sameMap(state.buffers.A.quests, { [41] = true })
    assert(state:Apply("A", fragment(4, 1, 2, { [40] = false }), 1000))
    sameMap(state.peers.A.quests, { [40] = false, [41] = true })
end)

test("completed revisions cannot be replayed with changed data or timestamps", function()
    local state = Q.New()
    assert(state:Apply("A", snapshot(2, { [1] = false }), 1000))
    local peer = state.peers.A
    equal(state:Apply("A", snapshot(2, { [1] = true }, 1001), 1001), false)
    equal(state:Apply("A", snapshot(1, { [2] = true }, 1001), 1001), false)
    equal(state:Apply("A", stop(2, 1001), 1001), false)
    equal(state.peers.A, peer)
    equal(peer.sentAt, 1000)
end)

test("withdrawal removes published and buffered data and prevents resurrection", function()
    local state = Q.New()
    assert(state:Apply("A", snapshot(1, { [1] = false }), 1000))
    equal(state:Apply("A", fragment(2, 1, 2, { [2] = false }), 1000), false)
    assert(state:Apply("A", stop(3), 1000))
    equal(state.peers.A, nil)
    equal(state.buffers.A, nil)
    equal(state.seen.A, 3)
    equal(state:Apply("A", fragment(2, 2, 2, { [3] = true }), 1000), false)
    equal(state:Apply("A", snapshot(3, { [4] = true }), 1000), false)
    equal(state:Apply("A", snapshot(1, { [1] = false }), 1000), false)
    equal(state:Apply("A", stop(3), 1000), false)
    equal(state.peers.A, nil)
    equal(state.buffers.A, nil)
    assert(state:Apply("A", snapshot(4, { [4] = false }), 1000))
end)

test("withdrawal without a completed peer still clears buffers and retains watermark", function()
    local state = Q.New()
    equal(state:Apply("A", fragment(1, 1, 2, { [1] = false }), 1000), false)
    equal(state:Apply("A", stop(2), 1000), false)
    equal(state.buffers.A, nil)
    equal(state.seen.A, 2)
    equal(state:Apply("A", fragment(1, 2, 2, { [2] = false }), 1000), false)
    equal(state:Apply("B", stop(10), 1000), false)
    equal(state.seen.B, 10)
    equal(state:Apply("B", snapshot(9, {}), 1000), false)
    equal(state:Prune(2000), false)
    equal(state.seen.B, 10)
end)

test("assemblies from different senders remain independent", function()
    local state = Q.New()
    equal(state:Apply("A", fragment(2, 1, 2, { [1] = false }), 1000), false)
    equal(state:Apply("B", fragment(1, 2, 2, { [2] = true }), 1000), false)
    equal(state:Apply("A", stop(3), 1000), false)
    assert(state:Apply("B", fragment(1, 1, 2, { [1] = true }), 1000))
    equal(state.peers.A, nil)
    sameMap(state.peers.B.quests, { [1] = true, [2] = true })
end)

test("one assembly accepts at most 32 distinct parts", function()
    local state = Q.New()
    for part = 32, 1, -1 do
        equal(state:Apply("A", fragment(1, part, 32, { [part] = false }), 1000), part == 1)
        if part > 1 then
            equal(count(state.buffers), 1)
            assert(count(state.buffers.A.chunks) <= 32)
        end
    end
    equal(count(state.peers.A.quests), 32)
    equal(state.buffers.A, nil)
end)

test("aggregate quest cap rejects overflowing parts without partial mutation", function()
    local state = Q.New()
    for part = 1, 28 do
        equal(state:Apply("A", fragment(1, part, 29, questLog(7, (part - 1) * 7 + 1)), 1000), false)
    end
    equal(state.buffers.A.count, 196)
    equal(state:Apply("A", fragment(1, 29, 29, questLog(5, 197)), 1000), false)
    equal(state.buffers.A.count, 196)
    equal(count(state.buffers.A.quests), 196)
    equal(state.buffers.A.received, 28)
    equal(state.peers.A, nil)
    assert(state:Apply("A", fragment(1, 29, 29, questLog(4, 197)), 1000))
    equal(count(state.peers.A.quests), 200)
end)

-- Freshness uses packet clocks, not receipt time or duplicate arrivals.
test("stale and implausibly future packets cannot advance watermarks", function()
    for _, sentAt in ipairs({ 925, 924, 1006 }) do
        for _, packet in ipairs({ snapshot(9, {}, sentAt), stop(9, sentAt),
            fragment(9, 1, 2, { [1] = false }, sentAt) }) do
            local state = Q.New()
            assert(state:Apply("A", snapshot(1, { [2] = true }), 1000))
            local peer = state.peers.A
            equal(state:Apply("A", packet, 1000), false)
            equal(state.peers.A, peer)
            equal(state.buffers.A, nil)
            equal(state.seen.A, 1)
        end
    end
end)

test("TTL and future-skew boundary values are accepted exactly", function()
    local state = Q.New()
    assert(state:Apply("A", snapshot(1, {}, 926), 1000))
    assert(state:Apply("B", snapshot(1, {}, 1005), 1000))
    equal(state.peers.A.sentAt, 926)
    equal(state.peers.B.sentAt, 1005)
    assert(state:Prune(1001))
    equal(state.peers.A, nil)
    assert(state.peers.B)
end)

test("pruning expired peers preserves revision ordering and allows a newer snapshot", function()
    local state = Q.New()
    assert(state:Apply("A", snapshot(2, { [1] = false }), 1000))
    equal(state:Prune(1074), false)
    assert(state:Prune(1075))
    equal(state.peers.A, nil)
    equal(state.seen.A, 2)
    equal(state:Prune(1075), false)
    equal(state:Apply("A", snapshot(2, { [2] = true }, 1075), 1075), false)
    equal(state:Apply("A", snapshot(1, {}, 1075), 1075), false)
    assert(state:Apply("A", snapshot(3, {}, 1075), 1075))
end)

test("partial buffers expire on packet time and cannot restart the same revision", function()
    local state = Q.New()
    equal(state:Apply("A", fragment(2, 1, 2, { [1] = false }), 1000), false)
    equal(state:Apply("A", fragment(2, 1, 2, { [1] = false }), 1074), false)
    equal(state:Prune(1074), false)
    assert(state:Prune(1075))
    equal(state.buffers.A, nil)
    equal(state.seen.A, 2)
    equal(state:Apply("A", fragment(2, 2, 2, { [2] = true }), 1075), false)
    equal(state:Apply("A", fragment(2, 1, 2, { [1] = true }, 1075), 1075), false)
    equal(state:Apply("A", snapshot(1, {}, 1075), 1075), false)
    assert(state:Apply("A", snapshot(3, {}, 1075), 1075))
end)

test("partial updates do not refresh the previous completed snapshot", function()
    local state = Q.New()
    assert(state:Apply("A", snapshot(1, { [1] = false }), 1000))
    equal(state:Apply("A", fragment(2, 1, 2, { [2] = false }, 1050), 1050), false)
    assert(state:Prune(1075))
    equal(state.peers.A, nil)
    assert(state.buffers.A)
    equal(state.seen.A, 2)
    assert(state:Apply("A", fragment(2, 2, 2, { [3] = true }, 1050), 1075))
    equal(state.peers.A.sentAt, 1050)
    sameMap(state.peers.A.quests, { [2] = false, [3] = true })
end)

test("incomplete newer revisions cannot refresh their clock through conflicting headers", function()
    local state = Q.New()
    equal(state:Apply("A", fragment(2, 1, 2, { [1] = false }), 1000), false)
    equal(state:Apply("A", fragment(2, 2, 2, { [2] = true }, 1074), 1074), false)
    equal(state.buffers.A.sentAt, 1000)
    assert(state:Prune(1075))
    equal(state:Apply("A", fragment(2, 1, 2, { [1] = false }, 1075), 1075), false)
    equal(state.buffers.A, nil)
end)

test("pruning guards backward clock jumps and honors namespace timeout", function()
    local state = Q.New()
    assert(state:Apply("A", snapshot(1, {}), 1000))
    equal(state:Apply("B", fragment(2, 1, 2, {}), 1000), false)
    assert(state:Prune(994))
    equal(state.peers.A, nil)
    equal(state.buffers.B, nil)
    equal(state.seen.A, 1)
    equal(state.seen.B, 2)
    local original = ns.TIMEOUT
    ns.TIMEOUT = 10
    local ok, err = pcall(function()
        equal(state:Apply("C", snapshot(1, {}, 990), 1000), false)
        assert(state:Apply("C", snapshot(1, {}, 991), 1000))
        assert(state:Prune(1001))
        equal(state.peers.C, nil)
    end)
    ns.TIMEOUT = original
    assert(ok, err)
end)

-- Availability, intersections, and ownership of mutable tables.
test("empty sharing differs from unavailable data and partial state is never zero sharing", function()
    local state = Q.New()
    equal(state.peers.A, nil)
    equal(state:Apply("A", fragment(1, 1, 2, {}), 1000), false)
    equal(state.peers.A, nil)
    assert(state:Apply("A", fragment(1, 2, 2, { [1] = false }), 1000))
    equal(#Q.Common({ [1] = false }, state.peers.A.quests), 1)
    equal(state:Apply("A", fragment(2, 1, 2, {}), 1000), false)
    equal(#Q.Common({ [1] = false }, state.peers.A.quests), 1)
    assert(state:Apply("A", fragment(2, 2, 2, {}), 1000))
    assert(state.peers.A)
    equal(count(state.peers.A.quests), 0)
    equal(#Q.Common({ [1] = false }, state.peers.A.quests), 0)
    assert(state:Apply("A", stop(3), 1000))
    equal(state.peers.A, nil)
end)

test("common quests are sorted and include every boolean status combination", function()
    local ours = { [40] = true, [10] = false, [30] = true, [20] = false, [50] = false }
    local theirs = { [40] = true, [30] = false, [20] = true, [10] = false, [60] = true }
    local common = Q.Common(ours, theirs)
    equal(#common, 4)
    for index, id in ipairs({ 10, 20, 30, 40 }) do
        equal(common[index].questID, id)
        equal(common[index].localComplete, ours[id])
        equal(common[index].peerComplete, theirs[id])
    end
    equal(#Q.Common({}, theirs), 0)
    equal(#Q.Common(ours, {}), 0)
    equal(#Q.Common(nil, theirs), 0)
    equal(#Q.Common(ours, nil), 0)
end)

test("encoding decoding assembly and common results do not alias input quest maps", function()
    local quests = { [1] = false, [2] = true }
    local messages = Q.Encode(1, 1000, 0, 60, quests)
    local packet = assert(Q.Decode(messages[1]))
    packet.quests[1] = true
    equal(quests[1], false)
    local decodedAgain = assert(Q.Decode(messages[1]))
    equal(decodedAgain.quests[1], false)
    local state = Q.New()
    assert(state:Apply("A", decodedAgain, 1000))
    decodedAgain.quests[1], decodedAgain.quests[3] = true, false
    sameMap(state.peers.A.quests, quests)
    local first = fragment(2, 1, 2, { [3] = false })
    equal(state:Apply("A", first, 1000), false)
    first.quests[3], first.quests[99], first.zoneID = true, true, 99
    sameMap(state.buffers.A.quests, { [3] = false })
    local second = fragment(2, 2, 2, { [4] = true })
    assert(state:Apply("A", second, 1000))
    second.quests[4] = false
    sameMap(state.peers.A.quests, { [3] = false, [4] = true })
    equal(state.peers.A.zoneID, 0)
    local common = Q.Common(quests, { [1] = true })
    common[1].questID, common[1].localComplete = 999, true
    equal(quests[1], false)
    equal(Q.Common(quests, { [1] = true })[1].questID, 1)
end)

print(string.format("\n%d passed; %d failed", passed, failed))
if failed > 0 then os.exit(1) end
