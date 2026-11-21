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
-- Off unless this computer's ExtState "link need list" is "1": a bandmate's folder is a weaker judge of what's missing than Syncthing. A
-- file deleted while this script wasn't running, that the bandmate still holds because Syncthing hasn't taken it there yet, would be
-- fetched back and the delete undone for everyone. So it waits for a test on real computers.
-- Events are not traded here: they still come by Syncthing when a computer was away (rt-linkmove.md, "not done").
-- Unreviewed (security reviews come after all features, James 2026-11-19).
local band = require("band")
local direct = require("direct")
local needlist = { EVERY = 30, SETTLE = 30, PER_MSG = 300, MAX = 6000, ANSWER_EVERY = 10, KEEP = 3600, EXT = "link need list" }

function needlist.on() return reaper.GetExtState(band.SECTION, needlist.EXT) == "1" end

-- This computer's media in the song's rooms that the link could carry: { { room, file, size } } in name order, and its digest. Only files
-- last written SETTLE s ago or more (one still being recorded or copied in isn't whole), each measured once (media is written once, under a
-- name of its own).
local sizes = {}
function needlist.mine(cfg, song)
  local out, bytes = {}, 0
  local rooms, time_of = cfg.root .. "/" .. song .. "/rooms", reaper.StudioSync_DirectFileTime
  local streams = require("streams")
  for _, room in ipairs(band.subdirs(rooms)) do
    local dir = rooms .. "/" .. room .. "/media"
    for _, f in ipairs(band.files(dir)) do
      if #out >= needlist.MAX then break end
      local path = dir .. "/" .. f
      local size = sizes[path]
      if not size and time_of and streams.media_name(room, f) then
        local t = tonumber(time_of(path)) or -1
        size = t >= 0 and os.time() - t >= needlist.SETTLE and band.size(path) or nil
        if size and size > 0 then sizes[path] = size else size = nil end
      end
      if size then out[#out + 1], bytes = { room, f, size }, bytes + size end
    end
  end
  return out, #out .. "|" .. string.format("%d", bytes)
end

-- ---- the asker ----------------------------------------------------------------------------------------------------------------------------
needlist.wants = {} -- song/room/file -> { room, file, size, by (the lister's device id), key, at }
local seen, parts = {}, {} -- device id -> the digest of its list this computer has been through; -> { digest, n }
local asked_at, who, round = -math.huge, nil, 0
-- Live sync's tick. -> 1 when it asked.
function needlist.tick(cfg, b)
  if not needlist.on() or not direct.live_available() then return 0 end
  local peers, dev_of = direct.peers(cfg, b.song, b.room)
  local key = cfg.root .. "\n" .. b.song .. "\n" .. table.concat(peers, " ")
  local now = reaper.time_precise()
  if #peers == 0 then who = key; return 0 end
  if key == who and math.abs(now - asked_at) < needlist.EVERY then return 0 end -- (at once when who's here changes)
  who, asked_at, round = key, now, round + 1
  local me = require("services").my_device_id()
  if not me then return 0 end
  needlist.mine(cfg, b.song) -- (what's here now is remembered: a file gone from here later was deleted, on_list)
  local sorted = { table.unpack(peers) }
  table.sort(sorted)
  local peer = sorted[round % #sorted + 1] -- (one bandmate a round, each in turn)
  direct.send_live(cfg, "need_ask", { user = cfg.user, dev = me, seen = seen[(dev_of or {})[peer] or ""] }, b.song, b.room, nil, { peer })
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
function needlist.on_list(cfg, b, d)
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
        needlist.wants[key] = { room = room, file = file, size = size, by = d.dev, key = key, at = now }
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
-- For streams.catchup_tick: Syncthing's wants (`list`, shared: never changed) with the link's added, smallest first as catchup_wants; `list`
-- itself when the link has none. `here(w)`: the file is in place now (then it's no longer wanted). Wants kept KEEP s at most.
function needlist.pending(list, song, here)
  local now, have, out = reaper.time_precise(), {}, nil
  for key, w in pairs(needlist.wants) do
    if math.abs(now - w.at) > needlist.KEEP then needlist.wants[key], seen[w.by] = nil, nil -- (never fetched: that list is asked for again)
    elseif key:sub(1, #song + 1) == song .. "/" and here(w) then needlist.wants[key] = nil
    elseif key:sub(1, #song + 1) == song .. "/" then
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
function needlist.on_ask(cfg, b, d)
  if not needlist.on() or type(d) ~= "table" then return 0 end
  local to = peer_of(cfg, b, d.dev)
  local now = reaper.time_precise()
  if not to or math.abs(now - (answered[d.dev] or -math.huge)) < needlist.ANSWER_EVERY then return 0 end
  local list, digest = needlist.mine(cfg, b.song)
  if d.seen == digest then return 0 end
  answered[d.dev] = now
  local me, of = require("services").my_device_id(), math.max(1, math.ceil(#list / needlist.PER_MSG))
  for part = 1, of do
    local files = {}
    for k = (part - 1) * needlist.PER_MSG + 1, math.min(part * needlist.PER_MSG, #list) do files[#files + 1] = list[k] end
    direct.send_live(cfg, "need_list", { dev = me, digest = digest, part = part, of = of, files = files }, b.song, b.room, nil, { to })
  end
  return of
end

return needlist
