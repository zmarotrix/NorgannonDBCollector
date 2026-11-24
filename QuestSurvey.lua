-- Quest XP survey (/ndbc questxp): WoW Forever pays more XP than Classic for many quests, dungeon quests
-- above all, and only the server knows how much. Asking it about a quest (C_QuestLog.RequestLoadQuestByID)
-- makes the client keep the answer, the quest's XP difficulty and multiplier included, in
-- Cache/WDB/<locale>/questcache.wdb, where tools/norgannondb/client_questxp.py reads it once the game has
-- closed. Switched on, this asks about every NorgannonDB quest once per game build (the client empties its
-- cache when the game patches) and again when NorgannonDB gains quests: a few at a time, never in combat,
-- skipping quests the client already has and ones the server said this build it doesn't have. It is for
-- whoever builds NorgannonDB, so it is off until switched on. It saves only how far it got:
--
--   sv.questSurvey = { build = "70959", quests = "6103:<sum of ids>" (NorgannonDB's quest list),
--                      next = questId to ask next, asked = n, cached = n (already in the client),
--                      unknown = { questIds the server said it doesn't have }, skipped = n (of those, not
--                      asked again), lost = n (no answer), done = true }

local C = NorgannonDBCollector
local DB = NorgannonDB

local PER_SECOND = 5    -- requests a second at most
local IN_FLIGHT = 4     -- unanswered requests at once
local TIMEOUT = 10      -- seconds: an unanswered request is given up on

local frame = CreateFrame("Frame")
frame:Hide()
C.questSurveyFrame = frame

local ids, idsFor, stamp, pos, pending, waited = nil, nil, nil, 1, {}, 0
local skip, skipFor = {}, nil

local function now() return GetTime and GetTime() or 0 end
local function clientBuild()
  local _, build = GetBuildInfo()
  return tostring(build)
end
local function available()
  return C_QuestLog and C_QuestLog.RequestLoadQuestByID and true or false
end

local function questIds()
  if not ids or idsFor ~= DB.quests then
    ids, idsFor = {}, DB.quests
    local sum = 0
    for id in pairs(DB.quests) do
      if type(id) == "number" and id > 0 then ids[#ids + 1] = id; sum = sum + id end
    end
    table.sort(ids)
    stamp = #ids .. ":" .. sum
  end
  return ids
end

-- This build's survey of this NorgannonDB, started again when the game has patched or NorgannonDB has
-- changed. A new game build empties the client's cache, so everything is asked again. A new NorgannonDB
-- with the same game build only needs its new quests asked: the client still has the rest, and what the
-- server said it doesn't have still holds.
local function state()
  local s = C.sv.questSurvey
  local build = clientBuild()
  questIds()
  if type(s) ~= "table" or s.build ~= build or s.quests ~= stamp then
    local unknown = type(s) == "table" and s.build == build and type(s.unknown) == "table" and s.unknown or {}
    s = { build = build, quests = stamp, next = 0, asked = 0, cached = 0, skipped = 0, lost = 0, unknown = unknown }
    C.sv.questSurvey = s
  end
  return s
end

-- Quests the server already said it doesn't have (in an earlier pass with this build): not asked again.
local function known(s)
  if skipFor ~= s then
    skip, skipFor = {}, s
    for _, id in ipairs(s.unknown) do skip[id] = true end
  end
  return skip
end

-- The quest to start from next time: the lowest one still waiting for an answer, else the next to ask.
local function cursor()
  local low = ids and ids[pos]
  for id in pairs(pending) do
    if not low or id < low then low = id end
  end
  return low
end

local function count(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

local function finish(s)
  frame:Hide()
  s.done, s.next = true, nil
  C.Print(("quest XP survey done: asked about %d quests (%d already known to the client, %d the server doesn't have)."
    .. " Exit the game so it saves them, then run tools/norgannondb/client_questxp.py.")
    :format(s.asked, s.cached, #s.unknown))
end

local function step()
  local s = state()
  local t = now()
  for id, asked in pairs(pending) do
    if t - asked > TIMEOUT then
      pending[id] = nil
      s.lost = s.lost + 1
    end
  end
  if not C.CanCollect() or count(pending) >= IN_FLIGHT then return end
  local list, unknown = questIds(), known(s)
  while list[pos] do
    local id = list[pos]
    pos = pos + 1
    s.next = list[pos]
    -- a quest the client already has needs no question (its answer is in the cache)
    local title = C_QuestLog.GetTitleForQuestID and C.pub(C_QuestLog.GetTitleForQuestID(id))
    if title and title ~= "" then
      s.cached = s.cached + 1
    elseif unknown[id] then
      s.skipped = (s.skipped or 0) + 1
    else
      pending[id] = t
      s.asked = s.asked + 1
      C_QuestLog.RequestLoadQuestByID(id)
      return
    end
  end
  if not next(pending) then finish(s) end
end

frame:SetScript("OnUpdate", function(_, elapsed)
  waited = waited + elapsed
  if waited < 1 / PER_SECOND then return end
  waited = 0
  local ok, err = pcall(step)
  if not ok then
    frame:Hide()
    if geterrorhandler then geterrorhandler()("NorgannonDBCollector quest survey: " .. tostring(err)) end
  end
end)

-- Starts (or carries on with) this build's survey when it is switched on and not done yet.
function C.QuestSurveyStart()
  if not (C.sv and C.sv.settings.questSurvey and available()) then return false end
  local s = state()
  if s.done then return false end
  local list = questIds()
  pos = 1
  while list[pos] and list[pos] < (s.next or 0) do pos = pos + 1 end
  wipe(pending)   -- s.next is the lowest quest left unanswered, so those are asked again
  waited = 0
  frame:Show()
  return true
end

-- "asked 1,200 of 6,103 quests" and the like, for /ndbc questxp and /ndbc stats.
function C.QuestSurveyStatus()
  if not C.sv.settings.questSurvey then return "quest XP survey off (/ndbc questxp to switch it on)" end
  if not available() then return "quest XP survey: this client can't ask the server about quests" end
  local s = state()
  local total = #questIds()
  if s.done then
    return ("quest XP survey done for build %s: %d asked, %d already known, %d unknown to the server")
      :format(s.build, s.asked, s.cached, #s.unknown)
  end
  return ("quest XP survey: %d of %d quests (%d asked, %d already known, %d unknown to the server)%s")
    :format(s.asked + s.cached + (s.skipped or 0), total, s.asked, s.cached, #s.unknown,
      C.CanCollect() and "" or "; waits while you're in combat or paused")
end

function C.QuestSurveyToggle()
  local settings = C.sv.settings
  settings.questSurvey = not settings.questSurvey
  if settings.questSurvey then
    C.QuestSurveyStart()
  else
    frame:Hide()
    local s = C.sv.questSurvey
    if s and not s.done then s.next = cursor() end
    wipe(pending)
  end
  C.Print(C.QuestSurveyStatus())
end

local handlers = {}
handlers.PLAYER_LOGIN = function() C.QuestSurveyStart() end
handlers.QUEST_DATA_LOAD_RESULT = function(questId, success)
  questId = C.pub(questId)
  if not (questId and pending[questId]) then return end   -- someone else's question
  pending[questId] = nil
  if not C.pub(success) then table.insert(state().unknown, questId) end
end
handlers.PLAYER_LOGOUT = function()
  local s = C.sv.questSurvey
  if s and not s.done and frame:IsShown() then s.next = cursor() end
end

frame:SetScript("OnEvent", function(_, event, ...)
  if not C.sv then return end
  local ok, err = pcall(handlers[event], ...)
  if not ok and geterrorhandler then geterrorhandler()("NorgannonDBCollector " .. event .. ": " .. tostring(err)) end
end)
for event in pairs(handlers) do
  local known = not C_EventUtils or not C_EventUtils.IsEventValid or C_EventUtils.IsEventValid(event)
  if known then pcall(frame.RegisterEvent, frame, event) end
end
