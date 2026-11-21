-- The shared DAW view, stage 3 (lib/dawmidi.lua, lib/webui/pianoroll.js, autolanes.js): what a page may send, the open item's notes and the
-- open tracks' envelopes as published (only while a page looks, the item followed after it moves), note edits (add, move, resize, delete,
-- velocity, snapped to the page's grid in quarter notes) and envelope point edits (add, move, delete, in raw values across the envelope's
-- range), each on a stand-in REAPER in one undo point, the permission rules (the real sync.authority over a stand-in shared folder: claims,
-- a bandmate's hold, Driver only), refusals that change nothing, the answer as stage 2's dawedit topic, and a link check of the pages. (James, rt)
package.path = "lib/?.lua;" .. package.path
local ext, logged, clock = {}, {}, 1000
reaper = setmetatable({
  time_precise = function() return clock end,
  GetOS = function() return "Win64" end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  GetExePath = function() return "C:/REAPER" end,
  GetResourcePath = function() return "C:/res" end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() return "" end end end })
local band = require("band")
band.log = function(s) logged[#logged + 1] = s end

-- ---- a stand-in shared folder, read by the real sync.authority (as stage 2's test) --------------------------------------------------
local files = {}
band.read_json = function(path) return files[path] end
local function list(dir) local out = {}; for p in pairs(files) do local f = p:match("^" .. dir:gsub("%p", "%%%0") .. "/([^/]+%.json)$"); if f then out[#out + 1] = f end end; table.sort(out); return out end
band.files, band.listing = list, function(dir) return list(dir) end
local R = "R/S/rooms/main"
files["R/S/session.json"] = { host = "James" }
local function room(mode, claims)
  for p in pairs(files) do if p:find("^" .. R) then files[p] = nil end end
  files[R .. "/mode.json"] = { mode = mode }
  for user, c in pairs(claims or {}) do c.user, c.time = user, "2026-11-20T10:00:00Z"; files[R .. "/claims/" .. user .. ".json"] = c end
end
package.loaded.groups = { may_manage = function(_, user) return user == "Admin" end }
package.loaded.mirror = {
  local_track = function(tr) return tr.t["local"] == true end,
  track_oid = function(tr) return (tr.t.oid or ""):upper() end,
  item_oid = function(it) return (it.oid or ""):upper() end,
  is_creator = function(oid, user) return (oid or ""):match("^%a%-(.-)%-") == user:upper() end,
}
package.loaded.people = { colours = function() return {} end }
local peers = {}
require("presence").peers = function() return peers end
local dawmidi, dawview, dawedit = require("dawmidi"), require("dawview"), require("dawedit")

-- ---- parse ------------------------------------------------------------------------------------------------------------------------------
local l = dawmidi.parse_look({ item = { lane = 1, idx = 0, p = 4, l = 8 }, env = { 0, 2, -1, "x", 1.5 } })
assert(l.item.lane == 1 and #l.env == 2 and l.env[2] == 2, "a look: the item and the good track places")
assert(dawmidi.parse_look({ env = { 0 } }).item == nil and dawmidi.parse_look({ item = false }).item == false, "either part alone; false closes the piano roll")
local env10 = {}
for i = 1, 20 do env10[i] = i end
assert(#dawmidi.parse_look({ env = env10 }).env == dawmidi.LANES_MAX, "at most LANES_MAX tracks' automation")
local it0 = { lane = 1, idx = 0, p = 4, l = 8 }
local n = dawmidi.parse_note({ id = "n1", op = "add", item = it0, k = 60, a = 4.5, z = 5, g = 0.5 })
assert(n and n.k == 60 and n.v == 100 and n.ch == 0 and n.g == 0.5 and n.id == "n1", "an add: velocity 100 and channel 1 unless said")
assert(dawmidi.parse_note({ op = "move", item = it0, n = 2, s = 480, k = 62, to = 6, tok = 64 }).tok == 64, "a move")
assert(dawmidi.parse_note({ op = "vel", item = it0, n = 0, s = 0, k = 60, v = 0 }) == nil, "velocity 0 isn't a note")
assert(dawmidi.parse_note({ op = "add", item = it0, k = 60, a = 4.5, z = 5, g = 99 }).g == 0, "a silly grid: no snapping")
local bad = { { op = "add", item = it0, k = 128, a = 1, z = 2 }, { op = "add", item = it0, k = 60, a = 2, z = 2 }, { op = "add", k = 60, a = 1, z = 2 },
  { op = "move", item = it0, n = 0, s = 0, k = 60, to = 1 }, { op = "resize", item = it0, n = -1, s = 0, k = 60, z = 1 }, { op = "glue", item = it0 },
  { op = "move", item = { lane = 0, idx = 0, p = 0 / 0, l = 1 }, n = 0, s = 0, k = 60, to = 1, tok = 60 }, "nope" }
for i, b in ipairs(bad) do assert(dawmidi.parse_note(b) == nil, "a note edit refused: #" .. i) end
assert(select(3, dawmidi.parse_note({ id = "n9", op = "glue" })) == "n9", "a refusal keeps its id")
local au = dawmidi.parse_auto({ id = "a1", op = "add", lane = 0, e = 1, name = "Pan", t = 3, v = 1.7 })
assert(au and au.at == 3 and au.v == 1, "an envelope point: v clamped to the range")
assert(dawmidi.parse_auto({ op = "move", lane = 0, e = 1, name = "Pan", n = 0, t = 1, to = 2, v = 0.5 }).at == 2, "a move goes to `to`")
for i, b in ipairs({ { op = "add", lane = 0, e = 1, t = 3, v = 0.5 }, { op = "move", lane = 0, e = 1, name = "Pan", t = 1, to = 2, v = 0.5 },
    { op = "delete", lane = 0, e = 1, name = "Pan", n = 0 }, { op = "add", lane = 0, e = 1, name = ("x"):rep(201), t = 1, v = 0 }, { op = "shape", lane = 0, e = 1, name = "Pan" } }) do
  assert(dawmidi.parse_auto(b) == nil, "a point edit refused: #" .. i)
end
-- controllers (rt-p14): the lane shown, and a controller point named by its index, its ticks and its CC number
assert(dawmidi.parse_look({ item = { lane = 0, idx = 0, p = 4, l = 8 }, cc = 7 }).cc == 7 and dawmidi.parse_look({ cc = false }).cc == false and dawmidi.parse_look({ cc = 128 }).cc == false
  and dawmidi.parse_look({ cc = -1 }).cc == false and dawmidi.parse_look({ item = false }).cc == nil, "a look at a CC lane: 0 to 127, false closes it, silent when it isn't said")
local ca = dawmidi.parse_note({ id = "c1", op = "cc_add", item = it0, c = 1, a = 5, v = 0 })
assert(ca and ca.c == 1 and ca.a == 5 and ca.v == 0 and ca.ch == 0 and ca.id == "c1", "a controller add: value 0 is a value")
local cm = dawmidi.parse_note({ op = "cc_move", item = it0, c = 1, n = 2, s = 960, to = 6, v = 99 })
assert(cm and cm.n == 2 and cm.s == 960 and cm.to == 6 and cm.v == 99 and dawmidi.parse_note({ op = "cc_delete", item = it0, c = 7, n = 0, s = 0 }).c == 7, "move, delete")
for i, bad in ipairs({ { op = "cc_add", item = it0, c = 128, a = 1, v = 1 }, { op = "cc_add", item = it0, a = 1, v = 1 }, { op = "cc_add", item = it0, c = 1, a = 1, v = 128 }, { op = "cc_add", item = it0, c = 1, v = 1 },
    { op = "cc_move", item = it0, c = 1, n = 0, s = 0, v = 1 }, { op = "cc_move", item = it0, c = 1, n = 0, s = 0, to = 1 }, { op = "cc_delete", item = it0, c = 1, s = 0 },
    { op = "cc_delete", c = 1, n = 0, s = 0 }, { op = "cc_wheel", item = it0, c = 1 } }) do
  assert(dawmidi.parse_note(bad) == nil, "a controller edit refused: #" .. i)
end
-- sends (rt-p14): a send is named by its track's place, its index and its destination's place
assert(dawmidi.parse_look({ send = 2 }).send == 2 and dawmidi.parse_look({ send = false }).send == false and dawmidi.parse_look({ send = -1 }).send == false, "a look at a track's sends; false closes the panel")
assert(dawmidi.parse_look({ env = { 0 } }).send == nil, "and says nothing of them when it doesn't")
local sv = dawmidi.parse_send({ id = "s1", op = "vol", lane = 0, to = 1, i = 0, v = 0.5 })
assert(sv and sv.v == 0.5 and sv.i == 0 and sv.to == 1 and sv.id == "s1", "a send level")
assert(dawmidi.parse_send({ op = "add", lane = 0, to = 1 }).i == nil and dawmidi.parse_send({ op = "mute", lane = 0, to = 1, i = 2, on = true }).on == true
  and dawmidi.parse_send({ op = "pan", lane = 0, to = 1, i = 2, p = -0.5 }).p == -0.5 and dawmidi.parse_send({ op = "remove", lane = 0, to = 1, i = 2 }).i == 2, "add, mute, pan, remove")
for i, bad in ipairs({ { op = "vol", lane = 0, to = 1, i = 0, v = -1 }, { op = "vol", lane = 0, to = 1, i = 0, v = 4.5 }, { op = "vol", lane = 0, to = 1, i = 0 },
    { op = "pan", lane = 0, to = 1, i = 0, p = 1.5 }, { op = "remove", lane = 0, to = 1 }, { op = "remove", lane = 0, to = 1, i = 256 }, { op = "add", lane = 0 },
    { op = "add", to = 1 }, { op = "mode", lane = 0, to = 1, i = 0 }, { op = "vol", lane = 0, to = 1, i = 0, v = 0 / 0 }, "nope" }) do
  assert(dawmidi.parse_send(bad) == nil, "a send edit refused: #" .. i)
end
assert(select(3, dawmidi.parse_send({ id = "s9", op = "glue" })) == "s9", "a refusal keeps its id")
-- automation items (rt-p14): named by index and place; moved, given a length, muted
local ai = dawmidi.parse_auto({ id = "i1", op = "ai_move", lane = 0, e = 1, name = "Pan", n = 1, t = 10, to = 11 })
assert(ai and ai.n == 1 and ai.t == 10 and ai.at == 11 and ai.id == "i1", "an automation item move")
assert(dawmidi.parse_auto({ op = "ai_resize", lane = 0, e = 1, name = "Pan", n = 0, t = 2, len = 3 }).len == 3 and dawmidi.parse_auto({ op = "ai_mute", lane = 0, e = 1, name = "Pan", n = 0, t = 2, on = true }).on == true, "resize, mute")
for i, bad in ipairs({ { op = "ai_move", lane = 0, e = 1, name = "Pan", n = 1, t = 10 }, { op = "ai_move", lane = 0, e = 1, name = "Pan", t = 10, to = 1 }, { op = "ai_resize", lane = 0, e = 1, name = "Pan", n = 0, t = 2, len = 0 },
    { op = "ai_resize", lane = 0, e = 1, name = "Pan", n = 0, t = 2 }, { op = "ai_mute", lane = 0, e = 1, n = 0, t = 2, on = true }, { op = "ai_move", lane = 0, e = 1, name = "Pan", n = -1, t = 1, to = 1 },
    { op = "ai_delete", lane = 0, e = 1, name = "Pan", n = 0, t = 2 } }) do
  assert(dawmidi.parse_auto(bad) == nil, "an automation item edit refused: #" .. i)
end
assert(dawmidi.snap_qn(5.3, 4, 0.5) == 5.5 and dawmidi.snap_qn(5.3, 4, 0) == 5.3 and dawmidi.snap_qn(3.6, 3.5, 1) == 3.5, "snapped from the bar's start (a 7/8 bar starts mid-beat)")
assert(dawmidi.norm(0.5, -1, 1) == 0.75 and dawmidi.norm(9, 0, 1) == 1 and dawmidi.denorm(0.75, -1, 1) == 0.5, "normalised and back")

-- ---- a stand-in REAPER: 120 bpm in 4/4 (2 quarter notes a second), 960 ticks a quarter note -------------------------------------------
local undo, fake = {}, nil
local function setup(f)
  fake = f
  for _, t in ipairs(f.tracks) do
    t.ptr = { t = t }
    for _, it in ipairs(t.items) do it.track = t; for _, tk in ipairs(it.takes or {}) do tk.item = it end end
    for _, e in ipairs(t.envs or {}) do e.track = t end
  end
end
reaper.CountTracks = function() return #fake.tracks end
reaper.GetTrack = function(_, i) return fake.tracks[i + 1].ptr end
reaper.GetMediaTrackInfo_Value = function(tr, k) if k == "B_SHOWINTCP" then return tr.t.hidden and 0 or 1 end return 0 end
reaper.GetSetMediaTrackInfo_String = function(tr, k) if k == "P_NAME" then return true, tr.t.name end return true, "" end
reaper.CountTrackMediaItems = function(tr) return #tr.t.items end
reaper.GetTrackMediaItem = function(tr, j) return tr.t.items[j + 1] end
local IV = { D_POSITION = "pos", D_LENGTH = "len", B_MUTE = "mute", I_CUSTOMCOLOR = "color" }
reaper.GetMediaItemInfo_Value = function(it, k) return it[IV[k]] or 0 end
reaper.GetActiveTake = function(it) return (it.takes or {})[1] end
reaper.GetMediaItemTakeInfo_Value = function(tk, k) return k == "I_CUSTOMCOLOR" and (tk.color or 0) or 0 end
reaper.TakeIsMIDI = function(tk) return tk.notes ~= nil end
reaper.GetTakeName = function() return "Riff" end
reaper.ColorFromNative = function(c) return c & 255, (c >> 8) & 255, (c >> 16) & 255 end
reaper.ValidatePtr2 = function(_, p) for _, t in ipairs(fake.tracks) do for _, it in ipairs(t.items) do if it == p then return true end end end return false end
local function pos_of(tk) return tk.item.pos end
reaper.MIDI_CountEvts = function(tk) return 1, #tk.notes, #(tk.ccs or {}), 0 end
local function csort(tk) table.sort(tk.ccs, function(a, z) return a.ppq < z.ppq end) end
reaper.MIDI_GetCC = function(tk, i)
  local x = (tk.ccs or {})[i + 1]
  if not x then return false end
  return true, false, false, x.ppq, x.msg or 0xB0, x.ch or 0, x.c, x.v
end
reaper.MIDI_SetCC = function(tk, i, _, _, ppq, _, _, _, v) local x = tk.ccs[i + 1]; x.ppq, x.v = ppq or x.ppq, v or x.v; csort(tk); return true end
reaper.MIDI_InsertCC = function(tk, _, _, ppq, msg, ch, c, v) tk.ccs = tk.ccs or {}; tk.ccs[#tk.ccs + 1] = { ppq = ppq, msg = msg, ch = ch, c = c, v = v }; return true end
reaper.MIDI_DeleteCC = function(tk, i) table.remove(tk.ccs, i + 1); return true end
reaper.MIDI_Sort = function(tk) if tk.ccs then csort(tk) end return true end
reaper.MIDI_GetNote = function(tk, i)
  local x = tk.notes[i + 1]
  if not x then return false end
  return true, false, x.muted or false, x.s, x.e, x.ch or 0, x.k, x.v
end
local function sort(tk) table.sort(tk.notes, function(a, z) return a.s < z.s end) end
reaper.MIDI_SetNote = function(tk, i, _, _, s, e, _, k, v)
  local x = tk.notes[i + 1]
  x.s, x.e, x.k, x.v = s or x.s, e or x.e, k or x.k, v or x.v
  sort(tk)
  return true
end
reaper.MIDI_InsertNote = function(tk, _, _, s, e, ch, k, v) tk.notes[#tk.notes + 1] = { s = s, e = e, ch = ch, k = k, v = v }; sort(tk); return true end
reaper.MIDI_DeleteNote = function(tk, i) table.remove(tk.notes, i + 1); return true end
reaper.MIDI_GetHash = function(tk, notesonly)
  local h = {}
  for _, x in ipairs(tk.notes) do h[#h + 1] = x.s .. ":" .. x.e .. ":" .. x.k .. ":" .. x.v end
  if not notesonly then for _, x in ipairs(tk.ccs or {}) do h[#h + 1] = "c" .. x.ppq .. ":" .. x.c .. ":" .. x.v end end
  return true, table.concat(h, ",")
end
reaper.MIDI_GetProjTimeFromPPQPos = function(tk, ppq) return pos_of(tk) + ppq / 1920 end
reaper.MIDI_GetPPQPosFromProjTime = function(tk, t) return (t - pos_of(tk)) * 1920 end
reaper.MIDI_GetPPQPosFromProjQN = function(tk, qn) return (qn / 2 - pos_of(tk)) * 1920 end
reaper.TimeMap2_timeToQN = function(_, t) return t * 2 end
reaper.TimeMap_QNToMeasures = function(_, qn) local m = math.floor(qn / 4); return m + 1, m * 4, m * 4 + 4 end
reaper.SnapToGrid = function(_, t) return math.floor(t * 2 + 0.5) / 2 end
reaper.Undo_BeginBlock2 = function() undo[#undo + 1] = { open = true } end
reaper.Undo_EndBlock2 = function(_, label) undo[#undo].open, undo[#undo].label = false, label end
-- envelopes: raw values; the volume one is "fader scaled" here as raw = gain / 2
reaper.CountTrackEnvelopes = function(tr) return #(tr.t.envs or {}) end
reaper.GetTrackEnvelope = function(tr, i) return (tr.t.envs or {})[i + 1] end
reaper.GetEnvelopeName = function(e) return true, e.name end
reaper.GetTrackEnvelopeByChunkName = function(tr, chunk) for _, e in ipairs(tr.t.envs or {}) do if e.chunk == chunk then return e end end end
reaper.Envelope_GetParentTrack = function(e) return e.track.ptr, e.fx or -1, e.param or -1 end
reaper.TrackFX_GetParamEx = function() return 0.5, 20, 20000, 1000 end
reaper.GetEnvelopeScalingMode = function(e) return e.chunk == "<VOLENV2" and 1 or 0 end
reaper.ScaleToEnvelopeMode = function(mode, v) return mode == 1 and v / 2 or v end
reaper.CountEnvelopePointsEx = function(e) return #e.pts end
reaper.GetEnvelopePointEx = function(e, _, i) local p = e.pts[i + 1]; if not p then return false end return true, p.t, p.v, p.shape or 0, 0, false end
local function esort(e) table.sort(e.pts, function(a, z) return a.t < z.t end) end
reaper.SetEnvelopePointEx = function(e, _, i, t, v) local p = e.pts[i + 1]; p.t, p.v = t or p.t, v or p.v; return true end
reaper.InsertEnvelopePointEx = function(e, _, t, v, shape) e.pts[#e.pts + 1] = { t = t, v = v, shape = shape }; return true end
reaper.DeleteEnvelopePointEx = function(e, _, i) table.remove(e.pts, i + 1); return true end
reaper.Envelope_SortPointsEx = function(e) esort(e); return true end
reaper.Envelope_FormatValue = function(e, v) return string.format("%s %.2f", e.name, v) end
-- automation items: an envelope's list of { pos, len, mute }
reaper.CountAutomationItems = function(e) return #(e.ais or {}) end
local AIK = { D_POSITION = "pos", D_LENGTH = "len", D_MUTE = "mute" }
reaper.GetSetAutomationItemInfo = function(e, a, k, v, set)
  local x = e.ais[a + 1]
  if set then x[AIK[k]] = v; return v end
  return x[AIK[k]]
end
reaper.GetProjectStateChangeCount = function() return clock end
-- sends: a track's list of { dest = the destination's stand-in, v, p, m }
reaper.GetTrackNumSends = function(tr) return #(tr.t.sends or {}) end
reaper.GetTrackSendInfo_Value = function(tr, _, i, k)
  local s = tr.t.sends[i + 1]
  if k == "P_DESTTRACK" then return s.dest.ptr elseif k == "D_VOL" then return s.v elseif k == "D_PAN" then return s.p elseif k == "B_MUTE" then return s.m and 1 or 0 end
  return 0
end
reaper.SetTrackSendInfo_Value = function(tr, _, i, k, v)
  local s = tr.t.sends[i + 1]
  if k == "D_VOL" then s.v = v elseif k == "D_PAN" then s.p = v elseif k == "B_MUTE" then s.m = v ~= 0 end
  return true
end
reaper.CreateTrackSend = function(tr, dest) tr.t.sends = tr.t.sends or {}; tr.t.sends[#tr.t.sends + 1] = { dest = dest.t, v = 1, p = 0 }; return #tr.t.sends - 1 end
reaper.RemoveTrackSend = function(tr, _, i) table.remove(tr.t.sends, i + 1); return true end

local function song()
  setup({
    tracks = {
      { name = "Keys", oid = "T-JAMES-1", items = { { pos = 4, len = 8, oid = "I-JAMES-1", takes = { { notes = {
          { s = 0, e = 960, k = 60, v = 100 }, { s = 960, e = 1920, k = 64, v = 90 }, { s = 1920, e = 2880, k = 67, v = 80, muted = true } },
          ccs = { { ppq = 0, c = 1, v = 10 }, { ppq = 480, c = 7, v = 100 }, { ppq = 960, c = 1, v = 60 }, { ppq = 1000, msg = 0xE0, c = 0, v = 64 } } } } } },
        envs = { { name = "Volume", chunk = "<VOLENV2", pts = { { t = 0, v = 0.5 }, { t = 8, v = 0.25 } } },
                 { name = "Pan", chunk = "<PANENV2", pts = { { t = 2, v = -0.5 } }, ais = { { pos = 2, len = 4, mute = 0 }, { pos = 10, len = 2.5, mute = 1 } } },
                 { name = "Mute", chunk = "<MUTEENV", pts = {} },
                 { name = "Cutoff / ReaEQ", fx = 0, param = 3, pts = { { t = 1, v = 1000 } } } } },
      { name = "Mine", ["local"] = true, items = {} },
      { name = "Bass", oid = "T-CHILIO-2", items = { { pos = 0, len = 4, oid = "I-CHILIO-1", takes = { { notes = { { s = 0, e = 480, k = 40, v = 100 } } } } },
          { pos = 6, len = 2, oid = "I-CHILIO-2", takes = { {} } } }, envs = { { name = "Volume", chunk = "<VOLENV2", pts = {} } } },
    },
  })
  fake.tracks[1].sends = { { dest = fake.tracks[3], v = 1, p = 0, m = false }, { dest = fake.tracks[2], v = 0.7, p = 0, m = false } } -- (Keys -> Bass, and one to this computer's own track)
  undo = {}
end
local b = { song = "S", room = "main" }
local function as(user) return { root = "R", user = user } end
local function note(user, e) return dawview.action("P", as(user), b, { topic = "daw", note = e }), dawedit.reply end
local function auto(user, e) return dawview.action("P", as(user), b, { topic = "daw", auto = e }), dawedit.reply end
local function send(user, e) return dawview.action("P", as(user), b, { topic = "daw", send = e }), dawedit.reply end
local function keys() return fake.tracks[1].items[1].takes[1].notes end
local KEYS = { lane = 0, idx = 0, p = 4, l = 8 }

-- ---- note edits -------------------------------------------------------------------------------------------------------------------------
song(); room("open", { Chilio = { tracks = { "Bass" } } })
local said, r = note("James", { id = "x1", op = "add", item = KEYS, k = 72, a = 4.6, z = 4.9, v = 110, g = 0.5 })
assert(r.id == "x1" and r.ok and #keys() == 4, "a note added: " .. tostring(r.why))
local added
for _, x in ipairs(keys()) do if x.k == 72 then added = x end end
assert(added.k == 72 and added.v == 110 and added.s == 960 and added.e == 1920, "on the grid the page snapped to (half a beat), exactly in ticks: " .. added.s .. "-" .. added.e)
assert(#undo == 1 and not undo[1].open and undo[1].label == "StudioSync web page: add note" and said:find("add note"), "in one undo point, closed")
song()
r = select(2, note("James", { op = "move", item = KEYS, n = 1, s = 960, k = 64, to = 6.1, tok = 65, g = 1 }))
local moved = keys()[3]
assert(r.ok and moved.k == 65 and moved.s == 3840 and moved.e == 4800, "moved: its new start on the grid (a beat), its length kept, a semitone up")
r = select(2, note("James", { op = "move", item = KEYS, n = 1, s = 960, k = 64, to = 6, tok = 65 }))
assert(r.why:find("note changed meanwhile") and #undo == 1, "the page's view is stale: refused, nothing changed")
r = select(2, note("James", { op = "resize", item = KEYS, n = 0, s = 0, k = 60, z = 4.2, g = 0 }))
assert(r.ok and keys()[1].e == 384, "resized, unsnapped: to the tick")
r = select(2, note("James", { op = "resize", item = KEYS, n = 0, s = 0, k = 60, z = 3, g = 0 }))
assert(r.ok and keys()[1].e == 1, "never ends before it starts")
r = select(2, note("James", { op = "vel", item = KEYS, n = 0, s = 0, k = 60, v = 33 }))
assert(r.ok and keys()[1].v == 33 and undo[#undo].label:find("note velocity"), "velocity")
r = select(2, note("James", { op = "delete", item = KEYS, n = 0, s = 0, k = 60 }))
assert(r.ok and #keys() == 2 and keys()[1].k == 67, "deleted")
-- permissions: the item's own, as stage 2's
r = select(2, note("James", { op = "add", item = { lane = 1, idx = 0, p = 0, l = 4 }, k = 40, a = 1, z = 2 }))
assert(r.why:find("Chilio has claimed Bass") and #fake.tracks[3].items[1].takes[1].notes == 1, "someone else's claimed track: refused, nothing changed: " .. tostring(r.why))
assert(select(2, note("Chilio", { op = "add", item = { lane = 1, idx = 0, p = 0, l = 4 }, k = 40, a = 1, z = 2 })).ok, "its claimant may")
r = select(2, note("Chilio", { op = "add", item = { lane = 1, idx = 1, p = 6, l = 2 }, k = 40, a = 6.5, z = 7 }))
assert(r.why:find("isn't MIDI"), "an audio item has no notes")
r = select(2, note("James", { op = "add", item = { lane = 0, idx = 0, p = 5, l = 8 }, k = 40, a = 6.5, z = 7 }))
assert(r.why:find("item changed meanwhile"), "an item that isn't where the page saw it")
peers = { { user = "Chilio", editing = { "I-JAMES-1" } } }
r = select(2, note("James", { op = "vel", item = KEYS, n = 0, s = 1920, k = 67, v = 50 }))
assert(r.ok and not r.why, "a bandmate editing it too: not refused, the two merge note by note (rt-merge): " .. tostring(r.why))
peers = {}
room("driver")
assert(select(2, note("Chilio", { op = "vel", item = KEYS, n = 0, s = 1920, k = 67, v = 50 })).why:find("only the driver"), "Driver only")
assert(select(2, note("James", { op = "vel", item = KEYS, n = 0, s = 1920, k = 67, v = 50 })).ok, "the driver may")

-- rt-p5: step input. A run of notes goes in with no undo point of its own; one "step input" point when the run ends (STEP_GAP after the last
-- note, or at once for any other edit), so one Ctrl+Z takes the run back
reaper.Undo_OnStateChangeEx2 = function(_, label) undo[#undo + 1] = { open = false, label = label } end
local valid_ptr = reaper.ValidatePtr2
reaper.ValidatePtr2 = function(pr, p, cls) if cls == "MediaItem_Take*" then return true end return valid_ptr(pr, p, cls) end
song(); room("open")
local n0 = #keys()
for i = 1, 3 do
  r = select(2, note("James", { id = "s" .. i, op = "add", item = KEYS, k = 60 + i, a = 5 + i * 0.5, z = 5.5 + i * 0.5, v = 100, g = 0, step = true }))
  assert(r.ok, "a step note goes in: " .. tostring(r.why))
  clock = clock + 0.3
end
assert(#keys() == n0 + 3 and #undo == 0, "three step notes: in, and no undo point of their own yet")
dawmidi.step_flush("P", clock) -- (the tick does this)
assert(#undo == 0, "not yet: STEP_GAP hasn't passed since the last note")
clock = clock + dawmidi.STEP_GAP
dawmidi.tick("P", as("James"), b, function() end, clock)
assert(#undo == 1 and undo[1].label == "StudioSync web page: step input (3 notes)", "the run's one undo point, made by the tick: " .. tostring(undo[1] and undo[1].label))
dawmidi.tick("P", as("James"), b, function() end, clock + 5)
assert(#undo == 1, "once")
-- any other edit ends a run first, then has its own point
song(); room("open")
note("James", { op = "add", item = KEYS, k = 70, a = 5, z = 5.5, v = 100, g = 0, step = true })
note("James", { op = "add", item = KEYS, k = 71, a = 5.5, z = 6, v = 100, g = 0, step = true })
r = select(2, note("James", { op = "vel", item = KEYS, n = 0, s = 0, k = 60, v = 40 }))
assert(r.ok and #undo == 2 and undo[1].label == "StudioSync web page: step input (2 notes)" and undo[2].label:find("note velocity"), "another edit: the run's point, then its own")
-- an add that isn't step input keeps its own point, as before
song(); room("open")
note("James", { op = "add", item = KEYS, k = 72, a = 5, z = 5.5, v = 100, g = 0 })
assert(#undo == 1 and undo[1].label == "StudioSync web page: add note", "a plain add: its own point")
-- a refused step note is refused as any (nothing in, no run begun)
song(); room("open", { Chilio = { tracks = { "Bass" } } })
r = select(2, note("James", { op = "add", item = { lane = 1, idx = 0, p = 0, l = 4 }, k = 40, a = 1, z = 2, step = true }))
assert(r.why:find("Chilio has claimed Bass") and #fake.tracks[3].items[1].takes[1].notes == 1, "a claimed track's step note: refused, nothing changed")
dawmidi.step_flush("P", clock + 100, true)
assert(#undo == 0, "and no run to end")

-- ---- envelope point edits -----------------------------------------------------------------------------------------------------------------
song(); room("open", { Chilio = { tracks = { "Bass" } } })
local vol, pan, mute, eq = table.unpack(fake.tracks[1].envs)
r = select(2, auto("James", { id = "p1", op = "add", lane = 0, e = 1, name = "Pan", t = 3.2, v = 1 }))
assert(r.id == "p1" and r.ok and #pan.pts == 2 and pan.pts[2].t == 3 and pan.pts[2].v == 1, "a pan point: snapped as REAPER snaps, full left")
assert(undo[#undo].label == "StudioSync web page: add envelope point", "one undo point")
r = select(2, auto("James", { op = "add", lane = 0, e = 0, name = "Volume", t = 4, v = 0.5 }))
assert(r.ok and vol.pts[2].t == 4 and vol.pts[2].v == 0.5, "volume: halfway across 0 to +6 dB in raw values (ScaleToEnvelopeMode's): " .. vol.pts[2].v)
r = select(2, auto("James", { op = "add", lane = 0, e = 2, name = "Mute", t = 1, v = 1 }))
assert(r.ok and mute.pts[1].shape == 1, "a mute point is square")
r = select(2, auto("James", { op = "move", lane = 0, e = 3, name = "Cutoff / ReaEQ", n = 0, t = 1, to = 2.4, v = 0.5 }))
assert(r.ok and eq.pts[1].t == 2.5 and eq.pts[1].v == 10010, "an FX parameter, across its own range: " .. eq.pts[1].v)
r = select(2, auto("James", { op = "move", lane = 0, e = 3, name = "Cutoff / ReaEQ", n = 0, t = 1, to = 3, v = 0.5 }))
assert(r.why:find("point changed meanwhile") and eq.pts[1].t == 2.5, "a stale point: refused")
r = select(2, auto("James", { op = "delete", lane = 0, e = 1, name = "Volume", n = 0, t = 2 }))
assert(r.why:find("envelope changed meanwhile") and #pan.pts == 2, "an envelope named wrongly: refused")
r = select(2, auto("James", { op = "delete", lane = 0, e = 1, name = "Pan", n = 0, t = 2 }))
assert(r.ok and #pan.pts == 1 and pan.pts[1].t == 3, "deleted")
r = select(2, auto("James", { op = "add", lane = 1, e = 0, name = "Volume", t = 1, v = 0.5 }))
assert(r.why:find("Chilio has claimed Bass") and #fake.tracks[3].envs[1].pts == 0, "a claimed track's automation is its claimant's")
assert(select(2, auto("Chilio", { op = "add", lane = 1, e = 0, name = "Volume", t = 1, v = 0.5 })).ok, "the claimant's")
peers = { { user = "Chilio", editing = { "E-JAMES-1" } } }
r = select(2, auto("James", { op = "add", lane = 0, e = 1, name = "Pan", t = 5, v = 0.5 }))
assert(r.ok and #pan.pts == 2, "a bandmate editing the track's automation too: not refused, the two merge point by point (rt-merge): " .. tostring(r.why))
peers = {}
room("claims") -- (Driver + claims, removed in rt: works as Driver only)
assert(select(2, auto("Andie", { op = "add", lane = 0, e = 1, name = "Pan", t = 1, v = 0.5 })).why:find("only the driver"), "Driver + claims reads as Driver only")

-- ---- controller edits ---------------------------------------------------------------------------------------------------------------------
local function ccs() return fake.tracks[1].items[1].takes[1].ccs end
song(); room("open", { Chilio = { tracks = { "Bass" } } })
said, r = note("James", { id = "k1", op = "cc_add", item = KEYS, c = 1, a = 5, v = 90, g = 0 })
assert(r.id == "k1" and r.ok and #ccs() == 5 and said:find("add controller point"), "a controller point added: " .. tostring(r.why))
local made
for _, x in ipairs(ccs()) do if x.v == 90 then made = x end end
assert(made and made.c == 1 and made.msg == 0xB0 and made.ch == 0 and made.ppq == 1920, "a CC (0xB0) number 1, at the ticks of 5 s in an item starting at 4 s (1920 a second here)")
assert(#undo == 1 and undo[1].label == "StudioSync web page: add controller point" and not undo[1].open, "in one undo point")
r = select(2, note("James", { op = "cc_move", item = KEYS, c = 1, n = 2, s = 960, to = 6.1, v = 30, g = 1 }))
assert(r.ok, "moved: " .. tostring(r.why))
local mv
for _, x in ipairs(ccs()) do if x.v == 30 then mv = x end end
assert(mv and mv.ppq == 3840 and mv.c == 1, "its new time on the grid the page snapped to (a beat), its new value")
r = select(2, note("James", { op = "cc_move", item = KEYS, c = 1, n = 2, s = 960, to = 6, v = 31 }))
assert(r.why:find("controller point changed meanwhile"), "the page's view is stale: refused")
r = select(2, note("James", { op = "cc_delete", item = KEYS, c = 7, n = 0, s = 0 }))
assert(r.why:find("controller point changed meanwhile") and #ccs() == 5, "named for another controller number: refused")
r = select(2, note("James", { op = "cc_delete", item = KEYS, c = 1, n = 3, s = 1000 }))
assert(r.why:find("controller point changed meanwhile") and #ccs() == 5, "a pitch bend isn't a CC: refused")
r = select(2, note("James", { op = "cc_delete", item = KEYS, c = 7, n = 1, s = 480 }))
assert(r.ok and #ccs() == 4 and undo[#undo].label == "StudioSync web page: delete controller point", "deleted")
r = select(2, note("James", { op = "cc_add", item = { lane = 1, idx = 0, p = 0, l = 4 }, c = 1, a = 1, v = 5 }))
assert(r.why:find("Chilio has claimed Bass") and not fake.tracks[3].items[1].takes[1].ccs, "a claimed track's item: refused, nothing changed")
room("driver")
r = select(2, note("Andie", { op = "cc_add", item = KEYS, c = 1, a = 5, v = 5 }))
assert(r.why:find("only the driver %(James%)"), "Driver only: refused")
room("open")

-- ---- automation item edits ----------------------------------------------------------------------------------------------------------------
song(); room("open", { Chilio = { tracks = { "Bass" } } })
local pais = fake.tracks[1].envs[2].ais
r = select(2, auto("James", { id = "q1", op = "ai_move", lane = 0, e = 1, name = "Pan", n = 0, t = 2, to = 3.2 }))
assert(r.id == "q1" and r.ok and pais[1].pos == 3 and pais[1].len == 4 and undo[#undo].label == "StudioSync web page: move automation item" and not undo[#undo].open, "moved, snapped as REAPER snaps, in one undo point: " .. tostring(r.why))
r = select(2, auto("James", { op = "ai_move", lane = 0, e = 1, name = "Pan", n = 0, t = 2, to = 5 }))
assert(r.why:find("automation item changed meanwhile") and pais[1].pos == 3, "the page's view is stale: refused")
r = select(2, auto("James", { op = "ai_move", lane = 0, e = 1, name = "Pan", n = 2, t = 10, to = 5 }))
assert(r.why:find("automation item changed meanwhile"), "no such item: refused")
r = select(2, auto("James", { op = "ai_move", lane = 0, e = 0, name = "Pan", n = 0, t = 3, to = 5 }))
assert(r.why:find("envelope changed meanwhile"), "an envelope named wrongly: refused")
r = select(2, auto("James", { op = "ai_resize", lane = 0, e = 1, name = "Pan", n = 0, t = 3, len = 3.2 }))
assert(r.ok and pais[1].len == 3 and undo[#undo].label == "StudioSync web page: resize automation item", "resized: the end snapped (3 + 3.2 -> 6), as a trimmed item's")
r = select(2, auto("James", { op = "ai_resize", lane = 0, e = 1, name = "Pan", n = 1, t = 10, len = 0.1 }))
assert(r.ok and pais[2].len == dawedit.MIN_LEN, "never shorter than MIN_LEN")
r = select(2, auto("James", { op = "ai_mute", lane = 0, e = 1, name = "Pan", n = 1, t = 10, on = false }))
assert(r.ok and pais[2].mute == 0 and undo[#undo].label == "StudioSync web page: unmute automation item", "unmuted")
r = select(2, auto("James", { op = "ai_mute", lane = 0, e = 1, name = "Pan", n = 0, t = 3, on = true }))
assert(r.ok and pais[1].mute == 1 and undo[#undo].label == "StudioSync web page: mute automation item", "muted")
fake.tracks[3].envs[1].ais = { { pos = 1, len = 1, mute = 0 } }
r = select(2, auto("James", { op = "ai_move", lane = 1, e = 0, name = "Volume", n = 0, t = 1, to = 2 }))
assert(r.why:find("Chilio has claimed Bass") and fake.tracks[3].envs[1].ais[1].pos == 1, "a claimed track's automation items are its claimant's")
assert(select(2, auto("Chilio", { op = "ai_move", lane = 1, e = 0, name = "Volume", n = 0, t = 1, to = 2 })).ok and fake.tracks[3].envs[1].ais[1].pos == 2, "the claimant's")
room("claims")
assert(select(2, auto("Andie", { op = "ai_mute", lane = 0, e = 1, name = "Pan", n = 0, t = 3, on = false })).why:find("only the driver"), "Driver + claims reads as Driver only")

-- ---- send edits ---------------------------------------------------------------------------------------------------------------------------
song(); room("open", { Chilio = { tracks = { "Bass" } } })
said, r = send("James", { id = "t1", op = "vol", lane = 0, to = 1, i = 0, v = 0.5 })
assert(r.id == "t1" and r.why and r.why:find("Chilio has claimed Bass") and fake.tracks[1].sends[1].v == 1 and #undo == 0, "a send to a track a bandmate claimed: refused, nothing changed (the receive is the destination's): " .. tostring(r.why))
assert(said:find("wasn't made"), "and the log says so")
r = select(2, send("Chilio", { op = "vol", lane = 0, to = 1, i = 0, v = 0.5 }))
assert(r.ok and fake.tracks[1].sends[1].v == 0.5 and #undo == 1 and undo[1].label == "StudioSync web page: send level Bass" and not undo[1].open, "its claimant sets the level in one undo point")
song(); room("open")
r = select(2, send("James", { op = "pan", lane = 0, to = 1, i = 0, p = -0.25 }))
assert(r.ok and fake.tracks[1].sends[1].p == -0.25 and undo[1].label == "StudioSync web page: send pan Bass", "pan")
r = select(2, send("James", { op = "mute", lane = 0, to = 1, i = 0, on = true }))
assert(r.ok and fake.tracks[1].sends[1].m == true, "mute")
r = select(2, send("James", { op = "mute", lane = 0, to = 1, i = 0, on = false }))
assert(r.ok and fake.tracks[1].sends[1].m == false, "and unmute")
r = select(2, send("James", { op = "vol", lane = 0, to = 0, i = 0, v = 1 }))
assert(r.why:find("send changed meanwhile") and #undo == 3, "the send isn't to the track the page said: refused")
r = select(2, send("James", { op = "vol", lane = 0, to = 1, i = 5, v = 1 }))
assert(r.why:find("send changed meanwhile"), "no such send: refused")
r = select(2, send("James", { op = "add", lane = 1, to = 0 }))
assert(r.ok and #fake.tracks[3].sends == 1 and fake.tracks[3].sends[1].dest == fake.tracks[1] and undo[#undo].label == "StudioSync web page: add send to Keys", "a send added: Bass to Keys")
r = select(2, send("James", { op = "add", lane = 1, to = 1 }))
assert(r.why:find("can't send to itself") and #fake.tracks[3].sends == 1, "not to itself")
r = select(2, send("James", { op = "add", lane = 7, to = 0 }))
assert(r.why:find("track changed meanwhile"), "a track that isn't there")
r = select(2, send("James", { op = "remove", lane = 0, to = 1, i = 0 }))
assert(r.ok and #fake.tracks[1].sends == 1 and fake.tracks[1].sends[1].dest == fake.tracks[2] and undo[#undo].label == "StudioSync web page: remove send Bass", "removed (the one to this computer's own track stays)")
room("driver")
r = select(2, send("Andie", { op = "add", lane = 1, to = 0 }))
assert(r.why:find("only the driver %(James%)") and #fake.tracks[3].sends == 1, "Driver only: refused")
room("open")
song()
dawedit.reply = nil
send("James", { id = "t2", op = "vol", lane = 0, to = 1, i = 0, v = 2 })
assert(dawedit.reply.ok and fake.tracks[1].sends[1].v == 2, "+6 dB")
r = select(2, send("James", { id = "t3", op = "vol", lane = 0, to = 1, i = 0, v = 9 }))
assert(r.id == "t3" and r.why and fake.tracks[1].sends[1].v == 2, "past +12 dB: refused, and the answer names the edit")

-- ---- what the page is sent: only while it looks, only the open item and the open tracks ----------------------------------------------
song(); room("open")
local published = {}
local function pub(topic, t) published[topic] = t end
local function tick() dawview.tick("P", as("James"), b, pub, { mode = "open", driver = "James" }, clock) end
reaper.GetProjectLength = function() return 60 end
reaper.TimeMap_GetMeasureInfo = function(_, m) return m * 2, 0, 0, 4, 4, 120 end
reaper.GetSetProjectGrid = function() return 0, 0.25 end
reaper.GetSet_ArrangeView2 = function() return 0, 30 end
reaper.Master_GetPlayRate = function() return 1 end
reaper.GetPlayStateEx = function() return 0 end
reaper.GetCursorPositionEx = function() return 0 end
reaper.GetMediaItemTake_Peaks = function() return 0 end -- (the audio item's peaks: stage 1's test)
reaper.new_array = function() return { table = function() return {} end } end
reaper.EnumProjectMarkers3 = function() return 0 end
reaper.CountTempoTimeSigMarkers = function() return 0 end
reaper.TimeMap_GetTimeSigAtTime = function() return 4, 4, 120 end
dawview.action("P", as("James"), b, { want = true })
tick()
assert(not published.dawmidi and not published.dawenv, "nothing of stage 3's until a page opens something")
assert(published.daw.tracks[1].e == 4 and published.daw.tracks[2].e == 1, "the header says which tracks have envelopes")
dawview.action("P", as("James"), b, { look = { item = KEYS, env = { 0 } } })
tick()
local m = published.dawmidi
assert(m and m.ref.lane == 0 and m.ref.p == 4 and m.track == "Keys" and m.name == "Riff" and #m.nt == 18, "the open item's notes, six numbers each")
assert(m.nt[1] == 0 and m.nt[2] == 500 and m.nt[3] == 60 and m.nt[4] == 100 and m.nt[5] == 0 and m.nt[6] == 0 and m.nt[18] == 1, "start and length in ms, pitch, velocity, ticks, muted")
local ev = published.dawenv.lanes
assert(#ev == 1 and ev[1].lane == 0 and #ev[1].env == 4, "only the open track's envelopes")
local v1, p1, m1, f1 = table.unpack(ev[1].env)
assert(v1.k == "vol" and v1.p[2] == 0.5 and v1.p[5] == 0.25 and v1.i == 0, "volume points across its raw range (0.5 raw of 0 to 1 raw)")
assert(p1.k == "pan" and p1.p[2] == 0.25 and m1.k == "mute" and f1.k == "fx" and f1.n == "Cutoff / ReaEQ", "pan -0.5 is a quarter up; kinds by chunk name, then FX")
assert(#p1.a == 6 and p1.a[1] == 2 and p1.a[2] == 4 and p1.a[3] == 0 and p1.a[4] == 10 and p1.a[5] == 2.5 and p1.a[6] == 1 and v1.a == nil, "an envelope's automation items: place, length, muted; none: no key")
assert(#v1.f == dawmidi.LABELS + 1 and v1.f[1] == "Volume 0.00" and v1.f[#v1.f] == "Volume 1.00", "REAPER's own labels across the range")
-- the controllers (rt-p14): which numbers the item has, and the events of the one asked for
assert(m.ccs and #m.ccs == 2 and m.ccs[1] == 1 and m.ccs[2] == 7 and m.cc == nil, "the CC numbers it has (a pitch bend isn't one); no events until a lane is asked for")
dawview.action("P", as("James"), b, { look = { item = KEYS, cc = 1 } })
published.dawmidi = nil
clock = clock + 1
tick()
m = published.dawmidi
assert(m and m.cc and m.cc.c == 1 and #m.cc.ev == 10, "a CC lane asked for: its events, five numbers each")
assert(m.cc.ev[1] == 0 and m.cc.ev[2] == 0 and m.cc.ev[3] == 10 and m.cc.ev[4] == 0 and m.cc.ev[5] == 0 and m.cc.ev[6] == 2 and m.cc.ev[7] == 500 and m.cc.ev[8] == 60 and m.cc.ev[9] == 960,
  "index among the take's controller events (the number 7 one is between them), ms from the item's start, value, ticks, channel")
published.dawmidi = nil
clock = clock + 1
tick()
assert(not published.dawmidi, "nothing changed: not sent again")
fake.tracks[1].items[1].takes[1].ccs[1].v = 11
clock = clock + 1
tick()
assert(published.dawmidi and published.dawmidi.cc.ev[3] == 11, "a controller changed in REAPER (the notes the same): sent again")
dawview.action("P", as("James"), b, { look = { item = KEYS, cc = 7 } })
published.dawmidi = nil
clock = clock + 1
tick()
assert(published.dawmidi.cc.c == 7 and #published.dawmidi.cc.ev == 5 and published.dawmidi.cc.ev[1] == 1 and published.dawmidi.cc.ev[3] == 100, "another number asked for: its events at once")
dawview.action("P", as("James"), b, { look = { item = KEYS, cc = false } })
published.dawmidi = nil
clock = clock + 1
tick()
assert(published.dawmidi and published.dawmidi.cc == nil and published.dawmidi.ccs, "the lane closed: no events, the numbers still")
fake.tracks[1].items[1].takes[1].ccs[1].v = 10
-- the item moves (a stage 2 edit, or in REAPER): followed, and named where it is now
published.dawmidi = nil
fake.tracks[1].items[1].pos = 6
clock = clock + 1
tick()
assert(published.dawmidi and published.dawmidi.ref.p == 6, "followed after it moved: the page's next edits name it there")
dawview.action("P", as("James"), b, { look = { item = { lane = 0, idx = 0, p = 4, l = 8 } } })
published.dawmidi = nil
clock = clock + 1
tick()
assert(not published.dawmidi, "nothing changed: nothing sent again")
keys()[1].v = 101
clock = clock + 1
tick()
assert(published.dawmidi and published.dawmidi.ref.p == 6 and published.dawmidi.nt[4] == 101, "a look naming it where it was still means it")
-- an edit answers through stage 2's topic, and the notes come again at once
note("James", { id = "z1", op = "delete", item = { lane = 0, idx = 0, p = 6, l = 8 }, n = 0, s = 0, k = 60 })
tick()
assert(published.dawedit.id == "z1" and published.dawedit.ok and #published.dawmidi.nt == 12, "answered, and the notes resent")
-- closed: not built any more; looks run out
dawview.action("P", as("James"), b, { look = { item = false, env = {} } })
published = {}
clock = clock + 1
tick()
assert(not published.dawmidi and not published.dawenv, "closed: nothing built")
dawview.action("P", as("James"), b, { look = { env = { 1 } } })
clock = clock + dawmidi.WANT_FOR + 1
dawview.action("P", as("James"), b, { want = true })
tick()
assert(not published.dawenv, "a look runs out after WANT_FOR without the page saying it again")
-- the sends panel (rt-p14): its track's sends only, to the shown tracks only, while the page looks
dawview.action("P", as("James"), b, { look = { item = false, env = {} } })
published = {}
clock = clock + 1
tick()
assert(not published.dawsend, "nothing of the sends until a page opens a track's")
dawview.action("P", as("James"), b, { look = { send = 0 } })
tick()
local sd = published.dawsend
assert(sd and sd.lane == 0 and sd.name == "Keys" and #sd.sends == 1, "the open track's sends: the one to this computer's own track isn't shown")
assert(sd.sends[1].i == 0 and sd.sends[1].to == 1 and sd.sends[1].n == "Bass" and sd.sends[1].v == 1 and sd.sends[1].p == 0 and sd.sends[1].m == nil, "index, destination place and name, level, pan")
published.dawsend = nil
fake.tracks[1].sends[1].m = true
clock = clock + 1
tick()
assert(published.dawsend and published.dawsend.sends[1].m == 1, "a send muted in REAPER: sent again")
send("James", { id = "t4", op = "vol", lane = 0, to = 1, i = 0, v = 0.5 })
tick()
assert(published.dawedit.id == "t4" and published.dawsend.sends[1].v == 0.5, "an edit is answered and the sends come again at once")
dawview.action("P", as("James"), b, { look = { send = false } })
published = {}
clock = clock + 1
tick()
assert(not published.dawsend, "closed: not built")
dawview.action("P", as("James"), b, { look = { send = 0 } })
clock = clock + dawmidi.WANT_FOR + 1
dawview.action("P", as("James"), b, { want = true })
tick()
assert(not published.dawsend, "a look runs out after WANT_FOR")
-- a deleted item: said once
dawview.action("P", as("James"), b, { look = { item = KEYS } })
fake.tracks[1].items = {}
clock = clock + 1
tick()
assert(published.dawmidi and published.dawmidi.gone, "the open item gone: the page hears so")

-- ---- the pages: there, linked, and talking to the topics above ----------------------------------------------------------------------------
local function read(path) local f = assert(io.open(path, "rb"), path); local s = f:read("a"); f:close(); return s end
local html, daw, pr, al, css = read("lib/webui/index.html"), read("lib/webui/daw.js"), read("lib/webui/pianoroll.js"), read("lib/webui/autolanes.js"), read("lib/webui/daw.css")
assert(html:find('<script src="daw.js" defer></script>', 1, true) < html:find('<script src="pianoroll.js" defer></script>', 1, true)
  and html:find('<script src="pianoroll.js" defer></script>', 1, true) < html:find('<script src="autolanes.js" defer></script>', 1, true), "index.html: after daw.js, whose hooks they fill")
for _, want in ipairs({ "window.ssDaw", "X.extra", "X.drawAuto", "X.autoDown", "X.autoMove", "X.autoUp", "X.autoTap", "X.autoAdd", "X.autoMenu", "X.openMidi", "X.header", "laneY(", "trackAt(" }) do
  assert(daw:find(want, 1, true), "daw.js has " .. want)
end
for _, want in ipairs({ "ssDaw.act({ look:", "note: Object.assign({ id }", "t.dawmidi", "t.dawedit", "op: 'add'", "op: 'move'", "op: 'resize'", "op: 'delete'", "op: 'vel'",
    "pointerdown", "'wheel'", "'keydown'", "setTimeout(", "snapBack(",
    "op: 'cc_add'", "op: 'cc_delete'", "'cc_move'", "function drawCC(g, C, col, top)", "look: { item: want || false, cc: ccN === null ? false : ccN }", "step: true" }) do
  assert(pr:find(want, 1, true), "pianoroll.js has " .. want)
end
for _, want in ipairs({ "ssDaw.act({ look:", "auto: Object.assign({ id }", "t.dawenv", "t.dawedit", "op: 'add'", "op: 'move'", "op: 'delete'", "X.extra =", "X.drawAuto =",
    "op: 'ai_move'", "op: 'ai_resize'", "op: 'ai_mute'", "function aiAt(L, x, y, touch)", "aiOvr", "'Mute automation item'" }) do
  assert(al:find(want, 1, true), "autolanes.js has " .. want)
end
for _, want in ipairs({ "act({ look: { send: sendLane } })", "act({ send: Object.assign({ id, lane: sendLane }, o) })", "T.dawsend", "t.dawsend", "add('Sends…'", "bSends.addEventListener",
    "op: 'vol'", "op: 'pan'", "op: 'mute'", "op: 'remove'", "op: 'add', to:" }) do
  assert(daw:find(want, 1, true), "daw.js has " .. want)
end
assert(not daw:find("innerHTML%s*=%s*[^'\n]*%+"), "daw.js puts no data in as HTML")
assert(not (pr .. al):find("innerHTML%s*=%s*[^'\n]*%+"), "no data put in as HTML")
assert(css:find(".proll", 1, true) and css:find("touch-action: none", 1, true), "the piano roll is styled and takes touches")
print("ok")
