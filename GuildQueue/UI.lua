local _, ns = ...
local frame, status, guildLabel, queueStatus, joinButton, groupsTab, queueTab
local outputScroll, dungeonScroll, selectionCount
local roleChecks, dungeonChecks, counters = {}, {}, {}
local mode, hovered, pendingScroll = "groups", nil, nil
local scrollPositions = { groups = 0, queue = 0 }
local pools = { groups = {}, people = {}, headings = {}, empty = {} }
local CONTENT_WIDTH = 728
local C = {
    background = { 0.025, 0.025, 0.025 }, panel = { 0.035, 0.035, 0.035 },
    card = { 0.045, 0.045, 0.045 }, tile = { 0.025, 0.025, 0.025 },
    border = { 1, 1, 1 }, gold = { 1, 0.82, 0 },
    heading = { 1, 0.82, 0 }, text = { 1, 1, 1 },
    muted = { 0.65, 0.65, 0.65 }, selected = { 0.08, 0.075, 0.045 },
    green = { 0.2, 1, 0.2 }, own = { 0.055, 0.055, 0.035 },
    dim = { 0.5, 0.5, 0.5 },
}
local roleAtlases = { [1] = "UI-LFG-RoleIcon-Tank", [2] = "UI-LFG-RoleIcon-Healer",
    [4] = "UI-LFG-RoleIcon-DPS" }
local backdrop = { bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 32,
    edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } }
local windowBackdrop = { bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border", tile = true, tileSize = 32,
    edgeSize = 32, insets = { left = 11, right = 11, top = 11, bottom = 11 } }

local function colorText(region, color)
    region:SetTextColor(color[1], color[2], color[3], 1)
end

local function applyBackdrop(control, style)
    -- Create the opaque backing first, below the native dialog artwork.
    control.opaqueFill = control:CreateTexture(nil, "BACKGROUND", nil, -8)
    control.opaqueFill:SetAllPoints(control)
    control:SetBackdrop(style)
end

local function surface(control, fill, edge)
    control.opaqueFill:SetColorTexture(fill[1], fill[2], fill[3], 1)
    control:SetBackdropColor(1, 1, 1, 1)
    edge = edge or C.border
    control:SetBackdropBorderColor(edge[1], edge[2], edge[3], 1)
end

local function place(control, x, y, width, height)
    control:ClearAllPoints()
    control:SetPoint("TOPLEFT", x, -y)
    control:SetSize(width, height)
end

local function panel(parent, x, y, width, height, fill, edge)
    local control = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    place(control, x, y, width, height)
    applyBackdrop(control, backdrop)
    surface(control, fill or C.panel, edge)
    return control
end

-- Every text region is bounded, including names and multi-line dungeon selections.
local function label(parent, text, x, y, width, height, font, color, wrap)
    local region = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    place(region, x, y, width, height)
    region:SetJustifyH("LEFT")
    region:SetJustifyV("MIDDLE")
    region:SetWordWrap(wrap == true)
    region:SetNonSpaceWrap(false)
    region:SetText(text)
    colorText(region, color or C.text)
    return region
end

local function solid(parent, x, y, width, height, color)
    local texture = parent:CreateTexture(nil, "ARTWORK")
    place(texture, x, y, width, height)
    texture:SetColorTexture(color[1], color[2], color[3], 1)
    return texture
end

local function roleIcon(parent, role, x, y, size)
    local texture = parent:CreateTexture(nil, "ARTWORK")
    place(texture, x, y, size, size)
    texture:SetAtlas(roleAtlases[role])
    texture.guildQueueKind, texture.role = "roleIcon", role
    return texture
end

local function roleIconRow(parent)
    local icons = {}
    for _, role in ipairs({ 1, 2, 4 }) do
        icons[role] = roleIcon(parent, role, 0, 0, 16)
        icons[role]:Hide()
    end
    return icons
end

local function updateRoleIcons(icons, mask, x, y, size)
    for _, role in ipairs({ 1, 2, 4 }) do
        local icon = icons[role]
        local selected = ns.HasRole(mask, role)
        icon:SetShown(selected)
        if selected then
            place(icon, x, y, size, size)
            x = x + size + 4
        end
    end
end

local function hideTooltip(control)
    if GameTooltip:IsOwned(control) then
        GameTooltip:Hide()
    end
    if hovered == control then
        hovered = nil
    end
end

local function clearHover()
    if hovered then
        hideTooltip(hovered)
    end
end

local function showTextTooltip(control)
    GameTooltip:SetOwner(control, "ANCHOR_RIGHT")
    GameTooltip:SetText(control.tooltipTitle or "Guild Queue")
    GameTooltip:AddLine(control.tooltipText or "", 1, 1, 1, true)
    GameTooltip:Show()
end

local function showPartyTooltip(control)
    GameTooltip:SetOwner(control, "ANCHOR_RIGHT")
    GameTooltip:SetText("Create party")
    GameTooltip:AddLine(ns.CreatePartyDisabledReason(control.group)
        or "Invite the other four players in this suggested group. Each player must accept.",
        1, 1, 1, true)
    GameTooltip:Show()
end

local function showQueueTooltip(control)
    GameTooltip:SetOwner(control, "ANCHOR_RIGHT")
    GameTooltip:SetText(ns.queued and "Leave queue" or "Join queue")
    GameTooltip:AddLine(ns.queued and "Remove yourself from the guild dungeon queue."
        or ns.JoinQueueDisabledReason() or "Join the guild queue with your selected roles and dungeons.",
        1, 1, 1, true)
    GameTooltip:Show()
end

local function paint(control)
    -- Native templates own their hover, pressed, checked and disabled artwork.
    if control.guildQueueKind == "scrollbar" then
        surface(control, C.background)
    elseif control.guildQueueKind == "tab" then
        control:SetButtonState(control.selected and "PUSHED" or "NORMAL", control.selected == true)
    end
    colorText(control.caption, control:IsEnabled() and C.heading or C.dim)
end

local function bindHover(control, tooltip, styled)
    control.tooltip = tooltip
    control:EnableMouse(true)
    control:SetScript("OnEnter", function(self)
        if hovered and hovered ~= self then
            hideTooltip(hovered)
        end
        hovered = self
        if styled then paint(self) end
        if self.tooltip then self.tooltip(self) end
    end)
    control:SetScript("OnLeave", function(self)
        hideTooltip(self)
        if styled then paint(self) end
    end)
    control:SetScript("OnHide", function(self)
        hideTooltip(self)
    end)
end

local function button(parent, text, x, y, width, height, callback, kind)
    local template = kind == "scrollbar" and "BackdropTemplate"
        or kind == "close" and "UIPanelCloseButton" or "UIPanelButtonTemplate"
    local control = CreateFrame("Button", nil, parent, template)
    place(control, x, y, width, height)
    if kind == "scrollbar" then applyBackdrop(control, backdrop) end
    control.guildQueueKind = kind
    control.caption = label(control, "", 6, 0, math.max(1, width - 12), height, "GameFontNormal")
    control.caption:SetJustifyH("CENTER")
    -- Keep Button's native SetText/GetText contract; do not replace widget methods.
    control:SetFontString(control.caption)
    control:SetText(text)
    control:SetScript("OnClick", callback)
    bindHover(control, nil, true)
    paint(control)
    return control
end

local function check(parent, text, x, y, width, height, callback, kind, role)
    local control = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    place(control, x, y, width, height)
    control.guildQueueKind, control.guildQueueCheck = kind, true
    -- Keep the native checkbox small even though the entire row is clickable.
    for _, getter in ipairs({ "GetNormalTexture", "GetPushedTexture", "GetHighlightTexture",
        "GetCheckedTexture", "GetDisabledCheckedTexture" }) do
        local texture = control[getter](control)
        if texture then
            place(texture, role and 5 or 0, role and 32 or math.floor((height - 24) / 2), 24, 24)
            texture:SetDrawLayer("OVERLAY", 1)
        end
    end
    if role then
        control.roleIcon = roleIcon(control, role, math.floor((width - 48) / 2), 0, 48)
        control.caption = label(control, text, 2, 54, width - 4, 18, "GameFontNormal", C.heading)
        control.caption:SetJustifyH("CENTER")
    else
        control.caption = label(control, text, 25, 2, width - 30, height - 4,
            "GameFontHighlightSmall", C.heading, true)
    end
    control.tooltipTitle = text
    control.tooltipText = "Select one or more. Your selections update while queued."
    control:SetScript("OnClick", function(self)
        callback(self)
        paint(self)
    end)
    bindHover(control, showTextTooltip, true)
    paint(control)
    return control
end

-- Preserve per-tab wheel/track scrolling, using WoW's native scroll-knob artwork.
local function scrollArea(parent, x, y, width, height, kind)
    local scroll = CreateFrame("ScrollFrame", nil, parent)
    place(scroll, x, y, width - 14, height)
    scroll.guildQueueKind = kind
    scroll:EnableMouseWheel(true)
    scroll.content = CreateFrame("Frame", nil, scroll)
    scroll.content:SetSize(width - 18, 1)
    scroll:SetScrollChild(scroll.content)
    scroll.track = button(parent, "", x + width - 16, y, 16, height, nil, "scrollbar")
    scroll.thumb = scroll.track:CreateTexture(nil, "OVERLAY")
    scroll.thumb:SetTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
    local function update()
        local maximum = math.max(0, scroll.content:GetHeight() - height)
        local position = math.max(0, math.min(scroll:GetVerticalScroll(), maximum))
        scroll:SetVerticalScroll(position)
        local thumbHeight = math.min(height, 32)
        local thumbY = maximum > 0 and (height - thumbHeight) * position / maximum or 0
        place(scroll.thumb, 1, thumbY, 14, thumbHeight)
        scroll.track:SetShown(maximum > 0)
    end
    scroll.update = update
    local function wheel(_, delta)
        clearHover()
        scroll:SetVerticalScroll(math.max(0, scroll:GetVerticalScroll() - delta * 42))
        update()
    end
    scroll:SetScript("OnMouseWheel", wheel)
    scroll.track:EnableMouseWheel(true)
    scroll.track:SetScript("OnMouseWheel", wheel)
    scroll.track:SetScript("OnClick", function(self)
        local _, cursorY = GetCursorPosition()
        local fraction = (self:GetTop() - cursorY / self:GetEffectiveScale()) / height
        local maximum = math.max(0, scroll.content:GetHeight() - height)
        clearHover()
        scroll:SetVerticalScroll(math.max(0, math.min(1, fraction)) * maximum)
        update()
    end)
    return scroll
end

local function includesPlayer(group)
    for _, player in ipairs(group.slots) do
        if player.name == ns.playerName then return true end
    end
    return false
end

local function displayName(player)
    local name = player.name:match("^[^%-]+") or player.name
    return ns.SafeText(name) .. (player.name == ns.playerName and " (you)" or "")
end

local function playerTooltip(control, player)
    control.player = player
    control.tooltipTitle = ns.SafeText(player.name) .. (player.name == ns.playerName and " (you)" or "")
    control.tooltipText = "Roles: " .. ns.SafeText(ns.RoleText(player.roles))
        .. "\nDungeons: " .. ns.SafeText(ns.DungeonText(player.dungeons))
end

local function acquire(pool, create)
    pool.used = (pool.used or 0) + 1
    if not pool[pool.used] then pool[pool.used] = create() end
    local control = pool[pool.used]
    control:Show()
    return control
end

local function newGroupCard()
    local card = panel(outputScroll.content, 0, 0, CONTENT_WIDTH, 226, C.card)
    card.guildQueueKind = "group"
    card.band = solid(card, 1, 1, CONTENT_WIDTH - 2, 68, C.selected)
    card.accent = solid(card, 1, 1, 3, 68, C.gold)
    card.kicker = label(card, "", 14, 10, 490, 16, "GameFontNormalSmall", C.green)
    card.title = label(card, "", 14, 28, 540, 40, "GameFontNormalLarge", C.heading, true)
    card.matched = label(card, "5 / 5 matched", 562, 12, 152, 22, "GameFontNormal", C.green)
    card.matched:SetJustifyH("RIGHT")
    card.common = label(card, "", 14, 72, 700, 28, nil, C.muted, true)
    card.note = label(card, "", 14, 190, 485, 24, nil, C.muted, true)
    card.tiles = {}
    for slot = 1, 5 do
        local tile = panel(card, 14 + (slot - 1) * 141, 110, 135, 68, C.tile)
        tile.guildQueueKind, tile.slot, tile.role = "member", slot, ns.SLOTS[slot]
        tile.roleIcon = roleIcon(tile, ns.SLOTS[slot], 9, 5, 18)
        tile.roleLabel = label(tile, ns.ROLE_NAMES[ns.SLOTS[slot]], 31, 6, 95, 16,
            "GameFontNormalSmall", C.heading)
        tile.name = label(tile, "", 9, 24, 117, 18, "GameFontNormal", C.text)
        tile.roleIcons = roleIconRow(tile)
        bindHover(tile, showTextTooltip)
        card.tiles[slot] = tile
    end
    bindHover(card, showTextTooltip)
    return card
end

local function renderGroup(group, index, own, y)
    local card = acquire(pools.groups, newGroupCard)
    local height = own and 226 or 170
    place(card, 0, y, CONTENT_WIDTH, height)
    surface(card, C.card, own and C.gold or C.border)
    card.band:SetShown(own)
    card.accent:SetShown(own)
    card.group = group
    card.kicker:SetText(own and "YOUR SUGGESTED GROUP" or ("SUGGESTED GROUP " .. index))
    local dungeon = ns.DUNGEON_BY_ID[group.dungeonID]
    local title = dungeon and dungeon.name or "Shared dungeon"
    card.title:SetText(ns.SafeText(title))
    card.common:SetText("Common dungeons: " .. ns.SafeText(ns.DungeonText(group.dungeons)))
    card.tooltipTitle = ns.SafeText(title)
    card.tooltipText = "Common dungeons: " .. ns.SafeText(ns.DungeonText(group.dungeons))
    for slot, tile in ipairs(card.tiles) do
        local player = group.slots[slot]
        place(tile, 14 + (slot - 1) * 141, own and 110 or 102, 135, own and 68 or 56)
        if player then
            tile:Show()
            tile.name:SetText(displayName(player))
            colorText(tile.name, player.name == ns.playerName and C.green or C.text)
            updateRoleIcons(tile.roleIcons, own and player.roles or 0, 9, 47, 16)
            surface(tile, player.name == ns.playerName and C.own or C.tile,
                player.name == ns.playerName and C.green or C.border)
            playerTooltip(tile, player)
        else
            tile:Hide()
        end
    end
    card.note:SetShown(own)
    if own then
        card.note:SetText("You + 4 guildmates. Everyone must accept their invitation.")
        if not card.createParty then
            card.createParty = button(card, "Create party", 526, 188, 188, 28, function(control)
                if control.group then ns.CreateParty(control.group) end
            end, "party")
            -- Required for already-grouped/combat explanations on disabled buttons.
            card.createParty:SetMotionScriptsWhileDisabled(true)
            card.createParty.tooltip = showPartyTooltip
        end
        local control = card.createParty
        if control.group ~= group then hideTooltip(control) end
        control.group = group
        control:SetEnabled(ns.CreatePartyDisabledReason(group) == nil)
        control:Show()
        paint(control)
    elseif card.createParty then
        card.createParty:Hide()
        card.createParty.group = nil
    end
    return y + height + 12
end

local function heading(text, detail, y)
    local control = acquire(pools.headings, function()
        local row = CreateFrame("Frame", nil, outputScroll.content)
        row.title = label(row, "", 2, 0, 430, 26, "GameFontNormal", C.heading)
        row.detail = label(row, "", 434, 0, 292, 26, nil, C.muted)
        row.detail:SetJustifyH("RIGHT")
        return row
    end)
    place(control, 0, y, CONTENT_WIDTH, 30)
    control.title:SetText(text)
    control.detail:SetText(detail or "")
    return y + 32
end

local function emptyCard(title, text, y)
    local card = acquire(pools.empty, function()
        local control = panel(outputScroll.content, 0, 0, CONTENT_WIDTH, 90, C.card)
        control.guildQueueKind = "empty"
        control.title = label(control, "", 18, 14, 692, 24, "GameFontNormal", C.heading)
        control.text = label(control, "", 18, 43, 692, 32, nil, C.muted, true)
        return control
    end)
    place(card, 0, y, CONTENT_WIDTH, 90)
    card.title:SetText(title)
    card.text:SetText(text)
    return y + 102
end

local function newPersonCard()
    local card = panel(outputScroll.content, 0, 0, 358, 88, C.card)
    card.guildQueueKind = "individual"
    card.name = label(card, "", 12, 8, 334, 20, "GameFontNormal", C.text)
    card.roleIcons = roleIconRow(card)
    card.dungeons = label(card, "", 12, 49, 334, 30, nil, C.muted, true)
    bindHover(card, showTextTooltip)
    return card
end

local function renderPeople(players, y)
    for index, player in ipairs(players) do
        local card = acquire(pools.people, newPersonCard)
        place(card, ((index - 1) % 2) * 370, y + math.floor((index - 1) / 2) * 100, 358, 88)
        card.name:SetText(displayName(player))
        colorText(card.name, player.name == ns.playerName and C.green or C.text)
        updateRoleIcons(card.roleIcons, player.roles, 12, 29, 18)
        card.dungeons:SetText(ns.SafeText(ns.DungeonText(player.dungeons)))
        surface(card, player.name == ns.playerName and C.own or C.card)
        playerTooltip(card, player)
    end
    return y + math.ceil(#players / 2) * 100
end

local function renderOutput(players)
    for _, pool in pairs(pools) do pool.used = 0 end
    local y = 0
    if mode == "groups" then
        local ownIndex
        for index, group in ipairs(ns.groups) do
            if #group.slots == 5 and includesPlayer(group) then
                ownIndex = index
                break
            end
        end
        if ownIndex then y = renderGroup(ns.groups[ownIndex], ownIndex, true, y) end
        if #ns.groups == 0 then
            y = emptyCard("No complete groups yet",
                "A group needs a tank, a healer and three damage players who share a dungeon. "
                    .. "Keep your selections open while more guildmates queue.", y)
        end
        if #ns.groups > (ownIndex and 1 or 0) then
            y = heading(ownIndex and "Other suggested groups" or "Suggested groups",
                "Suggestions only - no automatic invites", y)
            for index, group in ipairs(ns.groups) do
                if index ~= ownIndex then y = renderGroup(group, index, false, y) end
            end
        end
        y = heading("Unmatched individuals (" .. #ns.individuals .. ")", "Waiting for a compatible group", y)
        if #ns.individuals == 0 then
            y = emptyCard("No unmatched individuals", #players == 0
                and "No one is queued yet. Select your roles and dungeons to join."
                or "Everyone queued is in a suggested group.", y)
        else
            y = renderPeople(ns.individuals, y)
        end
    else
        y = heading("All queued guild members (" .. #players .. ")", "Oldest queue entries first", y)
        if #players == 0 then
            y = emptyCard("No guild members are currently queued",
                "Select your roles and dungeons, then click Join queue to get started.", y)
        else
            y = renderPeople(players, y)
        end
    end
    for _, pool in pairs(pools) do
        for index = pool.used + 1, #pool do
            local control = pool[index]
            if control.createParty then
                control.createParty:Hide()
                control.createParty.group = nil
            end
            control:Hide()
        end
    end
    outputScroll.content:SetHeight(math.max(1, y))
    if pendingScroll then
        outputScroll:SetVerticalScroll(pendingScroll)
        pendingScroll = nil
    end
    outputScroll.update()
end

function ns.RefreshUI()
    if not frame or not frame:IsShown() then return end
    local players = ns.state:Sorted()
    guildLabel:SetText(ns.SafeText(ns.guildName or "No guild"))
    status:SetText(ns.SafeText(ns.StatusText()))
    local stateText = ns.queued and "Queued" or "Not queued"
    if ns.queued and not ns.state.records[ns.playerName] then stateText = "Waiting to broadcast" end
    queueStatus:SetText(stateText)
    colorText(queueStatus, ns.queued and C.green or C.muted)
    counters.queued:SetText(#players)
    counters.groups:SetText(#ns.groups)
    counters.unmatched:SetText(#ns.individuals)
    joinButton:SetText(ns.queued and "Leave queue" or "Join queue")
    -- Leaving must remain possible when identity/transport/selections are unavailable.
    joinButton:SetEnabled(ns.queued or ns.JoinQueueDisabledReason() == nil)
    paint(joinButton)
    for role, control in pairs(roleChecks) do
        control:SetChecked(ns.HasRole(ns.prefs.roles, role))
        paint(control)
    end
    local selected = 0
    for id, control in pairs(dungeonChecks) do
        control:SetChecked(ns.prefs.dungeons[id] == true)
        if ns.prefs.dungeons[id] then selected = selected + 1 end
        paint(control)
    end
    selectionCount:SetText(selected .. " selected")
    groupsTab.selected, queueTab.selected = mode == "groups", mode == "queue"
    queueTab:SetText("All queued (" .. #players .. ")")
    paint(groupsTab)
    paint(queueTab)
    renderOutput(players)
    if hovered and hovered:IsShown() and hovered.tooltip then hovered.tooltip(hovered) end
end

local function switchTab(nextMode)
    clearHover()
    if nextMode ~= mode then
        scrollPositions[mode] = outputScroll:GetVerticalScroll()
        mode = nextMode
        pendingScroll = scrollPositions[mode]
    end
    ns.RefreshUI()
end

local function fitScreen()
    frame:SetScale(math.min(1, UIParent:GetWidth() / 1100, UIParent:GetHeight() / 780))
end

local function createUI()
    frame = CreateFrame("Frame", "GuildQueueFrame", UIParent, "BackdropTemplate")
    frame:SetSize(1060, 740)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    applyBackdrop(frame, windowBackdrop)
    surface(frame, C.background)
    fitScreen()
    table.insert(UISpecialFrames, "GuildQueueFrame")

    local header = panel(frame, 18, 18, 1024, 79, C.panel)
    label(header, "Guild Queue", 16, 4, 385, 28, "GameFontNormalHuge", C.heading)
    guildLabel = label(header, "", 16, 34, 430, 18, "GameFontNormal", C.text)
    label(header, "Guild members with the addon only", 16, 57, 430, 16, nil, C.muted)
    for index, entry in ipairs({ { "queued", "QUEUED" }, { "groups", "GROUPS" },
        { "unmatched", "UNMATCHED" } }) do
        local x = 524 + (index - 1) * 100
        counters[entry[1]] = label(header, "0", x, 12, 96, 26, "GameFontNormalLarge", C.heading)
        counters[entry[1]]:SetJustifyH("CENTER")
        local caption = label(header, entry[2], x, 44, 96, 16, "GameFontNormalSmall", C.muted)
        caption:SetJustifyH("CENTER")
    end
    queueStatus = label(header, "", 828, 20, 170, 36, "GameFontNormal", C.green, true)
    queueStatus:SetJustifyH("CENTER")
    button(frame, "", 1027, 0, 32, 32, function() frame:Hide() end, "close")

    local sidebar = panel(frame, 18, 112, 260, 574, C.panel)
    label(sidebar, "YOUR QUEUE", 14, 12, 230, 18, "GameFontNormalSmall", C.heading)
    label(sidebar, "Play as", 14, 36, 105, 22, "GameFontNormalLarge", C.text)
    label(sidebar, "Choose 1 or more", 122, 39, 124, 18, nil, C.muted)
    for index, role in ipairs({ 1, 2, 4 }) do
        local control = check(sidebar, ns.ROLE_NAMES[role], 12 + (index - 1) * 80, 64, 76, 76,
            function(self)
                local hadRole = ns.HasRole(ns.prefs.roles, self.role)
                if self:GetChecked() and not hadRole then
                    ns.prefs.roles = ns.prefs.roles + self.role
                elseif not self:GetChecked() and hadRole then
                    ns.prefs.roles = ns.prefs.roles - self.role
                end
                ns.PreferencesChanged()
            end, "role", role)
        control.role = role
        roleChecks[role] = control
    end
    solid(sidebar, 14, 156, 232, 1, C.border)
    label(sidebar, "Dungeons", 14, 168, 130, 24, "GameFontNormalLarge", C.heading)
    selectionCount = label(sidebar, "", 150, 172, 96, 18, nil, C.heading)
    selectionCount:SetJustifyH("RIGHT")
    label(sidebar, "Match on a shared dungeon.", 14, 197, 230, 18, nil, C.muted)
    dungeonScroll = scrollArea(sidebar, 12, 224, 236, 206, "dungeonScroll")
    dungeonScroll.content:SetHeight(math.max(1, #ns.DUNGEONS * 38))
    for index, dungeon in ipairs(ns.DUNGEONS) do
        local control = check(dungeonScroll.content, dungeon.name, 0, (index - 1) * 38, 218, 34,
            function(self)
                ns.prefs.dungeons[self.id] = self:GetChecked() and true or nil
                ns.PreferencesChanged()
            end, "dungeon")
        control.id = dungeon.id
        dungeonChecks[dungeon.id] = control
    end
    dungeonScroll.update()
    label(sidebar, "Scroll for the full dungeon list", 14, 439, 230, 16, nil, C.muted)
    button(sidebar, "Select all", 14, 464, 111, 28, function()
        for _, dungeon in ipairs(ns.DUNGEONS) do ns.prefs.dungeons[dungeon.id] = true end
        ns.PreferencesChanged()
    end, "selectAll")
    button(sidebar, "Clear", 135, 464, 111, 28, function()
        ns.prefs.dungeons = {}
        ns.PreferencesChanged()
    end, "clear")
    joinButton = button(sidebar, "Join queue", 14, 506, 232, 34, function()
        ns.SetQueued(not ns.queued)
    end, "queue")
    joinButton:SetMotionScriptsWhileDisabled(true)
    joinButton.tooltip = showQueueTooltip
    label(sidebar, "Selections update while queued.", 14, 548, 232, 16, nil, C.muted)

    groupsTab = button(frame, "Groups + individuals", 296, 112, 206, 32,
        function() switchTab("groups") end, "tab")
    groupsTab.mode = "groups"
    queueTab = button(frame, "All queued", 510, 112, 166, 32,
        function() switchTab("queue") end, "tab")
    queueTab.mode = "queue"
    label(frame, "Live guild queue", 864, 119, 178, 18, nil, C.green):SetJustifyH("RIGHT")
    outputScroll = scrollArea(frame, 296, 156, 746, 530, "outputScroll")
    solid(frame, 18, 695, 1024, 1, C.border)
    status = label(frame, "", 24, 699, 1012, 14, nil, C.muted)
    label(frame, "Invites are sent only when you click Create party. Leave the queue once your party is formed.",
        24, 715, 1012, 14, nil, C.heading)
    frame:SetScript("OnShow", function()
        fitScreen()
        ns.RefreshUI()
    end)
    frame:SetScript("OnHide", clearHover)
    frame:Hide()
end

function ns.ToggleUI()
    if not frame then createUI() end
    frame:SetShown(not frame:IsShown())
end
