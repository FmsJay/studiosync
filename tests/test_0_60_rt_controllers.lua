-- Shared controllers (lib/controllers.lua; roadmap More big ideas 5): what a ctl message may carry, holds, a plug-in's place in the band's chain;
-- then two stand-in REAPERs, James's and Bo's, with a message pump between them: a fader move streams and shows, at most every RATE s; nothing
-- echoes back (a shown move, the band's own change); let go; the band's change confirms it, or the value before it comes back; two on one
-- control (the first holds it, the other's goes back, said once); a move that isn't theirs refused; Hold my changes, Local mixing and
-- automation writing; a plug-in knob, with a translation of James's own in his chain; the setting off; and mirror.watch leaving a shown
-- track alone. (James, rt)
package.path = "lib/?.lua;" .. package.path
local clock = 100
local function world(user)
  local function T(name, oid, fx) return { name = name, oid = oid, vol = 1, pan = 0, mute = 0, auto = 0, ext = {}, fx = fx or {} } end
  local w = { user = user, ext = {}, projext = {}, front = "P", playing = false, cc = 1, out = {}, logs = {}, touched = { false },
    rev = {}, unsent = {}, previewing = {}, off = false }
  w.tracks = { T("Bass", "T-JAMES-1-1", { { guid = "{EQ}", name = "VST: ReaEQ", p = { 0.1, 0.2, 0.3, 0.4 } } }), T("Keys", "T-BO-1-2") }
  w.mirror = { track_oid = function(tr) return tr.oid end, local_track = function(tr) return tr.here == true end,
    find = function(_, _, oid) for _, tr in ipairs(w.tracks) do if tr.oid == oid then return tr end end end,
    known = function(_, oid) return w.rev[oid] or 1 end, unsent = w.unsent, previewing = w.previewing }
  w.pass = { can = function() return true end, my_can = function() return true end, who = { mode = "open" }, hold = false }
  return w
end
local A, B = world("James"), world("Bo")
local cur = A
local PARM = { D_VOL = "vol", D_PAN = "pan", B_MUTE = "mute" }
reaper = setmetatable({
  time_precise = function() return clock end,
  GetExtState = function(_, k) return cur.ext[k] or "" end,
  SetExtState = function(_, k, v) cur.ext[k] = v end,
  GetProjExtState = function(_, _, k) return 1, cur.projext[k] or "" end,
  EnumProjects = function() return cur.front end,
  GetPlayStateEx = function() return cur.playing and 1 or 0 end,
  GetProjectStateChangeCount = function() return cur.cc end,
  CountTracks = function() return #cur.tracks end,
  GetTrack = function(_, i) return cur.tracks[i + 1] end,
  ValidatePtr2 = function(_, x) return x ~= nil and not x.gone end,
  GetMediaTrackInfo_Value = function(tr, k) return tr[PARM[k]] end,
  SetMediaTrackInfo_Value = function(tr, k, v) tr[PARM[k]] = v end,
  GetSetMediaTrackInfo_String = function(tr, k, v, set)
    if k == "P_NAME" then return true, tr.name end
    local e = k:match("^P_EXT:(.+)$")
    if set then tr.ext[e] = v end
    return true, tr.ext[e] or ""
  end,
  GetGlobalAutomationOverride = function() return -1 end,
  GetTrackAutomationMode = function(tr) return tr.auto end,
  GetTouchedOrFocusedFX = function() return table.unpack(cur.touched) end,
  TrackFX_GetCount = function(tr) return #tr.fx end,
  TrackFX_GetFXGUID = function(tr, i) return tr.fx[i + 1].guid end,
  TrackFX_GetFXName = function(tr, i) return true, tr.fx[i + 1].name end,
  TrackFX_GetNumParams = function(tr, i) return #tr.fx[i + 1].p end,
  TrackFX_GetParamNormalized = function(tr, i, n) return tr.fx[i + 1].p[n + 1] end,
  TrackFX_SetParamNormalized = function(tr, i, n, v) tr.fx[i + 1].p[n + 1] = v end,
  TrackFX_GetNamedConfigParm = function() return true, "0" end,
  GetFXEnvelope = function() return nil end,
  GetOS = function() return "Win64" end, GetExePath = function() return "C:/REAPER" end, GetResourcePath = function() return "C:/res" end,
}, { __index = function(_, k) error("fake reaper has no " .. tostring(k)) end })
local band = require("band")
band.log = function(s) cur.logs[#cur.logs + 1] = s end
package.loaded.mirror = setmetatable({}, { __index = function(_, k) return cur.mirror[k] end })
package.loaded.groups = { trusted = function() if cur.off then return { shared_controllers = false } end return {} end }
package.loaded.sync = { maker_may = function() return false end }
package.loaded.direct = { live_available = function() return true end, peers = function() return { "peer" } end, shared_now = function() return clock end,
  behind = function() return cur.behind == true end,
  send_live = function(_, kind, d, song, room) cur.out[#cur.out + 1] = { kind = kind, d = band.json_decode(band.json_encode(d)), song = song, room = room } end }
-- (one controllers per computer: its state is the module's)
package.loaded.controllers = nil
local CA = require("controllers")
package.loaded.controllers = nil
local CB = require("controllers")
local C = CA
local cfgA, cfgB, b = { root = "R", user = "James" }, { root = "R", user = "Bo" }, { song = "S", room = "main" }
local function on(w) cur = w; local c = w == A and CA or CB; c.pass = w.pass; return c, w == A and cfgA or cfgB end
-- One Live sync tick on that computer: its link's messages first (from the other), then the tick, then settle.
local function tick(w, during)
  local c, cfg = on(w)
  local other = w == A and B or A
  for _, m in ipairs(other.out) do if m.kind == "ctl" then c.on_msg("P", cfg, b, m.d) end end
  other.out = {}
  c.tick("P", cfg, b)
  if during then during() end -- (what the rest of the tick does: a receive pass, say)
  c.settle("P")
end
local function sent(w) local n = 0 for _, m in ipairs(w.out) do n = n + #m.d.m end return n end
local BASS, KEYS = "T-JAMES-1-1", "T-BO-1-2"

-- ---- 1. what a message may carry, holds, chains --------------------------------------------------------------------------------------------
local ok1 = C.clean({ user = "Bo", m = { { o = BASS, k = "v", v = 0.5, s = 10 }, { o = BASS, k = "x", f = 0, n = 2, v = 1, s = 10, g = 1 } } }, "James")
assert(ok1 and #ok1.m == 2 and ok1.m[1].v == 0.5 and ok1.m[2].f == 0 and ok1.m[2].g == true and ok1.m[1].g == false, "a message, cleaned")
assert(C.clean({ user = "James", m = { { o = BASS, k = "v", v = 1, s = 1 } } }, "James") == nil, "never your own")
assert(C.clean({ user = "Bo", m = { { o = BASS, k = "s", v = 1, s = 1 } } }, "James") == nil, "solo isn't a control here")
assert(C.clean({ user = "Bo", m = { { o = BASS, k = "v", v = 99, s = 1 } } }, "James") == nil and C.clean({ user = "Bo", m = { { o = BASS, k = "p", v = -2, s = 1 } } }, "James") == nil, "out of range: dropped")
assert(C.clean({ user = "Bo", m = { { o = BASS, k = "v", v = 0 / 0, s = 1 } } }, "James") == nil, "not a number: dropped")
assert(C.clean({ user = "Bo", m = { { o = "F-x", k = "v", v = 1, s = 1 } } }, "James") == nil and C.clean({ user = "Bo", m = { { o = "T-MASTER/x", k = "v", v = 1, s = 1 } } }, "James") == nil, "only a track's oid")
assert(C.clean({ user = "Bo", m = { { o = BASS, k = "x", v = 1, s = 1 } } }, "James") == nil and C.clean({ user = "Bo", m = { { o = BASS, k = "x", f = 1.5, n = 0, v = 1, s = 1 } } }, "James") == nil, "a knob needs whole f and n")
local many = {}
for i = 1, C.MAX + 1 do many[i] = { o = BASS, k = "v", v = 1, s = 1 } end
assert(C.clean({ user = "Bo", m = many }, "James") == nil and C.clean({ user = "Bo", m = {} }, "James") == nil, "too many or none: dropped")
assert(C.key({ o = BASS, k = "x", f = 1, n = 3 }) == BASS .. "|x1:3" and C.object({ o = BASS, k = "x" }) == "F-JAMES-1-1" and C.object({ o = BASS, k = "m" }) == BASS, "keys and objects")
assert(C.wins({ user = "Zed", s = 1 }, { user = "Al", s = 2 }) and C.wins({ user = "Al", s = 2 }, { user = "Zed", s = 2 }) and not C.wins({ user = "Zed", s = 2 }, { user = "Al", s = 2 }), "the earlier start, then the name")
local chain, lfx = { "{L}", "{EQ}", "{C}" }, "{L}for={EQ};"
assert(C.band_fx(chain, lfx, 0) == nil and C.band_fx(chain, lfx, 1) == 0 and C.band_fx(chain, lfx, 2) == 1, "your own plug-in has no place in the band's chain")
assert(C.here_fx(chain, lfx, 0) == 1 and C.here_fx(chain, lfx, 1) == 2 and C.here_fx(chain, lfx, 2) == nil and C.here_fx({ "{EQ}" }, "", 0) == 0, "and back")
assert(C.words("Bass", "v") == "Bass volume" and C.words("Bass", "x", "VST: ReaEQ", 2) == "Bass VST: ReaEQ knob 3", "words")

-- ---- 2. a fader move streams and shows; rate; no echo -------------------------------------------------------------------------------------
tick(A); tick(B)
assert(sent(A) == 0 and sent(B) == 0, "the first reading isn't a move")
A.tracks[1].vol = 0.5
clock = clock + 0.06
tick(A)
assert(sent(A) == 1 and A.out[1].kind == "ctl" and A.out[1].d.m[1].k == "v" and A.out[1].d.m[1].v == 0.5 and A.out[1].d.user == "James" and A.out[1].song == "S", "James's fader goes")
tick(B)
assert(B.tracks[1].vol == 0.5 and B.previewing["P" .. BASS], "and moves on Bo's, the track held from the mirror meanwhile")
tick(B)
assert(sent(B) == 0, "what came in isn't Bo's move: no echo")
A.tracks[1].vol = 0.6
clock = clock + 0.02
tick(A)
assert(sent(A) == 0, "not again within RATE")
clock = clock + 0.06
tick(A)
assert(sent(A) == 1 and A.out[1].d.m[1].v == 0.6, "after RATE: the latest value")
tick(B)
assert(B.tracks[1].vol == 0.6, "shown")
-- the band's own change landing on Bo's in a receive pass isn't Bo moving it
clock = clock + 0.06
tick(B, function() B.tracks[1].mute = 1; B.cc = B.cc + 1 end)
clock = clock + 0.06
tick(B)
assert(sent(B) == 0, "a receive pass's writes aren't moves (settle)")
B.tracks[1].mute = 0; B.cc = B.cc + 1
tick(B, function() end)

-- ---- 3. let go; the band's change confirms it, or the value before comes back ----------------------------------------------------------
clock = clock + CA.LET_GO + 0.01
tick(A)
assert(sent(A) == 1 and A.out[1].d.m[1].g == 1, "let go after LET_GO")
tick(B)
assert(next(CB.state.theirs) == nil and B.previewing["P" .. BASS], "Bo: James let go, the track still held till his change lands")
B.rev[BASS] = 2 -- (James's change, from the normal sync)
clock = clock + 0.06
tick(B)
assert(not B.previewing["P" .. BASS] and B.tracks[1].vol == 0.6 and #B.logs == 0, "confirmed: the track is the mirror's again, nothing put back")
A.tracks[1].vol = 0.9
clock = clock + 0.06
tick(A); tick(B)
assert(B.tracks[1].vol == 0.9, "a new move shown")
clock = clock + CA.LET_GO + 0.01
tick(A); tick(B)
clock = clock + CB.CONFIRM + 1
tick(B)
assert(B.tracks[1].vol == 0.6 and not B.previewing["P" .. BASS] and B.logs[#B.logs]:find("put back"), "no change from James in CONFIRM s: the value before it is back")
clock = clock + 0.06
tick(B)
assert(sent(B) == 0, "and the put-back isn't Bo's move")

-- ---- 4. two on one control: the first holds it ---------------------------------------------------------------------------------------------
A.tracks[1].pan = -0.5
clock = clock + 0.06
tick(A) -- (James starts first: his hold's start is earlier)
local james_pan = A.out
A.out = {}
clock = clock + 0.01
B.tracks[1].pan = 0.5
on(B); CB.tick("P", cfgB, b); CB.settle("P") -- (Bo starts a moment later, before James's move reaches him)
assert(sent(B) == 1, "Bo's move went too")
A.out = james_pan
clock = clock + 0.06
tick(B) -- (James's arrives at Bo's: James holds it)
assert(B.tracks[1].pan == -0.5 and CB.state.theirs[BASS .. "|p"].user == "James", "Bo's REAPER takes James's: his started first")
tick(A) -- (Bo's arrives at James's: refused, James holds it)
assert(A.tracks[1].pan == -0.5, "James's REAPER keeps his own")
B.tracks[1].pan = 0.8
clock = clock + 0.06
tick(B)
assert(B.tracks[1].pan == -0.5 and sent(B) == 0 and B.logs[#B.logs]:find("James has Bass pan"), "Bo moving it again: back to James's, said")
local said = #B.logs
B.tracks[1].pan = 0.7
clock = clock + 0.06
tick(B)
assert(#B.logs == said, "said once")
clock = clock + CA.HELD + 0.1 -- (James let go: his let-go and his hold end)
tick(A); tick(B)
B.tracks[1].pan = 0.3
clock = clock + 0.06
tick(B)
assert(B.tracks[1].pan == 0.3 and sent(B) == 1, "free again: Bo's move goes")
B.out = {}
clock = clock + CB.LET_GO + 0.01
tick(B); B.out = {}
B.rev[BASS] = 3
clock = clock + CB.CONFIRM + 1
tick(A); tick(B)

-- ---- 5. permissions, Hold my changes, Local mixing, automation ---------------------------------------------------------------------------
B.pass.can = function(user, name) return not (user == "James" and name == "Keys") end -- (Keys is Bo's: claimed)
A.tracks[2].vol = 0.3
clock = clock + 0.06
tick(A)
assert(sent(A) == 1, "James's REAPER thinks he may (a claim still on its way)")
tick(B)
assert(B.tracks[2].vol == 1 and not B.previewing["P" .. KEYS] and CB.state.n_refused == 1 and B.logs[#B.logs]:find("isn't theirs"), "Bo's refuses it: not shown")
A.pass.my_can = function(_, name) return name ~= "Keys" end
A.tracks[2].vol = 0.2
clock = clock + 0.06
tick(A)
assert(sent(A) == 0, "a move that isn't yours never goes")
A.out = {}
A.pass.my_can, B.pass.can = function() return true end, function() return true end
A.pass.hold = true
A.tracks[1].vol = 0.4
clock = clock + 0.06
tick(A)
assert(sent(A) == 0, "Hold my changes: nothing goes")
A.pass.hold = false
A.projext.local_mix = "1"
A.tracks[1].vol, A.tracks[1].mute = 0.45, 1
clock = clock + 0.06
tick(A)
assert(sent(A) == 1 and A.out[1].d.m[1].k == "m", "Local mixing: your fader stays yours, the mute goes")
A.projext.local_mix = nil
B.projext.local_mix = "1"
A.tracks[1].vol = 0.55
clock = clock + 0.06
tick(A); tick(B)
assert(B.tracks[1].mute == 1 and B.tracks[1].vol ~= 0.55, "Bo on Local mixing: James's mute shown, not his fader")
B.projext.local_mix = nil
B.tracks[1].auto = 3 -- (Bo writing automation on Bass)
A.tracks[1].vol = 0.65
clock = clock + 0.06
tick(A); tick(B)
assert(B.tracks[1].vol ~= 0.65, "a track writing automation here: nothing streamed lands in its envelope")
B.tracks[1].auto = 0
clock = clock + CA.CONFIRM + 2
tick(A); tick(B); A.out = {}; B.out = {}
clock = clock + CA.CONFIRM + 2
tick(A); tick(B); A.out = {}; B.out = {}

-- ---- 6. a plug-in knob, past a translation of James's own -------------------------------------------------------------------------------
table.insert(A.tracks[1].fx, 1, { guid = "{L}", name = "JS: translation", p = { 0, 0, 0, 0 } })
A.tracks[1].ext.band_local_fx = "{L}for={EQ};"
A.touched = { true, 0, -1, 0, 1, 2 } -- (REAPER: ReaEQ's knob 3 on Bass was just touched)
A.tracks[1].fx[2].p[3] = 0.75
clock = clock + 0.06
tick(A)
local mv = A.out[1] and A.out[1].d.m[1]
assert(mv and mv.k == "x" and mv.f == 0 and mv.n == 2 and mv.v == 0.75, "the touched knob goes, by its place in the band's chain")
tick(B)
assert(B.tracks[1].fx[1].p[3] == 0.75 and B.previewing["PF-JAMES-1-1"], "and turns on Bo's ReaEQ, its chain held from the mirror")
B.touched = { true, 0, -1, 0, 0, 2 } -- (setting it may count as touched on Bo's)
clock = clock + 0.06
tick(B)
assert(sent(B) == 0, "no echo of a knob set from James's move")
A.tracks[1].fx[2].p[3] = 0.8
clock = clock + 0.06
tick(A)
assert(sent(A) == 1 and A.out[1].d.m[1].v == 0.8, "still watched: the next turn goes")
tick(B)
assert(B.tracks[1].fx[1].p[3] == 0.8, "shown")
clock = clock + CA.LET_GO + 0.01
tick(A); tick(B)
B.rev["F-JAMES-1-1"] = 2
clock = clock + 0.06
tick(B)
assert(not B.previewing["PF-JAMES-1-1"] and B.tracks[1].fx[1].p[3] == 0.8, "confirmed by the chain's change")

-- ---- 6b. order and latest wins: an older move never lands after a newer one; nothing goes while the link is behind ---------------------------
A.tracks[1].vol = 0.31
clock = clock + 0.06
tick(A)
local older = A.out[1].d
A.out = {}
A.tracks[1].vol = 0.32
clock = clock + 0.06
tick(A)
assert(older.m[1].q == 1 and A.out[1].d.m[1].q == 2, "each move of a hold numbered")
A.out = { A.out[1], { kind = "ctl", d = older } } -- (the newer first: the older comes in after it)
tick(B)
assert(B.tracks[1].vol == 0.32, "the older move, come in after the newer one, is dropped")
A.behind = true -- (the link's window full on a peer)
A.tracks[1].vol = 0.33
clock = clock + 0.06
tick(A)
A.tracks[1].vol = 0.34
clock = clock + 0.06
tick(A)
assert(sent(A) == 0, "the link behind: nothing goes")
A.behind = false
clock = clock + 0.06
tick(A)
assert(sent(A) == 1 and A.out[1].d.m[1].v == 0.34 and A.out[1].d.m[1].q == 3, "caught up: only the latest value goes")
tick(B)
assert(B.tracks[1].vol == 0.34, "and shows")
clock = clock + CA.LET_GO + 0.01
tick(A); tick(B)
B.rev[BASS] = 4
clock = clock + 0.06
tick(B)
assert(not B.previewing["P" .. BASS], "confirmed")

-- ---- 7. off for the studio -----------------------------------------------------------------------------------------------------------------
A.off, B.off = true, true
A.tracks[1].vol = 0.11
clock = clock + 0.06
tick(A)
assert(sent(A) == 0, "off: nothing read or sent")
A.out = { { kind = "ctl", d = { user = "James", m = { { o = BASS, k = "v", v = 0.12, s = clock } } } } }
tick(B)
assert(B.tracks[1].vol ~= 0.12 and CB.state.theirs[BASS .. "|v"] == nil, "off: nothing shown")
cur = B
local row = CB.health_row(cfgB)
assert(row[4]:find("off for this studio"), "Health says so: " .. row[4])
B.off = false
B.ext["live controls"] = band.json_encode({ held = { "James moving Bass volume" }, sent = 3, shown = 5, refused = 1 })
row = CB.health_row(cfgB)
assert(row[2] == false and row[4]:find("James moving Bass volume") and row[4]:find("1 refused"), "Health: who's moving what, and a refusal: " .. row[4])

-- ---- 8. mirror.watch leaves a shown track alone --------------------------------------------------------------------------------------------
package.loaded.mirror = nil
local mirror = require("mirror")
local looked = {}
mirror.W.one = function(_, o) looked[#looked + 1] = o.oid end
mirror.previewing["P1T-X"] = true
local seen = {}
mirror.W.each({ objs = { { oid = "T-X" }, { oid = "T-Y" } }, seen = seen, proj = "P1", say_once = function() end })
assert(#looked == 1 and looked[1] == "T-Y" and seen["T-X"] and seen["T-Y"], "a shown track is neither sent nor put back, and still counts as here")
print("ok")
