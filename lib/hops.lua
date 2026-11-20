-- Live hops (docs/realtime-roadmap.md 4b): hear a plug-in you don't have, live, through the REAPER of a bandmate who does. The extension
-- does the audio (extension/hopnet.cpp: raw float PCM on live audio's UDP socket, every frame back under its own number); this file:
--  - makes a hop: a StudioSync Hop right after the plug-in on your track (one of this computer's own FX: band_local_fx "for=hop", never sent
--    to the others), and asks the bandmate who has it (prints.lua's published plug-in lists) to host it, over the direct link;
--  - on the bandmate's computer: a hidden track of its own (band_local "hop") with Hop X, a copy of that plug-in from their copy of the song,
--    and Hop Y; its chain's PDC set to "ignore" so REAPER adds nothing there, its knobs kept the same as the song's as they change;
--  - starts and stops with Live sync; a Health row per hop.
-- The Hop reports a fixed latency (7200 samples = 150 ms at 48 kHz by default): REAPER plays the rest of the mix that much later, so the
-- returned audio is in time (James, rt: "always has to do playback so everything is synced up, means playing everything later enough").
-- (James, rt)
local band = require("band")
local hops = { EVERY = 0.5, ASK_EVERY = 3, IDLE = 30, NAME = "StudioSync Hop", TAG = "for=hop;", TRACK_TAG = "hop", MARGIN_MS = 20, REMOTE_LATENCY = 256 }
local S = { at = -math.huge, connected = {}, asked = {}, serving = {}, why = {} } -- (this script's state)
hops.S = S
local SEC = "StudioSync hops" -- ProjExtState: this project's hops (requester side), hop id -> record

function hops.available()
  return reaper.StudioSync_HopConnect ~= nil and reaper.StudioSync_HopServe ~= nil and reaper.StudioSync_HopStatus ~= nil
end

-- ---- pure ----------------------------------------------------------------------------------------------------------------------------
function hops.is_hop_name(name) return tostring(name or ""):find(hops.NAME, 1, true) ~= nil end
-- The first hop id from..to (step 1 or -1) not in `used` (a set). nil when all are taken.
function hops.free_id(used, from, to)
  local step = from <= to and 1 or -1
  for id = from, to, step do if not used[id] then return id end end
  return nil
end
-- Who hosts a hop: of those here (`peer_of`: user -> "name:port"), whoever has every plug-in (`has(user)`), by name; `prefer` first when they
-- can. -> user, peer; or nil. Pure.
function hops.pick(peer_of, has, prefer)
  if prefer and peer_of[prefer] and has(prefer) then return prefer, peer_of[prefer] end
  local names = {}
  for u in pairs(peer_of) do names[#names + 1] = u end
  table.sort(names)
  for _, u in ipairs(names) do if has(u) then return u, peer_of[u] end end
  return nil
end
-- The JSON the extension takes on each side.
function hops.connect_json(secret, token) return band.json_encode({ secret = secret, token = math.floor(token) }) end
function hops.serve_json(secret, token, x, y, pdc, margin_ms)
  return band.json_encode({ secret = secret, token = math.floor(token), x = math.floor(x), y = math.floor(y), pdc = math.floor(pdc or 0), margin_ms = margin_ms or hops.MARGIN_MS })
end
local function who(peer) return tostring(peer):match("^([^%.:]+)") or tostring(peer) end
-- Health's words for one hop from StudioSync_HopStatus's JSON: ok, text. Pure.
function hops.health_text(rec, st)
  local net = type(st) == "table" and st.net or nil
  local name = string.format("Hop %s (%s on %s's computer)", tostring(rec.id), tostring(rec.fx or "?"):gsub("^%w+:%s*", ""), tostring(rec.user or who(rec.peer)))
  if S.why[rec.token] then return false, name .. ": " .. S.why[rec.token] end
  if type(net) ~= "table" then return false, name .. ": not connected yet" end
  if not net.resolved then return false, name .. ": can't reach " .. who(rec.peer) .. " (Tailscale off there or here?)" end
  if not net.serving then return false, name .. ": waiting for " .. tostring(rec.user or who(rec.peer)) .. "'s StudioSync to host it (Live sync on there?)" end
  if net.same_rate == false then return false, name .. ": the two computers run different sample rates; set both to the same" end
  if not net.remote_alive then return false, name .. ": the hidden track there isn't running (REAPER's audio stopped there?)" end
  local sent = math.max(1, tonumber(net.sent) or 0)
  local lost = 100 * ((tonumber(net.lost) or 0) + (tonumber(net.late) or 0)) / sent
  local over = (tonumber(net.need_ms) or 0) > (tonumber(net.budget_ms) or 0)
  local text = string.format("%s: round trip %.0f ms + %.0f ms there, needs %.0f of its %.0f ms, %.0f ms to spare; lost %.2f%%", name, tonumber(net.rtt_ms) or -1,
    tonumber(net.remote_ms) or -1, tonumber(net.need_ms) or -1, tonumber(net.budget_ms) or -1, tonumber(net.slack_ms) or -1, lost)
  if (tonumber(net.remote_slips) or 0) > 0 then text = text .. string.format(", %d clock slips", net.remote_slips) end
  if (tonumber(st.late) or 0) > 0 then text = text .. string.format(", %d late blocks", st.late) end
  if over then text = text .. ". Raise the Hop's Latency budget" end
  return not over and lost < 1, text
end

-- ---- REAPER helpers --------------------------------------------------------------------------------------------------------------------
local function fx_name(tr, i)
  local ok, name = reaper.TrackFX_GetNamedConfigParm(tr, i, "fx_name")
  if not ok or name == "" then name = select(2, reaper.TrackFX_GetFXName(tr, i, "")) end
  return name
end
local function guid_at(tr, guid)
  for i = 0, reaper.TrackFX_GetCount(tr) - 1 do if reaper.TrackFX_GetFXGUID(tr, i) == guid then return i end end
end
local function param_by_name(tr, fx, want)
  for p = 0, reaper.TrackFX_GetNumParams(tr, fx) - 1 do
    if select(2, reaper.TrackFX_GetParamName(tr, fx, p, "")) == want then return p end
  end
end
-- A Hop's knob to `v` in its own range lo..hi: REAPER hands a CLAP's real range, a VST3's 0..1.
local function set_knob(tr, fx, name, v, lo, hi)
  local p = param_by_name(tr, fx, name)
  if not p then return false end
  local _, mn, mx = reaper.TrackFX_GetParam(tr, fx, p)
  if (mx or 1) - (mn or 0) > 1.5 then reaper.TrackFX_SetParam(tr, fx, p, v) else reaper.TrackFX_SetParamNormalized(tr, fx, p, (v - lo) / (hi - lo)) end
  return true
end
local function hop_id_of(tr, fx)
  local p = param_by_name(tr, fx, "Hop id")
  if not p then return nil end
  local v, mn, mx = reaper.TrackFX_GetParam(tr, fx, p)
  if (mx or 1) - (mn or 0) <= 1.5 then v = 1 + v * 63 end
  return math.floor(v + 0.5)
end
-- Every hop id in use in the project (both sides': a served hop's two Hops too).
function hops.used_ids(proj)
  local used = {}
  local function scan(tr)
    for i = 0, reaper.TrackFX_GetCount(tr) - 1 do
      if hops.is_hop_name(fx_name(tr, i)) then local id = hop_id_of(tr, i); if id then used[id] = true end end
    end
  end
  scan(reaper.GetMasterTrack(proj))
  for t = 0, reaper.CountTracks(proj) - 1 do scan(reaper.GetTrack(proj, t)) end
  return used
end
-- A new Hop at chain position `pos` with its id and knobs; the plug-in takes a new id or latency only while stopped or when it starts,
-- so it's taken offline and back to start with them. -> its index, or nil.
local function add_hop(tr, pos, id, latency, dry)
  local idx = -1
  for _, n in ipairs({ "CLAP: " .. hops.NAME, "VST3: " .. hops.NAME, hops.NAME }) do
    idx = reaper.TrackFX_AddByName(tr, n, false, -1000 - pos)
    if idx >= 0 then break end
  end
  if idx < 0 then return nil end
  set_knob(tr, idx, "Hop id", id, 1, 64)
  if latency then set_knob(tr, idx, "Latency budget", latency, 256, 8192) end
  set_knob(tr, idx, "Dry when late", dry or 0, 0, 1)
  reaper.TrackFX_SetOffline(tr, idx, true)
  reaper.TrackFX_SetOffline(tr, idx, false)
  return idx
end
hops.add_hop = add_hop -- (live audio's Play reads a Hop on its hidden live out track: lib/liveaudio.lua)
-- This computer's own FX on a track (translations, drum maps, Hops) and StudioSync's helpers: not part of the song.
local function own_fx(tr)
  local set = require("mirror").live_fx(tr)
  for g in band.track_ext(tr, "band_local_fx"):gmatch("({[^}]+})for=") do set[g] = true end
  return set
end
-- The song's FX on a track only, in order: { index }.
local function shared_fx(tr)
  local own, out = own_fx(tr), {}
  for i = 0, reaper.TrackFX_GetCount(tr) - 1 do if not own[reaper.TrackFX_GetFXGUID(tr, i)] then out[#out + 1] = i end end
  return out
end
local function track_by_oid(proj, oid)
  local mirror = require("mirror")
  for t = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, t)
    if mirror.track_oid(tr) == tostring(oid):upper() then return tr end
  end
end
-- The song's plug-in a hop stands for, on this computer's copy: track, its index; or nil.
local function find_fx(proj, oid, fxi, name)
  local tr = oid and track_by_oid(proj, oid)
  if not tr then return nil end
  local i = shared_fx(tr)[(tonumber(fxi) or -1) + 1]
  if not i or require("plugins").key(fx_name(tr, i)) ~= require("plugins").key(name) then return nil end
  return tr, i
end

-- Who's here: user -> "name:port" (the direct link's peers, by the devices they wrote).
function hops.peers_by_user(cfg, song, room)
  local list, dev_of = require("direct").peers(cfg, song, room)
  local user_of = {}
  for _, f in ipairs(band.files(cfg.root .. "/_band/devices", ".json")) do
    local d = band.read_json(cfg.root .. "/_band/devices/" .. f)
    if type(d) == "table" and type(d.user) == "string" and type(d.device) == "string" then user_of[d.device] = d.user end
  end
  local out = {}
  for _, p in ipairs(list or {}) do
    local u = user_of[(dev_of or {})[p] or ""]
    if u and u ~= cfg.user then out[u] = p end
  end
  return out
end
-- Bandmates here who have the plug-in, sorted: { {user, peer} }.
function hops.candidates(cfg, name, song, room)
  local prints, key, out = require("prints"), require("plugins").key(name), {}
  for u, p in pairs(hops.peers_by_user(cfg, song, room)) do
    if prints.has(cfg, u, { key }) then out[#out + 1] = { user = u, peer = p } end
  end
  table.sort(out, function(a, b) return a.user < b.user end)
  return out
end

local function secret_of(cfg)
  local groups = require("groups")
  return groups.tailnet(cfg.root) and groups.sonobus_secret(cfg.root) or nil
end
-- The hops travel on live audio's UDP socket: when live audio isn't running here (the studio has it off), it's started with nobody to send
-- to (nothing of this computer's inputs goes anywhere) just to carry the hops. Live audio's own tick takes it over when the studio turns it on.
function hops.ensure_link(cfg, secret)
  if not reaper.StudioSync_LiveAudioStatus then return false end
  local st = band.json_decode(reaper.StudioSync_LiveAudioStatus())
  if type(st) == "table" and st.running then return true end
  local la = require("liveaudio")
  reaper.StudioSync_LiveAudioPeers(la.peers_json(secret, require("direct").port(), {}))
  local first, nch, kbps = la.mine() -- (live audio's own choice, so its tick doesn't restart it when the studio turns it on)
  return reaper.StudioSync_LiveAudioStart(first, nch, kbps) == 1
end

function hops.records(proj)
  local _, v = reaper.GetProjExtState(proj, SEC, "list")
  local t = band.json_decode(v)
  return type(t) == "table" and t or {}
end
local function save(proj, recs) reaper.SetProjExtState(proj, SEC, "list", band.json_encode(recs)) end
local function status(id) local st = band.json_decode(reaper.StudioSync_HopStatus(math.floor(id))); return type(st) == "table" and st or {} end

-- ---- the computer whose track has the Hop ---------------------------------------------------------------------------------------------
local function ask(cfg, rec, song, room)
  S.asked[rec.token] = reaper.time_precise()
  return require("direct").send_live(cfg, "hop", { op = "serve", token = rec.token, oid = rec.oid, fxi = rec.fxi, fx = rec.fx, user = cfg.user }, song, room, nil, { rec.peer })
end
-- "Run this plug-in on <user>'s computer": a Hop right after FX `fx` on `tr`, and the bandmate asked to host it. -> hop id, or nil and why.
function hops.make(proj, cfg, tr, fx, user, peer, song, room)
  if not hops.available() then return nil, "needs StudioSync's extension with live hops" end
  local secret = secret_of(cfg)
  if not secret then return nil, "needs the studio on Tailscale with its secret (Settings > Studio)" end
  local mirror = require("mirror")
  local oid = mirror.track_oid(tr)
  if oid == "" then return nil, "this track isn't shared yet" end
  local guid = reaper.TrackFX_GetFXGUID(tr, fx)
  local fxi
  for k, i in ipairs(shared_fx(tr)) do if i == fx then fxi = k - 1 end end
  if not fxi then return nil, "that's one of this computer's own effects, not the song's" end
  local id = hops.free_id(hops.used_ids(proj), 1, 32)
  if not id then return nil, "every hop id is taken" end
  local idx = add_hop(tr, fx + 1, id, nil, 0)
  if not idx then return nil, "the StudioSync Hop plug-in isn't installed here (run StudioSync's installer, then rescan plug-ins)" end
  band.set_track_ext(tr, "band_local_fx", band.track_ext(tr, "band_local_fx") .. reaper.TrackFX_GetFXGUID(tr, idx) .. hops.TAG)
  local rec = { id = id, token = math.random(1, 2147483647), user = user, peer = peer, oid = oid, fxi = fxi, fx = fx_name(tr, fx), of = guid,
    hop = reaper.TrackFX_GetFXGUID(tr, idx), song = song, room = room }
  local recs = hops.records(proj)
  recs[tostring(id)] = rec
  save(proj, recs)
  hops.ensure_link(cfg, secret)
  reaper.StudioSync_HopConnect(id, peer, hops.connect_json(secret, rec.token))
  S.connected[id] = peer .. "\0" .. rec.token
  ask(cfg, rec, song, room)
  band.log(string.format("hop %d: %s now plays through %s's computer, the Hop's latency budget later (REAPER plays the rest of the mix that much later too)",
    id, (rec.fx:gsub("^%w+:%s*", "")), user))
  return id
end
-- Stop a hop: the Hop comes out of the track, the bandmate's hidden track goes. -> true when there was one.
function hops.stop(proj, cfg, id)
  local recs = hops.records(proj)
  local rec = recs[tostring(id)]
  if not rec then return false end
  if hops.available() then reaper.StudioSync_HopConnect(math.floor(id), "", '{"stop":true}') end
  require("direct").send_live(cfg, "hop", { op = "stop", token = rec.token }, rec.song, rec.room, nil, { rec.peer })
  local tr = track_by_oid(proj, rec.oid)
  local i = tr and guid_at(tr, rec.hop)
  if i then
    reaper.TrackFX_Delete(tr, i)
    band.set_track_ext(tr, "band_local_fx", (band.track_ext(tr, "band_local_fx"):gsub(rec.hop:gsub("%p", "%%%0") .. hops.TAG:gsub("%p", "%%%0"), "")))
  end
  recs[tostring(id)], S.connected[id], S.asked[rec.token], S.why[rec.token] = nil, nil, nil, nil
  save(proj, recs)
  return true
end
-- The hop standing for FX `fx` on `tr`, if any: its record.
function hops.of_fx(proj, tr, fx)
  local g = reaper.TrackFX_GetFXGUID(tr, fx)
  for _, rec in pairs(hops.records(proj)) do if rec.of == g or rec.hop == g then return rec end end
end

-- ---- the bandmate's computer: hosting a hop -------------------------------------------------------------------------------------------
local function drop_served(proj, token)
  local sv = S.serving[token]
  if not sv then return end
  if hops.available() then reaper.StudioSync_HopServe(band.json_encode({ token = token, stop = true })) end
  for t = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, t)
    if reaper.GetTrackGUID(tr) == sv.track then reaper.DeleteTrack(tr); break end
  end
  S.serving[token] = nil
end
local function served_track(proj, sv)
  for t = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, t)
    if reaper.GetTrackGUID(tr) == sv.track then return tr end
  end
end
-- A bandmate asks this computer to host a hop (d: op, token, oid, fxi, fx, user). -> true when it's hosted.
function hops.serve(proj, cfg, d, song, room)
  local token = math.tointeger(tonumber(d.token))
  local secret = secret_of(cfg)
  local function fail(why)
    S.why[token or 0] = why
    require("direct").send_live(cfg, "hop", { op = "fail", token = token, why = why, user = cfg.user }, song, room)
    return false
  end
  if not token or token < 1 then return false end
  if not hops.available() then return fail("their StudioSync extension has no live hops (it needs updating there)") end
  if not secret then return fail("their StudioSync isn't on the studio's Tailscale") end
  local sv = S.serving[token]
  if sv and served_track(proj, sv) then sv.asked = reaper.time_precise(); hops.ensure_link(cfg, secret); return true end
  local src, si = find_fx(proj, d.oid, d.fxi, d.fx)
  if not src then return fail("their copy of the song doesn't have " .. tostring(d.fx) .. " on that track") end
  if not require("prints").fx_here(src, si) then return fail(tostring(d.fx):gsub("^%w+:%s*", "") .. " doesn't load on their computer") end
  local used = hops.used_ids(proj)
  local x = hops.free_id(used, 64, 33)
  if x then used[x] = true end
  local y = x and hops.free_id(used, 64, 33)
  if not y then return fail("every hop id is taken on their computer") end
  reaper.PreventUIRefresh(1)
  local tr = require("mirror").add_local_track(proj, "StudioSync hop for " .. tostring(d.user), hops.TRACK_TAG)
  reaper.SetMediaTrackInfo_Value(tr, "B_MAINSEND", 0) -- (heard by nobody here: it only feeds the hop)
  reaper.SetMediaTrackInfo_Value(tr, "I_PERFFLAGS", math.floor(reaper.GetMediaTrackInfo_Value(tr, "I_PERFFLAGS")) | 2) -- (no anticipative FX: real time)
  local ok = add_hop(tr, 0, x, hops.REMOTE_LATENCY, 0) ~= nil
  if ok then reaper.TrackFX_CopyToTrack(src, si, tr, 1, false); ok = reaper.TrackFX_GetCount(tr) == 2 end
  ok = ok and add_hop(tr, 2, y, hops.REMOTE_LATENCY, 0) ~= nil
  if ok then reaper.TrackFX_SetNamedConfigParm(tr, 0, "chain_pdc_mode", "2") end -- (PDC "ignore": REAPER adds no delay of its own in this chain)
  reaper.PreventUIRefresh(-1)
  if not ok then reaper.DeleteTrack(tr); return fail("the StudioSync Hop plug-in isn't installed on their computer") end
  local pdc = tonumber(select(2, reaper.TrackFX_GetNamedConfigParm(tr, 1, "pdc"))) or 0
  sv = { track = reaper.GetTrackGUID(tr), x = x, y = y, pdc = pdc, user = d.user, oid = d.oid, fxi = d.fxi, fx = d.fx, asked = reaper.time_precise(), knobs = {} }
  S.serving[token], S.why[token] = sv, nil
  hops.ensure_link(cfg, secret)
  reaper.StudioSync_HopServe(hops.serve_json(secret, token, x, y, pdc))
  band.log(string.format("hosting a hop for %s: %s on a hidden track here", tostring(d.user), tostring(d.fx):gsub("^%w+:%s*", "")))
  return true
end
-- The hidden copy follows the song's plug-in: its knobs as they change, its latency.
local function follow(proj, cfg, token, sv)
  local tr = served_track(proj, sv)
  local src, si = find_fx(proj, sv.oid, sv.fxi, sv.fx)
  if not (tr and src) then drop_served(proj, token); return end
  for p = 0, reaper.TrackFX_GetNumParams(src, si) - 1 do
    local v = reaper.TrackFX_GetParamNormalized(src, si, p)
    if sv.knobs[p] ~= v then reaper.TrackFX_SetParamNormalized(tr, 1, p, v); sv.knobs[p] = v end
  end
  local pdc = tonumber(select(2, reaper.TrackFX_GetNamedConfigParm(tr, 1, "pdc"))) or 0
  if pdc ~= sv.pdc then
    sv.pdc = pdc
    local secret = secret_of(cfg)
    if secret then reaper.StudioSync_HopServe(hops.serve_json(secret, token, sv.x, sv.y, pdc)) end
  end
end

-- What arrives over the direct link (Live sync's handlers.hop).
function hops.on_msg(proj, cfg, d, song, room)
  if type(d) ~= "table" then return end
  local token = math.tointeger(tonumber(d.token))
  if d.op == "serve" then hops.serve(proj, cfg, d, song, room)
  elseif d.op == "stop" and token then drop_served(proj, token)
  elseif d.op == "fail" and token then
    for _, rec in pairs(hops.records(proj)) do
      if rec.token == token then S.why[token] = tostring(d.why or "?"); band.log("hop " .. rec.id .. ": " .. S.why[token]) end
    end
  end
end

-- ---- Live sync's tick -----------------------------------------------------------------------------------------------------------------
function hops.tick(cfg, b, proj)
  local now = reaper.time_precise()
  if now - S.at < hops.EVERY then return end
  S.at = now
  if not (cfg and hops.available()) or (proj and reaper.EnumProjects(-1) ~= proj) then return end
  local secret = secret_of(cfg)
  if not secret then return end
  local recs, linked = hops.records(proj), false
  for key, rec in pairs(recs) do
    local id = math.floor(rec.id)
    local tr = track_by_oid(proj, rec.oid)
    local src = tr and find_fx(proj, rec.oid, rec.fxi, rec.fx)
    if not src then -- (the plug-in it stood for is gone from the song: so is the hop)
      hops.stop(proj, cfg, id)
    else
      if not guid_at(tr, rec.hop) then -- (the band's chain replaced this track's, own FX and all: the Hop goes back in)
        local _, i = find_fx(proj, rec.oid, rec.fxi, rec.fx)
        local idx = add_hop(tr, i + 1, id, nil, 0)
        if idx then
          rec.hop = reaper.TrackFX_GetFXGUID(tr, idx)
          band.set_track_ext(tr, "band_local_fx", band.track_ext(tr, "band_local_fx") .. rec.hop .. hops.TAG)
          recs[key] = rec
          save(proj, recs)
        end
      end
      if not linked then linked = hops.ensure_link(cfg, secret) end
      local st = status(id)
      local want = rec.peer .. "\0" .. rec.token
      if S.connected[id] ~= want or type(st.net) ~= "table" then
        reaper.StudioSync_HopConnect(id, rec.peer, hops.connect_json(secret, rec.token))
        S.connected[id] = want
      end
      if not (type(st.net) == "table" and st.net.serving) and now - (S.asked[rec.token] or -math.huge) > hops.ASK_EVERY then ask(cfg, rec, b and b.song or rec.song, b and b.room or rec.room) end
    end
  end
  for token, sv in pairs(S.serving) do
    local st = status(sv.x)
    local idle = type(st.net) == "table" and tonumber(st.net.idle_s) or 0
    if idle > hops.IDLE and now - sv.asked > hops.IDLE then drop_served(proj, token) -- (the bandmate went: so does the hidden track)
    else follow(proj, cfg, token, sv) end
  end
end
-- Live sync ending: hops stop on both sides (the records stay in the project: they start again with Live sync).
function hops.on_exit(proj, cfg)
  if not hops.available() then return end
  for _, rec in pairs(hops.records(proj)) do
    reaper.StudioSync_HopConnect(math.floor(rec.id), "", '{"stop":true}')
    if cfg then require("direct").send_live(cfg, "hop", { op = "stop", token = rec.token }, rec.song, rec.room, nil, { rec.peer }) end
  end
  S.connected = {}
  for token in pairs(S.serving) do drop_served(proj, token) end
end

-- Health: a row per hop, on either side.
function hops.health_rows(cfg, proj)
  if not hops.available() then return {} end
  proj = proj or reaper.EnumProjects(-1)
  local rows, ids = {}, {}
  local recs = hops.records(proj)
  for k in pairs(recs) do ids[#ids + 1] = k end
  table.sort(ids)
  for _, k in ipairs(ids) do
    local rec = recs[k]
    local ok, text = hops.health_text(rec, status(rec.id))
    rows[#rows + 1] = { "hop " .. k, ok, "yellow", text, text }
  end
  for _, sv in pairs(S.serving) do
    local net = status(sv.x).net
    local good = type(net) == "table" and net.alive and net.lined_up and net.heard
    local text = string.format("Hosting a hop for %s (%s): %s", tostring(sv.user), tostring(sv.fx):gsub("^%w+:%s*", ""),
      type(net) ~= "table" and "starting" or not net.alive and "its hidden track isn't running" or not net.heard and "waiting for their audio"
      or string.format("%.0f ms here, %d clock slips", tonumber(net.remote_ms) or 0, tonumber(net.slips) or 0))
    rows[#rows + 1] = { "hop host " .. tostring(sv.x), good == true, "yellow", text, text }
  end
  return rows
end

return hops
