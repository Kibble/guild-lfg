local addonName, ns = ...
local events = CreateFrame("Frame")
local guildIdentityReady = false
local pendingStateAt, pendingHello, pendingPresence = nil, false, false
local lastAttempt, lastSent, lastHello, lastPresence, lastHelloReply = -100, -100, -100, -100, -100
local presence = {}
local registered, started = false, false
local transportError
local lastPartyInviteAt = -100
ns.queued = false
ns.state = ns.State.New()
ns.groups, ns.individuals = {}, {}

local function secret(...)
    return hasanysecretvalues and hasanysecretvalues(...)
end

local function printMessage(message)
    DEFAULT_CHAT_FRAME:AddMessage("|cffffd100Guild Queue:|r " .. message)
end

local function normalize(name)
    if secret(name) or type(name) ~= "string" or name == "" then
        return nil
    end
    name = name:match("^%s*(.-)%s*$")
    local character, realm = name:match("^([^%s%-]+)%-(.+)$")
    if not character then
        -- Some client name surfaces use "Character Realm" instead of a hyphen.
        -- Character names contain no spaces; keep the entire remaining realm.
        character, realm = name:match("^([^%s%-]+)%s+(.+)$")
    end
    if not character then
        character, realm = name, ns.realm
    end
    if character == "" or character:find("[%s%-]") or not realm then
        return nil
    end
    realm = realm:gsub("%s", "")
    if realm == "" then return nil end
    return character .. "-" .. realm
end

local function rebuild()
    ns.groups, ns.individuals = ns.Match(ns.state)
    ns.RefreshUI()
end

local function requestState(delay)
    local due = GetTime() + (delay or 0)
    pendingStateAt = math.min(pendingStateAt or due, due)
end

function ns.IsReady()
    return registered and IsInGuild() and guildIdentityReady and ns.playerName ~= nil
end

function ns.OnlineAddonCount()
    if not ns.IsReady() then
        return 0
    end
    local now, count = GetServerTime(), 1
    for _, seenAt in pairs(presence) do
        if now - seenAt < ns.TIMEOUT then
            count = count + 1
        end
    end
    return count
end

function ns.StatusText()
    if not registered then
        return "Addon messaging could not be registered."
    elseif not IsInGuild() then
        return "Join a guild to use the queue."
    elseif not ns.playerName then
        return "Waiting for your character name and realm."
    elseif not guildIdentityReady then
        return "Waiting for guild information. Try opening the Guild window."
    elseif transportError then
        return transportError
    end
    return "Guild members with this addon only. Select roles and dungeons, then join."
end

function ns.JoinQueueDisabledReason()
    if not ns.IsReady() then
        return ns.StatusText()
    end
    if not ns.Protocol.ValidSelections(ns.prefs.roles, ns.prefs.dungeons) then
        return "Select at least one role and one dungeon."
    end
end

-- Used both by the disabled-button tooltip and immediately before a click action.
function ns.CreatePartyDisabledReason(group)
    local homeGroup = IsInGroup(LE_PARTY_CATEGORY_HOME)
    local instanceGroup = IsInGroup(LE_PARTY_CATEGORY_INSTANCE)
    if secret(homeGroup, instanceGroup) then
        return "Your party status is unavailable right now."
    end
    if homeGroup or instanceGroup then
        return "You are already in a party or raid. Leave your current group to create a new party."
    end
    if InCombatLockdown() then
        return "You cannot create a party during combat."
    end
    if not C_PartyInfo or not C_PartyInfo.InviteUnit then
        return "Party invitations are unavailable on this client."
    end
    if not ns.IsReady() then
        return "Your guild queue is not ready yet."
    end
    local current = false
    for _, suggestion in ipairs(ns.groups) do
        if suggestion == group then
            current = true
            break
        end
    end
    if not current then
        return "This suggested group has changed. Wait for the queue to refresh."
    end
    local includesPlayer, names = false, {}
    if #group.slots ~= 5 then
        return "This suggested group is incomplete."
    end
    for _, player in ipairs(group.slots) do
        local record = ns.state.records[player.name]
        if names[player.name] or not record
            or GetServerTime() - record.sentAt >= ns.TIMEOUT then
            return "This suggested group is no longer available. Wait for the queue to refresh."
        end
        names[player.name] = true
        includesPlayer = includesPlayer or player.name == ns.playerName
    end
    if not includesPlayer then
        return "You can only create a party for your own suggested group."
    end
    if GetTime() - lastPartyInviteAt < 5 then
        return "Invitations were just requested. Wait a few seconds before trying again."
    end
end

-- Called only by the Create party button's OnClick, never by matching or timers.
-- Submit all four requests together; the party may appear after the first request.
function ns.CreateParty(group)
    local reason = ns.CreatePartyDisabledReason(group)
    if reason then
        printMessage(reason)
        ns.RefreshUI()
        return false
    end
    local targets = {}
    for _, player in ipairs(group.slots) do
        if player.name ~= ns.playerName then
            targets[#targets + 1] = player.name
        end
    end
    lastPartyInviteAt = GetTime()
    local requested = 0
    for _, name in ipairs(targets) do
        if pcall(C_PartyInfo.InviteUnit, name) then
            requested = requested + 1
        end
    end
    if requested == 4 then
        printMessage("Party invitations requested. Players must accept; leave the queue once grouped.")
    else
        printMessage("Some invitation requests could not be submitted. Check WoW's messages before trying again.")
    end
    ns.RefreshUI()
    return requested == 4
end

function ns.SetQueued(wanted)
    if wanted then
        local reason = ns.JoinQueueDisabledReason()
        if reason then
            printMessage(reason)
            return
        end
        if not ns.queued then
            ns.joinedAt = GetServerTime()
        end
        ns.queued = true
        printMessage("Queue requested. Use Create party on your suggested group to invite its members.")
    else
        ns.queued, ns.joinedAt = false, nil
        -- Withdraw locally immediately, even if transport is currently blocked.
        ns.state.records[ns.playerName or ""] = nil
        rebuild()
        printMessage("Left the queue. Other clients update on delivery or within 75 seconds.")
    end
    requestState(0)
    ns.RefreshUI()
end

function ns.PreferencesChanged()
    if ns.queued then
        if ns.Protocol.ValidSelections(ns.prefs.roles, ns.prefs.dungeons) then
            requestState(0)
        else
            ns.SetQueued(false)
        end
    end
    ns.RefreshUI()
end

local function identifyPlayer()
    local name, realm = UnitFullName("player")
    if secret(name, realm) or not name then
        return
    end
    realm = realm ~= "" and realm or GetNormalizedRealmName()
    if secret(realm) or not realm or realm == "" then
        return
    end
    ns.realm = realm:gsub("%s", "")
    -- UnitFullName normally returns a short name, but do not double-qualify
    -- clients that already include the realm in the first return value.
    ns.playerName = normalize(name)
    if ns.playerName then
        ns.realm = ns.playerName:match("^[^%-]+%-(.+)$")
    end
end

local function applyGuildIdentity(guildName, guildRealm)
    local key = guildName and (guildName .. "-" .. (guildRealm or ns.realm or "")) or nil
    if key ~= ns.guildKey then
        ns.guildKey, ns.guildName = key, guildName
        ns.queued, ns.joinedAt = false, nil
        ns.state = ns.State.New()
        pendingStateAt, pendingHello, pendingPresence = nil, key ~= nil, key ~= nil
        lastHello, lastPresence, lastHelloReply = -100, -100, -100
        presence = {}
        transportError = nil
        if key then
            -- A new revision tombstone clears any pre-reload queue entry.
            requestState(0)
        end
        rebuild()
    end
end

local function updateGuild(clearIfUnresolved)
    if not ns.playerName then
        identifyPlayer()
    end
    guildIdentityReady = false
    if not IsInGuild() then
        applyGuildIdentity(nil)
        return
    end
    local guildName, _, _, guildRealm = GetGuildInfo("player")
    if secret(guildName, guildRealm) or not guildName then
        -- Preserve state through a transient loading screen, but do not send or
        -- accept messages until we can confirm which guild we belong to.
        -- A membership-change event with unresolved identity must discard old data.
        if clearIfUnresolved then
            applyGuildIdentity(nil)
        end
        return
    end
    guildIdentityReady = true
    applyGuildIdentity(guildName, guildRealm)
end

local function send(message)
    if C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() then
        transportError = "Addon messaging is restricted right now; retrying when allowed."
        return false
    end
    local ok, result = pcall(C_ChatInfo.SendAddonMessage, ns.PREFIX, message, "GUILD")
    local success = Enum and Enum.SendAddonMessageResult and Enum.SendAddonMessageResult.Success or 0
    if not ok or result ~= success then
        -- Do not print raw API error strings or payloads.
        transportError = "Guild message could not be sent (account/server restriction or throttling); retrying."
        return false
    end
    transportError = nil
    return true
end

local function sendState()
    local now = GetServerTime()
    -- Persist only preferences and an ordering counter, never active queue membership.
    -- Server-time seeding also helps when the character logs in on another computer.
    ns.prefs.revision = math.max(ns.prefs.revision, now * 1000) + 1
    local packet = { kind = ns.queued and "S" or "X", revision = ns.prefs.revision, sentAt = now }
    if ns.queued then
        packet.joinedAt, packet.roles, packet.dungeons = ns.joinedAt, ns.prefs.roles, ns.prefs.dungeons
    end
    if send(ns.Protocol.Encode(packet)) then
        pendingStateAt, lastSent, lastPresence = nil, GetTime(), GetTime()
        pendingPresence = false
        if ns.state:Apply(ns.playerName, packet, now) then
            rebuild()
        end
        return true
    end
    return false
end

local function tick()
    if not started then
        return
    end
    local clock = GetTime()
    updateGuild()
    local serverNow = GetServerTime()
    if ns.state:Prune(serverNow) then
        rebuild()
    end
    for name, seenAt in pairs(presence) do
        if serverNow - seenAt >= ns.TIMEOUT then
            presence[name] = nil
        end
    end
    if not ns.IsReady() then
        ns.RefreshUI()
        return
    end
    if ns.queued and clock - lastSent >= ns.HEARTBEAT then
        requestState(0)
    elseif not ns.queued and clock - lastPresence >= ns.HEARTBEAT then
        pendingPresence = true
    end
    -- At most one outgoing message per second; failures back off for five seconds.
    local interval = transportError and 5 or 1
    if clock - lastAttempt >= interval then
        if pendingStateAt and pendingStateAt <= clock then
            lastAttempt = clock
            sendState()
        elseif pendingHello and clock - lastHello >= 15 then
            lastAttempt = clock
            if send(ns.Protocol.Encode({ kind = "H" })) then
                pendingHello, lastHello = false, clock
            end
        elseif pendingPresence then
            lastAttempt = clock
            if send(ns.Protocol.Encode({ kind = "P" })) then
                pendingPresence, lastPresence = false, clock
            end
        end
    end
    ns.RefreshUI()
end

local function receive(prefix, message, channel, sender)
    if secret(prefix, message, channel, sender)
        or prefix ~= ns.PREFIX or channel ~= "GUILD" then
        return
    end
    -- WoW's server restricts GUILD addon delivery to guild members. Use that
    -- transport boundary, never a claimed payload identity or another channel.
    -- A separate GetGuildRosterInfo cache is not required to join or synchronize.
    updateGuild()
    if not ns.IsReady() then
        return
    end
    local name = normalize(sender)
    if not name or name:lower() == ns.playerName:lower() then
        return
    end
    local packet = ns.Protocol.Decode(message)
    if not packet then
        return
    end
    local now = GetServerTime()
    if packet.kind == "H" or packet.kind == "P" then
        presence[name] = now
        if packet.kind == "H" and ns.queued and GetTime() - lastHelloReply >= 5 then
            lastHelloReply = GetTime()
            requestState(math.random(1, 5))
        end
        ns.RefreshUI()
    elseif packet.sentAt <= now + 5 and now - packet.sentAt < ns.TIMEOUT then
        presence[name] = now
        if ns.state:Apply(name, packet, now) then
            rebuild()
        else
            ns.RefreshUI()
        end
    end
end

local function initialize()
    if type(GuildQueueDB) ~= "table" then
        GuildQueueDB = {}
    end
    ns.prefs = GuildQueueDB
    if type(ns.prefs.roles) ~= "number" or ns.prefs.roles ~= ns.prefs.roles
        or ns.prefs.roles < 0 or ns.prefs.roles > 7 or ns.prefs.roles % 1 ~= 0 then
        ns.prefs.roles = 4
    end
    local dungeons = {}
    if type(ns.prefs.dungeons) == "table" then
        for _, dungeon in ipairs(ns.DUNGEONS) do
            if ns.prefs.dungeons[dungeon.id] == true then
                dungeons[dungeon.id] = true
            end
        end
    end
    ns.prefs.dungeons = dungeons
    if type(ns.prefs.revision) ~= "number" or ns.prefs.revision ~= ns.prefs.revision
        or ns.prefs.revision < 0 or ns.prefs.revision > 8000000000000000
        or ns.prefs.revision % 1 ~= 0 then
        ns.prefs.revision = 0
    end
    local ok = pcall(C_ChatInfo.RegisterAddonMessagePrefix, ns.PREFIX)
    registered = ok and C_ChatInfo.IsAddonMessagePrefixRegistered(ns.PREFIX)
end

local function start()
    if started or not ns.prefs then
        return
    end
    started = true
    identifyPlayer()
    updateGuild()
    ns.ticker = C_Timer.NewTicker(1, tick)
    printMessage("Loaded. Use /gq to open the guild dungeon queue.")
end

events:SetScript("OnEvent", function(_, event, ...)
    if secret(...) then
        return
    end
    if event == "ADDON_LOADED" then
        if ... == addonName then
            initialize()
        end
    elseif event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        start()
    elseif event == "CHAT_MSG_ADDON" then
        receive(...)
    elseif event == "GUILD_ROSTER_UPDATE" then
        if started then
            updateGuild()
            ns.RefreshUI()
        end
    elseif event == "PLAYER_GUILD_UPDATE" then
        local unit = ...
        if started and unit == "player" then
            updateGuild(true)
            ns.RefreshUI()
        end
    elseif event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_REGEN_DISABLED"
        or event == "PLAYER_REGEN_ENABLED" then
        if started then
            ns.RefreshUI()
        end
    elseif event == "PLAYER_LOGOUT" then
        if ns.IsReady() then
            ns.queued = false
            -- Best effort only: peers also expire entries if logout delivery is lost.
            sendState()
        end
    end
end)
for _, event in ipairs({ "ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "CHAT_MSG_ADDON",
    "GUILD_ROSTER_UPDATE", "PLAYER_GUILD_UPDATE", "GROUP_ROSTER_UPDATE",
    "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "PLAYER_LOGOUT" }) do
    events:RegisterEvent(event)
end

SLASH_GUILDQUEUE1, SLASH_GUILDQUEUE2 = "/gq", "/guildqueue"
SlashCmdList.GUILDQUEUE = function(command)
    if not started then
        return
    end
    command = command:lower():match("^%s*(.-)%s*$")
    if command == "leave" then
        ns.SetQueued(false)
    elseif command == "join" then
        ns.SetQueued(true)
    elseif command == "status" then
        updateGuild()
        local reason = ns.JoinQueueDisabledReason()
        printMessage(ns.queued and "You have requested to queue. " .. ns.StatusText()
            or reason or "Ready to join. Click Join queue or type /gq join.")
        printMessage("Guild member: " .. (IsInGuild() and "yes" or "no")
            .. "; guild information: " .. (guildIdentityReady and "ready" or "waiting")
            .. "; character information: " .. (ns.playerName and "ready" or "waiting")
            .. "; addon messaging: " .. (registered and "ready" or "unavailable") .. ".")
        ns.RefreshUI()
    else
        ns.ToggleUI()
    end
end
