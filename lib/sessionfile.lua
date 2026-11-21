-- End-of-session projects on Google Drive: a real REAPER project file for each session's end, which opens in plain
-- REAPER (no StudioSync needed) from anyone's Drive.
--   <drive>/<Song>/sessions/<stamp>-<user>-<room>.rpp      the project as it was at the end of the session
--   <drive>/<Song>/sessions/media/<user>/<file>              your own recordings it uses (copied once, never removed)
-- Bandmates' takes aren't copied again: the project points at the room's own copies on Drive
-- (../rooms/<room>/takes/ or _trash/, which the Drive copy keeps forever). Each machine writes only its own files
-- (lib/drive.lua: two machines writing one file on one Google account loses one of them). SonoBus / ReaNINJAM are
-- left out (they carry this machine's identity).
local band = require("band")
local sessionfile = {}

-- media still to copy, per song (persistent ExtState, so a restart carries on): JSON { {from, to} }
local function pending_key(song) return "session_media " .. song end
local function get_pending(song) return band.ext_json(band.SECTION, pending_key(song)) or {} end
local function set_pending(song, list) band.set_ext_json(band.SECTION, pending_key(song), list, true) end

-- The FILE lines of a project's text with their paths changed by `map(path) -> new path or nil` (unchanged). Pure.
function sessionfile.map_files(text, map)
  local out = {}
  for l in (text .. "\n"):gmatch("([^\n]*)\n") do
    local line = l
    local pre, rest = line:match("^(%s*FILE )(.*)$")
    if pre then
      local path, tail
      if rest:sub(1, 1) == '"' then path, tail = rest:match('^"([^"]*)"(.*)$') else path, tail = rest:match("^(%S+)(.*)$") end
      local new = path and map(path)
      if new then line = pre .. '"' .. new .. '"' .. (tail or "") end
    end
    out[#out + 1] = line
  end
  if out[#out] == "" then out[#out] = nil end
  return table.concat(out, "\n") .. "\n"
end

-- Each FILE line's path in a project's text, as map_files sees them, without rebuilding the text: fn(path). (The cloud copy's storage sweep
-- reads every end-of-session project for its recordings: map_files took 20-36 ms a project on REAPER's thread. rt-drive2.) Pure.
-- (found by a plain search for "FILE ", then its line checked: the pattern tried every line start, 15 ms for a 1.5 MB project, most of the
-- sweep's 34.8 ms plan on the desktop. rt-drive2, round 5)
local WS = { [32] = true, [9] = true, [10] = true, [11] = true, [12] = true, [13] = true }
function sessionfile.each_file(text, fn)
  local at = 1
  while true do
    local a = text:find("FILE ", at, true)
    if not a then return end
    at = a + 5
    local j, nl = a - 1, false -- (only space before it on its line, and a line start: as "\n%s*FILE " on "\n" .. text)
    while j >= 1 and WS[text:byte(j)] do nl = nl or text:byte(j) == 10; j = j - 1 end
    if j == 0 or nl then
      local rest = text:match("^[^\n]*", at)
      local path = rest:sub(1, 1) == '"' and rest:match('^"([^"]*)"') or rest:match("^(%S+)")
      if path then fn(path) end
    end
  end
end

local function exists(p) return reaper.file_exists(p) end
-- Without opening it: a file on Google Drive took 0.6 s to open, and a project holds dozens, so a backup stopped REAPER for 46 s
-- and Live sync looked dead. Only for files that have been there a while: one just written can read wrong, so band.size's own
-- check of a write stays as it is.
local function settled_size(p)
  if reaper.JS_File_Stat then
    local status, size = reaper.JS_File_Stat(p)
    if status == 0 then return math.floor(size) end
  end
  return band.size(p)
end

-- A project's text as a plain project: SonoBus / ReaNINJAM out of every plug-in chain (master, tracks, input FX:
-- they carry this machine's identity, and opening the file elsewhere warned about ReaNINJAM), and StudioSync's own
-- project state (<BANDSYNC...> under EXTSTATE) gone, so it doesn't open as a session tab. `split` = mixlayer.split_live.
-- Pure.
function sessionfile.plain(text, split)
  local lines = {}
  -- (REAPER on Windows writes CRLF: a block's closing line is ">\r", which never matched and swallowed the rest)
  for l in (text .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = (l:gsub("\r$", "")) end
  if lines[#lines] == "" then lines[#lines] = nil end
  local out, i = {}, 1
  while i <= #lines do
    local l = lines[i]
    local ind, tag = l:match("^(%s*)<(%S+)")
    local fx = tag and (tag:match("^FXCHAIN") or tag == "MASTERFXLIST")
    local ours = tag and tag:upper():match("^BANDSYNC")
    if fx or ours then
      local j = i + 1
      while j <= #lines and lines[j] ~= ind .. ">" do j = j + 1 end
      if fx then
        local block = table.concat(lines, "\n", i, math.min(j, #lines))
        for b in ((split(block)) .. "\n"):gmatch("([^\n]*)\n") do out[#out + 1] = b end
      end
      i = j + 1
    else
      out[#out + 1] = l
      i = i + 1
    end
  end
  return table.concat(out, "\n") .. "\n"
end

-- The paths a band's version put on items and tracks here, as the project's text records them (P_EXT band_theirs, lib/mirror.lua), as a set
-- of fxfiles.key. Pure.
function sessionfile.theirs(text)
  local set, key = {}, require("fxfiles").key
  for v in text:gmatch("band_theirs%s+\"?([^\"\r\n]*)") do
    for p in v:gmatch("[^|]+") do set[key(p)] = true end
  end
  return set
end
-- May the end-of-session export copy this file to the cloud? Only one inside the project's own folder or the studio's (`roots`), and not one a
-- band's version named (`theirs`): it copied every file any FILE line named, so a path a bandmate planted went to the cloud folder everyone has
-- at your session's end, with no action of yours. Security, Round 2 review, 0.59.46. Pure.
function sessionfile.may_copy(full, roots, theirs)
  local key = require("fxfiles").key
  local k = key(full)
  if theirs and theirs[k] then return false end
  for _, r in ipairs(roots) do
    local rk = r and key(r):gsub("/+$", "") .. "/"
    if rk and rk ~= "/" and k:sub(1, #rk) == rk then return true end
  end
  return false
end

-- Write this machine's end-of-session project to Drive. Returns the file written, or nil + why.
function sessionfile.export(proj, cfg, b, droot, room_dir)
  -- (history the cloud copy doesn't keep in Essentials: lib/cloudmodes.lua. James, rt)
  if require("cloudmodes").settings_for(cfg.root).mode == "essentials" then return nil, "the studio's cloud copy keeps essentials only (Settings > Options > Cloud copy)" end
  local path
  for i = 0, 512 do
    local p, f = reaper.EnumProjects(i)
    if not p then break end
    if p == proj then path = f end
  end
  if not path or path == "" then
    -- (REAPER closing the tab gives it no file any more: at a REAPER restart on the desktop, 08:07:58, this said "never been saved" of a saved
    -- project. The saved version is kept either way; only the plain-REAPER copy in the cloud is missed. rt-drive2, round 4)
    local known = band.project_file and band.project_file(cfg.root, b.song) or ""
    if known ~= "" and reaper.file_exists(known) then return nil, "REAPER was closing the project, so there was no file to copy (the saved version is kept)" end
    return nil, "the project has never been saved"
  end
  local projdir = path:gsub("\\", "/"):match("^(.*)/")
  -- a copy as it is now, next to it (so relative paths read the same); the open project and its file are untouched
  local tmp = projdir .. "/.bandsync-session-copy.rpp"
  band.save_copy(proj, tmp) -- (keeps the project's unsaved mark. Called plainly: "save_copy and save_copy() or <old save>" saved the copy twice. Round 2 review, 0.59.46)
  local text = band.read(tmp)
  os.remove(tmp)
  if not text then return nil, "couldn't save a copy of the project" end
  -- (this computer's own tracks stay out, as lib/export.lua leaves them: they went to the shared cloud folder at every session end. James,
  -- Round 2 review, 0.59.46)
  text = require("export").no_local_tracks(text)
  local theirs = sessionfile.theirs(text)
  local sdir = droot .. "/" .. b.song .. "/sessions"
  local user = (cfg.user:gsub("[^%w%-_]", "_"))
  local pending = get_pending(b.song)
  local function abs(p)
    p = p:gsub("\\", "/")
    if p:match("^%a:/") or p:sub(1, 1) == "/" then return p end
    return projdir .. "/" .. p
  end
  text = sessionfile.map_files(text, function(p)
    local full = abs(p)
    local name = full:match("[^/]+$")
    local band_file = name:match("^takes_(.+)$") -- a bandmate's take, as imported: the room's copy has it
    if band_file then
      for _, sub in ipairs({ "takes", "_trash" }) do
        if exists(droot .. "/" .. b.song .. "/rooms/" .. b.room .. "/" .. sub .. "/" .. band_file)
            or exists(room_dir .. "/" .. sub .. "/" .. band_file) then
          return "../rooms/" .. b.room .. "/" .. sub .. "/" .. band_file
        end
      end
    end
    if not exists(full) or not sessionfile.may_copy(full, { projdir, cfg.root }, theirs) then return nil end
    local to = sdir .. "/media/" .. user .. "/" .. name
    if exists(to) and settled_size(to) ~= band.size(full) then -- a different file with the same name
      name = os.date("!%Y%m%d-%H%M%SZ") .. "_" .. name
      to = sdir .. "/media/" .. user .. "/" .. name
    end
    if not exists(to) then pending[#pending + 1] = { from = full, to = to } end
    return "media/" .. user .. "/" .. name
  end)
  text = sessionfile.plain(text, require("mixlayer").split_live)
  reaper.RecursiveCreateDirectory(sdir .. "/media/" .. user, 0)
  local out = string.format("%s/%s-%s-%s.rpp", sdir, os.date("!%Y%m%d-%H%M%SZ"), user, (b.room:gsub("[^%w%-_]", "_")))
  band.write_atomic(out, text)
  set_pending(b.song, pending)
  local okp, why = pcall(sessionfile.prune, sdir, user, (b.room:gsub("[^%w%-_]", "_")))
  if not okp then band.log("couldn't tidy old end-of-session projects in the cloud copy: " .. tostring(why)) end
  sessionfile.catch_up(b.song, 1.5)
  return out
end

-- How many end-of-session projects the cloud copy keeps (James, rt: "the studio's backup", not one that grows without limit): each person's
-- newest KEEP per room, and only the recordings of theirs those still use (sessions/media/<you>/). One is written at every session's end and
-- after every 20 quiet minutes, so they piled up. Nothing of the song's history goes: every end-of-session saved version (rooms/<room>/recall)
-- stays in the cloud copy for good and restores exactly from Restore > Saved versions; only an old session's plain-REAPER project goes, and
-- the copies of recordings only it used (the originals are in the studio folder). Each computer tidies only its own files (drive.mine's
-- one-writer rule). shortcut: "James" in room "Laptop-main" and "James-Laptop" in "main" share one name; nobody names rooms so.
sessionfile.KEEP = 10
-- Which of `files` (names in sessions/) go: `user`'s projects of `room` (both as file names have them) beyond the newest `keep`. Names are
-- <yyyymmdd-hhmmssZ>-<user>-<room>.rpp, so they sort by time. Pure.
function sessionfile.prune_plan(files, user, room, keep)
  local mine, tail = {}, "-" .. user .. "-" .. room .. ".rpp"
  for _, f in ipairs(files) do
    if f:match("^%d%d%d%d%d%d%d%d%-%d%d%d%d%d%dZ%-") and f:sub(17) == tail then mine[#mine + 1] = f end
  end
  table.sort(mine, function(a, b) return a > b end)
  local out = {}
  for i = keep + 1, #mine do out[#out + 1] = mine[i] end
  return out
end
-- Which of `names` (files in sessions/media/<user>/) none of `texts` (that user's projects still there) uses. Pure.
function sessionfile.unused_media(names, texts, user)
  local used, prefix = {}, "media/" .. user .. "/"
  for _, t in ipairs(texts) do
    sessionfile.map_files(t, function(p) if p:sub(1, #prefix) == prefix then used[p:sub(#prefix + 1)] = true end end)
  end
  local out = {}
  for _, n in ipairs(names) do if not used[n] then out[#out + 1] = n end end
  return out
end
-- -> how many projects went. Recordings are looked at only when one did, and left alone if any of this user's projects doesn't read.
function sessionfile.prune(sdir, user, room)
  local gone = sessionfile.prune_plan(band.files(sdir, ".rpp"), user, room, sessionfile.KEEP)
  for _, f in ipairs(gone) do os.remove(sdir .. "/" .. f) end
  if not gone[1] then return 0 end
  local texts, who = {}, "-" .. user .. "-"
  for _, f in ipairs(band.files(sdir, ".rpp")) do
    if f:sub(17, 16 + #who) == who then -- (any room of theirs; a longer name that starts with theirs too, which only keeps more)
      local t = band.read(sdir .. "/" .. f)
      if not t then return #gone end
      texts[#texts + 1] = t
    end
  end
  local media = sdir .. "/media/" .. user
  for _, f in ipairs(sessionfile.unused_media(band.files(media), texts, user)) do
    if not require("drive").arriving(f) then os.remove(media .. "/" .. f) end
  end
  return #gone
end

-- Copy media the exported projects still need, for up to `budget` seconds (called from the Drive pass, so a big
-- first copy is spread out instead of holding up REAPER). Returns how many are left.
-- With the cloud copy's background worker on (lib/drivebg.lua), not here: the drive round's "sessions" unit plans the copies (bg.C planned), the
-- worker makes them, and each leaves the list once the cloud folder's listing has it. A call on REAPER's thread meanwhile (Live sync after a
-- pass, sessionfile.export) leaves them to it: they were up to 1.5 s of copying on REAPER's thread at a session's end. (backlog 1.35, rt-p2)
function sessionfile.catch_up(song, budget)
  local list = get_pending(song)
  if #list == 0 then return 0 end
  local bg = require("drivebg")
  local C = bg.C
  if not C.planned and bg.on() then return #list end
  if C.planned then
    local left = {}
    for _, m in ipairs(list) do
      if type(m) == "table" and m.from and m.to and not C.exists(m.to) and exists(m.from) then left[#left + 1] = m end
    end
    C.check() -- (every listing read first: a copy planned on a half-read one could be one the cloud has)
    for _, m in ipairs(left) do C.copy(m.from, m.to, false, "count") end
    set_pending(song, left)
    return #left
  end
  local t0, left = reaper.time_precise(), {}
  for _, m in ipairs(list) do
    if reaper.time_precise() - t0 < (budget or 1.5) and type(m) == "table" and m.from and m.to then
      if not exists(m.to) and exists(m.from) then
        reaper.RecursiveCreateDirectory(m.to:match("^(.*)/"), 0)
        band.copy_atomic(m.from, m.to)
      end
    else
      left[#left + 1] = m
    end
  end
  set_pending(song, left)
  return #left
end

return sessionfile
