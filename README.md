# GuildLedger

A World of Warcraft (retail) addon that scans your guild bank, syncs that
snapshot across the guild, and keeps a guild-shared shopping list of what
still needs to be stocked.

## How it works

Blizzard doesn't let addons read guild bank contents remotely — you can only
query it while standing at a guild banker with the bank window open. So:

1. **Scan** — when you open the guild bank, GuildLedger walks every tab/slot
   and records item, count, and tab.
2. **Sync** — the scan is broadcast to the rest of the guild over an addon
   message (guild channel), so people who weren't at the bank still see a
   recent snapshot. `/gledger sync` asks the guild for a fresher one if
   yours is stale.
3. **Shopping list** — officers (configurable rank threshold) maintain a
   shared list of items + desired quantities. The UI diffs that list against
   the cached bank contents and shows have/need per item.

## Commands

- `/gledger` — toggle the main window.
- `/gledger sync` — request a bank sync from the guild.
- `/gledger config` — open the options panel.

## Project layout

```
GuildLedger.toc     Addon manifest (bump ## Interface to match your client)
Core.lua            AceAddon setup, per-guild data binding, officer check
BankScan.lua        Scans the guild bank UI into guildData.bank
Comm.lua            Broadcasts/receives bank + shopping list snapshots (AceComm)
ShoppingList.lua    CRUD + have/need diff logic for the shared shopping list
UI.lua              AceGUI window: Bank Inventory tab, Shopping List tab
Config.lua          AceConfig options panel
Libs/embeds.xml     Pulls in the Ace3 libraries listed below
.pkgmeta            Externals so a packager (CurseForge/WowAce/BigWigs
                    packager) can vendor Ace3 automatically
```

## Getting Ace3 into `Libs/`

The addon depends on Ace3 (AceAddon, AceEvent, AceConsole, AceDB,
AceSerializer, AceComm, AceGUI, AceConfig) plus CallbackHandler-1.0 and
LibStub. `.pkgmeta` lists them as externals, so:

- **Easiest:** run this repo through the
  [BigWigs packager](https://github.com/BigWigsMods/packager) (what
  CurseForge/Wago use) — it reads `.pkgmeta` and checks out every library
  into `Libs/` automatically.
- **Manual:** download each library's current source from
  [wowace.com](https://www.wowace.com/projects/ace3/files) or its SVN repo
  and drop it into the matching `Libs/<LibName>` folder so the paths in
  `Libs/embeds.xml` resolve.

Without the libraries in place, the addon won't load (LibStub calls will
error).

## Known rough edges (MVP, first pass)

- **Verify the guild bank API in-game first.** `BankScan.lua` uses the
  long-standing globals (`QueryGuildBankTab`, `GetGuildBankTabInfo`,
  `GetGuildBankItemInfo`). These have been stable for years, but Blizzard
  periodically migrates old globals into `C_` namespaces — if the addon
  loads but the bank tab never populates, that's the first thing to check
  against Warcraft Wiki for the client version you're on.
- **`## Interface` in `GuildLedger.toc`** is a placeholder — set it to your
  client's build via `/run print(select(4, GetBuildInfo()))` in-game.
- Sync is last-writer-wins by timestamp (whole snapshot replaces whole
  snapshot). Fine for a bank/list that isn't being edited by two officers in
  the same second; a real conflict-merge strategy is a later improvement.
- No minimap button, no low-stock alerts yet, no addon-comm compression
  (large guild banks with lots of unique items could hit multiple addon
  message chunks — AceComm handles chunking, but very large syncs may be
  slow over guild chat's rate limits).

## Roadmap / feature ideas

- Low-stock threshold alerts (flag items below a configured count).
- Request queue: members request an item + qty; officers see a queue
  instead of guild-chat spam.
- Auto-build shopping list entries from a profession/crafting queue.
- Auction house price lookups (TSM/Auctionator hooks) on shopping list rows.
- Withdrawal log / audit trail.
- Export shopping list to Discord/clipboard.
- Minimap icon (LibDBIcon) and LDB data feed.
- Search/filter box in both tabs.
