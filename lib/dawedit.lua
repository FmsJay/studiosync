-- The shared DAW view, stage 2 (docs/realtime-roadmap.md "Shared DAW view"): item and marker edits from the web UI's Project page
-- (lib/webui/daw.js, through lib/dawview.lua's action). Each edit is checked as this computer's own edits are before they go out:
--   items: mirror.watch's rule (its `allowed`): the room's (sync.authority) for the track's name and the spot, or the track's or item's maker
--     while nobody has claimed it; where it is now and where it goes; and not while a bandmate is editing it (presence's holds)
--   markers and regions: sync.watch_timeline's: the song's timeline is the driver's (Claims: anyone's), and a region someone claimed is theirs
--   In Claims, an item on what a bandmate here has claimed isn't refused: it's made, and mirror.watch holds it and asks them for it, as for an
--   edit made in REAPER (lib/claimask.lua); the answer says who was asked (`ask`). rt-claims
-- then applied to this REAPER through the API in one undo point. The normal sync sends it from there, so there's no second sync path and a
-- refusal changes nothing. The answer goes back as the dawedit topic ({ id, ok | why }), and the page that sent it snaps back on a refusal.
-- Items are named as the page drew them (the track's place and the item's among the shown ones, lib/dawview.lua's shown/items_of) and
-- must still be where the page saw them; markers by REAPER's own number. Moves and trims snap to the grid as REAPER would (SnapToGrid: only
-- with snapping on). (James, rt)
local band = require("band")
local dawedit = {}
dawedit.NAME_MAX = 100 -- characters of a marker's or region's name
dawedit.MIN_LEN = 0.01 -- seconds: the shortest an item trims to
dawedit.TOL = 0.002    -- seconds: still where the page drew it (positions go to the page rounded to ms)
dawedit.reply = nil    -- the last edit's answer, published by dawview.tick
dawedit.asking = nil   -- whom the edit being made asks for what they claimed (lib/claimask.lua), else nil

-- ---- pure ------------------------------------------------------------------------------------------------------------------------------
local OPS = { move = "item", trim_start = "item", trim_end = "item", split = "item", mute = "item", colour = "item",
  add_marker = "marker", move_marker = "marker", rename_marker = "marker" }
local function num(x) x = tonumber(x); return x and x == x and x > -1e7 and x < 1e7 and x or nil end
local function int(x) x = tonumber(x); return x and x >= 0 and x < 1e6 and math.floor(x) == x and math.floor(x) or nil end
-- A marker's or region's name from a page: control characters become spaces, ends trimmed; nil when too long, not text, or one of this
-- computer's own marks (a ping, a claim, a punch: band.is_local_mark), which never go to the others.
function dawedit.clean_name(t)
  if t == nil then return "" end
  if type(t) ~= "string" then return nil end
  t = t:gsub("%c", " "):match("^%s*(.-)%s*$")
  if not utf8.len(t) or utf8.len(t) > dawedit.NAME_MAX or band.is_local_mark(t) then return nil end
  return t
end
-- An edit from a page -> what it asks for, checked, or nil, why and its id (so the page that sent it still hears why).
function dawedit.parse(e)
  if type(e) ~= "table" then return nil, "not an edit" end
  local id = type(e.id) == "string" and #e.id <= 40 and e.id:match("^[%w%-]+$") and e.id or nil
  if not OPS[e.op] then return nil, "not an edit this page can make", id end
  local out = { op = e.op, id = id }
  if OPS[e.op] == "item" then
    out.lane, out.idx, out.p, out.l = int(e.lane), int(e.idx), num(e.p), num(e.l)
    if not (out.lane and out.idx and out.p and out.l) then return nil, "that isn't an item the page showed", id end
    if e.op == "move" or e.op == "trim_start" or e.op == "trim_end" then
      out.to = num(e.to)
      if not out.to then return nil, "no place to put it", id end
    end
    if e.op == "move" and e.tolane ~= nil then
      out.tolane = int(e.tolane)
      if not out.tolane then return nil, "not a track the page showed", id end
    end
    if e.op == "mute" then out.on = e.on == true end
    if e.op == "colour" then
      if e.c == nil or e.c == "" then out.c = false
      elseif type(e.c) == "string" and e.c:match("^#%x%x%x%x%x%x$") then out.c = e.c:lower()
      else return nil, "not a colour", id end
    end
    return out
  end
  if e.op == "add_marker" or e.op == "rename_marker" then
    out.name = dawedit.clean_name(e.name)
    if not out.name then return nil, "a name is text up to " .. dawedit.NAME_MAX .. " characters, not starting [ping], [punch] or [claimed", id end
  end
  if e.op == "add_marker" then
    out.at, out.region = num(e.at), e.region == true
    if not out.at then return nil, "no place to put it", id end
    if out.region then
      out.to = num(e.to)
      if not (out.to and out.to > out.at) then return nil, "a region needs an end after its start", id end
    end
    return out
  end
  out.i, out.r, out.p = int(e.i), e.r == true, num(e.p)
  if not (out.i and out.p) then return nil, "that isn't a marker the page showed", id end
  if e.op == "move_marker" then
    out.to = num(e.to)
    if not out.to then return nil, "no place to put it", id end
  end
  return out
end

-- Why this computer's user may not change what's on a track at `pos`, or nil when they may. can, who: sync.authority's; name: the track's;
-- track_oid, item_oid: mirror's. mirror.watch's own rule (its `allowed`), in words as its put-backs have them.
function dawedit.item_refusal(can, who, user, name, track_oid, item_oid, pos)
  if can(user, name, pos) then return nil end
  if require("sync").maker_may(track_oid, user, name, pos, who.mode, item_oid, who.is_claimed) then return nil end
  if who.mode == "driver" then return "only the driver (" .. tostring(who.driver) .. ") changes things in this room" end
  local owner = who.is_claimed and who.is_claimed(name, pos) and who.owner_of and who.owner_of(name, pos)
  if owner and owner ~= user then return tostring(owner) .. " has claimed " .. (name ~= "" and name or "that track") .. " there" end
  if who.mode == "admins" then return "only admins change what nobody has claimed in this room" end
  return "it's the driver's (" .. tostring(who.driver) .. ") until someone claims it: claim the track first"
end
-- Why this computer's user may not change the markers and regions (names: the regions' old and new names), or nil. sync.watch_timeline's
-- rule (the timeline is the driver's, or anyone's in Claims), and a region claimed by someone else stays theirs.
function dawedit.timeline_refusal(can, who, user, names)
  if not can(user, nil, nil) then
    return who.mode == "admins" and "only the driver and admins change markers and regions in this room"
      or "only the driver changes markers and regions (Take control, or ask them to set Who controls to Claims)"
  end
  for _, n in ipairs(names or {}) do
    local c = n ~= "" and type(who.regions) == "table" and who.regions[n:lower()]
    if c and c.user ~= user then return tostring(c.user) .. " has claimed the region " .. n end
  end
end

-- ---- applying it to REAPER ----------------------------------------------------------------------------------------------------------------
-- (the helpers below are stage 3's too: lib/dawmidi.lua's note and envelope point edits find and check what they name the same way)
local function snap(proj, t) return math.max(0, reaper.SnapToGrid(proj, math.max(0, t))) end
dawedit.snap = snap
local function shown_tracks(proj)
  local dawview, out = require("dawview"), {}
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    if dawview.shown(tr) then out[#out + 1] = tr end
  end
  return out
end
local function find_item(proj, e)
  local tracks = shown_tracks(proj)
  local tr = tracks[e.lane + 1]
  local it = tr and require("dawview").items_of(tr)[e.idx + 1]
  if not it then return nil end
  local pos, len = reaper.GetMediaItemInfo_Value(it, "D_POSITION"), reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
  if math.abs(pos - e.p) > dawedit.TOL or math.abs(len - e.l) > dawedit.TOL then return nil end
  return it, tr, pos, len, tracks
end
local function find_marker(proj, e)
  local i = 0
  while true do
    local n, rgn, pos, rend, name, number, color = reaper.EnumProjectMarkers3(proj, i)
    if n == 0 then return nil end
    if number == e.i and rgn == e.r and math.abs(pos - e.p) <= dawedit.TOL and not band.is_local_mark(name) then return { pos = pos, rend = rend, name = name, color = color } end
    i = i + 1
  end
end
local function track_name(tr) return select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)) end
-- One undo point, closed whatever happens. -> nil, or what went wrong.
local function in_undo(proj, label, fn)
  reaper.Undo_BeginBlock2(proj)
  local ok, err = pcall(fn)
  reaper.Undo_EndBlock2(proj, "StudioSync web page: " .. label, -1)
  reaper.UpdateArrange()
  if not ok then return tostring(err) end
end
dawedit.shown_tracks, dawedit.find_item, dawedit.track_name, dawedit.in_undo = shown_tracks, find_item, track_name, in_undo
-- The room's rule now (sync.authority, with the session's regions: region claims hold). -> can, who.
function dawedit.authority(cfg, b) return require("sync").authority(cfg, b.song, b.room, band.read_json(band.session_path(cfg, b.song))) end
-- Why this computer's user may not change item `it` on track `tr` where it is (`pos`) right now, or nil; and the rule, to ask again for
-- where it goes (t, at -> why). Not while a bandmate is editing it (presence's holds), then mirror.watch's rule.
function dawedit.item_why(cfg, b, can, who, it, tr, pos)
  local mirror, presence = require("mirror"), require("presence")
  local user, ioid = cfg.user, mirror.item_oid(it)
  local function refusal(t, at)
    local why = dawedit.item_refusal(can, who, user, track_name(t), mirror.track_oid(t), ioid ~= "" and ioid or nil, at)
    -- (Claims: theirs to give, not a refusal. Made here, mirror.watch holds it and asks them. lib/claimask.lua, rt-claims)
    local owner = why and require("claimask").askable(cfg, b, who, track_name(t), at)
    if owner then dawedit.asking = owner; return nil end
    return why
  end
  local holder = ioid ~= "" and presence.holder(presence.peers(cfg, b.song, b.room), ioid)
  if holder and holder ~= user then return tostring(holder) .. " is editing that item right now: try again in a few seconds", refusal end
  return refusal(tr, pos), refusal
end

local LABEL = { move = "move item", trim_start = "trim item start", trim_end = "trim item end", split = "split item", mute = "mute item",
  colour = "item colour", add_marker = "add marker", move_marker = "move marker", rename_marker = "rename marker" }
-- -> nil when done, or why not.
local function apply(proj, cfg, b, e)
  local can, who = dawedit.authority(cfg, b)
  local user = cfg.user
  if OPS[e.op] == "marker" then
    if e.op == "add_marker" then
      local at = snap(proj, e.at)
      local to = e.region and math.max(at + dawedit.MIN_LEN, snap(proj, e.to)) or 0
      local why = dawedit.timeline_refusal(can, who, user, { e.region and e.name or "" })
      if why then return why end
      return in_undo(proj, e.region and "add region" or LABEL[e.op], function() reaper.AddProjectMarker2(proj, e.region, at, to, e.name, -1, 0) end)
    end
    local m = find_marker(proj, e)
    if not m then return "that " .. (e.r and "region" or "marker") .. " changed meanwhile" end
    local why = dawedit.timeline_refusal(can, who, user, { e.r and m.name or "", e.r and e.name or "" })
    if why then return why end
    local label = e.r and LABEL[e.op]:gsub("marker", "region") or LABEL[e.op]
    if e.op == "move_marker" then
      local to = snap(proj, e.to)
      -- (name "": unchanged; colour 0: unchanged)
      return in_undo(proj, label, function() reaper.SetProjectMarker4(proj, e.i, e.r, to, e.r and to + (m.rend - m.pos) or 0, m.name, 0, 0) end)
    end
    return in_undo(proj, label, function() reaper.SetProjectMarker4(proj, e.i, e.r, m.pos, m.rend, e.name, 0, e.name == "" and 1 or 0) end)
  end
  local it, tr, pos, len, tracks = find_item(proj, e)
  if not it then return "that item changed meanwhile" end
  -- (allowed where it is, and where it goes: moving an item off a claimed track, or onto one, mustn't slip past the claim)
  local why, refusal = dawedit.item_why(cfg, b, can, who, it, tr, pos)
  if why then return why end
  if e.op == "move" then
    local to, dest = snap(proj, e.to), e.tolane and tracks[e.tolane + 1] or tr
    if not dest then return "that track changed meanwhile" end
    why = refusal(dest, to)
    if why then return why end
    return in_undo(proj, LABEL[e.op], function()
      reaper.SetMediaItemInfo_Value(it, "D_POSITION", to)
      if dest ~= tr then reaper.MoveMediaItemToTrack(it, dest) end
    end)
  end
  if e.op == "trim_start" then
    -- (as REAPER's left-edge trim: the content stays put in time; not before the source's start unless it loops)
    local take = reaper.GetActiveTake(it)
    local lo = 0
    if take and reaper.GetMediaItemInfo_Value(it, "B_LOOPSRC") == 0 then
      lo = pos - reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS") / math.max(1e-6, reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE"))
    end
    local to = math.min(math.max(snap(proj, e.to), lo, 0), pos + len - dawedit.MIN_LEN)
    why = refusal(tr, to)
    if why then return why end
    local d = to - pos
    return in_undo(proj, LABEL[e.op], function()
      for k = 0, reaper.CountTakes(it) - 1 do
        local tk = reaper.GetTake(it, k)
        if tk then reaper.SetMediaItemTakeInfo_Value(tk, "D_STARTOFFS", reaper.GetMediaItemTakeInfo_Value(tk, "D_STARTOFFS") + d * reaper.GetMediaItemTakeInfo_Value(tk, "D_PLAYRATE")) end
      end
      reaper.SetMediaItemInfo_Value(it, "D_POSITION", to)
      reaper.SetMediaItemInfo_Value(it, "D_LENGTH", len - d)
    end)
  end
  if e.op == "trim_end" then
    local to = math.max(snap(proj, e.to), pos + dawedit.MIN_LEN)
    return in_undo(proj, LABEL[e.op], function() reaper.SetMediaItemInfo_Value(it, "D_LENGTH", to - pos) end)
  end
  if e.op == "split" then
    -- (at the play cursor while playing, else the edit cursor: REAPER's S)
    local at = reaper.GetPlayStateEx(proj) & 1 == 1 and reaper.GetPlayPositionEx(proj) or reaper.GetCursorPositionEx(proj)
    if not (at > pos + 1e-4 and at < pos + len - 1e-4) then return "the " .. (reaper.GetPlayStateEx(proj) & 1 == 1 and "play" or "edit") .. " cursor isn't over that item" end
    why = refusal(tr, at) -- (the new right-hand piece starts there)
    if why then return why end
    return in_undo(proj, LABEL[e.op], function() reaper.SplitMediaItem(it, at) end)
  end
  if e.op == "mute" then
    return in_undo(proj, e.on and LABEL[e.op] or "unmute item", function() reaper.SetMediaItemInfo_Value(it, "B_MUTE", e.on and 1 or 0) end)
  end
  -- colour: on the active take when it has its own (that's the one REAPER shows), else on the item; none clears both
  local col = e.c and (reaper.ColorToNative(tonumber(e.c:sub(2, 3), 16), tonumber(e.c:sub(4, 5), 16), tonumber(e.c:sub(6, 7), 16)) | 0x1000000) or 0
  return in_undo(proj, LABEL[e.op], function()
    local take = reaper.GetActiveTake(it)
    local own = take and reaper.GetMediaItemTakeInfo_Value(take, "I_CUSTOMCOLOR") ~= 0
    if own or (take and col == 0) then reaper.SetMediaItemTakeInfo_Value(take, "I_CUSTOMCOLOR", col) end
    if not own or col == 0 then reaper.SetMediaItemInfo_Value(it, "I_CUSTOMCOLOR", col) end
  end)
end

-- An edit a page sent (dawview.action). Sets dawedit.reply for the page. -> words for the log.
function dawedit.action(proj, cfg, b, raw)
  local e, why, id = dawedit.parse(raw)
  dawedit.asking = nil
  if e then id = e.id; why = apply(proj, cfg, b, e) end
  local ask = not why and dawedit.asking or nil
  dawedit.reply = { id = id, ok = not why or nil, why = why, ask = ask }
  if why then return "the web page's edit wasn't made: " .. why end
  if ask then return "the web page: " .. (LABEL[e.op] or e.op) .. ", held here while " .. ask .. " is asked for it" end
  return "the web page: " .. (LABEL[e.op] or e.op)
end

return dawedit
