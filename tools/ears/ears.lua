-- StudioSync "ears", REAPER's side (docs/rt/rt-ears.md). GPL-3.0-or-later.
-- Run through a dev eval hook with a table EARS = { mode = ..., ... } set first; returns one line of text. Every REAPER call is pcall-wrapped
-- and given all its arguments (a wrong count shows a modal "ReaScript Error" even inside pcall). Works only in the song "Cross Test".
--  load      f32=<pattern.f32>                  the pattern into gmem "StudioSyncEars" for tools/ears/ears.jsfx
--  track     add=true|false [note=N] [instrument=FX] [capture=true]
--                                               the test track "XT Ears": this computer's own (band_local "yours": never sent, feeds Play),
--                                               armed, no input, no master send, ears.jsfx playing the pattern (or MIDI note N into
--                                               `instrument`, e.g. "ReaSynth", or a StudioSync Hop for the held-note check), then with
--                                               capture=true a second ears.jsfx recording what comes out (slot 1)
--  fire      slot=0 [frames=N] [off=N]          start the player (or a capture) in that slot; -> the link clock when asked
--  note      frames=N off=N                     the held-note check in one go: capture (slot 1, N frames) and the note (slot 0, off at
--                                               frame `off`) asked together, so both start in the same block
--  slot      slot=0                             what the slot did: command taken, song position at the start, running, frames done
--  poll      out=<file> secs=N [hub_peer=P hub_serve=0|1]
--                                               live audio's status read every ~2 ms for N s, one JSON line a read (tools/ears/ears.py env);
--                                               with hub_*, who mixes is asked again (and noted) whenever it isn't that: Live sync asks for
--                                               its own plan when the room changes, which would end a hub test early
--  live      role=send|recv|restore volume=V    the sound test's settings: send (Play only, not muted or deafened), recv (Mute me, not
--                                               deafened), restore (Deafen on, the rest as it was); live audio volume V
--  hub       peer=<name:port> serve=0|1         who mixes, straight to the extension (Live sync asks again only when its own plan changes)
--  capread   slot=1 out=<file.wav>              a capture slot into a 32-bit float WAV
--  tap       peer=<name:port>|"" stream=talk|play|hub secs=N out=<file.wav>
--                                               live audio's waveform tap (StudioSync_LiveAudioEars): a bandmate's stream as heard here, or
--                                               peer="" stream=play this computer's own Play as sent; <out>.json stamps it (ears.py wav --stamps)
--  jamset    on=true|false                      Jam on (In time, Jam, Follow each other at 0) or back as it was
--  transport play=true|false [pos=S]            Cross Test plays from S, or stops (and the cursor goes back where it was)
--  jamwatch  out=<file> secs=N                  the hidden Jam tracks' items, logged whenever they change, with the play position
local E = EARS or {}
EARS = nil
local S = "BandSync"
local GM = "StudioSyncEars"
local FX = "JS:StudioSync Ears/ears.jsfx"

local function cross_test()
  for i = 0, 50 do
    local q = reaper.EnumProjects(i)
    if not q then break end
    if select(2, reaper.GetProjExtState(q, S, "song")) == "Cross Test" then return q end
  end
end
local function find_track(p, name)
  for k = 0, reaper.CountTracks(p) - 1 do
    local tr = reaper.GetTrack(p, k)
    if select(2, reaper.GetTrackName(tr)) == name then return tr end
  end
end
local function now() return reaper.StudioSync_DirectNow and reaper.StudioSync_DirectNow() or reaper.time_precise() end
local function q(s) return '"' .. tostring(s):gsub('[%c"\\]', function(c) return string.format("\\u%04x", c:byte()) end) .. '"' end
local function me()
  local n = os.getenv("COMPUTERNAME")
  if not n or n == "" then
    local f = io.open("/etc/hostname", "r")
    n = f and f:read("l") or ""
    if f then f:close() end
  end
  return n:lower()
end
local function la(k) return reaper.GetExtState(S, "live audio " .. k) end
local function la_put(k, v) if v == nil or v == "" then reaper.DeleteExtState(S, "live audio " .. k, true) else reaper.SetExtState(S, "live audio " .. k, v, true) end end

local modes = {}

function modes.load()
  local f = assert(io.open(E.f32, "rb"))
  local data = f:read("a")
  f:close()
  reaper.gmem_attach(GM)
  local n = #data // 4
  local CH = 4096
  for i = 0, n - 1, CH do
    local m = math.min(CH, n - i)
    local vals = { string.unpack("<" .. string.rep("f", m), data, i * 4 + 1) }
    for j = 1, m do reaper.gmem_write(1024 + i + j - 1, vals[j]) end
  end
  reaper.gmem_write(0, n)
  return "loaded " .. n .. " frames"
end

function modes.track()
  local p = assert(cross_test(), "no Cross Test tab")
  local tr = find_track(p, "XT Ears")
  if E.add then
    if tr then return "already there" end
    reaper.Undo_BeginBlock2(p)
    local n = reaper.CountTracks(p)
    reaper.InsertTrackAtIndex(n, true)
    tr = reaper.GetTrack(p, n)
    reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "XT Ears", true)
    reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_local", "yours", true)
    reaper.SetMediaTrackInfo_Value(tr, "B_MAINSEND", 0)
    reaper.SetMediaTrackInfo_Value(tr, "I_RECINPUT", -1)
    reaper.SetMediaTrackInfo_Value(tr, "I_RECMON", 0)
    local fx = reaper.TrackFX_AddByName(tr, FX, false, -1)
    if fx < 0 then
      reaper.DeleteTrack(tr)
      reaper.Undo_EndBlock2(p, "ears: test track", -1)
      return "ears.jsfx not found (copy it to Effects/StudioSync Ears/)"
    end
    reaper.TrackFX_SetParam(tr, fx, 0, 0)
    reaper.TrackFX_SetParam(tr, fx, 1, 0)
    reaper.TrackFX_SetParam(tr, fx, 2, tonumber(E.note) or 0)
    if E.instrument and reaper.TrackFX_AddByName(tr, tostring(E.instrument), false, -1) < 0 then
      reaper.DeleteTrack(tr)
      reaper.Undo_EndBlock2(p, "ears: test track", -1)
      return "instrument not found: " .. tostring(E.instrument)
    end
    if E.capture then
      local c = reaper.TrackFX_AddByName(tr, FX, false, -1)
      reaper.TrackFX_SetParam(tr, c, 0, 1)
      reaper.TrackFX_SetParam(tr, c, 1, 1)
    end
    reaper.SetMediaTrackInfo_Value(tr, "I_RECARM", 1)
    reaper.Undo_EndBlock2(p, "ears: test track", -1)
    return "added XT Ears (armed, yours, no master send)"
  end
  if not tr then return "not there" end
  reaper.Undo_BeginBlock2(p)
  reaper.SetMediaTrackInfo_Value(tr, "I_RECARM", 0)
  reaper.DeleteTrack(tr)
  reaper.Undo_EndBlock2(p, "ears: test track removed", -1)
  return "removed XT Ears"
end

function modes.fire()
  reaper.gmem_attach(GM)
  local base = 8 + 8 * (tonumber(E.slot) or 0)
  if E.frames then reaper.gmem_write(base + 5, tonumber(E.frames)) end
  if E.off then reaper.gmem_write(base + 5, tonumber(E.off)) end
  local t = now()
  reaper.gmem_write(base, reaper.gmem_read(base) + 1)
  return string.format("fired slot %d at %.4f", tonumber(E.slot) or 0, t)
end

function modes.note()
  reaper.gmem_attach(GM)
  reaper.gmem_write(16 + 5, tonumber(E.frames) or 96000)
  reaper.gmem_write(8 + 5, tonumber(E.off) or 24000)
  reaper.gmem_write(16, reaper.gmem_read(16) + 1)
  reaper.gmem_write(8, reaper.gmem_read(8) + 1)
  return string.format("note asked at %.4f", now())
end

function modes.slot()
  reaper.gmem_attach(GM)
  local base = 8 + 8 * (tonumber(E.slot) or 0)
  return string.format("cmd %d taken %d pos %.6f running %d done %d", reaper.gmem_read(base), reaper.gmem_read(base + 1), reaper.gmem_read(base + 2),
    reaper.gmem_read(base + 3), reaper.gmem_read(base + 7))
end

-- One status read -> a JSON line: t (link clock), cb (audio callbacks so far), own (Play going out, peak since the last read), hub (the hub's
-- mix heard), hs (hub state), peers { name = { play_level, level, underruns } }, first (the first read of a defer cycle: Live sync may have
-- read the peaks in between, so its peaks are unknown). Per peer: play_level, level, underruns, latency_ms, buffer_ms, jitter, switched, trims.
local function status_line(first)
  local s = reaper.StudioSync_LiveAudioStatus() or ""
  local t = now()
  local i = s:find('"peers":{', 1, true) or #s
  local head, peers = s:sub(1, i - 1), s:sub(i + 9)
  local hub = head:match('"hub":(%b{})') or ""
  local out = { string.format('{"t":%.6f,"cb":%s,"first":%s,"own":%s,"hub":%s,"hs":%s,"peers":{', t, head:match('"callbacks":(%d+)') or "null",
    first and "true" or "false", head:match('"play_level":([%d%.]+)') or "null", hub:match('"level":([%d%.]+)') or "null", q(hub:match('"state":"(%a+)"') or "")) }
  local k = 0
  for name, body in peers:gmatch('"([^"]+)":(%b{})') do
    local function n(key) return body:match('"' .. key .. '":(%-?[%d%.]+)') or "null" end
    out[#out + 1] = string.format('%s%s:[%s,%s,%s,%s,%s,%s,%s,%s]', k > 0 and "," or "", q(name), n("play_level"), n("level"), n("underruns"),
      n("latency_ms"), n("buffer_ms"), n("jitter"), n("switched"), n("trims"))
    k = k + 1
  end
  out[#out + 1] = "}}\n"
  return table.concat(out)
end

function modes.poll()
  assert(reaper.StudioSync_LiveAudioStatus and reaper.StudioSync_DirectNow, "needs the StudioSync extension")
  local f = assert(io.open(E.out, "w"))
  local secs = tonumber(E.secs) or 20
  local clock = reaper.StudioSync_DirectClock and reaper.StudioSync_DirectClock() or "{}"
  f:write(string.format('{"me":%s,"start":%.6f,"secs":%s,"clock":%s}\n', q(me()), now(), secs, clock))
  local t_end = reaper.time_precise() + secs
  local hub_at = -math.huge
  local function keep_hub()
    if E.hub_peer == nil or reaper.time_precise() - hub_at < 0.5 then return end
    hub_at = reaper.time_precise()
    local hub = (reaper.StudioSync_LiveAudioStatus() or ""):match('"hub":(%b{})') or ""
    local serve = hub:match('"serve":(%a+)') == "true" and 1 or 0
    if (hub:match('"peer":"([^"]*)"') or "") ~= E.hub_peer or serve ~= (tonumber(E.hub_serve) or 0) then
      reaper.StudioSync_LiveAudioHub(tostring(E.hub_peer), tonumber(E.hub_serve) or 0)
      f:write(string.format('{"note":"hub asked again","at":%.6f,"was":%s}\n', now(), q(hub:sub(1, 120))))
    end
  end
  local function cycle()
    local ok, err = pcall(function()
      keep_hub()
      local c0 = reaper.time_precise()
      local first = true
      repeat
        local t = reaper.time_precise()
        f:write(status_line(first))
        first = false
        while reaper.time_precise() - t < 0.002 do end -- (a read every ~2 ms; a block is 2.7-10.7 ms on the test computers)
      until reaper.time_precise() - c0 > 0.020 or reaper.time_precise() > t_end
    end)
    if ok and reaper.time_precise() <= t_end then reaper.defer(cycle); return end
    pcall(function() f:write('{"end":' .. string.format("%.6f", now()) .. ',"clock":' .. (reaper.StudioSync_DirectClock and reaper.StudioSync_DirectClock() or "{}") .. ',"error":' .. q(err or "") .. '}\n') end)
    f:close()
  end
  reaper.defer(cycle)
  return "polling " .. secs .. " s into " .. E.out
end

function modes.live()
  local role = E.role
  if role == "send" or role == "recv" then
    if not reaper.HasExtState(S, "live audio ears saved") then
      reaper.SetExtState(S, "live audio ears saved", "1", true)
      reaper.SetExtState(S, "live audio ears volume", la("volume"), true)
      reaper.SetExtState(S, "live audio ears source", la("source"), true)
      reaper.SetExtState(S, "live audio ears mute", la("mute"), true)
    end
    la_put("volume", string.format("%.4f", tonumber(E.volume) or 0))
    if role == "recv" then la_put("mute", "1"); la_put("deaf", nil)
    else la_put("source", "play"); la_put("mute", nil); la_put("deaf", nil) end
  elseif role == "restore" then
    la_put("deaf", "1")
    if reaper.HasExtState(S, "live audio ears saved") then
      la_put("volume", reaper.GetExtState(S, "live audio ears volume"))
      la_put("source", reaper.GetExtState(S, "live audio ears source"))
      la_put("mute", reaper.GetExtState(S, "live audio ears mute"))
      for _, k in ipairs({ "saved", "volume", "source", "mute" }) do reaper.DeleteExtState(S, "live audio ears " .. k, true) end
    else la_put("mute", nil) end
  else return "role?" end
  return string.format("%s: deaf=%s mute=%s source=%s volume=%s", role, la("deaf"), la("mute"), la("source"), la("volume"))
end

function modes.hub()
  local r = reaper.StudioSync_LiveAudioHub(tostring(E.peer or ""), tonumber(E.serve) or 0)
  return "hub asked: peer=" .. tostring(E.peer or "") .. " serve=" .. tostring(E.serve or 0) .. " -> " .. tostring(r)
end

local function le32(n) return string.pack("<I4", n) end
function modes.capread()
  reaper.gmem_attach(GM)
  local slot = tonumber(E.slot) or 1
  local base, cap = 8 + 8 * slot, 1048576 * (1 + slot)
  local n = math.floor(reaper.gmem_read(base + 7))
  local sr = math.floor(reaper.GetSetProjectInfo(0, "PROJECT_SRATE", 0, false))
  if sr <= 0 then sr = 48000 end
  local _, dev = reaper.GetAudioDeviceInfo("SRATE", "")
  sr = tonumber(dev) or sr
  local parts = {}
  local CH = 4096
  for i = 0, n - 1, CH do
    local m, vals = math.min(CH, n - i), {}
    for j = 1, m do vals[j] = reaper.gmem_read(cap + i + j - 1) end
    parts[#parts + 1] = string.pack("<" .. string.rep("f", m), table.unpack(vals))
  end
  local data = table.concat(parts)
  local f = assert(io.open(E.out, "wb"))
  f:write("RIFF", le32(36 + #data), "WAVEfmt ", le32(16), string.pack("<I2I2I4I4I2I2", 3, 1, sr, sr * 4, 4, 32), "data", le32(#data), data)
  f:close()
  return string.format("wrote %d frames at %d Hz to %s", n, sr, E.out)
end

-- The ears tap (extension 1.0.35+, rt-p11): what this computer actually hears of a bandmate's live audio stream, or its own Play as it goes
-- out, as a WAV, with a stamp beside it (<out>.json: t_first, the link clock when its first frame was heard or sent; me; DirectClock) that
-- ears.py wav --stamps turns into the latency and its steadiness. peer="" stream="play": this computer's own Play.
function modes.tap()
  assert(reaper.StudioSync_LiveAudioEars and reaper.StudioSync_LiveAudioStatus and reaper.StudioSync_DirectNow, "needs the StudioSync extension with StudioSync_LiveAudioEars (1.0.35+)")
  local peer, stream, secs = tostring(E.peer or ""), tostring(E.stream or "play"), math.max(0.1, math.min(60, tonumber(E.secs) or 12))
  local out = assert(E.out, "out=<file.wav>")
  local started = reaper.StudioSync_LiveAudioEars(peer, stream, out, secs)
  if started ~= 1 then return "tap refused (" .. peer .. " " .. stream .. "): live audio running? peer in the list? another tap writing? path a .wav?" end
  local t_first, t_end = nil, reaper.time_precise() + secs + 20
  local function stamp(state, s)
    local f = io.open(out .. ".json", "w")
    if not f then return end
    f:write(string.format('{"t_first":%s,"me":%s,"peer":%s,"stream":%s,"state":%s,"frames":%s,"lost":%s,"clock":%s}\n', t_first and string.format("%.6f", t_first) or "null",
      q(me()), q(peer), q(stream), q(state), s:match('"ears":{.-"frames":(%d+)') or "0", s:match('"ears":{.-"lost":(%d+)') or "0",
      reaper.StudioSync_DirectClock and reaper.StudioSync_DirectClock() or "{}"))
    f:close()
  end
  local function cycle()
    local ok, s = pcall(reaper.StudioSync_LiveAudioStatus)
    s = ok and s or ""
    local age = tonumber(s:match('"ears":{.-"first_age_s":(%-?[%d%.]+)'))
    if not t_first and age and age >= 0 then t_first = now() - age end -- (read together: the age is as of this status)
    local state = s:match('"ears":{.-"state":"(%a+)"') or "?"
    if state == "writing" and reaper.time_precise() < t_end then reaper.defer(cycle); return end
    stamp(state, s)
  end
  reaper.defer(cycle)
  return string.format("tapping %s %s for %.1f s into %s (and %s.json when done)", peer == "" and "own" or peer, stream, secs, out, out)
end

function modes.jamset()
  local p = assert(cross_test(), "no Cross Test tab")
  local function px(k) return select(2, reaper.GetProjExtState(p, S, k)) end
  if E.on then
    if not reaper.HasExtState(S, "ears jam saved") then
      reaper.SetExtState(S, "ears jam saved", "1", true)
      reaper.SetExtState(S, "ears jam listen", reaper.GetExtState(S, "stream listen"), true)
      reaper.SetExtState(S, "ears jam jam", reaper.GetExtState(S, "stream jam"), true)
      reaper.SetExtState(S, "ears jam side", px("side") ~= "" and px("side") or "none", true)
    end
    reaper.SetExtState(S, "stream listen", "in_time", true)
    reaper.SetExtState(S, "stream jam", "1", true)
    reaper.SetProjExtState(p, S, "side", "0")
  elseif reaper.HasExtState(S, "ears jam saved") then
    local function put(k, v) if v == "" then reaper.DeleteExtState(S, k, true) else reaper.SetExtState(S, k, v, true) end end
    put("stream listen", reaper.GetExtState(S, "ears jam listen"))
    put("stream jam", reaper.GetExtState(S, "ears jam jam"))
    local side = reaper.GetExtState(S, "ears jam side")
    reaper.SetProjExtState(p, S, "side", side == "none" and "" or side)
    for _, k in ipairs({ "saved", "listen", "jam", "side" }) do reaper.DeleteExtState(S, "ears jam " .. k, true) end
  end
  return string.format("jam=%s listen=%s side=%s bars=%s", reaper.GetExtState(S, "stream jam"), reaper.GetExtState(S, "stream listen"), px("side"),
    reaper.GetExtState(S, "stream bars"))
end

function modes.transport()
  local p = assert(cross_test(), "no Cross Test tab")
  if E.play then
    reaper.SetExtState(S, "ears cursor", tostring(reaper.GetCursorPositionEx(p)), false)
    reaper.SetEditCurPos2(p, tonumber(E.pos) or 60, false, false)
    reaper.OnPlayButtonEx(p)
    return string.format("playing from %.2f at %.4f", tonumber(E.pos) or 60, now())
  end
  reaper.OnStopButtonEx(p)
  local c = tonumber(reaper.GetExtState(S, "ears cursor"))
  if c then reaper.SetEditCurPos2(p, c, false, false) end
  return "stopped"
end

function modes.jamwatch()
  local p = assert(cross_test(), "no Cross Test tab")
  local f = assert(io.open(E.out, "w"))
  local t_end = reaper.time_precise() + (tonumber(E.secs) or 30)
  local last = {}
  local function bar_of(t)
    local beats, meas, cml = reaper.TimeMap2_timeToBeats(p, t)
    return (meas or 0) + beats / math.max(1, cml or 4)
  end
  local function cycle()
    local ok, err = pcall(function()
      local pp = reaper.GetPlayPositionEx(p)
      for k = 0, reaper.CountTracks(p) - 1 do
        local tr = reaper.GetTrack(p, k)
        if select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_local", "", false)) == "jam" then
          local tn = select(2, reaper.GetTrackName(tr))
          for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
            local it = reaper.GetTrackMediaItem(tr, j)
            local tk = reaper.GetActiveTake(it)
            local src = tk and reaper.GetMediaItemTake_Source(tk)
            local file = src and reaper.GetMediaSourceFileName(src, "") or ""
            local pos, len = reaper.GetMediaItemInfo_Value(it, "D_POSITION"), reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
            local offs = tk and reaper.GetMediaItemTakeInfo_Value(tk, "D_STARTOFFS") or 0
            local key = string.format("%s|%.6f|%.6f|%.6f|%s", tn, pos, len, offs, file)
            if not last[key] then
              last[key] = true
              f:write(string.format('{"t":%.6f,"play":%.6f,"track":%s,"pos":%.6f,"len":%.6f,"offs":%.6f,"bar":%.6f,"file":%s}\n', now(), pp, q(tn),
                pos, len, offs, bar_of(pos), q(file)))
            end
          end
        end
      end
    end)
    if ok and reaper.time_precise() <= t_end then reaper.defer(cycle); return end
    pcall(function() f:write('{"end":true,"error":' .. q(err or "") .. '}\n') end)
    f:close()
  end
  local bpm, bpi = reaper.GetProjectTimeSignature2(p)
  f:write(string.format('{"me":%s,"bpm":%.4f,"bpi":%s,"bars":%s}\n', q(me()), bpm, tostring(bpi), q(reaper.GetExtState(S, "stream bars"))))
  reaper.defer(cycle)
  return "watching Jam tracks into " .. E.out
end

local ok, res = pcall(function()
  local fn = modes[E.mode or ""]
  if not fn then return "mode?" end
  return fn()
end)
return "EARS " .. (ok and tostring(res) or ("error: " .. tostring(res))) -- (tagged: a shared eval hook can hand back someone else's result)
