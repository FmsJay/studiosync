-- The studio's hub and each song's (docs/realtime-roadmap.md "More big ideas" 1; James, rt). One online computer is the studio's hub and each
-- song has one too; every computer works out the same ones from what they all see (the status files: who's online, since when, in which song,
-- who holds a role now; band.json's preferred hub; the song's own hub.json), so nobody is told and nothing is negotiated.
--   Studio hub: the owner's preferred computer when it's online (handed back to it once it's been on HANDBACK s), else whoever holds it now
--     (so it doesn't flap), else the ranking: the direct link listening there first, then online longest, then its machine id.
--   A song's hub: its home (whoever shared the song, or whoever it was handed to since: hub.json), else whoever holds it now, else the studio
--     hub if it has the song open, else the ranking among those in the song; nobody there: the cloud copy stands in (it already carries every
--     restore point both ways: lib/drive.lua).
--   Nothing depends on it: peer to peer and Syncthing stay the baseline, and what the hub keeps is never the only copy.
-- The hub is someone's working REAPER: its one job here (a song's restore points, "hub snapshot") runs only while that REAPER is stopped and
-- untouched for IDLE s, never while anything records or plays, at most every SNAP_EVERY s and within a CPU budget; the person can hand the role
-- on (Health), and the next computer takes it.
local band = require("band")
local hub = { SCAN_EVERY = 10, FRESH = 45, HANDBACK = 30, SNAP_EVERY = 1800, IDLE = 60, BUDGET = 0.002, SCAN_MS = 4, TICK_EVERY = 2, LABEL = "hub snapshot",
  TRANSFERS_KEPT = 50 }

-- ---- pure ----------------------------------------------------------------------------------------------------------------------------
-- Candidates: { user, machine, since (os.time it came online), link (its direct link listens), off (handed the role on), studio (holds the
-- studio hub now), songs = { [song] = { holds = true when it holds that song's hub now } } }.
-- The ranking, the same on every computer: the link listening first, then online longest, then machine id, then name.
function hub.better(a, b)
  if (a.link == true) ~= (b.link == true) then return a.link == true end
  local sa, sb = tonumber(a.since) or math.huge, tonumber(b.since) or math.huge
  if sa ~= sb then return sa < sb end
  local ma, mb = tostring(a.machine or ""), tostring(b.machine or "")
  if ma ~= mb then return ma < mb end
  return tostring(a.user) < tostring(b.user)
end
local function best(list, keep)
  local out
  for _, c in ipairs(list) do if (not keep or keep(c)) and (not out or hub.better(c, out)) then out = c end end
  return out
end
local function find(list, user) for _, c in ipairs(list) do if c.user == user then return c end end end
-- A computer that comes back takes its role back once it's been on HANDBACK s, or at once when nobody else holds it (no flapping on a computer
-- that drops in and out).
local function settled(c, now, others_hold) return not others_hold or (now - (tonumber(c.since) or now)) >= hub.HANDBACK end

-- -> the studio hub's user (nil: nobody online who'll take it) and why: "preferred", "kept", "ranked", or "nobody".
function hub.elect_studio(cands, preferred, now)
  local ok = {}
  for _, c in ipairs(cands or {}) do if not c.off then ok[#ok + 1] = c end end
  local holder = best(ok, function(c) return c.studio == true end)
  local p = preferred and find(ok, preferred)
  if p and settled(p, now, holder and holder ~= p) then return p.user, "preferred" end
  if holder then return holder.user, "kept" end
  local r = best(ok)
  if r then return r.user, "ranked" end
  return nil, "nobody"
end

-- -> a song's hub (nil: nobody in it who'll take it: the cloud copy stands in) and why: "home", "kept", "studio", "ranked", or "nobody".
-- home: hub.home_of's; studio: the studio hub's user.
function hub.elect_song(cands, song, home, studio, now)
  local here = {}
  for _, c in ipairs(cands or {}) do if not c.off and type(c.songs) == "table" and c.songs[song] then here[#here + 1] = c end end
  local holder = best(here, function(c) return c.songs[song].holds == true end)
  local h = home and find(here, home)
  if h and settled(h, now, holder and holder ~= h) then return h.user, "home" end
  if holder then return holder.user, "kept" end
  if studio and find(here, studio) then return studio, "studio" end
  local r = best(here)
  if r then return r.user, "ranked" end
  return nil, "nobody"
end

-- A song's home: whoever shared it, then each handover in order that its sharer, the home at the time, or the owner or an admin (may(by))
-- made. Others are passed over, so a member can't take a song's hub for themselves. -> the user, and whether it was handed on.
function hub.home_of(sharer, transfers, may)
  local list = {}
  for _, t in ipairs(type(transfers) == "table" and transfers or {}) do
    if type(t) == "table" and type(t.to) == "string" and t.to ~= "" and type(t.by) == "string" then list[#list + 1] = t end
  end
  table.sort(list, function(a, b)
    if (tonumber(a.at) or 0) ~= (tonumber(b.at) or 0) then return (tonumber(a.at) or 0) < (tonumber(b.at) or 0) end
    return a.by .. "\0" .. a.to < b.by .. "\0" .. b.to
  end)
  local cur, moved = sharer, false
  for _, t in ipairs(list) do
    if t.by == sharer or t.by == cur or (may and may(t.by)) then cur, moved = t.to, t.to ~= sharer end
  end
  return cur, moved
end

-- Statuses -> candidates. sts: { { song, st (a status file's table), seen (os.time it last changed here) } }; me: this computer's user; fresh:
-- seen or written within FRESH s (a bandmate's clock that's off still reads as here while its file keeps changing, as lib/presence.lua).
-- Each person's newest status gives their since/link/off/studio; every song they're fresh in goes in songs.
function hub.candidates(sts, now, age_of)
  local by, out = {}, {}
  for _, s in ipairs(sts or {}) do
    local st = s.st
    if type(st) == "table" and type(st.user) == "string" and type(st.time) == "string" and type(s.song) == "string"
      and (age_of(st.time) < hub.FRESH or now - (tonumber(s.seen) or -math.huge) < hub.FRESH) then
      local h = type(st.hub) == "table" and st.hub or {}
      local c = by[st.user]
      if not c then c = { user = st.user, songs = {} }; by[st.user] = c; out[#out + 1] = c end
      if not c.time or st.time > c.time then
        c.time, c.machine, c.since, c.link, c.off, c.studio = st.time, st.machine, tonumber(h.since), h.link == true, h.off == true, h.studio == true
      end
      c.songs[s.song] = c.songs[s.song] or {}
      if h.song == true then c.songs[s.song].holds = true end
    end
  end
  table.sort(out, function(a, b) return a.user < b.user end)
  return out
end

-- Is a hub snapshot due? last: os.time of the room's newest one (nil: none); changed: anything new since this computer's last look (nil: not
-- known here, as after a handover: due by time alone); dur: the last one's seconds. -> true, or false and why ("recent", "budget", "unchanged").
function hub.snap_due(now, last, changed, last_end, dur)
  if last and now - last < hub.SNAP_EVERY then return false, "recent" end
  if last_end and dur and now - last_end < dur / hub.BUDGET then return false, "budget" end
  if changed == false then return false, "unchanged" end
  return true
end
-- A hub snapshot's file name (recall.save: "<YYYYMMDD-HHMMSSZ>-<user>-hub_snapshot.json") -> its os.time, or nil if it isn't one.
function hub.snap_time(name)
  local y, mo, d, h, mi, s = tostring(name):match("^(%d%d%d%d)(%d%d)(%d%d)%-(%d%d)(%d%d)(%d%d)Z%-.*%-hub_snapshot%.json$")
  -- (as an os.time: now less its age. band.iso_time reads a UTC time as local, which put the last snapshot hours ahead here ("last -358 min
  -- ago") and every next one "recent" for as long. Desktop, rt)
  return y and os.time() - band.age(string.format("%s-%s-%sT%s:%s:%sZ", y, mo, d, h, mi, s)) or nil
end

-- Health's words. v: { studio, studio_why, song, hub, why, home }; me: this computer's user. Pure.
local WHY_STUDIO = { preferred = "the owner's pick", kept = "holding it", ranked = "online longest" }
local function who(u, me) return u == me and "you" or u end
function hub.line(v, me)
  local s = v.studio and (who(v.studio, me) .. " (" .. (WHY_STUDIO[v.studio_why] or "?") .. ")") or "nobody online"
  local why = v.why == "home" and (v.moved and "it was handed to them" or "shared it")
    or v.why == "kept" and ("holding it" .. (v.home and v.home ~= v.hub and (" until " .. v.home .. " is back") or ""))
    or v.why == "studio" and ("the studio hub" .. (v.home and (", " .. v.home .. " is away") or ""))
    or v.why == "ranked" and ("online longest" .. (v.home and (", " .. v.home .. " is away") or "")) or ""
  local song = v.hub and (who(v.hub, me) .. " (" .. why .. ")") or "nobody here, so the cloud copy stands in"
  return "Hub: " .. s .. "; this song: " .. song .. "."
end

-- ---- this computer ---------------------------------------------------------------------------------------------------------------------
local function id_of(root) return band.info(root).id end
-- When this REAPER came online (os.time), kept for the session so every Live sync tab says the same.
function hub.since()
  local v = tonumber(reaper.GetExtState(band.SECTION, "hub since"))
  if not v then v = os.time(); reaper.SetExtState(band.SECTION, "hub since", tostring(v), false) end
  return v
end
-- Handed on: this computer takes no hub role in the studio until its person says so again (kept between sessions).
function hub.off(root) return reaper.GetExtState(band.SECTION, "hub off " .. id_of(root)) == "1" end
function hub.set_off(root, on)
  if on then reaper.SetExtState(band.SECTION, "hub off " .. id_of(root), "1", true) else reaper.DeleteExtState(band.SECTION, "hub off " .. id_of(root), true) end
  band.log(on and "you handed the hub role on: the next computer takes it within a few seconds (Health: Be a hub again)" or "this computer can be a hub again")
end

-- The song's hub.json: { transfers = { { to, by, at } } }, read with session.json's host (who shared it).
local function song_file(cfg, song) return band.song_dir(cfg, song) .. "/hub.json" end
local function may_fn(root)
  local groups = require("groups")
  return function(u) local r = groups.role(root, u); return r == "owner" or r == "admin" or r == "open" end
end
function hub.home(cfg, song)
  local s = band.read_json(band.session_path(cfg, song)) or {}
  local j = band.read_json(song_file(cfg, song)) or {}
  -- shortcut: `by` is what the file says, checked against the roles, not Syncthing's modifiedBy (trust.claim_ok's way); it only moves where a
  -- song's restore points are kept, never data. Check modifiedBy once a hub job carries more than that.
  return hub.home_of(type(s.host) == "string" and s.host or nil, j.transfers, may_fn(cfg.root))
end
-- May `by` hand `song`'s hub on? Its sharer, its home now, or the owner or an admin.
function hub.may_hand(cfg, song, by)
  local s = band.read_json(band.session_path(cfg, song)) or {}
  return by == s.host or by == hub.home(cfg, song) or may_fn(cfg.root)(by)
end
-- Hands `song`'s hub to `to` for good (every computer reads the same hub.json). -> true, or nil and why.
function hub.hand_song(cfg, song, to)
  if not hub.may_hand(cfg, song, cfg.user) then return nil, "only whoever shared the song, its hub, the owner or an admin can hand it on" end
  local path = song_file(cfg, song)
  local j = band.read_json(path) or {}
  local list = type(j.transfers) == "table" and j.transfers or {}
  list[#list + 1] = { to = to, by = cfg.user, at = os.time() }
  while #list > hub.TRANSFERS_KEPT do table.remove(list, 1) end -- (the oldest go: the chain from the sharer is replayed from what's left)
  j.transfers = list
  band.write_json(path, j)
  band.log(string.format("'%s': its hub is %s's computer from now on (the song's home)", song, to))
  return true
end

-- What goes in this computer's status (Live sync's P.status): when it came online, its link, handed on, and the roles it holds now.
local held = {} -- root -> { studio = bool, songs = { [song] = bool } }: this script's last election
local link_ok = false
function hub.status_part(cfg, b)
  local h = held[cfg.root] or { songs = {} }
  return { since = hub.since(), link = link_ok or nil, off = hub.off(cfg.root) or nil, studio = h.studio or nil, song = b and h.songs[b.song] or nil }
end

-- The studio's statuses, read a few songs at a time (SCAN_MS a tick), every SCAN_EVERY s; shared through ExtState with the other Live sync tabs,
-- so one scan serves them all. -> the candidates, or nil while the first scan is under way.
local scans = {} -- root -> { songs, i, sts, done = cands, at }
local seen_at = {} -- status path -> { time, at }: when its time last changed here
local function cands_key(root) return "hub cands " .. id_of(root) end
local function scan(cfg)
  local now, c = reaper.time_precise(), scans[cfg.root]
  local shared = band.ext_json(band.SECTION, cands_key(cfg.root))
  if type(shared) == "table" and tonumber(shared.at) and now - shared.at < hub.SCAN_EVERY and now >= shared.at and type(shared.list) == "table"
    and not (c and c.done and c.at >= shared.at) then
    scans[cfg.root] = { done = shared.list, at = shared.at }
    return shared.list
  end
  if c and c.done and now - c.at < hub.SCAN_EVERY then return c.done end
  if not (c and c.songs) then
    local okd, direct = pcall(require, "direct")
    link_ok = okd and direct.available() and direct.live_available() and direct.firewall_ok() or false
    c = { songs = band.songs(cfg), i = 1, sts = {}, done = c and c.done, at = c and c.at }
    scans[cfg.root] = c
  end
  local t0, os_now = reaper.time_precise(), os.time()
  while c.i <= #c.songs and (reaper.time_precise() - t0) * 1000 < hub.SCAN_MS do
    local s = c.songs[c.i]
    local rdir = band.song_dir(cfg, s) .. "/rooms"
    for _, room in ipairs(band.subdirs(rdir)) do
      local dir = rdir .. "/" .. room .. "/status"
      for _, f in ipairs(band.files(dir, ".json")) do
        local st = band.read_json(dir .. "/" .. f)
        if type(st) == "table" and type(st.time) == "string" then
          local l = seen_at[dir .. "/" .. f]
          if not l or l.time ~= st.time then l = { time = st.time, at = l and os_now or -math.huge }; seen_at[dir .. "/" .. f] = l end
          c.sts[#c.sts + 1] = { song = s, st = st, seen = l.at }
        end
      end
    end
    c.i = c.i + 1
  end
  if c.i <= #c.songs then return c.done end
  local list = hub.candidates(c.sts, os_now, band.age)
  scans[cfg.root] = { done = list, at = now }
  band.set_ext_json(band.SECTION, cands_key(cfg.root), { at = now, list = list }, false)
  return list
end
-- This computer as it is now (fresher than its own status file): since, link, off, and in this song.
local function with_me(list, cfg, song)
  local out, me = {}, nil
  for _, c in ipairs(list or {}) do
    if c.user == cfg.user then
      me = { user = c.user, machine = c.machine, songs = {} }
      for k, v in pairs(c.songs) do me.songs[k] = v end
      out[#out + 1] = me
    else out[#out + 1] = c end
  end
  if not me then me = { user = cfg.user, songs = {} }; out[#out + 1] = me end
  local h = held[cfg.root] or { songs = {} }
  me.machine = me.machine or require("sync").machine()
  me.since, me.link, me.off, me.studio = hub.since(), link_ok, hub.off(cfg.root), h.studio == true
  me.songs[song] = { holds = h.songs[song] == true }
  return out
end

-- Live sync's tick: who's hub, published for Health (ExtState "hub view <id> <song>"), and this computer's job when it's this song's hub.
local view = {} -- root\nsong -> the last published view (said once when it changes)
local job = {} -- root\nsong\nroom -> { count (events when last snapshotted here), last_end, dur, state }
local idle = { cc = nil, since = 0 }
local ticked = {} -- root\nsong -> reaper.time_precise of the last whole tick
function hub.tick(proj, cfg, b)
  if not (b and b.song and b.room) then return end
  local tk = cfg.root .. "\n" .. b.song
  if reaper.time_precise() - (ticked[tk] or -math.huge) < hub.TICK_EVERY then return end
  ticked[tk] = reaper.time_precise()
  local list = scan(cfg)
  if not list then return end
  list = with_me(list, cfg, b.song)
  local now = os.time()
  local groups = require("groups")
  local pref = groups.trusted(cfg.root).hub
  local studio, swhy = hub.elect_studio(list, type(pref) == "string" and pref or nil, now)
  local home, moved = hub.home(cfg, b.song)
  local song, why = hub.elect_song(list, b.song, home, studio, now)
  local h = held[cfg.root] or { songs = {} }
  h.studio, h.songs[b.song] = studio == cfg.user, song == cfg.user
  held[cfg.root] = h
  local v = { studio = studio, studio_why = swhy, song = b.song, hub = song, why = why, home = home, moved = moved }
  local key = cfg.root .. "\n" .. b.song
  local was = view[key]
  if not was or was.hub ~= song or was.studio ~= studio then
    if song == cfg.user and (not was or was.hub ~= cfg.user) then band.log("you're the hub for '" .. b.song .. "' now: it keeps the song's restore points while you're not playing or recording (Health: Hand it on)")
    elseif was and was.hub == cfg.user and song ~= cfg.user then band.log("'" .. b.song .. "': " .. (song and (song .. " is its hub now") or "no hub here now: the cloud copy stands in")) end
  end
  view[key] = v
  v.job = hub.job_tick(proj, cfg, b, song == cfg.user)
  band.set_ext_json(band.SECTION, "hub view " .. id_of(cfg.root) .. " " .. b.song, v, false)
end

-- The song hub's job: a restore point ("hub snapshot") of the room now and then, from the open project. -> its state for Health:
-- { state = "kept" | "paused" | "waiting" | "off", last (os.time), dur }.
function hub.job_tick(proj, cfg, b, mine)
  local k = cfg.root .. "\n" .. b.song .. "\n" .. b.room
  local j = job[k] or {}
  job[k] = j
  if not mine then j.state = "off"; return { state = "off" } end
  local tnow = reaper.time_precise()
  if reaper.GetPlayState() ~= 0 then idle.cc, idle.since = nil, tnow; return { state = "paused", last = j.last, dur = j.dur } end -- (any tab playing or recording)
  local cc = reaper.GetProjectStateChangeCount(proj)
  if cc ~= idle.cc then idle.cc, idle.since = cc, tnow end
  local sync = require("sync")
  if tnow - idle.since < hub.IDLE or sync.loading[tostring(proj)] then return { state = "waiting", last = j.last, dur = j.dur } end
  if j.looked and tnow - j.looked < 60 then return { state = j.state or "waiting", last = j.last, dur = j.dur } end
  j.looked = tnow
  local recall = require("recall")
  local last
  for _, f in ipairs(band.files(recall.dir(cfg, b.song, b.room), ".json")) do
    local t = hub.snap_time(f)
    if t and (not last or t > last) then last = t end
  end
  j.last = last
  local count = #band.listing(sync.room_dir(cfg, b.song, b.room) .. "/events", ".json")
  local changed -- (nil: not known here, as after a handover)
  if j.count then changed = count ~= j.count end
  local due = hub.snap_due(os.time(), last, changed, j.last_end, j.dur)
  if count == 0 or not due then j.state = "kept"; return { state = "kept", last = last, dur = j.dur } end
  local t0 = reaper.time_precise()
  local ok, err = pcall(recall.save, proj, cfg, b.song, b.room, hub.LABEL, false)
  j.dur, j.last_end, j.count = reaper.time_precise() - t0, os.time(), count
  if ok then j.last, j.state = os.time(), "kept" else band.log("hub: couldn't keep a restore point of '" .. b.song .. "': " .. tostring(err)) end
  return { state = "kept", last = j.last, dur = j.dur }
end

-- Health's row (lib/page_health.lua), from what Live sync published for this song. Its button hands the role on, or takes it up again.
function hub.health_row(cfg, b)
  if not (b and b.song) then return nil end
  local v = band.ext_json(band.SECTION, "hub view " .. id_of(cfg.root) .. " " .. b.song)
  local off = hub.off(cfg.root)
  if type(v) ~= "table" then return nil end
  local text = hub.line(v, cfg.user)
  local mine = v.hub == cfg.user or v.studio == cfg.user
  if v.hub == cfg.user then
    local jb = type(v.job) == "table" and v.job or {}
    local last = tonumber(jb.last) and string.format("last %d min ago", math.floor((os.time() - jb.last) / 60)) or "none yet"
    text = text .. " You're this song's hub: it keeps the song's restore points (" .. last .. ")" ..
      (jb.state == "paused" and ", paused while REAPER plays or records." or jb.state == "waiting" and ", waiting until you've stopped working for a minute." or ".")
  end
  if off then text = text .. " You handed the role on: this computer is nobody's hub." end
  local row = { "hub", true, "grey", text, text }
  if mine and not off then
    row.action = { "Hand it on", function() hub.set_off(cfg.root, true) end, "The next computer takes the hub role within a few seconds; nothing is lost (the hub keeps " ..
      "only copies). Be a hub again from here any time." }
  elseif off then
    row.action = { "Be a hub again", function() hub.set_off(cfg.root, false) end, "This computer can take a hub role again, as the ranking says." }
  end
  return row
end

-- Settings > Studio: the preferred studio hub (band.json "hub": owner and admins) and the open song's home (its sharer, its hub now, the owner
-- or an admin may hand it on). `may`: owner or admin.
local members_c = { at = -math.huge }
local function members(root)
  if reaper.time_precise() - members_c.at < 30 and members_c.root == root then return members_c.list end
  local list, seen = {}, {}
  for _, f in ipairs(band.files(root .. "/_band/devices", ".json")) do
    local d = band.read_json(root .. "/_band/devices/" .. f)
    if type(d) == "table" and type(d.user) == "string" and not seen[d.user] then seen[d.user] = true; list[#list + 1] = d.user end
  end
  table.sort(list)
  members_c = { at = reaper.time_precise(), root = root, list = list }
  return list
end
local function pick(ctx, ImGui, id, label, cur, names, none)
  local chosen
  if ImGui.BeginCombo(ctx, id, label) then
    if none and ImGui.Selectable(ctx, none, cur == nil) then chosen = false end
    for _, n in ipairs(names) do if ImGui.Selectable(ctx, n, n == cur) then chosen = n end end
    ImGui.EndCombo(ctx)
  end
  return chosen
end
function hub.studio_ui(ctx, ImGui, cfg, may)
  ImGui.SeparatorText(ctx, "Hub")
  ImGui.TextDisabled(ctx, "One online computer is the studio's hub and each song has one (whoever shared it, unless it's handed on). A song's hub keeps its " ..
    "restore points while that REAPER isn't playing or recording. Nothing depends on a hub: with none online, everyone still syncs directly and the cloud copy stands in.")
  local pref = require("groups").trusted(cfg.root).hub
  pref = type(pref) == "string" and pref or nil
  if may then
    local ch = pick(ctx, ImGui, "Preferred studio hub##hubpref", pref or "None: the computer online longest", pref, members(cfg.root), "None: the computer online longest")
    if ch ~= nil then
      require("groups").set_hub(cfg.root, ch or nil)
      band.log(ch and ("the studio's preferred hub is " .. ch .. "'s computer: it takes the role whenever it's online") or "no preferred hub: the computer online longest is the studio's hub")
    end
    ImGui.SetItemTooltip(ctx, "Owner and admins. Usually the computer that's on most, with the best connection.")
  else ImGui.Text(ctx, "Preferred studio hub: " .. (pref or "none (the computer online longest)")) end
  local front = band.binding(reaper.EnumProjects(-1))
  if front and front.song and band.same_studio(front.root, cfg.root) then
    local home = hub.home(cfg, front.song)
    if hub.may_hand(cfg, front.song, cfg.user) then
      local ch = pick(ctx, ImGui, "'" .. front.song .. "' hub##hubsong", tostring(home or "?"), home, members(cfg.root))
      if ch and ch ~= home then local _, why = hub.hand_song(cfg, front.song, ch); if why then band.log(why) end end
      ImGui.SetItemTooltip(ctx, "Whoever shared the song, its hub now, the owner or an admin. Hands the song's hub on for good; with that computer offline, the studio hub stands in.")
    else ImGui.Text(ctx, "'" .. front.song .. "' hub: " .. tostring(home or "?")) end
  end
end

return hub
