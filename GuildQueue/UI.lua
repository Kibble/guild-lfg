local addonName, ns = ...
local frame, status, guildLabel, queueStatus, joinButton, groupsTab, queueTab, dungeonTab, questTab, minimapButton
local sidebar, queueViewStatus, defaultView, roleView, roleToolbar, roleTitle
local outputScroll, dungeonScroll, selectionCount, questToolbar, questZone, shareQuests
local guildHint, updateButton, updateDialog
local expandedQuests = {}
local roleChecks, dungeonChecks, counters = {}, {}, {}
local mode, dungeonMode, hovered, pendingScroll = "groups", "groups", nil, nil
local defaultMode = "groups"
local scrollPositions = { groups = 0, queue = 0, roles = 0, questing = 0 }
local pools = { groups = {}, people = {}, headings = {}, empty = {}, questing = {},
    rolePeople = {}, roleEmpty = {} }
local CONTENT_WIDTH, QUEST_WIDTH, QUEST_TOOLBAR_HEIGHT = 728, 1006, 136
local ROLE_COLUMN_WIDTH, ROLE_ROW_HEIGHT = 234, 124
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

local function showMinimapTooltip(control)
    GameTooltip:SetOwner(control, "ANCHOR_RIGHT")
    GameTooltip:SetText("Guild Queue")
    GameTooltip:AddLine("Installed version: " .. (ns.addonVersion and "v" .. ns.SafeText(ns.addonVersion) or "unknown"),
        1, 1, 1, true)
    local version = ns.GetUpdateVersion()
    if version then
        GameTooltip:AddLine("Newer version detected: v" .. ns.SafeText(version), C.gold[1], C.gold[2], C.gold[3], true)
        GameTooltip:AddLine("Reported by a guildmate; not verified against GitHub. May be relayed.", C.muted[1], C.muted[2], C.muted[3], true)
        GameTooltip:AddLine("Open Guild Queue and click the gold version notice for the manual download link.", 1, 1, 1, true)
    end
    GameTooltip:AddLine(control.tooltipText, 1, 1, 1, true)
    GameTooltip:Show()
end

local function showPartyTooltip(control)
    GameTooltip:SetOwner(control, "ANCHOR_RIGHT")
    GameTooltip:SetText(control.actionLabel or "Create party")
    GameTooltip:AddLine(ns.CreatePartyDisabledReason(control.group)
        or "Invite the other matched guild members who are not already in your party. Each player must accept.",
        1, 1, 1, true)
    GameTooltip:Show()
end

local function showQueueInviteTooltip(control)
    GameTooltip:SetOwner(control, "ANCHOR_RIGHT")
    GameTooltip:SetText(control.actionLabel or "Invite")
    GameTooltip:AddLine(ns.QueueInviteDisabledReason(control.memberName, control.requestedRole)
        or ("Request " .. (ns.ROLE_NAMES[control.requestedRole] or "a role")
            .. " and invite this player. Updated addons receive a role notice. Confirm the role with them; it is not assigned automatically."), 1, 1, 1, true)
    GameTooltip:Show()
end

local function showQuestInviteTooltip(control)
    GameTooltip:SetOwner(control, "ANCHOR_RIGHT")
    GameTooltip:SetText(control.actionLabel or "Invite")
    GameTooltip:AddLine(ns.QuestInviteDisabledReason(control.memberName)
        or "Invite this guild member to your party. They must accept.", 1, 1, 1, true)
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
    elseif control.guildQueueKind == "tab" or control.guildQueueKind == "viewSwitch" then
        if control.mainTab then
            if control.selected then PanelTemplates_SelectTab(control) else PanelTemplates_DeselectTab(control) end
            return -- Native visibility/color changes; both states share fixed geometry.
        end
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

local function refreshUpdateNotice()
    local version = ns.GetUpdateVersion()
    if updateButton then
        guildHint:SetShown(version == nil)
        updateButton:SetShown(version ~= nil)
        updateButton:SetText(version and "Newer version detected: v" .. ns.SafeText(version) or "")
    end
    if updateDialog and updateDialog:IsShown() then
        if not version then
            updateDialog:Hide()
        else
            updateDialog.installedVersion:SetText("Installed version: "
                .. (ns.addonVersion and "v" .. ns.SafeText(ns.addonVersion) or "unknown"))
            updateDialog.newerVersion:SetText("Guildmate-reported version: v" .. ns.SafeText(version))
        end
    end
end

local function showUpdateDialog()
    if not ns.GetUpdateVersion() then return end
    if not updateDialog then
        local dialog = CreateFrame("Frame", "GuildQueueUpdateDialog", UIParent, "BackdropTemplate")
        updateDialog = dialog
        dialog.guildQueueKind = "updateDialog"
        dialog:SetSize(480, 280)
        dialog:SetPoint("CENTER")
        dialog:SetFrameStrata("DIALOG")
        dialog:SetFrameLevel(frame:GetFrameLevel() + 10)
        dialog:SetClampedToScreen(true)
        dialog:EnableMouse(true)
        applyBackdrop(dialog, windowBackdrop)
        surface(dialog, C.background)
        label(dialog, "Guild Queue update", 22, 16, 414, 28, "GameFontNormalLarge", C.heading)
        label(dialog, "Reported by a guildmate; not verified against GitHub. May be relayed.\nNothing is downloaded or installed automatically.",
            22, 52, 436, 40, nil, C.muted, true)
        dialog.installedVersion = label(dialog, "", 22, 100, 436, 20, "GameFontNormal", C.text)
        dialog.installedVersion.guildQueueKind = "updateInstalledVersion"
        dialog.newerVersion = label(dialog, "", 22, 124, 436, 20, "GameFontNormal", C.gold)
        dialog.newerVersion.guildQueueKind = "updateReportedVersion"
        label(dialog, "Copy the link with Ctrl+C, then open it in your browser.\nClose WoW before installing; restart afterward.",
            22, 158, 436, 38, nil, C.text, true)
        local link = CreateFrame("EditBox", nil, dialog, "InputBoxTemplate")
        dialog.link = link
        link.guildQueueKind = "updateURL"
        place(link, 22, 207, 436, 28)
        link:SetAutoFocus(false)
        link:SetText(ns.UPDATE_URL)
        -- Keep this a copy-only project link, never peer-provided or user-edited text.
        link:SetScript("OnTextChanged", function(self, userInput)
            if userInput then
                self:SetText(ns.UPDATE_URL)
                self:HighlightText()
            end
        end)
        link:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
        link:SetScript("OnMouseUp", function(self) self:HighlightText() end)
        link:SetScript("OnEscapePressed", function() dialog:Hide() end)
        label(dialog, "Fixed project link (manual copy only).", 22, 241, 436, 18, nil, C.muted)
        dialog.close = button(dialog, "", 446, 4, 32, 32, function() dialog:Hide() end, "close")
        dialog.close.guildQueueKind = "updateClose"
        local function fitDialog()
            dialog:SetScale(math.min(1, UIParent:GetWidth() / 520, UIParent:GetHeight() / 320))
        end
        dialog:SetScript("OnShow", function()
            fitDialog()
            refreshUpdateNotice()
        end)
        UIParent:HookScript("OnSizeChanged", fitDialog)
        table.insert(UISpecialFrames, "GuildQueueUpdateDialog")
        dialog:Hide()
    end
    updateDialog:Show()
    updateDialog.link:SetFocus()
    updateDialog.link:HighlightText()
end

local function bottomTab(parent, text, previous, callback, tabMode)
    -- Native Auction House-style tabs without loading its behavior-specific mixins.
    local control = CreateFrame("Button", nil, parent, "PanelTabButtonTemplate")
    control.guildQueueKind, control.mainTab, control.mode = "tab", true, tabMode
    control:SetText(text)
    control.caption = control.Text
    -- Use one silhouette for every state, not the taller native selected shape.
    -- Only desaturation and the native font color change when a tab is selected.
    control.selectedTextY, control.deselectedTextY = -3, -3
    for part, atlas in pairs({ Left = "uiframe-activetab-left", Middle = "_uiframe-activetab-center",
        Right = "uiframe-activetab-right" }) do
        local active = control[part .. "Active"]
        active:SetDesaturated(false)
        for _, suffix in ipairs({ "", "Highlight" }) do
            local texture = control[part .. suffix]
            texture:SetAtlas(atlas, true)
            texture:ClearAllPoints()
            texture:SetAllPoints(active)
            texture:SetDesaturated(true)
        end
    end
    PanelTemplates_TabResize(control, 20, nil, 70)
    if previous then
        -- The art extends 8 pixels right and up to 3 left beyond each button.
        -- A 12-pixel frame gap keeps both selected/inactive states separate.
        control:SetPoint("LEFT", previous, "RIGHT", 12, 0)
    else
        control:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 20, -28)
    end
    control:SetScript("OnClick", callback)
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
    scroll.layout = function(nextX, nextY, nextWidth, nextHeight)
        width, height = nextWidth, nextHeight
        place(scroll, nextX, nextY, width - 14, height)
        scroll.content:SetWidth(width - 18)
        place(scroll.track, nextX + width - 16, nextY, 16, height)
        update()
    end
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
    for _, player in ipairs(group.members) do
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
    local count = #group.members
    card.matched:SetText(count .. " / 5 matched")
    colorText(card.matched, count == 5 and C.green or C.heading)
    card.kicker:SetText(own and (count < 5 and "YOUR PARTIAL MATCH" or "YOUR SUGGESTED GROUP")
        or ("SUGGESTED GROUP " .. index))
    local dungeon = ns.DUNGEON_BY_ID[group.dungeonID]
    local title = dungeon and ns.DungeonName(dungeon) or "Shared dungeon"
    card.title:SetText(ns.SafeText(title))
    card.common:SetText("Common dungeons: " .. ns.SafeText(ns.DungeonText(group.dungeons)))
    card.tooltipTitle = ns.SafeText(title)
    card.tooltipText = "Common dungeons: " .. ns.SafeText(ns.DungeonText(group.dungeons))
    for slot, tile in ipairs(card.tiles) do
        local player = group.slots[slot]
        place(tile, 14 + (slot - 1) * 141, own and 110 or 102, 135, own and 68 or 56)
        tile:Show()
        tile.roleIcon:SetDesaturated(not player)
        colorText(tile.roleLabel, player and C.heading or C.muted)
        if player then
            tile.name:SetText(displayName(player))
            colorText(tile.name, player.name == ns.playerName and C.green or C.text)
            updateRoleIcons(tile.roleIcons, own and player.roles or 0, 9, 47, 16)
            surface(tile, player.name == ns.playerName and C.own or C.tile,
                player.name == ns.playerName and C.green or C.border)
            playerTooltip(tile, player)
        else
            tile.player = nil
            tile.name:SetText("Needed")
            colorText(tile.name, C.muted)
            updateRoleIcons(tile.roleIcons, 0, 9, 47, 16)
            surface(tile, C.tile, C.border)
            tile.tooltipTitle = ns.ROLE_NAMES[ns.SLOTS[slot]] .. " needed"
            tile.tooltipText = "Open role slot. Waiting for a compatible guild member who shares a dungeon."
        end
    end
    card.note:SetShown(own)
    if own then
        card.note:SetText("You + " .. (count - 1) .. (count == 2 and " guildmate. " or " guildmates. ")
            .. (count < 5 and ((5 - count) .. (count == 4 and " open slot. " or " open slots. ")
                .. "Invitations are manual.")
                or "Everyone must accept their invitation."))
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
        local reason, _, existingParty = ns.CreatePartyDisabledReason(group)
        local formation = ns.FormationStatus(group)
        local forming = formation and not formation.isOwner
        control.actionLabel = forming and "Forming..." or existingParty and "Invite Others" or "Create party"
        control:SetText(control.actionLabel)
        if forming then
            local formingReason = ns.FormationDisabledReason(group)
            card.note:SetText(formingReason)
        elseif existingParty then
            card.note:SetText("Invite only suggested members not already in your party.")
        elseif formation then
            card.note:SetText("You are inviting this matchup. Others are paused for " .. formation.remaining .. "s.")
        end
        control:SetEnabled(reason == nil)
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

local function emptyCard(title, text, y, width)
    width = width or CONTENT_WIDTH
    local card = acquire(pools.empty, function()
        local control = panel(outputScroll.content, 0, 0, CONTENT_WIDTH, 90, C.card)
        control.guildQueueKind = "empty"
        control.title = label(control, "", 18, 14, 692, 24, "GameFontNormal", C.heading)
        control.text = label(control, "", 18, 43, 692, 32, nil, C.muted, true)
        return control
    end)
    place(card, 0, y, width, 90)
    card.title:SetWidth(width - 36)
    card.text:SetWidth(width - 36)
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

local function newRolePersonCard()
    local card = panel(outputScroll.content, 0, 0, ROLE_COLUMN_WIDTH, 112, C.card)
    card.guildQueueKind = "rolePlayer"
    card.name = label(card, "", 10, 6, ROLE_COLUMN_WIDTH - 20, 20, "GameFontNormal", C.text)
    card.wait = label(card, "", 10, 30, ROLE_COLUMN_WIDTH - 20, 16, nil, C.muted)
    card.dungeons = label(card, "", 10, 49, ROLE_COLUMN_WIDTH - 20, 26, nil, C.muted, true)
    card.invite = button(card, "Invite", 10, 82, ROLE_COLUMN_WIDTH - 20, 24, function(self)
        ns.InviteQueuedPlayer(self.memberName, self.requestedRole)
    end, "queueInvite")
    card.invite:SetMotionScriptsWhileDisabled(true)
    card.invite.tooltip = showQueueInviteTooltip
    bindHover(card, showTextTooltip)
    return card
end

local function newRoleEmpty()
    local card = panel(outputScroll.content, 0, 0, ROLE_COLUMN_WIDTH, 72, C.card)
    card.message = label(card, "No compatible players queued for this role.", 10, 10,
        ROLE_COLUMN_WIDTH - 20, 52, nil, C.muted, true)
    return card
end

local function renderRoleList()
    local lists, reason = ns.GetRoleLists()
    local now, height = GetServerTime(), 136
    roleToolbar.hint:SetText(reason or (next(ns.prefs.dungeons)
        and "Offered roles, longest waiting first. Existing-party compatibility is checked; confirm requested roles."
        or "Select dungeons on the left to see players with shared selections."))
    for index, role in ipairs({ 1, 2, 4 }) do
        local column, x = lists[role], (index - 1) * (ROLE_COLUMN_WIDTH + 12)
        roleToolbar.columns[role]:SetText(ns.ROLE_NAMES[role] .. " (" .. #column .. ")")
        if #column == 0 then
            local empty = acquire(pools.roleEmpty, newRoleEmpty)
            place(empty, x, 64, ROLE_COLUMN_WIDTH, 72)
        end
        for row, entry in ipairs(column) do
            local player = entry.player
            local card = acquire(pools.rolePeople, newRolePersonCard)
            place(card, x, 64 + (row - 1) * ROLE_ROW_HEIGHT, ROLE_COLUMN_WIDTH, 112)
            card.role = role
            card.name:SetText(displayName(player))
            colorText(card.name, player.name == ns.playerName and C.green or C.text)
            local seconds = math.max(0, now - player.joinedAt)
            card.wait:SetText(string.format("Queued %dm %02ds", math.floor(seconds / 60), seconds % 60))
            card.dungeons:SetText(ns.SafeText(ns.DungeonText(entry.dungeons)))
            surface(card, player.name == ns.playerName and C.own or C.card)
            playerTooltip(card, player)
            card.tooltipText = card.tooltipText .. "\nShared dungeons: " .. ns.SafeText(ns.DungeonText(entry.dungeons))
            if card.invite.memberName ~= player.name or card.invite.requestedRole ~= role then
                hideTooltip(card.invite)
            end
            card.invite.memberName, card.invite.requestedRole = player.name, role
            local disabled, _, inParty = ns.QueueInviteDisabledReason(player.name, role)
            local formation = ns.FormationStatus(player.name)
            inParty = inParty or entry.inParty
            card.invite.actionLabel = player.name == ns.playerName and "You"
                or inParty and "In party" or formation and not formation.isOwner and "Forming..."
                or ("Invite as " .. ns.ROLE_NAMES[role])
            card.invite:SetText(card.invite.actionLabel)
            card.invite:SetEnabled(disabled == nil)
            paint(card.invite)
        end
        height = math.max(height, 64 + #column * ROLE_ROW_HEIGHT)
    end
    return height
end

local function newQuestCard()
    local card = panel(outputScroll.content, 0, 0, QUEST_WIDTH, 78, C.card)
    card.guildQueueKind, card.lines = "questMember", {}
    card.name = label(card, "", 12, 10, QUEST_WIDTH - 322, 22, "GameFontNormal", C.text)
    card.level = label(card, "", QUEST_WIDTH - 302, 10, 178, 22, nil, C.muted)
    card.level:SetJustifyH("RIGHT")
    card.invite = button(card, "Invite", QUEST_WIDTH - 116, 6, 100, 26, function(self)
        ns.InviteQuestingPlayer(self.memberName)
    end, "questInvite")
    card.invite:SetMotionScriptsWhileDisabled(true)
    card.invite.tooltip = showQuestInviteTooltip
    card.summary = label(card, "", 12, 40, QUEST_WIDTH - 196, 24, nil, C.muted)
    card.expand = button(card, "Show quests", QUEST_WIDTH - 176, 36, 160, 28, function()
        if card.member then
            local key = (ns.guildKey or "") .. ":" .. card.member.name
            expandedQuests[key] = not expandedQuests[key]
            ns.RefreshUI()
        end
    end, "questExpand")
    bindHover(card, showTextTooltip)
    return card
end

local function renderQuesting()
    questZone:SetText("Current zone: " .. ns.SafeText(ns.QuestingZoneText()))
    shareQuests:SetChecked(ns.prefs.shareQuests)
    local members, y = ns.GetQuestingPlayers(), QUEST_TOOLBAR_HEIGHT + 6
    if #members == 0 then
        return emptyCard("No guildmates found in your zone",
            "Guild roster information can take a moment to arrive. Quest details require a guildmate using this version with sharing enabled.", y, QUEST_WIDTH)
    end
    for _, member in ipairs(members) do
        local card = acquire(pools.questing, newQuestCard)
        card.member = member
        card.invite.memberName = member.name
        local reason, _, inParty = ns.QuestInviteDisabledReason(member.name)
        local formation = ns.FormationStatus(member.name)
        card.invite.actionLabel = inParty and "In party" or formation and not formation.isOwner and "Forming..." or "Invite"
        card.invite:SetText(card.invite.actionLabel)
        card.invite:SetEnabled(reason == nil)
        paint(card.invite)
        card.name:SetText(ns.SafeText(member.name))
        card.level:SetText(member.level > 0 and ("Level " .. member.level) or "Level unavailable")
        local count = member.shared and #member.shared
        card.summary:SetText(count and (count .. " shared active quest" .. (count == 1 and "" or "s"))
            or "Quest data unavailable")
        local key = (ns.guildKey or "") .. ":" .. member.name
        local expanded = count and count > 0 and expandedQuests[key]
        card.expand:SetShown(count ~= nil and count > 0)
        card.expand:SetText(expanded and "Hide quests" or "Show quests")
        card.tooltipTitle = ns.SafeText(member.name)
        card.tooltipText = "Same zone does not guarantee the same layer or phase. "
            .. (count and "Quest details reflect recently shared snapshots." or "Quest sharing is optional, or data has expired/is still loading.")
        local used = expanded and count or 0
        place(card, 0, y, QUEST_WIDTH, 78 + used * 44)
        for index = 1, used do
            local line = card.lines[index]
            if not line then
                line = { title = label(card, "", 16, 0, QUEST_WIDTH - 32, 20, "GameFontNormal", C.heading),
                    status = label(card, "", 16, 0, QUEST_WIDTH - 32, 18, nil, C.muted) }
                card.lines[index] = line
            end
            local quest = member.shared[index]
            place(line.title, 16, 76 + (index - 1) * 44, QUEST_WIDTH - 32, 20)
            place(line.status, 16, 96 + (index - 1) * 44, QUEST_WIDTH - 32, 18)
            line.title:SetText(ns.SafeText(quest.title))
            line.status:SetText("You: " .. (quest.localComplete and "Ready to turn in" or "In progress")
                .. "  |  Guildmate: " .. (quest.peerComplete and "Ready to turn in" or "In progress"))
            line.title:Show()
            line.status:Show()
        end
        for index = used + 1, #card.lines do
            card.lines[index].title:Hide()
            card.lines[index].status:Hide()
        end
        y = y + card:GetHeight() + 12
    end
    return y
end

local function renderOutput(players)
    for _, pool in pairs(pools) do pool.used = 0 end
    questToolbar:SetShown(mode == "questing")
    roleToolbar:SetShown(mode == "roles")
    local y = 0
    if mode == "questing" then
        y = renderQuesting()
    elseif mode == "roles" then
        y = renderRoleList()
    elseif mode == "groups" then
        local ownIndex
        for index, group in ipairs(ns.groups) do
            if includesPlayer(group) then
                ownIndex = index
                break
            end
        end
        if ownIndex then y = renderGroup(ns.groups[ownIndex], ownIndex, true, y) end
        if #ns.groups == 0 then
            y = emptyCard("No compatible matches yet",
                "Two or more players need a shared dungeon and compatible role slots. "
                    .. "You can start a party before all five slots are filled.", y)
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
            if control.guildQueueKind == "rolePlayer" then
                hideTooltip(control.invite)
                control.invite.memberName, control.invite.requestedRole = nil, nil
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
    refreshUpdateNotice()
    -- Version receipts must update a hovered launcher even before the main window exists.
    -- Never take ownership back from a different control's tooltip.
    if minimapButton and hovered == minimapButton and minimapButton:IsShown()
        and GameTooltip:IsOwned(minimapButton) then
        showMinimapTooltip(minimapButton)
    end
    if not frame or not frame:IsShown() then return end
    local questing = mode == "questing"
    sidebar:SetShown(not questing)
    groupsTab:SetShown(not questing and mode ~= "roles")
    queueTab:SetShown(not questing and mode ~= "roles")
    roleTitle:SetShown(mode == "roles")
    defaultView:SetShown(not questing)
    roleView:SetShown(not questing)
    queueViewStatus:SetShown(not questing)
    queueViewStatus:SetText(mode == "roles" and "Shared dungeons" or "Live guild queue")
    if questing then
        outputScroll.layout(18, 112, 1024, 574)
    else
        outputScroll.layout(296, 156, 746, 530)
    end
    local players = ns.state:Sorted()
    guildLabel:SetText(ns.SafeText(ns.guildName or "No guild"))
    status:SetText(ns.SafeText(ns.StatusText()))
    local stateText = ns.queued and "Queued" or "Not queued"
    if ns.QueueUpdatePending() then stateText = "Waiting to broadcast" end
    queueStatus:SetText(stateText)
    colorText(queueStatus, ns.queued and C.green or C.muted)
    counters.queued:SetText(#players)
    counters.groups:SetText(#ns.groups)
    counters.unmatched:SetText(#ns.individuals)
    counters.online:SetText(ns.OnlineAddonCount())
    joinButton:SetText(ns.queued and "Leave queue" or "Join queue")
    -- Leaving must remain possible when identity/transport/selections are unavailable.
    joinButton:SetEnabled(ns.queued or ns.JoinQueueDisabledReason() == nil)
    paint(joinButton)
    for role, control in pairs(roleChecks) do
        local reason = ns.RoleDisabledReason(role)
        control:SetEnabled(reason == nil)
        control.tooltipText = reason or "Select one or more roles available for your class."
        control.roleIcon:SetDesaturated(reason ~= nil)
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
    dungeonTab.selected, questTab.selected = not questing, questing
    queueTab:SetText("All queued (" .. #players .. ")")
    paint(groupsTab)
    paint(queueTab)
    defaultView.selected, roleView.selected = mode ~= "roles", mode == "roles"
    paint(defaultView)
    paint(roleView)
    paint(dungeonTab)
    paint(questTab)
    renderOutput(players)
    if hovered and hovered:IsShown() and hovered.tooltip then hovered.tooltip(hovered) end
end

local function switchTab(nextMode)
    clearHover()
    if nextMode == "dungeons" then nextMode = dungeonMode end
    if nextMode ~= mode then
        scrollPositions[mode] = outputScroll:GetVerticalScroll()
        if mode ~= "questing" then dungeonMode = mode end
        mode = nextMode
        if mode ~= "questing" then dungeonMode = mode end
        if mode == "groups" or mode == "queue" then defaultMode = mode end
        pendingScroll = scrollPositions[mode]
    end
    ns.RefreshUI()
end

local function fitScreen()
    frame:SetScale(math.min(1, UIParent:GetWidth() / 1100, UIParent:GetHeight() / 820))
end

local function createUI()
    frame = CreateFrame("Frame", "GuildQueueFrame", UIParent, "BackdropTemplate")
    frame:SetSize(1060, 740)
    frame.tabPadding, frame.minTabWidth = 20, 70
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
    local getMetadata = C_AddOns and C_AddOns.GetAddOnMetadata
    local version = getMetadata and getMetadata(addonName, "Version")
    if type(version) ~= "string" or version == "" then version = "unknown" end
    label(header, "Guild Queue (v" .. ns.SafeText(version) .. ")", 16, 4, 385, 28, "GameFontNormalHuge", C.heading)
    guildLabel = label(header, "", 16, 34, 430, 18, "GameFontNormal", C.text)
    guildHint = label(header, "Guild members with addon seen in the last 75 seconds", 16, 57, 430, 16, nil, C.muted)
    guildHint.guildQueueKind = "guildHint"
    updateButton = CreateFrame("Button", nil, header)
    updateButton.guildQueueKind = "updateNotice"
    place(updateButton, 16, 57, 430, 16)
    updateButton.caption = label(updateButton, "", 0, 0, 430, 16, nil, C.gold)
    updateButton:SetFontString(updateButton.caption)
    updateButton.tooltipTitle = "Guildmate-reported update"
    updateButton.tooltipText = "May be relayed; not verified against GitHub. Click for version details and a manually copied project link."
    updateButton:SetScript("OnClick", showUpdateDialog)
    bindHover(updateButton, showTextTooltip)
    updateButton:Hide()
    for index, entry in ipairs({ { "queued", "QUEUED" }, { "groups", "GROUPS" },
        { "unmatched", "UNMATCHED" }, { "online", "ADDON ONLINE" } }) do
        local x = 452 + (index - 1) * 94
        counters[entry[1]] = label(header, "0", x, 12, 90, 26, "GameFontNormalLarge", C.heading)
        counters[entry[1]].guildQueueKind = "counter"
        counters[entry[1]].counterName = entry[1]
        counters[entry[1]]:SetJustifyH("CENTER")
        local caption = label(header, entry[2], x, 44, 90, 16, "GameFontNormalSmall", C.muted)
        caption:SetJustifyH("CENTER")
    end
    queueStatus = label(header, "", 828, 20, 170, 36, "GameFontNormal", C.green, true)
    queueStatus:SetJustifyH("CENTER")
    button(frame, "", 1027, 0, 32, 32, function() frame:Hide() end, "close")

    sidebar = panel(frame, 18, 112, 260, 574, C.panel)
    sidebar.guildQueueKind = "dungeonSidebar"
    label(sidebar, "YOUR QUEUE", 14, 12, 230, 18, "GameFontNormalSmall", C.heading)
    label(sidebar, "Play as", 14, 36, 105, 22, "GameFontNormalLarge", C.text)
    label(sidebar, "Choose 1 or more", 122, 39, 124, 18, nil, C.muted)
    for index, role in ipairs({ 1, 2, 4 }) do
        local control = check(sidebar, ns.ROLE_NAMES[role], 12 + (index - 1) * 80, 64, 76, 76,
            function(self)
                if ns.RoleDisabledReason(self.role) then
                    ns.PreferencesChanged()
                    return
                end
                local hadRole = ns.HasRole(ns.prefs.roles, self.role)
                if self:GetChecked() and not hadRole then
                    ns.prefs.roles = ns.prefs.roles + self.role
                elseif not self:GetChecked() and hadRole then
                    ns.prefs.roles = ns.prefs.roles - self.role
                end
                ns.PreferencesChanged()
            end, "role", role)
        control.role = role
        control:SetMotionScriptsWhileDisabled(true)
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
        local control = check(dungeonScroll.content, ns.DungeonName(dungeon), 0, (index - 1) * 38, 218, 34,
            function(self)
                ns.prefs.dungeons[self.id] = self:GetChecked() and true or nil
                ns.PreferencesChanged()
            end, "dungeon")
        control.id = dungeon.id
        dungeonChecks[dungeon.id] = control
    end
    dungeonScroll.update()
    label(sidebar, "Ranges are recommended levels", 14, 439, 230, 16, nil, C.muted)
    button(sidebar, "Select all", 14, 464, 232, 28, function()
        for _, dungeon in ipairs(ns.DUNGEONS) do ns.prefs.dungeons[dungeon.id] = true end
        ns.PreferencesChanged()
    end, "selectAll")
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
    dungeonTab = bottomTab(frame, "Dungeons", nil, function() switchTab("dungeons") end, "dungeons")
    questTab = bottomTab(frame, "Quests", dungeonTab, function() switchTab("questing") end, "questing")
    roleTitle = label(frame, "Role List", 296, 116, 380, 24, "GameFontNormalLarge", C.heading)
    queueViewStatus = label(frame, "Live guild queue", 690, 119, 126, 18, nil, C.green)
    queueViewStatus:SetJustifyH("RIGHT")
    defaultView = button(frame, "Default", 826, 112, 96, 32,
        function() switchTab(defaultMode) end, "viewSwitch")
    defaultView.viewMode = "default"
    roleView = button(frame, "Role List", 930, 112, 112, 32,
        function() switchTab("roles") end, "viewSwitch")
    roleView.viewMode = "roles"
    outputScroll = scrollArea(frame, 296, 156, 746, 530, "outputScroll")
    roleToolbar = CreateFrame("Frame", nil, outputScroll.content)
    roleToolbar.guildQueueKind = "roleToolbar"
    place(roleToolbar, 0, 0, CONTENT_WIDTH, 56)
    roleToolbar.hint = label(roleToolbar, "", 2, 0, CONTENT_WIDTH - 4, 18, nil, C.muted)
    roleToolbar.columns = {}
    for index, role in ipairs({ 1, 2, 4 }) do
        local x = (index - 1) * (ROLE_COLUMN_WIDTH + 12)
        roleIcon(roleToolbar, role, x + 8, 28, 20)
        roleToolbar.columns[role] = label(roleToolbar, "", x + 36, 26,
            ROLE_COLUMN_WIDTH - 44, 24, "GameFontNormal", C.heading)
    end
    roleToolbar:Hide()
    questToolbar = CreateFrame("Frame", nil, outputScroll.content)
    place(questToolbar, 0, 0, QUEST_WIDTH, QUEST_TOOLBAR_HEIGHT)
    label(questToolbar, "Guild members in your zone", 2, 0, QUEST_WIDTH - 4, 30, "GameFontNormalLarge", C.heading)
    questZone = label(questToolbar, "", 2, 32, QUEST_WIDTH - 4, 22, "GameFontNormal", C.text)
    shareQuests = check(questToolbar, "Share my active quests with my guild", 0, 64, QUEST_WIDTH - 4, 28,
        function(self) ns.SetQuestSharing(self:GetChecked()) end, "questSharing")
    shareQuests.tooltipTitle = "Optional quest sharing"
    shareQuests.tooltipText = "Off by default. Share active quest IDs and completion states with your guild; snapshots include zone ID and level as context. Guild-roster zones remain available without quest sharing. No coordinates or quest history. Turning off withdraws your snapshot."
    label(questToolbar, "Guild roster zones can include members without this addon. Shared quest data expires after 75 seconds; same zone does not guarantee the same layer or phase.",
        2, 98, QUEST_WIDTH - 4, 32, nil, C.muted, true)
    questToolbar:Hide()
    solid(frame, 18, 695, 1024, 1, C.border)
    status = label(frame, "", 24, 699, 1012, 14, nil, C.muted)
    label(frame, "Invitations are click-only. Stay queued while filling your party; leave when everyone is finished looking.",
        24, 715, 1012, 14, nil, C.heading)
    frame:SetScript("OnShow", function()
        fitScreen()
        ns.RefreshUI()
    end)
    frame:SetScript("OnHide", clearHover)
    frame:Hide()
end

function ns.InitializeMinimap()
    if minimapButton then return minimapButton end
    if not Minimap or not ns.prefs then return end
    local angle = ns.prefs.minimapAngle
    if type(angle) ~= "number" or angle ~= angle or angle < 0 or angle >= 360 then angle = 225 end
    ns.prefs.minimapAngle = angle
    local dragging, wasDragged = false, false
    local control = CreateFrame("Button", "GuildQueueMinimapButton", Minimap)
    minimapButton = control
    control:SetSize(31, 31)
    control:EnableMouse(true)
    control:SetMovable(true)
    control:SetFrameStrata("MEDIUM")
    control:SetFrameLevel(Minimap:GetFrameLevel() + 8)
    control:RegisterForClicks("LeftButtonUp")
    control:RegisterForDrag("LeftButton")
    control:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    local icon = control:CreateTexture(nil, "ARTWORK")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER", control, "CENTER", 0, 1)
    icon:SetTexture("Interface\\Icons\\INV_Misc_GroupLooking")
    icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
    local border = control:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT", control, "TOPLEFT")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    control.tooltipTitle = "Guild Queue"
    control.tooltipText = "Left-click to toggle Guild Queue. Drag to move around the minimap."
    local function position()
        local radians = math.rad(angle)
        control:ClearAllPoints()
        control:SetPoint("CENTER", Minimap, "CENTER", math.cos(radians) * (Minimap:GetWidth() / 2 + 8),
            math.sin(radians) * (Minimap:GetHeight() / 2 + 8))
    end
    local function drag()
        local centerX, centerY = Minimap:GetCenter()
        local scale = Minimap:GetEffectiveScale()
        if not centerX or not centerY or not scale or scale <= 0 then return end
        local x, y = GetCursorPosition()
        x, y = x / scale - centerX, y / scale - centerY
        if x == 0 and y == 0 then return end
        angle = math.deg(math.atan2(y, x)) % 360
        ns.prefs.minimapAngle = angle
        position()
    end
    local function stopDragging()
        dragging = false
        control:SetScript("OnUpdate", nil)
        hideTooltip(control)
    end
    control:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" then wasDragged = false end
    end)
    control:SetScript("OnDragStart", function(self)
        dragging, wasDragged = true, true
        hideTooltip(self)
        self:SetScript("OnUpdate", drag)
        drag()
    end)
    control:SetScript("OnDragStop", stopDragging)
    control:SetScript("OnHide", stopDragging)
    control:SetScript("OnClick", function(self, button)
        if button == "LeftButton" and not dragging and not wasDragged then
            hideTooltip(self)
            ns.ToggleUI()
        end
    end)
    control:SetScript("OnEnter", function(self)
        if dragging then return end
        clearHover()
        hovered = self
        showMinimapTooltip(self)
    end)
    control:SetScript("OnLeave", hideTooltip)
    Minimap:HookScript("OnSizeChanged", position)
    position()
    return control
end

function ns.ToggleUI()
    if not frame then createUI() end
    frame:SetShown(not frame:IsShown())
end
