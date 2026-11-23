# Guild Queue Changelog

## Closed beta change history

### v0.19.0 — changes since v0.16.5

- **Whole-party queues:** leaders can list their 2–5 player party using WoW-assigned roles and their selected dungeons. The party stays together, and other members need neither guild membership nor the addon.
- **Individual party-member queues:** nonleaders can queue separately with multiple class-allowed roles. A leader's party listing takes precedence without duplicates; still-active individual entries resume when it ends.
- **Automatic listing updates:** queued parties update as members, roles or dungeon selections change, preserving queue age. Temporarily invalid or unavailable party data pauses the listing until it recovers.
- **Per-dungeon match options:** see a separate option for every selected dungeon with compatible recruits, including partial matches. Options may share players and are not reservations.
- **Safer recruitment:** each card invites only its missing recruits on click. Ten-second **Forming...** windows block conflicting options while unrelated matches remain usable.
- **Simpler controls:** removed **Select all** and moved **Join queue** up. Party leaders see guidance for WoW's role controls; solo players and nonleaders retain multi-role selectors.

### v0.16.5

- Initial closed-beta release, with optional queue-view navigation controlled by `GuildQueue/Config.lua`.
