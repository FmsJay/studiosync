-- One computer of the convergence soak (tools/soak/soak.py, docs/rt/rt-soak.md): the real Live sync code (lib/mirror.lua, lib/sync.lua,
-- lib/undo.lua and what they load) in its own Lua state, against the stand-in REAPER (tests/fixtures/editreaper.lua) and a folder of its own
-- in memory. soak.py makes three of these (plus a late joiner), carries what each writes in the studio's folder to the others as Syncthing
-- would (late, out of order, half-written, twice) and what each sends on the direct link (late, twice, or never), and drives seeded edits.
-- Everything crosses to Python as JSON text. Set before this runs: SOAK_USER, SOAK_SEED, SOAK_SKEW (seconds this computer's clock is off).
package.path = "lib/?.lua;tests/fixtures/?.lua;" .. package.path
local E = require("editreaper")
-- (GUIDs: the stand-in counts them from 0 in every Lua, so two computers made the same ones, and a track made here could share a GUID with a
-- take that came from a bandmate. REAPER's are random: each computer's count starts in a range of its own)
do
  local off = 0
  for c in tostring(SOAK_USER):gmatch(".") do off = (off * 31 + c:byte()) % 4093 end
  for i = 1, 20 do
    local name = debug.getupvalue(E.guid, i)
    if name == "seq" then debug.setupvalue(E.guid, i, (off + 1) * 0x100000); break end
    if not name then break end
  end
end
local real_date, real_time = os.date, os.time
local T0 = real_time({ year = 2026, month = 11, day = 22, hour = 12, min = 0, sec = 0 })
local ROOT, SONG, ROOM = "C:/soak/Studio", "Soak", "main"
local USER, SKEW = SOAK_USER, tonumber(SOAK_SKEW) or 0
math.randomseed(tonumber(SOAK_SEED) or 1)
local now = 0 -- simulated seconds since the start (soak.py sets it)
os.time = function(t) if t then return real_time(t) end; return T0 + math.floor(now + SKEW) end
os.date = function(fmt, t) return real_date(fmt, t or os.time()) end

local F = E.new("C:/soak/" .. USER .. "/" .. SONG .. ".rpp")
F.undos = {}
reaper = F.reaper
local cfg = { user = USER, root = ROOT }
local B = { song = SONG, room = ROOM }

-- ---- the computer's disk, in memory: io.open, os.remove/rename and REAPER's listings read and write it ----
local fs, dirs, outbox = {}, {}, {}
local function norm(p) return (tostring(p):gsub("\\", "/"):gsub("//+", "/")) end
local function parent(p) return p:match("^(.*)/[^/]*$") end
local function add_dirs(d) while d and not dirs[d] do dirs[d] = {}; local up = parent(d); if up then dirs[up] = dirs[up] or {}; dirs[up][d] = true end; d = up end end
-- (Syncthing carries the studio's folder, never its own temporary names)
local function shared(p) return p:sub(1, #ROOT + 1) == ROOT .. "/" and not p:match("/%.syncthing%.[^/]*$") and not p:find("~syncthing~", 1, true) end
local function set(p, data, from_sync)
  if data == nil then fs[p] = nil else fs[p] = data; add_dirs(parent(p)) end
  if shared(p) and not from_sync then outbox[#outbox + 1] = { data == nil and "del" or "put", p, data } end
end
local function handle(p, data, writing)
  local h, pos, buf = {}, 1, writing and { data } or nil
  function h:read(fmt)
    fmt = fmt or "l"
    if pos > #data and fmt ~= "a" and fmt ~= "*a" then return nil end
    if fmt == "a" or fmt == "*a" then local s = data:sub(pos); pos = #data + 1; return s end
    if type(fmt) == "number" then local s = data:sub(pos, pos + fmt - 1); pos = pos + fmt; return s end
    local e = data:find("\n", pos, true) or (#data + 1)
    local s = data:sub(pos, (fmt == "L" or fmt == "*L") and e or e - 1); pos = e + 1
    return s
  end
  function h:lines() return function() return h:read("l") end end
  function h:seek(whence, off)
    -- (a file being written: its end is what's been written so far. band.lua's atomic write reads its size this way since rt-fix7; answered
    -- 0, every write "failed (is the disk full?)" and no soak computer could share the song. rt-converge)
    if buf then local n = 0; for _, s in ipairs(buf) do n = n + #s end; return n end
    if whence == "end" then pos = #data + 1 + (off or 0) elseif whence == "set" then pos = (off or 0) + 1 end
    return pos - 1
  end
  function h:write(...) for _, s in ipairs({ ... }) do buf[#buf + 1] = tostring(s) end; return h end
  function h:flush() return h end
  function h:setvbuf() return true end
  function h:close() if buf then set(p, table.concat(buf)); buf = nil end; return true end
  return h
end
io.open = function(path, mode)
  local p = norm(path)
  mode = mode or "r"
  if mode:sub(1, 1) == "r" then
    if not fs[p] then return nil, p .. ": No such file or directory" end
    return handle(p, fs[p], false)
  end
  if not dirs[parent(p) or ""] then return nil, p .. ": No such file or directory" end
  return handle(p, mode:sub(1, 1) == "a" and (fs[p] or "") or "", true)
end
io.lines = function(path) local h = assert(io.open(path, "r")); return h:lines() end
os.remove = function(path) local p = norm(path); if not fs[p] then return nil, p .. ": No such file" end; set(p, nil); return true end
os.rename = function(a, b)
  local pa, pb = norm(a), norm(b)
  if not fs[pa] or not dirs[parent(pb) or ""] then return nil, pa .. ": No such file" end
  local d = fs[pa]
  set(pb, d); set(pa, nil)
  return true
end
os.execute = function() return nil end
local enum_cache = {}
local function names_in(d, want_dirs)
  local out = {}
  if want_dirs then for sub in pairs(dirs[d] or {}) do out[#out + 1] = sub:match("([^/]*)$") end
  else
    local pre = d .. "/"
    for p in pairs(fs) do if p:sub(1, #pre) == pre and not p:find("/", #pre + 1, true) then out[#out + 1] = p:sub(#pre + 1) end end
  end
  table.sort(out)
  return out
end
local function enumerate(want_dirs)
  return function(dir, i)
    local d = norm(dir):gsub("/$", "")
    local key = (want_dirs and "D" or "F") .. d
    if i < 0 then enum_cache[key] = nil; return nil end
    if i == 0 or not enum_cache[key] then enum_cache[key] = names_in(d, want_dirs) end
    return enum_cache[key][i + 1]
  end
end
rawset(reaper, "EnumerateFiles", enumerate(false))
rawset(reaper, "EnumerateSubdirectories", enumerate(true))
rawset(reaper, "file_exists", function(p) return fs[norm(p)] ~= nil end)
rawset(reaper, "RecursiveCreateDirectory", function(p) add_dirs(norm(p)); return 1 end)
rawset(reaper, "MB", function() return 6 end) -- (Undo asks when a bandmate changed it since: yes)
rawset(reaper, "GetMousePosition", function() return 0, 0 end)
rawset(reaper, "IsProjectDirty", function() return 0 end)
add_dirs(ROOT .. "/_band")
add_dirs(parent(F.path)) -- (the project's own folder: its id file sits beside it)
fs[ROOT .. "/_band/band.json"] = '{"id":"soak","name":"Soak"}'

-- ---- StudioSync, as Live sync loads it ----
local band = require("band")
local LOG, ERRORS = {}, {}
local real_log = band.log
band.log = function(t) LOG[#LOG + 1] = string.format("%.1f %s", now, tostring(t)); if #LOG > 400 then table.remove(LOG, 1) end; return real_log(t) end
band.log_error = function(where, err) ERRORS[#ERRORS + 1] = string.format("%.1f %s: %s", now, tostring(where), tostring(err)) end
local mirror, sync, direct, undo = require("mirror"), require("sync"), require("direct"), require("undo")
local recall, claimask = require("recall"), require("claimask")
direct.available = function() return true end -- (the extension is mandatory: its inbox is read)
-- (and the link is started for this studio, as Live sync's direct.ensure leaves it: mirror reads a version that has only come over the link
-- from the inbox of the studios in direct.started (direct.path with no cfg). Left empty, every such version was "not readable on this
-- computer" until Syncthing's copy came, which the real Live sync never says: a soak artifact. rt-converge)
direct.started[ROOT] = { at = 0, ok = true }
direct.send_live = function(_, kind, d, song, room, id)
  outbox[#outbox + 1] = { "link", kind, band.json_encode({ song = song, room = room, id = id, d = d }) }
  return true
end
require("prints").choose = function() end -- (which take plays: this computer's own)
package.loaded.trust = setmetatable({ claim_ok = function() return true end }, { __index = require("trust") }) -- (Syncthing says who wrote each file: here, truly them)
-- (REAPER's own move of an item for a tempo change: the stand-in moves its place and length; REAPER, in beats (position, length, rate), also
-- stretches what's inside it (fades, snap offset, an audio take's rate), which is what mirror.retime does when StudioSync puts a version on
-- another map (rt-p1b). Two computers that reached one map by the two roads then differed in the soak alone, by the stand-in's shortfall.
-- Here REAPER's move is mirror.retime's, for every item. rt-converge)
do
  local real = F.tempo_edit
  F.tempo_edit = function(fn)
    local old, was = band.capture_tempo(F.proj), {}
    for _, it in ipairs(F.all_items()) do was[it] = it.text end
    real(fn)
    local new = band.capture_tempo(F.proj)
    for it, text in pairs(was) do it.text = mirror.retime(text, old, new, 1) end
  end
end
local MEDIA = sync.room_dir(cfg, SONG, ROOM) .. "/media"
-- (the song's folders, as the studio's folder has them once the song is shared: Syncthing makes a folder before its first file)
for _, d in ipairs({ "events", "status", "claims", "released", "media" }) do add_dirs(sync.room_dir(cfg, SONG, ROOM) .. "/" .. d) end
local SESSION = band.session_path(cfg, SONG)

local N = {}
NODE = N
local oid_of
local function json(v) return band.json_encode(v) end
local changed_at = -math.huge
function N.set_time(t) now = t; F.clock = 1000 + t + SKEW end

-- ---- a pass of Live sync (its P.who, P.look and P.receive, without the parts that aren't sync) ----
local function who()
  local can, w = sync.authority(cfg, SONG, ROOM, band.read_json(SESSION))
  sync.soft = { room = ROOM, fn = function(name, pos, user) return claimask.soft(w, name, pos, user) end }
  return can, w
end
function N.look()
  local can, w = who()
  local ok, e = pcall(sync.watch_timeline, F.proj, cfg, SONG, ROOM, can)
  if not ok then ERRORS[#ERRORS + 1] = string.format("%.1f watch_timeline: %s", now, tostring(e)) end
  local ok2, sent = pcall(mirror.watch, F.proj, cfg, SONG, ROOM, { can = can, owner_can = can, mode = w.mode, is_claimed = w.is_claimed, owner_of = w.owner_of,
    quick = true, edited_at = changed_at,
    ask = function(name, pos) return claimask.hold(cfg, B, w, name, pos) end, sent = claimask.on_sent,
    soft = function(name, pos) return claimask.soft(w, name, pos, USER) end })
  if not ok2 then ERRORS[#ERRORS + 1] = string.format("%.1f mirror.watch: %s", now, tostring(sent)) end
  band.try("claimask.flush", claimask.flush, cfg, B, w, false)
  return (mirror.more or mirror.unsettled) and 1 or 0
end
function N.receive()
  local can = who()
  local n = 0
  for _ = 1, 20 do
    local ok, got = pcall(sync.receive, F.proj, cfg, SONG, ROOM, can)
    if not ok then ERRORS[#ERRORS + 1] = string.format("%.1f sync.receive: %s", now, tostring(got)); break end
    n = n + (tonumber(got) or 0)
    if (tonumber(got) or 0) == 0 and not sync.backlog and not sync.read_cut then break end
  end
  return n
end
-- (Live sync's P.heal and the order heal: a bandmate with every change whose project has differed from ours for a minute, while we're caught up
-- too, brings ours in line (at most every 5 minutes); the track order put right 10 s after the last edit. Counted for the soak's stats.)
local heal_since, healed_at, heals, claims_at = nil, -math.huge, 0, -math.huge
local function heal()
  local now = F.clock
  local mine, differs = mirror.root(F.proj), false
  for _, st in ipairs(require("presence").peers(cfg, SONG, ROOM)) do
    if st.mirror and st.pending == 0 and st.mirror ~= mine then differs = true end
  end
  -- (Live sync's note of who holds another project or track order, each pass: the order heal acts on it (mirror.order_apart_for). Without it
  -- no soak computer ever put its track order right after its first look, which the real Live sync does: a soak artifact. rt-converge)
  pcall(mirror.apart_note, F.proj, mine, mirror.order_code(F.proj), function() return sync.pending_events(F.proj, cfg, SONG, ROOM) end,
    require("presence").peers(cfg, SONG, ROOM), now)
  if differs and sync.pending_events(F.proj, cfg, SONG, ROOM) == 0 then heal_since = heal_since or now else heal_since = nil end
  if now - claims_at > 10 then claims_at = now; pcall(sync.drop_gone_claims, F.proj, cfg, SONG, ROOM) end -- (as P.heal: a deleted track's claim goes)
  if heal_since and now - heal_since > 60 and now - healed_at > 300 then
    healed_at, heal_since = now, nil
    local ok, n = pcall(mirror.heal, F.proj, sync.room_dir(cfg, SONG, ROOM), false)
    if not ok then ERRORS[#ERRORS + 1] = string.format("%.1f mirror.heal: %s", now, tostring(n)) elseif (n or 0) > 0 then heals = heals + 1 end
  end
  local ok, moved = pcall(mirror.order_heal, F.proj, cfg, SONG, ROOM, now, now - changed_at)
  if not ok then ERRORS[#ERRORS + 1] = string.format("%.1f mirror.order_heal: %s", now, tostring(moved)) elseif (moved or 0) > 0 then heals = heals + 1 end
  return (ok and moved or 0)
end
function N.pass() local more = N.look(); local n = N.receive(); n = n + heal(); return json({ more = more, got = n, heals = heals }) end
-- (the order heal's own act, for the late joiner: mirror.order_heal puts a project on the studio's order once after opening, and after that
-- only when a caught-up bandmate has had another order for 30 s. The late joiner has nobody beside it in the soak, so tracks that landed
-- after its first heal (a change refused by the claims lands a minute later) stayed where they landed, which no real late joiner's would.
-- -> how many tracks moved. rt-converge)
function N.order_now() return mirror.keep_order(F.proj, cfg, SONG, ROOM) end
-- (Live sync's status: the file every FILE_QUIET s and a presence message beside it, so the others know who's here; with what P.heal compares:
-- the project's root, what's still to apply, the track order's code)
function N.status()
  local info = { pending = sync.pending_events(F.proj, cfg, SONG, ROOM), mirror = mirror.root(F.proj), order = mirror.order_code(F.proj) }
  band.try("write_status", sync.write_status, F.proj, cfg, SONG, ROOM, info, false)
  return true
end
-- (the room's mode, as its owner set it: "open" is Claims, the default; "everyone" is Open, claims off)
function N.set_mode(mode) sync.set_mode(cfg, SONG, ROOM, mode, USER); return true end

-- ---- what Syncthing and the link bring ----
function N.put(path, data) set(path, data, true); return true end -- (data nil: deleted)
function N.has(path) return fs[path] end
function N.link(kind, text)
  local w = band.json_decode(text)
  if type(w) ~= "table" or w.song ~= SONG or w.room ~= ROOM then return false end
  if kind == "event" then
    local ok, took = pcall(sync.take_event, cfg, SONG, ROOM, w.d)
    if not ok then ERRORS[#ERRORS + 1] = string.format("%.1f take_event: %s", now, tostring(took)) end
    return ok and took or false
  elseif kind == "presence" or kind == "heartbeat" then pcall(require("presence").from_msg, cfg, SONG, ROOM, w.d, kind)
  elseif kind == "claim" then pcall(sync.live_claim, SONG, ROOM, w.d)
  elseif kind == "claim_ask" then pcall(claimask.on_ask, cfg, B, w.d)
  elseif kind == "claim_answer" then pcall(claimask.on_answer, cfg, B, w.d) end
  return true
end
-- (a file taken away and put again within one drain is one change of it: band.lua's atomic write on Windows moves the old file aside, puts
-- the new one in place and removes the old (since rt-fix7 for every write), which Syncthing's watcher sees as the file changing, seconds
-- later. Sent on as a deletion and a new file, each with its own delay, a bandmate's claims or order list was gone for seconds on the other
-- computers: a soak artifact. rt-converge)
function N.drain()
  local o, put_later, out = outbox, {}, {}
  outbox = {}
  for i = #o, 1, -1 do
    local e = o[i]
    if e[1] == "put" then put_later[e[2]] = true
    elseif e[1] == "del" and put_later[e[2]] then o[i] = false end
  end
  for _, e in ipairs(o) do if e then out[#out + 1] = e end end
  return json(out)
end
function N.shared_files() -- every file of the studio's folder here, for a late joiner's Syncthing
  local out = {}
  for p, d in pairs(fs) do if shared(p) then out[#out + 1] = { p, d } end end
  table.sort(out, function(a, b) return a[1] < b[1] end)
  return json(out)
end
function N.errors() return json(ERRORS) end
-- (for looking into a failure by hand: Lua run inside this computer, with F, mirror, sync, cfg and fs at hand)
function N.eval(code)
  local fn = assert(load(code, "eval", "t", setmetatable({ F = F, mirror = mirror, sync = sync, band = band, cfg = cfg, fs = fs, SONG = SONG, ROOM = ROOM, MEDIA = MEDIA }, { __index = _G })))
  local res = table.pack(pcall(fn))
  local out = {}
  for i = 1, res.n do out[#out + 1] = tostring(res[i]) end
  return table.concat(out, "\t")
end
function N.log() return table.concat(LOG, "\n") end

-- ---- what this computer holds: every object's hash, the track order, the timeline, and the doubles ----
function N.state()
  local objs = mirror.scan(F.proj, USER, MEDIA, false)
  local hashes, order, seen, dup = {}, {}, {}, {}
  for _, o in ipairs(objs) do
    if seen[o.oid] then dup[#dup + 1] = "the same id twice: " .. o.oid end
    seen[o.oid] = true
    -- (a part's text with every decimal to its 9th place: a time REAPER moved for a tempo map and back is written to its 14th digit, the
    -- event's text has it rounded. Nobody hears 1e-12 s; mirror.rounded makes the same allowance)
    -- (and a whole number written as one: a rate of 1 that went to another map and back reads 0.99999999999997 on the computer REAPER
    -- moved it on, and "1" where the change landed: "1.000000000" against "1" was a difference. rt-converge)
    if type(o.state) == "string" and o.state:find("%d%.%d") then
      local function num9(x)
        local s = string.format("%.9f", tonumber(x)):gsub("0+$", ""):gsub("%.$", "")
        return s == "-0" and "0" or s
      end
      hashes[o.oid] = mirror.hash((o.state:gsub("%-?%d+%.%d+e%-?%d+", num9):gsub("%-?%d+%.%d+", num9)))
    else hashes[o.oid] = o.hash end
    if o.kind == "track" then order[#order + 1] = o.oid end
  end
  -- (two items alike in everything but their ids, on one track: one change applied twice. The driver never makes two alike: every place it
  -- puts an item is a fresh random time)
  for _, t in ipairs(F.tracks) do
    local like = {}
    for _, it in ipairs(t.items) do
      local k = it.text:gsub("\n%s*GUID [^\n]*", ""):gsub("\n%s*SEL [^\n]*", "")
      if like[k] then dup[#dup + 1] = "two items alike on " .. tostring(t.name) .. ": " .. tostring(it.ext.band_oid) .. " and " .. tostring(like[k]) end
      like[k] = it.ext.band_oid or "?"
    end
  end
  local function r(x) return type(x) == "number" and math.floor(x * 1e6 + 0.5) / 1e6 or x end
  local tempo, markers = band.capture_tempo(F.proj), band.capture_markers(F.proj)
  for _, x in ipairs(tempo) do x.time, x.bpm = r(x.time), r(x.bpm) end
  for _, x in ipairs(markers) do x.pos, x["end"] = r(x.pos), r(x["end"]) end
  local names = {}
  for _, o in ipairs(objs) do if o.kind == "track" and type(o.state) == "table" then names[o.oid] = o.state.name end end
  return json({ hashes = hashes, order = table.concat(order, ","), timeline = json({ tempo, markers }), dup = dup, names = names, ntracks = #F.tracks, nitems = #F.all_items() })
end
-- Every track and item here, one line each (for a failure's report).
function N.dump()
  local out = {}
  for _, t in ipairs(F.tracks) do
    out[#out + 1] = string.format("track %s %q", oid_of(t), t.name)
    for _, it in ipairs(t.items) do
      out[#out + 1] = string.format("  item %s %s pos %s len %s", oid_of(it), it.text:match('NAME "([^"]*)"') or "", E.top_value(it.text, "POSITION"), E.top_value(it.text, "LENGTH"))
    end
  end
  return table.concat(out, "\n")
end
-- One object as this computer reads it (for a failure's report).
function N.show(oid)
  for _, o in ipairs(mirror.scan(F.proj, USER, MEDIA, false)) do
    if o.oid == oid then return type(o.state) == "table" and json(o.state) or tostring(o.state) end
  end
  return "(not here)"
end

-- ---- the song, as the first computer shares it ----
local function f(x) return E.f(x) end
local file_n = 0
local function audio(pos, len, name)
  file_n = file_n + 1
  -- (its recording, in the studio's media folder: Syncthing carries it too, often after the change that names it)
  set(MEDIA .. "/" .. USER .. "-" .. file_n .. ".flac", "fLaC" .. string.rep(USER, 40) .. file_n)
  return table.concat({ "<ITEM", "POSITION " .. f(pos), "SNAPOFFS 0", "LENGTH " .. f(len), "LOOP 1", "ALLTAKES 0", "FADEIN 1 0.01 0 1 0 0 0", "FADEOUT 1 0.01 0 1 0 0 0",
    "MUTE 0 0", "SEL 0", "IID 1", 'NAME "' .. name .. '"', "VOLPAN 1 0 1 -1", "SOFFS 0", "PLAYRATE 1 1 0 -1 0 0.0025", "CHANMODE 0", "GUID " .. E.guid(),
    "<SOURCE WAVE", 'FILE "' .. MEDIA .. "/" .. USER .. "-" .. file_n .. '.flac"', ">", ">" }, "\n") .. "\n"
end
local function midi(pos, len, name, notes)
  local t = { "<ITEM", "POSITION " .. f(pos), "SNAPOFFS 0", "LENGTH " .. f(len), "LOOP 0", "ALLTAKES 0", "FADEIN 1 0 0 1 0 0 0", "FADEOUT 1 0 0 1 0 0 0", "MUTE 0 0", "SEL 0",
    "IID 2", 'NAME "' .. name .. '"', "VOLPAN 1 0 1 -1", "SOFFS 0", "PLAYRATE 1 1 0 -1 0 0.0025", "CHANMODE 0", "GUID " .. E.guid(), "<SOURCE MIDI", "HASDATA 1 960 QN", "CCINTERP 32" }
  for _, n in ipairs(notes) do t[#t + 1] = n end
  for _, l in ipairs({ "E 960 b0 7b 00", "GUID " .. E.guid(), "IGNTEMPO 0 120 4 4", ">", ">" }) do t[#t + 1] = l end
  return table.concat(t, "\n") .. "\n"
end
local ENV = "<VOLENV2\nEGUID {E1}\nACT 1 -1\nVIS 1 1 1\nLANEHEIGHT 0 0\nARM 0\nDEFSHAPE 0 -1 -1\nPT 0 1 0\nPT 4 0.5 0\nPT 8 1 0\nPT 12 0.7 0\n>\n"
local function seed_markers() F.add_marker(true, 0, 8, "Verse"); F.add_marker(true, 8, 16, "Chorus"); F.add_marker(false, 4, 4, "Cue") end
function N.open() seed_markers(); return true end -- (the song's file: every computer opens with its markers)
function N.share()
  local drums = F.add_track("Drums", nil, ENV)
  local bass, keys, gtr = F.add_track("Bass"), F.add_track("Keys"), F.add_track("Gtr")
  for i = 0, 3 do F.add_item(drums, audio(i * 4, 3.5, "Drums " .. i)) end
  for i = 0, 3 do F.add_item(bass, audio(i * 4 + 0.5, 3, "Bass " .. i)) end
  F.add_item(keys, midi(0, 4, "Keys A", { "E 0 90 3c 60", "E 480 80 3c 00", "E 0 90 40 50", "E 480 80 40 00" }))
  F.add_item(keys, midi(8, 4, "Keys B", { "E 0 90 43 60", "E 480 80 43 00", "E 0 b0 07 64" }))
  F.add_item(gtr, audio(2, 6, "Gtr"))
  add_dirs(band.song_dir(cfg, SONG))
  band.write_json(SESSION, { sync = "mirror", host = USER, tempo = band.capture_tempo(F.proj), markers = band.capture_markers(F.proj) })
  return true
end

-- ---- the driver's edits: each as REAPER leaves the project after it. `r`: the driver's random numbers in [0, 1), which pick the target ----
local function pick(list, x) if #list == 0 then return nil end; return list[1 + math.floor(x * #list) % #list] end
local function at(x) return math.floor(x * 600000) / 10000 end -- (a fresh random time 0-60 s: no two places alike)
local function setv(it, key, v) F.set_text(it, E.set_top(it.text, key, v)) end
oid_of = function(x) return (x and x.ext and x.ext.band_oid) or "?" end
local function tname(t) return t and (t.name ~= "" and t.name or oid_of(t)) or "?" end
-- (the items by their id and place, not by where each sits in its track's list: that order comes from the order changes landed in, which
-- varies between runs of one seed, so the same random number picked another item)
local function items_in_order()
  local l = F.all_items()
  local key = {}
  for _, it in ipairs(l) do key[it] = (it.ext.band_oid or "~") .. string.format("%020.6f", tonumber(E.top_value(it.text, "POSITION")) or 0) .. it.guid end
  table.sort(l, function(a, b) return key[a] < key[b] end)
  return l
end
local function midi_items()
  local out = {}
  for _, it in ipairs(items_in_order()) do if it.text:find("<SOURCE MIDI", 1, true) then out[#out + 1] = it end end
  return out
end
local function body_set(t, body) t.body = body; F.changed() end
-- (the tracks an edit is made on: the studio's, not this computer's own "(yours, not sent)" tracks. An item dragged onto one of those is,
-- by design, out of the studio on this computer alone ("it isn't sent from there, and the others keep it where it was"), which the oracle
-- then read as "missing here": the driver doesn't do that. rt-converge)
local function studio_tracks()
  local out = {}
  for _, t in ipairs(F.tracks) do if not (t.ext and (t.ext.band_local or t.ext.band_live_track)) then out[#out + 1] = t end end
  return out
end
local FX = { 'VST "VST: ReaEQ (Cockos)" reaeq.dll 0 "" 1919247729<56535472656571726561657100000000> ""', 'VST "VST: ReaComp (Cockos)" reacomp.dll 0 "" 1919247213<56535472636D70726561636F6D7000> ""',
  'JS utility/volume ""', 'VST "VST: ReaDelay (Cockos)" readelay.dll 0 "" 1919247468<5653547265646C72656164656C617900> ""' }
-- The plug-ins of a track's <FXCHAIN, each its lines; and the body before and after the chain (to its own closing ">", past the plug-ins'
-- nested blocks). No chain: {}, the body, nil.
local function fx_blocks(body)
  local L, before, list, cur, d, start, stop = {}, {}, {}, nil, 0, nil, nil
  for l in body:gmatch("[^\n]+") do L[#L + 1] = l end
  for i, l in ipairs(L) do
    if not start then
      if l == "<FXCHAIN" and d == 0 then start, d = i, 1 else before[#before + 1] = l end
      if not start then if l:sub(1, 1) == "<" then d = d + 1 elseif l == ">" then d = d - 1 end end
    elseif not stop then
      if d == 1 and l:match("^BYPASS ") then cur = { l }; list[#list + 1] = cur
      elseif d == 1 and l == ">" then stop = i
      elseif cur then cur[#cur + 1] = l end
      if not stop then if l:sub(1, 1) == "<" then d = d + 1 elseif l == ">" then d = d - 1 end end
    end
  end
  if not start then return {}, body, nil end
  local pre = #before > 0 and (table.concat(before, "\n") .. "\n") or ""
  local post = stop and stop < #L and (table.concat(L, "\n", stop + 1) .. "\n") or ""
  return list, pre, post
end
local function fx_write(t, list, before, after)
  local out = {}
  for _, b in ipairs(list) do out[#out + 1] = table.concat(b, "\n") end
  local chain = #list > 0 and ("<FXCHAIN\nSHOW 0\nLASTSEL 0\nDOCKED 0\n" .. table.concat(out, "\n") .. "\n>\n") or ""
  body_set(t, (before or t.body) .. chain .. (after or ""))
end
-- (the plug-ins through the API, read from the chain's text, as REAPER's would read: the stand-in has none (TrackFX_GetCount 0), and with no
-- knobs to read mirror took every chain edit for REAPER re-encoding the chain and never sent it (mirror.lua's fx_readback). One knob per
-- plug-in, its value the number in the driver's state line; a plug-in's name from its first line; no presets, never open)
local function fx_of(tr, i) local list = fx_blocks(tr.body or ""); return list[i + 1] end
rawset(reaper, "TrackFX_GetCount", function(tr) return #fx_blocks(tr.body or "") end)
rawset(reaper, "TrackFX_GetNumParams", function(tr, i) return fx_of(tr, i) and 1 or 0 end)
rawset(reaper, "TrackFX_GetParamNormalized", function(tr, i) local b = fx_of(tr, i); return b and (tonumber((b[3] or ""):match("^QUFB(%d+)")) or 0) / 1000 or 0 end)
rawset(reaper, "TrackFX_GetFXName", function(tr, i) local b = fx_of(tr, i); return b ~= nil, b and (b[2]:match('^<%u+ "([^"]*)"') or b[2]:match("^<JS (%S+)")) or "" end)
rawset(reaper, "TrackFX_GetPreset", function() return false, "" end)
rawset(reaper, "TrackFX_GetOpen", function() return false end)
rawset(reaper, "TrackFX_GetEnabled", function(tr, i) local b = fx_of(tr, i); return b ~= nil and b[1]:match("^BYPASS 0") ~= nil end)
rawset(reaper, "TrackFX_GetOffline", function() return false end)
rawset(reaper, "TrackFX_GetFXGUID", function(tr, i) local b = fx_of(tr, i); for _, l in ipairs(b or {}) do local g = l:match("^FXID (%S+)"); if g then return g end end end)
local EDITS = {}
EDITS.item_move = function(r)
  local it = pick(items_in_order(), r[1]); if not it then return end
  reaper.SetMediaItemInfo_Value(it, "D_POSITION", at(r[2]))
  return "moved item " .. oid_of(it) .. " to " .. at(r[2])
end
EDITS.item_resize = function(r)
  local it = pick(items_in_order(), r[1]); if not it then return end
  local l = 0.5 + math.floor(r[2] * 70000) / 10000
  reaper.SetMediaItemInfo_Value(it, "D_LENGTH", l)
  return "resized item " .. oid_of(it) .. " to " .. l
end
EDITS.item_mute = function(r)
  local it = pick(items_in_order(), r[1]); if not it then return end
  local m = reaper.GetMediaItemInfo_Value(it, "B_MUTE") == 1 and 0 or 1
  reaper.SetMediaItemInfo_Value(it, "B_MUTE", m)
  return (m == 1 and "muted" or "unmuted") .. " item " .. oid_of(it)
end
EDITS.item_delete = function(r)
  local it = pick(items_in_order(), r[1]); if not it then return end
  local o = oid_of(it)
  reaper.DeleteTrackMediaItem(it.track, it)
  return "deleted item " .. o
end
EDITS.item_new = function(r)
  local t = pick(studio_tracks(), r[1]); if not t then return end
  local p = at(r[2])
  F.add_item(t, audio(p, 1 + math.floor(r[3] * 40) / 10, USER .. " take " .. file_n + 1))
  F.sort_items(t)
  return "recorded a new item on " .. tname(t) .. " at " .. p
end
EDITS.item_copy = function(r) -- (REAPER's copy: the chunk and P_EXT as they were, new GUIDs, then placed)
  local it = pick(items_in_order(), r[1]); local t = pick(studio_tracks(), r[2]); if not (it and t) then return end
  local c = F.add_item(t, (F.item_chunk(it):gsub("\nIGUID [^\n]*", ""):gsub("\nGUID [^\n]*", function() return "\nGUID " .. E.guid() end)))
  setv(c, "POSITION", f(at(r[3])))
  F.sort_items(t)
  return "copied item " .. oid_of(it) .. " to " .. tname(t) .. " at " .. at(r[3])
end
EDITS.item_to_track = function(r)
  local it = pick(items_in_order(), r[1]); local t = pick(studio_tracks(), r[2]); if not (it and t) or it.track == t then return end
  reaper.MoveMediaItemToTrack(it, t)
  return "moved item " .. oid_of(it) .. " to track " .. tname(t)
end
EDITS.track_add = function(r)
  local n = 1 + math.floor(r[1] * (#F.tracks + 1))
  F.add_track(USER .. " " .. math.floor(r[2] * 1000), math.min(n, #F.tracks + 1))
  return "added a track at " .. n
end
EDITS.track_rename = function(r)
  local t = pick(studio_tracks(), r[1]); if not t then return end
  local was = tname(t)
  reaper.GetSetMediaTrackInfo_String(t, "P_NAME", "T" .. math.floor(r[2] * 10000), true)
  return "renamed track " .. was .. " to " .. t.name
end
EDITS.track_delete = function(r)
  if #F.tracks <= 2 then return end
  local t = pick(studio_tracks(), r[1]); if not t then return end
  local was = tname(t)
  reaper.DeleteTrack(t)
  return "deleted track " .. was
end
EDITS.track_volume = function(r)
  local t = pick(studio_tracks(), r[1]); if not t then return end
  local v = math.floor(r[2] * 2000) / 1000
  reaper.SetMediaTrackInfo_Value(t, "D_VOL", v)
  return "set track " .. tname(t) .. " volume " .. v
end
EDITS.track_move = function(r)
  if #F.tracks < 2 then return end
  local t = pick(studio_tracks(), r[1]); if not t then return end
  local to = math.floor(r[2] * #F.tracks)
  reaper.SetOnlyTrackSelected(t)
  reaper.ReorderSelectedTracks(to, 0)
  return "moved track " .. tname(t) .. " above " .. to
end
EDITS.tempo = function(r)
  local n = reaper.CountTempoTimeSigMarkers(F.proj)
  local bpm = 80 + math.floor(r[2] * 80)
  if r[1] < 0.4 then
    reaper.SetTempoTimeSigMarker(F.proj, 0, 0, -1, -1, bpm, 4, 4, false)
    return "first tempo to " .. bpm
  elseif r[1] < 0.75 or n < 2 then
    local t = 2 + math.floor(r[3] * 40)
    -- (one tempo marker to a place, as REAPER keeps them: a second set at a marker's time changes that marker. The stand-in kept both, in
    -- whatever order its sort left two of one time, and two computers then read one map as two tempos from there on. rt-converge)
    local at = -1
    for i = 0, n - 1 do
      local _, mt = reaper.GetTempoTimeSigMarker(F.proj, i)
      if math.abs(mt - t) < 1e-9 then at = i end
    end
    reaper.SetTempoTimeSigMarker(F.proj, at, t, -1, -1, bpm, 4, 4, false)
    return "tempo marker " .. bpm .. " at " .. t
  end
  local i = 1 + math.floor(r[3] * (n - 1))
  reaper.DeleteTempoTimeSigMarker(F.proj, i)
  return "deleted tempo marker " .. i
end
EDITS.marker = function(r)
  local list = {}
  for _, m in ipairs(F.markers) do list[#list + 1] = m end
  local m = pick(list, r[2])
  if r[1] < 0.35 or not m then
    local p = at(r[3])
    local region = r[4] < 0.4
    reaper.AddProjectMarker2(F.proj, region, p, p + 4, USER .. " " .. math.floor(r[5] * 100), -1, 0)
    return "added a " .. (region and "region" or "marker") .. " at " .. p
  elseif r[1] < 0.6 then
    reaper.SetProjectMarker4(F.proj, m.num, m.region, at(r[3]), at(r[3]) + 4, m.name, 0)
    return "moved " .. (m.region and "region " or "marker ") .. m.num .. " to " .. at(r[3])
  elseif r[1] < 0.85 then
    reaper.SetProjectMarker4(F.proj, m.num, m.region, m.pos, m.rend, "N" .. math.floor(r[3] * 1000), 0)
    return "renamed " .. (m.region and "region " or "marker ") .. m.num
  end
  reaper.DeleteProjectMarker(F.proj, m.num, m.region)
  return "deleted " .. (m.region and "region " or "marker ") .. m.num
end
EDITS.notes = function(r) -- a note added, moved, transposed or taken out of a MIDI item
  local it = pick(midi_items(), r[1]); if not it then return end
  local L, ev = {}, {}
  for l in it.text:gmatch("[^\n]+") do L[#L + 1] = l; if l:match("^E %d+ [89]") then ev[#ev + 1] = #L end end
  local key = string.format("%02x", 36 + math.floor(r[3] * 48))
  local what
  if r[2] < 0.4 or #ev < 2 then -- (added before the item's last event)
    local last
    for i, l in ipairs(L) do if l:match("^E ") then last = i end end
    if not last then return end
    table.insert(L, last, "E " .. math.floor(r[4] * 960) .. " 90 " .. key .. " 60")
    table.insert(L, last + 1, "E 240 80 " .. key .. " 00")
    what = "added note " .. key
  elseif r[2] < 0.7 then -- (a note on and its off moved to another key)
    local i = ev[1 + math.floor(r[4] * #ev) % #ev]
    local old = L[i]:match("^E %d+ %x%x (%x%x)")
    for j = i, #L do
      local d, s, k, v = L[j]:match("^E (%d+) (%x%x) (%x%x) (%x%x)")
      if k == old and (j == i or s:sub(1, 1) == "8") then L[j] = "E " .. d .. " " .. s .. " " .. key .. " " .. v; if j > i then break end end
    end
    what = "transposed note " .. old .. " to " .. key
  else -- (one note's on and off taken out)
    local i = ev[1 + math.floor(r[4] * #ev) % #ev]
    local old = L[i]:match("^E %d+ %x%x (%x%x)")
    local j2
    for j = i + 1, #L do local s, k = L[j]:match("^E %d+ (%x%x) (%x%x)"); if k == old and s:sub(1, 1) == "8" then j2 = j; break end end
    if j2 then table.remove(L, j2) end
    table.remove(L, i)
    what = "removed note " .. old
  end
  F.set_text(it, table.concat(L, "\n") .. "\n")
  return what .. " in item " .. oid_of(it)
end
EDITS.cc = function(r) -- a controller value drawn or changed
  local it = pick(midi_items(), r[1]); if not it then return end
  local L, cc = {}, {}
  for l in it.text:gmatch("[^\n]+") do L[#L + 1] = l; if l:match("^E %d+ b0 07 ") then cc[#cc + 1] = #L end end
  local v = string.format("%02x", math.floor(r[3] * 127))
  if r[2] < 0.5 or #cc == 0 then
    local last
    for i, l in ipairs(L) do if l:match("^E ") then last = i end end
    if not last then return end
    table.insert(L, last, "E " .. math.floor(r[4] * 960) .. " b0 07 " .. v)
  else
    local i = cc[1 + math.floor(r[4] * #cc) % #cc]
    L[i] = L[i]:gsub("%x%x$", v)
  end
  F.set_text(it, table.concat(L, "\n") .. "\n")
  return "CC7 " .. v .. " in item " .. oid_of(it)
end
EDITS.fx = function(r) -- a plug-in added, removed, moved or turned (its state line)
  local t = pick(studio_tracks(), r[1]); if not t then return end
  local list, before, after = fx_blocks(t.body)
  local what
  if r[2] < 0.35 or #list == 0 then
    local name = pick(FX, r[3])
    table.insert(list, 1 + math.floor(r[4] * (#list + 1)) % (#list + 1),
      { "BYPASS 0 0 0", "<" .. name, "QUFB" .. math.floor(r[5] * 1000) .. "AAAA", ">", "FLOATPOS 0 0 0 0", "FXID " .. E.guid(), "WAK 0 0" })
    what = "added " .. (name:match('^VST "([^"]+)"') or name:match("^JS (%S+)")) .. " on "
  elseif r[2] < 0.55 then
    table.remove(list, 1 + math.floor(r[3] * #list) % #list)
    what = "removed a plug-in from "
  elseif r[2] < 0.7 and #list > 1 then
    local b = table.remove(list, 1 + math.floor(r[3] * #list) % #list)
    table.insert(list, 1 + math.floor(r[4] * (#list + 1)) % (#list + 1), b)
    what = "reordered the plug-ins on "
  else
    local b = list[1 + math.floor(r[3] * #list) % #list]
    b[3] = "QUFB" .. math.floor(r[5] * 1000) .. "AAAA"
    what = "turned a plug-in on "
  end
  fx_write(t, list, before, after)
  return what .. tname(t)
end
EDITS.envelope = function(r) -- an automation point moved in value
  local withenv = {}
  for _, t in ipairs(F.tracks) do if t.body:find("<VOLENV2", 1, true) then withenv[#withenv + 1] = t end end
  local t = pick(withenv, r[1])
  if not t then
    t = pick(studio_tracks(), r[1]); if not t then return end
    body_set(t, t.body .. ENV:gsub("{E1}", E.guid()))
    return "added volume automation on " .. tname(t)
  end
  local n, k = 0, 1 + math.floor(r[2] * 4)
  body_set(t, (t.body:gsub("\nPT (%S+) (%S+)", function(p, v) n = n + 1; if n == k then return "\nPT " .. p .. " " .. f(math.floor(r[3] * 1000) / 1000) end end)))
  return "moved automation point " .. k .. " on " .. tname(t)
end
EDITS.claim = function(r)
  local t = pick(studio_tracks(), r[1]); if not t then return end
  if r[2] < 0.7 then sync.claim_tracks(cfg, SONG, ROOM, { t.name }); return "claimed " .. tname(t) end
  local c = sync.my_claims(cfg, SONG, ROOM)
  if c then c.tracks = {}; sync.set_claims(cfg, SONG, ROOM, c) end
  return "let go of my claims"
end
-- (Ctrl+Z / Ctrl+Shift+Z on a StudioSync song: lib/undo.lua's step)
local function step(redo)
  local ok, res, why = pcall(undo.step, F.proj, cfg, B, redo, {})
  if not ok then ERRORS[#ERRORS + 1] = string.format("%.1f undo.step: %s", now, tostring(res)); return "undo.step raised" end
  return (redo and "redo" or "undo") .. ": " .. tostring(res or ("nothing (" .. tostring(why) .. ")"))
end
EDITS.undo = function() return step(false) end
EDITS.redo = function() return step(true) end
EDITS.restore = function(r) -- the whole song back to an older point, as the Restore page does: the map first, then the objects
  local entries = recall.entries(cfg, SONG, ROOM)
  if #entries < 2 then return end
  local upto = 1 + math.floor(r[1] * (#entries - 1))
  local okt, e = pcall(sync.restore_timeline, F.proj, cfg, SONG, ROOM, entries, upto, band.read_json(SESSION))
  if not okt then ERRORS[#ERRORS + 1] = string.format("%.1f restore_timeline: %s", now, tostring(e)) end
  local can = who()
  local act = string.format("%s-%s-r%d", sync.id_user(USER), os.date("!%Y%m%d%H%M%S"), math.random(0, 999999))
  local ok, res = pcall(mirror.revert, F.proj, cfg, SONG, ROOM, mirror.plan_restore(entries, upto), { can = can, mode = "open", at_once = true, act = act })
  if not ok then ERRORS[#ERRORS + 1] = string.format("%.1f mirror.revert: %s", now, tostring(res)) end
  return "restored the song to change " .. upto .. " of " .. #entries .. ": " .. tostring(res)
end
-- -> what was done, or "" when the edit had nothing to act on here.
function N.edit(kind, rtext)
  local r = band.json_decode(rtext)
  local fn = EDITS[kind]
  local ok, what = pcall(fn, r)
  if not ok then ERRORS[#ERRORS + 1] = string.format("%.1f edit %s: %s", now, kind, tostring(what)); return "edit raised" end
  if what then changed_at = F.clock end
  return what or ""
end
return true
