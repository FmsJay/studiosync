-- AI as an optional add-on, the web UI's side (lib/ai.lua; docs/rt/rt-ai.md). No model, local or cloud, is ever run here: every program is a
-- stand-in that the test plays itself, writing the files the real one would (pid.txt, exit.txt, its outputs). Covers: the pure rules
-- (addresses, local or sent away, provider choice, the yes rule, command lines and job scripts, a chat reply, error lines); the yes gate (the
-- studio's switch, nothing runs on an ask, a phone's yes refused unless this computer allows it, run-out and unknown ids, settings changed since
-- the ask, no, too many asks, the panel's yes); each job's life (started in the background, done, failed, failed to start, past its time,
-- cancelled before and after its pid); every result path (stems into the stems folder and new tracks, words onto the Sheet, MIDI as a track,
-- a chat answer as a chat message) and the page's topic. Lupa, repo root.
package.path = "lib/?.lua;" .. package.path
local SEP = package.config:sub(1, 1)
local T = (os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"):gsub("\\", "/") .. "/ss_ai_" .. os.time() .. "_" .. math.random(100000, 999999)
local function clean() os.execute(SEP == "\\" and ('rmdir /s /q "' .. T:gsub("/", "\\") .. '" 2>nul') or ("rm -rf '" .. T .. "'")) end
local pyos = python.eval("__import__('os')")
local listdir = python.eval("lambda os, d, files: '/'.join(sorted(n for n in os.listdir(d) if os.path.isfile(os.path.join(d, n)) == files)) if os.path.isdir(d) else ''")
local function list(d, files) local out = {}; for n in tostring(listdir(pyos, d, files)):gmatch("[^/]+") do out[#out + 1] = n end; return out end
local function mkdirs(d) python.eval("lambda os, d: os.makedirs(d, exist_ok=True)")(pyos, d) end
local function write(p, s) mkdirs(p:match("^(.*)/[^/]+$")); local f = assert(io.open(p, "wb")); f:write(s); f:close() end
local function read(p) local f = io.open(p, "rb"); if not f then return nil end; local s = f:read("a"); f:close(); return s end
local function exists(p) local f = io.open(p, "rb"); if f then f:close() end; return f ~= nil end

-- ---- a stand-in REAPER with one project: two audio takes and a MIDI one ------------------------------------------------------------------
local clock, ext, guid = 1000, {}, 0
local proj = "P1"
local tracks = {
  { name = "Vox", items = { { g = "{V1}", take = { name = "Vox take 3", file = T .. "/proj/media/vox3.wav", offs = 1.5 }, pos = 32, len = 20 } } },
  { name = "Keys", items = { { g = "{K1}", take = { name = "Keys", midi = true }, pos = 0, len = 8 }, { g = "{K2}", take = { name = "", file = T .. "/proj/media/keys.flac", offs = 0 }, pos = 4, len = 10 } } },
}
local added = {} -- tracks the code put in: { name, items = { { pos, len, offs, src, name } } }
local undo = {}
reaper = setmetatable({
  GetOS = function() return "Win64" end,
  time_precise = function() return clock end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  genGuid = function() guid = guid + 1; return string.format("{%08X-%04X-2222-3333-%012X}", math.random(0, 0x7fffffff), guid % 65536, guid * 7919) end,
  GetResourcePath = function() return T .. "/res" end,
  EnumerateFiles = function(d, i) if i < 0 then return nil end; return list(d, true)[i + 1] end,
  EnumerateSubdirectories = function(d, i) if i < 0 then return nil end; return list(d, false)[i + 1] end,
  RecursiveCreateDirectory = function(d) mkdirs(d); return 1 end,
  file_exists = function(p) return exists(p) end,
  ValidatePtr = function(p, kind) return p == proj and kind == "ReaProject*" end,
  CountTracks = function() return #tracks + #added end,
  GetTrack = function(_, i) return i < #tracks and tracks[i + 1] or added[i - #tracks + 1] end,
  GetTrackName = function(tr) return true, tr.name end,
  CountTrackMediaItems = function(tr) return #(tr.items or {}) end,
  GetTrackMediaItem = function(tr, i) return tr.items[i + 1] end,
  GetActiveTake = function(it) return it.take end,
  TakeIsMIDI = function(tk) return tk.midi == true end,
  GetSetMediaItemInfo_String = function(it, k) assert(k == "GUID"); return true, it.g end,
  GetSetMediaItemTakeInfo_String = function(tk, k, v, set) if set then tk.name = v end; return true, tk.name end,
  GetMediaItemInfo_Value = function(it, k) return k == "D_POSITION" and it.pos or k == "D_LENGTH" and it.len or 0 end,
  GetMediaItemTakeInfo_Value = function(tk, k) return k == "D_STARTOFFS" and (tk.offs or 0) or 0 end,
  GetMediaItemTake_Source = function(tk) return tk.src or (tk.file and { file = tk.file }) end,
  GetMediaSourceFileName = function(src) return src.file or "" end,
  PCM_Source_CreateFromFile = function(p) return exists(p) and { file = p } or nil end,
  PCM_Source_Destroy = function() end,
  CalculateNormalization = function(_, mode) return ({ [0] = 10 ^ (9 / 20), [1] = 10 ^ (12 / 20), [2] = 10 ^ (0.1 / 20), [3] = 10 ^ (-0.2 / 20) })[mode] end,
  GetMediaSourceLength = function() return 99 end,
  InsertTrackInProject = function(_, idx) added[idx - #tracks + 1] = { name = "", items = {} } end,
  GetSetMediaTrackInfo_String = function(tr, k, v) if k == "P_NAME" then tr.name = v end; return true, tr.name end,
  AddMediaItemToTrack = function(tr) local it = { pos = 0, len = 0 }; tr.items[#tr.items + 1] = it; return it end,
  AddTakeToMediaItem = function(it) it.take = { name = "" }; return it.take end,
  SetMediaItemTake_Source = function(tk, src) tk.src = src end,
  SetMediaItemTakeInfo_Value = function(tk, k, v) if k == "D_STARTOFFS" then tk.offs = v end end,
  SetMediaItemInfo_Value = function(it, k, v) if k == "D_POSITION" then it.pos = v elseif k == "D_LENGTH" then it.len = v end end,
  Undo_BeginBlock2 = function() undo[#undo + 1] = "begin" end,
  Undo_EndBlock2 = function(_, name) undo[#undo + 1] = name end,
  TimeMap2_timeToBeats = function(_, t) return 0, math.floor(t / 2) end, -- (120 BPM 4/4: a bar every 2 s, 0-based)
  EnumProjectMarkers3 = function() return 0 end, -- (no markers: the stand-in recap.section_at answers by position)
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() return "" end end end })

local band = require("band")
local logs = {}
band.log = function(s) logs[#logs + 1] = s end
local studio = { on = false, may = true }
package.loaded.groups = { ai = function() return studio.on end, may_manage = function() return studio.may end }
local hidden = {} -- what the background runner was handed
package.loaded.services = { run_hidden = function(name, cmd) hidden[#hidden + 1] = { name = name, cmd = cmd } end }
package.loaded.listen = { AUDIO = { wav = true, flac = true, mp3 = true } }
local sheet_sets, posts = {}, {}
package.loaded.songsheet = { action = function(p, cfg, b, a) sheet_sets[#sheet_sets + 1] = { proj = p, user = cfg.user, song = b.song, set = a.set } end }
package.loaded.page_chat = { post = function(cfg, b, text, sc) posts[#posts + 1] = { user = cfg.user, song = b.song, text = text, sc = sc } end }
local last_recap = nil
package.loaded.recap = { last = function() return last_recap end, lines = function(r) return r.lines end,
  section_at = function(_, pos) return pos >= 30 and "Chorus" or "Verse" end }
local ai = require("ai")
-- (the tab offers only stems and audio to MIDI (ai.SHOWN, rt-ui4); the hidden tools' code is kept, so it's tested with all shown, then section 6)
local SHOWN = ai.SHOWN
ai.SHOWN = { stems = true, lyrics = true, midi = true, feedback = true, recap = true, names = true }
local cfg, b = { root = T .. "/studio", user = "James" }, { song = "Song", room = "main" }

-- ---- 1. pure rules ----------------------------------------------------------------------------------------------------------------------
assert(ai.url_ok("http://127.0.0.1:4000") and ai.url_ok("https://hub.tail99.ts.net/v1") and ai.url_ok("http://[::1]:8080"), "plain addresses")
for _, bad in ipairs({ "ftp://x", "http://", "http://a b", 'http://x"y', "http://x'y", "javascript:alert(1)", "http://x\n", "x", 5, nil, "http://:80" }) do
  assert(not ai.url_ok(bad), "refused: " .. tostring(bad))
end
assert(ai.is_local("http://127.0.0.1:4000") and ai.is_local("http://localhost:11434/v1") and ai.is_local("http://[::1]:1") and ai.is_local("http://127.5.0.1"), "local")
assert(not ai.is_local("https://james-main.tail99132c.ts.net") and not ai.is_local("http://192.168.1.5:4000") and not ai.is_local("http://localhost.evil.com")
  and not ai.is_local("http://127.0.0.1.nip.io") and not ai.is_local("https://api.example.com"), "anything else is sent away")
assert(not ai.is_local("http://localhost@evil.com/"), "a name before @ is not the host")
assert(ai.redact("http://bob:secret@127.0.0.1:4000/v1?key=abc#x") == "http://127.0.0.1:4000/v1", "no name, password or query: " .. ai.redact("http://bob:secret@127.0.0.1:4000/v1?key=abc#x"))
assert(ai.endpoint("http://127.0.0.1:4000") == "http://127.0.0.1:4000/v1/chat/completions" and ai.endpoint("http://h/v1/") == "http://h/v1/chat/completions"
  and ai.endpoint("http://h/v1/chat/completions") == "http://h/v1/chat/completions", "the chat address")
local F = ai.BY_ID
assert(ai.provider(F.stems, {}) == "none" and select(2, ai.provider(F.stems, {})):find("demucs", 1, true), "a tool not set up: none, and why")
assert(ai.provider(F.stems, { demucs = "C:/d.exe" }) == "tool" and ai.provider(F.lyrics, { whisper = "w.exe" }) == "none"
  and ai.provider(F.lyrics, { whisper = "w.exe", whisper_model = "m.bin" }) == "tool" and ai.provider(F.midi, { basic_pitch = "bp" }) == "tool", "tools")
assert(ai.provider(F.feedback, { url = "http://127.0.0.1:4000" }) == "none" and ai.provider(F.feedback, { model = "m" }) == "none"
  and ai.provider(F.feedback, { url = "http://x y", model = "m" }) == "none" and ai.provider(F.recap, { url = "http://127.0.0.1:4000", model = "m" }) == "chat", "chat")
assert(ai.provider(nil, {}) == "none", "no feature")
assert(ai.yes_ok("panel", {}) and ai.yes_ok("here", {}) and not ai.yes_ok("away", {}) and not ai.yes_ok("away", { phone_yes = false })
  and ai.yes_ok("away", { phone_yes = true }) and not ai.yes_ok(nil, { phone_yes = true }) and not ai.yes_ok("other", { phone_yes = true }), "which yes counts")
local sp = ai.tool_spec(F.stems, { demucs = "C:/demucs.exe" }, "C:/a b/take.wav", "D")
assert(sp.exe == "C:/demucs.exe" and table.concat(sp.args, "|") == "-n|htdemucs|-o|D/out|C:/a b/take.wav", "demucs's command line")
sp = ai.tool_spec(F.lyrics, { whisper = "w", whisper_model = "m.bin" }, "t.wav", "D")
assert(table.concat(sp.args, "|") == "-m|m.bin|-f|t.wav|-otxt|-of|D/lyrics|-np", "whisper-cli's")
assert(table.concat(ai.tool_spec(F.midi, { basic_pitch = "bp" }, "t.wav", "D").args, "|") == "D/out|t.wav", "basic-pitch's")
local cs = ai.chat_spec({ url = "http://127.0.0.1:4000", model = "qwen" }, "D", "sys", "user text", true)
assert(cs.exe == "curl.exe" and cs.request.model == "qwen" and cs.request.messages[2].content == "user text" and cs.request.stream == false, "the request")
assert(table.concat(cs.args, " "):find("@D/request.json -o D/reply.json -w %{http_code} http://127.0.0.1:4000/v1/chat/completions", 1, true), "curl's: " .. table.concat(cs.args, " "))
assert(ai.chat_spec({ url = "http://h", model = "m" }, "D", "s", "u", false).exe == "curl", "curl elsewhere")
local ps = ai.script({ exe = "C:/Program Files/Demucs/demucs.exe", args = { "-o", "C:/it's/out\\", "x" } }, "C:/jobs/it's", true)
assert(ps:find("$d = 'C:/jobs/it''s'", 1, true) and ps:find("-FilePath 'C:/Program Files/Demucs/demucs.exe'", 1, true), "PowerShell quotes: " .. ps)
assert(ps:find([[-ArgumentList '"-o" "C:/it''s/out\\" "x"']], 1, true), "each argument quoted for Windows, a trailing backslash doubled")
assert(ps:find("pid.txt') $p.Id", 1, true) and ps:find("WaitForExit()", 1, true) and ps:find("exit.txt') $p.ExitCode", 1, true) and ps:find("'failed'", 1, true), "pid, wait, exit, failed")
local sh = ai.script({ exe = "/opt/demucs", args = { "it's", "b c" } }, "/j/it's", false)
assert(sh:find("cd '/j/it'\\''s' || exit 1", 1, true) and sh:find("'/opt/demucs' 'it'\\''s' 'b c' > out.txt 2> err.txt &", 1, true)
  and sh:find('echo "$p" > pid.txt', 1, true) and sh:find("echo $? > exit.txt", 1, true), "sh quotes: " .. sh)
assert(ai.job_state(nil, nil) == "starting" and ai.job_state("4242\r\n", nil) == "running" and ai.job_state("failed", nil) == "failed", "states")
local st, code = ai.job_state("4242", "0\r\n")
assert(st == "done" and code == 0 and select(2, ai.job_state("1", "-1")) == -1 and select(2, ai.job_state("1", "137")) == 137, "exit codes")
assert(ai.job_state("1", "") == "running", "an exit file still being written: not done yet")
local ok_reply = '{"choices":[{"message":{"role":"assistant","content":"  Turn the bass down 2 dB.\\r\\nThe peaks are fine.\\u0007 "}}]}'
assert(ai.reply_text("200", ok_reply) == "Turn the bass down 2 dB.\nThe peaks are fine.", "the words, tidied")
local t, why = ai.reply_text("500", '{"error":{"message":"model not loaded"}}')
assert(not t and why:find("HTTP 500", 1, true) and why:find("model not loaded", 1, true), "an error says why: " .. tostring(why))
assert(not ai.reply_text("", nil) and select(2, ai.reply_text("", nil)):find("nothing", 1, true), "no answer at all")
assert(not ai.reply_text("200", "not json") and not ai.reply_text("200", '{"choices":[]}') and not ai.reply_text("200", '{"choices":[{"message":{"content":"  "}}]}'), "no text")
assert(#ai.reply_text("200", '{"choices":[{"message":{"content":"' .. string.rep("a", 9000) .. '"}}]}') <= ai.REPLY_MAX + 3, "kept short")
assert(not ai.reply_text("200", string.rep(" ", ai.READ_MAX + 1)), "a reply file over the limit isn't read")
assert(ai.err_line("warming up\nError: can't reach http://bob:pw@10.0.0.1:4000/v1\n\n") == "Error: can't reach http://10.0.0.1:4000/v1", "the last line, no password")
assert(ai.err_line("") == nil and #ai.err_line(string.rep("x", 500)) == 203, "nothing, or kept short")

-- ---- 2. the yes gate --------------------------------------------------------------------------------------------------------------------
write(T .. "/proj/media/vox3.wav", "RIFF....WAVE")
write(T .. "/proj/media/keys.flac", "fLaC")
write(T .. "/bin/demucs.exe", "stand-in")
local ask, ans
ask, why = ai.ask(proj, cfg, b, { feature = "stems", take = "{V1}" }, clock)
assert(not ask and why:find("off for this studio", 1, true), "the studio's switch is off by default: " .. tostring(why))
studio.on = true
ask, why = ai.ask(proj, cfg, b, { feature = "stems", take = "{V1}" }, clock)
assert(not ask and why:find("demucs isn't set up", 1, true), "not set up here")
ai.set_conf("demucs", T .. "/bin/demucs.exe")
assert(not ai.ask(proj, cfg, b, { feature = "nope" }, clock) and not ai.ask(proj, cfg, b, nil, clock), "not a feature")
ask, why = ai.ask(proj, cfg, b, { feature = "stems", take = "{nope}" }, clock)
assert(not ask and why:find("pick a take", 1, true), "an unknown take")
assert(not ai.ask(proj, cfg, b, { feature = "stems", take = "{K1}" }, clock), "a MIDI take isn't audio")
assert(not ai.ask(proj, cfg, b, { feature = "stems", take = string.rep("x", 100) }, clock), "a silly id")
ask = assert(ai.ask(proj, cfg, b, { feature = "stems", take = "{V1}", tracks = true }, clock))
assert(#hidden == 0, "an ask runs nothing")
assert(ask.here and ask.sends:find("vox3.wav", 1, true) and ask.sends:find("Nothing leaves this computer", 1, true) and ask.sends:find("graphics card", 1, true)
  and ask.result:find("Song/stems/<date> AI Vox take 3", 1, true) and ask.result:find("new tracks", 1, true), "it says what goes where: " .. ask.sends)
assert(#ask.id == 16 and ask.id:match("^%x+$"), "a one-time id")
-- a phone's yes
ans, why = ai.answer(proj, cfg, b, ask.id, true, "away", clock)
assert(not ans and why:find("doesn't count", 1, true) and #hidden == 0, "a phone's yes doesn't count by default")
assert(ai._state().asks[ask.id], "and the ask still waits for a yes here")
local said = ai.action(proj, cfg, b, { yes = ask.id }, false)
assert(said and said:find("doesn't count", 1, true) and #hidden == 0, "through the page's action from a phone too")
assert(ai.action(proj, cfg, b, { yes = "0123456789abcdef" }, true):find("run out", 1, true) and #hidden == 0, "an id nobody asked for")
assert(ai.action(proj, cfg, b, { yes = 5 }, true) and #hidden == 0, "not an id")
-- run out
clock = clock + ai.ASK_FOR + 1
ans, why = ai.answer(proj, cfg, b, ask.id, true, "here", clock)
assert(not ans and why:find("run out", 1, true) and #hidden == 0 and not ai._state().asks[ask.id], "a yes after the ask ran out")
-- settings changed since the ask
ask = assert(ai.ask(proj, cfg, b, { feature = "stems", take = "{V1}" }, clock))
write(T .. "/bin/demucs2.exe", "stand-in")
ai.set_conf("demucs", T .. "/bin/demucs2.exe")
ans, why = ai.answer(proj, cfg, b, ask.id, true, "here", clock)
assert(not ans and why:find("settings changed", 1, true) and #hidden == 0, "the program changed since the ask: nothing runs")
-- the studio turned off meanwhile
ask = assert(ai.ask(proj, cfg, b, { feature = "stems", take = "{V1}" }, clock))
studio.on = false
ans, why = ai.answer(proj, cfg, b, ask.id, true, "here", clock)
assert(not ans and why:find("off for this studio", 1, true) and #hidden == 0, "switched off between the ask and the yes")
studio.on = true
-- no
ask = assert(ai.ask(proj, cfg, b, { feature = "stems", take = "{V1}" }, clock))
assert(ai.action(proj, cfg, b, { no = ask.id }, false):find("not run", 1, true) and not ai._state().asks[ask.id] and #hidden == 0, "no: gone, from anywhere")
-- too many asks
for _ = 1, ai.ASKS_MAX do assert(ai.ask(proj, cfg, b, { feature = "stems", take = "{V1}" }, clock)) end
ask, why = ai.ask(proj, cfg, b, { feature = "stems", take = "{V1}" }, clock)
assert(not ask and why:find("already waiting", 1, true), "no more than ASKS_MAX waiting")
ai.reset()
-- an ask from a phone is fine (it only asks); its yes is refused; this computer's page says yes and it runs
assert(ai.action(proj, cfg, b, { ask = { feature = "stems", take = "{K2}" } }, false) == nil, "a phone may ask")
local id = next(ai._state().asks)
assert(id and #hidden == 0)
assert(ai.action(proj, cfg, b, { yes = id }, false) and #hidden == 0, "but not say yes")
assert(ai.action(proj, cfg, b, { yes = id }, true) == nil and #hidden == 1, "a page on this computer: yes, and it starts")
assert(not ai._state().asks[id], "a yes is used up")
assert(ai.action(proj, cfg, b, { yes = id }, true):find("run out", 1, true) and #hidden == 1, "the same yes again runs nothing")
-- phones allowed on this computer
ai.set_conf("phone_yes", true)
ask = assert(ai.ask(proj, cfg, b, { feature = "stems", take = "{V1}" }, clock))
assert(ai.answer(proj, cfg, b, ask.id, true, "away", clock) and #hidden == 2, "with phones allowed here, a phone's yes counts")
ai.set_conf("phone_yes", false)
-- the panel's yes, through ExtState
ai.reset()
hidden = {}
package.loaded.services.run_hidden = function(name, cmd) hidden[#hidden + 1] = { name = name, cmd = cmd } end
ask = assert(ai.ask(proj, cfg, b, { feature = "stems", take = "{V1}", tracks = true }, clock))
local pubs = {}
local function publish(topic, v) pubs[#pubs + 1] = { topic = topic, v = v } end
ai.tick(proj, cfg, b, publish, clock)
local panel = band.json_decode(ext[band.SECTION .. "/ai asks"])
assert(#panel == 1 and panel[1].id == ask.id and panel[1].sends == ask.sends, "the panel is shown the ask")
assert(#hidden == 0, "showing it runs nothing")
ext[band.SECTION .. "/ai answer"] = ask.id .. " yes"
ai.tick(proj, cfg, b, publish, clock)
assert(#hidden == 1 and ext[band.SECTION .. "/ai answer"] == "", "the panel's yes runs it (and is used up)")
local job = ai._state().jobs[1]
assert(job and job.state == "running" and job.feature == "stems", "a job")

-- ---- 3. a job's life, with the stand-in programs -----------------------------------------------------------------------------------------
local h = hidden[1]
assert(h.name == "ai-" .. job.id and h.cmd:find("^powershell%.exe %-NoProfile %-NonInteractive %-ExecutionPolicy Bypass %-File \"") and h.cmd:find(job.dir .. "/run.ps1", 1, true), "started hidden: " .. h.cmd)
local script = read(job.dir .. "/run.ps1")
assert(script and script:find(T .. "/bin/demucs2.exe", 1, true) and script:find('"' .. T .. '/proj/media/vox3.wav"', 1, true), "its script runs the program set here on the take's file")
assert(job.dir:find(T .. "/res/StudioSync/ai/jobs/", 1, true) == 1, "in this computer's own folder, not the shared one: " .. job.dir)
ai.tick(proj, cfg, b, publish, clock + 1)
assert(job.state == "running", "nothing yet: still running")
write(job.dir .. "/pid.txt", "4242\r\n")
-- the stand-in demucs: four stems where the real one puts them
for _, s in ipairs({ "vocals", "drums", "bass", "other" }) do write(job.dir .. "/out/htdemucs/vox3/" .. s .. ".wav", "RIFF" .. s) end
write(job.dir .. "/exit.txt", "0\r\n")
ai.tick(proj, cfg, b, publish, clock + 2)
assert(job.state == "done" and job.msg:find("4 stems in stems/", 1, true) and job.msg:find("4 new tracks", 1, true), "done: " .. tostring(job.msg))
local dest = band.song_dir(cfg, "Song") .. "/stems"
local folder = list(dest, false)[1]
assert(folder and folder:find(" AI Vox take 3$"), "the stems folder: " .. tostring(folder))
assert(read(dest .. "/" .. folder .. "/vocals.wav") == "RIFFvocals" and #list(dest .. "/" .. folder, true) == 4, "the stems are copied there")
assert(#added == 4 and added[1].name:find("^Vox take 3 %- ") and added[1].items[1].pos == 32 and added[1].items[1].len == 20 and added[1].items[1].take.offs == 1.5
  and added[1].items[1].take.src.file:find(folder, 1, true), "new tracks lined up with the take (same place in the file)")
assert(undo[1] == "begin" and undo[2] == "StudioSync AI: stems of Vox take 3", "one undo step")
local function fresh(feature, req)
  ai.reset(); hidden = {}
  local a = assert(ai.ask(proj, cfg, b, req or { feature = feature, take = "{V1}" }, clock))
  local j = assert(ai.answer(proj, cfg, b, a.id, true, "here", clock))
  return j, a
end
-- failed: a stop with an error code, the reason without a password
job = fresh("stems")
write(job.dir .. "/pid.txt", "77")
write(job.dir .. "/err.txt", "loading\nRuntimeError: CUDA out of memory at http://u:pw@h\n")
write(job.dir .. "/exit.txt", "1")
ai.poll(job, clock + 1)
assert(job.state == "failed" and job.msg:find("code 1", 1, true) and job.msg:find("CUDA out of memory", 1, true) and not job.msg:find("pw", 1, true), "failed: " .. job.msg)
-- didn't start (the program isn't there any more)
job = fresh("stems")
write(job.dir .. "/pid.txt", "failed")
write(job.dir .. "/err.txt", "This command cannot be run due to the error: The system cannot find the file specified.")
ai.poll(job, clock + 1)
assert(job.state == "failed" and job.msg:find("didn't start", 1, true) and job.msg:find("cannot find the file", 1, true), "failed to start: " .. job.msg)
-- past its time
job = fresh("stems")
write(job.dir .. "/pid.txt", "999")
ai.poll(job, clock + ai.TIMEOUT.stems + 1)
assert(job.state == "failed" and job.msg:find("ran past 30 minutes", 1, true), "past its time")
assert(hidden[#hidden].cmd == "taskkill /PID 999 /T /F" and hidden[#hidden].name == "ai-kill-999", "and stopped")
-- cancelled while running
job = fresh("stems")
write(job.dir .. "/pid.txt", "1234")
assert(ai.action(proj, cfg, b, { cancel = job.id }, false):find("cancelled", 1, true) and job.state == "cancelled", "Cancel")
assert(hidden[#hidden].cmd == "taskkill /PID 1234 /T /F", "ends it")
write(job.dir .. "/exit.txt", "1")
ai.poll(job, clock + 1)
assert(job.state == "cancelled", "a cancelled job's exit changes nothing")
assert(ai.cancel(job.id):find("nothing running", 1, true), "cancelling twice")
-- cancelled before its pid was written: stopped once it shows up
job = fresh("stems")
local n0 = #hidden
ai.cancel(job.id)
assert(job.state == "cancelled" and #hidden == n0 and job.kill_pending, "no pid yet: nothing to end")
write(job.dir .. "/pid.txt", "5555")
ai.tick(proj, cfg, b, publish, clock + 1)
assert(hidden[#hidden].cmd == "taskkill /PID 5555 /T /F" and not job.kill_pending, "ended as soon as its pid is there")
-- elsewhere: sh and kill
reaper.GetOS = function() return "OSX64" end
job = fresh("stems")
assert(hidden[1].cmd == "/bin/sh '" .. job.dir .. "/run.sh'" and read(job.dir .. "/run.sh"):find("> out.txt 2> err.txt &", 1, true), "macOS/Linux: /bin/sh")
write(job.dir .. "/pid.txt", "321")
ai.cancel(job.id)
assert(hidden[#hidden].cmd == "pkill -P 321; kill 321", "and kill")
reaper.GetOS = function() return "Win64" end
-- a result that can't be read fails the job, not the tick
job = fresh("stems")
write(job.dir .. "/pid.txt", "1"); write(job.dir .. "/exit.txt", "0")
ai.poll(job, clock + 1)
assert(job.state == "failed" and job.msg == "demucs made no stems", "no stems: " .. tostring(job.msg))
-- finished jobs listed: only the newest KEEP_JOBS
ai.reset()
for i = 1, ai.KEEP_JOBS + 3 do
  local j = { id = "j" .. i, label = "x", state = "running", started = clock, dir = T .. "/none", timeout = 10 }
  ai._state().jobs[i] = j
end
for _, j in ipairs({ table.unpack(ai._state().jobs) }) do ai.cancel(j.id) end
assert(#ai._state().jobs == ai.KEEP_JOBS and ai._state().jobs[1].id == "j4", "the oldest finished ones go")

-- ---- 4. the other results ---------------------------------------------------------------------------------------------------------------
-- lyrics onto the Sheet
write(T .. "/bin/whisper-cli.exe", "stand-in"); write(T .. "/models/ggml-base.en.bin", "stand-in")
ai.set_conf("whisper", T .. "/bin/whisper-cli.exe"); ai.set_conf("whisper_model", T .. "/models/ggml-base.en.bin")
local a
job, a = fresh("lyrics")
assert(a.result:find("Sheet page", 1, true) and a.spec.args[2] == T .. "/models/ggml-base.en.bin", "the words go on the Sheet")
write(job.dir .. "/pid.txt", "1")
write(job.dir .. "/lyrics.txt", " I walked the line\r\n\r\n\r\nand the line walked back\1 \n")
write(job.dir .. "/exit.txt", "0")
ai.poll(job, clock + 1)
assert(job.state == "done" and job.msg:find("Lyrics: Vox take 3 (AI)", 1, true), "lyrics done: " .. tostring(job.msg))
local s1 = sheet_sets[1]
assert(s1 and s1.proj == proj and s1.user == "James" and s1.song == "Song" and s1.set.id == "h:ai" .. job.id:sub(1, 8) and s1.set.id:match("^h:[%w]+$")
  and s1.set.text == "I walked the line\nand the line walked back" and s1.set.name == "Lyrics: Vox take 3 (AI)" and s1.set.bar == 17, "a new hand section, at the take's bar")
job = fresh("lyrics")
write(job.dir .. "/pid.txt", "1"); write(job.dir .. "/lyrics.txt", " \n "); write(job.dir .. "/exit.txt", "0")
ai.poll(job, clock + 1)
assert(job.state == "failed" and job.msg == "no words heard" and #sheet_sets == 1, "no words: nothing on the Sheet")
-- a part to MIDI
write(T .. "/bin/basic-pitch.exe", "stand-in")
ai.set_conf("basic_pitch", T .. "/bin/basic-pitch.exe")
local before = #added
job = fresh("midi", { feature = "midi", take = "{K2}" })
write(job.dir .. "/pid.txt", "1"); write(job.dir .. "/out/keys_basic_pitch.mid", "MThd"); write(job.dir .. "/exit.txt", "0")
ai.poll(job, clock + 1)
assert(job.state == "done" and #added == before + 1 and added[#added].items[1].pos == 4 and added[#added].items[1].len == 10
  and added[#added].items[1].take.src.file:find("keys_basic_pitch.mid", 1, true), "a MIDI track at the take: " .. tostring(job.msg))
assert(added[#added].name == "Keys - keys MIDI", "named for the take (its track's name when the take has none): " .. added[#added].name)
-- stems of the newest mix
before = #added
assert(not ai.ask(proj, cfg, b, { feature = "stems", mix = true }, clock), "no mix yet")
write(band.song_dir(cfg, "Song") .. "/mixes/2026-11-19 2010 Song.wav", "RIFF")
write(band.song_dir(cfg, "Song") .. "/mixes/2026-11-20 0930 Song.flac", "fLaC")
write(band.song_dir(cfg, "Song") .. "/mixes/.syncthing.x.tmp", "")
a = assert(ai.ask(proj, cfg, b, { feature = "stems", mix = true, tracks = false }, clock))
assert(a.spec.args[5]:find("2026%-11%-20 0930 Song%.flac$") and not a.result:find("new tracks", 1, true), "the newest mix; tracks only when asked")

-- mix feedback: only numbers, to the chat model; the answer in the chat
-- (a real 16-bit stereo WAV, so StudioSync AI's own analysis reads it too)
local frames, data = 48000, {}
for i = 0, frames - 1 do local v = math.floor(math.sin(i * 2 * math.pi * 220 / 48000) * 12000); data[#data + 1] = string.pack("<i2<i2", v, v // 2) end
local pcm = table.concat(data)
write(band.song_dir(cfg, "Song") .. "/mixes/2026-11-20 1000 Song.wav", "RIFF" .. string.pack("<I4", 36 + #pcm) .. "WAVEfmt " ..
  string.pack("<I4<I2<I2<I4<I4<I2<I2", 16, 1, 2, 48000, 48000 * 4, 4, 16) .. "data" .. string.pack("<I4", #pcm) .. pcm)
assert(not ai.ask(proj, cfg, b, { feature = "feedback" }, clock), "no chat model set: none")
ai.set_conf("url", "http://user:pw@127.0.0.1:4000"); ai.set_conf("model", "qwen-desktop")
logs = {}
job, a = fresh("feedback")
assert(a.here and a.to:find("qwen-desktop at http://127.0.0.1:4000 (this computer)", 1, true) and not a.to:find("pw", 1, true), "local, and no password shown: " .. a.to)
assert(a.sends:find("no audio", 1, true) and a.sends:find('"lufs_i":-9', 1, true) and a.sends:find("phase_coherence", 1, true) and a.result:find("chat", 1, true), "the numbers it sends: " .. a.sends)
local req = band.json_decode(read(job.dir .. "/request.json"))
assert(req.model == "qwen-desktop" and req.messages[1].content:find("never the audio", 1, true) and req.messages[2].content:find("2026-11-20 1000 Song.wav", 1, true)
  and req.messages[2].content:find('"true_peak_db":0.2', 1, true) and #read(job.dir .. "/request.json") < 4000, "request.json: the numbers only")
assert(req.messages[2].content:find("rule_notes", 1, true), "with the rule-based notes")
local ps1 = read(job.dir .. "/run.ps1")
assert(ps1:find("curl.exe", 1, true) and ps1:find("http://user:pw@127.0.0.1:4000/v1/chat/completions", 1, true), "curl to the endpoint")
for _, l in ipairs(logs) do assert(not l:find("pw", 1, true) and not l:find("lufs", 1, true), "no password or content in the log: " .. l) end
write(job.dir .. "/pid.txt", "1"); write(job.dir .. "/out.txt", "200"); write(job.dir .. "/reply.json", ok_reply); write(job.dir .. "/exit.txt", "0")
ai.poll(job, clock + 1)
assert(job.state == "done" and #posts == 1 and posts[1].sc == "song" and posts[1].song == "Song"
  and posts[1].text == "AI (qwen-desktop, mix feedback; suggestions only): Turn the bass down 2 dB.\nThe peaks are fine.", "the answer as a chat message: " .. tostring(posts[1] and posts[1].text))
job = fresh("feedback")
write(job.dir .. "/pid.txt", "1"); write(job.dir .. "/out.txt", "503"); write(job.dir .. "/reply.json", '{"error":{"message":"busy"}}'); write(job.dir .. "/exit.txt", "0")
ai.poll(job, clock + 1)
assert(job.state == "failed" and job.msg:find("HTTP 503: busy", 1, true) and #posts == 1, "an HTTP error: no message")
job = fresh("feedback")
write(job.dir .. "/pid.txt", "1"); write(job.dir .. "/err.txt", "curl: (7) Failed to connect to 127.0.0.1 port 4000"); write(job.dir .. "/exit.txt", "7")
ai.poll(job, clock + 1)
assert(job.state == "failed" and job.msg:find("Failed to connect", 1, true), "the endpoint not there")
-- sent away
ai.set_conf("url", "https://hub.example.net/v1")
job, a = fresh("feedback")
assert(not a.here and a.to:find("another computer: this text leaves this computer", 1, true), "sent away says so")
-- recaps and take names: only behind the same yes; text only
a, why = ai.ask(proj, cfg, b, { feature = "recap" }, clock)
assert(not a and why:find("no session recap", 1, true), "no recap yet")
last_recap = { lines = { "James and Bo, 40 minutes", "3 takes: Chorus - Bo - take 1, 2, 3" } }
hidden = {}
a = assert(ai.ask(proj, cfg, b, { feature = "recap" }, clock))
assert(#hidden == 0 and a.sends:find("3 takes: Chorus", 1, true), "the recap's lines")
a = assert(ai.ask(proj, cfg, b, { feature = "names" }, clock))
assert(a.sends:find("Vox take 3 @ 0:32 on Vox (Chorus)", 1, true) and a.sends:find("(no name) @ 0:04 on Keys (Verse)", 1, true) and not a.sends:find("Keys @ 0:00", 1, true),
  "the takes, with their sections (audio takes only): " .. a.sends)
assert(#hidden == 0, "still nothing ran")

-- ---- 5. the page's topic ----------------------------------------------------------------------------------------------------------------
ai.reset()
pubs = {}
ai.action(proj, cfg, b, { want = true }, false)
ai.tick(proj, cfg, b, publish, clock)
local m = pubs[#pubs].v
assert(pubs[#pubs].topic == "ai" and m.on and m.may and m.me == "James" and m.takes[1].g == "{V1}" and m.takes[2].g == "{K2}" and m.mix == "2026-11-20 1000 Song.wav", "what the page sees")
local byf = {}
for _, f in ipairs(m.features) do byf[f.id] = f end
assert(byf.stems.provider == "tool" and byf.stems.where == "here" and byf.feedback.where == "away" and byf.recap.provider == "chat", "where each runs")
ai.set_conf("basic_pitch", "")
ai.action(proj, cfg, b, { ask = { feature = "midi", take = "{K2}" } }, false)
ai.tick(proj, cfg, b, publish, clock)
m = pubs[#pubs].v
assert(m.note:find("Basic Pitch isn't set up", 1, true), "a refused ask is said on the page")
for _, f in ipairs(m.features) do if f.id == "midi" then assert(f.provider == "none" and f.why:find("Basic Pitch", 1, true)) end end
ai.action(proj, cfg, b, { ask = { feature = "stems", take = "{V1}" } }, false)
ai.tick(proj, cfg, b, publish, clock)
m = pubs[#pubs].v
assert(#m.asks == 1 and m.asks[1].sends:find("vox3.wav", 1, true) and m.asks[1].left == nil and m.asks[1].at == nil and m.asks[1].here, "the ask, with no countdown in it")
local s_before = band.json_encode(m)
ai.tick(proj, cfg, b, publish, clock + 1)
assert(band.json_encode(pubs[#pubs].v) == s_before, "the topic doesn't change by itself from tick to tick")
-- quiet when there's nothing to do (the webui test's tick, an older extension)
ai.reset()
pubs = {}
ext[band.SECTION .. "/ai answer"] = ""
ai.tick(proj, cfg, b, publish, clock)
ai.tick(proj, cfg, b, publish, clock)
assert(#pubs <= 1, "nothing to do: the tick goes quiet")
pubs = {}
ai.tick(proj, cfg, b, publish, clock)
assert(#pubs == 0, "and stays quiet")

-- ---- 6. only stems and audio to MIDI (findings item 6; docs/rt/ui-web-plan.md 2.7; rt-ui4) ------------------------------------------------
ai.SHOWN = SHOWN
assert(ai.SHOWN.stems and ai.SHOWN.midi and not ai.SHOWN.lyrics and not ai.SHOWN.feedback and not ai.SHOWN.recap and not ai.SHOWN.names, "only stems and midi")
assert(#ai.FEATURES == 6 and ai.BY_ID.lyrics and ai.BY_ID.recap, "the others are hidden, not deleted")
ai.reset()
pubs = {}
ai.action(proj, cfg, b, { want = true }, true)
ai.tick(proj, cfg, b, publish, clock)
m = pubs[#pubs].v
local ids = {}
for _, f in ipairs(m.features) do ids[#ids + 1] = f.id end
assert(table.concat(ids, ",") == "stems,midi", "the topic carries only stems and midi: " .. table.concat(ids, ","))
assert(not band.json_encode(m):find("lyrics", 1, true) and not band.json_encode(m):find("Mix feedback", 1, true), "nothing of the others in the topic")
for _, id in ipairs({ "lyrics", "feedback", "recap", "names" }) do
  local said = ai.action(proj, cfg, b, { ask = { feature = id, take = "{V1}" } }, true)
  assert(said and said:find("isn't offered", 1, true), id .. ": an ask is refused: " .. tostring(said))
end
assert(not next(ai._state().asks), "no ask was made for a hidden tool")
assert(ai.ask(proj, cfg, b, { feature = "stems", take = "{V1}" }, clock), "stems still asks")
assert(ai.BY_ID.midi.label == "Audio to MIDI", "the plan's name")
assert(ai.key_shown("demucs") and ai.key_shown("basic_pitch") and not ai.key_shown("url") and not ai.key_shown("model")
  and not ai.key_shown("whisper") and not ai.key_shown("whisper_model"), "the panel's card: only the shown tools' settings")
ai.SHOWN = { stems = true, recap = true }
assert(ai.key_shown("url") and ai.key_shown("model") and not ai.key_shown("basic_pitch"), "a chat feature shown: its address and model fields")
ai.SHOWN = SHOWN

clean()
print("ok")
