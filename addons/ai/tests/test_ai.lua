-- StudioSync AI (addons/ai): the consent text, the rule-based mix notes (from fixtures/mixstats.json), reading and measuring WAVs, and
-- turning helper results (fixtures/results/*.json, made by the helper's dry runs) into project steps. Run from the worktree root by
-- tests/run.py (lupa, Lua 5.4); its last line is "ok".
package.path = "addons/ai/lib/?.lua;lib/?.lua;" .. package.path
local json = require("json")
local jobs, mix, imp = require("ai_jobs"), require("ai_mix"), require("ai_import")

local function read(path)
  local f = assert(io.open(path, "rb"), "missing " .. path)
  local s = f:read("a")
  f:close()
  return s
end
local function near(a, b, tol, what) assert(math.abs(a - b) <= tol, what .. ": " .. tostring(a) .. " vs " .. tostring(b)) end

-- every Lua file of the add-on compiles (tools/compile_check.py doesn't look in addons/)
for _, f in ipairs({ "addons/ai/studiosync_ai.lua", "addons/ai/lib/ai_jobs.lua", "addons/ai/lib/ai_mix.lua", "addons/ai/lib/ai_import.lua", "addons/ai/lib/ai_run.lua" }) do
  assert(load(read(f), "@" .. f), "doesn't compile: " .. f)
end

-- ---------------------------------------------------------------- consent text
local stems = jobs.BY_ID.stems
local t = jobs.consent_text(stems, { missing = { "audio-separator" } })
assert(t:find("htdemucs_ft", 1, true) and t:find("graphics card", 1, true) and t:find("4-8 GB", 1, true), "names the model, the GPU and its memory: " .. t)
assert(t:find("downloads and installs: audio-separator", 1, true), "says what it downloads")
assert(t:find("Go ahead?", 1, true), "ends in the question")
assert(not jobs.consent_text(stems, {}):find("downloads", 1, true), "nothing to install: no download line")
t = jobs.consent_text(stems, { where = "cloud", service = "LALAL.AI" })
assert(t:find("LALAL.AI, in the cloud", 1, true) and t:find("audio leaves this computer", 1, true), "a cloud run says the audio leaves: " .. t)
t = jobs.consent_text(jobs.FEEDBACK, { endpoint = "claude", model = "claude-opus-5-5" })
assert(t:find("no audio", 1, true) and t:find("in the cloud", 1, true) and t:find("claude-opus-5-5", 1, true), "Claude: numbers only, cloud: " .. t)
t = jobs.consent_text(jobs.FEEDBACK, { endpoint = "hub", model = "qwen-auto", hub_url = "http://127.0.0.1:4000" })
assert(t:find("local GPU model", 1, true) and t:find("qwen-auto", 1, true) and t:find("no audio", 1, true), "hub: says it uses the GPU: " .. t)
assert(jobs.feedback_where("hub") == "gpu" and jobs.feedback_where("claude") == "cloud" and jobs.feedback_where("none") == "none", "feedback's where")
for _, j in ipairs(jobs.LIST) do
  assert(j.model and j.time and j.vram and j.licence and j.timeout and (j.where == "gpu" or j.where == "cpu"), "complete row: " .. j.id)
end

-- ---------------------------------------------------------------- rule-based notes
local stats = json.decode(read("addons/ai/tests/fixtures/mixstats.json"))
local notes = mix.notes(stats)
local all = table.concat(notes, "\n")
local function has(s) assert(all:find(s, 1, true), "a note says '" .. s .. "':\n" .. all) end
has("Master: peaks at 0.6 dBFS (true peak)")
has("Master: -7.2 LUFS is very loud for streaming")
has("turn it down by 6.8 dB")
has("Bass: crest factor 4.5 dB")
has("Bass: 200-500 Hz is 12.3 dB above")
has("Guitars: phase coherence 0.31")
has("Vox: peaks at -0.1 dBFS (true peak): hot")
has("Vox: DC offset +0.0021")
assert(#notes == 7, "7 notes, got " .. #notes .. ":\n" .. all)
assert(not all:find("Keys", 1, true), "a clean track gets no note")
assert(not all:find("Bass: phase", 1, true), "a mono track has no phase note")
assert(notes[1]:find("^Master"), "the master first")
local clean = { master = { name = "Master", lufs_i = -14.5, peak_db = -1.2, crest_db = 9, stereo = true, phase_coherence = 0.8, stereo_width = 0.2 } }
local cn = mix.notes(clean)
assert(#cn == 2 and cn[1]:find("0.5 dB below where streaming plays", 1, true) and cn[2]:find("Nothing else stands out", 1, true), table.concat(cn, " | "))
assert(#mix.notes({ tracks = {} }) == 1, "no numbers: one line, nothing invented")
assert(mix.notes_text(stats):find("^%- Master"), "as a list")
near(mix.gain_db(0.5), 6.0206, 1e-3, "a gain of 0.5 is 6 dB under the target")
assert(mix.gain_db(0) == nil and mix.gain_db(nil) == nil, "no gain, no level")

-- ---------------------------------------------------------------- FFT
local re, im = { 1, 0, 0, 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0, 0, 0, 0 }
mix.fft(re, im)
for i = 1, 8 do near(re[i], 1, 1e-9, "an impulse is flat"); near(im[i], 0, 1e-9, "and real") end
re, im = {}, {}
for i = 1, 16 do re[i] = math.cos(2 * math.pi * 3 * (i - 1) / 16); im[i] = 0 end
mix.fft(re, im)
near(math.sqrt(re[4] ^ 2 + im[4] ^ 2), 8, 1e-9, "a cosine at bin 3 lands in bin 3")
near(math.sqrt(re[3] ^ 2 + im[3] ^ 2), 0, 1e-9, "and nowhere else")

-- ---------------------------------------------------------------- WAVs
local tmp = (os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"):gsub("\\", "/") .. "/ssai-test-" .. os.time() .. "-" .. math.random(1e6) .. ".wav"
-- A stereo WAV: fn(i) -> l, r. tag 1 (PCM) or 3 (float); bits; extensible: a WAVE_FORMAT_EXTENSIBLE header, with a LIST chunk before data.
local function write_wav(path, sr, frames, bits, tag, fn, extensible)
  local code = tag == 3 and "<f" or ({ [16] = "<i2", [24] = "<i3" })[bits]
  local scale = tag == 3 and 1 or (bits == 16 and 32767 or 8388607)
  local data = {}
  for i = 0, frames - 1 do
    local l, r = fn(i)
    data[#data + 1] = string.pack(code, tag == 3 and l or math.floor(l * scale)) .. string.pack(code, tag == 3 and r or math.floor(r * scale))
  end
  local body = table.concat(data)
  local align = 2 * bits // 8
  local fmt = string.pack("<I2I2I4I4I2I2", extensible and 0xFFFE or tag, 2, sr, sr * align, align, bits)
  if extensible then fmt = fmt .. string.pack("<I2I2I4", 22, bits, 3) .. string.pack("<I2", tag) .. string.rep("\0", 14) end
  local extra = extensible and ("LIST" .. string.pack("<I4", 5) .. "abcde\0") or "" -- (odd length: padded)
  local chunks = "fmt " .. string.pack("<I4", #fmt) .. fmt .. extra .. "data" .. string.pack("<I4", #body) .. body
  local f = assert(io.open(path, "wb"))
  f:write("RIFF" .. string.pack("<I4", 4 + #chunks) .. "WAVE" .. chunks)
  f:close()
end
local SR, LEN = 8000, 256
-- 100 Hz, right channel the left upside down (and quieter, so the mono sum the spectrum reads isn't silence): all low end, out of phase
write_wav(tmp, SR, 8000, 24, 1, function(i) local s = 0.5 * math.sin(2 * math.pi * 100 * i / SR); return s, -0.5 * s end)
local w = assert(mix.read_wav(tmp, 16, LEN))
assert(w.sr == SR and w.channels == 2 and w.frames == 8000 and #w.l == 16 * LEN, "read 16 blocks of 256 frames: " .. #w.l)
near(w.l[1], 0, 1e-6, "24-bit sample 0")
local a = mix.analyze(w, LEN)
near(a.phase_coherence, -1, 1e-3, "inverted right channel: coherence -1")
near(a.stereo_width, 0, 1e-3, "width 1 - |coherence|")
assert(a.low > 0.95, "a 100 Hz tone is low end: " .. a.low)
near(a.dc_offset, 0, 1e-3, "no DC")
-- 1 kHz, the same in both, 16-bit, extensible header with a chunk before data
write_wav(tmp, SR, 4000, 16, 1, function(i) local s = 0.3 * math.sin(2 * math.pi * 1000 * i / SR) + 0.01; return s, s end, true)
w = assert(mix.read_wav(tmp, 8, LEN))
a = mix.analyze(w, LEN)
near(a.phase_coherence, 1, 1e-6, "identical channels: coherence 1")
assert(a.mid > 0.95, "1 kHz is mid: " .. a.mid)
near(a.dc_offset, 0.01, 1e-3, "the DC it was given")
assert(a.low_mid_tilt_db < -10, "all upper mids, no mud: " .. a.low_mid_tilt_db)
-- float, 5 kHz
write_wav(tmp, 16000, 4000, 32, 3, function(i) local s = 0.25 * math.sin(2 * math.pi * 5000 * i / 16000); return s, 0.5 * s end)
w = assert(mix.read_wav(tmp, 4, LEN))
near(w.l[2], 0.25 * math.sin(2 * math.pi * 5000 / 16000), 1e-6, "float sample read as is")
assert(mix.analyze(w, LEN).high > 0.95, "5 kHz is high")
os.remove(tmp)
assert(mix.read_wav(tmp, 4, LEN) == nil, "no file: nil")
local f = assert(io.open(tmp, "wb")); f:write("not a wav at all"); f:close()
local none, why = mix.read_wav(tmp, 4, LEN)
assert(none == nil and why == "not a WAV file", "not a WAV: says so")
os.remove(tmp)

-- ---------------------------------------------------------------- results into steps
local function fixture(job) return json.decode(read("addons/ai/tests/fixtures/results/" .. job .. ".json")) end
local steps = assert(imp.plan(fixture("stems"), 12.5))
assert(#steps == 4 and steps[1].op == "track" and steps[1].name == "Vocals (AI)" and steps[1].file == "vocals.wav" and steps[1].pos == 12.5, "stems: a track each, from the start")
assert(imp.describe(steps) == "4 new tracks", imp.describe(steps))
steps = assert(imp.plan(fixture("master"), 0))
assert(#steps == 1 and steps[1].name == "Master (matched) (AI)", "master: one track")
steps = assert(imp.plan(fixture("sections"), 10))
assert(steps[1].op == "region" and steps[1].pos == 10 and steps[1].stop == 18 and steps[1].name == "intro", "sections: regions, moved to the start")
for _, s in ipairs(steps) do assert(s.op ~= "tempo", "no tempo map unless asked") end
steps = assert(imp.plan(fixture("sections"), 10, { tempo = true }))
local tempos = {}
for _, s in ipairs(steps) do if s.op == "tempo" then tempos[#tempos + 1] = s end end
assert(#tempos == 8 and tempos[1].pos == 10 and math.abs(tempos[1].bpm - 120) < 1e-9, "a tempo marker per bar at 120: " .. #tempos)
assert(imp.describe(steps) == "3 regions, 8 tempo markers", imp.describe(steps))
steps = assert(imp.plan(fixture("transcribe"), 60))
assert(#steps == 1 and steps[1].op == "notes" and steps[1].text:find("[1:00] Speaker 1: (dry run) Let's take it", 1, true), "transcript into the notes, timed: " .. tostring(steps[1].text))
steps = assert(imp.plan(fixture("transcribe"), 0, { regions = true }))
assert(#steps == 3 and steps[2].op == "region" and steps[2].name:find("^Speaker 1: "), "and as regions when asked")
steps = assert(imp.plan(fixture("chords"), 0))
assert(steps[1].op == "notes" and steps[1].text == "Key (StudioSync AI): A minor" and steps[2].op == "marker" and steps[2].name == "Am", "chords: key note, chord markers")
steps = assert(imp.plan(fixture("midi"), 3))
assert(#steps == 1 and steps[1].op == "midi" and steps[1].file == "in.mid" and steps[1].name == "in (AI MIDI)", "midi: a track each")
-- what comes from outside is checked
local bad = { job = "stems", status = "ok", data = { stems = { { name = "Up", file = "../../evil.wav" }, { name = "Abs", file = "C:/x.wav" },
  { name = "Hidden", file = ".x.wav" }, { name = "ok", file = "fine.wav" } } } }
steps = assert(imp.plan(bad, 0))
assert(#steps == 1 and steps[1].file == "fine.wav", "only plain file names in the run folder")
steps = assert(imp.plan({ job = "sections", status = "ok", data = { segments = { { start = -1, ["end"] = 2 }, { start = 5, ["end"] = 3 }, { start = "x" }, { start = 1, ["end"] = 2, label = "a|b" } } } }, 0))
assert(#steps == 1 and steps[1].name == "a b", "bad times dropped, names cleaned")
local none2, why2 = imp.plan({ job = "stems", status = "error", message = "out of memory" }, 0)
assert(none2 == nil and why2 == "out of memory", "a failed run says why")
assert(select(2, imp.plan({ job = "stems", status = "ok", data = {} }, 0)) == "the result had nothing to put in the project", "empty result")
assert(select(2, imp.plan({ job = "feedback", status = "ok", data = {} }, 0)):find("nothing to put", 1, true), "feedback isn't imported")
assert(imp.plan(nil, 0) == nil, "no result")

print("ok")
