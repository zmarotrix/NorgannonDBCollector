-- Event collectors. Every handler is a read of public game state; nothing here calls a
-- protected function, and handlers return early in combat, on secret values and (for
-- positions) inside instances.

local C = NorgannonDBCollector
local DB = NorgannonDB

local frame = CreateFrame("Frame")
C.frame = frame

-- per-session state (never saved): GUIDs already counted, pending dialogs
local seenGuid = {}        -- guid -> true once its position was recorded this session
local killed = {}          -- guid -> true once counted as a kill
local lootedItems = {}     -- guid..mode -> { [itemId] = true }
local lootedGuid = {}      -- guid..mode -> true
local guidByName = {}      -- unit name -> last creature guid seen with it (kill fallback)
local pendingKills = {}
local pendingObjectives = {}
local questDialog, turnInDialog
local lastSpell, lastContainer, lastObjectTip
local objectNames = {}

local function now() return GetTime and GetTime() or 0 end

-------------------------------------------------------------------------------------------
-- NPC sightings
-------------------------------------------------------------------------------------------

local RANKS = { elite = 1, rareelite = 2, worldboss = 3, rare = 4 }

local function near(unit)
  if not CheckInteractDistance then return false end
  local ok, result = pcall(CheckInteractDistance, unit, 3)
  return ok and C.pub(result) and true or false
end

-- Records the unit when it is a creature; `precise` when the player is interacting with it.
-- Returns npcId or objectId and the kind.
function C.SeeUnit(unit, precise)
  if not C.CanCollect() then return C.Log("%s: skipped (combat or paused)", unit) end
  local raw = UnitGUID and UnitGUID(unit)
  local guid = C.pub(raw)
  local kind, id = C.ParseGUID(guid)
  if kind ~= "npcs" and kind ~= "objects" then
    return C.Log("%s: no creature GUID (%s)", unit, raw == nil and "none" or guid == nil and "secret" or "not a creature")
  end
  if kind == "npcs" and UnitPlayerControlled and C.pub(UnitPlayerControlled(unit)) then return end

  local rec = C.Record(kind, id)
  local name = UnitName and C.pub(UnitName(unit))
  C.SetName(rec, name)
  if name then guidByName[name] = guid end

  if kind == "npcs" then
    if C.TagInstanceNpc then C.TagInstanceNpc(id) end
    local level = UnitLevel and C.pub(UnitLevel(unit))
    if type(level) == "number" and level > 0 then
      if not rec.minLevel or level < rec.minLevel then rec.minLevel = level end
      if not rec.maxLevel or level > rec.maxLevel then rec.maxLevel = level end
    end
    local class = UnitClassification and C.pub(UnitClassification(unit))
    if class and RANKS[class] then rec.rank = RANKS[class] end
    if (class == "worldboss" or level == -1) and C.TagInstanceBoss then C.TagInstanceBoss(id, "worldboss", name) end
  end

  if seenGuid[guid] then return id, kind end
  if not precise and not near(unit) then
    C.Log("%s: %s %d, too far for a position", unit, kind, id)
    return id, kind
  end
  local area, x, y = C.PlayerPosition()
  if not area then
    C.Log("%s: %s %d, no map position (instance or unknown map)", unit, kind, id)
    return id, kind
  end
  C.Log("%s: %s %d at %d %.1f,%.1f", unit, kind, id, area, x, y)
  seenGuid[guid] = true
  rec.zone = rec.zone or area
  local _, isNew = C.AddSpawn(rec, area, x, y)
  C.Inc(rec.obs, "seen")
  if isNew then C.CheckSpawn(kind, id, area, x, y) end
  return id, kind
end

-------------------------------------------------------------------------------------------
-- Services (npc flags) from interaction frames
-------------------------------------------------------------------------------------------

local function addFlag(rec, flagName)
  local flag = DB.enums and DB.enums.npcFlags and DB.enums.npcFlags[flagName]
  if not flag then return end
  local flags = rec.flags or 0
  if flags % (2 * flag) < flag then rec.flags = flags + flag end
end

function C.Interact(flagName)
  local id, kind = C.SeeUnit("npc", true)
  if kind ~= "npcs" then return end
  local rec = C.sv.npcs[id]
  if flagName then
    addFlag(rec, flagName)
    C.CheckFlag(id, flagName)
  end
  return id, rec
end

local SERVICE_EVENTS = {
  GOSSIP_SHOW = "GOSSIP",
  TRAINER_SHOW = "TRAINER",
  BANKFRAME_OPENED = "BANKER",
  AUCTION_HOUSE_SHOW = "AUCTIONEER",
  PET_STABLE_SHOW = "STABLEMASTER",
  CONFIRM_BINDER = "INNKEEPER",
  PETITION_VENDOR_SHOW = "PETITIONER",
  GUILD_REGISTRAR_SHOW = "PETITIONER",
  BATTLEFIELDS_SHOW = "BATTLEMASTER",
  QUEST_GREETING = "QUEST_GIVER",
}

local function taxiNodeName()
  if not NumTaxiNodes then return nil end
  local ok, n = pcall(NumTaxiNodes)
  for i = 1, ok and C.pub(n) or 0 do
    if C.pub(TaxiNodeGetType(i)) == "CURRENT" then return C.pub(TaxiNodeName(i)) end
  end
end

-------------------------------------------------------------------------------------------
-- Vendors
-------------------------------------------------------------------------------------------

local function merchantItem(i)
  local id = GetMerchantItemID and C.pub(GetMerchantItemID(i))
  if not id and GetMerchantItemLink then id = C.ItemIDFromLink(GetMerchantItemLink(i)) end
  local stock
  if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
    local info = C.pubTable(C_MerchantFrame.GetItemInfo(i))
    stock = info and C.pub(info.numAvailable)
  elseif GetMerchantItemInfo then
    stock = C.pub(select(5, GetMerchantItemInfo(i)))
  end
  return id, stock
end

-- update: MERCHANT_UPDATE rescans late-loading items without counting another visit
function C.ScanMerchant(update)
  if not C.CanCollect() then return end
  local npcId, rec
  if update then
    local kind, id = C.ParseGUID(UnitGUID and UnitGUID("npc"))
    if kind ~= "npcs" or not C.sv.npcs[id] then return end
    npcId, rec = id, C.sv.npcs[id]
  else
    npcId, rec = C.Interact("VENDOR")
  end
  if not npcId then return end
  if not update and CanMerchantRepair and C.pub(CanMerchantRepair()) then
    addFlag(rec, "REPAIR")
    C.CheckFlag(npcId, "REPAIR")
  end
  local count = GetMerchantNumItems and C.pub(GetMerchantNumItems()) or 0
  rec.sells = rec.sells or {}
  for i = 1, count do
    local itemId, stock = merchantItem(i)
    if itemId then
      -- SPEC: 0 = unlimited/unknown, otherwise the largest stock seen
      local value = (type(stock) == "number" and stock > 0) and stock or 0
      local old = rec.sells[itemId]
      if old == nil or (old > 0 and value > old) or (old > 0 and value == 0 and stock == -1) then
        rec.sells[itemId] = value
      end
      local item = C.Record("items", itemId)
      item.vendors = item.vendors or {}
      item.vendors[npcId] = rec.sells[itemId]
      if old == nil then C.CheckVendorItem(npcId, itemId) end
    end
  end
  if not update then C.Inc(rec.obs, "merchantVisits") end
end

-------------------------------------------------------------------------------------------
-- Quests
-------------------------------------------------------------------------------------------

local function dialogActor()
  local guid = UnitGUID and C.pub(UnitGUID("npc"))
  local kind, id = C.ParseGUID(guid)
  if kind == "npcs" or kind == "objects" then
    C.SeeUnit("npc", true)
    return kind, id
  end
  -- quests started from an item: the item the player used just before
  if lastContainer and now() - lastContainer.t < 5 then return "items", lastContainer.id end
end

local function addActor(quest, questId, role, kind, id)
  if not kind or not id then return end
  quest[role] = quest[role] or {}
  local list = C.Sub(quest[role], kind)
  for _, v in ipairs(list) do if v == id then return end end
  table.insert(list, id)
  local actor = kind ~= "items" and C.sv[kind][id]
  if actor then
    local key = role == "starters" and "questStarts" or "questEnds"
    actor[key] = actor[key] or {}
    for _, v in ipairs(actor[key]) do if v == questId then return end end
    table.insert(actor[key], questId)
  end
end

local function questRecord(questId)
  return C.Record("quests", questId)
end

function C.OnQuestDetail()
  if not C.CanCollect() then return end
  local questId = GetQuestID and C.pub(GetQuestID())
  C.Log("quest dialog: quest %s, npc %s", tostring(questId), tostring(UnitGUID and C.pub(UnitGUID("npc"))))
  if not questId or questId == 0 then return end
  local kind, id = dialogActor()
  if kind == "npcs" then C.Interact("QUEST_GIVER") end
  questDialog = { id = questId, kind = kind, actor = id, title = GetTitleText and C.pub(GetTitleText()) }
end

-- Splits an objective line into its subject using the client's own objective formats.
local SUFFIX_FORMATS = { monster = "QUEST_MONSTERS_KILLED", item = "QUEST_ITEMS_NEEDED", object = "QUEST_OBJECTS_FOUND" }

function C.ObjectiveName(text, otype)
  if type(text) ~= "string" then return nil end
  local name = text:match("^(.-)%s*[:：]%s*%d+%s*/%s*%d+$") or text:match("^%d+%s*/%s*%d+%s+(.+)$") or text
  local fmt = SUFFIX_FORMATS[otype] and _G[SUFFIX_FORMATS[otype]]
  if type(fmt) == "string" then
    local suffix = fmt:match("%%1?%$?s(.*)$") or ""
    suffix = suffix:gsub("%%%d?%$?d", ""):gsub("[:：]?%s*/%s*", "")
    suffix = suffix:match("^%s*(.-)%s*$")
    if suffix ~= "" and name:sub(-#suffix - 1) == " " .. suffix then
      name = name:sub(1, -#suffix - 2)
    end
  end
  return name:match("^%s*(.-)%s*$")
end

-- Reads the quest's objectives from the quest log. Returns false when not loaded yet.
function C.CaptureObjectives(questId)
  if not C_QuestLog or not C_QuestLog.GetQuestObjectives then return true end
  local list = C.pubTable(C_QuestLog.GetQuestObjectives(questId))
  if not list or #list == 0 then return false end
  local quest = C.sv.quests[questId]
  if not quest then return true end
  local observed, spec = {}, {}
  for i, o in ipairs(list) do
    o = C.pubTable(o)
    local text = o and C.pub(o.text)
    if not text then return true end
    local otype = C.pub(o.type)
    local name = C.ObjectiveName(text, otype)
    local required = C.pub(o.numRequired)
    observed[i] = { text = text, type = otype, name = name, required = required }
    local id = C.ResolveObjective(questId, otype, name)
    local kind = ({ monster = "npcs", item = "items", object = "objects" })[otype]
    if kind and id then
      spec[kind] = spec[kind] or {}
      table.insert(spec[kind], { id = id, text = C.enUS and name or nil })
      observed[i].id = id
    end
  end
  quest.obs.objectives = observed
  if next(spec) then quest.objectives = spec end
  C.CheckObjectives(questId, observed)
  return true
end

function C.OnQuestAccepted(a, b)
  -- Forever sends the quest ID; older clients send (logIndex, questID)
  local questId = C.pub(b or a)
  C.Log("quest accepted: %s (dialog %s)", tostring(questId), questDialog and tostring(questDialog.id) or "none")
  if not questId or not C.CanCollect() then return end
  local quest = questRecord(questId)
  local info = C_QuestLog and C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetLogIndexForQuestID(questId)
  info = info and C.pubTable(C_QuestLog.GetInfo(info))
  if info then
    if C.enUS and C.pub(info.title) then quest.name = info.title end
    if C.pub(info.level) then quest.level = info.level end
  elseif questDialog and questDialog.id == questId and questDialog.title then
    C.SetName(quest, questDialog.title)
  end
  C.Inc(quest.obs, "accepted")
  local faction = UnitFactionGroup and C.pub(UnitFactionGroup("player"))
  if faction then C.Inc(C.Sub(quest.obs, "factions"), faction) end
  C.CheckQuest(questId)
  if questDialog and questDialog.id == questId and questDialog.kind then
    addActor(quest, questId, "starters", questDialog.kind, questDialog.actor)
    C.CheckQuestActor(questId, "starters", questDialog.kind, questDialog.actor)
  end
  questDialog = nil
  if not C.CaptureObjectives(questId) then pendingObjectives[questId] = true end
end

local function rewardItems(kind, count)
  local items = {}
  for i = 1, count or 0 do
    local id = GetQuestItemLink and C.ItemIDFromLink(GetQuestItemLink(kind, i))
    if id then table.insert(items, id) end
  end
  return items
end

function C.OnQuestComplete()
  if not C.CanCollect() then return end
  local questId = GetQuestID and C.pub(GetQuestID())
  if not questId or questId == 0 then return end
  local kind, id = dialogActor()
  local quest = questRecord(questId)
  if GetTitleText then C.SetName(quest, GetTitleText()) end
  local choices = rewardItems("choice", GetNumQuestChoices and C.pub(GetNumQuestChoices()))
  local fixed = rewardItems("reward", GetNumQuestRewards and C.pub(GetNumQuestRewards()))
  if #choices + #fixed > 0 then
    quest.rewards = quest.rewards or {}
    local all = {}
    for _, v in ipairs(fixed) do table.insert(all, v) end
    for _, v in ipairs(choices) do table.insert(all, v) end
    quest.rewards.items = all
    quest.obs.choices = #choices > 0 and choices or nil
    quest.obs.fixedRewards = #fixed > 0 and fixed or nil
    for _, item in ipairs(all) do
      local rec = C.Record("items", item)
      rec.rewardOf = rec.rewardOf or {}
      local found = false
      for _, q in ipairs(rec.rewardOf) do if q == questId then found = true end end
      if not found then table.insert(rec.rewardOf, questId) end
    end
  end
  turnInDialog = { id = questId, kind = kind, actor = id }
end

function C.OnQuestTurnedIn(questId, xp)
  questId = C.pub(questId)
  C.Log("quest turned in: %s (completion dialog %s)", tostring(questId), turnInDialog and tostring(turnInDialog.id) or "none")
  if not questId or not C.CanCollect() then return end
  local quest = questRecord(questId)
  C.Inc(quest.obs, "turnedIn")
  xp = C.pub(xp)
  local level = UnitLevel and C.pub(UnitLevel("player"))
  if xp and level then C.Sub(quest.obs, "xp")[level] = xp end
  C.CheckQuest(questId)
  if turnInDialog and turnInDialog.id == questId and turnInDialog.kind and turnInDialog.kind ~= "items" then
    addActor(quest, questId, "finishers", turnInDialog.kind, turnInDialog.actor)
    C.CheckQuestActor(questId, "finishers", turnInDialog.kind, turnInDialog.actor)
  end
  turnInDialog = nil
end

-------------------------------------------------------------------------------------------
-- Kills and loot
-------------------------------------------------------------------------------------------

-- Loot opened right after one of these casts is not regular loot.
local LOOT_MODES = {
  [921] = "pickpocket",
  [8613] = "skinning", [8617] = "skinning", [8618] = "skinning", [10768] = "skinning",
}

local function countKill(guid)
  if killed[guid] then return end
  local kind, id = C.ParseGUID(guid)
  if kind ~= "npcs" then return end
  killed[guid] = true
  C.Inc(C.Record("npcs", id).obs, "kills")
  if C.TagInstanceNpc then C.TagInstanceNpc(id) end
end

local function flushKills()
  if InCombatLockdown and InCombatLockdown() then return end
  for i = #pendingKills, 1, -1 do
    countKill(table.remove(pendingKills, i))
  end
end

function C.OnCombatLog()
  local _, sub, _, source, _, _, _, dest = CombatLogGetCurrentEventInfo()
  sub, source, dest = C.pub(sub), C.pub(source), C.pub(dest)
  if sub ~= "PARTY_KILL" or not dest then return end
  local player = UnitGUID("player")
  local pet = UnitGUID("pet")
  if source == player or (pet and source == pet) then
    C.cleuKills = true
    table.insert(pendingKills, dest)   -- counted once out of combat
  end
end

-- Fallback when the combat log is not available to addons: "%s dies, you gain %d experience."
function C.OnXPGain(msg)
  if C.cleuKills or type(msg) ~= "string" or not COMBATLOG_XPGAIN_FIRSTPERSON then return end
  local pattern = "^" .. COMBATLOG_XPGAIN_FIRSTPERSON:gsub("([%(%)%.%-%+%*%?%[%]%^])", "%%%1")
    :gsub("%%s", "(.+)"):gsub("%%d", "%%d+")
  local name = msg:match(pattern)
  local guid = name and guidByName[name]
  if guid then table.insert(pendingKills, guid) end
end

local function lootMode()
  if IsFishingLoot and C.pub(IsFishingLoot()) then return "fishing" end
  if lastSpell and now() - lastSpell.t < 3 then return LOOT_MODES[lastSpell.id] or "loot" end
  return "loot"
end

local function sourceRecord(guid)
  local kind, id = C.ParseGUID(guid)
  if kind == "items" then
    if lastContainer and now() - lastContainer.t < 5 then return "items", lastContainer.id end
    return nil
  end
  return kind, id
end

function C.OnLootOpened()
  if not C.CanCollect() or not GetNumLootItems then return end
  local mode = lootMode()
  if mode == "fishing" then return end
  lastSpell = nil
  local slots = C.pub(GetNumLootItems()) or 0
  C.Log("loot: %d slots, mode %s", slots, mode)
  for slot = 1, slots do
    local itemId = GetLootSlotLink and C.ItemIDFromLink(GetLootSlotLink(slot))
    local sources = { GetLootSourceInfo(slot) }
    for i = 1, #sources, 2 do
      local guid = C.pub(sources[i])
      local kind, id = sourceRecord(guid)
      if kind then
        local key = guid .. mode
        local rec = C.Record(kind, id)
        if not lootedGuid[key] then
          lootedGuid[key] = true
          if mode == "loot" then
            C.Inc(rec.obs, "looted")
            if kind == "npcs" then countKill(guid) end
            if kind == "objects" then
              if not rec.name and objectNames[guid] then C.SetName(rec, objectNames[guid]) end
              if not rec.name and lastObjectTip and now() - lastObjectTip.t < 15 then C.SetName(rec, lastObjectTip.name) end
            end
            -- the player stands on the corpse or node while looting: a precise position
            if kind ~= "items" and not seenGuid[guid] then
              local area, x, y = C.PlayerPosition()
              if area then
                seenGuid[guid] = true
                rec.zone = rec.zone or area
                local _, isNew = C.AddSpawn(rec, area, x, y)
                C.Inc(rec.obs, "seen")
                if isNew then C.CheckSpawn(kind, id, area, x, y) end
              end
            end
          else
            C.Inc(rec.obs, mode)
          end
        end
        if itemId then
          lootedItems[key] = lootedItems[key] or {}
          if not lootedItems[key][itemId] then
            lootedItems[key][itemId] = true
            local field = mode == "loot" and "loot" or (mode .. "Loot")
            C.Inc(C.Sub(rec.obs, field), itemId)
            if mode == "loot" and kind ~= "items" then C.CheckDrop(kind, id, itemId) end
            C.Record("items", itemId)
          end
        end
      end
    end
  end
end

-- Turns loot counts into SPEC drop chances (percent of looted sources / kills).
function C.ComputeDrops()
  for _, kind in ipairs({ "npcs", "objects", "items" }) do
    for id, rec in pairs(C.sv[kind]) do
      local loot = rec.obs.loot
      local total = math.max(rec.obs.kills or 0, rec.obs.looted or 0)
      if loot and total > 0 then
        rec.drops = kind == "items" and rec.drops or {}
        for itemId, n in pairs(loot) do
          local chance = math.floor(n / total * 10000 + 0.5) / 100
          if kind ~= "items" then rec.drops[itemId] = chance end
          local item = C.Record("items", itemId)
          item.drops = item.drops or {}
          C.Sub(item.drops, kind)[id] = chance
        end
      end
    end
  end
end

-------------------------------------------------------------------------------------------
-- Tooltip names (objects) and subnames (npcs)
-------------------------------------------------------------------------------------------

local function hookTooltips()
  if not TooltipDataProcessor or not Enum or not Enum.TooltipDataType then return end
  if Enum.TooltipDataType.Object then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Object, function(_, data)
      data = C.pubTable(data)
      local line = data and data.lines and C.pubTable(data.lines[1])
      local name = line and C.pub(line.leftText)
      if not name then return end
      lastObjectTip = { name = name, t = now() }
      local guid = C.pub(data.guid)
      if guid then objectNames[guid] = name end
    end)
  end
  TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(_, data)
    if not C.CanCollect() or not C.enUS then return end
    data = C.pubTable(data)
    local kind, id = C.ParseGUID(data and data.guid)
    if kind ~= "npcs" or not C.sv.npcs[id] then return end
    local line = data.lines and C.pubTable(data.lines[2])
    local text = line and C.pub(line.leftText)
    local levelWord = LEVEL or "Level"
    if type(text) == "string" and text ~= "" and not text:find(levelWord, 1, true) then
      C.sv.npcs[id].subName = text
    end
  end)
end

-------------------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------------------

local handlers = {}

handlers.ADDON_LOADED = function(name)
  if name ~= C.name then return end
  C.InitStore()
  C.ApplyCorrections()
  hookTooltips()
  if C_Container and C_Container.UseContainerItem and C_Container.GetContainerItemID then
    hooksecurefunc(C_Container, "UseContainerItem", function(bag, slot)
      local id = C.pub(C_Container.GetContainerItemID(bag, slot))
      if id then lastContainer = { id = id, t = now() } end
    end)
  end
  -- the combat log may be unavailable to addons on this client; kills then come from XP gains
  if CombatLogGetCurrentEventInfo then
    pcall(frame.RegisterEvent, frame, "COMBAT_LOG_EVENT_UNFILTERED")
  end
end

handlers.PLAYER_LOGIN = function()
  if C.ShowLastSummary then C.ShowLastSummary() end
end

handlers.PLAYER_LOGOUT = function()
  C.ComputeDrops()
  if C.WriteSummary then C.WriteSummary(true) end
end

handlers.PLAYER_TARGET_CHANGED = function() C.SeeUnit("target") end
handlers.UPDATE_MOUSEOVER_UNIT = function() C.SeeUnit("mouseover") end
handlers.PLAYER_REGEN_ENABLED = function()
  flushKills()
  C.FlushInstanceBosses()
end
handlers.PLAYER_ENTERING_WORLD = function()
  C.UpdateInstance()
  if RequestRaidInfo then RequestRaidInfo() end   -- answers with UPDATE_INSTANCE_INFO (lockouts)
end
handlers.ZONE_CHANGED_NEW_AREA = function() C.UpdateInstance() end
handlers.ENCOUNTER_END = function(...) C.OnEncounterEnd(...) end
handlers.INSTANCE_ENCOUNTER_ENGAGE_UNIT = function() C.ReadBossFrames() end
handlers.UPDATE_INSTANCE_INFO = function() C.ReadLockouts() end
handlers.MERCHANT_SHOW = function() C.ScanMerchant(false) end
handlers.MERCHANT_UPDATE = function() C.ScanMerchant(true) end
handlers.TAXIMAP_OPENED = function()
  local id, rec = C.Interact("FLIGHT_MASTER")
  local node = rec and taxiNodeName()
  if node then rec.obs.taxiNode = node end
end
handlers.QUEST_DETAIL = C.OnQuestDetail
handlers.QUEST_ACCEPTED = C.OnQuestAccepted
handlers.QUEST_PROGRESS = function() C.Interact() end
handlers.QUEST_COMPLETE = C.OnQuestComplete
handlers.QUEST_TURNED_IN = C.OnQuestTurnedIn
handlers.QUEST_LOG_UPDATE = function()
  if not C.CanCollect() then return end
  for questId in pairs(pendingObjectives) do
    if C.CaptureObjectives(questId) then pendingObjectives[questId] = nil end
  end
end
-- auto-loot addons (SpeedyAutoLoot, ...) empty the window during LOOT_READY, before
-- LOOT_OPENED; read it at both (corpses and items are counted once)
handlers.LOOT_READY = C.OnLootOpened
handlers.LOOT_OPENED = C.OnLootOpened
handlers.COMBAT_LOG_EVENT_UNFILTERED = C.OnCombatLog
handlers.CHAT_MSG_COMBAT_XP_GAIN = function(msg)
  C.OnXPGain(C.pub(msg))
  flushKills()
end
handlers.UNIT_SPELLCAST_SUCCEEDED = function(unit, _, spellId)
  if unit == "player" then
    spellId = C.pub(spellId)
    if spellId then lastSpell = { id = spellId, t = now() } end
  end
end

for event, flag in pairs(SERVICE_EVENTS) do
  handlers[event] = function() C.Interact(flag) end
end

local QUIET = { UPDATE_MOUSEOVER_UNIT = true, PLAYER_TARGET_CHANGED = true, QUEST_LOG_UPDATE = true,
  UNIT_SPELLCAST_SUCCEEDED = true, COMBAT_LOG_EVENT_UNFILTERED = true, MERCHANT_UPDATE = true }

frame:SetScript("OnEvent", function(_, event, ...)
  if event ~= "ADDON_LOADED" and not C.sv then return end
  if not QUIET[event] then C.Log("event %s", event) end
  local ok, err = pcall(handlers[event], ...)
  if not ok and geterrorhandler then geterrorhandler()("NorgannonDBCollector " .. event .. ": " .. tostring(err)) end
end)

-- Some events from older clients (e.g. PETITION_VENDOR_SHOW) do not exist on Forever;
-- registering an unknown event raises an error, so only register what the client knows.
local function IsKnownEvent(event)
  if C_EventUtils and C_EventUtils.IsEventValid then
    return C_EventUtils.IsEventValid(event)
  end
  return true
end

for event in pairs(handlers) do
  if event ~= "COMBAT_LOG_EVENT_UNFILTERED" and IsKnownEvent(event) then
    pcall(frame.RegisterEvent, frame, event)
  end
end
