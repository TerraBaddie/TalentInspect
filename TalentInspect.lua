-- TalentInspect v1.4.0 - WoW 1.12.1 / VanillaPlus
-- Request-driven talent sync with Blizzard-style one-tree-per-page UI.

TalentInspectDB = TalentInspectDB or {}
TalentInspectDB.cache = TalentInspectDB.cache or {}
TalentInspectDB.cacheSchema = TalentInspectDB.cacheSchema or 1
TalentInspectDB.learnedSchema = TalentInspectDB.learnedSchema or 1
TalentInspectDB.schema = TalentInspectDB.schema or TalentInspectDB.cacheSchema or 1
TalentInspectDB.migratedFrom = TalentInspectDB.migratedFrom or nil

-- SETTINGS1: persist overrides only; missing values inherit these defaults.
local TI_DEFAULTS = {
  sync = true,
  tooltips = true,
  cache = true,
  links = true,
}
TalentInspectDB.settings = TalentInspectDB.settings or {}
-- SETTINGS2: prerequisite lines are a core feature, not a user preference.
-- Remove stale SETTINGS1 overrides so an old /ti lines off cannot survive upgrade.
TalentInspectDB.settings.arrows = nil
TalentInspectDB.settings.lines = nil

local function settingEnabled(key)
  local v=TalentInspectDB.settings and TalentInspectDB.settings[key]
  if v==nil then return TI_DEFAULTS[key]~=false end
  return v and true or false
end

local function setSetting(key,value)
  TalentInspectDB.settings=TalentInspectDB.settings or {}
  if value==TI_DEFAULTS[key] then TalentInspectDB.settings[key]=nil
  else TalentInspectDB.settings[key]=value and true or false end
end

function TalentInspect_IsSettingEnabled(key)
  return settingEnabled(key)
end

-- DB3: player cache stays compact; learned data is a delta overlay on packaged TalentData.lua.
local runtimeCache = {}

local TI = {}
TI.VERSION = "1.3.5-DB4"
TI.PREFIX = "VPTI1"
TI.selectedTab = 1
TI.currentName = nil
TI.currentData = nil
TI.pending = {}
TI.learnPending = {}
TI.learnDescParts = {}
TI.lastLearnSync = TI.lastLearnSync or {}
TI.buttons = {}
TI.connectors = {}
TI.hostState = {
  CharacterFrame = { name=nil, data=nil, selectedTab=1 },
  InspectFrame = { name=nil, data=nil, selectedTab=1 }
}
TI.embeddedPrefix = nil
TI.fallbackName = nil
TI.fallbackClass = nil
TI.fallbackElapsed = 0
TI.FALLBACK_DELAY = 1.5
TI.syncTiming = TI.syncTiming or {}
TI.syncActiveName = nil
TI.syncRequestStarted = nil
TI.syncBeginAt = nil
TI.syncCompleteAt = nil
TI.syncExpectedName = nil
TI.syncExpectedClass = nil
TI.renderGeneration = TI.renderGeneration or 0
TI.renderOwner = nil
TI.lastServedRequest = {}
TI.lastServedLearnRequest = {}

local CLASS_COLORS = {
  WARRIOR={0.78,0.61,0.43}, MAGE={0.41,0.80,0.94}, ROGUE={1.00,0.96,0.41},
  DRUID={1.00,0.49,0.04}, HUNTER={0.67,0.83,0.45}, SHAMAN={0.00,0.44,0.87},
  PRIEST={1.00,1.00,1.00}, WARLOCK={0.58,0.51,0.79}, PALADIN={0.96,0.55,0.73}
}

-- Static tree names mirror the Hawaiisa VanillaPlus calculator class data.
-- Static metadata/descriptions come from vendored Hawaiisa data; sync only supplies the inspected player's live ranks.
local VPLUS_TREE_NAMES = {
  DRUID={"Balance","Feral Combat","Restoration"},
  HUNTER={"Beast Mastery","Marksmanship","Survival"},
  MAGE={"Arcane","Fire","Frost"},
  PALADIN={"Holy","Protection","Retribution"},
  PRIEST={"Discipline","Holy","Shadow"},
  ROGUE={"Assassination","Combat","Subtlety"},
  SHAMAN={"Elemental","Enhancement","Restoration"},
  WARLOCK={"Affliction","Demonology","Destruction"},
  WARRIOR={"Arms","Fury","Protection"}
}

-- FR1G: GetTalentTabInfo() normally supplies these native fileName values for
-- live talent data. A no-sync fallback has no remote GetTalentTabInfo(), so it
-- must map bundled TalentData trees to the native TalentFrame artwork itself.
local VPLUS_TREE_BACKGROUNDS = {
  DRUID={"DruidBalance","DruidFeralCombat","DruidRestoration"},
  HUNTER={"HunterBeastMastery","HunterMarksmanship","HunterSurvival"},
  MAGE={"MageArcane","MageFire","MageFrost"},
  PALADIN={"PaladinHoly","PaladinProtection","PaladinCombat"},
  PRIEST={"PriestDiscipline","PriestHoly","PriestShadow"},
  ROGUE={"RogueAssassination","RogueCombat","RogueSubtlety"},
  SHAMAN={"ShamanElementalCombat","ShamanEnhancement","ShamanRestoration"},
  WARLOCK={"WarlockCurses","WarlockSummoning","WarlockDestruction"},
  WARRIOR={"WarriorArms","WarriorFury","WarriorProtection"}
}

-- FR3d: backgrounds are local presentation metadata. They must never be
-- independently supplied by another player's sync/cache state.
local function canonicalTreeBackground(classToken,page)
  if TalentInspectData_NormalizeClass then
    classToken=TalentInspectData_NormalizeClass(classToken)
  end
  local backgrounds=VPLUS_TREE_BACKGROUNDS[classToken or ""]
  return (backgrounds and backgrounds[page]) or nil
end

local function currentTargetClassToken()
  if not UnitName("target") or UnitName("target")~=TI.currentName then return nil end
  local _,classToken=UnitClass("target")
  if TalentInspectData_NormalizeClass then
    classToken=TalentInspectData_NormalizeClass(classToken)
  end
  return classToken
end

local function classesAgree(a,b)
  if TalentInspectData_NormalizeClass then
    a=TalentInspectData_NormalizeClass(a)
    b=TalentInspectData_NormalizeClass(b)
  end
  if not a or a=="" or not b or b=="" then return 1 end
  return a==b
end


local function buildZeroTalentData(name,classToken,level)
  if TalentInspectData_NormalizeClass then
    classToken=TalentInspectData_NormalizeClass(classToken)
  end

  -- LEARNEDFALLBACK1:
  -- Packaged data remains the baseline, but once this client has learned an
  -- exact live class roster, that learned identity/index/geometry becomes the
  -- authority for reconstructing cached builds while the player is offline.
  -- This prevents stale packaged slots from creating blank/misplaced icons.
  local names=VPLUS_TREE_NAMES[classToken or ""]
  local bgNames=VPLUS_TREE_BACKGROUNDS[classToken or ""]
  local d={name=name,class=classToken,level=level or 0,tabs={}}

  local learnedClass=TalentInspectData_GetLearnedClass and
                     TalentInspectData_GetLearnedClass(classToken)

  for p=1,3 do
    local staticTree=TalentInspectData_GetTree and TalentInspectData_GetTree(classToken,p)
    local learnedTree=learnedClass and learnedClass.trees and learnedClass.trees[p]

    if staticTree or learnedTree then
      local tab={
        name=(names and names[p]) or (staticTree and staticTree.name) or
             (learnedTree and learnedTree.name) or ("Tree "..p),
        icon=(staticTree and staticTree.icon and ("Interface\\Icons\\"..staticTree.icon)) or "",
        points=0,
        fileName=(bgNames and bgNames[p]) or (staticTree and staticTree.background) or "",
        talents={}
      }

      local roster=(learnedTree and learnedTree.talents and next(learnedTree.talents) and learnedTree.talents) or
                   (staticTree and staticTree.talents) or {}

      for idx,src in pairs(roster) do
        local st=nil
        if TalentInspectData_FindTalent then
          st=TalentInspectData_FindTalent(classToken,p,src.name or src.sourceName,src.pos,src.index or idx)
        end
        st=st or src

        local tier=src.tier or st.tier
        local col=src.col or st.col
        if (not tier or not col) and (src.pos or st.pos) then
          local pos=src.pos or st.pos
          local _,_,a,b=string.find(pos,"^r(%d+)c(%d+)$")
          tier=tonumber(a) or tier
          col=tonumber(b) or col
        end

        local icon=src.icon or st.icon or ""
        if icon~="" and not string.find(icon,"\\",1,true) then
          icon="Interface\\Icons\\"..icon
        end

        local prereqName=nil
        local prereqScanned=nil
        local preRank=nil
        if src.prereqScanned==1 then
          prereqName=src.prereqName or ""
          prereqScanned=1
          preRank=src.preRank
        elseif st.prereqScanned==1 then
          prereqName=st.prereqName or ""
          prereqScanned=1
          preRank=st.preRank
        elseif st.prereq then
          prereqName=st.prereq
        end

        tab.talents[idx]={
          index=src.index or idx,
          name=src.name or src.sourceName or st.name or st.sourceName or ("Talent "..idx),
          icon=icon,
          tier=tier or 1,
          col=col or 1,
          rank=0,
          maxRank=src.maxRank or st.maxRank or 1,
          preTier=0,
          preCol=0,
          preRank=preRank,
          prereqName=prereqName,
          prereqScanned=prereqScanned,
          description=src.desc
        }
      end

      -- Resolve prerequisite names against the exact reconstructed roster.
      for _,t in pairs(tab.talents) do
        if t.prereqName and t.prereqName~="" then
          for _,pre in pairs(tab.talents) do
            if pre.name==t.prereqName then
              t.preTier=pre.tier or 0
              t.preCol=pre.col or 0
              break
            end
          end
        end
      end

      d.tabs[p]=tab
    end
  end
  return d
end

-- DB4 compact inspected-player cache -----------------------------------------
local function compactCachedBuild(d)
  if not d or not d.name or not d.class or not d.tabs then return nil end
  local c={v=4,name=d.name,class=d.class,level=d.level or 0,stamp=d.stamp or (time and time() or 0),tabs={}}
  for p=1,3 do
    local tab=d.tabs[p]
    if tab then
      local ct={points=tab.points or 0,ranks={},desc={}}
      for i,t in pairs(tab.talents or {}) do
        local r=tonumber(t.rank) or 0
        if r~=0 then ct.ranks[i]=r end
        if t.description and t.description~="" then ct.desc[i]=t.description end
      end
      if not next(ct.desc) then ct.desc=nil end
      c.tabs[p]=ct
    end
  end
  return c
end

local function expandCachedBuild(c)
  if not c then return nil end
  if c.tabs and c.v~=2 and c.v~=4 then return c end -- legacy rich cache
  if (c.v~=2 and c.v~=4) or not c.name or not c.class then return nil end
  local d=buildZeroTalentData(c.name,c.class,c.level or 0)
  if not d then return nil end
  d.stamp=c.stamp or 0
  for p=1,3 do
    local ct=c.tabs and c.tabs[p]
    local tab=d.tabs and d.tabs[p]
    if ct and tab then
      tab.points=ct.points or 0
      for i,r in pairs(ct.ranks or {}) do
        if tab.talents[i] then tab.talents[i].rank=tonumber(r) or 0 end
      end
      for i,text in pairs(ct.desc or {}) do
        if tab.talents[i] then tab.talents[i].description=text end
      end
    end
  end
  return d
end

local function getCachedBuild(name)
  if not name then return nil end
  if runtimeCache[name] then return runtimeCache[name] end
  local saved=TalentInspectDB.cache and TalentInspectDB.cache[name]
  local d=expandCachedBuild(saved)
  if d then runtimeCache[name]=d end
  return d
end

local function removeCachedBuild(name)
  runtimeCache[name]=nil
  if TalentInspectDB.cache then TalentInspectDB.cache[name]=nil end
end

local function migrateCacheSchema4()
  TalentInspectDB.cache=TalentInspectDB.cache or {}
  if TalentInspectDB.cacheSchema==4 then TalentInspectDB.schema=4 return end
  local fresh={}
  for name,entry in pairs(TalentInspectDB.cache) do
    local rich=expandCachedBuild(entry)
    if rich and rich.name then
      runtimeCache[name]=rich
      local compact=compactCachedBuild(rich)
      if compact then fresh[name]=compact end
    end
  end
  TalentInspectDB.cache=fresh
  local old=TalentInspectDB.cacheSchema or 1
  TalentInspectDB.cacheSchema=4
  TalentInspectDB.schema=4
  if old~=4 then TalentInspectDB.migratedFrom=old end
end

-- One geometry source of truth. Hawaiisa's calculator is a 4-column x 7-row grid.
local TREE_VIEW_W = 320
local TREE_VIEW_H = 350
local TREE_CANVAS_W = 320
local TREE_CANVAS_H = 397
local TALENT_SIZE = 44
local GRID_X0 = 18
local GRID_Y0 = 12
local GRID_X = 72
local GRID_Y = 55
local WHEEL_STEP = 20

local function talentGridY(tier)
  -- ROWSNAP2: every tier uses the exact same 55-unit spacing.
  -- The old tier-7-only -4px exception made the final row impossible to
  -- line up with the row above after a one-row snap.
  return GRID_Y0+((tier or 1)-1)*GRID_Y
end
local WHEEL_STEP = 20

local function usingPfUI()
  return pfUI and pfUI.api
end

-- BUIICON2:
-- Blizzard default UI needs the talent grid 2px higher to stay clear of the
-- exterior frame. pfUI keeps its existing position exactly.
-- This is a uniform visual offset only; row spacing remains exactly 55px.
local function talentDisplayY(tier)
  local y=talentGridY(tier)
  if not usingPfUI() then y=y-2 end
  return y
end

local function wipeTable(t)
  for k in pairs(t) do t[k] = nil end
end

local function split(s, sep)
  local out = {}
  local start = 1
  while true do
    local p = string.find(s, sep, start, true)
    if not p then
      table.insert(out, string.sub(s, start))
      break
    end
    table.insert(out, string.sub(s, start, p-1))
    start = p + string.len(sep)
  end
  return out
end

local function safe(s)
  s = tostring(s or "")
  s = string.gsub(s, "%%", "%%25")
  s = string.gsub(s, "%^", "%%5E")
  return s
end

local function unsafe(s)
  s = string.gsub(s or "", "%%5E", "^")
  s = string.gsub(s, "%%25", "%%")
  return s
end

-- 1.12 SendAddonMessage only supports PARTY / RAID / GUILD / BATTLEGROUND.
-- There is NO hidden addon WHISPER transport in stock 1.12.
TI.outbox = TI.outbox or {}
TI.outboxHead = 1
TI.outboxElapsed = 0
local syncPump=CreateFrame("Frame")

local function sendNow(msg, channel)
  if not settingEnabled("sync") then return end
  if SendAddonMessage and msg and channel then SendAddonMessage(TI.PREFIX,msg,channel) end
end
local function outboxCount()
  local n=table.getn(TI.outbox)
  if n<TI.outboxHead then return 0 end
  return n-TI.outboxHead+1
end
local function TalentInspect_SyncPumpUpdate()
  if outboxCount()<=0 then
    TI.outbox={}; TI.outboxHead=1; this:SetScript("OnUpdate",nil); TI.outboxElapsed=0; return
  end
  TI.outboxElapsed=TI.outboxElapsed+(arg1 or 0)
  if TI.outboxElapsed<0.06 then return end
  TI.outboxElapsed=0
  local item=TI.outbox[TI.outboxHead]
  TI.outbox[TI.outboxHead]=nil
  TI.outboxHead=TI.outboxHead+1
  if item then sendNow(item.msg,item.channel) end
  if outboxCount()<=0 then TI.outbox={}; TI.outboxHead=1; this:SetScript("OnUpdate",nil) end
end
local function queueSend(msg, channel)
  if not msg or not channel then return end
  table.insert(TI.outbox,{msg=msg,channel=channel})
  if not syncPump:GetScript("OnUpdate") then syncPump:SetScript("OnUpdate",TalentInspect_SyncPumpUpdate) end
end

local function isNameInRaid(name)
  if not name then return nil end
  local n=GetNumRaidMembers and GetNumRaidMembers() or 0
  for i=1,n do
    if UnitName("raid"..i)==name then return 1 end
  end
  return nil
end

local function isNameInParty(name)
  if not name then return nil end
  if UnitName("player")==name then return 1 end
  local n=GetNumPartyMembers and GetNumPartyMembers() or 0
  for i=1,n do
    if UnitName("party"..i)==name then return 1 end
  end
  return nil
end

TI.guildPeers = TI.guildPeers or {}
TI.guildRosterNames = TI.guildRosterNames or {}

local function normalizePlayerName(name)
  if not name then return nil end
  -- Vanilla normally has no realm suffix, but tolerate one if a custom client adds it.
  local dash=string.find(name,"-",1,true)
  if dash then name=string.sub(name,1,dash-1) end
  return string.lower(name)
end

local function refreshGuildRosterNames()
  TI.guildRosterNames={}
  if not GetNumGuildMembers or not GetGuildRosterInfo then return end
  local n=GetNumGuildMembers(true) or GetNumGuildMembers() or 0
  for i=1,n do
    local name=GetGuildRosterInfo(i)
    local key=normalizePlayerName(name)
    if key then TI.guildRosterNames[key]=1 end
  end
end

local function currentTargetSameGuild(name)
  if not name or not UnitExists("target") or UnitName("target")~=name then return nil end
  if not GetGuildInfo then return nil end
  local mine=GetGuildInfo("player")
  local theirs=GetGuildInfo("target")
  if mine and theirs and mine~="" and mine==theirs then
    TI.guildPeers[normalizePlayerName(name) or name]=1
    return 1
  end
  return nil
end

local function isKnownGuildPeer(name)
  local key=normalizePlayerName(name)
  if not key then return nil end
  if TI.guildPeers[key] then return 1 end
  if TI.guildRosterNames[key] then return 1 end
  return nil
end

local function transportFor(name)
  if isNameInRaid(name) then return "RAID" end
  if isNameInParty(name) then return "PARTY" end

  -- SYNC1: GUILD transport must not depend on both clients targeting each
  -- other at the exact same instant. Current-target confirmation, a remembered
  -- guild peer, or the guild roster are all sufficient.
  if currentTargetSameGuild(name) or isKnownGuildPeer(name) then return "GUILD" end
  return nil
end

local function playerClassToken()
  local _, c = UnitClass("player")
  return c or ""
end

local function captureLocal()
  local d = { name=UnitName("player"), class=playerClassToken(), level=UnitLevel("player"), tabs={} }
  local numTabs = GetNumTalentTabs and GetNumTalentTabs() or 3
  for page=1,numTabs do
    local name, icon, points, fileName = GetTalentTabInfo(page)
    local tab = { name=name or ("Tree "..page), icon=icon or "", points=points or 0, fileName=fileName or "", talents={} }
    local n = GetNumTalents(page) or 0
    for i=1,n do
      local tn, tex, tier, col, rank, maxRank = GetTalentInfo(page, i)
      local pt, pc, pr, prereqScanned=nil,nil,nil,nil
      if GetTalentPrereqs then
        local ok,a,b,c=pcall(GetTalentPrereqs,page,i)
        if ok then
          prereqScanned=1
          pt=tonumber(a); pc=tonumber(b); pr=tonumber(c)
          if not pt or not pc or pt<1 or pt>7 or pc<1 or pc>4 then
            pt=nil; pc=nil; pr=nil
          end
        end
      end
      if tn then
        tab.talents[i] = { index=i, name=tn, icon=tex or "", tier=tier or 1, col=col or 1,
          rank=rank or 0, maxRank=maxRank or 1, preTier=pt or 0, preCol=pc or 0,
          preRank=pr, prereqScanned=prereqScanned }
      end
    end
    d.tabs[page] = tab
  end
  return d
end


local function sendLearnedAdvertisement(target,channel)
  if not TalentInspectHelper or not target or not channel then return end

  local d
  if TalentInspectHelper.EnsureFreshForPeerSync then
    d=TalentInspectHelper:EnsureFreshForPeerSync()
  else
    d=TalentInspectHelper:GetOwnLearnedClass()
  end
  if not d then return end
  queueSend("LADV^"..safe(target).."^"..safe(d.class).."^"..safe(TalentInspectHelper:GetFingerprint(d.class)),channel)
end

local function sendLearnedClass(target,channel,classToken,receiverFP)
  if not TalentInspectHelper or not target or not channel then return end
  local d=TalentInspectHelper:GetOwnLearnedClass()
  if not d or d.class~=classToken then return end
  local fp=TalentInspectHelper:GetFingerprint(classToken)
  if receiverFP==fp then return end
  local to=safe(target)

  queueSend("LBEGIN^"..to.."^"..safe(classToken).."^"..safe(fp),channel)
  for p=1,3 do
    local tree=d.trees and d.trees[p]
    if tree and tree.talents then
      for i=1,table.getn(tree.talents) do
        local t=tree.talents[i]
        if t then
          local structural=TalentInspectHelper:SerializeLearnedTalent(t)
          local msg="LTAL^"..to.."^"..safe(classToken).."^"..p.."^"..structural
          if string.len(TI.PREFIX)+string.len(msg)<=254 then
            queueSend(msg,channel)
          end

          -- Description uses separate bounded chunks. 120 characters leaves
          -- generous headroom for recipient/class/tree/index/part metadata.
          local desc=TalentInspectHelper:SerializeLearnedDescription(t)
          if desc and desc~="" then
            local chunkSize=120
            local total=math.ceil(string.len(desc)/chunkSize)
            for part=1,total do
              local chunk=string.sub(desc,(part-1)*chunkSize+1,part*chunkSize)
              local dmsg="LDES^"..to.."^"..safe(classToken).."^"..p.."^"..i.."^"..part.."^"..total.."^"..chunk
              if string.len(TI.PREFIX)+string.len(dmsg)<=254 then
                queueSend(dmsg,channel)
              end
            end
          end
        end
      end
    end
  end
  queueSend("LEND^"..to.."^"..safe(classToken).."^"..safe(fp),channel)
end

local function cacheData(d)
  if not d or not d.name then return end
  d.stamp=time and time() or 0
  runtimeCache[d.name]=d
  if not settingEnabled("cache") then return end
  TalentInspectDB.cacheSchema=4
  TalentInspectDB.schema=4
  TalentInspectDB.cache[d.name]=compactCachedBuild(d)
  local count=0
  for _ in pairs(TalentInspectDB.cache) do count=count+1 end
  while count>200 do
    local oldestName=nil; local oldestStamp=nil
    for name,entry in pairs(TalentInspectDB.cache) do
      if name~=d.name then
        local stamp=(entry and tonumber(entry.stamp)) or 0
        if not oldestStamp or stamp<oldestStamp then oldestStamp=stamp; oldestName=name end
      end
    end
    if not oldestName then break end
    removeCachedBuild(oldestName)
    count=count-1
  end
end

local function clearTalentCache()
  -- CACHEFIX1:
  -- /ti clearcache is a persistence operation, NOT a live UI reset.
  --
  -- The old implementation destroyed TI.currentData, pending sync state and
  -- every hostState while TalentInspect/Blizzard InspectFrame could still be
  -- rendering those exact tables.  That immediately collapsed the visible
  -- tree to "Tree 1/2/3 0" and created an unsafe mid-frame state on the old
  -- 1.12 client.
  --
  -- Only detach the SavedVariables cache here.  Any currently displayed data
  -- remains alive until the normal target/tab/inspect lifecycle replaces it.
  -- A fresh table also means the old cache becomes collectible naturally
  -- after no live UI references remain.
  TalentInspectDB.cache = {}
  runtimeCache = {}
  TalentInspectDB.cacheSchema = 4
  TalentInspectDB.schema = 4
end

-- UI -------------------------------------------------------------------------
-- FR2-XML1: static frames/regions are declared in TalentInspect.xml.
-- Lua owns runtime behavior, data binding and state only.
local f = TalentInspectFrame
if not f then error("TalentInspect.xml did not create TalentInspectFrame") end

f.bg = TalentInspectFrameBG
local border = TalentInspectFrameBorder
f.title = TalentInspectTitle
f.subtitle = TalentInspectSubtitle
f.blizzChrome = TalentInspectBlizzardChrome
f.blizzHeader = TalentInspectBlizzardHeader
f.blizzClose = TalentInspectBlizzardClose
local close = TalentInspectStandaloneClose
f.treeTitle = TalentInspectTreeTitle
f.status = TalentInspectStatus
f.noSyncLeft = TalentInspectNoSyncLeft
f.noSyncRight = TalentInspectNoSyncRight
f.statusOverlay = TalentInspectStatusOverlay

f:SetMovable(0)
f:SetScript("OnDragStart",nil)
f:SetScript("OnDragStop",nil)
f:SetScript("OnHide",function()
  TI.hoveredTalentButton=nil
  if GameTooltip then GameTooltip:Hide() end
end)
f:Hide()

-- Static XML buttons still get behavior here so no UI logic lives in XML.
f.blizzClose:SetScript("OnClick",function()
  if CharacterFrame and CharacterFrame:IsVisible() then
    HideUIPanel(CharacterFrame)
  elseif InspectFrame and InspectFrame:IsVisible() then
    HideUIPanel(InspectFrame)
  end
end)

-- Display modes --------------------------------------------------------------
-- TalentInspect is a native Character/Inspect page. The old standalone layout
-- remains internal fallback code only and is not part of normal user flow.
TI.embeddedHost = nil

local function setStandaloneMode()
  TI.embeddedHost = nil
  f:SetParent(UIParent)
  f:EnableMouse(1)
  f:ClearAllPoints(); f:SetWidth(356); f:SetHeight(512)
  f:SetPoint("CENTER", UIParent, "CENTER", 120, 20)
  f:SetFrameStrata("DIALOG")
  f:SetFrameLevel(1)
  f.bg:Show(); border:Show(); close:Show(); f.title:Show(); f.subtitle:Show()
  f.treeTitle:ClearAllPoints(); f.treeTitle:SetPoint("TOP",f,"TOP",0,-48)
  f.status:ClearAllPoints(); f.status:SetPoint("BOTTOM",f,"BOTTOM",0,9)
  if f.scroll then
    f.scroll:ClearAllPoints()
    f.scroll:SetPoint("TOPLEFT",f,"TOPLEFT",18,-72)
    f.scroll:SetWidth(286)
    f.scroll:SetHeight(334)
  end
  if f.tabs then
    for i=1,3 do
      local b=f.tabs[i]
      if b then
        b:ClearAllPoints()
        if i==1 then b:SetPoint("BOTTOMLEFT",f,"BOTTOMLEFT",14,31)
        else b:SetPoint("LEFT",f.tabs[i-1],"RIGHT",4,0) end
      end
    end
  end
end

local function setEmbeddedMode(host)
  if not host then return end

  local hostChanged=(TI.embeddedHost~=host) or
                    (f.GetParent and f:GetParent()~=host)
  TI.embeddedHost = host

  -- DEEPHARDEN1: reparent/anchor only when ownership actually changes.
  -- Repeated cache/sync/tab renders should not churn the legacy frame tree.
  if hostChanged then
    f:Hide()
    f:SetParent(host)
    f:SetMovable(0)
    f:EnableMouse(0)
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT",host,"TOPLEFT",14,-42)
    f:SetPoint("BOTTOMRIGHT",host,"BOTTOMRIGHT",-14,39)
  else
    f:SetMovable(0)
    f:EnableMouse(0)
  end
  -- Custom 1.12 character UIs can place PaperDoll/overlays above their parent.
  -- Never inherit the host strata: keep the Talents page decisively above
  -- native subframes while still parented/locked to CharacterFrame/InspectFrame.
  f:SetFrameStrata("DIALOG")
  f:SetFrameLevel((host:GetFrameLevel() or 1)+60)
  if f.Raise then f:Raise() end

  -- The host IS the window. Match the player's installed UI.
  f.bg:Hide()
  border:Hide(); close:Hide(); f.title:Hide(); f.subtitle:Hide()

  if usingPfUI() then
    if f.blizzChrome then f.blizzChrome:Hide() end
    if f.blizzHeader then f.blizzHeader:Hide() end
    if f.blizzClose then f.blizzClose:Hide() end
  else
    if f.blizzChrome then f.blizzChrome:Show() end
    -- HEADERCLEAN1: the selected-tree name/points already live in the three
    -- persistent tree tabs.  Do not draw the old redundant Blizzard input-box
    -- header behind a second copy of the same information.
    if f.blizzHeader then f.blizzHeader:Hide() end
    if f.blizzClose then
      f.blizzClose:SetFrameLevel(f:GetFrameLevel()+220)
      f.blizzClose:Show()
      if f.blizzClose.Raise then f.blizzClose:Raise() end
    end

    -- FR2-XML5: restore stock InspectFrame close-button position.
    -- XML4 moved the whole red button when only the X artwork looked off.
    local hostClose=getglobal("InspectFrameCloseButton")
    if hostClose then
      -- CLOSEALIGN1: TalentInspect's Blizzard-default header sits slightly
      -- inside the host chrome. Reuse the native close button and nudge it
      -- into that socket; do not create/reparent/replace the button.
      hostClose:ClearAllPoints()
      hostClose:SetPoint("TOPRIGHT",host,"TOPRIGHT",-30,-8)
      if hostClose.Raise then hostClose:Raise() end
    end
  end

  -- HEADERCLEAN1: remove the old selected-tree header completely in embedded
  -- Character/Inspect mode.  The tree tabs already show name + points, so this
  -- text was redundant in both Blizzard UI and pfUI.  Standalone fallback keeps
  -- its legacy title behavior.
  f.treeTitle:ClearAllPoints()
  f.treeTitle:SetText("")
  f.treeTitle:Hide()

  f.status:ClearAllPoints()
  f.status:SetPoint("BOTTOMRIGHT",f,"BOTTOMRIGHT",-20,1)

  if f.noSyncLeft and f.noSyncRight then
    f.noSyncLeft:ClearAllPoints()
    f.noSyncRight:ClearAllPoints()
    if usingPfUI() then
      -- pfUI keeps its original status position.
      f.noSyncLeft:SetPoint("TOPLEFT",f,"TOPLEFT",-1,32)
      f.noSyncRight:SetPoint("TOPLEFT",f,"TOPLEFT",-1,-3)
    else
      -- HEADERCLEAN3/TABDOWN1: keep the target/sync status inside the open
      -- strip above the spec tabs.  The old +20 Y placed this text above the
      -- embedded page and clipped it against Blizzard's top chrome.
      -- SAFEUIBASE1: Blizzard-only top target-status anchor. pfUI uses the branch above.
      f.noSyncLeft:SetPoint("TOPLEFT",f,"TOPLEFT",64,22)
      f.noSyncRight:SetPoint("BOTTOMLEFT",f,"BOTTOMLEFT",16,48)
    end
  end

  -- Octo/Turtle-style spec selector at the TOP of the talent page.
  if f.tabs then
    for i=1,3 do
      local b=f.tabs[i]
      if b then
        b:ClearAllPoints()
        if i==1 then
          if usingPfUI() then
            b:SetPoint("BOTTOMLEFT",f.scroll,"TOPLEFT",0,4)
          else
            -- HEADERCLEAN3/TABDOWN1: use only the lower Blizzard spec-tab row.
            -- HEADERCLEAN2 left these 20px too high after the redundant header
            -- was removed, crowding/clipping the target status line.  Keep the
            -- same tabs and move their single anchor down 20px; do not create
            -- or duplicate any tab buttons.
            b:SetPoint("BOTTOMLEFT",f.scroll,"TOPLEFT",34,12)
          end
        else
          if usingPfUI() then
            b:SetPoint("LEFT",f.tabs[i-1],"RIGHT",3,0)
          else
            b:SetPoint("LEFT",f.tabs[i-1],"RIGHT",-15,0)
          end
        end
        if b.Raise then b:Raise() end
      end
    end
  end

  -- FR2-XML4: normalize the XML-created top-tab skin as soon as the page
  -- enters InspectFrame. This prevents even a single-frame flash of the
  -- pfUI/flat XML default on stock Blizzard UI.
  if f.tabs then
    for i=1,3 do
      local b=f.tabs[i]
      if b then
        if usingPfUI() then
          if b.blizzL then b.blizzL:Hide(); b.blizzM:Hide(); b.blizzR:Hide() end
          if b.bg then b.bg:Show() end
          if b.edge then b.edge:Show() end
        else
          if b.bg then b.bg:Hide() end
          if b.edge then b.edge:Hide() end
          if b.blizzL then
            b.blizzL:SetTexture("Interface\\PaperDollInfoFrame\\UI-Character-InActiveTab")
            b.blizzM:SetTexture("Interface\\PaperDollInfoFrame\\UI-Character-InActiveTab")
            b.blizzR:SetTexture("Interface\\PaperDollInfoFrame\\UI-Character-InActiveTab")
            b.blizzL:Show(); b.blizzM:Show(); b.blizzR:Show()
          end
        end
      end
    end
  end

  -- HEADERCLEAN2: keep the proven SNAPSCROLL2 viewport geometry in both UI
  -- modes.  The redundant selected-tree header/box stays removed, but the
  -- talent ScrollFrame (and therefore its stock up/down buttons/slider) does
  -- NOT move.  This avoids the 20px upward jump seen in HEADERCLEAN1.
  if f.scroll then
    f.scroll:EnableMouse(1)
    f.scroll:EnableMouseWheel(1)
    f.scroll:ClearAllPoints()
    if usingPfUI() then
      f.scroll:SetPoint("TOPLEFT",f,"TOPLEFT",4,-48)
    else
      f.scroll:SetPoint("TOPLEFT",f,"TOPLEFT",4,-38)
    end
    f.scroll:SetWidth(TREE_VIEW_W)
    if usingPfUI() then
      f.scroll:SetHeight(TREE_VIEW_H)
    else
      f.scroll:SetHeight(TREE_VIEW_H-11)
    end

    -- ROWSNAP1:
    -- Keep the two legal scroll positions exactly ONE talent-row apart.
    -- The old fixed 397px canvas produced different scroll ranges:
    --   pfUI = 47px, Blizzard = 58px
    -- while the actual talent row spacing is 55px (GRID_Y).
    -- That made every icon land at a slightly different screen Y after
    -- scrolling.  Size only the existing canvas so max scroll = GRID_Y.
    -- No button re-anchoring, no background changes, no new frames.
    if f.canvas then
      f.canvas:SetHeight((f.scroll:GetHeight() or TREE_VIEW_H) + GRID_Y)
    end
  end

  if f.treeBackgroundClip and f.scroll then
    f.treeBackgroundClip:ClearAllPoints()
    -- HFUI + SNAPSCROLL2/LAYOUT2: Blizzard keeps the proven +3px horizontal
    -- correction. The artwork window also sits 3px lower inside the newly
    -- expanded viewport; pfUI keeps the BACKGROUNDFIX1 position unchanged.
    if usingPfUI() then
      f.treeBackgroundClip:SetPoint("TOPLEFT",f.scroll,"TOPLEFT",0,0)
    else
      f.treeBackgroundClip:SetPoint("TOPLEFT",f.scroll,"TOPLEFT",3,-3)
    end
    f.treeBackgroundClip:SetWidth(TREE_VIEW_W)
    f.treeBackgroundClip:SetHeight(f.scroll:GetHeight())

    -- BACKGROUNDFIX1: crop the bottom 128px source tiles by resizing the
    -- texture regions themselves.  This keeps all background artwork static
    -- and avoids a second ScrollFrame / renderer state machine.
    local bgBottom=(f.scroll:GetHeight() or TREE_VIEW_H)-256
    if bgBottom < 0 then bgBottom=0 elseif bgBottom > 128 then bgBottom=128 end

    -- BGEXT1 (Blizzard only): use 25px more of the EXISTING bottom artwork
    -- tiles.  No new texture/frame/ScrollFrame and no OnUpdate/show-hide churn.
    -- pfUI remains exactly on the proven BACKGROUNDFIX1 geometry.
    if not usingPfUI() then
      bgBottom=bgBottom+25
      if bgBottom>128 then bgBottom=128 end
    end

    local bgFrac=bgBottom/128
    if tiles and tiles[3] and tiles[4] then
      tiles[3]:SetHeight(bgBottom)
      tiles[4]:SetHeight(bgBottom)
      tiles[3]:SetTexCoord(0,1,0,bgFrac)
      tiles[4]:SetTexCoord(0,1,0,bgFrac)
    end

    -- FR2-XML5 explicit layer stack.
    f.treeBackgroundClip:SetFrameLevel(f:GetFrameLevel()+10)
    if f.treeBackground then f.treeBackground:SetFrameLevel(f:GetFrameLevel()+9) end
    f.scroll:SetFrameLevel(f:GetFrameLevel()+30)
    if f.canvas then f.canvas:SetFrameLevel(f:GetFrameLevel()+31) end

          end

  if f.blankPane and f.scroll then
    f.blankPane:ClearAllPoints()
    f.blankPane:SetPoint("TOPLEFT",f.scroll,"TOPLEFT",0,0)
    f.blankPane:SetPoint("BOTTOMRIGHT",f.scroll,"BOTTOMRIGHT",0,0)
  end

  if f.scrollBar then
    f.scrollBar:SetFrameLevel(f:GetFrameLevel()+200)
    if tiScrollUp then tiScrollUp:SetFrameLevel(f:GetFrameLevel()+201) end
    if tiScrollDown then tiScrollDown:SetFrameLevel(f:GetFrameLevel()+201) end
    f.scrollBar:ClearAllPoints()
    -- Keep the scrollbar visibly INSIDE the native page.
    -- HF2: the up/down arrow buttons stay at the HF1 positions, while the
    -- slider track itself ends farther inside them. This guarantees the knob
    -- remains visible at minimum/maximum scroll instead of slipping under the
    -- bottom `v` arrow.
    f.scrollBar:SetPoint("TOPRIGHT",f.scroll,"TOPRIGHT",-2,-26)
    f.scrollBar:SetPoint("BOTTOMRIGHT",f.scroll,"BOTTOMRIGHT",-2,30)
    f.scrollBar:SetWidth(18)
    f.scrollBar:Show()
    if f.scrollBar.Raise then f.scrollBar:Raise() end
  end

  if f.canvas and f.scroll then
    f.canvas:ClearAllPoints()
    f.canvas:SetPoint("TOPLEFT",f.scroll,"TOPLEFT",0,0)
  end

  -- FR2-XML5: explicit foreground text/controls.
  if f.statusOverlay then
    f.statusOverlay:SetFrameLevel(f:GetFrameLevel()+230)
    if f.statusOverlay.Raise then f.statusOverlay:Raise() end
  end
  if not usingPfUI() and f.blizzClose then
    f.blizzClose:SetFrameLevel(f:GetFrameLevel()+220)
    if f.blizzClose.Raise then f.blizzClose:Raise() end
  end
end

-- Hawaiisa geometry is a 4-column x 7-row talent grid.
-- Keep the full tree large and readable, then clip it with a native scroll view
-- instead of shrinking icons/background to fit the Character panel.

-- Lua 5.0 scope rule: these MUST exist lexically before any scripts/functions
-- that reference them. v0.3.1 declared them too late.
local applyViewportClipping
local hideConnector
local TalentInspect_UpdateScrollRange
local TalentInspect_MouseWheel

-- FR2-XML1: viewport, canvas, scrollbar, arrows, background clip and blank pane
-- are static XML objects. Keep all safety-sensitive scroll behavior in Lua.
f.scroll = TalentInspectTreeScroll
f.canvas = TalentInspectTreeCanvas
f.scrollBar = TalentInspectTreeScrollBar
local tiScrollBar = f.scrollBar
local tiScrollUp = TalentInspectTreeScrollUp
local tiScrollDown = TalentInspectTreeScrollDown
f.treeBackgroundClip = TalentInspectTreeBackgroundClip
f.treeBackground = TalentInspectTreeBackground
f.blankPane = TalentInspectBlankPane
f.blankPaneBG = TalentInspectBlankPaneBG

-- Make sure custom 1.12 clients preserve the intended scroll-child ownership.
f.scroll:SetScrollChild(f.canvas)
f.canvas:EnableMouse(0)
f.treeBackground:EnableMouse(0)
f.treeBackgroundClip:EnableMouse(0)
f.blankPane:EnableMouse(0)

local thumb=tiScrollBar:GetThumbTexture()
if thumb then thumb:SetWidth(18); thumb:SetHeight(20) end
tiScrollBar:EnableMouse(1)
tiScrollBar:SetHitRectInsets(-6,-6,-5,-5)
tiScrollBar.track=TalentInspectScrollTrack
tiScrollBar.trackTopCap=TalentInspectScrollTrackTop
tiScrollBar.trackBottomCap=TalentInspectScrollTrackBottom

local function TalentInspect_SetSliderFromCursor()
  local _,cy=GetCursorPosition()
  local scale=tiScrollBar:GetEffectiveScale() or 1
  cy=cy/scale
  local top=tiScrollBar:GetTop()
  local bottom=tiScrollBar:GetBottom()
  if not top or not bottom or top<=bottom then return end

  -- SNAPSCROLL1: there are deliberately only TWO legal viewport states:
  -- fully at the top and fully at the bottom. Clicking or dragging the
  -- scrollbar chooses the nearest half rather than exposing partial rows.
  local minValue,maxValue=tiScrollBar:GetMinMaxValues()
  local midpoint=(top+bottom)/2
  local target
  if cy>=midpoint then target=minValue else target=maxValue end
  if (tiScrollBar:GetValue() or minValue)~=target then
    tiScrollBar:SetValue(target)
  end
end

local function TalentInspect_DragUpdate()
  TalentInspect_SetSliderFromCursor()
end

tiScrollBar:SetScript("OnMouseDown",function()
  this.tiDragging=1
  TalentInspect_SetSliderFromCursor()
  this:SetScript("OnUpdate",TalentInspect_DragUpdate)
end)
tiScrollBar:SetScript("OnMouseUp",function()
  this.tiDragging=nil
  this:SetScript("OnUpdate",nil)
end)
tiScrollBar:SetScript("OnHide",function()
  this.tiDragging=nil
  this:SetScript("OnUpdate",nil)
end)

local tiScrollSyncing=nil
TalentInspect_UpdateScrollRange = function()
  if not f.scroll or not f.canvas or not tiScrollBar then return end
  -- ROWSNAP2: this UI intentionally has only TOP and BOTTOM.
  -- Make BOTTOM exactly one talent-row (55 units) below TOP. Do not derive
  -- this from frame dimensions, which can pick up fractional UI-scale rounding.
  local range=GRID_Y
  local value=tiScrollBar:GetValue() or 0
  if value<0 then value=0 end
  if value>range then value=range end
  tiScrollSyncing=1
  tiScrollBar:SetMinMaxValues(0,range)
  -- SNAPSCROLL1: slider has only the top and bottom stops.
  tiScrollBar:SetValueStep(range>0 and range or 1)
  -- Any stale/midpoint value from an older build is normalized immediately.
  if range>0 and value>0 then
    if value<(range/2) then value=0 else value=range end
  end
  tiScrollBar:SetValue(value)
  tiScrollSyncing=nil
  f.scroll:SetVerticalScroll(value)
  if applyViewportClipping then applyViewportClipping() end
  if value<=0 then tiScrollUp:Disable() else tiScrollUp:Enable() end
  if value>=range then tiScrollDown:Disable() else tiScrollDown:Enable() end
end

tiScrollBar:SetScript("OnValueChanged",function()
  if tiScrollSyncing then return end
  local value=arg1
  if value==nil then value=this:GetValue() or 0 end
  local minValue,maxValue=this:GetMinMaxValues()
  if value<minValue then value=minValue end
  if value>maxValue then value=maxValue end

  -- SNAPSCROLL1 safety net: even if the legacy Slider internally reports an
  -- intermediate drag/click value, collapse it to the nearest legal stop.
  local snapped=value
  if maxValue>minValue then
    if value<((minValue+maxValue)/2) then snapped=minValue else snapped=maxValue end
  end
  if snapped~=value then
    tiScrollSyncing=1
    this:SetValue(snapped)
    tiScrollSyncing=nil
    value=snapped
  end

  f.scroll:SetVerticalScroll(value)
  if applyViewportClipping then applyViewportClipping() end
  if value<=minValue then tiScrollUp:Disable() else tiScrollUp:Enable() end
  if value>=maxValue then tiScrollDown:Disable() else tiScrollDown:Enable() end
end)

tiScrollUp:SetScript("OnClick",function()
  TalentInspect_UpdateScrollRange()
  local minValue,maxValue=tiScrollBar:GetMinMaxValues()
  tiScrollBar:SetValue(minValue)
  PlaySound("UChatScrollButton")
end)
tiScrollDown:SetScript("OnClick",function()
  TalentInspect_UpdateScrollRange()
  local minValue,maxValue=tiScrollBar:GetMinMaxValues()
  tiScrollBar:SetValue(maxValue)
  PlaySound("UChatScrollButton")
end)

TalentInspect_MouseWheel = function(delta)
  TalentInspect_UpdateScrollRange()
  local minValue,maxValue=tiScrollBar:GetMinMaxValues()
  delta=delta or 0
  if delta>0 then
    tiScrollBar:SetValue(minValue)
  elseif delta<0 then
    tiScrollBar:SetValue(maxValue)
  end
end

local function routeWheel(frame)
  if not frame then return end
  frame:EnableMouse(1)
  frame:EnableMouseWheel(1)
  frame:SetScript("OnMouseWheel",function()
    if TalentInspect_MouseWheel then TalentInspect_MouseWheel(arg1) end
  end)
end
routeWheel(f.scroll)
routeWheel(tiScrollBar)
routeWheel(tiScrollUp)
routeWheel(tiScrollDown)

f.scroll:SetScript("OnShow",function()
  if f.treeBackgroundClip then f.treeBackgroundClip:Show() end
  if f.treeBackground then f.treeBackground:Show() end
  f.canvas:Show(); tiScrollBar:Show(); tiScrollUp:Show(); tiScrollDown:Show()
  TalentInspect_UpdateScrollRange()
  if applyViewportClipping then applyViewportClipping() end
end)
f.scroll:SetScript("OnHide",function()
  if f.treeBackgroundClip then f.treeBackgroundClip:Hide() end
  if f.treeBackground then f.treeBackground:Hide() end
  f.canvas:Hide(); tiScrollBar:Hide(); tiScrollUp:Hide(); tiScrollDown:Hide()
end)

local tiles = {
  TalentInspectTreeTile1,
  TalentInspectTreeTile2,
  TalentInspectTreeTile3,
  TalentInspectTreeTile4
}
local tileNames = {"TopLeft","TopRight","BottomLeft","BottomRight"}
f.tiles=tiles
f.clipTop=nil
f.clipBottom=nil
TalentInspect_UpdateScrollRange()

local function setTreeBackground(fileName)
  if f.blankPane then f.blankPane:Hide() end
  if f.scroll then f.scroll:Show() end
  if f.canvas then f.canvas:Show() end
  if f.treeBackground then f.treeBackground:Show() end
  if f.treeBackgroundClip then
    f.treeBackgroundClip:Show()
    f.treeBackgroundClip:SetFrameLevel(f:GetFrameLevel()+10)
  end
  if f.treeBackground then f.treeBackground:SetFrameLevel(f:GetFrameLevel()+9) end
  if f.scroll then f.scroll:SetFrameLevel(f:GetFrameLevel()+30) end
  if f.canvas then f.canvas:SetFrameLevel(f:GetFrameLevel()+31) end

  local base = "Interface\\TalentFrame\\"..(fileName or "MageFire").."-"
  for i=1,4 do
    tiles[i]:SetTexture(base..tileNames[i])
    tiles[i]:Show()
  end
end

local function showBlankPane()
  -- FR3d: scrub previous-player artwork, don't merely hide the clip frame.
  -- Legacy frame/layer transitions can otherwise briefly resurrect old tiles.
  for i=1,4 do
    if tiles and tiles[i] then
      tiles[i]:SetTexture(nil)
      tiles[i]:Hide()
    end
  end
  if f.treeBackgroundClip then f.treeBackgroundClip:Hide() end
  if f.blankPane then f.blankPane:Show() end
end

local function hideButtons()
  for _,b in pairs(TI.buttons) do
    b:Hide()
    b.data=nil
    b.ownerName=nil
    b.static=nil
    b.tiDesaturated=nil
    if b.rank then
      b.rank:SetText("")
      b.rank:Hide()
    end
    if b.rankBG then b.rankBG:Hide() end
  end
end

local requestTalentDescription
local renderRemoteTalentTooltip
local renderStaticTalentTooltip

local function makeTalentButton(i)
  local b=CreateFrame("Button","TalentInspectTalent"..i,f.canvas,"TalentInspectTalentButtonTemplate")
  b:SetFrameLevel((f.canvas and f.canvas:GetFrameLevel() or f.scroll:GetFrameLevel())+35)
  b.icon=getglobal(b:GetName().."Icon")
  b.rankBG=getglobal(b:GetName().."RankBG")
  b.rank=getglobal(b:GetName().."Rank")
  b.highlight=getglobal(b:GetName().."Highlight")
  b.border={} -- FR2 XML template intentionally has no custom gold/colored border.
  if b.highlight then b.highlight:SetAlpha(0.18) end
  b:EnableMouse(1)
  b:RegisterForClicks("LeftButtonUp","RightButtonUp")
  b.tiTalentButton=1
  b:SetScript("OnClick",function()
    if TalentSyncLinkSystem_OnTalentClick then
      TalentSyncLinkSystem_OnTalentClick(this,arg1)
    end
  end)
  b:SetScript("OnEnter", function()
    if not this or not this.data then return end
    TI.hoveredTalentButton=this
    local owner=this.ownerName or TI.currentName
    local page=this.page or TI.selectedTab or 1
    local index=this.data.index
    if owner==UnitName("player") and GameTooltip.SetTalent then
      GameTooltip:SetOwner(this,"ANCHOR_RIGHT")
      GameTooltip:SetTalent(page,index)
      GameTooltip:Show()
      return
    end
    if settingEnabled("tooltips") and renderStaticTalentTooltip then renderStaticTalentTooltip(this) end
  end)
  b:SetScript("OnLeave", function()
    if TI.hoveredTalentButton==this then TI.hoveredTalentButton=nil end
    GameTooltip:Hide()
  end)
  b:EnableMouseWheel(1)
  b:SetScript("OnMouseWheel",function()
    if TalentInspect_MouseWheel then TalentInspect_MouseWheel(arg1) end
  end)
  TI.buttons[i]=b
  return b
end

-- SAFE1: no permanent mouse-focus polling.
-- Talent buttons rely on native OnEnter/OnLeave only.

local function setTalentBorderColor(b,r,g,blue,a)
  -- No custom talent outline. Icon saturation + rank text convey state.
end

-- TREEISOLATE2: never move the same connector Texture objects between
-- different talent tabs.  The 1.12 renderer can briefly retain old geometry
-- when a reused texture is hidden/reanchored/shown during a rapid page swap.
-- Keep one lightweight connector layer/pool per tab and switch the whole layer.
TI.connectorPages = TI.connectorPages or {}

local function getConnectorPage(page)
  page=page or 1
  local cp=TI.connectorPages[page]
  if cp then return cp end

  local layer=CreateFrame("Frame",nil,f.canvas)
  layer:ClearAllPoints()
  layer:SetPoint("TOPLEFT",f.canvas,"TOPLEFT",0,0)
  layer:SetPoint("BOTTOMRIGHT",f.canvas,"BOTTOMRIGHT",0,0)
  layer:SetFrameLevel((f.canvas and f.canvas:GetFrameLevel() or f:GetFrameLevel())+20)
  layer:EnableMouse(0)
  layer:Hide()

  cp={frame=layer,connectors={},use=0}
  TI.connectorPages[page]=cp
  return cp
end

local function resetConnectorPool(page)
  if page then
    local cp=TI.connectorPages[page]
    if not cp then return end
    cp.use=0
    for _,c in pairs(cp.connectors or {}) do
      if c and c.segments then
        for _,seg in pairs(c.segments) do
          seg:Hide()
          seg:ClearAllPoints()
        end
      end
    end
    return
  end

  -- A tab change first hides every page-level connector frame.  This is the
  -- hard identity boundary; no old-tree texture remains visible while the new
  -- talent buttons are being rebound.
  for _,cp in pairs(TI.connectorPages) do
    if cp then
      cp.use=0
      if cp.frame then cp.frame:Hide() end
      for _,c in pairs(cp.connectors or {}) do
        if c and c.segments then
          for _,seg in pairs(c.segments) do
            seg:Hide()
            seg:ClearAllPoints()
          end
        end
      end
    end
  end
end

local function activateConnectorPage(page)
  -- Hide all layers before exposing the selected one.
  for p,cp in pairs(TI.connectorPages) do
    if cp and cp.frame then cp.frame:Hide() end
  end
  local cp=getConnectorPage(page)
  resetConnectorPool(page)
  cp.frame:Show()
  return cp
end

local function acquireConnector(page)
  local cp=getConnectorPage(page)
  cp.use=(cp.use or 0)+1
  local slot=cp.use
  local c=cp.connectors[slot]
  if not c then
    c={segments={}}
    for n=1,3 do
      c.segments[n]=cp.frame:CreateTexture(nil,"BORDER")
    end
    cp.connectors[slot]=c
  end
  for _,seg in pairs(c.segments) do
    seg:Hide()
    seg:ClearAllPoints()
  end
  return c,cp
end

hideConnector = function(c)
  if not c or not c.segments then return end
  for _,seg in pairs(c.segments) do
    seg:Hide()
    seg:ClearAllPoints()
  end
end

local function styleConnectorSegment(seg)
  -- CLEAN5: use the same lightweight gold prerequisite connector on every UI profile.
  -- No rank/maxRank state checks; color is static during tree rendering for stability.
  seg:SetTexture(1,0.82,0,0.92)
end

local function drawPrereq(source, target, page)
  if not source or not target or not source.tier or not source.col or
     not target.tier or not target.col then return end

  local c,cp=acquireConnector(page)
  local thickness=usingPfUI() and 3 or 4
  for _,seg in pairs(c.segments) do styleConnectorSegment(seg) end

  local sourceX=GRID_X0+(source.col-1)*GRID_X
  local sourceDown=talentDisplayY(source.tier)
  local targetX=GRID_X0+(target.col-1)*GRID_X
  local targetDown=talentDisplayY(target.tier)
  local sourceCenterX=sourceX+22
  local targetCenterX=targetX+22
  local sourceCenterDown=sourceDown+22
  local sourceBottom=sourceDown+44
  local targetTop=targetDown

  if source.tier==target.tier and sourceCenterX~=targetCenterX then
    local h=c.segments[1]
    local leftX,width
    if sourceCenterX<targetCenterX then
      leftX=sourceX+44
      width=math.max(thickness,targetX-leftX)
    else
      leftX=targetX+44
      width=math.max(thickness,sourceX-leftX)
    end
    h:SetWidth(width); h:SetHeight(thickness)
    h:SetPoint("TOPLEFT",cp.frame,"TOPLEFT",leftX,-(sourceCenterDown-math.floor(thickness/2)))
    h:Show()
    return
  end

  if targetTop<=sourceBottom then return end
  local gap=targetTop-sourceBottom
  if sourceCenterX==targetCenterX then
    local v=c.segments[1]
    v:SetWidth(thickness); v:SetHeight(gap)
    v:SetPoint("TOPLEFT",cp.frame,"TOPLEFT",sourceCenterX-math.floor(thickness/2),-sourceBottom)
    v:Show()
  else
    local mid=sourceBottom+math.floor(gap/2)
    local v1,h,v2=c.segments[1],c.segments[2],c.segments[3]
    v1:SetWidth(thickness); v1:SetHeight(math.max(2,mid-sourceBottom))
    v1:SetPoint("TOPLEFT",cp.frame,"TOPLEFT",sourceCenterX-math.floor(thickness/2),-sourceBottom)
    v1:Show()
    h:SetWidth(math.max(thickness,math.abs(targetCenterX-sourceCenterX))); h:SetHeight(thickness)
    h:SetPoint("TOPLEFT",cp.frame,"TOPLEFT",math.min(sourceCenterX,targetCenterX),-(mid-math.floor(thickness/2)))
    h:Show()
    v2:SetWidth(thickness); v2:SetHeight(math.max(2,targetTop-mid))
    v2:SetPoint("TOPLEFT",cp.frame,"TOPLEFT",targetCenterX-math.floor(thickness/2),-mid)
    v2:Show()
  end
end

applyViewportClipping = function()
  if not f.scroll or not TI.currentData or not TI.buttons then return end
  local offset=f.scroll:GetVerticalScroll() or 0
  local viewport=f.scroll:GetHeight() or 334
  local tab=TI.currentData.tabs and TI.currentData.tabs[TI.selectedTab]
  if not tab then return end

  for i,t in pairs(tab.talents or {}) do
    local b=TI.buttons[i]
    if b then
      local topDown=talentDisplayY(t.tier)
      local bottomDown=topDown+44
      if topDown>=offset and bottomDown<=(offset+viewport) then
        b:Show()
      else
        b:Hide()
        if TI.hoveredTalentButton==b then
          TI.hoveredTalentButton=nil
          GameTooltip:Hide()
        end
      end
    end

  end
end

local function staticTalentFor(d,page,t)
  if not d or not t or not TalentInspectData_FindTalent then return nil end
  local pos
  if t.tier and t.col then pos=string.char(96+t.tier)..tostring(t.col) end
  -- Name/position are safer than index across custom-client talent ordering.
  local st=TalentInspectData_FindTalent(d.class,page,t.name,pos,t.index)
  if st then return st end
  -- If the live packet supplied a name, that identity boundary is final.
  if t.name and t.name~="" then return nil end
  return TalentInspectData_FindTalent(d.class,page,nil,pos,t.index)
end



local function packagedTalentByExactName(classToken,page,name)
  if not classToken or not name or name=="" or not TalentInspectData_GetTree then return nil end
  local tree=TalentInspectData_GetTree(classToken,page)
  if not tree or not tree.talents then return nil end
  for _,st in pairs(tree.talents) do
    if st and (st.name==name or st.sourceName==name) then return st end
  end
  return nil
end

local function displayedTalentByExactName(tab,name)
  if not tab or not tab.talents or not name or name=="" then return nil end
  for _,lt in pairs(tab.talents) do
    if lt and lt.name==name then return lt end
  end
  return nil
end

local updateSpecButtonVisual

local function selectTab(page)
  -- PREREQLINES2/TREEISOLATE2: hide every page connector layer before the
  -- selected tree identity changes.  Reused textures must never spend even
  -- one render pass carrying geometry from the previous tree.
  resetConnectorPool()
  TI.selectedTab=page
  if TI.embeddedPrefix and TI.hostState[TI.embeddedPrefix] then
    TI.hostState[TI.embeddedPrefix].selectedTab=page
  end
  if f.scrollBar then
    TalentInspect_UpdateScrollRange()
    f.scrollBar:SetValue(0)
    f.scroll:SetVerticalScroll(0)
  elseif f.scroll then
    f.scroll:SetVerticalScroll(0)
  end
  local d=TI.currentData
  if not d or not d.tabs or not d.tabs[page] then return end
  if f.blankPane then f.blankPane:Hide() end
  if f.scroll then f.scroll:Show() end
  if f.canvas then f.canvas:Show() end
  hideButtons()
  resetConnectorPool()
  local tab=d.tabs[page]
  f.treeTitle:SetText((tab.name or "Talent Tree").."  |cffffffff"..(tab.points or 0).." points|r")
  -- FR3d: never let a remote/cached fileName choose another class's artwork.
  local canonicalBG=canonicalTreeBackground(d.class,page)
  setTreeBackground(canonicalBG or tab.fileName)
  if f.scrollBar then
    TalentInspect_UpdateScrollRange()
    f.scrollBar:SetValue(0)
    f.scroll:SetVerticalScroll(0)
  end
  local n=0
  for i,t in pairs(tab.talents or {}) do
    n=n+1
    local b=TI.buttons[i] or makeTalentButton(i)
    b.data=t
    b.ownerName=TI.currentName
    b.page=page
    b.classToken=(TI.currentData and TI.currentData.class) or nil
    b.treeName=(TI.currentData and TI.currentData.tabs and TI.currentData.tabs[page] and TI.currentData.tabs[page].name) or nil
    b.static=staticTalentFor(d,page,t)
    -- Static Hawaiisa data is authoritative for talent metadata/tooltips.
    -- Live sync contributes only the inspected player's current ranks.
    b:ClearAllPoints()
    local x=GRID_X0+(t.col-1)*GRID_X
    local y=-talentDisplayY(t.tier)
    b:SetPoint("TOPLEFT",f.canvas,"TOPLEFT",x,y)
    b:SetFrameLevel((f.canvas and f.canvas:GetFrameLevel() or f:GetFrameLevel())+35)
    b:EnableMouse(1)
    if b.icon then
      b.icon:SetTexture(t.icon)
      b.icon:SetAlpha(1)
      b.icon:Show()
    end
    local rank=t.rank or 0

    -- FR1c: SetTexture() can refresh renderer state on legacy/custom clients.
    -- Reassert the authoritative visual state every page render instead of
    -- trusting a Lua shadow flag from the previously reused talent button.
    if rank<=0 then
      if b.icon.SetDesaturated then b.icon:SetDesaturated(1) end
      b.icon:SetVertexColor(0.75,0.75,0.75)
    else
      if b.icon.SetDesaturated then b.icon:SetDesaturated(nil) end
      b.icon:SetVertexColor(1,1,1)
    end
    b.tiDesaturated=nil

    -- The remote/local client's live maxRank outranks stale packaged data.
    local displayMax=t.maxRank or (b.static and b.static.maxRank) or 1

    -- One neutral outline for every talent. The build reads quickly because
    -- zero-rank talents have no gold 0/# badge at all.
    setTalentBorderColor(b,0.52,0.52,0.52,1)
    if rank<=0 then
      b.rank:SetText("")
      b.rank:Hide()
      if b.rankBG then b.rankBG:Hide() end
    else
      if b.rankBG then b.rankBG:Show() end
      b.rank:Show()
      if rank>=displayMax then
        b.rank:SetTextColor(1,0.82,0)
      else
        b.rank:SetTextColor(0.25,1,0.25)
      end
      b.rank:SetText(rank.."/"..displayMax)
    end
    if b.highlight then b.highlight:SetAlpha(0.18) end
    b:Show()

  end

  -- PREREQLINES2/TREEISOLATE2: prerequisite connectors are a completely
  -- separate render pass.  Clear the pool AGAIN after all reused talent
  -- buttons have been rebound to this tree, then derive every relationship
  -- only from the packaged tree for THIS page and exact displayed names.
  -- This prevents a connector from the previously selected tree from
  -- visually landing on unrelated talents that happen to occupy the same
  -- coordinates.  No connector creation/rebuild happens while scrolling.
  activateConnectorPage(page)
  local packagedTree=TalentInspectData_GetTree and TalentInspectData_GetTree(d.class,page)
  local learnedClass=TalentInspectData_GetLearnedClass and TalentInspectData_GetLearnedClass(d.class)
  local learnedTree=learnedClass and learnedClass.trees and learnedClass.trees[page]

  -- LIVEPREREQ2 authority is identity-first:
  --   learned exact-name relationship > packaged exact-name relationship > none.
  -- Rendering never consumes saved prerequisite coordinates and never scans the
  -- game API. The live scanner updates DATA only; this pass draws DATA only.
  if packagedTree and packagedTree.talents then
    for _,packagedTarget in pairs(packagedTree.talents) do
      if packagedTarget then
        local targetName=packagedTarget.name or packagedTarget.sourceName
        local prereqName=nil
        local learnedTarget=learnedTree and learnedTree.byName and targetName and learnedTree.byName[targetName]
        if learnedTarget and learnedTarget.prereqScanned==1 then
          prereqName=learnedTarget.prereqName or "" -- empty means authoritative NONE
        else
          prereqName=packagedTarget.prereq or ""
        end
        if prereqName~="" then
          local displayedTarget=displayedTalentByExactName(tab,targetName)
          local displayedSource=displayedTalentByExactName(tab,prereqName)
          if displayedSource and displayedTarget then
            drawPrereq(displayedSource,displayedTarget,page)
          end
        end
      end
    end
  end

  for i=1,3 do
    local bt=f.tabs[i]
    local td=d.tabs[i]
    if td then
      bt.text:SetText((td.name or ("Tree "..i)).." "..(td.points or 0))
      bt:SetFrameLevel(f:GetFrameLevel()+180)
      bt:Show()
      if bt.Raise then bt:Raise() end
      updateSpecButtonVisual(bt, i==page)
    else bt:Hide() end
  end
  applyViewportClipping()
end


updateSpecButtonVisual = function(b, selected)
  if not b then return end
  b.tiSelected=selected and 1 or nil

  if usingPfUI() then
    if b.blizzL then b.blizzL:Hide(); b.blizzM:Hide(); b.blizzR:Hide() end
    b.bg:Show(); b.edge:Show()
    if selected then
      b.bg:SetTexture(0.07,0.07,0.085,0.99)
      b.text:SetTextColor(1.00,0.84,0.24)
      b.edge:SetTexture(0.38,0.38,0.42,1)
    else
      b.bg:SetTexture(0.025,0.025,0.032,0.98)
      b.text:SetTextColor(0.82,0.82,0.82)
      b.edge:SetTexture(0.20,0.20,0.22,1)
    end
  else
    -- FR1F: keep the user's finalized inverted CharacterFrame-tab artwork.
    -- Only the artwork is flipped; text remains upright.
    b.bg:Hide()
    b.edge:Hide()
    if b.blizzL then
      local tex
      if selected then tex="Interface\\PaperDollInfoFrame\\UI-Character-ActiveTab"
      else tex="Interface\\PaperDollInfoFrame\\UI-Character-InActiveTab" end
      b.blizzL:SetTexture(tex)
      b.blizzM:SetTexture(tex)
      b.blizzR:SetTexture(tex)
      b.blizzL:Show()
      b.blizzM:Show()
      b.blizzR:Show()
    end
    if selected then b.text:SetTextColor(1.00,0.82,0.00)
    else b.text:SetTextColor(0.82,0.82,0.82) end
  end
end


f.tabs={TalentInspectTab1,TalentInspectTab2,TalentInspectTab3}
for i=1,3 do
  local b=f.tabs[i]
  b:SetFrameLevel(f:GetFrameLevel()+180)
  b:EnableMouse(1)
  b:SetHitRectInsets(-2,-2,-7,-7)
  b:RegisterForClicks("LeftButtonUp")

  -- FR2-XML3: bind the long-lived regions instantiated by XML.
  local n=b:GetName()
  b.bg=getglobal(n.."BG")
  b.blizzL=getglobal(n.."BlizzL")
  b.blizzM=getglobal(n.."BlizzM")
  b.blizzR=getglobal(n.."BlizzR")
  b.edge=getglobal(n.."Edge")
  b.text=getglobal(n.."Text")

  b.page=i
  b:SetScript("OnClick",function() if this.page then selectTab(this.page) end end)
  b:SetScript("OnEnter",function()
    if not this.tiSelected then
      if usingPfUI() and this.bg then this.bg:SetTexture(0.055,0.055,0.065,0.98) end
      if this.text then this.text:SetTextColor(0.95,0.82,0.25) end
    end
  end)
  b:SetScript("OnLeave",function()
    if not this.tiSelected then
      if usingPfUI() and this.bg then this.bg:SetTexture(0.025,0.025,0.032,0.98) end
      if this.text then this.text:SetTextColor(0.82,0.82,0.82) end
    end
  end)
  b:EnableMouseWheel(1)
  b:SetScript("OnMouseWheel",function() if TalentInspect_MouseWheel then TalentInspect_MouseWheel(arg1) end end)
end

-- The legacy top-level frame stays hidden. Native Character/Inspect pages
-- re-anchor it only when the Talents tab is selected.
f:Hide()

local function validCachedBuild(d)
  if not d or not d.name or not d.class or not d.tabs then return nil end
  local names=VPLUS_TREE_NAMES[d.class]
  if not names then return nil end
  for p=1,3 do
    local tab=d.tabs[p]
    if not tab or not tab.name or tab.name=="" or
       tab.name=="Tree "..p or not tab.talents then
      return nil
    end
  end
  return 1
end

local function cachedStatus(d)
  if not d or not d.stamp or d.stamp<=0 or not time then return "Cached" end
  local age=time()-d.stamp
  if age<0 then age=0 end
  if age<60 then return "Cached • <1m old" end
  if age<3600 then return "Cached • "..math.floor(age/60).."m old" end
  if age<86400 then return "Cached • "..math.floor(age/3600).."h old" end
  return "Cached • "..math.floor(age/86400).."d old"
end

local function showData(d, status)
  if not d then return end
  if status~="No sync data" then
    if f.noSyncLeft then f.noSyncLeft:Hide() end
    if f.noSyncRight then f.noSyncRight:Hide() end
  end
  if d.class and TalentInspectData_NormalizeClass then
    d.class=TalentInspectData_NormalizeClass(d.class)
  end
  local canonicalNames=VPLUS_TREE_NAMES[d.class or ""]
  for p=1,3 do
    if d.tabs and d.tabs[p] then
      -- Never display generic legacy "Tree N" labels when class identity is known.
      if canonicalNames and canonicalNames[p] and
         (not d.tabs[p].name or d.tabs[p].name=="" or d.tabs[p].name=="Tree "..p) then
        d.tabs[p].name=canonicalNames[p]
      end
      d.tabs[p].fileName=canonicalTreeBackground(d.class,p) or d.tabs[p].fileName
    end
  end

  TI.currentData=d; TI.currentName=d.name

  if TI.embeddedPrefix and TI.hostState[TI.embeddedPrefix] then
    local hs=TI.hostState[TI.embeddedPrefix]
    hs.name=d.name
    hs.data=d
    hs.selectedTab=TI.selectedTab or hs.selectedTab or 1
  end
  local c=CLASS_COLORS[d.class] or {1,0.82,0}
  f.title:SetTextColor(c[1],c[2],c[3])
  f.title:SetText((d.name or "Unknown").." - "..(d.class or ""))
  f.subtitle:SetText("Level "..tostring(d.level or "?").."  •  VanillaPlus Talents")
  f.status:SetText(status or "Synced")
  -- v0.2.4: TalentInspect is a native Character/Inspect page only.
  -- Never surface the old standalone window.
  if TI.embeddedHost then f:Show() end
  selectTab(TI.selectedTab or 1)
end

-- Sync -----------------------------------------------------------------------
-- IMPORTANT (1.12): never use a literal "|" in addon payloads. WoW treats "|"
-- as a chat escape introducer, and ChatThrottleLib will reject invalid escape
-- sequences before SendAddonMessage. v0.2.1 uses "^" as the field delimiter.
local function sendLocalTo(target, channel)
  if not target or not channel then return end
  local d=captureLocal()
  local session=tostring(math.random(1000,9999))
  local to=safe(target)

  sendLearnedAdvertisement(target,channel)
  queueSend("BEGIN^"..to.."^"..session.."^"..safe(d.name).."^"..safe(d.class).."^"..tostring(d.level or 0),channel)
  for p=1,3 do
    local tab=d.tabs[p]
    if tab then
      queueSend("TAB^"..to.."^"..session.."^"..p.."^"..safe(tab.name).."^"..safe(tab.icon).."^"..tostring(tab.points or 0).."^"..safe(tab.fileName),channel)
      for i,t in pairs(tab.talents) do
        -- Keep every payload comfortably under the 1.12 254-byte prefix+message cap.
        -- Talent descriptions are static DB/UI data and are not sent.
        local msg="TAL^"..to.."^"..session.."^"..p.."^"..i.."^"..safe(t.name).."^"..safe(t.icon).."^"..t.tier.."^"..t.col.."^"..t.rank.."^"..t.maxRank.."^0^0^0"
        if string.len(TI.PREFIX)+string.len(msg)<=254 then
          queueSend(msg,channel)
        end
      end
    end
  end
  queueSend("END^"..to.."^"..session,channel)
end

local function nowSeconds()
  if GetTime then return GetTime() end
  return 0
end

local function pruneTransientSyncState()
  local now=nowSeconds()
  local cutoff=30

  for session,d in pairs(TI.pending or {}) do
    if d and d.startedAt and (now-d.startedAt)>cutoff then
      TI.pending[session]=nil
    end
  end
  for classToken,d in pairs(TI.learnPending or {}) do
    if d and d.startedAt and (now-d.startedAt)>cutoff then
      TI.learnPending[classToken]=nil
      if TalentInspectHelper and TalentInspectHelper.AbortPeerClass then
        TalentInspectHelper:AbortPeerClass(classToken)
      end
    end
  end
  for key,d in pairs(TI.learnDescParts or {}) do
    if d and d.startedAt and (now-d.startedAt)>cutoff then
      TI.learnDescParts[key]=nil
    end
  end
end

local function beginSyncTiming(name)
  pruneTransientSyncState()
  TI.syncActiveName=name
  TI.syncRequestStarted=nowSeconds()
  TI.syncBeginAt=nil
  TI.syncCompleteAt=nil
end

local function markSyncBegin(name)
  if not name or name~=TI.syncActiveName then return end
  TI.syncBeginAt=nowSeconds()
  local t=TI.syncTiming[name] or {}
  if TI.syncRequestStarted then
    t.requestToBegin=TI.syncBeginAt-TI.syncRequestStarted
  end
  TI.syncTiming[name]=t
end

local function markSyncComplete(name)
  if not name then return end

  -- FR2-XML7: completion may arrive after harmless request()/UI refresh calls
  -- have touched current state. Record completion for the active/current owner
  -- as long as we actually have a timing start for this request.
  if name~=TI.syncActiveName and name~=TI.currentName then return end

  TI.syncCompleteAt=nowSeconds()
  local t=TI.syncTiming[name] or {}

  if TI.syncRequestStarted then
    t.requestToComplete=TI.syncCompleteAt-TI.syncRequestStarted
  end
  if TI.syncBeginAt then
    t.beginToComplete=TI.syncCompleteAt-TI.syncBeginAt
  elseif t.requestToBegin and t.requestToComplete then
    t.beginToComplete=t.requestToComplete-t.requestToBegin
  end

  TI.syncTiming[name]=t
  local count=0
  for _ in pairs(TI.syncTiming) do count=count+1 end
  if count>40 then
    for oldName in pairs(TI.syncTiming) do
      if oldName~=name then
        TI.syncTiming[oldName]=nil; count=count-1
        if count<=40 then break end
      end
    end
  end
end

local fallbackDriver=CreateFrame("Frame")

local function stopFallbackTimer()
  TI.fallbackName=nil
  TI.fallbackClass=nil
  TI.fallbackGeneration=nil
  TI.fallbackElapsed=0
  fallbackDriver:SetScript("OnUpdate",nil)
  fallbackDriver:Hide()
end

local function showNoSyncMessages(leftText,rightText,rightState)
  if not f.noSyncLeft or not f.noSyncRight then return end

  if leftText and leftText~="" then
    f.noSyncLeft:SetText(leftText)
    if leftText=="Target NOT in party, raid, guild" then
      f.noSyncLeft:SetTextColor(1,0.15,0.15)
    else
      f.noSyncLeft:SetTextColor(0.70,0.70,0.70)
    end
    f.noSyncLeft:Show()
  else
    f.noSyncLeft:Hide()
  end

  if rightText and rightText~="" then
    f.noSyncRight:SetText(rightText)
    if rightState=="success" then
      f.noSyncRight:SetTextColor(0.20,1.00,0.20)
    else
      f.noSyncRight:SetTextColor(0.70,0.70,0.70)
    end
    f.noSyncRight:Show()
  else
    f.noSyncRight:Hide()
  end
end

local function showBlankLoadedStatus(noTransport)
  showNoSyncMessages(
    noTransport and "Target NOT in party, raid, guild" or nil,
    "No sync data blank loaded",
    "blank"
  )
end

local function showSyncSuccessStatus()
  -- STATUSGREEN1: once sync succeeds, positively confirm transport eligibility
  -- in the same top/left status position that shows the red failure message.
  showNoSyncMessages("Target IS in party, raid, guild","Sync data load successful","success")
  if f.noSyncLeft then
    f.noSyncLeft:SetTextColor(0.20,1.00,0.20)
  end
end

local function hideNoSyncMessages()
  if f.noSyncLeft then f.noSyncLeft:Hide() end
  if f.noSyncRight then f.noSyncRight:Hide() end
end

local function showZeroTalentFallback(name,classToken,leftText,rightText)
  if not name or not classToken then return nil end

  local d=buildZeroTalentData(name,classToken,UnitLevel("target"))
  if not d or not d.tabs or not d.tabs[1] then return nil end

  local hs=TI.hostState and TI.hostState.InspectFrame
  local keepTab=(hs and hs.selectedTab) or TI.selectedTab or 1
  if keepTab<1 or keepTab>3 then keepTab=1 end

  TI.currentName=name
  TI.currentData=d
  TI.selectedTab=keepTab

  if hs then
    hs.name=name
    hs.data=d
    hs.selectedTab=keepTab
  end

  showData(d,"No sync data")
  -- TABSTAY1: keep the same tree page while provisional/blank data is shown.
  selectTab(keepTab)
  showBlankLoadedStatus(leftText=="Target NOT in party, raid, guild")
  return 1
end

local function startFallbackTimer(name,classToken,leftText,rightText)
  stopFallbackTimer()
  TI.fallbackName=name
  TI.fallbackClass=classToken
  TI.fallbackGeneration=TI.renderGeneration
  TI.fallbackElapsed=0

  if leftText=="Target NOT in party, raid, guild" then
    showNoSyncMessages("Target NOT in party, raid, guild",nil,nil)
  else
    hideNoSyncMessages()
  end

  fallbackDriver:Show()
  fallbackDriver:SetScript("OnUpdate",function()
    -- Never allow empty fallback to race a real sync that has started.
    if TI.syncActiveName==TI.fallbackName and TI.syncBeginAt then
      stopFallbackTimer()
      return
    end

    TI.fallbackElapsed=TI.fallbackElapsed+(arg1 or 0)
    if TI.fallbackElapsed<TI.FALLBACK_DELAY then return end

    local wanted=TI.fallbackName
    local class=TI.fallbackClass
    local generation=TI.fallbackGeneration
    stopFallbackTimer()

    if TI.embeddedPrefix=="InspectFrame" and f:IsShown() and
       wanted and wanted==TI.currentName and
       generation==TI.renderGeneration and TI.renderOwner==wanted and
       not (TI.syncActiveName==wanted and TI.syncBeginAt) then
      -- NOBLANK2: the full provisional tree already exists. Timeout changes
      -- status only; it never rebuilds or blanks the page.
      showBlankLoadedStatus(false)
    end
  end)
end

local function showNoTransport(name)
  stopFallbackTimer()

  local _,classToken=UnitClass("target")
  if TalentInspectData_NormalizeClass then
    classToken=TalentInspectData_NormalizeClass(classToken)
  end

  -- NOCHANNELFIX1:
  -- No PARTY/RAID/GUILD transport means a real sync CANNOT start, so there is
  -- nothing useful to wait 1.5 seconds for. The old path parked the legacy
  -- InspectFrame on BlankPane and depended on an OnUpdate transition. The
  -- supplied video shows that transition can fail and leave the client in a
  -- permanently black custom inspect page before #132.
  --
  -- Build the complete packaged gray 0/0/0 tree immediately instead.
  if name and classToken then
    if showZeroTalentFallback(
      name,
      classToken,
      "Target NOT in party, raid, guild",
      nil
    ) then
      TI.requestGuardName=name
      TI.requestLoadedName=name
      TI.requestCooldownUntil=nil
      return
    end
  end

  -- If even target class identity vanished during this exact transition, do
  -- not leave an ownerless black page alive.
  hideButtons()
  showBlankPane()
  showNoSyncMessages("Target NOT in party, raid, guild",nil,nil)
  f:Hide()
  closeInvalidInspectTarget()
end

local function request(name)
  if not name or name=="" then return end

  -- SPAMGUARD2_7S: coalesce impatient back-to-back Talents clicks for 7 seconds.
  -- This is only a time gate around the actual sync request; repeated popup/tab
  -- clicks may still raise/reuse the UI, but they cannot queue another REQ.
  local guardNow=nowSeconds()
  if TI.requestGuardName==name and TI.requestCooldownUntil and
     guardNow<TI.requestCooldownUntil then
    if f:IsShown() and f.Raise then f:Raise() end
    return
  end
  TI.requestGuardName=name
  TI.requestCooldownUntil=guardNow+7.0

  TI.renderGeneration=(TI.renderGeneration or 0)+1
  TI.renderOwner=name
  local requestGeneration=TI.renderGeneration

  TI.currentName=name
  beginSyncTiming(name)

  TI.syncExpectedName=name
  local _,expectedClass=UnitClass("target")
  if TalentInspectData_NormalizeClass then
    expectedClass=TalentInspectData_NormalizeClass(expectedClass)
  end
  TI.syncExpectedClass=expectedClass
  local cached=getCachedBuild(name)
  if cached and not validCachedBuild(cached) then
    -- TREEFIX1: quarantine a malformed legacy cache entry instead of rendering
    -- generic Tree 1/2/3 state. This repairs players previously affected by
    -- the destructive old /ti clearcache behavior on their next inspection.
    removeCachedBuild(name)
    cached=nil
  end
  if cached and cached.name==name and TI.embeddedPrefix=="InspectFrame" then
    local hs=TI.hostState.InspectFrame
    hs.name=name
    hs.data=cached
    TI.selectedTab=hs.selectedTab or 1
    showData(cached,cachedStatus(cached))
  end

  local channel=transportFor(name)
  TI.syncDiag=TI.syncDiag or {}
  TI.syncDiag.lastRequestName=name
  TI.syncDiag.lastRequestChannel=channel or "NONE"
  TI.syncDiag.lastRequestAt=GetTime and GetTime() or 0

  if not channel then
    if not cached then showNoTransport(name) end
    return
  end

  if not cached then
    local _,classToken=UnitClass("target")
    if TalentInspectData_NormalizeClass then
      classToken=TalentInspectData_NormalizeClass(classToken)
    end

    -- NOBLANK2: always establish a complete packaged tree before networking.
    if not showZeroTalentFallback(name,classToken,nil,nil) then
      f:Hide()
      closeInvalidInspectTarget()
      return
    end

    -- Valid transport: provisional gray tree stays visible while BEGIN gets
    -- its 1.5-second chance. Do not show the gray timeout label yet.
    hideNoSyncMessages()
    startFallbackTimer(name,classToken,nil,nil)
  end

  -- Address the request inside the payload; the valid 1.12 transport itself is shared.
  queueSend("REQ^"..safe(name).."^"..safe(UnitName("player")).."^"..TI.VERSION,channel)
end


renderStaticTalentTooltip = function(button)
  if not button or not button.data then return end

  local live=button.data
  local d=TI.currentData
  local page=button.page or TI.selectedTab or 1
  local classToken=button.classToken or (d and d.class)
  if TalentInspectData_NormalizeClass then
    classToken=TalentInspectData_NormalizeClass(classToken)
  end

  local st=nil
  if TalentInspectData_FindTalent and classToken then
    local pos=nil
    if live.tier and live.col then
      pos=string.char(96+live.tier)..tostring(live.col)
    end
    st=TalentInspectData_FindTalent(classToken,page,live.name,pos,live.index)
    -- Never positional/index-substitute another talent when live.name exists.
    if not st and (not live.name or live.name=="") then
      st=TalentInspectData_FindTalent(classToken,page,nil,pos,live.index)
    end
  end
  button.static=st

  GameTooltip:SetOwner(button,"ANCHOR_RIGHT")
  GameTooltip:ClearLines()

  -- FR4g: the inspected player's live TAL packet is structural authority.
  -- Static/learned metadata may provide descriptions/requirements, but may not
  -- rewrite the live talent name or max rank.
  local title=live.name or (st and st.name) or "Talent"
  local rank=live.rank or 0
  local maxRank=live.maxRank or (st and st.maxRank) or 1
  GameTooltip:SetText(title,1,0.82,0)

  if rank>0 then
    GameTooltip:AddLine("Rank "..rank.." / "..maxRank,1,0.82,0)
  else
    GameTooltip:AddLine("Rank 0 / "..maxRank,0.75,0.75,0.75)
  end

  if st then
    local shownRank=rank
    if shownRank<1 then shownRank=1 end
    if shownRank>maxRank then shownRank=maxRank end

    if rank==0 then GameTooltip:AddLine("Rank 1",0.45,0.70,1) end

    -- FR4f: all description authority is centralized in TalentData.lua.
    -- Do not inspect .desc/.descriptions directly here.
    local desc,descSource=nil,"none"
    if TalentInspectData_GetDescription then
      desc,descSource=TalentInspectData_GetDescription(st,shownRank)
    end

    if desc and desc~="" then
      GameTooltip:AddLine(desc,1,1,1,1)
    else
      GameTooltip:AddLine("Talent description unavailable for this rank",0.65,0.65,0.65)
    end

    if rank>0 and rank<maxRank then
      local nextDesc=nil
      if TalentInspectData_GetDescription then
        nextDesc=TalentInspectData_GetDescription(st,rank+1)
      end
      if nextDesc and nextDesc~="" then
        GameTooltip:AddLine(" ",1,1,1)
        GameTooltip:AddLine("Next rank:",0.25,1,0.25)
        GameTooltip:AddLine(nextDesc,0.78,0.88,0.78,1)
      end
    end

    if st.reqPoints and st.reqPoints>0 then
      local treeName=button.treeName or (d and d.tabs and d.tabs[page] and d.tabs[page].name) or "this tree"
      GameTooltip:AddLine("Requires "..st.reqPoints.." points in "..treeName,0.65,0.65,0.65)
    end
    if st.prereq then
      GameTooltip:AddLine("Requires "..st.prereq,1,0.25,0.25)
    end
  else
    GameTooltip:AddLine("Talent data match unavailable",1,0.30,0.30)
    GameTooltip:AddLine("Class: "..tostring(classToken or "nil").."  Tree: "..tostring(page),0.55,0.55,0.55)
    if live.tier and live.col then
      GameTooltip:AddLine("Pos: "..tostring(live.tier)..","..tostring(live.col),0.55,0.55,0.55)
    end
  end

  GameTooltip:Show()
end

-- Compatibility shim: old code may still call this, but it now goes through
-- the SAME static renderer. No second tooltip implementation remains.
renderRemoteTalentTooltip = function(button)
  if renderStaticTalentTooltip then
    renderStaticTalentTooltip(button)
  end
end

-- Remote talent descriptions ---------------------------------------------------
-- Hawaiisa's calculator contains full rank-sensitive descriptions. For live
-- server fidelity, remote hover asks the inspected player's own client for the
-- exact current tooltip and caches it.
local tooltipScanner=CreateFrame("GameTooltip","TalentInspectTooltipScanner",UIParent,"GameTooltipTemplate")
tooltipScanner:SetOwner(UIParent,"ANCHOR_NONE")
local descParts={}
local descRequested={}

local function escapeTooltipText(s)
  s=tostring(s or "")
  s=string.gsub(s,"%%","%%25")
  s=string.gsub(s,"|","%%7C")
  s=string.gsub(s,"%^","%%5E")
  s=string.gsub(s,"\n","%%0A")
  return s
end

local function unescapeTooltipText(s)
  s=tostring(s or "")
  s=string.gsub(s,"%%0A","\n")
  s=string.gsub(s,"%%5E","^")
  s=string.gsub(s,"%%7C","|")
  s=string.gsub(s,"%%25","%%")
  return s
end

local function scanLocalTalentDescription(page,index)
  if not tooltipScanner or not tooltipScanner.SetTalent then return "" end

  tooltipScanner:Hide()
  tooltipScanner:SetOwner(UIParent,"ANCHOR_NONE")
  tooltipScanner:ClearLines()
  tooltipScanner:SetTalent(page,index)
  tooltipScanner:Show()

  local talentName=GetTalentInfo(page,index)
  local lines={}
  local n=20
  if tooltipScanner.NumLines then
    n=tooltipScanner:NumLines() or 20
  end
  if n<2 then n=20 end

  for i=1,n do
    local l=getglobal("TalentInspectTooltipScannerTextLeft"..i)
    local r=getglobal("TalentInspectTooltipScannerTextRight"..i)
    local lt=l and l:GetText()
    local rt=r and r:GetText()

    if lt and lt~="" then
      local isTitle=(talentName and lt==talentName)
      local isRank=string.find(lt,"^Rank ")
      if not isTitle and not isRank then table.insert(lines,lt) end
    end
    if rt and rt~="" and not string.find(rt,"^Rank ") then
      table.insert(lines,rt)
    end
  end

  tooltipScanner:Hide()
  return table.concat(lines,"\n")
end

local function cacheDescription(name,page,index,text)
  descRequested[tostring(name)..":"..tostring(page)..":"..tostring(index)]=nil
  local d=getCachedBuild(name)
  if not d or not d.tabs or not d.tabs[page] or not d.tabs[page].talents[index] then return end
  d.tabs[page].talents[index].description=text
  TalentInspectDB.cache[name]=compactCachedBuild(d)
  if TI.currentData==d then TI.currentData.tabs[page].talents[index].description=text end

  local hb=TI.hoveredTalentButton
  if hb and hb.data and hb.data.index==index and hb.page==page and (hb.ownerName==name or not hb.ownerName) then
    hb.data.description=text
    if renderRemoteTalentTooltip then renderRemoteTalentTooltip(hb) end
  end
end

requestTalentDescription = function(name,page,index)
  -- SAFE5: disabled legacy direct-description request path. FR4f Learned Data resolver owns hover authority.
  return
end

local function sendDescriptionTo(requester,page,index,channel)
  -- SAFE5: no hidden GameTooltip:SetTalent scan / description chunk traffic.
  return
end

-- Native Character / Inspect page integration --------------------------------
-- v0.2.4 follows the actual Turtle WoW 1.12 inspect-tab pattern:
--   * create the tab using the host's normal global tab name (InspectFrameTab3)
--   * PanelTemplates_TabResize(0, tab) -- 1.12 argument order is padding, tab
--   * PanelTemplates_SetNumTabs(host, count)
--   * PanelTemplates_SetTab(host, numericID)
-- TalentInspect's content is parented directly into the existing host frame.
-- The old standalone TalentInspectFrame is never shown by normal user actions.

local nativeTabs = {}

local function tabText(tab)
  if not tab or not tab.GetText then return "" end
  return string.lower(tostring(tab:GetText() or ""))
end

local function findHonorTab(prefix)
  local last=nil
  for i=1,10 do
    local tab=getglobal(prefix.."Tab"..i)
    if tab then
      last=tab
      local txt=tabText(tab)
      if txt=="honor" or (HONOR and txt==string.lower(HONOR)) then return tab,i end
    end
  end
  return nil,nil
end

local function hostPlayerName(host, prefix)
  if host and type(host.unit)=="string" and UnitExists(host.unit) and UnitIsPlayer(host.unit) then
    return UnitName(host.unit)
  end
  if prefix=="InspectFrame" and UnitExists("target") and UnitIsPlayer("target") then
    return UnitName("target")
  end
  return UnitName("player")
end

local function hideNamedFrame(name)
  local x=getglobal(name)
  if x and x~=f and x.Hide then x:Hide() end
end

local function hideHostPages(prefix)
  if prefix=="InspectFrame" then
    -- Turtle's own implementation uses INSPECTFRAME_SUBFRAMES. Honor that list
    -- when present, while also covering common 1.12/custom frame names.
    if INSPECTFRAME_SUBFRAMES then
      for _,name in pairs(INSPECTFRAME_SUBFRAMES) do
        if name and name~="TalentInspectNativePage" and name~="InspectTalentsFrame" then
          hideNamedFrame(name)
        end
      end
    end
    hideNamedFrame("InspectPaperDollFrame")
    hideNamedFrame("InspectHonorFrame")
    hideNamedFrame("InspectPVPFrame")
  else
    hideNamedFrame("PaperDollFrame")
    hideNamedFrame("PetPaperDollFrame")
    hideNamedFrame("ReputationFrame")
    hideNamedFrame("SkillFrame")
    hideNamedFrame("HonorFrame")
    hideNamedFrame("PVPFrame")
  end
end

local function showEmbeddedTalents(host, prefix)
  if not host or prefix~="InspectFrame" then return nil end

  hideHostPages(prefix)
  TI.embeddedPrefix=prefix
  setEmbeddedMode(host)

  -- Resolve ownership BEFORE showing the reusable TalentInspect canvas.
  local name=hostPlayerName(host,prefix)
  if not name or name=="" or name==UnitName("player") then
    -- OPENFIX1: InspectUnit/InspectFrame identity can lag by a frame or two.
    -- Do NOT treat a host with no resolved inspected name as successfully
    -- embedded, otherwise the custom tab can sit on an empty page forever.
    f:Hide()
    return nil
  end

  local hs=TI.hostState.InspectFrame
  local keepTab=(hs and hs.selectedTab) or TI.selectedTab or 1
  if keepTab<1 or keepTab>3 then keepTab=1 end

  -- Player transition boundary: invalidate every visible reference belonging
  -- to the previous inspected player before the new player's cache/request is
  -- allowed to show anything.
  if TI.currentName~=name or (hs and hs.name and hs.name~=name) then
    TI.requestGuardName=nil
    TI.requestLoadedName=nil
    TI.requestCooldownUntil=nil
    f:Hide()
    hideButtons()

    -- DEEPHARDEN1/NOBLANK3: player transition is teardown only. Never arm the
    -- black BlankPane during a normal inspect transition.
    if f.blankPane then f.blankPane:Hide() end
    if f.treeBackgroundClip then f.treeBackgroundClip:Hide() end
    if f.treeBackground then f.treeBackground:Hide() end
    for i=1,4 do if tiles[i] then tiles[i]:Hide() end end
    for i=1,3 do if f.tabs[i] then f.tabs[i]:Hide() end end

    TI.currentData=nil
    TI.currentName=name
    TI.hoveredTalentButton=nil
    if GameTooltip then GameTooltip:Hide() end
    if hs then
      hs.name=name
      hs.data=nil
      hs.selectedTab=keepTab
    end
    TI.selectedTab=keepTab
  end

  if f.scroll then f.scroll:Show() end
  if f.scrollBar then f.scrollBar:Show() end

  -- Show only data that is explicitly owned by THIS player.
  local cached=getCachedBuild(name)
  if cached and cached.name==name then
    if hs then
      hs.name=name
      hs.data=cached
    end
    showData(cached,cachedStatus(cached))
  else
    -- Do not show an empty custom page. request(name) immediately renders the
    -- packaged provisional 0/0/0 tree before networking can matter.
    hideButtons()
    if f.blankPane then f.blankPane:Hide() end
    f.treeTitle:SetText("")
    f.title:SetText(name)
    f.subtitle:SetText("")
    f.status:SetText("")
  end

  request(name)
  if f.Raise then f:Raise() end
  return 1
end

local function hideEmbeddedForHost(host)
  if TI.embeddedHost==host then
    stopFallbackTimer()
    TI.requestGuardName=nil
    TI.requestLoadedName=nil
    TI.requestCooldownUntil=nil
    if f.blankPane then f.blankPane:Hide() end
    f:Hide()
    TI.embeddedHost=nil
    TI.embeddedPrefix=nil
  end
end

local function hookNativeSubFrameShows(host,prefix)
  if prefix=="CharacterFrame" then return end
  if not host or host.TalentInspectSubframeHooks then return end
  host.TalentInspectSubframeHooks=1

  local names
  if prefix=="InspectFrame" then
    names={"InspectPaperDollFrame","InspectHonorFrame","InspectPVPFrame"}
  else
    names={"PaperDollFrame","PetPaperDollFrame","ReputationFrame","SkillFrame","HonorFrame","PVPFrame"}
  end

  for _,name in pairs(names) do
    local sub=getglobal(name)
    if sub and not sub.TalentInspectOnShowHook then
      local old=sub:GetScript("OnShow")
      sub:SetScript("OnShow",function()
        hideEmbeddedForHost(host)
        if old then old() end
      end)
      sub.TalentInspectOnShowHook=1
    end
  end
end

local function hookOtherTabs(host,prefix,talentTab)
  for i=1,10 do
    local tab=getglobal(prefix.."Tab"..i)
    if tab and tab~=talentTab and not tab.TalentInspectHooked then
      local old=tab:GetScript("OnClick")
      tab:SetScript("OnClick",function()
        hideEmbeddedForHost(host)
        if old then old() end
      end)
      tab.TalentInspectHooked=1
    end
  end
end

local function installNativeTab(prefix)
  -- FR1b safety boundary: never attach TalentInspect to the local CharacterFrame.
  if prefix=="CharacterFrame" then return nil end
  local host=getglobal(prefix)
  if not host then return nil end

  -- Reuse our already-created tab after lazy UI reloads.
  if nativeTabs[prefix] and nativeTabs[prefix].GetParent and
     nativeTabs[prefix]:GetParent()==host then
    return nativeTabs[prefix]
  end
  nativeTabs[prefix]=nil

  local honor,honorIndex=findHonorTab(prefix)
  if not honor then return nil end

  local newIndex=(honor.GetID and honor:GetID()) or honorIndex
  newIndex=newIndex+1

  -- Reuse an existing Talents tab if this client/server already made one, BUT
  -- still adopt/wire its click handler. v0.4.0 returned early here, which is
  -- why stock Blizzard/minimal setups could show a Talents tab that opened a
  -- completely blank page.
  local tab=nil
  for i=1,10 do
    local existing=getglobal(prefix.."Tab"..i)
    if existing and tabText(existing)=="talents" then
      tab=existing
      newIndex=(existing.GetID and existing:GetID()) or i
      break
    end
  end

  -- The global naming is intentional. 1.12 PanelTemplates_UpdateTabs expects
  -- host tabs to follow CharacterFrameTabN / InspectFrameTabN naming.
  if not tab then
    local globalName=prefix.."Tab"..newIndex
    tab=getglobal(globalName)
    if not tab then tab=CreateFrame("Button",globalName,host,"CharacterFrameTabButtonTemplate") end
    tab:SetID(newIndex)
    tab:SetText("Talents")
    tab:ClearAllPoints()
    if usingPfUI() then
      tab:SetPoint("LEFT",honor,"RIGHT",5,0)
    else
      -- Stock Blizzard CharacterFrameTabButtonTemplate tabs overlap edges.
      -- Positive spacing leaves "Talents" floating far outside the panel.
      tab:SetPoint("LEFT",honor,"RIGHT",-15,0)
    end
  end

  -- Normalize the adopted tab too. Custom server UIs sometimes ship an
  -- existing Talents button with a detached anchor.
  tab:ClearAllPoints()
  if usingPfUI() then
    tab:SetPoint("LEFT",honor,"RIGHT",5,0)
  else
    tab:SetPoint("LEFT",honor,"RIGHT",-15,0)
  end

  -- IMPORTANT: this is the exact 1.12/Turtle signature:
  -- PanelTemplates_TabResize(padding, tab)
  if usingPfUI() then
    if PanelTemplates_TabResize then PanelTemplates_TabResize(2,tab) end
    if tab.SetWidth and tab:GetWidth()<62 then tab:SetWidth(62) end
  else
    if PanelTemplates_TabResize then PanelTemplates_TabResize(0,tab) end
  end
  if PanelTemplates_SetNumTabs then PanelTemplates_SetNumTabs(host,newIndex) end

  tab:SetScript("OnEnter",function()
    GameTooltip:SetOwner(this,"ANCHOR_RIGHT")
    GameTooltip:SetText("Talents",1,1,1)
  end)
  tab:SetScript("OnLeave",function() GameTooltip:Hide() end)
  tab:SetScript("OnClick",function()
    PlaySound("igCharacterInfoTab")
    if PanelTemplates_SetTab then PanelTemplates_SetTab(host,newIndex) end

    -- DEEPHARDEN1: native tab clicks are user-facing entry points too.
    -- Do not synchronously hide pages/render/request from the click callback.
    local name=hostPlayerName(host,prefix)
    if TI.QueueSafeEmbed and name and name~="" then
      TI.QueueSafeEmbed(host,prefix,name)
    end
  end)

  -- Match installed pfUI instead of fighting it.
  if usingPfUI() and pfUI.api.SkinTab then
    pfUI.api.SkinTab(tab)
  end

  nativeTabs[prefix]=tab
  hookOtherTabs(host,prefix,tab)
  hookNativeSubFrameShows(host,prefix)
  return tab
end

local inspectFrameGuardInstalled=nil

-- GUARD2: forward declarations are required in Lua 5.0 because the
-- InspectFrame OnEvent closure is created before the helper implementations
-- later in this file. Without these locals, the closure resolves globals and
-- can throw "attempt to call global ... (a nil value)" when a target logs out.
local targetCanBeInspectedSafely
local closeInvalidInspectTarget

local function installInspectFrameGuard()
  if inspectFrameGuardInstalled then return end
  local host=getglobal("InspectFrame")
  if not host or not host.GetScript or not host.SetScript then return end
  local oldOnEvent=host:GetScript("OnEvent")
  if not oldOnEvent then return end

  host:SetScript("OnEvent",function()
    -- Stock Blizzard_InspectUI can attempt portrait work during a target swap
    -- after the old inspected unit has become invalid. When TalentInspect owns
    -- the InspectFrame, swallow only that invalid PLAYER_TARGET_CHANGED event.
    if event=="PLAYER_TARGET_CHANGED" and host and host:IsShown() then
      local safe=nil
      if targetCanBeInspectedSafely then safe=targetCanBeInspectedSafely() end
      if not safe then
        -- HOSTILESAFE1: do not let stock Blizzard_InspectUI process a target
        -- transition to a hostile/invalid player.  Its PaperDoll/portrait code
        -- calls SetUnit/SetPortraitTexture with an unusable inspect unit on this
        -- client.  Cross-faction party/raid members pass the helper above.
        if closeInvalidInspectTarget then
          closeInvalidInspectTarget()
        else
          if host then host:Hide() end
        end
        return
      end
    end
    oldOnEvent()
  end)
  inspectFrameGuardInstalled=1
end

local function installNativeTabs()
  -- FR1b: TalentInspect is inspect-only. Do not create/adopt a custom Talents
  -- tab on CharacterFrame; the server/default N talent window owns local talents.
  installNativeTab("InspectFrame")
  installInspectFrameGuard()
end

local function clickTalentTabFor(prefix)
  local host=getglobal(prefix)
  local tab=installNativeTab(prefix)
  if not host or not tab then return nil end

  local id=tab:GetID()
  if PanelTemplates_SetTab then PanelTemplates_SetTab(host,id) end

  hideHostPages(prefix)
  local embedded=showEmbeddedTalents(host,prefix)

  if embedded then
    hideHostPages(prefix)
    return 1
  end

  -- OPENFIX1: identity is not ready yet. Restore native Inspect visibility
  -- instead of leaving a selected Talents tab with every page hidden.
  f:Hide()
  return nil
end

local function openSelfTalents()
  -- FR1b: local talents belong to the server/default N talent UI.
  -- TalentInspect still captures local talents internally when responding
  -- to another player's addon request, but renders no duplicate local tree.
  DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99TalentInspect:|r local talents use the normal Talents window (N). TalentInspect is for inspecting other players.")
end

-- OPENFIX1 forward state for bounded InspectFrame open retry.
-- Declared here so reset/close paths can cancel it safely.
local pendingNativeOpen
local pendingNativeElapsed=0

-- HOSTILESAFE1: Blizzard_InspectUI cannot safely InspectUnit() a genuinely
-- hostile player on this client.  VanillaPlus can have cross-faction party/raid
-- members, so faction/race is NOT authoritative here: a roster member is always
-- allowed, even if UnitIsFriend/UnitCanCooperate reports an odd faction result.
local function targetIsFriendlyOrGroupedForInspect()
  if not UnitExists("target") or not UnitIsPlayer("target") then return nil end

  local targetName=UnitName("target")
  if not targetName or targetName=="" then return nil end

  -- Explicit group membership wins for VanillaPlus cross-faction grouping.
  if isNameInParty(targetName) or isNameInRaid(targetName) then return 1 end

  -- Outside a group, require Blizzard's relationship APIs to consider the
  -- target cooperative/friendly.  Guard both APIs because private-server
  -- clients can expose only one or implement them slightly differently.
  if UnitCanCooperate and UnitCanCooperate("player","target") then return 1 end
  if UnitIsFriend and UnitIsFriend("player","target") then return 1 end

  return nil
end

targetCanBeInspectedSafely = function()
  if not UnitExists("target") or not UnitIsPlayer("target") then return nil end
  if UnitName("target")==UnitName("player") then return nil end
  if not targetIsFriendlyOrGroupedForInspect() then return nil end

  -- 1.12 InspectUnit itself is normally gated by CheckInteractDistance(...,1).
  if CheckInteractDistance and not CheckInteractDistance("target",1) then
    return nil
  end
  return 1
end

local function resetInspectTalentView(newName)
  pendingNativeOpen=nil
  stopFallbackTimer()
  hideNoSyncMessages()
  f:Hide()
  hideButtons()

  -- TARGETSAFE1/NOBLANK2:
  -- reset is teardown, not a render state. Do not turn BlankPane on, because a
  -- later host re-show can expose stale transitional black content.
  if f.blankPane then f.blankPane:Hide() end
  if f.treeBackgroundClip then f.treeBackgroundClip:Hide() end
  if f.treeBackground then f.treeBackground:Hide() end
  for i=1,4 do if tiles[i] then tiles[i]:Hide() end end
  for i=1,3 do if f.tabs[i] then f.tabs[i]:Hide() end end
  TI.renderGeneration=(TI.renderGeneration or 0)+1
  TI.renderOwner=nil
  TI.currentData=nil
  TI.currentName=newName
  TI.hoveredTalentButton=nil
  local hs=TI.hostState and TI.hostState.InspectFrame
  local keepTab=(hs and hs.selectedTab) or TI.selectedTab or 1
  if keepTab<1 or keepTab>3 then keepTab=1 end
  TI.selectedTab=keepTab
  if GameTooltip then GameTooltip:Hide() end
  if hs then
    hs.name=newName
    hs.data=nil
    hs.selectedTab=keepTab
  end
end

closeInvalidInspectTarget = function()
  resetInspectTalentView(UnitExists("target") and UnitName("target") or nil)
  local host=getglobal("InspectFrame")
  if host then
    if HideUIPanel then HideUIPanel(host) else host:Hide() end
  end
end

local function openTargetTalentsImpl()
  if not UnitExists("target") or not UnitIsPlayer("target") then
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99TalentInspect:|r target another player to inspect talents.")
    return
  end
  if UnitName("target")==UnitName("player") then
    openSelfTalents()
    return
  end

  -- Always open Blizzard's real inspect panel first.
  if f:GetParent()==UIParent then f:Hide() end

  local targetName=UnitName("target")
  if targetName and TI.currentName and targetName~=TI.currentName then
    resetInspectTalentView(targetName)
  end

  -- Never hand an out-of-range/invalid target to Blizzard_InspectUI.
  -- On stock 1.12 this can leave InspectFrame with an invalid unit and later
  -- trigger SetPortraitTexture(texture,"unit") usage errors.
  if not targetCanBeInspectedSafely() then
    closeInvalidInspectTarget()
    return
  end

  -- OPENFIX1: call legacy InspectUnit exactly ONCE per user open.
  -- Repeated InspectUnit/ShowUIPanel calls during frame initialization are
  -- avoided; old 1.12 clients are much safer when we wait for the host identity.
  if InspectUnit then InspectUnit("target") end

  installNativeTabs()
  local host=getglobal("InspectFrame")
  if host then
    if ShowUIPanel then ShowUIPanel(host) else host:Show() end
    if clickTalentTabFor("InspectFrame") then return 1 end
  end

  -- InspectFrame exists but its inspected-player identity can become valid a
  -- little later. Retry ONLY the lightweight embed step.
  pendingNativeOpen={kind="target",tries=0,targetName=targetName,
    generation=TI.renderGeneration}
  pendingNativeElapsed=0
  startNativeOpenDriver()
end


local openTransactionBusy=nil
local function openTargetTalents()
  if openTransactionBusy then return nil end
  openTransactionBusy=1
  local result=openTargetTalentsImpl()
  openTransactionBusy=nil
  return result
end

-- SAFE3:
-- No permanent Character/Inspect visibility OnUpdate polling.
-- Native CharacterFrame / InspectFrame tab clicks already call the page-hide
-- path directly. The short-lived nativeOpenDriver below is retained only while
-- an Inspect/Character Talents page is actively being opened.
--
-- This deliberately trades a little fallback cleverness for maximum stability
-- on legacy/custom 1.12 clients, especially while the game is unfocused.

local nativeOpenDriver=CreateFrame("Frame")

local function TalentInspect_NativeOpenUpdate()
  if not pendingNativeOpen then
    this:SetScript("OnUpdate",nil)
    pendingNativeElapsed=0
    return
  end

  pendingNativeElapsed=pendingNativeElapsed+(arg1 or 0)
  if pendingNativeElapsed<0.15 then return end
  pendingNativeElapsed=0

  -- Target ownership changed/disappeared while InspectFrame was settling.
  local expected=pendingNativeOpen.targetName
  local expectedGeneration=pendingNativeOpen.generation
  if not expected or expectedGeneration~=TI.renderGeneration or
     not UnitExists("target") or not UnitIsPlayer("target") or
     UnitName("target")~=expected or not targetCanBeInspectedSafely() then
    pendingNativeOpen=nil
    this:SetScript("OnUpdate",nil)
    closeInvalidInspectTarget()
    return
  end

  pendingNativeOpen.tries=(pendingNativeOpen.tries or 0)+1
  local host=getglobal("InspectFrame")
  local done=nil
  if host and host:IsShown() then
    -- Lightweight retry only. Never call InspectUnit or ShowUIPanel again here.
    done=clickTalentTabFor("InspectFrame")
  end

  if done then
    pendingNativeOpen=nil
    this:SetScript("OnUpdate",nil)
    return
  end

  -- Hard stop after 5 attempts (~0.75s). Never leave an infinitely blank
  -- TalentInspect page alive if Blizzard never exposes valid inspect ownership.
  if pendingNativeOpen.tries>=5 then
    pendingNativeOpen=nil
    this:SetScript("OnUpdate",nil)
    stopFallbackTimer()
    f:Hide()

    -- Return the host to a safe native page rather than leaving all subframes
    -- hidden behind our selected custom tab.
    local inspect=getglobal("InspectFrame")
    if inspect then
      -- Never manually execute another frame's OnClick script in 1.12.
      -- The global `this` would still be nativeOpenDriver, which can corrupt
      -- assumptions inside Blizzard/custom UI tab handlers.
      if HideUIPanel then HideUIPanel(inspect) else inspect:Hide() end
    end
  end
end

local function startNativeOpenDriver()
  pendingNativeElapsed=0
  if not nativeOpenDriver:GetScript("OnUpdate") then
    nativeOpenDriver:SetScript("OnUpdate",TalentInspect_NativeOpenUpdate)
  end
end

local function inspectTarget()
  local name=(UnitExists("target") and UnitIsPlayer("target")) and UnitName("target") or nil
  if not name then
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99TalentInspect:|r target another player to inspect talents.")
    return nil
  end

  -- SLASHSAFE1/public-entry safety: never directly enter legacy InspectFrame
  -- from slash/macro/public helper callbacks. Route through the same one-shot
  -- deferred queue used by the UnitPopup path.
  if TI.QueueSafeOpen then
    return TI.QueueSafeOpen(name)
  end

  return nil
end

local eventFrame=CreateFrame("Frame")
eventFrame:RegisterEvent("CHAT_MSG_ADDON")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
eventFrame:RegisterEvent("GUILD_ROSTER_UPDATE")
eventFrame:SetScript("OnEvent", function()
  if event=="PLAYER_LOGIN" then
    math.randomseed(time())
    if type(TalentInspectDB.cache)~="table" then TalentInspectDB.cache={} end
    migrateCacheSchema4()
    refreshGuildRosterNames()
    installNativeTabs()
    return
  end
  if event=="GUILD_ROSTER_UPDATE" then
    refreshGuildRosterNames()
    return
  end
  if event=="ADDON_LOADED" then
    local loaded=arg1
    if loaded=="TalentInspect" or loaded=="Blizzard_InspectUI" then
      installNativeTabs()
    end
    return
  end
  if event=="PLAYER_TARGET_CHANGED" then
    if TI.CancelPopupOpen then TI.CancelPopupOpen() end
    if TI.CancelNativeTabEmbed then TI.CancelNativeTabEmbed() end

    -- TARGETSAFE1:
    -- A target change is now an ownership boundary, NEVER an implicit request
    -- to inspect the new player. Right-clicking another nameplate can itself
    -- fire PLAYER_TARGET_CHANGED before the popup Talents item is clicked.
    -- The old auto-open behavior could therefore race:
    --
    --   target changes A -> B
    --   PLAYER_TARGET_CHANGED auto-opens B
    --   popup Talents queues another B open
    --   cached/provisional/sync render paths all touch the same reusable frame
    --
    -- Under rapid Hunter/Mage/Shaman stress switching this visibly looked like
    -- class backgrounds fighting each other.
    --
    -- Close/reset the old inspect ownership here. The NEW player is opened only
    -- by an explicit Talents click (or explicit /ti command).
    if TI.embeddedPrefix=="InspectFrame" and f:IsShown() then
      closeInvalidInspectTarget()
    end
    return
  end

  if event~="CHAT_MSG_ADDON" or arg1~=TI.PREFIX then return end
  if not settingEnabled("sync") then return end
  local msg, channel, sender=arg2,arg3,arg4
  local a=split(msg,"^")
  local cmd=a[1]
  local me=UnitName("player")

  if cmd=="DREQ" then
    local wanted=unsafe(a[2])
    local requester=unsafe(a[3])
    local page=tonumber(a[4])
    local index=tonumber(a[5])
    if wanted==me and requester and page and index then
      sendDescriptionTo(requester,page,index,channel)
    end
    return
  end

  if cmd=="DESC" then
    -- Legacy direct-description transport is retired; allocate nothing.
    return
  end

  if cmd=="REQ" then
    local wanted=unsafe(a[2])
    local requester=unsafe(a[3])
    TI.syncDiag=TI.syncDiag or {}
    TI.syncDiag.lastReqSeen=wanted
    TI.syncDiag.lastReqSender=sender
    TI.syncDiag.lastReqChannel=channel
    if wanted==me and requester and requester~="" then
      local now=nowSeconds()
      local last=TI.lastServedRequest[requester] or -100
      if (now-last)>=1.0 then
        TI.lastServedRequest[requester]=now
        sendLocalTo(requester,channel)
      end
    end
    return
  end

  -- All response packets are addressed to the requesting player.
  local recipient=unsafe(a[2])
  if recipient~=me then return end

  if cmd=="LADV" then
    local classToken=unsafe(a[3]); local remoteFP=unsafe(a[4])
    if TalentInspectData_NormalizeClass then classToken=TalentInspectData_NormalizeClass(classToken) end
    local localFP=TalentInspectHelper and TalentInspectHelper:GetFingerprint(classToken) or "0"
    if remoteFP and remoteFP~=localFP then
      -- FR4g: reply on the SAME channel that successfully delivered LADV.
      -- transportFor(sender) is invalid for guild-only inspection because it
      -- required the remote Paladin to also be targeting the Hunter.
      if channel then
        queueSend("LREQ^"..safe(sender).."^"..safe(classToken).."^"..safe(localFP),channel)
      end
    end
    return
  elseif cmd=="LREQ" then
    local classToken=unsafe(a[3]); local receiverFP=unsafe(a[4])
    if TalentInspectData_NormalizeClass then classToken=TalentInspectData_NormalizeClass(classToken) end
    -- Same rule: LREQ already arrived over a valid PARTY/RAID/GUILD channel.
    -- Never rediscover transport from target state.
    if channel then
      local now=nowSeconds()
      local key=tostring(sender or "")..":"..tostring(classToken or "")
      local last=TI.lastServedLearnRequest[key] or -100
      if (now-last)>=1.0 then
        TI.lastServedLearnRequest[key]=now
        sendLearnedClass(sender,channel,classToken,receiverFP)
      end
    end
    return
  elseif cmd=="LBEGIN" then
    pruneTransientSyncState()
    local classToken=unsafe(a[3]); local fp=unsafe(a[4])
    if TalentInspectData_NormalizeClass then classToken=TalentInspectData_NormalizeClass(classToken) end
    if TalentInspectHelper and TalentInspectHelper:BeginPeerClass(classToken) then
      TI.learnPending[classToken]={sender=sender,fingerprint=fp,count=0,startedAt=nowSeconds()}
      TI.lastLearnSync[classToken]={state="receiving",sender=sender,fingerprint=fp,count=0}
    end
    return
  elseif cmd=="LTAL" then
    local classToken=unsafe(a[3]); local treeIndex=tonumber(a[4])
    if TalentInspectData_NormalizeClass then classToken=TalentInspectData_NormalizeClass(classToken) end
    local p=TI.learnPending[classToken]
    if p and p.sender==sender and treeIndex and TalentInspectHelper then
      -- LTAL payload contains no ^ because SerializeLearnedTalent escapes it.
      if TalentInspectHelper:AcceptPeerTalent(classToken,treeIndex,a[5] or "") then
        p.count=p.count+1
        if TI.lastLearnSync[classToken] then TI.lastLearnSync[classToken].count=p.count end
      end
    end
    return
  elseif cmd=="LDES" then
    local classToken=unsafe(a[3]); local treeIndex=tonumber(a[4])
    local index=tonumber(a[5]); local part=tonumber(a[6]); local total=tonumber(a[7])
    if TalentInspectData_NormalizeClass then classToken=TalentInspectData_NormalizeClass(classToken) end
    local pending=TI.learnPending[classToken]
    if not pending or pending.sender~=sender or not treeIndex or not index or not part or not total then return end
    if total<1 or total>50 or part<1 or part>total then return end

    local key=classToken..":"..treeIndex..":"..index
    local d=TI.learnDescParts[key]
    if not d then d={total=total,parts={},startedAt=nowSeconds()}; TI.learnDescParts[key]=d end
    if d.total~=total then TI.learnDescParts[key]=nil; return end
    d.parts[part]=a[8] or ""

    local ready=1
    for n=1,total do if not d.parts[n] then ready=nil break end end
    if ready then
      local encoded=""
      for n=1,total do encoded=encoded..d.parts[n] end
      TI.learnDescParts[key]=nil
      if TalentInspectHelper then
        TalentInspectHelper:ApplyPeerDescription(classToken,treeIndex,index,encoded)
      end
    end
    return

  elseif cmd=="LEND" then
    local classToken=unsafe(a[3]); local fp=unsafe(a[4])
    if TalentInspectData_NormalizeClass then classToken=TalentInspectData_NormalizeClass(classToken) end
    local p=TI.learnPending[classToken]
    if p and p.sender==sender and TalentInspectHelper then
      local ok=TalentInspectHelper:FinalizePeerClass(classToken,fp or p.fingerprint)
      TI.lastLearnSync[classToken]={
        state=ok and "verified" or "fingerprint-failed",
        sender=sender,
        fingerprint=fp or p.fingerprint,
        count=p.count or 0
      }
    end
    TI.learnPending[classToken]=nil
    return
  end

  if cmd=="BEGIN" then
    pruneTransientSyncState()
    TI.syncDiag=TI.syncDiag or {}
    TI.syncDiag.lastBeginSender=sender
    TI.syncDiag.lastBeginChannel=channel
    local s=a[3]
    local incomingName=unsafe(a[4])
    local incomingClass=unsafe(a[5])
    if TalentInspectData_NormalizeClass then
      incomingClass=TalentInspectData_NormalizeClass(incomingClass)
    end

    local expectedClass=TI.syncExpectedClass or currentTargetClassToken()
    if not s or incomingName~=TI.syncExpectedName or sender~=incomingName or
       not classesAgree(incomingClass,expectedClass) then
      if s then TI.pending[s]=nil end
      return
    end

    if incomingName and incomingName==TI.currentName then
      markSyncBegin(incomingName)
      stopFallbackTimer()
      hideNoSyncMessages()
    elseif incomingName and incomingName==TI.fallbackName then
      markSyncBegin(incomingName)
      stopFallbackTimer()
      hideNoSyncMessages()
    end
    TI.pending[s]={name=incomingName,class=incomingClass,level=tonumber(a[6]) or 0,tabs={},sender=sender,
      startedAt=nowSeconds(),renderGeneration=TI.renderGeneration}
  elseif cmd=="TAB" then
    local d=TI.pending[a[3]]; if not d or d.sender~=sender then return end
    local p=tonumber(a[4]); if not p or p<1 or p>3 then return end
    local remoteFileName=unsafe(a[8])
    d.tabs[p]={
      name=unsafe(a[5]),
      icon=unsafe(a[6]),
      points=tonumber(a[7]) or 0,
      fileName=canonicalTreeBackground(d.class,p) or remoteFileName,
      talents={}
    }
  elseif cmd=="TAL" then
    local d=TI.pending[a[3]]; if not d or d.sender~=sender then return end
    local p=tonumber(a[4]); local i=tonumber(a[5])
    if not p or p<1 or p>3 or not i or i<1 or i>80 or not d.tabs[p] then return end
    d.tabs[p].talents[i]={index=i,name=unsafe(a[6]),icon=unsafe(a[7]),tier=tonumber(a[8]) or 1,col=tonumber(a[9]) or 1,
      rank=tonumber(a[10]) or 0,maxRank=tonumber(a[11]) or 1}
  elseif cmd=="END" then
    local d=TI.pending[a[3]]; if not d or d.sender~=sender then return end
    TI.pending[a[3]]=nil

    if d.name==TI.syncExpectedName and
       not classesAgree(d.class,TI.syncExpectedClass or currentTargetClassToken()) then
      return
    end

    for p=1,3 do
      if d.tabs[p] then
        d.tabs[p].fileName=canonicalTreeBackground(d.class,p) or d.tabs[p].fileName
      end
    end

    local old=getCachedBuild(d.name)
    if old and old.tabs then
      for p=1,3 do
        if d.tabs[p] and old.tabs[p] and old.tabs[p].talents then
          for idx,t in pairs(d.tabs[p].talents or {}) do
            local ot=old.tabs[p].talents[idx]
            if ot and ot.description then t.description=ot.description end
          end
        end
      end
    end
    markSyncComplete(d.name)
    TI.requestGuardName=d.name
    TI.requestLoadedName=d.name
    TI.requestCooldownUntil=nil
    cacheData(d)

    -- Preserve the inspected player's view independently of local CharacterFrame.
    local rhs=TI.hostState.InspectFrame
    rhs.name=d.name
    rhs.data=d

    local best=1
    local bestPoints=-1
    for p=1,3 do
      local pts=(d.tabs[p] and d.tabs[p].points) or 0
      if pts>bestPoints then best=p; bestPoints=pts end
    end
    if not rhs.selectedTab then rhs.selectedTab=best end

    -- FR1c ownership guard: a late packet from Player A must never replace
    -- Player B after the InspectFrame target has changed.
    if TI.embeddedPrefix=="InspectFrame" and
       TI.currentName==d.name and TI.renderOwner==d.name and
       d.renderGeneration==TI.renderGeneration and sender==d.name then
      TI.selectedTab=rhs.selectedTab or best
      showData(d,"Synced")
      showSyncSuccessStatus()
    end
  end
end)

-- Slash commands -------------------------------------------------------------
local function tiOnOff(v) return v and "|cff33ff66ON|r" or "|cffff5555OFF|r" end

local function clearLearnedTalentData()
  TalentInspectDB.learned={}
  TalentInspectDB.learnedSchema=4
  TalentInspectData_Learned={}
  if TalentInspectHelper and TalentInspectHelper.RestoreLearned then
    TalentInspectHelper:RestoreLearned()
  end
end

local function printSettingsStatus()
  DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99TalentInspect v"..TI.VERSION.." settings|r")
  DEFAULT_CHAT_FRAME:AddMessage(" Sync: "..tiOnOff(settingEnabled("sync")).."  Tooltips: "..tiOnOff(settingEnabled("tooltips")))
  DEFAULT_CHAT_FRAME:AddMessage(" Cache: "..tiOnOff(settingEnabled("cache")).."  Links: "..tiOnOff(settingEnabled("links")))
end

local function refreshCurrentTalentView()
  if TI.currentData and f:IsShown() then
    local status=nil
    if f.status and f.status.GetText then status=f.status:GetText() end
    showData(TI.currentData,status)
  end
end

-- RESETUI1: one small centered reset/data-management panel.  No drag state,
-- no dependence on Blizzard popup templates, and destructive actions always
-- require an explicit second click.
local resetFrame=nil
local resetConfirmMode=nil

local function makeResetButton(parent,text,w,h)
  local b=CreateFrame("Button",nil,parent)
  b:SetWidth(w or 74)
  b:SetHeight(h or 22)
  b:SetBackdrop({bgFile="Interface\\Tooltips\\UI-Tooltip-Background",edgeFile="Interface\\Tooltips\\UI-Tooltip-Border",tile=true,tileSize=16,edgeSize=10,insets={left=2,right=2,top=2,bottom=2}})
  b:SetBackdropColor(0.10,0.10,0.10,0.96)
  b:SetBackdropBorderColor(0.55,0.55,0.55,1)
  local fs=b:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
  fs:SetPoint("CENTER",b,"CENTER",0,0)
  fs:SetText(text)
  b.text=fs
  b:SetScript("OnEnter",function() this:SetBackdropBorderColor(1,0.82,0,1) end)
  b:SetScript("OnLeave",function() this:SetBackdropBorderColor(0.55,0.55,0.55,1) end)
  return b
end

local function resetFrameShowMain()
  if not resetFrame then return end
  resetConfirmMode=nil
  resetFrame.confirmText:Hide()
  resetFrame.deleteButton:Hide()
  resetFrame.cancelButton:Hide()
  resetFrame.helpText:Show()
  resetFrame.defaultsButton:Show()
  resetFrame.playerButton:Show()
  resetFrame.learnedButton:Show()
  resetFrame.allButton:Show()
end

local function resetFrameAsk(mode)
  if not resetFrame then return end
  resetConfirmMode=mode
  resetFrame.helpText:Hide()
  resetFrame.defaultsButton:Hide()
  resetFrame.playerButton:Hide()
  resetFrame.learnedButton:Hide()
  resetFrame.allButton:Hide()
  local label=""
  if mode=="player" then label="Player"
  elseif mode=="learned" then label="Learned"
  else label="All" end
  resetFrame.confirmText:SetText("Are you sure you want to delete "..label.." data?")
  resetFrame.confirmText:Show()
  resetFrame.deleteButton:Show()
  resetFrame.cancelButton:Show()
end

local function performResetDelete()
  if resetConfirmMode=="player" then
    clearTalentCache()
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99TalentInspect:|r cached player talent builds cleared.")
  elseif resetConfirmMode=="learned" then
    clearLearnedTalentData()
    refreshCurrentTalentView()
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99TalentInspect:|r learned talent/prerequisite data cleared. Packaged data remains available.")
  elseif resetConfirmMode=="all" then
    clearTalentCache()
    clearLearnedTalentData()
    refreshCurrentTalentView()
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99TalentInspect:|r all saved player and learned talent data cleared. Settings were kept.")
  end
  resetFrameShowMain()
end

local function ensureResetFrame()
  if resetFrame then return resetFrame end

  local r=CreateFrame("Frame","TalentInspectResetFrame",UIParent)
  r:SetWidth(310)
  r:SetHeight(154)
  r:SetPoint("CENTER",UIParent,"CENTER",0,30)
  r:SetFrameStrata("DIALOG")
  r:SetToplevel(true)
  r:EnableMouse(true)
  r:SetMovable(false)
  r:SetClampedToScreen(true)
  r:SetBackdrop({bgFile="Interface\\DialogFrame\\UI-DialogBox-Background",edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border",tile=true,tileSize=32,edgeSize=24,insets={left=7,right=7,top=7,bottom=7}})
  r:Hide()

  local title=r:CreateFontString(nil,"OVERLAY","GameFontNormal")
  title:SetPoint("TOP",r,"TOP",0,-16)
  title:SetText("TalentInspect Reset")
  r.title=title

  local close=CreateFrame("Button",nil,r)
  close:SetWidth(18)
  close:SetHeight(18)
  close:SetPoint("TOPRIGHT",r,"TOPRIGHT",-9,-9)
  local cfs=close:CreateFontString(nil,"OVERLAY","GameFontNormal")
  cfs:SetPoint("CENTER",close,"CENTER",0,0)
  cfs:SetText("|cffff5555X|r")
  close:SetScript("OnClick",function() resetConfirmMode=nil; r:Hide() end)
  r.closeButton=close

  local help=r:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
  help:SetPoint("TOP",title,"BOTTOM",0,-10)
  help:SetText("Reset settings or clear saved data")
  r.helpText=help

  local defaults=makeResetButton(r,"Defaults",82,22)
  defaults:SetPoint("TOP",help,"BOTTOM",0,-9)
  defaults:SetScript("OnClick",function()
    TalentInspectDB.settings={}
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99TalentInspect:|r settings restored to defaults (all optional features ON).")
  end)
  r.defaultsButton=defaults

  local player=makeResetButton(r,"Player",74,22)
  player:SetPoint("BOTTOMLEFT",r,"BOTTOMLEFT",30,18)
  player:SetScript("OnClick",function() resetFrameAsk("player") end)
  r.playerButton=player

  local learned=makeResetButton(r,"Learned",74,22)
  learned:SetPoint("LEFT",player,"RIGHT",14,0)
  learned:SetScript("OnClick",function() resetFrameAsk("learned") end)
  r.learnedButton=learned

  local all=makeResetButton(r,"All",74,22)
  all:SetPoint("LEFT",learned,"RIGHT",14,0)
  all:SetScript("OnClick",function() resetFrameAsk("all") end)
  r.allButton=all

  local confirm=r:CreateFontString(nil,"OVERLAY","GameFontHighlight")
  confirm:SetWidth(255)
  confirm:SetPoint("CENTER",r,"CENTER",0,13)
  confirm:SetJustifyH("CENTER")
  confirm:SetText("")
  confirm:Hide()
  r.confirmText=confirm

  local del=makeResetButton(r,"Delete",82,24)
  del:SetPoint("BOTTOM",r,"BOTTOM",-48,21)
  del:SetScript("OnClick",performResetDelete)
  del:Hide()
  r.deleteButton=del

  local cancel=makeResetButton(r,"Cancel",82,24)
  cancel:SetPoint("LEFT",del,"RIGHT",14,0)
  cancel:SetScript("OnClick",resetFrameShowMain)
  cancel:Hide()
  r.cancelButton=cancel

  r:SetScript("OnShow",resetFrameShowMain)
  resetFrame=r
  return r
end

local function showResetFrame()
  local r=ensureResetFrame()
  r:ClearAllPoints()
  r:SetPoint("CENTER",UIParent,"CENTER",0,30)
  resetFrameShowMain()
  r:Show()
end

local function handleToggle(key,label,arg)
  if arg~="on" and arg~="off" then
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99TalentInspect:|r /ti "..label.." on|off  (currently "..(settingEnabled(key) and "ON" or "OFF")..")")
    return
  end
  local enabled=(arg=="on")
  setSetting(key,enabled)
  DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99TalentInspect:|r "..label.." "..(enabled and "enabled." or "disabled."))
end

SLASH_TALENTINSPECT1="/ti"
SLASH_TALENTINSPECT2="/talentinspect"
SlashCmdList["TALENTINSPECT"]=function(msg)
  msg=string.lower(msg or "")
  msg=string.gsub(msg,"^%s+","")
  msg=string.gsub(msg,"%s+$","")
  local _,_,cmd,arg=string.find(msg,"^(%S+)%s*(.-)$")
  cmd=cmd or ""

  if cmd=="" then inspectTarget(); return end

  if cmd=="refresh" then
    if not UnitExists("target") or not UnitIsPlayer("target") then
      DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99TalentInspect:|r refresh skipped: target a nearby inspectable player.")
      return
    end
    local targetName=UnitName("target")
    if not targetName or targetName=="" then
      DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99TalentInspect:|r refresh skipped: no valid target.")
      return
    end
    if TI.QueueSafeOpen then TI.QueueSafeOpen(targetName,1) end
    return
  end

  if cmd=="players" then
    local n=0
    for _ in pairs(TalentInspectDB.cache or {}) do n=n+1 end
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99TalentInspect:|r "..n.." cached player talent build(s).")
    return
  end

  if cmd=="sync" then handleToggle("sync","sync",arg); return end
  if cmd=="tooltips" then handleToggle("tooltips","tooltips",arg); return end
  if cmd=="cache" then handleToggle("cache","cache",arg); return end
  if cmd=="links" then handleToggle("links","links",arg); return end

  if cmd=="status" then printSettingsStatus(); return end

  if cmd=="dbinfo" then
    local classes=0
    for _ in pairs(TalentInspectDB.learned or {}) do classes=classes+1 end
    local players=0
    for _ in pairs(TalentInspectDB.cache or {}) do players=players+1 end
    local from=TalentInspectDB.migratedFrom and (" • migrated DB"..tostring(TalentInspectDB.migratedFrom)) or ""
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99TalentInspect:|r DB4"..from.." • learned classes "..classes.."/9 • cached players "..players.."/200")
    return
  end


  if cmd=="reset" then showResetFrame(); return end

  -- Retired data-clear/default commands are kept as safe compatibility aliases:
  -- they now open the single reset panel instead of deleting immediately.
  if cmd=="defaultsettings" or cmd=="clearplayers" or cmd=="clearlearnedtalents" or cmd=="clearalldata" or cmd=="clearcache" then
    showResetFrame()
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99TalentInspect:|r data/settings reset controls moved to |cffffffff/ti reset|r.")
    return
  end

  if cmd=="help" then
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99TalentInspect v"..TI.VERSION.."|r")
    DEFAULT_CHAT_FRAME:AddMessage(" /ti  /ti refresh  /ti status  /ti dbinfo  /ti players  /ti reset")
    DEFAULT_CHAT_FRAME:AddMessage(" /ti sync on|off  /ti tooltips on|off")
    DEFAULT_CHAT_FRAME:AddMessage(" /ti cache on|off  /ti links on|off")
    return
  end

  DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99TalentInspect:|r unknown or retired command. Use /ti help.")
end


-- OPENSAFE1: deferred one-shot UnitPopup open --------------------------------
local popupOpenDriver=CreateFrame("Frame")
local popupOpenPending=nil
local popupOpenElapsed=0
local popupOpenBusy=nil

local function cancelPopupOpen()
  popupOpenPending=nil
  popupOpenElapsed=0
  popupOpenBusy=nil
  popupOpenDriver:SetScript("OnUpdate",nil)
  popupOpenDriver:Hide()
end
TI.CancelPopupOpen=cancelPopupOpen

local function queuePopupOpen(name,forceRefresh)
  if not name or name=="" then return nil end
  if popupOpenPending or popupOpenBusy then return nil end

  popupOpenPending={name=name,forceRefresh=forceRefresh and 1 or nil}
  popupOpenElapsed=0
  popupOpenDriver:Show()
  popupOpenDriver:SetScript("OnUpdate",function()
    popupOpenElapsed=popupOpenElapsed+(arg1 or 0)
    if popupOpenElapsed<0.05 then return end

    -- One-shot: detach BEFORE any talent/InspectFrame work.
    this:SetScript("OnUpdate",nil)
    this:Hide()

    local pending=popupOpenPending
    popupOpenPending=nil
    popupOpenElapsed=0
    popupOpenBusy=1

    if pending and UnitExists("target") and UnitIsPlayer("target") and
       UnitName("target")==pending.name then

      if pending.name==UnitName("player") then
        -- Self view is also deferred so slash/public callbacks remain trivial.
        openSelfTalents()
      elseif targetCanBeInspectedSafely and targetCanBeInspectedSafely() then
        -- Refresh no longer resets UI synchronously. request() already sends a
        -- fresh sync request even when a valid cache exists, so the same safe
        -- open transaction is sufficient.
        openTargetTalents()
      end
    end

    popupOpenBusy=nil
  end)
  return 1
end

-- Runtime indirection lets slash/public helpers defined earlier in the file
-- use the exact same safe queue after addon initialization completes.
TI.QueueSafeOpen=queuePopupOpen

-- DEEPHARDEN1: deferred one-shot native Inspect Talents-tab embed.
local nativeTabEmbedDriver=CreateFrame("Frame")
local nativeTabEmbedPending=nil
local nativeTabEmbedElapsed=0

local function cancelNativeTabEmbed()
  nativeTabEmbedPending=nil
  nativeTabEmbedElapsed=0
  nativeTabEmbedDriver:SetScript("OnUpdate",nil)
  nativeTabEmbedDriver:Hide()
end

local function queueSafeEmbed(host,prefix,name)
  if not host or prefix~="InspectFrame" or not name or name=="" then return nil end
  if nativeTabEmbedPending then return nil end

  nativeTabEmbedPending={host=host,prefix=prefix,name=name}
  nativeTabEmbedElapsed=0
  nativeTabEmbedDriver:Show()
  nativeTabEmbedDriver:SetScript("OnUpdate",function()
    nativeTabEmbedElapsed=nativeTabEmbedElapsed+(arg1 or 0)
    if nativeTabEmbedElapsed<0.05 then return end

    this:SetScript("OnUpdate",nil)
    this:Hide()

    local p=nativeTabEmbedPending
    nativeTabEmbedPending=nil
    nativeTabEmbedElapsed=0

    if not p or not p.host or not p.host:IsShown() then return end
    if not UnitExists("target") or not UnitIsPlayer("target") then return end
    if UnitName("target")~=p.name then return end
    if not targetCanBeInspectedSafely or not targetCanBeInspectedSafely() then return end

    showEmbeddedTalents(p.host,p.prefix)
  end)
  return 1
end

TI.QueueSafeEmbed=queueSafeEmbed
TI.CancelNativeTabEmbed=cancelNativeTabEmbed

-- Blizzard player right-click menu ------------------------------------------
local POP="VPTI_INSPECT_TALENTS"
if UnitPopupButtons and UnitPopupMenus then
  -- HF3: Vanilla 1.12 UnitPopup expects every button to have a numeric dist.
  -- Leaving it nil makes UnitPopup_OnUpdate compare a number against nil
  -- (seen on GUILD/FRIEND roster popups). A positive dist is also unsafe there
  -- because those menus may have no valid unit token and FrameXML then calls
  -- CheckInteractDistance(nil, distIndex). dist=0 is the safe native sentinel:
  -- no Blizzard range query; TalentInspect performs its own guarded range check
  -- only when the Talents action is actually clicked.
  UnitPopupButtons[POP]={text="Talents",dist=0}
  local menus={"PLAYER","PARTY","RAID_PLAYER","FRIEND","GUILD","TARGET"}
  for _,m in ipairs(menus) do
    if UnitPopupMenus[m] then
      local found=nil
      for _,v in ipairs(UnitPopupMenus[m]) do if v==POP then found=1 end end
      if not found then table.insert(UnitPopupMenus[m],POP) end
    end
  end
  -- HF4: UIDROPDOWNMENU_INIT_MENU is NOT always a unit token. On the vanilla
  -- Friends/Guild roster it can literally be the global frame name
  -- "FriendsDropDown"/"GuildFrameDropDown". Passing those strings to
  -- UnitExists() throws "Unknown unit name" on this client. Resolve frame
  -- names first and call UnitExists only on known-safe unit-token shapes.
  local function isSafeUnitToken(unit)
    if type(unit)~="string" then return nil end
    if unit=="player" or unit=="target" or unit=="pet" or unit=="mouseover" then return 1 end
    if string.find(unit,"^party%d+$") then return 1 end
    if string.find(unit,"^raid%d+$") then return 1 end
    if string.find(unit,"^party%d+pet$") then return 1 end
    if string.find(unit,"^raid%d+pet$") then return 1 end
    return nil
  end

  local function popupDropdownObject()
    local dropdown=UIDROPDOWNMENU_INIT_MENU
    if type(dropdown)=="table" then return dropdown end
    if type(dropdown)=="string" and getglobal then
      local obj=getglobal(dropdown)
      if type(obj)=="table" then return obj end
    end
    return nil
  end

  local function resolvePopupPlayerName()
    local dropdown=UIDROPDOWNMENU_INIT_MENU
    local obj=popupDropdownObject()

    if obj then
      if obj.name and obj.name~="" then return obj.name end
      if isSafeUnitToken(obj.unit) and UnitExists(obj.unit) then
        return UnitName(obj.unit)
      end
    elseif isSafeUnitToken(dropdown) and UnitExists(dropdown) then
      return UnitName(dropdown)
    end

    -- If the popup itself does not expose a roster name, use target only when
    -- it is a real player. Never reinterpret a dropdown-frame name as a unit.
    if UnitExists("target") and UnitIsPlayer("target") then
      return UnitName("target")
    end

    return UnitName("player")
  end

  local function resolvePopupUnit()
    local dropdown=UIDROPDOWNMENU_INIT_MENU
    local obj=popupDropdownObject()

    if obj then
      if isSafeUnitToken(obj.unit) and UnitExists(obj.unit) and UnitIsPlayer(obj.unit) then
        return obj.unit
      end
      if obj.name and UnitExists("target") and UnitIsPlayer("target") and
         UnitName("target")==obj.name then
        return "target"
      end
    elseif isSafeUnitToken(dropdown) and UnitExists(dropdown) and UnitIsPlayer(dropdown) then
      return dropdown
    end

    local name=resolvePopupPlayerName()
    if name and UnitExists("target") and UnitIsPlayer("target") and UnitName("target")==name then
      return "target"
    end
    return nil
  end

  local function popupTalentInRange()
    local unit=resolvePopupUnit()
    if not unit or not CheckInteractDistance then return nil end
    return CheckInteractDistance(unit,3) and 1 or nil
  end

  if UnitPopup_OnClick then
    local oldUnitPopup_OnClick=UnitPopup_OnClick
    UnitPopup_OnClick=function()
      if this and this.value==POP then
        local name=resolvePopupPlayerName()

        -- HF3: native popup distance is deliberately dist=0 for roster safety.
        -- Enforce TalentInspect's real interaction-range rule here instead.
        if name==UnitName("player") or not popupTalentInRange() then
          CloseDropDownMenus()
          return
        end

        -- OPENSAFE1: no legacy InspectFrame work inside UnitPopup_OnClick.
        -- Queue one target, close menu, return immediately.
        queuePopupOpen(name)
        CloseDropDownMenus()
        return
      end
      oldUnitPopup_OnClick()
    end
  end
end

-- Public helpers for testing/macros.
TalentInspect = TI
TalentInspect.InspectTarget = inspectTarget
TalentInspect.Request = request
TalentInspect.ShowSelf = openSelfTalents
TalentInspect.InstallNativeTabs = installNativeTabs
TalentInspect.OpenSelfTalents = openSelfTalents

-- SLASHSAFE1: public target-open helper is safe/deferred too. Keep the raw
-- legacy open transaction private to this file.
TalentInspect.OpenTargetTalents = inspectTarget
