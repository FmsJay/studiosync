-- The web UI's Sheet and Beat pages (docs/realtime-roadmap.md "What the web UI makes possible": Song sheet, Synced visuals; the pages are
-- lib/webui/sheet.js and visuals.js, the tick lib/webui.lua). Topics, built only while a page shows one of them (it says so every 10 s, as the
-- Project page does) and published only when they change:
--   sheet    the project's sections (its regions, in order, then any added by hand) with lyrics and chords ("[C]" inline, ChordPro's way),
--            who plays what, who edited each last and when, and other people's versions of a section that lost to a later edit
--   beatmap  every beat's time by the project's own tempo map (ramps and time signatures as REAPER has them), each bar's number, the regions:
--            a page works out bar.beat for any position itself, so only the position below has to move
--   beat     where the song is: its position at a moment on this computer's link clock (StudioSync_DirectNow, which a page measures itself
--            against through GET /api/time, as the Record page does), playing or not and at what rate, a start that's due and its count-in
--
-- In time: the position goes as a line (pos at `at`, moving at `rate`) fitted to the readings of this playing stretch (the median of pos - t *
-- rate over the last few ticks, phonerec's way: one late tick moves nothing), sent again only when it moves by more than MOVED. Each page draws
-- the beat from its own clock, so a page shows its computer's REAPER within the clock's error (half a round trip to it: about a millisecond
-- here, a few on Tailscale) plus a frame; every computer started together at the same moment on the studio's shared clock (lib/together.lua),
-- so every page in the studio shows the same beat within a few ms.
--
-- The sheet is files: <project>/sheet/<user>.json, one per person, written only by them (no two people ever write the same file, so
-- Syncthing never conflicts, as the chat's files), each holding that person's latest version of every section they edited, stamped with the
-- shared clock. Merged per section, the latest stamp wins: a section is a few lines one person usually has in hand, so last-writer-wins on
-- the section, never the whole sheet, loses nothing anyone sees as theirs; and the version that lost is still in its writer's file, shown
-- under the section with who wrote it, one press from being taken back. An edit also goes to those here at once over the direct link and
-- shows until its file arrives. (James, rt)
local band = require("band")
local songsheet = {}
songsheet.WANT_FOR = 30     -- seconds a page's "I'm showing the sheet or the beat" lasts (pages say it every 10 s)
songsheet.READ_EVERY = 2    -- seconds between reading the sheet's files while a page shows them
songsheet.LOOK_EVERY = 0.5  -- seconds between looks at REAPER's change count (tempo map, regions)
songsheet.FLOOR = 10        -- a whole look at least this often
songsheet.MEDIAN_OF = 15    -- readings the play position's line is fitted to
songsheet.MOVED = 0.003     -- seconds the fitted position may move before it goes again
songsheet.NAME_MAX, songsheet.TEXT_MAX, songsheet.PLAYS_MAX = 80, 20000, 2000
songsheet.MAX_BEATS = 6000  -- beats in the map (about 50 minutes at 120): past it a page goes on at the last bar's spacing
songsheet.ALTS = 3          -- other people's versions shown under a section

local S
function songsheet.reset() S = { want = -math.huge, look_at = -math.huge, full_at = -math.huge, sheet_at = -math.huge, readings = {}, live = {} } end
songsheet.reset()

-- ---- pure ------------------------------------------------------------------------------------------------------------------------------
function songsheet.file_name(user) return (tostring(user):gsub("[^%w%-_]", "_")) .. ".json" end
local function r3(x) return math.floor((tonumber(x) or 0) * 1000 + 0.5) / 1000 end
-- Text from a page or a bandmate's file: control characters other than newlines and tabs gone, ends of lines kept. nil when it isn't
-- text or is over max bytes.
local function text(v, max)
  if v == nil then return "" end
  if type(v) ~= "string" or #v > max or not utf8.len(v) then return nil end
  return (v:gsub("\r\n?", "\n"):gsub("[%z\1-\8\11-\31\127]", ""))
end
-- A section id: "r:<region name>:<n>" (the nth region of that name) or "h:<letters and digits>" (added by hand). Only ever a key, never a path.
function songsheet.id_ok(id)
  return type(id) == "string" and #id <= 120 and not id:find("[%c]") and (id:match("^r:.+:%d+$") or id:match("^h:[%w]+$")) ~= nil
end
-- A section's edit from a page: { id, name, text, plays, bar, ord, del }. -> the version to keep (without by/at), or nil and why.
function songsheet.clean(set)
  if type(set) ~= "table" or not songsheet.id_ok(set.id) then return nil, "not a section" end
  local name, body, plays = text(set.name, songsheet.NAME_MAX), text(set.text, songsheet.TEXT_MAX), text(set.plays, songsheet.PLAYS_MAX)
  if not (name and body and plays) then return nil, "too long, or not text" end
  local bar, ord = tonumber(set.bar), tonumber(set.ord)
  return { name = name:gsub("\n", " "), text = body, plays = plays, bar = bar and bar == bar and math.floor(math.max(-9999, math.min(9999, bar))) or nil,
    ord = ord and ord == ord and math.max(-1e6, math.min(1e6, ord)) or nil, del = set.del == true or nil }
end
-- regions: { { name, pos, rend } } in order -> each with its id (the nth of its name: two Choruses are r:Chorus:1 and r:Chorus:2).
function songsheet.region_ids(regions)
  local n = {}
  for _, r in ipairs(regions or {}) do
    n[r.name] = (n[r.name] or 0) + 1
    r.id = "r:" .. r.name .. ":" .. n[r.name]
  end
  return regions or {}
end
-- files: user -> their file's table ({ sections = { id -> version } }); live: user -> { id -> version } (sent over the link, not yet in a file);
-- regions: region_ids'. Each version: { name, text, plays, bar, ord, del, at (shared clock), by }. -> { sections = { { id, name, region,
-- pos, rend, bar, ord, text, plays, by, at, alts = { { by, at, text, plays } } } } }: the regions in order (an empty one too), then the sections
-- added by hand or whose region has gone, by start bar, then ord. Pure.
function songsheet.merge(files, live, regions)
  local best = {} -- id -> { winner, all versions }
  local function take(user, id, v)
    if type(v) ~= "table" or not songsheet.id_ok(id) or not tonumber(v.at) then return end
    v = { name = type(v.name) == "string" and v.name or "", text = type(v.text) == "string" and v.text or "", plays = type(v.plays) == "string" and v.plays or "",
      bar = tonumber(v.bar), ord = tonumber(v.ord), del = v.del == true or nil, at = tonumber(v.at), by = user }
    local e = best[id] or { per = {} }
    best[id] = e
    local had = e.per[user]
    if not had or v.at > had.at then e.per[user] = v end -- (a person's link copy and file copy: the newer)
  end
  for user, f in pairs(files or {}) do
    if type(f) == "table" and type(f.sections) == "table" then for id, v in pairs(f.sections) do take(user, id, v) end end
  end
  for user, l in pairs(live or {}) do for id, v in pairs(l) do take(user, id, v) end end
  local function out(id, region)
    local e = best[id]
    local vs = {}
    for _, v in pairs(e and e.per or {}) do vs[#vs + 1] = v end
    table.sort(vs, function(a, z) if a.at ~= z.at then return a.at > z.at end return a.by < z.by end)
    local w = vs[1] or {}
    local s = { id = id, name = region and region.name or w.name or "", region = region and true or nil, pos = region and r3(region.pos) or nil,
      rend = region and r3(region.rend) or nil, bar = not region and w.bar or nil, ord = w.ord, text = w.text or "", plays = w.plays or "",
      by = w.by, at = w.at, del = w.del, alts = {} }
    for i = 2, #vs do
      local v = vs[i]
      if #s.alts < songsheet.ALTS and not v.del and (v.text ~= s.text or v.plays ~= s.plays) and (v.text ~= "" or v.plays ~= "") then
        s.alts[#s.alts + 1] = { by = v.by, at = v.at, text = v.text, plays = v.plays }
      end
    end
    return s
  end
  local sections, used = {}, {}
  for _, r in ipairs(regions or {}) do
    local s = out(r.id, r)
    s.del = nil -- (a region's section can be emptied, not deleted: it's the region's)
    sections[#sections + 1], used[r.id] = s, true
  end
  local rest = {}
  for id in pairs(best) do
    if not used[id] then
      local s = out(id)
      -- (a region that's gone, or renamed: its words stay, as a section of its own, until someone deletes it)
      if not s.del and (id:sub(1, 2) == "h:" or s.text ~= "" or s.plays ~= "") then
        if id:sub(1, 2) == "r:" and s.name == "" then s.name = id:match("^r:(.+):%d+$") end
        rest[#rest + 1] = s
      end
    end
  end
  table.sort(rest, function(a, z) -- (by the bar each starts at, those with one; then in the order they were added)
    local x, y = a.bar or math.huge, z.bar or math.huge
    if x ~= y then return x < y end
    x, y = a.ord or math.huge, z.ord or math.huge
    if x ~= y then return x < y end
    return (a.at or 0) < (z.at or 0)
  end)
  for _, s in ipairs(rest) do s.del = nil; sections[#sections + 1] = s end
  for _, s in ipairs(sections) do if #s.alts == 0 then s.alts = nil end end
  return { sections = sections }
end
-- A bandmate's edit over the link: { song, user, id, v }. -> the user, id and version to show until their file has it, or nil.
function songsheet.live_ok(d, me)
  if type(d) ~= "table" or type(d.song) ~= "string" or type(d.user) ~= "string" or d.user == "" or d.user == me or not songsheet.id_ok(d.id) or type(d.v) ~= "table" then return nil end
  local v = songsheet.clean({ id = d.id, name = d.v.name, text = d.v.text, plays = d.v.plays, bar = d.v.bar, ord = d.v.ord, del = d.v.del })
  if not v or not tonumber(d.v.at) then return nil end
  v.at = tonumber(d.v.at)
  return d.user, d.id, v
end
-- The play position's line from phonerec's readings ({ { t, pos, rate, seg } }, broken when stopped): the median of pos - t * rate over the
-- newest stretch's last n readings. -> pos at t (the newest reading's), rate; nil when not playing. Pure.
function songsheet.fit(list, n)
  local last = list[#list]
  if not last or list.broken then return nil end
  local cs = {}
  for i = #list, math.max(1, #list - (n or songsheet.MEDIAN_OF) + 1), -1 do
    local r = list[i]
    if r.seg ~= last.seg then break end
    cs[#cs + 1] = r.pos - r.t * r.rate
  end
  table.sort(cs)
  local c = #cs % 2 == 1 and cs[(#cs + 1) // 2] or (cs[#cs // 2] + cs[#cs // 2 + 1]) / 2
  return c + last.t * last.rate, last.rate
end

-- ---- reading REAPER --------------------------------------------------------------------------------------------------------------------
-- The project's regions in order, StudioSync's own marks (claims, pings) left out: { { name, pos, rend } }, an unnamed one "Region <n>".
function songsheet.read_regions(proj)
  local out, i = {}, 0
  while true do
    local n, rgn, pos, rend, name = reaper.EnumProjectMarkers3(proj, i)
    if n == 0 then break end
    if rgn and not band.is_local_mark(name) then out[#out + 1] = { name = name, pos = pos, rend = rend } end
    i = i + 1
  end
  table.sort(out, function(a, z) return a.pos < z.pos end)
  for k, r in ipairs(out) do if r.name == "" then r.name = "Region " .. k end end
  return songsheet.region_ids(out)
end
-- Every beat to the project's end and a minute on: b = { time }, bars = { { first beat's index (0-based), bar number as REAPER shows it,
-- beats in it } }. By REAPER's own map (QN to time), so ramps and time signature changes land where REAPER plays them.
function songsheet.read_beatmap(proj, regions)
  local b, bars = {}, {}
  local stop = math.max(reaper.GetProjectLength(proj), 1) + 60
  for m = 0, 100000 do
    local t, qn, _, num, den = reaper.TimeMap_GetMeasureInfo(proj, m)
    if t > stop or #b + num > songsheet.MAX_BEATS then break end
    bars[#bars + 1] = { #b, tonumber(reaper.format_timestr_pos(t, "", 2):match("^(-?%d+)")) or (m + 1), num }
    for k = 0, num - 1 do b[#b + 1] = r3(k == 0 and t or reaper.TimeMap2_QNToTime(proj, qn + k * 4 / den)) end
  end
  local rg = {}
  for i, r in ipairs(regions or {}) do rg[i] = { id = r.id, name = r.name, pos = r3(r.pos), rend = r3(r.rend) } end
  return { b = b, bars = bars, regions = rg }
end
local function files_of(cfg, b)
  local dir, out = band.song_dir(cfg, b.song) .. "/sheet", {}
  for _, f in ipairs(band.files(dir, ".json")) do
    local t = band.read_json(dir .. "/" .. f)
    if type(t) == "table" and type(t.user) == "string" and songsheet.file_name(t.user) == f then out[t.user] = t end -- (a file says whose it is: its name agrees)
  end
  return out, dir
end
local function shared_now() return require("together").start_at(0) or require("together").now() end

-- ---- what the pages send and the link brings ---------------------------------------------------------------------------------------------
-- a: { topic = "sheet", want } or { topic = "sheet", set = { id, name, text, plays, bar, ord, del } }. -> words for the log, or nil.
function songsheet.action(proj, cfg, b, a)
  local now = reaper.time_precise()
  if a.want then S.want = now + songsheet.WANT_FOR end
  if a.set == nil then return end
  local v, why = songsheet.clean(a.set)
  if not v then return "the web page's sheet edit was left out: " .. why end
  local files, dir = files_of(cfg, b)
  local mine = files[cfg.user] or { user = cfg.user, sections = {} }
  if type(mine.sections) ~= "table" then mine.sections = {} end
  v.at = shared_now()
  local id = a.set.id
  mine.sections[id], mine.user, mine.v = v, cfg.user, 1
  reaper.RecursiveCreateDirectory(dir, 0)
  band.write_json(dir .. "/" .. songsheet.file_name(cfg.user), mine)
  S.sheet_at = -math.huge
  -- (to those here at once over the direct link; the file is the record. shortcut: a section over the link's 64 KB doesn't go live, its file still does)
  require("direct").send_live(cfg, "sheet", { song = b.song, user = cfg.user, id = id, v = v }, b.song, b.room or "main", cfg.user .. "\0" .. id .. "\0" .. v.at)
end
function songsheet.from_msg(cfg, d)
  local user, id, v = songsheet.live_ok(d, cfg.user)
  if not user then return false end
  S.live[d.song] = S.live[d.song] or {}
  local l = S.live[d.song]
  l[user] = l[user] or {}
  l[user][id] = v
  S.sheet_at = -math.huge
  return true
end

-- Each tick in front while a page looks (lib/webui.lua). publish(topic, table) sends only what changed.
function songsheet.tick(proj, cfg, b, publish, handlers, now)
  if type(handlers) == "table" and not handlers.sheet then handlers.sheet = function(d) songsheet.from_msg(cfg, d) end end
  if S.want <= now then return end
  if now - S.look_at >= songsheet.LOOK_EVERY then
    S.look_at = now
    local cc = reaper.GetProjectStateChangeCount(proj)
    if cc ~= S.cc or proj ~= S.proj or now - S.full_at >= songsheet.FLOOR then
      if proj ~= S.proj then S.readings = {} end
      S.cc, S.proj, S.full_at = cc, proj, now
      S.regions = songsheet.read_regions(proj)
      publish("beatmap", songsheet.read_beatmap(proj, S.regions))
      S.sheet_at = -math.huge
    end
  end
  if now - S.sheet_at >= songsheet.READ_EVERY then
    S.sheet_at = now
    local files = files_of(cfg, b)
    local live = S.live[b.song] or {}
    for user, l in pairs(live) do -- (a link copy goes once its file has caught up)
      for id, v in pairs(l) do
        local f = files[user] and type(files[user].sections) == "table" and files[user].sections[id]
        if type(f) == "table" and (tonumber(f.at) or 0) >= v.at then l[id] = nil end
      end
    end
    local m = songsheet.merge(files, live, S.regions)
    m.me = cfg.user
    publish("sheet", m)
  end
  if not reaper.StudioSync_DirectNow then publish("beat", { noclock = true }); return end
  local ps = reaper.GetPlayStateEx(proj)
  local playing = ps & 1 == 1
  local t = reaper.StudioSync_DirectNow()
  local pos = playing and reaper.GetPlayPositionEx(proj) or reaper.GetCursorPositionEx(proj)
  local rate = reaper.Master_GetPlayRate(proj)
  local phonerec = require("phonerec")
  phonerec.add_reading(S.readings, t, pos, rate, playing)
  if #S.readings > 200 then phonerec.prune(S.readings, t, 5) end
  local fpos, frate = songsheet.fit(S.readings)
  local was = S.line
  if fpos then
    -- (the same line moved on to now: sent again only when it's moved off it, or it's a new stretch)
    if not (was and was.playing and was.rate == frate and math.abs(was.pos + (t - was.at) * was.rate - fpos) <= songsheet.MOVED) then
      S.line = { playing = true, pos = fpos, at = t, rate = frate }
    end
  elseif not (was and not was.playing and math.abs(was.pos - pos) < 1e-4) then S.line = { playing = false, pos = pos, at = t, rate = rate } end
  local key = tostring(proj)
  local together = require("together")
  local tnow = together.now()
  -- (a start's moment, in together.now()'s terms, put on the link clock once when it changes: worked out again each tick it moved by
  -- microseconds and went out every tick)
  local raw = reaper.GetExtState(band.SECTION, "together_at " .. key) .. "\t" .. reaper.GetExtState(band.SECTION, "together_from " .. key)
  if raw ~= S.start_raw then
    local due = tonumber(raw:match("^([^\t]*)"))
    local cto, clen, cfire = raw:match("\t(%S+) (%S+) (%S+)$")
    S.start_raw, S.due = raw, due and t + (due - tnow) or nil
    S.cin = tonumber(clen) and tonumber(clen) > 0 and tonumber(cfire) and { to = r3(cto), len = r3(clen), fire = t + (tonumber(cfire) - tnow) } or nil
  end
  local L = S.line
  publish("beat", { playing = L.playing or nil, rec = ps & 4 == 4 or nil, pos = math.floor(L.pos * 1e4 + 0.5) / 1e4, at = L.at, rate = L.rate,
    due = S.due and S.due > t and S.due or nil, cin = S.cin, jam = require("jam").beat_info() }) -- (jam: its interval in bars and who's heard. rt-jam)
end

return songsheet
