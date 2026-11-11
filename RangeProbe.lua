-- /ndbc rangeprobe: which range tests WoW Forever answers for nameplate units, before the
-- Collector relies on any of them to place NPCs from their nameplates (range rings). It
-- only reads: CheckInteractDistance, item range checks with items of known range, and the
-- map's size in yards. Results go to chat and to NorgannonDBCollectorDB.rangeProbe.
--
-- Stand out of combat with several NPCs' nameplates showing (and one targeted) and type it.

local C = NorgannonDBCollector

-- items whose use range is known (LibRangeCheck's tables): yards -> item ID
local RANGE_ITEMS = { [5] = 8149, [8] = 34368, [10] = 32321, [15] = 1251, [20] = 21519, [25] = 13289, [30] = 1180,
  [35] = 18904, [40] = 34471, [45] = 32698, [60] = 32825, [80] = 35278 }

local function tally(results, test, ok, value)
  local r = results[test] or { answered = 0, none = 0, secret = 0, error = 0, yes = 0 }
  results[test] = r
  if not ok then r.error = r.error + 1
  elseif value == nil then r.none = r.none + 1
  elseif issecretvalue and issecretvalue(value) then r.secret = r.secret + 1
  else
    r.answered = r.answered + 1
    if value == true or value == 1 then r.yes = r.yes + 1 end
  end
end

local function units()
  local out = { "target" }
  if C_NamePlate and C_NamePlate.GetNamePlates then
    for _, plate in ipairs(C_NamePlate.GetNamePlates() or {}) do
      local token = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
      if token then out[#out + 1] = token end
    end
  end
  return out
end

function C.RangeProbe()
  if InCombatLockdown and InCombatLockdown() then return C.Print("rangeprobe: leave combat first") end
  local results, seen = {}, 0
  local itemRange = (C_Item and C_Item.IsItemInRange) or IsItemInRange
  for _, unit in ipairs(units()) do
    if UnitExists and UnitExists(unit) and not (UnitIsPlayer and UnitIsPlayer(unit)) then
      seen = seen + 1
      tally(results, "guid", true, UnitGUID(unit))
      for index = 1, 4 do
        tally(results, "CheckInteractDistance " .. index, pcall(CheckInteractDistance, unit, index))
      end
      if itemRange then
        for yards, item in pairs(RANGE_ITEMS) do
          tally(results, ("item %d yd (%d)"):format(yards, item), pcall(itemRange, item, unit))
        end
      end
      if UnitInRange then tally(results, "UnitInRange", pcall(UnitInRange, unit)) end
    end
  end
  local uiMap = C_Map and C.pub(C_Map.GetBestMapForUnit("player"))
  local width, height
  if uiMap and C_Map.GetMapWorldSize then
    local ok, w, h = pcall(C_Map.GetMapWorldSize, uiMap)
    if ok then width, height = C.pub(w), C.pub(h) end
  end
  local _, build = GetBuildInfo()
  C.sv.rangeProbe = { build = build, units = seen, results = results, map = uiMap, mapYards = width and { width, height } }
  C.Print(("rangeprobe: %d units; map %s is %s yards"):format(seen, tostring(uiMap),
    width and ("%.0f x %.0f"):format(width, height) or "of unknown size"))
  local names = {}
  for test in pairs(results) do names[#names + 1] = test end
  table.sort(names)
  for _, test in ipairs(names) do
    local r = results[test]
    C.Print(("  %s: %d answered (%d in range), %d nil, %d secret, %d errors"):format(test, r.answered, r.yes, r.none, r.secret, r.error))
  end
  if seen == 0 then C.Print("rangeprobe: no NPC nameplates or target; turn nameplates on and stand near some NPCs") end
end
