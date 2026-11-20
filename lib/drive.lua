-- Google Drive as the band's post box. Syncthing only moves files while two machines are on at the same time; a
-- copy of each room on Drive carries what someone did alone (and every end-of-session restore point) to the others
-- whenever they next open the song, and keeps the band's history off any one machine.
--   <drive root>/<Song>/rooms/<room>/{events,recall,midi,fx,takes,_trash}   same layout as the shared folder
-- Nothing is lost on either side (a file is only removed from one place once it's in the right one). Events, restore points and MIDI are written once, so copying what's
-- missing both ways is enough. A take's files move between takes/ and _trash/ (a delete, an undone delete, a new
-- revision), so where each one belongs is worked out from the room's events and manifests, and both sides end up so.
-- A recording deleted on purpose isn't "missing": its tombstone (<room>/deleted, media_deletes below) keeps it from coming back.
local band = require("band")
local drive = {}
drive.listed = {} -- Drive folder -> { at, files }: its listing, kept a little while (drive.mirror)

-- Where the Drive copy lives, or nil (no Drive on this machine, or turned off: ExtState drive_root = "off").
-- Looking is cached for 5 minutes: listing My Drive asks Google's servers, and doing it every Live sync poll and
-- panel frame on two machines of one account ran into Drive's rate limit (2026-10-28: 600+ "userRateLimitExceeded"
-- in an hour, uploads held back for many minutes, "Can't add file" messages).
-- The band's folder is a Drive folder one person shares with everyone (Editor), each on their own Google account,
-- added to each person's My Drive as a shortcut named StudioSync. It's only ever found, never made: making it in a My
-- Drive without the shortcut would copy everything into a private folder nobody else sees.
-- First My Drive (of `places`, in order) holding a StudioSync folder -> its path; else nil, plus the first My Drive
-- seen (so the panel can say the shortcut is missing). `subdirs(dir)` lists folder names; `has(path)`, if given, says
-- whether a folder is there even when a listing leaves it out (on a Mac the shortcut is a symlink into
-- .shortcut-targets-by-id, 2026-10-31). Pure.
function drive.find(places, subdirs, has, name)
  name = name or "BandSync" -- (each band its own Drive folder: band.info)
  local missing
  for _, md in ipairs(places) do
    if has and has(md .. "/" .. name) then return md .. "/" .. name end
    local dirs = subdirs(md)
    for _, d in ipairs(dirs) do
      if d:lower() == name:lower() then return md .. "/" .. d end
    end
    if dirs[1] and not missing then missing = md end
  end
  return nil, missing
end

-- The cloud drives a studio's copy can live in (James, 0.58.79: "compatibility for other drive services like Dropbox"). Each is
-- a folder its desktop app keeps in step with the cloud, and the studio's folder is one the owner shares with everyone in that service
-- (it shows up in each person's own drive, by name), so finding it by name works the same in all of them.
drive.SERVICES = {
  { "google", "Google Drive", "On drive.google.com: Shared with me > right-click %s > Organize > Add shortcut > My Drive, keeping the name." },
  { "dropbox", "Dropbox", "On dropbox.com: Shared > %s > Add to Dropbox (it lands in your Dropbox folder, keeping the name)." },
  { "onedrive", "OneDrive", "On onedrive.com: Shared > %s > Add shortcut to My files." },
  { "icloud", "iCloud Drive", "Accept the invitation to %s (Mail or Files): it shows up in iCloud Drive." },
  { "box", "Box", "Accept the invitation to %s on box.com: it shows up in your Box folder (Box Drive)." },
}
-- Which service a folder belongs to, from its path: "google", "dropbox"... or nil. Pure.
function drive.service_of(path)
  local p = (path or ""):lower()
  if p:find("/my drive", 1, true) or p:find("googledrive%-") then return "google" end
  if p:find("dropbox", 1, true) then return "dropbox" end
  if p:find("onedrive", 1, true) then return "onedrive" end
  if p:find("icloud", 1, true) or p:find("com~apple~clouddocs", 1, true) then return "icloud" end
  if p:find("/box/", 1, true) or p:find("/box$") or p:find("box%-box") then return "box" end
  return nil
end
function drive.label(service)
  for _, s in ipairs(drive.SERVICES) do if s[1] == service then return s[2] end end
  return "your cloud drive"
end
-- The service this computer uses for studio copies: ExtState "drive service" ("" = whichever is here, Google Drive first).
function drive.service() return reaper.GetExtState(band.SECTION, "drive service") end

-- Where each service's desktop app may keep its folder. Google Drive for desktop: a drive letter on Windows (G: unless it's taken;
-- one per signed-in account), the user folder (Windows mirroring), ~/Library/CloudStorage/GoogleDrive-<account> on macOS.
-- Dropbox: the paths in its info.json, else ~/Dropbox; OneDrive: its environment variables or CloudStorage/OneDrive-*; iCloud Drive:
-- ~/iCloudDrive (Windows) or Mobile Documents (macOS); Box: ~/Box or CloudStorage/Box-Box. `only`: one service's.
local copy_said = {} -- (a file that failed to copy, said once)
drive.extra = {} -- top folders of Google's drive other than My Drive (looked in, never made in)
drive.BIG = 16 * 1024 * 1024 -- bytes: a file this big is copied in the background (drive.mirror)
local function places(only, g_only)
  local out = {}
  local function add(service, path) if path and (only == nil or only == "" or only == service) then out[#out + 1] = path end end
  local win = reaper.GetOS():find("^Win")
  local home = ((win and os.getenv("USERPROFILE") or os.getenv("HOME")) or ""):gsub("\\", "/")
  -- ("My Drive" is in the computer's language: "Meine Ablage", "Mi unidad"... So every folder at the top of Google's drive is looked in, after
  -- "My Drive". A drive letter is Google's if it has My Drive, or Google's own .shortcut-targets-by-id or .Encrypted. 0.59.10)
  local function google(root, sure) -- (the extra folders are for finding a studio's folder: drive.make never makes one there)
    local subs = band.subdirs(root)
    local is = sure
    for _, d in ipairs(subs) do if d == "My Drive" or d == ".shortcut-targets-by-id" or d == ".Encrypted" then is = true end end
    if not is then return end
    add("google", root .. "/My Drive")
    for _, d in ipairs(subs) do if d:sub(1, 1) ~= "." and d ~= "$RECYCLE.BIN" and d ~= "My Drive" then add("google", root .. "/" .. d); drive.extra[root .. "/" .. d] = true end end
  end
  -- (and only when Google's is one this computer may use: with another service chosen in Settings each letter was listed anyway. Round 1 review, 0.59.45)
  if win and (only == nil or only == "" or only == "google") then -- (drive letters only on Windows: a Mac looked at 23 that can't exist)
    google("G:", false)
    -- (`g_only`: G: alone, after a sweep found nothing: the other letters every 5 minutes kept a dead mapped drive freezing REAPER. A change of
    -- service in Settings sweeps them all again (drive.forget). Round 2 review, 0.59.46)
    for c = ("D"):byte(), ("Z"):byte() do
      if c ~= ("G"):byte() and not g_only then google(string.char(c) .. ":", false) end
    end
  end
  if home ~= "" then add("google", home .. "/My Drive") end
  local cs = home .. "/Library/CloudStorage"
  local cloud = band.subdirs(cs)
  for _, d in ipairs(cloud) do
    if d:match("^GoogleDrive%-") then google(cs .. "/" .. d, true) end
  end
  for _, info in ipairs({ (os.getenv("LOCALAPPDATA") or ""):gsub("\\", "/") .. "/Dropbox/info.json", (os.getenv("APPDATA") or ""):gsub("\\", "/") .. "/Dropbox/info.json",
      home .. "/.dropbox/info.json" }) do
    local j = band.read_json(info)
    if type(j) == "table" then
      for _, kind in ipairs({ "personal", "business" }) do
        if type(j[kind]) == "table" and type(j[kind].path) == "string" then add("dropbox", (j[kind].path:gsub("\\", "/"))) end
      end
    end
  end
  for _, d in ipairs(cloud) do if d:match("^Dropbox") then add("dropbox", cs .. "/" .. d) end end
  add("dropbox", home .. "/Dropbox")
  for _, v in ipairs({ "OneDriveConsumer", "OneDriveCommercial", "OneDrive" }) do
    local p = os.getenv(v)
    if p and p ~= "" then add("onedrive", (p:gsub("\\", "/"))) end
  end
  for _, d in ipairs(cloud) do if d:match("^OneDrive") then add("onedrive", cs .. "/" .. d) end end
  add("icloud", win and (home .. "/iCloudDrive") or (home .. "/Library/Mobile Documents/com~apple~CloudDocs"))
  for _, d in ipairs(cloud) do if d:match("^Box") then add("box", cs .. "/" .. d) end end
  add("box", home .. "/Box")
  return out
end

-- Several cloud drives on one computer (James, 0.59.4: "make sure it won't mess up if someone has multiple on the same system"): the folder
-- this studio's copy was last in (`seen`) stays the one while it's there, though another drive has a folder of the same name earlier in the
-- order; and it never jumps to another service's folder on its own (Google Drive not up yet at login, and a OneDrive folder of that name
-- took the copies, where nobody else looks). `chosen`: a service picked in Settings > Cloud copy, which may move it. -> the folder to use or
-- nil, the one that's away (nil if none), and another service's folder of that name, left alone (for the panel). Pure.
function drive.settle(found, seen, exists, chosen)
  seen = seen ~= "" and seen or nil
  if not seen or found == seen then return found end
  if not (chosen and chosen ~= "" and drive.service_of(seen) ~= chosen) and exists(seen) then return seen end
  if not found then return nil, seen end
  if (chosen and chosen ~= "") or drive.service_of(found) == drive.service_of(seen) then return found end -- (picked, or the same drive on another letter)
  return nil, seen, found
end

local looked = {} -- per band (its Drive folder's name): { found, at, missing, away, other }
function drive.forget() looked = {} end -- (the service was changed: look again now)
-- The service the studio's copy is in here (or would be), in words: "Google Drive", "Dropbox"...
function drive.name(cfg)
  local r = drive.root(cfg)
  return drive.label(r and drive.service_of(r) or drive.service_of(drive.missing) or (drive.service() ~= "" and drive.service()) or "google")
end
-- How someone adds the studio's shared folder `folder` to their drive, in the service the copy is in.
function drive.share_hint(cfg, folder)
  local svc = drive.service_of(drive.root(cfg) or drive.missing) or (drive.service() ~= "" and drive.service()) or "google"
  for _, s in ipairs(drive.SERVICES) do if s[1] == svc then return (s[3]:format(folder)) end end
  return ""
end
drive.missing = nil -- a My Drive with no StudioSync folder in it (the shared folder isn't added yet), for the panel
function drive.root(cfg)
  local r = reaper.GetExtState(band.SECTION, "drive_root")
  if r == "off" then return nil end
  if r ~= "" then return r end
  local info = band.info(cfg and cfg.root)
  local l = looked[info.drive] or { at = -math.huge }
  looked[info.drive] = l
  -- (Round 1 review, 0.59.45: the folder it was last in, while it's still there (and its service may be used), with no sweep of D: to Z:; and
  -- never a sweep while the transport runs: each letter is a listing on REAPER's own thread, and a dead mapped drive froze it every 5 minutes.)
  local key = "drive_seen" .. (info.id == "bandsync" and "" or (" " .. info.id)) -- (the first band keeps its old key)
  local function exists(p) return reaper.EnumerateSubdirectories(p, 0) ~= nil or reaper.EnumerateFiles(p, 0) ~= nil end
  local chosen = drive.service()
  if reaper.time_precise() - l.at >= 300 then
    local seen = reaper.GetExtState(band.SECTION, key)
    if seen ~= "" and (chosen == "" or drive.service_of(seen) == chosen) and exists(seen) then
      l.at, l.found, l.missing, l.away, l.other = reaper.time_precise(), seen, nil, nil, nil
    elseif reaper.GetPlayState() ~= 0 then
      l.at = reaper.time_precise() - 270 -- (looked for again in half a minute)
    end
  end
  if reaper.time_precise() - l.at >= 300 then
    l.at = reaper.time_precise()
    l.found, l.missing = drive.find(places(drive.service(), l.swept), band.subdirs,
      function(p) return reaper.EnumerateSubdirectories(p, 0) ~= nil or reaper.EnumerateFiles(p, 0) ~= nil end, info.drive)
    l.swept = l.swept or not l.found
    -- the band's Drive was here and isn't now: that Google account signed out, or Drive switched to another one (Mac,
    -- 2026-10-31: a personal and a band account on one machine). Said, not guessed at: drive.away, for the panel.
    local seen = reaper.GetExtState(band.SECTION, key)
    l.found, l.away, l.other = drive.settle(l.found, seen, exists, chosen)
    if l.found then
      if seen ~= l.found then reaper.SetExtState(band.SECTION, key, l.found, true) end
    elseif l.away and l.missing and chosen ~= "" and drive.service_of(l.away) ~= chosen then
      l.away = nil -- (another service picked in Settings, with no studio folder yet: its "add the shared folder" hint, not the old one's. 0.59.10)
    elseif l.away then l.missing = nil end
  end
  drive.missing, drive.away, drive.other = l.missing, l.away, l.other -- (this band's, for the panel)
  return l.found
end

-- Whoever starts a studio makes its folder (James, 2026-11-04): the others add it as a shortcut once it's shared with them, so this is never done for someone joining.
-- -> its path, or nil when there's no My Drive here. shortcut: the first My Drive found, with several Google accounts signed in; it can be moved at drive.google.com.
function drive.wanted() return reaper.GetExtState(band.SECTION, "drive make") ~= "off" and reaper.GetExtState(band.SECTION, "drive_root") ~= "off" end
function drive.make(name)
  for _, md in ipairs(places(drive.service())) do
    if not drive.extra[md] and (reaper.EnumerateSubdirectories(md, 0) ~= nil or reaper.EnumerateFiles(md, 0) ~= nil) then
      reaper.RecursiveCreateDirectory(md .. "/" .. name, 0)
      looked[name] = nil
      -- (only once it's there: a folder that couldn't be made was named as the copy anyway. Review, 0.59.14)
      for _, d in ipairs(band.subdirs(md)) do if d == name then return md .. "/" .. name end end
    end
  end
end

-- A take file's name -> take id, revision (1 for the first print), and whether it's the manifest. Pure.
--   James-20261028-032515Z-2.flac / -dry.flac / -r6.opus / -dry-r6.flac / .json / .midibuf
function drive.parse(name)
  local base, ext = name:match("^(.+)%.([^.]+)$")
  if not base then return nil end
  local id = base:match("^(.+%-%d%d%d%d%d%d%d%d%-%d%d%d%d%d%dZ%-%d+)")
  if not id then return nil end
  return id, tonumber(base:match("%-r(%d+)$")) or 1, ext:lower() == "json"
end

-- Where a take file belongs: "_trash" if its take is deleted or it's an older revision's, else "takes". Pure.
function drive.place(name, trashed, cur_rev)
  local id, rev, manifest = drive.parse(name)
  if not id then return nil end
  if trashed[id:lower()] then return "_trash" end
  if not manifest and rev < (cur_rev[id:lower()] or rev) then return "_trash" end
  return "takes"
end

-- Which takes are deleted: the newest delete/undelete event for each take says. `events` = { {type, take, time, id} }. Pure.
function drive.trashed(events)
  local last = {}
  for _, ev in ipairs(events) do
    if (ev.type == "delete" or ev.type == "undelete") and type(ev.take) == "string" then
      local k, key = ev.take:lower(), (ev.time or "") .. (ev.id or "")
      if not last[k] or key > last[k].key then last[k] = { key = key, del = ev.type == "delete" } end
    end
  end
  local out = {}
  for k, v in pairs(last) do if v.del then out[k] = true end end
  return out
end

-- Whose each recording in a room's media folder is: the author of the first change that used it (a recording's file
-- is named by REAPER, not after anyone, so the name can't say; later changes by others only move it). Media used
-- from another room's folder is that room's. `events` = { {user, time, id, media = { {room, file} }} }. Pure.
function drive.media_owners(events, room)
  local first = {}
  for _, ev in ipairs(events) do
    local key = (ev.time or "") .. (ev.id or "")
    for _, m in ipairs(ev.media or {}) do
      if m[1] == room and ev.user and (not first[m[2]] or key < first[m[2]].key) then first[m[2]] = { key = key, user = ev.user } end
    end
  end
  local out = {}
  for f, v in pairs(first) do out[f] = v.user end
  return out
end

local seen_events = {} -- path -> { type, take, time, id, user, media } (events are written once, so read once)
-- -> the events, or nil once `deadline` (time_precise) has passed with some still unread: those read so far are kept, the next call carries on
-- (the first pass after a start read a big room's 3,150 at once and held REAPER up 0.7 s)
local function read_events(dir, deadline)
  local out = {}
  for _, f in ipairs(band.files(dir, ".json")) do
    local p = dir .. "/" .. f
    local e = seen_events[p]
    if e == nil and deadline and reaper.time_precise() > deadline then return nil end
    if not e then
      local ev = band.read_json(p)
      e = ev and { type = ev.type, take = ev.take, time = ev.time, id = ev.id, user = ev.user, oid = ev.oid, gone = ev.gone == true or nil } or false
      if e and type(ev.state) == "string" then -- (an item's chunk: the recordings it plays)
        e.media = {}
        for room, rel in ev.state:gmatch('FILE "{media:([^}]+)}/([^"]+)"') do e.media[#e.media + 1] = { room, rel } end
      end
      if e then seen_events[p] = e end -- (one not readable yet may still be arriving: read again next time)
    end
    if e then out[#out + 1] = e end
  end
  return out
end

-- What we may write on Drive: only our own files (named after us: takes, events, MIDI and restore points all carry
-- their author's name). Two machines on one Google account writing the same file, even minutes apart (Drive takes
-- a while to show one machine's upload to the other), made Drive keep one and move the other to "Lost and Found"
-- with a "Can't sync file" message each time (2026-10-28). Reading from Drive is anyone's.
-- `wait` (tests only): others' files too, once missing that many seconds.
local first_seen = {} -- path -> when we first saw it missing on Drive
-- (bandmates whose name starts with ours and a dash, "James-Laptop" for "James": their files read as ours, so both computers wrote them on
-- Drive. Set by drive.mirror from the events it reads. Review, 0.58.92)
local longer = {}
local function owned(f, u) return f:sub(1, #u + 1) == u .. "-" or f:find("Z-" .. u .. "-", 1, true) ~= nil end
local function mine(f, user, others) -- (others: the longer names; drive.mirror's own by default)
  local u = (user or ""):gsub("[^%w%-_]", "_")
  if u == "" or not owned(f, u) then return false end
  for _, l in ipairs(others or longer) do if owned(f, l) then return false end end
  return true
end
-- Bandmates' names (from events) that start with this one's and a dash, cleaned as file names have them. Pure.
function drive.longer_names(events, user)
  local u, seen, out = (user or ""):gsub("[^%w%-_]", "_"), {}, {}
  for _, e in ipairs(events) do
    local l = type(e.user) == "string" and e.user:gsub("[^%w%-_]", "_") or ""
    if not seen[l] and #l > #u + 1 and l:sub(1, #u + 1) == u .. "-" then seen[l] = true; out[#out + 1] = l end
  end
  return out
end
local function due(path, f, user, wait)
  if mine(f, user) then return true end
  if not wait then return false end
  local t = reaper.time_precise()
  first_seen[path] = first_seen[path] or t
  return t - first_seen[path] >= wait
end
drive.mine = mine

-- Google's conflict copies ("x (1).json") of a file that's there under its own name, same size: only clutter.
local function tidy(dir)
  local i, gone = 0, {}
  reaper.EnumerateFiles(dir, -1)
  while true do
    local f = reaper.EnumerateFiles(dir, i)
    if not f then break end
    local orig = f:gsub(" %(%d+%)(%.[^.]+)$", "%1")
    if orig ~= f and band.size(dir .. "/" .. orig) == band.size(dir .. "/" .. f) then gone[#gone + 1] = f end
    i = i + 1
  end
  for _, f in ipairs(gone) do os.remove(dir .. "/" .. f) end
  return #gone
end

-- Changes the history trim took out of the room (lib/trim.lua lists them in trimmed/): Drive's copy still has them.
local seen_trims = {} -- path -> its list (written once)
local function trimmed(dir)
  local out, media = {}, {}
  for _, f in ipairs(band.files(dir, ".json")) do
    local p = dir .. "/" .. f
    seen_trims[p] = seen_trims[p] or band.read_json(p) or nil
    local list = type(seen_trims[p]) == "table" and seen_trims[p] or {}
    for _, id in ipairs(list) do out[tostring(id) .. ".json"] = true end
    for _, m in ipairs(type(list.media) == "table" and list.media or {}) do media[tostring(m)] = true end -- (prints that followed them: 0.58.92)
  end
  return out, media
end
-- Syncthing's files while one arrives (".syncthing.x.tmp", "~syncthing~x.tmp"): copied to Drive mid-download, they came back from it for good
local function arriving(f) return (f:match("^%.syncthing%.") or f:match("^~") or f:match("%.tmp$")) and true or false end
drive.arriving = arriving

local function into_trash_index(dir, f)
  local idx = band.read_json(dir .. "/index.json") or {}
  if not idx[f] then idx[f] = os.date("!%Y-%m-%d"); band.write_json(dir .. "/index.json", idx) end
end

-- ---- deleted recordings (VM test, rt: four unused WAVs deleted from a room's media came back from the cloud copy, which copies whatever's ----
-- missing on either side, on two computers). A file someone deletes from a room's media (by hand, or Syncthing carrying someone's delete) is
-- told from one this computer never had by what it saw there last pass (its own memory, outside the shared folder: band.home()). Gone since,
-- and no longer played by the song as it stands (drive.media_in_use, in any of its rooms), it's written down as deleted: a tombstone, a file
-- written once in the room's deleted/ folder (<user>-<time>-<n>.json { names = { [file] = os.time() } }) that Syncthing and the cloud copy
-- carry as they carry events. A tombstoned file is copied neither way, catch-up doesn't fetch it (lib/streams.lua), and the cloud's copy is
-- moved into the cloud copy's _trash/media (kept there, and in the service's own trash after that). Nothing here removes a file on this
-- computer: Syncthing carries deletes between computers.
-- Still played (the song uses it, in this room or another, whoever deleted it): not a delete to keep, so it comes back from the cloud copy as
-- before, and that's said. A tombstone stops counting while the song plays that file again (the same audio added back has the same name).

-- The files of room `room` the song plays as it stands: the newest change to each object (by time, then id) in each room, unless that change
-- removed it, and the {media:<room>} files it names. `rooms`: { [room] = its events }. Pure.
function drive.media_in_use(rooms, room)
  local out = {}
  for _, events in pairs(rooms) do
    local last = {}
    for _, ev in ipairs(events) do
      if ev.oid then
        local key = (ev.time or "") .. (ev.id or "")
        if not last[ev.oid] or key > last[ev.oid].key then last[ev.oid] = { key = key, ev = ev } end
      end
    end
    for _, l in pairs(last) do
      if not l.ev.gone then for _, m in ipairs(l.ev.media or {}) do if m[1] == room then out[m[2]] = true end end end
    end
  end
  return out
end
-- A room's tombstones (its deleted/ folder): file -> when it was deleted (the latest). Each tombstone is written once, so read once.
local seen_tombs = {}
function drive.tombstones(dir)
  local out = {}
  for _, f in ipairs(band.files(dir, ".json")) do
    local p = dir .. "/" .. f
    if seen_tombs[p] == nil then -- (one not readable yet may still be arriving: read again next time)
      local t = band.read_json(p)
      seen_tombs[p] = type(t) == "table" and type(t.names) == "table" and t.names or nil
    end
    for name, at in pairs(seen_tombs[p] or {}) do
      if type(name) == "string" then out[name] = math.max(out[name] or 0, tonumber(at) or 0) end
    end
  end
  return out
end
-- What this computer saw in each room's media last pass: { [room folder, lower case] = { names } }, in band.home() (never synced).
local media_seen
local function seen_path() return band.home() .. "/cloud-media-seen.json" end
local function get_seen(key)
  media_seen = media_seen or band.read_json(seen_path()) or {}
  return type(media_seen[key]) == "table" and media_seen[key] or nil
end
local function set_seen(key, names)
  table.sort(names)
  local old = get_seen(key)
  if old and table.concat(old, "\0") == table.concat(names, "\0") then return end
  media_seen[key] = names
  pcall(band.write_json, seen_path(), media_seen)
end
local said_kept, tomb_seq = {}, 0
-- One pass's deletes for a room's media. A: this side's files; inA, inB: here and in the cloud copy (a trim's archived prints count as both);
-- owners: drive.media_owners. -> the files to leave alone (copied neither way) and how many moved into the cloud's _trash/media; or nil while
-- the song's changes are still being read (the next pass carries on).
local function media_deletes(here, there, A, inA, inB, user, owners, deadline)
  local key = here:gsub("\\", "/"):lower()
  local seen, tomb = get_seen(key), drive.tombstones(here .. "/deleted")
  local newly, cand = {}, false
  -- (nothing at all here while this computer saw files: the folder isn't there just now, or is being rebuilt. Not a delete)
  if seen and #A > 0 then for _, f in ipairs(seen) do if not inA[f] and not tomb[f] then newly[#newly + 1] = f end end end
  cand = #newly > 0
  for f in pairs(tomb) do if inA[f] or inB[f] then cand = true; break end end
  if not cand then return {}, 0 end
  local rooms_dir, room = here:match("^(.*)/([^/]+)$")
  local rooms = {}
  for _, r in ipairs(band.subdirs(rooms_dir)) do
    rooms[r] = read_events(rooms_dir .. "/" .. r .. "/events", deadline)
    if not rooms[r] then return nil end
  end
  local used = drive.media_in_use(rooms, room)
  local new, n_new = {}, 0
  for _, f in ipairs(newly) do
    if used[f] then
      if not said_kept[key .. "\0" .. f] then
        said_kept[key .. "\0" .. f] = true
        band.log(f .. " was deleted from " .. room .. "'s recordings here, but the project still plays it: not taken as deleted (the cloud copy brings it back)")
      end
    else new[f], tomb[f], n_new = os.time(), os.time(), n_new + 1 end
  end
  if n_new > 0 then
    tomb_seq = tomb_seq + 1
    local who = (user or ""):gsub("[^%w%-_]", "_")
    reaper.RecursiveCreateDirectory(here .. "/deleted", 0)
    band.write_json(string.format("%s/deleted/%s-%s-%d.json", here, who ~= "" and who or "someone", os.date("!%Y%m%d-%H%M%SZ"), tomb_seq), { names = new, by = user })
    band.log(string.format("%d recording%s deleted from %s's media here (%s%s): the cloud copy won't bring %s back", n_new, n_new == 1 and "" or "s", room,
      next(new), n_new > 1 and ", ..." or "", n_new == 1 and "it" or "them"))
  end
  local skip, moved = {}, 0
  for f in pairs(tomb) do
    if not used[f] then
      skip[f] = true
      -- (moved by the computer whose recording it is, or by any when nobody's known: two moving one at once leaves a "(1)" copy in _trash at worst)
      if inB[f] and (owners[f] == nil or owners[f] == user) then
        local from, to = there .. "/media/" .. f, there .. "/_trash/media/" .. f
        reaper.RecursiveCreateDirectory(there .. "/_trash/media", 0)
        if os.rename(from, to) or (band.size(to) == band.size(from) and os.remove(from)) then moved = moved + 1 end
      end
    end
  end
  return skip, moved
end

-- One pass for one room. Copying stops once `budget` seconds have gone (big FLACs on a slow link): the next pass
-- carries on. Returns files copied or moved, and whether work is left.
function drive.mirror(here, there, budget, user, wait)
  local t0, n = reaper.time_precise(), 0
  local function out_of_time() return reaper.time_precise() - t0 > (budget or 1.5) end
  local function copy(a, z)
    reaper.RecursiveCreateDirectory(z:match("^(.*)/"), 0)
    -- (a file still being written, on Drive or here: a change that doesn't read yet, or a size that moved while it copied. Left for a later
    -- pass, so half a file never takes the whole one's place: it isn't copied again once it's there. 0.59.10)
    if a:match("%.json$") and band.read_json(a) == nil then return end
    local size = band.size(a)
    -- (a big one, a long print or recording: copied by the system in the background, to a temporary name and then into place, so REAPER
    -- doesn't hold still while it goes. James, 0.59.12. Once a minute at most per file: the next pass sees it there)
    if (size or 0) > drive.BIG then band.copy_background(a, z); return end -- (band.copy_background: a quarter of an hour at most per file)
    local okc, why = pcall(band.copy_atomic, a, z) -- (one that fails, a Drive file that won't download offline, is skipped: it stopped the whole room each pass)
    if not okc then
      if not copy_said[a] then copy_said[a] = true; band.log("couldn't copy " .. a:match("[^/]+$") .. " for the cloud copy: " .. tostring(why)) end
      return
    end
    if band.size(a) ~= size or band.size(z) ~= size then os.remove(z); return end
    n = n + 1
  end
  -- written once: whatever's missing goes across
  local events = read_events(here .. "/events", t0 + (budget or 1.5))
  if not events then return 0, true end -- (who owns which recording isn't known yet: nothing's copied on half a list)
  local owners = drive.media_owners(events, here:match("([^/]+)$"))
  longer = drive.longer_names(events, user)
  -- (recall/known: a saved version's map, beside it since 0.59.46: one brought back from the cloud restored by time. Round 3 review, 0.59.48)
  -- (deleted: tombstones, before media so a pass has the cloud's before it copies any recording)
  for _, sub in ipairs({ "trimmed", "events", "recall", "recall/known", "midi", "deleted", "media" }) do -- (media: recordings and prints the items use)
    local A, B = {}, {}
    for _, f in ipairs(band.files(here .. "/" .. sub)) do if not arriving(f) then A[#A + 1] = f end end
    -- (the Drive side's listing, kept 30 s: listing a cloud drive's folders is the slow part, and in a quiet room every pass listed all five
    -- for nothing. Dropped whenever this pass writes or tidies there. Review list, 0.59.37)
    local td = there .. "/" .. sub
    local lc = drive.listed[td]
    local fresh = not (lc and reaper.time_precise() - lc.at < 30)
    if fresh then lc = { at = reaper.time_precise(), files = band.files(td) }; drive.listed[td] = lc end
    for _, f in ipairs(lc.files) do if not arriving(f) then B[#B + 1] = f end end
    local n_before = n
    local inA, inB = {}, {}
    for _, f in ipairs(A) do inA[f] = true end
    for _, f in ipairs(B) do inB[f] = true end
    local skip = {} -- (deleted recordings: copied neither way)
    if sub == "media" then -- (prints a trim archived: left where each side has them, not brought back from Drive)
      for f in pairs(select(2, trimmed(here .. "/trimmed"))) do inA[f], inB[f] = true, true end
      local moved
      skip, moved = media_deletes(here, there, A, inA, inB, user, owners, t0 + (budget or 1.5))
      if not skip then return n, true end
      if moved > 0 then n, drive.listed[td] = n + moved, nil end
    end
    if sub == "events" then -- trimmed: not brought back from Drive, and gone from it once whoever made them sees that
      for f in pairs(trimmed(here .. "/trimmed")) do -- ("trimmed" goes first: a list may have just come from Drive)
        inA[f], inB[f] = true, true
        if mine(f, user) and reaper.file_exists(there .. "/events/" .. f) then os.remove(there .. "/events/" .. f); drive.listed[td] = nil end
      end
    end
    for _, f in ipairs(A) do
      if not inB[f] and not skip[f] and (sub == "media" and owners[f] == user or due(here .. "/" .. sub .. "/" .. f, f, user, wait)) then
        if out_of_time() then return n, true end
        copy(here .. "/" .. sub .. "/" .. f, there .. "/" .. sub .. "/" .. f)
      end
    end
    if n ~= n_before then drive.listed[td] = nil end
    if fresh and tidy(td) > 0 then drive.listed[td] = nil end -- (Drive's "name (1).ext" copies: looked for with the listing, not every pass)
    local got = {}
    for _, f in ipairs(B) do
      if not inA[f] and not skip[f] then
        if out_of_time() then return n, true end
        local k = n
        copy(there .. "/" .. sub .. "/" .. f, here .. "/" .. sub .. "/" .. f)
        if sub == "media" and n > k then drive.landed[#drive.landed + 1] = here .. "/media/" .. f; got[#got + 1] = f end
      end
    end
    if sub == "media" and #A > 0 then -- (what's here now, for the next pass to tell a delete by. An empty folder keeps the last: media_deletes)
      for _, f in ipairs(A) do got[#got + 1] = f end
      set_seen(here:gsub("\\", "/"):lower(), got)
    end
  end
  -- plug-in chains: rewritten by their owner, so a differing copy is only refreshed where it's missing (Syncthing
  -- and the owner's own pass keep the rest current)
  local users = {}
  for _, side in ipairs({ here, there }) do for _, u in ipairs(band.subdirs(side .. "/fx")) do users[u] = true end end
  for u in pairs(users) do
    for _, pair in ipairs(mine(u .. "-", user) and { { here, there }, { there, here } } or { { there, here } }) do
      local a, z = pair[1] .. "/fx/" .. u, pair[2] .. "/fx/" .. u
      for _, f in ipairs(band.files(a)) do
        if not arriving(f) and not reaper.file_exists(z .. "/" .. f) then if out_of_time() then return n, true end; copy(a .. "/" .. f, z .. "/" .. f) end
      end
    end
  end
  -- takes: each file where it belongs, on both sides
  tidy(there .. "/takes"); tidy(there .. "/_trash")
  local trashed = drive.trashed(events)
  local where = {} -- name -> { [side .. "/" .. sub] = true }
  local cur_rev, newest, mrev = {}, {}, {} -- per take: newest manifest's revision and path; per manifest path: its revision
  for _, side in ipairs({ here, there }) do
    for _, sub in ipairs({ "takes", "_trash" }) do
      for _, f in ipairs(band.files(side .. "/" .. sub)) do
        local id, _, manifest = drive.parse(f)
        if id and not f:match("^[.~]") then -- (Syncthing's .syncthing.*.tmp while a file is arriving)
          where[f] = where[f] or {}
          where[f][side .. "/" .. sub] = true
          if manifest then
            local path = side .. "/" .. sub .. "/" .. f
            local m = band.read_json(path)
            mrev[path] = m and tonumber(m.rev) or 1
            if mrev[path] > (cur_rev[id:lower()] or 0) then cur_rev[id:lower()], newest[f] = mrev[path], path end
          end
        end
      end
    end
  end
  for f, at in pairs(where) do
    local dest = drive.place(f, trashed, cur_rev)
    local id, _, manifest = drive.parse(f)
    for _, side in ipairs({ here, there }) do
      local want, other = side .. "/" .. dest, side .. "/" .. (dest == "takes" and "_trash" or "takes")
      local stale = manifest and (mrev[want .. "/" .. f] or 0) < cur_rev[id:lower()] -- an older revision's manifest
      local work = not at[want] or stale or (at[other] and at[want])
      -- on Drive, someone else's take is theirs to file: their machine moves it at once, ours only if it's still
      -- undone 5 minutes on (2026-10-28: both machines moving a just-deleted take at once, Drive refused one with
      -- "Can't add file ... you don't have permission to add files to 'takes'" and kept a "(1)" copy)
      if work and side == there and not due("place:" .. f, f, user, wait) then goto next_side end
      if not at[want] or stale then
        if out_of_time() then return n, true end
        if at[other] and not manifest then -- on this side already: a move
          reaper.RecursiveCreateDirectory(want, 0)
          if os.rename(other .. "/" .. f, want .. "/" .. f) then at[other], n = nil, n + 1 end
        else
          local src = manifest and newest[f] or (function() for k in pairs(at) do return k .. "/" .. f end end)()
          copy(src, want .. "/" .. f)
          mrev[want .. "/" .. f] = manifest and cur_rev[id:lower()] or nil
        end
        at[want] = true
        if dest == "_trash" and side == here then into_trash_index(want, f) end -- (Drive's copy has none: one file both would write)
      end
      if at[other] and at[want] then -- the right place has it, so this copy in the wrong one is only a leftover
        if os.remove(other .. "/" .. f) then at[other] = nil end
      end
      ::next_side::
    end
  end
  return n, false
end

-- ---- the cloud copy as the studio's backup and its always-on member where there's no hub (James, 2026-11-19, rt) ----
-- A pass every EVERY s when nothing's happening; SOON s after changes went out (yours reach the cloud copy within half a minute, not three),
-- or after catch-up found files Syncthing still needs and nobody on the link to bring them (the cloud may have them); straight on while a
-- pass has work left. Never closer than SOON apart: Drive limits how often one account may change files. Pure.
drive.EVERY, drive.SOON = 180, 30
function drive.pass_due(now, last, more, soon_at, cloud_want)
  if more then return true end
  if now - last < drive.SOON then return false end
  return (soon_at ~= nil and now >= soon_at) or cloud_want == true or now - last > drive.EVERY
end
-- Media a pass brought here from the cloud copy (Live sync has Syncthing rescan each and its temp tidied, as for the link's: lib/streams.lua)
drive.landed = {}
-- Health's row for the cloud copy from Live sync's record of its last pass ({ at, moved, more, err }, os.time()), or nil (no cloud copy here,
-- or nothing recorded yet). label: the service's name. Pure.
function drive.health_row(st, now, label)
  if type(st) ~= "table" or not tonumber(st.at) then return nil end
  local ago = now - st.at
  local when = ago < 90 and "under a minute ago" or string.format("%d minutes ago", math.floor(ago / 60))
  if st.err then
    return { "cloud copy", false, "yellow", label .. ": last pass failed", label .. " copy: the last pass (" .. when .. ") failed: " .. tostring(st.err) ..
      ". Everything still syncs between you; it tries again each pass." }
  end
  if ago > 15 * 60 then
    return { "cloud copy", false, "yellow", label .. ": no pass lately", label .. " copy: no pass for " .. math.floor(ago / 60) ..
      " minutes (passes run while REAPER is stopped, at most every 3 minutes). The backup is that far behind." }
  end
  local text = st.more and (label .. " copy: still copying (" .. tostring(st.moved or 0) .. " files last pass), carries on between passes")
    or (label .. " copy: up to date, last pass " .. when)
  return { "cloud copy", true, st.more and "grey" or "green", text, text .. ". The studio's backup, and what anyone opening the project brings when nobody else is on." }
end

-- Every song here in full keeps its copy on Drive, not only the one open (James, 2026-11-01): a song a bandmate
-- made can then be opened when nobody who has it is online, since opening a song brings its rooms from Drive
-- (Live sync's pass for the open song). One song a pass, in turn, carried on while it has work left. `songs`: the
-- songs here in full; `skip`: the open one (its own pass). Returns files copied, whether that song has more, and it.
local turn = { i = 0 }
function drive.upkeep(cfg, droot, songs, skip, budget)
  local list = {}
  for _, s in ipairs(songs) do if s ~= skip then list[#list + 1] = s end end
  if #list == 0 then return 0, false end
  if not turn.more or not list[turn.i] then turn.i = turn.i % #list + 1 end
  local song, t0, n, more = list[turn.i], reaper.time_precise(), 0, false
  for _, room in ipairs(band.subdirs(band.song_dir(cfg, song) .. "/rooms")) do
    local left = (budget or 1) - (reaper.time_precise() - t0)
    if left <= 0 then more = true; break end
    local okm, k, m = pcall(drive.mirror, band.song_dir(cfg, song) .. "/rooms/" .. room, droot .. "/" .. song .. "/rooms/" .. room, left, cfg.user)
    if not okm then turn.more = false; return n, false, song end -- (on to the next song next time: it stayed on this one. Review, 0.59.14)
    n, more = n + k, more or m
  end
  turn.more = more
  return n, more, song
end

-- Health's grey row for a computer with no cloud copy of the studio: what one would bring it, and how to add it (`how`: drive.share_hint;
-- `place`: where another service is picked). The laptop here had none and nothing said what it missed (James, rt). Pure.
function drive.join_hint(label, how, place)
  local text = "No " .. label .. " copy of the studio here. One would give this computer a backup of every project, projects that open when nobody " ..
    "else is on, and StudioSync updates while the owner is away. Install " .. label .. "'s desktop app and sign in, then: " .. how ..
    " (another service: " .. place .. ")."
  return { "cloud copy hint", false, "grey", text, text }
end

-- ---- the studio's update files in the cloud copy (James, 2026-11-19: updates for a member who's never on when the owner is, rt) ----
-- <studio>/_tools/studiosync (the studio's own StudioSync, signed by its owner: lib/fromfolder.lua, band.signed_ok) goes to
-- <cloud>/_tools/studiosync from the owner's computer, and a computer whose studio folder has an older one brings the cloud's into it. Only in a
-- studio with an update key, and only a copy that checks as signed with the key pinned on this computer, checked again just before it's copied:
-- anyone with the cloud folder can write there, so it's never a way round the signature. What it brings then goes through the usual update
-- flow, which checks it all again before any of it runs (band.update_ok, band.code_guard); "update ok" isn't touched, as a keyed studio's
-- signature decides, not that. Never an older version over a newer one, and not while Syncthing is still bringing _tools here (it may be
-- bringing the newer one). Members only read the cloud's copy; only the owner writes it (drive.mine's one-writer rule).
-- What a member brings in is dated as the cloud's copy (drive.date_like): dated now, a version the owner signed and never got to the cloud
-- before going offline lost the Syncthing conflict to the older signed copy once they met (Syncthing keeps the newer-dated side). (James, rt)

-- The script that gives each copy its source's modified time: PowerShell on Windows, `touch -r` elsewhere. pairs: { { from, to } }. Pure.
function drive.date_like_script(pairs, win)
  local lines = {}
  for _, p in ipairs(pairs) do
    if win then
      local a, z = p[1]:gsub("'", "''"), p[2]:gsub("'", "''")
      lines[#lines + 1] = "try { (Get-Item -LiteralPath '" .. z .. "').LastWriteTime = (Get-Item -LiteralPath '" .. a .. "').LastWriteTime } catch {}"
    else
      local a, z = p[1]:gsub("'", "'\\''"), p[2]:gsub("'", "'\\''")
      lines[#lines + 1] = "touch -r '" .. a .. "' '" .. z .. "' 2>/dev/null"
    end
  end
  return table.concat(lines, "\n") .. "\n"
end
-- Run it in the background (REAPER never waits). -> true when started.
function drive.date_like(pairs)
  if #pairs == 0 then return false end
  local dir = band.norm(os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp")
  local path = dir .. "/studiosync-date-like" .. (band.WIN and ".ps1" or ".sh")
  if not pcall(band.write_atomic, path, drive.date_like_script(pairs, band.WIN)) then return false end
  local cmd = band.WIN and ('powershell -NoProfile -ExecutionPolicy Bypass -File "' .. path .. '"') or ("/bin/sh '" .. path .. "'")
  return pcall(require("services").run_hidden, "studiosync-date-like", cmd, 0)
end

-- A signed copy's files, from its lib/files.txt: each one with a SHA-256 row, then lib/files.txt, and lib/files.txt.sig last (a copy half across
-- never checks as signed). nil when there are none, or a path could step outside the copy (the list came from a folder others can write). Pure.
function drive.tools_files(text)
  local out = {}
  for line in (text or ""):gmatch("[^\r\n]+") do
    local p = line:match("^sha256 %x+ (.+)$")
    if p then
      if p:find("..", 1, true) or p:find("^/") or p:find("[:\\%c]") then return nil end
      if p ~= "lib/files.txt" and p ~= "lib/files.txt.sig" then out[#out + 1] = p end
    end
  end
  if not out[1] then return nil end
  out[#out + 1] = "lib/files.txt"
  out[#out + 1] = "lib/files.txt.sig"
  return out
end
-- Which way the update files go: "in" (the cloud's signed copy into the studio folder: strictly newer than the version there, signed or not, so
-- a version still arriving by Syncthing is never written over by an older one), "out" (the studio's signed copy to the cloud, from the owner:
-- the cloud has none, an unsigned one, or another signature of a version no newer), or nil. `hv`: the studio copy's version on disk; `h`, `t`:
-- { version, sig } of the studio's and the cloud's copies when signed with the studio's key, else nil. Pure.
function drive.tools_way(hv, h, t, owner)
  local newer = require("fromfolder").at_least
  if t and t.version and (not hv or not newer(hv, t.version)) then return "in" end
  if owner and h and h.version and (not t or (h.sig ~= t.sig and newer(h.version, t.version))) then return "out" end
  return nil
end

local tools_memo, tools_said = {}, {}
-- { version, sig } of the copy in `dir` when it checks as signed with `key`, else nil: checked once per lib/files.txt and .sig (a whole copy's
-- SHA-256s each pass would be most of it). Only for choosing the way: what's copied is checked again first.
local function signed_copy(dir, key)
  local text, sig = band.read(dir .. "/lib/files.txt"), band.read(dir .. "/lib/files.txt.sig")
  if not (text and sig) then return nil end
  local m = tools_memo[dir]
  if not (m and m.text == text and m.sig == sig and m.key == key) then
    m = { text = text, sig = sig, key = key, ok = band.signed_ok(dir, key) == true }
    tools_memo[dir] = m
  end
  return m.ok and { version = text:match("^version (%S+)"), sig = sig } or nil
end
-- The signed copy in `from` over `to`: checked, copied where a file differs (in drive.tools_files' order), code files `to` has that the list
-- doesn't name taken away (a module the new version dropped: the copy never checks as whole with it), then `to` checked. -> files changed, or
-- nil and why.
local function send_tools(from, to, key, dated)
  local ok, why = band.signed_ok(from, key)
  if not ok then return nil, why end
  local files = drive.tools_files(band.read(from .. "/lib/files.txt"))
  if not files then return nil, "its lib/files.txt names a file outside the copy" end
  local n, keep, copied = 0, {}, {}
  for _, rel in ipairs(files) do
    keep[rel] = true
    local a = band.read(from .. "/" .. rel)
    if not a then return nil, "couldn't read " .. rel end
    if band.read(to .. "/" .. rel) ~= a then
      reaper.RecursiveCreateDirectory((to .. "/" .. rel):match("^(.*)/"), 0)
      band.copy_atomic(from .. "/" .. rel, to .. "/" .. rel)
      copied[#copied + 1] = { from .. "/" .. rel, to .. "/" .. rel }
      n = n + 1
    end
  end
  if dated then drive.date_like(copied) end -- (into the studio folder: dated as the cloud's, so the owner's newer version wins in Syncthing)
  local code = {}
  for _, f in ipairs(band.files(to, ".lua")) do if f:find("^StudioSync %- ") then code[#code + 1] = f end end
  for _, f in ipairs(band.files(to .. "/lib", ".lua")) do code[#code + 1] = "lib/" .. f end
  for _, rel in ipairs(code) do if not keep[rel] and os.remove(to .. "/" .. rel) then n = n + 1 end end
  tools_memo[to] = nil
  ok, why = band.signed_ok(to, key)
  if not ok then return nil, "copied, but the copy doesn't check: " .. tostring(why) end
  return n
end
-- From Live sync's cloud pass, at most every EVERY s (reads two small files in the cloud copy, and a listing only when there's work).
drive.tools_at = -math.huge
function drive.tools_pass(cfg, droot, now)
  if now - drive.tools_at < drive.EVERY then return end
  drive.tools_at = now
  local key = band.studio_update_key(cfg.root)
  if not key then return end
  -- (a guest's computer never runs or syncs the studio's copy: lib/fromfolder.lua wanted)
  if select(2, pcall(function() return require("access").mine(cfg.root) ~= nil or require("removal").am_guest(cfg.root) end)) == true then return end
  local here, there = require("fromfolder").target(cfg.root), droot .. "/_tools/studiosync"
  local hv = band.version_on_disk(here)
  local t = signed_copy(there, key)
  local way = drive.tools_way(hv, signed_copy(here, key), t, require("groups").role(cfg.root, cfg.user) == "owner")
  if not way then return end
  if way == "in" then -- (not while Syncthing still needs anything in _tools here, or before it has said: that may be a newer version arriving)
    local need = require("services").need(band.info(cfg.root).id, 60)
    if not need or need:find("_tools[/\\]+studiosync") then return end
  end
  local cloud = drive.label(drive.service_of(droot))
  local n, why = send_tools(way == "in" and there or here, way == "in" and here or there, key, way == "in")
  local v = way == "in" and t.version or hv
  local said = way .. " " .. tostring(v) .. " " .. tostring(n and "ok" or why)
  if tools_said[said] then return n end
  tools_said[said] = true
  if not n then
    band.log("StudioSync " .. tostring(v) .. (way == "in" and (" in the " .. cloud .. " copy wasn't brought into the studio's folder: ") or
      (" couldn't go to the " .. cloud .. " copy: ")) .. tostring(why))
  elseif n > 0 then
    band.log(way == "in" and ("StudioSync " .. tostring(v) .. " came from the " .. cloud .. " copy into the studio's folder (signed with the studio's update key): it updates from there as usual")
      or ("StudioSync " .. tostring(v) .. " is in the " .. cloud .. " copy, for anyone in the studio who isn't on when you are"))
  end
  return n
end

return drive
