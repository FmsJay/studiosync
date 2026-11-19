-- StudioSync AI: mix feedback with no AI at all. The numbers come from renders of the master and each shared track: loudness, RMS and
-- peaks from REAPER (CalculateNormalization over the whole file), stereo phase and spectrum balance from samples read here. Then fixed
-- rules turn them into notes. The rules and thresholds are the reaper-mcp-server analyzer's (audio_analyzer.py, MIT, David Schuler):
-- peaks above -0.3 dBFS, louder than -8 LUFS for streaming (-14 is where streaming plays), phase coherence under 0.5, crest factor under
-- 6 dB, 200-500 Hz more than 10 dB over 500-2000 Hz, DC offset over 0.001. Mixing judgements, not arbitrary constants: keep their meaning.
-- Pure Lua 5.4 apart from the file it reads, so the tests run it.
local mix = {}

mix.T = { peak_db = -0.3, loud_lufs = -8, stream_lufs = -14, coherence = 0.5, narrow = 0.1, crest_db = 6, tilt_db = 10, dc = 0.001 }
mix.BANDS = { low = { 20, 200 }, mid = { 200, 2000 }, high = { 2000, 20000 }, mud = { 200, 500 }, upper = { 500, 2000 } }

-- CalculateNormalization's answer (the gain that would reach a target of 0) as the level it measured, in dB. nil for no answer.
function mix.gain_db(g) return (g and g > 0) and -20 * math.log(g, 10) or nil end

-- ---------------------------------------------------------------- reading a WAV
-- `blocks` stretches of `len` frames spread evenly through a WAV (PCM 16/24/32-bit or float 32/64, plain or WAVE_FORMAT_EXTENSIBLE).
-- -> { sr, channels, frames, l = {...}, r = {...} } with samples as -1..1 (r = l for mono), or nil + why.
-- shortcut: RF64 (over 4 GB) isn't read; a 4-minute stereo 24-bit stem is about 70 MB, so this matters only for hours-long renders.
local DECODE = { [1] = { [16] = { "<i2", 32768 }, [24] = { "<i3", 8388608 }, [32] = { "<i4", 2147483648 } }, [3] = { [32] = { "<f", 1 }, [64] = { "<d", 1 } } }
function mix.read_wav(path, blocks, len)
  local f = io.open(path, "rb")
  if not f then return nil, "can't open " .. tostring(path) end
  local head = f:read(12)
  if not head or #head < 12 or head:sub(1, 4) ~= "RIFF" or head:sub(9, 12) ~= "WAVE" then f:close(); return nil, "not a WAV file" end
  local fmt, data_at, data_len
  while true do
    local ch = f:read(8)
    if not ch or #ch < 8 then break end
    local id, n = ch:sub(1, 4), string.unpack("<I4", ch, 5)
    if id == "fmt " then
      local b = f:read(n)
      if not b or #b < 16 then break end
      fmt = { tag = string.unpack("<I2", b, 1), channels = string.unpack("<I2", b, 3), sr = string.unpack("<I4", b, 5),
        align = string.unpack("<I2", b, 13), bits = string.unpack("<I2", b, 15) }
      if fmt.tag == 0xFFFE and #b >= 26 then fmt.tag = string.unpack("<I2", b, 25) end -- (the sub-format's first two bytes)
      if n % 2 == 1 then f:seek("cur", 1) end
    elseif id == "data" then
      data_at, data_len = f:seek(), n
      break
    else
      f:seek("cur", n + n % 2)
    end
  end
  local dec = fmt and DECODE[fmt.tag] and DECODE[fmt.tag][fmt.bits]
  if not (dec and data_at and fmt.channels >= 1 and fmt.align > 0) then f:close(); return nil, "a WAV format this doesn't read" end
  local frames = data_len // fmt.align
  local w = { sr = fmt.sr, channels = fmt.channels, frames = frames, l = {}, r = {} }
  len = math.min(len, frames)
  if len < 1 then f:close(); return w end
  blocks = math.max(1, math.min(blocks, frames // len))
  local step, size, code, scale = (frames - len) / math.max(1, blocks - 1), fmt.bits // 8, dec[1], dec[2]
  local l, r = w.l, w.r
  for b = 0, blocks - 1 do
    f:seek("set", data_at + math.floor(b * step) * fmt.align)
    local s = f:read(len * fmt.align) or ""
    for i = 0, #s // fmt.align - 1 do
      local at = i * fmt.align + 1
      local a = string.unpack(code, s, at) / scale
      l[#l + 1] = a
      r[#r + 1] = fmt.channels > 1 and string.unpack(code, s, at + size) / scale or a
    end
  end
  f:close()
  return w
end

-- ---------------------------------------------------------------- analysis
-- In-place radix-2 FFT of re/im (1-based, length a power of 2).
function mix.fft(re, im)
  local n = #re
  local j = 0 -- (bit-reversed order, counted from 0)
  for i = 0, n - 2 do
    if i < j then re[i + 1], re[j + 1] = re[j + 1], re[i + 1]; im[i + 1], im[j + 1] = im[j + 1], im[i + 1] end
    local m = n // 2
    while m >= 1 and j >= m do j = j - m; m = m // 2 end
    j = j + m
  end
  local size = 2
  while size <= n do
    local half, ang = size // 2, -2 * math.pi / size
    for k = 0, half - 1 do
      local wr, wi = math.cos(ang * k), math.sin(ang * k)
      for s = k + 1, n, size do
        local t = s + half
        local xr, xi = re[t] * wr - im[t] * wi, re[t] * wi + im[t] * wr
        re[t], im[t] = re[s] - xr, im[s] - xi
        re[s], im[s] = re[s] + xr, im[s] + xi
      end
    end
    size = size * 2
  end
end

-- Stereo and spectrum figures from what read_wav sampled (`len`: the block length it was read with, a power of 2).
-- -> { stereo, phase_coherence, stereo_width, dc_offset, low, mid, high (shares of power), low_mid_tilt_db }
function mix.analyze(w, len)
  local l, r, n = w.l, w.r, #w.l
  local out = { stereo = w.channels > 1, phase_coherence = 1.0, stereo_width = 0.0, dc_offset = 0.0 }
  if n == 0 then return out end
  local sl, sr_, sll, srr, slr = 0, 0, 0, 0, 0
  for i = 1, n do
    local a, b = l[i], r[i]
    sl, sr_, sll, srr, slr = sl + a, sr_ + b, sll + a * a, srr + b * b, slr + a * b
  end
  out.dc_offset = (sl + sr_) / (2 * n)
  local vl, vr = sll - sl * sl / n, srr - sr_ * sr_ / n
  if out.stereo and vl > 1e-12 and vr > 1e-12 then -- (a silent or DC channel: correlation undefined, read as fully correlated)
    out.phase_coherence = (slr - sl * sr_ / n) / math.sqrt(vl * vr)
  end
  out.stereo_width = out.stereo and 1 - math.abs(out.phase_coherence) or 0.0
  -- spectrum: each block windowed (Hann) and transformed; power per band as a share of all of it
  local power, total = { low = 0, mid = 0, high = 0, mud = 0, upper = 0 }, 0
  local hann = {}
  for i = 1, len do hann[i] = 0.5 - 0.5 * math.cos(2 * math.pi * (i - 1) / (len - 1)) end
  for start = 1, n - len + 1, len do
    local re, im = {}, {}
    for i = 1, len do re[i] = (l[start + i - 1] + r[start + i - 1]) * 0.5 * hann[i]; im[i] = 0 end
    mix.fft(re, im)
    for k = 1, len // 2 do
      local hz, p = (k - 1) * w.sr / len, re[k] * re[k] + im[k] * im[k]
      total = total + p
      for name, edge in pairs(mix.BANDS) do
        if hz >= edge[1] and hz < edge[2] then power[name] = power[name] + p end
      end
    end
  end
  for _, name in ipairs({ "low", "mid", "high" }) do out[name] = total > 0 and power[name] / total or 0 end
  out.low_mid_tilt_db = (power.mud > 0 and power.upper > 0) and 10 * math.log(power.mud / power.upper, 10) or 0
  return out
end

-- ---------------------------------------------------------------- notes
local function f1(x) return string.format("%.1f", x) end

-- The rule-based notes for one stats summary ({ master = {...}, tracks = {{...}} }, each with name, lufs_i, peak_db, true_peak_db,
-- rms_db, crest_db, stereo, phase_coherence, stereo_width, low_mid_tilt_db, dc_offset; any may be missing). -> a list of strings,
-- the master's first. Figures not measured say nothing.
function mix.notes(stats)
  local T, out, info = mix.T, {}, 0 -- (info: lines that only report, the master's loudness against -14)
  local function one(s, is_master)
    local who = s.name or (is_master and "Master" or "a track")
    local peak = s.true_peak_db or s.peak_db
    if peak and peak > T.peak_db then
      out[#out + 1] = who .. ": peaks at " .. f1(peak) .. " dBFS" .. (s.true_peak_db and " (true peak)" or "") ..
        (is_master and ", above -0.3: it may clip once it's encoded. Turn the master down or limit to -1 dBTP." or ": hot going into the master, little headroom.")
    end
    if is_master and s.lufs_i then
      if s.lufs_i > T.loud_lufs then
        out[#out + 1] = who .. ": " .. f1(s.lufs_i) .. " LUFS is very loud for streaming. Services play at about -14 LUFS, so they turn it down by " ..
          f1(s.lufs_i - T.stream_lufs) .. " dB: the extra loudness only costs dynamics."
      else
        local d = s.lufs_i - T.stream_lufs
        info = info + 1
        out[#out + 1] = who .. ": " .. f1(s.lufs_i) .. " LUFS integrated, " .. f1(math.abs(d)) .. " dB " .. (d >= 0 and "above" or "below") ..
          " where streaming plays (-14 LUFS)."
      end
    end
    if s.crest_db and s.crest_db > 0 and s.crest_db < T.crest_db then
      out[#out + 1] = who .. ": crest factor " .. f1(s.crest_db) .. " dB (peak to RMS): it may be over-compressed or limited."
    end
    if s.stereo and s.phase_coherence and s.phase_coherence < T.coherence then
      out[#out + 1] = who .. ": phase coherence " .. string.format("%.2f", s.phase_coherence) ..
        ", under 0.5: parts may cancel when played in mono (phones, club PAs). Check its stereo wideners and mic polarity."
    end
    if is_master and s.stereo and s.stereo_width and s.stereo_width < T.narrow then
      out[#out + 1] = who .. ": stereo width " .. string.format("%.2f", s.stereo_width) .. ", mostly mono. Panning could open it up."
    end
    if s.low_mid_tilt_db and s.low_mid_tilt_db > T.tilt_db then
      out[#out + 1] = who .. ": 200-500 Hz is " .. f1(s.low_mid_tilt_db) .. " dB above 500-2000 Hz: it may sound boxy or muddy."
    end
    if s.dc_offset and math.abs(s.dc_offset) > T.dc then
      out[#out + 1] = who .. ": DC offset " .. string.format("%+.4f", s.dc_offset) .. ". A high-pass filter (or REAPER's DC removal) takes it out."
    end
  end
  if stats.master then one(stats.master, true) end
  for _, t in ipairs(stats.tracks or {}) do one(t, false) end
  if #out == info then
    out[#out + 1] = "Nothing else stands out against the usual checks (peaks, loudness, crest factor, phase, low mids, DC)."
  end
  return out
end

-- The notes as one block of text, for the message box and feedback.md.
function mix.notes_text(stats)
  local lines = {}
  for _, n in ipairs(mix.notes(stats)) do lines[#lines + 1] = "- " .. n end
  return table.concat(lines, "\n")
end

return mix
