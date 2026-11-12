-- /ndbc report, session summaries and runtime corrections.

local C = NorgannonDBCollector
local DB = NorgannonDB

local function count(t) local n = 0 for _ in pairs(t or {}) do n = n + 1 end return n end

-------------------------------------------------------------------------------------------
-- Corrections produced by tools/norgannondb/merge_collected.py (Corrections.lua)
-------------------------------------------------------------------------------------------

function C.ApplyCorrections()
  local data = _G.NorgannonDBCollector_Corrections
  C.appliedCorrections = 0
  if type(data) ~= "table" or type(data.list) ~= "table" or not C.sv.settings.applyCorrections then return end
  for _, entry in ipairs(data.list) do
    local kind, id, fields = entry[1], entry[2], entry[3]
    local ok = pcall(DB.RegisterCorrection, DB, C.name, kind, id, fields)
    if ok then C.appliedCorrections = C.appliedCorrections + 1 end
  end
end

-------------------------------------------------------------------------------------------
-- Summaries
-------------------------------------------------------------------------------------------

function C.Stats()
  local sv = C.sv
  local s = {
    npcs = count(sv.npcs), objects = count(sv.objects), quests = count(sv.quests), items = count(sv.items),
    instances = count(sv.instances), trainers = count(sv.trainers),
    mismatches = count(sv.mismatches), newMismatches = 0, byType = {},
  }
  for _, m in pairs(sv.mismatches) do
    s.byType[m.type] = (s.byType[m.type] or 0) + 1
    if m.first == C.session then s.newMismatches = s.newMismatches + 1 end
  end
  return s
end

local function summaryLine(s)
  return string.format("%d npcs, %d objects, %d quests, %d items, %d trainers recorded; %d mismatches (%d new this session)",
    s.npcs, s.objects, s.quests, s.items, s.trainers, s.mismatches, s.newMismatches)
end

-- Stored on logout (chat is not visible then) and shown at the next login.
function C.WriteSummary(logout)
  local s = C.Stats()
  C.sv.lastSummary = { session = C.session, text = summaryLine(s), byType = s.byType }
  if logout then C.Print("session summary: " .. summaryLine(s)) end
  return s
end

function C.ShowLastSummary()
  local last = C.sv.lastSummary
  if last and last.session ~= C.session and C.sv.settings.chat then
    C.Print("last session: " .. last.text .. "  (/ndbc report)")
  end
end

-------------------------------------------------------------------------------------------
-- Report
-------------------------------------------------------------------------------------------

function C.Report(filter, limit)
  limit = limit or 15
  local list = {}
  for key, m in pairs(C.sv.mismatches) do
    if not filter or m.type == filter or m.kind == filter then
      m.key = key
      table.insert(list, m)
    end
  end
  table.sort(list, function(a, b)
    if a.n ~= b.n then return a.n > b.n end
    return a.key < b.key
  end)
  local s = C.Stats()
  C.Print(summaryLine(s))
  local types = {}
  for t, n in pairs(s.byType) do table.insert(types, t .. "=" .. n) end
  table.sort(types)
  if #types > 0 then C.Print("by type: " .. table.concat(types, ", ")) end
  for i = 1, math.min(limit, #list) do
    local m = list[i]
    local name = C.sv[m.kind] and C.sv[m.kind][m.id] and C.sv[m.kind][m.id].name
      or (DB[m.kind] and DB[m.kind][m.id] and DB:L(m.kind, m.id))
    C.Print(string.format("  %s %d %s: %s - %s (x%d)", m.kind, m.id, name and ("[" .. name .. "]") or "",
      C.MISMATCH_LABELS[m.type] or m.type, tostring(m.detail or ""), m.n))
  end
  if #list > limit then C.Print(string.format("  ... %d more (/ndbc report <type> [n])", #list - limit)) end
  return list
end

local HELP = {
  "/ndbc report [type|kind] [n] - list mismatches against NorgannonDB",
  "/ndbc stats - what has been recorded",
  "/ndbc verbose - announce each new mismatch in chat",
  "/ndbc pause - stop/resume collecting",
  "/ndbc corrections on|off - apply merged corrections at load (now: %s, %d applied)",
  "/ndbc reset - delete all collected data",
  "/ndbc share - send what you found in (copy, then paste in Discord)",
  "/ndbc reminder on|off - say once a day when you have something new to share (now: %s)",
  "/ndbc debug [show [n] | chat | clear] - log what the collector sees (saved with your data)",
}

SLASH_NORGANNONDBCOLLECTOR1 = "/ndbc"
SLASH_NORGANNONDBCOLLECTOR2 = "/azdbc" -- name before the rename
SlashCmdList["NORGANNONDBCOLLECTOR"] = function(msg)
  if not C.sv then return end
  local cmd, a, b = strsplit(" ", strtrim(msg or ""))
  cmd = cmd and cmd:lower() or ""
  local settings = C.sv.settings
  if cmd == "report" or cmd == "r" then
    local n = tonumber(a)
    C.Report(not n and a ~= "" and a or nil, n or tonumber(b))
  elseif cmd == "debug" then
    if a == "show" then
      local log = C.sv.debugLog or {}
      for i = math.max(1, #log - (tonumber(b) or 20) + 1), #log do C.Print(log[i]) end
      if #log == 0 then C.Print("debug log is empty") end
    elseif a == "chat" then
      settings.debugChat = not settings.debugChat
      C.Print("debug chat " .. (settings.debugChat and "on" or "off"))
    elseif a == "clear" then
      C.sv.debugLog = nil
      C.Print("debug log cleared")
    else
      settings.debug = not settings.debug
      C.Print("debug log " .. (settings.debug and "on: /ndbc debug show [n], /ndbc debug chat" or "off"))
    end
  elseif cmd == "share" or cmd == "export" then
    C.ShowShare()
  elseif cmd == "reminder" then
    settings.shareReminder = a ~= "off"
    C.Print("share reminder " .. (settings.shareReminder and "on" or "off"))
  elseif cmd == "stats" then
    C.Print(summaryLine(C.Stats()))
  elseif cmd == "verbose" then
    settings.verbose = not settings.verbose
    C.Print("verbose " .. (settings.verbose and "on" or "off"))
  elseif cmd == "pause" then
    settings.paused = not settings.paused
    C.Print(settings.paused and "paused" or "collecting")
  elseif cmd == "corrections" then
    settings.applyCorrections = a ~= "off"
    C.Print("corrections " .. (settings.applyCorrections and "on" or "off") .. " (takes effect after /reload)")
  elseif cmd == "rangeprobe" then
    C.RangeProbe()
  elseif cmd == "tips" then
    local p = C.sv.tipProbe
    if not p then
      C.Print("tips: no NPC tooltip read yet; hover a mob your quest needs")
    elseif not p.lineTypes then
      C.Print("tips: this client's tooltips don't say which lines are quest lines; nothing is read")
    else
      C.Print(("tips: %d NPCs hovered; %d quest titles (%d with a quest ID), %d objective lines (%d matched to the quest log)")
        :format(p.units, p.titles, p.withId, p.objectives, p.matched))
    end
  elseif cmd == "reset" then
    local keep = settings
    _G.NorgannonDBCollectorDB = nil
    C.InitStore()
    C.sv.settings = keep
    C.Print("collected data cleared")
  else
    for i, line in ipairs(HELP) do
      if i == 5 then line = line:format(settings.applyCorrections and "on" or "off", C.appliedCorrections or 0)
      elseif i == 8 then line = line:format(settings.shareReminder == false and "off" or "on") end
      C.Print(line)
    end
  end
end
