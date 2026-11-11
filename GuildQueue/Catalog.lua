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
ns.DUNGEONS = {
    { id = 1, name = "Ragefire Chasm" },
    { id = 2, name = "Hall of Thanes" },
    { id = 3, name = "Ruins of Lordaeron" },
    { id = 4, name = "Wailing Caverns" },
    { id = 5, name = "The Deadmines" },
    { id = 6, name = "Shadowfang Keep" },
    { id = 7, name = "Blackfathom Deeps" },
    { id = 8, name = "The Stockade" },
    { id = 9, name = "Excavation Site" },
    { id = 10, name = "City of Dalaran" },
    { id = 11, name = "Gnomeregan" },
    { id = 12, name = "Razorfen Kraul" },
    { id = 13, name = "Scarlet Monastery: Graveyard" },
    { id = 14, name = "Scarlet Monastery: Library" },
    { id = 15, name = "Scarlet Monastery: Armory" },
    { id = 16, name = "Scarlet Monastery: Cathedral" },
    { id = 17, name = "The Drowned City" },
    { id = 18, name = "Razorfen Downs" },
    { id = 19, name = "Krol'dok Stronghold" },
    { id = 20, name = "Uldaman" },
    { id = 21, name = "Zul'Farrak" },
    { id = 22, name = "Maraudon" },
    { id = 23, name = "Alcaz Prison" },
    { id = 24, name = "Sunken Temple" },
    { id = 25, name = "Blackrock Depths" },
    { id = 26, name = "Dire Maul: East" },
    { id = 27, name = "Dire Maul: West" },
    { id = 28, name = "Dire Maul: North" },
    { id = 29, name = "Lower Blackrock Spire" },
    { id = 30, name = "Blackmaw Hold" },
    { id = 31, name = "Shaper's Terrace" },
    { id = 32, name = "Scholomance" },
    { id = 33, name = "Stratholme: Main Gate" },
    { id = 34, name = "Stratholme: Service Gate" },
}
ns.DUNGEON_BY_ID = {}
for _, dungeon in ipairs(ns.DUNGEONS) do
    ns.DUNGEON_BY_ID[dungeon.id] = dungeon
end

function ns.HasRole(mask, role)
    return math.floor(mask / role) % 2 == 1
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

function ns.DungeonText(selected)
    local names = {}
    for _, dungeon in ipairs(ns.DUNGEONS) do
        if selected[dungeon.id] then
            names[#names + 1] = dungeon.name
        end
    end
    return table.concat(names, ", ")
end

function ns.SafeText(text)
    return (text:gsub("|", "||"))
end
