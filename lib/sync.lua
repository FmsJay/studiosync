-- StudioSync sync engine: event files in and out (mirror sync's object changes, lib/mirror.lua, plus the timeline,
-- handovers, play/stop cues, notes and likes), claims and who may change what, and rendering prints. Each person
-- writes only files named after themselves, so a sync client never sees two people writing the same file.
local band = require("band")
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
sync.TIMELINE_FORMAT = 4 -- (4: the recording-over-items choice joined the shared project settings: the first look after updating is not taken for an edit. James, rt)
local function timeline_sig(proj) return band.json_encode({ band.capture_tempo(proj), band.capture_markers(proj), band.capture_project(proj), sync.TIMELINE_FORMAT }) end
-- The tempo map alone, said one way (round-tripped through JSON), to tell a tempo change from a marker or notes one: only a tempo change
-- moves parts by itself (mirror.tempo_changed). A marker set the window going too, and for 15 s a nudge, a fade or automation drawn
-- went nowhere. Review, 0.58.87.
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


-- The driver's new timeline goes into session.json too: refreshing, or a bandmate joining later, gets it.
-- `stamp`: the timeline event's order (time..id), so a computer opening the song can tell whether it already holds a newer map. James, rt
function sync.session_timeline(cfg, song, tempo, markers, stamp_order)
  local sp = band.session_path(cfg, song)
  local s = band.read_json(sp)
  if s then
    s.first_timeline = s.first_timeline or { tempo = s.tempo, markers = s.markers } -- history restores before this need it
    s.tempo, s.markers, s.timeline_order = tempo, markers, stamp_order
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
      since[k .. ":" .. name:lower()] = (old.since or {})[k .. ":" .. name:lower()] or (old.since or {})[k .. ":" .. was:lower()] or now
    end
  end
  claims.since = since
  claims.user, claims.time = cfg.user, now
  reaper.RecursiveCreateDirectory(sync.room_dir(cfg, song, room) .. "/claims", 0)
  band.write_json(sync.claims_path(cfg, song, room, cfg.user), claims)
  require("direct").send_live(cfg, "claim", claims, song, room) -- (in the others' claims at once: sync.live_claim. James, 0.60.0-rt)
end
-- Claims that came over the direct link: song/room -> user -> their claims, used by sync.authority while newer than (or as new as) that person's
-- claims file, which is the record. The same bar as the file: a claims file speaks only for the person it's named for. (James, 0.60.0-rt)
sync.live_claims = {}
function sync.live_claim(song, room, c)
  if type(c) ~= "table" or type(c.user) ~= "string" or type(c.time) ~= "string" or (c.since ~= nil and type(c.since) ~= "table") or c.given then return false end
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
function sync.follow_claims(proj, cfg, song, room)
  do -- claims an admin gave me, into my own file
    local dir, prefix = sync.room_dir(cfg, song, room) .. "/claims", "given-" .. (cfg.user:gsub("[^%w%-_ ]", "")) .. "-"
    for _, f in ipairs(band.files(dir, ".json")) do
      if f:sub(1, #prefix) == prefix then
        local g, c = band.read_json(dir .. "/" .. f), sync.my_claims(cfg, song, room)
        if type(g) == "table" and c and given_ok(cfg, song, room, f, g) then
          for _, kind in ipairs({ "tracks", "regions" }) do
            c[kind] = c[kind] or {}
            for _, n in ipairs(g[kind] or {}) do
              local have = false
              for _, m in ipairs(c[kind]) do have = have or m:lower() == n:lower() end
              if not have then c[kind][#c[kind] + 1] = n end
            end
          end
          c.times = c.times or {}
          for _, t in ipairs(g.times or {}) do c.times[#c.times + 1] = t end
          -- (dated as given: folding it in must not make it newer than a claim someone made since)
          sync.set_claims(cfg, song, room, c)
          os.remove(dir .. "/" .. f)
          local words = {}
          for _, n in ipairs(g.tracks or {}) do words[#words + 1] = n end
          for _, n in ipairs(g.regions or {}) do words[#words + 1] = "region " .. n end
          if #(g.times or {}) > 0 then words[#words + 1] = "a stretch of time" end
          band.log(tostring(g.by) .. " gave you " .. table.concat(words, ", ") .. ": yours to change now")
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
  local mirror = require("mirror")
  c.oids, c.since = c.oids or {}, c.since or {}
  local changed = false
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
      changed = true
    end
  end
  if changed then band.write_json(sync.claims_path(cfg, song, room, cfg.user), c) end
end

-- Returns can(user, track, pos, take) -> bool, plus { driver, tracks, regions, times, owner(track, pos) } for display.
-- Who owns a take: its track's claimant, else the newest claim on a stretch of time it starts in (a time selection),
-- else the claimant of the named region it starts in, else the driver. A take's author may change it (move, trim,
-- mute) wherever nobody has claimed it that way.
-- How a room shares editing, set by the studio's owner or an admin (rooms/<room>/mode.json). The names on disk are older than the
-- panel's (James, 0.58.82: "Claims" for everyone-but-claims, the driver over claims in "Driver + claims", and "Everyone" with no claims):
--   "open"      Claims, the default: anyone changes anything nobody else has claimed (the newest change wins), the tempo map and markers too
--   "claims"    Driver + claims: the driver changes anything, claimed or not; everyone else what they've claimed
--   "driver"    Driver only: only the driver changes what the band has (claims are kept, but don't count while it's on)
--   "everyone"  Everyone: anyone changes anything; claims are kept but don't hold
--   "admins"    only the group's owner and admins, and everyone on what's been claimed for them (lib/groups.lua; an admin can give a claim)
-- Changes someone may not make are put back where the band has them, never kept on their machine only.
sync.MODES = { driver = true, claims = true, open = true, everyone = true, admins = true }
sync.DEFAULT_MODE = "open"
function sync.mode(cfg, song, room)
  local m = band.read_json(sync.room_dir(cfg, song, room) .. "/mode.json")
  return type(m) == "table" and sync.MODES[m.mode] and m.mode or sync.DEFAULT_MODE
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
      if key and e and e.key == key and e.settled then c = e.c
      else
        c = band.read_json(path)
        -- (a read that failed, the file busy mid-replace, isn't kept: it would hide that claim until the file changed again)
        e = key and c and { key = key, c = c, settled = (band.file_age(mt) or -1) >= sync.CLAIMS_SETTLE } or nil
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
  for _, c in ipairs(list) do
    if c and c.user and c.time then
      local gone = released[c.user]
      for _, t in ipairs(c.times or {}) do
        local at = t.at or c.time
        if tonumber(t.from) and tonumber(t.to) and t.to > t.from and not (gone and at <= gone) then
          times[#times + 1] = { user = c.user, time = at, from = t.from, to = t.to }
        end
      end
      for _, name in ipairs(c.prints or {}) do -- (newest wins, as for tracks)
        local k = name:lower()
        local t = (c.since or {})["prints:" .. k] or c.time
        local o = printers[k]
        if not (gone and t <= gone) and (not o or o.time < t or (o.time == t and o.user < c.user)) then printers[k] = { user = c.user, time = t, name = name } end
      end
      for _, list in ipairs({ { c.tracks, tracks }, { c.regions, regions } }) do
        for _, name in ipairs(list[1] or {}) do
          local k = name:lower()
          local t = (c.since or {})[(list[2] == tracks and "tracks:" or "regions:") .. k] or c.time
          local o = list[2][k] -- newest wins; the same second goes to the later name, so every machine agrees
          if not (gone and t <= gone) and (not o or o.time < t or (o.time == t and o.user < c.user)) then list[2][k] = { user = c.user, time = t, name = name } end
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
    return x.user > y.user
  end)
  local function in_time(pos)
    for _, t in ipairs(pos and times or {}) do if pos >= t.from and pos < t.to then return t end end
  end
  local function owner(track, pos, drv)
    local t = base_name(track)
    if t and tracks[t:lower()] then return tracks[t:lower()].user end
    local tc = in_time(pos)
    if tc then return tc.user end
    if pos then
      for _, sp in ipairs(spans) do
        if pos >= sp.from and pos < sp.to and regions[sp.name] then return regions[sp.name].user end
      end
    end
    return drv or driver
  end
  local function claimed(track, pos)
    local t = base_name(track)
    if t and tracks[t:lower()] then return true end
    if in_time(pos) then return true end
    for _, sp in ipairs(pos and spans or {}) do
      if pos >= sp.from and pos < sp.to and regions[sp.name] then return true end
    end
  end
  sync.owner_of = owner -- for messages ("... is James's to change")
  sync.is_claimed = claimed -- (sync.maker_may)
  return function(user, track, pos, take, drv) -- drv: the driver to judge by (an event's own time), else today's
      if mode == "driver" then return user == (drv or driver) end
      if mode == "everyone" then return true end
      if mode == "claims" and user == (drv or driver) then return true end -- (the driver over claims: James, 0.58.82)
      if mode == "admins" then
        if claimed(track, pos) then return owner(track, pos, drv) == user end
        return require("groups").may_manage(cfg.root, user)
      end
      if owner(track, pos, drv) == user then return true end
      -- open: anything nobody claimed, by anyone, the song's tempo map, markers and settings too (James, 2026-10-31:
      -- Open means open; before, those stayed the driver's)
      if mode == "open" and not claimed(track, pos) then return true end
      return take ~= nil and sync.author(take) == sync.author_of(user) and not claimed(track, pos)
    end,
    -- (is_claimed and owner_of: this room's, for callers to pass on. The module's sync.is_claimed / sync.owner_of are the last call's, and one
    -- for another room in between judged this one by that room's claims. They stay, for callers not passing these yet. Round 1 review, 0.59.45)
    { driver = driver, tracks = tracks, regions = regions, times = times, owner = owner, spans = spans, mode = mode, printers = printers,
      is_claimed = claimed, owner_of = owner }
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
function sync.restore_timeline(proj, cfg, song, room, entries, upto, session, from)
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
  band.apply_tempo(proj, t.tempo)
  band.apply_markers(proj, t.markers or {})
  sync.post(cfg, song, room, { type = "timeline", tempo = t.tempo, markers = t.markers or {} }, proj) -- (proj: ordered after the newest map seen here. Review, 0.58.95)
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
-- (`have`: time .. id). -> its id, or nil. Pure (review, 0.58.92).
function sync.newest_map(pending, have)
  local id, best = nil, have or ""
  for _, ev in ipairs(pending) do
    if ev.type == "timeline" then
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
  ev_seq = ev_seq + 1
  sync.posted = ev_seq -- (Live sync's cloud pass comes sooner after changes went out: James, rt)
  ev.format, ev.user, ev.time = band.FORMAT, cfg.user, os.date("!%Y-%m-%dT%H:%M:%SZ")
  if ev.type == "obj" and not ev.hlc then ev.hlc = require("mirror").hlc_next() end -- (what equal revisions are settled by: mirror.order_of)
  -- made with nobody else here (full control): everyone takes it when it reaches them, whoever drove then
  if sync.alone then ev.alone = true; if proj then setext(proj, band.SECTION, "alone_last", ev.time) end end
  ev.id = string.format("%s-%s-%05d-%04d", sync.id_user(cfg.user), os.date("!%Y%m%d-%H%M%SZ"), ev_seq, math.random(0, 9999))
  local k = proj and newest_key(ev)
  if k then
    local seen = ext(proj, sync.NEWEST, k)
    if seen >= ev.time .. ev.id then ev.order = seen .. "+" end
  end
  local dir = sync.room_dir(cfg, song, room) .. "/events"
  reaper.RecursiveCreateDirectory(dir, 0)
  band.write_json(dir .. "/" .. ev.id .. ".json", ev)
  -- (to whoever's here over the direct link too, a start or stop also as a message: lib/direct.lua. Syncthing's copy stays the record. James, 0.60.0-rt)
  local direct = require("direct")
  direct.offer(cfg, dir .. "/" .. ev.id .. ".json")
  if ev.type == "start" or ev.type == "stop" then direct.send_live(cfg, "cue", ev, song, room, ev.id) end
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
  if can(ev.user, ev.name or "", ev.pos, nil, driver) then return true end
  return sync.maker_may(ev.obj == "track" and ev.oid or ev.track, ev.user, ev.name or "", ev.pos, sync.room_mode, ev.obj == "item" and ev.oid or nil)
end

-- A track's maker may change it and what's on it while nobody has claimed it, unless the room is Driver only. Before
-- 0.40.3 the maker beat a bandmate's claim too, and nothing showed it (James, 2026-11-01: "it gets confusing"). Nothing is
-- claimed for anyone by itself since 0.58.82 (James: auto-claims "just make things more troublesome"): only Claim does.
-- `item`: an item's own oid. Your own recording on a track nobody claimed goes out too, as the take rule in sync.authority
-- says (it went to "(yours, not sent)" while the panel said "recording still goes out": UX review, 0.58.76).
-- `is_claimed` (optional): the room's (sync.authority's who.is_claimed), else the last authority call's. Round 1 review, 0.59.45
function sync.maker_may(oid, user, name, pos, mode, item, is_claimed)
  local mirror = require("mirror")
  is_claimed = is_claimed or sync.is_claimed
  return mode ~= "driver" and mode ~= "admins" and (mirror.is_creator(oid, user) or (item ~= nil and mirror.is_creator(item, user)))
    and not (is_claimed and is_claimed(name, pos))
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

-- Hold my changes on, and this project's tempo map or markers differ from the last ones seen: the band's timeline waits (sync.apply).
function sync.timeline_waits(proj)
  if ext(proj, band.SECTION, "hold") == "" then return false end
  local seen = ext(proj, band.SECTION, "timeline")
  return seen ~= "" and seen ~= timeline_sig(proj)
end
-- Apply one event from whoever may make it. False means retry later. `dir`: the room's folder.
-- The item a note or like is on, here (a part in mirror sync is found by its item id: it has no take id. 0.58.98), or nil.
function sync.note_item(proj, ev)
  return (ev.take and band.find_take(proj, ev.take)) or (type(ev.item) == "string" and require("mirror").find(proj, "item", ev.item)) or nil
end
-- Whether a change that isn't an object's changes this project: a play or stop together, a driver change and a note on nothing here don't.
-- (only then an arrival's undo block: opened for every bandmate's event, it closed empty on top of REAPER's list and sent Ctrl+Z StudioSync's
-- way. Cost: a lookup per note. Round 4 review, 0.59.49)
function sync.alters(proj, ev)
  if ev.type == "timeline" or ev.type == "shift" then return true end
  return (ev.type == "note" or ev.type == "like") and sync.note_item(proj, ev) ~= nil
end
function sync.apply(proj, ev, dir, can, me)
  if ev.type == "obj" then return require("mirror").receive(proj, ev, dir .. "/media", sync.local_mix, me) end -- mirror sync
  if ev.type == "timeline" then -- REAPER moves the items for the new map, as it would for a local change
    -- (Hold my changes on, and your tempo map or markers differ from the last ones seen here: theirs waits, not applied and not marked seen,
    -- as their change to an object you hold does. Applied, yours was replaced with no word and nothing was left to send on release. Live sync
    -- doesn't look at the timeline while holding, so "seen" is still the band's last. James: theirs waits. Cost: one signature per incoming
    -- timeline while on Hold. Round 1 review, 0.59.45)
    if sync.timeline_waits(proj) then return false end
    if tempo_sig(ev.tempo) ~= tempo_sig(band.capture_tempo(proj)) then require("mirror").tempo_changed(proj) end
    sync.audio_follow_tempo(proj)
    band.apply_tempo(proj, ev.tempo or {})
    band.apply_project(proj, ev.project) -- (title, notes, group names, timebase, ruler lanes: from 0.31.1; before the markers that sit in them)
    band.apply_markers(proj, ev.markers or {})
    setext(proj, band.SECTION, "timeline", timeline_sig(proj))
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
-- the first place, see apply_locks). Hold sync doesn't call this at all: the snapshots keep the last
-- synced state, so releasing the hold sends the net result once.
sync.timeline_looked = {}
sync.timeline_live = {} -- project -> a timeline was applied or made here since it was opened (watch_timeline's first look; W.order clears it)
-- The song's tempo map and markers: the driver's changes go out, anyone else's are put back (mirror sync carries
-- everything else; the timeline isn't a track or an item).
function sync.watch_timeline(proj, cfg, song, room, can)
  local me = cfg.user
  -- tempo map / markers first: if they changed, REAPER has just moved items for it, and those moves aren't edits
  local sig, seen = timeline_sig(proj), ext(proj, band.SECTION, "timeline")
  if seen ~= sig and seen ~= "" and (band.json_decode(seen) or {})[4] ~= sync.TIMELINE_FORMAT then seen = "" end -- (noted in an older format: a first look)
  -- opened behind the song (closed without its last save, say): nothing of ours waits, and your own marker has no event coming back to you (Mac, 0.57.6)
  if not sync.timeline_looked[proj] then
    sync.timeline_looked[proj] = true
    -- (tempo and markers only: a reopened file's project settings often differ (another REAPER's defaults), and that skipped this look and
    -- then posted the stale markers with them, wiping a region the others had. Laptop restart, James, rt)
    local function tm(x) local t = band.json_decode(x) or {}; return band.json_encode({ t[1] or {}, t[2] or {} }) end
    local s = room == "main" and seen ~= "" and tm(seen) == tm(sig) and band.read_json(band.session_path(cfg, song))
    -- (only a session.json map newer than the newest this project has applied or made (NEWEST), or, unstamped (written before rt), none
    -- applied or made in this session: it comes through Syncthing, seconds behind a map over the direct link, and the stale one was put
    -- back over the new. Cross test step 1, James, rt)
    local held = ext(proj, sync.NEWEST, "timeline")
    if s and not (s.timeline_order and tostring(s.timeline_order) > held or not s.timeline_order and not sync.timeline_live[proj]) then s = nil end
    if s and type(s.tempo) == "table" and type(s.markers) == "table" and #s.tempo > 0 then
      if s.timeline_order then setext(proj, sync.NEWEST, "timeline", tostring(s.timeline_order)) end -- (what it holds now: older maps stay superseded)
      local function plain(x) return band.json_encode(band.json_decode(band.json_encode(x))) end
      local tempo_off = plain(s.tempo) ~= plain(band.capture_tempo(proj))
      if tempo_off or plain(s.markers) ~= plain(band.capture_markers(proj)) then
        reaper.Undo_BeginBlock2(proj)
        local ok, e = pcall(function() -- (the undo point closed whatever happens: review, 0.58.92)
          if tempo_off then band.apply_tempo(proj, s.tempo); require("mirror").tempo_changed(proj) end
          band.apply_markers(proj, s.markers)
        end)
        reaper.Undo_EndBlock2(proj, "StudioSync: the song's tempo map and markers", -1)
        if not ok then error(e, 0) end
        sig = timeline_sig(proj)
        seen = sig
        setext(proj, band.SECTION, "timeline", sig)
        band.log("this project was behind the song: its tempo map and markers are back as the studio has them")
      end
    end
  end
  if seen ~= sig then
    local was = seen ~= "" and band.json_decode(seen)
    if not (type(was) == "table" and tempo_sig(was[1]) == tempo_sig(band.capture_tempo(proj))) then require("mirror").tempo_changed(proj) end
    if seen ~= "" then
      if can(me, nil, nil) then -- the song's timeline is the driver's
        local tempo, markers = band.capture_tempo(proj), band.capture_markers(proj)
        local tev = { type = "timeline", tempo = tempo, markers = markers, project = band.capture_project(proj) }
        sync.post(cfg, song, room, tev, proj) -- (proj: without it no order was set, 0.58.93's fix never applied. Review, 0.58.95)
        sync.timeline_live[proj] = true
        sync.session_timeline(cfg, song, tempo, markers, order(tev))
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
          sync.put_back("Not sent: only the driver changes the tempo, markers and project settings. Take control, or ask them to set Who controls to Anyone")
        else
          band.log("tempo or markers changed here, but only the driver's changes go to the others (Take control first)")
        end
      end
    end
    setext(proj, band.SECTION, "timeline", sig)
    sync.resnap(proj, true)
  end
end

-- May the band's changes come in now? Only once a look (mirror.watch) has seen this computer's last change: that look marks it as yours and
-- unsent, so theirs waits for it. Before it, a bandmate's change to the same item landed over yours with no trace (review, 0.58.47). 30 s at
-- most. cc: the project's change count now; looked_cc, looked_at: the count just after the last look, and when it ran.
function sync.seen_mine(cc, looked_cc, now, looked_at) return cc == looked_cc or now - looked_at > 30 end

-- Real-time cadence (pure; Live sync's tick). A look goes 0.1 s after your last edit settles, not at the next 2 s pass (desktop -> laptop
-- took 1.6-2.3 s with a 30 ms link. James, rt). SETTLE: a drag's drop or a burst of edits is one look. Never mid-drag, and the pass
-- gets at most a fifth of REAPER's time on a big song, as the look's own mirror_took guard.
-- changed_at: when your last edit was seen; polled_at, pass_took: when the last pass started and how long it took.
sync.SETTLE, sync.QUIET, sync.QUIET_DIRECT, sync.DIRECT_FRESH = 0.1, 2, 0.4, 10
function sync.look_now(changed_at, polled_at, pass_took, now, mouse)
  return not mouse and changed_at > polled_at and now - changed_at >= sync.SETTLE and now - polled_at > pass_took * 5
end
-- How long after your last edit the band's changes wait: 0.4 s while they come over the direct link (arrived in the last 10 s), 2 s on
-- Syncthing alone as before. (Unsent edits stay protected per object in mirror.receive, a drag by the mouse gate. James, rt)
function sync.quiet_for(now, direct_at) return now - (direct_at or -math.huge) < sync.DIRECT_FRESH and sync.QUIET_DIRECT or sync.QUIET end
-- A pass the moment the quiet window ends, for what came over the link and waited for your edit: else it waited for the next 2 s pass.
-- Once: the last pass ran inside the window (that's why it waited), and the window is over now. held: something arrived and isn't in yet.
function sync.receive_now(held, changed_at, quiet, polled_at, pass_took, now, mouse)
  return held and not mouse and polled_at < changed_at + quiet and now >= changed_at + quiet and now - polled_at > pass_took * 5
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
function sync.too_new(ev)
  return not sync.KNOWN[ev.type] or (tonumber(ev.format) or 0) > band.FORMAT
end
sync.version_looked = {} -- proj -> true: its skipped changes were looked at for this version
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
  if peaks_due[pk] and reaper.EnumProjects(-1) == proj and reaper.GetPlayStateEx(proj) == 0 then -- (an action works on the tab in front)
    peaks_due[pk] = nil
    reaper.Main_OnCommand(40047, 0) -- Peaks: Build any missing peaks
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
    if not settled[f] and ext(proj, sync.APPLIED, f:sub(1, -6)) ~= "" then settled[f] = true end
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
        if reaper.time_precise() - sync.unreadable[id] > sync.UNREADABLE_SECS then
          -- (on Health's skipped list, so Try again can have it once it's whole: marked done, it was never looked at again. Review, 0.58.92)
          sync.skip(proj, { id = id, user = type(ev) == "table" and type(ev.user) == "string" and ev.user or "?" }, "its file couldn't be read (half-synced or damaged)")
          band.log("skipped a file in the studio's folder that StudioSync can't read (" .. f .. ")")
        end
      end
      if good then
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
  table.sort(pending, function(a, x) return (a.time .. a.id) < (x.time .. x.id) end)
  local function driver_at(t) -- who drove when this happened
    local best
    for id, d in pairs(drivers) do -- two handovers in the same second: the later id, so every machine agrees
      if d.time <= t and (not best or d.time > best.time or (d.time == best.time and id > best.id)) then best = d; best.id = id end
    end
    return best and best.user
  end
  -- A timeline event is the whole map: only the newest is applied. (Every older map landing in turn, between looks, re-timed
  -- beat-timebase items, and those went out as edits: 158 from the laptop in one catch-up. Sync engine review, 0.58.76)
  local newest_map
  -- (ours count too, and the newest this project already has: an older map of theirs landed over our newer one, theirs took ours, and the two
  -- projects kept different tempo maps. Review, 0.58.92)
  newest_map = sync.newest_map(pending, ext(proj, sync.NEWEST, "timeline"))
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
  local function refused(ev)
    return not (sync.ANYONE[ev.type] or ev.alone or (ev.type == "obj" and sync.obj_allowed(ev, can, driver_at(ev.time)))
      or (ev.type ~= "obj" and can(ev.user, ev.was or ev.track, ev.pos, ev.take, driver_at(ev.time))))
  end
  -- Catching up (joining late, back from a week away): only the newest revision of each object is applied; the
  -- older ones are counted as done (they stay in the folder for Restore). Replaying every revision of every object
  -- rewrote a plug-in chain changed 50 times 50 times (review, 2026-10-31).
  local function mirror_newer(a, x)
    local mirror = require("mirror")
    return mirror.newer({ rev = a.rev, time = mirror.order_of(a) }, { rev = x.rev, time = mirror.order_of(x) })
  end
  -- (but a change to an item made apart from the newest one isn't older news: the two are merged, mirror.receive, as every computer does)
  local function apart(x, w) -- (true, false, or nil while a change between hasn't arrived: then it isn't counted as done either)
    -- (an item's deletion that beats the newer edit made without seeing it isn't older news: it lands, mirror.gone_race. Counted done, a
    -- delete-all raced by tempo re-times never landed where all of them came in one pass. Cross test, James, rt)
    local race = w and require("mirror").gone_race(sync.room_dir(cfg, song, room), x, w)
    if race == true then return true elseif race == "wait" then return nil end
    if not (x.obj == "item" and w and not x.gone and not w.gone and x.base_ev and w.base_ev) then return false end
    return require("mirror").apart(sync.room_dir(cfg, song, room), x, w)
  end
  -- An object change StudioSync can read. (Checked before the newest of each object is picked: a malformed or newer-format one, picked as the
  -- newest, marked the readable ones before it superseded, and was then skipped itself. 0.59.14, review)
  local function readable(ev)
    return type(ev.oid) == "string" and (ev.obj == "item" or ev.obj == "track" or require("mirror").PART[ev.obj]) and type(ev.rev) == "number"
      and (ev.gone or type(ev.state) == (ev.obj == "track" and "table" or "string")) and ev.state ~= require("json").null and (ev.name == nil or type(ev.name) == "string") and (ev.pos == nil or type(ev.pos) == "number")
  end
  local latest = {}
  for _, ev in ipairs(pending) do
    -- (not one too new for this version: it waits, sync.too_new, and picked as the newest it marked the older ones done, so this computer stayed
    -- on an even older state until it updated. Round 3 review, 0.59.48)
    if ev.type == "obj" and readable(ev) and not sync.too_new(ev) then
      local cur = latest[ev.oid]
      if not cur or mirror_newer(ev, cur) then latest[ev.oid] = ev end
    end
  end
  sync.ev_cache[dir] = kept
  local t0, budget_out = reaper.time_precise(), false -- (and a quarter second of applying per pass, a second while loading: the rest next pass)
  require("mirror").index_for(proj)
  local applied, done, undo_open, late_point = 0, {}, false, false
  sync.backlog = false
  local rdir = sync.room_dir(cfg, song, room)
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
      if not sync.too_new_said then sync.too_new_said = true; band.log(tostring(ev.user) .. " sent a change this StudioSync doesn't know yet: update StudioSync and it lands") end
    elseif obj and not readable(ev) then
      sync.skip(proj, ev, "StudioSync can't read it") -- malformed (a newer or damaged file): skipped, once, without stopping the rest
      band.log("skipped a change from " .. tostring(ev.user) .. " that StudioSync can't read (" .. tostring(ev.id) .. ")")
    elseif (ev.type == "timeline" and ev.user ~= cfg.user and newest_map ~= ev.id) or superseded(proj, ev) or (obj and latest[ev.oid] ~= ev and apart(ev, latest[ev.oid]) == false) then
      setext(proj, sync.APPLIED, ev.id, "1") -- superseded
    elseif ev.user == cfg.user and not obj then
      setext(proj, sync.APPLIED, ev.id, "1") -- our own: already true here
      stamp(proj, ev) -- and what we change next comes after it, even one stamped while our clock ran ahead
    elseif not obj and refused(ev) and reaper.time_precise() - sync.refused_since(ev.id) <= 60 then
      -- (the older kinds of change) not theirs to change, as far as this machine knows: their claim or the handover may simply not have
      -- synced here yet, so it waits a minute from when it arrived, then lands like any other, as an object change does. Dropped once
      -- 10 minutes old, one that came in before the handover it rested on was lost for good. Review, 0.58.91
      sync.deferred[ev.id] = true
    elseif obj and refused(ev) and reaper.time_precise() - sync.refused_since(ev.id) <= 60 then
      -- (the minute is from when it arrived here, not the sender's own clock: one running a minute or more behind had a refused change land at
      -- once. Review, 0.58.92)
      -- An object change: the sender checked it against the claims as they had them when they made it. What looks
      -- refused here is most likely a claim or handover still on its way, either way: it waits a minute, then lands
      -- like any other. Judging it by today's claims and dropping it after 10 minutes left a machine that was away
      -- (or a claim released since) with a different project for good, and nothing said so (review, 2026-10-31).
      sync.deferred[ev.id] = true
    else
      -- one undo point per pass, only when something lands: reading our own change back opened one too, which sat on
      -- top of the edit and held its print, so Ctrl+Z took two presses and the first left the note moved (PC, 0.40.3)
      local m = require("mirror")
      -- one bad event must never block everything behind it (2026-10-28: a take-less "driver" event threw on every
      -- pass, so the handover's edits and tempo change never applied): log it and move on
      -- (whether it lands, inside the same pcall: wins and merge_for read the event too, and an error there stopped the pass with an undo
      -- block open. 0.59.14, review)
      -- (no undo block for a change that waited last pass, or a timeline that waits now: the block opened before apply said it waits, and closed
      -- named whatever happened, an empty undo point every pass while a recording arrived, a part was open in the MIDI editor or Hold kept a
      -- change. Each changed the project's count (a full look and a 2 s pause followed), and on top of REAPER's list sent Ctrl+Z StudioSync's
      -- way. One that waited and lands now gets its point after: below. Cost: one table entry per waiting change. Round 2 review, 0.59.46)
      local waited = sync.waited[ev.id]
      local ok, res = pcall(function()
        local lands
        if obj then lands = m.wins(proj, ev.oid, ev.rev or 0, m.order_of(ev)) or m.merge_for(proj, ev, sync.room_dir(cfg, song, room)) ~= nil -- (or it's merged in)
        else lands = sync.alters(proj, ev) end
        if ev.type == "timeline" and sync.timeline_waits(proj) then lands = false end
        -- (nor on its first wait, where that's cheap to know: mirror.will_wait. Round 3 review, 0.59.48)
        if lands and not waited and obj and m.will_wait(proj, ev) then waited = true end
        if lands and not waited and not undo_open then reaper.Undo_BeginBlock2(proj); undo_open = true end
        return sync.apply(proj, ev, sync.room_dir(cfg, song, room), can, cfg.user)
      end)
      if ok and res == false then sync.waited[ev.id] = true
      elseif ok and res and waited then sync.waited[ev.id], late_point = nil, true end
      if not ok then
        sync.failed[ev.id] = (sync.failed[ev.id] or 0) + 1
        if not obj or sync.failed[ev.id] >= 5 then
          band.log("skipped a change from " .. tostring(ev.user) .. " that StudioSync couldn't apply (" .. tostring(ev.type) .. "): " .. tostring(res))
          sync.skip(proj, ev, res)
        end
      elseif res then
        setext(proj, sync.APPLIED, ev.id, "1")
        stamp(proj, ev)
        if type(ev.note) == "string" and ev.user ~= cfg.user and band.age(ev.time) < 3600 then band.log(ev.note) end -- (a copy's credit, a bus: mirror.watch)
        if reaper.time_precise() - t0 > budget then budget_out, sync.backlog = true, true end
        -- (nor one mirror.receive dropped (on a deleted track, beaten by a deletion, older than what's here): "James-Laptop: changed an item on
        -- XT Drums A" was logged for an edit that never landed. Cross test, James, rt)
        local theirs = ev.user ~= cfg.user and not (obj and require("mirror").dropped) -- (your own changes come back too: they aren't "from the band")
        if theirs then applied = applied + 1 end
        local what = ({ timeline = "changed the tempo map / markers",
          start = (ev.rec and "record" or "play") .. " together at " .. tostring(ev.pos), stop = "stop together",
          note = "note: " .. tostring(ev.text), like = "liked " .. tostring(ev.take or (ev.track and ("a part on " .. ev.track)) or "a part"),
          obj = (ev.gone and "deleted " or "changed ") .. (require("mirror").PART[ev.obj] or (ev.obj == "item" and "an item" or "a track")) ..
            " on " .. ((ev.name or "") ~= "" and ev.name or "an unnamed track"),
          shift = ((ev.len or 0) > 0 and "inserted " or "removed ") .. string.format("%.2f s at %.2f s", math.abs(ev.len or 0), ev.at or 0) })[ev.type]
        if theirs and what then done[#done + 1] = ev.user .. ": " .. what end
      end
    end
  end
  require("mirror").index_for(nil)
  -- a change skipped because its track was gone, and the track may have come back since (a download arrives in
  -- batches, out of history order): once this pass has drained the queue, everything's newest change that hasn't
  -- landed is put in place (mirror.heal: only what differs)
  local mirror = require("mirror")
  local orph = mirror.orphaned[tostring(proj)]
  if orph and not budget_out then
    local back = false
    for toid in pairs(orph) do if mirror.find(proj, "track", toid) then orph[toid] = nil; back = true end end
    if back then -- (only when such a track exists again: a track that stays deleted costs one lookup a pass)
      local hok, n = pcall(mirror.heal, proj, rdir, sync.local_mix)
      if hok and n > 0 then sync.redraw = true; band.log(string.format("%d change(s) landed once their track was back", n)) end -- (no undo point, not in `applied`: Live sync's redraw. James, rt)
    end
    if next(orph) == nil then mirror.orphaned[tostring(proj)] = nil end
  end
  -- (an edit landed over a deletion held here: mirror.receive. Round 2 review, 0.59.46. Held until the tab is in front and stopped, as Live sync's
  -- own heal is: the session's first heal reads the room's whole history, up to a second or more, and it landed mid-playback in any tab.
  -- Round 3 review, 0.59.48)
  if mirror.heal_due[pk] and not budget_out and reaper.EnumProjects(-1) == proj and reaper.GetPlayStateEx(proj) == 0 then
    mirror.heal_due[pk] = nil
    local hok, n = pcall(mirror.heal, proj, rdir, sync.local_mix)
    if hok and n > 0 then late_point = true end -- (on a later pass than the edit's, perhaps: an undo point of its own)
  end
  if undo_open then reaper.Undo_EndBlock2(proj, "StudioSync: changes from the others", -1)
  -- (a change that waited, landed: its point now. Every kind of state, not items only (Undo_OnStateChange2): a plug-in chain, automation or
  -- track change landing under an items-only point was taken back by your next native Ctrl+Z and sent as your change. Round 3 review, 0.59.48)
  elseif late_point then reaper.Undo_OnStateChangeEx2(proj, "StudioSync: changes from the others", -1, -1) end
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
sync.settled, sync.settled_master, sync.settled_retry = {}, {}, {}
function sync.settled_for(proj, dir)
  local key = tostring(proj) .. "\0" .. dir
  local had, master = sync.settled_master[key], reaper.GetMasterTrack(proj)
  if had and not (had == master and reaper.ValidatePtr2(proj, had, "MediaTrack*")) then sync.settled[key] = nil end
  sync.settled_master[key] = master
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
      if ext(proj, sync.APPLIED, id) ~= "" then settled[f] = true
      -- waiting on a claim isn't "behind", and neither is our own change on its way back (the pill read "Receiving 321"
      -- right after a restore we sent: laptop, 0.34.4)
      elseif not sync.deferred[id] and not sync.is_mine(id, cfg.user) then n = n + 1 end
    end
  end
  return n
end
sync.ev_cache = {} -- events dir -> { file -> decoded event }, for the files still waiting (sync.receive)
sync.waited = {} -- event id -> true: its apply said "later" last pass (no undo block is opened for it again: sync.receive)

-- Events refused for now (authority not synced here yet): retried until 10 minutes old. And the room's driver
-- changes, read once and then kept up to date from incoming events: { [id] = { time, user } }.
sync.deferred = {}
local refused_at, refused_pruned = {}, -math.huge -- event id -> when it was first found refused here
-- (a refused change lands after a minute anyway, so an entry an hour old is spent: they're dropped every 10 minutes, as the table grew all
-- session. One still waiting then would wait one more minute. James, rt)
function sync.refused_since(id)
  local now = reaper.time_precise()
  if now - refused_pruned > 600 then
    refused_pruned = now
    for k, at in pairs(refused_at) do if now - at > 3600 then refused_at[k] = nil end end
  end
  refused_at[id] = refused_at[id] or now
  return refused_at[id]
end
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
      local ok, ev = pcall(require("json").decode, text)
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
function sync.write_status(proj, cfg, song, room, info)
  local dir = sync.room_dir(cfg, song, room) .. "/status"
  reaper.RecursiveCreateDirectory(dir, 0)
  local path = dir .. "/" .. (cfg.user:gsub("[^%w%-_ ]", "")) .. ".json"
  local now = reaper.time_precise()
  if not sync.name_clash_said and now - (clash_at[path] or -math.huge) >= sync.CLASH_EVERY then
    clash_at[path] = now
    local was = band.read_json(path)
    if type(was) == "table" and was.machine and was.machine ~= sync.machine() and type(was.time) == "string" and band.age(was.time) < 45 then
      sync.name_clash_said = true
      sync.put_back("another computer is also using the name " .. cfg.user .. ", so your changes and theirs get mixed up. " ..
        "Change the name on one of them: Settings > You")
    end
  end
  info.machine = sync.machine()
  info.user, info.time, info.version, info.room = cfg.user, os.date("!%Y-%m-%dT%H:%M:%SZ"), band.VERSION, room
  -- (free MB where takes land, so the others can say "Mac is low on disk": lib/rthealth.lua. James, rt)
  info.free_mb = require("rthealth").free_mb(proj)
  info.reaper = (reaper.GetAppVersion():match("^[%d%.]+")) -- (Setup > Health compares the band's: "7.79/win64" -> "7.79")
  local okc, look = pcall(require("colours").look, proj) -- (what colours this computer shows, for Health's Colour parity row. James, rt)
  info.look = okc and look or nil
  band.write_json(dir .. "/" .. (cfg.user:gsub("[^%w%-_ ]", "")) .. ".json", info)
  require("direct").send_live(cfg, "presence", info, song, room) -- (seen at once by those here: lib/presence.lua from_msg. James, 0.60.0-rt)
end

-- Opening a project: what's new for it comes in before you get it, in one go. Left to Live sync, it comes a quarter of a second at a
-- time with REAPER redrawing between, and you work through the lag (James, 2026-11-02). What's here that hasn't gone out goes first,
-- as Live sync would have it. A tab you click on that's behind still catches up as it goes: it's already yours to use by then.
sync.PRELOAD_SECS = 20
function sync.preload(proj, cfg, song, room)
  if select(2, reaper.GetProjExtState(proj, band.SECTION, "hold")) ~= "" then return 0 end
  -- (this person's own mix, if they keep one: preload runs in Autostart's or Open session's own Lua, where it was never set, and the
  -- studio's faders and pan landed over theirs as the project opened. Review, 0.58.87)
  sync.local_mix = select(2, reaper.GetProjExtState(proj, band.SECTION, "local_mix")) == "1"
  local s = band.read_json(band.session_path(cfg, song))
  if not (s and s.sync == "mirror") then return 0 end
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
