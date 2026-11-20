-- Latency calibration per person (lib/calibrate.lua; docs/realtime-roadmap.md "More big ideas" 8): finding the burst by cross-correlation in
-- synthetic recordings (silence, gain, a polarity flip, clipping, noise, a speaker's smear, nothing there), three bursts into one offset (late,
-- early, disagreeing, one missing), the played file read back, and with REAPER stubbed: a whole check in a scratch tab (what it plays, records,
-- stops, closes and puts back), Correct it / Put back through REAPER's input offset, and Health's line. (James, rt)
package.path = "lib/?.lua;" .. package.path
local ext, cfgvars, calls, toggles, play = {}, { adjrecmanlatin = 0 }, {}, { [40364] = 1, [41819] = 0, [40076] = 1, [40253] = 0 }, 0
local deferred, front, tabs, now_p, dev = nil, "SONG", {}, 100, { IDENT_IN = "ToneX", SRATE = "8000", BSIZE = "128" }
local rec_item, rec_late = nil, 0
reaper = setmetatable({
  time_precise = function() return now_p end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  DeleteExtState = function(s, k) ext[s .. "/" .. k] = nil end,
  get_config_var_string = function(k) return cfgvars[k] ~= nil, cfgvars[k] ~= nil and tostring(cfgvars[k]) or "" end,
  SNM_SetIntConfigVar = function(k, v) cfgvars[k] = v; return true end,
  GetAudioDeviceInfo = function(k) return dev[k] ~= nil, dev[k] end,
  GetInputOutputLatency = function() return 64, 96 end,
  Audio_IsRunning = function() return 1 end,
  GetPlayState = function() return play end,
  GetNumAudioInputs = function() return 2 end,
  GetResourcePath = function() return "RES" end,
  EnumerateSubdirectories = function() return nil end,
  EnumerateFiles = function() return nil end,
  RecursiveCreateDirectory = function() return true end,
  GetToggleCommandState = function(id) return toggles[id] or 0 end,
  Main_OnCommand = function(id)
    calls[#calls + 1] = id
    if id == 40859 then tabs[#tabs + 1] = "TAB"; front = "TAB"
    elseif id == 40860 then tabs[#tabs] = nil; front = "OTHER" -- (REAPER fronts a neighbour, not necessarily the song)
    elseif id == 1013 then play = 5
    elseif id == 40667 then play = 0
    elseif id == 40252 then toggles[40076], toggles[40253] = 0, 0
    elseif toggles[id] then toggles[id] = 1 - toggles[id] end
  end,
  EnumProjects = function() return front end,
  SelectProjectInstance = function(p) front = p end,
  ValidatePtr2 = function(_, p) return p == "SONG" or (p == "TAB" and #tabs > 0) end,
  GetPlayStateEx = function() return play end,
  GetPlayPosition2Ex = function() return 2.5 end,
  GetSetProjectInfo = function() return 0 end,
  Main_SaveProjectEx = function(_, path) calls[#calls + 1] = "save " .. path end,
  CountTracks = function() return 0 end,
  InsertTrackInProject = function() end,
  GetTrack = function() return "TR" end,
  PCM_Source_CreateFromFile = function() return "SRC" end,
  SetMediaTrackInfo_Value = function(_, k, v) calls[#calls + 1] = k .. "=" .. v end,
  GetTrackMediaItem = function() return rec_item end,
  GetActiveTake = function() return "TK" end,
  CreateTakeAudioAccessor = function() return "ACC" end,
  DestroyAudioAccessor = function() end,
  GetMediaItemInfo_Value = function() return 0 end,
  new_array = function(n)
    local a = {}
    a.table = function() local t = {} for i = 1, n do t[i] = a[i] or 0 end return t end
    return a
  end,
  defer = function(f) deferred = f end,
  atexit = function() end,
}, { __index = function() return function() return "" end end })
local band = require("band")
band.log = function() end
band.files = function() return {} end
band.add_item = function() return "IT", "TK" end
local cal = require("calibrate")
local SR = 8000
local real_open, written = io.open, {}
io.open = function(path, mode) -- (the played file: kept in memory)
  if path:match("^RES/") then return { write = function(_, ...) written[path] = table.concat({ ... }) end, close = function() end } end
  return real_open(path, mode)
end

-- a recording: the bursts as the played file has them, `late` samples late, through `fx`(v, i) per sample
local seed = 7
local function noise() seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 1073741824 - 1 end
local function recording(late, fx, starts, n)
  local ref, rec = cal.burst(), {}
  for i = 1, n do rec[i] = 0 end
  for _, s in ipairs(starts) do for i, v in ipairs(ref) do if s + late + i <= n then rec[s + late + i] = v * 0.5 end end end
  for i = 1, n do rec[i] = fx and fx(rec[i], i) or rec[i] end
  return rec
end
local starts, N = cal.starts(SR), math.floor(cal.LEN * SR)

-- ---- the burst ----
do
  local b, sum = cal.burst(), 0
  assert(#b == cal.BURST, "BURST samples")
  for _, v in ipairs(b) do assert(v == 1 or v == -1, "+-1 only"); sum = sum + v end
  assert(math.abs(sum) < cal.BURST / 8, "about as many + as -: white, no DC")
  local again = cal.burst()
  for i = 1, #b do assert(b[i] == again[i], "the same every time: the file and the search agree") end
end

-- ---- one burst: where it starts ----
do
  local ref = cal.burst()
  local one = recording(0, nil, { 300 }, 2000)
  local lag, sc = cal.find(one, ref, 0, 1000)
  assert(lag == 300 and sc > 0.99, "in silence: exactly where it is, a perfect score")
  local quiet = recording(0, function(v) return v * 0.001 end, { 300 }, 2000)
  lag, sc = cal.find(quiet, ref, 0, 1000)
  assert(lag == 300 and sc > 0.99, "60 dB down: the same lag, the same score (normalised)")
  local flipped = recording(0, function(v) return -v end, { 300 }, 2000)
  lag, sc = cal.find(flipped, ref, 0, 1000)
  assert(lag == 300 and sc > 0.99, "a polarity flip (an inverting input or speaker): the same lag")
  local clipped = recording(0, function(v) return math.max(-0.05, math.min(0.05, v * 20)) end, { 300 }, 2000)
  lag = cal.find(clipped, ref, 0, 1000)
  assert(lag == 300, "hard clipped (too much gain): the same lag")
  local noisy = recording(0, function(v) return v + noise() * 0.5 end, { 300 }, 2000)
  lag, sc = cal.find(noisy, ref, 0, 1000)
  assert(lag == 300 and sc > cal.MIN_SCORE, "in noise as loud as the burst: found, clearly above the floor (" .. sc .. ")")
  local smear = recording(0, nil, { 300 }, 2000)
  local sm = {}
  for i = 1, #smear do sm[i] = 0.5 * (smear[i] or 0) + (smear[i - 1] or 0) + 0.5 * (smear[i - 2] or 0) end -- (a speaker and mic: spread over 3 samples, centred 1 late)
  lag = cal.find(sm, ref, 0, 1000)
  assert(lag == 301, "smeared: at the middle of the smear")
  local none = {}
  for i = 1, 2000 do none[i] = noise() * 0.3 end
  lag, sc = cal.find(none, ref, 0, 1000)
  assert(sc < cal.MIN_SCORE, "noise and no burst: under the floor (" .. sc .. ")")
  local silent = {}
  for i = 1, 2000 do silent[i] = 0 end
  lag, sc = cal.find(silent, ref, 0, 1000)
  assert(sc == 0, "silence: score 0, no division by zero")
  assert(cal.find(one, ref, 1800, 1900) == nil, "a window the burst can't fit in: nil")
  assert(cal.find(one, ref, -50, 400) == 300, "a window starting before the recording is clipped to it")
end

-- ---- three bursts: one offset ----
do
  local r = cal.measure(recording(37, nil, starts, N), cal.burst(), starts, SR)
  assert(r and r.late == 37 and r.spread == 0 and r.score > 0.99, "37 samples late")
  r = cal.measure(recording(-20, nil, starts, N), cal.burst(), starts, SR)
  assert(r and r.late == -20, "20 samples early (a driver reporting too much)")
  r = cal.measure(recording(0, nil, starts, N), cal.burst(), starts, SR)
  assert(r and r.late == 0, "on time")
  r = cal.measure(recording(math.floor(0.2 * SR), nil, starts, N), cal.burst(), starts, SR)
  assert(r and r.late == math.floor(0.2 * SR), "200 ms late (no compensation at all): still in the window")
  local all = recording(12, function(v) return math.max(-0.2, math.min(0.2, -v * 3)) + noise() * 0.2 end, starts, N)
  r = cal.measure(all, cal.burst(), starts, SR)
  assert(r and r.late == 12, "flipped, clipped and noisy together: 12")
  local missing = recording(10, nil, { starts[1], starts[2] }, N)
  local res, why = cal.measure(missing, cal.burst(), starts, SR)
  assert(res == nil and why == "quiet", "a burst that didn't come back: no answer, not a guess")
  local apart = recording(10, nil, { starts[1], starts[2] }, N)
  local ref = cal.burst()
  for i, v in ipairs(ref) do apart[starts[3] + 40 + i] = v * 0.5 end
  res, why = cal.measure(apart, ref, starts, SR)
  assert(res == nil and why == "spread", "bursts 30 samples apart: something else got in")
  local jitter = recording(10, nil, { starts[1], starts[2] }, N)
  for i, v in ipairs(ref) do jitter[starts[3] + 12 + i] = v * 0.5 end
  r = cal.measure(jitter, ref, starts, SR)
  assert(r and r.late == 10 and r.spread == 2, "two samples' disagreement is allowed: the middle one")
end

-- ---- the played file, read back ----
do
  local bytes = cal.wav_bytes(SR)
  local riff, size, wave, _, _, fmt, chans, rate, _, _, bits, data, len = string.unpack("<c4I4c4c4I4I2I2I4I4I2I2c4I4", bytes)
  assert(riff == "RIFF" and wave == "WAVE" and data == "data" and fmt == 1 and chans == 1 and rate == SR and bits == 16, "a mono 16-bit PCM WAV at the rate")
  assert(size == #bytes - 8 and len == #bytes - 44 and len == 2 * N, "sizes agree; LEN seconds long")
  local rec = {}
  for i = 1, N do rec[i] = string.unpack("<i2", bytes, 44 + 2 * i - 1) / 32768 end
  local r = cal.measure(rec, cal.burst(), starts, SR)
  assert(r and r.late == 0, "the file as played, read straight back: on time (the file and the search agree)")
  assert(cal.words(0, SR) == "exactly on time" and cal.words(8, SR) == "1.00 ms (8 samples) late" and cal.words(-1, SR) == "0.12 ms (1 sample) early", "in words")
end

-- ---- a whole check, REAPER stubbed ----
do
  play = 5
  local ok, why = cal.start(1)
  assert(not ok and why:match("Stop playback"), "never while playing")
  play = 0
  ok, why = cal.start(3)
  assert(not ok and why:match("Input 3"), "an input the device doesn't have")
  assert(#calls == 0, "refused: nothing touched")
  rec_item, rec_late = "REC", 25
  reaper.GetAudioAccessorSamples = function(_, sr, nch, t0, n, buf)
    assert(sr == SR and nch == 1 and t0 == 0 and n == N, "read mono at the device's rate from the take's start")
    local r = recording(rec_late, function(v) return v + noise() * 0.1 end, starts, n)
    for i = 1, n do buf[i] = r[i] end
  end
  local started, swhy = cal.start(1)
  assert(started == true and cal.running(), "started: " .. tostring(swhy))
  assert(written["RES/StudioSync/latency-check/bursts.wav"] == cal.wav_bytes(SR), "the bursts written at the device's rate")
  assert(front == "TAB", "in a scratch tab of its own")
  local seen = table.concat((function() local t = {} for _, c in ipairs(calls) do t[#t + 1] = tostring(c) end return t end)(), ",")
  assert(seen:match("I_RECINPUT=0") and seen:match("I_RECMON=0") and seen:match("I_RECARM=1"), "records input 1, unmonitored (a loop would feed back)")
  assert(seen:match("40364") and toggles[40364] == 0 and toggles[40076] == 0, "metronome off and auto-punch to normal for the run")
  assert(seen:match("save RES/StudioSync/latency%-check/check.rpp"), "the tab saved in its own folder, so what it records lands there")
  assert(calls[#calls] == 1013 and deferred, "records, then waits")
  local wait = deferred
  deferred = nil
  calls = {}
  wait() -- (GetPlayPosition2Ex says past the end)
  assert(not cal.running(), "done")
  assert(calls[1] == 40667, "stopped first, saving what it recorded (no question)")
  local closed
  for i, c in ipairs(calls) do if c == 40860 then closed = i end end
  assert(closed and #tabs == 0, "the scratch tab closed")
  assert(toggles[40364] == 1 and toggles[40076] == 1, "metronome and auto-punch put back")
  assert(front == "SONG", "back to the song's tab, not whichever REAPER fronted")
  local r = cal.last()
  assert(r and r.late == 25 and r.sr == SR and r.din == 64 and r.dout == 96 and r.off == 0 and r.device == "ToneX|8000|128", "kept: 25 late, the driver's numbers, the device")
  assert(cfgvars.adjrecmanlatin == 0, "measuring never changes REAPER's offset")
end

-- ---- Correct it and Put back ----
do
  assert(cal.apply(25) == true and cfgvars.adjrecmanlatin == 25, "Correct it: REAPER's input offset +25")
  assert(cal.fix().from == 0 and cal.fix().to == 25, "what it was, kept")
  assert(cal.apply(27) == true and cal.fix().from == 0, "corrected again after another check: Put back still goes to the first value")
  assert(cal.put_back() == true and cfgvars.adjrecmanlatin == 0 and cal.fix() == nil, "Put back: as it was")
  local set = reaper.SNM_SetIntConfigVar
  reaper.SNM_SetIntConfigVar = false -- (nil would fall to the stub's catch-all)
  local ok, why = cal.apply(25)
  assert(not ok and why:match("SWS") and cfgvars.adjrecmanlatin == 0, "no SWS: says where to type it, changes nothing")
  reaper.SNM_SetIntConfigVar = set
end

-- ---- Health ----
do
  local saved = ext["BandSync/latency check"]
  ext["BandSync/latency check"] = nil
  local row = cal.health_row()
  assert(row[1] == "latency" and row[2] == false and row[3] == "grey" and row.action and row.action[1] == "Measure my latency", "never checked: grey, with Measure")
  row.action[2]()
  assert(ext["BandSync/setup tab"] == "Advanced", "Measure opens Settings > Advanced")
  ext["BandSync/latency check"] = saved
  row = cal.health_row()
  assert(row[2] == true and row[4]:match("min ago") and row[4]:match("ms %(25 samples%) late") and not row.action, "checked: when, and what it found")
  cal.apply(25)
  row = cal.health_row()
  assert(row[4]:match("Corrected: REAPER's input offset is 25 samples %(was 0%)"), "the correction in use")
  dev.BSIZE = "256"
  row = cal.health_row()
  assert(row[2] == false and row.action[1] == "Measure again" and row[4]:match("changed since"), "another buffer size: worth measuring again")
end

print("ok calibrate")
