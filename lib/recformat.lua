-- REAPER's own recording format for new projects: 24-bit WAV (James, 2026-11-23: "WAV for all devices and all studios"; StudioSync already sets
-- it inside studio projects, lib/streams.lua record_want). REAPER keeps it as the project default "reccfg" in reaper.ini's [reaper] section: the
-- sink's bytes in hex, then a checksum byte (their sum, as Windows' WritePrivateProfileStruct writes it). A FLAC default came from older
-- StudioSync templates and ReaPersona's DAW templates. Set from the installer's step inside REAPER and once from StudioSync (Autostart), and
-- only over FLAC or nothing: another format someone chose stays, and so does FLAC where this computer chose it (Settings > Options > Parts
-- play: ExtState "record wav" = "0"). REAPER rewrites its ini from memory, so it goes through REAPER's own set_config_var_string (7.74 on;
-- persist 2 = a project default, written to reaper.ini), with SWS's ini write as the fallback for an older REAPER. (rt-setup)
local recformat = { KEY = "default format set" }
recformat.WAV24_HEX = "65766177180001CC" -- ("evaw", 24 bits, 0, 1: base64 ZXZhdxgAAQ==, lib/streams.lua WAV24; then the sum's low byte)

-- The value of `key` in reaper.ini's [reaper] section (any case), or nil. Pure.
function recformat.ini_value(text, key)
  local inside = false
  for line in ((text or "") .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    local sec = line:match("^%s*%[([^%]]+)%]")
    if sec then inside = sec:lower() == "reaper"
    elseif inside then
      local k, v = line:match("^([^=]+)=(.*)$")
      if k and k:lower() == key:lower() then return v end
    end
  end
  return nil
end
-- Hex bytes, their checksum byte last -> whether the checksum holds. Pure.
function recformat.sum_ok(hex)
  if type(hex) ~= "string" or #hex < 4 or #hex % 2 ~= 0 or hex:find("[^%x]") then return false end
  local sum = 0
  for i = 1, #hex - 2, 2 do sum = sum + tonumber(hex:sub(i, i + 1), 16) end
  return sum % 256 == tonumber(hex:sub(-2), 16)
end
-- The sink's kind from reaper.ini's hex: "flac", "wave", ... (four letters, stored backwards). Pure.
function recformat.kind(hex)
  if type(hex) ~= "string" or #hex < 8 or hex:sub(1, 8):find("[^%x]") then return "" end
  return (hex:sub(1, 8):gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end)):reverse()
end
-- Set it? Only over nothing or FLAC, and not where this computer chose FLAC. Pure.
function recformat.decide(cur, flac_chosen)
  if flac_chosen then return false end
  return cur == nil or cur == "" or recformat.kind(cur) == "flac"
end

local function ini_now()
  local f = io.open(reaper.get_ini_file(), "rb")
  local t = f and f:read("a") or ""
  if f then f:close() end
  return recformat.ini_value(t, "reccfg")
end
-- -> "set" (REAPER took it), "written" (into the file only: REAPER reads it at its next start), "kept" (nothing to do) or "failed", and the value now.
function recformat.apply(flac_chosen)
  local cur = ini_now()
  if not recformat.decide(cur, flac_chosen) then return "kept", cur end
  local proj = reaper.EnumProjects(-1)
  local was = proj and select(2, reaper.GetSetProjectInfo_String(proj, "RECORD_FORMAT", "", false))
  if reaper.set_config_var_string then pcall(reaper.set_config_var_string, "reccfg", recformat.WAV24_HEX, 2) end
  -- (a project default is also the open project's setting in memory: the project in front keeps its own)
  if was and select(2, reaper.GetSetProjectInfo_String(proj, "RECORD_FORMAT", "", false)) ~= was then reaper.GetSetProjectInfo_String(proj, "RECORD_FORMAT", was, true) end
  if ini_now() == recformat.WAV24_HEX then return "set", recformat.WAV24_HEX end
  if reaper.BR_Win32_WritePrivateProfileString then reaper.BR_Win32_WritePrivateProfileString("REAPER", "reccfg", recformat.WAV24_HEX, reaper.get_ini_file()) end
  local now = ini_now()
  return now == recformat.WAV24_HEX and "written" or "failed", now
end
-- Once on this computer (Autostart): a person who sets FLAC as REAPER's default afterwards keeps it.
function recformat.once()
  local band = require("band")
  if reaper.GetExtState(band.SECTION, recformat.KEY) == "1" then return nil end
  local res = recformat.apply(reaper.GetExtState(band.SECTION, "record wav") == "0")
  reaper.SetExtState(band.SECTION, recformat.KEY, "1", true)
  if res == "set" or res == "written" then
    band.log("REAPER's recording format for new projects is 24-bit WAV now, as in the studio's projects (it was FLAC). Project settings > Media changes it")
  elseif res == "failed" then band.log("couldn't set REAPER's recording format for new projects to 24-bit WAV: set it in File > Project settings > Media, then Save as default project settings") end
  return res
end

return recformat
