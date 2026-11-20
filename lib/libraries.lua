-- Who has which library (docs/realtime-roadmap.md, rt). A sampler's MIDI part printed whenever its sampler was one by name
-- (prints.SAMPLERS), since two computers with the same plug-in can hold different libraries. Now each computer says which of the sounds
-- the studio's songs use it has, and the part prints only when someone lacks one, for the samplers whose state says what they play:
--   - ReaSamplOmatic5000: its files (FILE0, FILE1...: REAPER's own named config parms, documented in the API);
--   - any listed sampler whose saved state names its files by path (fxfiles.paths: plain, UTF-16 or base64): audio files and SoundFonts as
--     they are, an .sfz with the samples it names (the open SFZ format: sample=, default_path=), a Decent Sampler .dspreset with the
--     samples its XML names (path="..."). Whether a given sampler writes such a path into its state is its own business: sforzando and
--     Decent Sampler are expected to, and are read only if they do.
-- Opaque, so as before (a print whenever whoever changed the part has the chain): Kontakt and Komplete Kontrol (.nki and NI's own formats),
-- EZdrummer, EZkeys, EZbass, Superior Drummer, Addictive Drums and Keys, BFD, Spitfire's players, SampleTank, HALion, Battery, and any
-- sampler whose state names no file, or a file of a kind not above. Their states are the vendor's own binary: a library name read out of
-- one would be a guess, and a guess wrong is a silent part. A JSFX file slider saves an index into a folder's listing, not a name: not read.
-- A plug-in not on prints.SAMPLERS isn't looked at here (it prints only when someone lacks the plug-in, as before).
-- Each computer publishes <shared folder>/libraries/<user>.json: { user, os, time, have = { id... } }, an id being a short hash of a file's
-- path (fxfiles.key; a preset's by its place in the preset folder, content.id): no path, folder or file name leaves the computer. Only
-- the sounds and files the studio's songs use, as each song is open here: never a listing of anyone's drives. A computer that hasn't said
-- yet (the song not opened there since) lacks them all: a print, as before.
local band = require("band")
local libraries = { EVERY = 60, KEEP = 20000, CHUNK_MAX = 8 * 1024 * 1024, SAMPLES_MAX = 4096, DIR = "libraries" }
libraries.AUDIO = { wav = true, w64 = true, flac = true, aif = true, aiff = true, ogg = true, mp3 = true, opus = true, sf2 = true }

local function ext_of(p) return (tostring(p or ""):match("%.(%w+)$") or ""):lower() end
local function dir_of(p) return (tostring(p):gsub("\\", "/"):match("^(.*)/[^/]*$")) end
local function absolute(p) return p:match("^%a:[\\/]") ~= nil or p:sub(1, 1) == "/" end
local function join(dir, rel)
  rel = rel:gsub("\\", "/")
  if absolute(rel) or not dir then return rel end
  return dir .. "/" .. rel:gsub("^%./", "")
end
function libraries.id(path) return require("mirror").hash(require("fxfiles").key(path)) end

-- ---- pure ----------------------------------------------------------------------------------------------------------------------------
-- An .sfz's samples, as paths (relative ones from `dir`, the .sfz's folder): its sample= opcodes after any default_path=. A value runs to
-- the next opcode on the line (sample paths may hold spaces). nil where it can't be followed: #include, #define'd $variables, or more than
-- SAMPLES_MAX. Generated sounds (*sine, *silence) aren't files. Pure.
function libraries.sfz_samples(text, dir)
  text = tostring(text or ""):gsub("/%*.-%*/", ""):gsub("//[^\n]*", "")
  if text:find("#include", 1, true) or text:find("$", 1, true) then return nil end
  local out, default = {}, ""
  for line in text:gmatch("[^\r\n]+") do
    local marks = {}
    for s, name in line:gmatch("()([%w_]+)=") do
      if s == 1 or line:sub(s - 1, s - 1):match("[%s>]") then marks[#marks + 1] = { s = s, name = name } end
    end
    for k, m in ipairs(marks) do
      local v = line:sub(m.s + #m.name + 1, marks[k + 1] and marks[k + 1].s - 1 or #line):gsub("%s*<.*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
      local name = m.name:lower()
      if name == "default_path" then default = v:gsub("\\", "/")
      elseif name == "sample" and v ~= "" and v:sub(1, 1) ~= "*" then
        out[#out + 1] = join(dir, absolute(v) and v or (default .. v))
        if #out > libraries.SAMPLES_MAX then return nil end
      end
    end
  end
  return out
end
-- A Decent Sampler .dspreset's samples: every path="..." in its XML, relative ones from `dir`. nil past SAMPLES_MAX. Pure.
local ENTITY = { amp = "&", quot = '"', apos = "'", lt = "<", gt = ">" }
function libraries.dspreset_samples(text, dir)
  local out = {}
  for v in tostring(text or ""):gmatch('%spath%s*=%s*"([^"]*)"') do
    v = v:gsub("&(%a+);", function(e) return ENTITY[e] end)
    if v ~= "" then out[#out + 1] = join(dir, v) end
    if #out > libraries.SAMPLES_MAX then return nil end
  end
  return out
end
-- The sounds a sampler plays, from the paths its state names (fxfiles.paths): audio files and SoundFonts, an .sfz or .dspreset and the
-- samples in it (read(path) -> its text, or nil when it isn't on this computer: then the instrument file alone, which this computer lacks).
-- -> the paths, or nil: opaque (no path at all, or one of a kind that isn't a sound here: .nki, .nkm, .json... a format of the vendor's own,
-- whose library can't be read out of it). Pure but for `read`.
function libraries.sounds(paths, read)
  if type(paths) ~= "table" or #paths == 0 then return nil end
  local out = {}
  for _, p in ipairs(paths) do
    local e = ext_of(p)
    if libraries.AUDIO[e] then out[#out + 1] = p
    elseif e == "sfz" or e == "dspreset" then
      out[#out + 1] = p
      local text = read and read(p)
      if text then
        local more = (e == "sfz" and libraries.sfz_samples or libraries.dspreset_samples)(text, dir_of(p))
        if not more then return nil end
        for _, s in ipairs(more) do out[#out + 1] = s end
      end
    else return nil end
  end
  return out
end
-- Does someone in the studio lack one of `ids` (a sampler's sounds)? members: the studio's users (plugins.lists'); haves: user -> set of ids
-- (their published reports); me: this computer's user, who has what it's printing. A member with no report lacks everything. -> true or
-- false; nil for `ids` nil (opaque: can't tell). Pure.
function libraries.decide(ids, members, haves, me)
  if type(ids) ~= "table" then return nil end
  for _, u in ipairs(members or {}) do
    if u ~= me then
      local h = haves and haves[u]
      for _, id in ipairs(ids) do if not (h and h[id]) then return true end end
    end
  end
  return false
end
-- This computer's report after a look: `old` (its last have list) with the look's ids set to whether they're here (one gone from here comes
-- out), at most KEEP. refs: { { id, here } }. -> the sorted list. Pure.
-- (shortcut: past KEEP the ids kept are this look's then the old list's first, not the most recently used; a ledger of when each was last
-- seen would keep the right ones once a studio's songs use more than 20,000 sounds)
function libraries.merge(old, refs)
  local set = {}
  for _, r in ipairs(refs) do
    if set[r.id] == nil then set[r.id] = r.here == true end
  end
  local out = {}
  for id, here in pairs(set) do if here then out[#out + 1] = id end end
  for _, id in ipairs(type(old) == "table" and old or {}) do
    if type(id) == "string" and set[id] == nil then set[id] = true; out[#out + 1] = id end
  end
  while #out > libraries.KEEP do table.remove(out) end
  table.sort(out)
  return out
end

-- ---- what a plug-in loads -------------------------------------------------------------------------------------------------------------
local function fx_name(tr, i)
  local ok, name = reaper.TrackFX_GetNamedConfigParm(tr, i, "fx_name")
  if not ok or name == "" then name = select(2, reaper.TrackFX_GetFXName(tr, i)) end
  return name or ""
end
-- The paths a plug-in's saved state names (fxfiles.paths over its base64 chunk: vst_chunk, or clap_chunk for a CLAP), kept by the FX's GUID
-- up to `fresh` seconds: a print's decision asks afresh (a sample just loaded must count), Health's look every 10 minutes (asking every
-- plug-in for its state each minute would hold REAPER up). None for a JSFX (no chunk), or a state over CHUNK_MAX (a sampler holding a
-- whole multi: opaque rather than seconds of decoding).
local states, states_n = {}, 0
local function state_paths(tr, i, fresh)
  local guid = reaper.TrackFX_GetFXGUID(tr, i) or (tostring(tr) .. ":" .. i)
  local c, now = states[guid], reaper.time_precise()
  if c and now - c.at < fresh then return c.paths end
  local _, kind = reaper.TrackFX_GetNamedConfigParm(tr, i, "fx_type")
  local paths = {}
  if kind ~= "JS" then
    local ok, b64 = reaper.TrackFX_GetNamedConfigParm(tr, i, tostring(kind):match("^CLAP") and "clap_chunk" or "vst_chunk")
    if ok and type(b64) == "string" and b64 ~= "" and #b64 <= libraries.CHUNK_MAX then paths = require("fxfiles").paths("\n" .. b64 .. "\n") end
  end
  if states_n > 2000 then states, states_n = {}, 0 end
  if not c then states_n = states_n + 1 end
  states[guid] = { at = now, paths = paths }
  return paths
end
-- Plug-in `i` on `tr`: -> sounds (a listed sampler's: paths, or false when opaque; nil for any other plug-in), files (the small content it
-- loads or shows: lib/content.lua's kinds, presets included), its name. fresh: as state_paths (default 2 s).
function libraries.fx_refs(tr, i, fresh)
  local prints, content = require("prints"), require("content")
  local name = fx_name(tr, i)
  local sounds, files = nil, {}
  if require("plugins").key(name):find("reasamplomatic5000", 1, true) then
    sounds = {}
    for k = 0, 127 do
      local _, f = reaper.TrackFX_GetNamedConfigParm(tr, i, "FILE" .. k)
      if type(f) ~= "string" or f == "" then break end
      sounds[#sounds + 1] = f
    end
    return sounds, files, name
  end
  local paths = state_paths(tr, i, fresh or 2)
  if prints.sampler_name(name) then sounds = libraries.sounds(paths, band.read) or false
  else for _, p in ipairs(paths) do if content.kind(p) then files[#files + 1] = p end end end
  local _, preset = reaper.TrackFX_GetPreset(tr, i)
  if content.preset_tail(preset) then files[#files + 1] = preset end
  return sounds, files, name
end

-- ---- the studio's reports -----------------------------------------------------------------------------------------------------------
local function dir(cfg) return cfg.root .. "/" .. libraries.DIR end
local function file_of(cfg) return dir(cfg) .. "/" .. (cfg.user:gsub("[^%w%-_]", "_")) .. ".json" end
-- The studio's members (whoever's plug-in list still counts: plugins.lists) and each one's set of ids, looked up once a minute.
local studio = { at = -math.huge }
function libraries.studio(cfg)
  if reaper.time_precise() - studio.at < 60 and studio.root == cfg.root then return studio.members, studio.haves end
  local members, haves = {}, {}
  for _, l in ipairs(require("plugins").lists(cfg)) do members[#members + 1] = l.user end
  local gone = require("removal").gone(cfg.root)
  for _, f in ipairs(band.files(dir(cfg), ".json")) do
    local l = band.read_json(dir(cfg) .. "/" .. f)
    if type(l) == "table" and type(l.user) == "string" and type(l.have) == "table" and type(l.time) == "string"
        and band.age(l.time) < 90 * 86400 and not gone[l.user] then
      local set = {}
      for _, id in ipairs(l.have) do if type(id) == "string" then set[id] = true end end
      haves[l.user] = set
    end
  end
  studio.at, studio.root, studio.members, studio.haves = reaper.time_precise(), cfg.root, members, haves
  return members, haves
end
-- For prints.midi_prints: does someone in the studio lack a sound one of this track's samplers plays? -> true or false; nil when a sampler
-- on it is opaque (prints.sample_player decides then, as before). A track without a listed sampler: false.
function libraries.lacks(tr, cfg)
  if not (cfg and cfg.root and cfg.user) then return nil end
  local prints, ids = require("prints"), {}
  for _, i in ipairs(prints.fx_all(tr)) do
    if prints.sampler_name(fx_name(tr, i)) then -- (only a sampler's state is asked for: the decision comes with every print)
      local sounds = libraries.fx_refs(tr, i)
      if sounds == false then return nil end
      for _, p in ipairs(sounds or {}) do ids[#ids + 1] = libraries.id(p) end
    end
  end
  if #ids == 0 then return false end
  local members, haves = libraries.studio(cfg)
  return libraries.decide(ids, members, haves, cfg.user)
end

-- Every sound and small file the song's plug-ins use, as this computer sees them: { { id, what (the file's name: shown here only, never
-- published), track, fx, kind = "sound"/"file", here } }, and the opaque samplers { { track, fx } }.
function libraries.look(proj)
  local prints, content = require("prints"), require("content")
  local refs, opaque = {}, {}
  for t = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, t)
    local _, tname = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    tname = tname ~= "" and tname or ("Track " .. (t + 1))
    for _, i in ipairs(prints.fx_all(tr)) do
      local sounds, files, name = libraries.fx_refs(tr, i, 600)
      local short = require("plugins").key(name)
      if sounds == false then opaque[#opaque + 1] = { track = tname, fx = short } end
      for _, p in ipairs(sounds or {}) do
        refs[#refs + 1] = { id = libraries.id(p), what = p:gsub("\\", "/"):match("[^/]+$"), track = tname, fx = short, kind = "sound", here = reaper.file_exists(p) }
      end
      for _, p in ipairs(files) do
        refs[#refs + 1] = { id = content.id(p), what = p:gsub("\\", "/"):match("[^/]+$"), track = tname, fx = short, kind = "file", here = content.here(p) }
      end
    end
  end
  return refs, opaque
end
-- Live sync, each pass: once a minute, while stopped (a plug-in asked for its state mid-playback can stutter), looks at the song and
-- publishes this computer's report when it changed; the look goes in ExtState "libraries look <root>" for Health (another script).
local looked_at = -math.huge
function libraries.tick(proj, cfg)
  if reaper.time_precise() - looked_at < libraries.EVERY or reaper.GetPlayStateEx(proj) ~= 0 then return end
  looked_at = reaper.time_precise()
  local refs, opaque = libraries.look(proj)
  local path = file_of(cfg)
  local old = band.read_json(path)
  local have = libraries.merge(type(old) == "table" and old.have or nil, refs)
  if not (type(old) == "table" and band.json_encode(old.have or {}) == band.json_encode(have)) then
    reaper.RecursiveCreateDirectory(dir(cfg), 0)
    band.write_json(path, { user = cfg.user, os = reaper.GetOS(), time = os.date("!%Y-%m-%dT%H:%M:%SZ"), have = have })
  end
  local keep = {}
  for k = 1, math.min(#refs, 400) do keep[k] = refs[k] end
  reaper.SetExtState(band.SECTION, "libraries look " .. cfg.root, band.json_encode({ refs = keep, opaque = opaque, time = os.time() }), false)
end

-- Who lacks which of the song's sounds and files, from a look (`refs`) and the studio's reports. -> { { what, track, kind, users } },
-- only those someone else lacks, one per id. Pure.
function libraries.who_lacks(refs, members, haves, me)
  local out, seen = {}, {}
  for _, r in ipairs(type(refs) == "table" and refs or {}) do
    if type(r) == "table" and type(r.id) == "string" and not seen[r.id] then
      seen[r.id] = true
      local users = {}
      for _, u in ipairs(members or {}) do
        if u ~= me and not (haves[u] and haves[u][r.id]) then users[#users + 1] = u end
      end
      if #users > 0 then out[#out + 1] = { what = r.what, track = r.track, kind = r.kind, users = users } end
    end
  end
  return out
end
-- Health's row for the song in front (Live sync's last look). -> a row, or nil before a look.
function libraries.health_row(cfg)
  local look = band.ext_json(band.SECTION, "libraries look " .. cfg.root)
  if type(look) ~= "table" or type(look.refs) ~= "table" then return nil end
  local members, haves = libraries.studio(cfg)
  local lacks = libraries.who_lacks(look.refs, members, haves, cfg.user)
  local opaque = {}
  for k, o in ipairs(type(look.opaque) == "table" and look.opaque or {}) do if k <= 3 then opaque[#opaque + 1] = tostring(o.fx) .. " on " .. tostring(o.track) end end
  local tail = #opaque > 0 and (" Opaque, so their parts print as before: " .. table.concat(opaque, ", ") .. (#look.opaque > 3 and "..." or "") ..
    " (what they play can't be read from their state).") or ""
  if #lacks == 0 then
    return { "libraries", true, "grey", "Sounds and files: everyone in the studio has what this project's samplers and plug-ins load (" .. #look.refs .. ")." .. tail, "" }
  end
  local each = {}
  for k, m in ipairs(lacks) do
    if k <= 4 then each[#each + 1] = string.format("%s (%s: %s)", tostring(m.what), tostring(m.track), table.concat(m.users, ", ")) end
  end
  return { "libraries", false, "yellow", "", string.format("Sounds and files someone lacks for this project (%d): %s%s. A sampler's part prints for them; " ..
    "a preset, IR or capture goes to them (Settings > Studio: Presets and small content). Someone whose computer hasn't opened the project yet counts as lacking.%s",
    #lacks, table.concat(each, "; "), #lacks > 4 and "..." or "", tail) }
end

return libraries
