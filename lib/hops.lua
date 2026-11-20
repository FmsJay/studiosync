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
-- Shared CPU (roadmap "More big ideas" 2): the same hop for plug-ins you DO have. "Offload this track's FX" picks the idlest bandmate here
-- (the `cpu` every computer now puts in its status; never one recording, or a guest's), puts one Hop at the end of the track's chain and
-- holds the song's FX off here (each one's BYPASS line as the band has it kept in the track's band_fx_held, which mirror sends in its place,
-- so it's this computer's choice, never the song's); the bandmate hosts the whole chain. It comes back by itself (the chain on again, exactly
-- as it was) when they start recording, go away or fall behind, and with Live sync. Not on the master. (James, rt)
local band = require("band")
-- LATENCY: a hop's budget, the plug-in's most (170 ms at 48 kHz). The desktop <-> laptop link over the internet measured an 80-125 ms round
-- trip, and the plug-in's default 150 ms left about 12 ms to spare: most of every spike came back too late. The extra 20 ms is only more of
-- REAPER's delay compensation. (Desktop -> laptop, rt)
local hops = { EVERY = 0.5, ASK_EVERY = 3, IDLE = 30, NAME = "StudioSync Hop", TAG = "for=hop;", TRACK_TAG = "hop", MARGIN_MS = 20, REMOTE_LATENCY = 256,
  LATENCY = 8192, HELD = "band_fx_held", MAX_CHAIN = 32, BUSY = 75, CPU_EVERY = 20, START = 20, AWAY = 10, LATE_WINDOW = 10, LATE_MAX = 8, LOST_MAX = 2, SAY_BACK = 300 }
-- (this script's state; kept across Live sync's reload in place (band.reload: the same Lua, the modules loaded again): a fresh one forgot the
-- hidden tracks this computer hosts, so a stop never removed them, and the next ask made a second track for the same hop. Laptop, rt)
local S = rawget(_G, "STUDIOSYNC_HOPS_S") or {}
for k, v in pairs({ at = -math.huge, connected = {}, asked = {}, serving = {}, why = {}, ok_at = {}, late = {}, back = {} }) do if S[k] == nil then S[k] = v end end
_G.STUDIOSYNC_HOPS_S = S
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
  local name = rec.offload and string.format("%s's effects run on %s's computer", tostring(rec.track or "?"), tostring(rec.user or who(rec.peer)))
    or string.format("Hop %s (%s on %s's computer)", tostring(rec.id), tostring(rec.fx or "?"):gsub("^%w+:%s*", ""), tostring(rec.user or who(rec.peer)))
  if S.why[rec.token] then return false, name .. ": " .. S.why[rec.token] end
  if type(net) ~= "table" then return false, name .. ": not connected yet" end
  if not net.resolved then return false, name .. ": can't reach " .. who(rec.peer) .. " (Tailscale off there or here?)" end
  if not net.serving then return false, name .. ": waiting for " .. tostring(rec.user or who(rec.peer)) .. "'s StudioSync to host it (Live sync on there?)" end
  if net.same_rate == false then return false, name .. ": the two computers run different sample rates; set both to the same" end
  if not net.remote_alive then return false, name .. ": the hidden track there isn't running (REAPER's audio stopped there?)" end
  local sent = math.max(1, tonumber(net.sent) or 0)
  local lost = 100 * (tonumber(net.lost) or 0) / sent -- (net.late: frames back after they were counted lost, not more of them)
  local over = (tonumber(net.need_ms) or 0) > (tonumber(net.budget_ms) or 0)
  local text = string.format("%s: round trip %.0f ms + %.0f ms there, needs %.0f of its %.0f ms, %.0f ms to spare; lost %.2f%%", name, tonumber(net.rtt_ms) or -1,
    tonumber(net.remote_ms) or -1, tonumber(net.need_ms) or -1, tonumber(net.budget_ms) or -1, tonumber(net.slack_ms) or -1, lost)
  if (tonumber(net.remote_slips) or 0) > 0 then text = text .. string.format(", %d clock slips", net.remote_slips) end
  if (tonumber(st.late) or 0) > 0 or rec.offload then text = text .. string.format(", %d late blocks", tonumber(st.late) or 0) end
  if (tonumber(net.holes) or 0) > 0 then text = text .. string.format(", %d dropouts", net.holes) end
  if over then text = text .. ". Raise the Hop's Latency budget" end
  return not over and lost < 1, text
end
-- The song's plug-ins a hop stands for, from a request: { {fxi, fx} }, an offload's whole chain or the one plug-in; nil when it isn't one. Pure.
function hops.chain_of(d)
  local c = type(d.chain) == "table" and d.chain or { { fxi = d.fxi, fx = d.fx } }
  if #c < 1 or #c > hops.MAX_CHAIN then return nil end
  for _, e in ipairs(c) do
    if type(e) ~= "table" or not math.tointeger(tonumber(e.fxi)) or type(e.fx) ~= "string" then return nil end
  end
  return c
end
-- How busy this computer is, 0-100 in tens, from what the probe printed: typeperf's CSV (Windows: the sample's value is the last quoted number),
-- or the 1-minute load average and the core count (macOS `sysctl -n vm.loadavg hw.ncpu`, Linux /proc/loadavg and nproc). nil when unreadable. Pure.
function hops.cpu_parse(out)
  out = tostring(out or "")
  local v
  for x in out:gmatch('"[^"\n]*","%s*([%d%.,]+)"') do v = x end
  local busy = v and tonumber((v:gsub(",", ".")))
  if not v then
    local load, n = out:match("(%d+[%.,]%d+)"), tonumber(out:match("(%d+)%s*$"))
    busy = load and n and n > 0 and 100 * tonumber((load:gsub(",", "."))) / n or nil
  end
  return busy and math.min(100, math.max(0, math.floor(busy / 10 + 0.5) * 10)) or nil
end
-- This computer's `cpu` for its status (Live sync): the probe runs in the background every CPU_EVERY s; an audio dropout in the last minute reads
-- as 100 (no headroom, whatever the processor says).
-- shortcut: typeperf's counter name is English, so a localized Windows reads nothing and counts as 50; use Get-CimInstance there if it matters.
function hops.cpu_now()
  local win = reaper.GetOS():find("Win") ~= nil
  local out = require("services").run_hidden("cpu", win and 'typeperf "\\Processor(_Total)\\% Processor Time" -sc 1'
    or "sysctl -n vm.loadavg hw.ncpu 2>/dev/null || { cat /proc/loadavg; nproc; }", hops.CPU_EVERY)
  local xrun, _, now = reaper.GetUnderrunTime()
  if tonumber(xrun) and xrun > 0 and tonumber(now) and now - xrun < 60000 then return 100 end
  return hops.cpu_parse(out) or 50
end
-- Who an offload goes to: of those here on the link (`peer_of`: user -> peer), with a status that says how busy they are (`status_of`: user ->
-- status; a StudioSync without `cpu` can't host a whole chain), not recording, not a guest, who has every plug-in (`has(user)`), under BUSY:
-- the least busy, then by name. -> user, peer; or nil and why, for each who couldn't. Pure.
function hops.offload_pick(peer_of, status_of, guests, has)
  local ok, why = {}, {}
  for u in pairs(peer_of) do
    local st = status_of[u]
    local cpu = type(st) == "table" and tonumber(st.cpu)
    if guests[u] then -- (a guest's computer isn't the band's to use)
    elseif not cpu then why[#why + 1] = u .. "'s StudioSync is too old to host it"
    elseif st.recording then why[#why + 1] = u .. " is recording"
    elseif not has(u) then why[#why + 1] = u .. " doesn't have all of its plug-ins"
    elseif cpu > hops.BUSY then why[#why + 1] = string.format("%s's computer is busy (%d%%)", u, cpu)
    else ok[#ok + 1] = { u = u, cpu = cpu } end
  end
  table.sort(ok, function(a, b) if a.cpu ~= b.cpu then return a.cpu < b.cpu end return a.u < b.u end)
  if ok[1] then return ok[1].u, peer_of[ok[1].u] end
  table.sort(why)
  return nil, #why > 0 and table.concat(why, "; ") or "no bandmate's computer is connected now (Live sync on there too?)"
end
-- Why an offloaded track comes back here, or nil while it's fine. `st`: the hop's HopStatus; `status`: the host's presence status (nil: gone);
-- `ok_ago`: seconds since it was last hosted and running; `late_rise`: late blocks in the last LATE_WINDOW s; `lost_pct`: the share of its
-- audio that didn't come back in time then (the network's dropouts: the plug-in never sees those as late). Pure.
function hops.handback_why(rec, st, status, ok_ago, late_rise, lost_pct)
  local u = tostring(rec.user)
  if type(status) == "table" and status.recording then return u .. " started recording" end
  if ok_ago > hops.AWAY then return status and (u .. "'s computer stopped hosting it") or (u .. "'s computer went away") end
  if late_rise > hops.LATE_MAX then return string.format("%s's computer fell behind (%d late blocks in %d s)", u, late_rise, hops.LATE_WINDOW) end
  if (lost_pct or 0) > hops.LOST_MAX then return string.format("the network to %s's computer fell behind (%.1f%% of its audio didn't come back in time in %d s)", u, lost_pct, hops.LATE_WINDOW) end
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
  local function knobs()
    set_knob(tr, idx, "Hop id", id, 1, 64)
    if latency then set_knob(tr, idx, "Latency budget", latency, 256, 8192) end
    set_knob(tr, idx, "Dry when late", dry or 0, 0, 1)
  end
  knobs()
  reaper.TrackFX_SetOffline(tr, idx, true)
  reaper.TrackFX_SetOffline(tr, idx, false)
  -- (again: a CLAP's new values reach it in its next process call, and the reload above came first, so it woke with its defaults:
  -- every Hop was id 1 and live audio's Play read nothing. The plug-in takes them in its next stopped block. Desktop, rt)
  knobs()
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
  local user_of, user_of_name = {}, {}
  for _, f in ipairs(band.files(cfg.root .. "/_band/devices", ".json")) do
    local d = band.read_json(cfg.root .. "/_band/devices/" .. f)
    if type(d) == "table" and type(d.user) == "string" and type(d.device) == "string" then
      user_of[d.device] = d.user
      for _, n in pairs(type(d.ts) == "table" and d.ts or {}) do if type(n) == "string" then user_of_name[n:lower()] = d.user end end
    end
  end
  local out = {}
  for _, p in ipairs(list or {}) do
    -- (or by its Tailscale name: outside Live sync (the panel, the actions) direct.peers has only the list, so Offload and Run plug-in on a
    -- bandmate found nobody. Desktop, rt)
    local u = user_of[(dev_of or {})[p] or ""] or user_of_name[(tostring(p):match("^(.-):%d+$") or tostring(p)):lower()]
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
  return require("direct").send_live(cfg, "hop", { op = "serve", token = rec.token, oid = rec.oid, fxi = rec.fxi, fx = rec.fx, chain = rec.chain, user = cfg.user },
    song, room, nil, { rec.peer })
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
  local idx = add_hop(tr, fx + 1, id, hops.LATENCY, 0)
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
  if rec.offload and tr then hops.release_chain(tr, rec.held or {}) end -- (its own chain on again, as it was)
  recs[tostring(id)], S.connected[id], S.asked[rec.token], S.why[rec.token] = nil, nil, nil, nil
  S.ok_at[rec.token], S.late[rec.token] = nil, nil
  save(proj, recs)
  return true
end
-- The hop standing for FX `fx` on `tr`, if any: its record.
function hops.of_fx(proj, tr, fx)
  local g = reaper.TrackFX_GetFXGUID(tr, fx)
  for _, rec in pairs(hops.records(proj)) do if rec.of == g or rec.hop == g then return rec end end
end

-- ---- Shared CPU: a whole track's FX on a bandmate's computer ---------------------------------------------------------------------------
-- The song's FX on `tr` held off here: each one's BYPASS line as the band has it goes into the track's band_fx_held first (mirror sends that in
-- its place: lib/mirror.lua track_head_parts), then each is bypassed. -> { [fx guid] = the rest of its BYPASS line }.
-- `prev`: what was held already (a Hop deleted by hand: its chain is still held off, and read again it would come back bypassed).
function hops.hold_chain(tr, prev)
  local _, chunk = reaper.GetTrackStateChunk(tr, "", false)
  local held, list = {}, {}
  for _, i in ipairs(shared_fx(tr)) do
    local g = reaper.TrackFX_GetFXGUID(tr, i)
    local line = require("mirror").fx_blocks(chunk or "", { [g] = true })[1] or ""
    held[g] = (prev or {})[g] or line:match("^BYPASS (.+)$") or (reaper.TrackFX_GetEnabled(tr, i) and "0 0 0" or "1 0 0")
    list[#list + 1] = g .. "held=" .. held[g] .. ";"
  end
  band.set_track_ext(tr, hops.HELD, table.concat(list))
  for _, i in ipairs(shared_fx(tr)) do reaper.TrackFX_SetEnabled(tr, i, false) end
  return held
end
-- Back on as they were (a chain the band replaced since has new ids and is theirs already: nothing to put back).
function hops.release_chain(tr, held)
  for i = 0, reaper.TrackFX_GetCount(tr) - 1 do
    local rest = held[reaper.TrackFX_GetFXGUID(tr, i)]
    if rest then reaper.TrackFX_SetEnabled(tr, i, rest:match("^1") == nil) end
  end
  band.set_track_ext(tr, hops.HELD, "")
end
-- The track's chain as a hop asks for it: { {fxi, fx} } in order, and its plug-in keys; or nil and why it can't go.
local function chain_here(proj, tr)
  if tr == reaper.GetMasterTrack(proj) then return nil, "not the master: only a track's own effects" end
  local shared = shared_fx(tr)
  if #shared ~= reaper.TrackFX_GetCount(tr) then return nil, "this track has effects of this computer's own on it (a translation, drum map or live hop)" end
  local chain, keys = {}, {}
  for k, i in ipairs(shared) do
    local name = fx_name(tr, i)
    if name:match("^%u+%d*i: ") then return nil, name:gsub("^%w+:%s*", "") .. " is an instrument: a hop carries audio, not MIDI" end
    chain[k], keys[k] = { fxi = k - 1, fx = name }, require("plugins").key(name)
  end
  if #chain == 0 then return nil, "this track has no effects" end
  if #chain > hops.MAX_CHAIN then return nil, "more than " .. hops.MAX_CHAIN .. " effects" end
  return chain, keys
end
-- The idlest bandmate here who can take `tr`'s whole chain: user, peer; or nil and why.
function hops.offload_target(proj, cfg, tr, song, room)
  local chain, keys = chain_here(proj, tr)
  if not chain then return nil, keys end
  local status_of = {}
  for _, st in ipairs(require("presence").peers(cfg, song, room) or {}) do status_of[st.user] = st end
  local okg, guests = pcall(require("removal").guest_names, cfg.root)
  local prints = require("prints")
  return hops.offload_pick(hops.peers_by_user(cfg, song, room), status_of, okg and guests or {}, function(u) return prints.has(cfg, u, keys) end)
end
-- "Offload this track's FX": one Hop at the end of `tr`'s chain (late blocks play dry, never silence), the song's FX held off here, `user`
-- asked to host the whole chain. -> hop id, or nil and why.
function hops.offload(proj, cfg, tr, user, peer, song, room)
  if not hops.available() then return nil, "needs StudioSync's extension with live hops" end
  local secret = secret_of(cfg)
  if not secret then return nil, "needs the studio on Tailscale with its secret (Settings > Studio)" end
  local oid = require("mirror").track_oid(tr)
  if oid == "" then return nil, "this track isn't shared yet" end
  for _, r in pairs(hops.records(proj)) do if r.oid == oid then return nil, "this track already has a hop" end end
  local chain, why = chain_here(proj, tr)
  if not chain then return nil, why end
  local id = hops.free_id(hops.used_ids(proj), 1, 32)
  if not id then return nil, "every hop id is taken" end
  local idx = add_hop(tr, reaper.TrackFX_GetCount(tr), id, hops.LATENCY, 1)
  if not idx then return nil, "the StudioSync Hop plug-in isn't installed here (run StudioSync's installer, then rescan plug-ins)" end
  band.set_track_ext(tr, "band_local_fx", band.track_ext(tr, "band_local_fx") .. reaper.TrackFX_GetFXGUID(tr, idx) .. hops.TAG)
  local name = select(2, reaper.GetTrackName(tr))
  local rec = { id = id, token = math.random(1, 2147483647), user = user, peer = peer, oid = oid, fxi = 0, fx = name .. "'s effects", chain = chain,
    offload = true, track = name, held = hops.hold_chain(tr), hop = reaper.TrackFX_GetFXGUID(tr, idx), song = song, room = room }
  local recs = hops.records(proj)
  recs[tostring(id)] = rec
  save(proj, recs)
  hops.ensure_link(cfg, secret)
  reaper.StudioSync_HopConnect(id, peer, hops.connect_json(secret, rec.token))
  S.connected[id], S.ok_at[rec.token] = peer .. "\0" .. rec.token, reaper.time_precise() + hops.START
  ask(cfg, rec, song, room)
  band.log(string.format("%s's %d effect%s now run on %s's computer (only here: the song's chain is the same for everyone). Bring them back: the same button",
    name, #chain, #chain == 1 and "" or "s", user))
  return id
end
-- The offload on `tr`, if any: its record.
function hops.offload_of(proj, tr)
  local oid = require("mirror").track_oid(tr)
  for _, rec in pairs(hops.records(proj)) do if rec.offload and rec.oid == oid then return rec end end
end
-- An offload comes back here: its chain on again as it was, the bandmate's hidden track gone, and said (a line, and Health for a while).
function hops.hand_back(proj, cfg, rec, why)
  hops.stop(proj, cfg, rec.id)
  local text = string.format("%s's effects are back on this computer: %s", tostring(rec.track), why)
  while S.back[1] and reaper.time_precise() - S.back[1].at >= hops.SAY_BACK do table.remove(S.back, 1) end
  S.back[#S.back + 1] = { text = text, at = reaper.time_precise() }
  band.log(text)
end
-- The action and the panel's button: offload the track's FX, or bring them back. -> what to tell the person (nil: nothing to say).
function hops.offload_toggle(proj, cfg, b, tr)
  if not hops.available() then return "This needs StudioSync's extension with live hops: Extensions > ReaPack > Synchronize packages, then restart REAPER." end
  local rec = hops.offload_of(proj, tr)
  if rec then hops.stop(proj, cfg, rec.id); band.log(tostring(rec.track) .. "'s effects are back on this computer"); return nil end
  local user, peer = hops.offload_target(proj, cfg, tr, b.song, b.room)
  if not user then return "Not offloaded: " .. tostring(peer) .. "." end
  local id, why = hops.offload(proj, cfg, tr, user, peer, b.song, b.room)
  if not id then return "Not offloaded: " .. tostring(why) .. "." end
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
-- The latency of the hidden track's copies (FX 1..n): REAPER's PDC is off in that chain, so the extension counts it.
local function chain_pdc(tr, n)
  local sum = 0
  for i = 1, n do sum = sum + (tonumber(select(2, reaper.TrackFX_GetNamedConfigParm(tr, i, "pdc"))) or 0) end
  return sum
end
-- A bandmate asks this computer to host a hop (d: op, token, oid, fxi, fx, user; `chain` = { {fxi, fx} } for an offloaded track's whole chain,
-- fx then just its label). -> true when it's hosted.
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
  local chain = hops.chain_of(d)
  if not chain then return fail("their StudioSync didn't understand the request") end
  local src, sis = nil, {}
  for k, e in ipairs(chain) do
    local s, si = find_fx(proj, d.oid, e.fxi, e.fx)
    if not s then return fail("their copy of the song doesn't have " .. tostring(e.fx) .. " on that track") end
    if not require("prints").fx_here(s, si) then return fail(tostring(e.fx):gsub("^%w+:%s*", "") .. " doesn't load on their computer") end
    src, sis[k] = s, si
  end
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
  if ok then
    for k, si in ipairs(sis) do reaper.TrackFX_CopyToTrack(src, si, tr, k, false) end
    ok = reaper.TrackFX_GetCount(tr) == #sis + 1
  end
  -- (Y plays its input: nobody hears this track (no master send), but its meter shows the hop's audio; with silence it read 0.000 while the
  -- hop worked. Laptop, rt)
  ok = ok and add_hop(tr, #sis + 1, y, hops.REMOTE_LATENCY, 1) ~= nil
  if ok then reaper.TrackFX_SetNamedConfigParm(tr, 0, "chain_pdc_mode", "2") end -- (PDC "ignore": REAPER adds no delay of its own in this chain)
  reaper.PreventUIRefresh(-1)
  if not ok then reaper.DeleteTrack(tr); return fail("the StudioSync Hop plug-in isn't installed on their computer") end
  local pdc = chain_pdc(tr, #sis)
  sv = { track = reaper.GetTrackGUID(tr), x = x, y = y, pdc = pdc, user = d.user, oid = d.oid, chain = chain, fx = d.fx, asked = reaper.time_precise(), knobs = {} }
  S.serving[token], S.why[token] = sv, nil
  hops.ensure_link(cfg, secret)
  reaper.StudioSync_HopServe(hops.serve_json(secret, token, x, y, pdc))
  band.log(string.format("hosting a hop for %s: %s on a hidden track here", tostring(d.user), tostring(d.fx):gsub("^%w+:%s*", "")))
  return true
end
-- The hidden copies follow the song's plug-ins: their knobs and bypass as they change, their latency.
local function follow(proj, cfg, token, sv)
  local tr = served_track(proj, sv)
  for k, e in ipairs(sv.chain) do
    local src, si = find_fx(proj, sv.oid, e.fxi, e.fx)
    if not (tr and src) then drop_served(proj, token); return end
    local kn = sv.knobs[k] or {}
    sv.knobs[k] = kn
    for p = 0, reaper.TrackFX_GetNumParams(src, si) - 1 do
      local v = reaper.TrackFX_GetParamNormalized(src, si, p)
      if kn[p] ~= v then reaper.TrackFX_SetParamNormalized(tr, k, p, v); kn[p] = v end
    end
    local on = reaper.TrackFX_GetEnabled(src, si)
    if kn.on ~= on then reaper.TrackFX_SetEnabled(tr, k, on); kn.on = on end
  end
  local pdc = chain_pdc(tr, #sv.chain)
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
-- An offloaded track at each tick: the Hop and the hold back after the band replaced its chain (back here instead when its plug-ins changed),
-- then back here when the host records, goes or falls behind. -> true while it stays offloaded.
local function keep_offload(proj, cfg, key, rec, tr, now)
  if not tr then hops.stop(proj, cfg, rec.id); return false end -- (the track's gone)
  if not guid_at(tr, rec.hop) then
    local chain = chain_here(proj, tr)
    local same = chain ~= nil and #chain == #rec.chain
    for k, e in ipairs(same and chain or {}) do same = same and e.fx == rec.chain[k].fx end
    if not same then hops.hand_back(proj, cfg, rec, "the band changed its effects (offload it again to move them)"); return false end
    local idx = add_hop(tr, reaper.TrackFX_GetCount(tr), math.floor(rec.id), hops.LATENCY, 1)
    if not idx then hops.hand_back(proj, cfg, rec, "the StudioSync Hop didn't load again"); return false end
    rec.hop = reaper.TrackFX_GetFXGUID(tr, idx)
    band.set_track_ext(tr, "band_local_fx", band.track_ext(tr, "band_local_fx") .. rec.hop .. hops.TAG)
    rec.held = hops.hold_chain(tr, rec.held) -- (a replaced chain has new ids: the band's states now)
    local recs = hops.records(proj)
    recs[key] = rec
    save(proj, recs)
  end
  local st = status(rec.id)
  local net = type(st.net) == "table" and st.net or {}
  if net.serving and net.remote_alive then S.ok_at[rec.token] = now
  elseif not S.ok_at[rec.token] then S.ok_at[rec.token] = now + hops.START end -- (Live sync just started: time to connect first)
  local late, lost, sent, l = tonumber(st.late) or 0, tonumber(net.lost) or 0, tonumber(net.sent) or 0, S.late[rec.token]
  -- (counted only while the audio goes both ways: the blocks before the bandmate's hidden track ran played dry, counted as late, and handed
  -- the offload back at its first look, 10 s in. Desktop -> laptop, rt)
  if not (net.active and net.remote_alive) then l = nil end
  if not l or now - l.at >= hops.LATE_WINDOW then
    l = { at = now, late = late, lost = lost, sent = sent, rise = l and math.max(0, late - l.late) or 0,
      lost_pct = l and sent > l.sent and 100 * math.max(0, lost - l.lost) / (sent - l.sent) or 0 }
    S.late[rec.token] = l
  end
  local host
  for _, p in ipairs(require("presence").peers(cfg, rec.song, rec.room) or {}) do if p.user == rec.user then host = p end end
  local why = hops.handback_why(rec, st, host, now - S.ok_at[rec.token], l.rise, l.lost_pct)
  if why then hops.hand_back(proj, cfg, rec, why); return false end
  return true
end
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
    local src = tr and (rec.offload or find_fx(proj, rec.oid, rec.fxi, rec.fx))
    if not src then -- (the plug-in it stood for is gone from the song: so is the hop)
      hops.stop(proj, cfg, id)
    elseif not rec.offload or keep_offload(proj, cfg, key, rec, tr, now) then
      if not rec.offload and not guid_at(tr, rec.hop) then -- (the band's chain replaced this track's, own FX and all: the Hop goes back in)
        local _, i = find_fx(proj, rec.oid, rec.fxi, rec.fx)
        local idx = add_hop(tr, i + 1, id, hops.LATENCY, 0)
        if idx then
          rec.hop = reaper.TrackFX_GetFXGUID(tr, idx)
          band.set_track_ext(tr, "band_local_fx", band.track_ext(tr, "band_local_fx") .. rec.hop .. hops.TAG)
          local now_recs = hops.records(proj) -- (read again: another hop stopped earlier in this loop would come back with the copy)
          now_recs[key] = rec
          save(proj, now_recs)
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
  -- (a hidden hop track here that this computer doesn't host (any more): left by a StudioSync before the reload fix, or by a crash. It goes)
  local mine = {}
  for _, sv in pairs(S.serving) do mine[sv.track] = true end
  for t = reaper.CountTracks(proj) - 1, 0, -1 do
    local tr = reaper.GetTrack(proj, t)
    if band.track_ext(tr, "band_local") == hops.TRACK_TAG and not mine[reaper.GetTrackGUID(tr)] then reaper.DeleteTrack(tr) end
  end
  for token, sv in pairs(S.serving) do
    local st = status(sv.x)
    local idle = type(st.net) == "table" and tonumber(st.net.idle_s) or 0
    if idle > hops.IDLE and now - sv.asked > hops.IDLE then drop_served(proj, token) -- (the bandmate went: so does the hidden track)
    else follow(proj, cfg, token, sv) end
  end
end
-- Live sync ending: hops stop on both sides (the records stay in the project: they start again with Live sync). An offload comes back here
-- for good: with nobody hosting it, its track would play dry.
function hops.on_exit(proj, cfg)
  if not hops.available() then return end
  for _, rec in pairs(hops.records(proj)) do
    if rec.offload then hops.hand_back(proj, cfg, rec, "Live sync stopped")
    else
      reaper.StudioSync_HopConnect(math.floor(rec.id), "", '{"stop":true}')
      if cfg then require("direct").send_live(cfg, "hop", { op = "stop", token = rec.token }, rec.song, rec.room, nil, { rec.peer }) end
    end
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
  for k, x in ipairs(S.back) do -- (an offload that came back, for a while: never silently)
    if reaper.time_precise() - x.at < hops.SAY_BACK then rows[#rows + 1] = { "offload back " .. k, false, "yellow", x.text, x.text } end
  end
  return rows
end

return hops
