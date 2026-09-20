# GuildLedger

A World of Warcraft (retail) addon that scans your guild bank, syncs that
snapshot across the guild, and keeps a guild-shared shopping list of what
still needs to be stocked.

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
3. **Shopping list** — officers (configurable rank threshold) maintain a
   shared list of items + desired quantities. The UI diffs that list against
   the cached bank contents and shows stock over target as `35 / 200`, green
   once the target is met and red while it isn't.
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
| `/gledger sync` | Ask the guild for a fresh bank snapshot and shopping list. |
| `/gledger config` | Open the options panel. |
| `/gledger scan` | Force a bank scan (must be at a guild banker). |
| `/gledger status` | Print guild binding, cache contents and guild bank API availability. |
| `/gledger debug` | Toggle trace output. Persists across reloads. |

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
- **Officer rank threshold** — guild rank index (0 = Guild Master) at or
  below which a member may edit the shopping list.
- **Font size** — text size throughout the window, 10–24 (default 14).
- **Low stock threshold** — reserved; nothing reads it yet.

## At the auction house

Opening the auction house pins a narrow panel to the side of the window (it
flips to the left if there's no room on the right) listing every shopping
list entry, most-short-of-target first, with how many are still needed.
Clicking a row puts the item name in the auction house search box and runs
the search.

The panel only appears when there's actually something on the list, and its
close button dismisses it for that visit. Opening the auction house also asks
the guild for a fresh list (at most once a minute), so you aren't shopping
from whatever snapshot you had at login.

Driving Blizzard's search means calling into `Blizzard_AuctionHouseUI`
internals, which are not a stable API. `SearchAuctionHouse` tries the search
bar's `StartSearch`, then the search box's own `OnEnterPressed`, then
`C_AuctionHouse.SendBrowseQuery`, each wrapped in `pcall`. The item name is
written into the search box before any of that, so the worst case after a
patch renames something is "press Enter yourself", not a Lua error.

## Who can edit the shopping list

The list is read-only for everyone below the officer rank threshold. That
restriction is enforced **on receipt**, not just in the UI: `OnCommReceived`
checks the sender's guild rank from the roster before accepting a list
snapshot. Senders of addon messages are supplied by the server and can't be
forged, so a modified client that broadcasts edits it isn't entitled to is
simply ignored by everyone else.

Bank snapshots are accepted from anyone — a scan is an observation that
whoever is standing at the banker can legitimately make.

`GuildLedger.ALWAYS_ALLOWED_EDITORS` in `Core.lua` is an allowlist of
characters who may edit regardless of rank. It lives in shared code rather
than saved variables because every client validates against its own copy: an
entry only one person had would be rejected by everyone else. Keys are
`"Name"` (that name on any realm) or `"Name-Realm"` (that character only).

## Project layout

```
GuildLedger.toc     Addon manifest (## Interface 120100, retail 12.1.0)
Core.lua            AceAddon setup, per-guild data binding, permissions,
                    slash commands, tracing
BankScan.lua        Scans the guild bank UI into guildData.bank
Comm.lua            Broadcasts/receives bank + shopping list snapshots (AceComm)
ShoppingList.lua    CRUD + have/need diff logic for the shared shopping list
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
tabs and item stacks recorded.

Errors show up in BugSack/!BugGrabber if you have them. Worth checking first:
a function that silently never runs usually means something earlier in the
same handler threw.

## Known rough edges

- **Shopping list edits are last-writer-wins with no timestamp.** Each edit
  broadcasts the whole list and receivers replace theirs wholesale, so two
  officers editing within the same moment can lose one edit and end up with
  different lists until the next edit repairs it. Deliberate: a per-item
  merge with tombstones is a lot of machinery for a race that rarely happens
  in a small guild.
- **Sync is best-effort.** There's no server; a catch-up request is only
  answered if an officer is online to answer it. Otherwise the client retries
  next login.
- **The officer rank threshold is per-client.** Receive-side validation reads
  the *receiver's* setting, so guildmates who configure it differently will
  disagree about who may edit. Moving the threshold into the synced guild
  data would fix this properly.
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
