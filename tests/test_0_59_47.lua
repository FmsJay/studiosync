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
local function fromfolder(n) put(D .. "/lib/fromfolder.lua", "-- " .. n .. "\nlocal band = require('band')\nreturn { trusted_copy = function(dir) return true end }\n") end
-- (0.59.48, Round 3 review: "updates through its folder" is told by band.json and the settings this computer last verified (lib/groups.lua
-- trusted), with no module of the shared folder loaded first: its own fromfolder decided whether changed code, itself too, was trusted)
local function trusted(file_says, verified)
  put(R .. "/_band/band.json", '{"name":"S","id":"studiosync-s-0001"' .. (file_says and ',"updates":"folder"' or "") .. '}')
  ext["BandSync/trusted settings " .. R:lower()] = verified and '{"updates":"folder"}' or nil
end
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

fromfolder(2); trusted(true, true)
ok, e = fresh()
check(ok and boxes == 0, "changed, in a studio that updates through its folder: used without asking (it asked once per level)")
check(package.loaded.fromfolder == nil, "and nothing of the shared folder loaded to decide it")

fromfolder(3); trusted(true, false); answer = 6 -- Yes
ok, e = fresh()
check(ok and boxes == 1, "band.json says folder updates but nothing verified here does (a member wrote it): asked once, and Yes loads it")
trusted(false, false)

fromfolder(4); answer = 7 -- No
ok, e = fresh()
check(not ok and boxes == 2 and tostring(e):find("didn't start", 1, true), "No stops the script, asked once")
check(package.loaded.band == nil, "and a refused band isn't left loaded for the next require")
ok, e = fresh()
check(not ok and boxes == 2, "and isn't asked about again")

-- a reload (band.reload) passes the version it approved: the new band.lua records it without a box; anything else inside a reload is
-- refused with a line in the log, no box, and the old code carries on (0.59.48, James's decision)
fromfolder(5); answer = 6
ok, e = fresh()
check(ok and boxes == 3, "a fresh start, said yes to")
put(D .. "/StudioSync - Main.lua", "require('band')\n")
local function version(v) put(D .. "/lib/band.lua", (slurp(BAND_SRC or "lib/band.lua"):gsub('VERSION = "[^"]+"', 'VERSION = "' .. v .. '"', 1))) end
local old = package.loaded.band
version("9.9.1")
local r, why = old.reload(D, "StudioSync - Main.lua", "9.9.1")
check(r == true and boxes == 3 and package.loaded.band ~= old, "a reload to the approved version: switched, no box (" .. tostring(why) .. ")")
check(_G.STUDIOSYNC_RELOAD_APPROVED == nil, "and the approval doesn't outlive the reload")
old = package.loaded.band
version("9.9.2")
r, why = old.reload(D, "StudioSync - Main.lua", nil)
check(r == false and boxes == 3 and package.loaded.band == old and tostring(why):find("wasn't switched to", 1, true),
  "a reload to a version not approved: refused, no box, the old code kept (" .. tostring(why) .. ")")
version("9.9.3"); trusted(true, true)
r, why = old.reload(D, "StudioSync - Main.lua", nil)
check(r == true and boxes == 3, "inside a reload, a studio that updates through its folder: switched, no box (" .. tostring(why) .. ")")
clean()
print("ok")
