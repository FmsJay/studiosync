-- Latency calibration per person (docs/realtime-roadmap.md "More big ideas" 8; James, rt). Mostly automatic already: REAPER places each
-- recording by the latency the audio driver reports (input + output), and StudioSync covers the network from the shared clock. This checks
-- the driver, for the ones that misreport by a few ms, so parts recorded against a bandmate land on the grid.
-- Measure my latency (Settings > Advanced; Health's line points there): with an output looped to an input (a cable, or a mic held to a
-- speaker), a scratch project tab (nothing StudioSync: no sync runs on it, as lib/export.lua's) plays three short noise bursts through the
-- master's outputs and records them back on the chosen input. Each burst is found by cross-correlation (cal.find: gain, a polarity flip and
-- clipping don't move it), and how late they land is the driver's misreport, REAPER's own compensation included. The tab, its tracks and
-- every file it made go afterwards; the metronome, pre-roll and record mode are put back.
-- The fix goes where REAPER keeps it: Preferences > Audio > Recording, Input manual offset (reaper.ini `adjrecmanlatin`; "added to the
-- automatic offset, can be negative"). Verified on a ToneX: 203 samples late fixed by +203 (reaper skill F-0039). Set through SWS, only when
-- the person presses Correct it, and Put back sets what it was. Kept per computer (ExtState): the device, rate and buffer it was measured
-- with, so Health says when it's worth measuring again.
-- Not covered: a take's streamed placeholder (lib/streams.lua) is the raw file at the take's start, uncompensated; the real take replaces it.
local band = require("band")
local cal = { BURST = 512, AT = { 0.5, 1.0, 1.5 }, LEN = 2.0, EARLY = 0.05, LATE = 0.25, MIN_SCORE = 0.2, MAX_SPREAD = 4, AMP = 0.5,
  KEY = "latency check", KEY_FIX = "latency fix", KEY_IN = "latency input", PREF = "adjrecmanlatin" }

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
function cal.fix() local f = band.ext_json(band.SECTION, cal.KEY_FIX); return type(f) == "table" and f or nil end
-- Set REAPER's input offset to `to`, remembering what it was the first time (so Put back goes all the way back). -> true, or nil, why.
function cal.apply(to)
  if not reaper.SNM_SetIntConfigVar then return nil, "needs SWS (sws-extension.org): or type it in Preferences > Audio > Recording, Input manual offset" end
  local from, f = cal.offset() or 0, cal.fix()
  if not reaper.SNM_SetIntConfigVar(cal.PREF, math.floor(to)) then return nil, "REAPER didn't take it" end
  reaper.SetExtState(band.SECTION, cal.KEY_FIX, band.json_encode({ from = f and f.from or from, to = math.floor(to), at = os.time() }), true)
  band.log(string.format("recording latency: REAPER's input offset %d -> %d samples (Settings > Advanced > Recording latency)", from, math.floor(to)))
  return true
end
function cal.put_back()
  local f = cal.fix()
  if not f then return true end
  if not (reaper.SNM_SetIntConfigVar and reaper.SNM_SetIntConfigVar(cal.PREF, math.floor(tonumber(f.from) or 0))) then return nil, "needs SWS" end
  reaper.DeleteExtState(band.SECTION, cal.KEY_FIX, true)
  band.log(string.format("recording latency: REAPER's input offset put back to %d samples", math.floor(tonumber(f.from) or 0)))
  return true
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
-- Health's line: when it was last measured and the correction in use; grey (it's optional), with Measure when never or on another device.
function cal.health_row()
  local r, off, f = cal.last(), cal.offset(), cal.fix()
  local act = { "Measure my latency", go_measure, "Settings > Advanced > Recording latency: a loopback check, under a minute." }
  if not r then
    return { "latency", false, "grey", "", "Recording latency hasn't been checked here. REAPER lines recordings up by what your audio interface reports; " ..
      "a loopback check shows whether it's off by a few ms.", action = act }
  end
  local text = "Recording latency checked " .. ago(r.at) .. ": recordings landed " .. cal.words(tonumber(r.late) or 0, tonumber(r.sr) or 48000) .. "."
  if f and off == tonumber(f.to) then text = text .. string.format(" Corrected: REAPER's input offset is %d samples (was %d).", off, tonumber(f.from) or 0)
  elseif off and off ~= 0 then text = text .. string.format(" REAPER's input offset: %d samples.", off) end
  local moved = r.device ~= device()
  if moved then text = text .. " Your audio device, rate or buffer changed since: worth measuring again." end
  local row = { "latency", not moved, "grey", text, text }
  if moved then act[1] = "Measure again"; row.action = act end
  return row
end

local confirm = false
function cal.ui(ctx, ImGui)
  ImGui.SeparatorText(ctx, "Recording latency")
  ImGui.TextDisabled(ctx, "REAPER lines up what you record by the latency your audio interface reports, and StudioSync covers the internet. Some drivers " ..
    "misreport by a few ms: this checks yours, so what you record against a bandmate lands on the grid. Loop an output to an input with a cable (or hold " ..
    "a mic to a speaker); three short bursts play through the master's outputs.")
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
  local r, off, f = cal.last(), cal.offset(), cal.fix()
  if r and not run then
    local sr, late = tonumber(r.sr) or 48000, tonumber(r.late) or 0
    local drv = (tonumber(r.din) or 0) + (tonumber(r.dout) or 0)
    ImGui.TextWrapped(ctx, string.format("Checked %s: recordings landed %s. Your driver reports %d samples (%d in + %d out); with REAPER's input offset of %d " ..
      "then, the round trip measured %d samples (%.2f ms).", ago(r.at), cal.words(late, sr), drv, tonumber(r.din) or 0, tonumber(r.dout) or 0, tonumber(r.off) or 0,
      drv + (tonumber(r.off) or 0) + late, (drv + (tonumber(r.off) or 0) + late) / sr * 1000))
    local to = (tonumber(r.off) or 0) + late
    if late ~= 0 and off and off ~= to then
      if ImGui.Button(ctx, string.format("Correct it: input offset %d -> %d##latfix", off, to)) then local ok, why = cal.apply(to); said = not ok and why or "Corrected. Measure again to check it lands on time." end
      ImGui.SetItemTooltip(ctx, "Sets REAPER's own Input manual offset (Preferences > Audio > Recording), which it adds to what the driver reports. Only on this computer;\n" ..
        "Put back sets it as it was." .. (math.abs(late) / sr < 0.001 and "\nUnder a millisecond: it's fine as it is, too." or ""))
    end
  end
  if f and off == tonumber(f.to) then
    if ImGui.Button(ctx, string.format("Put back (%d)##latback", tonumber(f.from) or 0)) then local ok, why = cal.put_back(); said = not ok and why or nil end
    ImGui.SetItemTooltip(ctx, "Sets REAPER's input offset back to what it was before StudioSync corrected it.")
  end
end

return cal
