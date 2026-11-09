-- /ndbc export: the collected data as one copyable string, for tools/norgannondb/import_collected.py.
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
-- Copy window
-------------------------------------------------------------------------------------------

local window

-- suite design language: dark stone, a thin gold rule, parchment title, the addon's accent
local ICON = "Interface\\AddOns\\NorgannonDBCollector\\media\\icon"
local GOLD = { 0.61, 0.48, 0.24 }

local function createWindow()
  local f = CreateFrame("Frame", "NorgannonDBCollectorExport", UIParent, "BackdropTemplate")
  f:SetSize(540, 228)
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
  f.kicker:SetText("NORGANNONDB")
  f.kicker:SetTextColor(0.91, 0.78, 0.42)

  f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  f.title:SetPoint("TOPLEFT", f.kicker, "BOTTOMLEFT", 0, -2)
  f.title:SetText("Collector")
  f.title:SetTextColor(0.97, 0.91, 0.75)

  f.x = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  f.x:SetPoint("TOPRIGHT", 2, 2)

  f.rule = f:CreateTexture(nil, "ARTWORK")
  f.rule:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 0.45)
  f.rule:SetHeight(1)
  f.rule:SetPoint("TOPLEFT", 10, -52)
  f.rule:SetPoint("TOPRIGHT", -10, -52)

  f.thanks = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.thanks:SetPoint("TOPLEFT", 16, -64)
  f.thanks:SetText("Thank you for helping map Azeroth.")
  f.thanks:SetTextColor(C.ACCENT_RGB[1], C.ACCENT_RGB[2], C.ACCENT_RGB[3])

  f.stats = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  f.stats:SetPoint("TOPLEFT", f.thanks, "BOTTOMLEFT", 0, -6)
  f.stats:SetWidth(508)
  f.stats:SetJustifyH("LEFT")

  f.help = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.help:SetPoint("TOPLEFT", f.stats, "BOTTOMLEFT", 0, -8)
  f.help:SetWidth(508)
  f.help:SetJustifyH("LEFT")
  f.help:SetTextColor(0.78, 0.74, 0.66)

  f.box = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
  f.box:SetPoint("BOTTOMLEFT", 22, 46)
  f.box:SetPoint("BOTTOMRIGHT", -16, 46)
  f.box:SetHeight(24)
  f.box:SetAutoFocus(false)
  f.box:SetMaxLetters(0)
  -- read-only: typing restores the export and keeps it selected for Ctrl+C
  f.box:SetScript("OnTextChanged", function(self, userInput)
    if userInput and window.text then
      self:SetText(window.text)
      self:HighlightText()
    end
  end)
  f.box:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
  f.box:SetScript("OnEscapePressed", function() f:Hide() end)

  f.close = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  f.close:SetSize(90, 22)
  f.close:SetPoint("BOTTOMRIGHT", -14, 12)
  f.close:SetText(CLOSE or "Close")
  f.close:SetScript("OnClick", function() f:Hide() end)

  f.size = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.size:SetPoint("BOTTOMLEFT", 16, 18)

  table.insert(UISpecialFrames, "NorgannonDBCollectorExport")
  return f
end

local function plural(n, word)
  return n .. " " .. word .. (n == 1 and "" or "s")
end

function C.ShowExport()
  local text = C.ExportString()
  C.lastExport = text
  C.sv.meta.lastExport = time and time() or 0
  window = window or createWindow()
  window.text = text
  local s = C.Stats()
  window.stats:SetText(string.format("You have recorded %s, %s, %s and %s.", plural(s.npcs, "NPC"),
    plural(s.objects, "object"), plural(s.quests, "quest"), plural(s.items, "item")))
  window.help:SetText("Press Ctrl+C to copy the line below, then paste it into a text file or a message for the "
    .. "NorgannonDB maintainer. It contains no character names. Exports include everything so far, so send a fresh one now and then.")
  local method = text:match("^%a+:%d+:(%a):")
  window.size:SetText(string.format("%.1f KB, %s", #text / 1024, method == "C" and "compressed" or "plain"))
  window:Show()
  window.box:SetText(text)
  window.box:SetFocus()
  window.box:HighlightText()
  window.box:SetCursorPosition(0)
  window.box:HighlightText()
  return text
end
