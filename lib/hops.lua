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
-- Try a plug-in you don't have (rt-hopvst, lib/hoptry.lua): a bandmate's plug-in from their published list, loaded fresh on their hidden track
-- once they say yes (their computer, their licence), with your audio or MIDI through it and its knobs from your side. A lost frame plays dry
-- now, and a link that needs more than a hop's budget gets a bigger one when stopped (up to LAT_MAX), both with the Hop plug-in 0.2.0.
local band = require("band")
-- LATENCY: a hop's budget, the plug-in's most (170 ms at 48 kHz). The desktop <-> laptop link over the internet measured an 80-125 ms round
-- trip, and the plug-in's default 150 ms left about 12 ms to spare: most of every spike came back too late. The extra 20 ms is only more of
-- REAPER's delay compensation. (Desktop -> laptop, rt)
-- MARGIN_MS: how far ahead of the hidden track's Hop X its audio is put, for the jitter on the way there; the rest of the budget is the
-- jitter on the way back. At 20 ms, four times as much was lost on the way there (dropped late at the remote) as came back late.
-- LOST_MAX: % of a hop's audio not back in time over LATE_WINDOW s that hands an offload back: that link loses 0.3-0.7% (a packet now and
-- then) and a 150-200 ms stall every minute or so (2.1% of a window), which isn't falling behind; before the spike fix it lost 8-13%.
local hops = { EVERY = 0.5, ASK_EVERY = 3, IDLE = 30, NAME = "StudioSync Hop", TAG = "for=hop;", TRACK_TAG = "hop", MARGIN_MS = 30, REMOTE_LATENCY = 256,
  LATENCY = 8192, LAT_MAX = 32768, OLD_MAX = 8192, SPARE_MS = 20, HELD = "band_fx_held", MAX_CHAIN = 32, BUSY = 75, CPU_EVERY = 20, START = 20, AWAY = 10, LATE_WINDOW = 10, LATE_MAX = 8, LOST_MAX = 5, SETTLE = 3, SAY_BACK = 300,
  RUN_BG = { 40871, 40873 }, -- (Project tabs: Run background projects; Run stopped background projects. hops.run_background)
  FREEZE = 2, KEEP_WAIT = 10 } -- (a borrowed plug-in's knobs into the song FREEZE s after the last turn, once stopped; an unanswered ask, again. rt-borrow)
-- (this script's state; kept across Live sync's reload in place (band.reload: the same Lua, the modules loaded again): a fresh one forgot the
-- hidden tracks this computer hosts, so a stop never removed them, and the next ask made a second track for the same hop. Laptop, rt)
local S = rawget(_G, "STUDIOSYNC_HOPS_S") or {}
for k, v in pairs({ at = -math.huge, connected = {}, asked = {}, serving = {}, why = {}, ok_at = {}, late = {}, up = {}, tp = {}, back = {},
  pending = {}, allow = {}, refused = {}, params = {}, sent = {}, act = {}, stand = {}, keep = {}, kept = {}, dirty = {} }) do if S[k] == nil then S[k] = v end end
-- (pending .. sent, keep .. dirty: lib/hoptry.lua's; stand: the song's plug-ins a hop plays here, read by prints.track_plays)
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
  if over then
    text = text .. ((tonumber(net.budget_ms) or 0) * hops.LAT_MAX / math.max(1, tonumber(rec.latency) or hops.LATENCY) <= (tonumber(net.need_ms) or 0)
      and ". This link needs more than the most a Hop can wait" or ". StudioSync gives it a bigger budget the next time playback stops")
  end
  return not over and lost < 1, text
end
-- A long link (rt-hopvst): when a hop needs more than its budget less SPARE_MS, the budget that covers it with SPARE_MS to spare, in steps of
-- 1024 frames, up to LAT_MAX; nil while it fits (or the numbers aren't there yet). `cur`: its latency now, in frames. Pure.
function hops.budget_for(cur, need_ms, budget_ms)
  cur, need_ms, budget_ms = tonumber(cur), tonumber(need_ms), tonumber(budget_ms)
  if not (cur and need_ms and budget_ms and need_ms > 0 and budget_ms > 0) or need_ms + hops.SPARE_MS <= budget_ms then return nil end
  local per_ms = cur / budget_ms -- (frames a ms: the budget is the latency at the plug-in's own rate)
  local want = math.min(hops.LAT_MAX, math.ceil((need_ms + hops.SPARE_MS) * per_ms / 1024) * 1024)
  return want > cur and want or nil
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
-- Borrow for real (rt-borrow): a plug-in's block as the owner's REAPER wrote it in its track's FXCHAIN (mirror.fx_blocks: from its BYPASS
-- line on), checked before it goes into a track here: at most KEEP_MAX bytes, one plug-in of a kind a hop runs whose name is `key`
-- (plugins.key), balanced; any other block in it (a second plug-in, a knob's envelope or modulation) is left out. -> its lines without its
-- FXID (REAPER gives it one here), and its REAPER name; or nil and why. Pure.
hops.KEEP_MAX = 48 * 1024 -- (a direct-link message caps at 64 KB with its envelope)
local KINDS = { VST = true, CLAP = true, AU = true, LV2 = true, JS = true }
function hops.block_lines(block, key)
  if type(block) ~= "string" or #block > hops.KEEP_MAX then return nil, "its settings didn't come (or were too big)" end
  local out, depth, name, skip = {}, 0, nil, false
  for l in block:gmatch("[^\r\n]+") do
    local s = l:match("^%s*(.-)%s*$")
    if #out == 0 then
      if not s:match("^BYPASS[%d%s]+$") then return nil, "what came isn't a plug-in" end
    elseif depth == 0 and s:sub(1, 1) == "<" then
      skip = name ~= nil
      if not skip then
        local kind, n = s:match('^<(%u+)%d?%s+"([^"]+)"')
        if kind == "JS" or s:match("^<JS%s") then kind, n = "JS", "JS: " .. (s:match('^<JS%s+"([^"]*)"') or s:match("^<JS%s+(%S+)") or "") end
        if not (kind and KINDS[kind] and n) then return nil, "what came isn't a plug-in a hop runs" end
        name = n
      end
    end
    local was = depth
    if s:sub(1, 1) == "<" then depth = depth + 1 elseif s == ">" then depth = depth - 1 end
    if depth < 0 then return nil, "what came isn't a whole plug-in" end
    if not (skip or (depth == 0 and was == 0 and s:match("^FXID "))) then out[#out + 1] = s end
    if skip and depth == 0 then skip = false end
  end
  if not name or depth ~= 0 then return nil, "what came isn't a whole plug-in" end
  if require("plugins").key(name) ~= key then return nil, "what came is another plug-in (" .. name .. ")" end
  return out, name
end
-- `chunk` (a track's) with `lines` in its FXCHAIN: in place of the plug-in whose FXID is `replace` (keeping that id), or else in front of the
-- one whose FXID is `before`. -> the new chunk, or nil when neither is there. Pure.
function hops.put_block(chunk, lines, before, replace)
  local src, starts, ids, depth, on, close = {}, {}, {}, 0, false, nil
  for l in (tostring(chunk) .. "\n"):gmatch("([^\n]*)\n") do src[#src + 1] = l end
  for n, l in ipairs(src) do
    local s = l:match("^%s*(.-)%s*$")
    if not on then on, depth = s == "<FXCHAIN", 1
    else
      local top = depth == 1
      if s:sub(1, 1) == "<" then depth = depth + 1 elseif s == ">" then depth = depth - 1 end
      if depth == 0 then close = n; break end
      if top and s:match("^BYPASS ") then starts[#starts + 1] = n
      elseif top and starts[1] and s:match("^FXID ") then ids[#starts] = s:match("^FXID (%S+)") end
    end
  end
  if not close then return nil end
  local function build(k)
    local n, z, res = starts[k], (starts[k + 1] or close) - 1, {}
    for i = 1, n - 1 do res[#res + 1] = src[i] end
    local wak
    for _, x in ipairs(lines) do
      if replace and not wak and x:match("^WAK ") then wak = true; res[#res + 1] = "FXID " .. replace end
      res[#res + 1] = x
    end
    if replace and not wak then res[#res + 1] = "FXID " .. replace end
    for i = replace and z + 1 or n, #src do res[#res + 1] = src[i] end
    return table.concat(res, "\n")
  end
  for k in ipairs(starts) do if replace and ids[k] == replace then return build(k) end end
  for k in ipairs(starts) do if not replace and before and ids[k] == before then return build(k) end end
  return nil
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
-- A Hop's knob to `v` in its own range lo..hi: REAPER hands a CLAP's real range, a VST3's 0..1. old_hi: an older Hop's top (its Latency budget
-- ended at 8192 before 0.2.0): what a VST3 took is read back, and set again on that range when it isn't v.
local function set_knob(tr, fx, name, v, lo, hi, old_hi)
  local p = param_by_name(tr, fx, name)
  if not p then return false end
  local _, mn, mx = reaper.TrackFX_GetParam(tr, fx, p)
  if (mx or 1) - (mn or 0) > 1.5 then reaper.TrackFX_SetParam(tr, fx, p, v) else
    reaper.TrackFX_SetParamNormalized(tr, fx, p, (v - lo) / (hi - lo))
    local got = old_hi and tonumber((select(2, reaper.TrackFX_GetFormattedParamValue(tr, fx, p, "")) or ""):match("%d+"))
    if got and math.abs(got - v) > 1 then reaper.TrackFX_SetParamNormalized(tr, fx, p, math.min(1, (v - lo) / (old_hi - lo))) end
  end
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
    if latency then set_knob(tr, idx, "Latency budget", latency, 256, hops.LAT_MAX, hops.OLD_MAX) end
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
hops.set_knob = set_knob
-- A track with a Hop runs its FX in real time ("no anticipative FX", I_PERFFLAGS 2; not sent to the others): rendered ahead, the Hop's blocks
-- came in bursts, and a play start's whole-latency burst made 30 late blocks instead of 12. -> the flags it had, to put back.
local function real_time(tr)
  local f = math.floor(reaper.GetMediaTrackInfo_Value(tr, "I_PERFFLAGS"))
  reaper.SetMediaTrackInfo_Value(tr, "I_PERFFLAGS", f | 2)
  return f
end
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
hops.track_by_oid = track_by_oid
hops.fx_name, hops.guid_at = fx_name, guid_at
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
hops.secret_of = secret_of
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
  return require("direct").send_live(cfg, "hop", { op = "serve", token = rec.token, oid = rec.oid, fxi = rec.fxi, fx = rec.fx, chain = rec.chain, user = cfg.user,
    try = rec.try or nil, borrowed = rec.borrowed or nil }, song, room, nil, { rec.peer })
end
local function tagged(tr, g) return g ~= nil and band.track_ext(tr, "band_local_fx"):find(g .. hops.TAG, 1, true) ~= nil end
local function untag(tr, g)
  band.set_track_ext(tr, "band_local_fx", (band.track_ext(tr, "band_local_fx"):gsub(g:gsub("%p", "%%%0") .. hops.TAG:gsub("%p", "%%%0"), "")))
end
-- The track's parts play again as Auto says, now that a hop does or doesn't stand for one of its plug-ins (prints.track_plays: a plug-in a hop
-- plays here counts as here, so its dry take plays through the hop instead of the print with the chain held off).
local function rechoose(tr) if tr then pcall(function() require("prints").rechoose(tr) end) end end
local function short(name) return (tostring(name):gsub("^%w+:%s*", ""):gsub("%s*%(.-%)$", "")) end -- ("VST3: Neural Amp (Neural DSP)" -> "Neural Amp")
-- Something that ended a hop by itself, said in the log and on Health for a while (never silently).
local function say_back(text)
  while S.back[1] and reaper.time_precise() - S.back[1].at >= hops.SAY_BACK do table.remove(S.back, 1) end
  S.back[#S.back + 1] = { text = text, at = reaper.time_precise() }
  band.log(text)
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
  if not fxi then return nil, "that's one of this computer's own effects, not the project's" end
  local id = hops.free_id(hops.used_ids(proj), 1, 32)
  if not id then return nil, "every hop id is taken" end
  local idx = add_hop(tr, fx + 1, id, hops.LATENCY, 1) -- (a lost frame plays dry, not silence: the Hop 0.2.0's, rt-hopvst)
  if not idx then return nil, "the StudioSync Hop plug-in isn't installed here (run StudioSync's installer, then rescan plug-ins)" end
  band.set_track_ext(tr, "band_local_fx", band.track_ext(tr, "band_local_fx") .. reaper.TrackFX_GetFXGUID(tr, idx) .. hops.TAG)
  local rec = { id = id, token = math.random(1, 2147483647), user = user, peer = peer, oid = oid, fxi = fxi, fx = fx_name(tr, fx), of = guid,
    hop = reaper.TrackFX_GetFXGUID(tr, idx), song = song, room = room, perf = real_time(tr) }
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
  if i then reaper.TrackFX_Delete(tr, i) end
  if tr and rec.hop then untag(tr, rec.hop) end -- (also when the Hop was deleted by hand: nothing of it left in the list. rt-borrow)
  if rec.offload and tr then hops.release_chain(tr, rec.held or {}) end -- (its own chain on again, as it was)
  recs[tostring(id)] = nil
  local others = false
  for _, r in pairs(recs) do others = others or r.oid == rec.oid end
  if tr and rec.perf and not others then reaper.SetMediaTrackInfo_Value(tr, "I_PERFFLAGS", math.floor(rec.perf)) end -- (as it was, with its last hop)
  recs[tostring(id)], S.connected[id] = nil, nil
  hops.forget(rec.token)
  save(proj, recs)
  if rec.of and S.stand[rec.of] then S.stand[rec.of] = nil; rechoose(tr) end -- (Auto again: the print where the plug-in doesn't load)
  return true
end
-- What this computer kept for a hop's token while it ran.
function hops.forget(token)
  for _, k in ipairs({ "asked", "why", "ok_at", "late", "up", "tp", "params", "act", "keep", "kept", "dirty" }) do S[k][token] = nil end
end
-- "Try <key> on <user>'s computer" (rt-hopvst, lib/hoptry.lua): a plug-in from their published list (plugins.key's name) that nothing in the
-- song has: a Hop at the end of `tr`'s chain (MIDI from the track reaches it there, for an instrument; a lost frame plays dry), and they're asked
-- to load it on a hidden track of theirs; they have to say yes first. -> hop id, or nil and why.
function hops.try(proj, cfg, tr, user, peer, key, song, room)
  if not hops.available() then return nil, "needs StudioSync's extension with live hops" end
  local secret = secret_of(cfg)
  if not secret then return nil, "needs the studio on Tailscale with its secret (Settings > Studio)" end
  if type(key) ~= "string" or key == "" or #key > 200 then return nil, "no plug-in named" end
  if tr == reaper.GetMasterTrack(proj) then return nil, "not on the master: pick a track" end
  local oid = require("mirror").track_oid(tr)
  if oid == "" then return nil, "this track isn't shared yet" end
  for _, r in pairs(hops.records(proj)) do if r.try and r.oid == oid and r.fx == key then return nil, "already trying it on this track" end end
  local id = hops.free_id(hops.used_ids(proj), 1, 32)
  if not id then return nil, "every hop id is taken" end
  local idx = add_hop(tr, reaper.TrackFX_GetCount(tr), id, hops.LATENCY, 1)
  if not idx then return nil, "the StudioSync Hop plug-in isn't installed here (run StudioSync's installer, then rescan plug-ins)" end
  band.set_track_ext(tr, "band_local_fx", band.track_ext(tr, "band_local_fx") .. reaper.TrackFX_GetFXGUID(tr, idx) .. hops.TAG)
  local rec = { id = id, token = math.random(1, 2147483647), user = user, peer = peer, oid = oid, fxi = 0, fx = key, try = true,
    track = select(2, reaper.GetTrackName(tr)), hop = reaper.TrackFX_GetFXGUID(tr, idx), song = song, room = room, perf = real_time(tr) }
  local recs = hops.records(proj)
  recs[tostring(id)] = rec
  save(proj, recs)
  hops.ensure_link(cfg, secret)
  reaper.StudioSync_HopConnect(id, peer, hops.connect_json(secret, rec.token))
  S.connected[id] = peer .. "\0" .. rec.token
  ask(cfg, rec, song, room)
  band.log(string.format("hop %d: asked %s to let you try %s on their computer (it plays here once they say yes)", id, user, key))
  return id
end

-- The hop standing for FX `fx` on `tr`, if any: its record.
function hops.of_fx(proj, tr, fx)
  local g = reaper.TrackFX_GetFXGUID(tr, fx)
  for _, rec in pairs(hops.records(proj)) do if rec.of == g or rec.hop == g then return rec end end
end
-- The song's plug-ins a hop plays here (S.stand: fx guid -> track oid), from the project's hops; a track whose set changed plays as Auto says
-- again. Read by prints.track_plays (prints.hop_plays).
function hops.stands(proj, recs)
  local now_set, changed = {}, {}
  for _, rec in pairs(recs or {}) do if rec.of and not rec.offload then now_set[rec.of] = rec.oid end end
  for g, oid in pairs(now_set) do if S.stand[g] ~= oid then changed[oid] = true end end
  for g, oid in pairs(S.stand) do if now_set[g] ~= oid then changed[oid] = true end end
  S.stand = now_set
  for oid in pairs(changed) do rechoose(track_by_oid(proj, oid)) end
end
-- Borrow for real (rt-borrow, lib/hoptry.lua): the owner's block for a plug-in (hops.block_lines: `lines`, `name`) goes into the song on
-- `rec`'s track: a try's, in front of its Hop (the try becomes a hop for a plug-in of the song, as "Run plug-in on a bandmate" makes: a new
-- token, so the owner drops the try's hidden track and hosts a copy of their own copy of the song's, once the band's change reaches them);
-- a borrowed one's, in place of the plug-in (its settings as last turned there: mirror sends them to the band, and the print follows on a
-- computer that has it). Only while stopped: a chain set from its chunk reloads its plug-ins. -> true, or nil and why.
function hops.borrow_in(proj, cfg, key, rec, lines, name)
  local tr = track_by_oid(proj, rec.oid)
  if not (tr and guid_at(tr, rec.hop)) then return nil, "its track or its StudioSync Hop is gone" end
  local _, chunk = reaper.GetTrackStateChunk(tr, "", false)
  local new = hops.put_block(chunk or "", lines, not rec.of and rec.hop or nil, rec.of)
  if not new then return nil, "its place in the track's chain wasn't found" end
  reaper.SetTrackStateChunk(tr, new, false)
  if rec.of then return true end
  local i = (guid_at(tr, rec.hop) or 0) - 1
  local fxi
  for k, x in ipairs(shared_fx(tr)) do if x == i then fxi = k - 1 end end
  if not fxi then return nil, "it didn't go into the chain" end
  require("direct").send_live(cfg, "hop", { op = "stop", token = rec.token }, rec.song, rec.room, nil, { rec.peer })
  local old = rec.token
  rec.try, rec.borrowed, rec.key = nil, true, rec.fx
  rec.of, rec.fxi, rec.fx, rec.token = reaper.TrackFX_GetFXGUID(tr, i), fxi, name, math.random(1, 2147483647)
  local pm = S.params[old] -- (its knobs show on until the new hop sends them)
  hops.forget(old)
  S.params[rec.token], S.connected[math.floor(rec.id)] = pm, nil
  local recs = hops.records(proj)
  recs[key] = rec
  save(proj, recs)
  band.log(string.format("%s is on %s for real now: in the project for everyone, running on %s's computer through the hop while you play; where it isn't running live (and once you stop it) the studio's print of the track plays, made on a computer that has it",
    tostring(rec.key), tostring(rec.track or "the track"), tostring(rec.user)))
  return true
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
    offload = true, track = name, held = hops.hold_chain(tr), hop = reaper.TrackFX_GetFXGUID(tr, idx), song = song, room = room, perf = real_time(tr) }
  local recs = hops.records(proj)
  recs[tostring(id)] = rec
  save(proj, recs)
  hops.ensure_link(cfg, secret)
  reaper.StudioSync_HopConnect(id, peer, hops.connect_json(secret, rec.token))
  S.connected[id], S.ok_at[rec.token] = peer .. "\0" .. rec.token, reaper.time_precise() + hops.START
  ask(cfg, rec, song, room)
  band.log(string.format("%s's %d effect%s now run on %s's computer (only here: the project's chain is the same for everyone). Bring them back: the same button",
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
  say_back(string.format("%s's effects are back on this computer: %s", tostring(rec.track), why))
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
  S.serving[token], S.sent[token] = nil, nil
end
hops.drop_served = drop_served
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
  local src, sis, try = nil, {}, nil
  if d.try then -- (a plug-in of theirs nothing in the song has: only with their yes, loaded fresh by name. lib/hoptry.lua, rt-hopvst)
    local name, why, inst = require("hoptry").host_check(cfg, d, token, song, room)
    if not name then return why ~= nil and fail(why) end -- (no why: refused, and told so already)
    try = { name = name, instrument = inst }
    sis[1] = -1
  end
  for k, e in ipairs(try and {} or chain) do
    local s, si = find_fx(proj, d.oid, e.fxi, e.fx)
    if not s and d.borrowed then return fail("waiting for the track's new plug-in to reach their copy of the project (it goes in there while their playback is stopped)") end
    if not s then return fail("their copy of the project doesn't have " .. tostring(e.fx) .. " on that track") end
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
  if ok and try then ok = reaper.TrackFX_AddByName(tr, try.name, false, -1001) == 1 -- (never its window: only the owner opens that, here)
  elseif ok then
    for k, si in ipairs(sis) do reaper.TrackFX_CopyToTrack(src, si, tr, k, false) end
  end
  ok = ok and reaper.TrackFX_GetCount(tr) == #sis + 1
  -- (Y plays its input: nobody hears this track (no master send), but its meter shows the hop's audio; with silence it read 0.000 while the
  -- hop worked. Laptop, rt)
  ok = ok and add_hop(tr, #sis + 1, y, hops.REMOTE_LATENCY, 1) ~= nil
  if ok then reaper.TrackFX_SetNamedConfigParm(tr, 0, "chain_pdc_mode", "2") end -- (PDC "ignore": REAPER adds no delay of its own in this chain)
  reaper.PreventUIRefresh(-1)
  if not ok then reaper.DeleteTrack(tr); return fail(try and (try.name .. " didn't load on their computer") or "the StudioSync Hop plug-in isn't installed on their computer") end
  local pdc = chain_pdc(tr, #sis)
  sv = { track = reaper.GetTrackGUID(tr), x = x, y = y, pdc = pdc, user = d.user, oid = d.oid, chain = chain, fx = d.fx, asked = reaper.time_precise(), knobs = {},
    try = try and true or nil, name = try and try.name or (d.borrowed and d.fx) or nil, instrument = try and try.instrument or nil, song = song, room = room,
    borrowed = (not try and d.borrowed == true and #chain == 1) or nil } -- (a borrowed plug-in: its knobs go to its borrower too, as a try's: rt-borrow)
  S.serving[token], S.why[token] = sv, nil
  hops.ensure_link(cfg, secret)
  reaper.StudioSync_HopServe(hops.serve_json(secret, token, x, y, pdc))
  band.log(string.format("hosting a hop for %s: %s on a hidden track here", tostring(d.user), tostring(d.fx):gsub("^%w+:%s*", "")))
  return true
end
-- The hidden copies follow the song's plug-ins: their knobs and bypass as they change, their latency. A tried plug-in has no song copy: its
-- knobs go to whoever tries it instead (lib/hoptry.lua), and theirs come back as "set".
local function follow(proj, cfg, token, sv)
  local tr = served_track(proj, sv)
  -- (its hidden track deleted here by hand: the same as Stop, so they're told and the yes goes. findings 8, rt-borrow)
  if sv.try and not tr then require("hoptry").end_use(proj, cfg, token); return end
  if tr and (sv.try or sv.borrowed) then require("hoptry").host_params(cfg, token, sv, tr) end
  for k, e in ipairs(sv.try and {} or sv.chain) do
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
  elseif d.op == "stop" and token then drop_served(proj, token); require("hoptry").gone(token)
  elseif (d.op == "params" or d.op == "page" or d.op == "set" or d.op == "keep" or d.op == "kept") and token then require("hoptry").on_msg(proj, cfg, d, token)
  elseif d.op == "fail" and token then
    for _, rec in pairs(hops.records(proj)) do
      if rec.token == token and rec.try and d.denied then -- (the owner said no, or stopped it: the try ends here too, and says why)
        hops.stop(proj, cfg, rec.id)
        say_back(string.format("Trying %s on %s's computer ended: %s", tostring(rec.fx), tostring(rec.user), tostring(d.why or "they stopped it")))
      elseif rec.token == token then S.why[token] = tostring(d.why or "?"); band.log("hop " .. rec.id .. ": " .. S.why[token]) end
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
  -- (counted only once the audio has gone both ways for SETTLE s: the blocks before then (the bandmate's hidden track starting, 9-13 of them
  -- every time in REAPER, none after) handed every offload back at its first look, 10 s in. Desktop -> laptop, rt)
  -- (and again after a play start, a stop or a seek: REAPER processes the hop's whole latency at once then, to line up its delay compensation,
  -- and those blocks can't be back in time: 12-33 of them at every play in REAPER, none after. Desktop -> laptop, rt)
  local ps, pos, tp = tonumber(reaper.GetPlayStateEx(proj)) or 0, tonumber(reaper.GetPlayPositionEx(proj)) or 0, S.tp[rec.token]
  local moved = tp and (tp.ps ~= ps or (ps & 1 == 1 and math.abs(pos - tp.pos - (now - tp.at) * (tonumber(reaper.Master_GetPlayRate(proj)) or 1)) > 0.5))
  S.tp[rec.token] = { ps = ps, pos = pos, at = now }
  if not (net.active and net.remote_alive) then S.up[rec.token] = nil elseif not S.up[rec.token] or moved then S.up[rec.token] = now end
  if not S.up[rec.token] or now - S.up[rec.token] < hops.SETTLE then l = nil -- (the first window starts once settled, not before)
  elseif not l or now - l.at >= hops.LATE_WINDOW then
    l = { at = now, late = late, lost = lost, sent = sent, rise = l and math.max(0, late - l.late) or 0,
      lost_pct = l and sent > l.sent and 100 * math.max(0, lost - l.lost) / (sent - l.sent) or 0 }
  end
  S.late[rec.token] = l
  l = l or { rise = 0, lost_pct = 0 }
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
  require("hoptry").print_tick(now) -- (a print of a tried plug-in ends on time: lib/hoptry.lua)
  if not (cfg and hops.available()) then return end
  require("hoptry").asks_tick(cfg) -- (asks for your plug-ins to the panel's bar, its Allow / Deny back: rt-borrow)
  hops.run_background(next(S.serving) ~= nil)
  local secret = secret_of(cfg)
  if not secret then return end
  -- (this computer's own hops only while its Live sync tab is in front; hosting goes on behind another tab too: rt-hop2 item 3)
  local recs, linked = (proj == nil or reaper.EnumProjects(-1) == proj) and hops.records(proj) or {}, false
  local stopped = (tonumber(reaper.GetPlayStateEx(proj)) or 0) == 0
  for key, rec in pairs(recs) do
    local id = math.floor(rec.id)
    local tr = track_by_oid(proj, rec.oid)
    local ftr, fi = nil, nil
    if tr and not (rec.offload or rec.try) then ftr, fi = find_fx(proj, rec.oid, rec.fxi, rec.fx) end
    local src = tr and (rec.offload or rec.try or ftr)
    if not src then -- (the plug-in it stood for is gone from the song: so is the hop)
      hops.stop(proj, cfg, id)
    elseif not guid_at(tr, rec.hop) and tagged(tr, rec.hop) then -- (its Hop deleted by hand: the same as Stop, on both sides. findings 8)
      if rec.offload then hops.hand_back(proj, cfg, rec, "its StudioSync Hop was removed from the track")
      else
        hops.stop(proj, cfg, id)
        say_back(string.format("%s on %s's computer stopped: its StudioSync Hop was removed from %s", short(rec.key or rec.fx), tostring(rec.user),
          select(2, reaper.GetTrackName(tr))))
      end
    elseif fi and require("prints").fx_here(tr, fi) then -- (the plug-in loads here now (installed since): it runs here, and the hop would apply it twice)
      hops.stop(proj, cfg, id)
      say_back(string.format("%s loads on this computer now, so it runs here: the hop to %s's computer stopped", short(rec.fx), tostring(rec.user)))
    elseif S.kept[rec.token] and stopped then -- (a borrowed plug-in's block from its owner: into the song while stopped. lib/hoptry.lua, rt-borrow)
      local k = S.kept[rec.token]
      S.kept[rec.token] = nil
      local ok, why = hops.borrow_in(proj, cfg, key, rec, k.lines, k.name)
      if not ok then say_back(string.format("%s wasn't added to the track: %s", tostring(rec.key or rec.fx), tostring(why))) end
    elseif not rec.offload or keep_offload(proj, cfg, key, rec, tr, now) then
      if rec.borrowed and stopped and not S.keep[rec.token] and now - (S.dirty[rec.token] or math.huge) >= hops.FREEZE then
        require("hoptry").keep(proj, cfg, id) -- (knobs turned while it played: their settings into the song now, so the print follows. rt-borrow)
      elseif S.keep[rec.token] and now - S.keep[rec.token] > hops.KEEP_WAIT then -- (no answer: asked again, if it was a freeze)
        S.keep[rec.token] = nil
        if rec.borrowed then S.dirty[rec.token] = now end
      end
      if not rec.offload and not guid_at(tr, rec.hop) then -- (the band's chain replaced this track's, own FX and all: the Hop goes back in)
        local i = rec.try and reaper.TrackFX_GetCount(tr) - 1 or select(2, find_fx(proj, rec.oid, rec.fxi, rec.fx)) -- (a try's at the end)
        local idx = add_hop(tr, i + 1, id, math.floor(tonumber(rec.latency) or hops.LATENCY), 1)
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
      if type(st.net) == "table" and st.net.serving then S.why[rec.token] = nil end -- (hosted now: an earlier "waiting for a yes" is past)
      hops.long_link(proj, key, rec, tr, st, now)
      local want = rec.peer .. "\0" .. rec.token
      if S.connected[id] ~= want or type(st.net) ~= "table" then
        reaper.StudioSync_HopConnect(id, rec.peer, hops.connect_json(secret, rec.token))
        S.connected[id] = want
      end
      if not (type(st.net) == "table" and st.net.serving) and now - (S.asked[rec.token] or -math.huge) > hops.ASK_EVERY then ask(cfg, rec, b and b.song or rec.song, b and b.room or rec.room) end
    end
  end
  if proj == nil or reaper.EnumProjects(-1) == proj then hops.stands(proj, hops.records(proj)) end
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
-- REAPER may not run a project tab that isn't in front, and a hop hosted here stopped when its owner switched tabs (rt-hop2 item 3). While
-- this computer hosts one, REAPER's "Project tabs: Run background projects" and "Run stopped background projects" are on; each one turned
-- on here goes back off when the last hosted hop ends (the next tick) or Live sync stops.
function hops.run_background(on)
  if on and not S.bg then
    S.bg = {}
    for _, c in ipairs(hops.RUN_BG) do
      if reaper.GetToggleCommandState(c) == 0 then reaper.Main_OnCommand(c, 0); S.bg[#S.bg + 1] = c end
    end
    if #S.bg > 0 then band.log("hosting a hop: REAPER now runs project tabs that aren't in front (Project tabs: Run background projects), so it keeps playing if you switch tabs; put back when the hop ends") end
  elseif not on and S.bg then
    for _, c in ipairs(S.bg) do if reaper.GetToggleCommandState(c) == 1 then reaper.Main_OnCommand(c, 0) end end
    S.bg = nil
  end
end
-- A hop whose link needs more than its budget gets a bigger one (hops.budget_for), only while REAPER is stopped (a latency change mid-play
-- makes REAPER recompute its delay compensation, which can glitch) and once the hop has run settled; kept in its record (rt-hopvst).
function hops.long_link(proj, key, rec, tr, st, now)
  local net = type(st) == "table" and st.net
  if type(net) ~= "table" or not net.active then S.act[rec.token] = nil; return end
  S.act[rec.token] = S.act[rec.token] or now
  if now - S.act[rec.token] < hops.SETTLE or (tonumber(reaper.GetPlayStateEx(proj)) or 0) ~= 0 then return end
  local cur = math.floor(tonumber(rec.latency) or hops.LATENCY)
  local want = hops.budget_for(cur, net.need_ms, net.budget_ms)
  local i = want and guid_at(tr, rec.hop)
  if not i then return end
  set_knob(tr, i, "Latency budget", want, 256, hops.LAT_MAX, hops.OLD_MAX)
  rec.latency = want
  local recs = hops.records(proj)
  if recs[key] then recs[key].latency = want; save(proj, recs) end
  band.log(string.format("hop %d: the link to %s needs %.0f ms, so its budget is now %.0f ms (REAPER plays the rest of the mix that much later)",
    math.floor(rec.id), tostring(rec.user), tonumber(net.need_ms) or 0, (tonumber(net.budget_ms) or 0) * want / math.max(1, cur)))
end

-- Live sync ending: hops stop on both sides (the records stay in the project: they start again with Live sync). An offload comes back here
-- for good: with nobody hosting it, its track would play dry. A tried plug-in's yes was for this session: asked again next time.
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
  hops.run_background(false)
  S.allow, S.pending, S.refused = {}, {}, {}
  require("hoptry").asks_clear()
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
  for token, sv in pairs(S.serving) do
    local net = status(sv.x).net
    local good = type(net) == "table" and net.alive and net.lined_up and net.heard
    local text = string.format(sv.try and "%s is trying your %s here: %s" or "Hosting a hop for %s (%s): %s", tostring(sv.user), tostring(sv.fx):gsub("^%w+:%s*", ""),
      type(net) ~= "table" and "starting" or not net.alive and "its hidden track isn't running" or not net.heard and "waiting for their audio"
      or string.format("%.0f ms here, %d clock slips", tonumber(net.remote_ms) or 0, tonumber(net.slips) or 0))
    -- (a tried plug-in is the owner's to stop, at any time: lib/hoptry.lua)
    rows[#rows + 1] = { "hop host " .. tostring(sv.x), good == true, "yellow", text, text,
      action = sv.try and { "Stop", function() require("hoptry").end_use(proj, cfg, token) end, "Their try ends now; they'd have to ask you again." } or nil }
  end
  local okt, trows = pcall(function() return require("hoptry").health_rows(proj, cfg) end) -- (asks to try your plug-ins: Allow, lib/hoptry.lua)
  if okt then for _, r in ipairs(trows or {}) do rows[#rows + 1] = r end end
  for k, x in ipairs(S.back) do -- (an offload that came back, for a while: never silently)
    if reaper.time_precise() - x.at < hops.SAY_BACK then rows[#rows + 1] = { "offload back " .. k, false, "yellow", x.text, x.text } end
  end
  return rows
end

return hops
