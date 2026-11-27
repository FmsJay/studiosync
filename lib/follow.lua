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
-- One Follow (rt-follow, findings 2026-11-27 items 5 and 12): you follow a PERSON (their active computer, or one you pick), which means their
-- transport (lib/together.lua and Live sync's follow cues: play, pause, stop, jumps, skip, pre-roll; Record records with them on your armed
-- tracks) and their view (here: horizontal and vertical zoom and scroll, edit cursor, selection, the MIDI editor they have open). "Everyone"
-- (the project's "side") follows whoever plays. The UI says Following only once it is: their view arrived, naming you, and your transport has
-- been put where theirs is (follow.state). Stored in the old keys ("follow <proj>" = the computer followed, "follow driver", "side"), so older
-- computers read it as before; "follow person <proj>" and "follow pinned <proj>" are new and only this file reads them.
local band = require("band")
local follow = {}
follow.EVERY = 0.1   -- seconds between view messages while someone follows you (on a change; 10 a second at most)
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
  local out = { user = d.user, v = { a, z }, c = tonumber(d.c), p = tonumber(d.p), tr = tr, it = it, w = words_of(d.w) }
  -- (rt-follow: vertical zoom, the top track and how far it's scrolled past, the MIDI editor's item, the play state, the shared clock, and who
  -- the sender knows follows it. Each optional: an older StudioSync sends none of them)
  local vz, ps, sn = tonumber(d.vz), math.tointeger(tonumber(d.ps)), tonumber(d.sn)
  if vz and vz >= 0 and vz <= 1000 then out.vz = vz end
  if type(d.top) == "table" and type(d.top[1]) == "string" and #d.top[1] <= 80 and tonumber(d.top[2]) and math.abs(d.top[2]) < 1e5 then out.top = { d.top[1], tonumber(d.top[2]) } end
  if type(d.ed) == "string" and #d.ed > 0 and #d.ed <= 80 then out.ed = d.ed end
  if ps and ps >= 0 and ps <= 7 then out.ps = ps end
  if sn and sn > 0 and sn < 1e11 then out.sn = sn end
  if type(d.fw) == "table" then
    local fw = {}
    for i, u in ipairs(d.fw) do if i <= follow.MAX and name_ok(u) then fw[#fw + 1] = u end end
    out.fw = fw
  end
  return out
end
-- Who follows (or watches, from a web page) `me`: names, sorted. st.follow (a name), st.follow_driver while I drive, st.watch (a web page's
-- Project view watching me: lib/dawview.lua). Pure.
function follow.followers(peers, me, driver)
  local out = {}
  for _, st in ipairs(peers or {}) do
    if type(st) == "table" and name_ok(st.user) and st.user ~= me
      and (st.follow == me or st.watch == me or (st.follow_driver and driver == me)) then out[#out + 1] = st.user end
  end
  table.sort(out)
  return out
end
-- Whose person a computer's name is, and the person's name: rt-people's lib/persons.lua (two computers are one person only when both say so,
-- each in its own devices file); without it each computer is its own person. -> fold(user) -> key, name.
local persons_mod
function follow.fold(cfg)
  if persons_mod == nil then
    local ok, m = pcall(require, "persons")
    persons_mod = ok and type(m) == "table" and type(m.map) == "function" and m or false
  end
  local okm, map = false, nil
  if persons_mod and cfg and cfg.root then okm, map = pcall(persons_mod.map, cfg.root) end
  map = okm and type(map) == "table" and map or {}
  return function(u)
    local m = map[u]
    if type(m) == "table" and name_ok(m.key) then return m.key, name_ok(m.name) and m.name or m.key end
    return u, u
  end
end
-- The computer to follow of a person's: the one you're on while it still plays or records, or nothing else of theirs does; else one recording,
-- playing, with the project in front, latest active, first by name. sts: that person's statuses. Pure.
function follow.active(sts, current)
  local cur
  for _, st in ipairs(sts) do if st.user == current then cur = st end end
  local function busy(st) return st.recording or st.playing end
  local other_busy = false
  for _, st in ipairs(sts) do if st ~= cur and busy(st) then other_busy = true end end
  if cur and (busy(cur) or not other_busy) then return cur.user end
  local best, rank
  for _, st in ipairs(sts) do
    local r = { st.recording and 1 or 0, st.playing and 1 or 0, st.front and 1 or 0, tonumber(st.last_at) or 0 }
    local better = not best
    if best then
      for i = 1, 4 do if r[i] ~= rank[i] then better = r[i] > rank[i]; break end end
      if r[1] == rank[1] and r[2] == rank[2] and r[3] == rank[3] and r[4] == rank[4] then better = st.user < best end
    end
    if better then best, rank = st.user, r end
  end
  return best
end
-- The people here to follow, a person's computers folded: { { key, label, users = { sorted }, active } }, by label. peers: statuses (not
-- you); fold: follow.fold's (nil: each computer its own person). Pure.
function follow.people(peers, me, current, fold)
  local by, list = {}, {}
  for _, st in ipairs(peers or {}) do
    if type(st) == "table" and name_ok(st.user) and st.user ~= me then
      local k, label = st.user, st.user
      if fold then k, label = fold(st.user) end
      if not by[k] then by[k] = { key = k, label = label, users = {}, sts = {} }; list[#list + 1] = by[k] end
      by[k].users[#by[k].users + 1] = st.user
      by[k].sts[#by[k].sts + 1] = st
    end
  end
  for _, p in ipairs(list) do table.sort(p.users); p.active = follow.active(p.sts, current); p.sts = nil end
  table.sort(list, function(a, z) return a.label:lower() < z.label:lower() end)
  return list
end
-- What following is now, said only as it really is (findings 2026-11-27 bug: "said following but wasn't actually following for a bit": the
-- panel showed Following the moment it was clicked, while the leader didn't know yet, so their presses didn't come; and nothing put your
-- transport where theirs already was). t: { name (followed computer, "" none), paused, view (their fresh link view, or nil), me, synced
-- (your transport was put where theirs is), slow (no link view, but their status shows its view: the shared folder's follow) }.
-- -> "off" | "waiting" | "live" | "paused" | "slow". Pure.
function follow.state(t)
  if (t.name or "") == "" then return "off" end
  if t.paused then return "paused" end
  local v = t.view
  if v then
    local knows = v.fw == nil -- (an older StudioSync doesn't say who it knows follows it: its view arriving at all is the sign)
    for _, u in ipairs(v.fw or {}) do knows = knows or u == t.me end
    return (knows and t.synced) and "live" or "waiting"
  end
  return t.slow and "slow" or "waiting"
end
-- The first sync: their transport as their view says, against yours. -> a cue to fire here ({ type = "start" | "stop", ... } as Live sync's
-- follow cues are), or nil when nothing needs doing. Never into a take of yours. me = { playing, recording }. Pure.
function follow.first_cue(v, me, lead, now)
  local playing = v.ps and v.ps & 1 == 1 or (v.ps == nil and v.p ~= nil)
  if me.recording then return nil end
  if playing and v.p and not me.playing then
    -- (a take of theirs already going: you play along; recording together starts with their next Record)
    return { type = "start", follow = true, lead = lead, user = lead, pos = v.p, countin = 0, at = now, start_at = v.sn, id = "follow-sync-" .. lead .. "-" .. string.format("%.3f", now) }
  end
  if not playing and me.playing then -- (no position: a stop now; your edit cursor goes to theirs with the view)
    return { type = "stop", follow = true, lead = lead, user = lead, at = now, id = "follow-sync-" .. lead .. "-" .. string.format("%.3f", now) }
  end
end
-- Did YOU move the view (pause following)? Stopped: a scroll or zoom past 1% (follow.moved). Playing, REAPER's own scrolling moves it too, so
-- only a zoom counts (the width changed). Vertical: your scroll away from where following put it (REAPER never scrolls it by itself). Pure.
function follow.user_moved(applied, a, z, playing, vapplied, vnow)
  if vapplied and vnow and math.abs(vnow - vapplied) > 2 then return true end
  if not playing then return follow.moved(applied, a, z) end
  if not applied then return false end
  local w0, w = applied[2] - applied[1], z - a
  return math.abs(w - w0) > math.max(1e-3, w0 * 0.01)
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
    return { o = mirror.item_oid(reaper.GetMediaItemTake_Item(tk)), w = "the MIDI of '" .. take_name(tk) .. "' on " .. tname(reaper.GetMediaItemTake_Track(tk)), midi = true }
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
-- What a fresh link view of `user` says, for the web Project page (lib/dawview.lua), or nil.
function follow.live_view(user)
  local v = S.views[user]
  return v and reaper.time_precise() - v.at < follow.FRESH and v.d or nil
end

-- Vertical: REAPER's vertical zoom (vzoom2, through SWS) and the arrange view's scrollbar (js_ReaScriptAPI: the arrange is the main window's
-- child 1000). Both optional: without them only the horizontal view, cursors, selection and MIDI editor follow.
local function arrange_hwnd() return reaper.JS_Window_FindChildByID and reaper.JS_Window_FindChildByID(reaper.GetMainHwnd(), 1000) or nil end
local function vscroll()
  local h = arrange_hwnd()
  if not h then return nil end
  local ok, pos = reaper.JS_Window_GetScrollInfo(h, "v")
  return ok and pos or nil
end
local function vzoom() return reaper.SNM_GetIntConfigVar and reaper.SNM_GetIntConfigVar("vzoom2", -1) or -1 end
-- The top track in view and its top edge (px from the arrange's top, 0 or less: scrolled past that much). -> oid, y; or nil.
local function top_track(proj)
  local mirror = require("mirror")
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    local y, h = reaper.GetMediaTrackInfo_Value(tr, "I_TCPY"), reaper.GetMediaTrackInfo_Value(tr, "I_TCPH")
    if h > 0 and y + h > 0 then
      local o = mirror.track_oid(tr)
      if o ~= "" then return o, y end
    end
  end
end
local function apply_vertical(proj, v)
  if v.vz and reaper.SNM_SetIntConfigVar and vzoom() ~= math.floor(v.vz) then
    reaper.SNM_SetIntConfigVar("vzoom2", math.floor(v.vz))
    reaper.TrackList_AdjustWindows(true)
  end
  local h = v.top and arrange_hwnd()
  local tr = h and require("mirror").find(proj, "track", v.top[1])
  if tr then
    local diff = math.floor(reaper.GetMediaTrackInfo_Value(tr, "I_TCPY") - v.top[2] + 0.5)
    local ok, pos = reaper.JS_Window_GetScrollInfo(h, "v")
    if ok and math.abs(diff) > 2 then reaper.JS_Window_SetScrollPos(h, "v", pos + diff) end
  end
  return vscroll()
end

-- Sending what you see, while someone follows you (or a web page's Project view watches you).
local function send_view(proj, cfg, b, now)
  if now - S.sent_at < follow.EVERY then return end
  local fw = follow.followers(require("presence").peers(cfg, b.song, b.room), cfg.user, require("sync").driver_name)
  if #fw == 0 then S.sent_fp = ""; return end
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
  local ps = reaper.GetPlayStateEx(proj)
  local d = { user = cfg.user, v = { r3(a), r3(z) }, c = r3(reaper.GetCursorPositionEx(proj)), p = playing and r3(reaper.GetPlayPositionEx(proj)) or nil,
    tr = tr, it = it, w = S.sel_words, ps = ps & 7, fw = fw, ed = ed and ed.midi and ed.o or nil }
  local vz = vzoom()
  if vz >= 0 then d.vz = vz end
  local to, ty = top_track(proj)
  if to then d.top = { to, math.floor(ty) } end
  local fp = band.json_encode(d)
  if fp == S.sent_fp and now - S.sent_at < follow.KEEP then return end
  S.sent_at, S.sent_fp = now, fp
  local ok, sn = pcall(function() return require("direct").shared_now() end) -- (when p was read, on the studio's shared clock: the first sync)
  d.sn = ok and sn or nil
  require("direct").send_live(cfg, "view", d, b.song, b.room)
end

-- Sending what you're editing, as soon as it starts and until you move on.
local function send_editing(proj, cfg, b, now, changed_at)
  if now - S.look_at < follow.LOOK then return end
  S.look_at = now
  if #require("presence").peers(cfg, b.song, b.room) == 0 then return end
  local ed = follow.my_editor(proj)
  if ed and ed.o == S.opened_ed then ed = nil end -- (a MIDI editor following opened shows their editing, not yours)
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
  -- Track: Vertical scroll selected tracks into view (their tracks, as near as the view allows): only from an older StudioSync, whose view
  -- doesn't say where it's scrolled (apply_vertical puts it exactly where theirs is)
  if #v.tr > 0 and not v.top then reaper.Main_OnCommandEx(40913, 0, proj) end
end
-- The MIDI editor: the item theirs shows, opened here (and closed again when they close theirs or you stop following, if following opened it).
local function close_editor()
  if not S.opened_ed then return end
  local ed = reaper.MIDIEditor_GetActive and reaper.MIDIEditor_GetActive()
  local tk = ed and reaper.MIDIEditor_GetTake(ed)
  if tk and require("mirror").item_oid(reaper.GetMediaItemTake_Item(tk)) == S.opened_ed then reaper.MIDIEditor_OnCommand(ed, 2) end -- File: Close window
  S.opened_ed = nil
end
local function follow_editor(proj, v)
  if v.ed == S.ed_seen then return end
  S.ed_seen = v.ed
  close_editor()
  if not v.ed then return end
  local mine = follow.my_editor(proj)
  if mine and mine.o == v.ed then return end -- (open here already: yours)
  local it = require("mirror").find(proj, "item", v.ed)
  if not it then return end
  reaper.SelectAllMediaItems(proj, false)
  reaper.SetMediaItemSelected(it, true)
  reaper.Main_OnCommandEx(40153, 0, proj) -- Item: Open in built-in MIDI editor (the selected item: theirs alone for it)
  S.opened_ed, S.sel_fp = v.ed, nil -- (their selection again next look)
end
-- Following a person: "follow <proj>" goes to their active computer (follow.active), unless you picked one ("follow pinned <proj>"). A follow
-- set by an older StudioSync (a computer's name alone) becomes that person's, pinned to that computer, so it stays exactly as it was.
local function resolve(proj, cfg, peers)
  local key = tostring(proj)
  local cur = reaper.GetExtState(band.SECTION, "follow " .. key)
  local person = reaper.GetExtState(band.SECTION, "follow person " .. key)
  if cur == "" then
    if person ~= "" then reaper.DeleteExtState(band.SECTION, "follow person " .. key, false); reaper.DeleteExtState(band.SECTION, "follow pinned " .. key, false) end
    return
  end
  if person == "" then
    reaper.SetExtState(band.SECTION, "follow person " .. key, (follow.fold(cfg)(cur)), false)
    reaper.SetExtState(band.SECTION, "follow pinned " .. key, cur, false)
    return
  end
  if reaper.GetExtState(band.SECTION, "follow pinned " .. key) ~= "" then return end
  for _, p in ipairs(follow.people(peers, cfg.user, cur, follow.fold(cfg))) do
    if p.key == person then
      if p.active and p.active ~= cur then
        reaper.SetExtState(band.SECTION, "follow " .. key, p.active, false)
        band.log("following " .. person .. " on " .. p.active .. " now: the computer of theirs that's active")
      end
      return
    end
  end
end
local function knows_me(v, me)
  if v.fw == nil then return true end
  for _, u in ipairs(v.fw) do if u == me then return true end end
  return false
end
local function apply_follow(proj, cfg, b, now)
  local key = tostring(proj)
  local peers = require("presence").peers(cfg, b.song, b.room)
  resolve(proj, cfg, peers)
  local name = follow.target(proj, cfg.user)
  local paused = reaper.GetExtState(band.SECTION, "follow paused " .. key)
  if name ~= S.following then -- (started, stopped or someone else)
    if name == "" then restore(S.saved); S.saved = nil end
    close_editor()
    S.following, S.applied, S.vapplied, S.sel_fp, S.cur_seen, S.synced, S.ed_seen = name, nil, nil, nil, nil, nil, nil
    if paused ~= "" and paused ~= name then reaper.DeleteExtState(band.SECTION, "follow paused " .. key, false); paused = "" end
  end
  local vv = name ~= "" and S.views[name] or nil
  local v = vv and now - vv.at <= follow.FRESH and vv.d or nil
  if not v then S.synced = nil end -- (their link view went quiet: synced again when it's back)
  local is_paused = name ~= "" and paused == name
  if is_paused then S.was_paused = true
  elseif S.was_paused then S.was_paused, S.applied, S.vapplied, S.sel_fp, S.cur_seen, S.synced, S.ed_seen = false, nil, nil, nil, nil, nil, nil end -- (resumed: catch up at once)
  -- the first sync: your transport where theirs is, once they know you follow them (then their presses come as cues)
  if v and not S.synced and not is_paused and knows_me(v, cfg.user) then
    local ps = reaper.GetPlayStateEx(proj)
    local cue = follow.first_cue(v, { playing = ps & 1 == 1, recording = ps & 4 == 4 }, name, require("together").now() - (now - vv.at))
    if cue then
      band.set_ext_json(band.SECTION, "transport " .. key, cue, false) -- (Live sync takes it as it takes their own follow cues)
      band.log(cue.type == "start" and string.format("following %s: they're playing, so you play from where they are (%.2f s)", name, cue.pos)
        or "following " .. name .. ": they've stopped, so you stop too")
    end
    S.synced = true
  end
  local slow = false
  if name ~= "" and not v then for _, st in ipairs(peers) do slow = slow or (st.user == name and type(st.view) == "table") end end
  local state = follow.state({ name = name, paused = is_paused, view = v, me = cfg.user, synced = S.synced, slow = slow })
  set_ext("follow state " .. key, state == "off" and "" or state)
  local words = v and v.w ~= "" and (": " .. v.w) or ""
  set_ext("follow seen " .. key, state == "off" and "" or state == "waiting" and ("Connecting to " .. name .. "...")
    or state == "slow" and (name .. " (slow: over the shared folder, a few seconds behind)") or ((is_paused and "Paused: " or "") .. name .. words))
  if not v or is_paused then return end
  if reaper.EnumProjects(-1) ~= proj then S.applied, S.vapplied = nil, nil; return end -- (only the tab in front has a view to move)
  local playing = reaper.GetPlayStateEx(proj) & 1 == 1
  local a, z = reaper.GetSet_ArrangeView2(proj, false, 0, 0, 0, 0)
  if follow.user_moved(S.applied, a, z, playing, S.vapplied, vscroll()) then
    reaper.SetExtState(band.SECTION, "follow paused " .. key, name, false)
    set_ext("follow seen " .. key, "Paused: " .. name .. words)
    set_ext("follow state " .. key, "paused")
    band.log("you scrolled or zoomed, so following " .. name .. "'s view is paused (their play and stop still come): Resume on the Play page or their Following button")
    return
  end
  if follow.moved({ a, z }, v.v[1], v.v[2]) then
    reaper.GetSet_ArrangeView2(proj, true, 0, 0, v.v[1], v.v[2])
    a, z = reaper.GetSet_ArrangeView2(proj, false, 0, 0, 0, 0)
  end
  S.applied = { a, z }
  -- the edit cursor goes where theirs is; while they play and you don't, to their play cursor
  local c = v.p and not playing and v.p or (not v.p and v.c) or nil
  if c and c ~= S.cur_seen then S.cur_seen = c; reaper.SetEditCurPos2(proj, c, false, false) end
  follow_editor(proj, v)
  local sfp = table.concat(v.tr, " ") .. "|" .. table.concat(v.it, " ")
  if sfp ~= S.sel_fp then S.sel_fp = sfp; apply_selection(proj, v) end
  S.vapplied = apply_vertical(proj, v)
  reaper.UpdateArrange()
end

-- ---- the one Follow choice (the panel's Play page and Follow buttons, the web Play page) ------------------------------------------------
-- The choice now: "" nobody, "*" everyone (the project's "side"), "@driver", or a person's key; and the computer followed.
function follow.choice_of(proj)
  local key = tostring(proj)
  local name = reaper.GetExtState(band.SECTION, "follow " .. key)
  if name ~= "" then
    local person = reaper.GetExtState(band.SECTION, "follow person " .. key)
    return person ~= "" and person or name, name
  end
  if reaper.GetExtState(band.SECTION, "follow driver") ~= "" then return "@driver", "" end
  if select(2, reaper.GetProjExtState(proj, band.SECTION, "side")) ~= "" then return "*", "" end
  return "", ""
end
-- Pick: "" nobody, "*" everyone (whoever plays, `bars` behind), "@driver", a person's key (their active computer; `user`: one of theirs
-- pinned), or a computer's name (the older Follow buttons and pages: that person's, pinned to it). -> words for the log, or nil and why not.
-- Real time, Jam, Time-sync and In time set "side" themselves: picking a person or nobody leaves theirs as it is.
function follow.set_choice(proj, cfg, peers, choice, user, bars)
  local key = tostring(proj)
  local function px(k) return select(2, reaper.GetProjExtState(proj, band.SECTION, k)) end
  local managed = require("live").realtime_on(proj) or px("side before timesync") ~= "" or px("side before jam") ~= "" or px("side before their") ~= ""
  local function clear()
    for _, k in ipairs({ "follow ", "follow person ", "follow pinned ", "follow paused " }) do reaper.DeleteExtState(band.SECTION, k .. key, false) end
    reaper.SetExtState(band.SECTION, "follow driver", "", true)
    if not managed then reaper.SetProjExtState(proj, band.SECTION, "side", "") end
  end
  if choice == "*" then
    if managed then return nil, "Real time, Jam or Time-sync is on: you already follow whoever plays" end
    local n = math.max(0, math.min(16, math.floor(tonumber(bars) or tonumber(px("side")) or 2)))
    clear()
    reaper.SetProjExtState(proj, band.SECTION, "side", tostring(n))
    return "following everyone: whoever plays, " .. n .. " bar" .. (n == 1 and "" or "s") .. " behind"
  end
  if choice == "@driver" then clear(); reaper.SetExtState(band.SECTION, "follow driver", "1", true); return "following the driver" end
  if choice == nil or choice == "" then clear(); return "following nobody" end
  if not name_ok(choice) or choice == cfg.user then return nil, "nobody called that is here" end
  for _, p in ipairs(follow.people(peers, cfg.user, reaper.GetExtState(band.SECTION, "follow " .. key), follow.fold(cfg))) do
    local pin -- (the person's key is also a computer's name: as the person, their active one, unless `user` picks one)
    for _, u in ipairs(p.users) do if u == user or (u == choice and p.key ~= choice) then pin = u end end
    if p.key == choice or pin then
      clear()
      reaper.SetExtState(band.SECTION, "follow person " .. key, p.key, false)
      if pin then reaper.SetExtState(band.SECTION, "follow pinned " .. key, pin, false) end
      reaper.SetExtState(band.SECTION, "follow " .. key, pin or p.active, false)
      return "following " .. p.key .. " (" .. (pin and ("on " .. pin) or ("their active computer, " .. p.active)) .. ")"
    end
  end
  return nil, "nobody called that is here"
end
-- Record when the one you follow records (on your armed tracks): on unless "follow no rec" (this computer's, kept) says to play along.
function follow.records_along() return reaper.GetExtState(band.SECTION, "follow no rec") == "" end
-- The line the panel's and the web Play page show: following only once it is. t: { choice, state (follow state), seen (follow seen), computer
-- (the one followed), multi (that person has more than one here), label (the person's name), rt (Real time mode), bars (side) }. Pure.
function follow.words(t)
  local c = t.choice or ""
  if c == "" then return "Following nobody: your play, stop and view are your own." end
  if c == "*" then
    if t.rt then return "Real time mode is on (Home): everyone follows whoever plays, at the same spot." end
    local n = tonumber(t.bars) or 0
    return "Following everyone: whoever presses play, stop or record, you follow, " .. (n == 0 and "right along." or (n .. (n == 1 and " bar" or " bars") .. " behind."))
  end
  local who = t.label or c
  local name = c == "@driver" and ("the driver" .. ((t.computer or "") ~= "" and (" (" .. t.computer .. ")") or "")) or (t.multi and (who .. " on " .. tostring(t.computer)) or who)
  local what = (t.seen or ""):match("^[^:]*(: .*)$") or ""
  if t.state == "live" then return "Following " .. name .. what .. "." end
  if t.state == "paused" then return "Following " .. name .. ": your view is paused (you scrolled or zoomed); their play and stop still come." end
  if t.state == "slow" then return "Following " .. name .. " over the shared folder, a few seconds behind (the direct link doesn't reach them)." end
  return "Connecting to " .. name .. "... (their StudioSync hasn't answered yet: until it does, you aren't following)."
end

-- Live sync's tick (within it, so what this changes counts as StudioSync's, not you editing). changed_at: when you last changed the project.
function follow.tick(proj, cfg, b, changed_at)
  local now = reaper.time_precise()
  apply_follow(proj, cfg, b, now)
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
