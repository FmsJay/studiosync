-- Borrow a plug-in for real, and the Hop's other loose ends (docs/rt/rt-borrow.md; lib/hops.lua, lib/hoptry.lua, lib/prints.lua): the
-- pure parts (a plug-in's block checked before it goes into a track, and put into a chain), then the stand-in REAPER of
-- tests/test_0_60_rt_hoptry.lua (with track chunks) on both computers. Deleting the StudioSync Hop is the same as stopping it (a run-on hop,
-- an offload, and Bo's hidden track of a try); a plug-in installed since runs here and its hop stops; an ask for your plug-in on the panel's
-- bar and every web page, with Allow / Deny; James adds Bo's Serum to his Keys track for real: Bo's block goes into the chain in front of the
-- Hop (only while stopped), the try becomes a hop for the song's plug-in hosted from Bo's copy of the song, its knobs still turn, and what he
-- turned goes into the song once stopped; Stop leaves the plug-in in the project. Auto plays a part through a hop; old per-track dry / wet
-- choices are cleared once.
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


-- ---- rt-borrow's additions: track chunks (FXCHAIN groups from each FX; set back, a missing plug-in stays offline with its block), the real
-- mirror.fx_blocks, ExtState, items for prints --------------------------------------------------------------------------------------------
local function fx_group(f)
  local head = f.block_head or string.format('<VST "%s" x.dll 0 "" 0<00>', f.name)
  return { "BYPASS 0 0 0", head, f.state or "U1RBVEU=", ">", "FLOATPOS 0 0 0 0", "FXID " .. f.guid, "WAK 0 0" }
end
reaper.GetTrackStateChunk = function(tr)
  local out = { "<TRACK", "NAME x", "<FXCHAIN", "SHOW 0" }
  for _, f in ipairs(tr.fx) do for _, l in ipairs(fx_group(f)) do out[#out + 1] = "  " .. l end end
  out[#out + 1] = ">"; out[#out + 1] = ">"
  return true, table.concat(out, "\n") .. "\n"
end
local chunk_sets = 0
reaper.SetTrackStateChunk = function(tr, chunk)
  chunk_sets = chunk_sets + 1
  local by, new, cur, depth = {}, {}, nil, 0
  for _, f in ipairs(tr.fx) do by[f.guid] = f end
  local inside = false
  for l in chunk:gmatch("[^\n]+") do
    local s = l:match("^%s*(.-)%s*$")
    if s == "<FXCHAIN" then inside, depth = true, 1
    elseif inside then
      local top = depth == 1
      if s:sub(1, 1) == "<" then depth = depth + 1 elseif s == ">" then depth = depth - 1 end
      if depth == 0 then inside = false
      elseif top and s:match("^BYPASS") then cur = {}; new[#new + 1] = cur
      elseif top and s:match("^<") then cur.head = s; cur.name = s:match('^<%u+%d?%s+"([^"]+)"')
      elseif top and s:match("^FXID ") then cur.guid = s:match("^FXID (%S+)")
      elseif not top and depth == 2 and cur and cur.head then cur.state = s end
    end
  end
  local fx = {}
  for _, c in ipairs(new) do
    local f = c.guid and by[c.guid]
    if not f then
      f = plugin(c.name)
      if c.guid then f.guid = c.guid end
      local here = false
      for _, n in ipairs(installed[tr.proj] or {}) do here = here or n == c.name end
      f.offline = not here -- (a plug-in this computer hasn't: REAPER keeps its block, offline)
      f.block_head = c.head
    end
    f.state = c.state
    fx[#fx + 1] = f
  end
  tr.fx = fx
  return true
end
do -- (the real mirror.fx_blocks: what the owner sends is what REAPER's chunk has)
  local stub = package.loaded.mirror
  package.loaded.mirror = nil
  local real = require("mirror")
  package.loaded.mirror = stub
  stub.fx_blocks = real.fx_blocks
end

local hops, hoptry = require("hops"), require("hoptry")
local cfg = { root = "J:/St/Smiley", user = "James" }
local cfg_bo = { root = "J:/St/Smiley", user = "Bo" }
local b = { song = "Song", room = "main" }
local function last(op) for i = #sent, 1, -1 do if sent[i].d.op == op then return sent[i] end end end
local function tick(proj, c) clock = clock + 1; hops.tick(c or cfg, b, proj) end
-- (one Lua state plays both computers: Bo's hosting is put aside while James's ticks run, and James's tries while Bo's do)
local bo_serving = {}
local function as_james() front = "P1"; bo_serving, hops.S.serving = hops.S.serving, {} end
local function as_bo() front = "P2"; hops.S.serving = bo_serving end

-- ---- 1. pure: a plug-in's block checked, and put into a chain ---------------------------------------------------------------------------
local block = table.concat({ "BYPASS 0 0 0", '<VST "VST3i: Serum (Xfer)" Serum.vst3 0 "" 1<00>', "c3RhdGU=", ">", "FLOATPOS 0 0 0 0", "FXID {OWNER-1}", "WAK 0 0" }, "\n")
local lines, name = hops.block_lines(block, "serum")
assert(lines and name == "VST3i: Serum (Xfer)" and #lines == 6 and lines[1] == "BYPASS 0 0 0" and lines[6] == "WAK 0 0", "a plug-in's block, its name")
for _, l in ipairs(lines) do assert(not l:match("^FXID"), "its FXID left out (REAPER gives it one here)") end
assert(select(2, hops.block_lines(block, "other")):find("another plug-in", 1, true), "another plug-in than the one asked for: refused")
assert(not hops.block_lines("<TRACK\n>", "serum"), "not a plug-in's block")
assert(not hops.block_lines("BYPASS 0 0 0\n<CONTAINER\n>", "serum"), "a container isn't a plug-in a hop runs")
assert(not hops.block_lines("BYPASS 0 0 0\n" .. '<VST "VST3i: Serum (Xfer)" s 0 "" 1<00>' .. "\nc3RhdGU=", "serum"), "unbalanced: refused")
assert(not hops.block_lines("BYPASS 0 0 0\n>\n>", "serum"), "closes what it never opened: refused")
assert(not hops.block_lines(block .. string.rep("x", hops.KEEP_MAX), "serum"), "too big: refused")
local two = block .. "\n" .. '<VST "VST: Evil (X)" evil.dll 0 "" 1<00>\nZXZpbA==\n>\n<PARMENV 1 0 1 0.5\nPT 0 0.5 0\n>'
lines = hops.block_lines(two, "serum")
assert(lines and #lines == 6 and not table.concat(lines, "\n"):find("Evil", 1, true) and not table.concat(lines, "\n"):find("PARMENV", 1, true),
  "a second plug-in or a knob's envelope in what came is left out")
assert(select(2, hops.block_lines('BYPASS 0 0 0\n<JS "utility/volume" ""\n0 -\n>', "serum")):find("another", 1, true), "a JSFX by its path")
lines = hops.block_lines(block, "serum")
local chunk = "<TRACK\n<FXCHAIN\nSHOW 0\nBYPASS 0 0 0\n<VST \"A\" a 0 \"\" 1<00>\nQQ==\n>\nFXID {A}\nWAK 0 0\nBYPASS 0 0 0\n<CLAP \"CLAP: StudioSync Hop\" h\n>\nFXID {HOP}\nWAK 0 0\n>\n>\n"
local put = hops.put_block(chunk, lines, "{HOP}")
assert(put and put:find("FXID {A}\nWAK 0 0\nBYPASS 0 0 0\n<VST \"VST3i: Serum", 1, true) and put:find("WAK 0 0\nBYPASS 0 0 0\n<CLAP", 1, true), "in front of the Hop")
assert(put:sub(-2) == ">\n" and select(2, put:gsub("FXID", "")) == 2, "nothing else changed; no id of its own (REAPER gives one)")
put = hops.put_block(put, hops.block_lines(block:gsub("c3RhdGU=", "bmV3"), "serum"), nil, "{SERUM-HERE}")
assert(put == nil, "replace: only a plug-in that's there")
local with_id = hops.put_block(chunk, lines, nil, "{A}")
assert(with_id and with_id:find("FLOATPOS 0 0 0 0\nFXID {A}\nWAK 0 0\nBYPASS 0 0 0\n<CLAP", 1, true) and not with_id:find("QQ==", 1, true), "replaced in place, keeping its id")
assert(hops.put_block(chunk, lines, "{NOPE}") == nil and hops.put_block("<TRACK\n>", lines, "{HOP}") == nil, "nowhere to put it: nil")

-- ---- 2. deleting the Hop is stopping it (findings 8) ----------------------------------------------------------------------------------
front = "P1"
local amp = plugin("VST3: Neural Amp (Neural DSP)")
amp.offline = true
local gtr = track("P1", "ggg", { plugin("VST3: ReaEQ (Cockos)"), amp })
gtr.ext.P_NAME = "Gtr"
local id = hops.make("P1", cfg, gtr, 1, "Bo", "bo-pc.tail99.ts.net:47281", "Song", "main")
assert(id == 1 and hops.is_hop_name(gtr.fx[3].name), "a hop for Neural Amp")
local hop_guid = gtr.fx[3].guid
tick()
assert(hops.S.stand[amp.guid] == "GGG", "a plug-in a hop plays here is known (prints.hop_plays)")
-- the band's chain replaced the track's (mirror empties this computer's list): the Hop goes back in, as before
table.remove(gtr.fx, 3); gtr.ext.band_local_fx = ""
tick()
assert(hops.records("P1")["1"] and hops.is_hop_name(gtr.fx[3].name), "replaced by the band: put back")
-- deleted by hand (the list still names it): stopped, on both sides, nothing left
hop_guid = gtr.fx[3].guid
table.remove(gtr.fx, 3)
local nsent, nconn = #sent, #E.connect
tick()
assert(next(hops.records("P1")) == nil, "deleted by hand: the hop is stopped")
assert(not gtr.ext.band_local_fx:find(hop_guid, 1, true) and not gtr.ext.band_local_fx:find("for=hop", 1, true), "nothing of it left in the track's list")
assert(#sent == nsent + 1 and sent[#sent].d.op == "stop" and sent[#sent].to[1] == "bo-pc.tail99.ts.net:47281", "Bo told, as Stop tells")
assert(E.connect[#E.connect].json:find('"stop":true', 1, true) and #E.connect == nconn + 1, "the extension's side stopped")
assert(#gtr.fx == 2 and gtr.info.I_PERFFLAGS == 0, "the track as it was")
assert(hops.S.back[#hops.S.back].text:find("Hop was removed from Gtr", 1, true), "said, on Health and in the log")
assert(hops.S.stand[amp.guid] == nil, "and its plug-in plays as Auto says again")
-- the same for an offload: the chain comes back on
local fx1, fx2 = plugin("VST3: ReaEQ (Cockos)"), plugin("VST3: ReaComp (Cockos)")
local vox = track("P1", "vvv", { fx1, fx2 })
vox.ext.P_NAME = "Vox"
reaper.TrackFX_GetEnabled = function(tr, i) return not F(tr, i).off end
reaper.TrackFX_SetEnabled = function(tr, i, on) F(tr, i).off = not on end
local oid = hops.offload("P1", cfg, vox, "Bo", "bo-pc.tail99.ts.net:47281", "Song", "main")
assert(oid and fx1.off and fx2.off and hops.is_hop_name(vox.fx[3].name), "offloaded: its chain held off here")
table.remove(vox.fx, 3)
tick()
assert(next(hops.records("P1")) == nil and not fx1.off and not fx2.off and vox.ext.band_fx_held == "", "its Hop deleted: back on here, as Stop does")
assert(not vox.ext.band_local_fx:find("for=hop", 1, true) and hops.S.back[#hops.S.back].text:find("Vox's effects are back on this computer: its StudioSync Hop was removed", 1, true), "said")
-- a plug-in installed since: it runs here, the hop stops (it would apply it twice)
id = hops.make("P1", cfg, gtr, 1, "Bo", "bo-pc.tail99.ts.net:47281", "Song", "main")
amp.offline = false
tick()
assert(next(hops.records("P1")) == nil and hops.S.back[#hops.S.back].text:find("Neural Amp loads on this computer now", 1, true), "installed here now: the hop stops by itself")
amp.offline = true

-- ---- 3. Bo's side: the hidden track of a try deleted by hand is Stop too ---------------------------------------------------------------
local keys = track("P1", "kkk", { plugin("VST3: ReaEQ (Cockos)") })
keys.ext.P_NAME = "Keys"
id = hoptry.start("P1", cfg, b, keys, "Bo", "serum")
assert(id == 1, "James tries Bo's Serum")
assert(select(2, hoptry.start("P1", cfg, b, keys, "Bo", "reaeq")):find("installed on this computer", 1, true), "one installed here: not tried over the link (it runs here)")
local ask = last("serve")
as_bo()
local bo_keys = track("P2", "KKK", { plugin("VST3: ReaEQ (Cockos)") })
hops.on_msg("P2", cfg_bo, ask.d, "Song", "main")
-- the ask on REAPER's panel bar and every web page, with Allow / Deny right there (findings: "a notification when someone asks")
tick("P2", cfg_bo)
local bar = band.json_decode(reaper.GetExtState(band.SECTION, "try asks"))
assert(type(bar) == "table" and bar[1].user == "James" and bar[1].key == "serum" and bar[1].token == ask.d.token, "the panel's bar has the ask")
local published = {}
hoptry.web_tick("P2", cfg_bo, b, function(t, v) published[t] = v end, clock + 1000)
assert(published.tryask and published.tryask.asks[1].user == "James" and published.tryfx == nil, "every page gets the ask (no Try tab open)")
local drawn = {}
local fake_imgui = { AlignTextToFramePadding = function() end, TextColored = function(_, _, t) drawn[#drawn + 1] = t end, SameLine = function() end,
  SmallButton = function(_, label) drawn[#drawn + 1] = label; return label:find("^Allow") ~= nil end, SetItemTooltip = function() end }
hoptry.bar({}, fake_imgui)
assert(drawn[1]:find("James asks to try your serum", 1, true) and drawn[2]:find("^Allow##tryask") and drawn[3]:find("^Deny##tryask"), "the bar: the ask, Allow, Deny")
tick("P2", cfg_bo) -- (the bar's Allow, taken by Live sync)
assert(next(hoptry.asks()) == nil and reaper.GetExtState(band.SECTION, "try answer") == "" and reaper.GetExtState(band.SECTION, "try asks") == "", "allowed from the bar; the bar clears")
hops.on_msg("P2", cfg_bo, ask.d, "Song", "main")
local hidden = projs.P2.tracks[#projs.P2.tracks]
assert(hidden.ext.band_local == "hop" and hidden.fx[2].name == "VST3i: Serum (Xfer)", "hosted after the yes")
E.status[64] = { hop = 64, ready = true, net = { role = "serve", alive = true, lined_up = true, heard = true, idle_s = 0.1, remote_ms = 31, slips = 0 } }
tick("P2", cfg_bo)
local params = last("params")
assert(params and params.d.token == ask.d.token, "its knobs go to James")

-- ---- 4. borrow for real (findings 3): the try goes into the track's chain, and the hop plays it from Bo's copy of the song ------------------
as_james()
hops.on_msg("P1", cfg, params.d, "Song", "main")
hops.on_msg("P1", cfg, { op = "kept", token = ask.d.token, block = block, user = "Bo" }, "Song", "main")
assert(hops.S.kept[ask.d.token] == nil, "a block nobody asked for is ignored")
local said = hoptry.web_action("P1", cfg, b, { keep = 1 })
local kreq = last("keep")
assert(said:find("adding serum to Keys for real", 1, true) and kreq.d.token == ask.d.token and kreq.to[1] == "bo-pc.tail99.ts.net:47281", "Add to track: Bo's computer asked for its settings")
assert(hoptry.model("P1", cfg, b).tries[1].keeping, "the page shows it on its way")
assert(select(2, hoptry.keep("P1", cfg, 1)):find("on its way", 1, true), "not asked twice")
as_bo()
hidden.fx[2].state = "Qk9fU0VUVElOR1M=" -- (what Bo's copy holds now: James's knob turns included)
hops.on_msg("P2", cfg_bo, { op = "keep", token = ask.d.token, user = "Mac" }, "Song", "main")
assert(last("kept") == nil, "only the one trying it gets its settings")
hops.on_msg("P2", cfg_bo, kreq.d, "Song", "main")
local kept = last("kept")
assert(kept and kept.d.block:find('<VST "VST3i: Serum (Xfer)"', 1, true) and kept.d.block:find("Qk9fU0VUVElOR1M=", 1, true),
  "Bo's computer sends the plug-in's block as its copy has it")
assert(logs[#logs]:find("James is adding your serum to their track for real", 1, true), "Bo is told what it means")
as_james()
hops.on_msg("P1", cfg, kept.d, "Song", "main")
assert(hops.S.kept[ask.d.token], "kept until playback stops")
ps = 1
tick()
assert(#keys.fx == 2 and hops.records("P1")["1"].try, "not while playing (a chain set from its chunk reloads its plug-ins)")
ps = 0
local old_token, nconn2 = ask.d.token, #E.connect
tick()
local rec = hops.records("P1")["1"]
assert(#keys.fx == 3 and keys.fx[2].name == "VST3i: Serum (Xfer)" and keys.fx[2].offline and keys.fx[2].state == "Qk9fU0VUVElOR1M=" and hops.is_hop_name(keys.fx[3].name),
  "stopped: Serum is in the track's chain for real, in front of the Hop (offline here: James hasn't it), with Bo's settings")
assert(rec.borrowed and not rec.try and rec.of == keys.fx[2].guid and rec.fxi == 1 and rec.fx == "VST3i: Serum (Xfer)" and rec.key == "serum" and rec.token ~= old_token,
  "the try is now a hop for a plug-in of the song")
assert(keys.ext.band_local_fx == keys.fx[3].guid .. "for=hop;", "the Hop is still this computer's own (Serum is the song's: mirror sends it)")
local stop = last("stop")
assert(stop.d.token == old_token, "Bo's computer drops the try's hidden track")
assert(hops.S.params[rec.token] and not hops.S.params[old_token], "its knobs show on meanwhile")
assert(logs[#logs]:find("serum is on Keys for real now", 1, true), "said")
tick()
local serve2 = last("serve")
assert(serve2.d.token == rec.token and serve2.d.borrowed == true and not serve2.d.try and serve2.d.fxi == 1 and serve2.d.fx == "VST3i: Serum (Xfer)", "Bo asked to host it as the song's plug-in")
assert(#E.connect > nconn2 and band.json_decode(E.connect[#E.connect].json).token == rec.token, "connected with the new token")
assert(hops.S.stand[rec.of] == "KKK", "Auto counts it as here while the hop runs (its dry take through the hop, not the print)")
local model = hoptry.model("P1", cfg, b)
assert(model.tries[1].borrowed and model.tries[1].fx == "serum", "the page shows it borrowed")
-- Bo: before the band's change reaches his copy, a wait (said so); then hosted from his copy of the song
as_bo()
hops.on_msg("P2", cfg_bo, stop.d, "Song", "main")
assert(not hops.S.serving[old_token] and projs.P2.tracks[#projs.P2.tracks] ~= hidden, "the try's hidden track gone")
hops.on_msg("P2", cfg_bo, serve2.d, "Song", "main")
assert(last("fail").d.why:find("waiting for the track's new plug-in", 1, true), "not in Bo's copy yet: James is told it waits")
local bo_serum = plugin("VST3i: Serum (Xfer)")
table.insert(bo_keys.fx, bo_serum) -- (mirror brings the band's chain: Serum, loaded on Bo's computer)
hops.on_msg("P2", cfg_bo, serve2.d, "Song", "main")
local sv = hops.S.serving[rec.token]
local hidden2 = projs.P2.tracks[#projs.P2.tracks]
assert(sv and sv.borrowed and hidden2.fx[2].name == "VST3i: Serum (Xfer)", "hosted: a copy of Bo's copy of the song's Serum")
E.status[sv.x] = { hop = sv.x, ready = true, net = { role = "serve", alive = true, lined_up = true, heard = true, idle_s = 0.1, remote_ms = 31, slips = 0 } }
local n0 = #sent
tick("P2", cfg_bo)
local p2 = last("params")
assert(#sent > n0 and p2.d.token == rec.token and p2.d.fx == "VST3i: Serum (Xfer)", "its knobs go to James, as a try's")
-- James turns a knob: Bo's hidden copy follows at once; the song gets it once playback has stopped a moment (the freeze)
as_james()
hops.on_msg("P1", cfg, p2.d, "Song", "main")
assert(hoptry.set_param("P1", cfg, 1, 0, 0.7), "a knob turned")
local setm = last("set")
as_bo()
hops.on_msg("P2", cfg_bo, setm.d, "Song", "main")
assert(hidden2.fx[2].v[1] == 0.7, "Bo's copy turned (the one playing)")
hidden2.fx[2].state = "VFVSTkVE"
as_james()
ps = 1
local nk = #sent
tick(); clock = clock + hops.FREEZE; tick()
assert(not (last("keep") and #sent > nk and last("keep").d.token == rec.token), "not while playing")
ps = 0
tick()
local k2 = last("keep")
assert(k2 and k2.d.token == rec.token, "stopped: its settings asked for, to go into the song")
as_bo()
hops.on_msg("P2", cfg_bo, k2.d, "Song", "main")
local kept2 = last("kept")
as_james()
hops.on_msg("P1", cfg, kept2.d, "Song", "main")
local sets = chunk_sets
tick()
assert(chunk_sets == sets + 1 and keys.fx[2].guid == rec.of and keys.fx[2].state == "VFVSTkVE" and #keys.fx == 3, "the song's Serum has them now, the same plug-in (its id kept)")
tick(); tick()
assert(chunk_sets == sets + 1, "once: nothing turned since")
-- Stop the hop: Serum stays in the project; Auto plays the print here again
assert(hoptry.web_action("P1", cfg, b, { stop = 1 }):find("stays on the track", 1, true), "stopped from the page")
assert(#keys.fx == 2 and keys.fx[2].name == "VST3i: Serum (Xfer)" and hops.S.stand[rec.of] == nil, "the hop goes, the plug-in stays in the song")

-- ---- 5. prints: Auto plays a part through a hop; the old per-track dry / wet choices are cleared once (findings 10) ---------------------
package.loaded.prints = nil
local prints = require("prints")
reaper.TrackFX_GetOffline = function(tr, i) return F(tr, i).offline == true end
reaper.TrackFX_GetInstrument = function() return 0 end
reaper.ValidatePtr = function() return true end
local pt = track("P1", "ppp", { plugin("VST3: ReaEQ (Cockos)"), amp })
reaper.TrackFX_GetNamedConfigParm = function(tr, i, k)
  local f = F(tr, i)
  if not f then return false, "" end
  if k == "fx_name" then return true, f.name end
  if k == "fx_type" then return true, "VST3" end
  if k == "fx_ident" then return true, f.offline and "" or "C:/x.vst3" end
  return false, ""
end
assert(not prints.track_plays(pt), "a plug-in missing here: the track doesn't play here (Auto: the print)")
hops.S.stand[amp.guid] = "PPP"
assert(prints.track_plays(pt) and not prints.track_plays(pt, true), "a hop plays it: Auto plays the part through it; it still can't print here")
hops.S.stand[amp.guid] = nil
projs.P1.ext["BandSync plays/" .. pt.guid] = "wet"
local enum = {}
reaper.EnumProjExtState = function(proj, sec, i)
  enum = {}
  for k in pairs(P(proj).ext) do local s, key = k:match("^(.-)/(.*)$"); if s == sec and P(proj).ext[k] ~= "" then enum[#enum + 1] = key end end
  table.sort(enum)
  if enum[i + 1] then return true, enum[i + 1], "" end
  return false, "", ""
end
reaper.SetProjExtState = function(proj, sec, k, v)
  if k == "" then for key in pairs(P(proj).ext) do if key:find("^" .. sec:gsub("%p", "%%%0") .. "/") then P(proj).ext[key] = nil end end
  else P(proj).ext[sec .. "/" .. k] = v end
end
local rechosen = 0
local real_rechoose = prints.rechoose
prints.rechoose = function(tr) rechosen = rechosen + 1; assert(tr == pt, "only the track that had a choice") end
assert(prints.forget_track_choices("P1") == 1 and projs.P1.ext["BandSync plays/" .. pt.guid] == nil and rechosen == 1, "an old file's track choice: cleared, the track chosen again")
assert(prints.forget_track_choices("P1") == 0 and rechosen == 1, "once a project")
prints.rechoose = real_rechoose
assert(prints.track_choice == nil and prints.set_track_choice == nil, "no per-track choice any more")
local f = io.open("StudioSync - Selected tracks play dry.lua", "r")
assert(f == nil, "its actions are gone")
local js = io.open("lib/webui/tryfx.js"):read("a")
assert(js:find("tryask", 1, true) and js:find("{ keep: t.id }", 1, true) and js:find("'Deny'", 1, true), "the page: the toast on every tab, Add to track, Deny")
print("ok: borrow a plug-in for real, Hop deleted = stopped, asks on the bar and every page")
