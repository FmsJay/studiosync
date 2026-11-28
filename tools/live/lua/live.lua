-- tools/live/lua/live.lua: helpers for StudioSync's live checks, loaded in a real REAPER through its dev eval hook.
-- live.py copies this file beside the hook (dev/live.lua) and every step's chunk starts with `local LV = dofile(<that path>)`.
-- Edits are made the way a person's are: in an undo block named as REAPER's own action names it, so Live sync reads them as a person's.
-- Nothing here saves a project. A step's chunk returns LV.out(value): JSON, which live.py reads back.
local LV = {}
local SEC = "rt-live" -- ExtState section for this tool's own notes (timed steps' results, marks)

-- ---- JSON out (strings, numbers, booleans, arrays, objects) ----
local function esc(s) return (s:gsub('[%c"\\]', function(c) return string.format("\\u%04x", c:byte()) end)) end
function LV.json(v)
  local t = type(v)
  if t == "nil" then return "null" end
  if t == "boolean" then return tostring(v) end
  if t == "number" then return (v ~= v or v == math.huge or v == -math.huge) and "null" or string.format("%.10g", v) end
  if t == "string" then return '"' .. esc(v) .. '"' end
  if t == "table" then
    local n = #v
    if n > 0 or next(v) == nil then
      local o = {}
      for i = 1, n do o[i] = LV.json(v[i]) end
      return "[" .. table.concat(o, ",") .. "]"
    end
    local keys, o = {}, {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    for _, k in ipairs(keys) do o[#o + 1] = '"' .. esc(k) .. '":' .. LV.json(v[k] == nil and v[tonumber(k)] or v[k]) end
    return "{" .. table.concat(o, ",") .. "}"
  end
  return '"' .. esc(tostring(v)) .. '"'
end
function LV.out(v) return "LVJSON" .. LV.json(v) end

-- ---- StudioSync's own modules (the studio folder's copy), loaded once into the hook's Lua; again when the version on disk changed ----
LV.STUDIO = LV_STUDIO or "Smiley Studios"
function LV.studio_root()
  local r = reaper.GetExtState("BandSync", "sync_root")
  -- (the current studio may be another one, Chilio's on the desktop: the Smiley Studios folder sits beside it)
  local dir = r:match("^(.*)[/\\][^/\\]+$") or r
  return dir .. "/StudioSync " .. LV.STUDIO
end
function LV.lib()
  local root = LV.studio_root()
  local dir = root .. "/_tools/studiosync"
  local f = io.open(dir .. "/lib/band.lua")
  local v = f and f:read("a"):match('VERSION = "([^"]+)"'); if f then f:close() end
  if LV_LOADED ~= dir .. "|" .. tostring(v) then
    for name in pairs(package.loaded) do
      if type(name) == "string" and reaper.file_exists(dir .. "/lib/" .. name .. ".lua") then package.loaded[name] = nil end
    end
    package.path = dir .. "/lib/?.lua;" .. package.path:gsub("[^;]*studiosync[/\\]lib[/\\]%?%.lua;", "")
    LV_LOADED = dir .. "|" .. tostring(v)
  end
  return require("band"), dir, v
end

-- ---- StudioSync's actions, as a person runs them ----
-- The folder this computer runs StudioSync's actions from: LV_SCRIPTS (live.py sets it: the desktop's main checkout), else the studio's copy.
function LV.scripts_dir() return LV_SCRIPTS or (LV.studio_root() .. "/_tools/studiosync") end
function LV.run_script(name)
  local id = reaper.AddRemoveReaScript(true, 0, LV.scripts_dir() .. "/" .. name, true)
  if not id or id <= 0 then error("couldn't register " .. name, 0) end
  reaper.Main_OnCommand(id, 0)
  return id
end
-- Work in the test studio (as the web page's Open does: band.use_band). The studio this computer worked in before is kept in ExtState
-- rt-live/prev root and put back by LV.restore_studio().
function LV.use_studio()
  local band = LV.lib()
  local root, now = LV.studio_root(), reaper.GetExtState("BandSync", "sync_root")
  if now ~= root then
    if reaper.GetExtState(SEC, "prev root") == "" then reaper.SetExtState(SEC, "prev root", now, true) end
    band.use_band(root)
  end
  return root
end
function LV.restore_studio()
  local prev = reaper.GetExtState(SEC, "prev root")
  if prev == "" then return "nothing to put back" end
  local band = LV.lib()
  band.use_band(prev)
  reaper.DeleteExtState(SEC, "prev root", true)
  return "back to " .. prev
end
-- Open the studio's song in a tab of its own, as the panel's Projects page and the web page do (Open session, quietly: its boxes go to the log).
function LV.open_song(song)
  if LV.proj(song) then return "open already" end
  LV.use_studio()
  reaper.SetExtState("BandSync", "open project", song .. "|main", false)
  reaper.SetExtState("BandSync", "open quiet", "1", false)
  reaper.DeleteExtState("BandSync", "open said", false)
  LV.run_script("StudioSync - Open session.lua")
  reaper.DeleteExtState("BandSync", "open quiet", false)
  local said = reaper.GetExtState("BandSync", "open said")
  return LV.proj(song) and "opened" or ("not opened: " .. said)
end
-- Make a new song in the studio from an empty new tab (as tests/cross/cross_test.lua's A does): Publish session with "publish as".
function LV.publish_song(song)
  if LV.proj(song) then return "open already" end
  LV.use_studio()
  reaper.Main_OnCommand(40859, 0) -- (File: New project tab)
  local p = reaper.EnumProjects(-1)
  reaper.SetExtState("BandSync", "prepared " .. tostring(p), "1", false)
  reaper.SetExtState("BandSync", "publish as", song, false)
  LV.run_script("StudioSync - Publish session.lua")
  reaper.DeleteExtState("BandSync", "publish as", false)
  return LV.proj(song) and "published" or "not published"
end
-- An empty project file of this tool's (never a song's): what a tab is loaded with to leave it without saving.
function LV.empty_rpp()
  local f = reaper.GetResourcePath() .. "/Scripts/MIDI Control Center/midi_control_center/dev/lv_empty.rpp"
  if not reaper.file_exists(f) then local h = assert(io.open(f, "w")); h:write('<REAPER_PROJECT 0.1 "7.0" 0\n>\n'); h:close() end
  return f
end
-- Load a project file into the song's tab without REAPER's "Save?" box (Main_openProject's noprompt: nothing is written). -> the tab.
function LV.load_into(p, file)
  local was = reaper.EnumProjects(-1)
  reaper.SelectProjectInstance(p)
  reaper.Main_openProject("noprompt:" .. file)
  local now = reaper.EnumProjects(-1)
  if was ~= p and reaper.ValidatePtr(was, "ReaProject*") then reaper.SelectProjectInstance(was) end
  return now
end
-- Close every tab holding this tool's empty project (clean: no box).
function LV.close_empty()
  local n = 0
  for _ = 1, 20 do
    local hit
    for i = 0, 99 do local q, fn = reaper.EnumProjects(i); if not q then break end; if fn:find("lv_empty.rpp", 1, true) then hit = q end end
    if not hit then break end
    reaper.SelectProjectInstance(hit); reaper.Main_OnCommand(40860, 0); n = n + 1
  end
  return n
end
-- Close the song's tab without saving: the empty project loaded into it first (noprompt), then the clean tab closed.
function LV.close_song(song)
  local p = LV.proj(song)
  if not p then return "not open" end
  local was = reaper.EnumProjects(-1)
  LV.load_into(p, LV.empty_rpp())
  reaper.SelectProjectInstance(p)
  reaper.Main_OnCommand(40860, 0) -- (File: Close current project tab: clean now, so no box)
  if was ~= p and reaper.ValidatePtr(was, "ReaProject*") then reaper.SelectProjectInstance(was) end
  return LV.proj(song) and "still open" or "closed"
end

-- ---- the test song's tab ----
-- The tab bound to `song` in the test studio (never another studio's song of the same name). nil when it isn't open here.
function LV.proj(song)
  for i = 0, 99 do
    local p = reaper.EnumProjects(i)
    if not p then return nil end
    local _, s = reaper.GetProjExtState(p, "BandSync", "song")
    local _, r = reaper.GetProjExtState(p, "BandSync", "root")
    if s == song and r:find("StudioSync " .. LV.STUDIO, 1, true) then return p end
  end
end
function LV.need(song)
  local p = LV.proj(song)
  if not p then error("LVNOSONG " .. tostring(song) .. " isn't open here", 0) end
  return p
end
function LV.live_running(p)
  local beat = tonumber(reaper.GetExtState("BandSync", "live " .. tostring(p)))
  return beat ~= nil and reaper.time_precise() - beat < 10
end

-- ---- reading ----
local function tname(t) return select(2, reaper.GetTrackName(t)) end
local function text(get, o, key) local _, v = get(o, key, "", false); return v or "" end
function LV.track(p, name)
  for k = 0, reaper.CountTracks(p) - 1 do
    local t = reaper.GetTrack(p, k)
    if tname(t) == name then return t, k end
  end
end
function LV.tracks_named(p, names)
  local out = {}
  for _, n in ipairs(names) do local t = LV.track(p, n); if not t then error("no track " .. n, 0) end; out[#out + 1] = t end
  return out
end
-- The song as plain data: tracks in order with depth, folder parent (worked out from the depths, as REAPER shows them), rank, mixer basics,
-- items (position, length, name, stand-in mark, StudioSync id). `opts.prefix`: only tracks whose names start with it (a scenario's own).
function LV.state(p, opts)
  opts = opts or {}
  local st, stack, d = { tracks = {} }, {}, 0
  for k = 0, reaper.CountTracks(p) - 1 do
    local t = reaper.GetTrack(p, k)
    local n = tname(t)
    local depth = math.floor(reaper.GetMediaTrackInfo_Value(t, "I_FOLDERDEPTH"))
    local parent = stack[#stack]
    if not opts.prefix or n:sub(1, #opts.prefix) == opts.prefix then
      local items = {}
      for j = 0, reaper.CountTrackMediaItems(t) - 1 do
        local it = reaper.GetTrackMediaItem(t, j)
        local tk = reaper.GetActiveTake(it)
        items[#items + 1] = {
          pos = math.floor(reaper.GetMediaItemInfo_Value(it, "D_POSITION") * 1000 + 0.5) / 1000,
          len = math.floor(reaper.GetMediaItemInfo_Value(it, "D_LENGTH") * 1000 + 0.5) / 1000,
          name = tk and text(reaper.GetSetMediaItemTakeInfo_String, tk, "P_NAME") or "",
          arriving = text(reaper.GetSetMediaItemInfo_String, it, "P_EXT:band_arriving") ~= "",
          oid = text(reaper.GetSetMediaItemInfo_String, it, "P_EXT:band_oid"),
          midi = tk and reaper.TakeIsMIDI(tk) or false,
        }
      end
      st.tracks[#st.tracks + 1] = {
        name = n, depth = depth, parent = parent, d = d,
        rank = text(reaper.GetSetMediaTrackInfo_String, t, "P_EXT:band_rank"),
        oid = text(reaper.GetSetMediaTrackInfo_String, t, "P_EXT:band_oid"),
        vol = math.floor(reaper.GetMediaTrackInfo_Value(t, "D_VOL") * 10000 + 0.5) / 10000,
        mute = reaper.GetMediaTrackInfo_Value(t, "B_MUTE"),
        items = items,
      }
    end
    if depth == 1 then stack[#stack + 1] = n
    elseif depth < 0 then for _ = 1, -depth do stack[#stack] = nil end end
    d = d + depth
  end
  st.count = reaper.CountTracks(p)
  st.live = LV.live_running(p)
  return st
end
-- One line per track: "name<parent|items" (a compact view a scenario compares across computers).
function LV.shape(p, prefix)
  local s = LV.state(p, { prefix = prefix })
  local o = {}
  for _, t in ipairs(s.tracks) do
    local its = {}
    for _, it in ipairs(t.items) do its[#its + 1] = string.format("%.2f+%.2f%s", it.pos, it.len, it.arriving and "~" or "") end
    table.sort(its)
    o[#o + 1] = t.name .. (t.parent and ("<" .. t.parent) or "") .. (#its > 0 and ("|" .. table.concat(its, ",")) or "")
  end
  return table.concat(o, " ; ")
end

-- ---- StudioSync's log (the file, with seconds) ----
function LV.log_path()
  local band = LV.lib()
  return band.log_dir() .. "/studiosync-" .. os.date("%Y-%m-%d") .. ".log"
end
function LV.log_mark()
  local f = io.open(LV.log_path(), "rb")
  if not f then return 0 end
  local n = f:seek("end"); f:close()
  return n
end
-- Lines written since `mark` (LV.log_mark's), optionally only those containing `find` (plain text).
function LV.log_since(mark, find)
  local f = io.open(LV.log_path(), "rb")
  if not f then return {} end
  local n = f:seek("end")
  if n < (mark or 0) then mark = 0 end -- (a new day's file)
  f:seek("set", mark or 0)
  local out = {}
  for l in f:read("a"):gmatch("[^\n]+") do
    if not find or l:find(find, 1, true) then out[#out + 1] = l end
  end
  f:close()
  return out
end
function LV.activity() return reaper.GetExtState("BandSync", "activity") end
-- The log's last `n` lines (containing `find`, plain, when given), each cut to 260 characters.
function LV.log_tail(n, find)
  local all = LV.log_since(0, find)
  local out = {}
  for i = math.max(1, #all - (n or 40) + 1), #all do out[#out + 1] = all[i]:sub(1, 260) end
  return out
end

-- ---- the song's events folder (what each computer sent) ----
-- Events `user` sent since `since` (an os.time), from the studio folder's rooms/<room>/events: [{ id, obj, name, gone }].
function LV.events_since(song, user, since, room)
  local dir = LV.studio_root() .. "/" .. song .. "/rooms/" .. (room or "main") .. "/events"
  local mark = os.date("!%Y%m%d-%H%M%SZ", since)
  local pre = user .. "-"
  local out = {}
  local i = 0
  reaper.EnumerateFiles(dir, -1) -- (REAPER caches a folder's listing: -1 reads it afresh)
  while true do
    local f = reaper.EnumerateFiles(dir, i)
    if not f then break end
    i = i + 1
    if f:sub(1, #pre) == pre and f:sub(#pre + 1, #pre + 16) >= mark and f:match("%.json$") then
      local h = io.open(dir .. "/" .. f)
      local s = h and h:read("a") or ""; if h then h:close() end
      out[#out + 1] = { id = f, obj = s:match('"obj"%s*:%s*"([^"]*)"'), name = s:match('"name"%s*:%s*"([^"]*)"'), gone = s:find('"gone"%s*:%s*true') ~= nil }
    end
  end
  return out
end

-- ---- edits, named as REAPER's own actions name them ----
local function block(p, name, fn)
  reaper.PreventUIRefresh(1)
  reaper.Undo_BeginBlock2(p)
  local ok, err = pcall(fn)
  reaper.Undo_EndBlock2(p, name, -1)
  reaper.PreventUIRefresh(-1)
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
  if not ok then error(err, 0) end
end
LV.block = block
-- New tracks at the end (or at index `at`): names in order. "Insert new track".
function LV.add_tracks(p, names, at)
  block(p, "Insert new track", function()
    local i = at or reaper.CountTracks(p)
    for _, n in ipairs(names) do
      reaper.InsertTrackAtIndex(i, true)
      local t = reaper.GetTrack(p, i)
      reaper.GetSetMediaTrackInfo_String(t, "P_NAME", n, true)
      i = i + 1
    end
  end)
end
-- Delete tracks by name: "Remove tracks" (REAPER's Track: Remove tracks).
function LV.delete_tracks(p, names)
  local ts = LV.tracks_named(p, names)
  block(p, "Remove tracks", function() for _, t in ipairs(ts) do reaper.DeleteTrack(t) end end)
end
-- Delete every track whose name starts with `prefix`, outside any check (clean-up), as one "Remove tracks".
function LV.delete_prefix(p, prefix)
  local ts = {}
  for k = 0, reaper.CountTracks(p) - 1 do local t = reaper.GetTrack(p, k); if tname(t):sub(1, #prefix) == prefix then ts[#ts + 1] = t end end
  -- (its own undo name: StudioSync tells a new deletion by the undo top's text changing, so a clean-up right after a scenario's own "Remove
  -- tracks" was taken for no new point and put back. docs/rt/rt-live.md, bug 1)
  if #ts > 0 then block(p, "Remove tracks (live check clean-up " .. os.time() .. ")", function() for _, t in ipairs(ts) do reaper.DeleteTrack(t) end end) end
  return #ts
end
local function select_only(p, ts)
  for k = 0, reaper.CountTracks(p) - 1 do reaper.SetTrackSelected(reaper.GetTrack(p, k), false) end
  for _, t in ipairs(ts) do reaper.SetTrackSelected(t, true) end
end
-- Move tracks (in their order) to sit before the track named `before` (nil: the end), as a drag does: "Reorder tracks".
-- `into`: make the moved tracks the last children of folder `into` (a drag into a folder). `make_folder` (0/1/2): ReorderSelectedTracks' flag.
function LV.move_tracks(p, names, before, make_folder)
  local ts = LV.tracks_named(p, names)
  local idx = reaper.CountTracks(p)
  if before then local _, k = LV.track(p, before); if not k then error("no track " .. before, 0) end; idx = k end
  block(p, "Reorder tracks", function()
    select_only(p, ts)
    reaper.ReorderSelectedTracks(idx, make_folder or 0)
  end)
end
-- Drag `names` into folder `folder` as its last children (REAPER's drag into a folder, ReorderSelectedTracks flag 2 after the last child).
-- The folder track becomes a folder when it wasn't one.
function LV.into_folder(p, names, folder)
  local ts = LV.tracks_named(p, names)
  local f, fk = LV.track(p, folder)
  if not f then error("no track " .. folder, 0) end
  block(p, "Reorder tracks", function()
    select_only(p, ts)
    if reaper.GetMediaTrackInfo_Value(f, "I_FOLDERDEPTH") ~= 1 then
      -- (not a folder yet: right below it with flag 1, "the track above becomes a folder with these in it")
      reaper.ReorderSelectedTracks(fk + 1, 1)
    else
      -- the folder's end: the first track after fk whose running depth closes it
      local d, k = 0, fk
      repeat
        d = d + reaper.GetMediaTrackInfo_Value(reaper.GetTrack(p, k), "I_FOLDERDEPTH")
        k = k + 1
      until d <= 0 or k >= reaper.CountTracks(p)
      -- k-1 is the folder's last child: place right after it, inside (flag 2: the moved tracks become the folder's last children)
      reaper.ReorderSelectedTracks(k, 2)
    end
  end)
end
-- Move tracks out of any folder, to just before `before` at the top level (nil: the end). "Reorder tracks".
function LV.out_of_folder(p, names, before)
  local ts = LV.tracks_named(p, names)
  local idx = reaper.CountTracks(p)
  if before then local _, k = LV.track(p, before); idx = k end
  block(p, "Reorder tracks", function()
    select_only(p, ts)
    reaper.ReorderSelectedTracks(idx, 0)
  end)
end
-- REAPER's own actions on selected tracks (indent 40914? no: by command id given by the caller), in the test song's tab made current
-- for the moment the action runs, then the previous tab back. Used where the action itself matters (indent / outdent).
function LV.action_on(p, names, cmd)
  local ts = LV.tracks_named(p, names)
  local was = reaper.EnumProjects(-1)
  if was ~= p then reaper.SelectProjectInstance(p) end
  select_only(p, ts)
  reaper.Main_OnCommand(cmd, 0)
  if was ~= p then reaper.SelectProjectInstance(was) end
end
function LV.rename(p, name, new)
  local t = LV.track(p, name); if not t then error("no track " .. name, 0) end
  block(p, "Track name", function() reaper.GetSetMediaTrackInfo_String(t, "P_NAME", new, true) end)
end
function LV.set_vol(p, name, v)
  local t = LV.track(p, name); if not t then error("no track " .. name, 0) end
  block(p, "Track volume", function() reaper.SetMediaTrackInfo_Value(t, "D_VOL", v) end)
end
-- An empty MIDI item on a track (a "take" stand-in that needs no audio): "Insert new MIDI item".
function LV.midi_item(p, name, pos, len)
  local t = LV.track(p, name); if not t then error("no track " .. name, 0) end
  local it
  block(p, "Insert new MIDI item", function() it = reaper.CreateNewMIDIItemInProj(t, pos, pos + len, false) end)
  return it
end
-- A recorded take, as a real recording leaves it: a WAV written into the project's recording folder (generated: a sine at low level,
-- never a microphone), put on the track as REAPER's recording does ("Recorded media"). -> the item.
function LV.record_take(p, name, pos, secs, tag)
  local t = LV.track(p, name); if not t then error("no track " .. name, 0) end
  local dir = reaper.GetProjectPathEx(p, "")
  if dir == "" then error("the project has no recording folder", 0) end
  reaper.RecursiveCreateDirectory(dir, 0)
  local file = string.format("%s/%s-%s-%d.wav", dir, (name:gsub("[^%w]", "")), tag or "lv", math.floor(reaper.time_precise() * 1000) % 100000000)
  LV.write_wav(file, secs or 4)
  local it
  block(p, "Recorded media", function()
    it = reaper.AddMediaItemToTrack(t)
    local tk = reaper.AddTakeToMediaItem(it)
    reaper.SetMediaItemTake_Source(tk, reaper.PCM_Source_CreateFromFile(file))
    reaper.SetMediaItemInfo_Value(it, "D_POSITION", pos)
    reaper.SetMediaItemInfo_Value(it, "D_LENGTH", secs or 4)
    reaper.GetSetMediaItemTakeInfo_String(tk, "P_NAME", (file:match("[^/\\]+$")), true)
  end)
  return it, file
end
-- A 16-bit mono 44.1 kHz sine at -30 dBFS (a generated signal: no input device involved).
function LV.write_wav(file, secs)
  local sr, n = 44100, math.floor(44100 * secs)
  local f = assert(io.open(file, "wb"))
  local function u32(x) return string.char(x % 256, (x // 256) % 256, (x // 65536) % 256, (x // 16777216) % 256) end
  local function u16(x) return string.char(x % 256, (x // 256) % 256) end
  f:write("RIFF", u32(36 + n * 2), "WAVEfmt ", u32(16), u16(1), u16(1), u32(sr), u32(sr * 2), u16(2), u16(16), "data", u32(n * 2))
  local amp, buf = 1036, {} -- (-30 dBFS of 32767)
  for i = 0, n - 1 do
    local s = math.floor(amp * math.sin(2 * math.pi * 440 * i / sr))
    if s < 0 then s = s + 65536 end
    buf[#buf + 1] = u16(s)
    if #buf == 4096 then f:write(table.concat(buf)); buf = {} end
  end
  f:write(table.concat(buf)); f:close()
end
function LV.delete_items_on(p, name)
  local t = LV.track(p, name); if not t then error("no track " .. name, 0) end
  block(p, "Remove items", function()
    for j = reaper.CountTrackMediaItems(t) - 1, 0, -1 do reaper.DeleteTrackMediaItem(t, reaper.GetTrackMediaItem(t, j)) end
  end)
end
-- A copy of an item (Ctrl+drag) at `pos`: "Duplicate items" style copy through the item's chunk, as REAPER's copy keeps every P_EXT.
function LV.copy_item(p, it, pos)
  local t = reaper.GetMediaItem_Track(it)
  local _, chunk = reaper.GetItemStateChunk(it, "", false)
  chunk = chunk:gsub("\nIGUID [^\n]*", ""):gsub("\nGUID [^\n]*", "")
  local new
  block(p, "Copy media items", function()
    new = reaper.AddMediaItemToTrack(t)
    reaper.SetItemStateChunk(new, chunk, false)
    reaper.SetMediaItemInfo_Value(new, "D_POSITION", pos)
  end)
  return new
end

-- ---- the shared moment: a step run at one link-clock time on several computers ----
-- `at`: the studio's shared clock (direct.shared_now) time to run fn at; deferred, so the hook answers at once. The result goes to
-- ExtState rt-live/tm, read back with LV.timed_result().
function LV.now()
  LV.lib()
  local ok, direct = pcall(require, "direct")
  local v = ok and direct.shared_now and direct.shared_now()
  return type(v) == "number" and v or (reaper.StudioSync_DirectNow and reaper.StudioSync_DirectNow()) or os.time()
end
function LV.at(at, fn)
  reaper.SetExtState(SEC, "tm", "waiting", false)
  local function go()
    local ok, r = pcall(fn)
    reaper.SetExtState(SEC, "tm", LV.json({ ok = ok, at = LV.now(), result = ok and r or tostring(r) }), false)
  end
  local function wait() if LV.now() >= at then go() else reaper.defer(wait) end end
  wait()
  return { scheduled = at, now = LV.now() }
end
function LV.timed_result() return reaper.GetExtState(SEC, "tm") end

-- ---- StudioSync's asks: the big deletion and Undo, answered the way the panel's bar answers ----
function LV.asks(p)
  local band = LV.lib()
  local ok, claimask = pcall(require, "claimask")
  if not ok then return { error = tostring(claimask) } end
  return claimask.local_asks(p)
end
-- Answer the pending ask of `kind` ("delete" / "undo") with yes (true/false), exactly as claimask.bar writes it.
function LV.answer(p, kind, yes)
  local list = LV.asks(p)
  for _, a in ipairs(list) do
    if a.kind == kind then
      local band = LV.lib()
      -- (the bar's No to Undo ends it with undo.clear; every other answer is the ExtState Live sync's tick carries out)
      if kind == "undo" and not yes then require("undo").clear(p)
      else reaper.SetExtState("BandSync", kind .. " answer " .. tostring(p), band.json_encode({ id = a.id, yes = yes and true or false }), false) end
      return a
    end
  end
  return nil
end

return LV
