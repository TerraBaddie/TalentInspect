-- TalentInspect v1.0.0 FR4a - WoW 1.12.1 / VanillaPlus
-- Request-driven talent sync with Blizzard-style one-tree-per-page UI.

TalentInspectDB = TalentInspectDB or {}
TalentInspectDB.cache = TalentInspectDB.cache or {}
TalentInspectDB.cacheSchema = TalentInspectDB.cacheSchema or 1

local TI = {}
TI.VERSION = "1.0.3-GUARD2"
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

  local d={name=name,class=classToken,level=level or 0,tabs={}}
  local bgNames=VPLUS_TREE_BACKGROUNDS[classToken or ""]

  for p=1,3 do
    local tree=nil
    local learnedClass=TalentInspectData_GetLearnedClass and TalentInspectData_GetLearnedClass(classToken)
    if learnedClass and learnedClass.trees then tree=learnedClass.trees[p] end
    if not tree then tree=TalentInspectData_GetTree and TalentInspectData_GetTree(classToken,p) end
    if tree then
      local tab={
        name=tree.name or ("Tree "..p),
        icon=tree.icon and ("Interface\\Icons\\"..tree.icon) or "",
        points=0,
        fileName=(bgNames and bgNames[p]) or tree.background or "",
        talents={}
      }

      -- First pass: create every talent at rank zero using real in-game icon paths.
      for idx,st in pairs(tree.talents or {}) do
        local tier=st.tier
        local col=st.col
        if (not tier or not col) and st.pos then
          local letter=string.sub(st.pos,1,1)
          tier=string.byte(letter)-96
          col=tonumber(string.sub(st.pos,2)) or 1
        end

        local icon=st.icon or ""
        if icon~="" and not string.find(icon,"\\",1,true) then
          icon="Interface\\Icons\\"..icon
        end

        tab.talents[idx]={
          index=idx,
          name=st.name or st.sourceName or ("Talent "..idx),
          icon=icon,
          tier=tier or 1,
          col=col or 1,
          rank=0,
          maxRank=st.maxRank or 1,
          preTier=(st.prereqScanned==1 and st.preTier) or 0,
          preCol=(st.prereqScanned==1 and st.preCol) or 0,
          preRank=(st.prereqScanned==1 and st.preRank) or nil,
          prereqScanned=st.prereqScanned
        }
      end

      -- Second pass: restore prerequisite geometry so the empty tree still
      -- looks like the real tree, including its dependency arrows.
      for idx,st in pairs(tree.talents or {}) do
        if st.prereq and tab.talents[idx] and tab.talents[idx].prereqScanned~=1 then
          for _,pre in pairs(tab.talents) do
            if pre.name==st.prereq then
              tab.talents[idx].preTier=pre.tier or 0
              tab.talents[idx].preCol=pre.col or 0
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

local function usingPfUI()
  return pfUI and pfUI.api
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
TI.outboxElapsed = 0

local syncPump=CreateFrame("Frame")

local function sendNow(msg, channel)
  if SendAddonMessage and msg and channel then
    SendAddonMessage(TI.PREFIX,msg,channel)
  end
end

local function TalentInspect_SyncPumpUpdate()
  if not TI.outbox or table.getn(TI.outbox)==0 then
    this:SetScript("OnUpdate",nil)
    TI.outboxElapsed=0
    return
  end
  TI.outboxElapsed=TI.outboxElapsed+(arg1 or 0)
  if TI.outboxElapsed<0.06 then return end
  TI.outboxElapsed=0
  local item=table.remove(TI.outbox,1)
  if item then sendNow(item.msg,item.channel) end
  if table.getn(TI.outbox)==0 then
    this:SetScript("OnUpdate",nil)
  end
end

local function queueSend(msg, channel)
  if not msg or not channel then return end
  table.insert(TI.outbox,{msg=msg,channel=channel})
  if not syncPump:GetScript("OnUpdate") then
    syncPump:SetScript("OnUpdate",TalentInspect_SyncPumpUpdate)
  end
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

  -- FR4h: a PLAYER_LOGIN scan can occur before VanillaPlus has finished
  -- exposing its final hotfixed talent tooltip text.  The first real peer
  -- sync is therefore a safe authoritative refresh point.  This is NOT
  -- continuous polling: it runs only when another TalentInspect client
  -- actually requests/receives learned-data advertisement.
  if TalentInspectHelper.ScanCurrentClass then
    TalentInspectHelper:ScanCurrentClass("peer-sync-authoritative-refresh",1)
  end

  local d=TalentInspectHelper:GetOwnLearnedClass()
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
  if d and d.name then
    d.stamp = time and time() or 0
    TalentInspectDB.cache[d.name] = d
  end
end

local function clearTalentCache()
  TalentInspectDB.cache = {}
  TalentInspectDB.cacheSchema = 1
  TI.pending = {}
  TI.currentData = nil
  if TI.hostState then
    for _,state in pairs(TI.hostState) do
      state.name=nil
      state.data=nil
      state.selectedTab=1
    end
  end
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
  TI.embeddedHost = host
  f:SetParent(host)
  f:SetMovable(0)
  -- The large wrapper is visual/layout only. Do not let it intercept native
  -- Character/Pet/Reputation/Skills/Honor tab clicks underneath.
  f:EnableMouse(0)
  f:ClearAllPoints()

  -- Stay completely inside the original Character/Inspect frame.
  -- Native header and native Character/Honor/Talents tabs remain visible.
  f:SetPoint("TOPLEFT",host,"TOPLEFT",14,-42)
  f:SetPoint("BOTTOMRIGHT",host,"BOTTOMRIGHT",-14,39)
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
    if f.blizzHeader then f.blizzHeader:Show() end
    if f.blizzClose then
      f.blizzClose:SetFrameLevel(f:GetFrameLevel()+220)
      f.blizzClose:Show()
      if f.blizzClose.Raise then f.blizzClose:Raise() end
    end

    -- FR2-XML5: restore stock InspectFrame close-button position.
    -- XML4 moved the whole red button when only the X artwork looked off.
    local hostClose=getglobal("InspectFrameCloseButton")
    if hostClose and hostClose.Raise then hostClose:Raise() end
  end

  -- Compact header: selected tree centered; cache/sync state unobtrusive.
  f.treeTitle:ClearAllPoints()
  if usingPfUI() then
    f.treeTitle:SetPoint("TOP",f,"TOP",0,-2)
  else
    f.treeTitle:SetPoint("CENTER",f.blizzHeader,"CENTER",0,0)
  end

  f.status:ClearAllPoints()
  f.status:SetPoint("BOTTOMRIGHT",f,"BOTTOMRIGHT",-20,1)

  if f.noSyncLeft and f.noSyncRight then
    f.noSyncLeft:ClearAllPoints()
    f.noSyncRight:ClearAllPoints()
    if usingPfUI() then
      -- User mock-up: white status text on the open strip above the spec tabs.
      f.noSyncLeft:SetPoint("TOPLEFT",f,"TOPLEFT",-1,32)
      f.noSyncRight:SetPoint("TOPLEFT",f,"TOPLEFT",-1,-3)
    else
      -- Conservative Blizzard placement until a final Blizzard mock-up is supplied.
      f.noSyncLeft:SetPoint("TOPLEFT",f,"TOPLEFT",94,20)
      f.noSyncRight:SetPoint("BOTTOMLEFT",f,"BOTTOMLEFT",16 ,48)
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
            -- Blizzard mode: lift the upward-facing tree tabs into the spare
            -- header area above the artwork.
            b:SetPoint("BOTTOMLEFT",f.scroll,"TOPLEFT",34,32)
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

  -- Short fixed viewport. The full 7-row tree scrolls behind this window.
  if f.scroll then
    f.scroll:EnableMouse(1)
    f.scroll:EnableMouseWheel(1)
    f.scroll:ClearAllPoints()
    if usingPfUI() then
      f.scroll:SetPoint("TOPLEFT",f,"TOPLEFT",4,-48)
    else
      f.scroll:SetPoint("TOPLEFT",f,"TOPLEFT",4,-50)
    end
    f.scroll:SetWidth(TREE_VIEW_W)
    if usingPfUI() then
      f.scroll:SetHeight(TREE_VIEW_H)
    else
      f.scroll:SetHeight(TREE_VIEW_H-28)
    end
  end

  if f.treeBackgroundClip and f.scroll then
    f.treeBackgroundClip:ClearAllPoints()
    f.treeBackgroundClip:SetPoint("TOPLEFT",f.scroll,"TOPLEFT",0,0)
    f.treeBackgroundClip:SetWidth(TREE_VIEW_W)
    f.treeBackgroundClip:SetHeight(f.scroll:GetHeight())

    -- FR2-XML5 explicit layer stack.
    f.treeBackgroundClip:SetFrameLevel(f:GetFrameLevel()+10)
    if f.treeBackground then f.treeBackground:SetFrameLevel(f:GetFrameLevel()+9) end
    f.scroll:SetFrameLevel(f:GetFrameLevel()+30)
    if f.canvas then f.canvas:SetFrameLevel(f:GetFrameLevel()+31) end

    f.treeBackgroundClip:SetVerticalScroll(0)
    f.treeBackgroundClip:SetHorizontalScroll(0)
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
f.treeBackgroundClip:SetScrollChild(f.treeBackground)
f.treeBackground:EnableMouse(0)
f.treeBackgroundClip:EnableMouse(0)
f.blankPane:EnableMouse(0)
f.treeBackgroundClip:SetVerticalScroll(0)
f.treeBackgroundClip:SetHorizontalScroll(0)

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
  local halfThumb=10
  local endPad=2
  top=top-halfThumb-endPad
  bottom=bottom+halfThumb+endPad
  if top<=bottom then return end
  local minValue,maxValue=tiScrollBar:GetMinMaxValues()
  local pct=(top-cy)/(top-bottom)
  if pct<0 then pct=0 elseif pct>1 then pct=1 end
  tiScrollBar:SetValue(minValue+(maxValue-minValue)*pct)
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
  local range=(f.canvas:GetHeight() or TREE_CANVAS_H)-(f.scroll:GetHeight() or TREE_VIEW_H)
  if range<0 then range=0 end
  local value=tiScrollBar:GetValue() or 0
  if value<0 then value=0 end
  if value>range then value=range end
  tiScrollSyncing=1
  tiScrollBar:SetMinMaxValues(0,range)
  tiScrollBar:SetValueStep(WHEEL_STEP)
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
  f.scroll:SetVerticalScroll(value)
  if applyViewportClipping then applyViewportClipping() end
  if value<=minValue then tiScrollUp:Disable() else tiScrollUp:Enable() end
  if value>=maxValue then tiScrollDown:Disable() else tiScrollDown:Enable() end
end)

tiScrollUp:SetScript("OnClick",function()
  TalentInspect_UpdateScrollRange()
  local minValue,maxValue=tiScrollBar:GetMinMaxValues()
  local value=(tiScrollBar:GetValue() or 0)-20
  if value<minValue then value=minValue end
  tiScrollBar:SetValue(value)
  PlaySound("UChatScrollButton")
end)
tiScrollDown:SetScript("OnClick",function()
  TalentInspect_UpdateScrollRange()
  local minValue,maxValue=tiScrollBar:GetMinMaxValues()
  local value=(tiScrollBar:GetValue() or 0)+20
  if value>maxValue then value=maxValue end
  tiScrollBar:SetValue(value)
  PlaySound("UChatScrollButton")
end)

TalentInspect_MouseWheel = function(delta)
  TalentInspect_UpdateScrollRange()
  local minValue,maxValue=tiScrollBar:GetMinMaxValues()
  local value=tiScrollBar:GetValue() or 0
  delta=delta or 0
  value=value-(delta*WHEEL_STEP)
  if value<minValue then value=minValue end
  if value>maxValue then value=maxValue end
  tiScrollBar:SetValue(value)
  f.scroll:SetVerticalScroll(value)
  if applyViewportClipping then applyViewportClipping() end
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
  if f.treeBackgroundClip then f.treeBackgroundClip:Show() end
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
  for _,c in pairs(TI.connectors) do hideConnector(c) end
end

local requestTalentDescription
local renderRemoteTalentTooltip
local renderStaticTalentTooltip

local function makeTalentButton(i)
  local b=CreateFrame("Button","TalentInspectTalent"..i,f.canvas,"TalentInspectTalentButtonTemplate")
  b:SetFrameLevel(f.scroll:GetFrameLevel()+35)
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
    if renderStaticTalentTooltip then renderStaticTalentTooltip(this) end
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

local function connector(i)
  local c=TI.connectors[i]
  if not c then
    c={segments={},active={}}
    for n=1,3 do
      local t=f.canvas:CreateTexture(nil,"BORDER")
      t:SetTexture(1,0.82,0,0.78)
      c.segments[n]=t
      c.active[n]=nil
    end
    TI.connectors[i]=c
  end
  return c
end

hideConnector = function(c)
  if not c or not c.segments then return end
  for n,seg in pairs(c.segments) do
    seg:Hide()
    if c.active then c.active[n]=nil end
  end
  c.minDown=nil
  c.maxDown=nil
end

local function drawPrereq(talent, idx)
  -- FR4L: ALWAYS clear the reusable connector slot before deciding whether
  -- this talent currently has a prerequisite. Previously the early return
  -- below occurred first, leaving stale yellow arrows on no-prereq talents.
  local c=connector(idx)
  hideConnector(c)

  if not talent or not talent.preTier or talent.preTier==0 or
     not talent.preCol or talent.preCol==0 then
    return
  end

  -- FR3b: prerequisite RELATIONSHIPS stay data-driven, while geometry is
  -- derived from source/target row+column. Preserve the established pfUI
  -- appearance exactly: simple 3px sleek yellow connector segments.
  local sourceX=GRID_X0+(talent.preCol-1)*GRID_X
  local sourceDown=GRID_Y0+(talent.preTier-1)*GRID_Y
  local targetX=GRID_X0+(talent.col-1)*GRID_X
  local targetDown=GRID_Y0+(talent.tier-1)*GRID_Y

  local sourceCenterX=sourceX+22
  local targetCenterX=targetX+22
  local sourceCenterDown=sourceDown+22
  local targetCenterDown=targetDown+22
  local sourceBottom=sourceDown+44
  local targetTop=targetDown

  -- Same-row prerequisites exist in current V5 trees (left -> right or
  -- right -> left). The old renderer returned early here, so those links
  -- silently disappeared even though TalentData correctly described them.
  if talent.preTier==talent.tier and sourceCenterX~=targetCenterX then
    local h=c.segments[1]
    local leftX, width

    if sourceCenterX<targetCenterX then
      -- Source icon right edge -> target icon left edge.
      leftX=sourceX+44
      width=math.max(3,targetX-leftX)
    else
      -- Target icon right edge -> source icon left edge.
      leftX=targetX+44
      width=math.max(3,sourceX-leftX)
    end

    h:ClearAllPoints()
    h:SetWidth(width)
    h:SetHeight(3)
    h:SetPoint("TOPLEFT",f.canvas,"TOPLEFT",leftX,-(sourceCenterDown-1))
    c.active[1]=1
    h:Show()

    c.minDown=sourceDown
    c.maxDown=sourceDown+44
    return
  end

  -- A prerequisite below/at the dependent talent is invalid for our visual
  -- routing. Leave it hidden rather than inventing geometry.
  if targetTop<=sourceBottom then return end

  local gap=targetTop-sourceBottom

  if sourceCenterX==targetCenterX then
    -- Straight vertical link between icon edges.
    local v=c.segments[1]
    v:ClearAllPoints()
    v:SetWidth(3)
    v:SetHeight(gap)
    v:SetPoint("TOPLEFT",f.canvas,"TOPLEFT",sourceCenterX-1,-sourceBottom)
    c.active[1]=1
    v:Show()

    c.minDown=sourceBottom
    c.maxDown=targetTop
  else
    -- Cross-column prerequisite: preserve the established orthogonal dog-leg
    -- look. Only geometry changed; color/thickness remain the FR3a baseline.
    local mid=sourceBottom+math.floor(gap/2)
    local v1,h,v2=c.segments[1],c.segments[2],c.segments[3]

    v1:ClearAllPoints()
    v1:SetWidth(3)
    v1:SetHeight(math.max(2,mid-sourceBottom))
    v1:SetPoint("TOPLEFT",f.canvas,"TOPLEFT",sourceCenterX-1,-sourceBottom)
    c.active[1]=1
    v1:Show()

    h:ClearAllPoints()
    h:SetWidth(math.max(3,math.abs(targetCenterX-sourceCenterX)))
    h:SetHeight(3)
    h:SetPoint("TOPLEFT",f.canvas,"TOPLEFT",math.min(sourceCenterX,targetCenterX),-mid)
    c.active[2]=1
    h:Show()

    v2:ClearAllPoints()
    v2:SetWidth(3)
    v2:SetHeight(math.max(2,targetTop-mid))
    v2:SetPoint("TOPLEFT",f.canvas,"TOPLEFT",targetCenterX-1,-mid)
    c.active[3]=1
    v2:Show()

    c.minDown=sourceBottom
    c.maxDown=targetTop
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
      local topDown=GRID_Y0+(t.tier-1)*GRID_Y
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

    local c=TI.connectors[i]
    if c and c.minDown and c.maxDown then
      if c.minDown>=offset and c.maxDown<=(offset+viewport) then
        for n,seg in pairs(c.segments) do
          if c.active and c.active[n] then seg:Show() else seg:Hide() end
        end
      else
        -- Hide only for clipping. Keep active flags/geometry so valid
        -- prerequisite lines restore correctly when scrolling back.
        for _,seg in pairs(c.segments) do seg:Hide() end
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

local function prerequisiteTalentForRender(d,page,t,staticTalent)
  if not t then return t end

  -- Current live packet is absolute prerequisite authority.
  if t.prereqScanned==1 then return t end

  -- Learned current-class / peer-learned geometry is next.
  if staticTalent and TalentInspectData_GetPrerequisite then
    local pt,pc,pr,source=TalentInspectData_GetPrerequisite(staticTalent)
    if source=="learned" or source=="learned-none" then
      local view={}
      for k,v in pairs(t) do view[k]=v end
      view.preTier=pt or 0
      view.preCol=pc or 0
      view.preRank=pr
      view.prereqScanned=1
      return view
    end
  end

  -- Old/static geometry remains last resort.
  return t
end

local updateSpecButtonVisual

local function selectTab(page)
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
  hideButtons()
  local tab=d.tabs[page]
  f.treeTitle:SetText((tab.name or "Talent Tree").."  |cffffffff"..(tab.points or 0).." points|r")
  -- FR3d: never let a remote/cached fileName choose another class's artwork.
  local canonicalBG=canonicalTreeBackground(d.class,page)
  setTreeBackground(canonicalBG or tab.fileName)
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
    local y=-GRID_Y0-(t.tier-1)*GRID_Y
    b:SetPoint("TOPLEFT",f.canvas,"TOPLEFT",x,y)
    b.icon:SetTexture(t.icon)
    b.icon:SetAlpha(1)
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
    drawPrereq(prerequisiteTalentForRender(d,page,t,b.static), i)
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
  for p=1,3 do
    if d.tabs and d.tabs[p] then
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
        local msg="TAL^"..to.."^"..session.."^"..p.."^"..i.."^"..safe(t.name).."^"..safe(t.icon).."^"..t.tier.."^"..t.col.."^"..t.rank.."^"..t.maxRank.."^"..(t.preTier or 0).."^"..(t.preCol or 0).."^"..(t.prereqScanned or 0)
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

local function beginSyncTiming(name)
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
end

local fallbackDriver=CreateFrame("Frame")

local function stopFallbackTimer()
  TI.fallbackName=nil
  TI.fallbackClass=nil
  TI.fallbackElapsed=0
  fallbackDriver:SetScript("OnUpdate",nil)
end

local function showNoSyncMessages(leftText,rightText)
  if not f.noSyncLeft or not f.noSyncRight then return end
  f.noSyncLeft:SetText(leftText or "Target not in party, raid, guild")
  f.noSyncRight:SetText(rightText or "No TalentInspect Sync Data")
  f.noSyncLeft:Show()
  f.noSyncRight:Show()
end

local function hideNoSyncMessages()
  if f.noSyncLeft then f.noSyncLeft:Hide() end
  if f.noSyncRight then f.noSyncRight:Hide() end
end

local function showZeroTalentFallback(name,classToken,leftText,rightText)
  if not name or not classToken then return end

  local d=buildZeroTalentData(name,classToken,UnitLevel("target"))
  if not d or not d.tabs or not d.tabs[1] then return end

  TI.currentName=name
  TI.currentData=d
  TI.selectedTab=1

  local hs=TI.hostState and TI.hostState.InspectFrame
  if hs then
    hs.name=name
    hs.data=d
    hs.selectedTab=1
  end

  showData(d,"No sync data")
  -- Explicitly render tree 1 after the static zero data is bound. The other
  -- two tree tabs remain live and switch to their own complete zero-rank trees.
  selectTab(1)
  showNoSyncMessages(leftText,rightText)
end

local function startFallbackTimer(name,classToken,leftText,rightText)
  stopFallbackTimer()
  TI.fallbackName=name
  TI.fallbackClass=classToken
  TI.fallbackElapsed=0

  showNoSyncMessages(leftText,rightText)

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
    stopFallbackTimer()

    if TI.embeddedPrefix=="InspectFrame" and f:IsShown() and
       wanted and wanted==TI.currentName and
       not (TI.syncActiveName==wanted and TI.syncBeginAt) then
      showZeroTalentFallback(
        wanted,
        class,
        leftText or "Target not in party, raid, guild",
        rightText or "No TalentInspect Sync Data"
      )
    end
  end)
end

local function showNoTransport(name)
  hideButtons()
  showBlankPane()

  local _,classToken=UnitClass("target")
  if TalentInspectData_NormalizeClass then
    classToken=TalentInspectData_NormalizeClass(classToken)
  end

  local names=VPLUS_TREE_NAMES[classToken or ""]
  if names and names[1] then
    f.treeTitle:SetText(names[1].." 0 points")
  else
    f.treeTitle:SetText("Talents 0 points")
  end
  for i=1,3 do
    if f.tabs[i] then
      if names and names[i] then
        f.tabs[i].text:SetText(names[i].." 0")
        f.tabs[i]:Show()

        -- FR2-XML4: skin the tab immediately during the six-second waiting
        -- state. Previously the XML default/pfUI-looking layer remained visible
        -- until selectTab() ran after fallback data was rendered.
        updateSpecButtonVisual(f.tabs[i], i==1)
      else
        f.tabs[i]:Hide()
      end
    end
  end

  f.title:SetText(name or "Unknown")
  f.subtitle:SetText("TalentInspect sync")
  if TI.embeddedHost then f:Show() end

  startFallbackTimer(
    name,
    classToken,
    "WoW 1.12 sync requires party, raid, or guild",
    "No TalentInspect Sync Data"
  )
end

local function request(name)
  if not name or name=="" then return end
  TI.currentName=name
  beginSyncTiming(name)

  TI.syncExpectedName=name
  local _,expectedClass=UnitClass("target")
  if TalentInspectData_NormalizeClass then
    expectedClass=TalentInspectData_NormalizeClass(expectedClass)
  end
  TI.syncExpectedClass=expectedClass
  local cached=TalentInspectDB.cache[name]
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
    hideButtons()
    showBlankPane()
    f.treeTitle:SetText("Requesting talents...")
    for i=1,3 do if f.tabs[i] then f.tabs[i]:Hide() end end
    f.title:SetText(name)
    f.subtitle:SetText("Requesting VanillaPlus talents via "..channel)
    f.status:SetText("Waiting for addon response")
    if TI.embeddedHost then f:Show() end

    local _,classToken=UnitClass("target")
    if TalentInspectData_NormalizeClass then
      classToken=TalentInspectData_NormalizeClass(classToken)
    end
    startFallbackTimer(
      name,
      classToken,
      "Waiting for TalentInspect response",
      "No TalentInspect Sync Data"
    )
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
  local d=TalentInspectDB and TalentInspectDB.cache and TalentInspectDB.cache[name]
  if not d or not d.tabs or not d.tabs[page] or not d.tabs[page].talents[index] then return end
  d.tabs[page].talents[index].description=text
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
  if not host or prefix~="InspectFrame" then return end

  hideHostPages(prefix)
  TI.embeddedPrefix=prefix
  setEmbeddedMode(host)

  -- Resolve ownership BEFORE showing the reusable TalentInspect canvas.
  local name=hostPlayerName(host,prefix)
  if not name or name=="" or name==UnitName("player") then
    f:Hide()
    return
  end

  local hs=TI.hostState.InspectFrame

  -- Player transition boundary: invalidate every visible reference belonging
  -- to the previous inspected player before the new player's cache/request is
  -- allowed to show anything.
  if TI.currentName~=name or (hs and hs.name and hs.name~=name) then
    f:Hide()
    hideButtons()
    showBlankPane()
    for i=1,3 do if f.tabs[i] then f.tabs[i]:Hide() end end
    TI.currentData=nil
    TI.currentName=name
    TI.hoveredTalentButton=nil
    if GameTooltip then GameTooltip:Hide() end
    if hs then
      hs.name=name
      hs.data=nil
      hs.selectedTab=1
    end
    TI.selectedTab=1
  end

  if f.scroll then f.scroll:Show() end
  if f.scrollBar then f.scrollBar:Show() end

  -- Show only data that is explicitly owned by THIS player.
  local cached=TalentInspectDB.cache and TalentInspectDB.cache[name]
  if cached and cached.name==name then
    if hs then
      hs.name=name
      hs.data=cached
    end
    showData(cached,cachedStatus(cached))
  else
    hideButtons()
    showBlankPane()
    f.treeTitle:SetText("Requesting talents...")
    f.title:SetText(name)
    f.subtitle:SetText("TalentInspect sync")
    f.status:SetText("Waiting for "..name)
    f:Show()
  end

  request(name)
  if f.Raise then f:Raise() end
end

local function hideEmbeddedForHost(host)
  if TI.embeddedHost==host then
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
    showEmbeddedTalents(host,prefix)
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
    if event=="PLAYER_TARGET_CHANGED" and TI.embeddedPrefix=="InspectFrame" and f:IsShown() then
      local safe=nil
      if targetCanBeInspectedSafely then safe=targetCanBeInspectedSafely() end
      if not safe then
        if closeInvalidInspectTarget then
          closeInvalidInspectTarget()
        else
          -- Ultra-early fallback: never pass an invalid target transition into
          -- stock Blizzard_InspectUI portrait code.
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

local pendingNativeOpen=nil
local pendingNativeElapsed=0

local function clickTalentTabFor(prefix)
  local host=getglobal(prefix)
  local tab=installNativeTab(prefix)
  if not host or not tab then return nil end

  local id=tab:GetID()
  if PanelTemplates_SetTab then PanelTemplates_SetTab(host,id) end

  -- ShowUIPanel / CharacterFrame OnShow can resurrect the default paper doll.
  -- Hide native pages immediately before AND after embedding our Talents page.
  hideHostPages(prefix)
  showEmbeddedTalents(host,prefix)
  hideHostPages(prefix)

  return 1
end

local function openSelfTalents()
  -- FR1b: local talents belong to the server/default N talent UI.
  -- TalentInspect still captures local talents internally when responding
  -- to another player's addon request, but renders no duplicate local tree.
  DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99TalentInspect:|r local talents use the normal Talents window (N). TalentInspect is for inspecting other players.")
end

targetCanBeInspectedSafely = function()
  if not UnitExists("target") or not UnitIsPlayer("target") then return nil end
  if UnitName("target")==UnitName("player") then return nil end

  -- 1.12 InspectUnit itself is normally gated by CheckInteractDistance(...,1).
  if CheckInteractDistance and not CheckInteractDistance("target",1) then
    return nil
  end
  return 1
end

local function resetInspectTalentView(newName)
  stopFallbackTimer()
  hideNoSyncMessages()
  f:Hide()
  hideButtons()
  showBlankPane()
  for i=1,3 do if f.tabs[i] then f.tabs[i]:Hide() end end
  TI.currentData=nil
  TI.currentName=newName
  TI.hoveredTalentButton=nil
  TI.selectedTab=1
  if GameTooltip then GameTooltip:Hide() end
  local hs=TI.hostState and TI.hostState.InspectFrame
  if hs then
    hs.name=newName
    hs.data=nil
    hs.selectedTab=1
  end
end

closeInvalidInspectTarget = function()
  resetInspectTalentView(UnitExists("target") and UnitName("target") or nil)
  local host=getglobal("InspectFrame")
  if host then
    if HideUIPanel then HideUIPanel(host) else host:Hide() end
  end
end

local function openTargetTalents()
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

  if InspectUnit then InspectUnit("target") end

  installNativeTabs()
  local host=getglobal("InspectFrame")
  if host then
    if ShowUIPanel then ShowUIPanel(host) else host:Show() end
    if clickTalentTabFor("InspectFrame") then return end
  end

  -- Custom 1.12 UIs may instantiate InspectFrame one or two frames later.
  pendingNativeOpen={kind="target",tries=0}
  pendingNativeElapsed=0
  startNativeOpenDriver()
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
  if pendingNativeElapsed<0.10 then return end
  pendingNativeElapsed=0
  pendingNativeOpen.tries=(pendingNativeOpen.tries or 0)+1

  installNativeTabs()

  local prefix="InspectFrame"
  local host=getglobal(prefix)
  local done=nil
  if host then
    if ShowUIPanel then ShowUIPanel(host) else host:Show() end
    done=clickTalentTabFor(prefix)
  end

  if done or pendingNativeOpen.tries>=8 then
    pendingNativeOpen=nil
    this:SetScript("OnUpdate",nil)
  end
end

local function startNativeOpenDriver()
  pendingNativeElapsed=0
  if not nativeOpenDriver:GetScript("OnUpdate") then
    nativeOpenDriver:SetScript("OnUpdate",TalentInspect_NativeOpenUpdate)
  end
end

local function inspectTarget()
  openTargetTalents()
end

local eventFrame=CreateFrame("Frame")
eventFrame:RegisterEvent("CHAT_MSG_ADDON")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("CHARACTER_POINTS_CHANGED")
eventFrame:RegisterEvent("SPELLS_CHANGED")
eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
eventFrame:RegisterEvent("GUILD_ROSTER_UPDATE")
eventFrame:SetScript("OnEvent", function()
  if event=="PLAYER_LOGIN" then
    math.randomseed(time())
    if type(TalentInspectDB.cache)~="table" then TalentInspectDB.cache={} end
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
    -- One-shot ownership refresh only while TalentInspect owns InspectFrame.
    if TI.embeddedPrefix=="InspectFrame" and f:IsShown() then
      local newName=(UnitExists("target") and UnitIsPlayer("target")) and UnitName("target") or nil

      if not newName or newName==UnitName("player") or not targetCanBeInspectedSafely() then
        closeInvalidInspectTarget()
        return
      end

      if newName~=TI.currentName then
        resetInspectTalentView(newName)
        -- openTargetTalents() performs the single guarded InspectUnit call.
        openTargetTalents()
      end
    end
    return
  end

  if event=="CHARACTER_POINTS_CHANGED" or event=="SPELLS_CHANGED" then
    local me=UnitName("player")
    if me then
      local fresh=captureLocal()
      cacheData(fresh)
      if TI.currentName==me and f:IsShown() then
        showData(fresh,"Local talents updated")
      end
    end
    return
  end
  if event~="CHAT_MSG_ADDON" or arg1~=TI.PREFIX then return end
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
    local recipient=unsafe(a[2])
    if recipient~=me then return end
    local page=tonumber(a[3])
    local index=tonumber(a[4])
    local part=tonumber(a[5]) or 1
    local total=tonumber(a[6]) or 1
    local key=tostring(sender or "")..":"..tostring(page)..":"..tostring(index)
    descParts[key]=descParts[key] or {total=total,parts={}}
    descParts[key].parts[part]=a[7] or ""
    local ready=1
    for p=1,total do if not descParts[key].parts[p] then ready=nil break end end
    if ready then
      local joined=""
      for p=1,total do joined=joined..descParts[key].parts[p] end
      descParts[key]=nil
      cacheDescription(sender,page,index,unescapeTooltipText(joined))
    end
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
      sendLocalTo(requester,channel)
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
    if channel then sendLearnedClass(sender,channel,classToken,receiverFP) end
    return
  elseif cmd=="LBEGIN" then
    local classToken=unsafe(a[3]); local fp=unsafe(a[4])
    if TalentInspectData_NormalizeClass then classToken=TalentInspectData_NormalizeClass(classToken) end
    if TalentInspectHelper and TalentInspectHelper:BeginPeerClass(classToken) then
      TI.learnPending[classToken]={sender=sender,fingerprint=fp,count=0}
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
    if not d then d={total=total,parts={}}; TI.learnDescParts[key]=d end
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
    if incomingName==TI.syncExpectedName and
       not classesAgree(incomingClass,expectedClass) then
      TI.pending[s]=nil
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
    TI.pending[s]={name=incomingName,class=incomingClass,level=tonumber(a[6]) or 0,tabs={},sender=sender}
  elseif cmd=="TAB" then
    local d=TI.pending[a[3]]; if not d then return end
    local p=tonumber(a[4]); if not p then return end
    local remoteFileName=unsafe(a[8])
    d.tabs[p]={
      name=unsafe(a[5]),
      icon=unsafe(a[6]),
      points=tonumber(a[7]) or 0,
      fileName=canonicalTreeBackground(d.class,p) or remoteFileName,
      talents={}
    }
  elseif cmd=="TAL" then
    local d=TI.pending[a[3]]; if not d then return end
    local p=tonumber(a[4]); local i=tonumber(a[5]); if not d.tabs[p] then return end
    d.tabs[p].talents[i]={index=i,name=unsafe(a[6]),icon=unsafe(a[7]),tier=tonumber(a[8]) or 1,col=tonumber(a[9]) or 1,
      rank=tonumber(a[10]) or 0,maxRank=tonumber(a[11]) or 1,
      preTier=tonumber(a[12]) or 0,preCol=tonumber(a[13]) or 0,
      prereqScanned=tonumber(a[14]) or 0}
  elseif cmd=="END" then
    local d=TI.pending[a[3]]; if not d then return end
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

    local old=TalentInspectDB.cache[d.name]
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
       TI.currentName==d.name and sender==d.name then
      TI.selectedTab=rhs.selectedTab or best
      showData(d,"Synced")
    end
  end
end)

-- Slash commands -------------------------------------------------------------
SLASH_TALENTINSPECT1="/ti"
SLASH_TALENTINSPECT2="/talentinspect"
SlashCmdList["TALENTINSPECT"]=function(msg)
  msg=string.lower(msg or "")
  if msg=="prereqs" then
    local n=0
    for _,c in pairs(TI.connectors or {}) do
      if c.minDown and c.maxDown then n=n+1 end
    end
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99TalentInspect:|r rendered prerequisite links="..n..
      " on tree "..tostring(TI.selectedTab or "?")..".")
    return
  end
  if msg=="self" then
    openSelfTalents()
  elseif msg=="refresh" and TI.currentName then
    if TI.currentName==UnitName("player") then
      local d=captureLocal(); cacheData(d); showData(d,"Local talents updated")
    else
      request(TI.currentName)
    end
  elseif msg=="clearcache" or msg=="purge" then
    clearTalentCache()
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99TalentInspect:|r cached inspected talents cleared. Your UI/settings were kept.")
  elseif msg=="cache" then
    local n=0
    for _ in pairs(TalentInspectDB.cache or {}) do n=n+1 end
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99TalentInspect:|r "..n.." cached player talent build(s).")
  elseif msg=="learntalent" then
    local b=TI.hoveredTalentButton
    if not b or not b.data then
      DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99TalentInspect:|r hover a talent first, then run /ti learntalent.")
    else
      local live=b.data
      local d=TI.currentData
      local page=b.page or TI.selectedTab or 1
      local classToken=b.classToken or (d and d.class)
      local pos=nil
      if live.tier and live.col then pos=string.char(96+live.tier)..tostring(live.col) end
      local st=TalentInspectData_FindTalent and TalentInspectData_FindTalent(classToken,page,live.name,pos,live.index)
      DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99TalentInspect learned talent:|r "..tostring(live.name)..
        " source="..tostring(st and st.source or "static")..
        " learned="..tostring(st and st.learned or 0)..
        " descRank="..tostring(st and st.descRank or "nil")..
        " hasDesc="..tostring(st and st.desc and st.desc~="" and "yes" or "no")..
        " resolved="..tostring(st and TalentInspectData_GetDescription and select(2,TalentInspectData_GetDescription(st,(live.rank or 0)>0 and live.rank or 1)) or "none"))
    end
  elseif msg=="learnsync" then
    local parts={}
    if TalentInspectDB and TalentInspectDB.learned then
      for classToken,d in pairs(TalentInspectDB.learned) do
        local fp=(TalentInspectHelper and TalentInspectHelper:GetFingerprint(classToken)) or "?"
        table.insert(parts,classToken.."="..fp.." ("..tostring(d.source or "?")..")")
      end
    end
    if table.getn(parts)==0 then
      DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99TalentInspect:|r no learned class snapshots stored.")
    else
      DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99TalentInspect learned:|r "..table.concat(parts,", "))
    end
    for classToken,s in pairs(TI.lastLearnSync or {}) do
      DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99TalentInspect sync:|r "..classToken..
        " state="..tostring(s.state).." sender="..tostring(s.sender)..
        " talents="..tostring(s.count or 0))
    end
  elseif msg=="syncdebug" then
    local name=TI.currentName or (UnitExists("target") and UnitName("target")) or "nil"
    local channel=(name~="nil") and transportFor(name) or nil
    local key=normalizePlayerName(name)
    local d=TI.syncDiag or {}
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99TalentInspect syncdebug:|r target="..tostring(name)..
      " transport="..tostring(channel or "NONE")..
      " guildPeer="..tostring(key and TI.guildPeers[key] and 1 or 0)..
      " roster="..tostring(key and TI.guildRosterNames[key] and 1 or 0))
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99TalentInspect syncdebug:|r lastRequest="..
      tostring(d.lastRequestName or "nil").." via "..tostring(d.lastRequestChannel or "nil")..
      " lastREQseen="..tostring(d.lastReqSeen or "nil")..
      " from="..tostring(d.lastReqSender or "nil")..
      " via="..tostring(d.lastReqChannel or "nil")..
      " beginFrom="..tostring(d.lastBeginSender or "nil")..
      " beginVia="..tostring(d.lastBeginChannel or "nil"))
  elseif msg=="synctime" then
    local name=TI.currentName
    local t=name and TI.syncTiming[name]
    if t then
      local rb=t.requestToBegin
      local rc=t.requestToComplete
      local bc=t.beginToComplete
      DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff33ff99TalentInspect:|r %s sync: request->begin %s, request->complete %s, begin->complete %s",
        name,
        rb and string.format("%.3fs",rb) or "pending",
        rc and string.format("%.3fs",rc) or "pending",
        bc and string.format("%.3fs",bc) or "pending"))
    else
      DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99TalentInspect:|r no completed sync timing for the current inspected player.")
    end
  elseif msg=="help" then
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99TalentInspect|r  /ti  /ti refresh  /ti cache  /ti learntalent  /ti learnsync  /ti syncdebug  /ti synctime  /ti clearcache")
  else
    openTargetTalents()
  end
end

-- Blizzard player right-click menu ------------------------------------------
local POP="VPTI_INSPECT_TALENTS"
if UnitPopupButtons and UnitPopupMenus then
  -- FR1d: use the native Duel interaction distance. UnitPopup will grey
  -- and disable this entry the same way it does other distance-gated actions.
  UnitPopupButtons[POP]={text="Talents",dist=3}
  local menus={"PLAYER","PARTY","RAID_PLAYER","FRIEND","GUILD","TARGET"}
  for _,m in ipairs(menus) do
    if UnitPopupMenus[m] then
      local found=nil
      for _,v in ipairs(UnitPopupMenus[m]) do if v==POP then found=1 end end
      if not found then table.insert(UnitPopupMenus[m],POP) end
    end
  end
  local function resolvePopupPlayerName()
    local dropdown=UIDROPDOWNMENU_INIT_MENU

    -- Different 1.12/custom clients expose UIDROPDOWNMENU_INIT_MENU in
    -- different shapes. Stock-like clients may provide a dropdown table,
    -- while VanillaPlus/custom FrameXML may leave a string token here.
    if type(dropdown)=="table" then
      if dropdown.name and dropdown.name~="" then
        return dropdown.name
      end
      if dropdown.unit and UnitExists(dropdown.unit) then
        return UnitName(dropdown.unit)
      end
    elseif type(dropdown)=="string" and UnitExists(dropdown) then
      return UnitName(dropdown)
    end

    -- TalentInspect is primarily invoked after targeting the player, so this
    -- is the safest cross-client fallback when the popup does not expose its
    -- owner as a table. Never index the string as though it were a frame.
    if UnitExists("target") and UnitIsPlayer("target") then
      return UnitName("target")
    end

    return UnitName("player")
  end

  local function resolvePopupUnit()
    local dropdown=UIDROPDOWNMENU_INIT_MENU
    if type(dropdown)=="table" then
      if dropdown.unit and UnitExists(dropdown.unit) and UnitIsPlayer(dropdown.unit) then
        return dropdown.unit
      end
      if dropdown.name and UnitExists("target") and UnitIsPlayer("target") and
         UnitName("target")==dropdown.name then
        return "target"
      end
    elseif type(dropdown)=="string" and UnitExists(dropdown) and UnitIsPlayer(dropdown) then
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

        -- FR1d safety guard: native UnitPopup dist=3 should already make this
        -- grey/non-clickable when out of Duel range. Re-check here anyway so
        -- a custom UnitPopup implementation cannot bypass the distance rule.
        if name==UnitName("player") or not popupTalentInRange() then
          CloseDropDownMenus()
          return
        end

        -- The intended workflow is nearby player -> right-click -> Talents.
        openTargetTalents()
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
TalentInspect.OpenTargetTalents = openTargetTalents
