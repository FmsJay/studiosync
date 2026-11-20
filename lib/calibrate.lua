-- Latency calibration per person (docs/realtime-roadmap.md "More big ideas" 8; James, rt). Mostly automatic already: REAPER places each
-- recording by the latency the audio driver reports (input + output), and StudioSync covers the network from the shared clock. This checks
-- the driver, for the ones that misreport by a few ms, so parts recorded against a bandmate land on the grid.
-- Measure my latency (Settings > Advanced; Health's line points there): with an output looped to an input (a cable, or a mic held to a
-- speaker), a scratch project tab (nothing StudioSync: no sync runs on it, as lib/export.lua's) plays three short noise bursts through the
-- master's outputs and records them back on the chosen input. Each burst is found by cross-correlation (cal.find: gain, a polarity flip and
-- clipping don't move it), and how late they land is the driver's misreport, REAPER's own compensation included. The tab, its tracks and
-- every file it made go afterwards; the metronome, pre-roll and record mode are put back.
-- The fix goes where REAPER keeps it: Preferences > Audio > Recording, Input manual offset (reaper.ini `adjrecmanlatin`; "added to the
-- automatic offset, can be negative"). Verified on a ToneX: 203 samples late fixed by +203 (reaper skill F-0039); a UR22mkII on the same
-- laptop needs -8. REAPER keeps one offset for every interface, so a measurement is kept per interface, per computer (ExtState "latency
-- offsets"), and cal.tick sets REAPER's to the one for the interface in use: at each start (Autostart, Live sync) and when the device
-- changes. REAPER doesn't save an offset set through SWS to reaper.ini on quit (it still held 203 after clean quits), and that no longer
-- matters: it's set again at every start. An interface never measured is left alone, and a value typed in Preferences after measuring
-- becomes that interface's (never fought). (James, rt)
-- Keyed by the input device and sample rate, not the buffer: the offset is in samples and converters' filters change with the rate, but
-- people move the buffer all the time (low to track, high to mix) and a driver's misreport is mostly fixed; Health says when the buffer
-- differs from the measured one. (James, rt)
-- Not covered: a take's streamed placeholder (lib/streams.lua) is the raw file at the take's start, uncompensated; the real take replaces it.
local band = require("band")
local cal = { BURST = 512, AT = { 0.5, 1.0, 1.5 }, LEN = 2.0, EARLY = 0.05, LATE = 0.25, MIN_SCORE = 0.2, MAX_SPREAD = 4, AMP = 0.5,
  KEY = "latency check", KEY_OFFS = "latency offsets", KEY_IN = "latency input", PREF = "adjrecmanlatin", EVERY = 1 }

-- ---- pure ------------------------------------------------------------------------------------------------------------------------------
-- The burst: BURST samples of +-1 from a fixed generator (white, so its correlation with itself is one sharp peak). Pure.
function cal.burst(n)
  local t, x = {}, 12345
  for i = 1, n or cal.BURST do
    x = (x * 1103515245 + 12345) % 2147483648
    t[i] = x >= 1073741824 and 1 or -1 -- (the top bit: an LCG's low bits repeat)
  end
  return t
end
-- Where `ref` starts in `rec` (1-based arrays): the lag in lo..hi (0-based, rec[lag + 1] lines up with ref[1]) with the largest |normalised
-- correlation|, so gain, polarity and clipping don't move it. -> lag, score (0..1), or nil when the window doesn't fit. Pure.
-- (lags x BURST multiplies: 0.3 s at 48 kHz is 7 M per burst, well under a second in Lua; at 192 kHz four times that, once.)
function cal.find(rec, ref, lo, hi)
  local m = #ref
  lo, hi = math.max(0, lo), math.min(hi, #rec - m)
  if hi < lo then return nil end
  local eref, ewin = 0, 0
  for i = 1, m do eref = eref + ref[i] * ref[i] end
  for i = lo + 1, lo + m do ewin = ewin + rec[i] * rec[i] end
  local best, at = -1, nil
  for lag = lo, hi do
    if lag > lo then local a, z = rec[lag], rec[lag + m]; ewin = ewin - a * a + z * z end -- (the window's energy, slid along)
    local s = 0
    for i = 1, m do s = s + rec[lag + i] * ref[i] end
    local d = math.max(ewin, 0) * eref
    local sc = d > 1e-20 and math.abs(s) / math.sqrt(d) or 0
    if sc > best then best, at = sc, lag end
  end
  return at, best
end
-- How late the bursts landed: `starts`, each burst's 0-based sample in `rec` had it landed exactly; `sr` the rate. Searched from EARLY s
-- early to LATE s late (a driver whose latency isn't compensated at all lands its whole round trip late).
-- -> { late (samples, + = late), spread, score }, or nil, "quiet" (a burst didn't come back clearly) / "spread" (they disagree). Pure.
function cal.measure(rec, ref, starts, sr)
  local lags, score, lo_d, hi_d = {}, 1, math.huge, -math.huge
  for _, s in ipairs(starts) do
    local lag, sc = cal.find(rec, ref, s - math.floor(cal.EARLY * sr), s + math.floor(cal.LATE * sr))
    if not lag or sc < cal.MIN_SCORE then return nil, "quiet", sc end
    local d = lag - s
    lags[#lags + 1], score, lo_d, hi_d = d, math.min(score, sc), math.min(lo_d, d), math.max(hi_d, d)
  end
  if #lags == 0 then return nil, "quiet" end
  if hi_d - lo_d > cal.MAX_SPREAD then return nil, "spread", hi_d - lo_d end
  table.sort(lags)
  return { late = lags[(#lags + 1) // 2], spread = hi_d - lo_d, score = score }
end
-- Each burst's first sample in the played file at rate `sr`, 0-based (the file and the measurement agree on these). Pure.
function cal.starts(sr)
  local t = {}
  for i, at in ipairs(cal.AT) do t[i] = math.floor(at * sr + 0.5) end
  return t
end
-- The played file, a mono 16-bit WAV at `sr`: silence with the burst at each of cal.starts. Pure (bytes).
function cal.wav_bytes(sr)
  local ref, one = cal.burst(), {}
  for i, v in ipairs(ref) do one[i] = string.pack("<i2", math.floor(v * 32767 * cal.AMP)) end
  one = table.concat(one)
  local parts, last = {}, 0
  for _, s in ipairs(cal.starts(sr)) do parts[#parts + 1] = string.rep("\0\0", s - last) .. one; last = s + #ref end
  parts[#parts + 1] = string.rep("\0\0", math.max(0, math.floor(cal.LEN * sr) - last))
  local data = table.concat(parts)
  return string.pack("<c4I4c4c4I4I2I2I4I4I2I2c4I4", "RIFF", 36 + #data, "WAVE", "fmt ", 16, 1, 1, sr, sr * 2, 2, 16, "data", #data) .. data
end
-- A result in words: "1.2 ms (58 samples) late". Pure.
function cal.words(late, sr)
  if late == 0 then return "exactly on time" end
  return string.format("%.2f ms (%d sample%s) %s", math.abs(late) / sr * 1000, math.abs(late), math.abs(late) == 1 and "" or "s", late > 0 and "late" or "early")
end
local function ago(t)
  local s = os.time() - (tonumber(t) or os.time())
  return s < 3600 and string.format("%d min ago", s // 60) or s < 86400 and string.format("%d h ago", s // 3600) or string.format("%d days ago", s // 86400)
end
local function day(t) return os.date("%b ", tonumber(t) or os.time()) .. tonumber(os.date("%d", tonumber(t) or os.time())) end -- "Nov 19"
-- An interface's key: the input device REAPER names (GetAudioDeviceInfo IDENT_IN) and the rate; nil when there's no device. Pure.
function cal.key(ident, sr)
  ident, sr = (tostring(ident or ""):gsub("^%s+", ""):gsub("%s+$", "")), math.floor(tonumber(sr) or 0)
  if ident == "" or sr <= 0 then return nil end
  return ident .. "|" .. sr
end
-- What to do with REAPER's input offset `off` (nil: unreadable). `want`, this interface's kept offset (nil: never measured); `changed`, the
-- interface changed since the last look (or it's the first, at a start); `seen`, REAPER's value at the last look.
-- -> "set", n / "adopt", n (typed in Preferences since: it becomes the interface's) / nil (leave it). Pure.
function cal.choose(want, changed, off, seen)
  if not want or not off or off == want then return nil end -- (never measured: REAPER's value stays, whatever it is)
  if not changed and off ~= seen then return "adopt", off end
  return "set", want -- (a start, another interface, or the kept value changed elsewhere: a new measurement, another script's adoption)
end

-- ---- this computer ---------------------------------------------------------------------------------------------------------------------
local function dev_info(k) return select(2, reaper.GetAudioDeviceInfo(k)) end
local function device() return table.concat({ dev_info("IDENT_IN") or "", dev_info("SRATE") or "", dev_info("BSIZE") or "" }, "|") end
-- REAPER's input manual offset (samples), read through the core API; nil when it can't be read.
function cal.offset()
  local v = tonumber(select(2, reaper.get_config_var_string(cal.PREF)))
  if v or not reaper.SNM_GetIntConfigVar then return v end
  v = reaper.SNM_GetIntConfigVar(cal.PREF, -999999) -- (SWS's reader, if the core one gave nothing)
  return v ~= -999999 and v or nil
end
function cal.last() local r = band.ext_json(band.SECTION, cal.KEY); return type(r) == "table" and r or nil end
-- The interface in use: key, name, rate, buffer; nil when REAPER's device isn't running.
function cal.here()
  if reaper.Audio_IsRunning() ~= 1 then return nil end
  local id, sr = dev_info("IDENT_IN") or "", math.floor(tonumber(dev_info("SRATE")) or 0)
  return cal.key(id, sr), id, sr, math.floor(tonumber(dev_info("BSIZE")) or 0)
end
-- The kept offsets: key -> { off, name, sr, buf (measured at), at (measured), typed (set in Preferences since), late, from (REAPER's before) }
function cal.offsets() local t = band.ext_json(band.SECTION, cal.KEY_OFFS); return type(t) == "table" and t or {} end
local function save(t) reaper.SetExtState(band.SECTION, cal.KEY_OFFS, band.json_encode(t), true) end
local look = { at = -math.huge } -- the last look: { key, seen (REAPER's value then), failed (the key REAPER refused) }; per script (each has its own)
-- REAPER's input offset to the interface's kept one, cheaply (two device reads and a config read, once a second at most; `now` skips the wait).
function cal.tick(now)
  if not now and reaper.time_precise() - look.at < cal.EVERY then return end
  look.at = reaper.time_precise()
  local key = cal.here()
  if not key then return end
  local all, off = cal.offsets(), cal.offset()
  local e = all[key]
  local act, n = cal.choose(e and tonumber(e.off), key ~= look.key, off, look.seen)
  look.key = key
  if act == "adopt" then
    e.off, e.typed = n, os.time()
    save(all)
    band.log(string.format("recording latency: you set REAPER's input offset to %d samples in Preferences: kept for %s at %d Hz", n, e.name or key, tonumber(e.sr) or 0))
  elseif act == "set" and reaper.SNM_SetIntConfigVar then -- (no SWS: Health and Settings say the number to type)
    if reaper.SNM_SetIntConfigVar(cal.PREF, math.floor(n)) then
      band.log(string.format("recording latency: REAPER's input offset %d -> %d samples for %s at %d Hz (measured %s)", off, n, e.name or key, tonumber(e.sr) or 0, day(e.at)))
      off, look.failed = n, nil
    elseif look.failed ~= key then look.failed = key; band.log("recording latency: REAPER didn't take an input offset of " .. n .. " samples") end
  end
  look.seen = off
end
-- Forget an interface's offset; when it's the one in use and REAPER still has it, REAPER's goes back to what it was before the first measurement.
function cal.forget(key)
  local all = cal.offsets()
  local e = all[key]
  if not e then return end
  all[key] = nil
  save(all)
  local back = tonumber(e.from)
  back = back and key == cal.here() and cal.offset() == tonumber(e.off) and reaper.SNM_SetIntConfigVar and reaper.SNM_SetIntConfigVar(cal.PREF, math.floor(back)) and back
  band.log(string.format("recording latency: forgot %s at %d Hz (%d samples)%s", e.name or key, tonumber(e.sr) or 0, tonumber(e.off) or 0,
    back and (", REAPER's input offset back to " .. back) or ""))
end

-- ---- the measurement (a scratch tab, a few seconds) ------------------------------------------------------------------------------------
local run, said -- the measurement going on: { tab, front, rec, dir, sr, t0, back }; the last thing to say (an error, or nil)
local function work_dir() return band.home() .. "/latency-check" end
local function clean(dir) -- (its files and one level of folders: REAPER may record into a Media folder, and peaks go beside)
  for _, f in ipairs(band.files(dir)) do os.remove(dir .. "/" .. f) end
  local i = 0
  while true do
    local sub = reaper.EnumerateSubdirectories(dir, i)
    if not sub then break end
    for _, f in ipairs(band.files(dir .. "/" .. sub)) do os.remove(dir .. "/" .. sub .. "/" .. f) end
    i = i + 1
  end
end
-- The metronome would play into the bursts, pre-roll moves the start, and an auto-punch record mode records nothing in an empty tab:
-- off for the run, then put back. (40364 metronome, 41819 pre-roll on record; 40076/40253 auto-punch, 40252 normal: F-0039, reaper skill)
local function quiet_transport()
  local back = {}
  for _, id in ipairs({ 40364, 41819 }) do
    if reaper.GetToggleCommandState(id) == 1 then reaper.Main_OnCommand(id, 0); back[#back + 1] = id end
  end
  for _, id in ipairs({ 40076, 40253 }) do
    if reaper.GetToggleCommandState(id) == 1 then reaper.Main_OnCommand(40252, 0); back[#back + 1] = id end
  end
  return back
end
local function put_transport(back) for _, id in ipairs(back or {}) do reaper.Main_OnCommand(id, 0) end end

local function read_and_measure(r)
  local item = r.rec and reaper.GetTrackMediaItem(r.rec, 0)
  if not item then return nil, "Nothing was recorded: is REAPER's audio device open, and does that input exist?" end
  local take = reaper.GetActiveTake(item)
  local acc = take and reaper.CreateTakeAudioAccessor(take)
  if not acc then return nil, "The recording couldn't be read." end
  local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local n = math.floor(cal.LEN * r.sr)
  local buf = reaper.new_array(n)
  reaper.GetAudioAccessorSamples(acc, r.sr, 1, 0, n, buf) -- (take time: 0 is the item's start)
  reaper.DestroyAudioAccessor(acc)
  local starts, shift = cal.starts(r.sr), math.floor(pos * r.sr + 0.5)
  for i, s in ipairs(starts) do starts[i] = s - shift end
  local res, why, v = cal.measure(buf.table(), cal.burst(), starts, r.sr)
  if not res then
    return nil, why == "spread" and string.format("The bursts came back %d samples apart: something else got in (noise, a plug-in on the input?). Try again.", v)
      or "No clear burst came back. Check the cable (or mic) goes from the master's output to that input, and the input's gain."
  end
  return res
end
local function finish(r)
  run = nil
  if not reaper.ValidatePtr2(0, r.tab, "ReaProject*") then put_transport(r.back); said = "The check's project tab was closed before it finished."; return end
  reaper.SelectProjectInstance(r.tab) -- (actions go to the tab in front: the person may have clicked another)
  reaper.Main_OnCommand(40667, 0) -- Transport: Stop (save all recorded media): no keep/delete question
  local ok, res, why = pcall(read_and_measure, r)
  put_transport(r.back)
  reaper.Main_SaveProjectEx(r.tab, r.dir .. "/check.rpp", 8) -- (a saved tab closes without a question)
  reaper.Main_OnCommand(40860, 0) -- File: Close current project tab
  clean(r.dir)
  if r.front and reaper.ValidatePtr2(0, r.front, "ReaProject*") then reaper.SelectProjectInstance(r.front) end
  if not ok or not res then said = ok and why or ("The check failed: " .. tostring(res)); return end
  local din, dout = reaper.GetInputOutputLatency()
  local rec = { at = os.time(), late = res.late, spread = res.spread, score = math.floor(res.score * 100 + 0.5) / 100, sr = r.sr, din = din, dout = dout,
    off = cal.offset(), device = device(), input = r.ch }
  reaper.SetExtState(band.SECTION, cal.KEY, band.json_encode(rec), true)
  said = nil
  band.log("recording latency measured: recordings land " .. cal.words(res.late, r.sr) .. string.format(" (driver reports %d in + %d out samples)", din or 0, dout or 0))
  -- the offset that lands it on time becomes this interface's, and is set now (as at a start: the next look counts it as new. James, rt)
  local key, name, sr, buf = cal.here()
  if not (key and rec.off) then said = "Measured, but REAPER's device or input offset couldn't be read: nothing kept."; return end
  local all = cal.offsets()
  local old = all[key]
  all[key] = { off = rec.off + res.late, name = name, sr = sr, buf = buf, at = rec.at, late = res.late, from = old and old.from or rec.off }
  save(all)
  look.key = nil
  cal.tick(true)
end
local function wait()
  local r = run
  if not r then return end
  local recording = reaper.ValidatePtr2(0, r.tab, "ReaProject*") and reaper.GetPlayStateEx(r.tab) & 4 == 4
  if recording and reaper.GetPlayPosition2Ex(r.tab) < cal.LEN - 0.05 and reaper.time_precise() - r.t0 < cal.LEN + 10 then return reaper.defer(wait) end
  finish(r)
end
local exit_set
-- Start: `ch` the input (1-based) the output is looped to. -> true, or nil, why.
function cal.start(ch)
  if run then return nil, "Already measuring." end
  if reaper.Audio_IsRunning() ~= 1 then return nil, "REAPER's audio device isn't running (Preferences > Audio > Device)." end
  if reaper.GetPlayState() ~= 0 then return nil, "Stop playback first." end
  local nin = reaper.GetNumAudioInputs()
  if not ch or ch < 1 or ch > nin then return nil, string.format("Input %s isn't there: this device has %d.", tostring(ch), nin) end
  local sr = math.floor(tonumber(dev_info("SRATE")) or 0)
  if sr <= 0 then return nil, "REAPER's audio device didn't say its sample rate." end
  local dir = work_dir()
  reaper.RecursiveCreateDirectory(dir, 0)
  clean(dir)
  local f = io.open(dir .. "/bursts.wav", "wb")
  if not f then return nil, "Couldn't write in " .. dir .. "." end
  f:write(cal.wav_bytes(sr))
  f:close()
  local front = reaper.EnumProjects(-1)
  reaper.Main_OnCommand(40859, 0) -- File: New project tab (nothing StudioSync: no sync runs on it)
  local tab = reaper.EnumProjects(-1)
  reaper.GetSetProjectInfo(tab, "PROJECT_SRATE", sr, true) -- (the bursts play unresampled)
  reaper.GetSetProjectInfo(tab, "PROJECT_SRATE_USE", 1, true)
  reaper.Main_SaveProjectEx(tab, dir .. "/check.rpp", 8) -- (its own folder: what it records lands there)
  band.add_item(band.new_track(tab, "bursts"), dir .. "/bursts.wav", 0)
  local rec = band.new_track(tab, "loopback")
  reaper.SetMediaTrackInfo_Value(rec, "I_RECINPUT", ch - 1) -- (mono hardware input, 0-based)
  reaper.SetMediaTrackInfo_Value(rec, "I_RECMODE", 0) -- (record the input)
  reaper.SetMediaTrackInfo_Value(rec, "I_RECMON", 0) -- (no monitoring: a loop back out would feed back)
  reaper.SetMediaTrackInfo_Value(rec, "I_RECARM", 1)
  reaper.SetEditCurPos2(tab, 0, false, false)
  run = { tab = tab, front = front, rec = rec, dir = dir, sr = sr, ch = ch, t0 = reaper.time_precise(), back = quiet_transport() }
  if not exit_set then -- (the panel closed mid-check: stop it, put things back, close the tab)
    exit_set = true
    reaper.atexit(function() if run then pcall(finish, run) end end)
  end
  said = nil
  reaper.Main_OnCommand(1013, 0) -- Transport: Record
  reaper.defer(wait)
  return true
end
function cal.running() return run ~= nil end

-- ---- Health and Settings ---------------------------------------------------------------------------------------------------------------
local function go_measure() reaper.SetExtState(band.SECTION, "setup tab", "Advanced", false) end
local function type_it(n) return string.format("type %d in Preferences > Audio > Recording, Input manual offset (with SWS, sws-extension.org, StudioSync sets it itself)", n) end
-- Health's line for the interface in use: its kept offset and whether REAPER has it; grey (it's optional), Measure when never measured or
-- measured at another buffer, yellow when kept but not in REAPER.
function cal.health_row()
  local key, name, _, buf = cal.here()
  local e, off = key and cal.offsets()[key], cal.offset()
  local act = { "Measure my latency", go_measure, "Settings > Advanced > Recording latency: a loopback check, under a minute." }
  if not e then
    return { "latency", false, "grey", "", "Recording latency hasn't been checked on " .. (key and name or "this audio device") .. ". REAPER lines recordings up by " ..
      "what your audio interface reports; a loopback check shows whether it's off by a few ms." .. (off and off ~= 0 and string.format(" REAPER's input offset stays %d samples.", off) or ""), action = act }
  end
  local want = tonumber(e.off) or 0
  local text = string.format("Recording latency: %s %d samples (%s %s)", e.name or name, want, e.typed and "set in Preferences" or "measured", day(e.typed or e.at))
  if off ~= want then
    text = text .. string.format(", not applied: REAPER's input offset is %s. %s.", tostring(off or "unreadable"), reaper.SNM_SetIntConfigVar and "StudioSync sets it within a second while Live sync or its autostart runs" or ("To fix it, " .. type_it(want)))
    return { "latency", false, "yellow", text, text, action = act }
  end
  text = text .. ", applied. StudioSync sets it at each start and when you switch interface (REAPER doesn't keep it across restarts by itself)."
  local moved = tonumber(e.buf) and tonumber(e.buf) ~= buf
  if moved then text = text .. string.format(" Measured at a %d-sample buffer, now %d: worth measuring again.", tonumber(e.buf), buf) end
  local row = { "latency", not moved, "grey", text, text }
  if moved then act[1] = "Measure again"; row.action = act end
  return row
end

local confirm = false
function cal.ui(ctx, ImGui)
  ImGui.SeparatorText(ctx, "Recording latency")
  ImGui.TextDisabled(ctx, "REAPER lines up what you record by the latency your audio interface reports, and StudioSync covers the internet. Some drivers " ..
    "misreport by a few ms: this checks yours, so what you record against a bandmate lands on the grid. Loop an output to an input with a cable (or hold " ..
    "a mic to a speaker); three short bursts play through the master's outputs. What it finds is kept for that interface and set in REAPER whenever you use it.")
  local key, name = cal.here()
  ImGui.Text(ctx, key and ("This interface: " .. name) or "REAPER's audio device isn't running.")
  local ch = math.floor(tonumber(reaper.GetExtState(band.SECTION, cal.KEY_IN)) or 1)
  ImGui.SetNextItemWidth(ctx, 110)
  local chg, v = ImGui.InputInt(ctx, "input it comes back on##latin", ch)
  if chg then reaper.SetExtState(band.SECTION, cal.KEY_IN, tostring(math.max(1, v)), true) end
  if run then ImGui.Text(ctx, "Measuring...")
  elseif confirm then
    ImGui.TextWrapped(ctx, "Turn speakers and headphones down if it's a cable: the bursts are loud.")
    if ImGui.Button(ctx, "Play the bursts##latgo") then
      confirm = false
      local ok, why = cal.start(ch)
      if not ok then said = why end
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Cancel##latno") then confirm = false end
  elseif ImGui.Button(ctx, "Measure my latency##latm") then confirm = true end
  if said then ImGui.TextWrapped(ctx, said) end
  local r, off = cal.last(), cal.offset()
  if r and not run then
    local sr, late = tonumber(r.sr) or 48000, tonumber(r.late) or 0
    local drv = (tonumber(r.din) or 0) + (tonumber(r.dout) or 0)
    ImGui.TextWrapped(ctx, string.format("Last check, %s: recordings landed %s. Your driver reports %d samples (%d in + %d out); with REAPER's input offset of %d " ..
      "then, the round trip measured %d samples (%.2f ms).", ago(r.at), cal.words(late, sr), drv, tonumber(r.din) or 0, tonumber(r.dout) or 0, tonumber(r.off) or 0,
      drv + (tonumber(r.off) or 0) + late, (drv + (tonumber(r.off) or 0) + late) / sr * 1000))
  end
  -- every interface measured on this computer, with Forget; REAPER's Input manual offset (Preferences > Audio > Recording) is set to the one in use
  local all, keys = cal.offsets(), {}
  for k in pairs(all) do keys[#keys + 1] = k end
  table.sort(keys)
  for i, k in ipairs(keys) do
    local e = all[k]
    ImGui.Text(ctx, string.format("%s, %d Hz: %d samples (%s %s%s)%s", e.name or k, tonumber(e.sr) or 0, tonumber(e.off) or 0, e.typed and "set in Preferences" or "measured",
      day(e.typed or e.at), tonumber(e.buf) and (", buffer " .. e.buf) or "", k == key and ", in use" or ""))
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, "Forget##latf" .. i) then cal.forget(k) end
    ImGui.SetItemTooltip(ctx, "StudioSync stops setting REAPER's input offset for this interface." .. (k == key and tonumber(e.from) and
      string.format("\nIt's the one in use: REAPER's goes back to %d, what it was before the first measurement.", tonumber(e.from)) or ""))
    if k == key and off ~= tonumber(e.off) and not reaper.SNM_SetIntConfigVar then ImGui.TextWrapped(ctx, "SWS isn't installed, so StudioSync can't set it: " .. type_it(tonumber(e.off) or 0) .. ".") end
  end
end

return cal
