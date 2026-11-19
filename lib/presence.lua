-- Who's doing what, at the speed the shared folder carries it (a few seconds): edit holds, following someone's view,
-- and pings. Each machine puts its part in its status file (rooms/<room>/status/<user>.json); Live sync reads the
-- others'.
--   Holds: what someone changed in the last HOLD seconds is theirs for that long. Your own change to it is put back
--     with "<name> is editing that right now" (two people working one item at once was a tug of war).
--   Follow: Who's here can follow a bandmate's view (the arrange view goes where theirs is).
--   Ping: the radial menu's "Ping here" puts a marker at a spot on everyone's timeline for a while.
local band = require("band")
local presence = {}
presence.HOLD = 15       -- seconds a changed object stays held by whoever changed it
presence.PING_SHOWN = 30 -- seconds a ping's marker stays
presence.MARK = "[ping] " -- a ping's marker name starts so (never part of the band's markers: band.is_local_mark)

-- ---- this machine's part --------------------------------------------------------------------------
local touched = {} -- proj -> { oid -> os.time() of our last change }
function presence.touch(proj, oid)
  local k = tostring(proj)
  touched[k] = touched[k] or {}
  touched[k][oid] = os.time()
end
-- The oids we changed within HOLD seconds, sorted (for the status file: it's rewritten when this changes).
function presence.editing(proj)
  local out, now = {}, os.time()
  for oid, t in pairs(touched[tostring(proj)] or {}) do if now - t < presence.HOLD then out[#out + 1] = oid end end
  table.sort(out)
  return out
end
-- The arrange view, rounded (so the status file isn't rewritten for a pixel's scroll).
function presence.view(proj)
  local a, z = reaper.GetSet_ArrangeView2(proj, false, 0, 0, 0, 0)
  return { math.floor(a * 2 + 0.5) / 2, math.floor(z * 2 + 0.5) / 2 }
end
-- A ping from here: the spot and when (ExtState, so the radial menu can set it; Live sync puts it in the status).
function presence.ping_here(proj, pos)
  reaper.SetExtState(band.SECTION, "ping " .. tostring(proj), string.format("%.3f %s", pos, os.date("!%Y-%m-%dT%H:%M:%SZ")), false)
  -- (the marker is for the others, so this is the pinger's only sign it went: laptop, 2026-10-31)
  band.log(string.format("pinged %.2f s: everyone in the room sees a marker with your name there for %d seconds", pos, presence.PING_SHOWN))
end
function presence.my_ping(proj)
  local pos, at = reaper.GetExtState(band.SECTION, "ping " .. tostring(proj)):match("^(%S+) (%S+)$")
  return pos and { pos = tonumber(pos), at = at } or nil
end

-- ---- the others' ----------------------------------------------------------------------------------
local peers_at, peers, everyone = {}, {}, {} -- (everyone: every bandmate's status file as read, fresh or not: presence.all)
-- Bandmates' fresh status files (seen in the last 45 s), read at most once a second per room.
-- Clocks (review, 0.58.89): a status file carries its writer's own clock. Each one that changes is a few seconds old when it arrives, so a
-- bigger gap, either way, is a clock that's off: theirs or this computer's. One behind by more than 45 s read as gone, though here.
presence.skew = {} -- user -> seconds their clock is behind ours (negative: ahead), only while it's more than presence.SKEW
presence.SKEW = 90
local last_time = {} -- user -> { time = their last status time, at = when it changed here }
function presence.clock_gap(age, changed_ago) -- (pure: how far off a clock is, given a just-changed stamp's age; nil when within reason)
  if changed_ago > 10 then return nil end
  local gap = age - changed_ago
  return math.abs(gap) > presence.SKEW and gap or nil
end
-- Statuses that came over the direct link (lib/direct.lua; James, 0.60.0-rt): seen at once, not when Syncthing brings the file, and used while
-- newer than it. A heartbeat moves a known status's time on. The file stays the record (and what the panel, which polls no messages, reads).
local live_st = {} -- song/room -> user -> status
function presence.from_msg(cfg, song, room, st, kind)
  if type(st) ~= "table" or type(st.user) ~= "string" or st.user == cfg.user or type(st.time) ~= "string" or (st.room ~= nil and st.room ~= room) then return false end
  local key = song .. "/" .. room
  live_st[key] = live_st[key] or {}
  local had = live_st[key][st.user]
  if kind == "heartbeat" then
    if not had then for _, s in ipairs(everyone[key] or {}) do if s.user == st.user then had = s end end end
    if not had or had.time >= st.time then return false end
    local copy = {}
    for k, v in pairs(had) do copy[k] = v end
    copy.time, st = st.time, copy
  elseif had and had.time > st.time then return false end
  live_st[key][st.user] = st
  peers_at[key] = nil -- (read again at the next ask)
  return true
end
-- Pure: the status files' statuses with each person's newer live one in its place (or added). -> a new list.
function presence.with_live(sts, live)
  local out, at = {}, {}
  for _, st in ipairs(sts) do out[#out + 1] = st; at[st.user] = #out end
  for user, l in pairs(live or {}) do
    local i = at[user]
    if not i then out[#out + 1] = l elseif l.time > out[i].time then out[i] = l end
  end
  return out
end
function presence.peers(cfg, song, room)
  local key = song .. "/" .. room
  if peers_at[key] and reaper.time_precise() - peers_at[key] < 1 then return peers[key] end
  local dir, out, all = require("sync").room_dir(cfg, song, room) .. "/status", {}, {}
  local now = reaper.time_precise()
  local sts = {}
  for _, f in ipairs(band.files(dir, ".json")) do
    local st = band.read_json(dir .. "/" .. f)
    if type(st) == "table" and type(st.user) == "string" and st.user ~= cfg.user and type(st.time) == "string" then sts[#sts + 1] = st end
  end
  for _, st in ipairs(presence.with_live(sts, live_st[key])) do
    all[#all + 1] = st
    local l = last_time[st.user]
    if not l or l.time ~= st.time then l = { time = st.time, at = l and now or -math.huge }; last_time[st.user] = l end
    local age = band.age(st.time)
    local gap = presence.clock_gap(age, now - l.at)
    if now - l.at <= 10 then presence.skew[st.user] = gap end -- (known only from a fresh change: kept between them)
    if age < 45 or gap or now - l.at < 45 then out[#out + 1] = st end -- (still writing, whatever their clock says)
  end
  peers_at[key], peers[key], everyone[key] = reaper.time_precise(), out, all
  return out
end
-- Who's here within `within` seconds, by peers' rule: their own stamp says so, or their file changed here that recently, whatever their clock
-- says. (Who's alone was decided on the stamp alone: a bandmate whose clock ran 90 s behind read as gone, and you got full control over their
-- claims. Full review, 0.59.44.) -> their names, sorted.
function presence.here(cfg, song, room, within)
  presence.peers(cfg, song, room)
  local now, out = reaper.time_precise(), {}
  for _, st in ipairs(everyone[song .. "/" .. room] or {}) do
    local l = last_time[st.user]
    if band.age(st.time) < within or (l and now - l.at < within) then out[#out + 1] = st.user end
  end
  table.sort(out)
  return out
end
-- Every bandmate's status file, however old, from the same read as presence.peers (at most a second old). Shared: never change them.
-- (0.59.14, review: sync.present read every status file again each poll, right beside presence.peers.)
function presence.all(cfg, song, room)
  presence.peers(cfg, song, room)
  return everyone[song .. "/" .. room]
end
-- Who else is editing this object right now (nil when nobody is). Pure apart from the peers list.
-- Track groups that tie together tracks made by different people (review, 0.58.89): a group number travels as it is, so two people who
-- each made "group 5" apart tie each other's tracks together. `tracks`: { { maker, low, high } } with each track's group bits. Pure.
function presence.group_clashes(tracks)
  local makers = {} -- group number -> { maker = true }
  for _, t in ipairs(tracks) do
    for half, bits in ipairs({ t[2] or 0, t[3] or 0 }) do
      for b = 0, 31 do
        if bits & (1 << b) ~= 0 then
          local n = (half - 1) * 32 + b + 1
          makers[n] = makers[n] or {}
          makers[n][t[1]] = true
        end
      end
    end
  end
  local out = {}
  for n, who in pairs(makers) do
    local list = {}
    for u in pairs(who) do list[#list + 1] = u end
    if #list > 1 then table.sort(list); out[#out + 1] = { group = n, makers = list } end
  end
  table.sort(out, function(a, b) return a.group < b.group end)
  return out
end
local GROUP_PARAMS = { "VOLUME_LEAD", "VOLUME_FOLLOW", "PAN_LEAD", "PAN_FOLLOW", "MUTE_LEAD", "MUTE_FOLLOW", "SOLO_LEAD", "SOLO_FOLLOW",
  "RECARM_LEAD", "RECARM_FOLLOW", "VOLUME_VCA_LEAD", "VOLUME_VCA_FOLLOW", "SELECTED_LEAD", "SELECTED_FOLLOW" }
function presence.track_groups(proj)
  local tracks = {}
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    local oid = select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_oid", "", false))
    local maker = oid:match("^(.-)%-%d%d%d%d%d%d%d%d%-")
    if maker then
      local lo, hi = 0, 0
      for _, p in ipairs(GROUP_PARAMS) do
        lo = lo | math.floor(reaper.GetSetTrackGroupMembership(tr, p, 0, 0))
        if reaper.GetSetTrackGroupMembershipHigh then hi = hi | math.floor(reaper.GetSetTrackGroupMembershipHigh(tr, p, 0, 0)) end
      end
      if lo ~= 0 or hi ~= 0 then tracks[#tracks + 1] = { maker:lower(), lo & 0xFFFFFFFF, hi & 0xFFFFFFFF } end
    end
  end
  return presence.group_clashes(tracks)
end

function presence.holder(list, oid)
  for _, st in ipairs(list) do
    for _, o in ipairs(type(st.editing) == "table" and st.editing or {}) do if o == oid then return st.user end end
  end
end

-- Follow: this machine's arrange view goes where `name`'s is (when it's more than a little off).
local followed_cursor = {} -- proj .. name -> where their cursor last was: only when it moves does yours (you can still put yours elsewhere meanwhile)
function presence.follow(proj, list, name)
  for _, st in ipairs(list) do
    if st.user == name and type(st.view) == "table" and tonumber(st.view[1]) and tonumber(st.view[2]) then
      local a, z = reaper.GetSet_ArrangeView2(proj, false, 0, 0, 0, 0)
      if math.abs(a - st.view[1]) > 0.5 or math.abs(z - st.view[2]) > 0.5 then
        reaper.GetSet_ArrangeView2(proj, true, 0, 0, st.view[1], st.view[2])
      end
    end
    if st.user == name then
      -- stopped, your cursor goes where theirs is: after a stop, and when they jump somewhere (Mac, 0.50.4: it stayed at your own catch-up start, and a jump never came)
      local key, cur = tostring(proj) .. name, tonumber(st.cursor)
      -- (their status has no cursor while they play, so every stop counts as a move, even back to where their cursor already was: Mac, 0.51.13)
      if not cur then followed_cursor[key] = nil
      elseif reaper.GetPlayStateEx(proj) == 0 and followed_cursor[key] ~= cur then
        reaper.SetEditCurPos2(proj, cur, false, false)
        followed_cursor[key] = cur
      end
      return
    end
  end
end

-- Following someone takes on their mix too (James, 0.58.82: "following someone should probably also adopt their mix including what they have
-- muted or soloed"). Whoever is followed puts their faders, pan and solos in their status (presence.my_mix); the follower's tracks take them, with
-- Control your own mix on meanwhile so none of it goes out, and get their own back when they stop following. Mutes are the studio's, the same
-- for everyone already. What's saved to come back to: the project's "follow mix saved" ({ local_mix, tracks = { oid = { v, p, s } } }).
local function round(x, n) local m = 10 ^ n; return math.floor(x * m + 0.5) / m end
-- This computer's mix, by track: { oid = { v, p, s } }. Only tracks the studio has (not local ones).
function presence.my_mix(proj)
  local mirror, out = require("mirror"), {}
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    local oid = mirror.track_oid(tr)
    if oid ~= "" and not mirror.local_track(tr) then
      out[oid] = { v = round(reaper.GetMediaTrackInfo_Value(tr, "D_VOL"), 4), p = round(reaper.GetMediaTrackInfo_Value(tr, "D_PAN"), 3),
        s = math.floor(reaper.GetMediaTrackInfo_Value(tr, "I_SOLO")) }
    end
  end
  return out
end
-- Is anyone following `me` (by name, or Always follow the driver while I drive)? Pure over the peers list.
function presence.followed(list, me, driver)
  for _, st in ipairs(list) do
    if st.follow == me or (st.follow_driver and driver == me and st.user ~= me) then return true end
  end
  return false
end
-- Which track values differ between a mix and what `want` says: { { oid, key, value } }. Pure.
function presence.mix_changes(have, want)
  local out = {}
  for oid, w in pairs(want or {}) do
    local h = have[oid]
    if h and type(w) == "table" then
      if tonumber(w.v) and math.abs(h.v - w.v) > 1e-4 then out[#out + 1] = { oid, "D_VOL", w.v } end
      if tonumber(w.p) and math.abs(h.p - w.p) > 1e-3 then out[#out + 1] = { oid, "D_PAN", w.p } end
      if tonumber(w.s) and h.s ~= w.s then out[#out + 1] = { oid, "I_SOLO", w.s } end
    end
  end
  table.sort(out, function(a, b) return a[1] .. a[2] < b[1] .. b[2] end)
  return out
end
local function set_mix(proj, list)
  local mirror = require("mirror")
  for _, c in ipairs(list) do
    local tr = mirror.find(proj, "track", c[1])
    if tr then reaper.SetMediaTrackInfo_Value(tr, c[2], c[3]) end
  end
end
-- Each Live sync pass: `name` is who this computer follows ("" for nobody). `ctx`: { cfg, song, room } for giving the studio's mix back.
function presence.follow_mix(proj, list, name, ctx)
  local saved = band.json_decode(select(2, reaper.GetProjExtState(proj, band.SECTION, "follow mix saved")))
  local st
  for _, s in ipairs(list) do if s.user == name then st = s end end
  if name == "" then
    if type(saved) ~= "table" then return end
    reaper.SetProjExtState(proj, band.SECTION, "follow mix saved", "")
    set_mix(proj, presence.mix_changes(presence.my_mix(proj), saved.tracks))
    if saved.local_mix ~= "1" then
      reaper.SetProjExtState(proj, band.SECTION, "local_mix", "")
      require("mirror").end_local_mix(proj, ctx.cfg, ctx.song, ctx.room, true) -- (the studio's faders and pan, as before you followed)
    end
    band.log("stopped following: your own mix is back")
    return
  end
  if not (st and type(st.mix) == "table") then return end -- (not here, or older StudioSync: yours stays as it is)
  local have = presence.my_mix(proj)
  if type(saved) ~= "table" then
    local lm = select(2, reaper.GetProjExtState(proj, band.SECTION, "local_mix"))
    reaper.SetProjExtState(proj, band.SECTION, "follow mix saved", band.json_encode({ local_mix = lm, tracks = have }))
    if lm ~= "1" then reaper.SetProjExtState(proj, band.SECTION, "local_mix", "1"); require("mirror").begin_local_mix(proj) end
    band.log("following " .. name .. ": you hear their mix (faders, pan, solos) until you stop following")
  end
  set_mix(proj, presence.mix_changes(have, st.mix))
end

-- Pings: a bandmate's new ping shows as a marker here (and a line in the Activity list) for PING_SHOWN seconds.
local shown = {} -- proj .. user -> the ping's time, once shown
function presence.pings(proj, list)
  for _, st in ipairs(list) do
    local p = type(st.ping) == "table" and st.ping
    local key = tostring(proj) .. st.user
    if p and tonumber(p.pos) and type(p.at) == "string" and band.age(p.at) < presence.PING_SHOWN and shown[key] ~= p.at then
      shown[key] = p.at
      reaper.AddProjectMarker2(proj, false, p.pos, 0, presence.MARK .. st.user, -1, reaper.ColorToNative(255, 170, 0) | 0x1000000)
      band.log(string.format("%s pinged a spot at %.2f s: their marker shows there for %d seconds", st.user, p.pos, presence.PING_SHOWN))
    end
  end
  -- old pings go
  for i = reaper.CountProjectMarkers(proj) - 1, 0, -1 do
    local _, rgn, pos, _, name = reaper.EnumProjectMarkers3(proj, i)
    local who = not rgn and name:sub(1, #presence.MARK) == presence.MARK and name:sub(#presence.MARK + 1)
    if who then
      local still = false
      for _, st in ipairs(list) do
        if st.user == who and type(st.ping) == "table" and tonumber(st.ping.pos) and math.abs(st.ping.pos - pos) < 1e-3
            and band.age(st.ping.at or "") < presence.PING_SHOWN then still = true end
      end
      if not still then reaper.DeleteProjectMarkerByIndex(proj, i) end
    end
  end
end

return presence
