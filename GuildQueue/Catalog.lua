local _, ns = ...

ns.PREFIX = "GuildQueue1"
ns.HEARTBEAT = 20
ns.TIMEOUT = 75
ns.ROLE = { TANK = 1, HEALER = 2, DAMAGER = 4 }
ns.ROLE_NAMES = { [1] = "Tank", [2] = "Healer", [4] = "Damage" }
ns.SLOTS = { 1, 2, 4, 4, 4 }

-- Addon-local, permanent protocol IDs, NOT Blizzard dungeon/activity IDs.
-- Never renumber an existing entry. New entries must use new IDs.
-- This is a selectable catalog, not a claim that a character can enter a dungeon.
-- Forever native LFG-recommended bands, per Warcraft Tavern:
-- https://www.warcrafttavern.com/forever/guides/dungeons/
-- Recommendations, not minimum-entry restrictions or encounter-level bands.
ns.DUNGEONS = {
    { id = 1, name = "Ragefire Chasm", minLevel = 13, maxLevel = 18 },
    { id = 2, name = "Hall of Thanes", minLevel = 13, maxLevel = 20 },
    { id = 3, name = "Ruins of Lordaeron", minLevel = 15, maxLevel = 22 },
    { id = 4, name = "Wailing Caverns", minLevel = 15, maxLevel = 24 },
    { id = 5, name = "The Deadmines", minLevel = 17, maxLevel = 26 },
    { id = 6, name = "Shadowfang Keep", minLevel = 20, maxLevel = 30 },
    { id = 7, name = "Blackfathom Deeps", minLevel = 24, maxLevel = 32 },
    { id = 8, name = "The Stockade", minLevel = 24, maxLevel = 32 },
    { id = 9, name = "Excavation Site", minLevel = 26, maxLevel = 33 },
    { id = 10, name = "City of Dalaran", minLevel = 28, maxLevel = 35 },
    { id = 11, name = "Gnomeregan", minLevel = 29, maxLevel = 38 },
    { id = 12, name = "Razorfen Kraul", minLevel = 29, maxLevel = 38 },
    { id = 13, name = "Scarlet Monastery: Graveyard", minLevel = 30, maxLevel = 38 },
    { id = 14, name = "Scarlet Monastery: Library", minLevel = 33, maxLevel = 41 },
    { id = 15, name = "Scarlet Monastery: Armory", minLevel = 36, maxLevel = 44 },
    { id = 16, name = "Scarlet Monastery: Cathedral", minLevel = 38, maxLevel = 46 },
    { id = 17, name = "The Drowned City", minLevel = 35, maxLevel = 42 },
    { id = 18, name = "Razorfen Downs", minLevel = 37, maxLevel = 46 },
    { id = 19, name = "Krol'dok Stronghold", minLevel = 40, maxLevel = 47 },
    { id = 20, name = "Uldaman", minLevel = 41, maxLevel = 51 },
    { id = 21, name = "Zul'Farrak", minLevel = 44, maxLevel = 54 },
    { id = 22, name = "Maraudon", minLevel = 46, maxLevel = 55 },
    { id = 23, name = "Alcaz Prison", minLevel = 48, maxLevel = 55 },
    { id = 24, name = "Sunken Temple", minLevel = 50, maxLevel = 60 },
    { id = 25, name = "Blackrock Depths", minLevel = 52, maxLevel = 60 },
    { id = 26, name = "Dire Maul: East", minLevel = 54, maxLevel = 60 },
    { id = 27, name = "Dire Maul: West", minLevel = 56, maxLevel = 60 },
    { id = 28, name = "Dire Maul: North", minLevel = 56, maxLevel = 60 },
    { id = 29, name = "Lower Blackrock Spire", minLevel = 55, maxLevel = 60 },
    { id = 30, name = "Blackmaw Hold", minLevel = 55, maxLevel = 60 },
    { id = 31, name = "Shaper's Terrace", minLevel = 58, maxLevel = 60 },
    { id = 32, name = "Scholomance", minLevel = 58, maxLevel = 60 },
    { id = 33, name = "Stratholme: Main Gate", minLevel = 58, maxLevel = 60 },
    { id = 34, name = "Stratholme: Service Gate", minLevel = 58, maxLevel = 60 },
}
ns.DUNGEON_BY_ID = {}
for _, dungeon in ipairs(ns.DUNGEONS) do
    ns.DUNGEON_BY_ID[dungeon.id] = dungeon
end

function ns.HasRole(mask, role)
    return math.floor(mask / role) % 2 == 1
end

-- Intersect selections without depending on a client bit-operation library.
function ns.FilterRoles(mask, allowed)
    if type(mask) ~= "number" or mask % 1 ~= 0 or mask < 0 or mask > 7 then return 0 end
    local filtered = 0
    for _, role in ipairs({ 1, 2, 4 }) do
        if ns.HasRole(mask, role) and ns.HasRole(allowed, role) then filtered = filtered + role end
    end
    return filtered
end

function ns.RoleText(mask)
    local names = {}
    for _, role in ipairs({ 1, 2, 4 }) do
        if ns.HasRole(mask, role) then
            names[#names + 1] = ns.ROLE_NAMES[role]
        end
    end
    return table.concat(names, "/")
end

function ns.CommonDungeons(left, right)
    local shared = {}
    for _, dungeon in ipairs(ns.DUNGEONS) do
        if left[dungeon.id] and right[dungeon.id] then shared[dungeon.id] = true end
    end
    return shared
end

function ns.DungeonName(dungeon)
    if dungeon.minLevel and dungeon.maxLevel then
        return dungeon.name .. " (" .. dungeon.minLevel .. "-" .. dungeon.maxLevel .. ")"
    end
    return dungeon.name
end

function ns.DungeonText(selected)
    local names = {}
    for _, dungeon in ipairs(ns.DUNGEONS) do
        if selected[dungeon.id] then
            names[#names + 1] = ns.DungeonName(dungeon)
        end
    end
    return table.concat(names, ", ")
end

function ns.SafeText(text)
    return (text:gsub("|", "||"))
end
