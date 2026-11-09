-- /ndbc share (and its old name /ndbc export): the collected data as one code to copy into
-- Discord, for tools/norgannondb/import_collected.py.
--
--   NDBC:1:C:<base64>   CBOR, compressed, Base64 (C_EncodingUtil, modern clients)
--   NDBC:1:L:<base64>   Lua table literal, Base64 (fallback when C_EncodingUtil is missing)
--
-- The payload carries no player names or GUIDs: the store never records players, and the
-- contributor field is a random ID made once per account so imports can tell submitters apart.

local C = NorgannonDBCollector

C.EXPORT_FORMAT = 1
local EXPORTED = { "schema", "meta", "npcs", "objects", "quests", "items", "instances", "mismatches" }

local function contributorId()
  local settings = C.sv.settings
  if not settings.contributor then
    local hex = {}
    for i = 1, 16 do hex[i] = string.format("%x", math.random(0, 15)) end
    settings.contributor = table.concat(hex)
  end
  return settings.contributor
end

function C.ExportPayload()
  C.ComputeDrops()
  local payload = { format = C.EXPORT_FORMAT, contributor = contributorId(), exported = time and time() or 0 }
  for _, key in ipairs(EXPORTED) do payload[key] = C.sv[key] end
  return payload
end

-------------------------------------------------------------------------------------------
-- Fallback encoding (pure Lua)
-------------------------------------------------------------------------------------------

local function serialize(value, out)
  local t = type(value)
  if t == "table" then
    out[#out + 1] = "{"
    for k, v in pairs(value) do
      if type(k) == "number" then
        out[#out + 1] = "[" .. string.format("%.17g", k) .. "]="
      else
        out[#out + 1] = "[" .. string.format("%q", tostring(k)) .. "]="
      end
      serialize(v, out)
      out[#out + 1] = ","
    end
    out[#out + 1] = "}"
  elseif t == "string" then
    out[#out + 1] = string.format("%q", value)
  elseif t == "number" then
    out[#out + 1] = string.format("%.17g", value)
  elseif t == "boolean" then
    out[#out + 1] = tostring(value)
  else
    out[#out + 1] = "nil"
  end
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64(data)
  local out, n = {}, #data
  for i = 1, n, 3 do
    local a, b, c = data:byte(i, i + 2)
    local v = a * 65536 + (b or 0) * 256 + (c or 0)
    local c1, c2 = math.floor(v / 262144) % 64, math.floor(v / 4096) % 64
    local c3, c4 = math.floor(v / 64) % 64, v % 64
    out[#out + 1] = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1)
      .. (b and B64:sub(c3 + 1, c3 + 1) or "=") .. (c and B64:sub(c4 + 1, c4 + 1) or "=")
  end
  return table.concat(out)
end

-------------------------------------------------------------------------------------------
-- Encode
-------------------------------------------------------------------------------------------

local function nativeEncoding()
  local E = C_EncodingUtil
  return E and E.SerializeCBOR and E.CompressString and E.EncodeBase64 and E
end

function C.ExportString()
  local payload = C.ExportPayload()
  local E = nativeEncoding()
  if E then
    local ok, encoded = pcall(function()
      return E.EncodeBase64(E.CompressString(E.SerializeCBOR(payload)))
    end)
    if ok and type(encoded) == "string" and encoded ~= "" then
      return "NDBC:" .. C.EXPORT_FORMAT .. ":C:" .. encoded
    end
  end
  local out = {}
  serialize(payload, out)
  return "NDBC:" .. C.EXPORT_FORMAT .. ":L:" .. base64(table.concat(out))
end

-------------------------------------------------------------------------------------------
-- Share window: the code is selected and focused, so Ctrl+C is all it takes. Players never
-- see what the code is made of; the window talks in two plain steps.
-------------------------------------------------------------------------------------------

C.SHARE_CHANNEL = "#share-finds"

local window

-- suite design language: dark stone, a thin gold rule, parchment title, the addon's accent
local ICON = "Interface\\AddOns\\NorgannonDBCollector\\media\\icon"
local GOLD = { 0.61, 0.48, 0.24 }
local DONE = { 0.45, 0.85, 0.5 }

local function plural(n, word)
  return n .. " " .. word .. (n == 1 and "" or "s")
end

-- Finds (what NorgannonDB has wrong or missing) first noticed since the last share.
function C.UnsharedFinds()
  local since = C.sv.meta.sharedSession or 0
  local n = 0
  for _, m in pairs(C.sv.mismatches) do
    if (m.first or 0) > since then n = n + 1 end
  end
  return n
end

local function markShared()
  C.sv.meta.lastShare = time and time() or 0
  C.sv.meta.sharedSession = C.session
  if window and not window.copied then
    window.copied = true
    window.step1:SetText("1. Copied!")
    window.step1:SetTextColor(DONE[1], DONE[2], DONE[3])
  end
end
C.MarkShared = markShared

local function createWindow()
  local f = CreateFrame("Frame", "NorgannonDBCollectorShare", UIParent, "BackdropTemplate")
  f:SetSize(560, 270)
  f:SetPoint("CENTER")
  f:SetFrameStrata("DIALOG")
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  if f.SetBackdrop then
    f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    f:SetBackdropColor(0.075, 0.062, 0.048, 0.97)
    f:SetBackdropBorderColor(GOLD[1], GOLD[2], GOLD[3], 1)
  end

  f.icon = f:CreateTexture(nil, "ARTWORK")
  f.icon:SetSize(34, 34)
  f.icon:SetPoint("TOPLEFT", 12, -10)
  f.icon:SetTexture(ICON)

  f.kicker = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  f.kicker:SetPoint("TOPLEFT", f.icon, "TOPRIGHT", 10, -1)
  f.kicker:SetText("NORGANNONDB COLLECTOR")
  f.kicker:SetTextColor(0.91, 0.78, 0.42)

  f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  f.title:SetPoint("TOPLEFT", f.kicker, "BOTTOMLEFT", 0, -2)
  f.title:SetText("Share your finds")
  f.title:SetTextColor(0.97, 0.91, 0.75)

  f.x = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  f.x:SetPoint("TOPRIGHT", 2, 2)

  f.rule = f:CreateTexture(nil, "ARTWORK")
  f.rule:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 0.45)
  f.rule:SetHeight(1)
  f.rule:SetPoint("TOPLEFT", 10, -52)
  f.rule:SetPoint("TOPRIGHT", -10, -52)

  f.stats = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.stats:SetPoint("TOPLEFT", 18, -64)
  f.stats:SetWidth(524)
  f.stats:SetJustifyH("LEFT")
  f.stats:SetTextColor(C.ACCENT_RGB[1], C.ACCENT_RGB[2], C.ACCENT_RGB[3])

  f.step1 = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightHuge")
  f.step1:SetPoint("TOPLEFT", f.stats, "BOTTOMLEFT", 0, -14)
  f.step1:SetJustifyH("LEFT")

  f.step2 = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  f.step2:SetPoint("TOPLEFT", f.step1, "BOTTOMLEFT", 0, -10)
  f.step2:SetWidth(524)
  f.step2:SetJustifyH("LEFT")

  f.note = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.note:SetPoint("TOPLEFT", f.step2, "BOTTOMLEFT", 0, -10)
  f.note:SetWidth(524)
  f.note:SetJustifyH("LEFT")
  f.note:SetTextColor(0.78, 0.74, 0.66)
  f.note:SetText("No character names are in it. Share again whenever you like: the newest one replaces your last.")

  -- the code itself: small and dim, always selected; typing puts it back
  f.box = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
  f.box:SetPoint("BOTTOMLEFT", 24, 48)
  f.box:SetPoint("BOTTOMRIGHT", -18, 48)
  f.box:SetHeight(22)
  f.box:SetAutoFocus(false)
  f.box:SetMaxLetters(0)
  f.box:SetTextColor(0.6, 0.57, 0.5)
  f.box:SetScript("OnTextChanged", function(self, userInput)
    if userInput and window.text then
      self:SetText(window.text)
      self:HighlightText()
    end
  end)
  f.box:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
  f.box:SetScript("OnEscapePressed", function() f:Hide() end)
  f.box:SetScript("OnKeyDown", function(_, key)
    if (key == "C" or key == "c") and IsControlKeyDown and IsControlKeyDown() then markShared() end
  end)
  -- a click anywhere on the window selects the code again
  f:SetScript("OnMouseDown", function() f.box:SetFocus(); f.box:HighlightText() end)

  f.close = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  f.close:SetSize(210, 26)
  f.close:SetPoint("BOTTOMRIGHT", -14, 12)
  f.close:SetText("Copied? You're done here")
  f.close:SetScript("OnClick", function() markShared(); f:Hide() end)

  table.insert(UISpecialFrames, "NorgannonDBCollectorShare")
  return f
end

function C.ShowShare()
  local text = C.ExportString()
  window = window or createWindow()
  C.shareWindow = window
  window.text = text
  window.copied = nil
  local s = C.Stats()
  local new = C.UnsharedFinds()
  if s.mismatches == 0 then
    window.stats:SetText("Nothing new found yet, but what you've seen still helps.")
  elseif new > 0 and new < s.mismatches then
    window.stats:SetText(string.format("You've found %s the database didn't know, %d of them since you last shared.",
      plural(s.mismatches, "thing"), new))
  else
    window.stats:SetText(string.format("You've found %s the database didn't know.", plural(s.mismatches, "thing")))
  end
  window.step1:SetText("1. Press Ctrl+C")
  window.step1:SetTextColor(1, 1, 1)
  window.step2:SetText("2. In Discord, open " .. C.SHARE_CHANNEL .. " and press Ctrl+V, then Enter")
  window:Show()
  window.box:SetText(text)
  window.box:SetFocus()
  window.box:SetCursorPosition(0)
  window.box:HighlightText()
  return text
end
C.ShowExport = C.ShowShare

-------------------------------------------------------------------------------------------
-- Reminder: at login, at most once a day, when something new hasn't been shared yet
-------------------------------------------------------------------------------------------

local DAY = 24 * 60 * 60

function C.ShareReminder()
  local settings = C.sv.settings
  if settings.shareReminder == false or not settings.chat then return end
  local n = C.UnsharedFinds()
  local nowT = time and time() or 0
  if n == 0 or nowT - (settings.lastShareReminder or 0) < DAY then return end
  settings.lastShareReminder = nowT
  C.Print(string.format("Found %s. Type /ndbc share to send %s in.", plural(n, "new thing"), n == 1 and "it" or "them"))
  return n
end
