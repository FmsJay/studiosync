-- Google Drive as the band's post box. Syncthing only moves files while two machines are on at the same time; a
-- copy of each room on Drive carries what someone did alone (and every end-of-session restore point) to the others
-- whenever they next open the song, and keeps the band's history off any one machine.
--   <drive root>/<Song>/rooms/<room>/{events,recall,midi,fx,takes,_trash}   same layout as the shared folder
-- Nothing is lost on either side (a file is only removed from one place once it's in the right one). Events, restore points and MIDI are written once, so copying what's
-- missing both ways is enough. A take's files move between takes/ and _trash/ (a delete, an undone delete, a new
-- revision), so where each one belongs is worked out from the room's events and manifests, and both sides end up so.
local band = require("band")
local drive = {}

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
local function places(only)
  local out = {}
  local function add(service, path) if path and (only == nil or only == "" or only == service) then out[#out + 1] = path end end
  local win = reaper.GetOS():find("^Win")
  local home = ((win and os.getenv("USERPROFILE") or os.getenv("HOME")) or ""):gsub("\\", "/")
  -- ("My Drive" is in the computer's language: "Meine Ablage", "Mi unidad"... So every folder at the top of Google's drive is looked in, after
  -- "My Drive". A drive letter is Google's if it has My Drive, or Google's own .shortcut-targets-by-id or .Encrypted. 0.59.10)
  local function google(root, sure)
    local subs = band.subdirs(root)
    local is = sure
    for _, d in ipairs(subs) do if d == "My Drive" or d == ".shortcut-targets-by-id" or d == ".Encrypted" then is = true end end
    if not is then return end
    add("google", root .. "/My Drive")
    for _, d in ipairs(subs) do if d:sub(1, 1) ~= "." and d ~= "$RECYCLE.BIN" and d ~= "My Drive" then add("google", root .. "/" .. d) end end
  end
  if win then -- (drive letters only on Windows: a Mac looked at 23 that can't exist)
    google("G:", false)
    for c = ("D"):byte(), ("Z"):byte() do
      if c ~= ("G"):byte() then google(string.char(c) .. ":", false) end
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
  if reaper.time_precise() - l.at >= 300 then
    l.at = reaper.time_precise()
    l.found, l.missing = drive.find(places(drive.service()), band.subdirs,
      function(p) return reaper.EnumerateSubdirectories(p, 0) ~= nil or reaper.EnumerateFiles(p, 0) ~= nil end, info.drive)
    -- the band's Drive was here and isn't now: that Google account signed out, or Drive switched to another one (Mac,
    -- 2026-10-31: a personal and a band account on one machine). Said, not guessed at: drive.away, for the panel.
    local key = "drive_seen" .. (info.id == "bandsync" and "" or (" " .. info.id)) -- (the first band keeps its old key)
    local seen = reaper.GetExtState(band.SECTION, key)
    local function exists(p) return reaper.EnumerateSubdirectories(p, 0) ~= nil or reaper.EnumerateFiles(p, 0) ~= nil end
    local chosen = drive.service()
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
    if reaper.EnumerateSubdirectories(md, 0) ~= nil or reaper.EnumerateFiles(md, 0) ~= nil then
      reaper.RecursiveCreateDirectory(md .. "/" .. name, 0)
      looked[name] = nil
      return md .. "/" .. name
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
      e = ev and { type = ev.type, take = ev.take, time = ev.time, id = ev.id, user = ev.user } or false
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
    band.copy_atomic(a, z)
    if band.size(a) ~= size or band.size(z) ~= size then os.remove(z); return end
    n = n + 1
  end
  -- written once: whatever's missing goes across
  local events = read_events(here .. "/events", t0 + (budget or 1.5))
  if not events then return 0, true end -- (who owns which recording isn't known yet: nothing's copied on half a list)
  local owners = drive.media_owners(events, here:match("([^/]+)$"))
  longer = drive.longer_names(events, user)
  for _, sub in ipairs({ "trimmed", "events", "recall", "midi", "media" }) do -- (media: recordings and prints the items use)
    local A, B = {}, {}
    for _, f in ipairs(band.files(here .. "/" .. sub)) do if not arriving(f) then A[#A + 1] = f end end
    for _, f in ipairs(band.files(there .. "/" .. sub)) do if not arriving(f) then B[#B + 1] = f end end
    local inA, inB = {}, {}
    for _, f in ipairs(A) do inA[f] = true end
    for _, f in ipairs(B) do inB[f] = true end
    if sub == "media" then -- (prints a trim archived: left where each side has them, not brought back from Drive)
      for f in pairs(select(2, trimmed(here .. "/trimmed"))) do inA[f], inB[f] = true, true end
    end
    if sub == "events" then -- trimmed: not brought back from Drive, and gone from it once whoever made them sees that
      for f in pairs(trimmed(here .. "/trimmed")) do -- ("trimmed" goes first: a list may have just come from Drive)
        inA[f], inB[f] = true, true
        if mine(f, user) and reaper.file_exists(there .. "/events/" .. f) then os.remove(there .. "/events/" .. f) end
      end
    end
    for _, f in ipairs(A) do
      if not inB[f] and (sub == "media" and owners[f] == user or due(here .. "/" .. sub .. "/" .. f, f, user, wait)) then
        if out_of_time() then return n, true end
        copy(here .. "/" .. sub .. "/" .. f, there .. "/" .. sub .. "/" .. f)
      end
    end
    tidy(there .. "/" .. sub)
    for _, f in ipairs(B) do if not inA[f] then if out_of_time() then return n, true end; copy(there .. "/" .. sub .. "/" .. f, here .. "/" .. sub .. "/" .. f) end end
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
    local k, m = drive.mirror(band.song_dir(cfg, song) .. "/rooms/" .. room, droot .. "/" .. song .. "/rooms/" .. room, left, cfg.user)
    n, more = n + k, more or m
  end
  turn.more = more
  return n, more, song
end

return drive
