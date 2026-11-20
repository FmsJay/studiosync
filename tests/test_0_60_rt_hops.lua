-- Live hops (James, rt; lib/hops.lua, the extension's side in extension/hopnet.cpp and tests/hopnet_test.cpp): the pure parts, then a stand-in
-- REAPER on both computers. The requester: "Run this plug-in on Bo's computer" puts a Hop right after the plug-in as this computer's own FX,
-- connects it and asks Bo; Live sync's tick keeps it connected, asks again until Bo hosts it, puts the Hop back when the band's chain replaced
-- the track's; Stop takes it all away. Bo: the hidden track (Hop X, a copy of the song's plug-in, Hop Y; no master send, no anticipative FX,
-- chain PDC "ignore"), served with its ids and the plug-in's latency, knobs that follow the song's, a refusal when the plug-in isn't there,
-- and the track gone on stop. Health's rows on both sides.
package.path = "lib/?.lua;" .. package.path
local clock, ext, front = 1000, {}, "P1"
reaper = setmetatable({
  time_precise = function() return clock end,
  GetOS = function() return "Win64" end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  DeleteExtState = function(s, k) ext[s .. "/" .. k] = nil end,
  GetResourcePath = function() return "C:/res" end,
  EnumProjects = function() return front end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() return "" end end end })

local band = require("band")
local logs = {}
band.log = function(s) logs[#logs + 1] = s end

-- ---- a stand-in REAPER: projects of tracks, each with FX that have knobs ----------------------------------------------------------------
local projs, nguid = { P1 = { tracks = {}, ext = {} }, P2 = { tracks = {}, ext = {} } }, 0
local function guid() nguid = nguid + 1; return string.format("{%08d-0000-0000-0000-000000000000}", nguid) end
local function hop_fx()
  return { name = "CLAP: StudioSync Hop (StudioSync)", guid = guid(), pnames = { "Hop id", "Latency budget", "Dry when late", "Late blocks" },
    lo = { 1, 256, 0, 0 }, hi = { 64, 8192, 1, 1e7 }, v = { 1, 7200, 1, 0 }, pdc = 7200 }
end
local function plugin(name, pdc)
  return { name = name, guid = guid(), pnames = { "Gain", "Drive", "Tone" }, lo = { 0, 0, 0 }, hi = { 1, 1, 1 }, v = { 0.5, 0.25, 0.75 }, pdc = pdc or 0 }
end
local function track(p, oid, fx)
  local t = { guid = guid(), ext = { band_oid = oid or "" }, info = { B_MAINSEND = 1, I_PERFFLAGS = 0, B_SHOWINTCP = 1, B_SHOWINMIXER = 1 }, fx = fx or {}, proj = p }
  projs[p].tracks[#projs[p].tracks + 1] = t
  return t
end
local master = { guid = "{MASTER}", ext = {}, info = {}, fx = {} }
local function P(proj) return projs[proj or front] end
local function F(tr, i) return tr.fx[i + 1] end
reaper.GetMasterTrack = function() return master end
reaper.CountTracks = function(proj) return #P(proj).tracks end
reaper.GetTrack = function(proj, i) return P(proj).tracks[i + 1] end
reaper.GetTrackGUID = function(tr) return tr.guid end
reaper.InsertTrackInProject = function(proj, idx) table.insert(P(proj).tracks, idx + 1, { guid = guid(), ext = {}, info = { B_MAINSEND = 1, I_PERFFLAGS = 0, B_SHOWINTCP = 1, B_SHOWINMIXER = 1 }, fx = {}, proj = proj }) end
reaper.DeleteTrack = function(tr) local ts = P(tr.proj).tracks; for i, t in ipairs(ts) do if t == tr then table.remove(ts, i); return end end end
reaper.GetSetMediaTrackInfo_String = function(tr, key, v, set)
  local k = key:match("^P_EXT:(.*)$") or key
  if set then tr.ext[k] = v end
  return true, tr.ext[k] or ""
end
reaper.GetMediaTrackInfo_Value = function(tr, k) return tr.info[k] or 0 end
reaper.SetMediaTrackInfo_Value = function(tr, k, v) tr.info[k] = v end
reaper.TrackFX_GetCount = function(tr) return #tr.fx end
reaper.TrackFX_GetFXGUID = function(tr, i) return F(tr, i) and F(tr, i).guid end
reaper.TrackFX_GetFXName = function(tr, i) return true, F(tr, i).name end
reaper.TrackFX_GetNamedConfigParm = function(tr, i, k)
  local f = F(tr, i)
  if not f then return false, "" end
  if k == "fx_name" then return true, f.name end
  if k == "pdc" then return true, tostring(f.pdc) end
  return false, ""
end
reaper.TrackFX_SetNamedConfigParm = function(tr, i, k, v) tr.chain = tr.chain or {}; tr.chain[k] = v; return true end
reaper.TrackFX_GetNumParams = function(tr, i) return #F(tr, i).pnames end
reaper.TrackFX_GetParamName = function(tr, i, p) return true, F(tr, i).pnames[p + 1] end
reaper.TrackFX_GetParam = function(tr, i, p) local f = F(tr, i); return f.v[p + 1], f.lo[p + 1], f.hi[p + 1] end
reaper.TrackFX_SetParam = function(tr, i, p, v) F(tr, i).v[p + 1] = v; return true end
reaper.TrackFX_SetParamNormalized = function(tr, i, p, v) local f = F(tr, i); f.v[p + 1] = f.lo[p + 1] + v * (f.hi[p + 1] - f.lo[p + 1]); return true end
reaper.TrackFX_GetParamNormalized = function(tr, i, p) local f = F(tr, i); return (f.v[p + 1] - f.lo[p + 1]) / (f.hi[p + 1] - f.lo[p + 1]) end
local hop_installed = true
reaper.TrackFX_AddByName = function(tr, name, _, at)
  if not (hop_installed and name == "CLAP: StudioSync Hop") then return -1 end -- (only the CLAP here: the first name tried)
  local pos = math.min(-1000 - at, #tr.fx)
  table.insert(tr.fx, pos + 1, hop_fx())
  return pos
end
reaper.TrackFX_SetOffline = function(tr, i, off) F(tr, i).offline_toggles = (F(tr, i).offline_toggles or 0) + 1; F(tr, i).offline = off end
reaper.TrackFX_Delete = function(tr, i) table.remove(tr.fx, i + 1) end
reaper.TrackFX_CopyToTrack = function(src, si, dst, di)
  local f, c = F(src, si), {}
  for k, v in pairs(f) do c[k] = type(v) == "table" and { table.unpack(v) } or v end
  c.guid = guid()
  table.insert(dst.fx, di + 1, c)
end
reaper.GetProjExtState = function(proj, sec, k) return 1, P(proj).ext[sec .. "/" .. k] or "" end
reaper.SetProjExtState = function(proj, sec, k, v) P(proj).ext[sec .. "/" .. k] = v end

-- the stand-in extension
local E = { connect = {}, serve = {}, status = {}, live = false, la = {} }
reaper.StudioSync_HopConnect = function(id, peer, json) E.connect[#E.connect + 1] = { id = id, peer = peer, json = json }; return 1 end
reaper.StudioSync_HopServe = function(json) E.serve[#E.serve + 1] = json; return 1 end
reaper.StudioSync_HopStatus = function(id) return band.json_encode(E.status[id] or { hop = id, ready = true }) end
reaper.StudioSync_LiveAudioStatus = function() return band.json_encode({ running = E.live }) end
reaper.StudioSync_LiveAudioPeers = function(json) E.la[#E.la + 1] = "peers " .. json; return 0 end
reaper.StudioSync_LiveAudioStart = function(f, n, k) E.la[#E.la + 1] = string.format("start %d %d %d", f, n, k); E.live = true; return 1 end

-- the rest of StudioSync, as far as hops reaches
local sent = {}
package.loaded.direct = {
  peers = function() return { "bo-pc.tail99.ts.net:47281", "mac.tail99.ts.net:47281" }, { ["bo-pc.tail99.ts.net:47281"] = "DEVBO", ["mac.tail99.ts.net:47281"] = "DEVMAC" } end,
  send_live = function(cfg, kind, d, song, room, id, to) sent[#sent + 1] = { kind = kind, d = d, song = song, room = room, to = to }; return true end,
  port = function() return 47281 end,
}
package.loaded.groups = { tailnet = function() return { suffix = "tail99.ts.net" } end, sonobus_secret = function() return "s3cret" end }
package.loaded.liveaudio = { peers_json = function(secret, port, peers) return band.json_encode({ secret = secret, port = port, peers = peers }) end, mine = function() return 0, 1, 128 end }
local has = { Bo = { ["neural amp"] = true }, Mac = {} }
package.loaded.prints = { has = function(_, u, keys) for _, k in ipairs(keys) do if not (has[u] or {})[k] then return false end end; return true end,
  fx_here = function(tr, i) return not F(tr, i).offline end }
package.loaded.plugins = { key = function(n) return ((n or ""):gsub("^%w+:%s*", "")):gsub("%s*%(.-%)$", ""):lower() end }
package.loaded.mirror = {
  track_oid = function(tr) return (tr.ext.band_oid or ""):upper() end,
  live_fx = function() return {} end,
  add_local_track = function(proj, name, tag)
    reaper.InsertTrackInProject(proj, #P(proj).tracks)
    local tr = P(proj).tracks[#P(proj).tracks]
    tr.ext.P_NAME, tr.ext.band_local = name, tag
    tr.info.B_SHOWINTCP, tr.info.B_SHOWINMIXER = 0, 0
    return tr
  end,
}
band.files = function(dir) return dir:find("_band/devices", 1, true) and { "bo.json", "mac.json" } or {} end
band.read_json = function(p) if p:find("bo.json", 1, true) then return { user = "Bo", device = "DEVBO" } elseif p:find("mac.json", 1, true) then return { user = "Mac", device = "DEVMAC" } end end

local hops = require("hops")
local cfg = { root = "J:/St/Smiley", user = "James" }

-- ---- 1. pure --------------------------------------------------------------------------------------------------------------------------
assert(hops.is_hop_name("CLAP: StudioSync Hop (StudioSync)") and not hops.is_hop_name("VST3: Neural Amp"), "a Hop by its name")
assert(hops.free_id({ [1] = true, [2] = true }, 1, 32) == 3 and hops.free_id({ [64] = true }, 64, 33) == 63, "the first free id, up or down")
assert(hops.free_id({ [1] = true }, 1, 1) == nil, "none free")
local peer_of = { Bo = "bo:1", Ann = "ann:1", Cy = "cy:1" }
local can = function(u) return u ~= "Ann" end
assert(hops.pick(peer_of, can) == "Bo", "the first by name who has it (Ann hasn't)")
assert(hops.pick(peer_of, can, "Cy") == "Cy", "the one asked for, when they have it")
assert(hops.pick(peer_of, can, "Ann") == "Bo", "not one who lacks it")
assert(hops.pick(peer_of, function() return false end) == nil, "nobody has it")
local j = band.json_decode(hops.connect_json("se\"c", 123.0))
assert(j.secret == 'se"c' and j.token == 123, "what HopConnect takes")
j = band.json_decode(hops.serve_json("s", 9, 64, 63, 100))
assert(j.x == 64 and j.y == 63 and j.pdc == 100 and j.margin_ms == hops.MARGIN_MS and j.token == 9, "what HopServe takes")
local rec0 = { id = 3, token = 5, fx = "VST3: Neural Amp", user = "Bo", peer = "bo-pc.tail99.ts.net:47281" }
local ok, text = hops.health_text(rec0, {})
assert(not ok and text:find("not connected", 1, true), "Health: not connected yet")
ok, text = hops.health_text(rec0, { net = { resolved = true, serving = false } })
assert(not ok and text:find("waiting for Bo", 1, true), "Health: waiting for Bo")
local good = { resolved = true, serving = true, remote_alive = true, same_rate = true, rtt_ms = 40, remote_ms = 30, need_ms = 80, budget_ms = 150, slack_ms = 60, sent = 100000, lost = 10, late = 0, remote_slips = 0 }
ok, text = hops.health_text(rec0, { late = 0, net = good })
assert(ok and text:find("Hop 3 (Neural Amp on Bo's computer)", 1, true) and text:find("needs 80 of its 150 ms", 1, true), "Health: in budget: " .. text)
good.need_ms = 160
ok, text = hops.health_text(rec0, { net = good })
assert(not ok and text:find("Raise the Hop's Latency budget", 1, true), "Health: over budget")
good.need_ms, good.same_rate = 80, false
assert(not hops.health_text(rec0, { net = good }), "Health: two sample rates")

-- ---- 2. the requester: James lacks Neural Amp; Bo has it ------------------------------------------------------------------------------
front = "P1"
local amp = plugin("VST3: Neural Amp (Neural DSP)")
amp.offline = true
local mine = plugin("JS: my own translation")
local tr = track("P1", "aaa", { plugin("VST3: ReaEQ (Cockos)"), mine, amp })
tr.ext.band_local_fx = mine.guid .. "for=" .. amp.guid .. ";" -- (a translation of this computer's own: not counted as the song's)
local list = hops.candidates(cfg, amp.name, "Song", "main")
assert(#list == 1 and list[1].user == "Bo" and list[1].peer == "bo-pc.tail99.ts.net:47281", "only Bo has it here")
-- outside Live sync (the panel, an action) direct.peers gives the list only: the bandmates are still found, by their Tailscale names (desktop, rt)
do
  local real_peers, real_read = package.loaded.direct.peers, band.read_json
  package.loaded.direct.peers = function() return { "bo-pc.tail99.ts.net:47281", "mac.tail99.ts.net:47281" }, {} end
  band.read_json = function(p)
    if p:find("bo.json", 1, true) then return { user = "Bo", device = "DEVBO", ts = { ["tail99.ts.net"] = "bo-pc.tail99.ts.net" } } end
    if p:find("mac.json", 1, true) then return { user = "Mac", device = "DEVMAC", ts = { ["tail99.ts.net"] = "MAC.tail99.ts.net" } } end
  end
  local by = hops.peers_by_user(cfg, "Song", "main")
  assert(by.Bo == "bo-pc.tail99.ts.net:47281" and by.Mac == "mac.tail99.ts.net:47281", "found by name (any case) without the device map")
  package.loaded.direct.peers, band.read_json = real_peers, real_read
end
local id, why = hops.make("P1", cfg, tr, 2, "Bo", list[1].peer, "Song", "main")
assert(id == 1, "made: " .. tostring(why))
local hop = tr.fx[4]
assert(hops.is_hop_name(hop.name) and hop.v[1] == 1 and hop.v[2] == hops.LATENCY and hop.v[3] == 0, "a Hop right after the plug-in: id 1, the plug-in's most budget, silent when late")
assert(hop.offline_toggles == 2 and hop.offline == false, "taken offline and back, so it starts with its id")
assert(tr.ext.band_local_fx:find(hop.guid .. "for=hop;", 1, true), "this computer's own FX: never sent to the others")
local rec = hops.records("P1")["1"]
assert(rec and rec.fxi == 1 and rec.oid == "AAA" and rec.user == "Bo" and rec.of == amp.guid, "kept in the project: the song's 2nd plug-in (own FX not counted)")
assert(E.la[1]:find('"peers":[]', 1, true) and E.la[2] == "start 0 1 128", "live audio wasn't running: started with nobody to send to, to carry the hop")
assert(E.connect[1].id == 1 and E.connect[1].peer == list[1].peer and band.json_decode(E.connect[1].json).token == rec.token, "connected with the hop's token")
assert(band.json_decode(E.connect[1].json).secret == "s3cret", "and the studio secret")
assert(sent[1].kind == "hop" and sent[1].d.op == "serve" and sent[1].d.oid == "AAA" and sent[1].d.fxi == 1 and sent[1].to[1] == list[1].peer, "Bo asked to host it")
assert(hops.of_fx("P1", tr, 2) == nil or hops.of_fx("P1", tr, 2).id == 1, "the hop found from its plug-in")
assert(hops.of_fx("P1", tr, 3).id == 1, "and from the Hop")

local function tick(proj) clock = clock + 1; hops.tick(cfg, { song = "Song", room = "main" }, proj or front) end
E.status[1] = { hop = 1, ready = true, net = { resolved = true, serving = false } }
local nconnect, nsent = #E.connect, #sent
tick()
assert(#E.connect == nconnect, "connected already: not again")
assert(#sent == nsent, "asked a second ago: not again yet")
clock = clock + hops.ASK_EVERY
tick()
assert(#sent == nsent + 1 and sent[#sent].d.op == "serve", "not hosted yet after a while: asked again")
E.status[1].net.serving = true
clock = clock + hops.ASK_EVERY
nsent = #sent
tick()
assert(#sent == nsent, "hosted: no more asking")
E.status[1] = { hop = 1, ready = true } -- (the extension restarted: no network side)
tick()
assert(#E.connect == nconnect + 1, "connected again when the extension forgot it")
table.remove(tr.fx, 4); table.remove(tr.fx, 2); tr.ext.band_local_fx = "" -- (the band's chain replaced this track's: own FX gone, mirror empties the list)
tick()
assert(hops.is_hop_name(tr.fx[3].name) and tr.fx[3].v[1] == 1, "the Hop is put back after the plug-in")
assert(hops.records("P1")["1"].hop == tr.fx[3].guid and tr.ext.band_local_fx == tr.fx[3].guid .. "for=hop;", "and its record follows")
E.status[1] = { hop = 1, ready = true, late = 2, net = { resolved = true, serving = true, remote_alive = true, same_rate = true, rtt_ms = 41, remote_ms = 30,
  need_ms = 77, budget_ms = 150, slack_ms = 70, sent = 48000, lost = 0, late = 0, remote_slips = 1 } }
local rows = hops.health_rows(cfg, "P1")
assert(#rows == 1 and rows[1][2] == true and rows[1][4]:find("1 clock slips", 1, true) and rows[1][4]:find("2 late blocks", 1, true), "Health's row: " .. tostring(rows[1] and rows[1][4]))

-- ---- 3. Bo's computer: hosting it ------------------------------------------------------------------------------------------------------
front = "P2"
local bo_amp = plugin("VST3: Neural Amp (Neural DSP)", 64)
local bo_tr = track("P2", "AAA", { plugin("VST3: ReaEQ (Cockos)"), bo_amp })
local serve_msg = sent[1].d
hops.on_msg("P2", cfg, serve_msg, "Song", "main")
local hidden = projs.P2.tracks[2]
assert(hidden and hidden.ext.band_local == "hop" and hidden.ext.P_NAME == "StudioSync hop for James", "a hidden track of Bo's own")
assert(#hidden.fx == 3 and hops.is_hop_name(hidden.fx[1].name) and hidden.fx[2].name == bo_amp.name and hops.is_hop_name(hidden.fx[3].name), "Hop X, the copy, Hop Y")
assert(hidden.fx[1].v[1] == 64 and hidden.fx[3].v[1] == 63 and hidden.fx[1].v[2] == 256 and hidden.fx[3].v[2] == 256, "ids from the top down; 256-sample latency")
assert(hidden.fx[1].v[3] == 0 and hidden.fx[3].v[3] == 1, "Y plays its input (the hidden track's meter shows the hop), X only what's fed")
assert(hidden.info.B_MAINSEND == 0 and hidden.info.I_PERFFLAGS & 2 == 2 and hidden.chain.chain_pdc_mode == "2", "no master send, real time, chain PDC ignored")
local sj = band.json_decode(E.serve[#E.serve])
assert(sj.x == 64 and sj.y == 63 and sj.pdc == 64 and sj.token == serve_msg.token and sj.secret == "s3cret", "served with the plug-in's latency")
local nserve = #E.serve
hops.on_msg("P2", cfg, serve_msg, "Song", "main")
assert(#projs.P2.tracks == 2, "asked again: the same track, not another")
bo_amp.v[2] = 0.9 -- (a knob turned on the song's plug-in)
E.status[64] = { hop = 64, ready = true, net = { role = "serve", alive = true, lined_up = true, heard = true, idle_s = 0.1, remote_ms = 31, slips = 0 } }
tick("P2")
assert(hidden.fx[2].v[2] == 0.9, "the copy's knobs follow the song's")
assert(#E.serve == nserve, "nothing to tell the extension")
hidden.fx[2].pdc = 128
tick("P2")
assert(band.json_decode(E.serve[#E.serve]).pdc == 128, "a new latency on the copy: the extension told")
rows = hops.health_rows(cfg, "P2")
assert(rows[#rows][1] == "hop host 64" and rows[#rows][2] == true and rows[#rows][4]:find("Hosting a hop for James", 1, true), "Bo's Health row")
hops.on_msg("P2", cfg, { op = "serve", token = 77, oid = "ZZZ", fxi = 0, fx = "VST3: Nothing", user = "James" }, "Song", "main")
assert(sent[#sent].d.op == "fail" and sent[#sent].d.why:find("doesn't have", 1, true) and #projs.P2.tracks == 2, "a plug-in it hasn't: refused, said why")
hop_installed = false
hops.on_msg("P2", cfg, { op = "serve", token = 78, oid = "AAA", fxi = 1, fx = bo_amp.name, user = "James" }, "Song", "main")
assert(sent[#sent].d.why:find("Hop plug-in isn't installed", 1, true) and #projs.P2.tracks == 2, "no Hop plug-in there: refused, nothing left behind")
hop_installed = true
hops.on_msg("P2", cfg, { op = "stop", token = serve_msg.token }, "Song", "main")
assert(#projs.P2.tracks == 1 and band.json_decode(E.serve[#E.serve]).stop == true, "stopped: the hidden track goes, the extension stops serving")

-- ---- 4. James stops it ------------------------------------------------------------------------------------------------------------------
front = "P1"
hops.on_msg("P1", cfg, { op = "fail", token = rec.token, why = "Neural Amp doesn't load on their computer" }, "Song", "main")
ok, text = hops.health_text(hops.records("P1")["1"], E.status[1])
assert(not ok and text:find("doesn't load", 1, true), "Bo's refusal shows in Health")
assert(hops.stop("P1", cfg, 1), "stopped")
assert(#tr.fx == 2 and not tr.ext.band_local_fx:find("for=hop;", 1, true), "the Hop is gone from the track")
assert(E.connect[#E.connect].json:find('"stop":true', 1, true) and sent[#sent].d.op == "stop", "the extension and Bo told")
assert(next(hops.records("P1")) == nil, "and the project forgets it")
print("ok: live hops")
