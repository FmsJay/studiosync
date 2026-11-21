-- A stand-in REAPER whose tracks and items are their chunks, for proving edits end to end offline (tests/test_0_60_rt_edits.lua: one per
-- computer, `reaper = F.reaper` to act as it). What REAPER does to a chunk is what this does: an item's chunk is its text (its GUID and P_EXT
-- written into it when read, taken out of it when set), its position, length, mute, group, selection and takes are read from that text and
-- written back into it; a track's chunk is its settings, its blocks (envelopes, FX, receives: kept as text), then its items, and setting one
-- replaces its items as REAPER does (an item keeps its pointer by its IGUID). Markers, regions, the region render matrix, the tempo map, the
-- loop range and repeat, project info and ProjExtState are kept per project. Every change moves the change count.
--   local F = require("editreaper").new("C:/A/Song.rpp"); reaper = F.reaper
-- shortcut: no plug-ins (TrackFX_GetCount 0), sends or automation items through the API, and one project per instance; enough for item and
-- track edits, markers and the tempo map. Upgrade it when a test needs those through the API.
local E = {}
local seq = 0
local function guid() seq = seq + 1; return string.format("{%08X-0000-0000-0000-%012X}", seq, seq * 7919) end
E.guid = guid
local function f(x) return string.format("%.10g", x) end
E.f = f

-- ---- item text helpers (pure) ----
local function lines(s) local t = {}; for l in (s or ""):gmatch("[^\n]+") do t[#t + 1] = l end; return t end
-- The value of a top-level line `key` in an item's text (depth 1 inside <ITEM, outside takes' sub-blocks), or nil.
local function top_value(text, key)
  local d = 0
  for _, l in ipairs(lines(text)) do
    local s = l:match("^%s*(.-)%s*$")
    if d == 1 then
      local k, v = s:match("^(%S+)%s*(.*)$")
      if k == key then return v end
    end
    if s:sub(1, 1) == "<" then d = d + 1 elseif s == ">" then d = d - 1 end
  end
  return nil
end
-- Set (or add, or with v == nil remove) the first top-level line `key`.
local function set_top(text, key, v)
  local out, d, done = {}, 0, false
  for _, l in ipairs(lines(text)) do
    local s = l:match("^%s*(.-)%s*$")
    local k = d == 1 and s:match("^(%S+)")
    if k == key and not done then
      done = true
      if v ~= nil then out[#out + 1] = key .. " " .. v end
    else out[#out + 1] = l end
    if s:sub(1, 1) == "<" then d = d + 1 elseif s == ">" then d = d - 1 end
  end
  if not done and v ~= nil then table.insert(out, 2, key .. " " .. v) end
  return table.concat(out, "\n") .. "\n"
end
E.top_value, E.set_top = top_value, set_top
-- Takes: the top-level spans of an item's text. Take 0 starts at the first NAME/<SOURCE or take line; each "TAKE" line starts the next.
-- -> { { first, last, null = empty take, sel = "TAKE SEL" } } of line numbers.
local function takes_of(text)
  local L, d, out, cur = lines(text), 0, {}, nil
  for i, l in ipairs(L) do
    local s = l:match("^%s*(.-)%s*$")
    if d == 1 then
      if s:match("^TAKE") then
        if cur then cur.last = i - 1 end
        cur = { first = i, null = s:match("^TAKE%s+NULL") ~= nil, sel = s:match("^TAKE%s+SEL") ~= nil }
        out[#out + 1] = cur
      elseif not cur and (s:match("^NAME ") or s:match("^<SOURCE")) then
        cur = { first = i }
        out[#out + 1] = cur
      end
    end
    if s:sub(1, 1) == "<" then d = d + 1 elseif s == ">" then d = d - 1 end
  end
  if cur then cur.last = #L - 1 end
  return out, L
end
E.takes_of = takes_of

function E.new(path)
  local F = { calls = {}, cc = 1, clock = 1000, playing = 0, path = path or "C:/fake/Song.rpp", undo = nil, redo = nil }
  local proj = { name = "PROJ " .. F.path }
  F.proj = proj
  local tracks = {}
  F.tracks = tracks
  local master = { name = "MASTER", guid = "{MASTER}", ext = {}, vals = {}, body = "", items = {}, vol = 1, pan = 0, mute = 0, depth = 0, color = 0, is_master = true }
  F.master = master
  local markers = {} -- { num, region, pos, rend, name, color }, kept in position order
  F.markers = markers
  local matrix = {} -- region number -> { track, ... } (the region render matrix; the master track for "master mix")
  F.matrix = matrix
  local tempo = { { 0, 120, 4, 4, false } } -- { time, bpm, num, den, linear }
  F.tempo = tempo
  local info, info_s, pext, gext = {}, {}, {}, {}
  F.info, F.info_s, F.pext, F.gext = info, info_s, pext, gext
  F.loop, F.timesel, F.repeat_on = { 0, 0 }, { 0, 0 }, 0
  local function changed() F.cc = F.cc + 1 end
  F.changed = changed

  -- ---- items ----
  local function item_chunk(it)
    local L = lines(it.text)
    local out = { L[1], "IGUID " .. it.guid }
    local keys = {}
    for k in pairs(it.ext) do keys[#keys + 1] = k end
    table.sort(keys)
    if #keys > 0 then
      out[#out + 1] = "<EXT"
      for _, k in ipairs(keys) do out[#out + 1] = k .. " " .. it.ext[k] end
      out[#out + 1] = ">"
    end
    for i = 2, #L do out[#out + 1] = L[i] end
    local c = table.concat(out, "\n") .. "\n"
    -- (F.dialect: this REAPER writes an item a little differently from another's, as a Linux one does from a Windows one: the same item, another
    -- text. A function of the chunk, applied to every read.)
    return F.dialect and F.dialect(c) or c
  end
  -- the item's text from a chunk: its IGUID and <EXT (or <EXTI) block taken out (into it.ext; none: no P_EXT, as REAPER does)
  local function take_in(it, c)
    local out, ext, d, in_ext = {}, {}, 0, false
    for _, l in ipairs(lines(c)) do
      local s = l:match("^%s*(.-)%s*$")
      if in_ext then
        if s == ">" then in_ext = false; d = d - 1
        else local k, v = s:match("^(%S+)%s*(.*)$"); if k then ext[k] = v end end
      elseif d == 1 and (s == "<EXT" or s == "<EXTI") then in_ext = true; d = d + 1
      elseif d == 1 and s:match("^IGUID ") then
      else
        out[#out + 1] = s
        if s:sub(1, 1) == "<" then d = d + 1 elseif s == ">" then d = d - 1 end
      end
    end
    it.text, it.ext = table.concat(out, "\n") .. "\n", ext
  end
  local function new_item(tr, text, g)
    local it = { guid = g or guid(), track = tr, ext = {}, lane = 0, text = "<ITEM\n>\n", tk = {} }
    if text then take_in(it, text) end
    return it
  end
  F.item_chunk = item_chunk
  function F.add_item(tr, text, at) -- (an item as a paste or recording leaves it: its own GUID; P_EXT from the text)
    local it = new_item(tr, text)
    table.insert(tr.items, at or (#tr.items + 1), it)
    changed()
    return it
  end
  function F.remove_item(it) for i, x in ipairs(it.track.items) do if x == it then table.remove(it.track.items, i); changed(); return true end end end
  -- (an edit as REAPER would leave the item's chunk: its P_EXT stays unless the text has an <EXT block of its own)
  function F.set_text(it, text) local keep = it.ext; take_in(it, text); if not text:find("\n%s*<EXTI?\n") then it.ext = keep end; changed() end
  local function sort_items(tr) table.sort(tr.items, function(a, b) return (tonumber(top_value(a.text, "POSITION")) or 0) < (tonumber(top_value(b.text, "POSITION")) or 0) end) end
  F.sort_items = sort_items
  local function all_items()
    local out = {}
    for _, t in ipairs(tracks) do for _, it in ipairs(t.items) do out[#out + 1] = it end end
    return out
  end
  F.all_items = all_items

  -- ---- tracks ----
  local TV = { D_VOL = "vol", D_PAN = "pan", B_MUTE = "mute", I_FOLDERDEPTH = "depth", I_CUSTOMCOLOR = "color" }
  local function track_chunk(t)
    local out = { "<TRACK " .. t.guid, 'NAME "' .. (t.name or "") .. '"', "PEAKCOL " .. (t.color or 0), "VOLPAN " .. f(t.vol) .. " " .. f(t.pan) .. " -1 -1 1",
      "MUTESOLO " .. (t.mute or 0) .. " 0 0", "ISBUS " .. ((t.depth or 0) == 1 and "1 1" or (t.depth or 0) < 0 and ("2 " .. t.depth) or "0 0"), "TRACKID " .. t.guid }
    local keys = {}
    for k in pairs(t.ext) do keys[#keys + 1] = k end
    table.sort(keys)
    if #keys > 0 then
      out[#out + 1] = "<EXT"
      for _, k in ipairs(keys) do out[#out + 1] = k .. " " .. t.ext[k] end
      out[#out + 1] = ">"
    end
    local head = table.concat(out, "\n") .. "\n" .. (t.body or "")
    local parts = { head }
    for _, it in ipairs(t.items) do parts[#parts + 1] = item_chunk(it) end
    parts[#parts + 1] = ">\n"
    return table.concat(parts)
  end
  F.track_chunk = track_chunk
  local function set_track_chunk(t, c)
    local body, ext, items, d = {}, {}, {}, 0
    local block, bdepth -- (an item or EXT block being collected)
    local was = {}
    for _, it in ipairs(t.items) do was[it.guid] = it end
    for _, l in ipairs(lines(c)) do
      local s = l:match("^%s*(.-)%s*$")
      if block then
        block[#block + 1] = s
        if s:sub(1, 1) == "<" then bdepth = bdepth + 1 elseif s == ">" then bdepth = bdepth - 1 end
        if bdepth == 0 then
          if block.kind == "ITEM" then items[#items + 1] = table.concat(block, "\n") .. "\n"
          else for i = 2, #block - 1 do local k, v = block[i]:match("^(%S+)%s*(.*)$"); if k then ext[k] = v end end end
          block = nil
        end
      elseif d == 0 then
        if s:sub(1, 1) == "<" then d = 1 end
      elseif d == 1 and s == ">" then d = 0
      elseif d == 1 and (s:match("^<ITEM") or s == "<EXT") then block, bdepth = { s, kind = s == "<EXT" and "EXT" or "ITEM" }, 1
      elseif d == 1 then
        local k, v = s:match("^(%S+)%s*(.*)$")
        if k == "NAME" then t.name = v:match('^"(.*)"$') or v
        elseif k == "PEAKCOL" then t.color = tonumber(v) or 0
        elseif k == "VOLPAN" then local a, b = v:match("^(%S+)%s+(%S+)"); t.vol, t.pan = tonumber(a) or 1, tonumber(b) or 0
        elseif k == "MUTESOLO" then t.mute = tonumber(v:match("^(%S+)")) or 0
        elseif k == "ISBUS" then local a, b = v:match("^(%S+)%s+(%S+)"); t.depth = a == "1" and 1 or a == "2" and tonumber(b) or 0
        elseif k == "TRACKID" then
        else
          body[#body + 1] = s
          if s:sub(1, 1) == "<" then d = d + 1 end
        end
      else
        body[#body + 1] = s
        if s:sub(1, 1) == "<" then d = d + 1 elseif s == ">" then d = d - 1 end
      end
    end
    t.body = #body > 0 and (table.concat(body, "\n") .. "\n") or ""
    t.ext = ext
    t.items = {}
    for _, c2 in ipairs(items) do
      local g = c2:match("\n%s*IGUID (%S+)")
      local it = g and was[g] or new_item(t, nil, g)
      take_in(it, c2)
      it.track = t
      t.items[#t.items + 1] = it
    end
  end
  F.set_track_chunk = function(t, c) set_track_chunk(t, c); changed() end
  function F.add_track(name, at, body)
    local t = { guid = guid(), name = name or "", vol = 1, pan = 0, mute = 0, depth = 0, color = 0, vals = {}, ext = {}, body = body or "", items = {} }
    table.insert(tracks, at or (#tracks + 1), t)
    changed()
    return t
  end
  local function index_of(t) for i, x in ipairs(tracks) do if x == t then return i end end end
  local function parent_of(t)
    local stack = {}
    for _, x in ipairs(tracks) do
      if x == t then return stack[#stack] end
      if (x.depth or 0) == 1 then stack[#stack + 1] = x elseif (x.depth or 0) < 0 then for _ = 1, -x.depth do stack[#stack] = nil end end
    end
  end
  -- envelopes: the track's own blocks in its body (<VOLENV2 ..., <PANENV2 ...)
  local function envs_of(t)
    local out, cur, d = {}, nil, 0
    for _, l in ipairs(lines(t.body)) do
      if d == 0 and l:sub(1, 1) == "<" then
        local tag = l:match("^<(%S+)")
        if tag:match("^%u+ENV%d*$") and tag:sub(1, 3) ~= "AUX" then cur = { tr = t, tag = tag, text = {}, pts = 0 }; out[#out + 1] = cur else cur = nil end
      end
      if cur then
        cur.text[#cur.text + 1] = l
        if d == 1 and l:match("^PT ") then cur.pts = cur.pts + 1 end
      end
      if l:sub(1, 1) == "<" then d = d + 1 elseif l == ">" then d = d - 1 end
      if d == 0 then cur = nil end
    end
    return out
  end

  -- ---- markers ----
  local function sort_markers() table.sort(markers, function(a, b) if a.pos ~= b.pos then return a.pos < b.pos end; return (a.region and 1 or 0) < (b.region and 1 or 0) end) end
  F.sort_markers = sort_markers
  local function free_num(region)
    local used = {}
    for _, m in ipairs(markers) do if m.region == region then used[m.num] = true end end
    local n = 1
    while used[n] do n = n + 1 end
    return n
  end
  function F.add_marker(region, pos, rend, name, num, color)
    local m = { region = region, pos = pos, rend = region and rend or pos, name = name or "", num = num or free_num(region), color = color or 0 }
    markers[#markers + 1] = m
    sort_markers(); changed()
    return m
  end
  -- SWS, as the desktop and laptop have it (sws-autocoloricon.ini: auto marker colouring on, one rule, "any marker" gets a colour): F.sws holds
  -- the switches it's installed with (command name -> on), F.sws_tick is its timer: a marker with no colour of its own gets the rule's.
  F.sws, F.sws_ids = {}, { [53273] = "_SWSAUTOCOLOR_ENABLE", [53274] = "_S&MAUTOCOLOR_MKR_ENABLE", [53275] = "_S&MAUTOCOLOR_RGN_ENABLE" }
  F.sws_marker_colour = 22955745
  function F.sws_tick()
    if not F.sws["_S&MAUTOCOLOR_MKR_ENABLE"] then return 0 end
    local n = 0
    for _, m in ipairs(markers) do if not m.region and (m.color or 0) == 0 then m.color = F.sws_marker_colour; n = n + 1 end end
    if n > 0 then changed() end
    return n
  end

  -- ---- takes ----
  local function take(it, k)
    local spans = takes_of(it.text)
    local s = spans[k + 1]
    if not s or s.null then return nil end
    it.tk[k] = it.tk[k] or { item = it, k = k, ext = {} }
    return it.tk[k]
  end
  local function take_text(tk)
    local spans, L = takes_of(tk.item.text)
    local s = spans[tk.k + 1]
    if not s then return "" end
    return table.concat(L, "\n", s.first, s.last)
  end
  local function cur_take(it)
    for k, s in ipairs(takes_of(it.text)) do if s.sel then return k - 1 end end
    return 0
  end

  -- ---- the tempo map: what's in beats stays on its beat when the map changes, as in REAPER with its default timebases ----
  -- (checked against REAPER 7.86 on Cross Test: 130 bpm, a 100 bpm marker added at 8.0 s took an item at 7.385 + 3.692 s to 4.615 s long, an
  -- audio item's end from 22.754 to 27.180 and a region's end from 18.46 to 21.60; the first tempo to 120 then moved that marker to 8.667 s.
  -- An item whose chunk says "BEAT 0" stands for one set to the time timebase, and stays.)
  F.base_bpm, F.timebase = 120, "beats"
  local function qn_in(map, base, t)
    local q, pt, pb = 0, 0, base
    for _, m in ipairs(map) do
      if m[1] > t then break end
      q = q + (m[1] - pt) * pb / 60
      pt, pb = m[1], m[2]
    end
    return q + (t - pt) * pb / 60
  end
  local function time_in(map, base, q)
    local pq, pt, pb = 0, 0, base
    for _, m in ipairs(map) do
      local mq = pq + (m[1] - pt) * pb / 60
      if mq > q then break end
      pq, pt, pb = mq, m[1], m[2]
    end
    return pt + (q - pq) * 60 / pb
  end
  function F.qn_of(t) return qn_in(tempo, F.base_bpm, t) end
  function F.time_of(q) return time_in(tempo, F.base_bpm, q) end
  local function g14(x) return string.format("%.14g", x) end
  -- One edit of the tempo map (`fn` makes it and returns the marker it set or took out).
  function F.tempo_edit(fn)
    local old, old_base, at = {}, F.base_bpm, {}
    for i, m in ipairs(tempo) do old[i] = { m[1], m[2] } end
    for _, m in ipairs(tempo) do at[m] = qn_in(old, old_base, m[1]) end
    local edited = fn()
    table.sort(tempo, function(a, b) return a[1] < b[1] end)
    local et, built = edited and edited[1] or math.huge, {}
    for _, m in ipairs(tempo) do -- (the tempo markers after it keep their beats)
      if m ~= edited and at[m] and m[1] > et then m[1] = time_in(built, F.base_bpm, at[m]) end
      built[#built + 1] = m
    end
    if F.timebase == "beats" then
      local function move(t) return time_in(tempo, F.base_bpm, qn_in(old, old_base, t)) end
      for _, t in ipairs(tracks) do
        for _, it in ipairs(t.items) do
          if top_value(it.text, "BEAT") ~= "0" then
            local p, l = tonumber(top_value(it.text, "POSITION")) or 0, tonumber(top_value(it.text, "LENGTH")) or 0
            local np, ne = move(p), move(p + l)
            if math.abs(np - p) > 1e-12 then it.text = set_top(it.text, "POSITION", g14(np)) end
            if math.abs((ne - np) - l) > 1e-12 then it.text = set_top(it.text, "LENGTH", g14(ne - np)) end
          end
        end
        if t.body ~= "" then
          t.body = t.body:gsub("(\n?)PT (%S+)", function(nl, v)
            local x = tonumber(v)
            if not x then return nl .. "PT " .. v end
            local nx = move(x)
            return nl .. "PT " .. (math.abs(nx - x) > 1e-12 and g14(nx) or v)
          end)
        end
      end
      for _, m in ipairs(markers) do
        local np = move(m.pos)
        if m.region then local ne = move(m.rend); if math.abs(ne - m.rend) > 1e-12 then m.rend = tonumber(g14(ne)) end end
        if math.abs(np - m.pos) > 1e-12 then m.pos = tonumber(g14(np)) end
        if not m.region then m.rend = m.pos end
      end
    end
    changed()
  end

  local R = {
    time_precise = function() return F.clock end,
    GetOS = function() return "Win64" end, GetAppVersion = function() return "7.30/x64" end,
    GetResourcePath = function() return "C:/fake/res" end, GetExePath = function() return "C:/fake" end,
    EnumProjects = function(i) if i == 0 or i == -1 then return proj, F.path end end,
    ValidatePtr2 = function(_, x, kind)
      if kind == "MediaTrack*" then return x == master or index_of(x) ~= nil end
      if kind == "MediaItem*" then return type(x) == "table" and x.track ~= nil and index_of(x.track) ~= nil and (function() for _, y in ipairs(x.track.items) do if y == x then return true end end end)() == true end
      return true
    end,
    ValidatePtr = function() return true end,
    GetPlayStateEx = function() return F.playing end, GetPlayState = function() return F.playing end,
    GetProjectStateChangeCount = function() return F.cc end,
    GetProjectLength = function() return 600 end,
    GetCursorPositionEx = function() return 0 end, GetPlayPositionEx = function() return 0 end, GetPlayPosition2Ex = function() return 0 end,
    Master_GetPlayRate = function() return 1 end,
    GetSet_ArrangeView2 = function() return 0, 60 end,
    GetExtState = function(s, k) return gext[s .. "\0" .. k] or "" end,
    SetExtState = function(s, k, v) gext[s .. "\0" .. k] = v end,
    DeleteExtState = function(s, k) gext[s .. "\0" .. k] = nil end,
    HasExtState = function(s, k) return gext[s .. "\0" .. k] ~= nil end,
    GetProjExtState = function(_, s, k) local v = (pext[s] or {})[k] or ""; return v ~= "" and 1 or 0, v end,
    SetProjExtState = function(_, s, k, v) pext[s] = pext[s] or {}; pext[s][k] = v; return 1 end,
    EnumProjExtState = function(_, s, i)
      local keys = {}
      for k, v in pairs(pext[s] or {}) do if v ~= "" then keys[#keys + 1] = k end end
      table.sort(keys)
      local k = keys[i + 1]
      if k then return true, k, pext[s][k] end
      return false
    end,
    Undo_CanUndo2 = function() return F.undo end, Undo_CanRedo2 = function() return F.redo end,
    -- (F.undos, when a test sets it to a list: REAPER's undo points as they're made, newest last. A block's changes are one point, its name;
    -- ReorderSelectedTracks outside one makes REAPER's own "Change track order". rt-edits)
    Undo_BeginBlock2 = function() F.depth = (F.depth or 0) + 1 end,
    Undo_EndBlock2 = function(_, name) F.depth = math.max(0, (F.depth or 0) - 1); if F.undos and F.depth == 0 then F.undos[#F.undos + 1] = name end end,
    Undo_OnStateChangeEx2 = function(_, name) if F.undos and (F.depth or 0) == 0 then F.undos[#F.undos + 1] = name end end,
    Undo_BeginBlock = function() end, Undo_EndBlock = function() end,
    PreventUIRefresh = function() end, UpdateArrange = function() end, UpdateTimeline = function() end, TrackList_AdjustWindows = function() end,
    UpdateItemInProject = function() end,
    -- tracks
    CountTracks = function() return #tracks end,
    GetTrack = function(_, i) return tracks[i + 1] end,
    GetMasterTrack = function() return master end,
    GetParentTrack = function(t) return parent_of(t) end,
    GetTrackName = function(t) return true, t.is_master and "MASTER" or t.name end,
    GetTrackGUID = function(t) return t.guid end,
    InsertTrackInProject = function(_, idx) F.add_track("", idx + 1) end,
    InsertTrackAtIndex = function(idx) F.add_track("", idx + 1) end,
    DeleteTrack = function(t) local i = index_of(t); if i then table.remove(tracks, i); changed() end end,
    GetMediaTrackInfo_Value = function(t, k)
      local fld = TV[k]
      if fld then return t[fld] or 0 end
      if k == "IP_TRACKNUMBER" then return t.is_master and -1 or index_of(t) or 0 end
      if k == "I_NCHAN" then return 2 end
      local v = t.vals[k]
      if v == nil and (k == "B_SHOWINTCP" or k == "B_SHOWINMIXER" or k == "B_MAINSEND" or k == "I_FXEN") then return 1 end
      return v or 0
    end,
    SetMediaTrackInfo_Value = function(t, k, v)
      local fld = TV[k]
      if fld then t[fld] = v else t.vals[k] = v end
      changed()
      return true
    end,
    GetSetMediaTrackInfo_String = function(t, k, v, set)
      if k == "P_NAME" then if set then t.name = v; changed() end; return true, t.name or "" end
      if k == "GUID" then return true, t.guid end
      if k:sub(1, 6) == "P_EXT:" then
        local key = k:sub(7)
        if set then t.ext[key] = v ~= "" and v or nil; changed() end
        return true, t.ext[key] or ""
      end
      t.svals = t.svals or {}
      if set then t.svals[k] = v; changed() end
      return true, t.svals[k] or ""
    end,
    GetTrackStateChunk = function(t) return true, track_chunk(t) end,
    SetTrackStateChunk = function(t, c) set_track_chunk(t, c); changed(); return true end,
    GetTrackNumSends = function() return 0 end,
    GetTrackSendInfo_Value = function() return 0 end,
    TrackFX_GetCount = function() return 0 end, TrackFX_GetRecCount = function() return 0 end, TrackFX_GetInstrument = function() return -1 end,
    TakeFX_GetCount = function() return 0 end,
    CountTrackEnvelopes = function(t) return #envs_of(t) end,
    GetTrackEnvelope = function(t, i) return envs_of(t)[i + 1] end,
    GetTrackEnvelopeByChunkName = function(t, n) for _, e in ipairs(envs_of(t)) do if e.tag == n then return e end end end,
    CountEnvelopePoints = function(e) return e.pts end, CountEnvelopePointsEx = function(e) return e.pts end,
    GetEnvelopeStateChunk = function(e) return true, table.concat(e.text, "\n") .. "\n" end,
    Envelope_GetParentTrack = function(e) return e.tr end,
    CountAutomationItems = function() return 0 end,
    GetSelectedEnvelope = function() return nil end,
    GetLastTouchedTrack = function() return F.touched end,
    CountSelectedTracks = function() local n = 0; for _, t in ipairs(tracks) do if t.sel then n = n + 1 end end; return n end,
    GetSelectedTrack = function(_, i) local n = 0; for _, t in ipairs(tracks) do if t.sel then if n == i then return t end; n = n + 1 end end end,
    IsTrackSelected = function(t) return t.sel == true end,
    SetOnlyTrackSelected = function(t) for _, x in ipairs(tracks) do x.sel = nil end; t.sel = true end,
    SetTrackSelected = function(t, on) t.sel = on or nil end,
    ReorderSelectedTracks = function(before) -- (the selected tracks moved, in order, to just above the track at `before` (0-based), as REAPER does)
      local moving, rest, at = {}, {}, 0
      for i, t in ipairs(tracks) do
        if t.sel then moving[#moving + 1] = t else rest[#rest + 1] = t; if i - 1 < before then at = at + 1 end end
      end
      for i = #tracks, 1, -1 do tracks[i] = nil end
      for i, t in ipairs(rest) do if i == at + 1 then for _, m in ipairs(moving) do tracks[#tracks + 1] = m end end; tracks[#tracks + 1] = t end
      if at >= #rest then for _, m in ipairs(moving) do tracks[#tracks + 1] = m end end
      changed()
      if F.undos and (F.depth or 0) == 0 then F.undos[#F.undos + 1] = "Change track order" end
      return true
    end,
    GetSetTrackGroupMembership = function() return 0 end, GetSetTrackGroupMembershipHigh = function() return 0 end,
    GetTrackAutomationMode = function() return 0 end, GetGlobalAutomationOverride = function() return -1 end,
    -- items
    CountMediaItems = function() return #all_items() end,
    GetMediaItem = function(_, i) return all_items()[i + 1] end,
    CountTrackMediaItems = function(t) return #t.items end,
    GetTrackMediaItem = function(t, i) return t.items[i + 1] end,
    GetMediaItem_Track = function(it) return it.track end,
    GetItemProjectContext = function() return proj end,
    AddMediaItemToTrack = function(t) local it = new_item(t); t.items[#t.items + 1] = it; changed(); return it end,
    DeleteTrackMediaItem = function(t, it) for i, x in ipairs(t.items) do if x == it then table.remove(t.items, i); changed(); return true end end; return false end,
    MoveMediaItemToTrack = function(it, t)
      F.remove_item(it); it.track = t; t.items[#t.items + 1] = it; sort_items(t); changed(); return true
    end,
    GetMediaItemInfo_Value = function(it, k)
      if k == "D_POSITION" then return tonumber(top_value(it.text, "POSITION")) or 0 end
      if k == "D_LENGTH" then return tonumber(top_value(it.text, "LENGTH")) or 0 end
      if k == "B_MUTE" then return tonumber((top_value(it.text, "MUTE") or "0"):match("^(%S+)")) or 0 end
      if k == "D_VOL" then return tonumber((top_value(it.text, "VOLPAN") or "1"):match("^(%S+)")) or 1 end
      if k == "I_GROUPID" then return tonumber(top_value(it.text, "GROUP")) or 0 end
      if k == "B_UISEL" then return tonumber(top_value(it.text, "SEL")) or 0 end
      if k == "I_CURTAKE" then return cur_take(it) end
      if k == "I_FIXEDLANE" then return it.lane or 0 end
      if k == "I_CUSTOMCOLOR" then return tonumber((top_value(it.text, "COLOR") or "0"):match("^(%S+)")) or 0 end
      if k == "IP_ITEMNUMBER" then for i, x in ipairs(it.track.items) do if x == it then return i - 1 end end end
      return 0
    end,
    SetMediaItemInfo_Value = function(it, k, v)
      if k == "D_POSITION" then it.text = set_top(it.text, "POSITION", f(v)); sort_items(it.track)
      elseif k == "D_LENGTH" then it.text = set_top(it.text, "LENGTH", f(v))
      elseif k == "B_MUTE" then it.text = set_top(it.text, "MUTE", math.floor(v) .. " 0")
      elseif k == "I_GROUPID" then it.text = set_top(it.text, "GROUP", v ~= 0 and tostring(math.floor(v)) or nil)
      elseif k == "B_UISEL" then it.text = set_top(it.text, "SEL", tostring(math.floor(v)))
      elseif k == "I_FIXEDLANE" then it.lane = math.floor(v)
      elseif k == "I_CUSTOMCOLOR" then -- (as REAPER writes it: "COLOR n R" after MUTE, no line for 0. rt-nohold)
        local n = math.floor(v)
        if n ~= 0 and not top_value(it.text, "COLOR") and it.text:find("\n%s*MUTE ") then it.text = it.text:gsub("(\n%s*MUTE [^\n]*)", "%1\nCOLOR " .. n .. " R", 1)
        else it.text = set_top(it.text, "COLOR", n ~= 0 and (n .. " R") or nil) end
      elseif k == "I_CURTAKE" then
        local spans, L = takes_of(it.text)
        for i, s in ipairs(spans) do
          if s.first and L[s.first]:match("^%s*TAKE") then L[s.first] = (i - 1 == v and "TAKE SEL" or (s.null and "TAKE NULL" or "TAKE")) end
        end
        it.text = table.concat(L, "\n") .. "\n"
      end
      changed()
      return true
    end,
    GetSetMediaItemInfo_String = function(it, k, v, set)
      if k == "GUID" then return true, it.guid end
      if k:sub(1, 6) == "P_EXT:" then
        local key = k:sub(7)
        if set then it.ext[key] = v ~= "" and v or nil; changed() end
        return true, it.ext[key] or ""
      end
      return true, ""
    end,
    GetItemStateChunk = function(it) return true, item_chunk(it) end,
    SetItemStateChunk = function(it, c) take_in(it, c); changed(); return true end,
    IsMediaItemSelected = function(it) return top_value(it.text, "SEL") == "1" end,
    SetMediaItemSelected = function(it, on) it.text = set_top(it.text, "SEL", on and "1" or "0") end,
    CountSelectedMediaItems = function() local n = 0; for _, it in ipairs(all_items()) do if top_value(it.text, "SEL") == "1" then n = n + 1 end end; return n end,
    GetSelectedMediaItem = function(_, i) local n = 0; for _, it in ipairs(all_items()) do if top_value(it.text, "SEL") == "1" then if n == i then return it end; n = n + 1 end end end,
    CountTakes = function(it) return #takes_of(it.text) end,
    GetTake = function(it, k) return take(it, k) end,
    GetActiveTake = function(it) return take(it, cur_take(it)) end,
    GetMediaItemTake_Item = function(tk) return tk.item end,
    GetMediaItemTake_Track = function(tk) return tk.item.track end,
    TakeIsMIDI = function(tk) return take_text(tk):find("<SOURCE MIDI", 1, true) ~= nil end,
    GetTakeName = function(tk) return (take_text(tk):match('\nNAME "([^"]*)"') or take_text(tk):match('^NAME "([^"]*)"') or "") end,
    GetMediaItemTakeInfo_Value = function(tk, k) if k == "D_PLAYRATE" or k == "D_VOL" then return 1 end; return 0 end,
    GetSetMediaItemTakeInfo_String = function(tk, k, v, set)
      if k == "P_NAME" then return true, (take_text(tk):match('NAME "([^"]*)"') or "") end
      if k:sub(1, 6) == "P_EXT:" then local key = k:sub(7); if set then tk.ext[key] = v end; return true, tk.ext[key] or "" end
      return true, ""
    end,
    GetMediaItemTake_Source = function(tk) return tk end,
    GetMediaSourceFileName = function(src) return (take_text(src):match('FILE "([^"]*)"') or "") end,
    GetMediaSourceType = function(src) local t = take_text(src); return t:find("<SOURCE MIDI", 1, true) and "MIDI" or t:find("<SOURCE WAVE", 1, true) and "WAVE" or "EMPTY" end,
    GetMediaSourceParent = function() return nil end,
    GetMediaSourceLength = function() return 60, false end,
    MIDI_GetHash = function(tk) return true, tostring(#take_text(tk)) end,
    MIDIEditor_GetActive = function() return nil end,
    -- markers, regions and the render matrix
    CountProjectMarkers = function()
      local nm, nr = 0, 0
      for _, m in ipairs(markers) do if m.region then nr = nr + 1 else nm = nm + 1 end end
      return #markers, nm, nr
    end,
    EnumProjectMarkers3 = function(_, i)
      local m = markers[i + 1]
      if not m then return 0 end
      return i + 1, m.region, m.pos, m.rend, m.name, m.num, m.color
    end,
    GetNumRegionsOrMarkers = function() return 0 end, -- (no ruler lanes here: band.apply_markers' lane step ended in an error, after the markers. rt-nohold)
    EnumProjectMarkers2 = function(_, i) local m = markers[i + 1]; if not m then return 0 end; return i + 1, m.region, m.pos, m.rend, m.name, m.num end,
    EnumProjectMarkers = function(i) local m = markers[i + 1]; if not m then return 0 end; return i + 1, m.region, m.pos, m.rend, m.name, m.num end,
    AddProjectMarker2 = function(_, region, pos, rend, name, want, color) local m = F.add_marker(region, pos, rend, name, (want and want >= 0) and want or nil, color); return m.num end,
    AddProjectMarker = function(_, region, pos, rend, name, want) local m = F.add_marker(region, pos, rend, name, (want and want >= 0) and want or nil); return m.num end,
    SetProjectMarker4 = function(_, num, region, pos, rend, name, color)
      for _, m in ipairs(markers) do
        if m.num == num and m.region == region then
          m.pos, m.rend, m.name = pos, region and rend or pos, name
          if color and color ~= 0 then m.color = color end
          sort_markers(); changed(); return true
        end
      end
      return false
    end,
    SetProjectMarkerByIndex2 = function(_, idx, region, pos, rend, num, name, color)
      local m = markers[idx + 1]
      if not m then return false end
      m.region, m.pos, m.rend, m.num, m.name = region, pos, region and rend or pos, num >= 0 and num or m.num, name
      if color and color ~= 0 then m.color = color end
      sort_markers(); changed(); return true
    end,
    DeleteProjectMarker = function(_, num, region)
      for i, m in ipairs(markers) do if m.num == num and m.region == region then table.remove(markers, i); changed(); return true end end
      return false
    end,
    EnumRegionRenderMatrix = function(_, num, i) local l = matrix[num]; return l and l[i + 1] or nil end,
    SetRegionRenderMatrix = function(_, num, tr, add)
      local l = matrix[num] or {}
      matrix[num] = l
      for i, x in ipairs(l) do if x == tr then if add < 0 then table.remove(l, i); changed() end; return end end
      if add > 0 then l[#l + 1] = tr; changed() end
    end,
    -- the tempo map
    CountTempoTimeSigMarkers = function() return #tempo end,
    GetTempoTimeSigMarker = function(_, i)
      local p = tempo[i + 1]
      if not p then return false end
      return true, p[1], 0, 0, p[2], p[3], p[4], p[5]
    end,
    SetTempoTimeSigMarker = function(_, idx, t, _, _, bpm, num, den, lin)
      local p = { t, bpm, num > 0 and num or 4, den > 0 and den or 4, lin }
      F.tempo_edit(function()
        if idx >= 0 and tempo[idx + 1] then tempo[idx + 1] = p else tempo[#tempo + 1] = p end
        return p
      end)
      return true
    end,
    DeleteTempoTimeSigMarker = function(_, i)
      F.tempo_edit(function() local m = table.remove(tempo, i + 1); if #tempo == 0 and m then F.base_bpm = m[2] end; return m end)
      return true
    end,
    TimeMap_GetTimeSigAtTime = function() return tempo[1] and tempo[1][3] or 4, tempo[1] and tempo[1][4] or 4, tempo[1] and tempo[1][2] or F.base_bpm end,
    TimeMap2_timeToQN = function(_, t) return F.qn_of(t) end,
    TimeMap2_QNToTime = function(_, qn) return F.time_of(qn) end,
    TimeMap_QNToMeasures = function(_, qn) return math.floor(qn / 4) + 1 end,
    TimeMap_GetMeasureInfo = function(_, i) return i * 2, i * 4, (i + 1) * 4, 4, 4, tempo[1] and tempo[1][2] or 120 end,
    -- the transport's loop, time selection and repeat
    GetSet_LoopTimeRange2 = function(_, set, loop, s, e)
      local r = loop and F.loop or F.timesel
      if set then r[1], r[2] = s, e end
      return r[1], r[2]
    end,
    GetSet_LoopTimeRange = function(set, loop, s, e) local r = loop and F.loop or F.timesel; if set then r[1], r[2] = s, e end; return r[1], r[2] end,
    GetSetRepeatEx = function(_, v) if v >= 0 then F.repeat_on = v end; return F.repeat_on end,
    GetSetRepeat = function(v) if v >= 0 then F.repeat_on = v end; return F.repeat_on end,
    -- project info
    -- (PROJECT_TIMEBASE unset: as F.timebase, 1 = beats (position, length, rate), REAPER's default for a new project; 0 = time)
    GetSetProjectInfo = function(_, k, v, set)
      if set then info[k] = v; changed() end
      if k == "PROJECT_TIMEBASE" and info[k] == nil then return F.timebase == "beats" and 1 or 0 end
      return info[k] or 0
    end,
    GetSetProjectInfo_String = function(_, k, v, set) if set then info_s[k] = v; changed() end; return true, info_s[k] or "" end,
    GetSetProjectNotes = function(_, set, v) if set then info_s.notes = v end; return info_s.notes or "" end,
    GetSetProjectGrid = function() return 0, 0.25, 0, 0 end,
    ColorToNative = function(r, g, b) return r | (g << 8) | (b << 16) end,
    ColorFromNative = function(c) return c & 255, (c >> 8) & 255, (c >> 16) & 255 end,
    -- SWS's auto-colour switches (F.sws: command name -> on, for the ones SWS is "installed" with; F.sws_tick does what SWS's timer does)
    GetToggleCommandStateEx = function(_, id) local n = F.sws_ids[id]; return n and (F.sws[n] and 1 or 0) or 0 end,
    GetToggleCommandState = function(id) local n = F.sws_ids[id]; return n and (F.sws[n] and 1 or 0) or 0 end,
    NamedCommandLookup = function(name) if F.sws[name] ~= nil then for id, n in pairs(F.sws_ids) do if n == name then return id end end end; return 0 end,
    Main_OnCommand = function(id) local n = F.sws_ids[id]; if n then F.sws[n] = not F.sws[n] end end,
    file_exists = function() return true end,
    RecursiveCreateDirectory = function() return 1 end,
    JS_Mouse_GetState = function() return 0 end,
    format_timestr_pos = function(t) return string.format("%.3f", t) end,
    Track_GetPeakInfo = function() return 0 end,
    SetTrackMIDINoteNameEx = function() end,
  }
  local calls = F.calls
  local wrapped = {}
  for k, fn in pairs(R) do wrapped[k] = function(...) calls[k] = (calls[k] or 0) + 1; return fn(...) end end
  F.raw = R
  F.missing = {}
  F.reaper = setmetatable(wrapped, { __index = function(_, k)
    if tostring(k):find("^StudioSync_") or tostring(k):find("^JS_") or tostring(k):find("^CF_") or tostring(k):find("^BR_") or tostring(k):find("^SNM_") then return nil end
    F.missing[k] = true
    return function() end
  end })
  -- ---- the project as its file holds it (F.save), for opening again later as REAPER does after a restart without saving (E.open) ----
  local function deep(v)
    if type(v) ~= "table" then return v end
    local o = {}
    for k, x in pairs(v) do o[k] = deep(x) end
    return o
  end
  function F.save()
    local snap = { tracks = {}, markers = deep(markers), tempo = deep(tempo), base_bpm = F.base_bpm, pext = deep(pext), info = deep(info), info_s = deep(info_s),
      matrix = {}, loop = deep(F.loop), repeat_on = F.repeat_on }
    for i, t in ipairs(tracks) do
      local st = { guid = t.guid, name = t.name, color = t.color, vol = t.vol, pan = t.pan, mute = t.mute, depth = t.depth, vals = deep(t.vals), ext = deep(t.ext),
        svals = deep(t.svals), body = t.body, items = {} }
      for j, it in ipairs(t.items) do st.items[j] = { guid = it.guid, ext = deep(it.ext), lane = it.lane, text = it.text } end
      snap.tracks[i] = st
    end
    for num, l in pairs(matrix) do
      local g = {}
      for _, t in ipairs(l) do g[#g + 1] = t.is_master and "MASTER" or t.guid end
      snap.matrix[num] = g
    end
    return snap
  end
  function F.load(snap)
    for i = #tracks, 1, -1 do tracks[i] = nil end
    local by_guid = { MASTER = master }
    for i, st in ipairs(snap.tracks) do
      local t = { guid = st.guid, name = st.name, color = st.color, vol = st.vol, pan = st.pan, mute = st.mute, depth = st.depth, vals = deep(st.vals) or {}, ext = deep(st.ext) or {},
        svals = deep(st.svals), body = st.body or "", items = {} }
      for j, si in ipairs(st.items) do t.items[j] = { guid = si.guid, track = t, ext = deep(si.ext) or {}, lane = si.lane or 0, text = si.text, tk = {} } end
      tracks[i], by_guid[t.guid] = t, t
    end
    for i = #markers, 1, -1 do markers[i] = nil end
    for i, m in ipairs(snap.markers) do markers[i] = deep(m) end
    for i = #tempo, 1, -1 do tempo[i] = nil end
    for i, m in ipairs(snap.tempo) do tempo[i] = deep(m) end
    F.base_bpm = snap.base_bpm or 120
    for k in pairs(pext) do pext[k] = nil end
    for k, v in pairs(snap.pext) do pext[k] = deep(v) end
    for k in pairs(info) do info[k] = nil end
    for k, v in pairs(snap.info or {}) do info[k] = v end
    for k in pairs(info_s) do info_s[k] = nil end
    for k, v in pairs(snap.info_s or {}) do info_s[k] = v end
    for k in pairs(matrix) do matrix[k] = nil end
    for num, g in pairs(snap.matrix or {}) do
      matrix[num] = {}
      for _, id in ipairs(g) do if by_guid[id] then table.insert(matrix[num], by_guid[id]) end end
    end
    F.loop, F.repeat_on = deep(snap.loop) or { 0, 0 }, snap.repeat_on or 0
    changed()
  end
  return F
end
-- A project file opened in a REAPER just started: a new project pointer and master track, everything else as the file had it.
function E.open(path, snap)
  local F = E.new(path)
  F.load(snap)
  return F
end

return E
