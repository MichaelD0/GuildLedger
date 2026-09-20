# GuildLedger

A World of Warcraft (retail) addon that scans your guild bank, syncs that
snapshot across the guild, and keeps a personal shopping list of what you
mean to stock it with.

## How it works

Blizzard doesn't let addons read guild bank contents remotely — you can only
query it while standing at a guild banker with the bank window open. So:

1. **Scan** — when you open the guild bank, GuildLedger walks every viewable
   tab/slot and records item, count, and tab. The scan re-reads everything a
   few times over ~3 seconds, because tab data arrives asynchronously.
2. **Sync** — the scan is broadcast to the rest of the guild over an addon
   message (guild channel), so people who weren't at the bank still see a
   recent snapshot. Clients also ask the guild to catch them up shortly after
   login, and `/gledger sync` does the same on demand.
3. **Shopping list** — you keep your own list of items + desired quantities.
   It's per character, saved locally, and never sent to anyone: the bank is
   the shared half of this addon, the list is yours. The UI diffs the list
   against the cached bank contents and shows stock over target as
   `35 / 200`, green once the target is met and red while it isn't.
4. **Shop** — at the auction house, a side panel lists what's still missing.
   Click a row and it searches for that item.

The window opens itself when you walk up to a guild banker, and closes again
when you leave — unless you already had it open, in which case it's yours and
stays put. **Scan bank** and **Sync** buttons sit at the bottom of the window
for when you'd rather not use slash commands.

## Commands

| Command | What it does |
| --- | --- |
| `/gledger` | Toggle the main window. |
| `/gledger sync` | Ask the guild for a fresh bank snapshot. |
| `/gledger config` | Open the options panel. |
| `/gledger scan` | Force a bank scan (must be at a guild banker). |
| `/gledger status` | Print guild binding, cache contents and guild bank API availability. |
| `/gledger debug` | Toggle trace output *to chat*. Persists across reloads. |
| `/gledger trace` | Report how many trace lines are buffered, and where they land. |
| `/gledger trace clear` | Empty the trace buffer. |

`/guildledger` works as an alias for all of the above.

## Options

Reachable via `/gledger config`:

- **Auto-broadcast after scanning** — send your scan to the guild
  automatically once a scan finishes (~3s after opening the bank).
- **Open the window at the guild bank** — show the GuildLedger window when
  the guild bank opens and hide it again when it closes. A window you opened
  yourself first is left alone on close.
- **Show the shopping list at the auction house** — pin the list beside the
  auction house window.
- **Font size** — text size throughout the window, 10–24 (default 14).
- **Low stock threshold** — reserved; nothing reads it yet.

## At the auction house

Opening the auction house pins a panel to the side of the window (it flips to
the left if there's no room on the right) listing every shopping list entry
icon-first, most-short-of-target first, with stock over target beside it.
Clicking a row puts the item name in the auction house search box and runs
the search.

The panel only appears when there's actually something on the list, and its
close button dismisses it for that visit. Opening the auction house also asks
the guild for a fresh bank snapshot (at most once a minute), so the "in bank"
column isn't quoting what you had at login while you decide what to buy.

Driving Blizzard's search means calling into `Blizzard_AuctionHouseUI`
internals, which are not a stable API. `SearchAuctionHouse` tries the search
bar's `StartSearch`, then the search box's own `OnEnterPressed`, then
`C_AuctionHouse.SendBrowseQuery`, each wrapped in `pcall`. The item name is
written into the search box before any of that, so the worst case after a
patch renames something is "press Enter yourself", not a Lua error.

## What is shared and what isn't

Only the bank snapshot travels between clients, and it's accepted from anyone
— a scan is an observation that whoever is standing at the banker can
legitimately make.

The shopping list never goes on the wire. It lives in `db.char`, so every
character keeps their own, and nobody needs a rank to edit it: there is no
shared copy to protect, no merge to lose an edit to, and no officer check to
configure. If you want the guild to see your list, paste it in chat.

A list saved back when it was guild-shared is moved into the current
character's list the first time that character's guild resolves; entries
already there win.

## Project layout

```
GuildLedger.toc     Addon manifest (## Interface 120100, retail 12.1.0)
Core.lua            AceAddon setup, per-guild data binding, slash commands,
                    tracing
BankScan.lua        Scans the guild bank UI into guildData.bank
Comm.lua            Broadcasts/receives bank snapshots (AceComm)
ShoppingList.lua    CRUD + have/need diff logic for the per-character list
UI.lua              AceGUI window: Bank Inventory tab, Shopping List tab,
                    Scan/Sync toolbar, auto-open at the guild bank
AuctionHouse.lua    Shopping list panel pinned to the auction house window
Config.lua          AceConfig options panel
Libs/               Vendored Ace3 libraries, committed to the repo
Libs/embeds.xml     Pulls in the Ace3 libraries listed below
.pkgmeta            Externals so a packager (CurseForge/WowAce/BigWigs
                    packager) can re-vendor Ace3 when updating
```

## Ace3 libraries

The addon depends on Ace3 (AceAddon, AceEvent, AceConsole, AceDB,
AceSerializer, AceComm, AceGUI, AceConfig) plus CallbackHandler-1.0 and
LibStub. These are **committed under `Libs/`**, so a fresh clone can be
dropped straight into `Interface/AddOns/` and will load as-is — no packager
or extra download step.

`.pkgmeta` still lists every library as an external, which is what a packager
build (CurseForge/Wago, via the
[BigWigs packager](https://github.com/BigWigsMods/packager)) uses. To update
the vendored copies, either let that packager refresh `Libs/` and commit the
result, or download the current source from
[wowace.com](https://www.wowace.com/projects/ace3/files) into the matching
`Libs/<LibName>` folder — keeping the paths in `Libs/embeds.xml` resolvable.

## Debugging

`/gledger status` prints everything worth knowing when the addon appears to
be doing nothing: whether a guild is bound, what the cache holds, whether
you're currently interacting with a guild banker, and whether the guild bank
API functions exist on your client.

`/gledger debug` adds a running trace of the scan — banker opened, tab count,
tabs and item stacks recorded — to your chat frame.

That trace is **also kept on disk regardless of whether `debug` is on**. The
last 200 lines live in `GuildLedgerDB.global.trace`, timestamped and tagged
with the character that produced them, and land in

```
WTF/Account/<account>/SavedVariables/GuildLedger.lua
```

WoW only writes saved variables on logout or `/reload`, so that file always
lags the live session by however long it's been since the last one — `/reload`
first if you want the current session's lines. `debug` therefore controls only
whether the trace is *printed*; it no longer controls whether it's *recorded*,
so a problem can be read back after the fact instead of needing tracing to
have been switched on before it happened.

`/gledger trace` reports how many lines are buffered; `/gledger trace clear`
empties it. A session-start marker is written on every load, so it's easy to
tell where one session's lines end and the next begins.

The same directory holds `!BugGrabber.lua` if you run BugSack/!BugGrabber,
which is where actual Lua errors (with stack and locals) end up.

Errors show up in BugSack/!BugGrabber if you have them. Worth checking first:
a function that silently never runs usually means something earlier in the
same handler threw.

## Known rough edges

- **The shopping list doesn't follow you between characters.** It's per
  character by design — that's what makes it free of merge conflicts and
  rank checks — but your alt starts with an empty one.
- **Sync is best-effort.** There's no server; a catch-up request is only
  answered if a guildmate with a newer snapshot is online to answer it.
  Otherwise the client retries next login.
- **The auction house panel rides on Blizzard internals.** See above: it
  degrades to filling the search box rather than erroring, but a patch can
  still make one-click search stop working until this is updated.
- No minimap button, no low-stock alerts, no addon-comm compression. Very
  large guild banks may sync slowly over guild chat's rate limits (AceComm
  chunks, but chunks are throttled).

## Roadmap / feature ideas

- Low-stock threshold alerts (flag items below a configured count).
- Request queue: members request an item + qty; officers see a queue
  instead of guild-chat spam.
- Auto-build shopping list entries from a profession/crafting queue.
- Auction house price lookups (TSM/Auctionator hooks) on shopping list rows
  — the AH panel shows what's missing, but no prices.
- Withdrawal log / audit trail.
- Export shopping list to Discord/clipboard.
- Minimap icon (LibDBIcon) and LDB data feed.
- Search/filter box on the shopping list too (the bank tab has one).
