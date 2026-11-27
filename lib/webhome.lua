-- The web UI's Home page for the studio (James: "see what projects were worked on last and by who with time stamps and notifications for
-- messages"; the page is lib/webui/home.js, the server extension/webui.cpp, the tick lib/webui.lua). Everything comes from what the studio's
-- folder already holds; nothing new is tracked:
--   projects   band.songs, each with who changed it last, when and what (the newest change in each room's events, as History names it:
--              recall.describe), its stage (extras.stage) and who's in it now (each room's status files, as rooms.people reads them)
--   takes      new recordings among each room's newest changes (an added item still carrying a recording's name: recap.lua's rule)
--   bounces    mixes (<song>/mixes, named "<song> <date> <time> <user>") and stems (<song>/stems/<date> <time> <user>)
--   for you    the panel's unread count for this project (page_chat.unread), mentions of you (@name, @display name, @everyone) and to-dos that
--              name you, from the studio's chat (page_chat.read "band", the Chat page's own store and reader)
--   last session  this room's newest recap (lib/recap.lua)
-- Built every EVERY s, only while a page shows Home (it says so every 10 s), published only when it changed. Opening a project goes the way the
-- panel's Projects page does (ExtState "open project", then the Open session action), or switches to its tab when it's open here already.
-- Everyone's profile (lib/profile.lua) is the "profiles" topic, built while any page looks: presence, chat and Home all show it. (James, rt)
local band = require("band")
local webhome = {}
webhome.WANT_FOR = 30     -- seconds a page's "I'm on Home" lasts (pages say it every 10 s)
webhome.EVERY = 10        -- seconds between Home builds
webhome.CHAT_EVERY = 15   -- seconds between reading the studio's chat (every project's) for mentions and to-dos
webhome.OTHER_EVERY = 60  -- seconds between listing another room's changes (this room's: every build)
webhome.SCAN = 40         -- newest changes looked at per room
webhome.RECENT = 8        -- takes, bounces, mentions and messages shown
webhome.DAYS = 14         -- mentions this recent
webhome.FRESH = 45        -- seconds a status counts as online (rooms.people's rule)
webhome.PROJECTS = 60     -- projects listed
webhome.TEXT = 300        -- characters of a message shown
webhome.EVERYONE = { "everyone", "all" } -- (@everyone and @all mention every member: page_chat.EVERYONE)
webhome.CHAT_MSGS, webhome.CHAT_TODOS = 150, 80 -- the studio's newest messages and to-dos read for Home (page_chat.newest: not the whole chat)
webhome.SINCE_MAX = 40   -- projects a page may name in "since you were last here"

local S = { want = -math.huge, at = -math.huge, chat_at = -math.huge, chat = nil, prof_at = -math.huge, reply = nil }
local function scripts_dir() return debug.getinfo(1, "S").source:match("^@?(.*)[/\\]lib[/\\][^/\\]+$") or "." end

-- ---- pure ------------------------------------------------------------------------------------------------------------------------------
-- The compact UTC stamp an event file's name carries (sync.post's id: <user>-YYYYMMDD-HHMMSSZ-<seq>-<rand>.json): "YYYYMMDD-HHMMSS", or nil.
-- (Fixed places from the end first, a pattern only when the sequence number has more than 5 digits: a big room has 20,000 names.)
function webhome.stamp_of(f)
  if #f > 33 and f:byte(-17) == 90 and f:byte(-24) == 45 then -- ("Z" after the time, "-" between date and time)
    local s = f:sub(-32, -18)
    if s:match("^%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d$") then return s end
  end
  local d, t = f:match("(%d%d%d%d%d%d%d%d)%-(%d%d%d%d%d%d)Z%-%d+%-%d+%.json$")
  return d and (d .. "-" .. t) or nil
end
function webhome.iso(stamp)
  local y, mo, d, h, mi, s = tostring(stamp):match("^(%d%d%d%d)(%d%d)(%d%d)%-(%d%d)(%d%d)(%d%d)$")
  return y and string.format("%s-%s-%sT%s:%s:%sZ", y, mo, d, h, mi, s) or nil
end
-- The newest k of `names` by time_of(name) (comparable strings; nil: skipped), newest first: { { f, time } }. Pure.
function webhome.newest(names, k, time_of)
  local out = {}
  for _, f in ipairs(names) do
    local t = time_of(f)
    if t and (#out < k or t > out[#out].time) then
      local i = #out + 1
      while i > 1 and out[i - 1].time < t do i = i - 1 end
      table.insert(out, i, { f = f, time = t })
      if #out > k then out[#out] = nil end
    end
  end
  return out
end
-- A local date and time (as file names made here carry them) -> ISO UTC. Pure but for the time zone.
local function utc(y, mo, d, h, mi, s)
  local t = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = tonumber(h), min = tonumber(mi), sec = tonumber(s) or 0 })
  return t and os.date("!%Y-%m-%dT%H:%M:%SZ", t) or nil
end
webhome.AUDIO = { wav = true, flac = true, mp3 = true, ogg = true, m4a = true, aif = true, aiff = true }
-- JS_File_Stat's modified time ("YYYY-MM-DD hh:mm:ss", this computer's own clock) -> ISO UTC, or nil. Pure but for the time zone.
function webhome.stat_utc(mt)
  local y, mo, d, h, mi, s = tostring(mt or ""):match("^(%d%d%d%d)%D(%d%d)%D(%d%d)%D+(%d%d)%D(%d%d)%D(%d%d)")
  if not y or tonumber(y) < 2000 then return nil end -- (a zeroed FILETIME is 1601)
  local ok, t = pcall(utc, y, mo, d, h, mi, s)
  return ok and t or nil
end
-- A mix's file name ("<song> YYYY-MM-DD HHMMSS <user>.<audio>": Final mix and Render mix) -> { name, user, time }, or nil.
-- The name's time is the renderer's own clock, in their time zone; the file's modified time (mtime: JS_File_Stat's, kept by the shared folder's
-- sync) is the same moment in everyone's, so it wins when it's there. (Home showed a bandmate's mix hours off in another zone. rt-p5)
function webhome.mix_of(f, mtime)
  local ext = tostring(f):match("%.([^.]+)$")
  if not ext or not webhome.AUDIO[ext:lower()] or f:sub(1, 1) == "." then return nil end
  local y, mo, d, h, mi, s, user = f:match("(%d%d%d%d)%-(%d%d)%-(%d%d) (%d%d)(%d%d)(%d%d) (.-)%.[^.]+$")
  if not y then return nil end
  return { name = f, user = user ~= "" and user or nil, time = webhome.stat_utc(mtime) or utc(y, mo, d, h, mi, s) }
end
-- A stems folder's name ("YYYY-MM-DD HHMM <user>": Render stems) -> { name, user, time }, or nil.
function webhome.stems_of(dir, mtime)
  local y, mo, d, h, mi, user = tostring(dir):match("^(%d%d%d%d)%-(%d%d)%-(%d%d) (%d%d)(%d%d) (.+)$")
  if not y then return nil end
  return { name = dir, user = user, time = webhome.stat_utc(mtime) or utc(y, mo, d, h, mi, 0) }
end
-- Does this text mention any of `names` ("@James", case aside, not "@Jameson")? The chat's own rule, so Home and the chat agree. Pure.
function webhome.mentions(text, names) return require("page_chat").mentions(text, names) end
local function short(s, n)
  s = tostring(s or "")
  local len = utf8.len(s)
  if len and len > n then return s:sub(1, utf8.offset(s, n + 1) - 1) .. "…" end
  return s
end
local function id_of(m) return type(m.file) == "string" and m.file:match("([^/\\]+)%.json$") or nil end
-- The chat's parts of Home, from page_chat.read's { msgs, todo } for the studio (each oldest first, with where in words). me: your user name;
-- names: what mentions you (your user name, display name, @everyone); now: os.time(). -> { mentions, todos, recent }, newest first. Pure.
function webhome.chat_model(t, me, names, now)
  local out = { mentions = {}, todos = {}, recent = {} }
  local floor = os.date("!%Y-%m-%dT%H:%M:%SZ", now - webhome.DAYS * 86400)
  local msgs = type(t) == "table" and type(t.msgs) == "table" and t.msgs or {}
  for i = #msgs, 1, -1 do
    local m = msgs[i]
    if type(m) == "table" and type(m.text) == "string" and m.user ~= me then
      local e = { id = id_of(m), user = tostring(m.user or "?"), time = type(m.time) == "string" and m.time or nil, where = type(m.where) == "string" and m.where or nil,
        text = short(m.text, webhome.TEXT) }
      if #out.recent < webhome.RECENT then out.recent[#out.recent + 1] = e end
      if #out.mentions < webhome.RECENT and (e.time or "") >= floor and webhome.mentions(m.text, names) then out.mentions[#out.mentions + 1] = e end
    end
  end
  local todo = type(t) == "table" and type(t.todo) == "table" and t.todo or {}
  for i = #todo, 1, -1 do
    local d = todo[i]
    if type(d) == "table" and type(d.text) == "string" and not d.done and (d["for"] == me or webhome.mentions(d.text, names)) and #out.todos < webhome.RECENT * 2 then
      out.todos[#out.todos + 1] = { id = id_of(d), user = tostring(d.user or "?"), time = type(d.time) == "string" and d.time or nil,
        where = type(d.where) == "string" and d.where or nil, text = short(d.text, webhome.TEXT) }
    end
  end
  return out
end
-- An event as a take, when it is one: an added item (its first revision, not brought back, not automatic) whose take still carries a
-- recording's name (a smart name, or REAPER's own: recap.lua's rule). name_of(ev) -> the take's name and file. -> { user, track, name } or nil.
function webhome.take_of(ev, name_of)
  if type(ev) ~= "table" or (ev.kind or ev.type) ~= "obj" or ev.obj ~= "item" or (ev.rev or 1) ~= 1 or ev.gone or ev.restored or ev.auto then return nil end
  local recap = require("recap")
  local name, file = name_of(ev)
  local _, player = recap.parse_name(name)
  if not (player or (name and file and name ~= "" and recap.is_default_name(name, file))) then return nil end
  return { user = player or ev.user, track = (ev.name or "") ~= "" and ev.name or nil, name = name }
end

-- ---- reading the studio's folder -------------------------------------------------------------------------------------------------------
local mtimes = {} -- path -> its modified time as JS_File_Stat says it ("" when it can't), kept: a mix or a stems folder doesn't change after it's made
function webhome.mtime(path)
  local m = mtimes[path]
  if m == nil then
    m = ""
    if reaper.JS_File_Stat then
      local ok, status, _, _, modified = pcall(reaper.JS_File_Stat, path)
      if ok and status == 0 and modified then m = tostring(modified) end
    end
    local n = 0
    for _ in pairs(mtimes) do n = n + 1 end
    if n >= 2000 then mtimes = {} end
    mtimes[path] = m
  end
  return m ~= "" and m or nil
end
local scans = {} -- events folder -> { at, n, top = webhome.newest's }
local takes_memo = {} -- event path -> its take, or false
local function take_name(ev)
  local st = ev.state -- (read from its file again: recall's cache keeps events without their state)
  if type(st) ~= "string" then return nil end
  return st:match('\nNAME "([^"\n]*)"') or st:match("\nNAME ([^\n]*)"), st:match('FILE "([^"]+)"')
end
-- A room's newest changes: who changed it last, when and what, its new takes and (the third value) each change by anyone: { { user, time } }, for
-- "since you were last here". Another room's folder is listed at most every OTHER_EVERY s.
local function room_news(cfg, song, room, here, now)
  local edir = band.song_dir(cfg, song) .. "/rooms/" .. room .. "/events"
  local c = scans[edir]
  if not c or (now - c.at >= (here and webhome.EVERY or webhome.OTHER_EVERY) - 0.5) then
    local list = band.listing(edir, ".json", false)
    -- shortcut: the same number of names counts as unchanged (a trim and a new change in one look aren't seen until the next change)
    if not (c and c.n == #list) then c = { n = #list, top = webhome.newest(list, webhome.SCAN, webhome.stamp_of) } end
    c.at = now
    scans[edir] = c
  end
  local recall, last, takes, changes = require("recall"), nil, {}, {}
  for _, x in ipairs(c.top) do
    local path = edir .. "/" .. x.f
    local ev = recall.event(path)
    if ev then
      if not ev.auto and type(ev.user) == "string" then changes[#changes + 1] = { user = ev.user, time = webhome.iso(x.time) } end
      if not last and not ev.auto and type(ev.user) == "string" then
        local ok, what = pcall(recall.describe, ev)
        last = { user = ev.user, time = webhome.iso(x.time), what = ok and short(what, 120) or nil, room = room }
      end
      if takes_memo[path] == nil then takes_memo[path] = webhome.take_of(ev, take_name) or false end
      local t = takes_memo[path]
      if t then takes[#takes + 1] = { user = t.user, track = t.track, name = t.name, song = song, room = room, time = webhome.iso(x.time) } end
    end
  end
  return last, takes, changes
end
-- Is a status still fresh? e: { at = when this computer first saw its stamp (time_precise), changed = it saw the stamp change }; age: the stamp's
-- age by this computer's clock. Gone FRESH s after its last change here, whatever the writer's clock says (presence.peers' rule): one whose
-- clock ran ahead stayed online on Home for as long as it was ahead after they closed the project. Pure. (rt-people)
function webhome.fresh(e, age, now)
  return now - e.at < webhome.FRESH and (age < webhome.FRESH or e.changed == true)
end
local stamps, stamps_n = {}, 0 -- song/room/user -> { time, at, changed }
-- Who's in a room now (rooms.people's rule, with what they're doing): { { user, rec, play, away } }, you left out.
-- (each one's status line, "back at 8", comes from the profiles topic: lib/profile.lua)
local function room_people(cfg, song, room, now)
  local dir, sts = band.song_dir(cfg, song) .. "/rooms/" .. room .. "/status", {}
  for _, f in ipairs(band.files(dir, ".json")) do
    local st = band.read_json(dir .. "/" .. f)
    if type(st) == "table" and type(st.user) == "string" then sts[#sts + 1] = st end
  end
  local presence, out = require("presence"), {}
  for _, st in ipairs(presence.with_live(sts, presence.live(cfg, song, room))) do
    local fresh = false
    if st.user ~= cfg.user and type(st.time) == "string" then
      local k = song .. "/" .. room .. "/" .. st.user
      local e = stamps[k]
      if not e or e.time ~= st.time then
        if stamps_n >= 4000 then stamps, stamps_n = {}, 0 end
        if not e then stamps_n = stamps_n + 1 end
        e = { time = st.time, at = now, changed = e ~= nil }
        stamps[k] = e
      end
      fresh = webhome.fresh(e, band.age(st.time), now)
    end
    if fresh then
      out[#out + 1] = { user = st.user, rec = st.recording == true or nil, play = st.playing == true or nil, away = st.front == false or nil }
    end
  end
  table.sort(out, function(a, z) return a.user < z.user end)
  return out
end
local function newer(a, z) return (a.time or "") > (z.time or "") end
-- One entry per person (James's findings 2026-11-27: Online now showed someone once per project and room they had open, and each of a person's
-- computers apart). list: { { user, song, room, me, rec, play, away } }; key_of(user) -> their person (lib/persons.lua). The entry shown is their
-- most telling place (yours: this computer's first; then recording, playing, in front, in your project); every place is in `devices` when
-- there's more than one. rec and play: anywhere; away: everywhere; me: any of them yours. Pure. (rt-people)
function webhome.fold(list, key_of, here_song)
  local function rank(x)
    return (x.me and 0 or 8) + (x.rec and 0 or 4) + (x.play and 0 or 2) + (x.away and 1 or 0) + (x.song == here_song and 0 or 0.5)
  end
  local groups, order = {}, {}
  for _, x in ipairs(list) do
    local k = key_of(x.user)
    if not groups[k] then groups[k] = {}; order[#order + 1] = k end
    table.insert(groups[k], x)
  end
  local out = {}
  for _, k in ipairs(order) do
    local g = groups[k]
    table.sort(g, function(a, z)
      local ra, rz = rank(a), rank(z)
      if ra ~= rz then return ra < rz end
      return (a.user .. "\0" .. tostring(a.song) .. "\0" .. tostring(a.room)) < (z.user .. "\0" .. tostring(z.song) .. "\0" .. tostring(z.room))
    end)
    local e = {}
    for kk, v in pairs(g[1]) do e[kk] = v end
    local away = true
    for _, x in ipairs(g) do
      e.rec, e.play, e.me = e.rec or x.rec, e.play or x.play, e.me or x.me
      away = away and x.away == true
    end
    e.away = away or nil
    if #g > 1 then
      e.devices = {}
      for _, x in ipairs(g) do e.devices[#e.devices + 1] = { user = x.user, song = x.song, room = x.room, rec = x.rec, play = x.play, away = x.away, me = x.me } end
    end
    out[#out + 1] = e
  end
  return out
end

function webhome.build(proj, cfg, b, now)
  local rooms, extras = require("rooms"), require("extras")
  local front = reaper.EnumProjects(-1)
  local projects, online, takes, bounces = {}, {}, {}, {}
  -- (your other computers are you: folded into your own entry, lib/persons.lua. rt-people)
  local persons = require("persons")
  local me_key = persons.of(cfg.root, cfg.user)
  local function key_of(u) local k = persons.of(cfg.root, u); return k == me_key and "\0me" or k end
  for _, song in ipairs(band.songs(cfg)) do
    if #projects >= webhome.PROJECTS then break end
    local sdir = band.song_dir(cfg, song)
    local names = band.subdirs(sdir .. "/rooms")
    if #names == 0 then names = { "main" } end
    local p = { name = song, stage = extras.stage(cfg.root, song), current = song == b.song or nil, rooms = #names, online = {} }
    for _, room in ipairs(names) do
      local last, tk, changes = room_news(cfg, song, room, song == b.song and room == b.room, now)
      if last and (not p.last or last.time > p.last.time) then p.last = last end
      local since = S.since and S.since[song]
      if since then -- (since you were last here: others' changes newer than the time this browser last saw the project; the scan's depth is the most it counts)
        for _, c in ipairs(changes) do if c.user ~= cfg.user and c.time and c.time > since then p.since = (p.since or 0) + 1 end end
        p.since_at = since
      end
      for _, t in ipairs(tk) do takes[#takes + 1] = t end
      for _, x in ipairs(room_people(cfg, song, room, now)) do
        x.room = room ~= "main" and room or nil
        p.online[#p.online + 1] = x
        online[#online + 1] = { user = x.user, song = song, room = x.room, rec = x.rec, play = x.play, away = x.away, me = key_of(x.user) == "\0me" or nil }
      end
      local tab = rooms.tab(song, room)
      if tab then
        p.open = true
        online[#online + 1] = { user = cfg.user, me = true, song = song, room = room ~= "main" and room or nil, away = tab ~= front or nil }
      end
    end
    p.online = webhome.fold(p.online, key_of, nil) -- (one face per person in the project: rt-people)
    if not p.last then
      local s = band.read_json(band.session_path(cfg, song))
      if type(s) == "table" and type(s.published) == "string" then p.last = { user = type(s.host) == "string" and s.host or nil, time = s.published, what = "published it" } end
    end
    for _, f in ipairs(band.files(sdir .. "/mixes")) do
      local m = webhome.mix_of(f, webhome.mtime(sdir .. "/mixes/" .. f))
      if m and m.time then m.kind, m.song = "mix", song; bounces[#bounces + 1] = m end
    end
    for _, d in ipairs(band.subdirs(sdir .. "/stems")) do
      local m = webhome.stems_of(d, webhome.mtime(sdir .. "/stems/" .. d))
      if m and m.time then m.kind, m.song = "stems", song; bounces[#bounces + 1] = m end
    end
    projects[#projects + 1] = p
  end
  table.sort(projects, function(a, z)
    local ta, tz = a.last and a.last.time or "", z.last and z.last.time or ""
    if ta ~= tz then return ta > tz end
    return a.name < z.name
  end)
  online = webhome.fold(online, key_of, b.song)
  table.sort(online, function(a, z) if (a.me or false) ~= (z.me or false) then return z.me == true end return a.user < z.user end)
  for _, list in ipairs({ takes, bounces }) do
    table.sort(list, newer)
    for i = #list, webhome.RECENT + 1, -1 do list[i] = nil end
  end
  -- the chat's parts (the studio's whole chat: read less often)
  if not S.chat or now - S.chat_at >= webhome.CHAT_EVERY then
    S.chat_at = now
    local chat = require("page_chat")
    local names = chat.names_of(cfg) -- (the chat's own: your name, your display name, everyone)
    local ok, t = pcall(chat.newest, cfg, b, "band", webhome.CHAT_MSGS, webhome.CHAT_TODOS) -- (the newest, not the whole studio's chat)
    S.chat = webhome.chat_model(ok and t or nil, cfg.user, names, os.time())
    -- unread: every conversation's where the chat keeps an index of them (rt-chat2's chat.unread_summary: DMs and channels too), else the
    -- panel's count for this project
    if chat.unread_summary then
      local uok, x = pcall(chat.unread_summary, cfg, b)
      if uok and type(x) == "table" then
        S.chat.unread, S.chat.unread_at, S.chat.unread_by = tonumber(x.total), tonumber(x.mentions), {}
        for _, c in pairs(type(x.by) == "table" and x.by or {}) do
          if type(c) == "table" and (tonumber(c.n) or 0) > 0 then
            S.chat.unread_by[#S.chat.unread_by + 1] = { name = short(c.name, 40), kind = type(c.kind) == "string" and c.kind or nil, n = tonumber(c.n), at = tonumber(c.at) }
          end
        end
        table.sort(S.chat.unread_by, function(p, q) if p.n ~= q.n then return p.n > q.n end return p.name < q.name end)
        for i = #S.chat.unread_by, webhome.RECENT + 1, -1 do S.chat.unread_by[i] = nil end
      end
    else
      local uok, n = pcall(chat.unread, cfg, b)
      S.chat.unread = uok and tonumber(n) or nil
    end
  end
  local recap
  local rok, r = pcall(require("recap").last, cfg, b.song, b.room)
  if rok and type(r) == "table" then
    local lok, lines = pcall(require("recap").lines, r)
    recap = { time = r.to, lines = {} }
    for i = 1, lok and math.min(8, #lines) or 0 do recap.lines[i] = lines[i] end
  end
  -- (Your computers: which of the studio's computers are yours, both saying so. lib/persons.lua, rt-people)
  local cok, computers = pcall(persons.computers, cfg.root, cfg.user)
  return { me = cfg.user, studio = band.info(cfg.root).name, song = b.song, room = b.room ~= "main" and b.room or nil,
    projects = projects, online = online, takes = takes, bounces = bounces, recap = recap, computers = cok and computers or nil,
    opened = S.opened and os.time() - S.opened.at < 60 and S.opened or nil,
    unread = S.chat.unread, unread_at = S.chat.unread_at, unread_by = S.chat.unread_by, mentions = S.chat.mentions, todos = S.chat.todos, recent = S.chat.recent }
end

-- ---- what the page sends ---------------------------------------------------------------------------------------------------------------
-- Open a project of this studio here (o: { song, room }): only one band.songs lists (a guest's own list), a room it has. Its tab when it's
-- open, else the panel's way (Open session, which asks as ever). -> words for the log.
function webhome.open(cfg, o)
  if type(o) ~= "table" or type(o.song) ~= "string" then return nil end
  local room = type(o.room) == "string" and o.room ~= "" and o.room or "main"
  local known = false
  for _, s in ipairs(band.songs(cfg)) do known = known or s == o.song end
  if not known then return "the web page asked to open a project this studio doesn't have" end
  if room ~= "main" then
    local ok = false
    for _, r in ipairs(band.subdirs(band.song_dir(cfg, o.song) .. "/rooms")) do ok = ok or r == room end
    if not ok then return "the web page asked to open a room '" .. o.song .. "' doesn't have" end
  end
  local tab = require("rooms").tab(o.song, room)
  if tab then
    reaper.SelectProjectInstance(tab)
    S.opened = { song = o.song, room = room ~= "main" and room or nil, said = "It's already open on that computer: switched to it.", at = os.time() }
    return "switched to '" .. o.song .. "', from the web page"
  end
  local id = reaper.AddRemoveReaScript(true, 0, scripts_dir() .. "/StudioSync - Open session.lua", true)
  if not id or id <= 0 then return "couldn't register 'StudioSync - Open session' as an action (is the Scripts folder read-only?)" end
  reaper.SetExtState(band.SECTION, "open project", o.song .. "|" .. room, false)
  -- (a page asked, perhaps from a phone nobody at this computer is watching: the script's own boxes ("still arriving", "open that room first") would
  -- sit there blocking REAPER's window. With this flag it says them to the log and to ExtState "open said" instead, and the page is told. rt-p5)
  reaper.SetExtState(band.SECTION, "open quiet", "1", false)
  reaper.DeleteExtState(band.SECTION, "open said", false)
  reaper.Main_OnCommand(id, 0)
  reaper.DeleteExtState(band.SECTION, "open quiet", false)
  local said = reaper.GetExtState(band.SECTION, "open said")
  reaper.DeleteExtState(band.SECTION, "open said", false)
  S.opened = { song = o.song, room = room ~= "main" and room or nil, said = said ~= "" and said or nil, at = os.time() }
  return "opening '" .. o.song .. "', from the web page" .. (said ~= "" and (": " .. said) or "")
end
-- a: { topic = "home", want, open = { song, room } } or { topic = "profile", ... } (lib/profile.lua). -> words for the log, or nil.
function webhome.action(proj, cfg, b, a)
  local now = reaper.time_precise()
  if a.topic == "profile" then
    local ok, reply, said = pcall(require("profile").action, cfg, a)
    if not ok then reply, said = { id = type(a.id) == "string" and a.id:sub(1, 40) or nil, why = "couldn't be saved" }, "the web page's profile change couldn't be saved: " .. tostring(reply) end
    S.reply, S.prof_at, S.chat = reply, -math.huge, nil -- (a new display name mentions you from now on)
    return said
  end
  if a.want then
    S.want, S.at = now + webhome.WANT_FOR, -math.huge
    -- (since you were last here: the page says when it last saw each project; a map song -> ISO time, bounded, checked, a page's own browser's word)
    if type(a.since) == "table" then
      local m, n = {}, 0
      for song, t in pairs(a.since) do
        if n < webhome.SINCE_MAX and type(song) == "string" and #song <= 120 and type(t) == "string" and #t <= 20 and t:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$") then m[song], n = t, n + 1 end
      end
      S.since = m
    end
  end
  if a.open ~= nil then return webhome.open(cfg, a.open) end
  if type(a.computer) == "table" then -- ({ user, on }: one of the studio's computers is yours, or isn't. lib/persons.lua, rt-people)
    S.at = -math.huge
    local said, why = require("persons").set(cfg.root, a.computer.user, a.computer.on == true)
    return said or ("the web page's Your computers change wasn't made: " .. tostring(why))
  end
end
-- Each tick in front, while a page looks (lib/webui.lua).
function webhome.tick(proj, cfg, b, publish, now)
  local gen = require("page_chat").seen_gen -- (read in the chat here: the unread count goes again at once, not up to 25 s on. rt-people)
  if gen ~= S.seen_gen then
    if S.seen_gen ~= nil then S.chat, S.at = nil, -math.huge end
    S.seen_gen = gen
  end
  if now - S.prof_at >= require("profile").EVERY then
    S.prof_at = now
    local ok, m = pcall(require("profile").model, cfg, S.reply)
    publish("profiles", ok and m or { me = cfg.user, people = {}, error = tostring(m) })
  end
  if S.want > now and now - S.at >= webhome.EVERY then
    S.at = now
    local ok, m = pcall(webhome.build, proj, cfg, b, now)
    publish("home", ok and m or { me = cfg.user, error = tostring(m) })
  end
end
function webhome._reset() S = { want = -math.huge, at = -math.huge, chat_at = -math.huge, chat = nil, prof_at = -math.huge, reply = nil }; scans, takes_memo, mtimes, stamps, stamps_n = {}, {}, {}, {}, 0 end

return webhome
