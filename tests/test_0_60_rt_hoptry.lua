-- Try a plug-in you don't have (rt-hopvst; lib/hoptry.lua, lib/hops.lua hops.try): the pure parts, then the stand-in REAPER of
-- tests/test_0_60_rt_hops.lua on both computers. James tries Bo's Serum on his Keys track: a Hop at the end of the chain; Bo's computer loads
-- nothing until Bo says yes (Health's Allow), then a hidden track with Hop X, Serum (the VST3) and Hop Y; Serum's knobs go to James, and
-- James's turns come back (only from James, only real knobs, 0..1). The web page's search and try; a long link's bigger budget (only while
-- stopped); Print onto a new track over the time selection; Bo stops it, a no, and the yes lasting only until Live sync stops.
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
    lo = { 1, 256, 0, 0 }, hi = { 64, 32768, 1, 1e7 }, v = { 1, 7200, 1, 0 }, pdc = 7200 }
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


-- ---- rt-hopvst's additions to the stand-in: installed plug-ins per computer, loading one by name, published lists, print's REAPER --------
local installed = { P1 = { "VST3: ReaEQ (Cockos)" }, P2 = { "CLAPi: Serum (Xfer)", "VST3i: Serum (Xfer)", "VST3: ReaEQ (Cockos)" } }
local real_add = reaper.TrackFX_AddByName
reaper.TrackFX_AddByName = function(tr, name, rec, at)
  for _, n in ipairs(installed[tr.proj] or {}) do
    if n == name and at <= -1000 then
      local pos = math.min(-1000 - at, #tr.fx)
      table.insert(tr.fx, pos + 1, plugin(name, 32))
      return pos
    end
  end
  return real_add(tr, name, rec, at)
end
reaper.TrackFX_GetFormattedParamValue = function(tr, i, p) return true, string.format("%.2f dB", F(tr, i).v[p + 1]) end
reaper.GetTrackName = function(tr) return true, tr.ext.P_NAME or "Keys" end
local selected
reaper.GetSelectedTrack = function() return selected end
package.loaded.plugins.kind = function(n) return (n or ""):match("^(%w+):") end
package.loaded.plugins.installed = function() local o = {}; for _, n in ipairs(installed[front] or {}) do o[#o + 1] = { name = n } end; return o end
package.loaded.plugins.lists = function()
  return { { user = "Bo", names = { "neural amp", "reaeq", "serum" } }, { user = "Mac", names = { "serum", "serum fx" } }, { user = "Gone", names = { "serum" } } }
end
local ps, pos, cmds = 0, 0, {}
reaper.GetPlayStateEx = function() return ps end
reaper.GetPlayPosition2Ex = function() return pos end
reaper.ValidatePtr2 = function() return true end
local toggles = { [40252] = 1 } -- (rt-p4: pre-roll on record 41819, Project tabs: Run background projects 40871, Run stopped ones 40873, toggled by running them)
reaper.Main_OnCommand = function(c) cmds[#cmds + 1] = c; if c == 41819 or c == 40871 or c == 40873 then toggles[c] = 1 - (toggles[c] or 0) end end
reaper.GetToggleCommandState = function(c) return toggles[c] or 0 end
local tsel = { 0, 0 }
reaper.GetSet_LoopTimeRange2 = function(_, set, _, a, z) if set then tsel = { a, z } end; return tsel[1], tsel[2] end
reaper.SetEditCurPos2 = function(_, t) pos = t end
reaper.InsertTrackInProject = function(proj, idx) table.insert(P(proj).tracks, idx + 1, { guid = guid(), ext = {}, info = { B_MAINSEND = 1, I_PERFFLAGS = 0 }, fx = {}, proj = proj, sends = {}, items = {} }) end
reaper.CreateTrackSend = function(src, dst) src.sends = src.sends or {}; src.sends[#src.sends + 1] = { dst = dst }; return #src.sends - 1 end
reaper.GetTrackNumSends = function(tr) return #(tr.sends or {}) end
reaper.SetTrackSendInfo_Value = function(tr, _, i, k, v) tr.sends[i + 1][k] = v; return true end
reaper.CountTrackMediaItems = function(tr) return #(tr.items or {}) end
reaper.GetTrackMediaItem = function(tr, i) return tr.items[i + 1] end
reaper.GetMediaItemInfo_Value = function(it, k) return it[k] end
reaper.GetActiveTake = function(it) return it.take end
reaper.GetSetMediaItemTakeInfo_String = function(tk, k, v, set) if set then tk[k] = v end; return true, tk[k] or "" end

local hops, hoptry = require("hops"), require("hoptry")
local cfg = { root = "J:/St/Smiley", user = "James" }
local cfg_bo = { root = "J:/St/Smiley", user = "Bo" }
local function last(op) for i = #sent, 1, -1 do if sent[i].d.op == op then return sent[i] end end end

-- ---- 1. pure --------------------------------------------------------------------------------------------------------------------------
assert(hoptry.clip("abc\ndef", 10) == "abc def", "control characters become spaces")
assert(hoptry.clip("Gain é", 6) == "Gain ", "never cut inside a UTF-8 character")
assert(hoptry.clip(nil, 5) == "", "nothing")
local pl = package.loaded.plugins
local name, inst = hoptry.best({ { name = "CLAPi: Serum (Xfer)" }, { name = "VST3i: Serum (Xfer)" }, { name = "JS: serum" } }, "serum", pl)
assert(name == "VST3i: Serum (Xfer)" and inst == true, "VST3 first, and an instrument by its kind")
name, inst = hoptry.best({ { name = "CLAP: Serum (Xfer)" } }, "serum", pl)
assert(name == "CLAP: Serum (Xfer)" and inst == false, "an effect")
assert(hoptry.best({ { name = "VST3: Other (X)" } }, "serum", pl) == nil, "not installed")
local m, n = hoptry.search(pl.lists(), { Bo = true, Mac = true }, { reaeq = true }, "SER", 60)
assert(n == 3 and #m == 3 and m[1].key == "serum" and m[1].user == "Bo" and m[2].user == "Mac" and m[3].key == "serum fx", "by name then user; here only (not Gone)")
m, n = hoptry.search(pl.lists(), { Bo = true, Mac = true }, { reaeq = true }, "", 2)
assert(n == 4 and #m == 2, "nothing typed: everything they have that you don't, at most max (ReaEQ, yours, left out)")
assert(#hoptry.search(pl.lists(), { Bo = true }, {}, "serum fx", 60) == 0, "every word must match")
local cp = hoptry.clean_params({ { i = 0, n = "Gain", v = 1.5, s = "+6 dB" }, { i = -1, n = "x", v = 0 }, { i = 1.5, v = 0 }, "junk", { i = 2, n = string.rep("n", 99), v = 0.25, s = 3 } })
assert(#cp == 2 and cp[1].v == 1 and cp[2].i == 2 and #cp[2].n == hoptry.NAME_MAX and cp[2].s == "3", "knobs made safe: whole index, value 0..1, short text")
assert(hoptry.clean_params("x") == nil, "not a list")
local big = {}
for i = 1, 400 do big[i] = { i = i - 1, n = "p", v = 0, s = "" } end
assert(#hoptry.clean_params(big) == hoptry.PAGE, "at most a page")
cp = hoptry.clean_params(big, 256)
assert(#cp == 144 and cp[1].i == 256, "a page from its offset: only knobs in it")
assert(#hoptry.clean_params({ { i = 600, n = "x", v = 0 } }, 256) == 0, "past its page: left out")
local kv, kn = hoptry.knob_view({ { i = 0, n = "Gain" }, { i = 300, n = "Cutoff" }, { i = 301, n = "Res" } }, 1, "")
assert(#kv == 2 and kv[1].i == 300 and kn == 2, "knob_view: a page")
kv, kn = hoptry.knob_view({ { i = 0, n = "Gain" }, { i = 300, n = "Cutoff" } }, 0, "cut")
assert(#kv == 1 and kv[1].n == "Cutoff" and kn == 1, "knob_view: a filter through every page, any case")
assert(hops.budget_for(8192, 125, 170.7) == nil, "the desktop <-> laptop link fits the default budget")
assert(hops.budget_for(8192, 200, 170.7) == 11264, "a longer link: covered with SPARE_MS to spare, in 1024s")
assert(hops.budget_for(8192, 2000, 170.7) == hops.LAT_MAX, "never more than the Hop's most")
assert(hops.budget_for(8192, -1, 170.7) == nil and hops.budget_for(nil, 200, 170) == nil, "not measured yet")

-- ---- 2. James tries Bo's Serum on his Keys track --------------------------------------------------------------------------------------
front = "P1"
local keys = track("P1", "kkk", { plugin("VST3: ReaEQ (Cockos)") })
keys.ext.P_NAME = "Keys"
local id, why = hoptry.start("P1", cfg, { song = "Song", room = "main" }, nil, "Bo", "serum")
assert(not id and why:find("select a track", 1, true), "no track selected: said so")
id, why = hoptry.start("P1", cfg, { song = "Song", room = "main" }, keys, "Nobody", "serum")
assert(not id and why:find("isn't on the link", 1, true), "someone not here")
id, why = hoptry.start("P1", cfg, { song = "Song", room = "main" }, keys, "Bo", "serum")
assert(id == 1, "tried: " .. tostring(why))
local hop = keys.fx[2]
assert(hops.is_hop_name(hop.name) and hop.v[1] == 1 and hop.v[2] == hops.LATENCY and hop.v[3] == 1, "a Hop at the end of the chain: dry when late")
assert(keys.ext.band_local_fx:find(hop.guid .. "for=hop;", 1, true), "this computer's own FX")
local rec = hops.records("P1")["1"]
assert(rec.try and rec.fx == "serum" and rec.user == "Bo" and rec.track == "Keys", "kept as a try")
local ask = last("serve")
assert(ask.d.try == true and ask.d.fx == "serum" and ask.d.user == "James" and ask.to[1] == "bo-pc.tail99.ts.net:47281", "Bo asked, as a try")
assert(select(2, hoptry.start("P1", cfg, { song = "Song", room = "main" }, keys, "Bo", "serum")):find("already", 1, true), "not twice on one track")

-- ---- 3. Bo's computer: nothing loads until Bo says yes ---------------------------------------------------------------------------------
front = "P2"
local ntracks = #projs.P2.tracks
hops.on_msg("P2", cfg_bo, ask.d, "Song", "main")
assert(#projs.P2.tracks == ntracks, "not loaded before a yes")
local f = last("fail")
assert(f.d.why:find("waiting for Bo to say yes", 1, true) and not f.d.denied, "James is told it waits for Bo")
assert(logs[#logs]:find("James asks to try your serum", 1, true), "Bo is told, once")
local nlogs = #logs
hops.on_msg("P2", cfg_bo, ask.d, "Song", "main")
assert(#logs == nlogs, "asked again: not said again")
local rows = hops.health_rows(cfg_bo, "P2")
local arow
for _, r in ipairs(rows) do if r[1]:find("^hop ask") then arow = r end end
assert(arow and arow[4]:find("James asks to try your serum", 1, true) and arow.action[1] == "Allow for this session", "Bo's Health: the ask, with Allow")
-- (James's side shows the wait)
front = "P1"
hops.on_msg("P1", cfg, f.d, "Song", "main")
assert(select(2, hops.health_text(rec, {})):find("waiting for Bo to say yes", 1, true), "James's Health says it waits for Bo's yes")
front = "P2"
arow.action[2]() -- Allow
assert(next(hoptry.asks()) == nil, "the ask is answered")
hops.on_msg("P2", cfg_bo, ask.d, "Song", "main")
local hidden = projs.P2.tracks[#projs.P2.tracks]
assert(#projs.P2.tracks == ntracks + 1 and hidden.ext.band_local == "hop", "loaded after the yes, on a hidden track")
assert(#hidden.fx == 3 and hidden.fx[2].name == "VST3i: Serum (Xfer)" and hops.is_hop_name(hidden.fx[1].name) and hops.is_hop_name(hidden.fx[3].name), "Hop X, Serum (the VST3), Hop Y")
local sj = band.json_decode(E.serve[#E.serve])
assert(sj.pdc == 32 and sj.token == ask.d.token, "served with its latency")
local sv = hops.S.serving[ask.d.token]
assert(sv.try and sv.instrument and sv.name == "VST3i: Serum (Xfer)", "known as a try of an instrument")
assert(#hoptry.uses() == 1 and hoptry.uses()[1].user == "James" and hoptry.uses()[1].key == "serum", "Bo sees who uses which")

-- ---- 4. its knobs: to James, and James's turns back ----------------------------------------------------------------------------------
E.status[64] = { hop = 64, ready = true, net = { role = "serve", alive = true, lined_up = true, heard = true, idle_s = 0.1, remote_ms = 31, slips = 0 } }
local function tick(proj, c) clock = clock + 1; hops.tick(c or cfg, { song = "Song", room = "main" }, proj) end
local nsent = #sent
tick("P2", cfg_bo)
local pm = last("params")
assert(#sent > nsent and pm and pm.d.token == ask.d.token and #pm.d.list == 3 and pm.d.list[2].n == "Drive" and pm.d.list[2].s == "0.25 dB" and pm.d.instrument == true, "the knobs go to James")
nsent = #sent
tick("P2", cfg_bo)
assert(last("params") == pm, "unchanged: not again so soon")
hidden.fx[2].v[1] = 0.9
tick("P2", cfg_bo)
assert(last("params") ~= pm and last("params").d.list[1].v == 0.9, "a knob Bo turned in Serum's own window goes too")
assert(hidden.fx[2].v[1] == 0.9, "and the song never overwrites a tried plug-in's knobs")
front = "P1"
hops.on_msg("P1", cfg, last("params").d, "Song", "main")
local model = hoptry.model("P1", cfg, { song = "Song", room = "main" })
assert(#model.tries == 1 and model.tries[1].id == 1 and #model.tries[1].params == 3 and model.tries[1].instrument == true and model.tries[1].name == "VST3i: Serum (Xfer)", "James's page: the try with its knobs")
assert(hoptry.set_param("P1", cfg, 1, 1, 0.8), "a knob turned on James's page")
local st = last("set")
assert(st.d.p == 1 and st.d.v == 0.8 and st.d.user == "James" and st.to[1] == rec.peer, "sent to Bo")
front = "P2"
hops.on_msg("P2", cfg_bo, st.d, "Song", "main")
assert(hidden.fx[2].v[2] == 0.8, "Bo's Serum turned")
hops.on_msg("P2", cfg_bo, { op = "set", token = ask.d.token, p = 1, v = 0.1, user = "Mac" }, "Song", "main")
hops.on_msg("P2", cfg_bo, { op = "set", token = ask.d.token, p = 99, v = 0.1, user = "James" }, "Song", "main")
hops.on_msg("P2", cfg_bo, { op = "set", token = ask.d.token, p = 1, v = 0 / 0, user = "James" }, "Song", "main")
assert(hidden.fx[2].v[2] == 0.8, "only James, a knob it has, a real value")
hops.on_msg("P2", cfg_bo, { op = "set", token = ask.d.token, p = 1, v = 7, user = "James" }, "Song", "main")
assert(hidden.fx[2].v[2] == 1, "kept 0..1")

-- ---- 4b. rt-p4: knobs past 256 come a page at a time; James's page shows one page, or a filter through all of them ---------------------
assert(toggles[40871] == 1 and toggles[40873] == 1, "hosting a hop: REAPER runs background tabs, playing or stopped (rt-hop2 item 3)")
do
  local serum = hidden.fx[2]
  local keep = { serum.pnames, serum.lo, serum.hi, serum.v }
  local function knobs(n)
    serum.pnames, serum.lo, serum.hi, serum.v = {}, {}, {}, {}
    for p = 1, n do serum.pnames[p], serum.lo[p], serum.hi[p], serum.v[p] = p == 590 and "Filter Cutoff" or "Knob " .. p, 0, 1, 0.5 end
  end
  local function went(n0) local g = {}; for i = n0 + 1, #sent do if sent[i].d.op == "params" or sent[i].d.op == "page" then g[#g + 1] = sent[i].d end end; return g end
  knobs(600)
  local n0 = #sent
  tick("P2", cfg_bo)
  local got = went(n0)
  assert(#got == 3 and got[1].op == "params" and got[1].off == 0 and #got[1].list == 256 and got[2].op == "page" and got[2].off == 256 and got[2].list[1].i == 256
    and got[3].off == 512 and #got[3].list == 88 and got[3].total == 600, "600 knobs: page 0 as params (what an older StudioSync shows), the rest as pages with their offsets")
  for _, d in ipairs(got) do assert(#band.json_encode(d) < 64 * 1024, "each under the link's 64 KB") end
  front = "P1"
  for _, k in ipairs({ 3, 1, 2 }) do hops.on_msg("P1", cfg, got[k], "Song", "main") end -- (in any order)
  local pm = hops.S.params[ask.d.token]
  assert(#pm.list == 600 and pm.list[300].i == 299 and pm.list[600].i == 599 and pm.total == 600, "James has all 600, merged by index")
  hops.on_msg("P1", cfg, { op = "page", off = 100, token = ask.d.token, list = { { i = 100, n = "x", v = 1, s = "" } }, total = 600 }, "Song", "main")
  hops.on_msg("P1", cfg, { op = "page", off = 8192, token = ask.d.token, list = {}, total = 600 }, "Song", "main")
  assert(#hops.S.params[ask.d.token].list == 600 and hops.S.params[ask.d.token].list[101].n == "Knob 101", "a page at an odd or too-far offset is ignored")
  local b = { song = "Song", room = "main" }
  local t = hoptry.model("P1", cfg, b).tries[1]
  assert(#t.params == 256 and t.params[1].i == 0 and t.page == 0 and t.pages == 3 and t.total == 600 and not t.kq, "the page shows the first 256")
  hoptry.web_action("P1", cfg, b, { knobs = { id = 1, page = 2 } })
  t = hoptry.model("P1", cfg, b).tries[1]
  assert(t.page == 2 and #t.params == 88 and t.params[1].i == 512, "Later knobs: the third page")
  hoptry.web_action("P1", cfg, b, { knobs = { id = 1, page = 99 } })
  assert(hoptry.model("P1", cfg, b).tries[1].page == 2, "never past the last page")
  hoptry.web_action("P1", cfg, b, { knobs = { id = 1, q = "CUTOFF" } })
  t = hoptry.model("P1", cfg, b).tries[1]
  assert(t.kq == "CUTOFF" and t.matched == 1 and #t.params == 1 and t.params[1].i == 589, "the filter looks through every page")
  hoptry.web_action("P1", cfg, b, { knobs = { id = 1, q = "knob" } })
  t = hoptry.model("P1", cfg, b).tries[1]
  assert(t.matched == 599 and #t.params == 256, "a filter shows at most a page of what matches")
  hoptry.web_action("P1", cfg, b, { knobs = { id = 1, q = "", page = 0 } })
  assert(hoptry.set_param("P1", cfg, 1, 589, 0.9), "a knob past 256 turned on James's page")
  front = "P2"
  hops.on_msg("P2", cfg_bo, last("set").d, "Song", "main")
  assert(serum.v[590] == 0.9, "turned on Bo's copy")
  n0 = #sent
  tick("P2", cfg_bo)
  got = went(n0)
  assert(#got == 1 and got[1].op == "page" and got[1].off == 512 and got[1].list[78].v == 0.9, "only the page that changed goes again")
  -- (at most PAGES_EVERY pages a tick: a plug-in with 1,100 knobs, all new)
  knobs(1100)
  hops.S.sent[ask.d.token], hops.S.serving[ask.d.token].pv = nil, nil
  n0 = #sent
  tick("P2", cfg_bo)
  got = went(n0)
  assert(#got == hoptry.PAGES_EVERY and got[4].off == 768, "four pages in one tick")
  n0 = #sent
  tick("P2", cfg_bo)
  got = went(n0)
  assert(#got >= 1 and got[1].off == 1024 and #got[1].list == 76, "the fifth at the next")
  -- Bo switches to another tab: the hosting goes on (rt-hop2 item 3: it used to stop following until he came back)
  serum.pnames, serum.lo, serum.hi, serum.v = table.unpack(keep)
  front = "P1" -- (P1 stands in for Bo's other tab)
  n0 = #sent
  tick("P2", cfg_bo)
  got = went(n0)
  assert(#got == 1 and got[1].total == 3 and #got[1].list == 3, "behind another tab its knobs still go (back to Serum's 3)")
  hops.on_msg("P1", cfg, got[1], "Song", "main")
  local np = 0
  for _ in pairs(hops.S.params[ask.d.token].pages) do np = np + 1 end
  assert(#hops.S.params[ask.d.token].list == 3 and np == 1, "James: 3 knobs, the old pages gone")
  front = "P2"
end

-- ---- 5. the web page: search and try from it -----------------------------------------------------------------------------------------
-- (one Lua state plays both computers here: Bo's hosting is put aside while James's ticks run, as it lives on Bo's computer)
local bo_serving = hops.S.serving
hops.S.serving = {}
front = "P1"
local b = { song = "Song", room = "main" }
assert(hoptry.web_action("P1", cfg, b, { q = "ser" }) == nil, "a search")
model = hoptry.model("P1", cfg, b)
assert(model.q == "ser" and #model.matches == 3 and model.matches[1].user == "Bo" and model.matched == 3, "matches from those here")
assert(#model.people == 2 and model.people[1] == "Bo", "who's here")
assert(hoptry.web_action("P1", cfg, b, { try = { user = "Mac", key = "serum fx" } }):find("select a track", 1, true), "no track selected on the page's try")
local bass = track("P1", "bbb", {})
selected = bass
assert(hoptry.web_action("P1", cfg, b, { try = { user = "Mac", key = "serum fx" } }) == nil and hops.records("P1")["2"].fx == "serum fx", "tried from the page on the selected track")
local published = {}
local function publish(t, v) published[t] = v end
hoptry.web_tick("P1", cfg, b, publish, clock + 100)
assert(published.tryfx == nil, "nobody looking: nothing built")
hoptry.web_action("P1", cfg, b, { want = true })
hoptry.web_tick("P1", cfg, b, publish, clock)
assert(published.tryfx and #published.tryfx.tries == 2, "built while the page looks")
assert(hoptry.web_action("P1", cfg, b, { stop = 2 }):find("stopped trying serum fx", 1, true) and not hops.records("P1")["2"], "stopped from the page")

-- ---- 6. a long link: a bigger budget, only while stopped -------------------------------------------------------------------------------
local net = { resolved = true, serving = true, active = true, remote_alive = true, same_rate = true, rtt_ms = 160, remote_ms = 30, need_ms = 200, budget_ms = 170.7,
  slack_ms = -30, sent = 48000, lost = 0, late = 0 }
E.status[1] = { hop = 1, ready = true, net = net }
ps = 1
for _ = 1, hops.SETTLE + 2 do tick("P1") end
assert(keys.fx[2].v[2] == hops.LATENCY, "not while playing")
ps = 0
tick("P1")
assert(keys.fx[2].v[2] == 11264 and hops.records("P1")["1"].latency == 11264, "stopped: the Hop's budget raised to cover the link, and kept")
assert(logs[#logs]:find("needs 200 ms", 1, true), "said")

-- ---- 7. print: what comes back recorded onto a new track ------------------------------------------------------------------------------
local ok
ok, why = hoptry.print("P1", cfg, 1)
assert(not ok and why:find("time selection", 1, true), "nothing to print without a time selection or items")
local drums = track("P1", "ddd", {})
drums.info.I_RECARM = 1
tsel = { 10, 20 }
ps = 1
assert(select(2, hoptry.print("P1", cfg, 1)):find("stop playback", 1, true), "not while playing")
ps = 0
ok, why = hoptry.print("P1", cfg, 1)
assert(ok, "printing: " .. tostring(why))
local pt = projs.P1.tracks[#projs.P1.tracks]
assert(pt.ext.P_NAME == "Keys - serum print" and pt.info.I_RECARM == 1 and pt.info.I_RECMODE == 3 and pt.info.B_MAINSEND == 0, "a new track, armed, recording its output, not heard twice")
assert(keys.sends[1].dst == pt and keys.sends[1].I_SENDMODE == 3, "fed post-FX from the Keys track")
assert(drums.info.I_RECARM == 0, "other armed tracks held off while it prints")
assert(cmds[#cmds - 1] == 40076 and cmds[#cmds] == 1013 and pos == 8, "auto-punch on the time selection, recording from 2 s before")
assert(select(2, hoptry.print("P1", cfg, 1)):find("running already", 1, true), "one print at a time")
ps, pos = 5, 8.3
tick("P1")
ps, pos = 5, 15
tick("P1")
assert(hops.S.printing, "still recording")
pt.items = { { take = {} } }
pos = 20.4
tick("P1")
assert(not hops.S.printing and cmds[#cmds - 1] == 40667 and cmds[#cmds] == 40252, "stopped at the end (recording kept), record mode put back")
assert(pt.info.I_RECARM == 0 and pt.info.B_MAINSEND == 1 and drums.info.I_RECARM == 1, "the print track disarmed and heard; the other armed again")
assert(pt.items[1].take.P_NAME == "serum (via Bo's computer)", "the take says what it is")
ps = 0
-- (rt-hop2 item 2, rt-p4: a selection too near the project's start for the lead-in records with REAPER's pre-roll on, put back after; it
-- says so only when playback didn't go far enough back before the selection)
for _, l in ipairs(logs) do assert(not l:find("lead-in was only", 1, true), "a selection with room for the lead-in: no warning") end
assert(toggles[41819] ~= 1, "pre-roll on record is off to begin with")
tsel = { 0.4, 4 }
ok, why = hoptry.print("P1", cfg, 1)
assert(ok and pos == 0 and cmds[#cmds - 1] == 41819 and cmds[#cmds] == 1013 and toggles[41819] == 1, "a selection at 0.4 s: pre-roll on, then record from 0: " .. tostring(why))
assert(logs[#logs]:find("with REAPER's pre-roll", 1, true), "said")
ps, pos = 5, -1.6 -- (REAPER plays the pre-roll before 0)
tick("P1")
ps, pos = 5, 4.4
tick("P1")
assert(not hops.S.printing and toggles[41819] == 0, "that print ends too, pre-roll off again as it was")
for _, l in ipairs(logs) do assert(not l:find("lead-in was only", 1, true), "a 2 s pre-roll before 0: no warning") end
ps = 0
tsel = { 0.4, 4 }
ok = hoptry.print("P1", cfg, 1)
ps, pos = 5, 0.2 -- (it didn't play before 0)
tick("P1")
ps, pos = 5, 4.4
tick("P1")
assert(not hops.S.printing and logs[#logs]:find("lead-in was only 0.2 s", 1, true) and logs[#logs]:find("at 2 s or later", 1, true), "no pre-roll before 0: its start may be dry, said")
ps = 0
toggles[41819] = 1 -- (pre-roll already on here: left on)
ok = hoptry.print("P1", cfg, 1)
assert(cmds[#cmds] == 1013 and cmds[#cmds - 1] ~= 41819, "pre-roll already on: not touched")
ps, pos = 5, -1
tick("P1")
ps, pos = 5, 4.4
tick("P1")
assert(not hops.S.printing and toggles[41819] == 1, "and still on after")
toggles[41819] = 0
ps = 0

-- ---- 8. Bo stops it; a no; Live sync ending ------------------------------------------------------------------------------------------
hops.S.serving = bo_serving
front = "P2"
assert(hoptry.end_use("P2", cfg_bo, ask.d.token):find("stopped James trying your serum", 1, true), "Bo stops it")
assert(#projs.P2.tracks == ntracks and last("fail").d.denied == true and last("fail").d.why == "Bo stopped it", "the hidden track gone, James told")
hops.on_msg("P2", cfg_bo, ask.d, "Song", "main")
assert(#projs.P2.tracks == ntracks and last("fail").d.denied, "asked again on that try: refused at once")
front = "P1"
hops.on_msg("P1", cfg, last("fail").d, "Song", "main")
assert(not hops.records("P1")["1"] and not keys.fx[2], "James's try ends too: the Hop out of the track")
assert(hops.S.back[#hops.S.back].text:find("Trying serum on Bo's computer ended: Bo stopped it", 1, true), "and says why")
front = "P2"
hops.on_msg("P2", cfg_bo, { op = "serve", token = 555, oid = "kkk", fxi = 0, fx = "serum", user = "Mac", try = true }, "Song", "main")
assert(#hoptry.asks() == 1, "Mac asks")
assert(hoptry.refuse(cfg_bo, 555):find("told Mac no", 1, true) and last("fail").d.denied and last("fail").d.why == "Bo said no", "Bo says no")
hops.on_msg("P2", cfg_bo, { op = "serve", token = 556, oid = "kkk", fxi = 0, fx = "nothing here", user = "Mac", try = true }, "Song", "main")
assert(last("fail").d.why:find("isn't installed", 1, true), "a plug-in Bo hasn't got")
hops.S.allow["Ann\0serum"] = true
hops.on_exit("P2", cfg_bo)
assert(next(hops.S.allow) == nil, "a yes lasts this session only")
-- ---- 9. the page files ------------------------------------------------------------------------------------------------------------------
local function read(path) local fh = assert(io.open(path, "rb")); local s = fh:read("a"); fh:close(); return s end
local index = read("lib/webui/index.html")
for _, fname in ipairs({ "tryfx.js", "tryfx.css" }) do assert(index:find('"' .. fname .. '"', 1, true), "index.html links " .. fname) end
local js = read("lib/webui/tryfx.js")
assert(not js:find("innerHTML") and not js:find("eval%(") and not js:find("https?://[%w]"), "tryfx.js: no HTML from data, no eval, nothing fetched from elsewhere")
assert(js:find("ssTabs.act('tryfx'", 1, true) and require("webui").ACTIONS.tryfx, "its actions on its own topic, one the pages may send")
local wl = read("lib/webui.lua")
assert(wl:find('require("hoptry").web_action', 1, true) and wl:find('require("hoptry").web_tick', 1, true), "the web UI's tick hands the Try tab its actions and builds its topic")
print("ok: try a plug-in you don't have")
