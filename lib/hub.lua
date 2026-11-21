-- The studio's hub and each song's (docs/realtime-roadmap.md "More big ideas" 1; James, rt). One online computer is the studio's hub and each
-- song has one too; every computer works out the same ones from what they all see (the status files: who's online, since when, in which song,
-- who holds a role now; band.json's preferred hub; the song's own hub.json), so nobody is told and nothing is negotiated.
--   Studio hub: the owner's preferred computer when it's online (handed back to it once it's been on HANDBACK s), else whoever holds it now
--     (so it doesn't flap), else the ranking: the direct link listening there first, then online longest, then its machine id.
--   A song's hub: its home (the member who added the song, or whoever it was handed to since: <song>/hub/), else whoever holds it now, else the studio
--     hub if it has the song open, else the ranking among those in the song; nobody there: the cloud copy stands in (it already carries every
--     restore point both ways: lib/drive.lua). Below the home, a song's ranking starts with who reaches whom (hub.reach, rt-hubrank): the
--     computer the most others in the room reach, then the one that reaches the most itself, then the ranking above; whoever holds the role
--     keeps it unless another has been reached by more of the others for REACH_SETTLE s. The home itself is passed over while HOME_MISS of
--     the others can't reach it and another is reached by all (rt-p9); a computer whose Syncthing is behind takes no role (hub.lagging).
--   Nothing depends on it: peer to peer and Syncthing stay the baseline, and what the hub keeps is never the only copy.
-- The hub is someone's working REAPER: its one job here (a song's restore points, "hub snapshot") runs only while that REAPER is stopped and
-- untouched for IDLE s, never while anything records or plays, at most every SNAP_EVERY s and within a CPU budget; the person can hand the role
-- on (Health), and the next computer takes it.
-- Second slice (James, rt): a hub that drops is noticed by the direct link within seconds (hub.link_watch), its status file's age the fallback;
-- a handover counts only from its hander's own computer (each person's own file, checked with Syncthing: trust.own_file_ok); guests are
-- never a hub.
local band = require("band")
local hub = { SCAN_EVERY = 10, FRESH = 45, HANDBACK = 30, SNAP_EVERY = 1800, IDLE = 60, BUDGET = 0.002, SCAN_MS = 4, TICK_EVERY = 2, LABEL = "hub snapshot",
  TRANSFERS_KEPT = 50, LINK_GONE = 12, GUESTS_EVERY = 10, LISTEN = 45,
  -- (rt-hubfix, 2026-11-20: the song's hub flipped between the desktop and the Mac 24 times in a day. They can't reach each other directly, so
  -- each read the other's status only as a file through Syncthing, and whenever it came over FRESH s late one took the role and gave it back.)
  -- VOUCH: a status up to this old still counts while a computer here says its direct link reaches that one (its status's hub.sees: a third
  -- computer that reaches both). HOLD: whoever holds a role keeps counting this long with nobody vouching (the takeover's hysteresis; the
  -- link's own LINK_GONE still drops one it had reached within seconds). EXT: the extension the hub's jobs need (the live mix says whom it
  -- has from 1.0.28: an older one as the hub left listeners deaf to anyone it couldn't hear); an older one isn't elected while a computer
  -- with it is here.
  VOUCH = 150, HOLD = 90, EXT = "1.0.28",
  -- (rt-hubrank: a song's hub by who reaches whom.) REACH: how many more of the others must reach another computer than reach the one
  -- holding the role before it moves; REACH_SETTLE: for how long, without a break (a link that drops for a moment takes a name out of
  -- `sees` after LINK_GONE s and puts it back at once: that alone never moves the role).
  REACH = 1, REACH_SETTLE = 30,
  -- (rt-p9, backlog 4.d) HOME_MISS: the song's home is passed over once this many of the others here can't reach it while another is
  -- reached by all, for REACH_SETTLE s (and hosts again once reached for as long). LAG_HEARD: a computer that hears at least this many
  -- bandmates over the direct link while none of their status files here is under VOUCH s old has its Syncthing paused or broken: it says
  -- `lag` in its status and nobody elects it (hub.lagging).
  HOME_MISS = 2, LAG_HEARD = 2 }

-- ---- pure ----------------------------------------------------------------------------------------------------------------------------
-- Candidates: { user, machine, since (os.time it came online), link (its direct link listens), off (handed the role on), studio (holds the
-- studio hub now), songs = { [song] = { holds = true when it holds that song's hub now } }, listening (just came online: keeps a role it
-- holds, takes none: hub.tick), ext, sees; songs[song].sees = those its direct link reaches in that song's room; miss, blind: hub.reach's }.
-- The ranking, the same on every computer: the link listening first, then online longest, then machine id, then name.
function hub.better(a, b)
  if (a.link == true) ~= (b.link == true) then return a.link == true end
  local sa, sb = tonumber(a.since) or math.huge, tonumber(b.since) or math.huge
  if sa ~= sb then return sa < sb end
  local ma, mb = tostring(a.machine or ""), tostring(b.machine or "")
  if ma ~= mb then return ma < mb end
  return tostring(a.user) < tostring(b.user)
end
-- A song's ranking (rt-hubrank): the one the most others in its room reach (the fewest `miss`), then the one that reaches the most of them
-- itself (the fewest `blind`), then hub.better. hub.reach sets both; without it this is hub.better.
function hub.closer(a, b)
  local ma, mb = tonumber(a.miss) or 0, tonumber(b.miss) or 0
  if ma ~= mb then return ma < mb end
  ma, mb = tonumber(a.blind) or 0, tonumber(b.blind) or 0
  if ma ~= mb then return ma < mb end
  return hub.better(a, b)
end
local function best(list, keep, cmp)
  local out
  for _, c in ipairs(list) do if (not keep or keep(c)) and (not out or (cmp or hub.better)(c, out)) then out = c end end
  return out
end
local function find(list, user) for _, c in ipairs(list) do if c.user == user then return c end end end
-- A computer that comes back takes its role back once it's been on HANDBACK s, or at once when nobody else holds it (no flapping on a computer
-- that drops in and out). back: when the direct link reached it again after losing it (hub.link_watch): counted from then, not from its since.
local function settled(c, now, others_hold)
  return not others_hold or (now - math.max(tonumber(c.since) or now, tonumber(c.back) or -math.huge)) >= hub.HANDBACK
end

-- Takes a role it doesn't hold: not just come online. Its own `listening` (hub.tick), and for everyone else the same LISTEN s from its
-- `since`, so the others don't name a computer that won't take the role yet (they named it up to 15 s early: HANDBACK against LISTEN. rt-p9)
local function taking(c, now)
  return not c.listening and not (now and tonumber(c.since) and now - c.since < hub.LISTEN)
end
-- Those that may hold a role: not handed on, and not behind on Syncthing (hub.lagging), unless every one is (then as before rt-p9).
local function eligible(list)
  local ok, all = {}, {}
  for _, c in ipairs(list) do if not c.off then all[#all + 1] = c; if not c.lag then ok[#ok + 1] = c end end end
  return #ok > 0 and ok or all
end
-- Is an extension new enough for the hub's jobs? Pure.
function hub.fit(ext) return type(ext) == "string" and ext ~= "" and band.compare_versions(ext, hub.EXT) >= 0 end
-- A candidate's: one whose status doesn't say (an older StudioSync there, until its update arrives) counts as before, so an update that
-- reaches the computers one by one doesn't hand the roles to whoever got it first. A computer with no extension says "0".
function hub.fits(ext) return ext == nil or hub.fit(ext) end
-- Those whose extension is (or isn't said: hub.fits); all of them when nobody's is (the restore points need none, so the role still goes to someone).
local function fit_only(list)
  local out = {}
  for _, c in ipairs(list) do if hub.fits(c.ext) then out[#out + 1] = c end end
  return #out > 0 and out or list
end
-- -> the studio hub's user (nil: nobody online who'll take it) and why: "preferred", "kept", "ranked", or "nobody".
function hub.elect_studio(cands, preferred, now)
  local ok = fit_only(eligible(cands or {}))
  local holder = best(ok, function(c) return c.studio == true end)
  local p = preferred and find(ok, preferred)
  if p and taking(p, now) and settled(p, now, holder and holder ~= p) then return p.user, "preferred" end
  if holder then return holder.user, "kept" end
  local r = best(ok, function(c) return taking(c, now) end)
  if r then return r.user, "ranked" end
  return nil, "nobody"
end

-- Is `r` clearly better reached than `h` (who holds the role, or would get it ahead of the ranking)? Only when REACH more of the others
-- reach it: the tie-breakers alone (reaching more itself, the link, online longer) never move a role. With mem (the caller's, kept between
-- ticks, one per song): only once that has been so for REACH_SETTLE s without a break, so a link that drops for a moment, or statuses that
-- arrive at different moments, don't move it. Pure.
local function clearly(r, h, now, mem)
  local yes = r ~= nil and h ~= nil and r ~= h and (tonumber(h.miss) or 0) - (tonumber(r.miss) or 0) >= hub.REACH
  if not mem then return yes end
  if not yes or mem.who ~= h.user then mem.who, mem.at = yes and h.user or nil, yes and now or nil end
  return yes and now - mem.at >= hub.REACH_SETTLE
end
-- -> a song's hub (nil: nobody in it who'll take it: the cloud copy stands in) and why: "home", "kept", "studio", "ranked", or "nobody".
-- home: hub.home_of's; studio: the studio hub's user; mem: clearly's (nil: no settling time). The home first, as ever (James: the project's
-- home hosts). Below it who reaches whom counts (the caller ran hub.reach on the room first; without it, as before rt-hubrank): the holder
-- keeps the role unless another is clearly better reached, the studio hub is passed over for one clearly better reached, and the ranking
-- is hub.closer. Two that both say they hold it: hub.better's as ever, at once and the same everywhere (the numbers reach the computers
-- at different moments: between two holders they'd name different ones for a while), and reach then moves it through the settling time.
-- Is the song's home `h` passed over (backlog 4.d, rt-p9)? HOME_MISS or more of the others here don't reach it while another that would
-- take the role is reached by all of them. With mem: only once that has been so for REACH_SETTLE s without a break, and it hosts again once
-- it hasn't been so for as long (a link that drops for a moment moves nothing either way). Pure.
local function home_far(h, here, now, mem)
  local far = (tonumber(h.miss) or 0) >= hub.HOME_MISS
  if far then
    far = false
    for _, c in ipairs(here) do if c ~= h and tonumber(c.miss) == 0 and taking(c, now) then far = true end end
  end
  if not mem then return far end
  local m = mem.home
  if not m or m.who ~= h.user then m = { who = h.user, passed = false }; mem.home = m end
  if far == m.passed then m.at = nil
  else
    m.at = m.at or now
    if now - m.at >= hub.REACH_SETTLE then m.passed, m.at = far, nil end
  end
  return m.passed
end
-- -> also, as a third value, how many here can't reach the home when it's passed over (nil otherwise).
function hub.elect_song(cands, song, home, studio, now, mem)
  local here = {}
  for _, c in ipairs(cands or {}) do if type(c.songs) == "table" and c.songs[song] then here[#here + 1] = c end end
  here = fit_only(eligible(here))
  local h = home and find(here, home)
  local passed = h and home_far(h, here, now, mem) and tonumber(h.miss) or nil
  if passed then -- (passed over: not as the home, nor as the one holding it)
    local rest = {}
    for _, c in ipairs(here) do if c ~= h then rest[#rest + 1] = c end end
    here, h = rest, nil
  end
  local holder = best(here, function(c) return c.songs[song].holds == true end)
  local r = best(here, function(c) return taking(c, now) end, hub.closer)
  local worse = clearly(r, holder, now, mem)
  if h and taking(h, now) and settled(h, now, holder and holder ~= h) then return h.user, "home" end
  if holder and not worse then return holder.user, "kept", passed end
  local s = studio and find(here, studio)
  if s and not clearly(r, s) then return studio, "studio", passed end
  if r then return r.user, "ranked", passed end
  return nil, "nobody", passed
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
-- Each person's newest status gives their since/link/off/studio, ext (their extension) and sees (those their direct link reaches); every
-- song they're fresh in goes in songs. Someone with no fresh status but one under VOUCH s old is kept as `late` (its age, s), in that
-- newest status's song only: hub.vouched decides whether they still count.
-- A status's sees as a set: those its computer's direct link reaches in that status's room. Pure.
function hub.seen(st)
  local out, h = {}, type(st) == "table" and type(st.hub) == "table" and st.hub or {}
  for _, u in ipairs(type(h.sees) == "table" and h.sees or {}) do if type(u) == "string" then out[u] = true end end
  return out
end
local function person(c, st)
  local h = type(st.hub) == "table" and st.hub or {}
  c.time, c.machine, c.since, c.link, c.off, c.studio = st.time, st.machine, tonumber(h.since), h.link == true, h.off == true, h.studio == true
  c.lag = h.lag == true or nil -- (its Syncthing is behind: hub.lagging)
  c.ext, c.sees = type(h.ext) == "string" and h.ext or nil, hub.seen(st)
end
function hub.candidates(sts, now, age_of)
  local by, out, late = {}, {}, {}
  for _, s in ipairs(sts or {}) do
    local st = s.st
    if type(st) == "table" and type(st.user) == "string" and type(st.time) == "string" and type(s.song) == "string" then
      local age = age_of(st.time)
      if age < hub.FRESH or now - (tonumber(s.seen) or -math.huge) < hub.FRESH then
        local c = by[st.user]
        if not c then c = { user = st.user, songs = {} }; by[st.user] = c; out[#out + 1] = c end
        if not c.time or st.time > c.time then person(c, st) end
        c.songs[s.song] = c.songs[s.song] or {}
        if type(st.hub) == "table" and st.hub.song == true then c.songs[s.song].holds = true end
        -- (whom it reaches in this song's room, song by song: its newest status may be another song's. Two rooms of one song: either. hub.reach)
        local sg = c.songs[s.song]
        sg.sees = sg.sees or {}
        for u in pairs(hub.seen(st)) do sg.sees[u] = true end
      elseif age < hub.VOUCH and (not late[st.user] or st.time > late[st.user].st.time) then
        late[st.user] = { st = st, song = s.song, age = age }
      end
    end
  end
  for user, l in pairs(late) do
    if not by[user] then
      local c = { user = user, late = l.age, songs = { [l.song] = { holds = type(l.st.hub) == "table" and l.st.hub.song == true or nil, sees = hub.seen(l.st) } } }
      person(c, l.st)
      out[#out + 1] = c
    end
  end
  table.sort(out, function(a, b) return a.user < b.user end)
  return out
end
-- The open room's statuses as presence has them (the link's messages too: seconds old, where a file through Syncthing is up to FILE_QUIET s
-- old plus its trip) over the scan's candidates: each one fresh there is fresh here, in this song, with its newer word. -> a new list. Pure.
function hub.with_room(list, sts, song)
  local out, at = {}, {}
  for _, c in ipairs(list or {}) do out[#out + 1] = c; at[c.user] = #out end
  for _, st in ipairs(sts or {}) do
    if type(st) == "table" and type(st.user) == "string" and type(st.time) == "string" then
      local old = at[st.user] and out[at[st.user]]
      local c = { user = st.user, songs = {} }
      if old and not old.late then for k, v in pairs(old.songs) do c.songs[k] = v end end
      local newer = old and old.time and old.time > st.time
      if newer then for _, k in ipairs({ "time", "machine", "since", "link", "off", "studio", "ext", "sees", "lag" }) do c[k] = old[k] end
      else person(c, st) end
      local was = newer and type(old.songs) == "table" and old.songs[song]
      c.songs[song] = { holds = type(st.hub) == "table" and st.hub.song == true or nil, sees = type(was) == "table" and was.sees or hub.seen(st) }
      if old then out[at[st.user]] = c else out[#out + 1] = c; at[st.user] = #out end
    end
  end
  table.sort(out, function(a, b) return a.user < b.user end)
  return out
end
-- The candidates that count: a late one only while a computer that isn't late says its link reaches it (sees), or, holding a role, for
-- HOLD s. So two computers that can't reach each other still agree while a third reaches both, and a status that comes late through
-- Syncthing doesn't move a role there and back. -> a new list. Pure.
function hub.vouched(list)
  local out = {}
  for _, c in ipairs(list or {}) do
    local keep = not c.late
    if not keep then
      for _, v in ipairs(list) do keep = keep or (v ~= c and not v.late and type(v.sees) == "table" and v.sees[c.user] == true) end
      local holds = c.studio == true
      for _, sg in pairs(type(c.songs) == "table" and c.songs or {}) do holds = holds or (type(sg) == "table" and sg.holds == true) end
      keep = keep or (holds and c.late < hub.HOLD)
    end
    if keep then out[#out + 1] = c end
  end
  return out
end

-- Who reaches whom in a song's room (rt-hubrank). Each candidate there gets miss (how many of the others there don't reach it, by THEIR
-- word: their status's sees) and blind (how many of them it doesn't reach, by its own). One whose status doesn't say (no ext: an older
-- StudioSync, as hub.fits) is nobody's miss and has none itself, so it ranks as before; those not in the song get neither. Every computer
-- works out the same numbers from the same statuses. In place; -> cands. Pure.
-- guests (a set of names, rt-p9): a guest in the room counts as one of the others each must reach, by that computer's own word (does its
-- `sees` name the guest?), never the guest's: a guest's word moves nothing, but a hub a guest can't reach is a miss. Guests get no numbers.
local function sees_in(c, song) local s = c.songs[song].sees; return type(s) == "table" and s or {} end
function hub.reach(cands, song, guests)
  local here, gs = {}, {}
  for _, c in ipairs(cands or {}) do
    c.miss, c.blind = nil, nil
    if type(c.songs) == "table" and type(c.songs[song]) == "table" and c.ext ~= nil then
      if guests and guests[c.user] then gs[#gs + 1] = c else here[#here + 1] = c end
    end
  end
  for _, c in ipairs(here) do
    c.miss, c.blind = 0, 0
    for _, o in ipairs(here) do
      if o ~= c then
        if not sees_in(o, song)[c.user] then c.miss = c.miss + 1 end
        if not sees_in(c, song)[o.user] then c.blind = c.blind + 1 end
      end
    end
    for _, g in ipairs(gs) do if not sees_in(c, song)[g.user] then c.miss = c.miss + 1 end end
  end
  return cands
end
-- Those in the song's room whose direct link doesn't reach `user` (the song's hub), by their own word (a guest: by the hub's word, as
-- hub.reach); sorted names, for Health. Pure.
function hub.far(cands, song, user, guests)
  local out, hc = {}, find(cands or {}, user)
  for _, c in ipairs(cands or {}) do
    if c.user ~= user and c.ext ~= nil and type(c.songs) == "table" and type(c.songs[song]) == "table" then
      local g = guests and guests[c.user]
      if (g and hc and type(hc.songs) == "table" and type(hc.songs[song]) == "table" and not sees_in(hc, song)[c.user]) or (not g and not sees_in(c, song)[user]) then out[#out + 1] = c.user end
    end
  end
  table.sort(out)
  return out
end
-- Is this computer's Syncthing behind (paused or broken here)? live: the room's statuses the direct link brought (presence.live: user ->
-- status); list: the scan's candidates (status files under VOUCH s old). True when the link hears LAG_HEARD or more bandmates and none of
-- them has such a file here. One bandmate alone can't tell whose Syncthing it is (theirs or this one's), so two computers never lag. Pure.
function hub.lagging(live, list)
  local files, heard = {}, 0
  for _, c in ipairs(list or {}) do files[c.user] = true end
  for user, st in pairs(type(live) == "table" and live or {}) do
    if type(st) == "table" and type(st.time) == "string" and band.age(st.time) < hub.FRESH then
      if files[user] then return false end
      heard = heard + 1
    end
  end
  return heard >= hub.LAG_HEARD
end

-- Failover in seconds. reach: direct.reach's user -> { ok, at } for those here; mem: this computer's memory of each, kept between ticks. One
-- the link has reached and that hasn't answered for LINK_GONE s is gone, though its status file stays fresh for 45 s; one it never reached is
-- left to the status files. LINK_GONE spans a failed ping and the extension's 10 s wait before it tries that computer again, so one dropped
-- ping doesn't move the role. -> gone (a set), back (user -> os.time the link reached them again after losing them, for HANDBACK s). Pure.
function hub.link_watch(mem, reach, now)
  reach = reach or {}
  for user, r in pairs(reach) do
    local m = mem[user] or {}
    mem[user] = m
    if r.ok and now - (tonumber(r.at) or 0) < hub.LINK_GONE then
      if m.gone or m.out then m.back = now end
      m.reached, m.fail, m.gone, m.out = true, nil, nil, nil
    elseif m.reached then
      m.fail = m.fail or now
      if now - m.fail >= hub.LINK_GONE then m.gone = true end
    end
  end
  local gone, back = {}, {}
  for user, m in pairs(mem) do
    -- (out of the link's list: their status went stale, or this computer is in another song now. The status files decide then; back once in it)
    if not reach[user] and m.reached then m.out, m.fail, m.gone = true, nil, nil end
    if m.gone then gone[user] = true end
    if m.back and now - m.back < hub.HANDBACK then back[user] = m.back end
  end
  return gone, back
end
-- The candidates without those the link lost and without guests (guests are never a hub: James, rt), each with its `back`. -> a new list. Pure.
function hub.drop(list, gone, guests, back)
  local out = {}
  for _, c in ipairs(list or {}) do
    if not ((gone or {})[c.user] or (guests or {})[c.user]) then c.back = (back or {})[c.user]; out[#out + 1] = c end
  end
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

-- Health's words. v: { studio, studio_why, song, hub, why, home, fast (the link watches those here), gone (names the link lost), guest (this
-- computer is a guest's), refused (names whose handover file came from another computer) }; me: this computer's user. Pure.
local WHY_STUDIO = { preferred = "the owner's pick", kept = "holding it", ranked = "online longest" }
local function who(u, me) return u == me and "you" or u end
function hub.line(v, me)
  local s = v.studio and (who(v.studio, me) .. " (" .. (WHY_STUDIO[v.studio_why] or "?") .. ")") or "nobody online"
  -- (passed: the home is here but that many can't reach it, rt-p9)
  local away = v.home and (v.passed and (", " .. v.home .. " is the project's home but " .. v.passed .. " here can't reach it directly") or (", " .. v.home .. " is away")) or ""
  local why = v.why == "home" and (v.moved and "it was handed to them" or "shared it")
    or v.why == "kept" and ("holding it" .. (v.home and v.home ~= v.hub and (v.passed and away or (" until " .. v.home .. " is back")) or ""))
    or v.why == "studio" and ("the studio hub" .. away)
    or v.why == "ranked" and ("the one the others here reach best, then online longest" .. away) or ""
  local song = v.hub and (who(v.hub, me) .. " (" .. why .. ")") or "nobody here, so the cloud copy stands in"
  local out = "Hub: " .. s .. "; this project: " .. song .. "."
  if v.guest then out = out .. " You're a guest here: guests are never a hub." end
  if v.lag then out = out .. " Syncthing is behind here (the direct link hears bandmates whose status files haven't arrived), so this computer takes no hub role until it catches up." end
  if type(v.gone) == "table" and #v.gone > 0 then out = out .. " The direct link lost " .. table.concat(v.gone, ", ") .. ": not counted until it reaches them again." end
  if type(v.refused) == "table" and #v.refused > 0 then
    out = out .. " A handover in " .. table.concat(v.refused, ", ") .. "'s name came from another computer, so it doesn't count."
  end
  -- (rt-hubrank: the home hosts whoever reaches it, so say who doesn't)
  if v.hub and type(v.far) == "table" and #v.far > 0 then out = out .. " No direct link to this project's hub from: " .. table.concat(v.far, ", ") .. "." end
  if type(v.old) == "table" and #v.old > 0 then
    out = out .. " Not a hub until REAPER restarts there with StudioSync's extension " .. hub.EXT .. " or newer: " .. table.concat(v.old, ", ") .. "."
  end
  return out .. (v.fast and " A hub that drops is replaced within seconds (direct link)." or " A hub that drops is replaced within a minute or two (the direct link makes it seconds).")
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

-- A song's handovers: <song>/hub/<person>.json = { user, transfers = { { to, at } } }, each person's own file, so each counts only when
-- Syncthing says that person's own computer wrote it (trust.own_file_ok), and so does session.json's host (who shared it). The first slice's
-- one hub.json said who handed it on in its own words: any member could write "the owner handed it to me". (James, rt)
local function hub_dir(cfg, song) return band.song_dir(cfg, song) .. "/hub" end
local function may_fn(root)
  local groups = require("groups")
  return function(u) local r = groups.role(root, u); return r == "owner" or r == "admin" or r == "open" end
end
-- -> who shared the song (nil: not known, or not checked yet), every handover that counts { to, by, at }, the names whose file came from
-- another computer (set aside; one not checked yet just waits), session.json's own word of who shared it, and whether that one's adding is
-- kept (below).
-- Who shared it is the member who added the song (James, 2026-11-21): the adder's own hub file says so (`added`, written once by their own
-- computer when they share it, hub.note_added; signed like every hub file, lib/signed.lua "hub"), and it counts when it's the person
-- session.json names. Then whoever last wrote session.json no longer matters: a bandmate's computer rewriting it (an older build's timeline)
-- set the sharer aside, and the song's home came and went with it (rt-hubfix part 2). A song with no kept adder: as before, session.json's
-- host when that person's own computer wrote it.
function hub.transfers(cfg, song)
  local trust, refused, list, adders = require("trust"), {}, {}, {}
  local s = band.read_json(band.session_path(cfg, song)) or {}
  local named = type(s.host) == "string" and s.host or nil
  local dir = hub_dir(cfg, song)
  for _, f in ipairs(band.files(dir, ".json")) do
    local j = band.read_json(dir .. "/" .. f)
    if type(j) == "table" and type(j.user) == "string" and trust.user_file(j.user) == f and type(j.transfers) == "table" then
      local newest = tonumber(j.added) or 0
      for _, t in ipairs(j.transfers) do if type(t) == "table" then newest = math.max(newest, tonumber(t.at) or 0) end end
      local ok = trust.own_file_ok(cfg.root, song .. "/hub/" .. f, j.user, newest)
      if ok == false then refused[#refused + 1] = j.user end
      if ok == true then
        if tonumber(j.added) then adders[j.user] = true end
        for _, t in ipairs(j.transfers) do if type(t) == "table" then list[#list + 1] = { to = t.to, by = j.user, at = t.at } end end
      end
    end
  end
  local sharer = named and adders[named] and named or nil
  if named and not sharer then
    local ok = trust.own_file_ok(cfg.root, song .. "/session.json", named, type(s.published) == "string" and os.time() - band.age(s.published) or nil)
    if ok == false then refused[#refused + 1] = named end
    if ok == true then sharer = named end
  end
  table.sort(refused)
  return sharer, list, refused, named, named ~= nil and adders[named] == true
end
-- The member who added `song`, noted once in their own hub file (kept with its handovers). -> true when it wrote it.
function hub.note_added(cfg, song)
  local dir = hub_dir(cfg, song)
  local path = dir .. "/" .. require("trust").user_file(cfg.user)
  local j = band.read_json(path)
  j = type(j) == "table" and j or {}
  if tonumber(j.added) then return false end
  reaper.RecursiveCreateDirectory(dir, 0)
  band.write_json(path, { user = cfg.user, transfers = type(j.transfers) == "table" and j.transfers or {}, added = os.time() })
  return true
end
local noted = {} -- root\nsong -> this computer noted its person as the adder (hub.home)
-- -> the song's home, whether it was handed on, and the names set aside (hub.transfers).
-- (a song shared before the adder was kept: the sharer session.json names notes it from their own computer the first time it looks, so it
-- keeps its home whoever writes session.json from then on. Only that person's computer, for that person.)
function hub.home(cfg, song)
  local sharer, list, refused, named, added = hub.transfers(cfg, song)
  local k = tostring(cfg.root) .. "\n" .. tostring(song)
  if named and named == cfg.user and not added and not noted[k] then noted[k] = true; pcall(hub.note_added, cfg, song) end
  local home, moved = hub.home_of(sharer, list, may_fn(cfg.root))
  return home, moved, refused
end
-- May `by` hand `song`'s hub on? Its sharer, its home now, or the owner or an admin.
function hub.may_hand(cfg, song, by)
  local sharer, list = hub.transfers(cfg, song)
  local may = may_fn(cfg.root)
  return (sharer ~= nil and by == sharer) or by == hub.home_of(sharer, list, may) or may(by)
end
-- Hands `song`'s hub to `to` for good, in this person's own file (every computer reads the same). -> true, or nil and why.
function hub.hand_song(cfg, song, to)
  if not hub.may_hand(cfg, song, cfg.user) then return nil, "only whoever shared the project, its hub, the owner or an admin can hand it on" end
  local dir = hub_dir(cfg, song)
  local path = dir .. "/" .. require("trust").user_file(cfg.user)
  local j = band.read_json(path) or {}
  local list = type(j.transfers) == "table" and j.transfers or {}
  list[#list + 1] = { to = to, at = os.time() }
  while #list > hub.TRANSFERS_KEPT do table.remove(list, 1) end -- (the oldest go: the chain from the sharer is replayed from what's left)
  reaper.RecursiveCreateDirectory(dir, 0)
  band.write_json(path, { user = cfg.user, transfers = list, added = j.added }) -- (added: kept, hub.note_added)
  band.log(string.format("'%s': its hub is %s's computer from now on (the project's home)", song, to))
  return true
end

-- What goes in this computer's status (Live sync's P.status): when it came online, its link, handed on, and the roles it holds now.
local held = {} -- root -> { studio = bool, songs = { [song] = bool } }: this script's last election
local link_ok = false
local sees_now = {} -- root\nsong -> those this computer's direct link reaches in that song's room now (sorted names): hub.tick
local lag_now = {} -- root\nsong -> true while this computer's Syncthing is behind (hub.lagging): hub.tick
-- This computer's extension as REAPER loaded it ("menu extension": the extension says its version there), or nil.
local function my_ext() local v = reaper.GetExtState(band.SECTION, "menu extension"); return type(v) == "string" and v ~= "" and v or nil end
-- (ext: so a computer whose extension is too old for the hub's jobs isn't elected; sees: so the others count someone whose status comes late
-- to them while this computer's link reaches it. rt-hubfix)
function hub.status_part(cfg, b)
  local h = held[cfg.root] or { songs = {} }
  local sees = b and sees_now[cfg.root .. "\n" .. tostring(b.song)]
  return { since = hub.since(), link = link_ok or nil, off = hub.off(cfg.root) or nil, studio = h.studio or nil, song = b and h.songs[b.song] or nil,
    ext = my_ext() or "0", sees = sees and #sees > 0 and sees or nil, lag = b and lag_now[cfg.root .. "\n" .. tostring(b.song)] or nil }
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
local function with_me(list, cfg, song, sees, lag)
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
  me.ext, me.sees, me.lag = my_ext() or "0", {}, lag or nil
  for _, u in ipairs(sees or {}) do me.sees[u] = true end
  me.songs[song] = { holds = h.songs[song] == true, sees = me.sees }
  -- Just came online: for LISTEN s it takes no role it doesn't hold, so it has heard the room first: the others' statuses read over more than
  -- one scan (one whose stamp is off counts only once it's seen changing here: hub.candidates; Syncthing may still be bringing them after
  -- REAPER or the computer was off) and the direct link's first answers in. Before, a computer back from a restart took a role the moment it
  -- saw nobody holding it, while the one holding it wasn't in its view yet: both hub at once (James, rt: the desktop and the laptop).
  me.listening = os.time() - me.since < hub.LISTEN or nil
  return out
end

-- Live sync's tick: who's hub, published for Health (ExtState "hub view <id> <song>"), and this computer's job when it's this song's hub.
local view = {} -- root\nsong -> the last published view (said once when it changes)
local job = {} -- root\nsong\nroom -> { count (events when last snapshotted here), last_end, dur, state }
local idle = { cc = nil, since = 0 }
local ticked = {} -- root\nsong -> reaper.time_precise of the last whole tick
local link_mem = {} -- root -> hub.link_watch's memory
local reach_mem = {} -- root\nsong -> hub.elect_song's memory (how long the holder has been clearly worse reached)
-- The studio's guests' names (removal.guest_names: the marks someone in charge wrote), read every GUESTS_EVERY s.
local guests_c = {} -- root -> { at, set }
local function guests(root)
  local c = guests_c[root]
  if c and reaper.time_precise() - c.at < hub.GUESTS_EVERY then return c.set end
  local ok, set = pcall(function() return require("removal").guest_names(root) end)
  c = { at = reaper.time_precise(), set = ok and type(set) == "table" and set or (c and c.set) or {} }
  guests_c[root] = c
  return c.set
end
function hub.tick(proj, cfg, b)
  if not (b and b.song and b.room) then return end
  local tk = cfg.root .. "\n" .. b.song
  if reaper.time_precise() - (ticked[tk] or -math.huge) < hub.TICK_EVERY then return end
  ticked[tk] = reaper.time_precise()
  local list = scan(cfg)
  if not list then return end
  local now = os.time()
  -- (the link's view of those here: a hub that drops is out within LINK_GONE s, not when its status goes stale)
  local okr, reach = pcall(function()
    local direct = require("direct")
    return direct.available() and direct.live_available() and direct.reach(cfg, b.song, b.room) or {}
  end)
  reach = okr and reach or {}
  link_mem[cfg.root] = link_mem[cfg.root] or {}
  local gone, back = hub.link_watch(link_mem[cfg.root], reach, now)
  -- (those the link reaches now, by its memory: one failed ping doesn't take a name out, so the status isn't written again for it)
  local sees = {}
  for user in pairs(reach) do local m = link_mem[cfg.root][user]; if m and m.reached and not m.gone then sees[#sees + 1] = user end end
  table.sort(sees)
  sees_now[tk] = sees
  -- (the room's statuses as the link brought them, this computer as it is now, then who still counts: rt-hubfix)
  local okp, sts = pcall(function() return require("presence").peers(cfg, b.song, b.room) end)
  -- (Syncthing behind here: the statuses' files vs the link's own. Said in this computer's status, so nobody elects it, the same everywhere: rt-p9)
  local okl, live = pcall(function() return require("presence").live(cfg, b.song, b.room) end)
  local lag = hub.lagging(okl and live or nil, list)
  lag_now[tk] = lag or nil
  list = hub.vouched(with_me(hub.with_room(list, okp and type(sts) == "table" and sts or {}, b.song), cfg, b.song, sees, lag))
  local lost, fast = {}, false
  for _, c in ipairs(list) do if gone[c.user] then lost[#lost + 1] = c.user end end
  for _, r in pairs(reach) do if r.ok then fast = true end end
  local gs = guests(cfg.root)
  -- (who reaches whom in this room: before the link's own losses go, so every computer counts the same statuses; a guest counts as one to
  -- reach, by the others' word, never its own)
  local room = hub.reach(list, b.song, gs)
  list = hub.drop(list, gone, gs, back)
  local groups = require("groups")
  local pref = groups.trusted(cfg.root).hub
  local studio, swhy = hub.elect_studio(list, type(pref) == "string" and pref or nil, now)
  local home, moved, refused = hub.home(cfg, b.song)
  reach_mem[tk] = reach_mem[tk] or {}
  local song, why, passed = hub.elect_song(list, b.song, home, studio, now, reach_mem[tk])
  local far = song and hub.far(room, b.song, song, gs) or {}
  local h = held[cfg.root] or { songs = {} }
  h.studio, h.songs[b.song] = studio == cfg.user, song == cfg.user
  held[cfg.root] = h
  -- (hub_fit: false when even this song's hub has an extension too old to mix, lib/liveaudio.lua hub_plan; old: those here passed over for it)
  local old, any_fit, hub_fit = {}, false, nil
  for _, c in ipairs(list) do
    if type(c.songs) == "table" and c.songs[b.song] and not c.off then
      if hub.fits(c.ext) then any_fit = true else old[#old + 1] = c.user end
      if c.user == song then hub_fit = hub.fits(c.ext) end
    end
  end
  local v = { studio = studio, studio_why = swhy, song = b.song, hub = song, why = why, home = home, moved = moved, fast = fast or nil,
    gone = #lost > 0 and lost or nil, guest = gs[cfg.user] or nil, refused = refused and #refused > 0 and refused or nil,
    hub_fit = hub_fit, old = any_fit and #old > 0 and old or nil, far = #far > 0 and far or nil, passed = passed, lag = lag or nil }
  local key = cfg.root .. "\n" .. b.song
  local was = view[key]
  if not was or was.hub ~= song or was.studio ~= studio then
    if song == cfg.user and (not was or was.hub ~= cfg.user) then band.log("you're the hub for '" .. b.song .. "' now: it keeps the project's restore points while you're not playing or recording (Health: Hand it on)")
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

-- What Live sync last published for this song (hub.tick): { studio, hub, why, ... }, or nil. lib/liveaudio.lua mixes the live audio at v.hub.
function hub.view(cfg, song)
  local v = band.ext_json(band.SECTION, "hub view " .. id_of(cfg.root) .. " " .. tostring(song))
  return type(v) == "table" and v or nil
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
    text = text .. " You're this project's hub: it keeps the project's restore points (" .. last .. ")" ..
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
  local gs = guests(root) -- (guests are never a hub, so they're not offered)
  for _, f in ipairs(band.files(root .. "/_band/devices", ".json")) do
    local d = band.read_json(root .. "/_band/devices/" .. f)
    if type(d) == "table" and type(d.user) == "string" and not seen[d.user] and not gs[d.user] then seen[d.user] = true; list[#list + 1] = d.user end
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
  ImGui.TextDisabled(ctx, "One online computer is the studio's hub and each project has one (whoever shared it, unless it's handed on). A project's hub keeps its " ..
    "restore points while that REAPER isn't playing or recording. Nothing depends on a hub: with none online, everyone still syncs directly and the cloud copy stands in. " ..
    "A hub that drops is replaced within seconds over the direct link (within a minute or two without it). Guests are never a hub, and a handover counts only from its hander's own computer.")
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
    local home, _, refused = hub.home(cfg, front.song)
    if refused and #refused > 0 then
      ImGui.TextColored(ctx, require("theme").YELLOW,"A handover in " .. table.concat(refused, ", ") .. "'s name came from another computer, so it doesn't count.")
    end
    if hub.may_hand(cfg, front.song, cfg.user) then
      local ch = pick(ctx, ImGui, "'" .. front.song .. "' hub##hubsong", tostring(home or "?"), home, members(cfg.root))
      if ch and ch ~= home then local _, why = hub.hand_song(cfg, front.song, ch); if why then band.log(why) end end
      ImGui.SetItemTooltip(ctx, "Whoever shared the project, its hub now, the owner or an admin. Hands the project's hub on for good; with that computer offline, the studio hub stands in.")
    else ImGui.Text(ctx, "'" .. front.song .. "' hub: " .. tostring(home or "?")) end
  end
end

return hub
