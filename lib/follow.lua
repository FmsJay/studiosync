-- Follow a bandmate, live, and "Bo is editing this" before you touch it (docs/realtime-roadmap.md More big ideas 3 and 9). Both ride the
-- direct link's small messages (lib/direct.lua) from Live sync's tick, and cost an ExtState read a tick when nobody follows and nobody edits.
--   view     what you see, a few times a second, only while someone follows you (presence.followed, from their status): the arrange view, the
--            edit and play cursor, the selected tracks and items, and the open MIDI editor or plug-in window. The follower's view, cursors and
--            selection go there (their own selection back when they stop following); a scroll or zoom of theirs pauses it, with Resume on the
--            panel's Following and the web Play page. The status file's view and cursor stay the fallback (presence.follow) for a bandmate the
--            link doesn't reach.
--   editing  what you're editing right now: the item in the MIDI editor, the track or take whose plug-in window has focus (an editor counts
--            for IDLE s after you last changed something: opening it or moving its window isn't an edit), or what's selected while a change is
--            in progress (the project changed in the last CHANGED s, or the mouse is held down after pressing on the arrange or a track's
--            panel: a drag. A window moved or resized isn't one: James, findings 2026-11-27, rt-guard). Everyone shows "<name> is editing"
--            on it within ~100 ms: a
--            "[editing: <name>]" region over an item (any colour setting), the track tinted like an edit hold (lib/people.lua, Colour parity
--            off), a line on their card in the panel and on the web Project page. Shown only: it never reaches sync.authority or
--            presence.holder, so it blocks nobody; claims and edit holds do what they did. (James, rt)
local band = require("band")
local follow = {}
follow.EVERY = 0.2   -- seconds between view messages while someone follows you (5 a second)
follow.KEEP = 1      -- a view or editing message at least this often while it applies (a new follower, or a lost message, catches up)
follow.FRESH = 3     -- seconds a bandmate's last view or editing message counts
follow.LOOK = 0.1    -- seconds between looks at what you're editing
follow.HELD = 0.3    -- seconds the mouse is held before it counts as a drag of what's selected
follow.CHANGED = 2   -- seconds a change of yours keeps what's selected claimed
follow.IDLE = 120    -- seconds an open editor counts with no change of yours
follow.MAX = 16      -- tracks or items sent
follow.WORDS = 160   -- characters of words sent
follow.MARK = "[editing: " -- an editing region's name starts so (never the band's: band.is_local_mark)

-- ---- pure ------------------------------------------------------------------------------------------------------------------------------
local function r3(x) return math.floor((tonumber(x) or 0) * 1000 + 0.5) / 1000 end
local function list_of(t, max)
  if type(t) ~= "table" then return nil end
  local out = {}
  for i, v in ipairs(t) do
    if i > max or type(v) ~= "string" or #v > 80 then return nil end
    out[i] = v
  end
  return out
end
local function name_ok(u) return type(u) == "string" and #u > 0 and #u <= 64 end
local function words_of(w) return type(w) == "string" and w:sub(1, follow.WORDS) or "" end
-- A view message from the link (a trust boundary: anyone in the studio can send one). -> a clean copy, or nil.
function follow.clean_view(d, me)
  if type(d) ~= "table" or not name_ok(d.user) or d.user == me or type(d.v) ~= "table" then return nil end
  local a, z = tonumber(d.v[1]), tonumber(d.v[2])
  if not (a and z and z > a and a >= -1e6 and z <= 1e7) then return nil end
  local tr, it = list_of(d.tr or {}, follow.MAX), list_of(d.it or {}, follow.MAX)
  if not (tr and it) then return nil end
  return { user = d.user, v = { a, z }, c = tonumber(d.c), p = tonumber(d.p), tr = tr, it = it, w = words_of(d.w) }
end
-- An editing message: { user, o = { oids }, w = words }; o empty: they moved on. -> a clean copy, or nil.
function follow.clean_editing(d, me)
  if type(d) ~= "table" or not name_ok(d.user) or d.user == me then return nil end
  local o = list_of(d.o or {}, follow.MAX)
  return o and { user = d.user, o = o, w = words_of(d.w) } or nil
end
-- Did the view move from where following last left it? (a scroll or zoom of yours: 1% of the view's width, so REAPER's own rounding to a pixel
-- doesn't count). applied: { a, z } or nil.
function follow.moved(applied, a, z)
  if not applied then return false end
  local tol = math.max(1e-3, (applied[2] - applied[1]) * 0.01)
  return math.abs(a - applied[1]) > tol or math.abs(z - applied[2]) > tol
end
-- What you're editing, from what's looked at: s = { editor = { o, w } or nil, editor_age (s since it opened), changed_ago (s since your last
-- change), held (s the mouse has been down), items, tracks (selected oids) }. -> "editor" | "items" | "tracks", the oids; or nil.
function follow.claim_of(s)
  -- (not since it opened: a plug-in window opened and moved about read as "is editing" for two minutes. rt-guard)
  if s.editor and s.editor.o ~= "" and s.changed_ago < follow.IDLE then return "editor", { s.editor.o } end
  if s.changed_ago < follow.CHANGED or s.held >= follow.HELD then
    if #s.items > 0 then return "items", s.items end
    if #s.tracks > 0 then return "tracks", s.tracks end
  end
end
-- Does a press on this spot (GetThingFromPoint's words) start a drag of what's selected? The arrange view or a track's panel only: a window's
-- title bar or edge, a docker's splitter, another program's window aren't editing (JS_Mouse_GetState is the whole screen's). Pure. rt-guard
function follow.drag_spot(info)
  return type(info) == "string" and (info == "arrange" or info:match("^[tm]cp") ~= nil)
end
-- Is the mouse on such a spot now? (false where REAPER can't say: GetThingFromPoint is REAPER 6.24 on)
function follow.down_on_project()
  if not (reaper.GetMousePosition and reaper.GetThingFromPoint) then return false end
  local x, y = reaper.GetMousePosition()
  local _, info = reaper.GetThingFromPoint(x, y)
  return follow.drag_spot(info)
end
-- The editing regions wanted: edits = user -> { o }, span(oid) -> pos, len (nil: no such item here). -> sorted { "name|pos|end" }, and the
-- regions themselves { { user, pos, rend } }.
function follow.regions(edits, span)
  local keys, out = {}, {}
  local users = {}
  for u in pairs(edits) do users[#users + 1] = u end
  table.sort(users)
  for _, u in ipairs(users) do
    for _, o in ipairs(edits[u].o) do
      local pos, len = span(o)
      if pos then
        out[#out + 1] = { user = u, pos = pos, rend = pos + len }
        keys[#keys + 1] = string.format("%s%s]|%.6f|%.6f", follow.MARK, u, pos, pos + len)
      end
    end
  end
  table.sort(keys)
  return keys, out
end

-- ---- reading REAPER --------------------------------------------------------------------------------------------------------------------
local function tname(tr) return (select(2, reaper.GetTrackName(tr))) end
local function take_name(tk) return tk and select(2, reaper.GetSetMediaItemTakeInfo_String(tk, "P_NAME", "", false)) or "" end
-- The editor open here: the MIDI editor's item, else the plug-in window in focus (tab in front only: REAPER says which by track number).
-- -> { o = oid, w = words } or nil.
function follow.my_editor(proj)
  local mirror = require("mirror")
  local ed = reaper.MIDIEditor_GetActive and reaper.MIDIEditor_GetActive()
  local tk = ed and reaper.MIDIEditor_GetTake(ed)
  if tk and reaper.ValidatePtr2(proj, tk, "MediaItem_Take*") then
    return { o = mirror.item_oid(reaper.GetMediaItemTake_Item(tk)), w = "the MIDI of '" .. take_name(tk) .. "' on " .. tname(reaper.GetMediaItemTake_Track(tk)) }
  end
  if not reaper.GetFocusedFX2 or reaper.EnumProjects(-1) ~= proj then return nil end
  local rv, tn, itn, fx = reaper.GetFocusedFX2()
  if rv & 4 ~= 0 or tn < 1 then return nil end -- (no longer in focus, or the master's)
  local tr = reaper.GetTrack(proj, tn - 1)
  if not tr then return nil end
  if rv & 1 ~= 0 then return { o = mirror.track_oid(tr), w = "plug-in " .. select(2, reaper.TrackFX_GetFXName(tr, fx, "")) .. " on " .. tname(tr) } end
  local it = rv & 2 ~= 0 and itn >= 0 and reaper.GetTrackMediaItem(tr, itn)
  if it then return { o = mirror.item_oid(it), w = "the plug-ins of '" .. take_name(reaper.GetActiveTake(it)) .. "' on " .. tname(tr) } end
end
-- The selected tracks' and items' oids (the first MAX), and how many items are selected.
local function selection(proj)
  local mirror, tr, it = require("mirror"), {}, {}
  for i = 0, math.min(reaper.CountSelectedTracks(proj), follow.MAX) - 1 do
    local o = mirror.track_oid(reaper.GetSelectedTrack(proj, i))
    if o ~= "" then tr[#tr + 1] = o end
  end
  local n = reaper.CountSelectedMediaItems(proj)
  for i = 0, math.min(n, follow.MAX) - 1 do
    local o = mirror.item_oid(reaper.GetSelectedMediaItem(proj, i))
    if o ~= "" then it[#it + 1] = o end
  end
  return tr, it, n
end
-- Words for what's selected: "'Riff' on Bass", "3 items on Bass, Keys", "Bass, Keys".
local function sel_words(proj, kind)
  if kind == "items" then
    local n, first, tracks, seen = reaper.CountSelectedMediaItems(proj), nil, {}, {}
    for i = 0, math.min(n, follow.MAX) - 1 do
      local it = reaper.GetSelectedMediaItem(proj, i)
      first = first or it
      local t = tname(reaper.GetMediaItem_Track(it))
      if not seen[t] then seen[t] = true; tracks[#tracks + 1] = t end
    end
    if n == 1 then return "'" .. take_name(reaper.GetActiveTake(first)) .. "' on " .. tracks[1] end
    return n .. " items on " .. table.concat(tracks, ", ")
  end
  local names = {}
  for i = 0, math.min(reaper.CountSelectedTracks(proj), follow.MAX) - 1 do names[#names + 1] = tname(reaper.GetSelectedTrack(proj, i)) end
  return table.concat(names, ", ")
end

-- ---- state (one Live sync tab per script) ----------------------------------------------------------------------------------------------
local S = { views = {}, edits = {}, sent_at = -math.huge, sent_fp = "", look_at = -math.huge, ed_fp = "", ed_at = -math.huge,
  editor_fp = "", editor_at = 0, held_since = nil, sel_words_fp = nil, sel_words = "" }
follow.claims_seen = nil -- (sync.authority's claimed tracks from Live sync's last pass, for a repaint between passes)

-- What came over the link (Live sync's live_handlers).
function follow.on_view(cfg, d)
  local v = follow.clean_view(d, cfg.user)
  if v then S.views[v.user] = { d = v, at = reaper.time_precise() } end
end
function follow.on_editing(cfg, d)
  local c = follow.clean_editing(d, cfg.user)
  if not c then return end
  local had = S.edits[c.user]
  local was = had and (table.concat(had.o, " ") .. "|" .. had.w) or "|"
  S.edits[c.user] = #c.o > 0 and { o = c.o, w = c.w, at = reaper.time_precise() } or nil
  -- (a refresh of the same edit only keeps it fresh: no region or tint pass for it)
  if was ~= table.concat(c.o, " ") .. "|" .. (#c.o > 0 and c.w or "") then S.edits_changed = true end
end
-- Bandmates' live edits now: oid -> user (lib/people.lua paints them like edit holds).
function follow.live_editing()
  local out = {}
  for u, e in pairs(S.edits) do for _, o in ipairs(e.o) do out[o] = u end end
  return out
end
-- user -> words, for the web Project page (lib/dawview.lua).
function follow.words_by_user()
  local out = {}
  for u, e in pairs(S.edits) do out[u] = e.w ~= "" and e.w or "something" end
  return out
end
-- Who this tab follows: a name, the driver under Always follow the driver, or "".
function follow.target(proj, me)
  local name = reaper.GetExtState(band.SECTION, "follow " .. tostring(proj))
  local driver = require("sync").driver_name
  if name == "" and reaper.GetExtState(band.SECTION, "follow driver") ~= "" and driver ~= me then name = driver or "" end
  return name
end
-- Does the link carry following `name` here now (or is it paused)? Then the status file's view and cursor are left alone (presence.follow).
function follow.handles(proj, name)
  local v = S.views[name]
  return reaper.GetExtState(band.SECTION, "follow paused " .. tostring(proj)) == name or (v ~= nil and reaper.time_precise() - v.at < follow.FRESH)
end

local function set_ext(k, v) if reaper.GetExtState(band.SECTION, k) ~= v then reaper.SetExtState(band.SECTION, k, v, false) end end

-- Sending what you see, while someone follows you.
local function send_view(proj, cfg, b, now)
  if now - S.sent_at < follow.EVERY then return end
  local presence = require("presence")
  if not presence.followed(presence.peers(cfg, b.song, b.room), cfg.user, require("sync").driver_name) then S.sent_fp = ""; return end
  local tr, it, n = selection(proj)
  local a, z = reaper.GetSet_ArrangeView2(proj, false, 0, 0, 0, 0)
  local playing = reaper.GetPlayStateEx(proj) & 1 == 1
  local ed = follow.my_editor(proj)
  local sel_fp = table.concat(tr, " ") .. "|" .. table.concat(it, " ") .. "|" .. (ed and ed.w or "")
  if sel_fp ~= S.sel_words_fp then -- (words only when what's selected or open changed)
    local parts = {}
    if #tr > 0 then parts[#parts + 1] = sel_words(proj, "tracks") .. " selected" end
    if n > 0 then parts[#parts + 1] = n == 1 and sel_words(proj, "items") or (n .. " items") end
    if ed then parts[#parts + 1] = "editing " .. ed.w end
    S.sel_words_fp, S.sel_words = sel_fp, table.concat(parts, "; ")
  end
  local d = { user = cfg.user, v = { r3(a), r3(z) }, c = r3(reaper.GetCursorPositionEx(proj)), p = playing and r3(reaper.GetPlayPositionEx(proj)) or nil,
    tr = tr, it = it, w = S.sel_words }
  local fp = band.json_encode(d)
  if fp == S.sent_fp and now - S.sent_at < follow.KEEP then return end
  S.sent_at, S.sent_fp = now, fp
  require("direct").send_live(cfg, "view", d, b.song, b.room)
end

-- Sending what you're editing, as soon as it starts and until you move on.
local function send_editing(proj, cfg, b, now, changed_at)
  if now - S.look_at < follow.LOOK then return end
  S.look_at = now
  if #require("presence").peers(cfg, b.song, b.room) == 0 then return end
  local ed = follow.my_editor(proj)
  local efp = ed and ed.o or ""
  if efp ~= S.editor_fp then S.editor_fp, S.editor_at = efp, now end
  local down = reaper.JS_Mouse_GetState ~= nil and reaper.JS_Mouse_GetState(1) & 1 == 1
  if down and not S.held_since then S.held_on = follow.down_on_project() end -- (where it was pressed: a window moved isn't a drag. rt-guard)
  S.held_since = down and (S.held_since or now) or nil
  local changed_ago, held = now - (changed_at or -math.huge), S.held_since and S.held_on and now - S.held_since or 0
  local tr, it = {}, {}
  if changed_ago < follow.CHANGED or held >= follow.HELD then tr, it = selection(proj) end -- (only when it could count)
  local kind, oids = follow.claim_of({ editor = ed, editor_age = now - S.editor_at, changed_ago = changed_ago, held = held, items = it, tracks = tr })
  local fp = oids and table.concat(oids, " ") or ""
  if fp == S.ed_fp and (fp == "" or now - S.ed_at < follow.KEEP) then return end
  if fp ~= S.ed_fp then S.ed_words = kind == "editor" and ed.w or kind and sel_words(proj, kind) or "" end
  S.ed_fp, S.ed_at = fp, now
  require("direct").send_live(cfg, "editing", { user = cfg.user, o = oids or {}, w = S.ed_words }, b.song, b.room)
end

-- Showing bandmates' live edits: regions over their items, the tint, the panel's line.
local function show_editing(proj, cfg, b, now)
  for u, e in pairs(S.edits) do if now - e.at > follow.FRESH then S.edits[u] = nil; S.edits_changed = true end end
  if not S.edits_changed then return end
  S.edits_changed = false
  local mirror = require("mirror")
  local keys, regions = follow.regions(S.edits, function(o)
    local it = mirror.find(proj, "item", o)
    if it then return reaper.GetMediaItemInfo_Value(it, "D_POSITION"), reaper.GetMediaItemInfo_Value(it, "D_LENGTH") end
  end)
  local have = {}
  for i = 0, reaper.CountProjectMarkers(proj) - 1 do
    local _, rgn, p, e, name = reaper.EnumProjectMarkers3(proj, i)
    if rgn and name:sub(1, #follow.MARK) == follow.MARK then have[#have + 1] = string.format("%s|%.6f|%.6f", name, p, e) end
  end
  table.sort(have)
  if table.concat(keys, "\n") ~= table.concat(have, "\n") then
    for i = reaper.CountProjectMarkers(proj) - 1, 0, -1 do
      local _, rgn, _, _, name = reaper.EnumProjectMarkers3(proj, i)
      if rgn and name:sub(1, #follow.MARK) == follow.MARK then reaper.DeleteProjectMarkerByIndex(proj, i) end
    end
    local people = require("people")
    for _, r in ipairs(regions) do
      local rgb = people.colours(cfg.root, { r.user })[r.user] or 0xFFAA00
      reaper.AddProjectMarker2(proj, true, r.pos, r.rend, follow.MARK .. r.user .. "]", -1, reaper.ColorToNative(rgb >> 16, (rgb >> 8) & 0xFF, rgb & 0xFF) | 0x1000000)
    end
  end
  set_ext("live editing " .. tostring(proj), next(S.edits) and band.json_encode(follow.words_by_user()) or "")
  local people = require("people")
  if not people.parity(cfg) then people.paint(proj, cfg, require("presence").peers(cfg, b.song, b.room), follow.claims_seen, nil) end
  reaper.UpdateArrange()
end

-- Following: the view, cursors and selection go where the followed one's are.
local function restore(saved)
  if not saved then return end
  local proj = saved.proj
  for i = 0, reaper.CountTracks(proj) - 1 do reaper.SetTrackSelected(reaper.GetTrack(proj, i), false) end
  for _, tr in ipairs(saved.tracks) do if reaper.ValidatePtr2(proj, tr, "MediaTrack*") then reaper.SetTrackSelected(tr, true) end end
  reaper.SelectAllMediaItems(proj, false)
  for _, it in ipairs(saved.items) do if reaper.ValidatePtr2(proj, it, "MediaItem*") then reaper.SetMediaItemSelected(it, true) end end
end
local function apply_selection(proj, v)
  local mirror = require("mirror")
  if not S.saved then -- (yours, given back when you stop following)
    local saved = { proj = proj, tracks = {}, items = {} }
    for i = 0, reaper.CountSelectedTracks(proj) - 1 do saved.tracks[#saved.tracks + 1] = reaper.GetSelectedTrack(proj, i) end
    for i = 0, reaper.CountSelectedMediaItems(proj) - 1 do saved.items[#saved.items + 1] = reaper.GetSelectedMediaItem(proj, i) end
    S.saved = saved
  end
  local want = {}
  for _, o in ipairs(v.tr) do want[o] = true end
  for _, o in ipairs(v.it) do want[o] = true end
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    reaper.SetTrackSelected(tr, want[mirror.track_oid(tr)] == true)
  end
  for i = 0, reaper.CountMediaItems(proj) - 1 do
    local it = reaper.GetMediaItem(proj, i)
    reaper.SetMediaItemSelected(it, want[mirror.item_oid(it)] == true)
  end
  if #v.tr > 0 then reaper.Main_OnCommandEx(40913, 0, proj) end -- Track: Vertical scroll selected tracks into view (their tracks, as near as the view allows)
end
local function apply_follow(proj, cfg, now)
  local key = tostring(proj)
  local name = follow.target(proj, cfg.user)
  local paused = reaper.GetExtState(band.SECTION, "follow paused " .. key)
  if name ~= S.following then -- (started, stopped or someone else)
    if name == "" then restore(S.saved); S.saved = nil end
    S.following, S.applied, S.sel_fp, S.cur_seen = name, nil, nil, nil
    if paused ~= "" and paused ~= name then reaper.DeleteExtState(band.SECTION, "follow paused " .. key, false); paused = "" end
  end
  if name == "" then set_ext("follow seen " .. key, ""); return end
  local v = S.views[name]
  if not v or now - v.at > follow.FRESH then set_ext("follow seen " .. key, ""); return end
  v = v.d
  set_ext("follow seen " .. key, (paused == name and "Paused: " or "") .. name .. (v.w ~= "" and (": " .. v.w) or ""))
  if paused == name then S.was_paused = true; return end
  if S.was_paused then S.was_paused, S.applied, S.sel_fp, S.cur_seen = false, nil, nil, nil end -- (resumed: catch up at once)
  if reaper.EnumProjects(-1) ~= proj then S.applied = nil; return end -- (only the tab in front has a view to move)
  local stopped = reaper.GetPlayStateEx(proj) & 1 == 0
  local a, z = reaper.GetSet_ArrangeView2(proj, false, 0, 0, 0, 0)
  -- shortcut: a scroll or zoom of yours is told only while you're stopped (playing, REAPER's own scrolling moves the view too); upgrade with
  -- the extension's mouse/wheel hook if people miss it
  if stopped and follow.moved(S.applied, a, z) then
    reaper.SetExtState(band.SECTION, "follow paused " .. key, name, false)
    set_ext("follow seen " .. key, "Paused: " .. name .. (v.w ~= "" and (": " .. v.w) or ""))
    band.log("you scrolled or zoomed, so following " .. name .. " is paused: Resume on the panel (Following) or the web Play page")
    return
  end
  if follow.moved({ a, z }, v.v[1], v.v[2]) then
    reaper.GetSet_ArrangeView2(proj, true, 0, 0, v.v[1], v.v[2])
    a, z = reaper.GetSet_ArrangeView2(proj, false, 0, 0, 0, 0)
  end
  S.applied = { a, z }
  -- the edit cursor goes where theirs is; while they play and you don't, to their play cursor
  local c = v.p and stopped and v.p or (not v.p and v.c) or nil
  if c and c ~= S.cur_seen then S.cur_seen = c; reaper.SetEditCurPos2(proj, c, false, false) end
  local sfp = table.concat(v.tr, " ") .. "|" .. table.concat(v.it, " ")
  if sfp ~= S.sel_fp then S.sel_fp = sfp; apply_selection(proj, v) end
  reaper.UpdateArrange()
end

-- Live sync's tick (within it, so what this changes counts as StudioSync's, not you editing). changed_at: when you last changed the project.
function follow.tick(proj, cfg, b, changed_at)
  local now = reaper.time_precise()
  apply_follow(proj, cfg, now)
  show_editing(proj, cfg, b, now)
  if not require("direct").live_available() then return end
  send_view(proj, cfg, b, now)
  send_editing(proj, cfg, b, now, changed_at)
end
S.edits_changed = true -- (the first tick sweeps editing regions a crash left behind)

-- ---- the panel (another script: what Live sync published) ------------------------------------------------------------------------------
local panel_cache = { raw = nil, map = {} }
-- -> what `user` is editing now (words) or nil; what you see of them while you follow them (words) or nil.
function follow.panel_lines(proj, user)
  local raw = reaper.GetExtState(band.SECTION, "live editing " .. tostring(proj))
  if raw ~= panel_cache.raw then panel_cache.raw, panel_cache.map = raw, raw ~= "" and band.json_decode(raw) or {} end
  local ed = type(panel_cache.map) == "table" and panel_cache.map[user] or nil
  local seen = reaper.GetExtState(band.SECTION, "follow seen " .. tostring(proj))
  local mine = seen:match("^Paused: (.*)$") or seen
  return type(ed) == "string" and ed or nil, (mine:sub(1, #user + 1) == user .. ":" or mine == user) and seen or nil
end

return follow
