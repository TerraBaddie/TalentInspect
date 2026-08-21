# TalentInspect v1.4.0

TalentInspect adds inspectable VanillaPlus talent trees to World of Warcraft 1.12.1, with support for the Blizzard default UI and pfUI.

## Installation

1. Remove or replace the previous `TalentInspect` addon folder.
2. Extract the single `TalentInspect` folder into `Interface\\AddOns\\`.
3. Restart World of Warcraft or reload the UI.

## Screenshots BUI / pfUI

<img width="500" height="474" alt="TalentInspect_GitHub_Preview_1_500px" src="https://github.com/user-attachments/assets/0566d6f1-252f-4437-964f-3785433cad06" />
<img width="500" height="474" alt="TalentInspect_GitHub_Preview_2_500px" src="https://github.com/user-attachments/assets/d6360309-35f6-4bee-959f-3ff2a54619ce" />

## Features
- Inspect VanillaPlus talent builds directly in-game.
- Full talent trees for all nine classes.
- Blizzard default UI and pfUI support.
- Live talent syncing with nearby group and guild players.
- Cached talent builds for previously inspected players.
- Complete grey 0-point talent trees when live data is unavailable.
- Yellow prerequisite Talent Lines.
- Live prerequisite learning from the active class.
- Learned prerequisite corrections can sync between TalentInspect users.
- Automatic fallback to packaged VanillaPlus talent data.
- Talent tooltips with ranks, descriptions, and prerequisite requirements.
- Shift + Left Click talent linking into chat.
- Native-style TalentFrame links.
- Two-position snap scrolling for taller VanillaPlus talent trees.
- Talent tab selection remains stable while inspecting and refreshing.
- 7-second request spam guard to prevent duplicate sync requests.
- Range, ownership, stale-target, and sync safety guards.
- Safe Guild and Friends-list Talents right-click integration.
- Separate prerequisite rendering for each talent tree to prevent lines carrying between tabs.
- Lightweight rendering designed for the WoW 1.12.1 client.

## v1.4.0 More Cross-Faction Improvements & Learned Talent Logout/Login Persistence

- Added persistent learned talent data so information survives logout and login, preventing previously learned talents from returning as blank icon placeholders.
- Added richer persistent class knowledge for all 9 Vanilla classes while keeping individual inspected-player records lightweight.
- Added stronger learned-data fallback behavior, combining live discoveries with packaged VanillaPlus talent data when information is missing.
- Further hardened no-sync inspection

## v1.3.5 QoL & Stability

- Added customizable Sync, Tooltips, Cache, and Links options.
- Added `/ti reset` UI/BOX for settings and saved-data management.
- Greatly reduced SavedVariables size with automatic database migration.
- Improved cross-faction inspect safety when grouped players become hostile.
- Additional Lua 5.0 compatibility and stability fixes.
- Learned class data now reconstructs cached talent icons when live sync is unavailable.


## v1.3.0 Improvements / changes

- Restored gold/yellow prerequisite talent lines with stronger cross-tree isolation and safer rendering.
- Added self-learning prerequisite support using live VanillaPlus talent data, with packaged data retained as the offline fallback.
- Restored the proven 7-second Talents request spam guard to prevent duplicate sync requests.
- Fixed Guild/Friends right-click Talents handling for Vanilla 1.12.1 UnitPopup menus.
- Retained SAFEUIBASE1 UI improvements including icon borders, clipping, snap scrolling, tab persistence, and Blizzard/pfUI support.
- Further hardened tree switching, prerequisite rendering, sync ownership, and unit-token handling to reduce stale UI state and #132 crash risk.

## v1.2.0 Improvements / changes

- Added a safe one-shot refresh when an inspected target becomes reachable through party, raid, or guild transport.
- Hardened inspect, sync, cache, scrolling, and tree-switch behavior for the legacy 1.12.1 client.
- Kept prerequisite rendering independent from scrollbar movement to reduce UI state churn.
- Additional cleanup and safeguards aimed at reducing #132 crash risk.

## v1.1.0 Improvements / changes

- Hardened Lua/XML handling and inspect-page lifecycle safety.
- Improved sync, cache, and stale-owner protection.
- Improved VanillaPlus talent-tree rendering and packaged talent-data support.
- Improved stability during repeated inspecting, tree switching, and scrolling.
- Prerequisite arrow rendering is temporarily disabled while the connector system is being reworked for reliability.

## Commands

- `/ti` / `/ti help`
- `/ti refresh`
- `/ti sync on|off`
- `/ti tooltips on|off`
- `/ti cache on|off`
- `/ti links on|off`
- `/ti status`
- `/ti players`
- `/ti reset`

## Compatibility

Designed for World of Warcraft 1.12.1 / VanillaPlus. Supports the Blizzard default UI and pfUI.
