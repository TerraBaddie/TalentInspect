TalentInspect v1.0.0
====================

TalentInspect adds inspectable VanillaPlus talent trees for WoW 1.12.1.

FEATURES
--------
- Inspect another player's talents through the Character/Inspect UI.
- Supports Blizzard-style UI and pfUI presentation.
- Live talent sync between TalentInspect users through supported group/guild addon channels.
- Learned talent data can update stale packaged talent information.
- Live prerequisite relationships drive the yellow prerequisite connectors.
- Full grey empty class trees appear when no sync data is available.
- Shift + Left Click talents to place clickable TalentInspect talent links into chat.
- Native N TalentFrame talent links are supported too.
- Cached talent builds are retained for later viewing.
- Range/ownership guards prevent stale talents from one player being shown on another.

SYNC / FALLBACK
---------------
TalentInspect uses a short smart wait for normal talent sync. If no valid sync begins,
it can display a full grey 0-point tree for the inspected player's class.

The local live class scan is delayed after PLAYER_LOGIN to allow VanillaPlus talent
data and tooltips to settle before learning them.

INSTALL
-------
1. Extract the TalentInspect folder into:
   Interface\AddOns\
2. Restart WoW or reload the UI.
3. Inspect another player and open the Talents tab.

COMMANDS
--------
/ti
/ti refresh
/ti cache
/ti learnsync
/ti learntalent
/ti prereqs
/ti synctime
/ti clearcache

CHAT LINKS
----------
Open a chat edit box and Shift + Left Click a talent.

Learned talents create a light-blue clickable rank link.
Unlearned talents create a grey Rank 1 link.

COMPATIBILITY
-------------
Designed for WoW 1.12.1 / VanillaPlus.
