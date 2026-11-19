-- 0.59.47: band.lua loaded fresh from a shared folder, with its code changed (a new version arrived before "update ok"). Its code check
-- (band.code_guard, run as band.lua loads) requires fromfolder, which requires band: band.lua loaded itself again, round and round to Lua's
-- C-stack limit, then asked once per level (the Mac hung behind a box; the laptop asked twice), and a studio that updates through its
-- folder was asked though it shouldn't be. Real files in a temp folder, real require; BAND_SRC (a global) tests another band.lua.
local SEP = package.config:sub(1, 1)
local T = (os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"):gsub("\\", "/") .. "/ss_cg47_" .. os.time() .. "_" .. math.random(100000, 999999)
local function mkdir(d) os.execute(SEP == "\\" and ('mkdir "' .. d:gsub("/", "\\") .. '" 2>nul') or ("mkdir -p '" .. d .. "'")) end
local listing = {} -- dir -> { name = true } (only what this test writes)
local function put(path, text)
  local dir, name = path:match("^(.*)/([^/]+)$")
  mkdir(dir)
  local f = assert(io.open(path, "wb")); f:write(text); f:close()
  listing[dir] = listing[dir] or {}; listing[dir][name] = true
  local parent, sub = dir:match("^(.*)/([^/]+)$")
  while parent do listing[parent] = listing[parent] or {}; listing[parent][sub .. "/"] = true; parent, sub = parent:match("^(.*)/([^/]+)$") end
end
local function slurp(p) local f = assert(io.open(p, "rb")); local s = f:read("a"); f:close(); return s end
local function names(d, dirs)
  local out = {}
  for n in pairs(listing[d] or {}) do if (n:sub(-1) == "/") == dirs then out[#out + 1] = dirs and n:sub(1, -2) or n end end
  table.sort(out); return out
end

local ext, boxes, answer = {}, 0, 7
reaper = setmetatable({
  GetOS = function() return "Win64" end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  HasExtState = function(s, k) return ext[s .. "/" .. k] ~= nil end,
  DeleteExtState = function(s, k) ext[s .. "/" .. k] = nil end,
  file_exists = function(p) local f = io.open(p, "rb"); if f then f:close() end; return f ~= nil end,
  EnumerateFiles = function(d, i) return i >= 0 and names(d:gsub("\\", "/"):gsub("/+$", ""), false)[i + 1] or nil end,
  EnumerateSubdirectories = function(d, i) return i >= 0 and names(d:gsub("\\", "/"):gsub("/+$", ""), true)[i + 1] or nil end,
  RecursiveCreateDirectory = function(d) mkdir(d:gsub("\\", "/")); return 1 end,
  GetResourcePath = function() return T .. "/res" end,
  MB = function() boxes = boxes + 1; return answer end,
  time_precise = os.clock,
}, { __index = function() return function() return 0 end end })

local R, D = T .. "/s", T .. "/s/_tools/studiosync"
put(R .. "/_band/band.json", '{"name":"S","id":"studiosync-s-0001"}')
put(D .. "/StudioSync - Panel.lua", "panel()\n")
put(D .. "/lib/band.lua", slurp(BAND_SRC or "lib/band.lua"))
put(D .. "/lib/json.lua", slurp("lib/json.lua"))
TRUSTED = false
local function fromfolder(n) put(D .. "/lib/fromfolder.lua", "-- " .. n .. "\nlocal band = require('band')\nreturn { trusted_copy = function(dir) return TRUSTED end }\n") end
fromfolder(1)
mkdir(T .. "/res/StudioSync")
ext["BandSync/bands"] = R
package.path = D .. "/lib/?.lua;" .. package.path
local function fresh() -- (a script starting: nothing of StudioSync loaded yet, and no check in place)
  for _, m in ipairs({ "band", "fromfolder", "json" }) do package.loaded[m] = nil end
  for i = #package.searchers, 1, -1 do if package.searchers[i] == _G.BANDSYNC_CODE_SEARCHER then table.remove(package.searchers, i) end end
  return pcall(require, "band")
end
local function clean() os.execute(SEP == "\\" and ('rmdir /s /q "' .. T:gsub("/", "\\") .. '"') or ("rm -rf '" .. T .. "'")) end

local ok, e = fresh()
local function check(cond, what) if not cond then clean(); error(what .. " (boxes " .. boxes .. ", " .. tostring(e) .. ")", 2) end end
check(ok and boxes == 0 and reaper.file_exists(T .. "/res/StudioSync/approved code.json"), "the first load is remembered without asking")
check(package.loaded.band and package.loaded.band.code_guard, "and band loads")

fromfolder(2); TRUSTED = true
ok, e = fresh()
check(ok and boxes == 0, "changed, in a studio that updates through its folder: used without asking (it asked once per level)")

fromfolder(3); TRUSTED = false; answer = 6 -- Yes
ok, e = fresh()
check(ok and boxes == 1, "changed, not such a studio: asked once (it was asked once per level), and Yes loads it")

fromfolder(4); answer = 7 -- No
ok, e = fresh()
check(not ok and boxes == 2 and tostring(e):find("didn't start", 1, true), "No stops the script, asked once")
check(package.loaded.band == nil, "and a refused band isn't left loaded for the next require")
ok, e = fresh()
check(not ok and boxes == 2, "and isn't asked about again")
clean()
print("ok")
