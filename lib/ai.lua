-- AI as an optional add-on, the web UI's side (docs/realtime-roadmap.md "AI as an optional add-on"; docs/rt/rt-ai.md). James's rule: it's
-- optional, and it asks before every use. Nothing here runs a model by itself: it only starts programs the person installed and pointed at.
--
-- Providers, per feature (ai.provider):
--   tool  a command-line program on this computer, found by the path set here: demucs (stems), whisper.cpp's whisper-cli (words),
--         Basic Pitch (a part to MIDI). Audio stays on this computer; the program may use the graphics card.
--   chat  an OpenAI-compatible chat endpoint, set by its address (the workstation's AI hub at http://127.0.0.1:4000, a local server, or one
--         elsewhere): mix feedback, session recaps, take name ideas. Only text goes: numbers and names, never audio. "Local" when the address
--         is this computer (127.x, localhost, ::1), "sent away" otherwise; each ask says which.
--   none  not set up here: the feature says why and can't be asked for.
--
-- The yes (ai.ask, ai.answer): a page (or the panel) asks for a run; that only makes an ask, which shows what goes where and what comes back,
-- with a one-time id that runs out in ASK_FOR seconds. The run starts only on a yes naming that id: from the panel, or a page on this
-- computer (the extension's StudioSync_WebUIPollHere), or from a phone or another device only when this computer allows it (off by default).
-- Every run needs its own yes; a yes runs exactly what was shown, and nothing if this computer's settings changed meanwhile. The studio's
-- switch (band.json "ai", off unless true, owner and admins: groups.set_ai) must be on, at the ask and at the yes.
--
-- Jobs run in the background (lib/services.lua run_hidden) through a small script in the job's folder that records the program's pid and exit
-- code (Windows: PowerShell Start-Process; elsewhere /bin/sh), so REAPER never waits, a job past its time is stopped, and Cancel ends it. Job
-- folders are this computer's own: <StudioSync home>/ai/jobs/<id>. Results come in through the paths StudioSync already has: stems into the
-- project's stems folder (<Project>/stems/<date> AI <name>, as Render stems) and, if asked, new tracks under the take; words onto the Sheet
-- page (lib/songsheet.lua, as a page's edit); MIDI as a new track; a chat model's answer as a message in the project's chat (lib/page_chat.lua),
-- never applied to the project. (James, rt)
local band = require("band")
local ai = {}
ai.ASK_FOR = 120       -- seconds an ask waits for its yes
ai.ASKS_MAX = 5        -- asks waiting at once (a page that asks in a loop gets no more)
ai.WANT_FOR = 30       -- seconds a page's "I'm showing the AI page" lasts (it says so every 10 s)
ai.TAKES_MAX = 300     -- takes a page can pick from
ai.KEEP_JOBS = 10      -- finished jobs the page still lists
ai.REPLY_MAX = 4000    -- characters of a chat model's answer kept
ai.READ_MAX = 2000000  -- bytes of a reply file read at most
ai.SHOW_MAX = 1500     -- characters of what's sent that an ask shows (the rest: "... and N more")
ai.LYRICS_MAX = 20000  -- the Sheet page's own limit (songsheet.TEXT_MAX)
ai.TIMEOUT = { stems = 1800, lyrics = 1800, midi = 900, feedback = 330, recap = 330, names = 330 }

ai.FEATURES = {
  { id = "stems", label = "Split into stems", kind = "tool", tool = "demucs", input = "audio" },
  { id = "lyrics", label = "Lyrics from a vocal take", kind = "tool", tool = "whisper", input = "take" },
  { id = "midi", label = "A part to MIDI", kind = "tool", tool = "basic_pitch", input = "take" },
  { id = "feedback", label = "Mix feedback", kind = "chat", input = "mix" },
  { id = "recap", label = "Session recap", kind = "chat", input = "recap" },
  { id = "names", label = "Take name ideas", kind = "chat", input = "takes" },
}
ai.BY_ID = {}
for _, f in ipairs(ai.FEATURES) do ai.BY_ID[f.id] = f end
ai.TOOLS = { demucs = "demucs", whisper = "whisper.cpp", basic_pitch = "Basic Pitch" }

-- ---- this computer's settings (ExtState, kept): only the panel changes them, never a page ---------------------------------------------
ai.KEYS = { url = "ai url", model = "ai model", demucs = "ai demucs", whisper = "ai whisper", whisper_model = "ai whisper model",
  basic_pitch = "ai basic pitch", phone_yes = "ai phone yes" }
function ai.conf()
  local c = {}
  for k, key in pairs(ai.KEYS) do c[k] = reaper.GetExtState(band.SECTION, key) end
  c.phone_yes = c.phone_yes == "1"
  return c
end
function ai.set_conf(k, v) reaper.SetExtState(band.SECTION, ai.KEYS[k], v == true and "1" or v == false and "" or tostring(v), true) end
function ai.studio_on(root) local ok, on = pcall(function() return require("groups").ai(root) end); return ok and on == true end

-- ---- pure: addresses ---------------------------------------------------------------------------------------------------------------------
-- An http(s) address with a host and nothing a command line could misread (no spaces, quotes or control characters). -> scheme, host, rest
function ai.url_parts(u)
  if type(u) ~= "string" or #u > 500 or u:find("[%s\"'`<>\\%c]") then return nil end
  local scheme, auth, rest = u:match("^(https?)://([^/?#]+)(.*)$")
  if not scheme then return nil end
  local host = auth:gsub("^.*@", "")
  host = host:match("^%[([%x:]+)%]") or host:match("^([^:]+)") or ""
  if host == "" then return nil end
  return scheme, host:lower(), rest, auth
end
function ai.url_ok(u) return ai.url_parts(u) ~= nil end
-- This computer's own address: then what's sent never leaves it.
function ai.is_local(u)
  local _, host = ai.url_parts(u)
  return host ~= nil and (host == "localhost" or host == "::1" or host:match("^127%.%d+%.%d+%.%d+$") ~= nil)
end
-- For the log and the asks: scheme, host and port, never a name and password in the address, or its query.
function ai.redact(u)
  local scheme, _, rest, auth = ai.url_parts(u)
  if not scheme then return "(not a web address)" end
  return scheme .. "://" .. auth:gsub("^.*@", "") .. (rest:gsub("[?#].*$", ""))
end
-- The chat completions address from what was set: the server's address, or one ending in /v1.
function ai.endpoint(u)
  u = u:gsub("/+$", "")
  if u:match("/chat/completions$") then return u end
  if u:match("/v1$") then return u .. "/chat/completions" end
  return u .. "/v1/chat/completions"
end

-- -> "tool", "chat" or "none" (and why) for a feature with this computer's settings c. Pure.
function ai.provider(f, c)
  if not f then return "none", "no such feature" end
  if f.kind == "tool" then
    if (c[f.tool] or "") == "" then return "none", ai.TOOLS[f.tool] .. " isn't set up on this computer (panel: Settings > Studio > AI)" end
    if f.tool == "whisper" and (c.whisper_model or "") == "" then return "none", "whisper.cpp needs its model file (ggml-...bin) set too" end
    return "tool"
  end
  if (c.url or "") == "" or (c.model or "") == "" then return "none", "no chat model is set on this computer (panel: Settings > Studio > AI)" end
  if not ai.url_ok(c.url) then return "none", "the chat model's address isn't a plain http(s) address" end
  return "chat"
end
-- What a run's target is, to tell at the yes whether the settings changed since the ask. Pure.
function ai.target(f, c)
  if f.kind == "tool" then return f.tool .. "\0" .. (c[f.tool] or "") .. "\0" .. (f.tool == "whisper" and c.whisper_model or "") end
  return (c.url or "") .. "\0" .. (c.model or "")
end
-- Which yes counts: the panel's, or a page on this computer; a phone's (or another device's) only when this computer allows it. Pure.
function ai.yes_ok(origin, c) return origin == "panel" or origin == "here" or (origin == "away" and c.phone_yes == true) end

-- ---- pure: what runs ---------------------------------------------------------------------------------------------------------------------
-- A tool's command line: { exe, args }, writing into dir.
function ai.tool_spec(f, c, input, dir)
  if f.tool == "demucs" then return { exe = c.demucs, args = { "-n", "htdemucs", "-o", dir .. "/out", input } } end
  if f.tool == "whisper" then return { exe = c.whisper, args = { "-m", c.whisper_model, "-f", input, "-otxt", "-of", dir .. "/lyrics", "-np" } } end
  if f.tool == "basic_pitch" then return { exe = c.basic_pitch, args = { dir .. "/out", input } } end
end
-- A chat request: { exe = curl, args, request } (the request goes in dir/request.json, the answer comes in dir/reply.json, the HTTP status
-- on curl's output).
function ai.chat_spec(c, dir, system, user, win)
  return { exe = win and "curl.exe" or "curl", request = { model = c.model, stream = false,
      messages = { { role = "system", content = system }, { role = "user", content = user } } },
    args = { "-sS", "-m", "300", "-H", "Content-Type: application/json", "--data-binary", "@" .. dir .. "/request.json", "-o", dir .. "/reply.json",
      "-w", "%{http_code}", ai.endpoint(c.url) } }
end
local function ps_q(s) return "'" .. tostring(s):gsub("'", "''") .. "'" end
local function sh_q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
-- One Windows command-line argument (no quotes can be in a Windows path; a trailing backslash doubled so it doesn't escape the closing quote).
local function win_arg(s)
  local a = tostring(s):gsub('"', ""):gsub("(\\+)$", "%1%1")
  return '"' .. a .. '"'
end
-- The job's script: starts the program hidden in dir, writes pid.txt (or "failed"), then exit.txt with its exit code once it's done. Pure.
function ai.script(spec, dir, win)
  if win then
    local args = {}
    for i, a in ipairs(spec.args) do args[i] = win_arg(a) end
    return table.concat({
      "$d = " .. ps_q(dir),
      "try {",
      "  $p = Start-Process -FilePath " .. ps_q(spec.exe) .. " -ArgumentList " .. ps_q(table.concat(args, " ")) ..
        " -PassThru -WindowStyle Hidden -WorkingDirectory $d -RedirectStandardOutput (Join-Path $d 'out.txt') -RedirectStandardError (Join-Path $d 'err.txt')",
      "  $null = $p.Handle", -- (without it, ExitCode reads empty once the process has gone)
      "  Set-Content -LiteralPath (Join-Path $d 'pid.txt') $p.Id",
      "  $p.WaitForExit()",
      "  Set-Content -LiteralPath (Join-Path $d 'exit.txt') $p.ExitCode",
      "} catch {",
      "  Set-Content -LiteralPath (Join-Path $d 'err.txt') $_.Exception.Message",
      "  Set-Content -LiteralPath (Join-Path $d 'pid.txt') 'failed'",
      "}", "" }, "\r\n")
  end
  local args = {}
  for i, a in ipairs(spec.args) do args[i] = sh_q(a) end
  return table.concat({ "cd " .. sh_q(dir) .. " || exit 1", sh_q(spec.exe) .. " " .. table.concat(args, " ") .. " > out.txt 2> err.txt &",
    "p=$!", 'echo "$p" > pid.txt', 'wait "$p"', "echo $? > exit.txt", "" }, "\n")
end
-- How a job stands from its files: "starting", "running", "failed" (couldn't start), or "done" with its exit code. Pure.
function ai.job_state(pid, exit)
  local code = tonumber((exit or ""):match("^%s*(%-?%d+)"))
  if code then return "done", code end
  if (pid or ""):match("^%s*failed") then return "failed" end
  if (pid or ""):match("^%s*%d+") then return "running" end
  return "starting"
end
-- A chat endpoint's answer (curl's output: the HTTP status; the reply file's text) -> the words, or nil and why. Pure.
function ai.reply_text(status, body)
  local code = tonumber((status or ""):match("(%d%d%d)%s*$"))
  local j = type(body) == "string" and #body <= ai.READ_MAX and band.json_decode(body) or nil
  if code ~= 200 then
    local why = type(j) == "table" and type(j.error) == "table" and type(j.error.message) == "string" and j.error.message or nil
    return nil, "the chat model answered " .. (code and ("HTTP " .. code) or "nothing") .. (why and (": " .. why:sub(1, 200)) or "")
  end
  local ch = type(j) == "table" and type(j.choices) == "table" and j.choices[1]
  local t = type(ch) == "table" and type(ch.message) == "table" and ch.message.content
  if type(t) ~= "string" or not t:match("%S") then return nil, "the chat model's answer had no text" end
  t = t:gsub("\r\n?", "\n"):gsub("[%z\1-\8\11-\31\127]", ""):match("^%s*(.-)%s*$")
  if utf8.len(t) == nil then return nil, "the chat model's answer wasn't text" end
  if #t > ai.REPLY_MAX then t = t:sub(1, utf8.offset(t, ai.REPLY_MAX // 2) or ai.REPLY_MAX // 2) .. "..." end
  return t
end
-- The last line of a program's error output, short and with any address in it shorn of names and passwords. Pure.
function ai.err_line(err)
  local last
  for l in tostring(err or ""):gmatch("[^\r\n]+") do if l:match("%S") then last = l end end
  if not last then return nil end
  last = last:gsub("(https?://)[^/%s@]*@", "%1"):gsub("[%c]", " "):match("^%s*(.-)%s*$")
  return #last > 200 and last:sub(1, 200) .. "..." or last
end
local function shown(t)
  if #t <= ai.SHOW_MAX then return t end
  return t:sub(1, ai.SHOW_MAX) .. "\n... and " .. (#t - ai.SHOW_MAX) .. " characters more"
end
local function clock(s) s = tonumber(s) or 0; return string.format("%d:%02d", math.floor(s / 60), math.floor(s % 60)) end
local function mb(n) return string.format("%.1f MB", (tonumber(n) or 0) / 1048576) end

-- The prompts. Pure.
ai.PROMPTS = {
  feedback = "You are an experienced mixing engineer. You get measurements of a mix (loudness, peaks, stereo and spectrum figures), never the " ..
    "audio. Give 3 to 6 short, practical suggestions, each tied to a number, and say where the numbers look fine. Don't claim to have heard it.",
  recap = "You write a short, friendly recap of a band's recording session from its notes: 3 to 6 bullets, plain words, names and numbers as given.",
  names = "You suggest clear names for a band's recorded takes: section, player and anything notable, short. Reply as lines 'old -> new'. " ..
    "Nothing is renamed by itself: the band picks.",
}
function ai.recap_text(r) return r and table.concat(require("recap").lines(r), "\n") or nil end
function ai.names_text(takes, markers)
  local out = {}
  for i, t in ipairs(takes) do
    if i > 60 then out[#out + 1] = "... and " .. (#takes - 60) .. " more"; break end
    local sec = markers and require("recap").section_at(markers, t.pos)
    out[#out + 1] = string.format("%s @ %s on %s%s", t.name ~= "" and t.name or "(no name)", clock(t.pos), t.track, sec and (" (" .. sec .. ")") or "")
  end
  return table.concat(out, "\n")
end

-- ---- the project (REAPER) ---------------------------------------------------------------------------------------------------------------
local function r3(x) return math.floor((tonumber(x) or 0) * 1000 + 0.5) / 1000 end
local function source_file(tk)
  local src = reaper.GetMediaItemTake_Source(tk)
  local f = src and reaper.GetMediaSourceFileName(src, "") or ""
  if f == "" and src and reaper.GetMediaSourceParent then
    local p = reaper.GetMediaSourceParent(src)
    f = p and reaper.GetMediaSourceFileName(p, "") or ""
  end
  return f:gsub("\\", "/")
end
-- The project's audio takes a page can pick: { { g (the item's GUID), name, track, pos, len } }, at most TAKES_MAX. found(g): that one's item
-- and take instead.
local function each_take(proj, found)
  local out = {}
  for t = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, t)
    local _, tname = reaper.GetTrackName(tr)
    for i = 0, reaper.CountTrackMediaItems(tr) - 1 do
      local it = reaper.GetTrackMediaItem(tr, i)
      local tk = reaper.GetActiveTake(it)
      if tk and not reaper.TakeIsMIDI(tk) then
        local _, g = reaper.GetSetMediaItemInfo_String(it, "GUID", "", false)
        if found then
          if g == found then return it, tk, tname end
        elseif #out < ai.TAKES_MAX then
          out[#out + 1] = { g = g, name = select(2, reaper.GetSetMediaItemTakeInfo_String(tk, "P_NAME", "", false)) or "", track = tname,
            pos = r3(reaper.GetMediaItemInfo_Value(it, "D_POSITION")), len = r3(reaper.GetMediaItemInfo_Value(it, "D_LENGTH")) }
        end
      end
    end
  end
  if not found then return out end
end
function ai.takes(proj) return each_take(proj) end
-- The project's newest mix (<Project>/mixes, renders named by date: lib/phonerec.lua's rule). -> its path and name, or nil.
function ai.newest_mix(cfg, song)
  local dir, best, audio = band.song_dir(cfg, song) .. "/mixes", nil, require("listen").AUDIO
  for _, f in ipairs(band.files(dir)) do
    if audio[(f:match("%.([^.]+)$") or ""):lower()] and not f:find("^%.") and (not best or f > best) then best = f end
  end
  if best then return dir .. "/" .. best, best end
end
-- A mix file's numbers: REAPER's loudness, RMS and peaks over the whole file, plus the stereo and spectrum figures and the rule-based notes of
-- StudioSync AI's own mix feedback (addons/ai/lib/ai_mix.lua) when it's there and the file is a WAV. -> the stats, or nil for silence.
local function addon_mix()
  local ok, m = pcall(dofile, (debug.getinfo(1, "S").source:match("^@?(.*)[/\\]") or ".") .. "/../addons/ai/lib/ai_mix.lua")
  return ok and type(m) == "table" and m or nil
end
function ai.mix_stats(path, name)
  local src = reaper.PCM_Source_CreateFromFile(path)
  if not src then return nil end
  local g = {}
  for mode = 0, 3 do g[mode] = reaper.CalculateNormalization(src, mode, 0, 0, 0) end -- 0 LUFS-I, 1 RMS-I, 2 peak, 3 true peak
  reaper.PCM_Source_Destroy(src)
  if g[0] == 1 and g[2] == 1 then return nil end -- (silence: REAPER answers "no change" to both, lib/extras.lua)
  local db = function(x) return (x and x > 0) and r3(-20 * math.log(x, 10)) or nil end
  local row = { name = "Master", lufs_i = db(g[0]), rms_db = db(g[1]), peak_db = db(g[2]), true_peak_db = db(g[3]) }
  if row.peak_db and row.rms_db then row.crest_db = r3(row.peak_db - row.rms_db) end
  local mix = addon_mix()
  local stats = { file = name, master = row, tracks = {} }
  if mix and path:lower():match("%.wav$") then
    local w = mix.read_wav(path, 64, 2048)
    if w then for k, v in pairs(mix.analyze(w, 2048)) do row[k] = type(v) == "number" and r3(v) or v end end
  end
  if mix then stats.thresholds, stats.rule_notes = mix.T, mix.notes(stats) end
  return stats
end

-- ---- state -----------------------------------------------------------------------------------------------------------------------------
local S
function ai.reset() S = { want = -math.huge, asks = {}, jobs = {}, takes_at = -math.huge, n = 0 } end
ai.reset()
local function win() return reaper.GetOS():match("^Win") ~= nil end
local function nonce() return band.secret(16) end
function ai.jobs_dir() return band.home():gsub("\\", "/") .. "/ai/jobs" end
local function say(t) S.note, S.dirty = t, true; return t end

-- A page's (or the panel's) request: { feature, take = item GUID, mix = true, tracks = true }. Makes the ask; nothing runs. -> the ask, or nil
-- and why.
function ai.ask(proj, cfg, b, req, now)
  local f = type(req) == "table" and ai.BY_ID[req.feature]
  if not f then return nil, "AI: not a feature" end
  if not ai.studio_on(cfg.root) then return nil, "AI is off for this studio: the owner or an admin turns it on (panel: Settings > Studio > AI)" end
  local c = ai.conf()
  local kind, why = ai.provider(f, c)
  if kind == "none" then return nil, f.label .. ": " .. why end
  for id, a in pairs(S.asks) do if a.until_ <= now then S.asks[id] = nil end end
  local waiting = 0
  for _ in pairs(S.asks) do waiting = waiting + 1 end
  if waiting >= ai.ASKS_MAX then return nil, "AI: " .. waiting .. " asks are already waiting for a yes" end
  local id = nonce()
  local dir = ai.jobs_dir() .. "/" .. os.date("%Y%m%d-%H%M%S") .. "-" .. f.id .. "-" .. id:sub(1, 6)
  local a = { id = id, feature = f.id, label = f.label, kind = kind, until_ = now + ai.ASK_FOR, dir = dir, target = ai.target(f, c),
    proj = proj, song = b.song, room = b.room, opts = { tracks = req.tracks == true } }
  if kind == "tool" then
    local input, name, pos, offs, len
    if f.input == "audio" and req.mix == true then
      input, name = ai.newest_mix(cfg, b.song)
      if not input then return nil, f.label .. ": this project has no mix yet (Mixes page: Render mix)" end
      pos, offs = 0, 0
    else
      local it, tk, tname
      if type(req.take) == "string" and #req.take <= 64 then it, tk, tname = each_take(proj, req.take) end
      if not it then return nil, f.label .. ": pick a take first" end
      input = source_file(tk)
      name = select(2, reaper.GetSetMediaItemTakeInfo_String(tk, "P_NAME", "", false)) or ""
      name = name ~= "" and name or tname
      pos, offs = reaper.GetMediaItemInfo_Value(it, "D_POSITION"), reaper.GetMediaItemTakeInfo_Value(tk, "D_STARTOFFS")
      len = reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
    end
    if input == "" or not reaper.file_exists(input) then return nil, f.label .. ": its audio file isn't on this computer yet" end
    a.spec = ai.tool_spec(f, c, input, dir)
    a.opts.name, a.opts.pos, a.opts.offs, a.opts.len = name, pos, offs, len
    a.sends = (input:match("([^/]+)$") or input) .. " (" .. mb(band.size(input)) .. ", the whole file) goes to " .. ai.TOOLS[f.tool] .. " at " .. c[f.tool] ..
      " on this computer. Nothing leaves this computer. It may use the graphics card for a few minutes."
    a.to, a.here = "this computer: " .. ai.TOOLS[f.tool], true
    a.result = f.id == "stems" and ("Stems into " .. b.song .. "/stems/<date> AI " .. band.clean(name) .. (a.opts.tracks and ", and as new tracks under it" or ""))
      or f.id == "lyrics" and "The words go on the Sheet page as a new section (your edit, as if typed)"
      or "A new MIDI track at the take's place"
  else
    local text
    if f.input == "mix" then
      local path, name = ai.newest_mix(cfg, b.song)
      if not path then return nil, f.label .. ": this project has no mix yet (Mixes page: Render mix)" end
      local st = ai.mix_stats(path, name)
      if not st then return nil, f.label .. ": the newest mix is silent" end
      text = "Measurements of the mix " .. name .. " (JSON):\n" .. band.json_encode(st)
    elseif f.input == "recap" then
      text = ai.recap_text(require("recap").last(cfg, b.song, b.room))
      if not text then return nil, f.label .. ": no session recap here yet (one is made when a session ends)" end
      text = "Session notes:\n" .. text
    else
      local takes = ai.takes(proj)
      if #takes == 0 then return nil, f.label .. ": no takes in this project" end
      text = "Takes:\n" .. ai.names_text(takes, band.capture_markers and band.capture_markers(proj) or nil)
    end
    a.spec = ai.chat_spec(c, dir, ai.PROMPTS[f.id], text, win())
    a.here = ai.is_local(c.url)
    a.to = c.model .. " at " .. ai.redact(c.url) .. (a.here and " (this computer)" or " (another computer: this text leaves this computer)")
    a.sends = "This text goes to " .. a.to .. "; no audio:\n" .. shown(text)
    a.result = "The answer goes in this project's chat for the band. Nothing in the project changes."
  end
  a.spec.timeout = ai.TIMEOUT[f.id]
  S.asks[id], S.dirty = a, true
  band.log("AI: " .. f.label .. " asks for a yes (to " .. a.to .. ")")
  return a
end

local kill
-- The yes or no to an ask. origin: "panel", "here" (a page on this computer) or "away" (a phone, another device, or not known). -> the job, or
-- nil and why.
function ai.answer(proj, cfg, b, id, yes, origin, now)
  local a = type(id) == "string" and S.asks[id]
  if not a or a.until_ <= now then
    if a then S.asks[id] = nil end
    return nil, "AI: that ask has run out; ask again"
  end
  if not yes then S.asks[id], S.dirty = nil, true; band.log("AI: " .. a.label .. ": no"); return nil, "AI: " .. a.label .. " not run (no)" end
  local c = ai.conf()
  if not ai.yes_ok(origin, c) then
    return nil, "AI: a yes from a phone or another device doesn't count on " .. tostring(cfg.user) .. "'s computer; say yes there " ..
      "(or allow it in the panel: Settings > Studio > AI)"
  end
  S.asks[id], S.dirty = nil, true
  local f = ai.BY_ID[a.feature]
  if not ai.studio_on(cfg.root) then return nil, "AI is off for this studio now" end
  if ai.provider(f, c) == "none" or ai.target(f, c) ~= a.target then return nil, "AI: this computer's AI settings changed since the ask; ask again" end
  return ai.start(a, cfg, b, now)
end

-- A yes'd ask starts. -> the job, or nil and why.
function ai.start(a, cfg, b, now)
  local w = win()
  reaper.RecursiveCreateDirectory(a.dir, 0)
  local ok, err = pcall(function()
    if a.spec.request then band.write_atomic(a.dir .. "/request.json", band.json_encode(a.spec.request)) end
    band.write_atomic(a.dir .. (w and "/run.ps1" or "/run.sh"), ai.script(a.spec, a.dir, w))
  end)
  if not ok then return nil, "AI: " .. a.label .. " couldn't start: " .. tostring(err) end
  local cmd = w and ('powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' .. a.dir .. '/run.ps1"') or ("/bin/sh " .. sh_q(a.dir .. "/run.sh"))
  require("services").run_hidden("ai-" .. a.id, cmd, 1e9)
  S.n = S.n + 1
  local job = { id = a.id, n = S.n, feature = a.feature, label = a.label, kind = a.kind, state = "running", started = now, dir = a.dir, spec = a.spec,
    timeout = a.spec.timeout, opts = a.opts, proj = a.proj, cfg = cfg, b = { song = a.song, room = a.room }, here = a.here }
  S.jobs[#S.jobs + 1], S.dirty = job, true
  band.log("AI: " .. a.label .. " started (" .. a.to .. ")")
  return job
end

kill = function(pid)
  if not pid then return end
  local cmd = win() and ("taskkill /PID " .. pid .. " /T /F") or ("pkill -P " .. pid .. "; kill " .. pid)
  require("services").run_hidden("ai-kill-" .. pid, cmd, 1e9)
end
local function pid_of(job) return tonumber((band.read(job.dir .. "/pid.txt") or ""):match("^%s*(%d+)")) end
local function finish(job, state, msg)
  job.state, job.msg, job.ended, S.dirty = state, msg, reaper.time_precise(), true
  band.log("AI: " .. job.label .. " " .. state .. (msg and (": " .. msg) or ""))
  local done = {}
  for _, j in ipairs(S.jobs) do if j.state ~= "running" then done[#done + 1] = j end end
  for i = 1, #done - ai.KEEP_JOBS do -- (only the newest finished ones stay listed)
    for k, j in ipairs(S.jobs) do if j == done[i] then table.remove(S.jobs, k); break end end
  end
end
-- Cancel a running job (from a page or the panel; anyone who may see it). -> words for the page.
function ai.cancel(id)
  for _, j in ipairs(S.jobs) do
    if j.id == id and j.state == "running" then
      j.kill_pending = true
      kill(pid_of(j))
      if pid_of(j) then j.kill_pending = nil end
      finish(j, "cancelled")
      return "AI: " .. j.label .. " cancelled"
    end
  end
  return "AI: nothing running by that name"
end

-- ---- results ----------------------------------------------------------------------------------------------------------------------------
local function walk(dir, ext, out, depth)
  out = out or {}
  for _, f in ipairs(band.files(dir)) do if f:lower():sub(-#ext) == ext then out[#out + 1] = dir .. "/" .. f end end
  if (depth or 0) < 3 then
    local i = 0
    while true do
      local sub = reaper.EnumerateSubdirectories(dir, i)
      if not sub then break end
      walk(dir .. "/" .. sub, ext, out, (depth or 0) + 1)
      i = i + 1
    end
  end
  table.sort(out)
  return out
end
local function stems_dir(job)
  return band.song_dir(job.cfg, job.b.song) .. "/stems/" .. os.date("%Y-%m-%d %H%M") .. " AI " .. band.clean(job.opts.name or job.label)
end
-- New tracks, one per file, each item where the take was (same start in the file, same length), as one undo step.
local function add_tracks(proj, files, o, title)
  if not (proj and reaper.ValidatePtr(proj, "ReaProject*")) then return 0 end
  local n = 0
  reaper.Undo_BeginBlock2(proj)
  reaper.PreventUIRefresh(1)
  for _, path in ipairs(files) do
    local src = reaper.PCM_Source_CreateFromFile(path)
    if src then
      local idx = reaper.CountTracks(proj)
      reaper.InsertTrackInProject(proj, idx, 0)
      local tr = reaper.GetTrack(proj, idx)
      local name = (o.name or "") .. " - " .. ((path:match("([^/]+)%.[^.]+$") or path):gsub("_basic_pitch$", " MIDI"))
      reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", name, true)
      local it = reaper.AddMediaItemToTrack(tr)
      local tk = reaper.AddTakeToMediaItem(it)
      band.set_take_source(tk, src)
      reaper.GetSetMediaItemTakeInfo_String(tk, "P_NAME", name, true)
      reaper.SetMediaItemTakeInfo_Value(tk, "D_STARTOFFS", o.offs or 0)
      reaper.SetMediaItemInfo_Value(it, "D_POSITION", o.pos or 0)
      reaper.SetMediaItemInfo_Value(it, "D_LENGTH", o.len or (reaper.GetMediaSourceLength(src)))
      reaper.UpdateItemInProject(it)
      n = n + 1
    end
  end
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock2(proj, "StudioSync AI: " .. title, -1)
  return n
end
local function copy_into(files, dest)
  reaper.RecursiveCreateDirectory(dest, 0)
  local out = {}
  for _, f in ipairs(files) do
    local to = dest .. "/" .. f:match("([^/]+)$"):gsub('[%c\\:%*%?"<>|]', "_") -- (band.clean drops the dot before the extension)
    band.copy_atomic(f, to)
    out[#out + 1] = to
  end
  return out
end
ai.RESULTS = {
  stems = function(job)
    local files = walk(job.dir .. "/out", ".wav")
    if #files == 0 then return nil, "demucs made no stems" end
    local dest = stems_dir(job)
    local placed = copy_into(files, dest)
    local n = job.opts.tracks and add_tracks(job.proj, placed, job.opts, "stems of " .. tostring(job.opts.name)) or 0
    return #placed .. " stems in " .. dest:match("[^/]+/[^/]+$") .. (n > 0 and (", and " .. n .. " new tracks") or "")
  end,
  midi = function(job)
    local files = walk(job.dir .. "/out", ".mid")
    if #files == 0 then return nil, "Basic Pitch made no MIDI file" end
    local placed = copy_into({ files[1] }, stems_dir(job))
    local n = add_tracks(job.proj, placed, { name = job.opts.name, pos = job.opts.pos, len = job.opts.len }, "MIDI of " .. tostring(job.opts.name))
    if n == 0 then return nil, "the MIDI file is in " .. placed[1]:match("[^/]+/[^/]+/[^/]+$") .. ", but the project isn't open any more" end
    return "a new MIDI track, " .. tostring(job.opts.name) .. " - MIDI"
  end,
  lyrics = function(job)
    local t = band.read(job.dir .. "/lyrics.txt") or ""
    t = t:gsub("\r\n?", "\n"):gsub("[%z\1-\8\11-\31\127]", ""):gsub("\n%s*\n+", "\n"):match("^%s*(.-)%s*$")
    if t == "" then return nil, "no words heard" end
    if #t > ai.LYRICS_MAX then t = t:sub(1, ai.LYRICS_MAX) end
    local proj = job.proj
    local bar
    if proj and reaper.ValidatePtr(proj, "ReaProject*") and reaper.TimeMap2_timeToBeats then
      bar = select(2, reaper.TimeMap2_timeToBeats(proj, job.opts.pos or 0)) + 1
    end
    local name = ("Lyrics: " .. tostring(job.opts.name) .. " (AI)"):sub(1, 80)
    local said = require("songsheet").action(proj, job.cfg, job.b, { set = { id = "h:ai" .. job.id:sub(1, 8), name = name, text = t, plays = "", bar = bar } })
    if said then return nil, said end
    return "on the Sheet page as \"" .. name .. "\""
  end,
}
local function chat_result(job)
  local text, why = ai.reply_text(band.read(job.dir .. "/out.txt"), band.read(job.dir .. "/reply.json"))
  if not text then return nil, why end
  require("page_chat").post(job.cfg, job.b, "AI (" .. tostring(job.spec.request.model) .. ", " .. job.label:lower() .. "; suggestions only): " .. text, "song")
  return "the answer is in this project's chat"
end

-- One look at a running job. -> true when it changed.
function ai.poll(job, now)
  if job.state ~= "running" then
    if job.kill_pending and pid_of(job) then kill(pid_of(job)); job.kill_pending = nil end -- (cancelled before its pid was there)
    return false
  end
  local st, code = ai.job_state(band.read(job.dir .. "/pid.txt"), band.read(job.dir .. "/exit.txt"))
  if st == "failed" then finish(job, "failed", "it didn't start: " .. (ai.err_line(band.read(job.dir .. "/err.txt")) or "no reason given")); return true end
  if st ~= "done" then
    if now - job.started > job.timeout then
      kill(pid_of(job))
      job.kill_pending = pid_of(job) == nil or nil
      finish(job, "failed", "it ran past " .. math.floor(job.timeout / 60) .. " minutes and was stopped")
      return true
    end
    return false
  end
  if code ~= 0 then
    finish(job, "failed", "it stopped with code " .. code .. (ai.err_line(band.read(job.dir .. "/err.txt")) and (": " .. ai.err_line(band.read(job.dir .. "/err.txt"))) or ""))
    return true
  end
  local fn = job.kind == "chat" and chat_result or ai.RESULTS[job.feature]
  local ok, msg, why = pcall(fn, job)
  if ok and msg then finish(job, "done", msg) else finish(job, "failed", ok and why or tostring(msg)) end
  return true
end

-- ---- the page's model, its actions, the tick --------------------------------------------------------------------------------------------
function ai.model(cfg, b, now)
  local c, on = ai.conf(), ai.studio_on(cfg.root)
  local feats = {}
  for _, f in ipairs(ai.FEATURES) do
    local kind, why = ai.provider(f, c)
    feats[#feats + 1] = { id = f.id, label = f.label, input = f.input, provider = kind, why = why,
      where = kind == "tool" and "here" or kind == "chat" and (ai.is_local(c.url) and "here" or "away") or nil }
  end
  local asks = {}
  for _, a in pairs(S.asks) do
    if a.until_ > now then asks[#asks + 1] = { id = a.id, label = a.label, sends = a.sends, to = a.to, here = a.here, result = a.result, at = a.until_ } end
  end
  table.sort(asks, function(x, y) return x.at < y.at end)
  for _, a in ipairs(asks) do a.at = nil end -- (no countdown in the topic: it would change, and redraw the page, every tick)
  local jobs = {}
  for i = #S.jobs, 1, -1 do
    local j = S.jobs[i]
    jobs[#jobs + 1] = { id = j.id, label = j.label, state = j.state, msg = j.msg, secs = j.ended and math.floor(j.ended - j.started) or nil }
  end
  local may = false
  pcall(function() may = require("groups").may_manage(cfg.root, cfg.user) end)
  return { on = on, may = may, me = cfg.user, features = feats, asks = asks, jobs = jobs, note = S.note, phone_yes = c.phone_yes,
    here_known = reaper.StudioSync_WebUIPollHere ~= nil, takes = S.want > now and S.takes or nil, mix = S.want > now and S.mix or nil }
end

-- A page's action: { topic = "ai", want } | { ask = { feature, take, mix, tracks } } | { yes = id } | { no = id } | { cancel = id }.
-- here: the extension said a page on this computer sent it. -> words for the log, or nil.
function ai.action(proj, cfg, b, a, here)
  local now = reaper.time_precise()
  if a.want then S.want = now + ai.WANT_FOR; S.takes_at = -math.huge; S.dirty = true end
  if a.ask ~= nil then
    local ask, why = ai.ask(proj, cfg, b, a.ask, now)
    say(ask and ("AI: " .. ask.label .. " is waiting for a yes") or why)
    return why
  end
  local id = a.yes or a.no
  if id ~= nil then
    local job, why = ai.answer(proj, cfg, b, id, a.yes ~= nil, here and "here" or "away", now)
    say(job and ("AI: " .. job.label .. " started") or why)
    return why
  end
  if a.cancel ~= nil then return say(ai.cancel(a.cancel)) end
end

-- What the panel shows (ExtState "ai asks", this computer only) and its answer back ("ai answer": "<id> yes|no|cancel").
local panel_was
local function panel(proj, cfg, b, now)
  local ans = reaper.GetExtState(band.SECTION, "ai answer")
  if ans ~= "" then
    reaper.SetExtState(band.SECTION, "ai answer", "", false)
    local id, verb = ans:match("^(%x+) (%a+)$")
    if verb == "cancel" then say(ai.cancel(id))
    elseif verb == "yes" or verb == "no" then
      local job, why = ai.answer(proj, cfg, b, id, verb == "yes", "panel", now)
      say(job and ("AI: " .. job.label .. " started") or why)
    end
  end
  local list = {}
  for _, a in pairs(S.asks) do if a.until_ > now then list[#list + 1] = { id = a.id, label = a.label, sends = a.sends, result = a.result } end end
  for _, j in ipairs(S.jobs) do if j.state == "running" then list[#list + 1] = { id = j.id, label = j.label, running = true } end end
  table.sort(list, function(x, y) return x.id < y.id end)
  local s = band.json_encode(list)
  if s ~= panel_was then panel_was = s; reaper.SetExtState(band.SECTION, "ai asks", s, false) end
end

-- Each tick of the tab in front (lib/webui.lua), looking or not: the panel's answers, asks running out, jobs, and the page's topic.
function ai.tick(proj, cfg, b, publish, now)
  local busy = false
  for _, j in ipairs(S.jobs) do if j.state == "running" or j.kill_pending then busy = true; break end end
  if not busy and not next(S.asks) and not S.dirty and S.want <= now and reaper.GetExtState(band.SECTION, "ai answer") == "" and not panel_was then return end
  panel(proj, cfg, b, now)
  for id, a in pairs(S.asks) do if a.until_ <= now then S.asks[id], S.dirty = nil, true end end
  for _, j in ipairs(S.jobs) do ai.poll(j, now) end
  if S.want > now and now - S.takes_at >= 2 then
    S.takes_at, S.takes = now, ai.takes(proj)
    S.mix = select(2, ai.newest_mix(cfg, b.song))
  end
  S.dirty = false
  if publish then publish("ai", ai.model(cfg, b, now)) end
  if panel_was == "[]" and not next(S.asks) then panel_was = nil end -- (nothing left for the panel: the tick goes quiet again)
end

-- ---- the panel: Settings > Studio > AI ---------------------------------------------------------------------------------------------------
-- may: owner or admin (the studio's switch). This computer's settings and the asks waiting for a yes are everyone's own.
function ai.studio_ui(ctx, ImGui, cfg, may)
  ImGui.SeparatorText(ctx, "AI (optional)")
  local on = ai.studio_on(cfg.root)
  ImGui.TextDisabled(ctx, on and "On: people in the studio can ask for AI tools from the web UI's AI page. Every run asks first and says what goes where."
    or "Off: no AI tools. On, people can ask for stems, lyrics, MIDI, mix feedback and recaps; every run still asks first.")
  if may then
    local ch, v = ImGui.Checkbox(ctx, "AI tools for this studio##studioai", on)
    if ch then
      require("groups").set_ai(cfg.root, v)
      band.log(v and "AI tools are on for this studio; each run still asks first (Settings > Studio)" or "AI tools are off for this studio (Settings > Studio)")
    end
    ImGui.SetItemTooltip(ctx, "Owner and admins. Off by default. Each computer chooses its own tools and model below.")
  end
  if not on then return end
  ImGui.TextDisabled(ctx, "This computer (only here, never from a page):")
  local c = ai.conf()
  local fields = { { "url", "Chat model's address, e.g. http://127.0.0.1:4000" }, { "model", "Chat model's name" },
    { "demucs", "demucs program (stems)" }, { "whisper", "whisper-cli program (words)" }, { "whisper_model", "whisper model file (ggml-...bin)" },
    { "basic_pitch", "basic-pitch program (MIDI)" } }
  for _, fd in ipairs(fields) do
    ImGui.SetNextItemWidth(ctx, -1)
    local ch, v = ImGui.InputTextWithHint(ctx, "##ai" .. fd[1], fd[2], c[fd[1]])
    if ch then ai.set_conf(fd[1], (v:gsub("^%s+", ""):gsub("%s+$", ""))) end
  end
  if c.url ~= "" then
    ImGui.TextDisabled(ctx, not ai.url_ok(c.url) and "That address isn't a plain http(s) address." or ai.is_local(c.url) and "Local: the text stays on this computer."
      or "Sent away: that address is another computer, so what's asked leaves this one.")
  end
  local ch, v = ImGui.Checkbox(ctx, "A yes from a phone counts here##aiphoneyes", c.phone_yes)
  if ch then ai.set_conf("phone_yes", v) end
  ImGui.SetItemTooltip(ctx, "Off: a run that starts on this computer needs a yes here (this panel, or the web UI on this computer).\nOn: a phone or another device in the studio can say yes too.")
  local list = band.ext_json(band.SECTION, "ai asks")
  for _, a in ipairs(type(list) == "table" and list or {}) do
    if type(a) == "table" and type(a.id) == "string" then
      ImGui.Separator(ctx)
      ImGui.TextWrapped(ctx, tostring(a.label) .. (a.running and " is running." or "?"))
      if not a.running then
        ImGui.TextWrapped(ctx, tostring(a.sends))
        ImGui.TextDisabled(ctx, tostring(a.result))
        if ImGui.Button(ctx, "Yes, run it##aiyes" .. a.id) then reaper.SetExtState(band.SECTION, "ai answer", a.id .. " yes", false) end
        ImGui.SameLine(ctx)
        if ImGui.Button(ctx, "No##aino" .. a.id) then reaper.SetExtState(band.SECTION, "ai answer", a.id .. " no", false) end
      elseif ImGui.Button(ctx, "Cancel##aicancel" .. a.id) then reaper.SetExtState(band.SECTION, "ai answer", a.id .. " cancel", false) end
    end
  end
end

function ai._state() return S end
return ai
