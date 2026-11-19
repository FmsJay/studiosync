-- The cloud copy, part 2 (James, rt): the hub's other jobs when no hub is online. End-of-session projects kept to the newest few, the studio's
-- signed update files both ways through the cloud copy, and Health's hint for a computer without one. Pure parts, then the update files with a
-- stand-in file system, REAPER and signature check.
package.path = "lib/?.lua;" .. package.path
local fs = {} -- path -> contents
local function dir_list(dir, want_dirs)
  local out, seen = {}, {}
  for p in pairs(fs) do
    local rest = p:sub(1, #dir + 1) == dir .. "/" and p:sub(#dir + 2)
    if rest then
      local first, more = rest:match("^([^/]+)(/?)")
      if first and (more == "/") == want_dirs and not seen[first] then seen[first] = true; out[#out + 1] = first end
    end
  end
  table.sort(out)
  return out
end
local logs, removed, copied = {}, {}, {}
local verified = {} -- dir -> true when the stand-in signature check passes there
local band = {
  SECTION = "StudioSync",
  norm = function(p) return (tostring(p):gsub("\\", "/"):gsub("/+$", "")) end,
  read = function(p) return fs[p] end,
  files = function(dir, ext)
    local out = {}
    for _, f in ipairs(dir_list(dir, false)) do if not ext or f:sub(-#ext) == ext then out[#out + 1] = f end end
    return out
  end,
  subdirs = function(dir) return dir_list(dir, true) end,
  copy_atomic = function(a, z) assert(fs[a], "copied from nowhere: " .. a); fs[z] = fs[a]; copied[#copied + 1] = z end,
  log = function(s) logs[#logs + 1] = s end,
  version_on_disk = function(dir) return (fs[dir .. "/lib/band.lua"] or ""):match('VERSION = "([^"]+)"') end,
  studio_update_key = function() return ("ab"):rep(32) end,
  info = function() return { id = "studio1", drive = "StudioSync - Chilio" } end,
}
-- signed: the stand-in says yes where the test says so and the copy's band.lua is the version its files.txt names
band.signed_ok = function(dir)
  local text = fs[dir .. "/lib/files.txt"] or ""
  if not verified[dir] then return false, "not signed" end
  if text:match("^version (%S+)") ~= band.version_on_disk(dir) then return false, "versions differ" end
  for p in text:gmatch("sha256 %x+ ([^\n]+)") do if not fs[dir .. "/" .. p] then return false, p .. " missing" end end
  return true
end
package.loaded.band = band
local role, guest, need = "member", false, "{}"
package.loaded.groups = { role = function() return role end }
package.loaded.access = { mine = function() return guest and {} or nil end }
package.loaded.removal = { am_guest = function() return false end }
package.loaded.services = { need = function() return need end }
reaper = setmetatable({
  time_precise = function() return 0 end,
  GetExtState = function() return "" end,
  RecursiveCreateDirectory = function() return true end,
}, { __index = function() return function() end end })
local drive = require("drive")
local sessionfile = require("sessionfile")

-- ---- Health's hint for a computer without a cloud copy ----
local row = drive.join_hint("Google Drive", "On drive.google.com: Shared with me > right-click X > Organize > Add shortcut > My Drive, keeping the name.",
  "Settings > Options > Cloud copy")
assert(row[1] == "cloud copy hint" and row[2] == false and row[3] == "grey", "a grey row: not a problem, just said")
assert(row[5]:find("backup", 1, true) and row[5]:find("nobody else is on", 1, true) and row[5]:find("owner is away", 1, true), "what it would gain")
assert(row[5]:find("Add shortcut", 1, true) and row[5]:find("Cloud copy", 1, true), "and how to set it up")

-- ---- end-of-session projects: each person's newest KEEP per room ----
local names = {}
for i = 1, 13 do names[#names + 1] = string.format("202611%02d-120000Z-James-main.rpp", i) end
names[#names + 1] = "20261101-120000Z-James-side.rpp" -- (another room of his)
names[#names + 1] = "20261101-120000Z-James-Laptop-main.rpp" -- (a longer name that starts with his: not his)
names[#names + 1] = "20261101-120000Z-Mac-main.rpp" -- (a bandmate's: theirs to tidy)
names[#names + 1] = "notes.txt"
local gone = sessionfile.prune_plan(names, "James", "main", 10)
assert(#gone == 3 and gone[1] == "20261103-120000Z-James-main.rpp" and gone[3] == "20261101-120000Z-James-main.rpp", "the three oldest of his in this room")
for _, g in ipairs(gone) do assert(not g:find("Laptop") and not g:find("side") and not g:find("Mac"), "nobody else's, nor another room's") end
assert(#sessionfile.prune_plan(names, "James", "side", 10) == 0, "a room with fewer keeps them all")
local proj = '<REAPER_PROJECT\n  <SOURCE WAVE\n    FILE "media/James/a.wav"\n  >\n  <SOURCE WAVE\n    FILE "../rooms/main/takes/x.flac"\n  >\n>\n'
local unused = sessionfile.unused_media({ "a.wav", "b.wav" }, { proj }, "James")
assert(#unused == 1 and unused[1] == "b.wav", "only recordings no kept project uses")
-- and on disk: the old projects and the recording only they used go, the rest stays
fs = {}
local S = "G:/Cloud/Song/sessions"
for i = 1, 12 do fs[S .. string.format("/202611%02d-120000Z-James-main.rpp", i)] = i <= 2 and 'FILE "media/James/old.wav"\n' or 'FILE "media/James/new.wav"\n' end
fs[S .. "/20261101-120000Z-Mac-main.rpp"] = 'FILE "media/Mac/old.wav"\n'
fs[S .. "/media/James/old.wav"], fs[S .. "/media/James/new.wav"], fs[S .. "/media/Mac/old.wav"] = "o", "n", "m"
local real_remove = os.remove
os.remove = function(p) removed[#removed + 1] = p; local had = fs[p] ~= nil; fs[p] = nil; return had end
assert(sessionfile.prune(S, "James", "main") == 2, "two projects over ten")
assert(not fs[S .. "/media/James/old.wav"] and fs[S .. "/media/James/new.wav"] and fs[S .. "/media/Mac/old.wav"], "his unused recording only")
assert(fs[S .. "/20261101-120000Z-Mac-main.rpp"] and fs[S .. "/20261112-120000Z-James-main.rpp"], "a bandmate's and his newest stay")
removed = {}
assert(sessionfile.prune(S, "James", "main") == 0 and #removed == 0, "nothing more once it's ten")

-- ---- the studio's update files: which files, which way ----
local list = "version 0.60.1\nStudioSync - Autostart.lua\t10\tabc\nlib/band.lua\t20\tdef\nsha256 " .. ("1"):rep(64) .. " StudioSync - Autostart.lua\n" ..
  "sha256 " .. ("2"):rep(64) .. " lib/band.lua\nsha256 " .. ("3"):rep(64) .. " extension/reaper_studiosync-x64.dll\n"
local files = drive.tools_files(list)
assert(#files == 5 and files[1] == "StudioSync - Autostart.lua" and files[4] == "lib/files.txt" and files[5] == "lib/files.txt.sig", "each signed file, the signature last")
assert(drive.tools_files(list .. "sha256 " .. ("4"):rep(64) .. " ../../evil.lua\n") == nil, "a path out of the copy: nothing")
assert(drive.tools_files(list .. "sha256 " .. ("4"):rep(64) .. " /etc/evil\n") == nil and drive.tools_files(list .. "sha256 " .. ("4"):rep(64) .. " C:/evil\n") == nil, "nor an absolute one")
assert(drive.tools_files("version 1\n") == nil, "a list with no files")
local A, B = { version = "0.60.1", sig = "s1" }, { version = "0.60.2", sig = "s2" }
assert(drive.tools_way("0.60.1", A, B, false) == "in", "the cloud's is newer: in")
assert(drive.tools_way(nil, nil, B, false) == "in", "none here: in")
assert(drive.tools_way("0.60.2", nil, A, false) == nil, "never an older one over a newer (unsigned here: still arriving, maybe)")
assert(drive.tools_way("0.60.1", A, { version = "0.60.1", sig = "other" }, false) == nil, "the same version: left")
assert(drive.tools_way("0.60.2", B, A, true) == "out" and drive.tools_way("0.60.2", B, nil, true) == "out", "the owner's newer, or the cloud has none: out")
assert(drive.tools_way("0.60.2", B, A, false) == nil, "a member never writes the cloud's")
assert(drive.tools_way("0.60.1", A, { version = "0.60.1", sig = "s0" }, true) == "out", "the owner re-signed: out")
assert(drive.tools_way("0.60.1", A, A, true) == nil, "the same: nothing")
assert(drive.tools_way("0.60.2", nil, nil, true) == nil, "an unsigned copy never goes out")

-- ---- the update files through the pass ----
local ROOT, CLOUD = "J:/Studio", "G:/My Drive/StudioSync - Chilio"
local HERE, THERE = ROOT .. "/_tools/studiosync", CLOUD .. "/_tools/studiosync"
local function put(dir, v, extra)
  local text = "version " .. v .. "\nsha256 " .. ("1"):rep(64) .. " StudioSync - Autostart.lua\nsha256 " .. ("2"):rep(64) .. " lib/band.lua\n" .. (extra or "")
  fs[dir .. "/StudioSync - Autostart.lua"] = "autostart " .. v
  fs[dir .. "/lib/band.lua"] = 'band.VERSION = "' .. v .. '"'
  fs[dir .. "/lib/files.txt"], fs[dir .. "/lib/files.txt.sig"] = text, "sig " .. v
end
local cfg = { root = ROOT, user = "Laptop" }
local clock = 1000
local function pass() clock = clock + 200; return drive.tools_pass(cfg, CLOUD, clock) end
-- a member, never on with the owner: the cloud has 0.60.2, signed; the studio folder 0.60.1 with a module the new one dropped
fs, copied, logs = {}, {}, {}
put(HERE, "0.60.1"); fs[HERE .. "/lib/old.lua"] = "dropped in 0.60.2"
put(THERE, "0.60.2")
verified = { [HERE] = true, [THERE] = true }
need = nil
assert(pass() == nil and #copied == 0, "not before Syncthing has said what it still needs")
need = '[{"name":"_tools\\\\studiosync\\\\lib\\\\band.lua"}]'
assert(pass() == nil and #copied == 0, "nor while Syncthing is bringing _tools (perhaps a newer one)")
need = '{"progress":[],"queued":[],"rest":[]}'
assert(drive.tools_pass(cfg, CLOUD, clock + 10) == nil and #copied == 0, "at most every EVERY s")
local n = pass()
assert(n and n >= 4, "brought in: " .. tostring(n))
assert(fs[HERE .. "/lib/band.lua"]:find("0.60.2", 1, true) and fs[HERE .. "/lib/files.txt.sig"] == "sig 0.60.2", "the cloud's version, signature and all")
assert(copied[#copied] == HERE .. "/lib/files.txt.sig", "the signature last")
assert(not fs[HERE .. "/lib/old.lua"], "a module the new version dropped goes")
assert(not fs[THERE .. "/lib/old.lua"] and fs[THERE .. "/lib/band.lua"]:find("0.60.2", 1, true), "the cloud's copy only read")
assert(logs[#logs]:find("came from the Google Drive copy", 1, true), "said: " .. tostring(logs[#logs]))
copied = {}
assert(pass() == nil and #copied == 0, "nothing again once it's the same")
-- not signed with the studio's key in the cloud: never brought
fs, copied = {}, {}
put(HERE, "0.60.1"); put(THERE, "0.60.3")
verified = { [HERE] = true }
assert(pass() == nil and #copied == 0 and fs[HERE .. "/lib/band.lua"]:find("0.60.1", 1, true), "an unsigned cloud copy is left where it is")
-- signed when looked at, changed before it's copied: checked again first, nothing copied
put(THERE, "0.60.31") -- (a new list: the way's own check is kept per list)
verified = { [HERE] = true, [THERE] = true }
local real_signed = band.signed_ok
local looks = 0
band.signed_ok = function(dir, key) if dir == THERE then looks = looks + 1; if looks > 1 then return false, "lib/band.lua changed" end end; return real_signed(dir, key) end
assert(pass() == nil and #copied == 0, "the copy is checked again just before it's copied")
band.signed_ok = real_signed
-- no update key: nothing either way
local real_key = band.studio_update_key
band.studio_update_key = function() return nil end
fs, copied = {}, {}
put(HERE, "0.60.1"); put(THERE, "0.60.2"); verified = { [HERE] = true, [THERE] = true }
assert(pass() == nil and #copied == 0, "a studio without an update key: as before")
band.studio_update_key = real_key
-- a guest's computer: nothing
guest = true
assert(pass() == nil and #copied == 0, "never on a guest's computer")
guest = false
-- the owner: its newer signed copy goes out, the cloud's stale module with it
fs, copied, logs = {}, {}, {}
role, cfg.user = "owner", "James"
put(HERE, "0.60.4", "sha256 " .. ("5"):rep(64) .. " lib/mac/helper\n"); fs[HERE .. "/lib/mac/helper"] = "bin"
put(THERE, "0.60.3"); fs[THERE .. "/lib/stale.lua"] = "x"
verified = { [HERE] = true, [THERE] = true }
n = pass()
assert(n and fs[THERE .. "/lib/band.lua"]:find("0.60.4", 1, true) and fs[THERE .. "/lib/mac/helper"] == "bin" and not fs[THERE .. "/lib/stale.lua"], "out, whole")
assert(logs[#logs]:find("is in the Google Drive copy", 1, true), "said: " .. tostring(logs[#logs]))
-- an owner whose studio copy isn't signed sends nothing
fs, copied = {}, {}
put(HERE, "0.60.5"); put(THERE, "0.60.4")
verified = { [THERE] = true }
assert(pass() == nil and #copied == 0, "an unsigned copy never goes to the cloud")
os.remove = real_remove
print("ok")
