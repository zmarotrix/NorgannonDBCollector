-- Training: what trainers teach, what each class learns and at which level, and what a level-up
-- gives. Every record carries the client build it was seen on, so a rank that moves or a price
-- that changes between patches shows up as a find.
--
--   sv.trainers[npcId] = { type = "class" | "profession" | "pet", reaction = n,
--                          teaches = { [CLASS or "*"] = { [spellId] = service } }, obs = {...} }
--     service = { name, rank, level, cost, reaction, faction, skill = { name, rank }, needs = { "Name (Rank n)" }, build }
--   sv.classes[CLASS] = {
--     learned = { [spellId] = { level, how = "trainer"|"quest"|"item"|"level"|"other", npc, quest, item, race, faction, build, n } },
--     levels  = { [RACE] = { [level] = { hp, power, talents, str, agi, sta, int, spi, build } } },
--     skills  = { [skillId] = { name, first = level, max = { [level] = maxRank } } },
--   }
-- Costs are what the player paid: trainers take 5-20% off for reputation, so the trainer's
-- reaction to the player (UnitReaction, 5 = Friendly ... 8 = Exalted) is stored with each price
-- and C.BaseCost works the full price back out.

local C = NorgannonDBCollector
local DB = NorgannonDB

local frame = CreateFrame("Frame")
C.trainingFrame = frame

local TRAINER_TYPES = { [0] = "class", [2] = "profession", [3] = "pet" }
local SERVICE_TYPES = { available = true, unavailable = true, used = true, header = true }
local FILTERS = { "available", "unavailable", "used" }
local RECENT = 3               -- seconds: a spell learned this soon after a turn-in, a level-up or an item came from it

local scanning, trainerOpen, lastScan
local lastLevelUp, lastTurnIn, lastTalent

local function now() return GetTime and GetTime() or 0 end
local function build() return C.sv.meta.client and tostring(C.sv.meta.client.build) or "?" end

local function player()
  local _, class = UnitClass("player")
  local _, race = UnitRace("player")
  return C.pub(class), C.pub(race), C.pub(UnitLevel("player"))
end

-- some spells are one faction's (mage portals): each sighting says whose it was
local function faction()
  return UnitFactionGroup and C.pub((UnitFactionGroup("player"))) or nil
end

local function classData(class)
  C.sv.classes = C.sv.classes or {}
  local t = C.sv.classes[class]
  if not t then
    t = {}
    C.sv.classes[class] = t
  end
  return t
end

-------------------------------------------------------------------------------------------
-- Prices
-------------------------------------------------------------------------------------------

C.DISCOUNT = { [5] = 0.05, [6] = 0.10, [7] = 0.15, [8] = 0.20 }

-- The full price behind a discounted one: of the prices that discount to `cost`, the roundest.
function C.BaseCost(cost, reaction)
  local d = C.DISCOUNT[reaction or 0]
  if type(cost) ~= "number" or not d or cost <= 0 then return cost end
  local f = 1 - d
  local best, bestScore
  for b = math.ceil((cost - 1) / f), math.floor((cost + 1) / f) do
    if math.floor(b * f + 0.5) == cost or math.floor(b * f) == cost then
      local score, n = 0, b
      while n > 0 and n % 10 == 0 do score, n = score + 1, n / 10 end
      if not bestScore or score > bestScore then best, bestScore = b, score end
    end
  end
  return best or math.floor(cost / f + 0.5)
end

function C.Money(copper)
  if type(copper) ~= "number" then return "?" end
  local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
  local parts = {}
  if g > 0 then parts[#parts + 1] = g .. "g" end
  if s > 0 then parts[#parts + 1] = s .. "s" end
  if c > 0 or #parts == 0 then parts[#parts + 1] = c .. "c" end
  return table.concat(parts, " ")
end

-------------------------------------------------------------------------------------------
-- Trainer scan
-------------------------------------------------------------------------------------------

-- name, serviceType, rank. Forever returns name, serviceType, _, _, rank (What's Training? reads
-- it that way on this client); older clients return name, rank, serviceType, expanded.
local function serviceInfo(i)
  local a, b, c, _, e = GetTrainerServiceInfo(i)
  a, b, c, e = C.pub(a), C.pub(b), C.pub(c), C.pub(e)
  if SERVICE_TYPES[b] then return a, b, e end
  if SERVICE_TYPES[c] then return a, c, b end
  return a
end

local function spellOf(i)
  if not C_TooltipInfo or not C_TooltipInfo.GetTrainerService then return nil end
  local ok, data = pcall(C_TooltipInfo.GetTrainerService, i)
  data = ok and C.pubTable(data)
  if not data then return nil end
  local spell = Enum and Enum.TooltipDataType and Enum.TooltipDataType.Spell
  if spell and C.pub(data.type) ~= spell then return nil end
  return C.pub(data.id)
end

local function rankNumber(rank)
  rank = type(rank) == "string" and tonumber(rank:match("(%d+)"))
  return rank or nil
end

local function readService(i)
  local name, serviceType, rank = serviceInfo(i)
  if not name or serviceType == "header" then return nil end
  local spellId = spellOf(i)
  if not spellId then return nil, name end
  local s = { name = name, rank = rankNumber(rank), build = build() }
  if GetTrainerServiceLevelReq then
    local level = C.pub(GetTrainerServiceLevelReq(i))
    if type(level) == "number" and level > 0 then s.level = level end
  end
  if GetTrainerServiceCost then s.cost = C.pub(GetTrainerServiceCost(i)) end
  if GetTrainerServiceSkillReq then
    local skill, skillRank, has = GetTrainerServiceSkillReq(i)
    skill, skillRank = C.pub(skill), C.pub(skillRank)
    if type(skill) == "string" and skill ~= "" and type(skillRank) == "number" and skillRank > 0 then
      s.skill = { skill, skillRank }
    end
  end
  if GetTrainerServiceNumAbilityReq and GetTrainerServiceAbilityReq then
    local n = C.pub(GetTrainerServiceNumAbilityReq(i)) or 0
    for j = 1, n do
      local ability = C.pub(GetTrainerServiceAbilityReq(i, j))
      if type(ability) == "string" and ability ~= "" then
        s.needs = s.needs or {}
        s.needs[#s.needs + 1] = ability
      end
    end
  end
  return spellId, s
end

-- Turns on every service filter, so the scan sees what the player can't learn yet and what they
-- know already, and returns how to put the player's own filters back.
local function filterOn(f)
  local ok, on = pcall(GetTrainerServiceTypeFilter, f)
  on = ok and C.pub(on)
  return on ~= nil and on ~= false and on ~= 0
end

-- Older clients take 1/0, newer ones true/false, and an "off" answer (nil) doesn't say which:
-- try the form the client answered in first, and check that the filter really changed.
local numberForm
local function setFilter(f, on)
  local forms = numberForm == false and { on, on and 1 or 0 } or { on and 1 or 0, on }
  for _, v in ipairs(forms) do
    pcall(SetTrainerServiceTypeFilter, f, v)
    if filterOn(f) == on then
      numberForm = type(v) == "number"
      return true
    end
  end
end

local function showAll()
  if not GetTrainerServiceTypeFilter or not SetTrainerServiceTypeFilter then return function() end end
  local off = {}
  for _, f in ipairs(FILTERS) do
    local ok, raw = pcall(GetTrainerServiceTypeFilter, f)
    raw = ok and C.pub(raw)
    if type(raw) == "number" then numberForm = true elseif type(raw) == "boolean" then numberForm = false end
    if not filterOn(f) then off[#off + 1] = f end
  end
  for _, f in ipairs(off) do setFilter(f, true) end
  return function()
    for _, f in ipairs(off) do setFilter(f, false) end
  end
end

function C.ScanTrainer()
  if scanning or not C.CanCollect() or not GetNumTrainerServices then return end
  local kind, npcId = C.ParseGUID(UnitGUID and UnitGUID("npc"))
  if kind ~= "npcs" then return end
  local trainerType = C_Trainer and C_Trainer.GetTrainerType and C.pub(C_Trainer.GetTrainerType())
  local tType = TRAINER_TYPES[trainerType]
  if not tType and IsTradeskillTrainer and C.pub(IsTradeskillTrainer()) then tType = "profession" end
  tType = tType or "class"
  local class = player()
  if not class then return end

  scanning = true
  local restore = showAll()
  local ok, err = pcall(function()
    local rec = C.Record("trainers", npcId)
    rec.type = tType
    local reaction = UnitReaction and C.pub(UnitReaction("npc", "player"))
    rec.reaction = reaction
    local key = tType == "profession" and "*" or class
    local count = C.pub(GetNumTrainerServices()) or 0
    local found, unnamed = 0, 0
    for i = 1, count do
      local spellId, s = readService(i)
      if spellId then
        found = found + 1
        s.reaction = reaction
        s.faction = faction()
        rec.teaches = rec.teaches or {}
        local list = C.Sub(rec.teaches, key)
        local old = list[spellId]
        if old then C.CheckServiceChange(npcId, class, spellId, old, s) end
        if not old or old.build ~= s.build or old.level ~= s.level or old.cost ~= s.cost then
          list[spellId] = s
        end
        C.CheckService(npcId, tType, class, spellId, s)
      elseif s then
        unnamed = unnamed + 1
      end
    end
    C.Inc(rec.obs, "scans")
    C.Log("trainer %d (%s): %d services, %d with a spell ID, %d without", npcId, tType, count, found, unnamed)
  end)
  restore()
  scanning = false
  if not ok then error(err, 0) end
  lastScan = now()
end

-------------------------------------------------------------------------------------------
-- Level-ups, spells learned, skill lines
-------------------------------------------------------------------------------------------

function C.OnLevelUp(level, hp, power, talents, _, str, agi, sta, int, spi)
  if C.sv.settings.paused then return end
  local class, race = player()
  level = C.pub(level)
  if not class or not race or type(level) ~= "number" then return end
  lastLevelUp = now()
  local levels = C.Sub(classData(class), "levels")
  C.Sub(levels, race)[level] = { hp = C.pub(hp), power = C.pub(power), talents = C.pub(talents),
    str = C.pub(str), agi = C.pub(agi), sta = C.pub(sta), int = C.pub(int), spi = C.pub(spi), build = build() }
end

local function itemUsed()
  local used = C.lastContainer
  if used and now() - used.t < RECENT then return used.id end
end

function C.OnSpellLearned(spellId)
  spellId = C.pub(spellId)
  if C.sv.settings.paused or type(spellId) ~= "number" then return end
  local t = now()
  if lastTalent and t - lastTalent < RECENT then return end   -- talents are in the talent tree, not learned
  local class, race, level = player()
  if not class or not level then return end
  local how, npc, quest, item = "other"
  if trainerOpen then
    how = "trainer"
    local kind, id = C.ParseGUID(UnitGUID and UnitGUID("npc"))
    npc = kind == "npcs" and id or nil
  elseif lastTurnIn and t - lastTurnIn.t < RECENT then
    how, quest = "quest", lastTurnIn.id
  elseif itemUsed() then
    how, item = "item", itemUsed()
  elseif lastLevelUp and t - lastLevelUp < RECENT then
    how = "level"
  end
  local learned = C.Sub(classData(class), "learned")
  local rec = learned[spellId]
  if not rec or level < (rec.level or level + 1) or rec.how == "other" then
    rec = { level = level, how = how, npc = npc, quest = quest, item = item, race = race, faction = faction(),
      build = build(), n = rec and rec.n or 0 }
    learned[spellId] = rec
  end
  rec.n = (rec.n or 0) + 1
  C.CheckLearned(class, spellId, rec)
end

function C.ScanSkills()
  if not C.CanCollect() or not C_SkillInfo or not C_SkillInfo.GetNumSkillLines then return end
  local class, _, level = player()
  if not class or not level then return end
  local skills
  for i = 1, C.pub(C_SkillInfo.GetNumSkillLines()) or 0 do
    local info = C.pubTable(C_SkillInfo.GetSkillLineInfo(i))
    local id = info and C.pub(info.skillID)
    if id and id > 0 and not C.pub(info.isHeader) then
      local maxRank = C.pub(info.maxRank)
      skills = skills or C.Sub(classData(class), "skills")
      local s = skills[id]
      if not s then
        s = { name = C.pub(info.name), first = level, max = {} }
        skills[id] = s
      end
      if type(maxRank) == "number" and maxRank > 0 then
        local top, at = 0, 0
        for l, m in pairs(s.max) do if l > at then top, at = m, l end end
        if maxRank ~= top then s.max[level] = maxRank end
      end
    end
  end
end

-------------------------------------------------------------------------------------------
-- Events (a frame of its own, the same error handling as Collect.lua's)
-------------------------------------------------------------------------------------------

local handlers = {}
handlers.TRAINER_SHOW = function()
  trainerOpen = true
  C.ScanTrainer()
end
handlers.TRAINER_UPDATE = function()
  -- our own filter changes fire this while scanning; otherwise rescan at most once a second
  -- (late service names, a learned rank)
  if trainerOpen and not scanning and (not lastScan or now() - lastScan > 1) then C.ScanTrainer() end
end
handlers.TRAINER_CLOSED = function() trainerOpen = nil end
handlers.PLAYER_LEVEL_UP = C.OnLevelUp
handlers.LEARNED_SPELL_IN_SKILL_LINE = C.OnSpellLearned
handlers.LEARNED_SPELL_IN_TAB = C.OnSpellLearned
handlers.QUEST_TURNED_IN = function(questId)
  questId = C.pub(questId)
  if questId then lastTurnIn = { id = questId, t = now() } end
end
handlers.CHARACTER_POINTS_CHANGED = function() lastTalent = now() end
handlers.SKILL_LINES_CHANGED = function() C.ScanSkills() end
handlers.PLAYER_ENTERING_WORLD = function() C.ScanSkills() end

C.trainingHandlers = handlers

frame:SetScript("OnEvent", function(_, event, ...)
  if not C.sv then return end
  local ok, err = pcall(handlers[event], ...)
  if not ok and geterrorhandler then geterrorhandler()("NorgannonDBCollector " .. event .. ": " .. tostring(err)) end
end)

local seen = {}
for event in pairs(handlers) do
  -- LEARNED_SPELL_IN_TAB is the older clients' name for LEARNED_SPELL_IN_SKILL_LINE: listen to one
  local known = not C_EventUtils or not C_EventUtils.IsEventValid or C_EventUtils.IsEventValid(event)
  if known then seen[event] = true end
end
if seen.LEARNED_SPELL_IN_SKILL_LINE then seen.LEARNED_SPELL_IN_TAB = nil end
for event in pairs(seen) do pcall(frame.RegisterEvent, frame, event) end
