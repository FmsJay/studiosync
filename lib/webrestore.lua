-- History > Changes and Versions in the web UI (rt-ui3: docs/rt/ui-web-plan.md 2.5 and Phase 3). The panel's Restore page (lib/page_restore.lua)
-- for any page: every change, newest first, with its filters (who, kind, track, words); per change Go to it, Undo this change, Restore to here
-- (the whole project, or chosen tracks); saved versions (Save this version, Save permanently, Restore to one); Open it as it was before
-- StudioSync; kept automation (Put mine back, Let it go).
-- Restores and undos run page_restore's own functions (plan_for, restore_whole, restore_tracks, undo_change: its R.test table, set up with
-- this tick's project, as tests/test_0_60_rt_histhear_panel.lua does), so they do exactly what the panel's buttons do, under the same rules
-- (the whole project: the person in control only; tracks: each object's own). Nothing that changes the project or can't be taken back happens
-- on one message: the page asks, Live sync answers with what would change and an id (`ask`), the page shows that in its own confirm, and only
-- { yes = <that id>, confirm = true } within ASK_FOR s does it. From a phone the same (James, 2026-11-27: restore from a phone with an in-page
-- confirm). Go to it and Open it as it was before StudioSync act on this REAPER, so only from a page on this computer.
-- Topic "hchanges", built while a page shows Changes or Versions (it says so every 10 s, with its filters), every BUILD_EVERY s, sooner after
-- a filter or an act.
local band = require("band")
local webrestore = {}
webrestore.WANT_FOR = 30     -- seconds a page's "I'm looking" lasts
webrestore.BUILD_EVERY = 4   -- seconds between builds while looked at (the panel's History re-read)
webrestore.ROWS_MAX = 300    -- changes sent at most (the newest that match)
webrestore.ASK_FOR = 120     -- seconds an ask's yes stays good (histhear.ASK_FOR)
webrestore.LABEL_MAX = 80    -- a saved version's name, a filter's words
webrestore.TRACKS_MAX = 200
-- The kind filter, as lib/page_restore.lua's KINDS: a label, and a test on the change or a set of event kinds.
webrestore.KINDS = {
  { "Every kind" }, { "Items (recordings, MIDI, moves, edits)", function(e) return e.obj == "item" and not e.gone end },
  { "Tracks (names, lanes, mute, folders)", function(e) return e.obj == "track" and not e.gone end },
  { "Plug-ins", function(e) return e.obj == "fx" end }, { "Automation, sends and track settings", function(e) return e.obj == "env" or e.obj == "recv" or e.obj == "misc" end },
  { "Deletes", function(e) return e.gone end },
  { "Brought back (undo, restore)", function(e) return e.restored ~= nil end },
  { "Notes and likes", { note = true, like = true } }, { "Tempo and arrangement", { timeline = true, shift = true } },
  { "Who's in control (handovers)", { driver = true } }, { "Played or recorded together", { start = true, stop = true } },
}

-- ---- pure ------------------------------------------------------------------------------------------------------------------------------
-- A page's filter, checked: { who, kind (1..#KINDS), track, text }, strings capped. Pure.
function webrestore.filter(f)
  f = type(f) == "table" and f or {}
  local function s(x) return type(x) == "string" and #x <= webrestore.LABEL_MAX and x or "" end
  local k = math.tointeger(tonumber(f.kind)) or 1
  return { who = s(f.who), kind = (k >= 1 and k <= #webrestore.KINDS) and k or 1, track = s(f.track), text = s(f.text) }
end
-- The rows for a page: entries (sorted, oldest first), filter f, o = { describe(e), lane(i) -> words, moment(i) -> indices of its act }.
-- -> rows newest first (at most ROWS_MAX: { id, t, who, words, tint, n, undo }), how many more matched, the people and tracks to filter by. Pure.
function webrestore.rows(entries, f, o)
  local epoch = require("webhistory").epoch
  local want = webrestore.KINDS[f.kind][2]
  local text = f.text:lower()
  local users, tracks, seen = {}, {}, {}
  for _, e in ipairs(entries) do
    if e.user and not seen["u" .. e.user] then seen["u" .. e.user] = true; users[#users + 1] = e.user end
    local tn = e.kind == "obj" and e.name or e.track -- (mirror changes carry the track's name; .track is its id)
    if type(tn) == "string" and tn ~= "" and not seen["t" .. tn:lower()] then seen["t" .. tn:lower()] = true; tracks[#tracks + 1] = tn end
  end
  local rows, more = {}, 0
  for i = #entries, 1, -1 do
    local e = entries[i]
    local ok = not e.auto and (f.who == "" or e.user == f.who)
      and (not want or (type(want) == "function" and want(e)) or (type(want) == "table" and want[e.kind]))
      and (f.track == "" or (e.name or e.track or ""):lower() == f.track:lower())
    local line, lane
    if ok then
      line, lane = o.describe(e), o.lane(i)
      ok = text == "" or (line .. lane .. " " .. tostring(e.user)):lower():find(text, 1, true) ~= nil
    end
    local moment = ok and o.moment(i) or { i }
    for _, j in ipairs(moment) do if j > i then ok = false end end -- (one row for one act, on the newest of them)
    if ok then
      if #rows >= webrestore.ROWS_MAX then more = more + 1
      else
        rows[#rows + 1] = { id = e.id, t = epoch(e.time), who = e.user, words = line .. lane, n = #moment > 1 and #moment or nil,
          tint = e.gone and "gone" or e.restored ~= nil and "back" or nil, undo = e.kind == "obj" or nil }
      end
    end
  end
  return rows, more, users, tracks
end
-- The index of the change with this id, or nil. Pure.
function webrestore.find(entries, id)
  if type(id) ~= "string" then return nil end
  for i = #entries, 1, -1 do if entries[i].id == id then return i end end
end
-- The History index a saved version stands at (the last entry at or before its time; 0: older than everything kept). Pure.
function webrestore.upto(entries, p)
  local upto = 0
  for k, e in ipairs(entries) do if (e.time or "") <= (p.time or "") then upto = k end end
  return upto
end
-- Words for undoing entries[i]: what, how many with it, and whose later changes go back too. Pure.
function webrestore.undo_words(entries, i, me, describe)
  local mirror = require("mirror")
  local others, mine = mirror.later_by_others(entries, i), false
  for k = #others, 1, -1 do if others[k] == me then table.remove(others, k); mine = true end end
  if mine then table.insert(others, 1, "You") end
  local together = #mirror.same_moment(entries, i)
  local words = "Undo " .. describe(entries[i]) .. (together > 1 and string.format(", and the %d other change(s) made with it", together - 1) or "") ..
    ". Everything else stays; the undo goes to the others as a new change."
  if #others > 0 then
    words = words .. " " .. table.concat(others, ", ") .. " changed it after this: undoing it takes " .. (#others == 1 and mine and "your" or "their") .. " change back too."
  end
  return words
end

-- ---- Live sync's side (lib/webhistory.lua's action and tick) ----------------------------------------------------------------------------
local S = { want_until = -math.huge, at = -math.huge, f = webrestore.filter() }
webrestore.S = S -- (tests)
local function entries_of(cfg, b)
  local entries = require("recall").entries(cfg, b.song, b.room)
  table.sort(entries, function(a, x) return (a.time .. a.id) < (x.time .. x.id) end) -- (as page_restore's refresh_history)
  return entries
end
local function describe(e)
  local ok, w = pcall(function() -- (positions as bars, as the panel says them)
    local bar_of = require("together").bar_of
    return (require("recall").describe(e):gsub("( [at][to]?) (%d+%.%d+) s", function(w, n) return w .. " bar " .. bar_of(tonumber(n)) end))
  end)
  return ok and w or require("recall").describe(e)
end
local function rules(cfg, b)
  local session = band.read_json(band.session_path(cfg, b.song))
  local can, who = require("sync").authority(cfg, b.song, b.room, session)
  return can, who, session, who and who.driver == cfg.user
end
-- page_restore's functions, set up for this project and these entries.
local function panel(proj, cfg, b, entries, session, driver)
  local R = require("page_restore")
  R.init({ b = function() return b end, cfg = function() return cfg end, proj = function() return proj end,
    view = function() return { session = session, driver = driver } end, refresh_now = function() end })
  R.test.entries(entries)
  return R
end
local function opts_of(proj, can, who)
  return { can = can, mode = who and who.mode, driver = who and who.driver, is_claimed = who and who.is_claimed,
    local_mix = select(2, reaper.GetProjExtState(proj, band.SECTION, "local_mix")) == "1" }
end
local function version(cfg, b, file)
  if type(file) ~= "string" then return nil end
  for _, p in ipairs(require("recall").list(cfg, b.song, b.room)) do if p.file == file then return p end end
end
local function tracks_of(list)
  if list == nil then return nil end
  if type(list) ~= "table" or #list == 0 or #list > webrestore.TRACKS_MAX then return false end
  local out = {}
  for _, x in ipairs(list) do
    if type(x) ~= "string" or not x:match("^T%-[%w%-_]+$") or #x > 120 then return false end
    out[#out + 1] = x:upper()
  end
  return out
end
-- Kept automation (lib/mirror.lua put_back): files in this computer's StudioSync folder, newest first, read again every few seconds.
local function kept_list()
  local out, dir = {}, band.home() .. "/kept automation"
  for _, f in ipairs(band.files(dir, ".json")) do
    local k = band.read_json(dir .. "/" .. f)
    if type(k) == "table" and type(k.state) == "string" and type(k.track) == "string" then k.path, k.file = dir .. "/" .. f, f; out[#out + 1] = k end
  end
  table.sort(out, function(a, x) return tostring(a.time) > tostring(x.time) end)
  return out
end
local function kept_file(id)
  if type(id) ~= "string" then return nil end
  for _, k in ipairs(kept_list()) do if k.file == id then return k end end
end

-- What a do-it would change, as an ask for the page's confirm. -> nil (S.ask set), or nil with S.said saying why not.
local function ask(proj, cfg, b, a)
  local histhear, mirror = require("histhear"), require("mirror")
  local entries = entries_of(cfg, b)
  local can, who, session, driver = rules(cfg, b)
  local x = { id = band.secret(16), until_ = reaper.time_precise() + webrestore.ASK_FOR }
  if a.undo ~= nil then
    local i = webrestore.find(entries, a.undo)
    if not i then S.said = "That change isn't in History any more."; return end
    if entries[i].kind ~= "obj" then S.said = "This kind of change (tempo, a handover, a note) isn't undone on its own: restore the whole project to here instead."; return end
    x.what, x.change, x.words, x.n = "undo", a.undo, webrestore.undo_words(entries, i, cfg.user, describe), 1
  elseif a.letgo ~= nil then
    local k = kept_file(a.letgo)
    if not k then S.said = "That kept automation has gone already."; return end
    x.what, x.kept, x.n = "letgo", a.letgo, 1
    x.words = "Forget this automation of yours on " .. tostring(k.name or "a track") .. "? It can't be brought back after."
  else -- restore to a change ({ to = id }) or a saved version ({ file }), the whole project or chosen tracks
    local r = a.restore
    local tracks = tracks_of(r.tracks)
    if tracks == false then S.said = "Pick the tracks to put back first."; return end
    local i, point
    if r.file ~= nil then
      point = version(cfg, b, r.file)
      if not point then S.said = "That saved version isn't there any more."; return end
      i = webrestore.upto(entries, point)
    else
      i = webrestore.find(entries, r.to)
      if not i then S.said = "That change isn't in History any more."; return end
    end
    if i < 1 then S.said = "This version is older than every change kept in History, so it can't be rebuilt from it."; return end
    if not tracks and not driver then S.said = "Only the person in control can restore the whole project: ask them, or take control. You can restore chosen tracks."; return end
    local plan = panel(proj, cfg, b, entries, session, driver).test.plan_for(i, point, tracks and histhear.scope(tracks) or nil)
    local names = {}
    for _, e in ipairs(entries) do if e.kind == "obj" and e.obj == "track" and e.oid and (e.name or "") ~= "" then names[e.oid:upper()] = e.name end end
    for _, t in ipairs(histhear.track_names(proj)) do names[t[1]] = t[2] end
    local words, n = histhear.describe(plan, function(oid) local _, h, ev = mirror.known(proj, oid); return h, ev end, function(oid) return names[oid:upper()] end)
    if not tracks then
      words, n = histhear.tempo_words(words, n, histhear.timeline_at(entries, i, { first = histhear.first_map(cfg, b, session) }),
        require("sync").timeline_sig and band.json_decode(require("sync").timeline_sig(proj)))
    end
    x.what, x.change, x.file, x.tracks, x.words, x.n = tracks and "tracks" or "whole", r.to, r.file, tracks, words, n
  end
  S.ask, S.said = x, nil
end
-- The yes. -> words for the log, or nil.
local function yes(proj, cfg, b, a)
  local x = S.ask
  if not (x and a.yes == x.id and a.confirm == true and reaper.time_precise() <= x.until_) then
    S.said = "That check ran out: press the button again."; return nil
  end
  S.ask = nil
  if x.what == "letgo" then
    local k = kept_file(x.kept)
    if k then os.remove(k.path) end
    S.said = "Let go."
    return nil
  end
  local entries = entries_of(cfg, b)
  local can, who, session, driver = rules(cfg, b)
  local R = panel(proj, cfg, b, entries, session, driver)
  local opts = opts_of(proj, can, who)
  local said
  if x.what == "undo" then
    local i = webrestore.find(entries, x.change)
    if not i then S.said = "That change isn't in History any more."; return nil end
    said = R.test.undo_change(i, opts)
  else
    local point = x.file and version(cfg, b, x.file)
    local i = point and webrestore.upto(entries, point) or webrestore.find(entries, x.change)
    if not i or i < 1 then S.said = "That point isn't in History any more."; return nil end
    if x.what == "whole" then
      if not driver then S.said = "Only the person in control can restore the whole project: ask them, or take control."; return nil end
      said = R.test.restore_whole(i, point, opts)
    else said = R.test.restore_tracks(i, point, require("histhear").scope(x.tracks), opts) end
  end
  S.said, S.at = tostring(said), -math.huge
  return "History page: " .. S.said
end

-- A page's { changes = {...} }: { want, filter } (I'm looking), { go = id }, { undo = id }, { restore = { to = id | file, tracks } }, { letgo = kept id }
-- (each an ask), { yes = ask id, confirm = true }, { save = { label, keep } }, { before = true }, { putback = kept id }. here: the page is on this
-- computer. -> words for the log, or nil.
function webrestore.action(proj, cfg, b, a, here)
  if a.want ~= nil then
    S.want_until = a.want == true and reaper.time_precise() + webrestore.WANT_FOR or -math.huge
    local f = webrestore.filter(a.filter)
    if band.json_encode(f) ~= band.json_encode(S.f) then S.f, S.at = f, -math.huge end
    return nil
  end
  S.at = -math.huge -- (whatever it did shows on the next tick)
  if a.yes ~= nil then return yes(proj, cfg, b, a) end
  if a.undo ~= nil or a.letgo ~= nil or type(a.restore) == "table" then ask(proj, cfg, b, a); return nil end
  if type(a.save) == "table" then
    local label = type(a.save.label) == "string" and require("webui").clean_text(a.save.label) or nil
    if label and #label > webrestore.LABEL_MAX then label = label:sub(1, webrestore.LABEL_MAX) end
    local recall = require("recall")
    if a.save.keep == true then recall.back_up(proj, cfg, b, label) else recall.save(proj, cfg, b.song, b.room, label or ("saved by " .. cfg.user)) end
    S.said = "Saved" .. (label and (" '" .. label .. "'") or "") .. (a.save.keep == true and ", kept for good." or ".")
    return "History page: " .. S.said
  end
  if type(a.putback) == "string" then
    local k, mirror = kept_file(a.putback), require("mirror")
    local room = require("sync").room_dir(cfg, b.song, b.room)
    if not (k and k.room == room and mirror.find(proj, "track", k.track)) then S.said = "Its track isn't in this project."; return nil end
    local local_mix = select(2, reaper.GetProjExtState(proj, band.SECTION, "local_mix")) == "1"
    if not mirror.apply(proj, { obj = "env", oid = k.oid, track = k.track, name = k.name, state = k.state }, nil, local_mix) then
      S.said = "Not now: stop recording, then try again."; return nil
    end
    -- (the file stays, marked: it goes once the automation has gone out as yours, lib/mirror.lua; as page_restore's Put mine back)
    local path = k.path
    k.path, k.file, k.back = nil, nil, os.time()
    pcall(band.write_json, path, k)
    S.said = "Your automation on " .. tostring(k.name) .. " is back: it goes to the others as your change, if it's yours to change now."
    return "History page: " .. S.said
  end
  if a.go ~= nil or a.before == true then
    if not here then S.said = "That shows it in REAPER on the studio's computer: do it there."; return nil end
    if a.before == true then
      local before = select(2, reaper.GetProjExtState(proj, band.SECTION, "before_bandsync"))
      if before == "" or not reaper.file_exists(before) then S.said = "There's no copy from before StudioSync here."; return nil end
      reaper.Main_OnCommand(40859, 0) -- File: New project tab
      reaper.Main_openProject(before)
      return nil
    end
    local entries = entries_of(cfg, b)
    local i = webrestore.find(entries, a.go)
    local why = i and require("page_restore").show_change(proj, entries[i]) or "it isn't in History any more"
    S.said = why and ("Can't show it: " .. why .. ".") or nil
    return nil
  end
end

-- Each tick in front: the topic while a page looks.
function webrestore.tick(proj, cfg, b, publish, now)
  local key = b.song .. "/" .. b.room
  if S.key ~= key then S.key, S.ask, S.said, S.at = key, nil, nil, -math.huge end -- (another room's ask never does anything here)
  if now >= S.want_until then return end
  local recall, mirror = require("recall"), require("mirror")
  local warm, read, total = recall.warm(cfg, b.song, b.room, 0.004) -- (a few changes a tick until all are read: a big room takes a while)
  if now - S.at < (warm and webrestore.BUILD_EVERY or 1) then return end
  S.at = now
  if S.ask and now > S.ask.until_ then S.ask = nil end
  local driver = select(4, rules(cfg, b))
  local m = { key = key, kinds = {}, f = S.f, driver = driver or nil, said = S.said, tracks_now = require("histhear").track_names(proj) }
  for i, k in ipairs(webrestore.KINDS) do m.kinds[i] = k[1] end
  if S.ask then m.ask = { id = S.ask.id, what = S.ask.what, words = S.ask.words, n = S.ask.n, change = S.ask.change, file = S.ask.file } end
  local entries = warm and entries_of(cfg, b) or {}
  if not warm then m.warm = { read = read, total = total }
  else
    m.rows, m.more, m.users, m.tracks = webrestore.rows(entries, S.f, { describe = describe,
      lane = function(i) return mirror.lane_words(entries, i) end, moment = function(i) return mirror.same_moment(entries, i) end })
  end
  m.versions = {}
  local epoch = require("webhistory").epoch
  for _, p in ipairs(recall.list(cfg, b.song, b.room)) do
    m.versions[#m.versions + 1] = { file = p.file, t = epoch(p.time), label = p.label, by = p.by, keep = p.keep or nil, takes = (p.takes or 0) > 0 and p.takes or nil,
      behind = p.behind or nil, old = warm and webrestore.upto(entries, p) < 1 or nil }
  end
  local before = select(2, reaper.GetProjExtState(proj, band.SECTION, "before_bandsync"))
  m.before = before ~= "" and reaper.file_exists(before) or nil
  local room = require("sync").room_dir(cfg, b.song, b.room)
  m.kept = {}
  for _, k in ipairs(kept_list()) do
    m.kept[#m.kept + 1] = { id = k.file, name = tostring(k.name or "a track"), t = epoch(k.time), back = k.back and true or nil,
      here = (k.room == room and mirror.find(proj, "track", k.track)) and true or nil }
  end
  publish("hchanges", m)
end

return webrestore
