-- MIDI wet/dry (docs/mirror-design.md): a MIDI item's notes are the truth and travel as notes; whoever changes it
-- (and has the instrument) also renders a print, the item's second take, which travels with it as audio, when someone in
-- the studio lacks a plug-in it plays through or its instrument is a sample player (prints.midi_prints, 0.59.49). Each
-- machine picks which take plays: Notes (dry: your own instruments), Sound (wet: the print) or Auto (notes when the
-- track's plug-ins all load here, else the print). The playing take is never mirrored (lib/mirror.lua drops it), so
-- one person's choice never changes anyone else's.
local band = require("band")
local prints = {}
prints.KEY = "band_m_print" -- on the print take: the source hash it was made from (travels: band_m_ keys do)
-- (and, on an item with several takes, which real take it was made from, counted from 0 as mirror.picked_take counts: a print follows the
-- picked take, and stands in for that one only. Read by mirror.picked_take too. James, rt)
prints.FROM = "band_m_printof"

local function take_ext(tk, k) return tk and select(2, reaper.GetSetMediaItemTakeInfo_String(tk, "P_EXT:" .. k, "", false)) or "" end

function prints.takes(it)
  local midi, print
  for k = 0, reaper.CountTakes(it) - 1 do
    local tk = reaper.GetTake(it, k)
    if tk then
      if take_ext(tk, prints.KEY) ~= "" then print = print or tk
      elseif reaper.TakeIsMIDI(tk) then midi = midi or tk end
    end
  end
  -- (several takes: the notes are the picked take's, when it's MIDI; it was always the first's. James, rt)
  local pick = midi and require("mirror").picked_take(it)
  if pick then
    local k = require("mirror").real_takes(it)[pick + 1]
    local tk = k and reaper.GetTake(it, k)
    if tk and reaper.TakeIsMIDI(tk) then midi = tk end
  end
  return midi, print
end
-- Which real take a print stands for on an item with several (prints.FROM), or nil for an item with one. Shared by refresh and choose.
local function several_pick(it)
  local mirror = require("mirror")
  return reaper.CountTakes(it) > 1 and mirror.filled_takes(it) > 1 and mirror.picked_take(it) or nil
end

-- A MIDI track that plays an instrument on another track: no instrument of its own, and a send carrying MIDI to a
-- track that has one (a sampler fed by several MIDI tracks, drums on a kit track). -> that track, or nil. (The first
-- such send: a track sending MIDI to several instruments prints through the first.)
-- Whether a track has an instrument: a loaded one, or one that isn't here (offline: TrackFX_GetInstrument doesn't
-- count those, so the computer missing it, the one that most needs the print, didn't see the routing at all), known
-- by REAPER's "VSTi:", "VST3i:", "AUi:", "CLAPi:" name. A JSFX has no such name and TrackFX_GetInstrument doesn't see
-- it (Mac, 0.39.1): one counts when its file says "in_pin:none" (no audio in: chmaha's kits, organ and pianos), tags
-- itself an instrument, or is called a synth; read once per file. (A JS instrument that says none of that is missed.)
local js_inst = {} -- Effects-relative path -> true/false
local function js_instrument(tr, i)
  local _, kind = reaper.TrackFX_GetNamedConfigParm(tr, i, "fx_type")
  if kind ~= "JS" then return false end
  local _, ident = reaper.TrackFX_GetNamedConfigParm(tr, i, "fx_ident")
  ident = (ident or ""):gsub("\\", "/")
  if js_inst[ident] == nil then
    local text = (band.read(reaper.GetResourcePath() .. "/Effects/" .. ident) or ""):sub(1, 65536)
    local head = text:sub(1, (text:find("\n@") or #text)):lower() -- (the header, up to the first @section: chmaha's run 11 KB)
    -- (not one with no audio out either: a MIDI-only effect, an arpeggiator, says in_pin:none too)
    js_inst[ident] = not head:find("\nout_pin:none", 1, true) and (head:find("\nin_pin:none", 1, true) ~= nil
      or head:find("tags:[^\n]*instrument") ~= nil or (head:match("^desc:([^\n]*)") or head:match("\ndesc:([^\n]*)") or ""):find("synth", 1, true) ~= nil)
  end
  return js_inst[ident]
end
local function has_instrument(tr)
  if reaper.TrackFX_GetInstrument(tr) >= 0 then return true end
  for i = 0, reaper.TrackFX_GetCount(tr) - 1 do
    if select(2, reaper.TrackFX_GetFXName(tr, i)):match("^%u+%d*i: ") or js_instrument(tr, i) then return true end
  end
  return false
end
-- A print's file name: the item, what it was made from, and who rendered it. Two machines rendering the same item
-- made one name with different bytes, and on Windows Syncthing can't replace a file REAPER has open, so it retried
-- for good (laptop, 0.35.6).
local function who_suffix()
  local who = (reaper.GetExtState(band.SECTION, "user"):gsub("[^%w%-_]", "_"))
  return who ~= "" and ("-" .. who) or ""
end
local function print_name(oid, h) return "print-" .. (oid ~= "" and oid or "item") .. "-" .. h .. who_suffix() end
-- A chained print's stage k (prints.relay_stage): "stage-<oid>-<print hash>-<k>-<split hash>", then who rendered it. The print's hash
-- covers the notes or recording and the whole chain, so a stage file is never read for a part that changed since; the split's covers where
-- the chain was cut, which moves when someone installs a plug-in. Trimmed with the print of the same item and hash (lib/trim.lua). 0.59.49
local function stage_base(oid, h, k, sh) return "stage-" .. (oid ~= "" and oid or "item") .. "-" .. h .. "-" .. k .. "-" .. sh end
-- A file made from this (anyone's: "<base>-<who>.flac", or "<base>.flac") in `out`, from the shared listing, or nil.
local function find_made(out, base)
  for _, f in ipairs(band.listing(out, ".flac", true)) do -- (the shared listing: the folder was read once per part, every look. 0.59.19)
    local rest = f:sub(#base + 1)
    if f:sub(1, #base) == base and (rest == ".flac" or rest:sub(1, 1) == "-") then return out .. "/" .. f end
  end
end
-- What a track's prints go through doesn't change in the middle of a look, but it was worked out again for each of its items (a fifth of
-- a look at 2,000 items). mirror.watch opens a look (prints.begin_look) and ends it (prints.end_look); 2 s at most, should it never end.
-- (Not "while the project's change count holds": StudioSync's own writes in the look move it.) Nothing in a look changes a track's
-- instrument, sends or plug-ins: holding a track's FX off (hold_fx) is its enable, which neither answer reads.
-- (the track checked against the front project, where prints run: a project kept from the look's start may be a tab closed since,
-- and handed to ValidatePtr2 that's a freed pointer. 0.59.19)
local look, looking, look_at = {}, false, -math.huge
function prints.begin_look() look, looking, look_at = {}, true, reaper.time_precise() end
function prints.end_look() looking = false end
local function in_look(key, tr, make)
  if not looking or reaper.time_precise() - look_at > 2 or not reaper.ValidatePtr(tr, "MediaTrack*") then return make() end
  local k = key .. tostring(tr)
  local v = look[k]
  if v == nil then
    v = make()
    if v == nil then v = false end -- ("none" kept as false: `v == nil and false or v` came out nil, and nothing was kept)
    look[k] = v
  end
  return v or nil
end
local route
function prints.route(tr) return in_look("r", tr, function() return route(tr) end) end
function route(tr)
  if has_instrument(tr) then return nil end
  for s = 0, reaper.GetTrackNumSends(tr, 0) - 1 do
    local dest = reaper.GetTrackSendInfo_Value(tr, 0, s, "P_DESTTRACK")
    local midi = math.floor(reaper.GetTrackSendInfo_Value(tr, 0, s, "I_MIDIFLAGS")) & 31 ~= 31 -- (31: MIDI off)
    if dest and midi and reaper.GetTrackSendInfo_Value(tr, 0, s, "B_MUTE") == 0 and has_instrument(dest) then return dest end
  end
end

-- The send from a routed MIDI track to its instrument carries MIDI only, when the track has no audio of its own:
-- with the print playing (Wet), a send carrying audio took it into the instrument too, which passed it on, and the
-- band heard it twice, 6 dB hot (laptop, 0.35.6). It goes to the band like any routing change. Returns true if set.
function prints.midi_only(tr, dest)
  for i = 0, reaper.CountTrackMediaItems(tr) - 1 do -- (audio on the track besides prints: its send is left as it is)
    for k = 0, reaper.CountTakes(reaper.GetTrackMediaItem(tr, i)) - 1 do
      local tk = reaper.GetTake(reaper.GetTrackMediaItem(tr, i), k)
      if tk and not reaper.TakeIsMIDI(tk) and take_ext(tk, prints.KEY) == "" then return false end
    end
  end
  for s = 0, reaper.GetTrackNumSends(tr, 0) - 1 do
    if reaper.GetTrackSendInfo_Value(tr, 0, s, "P_DESTTRACK") == dest and reaper.GetTrackSendInfo_Value(tr, 0, s, "I_SRCCHAN") ~= -1 then
      reaper.SetTrackSendInfo_Value(tr, 0, s, "I_SRCCHAN", -1) -- (-1: no audio)
      band.log(string.format("the send from '%s' to '%s' now carries MIDI only, so its print doesn't play twice",
        select(2, reaper.GetTrackName(tr)), select(2, reaper.GetTrackName(dest))))
      return true
    end
  end
  return false
end

-- Every plug-in on a track, inside FX containers too (REAPER 7), as addresses for the TrackFX_ functions. A container
-- itself isn't one: it has no file, and its fx_ident ("__builtin_container") read as loaded whatever was missing inside
-- (plug-ins review, 0.58.76: an amp sim in a container a bandmate lacked was never printed for them).
function prints.fx_all(tr)
  local out = {}
  local function walk(idx)
    local _, n = reaper.TrackFX_GetNamedConfigParm(tr, idx, "container_count")
    if tonumber(n) then
      for k = 0, tonumber(n) - 1 do
        local _, sub = reaper.TrackFX_GetNamedConfigParm(tr, idx, "container_item." .. k)
        if tonumber(sub) then walk(math.tointeger(tonumber(sub))) end
      end
    else out[#out + 1] = idx end
  end
  for i = 0, reaper.TrackFX_GetCount(tr) - 1 do walk(i) end
  return out
end

-- Whether a track's plug-in really loads here. A missing VST, AU or CLAP shows offline; a missing JSFX doesn't: REAPER
-- keeps an empty stand-in (not offline, silent), so its file is looked for in Effects (Mac, 0.39.1: it printed a
-- JS synth it didn't have, and its silent print replaced the PC's good one).
-- Offline by choice (to save CPU) is installed, and plays nothing on purpose: it doesn't stop a print (one that leaves an instrument
-- silent is caught as silent), though the track doesn't play here. It held every print of its track back (plug-ins review, 0.58.76).
-- Installed: by name, in any format (REAPER's own list, cached).
local installed = { at = -math.huge }
local function installed_here(tr, i)
  if reaper.time_precise() - installed.at > 300 then
    installed.at, installed.set = reaper.time_precise(), {}
    local plugins = require("plugins")
    for _, x in ipairs(plugins.installed()) do installed.set[plugins.key(x.name)] = true end
  end
  local ok, name = reaper.TrackFX_GetNamedConfigParm(tr, i, "fx_name")
  return ok and name ~= "" and installed.set[require("plugins").key(name)] == true
end
function prints.fx_here(tr, i, offline_ok)
  if reaper.TrackFX_GetOffline(tr, i) then return offline_ok == true and installed_here(tr, i) end
  local _, kind = reaper.TrackFX_GetNamedConfigParm(tr, i, "fx_type")
  local _, ident = reaper.TrackFX_GetNamedConfigParm(tr, i, "fx_ident") -- (a JSFX's is relative to Effects: "ReaTeam JSFX/Synth/x.jsfx")
  -- a VST or AU that isn't installed doesn't read as offline either: no file behind it, and only REAPER's own three
  -- knobs (bypass, wet, delta). Taken as loaded, its notes printed silent, and in Auto they played silent where the
  -- print should have (laptop and PC, 0.42.2)
  -- (sforzando's CLAP: loaded, no ident and no knobs of its own, read as missing, so its parts never printed and Auto played the print.
  -- A missing CLAP shows offline. Plug-in test, 0.59.17)
  -- (REAPER's own Video processor: in every REAPER, and it plays no sound anyway. rt-video2)
  if require("video").builtin_fx(select(2, reaper.TrackFX_GetNamedConfigParm(tr, i, "fx_name")), kind) then return true end
  if kind ~= "JS" then return (ident or "") ~= "" or reaper.TrackFX_GetNumParams(tr, i) > 3 or (tostring(kind):find("CLAP") ~= nil and installed_here(tr, i)) end
  ident = (ident or ""):gsub("\\", "/")
  return ident == "" or reaper.file_exists(reaper.GetResourcePath() .. "/Effects/" .. ident) or reaper.file_exists(ident)
end

-- Does every plug-in on the item's track load here (and on the instrument's track, for a routed one)? A missing one
-- would leave its notes silent.
-- `to_print`: whether it can print here, where a plug-in offline by choice counts (see installed_here).
local track_plays
function prints.track_plays(tr, to_print) return in_look(to_print and "P" or "p", tr, function() return track_plays(tr, to_print) end) end
function track_plays(tr, to_print)
  for _, i in ipairs(prints.fx_all(tr)) do
    if not prints.fx_here(tr, i, to_print) then return false end
  end
  local dest = prints.route(tr)
  if dest then
    for _, i in ipairs(prints.fx_all(dest)) do
      if not prints.fx_here(dest, i, to_print) then return false end
    end
  end
  return true
end

-- What a print is made from: the notes, the item's length and the band's plug-in chain on its track (`fx_hash`:
-- mirror's hash of it, which leaves this machine's translations out, so it's the same on every machine).
-- Not which notes are selected: REAPER's MIDI_GetHash counts that (even notes-only), so an undo after a hand edit,
-- which leaves the moved note selected, rendered the same notes again (laptop, 2026-11-01). Second value: the hash
-- before 0.40.3, so prints made then stay current until their notes change (no re-render of every part at once).
local function unselected(raw, mtk)
  return require("mirror").memo("ms", raw, function()
    local ok, buf = reaper.MIDI_GetAllEvts(mtk, "")
    if not ok then return raw end
    local out, pos = {}, 1
    while pos + 8 < #buf do -- each event: offset (int32), flags (byte: 1 = selected), message (int32 length, bytes)
      local off, flags, msg, nxt = string.unpack("<i4Bs4", buf, pos)
      out[#out + 1] = string.pack("<i4Bs4", off, flags & ~1, msg)
      pos = nxt
    end
    return table.concat(out)
  end)
end
function prints.source(it, mtk, fx_hash)
  local mirror, raw = require("mirror"), select(2, reaper.MIDI_GetHash(mtk, false, ""))
  local tail = (fx_hash or "") .. string.format("%.6f", reaper.GetMediaItemInfo_Value(it, "D_LENGTH"))
  -- (and where in its notes the item starts and how fast it plays: a slip edit kept the old print. Only when not the usual, so prints made
  -- before stay current. Review, 0.58.92)
  local offs, rate = reaper.GetMediaItemTakeInfo_Value(mtk, "D_STARTOFFS"), reaper.GetMediaItemTakeInfo_Value(mtk, "D_PLAYRATE")
  if math.abs(offs) > 1e-6 then tail = tail .. string.format("|o%.6f", offs) end
  if math.abs(rate - 1) > 1e-6 then tail = tail .. string.format("|r%.6f", rate) end
  return mirror.hash(unselected(raw, mtk) .. tail), mirror.hash(raw .. tail)
end

-- The two takes say what they are: "dry" (the notes, or the editable ARA take) and "wet" (the print), each keeping
-- the name it had after a dash ("dry - Keys verse"). It used to be take 1 and "print of ..." (James, 2026-10-31).
-- Pure: an earlier label ("dry - ", "wet - ", "print of ") is taken off first, so naming again never stacks.
function prints.label(kind, name)
  name = (name or ""):gsub("^print of ", ""):gsub("^dry %- ", ""):gsub("^wet %- ", ""):gsub("^dry$", ""):gsub("^wet$", "")
  return name ~= "" and (kind .. " - " .. name) or kind
end
local function label_takes(dry, wet)
  local name = select(2, reaper.GetSetMediaItemTakeInfo_String(dry, "P_NAME", "", false))
  reaper.GetSetMediaItemTakeInfo_String(dry, "P_NAME", prints.label("dry", name), true)
  reaper.GetSetMediaItemTakeInfo_String(wet, "P_NAME", prints.label("wet", name), true)
end

-- This machine's choice: "auto" (default), "notes" or "sound".
function prints.mode() local m = reaper.GetExtState(band.SECTION, "midi_plays"); return m ~= "" and m or "auto" end
-- A track's own choice, this computer's (James, 0.59.2: "right click the track and switch dry or wet"): "dry" (every part plays itself,
-- through the track's plug-ins, which come back on), "wet" (every part plays the studio's print, the track's plug-ins held off so nothing
-- goes through them twice), "auto" (as Auto does: through the plug-ins when they all load here, else the print; James, 0.59.4: "dry wet
-- auto like the other setting"), or "" (never set: as Settings > Options > Parts play says). In the project's own state by the track's GUID: never sent to anyone.
prints.PLAYS = "BandSync plays"
function prints.track_choice(proj, tr) return select(2, reaper.GetProjExtState(proj, prints.PLAYS, reaper.GetTrackGUID(tr))) end
function prints.set_track_choice(proj, tr, choice)
  reaper.SetProjExtState(proj, prints.PLAYS, reaper.GetTrackGUID(tr), choice or "")
  for i = 0, reaper.CountTrackMediaItems(tr) - 1 do prints.choose(reaper.GetTrackMediaItem(tr, i)) end
  prints.hold_fx(tr)
end

-- Make the item play what this machine chose.
function prints.choose(it, no_hold) -- no_hold: the caller holds the track's FX once, after all its items
  local midi, print = prints.takes(it)
  local ara = print and not midi and prints.ara_take(it)
  if ara then -- an ARA take: editable only where it was edited (see prints.ARA)
    local want = take_ext(ara, prints.HERE) == take_ext(print, prints.KEY) and ara or print
    if reaper.GetActiveTake(it) ~= want then reaper.SetActiveTake(want); reaper.UpdateItemInProject(it) end
    return
  end
  -- (an item with a choice of real takes plays the one picked, the band's: the print was the first's, and choosing it here undid a comp. 0.58.85)
  -- (the track's FX hold is looked at on the way out too: an item that lost its print, or got a second real take, left the FX off for good.
  -- Review, 0.58.92)
  local tr = reaper.GetMediaItem_Track(it)
  local function recheck() if band.track_ext(tr, prints.FXEN) ~= "" then prints.hold_fx(tr) end end -- (only a track holding its FX: 0.58.93)
  local dry = midi or (print and prints.audio_take(it))
  if not (dry and print) then return recheck() end
  -- (several takes: the print plays only for the take it was made from (prints.FROM), and only where the track's plug-ins don't load: the
  -- picked take is the band's comp choice, so Sound / a track set to wet don't override it. Another take picked plays itself until its own
  -- print lands. James, rt)
  local pick = several_pick(it)
  if pick then
    local want = tostring(pick) == take_ext(print, prints.FROM) and not prints.track_plays(tr) and print or dry
    if reaper.GetActiveTake(it) ~= want then reaper.SetActiveTake(want); reaper.UpdateItemInProject(it) end
    if not no_hold then prints.hold_fx(tr) end
    return
  end
  local mode = prints.mode()
  local own = prints.track_choice(reaper.GetItemProjectContext(it), tr) -- (the track's own choice first)
  if own == "dry" then mode = "notes" elseif own == "wet" then mode = "sound" elseif own == "auto" then mode = "auto" end
  local want = mode == "sound" and print or mode == "notes" and dry or (prints.track_plays(tr) and dry or print)
  if reaper.GetActiveTake(it) ~= want then reaper.SetActiveTake(want); reaper.UpdateItemInProject(it) end
  if not no_hold then prints.hold_fx(tr) end
end

-- A wet take already went through its track's plug-ins: played through them again, the ones that load here would
-- apply twice (a missing amp sim passes the print through, the reverb after it doesn't). So while an item on the
-- track plays its wet take, the track's FX are switched off here (its FX button), and back on once none does.
-- Only here: mirror reads the band's setting from prints.FXEN while it's held. (ARA prints have only the take's
-- own plug-ins in them: their track's still apply.)
prints.FXEN = "band_fxen" -- (on a track, this machine only: the FX button as the band has it, while held off here)
local said_print_only = {}
function prints.hold_fx(tr)
  local wet = false
  for i = 0, reaper.CountTrackMediaItems(tr) - 1 do
    local x = reaper.GetTrackMediaItem(tr, i)
    local tk = reaper.GetActiveTake(x)
    -- (a lane that isn't playing isn't heard: its wet take took the Neve off a comp that was playing dry: Mac, 0.42.27)
    local heard = reaper.GetMediaTrackInfo_Value(tr, "I_FREEMODE") ~= 2
      or reaper.GetMediaTrackInfo_Value(tr, "C_LANEPLAYS:" .. math.floor(reaper.GetMediaItemInfo_Value(x, "I_FIXEDLANE"))) > 0
    if heard and tk and take_ext(tk, prints.KEY) ~= "" and not prints.ara_take(x) then
      -- (a comp made while a pass played its print: the Neve went off for the whole track, so every dry piece played unprocessed:
      -- Mac, 0.42.5. One piece through its plug-ins twice is the smaller harm, and it says so)
      if reaper.CountTakes(x) > 1 then wet = true; break end
      if not said_print_only[x] then
        said_print_only[x] = true
        band.log("a part on " .. select(2, reaper.GetTrackName(tr)) .. " holds only its print, no dry take, so it plays through this track's plug-ins a second time. If it came from a comp, comp it from the dry take")
      end
    end
  end
  local held = band.track_ext(tr, prints.FXEN)
  if wet and held == "" then
    reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:" .. prints.FXEN, tostring(math.floor(reaper.GetMediaTrackInfo_Value(tr, "I_FXEN"))), true)
    reaper.SetMediaTrackInfo_Value(tr, "I_FXEN", 0)
  elseif not wet and held ~= "" then
    reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:" .. prints.FXEN, "", true)
    reaper.SetMediaTrackInfo_Value(tr, "I_FXEN", tonumber(held) or 1)
  end
end

-- Tracks whose FX are held off for a print, looked at again: a part deleted (here or by the band) never passes through choose, and the
-- FX stayed off. Review, 0.58.92
function prints.release_held(proj)
  for t = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, t)
    if band.track_ext(tr, prints.FXEN) ~= "" then prints.hold_fx(tr) end
  end
end

-- Audio (0.37): the take a wet print stands in for, on an audio item whose track has a plug-in someone in the band
-- lacks: its one take that isn't the print, or with several, the one picked (mirror.picked_take: a playing print counts as the take it
-- was made from. It was none: James, rt). nil for MIDI and ARA items, and when the picked take is an empty one.
function prints.audio_take(it)
  local dry, n = nil, 0
  for k = 0, reaper.CountTakes(it) - 1 do
    local tk = reaper.GetTake(it, k)
    if tk and take_ext(tk, prints.KEY) == "" then
      if reaper.TakeIsMIDI(tk) then return nil end
      dry, n = dry or tk, n + 1
    end
  end
  if n == 0 or prints.ara_take(it) then return nil end
  if n == 1 then return dry end
  local mirror = require("mirror")
  local k = mirror.real_takes(it)[(mirror.picked_take(it) or 0) + 1]
  return k and reaper.GetTake(it, k) or nil
end

-- Whether a track has a plug-in someone in the band doesn't have (everyone's published list, lib/plugins.lua; by
-- its own name, not one it was renamed to). Looked up once a minute.
local common = { at = -math.huge }
function prints.lacking(tr, cfg)
  if not cfg then return false end
  local plugins = require("plugins")
  if reaper.time_precise() - common.at > 60 then
    local ok, set, members, systems = pcall(plugins.band, cfg)
    common.at, common.set, common.n, common.systems = reaper.time_precise(), ok and set or nil, ok and #members or 0, ok and systems or nil
  end
  if not common.set or common.n < 2 then return false end
  for _, i in ipairs(prints.fx_all(tr)) do
    local ok, name = reaper.TrackFX_GetNamedConfigParm(tr, i, "fx_name")
    if not ok or name == "" then name = select(2, reaper.TrackFX_GetFXName(tr, i)) end
    -- (the Video processor is on nobody's list but in every REAPER: a track with one printed its parts for nothing. rt-video2)
    local builtin = require("video").builtin_fx(name, select(2, reaper.TrackFX_GetNamedConfigParm(tr, i, "fx_type")))
    if not builtin and (not common.set[plugins.key(name)] or not plugins.loads_everywhere(name, common.systems)) then return true end
  end
  return false
end

-- Sample players: what they play is a library, kit or sample file the plug-in list can't see (two computers with Kontakt can hold different
-- libraries), so their parts keep printing whenever whoever changed them has the chain (James, 0.59.49). Matched on plugins.key's form,
-- at the start of a word ("bfd" isn't "xbfdx").
prints.SAMPLERS = { "kontakt", "komplete kontrol", "sforzando", "ezdrummer", "ezkeys", "ezbass", "superior drummer", "addictive drums",
  "addictive keys", "bfd", "spitfire audio", "decent sampler", "decentsampler", "sitala", "reasamplomatic5000", "sampletank", "halion", "battery" }
function prints.sampler_name(name) -- Pure.
  local k = require("plugins").key(name)
  for _, s in ipairs(prints.SAMPLERS) do
    local a = k:find(s, 1, true)
    if a and (a == 1 or not k:sub(a - 1, a - 1):match("%w")) then return true end
  end
  return false
end
local function fx_name(tr, i)
  local ok, name = reaper.TrackFX_GetNamedConfigParm(tr, i, "fx_name")
  if not ok or name == "" then name = select(2, reaper.TrackFX_GetFXName(tr, i)) end
  return name
end
-- Has the track a sample player on it? (ReaSamplOmatic5000 only with a sample loaded: the file is what may not be everywhere.)
function prints.sample_player(tr)
  for _, i in ipairs(prints.fx_all(tr)) do
    local name = fx_name(tr, i)
    if prints.sampler_name(name) and (not require("plugins").key(name):find("reasamplomatic5000", 1, true)
        or select(2, reaper.TrackFX_GetNamedConfigParm(tr, i, "FILE0")) ~= "") then return true end
  end
  return false
end
-- Does a MIDI part on `tr` (playing `dest`'s instrument, for a routed one) get a print? Only where a plug-in it plays through is missing
-- for someone in the studio, as audio parts (James, 0.59.49: "prints only where a plug-in is missing"), or its instrument is a sample
-- player. Cost: fewer renders and less Syncthing traffic; a part everyone can play from its notes no longer prints. Prints already on
-- items stay, and Auto plays the notes wherever everything loads, as before.
-- (a sampler whose state names its files prints only when someone in the studio lacks one; an opaque one as before: lib/libraries.lua. rt)
function prints.sounds_lacking(tr, cfg)
  local ok, r = pcall(require("libraries").lacks, tr, cfg)
  if ok and r ~= nil then return r end
  return prints.sample_player(tr)
end
function prints.midi_prints(tr, dest, cfg)
  return prints.lacking(tr, cfg) or (dest and prints.lacking(dest, cfg)) or prints.sounds_lacking(tr, cfg) or (dest and prints.sounds_lacking(dest, cfg)) or false
end

-- Whether a published list (plugins.lists) has the plug-in `name`: by plugins.key, in a format that loads on its system (an AU only on a
-- Mac, as plugins.loads_everywhere). Pure.
local function list_has(l, name)
  local plugins = require("plugins")
  if not l.set then
    l.set = {}
    for _, k in ipairs(type(l.names) == "table" and l.names or {}) do l.set[k] = true end
  end
  if require("video").builtin_fx(name) then return true end -- (in every REAPER, on nobody's list. rt-video2)
  return l.set[plugins.key(name)] == true and plugins.loads_everywhere(name, { [plugins.system(l.os)] = true })
end
-- Who lacks each of `names` (plug-in names, in order), by everyone's published list (the data prints.lacking goes by): { {fx, users} },
-- only those someone lacks. Pure.
function prints.who_lacks(names, lists)
  local out = {}
  if #lists < 2 then return out end -- (one list: nothing to compare yet, as prints.lacking)
  for _, name in ipairs(names) do
    local users = {}
    for _, l in ipairs(lists) do if not list_has(l, name) then users[#users + 1] = l.user end end
    table.sort(users)
    if #users > 0 then out[#out + 1] = { fx = (name:gsub("^%w+:%s*", "")), users = users } end
  end
  return out
end
-- The master's plug-ins someone in the studio lacks (Health, James 0.59.49). The master is never printed (the whole mix rendered again at
-- every change costs too much), so whoever lacks one hears the mix without it.
function prints.master_lacks(proj, cfg)
  if not (cfg and cfg.root) then return {} end
  local master, names = reaper.GetMasterTrack(proj), {}
  for _, i in ipairs(prints.fx_all(master)) do
    if reaper.TrackFX_GetEnabled(master, i) then names[#names + 1] = fx_name(master, i) end -- (a bypassed one plays nowhere)
  end
  if #names == 0 then return {} end
  local ok, lists = pcall(require("plugins").lists, cfg)
  return prints.who_lacks(names, ok and lists or {})
end

-- What an audio print is made from: the recording, how the take plays it and its own plug-ins, the item's length,
-- and the band's plug-in chain on its track (`fx_hash`). Not the item's volume and fades: prints leave those out,
-- and the item applies them to whichever take plays.
function prints.audio_source(it, tk, fx_hash)
  local f = { (reaper.GetMediaSourceFileName(reaper.GetMediaItemTake_Source(tk), ""):match("[^/\\]*$")) }
  f[#f + 1] = string.format("%.6f", reaper.GetMediaItemInfo_Value(it, "D_LENGTH"))
  for _, k in ipairs({ "D_STARTOFFS", "D_PLAYRATE", "D_PITCH", "D_VOL", "D_PAN", "I_CHANMODE", "B_PPITCH" }) do
    f[#f + 1] = string.format("%.6f", reaper.GetMediaItemTakeInfo_Value(tk, k))
  end
  for i = 0, reaper.TakeFX_GetCount(tk) - 1 do f[#f + 1] = select(2, reaper.TakeFX_GetFXName(tk, i, "")) end
  return require("mirror").hash(table.concat(f, "|") .. "|" .. (fx_hash or ""))
end

-- A part is rendered once it has held still, and those whose last change is oldest go first (James, 2026-11-01): a
-- burst measured on the PC rendered every state it passed through, and one part being edited held up all the others.
-- Going back to a state already printed doesn't wait (prints.render finds it first). `seen`: still asking; one that
-- stopped (deleted, or printed by someone else now) no longer holds anyone up.
prints.SETTLE = 3 -- seconds a part must stay unchanged
local queue = {} -- item oid -> { name, since, seen }
local QUEUE_SEEN = 5
-- The media folder, made if it isn't there: once every 10 s per folder, not for every part waiting to print at every look (680 calls, a
-- quarter of a second, at 2,000 items. 0.59.19)
local dirs_made = {}
local function made_dir(d)
  local now = reaper.time_precise()
  if now - (dirs_made[d] or -math.huge) > 10 then reaper.RecursiveCreateDirectory(d, 0); dirs_made[d] = now end
end
local function my_turn(oid, name)
  if prints.SETTLE <= 0 then return true end
  local now, w = reaper.time_precise(), queue[oid]
  if not w or w.name ~= name or now - w.seen > QUEUE_SEEN then w = { name = name, since = now }; queue[oid] = w end
  w.seen = now
  if now - w.since < prints.SETTLE then return false end
  for k, o in pairs(queue) do
    if k ~= oid and o.since < w.since and now - o.seen <= QUEUE_SEEN then return false end
  end
  return true
end
-- Whether a part is waiting for its turn (Live sync then looks every second).
function prints.waiting()
  local now = reaper.time_precise()
  for _, o in pairs(queue) do if now - o.seen <= QUEUE_SEEN then return true end end
  return false
end

-- Render a print: in the background where that works (lib/bgrender.lua: nil while it renders, and a later pass
-- picks it up), else here and now. `render()` renders it in front and returns its path; `tracks`: what it goes through.
-- A print that didn't come out goes up in the panel's bar, as an undone edit does, and on its small box (James, 0.59.12: "when a print or
-- render fails it should probably come up at the alert box"): ExtState "print problem", { text, n, at }, until it's dismissed or half an hour old.
function prints.problem(text)
  band.log(text)
  local old = band.ext_json(band.SECTION, "print problem") or {}
  local n = old.at and os.time() - old.at < 1800 and (tonumber(old.n) or 0) + 1 or 1
  band.set_ext_json(band.SECTION, "print problem", { text = text, n = n, at = os.time() }, false)
end
prints.failed = {} -- print name -> true: rendered here and nothing came out (this session; tried again once what it's made from changes)
prints.front_only = {} -- print name -> true: its background render failed, so it renders here (this session)
-- One render pass is enough only through REAPER's own plug-ins: an amp sim or IR loader (TONEX, NAM, Neural DSP) can load its model in the
-- background and print dry on a first pass, as an instrument can. (Review, 0.59.14)
local function stock_only(tr)
  for i = 0, reaper.TrackFX_GetCount(tr) - 1 do
    local n = select(2, reaper.TrackFX_GetFXName(tr, i, ""))
    if not (n:find("^JS:") or n:find("(Cockos)", 1, true)) then return false end
  end
  return true
end
-- How long REAPER has been left alone: the mouse where it was, no edit, the transport as it was. Asked every pass.
local quiet = { at = 0 }
local function quiet_for()
  local x, y = reaper.GetMousePosition()
  local key = x .. "," .. y .. "," .. reaper.GetProjectStateChangeCount(0) .. "," .. reaper.GetPlayState()
  if key ~= quiet.key then quiet.key, quiet.at = key, reaper.time_precise() end
  return reaper.time_precise() - quiet.at
end
prints.QUIET = 20 -- seconds left alone before a long print renders here, in front (it holds REAPER while it does)
local said_waiting = {}
local retry_seen -- (the alert bar's Try again: ExtState "prints retry")
function prints.render(oid, name, out, tracks, render, secs, quick) -- secs: the part's length; quick: no instrument, one render pass will do
  local retry = reaper.GetExtState(band.SECTION, "prints retry")
  if retry ~= "" and retry ~= retry_seen then
    retry_seen = retry
    prints.failed, prints.silent = {}, {}
    require("bgrender").stuck = {}
  end
  -- already printed: a print's name says what it was made from and who rendered it, so going back to a state it had
  -- (an undo, a note put back) finds its print here. Rendered again, its file (still open in REAPER) couldn't be
  -- replaced, so the background print was dropped and rendered in front as "-2" (laptop, 0.40.0).
  -- Anyone's print of it will do (the same item and source: "print-<oid>-<hash>-<who>"), ours first: going back to the
  -- laptop's state rendered the PC's own copy of it (PC, 0.40.1).
  if reaper.file_exists(out .. "/" .. name .. ".flac") then return out .. "/" .. name .. ".flac" end
  -- (a chained print's stage file too, "stage-...": 0.59.49)
  local found = find_made(out, name:match("^(%a+%-.+%-%x%x%x%x%x%x%x%x)%-") or name)
  if found then return found end
  -- (a track whose FX run on a bandmate's computer has them held off here: rendered now, the print would miss them. It waits till they're back:
  -- lib/hops.lua offload. Shared CPU, rt)
  for _, t in ipairs(tracks) do if band.track_ext(t, "band_fx_held") ~= "" then return nil end end
  local bg = require("bgrender")
  if bg.on() then
    if bg.stuck[name] then return nil end
    local path, state = bg.claim(oid, name, out)
    if path then return path end
    if state == "running" or state == "stuck" then return nil end
    if state == "failed" then prints.front_only[name] = true end
    -- (once failed in the background it renders in front: it started a hidden REAPER again every few seconds while the long part waited for
    -- REAPER to be left alone. Review, 0.59.14)
    if state ~= "failed" and not prints.front_only[name] then
      if not my_turn(oid, name) or bg.busy() then return nil end
      queue[oid] = nil
      local keep = {}
      for _, t in ipairs(tracks) do keep[#keep + 1] = reaper.GetTrackGUID(t) end
      if bg.start(oid, name, keep, render, secs, quick, tracks[1] and select(2, reaper.GetTrackName(tracks[1]))) then return nil end
    end
  elseif not my_turn(oid, name) then return nil end
  if prints.failed[name] then return nil end
  -- (in front, REAPER holds still for as long as the render takes: a long part waits till you've left it alone a while. James, 0.59.12)
  if (secs or 0) > 30 and quiet_for() < prints.QUIET then
    if not said_waiting[name] then said_waiting[name] = true; band.log("a long part's print waits till REAPER's been left alone for " .. prints.QUIET .. " s: it renders here, and holds REAPER while it does") end
    queue[oid] = nil -- (to the back of the line: it held every other print up while it waited. Review, 0.59.14)
    return nil
  end
  queue[oid] = nil
  -- (rendered into a folder of this computer's, then moved in whole: one cut short by a crash sat in the shared folder under its final
  -- name, was taken for done at the next open and went to everyone. Review, 0.59.14)
  local tmp = band.home() .. "/print-render"
  reaper.RecursiveCreateDirectory(tmp, 0)
  for _, f in ipairs(band.files(tmp)) do os.remove(tmp .. "/" .. f) end
  local ok, path = pcall(render, nil, tmp)
  if ok and path then
    local base, moved = tostring(path):gsub("\\", "/"):match("([^/]+)%.flac$"), nil
    for _, ext in ipairs({ ".flac", ".opus" }) do
      local a, z = tmp .. "/" .. tostring(base) .. ext, out .. "/" .. tostring(base) .. ext
      if base and reaper.file_exists(a) then
        os.remove(z)
        if os.rename(a, z) or (pcall(band.copy_atomic, a, z) and reaper.file_exists(z) and os.remove(a)) then
          if ext == ".flac" then moved = z end
        end
      end
    end
    if moved then return moved end
    ok, path = false, "couldn't move it into the studio's media folder"
  end
  prints.failed[name] = true -- (it rendered again at every pass, holding REAPER each time)
  local where = tracks[1] and select(2, reaper.GetTrackName(tracks[1])) or "a track"
  if not ok then band.log("print error on " .. where .. ": " .. tostring(path)) end -- (the details, for the console)
  prints.problem("A part on " .. where .. " didn't print, so collaborators without its plug-ins can't hear it yet. Press Try again, or nudge the part.")
  return nil
end

-- The print goes in as the item's wet take (replacing an older one), the playing take left as it was.
local function attach(it, print, dry, path, h, pick)
  local was = reaper.GetActiveTake(it)
  local ptk = print or reaper.AddTakeToMediaItem(it)
  band.set_take_source(ptk, reaper.PCM_Source_CreateFromFile(path))
  reaper.SetMediaItemTakeInfo_Value(ptk, "D_STARTOFFS", 0)
  label_takes(dry, ptk)
  reaper.GetSetMediaItemTakeInfo_String(ptk, "P_EXT:" .. prints.KEY, h, true)
  -- (which take it's of, on an item with several: written only then, so a one-take item's state stays as it was. James, rt)
  if pick or take_ext(ptk, prints.FROM) ~= "" then reaper.GetSetMediaItemTakeInfo_String(ptk, "P_EXT:" .. prints.FROM, pick and tostring(pick) or "", true) end
  if was then reaper.SetActiveTake(was) end
  return ptk
end
-- A print taken off its item (REAPER has no call that deletes a take: its action, on the item alone, as prints.takes_into_new_lanes does).
-- The tab is in front (mirror's W.prints). Round 4 review, 0.59.49
local function drop_print(proj, it, print)
  local picked = {}
  for s = 0, reaper.CountSelectedMediaItems(proj) - 1 do picked[#picked + 1] = reaper.GetSelectedMediaItem(proj, s) end
  for _, x in ipairs(picked) do reaper.SetMediaItemSelected(x, false) end
  reaper.SetActiveTake(print)
  reaper.SetMediaItemSelected(it, true)
  reaper.Main_OnCommand(40129, 0) -- Take: Delete active take from items
  reaper.SetMediaItemSelected(it, false)
  for _, x in ipairs(picked) do if reaper.ValidatePtr2(proj, x, "MediaItem*") then reaper.SetMediaItemSelected(x, true) end end
end

-- Melodyne and the other ARA plug-ins on an audio take: their edits live in the project, outside the item, so a
-- bandmate's copy of the item plays the take unedited. The print carries them: rendered with the take's own
-- plug-ins (not its track's), it plays everywhere except on the machine that made it, which keeps the editable take.
-- Closing the plug-in's window ends an editing pass: the take's band_m_ara count goes up and a new print follows.
prints.ARA = { "Melodyne", "RePitch", "Revoice", "SpectraLayers", "VocAlign" }
prints.HERE = "band_ara_here" -- (on the ARA take, this machine only: the print it made, so it plays the editable take)
function prints.ara_take(it)
  for k = 0, reaper.CountTakes(it) - 1 do
    local tk = reaper.GetTake(it, k)
    if tk and take_ext(tk, prints.KEY) == "" and not reaper.TakeIsMIDI(tk) then
      for f = 0, reaper.TakeFX_GetCount(tk) - 1 do
        local _, name = reaper.TakeFX_GetFXName(tk, f, "")
        for _, a in ipairs(prints.ARA) do if name:find(a, 1, true) then return tk end end
      end
    end
  end
end
local ara_open = {} -- take GUID -> its plug-in window was open at the last look
function prints.watch_ara(proj)
  for i = 0, reaper.CountMediaItems(proj) - 1 do
    local tk = prints.ara_take(reaper.GetMediaItem(proj, i))
    if tk then
      local open = false
      for f = 0, reaper.TakeFX_GetCount(tk) - 1 do open = open or reaper.TakeFX_GetOpen(tk, f) end
      local g = select(2, reaper.GetSetMediaItemTakeInfo_String(tk, "GUID", "", false))
      if ara_open[g] and not open then -- (an editing pass ended)
        reaper.GetSetMediaItemTakeInfo_String(tk, "P_EXT:band_m_ara", tostring((tonumber(take_ext(tk, "band_m_ara")) or 0) + 1), true)
      end
      ara_open[g] = open
    end
  end
end
function prints.ara_source(it, tk)
  local fx = {}
  for f = 0, reaper.TakeFX_GetCount(tk) - 1 do fx[#fx + 1] = select(2, reaper.TakeFX_GetFXName(tk, f, "")) end
  return require("mirror").hash(table.concat({ reaper.GetMediaSourceFileName(reaper.GetMediaItemTake_Source(tk), ""),
    string.format("%.6f %.6f %.6f %.6f", reaper.GetMediaItemInfo_Value(it, "D_LENGTH"), reaper.GetMediaItemTakeInfo_Value(tk, "D_STARTOFFS"),
      reaper.GetMediaItemTakeInfo_Value(tk, "D_PLAYRATE"), reaper.GetMediaItemTakeInfo_Value(tk, "D_PITCH")),
    take_ext(tk, "band_m_ara"), table.concat(fx, ",") }, "|"))
end
-- Is the take playing a file a band's version named (mirror.theirs)? Never printed here: who prints is decided from files anyone in the studio
-- writes, so a bandmate could have your computer render a private recording of yours into the shared folder. Security, Round 2 review,
-- 0.59.46. Cost: one P_EXT read when a print is about to be made.
function prints.from_band(it, tk)
  local src = tk and reaper.GetMediaItemTake_Source(tk)
  local file = src and reaper.GetMediaSourceFileName(src, "") or ""
  return file ~= "" and require("mirror").theirs(it)[require("fxfiles").key(file)] == true
end
local function refresh_ara(proj, it, media_dir)
  local ara = prints.ara_take(it)
  if not ara or prints.from_band(it, ara) then return false end
  for f = 0, reaper.TakeFX_GetCount(ara) - 1 do if reaper.TakeFX_GetOffline(ara, f) then return false end end
  local _, print = prints.takes(it)
  local h = prints.ara_source(it, ara)
  if print and take_ext(print, prints.KEY) == h then return false end
  local oid = select(2, reaper.GetSetMediaItemInfo_String(it, "P_EXT:band_oid", "", false))
  made_dir(media_dir)
  local name = print_name(oid, h)
  local path = prints.render(oid, name, media_dir, { reaper.GetMediaItem_Track(it) },
    function(_, front) return require("sync").print_item(proj, it, ara, front or media_dir, name, nil, true, true) end, reaper.GetMediaItemInfo_Value(it, "D_LENGTH")) -- (not quick: ARA. front: rendered here, into this folder first)
  if not path then return false end
  attach(it, print, ara, path, h)
  reaper.GetSetMediaItemTakeInfo_String(ara, "P_EXT:" .. prints.HERE, h, true)
  prints.choose(it)
  reaper.UpdateItemInProject(it)
  return true
end

-- ---- chained prints (docs/chained-prints-design.md, James 0.59.49) ---------------------------------------------------------------
-- When no computer has every plug-in a part plays through, nobody printed it. Now its chain is cut into runs, each on a computer that has
-- that run's plug-ins: the first renders the part through its run into a stage file in the shared media folder; the next sees that file
-- arrive (the listing prints already read), renders it through its own run, and so on; the last stage is the print, attached as ever.
-- No new messaging, no new render path: stage 1 is a print through only its run's plug-ins (the others bypassed for the render), each later
-- stage a scratch item playing the stage before through the next run (sync.print_file), both by prints.render (background or in front).
-- Kept out, as today (each computer plays the part with what it has, and Health says why): audio coming into the chain from another track
-- (sidechains, sends), knobs linked between plug-ins, FX containers and parallel plug-ins, more than two channels. The master never prints.

-- How many hand-overs the studio allows (band.json "print_hops", the owner's or an admin's, Settings > Studio): 0 (off), 1, 2 (the default:
-- the two-computer case), 3, or "any". Pure.
function prints.hops_cap(v)
  if v == "any" then return math.huge end
  v = math.tointeger(tonumber(v) or -1)
  if v and v >= 0 and v <= 3 then return v end
  return 2
end
-- The chain cut into runs, fewest for its order: `holders` per plug-in, in order, the set of users who have it; the first `head` must be one
-- run (a MIDI part's instrument and the MIDI plug-ins before it: notes don't go through a file). Each run takes plug-ins while someone has
-- them all. -> { {from, to, who = set} }, or nil and the plug-in it stopped at (nobody has it, or it would split the head). Pure.
function prints.split(holders, head)
  local runs, cur = {}, nil
  for i, h in ipairs(holders) do
    if not next(h) then return nil, i end
    local w = {}
    if cur then for u in pairs(cur.who) do if h[u] then w[u] = true end end end
    if cur and next(w) then cur.to, cur.who = i, w
    elseif cur and i <= (head or 0) then return nil, i
    else cur = { from = i, to = i, who = h }; runs[#runs + 1] = cur end
  end
  return runs
end
-- Who renders each run: whoever changed the part, when they're here and have it; else whoever here has most of the chain (`counts`), then
-- the first by name; else (nobody here has it) the same among everyone, and that stage waits for them. The same on every computer, so two
-- never take one stage. -> { {user, here} }. Pure.
function prints.assign(runs, author, here, counts)
  local out = {}
  local function better(u, b) return not b or (counts[u] or 0) > (counts[b] or 0) or ((counts[u] or 0) == (counts[b] or 0) and u < b) end
  for k, r in ipairs(runs) do
    local pick = author and r.who[author] and here[author] and author or nil
    if not pick then for u in pairs(r.who) do if here[u] and better(u, pick) then pick = u end end end
    if not pick and author and r.who[author] then pick = author end
    if not pick then for u in pairs(r.who) do if better(u, pick) then pick = u end end end
    out[k] = { user = pick, here = here[pick] == true }
  end
  return out
end
-- Does a chain (its FXCHAIN text, as mirror keeps it) link a knob to another plug-in's (parameter modulation's "PLINK scale fx:offset param",
-- a param of -1 being none), in a modulation block that's on? Any such link keeps the part out of chained prints: whether the two plug-ins
-- land in one stage isn't read here (shortcut: conservative; reading which plug-in each block belongs to would allow links within a stage). Pure.
function prints.linked(chain)
  local off = false
  for line in tostring(chain or ""):gmatch("[^\r\n]+") do
    local l = line:match("^%s*(.-)%s*$")
    if l:match("^<PROGRAMENV") then off = l:match("^<PROGRAMENV%s+%S+%s+1") ~= nil -- (its modulation switched off: mirror.modulated)
    elseif not off and l:match("^PLINK%s") then
      local p = tonumber(l:match("^PLINK%s+%S+%s+%S+%s+(%-?%d+)"))
      if p and p >= 0 then return true end
    end
  end
  return false
end

-- What a part's print goes through, ready to cut: { entries = { {tr, i, name} } (enabled plug-ins, the routed source's first), runs,
-- counts, bounds }, or nil and why it can't be chained. Worked out once a look per track.
local function relay_plan(tr, dest, midi, cfg, chains)
  for _, c in ipairs(chains or {}) do
    if prints.linked(c) then return nil, "a knob on it is linked to another plug-in's (parameter modulation)" end
  end
  local entries = {}
  for _, t in ipairs(dest and { tr, dest } or { tr }) do
    if reaper.GetMediaTrackInfo_Value(t, "I_NCHAN") > 2 then return nil, "it uses more than two channels" end
    for r = 0, reaper.GetTrackNumSends(t, -1) - 1 do -- (MIDI-only receives are fine: a sampler fed by several MIDI tracks)
      if reaper.GetTrackSendInfo_Value(t, -1, r, "B_MUTE") == 0 and reaper.GetTrackSendInfo_Value(t, -1, r, "I_SRCCHAN") ~= -1
          and reaper.GetTrackSendInfo_Value(t, -1, r, "P_SRCTRACK") ~= tr then
        return nil, "audio comes into its plug-ins from another track (a sidechain or a send)"
      end
    end
    for i = 0, reaper.TrackFX_GetCount(t) - 1 do
      if tonumber(select(2, reaper.TrackFX_GetNamedConfigParm(t, i, "container_count"))) then return nil, "it uses an FX container" end
      if (tonumber(select(2, reaper.TrackFX_GetNamedConfigParm(t, i, "parallel"))) or 0) ~= 0 then return nil, "plug-ins on it run in parallel" end
      if reaper.TrackFX_GetEnabled(t, i) then entries[#entries + 1] = { tr = t, i = i, name = fx_name(t, i) } end
    end
  end
  if #entries == 0 then return nil end
  local head = 0
  if midi then -- (up to the instrument, on the track that plays it; none found: the whole chain is one run)
    head = #entries
    for n, e in ipairs(entries) do
      if e.tr == (dest or tr) and (e.name:match("^%u+%d*i: ") or js_instrument(e.tr, e.i) or reaper.TrackFX_GetInstrument(e.tr) == e.i) then head = n; break end
    end
  end
  local ok, lists = pcall(require("plugins").lists, cfg)
  if not ok or #lists < 2 then return nil end
  local holders, counts = {}, {}
  for n, e in ipairs(entries) do
    holders[n] = {}
    for _, l in ipairs(lists) do
      if list_has(l, e.name) then holders[n][l.user] = true; counts[l.user] = (counts[l.user] or 0) + 1 end
    end
  end
  local runs, bad = prints.split(holders, head)
  if not runs then
    if not next(holders[bad]) then return nil, "nobody in the studio has " .. entries[bad].name:gsub("^%w+:%s*", "") end
    return nil, "its instrument and the MIDI plug-ins before it aren't all on one computer"
  end
  local bounds = {}
  for _, r in ipairs(runs) do bounds[#bounds + 1] = r.from .. "-" .. r.to end
  return { entries = entries, runs = runs, counts = counts, bounds = table.concat(bounds, ",") }
end

-- What Health says about chained prints, through ExtState "print relays <project>" (Live sync works them out; the panel shows them):
-- { {key, text, at} }, each for two minutes after it was last seen. Written when they change, or every half minute.
local relay_said, relay_sent = {}, { at = -math.huge }
local function relay_note(proj, key, text)
  local now = os.time()
  if key then relay_said[key] = { text = text, at = now } end
  local list, sig = {}, {}
  for k, v in pairs(relay_said) do
    if now - v.at < 120 then list[#list + 1] = { key = k, text = v.text, at = v.at } else relay_said[k] = nil end
  end
  table.sort(list, function(a, z) return a.key < z.key end)
  for _, x in ipairs(list) do sig[#sig + 1] = x.key .. "\0" .. x.text end
  sig = table.concat(sig, "\1")
  if sig ~= relay_sent.sig or now - relay_sent.at > 30 then
    relay_sent.sig, relay_sent.at = sig, now
    band.set_ext_json(band.SECTION, "print relays " .. tostring(proj), list, false)
  end
end
function prints.relay_notes(proj)
  local out = {}
  local list = band.ext_json(band.SECTION, "print relays " .. tostring(proj))
  for _, x in ipairs(type(list) == "table" and list or {}) do
    if type(x) == "table" and type(x.text) == "string" and os.time() - (tonumber(x.at) or 0) < 120 then out[#out + 1] = x end
  end
  return out
end

-- Which stage of a chained print this computer renders now, if any: the first whose file isn't in the media folder yet, when it's this
-- computer's (`relay`: { author, here, me, chains } from mirror's W.prints). -> { k, n, last, name, from, on, only } or nil, and whether
-- it's waiting on a computer that's here (looked at again at the next pass, not a minute later).
local relay_cant = {}
local function relay_stage(proj, tr, dest, midi, cfg, relay, oid, h, media_dir)
  local where = select(2, reaper.GetTrackName(tr))
  local cap = prints.hops_cap(require("groups").trusted(cfg.root).print_hops)
  if cap == 0 then return nil end -- (off: as before, and nothing said)
  local got = in_look(midi and "Rm" or "Ra", tr, function() -- (MIDI and audio parts on one track cut differently: the instrument's head)
    local plan, why = relay_plan(tr, dest, midi, cfg, relay.chains)
    return { plan = plan, why = why }
  end)
  local plan = got and got.plan
  if not plan then
    if got and got.why then relay_note(proj, "out " .. where, string.format("'%s' doesn't print in plug-in hand-overs: %s. Each computer plays its parts with the plug-ins it has.", where, got.why)) end
    return nil
  end
  local n = #plan.runs
  if n - 1 > cap then
    relay_note(proj, "cap " .. where, string.format("'%s' needs %d plug-in hand-overs to print; the studio allows %d (Settings > Studio > Plug-in hand-overs for prints). " ..
      "Until then each computer plays its parts with the plug-ins it has.", where, n - 1, cap))
    return nil
  end
  local who = prints.assign(plan.runs, relay.author, relay.here or {}, plan.counts)
  local sh = require("mirror").hash(plan.bounds)
  local k, found = n, {}
  for j = 1, n do
    found[j] = find_made(media_dir, j < n and stage_base(oid, h, j, sh) or ("print-" .. (oid ~= "" and oid or "item") .. "-" .. h))
    if not found[j] then k = j; break end
  end
  local run = plan.runs[k]
  local names = {}
  for x = run.from, run.to do names[#names + 1] = (plan.entries[x].name:gsub("^%w+:%s*", "")) end
  if who[k].user ~= relay.me then
    if not who[k].here then
      local step = n == 1 and string.format("only %s's computer has all of %s", tostring(who[k].user), table.concat(names, ", "))
        or string.format("it prints in %d steps, and step %d (%s) is for %s's computer", n, k, table.concat(names, ", "), tostring(who[k].user))
      relay_note(proj, "waits " .. where, string.format("A part on '%s' waits to print: %s, which is offline. Until it's back, each computer plays the part " ..
        "with the plug-ins it has.", where, step))
    end
    return nil, who[k].here
  end
  for x = run.from, run.to do -- (my list says I have it; it has to load here too)
    local e = plan.entries[x]
    if not prints.fx_here(e.tr, e.i, true) then
      if not relay_cant[names[x - run.from + 1]] then
        relay_cant[names[x - run.from + 1]] = true
        band.log(string.format("a part on '%s' waits for this computer to hand on its sound through %s, which doesn't load here", where, names[x - run.from + 1]))
      end
      return nil
    end
  end
  return {
    k = k, n = n, last = k == n, from = k > 1 and found[k - 1] or nil, on = dest or tr,
    name = k < n and (stage_base(oid, h, k, sh) .. who_suffix()) or print_name(oid, h),
    only = function() -- (only this stage's plug-ins on for the render) -> what puts the others back
      local off = {}
      for x, e in ipairs(plan.entries) do
        if x < run.from or x > run.to then reaper.TrackFX_SetEnabled(e.tr, e.i, false); off[#off + 1] = e end
      end
      return function() for _, e in ipairs(off) do reaper.TrackFX_SetEnabled(e.tr, e.i, true) end end
    end,
  }
end
-- Once its print is on, an item's stage files go (every version's: an older one's relay can't finish now, and its print would be found
-- first anyway). They're never named by a change, so nothing waits for them.
local function clear_stages(dir, oid)
  local pre = "stage-" .. (oid ~= "" and oid or "item") .. "-"
  for _, ext in ipairs({ ".flac", ".opus" }) do
    for _, f in ipairs(band.listing(dir, ext)) do
      local of = f:match("^stage%-(.+)%-%x%x%x%x%x%x%x%x%-%d+%-%x%x%x%x%x%x%x%x")
      if f:sub(1, #pre) == pre and of == (oid ~= "" and oid or "item") then os.remove(dir .. "/" .. f) end
    end
  end
end

-- Make or refresh the print of a MIDI item (rendered through its track: this tab in front, transport stopped).
-- Only when the track's plug-ins all load here (else the print would be silent). Returns true when the item changed.
-- An audio take with Melodyne (or another ARA plug-in) gets its print the same way (see prints.ARA). A track that
-- plays an instrument on another track (prints.route) prints through that track (sync.print_routed), and that
-- track's chain (`route_hash`) is part of what the print is made from.
-- An audio item gets one too when its track has a plug-in someone in the band lacks (`cfg`: whose band). Prints
-- render in the background where that works (prints.render), so this returns true on the pass that picks one up.
-- `relay` (0.59.49): nobody has the whole chain, so it may print in stages (relay_stage); a second result true says a stage waits on a
-- computer that's here, so the part is looked at again at the next pass.
function prints.refresh(proj, it, media_dir, fx_hash, route_hash, cfg, relay)
  local midi, print = prints.takes(it)
  local tr = reaper.GetMediaItem_Track(it)
  -- (a pass on a lane nobody hears: printed once it plays. Every pass of a comp was rendered: laptop, 0.42.5)
  if reaper.GetMediaTrackInfo_Value(tr, "I_FREEMODE") == 2
    and reaper.GetMediaTrackInfo_Value(tr, "C_LANEPLAYS:" .. math.floor(reaper.GetMediaItemInfo_Value(it, "I_FIXEDLANE"))) == 0 then return false end
  local audio = not midi and prints.audio_take(it)
  if not midi and not audio then return refresh_ara(proj, it, media_dir) end
  local dest = midi and prints.route(tr)
  -- (in a relay this computer has only its stage's plug-ins: relay_stage checks those load here)
  if (reaper.TrackFX_GetCount(tr) == 0 and not dest) or not (relay or prints.track_plays(tr, true)) then return false end
  if audio and (not prints.lacking(tr, cfg) or prints.from_band(it, audio)) then return false end
  -- (MIDI as audio: only where a plug-in is missing for someone, or a sample player's content can't be seen. James, 0.59.49)
  local wanted = not midi or prints.midi_prints(tr, dest, cfg)
  if not (wanted or print) then return false end
  local dry = midi or audio
  local h, old
  if midi then h, old = prints.source(it, midi, (fx_hash or "") .. (dest and ("\0" .. (route_hash or "")) or ""))
  else h = prints.audio_source(it, audio, fx_hash) end
  -- (several takes: which one is picked is part of what it's made from, so picking another prints again. James, rt)
  local pick = several_pick(it)
  if pick then h, old = require("mirror").hash(h .. "|t" .. pick), nil end
  if print and (take_ext(print, prints.KEY) == h or old and take_ext(print, prints.KEY) == old) then return false end
  -- (one that no longer prints, with a print of notes it no longer has: the print comes off, and the part goes out without it. Kept, Sound and a
  -- track set to "wet" went on playing the old notes everywhere. Cost: one notes hash, only for such a part with a print. Round 4 review, 0.59.49)
  if not wanted then
    drop_print(proj, it, print)
    prints.choose(it)
    reaper.UpdateItemInProject(it)
    return true
  end
  local oid = select(2, reaper.GetSetMediaItemInfo_String(it, "P_EXT:band_oid", "", false))
  local stage, waiting
  if relay then
    stage, waiting = relay_stage(proj, tr, dest, midi, cfg, relay, oid, h, media_dir)
    if not stage then return false, waiting end
  end
  local name = stage and stage.name or print_name(oid, h)
  if prints.silent[name] then return false end -- (came out silent once: not again until what it's made from changes)
  made_dir(media_dir)
  local sync = require("sync")
  local path = prints.render(oid, name, media_dir, dest and { tr, dest } or { tr }, function(_, front) -- (front: rendered here, into this folder first)
    local back = stage and stage.only() -- (a stage: only its plug-ins, put back whatever the render does)
    local ok, p = pcall(function()
      if stage and stage.from then return sync.print_file(proj, stage.on, it, stage.from, front or media_dir, name) end
      if dest then return sync.print_routed(proj, it, midi, dest, front or media_dir, name) end
      return sync.print_item(proj, it, dry, front or media_dir, name, nil, false, true)
    end)
    if back then back() end
    if not ok then error(p, 0) end
    return p
  end, reaper.GetMediaItemInfo_Value(it, "D_LENGTH"), not stage and audio and stock_only(tr)) -- (quick: audio through REAPER's own effects, nothing to load)
  if not path then return false end
  -- a print of notes that came out silent: the instrument loaded but its sounds didn't (a Kontakt library or an EZX that isn't
  -- installed here). Kept, it played silence for everyone who lacked the instrument, and nothing said so (plug-ins review, 0.58.76)
  if midi and prints.silent[name] == nil then
    local _, notes = reaper.MIDI_CountEvts(midi)
    prints.silent[name] = notes > 0 and prints.silent_file(path) or false
    if prints.silent[name] then
      -- (only a print this computer rendered: one found under a bandmate's name was theirs, deleted from the shared folder, and changes
      -- pointing at it waited for it for good. Review, 0.58.87)
      local who = (reaper.GetExtState(band.SECTION, "user"):gsub("[^%w%-_]", "_"))
      if who ~= "" and path:match("%-" .. who:gsub("%p", "%%%0") .. "%.flac$") then os.remove(path) end
      prints.problem("A part on " .. select(2, reaper.GetTrackName(tr)) .. " printed silent: its instrument loaded but its sounds didn't (is its library or kit " ..
        "installed here?). Fix that, then Try again. Until then, collaborators without the instrument don't hear that part.")
    end
  end
  if audio and prints.silent[name] == nil then -- (an audio print came out silent with no word: plug-in test, 0.59.14)
    local src = reaper.GetMediaSourceFileName(reaper.GetMediaItemTake_Source(audio), "")
    prints.silent[name] = prints.silent_file(path) and src ~= "" and not prints.silent_file(src) or false
    if prints.silent[name] then
      local who = (reaper.GetExtState(band.SECTION, "user"):gsub("[^%w%-_]", "_"))
      if who ~= "" and path:match("%-" .. who:gsub("%p", "%%%0") .. "%.flac$") then os.remove(path) end
      prints.problem("A part on " .. select(2, reaper.GetTrackName(tr)) .. " printed silent though its recording isn't: a plug-in may not have loaded in time. Press Try again.")
    end
  end
  if prints.silent[name] then return false end
  if stage and not stage.last then -- (a stage in the shared folder: the next computer takes it from there)
    band.log(string.format("a part on '%s': step %d of %d of its print is rendered here, for the next computer to carry on", select(2, reaper.GetTrackName(tr)), stage.k, stage.n))
    return false, true
  end
  if dest then prints.midi_only(tr, dest) end
  attach(it, print, dry, path, h, pick)
  if stage then clear_stages(media_dir, oid) end
  prints.choose(it)
  reaper.UpdateItemInProject(it)
  return true
end

prints.silent = {} -- print name -> whether it came out silent (looked at once)
-- Whether an audio file is silent: REAPER answers "no change", 1.0, both to its peak at 0 dB and to its loudness at -23 LUFS
-- (as extras' stems do; measured, 0.58.52).
function prints.silent_file(path)
  local src = reaper.PCM_Source_CreateFromFile(path)
  if not src then return false end
  local silent = reaper.CalculateNormalization(src, 2, 0, 0, 0) == 1 and reaper.CalculateNormalization(src, 0, -23, 0, 0) == 1
  reaper.PCM_Source_Destroy(src)
  return silent
end

-- ---- who prints (0.39) -----------------------------------------------------------------------------------------
-- An item's print is made by (James, 2026-11-01):
--   1. the bandmate in charge of printing its track ("Print selected tracks here", kept in their claims file), when
--      they're in the song now and have every plug-in it plays through;
--   2. else whoever changed it last, if they have those plug-ins (here or not: theirs waits for them);
--   3. else the first bandmate in the song now, by name, who has them.
-- Every machine works it out the same way, so one machine prints it. Whether someone has a plug-in: their published
-- list (lib/plugins.lua); this machine: whether it actually loads here.

-- The plug-in keys an item's print goes through: its track's, and the instrument track's for a routed one.
function prints.track_keys(tr)
  local plugins, keys = require("plugins"), {}
  for _, t in ipairs({ tr, prints.route(tr) }) do
    for _, i in ipairs(prints.fx_all(t)) do
      local ok, name = reaper.TrackFX_GetNamedConfigParm(t, i, "fx_name")
      if not ok or name == "" then name = select(2, reaper.TrackFX_GetFXName(t, i)) end
      keys[#keys + 1] = plugins.key(name)
    end
  end
  return keys
end
local lists = { at = -math.huge, by = {} } -- user -> set of plug-in keys (their published list), read once a minute
function prints.has(cfg, user, keys)
  if reaper.time_precise() - lists.at > 60 then
    lists.at, lists.by = reaper.time_precise(), {}
    for _, f in ipairs(band.files(cfg.root .. "/plugins", ".json")) do
      local l = band.read_json(cfg.root .. "/plugins/" .. f)
      if type(l) == "table" and type(l.user) == "string" and type(l.names) == "table" then
        local set = {}
        for _, k in ipairs(l.names) do set[k] = true end
        lists.by[l.user] = set
      end
    end
  end
  local set = lists.by[user]
  if not set then return false end
  local video = require("video")
  for _, k in ipairs(keys) do if not set[k] and not video.builtin_fx(k) then return false end end -- (the Video processor: everyone's. rt-video2)
  return true
end
-- Who prints this item: a user name, or nil (nobody can). `author`: who changed it last; `here`: { user = true }
-- (bandmates in the song now, this machine's user too); `printers`: sync.authority's (lower track name -> {user}).
-- `can(user)`: whether that user has every plug-in it plays through. Pure.
function prints.printer(track, author, here, printers, can)
  local d = printers[(track or ""):lower()]
  if d and here[d.user] and can(d.user) then return d.user end
  if author and can(author) then return author end
  local names = {}
  for u in pairs(here) do names[#names + 1] = u end
  table.sort(names)
  for _, u in ipairs(names) do if can(u) then return u end end
  return nil
end

-- Claims card: "Print selected tracks here", and who prints what. (In this file: the panel is near Lua's limit.)
function prints.printing_ui(ctx, ImGui, cfg, b, proj, who)
  local sync = require("sync")
  local function save(fn)
    local c, why = sync.my_claims(cfg, b.song, b.room)
    if not c then return band.msg(why) end
    c.prints = c.prints or {}
    fn(c)
    sync.set_claims(cfg, b.song, b.room, c)
  end
  if ImGui.Button(ctx, "Print selected tracks here") then
    if reaper.CountSelectedTracks(proj) == 0 then return band.msg("Select the tracks you want to print first.") end
    save(function(c)
      for i = 0, reaper.CountSelectedTracks(proj) - 1 do
        local n = sync.base_name(select(2, reaper.GetTrackName(reaper.GetSelectedTrack(proj, i))))
        local dup = false
        for _, x in ipairs(c.prints) do dup = dup or x:lower() == n:lower() end
        if not dup then c.prints[#c.prints + 1] = n end
      end
    end)
  end
  ImGui.SetItemTooltip(ctx, "Their prints are rendered here, with your plug-ins, whoever changes them: while you're in the project\n" ..
    "and have every plug-in they play through. Otherwise whoever changed them prints, or someone here who has the plug-ins.")
  local mine, others = {}, {}
  for _, p in pairs(who and who.printers or {}) do
    if p.user == cfg.user then mine[#mine + 1] = p.name else others[#others + 1] = p.name .. " (" .. p.user .. ")" end
  end
  table.sort(mine); table.sort(others)
  if #mine > 0 then
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, "Stop printing them") then save(function(c) c.prints = {} end) end
    ImGui.TextDisabled(ctx, "You print: " .. table.concat(mine, ", "))
  end
  if #others > 0 then ImGui.TextDisabled(ctx, "Printed by: " .. table.concat(others, ", ")) end
end

-- Setup > Options: rendering in the background, this machine's choice.
function prints.options(ctx, ImGui)
  local set, default = reaper.GetExtState(band.SECTION, "bg render"), require("bgrender").default_on()
  local on = set == "on" or (default and set ~= "off")
  local rv, v = ImGui.Checkbox(ctx, "Render prints in the background##bgrender", on)
  if rv then reaper.SetExtState(band.SECTION, "bg render", v == default and "" or (v and "on" or "off"), true) end
  ImGui.SetItemTooltip(ctx, "On: a hidden second REAPER renders each print while you keep working (a few seconds each).\n" ..
    "Off: REAPER renders them in front, holding up the screen for a moment each time." ..
    (default and "" or "\nOff by default here: this computer has no way to keep the second REAPER hidden, so it would take the keyboard for a moment each time."))
  -- (how it's going, from Live sync: lib/bgrender.lua. Given up, prints render here in front: James, 0.58.86, "it should show")
  local st = on and prints.bg_state()
  if st and st.gave_up then
    ImGui.TextColored(ctx, require("theme").YELLOW, string.format("The background renderer failed %d times (%s), so prints render here, in front.", st.failed or 0, st.why or "no reason given"))
    if ImGui.SmallButton(ctx, "Try in the background again##bgretry") then prints.bg_retry() end
    ImGui.SetItemTooltip(ctx, "Starts the hidden second REAPER again for the next print. Each failure is in the log (Console > Log files).")
  elseif st and (st.failed or 0) > 0 then
    ImGui.TextDisabled(ctx, string.format("Background renders: %d done, %d failed (%s). It keeps trying until %d fail with none done.", st.done or 0, st.failed, st.why or "?", require("bgrender").GIVE_UP))
  end
end
-- Settings > Studio: "Plug-in hand-overs for prints" (chained prints, James 0.59.49). `may`: the owner or an admin, who change it.
prints.HOPS = { { 0, "Off" }, { 1, "1" }, { 2, "2" }, { 3, "3" }, { "any", "No cap" } }
function prints.hops_ui(ctx, ImGui, cfg, may)
  ImGui.SeparatorText(ctx, "Plug-in hand-overs for prints")
  local cap = prints.hops_cap(require("groups").trusted(cfg.root).print_hops)
  ImGui.TextDisabled(ctx, "When no computer has every plug-in on a track, its parts print in steps: each computer renders the plug-ins it has and " ..
    "hands the sound on through the shared folder. This many hand-overs at most (each is one more render and a few seconds); a part that needs " ..
    "more, or Off, isn't printed, and each computer plays it with the plug-ins it has. Health says which.")
  for i, o in ipairs(prints.HOPS) do
    if i > 1 then ImGui.SameLine(ctx) end
    local on = cap == prints.hops_cap(o[1])
    if may then
      if ImGui.RadioButton(ctx, o[2] .. "##printhops", on) and not on then
        require("groups").set_print_hops(cfg.root, o[1] ~= 2 and o[1] or nil)
        band.log("plug-in hand-overs for prints: " .. o[2] .. " for everyone in the studio")
      end
    elseif on then ImGui.Text(ctx, "Now: " .. o[2]) end
  end
  if may then ImGui.SetItemTooltip(ctx, "Owner and admins. 2 covers two computers that each lack something the other has.") end
end
-- Settings > Studio: "Takes become lanes" (band.json "takes_to_lanes", on unless it's false: lib/groups.lua). `may`: owner or admin. (James, rt)
function prints.lanes_ui(ctx, ImGui, cfg, may)
  ImGui.SeparatorText(ctx, "Takes become lanes")
  local on = require("groups").takes_to_lanes(cfg.root)
  ImGui.TextDisabled(ctx, on and ("On: keeps everyone's projects alike across REAPER setups. A part recorded with several takes becomes fixed lanes " ..
    "(the takes you picked stay the comp), whoever's REAPER recorded it, so every computer plays and edits it the same way.") or
    ("Off: takes stay takes, as each REAPER recorded them; the picked take is still the studio's, and it gets a print where someone lacks a plug-in. " ..
    "On keeps everyone's projects alike across REAPER setups."))
  if may then
    local ch, v = ImGui.Checkbox(ctx, "Takes become lanes##studiolanes", on)
    if ch then
      require("groups").set_takes_to_lanes(cfg.root, v)
      band.log(v and "takes become lanes again for the studio" or "takes stay takes for the studio from now on (Settings > Studio)")
    end
    ImGui.SetItemTooltip(ctx, "Owner and admins. \"Set up this project\" and its lane setup stay as they are either way.")
  end
end

-- What Live sync's background renderer says (ExtState "bg render state"), or nil.
function prints.bg_state() return band.ext_json(band.SECTION, "bg render state") end
function prints.bg_retry()
  reaper.SetExtState(band.SECTION, "bg render retry", tostring(os.time()), false)
  reaper.DeleteExtState(band.SECTION, "bg render state", false)
  band.log("prints: the background renderer gets another go with the next print")
end

-- ---- takes become lanes (0.39) -----------------------------------------------------------------------------------
-- In a band song, an item's takes (several in one item, one playing) become fixed lanes, the way REAPER 7 keeps
-- alternatives (James, 2026-11-01): REAPER's own "explode takes to fixed lanes and add comp areas from active takes"
-- (42636), which keeps a comp exactly (tested: the same render, sample for sample, before and after), so a take
-- picked per stretch becomes a comp lane. Wet takes then work on every lane. Per track, only by whoever owns one of
-- its items' takes (`mine(item)`: their newest change, or not sent yet), so two machines never explode one at once;
-- a track holding a wet take (or an ARA one) waits, as exploding would split print from item. Returns tracks done.
-- A track already in lanes: each item with several takes keeps the one playing, in the lane that plays, and each other take
-- becomes its own item on a new lane at the bottom.
function prints.takes_into_new_lanes(proj, tr, mine)
  local items = {}
  for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
    local it = reaper.GetTrackMediaItem(tr, j)
    if require("mirror").filled_takes(it) > 1 and mine(it) then items[#items + 1] = it end
  end
  local exploding = {}
  for _, it in ipairs(items) do exploding[it] = true end
  local function new_lane()
    local lanes = reaper.GetMediaTrackInfo_Value(tr, "I_NUMFIXEDLANES")
    reaper.SetMediaTrackInfo_Value(tr, "I_NUMFIXEDLANES", lanes + 1)
    reaper.SetMediaTrackInfo_Value(tr, "C_LANEPLAYS:" .. lanes, 0)
    return lanes
  end
  -- Each take's place gets one lane, shared by every item's take in that place where they don't overlap (a comp split into twenty
  -- pieces made twenty lanes for each take, 0.58.85): the second takes together, the third together, as REAPER's explode lays them out.
  local lane_of_slot = {}
  local function free_at(lane, from, to, except)
    for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
      local x = reaper.GetTrackMediaItem(tr, j)
      if x ~= except and reaper.GetMediaItemInfo_Value(x, "I_FIXEDLANE") == lane then
        local a = reaper.GetMediaItemInfo_Value(x, "D_POSITION")
        -- (a crossfade's few milliseconds aren't a clash: each piece of a comp overlaps the next by that much)
        if a < to - 0.1 and a + reaper.GetMediaItemInfo_Value(x, "D_LENGTH") > from + 0.1 then return false end
      end
    end
    return true
  end
  local function lane_for(slot, from, to, except)
    local l = lane_of_slot[slot]
    if not (l and free_at(l, from, to, except)) then l = new_lane(); lane_of_slot[slot] = l end
    return l
  end
  local function crop_to_active(it)
    reaper.SetMediaItemSelected(it, true)
    reaper.Main_OnCommand(40131, 0) -- Take: Crop to active take in items
    reaper.SetMediaItemSelected(it, false)
  end
  for _, it in ipairs(items) do
    local _, chunk = reaper.GetItemStateChunk(it, "", false)
    -- (a copy with ids of its own: REAPER makes them new, and mirror takes it as a new item)
    chunk = chunk:gsub("\n%s*IGUID [^\n]*", ""):gsub("\n%s*GUID [^\n]*", ""):gsub("\n%s*band_oid [^\n]*", ""):gsub("\n%s*band_[%w_]+ [^\n]*", "")
    local cur = reaper.GetMediaItemInfo_Value(it, "I_CURTAKE")
    local own = math.floor(reaper.GetMediaItemInfo_Value(it, "I_FIXEDLANE"))
    local from0 = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
    local to0 = from0 + reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
    for k = 0, reaper.CountTakes(it) - 1 do
      -- (by place, not by pointer: an empty take has none, and two empty ones looked alike, so the playing one was copied too)
      if k ~= cur and reaper.GetTake(it, k) then -- (an empty take holds nothing to put on a lane)
        local copy = reaper.AddMediaItemToTrack(tr)
        reaper.SetItemStateChunk(copy, chunk, false)
        reaper.SetMediaItemInfo_Value(copy, "I_CURTAKE", k)
        crop_to_active(copy)
        reaper.SetMediaItemInfo_Value(copy, "I_FIXEDLANE", lane_for(k, from0, to0, copy))
      end
    end
    crop_to_active(it)
    -- (it stays on its own lane: a pass on a lane that doesn't play was moved into the one that does, and the comp under it went
    -- silent for everyone. Review, 0.58.87. Only one on a playing lane moves what it was played over out of the way)
    reaper.SetMediaItemInfo_Value(it, "I_FIXEDLANE", own)
    local from = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
    local to = from + reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
    for j = (reaper.GetMediaTrackInfo_Value(tr, "C_LANEPLAYS:" .. own) > 0 and reaper.CountTrackMediaItems(tr) or 0) - 1, 0, -1 do
      local x = reaper.GetTrackMediaItem(tr, j)
      local x_at = reaper.GetMediaItemInfo_Value(x, "D_POSITION")
      if x ~= it and not exploding[x] and mine(x) and reaper.GetMediaItemInfo_Value(x, "I_FIXEDLANE") == own
        and x_at < to and x_at + reaper.GetMediaItemInfo_Value(x, "D_LENGTH") > from then
        reaper.SetMediaItemInfo_Value(x, "I_FIXEDLANE", new_lane())
      end
    end
  end
  reaper.UpdateArrange()
end

prints.LANES_UNDO = "StudioSync: takes became lanes"
-- `root`: the studio, whose setting (band.json "takes_to_lanes", on unless false) says whether this runs at all; nil (the tests) runs it.
function prints.takes_to_lanes(proj, mine, root)
  if root and not require("groups").takes_to_lanes(root) then return 0 end -- (a studio setting now, the owner's. James, rt)
  local done = 0
  -- (Ctrl+Z on it: the next pass split them again. Undone, the track keeps its takes from then on, until none has two. Review, 0.58.91)
  if reaper.Undo_CanRedo2 and reaper.Undo_CanRedo2(proj) == prints.LANES_UNDO then
    local _, g = reaper.GetProjExtState(proj, band.SECTION, "lanes last")
    local tr = g ~= "" and reaper.BR_GetMediaTrackByGUID and reaper.BR_GetMediaTrackByGUID(proj, g)
    if not tr then for i = 0, reaper.CountTracks(proj) - 1 do if reaper.GetTrackGUID(reaper.GetTrack(proj, i)) == g then tr = reaper.GetTrack(proj, i) end end end
    if tr and band.track_ext(tr, "band_keep_takes") == "" then
      band.set_track_ext(tr, "band_keep_takes", "1")
      band.log("you undid the takes on " .. select(2, reaper.GetTrackName(tr)) .. " becoming lanes: they stay takes")
    end
  end
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    local want, blocked = false, require("mirror").local_track(tr)
    local keep = band.track_ext(tr, "band_keep_takes") ~= ""
    local any = false
    local in_lanes0 = reaper.GetMediaTrackInfo_Value(tr, "I_FREEMODE") == 2 and reaper.GetMediaTrackInfo_Value(tr, "I_NUMFIXEDLANES") > 1
    for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
      local it = reaper.GetTrackMediaItem(tr, j)
      local real = reaper.CountTakes(it) > 1 and require("mirror").filled_takes(it) or 0 -- (only "more than one" matters: one take, nothing to read. 0.59.19)
      if real > 1 and prints.ara_take(it) then blocked = true end
      if real > 1 and mine(it) then want = true end
      if real > 1 then any = true end
      -- (a bandmate's: REAPER's explode works on the whole track, and their prints were deleted with ours, where this computer couldn't
      -- print them again. A locked one: the crop and delete don't happen, so it went round every pass. Review, 0.58.87)
      if real > 1 and not mine(it) then blocked = true end
      if not in_lanes0 and select(2, prints.takes(it)) and not mine(it) then blocked = true end
      if real > 1 and reaper.GetMediaItemInfo_Value(it, "C_LOCK") % 2 == 1 then blocked = true end
    end
    if keep and not any then band.set_track_ext(tr, "band_keep_takes", "") end -- (no takes left to keep: split again from now on)
    if want and not blocked and not keep then
      reaper.SetProjExtState(proj, band.SECTION, "lanes last", reaper.GetTrackGUID(tr))
      reaper.PreventUIRefresh(1) -- (every part was selected and let go one after another, flashing across the project: review, 0.58.87)
      reaper.Undo_BeginBlock2(proj) -- (one point, named StudioSync's: Ctrl+Z on "Crop to active take" brought the takes back, to split again)
      local lanes_ok, lanes_err = pcall(function() -- (an error in here left REAPER's screen frozen and the undo point open. Review, 0.58.92)
      -- wet takes go first, or they'd become lanes of their own; the comp's item prints again. (Waiting for a track with no
      -- wet takes meant any comp on a played part stayed takes, and the takes picked never reached the band: laptop, 0.42.4)
      local picked = {}
      for s = 0, reaper.CountSelectedMediaItems(proj) - 1 do picked[#picked + 1] = reaper.GetSelectedMediaItem(proj, s) end
      for _, x in ipairs(picked) do reaper.SetMediaItemSelected(x, false) end
      local in_lanes = reaper.GetMediaTrackInfo_Value(tr, "I_FREEMODE") == 2 and reaper.GetMediaTrackInfo_Value(tr, "I_NUMFIXEDLANES") > 1 -- (one lane is the first time: its comp is th
      for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
        local it = reaper.GetTrackMediaItem(tr, j)
        -- (in lanes only the items being split: the others kept their prints and bandmates' parts were re-sent. And every wet take:
        -- one from an old version holds three, and the other two came out as plain parts on lanes of their own)
        local _, wet = prints.takes(it)
        if in_lanes and not (require("mirror").filled_takes(it) > 1 and mine(it)) then wet = nil end
        -- (the take that plays is kept by its place among the real takes: deleting a take can leave a take pointer pointing at nothing,
        -- and REAPER then played the first take, so the comp lost its pick. 0.58.85)
        local pick = require("mirror").picked_take(it)
        for _ = 1, 8 do -- (bounded: a take that won't delete can't spin forever)
          if not wet then break end
          reaper.SetActiveTake(wet)
          reaper.SetMediaItemSelected(it, true)
          reaper.Main_OnCommand(40129, 0) -- Take: Delete active take from items
          reaper.SetMediaItemSelected(it, false)
          wet = select(2, prints.takes(it))
        end
        if pick then require("mirror").pick_take(it, pick) end
      end
      for _, x in ipairs(picked) do if reaper.ValidatePtr2(proj, x, "MediaItem*") then reaper.SetMediaItemSelected(x, true) end end
      local sel = {}
      for s = 0, reaper.CountSelectedTracks(proj) - 1 do sel[#sel + 1] = reaper.GetSelectedTrack(proj, s) end
      -- already in lanes: REAPER's explode adds a new comp lane on top that plays alone, holding only the newest part, and
      -- everything else on the track went silent for everyone, with nothing saying so (laptop, 0.42.5). Moving what it makes
      -- back into the old comp lane loses it (0.42.6). So it isn't used: the take being played stays in the lane that's
      -- playing, and each other take gets a new lane at the bottom.
      reaper.SetOnlyTrackSelected(tr)
      if in_lanes then prints.takes_into_new_lanes(proj, tr, mine)
      else reaper.Main_OnCommand(42636, 0) end -- Take: Explode takes on selected tracks to fixed lanes and add comp areas from active takes
      local n = 0 -- (the take lanes come out "1" and unnamed: "Take 1", "Take 2"...; the comp lane stays "C1")
      for l = 0, reaper.GetMediaTrackInfo_Value(tr, "I_NUMFIXEDLANES") - 1 do -- (and carry on from any there already)
        n = math.max(n, tonumber(select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_LANENAME:" .. l, "", false)):match("^Take (%d+)$")) or 0)
      end
      for l = 0, reaper.GetMediaTrackInfo_Value(tr, "I_NUMFIXEDLANES") - 1 do
        local name = select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_LANENAME:" .. l, "", false))
        if name == "" or name:match("^%d+$") then n = n + 1; reaper.GetSetMediaTrackInfo_String(tr, "P_LANENAME:" .. l, "Take " .. n, true) end
      end
      reaper.SetTrackSelected(tr, false)
      for _, s in ipairs(sel) do if reaper.ValidatePtr2(proj, s, "MediaTrack*") then reaper.SetTrackSelected(s, true) end end
      end)
      reaper.PreventUIRefresh(-1)
      reaper.Undo_EndBlock2(proj, prints.LANES_UNDO, -1)
      if not lanes_ok then error(lanes_err, 0) end
      band.log("the takes on " .. select(2, reaper.GetTrackName(tr)) .. " became lanes (the takes you picked stay the comp)")
      done = done + 1
    end
  end
  return done
end

return prints
