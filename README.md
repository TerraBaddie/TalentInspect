# TalentInspect v1.3.0

TalentInspect adds inspectable VanillaPlus talent trees to World of Warcraft 1.12.1, with support for the Blizzard default UI and pfUI.

## Installation

1. Remove or replace the previous `TalentInspect` addon folder.
2. Extract the single `TalentInspect` folder into `Interface\\AddOns\\`.
3. Restart World of Warcraft or reload the UI.

## Screenshots BUI / pfUI

<img width="611" height="706" alt="image" src="https://github.com/user-attachments/assets/2c077a4f-1272-43d8-a56f-57826fb5f62b" />
<img width="582" height="678" alt="image" src="https://github.com/user-attachments/assets/65a02130-c9f3-4a0e-87c3-4884fa2b5018" />


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

## v1.3.0 Release Summary

v1.3.0 is the Prerequisite Talent Lines and more stabilities release.

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

- `/ti`
- `/ti refresh`
- `/ti cache`
- `/ti clearcache`
- `/ti help`

## Compatibility

Designed for World of Warcraft 1.12.1 / VanillaPlus. Supports the Blizzard default UI and pfUI.

## Release Baseline

v1.3.0 was promoted from the tested development lines:

`SAFEUIBASE1 -> PREREQLINES3 -> TREEISOLATE2 -> LIVEPREREQ2 -> UnitPopup hotfixes -> 7S SPAMGUARD`

The clean pre-prerequisite rollback baseline remains:

`TalentInspect_v1.1.0_SAFEUIBASE1_NOARROWS_ROWSNAP3_BUIICON2_TABSTAY1`
