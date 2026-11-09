-- Runtime checks of collected observations against NorgannonDB. Each finding is stored once per
-- key in NorgannonDBCollectorDB.mismatches with a hit count, and listed by /ndbc report.

local C = NorgannonDBCollector
local DB = NorgannonDB

C.MISMATCH_LABELS = {
  missing = "not in NorgannonDB",
  spawnFar = "seen far from every known spawn",
  spawnZone = "seen in a zone with no known spawns",
  questMissing = "quest not in NorgannonDB",
  starter = "unknown quest giver",
  finisher = "unknown quest ender",
  objectiveCount = "objective count differs",
  objectiveTarget = "objective target not in quest data",
  requiredCount = "objective required count not in quest text",
  vendorItem = "vendor sells item not in NorgannonDB",
  drop = "loot not in NorgannonDB drops",
  flag = "NPC service missing from flags",
  prerequisite = "follows a quest that isn't among its prerequisites",
  trainer = "trainer teaches something NorgannonDB doesn't list for them",
  trainingMissing = "class spell missing from NorgannonDB's training list",
  trainingLevel = "learned at a different level than NorgannonDB says",
  trainingCost = "trainer price differs from NorgannonDB",
  trainingSkill = "skill needed differs from NorgannonDB",
  trainingChanged = "changed since the Collector last saw it",
}

-- Records one finding; returns the mismatch entry.
function C.Flag(mtype, kind, id, detail, extra)
  local key = mtype .. ":" .. kind .. ":" .. tostring(id) .. (extra and (":" .. tostring(extra)) or "")
  local m = C.sv.mismatches[key]
  if not m then
    m = { type = mtype, kind = kind, id = id, detail = detail, n = 0, first = C.session }
    C.sv.mismatches[key] = m
    C.newMismatches = (C.newMismatches or 0) + 1
    if C.sv.settings.chat and C.sv.settings.verbose then
      C.Print(string.format("%s %s %s: %s", kind, tostring(id), C.MISMATCH_LABELS[mtype] or mtype, tostring(detail or "")))
    end
  end
  m.n = m.n + 1
  m.last = C.session
  m.detail = detail or m.detail
  return m
end

local function contains(list, value)
  for _, v in ipairs(list or {}) do if v == value then return true end end
  return false
end

-------------------------------------------------------------------------------------------
-- Spawns
-------------------------------------------------------------------------------------------

local function nearest(points, x, y, best)
  for _, p in ipairs(points or {}) do
    if p[1] and p[1] >= 0 then
      local d = math.sqrt((p[1] - x) ^ 2 + (p[2] - y) ^ 2)
      if not best or d < best then best = d end
    end
  end
  return best
end

-- kind: "npcs" or "objects"
function C.CheckSpawn(kind, id, area, x, y)
  local rec = DB[kind][id]
  if not rec then
    return C.Flag("missing", kind, id, string.format("%s at %d %.1f,%.1f", tostring(C.sv[kind][id] and C.sv[kind][id].name), area, x, y))
  end
  local best = nearest(rec.spawns and rec.spawns[area], x, y)
  for _, path in ipairs(rec.waypoints and rec.waypoints[area] or {}) do
    best = nearest(path, x, y, best)
  end
  if not best then
    if rec.spawns and rec.spawns[area] == nil then
      return C.Flag("spawnZone", kind, id, string.format("area %d at %.1f,%.1f", area, x, y), area)
    end
  elseif best > C.FAR then
    -- one finding per ~5% grid cell so a wandering mob does not flood the list
    local cell = math.floor(x / 5) .. "/" .. math.floor(y / 5)
    return C.Flag("spawnFar", kind, id, string.format("area %d at %.1f,%.1f (%.1f%% from nearest)", area, x, y, best), area .. "@" .. cell)
  end
end

-------------------------------------------------------------------------------------------
-- Quests
-------------------------------------------------------------------------------------------

function C.CheckQuest(questId)
  if not DB.quests[questId] then
    local seen = C.sv.quests[questId]
    C.Flag("questMissing", "quests", questId, seen and seen.name)
    return nil
  end
  return DB.quests[questId]
end

-- role: "starters" or "finishers"; kind: "npcs" / "objects" / "items"
function C.CheckQuestActor(questId, role, kind, id)
  local quest = DB.quests[questId]
  if not quest or not id then return end
  local list = quest[role] and quest[role][kind]
  if contains(list, id) then return end
  local name = C.sv[kind] and C.sv[kind][id] and C.sv[kind][id].name
  C.Flag(role == "starters" and "starter" or "finisher", "quests", questId,
    string.format("%s %d (%s)", kind, id, tostring(name or "?")), kind .. id)
end

-- The NPC offered questId straight after preId was turned in.
function C.CheckChain(questId, preId)
  local quest = DB.quests[questId]
  if not quest then return end
  local known = quest.prerequisites or {}
  if contains(known.all, preId) or contains(known.any, preId) then return end
  local pre = DB.quests[preId] or C.sv.quests[preId]
  C.Flag("prerequisite", "quests", questId,
    string.format("after quest %d (%s)", preId, tostring(pre and pre.name or "?")), preId)
end

-- name -> ids index for one kind, built on first use
local nameIndex = {}
function C.IdsByName(kind, name)
  if not name then return nil end
  local index = nameIndex[kind]
  if not index then
    index = {}
    for id, rec in pairs(DB[kind]) do
      local n = DB:L(kind, id)
      if type(n) == "string" then
        index[n] = index[n] or {}
        table.insert(index[n], id)
      end
    end
    nameIndex[kind] = index
  end
  return index[name]
end

local OBJECTIVE_KINDS = { monster = "npcs", item = "items", object = "objects" }

-- Resolves an objective name to an ID: the quest's own objective entries first, then the
-- whole database by name. Returns id, matchedInQuest.
function C.ResolveObjective(questId, otype, name)
  local kind = OBJECTIVE_KINDS[otype]
  if not kind or not name then return nil end
  local quest = DB.quests[questId]
  local objectives = quest and quest.objectives
  if objectives then
    for _, entry in ipairs(objectives[kind] or {}) do
      if entry.text == name or DB:L(kind, entry.id) == name then return entry.id, true end
    end
    if kind == "npcs" then
      for _, kc in ipairs(objectives.killCredit or {}) do
        if kc.text == name or DB:L("npcs", kc.credit) == name then return kc.credit, true end
      end
    end
  end
  local ids = C.IdsByName(kind, name)
  return ids and #ids == 1 and ids[1] or nil, false
end

-- objectives: array of { text, type, name, required } as recorded
function C.CheckObjectives(questId, objectives)
  local quest = DB.quests[questId]
  if not quest then return end
  local o = quest.objectives or {}
  local dbCount = #(o.npcs or {}) + #(o.items or {}) + #(o.objects or {}) + #(o.killCredit or {})
  local seen = 0
  for _, obj in ipairs(objectives) do
    if OBJECTIVE_KINDS[obj.type] then seen = seen + 1 end
  end
  if seen ~= dbCount then
    C.Flag("objectiveCount", "quests", questId, string.format("client %d, NorgannonDB %d", seen, dbCount))
  end

  local textNumbers = {}
  for _, line in ipairs(quest.text and quest.text.objectives or {}) do
    for n in string.gmatch(line, "%d+") do textNumbers[tonumber(n)] = true end
  end
  for i, obj in ipairs(objectives) do
    if OBJECTIVE_KINDS[obj.type] and obj.name then
      local _, inQuest = C.ResolveObjective(questId, obj.type, obj.name)
      if not inQuest then
        C.Flag("objectiveTarget", "quests", questId, string.format("%s '%s'", obj.type, obj.name), i)
      end
    end
    if obj.required and obj.required > 1 and next(textNumbers) and not textNumbers[obj.required] then
      C.Flag("requiredCount", "quests", questId, string.format("'%s' needs %d", tostring(obj.name or obj.text), obj.required), i)
    end
  end
end

-------------------------------------------------------------------------------------------
-- Vendors, loot, services
-------------------------------------------------------------------------------------------

function C.CheckVendorItem(npcId, itemId)
  local npc = DB.npcs[npcId]
  if npc and not (npc.sells and npc.sells[itemId] ~= nil) then
    C.Flag("vendorItem", "npcs", npcId, "item " .. itemId, itemId)
  end
end

-- Only checked where the database has a drop table for the source at all.
function C.CheckDrop(kind, id, itemId)
  local rec = DB[kind][id]
  if rec and rec.drops and rec.drops[itemId] == nil then
    C.Flag("drop", kind, id, "item " .. itemId, itemId)
  end
end

function C.CheckFlag(npcId, flagName)
  local npc = DB.npcs[npcId]
  local flag = DB.enums and DB.enums.npcFlags and DB.enums.npcFlags[flagName]
  if npc and flag and not (npc.flags and npc.flags > 0 and DB.HasFlag(npc.flags, flag)) then
    C.Flag("flag", "npcs", npcId, flagName, flagName)
  end
end

-------------------------------------------------------------------------------------------
-- Training: trainers' lists against NorgannonDB (recipes for professions, training for
-- classes), and against what this Collector saw on an earlier client build
-------------------------------------------------------------------------------------------

local function serviceName(s)
  return s.rank and string.format("%s (Rank %d)", tostring(s.name), s.rank) or tostring(s.name)
end

-- The same service seen again: a level or a full price that moved is a change in the game.
function C.CheckServiceChange(npcId, class, spellId, old, s)
  local was, is = C.BaseCost(old.cost, old.reaction), C.BaseCost(s.cost, s.reaction)
  local changes = {}
  if old.level and s.level and old.level ~= s.level then
    changes[#changes + 1] = string.format("level %d -> %d", old.level, s.level)
  end
  if type(was) == "number" and type(is) == "number" and was ~= is then
    changes[#changes + 1] = string.format("costs %s -> %s", C.Money(was), C.Money(is))
  end
  if #changes == 0 then return end
  local builds = old.build ~= s.build and string.format(" (build %s -> %s)", tostring(old.build), tostring(s.build)) or ""
  C.Flag("trainingChanged", "npcs", npcId, string.format("%s %s: %s%s", class, serviceName(s), table.concat(changes, ", "), builds), spellId)
end

local function listed(list, value)
  if type(list) ~= "table" then return false end
  if list[value] ~= nil then return true end
  for _, v in ipairs(list) do if v == value then return true end end
  return false
end

function C.CheckService(npcId, tType, class, spellId, s)
  local base = C.BaseCost(s.cost, s.reaction)
  if tType == "profession" then
    local recipe = DB.recipes and DB.recipes[spellId]
    if not recipe then return end
    local price = recipe.trainers and recipe.trainers[npcId]
    if price == nil then
      C.Flag("trainer", "npcs", npcId, "teaches " .. serviceName(s), spellId)
    elseif type(base) == "number" and base ~= price then
      C.Flag("trainingCost", "npcs", npcId, string.format("%s costs %s, NorgannonDB says %s", serviceName(s), C.Money(base), C.Money(price)), spellId)
    end
    if recipe.learn and s.skill and s.skill[2] ~= recipe.learn then
      C.Flag("trainingSkill", "npcs", npcId, string.format("%s needs %s %d, NorgannonDB says %d", serviceName(s), tostring(s.skill[1]), s.skill[2], recipe.learn), spellId)
    end
    return
  end
  if not DB.training or next(DB.training) == nil then
    -- nothing to compare with yet (NorgannonDB before 1.5, or no class confirmed): one find per class trainer says its list is worth sharing
    return C.Flag("trainingMissing", "npcs", npcId, class .. " trainer's spells aren't in NorgannonDB yet", class)
  end
  local entry = DB.training[class] and DB.training[class][spellId]
  if not entry then
    return C.Flag("trainingMissing", "training", spellId, string.format("%s %s, level %s, %s", class, serviceName(s), tostring(s.level), C.Money(base)), class)
  end
  if s.level and entry.level and s.level ~= entry.level then
    C.Flag("trainingLevel", "training", spellId, string.format("%s %s: level %d, NorgannonDB says %d", class, serviceName(s), s.level, entry.level), class)
  end
  if type(base) == "number" and entry.cost and base ~= entry.cost then
    C.Flag("trainingCost", "training", spellId, string.format("%s %s costs %s, NorgannonDB says %s", class, serviceName(s), C.Money(base), C.Money(entry.cost)), class)
  end
  if not listed(entry.trainers, npcId) then
    C.Flag("trainer", "npcs", npcId, string.format("teaches %s %s", class, serviceName(s)), spellId)
  end
end

-- Spells learned away from a trainer (quests, books, levels): checked once NorgannonDB has the class.
function C.CheckLearned(class, spellId, rec)
  if rec.how == "trainer" or rec.how == "other" or not DB.training or not DB.training[class] then return end
  local entry = DB.training[class][spellId]
  local how = rec.how == "quest" and ("from quest " .. tostring(rec.quest)) or rec.how == "item" and ("from item " .. tostring(rec.item)) or "on levelling"
  if not entry then
    C.Flag("trainingMissing", "training", spellId, string.format("%s spell learned at level %d %s", class, rec.level, how), class)
  elseif entry.level and entry.level ~= rec.level and rec.how == "level" then
    C.Flag("trainingLevel", "training", spellId, string.format("%s spell learned at level %d, NorgannonDB says %d", class, rec.level, entry.level), class)
  end
end
