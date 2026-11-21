-- Catch-up's list of missing media, from a bandmate over the direct link (docs/rt/rt-linkmove.md; rt-linkfirst's inventory: "catch-up's
-- need list"). lib/streams.lua's catch-up fetches over the link what Syncthing says this computer still needs (GET /rest/db/need), so it
-- starts only once Syncthing has found the others, traded its index and been asked (CATCHUP_EVERY). Here a computer asks one bandmate in
-- its room what media that computer holds in the song's rooms:
--   "need_ask"  { user, dev, seen }            to one peer, when who's here changes and every EVERY s; seen: that peer's list this computer
--                                              has already been through (its digest), so an unchanged list isn't sent again
--   "need_list" { dev, digest, part, of, files = { { room, file, size } } }   that peer's settled media files, PER_MSG a message
-- and what it lacks goes into streams.catchup_tick's wants beside Syncthing's (needlist.pending), fetched by the same "media_want" with the
-- same checks: only a name the link takes (streams.media_name), only where nothing is there, never a file with a tombstone in the room's
-- deleted/, only that very size at the peer; and never a file this computer held since this script started and lost (a delete).
-- Syncthing's list stays, and stays the backstop: anything this misses comes as before.
-- And a file the song no longer plays is never fetched from a bandmate's list: only one the newest change to some item names (as this
-- computer has the song's changes, the link's inbox too: drive.media_in_use), and only once the event catch-up below has nothing on its way.
-- That closes "deleted while this script wasn't running": a file someone deleted that the bandmate still holds (Syncthing hasn't taken the
-- delete there yet) is wanted only while the song still plays it, which is when the cloud copy brings it back too (lib/drive.lua).
-- Events (rt-linkmove2): the same ask carries this computer's event ids per room and day (the last EV_DAYS days, a count and a sum of
-- hashes), the bandmate answers with its ids for each day that differs, and this computer asks for the ones it lacks; the bandmate sends
-- those files over the link as it sends every new one (StudioSync_DirectSend), so they land in the link's inbox and sync.receive takes them
-- as any event that came over the link, with the same checks of who may make each change. Nothing is written into the folder: Syncthing's
-- copy is still the record, and the inbox copy goes when it lands. Never an id in the room's trimmed/ lists, never one older than EV_DAYS
-- (history trim takes only changes older than trim.DAYS), never this computer's own. Asked when who's here changes, again while a round
-- brought something, and again (EV_RETRY s, doubling) until a bandmate answers, an empty list meaning every day matches (rt-catchup).
-- Off unless this computer's ExtState "link need list" is "1", on both computers, until tested on real computers (rt-linkmove.md).
-- Unreviewed (security reviews come after all features, James 2026-11-19).
local band = require("band")
local direct = require("direct")
local needlist = { EVERY = 30, SETTLE = 30, PER_MSG = 300, MAX = 6000, ANSWER_EVERY = 10, KEEP = 3600, EXT = "link need list",
  EV_DAYS = 58, EV_PER_MSG = 300, EV_MAX = 6000, EV_ROOMS = 20, EV_WAIT = 60, -- (EV_ROOMS: 20 rooms of 58 days of sums stay well under direct.MSG_MAX)
  EV_RETRY = 5, WARM = 0.016 } -- (EV_RETRY: s before an unanswered ask of event ids goes again, doubling to EVERY; WARM: s a tick, the first read)

function needlist.on() return reaper.GetExtState(band.SECTION, needlist.EXT) == "1" end

-- This computer's media in the song's rooms that the link could carry: { { room, file, size } } in name order, and its digest. Only files
-- last written SETTLE s ago or more (one still being recorded or copied in isn't whole), each measured once (media is written once, under a
-- name of its own). New files are measured for at most MEASURE s a list (a big song's first answer measured all 6,000 in one go on REAPER's
-- thread); the rest go in the next answers, as the list's digest changes. rt-p3
needlist.MEASURE = 0.008
local sizes = {}
function needlist.mine(cfg, song)
  local out, bytes, t0 = {}, 0, reaper.time_precise()
  local rooms, time_of = cfg.root .. "/" .. song .. "/rooms", reaper.StudioSync_DirectFileTime
  local streams = require("streams")
  for _, room in ipairs(band.subdirs(rooms)) do
    local dir = rooms .. "/" .. room .. "/media"
    for _, f in ipairs(band.files(dir)) do
      if #out >= needlist.MAX then break end
      local path = dir .. "/" .. f
      local size = sizes[path]
      if not size and time_of and streams.media_name(room, f) and reaper.time_precise() - t0 < needlist.MEASURE then
        local t = tonumber(time_of(path)) or -1
        size = t >= 0 and os.time() - t >= needlist.SETTLE and band.size(path) or nil
        if size and size > 0 then sizes[path] = size else size = nil end
      end
      if size then out[#out + 1], bytes = { room, f, size }, bytes + size end
    end
  end
  return out, #out .. "|" .. string.format("%d", bytes)
end

-- ---- events: ids per room and day --------------------------------------------------------------------------------------------------------
local function h32(s) local h = 2166136261; for i = 1, #s do h = ((h ~ s:byte(i)) * 16777619) & 0xFFFFFFFF end; return h end
local hashes = {} -- id -> h32 (ids are written once)
local function ev_dir(cfg, song, room) return cfg.root .. "/" .. song .. "/rooms/" .. room .. "/events" end
-- An event id the link carries, made within EV_DAYS: its day ("yyyymmdd"), or nil. Pure but for the clock.
local function ev_day(song, room, id)
  local day = type(id) == "string" and id:match("%-(%d%d%d%d%d%d%d%d)%-")
  return day and day >= os.date("!%Y%m%d", os.time() - needlist.EV_DAYS * 86400) and direct.rel_ok(song .. "/rooms/" .. room .. "/events/" .. id .. ".json") and day or nil
end
-- A room's event ids here (the folder and the link's inbox) by day: { [day] = { ids } }.
local function by_day(cfg, song, room)
  local dir = ev_dir(cfg, song, room)
  local out = {}
  for _, f in ipairs((direct.merge(cfg, dir, band.files(dir, ".json")))) do
    local id = f:sub(1, -6)
    local day = ev_day(song, room, id)
    if day then out[day] = out[day] or {}; table.insert(out[day], id) end
  end
  return out
end
local function sums_of(days)
  local out = {}
  for day, ids in pairs(days) do
    local sum = 0
    for _, id in ipairs(ids) do hashes[id] = hashes[id] or h32(id); sum = (sum + hashes[id]) & 0xFFFFFFFF end
    out[day] = #ids .. ":" .. sum
  end
  return out
end
-- The ids history trim took out of a room (its trimmed/ lists, each written once): id -> true.
local trims = {}
local function trimmed(cfg, song, room)
  local dir, out = cfg.root .. "/" .. song .. "/rooms/" .. room .. "/trimmed", {}
  for _, f in ipairs(band.files(dir, ".json")) do
    local p = dir .. "/" .. f
    trims[p] = trims[p] or band.read_json(p) or nil
    for _, id in ipairs(type(trims[p]) == "table" and trims[p] or {}) do out[tostring(id)] = true end
  end
  return out
end
needlist.ev_wanted = {} -- song/room/id -> { at, path (the folder's), inbox (the link's) }
local function ev_waiting(song)
  local now = reaper.time_precise()
  for key, w in pairs(needlist.ev_wanted) do
    local landed = reaper.file_exists(w.path) or reaper.file_exists(w.inbox)
    if landed or math.abs(now - w.at) > needlist.EV_WAIT then
      needlist.ev_wanted[key] = nil
      if landed then needlist.stale() end -- (a change that landed may play a file, or stop one playing: read again now, not in CATCHUP_LOOK s)
    elseif key:sub(1, #song + 1) == song .. "/" then return true end
  end
  return false
end

-- ---- media the song plays (the folder's own changes say so) -------------------------------------------------------------------------------
local ev_read = {} -- event file -> what drive.media_in_use needs of it (written once)
local used_song, used_at, used, pass = nil, -math.huge, nil, nil -- (pass: a read under way, resumed by the next call)
function needlist.stale() used_at, pass = -math.huge, nil end
-- { [room] = { [file] = true } } for the song as this computer has it, or nil while its changes are still being read: `budget` s a call (0.05
-- by default: catch-up's look, every CATCHUP_LOOK s), each call going on where the last one stopped.
local function in_use(root, song, budget)
  local now = reaper.time_precise()
  if used_song == song and used and math.abs(now - used_at) < require("streams").CATCHUP_LOOK then return used end
  local deadline = now + (budget or 0.05)
  if not (pass and pass.song == song and pass.root == root) then
    local cfg = { root = root }
    pass = { song = song, root = root, rooms = {}, k = 1, i = 1 }
    for _, room in ipairs(band.subdirs(root .. "/" .. song .. "/rooms")) do
      local dir = ev_dir(cfg, song, room)
      local names, from = direct.merge(cfg, dir, band.files(dir, ".json"))
      pass.rooms[#pass.rooms + 1] = { room = room, dir = dir, names = names, from = from, evs = {} }
    end
  end
  while pass.k <= #pass.rooms do
    local r = pass.rooms[pass.k]
    while pass.i <= #r.names do
      local f = r.names[pass.i]
      local p = r.from and r.from[f] or r.dir .. "/" .. f
      if ev_read[p] == nil then
        if reaper.time_precise() > deadline then return nil end
        local ev = band.read_json(p)
        if type(ev) == "table" then -- (as lib/drive.lua reads them; one not readable yet may still be arriving: read again next time)
          local e = { oid = ev.oid, time = ev.time, id = ev.id, gone = ev.gone == true or nil, obj = ev.obj, track = ev.track }
          if type(ev.state) == "string" then
            e.media = {}
            for rm, rel in ev.state:gmatch('FILE "{media:([^}]+)}/([^"]+)"') do e.media[#e.media + 1] = { rm, rel } end
          end
          ev_read[p] = e
        end
      end
      r.evs[#r.evs + 1] = ev_read[p]
      pass.i = pass.i + 1
    end
    pass.k, pass.i = pass.k + 1, 1
  end
  local rooms = {}
  for _, r in ipairs(pass.rooms) do rooms[r.room] = r.evs end
  pass, used = nil, {}
  for room in pairs(rooms) do used[room] = require("drive").media_in_use(rooms, room) end
  used_song, used_at = song, now
  return used
end
-- The first read of a song's changes, WARM s a tick from Live sync's every tick (lib/streams.lua tick) until it's through, so the media a
-- bandmate lists is judged within seconds of a fresh start: at catch-up's own 0.05 s every CATCHUP_LOOK s, 2,700 changes took about 50 s
-- (LinuxBox, 2026-11-21). WORK_BUDGET's 16 ms, as the cloud copy's first round since REAPER started (lib/drive.lua). Started by needlist.tick.
local warm
function needlist.warm()
  if not warm then return false end
  if in_use(warm.root, warm.song, needlist.WARM) then warm = nil end
  return true
end

-- ---- the asker ----------------------------------------------------------------------------------------------------------------------------
needlist.wants = {} -- song/room/file -> { room, file, size, by (the lister's device id), key, at }
local seen, parts = {}, {} -- device id -> the digest of its list this computer has been through; -> { digest, n }
local asked_at, who, round = -math.huge, nil, 0
local ev_due, ev_round = false, 0 -- (the event ids go with the next ask: who's here changed, or the last round brought some)
-- (an ask with the ids that no bandmate has answered yet goes again at `next`, the gap doubling to EVERY. A bandmate drops an ask from a
-- computer it doesn't count as here yet (peer_of), as on a fresh start before it has heard this one: asked once, the ids never came. rt-catchup)
local ev_wait -- { next, gap }
-- Live sync's tick. -> 1 when it asked.
function needlist.tick(cfg, b)
  if not needlist.on() or not direct.live_available() then return 0 end
  if not (used_song == b.song and used) and not warm then warm = { root = cfg.root, song = b.song } end -- (needlist.warm)
  local peers, dev_of = direct.peers(cfg, b.song, b.room)
  local key = cfg.root .. "\n" .. b.song .. "\n" .. table.concat(peers, " ")
  local now = reaper.time_precise()
  if #peers == 0 then who = key; return 0 end
  local retry = ev_wait ~= nil and now >= ev_wait.next and key == who
  if key == who and math.abs(now - asked_at) < needlist.EVERY and not retry then return 0 end -- (at once when who's here changes)
  if key ~= who then ev_due, ev_wait = true, nil end
  if retry then ev_due = true end
  who, asked_at, round = key, now, round + 1
  local me = require("services").my_device_id()
  if not me then return 0 end
  needlist.mine(cfg, b.song) -- (what's here now is remembered: a file gone from here later was deleted, on_list)
  local sorted = { table.unpack(peers) }
  table.sort(sorted)
  local peer = sorted[round % #sorted + 1] -- (one bandmate a round, each in turn)
  local evs
  if ev_due then
    evs, ev_due, ev_round = {}, false, 0
    local gap = ev_wait and math.min(ev_wait.gap * 2, needlist.EVERY) or needlist.EV_RETRY
    ev_wait = { next = now + gap, gap = gap, tries = (ev_wait and ev_wait.tries or 0) + 1 }
    pcall(require("streams").trace, string.format("event catch-up: ids sent to %s (try %d)", peer, ev_wait.tries))
    for k, room in ipairs(band.subdirs(cfg.root .. "/" .. b.song .. "/rooms")) do
      if k > needlist.EV_ROOMS then break end
      if direct.plain(room) then evs[room] = sums_of(by_day(cfg, b.song, room)) end
    end
  end
  direct.send_live(cfg, "need_ask", { user = cfg.user, dev = me, seen = seen[(dev_of or {})[peer] or ""], evs = evs }, b.song, b.room, nil, { peer })
  return 1
end
-- The peer here whose computer is `dev` (only a computer the link knows and trusts, as lib/streams.lua on_media_want), or nil.
local function peer_of(cfg, b, dev)
  if not require("services").is_device_id(dev) or dev == require("services").my_device_id() then return nil end
  local peers, dev_of = direct.peers(cfg, b.song, b.room)
  for _, p in ipairs(peers) do if (dev_of or {})[p] == dev then return p end end
  return nil
end
-- A "need_list" from a bandmate here: what it holds that isn't here goes into the wants. -> how many were added, or false.
local on_ev_list
function needlist.on_list(cfg, b, d)
  if needlist.on() and type(d) == "table" and type(d.evs) == "table" then return on_ev_list(cfg, b, d) end
  if not needlist.on() or type(d) ~= "table" or type(d.files) ~= "table" or #d.files > needlist.PER_MSG then return false end
  if not peer_of(cfg, b, d.dev) or type(d.digest) ~= "string" or not d.digest:match("^%d+|%d+$") or #d.digest > 40 then return false end
  local part, of = math.tointeger(d.part), math.tointeger(d.of)
  if not (part and of and part >= 1 and part <= of and of <= math.ceil(needlist.MAX / needlist.PER_MSG)) then return false end
  local streams, now, n, count = require("streams"), reaper.time_precise(), 0, 0
  for _ in pairs(needlist.wants) do count = count + 1 end
  for _, e in ipairs(d.files) do
    local room, file, size = type(e) == "table" and e[1], type(e) == "table" and e[2], type(e) == "table" and math.tointeger(e[3])
    if type(room) == "string" and type(file) == "string" and size and size > 0 and size <= 16 * 2 ^ 30 and not file:find("/", 1, true) and streams.media_name(room, file) then
      local key, path = b.song .. "/" .. room .. "/" .. file, cfg.root .. "/" .. b.song .. "/rooms/" .. room .. "/media/" .. file
      -- (not one this computer held since this script started and no longer does: it was deleted, here or by Syncthing carrying someone's
      -- delete, and the bandmate's copy is only still there until Syncthing takes it. Fetched back, the delete would be undone for everyone)
      if count < needlist.MAX and not needlist.wants[key] and not sizes[path] and band.size(path) == nil then
        needlist.wants[key] = { room = room, file = file, size = size, by = d.dev, key = key, at = now, root = cfg.root }
        n, count = n + 1, count + 1
      end
    end
  end
  -- (every part of this list seen: it isn't asked for again until it changes)
  local p = parts[d.dev]
  if not p or p.digest ~= d.digest then p = { digest = d.digest, got = {}, n = 0 }; parts[d.dev] = p end
  if not p.got[part] then p.got[part], p.n = true, p.n + 1 end
  if p.n >= of then seen[d.dev], parts[d.dev] = d.digest, nil end
  return n
end
-- A bandmate's event ids for one room's days that differ from this computer's ({ dev, room, evs = { ids } }): the ones not here are asked
-- for, from that bandmate. -> how many were asked for, or false.
function on_ev_list(cfg, b, d)
  local to, room = peer_of(cfg, b, d.dev), d.room
  if to then ev_wait = nil end -- (answered: an empty list is "every day the same here")
  if not to or #d.evs > needlist.EV_PER_MSG or not direct.plain(room) or #band.subdirs(cfg.root .. "/" .. b.song .. "/rooms/" .. room) == 0 then return false end
  local dir = ev_dir(cfg, b.song, room)
  local idir = direct.inbox_dir(cfg, dir)
  if not idir then return false end
  local gone, sync, now, want = trimmed(cfg, b.song, room), require("sync"), reaper.time_precise(), {}
  for _, id in ipairs(d.evs) do
    local key = b.song .. "/" .. room .. "/" .. tostring(id)
    if ev_day(b.song, room, id) and not gone[id] and not sync.is_mine(id, cfg.user) and not needlist.ev_wanted[key] and ev_round < needlist.EV_MAX
        and not reaper.file_exists(dir .. "/" .. id .. ".json") and not reaper.file_exists(idir .. "/" .. id .. ".json") then
      want[#want + 1], ev_round = id, ev_round + 1
      needlist.ev_wanted[key] = { at = now, path = dir .. "/" .. id .. ".json", inbox = idir .. "/" .. id .. ".json" }
    end
  end
  if #want == 0 then return 0 end
  -- (the link's inbox keeps these a day from now, not from when each was made: they're as old as the change. lib/direct.lua prune, as for
  -- lib/joinboot.lua's welcome)
  reaper.RecursiveCreateDirectory(idir, 0)
  pcall(band.write_atomic, (idir:gsub("/events$", "/.boot")), tostring(os.time()))
  direct.send_live(cfg, "need_ask", { user = cfg.user, dev = require("services").my_device_id(), want = { room = room, ids = want } }, b.song, b.room, nil, { to })
  ev_due = true -- (and the ids once more next round, until a round brings nothing)
  pcall(require("streams").trace, string.format("event catch-up: %d changes in %s asked of %s", #want, room, to))
  return #want
end
-- A bandmate's media is fetched only while the song plays it, and once the changes on their way over the link are here (one of them may be
-- the one that stopped playing it).
local waiting_for, pass_used -- (looked at once a pass: in_use reads for 0.05 s while it isn't through)
local function wanted_now(w, song)
  if waiting_for == nil then waiting_for = ev_waiting(song) end
  if waiting_for or not w.root then return false end
  if pass_used == nil then pass_used = in_use(w.root, song) or false end
  return pass_used and pass_used[w.room] ~= nil and pass_used[w.room][w.file] == true or false
end
-- For streams.catchup_tick: Syncthing's wants (`list`, shared: never changed) with the link's added, smallest first as catchup_wants; `list`
-- itself when the link has none. `here(w)`: the file is in place now (then it's no longer wanted). Wants kept KEEP s at most.
function needlist.pending(list, song, here)
  waiting_for, pass_used = nil, nil
  local now, have, out = reaper.time_precise(), {}, nil
  for key, w in pairs(needlist.wants) do
    if math.abs(now - w.at) > needlist.KEEP then needlist.wants[key], seen[w.by] = nil, nil -- (never fetched: that list is asked for again)
    elseif key:sub(1, #song + 1) == song .. "/" and here(w) then needlist.wants[key] = nil
    elseif key:sub(1, #song + 1) == song .. "/" and wanted_now(w, song) then
      if not out then
        out = {}
        for i, x in ipairs(list) do out[i], have[x.key] = x, true end
      end
      if not have[key] then out[#out + 1] = w end
    end
  end
  if not out then return list end
  table.sort(out, function(a, z) if a.size ~= z.size then return a.size < z.size end return a.key < z.key end)
  return out
end

-- ---- the bandmate asked --------------------------------------------------------------------------------------------------------------------
local answered = {} -- device id -> when
-- A "need_ask": this computer's list goes back to the asker alone, unless it has seen this very list. -> how many messages went.
local ev_served = {} -- device id -> { at, n }: event files sent it in the last minute
-- "want" { room, ids }: those event files, from this computer's folder or the link's inbox, over the link as every new one goes (EV_MAX a
-- minute at most to one asker). -> how many went.
local function serve_events(cfg, b, d, to)
  local w = d.want
  local room = type(w) == "table" and w.room
  if not (direct.plain(room) and type(w.ids) == "table" and #w.ids <= needlist.EV_PER_MSG) then return 0 end
  local now, s = reaper.time_precise(), ev_served[d.dev]
  if not s or math.abs(now - s.at) > 60 then s = { at = now, n = 0 }; ev_served[d.dev] = s end
  local dir, id, n = ev_dir(cfg, b.song, room), band.info(cfg.root).id, 0
  if not (id and reaper.StudioSync_DirectSend and direct.ensure(cfg)) then return 0 end
  for _, e in ipairs(w.ids) do
    if s.n >= needlist.EV_MAX then break end
    local rel = b.song .. "/rooms/" .. room .. "/events/" .. tostring(e) .. ".json"
    local path = direct.rel_ok(rel) and direct.path(cfg, dir, e .. ".json")
    if path and reaper.file_exists(path) and reaper.StudioSync_DirectSend(id, rel, path, to) == 1 then n, s.n = n + 1, s.n + 1 end
  end
  pcall(require("streams").trace, string.format("event catch-up: %d changes in %s sent to %s", n, room, to))
  return n
end
-- "evs" { [room] = { [day] = sum } }: for each day here that differs, this computer's ids of that day go back (EV_MAX in all). -> how many.
local function ev_lists(cfg, b, d, to, me)
  local n, sent = 0, 0
  for room, theirs in pairs(d.evs) do
    n = n + 1
    if n > needlist.EV_ROOMS or sent >= needlist.EV_MAX then break end
    if direct.plain(room) and type(theirs) == "table" and #band.subdirs(cfg.root .. "/" .. b.song .. "/rooms/" .. room) > 0 then
      local days = by_day(cfg, b.song, room)
      local sums, ids = sums_of(days), {}
      for day, list in pairs(days) do
        if theirs[day] ~= sums[day] then for _, id in ipairs(list) do if sent + #ids < needlist.EV_MAX then ids[#ids + 1] = id end end end
      end
      table.sort(ids)
      for k = 1, #ids, needlist.EV_PER_MSG do
        direct.send_live(cfg, "need_list", { dev = me, room = room, evs = { table.unpack(ids, k, math.min(k + needlist.EV_PER_MSG - 1, #ids)) } }, b.song, b.room, nil, { to })
      end
      sent = sent + #ids
    end
  end
  -- (nothing differs: an empty list says so, and the asker stops asking. An older asker refuses it: no room)
  if sent == 0 then direct.send_live(cfg, "need_list", { dev = me, evs = {} }, b.song, b.room, nil, { to }) end
  return sent
end
function needlist.on_ask(cfg, b, d)
  if not needlist.on() or type(d) ~= "table" then return 0 end
  local to = peer_of(cfg, b, d.dev)
  if to and d.want ~= nil then return serve_events(cfg, b, d, to) end
  if not to and type(d.evs) == "table" then pcall(require("streams").trace, "event catch-up: an ask from " .. (tostring(d.user):gsub("%c", ""):sub(1, 40)) .. "'s computer dropped: not here for this one yet") end
  local now = reaper.time_precise()
  if not to or math.abs(now - (answered[d.dev] or -math.huge)) < needlist.ANSWER_EVERY then return 0 end
  answered[d.dev] = now
  local me = require("services").my_device_id()
  if type(d.evs) == "table" then ev_lists(cfg, b, d, to, me) end
  local list, digest = needlist.mine(cfg, b.song)
  if d.seen == digest then return 0 end
  local of = math.max(1, math.ceil(#list / needlist.PER_MSG))
  for part = 1, of do
    local files = {}
    for k = (part - 1) * needlist.PER_MSG + 1, math.min(part * needlist.PER_MSG, #list) do files[#files + 1] = list[k] end
    direct.send_live(cfg, "need_list", { dev = me, digest = digest, part = part, of = of, files = files }, b.song, b.room, nil, { to })
  end
  return of
end

return needlist
