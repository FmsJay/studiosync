-- Deleting this computer's copy of a project, to free the space: only once it's confirmed somewhere else, and so that nobody else loses
-- anything. The danger is Syncthing: a file deleted in a shared folder is deleted for everyone. So the project goes on this computer's
-- ignore list first (lib/songsync.lua), Syncthing is seen to have read that, and only then do the files go, to the Recycle Bin or Trash.
-- Its listing stays (session.json, chat and the like), so it's still on the Projects page; opening it brings it back.
--   Elsewhere means: Google Drive holds every file of it, or another computer of the group has said it holds exactly these files. Each computer
--   publishes that itself (_band/holds/<name>.json: copy.publish_holds), as Syncthing can't tell: /rest/db/remoteneed, completion and even a
--   file's availability all read as "has it" for a computer that's ignoring it and hasn't got one byte. Found the hard way on 0.50.0.
local band = require("band")
local copy = { DRIVE_SETTLED = 1800 }

local WIN = reaper.GetOS():find("^Win") ~= nil
-- What stays of a project, as the ignore list keeps it (songsync.LISTING).
local KEEP_TOP = { ["session.json"] = true, ["folder.json"] = true, ["live.json"] = true, invites = true, chat = true, rooms = true }
local KEEP_ROOM = { ["room.json"] = true, summary = true, status = true, chat = true }

-- Every file of the project that would go, relative to its folder, and the top-most paths to remove. Reads the folders.
function copy.contents(dir)
  local files, paths = {}, {}
  local function walk(rel)
    for _, f in ipairs(band.files(dir .. "/" .. rel)) do files[#files + 1] = rel .. "/" .. f end
    for _, d in ipairs(band.subdirs(dir .. "/" .. rel)) do walk(rel .. "/" .. d) end
  end
  for _, f in ipairs(band.files(dir)) do
    if not KEEP_TOP[f] then files[#files + 1] = f; paths[#paths + 1] = f end
  end
  for _, d in ipairs(band.subdirs(dir)) do
    if not KEEP_TOP[d] then walk(d); paths[#paths + 1] = d end
  end
  for _, room in ipairs(band.subdirs(dir .. "/rooms")) do
    local r = "rooms/" .. room
    for _, f in ipairs(band.files(dir .. "/" .. r)) do
      if not KEEP_ROOM[f] then files[#files + 1] = r .. "/" .. f; paths[#paths + 1] = r .. "/" .. f end
    end
    for _, d in ipairs(band.subdirs(dir .. "/" .. r)) do
      if not KEEP_ROOM[d] then walk(r .. "/" .. d); paths[#paths + 1] = r .. "/" .. d end
    end
  end
  return files, paths
end

-- A file's date newer than `since`, both as "2026.11.04 03:44:00". Pure.
function copy.is_young(modified, since) return modified:match("^%d%d%d%d%.") ~= nil and modified > since end
-- One word for a set of files: their names, whatever order they're read in. Pure. (A file that's there is whole: Syncthing moves it in when it's done.)
function copy.digest(files)
  local names = {}
  for _, f in ipairs(files) do
    local base = f:match("[^/]+$")
    if not base:find("^%.") and not base:find("^~") and not base:find("sync%-conflict", 1) then names[#names + 1] = f end
  end
  table.sort(names)
  local h = -3750763034362895579 -- (FNV-1a, 64 bits)
  local text = table.concat(names, "\n")
  for i = 1, #text do h = (h ~ text:byte(i)) * 1099511628211 end
  return string.format("%016x", h), #names
end
-- Who else says they hold exactly this: their names. `lists`: { { user, songs = { [song] = { digest } } } }. Pure.
function copy.holders(lists, song, digest, me)
  local out = {}
  for _, l in ipairs(lists) do
    local e = type(l.songs) == "table" and l.songs[song]
    if l.user ~= me and type(e) == "table" and e.digest == digest then out[#out + 1] = tostring(l.user) end
  end
  table.sort(out)
  return out
end
local function holds_file(root, user) return root .. "/_band/holds/" .. (user:gsub("[^%w%-_ ]", "")) .. ".json" end
function copy.read_holds(root)
  local out = {}
  for _, f in ipairs(band.files(root .. "/_band/holds", ".json")) do
    local l = band.read_json(root .. "/_band/holds/" .. f)
    if type(l) == "table" and type(l.user) == "string" then out[#out + 1] = l end
  end
  return out
end
-- This computer says what it holds, one project of each group per look (about every 30 s: lib/removal.lua, with any tab or none).
local turn = {}
function copy.publish_holds(root, me)
  local ss = require("songsync")
  local here = ss.here({ root = root, user = me })
  local path = holds_file(root, me)
  local mine = band.read_json(path)
  mine = type(mine) == "table" and type(mine.songs) == "table" and mine or { songs = {} }
  local changed, is_here = false, {}
  -- (only this group's: the list is the computer's, and other groups' projects taking turns left a new one waiting 5 minutes: PC + Mac, 0.52.1)
  local in_group = {}
  for _, s in ipairs(here) do
    is_here[s] = true
    if reaper.file_exists(root .. "/" .. s .. "/session.json") then in_group[#in_group + 1] = s end
  end
  for s in pairs(mine.songs) do if not is_here[s] then mine.songs[s], changed = nil, true end end
  if #in_group > 0 then
    turn[root] = (turn[root] or 0) % #in_group + 1
    local song = in_group[turn[root]]
    local d, n = copy.digest((copy.contents(root .. "/" .. song)))
    local e = mine.songs[song]
    if n > 0 and not (type(e) == "table" and e.digest == d) then mine.songs[song], changed = { digest = d, n = n }, true end
  end
  if changed then
    mine.user, mine.time = me, os.date("!%Y-%m-%dT%H:%M:%SZ")
    reaper.RecursiveCreateDirectory(root .. "/_band/holds", 0)
    band.write_json(path, mine)
  end
end
-- Where Drive keeps a room's file: a take may sit in takes or _trash, whichever the group has it in. Everything else at its own path.
function copy.drive_paths(rel)
  local room, sub, f = rel:match("^(rooms/[^/]+)/([^/]+)/(.+)$")
  if room and (sub == "takes" or sub == "_trash") then return { room .. "/takes/" .. f, room .. "/_trash/" .. f } end
  return { rel }
end
-- What the Drive copy doesn't carry, so it isn't asked of it: working files, and each computer's own bits.
function copy.drive_needs(rel)
  if rel:find("/peaks/", 1, true) or rel:find("%.reapeaks$") then return false end -- (REAPER remakes them, and Drive never gets them: a project that had been opened could never count: Mac, 0.51.15)
  local sub = rel:match("^rooms/[^/]+/([^/]+)/")
  return sub == "takes" or sub == "_trash" or sub == "media" or sub == "events" or sub == "midi" or sub == "recall"
end

-- Is a project open in a tab here?
function copy.open_here(root, song)
  for i = 0, math.huge do
    local p = reaper.EnumProjects(i)
    if not p then return false end
    local b = band.binding(p)
    if b and b.song == song and band.for_tab({ root = root, user = "" }, b).root == root then return true end
  end
end

-- A job: one project at a time, a slice each frame, so the panel keeps drawing. { songs, root, step, words, ... }
copy.job = nil
function copy.start(root, user, songs)
  for _, s in ipairs(songs) do
    if copy.open_here(root, s) then return nil, "'" .. s .. "' is open in a tab here: close its tab first." end
  end
  copy.job = { root = root, user = user, songs = songs, i = 1, step = "scan", words = "Getting ready", done = {}, skipped = {} }
  return true
end
function copy.cancel() copy.job = nil end

local function enc(s) return (s:gsub("[^%w%-_%.]", function(c) return string.format("%%%02X", c:byte()) end)) end
-- Syncthing has finished looking at the folder?
local function idle(id)
  local a = require("services").ask("/rest/db/status?folder=" .. id, 5)
  return a and a:find('"state":%s*"idle"') ~= nil
end
-- The script that moves paths into the Mac's Trash, each named for the project it came from (label, if any). Pure.
-- shortcut: a plain move, so Finder's Put Back stays greyed out; going through Finder would add an automation prompt, opening the project brings it back anyway.
-- `failed`: a file touched when a move is refused (macOS guards the Trash: a program without Full Disk Access may not write there. Mac review,
-- 0.58.62), so the message says so instead of "still on its way".
-- linux: the desktop's own Trash through `gio trash` (its own name kept; Restore puts it back where it was), not the Mac's ~/.Trash. 0.58.74
function copy.trash_script(paths, label, stamp, failed, linux)
  local sq = function(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
  local lines = {}
  for i, p in ipairs(paths) do
    local name = "StudioSync - " .. (label and label .. " - " or "") .. stamp .. " - " .. i .. " " .. p:match("[^/]+$")
    local move = linux and ("gio trash " .. sq(p)) or ("mv " .. sq(p) .. ' "$HOME/.Trash/"' .. sq(name))
    -- (if/then: with `[ -e ] && mv || touch` a path already gone, say Syncthing took it meanwhile, read as a refused move. Review, 0.58.67)
    lines[#lines + 1] = "if [ -e " .. sq(p) .. " ]; then " .. move .. (failed and (" || touch " .. sq(failed)) or "") .. "; fi" -- (one line per path)
  end
  return table.concat(lines, "\n") .. "\n"
end
-- Into the Recycle Bin or Trash, in the background: copy.bin_start, then copy.bin_poll each frame until it says how many paths couldn't go
-- (a file REAPER still has open, usually). Waited for in a loop, REAPER stood still for up to 20 s (review, 0.58.53).
local function left_now(paths)
  local left = 0
  for _, p in ipairs(paths) do
    if reaper.file_exists(p) or reaper.EnumerateFiles(p, 0) or reaper.EnumerateSubdirectories(p, 0) then left = left + 1 end
  end
  return left
end
function copy.bin_poll(h)
  if h.left then return h.left end
  local done = reaper.file_exists(h.tmp .. ".done") or reaper.time_precise() - h.t0 > (WIN and 20 or 300)
    or (reaper.time_precise() - h.t0 > 1 and left_now(h.paths) == 0)
  if not done then return nil end
  if reaper.file_exists(h.tmp .. ".notrash") then
    os.remove(h.tmp .. ".notrash")
    band.log((band.LINUX and "The Trash refused " or "macOS didn't let StudioSync move ") .. tostring(h.label or "some files") ..
      (band.LINUX and " (gio trash), so it's left where it is: delete it in your file manager if you mean to" or " to the Trash, so it's left where it is: delete it in Finder if you mean to"))
  end
  if reaper.file_exists(h.tmp .. ".nobin") then
    os.remove(h.tmp .. ".nobin")
    band.log("left " .. tostring(h.label or "some files") .. " where it is: that drive has no Recycle Bin, so deleting would be for good. Delete it by hand if you mean to")
  end
  for _, e in ipairs({ ".done", ".cmd", ".vbs", ".ps1", ".sh" }) do if reaper.file_exists(h.tmp .. e) then os.remove(h.tmp .. e) end end
  h.left = left_now(h.paths) -- shortcut: what hasn't gone by the time limit counts as left, though it may still be on its way
  return h.left
end
-- A whole group's copy (copy.delete_group) still waits here: a one-off its page asks for and expects done.
function copy.bin(paths, label)
  local h = copy.bin_start(paths, label)
  local left
  repeat left = copy.bin_poll(h) until left
  return left
end
function copy.bin_start(paths, label)
  if #paths == 0 then return { left = 0 } end
  local tmp = (os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"):gsub("\\", "/"):gsub("/+$", "") .. "/bandsync-bin-" .. os.time() .. "-" .. math.floor(reaper.time_precise() * 1000) % 1000000 -- (two in one second shared one script)
  local h = { tmp = tmp, paths = paths, label = label, t0 = reaper.time_precise() }
  if WIN then
    -- In the background, with no error boxes: a big folder takes minutes, and a file in use raised a box nobody could see on a hidden PowerShell, with REAPER
    -- stopped until it was killed (PC, 0.54.1, 17 minutes). shortcut: what doesn't go in 20 s is reported as left, though it may still be on its way.
    -- (PowerShell ends a '...' string at the curly quotes too: a file named with one ran the rest of its name as code. Security review, 0.58.76)
    local q = function(s) return "'" .. s:gsub("'", "''"):gsub("\226\128[\152-\155]", "%0%0") .. "'" end
    local lines = { "Add-Type @'", "using System; using System.Runtime.InteropServices;", "public static class StudioSyncBin {",
      "  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] public struct Op { public IntPtr hwnd; public uint func; public string from; public string to; public ushort flags; public bool aborted; public IntPtr maps; public string title; }",
      '  [DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern int SHFileOperation(ref Op op);',
      "  [StructLayout(LayoutKind.Sequential)] public struct Bin { public int size; public long bytes; public long items; }",
      '  [DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern int SHQueryRecycleBin(string root, ref Bin info);', "}", "'@" }
    -- (a drive with no Recycle Bin, a USB stick or a network share, deletes for good and asks on a window nobody sees: such paths are left,
    -- and said. Review, 0.58.47)
    for _, p in ipairs(paths) do
      local wp = q((p:gsub("/", "\\")))
      lines[#lines + 1] = "$b = New-Object StudioSyncBin+Bin; $b.size = [Runtime.InteropServices.Marshal]::SizeOf($b); " ..
        "if ([StudioSyncBin]::SHQueryRecycleBin([IO.Path]::GetPathRoot(" .. wp .. "), [ref]$b) -ne 0) { Set-Content -LiteralPath " .. q((tmp:gsub("/", "\\")) .. ".nobin") .. " 1 } else { " ..
        "$op = New-Object StudioSyncBin+Op; $op.func = 3; $op.flags = 0x0654; $op.from = " .. wp .. ' + [char]0 + [char]0; [void][StudioSyncBin]::SHFileOperation([ref]$op) }'
    end
    lines[#lines + 1] = "Set-Content -LiteralPath " .. q((tmp:gsub("/", "\\")) .. ".done") .. " 1"
    band.write_atomic(tmp .. ".ps1", "\239\187\191" .. table.concat(lines, "\r\n") .. "\r\n")
    band.write_atomic(tmp .. ".cmd", '@chcp 65001 >nul\r\n@powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' .. tmp .. '.ps1"\r\n') -- (chcp: UTF-8 paths, as services.background. 0.58.78)
    band.write_atomic(tmp .. ".vbs", 'CreateObject("WScript.Shell").Run """" & WScript.Arguments(0) & """", 0, False\r\n')
    reaper.ExecProcess(string.format('wscript.exe //B //Nologo "%s.vbs" "%s.cmd"', tmp, tmp), -1)
    return h
  end
  band.write_atomic(tmp .. ".sh", copy.trash_script(paths, label, os.date("%Y-%m-%d %H.%M.%S"), tmp .. ".notrash", band.LINUX) .. "touch '" .. tmp .. ".done'\n")
  reaper.ExecProcess("/bin/sh '" .. tmp .. ".sh'", -1)
  return h
end

-- One step of the job. Returns nothing; the job's fields say where it stands. Called each frame by the Projects page.
function copy.tick()
  local j = copy.job
  if not j or j.ask or j.finished then return end
  local services, ss, info = require("services"), require("songsync"), band.info(j.root)
  local song = j.songs[j.i]
  if not song then j.finished = true; return end
  local dir = j.root .. "/" .. song
  if j.step == "scan" then
    j.files, j.paths = copy.contents(dir)
    j.words = "Looking at '" .. song .. "'"
    if #j.files == 0 and #j.paths == 0 then -- only its listing is here
      j.skipped[#j.skipped + 1] = song .. " (nothing but its listing is here)"
      j.i, j.step = j.i + 1, "scan"
      return
    end
    j.step, j.at, j.places = "peers", 1, {}
  elseif j.step == "peers" then
    j.words = "Looking for who else holds '" .. song .. "'"
    local digest = copy.digest(j.files)
    local holders = copy.holders(copy.read_holds(j.root), song, digest, j.user)
    for _, h in ipairs(holders) do j.places[#j.places + 1] = h end
    j.step = "drive"
  elseif j.step == "drive" then
    j.droot = j.droot or require("drive").root({ root = j.root }) or false
    if not j.droot or j.drive_bad then j.step = "ask"; return end
    local t0 = reaper.time_precise()
    j.words = string.format("Checking Google Drive for '%s': %d of %d", song, j.at - 1, #j.files)
    while j.at <= #j.files and reaper.time_precise() - t0 < 0.01 do
      local rel = j.files[j.at]
      if copy.drive_needs(rel) then
        local found = false
        for _, p in ipairs(copy.drive_paths(rel)) do
          local there = j.droot .. "/" .. song .. "/" .. p
          if not found and reaper.file_exists(there) then
            found = true
            -- (on Drive's mount doesn't mean uploaded yet. Half an hour there is as near as a script can tell: Mac, 0.50.4)
            if reaper.JS_File_Stat then -- (not `a and f()`: that keeps one return value, and every file read as new, so Drive never counted: Mac, 0.51.12)
              local status, _, _, modified = reaper.JS_File_Stat(there)
              if status == 0 and modified and copy.is_young(tostring(modified), os.date("%Y.%m.%d %H:%M:%S", os.time() - copy.DRIVE_SETTLED)) then j.drive_young = true end
            else
              j.drive_young = true -- (without js_ReaScriptAPI nothing tells how long it's been there: Drive doesn't count. Review, 0.58.92)
            end
          end
        end
        if not found then j.drive_bad = rel; break end
        if j.drive_young then j.drive_bad = rel; break end
      end
      j.at = j.at + 1
    end
    if j.at > #j.files and not j.drive_bad then j.places[#j.places + 1] = "Google Drive"; j.step = "ask"
    elseif j.drive_bad then j.step = "ask" end
  elseif j.step == "ask" then
    local local_dir = band.home() .. "/" .. song
    if #j.places == 0 then
      j.skipped[#j.skipped + 1] = song .. " (no other copy confirmed: nobody else has said they hold exactly this" ..
        (j.drive_young and ", and Drive only got its files in the last half hour, so they may not be uploaded yet" or j.drive_bad and (", and Drive lacks " .. j.drive_bad:match("[^/]+$")) or "") .. ". If someone does, open REAPER there, wait a minute or two, and try again)"
      j.i, j.step = j.i + 1, "scan"
      return
    end
    j.ask = string.format("Delete this computer's copy of '%s'?\n\nConfirmed on: %s.\n\nIts files (%d) go to the %s, nothing changes for anyone else, and it stays on the Projects page: opening it brings it back%s.",
      song, table.concat(j.places, ", "), #j.files, WIN and "Recycle Bin" or "Trash", #j.places == 1 and j.places[1] == "Google Drive" and " from Drive" or " from them")
    j.local_dir = local_dir
  elseif j.step == "ignore" then -- first, so the delete can't reach anyone
    -- (who holds it, asked again now you've said yes: two computers each confirmed on the other, both said yes, and the last full copies
    -- went to the bin. Review, 0.58.92)
    local on_drive = false
    for _, p in ipairs(j.places) do on_drive = on_drive or p == "Google Drive" end
    if not on_drive and #copy.holders(copy.read_holds(j.root), song, copy.digest(j.files), j.user) == 0 then
      j.skipped[#j.skipped + 1] = song .. " (the other copy it was confirmed on is being deleted too: this one stays)"
      j.i, j.step = j.i + 1, "scan"
      return
    end
    local gone = ss.gone()
    gone[song] = true
    ss.save_gone(gone)
    ss.drop({ root = j.root, user = j.user }, song)
    pcall(copy.publish_holds, j.root, j.user) -- (nobody counts on this copy from now on)
    services.rescan(info.id)
    j.step, j.since = "ignored", reaper.time_precise()
    j.words = "Telling Syncthing to leave '" .. song .. "' alone"
  elseif j.step == "ignored" then
    if reaper.time_precise() - j.since < 1.5 then return end
    local probe = j.files[1]
    local a = probe and services.ask("/rest/db/file?folder=" .. info.id .. "&file=" .. enc(song .. "/" .. probe), 5)
    local local_part = a and a:match('"local":%s*(%b{})')
    if idle(info.id) and local_part and local_part:find('"ignored":%s*true') then j.step = "bin"
    elseif reaper.time_precise() - j.since > 45 then -- never delete on a guess
      j.skipped[#j.skipped + 1] = song .. " (Syncthing didn't confirm it would leave it alone, so nothing was deleted)"
      ss.want({ root = j.root, user = j.user }, song)
      j.i, j.step = j.i + 1, "scan"
    end
  elseif j.step == "bin" then
    local list = {}
    for _, p in ipairs(j.paths) do list[#list + 1] = dir .. "/" .. p end
    if reaper.EnumerateFiles(j.local_dir, 0) or reaper.EnumerateSubdirectories(j.local_dir, 0) then list[#list + 1] = j.local_dir end
    band.forget_project_file(j.root, song)
    j.binning, j.step = copy.bin_start(list, song), "binning"
    j.words = "Moving '" .. song .. "' to the " .. (WIN and "Recycle Bin" or "Trash")
  elseif j.step == "binning" then
    local left = copy.bin_poll(j.binning)
    if not left then return end
    j.binning = nil
    j.done[#j.done + 1] = song .. (left > 0 and string.format(" (%d not gone yet: still on its way to the Recycle Bin, or in use. If it stays, restart REAPER and delete again)", left) or "")
    band.log("deleted this computer's copy of '" .. song .. "': confirmed on " .. table.concat(j.places, ", ") .. ". Open it to bring it back")
    j.i, j.step = j.i + 1, "scan"
  end
end
-- The answer to j.ask.
function copy.answer(yes)
  local j = copy.job
  if not j then return end
  j.ask = nil
  if yes then j.step = "ignore" else j.skipped[#j.skipped + 1] = j.songs[j.i] .. " (you kept it)"; j.i, j.step = j.i + 1, "scan" end
end

-- Save the copy of a whole group that's no longer syncing: straight to the bin (no Syncthing has it any more).
function copy.delete_group(root)
  local left = copy.bin({ root })
  require("groups").forget_old(root)
  local list = {}
  for r in reaper.GetExtState(band.SECTION, "bands"):gmatch("[^|]+") do if r ~= root then list[#list + 1] = r end end
  reaper.SetExtState(band.SECTION, "bands", table.concat(list, "|"), true)
  return left
end

return copy
