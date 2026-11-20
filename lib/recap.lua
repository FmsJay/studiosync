-- Session recaps and smart take names (James, rt).
--
-- Recap: when a session ends (Live sync's end-of-session moment: 20 quiet minutes, Leave, or Live sync stopping), a few plain bullets about
-- it, worked out from the events the room already has (no new tracking, no AI model): who was there, how long, the takes recorded, tracks
-- added or removed, tempo and arrangement edits, notes, and saved versions. Shown as "Last session" on the Restore page, as a line in this
-- computer's log, and as a Markdown file in the song's cloud folder (readable on a phone).
-- Who writes: each computer its own view, into files only it writes (<room>/recaps/<user>.json, <cloud>/<song>/recaps/<date time> <user>.md),
-- the studio's rule of never two writers on one file (claims, status). A single writer (the driver) leaves gaps (the driver leaves first, or
-- 20 quiet minutes fires on everyone at once and the driver's REAPER is closed), and two writers of one file make Syncthing or cloud conflict
-- copies. The panel shows the newest recap in the room: whoever left last saw the most of the session.
--
-- Smart take names: when a recording stops, each new take still carrying REAPER's own name becomes "<section> - <player> - take <n>", the
-- section being the region (else the marker) under its start, n counted per section and player across the song. Renamed before the next
-- look, so it goes out with the take's first send (a take's name is part of its item's state: mirror sync carries it like any edit).
local recap = { GAP = 1200, KEEP = 20, MAX_READ = 1500 }

-- ---- pure -------------------------------------------------------------------------------------------------------------------------------
-- The section under `pos`: the region holding it (the latest-starting one, when they nest), else the last marker at or before it. Markers as
-- band.capture_markers gives them ({ region, pos, end, name }). Unnamed ones don't count. -> its name, or nil.
function recap.section_at(markers, pos)
  local rgn, mk
  for _, m in ipairs(markers or {}) do
    local name = tostring(m.name or "")
    if name ~= "" and m.pos and m.pos <= pos + 1e-6 then
      if m.region then
        if pos < (m["end"] or m.pos) - 1e-6 and (not rgn or m.pos >= rgn.pos) then rgn = m end
      elseif not mk or m.pos >= mk.pos then mk = m end
    end
  end
  return (rgn or mk) and (rgn or mk).name or nil
end
function recap.smart_name(section, player, n)
  return (section and section ~= "" and (section .. " - ") or "") .. tostring(player) .. " - take " .. n
end
-- A smart name read back: section (nil without one), player, n. Not one: nil.
function recap.parse_name(name)
  name = tostring(name or "")
  local s, p, n = name:match("^(.+) %- (.-) %- take (%d+)$")
  if s then return s, p, tonumber(n) end
  p, n = name:match("^(.-) %- take (%d+)$")
  if p and p ~= "" then return nil, p, tonumber(n) end
  return nil
end
-- The next take number for a section and player, given every take name in the song.
function recap.next_n(names, section, player)
  local top = 0
  for _, nm in ipairs(names) do
    local s, p, n = recap.parse_name(nm)
    if p == player and (s or "") == (section or "") then top = math.max(top, n) end
  end
  return top + 1
end
-- Is this still the name REAPER gave the recording? Empty; the recorded file's own name (with or without its extension); a MIDI recording's
-- "untitled MIDI item". Anything else someone typed, and is never overwritten.
function recap.is_default_name(name, file)
  name = tostring(name or "")
  if name == "" or name:match("^untitled MIDI item") then return true end
  local base = tostring(file or ""):gsub("\\", "/"):match("([^/]+)$")
  if not base then return false end
  local stem = base:gsub("%.[^.]+$", "")
  -- (or the band's shared copy of that file, "<hash>-<name with plain characters>": mirror.share_media. REAPER's take name keeps the
  -- recorded file's extension, "03-XT Rec A-261119_1730.flac", while the copy is "4a2761dd-03-XT_Rec_A-261119_1730.flac": compared without
  -- the extension on both sides, or a take whose source was already swapped to the shared copy at stop kept REAPER's name. Desktop, rt)
  local safe = name:gsub("[^%w%-_.]", "_")
  local safe_stem = (name:gsub("%.[^.]+$", "")):gsub("[^%w%-_.]", "_")
  return name == base or name == stem or stem:sub(-#safe - 1) == "-" .. safe or (safe_stem ~= "" and stem:sub(-#safe_stem - 1) == "-" .. safe_stem)
end
-- The time an event file's name carries (sync.post's id: <user>-YYYYMMDD-HHMMSSZ-<seq>-<rand>.json), as an ISO string, or nil.
function recap.name_time(f)
  local y, mo, d, h, mi, s = tostring(f):match("(%d%d%d%d)(%d%d)(%d%d)%-(%d%d)(%d%d)(%d%d)Z%-%d+%-%d+%.json$")
  return y and string.format("%s-%s-%sT%s:%s:%sZ", y, mo, d, h, mi, s) or nil
end
local function iso_secs(iso)
  local y, m, d, H, M, S = tostring(iso or ""):match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  return y and os.time({ year = y, month = m, day = d, hour = H, min = M, sec = S, isdst = false }) or nil
end
recap.iso_secs = iso_secs
-- The session in a time-sorted list of events: the trailing run with no gap longer than GAP, after `floor` (the last recap's end). -> first index.
function recap.window(evs, floor)
  local i = #evs
  while i > 1 do
    local a, z = iso_secs(evs[i - 1].time), iso_secs(evs[i].time)
    if not a or not z or z - a > recap.GAP or (floor and evs[i - 1].time <= floor) then break end
    i = i - 1
  end
  if floor and evs[i] and evs[i].time <= floor then i = i + 1 end
  return i
end
local function add_once(list, seen, v) if v and v ~= "" and not seen[v] then seen[v] = true; list[#list + 1] = v end end
local function mmss(p) p = math.max(0, math.floor((p or 0) + 0.5)); return string.format("%d:%02d", p // 60, p % 60) end
-- The recap of a session's events (time-sorted, the window already cut). `o`: { me, peers = { names }, markers (for a take's section),
-- versions = recall.list rows, take_name = function(ev) -> the item's first take name and its file (a new item's event only) }.
function recap.build(evs, o)
  o = o or {}
  local r = { from = evs[1] and evs[1].time, to = evs[#evs] and evs[#evs].time, people = {}, takes = {}, added = {}, removed = {},
    edits = {}, notes = {}, versions = {}, changes = {}, likes = 0, n = #evs }
  local seen_p, seen_t, seen_a, seen_r = {}, {}, {}, {}
  add_once(r.people, seen_p, o.me)
  for _, p in ipairs(o.peers or {}) do add_once(r.people, seen_p, p) end
  local timeline, shifts = 0, 0
  for _, e in ipairs(evs) do
    local kind = e.kind or e.type
    add_once(r.people, seen_p, e.user)
    if kind == "obj" and not e.auto then
      r.changes[e.user] = (r.changes[e.user] or 0) + 1
      local name = (e.name or "") ~= "" and e.name or "an unnamed track"
      if e.obj == "track" then
        if e.gone then add_once(r.removed, seen_r, name)
        elseif (e.rev or 1) == 1 and not e.restored then add_once(r.added, seen_a, name) end
      elseif e.obj == "item" and (e.rev or 1) == 1 and not e.gone and not e.restored and o.take_name then
        local tname, file = o.take_name(e)
        local s, p = recap.parse_name(tname)
        -- (a smart name, or REAPER's own: a recording. A lanes split copies takes already named: counted once, by name)
        if p or (tname and file and recap.is_default_name(tname, file) and tname ~= "") then
          local key = (tname or "") .. "\0" .. name
          if not seen_t[key] then
            seen_t[key] = true
            r.takes[#r.takes + 1] = { user = p or e.user, track = name, section = s or recap.section_at(o.markers, e.pos or 0), name = tname }
          end
        end
      end
    elseif kind == "timeline" then
      timeline = timeline + 1
      local t1 = (e.tempo or {})[1]
      r.tempo = t1 and t1.bpm or r.tempo
      r.marks = #(e.markers or {})
    elseif kind == "shift" then
      shifts = shifts + 1
      r.edits[#r.edits + 1] = string.format("%s %s %.1f s at %s (every track)", e.user, (e.len or 0) > 0 and "inserted" or "removed", math.abs(e.len or 0), mmss(e.at))
    elseif kind == "note" then
      local who = e.client and (tostring(e.client) .. " (client)") or tostring(e.user)
      r.notes[#r.notes + 1] = who .. (e.pos and (" at " .. mmss(e.pos)) or "") .. (e.track and (" on " .. e.track) or "") .. ": " .. tostring(e.text or "")
    elseif kind == "like" then r.likes = r.likes + 1
    elseif kind == "driver" then r.edits[#r.edits + 1] = tostring(e.driver or e.user) .. " took over driving"
    end
  end
  if timeline > 0 then
    table.insert(r.edits, 1, string.format("tempo or markers changed %d time%s (now %s%d marker%s/region%s)", timeline, timeline == 1 and "" or "s",
      r.tempo and string.format("%g bpm, ", r.tempo) or "", r.marks or 0, r.marks == 1 and "" or "s", r.marks == 1 and "" or "s"))
  end
  for _, v in ipairs(o.versions or {}) do
    if r.from and v.time and v.time >= r.from and v.time <= (o.now or r.to or v.time) then
      r.versions[#r.versions + 1] = tostring(v.label) .. (v.by and (" (" .. v.by .. ")") or "")
    end
  end
  local a, z = iso_secs(r.from), iso_secs(r.to)
  r.mins = (a and z) and math.max(1, math.floor((z - a) / 60 + 0.5)) or 0
  table.sort(r.people)
  return r
end
local function plural(n, one, many) return n .. " " .. (n == 1 and one or many) end
local function dur(m) return m >= 60 and string.format("%d h %02d min", m // 60, m % 60) or (m .. " min") end
-- The recap as bullets (no markup), brief and plain.
function recap.lines(r)
  local out = { "Who: " .. (#r.people > 0 and table.concat(r.people, ", ") or "nobody"), "How long: " .. dur(r.mins or 0) }
  if #r.takes == 0 then out[#out + 1] = "Takes: none"
  else
    out[#out + 1] = "Takes: " .. #r.takes
    for _, t in ipairs(r.takes) do out[#out + 1] = "  " .. t.user .. " on " .. t.track .. (t.section and (", " .. t.section) or "") .. (t.name and (" (" .. t.name .. ")") or "") end
  end
  if #r.added > 0 then out[#out + 1] = "Tracks added: " .. table.concat(r.added, ", ") end
  if #r.removed > 0 then out[#out + 1] = "Tracks removed: " .. table.concat(r.removed, ", ") end
  for _, e in ipairs(r.edits) do out[#out + 1] = "Edit: " .. e end
  local who = {}
  for u, n in pairs(r.changes) do who[#who + 1] = u .. " " .. n end
  table.sort(who)
  if #who > 0 then out[#out + 1] = "Changes: " .. table.concat(who, ", ") end
  for _, n in ipairs(r.notes) do out[#out + 1] = "Note: " .. n end
  if r.likes > 0 then out[#out + 1] = "Likes: " .. r.likes end
  for _, v in ipairs(r.versions) do out[#out + 1] = "Saved version: " .. v end
  return out
end
-- One line for the log.
function recap.log_line(r)
  local parts = { plural(#r.takes, "take", "takes") }
  if #r.added > 0 then parts[#parts + 1] = plural(#r.added, "track added", "tracks added") end
  if #r.removed > 0 then parts[#parts + 1] = plural(#r.removed, "track removed", "tracks removed") end
  if #r.notes > 0 then parts[#parts + 1] = plural(#r.notes, "note", "notes") end
  if #r.versions > 0 then parts[#parts + 1] = plural(#r.versions, "saved version", "saved versions") end
  return string.format("last session (%s; %s): %s. Restore > Last session has it", dur(r.mins or 0), table.concat(r.people, ", "), table.concat(parts, ", "))
end
-- The Markdown file for the cloud copy. `when`: the local date and time it's named for.
function recap.markdown(r, song, room, when, by)
  local out = { "# " .. tostring(song) .. (room ~= "main" and (" (" .. tostring(room) .. ")") or "") .. ": session of " .. tostring(when), "" }
  for _, l in ipairs(recap.lines(r)) do
    out[#out + 1] = (l:sub(1, 2) == "  " and "  - " .. l:sub(3)) or ("- " .. l)
  end
  out[#out + 1] = ""
  out[#out + 1] = "_As " .. tostring(by) .. "'s computer saw it (StudioSync)._"
  return table.concat(out, "\n") .. "\n"
end
-- The newest recap among the room's files ({ recaps = { newest first } } each). -> it, or nil.
function recap.newest(files)
  local best
  for _, f in ipairs(files) do
    local r = type(f) == "table" and type(f.recaps) == "table" and f.recaps[1]
    if type(r) == "table" and type(r.to) == "string" and (not best or r.to > best.to) then best = r end
  end
  return best
end

-- ---- REAPER -----------------------------------------------------------------------------------------------------------------------------
local function band() return require("band") end
local function take_file(tk)
  local src = tk and reaper.GetMediaItemTake_Source(tk)
  if src and reaper.GetMediaSourceType(src, "") == "SECTION" then src = reaper.GetMediaSourceParent(src) end
  return src and reaper.GetMediaSourceFileName(src, "") or ""
end
local function take_guid(tk) return select(2, reaper.GetSetMediaItemTakeInfo_String(tk, "GUID", "", false)) end

-- Studio setting (band.json "smart_take_names", on unless false: lib/groups.lua).
function recap.names_on(root) return require("groups").smart_take_names(root) end
-- As a recording starts: the takes already on the armed tracks, so the stop can tell the new ones.
function recap.before_record(proj)
  local had = { [".tracks"] = {} } -- (".tracks": the tracks armed now, as the stop may come after a disarm: REAPER's "disarm after recording",
  -- a quick hand, or a script. Without it the take on a track disarmed before Live sync's next tick kept REAPER's name. Desktop, rt)
  for t = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, t)
    if reaper.GetMediaTrackInfo_Value(tr, "I_RECARM") == 1 then
      had[".tracks"][tr] = true
      for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
        local it = reaper.GetTrackMediaItem(tr, j)
        for k = 0, reaper.CountTakes(it) - 1 do local tk = reaper.GetTake(it, k); if tk then had[take_guid(tk)] = true end end
      end
    end
  end
  return had
end
-- As it stops: each take on an armed track that wasn't there at the start and still has REAPER's name gets its smart name. -> how many.
function recap.name_takes(proj, cfg, had)
  if not had or not recap.names_on(cfg.root) then return 0 end
  local markers = band().capture_markers(proj)
  local names, new = {}, {}
  for t = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, t)
    local armed = (type(had[".tracks"]) == "table" and had[".tracks"][tr]) or reaper.GetMediaTrackInfo_Value(tr, "I_RECARM") == 1
    for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
      local it = reaper.GetTrackMediaItem(tr, j)
      for k = 0, reaper.CountTakes(it) - 1 do
        local tk = reaper.GetTake(it, k)
        if tk then
          local nm = select(2, reaper.GetSetMediaItemTakeInfo_String(tk, "P_NAME", "", false))
          names[#names + 1] = nm
          if armed and not had[take_guid(tk)] and recap.is_default_name(nm, take_file(tk)) then
            new[#new + 1] = { tk = tk, pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION") }
          end
        end
      end
    end
  end
  local pending = {}
  for _, x in ipairs(new) do -- (track order, then each track's items in time order: take 1 is the top track's)
    local section = recap.section_at(markers, x.pos)
    local n = recap.next_n(names, section, cfg.user)
    local name = recap.smart_name(section, cfg.user, n)
    reaper.GetSetMediaItemTakeInfo_String(x.tk, "P_NAME", name, true)
    names[#names + 1] = name
    pending[#pending + 1] = { tk = x.tk, section = section, name = name, pass = recap.smart_name(nil, cfg.user, n) }
  end
  -- (the lanes: now, and again over the next seconds, as takes-to-lanes (lib/prints.lua) moves a new take into a lane of its own after the
  -- stop, which REAPER numbers "3". Desktop, rt)
  recap.pending = #pending > 0 and { list = pending, till = reaper.time_precise() + recap.LANE_WAIT } or recap.pending
  recap.lane_tick(proj)
  return #new
end
recap.LANE_WAIT = 15
-- Smart lanes (James, rt): each fixed lane a new take sits in is named as its take ("Bridge - James - take 3"), or as the pass ("James -
-- take 3") when it holds takes of different sections; only a lane nobody named (empty, REAPER's own "1", "2"... or prints.lua's "Take 3").
-- Lane names travel with the track (mirror). Live sync calls this each tick; it's nothing once the takes have settled (LANE_WAIT after a stop).
local lane_at = -math.huge
function recap.lane_tick(proj)
  local p = recap.pending
  if not p then return end
  local now = reaper.time_precise()
  if now > p.till then recap.pending = nil; return end
  if now - lane_at < 0.25 then return end
  lane_at = now
  local lanes = {}
  for _, x in ipairs(p.list) do
    -- (a take deleted since: its pointer must never be used, REAPER would crash, not raise. ValidatePtr2 first)
    if reaper.ValidatePtr2 and not reaper.ValidatePtr2(proj, x.tk, "MediaItem_Take*") then x.gone = true end
    if not x.gone then
      local it = reaper.GetMediaItemTake_Item(x.tk)
      local tr = it and reaper.GetMediaItem_Track(it)
      if tr and reaper.GetMediaTrackInfo_Value(tr, "I_FREEMODE") == 2 then
        lanes[tr] = lanes[tr] or {}
        local list = lanes[tr]
        list[#list + 1] = { lane = math.floor(reaper.GetMediaItemInfo_Value(it, "I_FIXEDLANE")), section = x.section, name = x.name, pass = x.pass }
      end
    end
  end
  for tr, list in pairs(lanes) do
    for lane, lname in pairs(recap.lane_names(list)) do
      local key = "P_LANENAME:" .. lane
      local cur = select(2, reaper.GetSetMediaTrackInfo_String(tr, key, "", false))
      if cur == "" or cur:match("^%d+$") or cur:match("^Take %d+$") then reaper.GetSetMediaTrackInfo_String(tr, key, lname, true) end
    end
  end
end
-- What each fixed lane this pass recorded into is called: its take's name when it holds one section's take(s), else the pass's name (the
-- first take's, without a section). list: { { lane, section, name, pass } } in record order. -> { [lane] = name }. Pure.
function recap.lane_names(list)
  local by, out = {}, {}
  for _, x in ipairs(list or {}) do
    local l = by[x.lane]
    if not l then by[x.lane] = { name = x.name, pass = x.pass, section = x.section, mixed = false }
    elseif l.section ~= x.section then l.mixed = true end
  end
  for lane, l in pairs(by) do out[lane] = l.mixed and l.pass or l.name end
  return out
end

local function recaps_dir(cfg, song, room) return require("sync").room_dir(cfg, song, room) .. "/recaps" end
local function own_file(cfg, song, room) return recaps_dir(cfg, song, room) .. "/" .. require("sync").id_user(cfg.user) .. ".json" end
-- At the end of a session: works out this computer's recap since its last one, keeps it, logs it, and puts it in the cloud copy. -> it, or nil.
function recap.write(proj, cfg, b)
  local B, sync, recall = band(), require("sync"), require("recall")
  local mine = B.read_json(own_file(cfg, b.song, b.room))
  mine = type(mine) == "table" and type(mine.recaps) == "table" and mine or { recaps = {} }
  local last = mine.recaps[1]
  local now_iso = os.date("!%Y-%m-%dT%H:%M:%SZ")
  local floor = type(last) == "table" and last.to or os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - 86400) -- (a first recap: the last day at most)
  local edir = sync.room_dir(cfg, b.song, b.room) .. "/events"
  local names = {}
  for _, f in ipairs(B.listing(edir, ".json", false)) do
    local t = recap.name_time(f)
    if t and t > floor then names[#names + 1] = { f = f, time = t } end
  end
  table.sort(names, function(a, z) return (a.time .. a.f) < (z.time .. z.f) end)
  -- (bounded: a burst of thousands is read only at its end, REAPER may be closing. shortcut: a longer session's start is cut, raise MAX_READ if it matters)
  local evs = {}
  for i = math.max(1, #names - recap.MAX_READ + 1), #names do
    local ev = recall.event(edir .. "/" .. names[i].f)
    if ev then evs[#evs + 1] = ev end
  end
  table.sort(evs, function(a, z) return (a.time .. a.id) < (z.time .. z.id) end)
  local first = recap.window(evs, floor)
  local sess = {}
  for i = first, #evs do sess[#sess + 1] = evs[i] end
  if #sess == 0 then return nil end
  local peers = {}
  for _, st in ipairs(require("presence").peers(cfg, b.song, b.room) or {}) do peers[#peers + 1] = st.user end
  local r = recap.build(sess, { me = cfg.user, peers = peers, markers = B.capture_markers(proj), now = now_iso,
    versions = recall.list(cfg, b.song, b.room),
    take_name = function(ev)
      local st = ev.state
      if type(st) ~= "string" then return nil end
      local nm = st:match('\nNAME "([^"\n]*)"') or st:match("\nNAME ([^\n]*)")
      return nm, st:match('FILE "([^"]+)"')
    end })
  r.by, r.song, r.room = cfg.user, b.song, b.room
  table.insert(mine.recaps, 1, r)
  while #mine.recaps > recap.KEEP do table.remove(mine.recaps) end
  reaper.RecursiveCreateDirectory(recaps_dir(cfg, b.song, b.room), 0)
  B.write_json(own_file(cfg, b.song, b.room), mine)
  B.log(recap.log_line(r))
  local droot = require("drive").root(cfg)
  if droot then -- (a phone reads the cloud folder: <song>/recaps/<local date time> <user>.md, one writer per file)
    local when = os.date("%Y-%m-%d %H%M")
    local dir = droot .. "/" .. b.song .. "/recaps"
    reaper.RecursiveCreateDirectory(dir, 0)
    local ok, err = pcall(B.write_atomic, dir .. "/" .. when .. " " .. sync.id_user(cfg.user) .. ".md", recap.markdown(r, b.song, b.room, os.date("%Y-%m-%d %H:%M"), cfg.user))
    if not ok then B.log("couldn't put the session recap in the cloud copy: " .. tostring(err)) end
  end
  return r
end

-- The newest recap in the room (anyone's), read at most every 5 s. -> it, or nil.
local seen = { at = -math.huge }
function recap.last(cfg, song, room)
  local dir = recaps_dir(cfg, song, room)
  if seen.dir == dir and reaper.time_precise() - seen.at < 5 then return seen.r end
  local files = {}
  for _, f in ipairs(band().files(dir, ".json")) do files[#files + 1] = band().read_json(dir .. "/" .. f) end
  seen.dir, seen.at, seen.r = dir, reaper.time_precise(), recap.newest(files)
  return seen.r
end
-- The Restore page's "Last session": the bullets, folded.
function recap.section(ctx, ImGui, cfg, b, local_time)
  local r = recap.last(cfg, b.song, b.room)
  if not r then return end
  if ImGui.CollapsingHeader(ctx, "Last session: " .. local_time(r.from) .. " (as " .. tostring(r.by) .. " saw it)##lastsession") then
    for _, l in ipairs(recap.lines(r)) do
      if l:sub(1, 2) == "  " then ImGui.Indent(ctx); ImGui.TextWrapped(ctx, l:sub(3)); ImGui.Unindent(ctx) else ImGui.Bullet(ctx); ImGui.TextWrapped(ctx, l) end
    end
  end
end
-- Settings > Studio: "Smart take names" (band.json "smart_take_names", on unless false). `may`: owner or admin.
function recap.names_ui(ctx, ImGui, cfg, may)
  ImGui.SeparatorText(ctx, "Smart take and lane names")
  local on = recap.names_on(cfg.root)
  ImGui.TextDisabled(ctx, on and "On: a new take is named for the section under its start and who played it, \"Bridge - James - take 3\", and so is the lane it lands in (takes to lanes). A name someone typed is never changed."
    or "Off: takes keep the names REAPER gives them.")
  if may then
    local ch, v = ImGui.Checkbox(ctx, "Smart take names##studiotakenames", on)
    if ch then
      require("groups").set_smart_take_names(cfg.root, v)
      band().log(v and "new takes are named for their section and player again (Settings > Studio)" or "new takes keep REAPER's names from now on (Settings > Studio)")
    end
    ImGui.SetItemTooltip(ctx, "Owner and admins. Sections come from the song's regions, else its markers.")
  end
end

return recap
