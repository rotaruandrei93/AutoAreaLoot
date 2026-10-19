# AutoAreaLoot

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
  - search by name or item ID across your bags, items that have dropped for
    you, and the pfQuest item database
  - scrollable result and filter lists with an **Add** / **Remove** button per item
- ESC closes the filter menu first, then the settings panel

## Requirements

| Requirement | Needed for |
| --- | --- |
| [ClassicAPI](https://github.com/brues-code/ClassicAPI) DLL with `C_Loot.LootAllCorpses` | Normal looting (required) |
| [ClassicAPI](https://github.com/brues-code/ClassicAPI) DLL with `C_Loot.ScanNearbyLoot`, `C_Loot.LootUnitItem` and `C_Loot.LootUnit` | The item filter (required when the filter is on) |
| [HearthDB.dll](https://github.com/copypasteonly/HearthDB) | Reading the pfQuest-HDB item database (optional) |
| [pfQuest-HDB](https://github.com/rivi-s/pfQuest-HDB-Install) | Searching the full item database in the filter menu (optional) |
| Nampower | Reliable death detection (optional) |

AutoAreaLoot checks for the ClassicAPI functions at runtime and prints a chat
message if they are missing. With the filter on and the filter functions
missing, nothing is looted until the DLL is updated or the filter is turned off.

### HearthDB (optional)

The [pfQuest-HDB](https://github.com/rivi-s/pfQuest-HDB-Install) edition keeps
its item names in a SQLite database that is read through
[HearthDB.dll](https://github.com/copypasteonly/HearthDB). With both installed,
the filter menu search can find any item pfQuest knows, including Turtle WoW
custom items. Without it, the search still lists items in your bags
and items that have dropped for you, and you can always add an item by name
with `/aal add Item Name`.

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
