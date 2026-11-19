-- Signed updates (docs/realtime-roadmap.md "Signed updates"): in a studio with an update key, a folder copy signed with it is recorded without a
-- box (no "update ok" needed); a changed file, a missing lib/files.txt.sig, another key or no verifier is refused without a box; a studio
-- without a key asks as before; the key is pinned at first look; update_ok follows the signature; fromfolder.sign_copy signs only code said yes
-- to. The extension's StudioSync_VerifyFiles/FileHash/Sign/KeyCreate are stood in for by tools/sign_release.py (the same Ed25519 and file
-- rule, in Python, through lupa's `python`); the native code itself is tests/sign_test.cpp's, and tests/sign_cross.py checks the two agree.
-- Real files in a temp folder, real require (tests/test_0_59_49_trust_guard.lua's harness). Lupa, repo root.
local SEP = package.config:sub(1, 1)
local T = (os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"):gsub("\\", "/") .. "/ss_signed_" .. os.time() .. "_" .. math.random(100000, 999999)
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
local function slurp(p) local f = io.open(p, "rb"); if not f then return nil end; local s = f:read("a"); f:close(); return s end
local function names(d, dirs)
  local out = {}
  for n in pairs(listing[d] or {}) do if (n:sub(-1) == "/") == dirs then out[#out + 1] = dirs and n:sub(1, -2) or n end end
  table.sort(out); return out
end

python.eval("__import__('sys').path.insert(0, 'tools')")
local sr = python.eval("__import__('sign_release')")
local ext, boxes, answer, logs = {}, 0, 7, {}
local function verify_files(dir, key) return sr.check(dir, key) end
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
  ShowConsoleMsg = function(s) logs[#logs + 1] = s end,
  time_precise = os.clock,
  StudioSync_VerifyFiles = verify_files,
  StudioSync_FileHash = function(p) local ok, h = pcall(sr.file_hash, p); return ok and h or "" end,
  -- (bytes would come back as a Lua string, so the hex is made in Python)
  StudioSync_Sign = function(kp, msg) return python.eval("lambda sr, kp, m: sr.sign(sr.load_seed(kp), m.encode('utf-8')).hex()")(sr, kp, msg) end,
  StudioSync_KeyCreate = function(kp) return python.eval("lambda sr, kp: sr.public_key(sr.new_key(kp)).hex()")(sr, kp) end,
}, { __index = function() return function() return 0 end end })

local R, D = T .. "/s", T .. "/s/_tools/studiosync"
put(R .. "/_band/band.json", '{"name":"S","id":"studiosync-s-0001","updates":"folder"}')
put(D .. "/StudioSync - Panel.lua", "panel()\n")
put(D .. "/StudioSync - Main.lua", "require('band')\n")
put(D .. "/lib/band.lua", slurp("lib/band.lua"))
put(D .. "/lib/json.lua", slurp("lib/json.lua"))
put(D .. "/lib/fromfolder.lua", slurp("lib/fromfolder.lua"))
mkdir(T .. "/res/StudioSync")
ext["BandSync/bands"] = R
package.path = D .. "/lib/?.lua;" .. package.path
local function fresh()
  for _, m in ipairs({ "band", "fromfolder", "json", "groups" }) do package.loaded[m] = nil end
  for i = #package.searchers, 1, -1 do if package.searchers[i] == _G.BANDSYNC_CODE_SEARCHER then table.remove(package.searchers, i) end end
  return pcall(require, "band")
end
local function clean() os.execute(SEP == "\\" and ('rmdir /s /q "' .. T:gsub("/", "\\") .. '"') or ("rm -rf '" .. T .. "'")) end
local ok, e = fresh()
local function check(cond, what) if not cond then clean(); error(what .. " (boxes " .. boxes .. ", " .. tostring(e) .. ")", 2) end end
check(ok and boxes == 0, "the first load, no key yet: remembered without asking, as before")
local SETTINGS, PIN = "BandSync/trusted settings " .. R:lower(), "BandSync/update key " .. R:lower()
local KEYFILE, OTHER = T .. "/home/.studiosync/update-key", T .. "/home/other-key"
mkdir(T .. "/home/.studiosync")
local function version(v) put(D .. "/lib/band.lua", (slurp("lib/band.lua"):gsub('VERSION = "[^"]+"', 'VERSION = "' .. v .. '"', 1))) end
local function approved() return (slurp(T .. "/res/StudioSync/approved code.json") or "") end

-- sign_release produces a .sig the verifier accepts
version("9.9.1")
local pub = sr.sign_dir(D, KEYFILE)
check(#pub == 64 and verify_files(D, pub):match("^ok 9%.9%.1\n"), "tools/sign_release.py signs a copy its verifier accepts")
check(slurp(D .. "/lib/files.txt"):find("\nsha256 %x+ lib/fromfolder%.lua\n") and slurp(D .. "/lib/files.txt"):find("\nlib/band%.lua\t%d+\t%x+\n"),
  "lib/files.txt keeps its length and FNV rows and gains SHA-256 rows")

-- a keyed studio (the trusted setting, as groups.trusted stores it): a signed new version is recorded with no box and no "update ok"
ext[SETTINGS] = '{"updates":"folder","update_key":"' .. pub .. '"}'
ext["BandSync/update ok"] = nil
ok, e = fresh()
check(ok and boxes == 0, "a signed new version in a keyed studio: used, no box")
check(ext[PIN] == pub, "the studio's key is pinned at first look")
check(approved():find("9.9.1", 1, true), "and recorded as the code said yes to")
local band = package.loaded.band
check(band.update_ok(D, "9.9.1") == true, "update_ok: the signed version on disk")

-- a file changed after signing: refused, no box, logged
put(D .. "/StudioSync - Panel.lua", "panel('changed')\n")
ok, e = fresh()
check(not ok and boxes == 0 and tostring(e):find("isn't signed with the studio's update key", 1, true), "a changed file in a keyed studio: refused, no box")
check(tostring(e):find("StudioSync - Panel.lua", 1, true), "and it says which file")
put(D .. "/StudioSync - Panel.lua", "panel()\n")
ok, e = fresh()
check(ok and boxes == 0, "put back as signed: used again")

-- a new file the signed list doesn't have (both rows would be needed): refused
put(D .. "/lib/extra.lua", "return {}\n")
ok, e = fresh()
check(not ok and boxes == 0, "an extra lib module next to a signed copy: refused, no box")
os.remove(D .. "/lib/extra.lua"); listing[D .. "/lib"]["extra.lua"] = nil

-- missing .sig: refused
version("9.9.2")
sr.write(D) -- (lib/files.txt for 9.9.2, unsigned: the .sig goes)
check(not slurp(D .. "/lib/files.txt.sig"), "an unsigned lib/files.txt leaves no stale .sig")
ok, e = fresh()
check(not ok and boxes == 0 and tostring(e):find("no lib/files.txt.sig", 1, true), "no .sig in a keyed studio: refused, no box (" .. tostring(e) .. ")")
check(band.update_ok(D, "9.9.2") == false, "update_ok: not for an unsigned version")

-- signed with another key: refused, and a new key in band.json doesn't replace the pin
local other = sr.sign_dir(D, OTHER)
ok, e = fresh()
check(not ok and boxes == 0, "signed with another key: refused, no box")
ext[SETTINGS] = '{"updates":"folder","update_key":"' .. other .. '"}'
ok, e = fresh()
check(not ok and boxes == 0 and ext[PIN] == pub, "another key in the trusted settings later: the pin stands, still refused")
ext[SETTINGS] = '{"updates":"folder","update_key":"' .. pub .. '"}'

-- the pin lost in a crash: settings.json's kept copy (band.kept_keys has it)
sr.sign_dir(D, KEYFILE)
ext[PIN] = nil; ext[SETTINGS] = nil
put(T .. "/res/StudioSync/settings.json", '{"update key ' .. R:lower() .. '":"' .. pub .. '"}')
ok, e = fresh()
check(ok and boxes == 0 and ext[PIN] == pub, "the pin back from settings.json before Autostart runs: the signed copy is used")
check(table.concat(package.loaded.band.kept_keys(), "\n"):find("update key " .. R:lower(), 1, true), "and band.kept_keys keeps the pin")

-- no verifier (an extension older than 1.0.9) in a keyed studio: refused, no box
version("9.9.3"); sr.sign_dir(D, KEYFILE)
reaper.StudioSync_VerifyFiles = false -- (nil would reach the stand-in __index)
ok, e = fresh()
check(not ok and boxes == 0 and tostring(e):find("1.0.9", 1, true), "no verifier in a keyed studio: refused, no box")
reaper.StudioSync_VerifyFiles = verify_files

-- a studio without a key: exactly as before (a changed file in a studio that doesn't update through its folder is asked about)
ext[PIN] = nil; ext[SETTINGS] = '{}'
put(T .. "/res/StudioSync/settings.json", "{}")
put(R .. "/_band/band.json", '{"name":"S","id":"studiosync-s-0001"}')
os.remove(D .. "/lib/files.txt.sig")
put(D .. "/StudioSync - Panel.lua", "panel('unkeyed')\n")
ok, e = fresh()
check(not ok and boxes == 1, "no key: the changed code is asked about as before (No: not started)")
answer = 6
for k in pairs(ext) do if k:find("^BandSync/code refused ") then ext[k] = nil end end -- (a No holds until REAPER restarts)
ok, e = fresh()
check(ok and boxes == 2, "no key, Yes: used, as before")

-- fromfolder.sign_copy: signs code this computer said yes to, refuses code it didn't
band = package.loaded.band
local ff = require("fromfolder")
ok, e = ff.sign_copy(D, KEYFILE)
check(ok == true and verify_files(D, pub):match("^ok 9%.9%.3\n"), "sign_copy signs the copy this computer said yes to (" .. tostring(e) .. ")")
check(verify_files(D, pub):find("\nsha256 %x+ StudioSync %- Panel%.lua\n"), "with a SHA-256 row per code file")
put(D .. "/lib/json.lua", slurp("lib/json.lua") .. "\n-- slipped in\n")
ok, e = ff.sign_copy(D, KEYFILE)
check(ok == false and tostring(e):find("said yes to", 1, true), "sign_copy won't bless code this computer hasn't said yes to")
put(D .. "/lib/json.lua", slurp("lib/json.lua"))
check(ff.update_key_path():find("/%.studiosync/update%-key$") or os.getenv("STUDIOSYNC_UPDATE_KEY"), "the key lives under the home folder by default")

-- the keyed studio again, with the copy sign_copy signed: used, no box
ext[SETTINGS] = '{"update_key":"' .. pub .. '"}'
ok, e = fresh()
check(ok and boxes == 2, "a copy signed in REAPER (sign_copy) is used in a keyed studio, no box")
clean()
print("ok")
