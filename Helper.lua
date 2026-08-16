-- TalentInspect Helper.lua
-- FR4 Live Talent Learning
-- WoW 1.12.1 / VanillaPlus
--
-- Live current-class talent definitions feed a persistent learned-data layer.
-- The physical TalentData.lua cannot be rewritten by the WoW sandbox, so
-- TalentData.lua resolves this learned layer BEFORE packaged static V5 data.
--
-- Safety:
--   * one bounded scan after login;
--   * one delayed bounded rescan after CHARACTER_POINTS_CHANGED;
--   * no permanent polling;
--   * one reusable hidden tooltip;
--   * no frame/tooltip creation per talent.

TalentInspectHelper = TalentInspectHelper or {}
local H = TalentInspectHelper

H.VERSION = "1.0.0"
H.scanScheduled = nil
H.scanDelay = 0
H.scanReason = nil
H.lastScanAt = nil
H.lastScanClass = nil
H.lastScanCount = 0

TalentInspectData_Learned = TalentInspectData_Learned or {}

local function normClass(c)
  if TalentInspectData_NormalizeClass then
    return TalentInspectData_NormalizeClass(c)
  end
  return c
end

local function playerClass()
  local _,c=UnitClass("player")
  return normClass(c)
end

local function now()
  if GetTime then return GetTime() end
  return 0
end

local function ensureDB()
  TalentInspectDB = TalentInspectDB or {}
  TalentInspectDB.learned = TalentInspectDB.learned or {}
  return TalentInspectDB.learned
end

local scanTip=CreateFrame("GameTooltip","TalentInspectLiveTalentScanTooltip",UIParent,"GameTooltipTemplate")
scanTip:SetOwner(UIParent,"ANCHOR_NONE")
scanTip:Hide()

local function trim(s)
  if not s then return nil end
  s=string.gsub(s,"^%s+","")
  s=string.gsub(s,"%s+$","")
  if s=="" then return nil end
  return s
end

local function tooltipDescription(tab,index)
  if not scanTip or not scanTip.SetTalent then return nil end

  scanTip:ClearLines()
  local ok=pcall(function() scanTip:SetTalent(tab,index) end)
  if not ok then
    scanTip:Hide()
    return nil
  end

  local parts={}
  local n=scanTip:NumLines() or 0
  -- line 1 = name, line 2 often rank. Keep informative body only.
  for i=2,n do
    local left=getglobal("TalentInspectLiveTalentScanTooltipTextLeft"..i)
    local right=getglobal("TalentInspectLiveTalentScanTooltipTextRight"..i)
    local lt=left and trim(left:GetText())
    local rt=right and trim(right:GetText())

    -- Learn ONLY the currently displayed rank's effect text. Native talent
    -- tooltips can append "Next rank:" plus a second description; treating
    -- both as one learned description would silently corrupt rank authority.
    if lt and (string.find(lt,"^Next rank") or string.find(lt,"^Requires ")) then
      break
    end

    if lt and not string.find(lt,"^Rank %d") then
      table.insert(parts,lt)
    end
    if rt and rt~=lt and not string.find(rt,"^Rank %d") then
      table.insert(parts,rt)
    end
  end

  scanTip:Hide()
  if table.getn(parts)==0 then return nil end
  return table.concat(parts,"\n")
end

local function prereqInfo(tab,index)
  if not GetTalentPrereqs then return nil,nil,nil,nil end
  local ok,a,b,c=pcall(GetTalentPrereqs,tab,index)
  if not ok then return nil,nil,nil,nil end
  local tier=tonumber(a)
  local col=tonumber(b)
  local rank=tonumber(c)
  if tier and col and tier>=1 and tier<=7 and col>=1 and col<=4 then
    return tier,col,rank,1
  end
  -- Successful call + no valid coordinates is authoritative "no prerequisite".
  return nil,nil,nil,1
end

local function makePos(tier,col)
  if not tier or not col then return nil end
  return "r"..tier.."c"..col
end

local function publishLearned(classToken,classData)
  TalentInspectData_Learned[classToken]=classData
  local db=ensureDB()
  db[classToken]=classData
end

function H:RestoreLearned()
  local db=ensureDB()
  for classToken,classData in pairs(db) do
    if classData and classData.trees then
      for p=1,3 do
        local tree=classData.trees[p]
        if tree and tree.talents then
          tree.byName=tree.byName or {}
          tree.byPos=tree.byPos or {}
          for i,t in pairs(tree.talents) do
            if t then
              -- Pre-FR4e caches had no descRank. Own live-scan records retain
              -- their observed rank; old peer records are safely treated as
              -- Rank 1 rather than allowed to override arbitrary ranks.
              if t.desc and t.desc~="" and not t.descRank then
                if t.source=="live-scan" and tonumber(t.rank) and tonumber(t.rank)>0 then
                  t.descRank=tonumber(t.rank)
                else
                  t.descRank=1
                end
              end
              if t.name then tree.byName[t.name]=t end
              if t.pos then tree.byPos[t.pos]=t end
            end
          end
        end
      end
    end
    TalentInspectData_Learned[classToken]=classData
  end
end

function H:ScanCurrentClass(reason)
  local classToken=playerClass()
  if not classToken then return nil end
  if not GetNumTalentTabs or not GetNumTalents or not GetTalentInfo then return nil end

  local classData={class=classToken, scannedAt=time and time() or 0, trees={}}
  local total=0
  local numTabs=GetNumTalentTabs() or 0

  for tab=1,numTabs do
    local treeName,treeIcon,pointsSpent,fileName=GetTalentTabInfo(tab)
    local tree={
      name=treeName,
      icon=treeIcon,
      points=pointsSpent or 0,
      fileName=fileName,
      talents={},
      byName={},
      byPos={}
    }

    local numTalents=GetNumTalents(tab) or 0
    for index=1,numTalents do
      local name,icon,tier,col,rank,maxRank=GetTalentInfo(tab,index)
      if name and tier and col then
        local preTier,preCol,preRank,prereqScanned=prereqInfo(tab,index)
        local rec={
          learned=1,
          source="live-scan",
          index=index,
          sourceName=name,
          name=name,
          icon=icon,
          tier=tier,
          col=col,
          pos=makePos(tier,col),
          rank=rank or 0,
          maxRank=maxRank or 0,
          preTier=preTier,
          preCol=preCol,
          preRank=preRank,
          prereqScanned=prereqScanned,
          desc=tooltipDescription(tab,index),
          -- GameTooltip:SetTalent shows current rank when learned, otherwise
          -- the first learnable rank. Preserve that relationship explicitly.
          descRank=((rank or 0)>0 and (rank or 0) or 1),
          scannedAt=classData.scannedAt
        }

        tree.talents[index]=rec
        tree.byName[name]=rec
        if rec.pos then tree.byPos[rec.pos]=rec end
        total=total+1
      end
    end

    classData.trees[tab]=tree
  end

  publishLearned(classToken,classData)
  H.lastScanAt=now()
  H.lastScanClass=classToken
  H.lastScanCount=total
  H.lastScanReason=reason or "manual"
  return total
end

function H:ScheduleScan(delay,reason)
  H.scanScheduled=1
  H.scanDelay=delay or 0.75
  H.scanReason=reason or "scheduled"
end

-- Temporary driver only while a scan is scheduled.
local driver=CreateFrame("Frame")
driver:Hide()
driver:SetScript("OnUpdate",function()
  if not H.scanScheduled then
    this:Hide()
    return
  end

  H.scanDelay=(H.scanDelay or 0)-(arg1 or 0)
  if H.scanDelay>0 then return end

  local reason=H.scanReason
  H.scanScheduled=nil
  H.scanReason=nil
  this:Hide()
  H:ScanCurrentClass(reason)
end)

local function schedule(delay,reason)
  H:ScheduleScan(delay,reason)
  driver:Show()
end

local events=CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("CHARACTER_POINTS_CHANGED")
events:SetScript("OnEvent",function()
  if event=="PLAYER_LOGIN" then
    H:RestoreLearned()
    -- FR4j: give VanillaPlus/custom-client talent APIs and tooltip text extra time
    -- to settle before the single bounded login scan. This avoids capturing
    -- stale early-login talent descriptions.
    schedule(20.00,"login-delayed")
  elseif event=="CHARACTER_POINTS_CHANGED" then
    -- Coalesce rapid changes; one delayed full-class refresh.
    schedule(0.75,"talent-change")
  end
end)

SLASH_TALENTINSPECTLEARN1="/tilearn"
SlashCmdList["TALENTINSPECTLEARN"]=function(msg)
  msg=string.lower(msg or "")
  if msg=="scan" or msg=="" then
    local n=H:ScanCurrentClass("manual")
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99TalentInspect:|r live talent scan learned "..(n or 0).." current-class talents.")
  elseif msg=="status" then
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99TalentInspect:|r learned class="..tostring(H.lastScanClass)..
      " talents="..tostring(H.lastScanCount).." reason="..tostring(H.lastScanReason))
  end
end


-- FR4a: on-demand peer learned-data exchange -------------------------------
local function peerSafe(s)
  s=tostring(s or "")
  s=string.gsub(s,"%%","%%25")
  s=string.gsub(s,"|","%%7C")
  s=string.gsub(s,"\n","%%0A")
  s=string.gsub(s,"~","%%7E")
  s=string.gsub(s,"%^","%%5E")
  return s
end
local function peerUnsafe(s)
  s=string.gsub(s or "","%%5E","^")
  s=string.gsub(s,"%%7E","~")
  s=string.gsub(s,"%%0A","\n")
  s=string.gsub(s,"%%7C","|")
  s=string.gsub(s,"%%25","%%")
  return s
end

local function learnedFingerprint(d)
  if not d or not d.trees then return "0" end
  local sum=5381
  local count=0
  for p=1,3 do
    local tree=d.trees[p]
    if tree and tree.talents then
      for i=1,table.getn(tree.talents) do
        local t=tree.talents[i]
        if t then
          local s=(t.name or "").."|"..tostring(t.tier or 0).."|"..
            tostring(t.col or 0).."|"..tostring(t.maxRank or 0).."|"..
            tostring(t.preTier or 0).."|"..tostring(t.preCol or 0).."|"..
            tostring(t.preRank or 0).."|"..tostring(t.prereqScanned or 0).."|"..
            tostring(t.descRank or 0).."|"..(t.desc or "")
          for n=1,string.len(s) do
            sum=math.mod(sum*33+string.byte(s,n),2147483647)
          end
          count=count+1
        end
      end
    end
  end
  return tostring(count).."-"..tostring(sum)
end

function H:GetOwnLearnedClass()
  local c=playerClass()
  local d=TalentInspectData_Learned and TalentInspectData_Learned[c]
  if d and d.class==c then return d end
  return nil
end

function H:GetFingerprint(classToken)
  classToken=normClass(classToken)
  local d=TalentInspectData_Learned and TalentInspectData_Learned[classToken]
  return learnedFingerprint(d)
end

function H:SerializeLearnedTalent(t)
  -- FR4d: structural packet only. Descriptions are chunked separately because
  -- a full tooltip can exceed the 1.12 addon-message payload limit.
  return table.concat({
    tostring(t.index or 0),peerSafe(t.name),peerSafe(t.icon),
    tostring(t.tier or 0),tostring(t.col or 0),tostring(t.maxRank or 0),
    tostring(t.preTier or 0),tostring(t.preCol or 0),tostring(t.preRank or 0),
    tostring(t.descRank or (((t.rank or 0)>0) and t.rank or 1)),
    tostring(t.prereqScanned or 0)
  },"~")
end

function H:SerializeLearnedDescription(t)
  if not t or not t.desc or t.desc=="" then return "" end
  return peerSafe(t.desc)
end

function H:BeginPeerClass(classToken)
  classToken=normClass(classToken)
  if classToken==playerClass() then return nil end -- own live scan always wins
  local db=ensureDB()
  db[classToken]={class=classToken,source="peer-learned",scannedAt=time and time() or 0,trees={}}
  TalentInspectData_Learned[classToken]=db[classToken]
  return 1
end

function H:AcceptPeerTalent(classToken,treeIndex,payload)
  classToken=normClass(classToken)
  if classToken==playerClass() then return nil end

  local f={}
  local start=1
  while 1 do
    local p=string.find(payload or "","~",start,1)
    if not p then table.insert(f,string.sub(payload or "",start)); break end
    table.insert(f,string.sub(payload,start,p-1)); start=p+1
  end

  local index=tonumber(f[1]); local name=peerUnsafe(f[2])
  local tier=tonumber(f[4]); local col=tonumber(f[5])
  if not index or not name or name=="" or not tier or not col then return nil end
  if tier<1 or tier>7 or col<1 or col>4 then return nil end

  local db=ensureDB(); local d=db[classToken]
  if not d or d.source~="peer-learned" then return nil end
  local tree=d.trees[treeIndex]
  if not tree then tree={talents={},byName={},byPos={}}; d.trees[treeIndex]=tree end

  local rec={learned=1,source="peer-learned",index=index,sourceName=name,name=name,
    icon=peerUnsafe(f[3]),tier=tier,col=col,pos=makePos(tier,col),rank=0,
    maxRank=tonumber(f[6]) or 0,preTier=tonumber(f[7]),preCol=tonumber(f[8]),
    preRank=tonumber(f[9]),descRank=tonumber(f[10]) or 1,
    prereqScanned=tonumber(f[11]) or 0,
    desc=nil,scannedAt=time and time() or 0}
  tree.talents[index]=rec; tree.byName[name]=rec
  if rec.pos then tree.byPos[rec.pos]=rec end
  return 1
end

function H:ApplyPeerDescription(classToken,treeIndex,index,encoded)
  classToken=normClass(classToken)
  if classToken==playerClass() then return nil end
  local d=TalentInspectData_Learned and TalentInspectData_Learned[classToken]
  local tree=d and d.trees and d.trees[treeIndex]
  local t=tree and tree.talents and tree.talents[index]
  if not t then return nil end
  t.desc=peerUnsafe(encoded or "")
  return 1
end

function H:FinalizePeerClass(classToken,expected)
  classToken=normClass(classToken)
  local d=TalentInspectData_Learned and TalentInspectData_Learned[classToken]
  if not d then return nil end
  local got=learnedFingerprint(d)
  if got~=expected then
    local db=ensureDB(); db[classToken]=nil; TalentInspectData_Learned[classToken]=nil
    return nil
  end
  d.fingerprint=got; d.receivedAt=time and time() or 0
  return 1
end
