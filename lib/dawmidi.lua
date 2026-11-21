-- The shared DAW view, stage 3 (docs/realtime-roadmap.md "Shared DAW view"): the piano roll and the automation lanes on the web UI's
-- Project page (lib/webui/pianoroll.js, autolanes.js), through lib/dawview.lua's action and tick. Topics, built only while a page shows them
-- (it says so every 10 s, an action "look"; 30 s grace) and looked at again only when REAPER's change count moves:
--   dawmidi  the open MIDI item's notes: only that item's, found as stage 2 names items (lib/dawedit.lua's find_item) and followed after
--            that by the item itself, so a move or trim doesn't lose it; the page names it by the place this topic gives. And its
--            controllers (rt-p14): `ccs`, which CC numbers it has, and, for the one number the page asked for (a look's `cc`), `cc`: its
--            events, five numbers each (its index among the take's controller events, ms from the item's start, value, ticks, channel)
--   dawenv   the envelopes of the tracks whose automation lanes the page has open (volume, pan, width, mute, FX parameters, sends): only
--            those tracks', points normalised to the envelope's range, with its own value labels for the page's readout, and its automation
--            items' place, length and mute (`a`, flat triples: rt-p14)
--   dawsend  the sends of the one track whose sends panel the page has open (rt-p14): each one's destination (by its place among the shown
--            tracks), level, pan and mute
-- Edits, each checked as stage 2's are and applied through the API in one undo point; the normal sync sends them on, and the answer goes
-- back as stage 2's dawedit topic ({ id, ok | why }), so the page that sent it snaps back on a refusal:
--   notes (add, move, resize, delete, velocity): an edit to their item, so mirror.watch's rule where the item is, and not while a bandmate
--     holds it (lib/dawedit.lua's item_why); named by their index and still where the page saw them (start and pitch)
--   envelope points (add, move, delete): an edit to the track's automation, which travels with the track (mirror's "E-" and plug-in
--     objects), so mirror.watch's rule for the track's name with no spot; named by the envelope's index and name and the point's index and
--     time. Point times snap as REAPER's do (SnapToGrid, only with snapping on), note times to the grid the page snapped to. (James, rt)
local band = require("band")
local dawmidi = {}
dawmidi.NOTES_MAX = 4000  -- notes sent from the open item (the first ones)
dawmidi.CC_MAX = 4000     -- controller events sent from the open item for the one number shown (the first ones)
dawmidi.POINTS_MAX = 2000 -- points sent per envelope (the first ones)
dawmidi.LANES_MAX = 8     -- tracks with their automation open at once
dawmidi.SENDS_MAX = 32    -- sends sent from the open track (the first ones)
dawmidi.AI_MAX = 200      -- automation items sent per envelope (the first ones)
dawmidi.LABELS = 16       -- value labels per envelope (REAPER's own wording at even steps across its range)
dawmidi.WANT_FOR = 30     -- seconds a page's look lasts (pages say it every 10 s)
dawmidi.FLOOR = 10        -- a whole look at least this often
dawmidi.TOL = 0.002       -- seconds: an envelope point still where the page drew it

-- ---- pure ------------------------------------------------------------------------------------------------------------------------------
local function num(x) x = tonumber(x); return x and x == x and x > -1e7 and x < 1e7 and x or nil end
local function int(x) x = tonumber(x); return x and x >= 0 and x < 1e6 and math.floor(x) == x and math.floor(x) or nil end
local function r3(x) return math.floor((tonumber(x) or 0) * 1000 + 0.5) / 1000 end
local function id_of(e) return type(e.id) == "string" and #e.id <= 40 and e.id:match("^[%w%-]+$") and e.id or nil end
local function pitch(x) x = int(x); return x and x <= 127 and x or nil end
-- An item as the page drew it (stage 2's names: the track's place and the item's among the shown ones, where it was and how long).
local function ref_of(t)
  if type(t) ~= "table" then return nil end
  local r = { lane = int(t.lane), idx = int(t.idx), p = num(t.p), l = num(t.l) }
  return r.lane and r.idx and r.p and r.l and r or nil
end
dawmidi.ref_of = ref_of
-- What a page shows ({ item = ref | false, cc = a CC number | false, env = { track places }, send = a track's place | false }; any may be left out: the piano
-- roll, the lanes and the sends panel say theirs apart).
function dawmidi.parse_look(t)
  if type(t) ~= "table" then return nil end
  local out = {}
  if t.item ~= nil then out.item = ref_of(t.item) or false end
  if t.cc ~= nil then local n = int(t.cc); out.cc = n and n <= 127 and n or false end -- (the controller lane shown under the notes, or false: none)
  if t.send ~= nil then out.send = int(t.send) or false end -- (a track's place, or false: the sends panel closed)
  if t.env ~= nil then
    out.env = {}
    for _, l in ipairs(type(t.env) == "table" and t.env or {}) do
      local n = int(l)
      if n and #out.env < dawmidi.LANES_MAX then out.env[#out.env + 1] = n end
    end
  end
  return out
end
local NOTE_OPS = { add = "add note", move = "move note", resize = "resize note", delete = "delete note", vel = "note velocity",
  cc_add = "add controller point", cc_move = "move controller point", cc_delete = "delete controller point" }
-- A note edit from a page -> what it asks for, checked, or nil, why and its id. g: the grid the page snapped to, in quarter notes (0: none).
function dawmidi.parse_note(e)
  if type(e) ~= "table" then return nil, "not an edit" end
  local id = id_of(e)
  if not NOTE_OPS[e.op] then return nil, "not an edit this page can make", id end
  local out = { op = e.op, id = id, item = ref_of(e.item), g = num(e.g) or 0 }
  if not out.item then return nil, "that isn't an item the page showed", id end
  if out.g < 0 or out.g > 16 then out.g = 0 end
  if e.op:find("^cc_") then
    -- (a controller point of the open item: a CC number 0 to 127 and, but for an add, its index among the take's events and its ticks)
    out.c = pitch(e.c)
    if not out.c then return nil, "a controller is 0 to 127", id end
    if e.op == "cc_add" then
      out.a, out.v, out.ch = num(e.a), pitch(e.v), math.min(int(e.ch) or 0, 15)
      if not (out.a and out.v) then return nil, "a controller point needs a time and a value 0 to 127", id end
    else
      out.n, out.s = int(e.n), num(e.s)
      if not (out.n and out.s) then return nil, "that isn't a controller point the page showed", id end
      if e.op == "cc_move" then
        out.to, out.v = num(e.to), pitch(e.v)
        if not (out.to and out.v) then return nil, "no place to put it", id end
      end
    end
    return out
  end
  if e.op == "add" then
    out.k, out.a, out.z, out.v, out.ch = pitch(e.k), num(e.a), num(e.z), pitch(e.v) or 100, int(e.ch) or 0
    if not (out.k and out.a and out.z and out.z > out.a) then return nil, "a note needs a pitch, a start and an end after it", id end
    out.v, out.ch = math.max(1, out.v), math.min(out.ch, 15)
    out.step = e.step == true or nil -- (a note of the piano roll's step input: a run of them is one undo point. rt-p5)
    return out
  end
  out.n, out.s, out.k = int(e.n), num(e.s), pitch(e.k)
  if not (out.n and out.s and out.k) then return nil, "that isn't a note the page showed", id end
  if e.op == "move" then
    out.to, out.tok = num(e.to), pitch(e.tok)
    if not (out.to and out.tok) then return nil, "no place to put it", id end
  elseif e.op == "resize" then
    out.z = num(e.z)
    if not out.z then return nil, "no end to give it", id end
  elseif e.op == "vel" then
    out.v = pitch(e.v)
    if not (out.v and out.v >= 1) then return nil, "a velocity is 1 to 127", id end
  end
  return out
end
local AUTO_OPS = { add = "add envelope point", move = "move envelope point", delete = "delete envelope point",
  ai_move = "move automation item", ai_resize = "resize automation item", ai_mute = "mute automation item" }
-- An envelope point edit from a page -> what it asks for, checked, or nil, why and its id. v: 0 to 1 across the envelope's range.
function dawmidi.parse_auto(e)
  if type(e) ~= "table" then return nil, "not an edit" end
  local id = id_of(e)
  if not AUTO_OPS[e.op] then return nil, "not an edit this page can make", id end
  local out = { op = e.op, id = id, lane = int(e.lane), e = int(e.e), name = type(e.name) == "string" and #e.name <= 200 and e.name or nil }
  if not (out.lane and out.e and out.name) then return nil, "that isn't an envelope the page showed", id end
  if e.op:find("^ai_") then
    -- (an automation item: named by its index on the envelope and where it was; moved to `to`, given a new length, or muted)
    out.n, out.t = int(e.n), num(e.t)
    if not (out.n and out.t) then return nil, "that isn't an automation item the page showed", id end
    if e.op == "ai_move" then
      out.at = num(e.to)
      if not out.at then return nil, "no place to put it", id end
    elseif e.op == "ai_resize" then
      out.len = num(e.len)
      if not (out.len and out.len > 0) then return nil, "an automation item needs a length", id end
    else out.on = e.on == true end
    return out
  end
  if e.op ~= "add" then
    out.n, out.t = int(e.n), num(e.t)
    if not (out.n and out.t) then return nil, "that isn't a point the page showed", id end
  end
  if e.op ~= "delete" then
    out.at = num(e.op == "add" and e.t or e.to)
    out.v = num(e.v)
    if not (out.at and out.v) then return nil, "no place to put it", id end
    out.v = math.max(0, math.min(1, out.v))
  end
  return out
end
local SEND_OPS = { add = "add send", remove = "remove send", vol = "send level", pan = "send pan", mute = "send mute" }
dawmidi.SEND_VOL_MAX = 4 -- linear: +12 dB
-- A send edit from a page -> what it asks for, checked, or nil, why and its id. A send is named by its track's place, its index on that track
-- and its destination's place (the page shows the shown tracks, and these places are among them); `add` has no index.
function dawmidi.parse_send(e)
  if type(e) ~= "table" then return nil, "not an edit" end
  local id = id_of(e)
  if not SEND_OPS[e.op] then return nil, "not an edit this page can make", id end
  local out = { op = e.op, id = id, lane = int(e.lane), to = int(e.to) }
  if not (out.lane and out.to) then return nil, "that isn't a send the page showed", id end
  if e.op ~= "add" then
    out.i = int(e.i)
    if not (out.i and out.i < 256) then return nil, "that isn't a send the page showed", id end
  end
  if e.op == "vol" then
    out.v = num(e.v)
    if not (out.v and out.v >= 0 and out.v <= dawmidi.SEND_VOL_MAX) then return nil, "a send's level is 0 to +12 dB", id end
  elseif e.op == "pan" then
    out.p = num(e.p)
    if not (out.p and out.p >= -1 and out.p <= 1) then return nil, "a send's pan is -1 to 1", id end
  elseif e.op == "mute" then out.on = e.on == true end
  return out
end
-- A position in quarter notes on a grid of `step` quarter notes counted from its bar's start (`qs`), as REAPER's MIDI editor snaps.
function dawmidi.snap_qn(qn, qs, step)
  if not (step and step > 0) then return qn end
  return qs + math.floor((qn - qs) / step + 0.5) * step
end
-- A value across lo..hi as 0..1 (4 decimals), and back.
function dawmidi.norm(v, lo, hi) return math.floor(math.max(0, math.min(1, (v - lo) / (hi - lo))) * 10000 + 0.5) / 10000 end
function dawmidi.denorm(x, lo, hi) return lo + x * (hi - lo) end

-- ---- reading REAPER ---------------------------------------------------------------------------------------------------------------------
local function midi_take(it)
  local tk = it and reaper.GetActiveTake(it)
  return tk and reaper.TakeIsMIDI(tk) and tk or nil
end
-- An item's place as the page draws it (lib/dawview.lua's shown/items_of), or nil once it isn't shown.
local function locate(proj, it)
  local dawview, tracks = require("dawview"), require("dawedit").shown_tracks(proj)
  for lane, tr in ipairs(tracks) do
    for idx, x in ipairs(dawview.items_of(tr)) do
      if x == it then return { lane = lane - 1, idx = idx - 1, p = r3(reaper.GetMediaItemInfo_Value(it, "D_POSITION")), l = r3(reaper.GetMediaItemInfo_Value(it, "D_LENGTH")) }, tr end
    end
  end
end
-- The open item's notes: flat, six each: start (ms from the item's start), length (ms), pitch, velocity, start in the take's ticks (the
-- note's name for an edit, with its index and pitch), muted (1) or not (0).
function dawmidi.notes(take, pos)
  local out = {}
  local _, n = reaper.MIDI_CountEvts(take)
  for i = 0, math.min(tonumber(n) or 0, dawmidi.NOTES_MAX) - 1 do
    local ok, _, muted, s, e, _, k, v = reaper.MIDI_GetNote(take, i)
    if ok then
      local a = reaper.MIDI_GetProjTimeFromPPQPos(take, s) - pos
      local z = reaper.MIDI_GetProjTimeFromPPQPos(take, e) - pos
      out[#out + 1] = math.floor(a * 1000 + 0.5)
      out[#out + 1] = math.max(1, math.floor((z - a) * 1000 + 0.5))
      out[#out + 1], out[#out + 2], out[#out + 3], out[#out + 4] = math.floor(k), math.floor(v), r3(s), muted and 1 or 0
    end
  end
  return out, n
end
-- The open item's controllers: which CC numbers it has (sorted), and the events of `want` (a CC number or nil), flat, five each: the event's index among all
-- the take's controller events (its name for an edit, with its ticks and the number), ms from the item's start, value, ticks, channel. Only plain CCs
-- (0xB0): not pitch bend, pressure or program.
function dawmidi.ccs(take, pos, want)
  local has, ev = {}, {}
  local _, _, ncc = reaper.MIDI_CountEvts(take)
  for i = 0, (tonumber(ncc) or 0) - 1 do
    local ok, _, _, ppq, chanmsg, chan, msg2, msg3 = reaper.MIDI_GetCC(take, i)
    if ok and chanmsg == 0xB0 then
      has[msg2] = true
      if msg2 == want and #ev < dawmidi.CC_MAX * 5 then
        local n = #ev
        ev[n + 1], ev[n + 2] = i, math.floor((reaper.MIDI_GetProjTimeFromPPQPos(take, ppq) - pos) * 1000 + 0.5)
        ev[n + 3], ev[n + 4], ev[n + 5] = math.floor(msg3), r3(ppq), math.floor(chan)
      end
    end
  end
  local list = {}
  for k in pairs(has) do list[#list + 1] = k end
  table.sort(list)
  return list, ev
end
-- The built-in envelopes by what they are (names can be translated; their chunk names can't). Sends' and anything else go by name.
local BUILTIN = { ["<VOLENV2"] = "vol", ["<VOLENV"] = "vol", ["<VOLENV3"] = "vol", ["<PANENV2"] = "pan", ["<PANENV"] = "pan",
  ["<WIDTHENV2"] = "pan", ["<WIDTHENV"] = "pan", ["<MUTEENV"] = "mute" }
local function env_name(env) return select(2, reaper.GetEnvelopeName(env)) or "" end
-- An envelope's kind and range in REAPER's raw values (all the point functions use raw values: on a fader-scaled volume envelope that
-- isn't the gain, so the range goes through ScaleToEnvelopeMode). kinds: tr's built-ins (chunk name -> envelope), or nil to look them up.
local function env_range(tr, env, kinds)
  if not kinds then
    kinds = {}
    for chunk, kind in pairs(BUILTIN) do local x = reaper.GetTrackEnvelopeByChunkName(tr, chunk); if x then kinds[x] = kind end end
  end
  local name = env_name(env)
  local _, fx, param = reaper.Envelope_GetParentTrack(env)
  fx, param = tonumber(fx) or -1, tonumber(param) or -1
  local kind = kinds[env] or (fx >= 0 and "fx") or (name:find("Volume") and "vol") or ((name:find("Pan") or name:find("Width")) and "pan") or (name:find("Mute") and "mute") or nil
  local lo, hi
  if kind == "fx" then lo, hi = select(2, reaper.TrackFX_GetParamEx(tr, fx, param))
  elseif kind == "vol" then local mode = reaper.GetEnvelopeScalingMode(env); lo, hi = reaper.ScaleToEnvelopeMode(mode, 0), reaper.ScaleToEnvelopeMode(mode, 2) -- (+6 dB, REAPER's default top)
  elseif kind == "pan" then lo, hi = -1, 1
  else lo, hi = 0, 1 end
  lo, hi = tonumber(lo) or 0, tonumber(hi) or 1
  -- (a point outside it, as an envelope REAPER lets reach +12 dB: the range grows to hold it, so dragging it doesn't clip it)
  for i = 0, math.min(tonumber(reaper.CountEnvelopePointsEx(env, -1)) or 0, dawmidi.POINTS_MAX) - 1 do
    local v = select(3, reaper.GetEnvelopePointEx(env, -1, i))
    v = tonumber(v)
    if v then lo, hi = math.min(lo, v), math.max(hi, v) end
  end
  if hi - lo < 1e-9 then hi = lo + 1 end
  return kind or "other", lo, hi, name
end
-- One track's envelopes as the page draws them: { i (REAPER's index on the track), n (name), k (kind), f (labels), p (points: time, 0..1,
-- shape; flat) }.
function dawmidi.envelopes(tr)
  local kinds, out = {}, {}
  for chunk, kind in pairs(BUILTIN) do local x = reaper.GetTrackEnvelopeByChunkName(tr, chunk); if x then kinds[x] = kind end end
  for i = 0, (tonumber(reaper.CountTrackEnvelopes(tr)) or 0) - 1 do
    local env = reaper.GetTrackEnvelope(tr, i)
    if env then
      local kind, lo, hi, name = env_range(tr, env, kinds)
      local pts, labels = {}, {}
      for j = 0, math.min(tonumber(reaper.CountEnvelopePointsEx(env, -1)) or 0, dawmidi.POINTS_MAX) - 1 do
        local _, t, v, shape = reaper.GetEnvelopePointEx(env, -1, j)
        pts[#pts + 1], pts[#pts + 2], pts[#pts + 3] = r3(t), dawmidi.norm(tonumber(v) or lo, lo, hi), math.floor(tonumber(shape) or 0)
      end
      for k = 0, dawmidi.LABELS do
        local s = reaper.Envelope_FormatValue(env, dawmidi.denorm(k / dawmidi.LABELS, lo, hi))
        labels[#labels + 1] = type(s) == "string" and s:sub(1, 24) or ""
      end
      -- (its automation items: position, length, muted. Not their points: what an item plays isn't drawn, only where it is)
      local ais = {}
      for a = 0, math.min(tonumber(reaper.CountAutomationItems(env)) or 0, dawmidi.AI_MAX) - 1 do
        local n = #ais
        ais[n + 1], ais[n + 2] = r3(reaper.GetSetAutomationItemInfo(env, a, "D_POSITION", 0, false)), r3(reaper.GetSetAutomationItemInfo(env, a, "D_LENGTH", 0, false))
        ais[n + 3] = reaper.GetSetAutomationItemInfo(env, a, "D_MUTE", 0, false) ~= 0 and 1 or 0
      end
      out[#out + 1] = { i = i, n = name:sub(1, 80), k = kind, f = labels, p = pts, a = #ais > 0 and ais or nil }
    end
  end
  return out
end

-- One track's sends as the page draws them: { i (REAPER's index), to (the destination's place among the shown tracks), n (its name), v (level,
-- linear), p (pan), m (muted: 1) }. Sends to hidden tracks and this computer's own (the live out track) aren't shown, as in the Mixer.
function dawmidi.sends(proj, tr)
  local dawedit, out = require("dawedit"), {}
  local place = {}
  for k, t in ipairs(dawedit.shown_tracks(proj)) do place[t] = k - 1 end
  for i = 0, math.min(tonumber(reaper.GetTrackNumSends(tr, 0)) or 0, 255) - 1 do
    local dest = reaper.GetTrackSendInfo_Value(tr, 0, i, "P_DESTTRACK")
    local to = dest and place[dest]
    if to and #out < dawmidi.SENDS_MAX then
      out[#out + 1] = { i = i, to = to, n = dawedit.track_name(dest):sub(1, 40), v = r3(reaper.GetTrackSendInfo_Value(tr, 0, i, "D_VOL")),
        p = r3(reaper.GetTrackSendInfo_Value(tr, 0, i, "D_PAN")), m = reaper.GetTrackSendInfo_Value(tr, 0, i, "B_MUTE") ~= 0 and 1 or nil }
    end
  end
  return out
end

-- ---- applying edits ---------------------------------------------------------------------------------------------------------------------
local S = { item_until = -math.huge, env_until = -math.huge, send_until = -math.huge } -- (what a page is looking at, and a step input run in progress)
local function note_apply(proj, cfg, b, e)
  local dawedit = require("dawedit")
  local it, tr, pos = dawedit.find_item(proj, e.item)
  if not it then return "that item changed meanwhile" end
  local take = midi_take(it)
  if not take then return "that item isn't MIDI" end
  local can, who = dawedit.authority(cfg, b)
  local why = dawedit.item_why(cfg, b, can, who, it, tr, pos)
  if why then return why end
  -- a time from the page -> the take's ticks, on the grid the page snapped to (its bar times are rounded to ms; this is exact)
  local function tick(t)
    if e.g > 0 then
      local qn = reaper.TimeMap2_timeToQN(proj, t)
      local _, qs = reaper.TimeMap_QNToMeasures(proj, qn)
      return math.floor(reaper.MIDI_GetPPQPosFromProjQN(take, dawmidi.snap_qn(qn, tonumber(qs) or 0, e.g)) + 0.5)
    end
    return math.floor(reaper.MIDI_GetPPQPosFromProjTime(take, t) + 0.5)
  end
  if e.op == "cc_add" then
    return dawedit.in_undo(proj, NOTE_OPS[e.op], function() reaper.MIDI_InsertCC(take, false, false, math.max(0, tick(e.a)), 0xB0, e.ch, e.c, e.v); reaper.MIDI_Sort(take) end)
  elseif e.op == "cc_move" or e.op == "cc_delete" then
    local ok, _, _, ppq, chanmsg, _, msg2 = reaper.MIDI_GetCC(take, e.n)
    if not (ok and chanmsg == 0xB0 and msg2 == e.c and math.abs(ppq - e.s) < 0.5) then return "that controller point changed meanwhile" end
    return dawedit.in_undo(proj, NOTE_OPS[e.op], function()
      if e.op == "cc_move" then reaper.MIDI_SetCC(take, e.n, nil, nil, math.max(0, tick(e.to)), nil, nil, nil, e.v, false) else reaper.MIDI_DeleteCC(take, e.n) end
    end)
  end
  if e.op == "add" then
    local s = math.max(0, tick(e.a))
    local z = math.max(tick(e.z), s + 1)
    local function insert() reaper.MIDI_InsertNote(take, false, false, s, z, e.ch, e.k, e.v, false) end
    if not e.step then return dawedit.in_undo(proj, NOTE_OPS[e.op], insert) end
    -- Step input (rt-p5): each note of a run goes in with no undo point of its own, and one "step input" point is made when the run ends
    -- (dawmidi.step_flush: STEP_GAP s after the last note, or at once for any other edit), so Ctrl+Z takes the whole run back.
    -- shortcut: if nothing flushes (the page left and Live sync stopped), REAPER's next undo point of any kind takes the notes in.
    if S.step and S.step.take ~= take then dawmidi.step_flush(proj, reaper.time_precise(), true) end
    local ok, err = pcall(insert)
    reaper.UpdateArrange()
    if not ok then return tostring(err) end
    S.step = { proj = proj, take = take, at = reaper.time_precise(), n = (S.step and S.step.n or 0) + 1 }
    return nil
  end
  local ok, _, _, s, z, _, k = reaper.MIDI_GetNote(take, e.n)
  if not (ok and math.abs(s - e.s) < 0.5 and k == e.k) then return "that note changed meanwhile" end
  return dawedit.in_undo(proj, NOTE_OPS[e.op], function()
    if e.op == "move" then
      local to = math.max(0, tick(e.to))
      reaper.MIDI_SetNote(take, e.n, nil, nil, to, to + (z - s), nil, e.tok, nil, false)
    elseif e.op == "resize" then reaper.MIDI_SetNote(take, e.n, nil, nil, nil, math.max(tick(e.z), s + 1), nil, nil, nil, false)
    elseif e.op == "vel" then reaper.MIDI_SetNote(take, e.n, nil, nil, nil, nil, nil, nil, e.v, false)
    else reaper.MIDI_DeleteNote(take, e.n) end
  end)
end
local function auto_apply(proj, cfg, b, e)
  local dawedit, mirror = require("dawedit"), require("mirror")
  local tr = dawedit.shown_tracks(proj)[e.lane + 1]
  local env = tr and reaper.GetTrackEnvelope(tr, e.e)
  if not env or env_name(env) ~= e.name then return "that envelope changed meanwhile" end
  -- (the track's automation travels as the track's own, so the track's rule, with no spot: mirror.watch's for its "E-" and plug-in objects.
  -- A bandmate editing it too isn't a refusal: the two merge point by point. rt-merge)
  local toid = mirror.track_oid(tr)
  local can, who = dawedit.authority(cfg, b)
  local why = dawedit.item_refusal(can, who, cfg.user, dawedit.track_name(tr), toid, nil, nil)
  if why then return why end
  if e.op:find("^ai_") then
    local pos = e.n < (tonumber(reaper.CountAutomationItems(env)) or 0) and reaper.GetSetAutomationItemInfo(env, e.n, "D_POSITION", 0, false)
    if not (pos and math.abs(pos - e.t) <= dawmidi.TOL) then return "that automation item changed meanwhile" end
    return dawedit.in_undo(proj, e.op == "ai_mute" and not e.on and "unmute automation item" or AUTO_OPS[e.op], function()
      if e.op == "ai_move" then reaper.GetSetAutomationItemInfo(env, e.n, "D_POSITION", dawedit.snap(proj, e.at), true)
      elseif e.op == "ai_resize" then -- (the end snaps as a trimmed item's does; never shorter than an item may be)
        reaper.GetSetAutomationItemInfo(env, e.n, "D_LENGTH", math.max(dawedit.MIN_LEN, dawedit.snap(proj, pos + e.len) - pos), true)
      else reaper.GetSetAutomationItemInfo(env, e.n, "D_MUTE", e.on and 1 or 0, true) end
    end)
  end
  if e.op ~= "add" then
    local ok, t = reaper.GetEnvelopePointEx(env, -1, e.n)
    if not (ok and math.abs(t - e.t) <= dawmidi.TOL) then return "that point changed meanwhile" end
  end
  local kind, lo, hi = env_range(tr, env)
  return dawedit.in_undo(proj, AUTO_OPS[e.op], function()
    if e.op == "delete" then reaper.DeleteEnvelopePointEx(env, -1, e.n); return end
    local at, v = dawedit.snap(proj, e.at), dawmidi.denorm(e.v, lo, hi)
    if e.op == "add" then reaper.InsertEnvelopePointEx(env, -1, at, v, kind == "mute" and 1 or 0, 0, false, true)
    else reaper.SetEnvelopePointEx(env, -1, e.n, at, v, nil, nil, nil, true) end
    reaper.Envelope_SortPointsEx(env, -1)
  end)
end

-- A send edit. A send is the destination's own object in the sync (its receive: mirror's "AUXRECV" on the track it goes to), so it's the
-- destination's rule that's asked, as the Mixer does: the track's name, with no spot (sync.authority / sync.maker_may). A bandmate editing
-- it too isn't a refusal: they merge.
local function send_apply(proj, cfg, b, e)
  local dawedit, mirror = require("dawedit"), require("mirror")
  local tracks = dawedit.shown_tracks(proj)
  local tr, dest = tracks[e.lane + 1], tracks[e.to + 1]
  if not (tr and dest) then return "that track changed meanwhile" end
  if e.op == "add" and tr == dest then return "a track can't send to itself" end
  if e.op ~= "add" and not (e.i < (tonumber(reaper.GetTrackNumSends(tr, 0)) or 0) and reaper.GetTrackSendInfo_Value(tr, 0, e.i, "P_DESTTRACK") == dest) then
    return "that send changed meanwhile"
  end
  local can, who = dawedit.authority(cfg, b)
  local why = dawedit.item_refusal(can, who, cfg.user, dawedit.track_name(dest), mirror.track_oid(dest), nil, nil)
  if why then return why end
  local label = SEND_OPS[e.op] .. " " .. (e.op == "add" and "to " or "") .. dawedit.track_name(dest)
  return dawedit.in_undo(proj, label, function()
    if e.op == "add" then
      if reaper.CreateTrackSend(tr, dest) < 0 then error("REAPER couldn't make that send") end
    elseif e.op == "remove" then
      if not reaper.RemoveTrackSend(tr, 0, e.i) then error("REAPER couldn't remove that send") end
    elseif e.op == "vol" then reaper.SetTrackSendInfo_Value(tr, 0, e.i, "D_VOL", e.v)
    elseif e.op == "pan" then reaper.SetTrackSendInfo_Value(tr, 0, e.i, "D_PAN", e.p)
    else reaper.SetTrackSendInfo_Value(tr, 0, e.i, "B_MUTE", e.on and 1 or 0) end
  end)
end

-- ---- through lib/dawview.lua --------------------------------------------------------------------------------------------------------------
dawmidi.STEP_GAP = 1.5 -- seconds after a step input run's last note that its one undo point is made
-- The run of step input notes ends: its one undo point, if it's over (STEP_GAP s since the last note, or force). Sync sees the change from here.
function dawmidi.step_flush(proj, now, force)
  local st = S.step
  if not st or (not force and now - st.at < dawmidi.STEP_GAP) then return end
  S.step = nil
  if reaper.ValidatePtr2(st.proj or proj, st.take, "MediaItem_Take*") then
    reaper.Undo_OnStateChangeEx2(st.proj or proj, "StudioSync web page: step input (" .. st.n .. (st.n == 1 and " note)" or " notes)"), -1, -1)
  end
end
-- Everything goes again (the tab in front changed).
function dawmidi.reset() S.built, S.cc, S.sig = nil, nil, nil end
-- An action a page sent ({ look }, { note }, { auto }). -> words for the log, or nil.
function dawmidi.action(proj, cfg, b, a)
  local now = reaper.time_precise()
  if type(a.look) == "table" then
    local l = dawmidi.parse_look(a.look)
    if l.item ~= nil then
      -- (a newly opened item is found as the page named it, then followed by the item itself: a page's later looks name it where it was)
      local same = S.item and l.item and S.ref and l.item.lane == S.ref.lane and l.item.idx == S.ref.idx
      if not same then S.item = l.item and require("dawedit").find_item(proj, l.item) or nil; S.ref, S.built, S.sig = nil, nil, nil; S.asked = l.item or nil end
      S.item_until = l.item and now + dawmidi.WANT_FOR or -math.huge
    end
    if l.cc ~= nil and (l.cc or nil) ~= S.ccn then S.ccn, S.sig, S.built = l.cc or nil, nil, nil end
    if l.send ~= nil then S.send, S.built = l.send or nil, nil; S.send_until = l.send and now + dawmidi.WANT_FOR or -math.huge end
    if l.env ~= nil then S.env, S.built = l.env, nil; S.env_until = #l.env > 0 and now + dawmidi.WANT_FOR or -math.huge end
    return
  end
  local dawedit = require("dawedit")
  local parse, apply, ops = dawmidi.parse_note, note_apply, NOTE_OPS
  if a.send ~= nil then parse, apply, ops = dawmidi.parse_send, send_apply, SEND_OPS
  elseif a.note == nil then parse, apply, ops = dawmidi.parse_auto, auto_apply, AUTO_OPS end
  if not (type(a.note) == "table" and a.note.step == true and a.note.op == "add") then dawmidi.step_flush(proj, now, true) end -- (any other edit ends a step run first)
  local e, why, id = parse(a.note or a.auto or a.send)
  if e then id = e.id; why = apply(proj, cfg, b, e) end
  dawedit.reply = { id = id, ok = not why or nil, why = why }
  S.built = nil -- (looked at again at once, whatever the change count)
  if why then return "the web page's edit wasn't made: " .. why end
  return "the web page: " .. ops[e.op]
end
-- Each tick dawview.tick runs (a page shows the Project page). publish: lib/webui.lua's (sends only what changed).
function dawmidi.tick(proj, cfg, b, publish, now)
  dawmidi.step_flush(proj, now)
  local item_on, env_on, send_on = now < S.item_until, now < S.env_until, now < S.send_until
  if not (item_on or env_on or send_on) then return end
  local cc = reaper.GetProjectStateChangeCount(proj)
  if S.built and cc == S.cc and now - S.built < dawmidi.FLOOR then return end
  S.built, S.cc = now, cc
  local key = b.song .. "/" .. b.room
  if item_on then
    local it = S.item
    local ref, tr = nil, nil
    if it and reaper.ValidatePtr2(proj, it, "MediaItem*") then ref, tr = locate(proj, it) end
    local take = ref and midi_take(it)
    if not take then
      S.sig = nil
      publish("dawmidi", { key = key, asked = S.asked, gone = "that item changed meanwhile, or isn't MIDI any more" })
    else
      local _, h = reaper.MIDI_GetHash(take, false) -- (every event, not the notes only: a controller edit must show too)
      local sig = table.concat({ tostring(h), ref.lane, ref.idx, ref.p, ref.l, S.ccn or "" }, "|")
      if sig ~= S.sig then
        S.sig = sig
        local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
        local notes, n = dawmidi.notes(take, pos)
        local ccs, ccev = dawmidi.ccs(take, pos, S.ccn)
        local rgb = require("dawview").native_rgb(reaper.GetMediaItemTakeInfo_Value(take, "I_CUSTOMCOLOR"))
          or require("dawview").native_rgb(reaper.GetMediaItemInfo_Value(it, "I_CUSTOMCOLOR")) or require("dawview").native_rgb(band.track_colour(tr))
        publish("dawmidi", { key = key, asked = S.asked, ref = ref, name = reaper.GetTakeName(take):sub(1, 40), track = require("dawedit").track_name(tr),
          c = rgb, nt = notes, more = (tonumber(n) or 0) > dawmidi.NOTES_MAX and 1 or nil, ccs = #ccs > 0 and ccs or nil,
          cc = S.ccn and { c = S.ccn, ev = ccev } or nil })
      end
      S.ref = ref
    end
  end
  if send_on and S.send then
    local tr = require("dawedit").shown_tracks(proj)[S.send + 1]
    publish("dawsend", { key = key, lane = S.send, name = tr and require("dawedit").track_name(tr):sub(1, 40) or nil, sends = tr and dawmidi.sends(proj, tr) or {} })
  end
  if env_on then
    local tracks, lanes = require("dawedit").shown_tracks(proj), {}
    for _, lane in ipairs(S.env or {}) do
      local tr = tracks[lane + 1]
      if tr then lanes[#lanes + 1] = { lane = lane, env = dawmidi.envelopes(tr) } end
    end
    publish("dawenv", { key = key, lanes = lanes })
  end
end

return dawmidi
