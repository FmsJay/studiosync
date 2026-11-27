-- rt-setup (findings 2026-11-27, "still open": REAPER's own default recording format for new projects = 24-bit WAV, for every computer and
-- studio, not over a FLAC this computer chose). lib/recformat.lua reads reaper.ini's [reaper] reccfg (hex bytes + checksum, as REAPER writes it),
-- sets it through set_config_var_string (persist 2: a project default) or SWS's ini write, keeps the project in front's own format, and runs
-- once (installer step, Autostart). StudioSync's own first open and publish now follow the computer's choice too (they set FLAC).
package.path = "lib/?.lua;" .. package.path
local ext = {}
local ini = (os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"):gsub("\\", "/") .. "/studiosync_rt_setup_reaper.ini" -- (os.tmpname is the drive's root on Windows)
local function write(t) local f = assert(io.open(ini, "wb")); f:write(t); f:close() end
local function read(p) local f = assert(io.open(p, "rb")); local d = f:read("a"); f:close(); return d end
local FLAC_HEX = "63616C661000000005000000AB" -- (16-bit FLAC, as ReaPersona's templates had it, with REAPER's checksum)
local proj_fmt = "Y2FsZhgAAAAFAAAA" -- (the project in front's own: FLAC)
local api = true
local function ini_set(key, val, text)
  local out, done, inside = {}, false, false
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local sec = line:match("^%[(.-)%]")
    if sec then if inside and not done then out[#out + 1] = key .. "=" .. val; done = true end; inside = sec:lower() == "reaper" end
    if inside and line:lower():match("^" .. key .. "=") then line = key .. "=" .. val; done = true end
    out[#out + 1] = line
  end
  while out[#out] == "" do out[#out] = nil end
  return table.concat(out, "\n") .. "\n"
end
reaper = setmetatable({
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end, SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  get_ini_file = function() return ini end, EnumProjects = function() return "P", "" end,
  GetSetProjectInfo_String = function(_, k, v, set) if set then proj_fmt = v end; return true, proj_fmt end,
  set_config_var_string = function(name, value, persist)
    if not api then return 0 end
    proj_fmt = "ZXZhdxgAAQ==" -- (REAPER: a project default is the open project's setting in memory too)
    if persist == 2 then write(ini_set(name, value, read(ini))) end
    return 2
  end,
  BR_Win32_WritePrivateProfileString = function(sec, key, val, path) assert(path == ini and sec == "REAPER"); write(ini_set(key, val, read(ini))) end,
}, { __index = function() return function() return "" end end })
local rf = require("recformat")
-- pure parts
assert(rf.sum_ok(rf.WAV24_HEX) and rf.sum_ok(FLAC_HEX) and not rf.sum_ok("65766177180001CD"), "REAPER's checksum byte: the bytes' sum")
assert(rf.kind(rf.WAV24_HEX) == "wave" and rf.kind(FLAC_HEX) == "flac", "the sink's four letters, backwards")
local text = "[audioconfig]\nreccfg=nope\n[REAPER]\nnewprojtmpl=\nreccfg=" .. FLAC_HEX .. "\n[other]\nreccfg=x\n"
assert(rf.ini_value(text, "reccfg") == FLAC_HEX and rf.ini_value("[reaper]\n", "reccfg") == nil, "only [reaper]'s, any case")
assert(rf.decide(nil, false) and rf.decide(FLAC_HEX, false) and not rf.decide(FLAC_HEX, true), "over nothing or FLAC; not where this computer chose FLAC")
assert(not rf.decide("6576617720000300B5", false) and not rf.decide("6666696118000000", false), "a 32-bit WAV or AIFF someone chose stays")
-- in REAPER: set through the API, the open project keeps its own format
write(text)
local res = rf.apply(false)
assert(res == "set" and rf.ini_value(read(ini), "reccfg") == rf.WAV24_HEX, "REAPER's default for new projects: 24-bit WAV")
assert(proj_fmt == "Y2FsZhgAAAAFAAAA", "the project in front keeps its own format")
assert(read(ini):find("[other]\nreccfg=x", 1, true), "nothing else in the file touched")
assert(rf.apply(false) == "kept", "already WAV: left")
-- an older REAPER (no set_config_var_string): the file, through SWS
write(text); api = false
assert(rf.apply(false) == "written" and rf.ini_value(read(ini), "reccfg") == rf.WAV24_HEX, "written for REAPER's next start")
-- FLAC chosen on this computer: left
write(text); api = true
assert(rf.apply(true) == "kept" and rf.ini_value(read(ini), "reccfg") == FLAC_HEX, "this computer's FLAC choice stays")
-- once: the second time does nothing, even after someone sets FLAC again
local band = require("band")
band.log = function() end
write(text)
assert(rf.once() == "set" and ext["BandSync/default format set"] == "1", "once from StudioSync")
write(text)
assert(rf.once() == nil and rf.ini_value(read(ini), "reccfg") == FLAC_HEX, "never again: a FLAC chosen afterwards stays")
os.remove(ini)

-- the wiring: the installer's step inside REAPER, Autostart once, and StudioSync's own first open and publish follow the computer's choice
local function src(p) return (read(p):gsub("\r\n", "\n")) end
local setup, auto, open, pub = src("installer/studiosync_setup.lua"), src("StudioSync - Autostart.lua"), src("StudioSync - Open session.lua"), src("StudioSync - Publish session.lua")
assert(setup:find('pcall(require, "recformat")', 1, true) and setup:find('pcall(rf.apply, reaper.GetExtState("BandSync", "record wav") == "0")', 1, true), "the installer sets it")
assert(auto:find('band.try("recformat.once", require("recformat").once)', 1, true), "Autostart, once")
for name, t in pairs({ open = open, publish = pub }) do
  assert(not t:find('"RECORD_FORMAT", band.FLAC', 1, true) and t:find('"RECORD_FORMAT", require("streams").record_want(), true)', 1, true), name .. ": the computer's format, not FLAC")
end
print("ok")
