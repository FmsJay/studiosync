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
  { "newest", "Newest work", "The longest untouched cool, the latest changed warm: where the project's been moving lately." },
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
function colours.kind_of(name)
  local n = (name or ""):lower()
  for _, k in ipairs(KINDS) do
    for _, w in ipairs(k[2]) do if n:find(w) then return k[1] end end
  end
  return colours.OTHER
end

local function hash01(s)
  local h = 2166136261
  for i = 1, #s do h = ((h ~ s:byte(i)) * 16777619) & 0xFFFFFFFF end
  return h / 0xFFFFFFFF
end

-- The colour of each track. tracks: { { name, family (its top-level folder's number), maker (a colour, or nil), newest ("" if unknown) } }.
-- opt: { stops }. Pure.
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
  local seen = {}
  for i, t in ipairs(tracks) do
    local f, at = t.family or 0, i == 1 and 0 or (i - 1) / math.max(1, n - 1)
    seen[f] = (seen[f] or 0) + 1
    if scheme == "gradient" then out[i] = colours.ramp(stops, at)
    elseif scheme == "folders" then
      local base = colours.ramp(stops, families > 1 and (f - 1) / (families - 1) or 0)
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
-- The colour of each region or marker. marks: { { name, region } }. mode: "sections" (the same section, the same colour) or "song" (along the song). Pure.
function colours.plan_marks(marks, mode, stops)
  local out, regions, at, other, n = {}, 0, 0, {}, 0
  for _, m in ipairs(marks) do if m.region then regions = regions + 1 end end
  for i, m in ipairs(marks) do
    if mode == "song" then
      out[i] = colours.ramp(stops, regions > 1 and at / (regions - 1) or 0)
      if m.region then at = at + 1 end
    else
      local key = colours.section_key(m.name)
      if SECTIONS[key] then out[i] = SECTIONS[key]
      elseif key == "" then out[i] = colours.OTHER
      else
        if not other[key] then n = n + 1; other[key] = colours.ramp(stops, (n * 0.381966) % 1) end -- (spread out however many there turn out to be)
        out[i] = other[key]
      end
    end
  end
  return out
end

local function native(rgb) return reaper.ColorToNative(rgb >> 16, (rgb >> 8) & 255, rgb & 255) | 0x1000000 end

-- What the plan needs to know of this project's tracks: the same order as CountTracks, the helpers left out.
function colours.read(proj, cfg)
  local mirror, people = require("mirror"), require("people")
  local by_tag = {}
  for u, c in pairs(people.colours(cfg.root, { cfg.user })) do by_tag[mirror.user_tag(u)] = c end
  local list, depth, family = {}, 0, 0
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    if depth == 0 then family = family + 1 end
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
      list[#list + 1] = { ptr = tr, name = (select(2, reaper.GetTrackName(tr)):gsub(" %(band%)$", ""):gsub(" %(studio%)$", "")), family = family, maker = by_tag[mirror.creator(oid)], newest = newest }
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

function colours.apply_marks(proj, mode, stops)
  local marks, idx = {}, {}
  for i = 0, reaper.CountProjectMarkers(proj) - 1 do
    local _, region, pos, rend, name, num = reaper.EnumProjectMarkers3(proj, i)
    if not band.is_local_mark(name) then
      marks[#marks + 1] = { region = region, name = name }
      idx[#idx + 1] = { i = i, region = region, pos = pos, rend = rend, name = name, num = num }
    end
  end
  local plan = colours.plan_marks(marks, mode, stops)
  reaper.Undo_BeginBlock2(proj)
  for k, m in ipairs(idx) do reaper.SetProjectMarkerByIndex2(proj, m.i, m.region, m.pos, m.rend, m.num, m.name, native(plan[k]), 0) end
  reaper.Undo_EndBlock2(proj, "Colour regions", 8)
  reaper.UpdateTimeline()
  return #idx
end

colours.ITEM_SCHEMES = {
  { "section", "By section", "Everything in a verse one colour, everything in a chorus another, from the region it starts in." },
  { "song", "Along the song", "Start of the song to the end, through the palette." },
  { "person", "By who recorded it", "Each item in the colour of the person who made it." },
  { "lane", "By lane", "Each fixed lane its own colour: comps and alternatives stand apart." },
  { "take", "By takes", "One-take items one colour, the more takes the warmer: where there's a choice still to make." },
  { "kind", "By kind", "Recordings, MIDI parts and printed parts each their own colour: what's audio and what's notes, at a glance." },
  { "newest", "Newest work", "The longest untouched cool, the latest changed warm: where the song's been moving lately." },
  { "clear", "As its track", "Takes item colours off, so items follow their track again." },
}
-- The colour of each item (false: none). items: { { pos, section (a name, or nil), maker (a colour, or nil), lane, takes } }. opt: { stops, last (the song's end) }. Pure.
function colours.plan_items(items, scheme, opt)
  local out, stops = {}, opt.stops
  local keys, n, rank = {}, 0, {}
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
  if scheme == "section" then
    for _, it in ipairs(items) do
      local k = colours.section_key(it.section or "")
      if not keys[k] then keys[k] = n; n = n + 1 end
    end
  end
  for i, it in ipairs(items) do
    if scheme == "section" then
      out[i] = it.section and colours.ramp(stops, n > 1 and keys[colours.section_key(it.section)] / (n - 1) or 0) or colours.OTHER
    elseif scheme == "song" then out[i] = colours.ramp(stops, (opt.last or 0) > 0 and it.pos / opt.last or 0)
    elseif scheme == "person" then out[i] = it.maker or colours.OTHER
    elseif scheme == "lane" then out[i] = colours.ramp(stops, ((it.lane or 0) % 5) / 4)
    elseif scheme == "take" then out[i] = colours.ramp(stops, math.min((it.takes or 1) - 1, 4) / 4)
    elseif scheme == "kind" then out[i] = it.kind == "midi" and stops[1] or it.kind == "print" and colours.ramp(stops, 0.5) or it.kind == "audio" and stops[#stops] or colours.OTHER
    elseif scheme == "newest" then out[i] = colours.ramp(stops, n > 1 and (rank[i] - 1) / (n - 1) or 1)
    else out[i] = false end
  end
  return out
end

-- Every item on tracks this person may change gets its colour. -> how many, how many left. They go out like any change, a burst at a time.
function colours.apply_items(proj, cfg, scheme, stops, may)
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
      local name = select(2, reaper.GetTrackName(tr)):gsub(" %(band%)$", ""):gsub(" %(studio%)$", "")
      for k = 0, reaper.CountTrackMediaItems(tr) - 1 do
        local it = reaper.GetTrackMediaItem(tr, k)
        if may(name, tr) then
          local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
          last = math.max(last, pos)
          local section
          for _, m in ipairs(marks) do if pos >= m.pos - 0.001 and pos < m.rend then section = m.name end end
          local tk = reaper.GetActiveTake(it)
          local kind = tk and (select(2, reaper.GetSetMediaItemTakeInfo_String(tk, "P_EXT:band_m_print", "", false)) ~= "" and "print"
            or reaper.TakeIsMIDI(tk) and "midi" or "audio") or nil
          local _, _, evid = mirror.known(proj, mirror.item_oid(it))
          list[#list + 1] = { ptr = it, pos = pos, section = section, maker = by_tag[mirror.creator(mirror.item_oid(it))], kind = kind,
            newest = (evid or ""):match("%d%d%d%d%d%d%d%d%-%d%d%d%d%d%dZ") or "",
            lane = math.floor(reaper.GetMediaItemInfo_Value(it, "I_FIXEDLANE")), takes = mirror.filled_takes(it) } -- (a print isn't a take still to choose)
        else left = left + 1 end
      end
    end
  end
  local plan = colours.plan_items(list, scheme, { stops = stops, last = last })
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
  local function saved(key, default) local v = reaper.GetExtState(band.SECTION, key); return v ~= "" and v or default end
  return { scheme = saved("colour scheme", "gradient"), palette = saved("colour palette", "Sunset"), from = saved("colour from", "2F7BFF"), to = saved("colour to", "FF8A3D") }, "computer"
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
  local uncoloured = 0
  for _, t in ipairs(list) do if reaper.GetMediaTrackInfo_Value(t.ptr, "I_CUSTOMCOLOR") == 0 then uncoloured = uncoloured + 1 end end
  if state == "" and uncoloured < #list then reaper.SetProjExtState(proj, band.SECTION, "colours auto", "had"); return end
  if uncoloured == 0 then return end
  local plan = colours.plan(list, look.scheme, { stops = colours.stops_of(look) })
  reaper.Undo_BeginBlock2(proj)
  local done = 0
  for i, t in ipairs(list) do
    if reaper.GetMediaTrackInfo_Value(t.ptr, "I_CUSTOMCOLOR") == 0 and may(t.name, t.ptr) then band.set_track_colour(t.ptr, native(plan[i])); done = done + 1 end
  end
  reaper.Undo_EndBlock2(proj, "Colour tracks", 1)
  if state == "" then reaper.SetProjExtState(proj, band.SECTION, "colours auto", "auto") end
  if done > 0 then reaper.TrackList_AdjustWindows(false); band.log(string.format("coloured %d new track%s in the %s look", done, done == 1 and "" or "s", from == "studio" and "studio's" or "project's")) end
end

-- ---- trying a look here first (0.58.98, James: "an easy way to test/audition a look before applying it to everyone"): sending is held
-- (Hold sync, lib/sync.lua) while it's tried, and what was there is kept, so Put back puts exactly that back, and Keep lets it go to everyone.
local trying -- { proj, held_before, tracks = { ptr -> colour }, items = { ptr -> colour }, marks = { index -> {...} } }
local function snapshot(proj)
  local t = { proj = proj, held_before = select(2, reaper.GetProjExtState(proj, band.SECTION, "hold")), tracks = {}, items = {}, marks = {} }
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    t.tracks[tr] = reaper.GetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR")
    for k = 0, reaper.CountTrackMediaItems(tr) - 1 do local it = reaper.GetTrackMediaItem(tr, k); t.items[it] = reaper.GetMediaItemInfo_Value(it, "I_CUSTOMCOLOR") end
  end
  for i = 0, reaper.CountProjectMarkers(proj) - 1 do
    local _, region, pos, rend, name, num, colour = reaper.EnumProjectMarkers3(proj, i)
    t.marks[#t.marks + 1] = { i = i, region = region, pos = pos, rend = rend, name = name, num = num, colour = colour }
  end
  return t
end
local function try_first(proj, fn)
  if not trying or trying.proj ~= proj then
    trying = snapshot(proj)
    reaper.SetProjExtState(proj, band.SECTION, "hold", "1") -- (nothing goes out while it's tried)
  end
  fn()
end
function colours.trying(proj) return trying ~= nil and trying.proj == proj end
function colours.keep(proj)
  if not colours.trying(proj) then return end
  reaper.SetProjExtState(proj, band.SECTION, "hold", trying.held_before or "")
  band.log((trying.held_before or "") ~= "" and "kept the new look (Hold sync was already on: it goes out when you release it)" or "kept the new look: it goes to everyone now")
  trying = nil
end
function colours.put_back(proj)
  if not colours.trying(proj) then return end
  reaper.Undo_BeginBlock2(proj)
  for tr, c in pairs(trying.tracks) do if reaper.ValidatePtr2(proj, tr, "MediaTrack*") then reaper.SetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR", c) end end
  for it, c in pairs(trying.items) do if reaper.ValidatePtr2(proj, it, "MediaItem*") then reaper.SetMediaItemInfo_Value(it, "I_CUSTOMCOLOR", c) end end
  for _, m in ipairs(trying.marks) do reaper.SetProjectMarkerByIndex2(proj, m.i, m.region, m.pos, m.rend, m.num, m.name, m.colour, 0) end
  reaper.Undo_EndBlock2(proj, "Colours put back", -1)
  reaper.SetProjExtState(proj, band.SECTION, "hold", trying.held_before or "")
  trying = nil
  reaper.TrackList_AdjustWindows(false); reaper.UpdateArrange(); reaper.UpdateTimeline()
  band.log("the look you tried is put back: nothing went to the others")
end

local item_pick = "section"
function colours.draw(ctx, ImGui, proj, cfg, may, timeline_ok)
  ImGui.SeparatorText(ctx, "Colour the project")
  local look, from = colours.look_of(proj, cfg.root)
  local scheme, palette = look.scheme, look.palette or "Sunset"
  local a, z = tonumber(look.from or "2F7BFF", 16) or 0x2F7BFF, tonumber(look.to or "FF8A3D", 16) or 0xFF8A3D
  -- (a change of look is this project's own from now: the studio's stays the default for new ones)
  local function set(field, value)
    local t = { scheme = scheme, palette = palette, from = string.format("%06X", a), to = string.format("%06X", z) }
    t[field] = value
    reaper.SetProjExtState(proj, band.SECTION, "colours", band.json_encode(t))
    local keys = { scheme = "colour scheme", palette = "colour palette", from = "colour from", to = "colour to" }
    reaper.SetExtState(band.SECTION, keys[field], value, true) -- (and this computer's last pick)
    cache.at = -math.huge
  end
  ImGui.PushTextWrapPos(ctx, 0)
  ImGui.TextDisabled(ctx, "Pick a look, try it here, then keep it for everyone. " .. (from == "project" and "This project has a look of its own." or
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
  local label, tip = scheme, ""
  for _, s in ipairs(colours.SCHEMES) do if s[1] == scheme then label, tip = s[2], s[3] end end
  ImGui.AlignTextToFramePadding(ctx); ImGui.Text(ctx, "Tracks:"); ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, 170)
  if ImGui.BeginCombo(ctx, "##colourscheme", label) then
    for _, s in ipairs(colours.SCHEMES) do
      if ImGui.Selectable(ctx, s[2], s[1] == scheme) then set("scheme", s[1]); scheme = s[1] end
      ImGui.SetItemTooltip(ctx, s[3])
    end
    ImGui.EndCombo(ctx)
  end
  ImGui.SetItemTooltip(ctx, "How tracks are coloured: " .. tip)
  local uses = scheme == "gradient" or scheme == "folders" or scheme == "stripes" or scheme == "newest"
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, 120)
  if ImGui.BeginCombo(ctx, "##colourpalette", palette) then
    for _, p in ipairs(colours.PALETTES) do
      if ImGui.Selectable(ctx, p[1], p[1] == palette) then set("palette", p[1]); palette = p[1] end
    end
    if ImGui.Selectable(ctx, "Your own", palette == "Your own") then set("palette", "Your own"); palette = "Your own" end
    ImGui.EndCombo(ctx)
  end
  ImGui.SetItemTooltip(ctx, uses and "The colours it runs through. Items and regions use them too." or "For items and regions. This way of colouring tracks has its own colours.")
  local stops = colours.stops_of({ palette = palette, from = string.format("%06X", a), to = string.format("%06X", z) })
  if palette == "Your own" then
    ImGui.SameLine(ctx)
    local ch1, v1 = ImGui.ColorEdit3(ctx, "##colourfrom", a, ImGui.ColorEditFlags_NoInputs)
    ImGui.SameLine(ctx)
    local ch2, v2 = ImGui.ColorEdit3(ctx, "##colourto", z, ImGui.ColorEditFlags_NoInputs)
    if ch1 then a = v1; set("from", string.format("%06X", v1)) end
    if ch2 then z = v2; set("to", string.format("%06X", v2)) end
  end
  if reaper.time_precise() - cache.at > 2 or cache.proj ~= proj then
    cache.at, cache.proj = reaper.time_precise(), proj
    cache.list = colours.read(proj, cfg)
    cache.plan = colours.plan(cache.list, scheme, { stops = stops })
  end
  local w = ImGui.GetContentRegionAvail(ctx)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local dl, n = ImGui.GetWindowDrawList(ctx), #cache.list
  for i, rgb in ipairs(cache.plan) do
    local x0 = x + (i - 1) * w / n
    ImGui.DrawList_AddRectFilled(dl, x0, y, x0 + w / n - 1, y + 16, (rgb << 8) | 0xFF, 2)
  end
  ImGui.InvisibleButton(ctx, "##colourpreview", math.max(1, w), 16)
  if ImGui.IsItemHovered(ctx) and n > 0 then
    local i = math.max(1, math.min(n, math.floor((select(1, ImGui.GetMousePos(ctx)) - x) / w * n) + 1))
    ImGui.SetTooltip(ctx, cache.list[i].name)
  end
  local first = reaper.GetExtState(band.SECTION, "colour try") ~= "off"
  local function go(fn) if first then try_first(proj, fn) else fn() end end
  if ImGui.Button(ctx, "Colour all tracks") then go(function() colours.run(proj, cfg, may, false) end) end
  ImGui.SetItemTooltip(ctx, "Every track you may change, in the look above. Someone else's stays as it is.")
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Selected tracks only") then go(function() colours.run(proj, cfg, may, true) end) end
  ImGui.SetItemTooltip(ctx, "Only the tracks selected in REAPER.")
  -- items: pick how, then a button (picking in the list coloured everything at once: James, 0.58.98 "a little confusing")
  local ilabel, itip = item_pick, ""
  for _, s in ipairs(colours.ITEM_SCHEMES) do if s[1] == item_pick then ilabel, itip = s[2], s[3] end end
  ImGui.AlignTextToFramePadding(ctx); ImGui.Text(ctx, "Items:"); ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, 170)
  if ImGui.BeginCombo(ctx, "##colouritems", ilabel) then
    for _, s in ipairs(colours.ITEM_SCHEMES) do
      if ImGui.Selectable(ctx, s[2], s[1] == item_pick) then item_pick = s[1] end
      ImGui.SetItemTooltip(ctx, s[3])
    end
    ImGui.EndCombo(ctx)
  end
  ImGui.SetItemTooltip(ctx, itip)
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Colour items") then
    go(function()
      local n, left = colours.apply_items(proj, cfg, item_pick, stops, may)
      band.log(string.format("coloured %d item%s%s", n, n == 1 and "" or "s", left > 0 and string.format(": %d of someone else's left as they are", left) or ""))
    end)
  end
  ImGui.SetItemTooltip(ctx, "Items on the tracks you may change, " .. ilabel:lower() .. ", in the palette above.")
  ImGui.AlignTextToFramePadding(ctx); ImGui.Text(ctx, "Regions:"); ImGui.SameLine(ctx)
  ImGui.BeginDisabled(ctx, not timeline_ok)
  if ImGui.Button(ctx, "By section") then go(function() band.log(string.format("coloured %d regions and markers: the same section, the same colour", colours.apply_marks(proj, "sections", stops))) end) end
  ImGui.SetItemTooltip(ctx, timeline_ok and "Every verse one colour, every chorus another." or "The timeline is the driver's: they do this.")
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Along the song") then go(function() band.log(string.format("coloured %d regions and markers along the song", colours.apply_marks(proj, "song", stops))) end) end
  ImGui.SetItemTooltip(ctx, timeline_ok and "Start to end, through the palette." or "The timeline is the driver's: they do this.")
  ImGui.EndDisabled(ctx)
  local ch, v = ImGui.Checkbox(ctx, "Try it on this computer first##colourtryfirst", first)
  if ch then reaper.SetExtState(band.SECTION, "colour try", v and "" or "off", true) end
  ImGui.SetItemTooltip(ctx, "On: a colour button changes this computer only, with sending held, until you press Keep it for everyone (or Put it back).\n" ..
    "Off: it goes to everyone straight away (" .. require("undo").key_name() .. " still takes it back).")
  if require("groups").may_manage(cfg.root, cfg.user) then
    if ImGui.SmallButton(ctx, "Make this the studio's look") then
      require("groups").set_colours(cfg.root, { scheme = scheme, palette = palette, from = string.format("%06X", a), to = string.format("%06X", z) })
      band.log("new projects in " .. tostring(band.info(cfg.root).name) .. " start in this look (a project with colours of its own keeps them)")
    end
    ImGui.SetItemTooltip(ctx, "New projects in this studio are coloured this way by themselves, unless they already have colours. Any project can still pick its own.")
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
