-- Colouring a whole project at once (James, 2026-11-04): a gradient, by folder, by instrument, by who made it and a few more for tracks; regions by section or along the song.
-- It's the studio's colour, so it goes to everyone like any colour change. Who's working (lib/people.lua) still shows on top where a computer has that on.
local band = require("band")
local colours = {}

-- Colours are 0xRRGGBB here; REAPER's native form only at the edges (native below).
colours.PALETTES = {
  { "Sunset", { 0x2F7BFF, 0x8A5BE8, 0xFF8A3D } }, -- (the logo's: blue to orange through violet, as straight across goes grey)
  { "Ocean", { 0x0B3C5D, 0x1F8FB3, 0x6FE3D6 } },
  { "Forest", { 0x1E4D2B, 0x5E9E4A, 0xD9D26A } },
  { "Ember", { 0x5A1A2B, 0xD1493F, 0xFFC15A } },
  { "Neon", { 0xFF3DA5, 0x7A5CFF, 0x2DE2E6 } },
  { "Pastel", { 0xF7B2C4, 0xB8C7F9, 0xB4EBD4 } },
  { "Greys", { 0x3A4150, 0x7E8798, 0xD5DAE3 } },
}
colours.SCHEMES = {
  { "gradient", "Gradient", "Top track to bottom track, smoothly through the palette." },
  { "folders", "By folder", "Each folder its own colour, the tracks inside it shades of that." },
  { "instrument", "By instrument", "From the track's name: drums, bass, guitars, keys, synths, vocals, strings and horns, buses." },
  { "person", "By who made it", "Each track in the colour of the person who made it, kept even when nobody's working." },
  { "stripes", "Stripes", "Two colours taking turns, folder by folder: easy to follow across a long list." },
  { "rainbow", "Rainbow", "The whole colour wheel, top to bottom." },
  { "newest", "Newest work", "Where the project's been moving lately: the palette's first colour for the track untouched longest, its last for the latest changed." },
  { "confetti", "Confetti", "A bright colour of its own for each name, the same every time." },
}

function colours.mix(a, b, t)
  local function ch(s) return math.floor(((a >> s) & 255) + (((b >> s) & 255) - ((a >> s) & 255)) * t + 0.5) end
  return (ch(16) << 16) | (ch(8) << 8) | ch(0)
end
-- A place (0 to 1) along a list of colours.
function colours.ramp(stops, t)
  if #stops == 1 then return stops[1] end
  t = math.max(0, math.min(1, t)) * (#stops - 1)
  local i = math.min(#stops - 2, math.floor(t))
  return colours.mix(stops[i + 1], stops[i + 2], t - i)
end
function colours.hsv(h, s, v)
  local i, f = math.floor(h * 6) % 6, h * 6 - math.floor(h * 6)
  local p, q, u = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
  local r, g, b = ({ v, q, p, p, u, v })[i + 1], ({ u, v, v, q, p, p })[i + 1], ({ p, p, u, v, v, q })[i + 1]
  return (math.floor(r * 255 + 0.5) << 16) | (math.floor(g * 255 + 0.5) << 8) | math.floor(b * 255 + 0.5)
end

-- What a name says it is. First match wins, so "bass drum" is drums and "vocal bus" is a bus.
local KINDS = {
  { 0x8A93A6, { "bus", "master", "reverb", "verb", "delay", "aux", "return", "%f[%a]fx%f[%A]" } },
  { 0xE5584F, { "drum", "kick", "snare", "%f[%a]hat", "tom%f[%A]", "perc", "shaker", "cymbal", "overhead", "%f[%a]oh%f[%A]", "tamb", "clap" } },
  { 0xF2A33A, { "bass", "%f[%a]sub%f[%A]" } },
  { 0x57B85A, { "guitar", "gtr", "acoustic", "riff" } },
  { 0x4C9BE8, { "piano", "keys", "%f[%a]key", "organ", "rhodes", "wurli" } },
  { 0x9A6BE8, { "synth", "%f[%a]pad", "arp", "pluck" } },
  { 0xF06BAF, { "vox", "vocal", "voc%f[%A]", "sing", "harmony", "bgv", "choir", "%f[%a]lead" } },
  { 0x36C4B4, { "string", "violin", "viola", "cello", "brass", "horn", "trumpet", "sax", "flute" } },
}
colours.OTHER = 0xA9B0BD
-- Their names, for setting their colours (James, 0.59.3: "color tracks based on instrument should get a way to set those colors"), kept per
-- computer (ExtState "colour kinds": { [name] = "RRGGBB" }).
colours.KIND_NAMES = { "Buses and effects", "Drums", "Bass", "Guitars", "Keys", "Synths", "Vocals", "Strings and horns" }
local kind_cache, kind_at = nil, -math.huge
function colours.kind_colours()
  if kind_cache and reaper.time_precise() - kind_at < 2 then return kind_cache end
  local saved = band.ext_json(band.SECTION, "colour kinds")
  local out = {}
  for i, k in ipairs(KINDS) do
    local v = type(saved) == "table" and tonumber(tostring(saved[colours.KIND_NAMES[i]] or ""), 16)
    out[i] = v or k[1]
  end
  kind_cache, kind_at = out, reaper.time_precise()
  return out
end
function colours.set_kind_colour(i, rgb)
  local saved = band.ext_json(band.SECTION, "colour kinds")
  if type(saved) ~= "table" then saved = {} end
  saved[colours.KIND_NAMES[i]] = rgb and string.format("%06X", rgb) or nil
  band.set_ext_json(band.SECTION, "colour kinds", saved, true)
  kind_cache = nil
end
function colours.kind_of(name)
  local n = (name or ""):lower()
  local set = reaper and reaper.GetExtState and colours.kind_colours() or nil
  for i, k in ipairs(KINDS) do
    for _, w in ipairs(k[2]) do if n:find(w) then return set and set[i] or k[1] end end
  end
  return colours.OTHER
end

-- Colours set by name (James, 0.59.4: "a way to set colors for each region, folder etc like we have for instruments"), per computer:
-- ExtState "colour <kind>" = { [name] = "RRGGBB" }. kind "folders" (a top-level folder's name, lower case), "sections" (verse, chorus...:
-- colours.section_key), "itemkinds" (midi, print, audio).
local named_cache = {}
function colours.named(kind)
  local c = named_cache[kind]
  if c and reaper.time_precise() - c.at < 2 then return c.v end
  local saved, out = band.ext_json(band.SECTION, "colour " .. kind), {}
  if type(saved) == "table" then
    for k, v in pairs(saved) do local n = type(k) == "string" and tonumber(tostring(v), 16); if n then out[k] = n end end
  end
  named_cache[kind] = { at = reaper.time_precise(), v = out }
  return out
end
function colours.set_named(kind, key, rgb)
  local saved = band.ext_json(band.SECTION, "colour " .. kind)
  if type(saved) ~= "table" then saved = {} end
  saved[key] = rgb and string.format("%06X", rgb) or nil
  band.set_ext_json(band.SECTION, "colour " .. kind, saved, true)
  named_cache[kind] = nil
end
function colours.forget_named(kind) reaper.DeleteExtState(band.SECTION, "colour " .. kind, true); named_cache[kind] = nil end

-- Each family's base colour for "By folder": the one set for its folder's name, else along the palette. -> { [family] = rgb }. Pure.
function colours.folder_bases(tracks, stops, named)
  local families, out = 0, {}
  for _, t in ipairs(tracks) do families = math.max(families, t.family or 0) end
  for _, t in ipairs(tracks) do
    local f = t.family or 0
    if out[f] == nil then
      local key = t.folder and t.folder:lower()
      out[f] = (named and key and named[key]) or colours.ramp(stops, families > 1 and (f - 1) / (families - 1) or 0)
    end
  end
  return out
end

-- A colour swatch with ColorEdit's wheel that keeps its own colour while you drag in it, and hands it over once you let go (James, 0.59.6:
-- dragging in the triangle could spin it round: the colour passed back each frame came from elsewhere, a little off, and the wheel took its
-- hue from that). commit(rgb) on letting go. -> changed, done.
-- (0.59.7: it still wiggled. Handed RGB, the wheel works its hue out again from 8-bit numbers every frame, and near grey that hue jumps
-- about; handed HSV (InputHSV) it keeps the hue it's given. So the swatch is given HSV, held as it was dragged, and turned into RGB here.)
function colours.to_hsv(rgb) -- 0xRRGGBB -> h, s, v (0 to 1). Pure.
  local r, g, b = ((rgb >> 16) & 255) / 255, ((rgb >> 8) & 255) / 255, (rgb & 255) / 255
  local mx, mn = math.max(r, g, b), math.min(r, g, b)
  local d, h = mx - mn, 0
  if d > 0 then
    if mx == r then h = ((g - b) / d) % 6 elseif mx == g then h = (b - r) / d + 2 else h = (r - g) / d + 4 end
    h = h / 6
  end
  return h, mx > 0 and d / mx or 0, mx
end
local function pack(h, s, v) local function q(x) return math.floor(x * 255 + 0.5) end; return (q(h) << 16) | (q(s) << 8) | q(v) end
function colours.hsv_int(rgb) return pack(colours.to_hsv(rgb)) end
function colours.rgb_of_hsv(x) return colours.hsv(((x >> 16) & 255) / 255, ((x >> 8) & 255) / 255, (x & 255) / 255) end
local held, last = {}, {}
function colours.edit3(ctx, ImGui, label, value, commit, flags)
  local l = last[label]
  local shown = held[label] or (l and l.rgb == value and l.hsv) or colours.hsv_int(value) -- (the hue it was left at, while the colour's the one it gave)
  local ch, v = ImGui.ColorEdit3(ctx, label, shown, (flags or (ImGui.ColorEditFlags_NoInputs | ImGui.ColorEditFlags_PickerHueWheel)) | ImGui.ColorEditFlags_InputHSV)
  if ch then held[label] = v end
  local done = ImGui.IsItemDeactivatedAfterEdit(ctx)
  if done or (held[label] and not ImGui.IsItemActive(ctx)) then
    local x = held[label]
    held[label] = nil
    if x then
      local rgb = colours.rgb_of_hsv(x)
      last[label] = { rgb = rgb, hsv = x }
      commit(rgb)
    end
  end
  return ch, done
end

local function hash01(s)
  local h = 2166136261
  for i = 1, #s do h = ((h ~ s:byte(i)) * 16777619) & 0xFFFFFFFF end
  return h / 0xFFFFFFFF
end

-- The colour of each track. tracks: { { name, family (its top-level folder's number), maker (a colour, or nil), newest ("" if unknown) } }.
-- opt: { stops, folders (colours set by folder name) }. Pure.
function colours.plan(tracks, scheme, opt)
  local stops, n, out = opt.stops, #tracks, {}
  local families, members = 0, {}
  for _, t in ipairs(tracks) do
    families = math.max(families, t.family or 0)
    members[t.family or 0] = (members[t.family or 0] or 0) + 1
  end
  local rank = {}
  if scheme == "newest" then
    local order = {}
    for i, t in ipairs(tracks) do order[i] = i end
    table.sort(order, function(a, z)
      if (tracks[a].newest or "") ~= (tracks[z].newest or "") then return (tracks[a].newest or "") < (tracks[z].newest or "") end
      return a < z
    end)
    for r, i in ipairs(order) do rank[i] = r end
  end
  local seen, bases = {}, scheme == "folders" and colours.folder_bases(tracks, stops, opt.folders) or nil
  for i, t in ipairs(tracks) do
    local f, at = t.family or 0, i == 1 and 0 or (i - 1) / math.max(1, n - 1)
    seen[f] = (seen[f] or 0) + 1
    if scheme == "gradient" then out[i] = colours.ramp(stops, at)
    elseif scheme == "folders" then
      local base = bases[f]
      out[i] = colours.mix(base, 0xFFFFFF, (members[f] or 1) > 1 and 0.45 * (seen[f] - 1) / (members[f] - 1) or 0)
    elseif scheme == "instrument" then out[i] = colours.kind_of(t.name)
    elseif scheme == "person" then out[i] = t.maker or colours.OTHER
    elseif scheme == "stripes" then out[i] = f % 2 == 1 and stops[1] or stops[#stops]
    elseif scheme == "rainbow" then out[i] = colours.hsv(at * 0.85, 0.72, 0.95)
    elseif scheme == "newest" then out[i] = colours.ramp(stops, n > 1 and (rank[i] - 1) / (n - 1) or 1)
    elseif scheme == "confetti" then out[i] = colours.hsv(hash01((t.name or "") .. "!"), 0.65 + hash01(t.name or "") * 0.2, 0.95)
    else out[i] = colours.OTHER end
  end
  return out
end

-- The common sections keep a colour of their own in every song, whatever the palette: you learn them.
local SECTIONS = { intro = 0x7E8798, verse = 0x4C9BE8, pre = 0x36C4B4, prechorus = 0x36C4B4, chorus = 0xF2A33A, hook = 0xF2A33A, bridge = 0x9A6BE8, solo = 0xF06BAF,
  ["break"] = 0x57B85A, breakdown = 0x57B85A, drop = 0xE5584F, outro = 0x7E8798, ending = 0x7E8798, tag = 0xC9A15A, interlude = 0x57B85A }
function colours.section_key(name)
  return (name or ""):lower():gsub("[^%a]", " "):gsub("^%s*pre%s+chorus", "prechorus"):match("%a+") or ""
end
-- The common sections, for setting their colours.
colours.SECTION_NAMES = { { "intro", "Intro" }, { "verse", "Verse" }, { "prechorus", "Pre-chorus" }, { "chorus", "Chorus" }, { "bridge", "Bridge" },
  { "solo", "Solo" }, { "break", "Break" }, { "drop", "Drop" }, { "outro", "Outro" } }
-- A section's colour: its own if one's set, else the common sections' (the same in every song), else spread along the palette (`other`:
-- { n = 0, map = {} }, shared across one plan so a name keeps its colour). Pure.
function colours.section_colour(key, stops, named, other)
  if named and named[key] then return named[key] end
  if SECTIONS[key] then return SECTIONS[key] end
  if key == "" then return colours.OTHER end
  if not other.map[key] then other.n = other.n + 1; other.map[key] = colours.ramp(stops, (other.n * 0.381966) % 1) end -- (spread out however many there turn out to be)
  return other.map[key]
end
-- The colour of each region or marker. marks: { { name, region } }. mode: "sections" (the same section, the same colour) or "song"
-- (chronologically). named: colours set by section. Pure.
function colours.plan_marks(marks, mode, stops, named)
  local out, regions, other = {}, 0, { n = 0, map = {} }
  -- (chronologically: by where each starts, not the order they're listed in; a marker the colour of the next region to start)
  local order, place = {}, {}
  for i, m in ipairs(marks) do order[i] = i end
  table.sort(order, function(a, z)
    local pa, pz = marks[a].pos or a, marks[z].pos or z
    if pa ~= pz then return pa < pz end
    return a < z
  end)
  local at = 0
  for _, i in ipairs(order) do place[i] = at; if marks[i].region then at = at + 1 end end
  regions = at
  for i, m in ipairs(marks) do
    if mode == "song" then
      out[i] = colours.ramp(stops, regions > 1 and math.min(place[i], regions - 1) / (regions - 1) or 0)
    else out[i] = colours.section_colour(colours.section_key(m.name), stops, named, other) end
  end
  return out
end

local function native(rgb) return reaper.ColorToNative(rgb >> 16, (rgb >> 8) & 255, rgb & 255) | 0x1000000 end

-- What the plan needs to know of this project's tracks: the same order as CountTracks, the helpers left out.
function colours.read(proj, cfg)
  local mirror, people = require("mirror"), require("people")
  local by_tag = {}
  for u, c in pairs(people.colours(cfg.root, { cfg.user })) do by_tag[mirror.user_tag(u)] = c end
  local list, depth, family, folder, top = {}, 0, 0, nil, false
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    if depth == 0 then -- (a new family: a top-level folder, or a track on its own; the folder's name goes with each of its tracks)
      family = family + 1
      top = reaper.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH") >= 1
      folder = require("sync").base_name(select(2, reaper.GetTrackName(tr)))
    end
    if not mirror.local_track(tr) then
      local oid = mirror.track_oid(tr)
      local newest = ""
      local function look(o)
        local _, _, ev = mirror.known(proj, o)
        local stamp = (ev or ""):match("%d%d%d%d%d%d%d%d%-%d%d%d%d%d%dZ")
        if stamp and stamp > newest then newest = stamp end
      end
      look(oid)
      for k = 0, reaper.CountTrackMediaItems(tr) - 1 do look(mirror.item_oid(reaper.GetTrackMediaItem(tr, k))) end
      list[#list + 1] = { ptr = tr, name = require("sync").base_name(select(2, reaper.GetTrackName(tr))), family = family, folder = folder, in_folder = top or nil, maker = by_tag[mirror.creator(oid)], newest = newest }
    end
    depth = depth + math.floor(reaper.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH"))
    if depth < 0 then depth = 0 end
  end
  return list
end

-- Colours what this person may change. -> how many coloured, how many left because they're someone else's.
function colours.apply(proj, cfg, list, plan, may, only_selected)
  local done, left = 0, 0
  reaper.Undo_BeginBlock2(proj) -- (not named after StudioSync: Ctrl+Z is REAPER's own undo, and takes all of it back)
  for i, t in ipairs(list) do
    if not only_selected or reaper.IsTrackSelected(t.ptr) then
      if may(t.name, t.ptr) then band.set_track_colour(t.ptr, native(plan[i])); done = done + 1 else left = left + 1 end
    end
  end
  reaper.Undo_EndBlock2(proj, "Colour tracks", 1)
  reaper.TrackList_AdjustWindows(false)
  return done, left
end

-- The project's regions and markers (not this computer's own).
function colours.read_marks(proj)
  local idx = {}
  for i = 0, reaper.CountProjectMarkers(proj) - 1 do
    local _, region, pos, rend, name, num = reaper.EnumProjectMarkers3(proj, i)
    if not band.is_local_mark(name) then idx[#idx + 1] = { i = i, region = region, pos = pos, rend = rend, name = name, num = num } end
  end
  return idx
end
function colours.apply_marks(proj, mode, stops, named)
  local idx = colours.read_marks(proj)
  local plan = colours.plan_marks(idx, mode, stops, named or colours.named("sections"))
  reaper.Undo_BeginBlock2(proj)
  for k, m in ipairs(idx) do reaper.SetProjectMarkerByIndex2(proj, m.i, m.region, m.pos, m.rend, m.num, m.name, native(plan[k]), 0) end
  reaper.Undo_EndBlock2(proj, "Colour regions", 8)
  reaper.UpdateTimeline()
  return #idx
end

colours.ITEM_SCHEMES = {
  { "section", "By section", "Everything in a verse one colour, everything in a chorus another, from the region it starts in: the same colours as regions by section." },
  { "song", "Chronologically", "Start of the song to the end, from the palette's first colour to its last." },
  { "person", "By who recorded it", "Each item in the colour of the person who made it." },
  { "lane", "By lane", "Each fixed lane its own colour: comps and alternatives stand apart." },
  { "take", "By takes", "One-take items the palette's first colour, the more takes the further along it: where there's a choice still to make." },
  { "kind", "By kind", "MIDI parts, printed parts and recordings each their own colour (from the palette, or set below): what's audio and what's notes, at a glance." },
  { "newest", "Newest work", "Where the song's been moving lately: the palette's first colour for what's untouched longest, its last for the latest changed." },
  { "clear", "As its track", "Takes item colours off, so items follow their track again." },
}
-- The colour of each item (false: none). items: { { pos, section (a name, or nil), maker (a colour, or nil), lane, takes, kind } }.
-- opt: { stops, last (the song's end), sections (colours set by section), kinds (by kind: midi, print, audio) }. Pure.
function colours.plan_items(items, scheme, opt)
  local out, stops = {}, opt.stops
  local n, rank, other, kc = 0, {}, { n = 0, map = {} }, opt.kinds or {}
  if scheme == "newest" then
    local order = {}
    for i in ipairs(items) do order[i] = i end
    table.sort(order, function(a, z)
      if (items[a].newest or "") ~= (items[z].newest or "") then return (items[a].newest or "") < (items[z].newest or "") end
      return a < z
    end)
    for r, i in ipairs(order) do rank[i] = r end
    n = #items
  end
  for i, it in ipairs(items) do
    if scheme == "section" then
      out[i] = it.section and colours.section_colour(colours.section_key(it.section), stops, opt.sections, other) or colours.OTHER
    elseif scheme == "song" then out[i] = colours.ramp(stops, (opt.last or 0) > 0 and it.pos / opt.last or 0)
    elseif scheme == "person" then out[i] = it.maker or colours.OTHER
    elseif scheme == "lane" then out[i] = colours.ramp(stops, ((it.lane or 0) % 5) / 4)
    elseif scheme == "take" then out[i] = colours.ramp(stops, math.min((it.takes or 1) - 1, 4) / 4)
    elseif scheme == "kind" then out[i] = it.kind == "midi" and (kc.midi or stops[1]) or it.kind == "print" and (kc.print or colours.ramp(stops, 0.5))
      or it.kind == "audio" and (kc.audio or stops[#stops]) or colours.OTHER
    elseif scheme == "newest" then out[i] = colours.ramp(stops, n > 1 and (rank[i] - 1) / (n - 1) or 1)
    else out[i] = false end
  end
  return out
end

-- The project's items as plan_items needs them, on tracks `may(name, track)` allows (nil: every one). -> the list, how many left out, the song's end.
function colours.read_items(proj, cfg, may)
  local mirror, people = require("mirror"), require("people")
  local marks = {}
  for i = 0, reaper.CountProjectMarkers(proj) - 1 do
    local _, region, pos, rend, name = reaper.EnumProjectMarkers3(proj, i)
    if region and not band.is_local_mark(name) then marks[#marks + 1] = { pos = pos, rend = rend, name = name } end
  end
  local who, by_tag, last = people.colours(cfg.root, { cfg.user }), {}, 0
  for u, c in pairs(who) do by_tag[mirror.user_tag(u)] = c end
  local list, left = {}, 0
  for t = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, t)
    if not mirror.local_track(tr) then
      local name = require("sync").base_name(select(2, reaper.GetTrackName(tr)))
      for k = 0, reaper.CountTrackMediaItems(tr) - 1 do
        local it = reaper.GetTrackMediaItem(tr, k)
        if not may or may(name, tr) then
          local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
          last = math.max(last, pos)
          local section
          for _, m in ipairs(marks) do if pos >= m.pos - 0.001 and pos < m.rend then section = m.name end end
          local tk = reaper.GetActiveTake(it)
          local kind = tk and (select(2, reaper.GetSetMediaItemTakeInfo_String(tk, "P_EXT:band_m_print", "", false)) ~= "" and "print"
            or reaper.TakeIsMIDI(tk) and "midi" or "audio") or nil
          local _, _, evid = mirror.known(proj, mirror.item_oid(it))
          list[#list + 1] = { ptr = it, pos = pos, len = reaper.GetMediaItemInfo_Value(it, "D_LENGTH"), track = name, section = section, maker = by_tag[mirror.creator(mirror.item_oid(it))], kind = kind,
            newest = (evid or ""):match("%d%d%d%d%d%d%d%d%-%d%d%d%d%d%dZ") or "",
            lane = math.floor(reaper.GetMediaItemInfo_Value(it, "I_FIXEDLANE")), takes = mirror.filled_takes(it) } -- (a print isn't a take still to choose)
        else left = left + 1 end
      end
    end
  end
  return list, left, last
end
function colours.item_kinds() local k = colours.named("itemkinds"); return { midi = k.midi, print = k.print, audio = k.audio } end
-- Every item on tracks this person may change gets its colour. -> how many, how many left. They go out like any change, a burst at a time.
function colours.apply_items(proj, cfg, scheme, stops, may)
  local list, left, last = colours.read_items(proj, cfg, may)
  local plan = colours.plan_items(list, scheme, { stops = stops, last = last, sections = colours.named("sections"), kinds = colours.item_kinds() })
  reaper.Undo_BeginBlock2(proj)
  for i, x in ipairs(list) do reaper.SetMediaItemInfo_Value(x.ptr, "I_CUSTOMCOLOR", plan[i] and native(plan[i]) or 0) end
  reaper.Undo_EndBlock2(proj, "Colour items", 4)
  reaper.UpdateArrange()
  return #list, left
end

-- The Settings card. (In this file: the panel is near Lua's 200-locals limit.) may(name, track): this person may change that track. timeline_ok: the driver, or anyone in Anyone.
local cache = { at = -math.huge }
-- ---- the project's look and the studio's (0.58.98, James: "Studio colors should auto color new projects unless colors are already applied to
-- that project. Then project specific colors will override that if changed."): a look is { scheme, palette, from, to }. The project's own
-- (ProjExtState "colours"), else the studio's (band.json, lib/groups.lua), else this computer's last pick.
function colours.look_of(proj, root)
  local own = band.json_decode(select(2, reaper.GetProjExtState(proj, band.SECTION, "colours")))
  if type(own) == "table" and type(own.scheme) == "string" then return own, "project" end
  local studio = root and require("groups").colours(root)
  if studio then return studio, "studio" end
  local last = band.ext_json(band.SECTION, "colour look")
  if type(last) == "table" and type(last.scheme) == "string" then return last, "computer" end
  local function saved(key, default) local v = reaper.GetExtState(band.SECTION, key); return v ~= "" and v or default end
  return { scheme = saved("colour scheme", "gradient"), palette = saved("colour palette", "Sunset"), from = saved("colour from", "2F7BFF"), to = saved("colour to", "FF8A3D") }, "computer"
end
-- Tracks, items and regions each have their own way and palette (James, 0.59.4: "gradient on the tracks and then color items based on what's new
-- with a different gradient and regions with another"). Tracks: the look itself, as before; items and regions: look.items / look.regions,
-- each { scheme, palette, from, to }, missing in a look from before (then their old defaults, in the tracks' palette). Pure.
colours.REGION_SCHEMES = {
  { "sections", "By section", "Every verse one colour, every chorus another: the common sections keep their own colours in every song, the rest from the palette." },
  { "song", "Chronologically", "Start of the song to the end, from the palette's first colour to its last." },
}
local ROW_DEFAULT = { items = "section", regions = "sections" }
function colours.part(look, row)
  look = type(look) == "table" and look or {}
  local p = row == "tracks" and look or (type(look[row]) == "table" and look[row] or {})
  local function str(v, d) return type(v) == "string" and v ~= "" and v or d end
  return { scheme = str(p.scheme, row == "tracks" and "gradient" or ROW_DEFAULT[row]), palette = str(p.palette, str(look.palette, "Sunset")),
    from = str(p.from, str(look.from, "2F7BFF")), to = str(p.to, str(look.to, "FF8A3D")) }
end
function colours.stops_of(look)
  for _, p in ipairs(colours.PALETTES) do if p[1] == look.palette then return p[2] end end
  return { tonumber(look.from or "", 16) or 0x2F7BFF, tonumber(look.to or "", 16) or 0xFF8A3D }
end
-- A new project in the studio's look (Live sync, every few seconds, on the driver's computer only: one computer colours, the rest receive
-- it). Once: a project whose tracks already have colours keeps them ("had"); one coloured here ("auto") has its new tracks coloured too, as
-- they come, left as they are once they have a colour. may(name, track): this person may change it.
function colours.auto(proj, cfg, may)
  local state = select(2, reaper.GetProjExtState(proj, band.SECTION, "colours auto"))
  if state == "had" then return end
  local look, from = colours.look_of(proj, cfg.root)
  if from == "computer" then return end -- (nobody picked a look for the studio or the project: nothing automatic)
  local list = colours.read(proj, cfg)
  if #list == 0 then return end
  -- (the band's colour, not a "who's working" one painted over it here: band.track_colour. A track coloured once and reset by someone stays
  -- reset: P_EXT:band_autocol. Review, 0.58.98)
  local todo = {}
  local uncoloured = 0
  for i, t in ipairs(list) do
    if band.track_colour(t.ptr) == 0 then
      uncoloured = uncoloured + 1
      if band.track_ext(t.ptr, "band_autocol") == "" and may(t.name, t.ptr) then todo[#todo + 1] = i end
    end
  end
  if state == "" and uncoloured < #list then reaper.SetProjExtState(proj, band.SECTION, "colours auto", "had"); return end
  if #todo == 0 then return end
  local plan = colours.plan(list, look.scheme, { stops = colours.stops_of(look), folders = colours.named("folders") })
  reaper.Undo_BeginBlock2(proj)
  local done = 0
  for _, i in ipairs(todo) do
    band.set_track_colour(list[i].ptr, native(plan[i]))
    reaper.GetSetMediaTrackInfo_String(list[i].ptr, "P_EXT:band_autocol", "1", true)
    done = done + 1
  end
  reaper.Undo_EndBlock2(proj, "Colour tracks", 1)
  if state == "" then reaper.SetProjExtState(proj, band.SECTION, "colours auto", "auto") end
  if done > 0 then reaper.TrackList_AdjustWindows(false); band.log(string.format("coloured %d new track%s in the %s look", done, done == 1 and "" or "s", from == "studio" and "studio's" or "project's")) end
end

-- ---- trying a look here first (0.58.98, James: "an easy way to test/audition a look before applying it to everyone"): sending is held
-- (Hold sync, lib/sync.lua) while it's tried, and what was there is kept, so Put back puts exactly that back, and Keep lets it go to everyone.
-- (one per project tab: a second tab's try replaced the first's, which was left held with no Put back. Review, 0.58.98)
local tries = {} -- proj -> { proj, held_before, tracks = { ptr -> colour }, items = { ptr -> colour }, marks = { {num, region, colour} } }
local trying
local function snapshot(proj)
  local t = { proj = proj, held_before = select(2, reaper.GetProjExtState(proj, band.SECTION, "hold")), tracks = {}, items = {}, marks = {} }
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    t.tracks[tr] = band.track_colour(tr) -- (the band's colour: a "who's working" paint over it isn't it. Review, 0.58.98)
    for k = 0, reaper.CountTrackMediaItems(tr) - 1 do local it = reaper.GetTrackMediaItem(tr, k); t.items[it] = reaper.GetMediaItemInfo_Value(it, "I_CUSTOMCOLOR") end
  end
  for i = 0, reaper.CountProjectMarkers(proj) - 1 do
    local _, region, _, _, _, num, colour = reaper.EnumProjectMarkers3(proj, i)
    t.marks[#t.marks + 1] = { region = region, num = num, colour = colour }
  end
  return t
end
local function try_first(proj, fn)
  if not tries[proj] then
    tries[proj] = snapshot(proj)
    reaper.SetProjExtState(proj, band.SECTION, "hold", "1") -- (nothing goes out while it's tried)
  end
  fn()
end
function colours.trying(proj) return tries[proj] ~= nil end
function colours.keep(proj)
  trying = tries[proj]
  if not trying then return end
  if reaper.ValidatePtr2(0, proj, "ReaProject*") then reaper.SetProjExtState(proj, band.SECTION, "hold", trying.held_before or "") end
  band.log((trying.held_before or "") ~= "" and "kept the new look (Hold sync was already on: it goes out when you release it)" or "kept the new look: it goes to everyone now")
  tries[proj] = nil
end
function colours.put_back(proj)
  trying = tries[proj]
  if not trying then return end
  tries[proj] = nil
  if not reaper.ValidatePtr2(0, proj, "ReaProject*") then return end
  reaper.Undo_BeginBlock2(proj)
  for tr, c in pairs(trying.tracks) do if reaper.ValidatePtr2(proj, tr, "MediaTrack*") then band.set_track_colour(tr, c) end end
  for it, c in pairs(trying.items) do if reaper.ValidatePtr2(proj, it, "MediaItem*") then reaper.SetMediaItemInfo_Value(it, "I_CUSTOMCOLOR", c) end end
  -- (each marker's colour only, found by its number: one added or removed meanwhile moved the indices, and old positions and names went
  -- onto the wrong markers. Review, 0.58.98)
  local was = {}
  for _, m in ipairs(trying.marks) do was[(m.region and "r" or "m") .. m.num] = m.colour end
  for i = 0, reaper.CountProjectMarkers(proj) - 1 do
    local _, region, pos, rend, name, num, colour = reaper.EnumProjectMarkers3(proj, i)
    local c = was[(region and "r" or "m") .. num]
    if c and c ~= colour then reaper.SetProjectMarkerByIndex2(proj, i, region, pos, rend, num, name, c, 0) end
  end
  reaper.Undo_EndBlock2(proj, "Colours put back", -1)
  reaper.SetProjExtState(proj, band.SECTION, "hold", trying.held_before or "")
  reaper.TrackList_AdjustWindows(false); reaper.UpdateArrange(); reaper.UpdateTimeline()
  band.log("the look you tried is put back: nothing went to the others")
end
-- Before the panel reloads or closes: a look being tried is put back (the trial lived in the panel's Lua, and Hold stayed on with no
-- Put back after a reload. Review, 0.58.98)
function colours.put_back_all() for p in pairs(tries) do colours.put_back(p) end end

-- A small bar of the palette, words at each end: which end is which (James, 0.59.4: "the descriptions adapted for most recent vs oldest").
local function legend(ctx, ImGui, stops, left, right)
  ImGui.TextDisabled(ctx, left); ImGui.SameLine(ctx, 0, 6)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local dl, w, h = ImGui.GetWindowDrawList(ctx), 90, ImGui.GetTextLineHeight(ctx)
  for i = 0, 29 do ImGui.DrawList_AddRectFilled(dl, x + i * w / 30, y + 2, x + (i + 1) * w / 30, y + h - 2, (colours.ramp(stops, i / 29) << 8) | 0xFF) end
  ImGui.Dummy(ctx, w, h); ImGui.SameLine(ctx, 0, 6)
  if ImGui.GetContentRegionAvail(ctx) < ImGui.CalcTextSize(ctx, right) then ImGui.NewLine(ctx) end -- (cut mid-word: review, 0.59.14)
  ImGui.TextDisabled(ctx, right)
end
-- The long bar: what each would look like, with what each piece is on hover (James, 0.59.4: "the long one with details for each").
-- segs: { { from 0-1, to 0-1, rgb, words } }.
local function preview(ctx, ImGui, segs, none)
  if #segs == 0 then return ImGui.TextDisabled(ctx, none) end
  local w = ImGui.GetContentRegionAvail(ctx)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + 12, 0x80808030, 2)
  for _, sg in ipairs(segs) do ImGui.DrawList_AddRectFilled(dl, x + sg[1] * w, y, math.max(x + sg[1] * w + 1, x + sg[2] * w - 1), y + 12, (sg[3] << 8) | 0xFF, 2) end
  ImGui.InvisibleButton(ctx, "##preview", math.max(1, w), 12)
  if ImGui.IsItemHovered(ctx) then
    local mx, best = (select(1, ImGui.GetMousePos(ctx)) - x) / math.max(1, w), nil
    for _, sg in ipairs(segs) do if mx >= sg[1] and mx <= sg[2] then best = sg end end
    if best then ImGui.SetTooltip(ctx, best[4]) end
  end
end
-- Colours set by name, for one kind: entries { { key, label, colour now } }.
local function name_editors(ctx, ImGui, kind, entries, words)
  for i, e in ipairs(entries) do
    colours.edit3(ctx, ImGui, e[2] .. "##" .. kind .. e[1], e[3], function(v) colours.set_named(kind, e[1], v); cache.at = -math.huge end)
    if i % 2 == 1 and i < #entries then ImGui.SameLine(ctx, 180) end
  end
  if next(colours.named(kind)) and ImGui.SmallButton(ctx, words .. " as they were##" .. kind) then colours.forget_named(kind); cache.at = -math.huge end
  ImGui.SetItemTooltip(ctx, "Only on this computer, until you colour them; then everyone sees what you coloured.")
end
local function bar_at(pos) return (reaper.format_timestr_pos(pos, "", 2):match("^(%d+)")) or "?" end
-- What the three bars show, read every few seconds (reading every item is too much for every frame).
local function refresh(proj, cfg, parts, stops_of_row)
  if reaper.time_precise() - cache.at <= 3 and cache.proj == proj then return end
  cache.at, cache.proj = reaper.time_precise(), proj
  cache.list = colours.read(proj, cfg)
  local t = parts.tracks
  cache.plan = colours.plan(cache.list, t.scheme, { stops = stops_of_row.tracks, folders = colours.named("folders") })
  cache.tsegs = {}
  for i, x in ipairs(cache.list) do cache.tsegs[i] = { (i - 1) / #cache.list, i / #cache.list, cache.plan[i], x.name } end
  -- items where they are in the song, across its length (James, 0.59.6: "show by each time segment, based on project length"; one after
  -- another, items at the same time on several tracks looked out of order)
  local items, _, last = colours.read_items(proj, cfg, nil)
  local ip = colours.plan_items(items, parts.items.scheme, { stops = stops_of_row.items, last = last, sections = colours.named("sections"), kinds = colours.item_kinds() })
  local iend = 0
  for _, x in ipairs(items) do iend = math.max(iend, x.pos + (x.len or 0)) end
  cache.isegs = {}
  for i, x in ipairs(items) do
    if iend > 0 then
      cache.isegs[#cache.isegs + 1] = { x.pos / iend, (x.pos + (x.len or 0)) / iend, ip[i] or 0x5A5F6A, string.format("%s, bar %s%s", x.track, bar_at(x.pos), ip[i] and "" or " (as its track)") }
    end
  end
  local marks = colours.read_marks(proj)
  local mp = colours.plan_marks(marks, parts.regions.scheme, stops_of_row.regions, colours.named("sections"))
  local endt = 0
  for _, m in ipairs(marks) do endt = math.max(endt, m.region and m.rend or m.pos) end
  cache.msegs, cache.keys = {}, {}
  for i, m in ipairs(marks) do
    local a = endt > 0 and m.pos / endt or 0
    cache.msegs[#cache.msegs + 1] = { a, m.region and endt > 0 and m.rend / endt or a + 0.004, mp[i], (m.name ~= "" and m.name or "(no name)") .. ", bar " .. bar_at(m.pos) }
    local k = colours.section_key(m.name)
    if m.region and k ~= "" then cache.keys[k] = cache.keys[k] or m.name end
  end
end
local LEGENDS = { -- row.scheme -> the words at either end of the palette
  ["tracks.gradient"] = { "top", "bottom" }, ["tracks.newest"] = { "untouched longest", "changed most recently" },
  ["items.song"] = { "start", "end" }, ["items.newest"] = { "untouched longest", "changed most recently" }, ["items.take"] = { "one take", "five or more" },
  ["items.lane"] = { "lane 1", "lane 5" }, ["regions.song"] = { "start", "end" },
}
local USES_PALETTE = { tracks = { gradient = true, folders = true, stripes = true, newest = true },
  items = { section = true, song = true, lane = true, take = true, kind = true, newest = true }, regions = { sections = true, song = true } }
local ROWS = { { "tracks", "Tracks:", colours.SCHEMES }, { "items", "Items:", colours.ITEM_SCHEMES }, { "regions", "Regions:", colours.REGION_SCHEMES } }
function colours.draw(ctx, ImGui, proj, cfg, may, timeline_ok)
  ImGui.SeparatorText(ctx, "Colour the project")
  local look, from = colours.look_of(proj, cfg.root)
  local parts = { tracks = colours.part(look, "tracks"), items = colours.part(look, "items"), regions = colours.part(look, "regions") }
  local function whole() local t = parts.tracks; return { scheme = t.scheme, palette = t.palette, from = t.from, to = t.to, items = parts.items, regions = parts.regions } end
  -- (a change of look is this project's own from now: the studio's stays the default for new ones; and this computer's last pick)
  local function set(row, field, value)
    parts[row][field] = value
    local t = band.json_encode(whole())
    reaper.SetProjExtState(proj, band.SECTION, "colours", t)
    reaper.SetExtState(band.SECTION, "colour look", t, true)
    cache.at = -math.huge
  end
  local function beside(label) -- (on the row while it fits, else the next line: a narrow column cut them off)
    ImGui.SameLine(ctx)
    if ImGui.GetContentRegionAvail(ctx) < ImGui.CalcTextSize(ctx, label) + 2 * ImGui.GetStyleVar(ctx, ImGui.StyleVar_FramePadding) + 4 then ImGui.NewLine(ctx) end
  end
  ImGui.PushTextWrapPos(ctx, 0)
  ImGui.TextDisabled(ctx, "Tracks, items and regions each their own way and colours. Try it here, then keep it for everyone. " .. (from == "project" and "This project has a look of its own." or
    from == "studio" and "This project uses the studio's look." or "No look picked for the studio yet: new projects keep their own colours."))
  ImGui.PopTextWrapPos(ctx)
  if colours.trying(proj) then
    ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, 0x2E4D7FFF)
    if ImGui.BeginChild(ctx, "##colourtry", 0, 0, ImGui.ChildFlags_AutoResizeY | ImGui.ChildFlags_AlwaysUseWindowPadding) then
      ImGui.TextWrapped(ctx, "Trying a look on this computer only: nothing has gone to the others yet (sending is held).")
      if ImGui.Button(ctx, "Keep it for everyone##colourkeep") then colours.keep(proj) end
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, "Put it back##colourback") then colours.put_back(proj) end
      ImGui.EndChild(ctx)
    end
    ImGui.PopStyleColor(ctx)
  end
  local first = reaper.GetExtState(band.SECTION, "colour try") ~= "off"
  local function go(fn) if first then try_first(proj, fn) else fn() end end
  local stops_of_row = { tracks = colours.stops_of(parts.tracks), items = colours.stops_of(parts.items), regions = colours.stops_of(parts.regions) }
  for _, r in ipairs(ROWS) do
    local row, words, schemes = r[1], r[2], r[3]
    local p = parts[row]
    local stops = stops_of_row[row]
    ImGui.PushID(ctx, row)
    ImGui.Spacing(ctx)
    ImGui.AlignTextToFramePadding(ctx); ImGui.Text(ctx, words); ImGui.SameLine(ctx, 70)
    local label, tip = p.scheme, ""
    for _, sc in ipairs(schemes) do if sc[1] == p.scheme then label, tip = sc[2], sc[3] end end
    ImGui.SetNextItemWidth(ctx, 150)
    if ImGui.BeginCombo(ctx, "##scheme", label) then
      for _, sc in ipairs(schemes) do
        if ImGui.Selectable(ctx, sc[2], sc[1] == p.scheme) then set(row, "scheme", sc[1]) end
        ImGui.SetItemTooltip(ctx, sc[3])
      end
      ImGui.EndCombo(ctx)
    end
    if USES_PALETTE[row][p.scheme] then
      ImGui.SameLine(ctx)
      if ImGui.GetContentRegionAvail(ctx) < 110 then ImGui.NewLine(ctx) end -- (cut off in a narrow column: layout review, 0.59.14)
      ImGui.SetNextItemWidth(ctx, 110)
      if ImGui.BeginCombo(ctx, "##palette", p.palette) then
        for _, pal in ipairs(colours.PALETTES) do
          if ImGui.Selectable(ctx, pal[1], pal[1] == p.palette) then set(row, "palette", pal[1]) end
        end
        if ImGui.Selectable(ctx, "Your own", p.palette == "Your own") then set(row, "palette", "Your own") end
        ImGui.EndCombo(ctx)
      end
      ImGui.SetItemTooltip(ctx, "The colours " .. words:sub(1, -2):lower() .. " run through. Only " .. words:sub(1, -2):lower() .. ".")
      if p.palette == "Your own" then
        local a, z = tonumber(p.from, 16) or 0x2F7BFF, tonumber(p.to, 16) or 0xFF8A3D
        ImGui.SameLine(ctx)
        if ImGui.GetContentRegionAvail(ctx) < 2 * ImGui.GetFrameHeight(ctx) + 12 then ImGui.NewLine(ctx) end
        colours.edit3(ctx, ImGui, "##from" .. tostring(row), a, function(v) set(row, "from", string.format("%06X", v)) end)
        ImGui.SetItemTooltip(ctx, "The first colour")
        ImGui.SameLine(ctx)
        colours.edit3(ctx, ImGui, "##to" .. tostring(row), z, function(v) set(row, "to", string.format("%06X", v)) end)
        ImGui.SetItemTooltip(ctx, "The last colour")
      end
    end
    -- its button(s), on the row
    if row == "tracks" then
      beside("Colour all tracks")
      if ImGui.Button(ctx, "Colour all tracks") then go(function() colours.run(proj, cfg, may, false) end) end
      ImGui.SetItemTooltip(ctx, "Every track you may change, this way. Someone else's stays as it is.")
      beside("Selected only")
      if ImGui.Button(ctx, "Selected only") then go(function() colours.run(proj, cfg, may, true) end) end
      ImGui.SetItemTooltip(ctx, "Only the tracks selected in REAPER.")
    elseif row == "items" then
      beside("Colour items")
      if ImGui.Button(ctx, "Colour items") then
        go(function()
          local n, left = colours.apply_items(proj, cfg, p.scheme, stops, may)
          band.log(string.format("coloured %d item%s%s", n, n == 1 and "" or "s", left > 0 and string.format(": %d of someone else's left as they are", left) or ""))
        end)
      end
      ImGui.SetItemTooltip(ctx, "Items on the tracks you may change, " .. label:lower() .. ".")
    else
      beside("Colour regions")
      ImGui.BeginDisabled(ctx, not timeline_ok)
      if ImGui.Button(ctx, "Colour regions") then
        go(function() band.log(string.format("coloured %d regions and markers, %s", colours.apply_marks(proj, p.scheme, stops, colours.named("sections")), label:lower())) end)
      end
      ImGui.EndDisabled(ctx)
      ImGui.SetItemTooltip(ctx, timeline_ok and "Every region and marker, " .. label:lower() .. "." or "The timeline is the driver's: they do this.")
    end
    -- what it does, and which colour means what
    ImGui.Indent(ctx, 70)
    ImGui.PushTextWrapPos(ctx, 0)
    ImGui.TextDisabled(ctx, tip)
    ImGui.PopTextWrapPos(ctx)
    local ends = LEGENDS[row .. "." .. p.scheme]
    if ends then legend(ctx, ImGui, stops, ends[1], ends[2]) end
    -- colours of your own, by name (instruments, folders, sections, kinds)
    if row == "tracks" and p.scheme == "instrument" then
      local kc, entries = colours.kind_colours(), {}
      for i, name in ipairs(colours.KIND_NAMES) do entries[i] = { i, name, kc[i] } end
      for i, e in ipairs(entries) do
        colours.edit3(ctx, ImGui, e[2] .. "##kind" .. i, e[3], function(v) colours.set_kind_colour(i, v); cache.at = -math.huge end)
        if i % 2 == 1 and i < #entries then ImGui.SameLine(ctx, 180) end
      end
      if ImGui.SmallButton(ctx, "Instrument colours as they were##kinds") then reaper.DeleteExtState(band.SECTION, "colour kinds", true); kind_cache = nil; cache.at = -math.huge end
      ImGui.SetItemTooltip(ctx, "Each instrument's colour, found from the track's name (drums, bass, guitars...). Only on this computer, until you colour the tracks.")
    elseif row == "tracks" and p.scheme == "folders" then
      local bases, entries, seen = colours.folder_bases(cache.list or {}, stops, colours.named("folders")), {}, {}
      for _, t in ipairs(cache.list or {}) do
        if t.in_folder and not seen[t.family] then seen[t.family] = true; entries[#entries + 1] = { t.folder:lower(), t.folder, bases[t.family] } end
      end
      if #entries == 0 then ImGui.TextDisabled(ctx, "No folders in this project.") else name_editors(ctx, ImGui, "folders", entries, "Folder colours") end
    elseif (row == "regions" and p.scheme == "sections") or (row == "items" and p.scheme == "section") then
      local named, other, entries, have = colours.named("sections"), { n = 0, map = {} }, {}, {}
      for _, sn in ipairs(colours.SECTION_NAMES) do entries[#entries + 1] = { sn[1], sn[2] }; have[sn[1]] = true end
      local extra = {}
      for k, name in pairs(cache.keys or {}) do if not have[k] then extra[#extra + 1] = { k, name } end end
      table.sort(extra, function(x1, x2) return x1[1] < x2[1] end)
      for _, e in ipairs(extra) do entries[#entries + 1] = e end
      for _, e in ipairs(entries) do e[3] = colours.section_colour(e[1], stops, named, other) end
      if ImGui.TreeNode(ctx, "Section colours (" .. (row == "items" and "shared with regions" or "shared with items") .. ")##secnames") then
        name_editors(ctx, ImGui, "sections", entries, "Section colours")
        ImGui.TreePop(ctx)
      end
    elseif row == "items" and p.scheme == "kind" then
      local kc = colours.item_kinds()
      name_editors(ctx, ImGui, "itemkinds", { { "midi", "MIDI", kc.midi or stops[1] }, { "print", "Printed", kc.print or colours.ramp(stops, 0.5) },
        { "audio", "Recordings", kc.audio or stops[#stops] } }, "Kind colours")
    end
    ImGui.Unindent(ctx, 70)
    refresh(proj, cfg, parts, stops_of_row)
    if row == "tracks" then preview(ctx, ImGui, cache.tsegs, "No tracks yet.")
    elseif row == "items" then preview(ctx, ImGui, cache.isegs, "No items yet.")
    else preview(ctx, ImGui, cache.msegs, "No regions or markers yet.") end
    ImGui.PopID(ctx)
  end
  ImGui.Spacing(ctx)
  local ch, v = ImGui.Checkbox(ctx, "Try it on this computer first##colourtryfirst", first)
  if ch then reaper.SetExtState(band.SECTION, "colour try", v and "" or "off", true) end
  ImGui.SetItemTooltip(ctx, "On: a colour button changes this computer only, with sending held, until you press Keep it for everyone (or Put it back).\n" ..
    "Off: it goes to everyone straight away (" .. require("undo").key_name() .. " still takes it back).")
  if require("groups").may_manage(cfg.root, cfg.user) then
    if ImGui.SmallButton(ctx, "Make this the studio's look") then
      require("groups").set_colours(cfg.root, whole())
      band.log("new projects in " .. tostring(band.info(cfg.root).name) .. " start in this look (a project with colours of its own keeps them)")
    end
    ImGui.SetItemTooltip(ctx, "New projects in this studio get these track colours by themselves, unless they already have colours. Any project can still pick its own.")
  end
  if from == "project" then
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, "Use the studio's look here") then reaper.SetProjExtState(proj, band.SECTION, "colours", ""); cache.at = -math.huge end
    ImGui.SetItemTooltip(ctx, "Forget this project's own look: the studio's (or this computer's last pick) is shown again. Press a colour button to apply it.")
  end
  ImGui.TextDisabled(ctx, "Who's working still shows on top, where a computer has that on.")
end
function colours.run(proj, cfg, may, only_selected)
  local done, left = colours.apply(proj, cfg, cache.list, cache.plan, may, only_selected)
  band.log(string.format("coloured %d track%s%s", done, done == 1 and "" or "s", left > 0 and string.format(": %d someone else's left as they are", left) or ""))
end

return colours
