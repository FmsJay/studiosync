-- StudioSync sync engine: event files in and out (mirror sync's object changes, lib/mirror.lua, plus the timeline,
-- handovers, play/stop cues, notes and likes), claims and who may change what, and rendering prints. Each person
-- writes only files named after themselves, so a sync client never sees two people writing the same file.
local band = require("band")
local less = require("rank").less -- (names and ids that break a tie, byte by byte: every computer alike whatever its locale. lib/judge.lua, rt-sync2e)
local sync = {
  SNAP = "BandSync.snap",       -- id -> "<original-case id>|pos|len|offs|lane" as last seen/applied
  APPLIED = "BandSync.applied", -- event id -> "1"
  REV = "BandSync.rev",         -- id -> revision this project holds
  SNAPQN = "BandSync.snapqn",   -- id -> position in quarter notes as last seen/applied (tells tempo moves from edits)
  TAILS = "BandSync.tail",      -- id -> seconds of tail this project's print of it carries (items are that much longer)
  NEWEST = "BandSync.newest",   -- "timeline" -> time..id of the newest change made or applied here
}

-- An edit put back says why in the Activity list, and, with the panel closed (no banner either), in a tooltip by the
-- mouse, where the edit was just made: otherwise it just slid back with no word (laptop, 2026-10-30).
-- The panel also keeps the newest one up in a bar of its own until it's dismissed (ExtState "put back"), and the
-- small button says so: with the panel shrunk to that button, it said nothing at all (review, 2026-10-31).
function sync.put_back(text, mine, claim) -- mine: { oid, ev, name } when it was a clash your version lost, for Use mine; claim: a track the bar can claim
  band.log(text)
  -- (the count is this song's, lately: another song's flood carried over as "1352 edits undone": laptop, 0.42.5)
  local old = band.ext_json(band.SECTION, "put back") or {}
  local same = old.song == sync.current_song and old.at and os.time() - old.at < 600
  local n = same and (tonumber(old.n) or 0) + 1 or 1
  local list = same and mine and type(old.mine) == "table" and old.mine or nil -- (several at once: Use mine takes all of them back)
  if mine then
    list = list or {}
    local seen = false
    for _, m in ipairs(list) do if m.oid == mine.oid then seen = true end end -- (the first of yours that lost is the one you made)
    if not seen and #list < 200 then list[#list + 1] = mine end
  end
  band.set_ext_json(band.SECTION, "put back", { text = text, n = n, at = os.time(), song = sync.current_song, mine = list, claim = claim }, false)
  local beat = tonumber(reaper.GetExtState(band.SECTION, "panel alive"))
  local shown = beat and reaper.time_precise() - beat < 5 and reaper.GetExtState(band.SECTION, "panel minimized") == ""
  if not shown then
    local x, y = reaper.GetMousePosition()
    reaper.TrackCtl_SetToolTip("StudioSync: " .. text, x + 14, y + 14, true)
    sync.tip_at = reaper.time_precise() -- (Live sync takes it away after a few seconds: REAPER leaves it up)
  end
end
local function ext(proj, sec, key) return select(2, reaper.GetProjExtState(proj, sec, key)) end
local function setext(proj, sec, key, v) reaper.SetProjExtState(proj, sec, key, v) end
sync.ext, sync.setext = ext, setext

function sync.room_dir(cfg, song, room) return band.song_dir(cfg, song) .. "/rooms/" .. room end

-- Two changes to the timeline made at once on two machines arrive in opposite orders, so applying each as it
-- comes left every machine with the other's (2026-10-28 break round 2). The one stamped latest (time, then id) wins
-- everywhere: an older one arriving after it is skipped.
local function newest_key(ev)
  if ev.type == "timeline" then return "timeline" end -- (the tempo map and markers: ordered, so a computer whose clock ran ahead
  -- didn't make every later map look older. Review, 0.58.93)
end
-- The order is time..id, except that a change made here always comes after the newest one seen here (a machine
-- whose clock runs ahead would otherwise win over every later change).
local function order(ev) return ev.order or (ev.time .. ev.id) end
local function stamp(proj, ev)
  local k = newest_key(ev)
  if k and order(ev) > ext(proj, sync.NEWEST, k) then setext(proj, sync.NEWEST, k, order(ev)) end
end
local function superseded(proj, ev)
  local k = newest_key(ev)
  return k ~= nil and ext(proj, sync.NEWEST, k) > order(ev)
end

-- Events anyone may send, whoever drives or owns what: they change no take, track or timeline.
sync.ANYONE = { start = true, stop = true, note = true, like = true }
-- What the take sync before 0.32.0 sent: skipped (marked done) if a very old version still sends one.
sync.OLD_TYPES = { plays = true, track = true, mix = true, midi = true, delete = true, undelete = true, edit = true }
-- A take's author, from its id (<user>-YYYYMMDD-HHMMSSZ-n), normalised like user names in ids.
function sync.author(id) local who = (id or ""):match("^(.-)%-%d+%-%d+Z"); return who and who:lower():gsub("_", " ") end
function sync.author_of(user) return (user or ""):lower():gsub("_", " ") end

-- ---- state chunks: a top-level block (e.g. <FXCHAIN ... >) of a track's chunk -----------------------------
local function chunk_lines(s)
  local t = {}
  for l in ((s or "") .. "\n"):gmatch("(.-)\r?\n") do t[#t + 1] = l end
  if t[#t] == "" then t[#t] = nil end
  return t
end
local function find_block(L, tag)
  local depth, first = 0, nil
  for i, l in ipairs(L) do
    local t = l:match("^%s*(.-)%s*$")
    if t:sub(1, 1) == "<" then
      depth = depth + 1
      if depth == 2 and not first and (t == "<" .. tag or t:sub(1, #tag + 2) == "<" .. tag .. " ") then first = i end
    elseif t == ">" then
      if first and depth == 2 then return first, i end
      depth = depth - 1
    end
  end
end
-- The block's text (with its <TAG and > lines), or nil. Pure.
function sync.chunk_block(chunk, tag)
  local L = chunk_lines(chunk)
  local a, z = find_block(L, tag)
  return a and table.concat(L, "\n", a, z) or nil
end
-- The chunk with that block replaced by `block` (inserted before the track's end if absent; removed if nil). Pure.
function sync.chunk_set_block(chunk, tag, block)
  local L = chunk_lines(chunk)
  local a, z = find_block(L, tag)
  local out = {}
  if a then
    for i = 1, a - 1 do out[#out + 1] = L[i] end
    if block then out[#out + 1] = block end
    for i = z + 1, #L do out[#out + 1] = L[i] end
  else
    for i = 1, #L - 1 do out[#out + 1] = L[i] end
    if block then out[#out + 1] = block end
    out[#out + 1] = L[#L]
  end
  return table.concat(out, "\n")
end

-- ---- the timeline: tempo map and markers/regions ---------------------------------------------------
-- The driver's tempo or marker changes travel as one "timeline" event; every machine applies the same map and
-- REAPER moves (and, in its default "beats (position, length, rate)" timebase, stretches) each item exactly as it
-- would for a local tempo change. Positions also travel in quarter notes, so a take that crosses paths with a
-- tempo change still lands on its beat.
-- (the 4th part is the format: a signature noted in another format is a first look, never a change to send or put back. 3: the project's
-- settings, rt, so the first look after the update isn't taken for an edit of them. James, rt)
sync.TIMELINE_FORMAT = 6 -- (4: the recording-over-items choice joined the shared project settings: the first look after updating is not taken for an edit. James, rt; 5: the video settings, rt-video2; 6: markers' numbers and the region render matrix, rt-edits)
local function timeline_sig(proj) return band.json_encode({ band.capture_tempo(proj), band.capture_markers(proj), band.capture_project(proj), sync.TIMELINE_FORMAT }) end
-- The tempo map alone, said one way (round-tripped through JSON), to tell a tempo change from a marker or notes one: only a tempo change
-- moves parts by itself. Review, 0.58.87.
local function tempo_sig(tempo) return band.json_encode(band.json_decode(band.json_encode(tempo or {}))) end
sync.tempo_sig = tempo_sig
sync.timeline_sig = timeline_sig

function sync.qn(proj, pos) return reaper.TimeMap2_timeToQN(proj, pos) end

-- All band audio in the project (takes, prints, stems, live placeholders) follows tempo changes by REAPER's
-- auto-stretch when the project stretches audio (band.follow_tempo); existing items get it here, at Live sync start
-- and before a received tempo change.
function sync.audio_follow_tempo(proj)
  for i = 0, reaper.CountMediaItems(proj) - 1 do
    local it = reaper.GetMediaItem(proj, i)
    local tk = reaper.GetActiveTake(it)
    local tr = reaper.GetMediaItem_Track(it)
    if tk and (band.take_id(tk) or band.item_ext(it, "band_live") ~= "" or band.track_ext(tr, "band_stem") ~= "") then
      band.follow_tempo(it, tk)
    end
  end
end


-- The room's newest tempo map and markers, for a computer opening the song or checking what it holds: each computer keeps the last one IT
-- sent in a file of its own, rooms/<room>/timeline/<user>.json, and the newest stamp among them is the studio's (sync.studio_timeline). No file
-- has two writers, as with claims. It went into session.json, written by whichever computer changed the timeline: two changing it within
-- a second or two left Syncthing a session.sync-conflict copy, and the hub set session.json aside as "says it's James's, but another computer
-- wrote it" (James, 2026-11-20: no file that several computers write). session.json's timeline is still read (a computer on an older build
-- writes only that), and still written, in the main room, while anyone here is on a build that only reads that (sync.timeline_old_readers).
-- A side room's timeline no longer goes into session.json at all: it was read there as the main room's. rt-edits
-- `stamp_order`: the timeline event's order (time..id), so a computer opening the song can tell whether it already holds a newer map. James, rt
-- `project`: its settings (band.capture_project), for that same look. Crash-safe sessions, rt
local function user_file(user) return (tostring(user):gsub("[^%w%-_ ]", "")) .. ".json" end
function sync.timeline_path(cfg, song, room, user) return sync.room_dir(cfg, song, room) .. "/timeline/" .. user_file(user) end
-- This computer's own file says it reads these, before it has a timeline of its own to put in it (watch_timeline's first look).
function sync.timeline_reads(cfg, song, room)
  local path = sync.timeline_path(cfg, song, room, cfg.user)
  local have = band.read_json(path)
  if type(have) == "table" then return end
  reaper.RecursiveCreateDirectory(sync.room_dir(cfg, song, room) .. "/timeline", 0)
  band.write_json(path, { user = cfg.user, at = os.time(), reads = true })
end
-- Is anyone here now on a build that reads only session.json's timeline? They have no file in timeline/. Can't tell: yes, as before.
function sync.timeline_old_readers(cfg, song, room)
  local ok, peers = pcall(require("presence").peers, cfg, song, room)
  if not ok or type(peers) ~= "table" then return true end
  for _, st in ipairs(peers) do
    local theirs = type(st.user) == "string" and band.read_json(sync.timeline_path(cfg, song, room, st.user))
    if type(st.user) == "string" and type(theirs) ~= "table" then return true end
  end
  return false
end
-- -> the studio's newest timeline for the room, { tempo, markers, project, timeline_order } (session.json itself when its own is the newest,
-- or the only one: it may be unstamped, from before rt), or nil. A file counts only when it's named for the person it says and, where the
-- studio pins computers, that person's own computer wrote it (trust.own_file_ok, as for session.json's sharer); one not known yet is left out.
function sync.studio_timeline(cfg, song, room)
  local best
  local dir = sync.room_dir(cfg, song, room) .. "/timeline"
  for _, f in ipairs(band.files(dir, ".json")) do
    local t = band.read_json(dir .. "/" .. f)
    if type(t) == "table" and type(t.user) == "string" and user_file(t.user) == f and type(t.order) == "string" and type(t.tempo) == "table" and #t.tempo > 0
        and type(t.markers) == "table" and (not best or t.order > best.timeline_order) then
      local okt, mine = pcall(require("trust").own_file_ok, cfg.root, song .. "/rooms/" .. room .. "/timeline/" .. f, t.user, tonumber(t.at))
      if not okt or mine == true then
        best = { tempo = t.tempo, markers = t.markers, project = type(t.project) == "table" and t.project or nil, timeline_order = t.order, by = t.user }
      end
    end
  end
  local sj = room == "main" and band.read_json(band.session_path(cfg, song)) or nil
  if type(sj) == "table" and type(sj.tempo) == "table" and (not best or (sj.timeline_order ~= nil and tostring(sj.timeline_order) > best.timeline_order)) then return sj end
  return best
end
function sync.session_timeline(cfg, song, tempo, markers, stamp_order, project, room)
  room = room or "main"
  reaper.RecursiveCreateDirectory(sync.room_dir(cfg, song, room) .. "/timeline", 0)
  band.write_json(sync.timeline_path(cfg, song, room, cfg.user), { user = cfg.user, at = os.time(), order = stamp_order, tempo = tempo, markers = markers, project = project })
  if room ~= "main" or not sync.timeline_old_readers(cfg, song, room) then return end
  local sp = band.session_path(cfg, song)
  local s = band.read_json(sp)
  if s then
    s.first_timeline = s.first_timeline or { tempo = s.tempo, markers = s.markers } -- history restores before this need it
    s.tempo, s.markers, s.timeline_order, s.project = tempo, markers, stamp_order, project
    band.write_json(sp, s)
  end
end

-- Everything REAPER moved for a tempo change is where it should be: take new snapshots, so none of it is sent
-- as an edit. With only_tempo, an item whose beat position changed too (say "insert time" moved items and tempo
-- markers together) keeps its old snapshot, so the next look sends it as a real edit.
function sync.resnap(proj, only_tempo)
  for id, hit in pairs(band.take_index(proj)) do
    local tid = band.take_id(hit[2]) or id
    local was = tonumber(ext(proj, sync.SNAPQN, tid))
    local now = sync.qn(proj, reaper.GetMediaItemInfo_Value(hit[1], "D_POSITION"))
    if not only_tempo or not was or math.abs(now - was) < 1e-6 then sync.remember(proj, tid, hit[1], hit[2]) end
  end
end

-- The driver is whoever holds control of a room: the host, until someone runs "Take control".
function sync.driver(cfg, song, room, s)
  local d = band.read_json(sync.room_dir(cfg, song, room) .. "/driver.json")
  return d and d.driver or (s and s.host)
end
function sync.set_driver(cfg, song, room, user)
  reaper.RecursiveCreateDirectory(sync.room_dir(cfg, song, room), 0)
  band.write_json(sync.room_dir(cfg, song, room) .. "/driver.json", { driver = user, since = os.date("!%Y-%m-%dT%H:%M:%SZ") })
end

-- ---- who may change what ------------------------------------------------------------------------
-- People claim tracks and regions, each in their own file (rooms/<room>/claims/<user>.json: never two
-- writers on one file). A take may be changed by the owner of its track; else by the owner of the region
-- it starts in; else by the driver. The newest claim on a track or region wins.

local function base_name(track) return track and (track:gsub(" %(band%)$", ""):gsub(" %(studio%)$", "")) end
sync.base_name = base_name

function sync.claims_path(cfg, song, room, user)
  return sync.room_dir(cfg, song, room) .. "/claims/" .. (user:gsub("[^%w%-_ ]", "")) .. ".json"
end
-- nil + why when the file exists but can't be read right now (mid-sync, locked): callers must not write then,
-- or every other claim in it is lost (the likely end of a claim nobody released, 2026-10-28)
function sync.my_claims(cfg, song, room)
  local path = sync.claims_path(cfg, song, room, cfg.user)
  local c = band.read_json(path)
  if c then return c end
  if reaper.file_exists(path) then return nil, "your claims file is busy (syncing?): try again in a moment" end
  return { tracks = {}, regions = {}, times = {} }
end
-- Claims on tracks that are gone (deleted, or renamed): James, 2026-11-01, "automatically remove claims on deleted
-- tracks" (a claim on the Mac's deleted Scratch Mac stayed listed). Each machine drops its own (a claims file has
-- one writer), once it has caught up with the band and the track has been missing 30 s: a machine still catching up
-- may not have every track yet. Someone else's waits for them; the panel doesn't list it meanwhile. Returns how many.
sync.GONE_WAIT = 600 -- seconds a claimed track must stay missing (a whole-song Back takes it for a while: 30 s lost the claim for good when it came back: Mac, 0.42.5)
local missing_since = {} -- "tracks:<lower name>" -> when it was first missing here
function sync.drop_gone_claims(proj, cfg, song, room)
  if sync.pending_events(proj, cfg, song, room) ~= 0 or reaper.CountTracks(proj) == 0 then return 0 end
  local c = sync.my_claims(cfg, song, room)
  if not c then return 0 end
  local here = {}
  for i = 0, reaper.CountTracks(proj) - 1 do
    here[base_name(select(2, reaper.GetTrackName(reaper.GetTrack(proj, i)))):lower()] = true
  end
  local now, dropped = reaper.time_precise(), {}
  for _, k in ipairs({ "tracks", "prints" }) do
    local keep = {}
    for _, n in ipairs(c[k] or {}) do
      local key = k .. ":" .. n:lower()
      if here[n:lower()] then missing_since[key] = nil; keep[#keep + 1] = n
      -- (an auto-claim goes at once: it's for while you work on a track, and nothing has that name. A rename beaten by a bandmate's deletion
      -- left the renamer's on the new name, a name nothing had, through the track's return under its old one, until released by hand
      -- (rt-r2 P1-6, rt-r4). Back the track comes, the next edit claims it again. rt-fix9)
      elseif k == "tracks" and type(c.auto) == "table" and c.auto[key] then missing_since[key] = nil; c.auto[key] = nil; dropped[#dropped + 1] = n
      else
        missing_since[key] = missing_since[key] or now
        if now - missing_since[key] < sync.GONE_WAIT then keep[#keep + 1] = n else dropped[#dropped + 1] = n end
      end
    end
    c[k] = keep
  end
  if #dropped == 0 then return 0 end
  sync.set_claims(cfg, song, room, c)
  band.log("let go of your claim on " .. table.concat(dropped, ", ") .. ": no such track any more")
  return #dropped
end

-- Your claim on a track you renamed goes to its new name, keeping its date: dropped after GONE_WAIT, the claim was lost, and a new track
-- someone made under the old name took it over. -> whether it moved. 0.59.14
function sync.claim_renamed(cfg, song, room, from, to)
  local c = sync.my_claims(cfg, song, room)
  if not c then return false end
  from, to = base_name(from), base_name(to)
  local moved = false
  for _, k in ipairs({ "tracks", "prints" }) do
    local list, has = {}, false
    for _, n in ipairs(c[k] or {}) do if n:lower() == to:lower() then has = true end end
    for _, n in ipairs(c[k] or {}) do
      if n:lower() == from:lower() then
        moved = true
        if not has then list[#list + 1] = to; has = true end
      else list[#list + 1] = n end
    end
    c[k] = list
  end
  if moved then sync.set_claims(cfg, song, room, c, { [to:lower()] = from }) end
  return moved
end

-- A claim's key in `since`, `auto` and `dropped`: "tracks:bass", "regions:verse", "times:<from>|<to>".
function sync.claim_key(kind, n)
  if kind == "times" then return type(n) == "table" and string.format("times:%.6f|%.6f", tonumber(n.from) or 0, tonumber(n.to) or 0) or nil end
  return type(n) == "string" and (kind .. ":" .. n:lower()) or nil
end
sync.DROPPED_KEEP = 7 * 86400 -- seconds a claim you let go of is remembered against a given claim of it still read somewhere
-- `renamed` (optional): new lower name -> old name, whose claim date the new one keeps (sync.claim_renamed).
function sync.set_claims(cfg, song, room, claims, renamed)
  local now = os.date("!%Y-%m-%dT%H:%M:%SZ")
  -- each track/region keeps the date it was claimed: claiming something else later mustn't re-date (and so win
  -- back) an older contested claim
  local old = band.read_json(sync.claims_path(cfg, song, room, cfg.user)) or {}
  local since = {}
  for _, k in ipairs({ "tracks", "regions", "prints" }) do
    for _, name in ipairs(claims[k] or {}) do
      local was = k ~= "regions" and renamed and renamed[name:lower()] or name
      -- (or the date it carries in: a given claim folded in keeps the date it was given, sync.follow_claims. rt-edits)
      since[k .. ":" .. name:lower()] = (old.since or {})[k .. ":" .. name:lower()] or (old.since or {})[k .. ":" .. was:lower()]
        or (type(claims.since) == "table" and type(claims.since[k .. ":" .. name:lower()]) == "string" and claims.since[k .. ":" .. name:lower()]) or now
    end
  end
  claims.since = since
  -- (what you let go of, and when: a claim an admin gave you, folded in and then released from the panel, still counted where its given file
  -- was still read: a computer Syncthing hadn't told of the removal yet, or one holding the direct link's copy for its minute. sync.authority
  -- and sync.follow_claims pass over a given claim dated before you let go of it. Claimed again, it's no longer let go. rt-edits)
  local had, has, dropped = {}, {}, {}
  local cut = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - sync.DROPPED_KEEP)
  for k, t in pairs(type(old.dropped) == "table" and old.dropped or {}) do if type(k) == "string" and type(t) == "string" and t >= cut then dropped[k] = t end end
  local function keys(c, into, lasting) -- (lasting: auto-claims left out. A given claim is never one, and they lapse all day: lib/claimask.lua)
    local auto = type(c.auto) == "table" and c.auto or {}
    for _, kind in ipairs({ "tracks", "regions", "times" }) do
      for _, n in ipairs(type(c[kind]) == "table" and c[kind] or {}) do
        local k = sync.claim_key(kind, n)
        if k and not (lasting and (auto[k] ~= nil or (type(n) == "table" and n.auto ~= nil))) then into[k] = true end
      end
    end
  end
  keys(old, had, true)
  keys(claims, has)
  for k in pairs(had) do if not has[k] then dropped[k] = now end end
  for k in pairs(has) do dropped[k] = nil end
  -- (`let_go`: keys the caller lets go of though they may not be in your file: a claim given to you that only the direct link's copy has
  -- brought so far, released from the panel before Syncthing's file arrives and is folded in. It had nothing to remove, so it stayed yours.
  -- Backlog 1.8, James's default (b), rt-p1)
  for k in pairs(type(claims.let_go) == "table" and claims.let_go or {}) do if type(k) == "string" and not has[k] then dropped[k] = now end end
  claims.let_go = nil
  claims.dropped = next(dropped) and dropped or nil
  if type(claims.auto) == "table" then -- (auto-claims: only what's still claimed keeps its mark. lib/claimask.lua)
    local keep = {}
    for _, k in ipairs({ "tracks", "regions" }) do
      for _, name in ipairs(claims[k] or {}) do
        local key, was = k .. ":" .. name:lower(), k ~= "regions" and renamed and renamed[name:lower()]
        keep[key] = claims.auto[key] or (was and claims.auto[k .. ":" .. was:lower()]) or nil
      end
    end
    claims.auto = next(keep) and keep or nil
  end
  -- (each claimed track's id, under the name it has now: one let go or renamed away leaves no id behind. A stale one sent a later claim on that
  -- name after another track: sync.follow_claims. REAPER check, 0.59.49.73, rt-claims)
  if type(claims.oids) == "table" then
    local keep = {}
    for _, name in ipairs(claims.tracks or {}) do
      local was = renamed and renamed[name:lower()]
      keep[name:lower()] = (was and claims.oids[was:lower()]) or claims.oids[name:lower()] or nil
    end
    claims.oids = keep
  end
  claims.user, claims.time = cfg.user, now
  reaper.RecursiveCreateDirectory(sync.room_dir(cfg, song, room) .. "/claims", 0)
  band.write_json(sync.claims_path(cfg, song, room, cfg.user), claims)
  require("direct").send_live(cfg, "claim", claims, song, room) -- (in the others' claims at once: sync.live_claim. James, 0.60.0-rt)
end
-- Claims that came over the direct link: song/room -> user -> their claims, used by sync.authority while newer than (or as new as) that person's
-- claims file, which is the record. The same bar as the file: a claims file speaks only for the person it's named for. (James, 0.60.0-rt)
sync.live_claims = {}
sync.GIVEN_WAITS = true -- (follow_claims leaves a given claim's link copy alone: lib/signed.lua takes one for this computer's person only then)
function sync.live_claim(song, room, c)
  if type(c) ~= "table" or type(c.user) ~= "string" or type(c.time) ~= "string" or (c.since ~= nil and type(c.since) ~= "table") or c.given
      or (c.auto ~= nil and type(c.auto) ~= "table") then return false end
  for _, k in ipairs({ "tracks", "regions", "prints", "times" }) do
    if c[k] ~= nil and type(c[k]) ~= "table" then return false end
    for _, n in ipairs(c[k] or {}) do if type(n) ~= (k == "times" and "table" or "string") then return false end end
  end
  local key = tostring(song) .. "/" .. tostring(room)
  sync.live_claims[key] = sync.live_claims[key] or {}
  local had = sync.live_claims[key][c.user]
  if had and had.time > c.time then return false end
  sync.live_claims[key][c.user] = c
  return true
end

-- Claims the driver released for someone away (rooms/<room>/released.json: { user = time }): a claim made before
-- that time doesn't count. Only the driver writes it; a bandmate's own claims file stays theirs alone, and Live sync
-- empties it when they're back (James, 2026-10-31: someone who left the band kept their tracks locked for everyone).
-- (each releaser writes a file of their own, released/<them>.json, read together, the latest time per person: two writing the one file
-- within a sync lost one release, and a departed member's tracks stayed locked. Review, 0.58.53. released.json is read too, from before)
function sync.released(cfg, song, room)
  local rdir, out = sync.room_dir(cfg, song, room), {}
  local files = { rdir .. "/released.json" }
  for _, f in ipairs(band.files(rdir .. "/released", ".json")) do files[#files + 1] = rdir .. "/released/" .. f end
  for _, path in ipairs(files) do
    local r = band.read_json(path)
    if type(r) == "table" then
      for user, t in pairs(r) do if type(user) == "string" and type(t) == "string" and (not out[user] or t > out[user]) then out[user] = t end end
    end
  end
  return out
end
-- An admin gives someone a claim: their own claims file has one writer (them), so this is a file of its own, read as theirs by
-- sync.authority at once, even while they're away. Their Live sync folds it into their own file (sync.follow_claims) and removes it.
function sync.give_claims(cfg, song, room, user, tracks, regions, times)
  local dir = sync.room_dir(cfg, song, room) .. "/claims"
  reaper.RecursiveCreateDirectory(dir, 0)
  local now = os.date("!%Y-%m-%dT%H:%M:%SZ")
  local since = {}
  for _, n in ipairs(tracks or {}) do since["tracks:" .. n:lower()] = now end
  for _, n in ipairs(regions or {}) do since["regions:" .. n:lower()] = now end
  for _, t in ipairs(times or {}) do t.at = t.at or now end -- (a time claim carries its own date)
  band.write_json(string.format("%s/given-%s-%s.json", dir, (user:gsub("[^%w%-_ ]", "")), os.date("!%Y%m%d-%H%M%S")),
    { user = user, by = cfg.user, tracks = tracks or {}, regions = regions or {}, times = times or {}, since = since, time = now, given = true })
end
function sync.release_claims(cfg, song, room, user)
  local dir = sync.room_dir(cfg, song, room) .. "/released"
  reaper.RecursiveCreateDirectory(dir, 0)
  local path = dir .. "/" .. (cfg.user:gsub("[^%w%-_ ]", "")) .. ".json"
  local r = band.read_json(path)
  r = type(r) == "table" and r or {}
  r[user] = os.date("!%Y-%m-%dT%H:%M:%SZ")
  band.write_json(path, r)
end
-- Keep my claims on the tracks I claimed when they're renamed (a claim is by name; the track's id says which one
-- it was), and drop them if the driver released them while I was away. Run by Live sync every few seconds.
-- A given claim (claims/given-*.json) counts only from someone who may give it, and only as written by their own computer, as Syncthing tells it:
-- one naming an admin as its giver counted from anyone, and the person it named folded it into their own claims, where it was theirs for good.
-- Not known yet (Syncthing didn't say) is not yet. lib/trust.lua, Security review, 0.58.78.
local function given_ok(cfg, song, room, f, c)
  return type(c.by) == "string" and require("groups").may_manage(cfg.root, c.by)
    and require("trust").claim_ok(cfg.root, song .. "/rooms/" .. room .. "/claims/" .. f, c) == true
end
-- Is this given claim (its file's name, what it holds) for this person? By the name's start AND the person the file says it is for: the
-- name alone matched another's whose name starts with yours and a hyphen ("given-James-" is how "given-James-Laptop-..." starts too), so
-- James's computer folded James-Laptop's claim into its own and deleted the file before the laptop's Syncthing had it (rt-check3, 0.59.49.77).
function sync.given_for(f, g, user)
  local prefix = "given-" .. (tostring(user):gsub("[^%w%-_ ]", "")) .. "-"
  return f:sub(1, #prefix) == prefix and type(g) == "table" and g.user == user
end
function sync.follow_claims(proj, cfg, song, room)
  do -- claims an admin gave me, into my own file
    local dir, prefix = sync.room_dir(cfg, song, room) .. "/claims", "given-" .. (cfg.user:gsub("[^%w%-_ ]", "")) .. "-"
    for _, f in ipairs(band.files(dir, ".json")) do
      -- (not the direct link's copy of one, read here until Syncthing's file comes: it isn't a file, so the removal below did nothing and it
      -- was folded in again on every pass. sync.authority counts it meanwhile, so it's yours to edit at once; it's folded in, once, when
      -- the folder's file is here. sync.GIVEN_WAITS says so to lib/signed.lua. rt-linkmove's hook 1, rt-edits)
      if f:sub(1, #prefix) == prefix and not band.overlay_of(dir .. "/" .. f) then
        local g, c = band.read_json(dir .. "/" .. f), sync.my_claims(cfg, song, room)
        if sync.given_for(f, g, cfg.user) and c and given_ok(cfg, song, room, f, g) then
          -- (dated as given: folding it in must not make it newer than a claim someone made since, nor than a release. Folded with the day's
          -- date, a claim the driver released while you were away (released/) counted again from the fold. And not what you let go of after it
          -- was given (`dropped`, sync.set_claims): sync.authority passes over both alike. rt-edits)
          local gone, dropped = sync.released(cfg, song, room)[cfg.user], type(c.dropped) == "table" and c.dropped or {}
          local function stands(k, t) return type(t) == "string" and not (gone and t <= gone) and not (type(dropped[k]) == "string" and dropped[k] >= t) end
          local words = {}
          c.since = type(c.since) == "table" and c.since or {}
          for _, kind in ipairs({ "tracks", "regions" }) do
            c[kind] = c[kind] or {}
            for _, n in ipairs(g[kind] or {}) do
              local k = sync.claim_key(kind, n)
              local t = k and (type(g.since) == "table" and g.since[k] or g.time)
              if k and stands(k, t) then
                local have = false
                for _, m in ipairs(c[kind]) do have = have or m:lower() == n:lower() end
                if not have then c[kind][#c[kind] + 1] = n end
                c.since[k] = c.since[k] or t
                words[#words + 1] = (kind == "regions" and "region " or "") .. n
              end
            end
          end
          c.times = c.times or {}
          local any_time = false
          for _, t in ipairs(g.times or {}) do
            local k = sync.claim_key("times", t)
            local have = false
            for _, x in ipairs(c.times) do have = have or sync.claim_key("times", x) == k end
            if k and not have and stands(k, t.at or g.time) then t.at = t.at or g.time; c.times[#c.times + 1] = t; any_time = true end
          end
          if any_time then words[#words + 1] = "a stretch of time" end
          if #words > 0 then sync.set_claims(cfg, song, room, c) end
          os.remove(dir .. "/" .. f)
          os.remove(dir .. "/" .. f .. ".sig") -- (its signature file: every given claim left one in claims/ for good. rt-linkmove's hook 2)
          if #words > 0 then band.log(tostring(g.by) .. " gave you " .. table.concat(words, ", ") .. ": yours to change now") end
        end
      end
    end
  end
  local c = sync.my_claims(cfg, song, room)
  if not c or #(c.tracks or {}) + #(c.regions or {}) + #(c.times or {}) == 0 then return end
  local gone = sync.released(cfg, song, room)[cfg.user]
  if gone and (c.time or "") <= gone then
    sync.set_claims(cfg, song, room, { tracks = {}, regions = {}, times = {} })
    return band.log("the driver released your claims while you were away: claim again what you're working on")
  end
  -- (not while its first catch-up runs: a file reopened from before your rename still has the old name, and the claim went back to it until
  -- your rename came in again. Crash-safe sessions, James, rt)
  if sync.loading[tostring(proj)] then return end
  local mirror = require("mirror")
  c.oids, c.since = c.oids or {}, c.since or {}
  local changed, renamed = false, {}
  for i, name in ipairs(c.tracks or {}) do
    local k = name:lower()
    local oid = c.oids[k]
    local tr = oid and mirror.find(proj, "track", oid)
    if not oid then -- (claimed before 0.34: find it by name, once)
      for t = 0, reaper.CountTracks(proj) - 1 do
        local x = reaper.GetTrack(proj, t)
        if base_name(select(2, reaper.GetTrackName(x))):lower() == k then oid, tr = mirror.track_oid(x), x; break end
      end
      if oid and oid ~= "" then c.oids[k], changed = oid, true end
    end
    local now = tr and base_name(select(2, reaper.GetTrackName(tr)))
    if now and now ~= "" and now:lower() ~= k then -- renamed: the claim goes with it, keeping its date
      c.tracks[i] = now
      c.oids[now:lower()], c.oids[k] = oid, nil
      c.since["tracks:" .. now:lower()], c.since["tracks:" .. k] = c.since["tracks:" .. k], nil
      changed, renamed[now:lower()] = true, name
    end
  end
  -- (a rename: through set_claims, so its date, its auto-claim mark and its id go to the new name and everyone has it at once over the link.
  -- Written straight to the file, an auto-claim turned lasting and the others kept the old name until Syncthing brought the file. rt-claims)
  if next(renamed) then sync.set_claims(cfg, song, room, c, renamed)
  elseif changed then band.write_json(sync.claims_path(cfg, song, room, cfg.user), c) end
end

-- Returns can(user, track, pos, take) -> bool, plus { driver, tracks, regions, times, owner(track, pos) } for display.
-- Who owns a take: its track's claimant, else the newest claim on a stretch of time it starts in (a time selection),
-- else the claimant of the named region it starts in, else the driver. A take's author may change it (move, trim,
-- mute) wherever nobody has claimed it that way.
-- How a room shares editing, set by the studio's owner or an admin (rooms/<room>/mode.json). Four since rt (James, 2026-11-20: "keep open for
-- disabling all claims and completely open editing. Admins only makes sense too"; docs/rt/rt-audit.md §7). The names on disk are older
-- than the panel's:
--   "open"      Claims, the default: anyone changes anything nobody else has claimed (the newest change wins), the tempo map and markers too.
--               What you edit becomes your claim while you work on it, and an edit to someone else's asks them for it (lib/claimask.lua)
--   "everyone"  Open: claims off, anyone changes anything (claims are kept but don't hold; no auto-claims, no asks)
--   "driver"    Driver only: only the driver changes what the band has (claims are kept, but don't count while it's on)
--   "admins"    only the group's owner and admins, whoever an admin let edit in this room (lib/grants.lua), and everyone on what's been
--               claimed for them (lib/groups.lua; an admin can give a claim)
-- Changes someone may not make are put back where the band has them, never kept on their machine only.
-- A room saved on a mode since removed reads as the nearest one left (OLD_MODES), said once a session in the log; mode.json isn't rewritten
-- (only the owner or an admin writes it: their next pick does).
sync.MODES = { driver = true, open = true, everyone = true, admins = true }
sync.OLD_MODES = { claims = "driver" } -- (Driver + claims -> Driver only)
sync.OLD_NAMES = { claims = "Driver + claims" }
sync.DEFAULT_MODE = "open"
sync.AUTO_IDLE = 600 -- seconds without an edit before an auto-claim stops counting (lib/claimask.lua)
local mode_said = {}
function sync.mode(cfg, song, room)
  local m = band.read_json(sync.room_dir(cfg, song, room) .. "/mode.json")
  m = type(m) == "table" and m.mode
  local now = sync.OLD_MODES[m]
  if now then
    local k = tostring(song) .. "/" .. tostring(room) .. "/" .. m
    if not mode_said[k] and band.log then
      mode_said[k] = true
      band.log("'" .. tostring(room) .. "' was set to " .. sync.OLD_NAMES[m] .. ", which StudioSync no longer has: it works as " ..
        "Driver only now (the owner or an admin can pick another under Who controls)")
    end
    return now
  end
  return sync.MODES[m] and m or sync.DEFAULT_MODE
end
function sync.set_mode(cfg, song, room, mode, user)
  band.write_json(sync.room_dir(cfg, song, room) .. "/mode.json", { mode = mode, by = user, time = os.date("!%Y-%m-%dT%H:%M:%SZ") })
end

-- Every claims file in `dir` -> { { f, c } } in name order, c as band.read_json gives it (nil when unreadable). Asked each pass and each
-- second by the web UI, so a file is read again only when its size or modified time moves (js_ReaScriptAPI's JS_File_Stat; without it,
-- read every time as before). Modified times are to the second, and Syncthing copies a bandmate's: two same-size writes in one second
-- would look alike, so a file is trusted from cache only once it was read CLAIMS_SETTLE s after its time. The listing is band.listing's
-- (a fraction of a second, longer while the folder's time stands still). The tables are shared: never change them. (James, rt)
sync.CLAIMS_SETTLE = 60
local claims_cache = {} -- dir -> f -> { key, c, settled }
function sync.claims_files(dir)
  local stat = reaper and reaper.JS_File_Stat
  local names = band.listing and band.listing(dir, ".json", true) or band.files(dir, ".json")
  local was, now_c, out = claims_cache[dir] or {}, {}, {}
  for _, f in ipairs(names) do
    local path, c = dir .. "/" .. f, nil
    if stat then
      local ok, status, size, _, mt = pcall(stat, path)
      local key = ok and status == 0 and tostring(size) .. "|" .. tostring(mt) or nil
      local e = was[f]
      local linked = band.overlay_of and band.overlay_of(path)
      if key and e and e.key == key and e.settled and not linked then c = e.c
      else
        c = band.read_json(path)
        -- (a read that failed, the file busy mid-replace, isn't kept: it would hide that claim until the file changed again)
        -- (nor the direct link's copy, read in place of the folder's file until that changes: the cache returned the folder's older words, and
        -- kept under the folder file's size and time, the copy's would outlive it. lib/signed.lua, rt-linkmove3)
        e = key and c and not linked and { key = key, c = c, settled = (band.file_age(mt) or -1) >= sync.CLAIMS_SETTLE } or nil
      end
      now_c[f] = e
    else
      c = band.read_json(path)
    end
    out[#out + 1] = { f, c }
  end
  claims_cache[dir] = now_c -- (only what's listed now: a removed file's entry goes with it)
  return out
end
function sync.authority(cfg, song, room, s)
  local driver = sync.driver(cfg, song, room, s)
  local mode = sync.mode(cfg, song, room)
  local tracks, regions, times = {}, {}, {} -- lower name -> { user, time }; times: { user, time, from, to }
  local printers = {} -- lower track name -> { user, time, name }: who's in charge of printing it (lib/prints.lua)
  local dir = sync.room_dir(cfg, song, room) .. "/claims"
  local released = sync.released(cfg, song, room) -- (claims the driver let go of for someone who was away)
  local list, live, from_file = {}, sync.live_claims[song .. "/" .. room] or {}, {}
  for _, fc in ipairs(sync.claims_files(dir)) do
    local f, c = fc[1], fc[2]
    -- (a claims file speaks only for the person it's named for, or it's one an admin gave: claims/<anything>.json saying user "James"
    -- spoke for James. Review, 0.58.53)
    if c and type(c.user) == "string" and not (f:find("^given%-") or (c.user:gsub("[^%w%-_ ]", "")) .. ".json" == f) then c = nil end
    -- (and a given one counts only from someone who may give it, as the panel only lets them: anyone could write given-me.json. Review, 0.58.62)
    if c and f:find("^given%-") and not given_ok(cfg, song, room, f, c) then c = nil end -- (and from their computer: 0.58.78)
    -- (their newer claims, over the direct link, until this file says as much: sync.live_claim. James, 0.60.0-rt)
    if c and type(c.user) == "string" and not f:find("^given%-") then
      from_file[c.user] = true
      local l = live[c.user]
      if l and type(c.time) == "string" and l.time > c.time then c = l end
    end
    list[#list + 1] = c
  end
  for user, l in pairs(live) do if not from_file[user] then list[#list + 1] = l end end
  -- (what each person let go of, by their own claims: their given claim dated before that doesn't count. sync.set_claims, rt-edits)
  local dropped_by = {}
  for _, c in ipairs(list) do if c and not c.given and type(c.user) == "string" and type(c.dropped) == "table" then dropped_by[c.user] = c.dropped end end
  -- (an auto-claim counts while its last edit is under AUTO_IDLE old: on every computer alike, whether or not its owner's Live sync has
  -- dropped it yet. lib/claimask.lua, James, rt)
  local idle_cut = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - sync.AUTO_IDLE)
  for _, c in ipairs(list) do
    if c and c.user and c.time then
      local gone = released[c.user]
      local auto = type(c.auto) == "table" and c.auto or {}
      local dg = c.given and dropped_by[c.user]
      local function let_go(k, t) local d = dg and k and dg[k]; return type(d) == "string" and type(t) == "string" and d >= t end
      for _, t in ipairs(c.times or {}) do
        local at = t.at or c.time
        if tonumber(t.from) and tonumber(t.to) and t.to > t.from and not (gone and at <= gone) and not let_go(sync.claim_key("times", t), at) and not (t.auto ~= nil and not (type(t.auto) == "string" and t.auto >= idle_cut)) then
          times[#times + 1] = { user = c.user, time = at, from = t.from, to = t.to, auto = t.auto ~= nil or nil }
        end
      end
      for _, name in ipairs(c.prints or {}) do -- (newest wins, as for tracks)
        local k = name:lower()
        local t = (c.since or {})["prints:" .. k] or c.time
        local o = printers[k]
        if not (gone and t <= gone) and (not o or o.time < t or (o.time == t and less(o.user, c.user))) then printers[k] = { user = c.user, time = t, name = name } end
      end
      for _, list in ipairs({ { c.tracks, tracks }, { c.regions, regions } }) do
        for _, name in ipairs(list[1] or {}) do
          local k = name:lower()
          local kk = (list[2] == tracks and "tracks:" or "regions:") .. k
          local t = (c.since or {})[kk] or c.time
          local o = list[2][k] -- newest wins; the same second goes to the later name, so every machine agrees
          local a = auto[kk]
          if not (gone and t <= gone) and not let_go(kk, t) and not (a ~= nil and not (type(a) == "string" and a >= idle_cut))
              and (not o or o.time < t or (o.time == t and less(o.user, c.user))) then list[2][k] = { user = c.user, time = t, name = name, auto = a ~= nil or nil } end
        end
      end
    end
  end
  local spans = {} -- the song's regions, from the publish
  for _, m in ipairs((s and s.markers) or {}) do
    if m.region then spans[#spans + 1] = { name = m.name:lower(), from = m.pos, to = m["end"] } end
  end
  table.sort(times, function(x, y) -- the newest claim on a stretch wins (same second: the later name, as for tracks)
    if x.time ~= y.time then return x.time > y.time end
    return less(y.user, x.user)
  end)
  -- (`at`, optional, a change's own time: a claim made after it doesn't count. A change is judged by the claims as they stood when it was
  -- made, as far as today's files say: by today's, a late joiner refused James's whole track because Cee claimed it an hour after he made
  -- it, and showed the song without it for the minute a refused change waits; and a computer whose own auto-claim came after a bandmate's
  -- edit held that edit back a minute. The soak's bug 3. A claim that was there then and is released since is no longer known, and doesn't
  -- refuse either. sync.receive passes it; a look judges this person's own edit by the claims now. rt-converge)
  -- (nor one made in the same second: the times are whole seconds from two clocks, and a claim that young hadn't reached the change's
  -- maker. Two edits 20 ms apart, each auto-claiming, held each other's change back a minute: P1-1 and P1-2's "61 s", rt-r2. Since nothing
  -- is refused on receive (rt-sync2h), `at` only decides sync.receive's "which you've claimed ... didn't ask" word, and these keep it from
  -- naming a change made before the claim could reach its maker)
  local function then_(c, at) return c and not (at and type(c.time) == "string" and c.time >= at) and c or nil end
  local function in_time(pos, at)
    for _, t in ipairs(pos and times or {}) do if pos >= t.from and pos < t.to and then_(t, at) then return t end end
  end
  local function owner(track, pos, drv, at)
    local t = base_name(track)
    local c = t and then_(tracks[t:lower()], at)
    if c then return c.user end
    local tc = in_time(pos, at)
    if tc then return tc.user end
    if pos then
      for _, sp in ipairs(spans) do
        if pos >= sp.from and pos < sp.to and then_(regions[sp.name], at) then return regions[sp.name].user end
      end
    end
    return drv or driver
  end
  local function claimed(track, pos, at)
    local t = base_name(track)
    if t and then_(tracks[t:lower()], at) then return true end
    if in_time(pos, at) then return true end
    for _, sp in ipairs(pos and spans or {}) do
      if pos >= sp.from and pos < sp.to and then_(regions[sp.name], at) then return true end
    end
  end
  local granted = mode == "admins" and require("grants").list(cfg, song, room) or {} -- (Admins only: who an admin let edit in this room)
  sync.owner_of = owner -- for messages ("... is James's to change")
  sync.is_claimed = claimed -- (sync.maker_may)
  return function(user, track, pos, take, drv, at) -- drv: the driver to judge by (an event's own time), else today's; at: that time, for claims
      if mode == "driver" then return user == (drv or driver) end
      if mode == "everyone" then return true end -- (Open: claims off)
      if mode == "admins" then
        if claimed(track, pos, at) then return owner(track, pos, drv, at) == user end
        return require("groups").may_manage(cfg.root, user) or granted[user] ~= nil -- (or let edit here by an admin: lib/grants.lua)
      end
      if owner(track, pos, drv, at) == user then return true end
      -- open: anything nobody claimed, by anyone, the song's tempo map, markers and settings too (James, 2026-10-31:
      -- Open means open; before, those stayed the driver's)
      if mode == "open" and not claimed(track, pos, at) then return true end
      return take ~= nil and sync.author(take) == sync.author_of(user) and not claimed(track, pos, at)
    end,
    -- (is_claimed and owner_of: this room's, for callers to pass on. The module's sync.is_claimed / sync.owner_of are the last call's, and one
    -- for another room in between judged this one by that room's claims. They stay, for callers not passing these yet. Round 1 review, 0.59.45)
    { driver = driver, tracks = tracks, regions = regions, times = times, owner = owner, spans = spans, mode = mode, printers = printers,
      is_claimed = claimed, owner_of = owner, granted = granted }
end

-- Show the time claims as regions named "[claimed: <user>]" (this machine only; see band.CLAIM_MARK). Redrawn
-- only when they change.
function sync.draw_claims(proj, times)
  local want, have = {}, {}
  for _, t in ipairs(times or {}) do want[#want + 1] = string.format("%s%s]|%.6f|%.6f", band.CLAIM_MARK, t.user, t.from, t.to) end
  table.sort(want)
  for i = 0, reaper.CountProjectMarkers(proj) - 1 do
    local _, rgn, p, e, name = reaper.EnumProjectMarkers3(proj, i)
    if rgn and band.is_claim_mark(name) then have[#have + 1] = string.format("%s|%.6f|%.6f", name, p, e) end
  end
  table.sort(have)
  if table.concat(want, "\n") == table.concat(have, "\n") then return false end
  for i = reaper.CountProjectMarkers(proj) - 1, 0, -1 do
    local _, _, _, _, name = reaper.EnumProjectMarkers3(proj, i)
    if band.is_claim_mark(name) then reaper.DeleteProjectMarkerByIndex(proj, i) end
  end
  for _, t in ipairs(times or {}) do
    reaper.AddProjectMarker2(proj, true, t.from, t.to, band.CLAIM_MARK .. t.user .. "]", -1, reaper.ColorToNative(230, 150, 40) | 0x1000000)
  end
  return true
end

-- ---- where a take sits ---------------------------------------------------------------------------

-- REAPER's lane play state isn't per lane (verified 7.83): setting a lane to 1 plays it exclusively and
-- silences the others, setting any lane to 2 makes every lane play. A track plays one lane, or all.
local function set_lanes_playing(tr, lanes)
  local n = reaper.GetMediaTrackInfo_Value(tr, "I_NUMFIXEDLANES")
  if #lanes == 0 then
    for l = 0, n - 1 do reaper.SetMediaTrackInfo_Value(tr, "C_LANEPLAYS:" .. l, 0) end
  elseif #lanes == 1 then
    reaper.SetMediaTrackInfo_Value(tr, "C_LANEPLAYS:" .. lanes[1], 1)
  else
    reaper.SetMediaTrackInfo_Value(tr, "C_LANEPLAYS:" .. lanes[1], 2)
  end
end
local function lanes_playing(tr)
  local on = {}
  for l = 0, reaper.GetMediaTrackInfo_Value(tr, "I_NUMFIXEDLANES") - 1 do
    if reaper.GetMediaTrackInfo_Value(tr, "C_LANEPLAYS:" .. l) ~= 0 then on[#on + 1] = l end
  end
  return on
end

local function lane_of(it)
  local tr = reaper.GetMediaItem_Track(it)
  if reaper.GetMediaTrackInfo_Value(tr, "I_FREEMODE") ~= 2 or reaper.GetMediaTrackInfo_Value(tr, "I_NUMFIXEDLANES") < 2 then return nil end
  return math.floor(reaper.GetMediaItemInfo_Value(it, "I_FIXEDLANE"))
end
local function track_name(it) return base_name(select(2, reaper.GetTrackName(reaper.GetMediaItem_Track(it)))) end
local function shape(it, tk)
  return string.format("%.6f|%.6f|%.6f|%s|%d|%s", reaper.GetMediaItemInfo_Value(it, "D_POSITION"), reaper.GetMediaItemInfo_Value(it, "D_LENGTH"),
    reaper.GetMediaItemTakeInfo_Value(tk, "D_STARTOFFS"), tostring(lane_of(it)), reaper.GetMediaItemInfo_Value(it, "B_MUTE"), track_name(it))
end
function sync.remember(proj, id, it, tk)
  setext(proj, sync.SNAP, id, id .. "|" .. shape(it, tk))
  setext(proj, sync.SNAPQN, id, string.format("%.9f", sync.qn(proj, reaper.GetMediaItemInfo_Value(it, "D_POSITION"))))
  setext(proj, "BandSync.base", id, string.format("%.9f", band.base_offs(tk))) -- (a take that comes back is trimmed as it was)
end

-- One StudioSync track per name speaks for it: our real "Vox", not the "Vox (band)" mirror beside it.
local function speaks_for_name(proj, tr)
  if band.track_ext(tr, "band_mirror") == "" then return true end
  local name = select(2, reaper.GetTrackName(tr))
  return not band.find_track(proj, base_name(name), true) or base_name(name) == name
end
sync.speaks_for_name = speaks_for_name



-- Render one take as the song prints it and post it as revision `rev` of `id`.
--   wet: through its track's FX, volume and pan, at the item's exact extent
--   dry: take FX, fades and item volume only        both: wet, plus the dry print as a twin
-- Render source 32 ("selected media items") runs the item through its TRACK (FX, volume, pan; verified
-- 7.83), so a dry print bypasses the track's FX and neutralises its volume/pan for the render.
-- Works on the active tab only (REAPER renders the active project).
-- `twin`: printing someone's MIDI copy with our own instrument; it's the original track's name.
local function selection(proj)
  local sel = {}
  for i = 0, reaper.CountSelectedMediaItems(proj) - 1 do sel[#sel + 1] = reaper.GetSelectedMediaItem(proj, i) end
  return sel
end

-- The tempo map and markers as they were at entries[upto] (the newest change of them by then, else the session's own), for
-- the whole song going back: they stayed as they were (laptop, 0.42.5). Only the driver's to change. -> whether it changed them.
-- `from`: the room `entries` are the history of, when that isn't `room` (a new room made from a moment in another's).
-- `act`: the Restore's act, on its timeline change too, so "Undo this change" on one of its rows takes the map back (lib/page_restore.lua).
function sync.restore_timeline(proj, cfg, song, room, entries, upto, session, from, act)
  local t
  for i = 1, math.min(upto, #entries) do
    local e = entries[i]
    if e.kind == "timeline" and e.tempo then t = e end
  end
  -- A side room's history starts where it was made, not at the song's start. With no tempo change in it yet, the song's first map
  -- isn't what it had: all that follow the tempo stretched, went out and printed again (34 events for a one-item undo: Mac, 0.45.0).
  local meta = not t and band.read_json(sync.room_dir(cfg, song, from or room) .. "/room.json")
  if meta and meta.parent then
    if not meta.tempo then return false end -- (made before rooms noted it: what it has now is the best guess)
    t = meta
  end
  -- (before the song's first tempo change: the session file only holds the newest map. The Bridge's tempo stayed: laptop, 0.42.6)
  t = t or (session and session.first_timeline) or session
  if not (t and t.tempo) then return false end
  -- (the signature's first two parts: it holds the project's settings too, so this never matched, and every restore sent a timeline)
  local now = band.json_decode(sync.timeline_sig(proj))
  if type(now) == "table" and band.json_encode({ t.tempo, t.markers or {} }) == band.json_encode({ now[1], now[2] }) then return false end
  sync.audio_follow_tempo(proj)
  -- (what REAPER moves for the map reads the same in beats, so it's nobody's edit and nothing goes out for it: every receiver moves its own.
  -- lib/beats.lua, rt-sync2f)
  band.apply_tempo(proj, t.tempo)
  band.apply_markers(proj, t.markers or {})
  -- (restored: a Restore, not a change StudioSync's Undo steps back, as a restored object isn't: mirror.last_mine. rt-edits)
  sync.post(cfg, song, room, { type = "timeline", tempo = t.tempo, markers = t.markers or {}, restored = true, act = act }, proj) -- (proj: ordered after the newest map seen here. Review, 0.58.95)
  sync.setext(proj, band.SECTION, "timeline", sync.timeline_sig(proj))
  return true
end

-- Give the driver's seat to a bandmate here: the driver can hand over, not only the other person take it (laptop, 0.42.5).
function sync.hand_over(proj, cfg, song, room, to)
  require("recall").save(proj, cfg, song, room, "before " .. to .. " took over from " .. cfg.user)
  sync.set_driver(cfg, song, room, to)
  sync.post(cfg, song, room, { type = "driver", from = cfg.user, driver = to })
  band.log(to .. " is driving '" .. song .. "' now")
end

-- A track's mix automation (volume, pan, width, mute, after its plug-ins) is off for a print, as its fader is: it travels with
-- the track, so printed too it applied twice on whoever plays the print (11 dB on Drums: laptop, 0.42.4). -> what puts it back.
function sync.mix_envelopes_off(tr)
  local back = {}
  -- (Trim Volume too: it's after the plug-ins, like Volume, and stayed on where the print plays, so it applied twice. Plug-ins review, 0.58.76)
  for _, name in ipairs({ "Volume", "Pan", "Width", "Mute", "Trim Volume" }) do
    local env = reaper.GetTrackEnvelopeByName(tr, name)
    if env then
      local ok, chunk = reaper.GetEnvelopeStateChunk(env, "", false)
      if ok and chunk:find("\nACT 1", 1, true) then
        reaper.SetEnvelopeStateChunk(env, (chunk:gsub("\nACT 1", "\nACT 0", 1)), false)
        back[#back + 1] = function() reaper.SetEnvelopeStateChunk(env, chunk, false) end
      end
    end
  end
  return function() for _, f in ipairs(back) do f() end end
end

-- Render item `it` (its active take, which must be selected alone) to <out>/<name>.flac (+ .opus).
-- `bare`: without the item's own volume and fades (a wet take: the item applies them to whichever take plays).
local function render_item(it, take, out, name, wet, tail, bare)
  local tr = reaper.GetMediaItem_Track(it)
  local nch = reaper.GetMediaSourceNumChannels(reaper.GetMediaItemTake_Source(take))
  do
    -- leftovers would make REAPER stop on a modal "files exist" warning; one REAPER still holds open can't be
    -- removed, so that render takes a fresh name instead
    local base = name
    for n = 2, 99 do
      os.remove(out .. "/" .. name .. ".flac"); os.remove(out .. "/" .. name .. ".opus")
      if not reaper.file_exists(out .. "/" .. name .. ".flac") and not reaper.file_exists(out .. "/" .. name .. ".opus") then break end
      name = base .. "-" .. n
    end
    local keys = { "B_MUTE", "I_FXEN", "D_VOL", "D_PAN" }
    local saved, imute, lane = {}, reaper.GetMediaItemInfo_Value(it, "B_MUTE"), lane_of(it)
    for _, k in ipairs(keys) do saved[k] = reaper.GetMediaTrackInfo_Value(tr, k) end
    local playing = lane and lanes_playing(tr)
    -- an alternate in a silent lane, or a muted item/track, must still print
    reaper.SetMediaTrackInfo_Value(tr, "B_MUTE", 0)
    reaper.SetMediaItemInfo_Value(it, "B_MUTE", 0)
    if lane then reaper.SetMediaTrackInfo_Value(tr, "C_LANEPLAYS:" .. lane, 1) end
    if not wet then reaper.SetMediaTrackInfo_Value(tr, "I_FXEN", 0)
    else -- (the band's FX button, if it's held off here while a wet take plays: lib/prints.lua hold_fx)
      local held = band.track_ext(tr, "band_fxen")
      if held ~= "" then reaper.SetMediaTrackInfo_Value(tr, "I_FXEN", tonumber(held) or 1) end
    end
    local item_was = {}
    if bare then
      for _, k in ipairs({ "D_VOL", "D_FADEINLEN", "D_FADEOUTLEN", "D_FADEINLEN_AUTO", "D_FADEOUTLEN_AUTO" }) do
        item_was[k] = reaper.GetMediaItemInfo_Value(it, k)
        reaper.SetMediaItemInfo_Value(it, k, k == "D_VOL" and 1 or 0)
      end
    end
    -- the track's fader and pan aren't printed: they travel as the shared mix (track events), so moving a fader
    -- never re-renders anything, and everyone's mirror track carries the same setting
    reaper.SetMediaTrackInfo_Value(tr, "D_VOL", 1)
    reaper.SetMediaTrackInfo_Value(tr, "D_PAN", 0)
    -- the print is this item only: whatever else feeds the track (a synth routed in to record it) stays out of it
    -- (2026-10-28: Keys/Lead prints carried their source synth too, so they played twice on everyone else's machine)
    local receives = {}
    for r = 0, reaper.GetTrackNumSends(tr, -1) - 1 do
      receives[r] = reaper.GetTrackSendInfo_Value(tr, -1, r, "B_MUTE")
      reaper.SetTrackSendInfo_Value(tr, -1, r, "B_MUTE", 1)
    end
    local envs_back = sync.mix_envelopes_off(tr)
    -- (whatever the render does, everything set aside for it comes back: an error here left the track muted, its item's fades at zero
    -- and its envelopes off, and the next save kept them. Review, 0.58.87)
    local okr, err = pcall(band.render, { RENDER_SETTINGS = 32, RENDER_BOUNDSFLAG = 4, RENDER_SRATE = 0, RENDER_CHANNELS = wet and 2 or math.min(nch, 2),
      RENDER_TAILFLAG = tail and 16 or 0, RENDER_TAILMS = tail and math.floor(tail * 1000) or 0, -- 16: tail for selected items
      RENDER_ADDTOPROJ = 0 }, -- &32: selected media items, through their track
      { RENDER_FILE = out, RENDER_PATTERN = name, RENDER_FORMAT = band.FLAC, RENDER_FORMAT2 = band.OPUS })
    envs_back()
    for _, k in ipairs(keys) do reaper.SetMediaTrackInfo_Value(tr, k, saved[k]) end
    for r, m in pairs(receives) do reaper.SetTrackSendInfo_Value(tr, -1, r, "B_MUTE", m) end
    reaper.SetMediaItemInfo_Value(it, "B_MUTE", imute)
    for k, v in pairs(item_was) do reaper.SetMediaItemInfo_Value(it, k, v) end
    if lane then set_lanes_playing(tr, playing) end
    if not okr then error(err, 0) end
    return out .. "/" .. name
  end
end

-- Print one take through its track (wet) to <out>/<name>.flac, leaving selection and the playing take as they
-- were. Returns the .flac path, or nil. Active tab only. (Solo edit keeps wet prints beside dry recordings.)
function sync.print_item(proj, it, take, out, name, tail, dry, bare) -- (dry: the take's own plug-ins only, not its track's)
  local sel, playing = selection(proj), reaper.GetActiveTake(it)
  -- (the screen held still meanwhile: each part flashed selected and back, one after another across the project, whenever prints
  -- rendered here rather than in the background. James, 0.58.85)
  reaper.PreventUIRefresh(1)
  reaper.SetActiveTake(take)
  -- (one by one: SelectAllMediaItems on a selected item leaves an undo point, "Unselect all items", on top of the edit
  -- being printed, so Ctrl+Z undid that and took the print with it, and the note stayed moved: PC, 0.41.0)
  for _, s in ipairs(sel) do reaper.SetMediaItemSelected(s, false) end
  reaper.SetMediaItemSelected(it, true)
  local okr, base = pcall(render_item, it, take, out, name, not dry, tail, bare) -- (the hold always let go, whatever the render does)
  reaper.SetActiveTake(playing)
  reaper.SetMediaItemSelected(it, false)
  for _, s in ipairs(sel) do if reaper.ValidatePtr2(proj, s, "MediaItem*") then reaper.SetMediaItemSelected(s, true) end end
  reaper.PreventUIRefresh(-1)
  if not okr then error(base, 0) end
  local path = base .. ".flac"
  return reaper.file_exists(path) and path or nil
end

-- A chained print's later stage (lib/prints.lua relay_stage): the stage before's `file`, from where item `it` starts and as long, through
-- track `tr` (the caller leaves only that stage's plug-ins on), printed as print_item prints. On a scratch item, gone again before anything
-- else looks (API calls leave no undo point; in the background the copy is saved with it, then it goes). -> the .flac path, or nil. 0.59.49
function sync.print_file(proj, tr, it, file, out, name)
  local tmp = reaper.AddMediaItemToTrack(tr)
  reaper.SetMediaItemInfo_Value(tmp, "D_POSITION", reaper.GetMediaItemInfo_Value(it, "D_POSITION"))
  reaper.SetMediaItemInfo_Value(tmp, "D_LENGTH", reaper.GetMediaItemInfo_Value(it, "D_LENGTH"))
  local tk = reaper.AddTakeToMediaItem(tmp)
  reaper.SetMediaItemTake_Source(tk, reaper.PCM_Source_CreateFromFile(file))
  local ok, path = pcall(sync.print_item, proj, tmp, tk, out, name, nil, false, true)
  reaper.DeleteTrackMediaItem(tr, tmp)
  if not ok then error(path, 0) end
  return path
end

-- Print a MIDI item that plays an instrument on another track (lib/prints.lua prints.route): that track rendered as a
-- stem over the item's time, with only this item feeding it. For the render its other inputs and its own items are
-- muted, and so are the source track's other items; its fader and pan are left out (they travel as the mix), as in
-- render_item. Everything is put back after. Returns the .flac path, or nil. Active tab only.
function sync.print_routed(proj, it, take, dest, out, name)
  local src = reaper.GetMediaItem_Track(it)
  local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
  local len = reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
  local base = name
  for n = 2, 99 do -- (a leftover REAPER still holds can't be replaced: a fresh name instead, as render_item)
    os.remove(out .. "/" .. name .. ".flac"); os.remove(out .. "/" .. name .. ".opus")
    if not reaper.file_exists(out .. "/" .. name .. ".flac") then break end
    name = base .. "-" .. n
  end
  local undo = {}
  local function track(tr, k, v)
    local was = reaper.GetMediaTrackInfo_Value(tr, k)
    undo[#undo + 1] = function() reaper.SetMediaTrackInfo_Value(tr, k, was) end
    reaper.SetMediaTrackInfo_Value(tr, k, v)
  end
  local function item(x, v)
    local was = reaper.GetMediaItemInfo_Value(x, "B_MUTE")
    undo[#undo + 1] = function() reaper.SetMediaItemInfo_Value(x, "B_MUTE", was) end
    reaper.SetMediaItemInfo_Value(x, "B_MUTE", v)
  end
  reaper.PreventUIRefresh(1)
  local playing, sel_tracks = reaper.GetActiveTake(it), {}
  for i = 0, reaper.CountSelectedTracks(proj) - 1 do sel_tracks[#sel_tracks + 1] = reaper.GetSelectedTrack(proj, i) end
  reaper.SetActiveTake(take)
  item(it, 0)
  local lane = lane_of(it)
  local lanes = lane and lanes_playing(src)
  if lane then reaper.SetMediaTrackInfo_Value(src, "C_LANEPLAYS:" .. lane, 1) end
  track(src, "B_MUTE", 0)
  for i = 0, reaper.CountTrackMediaItems(src) - 1 do
    local x = reaper.GetTrackMediaItem(src, i)
    if x ~= it then item(x, 1) end
  end
  for i = 0, reaper.CountTrackMediaItems(dest) - 1 do item(reaper.GetTrackMediaItem(dest, i), 1) end
  local receives = {}
  for r = 0, reaper.GetTrackNumSends(dest, -1) - 1 do
    if reaper.GetTrackSendInfo_Value(dest, -1, r, "P_SRCTRACK") ~= src then
      receives[r] = reaper.GetTrackSendInfo_Value(dest, -1, r, "B_MUTE")
      reaper.SetTrackSendInfo_Value(dest, -1, r, "B_MUTE", 1)
    end
  end
  track(dest, "B_MUTE", 0); track(dest, "D_VOL", 1); track(dest, "D_PAN", 0)
  -- every other track muted too (not the folders these two sit in: that would mute them): this "stem" render took
  -- in whatever else played at the time, a second synth 7 dB over the print (PC, 0.38 test)
  local keep = {}
  for _, t in ipairs({ src, dest }) do
    while t do keep[t] = true; t = reaper.GetParentTrack(t) end
  end
  for i = 0, reaper.CountTracks(proj) - 1 do
    local t = reaper.GetTrack(proj, i)
    if not keep[t] and reaper.GetMediaTrackInfo_Value(t, "B_MUTE") == 0 then track(t, "B_MUTE", 1) end
  end
  reaper.SetOnlyTrackSelected(dest)
  local okr, err = pcall(band.render, { RENDER_SETTINGS = 2, RENDER_BOUNDSFLAG = 0, RENDER_STARTPOS = pos, RENDER_ENDPOS = pos + len, RENDER_SRATE = 0,
    RENDER_CHANNELS = 2, RENDER_TAILFLAG = 0, RENDER_TAILMS = 0, RENDER_ADDTOPROJ = 0 }, -- &2: stems only (the selected track), 0: this time range
    { RENDER_FILE = out, RENDER_PATTERN = name, RENDER_FORMAT = band.FLAC, RENDER_FORMAT2 = band.OPUS }) -- (put back whatever happens: review, 0.58.87)
  for r, m in pairs(receives) do reaper.SetTrackSendInfo_Value(dest, -1, r, "B_MUTE", m) end
  for i = #undo, 1, -1 do undo[i]() end
  if lane then set_lanes_playing(src, lanes) end
  reaper.SetActiveTake(playing)
  for i = 0, reaper.CountTracks(proj) - 1 do reaper.SetTrackSelected(reaper.GetTrack(proj, i), false) end
  for _, t in ipairs(sel_tracks) do if reaper.ValidatePtr2(proj, t, "MediaTrack*") then reaper.SetTrackSelected(t, true) end end
  reaper.PreventUIRefresh(-1)
  if not okr then error(err, 0) end
  -- a stem render may name the file after the track as well: whatever it made under this name is the print
  if not reaper.file_exists(out .. "/" .. name .. ".flac") then
    for _, f in ipairs(band.files(out)) do
      local ext = f:match("^" .. name:gsub("%p", "%%%0") .. ".-%.(%a+)$")
      if ext == "flac" or ext == "opus" then os.rename(out .. "/" .. f, out .. "/" .. name .. "." .. ext) end
    end
  end
  return reaper.file_exists(out .. "/" .. name .. ".flac") and (out .. "/" .. name .. ".flac") or nil
end

-- ---- events -------------------------------------------------------------------------------------

local ev_seq = 0
-- With `proj`, a timeline change is ordered after the newest one seen here, and remembered as that.
-- Changes from the band this project gave up on (they failed again and again, or couldn't be read): kept, so Health says so and can try
-- them again. Marked as done and only logged, the project stayed different for good with nothing to show it. Review, 0.58.47.
-- Of the timeline changes waiting (in time order), the one to apply: the newest, ours included, and newer than what this project already has
-- (`have`: time .. id). -> its id, or nil. Pure but for the floor (review, 0.58.92).
-- (only a map this version can apply: one too new or held (sync.too_new), picked as the newest, had every older map marked superseded while it
-- waited itself, so a computer that started on an older file took no map at all. rt-sync2h)
function sync.newest_map(pending, have)
  local id, best = nil, have or ""
  for _, ev in ipairs(pending) do
    if ev.type == "timeline" and not sync.too_new(ev) then
      local o = ev.order or ((ev.time or "") .. (ev.id or "")) -- (the order sync.post gives it: after the newest seen where it was made)
      if o > best then id, best = ev.id, o end
    end
  end
  return id
end
function sync.skipped(proj) return band.json_decode(ext(proj, band.SECTION, "skipped")) or {} end
function sync.skip(proj, ev, why)
  local list = sync.skipped(proj)
  if #list < 50 then list[#list + 1] = { id = ev.id, user = ev.user, why = tostring(why):sub(1, 200) } end
  setext(proj, band.SECTION, "skipped", band.json_encode(list))
  setext(proj, sync.APPLIED, ev.id, "1")
end
function sync.retry_skipped(proj)
  local list = sync.skipped(proj)
  for _, s in ipairs(list) do setext(proj, sync.APPLIED, s.id, ""); sync.failed[s.id] = nil; sync.unreadable[s.id] = nil end
  -- (and they're looked at again: the cache of settled files kept them as done, so Try again did nothing until a restart. Review, 0.58.62)
  local mine = tostring(proj)
  for k in pairs(sync.settled) do if k:sub(1, #mine) == mine then sync.settled[k] = nil end end
  setext(proj, band.SECTION, "skipped", "")
  -- (and told to whichever script receives: Health's Try again runs in the panel, Autostart receives, and its own cache still had them as
  -- done, so nothing was tried until REAPER restarted. 0.59.32)
  setext(proj, band.SECTION, "retry", tostring(reaper.time_precise()))
  return #list
end
-- A name as it starts an event's id: letters, digits, "-" and "_" only ("&", "(" and ")" split merge ids, mirror.split_merge. Review, 0.58.47).
function sync.id_user(user) return ((user or "x"):gsub("[^%w%-_]", "_")) end
local mine_pat = {} -- user -> the pattern sync.is_mine looks for (made once: it ran for every event file at every look. 0.59.19)
-- Is this event id (or file name) one `user` made? The name, then the date: "Al" isn't "Al-B" (their cues were skipped as ours. Review).
function sync.is_mine(id, user)
  local key = user or ""
  local pat = mine_pat[key]
  if not pat then pat = "^" .. sync.id_user(user):lower():gsub("%p", "%%%0") .. "%-%d%d%d%d%d%d%d%d%-"; mine_pat[key] = pat end
  return (id or ""):lower():find(pat) ~= nil
end
function sync.post(cfg, song, room, ev, proj)
  if sync.below_floor() then -- (below the studio's floor: nothing goes out. The look, heal and Undo don't run there; this catches the rest)
    if not sync.floor_said then sync.floor_said = true; band.log(sync.floor_words()) end
    return nil
  end
  ev.lv = sync.LEVEL -- (the level it was made at: sync.held_by_floor)
  ev_seq = ev_seq + 1
  sync.posted = ev_seq -- (Live sync's cloud pass comes sooner after changes went out: James, rt)
  ev.format, ev.user, ev.time = band.FORMAT, cfg.user, os.date("!%Y-%m-%dT%H:%M:%SZ")
  -- (what equal revisions are settled by, mirror.order_of; and a timeline change's place among its maker's own acts, lib/undo.lua. rt-sync2i)
  if (ev.type == "obj" or ev.type == "timeline") and not ev.hlc then ev.hlc = require("mirror").hlc_next() end
  if ev.type == "obj" then ev.mg = require("mirror").MG end -- (what this version merges: a chain merges only with another that says so. rt-p1)
  -- made with nobody else here (full control): everyone takes it when it reaches them, whoever drove then
  if sync.alone then ev.alone = true; if proj then setext(proj, band.SECTION, "alone_last", ev.time) end end
  ev.id = string.format("%s-%s-%05d-%04d", sync.id_user(cfg.user), os.date("!%Y%m%d-%H%M%SZ"), ev_seq, math.random(0, 9999))
  local k = proj and newest_key(ev)
  if k then
    local seen = ext(proj, sync.NEWEST, k)
    if seen >= ev.time .. ev.id then ev.order = seen .. "+" end
    -- (the tempo map and markers this one was made on, by that change's order: what its Undo goes back to, sync.undo_timeline. rt-converge)
    if k == "timeline" and seen ~= "" then ev.built_on = seen end
  end
  local dir = sync.room_dir(cfg, song, room) .. "/events"
  reaper.RecursiveCreateDirectory(dir, 0)
  band.write_json(dir .. "/" .. ev.id .. ".json", ev)
  -- (to whoever's here over the direct link too, a start or stop also as a message: lib/direct.lua. Syncthing's copy stays the record. James, 0.60.0-rt)
  local direct = require("direct")
  direct.offer(cfg, dir .. "/" .. ev.id .. ".json")
  if ev.type == "start" or ev.type == "stop" then direct.send_live(cfg, "cue", ev, song, room, ev.id) end
  -- (an object change also as a message: a file waits its turn on the link's one sending thread, behind every computer's copy, the clock's
  -- pings and the streams, so a slow or asleep computer first in line held the others' up to 1.5 s; each bandmate's messages go at once on a
  -- lane of their own. Up to direct.MSG_MAX (a big chain or MIDI item goes as the file only); the file is still the record. rt-look)
  -- (and a tempo map or marker change, at once like the object changes beside it. rt-edits)
  if ev.type == "obj" or ev.type == "timeline" then direct.send_live(cfg, "event", ev, song, room, ev.id) end
  if proj then stamp(proj, ev) end
  if ev.type == "start" or ev.type == "stop" then -- (a cue: Syncthing told to look at it now, not when its watcher gets round to it)
    local id = band.info(cfg.root).id
    local rel = (dir .. "/" .. ev.id .. ".json"):gsub("\\", "/"):sub(#cfg.root:gsub("\\", "/"):gsub("/+$", "") + 2)
    if id then pcall(require("services").rescan, id, rel) end
  end
  return ev.id
end

-- Which StudioSync takes are audible on a track: the active take of each item in a playing lane.
-- Returns whether the track holds any StudioSync takes, and their sorted ids.
function sync.audible(tr)
  local lanes = reaper.GetMediaTrackInfo_Value(tr, "I_FREEMODE") == 2
  local any, ids = false, {}
  for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
    local it = reaper.GetTrackMediaItem(tr, j)
    local active = reaper.GetActiveTake(it)
    local lane_on = not lanes or reaper.GetMediaTrackInfo_Value(tr, "C_LANEPLAYS:" ..
      math.floor(reaper.GetMediaItemInfo_Value(it, "I_FIXEDLANE"))) ~= 0
    for k = 0, reaper.CountTakes(it) - 1 do
      local tk = reaper.GetTake(it, k)
      local id = band.take_id(tk)
      if id then
        any = true
        if tk == active and lane_on then ids[#ids + 1] = id:lower() end
      elseif tk == active and lane_on and band.take_ext(tk, "band_dry") ~= "" then -- dry mode plays the dry twin: same take
        ids[#ids + 1] = band.take_ext(tk, "band_dry"):lower()
      end
    end
  end
  table.sort(ids)
  return any, table.concat(ids, ",")
end

sync.lane_of, sync.track_name = lane_of, track_name

-- A note on an item shows on every take of it (the print, its dry twin in dry mode, ...), at song position pos.
-- len (seconds): a note on a stretch, shaded across it, where REAPER has take marker lengths (7.86); elsewhere a point at its start.
function sync.mark_item(it, pos, text, len)
  local ipos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
  for k = 0, reaper.CountTakes(it) - 1 do
    local tk = reaper.GetTake(it, k)
    if not tk then goto next_take end -- (an empty take lane)
    -- (in the take's own time: a take played at another rate moves through its source faster or slower. The position ignored that until 0.58.67,
    -- so a note on a sped-up take landed in the wrong place)
    local rate = reaper.GetMediaItemTakeInfo_Value(tk, "D_PLAYRATE")
    if rate <= 0 then rate = 1 end
    local idx = reaper.SetTakeMarker(tk, -1, text, math.max(0, ((pos or ipos) - ipos) * rate + reaper.GetMediaItemTakeInfo_Value(tk, "D_STARTOFFS")))
    if tonumber(len) and len > 0 and idx >= 0 and reaper.SetTakeMarkerInfo then reaper.SetTakeMarkerInfo(tk, idx, "LENGTH", len * rate) end
    ::next_take::
  end
  reaper.UpdateItemInProject(it)
end

-- Apply one event from whoever may make it. False means retry later (its take hasn't arrived, or a
-- delete needs this tab in front).
-- `dir`: the room's folder (where "midi" events keep their note files); `root`: the shared folder (drum maps).
-- May ev.user make this mirror change? The track's name for claims; their own new tracks are theirs unless the room
-- is Driver only (the same rule mirror.watch uses when sending).
sync.failed = {} -- event id -> how many times applying it threw
function sync.obj_allowed(ev, can, driver)
  local at = type(ev.time) == "string" and ev.time or nil -- (by the claims as they stood when it was made: sync.authority's `at`. rt-converge)
  if can(ev.user, ev.name or "", ev.pos, nil, driver, at) then return true end
  return sync.maker_may(ev.obj == "track" and ev.oid or ev.track, ev.user, ev.name or "", ev.pos, sync.room_mode, ev.obj == "item" and ev.oid or nil, nil, at)
end

-- A track's maker may change it and what's on it while nobody has claimed it, unless the room is Driver only. Before
-- 0.40.3 the maker beat a bandmate's claim too, and nothing showed it (James, 2026-11-01: "it gets confusing"). Nothing is
-- claimed for anyone by itself from 0.58.82 (James: auto-claims "just make things more troublesome") until rt, when Claims mode brought them back
-- as claims that let go when you stop editing, with an ask instead of a refusal (James, 2026-11-20; lib/claimask.lua).
-- `item`: an item's own oid. Your own recording on a track nobody claimed goes out too, as the take rule in sync.authority
-- says (it went to "(yours, not sent)" while the panel said "recording still goes out": UX review, 0.58.76).
-- `is_claimed` (optional): the room's (sync.authority's who.is_claimed), else the last authority call's. Round 1 review, 0.59.45
function sync.maker_may(oid, user, name, pos, mode, item, is_claimed, at)
  local mirror = require("mirror")
  is_claimed = is_claimed or sync.is_claimed
  return mode ~= "driver" and mode ~= "admins" and (mirror.is_creator(oid, user) or (item ~= nil and mirror.is_creator(item, user)))
    and not (is_claimed and is_claimed(name, pos, at))
end

-- Add tracks to my claims. -> true, or nil and why.
function sync.claim_tracks(cfg, song, room, names)
  local c, why = sync.my_claims(cfg, song, room)
  if not c then return nil, why end
  c.tracks = c.tracks or {}
  for _, name in ipairs(names) do
    local have = false
    for _, n in ipairs(c.tracks) do have = have or n:lower() == name:lower() end
    if not have then c.tracks[#c.tracks + 1] = name end
  end
  sync.set_claims(cfg, song, room, c)
  return true
end

-- Apply one event from whoever may make it. False means retry later. `dir`: the room's folder.
-- The item a note or like is on, here (a part in mirror sync is found by its item id: it has no take id. 0.58.98), or nil.
function sync.note_item(proj, ev)
  return (ev.take and band.find_take(proj, ev.take)) or (type(ev.item) == "string" and require("mirror").find(proj, "item", ev.item)) or nil
end
sync.CUE_OLD = 120 -- seconds after which a start or stop that arrives is only history (sync.receive)
-- Whether a change that isn't an object's changes this project: a play or stop together, a driver change and a note on nothing here don't.
-- (only then an arrival's undo block: opened for every bandmate's event, it closed empty on top of REAPER's list and sent Ctrl+Z StudioSync's
-- way. Cost: a lookup per note. Round 4 review, 0.59.49)
function sync.alters(proj, ev)
  if ev.type == "timeline" or ev.type == "shift" then return true end
  return (ev.type == "note" or ev.type == "like") and sync.note_item(proj, ev) ~= nil
end
-- A tempo or marker change of yours that hasn't gone out when a newer timeline lands (a marker added in the first seconds after opening, while
-- this project still catches up; or made between two looks). The timeline travels whole, so what landed replaced yours and the log said
-- nothing. Now what you changed since this project's last look is made again on top of what landed, as if you'd made it a moment later, and
-- the next look sends it (or puts it back and says so, if the timeline isn't yours to change). rt-edits, backlog 1.
-- sync.timeline_unsent, before the newer one is put in place: what differs from the last look's note ("seen").
--   markers added and removed, by kind, place, end and name; a moved or renamed one is one of each;
--   the tempo map, if it differs: then markers are told apart by kind, number and name (REAPER moved them all, places say nothing).
--   A note in an older format compares by place only, and not at all if its tempo map reads differently (fields were added since).
-- -> nil when nothing differs; nil, true when something does but it can't be told what (the caller says so in the log).
do -- (its helpers stay out of the file's own locals)
local function near(a, b) return math.abs((tonumber(a) or 0) - (tonumber(b) or 0)) < 1e-6 end
local function mark_at(list, m, by_num)
  for j, h in ipairs(list) do
    if (m.region and true or false) == (h.region and true or false) and m.name == h.name then
      if by_num then if m.num ~= nil and m.num == h.num then return j end
      elseif near(m.pos, h.pos) and (not m.region or near(m["end"], h["end"])) then return j end
    end
  end
end
local function tempo_near(a, b)
  if #a ~= #b then return false end
  for i, x in ipairs(a) do
    local y = b[i]
    for _, k in ipairs({ "time", "bpm", "num", "denom", "linear" }) do
      local p, q = x[k], y[k]
      if type(p) == "number" and type(q) == "number" then if not near(p, q) then return false end
      elseif p ~= q then return false end
    end
  end
  return true
end
function sync.timeline_unsent(proj)
  local seen = ext(proj, band.SECTION, "timeline")
  local was = seen ~= "" and band.json_decode(seen)
  if type(was) ~= "table" or type(was[1]) ~= "table" or type(was[2]) ~= "table" then return nil end
  local tempo, markers = band.capture_tempo(proj), band.capture_markers(proj)
  local d = { added = {}, at = {}, removed = {}, count = #markers }
  if not tempo_near(was[1], tempo) then
    if was[4] ~= sync.TIMELINE_FORMAT then return nil, true end
    d.tempo = tempo
  end
  for _, m in ipairs(was[2]) do d.removed[#d.removed + 1] = m end
  for i, m in ipairs(markers) do
    local j = mark_at(d.removed, m, d.tempo ~= nil)
    if j then table.remove(d.removed, j) else d.added[#d.added + 1], d.at[#d.at + 1] = m, i end
  end
  if not d.tempo and #d.added == 0 and #d.removed == 0 then return nil end
  return d
end
-- (after the newer tempo map is in place, before its markers are: the markers you added sit where REAPER moved them for it)
function sync.timeline_carry(proj, d)
  if d.tempo then return end -- (your own map goes back on: they're placed in it already)
  local cur = band.capture_markers(proj)
  if #cur ~= d.count then return end
  for k, i in ipairs(d.at) do
    local c, a = cur[i], d.added[k]
    if c.name == a.name and (c.region and true or false) == (a.region and true or false) then d.added[k] = c end
  end
end
-- (after the newer timeline is in place and noted as seen: yours again on top. `who`: whose timeline landed, for the log.)
function sync.timeline_redo(proj, d, who)
  if d.tempo then band.apply_tempo(proj, d.tempo) end
  local cur, added, removed = band.capture_markers(proj), 0, 0
  for _, m in ipairs(d.removed) do
    local j = mark_at(cur, m) or mark_at(cur, m, true) -- (by place; else by number, where the two maps differ)
    if j then table.remove(cur, j); removed = removed + 1 end
  end
  for _, m in ipairs(d.added) do
    if not mark_at(cur, m) then
      for _, h in ipairs(cur) do -- (its number, unless the newer timeline gave it to another: REAPER then gives the next free one)
        if h.num == m.num and (h.region and true or false) == (m.region and true or false) then m.num = nil end
      end
      cur[#cur + 1] = m
      added = added + 1
    end
  end
  if added + removed > 0 then band.apply_markers(proj, cur) end
  if not d.tempo and added + removed == 0 then return false end
  local what = {}
  if d.tempo then what[#what + 1] = "your tempo map (theirs is replaced)" end
  if added > 0 then what[#what + 1] = added .. " marker(s) or region(s) you added" end
  if removed > 0 then what[#what + 1] = removed .. " you removed or moved" end
  band.log(tostring(who) .. "'s newer tempo map and markers landed before your own change had gone out. Kept on top of theirs: "
    .. table.concat(what, ", ") .. ". It goes to the studio next")
  return true
end
end
function sync.apply(proj, ev, dir, can, me)
  if ev.type == "obj" then return require("mirror").receive(proj, ev, dir .. "/media", sync.local_mix, me) end -- mirror sync
  if ev.type == "timeline" then -- REAPER moves the items for the new map, as it would for a local change
    local mine, untold
    if me then mine, untold = sync.timeline_unsent(proj) end -- (yours, not sent yet: kept on top below)
    sync.audio_follow_tempo(proj)
    -- (what REAPER moves for a map that wasn't made here reads the same in beats: never this computer's edit. lib/beats.lua, rt-sync2f)
    band.apply_tempo(proj, ev.tempo or {})
    if mine then sync.timeline_carry(proj, mine) end
    band.apply_project(proj, ev.project) -- (title, notes, group names, timebase, ruler lanes: from 0.31.1; before the markers that sit in them)
    band.apply_markers(proj, ev.markers or {})
    setext(proj, band.SECTION, "timeline", timeline_sig(proj))
    -- (noted as seen first: what's made again differs from it, so the next look takes it for the change of yours it is)
    if mine then sync.timeline_redo(proj, mine, ev.user) end
    if untold then
      band.log(tostring(ev.user) .. "'s newer tempo map and markers replaced this project's, whose own differed from what it last sent in a way "
        .. "StudioSync can't tell from an older file's (noted by an older version). If a change of yours went with it, REAPER's Undo brings it back")
    end
    sync.timeline_live[proj] = true
    sync.resnap(proj)
    return true
  end
  if ev.type == "start" or ev.type == "stop" then -- Live sync's tick fires it at the right moment (lib/together.lua)
    band.set_ext_json(band.SECTION, "transport " .. tostring(proj), ev, false)
    return true
  end
  if ev.type == "note" or ev.type == "like" then
    local it2 = sync.note_item(proj, ev)
    if it2 then sync.mark_item(it2, ev.pos, (ev.type == "like" and "+1 " or "") .. ev.user .. (ev.text and (": " .. ev.text) or ""), ev.len) end
    return true -- notes without a take live in the panel's Notes list (and History)
  end
  return true -- "driver" events and unknown types from newer versions: nothing to change in the project
end

-- Compare the project with its snapshots and post what changed, for whatever `can` says this person may
-- change (track owner, region owner or driver). Changes they may not make stay local (and are locked in
-- the first place, see apply_locks).
-- Is a tempo map or marker change newer than this project's waiting to land? true, false, or nil while that can't be told (the room's
-- changes waiting here haven't all been read yet: sync.receive notes it once they are). Asked only while a project catches up after opening.
sync.map_pending = {} -- tostring(proj) -> a newer map was among what waited, as of the last sync.receive that read everything
function sync.timeline_behind(proj, cfg, song, room)
  local known = sync.map_pending[tostring(proj)]
  if known ~= nil then return known end
  -- (anything at all not taken in yet, your own from before a restart included: the desktop's newer map was its own)
  local dir = sync.room_dir(cfg, song, room) .. "/events"
  local settled = sync.settled_for(proj, dir)
  for _, f in ipairs((require("direct").listing(cfg, dir))) do
    if not settled[f] and ext(proj, sync.APPLIED, f:sub(1, -6)) == "" then return nil end
  end
  return false
end
-- Does this project hold the newest tempo map and markers it says it does (sync.NEWEST names the change: its time, then its id)? Asked once
-- per stamp and opening, when nothing of yours waits to go: if the map's tempo or markers (kind, place, end, name) aren't what's here, they're
-- put in place. The desktop's Cross Test, reopened from an older file, had the newest map's stamp and its event marked done, and none of its
-- markers: nothing looked again, and its next marker edit would have dropped the region for everyone. REAPER check F7, rt-edits.
-- -> true when it put the map in place. Cost: one small file read per new stamp.
sync.timeline_checked = {}
function sync.timeline_differs(proj, t)
  local function near(a, b) return math.abs((tonumber(a) or 0) - (tonumber(b) or 0)) < 1e-6 end
  local tempo, markers = band.capture_tempo(proj), band.capture_markers(proj)
  if type(t.tempo) ~= "table" or type(t.markers) ~= "table" or #t.tempo ~= #tempo or #t.markers ~= #markers then return true end
  for i, m in ipairs(t.tempo) do
    local h = tempo[i]
    if not (near(m.time, h.time) and near(m.bpm, h.bpm) and m.num == h.num and m.denom == h.denom) then return true end
  end
  local left = {}
  for _, h in ipairs(markers) do left[#left + 1] = h end
  for _, m in ipairs(t.markers) do
    local found
    for i, h in ipairs(left) do
      if (m.region and true or false) == (h.region and true or false) and near(m.pos, h.pos) and (not m.region or near(m["end"], h["end"])) and m.name == h.name then found = i; break end
    end
    if not found then return true end
    table.remove(left, found)
  end
  return false
end
function sync.timeline_heal(proj, cfg, song, room)
  local held = ext(proj, sync.NEWEST, "timeline")
  if held == "" or sync.timeline_checked[proj] == held then return false end
  sync.timeline_checked[proj] = held
  local t
  local id = held:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ([%w%-_%.]+)$") -- (a stamp ending "+" is "after that one": its own id isn't in it)
  if id then
    local ev = band.read_json(sync.room_dir(cfg, song, room) .. "/events/" .. id .. ".json")
    if type(ev) == "table" and ev.type == "timeline" and ev.id == id then t = ev end
  end
  if not t then
    local sj = sync.studio_timeline(cfg, song, room)
    if type(sj) == "table" and tostring(sj.timeline_order) == held then t = sj end
  end
  if not (type(t) == "table" and type(t.tempo) == "table" and #t.tempo > 0 and type(t.markers) == "table") then return false end
  if not sync.timeline_differs(proj, t) then return false end
  reaper.Undo_BeginBlock2(proj)
  local ok, e = pcall(function()
    if tempo_sig(t.tempo) ~= tempo_sig(band.capture_tempo(proj)) then
      sync.audio_follow_tempo(proj)
      band.apply_tempo(proj, t.tempo)
    end
    if type(t.project) == "table" then band.apply_project(proj, t.project) end
    band.apply_markers(proj, t.markers)
  end)
  reaper.Undo_EndBlock2(proj, "StudioSync: the project's tempo map and markers", -1)
  if not ok then error(e, 0) end
  band.log("this project's tempo map and markers weren't the studio's newest, which it had counted as here: they're back as the studio has them")
  return true
end

-- An act's tempo map or marker change, put back with it (Undo and Redo: lib/undo.lua). entries[j] is that change (T); P is the timeline before
-- it. Markers: what T added goes and what it took away comes back, by kind, place, end and name; everything else stays as it is now, a
-- bandmate's markers since among them. Where T changed the tempo map, places can't be compared across the two maps, so the whole of P comes
-- back, and only if what's here is still T. The tempo goes first, so REAPER moves things back before the act's items are restored.
-- `tags`: { undoes = id } or { redoes = id }, on the change it sends; { restored = true }: "Undo this change" on a Restore's row (lib/page_restore.lua),
-- a Restore like the rows it puts back, so StudioSync's Undo and Redo pass over it. -> true when it changed anything, and whether that was the tempo map.
-- REAPER check F3, rt-edits.
-- The timeline before entries[j] (a timeline change, T): what its Undo goes back to. -> it, or nil.
local function timeline_before(cfg, song, room, entries, j, session)
  local T = entries[j]
  -- (the timeline change before it by the timeline's own order (sync.post's `order`: after the newest one seen where it was made), not by
  -- History's rows, which sort by each computer's clock: a marker you added a second after a bandmate's Restore, stamped the same second,
  -- sat before their change in History, so the Redo of your Undo compared against their timeline, found nothing to bring back, and your
  -- marker stayed gone. The soak's undo probe, seed 31. rt-converge)
  -- (first, the one it says it was made on (`built_on`, from this package on): of two timeline changes made a moment apart the later by order
  -- wasn't made on the earlier, and compared with it the Undo also took back what its maker had never seen: a bandmate's rename of another
  -- marker, undone that same second, went back on with the Undo of a region's move. The soak's undo probe, seed 6002. rt-converge)
  local P
  local t_order = order(T)
  local function version(e, i) return i ~= j and e.kind == "timeline" and type(e.tempo) == "table" and type(e.time) == "string" and type(e.id) == "string" end
  if type(T.built_on) == "string" and T.built_on ~= "" then
    for i, e in ipairs(entries) do if version(e, i) and order(e) == T.built_on then P = e end end
  end
  for i, e in ipairs(P and {} or entries) do
    if version(e, i) and order(e) < t_order and (not P or order(e) > order(P)) then P = e end
  end
  if not P then
    local meta = band.read_json(sync.room_dir(cfg, song, room) .. "/room.json")
    if meta and meta.parent then P = meta.tempo and meta or nil else P = (session and session.first_timeline) or session end
  end
  return P and type(P.tempo) == "table" and P or nil
end
local function mark_key(m)
  return string.format("%s|%.6f|%.6f|%s", m.region and "r" or "m", tonumber(m.pos) or 0, m.region and (tonumber(m["end"]) or 0) or 0, tostring(m.name))
end
-- What the timeline change entries[j] changed, in words for Undo and Redo: "changed the tempo map (130 -> 100 bpm) and the markers". History's
-- own words say what the version holds ("now 130 bpm"), which an Undo of a marker rename made under 130 bpm said while a bandmate's 100 stayed
-- (rt-r4). rt-fix9
function sync.timeline_words(cfg, song, room, entries, j, session)
  local T, P = entries[j], timeline_before(cfg, song, room, entries, j, session)
  if not (P and type(T.tempo) == "table") then return "changed the tempo map or markers" end
  local what = {}
  if tempo_sig(P.tempo) ~= tempo_sig(T.tempo) then
    local a, z = P.tempo[1], T.tempo[1]
    what[#what + 1] = "the tempo map" .. ((#P.tempo == 1 and #T.tempo == 1 and a and z and tonumber(a.bpm) and tonumber(z.bpm))
      and string.format(" (%g -> %g bpm)", a.bpm, z.bpm) or "")
  end
  local had, n = {}, 0
  for _, m in ipairs(type(P.markers) == "table" and P.markers or {}) do had[mark_key(m)] = (had[mark_key(m)] or 0) + 1 end
  for _, m in ipairs(type(T.markers) == "table" and T.markers or {}) do
    local k = mark_key(m)
    if (had[k] or 0) > 0 then had[k] = had[k] - 1 else n = n + 1 end
  end
  for _, c in pairs(had) do n = n + c end
  -- (under another map every marker's seconds move: only the markers' count and names say whether they changed then)
  if n > 0 and #what > 0 then
    local names = function(list) local t = {}; for _, m in ipairs(type(list) == "table" and list or {}) do t[#t + 1] = tostring(m.name) end; table.sort(t); return table.concat(t, "\0") end
    if names(P.markers) == names(T.markers) then n = 0 end
  end
  if n > 0 then what[#what + 1] = "the markers" end
  return #what > 0 and ("changed " .. table.concat(what, " and ")) or "changed the tempo map or markers"
end
function sync.undo_timeline(proj, cfg, song, room, entries, j, tags, session)
  local T = entries[j]
  if not (T and T.kind == "timeline" and type(T.tempo) == "table") then return false end
  local P = timeline_before(cfg, song, room, entries, j, session)
  if not P then return false end
  local key = mark_key
  local function keys(list)
    local t = {}
    for _, m in ipairs(type(list) == "table" and list or {}) do t[key(m)] = m end
    return t
  end
  local now_m = band.capture_markers(proj)
  -- (both versions' markers on the map in place: a marker's seconds are under its own version's map, and REAPER has moved every marker
  -- for each map since. Compared as written, nothing of the undone change matched a marker here: the one it had changed stayed, and the
  -- one from before came back beside it at its old seconds; the Redo then took the wrong one away. Where a marker here is the one meant,
  -- its place as REAPER wrote it (worked out two ways, a place differs past its 9th decimal). The soak's undo probe, seed 3003. rt-converge)
  local cur_t = band.capture_tempo(proj)
  local function placed(list)
    if type(list) ~= "table" or tempo_sig(T.tempo) == tempo_sig(cur_t) then return list end
    local mode, out = reaper.GetSetProjectInfo(proj, "PROJECT_TIMEBASE", 0, false), {}
    local on = require("mirror").time_on
    local function near(a, b) return math.abs((tonumber(a) or 0) - (tonumber(b) or 0)) < 1e-6 end
    for i, m in ipairs(list) do
      local c = {}
      for k, v in pairs(m) do c[k] = v end
      c.pos = on(tonumber(m.pos) or 0, T.tempo, cur_t, mode)
      if m.region then c["end"] = on(tonumber(m["end"]) or 0, T.tempo, cur_t, mode) end
      for _, h in ipairs(now_m) do
        if (h.region and true or false) == (m.region and true or false) and near(h.pos, c.pos) and (not m.region or near(h["end"], c["end"])) then
          c.pos = h.pos
          if m.region then c["end"] = h["end"] end
          break
        end
      end
      out[i] = c
    end
    return out
  end
  local p_marks, t_marks = placed(P.markers), placed(T.markers)
  local in_p, in_t = keys(p_marks), keys(t_marks)
  local want_t, want_m
  if tempo_sig(P.tempo) ~= tempo_sig(T.tempo) then
    if sync.timeline_differs(proj, T) then return false end -- (the map or markers changed since: left as they are)
    want_t, want_m = P.tempo, type(P.markers) == "table" and P.markers or {}
  else
    local out, have, changed = {}, {}, false
    for _, m in ipairs(now_m) do
      local k = key(m)
      if in_t[k] and not in_p[k] then changed = true else out[#out + 1] = m; have[k] = true end
    end
    -- (what the undone change took away or changed comes back, unless a marker with its number is still here in another shape: a bandmate
    -- renamed or moved that one since, and it's theirs as it is. Compared by place and name alone it wasn't found, and the old one came
    -- back beside it: two markers on one place after an Undo of a rename someone had renamed again. The soak's undo probe, seed 6002. rt-converge)
    -- shortcut: a marker a bandmate added since under the same number (REAPER gives the lowest free one) also keeps the old one away; go by
    -- a marker id of StudioSync's own if that ever shows.
    local taken = {}
    for _, m in ipairs(out) do if m.num ~= nil then taken[(m.region and "r" or "m") .. tostring(m.num)] = true end end
    for _, m in ipairs(type(p_marks) == "table" and p_marks or {}) do
      local k = key(m)
      if not in_t[k] and not have[k] and not (m.num ~= nil and taken[(m.region and "r" or "m") .. tostring(m.num)]) then
        out[#out + 1] = m; have[k] = true; changed = true
      end
    end
    if not changed then return false end
    want_m = out
  end
  reaper.Undo_BeginBlock2(proj)
  local ok, e = pcall(function()
    if want_t then
      sync.audio_follow_tempo(proj)
      -- (what REAPER moves for it, outside the act being undone, reads the same in beats: nobody's edit. lib/beats.lua, rt-sync2f)
      band.apply_tempo(proj, want_t)
    end
    band.apply_markers(proj, want_m)
  end)
  reaper.Undo_EndBlock2(proj, "StudioSync: the tempo map and markers of what you undid", -1)
  if not ok then error(e, 0) end
  local tev = { type = "timeline", tempo = band.capture_tempo(proj), markers = band.capture_markers(proj), project = band.capture_project(proj),
    undoes = tags and tags.undoes, redoes = tags and tags.redoes, restored = tags and tags.restored, act = tags and tags.act } -- (act: the press it belongs to, lib/undo.lua)
  sync.post(cfg, song, room, tev, proj)
  sync.timeline_live[proj] = true
  sync.session_timeline(cfg, song, tev.tempo, tev.markers, order(tev), tev.project, room)
  setext(proj, band.SECTION, "timeline", timeline_sig(proj))
  sync.timeline_checked[proj] = ext(proj, sync.NEWEST, "timeline")
  sync.resnap(proj)
  return true, want_t ~= nil
end
-- Which of `me`'s timeline changes belongs to the change being undone or redone (entries[i], as lib/undo.lua picked it): undoing, the one sent
-- under its act; redoing, the one the undo sent (it carries the same `undoes`). The newest such. -> its index, or nil.
function sync.act_timeline(entries, i, me, redo)
  local e = entries[i]
  if not e then return nil end
  for j = #entries, 1, -1 do
    local x = entries[j]
    if x.kind == "timeline" and x.user == me and type(x.tempo) == "table" then
      if redo then if e.undoes and x.undoes == e.undoes then return j end
      elseif e.act and x.act == e.act then return j end
    end
  end
end

sync.timeline_looked = {}
sync.timeline_live = {} -- project -> a timeline was applied or made here since it was opened (watch_timeline's first look; W.order clears it)
-- The song's tempo map and markers: the driver's changes go out, anyone else's are put back (mirror sync carries
-- everything else; the timeline isn't a track or an item).
function sync.watch_timeline(proj, cfg, song, room, can)
  local me = cfg.user
  -- tempo map / markers first: if they changed, REAPER has just moved items for it, and those moves aren't edits
  local sig, seen = timeline_sig(proj), ext(proj, band.SECTION, "timeline")
  -- (noted in an older format: a first look, unless what both formats hold differs: the tempo map, or a marker's kind, place, end or name
  -- (sync.timeline_unsent). That's a marker or tempo change made after the last look of the older version, in the moments around updating:
  -- taken for a first look it was taken in and never sent. Then the note stays, and it goes out below as the change it is. rt-edits)
  if seen ~= sig and seen ~= "" and (band.json_decode(seen) or {})[4] ~= sync.TIMELINE_FORMAT then
    local changed, untold = sync.timeline_unsent(proj)
    if not (changed or untold) then seen = "" end
  end
  -- (a signature's tempo map and markers alone: a reopened file's project settings often read differently (another REAPER's defaults). Laptop
  -- restart, James, rt)
  local function tm(x) local t = band.json_decode(x) or {}; return band.json_encode({ t[1] or {}, t[2] or {} }) end
  -- opened behind the song (closed without its last save, say): nothing of ours waits, and your own marker has no event coming back to you (Mac, 0.57.6)
  if not sync.timeline_looked[proj] then
    sync.timeline_looked[proj] = true
    -- (tempo and markers only: with the settings, this look was skipped and the stale markers were then posted with them, wiping a region the
    -- others had. Laptop restart, James, rt)
    -- (or behind by session.json's stamp, whatever this file last noted: a file from before a TIMELINE_FORMAT change read as a first look, so
    -- an older file reopened after an update kept its stale markers, and its next marker edit would have dropped the studio's region for
    -- everyone. REAPER check F7, rt-edits)
    pcall(sync.timeline_reads, cfg, song, room) -- (this computer reads the per-computer timeline files: the others then stop writing session.json's)
    local sj = sync.studio_timeline(cfg, song, room)
    local behind = type(sj) == "table" and sj.timeline_order ~= nil and tostring(sj.timeline_order) > ext(proj, sync.NEWEST, "timeline")
    local s = type(sj) == "table" and (behind or (seen ~= "" and tm(seen) == tm(sig))) and sj
    -- (only a session.json map newer than the newest this project has applied or made (NEWEST), or, unstamped (written before rt), none
    -- applied or made in this session: it comes through Syncthing, seconds behind a map over the direct link, and the stale one was put
    -- back over the new. Cross test step 1, James, rt)
    local held = ext(proj, sync.NEWEST, "timeline")
    if s and not (s.timeline_order and tostring(s.timeline_order) > held or not s.timeline_order and not sync.timeline_live[proj]) then s = nil end
    if s and type(s.tempo) == "table" and type(s.markers) == "table" and #s.tempo > 0 then
      local function plain(x) return band.json_encode(band.json_decode(band.json_encode(x))) end
      local tempo_off = plain(s.tempo) ~= plain(band.capture_tempo(proj))
      -- (and its settings, where session.json has them: they're in the map's event, which this project now counts as had. Crash-safe sessions, rt)
      local proj_off = type(s.project) == "table" and plain(s.project) ~= plain(band.capture_project(proj))
      local studio_sig
      if tempo_off or proj_off or plain(s.markers) ~= plain(band.capture_markers(proj)) then
        -- (a marker or tempo change of yours since this file's last look, made as it opened: kept on top of the studio's. sync.timeline_unsent)
        local mine = sync.timeline_unsent(proj)
        reaper.Undo_BeginBlock2(proj)
        local ok, e = pcall(function() -- (the undo point closed whatever happens: review, 0.58.92)
          if tempo_off then band.apply_tempo(proj, s.tempo) end
          if mine then sync.timeline_carry(proj, mine) end
          if proj_off then band.apply_project(proj, s.project) end
          band.apply_markers(proj, s.markers)
          if mine then
            studio_sig = timeline_sig(proj)
            if not sync.timeline_redo(proj, mine, "the studio") then studio_sig = nil end
          end
        end)
        reaper.Undo_EndBlock2(proj, "StudioSync: the project's tempo map and markers", -1)
        if not ok then error(e, 0) end
        band.log("this project was behind the studio's copy: its tempo map and markers are back as the studio has them")
      end
      -- (what it holds now: older maps stay superseded. Only once it does hold it: stamped before an apply that failed, the map's own event
      -- was then taken for already here. rt-edits)
      if s.timeline_order then setext(proj, sync.NEWEST, "timeline", tostring(s.timeline_order)) end
      -- (behind, with no tempo or marker change of ours: what it holds now is what the studio has. Settings that still read differently went
      -- out as a change, newer than the studio's map, and every computer took this file's. Crash-safe sessions, James, rt)
      sig = timeline_sig(proj)
      seen = studio_sig or sig -- (the studio's, as noted: yours kept on top differs from it and goes out below, or waits while still behind)
      setext(proj, band.SECTION, "timeline", seen)
    end
  end
  -- (only the project settings differ, and this project's first catch-up isn't done: REAPER reads some of them differently as a file opens, and
  -- the band's newer map, or your own from before a crash, may be about to land. Sent now, this file's settings went out as newer than the
  -- studio's. Once caught up, what still differs is yours and goes out. Crash-safe sessions, James, rt)
  if seen ~= sig and seen ~= "" and sync.loading[tostring(proj)] and tm(seen) == tm(sig) then return end
  -- (nor a tempo or marker change while this project is behind the studio's map, or can't tell yet: a newer map is about to land, and a stale
  -- file's markers sent with one edit of yours would replace everyone's. A marker of yours added before the open still goes out at once when
  -- nothing newer waits. sync.timeline_behind, REAPER check F7, rt-edits)
  if seen ~= sig and seen ~= "" and sync.loading[tostring(proj)] and sync.timeline_behind(proj, cfg, song, room) ~= false then
    return
  end
  -- (and what this project's stamp says it holds is what's here: sync.timeline_heal, once per stamp. rt-edits)
  if seen == sig and not sync.loading[tostring(proj)] then
    local okh, healed = pcall(sync.timeline_heal, proj, cfg, song, room)
    if okh and healed then sig = timeline_sig(proj); seen = sig; setext(proj, band.SECTION, "timeline", sig) end
  end
  if seen ~= sig then
    if seen ~= "" then
      -- (another script's doing: the grid turning this computer's own is no change; a ReaPersona persona switch is put back. lib/compat.lua, James, rt)
      local okv, veto = pcall(require("compat").timeline_veto, proj, seen, sig)
      veto = okv and veto or nil
      if veto == "quiet" then -- (nothing to send or put back: "seen" takes it below)
      elseif can(me, nil, nil) and not veto then -- the song's timeline is the driver's
        local tempo, markers = band.capture_tempo(proj), band.capture_markers(proj)
        -- (act: the id the look after this sends its items under, so one Undo takes the region or markers back with them. rt-edits)
        local tev = { type = "timeline", tempo = tempo, markers = markers, project = band.capture_project(proj), act = require("mirror").act_for(proj, me) }
        sync.post(cfg, song, room, tev, proj) -- (proj: without it no order was set, 0.58.93's fix never applied. Review, 0.58.95)
        sync.timeline_live[proj] = true
        sync.session_timeline(cfg, song, tempo, markers, order(tev), tev.project, room)
        local before = band.json_decode(seen) or {}
        local now, what = band.json_decode(sig) or {}, {} -- (say what changed: it was "tempo map and markers" whatever it was)
        for i, word in ipairs({ "the tempo map", "the markers", "the project settings (notes, title, timebase, lanes, grid, metronome, render format)" }) do
          if band.json_encode(before[i] or {}) ~= band.json_encode(now[i] or {}) then what[#what + 1] = word end
        end
        band.log("sent " .. (#what > 0 and table.concat(what, " and ") or "the timeline") .. " to the studio")
        local from = math.huge -- where the map first differs: audio past there keeps its recorded speed
        for i, m in ipairs(tempo) do
          local o = (before[1] or {})[i]
          if not o or o.time ~= m.time or o.bpm ~= m.bpm or o.num ~= m.num or o.denom ~= m.denom then from = math.min(from, m.time) end
        end
        if #(before[1] or {}) > #tempo then from = math.min(from, (before[1][#tempo + 1] or {}).time or from) end
        local n = 0
        for _, hit in pairs(band.take_index(proj)) do
          local p = reaper.GetMediaItemInfo_Value(hit[1], "D_POSITION")
          if not reaper.TakeIsMIDI(hit[2]) and p + reaper.GetMediaItemInfo_Value(hit[1], "D_LENGTH") > from then n = n + 1 end
        end
        if n > 0 then
          band.log(string.format("%d audio take(s) play past the tempo change at %.2f s: REAPER stretches them there (MIDI parts are reprinted at the new tempo instead); re-record those bars for the best sound", n, from))
        end
      else
        -- not ours to change: the band's map and markers go back, as any change we may not make does (what you see is
        -- what the band has). REAPER moves the items back with the map; those moves aren't edits (resnap below).
        local before = band.json_decode(seen)
        if type(before) == "table" and type(before[1]) == "table" and #before[1] > 0 then
          reaper.Undo_BeginBlock2(proj)
          local ok, e = pcall(function()
            band.apply_tempo(proj, before[1])
            band.apply_project(proj, before[3])
            band.apply_markers(proj, before[2] or {})
          end)
          reaper.Undo_EndBlock2(proj, "StudioSync: put the studio's tempo map and markers back", -1)
          if not ok then error(e, 0) end
          sig = timeline_sig(proj)
          sync.put_back(veto or "Not sent: only the driver changes the tempo, markers and project settings. Take control, or ask them to set Who controls to Claims")
        else
          band.log("tempo or markers changed here, but only the driver's changes go to the others (Take control first)")
        end
      end
    end
    setext(proj, band.SECTION, "timeline", sig)
    sync.resnap(proj, true)
  end
end

-- A bandmate's object change that came as a message on the direct link (sync.post sends one beside its file): written into the link's inbox,
-- as the extension writes an event file that arrives, so sync.receive takes it the same way and once. Only an object change for this song and
-- room, named as its file would be (no path in it), not one already here; the extension checked it came from the studio and its size.
-- -> true when it's new (Live sync then receives at once). rt-look
function sync.take_event(cfg, song, room, ev)
  if type(ev) ~= "table" or (ev.type ~= "obj" and ev.type ~= "timeline") or type(ev.id) ~= "string" or #ev.id > 200 or not ev.id:match("^[%w%-_%.%(%)&]+$")
      or ev.id:find("..", 1, true) or ev.id:sub(1, 1) == "." or sync.is_mine(ev.id, cfg.user) then return false end
  local direct = require("direct")
  local dir = sync.room_dir(cfg, song, room) .. "/events"
  local idir = direct.inbox_dir(cfg, dir)
  local name = ev.id .. ".json"
  if not idir or reaper.file_exists(dir .. "/" .. name) or reaper.file_exists(idir .. "/" .. name) then return false end
  reaper.RecursiveCreateDirectory(idir, 0)
  band.write_json(idir .. "/" .. name, ev)
  return true
end

-- May the band's changes come in now? Only once a look (mirror.watch) has seen this computer's last change: that look marks it as yours and
-- unsent, so theirs waits for it. Before it, a bandmate's change to the same item landed over yours with no trace (review, 0.58.47). 30 s at
-- most. cc: the project's change count now; looked_cc, looked_at: the count just after the last look, and when it ran.
-- changed_at (Live sync's): when your last edit was noted. A look that began after it has seen it, whatever the count says since: StudioSync's
-- own writes between passes (taken in, not you editing) moved the count, and a change over the direct link waited for the next 2 s pass, about
-- a second on average (rt-look: desktop -> laptop took 1.2-1.6 s).
function sync.seen_mine(cc, looked_cc, now, looked_at, changed_at)
  return cc == looked_cc or (changed_at ~= nil and changed_at < looked_at) or now - looked_at > 30
end

-- Real-time cadence (pure; Live sync's tick). A look goes 0.1 s after your last edit settles, not at the next 2 s pass (desktop -> laptop
-- took 1.6-2.3 s with a 30 ms link. James, rt). SETTLE: a drag's drop or a burst of edits is one look. Never mid-drag, and the pass
-- gets at most a fifth of REAPER's time on a big song, as the look's own mirror_took guard.
-- changed_at: when your last edit was seen; polled_at, pass_took: when the last pass started and how long it took.
sync.SETTLE, sync.QUIET, sync.QUIET_DIRECT, sync.DIRECT_FRESH = 0.1, 2, 0.4, 10
function sync.look_now(changed_at, polled_at, pass_took, now, mouse)
  return not mouse and changed_at > polled_at and now - changed_at >= sync.SETTLE and now - polled_at > pass_took * 5
end
-- May the cloud copy's pass run now? Not within DRIVE_QUIET s of your last edit or of a bandmate's change over the link: a pass lists the cloud
-- drive's folders and holds REAPER meanwhile (0.2-0.3 s on the desktop, ~1 s on the laptop), and an edit or a change landing in one waited
-- for it. Never held past `every` s since the last pass (drive.EVERY), so a long session still gets its copy. Pure. rt-look
sync.DRIVE_QUIET = 3
function sync.drive_quiet(now, changed_at, direct_in_at, drive_at, every)
  if now - (drive_at or -math.huge) > (every or 180) then return true end
  return now - (changed_at or -math.huge) >= sync.DRIVE_QUIET and now - (direct_in_at or -math.huge) >= sync.DRIVE_QUIET
end
-- How long after your last edit the band's changes wait: 0.4 s while they come over the direct link (arrived in the last 10 s), 2 s on
-- Syncthing alone as before. (Unsent edits stay protected per object in mirror.receive, a drag by the mouse gate. James, rt)
function sync.quiet_for(now, direct_at) return now - (direct_at or -math.huge) < sync.DIRECT_FRESH and sync.QUIET_DIRECT or sync.QUIET end
-- A pass the moment the quiet window ends, for what came over the link and waited for your edit: else it waited for the next 2 s pass.
-- held: something arrived and isn't in yet. Again every RETRY s (and a big song's fifth) while it's held for any reason that passes: the mouse
-- let go, a look that hadn't run. Not while `blocked`: a redo waiting (the band's changes wait 30 s on purpose). rt-look
sync.RETRY = 0.1
function sync.receive_now(held, changed_at, quiet, polled_at, pass_took, now, mouse, blocked)
  return held and not mouse and not blocked and now >= changed_at + quiet and now - polled_at > math.max(pass_took * 5, sync.RETRY)
end
-- Are you editing? Your last edit within `quiet` s, or the mouse held; never more than 10 s in a row, so a long edit can't hold the band's
-- changes up for good. -> busy, held_since (kept by the caller).
function sync.editing_now(now, changed_at, held_since, quiet, mouse)
  local busy = now - changed_at < quiet or mouse
  if busy then held_since = held_since or now else held_since = nil end
  return busy and now - held_since < 10, held_since
end

-- Apply events this project hasn't applied yet, oldest first, from whoever may make each one.
-- Opening a project (James, 0.58.82: "is there any way to pre-load everything better when loading a project?"): until its first catch-up is
-- done, with the transport stopped, it takes a second of applying per pass instead of a quarter (you're waiting for it then, not playing),
-- with the arrange view held still meanwhile; then REAPER builds the peaks of everything that arrived, so the first play and the first
-- zoom don't stall on them. Live sync marks a project loading as it starts (sync.loading).
sync.loading = {} -- tostring(proj) -> true until its first catch-up is done
sync.LOAD_BUDGET, sync.BUDGET = 1.0, 0.25
local peaks_due = {}
local loading_said = {} -- tostring(proj) -> true: "loading <proj>" is published (sync.receive)
sync.live_in = {} -- tostring(proj) -> true: Live sync runs for that tab in this script (sync.begin_loading; lib/recall.lua)
-- Live sync opening a project: its first catch-up starts now, and "loading <proj>" is published at once, not on the first receive, which waits
-- for the first look (a panel save in those seconds was mapped though still behind). Cost: one non-persisted ExtState. Round 4 review, 0.59.49
function sync.begin_loading(proj)
  local pk = tostring(proj)
  sync.loading[pk], loading_said[pk], sync.live_in[pk] = true, true, true
  reaper.SetExtState(band.SECTION, "loading " .. pk, "1", false)
end
-- A change from a newer StudioSync: a kind this one doesn't know, or a newer file format. Pure.
sync.KNOWN = { obj = true, timeline = true, start = true, stop = true, note = true, like = true, driver = true, shift = true, solo = true }
-- (and one made below the studio's version floor: held here as a too-new one is, never applied. sync.held_by_floor, docs/rt/rt-floor.md)
function sync.too_new(ev)
  return not sync.KNOWN[ev.type] or (tonumber(ev.format) or 0) > band.FORMAT or sync.held_by_floor(ev)
end
-- ---- the version floor (docs/rt/rt-floor.md) ------------------------------------------------------------------------------------------------
-- StudioSync's level: raised at a release whose events older code mustn't mix with (what goes into a hash, mirror.HV; the event format,
-- band.FORMAT). Every event carries it (`lv`, sync.post). The studio's floor is the highest level any computer has run there, recorded in
-- <root>/_band/floor as "<level>-<user>.json" ({ level, since }), files nobody deletes, so it only goes up and a computer that never ran the
-- new code still finds it. A computer below the floor sends nothing and says "update StudioSync" (Live sync, Health); one at the floor holds,
-- never applies, a change made below it: one with a lower `lv`, or one with none (a StudioSync from before floors) made since the floor was
-- first recorded. Held, not dropped: it stays in the room unapplied and unmarked (docs/rt/rt-floor.md says why that loses nothing).
sync.LEVEL = 14 -- (11: rt-floor, the first floor; mirror.HV 11. 12: times in beats, mirror.HV 12, rt-sync2f. 13: fades and snap offset in beats where they sit, mirror.HV 13, rt-sync2g. 14: stretch markers as REAPER keeps them at a tempo change, mirror.HV 14, rt-fixlive2)
sync.FLOOR_EVERY = 10 -- seconds a read of the floor folder is kept
sync.floor_now = nil -- { level, since, below, root } as last read (sync.floor), or nil: none read in this Lua state yet (nothing held)
local floor_read = {} -- root -> { at, f }
function sync.floor_dir(cfg) return cfg.root .. "/_band/floor" end
-- The studio's floor, read (at most every FLOOR_EVERY s unless `fresh`), raised to this computer's level first if that's higher.
-- -> { level, since, below, root }. Changes nothing held here: sync.floor does that.
function sync.floor_read(cfg, fresh)
  local now, root = reaper.time_precise(), tostring(cfg and cfg.root or "")
  local r = floor_read[root]
  if r and not fresh and now - r.at < sync.FLOOR_EVERY then return r.f end
  -- (since: when the first floor of all was recorded, whatever its level: a change with no `lv` is from before floors, and only that tells
  -- one made after it from history. "~" sorts after every time: none known, none held)
  local dir, level, since = sync.floor_dir(cfg), 0, "~"
  for _, f in ipairs(band.files(dir, ".json")) do
    local n = tonumber(f:match("^(%d+)%-"))
    local v = n and band.read_json(dir .. "/" .. f)
    local s = type(v) == "table" and type(v.since) == "string" and v.since or "~" -- (a file still arriving: its level counts, its time not yet)
    if n and n > level then level = n end
    if n and s < since then since = s end
  end
  if sync.LEVEL > level then
    local t = os.date("!%Y-%m-%dT%H:%M:%SZ")
    level = sync.LEVEL
    if t < since then since = t end
    reaper.RecursiveCreateDirectory(dir, 0)
    pcall(band.write_json, dir .. "/" .. level .. "-" .. sync.id_user(cfg.user) .. ".json", { level = level, since = t }) -- (unwritten: the next read tries again)
  end
  local f = { level = level, since = since, below = sync.LEVEL < level, root = root }
  floor_read[root] = { at = now, f = f }
  return f
end
-- The floor this Lua state goes by (Live sync's pass, sync.preload): what's held and whether anything goes out. -> floor_now
-- (the "older than the studio's" lines are said once each time: this computer's again once it's back at the floor and drops below it again or
-- the floor rises; a bandmate's again once the floor rises. Once per Lua state, a second drop said nothing. Live check floor f3, rt-fixlive1)
function sync.floor(cfg, fresh)
  local was = sync.floor_now
  sync.floor_now = sync.floor_read(cfg, fresh)
  local risen = was ~= nil and was.level ~= sync.floor_now.level
  if risen or not sync.floor_now.below then sync.floor_said = nil end
  if risen then sync.floor_held = nil end
  return sync.floor_now
end
-- Is this computer below the studio's floor (as last read)? Then nothing goes out (sync.post refuses; the look, heal and Undo don't run).
function sync.below_floor() return sync.floor_now ~= nil and sync.floor_now.below end
-- Was `ev` made below the floor? A lower level, or none at all on a change made since the floor was first recorded (history from before
-- the floor has none either, and lands as ever). Pure but for floor_now.
-- (not a timeline change with a level: the floor guards what goes into a hash (mirror.HV) and the event format (band.FORMAT, checked on its
-- own), and a timeline has no hash, its shape kept by TIMELINE_FORMAT since before floors. Held, the room's newest map after a deploy that
-- raised the level was one nobody applied: LinuxBox and the desktop, restarted onto older files, kept theirs. rt-sync2h)
function sync.held_by_floor(ev)
  local f = sync.floor_now
  if not f then return false end
  local lv = tonumber(ev.lv)
  if lv then return lv < f.level and ev.type ~= "timeline" end
  return type(ev.time) == "string" and ev.time >= f.since
end
-- What a computer below the floor says, in Live sync's log and on Health (panel and web).
function sync.floor_words(f)
  f = f or sync.floor_now or {}
  return string.format("This computer's StudioSync (%s, level %d) is older than the studio's (level %s): nothing you change here goes to the "
    .. "others until you update StudioSync. You still get their changes.", band.VERSION, sync.LEVEL, tostring(f.level))
end
sync.version_looked = {} -- proj -> true: its skipped changes were looked at for this version
-- An object change StudioSync can read. (Checked before the newest of each object is picked: a malformed or newer-format one, picked as the
-- newest, marked the readable ones before it superseded, and was then skipped itself. 0.59.14, review) (A JSON null is StudioSync's own json's,
-- band.json: another script's "json" in Autostart's Lua read null as nil, and every deletion as unreadable. rt-sync2j)
function sync.readable(ev)
  return type(ev.oid) == "string" and (ev.obj == "item" or ev.obj == "track" or require("mirror").PART[ev.obj]) and type(ev.rev) == "number"
    and (ev.gone or type(ev.state) == (ev.obj == "track" and "table" or "string")) and ev.state ~= band.json.null and (ev.name == nil or type(ev.name) == "string") and (ev.pos == nil or type(ev.pos) == "number")
end
function sync.receive(proj, cfg, song, room, can)
  local pk = tostring(proj)
  -- (changes skipped for good (unreadable, failed five times) are tried once more when StudioSync's version changes: a newer version may read
  -- them. Only in a project with any, so nothing is written otherwise. Round 2 review, 0.59.46)
  if not sync.version_looked[pk] then
    sync.version_looked[pk] = true
    if #sync.skipped(proj) > 0 and ext(proj, band.SECTION, "skipped for") ~= band.VERSION then
      setext(proj, band.SECTION, "skipped for", band.VERSION)
      sync.retry_skipped(proj)
    end
  end
  -- (published while its first catch-up runs, for saved versions made from the panel: lib/recall.lua. Not kept past REAPER, and read only
  -- while Live sync runs in the tab. Round 3 review, 0.59.48)
  if sync.loading[pk] and not loading_said[pk] then loading_said[pk] = true; reaper.SetExtState(band.SECTION, "loading " .. pk, "1", false) end
  if peaks_due[pk] then -- (built a step a tick in any tab, not REAPER's modal "Build any missing peaks" in the front one: lib/peaks.lua, rt-setup)
    peaks_due[pk] = nil
    require("peaks").want(proj)
  end
  local budget = (sync.loading[pk] and reaper.GetPlayStateEx(proj) == 0) and sync.LOAD_BUDGET or sync.BUDGET
  local dir = sync.room_dir(cfg, song, room) .. "/events"
  local pending = {}
  local drivers = sync.driver_history(proj, cfg, song, room)
  -- (files read once while they wait: a backlog of 300 was read and decoded again on every pass; laptop, 0.34.4)
  local cache, kept = sync.ev_cache[dir] or {}, {}
  local settled = sync.settled_for(proj, dir)
  -- (reading, too, a pass's budget at a time: back from a week away, every new file was read and decoded in one go, and REAPER stood still
  -- meanwhile. What's read waits in the cache, and nothing is applied until all of it is: the newest-only rules below need every file.
  -- Review, 0.58.91)
  local t_read, cut = reaper.time_precise(), false
  -- (the unsorted listing, the one pending_events shares: pending is sorted below anyway. Round 1 review, 0.59.45)
  -- (with what came over the direct link, read from its inbox until Syncthing's copy is here: lib/direct.lua. James, 0.60.0-rt)
  local names, from = require("direct").listing(cfg, dir)
  for _, f in ipairs(names) do -- (shared with this poll's other looks at the folder: 0.59.14, review)
    if not settled[f] and ext(proj, sync.APPLIED, f:sub(1, -6)) ~= "" then sync.settle(settled, f) end
    if not settled[f] and not cache[f] and reaper.time_precise() - t_read > budget then cut = true; break end
    if not settled[f] then
      local ev = cache[f] or band.read_json(from and from[f] or dir .. "/" .. f)
      -- a malformed or half-synced file must not stop everything behind it; one still unreadable after 10 minutes
      -- (not a file a cloud drive is still writing) is skipped for good, or it counts as "still to come" for ever
      -- and Who's here never shows the same project again (laptop, block K: a truncated file left pending at 1)
      local good = type(ev) == "table" and type(ev.id) == "string" and type(ev.time) == "string" and type(ev.user) == "string" and type(ev.type) == "string"
      -- (named for its id, or what's applied (by id) never matches the file (by name), and it's applied again every pass: a renamed timeline
      -- change put the tempo map back every 2 s. No slashes either: ids name files to read. Review, 0.58.53)
      good = good and ev.id == f:sub(1, -6) and not ev.id:find("[/\\]") and (ev.base_ev == nil or (type(ev.base_ev) == "string" and not ev.base_ev:find("[/\\]")))
      -- (the fields the bookkeeping reads before anything's applied: a number for a take, a table for an order, an hlc that isn't a whole
      -- number threw every pass, outside the per-event pcall, and nothing was received from then. Review, 0.58.98)
      local function str_or_nil(v) return v == nil or type(v) == "string" end
      local hlc = type(ev) ~= "table" or ev.hlc == nil or (tonumber(ev.hlc) and tonumber(ev.hlc) == math.floor(tonumber(ev.hlc)) and math.abs(tonumber(ev.hlc)) < 2 ^ 53)
      good = good and str_or_nil(ev.take) and str_or_nil(ev.track) and str_or_nil(ev.was) and str_or_nil(ev.order) and str_or_nil(ev.item)
        and str_or_nil(ev.oid) and hlc and true or false
      -- (10 minutes, not 2: Google Drive and OneDrive write a file in place, and a slow one was skipped for good a minute before it was whole.
      -- Review, 0.58.53)
      if not good then
        local id = f:sub(1, -6)
        sync.unreadable[id] = sync.unreadable[id] or reaper.time_precise()
        -- (asked of the bandmates here by id first, and skipped at once when every one asked says it hasn't it: nobody made it. One they have,
        -- a cloud drive still writing it here, gets its UNREADABLE_SECS. lib/needlist.lua, rt-sync2 5b, rt-sync2j)
        local nl, rdir = require("needlist"), sync.room_dir(cfg, song, room)
        nl.want_id(rdir, id, true)
        if nl.gone_everywhere(rdir, id) or reaper.time_precise() - sync.unreadable[id] > sync.UNREADABLE_SECS then
          -- (on Health's skipped list, so Try again can have it once it's whole: marked done, it was never looked at again. Review, 0.58.92)
          sync.skip(proj, { id = id, user = type(ev) == "table" and type(ev.user) == "string" and ev.user or "?" }, "its file couldn't be read (half-synced or damaged)")
          band.log("skipped a file in the studio's folder that StudioSync can't read (" .. f .. ")")
        end
      end
      if good then
        if sync.unreadable[f:sub(1, -6)] then require("needlist").by_id[sync.room_dir(cfg, song, room) .. "\0" .. f:sub(1, -6)] = nil end
        sync.unreadable[f:sub(1, -6)] = nil
        kept[f] = ev
        pending[#pending + 1] = ev
        if ev.type == "driver" then
          drivers[ev.id:upper()] = { time = ev.time, user = ev.driver or ev.user }
          setext(proj, sync.DRIVERS, room .. "/" .. ev.id, ev.time .. "|" .. tostring(ev.driver or ev.user)) -- (kept, so the next open needn't look for it)
        end
      end
    end
  end
  if cut then
    for f, ev in pairs(cache) do kept[f] = kept[f] or ev end
    sync.ev_cache[dir] = kept
    sync.read_cut = true -- (preload: not "nothing to do", only "not read yet". Review, 0.58.96)
    return 0
  end
  sync.read_cut = nil
  -- (each one's key made once, not twice a comparison: 4,400 events in a catch-up made ~100,000 joined strings a pass. Bigger projects, rt)
  local sort_key = {}
  for _, ev in ipairs(pending) do sort_key[ev] = ev.time .. ev.id end
  table.sort(pending, function(a, x) return less(sort_key[a], sort_key[x]) end)
  local function driver_at(t) -- who drove when this happened
    local best
    for id, d in pairs(drivers) do -- two handovers in the same second: the later id, so every machine agrees
      if d.time <= t and (not best or d.time > best.time or (d.time == best.time and less(best.id, id))) then best = d; best.id = id end
    end
    return best and best.user
  end
  -- A timeline event is the whole map: only the newest is applied. (Every older map landing in turn, between looks, re-timed
  -- beat-timebase items, and those went out as edits: 158 from the laptop in one catch-up. Sync engine review, 0.58.76)
  local newest_map
  -- (ours count too, and the newest this project already has: an older map of theirs landed over our newer one, theirs took ours, and the two
  -- projects kept different tempo maps. Review, 0.58.92)
  newest_map = sync.newest_map(pending, ext(proj, sync.NEWEST, "timeline"))
  sync.map_pending[pk] = newest_map ~= nil -- (a newer map waits here: sync.timeline_behind)
  -- Both worked alone (neither could see the other's changes): theirs may undo some of ours. Before
  -- any of them lands, where things are here is saved as a kept restore point, so our side is never lost.
  local mine_alone = ext(proj, band.SECTION, "alone_last")
  for _, ev in ipairs(pending) do
    -- (whatever its time: they may have worked alone an hour before us, or after; either way the two versions split)
    if ev.alone and ev.user ~= cfg.user and mine_alone ~= "" and not superseded(proj, ev) then
      -- (with its map even mid catch-up: what it holds is exactly "yours before", and by time it brought their earlier work. Round 3 review, 0.59.48)
      require("recall").save(proj, cfg, song, room, "yours before " .. ev.user .. "'s work done alone", true, true)
      setext(proj, band.SECTION, "alone_last", "") -- once per meeting
      band.log(ev.user .. " also worked on this while you were both alone: where you were is kept as a saved version " ..
        "(Restore) before their changes land")
      break
    end
  end
  local readable = sync.readable
  -- Every readable change lands, judged by the judge alone: claims, room modes, asks, holds and put-backs are enforced where the edit is made
  -- (mirror.watch's W.refuse, lib/claimask.lua, the web pages), and the studio's floor holds every change from a StudioSync too old to ask
  -- (sync.held_by_floor). Refused here, a change waited a minute and then landed anyway, which made computers differ for that minute and
  -- needed five special cases (soft_ok, unasked, gone_before_claim, rename_stands, the same second), and a claimer's computer answered a
  -- rename with one of its own (set_back), which lost a Redo everywhere (the soak's 127, 6006). rt-sync2 section 4, option A; rt-sync2h.
  -- What's left is a word to the claimer: a bandmate's change to this computer's claim that went out without asking (their claim check
  -- crossed with yours, the direct link couldn't reach you for an auto-claim, or a modified StudioSync) is said, once a minute per person and
  -- thing. -> the name it's claimed under here, or nil. By the claims as they stood when it was made (sync.authority's `at`).
  local function past_mine(ev)
    if ev.type ~= "obj" or ev.user == cfg.user or ev.alone or sync.room_mode == "driver" or sync.room_mode == "everyone" then return nil end
    local name = ev.name or ""
    if ev.obj == "track" and not ev.gone then -- (a rename: the claim is on the name it has here)
      local tr = require("mirror").find(proj, "track", ev.oid)
      local here = tr and select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)) or ""
      if here ~= "" then name = here end
    end
    local drv = driver_at(ev.time)
    if not (sync.is_claimed and sync.is_claimed(name, ev.pos, ev.time) and can(cfg.user, name, ev.pos, nil, drv, ev.time)) then return nil end
    if sync.obj_allowed(setmetatable({ name = name }, { __index = ev }), can, drv) then return nil end
    -- (an auto-claim of mine: its sender asks only for an edit that clashes with mine, and one that merges goes out unasked by design)
    if not ev.unasked and sync.soft and sync.soft.room == room and sync.soft.fn(name, ev.pos, ev.user) == cfg.user then return nil end
    return name
  end
  sync.ev_cache[dir] = kept
  local t0, budget_out = reaper.time_precise(), false -- (and a quarter second of applying per pass, a second while loading: the rest next pass)
  require("mirror").index_for(proj)
  local applied, done, undo_open, late_point, fresh_move = 0, {}, false, false, false
  sync.backlog = false
  local rdir = sync.room_dir(cfg, song, room)
  local evindex = require("evindex")
  -- (what was read, in the index (light: a state is read again from its file when asked), so the judge has every version of each object.
  -- rt-sync2b)
  for f, ev in pairs(kept) do
    if ev.type == "obj" and readable(ev) then evindex.add(rdir, require("mirror").light_of(rdir, f, ev), f) end
  end
  -- After a change landed (or was handled): marked done, and said. `waited`: it waited last pass (its undo point comes after the pass).
  local function after(ev, theirs_obj)
    setext(proj, sync.APPLIED, ev.id, "1")
    stamp(proj, ev)
    if require("mirror").order_moved[pk] then -- (it moved a track here: mirror.apply. The order list follows, below)
      require("mirror").order_moved[pk] = nil
      fresh_move = fresh_move or band.age(ev.time) < sync.CUE_OLD
    end
    if type(ev.note) == "string" and ev.user ~= cfg.user and band.age(ev.time) < 3600 then band.log(ev.note) end -- (a copy's credit, a bus: mirror.watch)
    -- (nor one mirror.receive dropped (on a deleted track, beaten by a deletion, older than what's here): "James-Laptop: changed an item on
    -- XT Drums A" was logged for an edit that never landed. Cross test, James, rt)
    local obj = ev.type == "obj"
    local theirs = ev.user ~= cfg.user and (not obj or theirs_obj) -- (your own changes come back too: they aren't "from the band")
    if theirs then applied = applied + 1 end
    if theirs and (obj or ev.type == "timeline") then pcall(require("compat").landed, proj, obj and ev.oid or "timeline") end -- (a change here to it soon after: lib/compat.lua)
    local what = ({ timeline = "changed the tempo map / markers",
      start = (ev.rec and "record" or "play") .. " together at " .. tostring(ev.pos), stop = "stop together",
      note = "note: " .. tostring(ev.text), like = "liked " .. tostring(ev.take or (ev.track and ("a part on " .. ev.track)) or "a part"),
      obj = (ev.gone and "deleted " or "changed ") .. (require("mirror").PART[ev.obj] or (ev.obj == "item" and "an item" or "a track")) ..
        " on " .. ((ev.name or "") ~= "" and ev.name or "an unnamed track"),
      shift = ((ev.len or 0) > 0 and "inserted " or "removed ") .. string.format("%.2f s at %.2f s", math.abs(ev.len or 0), ev.at or 0) })[ev.type]
    if theirs and what then done[#done + 1] = ev.user .. ": " .. what end
  end
  -- Object changes are gathered per object (`groups`, in the order their first change came) and judged once each below. The rest land in
  -- time order around them: a tempo map (and inserted time) after the tracks and before their parts and items (a region names the tracks it
  -- renders; an item lands on its beat under the map in place, mirror.on_map), anything else after them all (a note names an item).
  local groups, gorder, maps, later = {}, {}, {}, {}
  for _, ev in ipairs(pending) do
    if budget_out then break end
    local obj = ev.type == "obj"
    if sync.OLD_TYPES[ev.type] then
      setext(proj, sync.APPLIED, ev.id, "1")
      if not sync.old_types_said then sync.old_types_said = true; band.log("skipped changes from " .. tostring(ev.user) .. "'s older StudioSync (before 0.32.0): they should update") end
    elseif sync.too_new(ev) then
      -- (a kind of change or a format this version doesn't know: left unapplied for the version that does, not marked done, so it lands once
      -- this computer updates. Set aside like a change waiting on a claim, so it isn't counted as "still to come". Round 2 review, 0.59.46)
      sync.deferred[ev.id] = true
      if sync.held_by_floor(ev) and not sync.below_floor() then -- (made below the studio's floor: held for good here, docs/rt/rt-floor.md)
        sync.floor_held = sync.floor_held or {}
        if not sync.floor_held[tostring(ev.user)] then
          sync.floor_held[tostring(ev.user)] = true
          band.log(tostring(ev.user) .. "'s StudioSync is older than the studio's: their changes wait, unapplied, until they update StudioSync and make them again")
        end
      elseif not sync.too_new_said then sync.too_new_said = true; band.log(tostring(ev.user) .. " sent a change this StudioSync doesn't know yet: update StudioSync and it lands") end
    elseif obj and not readable(ev) then
      sync.skip(proj, ev, "StudioSync can't read it") -- malformed (a newer or damaged file): skipped, once, without stopping the rest
      band.log("skipped a change from " .. tostring(ev.user) .. " that StudioSync can't read (" .. tostring(ev.id) .. ")")
    elseif (ev.type == "timeline" and ev.user ~= cfg.user and newest_map ~= ev.id) or superseded(proj, ev) then
      setext(proj, sync.APPLIED, ev.id, "1") -- superseded
    -- (a start or stop from long ago: a project reopened from an old file read every one since as news, and the log said "<who>: record together
    -- at 1.84" and "stop together" at each restart. Live sync never played them (their moment had passed), so nothing to do and nothing to say.
    -- sync.CUE_OLD seconds: a producer's cue counts for 30, a band one for its lead. rt-edits)
    elseif (ev.type == "start" or ev.type == "stop") and band.age(ev.time) > sync.CUE_OLD then
      setext(proj, sync.APPLIED, ev.id, "1")
    -- (not our own newest map when it's newer than this project's: REAPER killed or restarted without saving reopened a file from before it, and
    -- marked done unapplied, the file's older tempo, markers and settings stayed, and went out with the next marker. Crash-safe sessions, James, rt)
    elseif ev.user == cfg.user and not obj and not (ev.type == "timeline" and newest_map == ev.id) then
      setext(proj, sync.APPLIED, ev.id, "1") -- our own: already true here
      stamp(proj, ev) -- and what we change next comes after it, even one stamped while our clock ran ahead
    elseif obj then
      if not groups[ev.oid] then groups[ev.oid] = {}; gorder[#gorder + 1] = ev.oid end
      table.insert(groups[ev.oid], ev)
    elseif ev.type == "timeline" or ev.type == "shift" then maps[#maps + 1] = ev
    else later[#later + 1] = ev end
  end
  -- Each object that changed, judged once (mirror.judge, lib/judge.lua: its versions here, not the order they came in), and put in place when
  -- the answer differs from what's held: tracks first, each after the track it sits under when that one is in the pass too (a late joiner put
  -- a track first and kept it there: rt-edits), then their parts, then items, by id. A track that came back or went in this pass brings what
  -- it holds into the same pass (lib/evindex.lua contents: its items and parts, judged; one that can't land now is tried again next pass,
  -- sync.contents_due). This replaces newest-only catch-up (latest, apart, superseded objects, the after-sort), the lands check (wins,
  -- merge_for, lands_over), and the heals at the end of a pass for a returning track (orphaned) or an edit over a held deletion (heal_due).
  -- rt-sync2b
  local function land_rest(list) -- (one undo point per pass for all of it, and the pass's budget)
    for _, ev in ipairs(list) do
      if budget_out then break end
      -- one undo point per pass, only when something lands: reading our own change back opened one too, which sat on
      -- top of the edit and held its print, so Ctrl+Z took two presses and the first left the note moved (PC, 0.40.3)
      -- one bad event must never block everything behind it (2026-10-28: a take-less "driver" event threw on every
      -- pass, so the handover's edits and tempo change never applied): log it and move on
      -- (no undo block for a change that waited last pass: the block opened before apply said it waits, and closed named whatever happened, an
      -- empty undo point every pass while a recording arrived or a part was open in the MIDI editor. Each changed the project's count (a full look and a 2 s pause followed), and on top of REAPER's list sent Ctrl+Z StudioSync's
      -- way. One that waited and lands now gets its point after: below. Cost: one table entry per waiting change. Round 2 review, 0.59.46)
      local waited = sync.waited[ev.id]
      local ok, res = pcall(function()
        if sync.alters(proj, ev) and not waited and not undo_open then reaper.Undo_BeginBlock2(proj); undo_open = true end
        return sync.apply(proj, ev, rdir, can, cfg.user)
      end)
      if ok and res == false then sync.waited[ev.id] = true
      elseif ok and res and waited then sync.waited[ev.id], late_point = nil, true end
      if not ok then
        band.log("skipped a change from " .. tostring(ev.user) .. " that StudioSync couldn't apply (" .. tostring(ev.type) .. "): " .. tostring(res))
        sync.skip(proj, ev, res)
      elseif res then
        after(ev)
        if reaper.time_precise() - t0 > budget then budget_out, sync.backlog = true, true end
      end
    end
  end
  local maps_done = false
  local m = require("mirror")
  local due = sync.contents_due[pk] or {}
  sync.contents_due[pk] = nil
  local force, placed, order = {}, {}, {}
  local due_list = {}
  for oid in pairs(due) do due_list[#due_list + 1] = oid end
  for _, oid in ipairs(due_list) do if not groups[oid] then gorder[#gorder + 1] = oid end; force[oid] = true end
  local rank = { T = 1, F = 2, E = 2, R = 2, M = 2 }
  table.sort(gorder, function(a, b)
    local ra, rb = rank[a:sub(1, 1)] or 3, rank[b:sub(1, 1)] or 3
    if ra ~= rb then return ra < rb end
    return less(a, b)
  end)
  local function place(oid)
    if placed[oid] then return end
    placed[oid] = true
    local l = groups[oid]
    local top = l and l[#l]
    local above = top and top.obj == "track" and not top.gone and type(top.state) == "table" and type(top.state.after) == "string" and top.state.after
    if above and groups[above] then place(above) end
    order[#order + 1] = oid
  end
  for _, oid in ipairs(gorder) do place(oid) end
  local media, i = rdir .. "/media", 1
  while i <= #order do
    local oid = order[i]
    i = i + 1
    if not maps_done and oid:sub(1, 1) ~= "T" then maps_done = true; land_rest(maps) end
    if budget_out then -- (the rest next pass: their changes are still waiting; what a returning track holds, as owed)
      if not groups[oid] then sync.contents_due[pk] = sync.contents_due[pk] or {}; sync.contents_due[pk][oid] = true end
    else
      -- (a change made just before a tempo map it hasn't reached here yet lands now, in beats: REAPER keeps it on its beat when the map comes,
      -- so it no longer waits for the map (REAPER check F6's double move can't happen). lib/beats.lua, rt-sync2f)
      local list = {}
      for _, x in ipairs(groups[oid] or {}) do list[#list + 1] = x end
      local ev = list[#list] -- (the newest that came in: what the log names)
      local wkey = ev and ev.id or ("obj " .. oid) -- (the newest change's id: as each change's own was before)
      local waited = sync.waited[wkey]
      local had = oid:sub(1, 1) == "T" and m.find(proj, "track", oid) ~= nil
      local past = ev and past_mine(ev) -- (before it lands: a rename's claim is on the name it has here now)
      if groups[oid] and not ev then goto next_obj end
      -- (whether it lands, inside the same pcall: the judge reads events too, and an error there stopped the pass with an undo block open.
      -- 0.59.14, review) (nor on its first wait, where that's cheap to know: mirror.will_wait. Round 3 review, 0.59.48)
      local ok, res = pcall(function()
        local s = m.judge(proj, oid, rdir, list)
        local lands = m.lands(proj, s, force[oid])
        if lands and not waited and m.will_wait(proj, s.v) then waited = true end
        if lands and not waited and not undo_open then reaper.Undo_BeginBlock2(proj); undo_open = true end
        return m.receive(proj, ev, media, sync.local_mix, cfg.user, list, s, force[oid])
      end)
      if ok and res == false then
        sync.waited[wkey] = true
        if not ev then sync.contents_due[pk] = sync.contents_due[pk] or {}; sync.contents_due[pk][oid] = true end
      elseif ok and res and waited then sync.waited[wkey], late_point = nil, true end
      if not ok then
        local first = ev and ev.id or oid
        sync.failed[first] = (sync.failed[first] or 0) + 1
        if sync.failed[first] >= 5 then
          for _, x in ipairs(list) do
            band.log("skipped a change from " .. tostring(x.user) .. " that StudioSync couldn't apply (" .. tostring(x.type) .. "): " .. tostring(res))
            sync.skip(proj, x, res)
          end
        elseif not ev then sync.contents_due[pk] = sync.contents_due[pk] or {}; sync.contents_due[pk][oid] = true end
      elseif res then
        local theirs = not m.dropped
        for _, x in ipairs(list) do if x == ev then after(x, theirs) else setext(proj, sync.APPLIED, x.id, "1"); stamp(proj, x) end end
        local pk2 = past and (pk .. "\0" .. ev.user .. "\0" .. past:lower())
        if pk2 and theirs and reaper.time_precise() - (sync.past_said[pk2] or -math.huge) > 60 then
          sync.past_said[pk2] = reaper.time_precise()
          local renamed = ev.obj == "track" and not ev.gone and past:lower() ~= tostring(ev.name or ""):lower()
          band.log(string.format("%s %s %s, which you've claimed%s: their StudioSync %s", ev.user, ev.gone and "deleted" or renamed and "renamed" or "changed",
            past, renamed and (", to " .. tostring(ev.name)) or "", ev.unasked and "couldn't reach you to ask" or "didn't ask"))
        end
        if not ev and theirs then applied = applied + 1 end
        if reaper.time_precise() - t0 > budget then budget_out, sync.backlog = true, true end
        if had ~= (oid:sub(1, 1) == "T" and m.find(proj, "track", oid) ~= nil) then
          for _, c in ipairs(evindex.contents(rdir, oid)) do
            force[c] = true
            if not placed[c] then placed[c] = true; order[#order + 1] = c end
          end
        end
      end
    end
    ::next_obj::
  end
  if not maps_done then land_rest(maps) end
  land_rest(later)
  require("mirror").index_for(nil)
  local track_landed = require("mirror").order_band[pk] -- (before order_after_band takes it: the sort below. rt-sync2c)
  require("mirror").order_after_band(proj)
  -- (a bandmate's track move landed in this pass: this computer says the order it has now. The studio's order is the newest list anyone
  -- wrote, each a whole list, and only movers wrote one: of two moves made at once the later mover's list had not the other's move in it, so
  -- a late joiner, who goes by the list, lost that move while everyone who was here had both. With each computer saying its order as moves
  -- land, the newest list is one with every move in it. A small file per landed move. Only for a move made in the last CUE_OLD seconds, on
  -- a project past its first catch-up: a computer catching up on old moves would say an order half-way through them, and as the newest
  -- list that became the studio's. rt-converge)
  if fresh_move and not sync.loading[pk] then pcall(require("mirror").publish_order, proj, sync.room_dir(cfg, song, room), cfg.user) end
  if undo_open then reaper.Undo_EndBlock2(proj, "StudioSync: changes from the others", -1)
  -- (a change that waited, landed: its point now. Every kind of state, not items only (Undo_OnStateChange2): a plug-in chain, automation or
  -- track change landing under an items-only point was taken back by your next native Ctrl+Z and sent as your change. Round 3 review, 0.59.48)
  elseif late_point then reaper.Undo_OnStateChangeEx2(proj, "StudioSync: changes from the others", -1, -1) end
  -- (a track landed in a room with ranks: the whole order sorted by them now, not only the track that landed (mirror.apply placed that one
  -- among tracks that may sit elsewhere here). Not mid-drag; keep_order itself waits for the tab in front, stopped and caught up. rt-sync2
  -- section 3 "Applying", rt-sync2c)
  if track_landed and not sync.loading[pk] and not (reaper.JS_Mouse_GetState and (tonumber((reaper.JS_Mouse_GetState(1))) or 0) & 1 == 1)
      and require("mirror").ranked(proj) then
    -- (playing or recording: at the next stop, by mirror.watch's keep_order, not never. rt-live bug 4)
    if reaper.GetPlayStateEx(proj) & 5 ~= 0 then require("mirror").order_owed[pk] = true
    else pcall(require("mirror").keep_order, proj, cfg, song, room) end
  end
  if sync.loading[pk] and not budget_out then
    sync.loading[pk], loading_said[pk] = nil, nil
    reaper.DeleteExtState(band.SECTION, "loading " .. pk, false)
    peaks_due[pk] = true
    if sync.load_count and sync.load_count[pk] and sync.load_count[pk] > 0 then
      band.log(string.format("loaded: the studio's %d change(s) since you last had this open are in; building the waveforms of what arrived", sync.load_count[pk]))
    end
  end
  if sync.loading[pk] then sync.load_count = sync.load_count or {}; sync.load_count[pk] = (sync.load_count[pk] or 0) + applied end
  for _, d in ipairs(done) do band.log(d) end
  return applied
end

-- ---- status receipts ----------------------------------------------------------------------------


-- Files already applied or set aside, per project and events folder: each pass looked every one of thousands up in the project again
-- (review, 0.58.53). Only ever grows while the project is open: applied stays applied (sync.forget_trimmed drops only files that are gone).
-- (a song opened again in the same tab keeps the tab's address, and the cache then said the reopened song had everything: its master track
-- is a new one, so that's what is checked, as mirror.watch does with its first track. Linux stress test, 0.58.77)
-- (and the opening mirror.on_open tells: REAPER keeps the master track through File > Open in the same tab, so an older file opened there was
-- "settled" and the changes it lacked came back only with the next catch-up, up to 5 minutes later. rt-live bugs 2 and 3, rt-fixlive1)
-- (and the project's own marks: each cache keeps the last file it took as applied (sync.settle), and one whose mark is gone from the project
-- means a file was loaded into the tab (its marks are the file's) whatever else told it or didn't: File > Open of the song's own file runs
-- inside one REAPER call, so the load guard never saw REAPER loading and the name didn't change, and a reused track address hid it from
-- mirror.on_open. The changes the file lacks came back only with the heal, 64-292 s, or never (live sync2c c1.2, c2, c3). rt-fixlive2.
-- Counted per project in sync.marks_back, which mirror.on_open takes for an opening.)
sync.settled, sync.settled_master, sync.settled_retry, sync.settled_open = {}, {}, {}, {}
sync.settled_mark = setmetatable({}, { __mode = "k" }) -- settled table -> the file it last took as applied
sync.marks_back = {} -- tostring(proj) -> how many times its applied marks went back
function sync.settle(settled, f) settled[f] = true; sync.settled_mark[settled] = f end
local function marks_check(proj, key)
  local s = sync.settled[key]
  local f = s and sync.settled_mark[s]
  if f and ext(proj, sync.APPLIED, f:sub(1, -6)) == "" then
    sync.settled[key] = nil
    sync.marks_back[tostring(proj)] = (sync.marks_back[tostring(proj)] or 0) + 1
  end
end
-- -> how many times this project's applied marks went back (each events folder it has a cache for checked now). mirror.on_open
function sync.marks_moved(proj)
  local pk = tostring(proj) .. "\0"
  for key in pairs(sync.settled) do if key:sub(1, #pk) == pk then marks_check(proj, key) end end
  return sync.marks_back[tostring(proj)] or 0
end
local function marks_forget(proj) -- (marks cleared on purpose (trim, Try again): no load)
  local pk = tostring(proj) .. "\0"
  for key, s in pairs(sync.settled) do if key:sub(1, #pk) == pk then sync.settled_mark[s] = nil end end
end
function sync.settled_for(proj, dir)
  local key = tostring(proj) .. "\0" .. dir
  marks_check(proj, key)
  local had, master = sync.settled_master[key], reaper.GetMasterTrack(proj)
  if had and not (had == master and reaper.ValidatePtr2(proj, had, "MediaTrack*")) then sync.settled[key] = nil end
  sync.settled_master[key] = master
  local m = package.loaded.mirror
  local opening = m and m.opened and m.opened[tostring(proj)]
  if opening and sync.settled_open[key] and sync.settled_open[key] ~= opening then sync.settled[key] = nil end
  sync.settled_open[key] = opening or sync.settled_open[key]
  local retry = ext(proj, band.SECTION, "retry") -- (Try again, from another script: sync.retry_skipped)
  if sync.settled_retry[key] ~= retry then sync.settled[key], sync.settled_retry[key] = nil, retry end
  sync.settled[key] = sync.settled[key] or {}
  return sync.settled[key]
end

-- The project remembers every change it has applied, by id, and kept them all after history trim took the files away: the .rpp grew
-- for good (review, 0.58.53). Those whose file is in none of the song's rooms any more are dropped. -> how many (also sync.forgot).
sync.room_had_events = {}
function sync.forget_trimmed(proj, cfg, song)
  local here = {}
  for _, r in ipairs(require("rooms").list(cfg, song)) do
    local room = sync.room_dir(cfg, song, r.name)
    local dir = room .. "/events"
    local files = band.files(dir, ".json")
    -- (a room that reads empty just now (a drive hiccup, a folder being made again) would have its whole past taken for gone, and things like
    -- inserted time applied again: nothing is forgotten this time. Trim always leaves each thing's newest, so a room that had events is never
    -- empty. Review, 0.58.62. A room made and never used (its events folder there, and empty every time it's been looked at) has nothing to
    -- forget, and no longer stops forgetting for the whole song. Review, 0.58.69)
    if #files > 0 then sync.room_had_events[dir] = true
    else
      local there = false
      for _, d in ipairs(band.subdirs(room)) do if d == "events" then there = true end end
      if sync.room_had_events[dir] or not there then sync.forgot = 0; return 0 end
    end
    for _, f in ipairs(files) do here[f:sub(1, -6):upper()] = true end
    -- (and what's only in the direct link's inbox so far: a change applied from there lost its mark, and was applied again. James, 0.60.0-rt)
    for _, f in ipairs(require("direct").inbox_files(cfg, dir)) do here[f:sub(1, -6):upper()] = true end
  end
  if next(here) == nil then sync.forgot = 0; return 0 end -- (the folder not reachable just now: nothing is taken for gone)
  local gone, i = {}, 0
  while true do
    -- (upper-cased both sides: a reopened project hands its keys back upper-cased, so none matched a file's name, every mark was taken for
    -- gone, and each open took the song's changes in again: 534 on the Mac every time. Mac test, 0.58.70)
    local ok, key = reaper.EnumProjExtState(proj, sync.APPLIED, i)
    if not ok then break end
    if not here[key:upper()] then gone[#gone + 1] = key end
    i = i + 1
  end
  for _, key in ipairs(gone) do reaper.SetProjExtState(proj, sync.APPLIED, key, "") end
  if #gone > 0 then marks_forget(proj) end
  sync.forgot = #gone
  return #gone
end

-- How many of the room's events this project hasn't applied (or set aside) yet.
function sync.pending_events(proj, cfg, song, room)
  local n = 0
  local dir = sync.room_dir(cfg, song, room) .. "/events"
  local settled = sync.settled_for(proj, dir)
  for _, f in ipairs((require("direct").listing(cfg, dir))) do -- (a count: the shared listing, unsorted, and the direct link's inbox. 0.59.14, review; 0.60.0-rt)
    if not settled[f] then -- (looked at first: a name cut for every file of thousands, 2 to 3 times a poll. Round 1 review, 0.59.45)
      local id = f:sub(1, -6)
      if ext(proj, sync.APPLIED, id) ~= "" then sync.settle(settled, f)
      -- waiting on a claim isn't "behind", and neither is our own change on its way back (the pill read "Receiving 321"
      -- right after a restore we sent: laptop, 0.34.4)
      elseif not sync.deferred[id] and not sync.is_mine(id, cfg.user) then n = n + 1 end
    end
  end
  return n
end
sync.ev_cache = {} -- events dir -> { file -> decoded event }, for the files still waiting (sync.receive)
sync.contents_due = {} -- tostring(proj) -> { oid = true }: what a track that came back or went holds, not put in place yet (sync.receive)
sync.waited = {} -- event id -> true: its apply said "later" last pass (no undo block is opened for it again: sync.receive)

-- Events set aside: too new for this version, or made below the studio's floor (sync.too_new). And the room's driver
-- changes, read once and then kept up to date from incoming events: { [id] = { time, user } }.
sync.deferred = {}
sync.past_said = {} -- tostring(proj) \0 user \0 lower name -> when "which you've claimed ... didn't ask" was last said (sync.receive)
sync.unreadable = {} -- event file id -> when it was first found unreadable (sync.receive)
sync.UNREADABLE_SECS = 600 -- how long a file may stay unreadable before it's skipped for good
local driver_cache = {}
-- (the handovers are kept in the project as they're found, so an open reads them from there: reading every change of the room for them, once
-- each session, held REAPER up at every open of a long song. Review, 0.58.53. A project from before reads them all once, then keeps them)
sync.DRIVERS = "BandSync.drivers" -- "<room>/<event id>" -> "<time>|<driver>"; "<room>/" -> "1" once all were read
function sync.driver_history(proj, cfg, song, room)
  local key = tostring(cfg.root) .. "|" .. song .. "/" .. room -- (the studio too: two studios' songs of one name shared one history)
  if driver_cache[key] then return driver_cache[key] end
  local list, dir = {}, sync.room_dir(cfg, song, room) .. "/events"
  if proj and ext(proj, sync.DRIVERS, room .. "/") ~= "" then
    local i = 0
    while true do
      local ok, k, v = reaper.EnumProjExtState(proj, sync.DRIVERS, i)
      if not ok then break end
      i = i + 1
      -- (upper-cased: a reopened project hands its keys back upper-cased, "MAIN/...", and none matched: every handover was lost at each open,
      -- so whoever drove when a change was made read as the host. Ids are upper-cased everywhere here, for the same tie-break on every
      -- computer. Mac test, 0.58.70)
      local id = k:sub(1, #room + 1):upper() == (room .. "/"):upper() and k:sub(#room + 2):upper()
      local t, u = v:match("^([^|]*)|(.*)$")
      if id and id ~= "" and t then list[id] = { time = t, user = u } end
    end
    local s = band.read_json(band.session_path(cfg, song))
    if s and s.host then list["(host)"] = { time = "", user = s.host } end
    driver_cache[key] = list
    return list
  end
  for _, f in ipairs(band.files(dir, ".json")) do
    -- (only files that can be a handover are decoded: decoding every change of a long song's history, plug-in
    -- chains of a few MB among them, held REAPER up at every start: review, 2026-10-31)
    local text = band.read(dir .. "/" .. f)
    if text and text:find('"driver"', 1, true) then
      local ok, ev = pcall(band.json.decode, text)
      if ok and type(ev) == "table" and ev.type == "driver" and type(ev.time) == "string" then
        list[(ev.id or f):upper()] = { time = ev.time, user = ev.driver or ev.user }
        if proj then setext(proj, sync.DRIVERS, room .. "/" .. (ev.id or f:sub(1, -6)), ev.time .. "|" .. tostring(ev.driver or ev.user)) end
      end
    end
  end
  if proj then setext(proj, sync.DRIVERS, room .. "/", "1") end
  local s = band.read_json(band.session_path(cfg, song))
  if s and s.host then list["(host)"] = { time = "", user = s.host } end -- the host drives until the first handover
  driver_cache[key] = list
  return list
end

-- Who else is in the room now: everyone whose status receipt is under `within` s old (45: receipts are written every
-- 15 s and take a few seconds to sync). A machine whose Syncthing can't reach us counts as away.
function sync.present(cfg, song, room, within)
  -- (the files as presence.peers read them, within the second, with the same checks: 0.59.14, review. And its clock rule: 0.59.44)
  return require("presence").here(cfg, song, room, within or 45)
end

-- This computer's own id (made once, kept in REAPER's settings): two computers with the same name wrote one status
-- file between them, each thought it was alone, and each skipped some of the other's changes as its own (review,
-- 2026-10-31). Now the second one is told to pick another name.
function sync.machine()
  local id = reaper.GetExtState(band.SECTION, "machine id")
  if id == "" then
    math.randomseed(os.time() + math.floor(reaper.time_precise() * 1000))
    id = string.format("%08x", math.random(0, 0x7fffffff))
    reaper.SetExtState(band.SECTION, "machine id", id, true)
  end
  return id
end
-- (the file read back for the two-computers-one-name check at most every CLASH_EVERY s, and not once it's been said: it was read on every
-- write, each change and every 15 s. The other computer writes as often, so a clash still shows within a minute or two. James, rt)
sync.CLASH_EVERY = 45
local clash_at = {} -- status path -> when it was last read back
-- link_only: the presence message alone, no file (while the link reaches everyone here: lib/presence.lua put_status. James, rt)
function sync.write_status(proj, cfg, song, room, info, link_only)
  local sublap = band.sublap -- (Live sync's, only while perf stats is on: where a status write's 10-32 ms goes. rt-perfcut4)
  local dir = sync.room_dir(cfg, song, room) .. "/status"
  if not link_only then reaper.RecursiveCreateDirectory(dir, 0) end
  local path = dir .. "/" .. (cfg.user:gsub("[^%w%-_ ]", "")) .. ".json"
  local now = reaper.time_precise()
  if not link_only and not sync.name_clash_said and now - (clash_at[path] or -math.huge) >= sync.CLASH_EVERY then
    clash_at[path] = now
    local was = band.read_json(path)
    if type(was) == "table" and was.machine and was.machine ~= sync.machine() and type(was.time) == "string" and band.age(was.time) < 45 then
      sync.name_clash_said = true
      sync.put_back("another computer is also using the name " .. cfg.user .. ", so your changes and theirs get mixed up. " ..
        "Change the name on one of them: Settings > You")
    end
  end
  if sublap then sublap("status/folder, name clash") end
  info.machine = sync.machine()
  info.user, info.time, info.version, info.room = cfg.user, os.date("!%Y-%m-%dT%H:%M:%SZ"), band.VERSION, room
  -- (free MB where takes land, so the others can say "Mac is low on disk": lib/rthealth.lua. James, rt)
  info.free_mb = require("rthealth").free_mb(proj)
  info.reaper = (reaper.GetAppVersion():match("^[%d%.]+")) -- (Setup > Health compares the band's: "7.79/win64" -> "7.79")
  if sublap then sublap("status/info") end
  -- (what colours this computer shows, for Health's Colour parity row, which only exists with the studio's Colour parity on: with it off
  -- nobody reads `look`, and building it walks every item, 23-31 ms on a heavy song. James, rt; rt-perfcut4 cut 7)
  local okc, look = false, nil
  if require("colours").parity(cfg.root) then okc, look = pcall(require("colours").look, proj) end
  info.look = okc and look or nil
  if sublap then sublap("status/colour look") end
  if not link_only then band.write_json(path, info) end
  if sublap then sublap("status/file") end
  require("direct").send_live(cfg, "presence", info, song, room) -- (seen at once by those here: lib/presence.lua from_msg. James, 0.60.0-rt)
  if sublap then sublap("status/link send") end
end

-- Opening a project: what's new for it comes in before you get it, in one go. Left to Live sync, it comes a quarter of a second at a
-- time with REAPER redrawing between, and you work through the lag (James, 2026-11-02). What's here that hasn't gone out goes first,
-- as Live sync would have it. A tab you click on that's behind still catches up as it goes: it's already yours to use by then.
sync.PRELOAD_SECS = 20
function sync.preload(proj, cfg, song, room)
  -- (this person's own mix, if they keep one: preload runs in Autostart's or Open session's own Lua, where it was never set, and the
  -- studio's faders and pan landed over theirs as the project opened. Review, 0.58.87)
  sync.local_mix = select(2, reaper.GetProjExtState(proj, band.SECTION, "local_mix")) == "1"
  local s = band.read_json(band.session_path(cfg, song))
  if not (s and s.sync == "mirror") then return 0 end
  pcall(sync.floor, cfg) -- (the studio's version floor, in this script's Lua too: what's held, and whether anything may go out. docs/rt/rt-floor.md)
  local mirror = require("mirror")
  local can, who = sync.authority(cfg, song, room, s)
  sync.driver_name, sync.room_mode = who.driver, who.mode
  local t0, total, was_title = reaper.time_precise(), 0, nil
  reaper.PreventUIRefresh(1)
  local ok, err = pcall(function()
    if reaper.time_precise() - (sync.order_at or 0) > 3 then sync.order_at = reaper.time_precise(); mirror.keep_order(proj, cfg, song, room) end
    mirror.watch(proj, cfg, song, room, { can = can, mode = who.mode, local_mix = select(2, reaper.GetProjExtState(proj, band.SECTION, "local_mix")) == "1",
      is_claimed = who.is_claimed, owner_of = who.owner_of })
    -- (REAPER can't draw while this runs, and a plug-in's load can't be cut short: 206 changes took 54 s on the laptop. So its title
    -- bar says what's happening. Put back after: REAPER only redoes its own title when something changes, and it sat there saying this.)
    was_title = reaper.JS_Window_GetTitle and reaper.JS_Window_GetTitle(reaper.GetMainHwnd())
    local function say()
      if reaper.JS_Window_SetTitle then
        reaper.JS_Window_SetTitle(reaper.GetMainHwnd(), string.format("StudioSync: getting %s ready, %d change(s) to go...", song, sync.pending_events(proj, cfg, song, room)))
      end
    end
    while reaper.time_precise() - t0 < sync.PRELOAD_SECS do
      say()
      local n = sync.receive(proj, cfg, song, room, can)
      total = total + n
      if n == 0 and not sync.read_cut then break end -- (a big catch-up's first reads run past their budget: it gave up on exactly that)
    end
  end)
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  if was_title and reaper.JS_Window_SetTitle then reaper.JS_Window_SetTitle(reaper.GetMainHwnd(), was_title) end
  if not ok then band.log("getting '" .. song .. "' ready: " .. tostring(err)) end
  if total > 0 then band.log(string.format("'%s' is ready: %d change(s) from the others came in as it opened (%.1f s)", song, total, reaper.time_precise() - t0)) end
  -- (saved, so next time it opens from here. A file 27 hours old took 3034 changes in again on the Mac: 0.42.27)
  -- (after any catch-up, not only past 100: each open took the same changes in again until a big one came along. Review, 0.58.53)
  pcall(sync.forget_trimmed, proj, cfg, song)
  if (total > 0 or (sync.forgot or 0) > 0) and select(2, reaper.EnumProjects(-1)) ~= "" and reaper.EnumProjects(-1) == proj then reaper.Main_SaveProject(proj, false) end
  return total
end

return sync
