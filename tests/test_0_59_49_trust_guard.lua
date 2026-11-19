-- 0.59.49 (Round 4 review), the code check: a folder-updating studio's verified settings are read from settings.json when a crash lost them
-- (the check runs before Autostart puts them back); a studio with nothing verified still asks; a Yes makes that version "update ok"; a
-- version said yes to while part of it was arriving is taken once whole, inside the reload, with no box; band.reload_or_say notes the version
-- it approves as "update ok". Real files in a temp folder, real require (tests/test_0_59_47.lua's harness). Lupa or Lua 5.4, repo root.
local SEP = package.config:sub(1, 1)
local T = (os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"):gsub("\\", "/") .. "/ss_cg49_" .. os.time() .. "_" .. math.random(100000, 999999)
local function mkdir(d) os.execute(SEP == "\\" and ('mkdir "' .. d:gsub("/", "\\") .. '" 2>nul') or ("mkdir -p '" .. d .. "'")) end
local listing = {}
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
local function band_json(folder) put(R .. "/_band/band.json", '{"name":"S","id":"studiosync-s-0001"' .. (folder and ',"updates":"folder"' or "") .. '}') end
band_json(false)
put(D .. "/StudioSync - Panel.lua", "panel()\n")
put(D .. "/StudioSync - Main.lua", "require('band')\n")
put(D .. "/lib/band.lua", slurp("lib/band.lua"))
put(D .. "/lib/json.lua", slurp("lib/json.lua"))
put(D .. "/lib/fromfolder.lua", "local band = require('band')\nreturn { trusted_copy = function(dir) return true end }\n")
mkdir(T .. "/res/StudioSync")
ext["BandSync/bands"] = R
package.path = D .. "/lib/?.lua;" .. package.path
local function fresh()
  for _, m in ipairs({ "band", "fromfolder", "json" }) do package.loaded[m] = nil end
  for i = #package.searchers, 1, -1 do if package.searchers[i] == _G.BANDSYNC_CODE_SEARCHER then table.remove(package.searchers, i) end end
  return pcall(require, "band")
end
local function clean() os.execute(SEP == "\\" and ('rmdir /s /q "' .. T:gsub("/", "\\") .. '"') or ("rm -rf '" .. T .. "'")) end
local ok, e = fresh()
local function check(cond, what) if not cond then clean(); error(what .. " (boxes " .. boxes .. ", " .. tostring(e) .. ")", 2) end end
check(ok and boxes == 0, "the first load is remembered without asking")
local KEY = "trusted settings " .. R:lower()

-- install 3 / xplat 1 / changes 5: a crash lost the verified settings; settings.json still has them, and the check reads them there
put(D .. "/StudioSync - Panel.lua", "panel(2)\n"); band_json(true)
put(T .. "/res/StudioSync/settings.json", '{"' .. KEY .. '":"{\\"updates\\":\\"folder\\"}"}')
ok, e = fresh()
check(ok and boxes == 0, "a folder-updating studio whose verified settings are only in settings.json: used without asking (it asked after a crash)")
-- nothing verified anywhere (a studio from before owners never stores any): still asked, James's decision; a Yes makes it "update ok"
put(D .. "/StudioSync - Panel.lua", "panel(3)\n"); put(T .. "/res/StudioSync/settings.json", "{}"); answer = 6
ok, e = fresh()
check(ok and boxes == 1, "band.json says folder updates, nothing verified here or in settings.json: asked")
check(ext["BandSync/update ok"] == package.loaded.band.VERSION, "and the Yes is that version's \"update ok\" (the reload once the rest came had none)")
band_json(false)

-- changes 2: said yes to on a part-arrived copy (lib/extra.lua not as its list says yet); once whole, the reload takes it with no box
local function version(v) put(D .. "/lib/band.lua", (slurp("lib/band.lua"):gsub('VERSION = "[^"]+"', 'VERSION = "' .. v .. '"', 1))) end
version("9.9.4")
put(D .. "/lib/extra.lua", "return { whole = true }\n")
do -- the release's own list, of the whole copy
  local b, lines, paths = package.loaded.band, { "version 9.9.4" }, {}
  local now = b.code_files(D)
  for p in pairs(now) do paths[#paths + 1] = p end
  table.sort(paths)
  for _, p in ipairs(paths) do lines[#lines + 1] = p .. "\t" .. #(slurp(D .. "/" .. p):gsub("\r", "")) .. "\t" .. now[p] end
  put(D .. "/lib/files.txt", table.concat(lines, "\n") .. "\n")
end
put(D .. "/lib/extra.lua", "return { whole = nope }\n") -- (still arriving: the same length, another text)
ok, e = fresh()
check(ok and boxes == 2 and ext["BandSync/update ok"] == "9.9.4", "a fresh start on the part-arrived copy: asked, Yes")
local old = package.loaded.band
put(D .. "/lib/extra.lua", "return { whole = 0 }\n") -- (more of it arrived, still not the release's)
local r, why = old.reload(D, "StudioSync - Main.lua", "9.9.4")
check(r == false and boxes == 2 and package.loaded.band == old, "not whole yet: refused inside the reload, no box (" .. tostring(why) .. ")")
put(D .. "/lib/extra.lua", "return { whole = true }\n")
ext["BandSync/update ok"] = nil -- (approved by the studio's own copy here: band.reload_or_say notes it)
r = old.reload_or_say(D, "StudioSync - Main.lua", "9.9.4")
check(r == true and boxes == 2 and package.loaded.band ~= old, "whole now: switched inside the reload, no box (it was refused until REAPER restarted)")
check(ext["BandSync/update ok"] == "9.9.4", "and reload_or_say noted the version it approved (a 0.59.47 band.lua would ask its own box without it)")
check(_G.STUDIOSYNC_RELOAD_APPROVED == nil, "the approval doesn't outlive the reload")
-- same version, a file that isn't its list's: still refused (only the release's own files are taken)
old = package.loaded.band
put(D .. "/lib/extra.lua", "return { whole = 2 }\n")
r, why = old.reload(D, "StudioSync - Main.lua", "9.9.4")
check(r == false and boxes == 2, "a same-version change that doesn't match lib/files.txt: refused, no box (" .. tostring(why) .. ")")
clean()
print("ok")
