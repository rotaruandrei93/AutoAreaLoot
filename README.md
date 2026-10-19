# AutoAreaLoot

[![ClassicAPI](https://img.shields.io/badge/ClassicAPI-Required-800080?labelColor=555555&style=flat-square)](CLASSICAPI_LINK)
[![Nampower](https://img.shields.io/badge/Nampower-Required-800080?labelColor=555555&style=flat-square)](https://github.com/brues-code/nampower)
[![pfQuest](https://img.shields.io/badge/pfQuest-Optional-dfb317?labelColor=555555&style=flat-square)](https://github.com/shagu/pfQuest)
[![HearthDB](https://img.shields.io/badge/HearthDB-Optional-dfb317?labelColor=555555&style=flat-square)](https://github.com/copypasteonly/HearthDB)
[![Join our Discord](https://img.shields.io/badge/Discord-Join%20our%20server-5865F2?logo=discord&logoColor=white)](https://discord.gg/XDMJVczNcY)

AutoAreaLoot automatically loots nearby corpses when it is safe to do so.

## Behavior

- Loots nearby corpses when an NPC death event fires
- Ignores Nampower death events whose units are clearly beyond loot range
- Individually configurable death and movement-stop triggers
- Optional in-combat looting, enabled by default
- Coalesces blocked triggers into one pending loot pass
- Runs one final pass after combat when a combat-time trigger occurred
- Avoids interrupting manual loot windows
- Preserves new death requests received during an active loot walk
- Coalesces same-area movement stops into the active walk, while preserving one
  follow-up after moving into a new loot area even if the active walk succeeds
- Limits same-area movement-stop scans to one every 0.5 seconds, but permits an
  immediate scan after moving at least five yards into a new loot area
- Waits 0.15 seconds after movement stops and cancels the attempt if movement
  resumes; death requests received while moving remain queued for that stop
- Detects actual player speed so RMB strafing, jumping, and other displacement
  are not dependent on forward/back movement events
- Uses a bounded latency-adjusted settling period after successful walks,
  avoiding rescans while loot is still being delivered
- `/aal` opens a small settings panel with enable, death, movement-stop, combat, and item filter toggles
- `/aal log` opens a compact, scrollable session loot log
- `/aal debug` opens a bounded, copyable diagnostic trace without flooding chat
- Confirms item loot from the player's localized loot messages and filters it against the corpse scan
- Uses corpse GUIDs to prevent repeated scans from creating duplicate live
  loot-confirmation expectations
- Shows money totals and optionally combines matching item rows
- Shows the newest 500 loot events first with timestamps when rows are uncombined
- Keeps timestamps aligned in a fixed column and shows item tooltips on hover
- Keeps full-session combined item totals and money totals independently of
  the recent-event display limit
- Reuses only the visible loot-log rows and defers redraws while the log is closed
- Supports resizing the loot log down to a compact minimum size
- Remembers the loot log's size and screen position
- Can optionally open the loot log automatically on login or `/reload`
- Automatically uses a built-in pfUI theme when pfUI is loaded
- Slash commands can still enable, disable, or report the addon status

## Item filter

This fork can loot only the items you choose instead of everything.

- Turn it on with **Only loot items on my list** in `/aal`, or `/aal filter on`
- Optionally also loot every item of a chosen quality or better (`/aal quality green`)
- Choose whether money is still looted while filtering (`/aal money on|off`)
- Items that are not wanted stay on the corpse
- The filter menu (`/aal items`, or **Edit Filter List...** in `/aal`):
  - drag an item from your bags onto the **+** slot to add it
  - search by name or item ID in the pfQuest-HDB item database (needs
    pfQuest-HDB and HearthDB.dll)
  - scrollable result and filter lists with an **Add** / **Remove** button per item
- ESC closes the filter menu first, then the settings panel

## Requirements

| Requirement | Needed for |
| --- | --- |
| [ClassicAPI](https://github.com/brues-code/ClassicAPI) DLL with `C_Loot.LootAllCorpses` | Normal looting (required) |
| [ClassicAPI](https://github.com/brues-code/ClassicAPI) DLL with `C_Loot.ScanNearbyLoot`, `C_Loot.LootUnitItem` and `C_Loot.LootUnit` | The item filter (required when the filter is on) |
| [pfQuest-HDB](https://github.com/rivi-s/pfQuest-HDB-Install) | Searching items in the filter menu |
| [HearthDB.dll](https://github.com/copypasteonly/HearthDB) | Required by pfQuest-HDB to read its item database |
| [Nampower](https://github.com/brues-code/nampower) | Reliable death detection |

AutoAreaLoot checks for the ClassicAPI functions at runtime and prints a chat
message if they are missing. With the filter on and the filter functions
missing, nothing is looted until the DLL is updated or the filter is turned off.

### Item search (pfQuest-HDB + HearthDB)

The filter menu search uses only the
[pfQuest-HDB](https://github.com/rivi-s/pfQuest-HDB-Install) item database,
which is read through [HearthDB.dll](https://github.com/copypasteonly/HearthDB).
It can find any item pfQuest knows, including Turtle WoW custom items. There is
no other search source: without pfQuest-HDB and HearthDB the menu shows a
message and the search returns nothing. Adding items does not need the search:
you can always drag an item from your bags onto the **+** slot or use
`/aal add Item Name`.

Nampower is optional. When its `UNIT_DIED` event is available, the addon uses it; otherwise it falls back to `CHAT_MSG_COMBAT_HOSTILE_DEATH`.

## Installation

In the launcher, choose **Add Addon from Git** and use your fork's URL, for example:

```text
https://github.com/<your-username>/AutoAreaLoot.git
```

Original addon by Foulwerp: <https://github.com/Foulwerp/AutoAreaLoot>

The addon should be installed as:

```text
Interface/AddOns/AutoAreaLoot
```

## Commands

```text
/aal on
/aal off
/aal status
/aal log
/aal debug
/aal debug off
/aal debug clear
/aal items
/aal filter on|off
/aal add [shift-click an item, or type the name]
/aal remove [item]
/aal list
/aal clear
/aal quality off|grey|white|green|blue|purple|orange
/aal money on|off
/aal help
```

Typing `/aal` without an argument opens or closes the settings panel.
The debug window records precise trigger, scheduling, ClassicAPI scan, and loot
confirmation steps. Choose **Select All** to pause capture and select the trace,
then press `Ctrl+C` to copy a report.
