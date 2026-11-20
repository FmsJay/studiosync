-- Distributed bounces (James, rt; roadmap "Distributed bounces", lib/bounces.lua): stems split across the idle computers in the room.
-- The pure parts (the copy's SEL and paths, who can help, the split with same-named stems kept together, when a share is overdue), then a
-- stand-in of five computers in one Lua: James asks for stems; Bo, Cy and the hidden background REAPERs render shares (Cy lacks a plug-in a
-- stem hears through a send, a sampler's stem stays here, Gus is a guest, Old has no background REAPER); Bo drops mid-render and his stems
-- are redone elsewhere; every file lands in James's stems folder, the same as rendering the copy here would make it. Then a mix on the hub
-- over the link alone, and a hub that can't (rendered here).
package.path = "lib/?.lua;" .. package.path
local clock, ME = 1000, "James"

-- ---- an in-memory disk (each computer's paths are its own) ------------------------------------------------------------------------------
local FS = {}
local function parent(p) return p:match("^(.*)/[^/]+$") end
io.open = function(path, mode)
  mode = mode or "r"
  if mode:find("w") then
    local buf = {}
    return { write = function(self, s) buf[#buf + 1] = s; return self end, close = function() FS[path] = table.concat(buf); return true end,
      seek = function() return #table.concat(buf) end }
  end
  local data, pos = FS[path], 0
  if not data then return nil end
  return {
    read = function(_, n)
      if n == "a" or n == "*a" then local s = data:sub(pos + 1); pos = #data; return s end
      if pos >= #data then return nil end
      local s = data:sub(pos + 1, pos + n); pos = pos + #s; return s
    end,
    seek = function(_, w) if w == "end" then return #data end return pos end,
    close = function() return true end }
end
os.remove = function(p) if FS[p] then FS[p] = nil; return true end return nil end
os.rename = function(a, b) if FS[a] then FS[b], FS[a] = FS[a], nil; return true end return nil end
local function list(dir)
  local out = {}
  for p in pairs(FS) do if parent(p) == dir then out[#out + 1] = p:match("[^/]+$") end end
  table.sort(out)
  return out
end

-- ---- REAPER, per computer ----------------------------------------------------------------------------------------------------------------
local EXT, xrun, playstate = {}, {}, {}
local function ext() EXT[ME] = EXT[ME] or {}; return EXT[ME] end
reaper = setmetatable({
  time_precise = function() return clock end,
  GetOS = function() return "Win64" end,
  GetExtState = function(_, k) return ext()[k] or "" end,
  SetExtState = function(_, k, v) ext()[k] = v end,
  DeleteExtState = function(_, k) ext()[k] = nil end,
  EnumerateFiles = function(dir, i) if i < 0 then return nil end return list(dir)[i + 1] end,
  file_exists = function(p) return FS[p] ~= nil end,
  RecursiveCreateDirectory = function() return 1 end,
  EnumProjects = function(i) if i == 0 or i == -1 then return "P-" .. ME end end,
  GetPlayStateEx = function() return playstate[ME] or 0 end,
  GetUnderrunTime = function() return xrun[ME] or 0, 0, clock * 1000 end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() end end end })

local band = require("band")
local logs, chats = {}, {}
band.log = function(s) logs[#logs + 1] = ME .. ": " .. s end

-- James's project: tracks with GUIDs, folders, sends, plug-ins (keys), sounds and files their plug-ins load, items' media.
local master = { name = "MASTER", guid = "{MASTER}", fx = {}, items = {} }
local tracks = {}
local function T(t)
  t.guid = string.format("{%08X-0000-0000-0000-000000000000}", #tracks + 1)
  t.fx, t.items, t.sends_from, t.depth = t.fx or {}, t.items or {}, t.sends_from or {}, t.depth or 0
  tracks[#tracks + 1] = t
  return t
end
local JR = "C:/J/Studio"
local drums = T({ name = "Drums", depth = 1, fx = { { key = "reacomp" } } })
T({ name = "Kick", items = { "Song/Audio/kick.wav" }, parent = drums })
T({ name = "Snare", depth = -1, items = { "Song/Audio/snare.wav" }, parent = drums })
T({ name = "Bass", fx = { { key = "reaeq" } }, items = { "Song/Audio/bass.wav" } })
local gtr = T({ name = "Gtr", fx = { { key = "rare amp" } }, items = { "Song/Audio/gtr.wav" } })
T({ name = "Verb", fx = { { key = "reaverb", files = { "C:/IR/hall.wav", "C:/Users/j/VST3 Presets/x/hall.vstpreset" } } }, sends_from = { gtr } })
T({ name = "Keys", fx = { { key = "kontakt", sounds = false } }, items = { "Song/Audio/keys.mid" } })
T({ name = "Vox", fx = { { key = "reaeq" } }, items = { "Song/Audio/vox1.wav" } })
T({ name = "Vox", items = { "Song/Audio/vox2.wav" } })
T({ name = "Piano", fx = { { key = "rs5k", sounds = { "C:/Samples/piano.wav" } } }, items = { "Song/Audio/piano.mid" } })
T({ name = "Pad", silent = true, items = { "Song/Audio/pad.mid" } })
T({ name = "Click (mine)", loc = true, items = { "!C:/Private/click.wav" } }) -- (your own: outside the shared folder, muted in the copy)
local MINE = { RENDER_SETTINGS = 1, RENDER_PATTERN = "mine", RENDER_FORMAT = "mp3", RENDER_FORMAT2 = "", RENDER_SRATE = 44100, RENDER_BOUNDSFLAG = 1,
  RENDER_STARTPOS = 0, RENDER_ENDPOS = 0, RENDER_ADDTOPROJ = 0, RENDER_NORMALIZE = 0, RENDER_BRICKWALL = 0 } -- (your own render settings)
local proj_render, proj_len, mutes = {}, 60, {}
for k, v in pairs(MINE) do proj_render[k] = v end

local function idx(tr) for i, t in ipairs(tracks) do if t == tr then return i end end return 0 end
reaper.CountTracks = function() return #tracks end
reaper.GetTrack = function(_, i) return tracks[i + 1] end
reaper.GetMasterTrack = function() return master end
reaper.GetTrackGUID = function(tr) return tr.guid end
reaper.GetTrackName = function(tr) return true, tr.name end
reaper.GetSetMediaTrackInfo_String = function(tr, k) if k == "P_NAME" then return true, tr.name end return true, "" end
reaper.GetParentTrack = function(tr) return tr.parent end
reaper.GetMediaTrackInfo_Value = function(tr, k)
  if k == "I_FOLDERDEPTH" then return tr.depth elseif k == "B_MUTE" then return mutes[tr] or 0 elseif k == "IP_TRACKNUMBER" then return idx(tr) end
  return 0
end
reaper.SetMediaTrackInfo_Value = function(tr, k, v) if k == "B_MUTE" then mutes[tr] = v end end
reaper.GetTrackNumSends = function(tr, cat) return cat == -1 and #tr.sends_from or 0 end
reaper.GetTrackSendInfo_Value = function(tr, _, r) return tr.sends_from[r + 1] end
reaper.GetProjectLength = function() return proj_len end
reaper.GetSet_LoopTimeRange2 = function() return 10, 20 end

-- The copy as REAPER would save it: render settings, each track's MUTESOLO, SEL, plug-ins and media.
band.save_copy = function(_, path)
  local o = { "<REAPER_PROJECT 0.1 \"7.0\" 0", "  RENDER_SETTINGS " .. tostring(proj_render.RENDER_SETTINGS), "  RENDER_PATTERN " .. tostring(proj_render.RENDER_PATTERN),
    "  RENDER_FORMAT2 " .. tostring(proj_render.RENDER_FORMAT2), "  RENDER_RANGE " .. tostring(proj_render.RENDER_STARTPOS) .. " " .. tostring(proj_render.RENDER_ENDPOS) }
  for _, t in ipairs(tracks) do
    o[#o + 1] = "  <TRACK " .. t.guid
    o[#o + 1] = "    NAME " .. t.name
    o[#o + 1] = "    MUTESOLO " .. math.floor(mutes[t] or 0) .. " 0 0"
    o[#o + 1] = "    SEL 0"
    o[#o + 1] = "    <FXCHAIN"
    for _, f in ipairs(t.fx) do o[#o + 1] = '      <VST "VST: ' .. f.key .. '" x.dll 0'; o[#o + 1] = "      >" end
    o[#o + 1] = "    >"
    for _, m in ipairs(t.items) do
      local p = m:sub(1, 1) == "!" and m:sub(2) or (JR .. "/" .. m)
      o[#o + 1] = "    <ITEM"; o[#o + 1] = "      <SOURCE " .. (t.silent and "MIDI" or "WAVE"); o[#o + 1] = '        FILE "' .. p .. '" 1'
      if t.silent then o[#o + 1] = "        SILENT" end
      o[#o + 1] = "      >"; o[#o + 1] = "    >"
    end
    o[#o + 1] = "  >"
  end
  o[#o + 1] = ">"
  FS[path] = table.concat(o, "\n") .. "\n"
  return true
end

-- ---- the computers --------------------------------------------------------------------------------------------------------------------------
local ROOT = { James = JR, Bo = "D:/Bo/Studio", Cy = "/Users/cy/Studio", Gus = "E:/Gus/Studio", Old = "F:/Old/Studio" }
local up = { James = true, Bo = true, Cy = true, Gus = true, Old = true }
local cpu = { James = 20, Bo = 10, Cy = 30, Gus = 0, Old = 0 }
local bnc = { James = true, Bo = true, Cy = true, Gus = true, Old = false }
local recording = {}
local KEYS = { "reacomp", "reaeq", "rare amp", "reaverb", "kontakt", "rs5k" }
local plugins = { Bo = {}, Cy = {}, Gus = {}, Old = {} }
for u, set in pairs(plugins) do for _, k in ipairs(KEYS) do set[k] = not (u == "Cy" and k == "rare amp") end end
local haves = { Bo = { ["id:c:/ir/hall.wav"] = true, ["id:c:/samples/piano.wav"] = true }, Cy = { ["id:c:/ir/hall.wav"] = true } } -- (Cy lacks the piano's sample)
local B = { song = "Song", room = "main" }
local cfgs = {}
for u, r in pairs(ROOT) do
  cfgs[u] = { root = r, user = u }
  for _, f in ipairs({ "kick.wav", "snare.wav", "bass.wav", "gtr.wav", "keys.mid", "vox1.wav", "vox2.wav", "piano.mid", "pad.mid" }) do FS[r .. "/Song/Audio/" .. f] = "audio " .. f end
end
FS["C:/Private/click.wav"] = "James's own click"

local queue, inbox, jobs, link_files, syncthing = {}, {}, {}, true, true
local function others() local o = {}; for u in pairs(ROOT) do if u ~= ME and up[u] then o[#o + 1] = u end end; table.sort(o); return o end
local function inbox_dir(u) return ROOT[u] .. "/.inbox/.streams" end
package.loaded.direct = {
  live_available = function() return true end,
  send_live = function(_, kind, d, song, room, _, to)
    assert(kind == "bounce" and song == "Song" and room == "main", "bounce messages, this song and room")
    for _, p in ipairs(to or {}) do
      local u = p:match("^(.-):")
      if up[ME] and up[u] then queue[#queue + 1] = { to = u, d = band.json_decode(band.json_encode(d)) } end
    end
    return true
  end,
  stream_start = function(_, path, song, _, _, name, to)
    assert(name:match("^[^/\\:%*%?\"<>|]+%.%a+$") and #name <= 200 and (name:match("%.txt$") or name:match("%.wav$")), "a plain name the link takes: " .. name)
    local rel = song .. "/" .. name
    for _, p in ipairs(to) do
      local u = p:match("^(.-):")
      if up[ME] and up[u] and (link_files or name:match("%.txt$")) and FS[path] then
        FS[inbox_dir(u) .. "/" .. rel] = FS[path]
        inbox[u] = inbox[u] or {}
        table.insert(inbox[u], { rel = rel, done = true, ok = true })
      end
    end
    return rel
  end,
  stream_end = function() return true end,
  streams = function() return { out = {}, inn = inbox[ME] or {} } end,
  stream_path = function(_, rel) return inbox_dir(ME) .. "/" .. rel end,
}
package.loaded.presence = { peers = function()
  local out = {}
  for _, u in ipairs(others()) do out[#out + 1] = { user = u, cpu = cpu[u], bnc = bnc[u] or nil, recording = recording[u] } end
  return out
end }
package.loaded.hops = { BUSY = 75, cpu_now = function() return cpu[ME] end,
  peers_by_user = function() local o = {}; for _, u in ipairs(others()) do o[u] = u .. ":1" end; return o end }
package.loaded.prints = {
  track_keys = function(tr) local k = {}; for _, f in ipairs(tr.fx) do k[#k + 1] = f.key end; return k end,
  fx_all = function(tr) local o = {}; for i = 1, #tr.fx do o[i] = i - 1 end; return o end,
  has = function(_, u, keys) for _, k in ipairs(keys) do if not (plugins[u] and plugins[u][k]) then return false end end; return true end,
}
package.loaded.libraries = {
  fx_refs = function(tr, i) local f = tr.fx[i + 1]; return f.sounds, f.files or {} end,
  id = function(p) return "id:" .. p:lower() end,
  studio = function() return {}, haves end,
}
package.loaded.content = { kind = function(p) return p:match("%.vstpreset$") and "preset" or "file" end, id = function(p) return "id:" .. p:lower() end }
package.loaded.mirror = { local_track = function(tr) return tr.loc == true end }
package.loaded.extras = {
  STANDARD = function() return { RENDER_FORMAT = "wav24", RENDER_FORMAT2 = "", RENDER_SRATE = 48000 } end,
  save_render = function() local s = {}; for k, v in pairs(proj_render) do s[k] = v end; return s end,
  set_render = function(_, t) for k, v in pairs(t) do proj_render[k] = v end end,
  silent = function(p) return FS[p] == "SILENT" end,
}
package.loaded.removal = { guest_names = function() return { Gus = true } end }
local hub_is = "Bo"
package.loaded.hub = { view = function() return { hub = hub_is } end }
package.loaded.services = { rescan = function() end }
package.loaded.page_chat = { post = function(_, _, text) chats[#chats + 1] = text end }
package.loaded.tools = { render_guard = function() end }
local function tmp() return "T:/" .. ME .. "/render" end
package.loaded.bgrender = setmetatable({
  on = function() return bnc[ME] end,
  time_limit = function(secs) return 180 + secs * 8 end,
  launch_job = function(dir) jobs[#jobs + 1] = { who = ME, dir = dir, age = 0 } end,
  end_job = function(dir) for _, j in ipairs(jobs) do if j.dir == dir and j.who == ME then j.ended = true end end; return true end,
}, { __index = function(_, k) if k == "TMP" then return tmp() end end })

-- The hidden REAPER's render of a job: each selected track a stem (the master mix for RENDER_SETTINGS 0), named for its track (a second of
-- one name "-001"), its sound standing for everything that shapes it: its block in the copy, minus SEL, with this computer's studio folder
-- written <ROOT>, so the same project gives the same samples on any computer, and a file not on this computer shows. FLACs beside.
local function render(text, who, into)
  local mix = text:match("\n%s*RENDER_SETTINGS 0\n") ~= nil
  local pattern = text:match("\n%s*RENDER_PATTERN ([^\n]*)")
  local root, made, out, all = ROOT[who], {}, {}, {}
  for block in text:gmatch("\n  <TRACK .-\n  >") do
    local sel = block:match("\n%s*SEL 1") ~= nil
    local body = block:gsub("\n%s*SEL %d", "")
    for p in body:gmatch('FILE "([^"]+)"') do if not FS[p] then body = body .. "\nMISSING " .. p end end
    body = body:gsub(root:gsub("%p", "%%%0"), "<ROOT>")
    local muted = block:match("\n%s*MUTESOLO 1") ~= nil
    if not muted then all[#all + 1] = body end
    if not mix and sel then
      local name = block:match("\n%s*NAME ([^\n]*)")
      local f = name
      if made[name:lower()] then f = string.format("%s-%03d", name, made[name:lower()]) end
      made[name:lower()] = (made[name:lower()] or 0) + 1
      out[f .. ".wav"] = block:match("\n%s*SILENT") and "SILENT" or ("PCM " .. body)
      out[f .. ".flac"] = "FLAC " .. body
    end
  end
  if mix then out[pattern .. ".wav"] = "PCM MIX " .. table.concat(all, "\n") end
  for f, data in pairs(out) do FS[into .. "/" .. f] = data end
end
local slow = { Bo = 12 } -- (seconds each hidden REAPER takes: Bo's long enough to drop in the middle)
local function hidden_reapers()
  for _, j in ipairs(jobs) do
    if not j.ended and not j.finished and up[j.who] then
      j.age = j.age + 1
      if j.age >= (slow[j.who] or 3) then
        render(FS[j.dir .. "/job.rpp"], j.who, j.dir)
        FS[j.dir .. "/passes.txt"] = "2\n"
        j.finished = true
      end
    end
  end
end
-- Syncthing: the song's stems and mixes folders carried between the computers that are up, every few seconds.
local function sync_folders()
  if not syncthing then return end
  local got = {}
  for p, data in pairs(FS) do
    for u, r in pairs(ROOT) do
      local rel = up[u] and p:sub(1, #r + 1) == r .. "/" and p:sub(#r + 2)
      if rel and (rel:match("^Song/stems/") or rel:match("^Song/mixes/")) then got[rel] = got[rel] or data end
    end
  end
  for rel, data in pairs(got) do for u, r in pairs(ROOT) do if up[u] and not FS[r .. "/" .. rel] then FS[r .. "/" .. rel] = data end end end
end

-- Each computer its own bounces (its own R and H), as each REAPER loads its own copy.
local inst = {}
for u in pairs(ROOT) do inst[u] = assert(loadfile("lib/bounces.lua"))() end
local function flush()
  while #queue > 0 do
    local m = table.remove(queue, 1)
    if up[m.to] then local was = ME; ME = m.to; inst[m.to].on_msg("P-" .. m.to, cfgs[m.to], B, m.d); ME = was end
  end
end
local ORDER = { "James", "Bo", "Cy", "Gus", "Old" }
local function step(n)
  for s = 1, n or 1 do
    clock = clock + 1
    for _, u in ipairs(ORDER) do if up[u] then ME = u; inst[u].tick("P-" .. u, cfgs[u], B); flush() end end
    hidden_reapers()
    if clock % 3 == 0 then sync_folders() end
    ME = "James"
  end
end

-- ---- 1. pure -----------------------------------------------------------------------------------------------------------------------------
local bx = inst.James
assert(bx.dest_ok("mixes") and bx.dest_ok("stems/2026-11-20 1400 James") and not bx.dest_ok("stems/../x") and not bx.dest_ok("stems/a/b")
  and not bx.dest_ok("other") and not bx.dest_ok("stems/") and not bx.dest_ok("stems/.hidden"), "where a share's files may go")
assert(bx.file_ok("Bass.wav") and not bx.file_ok("Bass.flac") and not bx.file_ok("../Bass.wav") and not bx.file_ok("a/b.wav"), "a share's file names")
do
  local text = '<REAPER_PROJECT\n  <TRACK {A}\n    NAME A\n    MUTESOLO 0 0 0\n    SEL 0\n    <ITEM\n      <SOURCE WAVE\n        FILE "C:\\J\\Studio\\Song\\a.wav" 1\n' ..
    '      >\n    >\n  >\n  <TRACK {B}\n    NAME B\n    MUTESOLO 1 0 0\n    SEL 1\n    <ITEM\n      <SOURCE WAVE\n        FILE "C:/Mine/b.wav"\n      >\n    >\n  >\n' ..
    '  <TRACK {C}\n    NAME C\n    MUTESOLO 1 0 0\n    SEL 0\n    <MUTEENV\n    >\n    <ITEM\n      <SOURCE WAVE\n        FILE c.wav\n      >\n    >\n  >\n>\n'
  local out, media = bx.prepare(text, { ["{A}"] = true }, "C:/J/Studio/", "/Users/cy/Studio")
  assert(out:find('FILE "/Users/cy/Studio/Song/a.wav" 1\n', 1, true), "a shared file moved to this computer's studio folder: " .. out)
  assert(out:find("NAME A\n    MUTESOLO 0 0 0\n    SEL 1\n", 1, true) and out:find("NAME B\n    MUTESOLO 1 0 0\n    SEL 0\n", 1, true), "SEL as the share says")
  assert(out:find('FILE "C:/Mine/b.wav"', 1, true), "a file outside the studio folder kept as it is")
  assert(#media == 2 and media[1] == "/Users/cy/Studio/Song/a.wav" and media[2] == "c.wav", "a muted track's media isn't needed, unless it has a mute envelope")
  assert(bx.missing(media, "/Users/cy/Studio", function() return true end) == "c.wav", "a bandmate's copy: only files in the studio folder")
  assert(bx.missing({ "/Users/cy/Studio/Song/a.wav" }, "/Users/cy/Studio", function() return false end) == "a.wav", "not here yet")
  assert(bx.missing({ "/Users/cy/Studio/Song/a.wav" }, "/Users/cy/Studio", function() return true end) == nil, "all here")
  assert(select(1, bx.prepare(text, nil, "C:/J/Studio", "C:/J/Studio")):find("NAME B\n    MUTESOLO 1 0 0\n    SEL 1\n", 1, true), "sel nil: as it was (a mix)")
end
do
  local s = bx.settings({ RENDER_FORMAT = "w", RENDER_NORMALIZE = 0 }, false, nil, 5, 9, band.LIMIT)
  assert(s.RENDER_SETTINGS == 3 and s.RENDER_PATTERN == "$track" and s.RENDER_BOUNDSFLAG == 0 and s.RENDER_STARTPOS == 5 and s.RENDER_ENDPOS == 9
    and s.RENDER_ADDTOPROJ == 2 and s.RENDER_NORMALIZE == 0 and s.RENDER_FORMAT == "w" and s.RENDER_FORMAT2 == band.FLAC, "stems: the same bounds everywhere, a FLAC for the passes")
  local m = bx.settings({ RENDER_NORMALIZE = 0 }, true, "Song mix", 0, 60, band.LIMIT)
  assert(m.RENDER_SETTINGS == 0 and m.RENDER_PATTERN == "Song mix" and m.RENDER_NORMALIZE == 64 and m.RENDER_BRICKWALL == band.LIMIT.RENDER_BRICKWALL, "a mix: Final mix's limiter")
end
do
  local ws, why = bx.workers({ Bo = "b", Cy = "c", Gus = "g", Old = "o", Hot = "h", Rec = "r" },
    { Bo = { cpu = 10, bnc = true }, Cy = { cpu = 30, bnc = true }, Gus = { cpu = 0, bnc = true }, Old = { cpu = 0 }, Hot = { cpu = 90, bnc = true },
      Rec = { cpu = 0, bnc = true, recording = true } }, { Gus = true }, 75)
  assert(#ws == 2 and ws[1].u == "Bo" and ws[2].u == "Cy" and ws[1].peer == "b", "who can: Bo and Cy")
  local w = table.concat(why, "; ")
  assert(w:find("Old can't render", 1, true) and w:find("Hot's computer is busy (90%)", 1, true) and w:find("Rec is recording", 1, true) and not w:find("Gus", 1, true),
    "why not, each (a guest not named): " .. w)
  local stems = { { guid = "A", cost = 100, group = "a" }, { guid = "B", cost = 60, group = "b" }, { guid = "C", cost = 50, group = "c" },
    { guid = "V1", cost = 10, group = "vox" }, { guid = "V2", cost = 10, group = "vox" }, { guid = "K", cost = 40, group = "k", only_me = true } }
  local plan = bx.split(stems, { { u = "Bo", cpu = 0 }, { u = "Me", cpu = 0 } }, function(u, s) return u == "Me" or not s.only_me end, "Me")
  local where = {}
  for u, gs in pairs(plan) do for _, g in ipairs(gs) do where[g] = u end end
  assert(where.K == "Me" and where.V1 and where.V1 == where.V2 and where.A and where.B and where.C, "each stem once; Vox and Vox together; K only here")
  assert(where.A ~= where.B, "the heaviest two apart")
  assert(next(bx.split({ { guid = "X", cost = 1 } }, { { u = "Bo", cpu = 0 } }, function() return false end, "Me")) == nil, "nobody can: left out")
  assert(bx.group_of(" Gtr/L. ") == "gtr_l" and bx.group_of("GTR_L") == "gtr_l", "file-name groups")
  local sh = { user = "Bo", state = "rendering", at = 100 }
  assert(bx.overdue(sh, { cpu = 10 }, 120) == nil and bx.overdue(sh, { cpu = 10 }, 131) == "Bo's computer stopped answering"
    and bx.overdue(sh, nil, 131) == "Bo's computer went away" and bx.overdue(sh, { recording = true }, 101) == "Bo started recording", "overdue")
  sh.state = "sent"
  assert(bx.overdue(sh, { cpu = 10 }, 131) == nil and bx.overdue(sh, { cpu = 10 }, 100 + bx.SYNC_WAIT + 1), "sent: Syncthing's time to bring it")
end

-- ---- 2. stems across the room, Bo dropping mid-render -------------------------------------------------------------------------------------
ME = "James"
bx.ask("P-James", "track", false)
step(1)
local R = bx._state()
assert(R and R.active, "started: " .. table.concat(logs, " | "))
local copy = FS[R.copy]
assert(copy and copy:find("RENDER_SETTINGS 3", 1, true) and copy:find("RENDER_RANGE 0 60", 1, true), "the copy saved set up for the render")
assert(copy:find("NAME Click %(mine%)\n    MUTESOLO 1") and mutes[tracks[#tracks]] == 0, "your local track muted in the copy only")
for k, v in pairs(MINE) do assert(proj_render[k] == v, "your render settings put back: " .. k) end
-- What rendering the copy here, every stem at once, makes: the reference.
local everything = {}
for _, g in ipairs(R.order) do everything[g] = true end
local ref_dir = "T:/ref"
render((bx.prepare(copy, everything, JR, JR)), "James", ref_dir)
local reference = {}
for _, f in ipairs(list(ref_dir)) do if f:match("%.wav$") and FS[ref_dir .. "/" .. f] ~= "SILENT" then reference[f] = FS[ref_dir .. "/" .. f] end end
assert(reference["Vox.wav"] and reference["Vox-001.wav"] and not reference["Pad.wav"] and not reference["Click (mine).wav"], "the reference's files")

local by_user, guid_of = {}, {}
for _, t in ipairs(tracks) do guid_of[t.name] = guid_of[t.name] or t.guid end
for _, sh in ipairs(R.shares) do by_user[sh.user] = sh end
local function who_has(name)
  for _, t in ipairs(tracks) do
    if t.name == name then for _, sh in ipairs(R.shares) do for _, g in ipairs(sh.guids) do if g == t.guid then return sh.user end end end end
  end
end
assert(by_user.Bo and by_user.Cy and by_user.James and not by_user.Gus and not by_user.Old, "shared out to Bo, Cy and here; never the guest or Old")
assert(who_has("Keys") == "James", "the opaque sampler's stem stays here")
assert(who_has("Verb") ~= "Cy" and who_has("Gtr") ~= "Cy", "Verb hears Gtr's plug-in through a send: not Cy, who lacks it")
assert(who_has("Piano") ~= "Cy", "Cy lacks the piano's sample")
local v1, v2
for _, t in ipairs(tracks) do if t.name == "Vox" then for _, sh in ipairs(R.shares) do for _, g in ipairs(sh.guids) do if g == t.guid then if v1 then v2 = sh.user else v1 = sh.user end end end end end end
assert(v1 and v1 == v2, "both Vox tracks in one share")
local bo_stems = #by_user.Bo.guids
-- Bo drops while rendering his share.
for _ = 1, 10 do
  step(1)
  if by_user.Bo.state == "rendering" then break end
end
assert(by_user.Bo.state == "rendering", "Bo got the copy and renders: " .. by_user.Bo.state)
local bo_job
for _, j in ipairs(jobs) do if j.who == "Bo" then bo_job = j end end
assert(bo_job and not bo_job.finished and FS[bo_job.dir .. "/job.rpp"]:find("D:/Bo/Studio/Song/Audio/", 1, true), "Bo's hidden REAPER on his own copy of the files")
up.Bo = false
step(bx.STALL + 15)
assert(by_user.Bo.state == "failed" and by_user.Bo.why == "Bo's computer went away", "Bo's share failed: " .. tostring(by_user.Bo.why))
local redone = table.concat(R.redone, " ")
assert(redone:find("Bo's: Bo's computer went away; redone by", 1, true), "said: " .. redone)
for _ = 1, 40 do if not R.active then break end; step(1) end
assert(not R.active, "finished: " .. table.concat(logs, " | "))
local dest = JR .. "/Song/" .. R.dest
local got = {}
for _, f in ipairs(list(dest)) do if f:match("%.wav$") then got[f] = FS[dest .. "/" .. f] end end
for f, data in pairs(reference) do assert(got[f] == data, "the same as rendering it here: " .. f .. " = " .. tostring(got[f])) end
for f in pairs(got) do assert(reference[f], "nothing else: " .. f) end
assert(not got["Pad.wav"], "the silent stem dropped")
assert(not next((function() local t = {}; for _, f in ipairs(list(dest)) do if not f:match("%.wav$") then t[f] = true end end; return t end)()), "no FLACs in the stems folder")
local by = {}
for _, sh in ipairs(R.shares) do if sh.state == "done" then by[sh.user] = true end end
assert(by.Cy and by.James and not by.Bo, "rendered by Cy and here")
assert(chats[#chats]:find("Stems for whoever mixes: ", 1, true) and chats[#chats]:find("rendered by Cy, you", 1, true), "the chat says so: " .. tostring(chats[#chats]))
assert(bo_stems > 0, "Bo had stems")
assert(not FS[R.copy], "the copy tidied")
for _ = 1, bx.KEEP_SAYING + 5 do step(1) end
ME = "Cy"
assert(next(select(2, inst.Cy._state())) == nil, "Cy forgets its share once it's said for long enough")
ME = "James"
assert(bx.health_row(cfgs.James)[4]:find("stems in Song/stems/", 1, true), "Health says where: " .. tostring(bx.health_row(cfgs.James)[4]))

-- ---- 3. a mix on the hub, over the link alone; then a hub that can't ---------------------------------------------------------------------
up.Bo, syncthing, logs = true, false, {}
for _, u in ipairs(ORDER) do ME = u; inst[u]._reset() end
ME = "James"
for _, t in ipairs(tracks) do if t.name == "Keys" then t.fx[1].sounds = false end end
bx.ask("P-James", "mix", false)
step(1)
R = bx._state()
assert(R.active and #R.shares == 1 and R.shares[1].user == "James" and R.redone[1]:find("hub (Bo) can't now", 1, true), "an opaque sampler in the mix: here")
for _ = 1, 20 do if not R.active then break end; step(1) end
for _, u in ipairs(ORDER) do ME = u; inst[u]._reset() end
ME = "James"
for _, t in ipairs(tracks) do if t.name == "Keys" then t.fx[1].sounds = {} end end -- (a sampler that names no sound: nothing to lack)
bx.ask("P-James", "mix", false)
step(1)
R = bx._state()
assert(R.active and #R.shares == 1 and R.shares[1].user == "Bo", "the mix goes to the hub, Bo")
local mref = "T:/mref"
render((bx.prepare(FS[R.copy], nil, JR, JR)), "James", mref)
local mname = R.name .. ".wav"
assert(FS[mref .. "/" .. mname]:find("MISSING", 1, true) == nil, "the reference mix")
for _ = 1, 30 do if not R.active then break end; step(1) end
assert(not R.active and R.shares[1].state == "done", "the mix done on Bo: " .. table.concat(logs, " | "))
assert(FS[JR .. "/Song/mixes/" .. mname] == FS[mref .. "/" .. mname], "the hub's mix, the same as here, over the link (no Syncthing)")
assert(not FS[JR .. "/Song/mixes/" .. mname]:find("Click", 1, true), "your local track left out")

for _, u in ipairs(ORDER) do ME = u; inst[u]._reset() end
ME = "James"
plugins.Bo.reacomp = false
bx.ask("P-James", "mix", false)
step(1)
R = bx._state()
assert(R.active and R.shares[1].user == "James" and R.redone[1]:find("Rendered here: the song's hub (Bo) can't now", 1, true), "the hub can't: here, and said")
for _ = 1, 20 do if not R.active then break end; step(1) end
assert(not R.active and R.shares[1].state == "done" and FS[JR .. "/Song/mixes/" .. R.name .. ".wav"], "rendered here")

-- ---- 4. a helper's person starts recording (redone here); a dropout here while playing (nobody left: stopped) ---------------------------
plugins.Bo.reacomp, syncthing = true, true
for _, u in ipairs(ORDER) do ME = u; inst[u]._reset() end
ME = "James"
bx.ask("P-James", "mix", false)
step(1)
R = bx._state()
assert(R.active and R.shares[1].user == "Bo", "Bo renders the mix")
step(1)
xrun.Bo = 5 -- (a dropout on Bo while his REAPER is stopped: silence, the share renders on)
step(1)
assert(R.shares[1].state ~= "failed", "a dropout nobody heard doesn't end it")
recording.Bo, playstate.Bo = true, 5
step(2)
assert(R.shares[1].state == "failed" and R.shares[1].why:find("Bo started recording", 1, true), "Bo's person comes first: " .. tostring(R.shares[1].why))
local ended = false
for _, j in ipairs(jobs) do if j.who == "Bo" and j.ended then ended = true end end
assert(ended, "Bo's hidden REAPER ended")
assert(R.shares[2] and R.shares[2].user == "James" and R.redone[1]:find("redone by you", 1, true), "redone here: " .. tostring(R.redone[1]))
playstate.James, xrun.James = 1, 7 -- (playing here, and a dropout)
step(2)
assert(R.shares[2].state == "failed" and R.shares[2].why == "your REAPER had an audio dropout", "here too: " .. tostring(R.shares[2].why))
assert(R.active == false and R.redone[2]:find("nobody can redo it", 1, true), "nobody left: stopped")
assert(bx.health_row(cfgs.James)[4]:find("Stopped: try again", 1, true), "Health says it stopped: " .. tostring(bx.health_row(cfgs.James)[4]))
print("ok bounces")
