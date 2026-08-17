# TalentInspect v1.1.0

TalentInspect adds inspectable VanillaPlus talent trees to World of Warcraft 1.12.1.

## Features

- Inspect another player's VanillaPlus talent trees through the Character/Inspect UI.
- Blizzard-style and pfUI-compatible presentation.
- Live talent synchronization between TalentInspect users through supported group and guild addon channels.
- Cached inspected builds for later viewing.
- Complete grey 0-point class trees when valid sync data is unavailable.
- Shift + Left Click talents to place clickable TalentInspect talent links into chat.
- Range and ownership guards to prevent stale inspected-player data from leaking between targets.
- Stability hardening for the legacy 1.12.1 client, including guarded frame/API access and bounded talent scanning.

## v1.1.0 Improvements

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

## Installation

Extract the `TalentInspect` folder into `Interface\\AddOns\\`, then restart World of Warcraft or reload the UI.

## Compatibility

Designed for World of Warcraft 1.12.1 / VanillaPlus.
