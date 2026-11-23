-- Invoked by tests/run.lua with its simulated WoW client and UI fixtures.
local test, equal, client, openUI, packet, suggestedGroup = ...

local function party(options)
    options = options or {}
    options.partyRoles = options.partyRoles or { player = "TANK", party1 = "HEALER" }
    local c = client(options)
    c.homeGroup, c.partyMembers = true, { "Guest-OtherRealm" }
    return c
end

local function queued(c)
    c.ns.SetQueued(true)
    assert(c.ns.queued, c.ns.JoinQueueDisabledReason())
    c:advance(8)
    assert(not c.ns.QueueUpdatePending())
    return c.ns.state.records[c.ns.playerName]
end

local function link(sender, receiver)
    local original = sender.env.C_ChatInfo.SendAddonMessage
    sender.env.C_ChatInfo.SendAddonMessage = function(prefix, message, channel)
        local result = original(prefix, message, channel)
        if result == 0 then
            receiver.now = math.max(receiver.now, sender.now)
            receiver:fire("CHAT_MSG_ADDON", prefix, message, channel, sender.ns.playerName)
        end
        return result
    end
end

local function controls(c)
    local widgets, join, roles = openUI(c), nil, {}
    for _, control in ipairs(widgets) do
        if control.guildQueueKind == "queue" then join = control end
        if control.guildQueueKind == "role" then roles[control.role] = control end
    end
    return join, roles, widgets
end

local function noPartyPacketsAfter(c, index)
    for i = index + 1, #c.sent do
        local p = c.ns.Protocol.Decode(c.sent[i].text)
        assert(not p or (p.kind ~= "B" and p.kind ~= "C" and p.kind ~= "S"))
    end
end

test("party leader queues non-guild non-addon members using native roles and leader dungeons", function()
    local c = party({ saved = { roles = 0, dungeons = { [2] = true } }, roster = { "Self-TestRealm" } })
    local record = queued(c)
    equal(record.partyLeader, c.ns.playerName) equal(record.partySize, 2)
    equal(record.roles, 1) equal(c.ns.prefs.roles, 0)
    assert(record.dungeons[2] and not record.dungeons[1])
    local guest = c.ns.state:Get("Guest-OtherRealm")
    equal(guest.roles, 2) equal(guest.partyLeader, c.ns.playerName)
    assert(guest.dungeons[2]) equal(#c.ns.state:Sorted(), 2)
    equal(c.ns.state.records[guest.name], nil)
    equal(c.ns.OnlineAddonCount(), 1) equal(#c.invites, 0)
    for _, message in ipairs(c.sent) do equal(message.channel, "GUILD") assert(#message.text <= 255) end
end)

test("party fragments expose no partial group locally or on another guild client", function()
    local c, observer = party(), client({ characterName = "Observer" })
    link(c, observer)
    c.ns.SetQueued(true)
    c:advance(3) -- X, header, first member; the leader/member pair is not complete.
    equal(#c.ns.state:Sorted(), 0) equal(#observer.ns.state:Sorted(), 0)
    c:advance(1)
    equal(#c.ns.state:Sorted(), 2) equal(#observer.ns.state:Sorted(), 2)
    equal(observer.ns.OnlineAddonCount(), 2) -- Not three: Guest does not run the addon.
    equal(#observer.ns.groups, 1) equal(#observer.ns.groups[1].members, 2)
    equal(#c.invites, 0) equal(#observer.invites, 0)
end)

test("nonleaders queue individually through API slash command and UI with flexible class roles", function()
    for _, action in ipairs({ "api", "slash", "ui" }) do
        local c = party({ partyLeader = false, roleAssignedUnavailable = true, allowedRoles = 6,
            saved = { roles = 6, dungeons = { [1] = true } } })
        equal(c.ns.JoinQueueDisabledReason(), nil)
        local join, roles = controls(c)
        equal(join.text, "Join queue") assert(join.enabled)
        assert(not c.ns.UsesPartyRoles()) equal(c.ns.QueueRoles(), 6)
        assert(roles[2].shown and roles[2].enabled and roles[2]:GetChecked())
        assert(roles[4].shown and roles[4].enabled and roles[4]:GetChecked())
        assert(roles[1].shown and not roles[1].enabled)
        if action == "api" then c.ns.SetQueued(true)
        elseif action == "slash" then c.env.SlashCmdList.GUILDQUEUE("join")
        else join.scripts.OnClick(join) end
        c:advance(8)
        assert(c.ns.queued and not c.ns.QueueUpdatePending())
        local record = c.ns.state.records[c.ns.playerName]
        equal(record.roles, 6) equal(record.partyMembers, nil)
        equal(#c.ns.state:Sorted(), 1) equal(join.text, "Leave queue")
        for _, message in ipairs(c.sent) do
            local p = c.ns.Protocol.Decode(message.text)
            assert(p.kind ~= "B" and p.kind ~= "C")
        end
        equal(#c.invites, 0)
    end
end)

local function memberPartyClients()
    local member = party({ characterName = "Member", partyLeader = false, allowedRoles = 6,
        saved = { roles = 6, dungeons = { [1] = true } },
        partyRoles = { player = "HEALER", party1 = "TANK" } })
    local leader = party({ characterName = "Leader",
        saved = { roles = 0, dungeons = { [2] = true } } })
    local observer = client({ characterName = "Observer" })
    member.partyMembers, leader.partyMembers = { leader.ns.playerName }, { member.ns.playerName }
    link(member, leader) link(member, observer)
    link(leader, member) link(leader, observer)
    queued(member)
    return member, leader, observer
end

test("only a complete leader listing overrides individual roles and dungeons without duplicates", function()
    local member, leader, observer = memberPartyClients()
    local join, roles, widgets = controls(member)
    leader.ns.SetQueued(true) leader:advance(3)
    equal(observer.ns.state:Get(member.ns.playerName).roles, 6)
    equal(member.ns.PartyQueueLeader(), nil)
    leader:advance(1)
    for _, c in ipairs({ member, leader, observer }) do
        local effective = c.ns.state:Get(member.ns.playerName)
        equal(effective.partyLeader, leader.ns.playerName) equal(effective.roles, 2)
        assert(effective.dungeons[2] and not effective.dungeons[1])
        equal(#c.ns.state:Sorted(), 2)
        equal(c.ns.state.records[member.ns.playerName].roles, 6)
        equal(#c.invites, 0)
    end
    assert(member.ns.queued and not member.ns.QueueUpdatePending())
    equal(member.ns.PartyQueueLeader(), leader.ns.playerName)
    assert(roles[2].shown and roles[2]:GetChecked() and roles[4].shown and roles[4]:GetChecked())
    local statusShown = false
    for _, control in ipairs(widgets) do if control.text == "Party queued" then statusShown = true end end
    assert(statusShown)
    join.scripts.OnEnter(join)
    local tooltip = table.concat(member.tooltip.lines, "\n")
    assert(tooltip:find(leader.ns.playerName, 1, true) and tooltip:find("override", 1, true))
    observer.ns.prefs.dungeons = { [2] = true }
    local lists = observer.ns.GetRoleLists()
    equal(#lists[1], 1) equal(#lists[2], 1) equal(#lists[4], 0)
    member:advance(22)
    equal(#observer.ns.state:Sorted(), 2)
    equal(observer.ns.state:Get(member.ns.playerName).roles, 2)
end)

test("leader withdrawal restores the latest individual selections with original queue age", function()
    local member, leader, observer = memberPartyClients()
    local age = member.ns.joinedAt
    queued(leader)
    member.ns.prefs.roles, member.ns.prefs.dungeons = 4, { [3] = true }
    member.ns.PreferencesChanged()
    assert(member.ns.queued and member.ns.QueueUpdatePending())
    equal(member.ns.PartyQueueLeader(), leader.ns.playerName)
    member:advance(2)
    equal(observer.ns.state:Get(member.ns.playerName).roles, 2)
    leader.ns.SetQueued(false) leader:advance(2)
    for _, c in ipairs({ member, leader, observer }) do
        local effective = c.ns.state:Get(member.ns.playerName)
        equal(effective.partyLeader, nil) equal(effective.roles, 4)
        assert(effective.dungeons[3] and not effective.dungeons[2])
        equal(effective.joinedAt, age) equal(#c.ns.state:Sorted(), 1)
        equal(#c.invites, 0)
    end
    assert(member.ns.queued and not member.ns.QueueUpdatePending())
    equal(member.ns.PartyQueueLeader(), nil)
end)

test("leaving an overridden individual queue cannot withdraw the party or later rejoin", function()
    local member, leader, observer = memberPartyClients()
    queued(leader)
    member.ns.SetQueued(false) member:advance(2)
    assert(not member.ns.queued)
    for _, c in ipairs({ member, leader, observer }) do
        equal(c.ns.state.records[member.ns.playerName], nil)
        equal(c.ns.state:Get(member.ns.playerName).partyLeader, leader.ns.playerName)
        equal(#c.ns.state:Sorted(), 2)
    end
    equal(member.ns.PartyQueueLeader(), leader.ns.playerName)
    leader.ns.SetQueued(false) leader:advance(2) member:advance(22)
    equal(member.ns.PartyQueueLeader(), nil)
    for _, c in ipairs({ member, leader, observer }) do
        equal(c.ns.state:Get(member.ns.playerName), nil)
        equal(#c.invites, 0)
    end
end)

test("expired party listings uncover independently heartbeating individual members", function()
    local member, leader, observer = memberPartyClients()
    local age = member.ns.joinedAt
    queued(leader)
    -- The leader no longer ticks; the member continues its own S heartbeats.
    member:advance(member.ns.TIMEOUT + 2)
    -- Receiving packets alone advances the observer only to the last send time.
    observer.now = member.now observer:advance(1)
    for _, c in ipairs({ member, observer }) do
        local effective = c.ns.state:Get(member.ns.playerName)
        equal(effective.partyLeader, nil) equal(effective.roles, 6)
        equal(effective.joinedAt, age) equal(#c.ns.state:Sorted(), 1)
        equal(#c.invites, 0)
    end
    assert(member.ns.queued) equal(member.ns.PartyQueueLeader(), nil)
end)

test("removing an individually queued member uncovers that entry without splitting the remaining party", function()
    local member, leader, observer = memberPartyClients()
    leader.partyMembers[2], leader.partyRoles.party2 = "Guest-OtherRealm", "DAMAGER"
    queued(leader)
    equal(#observer.ns.state:Sorted(), 3)
    member.homeGroup, member.partyMembers = false, {}
    member:fire("GROUP_ROSTER_UPDATE")
    leader.partyMembers, leader.partyRoles.party1 = { "Guest-OtherRealm" }, "DAMAGER"
    leader:fire("GROUP_ROSTER_UPDATE") leader:advance(8)
    for _, c in ipairs({ member, leader, observer }) do
        equal(c.ns.state:Get(member.ns.playerName).partyLeader, nil)
        equal(c.ns.state:Get(member.ns.playerName).roles, 6)
        equal(c.ns.state:Get("Guest-OtherRealm").partyLeader, leader.ns.playerName)
        equal(#c.ns.state:Sorted(), 3) equal(#c.invites, 0)
    end
    assert(member.ns.queued)
end)

test("nonleader selections can be edited through real role controls while queued", function()
    local c = party({ partyLeader = false, saved = { roles = 6, dungeons = { [1] = true } } })
    queued(c)
    local age = c.ns.joinedAt
    local _, roles = controls(c)
    roles[4]:SetChecked(false) roles[4].scripts.OnClick(roles[4]) c:advance(2)
    equal(c.ns.state.records[c.ns.playerName].roles, 2)
    roles[1]:SetChecked(true) roles[1].scripts.OnClick(roles[1]) c:advance(2)
    equal(c.ns.state.records[c.ns.playerName].roles, 3)
    equal(c.ns.joinedAt, age) equal(#c.ns.state:Sorted(), 1)
    equal(c.ns.state.records[c.ns.playerName].partyMembers, nil)
    equal(#c.invites, 0)
end)

test("individual queues do not depend on peers' roster data and pause through unknown leadership", function()
    for _, unavailable in ipairs({ "partyLeaderUnavailable", "partyLeaderError" }) do
        local c = party({ partyLeader = false })
        queued(c)
        local age = c.ns.joinedAt
        c.partyMembers, c.partyCount = {}, 1
        c:fire("GROUP_ROSTER_UPDATE") c:advance(2)
        assert(c.ns.queued and not c.ns.QueueUpdatePending())
        c[unavailable] = true c:fire("PARTY_LEADER_CHANGED") c:advance(3)
        assert(c.ns.queued and c.ns.QueueUpdatePending()) equal(#c.ns.state:Sorted(), 0)
        c[unavailable] = false c:fire("PARTY_LEADER_CHANGED") c:advance(3)
        assert(c.ns.queued and not c.ns.QueueUpdatePending()) equal(c.ns.joinedAt, age)
        equal(#c.ns.state:Sorted(), 1) equal(#c.invites, 0)
    end
end)

test("nonleader individual queueing cannot bypass raid or instance restrictions", function()
    for _, mode in ipairs({ "raid", "instanceGroup" }) do
        local c = party({ partyLeader = false })
        c[mode] = true
        assert(c.ns.JoinQueueDisabledReason())
        c.ns.SetQueued(true) assert(not c.ns.queued)
        c:advance(3) noPartyPacketsAfter(c, 0)
        equal(#c.invites, 0)
    end
end)

test("individually queued nonleaders cannot start a native-party recruitment batch", function()
    local c = client({ partyLeader = false })
    local group = suggestedGroup(c)
    c.homeGroup, c.partyMembers = true, { group.members[2].name }
    c:fire("GROUP_ROSTER_UPDATE")
    assert(c.ns.queued)
    local reason = c.ns.CreatePartyDisabledReason(group)
    assert(reason and reason:find("leader", 1, true))
    assert(not c.ns.CreateParty(group))
    c:advance(3) equal(#c.invites, 0)
end)

test("a non-guild leader still cannot publish a party to the guild channel", function()
    local c = party({ noGuild = true })
    c.ns.SetQueued(true) assert(not c.ns.queued)
    c:advance(10) equal(#c.sent, 0) equal(#c.ns.state:Sorted(), 0)
end)

test("party UI hides addon role selection without changing saved solo preferences", function()
    local c = party({ saved = { roles = 6, dungeons = { [1] = true } } })
    local join, roles = controls(c)
    equal(join.text, "Queue party") assert(join.enabled)
    equal(c.ns.QueueRoles(), 1)
    for role, control in pairs(roles) do
        assert(not control.enabled and not control.shown)
        equal(control:GetChecked(), role == 1)
    end
    roles[4]:SetChecked(true) roles[4].scripts.OnClick(roles[4])
    equal(c.ns.prefs.roles, 6)
    join.scripts.OnClick(join) c:advance(8)
    equal(join.text, "Leave party queue") assert(join.enabled)
    join.scripts.OnClick(join)
    equal(join.text, "Queue party") equal(c.ns.prefs.roles, 6)
    equal(#c.ns.state:Sorted(), 0) equal(#c.invites, 0)
end)

test("party role messaging replaces controls before queueing and during queued or paused updates", function()
    local c = party()
    local _, roles, widgets = controls(c)
    local heading, hint, prompt, choose
    for _, control in ipairs(widgets) do
        if control.guildQueueKind == "partyRoleHeading" then heading = control end
        if control.guildQueueKind == "partyRoleHint" then hint = control end
        if control.text == "Play as" then prompt = control end
        if control.text == "Choose 1 or more" then choose = control end
    end
    assert(heading and hint and prompt and choose)
    local function replaced()
        assert(heading.shown and hint.shown and not prompt.shown and not choose.shown)
        for _, control in pairs(roles) do assert(not control.shown) end
    end
    replaced()
    equal(heading.text, "Party roles")
    assert(hint.text:find("WoW's party controls", 1, true))
    assert(hint.text:find("automatically", 1, true))
    -- Text replaces only the existing role area, above the divider at y=156.
    for _, control in ipairs({ heading, hint }) do
        assert(control.point[2] >= 14)
        assert(control.point[2] + control:GetWidth() <= control.parent:GetWidth())
        assert(-control.point[3] + control:GetHeight() < 156)
    end
    assert(hint:GetStringHeight() <= hint:GetHeight())
    local count = #widgets
    for _ = 1, 10 do c.ns.RefreshUI() replaced() end
    equal(#widgets, count)
    queued(c) replaced()
    c.partyRoles.party1 = "NONE" c:fire("PLAYER_ROLES_ASSIGNED")
    assert(c.ns.queued and c.ns.QueueUpdatePending()) replaced()
    local groupAPI = c.env.IsInGroup
    c.env.IsInGroup = function() return nil end
    c:fire("GROUP_ROSTER_UPDATE") replaced() -- Pending party intent still uses WoW roles.
    c.env.IsInGroup = groupAPI
    c.ns.SetQueued(false) replaced() -- Still in a native party, so no addon role editing.
    equal(#c.invites, 0)
end)

test("leaving a party restores saved solo role controls and clears the old role tooltip on grouping", function()
    local c = client({ saved = { roles = 6, dungeons = { [1] = true } } })
    local _, roles, widgets = controls(c)
    local prompt, choose, heading, hint
    for _, control in ipairs(widgets) do
        if control.text == "Play as" then prompt = control end
        if control.text == "Choose 1 or more" then choose = control end
        if control.guildQueueKind == "partyRoleHeading" then heading = control end
        if control.guildQueueKind == "partyRoleHint" then hint = control end
    end
    for _ = 1, 2 do
        assert(not c.ns.UsesPartyRoles())
        assert(prompt.shown and choose.shown and not heading.shown and not hint.shown)
        assert(roles[2].shown and roles[2].enabled and roles[2]:GetChecked())
        assert(roles[4].shown and roles[4]:GetChecked() and not roles[1]:GetChecked())
        roles[2].scripts.OnEnter(roles[2]) assert(c.tooltip.shown)
        c.homeGroup, c.partyMembers = true, { "Guest-OtherRealm" }
        c.partyRoles = { player = "TANK", party1 = "HEALER" }
        c:fire("GROUP_ROSTER_UPDATE")
        assert(c.ns.UsesPartyRoles() and heading.shown and hint.shown)
        assert(not roles[2].shown and not c.tooltip.shown)
        equal(c.ns.prefs.roles, 6)
        c.homeGroup, c.partyMembers = false, {}
        c:fire("GROUP_ROSTER_UPDATE")
    end
    assert(prompt.shown and choose.shown and not heading.shown and not hint.shown)
    equal(c.ns.prefs.roles, 6)
    assert(not c.ns.queued)
    equal(#c.sent, 0) equal(#c.invites, 0)
end)

test("leaders with unavailable roles or leadership still see read-only WoW party instructions", function()
    for _, options in ipairs({ { partyLeaderUnavailable = true }, { roleAssignedUnavailable = true } }) do
        local c = party(options)
        local join, roles, widgets = controls(c)
        assert(not join.enabled)
        local heading, hint
        for _, control in ipairs(widgets) do
            if control.guildQueueKind == "partyRoleHeading" then heading = control end
            if control.guildQueueKind == "partyRoleHint" then hint = control end
        end
        assert(heading.shown and hint.shown)
        for _, control in pairs(roles) do assert(not control.shown and not control.enabled) end
        assert(not c.ns.queued)
        equal(#c.sent, 0) equal(#c.invites, 0)
    end
end)

test("party queue uses assigned roles even when the solo class role API is unavailable", function()
    local c = party({ noRoleAPI = true, saved = { roles = 0, dungeons = { [1] = true } } })
    equal(queued(c).roles, 1) equal(c.ns.prefs.roles, 0)
end)

test("unknown unassigned erroneous or restricted party roles fail closed", function()
    for _, role in ipairs({ "NONE", "UNKNOWN", "DAMAGETANK" }) do
        local c = party({ partyRoles = { player = "TANK", party1 = role } })
        assert(c.ns.JoinQueueDisabledReason():find("role", 1, true))
        c.ns.SetQueued(true) assert(not c.ns.queued)
    end
    local c = party({ roleAssignedUnavailable = true })
    c.ns.SetQueued(true) assert(not c.ns.queued)
    c.env.UnitGroupRolesAssigned = function() error("Unavailable") end
    c.ns.SetQueued(true) assert(not c.ns.queued)
    c.env.UnitGroupRolesAssigned = function() return "HIDDEN_ROLE" end
    c.env.hasanysecretvalues = function(...)
        for i = 1, select("#", ...) do if select(i, ...) == "HIDDEN_ROLE" then return true end end
        return false
    end
    c.ns.SetQueued(true) assert(not c.ns.queued)
    assert(not table.concat(c.messages, "\n"):find("HIDDEN_ROLE", 1, true))
end)

test("unavailable leadership offline members and invalid role capacity prevent party queueing", function()
    for _, options in ipairs({ { partyLeaderUnavailable = true }, { partyLeaderError = true },
        { partyConnected = { party1 = false } }, { partyRoles = { player = "TANK", party1 = "TANK" } },
        { partyRoles = { player = "HEALER", party1 = "HEALER" } } }) do
        local c = party(options)
        assert(c.ns.JoinQueueDisabledReason())
        c.ns.SetQueued(true) assert(not c.ns.queued)
    end
end)

test("raid and instance groups cannot enter the dungeon party queue", function()
    local c = party() c.raid = true
    assert(c.ns.JoinQueueDisabledReason():lower():find("raid", 1, true))
    c.ns.SetQueued(true) assert(not c.ns.queued)
    c.raid, c.instanceGroup = false, true
    assert(c.ns.JoinQueueDisabledReason():find("instance", 1, true))
    c.ns.SetQueued(true) assert(not c.ns.queued)
end)

test("party queue rejects duplicate realm identities and unavailable members", function()
    local c = party()
    c.partyMembers = { "Self-TestRealm" }
    c.ns.SetQueued(true) assert(not c.ns.queued)
    c.partyMembers = { "Guest-OtherRealm", "Guest-OtherRealm" }
    c.ns.SetQueued(true) assert(not c.ns.queued)
    c.partyMembers, c.partyCount = {}, 1
    c.ns.SetQueued(true) assert(not c.ns.queued)
end)

test("complete five-member party stays together and never sends automatic invitations", function()
    local c = party({ partyRoles = { player = "TANK", party1 = "HEALER", party2 = "DAMAGER",
        party3 = "DAMAGER", party4 = "DAMAGER" } })
    c.partyMembers = { "Guest-OtherRealm", "Second-OtherRealm", "Third-OtherRealm", "Fourth-OtherRealm" }
    equal(queued(c).partySize, 5)
    equal(#c.ns.groups, 1) equal(#c.ns.groups[1].members, 5)
    assert(c.ns.CreatePartyDisabledReason(c.ns.groups[1]):find("already", 1, true))
    c:advance(30) equal(#c.invites, 0) equal(#c.ns.state:Sorted(), 5)
end)

test("party heartbeats keep the previous complete snapshot visible during reassembly", function()
    local c, observer = party(), client({ characterName = "Observer" })
    link(c, observer) queued(c)
    local old = observer.ns.state.records[c.ns.playerName]
    local groups = observer.ns.groups
    c:advance(17) -- Heartbeat header and a member; the last complete party remains visible.
    equal(#observer.ns.state:Sorted(), 2)
    c:advance(3)
    equal(#observer.ns.state:Sorted(), 2)
    assert(observer.ns.state.records[c.ns.playerName].sentAt > old.sentAt)
    equal(observer.ns.groups, groups) -- Freshness-only commit does not rematch.
    equal(#c.invites, 0)
end)

test("party leave during multipart transmission clears pending parts without later resurrection", function()
    local c, observer = party(), client({ characterName = "Observer" })
    link(c, observer) c.ns.SetQueued(true) c:advance(3)
    assert(observer.ns.state.pending[c.ns.playerName])
    c.locked = true c.ns.SetQueued(false)
    equal(#c.ns.state:Sorted(), 0)
    c.locked = false c:advance(8)
    equal(#observer.ns.state:Sorted(), 0)
    equal(observer.ns.state.pending[c.ns.playerName], nil)
    local count = #c.sent c:advance(20) noPartyPacketsAfter(c, count)
end)

test("party updates coalesce to latest dungeon preferences after transport failure", function()
    local c, observer = party(), client({ characterName = "Observer" })
    link(c, observer) queued(c)
    local age = c.ns.joinedAt
    c.result = 9
    c.ns.prefs.dungeons = { [2] = true } c.ns.PreferencesChanged() c:advance(1)
    assert(c.ns.queued and c.ns.QueueUpdatePending()) equal(#c.ns.state:Sorted(), 0)
    c.ns.prefs.dungeons = { [3] = true } c.ns.PreferencesChanged()
    c.result = 0 c:advance(12)
    assert(not c.ns.QueueUpdatePending()) equal(c.ns.joinedAt, age)
    local record = observer.ns.state.records[c.ns.playerName]
    assert(record.dungeons[3] and not record.dungeons[1] and not record.dungeons[2])
    equal(#observer.ns.state:Sorted(), 2) equal(#c.invites, 0)
end)

test("assigned party role changes invalidate old local slots and preserve queue age", function()
    local c = party() queued(c)
    local age = c.ns.joinedAt
    c.partyRoles.party1 = "DAMAGER"
    c:fire("PLAYER_ROLES_ASSIGNED")
    assert(c.ns.queued and c.ns.QueueUpdatePending()) equal(#c.ns.state:Sorted(), 0)
    c:advance(8)
    equal(c.ns.state:Get("Guest-OtherRealm").roles, 4) equal(c.ns.joinedAt, age)
end)

test("invalid assigned roles withdraw the listing but retain leader intent through messaging lockdown", function()
    local c = party() queued(c)
    c.locked = true c.partyRoles.party1 = "NONE"
    c:fire("ROLE_CHANGED_INFORM", "party1", "HEALER", "NONE")
    assert(c.ns.queued and c.ns.QueueUpdatePending()) equal(#c.ns.state:Sorted(), 0)
    local count = #c.sent c.locked = false c:advance(10) noPartyPacketsAfter(c, count)
    c.partyRoles.party1 = "HEALER" c:fire("PLAYER_ROLES_ASSIGNED")
    c:advance(8) assert(c.ns.queued and not c.ns.QueueUpdatePending())
    equal(#c.ns.state:Sorted(), 2) equal(#c.invites, 0)
end)

test("party leadership handoff removes the old queue and requires the new leader to explicitly queue", function()
    local c = party() queued(c)
    c.partyLeader = false c:fire("PARTY_LEADER_CHANGED")
    assert(not c.ns.queued) equal(#c.ns.state:Sorted(), 0)
    local count = #c.sent c:advance(10) noPartyPacketsAfter(c, count)
    local individual = queued(c)
    equal(individual.partyMembers, nil) equal(#c.ns.state:Sorted(), 1)
    c.partyLeader = true c:fire("PARTY_LEADER_CHANGED") c:advance(2)
    assert(not c.ns.queued) equal(#c.ns.state:Sorted(), 0)
    equal(queued(c).partyLeader, c.ns.playerName)
    equal(#c.ns.state:Sorted(), 2)
end)

test("queued roster changes preserve individual nonleaders but never automatically enroll a whole party", function()
    for _, change in ipairs({ "join", "replace" }) do
        local c = party() queued(c)
        local age = c.ns.joinedAt
        if change == "join" then c.partyMembers[2] = "New-OtherRealm"
        else c.partyMembers = { "Different-OtherRealm" } end
        c:fire("GROUP_ROSTER_UPDATE")
        assert(c.ns.queued and c.ns.QueueUpdatePending()) equal(#c.ns.state:Sorted(), 0)
        c:advance(8) assert(not c.ns.QueueUpdatePending())
        equal(c.ns.joinedAt, age)
        equal(#c.ns.state:Sorted(), #c.partyMembers + 1)
        equal(#c.invites, 0)
    end
    local disbanded = party() queued(disbanded)
    disbanded.homeGroup, disbanded.partyMembers = false, {}
    disbanded:fire("GROUP_ROSTER_UPDATE")
    assert(not disbanded.ns.queued) equal(#disbanded.ns.state:Sorted(), 0)
    local count = #disbanded.sent disbanded:advance(8) noPartyPacketsAfter(disbanded, count)
    for _, isLeader in ipairs({ false, true }) do
        local c = client() queued(c)
        local age = c.ns.joinedAt
        c.homeGroup, c.partyMembers, c.partyLeader = true, { "Guest-OtherRealm" }, isLeader
        c:fire("GROUP_ROSTER_UPDATE") c:advance(2)
        equal(c.ns.queued, not isLeader)
        if isLeader then
            equal(#c.ns.state:Sorted(), 0)
        else
            equal(#c.ns.state:Sorted(), 1) equal(c.ns.joinedAt, age)
            equal(c.ns.state.records[c.ns.playerName].partyMembers, nil)
            c.homeGroup, c.partyMembers = false, {}
            c:fire("GROUP_ROSTER_UPDATE") c:advance(2)
            assert(c.ns.queued) equal(c.ns.joinedAt, age)
        end
        equal(#c.invites, 0)
    end
end)

test("lost roster and role events are still checked before every queued transmission", function()
    local c = party() queued(c)
    c.partyLeader = false c:advance(1)
    assert(not c.ns.queued) equal(#c.ns.state:Sorted(), 0)
    local d = party() d.ns.SetQueued(true) d:advance(2)
    d.partyRoles.party1 = "NONE" d:advance(1)
    assert(d.ns.queued and d.ns.QueueUpdatePending()) equal(#d.ns.state:Sorted(), 0)
    d.partyRoles.party1 = "HEALER" d:advance(8)
    assert(not d.ns.QueueUpdatePending())
end)

test("joining and leaving members update the remote listing atomically without resetting queue age", function()
    local c, observer = party(), client({ characterName = "Observer" })
    link(c, observer) queued(c)
    local age = c.ns.joinedAt
    c.partyMembers[2], c.partyRoles.party2 = "New-OtherRealm", "DAMAGER"
    c:fire("GROUP_ROSTER_UPDATE")
    assert(c.ns.queued and c.ns.QueueUpdatePending())
    c:advance(2) equal(#observer.ns.state:Sorted(), 2)
    c:advance(6) equal(#observer.ns.state:Sorted(), 3)
    equal(observer.ns.state:Get("New-OtherRealm").roles, 4)
    c.partyMembers, c.partyRoles = { "New-OtherRealm" }, { player = "TANK", party1 = "DAMAGER" }
    c:fire("GROUP_ROSTER_UPDATE") c:advance(8)
    equal(#observer.ns.state:Sorted(), 2)
    equal(observer.ns.state:Get("Guest-OtherRealm"), nil)
    assert(observer.ns.state:Get("New-OtherRealm"))
    equal(c.ns.joinedAt, age) equal(#c.invites, 0)
end)

test("a new member without an assigned role pauses publication and resumes when the role is assigned", function()
    local c, observer = party(), client({ characterName = "Observer" })
    link(c, observer) queued(c)
    local age = c.ns.joinedAt
    c.partyMembers[2], c.partyRoles.party2 = "New-OtherRealm", "NONE"
    c:fire("GROUP_ROSTER_UPDATE")
    assert(c.ns.queued and c.ns.QueueUpdatePending()) equal(#c.ns.state:Sorted(), 0)
    c:advance(2) equal(#observer.ns.state:Sorted(), 0)
    local join = controls(c)
    equal(join.text, "Leave party queue") assert(join.enabled)
    join.scripts.OnEnter(join)
    assert(table.concat(c.tooltip.lines, "\n"):find("role", 1, true))
    c.partyRoles.party2 = "DAMAGER" c:fire("PLAYER_ROLES_ASSIGNED")
    c:advance(8)
    assert(not c.ns.QueueUpdatePending()) equal(#observer.ns.state:Sorted(), 3)
    equal(c.ns.joinedAt, age) equal(#c.invites, 0)
end)

test("temporary roster lookup failure retains intent and recovers without a queue click", function()
    local c, observer = party(), client({ characterName = "Observer" })
    link(c, observer) queued(c)
    c.partyCount = 2 c:fire("GROUP_ROSTER_UPDATE") -- party2 is not available yet.
    assert(c.ns.queued and c.ns.QueueUpdatePending())
    c:advance(2) equal(#observer.ns.state:Sorted(), 0)
    c.partyMembers[2], c.partyRoles.party2 = "New-OtherRealm", "DAMAGER"
    c.partyCount = nil c:fire("GROUP_ROSTER_UPDATE") c:advance(8)
    assert(not c.ns.QueueUpdatePending()) equal(#observer.ns.state:Sorted(), 3)
end)

test("invalid native role capacity pauses a listing and a valid role change republishes it", function()
    local c = party() queued(c)
    c.partyRoles.party1 = "TANK" c:fire("PLAYER_ROLES_ASSIGNED")
    assert(c.ns.queued and c.ns.QueueUpdatePending())
    c:advance(2) equal(#c.ns.state:Sorted(), 0)
    c.partyRoles.player = "HEALER" c:fire("ROLE_CHANGED_INFORM") c:advance(8)
    assert(not c.ns.QueueUpdatePending())
    equal(c.ns.state:Get(c.ns.playerName).roles, 2)
    equal(c.ns.state:Get("Guest-OtherRealm").roles, 1)
end)

test("roster and role updates during a failed transaction publish only the latest whole party", function()
    local c, observer = party(), client({ characterName = "Observer" })
    link(c, observer) queued(c)
    local age = c.ns.joinedAt
    c.result = 9
    c.partyMembers[2], c.partyRoles.party2 = "Intermediate-OtherRealm", "DAMAGER"
    c:fire("GROUP_ROSTER_UPDATE") c:advance(1)
    c.partyMembers[2], c.partyRoles.party2 = "Latest-OtherRealm", "DAMAGER"
    c.partyRoles.party1 = "DAMAGER"
    c:fire("PLAYER_ROLES_ASSIGNED") c:fire("GROUP_ROSTER_UPDATE")
    c.result = 0 c:advance(12)
    assert(not c.ns.QueueUpdatePending()) equal(#observer.ns.state:Sorted(), 3)
    equal(observer.ns.state:Get("Intermediate-OtherRealm"), nil)
    equal(observer.ns.state:Get("Guest-OtherRealm").roles, 4)
    equal(observer.ns.state:Get("Latest-OtherRealm").roles, 4)
    equal(c.ns.joinedAt, age) equal(#c.invites, 0)
end)

test("a roster edit during initial multipart delivery replaces rather than mixes staged members", function()
    local c, observer = party(), client({ characterName = "Observer" })
    link(c, observer) c.ns.SetQueued(true) c:advance(3)
    c.partyMembers[2], c.partyRoles.party2 = "New-OtherRealm", "DAMAGER"
    c:fire("GROUP_ROSTER_UPDATE") c:advance(8)
    assert(not c.ns.QueueUpdatePending()) equal(#observer.ns.state:Sorted(), 3)
    equal(observer.ns.state.records[c.ns.playerName].partySize, 3)
end)

test("paused listings withdraw once without starving presence quest or version traffic", function()
    local c, observer = party(), client({ characterName = "Observer" })
    link(c, observer) queued(c)
    c.ns.SetQuestSharing(true)
    c.partyRoles.party1 = "NONE" c:fire("PLAYER_ROLES_ASSIGNED")
    local start = #c.sent
    c:receive("Older-TestRealm", { kind = "V", sentAt = c.now, version = "0.1.0" })
    c:advance(45)
    local withdrawals, presence, quests, versions = 0, 0, 0, 0
    for i = start + 1, #c.sent do
        local p = c.ns.Protocol.Decode(c.sent[i].text)
        local q = c.ns.Questing.Decode(c.sent[i].text)
        if p then
            assert(p.kind ~= "S" and p.kind ~= "B" and p.kind ~= "C")
            if p.kind == "X" then withdrawals = withdrawals + 1 end
            if p.kind == "P" then presence = presence + 1 end
            if p.kind == "V" then versions = versions + 1 end
        end
        if q and q.kind == "Q" then quests = quests + 1 end
    end
    equal(withdrawals, 1) assert(presence >= 1 and quests >= 1 and versions >= 1)
    assert(c.ns.queued and c.ns.QueueUpdatePending())
    equal(#observer.ns.state:Sorted(), 0) equal(#c.invites, 0)
end)

test("explicit leave while a party update is paused prevents recovery from requeuing it", function()
    local c = party() queued(c)
    c.partyRoles.party1 = "NONE" c:fire("PLAYER_ROLES_ASSIGNED") c:advance(2)
    c.ns.SetQueued(false)
    c.partyRoles.party1 = "HEALER" c:fire("PLAYER_ROLES_ASSIGNED")
    local count = #c.sent c:advance(12) noPartyPacketsAfter(c, count)
    assert(not c.ns.queued) equal(#c.ns.state:Sorted(), 0)
end)

test("lost leadership during a pending party update still cancels all automatic recovery", function()
    local c = party() queued(c)
    c.partyRoles.party1 = "NONE" c:fire("PLAYER_ROLES_ASSIGNED") c:advance(1)
    c.partyLeader = false c:fire("PARTY_LEADER_CHANGED")
    assert(not c.ns.queued)
    c.partyRoles.party1, c.partyLeader = "HEALER", true
    c:fire("PLAYER_ROLES_ASSIGNED")
    local count = #c.sent c:advance(10) noPartyPacketsAfter(c, count)
    assert(not c.ns.queued)
end)

test("dungeon changes in the middle of a fragment batch cannot mix transactions", function()
    local c, observer = party(), client({ characterName = "Observer" })
    link(c, observer) c.ns.SetQueued(true) c:advance(3)
    c.ns.prefs.dungeons = { [3] = true } c.ns.PreferencesChanged()
    c:advance(8)
    local record = observer.ns.state.records[c.ns.playerName]
    assert(record and record.dungeons[3] and not record.dungeons[1])
    equal(record.partySize, 2) assert(not c.ns.QueueUpdatePending())
end)

test("long chat lockdown restarts an expired party transaction with a fresh revision", function()
    local c, observer = party(), client({ characterName = "Observer" })
    link(c, observer) c.ns.SetQueued(true) c:advance(3)
    local pending = observer.ns.state.pending[c.ns.playerName].revision
    c.locked = true c:advance(c.ns.TIMEOUT + 2)
    c.locked = false c:advance(12)
    local record = observer.ns.state.records[c.ns.playerName]
    assert(record and not c.ns.QueueUpdatePending())
    assert(observer.ns.state.seen[c.ns.playerName] > pending)
    equal(#observer.ns.state:Sorted(), 2)
end)

test("guild changes and logout withdraw party state without transferring it to the new guild", function()
    local c = party() queued(c)
    c.guild = "Other Guild" c:fire("PLAYER_GUILD_UPDATE", "player")
    assert(not c.ns.queued) equal(#c.ns.state:Sorted(), 0)
    local count = #c.sent c:advance(8) noPartyPacketsAfter(c, count)
    local d, observer = party(), client({ characterName = "Observer" })
    link(d, observer) queued(d)
    d:fire("PLAYER_LOGOUT")
    equal(#observer.ns.state:Sorted(), 0)
end)

test("logout cancels incomplete party transactions instead of transmitting their last member", function()
    local c, observer = party(), client({ characterName = "Observer" })
    link(c, observer) c.ns.SetQueued(true) c:advance(3)
    assert(observer.ns.state.pending[c.ns.playerName])
    c:fire("PLAYER_LOGOUT")
    local last = assert(c.ns.Protocol.Decode(c.sent[#c.sent].text))
    equal(last.kind, "X")
    equal(observer.ns.state.pending[c.ns.playerName], nil)
    equal(#observer.ns.state:Sorted(), 0)
end)

test("party advertisement expires as one whole unit on remote guild clients", function()
    local c, observer = party(), client({ characterName = "Observer" })
    link(c, observer) queued(c)
    observer:advance(c.ns.TIMEOUT)
    equal(#observer.ns.state:Sorted(), 0) equal(#observer.ns.groups, 0)
end)

test("party roster protocol is accepted only on the guild addon channel", function()
    for _, channel in ipairs({ "PARTY", "RAID", "WHISPER", "OFFICER", "INSTANCE_CHAT" }) do
        local c = client({ characterName = "Observer" })
        local fragments = assert(c.ns.Protocol.EncodeParty(1, c.now, c.now, { [1] = true }, {
            { name = "Leader-TestRealm", roles = 1 }, { name = "Guest-OtherRealm", roles = 2 } }))
        for _, message in ipairs(fragments) do
            c:fire("CHAT_MSG_ADDON", c.ns.PREFIX, message, channel, "Leader-TestRealm")
        end
        equal(#c.ns.state:Sorted(), 0)
    end
end)

test("matched solos cannot create competing parties or invite a premade's members separately", function()
    local c = party()
    local recruit = client({ characterName = "Recruit" })
    link(c, recruit) link(recruit, c)
    queued(c) queued(recruit)
    equal(#recruit.ns.groups, 1) equal(#recruit.ns.groups[1].members, 3)
    assert(recruit.ns.CreatePartyDisabledReason(recruit.ns.groups[1]):find("leader", 1, true))
    assert(not recruit.ns.CreateParty(recruit.ns.groups[1]))
    for _, name in ipairs({ c.ns.playerName, "Guest-OtherRealm" }) do
        assert(recruit.ns.QueueInviteDisabledReason(name, 1))
        assert(not recruit.ns.InviteQueuedPlayer(name))
    end
    equal(#recruit.invites, 0) equal(#c.invites, 0)
    assert(c.ns.CreateParty(c.ns.groups[1])) equal(#c.invites, 1)
    equal(c.invites[1], recruit.ns.playerName)
end)

test("only the queued premade leader can issue its matchup formation claim", function()
    local c, recruit = party(), client({ characterName = "Recruit" })
    link(c, recruit) link(recruit, c) queued(c) queued(recruit)
    local group = c.ns.groups[1]
    local key = assert(c.ns.MatchupKey(group))
    c:receive(recruit.ns.playerName, { kind = "F", sentAt = c.now,
        claimID = c.now * 1000, replacesID = 0, matchupKey = key })
    equal(c.ns.FormationStatus(group), nil)
    assert(c.ns.CreateParty(group)) equal(#c.invites, 1)
end)

test("synchronous expected roster events do not interrupt a click-authorized solo invitation batch", function()
    local c = client()
    local group = suggestedGroup(c)
    local original = c.env.C_PartyInfo.InviteUnit
    c.env.C_PartyInfo.InviteUnit = function(name)
        original(name)
        c.homeGroup, c.partyMembers = true, { c.invites[1] }
        c:fire("GROUP_ROSTER_UPDATE")
    end
    assert(c.ns.CreateParty(group)) equal(#c.invites, 4)
    assert(not c.ns.queued) equal(c.ns.QueueButtonText(), "Queue party")
end)

test("synchronous outsider or lost-leadership events still stop the authorized invitation batch", function()
    for _, outsider in ipairs({ true, false }) do
        local c = client()
        local group = suggestedGroup(c)
        local original = c.env.C_PartyInfo.InviteUnit
        c.env.C_PartyInfo.InviteUnit = function(name)
            original(name)
            c.homeGroup, c.partyMembers = true, { outsider and "Outsider-TestRealm" or name }
            c.partyLeader = outsider
            c:fire("GROUP_ROSTER_UPDATE")
        end
        assert(not c.ns.CreateParty(group)) equal(#c.invites, 1)
        -- A now-nonleader can keep looking individually, but never completes
        -- invitations after losing native party leadership.
        equal(c.ns.queued, not outsider)
        c:advance(3) equal(#c.invites, 1)
    end
end)
