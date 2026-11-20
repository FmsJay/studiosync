-- The first copy of the studio over the direct link, for a computer an invitation just let in (docs/realtime-roadmap.md "More big ideas" 6,
-- docs/rt/rt-joinlink.md). Once the computer that made the invitation lets the joiner in (lib/joins.lua: the owner's or an admin's, the
-- one-time token, every check there), it sends, to the joiner's Tailscale name only, on the invitation's own channel (keyed with the token's
-- signature):
--  - the welcome, sealed to the joiner's static key from its ask (StudioSync_Seal: X25519 + XChaCha20-Poly1305, extension/nat.cpp): the
--    studio's _band essentials as signed files (band.json, which holds the studio's secret, roles, removal marks, names, devices, guest
--    lists), the current song's session.json and its main room's settings (mode, driver, grants), and what follows;
--  - the song's main room as it stands: the newest change of each object (every change of one two people edited apart, so the joiner's
--    merge comes out as everyone's), the newest tempo map, every other kind of event but cues, as event files into the joiner's link inbox
--    (where Live sync reads the link's events);
--  - the media those changes play, streamed, smallest first.
-- On the joiner nothing is written into the shared folder but the media (as the link's media always is): the files land in a store beside
-- the inbox (<home>/direct/<studio>/.boot) and band.read reads them where the folder has none yet (band.boot_copy), so the studio stops
-- "waiting", its song is on the Projects page and opens with the studio's secret, roles and room settings. Syncthing pairs in the background
-- as before (tools.let_in shared the folder); each file it brings is the record from then on and its boot copy goes.
-- Without the extension's sealing (older than this), a key in the ask, or the link: today's welcome, and Syncthing brings everything.
-- Unreviewed (security reviews come after all features, James 2026-11-19). Review-later list: docs/rt/rt-joinlink.md.
local band = require("band")
local jb = { WELCOME_MAX = 30000, BODY_MAX = 32768, SIDE_MAX = 2048, EVENTS_PER_TICK = 500, MEDIA_AT_ONCE = 6, MEDIA_MAX = 300,
  KEEP = 2 * 86400, GRACE = 600, EVENT_MAX = 4 * 1024 * 1024 }
local EXT = "join boots" -- { [root] = { id = studio id, at = os.time() of the welcome, band_at = when the folder's band.json first showed } }

-- ---- pure -------------------------------------------------------------------------------------------------------------------------------
-- The files a welcome may carry, by their path in the studio (a sidecar <file>.sig of one too). -> true or false.
local ALLOWED = { "^_band/band%.json$", "^_band/roles%.json$", "^_band/names%.json$", "^_band/removed/[^/]+%.json$", "^_band/devices/[^/]+%.json$",
  "^_band/guest%-access/[^/]+%.json$", "^[^/]+/session%.json$", "^[^/]+/rooms/[^/]+/mode%.json$", "^[^/]+/rooms/[^/]+/driver%.json$",
  "^[^/]+/rooms/[^/]+/room%.json$", "^[^/]+/rooms/[^/]+/grants/[^/]+%.json$" }
function jb.rel_ok(rel)
  if type(rel) ~= "string" then return false end
  local base = rel:gsub("%.sig$", "")
  if not require("signedwrites").rel_ok(base) or rel:find("[%c\\:]") or rel:find("/%.") or rel:find("^%.") then return false end
  for _, p in ipairs(ALLOWED) do if base:find(p) then return true end end
  return false
end
local function parents_of(id, byid)
  local w, l = require("mirror").split_merge(id)
  if w then return { w, l } end
  local ev = byid[id]
  return ev and { ev.base_ev } or {}
end
-- A room's events -> what a new computer needs to end where everyone is: for each object its newest change (mirror.newer), or every change
-- of it when one wasn't built on by the newest (two people's edits made apart, a deletion racing an edit: the joiner's receive then merges
-- them as everyone's did); the newest tempo map; every other event but cues (start, stop), which only matter as they happen. Sorted as
-- receive applies them. Pure but for mirror's ordering.
function jb.compact(evs)
  local mirror = require("mirror")
  local by_oid, out, timeline = {}, {}, nil
  for _, ev in ipairs(evs) do
    if type(ev) == "table" and type(ev.id) == "string" then
      if ev.type == "obj" and type(ev.oid) == "string" then
        local t = by_oid[ev.oid] or {}
        by_oid[ev.oid] = t
        t[#t + 1] = ev
      elseif ev.type == "timeline" then
        local o = ev.order or ((ev.time or "") .. ev.id)
        if not timeline or o > timeline[2] then timeline = { ev, o } end
      elseif ev.type ~= "start" and ev.type ~= "stop" then out[#out + 1] = ev end
    end
  end
  if timeline then out[#out + 1] = timeline[1] end
  for _, list in pairs(by_oid) do
    local top
    for _, ev in ipairs(list) do
      if not top or mirror.newer({ rev = ev.rev, time = mirror.order_of(ev), user = ev.user }, { rev = top.rev, time = mirror.order_of(top), user = top.user }) then top = ev end
    end
    local byid, behind, todo, steps = {}, {}, { top.id }, 0
    for _, ev in ipairs(list) do byid[ev.id] = ev end
    while #todo > 0 and steps < 5000 do
      steps = steps + 1
      for _, pid in ipairs(parents_of(table.remove(todo), byid)) do
        if type(pid) == "string" and not behind[pid] then behind[pid] = true; todo[#todo + 1] = pid end
      end
    end
    local rival = steps >= 5000 -- (a walk too long to finish: everything, to be safe)
    for _, ev in ipairs(list) do if ev ~= top and not behind[ev.id] then rival = true end end
    if rival then for _, ev in ipairs(list) do out[#out + 1] = ev end else out[#out + 1] = top end
  end
  table.sort(out, function(a, z) return (a.time or "") .. a.id < (z.time or "") .. z.id end)
  return out
end
-- The studio media the kept changes play ({media:<room>}/<file>, {media}/<file> being `room`'s own): { { room, file } }, once each, never
-- a path out of a room's media folder. Pure.
function jb.media_of(evs, room)
  local out, seen = {}, {}
  local function add(r, f)
    if f:find("%.%.") or f:find("^[/\\]") or f:find("^%a:") or f:find("\\", 1, true) then return end
    local k = r .. "/" .. f
    if not seen[k] then seen[k] = true; out[#out + 1] = { room = r, file = f } end
  end
  for _, ev in ipairs(evs) do
    if ev.type == "obj" and not ev.gone and type(ev.state) == "string" then
      for r, f in ev.state:gmatch('FILE "{media:([^}]+)}/([^"]+)"') do add(r, f) end
      for f in ev.state:gmatch('FILE "{media}/([^"]+)"') do add(room, f) end
    end
  end
  return out
end

-- ---- the computer that made the invitation ---------------------------------------------------------------------------------------------
-- The files to carry, most needed first (whatever doesn't fit in the welcome comes with Syncthing): { rel }.
function jb.files_for(root, song, room)
  local rels = { "_band/band.json", "_band/roles.json" }
  if song then
    local rdir = song .. "/rooms/" .. room
    rels[#rels + 1] = song .. "/session.json"
    for _, f in ipairs({ "mode.json", "driver.json", "room.json" }) do rels[#rels + 1] = rdir .. "/" .. f end
    for _, f in ipairs(band.files(root .. "/" .. rdir .. "/grants", ".json")) do rels[#rels + 1] = rdir .. "/grants/" .. f end
  end
  for _, f in ipairs(band.files(root .. "/_band/removed", ".json")) do rels[#rels + 1] = "_band/removed/" .. f end
  rels[#rels + 1] = "_band/names.json"
  for _, f in ipairs(band.files(root .. "/_band/devices", ".json")) do rels[#rels + 1] = "_band/devices/" .. f end
  for _, f in ipairs(band.files(root .. "/_band/guest-access", ".json")) do rels[#rels + 1] = "_band/guest-access/" .. f end
  return rels
end
-- The song to hand over: the one in front here (when it's this studio's and the joiner may see it), else the newest the joiner may see.
function jb.song_for(root, device)
  local access = require("access")
  local shown = access.read(root, device)
  local okb, b = pcall(band.binding, reaper.EnumProjects(-1))
  if okb and b and b.song and band.same_studio(b.root, root) and access.shows(shown, b.song) and reaper.file_exists(root .. "/" .. b.song .. "/session.json") then
    return b.song
  end
  for _, s in ipairs(band.songs({ root = root })) do if access.shows(shown, s) then return s end end
end
-- The room's events, read from the folder and the link's inbox, kept as jb.compact says. -> { { ev, path } }.
function jb.events_for(root, song, room)
  local dir = root .. "/" .. song .. "/rooms/" .. room .. "/events"
  local names, from = require("direct").listing({ root = root }, dir)
  local evs, path_of = {}, {}
  for _, f in ipairs(names) do
    local p = from and from[f] or (dir .. "/" .. f)
    local ev = band.read_json(p)
    if type(ev) == "table" and ev.id == f:sub(1, -6) and (band.size(p) or 0) <= jb.EVENT_MAX then evs[#evs + 1] = ev; path_of[ev] = p end
  end
  local out = {}
  for _, ev in ipairs(jb.compact(evs)) do out[#out + 1] = { ev = ev, path = path_of[ev] } end
  return out
end

local prepared = {} -- token id -> { song, evs, media }
local jobs = {} -- token id -> what's still to send: { root, channel, peer, device, made, events, media, ei, mi, at }
jb.jobs = jobs
-- The welcome and the rest for a joiner just let in (or the same computer asking again: the welcome only, unless nothing went yet).
-- tok: the parsed token; r: the checked ask, its key (the joiner's static key, 64 hex) and reply (its Tailscale name) the ones bound at
-- first use; rec: the invitation's record. -> true when the sealed welcome went (else the caller sends today's).
function jb.send(root, tok, r, rec, now)
  if not (reaper.StudioSync_Seal and reaper.StudioSync_DirectStart and reaper.StudioSync_DirectMsg and type(r.key) == "string"
    and #r.key == 64 and r.key:match("^%x+$") and r.reply) then return false end
  local t = require("groups").tailnet(root)
  if not (t and r.reply:sub(-#t.suffix - 1) == "." .. t.suffix:lower()) then return false end
  local k = "join welcomed " .. tok.id
  if now - (tonumber(reaper.GetExtState(band.SECTION, k)) or -math.huge) < 5 then return true end -- (two scripts reading the same ask)
  -- (what goes is worked out once per invitation: an ask again, every RESEND s while the welcome is missed, reads no events)
  local prep = prepared[tok.id]
  if not prep then
    prep = { song = jb.song_for(root, r.device), evs = {}, media = {} }
    if prep.song then
      prep.evs = jb.events_for(root, prep.song, "main")
      local plain = {}
      for _, e in ipairs(prep.evs) do plain[#plain + 1] = e.ev end
      for _, m in ipairs(jb.media_of(plain, "main")) do
        local name = require("streams").media_name(m.room, m.file)
        local p = root .. "/" .. prep.song .. "/rooms/" .. m.room .. "/media/" .. m.file
        local size = name and band.size(p)
        if size and size > 0 and #prep.media < jb.MEDIA_MAX then prep.media[#prep.media + 1] = { room = m.room, file = m.file, size = size, name = name, path = p } end
      end
      table.sort(prep.media, function(a, z) if a.size ~= z.size then return a.size < z.size end return a.name < z.name end)
    end
    prepared[tok.id] = prep
  end
  local song, evs, media = prep.song, prep.evs, prep.media
  local access = require("access")
  local shown, songs = access.read(root, r.device), {}
  for _, s in ipairs(band.songs({ root = root })) do if #songs < 200 and access.shows(shown, s) then songs[#songs + 1] = s end end
  local j = band.read_json(root .. "/_band/band.json") or {}
  local w = { studio = tok.studio, id = tok.id, nonce = r.nonce, device = r.device, name = band.info(root).name, owner = j.owner, admins = j.admins,
    role = tok.role, songs = songs, song = song, room = "main", files = {}, at = now }
  -- (the keys this computer knows its bandmates' computers by: the joiner checks each file's signature with them, and believes no copy of
  -- the welcome's by Syncthing's silence. lib/signed.lua)
  local okk, keys = pcall(function() return require("signed").known_keys(root) end)
  w.keys = okk and keys or {}
  w.events = #evs
  w.media = {}
  for _, m in ipairs(media) do w.media[#w.media + 1] = { room = m.room, file = m.file, size = m.size } end
  local size = #band.json_encode(w)
  for _, rel in ipairs(jb.files_for(root, song, "main")) do
    local body = band.read_raw(root .. "/" .. rel)
    local needed = rel == "_band/band.json" or rel == tostring(song) .. "/session.json"
    if body and #body <= jb.BODY_MAX then
      local side = band.read_raw(root .. "/" .. rel .. ".sig")
      local f = { rel = rel, body = body, side = side and #side <= jb.SIDE_MAX and side or nil }
      local n = #band.json_encode(f) + 1
      if size + n <= jb.WELCOME_MAX then w.files[#w.files + 1] = f; size = size + n
      elseif needed then return false end -- (band.json and the song's session.json, or no first copy: Syncthing's as today)
    elseif needed then return false end
  end
  local sealed = tostring(reaper.StudioSync_Seal(r.key, band.json_encode(w)) or "")
  if sealed:sub(1, 4) ~= "SSS1" then return false end
  local channel, peer = "join-" .. tok.id, r.reply .. ":" .. require("direct").port()
  reaper.StudioSync_DirectStart(channel, tok.sig, band.home() .. "/direct/join", -1)
  if reaper.StudioSync_DirectMsg(channel, "welcome", band.json_encode({ sealed = sealed }), peer) ~= 1 then return false end
  reaper.SetExtState(band.SECTION, k, tostring(now), false)
  -- (the song's changes and media once per invitation: an ask again means only the welcome was missed, and it comes every RESEND s)
  if song and reaper.GetExtState(band.SECTION, "join booted " .. tok.id) == "" then
    reaper.SetExtState(band.SECTION, "join booted " .. tok.id, tostring(now), false)
    jobs[tok.id] = { root = root, song = song, channel = channel, peer = peer, device = r.device, made = rec.made, events = evs, media = media, ei = 1, mi = 1,
      at = reaper.time_precise() }
    band.log(string.format("sent %s the studio and '%s' over the link (%d changes, %d media files)", r.name, tostring(song or "no song"), #evs, #media))
  end
  return true
end
-- Each tick on the computer that made it: the events a batch at a time (the link holds 1,000 waiting files for everyone), the media a few
-- streams at a time; stopped for a computer taken out meanwhile.
function jb.maker_tick()
  for id, j in pairs(jobs) do
    if require("removal").out_since(j.root, j.device, j.made) then
      jobs[id] = nil
      band.log("stopped sending the studio to a computer taken out (" .. j.device:sub(1, 7) .. ")")
    else
      local sent = 0
      while j.ei <= #j.events and sent < jb.EVENTS_PER_TICK do
        local e = j.events[j.ei]
        local rel = j.song .. "/rooms/main/events/" .. e.ev.id .. ".json"
        local ok = e.path and reaper.StudioSync_DirectSend(j.channel, rel, e.path, j.peer) == 1
        if not ok and e.path and band.size(e.path) then break end -- (the link's queue full: the rest next tick; a file gone since: skipped)
        j.ei, sent = j.ei + 1, sent + 1
      end
      local live = 0
      local st = band.json_decode(reaper.StudioSync_DirectStreams and reaper.StudioSync_DirectStreams() or "") or {}
      for _, o in ipairs(type(st.out) == "table" and st.out or {}) do if o.studio == j.channel and not o.finished then live = live + 1 end end
      while j.mi <= #j.media and live < jb.MEDIA_AT_ONCE do
        local m = j.media[j.mi]
        local rel = j.song .. "/" .. m.name
        if reaper.StudioSync_DirectStream(j.channel, rel, m.path, j.peer, 250) ~= 1 then break end
        reaper.StudioSync_DirectStreamEnd(j.channel, rel) -- (complete: begun and ended at once, as streams.on_media_want)
        j.mi, live = j.mi + 1, live + 1
      end
      if j.ei > #j.events and j.mi > #j.media and live == 0 then
        jobs[id] = nil
        band.log(string.format("the first copy of '%s' went: %d changes, %d media files in %.1f s", j.song, #j.events, #j.media, reaper.time_precise() - j.at))
      end
    end
  end
end

-- ---- the joiner -------------------------------------------------------------------------------------------------------------------------
local function boots() local t = band.ext_json(band.SECTION, EXT); return type(t) == "table" and t or {} end
function jb.dir(id) return band.home() .. "/direct/" .. id .. "/.boot" end
local function norm(p) return (tostring(p):gsub("\\", "/"):gsub("/+$", "")) end
local function mkdir_for(p) reaper.RecursiveCreateDirectory(p:match("^(.*)/[^/]+$"), 0) end
local taken_at = {} -- root -> time_precise of the welcome (ready-to-play's clock)
-- A sealed welcome for the invitation pending for `root` (p: { token, nonce }). -> the welcome's fields (as today's welcome), or nil + why.
function jb.take(root, tok, p, sealed)
  if not (reaper.StudioSync_Unseal and type(sealed) == "string" and #sealed <= 140000) then return nil, "can't open a sealed welcome here" end
  local kp = require("nat").key_path()
  local text = kp and tostring(reaper.StudioSync_Unseal(kp, sealed) or "") or ""
  local w = text ~= "" and band.json_decode(text)
  if type(w) ~= "table" then return nil, "not sealed to this computer" end
  if w.studio ~= tok.studio or w.id ~= tok.id then return nil, "for another invitation" end
  if w.device ~= require("services").my_device_id() then return nil, "for another computer" end
  if type(p) ~= "table" or type(p.nonce) ~= "string" or w.nonce ~= p.nonce then return nil, "a replayed welcome (not the answer to this computer's ask)" end
  local dir, rels = jb.dir(tok.studio), {}
  for _, f in ipairs(type(w.files) == "table" and w.files or {}) do
    if type(f) == "table" and jb.rel_ok(f.rel) and not f.rel:find("%.sig$") and type(f.body) == "string" and #f.body <= jb.BODY_MAX then
      mkdir_for(dir .. "/" .. f.rel)
      band.write_atomic(dir .. "/" .. f.rel, f.body)
      if type(f.side) == "string" and #f.side <= jb.SIDE_MAX then band.write_atomic(dir .. "/" .. f.rel .. ".sig", f.side) end
      rels[#rels + 1] = f.rel
    end
  end
  local song = type(w.song) == "string" and require("direct").plain(w.song) and w.song or nil
  local media = {}
  for _, m in ipairs(type(w.media) == "table" and w.media or {}) do
    local name = type(m) == "table" and require("streams").media_name(m.room, m.file)
    local size = type(m) == "table" and tonumber(m.size)
    if song and name and size and size > 0 and size == math.floor(size) and #media < jb.MEDIA_MAX then media[#media + 1] = { room = m.room, file = m.file, size = math.floor(size), name = name } end
  end
  local n = tonumber(w.events) and math.max(0, math.floor(tonumber(w.events))) or 0
  if song then -- (the link's inbox keeps these past its day: they're as old as the song. lib/direct.lua prune)
    local mark = band.home() .. "/direct/" .. tok.studio .. "/" .. song .. "/rooms/main/.boot"
    mkdir_for(mark)
    band.write_atomic(mark, tostring(os.time()))
  end
  mkdir_for(dir .. "/manifest.json")
  band.write_atomic(dir .. "/manifest.json", band.json_encode({ root = root, song = song, events = n, media = media, files = rels, channel = "join-" .. tok.id }))
  local t = boots()
  t[root] = { id = tok.studio, at = os.time() }
  band.set_ext_json(band.SECTION, EXT, t, true)
  band.forget_info()
  local okk, nk = pcall(function() return require("signed").seed_keys(root, w.keys) end)
  if not okk then band.log("couldn't take the welcome's keys: " .. tostring(nk)) end
  taken_at[root] = reaper.time_precise()
  band.log(string.format("the studio's first copy came over the link: %d files%s", #rels,
    song and string.format(", '%s' on its way (%d changes, %d media files)", song, n, #media) or ""))
  return w
end
-- band.read's fallback (band.boot_copy): the boot copy of a studio file the folder has none of yet, or nil.
local parsed_text, parsed = nil, {}
function jb.read(path)
  local text = reaper.GetExtState(band.SECTION, EXT)
  if text ~= parsed_text then
    parsed_text, parsed = text, {}
    for root, v in pairs(band.json_decode(text) or {}) do
      if type(v) == "table" and type(v.id) == "string" and v.id:match("^[%w%-_.]+$") then parsed[#parsed + 1] = { r = norm(root):lower(), id = v.id, at = tonumber(v.at) or 0 } end
    end
  end
  if #parsed == 0 then return nil end
  local p = norm(path)
  local pl = p:lower()
  for _, b in ipairs(parsed) do
    if pl:sub(1, #b.r + 1) == b.r .. "/" and os.time() - b.at < jb.KEEP then
      local rel = p:sub(#b.r + 2)
      if jb.rel_ok(rel) then return band.read_raw(jb.dir(b.id) .. "/" .. rel) end
    end
  end
  return nil
end
-- The songs a boot copy brought for `root` (band.songs adds them while their folders aren't here).
function jb.songs(root)
  local want = norm(root):lower()
  for r, b in pairs(boots()) do
    local m = norm(r):lower() == want and type(b) == "table" and type(b.id) == "string" and os.time() - (tonumber(b.at) or 0) < jb.KEEP
      and band.json_decode(band.read_raw(jb.dir(b.id) .. "/manifest.json") or "")
    if type(m) == "table" and type(m.song) == "string" then return { m.song } end
  end
  return {}
end
-- Where the joiner stands: { files, events, events_want, media, media_want, playable }. events: the main room's changes here (folder and
-- inbox); playable once the song's session.json, every change and every media file are.
function jb.state(root)
  local b = boots()[root]
  local m = b and band.json_decode(band.read_raw(jb.dir(b.id) .. "/manifest.json") or "")
  if type(m) ~= "table" or type(m.song) ~= "string" then return nil end
  local dir = root .. "/" .. m.song .. "/rooms/main/events"
  local have = {}
  for _, f in ipairs(band.files(dir, ".json")) do have[f] = true end
  for _, f in ipairs(band.files(band.home() .. "/direct/" .. b.id .. "/" .. m.song .. "/rooms/main/events", ".json")) do have[f] = true end
  local n, placed = 0, 0
  for _ in pairs(have) do n = n + 1 end
  for _, x in ipairs(m.media) do if band.size(root .. "/" .. m.song .. "/rooms/" .. x.room .. "/media/" .. x.file) == x.size then placed = placed + 1 end end
  local session = band.read(root .. "/" .. m.song .. "/session.json") ~= nil
  return { song = m.song, events = n, events_want = m.events, media = placed, media_want = #m.media, session = session,
    playable = session and n >= m.events and placed >= #m.media }
end
-- A streamed media file, here and whole (the extension checked its length and SHA-256): into the room's media folder, as the link's media
-- always goes (lib/streams.lua place), and Syncthing told. -> true once it's there.
local copying = {}
local function place(root, id, song, x, inn)
  local target = root .. "/" .. song .. "/rooms/" .. x.room .. "/media/" .. x.file
  if band.size(target) == x.size then return true end
  if not (inn and inn.done and inn.ok and tonumber(inn.total) == x.size and type(inn.path) == "string") then return false end
  if reaper.file_exists(target) then return false end -- (another version there: Syncthing's word, not ours)
  mkdir_for(target)
  if not os.rename(inn.path, target) and not copying[target] then
    copying[target] = true
    band.copy_background(inn.path, target) -- (another drive: copied out of the way of REAPER)
    return false
  end
  if band.size(target) ~= x.size then return false end
  pcall(function() require("services").rescan(id, (target:sub(#root + 2))) end)
  return true
end
-- Each tick on the joiner: streamed media put in place; boot copies whose folder file has come dropped; the whole store gone once Syncthing
-- has had GRACE s since bringing band.json, or KEEP after the welcome; "ready to play" said once.
local said_ready = {}
function jb.joiner_tick(now)
  local t, changed = boots(), false
  for root, b in pairs(t) do
    local dir = type(b) == "table" and type(b.id) == "string" and jb.dir(b.id)
    local m = dir and band.json_decode(band.read_raw(dir .. "/manifest.json") or "")
    if type(m) ~= "table" or now - (tonumber(b.at) or 0) >= jb.KEEP then
      t[root], changed = nil, true
    else
      for _, rel in ipairs(m.files or {}) do
        if jb.rel_ok(rel) and reaper.file_exists(root .. "/" .. rel) then os.remove(dir .. "/" .. rel); os.remove(dir .. "/" .. rel .. ".sig") end
      end
      if not b.band_at and reaper.file_exists(root .. "/_band/band.json") then b.band_at, changed = now, true end
      if b.band_at and now - b.band_at >= jb.GRACE then
        for _, rel in ipairs(m.files or {}) do if jb.rel_ok(rel) then os.remove(dir .. "/" .. rel); os.remove(dir .. "/" .. rel .. ".sig") end end
        t[root], changed = nil, true
      elseif type(m.song) == "string" and type(m.media) == "table" then
        local inn = {}
        local st = band.json_decode(reaper.StudioSync_DirectStreams and reaper.StudioSync_DirectStreams() or "") or {}
        for _, i in ipairs(type(st["in"]) == "table" and st["in"] or {}) do if i.studio == m.channel then inn[tostring(i.rel)] = i end end
        for _, x in ipairs(m.media) do place(root, b.id, m.song, x, inn[m.song .. "/" .. x.name]) end
        local s = not said_ready[root] and jb.state(root)
        if s and s.playable then
          said_ready[root] = true
          local took = taken_at[root] and string.format(" %.1f s after the welcome", reaper.time_precise() - taken_at[root]) or ""
          band.log(string.format("'%s' is ready to play%s: open it from Projects (Syncthing carries on in the background)", m.song, took))
        end
      end
    end
  end
  if changed then
    band.set_ext_json(band.SECTION, EXT, t, true)
    band.forget_info()
  end
end
function jb.tick(now)
  band.try("joinboot.maker_tick", jb.maker_tick)
  band.try("joinboot.joiner_tick", jb.joiner_tick, now or os.time())
end

return jb
