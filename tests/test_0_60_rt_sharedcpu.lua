-- Shared CPU (James, rt; roadmap "More big ideas" 2, lib/hops.lua): a whole track's FX offloaded to the idlest bandmate through a live hop.
-- The pure parts (how busy from each OS's probe, who it goes to, why it comes back, what a request asks for), mirror sending the band's BYPASS
-- lines for a chain held off here, then a stand-in REAPER on both computers: offload picks Bo (Mac lacks a plug-in, Cy records, Gus is a guest),
-- one Hop at the end (dry when late), the song's FX held off with the band's states kept; Bo hosts the whole chain (knobs and bypass follow,
-- latency summed); it comes back by itself (falling behind, recording, going away, the band changing its plug-ins, Live sync stopping) with the
-- chain exactly as it was; the band's same chain landing or a Hop deleted by hand puts the Hop and the hold back; master, instruments and own
-- FX refused; Health's rows; the status's cpu.
package.path = "lib/?.lua;" .. package.path
local clock, front = 1000, "P1"
local xrun = 0
reaper = setmetatable({
  time_precise = function() return clock end,
  GetOS = function() return "Win64" end,
  GetExtState = function() return "" end,
  SetExtState = function() end,
  GetResourcePath = function() return "C:/res" end,
  EnumProjects = function() return front end,
  GetUnderrunTime = function() return xrun, 0, clock * 1000 end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() return "" end end end })

local band = require("band")
local logs = {}
band.log = function(s) logs[#logs + 1] = s end
local real_mirror = require("mirror")

-- ---- 1. pure --------------------------------------------------------------------------------------------------------------------------
local hops0 = require("hops")
local typeperf = '\r\n"(PDH-CSV 4.0)","\\\\DESK\\Processor(_Total)\\% Processor Time"\r\n"11/19/2026 20:00:01.234","23.456"\r\nExiting, please wait...\r\nThe command completed successfully.\r\n'
assert(hops0.cpu_parse(typeperf) == 20, "Windows: typeperf's value, in tens")
assert(hops0.cpu_parse('"11/19/2026 20:00:01","88,9"') == 90, "a decimal comma")
assert(hops0.cpu_parse("{ 2.00 1.50 1.20 }\n8\n") == 30, "macOS: load 2 of 8 cores = 25 -> 30")
assert(hops0.cpu_parse("6.10 5.00 4.00 3/400 999\n4\n") == 100, "Linux: over every core is 100")
assert(hops0.cpu_parse("") == nil and hops0.cpu_parse(nil) == nil and hops0.cpu_parse("nothing here") == nil, "unreadable: nil")
local peer_of = { Bo = "bo:1", Mac = "mac:1", Cy = "cy:1", Gus = "gus:1", Old = "old:1", Hot = "hot:1" }
local status_of = { Bo = { cpu = 30 }, Mac = { cpu = 10 }, Cy = { cpu = 0, recording = true }, Gus = { cpu = 0 }, Old = {}, Hot = { cpu = 90 } }
local lacks = { Mac = true }
local pick, why = hops0.offload_pick(peer_of, status_of, { Gus = true }, function(u) return not lacks[u] end)
assert(pick == "Bo" and why == "bo:1", "the least busy who can: Bo (Mac lacks one, Cy records, Gus is a guest, Old can't say, Hot is busy)")
status_of.Zed, peer_of.Zed = { cpu = 30 }, "zed:1"
assert(hops0.offload_pick(peer_of, status_of, { Gus = true }, function(u) return not lacks[u] end) == "Bo", "a tie: by name")
status_of.Bo.cpu = 40
assert(hops0.offload_pick(peer_of, status_of, { Gus = true }, function(u) return not lacks[u] end) == "Zed", "less busy wins")
pick, why = hops0.offload_pick({ Cy = "cy:1", Old = "old:1", Hot = "hot:1", Gus = "g:1" }, status_of, { Gus = true }, function() return true end)
assert(pick == nil and why:find("Cy is recording", 1, true) and why:find("Old's StudioSync is too old", 1, true) and why:find("Hot's computer is busy (90%)", 1, true)
  and not why:find("Gus", 1, true), "nobody: why, each (a guest isn't even named): " .. tostring(why))
assert(select(2, hops0.offload_pick({}, {}, {}, function() return true end)):find("connected", 1, true), "nobody here")
local r0 = { user = "Bo" }
assert(hops0.handback_why(r0, {}, { recording = true }, 0, 0) == "Bo started recording", "recording: at once")
assert(hops0.handback_why(r0, {}, {}, 5, 0) == nil, "a short gap: stays")
assert(hops0.handback_why(r0, {}, nil, 11, 0) == "Bo's computer went away", "gone")
assert(hops0.handback_why(r0, {}, {}, 11, 0) == "Bo's computer stopped hosting it", "here but not hosting")
assert(hops0.handback_why(r0, {}, {}, 0, 9):find("fell behind (9 late blocks", 1, true), "late blocks rising")
assert(hops0.handback_why(r0, {}, {}, 0, 8) == nil, "a few late blocks: stays")
assert(hops0.handback_why(r0, {}, {}, 0, 0, 1.5) == nil, "a little of the audio lost on the way (a packet now and then): stays")
assert(hops0.handback_why(r0, {}, {}, 0, 0, 3):find("network to Bo's computer fell behind (3.0%", 1, true), "more lost: back")
assert(#hops0.chain_of({ fxi = 2, fx = "VST: A" }) == 1 and hops0.chain_of({ fxi = 2, fx = "VST: A" })[1].fxi == 2, "one plug-in: a chain of one")
assert(#hops0.chain_of({ chain = { { fxi = 0, fx = "A" }, { fxi = 1, fx = "B" } } }) == 2, "a whole chain")
assert(hops0.chain_of({ chain = {} }) == nil and hops0.chain_of({ chain = { { fxi = "x", fx = "A" } } }) == nil and hops0.chain_of({ fx = "A" }) == nil, "malformed: nil")
local big = {}
for i = 1, hops0.MAX_CHAIN + 1 do big[i] = { fxi = i - 1, fx = "A" } end
assert(hops0.chain_of({ chain = big }) == nil, "too long: nil")

-- ---- 2. mirror sends the band's BYPASS lines for a chain held off here ---------------------------------------------------------------------
local function chunk_of(list) -- { {name, guid, bypass} }
  local out = { "<TRACK", "NAME Guitar", "<FXCHAIN", "SHOW 0", "DOCKED 0" }
  for _, f in ipairs(list) do
    out[#out + 1] = "BYPASS " .. f[3]; out[#out + 1] = '<VST "' .. f[1] .. '" x.dll 0 ""'; out[#out + 1] = "AAAA"; out[#out + 1] = ">"
    out[#out + 1] = "FXID " .. f[2]; out[#out + 1] = "WAK 0 0"
  end
  out[#out + 1] = ">"; out[#out + 1] = ">"
  return table.concat(out, "\n") .. "\n"
end
local band_view = real_mirror.track_head_parts(chunk_of({ { "VST: ReaEQ", "{E}", "0 0 0" }, { "VST: Comp", "{C}", "1 0 0" } }), "")
local here = chunk_of({ { "VST: ReaEQ", "{E2}", "1 0 0" }, { "VST: Comp", "{C2}", "1 0 0" }, { "CLAP: StudioSync Hop", "{H}", "0 0 0" } })
local held = real_mirror.track_head_parts(here, "{H}for=hop;" .. "{E2}held=0 0 0;{C2}held=1 0 0;")
assert(held.fx == band_view.fx and held.fxh == band_view.fxh, "held off here, sent as the band has it (and the Hop not at all):\n" .. held.fx .. "\n--\n" .. band_view.fx)
assert(real_mirror.track_head_parts(here, "{H}for=hop;").fxh ~= band_view.fxh, "without the held list it would go out bypassed")

-- ---- 3. a stand-in REAPER on two computers ------------------------------------------------------------------------------------------
local projs, nguid = { P1 = { tracks = {}, ext = {} }, P2 = { tracks = {}, ext = {} } }, 0
local function guid() nguid = nguid + 1; return string.format("{%08d-0000-0000-0000-000000000000}", nguid) end
local function hop_fx()
  return { name = "CLAP: StudioSync Hop (StudioSync)", guid = guid(), pnames = { "Hop id", "Latency budget", "Dry when late", "Late blocks" },
    lo = { 1, 256, 0, 0 }, hi = { 64, 8192, 1, 1e7 }, v = { 1, 7200, 1, 0 }, pdc = 7200 }
end
local function plugin(name, pdc, off)
  return { name = name, guid = guid(), pnames = { "Gain", "Drive" }, lo = { 0, 0 }, hi = { 1, 1 }, v = { 0.5, 0.25 }, pdc = pdc or 0, off = off }
end
local master = { guid = "{MASTER}", ext = {}, info = {}, fx = {}, name = "MASTER" }
local function track(p, oid, name, fx)
  local t = { guid = guid(), ext = { band_oid = oid or "" }, info = { B_MAINSEND = 1, I_PERFFLAGS = 0 }, fx = fx or {}, proj = p, name = name }
  projs[p].tracks[#projs[p].tracks + 1] = t
  return t
end
local function P(proj) return projs[proj or front] end
local function F(tr, i) return tr.fx[i + 1] end
reaper.GetMasterTrack = function() return master end
reaper.CountTracks = function(proj) return #P(proj).tracks end
reaper.GetTrack = function(proj, i) return P(proj).tracks[i + 1] end
reaper.GetTrackGUID = function(tr) return tr.guid end
reaper.GetTrackName = function(tr) return true, tr.name or "" end
reaper.DeleteTrack = function(tr) local ts = P(tr.proj).tracks; for i, t in ipairs(ts) do if t == tr then table.remove(ts, i); return end end end
reaper.GetSetMediaTrackInfo_String = function(tr, key, v, set)
  local k = key:match("^P_EXT:(.*)$") or key
  if set then tr.ext[k] = v end
  return true, tr.ext[k] or ""
end
reaper.GetMediaTrackInfo_Value = function(tr, k) return tr.info[k] or 0 end
reaper.SetMediaTrackInfo_Value = function(tr, k, v) tr.info[k] = v end
reaper.GetTrackStateChunk = function(tr)
  local list = {}
  for _, f in ipairs(tr.fx) do list[#list + 1] = { f.name, f.guid, (f.off and "1" or "0") .. " 0 0" } end
  return true, chunk_of(list)
end
reaper.TrackFX_GetCount = function(tr) return #tr.fx end
reaper.TrackFX_GetFXGUID = function(tr, i) return F(tr, i) and F(tr, i).guid end
reaper.TrackFX_GetFXName = function(tr, i) return true, F(tr, i).name end
reaper.TrackFX_GetEnabled = function(tr, i) return not F(tr, i).off end
reaper.TrackFX_SetEnabled = function(tr, i, on) F(tr, i).off = not on end
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
reaper.TrackFX_AddByName = function(tr, name, _, at)
  if name ~= "CLAP: StudioSync Hop" then return -1 end
  local pos = math.min(-1000 - at, #tr.fx)
  table.insert(tr.fx, pos + 1, hop_fx())
  return pos
end
reaper.TrackFX_SetOffline = function(tr, i, off) F(tr, i).offline = off end
reaper.TrackFX_GetOffline = function(tr, i) return F(tr, i).offline == true end
reaper.TrackFX_Delete = function(tr, i) table.remove(tr.fx, i + 1) end
reaper.TrackFX_CopyToTrack = function(src, si, dst, di)
  local f, c = F(src, si), {}
  for k, v in pairs(f) do c[k] = type(v) == "table" and { table.unpack(v) } or v end
  c.guid = guid()
  table.insert(dst.fx, di + 1, c)
end
reaper.GetProjExtState = function(proj, sec, k) return 1, P(proj).ext[sec .. "/" .. k] or "" end
reaper.SetProjExtState = function(proj, sec, k, v) P(proj).ext[sec .. "/" .. k] = v end

local E = { connect = {}, serve = {}, status = {}, live = true }
reaper.StudioSync_HopConnect = function(id, peer, json) E.connect[#E.connect + 1] = { id = id, peer = peer, json = json }; return 1 end
reaper.StudioSync_HopServe = function(json) E.serve[#E.serve + 1] = json; return 1 end
reaper.StudioSync_HopStatus = function(id) return band.json_encode(E.status[id] or { hop = id, ready = true }) end
reaper.StudioSync_LiveAudioStatus = function() return band.json_encode({ running = E.live }) end

local sent = {}
local DEVS = { ["bo:1"] = "DEVBO", ["mac:1"] = "DEVMAC", ["cy:1"] = "DEVCY", ["gus:1"] = "DEVGUS" }
package.loaded.direct = {
  peers = function() return { "bo:1", "mac:1", "cy:1", "gus:1" }, DEVS end,
  send_live = function(cfg, kind, d, song, room, id, to) sent[#sent + 1] = { kind = kind, d = d, to = to }; return true end,
  port = function() return 47281 end,
}
band.files = function(dir) return dir:find("_band/devices", 1, true) and { "bo.json", "mac.json", "cy.json", "gus.json" } or {} end
band.read_json = function(p)
  for _, u in ipairs({ "bo", "mac", "cy", "gus" }) do if p:find(u .. ".json", 1, true) then return { user = u:sub(1, 1):upper() .. u:sub(2), device = "DEV" .. u:upper() } end end
end
package.loaded.groups = { tailnet = function() return { suffix = "ts.net" } end, sonobus_secret = function() return "s3cret" end }
local has = { Bo = { reaeq = true, amp = true, comp = true }, Mac = { reaeq = true }, Cy = { reaeq = true, amp = true, comp = true }, Gus = { reaeq = true, amp = true, comp = true } }
package.loaded.prints = { has = function(_, u, keys) for _, k in ipairs(keys) do if not (has[u] or {})[k] then return false end end; return true end,
  fx_here = function(tr, i) return not F(tr, i).offline end }
package.loaded.plugins = { key = function(n) return ((n or ""):gsub("^%w+:%s*", "")):gsub("%s*%(.-%)$", ""):lower() end }
local statuses = { { user = "Bo", cpu = 20 }, { user = "Mac", cpu = 0 }, { user = "Cy", cpu = 0, recording = true }, { user = "Gus", cpu = 0 } }
package.loaded.presence = { peers = function() return statuses end }
package.loaded.removal = { guest_names = function() return { Gus = true } end }
local probe = typeperf
package.loaded.services = { run_hidden = function(name) assert(name == "cpu"); return probe end }
package.loaded.mirror = {
  track_oid = function(tr) return (tr.ext.band_oid or ""):upper() end,
  live_fx = function() return {} end,
  fx_blocks = real_mirror.fx_blocks,
  add_local_track = function(proj, name, tag)
    local t = track(proj, "", name)
    t.ext.band_local = tag
    return t
  end,
}
package.loaded.hops = nil
local hops = require("hops")
local cfg = { root = "J:/St/Smiley", user = "James" }
local b = { song = "Song", room = "main" }

-- ---- 4. James offloads Guitar ------------------------------------------------------------------------------------------------------------
front = "P1"
local eq, amp, comp = plugin("VST3: ReaEQ (Cockos)"), plugin("VST3: Amp (X)"), plugin("VST3: Comp (Y)", 0, true) -- (Comp is bypassed in the song)
local gtr = track("P1", "aaa", "Guitar", { eq, amp, comp })
assert(hops.offload_toggle("P1", cfg, b, gtr) == nil, "offloaded: " .. tostring(logs[#logs]))
local rec = hops.offload_of("P1", gtr)
assert(rec and rec.user == "Bo" and rec.peer == "bo:1" and rec.offload and #rec.chain == 3, "to Bo (Mac lacks Amp, Cy records, Gus is a guest)")
local hop = gtr.fx[4]
assert(#gtr.fx == 4 and hop.name:find("StudioSync Hop", 1, true) and hop.v[3] == 1, "one Hop at the end, dry when late")
assert(eq.off and amp.off and comp.off, "the song's FX held off here")
assert(gtr.ext.band_fx_held == eq.guid .. "held=0 0 0;" .. amp.guid .. "held=0 0 0;" .. comp.guid .. "held=1 0 0;", "with the band's lines kept: " .. tostring(gtr.ext.band_fx_held))
assert(gtr.ext.band_local_fx == hop.guid .. "for=hop;", "the Hop is this computer's own")
local ask = sent[#sent]
assert(ask.d.op == "serve" and ask.to[1] == "bo:1" and #ask.d.chain == 3 and ask.d.chain[2].fx == amp.name and ask.d.chain[3].fxi == 2, "Bo asked for the whole chain")
assert(logs[#logs]:find("Guitar's 3 effects now run on Bo's computer", 1, true), "said")
-- its chain as mirror sends it is the band's, held or not
local function sent_view(tr)
  local _, ch = reaper.GetTrackStateChunk(tr)
  return real_mirror.track_head_parts(ch, tr.ext.band_local_fx .. (tr.ext.band_fx_held or "")).fxh
end
local before = real_mirror.track_head_parts(chunk_of({ { eq.name, "{x}", "0 0 0" }, { amp.name, "{y}", "0 0 0" }, { comp.name, "{z}", "1 0 0" } }), "").fxh
assert(sent_view(gtr) == before, "the band sees the chain as it was")

-- ---- 5. Bo hosts it -----------------------------------------------------------------------------------------------------------------------
front = "P2"
local beq, bamp, bcomp = plugin("VST3: ReaEQ (Cockos)", 10), plugin("VST3: Amp (X)", 64), plugin("VST3: Comp (Y)", 6, true)
track("P2", "AAA", "Guitar", { beq, bamp, bcomp })
hops.on_msg("P2", cfg, ask.d, "Song", "main")
local hidden = projs.P2.tracks[2]
assert(hidden and hidden.ext.band_local == "hop" and #hidden.fx == 5, "a hidden track: Hop X, the three copies, Hop Y")
assert(hidden.fx[2].name == beq.name and hidden.fx[3].name == bamp.name and hidden.fx[4].name == bcomp.name and hidden.fx[4].off, "in order, bypass as the song has it")
assert(hidden.fx[1].v[1] == 64 and hidden.fx[5].v[1] == 63 and hidden.chain.chain_pdc_mode == "2", "ids, PDC ignored")
assert(band.json_decode(E.serve[#E.serve]).pdc == 80, "the chain's latency summed: 10 + 64 + 6")
bamp.v[2], bcomp.off = 0.8, false -- (a knob turned and Comp switched on, in the song)
E.status[64] = { hop = 64, net = { alive = true, lined_up = true, heard = true, idle_s = 0.1, remote_ms = 30, slips = 0 } }
clock = clock + 1
hops.tick(cfg, b, "P2")
assert(hidden.fx[3].v[2] == 0.8 and not hidden.fx[4].off, "the copies follow the song's knobs and bypass")
hops.on_msg("P2", cfg, { op = "serve", token = 5, oid = "AAA", fx = "x", chain = { { fxi = 0, fx = beq.name }, { fxi = 1, fx = "VST3: Nope" } }, user = "James" }, "Song", "main")
assert(sent[#sent].d.op == "fail" and sent[#sent].d.why:find("Nope", 1, true) and #projs.P2.tracks == 2, "a chain it hasn't all of: refused, nothing made")
package.loaded.hops = nil -- (Live sync reloads in place for a new StudioSync: the same Lua, the module loaded again)
hops = require("hops")
hops.on_msg("P2", cfg, { op = "stop", token = ask.d.token }, "Song", "main")
assert(#projs.P2.tracks == 1, "stopped, after a reload too: gone")
local stray = track("P2", "", "StudioSync hop for James")
stray.ext.band_local = "hop"
clock = clock + 1
hops.S.at = -math.huge
hops.tick(cfg, b, "P2")
assert(#projs.P2.tracks == 1, "a hidden hop track nothing here hosts (left by a crash, or an older StudioSync's reload): gone")

-- ---- 6. James's tick: fine, then back by itself --------------------------------------------------------------------------------------
front = "P1"
local function tick(dt) clock = clock + (dt or 1); hops.S.at = -math.huge; hops.tick(cfg, b, "P1") end
local good = { resolved = true, serving = true, active = true, remote_alive = true, same_rate = true, rtt_ms = 60, remote_ms = 25, need_ms = 120, budget_ms = 150, slack_ms = 30,
  sent = 48000, lost = 0, late = 0, remote_slips = 0 }
E.status[rec.id] = { hop = rec.id, late = 0, net = { resolved = true, serving = false } }
tick(5)
E.status[rec.id].late = 20
tick(hops.LATE_WINDOW)
assert(hops.offload_of("P1", gtr), "not hosted yet, inside the start grace: stays (the blocks played dry meanwhile aren't falling behind)")
E.status[rec.id] = { hop = rec.id, late = 20, net = good }
tick()
E.status[rec.id].late = 32 -- (the first blocks once it runs: still settling)
tick(hops.SETTLE)
local rows = hops.health_rows(cfg, "P1")
assert(rows[1][4]:find("Guitar's effects run on Bo's computer: round trip 60 ms", 1, true) and rows[1][4]:find("32 late blocks", 1, true), "Health: where and how: " .. rows[1][4])
tick(hops.LATE_WINDOW)
E.status[rec.id].late = 41
tick(hops.LATE_WINDOW)
assert(not hops.offload_of("P1", gtr), "late blocks rose: back")
assert(#gtr.fx == 3 and not eq.off and not amp.off and comp.off, "the chain exactly as it was (Comp still bypassed as the song has it)")
assert(gtr.ext.band_fx_held == "" and gtr.ext.band_local_fx == "", "nothing of the offload left")
assert(sent[#sent].d.op == "stop" and E.connect[#E.connect].json:find('"stop":true', 1, true), "Bo and the extension told")
rows = hops.health_rows(cfg, "P1")
assert(rows[#rows][4]:find("Guitar's effects are back on this computer: Bo's computer fell behind", 1, true) and logs[#logs]:find("fell behind", 1, true), "never silent")
clock = clock + hops.SAY_BACK
assert(#hops.health_rows(cfg, "P1") == 0, "the line goes after a while")

-- recording, going away
local function offload()
  assert(hops.offload_toggle("P1", cfg, b, gtr) == nil, "offloaded again")
  rec = hops.offload_of("P1", gtr)
  E.status[rec.id] = { hop = rec.id, late = 0, net = good }
  tick()
  assert(hops.offload_of("P1", gtr), "running")
end
offload()
statuses[1].recording = true
tick()
assert(not hops.offload_of("P1", gtr) and logs[#logs]:find("Bo started recording", 1, true) and not amp.off, "Bo records: back at once")
statuses[1].recording = nil
offload()
local function with(t) local c = {}; for k, v in pairs(good) do c[k] = v end; for k, v in pairs(t) do c[k] = v end; return c end
E.status[rec.id].net = with({ sent = 48000, lost = 0 })
tick(hops.LATE_WINDOW)
E.status[rec.id].net = with({ sent = 528000, lost = 4800, holes = 30 }) -- (1% of 10 s: a packet now and then)
tick(hops.LATE_WINDOW)
assert(hops.offload_of("P1", gtr) and hops.health_rows(cfg, "P1")[1][4]:find("30 dropouts", 1, true), "1% lost: stays, Health counts the dropouts")
E.status[rec.id].net = with({ sent = 1008000, lost = 19200 })
tick(hops.LATE_WINDOW)
assert(not hops.offload_of("P1", gtr) and logs[#logs]:find("didn't come back in time", 1, true), "3% lost: back")
offload()
E.status[rec.id] = { hop = rec.id, net = { resolved = true, serving = false } }
table.remove(statuses, 1)
tick(5)
assert(hops.offload_of("P1", gtr), "a few seconds: stays")
tick(hops.AWAY)
assert(not hops.offload_of("P1", gtr) and logs[#logs]:find("Bo's computer went away", 1, true), "gone: back")
table.insert(statuses, 1, { user = "Bo", cpu = 20 })

-- the band's chain lands (same plug-ins: the Hop and hold go back; others: back here); a Hop deleted by hand
offload()
gtr.fx = { plugin(eq.name), plugin(amp.name, 0, true), plugin(comp.name, 0, true) } -- (the band bypassed Amp; new ids; mirror empties the own list)
gtr.ext.band_local_fx = ""
tick()
rec = hops.offload_of("P1", gtr)
assert(rec and #gtr.fx == 4 and gtr.fx[4].name:find("Hop", 1, true) and gtr.fx[1].off and gtr.fx[2].off, "the same plug-ins: the Hop and the hold back")
assert(rec.held[gtr.fx[1].guid] == "0 0 0" and rec.held[gtr.fx[2].guid] == "1 0 0", "the band's states now")
table.remove(gtr.fx, 4)
tick()
rec = hops.offload_of("P1", gtr)
assert(rec and rec.held[gtr.fx[1].guid] == "0 0 0", "a Hop deleted by hand: back, and the chain still comes back on, not bypassed")
gtr.fx = { plugin(eq.name), plugin("VST3: Other (Z)") }
gtr.ext.band_local_fx = ""
tick()
assert(not hops.offload_of("P1", gtr) and logs[#logs]:find("the band changed its effects", 1, true) and not gtr.fx[1].off, "other plug-ins: back here")

-- Live sync stops; brought back by hand
gtr.fx = { eq, amp, comp }
eq.off, amp.off, comp.off = false, false, true
offload()
hops.on_exit("P1", cfg)
assert(not hops.offload_of("P1", gtr) and not amp.off and comp.off, "Live sync stops: back")
offload()
hops.offload_toggle("P1", cfg, b, gtr)
assert(not hops.offload_of("P1", gtr) and #gtr.fx == 3 and not eq.off, "the same button brings it back")

-- refused
assert(hops.offload_toggle("P1", cfg, b, master):find("not the master", 1, true), "never the master")
local synth = track("P1", "bbb", "Keys", { plugin("VSTi: Synth (S)") })
assert(hops.offload_toggle("P1", cfg, b, synth):find("instrument", 1, true), "an instrument: a hop carries audio")
local own = plugin("JS: translation")
local tr3 = track("P1", "ccc", "Bass", { plugin(eq.name), own })
tr3.ext.band_local_fx = own.guid .. "for=" .. "{X};"
assert(hops.offload_toggle("P1", cfg, b, tr3):find("of this computer's own", 1, true), "this computer's own FX on it: refused")
assert(hops.offload_toggle("P1", cfg, b, track("P1", "ddd", "Empty", {})):find("no effects", 1, true), "nothing to offload")
statuses[1].cpu = 90
assert(hops.offload_toggle("P1", cfg, b, gtr):find("Bo's computer is busy (90%)", 1, true), "nobody with headroom: said why")
statuses[1].cpu = 20

-- ---- 7. the status's cpu --------------------------------------------------------------------------------------------------------------
assert(hops.cpu_now() == 20, "from the probe")
probe = nil
assert(hops.cpu_now() == 50, "not read yet: half")
xrun = clock * 1000 - 5000
assert(hops.cpu_now() == 100, "a dropout in the last minute: no headroom")
print("ok: shared CPU")
