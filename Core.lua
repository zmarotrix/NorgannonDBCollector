-- NorgannonDBCollector: records what the player sees in the game world and checks it against
-- NorgannonDB. Records use the NorgannonDB SPEC.md shapes (spawns, sells, drops, starters, ...)
-- so tools/norgannondb/merge_collected.py can turn them into corrections. Evidence the SPEC has
-- no field for (sighting counts, loot counts, raw objective text) lives in each record's `obs`.

local ADDON = ...
local C = {}
_G.NorgannonDBCollector = C

C.name = ADDON or "NorgannonDBCollector"
C.DATA_VERSION = 1
C.CLUSTER = 0.6     -- map percent: sightings closer than this to a stored point are the same spawn
C.FAR = 3.0         -- map percent: a sighting farther than this from every known spawn is reported

local DB = NorgannonDB

-------------------------------------------------------------------------------------------
-- Secret values and restrictions
-------------------------------------------------------------------------------------------

-- Returns the value when an addon may read it, nil for secret values.
function C.pub(value)
  if value ~= nil and issecretvalue and issecretvalue(value) then return nil end
  return value
end

function C.pubTable(value)
  if not C.pub(value) or type(value) ~= "table" then return nil end
  if issecrettable and issecrettable(value) then return nil end
  return value
end

-- Collection is off in combat (data may be restricted and the UI must stay light) and while
-- the player has paused it.
function C.CanCollect()
  if C.sv and C.sv.settings.paused then return false end
  if InCombatLockdown and InCombatLockdown() then return false end
  return true
end

function C.InInstance()
  if not IsInInstance then return false end
  local inside = C.pub(IsInInstance())
  return inside and true or false
end

-------------------------------------------------------------------------------------------
-- GUIDs, links, positions
-------------------------------------------------------------------------------------------

-- "Creature-0-1-2-3-<npcId>-<spawnUID>", "GameObject-...", "Vehicle-...".
-- Players and pets are never recorded.
local GUID_KINDS = { Creature = "npcs", Vehicle = "npcs", GameObject = "objects" }

function C.ParseGUID(guid)
  guid = C.pub(guid)
  if type(guid) ~= "string" then return nil end
  local kind = guid:match("^(%a+)%-")
  local target = kind and GUID_KINDS[kind]
  if kind == "Item" then return "items", nil, guid end
  if not target then return nil end
  local id = tonumber(guid:match("^%a+%-%d+%-%d+%-%d+%-%d+%-(%d+)"))
  if not id or id == 0 then return nil end
  return target, id, guid
end

function C.ItemIDFromLink(link)
  link = C.pub(link)
  if type(link) ~= "string" then return nil end
  return tonumber(link:match("item:(%d+)"))
end

local function round2(v) return math.floor(v * 100 + 0.5) / 100 end

-- areaId, x, y (percent) of the player, or nil in instances / unknown maps.
function C.PlayerPosition()
  if C.InInstance() or not C_Map then return nil end
  local uiMap = C.pub(C_Map.GetBestMapForUnit("player"))
  if not uiMap then return nil end
  local area = DB.maps and DB.maps.uiMapToArea[uiMap]
  if not area then return nil, nil, nil, uiMap end
  local pos = C.pub(C_Map.GetPlayerMapPosition(uiMap, "player"))
  if not pos then return nil end
  local x, y = pos:GetXY()
  x, y = C.pub(x), C.pub(y)
  if not x or not y or x <= 0 or y <= 0 or x >= 1 or y >= 1 then return nil end
  return area, round2(x * 100), round2(y * 100), uiMap
end

-------------------------------------------------------------------------------------------
-- Saved data
-------------------------------------------------------------------------------------------

local function newStore()
  return {
    version = C.DATA_VERSION,
    schema = { major = DB.schema.major, minor = DB.schema.minor },
    settings = { applyCorrections = true, chat = true, paused = false },
    meta = { sessions = 0 },
    npcs = {}, objects = {}, quests = {}, items = {},
    mismatches = {},
  }
end

function C.InitStore()
  -- adopt data saved before the AzerothDB -> NorgannonDB rename
  if _G.NorgannonDBCollectorDB == nil and type(_G.AzerothDBCollectorDB) == "table" then
    _G.NorgannonDBCollectorDB = _G.AzerothDBCollectorDB
  end
  _G.AzerothDBCollectorDB = nil
  local sv = _G.NorgannonDBCollectorDB
  if type(sv) ~= "table" or sv.version ~= C.DATA_VERSION then
    sv = newStore()
    _G.NorgannonDBCollectorDB = sv
  end
  sv.settings = sv.settings or {}
  if sv.settings.applyCorrections == nil then sv.settings.applyCorrections = true end
  if sv.settings.chat == nil then sv.settings.chat = true end
  sv.meta = sv.meta or { sessions = 0 }
  sv.meta.sessions = (sv.meta.sessions or 0) + 1
  sv.meta.locale = GetLocale and GetLocale() or "enUS"
  local version, build, _, interface = GetBuildInfo()
  sv.meta.client = { version = version, build = build, interface = interface }
  sv.meta.db = DB.info and { generated = DB.info.generated, build = DB.info.build }
  sv.meta.lastSeen = time and time() or 0
  sv.meta.firstSeen = sv.meta.firstSeen or sv.meta.lastSeen
  for _, kind in ipairs({ "npcs", "objects", "quests", "items", "mismatches" }) do
    sv[kind] = sv[kind] or {}
  end
  C.sv = sv
  C.session = sv.meta.sessions
  C.enUS = sv.meta.locale == "enUS" or sv.meta.locale == "enGB"
  return sv
end

-- Collected record for kind/id, created on first use with an `obs` evidence table.
function C.Record(kind, id)
  local rows = C.sv[kind]
  local rec = rows[id]
  if not rec then
    rec = { obs = { first = C.session } }
    rows[id] = rec
  end
  rec.obs.last = C.session
  return rec
end

-- Names in SPEC records are enUS; other locales keep theirs as evidence only.
function C.SetName(rec, name)
  name = C.pub(name)
  if type(name) ~= "string" or name == "" or name == UNKNOWN then return end
  if C.enUS then rec.name = name else rec.obs.localName = name end
end

function C.Inc(t, key, n)
  t[key] = (t[key] or 0) + (n or 1)
end

function C.Sub(t, key)
  t[key] = t[key] or {}
  return t[key]
end

-- Adds a sighting to rec.spawns (SpawnList shape {x, y}); counts live in rec.obs.hits.
-- Returns the point and true when it is a new point.
function C.AddSpawn(rec, area, x, y)
  rec.spawns = rec.spawns or {}
  local points = C.Sub(rec.spawns, area)
  local hits = C.Sub(C.Sub(rec.obs, "hits"), area)
  for i, p in ipairs(points) do
    if math.abs(p[1] - x) <= C.CLUSTER and math.abs(p[2] - y) <= C.CLUSTER then
      hits[i] = (hits[i] or 1) + 1
      return p, false
    end
  end
  local p = { x, y }
  table.insert(points, p)
  hits[#points] = 1
  return p, true
end

-- /ndbc debug: a saved ring buffer of what the collector saw and why it skipped things,
-- readable in game (/ndbc debug show) and in the SavedVariables file.
C.LOG_SIZE = 300
function C.Log(fmt, ...)
  local sv = C.sv
  if not sv or not sv.settings.debug then return end
  local ok, line = pcall(string.format, fmt, ...)
  if not ok then line = fmt end
  local log = sv.debugLog or {}
  sv.debugLog = log
  log[#log + 1] = string.format("%s s%d %s", date and date("%H:%M:%S") or "", C.session or 0, line)
  if #log > C.LOG_SIZE then table.remove(log, 1) end
  if sv.settings.debugChat then C.Print("|cff999999" .. line .. "|r") end
end

-- brand accent (brand/README.md): emerald, inside NorgannonDB's gold
C.ACCENT_RGB = { 0.435, 0.863, 0.549 }
C.PREFIX = "|cffe7c66cNorgannonDB|r |cff6fdc8cCollector|r"

function C.Print(msg)
  if DEFAULT_CHAT_FRAME then
    DEFAULT_CHAT_FRAME:AddMessage(C.PREFIX .. ": " .. tostring(msg))
  end
end
