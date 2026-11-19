-- Per-song sync (docs/bands-design.md): every machine gets every song's listing (a few KB: what the song chooser
-- shows), and a song in full only once it's opened here. Syncthing's ignore file in the shared folder (.stignore,
-- never synced: each machine its own) holds a block StudioSync writes; anything else in that file is left as it is.
--   !/_*  !/plugins  !/drummaps      the band-wide folders, always (a new band-wide folder must be added here)
--   !/<Song>                          each song opened on this machine, in full
--   !/*/session.json ...              every other song's listing
--   /*/*                              the rest of every other song
-- First match wins, and the !-lines come first, so Syncthing still looks inside the songs it skips for their
-- listing. Files already here are never deleted by it: a song stops downloading, its files stay until removed.
-- Song names are plain (band.clean: letters, digits, spaces, - and _), so nothing in them needs escaping.
local band = require("band")
local songsync = {}

local BEGIN, END = "// StudioSync: what this computer downloads (written by StudioSync, up to the line below)", "// StudioSync end"
local OLD_BEGIN, OLD_END = "// BandSync: what this computer downloads (written by BandSync, up to the line below)", "// BandSync end" -- (from before the rename: replaced the same way)
songsync.BAND_WIDE = { "/_*", "/plugins", "/drummaps" }
songsync.LISTING = { "/*/session.json", "/*/folder.json", "/*/live.json", "/*/invites", "/*/chat", "/*/inbox", -- (inbox: audio dropped in from any computer, lib/extras.lua)
  "/*/rooms/*/room.json",
  "/*/rooms/*/summary", "/*/rooms/*/status", "/*/rooms/*/chat" }

-- The block's lines for the songs wanted here. Pure.
function songsync.block(wanted)
  local out = { BEGIN }
  for _, p in ipairs(songsync.BAND_WIDE) do out[#out + 1] = "!" .. p end
  local list = {}
  for s in pairs(wanted) do list[#list + 1] = s end
  table.sort(list)
  for _, s in ipairs(list) do out[#out + 1] = "!/" .. s end
  for _, p in ipairs(songsync.LISTING) do out[#out + 1] = "!" .. p end
  out[#out + 1] = "(?d)/*/*" -- ((?d): a folder the band deletes goes, its ignored files with it)
  out[#out + 1] = END
  return out
end

-- A computer keeping every song, with some deleted here (lib/localcopy.lua): everything comes, but those only as a listing. Pure.
function songsync.block_except(gone)
  local out = { BEGIN }
  for _, p in ipairs(songsync.LISTING) do out[#out + 1] = "!" .. p end
  local list = {}
  for s in pairs(gone) do list[#list + 1] = s end
  table.sort(list)
  for _, s in ipairs(list) do out[#out + 1] = "(?d)/" .. s .. "/*" end
  out[#out + 1] = END
  return out
end

-- A guest who sees only some projects (lib/access.lua): the band-wide folders and their projects, in full, and nothing else at the top
-- of the folder, not even another project's listing, so they never learn the others' names. Pure.
function songsync.block_guest(allowed)
  -- (but not the studio's copy of StudioSync: band-wide, a guest's edit there reached every computer that updates through the folder, and ran.
  -- First match wins, so this goes before the band-wide lines. Full review, 0.59.44)
  local out = { BEGIN, "/_tools" }
  for _, p in ipairs(songsync.BAND_WIDE) do out[#out + 1] = "!" .. p end
  local list = {}
  for s in pairs(allowed) do list[#list + 1] = s end
  table.sort(list)
  for _, s in ipairs(list) do out[#out + 1] = "!/" .. s end
  out[#out + 1] = "(?d)/*"
  out[#out + 1] = END
  return out
end

-- The ignore file's text with StudioSync's block replaced (or added at the end; nil wanted = taken out). `gone`: keep everything but these.
-- `allowed`: a guest's projects (they win over the rest). Pure.
-- The studio's debug reports (lib/debugmode.lua, <studio>/_debug/<name>/): everyone's reach the owner and admins only. Anyone else keeps
-- their own folder (so it's sent) and doesn't download the rest: a member's projects and logs went to every member. 0.59.40.
-- `debug`: { me = this computer's folder name, hide = true when it isn't the owner's or an admin's } or nil. -> lines for the block. Pure.
function songsync.debug_lines(debug)
  if not (debug and debug.hide and debug.me and debug.me ~= "") then return {} end
  return { "!/_debug/" .. debug.me, "/_debug" }
end
-- A guest's computer (a list or not: removal.am_guest) doesn't sync the studio's copy of StudioSync, nor other people's holds, guests' lists,
-- guest invitations and feedback (they name projects a guest with a list isn't to know of); its own holds, list and feedback still go.
-- `guest`: { me = its StudioSync name, device = its Syncthing ID } or nil. -> lines for the block, first. Pure. James's decision, Round 1 review, 0.59.45.
-- (`guest.limited`: a guest with a project list. Only theirs leave out others' holds lists, which name projects: an every-project guest needs
-- them, or Sync and exit could never find anyone who has the project. Round 2 review, 0.59.46)
function songsync.guest_lines(guest)
  if not (guest and guest.me) then return {} end
  local me = tostring(guest.me)
  local out = { "/_tools" }
  if guest.limited then out[#out + 1] = "!/_band/holds/" .. me:gsub("[^%w%-_ ]", "") .. ".json"; out[#out + 1] = "/_band/holds" end
  for _, l in ipairs({ "!/_band/guest-access/" .. tostring(guest.device or ""):sub(1, 7):gsub("[^%w]", "") .. ".json", "/_band/guest-access", "/_band/guest-invites",
    "!/_band/feedback/*-" .. me:gsub("[^%w%-_]", "_") .. ".md", "/_band/feedback" }) do out[#out + 1] = l end
  return out
end
function songsync.merge(text, wanted, gone, allowed, debug, guest)
  local keep, inside = {}, false
  text = (text or ""):gsub("^\239\187\191", "") -- (a byte-order mark would hide the first line: an editor's, or PowerShell's)
  for line in ((text or "") .. "\n"):gmatch("(.-)\r?\n") do
    if line == BEGIN or line == OLD_BEGIN then inside = true
    elseif inside and (line == END or line == OLD_END) then inside = false
    elseif not inside then keep[#keep + 1] = line end
  end
  while #keep > 0 and keep[#keep] == "" do keep[#keep] = nil end
  local dbg = songsync.debug_lines(debug)
  for _, l in ipairs(songsync.guest_lines(guest)) do if not (allowed and l == "/_tools") then dbg[#dbg + 1] = l end end -- (block_guest has its own)
  if allowed or wanted or (gone and next(gone)) or #dbg > 0 then
    if #keep > 0 then keep[#keep + 1] = "" end
    local block = allowed and songsync.block_guest(allowed) or wanted and songsync.block(wanted) or songsync.block_except(gone or {})
    for i, l in ipairs(block) do
      keep[#keep + 1] = l
      if i == 1 then for _, d in ipairs(dbg) do keep[#keep + 1] = d end end -- (first: Syncthing goes by the first line that matches)
    end
  end
  return #keep > 0 and (table.concat(keep, "\n") .. "\n") or ""
end

-- This machine's choices (persistent ExtState): the songs opened here, and "keep every song".
local KEY, ALL, SEEN = "projects here", "projects keep all", "projects here checked"
function songsync.keep_all() return reaper.GetExtState(band.SECTION, ALL) ~= "" end
-- Whether a song is here in more than its listing: any changes, takes, media or stems. (0.34.7 looked at events
-- only, and an older song with takes but no events, like CompTest, read as not here: James's PC, 2026-11-01.)
local function here_in_full(cfg, s)
  local dir = band.song_dir(cfg, s)
  if #band.subdirs(dir .. "/stems") > 0 then return true end
  for _, room in ipairs(band.subdirs(dir .. "/rooms")) do
    for _, part in ipairs({ "events", "takes", "media", "_trash" }) do
      if #band.files(dir .. "/rooms/" .. room .. "/" .. part) > 0 then return true end
    end
  end
  return false
end
function songsync.wanted(cfg)
  local raw = reaper.GetExtState(band.SECTION, KEY)
  local set = {}
  for s in raw:gmatch("[^|]+") do set[s] = true end
  -- once per machine: every song already here in full stays (a machine that had everything keeps it)
  if reaper.GetExtState(band.SECTION, SEEN) == "" then
    for _, s in ipairs(band.songs(cfg)) do if here_in_full(cfg, s) then set[s] = true end end
    songsync.save(set)
    reaper.SetExtState(band.SECTION, SEEN, "2", true)
  end
  return set
end
function songsync.save(set)
  local list = {}
  for s in pairs(set) do list[#list + 1] = s end
  table.sort(list)
  reaper.SetExtState(band.SECTION, KEY, #list > 0 and table.concat(list, "|") or "|", true) -- ("|": chosen, none yet)
end

-- Write the ignore file for this machine's choices and have Syncthing look again. Returns true when it changed.
-- This computer's part in the studio's debug reports: its folder's name, and whether it downloads only its own (not the owner or an admin).
function songsync.debug_of(cfg)
  if not (cfg and cfg.root and cfg.user and cfg.user ~= "") then return nil end
  local ok, may = pcall(function() return require("groups").may_manage(cfg.root, cfg.user) end)
  return { me = (tostring(cfg.user):gsub("[^%w%-_ ]", "_")), hide = not (ok and may) }
end
-- Whether the studio's ignore file already has this computer's debug lines as they should be.
function songsync.debug_ok(cfg)
  local text = band.read(cfg.root .. "/.stignore") or ""
  local want = songsync.debug_lines(songsync.debug_of(cfg))
  local has = text:find("\n/_debug\n", 1, true) ~= nil or text:find("^/_debug\n") ~= nil
  if #want == 0 then return not has end
  return has and text:find("!/_debug/" .. want[1]:sub(10), 1, true) ~= nil
end
function songsync.apply(cfg)
  if not cfg or not cfg.root or cfg.root == "" then return false end
  local path = cfg.root .. "/.stignore"
  local old = band.read(path) or ""
  local okc, allowed = pcall(function() return require("access").mine(cfg.root) end) -- (a guest with a list: theirs only. 0.58.89)
  local okg, guest = pcall(function() return require("removal").am_guest(cfg.root) end)
  guest = ((okc and allowed) or (okg and guest)) and { me = cfg.user or reaper.GetExtState(band.SECTION, "user"), device = require("services").my_device_id(),
    limited = (okc and allowed) and true or nil } or nil
  local new = songsync.merge(old, not songsync.keep_all() and songsync.wanted(cfg) or nil, songsync.keep_all() and songsync.gone() or nil, okc and allowed or nil,
    songsync.debug_of(cfg), guest)
  if new == old then return false end
  band.write_atomic(path, new)
  pcall(function() require("services").rescan(band.info(cfg.root).id) end)
  return true
end

-- A song opened here (open, publish, Live sync): from now on it comes in full.
function songsync.want(cfg, song)
  if not song or song == "" then return end
  local gone = songsync.gone()
  if gone[song] then gone[song] = nil; songsync.save_gone(gone) end
  local set = songsync.wanted(cfg)
  if not set[song] then set[song] = true; songsync.save(set) end
  songsync.apply(cfg)
end

-- The songs whose copy was deleted here (lib/localcopy.lua): by name, on this computer. Opening one brings it back.
function songsync.gone()
  local set = {}
  for s in reaper.GetExtState(band.SECTION, "projects gone"):gmatch("[^|]+") do set[s] = true end
  return set
end
function songsync.save_gone(set)
  local list = {}
  for s in pairs(set) do list[#list + 1] = s end
  table.sort(list)
  reaper.SetExtState(band.SECTION, "projects gone", table.concat(list, "|"), true)
end
-- The songs here in full (the Drive copy's upkeep goes by this: a song deleted here must not come back from Drive by itself).
function songsync.here(cfg)
  local out, gone = {}, songsync.gone()
  if songsync.keep_all() then
    for _, s in ipairs(band.songs(cfg)) do if not gone[s] then out[#out + 1] = s end end
  else
    for s in pairs(songsync.wanted(cfg)) do if not gone[s] then out[#out + 1] = s end end
    table.sort(out)
  end
  return out
end
-- Whether a song's whole copy is meant to be here.
function songsync.is_here(cfg, song)
  if songsync.gone()[song] then return false end
  return songsync.keep_all() or songsync.wanted(cfg)[song] == true
end

-- Stop downloading a song here (its files stay until removed by hand).
function songsync.drop(cfg, song)
  local set = songsync.wanted(cfg)
  set[song] = nil
  songsync.save(set)
  songsync.apply(cfg)
end

return songsync
