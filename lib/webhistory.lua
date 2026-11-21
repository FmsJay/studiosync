-- The web UI's History page (lib/webui/history.js): the song's life replayed as a time lapse, like the map at the end of a game of Civ.
-- Tracks appear, items land, move and get trimmed, regions form, coloured by who or by what kind of change; then a summary of who did what.
-- Built from the room's own records only (recall.lua's cache of the events folder, shared with the Song page's History and the panel's Restore
-- page, and recall.list's saved versions): nothing new is recorded, and nothing is changed from here. The page only ever says "I'm looking"
-- (`{topic:"history", want}`, every 10 s; WANT_FOR s grace). One topic, built every BUILD_EVERY s while looked at and published only when it
-- changed:
--   hist  { users, cols, kinds, tracks, frames, sessions, who, days, versions, ... }: at most FRAMES frames, each only what changed in it
--         (items set or gone, tracks added or gone, track-level changes, regions), so a long history is a few hundred KB at most, not every
--         event. A frame holds `per` changes (more in a long history), and never runs across a session (GAP s of quiet).
-- An item's length isn't in its event (only its position): it's read from the event file's text (the item chunk's LENGTH), a few files a tick
-- within READ_BUDGET, and kept (event files never change). A new item is a take when its take is named as a recording (lib/recap.lua's rule:
-- REAPER's own recorded-file name, or a smart take name). (James, rt)
local band = require("band")
local webhistory = {}
webhistory.WANT_FOR = 30         -- seconds a page's "I'm looking at History" lasts (pages say it every 10 s)
webhistory.BUILD_EVERY = 10      -- seconds between builds while looked at (a build is skipped when nothing new was read)
webhistory.FRAMES = 360          -- frames at most
webhistory.GAP = 1200            -- seconds of quiet that start a new session (lib/recap.lua's)
webhistory.READ_BUDGET = 0.004   -- seconds a tick reading events (recall.warm) and item lengths
webhistory.REGIONS_MAX = 200
webhistory.NAME_MAX = 40
webhistory.KINDS = { "take", "edit", "mix", "midi", "time" } -- (0-based on the page: 0 take ... 4 tempo, markers and regions)
local TAKE, EDIT, MIX, MIDI, TIME = 0, 1, 2, 3, 4

-- ---- pure ------------------------------------------------------------------------------------------------------------------------------
local function r3(x) return math.floor((tonumber(x) or 0) * 1000 + 0.5) / 1000 end
local function short(s) s = tostring(s or ""); return utf8.len(s) and utf8.len(s) > webhistory.NAME_MAX and s:sub(1, utf8.offset(s, webhistory.NAME_MAX + 1) - 1) .. "…" or s end
-- An ISO UTC stamp -> seconds since 1970 (UTC, exact: band.iso_time reads it as local time, fine for differences only). Pure.
function webhistory.epoch(iso)
  local y, m, d, H, M, S = tostring(iso or ""):match("^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)")
  if not y then return nil end
  y, m, d = tonumber(y), tonumber(m), tonumber(d)
  if m <= 2 then y = y - 1 end
  local era = y // 400
  local yoe = y - era * 400
  local doy = (153 * ((m + 9) % 12) + 2) // 5 + d - 1
  local days = era * 146097 + yoe * 365 + yoe // 4 - yoe // 100 + doy - 719468
  return days * 86400 + tonumber(H) * 3600 + tonumber(M) * 60 + tonumber(S)
end
-- An event's file text -> an item's { len, lane, midi, take }, or a track's { plays, after (the track it sat under) }. `decode`: the event decoded (only asked for a new item's, the one that can be a take).
function webhistory.detail(text, ev, decode)
  text = type(text) == "string" and text or ""
  if ev.obj == "track" then -- (a track: which of its fixed lanes play; nil when it has none, everything on it plays)
    return { plays = text:match('"freemode":%s*2[,}]') and text:match('"plays":%s*"([%d,]*)"') or nil, after = text:match('"after":%s*"([^"\\]*)"') }
  end
  local out = { lane = tonumber(text:match("BANDLANE (%d+)")), len = tonumber(text:match("\\nLENGTH ([%d%.eE%+%-]+)")), midi = text:find("<SOURCE MIDI", 1, true) ~= nil or nil }
  if (ev.rev or 1) == 1 and not ev.restored and not ev.gone then
    local full = decode and decode(text)
    local st = type(full) == "table" and type(full.state) == "string" and full.state or nil
    if st then -- (as lib/recap.lua counts a session's takes)
      local recap = require("recap")
      local nm = st:match('\nNAME "([^"\n]*)"') or st:match("\nNAME ([^\n]*)")
      local _, p = recap.parse_name(nm)
      if p or (nm and nm ~= "" and recap.is_default_name(nm, st:match('FILE "([^"]+)"'))) then out.take = true end
    end
  end
  return out
end

-- What kind of change an event is, and what it touches: "item", "track", "part" (a track's plug-ins, automation, sends: a mix move on the
-- track), "time" (tempo, markers, regions), "note", or nil (handovers, play/stop together, likes: not changes to the song).
local function what(e)
  local k = e.kind or e.type
  if k == "obj" then
    if e.obj == "item" then return "item" end
    if e.obj == "track" then return "track" end
    return "part"
  end
  if k == "edit" or k == "delete" or k == "undelete" or k == "midi" then return "litem" end -- (before mirror sync: takes by their id)
  if k == "track" or k == "plays" then return "ltrack" end
  if k == "timeline" or k == "shift" then return "time" end
  if k == "note" then return "note" end
  return nil
end
local function upper(s) return type(s) == "string" and s ~= "" and s:upper() or nil end

-- evs: recall's events, any order; info(ev) -> webhistory.detail's table or nil (not read yet); o: { places = upper oid or "N"..lower name ->
-- the track's place now, colours = user -> 0xRRGGBB, versions = recall.list's rows, frames, gap, day = secs -> "YYYY-MM-DD" }.
-- -> the hist topic (see the top).
function webhistory.build(evs, info, o)
  o = o or {}
  local FR, GAP = o.frames or webhistory.FRAMES, o.gap or webhistory.GAP
  local day = o.day or function(t) return os.date("%Y-%m-%d", t) end
  local places = o.places or {}
  local list, keys = {}, {}
  for _, e in ipairs(evs or {}) do
    if type(e) == "table" and type(e.user) == "string" and type(e.time) == "string" and not e.auto and what(e) then
      local t = webhistory.epoch(e.time)
      if t then list[#list + 1] = e; keys[e] = { e.time .. tostring(e.id), t } end
    end
  end
  table.sort(list, function(a, z) return keys[a][1] < keys[z][1] end)

  local users, uix, cols = {}, {}, {}
  local function u(name)
    if not uix[name] then
      users[#users + 1] = name; uix[name] = #users - 1
      local c = o.colours and math.tointeger(o.colours[name])
      cols[#users] = c and string.format("#%06x", c & 0xffffff) or false
    end
    return uix[name]
  end
  local who = {} -- user# -> { take, edit, mix, midi, time, tracks added, notes, first, last }
  local function credit(ui, k, t)
    local w = who[ui + 1] or { 0, 0, 0, 0, 0, 0, 0, t, t }
    who[ui + 1] = w
    if k then w[k + 1] = w[k + 1] + 1 end
    w[8], w[9] = math.min(w[8], t), math.max(w[9], t)
    return w
  end

  -- the replay: tracks and items as they stand after each event
  local tracks, tix = {}, {} -- out: { { name, place } }; key -> { id, alive }
  local order = {} -- track ids alive, top first, as they stood (rt-history2: a track sits under the track its change says, `after`)
  local items, nitems = {}, 0 -- key -> { iid, tid, pos, len, u, k }
  local frames, sessions, days = {}, {}, {}
  local F, last_t, nchanges, per = nil, nil, 0, 1
  local last_tp
  local nsess, prev_t = 0, nil
  for _, e in ipairs(list) do
    if what(e) ~= "note" then
      nchanges = nchanges + 1
      if not prev_t or keys[e][2] - prev_t > GAP then nsess = nsess + 1 end
      prev_t = keys[e][2]
    end
  end
  -- (a session's last frame can be short: room for one each, while sessions are under half the frames; past that, frames run across them)
  local breaks = nsess <= FR / 2
  per = math.max(1, math.ceil(nchanges / (FR - (breaks and nsess or 0))))
  local function close()
    if not F then return end
    local f = { t = F.t, s = F.s, n = F.n }
    local function flat(map, row)
      local ids = {}
      for id in pairs(map) do ids[#ids + 1] = id end
      if #ids == 0 then return nil end
      table.sort(ids)
      local out = {}
      for i, id in ipairs(ids) do out[i] = row and row(id, map[id]) or id end
      return out
    end
    f.i = flat(F.i, function(_, it) return { it.iid, it.tid, r3(it.pos), r3(it.len), it.u, it.k, it.lane or -1 } end)
    f.p = flat(F.p, function(id, x) return { id, x } end)
    f.g, f.ta, f.tg = flat(F.g), flat(F.ta), flat(F.tg)
    f.m = flat(F.m, function(id, x) return { id, x[1], x[2] } end)
    f.r, f.mk, f.tp = F.r, F.mk, F.tp
    if F.o then f.o = { table.unpack(order) } end -- (the lanes' order as it stood, when it changed)
    frames[#frames + 1] = f
    F = nil
  end
  local function frame(t)
    if not F then F = { t = t, s = #sessions - 1, n = 0, i = {}, g = {}, ta = {}, tg = {}, m = {}, p = {} } end
    F.s = math.max(0, #sessions - 1) -- (the session of its last change)
    return F
  end
  -- A track into the order under `after` ("" the top, a track's key; not known: where it sits today among those there then). -> whether it moved.
  local function place(tr, after, t)
    local cur, at
    for i, x in ipairs(order) do if x == tr.id then cur = i end end
    local a = after and after ~= "" and tix[after]
    if after == "" then at = 0 elseif a and a.alive and a ~= tr then for i, x in ipairs(order) do if x == a.id then at = i end end end
    if not at and cur then return false end -- (a place it can't tell: it stays)
    if cur then
      if (at == 0 and cur == 1) or (at and at > 0 and order[cur - 1] == order[at]) then return false end
      table.remove(order, cur)
      if at and at > cur then at = at - 1 end
    end
    if not at then
      local mine = tracks[tr.id + 1][2]
      mine = mine >= 0 and mine or math.huge
      at = #order
      for i, x in ipairs(order) do local p = tracks[x + 1][2]; if (p >= 0 and p or math.huge) > mine then at = i - 1; break end end
    end
    table.insert(order, at + 1, tr.id)
    frame(t).o = true
    return true
  end
  local function track(key, name, t, after)
    local tr = tix[key]
    if not tr then
      tracks[#tracks + 1] = { short(name), places[key] or -1 }
      tr = { id = #tracks - 1 }
      tix[key] = tr
    elseif name and name ~= "" then tracks[tr.id + 1][1] = short(name) end
    if not tr.alive then
      tr.alive = true
      local f = frame(t)
      if f.tg[tr.id] then f.tg[tr.id] = nil else f.ta[tr.id] = true end
      place(tr, after, t)
    end
    return tr
  end
  local function item_set(key, tr, pos, len, ui, k, t, lane)
    local it = items[key]
    if not it then nitems = nitems + 1; it = { iid = nitems - 1 }; items[key] = it end
    it.tid, it.pos, it.len, it.u, it.k, it.alive = tr.id, pos, len, ui, k, true
    if lane ~= false then it.lane = lane end -- (false: not read yet, the last known lane stays)
    local f = frame(t)
    f.g[it.iid] = nil
    f.i[it.iid] = it
  end
  local function item_gone(key, t)
    local it = items[key]
    if not (it and it.alive) then return end
    it.alive = false
    local f = frame(t)
    f.i[it.iid] = nil
    f.g[it.iid] = true
  end
  local function track_gone(key, t)
    local tr = tix[key]
    if not (tr and tr.alive) then return end
    tr.alive = false
    for ik, it in pairs(items) do if it.alive and it.tid == tr.id then item_gone(ik, t) end end
    for i, x in ipairs(order) do if x == tr.id then table.remove(order, i); frame(t).o = true; break end end
    local f = frame(t)
    if f.ta[tr.id] then f.ta[tr.id] = nil else f.tg[tr.id] = true end
  end
  local stats = { need = 0, have = 0 }
  -- Which revision of an object stands: mirror sync's own order (mirror.newer: higher rev, then its clock, then the user), not the order
  -- the files' times give. A bandmate's edit stamped after a deletion it lost to (or late, or clock-skewed) didn't bring anything back.
  local won = {}
  local function wins(e)
    local oid = upper(e.oid)
    if not oid or (e.kind or e.type) ~= "obj" then return true end
    local rev, ms, user = tonumber(e.rev) or 0, tonumber(e.hlc) or keys[e][2] * 1000, tostring(e.user)
    local w = won[oid]
    if w and (w[1] > rev or (w[1] == rev and (w[2] > ms or (w[2] == ms and w[3] >= user)))) then return false end
    won[oid] = { rev, ms, user }
    return true
  end

  for _, e in ipairs(list) do
    local w, t = what(e), keys[e][2]
    local ui = u(e.user)
    if w == "note" then local cw = credit(ui, nil, t); cw[7] = cw[7] + 1
    else
      if not last_t or t - last_t > GAP then
        if breaks then close() end
        sessions[#sessions + 1] = { a = t, z = t, n = 0, f = #frames, u = {} }
      end
      last_t = t
      local s = sessions[#sessions]
      s.z, s.n = t, s.n + 1
      s.u[ui + 1] = true
      local f = frame(t)
      f.t, f.n = t, f.n + 1
      local k
      if w == "item" then
        local key = "I" .. (upper(e.oid) or tostring(e.id))
        local tkey = upper(e.track) or ("N" .. tostring(e.name or ""):lower())
        local had, won = tix[tkey], wins(e)
        if e.gone then if won then item_gone(key, t) end; k = EDIT
        else
          stats.need = stats.need + 1
          local d = info and info(e)
          if d then stats.have = stats.have + 1 end
          local prev = items[key]
          local len = d and d.len or (prev and prev.len) or 0
          local pos = tonumber(e.pos) or (prev and prev.pos) or 0
          if d and d.take then k = TAKE
          elseif d and d.midi and (not prev or not prev.alive or (math.abs(prev.pos - pos) < 1e-4 and math.abs(prev.len - len) < 1e-4 and had and prev.tid == had.id)) then k = MIDI
          else k = EDIT end
          -- (an edit that lost to a newer revision, or onto a track already deleted, changes nothing: it went with its track, as in REAPER)
          local lane = false -- (not read yet)
          if d then lane = d.lane end
          if won and not (had and not had.alive) then item_set(key, track(tkey, e.name, t), pos, len, ui, k, t, lane) end
        end
      elseif w == "litem" then
        local key = "L" .. tostring(e.take or e.id)
        if e.kind == "delete" or e.type == "delete" then item_gone(key, t); k = EDIT
        else
          local tr = track("N" .. tostring(e.track or ""):lower(), e.track, t)
          local prev = items[key]
          k = (e.kind or e.type) == "midi" and MIDI or EDIT
          item_set(key, tr, tonumber(e.pos) or (prev and prev.pos) or 0, tonumber(e.len) or (prev and prev.len) or 0, ui, k, t)
        end
      elseif w == "track" or w == "ltrack" then
        local key = w == "track" and (upper(e.oid) or "?") or ("N" .. tostring(e.track or ""):lower())
        local had = tix[key] and tix[key].alive
        if not wins(e) then k = (e.gone or not had) and EDIT or MIX
        elseif e.gone then track_gone(key, t); k = EDIT
        else
          local d = w == "track" and info and info(e)
          local after = d and d.after and (d.after == "" and "" or upper(d.after)) or nil
          local tr = track(key, w == "track" and e.name or e.track, t, after)
          if w == "track" then stats.need = stats.need + 1; if d then stats.have = stats.have + 1 end end
          if d and (d.plays or "") ~= (tr.plays or "") then tr.plays = d.plays; f.p[tr.id] = d.plays or "" end -- (a lane switch: what shows changes)
          if not had and w == "track" and (e.rev or 1) == 1 and not e.restored then local cw = credit(ui, nil, t); cw[6] = cw[6] + 1 end
          local moved = had and after ~= nil and place(tr, after, t) -- (where its change says it sits: a move, or the order catching up)
          k = (had and not (moved and type(e.moved) == "string")) and MIX or EDIT
          if had then f.m[tr.id] = { ui, k } end
        end
      elseif w == "part" then
        local tkey = upper(e.track) or (upper(e.oid) and ("T" .. upper(e.oid):sub(2))) or "?"
        k = MIX
        if tkey ~= "T-MASTER" and wins(e) and not (tix[tkey] and not tix[tkey].alive) then f.m[track(tkey, e.name, t).id] = { ui, k } end -- (the master isn't a lane)
      elseif w == "time" then
        k = TIME
        if (e.kind or e.type) == "timeline" and type(e.markers) == "table" then
          local r = {}
          for _, m in ipairs(e.markers) do
            if type(m) == "table" and m.region and tonumber(m.pos) and tonumber(m["end"]) and #r < webhistory.REGIONS_MAX then
              r[#r + 1] = { r3(m.pos), r3(m["end"]), short(m.name) }
            end
          end
          f.r = r
          local mk = {} -- (markers, not regions: a flag on the ruler each)
          for _, m in ipairs(e.markers) do
            if type(m) == "table" and not m.region and tonumber(m.pos) and #mk < webhistory.REGIONS_MAX then mk[#mk + 1] = { r3(m.pos), short(m.name) } end
          end
          f.mk = mk
        end
        if (e.kind or e.type) == "timeline" and type(e.tempo) == "table" then -- (the tempo map, when it changed: { time, bpm, num, denom } each)
          local tp = {}
          for _, m in ipairs(e.tempo) do
            if type(m) == "table" and tonumber(m.time) and tonumber(m.bpm) and #tp < webhistory.REGIONS_MAX then tp[#tp + 1] = { r3(m.time), r3(m.bpm), tonumber(m.num) or 0, tonumber(m.denom) or 0 } end
          end
          local sig = band.json_encode(tp)
          if #tp > 0 and sig ~= last_tp then last_tp, f.tp = sig, tp end
        end
      end
      credit(ui, k, t)
      local dy = day(t)
      days[dy] = (days[dy] or 0) + 1
      if f.n >= per then close() end
    end
  end
  close()

  local sout = {}
  for _, s in ipairs(sessions) do
    local us = {}
    for i in pairs(s.u) do us[#us + 1] = i - 1 end
    table.sort(us)
    sout[#sout + 1] = { a = s.a, z = s.z, n = s.n, f = s.f, u = us }
  end
  local dout = {}
  for dy, n in pairs(days) do dout[#dout + 1] = { dy, n } end
  table.sort(dout, function(a, z) return a[1] < z[1] end)
  local vout = {}
  for _, v in ipairs(o.versions or {}) do
    local t = type(v) == "table" and webhistory.epoch(v.time)
    if t and #vout < 200 then vout[#vout + 1] = { t, short(v.label or v.file), type(v.by) == "string" and u(v.by) or -1 } end
  end
  table.sort(vout, function(a, z) return a[1] < z[1] end)
  for i = 1, #users do who[i] = who[i] or { 0, 0, 0, 0, 0, 0, 0, false, false } end
  return { users = users, cols = cols, kinds = webhistory.KINDS, tracks = tracks, frames = frames, sessions = sout, who = who, days = dout,
    versions = vout, changes = nchanges, per = per, lengths = { have = stats.have, need = stats.need } }
end

-- ---- Live sync's tick (through lib/webui.lua) -------------------------------------------------------------------------------------------
local S = { want_until = -math.huge }
local info = setmetatable({}, { __mode = "k" }) -- event (recall's cached table) -> webhistory.detail's; kept as long as recall keeps it
function webhistory.info(ev) return info[ev] end
-- An action a page sent ({ topic = "history", want }): "I'm looking" or "not any more". Hearing a point, A/B and Restore (the History page's
-- hear-it-as-it-was panel, lib/webui/histhear.js) are lib/histhear.lua's. The time lapse itself changes nothing.
function webhistory.action(proj, cfg, b, a)
  if type(a) ~= "table" then return end
  if a.hear ~= nil or a.cancel ~= nil or a.restore ~= nil then return require("histhear").action(proj, cfg, b, a) end
  local now = reaper.time_precise()
  if a.want == true then S.want_until = now + webhistory.WANT_FOR elseif a.want == false then S.want_until = -math.huge end
end
function webhistory.looking(now) return (now or reaper.time_precise()) < S.want_until end

local function places_now(proj)
  local out, dawview, mirror = {}, require("dawview"), require("mirror")
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    if dawview.shown(tr) then
      local oid = upper(mirror.track_oid(tr))
      if oid then out[oid] = i end
      out["N" .. select(2, reaper.GetTrackName(tr)):lower()] = i
    end
  end
  return out
end

-- Each tick in front, while a page looks. publish(topic, table) sends only what changed.
function webhistory.tick(proj, cfg, b, publish, now)
  require("histhear").tick(proj, cfg, b, publish, now) -- (a preview rendering goes on, and comes in, whatever page is shown)
  if now >= S.want_until then return end
  local key = b.song .. "/" .. b.room
  if S.key ~= key then S = { want_until = S.want_until, key = key, at = -math.huge, queue = {}, qi = 1 } end
  local recall = require("recall")
  local t0 = reaper.time_precise()
  local done, got, of = recall.warm(cfg, b.song, b.room, webhistory.READ_BUDGET / 2, false)
  -- item lengths, from the queue the last build left (events read but not looked into yet)
  local read_any = false
  while S.qi <= #S.queue and reaper.time_precise() - t0 < webhistory.READ_BUDGET do
    local ev = S.queue[S.qi]
    S.qi = S.qi + 1
    if not info[ev] then
      local path = rawget(ev, "path_")
      info[ev] = webhistory.detail(path and band.read(path), ev, band.json_decode)
      read_any = true
    end
  end
  S.read = S.read or read_any
  local queue_done = S.qi > #S.queue
  local first = S.at == -math.huge or (done and not S.done) or (queue_done and S.read and not S.qdone)
  if not (first or (now - S.at >= webhistory.BUILD_EVERY and (got ~= S.got or S.read))) then return end
  S.at, S.got, S.done, S.qdone, S.read = now, got, done, queue_done, false
  local evs = recall.read_so_far(cfg, b.song, b.room)
  S.queue, S.qi = {}, 1
  local names, list = {}, {}
  for _, e in ipairs(evs) do
    if e.kind == "obj" and (e.obj == "item" or e.obj == "track") and not e.gone and not info[e] then S.queue[#S.queue + 1] = e end
    if type(e.user) == "string" and not names[e.user] then names[e.user] = true; list[#list + 1] = e.user end
  end
  local h = webhistory.build(evs, webhistory.info, { places = places_now(proj), colours = require("people").colours(cfg.root, list),
    versions = recall.list(cfg, b.song, b.room) })
  S.qdone = #S.queue == 0
  h.key, h.song, h.read = key, b.song, { done = done or nil, got = got, of = of }
  publish("hist", h)
end

return webhistory
