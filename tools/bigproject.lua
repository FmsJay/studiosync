-- A big test project for StudioSync (James, rt: "make sure no issues with bigger projects - lots of tracks, plugins and items and MIDI, plus
-- long"). One model, two forms of it: REAPER's own .rpp text (tests/reaper/big_project.lua writes it and opens it in REAPER) and the track and
-- item chunks the offline harness serves through a fake REAPER (tests/test_0_60_rt_bigproj.lua). Pure Lua 5.4, no REAPER calls.
--   local G = require("bigproject"); local m = G.model(); local text = G.rpp(m)
-- Every name, GUID and value comes from a seeded generator, so the same options make the same bytes on every computer.
-- What's in it by default (G.DEFAULT): 150 tracks in 10 folders with 12 sends into 4 FX returns, 520 plug-ins (stock JS ones that load
-- everywhere, plus every 4th a stand-in VST with a 16 KB saved state that REAPER keeps as it is while it's missing), 4,000 items over 7
-- minutes (60 of them MIDI with dense notes and CC), volume, pan and plug-in automation, 50 regions and 20 markers, 4 tempo changes.
local G = {}

G.DEFAULT = {
  seed = 1, tracks = 150, folders = 10, returns = 4, sends = 12, fx = 520, big_every = 4, big_kb = 16, items = 4000, midi = 60,
  notes = 1200, ccs = 600, env_points = 120, regions = 50, markers = 20, length = 420, bpm = 120, wav = "big_silence.wav", wav_secs = 10,
}

-- (a 31-bit LCG: the same sequence on any Lua 5.3+)
local function rng(seed)
  local s = seed % 2147483647
  if s <= 0 then s = s + 2147483646 end
  return function(a, b)
    s = (s * 48271) % 2147483647
    if not a then return s / 2147483647 end
    return a + s % (b - a + 1)
  end
end
local function guid(r)
  local function hx(n) local t = {}; for i = 1, n do t[i] = string.format("%X", r(0, 15)) end; return table.concat(t) end
  return "{" .. hx(8) .. "-" .. hx(4) .. "-" .. hx(4) .. "-" .. hx(4) .. "-" .. hx(12) .. "}"
end
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function b64_lines(r, bytes)
  local out, line = {}, {}
  local chars = math.floor(bytes * 4 / 3 / 4) * 4
  for i = 1, chars do
    local k = r(1, 64)
    line[#line + 1] = B64:sub(k, k)
    if #line == 128 or i == chars then out[#out + 1] = table.concat(line); line = {} end
  end
  return out
end
local function f(x) return string.format("%.10g", x) end

-- The model: { opts, tracks = { { name, guid, depth, color, vol, pan, fx = { {...} }, sends = { track index }, env = { points }, items } },
-- regions, markers, tempo }. Track index from 1; `depth` is REAPER's I_FOLDERDEPTH (1 opens a folder, -1 closes one).
function G.model(o)
  local opts = {}
  for k, v in pairs(G.DEFAULT) do opts[k] = v end
  for k, v in pairs(o or {}) do opts[k] = v end
  local r = rng(opts.seed)
  local m = { opts = opts, tracks = {}, regions = {}, markers = {}, tempo = {} }
  local n, nret = opts.tracks, opts.returns
  local body = n - nret -- (the returns sit at the bottom, outside the folders)
  local per = math.max(2, math.floor(body / math.max(1, opts.folders)))
  local midi_tracks = math.max(1, math.ceil(opts.midi / 10))
  for i = 1, n do
    local t = { i = i, guid = guid(r), color = 0x1000000 | r(0, 0xFFFFFF), vol = 0.3 + r() * 0.9, pan = (r() - 0.5) * 1.6, fx = {}, sends = {}, items = {},
      depth = 0, mute = r(1, 40) == 1 and 1 or 0 }
    if i > body then t.name, t.ret = "FX Return " .. (i - body), true
    else
      local pos, folder = (i - 1) % per, (i - 1) // per
      t.name = string.format("Track %d", i)
      if folder < opts.folders then -- (the tracks past the last folder sit at the top level)
        if pos == 0 then t.depth, t.name = 1, "Folder " .. (folder + 1) elseif pos == per - 1 then t.depth = -1 end
      end
    end
    t.midi = not t.ret and t.depth ~= 1 and i > body - midi_tracks - 1 and i < body
    m.tracks[i] = t
  end
  -- sends: from body tracks into the returns
  for s = 1, opts.sends do
    local src = m.tracks[r(1, body)]
    src.sends[#src.sends + 1] = body + r(1, nret)
  end
  -- plug-ins: round-robin over every track, every `big_every`th a stand-in with a big saved state
  local JS = { "utility/volume", "utility/volume_pan", "delay/delay", "dynamics/general_dynamics", "utility/phase_adjust" } -- (stock JSFX: on every REAPER)
  for k = 1, opts.fx do
    local t = m.tracks[(k - 1) % n + 1]
    local fx = { guid = guid(r), bypass = r(1, 30) == 1 and 1 or 0 }
    if opts.big_every > 0 and k % opts.big_every == 0 then
      fx.kind, fx.name, fx.lines = "VST", "VST: StudioSync Big State Test (none)", b64_lines(r, opts.big_kb * 1024)
    else
      fx.kind, fx.name = "JS", JS[r(1, #JS)]
      local ps = {}
      for p = 1, 8 do ps[p] = f(math.floor(r() * 1000) / 100) end
      fx.params = table.concat(ps, " ")
    end
    t.fx[#t.fx + 1] = fx
  end
  -- automation: every track a volume envelope; every 3rd a pan one; every 10th its first plug-in's first knob
  for _, t in ipairs(m.tracks) do
    local function env(lo, hi)
      local pts, step = {}, opts.length / opts.env_points
      for p = 0, opts.env_points - 1 do pts[#pts + 1] = { p * step, lo + r() * (hi - lo), r(0, 2) } end
      return pts
    end
    t.volenv = env(0.2, 1.2)
    if t.i % 3 == 0 then t.panenv = env(-0.8, 0.8) end
    if t.i % 10 == 0 and t.fx[1] then t.parmenv = env(0, 1) end
  end
  -- items: MIDI ones on the MIDI tracks back to back (each 1/10 of the song), the rest audio over the other body tracks
  local audio_tracks, mtracks = {}, {}
  for _, t in ipairs(m.tracks) do
    if t.midi then mtracks[#mtracks + 1] = t elseif not t.ret and t.depth ~= 1 then audio_tracks[#audio_tracks + 1] = t end
  end
  local item_n = 0
  local function new_item(t, pos, len, midi)
    item_n = item_n + 1
    local it = { n = item_n, pos = pos, len = len, guid = guid(r), tguid = guid(r), midi = midi, name = (midi and "MIDI " or "Take ") .. item_n,
      soffs = midi and 0 or r() * (opts.wav_secs - 1), vol = 0.5 + r() * 0.5, mute = r(1, 50) == 1 and 1 or 0 }
    t.items[#t.items + 1] = it
    return it
  end
  local mlen = opts.length / 10
  for k = 1, math.min(opts.midi, opts.items) do
    local t = mtracks[(k - 1) % #mtracks + 1]
    local it = new_item(t, ((k - 1) // #mtracks) % 10 * mlen, mlen, true)
    -- dense notes: chords on a 16th grid, every note with its note-off; CC 1 and 11 sweeps between them (960 ticks a quarter)
    local ticks = math.floor(mlen * opts.bpm / 60 * 960)
    local evs = {}
    local step = math.max(1, math.floor(ticks / math.max(1, opts.notes / 3)))
    local made = 0
    for at = 0, ticks - step, step do
      if made >= opts.notes then break end
      local root = 36 + r(0, 36)
      for c = 0, 2 do
        if made < opts.notes then
          local len = math.max(30, step - 10)
          evs[#evs + 1] = { at, 0x90, root + c * 4, 40 + r(0, 80) }
          evs[#evs + 1] = { at + len, 0x80, root + c * 4, 0 }
          made = made + 1
        end
      end
    end
    local cstep = math.max(1, math.floor(ticks / math.max(1, opts.ccs)))
    for c = 0, opts.ccs - 1 do evs[#evs + 1] = { c * cstep, 0xB0, c % 2 == 0 and 1 or 11, r(0, 127) } end
    table.sort(evs, function(a, b) if a[1] ~= b[1] then return a[1] < b[1] end; return a[2] < b[2] end)
    it.events, it.ticks = evs, ticks
  end
  local audio_n = opts.items - math.min(opts.midi, opts.items)
  local per_track = math.max(1, math.ceil(audio_n / math.max(1, #audio_tracks)))
  local alen = opts.length / per_track
  for k = 1, audio_n do
    local t = audio_tracks[(k - 1) % #audio_tracks + 1]
    local slot = (k - 1) // #audio_tracks
    new_item(t, slot * alen + r() * alen * 0.1, alen * (0.6 + r() * 0.35), false)
  end
  m.n_items = item_n
  for k = 1, opts.regions do
    local a = (k - 1) * opts.length / opts.regions
    m.regions[k] = { a, a + opts.length / opts.regions * 0.95, "Part " .. k, 0x1000000 | r(0, 0xFFFFFF) }
  end
  for k = 1, opts.markers do m.markers[k] = { (k - 0.5) * opts.length / opts.markers, "Cue " .. k } end
  m.tempo = { { 0, opts.bpm }, { opts.length * 0.25, opts.bpm + 8 }, { opts.length * 0.5, opts.bpm - 6 }, { opts.length * 0.75, opts.bpm } }
  return m
end

-- ---- chunks, as REAPER writes them -------------------------------------------------------------------------------------------------------
-- ext: an object's P_EXT keys -> value (the fake REAPER's; REAPER writes them in an <EXT> block inside the chunk)
local function ext_block(out, ext, tag)
  if not ext or not next(ext) then return end
  local keys = {}
  for k in pairs(ext) do keys[#keys + 1] = k end
  table.sort(keys)
  out[#out + 1] = "<" .. (tag or "EXT")
  for _, k in ipairs(keys) do out[#out + 1] = k .. " " .. ext[k] end
  out[#out + 1] = ">"
end
local function midi_lines(out, it)
  out[#out + 1] = "<SOURCE MIDI"
  out[#out + 1] = "HASDATA 1 960 QN"
  out[#out + 1] = "CCINTERP 32"
  local last = 0
  for _, e in ipairs(it.events) do
    out[#out + 1] = string.format("E %d %x %02x %02x", e[1] - last, e[2], e[3], e[4])
    last = e[1]
  end
  out[#out + 1] = string.format("E %d b0 7b 00", math.max(0, it.ticks - last))
  out[#out + 1] = "GUID " .. it.tguid
  out[#out + 1] = "IGNTEMPO 0 120 4 4"
  out[#out + 1] = "SRCCOLOR 0"
  out[#out + 1] = "VELLANE -1 100 0"
  out[#out + 1] = "CFGEDITVIEW 0 0.12 64 12 0 -1 0 0 0 0.5"
  out[#out + 1] = "KEYSNAP 0"
  out[#out + 1] = "TRACKSEL 0"
  out[#out + 1] = "EVTFILTER 0 -1 -1 -1 -1 0 0 0 0 -1 -1 -1 -1 0 -1 0 -1 -1"
  out[#out + 1] = "CFGEDIT 1 1 0 1 0 0 1 1 1 1 1 0.125 0 0 1200 800 0 0 0 0 0 0 0 0 0 0.5 0 0 1 64"
  out[#out + 1] = ">"
end
-- One item. it.ext: its P_EXT; it.chunk_extra: lines a test added (an edit).
function G.item_chunk(m, it, iid)
  local out = { "<ITEM", "POSITION " .. f(it.pos), "SNAPOFFS 0", "LENGTH " .. f(it.len), "LOOP " .. (it.midi and 0 or 1), "ALLTAKES 0",
    "FADEIN 1 0.01 0 1 0 0 0", "FADEOUT 1 0.01 0 1 0 0 0", "MUTE " .. it.mute .. " 0", "SEL 0", "IGUID " .. it.guid, "IID " .. (iid or it.n) }
  ext_block(out, it.ext, "EXT")
  out[#out + 1] = 'NAME "' .. it.name .. '"'
  out[#out + 1] = "VOLPAN " .. f(it.vol) .. " 0 1 -1"
  out[#out + 1] = "SOFFS " .. f(it.soffs)
  out[#out + 1] = "PLAYRATE 1 1 0 -1 0 0.0025"
  out[#out + 1] = "CHANMODE 0"
  out[#out + 1] = "GUID " .. it.tguid
  if it.midi then midi_lines(out, it)
  else
    out[#out + 1] = "<SOURCE WAVE"
    out[#out + 1] = 'FILE "' .. m.opts.wav .. '"'
    out[#out + 1] = ">"
  end
  out[#out + 1] = ">"
  return table.concat(out, "\n") .. "\n"
end
local function env_block(out, tag, pts, extra)
  out[#out + 1] = "<" .. tag
  if extra then out[#out + 1] = extra end
  out[#out + 1] = "EGUID {00000000-0000-0000-0000-" .. string.format("%012X", #out) .. "}"
  out[#out + 1] = "ACT 1 -1"
  out[#out + 1] = "VIS 1 1 1"
  out[#out + 1] = "LANEHEIGHT 0 0"
  out[#out + 1] = "ARM 0"
  out[#out + 1] = "DEFSHAPE 0 -1 -1"
  for _, p in ipairs(pts) do out[#out + 1] = "PT " .. f(p[1]) .. " " .. f(p[2]) .. " " .. p[3] end
  out[#out + 1] = ">"
end
-- A track's chunk, its items included unless `no_items` (REAPER's GetTrackStateChunk has them). t.ext: its P_EXT. index_of(track number from
-- 1) -> 0-based index for AUXRECV (the model's own order by default).
function G.track_chunk(m, t, no_items, item_chunk)
  local out = { "<TRACK " .. t.guid, 'NAME "' .. t.name .. '"', "PEAKCOL " .. (t.color & 0xFFFFFF), "BEAT -1", "AUTOMODE 0",
    "VOLPAN " .. f(t.vol) .. " " .. f(t.pan) .. " -1 -1 1", "MUTESOLO " .. t.mute .. " 0 0", "IPHASE 0", "PLAYOFFS 0 1",
    "ISBUS " .. (t.depth == 1 and "1 1" or t.depth == -1 and "2 -1" or "0 0"), "BUSCOMP 0 0 0 0 0", "SHOWINMIX 1 0.6667 0.5 1 0.5 0 0 0",
    "FREEMODE 0", "SEL 0", "REC 0 0 1 0 0 0 0 0", "VU 2", "TRACKHEIGHT 0 0 0 0 0 0", "INQ 0 0 0 0.5 100 0 0 100", "NCHAN 2",
    "FX 1", "TRACKID " .. t.guid, "PERF 0", "MIDIOUT -1", "MAINSEND 1 0" }
  for _, src in ipairs(t.recv or {}) do out[#out + 1] = "AUXRECV " .. (src - 1) .. " 0 1 0 0 0 0 0 0 -1:U 0 -1 ''" end
  env_block(out, "VOLENV2", t.volenv, "VOLTYPE 1")
  if t.panenv then env_block(out, "PANENV2", t.panenv) end
  ext_block(out, t.ext, "EXT")
  if #t.fx > 0 then
    out[#out + 1] = "<FXCHAIN"
    for _, l in ipairs({ "WNDRECT 0 0 0 0", "SHOW 0", "LASTSEL 0", "DOCKED 0" }) do out[#out + 1] = l end
    for k, fx in ipairs(t.fx) do
      out[#out + 1] = "BYPASS " .. fx.bypass .. " 0 0"
      if fx.kind == "VST" then
        out[#out + 1] = '<VST "' .. fx.name .. '" ssbigstate.dll 0 "" 1397969479<56535453534253746174657465737400> ""'
        for _, l in ipairs(fx.lines) do out[#out + 1] = l end
        out[#out + 1] = "AAAQAAAA"
      else
        out[#out + 1] = "<JS " .. fx.name .. ' ""'
        out[#out + 1] = fx.params .. " - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -"
      end
      out[#out + 1] = ">"
      if k == 1 and t.parmenv then env_block(out, "PARMENV 0 0 1 0", t.parmenv) end
      out[#out + 1] = "FLOATPOS 0 0 0 0"
      out[#out + 1] = "FXID " .. fx.guid
      out[#out + 1] = "WAK 0 0"
    end
    out[#out + 1] = ">"
  end
  local head = table.concat(out, "\n") .. "\n"
  if no_items then return head .. ">\n" end
  local parts = { head }
  for _, it in ipairs(t.items) do parts[#parts + 1] = (item_chunk or G.item_chunk)(m, it) end
  parts[#parts + 1] = ">\n"
  return table.concat(parts)
end

-- The receives each track holds (AUXRECV lines are on the receiving track): from the model's sends.
local function wire_receives(m)
  for _, t in ipairs(m.tracks) do t.recv = nil end
  for _, t in ipairs(m.tracks) do
    for _, dst in ipairs(t.sends) do
      local d = m.tracks[dst]
      d.recv = d.recv or {}
      d.recv[#d.recv + 1] = t.i
    end
  end
end
G.wire_receives = wire_receives

-- The whole project as REAPER's .rpp text.
function G.rpp(m)
  wire_receives(m)
  local o = m.opts
  local out = { '<REAPER_PROJECT 0.1 "7.0/x64" 1795100000', "  RIPPLE 0", "  GRID 3199 8 1 8 1 0 0 0", "  TIMEMODE 1 5 -1 30 0 0 -1",
    "  PANMODE 3", "  CURSOR 0", "  ZOOM 4 0 0", "  LOOP 0", "  SAMPLERATE 48000 0 0", "  TEMPO " .. o.bpm .. " 4 4", "  PLAYRATE 1 0 0.25 4",
    "  MASTERAUTOMODE 0", "  MASTER_NCH 2 2", "  MASTER_VOLUME 1 0 -1 -1 1", "  MASTER_FX 1", "  MASTER_SEL 0" }
  local id = 0
  for k, rg in ipairs(m.regions) do
    id = id + 1
    out[#out + 1] = string.format('  MARKER %d %s "%s" 1 %d', k, f(rg[1]), rg[3], rg[4])
    out[#out + 1] = string.format('  MARKER %d %s "" 1', k, f(rg[2]))
  end
  for k, mk in ipairs(m.markers) do out[#out + 1] = string.format('  MARKER %d %s "%s" 0', #m.regions + k, f(mk[1]), mk[2]) end
  out[#out + 1] = "  <TEMPOENVEX"
  out[#out + 1] = "    EGUID {7E6F0000-0000-0000-0000-000000000001}"
  out[#out + 1] = "    ACT 1 -1"
  out[#out + 1] = "    VIS 1 0 1"
  out[#out + 1] = "    LANEHEIGHT 0 0"
  out[#out + 1] = "    ARM 0"
  out[#out + 1] = "    DEFSHAPE 1 -1 -1"
  for _, p in ipairs(m.tempo) do out[#out + 1] = "    PT " .. f(p[1]) .. " " .. f(p[2]) .. " 1 262148" end
  out[#out + 1] = "  >"
  local text = { table.concat(out, "\n") .. "\n" }
  for _, t in ipairs(m.tracks) do text[#text + 1] = G.track_chunk(m, t) end
  text[#text + 1] = ">\n"
  return table.concat(text)
end

-- A silent mono 16-bit WAV of `secs` (the one file every audio item plays, looped): REAPER finds it beside the .rpp, so nothing is offline.
function G.wav(secs, rate)
  rate = rate or 48000
  local n = math.floor(secs * rate)
  local data = n * 2
  local hdr = "RIFF" .. string.pack("<I4", 36 + data) .. "WAVEfmt " .. string.pack("<I4I2I2I4I4I2I2", 16, 1, 1, rate, rate * 2, 2, 16) ..
    "data" .. string.pack("<I4", data)
  return hdr .. string.rep("\0", data)
end

-- Numbers to print beside a measurement: how big the model is.
function G.stats(m)
  local s = { tracks = #m.tracks, fx = 0, big = 0, items = 0, midi = 0, notes = 0, ccs = 0, env_points = 0 }
  for _, t in ipairs(m.tracks) do
    s.fx = s.fx + #t.fx
    for _, fx in ipairs(t.fx) do if fx.kind == "VST" then s.big = s.big + 1 end end
    s.env_points = s.env_points + #t.volenv + (t.panenv and #t.panenv or 0) + (t.parmenv and #t.parmenv or 0)
    for _, it in ipairs(t.items) do
      s.items = s.items + 1
      if it.midi then
        s.midi = s.midi + 1
        for _, e in ipairs(it.events) do if e[2] == 0x90 then s.notes = s.notes + 1 elseif e[2] == 0xB0 then s.ccs = s.ccs + 1 end end
      end
    end
  end
  return s
end

return G
