-- Each person's colour, and tracks that show who's working on them (James, 2026-11-01).
-- Everyone has a colour: their own pick (Setup > Options), else a default from the palette nobody has picked, the
-- same on every machine. Drawings use it ("Mine"); tracks may too, as this machine chooses (ExtState "colour base", and
-- "colour working" / "colour new" on or off; before 0.58.79 one choice, "track colours"):
--   "band"     the studio's colours, with either or both of these on top (both by default: James, 0.58.79):
--              who's working: a track someone else is editing (its last 15 s, lib/presence.lua) or has claimed shows their colour
--              what's new: a track someone else changed shows their colour, briefly while you're here, and until you say OK
--              to "Since you were last here" for what came while you were away
--   "people"   every track in the colour of whoever is editing it, claimed it, or made it
-- A person's colour on a track is only ever shown here: the band's colour waits in the track's P_EXT:band_colour
-- meanwhile, and mirror, restore points and the rest read and write that one (band.track_colour), so nothing sends,
-- saves or loses it.
--   _band/colours/<user>.json   { colour = 0xRRGGBB, time, auto }: each person's own file (one writer each). A person with no pick has their
--                               default written there once (auto = true), so it's chosen once and kept in the studio: the same on every
--                               computer whoever joins later (James, rt: colour parity). They can change it any time.
-- With the studio's Colour parity on (lib/groups.lua colour_parity, the default) no track is ever recoloured here: who's working shows in
-- Who's here ("Working in ...", their claims) and in claim regions, and every computer shows the project's own colours.
local band = require("band")
local people = {}

people.PALETTE = { 0xFF5A5A, 0x4CC2FF, 0x7BE07B, 0xFFC24C, 0xC88BFF, 0xFF8BD0, 0x5AE0D0, 0xFF9F5A }
people.MODES = { { "band", "Studio colours", "Tracks keep the colours the studio gave them, with what's ticked below on top." },
  { "people", "Track owner", "Every track in the colour of whoever is editing it, claimed it, or made it." } }
people.SHOWS = { { "working", "Show who's working", "A track someone else is editing or has claimed shows their colour until they're done." },
  { "new", "Show what's new", "A track someone else changes shows their colour for a minute or two. What changed while you were away stays in their\n" ..
    "colour until you press OK on 'Since you were last here' at the top of Home." } }
people.NEW_FULL, people.NEW_FOR = 20, 120
-- How strongly a change this old shows while you're here: full for 20 s, then fading to nothing by 2 minutes. Pure.
function people.fade(age)
  if age < people.NEW_FULL then return 1 end
  if age >= people.NEW_FOR then return 0 end
  return 1 - (age - people.NEW_FULL) / (people.NEW_FOR - people.NEW_FULL)
end
-- "2026-11-16T14:11:00Z" -> "20261116-141100Z", the form changes' ids carry. Pure.
function people.compact(iso) return ((iso or ""):gsub("[-:]", ""):gsub("T", "-")) end
-- How strongly a track shows someone's change with id stamp `stamp` (compact UTC), `age` seconds old: in full while it came while
-- you were away (after `last_here`, before this computer opened the project at `opened`) and you haven't said OK since (`seen`),
-- else as people.fade. -> strength, held for OK. Pure.
function people.strength(stamp, age, last_here, opened, seen)
  if last_here ~= "" and stamp > last_here and stamp <= opened and not (seen ~= "" and seen >= opened) then return 1, true end
  return people.fade(age), false
end

local function file(root, user) return root .. "/_band/colours/" .. (user:gsub("[^%w%-_ ]", "")) .. ".json" end

-- Everyone's colour: picked ones, then a default each for the rest of `known` (name order, so every machine agrees), then for `later` (names
-- only some computers know of: someone in a room, who drew), skipping colours already taken. `later` comes after so it never moves a member's
-- default: a guest one computer knew of shifted everyone after them in name order there (colour parity audit, James, rt). Pure over `picked`
-- ({ user = rgb }), `known` and `later` (names).
function people.assign(picked, known, later)
  local out, taken, rest, seen = {}, {}, {}, {}
  for u, c in pairs(picked) do out[u], taken[c] = c, true end
  local function add(list)
    local more = {}
    for _, u in ipairs(list or {}) do if not out[u] and not seen[u] then seen[u] = true; more[#more + 1] = u end end
    table.sort(more)
    for _, u in ipairs(more) do rest[#rest + 1] = u end
  end
  add(known)
  add(later)
  local i = 0
  for _, u in ipairs(rest) do
    local c
    for _ = 1, #people.PALETTE do
      i = i % #people.PALETTE + 1
      if not taken[people.PALETTE[i]] then c = people.PALETTE[i]; break end
    end
    c = c or people.PALETTE[i] -- (more people than colours: they share)
    out[u], taken[c] = c, true
  end
  return out
end

local cache = {} -- root -> { at, picked, members }
-- Everyone's colour in this band (+ `extra` names: people in a room, who drew). 0xRRGGBB each.
function people.colours(root, extra)
  local c = cache[root]
  if not c or reaper.time_precise() - c.at > 10 then
    c = { at = reaper.time_precise(), picked = {}, members = {} }
    for _, f in ipairs(band.files(root .. "/_band/colours", ".json")) do
      local p = band.read_json(root .. "/_band/colours/" .. f)
      if type(p) == "table" and type(p.user) == "string" and math.tointeger(tonumber(p.colour)) then c.picked[p.user] = math.tointeger(tonumber(p.colour)) end
    end
    for _, f in ipairs(band.files(root .. "/plugins", ".json")) do -- (every machine publishes its plug-in list: the band's members)
      local p = band.read_json(root .. "/plugins/" .. f)
      if type(p) == "table" and type(p.user) == "string" then c.members[#c.members + 1] = p.user end
    end
    cache[root] = c
  end
  return people.assign(c.picked, c.members, extra)
end
-- Your colour is the same in every studio you're in (James, 0.58.82: "make the colour settings sync across studios"): a pick goes to all of
-- them, and a studio without one takes the newest you made elsewhere (once a panel run each: a studio joined later catches up).
-- (only from one of this computer's studios, as you: a scratch folder, or a test picking for someone else, stays where it is)
local function my_studios(cfg)
  local roots, seen, inside = { cfg.root }, { [cfg.root] = true }, false
  for _, x in ipairs(band.bands()) do
    if x.root == cfg.root then inside = true end
    if x.root and not seen[x.root] then seen[x.root] = true; roots[#roots + 1] = x.root end
  end
  if not inside or cfg.user ~= reaper.GetExtState(band.SECTION, "user") then return { cfg.root } end
  return roots
end
-- The newest pick of `user`'s among their own files in `roots`: the file's table, or nil. Pure but for reading them.
function people.newest_pick(roots, user)
  local best
  for _, root in ipairs(roots) do
    local p = band.read_json(file(root, user))
    -- (a kept default isn't a pick: it stays in its studio, where it was free)
    if type(p) == "table" and p.user == user and not p.auto and math.tointeger(tonumber(p.colour)) and (not best or tostring(p.time) > tostring(best.time)) then best = p end
  end
  return best
end
local aligned = {}
function people.mine(cfg)
  if not aligned[cfg.root .. "|" .. cfg.user] then
    aligned[cfg.root .. "|" .. cfg.user] = true
    local p = people.newest_pick(my_studios(cfg), cfg.user)
    local here = band.read_json(file(cfg.root, cfg.user))
    if p and not (type(here) == "table" and here.colour == p.colour) then
      reaper.RecursiveCreateDirectory(cfg.root .. "/_band/colours", 0)
      band.write_json(file(cfg.root, cfg.user), p)
      cache[cfg.root] = nil
    elseif not p and type(here) ~= "table" and cfg.user == reaper.GetExtState(band.SECTION, "user") then
      -- no pick anywhere: today's default is kept in the studio, so it can't move when someone joins (colour parity, James, rt)
      local c = people.colours(cfg.root, { cfg.user })[cfg.user]
      if c then
        reaper.RecursiveCreateDirectory(cfg.root .. "/_band/colours", 0)
        band.write_json(file(cfg.root, cfg.user), { user = cfg.user, colour = c, time = os.date("!%Y-%m-%dT%H:%M:%SZ"), auto = true })
        cache[cfg.root] = nil
      end
    end
  end
  return people.colours(cfg.root, { cfg.user })[cfg.user]
end
-- Pick a colour (nil: back to the default), in every studio you're in.
function people.pick(cfg, rgb)
  for _, root in ipairs(my_studios(cfg)) do
    if rgb then
      reaper.RecursiveCreateDirectory(root .. "/_band/colours", 0)
      band.write_json(file(root, cfg.user), { user = cfg.user, colour = rgb, time = os.date("!%Y-%m-%dT%H:%M:%SZ") })
    else
      os.remove(file(root, cfg.user))
    end
    cache[root] = nil
  end
end
-- How far apart two colours look (0xRRGGBB): the "redmean" distance, which weighs red, green and blue as eyes do, 0 to about 765. Pure.
function people.distance(a, b)
  local r1, g1, b1 = (a >> 16) & 255, (a >> 8) & 255, a & 255
  local r2, g2, b2 = (b >> 16) & 255, (b >> 8) & 255, b & 255
  local rm, dr, dg, db = (r1 + r2) / 2, r1 - r2, g1 - g2, b1 - b2
  return math.sqrt((2 + rm / 256) * dr * dr + 4 * dg * dg + (2 + (255 - rm) / 256) * db * db)
end
people.ALIKE = 70 -- (under this, two people's tracks are hard to tell apart at a glance: the palette's nearest two, yellow and orange, are 73 apart)
-- The pairs of people whose colours look alike, { { a, b }, ... } in name order. `colours`: { user = rgb }. Pure.
function people.alike(colours)
  local names, out = {}, {}
  for u in pairs(colours) do names[#names + 1] = u end
  table.sort(names)
  for i = 1, #names do
    for j = i + 1, #names do
      if people.distance(colours[names[i]], colours[names[j]]) < people.ALIKE then out[#out + 1] = { names[i], names[j] } end
    end
  end
  return out
end
-- The palette colour farthest from everyone else's, for `me`. Pure.
function people.distinct(colours, me)
  local best, best_d
  for _, c in ipairs(people.PALETTE) do
    local d = math.huge
    for u, x in pairs(colours) do if u ~= me then d = math.min(d, people.distance(c, x)) end end
    if not best_d or d > best_d then best, best_d = c, d end
  end
  return best
end
function people.mode()
  local m = reaper.GetExtState(band.SECTION, "colour base")
  if m == "" then m = reaper.GetExtState(band.SECTION, "track colours") end -- (before 0.58.79)
  return m == "people" and "people" or "band"
end
-- Is "working" or "new" on? Both are unless switched off, or "Studio colours" alone was picked before 0.58.79.
function people.shows(what)
  local v = reaper.GetExtState(band.SECTION, "colour " .. what)
  if v ~= "" then return v == "on" end
  return reaper.GetExtState(band.SECTION, "track colours") ~= "band"
end

-- Who a track shows, in this machine's mode: someone else editing it, else its claimant, else (Whose track) whoever
-- made it. `editing`: oid -> user (bandmates' edit holds); `claims`: lower track name -> { user } (sync.authority).
-- Pure apart from REAPER reads of the track.
function people.who(tr, mode, editing, claims, cfg)
  local me = cfg.user
  if mode == "band" then return nil end
  local mirror = require("mirror")
  local oid = mirror.track_oid(tr)
  local rest = oid:sub(2)
  for o, u in pairs(editing) do
    if u ~= me and (o == oid or (o:sub(1, 1) ~= "I" and o:sub(2) == rest)) then return u end -- (the track, its plug-ins, envelopes...)
  end
  for i = 0, reaper.CountTrackMediaItems(tr) - 1 do
    local u = editing[mirror.item_oid(reaper.GetTrackMediaItem(tr, i))]
    if u and u ~= me then return u end
  end
  local name = require("sync").base_name(select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false))):lower()
  if claims[name] then return claims[name].user end
  if mode == "people" then
    local tag = mirror.creator(oid)
    if tag then
      for u in pairs(people.colours(cfg.root, { me })) do if mirror.user_tag(u) == tag then return u end end
      local now = band.names()[tag] -- (they renamed since)
      if now then return now end
    end
  end
  return nil
end

-- What's new: each track's newest change by someone in `names`. -> track -> { user, age, stamp }. Read every 5 s: it looks at every item.
local new_at, new_of, opened = {}, {}, {}
local function newest_changes(proj, names)
  if new_of[proj] and reaper.time_precise() - new_at[proj] < 5 then return new_of[proj] end
  local mirror, out = require("mirror"), {}
  local now = os.time(os.date("!*t"))
  local sync = require("sync")
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    local best, who = "", nil
    local function look(oid)
      local _, _, ev = mirror.known(proj, oid)
      local stamp = (ev or ""):match("%d%d%d%d%d%d%d%d%-%d%d%d%d%d%dZ")
      if stamp and stamp > best then
        best, who = stamp, nil
        for u in pairs(names) do if sync.is_mine(ev, u) then who = u end end -- (not a prefix: "James" would take "James-Laptop"'s. 0.58.82)
      end
    end
    look(mirror.track_oid(tr))
    for k = 0, reaper.CountTrackMediaItems(tr) - 1 do look(mirror.item_oid(reaper.GetTrackMediaItem(tr, k))) end
    local y, mo, d, h, mi, s = best:match("(%d%d%d%d)(%d%d)(%d%d)%-(%d%d)(%d%d)(%d%d)")
    if y and who then out[tr] = { user = who, stamp = best, age = now - os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = s, isdst = false }) } end
  end
  new_at[proj], new_of[proj] = reaper.time_precise(), out
  return out
end

-- Show it: each mirrored track in its person's colour, or the band's. `peers`: bandmates' status files. `where`: "<song>/<room>",
-- for what came while you were away (its "last here", lib/extras.lua).
-- Colour parity on (the studio's, lib/groups.lua): no overlay anywhere, and any left from before goes back to the band's colour.
function people.parity(cfg) local ok, on = pcall(require("groups").colour_parity, cfg.root); return not ok or on end
-- -> true when any track's colour was written (Live sync's redraw. James, rt)
function people.paint(proj, cfg, peers, claims, where)
  local wrote = false
  if people.parity(cfg) then
    for i = 0, reaper.CountTracks(proj) - 1 do
      local tr = reaper.GetTrack(proj, i)
      if band.track_ext(tr, "band_colour") ~= "" and band.show_colour(tr, nil) then wrote = true end
    end
    if where then reaper.SetExtState(band.SECTION, "new held " .. where, "", false) end
    return wrote
  end
  local base, editing, others = people.mode(), {}, {}
  local mode = base == "people" and "people" or people.shows("working") and "working" or "band"
  for _, st in ipairs(peers or {}) do
    if type(st.user) == "string" then
      others[#others + 1] = st.user
      for _, o in ipairs(type(st.editing) == "table" and st.editing or {}) do editing[o] = st.user end
    end
  end
  local colours = mode ~= "band" and people.colours(cfg.root, others) or {}
  local mirror = require("mirror")
  local new
  if base == "band" and people.shows("new") then
    local names = people.colours(cfg.root, { cfg.user, table.unpack(others) })
    names[cfg.user] = nil -- (your own changes you know about)
    new = newest_changes(proj, names)
    opened[proj] = opened[proj] or os.date("!%Y%m%d-%H%M%SZ")
  end
  local last_here = where and people.compact(reaper.GetExtState(band.SECTION, "last here " .. where)) or ""
  local seen = where and reaper.GetExtState(band.SECTION, "new seen " .. where) or ""
  local held = 0
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    if not mirror.local_track(tr) then
      local u = people.who(tr, mode, editing, claims or {}, cfg)
      local rgb = u and (colours[u] or people.colours(cfg.root, { u })[u])
      local fresh = new and not rgb and new[tr]
      local strength, away = 0, false
      if fresh then strength, away = people.strength(fresh.stamp, fresh.age, last_here, opened[proj], seen) end
      if away then held = held + 1 end
      if strength > 0 then
        local bc, c = band.track_colour(tr), colours[fresh.user] or people.colours(cfg.root, { fresh.user })[fresh.user]
        local from = bc and bc ~= 0 and (function() local r, g, b = reaper.ColorFromNative(bc & 0xFFFFFF); return (r << 16) | (g << 8) | b end)() or 0x808080
        rgb = require("colours").mix(from, c, strength)
      end
      if band.show_colour(tr, rgb and (reaper.ColorToNative(rgb >> 16, (rgb >> 8) & 0xFF, rgb & 0xFF) | 0x1000000) or nil) then wrote = true end
    end
  end
  -- (the panel's "Since you were last here" shows while tracks are held for it, and its OK lets them go: people.seen)
  if where then reaper.SetExtState(band.SECTION, "new held " .. where, held > 0 and tostring(held) or "", false) end
  return wrote
end
-- OK on "Since you were last here": tracks showing what came while you were away go back to the studio's colours.
function people.seen(where)
  reaper.SetExtState(band.SECTION, "new seen " .. where, os.date("!%Y%m%d-%H%M%SZ"), true)
  reaper.SetExtState(band.SECTION, "new held " .. where, "", false)
end
function people.held(where) return tonumber(reaper.GetExtState(band.SECTION, "new held " .. where)) or 0 end

-- Settings: your colour, and how tracks look here. (In this file: the panel is near Lua's 200-locals limit.)
function people.colour_options(ctx, ImGui, cfg)
  ImGui.SeparatorText(ctx, "Your colour")
  local mine = people.mine(cfg)
  local list = {}
  for _, c in ipairs(people.PALETTE) do list[#list + 1] = c end
  -- (more to pick from: James, 0.59.3)
  for _, c in ipairs({ 0xE0E0E0, 0x8A6BFF, 0x3DFF8A, 0xFFE05A, 0xFF3D7F, 0x00B3A4, 0xB5E550, 0xFFB000, 0x6A8CFF, 0xD96BFF, 0xFF6F3D, 0x8FD3FF,
    0x2ECC71, 0xE74C3C, 0x9B59B6, 0xF1C40F }) do list[#list + 1] = c end
  local others = {} -- (a colour someone else shows in can't be picked: picking it moved their default, Mac 0.39.0)
  for u, c in pairs(people.colours(cfg.root, { cfg.user })) do if u ~= cfg.user then others[c] = u end end
  -- (on the same row while it fits: in a narrow column the last ones were cut off, with no way to reach them)
  local function next_to(width)
    ImGui.SameLine(ctx)
    if ImGui.GetContentRegionAvail(ctx) < width then ImGui.NewLine(ctx) end
  end
  local listed = false
  for _, c in ipairs(list) do listed = listed or c == mine end
  for i, c in ipairs(list) do
    if i > 1 then next_to(30) end
    ImGui.PushID(ctx, i)
    local size = c == mine and 26 or 20 -- (yours: the bigger one)
    ImGui.BeginDisabled(ctx, others[c] ~= nil)
    if ImGui.ColorButton(ctx, "##colour", (c << 8) | 0xFF, ImGui.ColorEditFlags_NoTooltip, size, size) then people.pick(cfg, c) end
    ImGui.EndDisabled(ctx)
    if others[c] then ImGui.SetItemTooltip(ctx, others[c] .. "'s") end
    ImGui.PopID(ctx)
  end
  -- Any colour: the last swatch, with a colour wheel on it; it takes the colour you pick, and is the bigger one then (James, 0.59.4: "a color
  -- wheel icon on the swatch... then it switches based on what you pick"). The wheel's window is ColorEdit's own, as before.
  next_to(30)
  local own = mine and not listed
  local pad = own and 6 or 3 -- (26 or 20 high, as the others)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, pad, (( own and 26 or 20) - ImGui.GetFontSize(ctx)) / 2)
  -- (held while you drag, picked when you let go: picking on every frame wrote to every studio's folder, and the wheel spun. 0.59.6)
  require("colours").edit3(ctx, ImGui, "##own", own and mine or 0x6A6F7A, function(v) if v ~= mine then people.pick(cfg, v) end end,
    ImGui.ColorEditFlags_NoInputs | ImGui.ColorEditFlags_PickerHueWheel | ImGui.ColorEditFlags_NoTooltip)
  ImGui.PopStyleVar(ctx)
  ImGui.SetItemTooltip(ctx, "Any colour of your own: click for the colour wheel")
  do -- the wheel on it: a ring of hues, small in the corner once it shows your colour
    local x0, y0 = ImGui.GetItemRectMin(ctx)
    local x1, y1 = ImGui.GetItemRectMax(ctx)
    local h = math.min(x1 - x0, y1 - y0)
    local r = own and h * 0.22 or h * 0.36
    local cx, cy = own and (x1 - r - 2) or (x0 + h / 2), own and (y1 - r - 2) or (y0 + h / 2)
    local dl, hsv = ImGui.GetWindowDrawList(ctx), require("colours").hsv
    for k = 0, 11 do
      local t0, t1 = k / 12 * 2 * math.pi, (k + 1) / 12 * 2 * math.pi
      ImGui.DrawList_AddTriangleFilled(dl, cx, cy, cx + r * math.cos(t0), cy + r * math.sin(t0), cx + r * math.cos(t1), cy + r * math.sin(t1), (hsv(k / 12, 0.85, 1) << 8) | 0xFF)
    end
  end
  next_to(70)
  if ImGui.SmallButton(ctx, "Default##colour") then people.pick(cfg, nil) end
  ImGui.TextDisabled(ctx, "Everyone sees you in it, in every studio you're in: your drawings, and tracks you're working on where they show that.")
end
function people.track_options(ctx, ImGui)
  ImGui.SeparatorText(ctx, "Track colours you see")
  local b = band.binding(reaper.EnumProjects(-1))
  if b and b.root and people.parity(b) then -- (the studio's choice wins over this computer's: James, rt)
    ImGui.TextDisabled(ctx, "Colour parity is on in this studio: every computer shows the project's own colours. Who's working shows in Who's here " ..
      "and in claim regions, not on the tracks. (Owner and admins: Settings > Studio > Colour parity.)")
    return
  end
  local function next_to(words)
    ImGui.SameLine(ctx)
    if ImGui.GetContentRegionAvail(ctx) < ImGui.CalcTextSize(ctx, words) + 40 then ImGui.NewLine(ctx) end
  end
  for i, m in ipairs(people.MODES) do
    if i > 1 then next_to(m[2]) end
    if ImGui.RadioButton(ctx, m[2] .. "##trackcolours", people.mode() == m[1]) then reaper.SetExtState(band.SECTION, "colour base", m[1], true) end
    ImGui.SetItemTooltip(ctx, m[3] .. "\nYour view, in every project and studio on this computer. Nobody else's colours change.")
  end
  ImGui.BeginDisabled(ctx, people.mode() ~= "band")
  for i, w in ipairs(people.SHOWS) do -- (on top of the studio's colours, one or both: James, 0.58.79)
    if i > 1 then next_to(w[2]) end
    local ch, v = ImGui.Checkbox(ctx, w[2] .. "##colour" .. w[1], people.shows(w[1]))
    if ch then reaper.SetExtState(band.SECTION, "colour " .. w[1], v and "on" or "off", true) end
    ImGui.SetItemTooltip(ctx, w[3] .. "\nYour view, in every project and studio on this computer.")
  end
  ImGui.EndDisabled(ctx)
end

return people
