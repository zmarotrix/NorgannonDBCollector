-- Optional API watch: helps document the game's add-on API for add-on authors (ForeverAPI). Off unless the
-- player switches it on with /ndbc api.
--
-- Adapted from ForeverAPI's ApiWatch. A situation is where you are and what is happening: "party/boss" is a dungeon
-- boss fight, "raid/idle" standing in a raid. The first time the watch sees a situation it calls the game's
-- no-argument getters once; the first time it sees a kind of unit there (an enemy NPC target, a party member, a
-- boss...) it calls the unit getters on it, a few per frame. It also logs when add-on restrictions switch on and
-- off. It stores result shapes (types, secret or not, errors), never a value, so nothing about you or anyone else.
-- It never calls a Cancel*/UnitSet*/Request*/Reward* name, anything that crashed the client, or anything refused.
--
-- Saved in NorgannonDBCollectorDB.api and shared with the rest of the finds; tools/norgannondb/import_collected.py
-- passes it to ForeverAPI.

local C = NorgannonDBCollector

local VERSION = "1"
local PER_FRAME = 8          -- calls per frame while a run is going: a few, so a frame never notices
local MAX_KEYS = 30
local MAX_TRANSITIONS = 400

local G = _G
local rawget, pcall, type, select, pairs, ipairs = rawget, pcall, type, select, pairs, ipairs
local issecretvalue = rawget(G, "issecretvalue")
local function isSecret(v) return issecretvalue ~= nil and issecretvalue(v) == true end
local function serverTime() return (rawget(G, "GetServerTime") or time)() end
local function inCombat() return InCombatLockdown and InCombatLockdown() and true or false end
local function buildKey()
  local version, build = GetBuildInfo()
  return tostring(version) .. "." .. tostring(build)
end
local function errText(e)
  if isSecret(e) then return "<secret error>" end
  e = tostring(e):gsub("Interface[\\/]AddOns[\\/]NorgannonDBCollector[\\/][^:]*:%d+: ", "")
  return #e > 200 and e:sub(1, 200) .. "..." or e
end

local db, leads
local plainPlan, unitPlan = {}, {}
local job, currentCall, forbiddenHit, encounter = nil, nil, nil, false
local lastRestrictions

-------------------------------------------------------------------------------------------
-- What to call
-------------------------------------------------------------------------------------------

local function buildPlans()
  leads = rawget(G, "NorgannonDBCollectorApiLeads") or { calls = {} }
  for _, c in ipairs(leads.calls or {}) do
    local key = c[1] and (c[1] .. "." .. c[2]) or c[2]
    if c[3] == nil then plainPlan[#plainPlan + 1] = { key = key, ns = c[1], fn = c[2] }
    elseif c[3] == "unit" then unitPlan[#unitPlan + 1] = { key = key, ns = c[1], fn = c[2] } end
  end
  for _, name in ipairs(leads.undocumented or {}) do
    if name:find("^Unit") then unitPlan[#unitPlan + 1] = { key = name, fn = name }
    else plainPlan[#plainPlan + 1] = { key = name, fn = name } end
  end
  leads.calls, leads.undocumented = nil, nil   -- the plans hold what's needed
end

local function skipped(key)
  local crash = leads.crashers or {}
  if crash[key] then return "crashed the client" end
  local ns = key:match("^([%w_]+)%.")
  if ns and crash[ns .. "."] then return "crashed the client (whole namespace skipped)" end
  if leads.refused and leads.refused[key] then return "refused to the probe" end
  if db.skip[key] then return db.skip[key] end
end

-------------------------------------------------------------------------------------------
-- Situations and units
-------------------------------------------------------------------------------------------

local function situation()
  local _, zone = IsInInstance()
  local phase = encounter and "boss" or inCombat() and "combat" or "idle"
  return (zone or "none") .. "/" .. phase
end

local function plainBool(f, ...)
  local ok, v = pcall(f, ...)
  if not ok or isSecret(v) then return nil end
  return v and true or false
end

local function unitKind(token)
  if not plainBool(UnitExists, token) then return nil end
  local slot = token:gsub("%d+", "")
  if slot == "player" or slot == "party" or slot == "raid" or slot == "pet" then return slot end
  local isPlayer = plainBool(UnitIsPlayer, token)
  local enemy = plainBool(UnitCanAttack, "player", token)
  local who = (enemy == nil and "unknown") or (enemy and "enemy" or "friendly")
  who = who .. " " .. (isPlayer == nil and "?" or isPlayer and "player" or "npc")
  return slot .. ": " .. who
end

local function candidates()
  local out = { "player", "target", "focus", "pet", "targettarget", "party1", "raid1", "boss1" }
  for i = 1, 40 do
    if plainBool(UnitExists, "nameplate" .. i) then out[#out + 1] = "nameplate" .. i break end
  end
  return out
end

local function restrictionsNow()
  local ra = rawget(G, "C_RestrictedActions")
  local E = rawget(G, "Enum") and Enum.AddOnRestrictionType
  if not (ra and ra.IsAddOnRestrictionActive and E) then return "unavailable" end
  local on = {}
  for key, value in pairs(E) do
    local ok, v = pcall(ra.IsAddOnRestrictionActive, value)
    if not ok then on[#on + 1] = key .. "=error"
    elseif isSecret(v) then on[#on + 1] = key .. "=secret"
    elseif v then on[#on + 1] = key end
  end
  table.sort(on)
  return #on > 0 and table.concat(on, ",") or "none"
end

local function noteRestrictions(reason)
  local now = restrictionsNow()
  if now == lastRestrictions then return end
  lastRestrictions = now
  local list = db.transitions
  list[#list + 1] = { at = serverTime(), on = now, situation = situation(), reason = reason }
  while #list > MAX_TRANSITIONS do table.remove(list, 1) end
end

-------------------------------------------------------------------------------------------
-- Runs
-------------------------------------------------------------------------------------------

local function shape(v)
  if isSecret(v) then
    local ok, t = pcall(type, v)
    return "secret:" .. (ok and t or "?")
  end
  local t = type(v)
  if t ~= "table" then return t end
  local keys, n = {}, 0
  local ok = pcall(function()
    for k, val in pairs(v) do
      n = n + 1
      if n <= MAX_KEYS then
        keys[#keys + 1] = (isSecret(k) and "<secret key>" or type(k) == "string" and k or "[" .. type(k) .. "]") .. "=" .. (isSecret(val) and "secret" or type(val))
      end
    end
  end)
  if not ok then return "table:unreadable" end
  table.sort(keys)
  if n > MAX_KEYS then keys[#keys + 1] = "...(" .. n .. ")" end
  return "table{" .. table.concat(keys, ",") .. "}"
end

local function capture(ok, ...)
  if not ok then return { error = errText((...)) } end
  local n = select("#", ...)
  local out = { n = n }
  for i = 1, math.min(n, 20) do out[i] = shape((select(i, ...))) end
  return out
end

local function startRun(sit, label, token, plan)
  local s = db.situations[sit] or { runs = {} }
  db.situations[sit] = s
  local run = { at = serverTime(), token = token, results = {} }
  s.runs[label] = run
  job = { situation = sit, label = label, token = token, plan = plan, i = 1, run = run }
end

local function stopRun(why)
  job.run.partial = why
  job = nil
end

local function step()
  if situation() ~= job.situation then stopRun("situation changed") return end
  if job.token and job.token ~= "player" and not plainBool(UnitExists, job.token) then stopRun("unit gone") return end
  local last = math.min(job.i + PER_FRAME - 1, #job.plan)
  for i = job.i, last do
    local c = job.plan[i]
    local callKey = c.key
    local why = skipped(callKey)
    local rec
    if why then
      rec = { skipped = why }
    else
      local fn
      if c.ns then
        local t = rawget(G, c.ns)
        fn = type(t) == "table" and rawget(t, c.fn)
      else
        fn = rawget(G, c.fn)
      end
      if type(fn) ~= "function" then
        rec = { missing = true }
      else
        currentCall, forbiddenHit = callKey, nil
        if job.token then rec = capture(pcall(fn, job.token)) else rec = capture(pcall(fn)) end
        currentCall = nil
        if forbiddenHit then rec.forbidden = true end
      end
    end
    job.run.results[callKey] = rec
  end
  job.i = last + 1
  if job.i > #job.plan then
    job.run.done = true
    job = nil
  end
end

local function nextRun()
  local sit = situation()
  local s = db.situations[sit]
  local function done(label) return s and s.runs[label] and s.runs[label].done end
  -- the open world's plain getters are documented already; everywhere else, once per situation
  if sit ~= "none/idle" and sit ~= "none/combat" and not done("getters") then
    return sit, "getters", nil, plainPlan
  end
  for _, token in ipairs(candidates()) do
    local kind = unitKind(token)
    if kind and not done(kind) then return sit, kind, token, unitPlan end
  end
end

local idle = 0
local function tick(elapsed)
  if job then step() return end
  idle = idle + elapsed
  if idle < 1 then return end
  idle = 0
  local sit, label, token, plan = nextRun()
  if sit then startRun(sit, label, token, plan) end
end

-------------------------------------------------------------------------------------------
-- Wiring
-------------------------------------------------------------------------------------------

local frame = CreateFrame("Frame")
local EVENTS = { "ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN", "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA",
  "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "ENCOUNTER_START", "ENCOUNTER_END", "CHALLENGE_MODE_START",
  "CHALLENGE_MODE_COMPLETED", "PVP_MATCH_ACTIVE", "PVP_MATCH_COMPLETE", "GROUP_ROSTER_UPDATE", "ADDON_RESTRICTION_STATE_CHANGED" }

local function onEvent(_, event, a1)
  if event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
    if a1 == "NorgannonDBCollector" and currentCall then
      forbiddenHit = true
      db.skip[currentCall] = event == "ADDON_ACTION_FORBIDDEN" and "forbidden" or "blocked"
    end
    return
  end
  if event == "ENCOUNTER_START" then encounter = true
  elseif event == "ENCOUNTER_END" or event == "PLAYER_ENTERING_WORLD" then encounter = false end
  noteRestrictions(event)
end

local running = false

local function start()
  if running then return end
  if not next(plainPlan) and not next(unitPlan) then buildPlans() end
  local sv = C.sv
  if type(sv.api) ~= "table" or sv.api.build ~= buildKey() or sv.api.watch ~= VERSION or sv.api.leads ~= leads.build then
    sv.api = { build = buildKey(), watch = VERSION, leads = leads.build, situations = {}, transitions = {}, skip = {} }
  end
  db = sv.api
  db.skip = db.skip or {}
  for _, e in ipairs(EVENTS) do pcall(frame.RegisterEvent, frame, e) end -- the last may not exist on this client
  frame:SetScript("OnEvent", onEvent)
  frame:SetScript("OnUpdate", function(_, elapsed) tick(elapsed) end)
  running = true
end

local function stop()
  frame:UnregisterAllEvents()
  frame:SetScript("OnUpdate", nil)
  frame:SetScript("OnEvent", nil)
  if job then stopRun("switched off") end
  running = false
end

-- called by Collect.lua at PLAYER_LOGIN, once the saved data is ready
function C.ApiWatchInit()
  if C.sv.settings.apiWatch then
    start()
  else
    NorgannonDBCollectorApiLeads = nil   -- not needed: let it go
  end
end

-- /ndbc api [on|off]
function C.ApiWatchCommand(arg)
  local settings = C.sv.settings
  if arg == "on" or arg == "off" then
    settings.apiWatch = arg == "on"
    if settings.apiWatch then
      if not rawget(G, "NorgannonDBCollectorApiLeads") and not next(plainPlan) then
        C.Print("API watch: on after /reload")
        return
      end
      start()
    else
      stop()
    end
  end
  local n = 0
  for _ in pairs(C.sv.api and C.sv.api.situations or {}) do n = n + 1 end
  C.Print(("API watch is %s. It helps document the game for add-on authors: it notes how the game's functions behave "
    .. "in dungeons, raids and fights, never any values. %d situation(s) seen. /ndbc api %s")
    :format(settings.apiWatch and "on" or "off", n, settings.apiWatch and "off" or "on"))
end
