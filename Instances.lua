-- Instances: which dungeon or raid you're in, the creatures and bosses there, and the real
-- lockout reset times. This is how NorgannonDB learns WoW Forever's own instances (Oracle shows
-- them once they're known) and checks the classic ones.
--
--   NorgannonDBCollectorDB.instances[instanceId] = {
--     name, type = "party" | "raid", maxPlayers, area (when NorgannonDB knows the instance),
--     npcs = { [npcId] = true }, bosses = { [npcId] = "encounter" | "bossframe" | "worldboss" },
--     encounters = { [encounterId] = { name, kills } }, lockout = { reset (seconds), seen (time) },
--     obs = { first, last, visits } }
--
-- Nothing is recorded in combat: bosses seen in a fight are queued and written when it ends.

local C = NorgannonDBCollector
local DB = NorgannonDB

C.MISMATCH_LABELS.instanceMissing = "instance not in NorgannonDB"
C.MISMATCH_LABELS.bossMissing = "boss not in NorgannonDB's instance"

local current            -- { id, name, rec } while inside an instance
local pendingBosses = {} -- { npcId, how, name } seen in combat

-------------------------------------------------------------------------------------------
-- Which instance
-------------------------------------------------------------------------------------------

-- the NorgannonDB instance keys for a game instance (by its map id, else by name)
local function knownKeys(instanceId, name)
  local out = {}
  local instances = DB.instances or {}
  local area = DB.maps and DB.maps.instanceToArea and DB.maps.instanceToArea[instanceId]
  for key, inst in pairs(instances) do
    if (area and inst.area == area) or (name and (inst.name == name or inst.groupName == name)) then
      out[#out + 1] = key
    elseif name and inst.area and DB.dungeons and DB.dungeons[inst.area] and DB.dungeons[inst.area].name == name then
      out[#out + 1] = key
    end
  end
  return out, area
end
C.InstanceKeys = knownKeys

local function record(instanceId)
  local rows = C.sv.instances
  local rec = rows[instanceId]
  if not rec then
    rec = { npcs = {}, bosses = {}, encounters = {}, obs = { first = C.session, visits = 0 } }
    rows[instanceId] = rec
  end
  rec.obs.last = C.session
  return rec
end

---Reads where we are: enters or leaves an instance record. Returns the current instance or nil.
function C.UpdateInstance()
  if not GetInstanceInfo then current = nil return nil end
  local name, itype, _, _, maxPlayers, _, _, instanceId = GetInstanceInfo()
  name, itype, maxPlayers, instanceId = C.pub(name), C.pub(itype), C.pub(maxPlayers), C.pub(instanceId)
  if not itype or itype == "none" or not instanceId then
    current = nil
    return nil
  end
  if current and current.id == instanceId then return current end
  local rec = record(instanceId)
  rec.obs.visits = (rec.obs.visits or 0) + 1
  rec.type, rec.maxPlayers = itype, maxPlayers
  if name then
    if C.enUS or not rec.name then rec.name = name end
  end
  local keys, area = knownKeys(instanceId, name)
  if area then rec.area = area end
  if #keys == 0 and (itype == "party" or itype == "raid") then
    C.Flag("instanceMissing", "instances", instanceId, name)
  end
  current = { id = instanceId, name = name, rec = rec, keys = keys }
  C.Log("instance %s (%s, %s players), NorgannonDB: %s", tostring(name), tostring(itype), tostring(maxPlayers),
    #keys > 0 and table.concat(keys, ", ") or "unknown")
  return current
end
function C.CurrentInstance() return current end

-------------------------------------------------------------------------------------------
-- Creatures and bosses
-------------------------------------------------------------------------------------------

local function bossKnown(npcId)
  for _, key in ipairs(current.keys) do
    local inst = DB.instances[key]
    for _, b in ipairs(inst and inst.bosses or {}) do
      if b.id == npcId then return true end
    end
  end
  return false
end

---A creature seen, killed or looted inside the instance.
function C.TagInstanceNpc(npcId)
  if not current or not npcId then return end
  current.rec.npcs[npcId] = true
  C.Record("npcs", npcId).instance = current.id
end

---A boss: how = "encounter" (the game's encounter ended), "bossframe" (shown in the boss frames)
---or "worldboss" (classified as one).
function C.TagInstanceBoss(npcId, how, name)
  if not current or not npcId then return end
  if InCombatLockdown and InCombatLockdown() then
    pendingBosses[#pendingBosses + 1] = { npcId, how, name }
    return
  end
  C.TagInstanceNpc(npcId)
  if not current.rec.bosses[npcId] then
    current.rec.bosses[npcId] = how
    if #current.keys > 0 and not bossKnown(npcId) then
      C.Flag("bossMissing", "npcs", npcId, (name or "?") .. " in " .. tostring(current.name), current.id)
    end
  end
  if name then C.SetName(C.Record("npcs", npcId), name) end
end

function C.FlushInstanceBosses()
  for i = 1, #pendingBosses do
    local b = pendingBosses[i]
    C.TagInstanceBoss(b[1], b[2], b[3])
  end
  wipe(pendingBosses)
end

-- the boss unit frames (boss1..boss5) name the bosses of the fight
function C.ReadBossFrames()
  if not current then return end
  for i = 1, 5 do
    local unit = "boss" .. i
    local kind, id = C.ParseGUID(UnitGUID and UnitGUID(unit))
    if kind == "npcs" then C.TagInstanceBoss(id, "bossframe", UnitName and C.pub(UnitName(unit))) end
  end
end

-------------------------------------------------------------------------------------------
-- Encounters and lockouts
-------------------------------------------------------------------------------------------

function C.OnEncounterEnd(encounterId, encounterName, _, _, success)
  encounterId, encounterName, success = C.pub(encounterId), C.pub(encounterName), C.pub(success)
  if not current or not encounterId then return end
  local e = current.rec.encounters[encounterId] or { kills = 0 }
  current.rec.encounters[encounterId] = e
  if encounterName then e.name = encounterName end
  if success == 1 or success == true then e.kills = (e.kills or 0) + 1 end
  -- the encounter's creature: the boss frame if it was shown, else the creature of that name
  C.ReadBossFrames()
  local ids = encounterName and C.IdsByName and C.IdsByName("npcs", encounterName) or {}
  if #ids == 1 then C.TagInstanceBoss(ids[1], "encounter", encounterName) end
end

-- saved instances: the real time left until each lockout resets
function C.ReadLockouts()
  if not (GetNumSavedInstances and GetSavedInstanceInfo) then return end
  local n = C.pub(GetNumSavedInstances()) or 0
  for i = 1, n do
    local name, _, reset, _, locked, _, _, isRaid, maxPlayers = GetSavedInstanceInfo(i)
    name, reset, locked = C.pub(name), C.pub(reset), C.pub(locked)
    if name and type(reset) == "number" and reset > 0 then
      for _, rec in pairs(C.sv.instances) do
        if rec.name == name then
          rec.lockout = { reset = reset, seen = time and time() or 0, raid = C.pub(isRaid) and true or nil,
            maxPlayers = C.pub(maxPlayers) }
        end
      end
    end
  end
end
