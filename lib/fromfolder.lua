-- Updates through the studio's folder (James, 0.59.24: "make sure the chilio and smiley studios groups are set to update via the folder
-- since we'll be doing a lot of work and debugging through everyone... inviting someone to a studio with this setup should be part of
-- the invite... so no extra setup on collaborators' ends").
-- A studio's owner or an admin turns it on (band.json "updates": "folder", Settings > Studio). Then each computer in the studio runs
-- StudioSync from <studio>/_tools/studiosync: Autostart moves it there by itself, once all of that copy has arrived (band.files_complete)
-- and it's this version or newer. A new person installs as usual (ReaPack) and moves once they're let in and the folder has come, so the
-- invitation needs nothing more. An action of the copy it ran from before (a toolbar button, a menu, a key) hands over to the folder's
-- (fromfolder.handoff, at the top of each script), so old code never runs beside new. A copy run from a git checkout (a developer's) stays
-- where it is. Code that changes in the folder is taken without asking (the studio trusts its members: band.code_guard, since 0.59.32).
-- A guest's computer never moves to it, and a guest with a project list doesn't sync _tools at all (lib/songsync.lua). Full review, 0.59.44.
-- (Round 1 review, 0.59.45: every guest, with a list or not (a guest mark naming this computer: removal.am_guest), and a computer that's no
-- longer in a studio that updates through its folder moves back to the copy it ran from before, remembered when it moved: the move was one-way.)
local band = require("band")
local ff = {}

local function norm(p) return band.norm(p or ""):lower() end
local function version_of(dir) return band.version_on_disk(dir) end
-- a is b or newer ("0.59.24" >= "0.59.9"). Pure.
function ff.at_least(a, b)
  local x, y = {}, {}
  for n in tostring(a):gmatch("%d+") do x[#x + 1] = tonumber(n) end
  for n in tostring(b):gmatch("%d+") do y[#y + 1] = tonumber(n) end
  for i = 1, math.max(#x, #y) do
    local p, q = x[i] or 0, y[i] or 0
    if p ~= q then return p > q end
  end
  return true
end
function ff.target(root) return band.norm(root) .. "/_tools/studiosync" end
function ff.on(root) return root and require("groups").trusted(root).updates == "folder" end
-- Is `dir` the copy in a studio that updates through its folder (its owner chose it)? Then a new version put there is taken without asking:
-- a studio sharing a folder trusts its members (James, 0.59.19), and Chilio's computer asked at every release. 0.59.32.
function ff.trusted_copy(dir)
  local root = band.norm(dir or ""):match("^(.*)/_tools/studiosync$")
  return root ~= nil and ff.on(root) == true
end
local function dev_copy(dir) return reaper.file_exists(band.norm(dir) .. "/.git/HEAD") or reaper.file_exists(band.norm(dir) .. "/.git") end

-- The studio this computer should run StudioSync from (the one in front first), or nil.
function ff.wanted(cfg)
  local list = {}
  if cfg and cfg.root then list[1] = cfg.root end
  for _, g in ipairs(band.bands()) do list[#list + 1] = g.root end
  for _, r in ipairs(list) do
    local guest = select(2, pcall(function() return require("access").mine(r) ~= nil or require("removal").am_guest(r) end)) == true -- (not a guest's to run)
    if ff.on(r) and not guest and reaper.file_exists(r .. "/_band/band.json") then return r end
  end
end
-- The copy this computer ran from before it moved to a studio's folder: remembered at the move ("run from before"), else the startup block's
-- fallback (written at every move since 0.59.24). -> it, or nil.
local function before(t)
  local b = reaper.GetExtState(band.SECTION, "run from before")
  if b == "" then
    local text = band.read(reaper.GetResourcePath() .. "/Scripts/__startup.lua") or ""
    for p in text:gmatch("%[%[([^%]]-)/StudioSync %- Autostart%.lua%]%]") do
      if norm(p) ~= norm(t) and not norm(p):find("/_tools/studiosync$") and norm(p) ~= norm(band.last_good_dir()) then b = p; break end
    end
  end
  return b ~= "" and reaper.file_exists(b .. "/StudioSync - Autostart.lua") and band.norm(b) or nil
end

-- From Autostart: moves this computer to the studio's copy when it should. `dir`: where this copy runs from. -> the copy it moved to, or nil.
local looked, back_seen, said_older, no_id = -math.huge, 0, nil, 0
function ff.tick(dir, cfg)
  if reaper.time_precise() - looked < 60 then return end
  looked = reaper.time_precise()
  if dev_copy(dir) then return end
  -- (not before Syncthing has said which computer this is: a guest is known by a mark naming it, and on the first look a guest with a leftover
  -- copy in the folder was moved to it, then back. Round 2 review, 0.59.46)
  local okid, id = pcall(require("services").my_device_id)
  if not (okid and id) then
    -- (said once, after five looks: a Flatpak REAPER, or a Syncthing run as a service with its config elsewhere, never answers, and then this
    -- computer never moves. It keeps waiting for the ID: James's decision, Round 3 review, 0.59.48)
    no_id = no_id + 1
    if no_id == 5 then band.log("Syncthing hasn't said which computer this is, so StudioSync stays on " .. band.norm(dir) .. " (a studio that updates through its folder moves it once Syncthing answers)") end
    return
  end
  local front = reaper.GetExtState(band.SECTION, "sync_root") -- (not band.settings: on a first run it asks for a name)
  cfg = cfg or (front ~= "" and { root = front } or nil)
  local root = ff.wanted(cfg)
  if not root then -- (no studio says so now: a copy this computer moved to that's gone is forgotten, and it runs where it is)
    local run = reaper.GetExtState(band.SECTION, "run from")
    if run ~= "" and not reaper.file_exists(run .. "/StudioSync - Autostart.lua") then reaper.DeleteExtState(band.SECTION, "run from", true) end
    -- (and from a studio's folder it no longer should run from (updates off, left, or a guest here), back to the copy it ran from before, once
    -- that's been so for two looks a minute apart: one look in a moment with nothing checked yet mustn't move it. Round 1 review, 0.59.45)
    -- (and from the last-good copy it was moved to (below), on to the copy it ran from before once that's at least as new: it stayed on the
    -- last-good copy for good, and an update through ReaPack never reached it. One version read a minute, only then. Round 3 review, 0.59.48)
    local lg = band.last_good_dir()
    local on_lg = run ~= "" and norm(run) == norm(lg)
    local from = on_lg and run or norm(run):find("/_tools/studiosync$") and run or (norm(dir):find("/_tools/studiosync$") and dir) or nil
    local back = from and before(from)
    if back and norm(run) == norm(back) then back = nil end -- (moved back already, waiting for REAPER's next start)
    -- (never to an older copy than the one running: it went back to whatever ReaPack copy it had when it moved, however old. Then this computer's
    -- last good copy, if it's at least as new, else it stays where it is; either way it says to update through ReaPack. James's decision,
    -- Round 2 review, 0.59.46)
    local older = back and not ff.at_least(band.version_on_disk(back) or "0", band.VERSION)
    if older and on_lg then back = nil -- (on the last-good copy already: it waits there, said when it moved)
    elseif older then
      local lv = band.version_on_disk(lg)
      local say = "the copy this computer ran StudioSync from before (" .. back .. ", " .. tostring(band.version_on_disk(back)) .. ") is older than " .. band.VERSION
      if lv and ff.at_least(lv, band.VERSION) and norm(run) ~= norm(lg) and norm(dir) ~= norm(lg) then back = lg; say = say .. ": it runs from its last good copy instead"
      else back = nil; say = say .. ": it stays on the studio's copy" end
      if said_older ~= say then said_older = say; band.log(say .. ". Update StudioSync through ReaPack (Extensions > ReaPack > Synchronize packages)") end
    end
    back_seen = back and back_seen + 1 or 0
    if back and back_seen >= 2 then
      back_seen = 0
      local ok, why = require("tools").set_autostart(true, back)
      if not ok then band.log("couldn't move StudioSync back from the studio's folder: " .. tostring(why)); return end
      pcall(band.sync_actions, back)
      reaper.SetExtState(band.SECTION, "run from", back, true) -- (an old button or key of the studio's copy hands over to this one)
      -- (kept when it's the last-good copy it moves to: the copy it ran from before is where it goes once that's updated. Round 3 review, 0.59.48)
      if norm(back) ~= norm(lg) then reaper.DeleteExtState(band.SECTION, "run from before", true) end
      band.log("StudioSync runs from " .. back .. " again from REAPER's next start: this computer no longer runs the studio's copy")
      return back
    end
    return
  end
  back_seen = 0
  local t = ff.target(root)
  if norm(dir) == norm(t) then
    if norm(reaper.GetExtState(band.SECTION, "run from")) ~= norm(t) then reaper.SetExtState(band.SECTION, "run from", t, true) end
    return
  end
  -- (moved already, waiting for REAPER's next start: the startup block, the actions and two settings were written again every minute. Round 1 review, 0.59.45)
  if norm(reaper.GetExtState(band.SECTION, "run from")) == norm(t) then return end
  if not reaper.file_exists(t .. "/StudioSync - Autostart.lua") or not band.files_complete(t) then return end
  local v = version_of(t)
  if not v or not ff.at_least(v, band.VERSION) then return end
  local ok, why = require("tools").set_autostart(true, t, band.norm(dir)) -- (this copy, should that folder go)
  if not ok then band.log("couldn't move StudioSync to the studio's folder: " .. tostring(why)); return end
  if norm(dir) ~= norm(band.last_good_dir()) then reaper.SetExtState(band.SECTION, "run from before", band.norm(dir), true) end -- (for the move back)
  pcall(band.sync_actions, t)
  reaper.SetExtState(band.SECTION, "update ok", v, true) -- (the studio's own choice: its copy, this version, said yes to here)
  reaper.SetExtState(band.SECTION, "run from", t, true)
  band.log("StudioSync runs from " .. tostring(band.info(root).name) .. "'s folder from REAPER's next start: updates put there reach this computer without asking")
  return t
end

-- The menu extension (extension/reaper_menu.cpp) from the copy StudioSync runs from, when it's newer than the one REAPER loaded: ReaPack
-- updates it only for a ReaPack install, so a computer running StudioSync from a studio's folder or a checkout kept an old one, and Health
-- said "older" for good (James's desktop and laptop: 1.0.5 against 1.0.6, 0.59.27). The loaded file is renamed, not overwritten (Windows
-- holds it; a Mac's loaded dylib mustn't change under it), and the new one goes in beside it: REAPER loads it at its next start.
-- -> true when it put one in.
local ext_done, arch_seen = false, nil
function ff.extension_tick(dir)
  if ext_done then return end
  local have, want = reaper.GetExtState(band.SECTION, "menu extension"), require("tools").EXT_WANT
  if have == "" or band.compare_versions(have, want) >= 0 then return end
  -- (Linux: REAPER says "Other" on an ARM computer too, so the machine's own word: Round 1 review, 0.59.45. Asked once: Round 2 review, 0.59.46)
  arch_seen = arch_seen or (band.LINUX and ((reaper.ExecProcess("/bin/uname -m", 3000) or ""):match("^0\n(%S+)") or "") or "")
  local arch = arch_seen
  local name = band.WIN and "reaper_studiosync-x64.dll" or band.MAC and "reaper_studiosync.dylib"
    or (reaper.GetOS():find("arm") or reaper.GetOS():find("aarch64") or arch == "aarch64" or arch == "arm64") and "reaper_studiosync-aarch64.so" or "reaper_studiosync-x86_64.so"
  local from, to = band.norm(dir) .. "/extension/" .. name, band.norm(reaper.GetResourcePath()) .. "/UserPlugins/" .. name
  -- (from a studio's folder with an update key: only a copy signed with it hands over its extension, checked once. Signed updates)
  local ukey = band.from_shared(dir) and band.update_key(dir)
  if ukey then
    local ok, why = band.signed_ok(dir, ukey)
    if not ok then ext_done = true; band.log("The menu extension in " .. band.norm(dir) .. " wasn't put in: " .. tostring(why)); return end
  end
  local new = band.read(from)
  if not new or #new < 10000 then return end
  if band.read(to) == new then ext_done = true; return end -- (already in, waiting for REAPER's restart)
  -- (only the build this code wants, EXT_VERSION as the binary holds it: the realtime branch shipped a 1.0.6 Mac build beside a 1.0.11
  -- want, and the Mac's 1.0.10 was swapped for it at the next start. rt)
  if not new:find(want .. "\0", 1, true) then ext_done = true; band.log("The menu extension in " .. band.norm(dir) .. " isn't " .. want .. ": left as it is"); return end
  ext_done = true
  local old = to .. ".old-" .. have
  os.remove(old)
  if reaper.file_exists(to) and not os.rename(to, old) then band.log("couldn't put the new menu extension in (" .. to .. " is held): restart REAPER and it tries again"); return end
  local ok, err = pcall(band.write_atomic, to, new)
  if not ok then os.rename(old, to); band.log("couldn't put the new menu extension in: " .. tostring(err)); return end
  band.log("StudioSync's menu extension " .. want .. " is in place of " .. have .. ": REAPER loads it when it next starts")
  return true
end

-- ---- Signed updates (docs/realtime-roadmap.md "Signed updates", extension 1.0.9) ----
-- The owner's update key: $STUDIOSYNC_UPDATE_KEY, else ~/.studiosync/update-key (tools/sign_release.py reads the same), outside every synced
-- folder. -> the path, or nil.
function ff.update_key_path()
  local p = os.getenv("STUDIOSYNC_UPDATE_KEY")
  if p and p ~= "" then return band.norm(p) end
  local home = os.getenv("USERPROFILE") or os.getenv("HOME")
  return home and home ~= "" and (band.norm(home) .. "/.studiosync/update-key") or nil
end
local SIGNED_PREFIX = "StudioSync files.txt v1\n" -- (extension/sign.h SIGN_FILES_PREFIX)
local SHIPPED = { "lib/mac", "lib/ninjam", "lib/listen", "lib/toolbar_icons" } -- (tools/sign_release.py shipped_files)
local EXTENSIONS = { "reaper_studiosync-x64.dll", "reaper_studiosync.dylib", "reaper_studiosync-x86_64.so", "reaper_studiosync-aarch64.so" }
local function all_files(dir, rel, out)
  for _, f in ipairs(band.files(dir .. "/" .. rel)) do if f:sub(1, 1) ~= "." then out[#out + 1] = rel .. "/" .. f end end
  for _, d in ipairs(band.subdirs(dir .. "/" .. rel)) do if d:sub(1, 1) ~= "." then all_files(dir, rel .. "/" .. d, out) end end
end
local here = band.norm((debug.getinfo(1, "S").source:gsub("^@", ""))):match("^(.*)/lib/[^/]+$") -- (the copy this computer runs)
-- The copy in `dir` (a studio's folder copy) signed with the owner's key, as tools/sign_release.py does: lib/files.txt written again (version,
-- each code file's length and FNV hash, a SHA-256 row per file that ships) and lib/files.txt.sig. Only code this computer has said yes to (the
-- code check's record for that copy) or the code running here: signing whatever is in the folder would bless a member's change. The helpers
-- (lib/mac, lib/ninjam, ...) are signed as they are. -> true, or false and why.
function ff.sign_copy(dir, keypath)
  dir, keypath = band.norm(dir), keypath or ff.update_key_path()
  if not (reaper.StudioSync_Sign and reaper.StudioSync_FileHash and reaper.StudioSync_KeyCreate) then return false, "signing needs StudioSync's extension 1.0.9 or newer" end
  if not (keypath and reaper.file_exists(keypath)) then return false, "there's no update key on this computer (" .. tostring(keypath) .. ")" end
  local version = band.version_on_disk(dir)
  if not version then return false, dir .. " has no StudioSync in it" end
  local now = band.code_files(dir)
  local function same(files)
    if type(files) ~= "table" then return false end
    for p, h in pairs(now) do if files[p] ~= h then return false end end
    for p in pairs(files) do if now[p] == nil then return false end end
    return true
  end
  local had = band.approved_code(dir)
  if not (same(had and had.files) or (here and here:lower() ~= dir:lower() and same(band.code_files(here)))) then
    return false, "the code in " .. dir .. " isn't code this computer has said yes to (run StudioSync from it once, or sign it with tools/sign_release.py)"
  end
  local rels, rows, shipped = {}, { "version " .. version }, {}
  for p in pairs(now) do rels[#rels + 1] = p end
  table.sort(rels)
  for _, p in ipairs(rels) do
    local s = band.read(dir .. "/" .. p) or ""
    if band.code_hash(s) ~= now[p] then return false, p .. " changed while it was being signed: try again" end
    rows[#rows + 1] = p .. "\t" .. (#s - select(2, s:gsub("\r", ""))) .. "\t" .. now[p]
    shipped[#shipped + 1] = p
  end
  for _, sub in ipairs(SHIPPED) do all_files(dir, sub, shipped) end
  for _, n in ipairs(EXTENSIONS) do if reaper.file_exists(dir .. "/extension/" .. n) then shipped[#shipped + 1] = "extension/" .. n end end
  for _, rel in ipairs(shipped) do
    local h = reaper.StudioSync_FileHash(dir .. "/" .. rel)
    if #h ~= 64 then return false, "couldn't read " .. rel end
    rows[#rows + 1] = "sha256 " .. h .. " " .. rel
  end
  local text = table.concat(rows, "\n") .. "\n"
  local sig = reaper.StudioSync_Sign(keypath, SIGNED_PREFIX .. text)
  if #sig ~= 128 then return false, "couldn't sign with the key at " .. keypath end
  band.write_atomic(dir .. "/lib/files.txt", text)
  band.write_atomic(dir .. "/lib/files.txt.sig", sig .. "\n")
  local check = reaper.StudioSync_VerifyFiles(dir, reaper.StudioSync_KeyCreate(keypath))
  if not check:match("^ok ") then return false, "signed, but the check of it says: " .. check end
  band.log("StudioSync " .. version .. " in " .. dir .. " is signed with this computer's update key")
  return true
end
-- Settings > Studio, the owner, once: this computer's update key made (or read, if it's there already), the studio's folder copy signed with it
-- first when it isn't (so nobody is refused the moment the key appears), then the public key written to band.json ("update_key") and pinned
-- here. Every computer in the studio needs extension 1.0.9 first: one without it refuses a keyed studio's folder copy. -> true and the public
-- key, or false and why.
function ff.create_update_key(root)
  if not (reaper.StudioSync_KeyCreate and reaper.StudioSync_Sign and reaper.StudioSync_VerifyFiles) then return false, "This needs StudioSync's extension 1.0.9 or newer." end
  local groups = require("groups")
  if groups.role(root, reaper.GetExtState(band.SECTION, "user")) ~= "owner" then return false, "Only the studio's owner can set its update key." end
  local path = ff.update_key_path()
  if not path then return false, "No home folder to keep the key in: set STUDIOSYNC_UPDATE_KEY to a file path." end
  if band.from_shared(path) then return false, "The key would be inside a shared folder (" .. path .. "): set STUDIOSYNC_UPDATE_KEY to a file outside it." end
  reaper.RecursiveCreateDirectory(path:match("^(.*)/[^/]+$") or path, 0)
  local pub = reaper.StudioSync_KeyCreate(path)
  if #pub ~= 64 then return false, "Couldn't make or read the update key at " .. path .. "." end
  local t = ff.target(root)
  if reaper.file_exists(t .. "/lib/band.lua") and not reaper.StudioSync_VerifyFiles(t, pub):match("^ok ") then
    local ok, why = ff.sign_copy(t, path)
    if not ok then return false, "The studio's copy of StudioSync couldn't be signed, so the key wasn't published: " .. why end
  end
  if not groups.edit(root, function(j) j.update_key = pub end) then return false, "band.json couldn't be written yet: try again in a minute." end
  band.pin_update_key(root, pub)
  band.log("The studio's update key is set (" .. pub:sub(1, 16) .. "...): its folder copy of StudioSync now runs only when signed with the key in " .. path)
  return true, pub
end

-- At the top of each StudioSync script: run from a copy this computer has moved away from (an old toolbar button or key), it starts the
-- same script in the copy it runs from now, and stops. `source`: debug.getinfo(1, "S").source. -> true when it handed over.
function ff.handoff(source)
  -- (not inside a reload (band.reload sets this, false or a version): the old loop stopped mid-session and its exit steps ran, while the copy
  -- moved to waits for REAPER's next start as a move intends. Round 4 review, 0.59.49)
  if _G.STUDIOSYNC_RELOAD_APPROVED ~= nil then return false end
  local run = reaper.GetExtState(band.SECTION, "run from")
  if run == "" then return false end
  local path = tostring(source or ""):gsub("^@", ""):gsub("\\", "/")
  local dir, file = path:match("^(.*)/(StudioSync %- [^/]+%.lua)$")
  -- (nor the last-good copy: the startup block started it because the copy it runs from failed to load. Round 1 review, 0.59.45)
  if not dir or norm(dir) == norm(run) or dev_copy(dir) or norm(dir) == norm(band.last_good_dir()) then return false end
  local there = band.norm(run) .. "/" .. file
  if not reaper.file_exists(there) then return false end
  -- (Live sync through a free launcher: its own action ignores a second start while it runs for another tab, and nothing started. Round 2 review, 0.59.46)
  if file == "StudioSync - Live sync.lua" then
    if not band.start_live(band.norm(run)) then band.log("Live sync has no free slot: close some StudioSync tabs (17 at most run at once)") end
    return true
  end
  local id = reaper.AddRemoveReaScript(true, 0, there, true)
  if id == 0 then return false end
  reaper.Main_OnCommand(id, 0)
  return true
end

return ff
