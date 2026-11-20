-- The first copy of the studio over the direct link for a computer an invitation lets in (lib/joinboot.lua, lib/joins.lua, docs/rt/rt-joinlink.md).
-- Two stand-in computers in one Lua state, each with its own folder, home, saved state and copy of every module (as test_0_60_rt_linkfirst):
-- Ann's (the owner, who made the invitation) and Jo's (the joiner), and a stand-in link between them (messages, files and streams handed
-- over at once, only on a channel both started with the same key, only to a computer listening). Checked:
--  - the bootstrap: Jo pastes the invitation, asks, Ann lets Jo in and sends the welcome, the song's changes and media; Jo's computer then
--    reads the studio's band.json, roles, devices, removal mark, the song's session.json and room settings as Ann's (signatures with them),
--    the studio isn't waiting, the song is on its Projects list, every object's newest change is Jo's newest (and every change of the one
--    two people edited apart), the newest tempo map, no cues, every media file placed byte for byte; nothing written into Jo's folder but
--    the media; the time to playable for the stand-in song;
--  - the studio's secret: never on the wire in the clear; the welcome opens only with Jo's key (not Eve's, who holds the token too);
--  - refused: a computer the invitation didn't let in (another device with a used token), a replayed welcome (after it was taken; and to a
--    later ask, whose nonce differs), an ask naming Jo's device with another key (nothing sent to its reply), Jo taken out (asking again gets
--    nothing; the rest of the first copy stops);
--  - Syncthing arriving later: the same files in Jo's folder change nothing read, the boot copies and inbox copies go, the store retires.
-- The sealing is a stand-in here (it opens only with the key it was sealed to; the real X25519 + XChaCha20-Poly1305 is tests/nat_test.cpp's).
-- Ed25519 is tools/sign_release.py's through lupa's `python`. Lupa, repo root. (rt-joinlink)
package.path = "lib/?.lua;" .. package.path
local T = (os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"):gsub("\\", "/") .. "/ss_joinlink_" .. os.time() .. "_" .. math.random(100000, 999999)
local SEP = package.config:sub(1, 1)
local function clean() os.execute(SEP == "\\" and ('rmdir /s /q "' .. T:gsub("/", "\\") .. '" 2>nul') or ("rm -rf '" .. T .. "'")) end
local function check(cond, what) if not cond then clean(); error(what, 2) end end

python.eval("__import__('sys').path.insert(0, 'tools')")
local sr = python.eval("__import__('sign_release')")
local py_sign = python.eval("lambda sr, kp, m: sr.sign(sr.load_seed(kp), m.encode('utf-8')).hex()")
local py_key = python.eval("lambda sr, kp: sr.public_key(sr.new_key(kp)).hex()")
local py_verify = python.eval("lambda sr, s, m, k: sr.verify(bytes.fromhex(k), m.encode('utf-8'), bytes.fromhex(s))")
local sha = python.eval("lambda s: __import__('hashlib').sha256(s.encode('latin-1')).hexdigest()")
local mkdirs = python.eval("lambda d: __import__('os').makedirs(d, exist_ok=True)")
local list_of = python.eval([[lambda d, dirs: '\n'.join(f for f in sorted(__import__('os').listdir(d))
  if (__import__('os').path.isdir(d + '/' + f) if dirs else __import__('os').path.isfile(d + '/' + f))) if __import__('os').path.isdir(d) else '']])
local function read(p) local f = io.open(p, "rb"); if not f then return nil end local s = f:read("a"); f:close(); return s end
local function write(p, s) mkdirs(p:match("^(.*)/[^/]+$")); local f = assert(io.open(p, "wb")); f:write(s); f:close() end
local function size(p) local f = io.open(p, "rb"); if not f then return nil end local n = f:seek("end"); f:close(); return n end
mkdirs(T)

local ID_PAT = "^" .. ("[%u%d]"):rep(7) .. ("%-" .. ("[%u%d]"):rep(7)):rep(7) .. "$"
local function is_id(x) return type(x) == "string" and x:match(ID_PAT) ~= nil end
local function stid(a) return (a .. ("-" .. a:sub(1, 1):rep(7)):rep(7)) end
local STUDIO, SONG, SECRET = "studiosync-jl-0001", "Song", "S3CRET-studio-key-0001"
local ANN_DEV, JO_DEV, EVE_DEV, BO_DEV = stid("AAAAAAA"), stid("JJJJJJJ"), stid("EEEEEEE"), stid("BBBBBBB")
local SUFFIX = "tail1234.ts.net"
local clock = 1000

-- the stand-in sealing: "SSS1" + the key it's for + the text's bytes turned (opens only with that key's file; the real one: nat_test.cpp)
local function nat_pub(path) return sha("nat " .. path) end
local function turn(s, k) local out = {}; for i = 1, #s do out[i] = string.format("%02x", s:byte(i) ~ k:byte((i - 1) % #k + 1)) end; return table.concat(out) end
local function unturn(h, k) local out, i = {}, 0; for x in h:gmatch("%x%x") do i = i + 1; out[i] = string.char(tonumber(x, 16) ~ k:byte((i - 1) % #k + 1)) end; return table.concat(out) end

-- the stand-in link: computers by their Tailscale names; everything that went over it, for the secret check
local net, wire = {}, {}
-- (REAPER's directory listing: read once per listing, as REAPER caches it until it's asked again from -1)
local function enum_of(c, dir, i, dirs)
  local k = (dirs and "d" or "f") .. dir
  c.lists = c.lists or {}
  if i < 0 then c.lists[k] = nil; return nil end
  if i == 0 or not c.lists[k] then
    local t = {}
    for f in tostring(list_of(dir, dirs)):gmatch("[^\n]+") do t[#t + 1] = f end
    c.lists[k] = t
  end
  return c.lists[k][i + 1]
end
local base = {}
for k in pairs(package.loaded) do base[k] = true end
local function computer(name, dev, letter)
  local c = { name = name, dev = dev, ts = name:lower() .. "." .. SUFFIX, root = T .. "/" .. name .. "/studio", res = T .. "/" .. name .. "/res",
    ext = {}, mods = {}, started = {}, polls = {}, seq = 0, inn = {}, logs = {}, kp = T .. "/" .. name .. "/device-key", ik = T .. "/" .. name .. "/invite-key",
    natkey = T .. "/" .. name .. "/nat-key" }
  write(c.natkey, "key\n")
  c.cfg = { root = c.root, user = name }
  local function deliver(peers, ch, fn)
    for peer in tostring(peers):gmatch("%S+") do
      local to = net[peer:match("^(.-):%d+$") or ""]
      local mine, theirs = c.started[ch], to and to.started[ch]
      if theirs and mine and theirs.port and theirs.port > 0 and theirs.secret == mine.secret then fn(to, theirs) end
    end
  end
  c.reaper = setmetatable({
    time_precise = function() return clock end, GetOS = function() return "Linux" end, GetResourcePath = function() return c.res end,
    GetExtState = function(_, k) return c.ext[k] or "" end, SetExtState = function(_, k, v) c.ext[k] = tostring(v) end,
    DeleteExtState = function(_, k) c.ext[k] = nil end,
    EnumerateFiles = function(dir, i) return enum_of(c, dir, i, false) end,
    EnumerateSubdirectories = function(dir, i) return enum_of(c, dir, i, true) end,
    RecursiveCreateDirectory = function(d) mkdirs(d); return 1 end,
    file_exists = function(p) return size(p) ~= nil end,
    genGuid = function() local t = {}; for i = 1, 32 do t[i] = string.format("%x", math.random(0, 15)) end; return "{" .. table.concat(t) .. "}" end,
    EnumProjects = function() return nil end,
    StudioSync_KeyCreate = function(p) return py_key(sr, p) end,
    StudioSync_Sign = function(kp, m) return py_sign(sr, kp, m) end,
    StudioSync_Verify = function(s, m, k) local ok, r = pcall(py_verify, sr, s, m, k); return ok and r and 1 or 0 end,
    StudioSync_NatKey = function(p) return size(p) and nat_pub(p) or "" end, StudioSync_NatSetup = function() return 0 end, StudioSync_NatStatus = function() return "{}" end,
    StudioSync_Seal = function(pub, text) if not tostring(pub):match("^%x+$") or #pub ~= 64 then return "" end return "SSS1" .. pub .. turn(text, pub) end,
    StudioSync_Unseal = function(path, sealed)
      local pub, body = tostring(sealed):match("^SSS1(%x+)(.*)$")
      if not pub or #pub < 64 or not size(path) then return "" end
      body, pub = pub:sub(65) .. body, pub:sub(1, 64)
      return pub == nat_pub(path) and unturn(body, pub) or ""
    end,
    StudioSync_DirectStart = function(ch, secret, inbox, port) c.started[ch] = { secret = secret, inbox = inbox, port = port }; return 1 end,
    StudioSync_DirectStop = function(ch) c.started[ch] = nil end,
    StudioSync_DirectMsg = function(ch, kind, data, peers)
      wire[#wire + 1] = data
      deliver(peers, ch, function(to) to.seq = to.seq + 1; to.polls[#to.polls + 1] = { to.seq, ch, kind, data } end)
      return 1
    end,
    StudioSync_DirectMsgPoll = function(after) for _, m in ipairs(c.polls) do if m[1] > after then return table.concat(m, "\t") end end; return "" end,
    StudioSync_DirectSend = function(ch, rel, path, peers)
      local body = read(path)
      if not body then return 0 end
      wire[#wire + 1] = body
      deliver(peers, ch, function(_, s) write(s.inbox .. "/" .. rel, body) end)
      return 1
    end,
    StudioSync_DirectStream = function(ch, rel, path, peers)
      local body = read(path)
      if not body then return 0 end
      wire[#wire + 1] = body
      deliver(peers, ch, function(to, s)
        local p = s.inbox .. "/.streams/" .. rel
        write(p, body)
        to.inn[#to.inn + 1] = { studio = ch, rel = rel, path = p, total = #body, bytes = #body, done = true, ok = true }
      end)
      return 1
    end,
    StudioSync_DirectStreamEnd = function() return 1 end,
    StudioSync_DirectStreams = function() return require("band").json_encode({ out = {}, ["in"] = c.inn }) end,
    StudioSync_DirectStatus = function() return "{}" end, StudioSync_DirectClock = function() return "{}" end,
  }, { __index = function() return function() return "" end end })
  c.outs = {}
  c.services = {
    is_device_id = is_id, my_device_id = function() return c.dev end, device_name = function(x) return tostring(x) end,
    my_tailscale_name = function() return c.ts .. "." end, modified_by = function() return "" end, add_device = function() return true end,
    rescan = function() end, run_hidden = function() return "" end,
  }
  c.groups = { may_manage = function(_, u) return u == "Ann" end, is_old = function() return false end, tailnet = function() return { name = "studio", suffix = SUFFIX } end,
    trusted = function() return {} end, set_tailnet = function() end }
  c.removal = { out_since = function(_, id) return c.outs[id] end, when = function() return "soon" end, mark = function() return nil end }
  c.tools = { let_in = function() c.let = (c.let or 0) + 1; return true end }
  c.trust = { from_manager_file = function() return true end }
  net[c.ts] = c
  return c
end
local current
local function use(c)
  if current ~= c then
    if current then
      current.mods = {}
      for k, v in pairs(package.loaded) do if not base[k] then current.mods[k] = v end end
    end
    for k in pairs(package.loaded) do if not base[k] then package.loaded[k] = nil end end
    for k, v in pairs(c.mods) do package.loaded[k] = v end
    for _, k in ipairs({ "services", "groups", "removal", "tools", "trust" }) do package.loaded[k] = package.loaded[k] or c[k] end
    reaper, current = c.reaper, c
  end
  local band = require("band")
  band.log = function(s) c.logs[#c.logs + 1] = s end
  require("signed").key_path = function() return c.kp end
  require("nat").key_path = function() return c.natkey end
  local joins = require("joins")
  joins.key_path = function() return c.ik end
  joins.can_make = function() return "ann." .. SUFFIX, ANN_DEV end
  return band, joins
end
local function said(c, pat) for _, l in ipairs(c.logs) do if l:find(pat) then return l end end return nil end

local A, J, E = computer("Ann", ANN_DEV), computer("Jo", JO_DEV), computer("Eve", EVE_DEV)
J.trust = nil -- (Jo's computer runs the real lib/trust.lua, and Syncthing never answers there: a boot copy is believed only by its signature)
J.services.modified_by = function() J.asked = (J.asked or 0) + 1; return nil end
local BO_KP = T .. "/Bo-key"
local BO_PUB = py_key(sr, BO_KP)
local ROOT_A, ROOT_J = A.root, J.root

-- ---- Ann's studio: signed _band files, a song whose main room has a history, its media ------------------------------------------------------
local band, joins = use(A)
A.ext.user, A.ext.sync_root = "Ann", ROOT_A
local function wj(p, t) mkdirs(p:match("^(.*)/[^/]+$")); band.write_json(p, t) end
band.pin_id(ROOT_A, STUDIO)
wj(ROOT_A .. "/_band/band.json", { id = STUDIO, name = "Joinlink", owner = "Ann", admins = { "Bo" }, sonobus = SECRET, managers = { Ann = { ANN_DEV } } })
wj(ROOT_A .. "/_band/devices/Ann.json", { user = "Ann", device = ANN_DEV, key = py_key(sr, A.kp) })
-- written on Bo's computer (signed with Bo's key): his devices file, a forged one naming Ann's computer, and roles.json making himself owner
local sw = require("signedwrites")
local function bo_writes(rel, t)
  local bytes = band.json_encode(t)
  write(ROOT_A .. "/" .. rel, bytes)
  write(ROOT_A .. "/" .. rel .. ".sig", sw.make(function(m) return py_sign(sr, BO_KP, m) end, BO_PUB, STUDIO, rel, os.time() * 1000, bytes))
end
bo_writes("_band/devices/Bo.json", { user = "Bo", device = BO_DEV, key = BO_PUB })
bo_writes("_band/devices/Mallory.json", { user = "Mallory", device = ANN_DEV })
bo_writes("_band/roles.json", { owner = "Bo", admins = { "Ann" } })
require("signed").note_key(ROOT_A, BO_DEV, BO_PUB) -- (Ann's computer believed Bo's devices file once, the usual way)
wj(ROOT_A .. "/_band/removed/Moe.json", { user = "Moe", device = stid("MMMMMMM"), at = 5, by = "Ann" })
wj(ROOT_A .. "/_band/names.json", {})
write(ROOT_A .. "/" .. SONG .. "/session.json", band.json_encode({ song = SONG, host = "Ann", srate = 48000, version = 3, published = "2026-11-20T10:00:00Z" }))
wj(ROOT_A .. "/" .. SONG .. "/rooms/main/mode.json", { mode = "open", by = "Ann" })
check(read(ROOT_A .. "/_band/band.json.sig") and read(ROOT_A .. "/" .. SONG .. "/rooms/main/mode.json.sig"), "Ann's studio files are signed as they're written")

local EV = ROOT_A .. "/" .. SONG .. "/rooms/main/events/"
local all, n_ev = {}, 0
local function ev(t)
  n_ev = n_ev + 1
  t.id = t.id or string.format("%s-20261101-%06dZ-%05d-0001", t.user or "Ann", 100000 + n_ev, n_ev)
  t.time = t.time or string.format("2026-11-01T10:%02d:%02dZ", (n_ev // 60) % 60, n_ev % 60)
  t.user = t.user or "Ann"
  t.hlc = t.hlc or (1700000000000 + n_ev)
  write(EV .. t.id .. ".json", band.json_encode(t))
  all[#all + 1] = t
  return t
end
local MEDIA = {}
for k = 1, 12 do
  local f = string.format("take-%02d.flac", k)
  local bytes = ("fLaC" .. string.rep(string.char(k), 8192 * k)):sub(1, 4096 + 8192 * k)
  write(ROOT_A .. "/" .. SONG .. "/rooms/main/media/" .. f, bytes)
  MEDIA[f] = bytes
end
-- 60 tracks and 120 items, four changes each (a straight line of versions), the items playing the takes
for i = 1, 180 do
  local oid = (i <= 60 and "T" or "I") .. string.format("-ANN-20261101-%04d", i)
  local prev
  for rev = 1, 4 do
    local state = i <= 60 and { name = "Track " .. i, vol = rev } or ('<ITEM\nPOSITION ' .. rev .. '\n<SOURCE FLAC\nFILE "{media:main}/take-' .. string.format("%02d", (i % 12) + 1) .. '.flac"\n>\n>')
    prev = ev({ type = "obj", obj = i <= 60 and "track" or "item", oid = oid, rev = rev, base = rev - 1, base_ev = prev and prev.id or nil, state = state })
  end
end
-- one item two people changed apart from the same version: both kept for the joiner's merge
local r1 = ev({ type = "obj", obj = "item", oid = "I-ANN-20261101-9999", rev = 1, state = '<ITEM\nPOSITION 1\n>' })
ev({ type = "obj", obj = "item", oid = "I-ANN-20261101-9999", rev = 2, base = 1, base_ev = r1.id, state = '<ITEM\nPOSITION 2\n>', user = "Ann" })
ev({ type = "obj", obj = "item", oid = "I-ANN-20261101-9999", rev = 2, base = 1, base_ev = r1.id, state = '<ITEM\nPOSITION 3\n>', user = "Bo" })
-- a deleted item: its newest (the deletion) only
local d1 = ev({ type = "obj", obj = "item", oid = "I-ANN-20261101-8888", rev = 1, state = '<ITEM\nFILE "{media:main}/gone.flac"\n>' })
ev({ type = "obj", obj = "item", oid = "I-ANN-20261101-8888", rev = 2, base = 1, base_ev = d1.id, gone = true })
for k = 1, 3 do ev({ type = "timeline", tempo = { { time = 0, bpm = 100 + k } } }) end
for _ = 1, 20 do ev({ type = "start" }); ev({ type = "stop" }) end
ev({ type = "note", text = "nice" })
ev({ type = "driver", driver = "Ann" })

-- ---- Ann makes an invitation; Jo pastes it and asks ------------------------------------------------------------------------------------------
local now = os.time()
local text, tok = joins.make(ROOT_A, "member", now)
check(text and tok, "Ann makes an invitation")
joins.tick(now) -- (the ask channel opens: an invitation is open here)
check(A.started[joins.CHANNEL] and A.started[joins.CHANNEL].port > 0, "Ann listens for asks while it's open")

band, joins = use(J)
J.ext.user, J.ext.sync_root, J.ext.bands = "Jo", ROOT_J, ROOT_J
mkdirs(ROOT_J)
write(ROOT_J .. "/.stignore", "")
band.pin_id(ROOT_J, STUDIO)
band.set_ext_json(band.SECTION, "joining " .. ROOT_J, { name = "Joinlink", id = STUDIO }, true)
require("trust").set_inviter(ROOT_J, ANN_DEV) -- (services.join_band: the computer the code came from)
local function waiting() for _, x in ipairs(band.bands()) do if x.root == ROOT_J then return x.waiting == true end end end
check(waiting(), "before: Jo's studio is waiting")
local t0 = os.clock()
check(joins.request(ROOT_J, joins.parse(text)), "Jo asks over the link")
local pend = band.ext_json(band.SECTION, "joins pending")[ROOT_J]
check(pend and #pend.nonce == 32, "the ask's nonce is kept with the pending invitation")
check(J.started["join-" .. tok.id].inbox == band.home() .. "/direct/" .. STUDIO, "Jo listens on the invitation's channel into the studio's link inbox")

-- ---- Ann lets Jo in and sends the first copy ---------------------------------------------------------------------------------------------
band, joins = use(A)
clock = clock + 2
joins.tick(now + 1)
check(A.let == 1, "Ann's computer lets Jo in (the invitation's checks, as before)")
local bound = band.ext_json(band.SECTION, "join bound " .. tok.id)
check(bound and bound.key == nat_pub(J.natkey) and bound.reply == J.ts, "the key and Tailscale name Jo asked with are bound to the invitation")
local job = require("joinboot").jobs[tok.id]
check(job and job.song == SONG and #job.media == 12, "the song's changes and its 12 media files are queued for Jo: " .. tostring(job and #job.media))
local welcome
for _, m in ipairs(J.polls) do if m[3] == "welcome" then welcome = m end end
check(welcome and welcome[2] == "join-" .. tok.id, "the welcome went to Jo on the invitation's channel")
check(band.json_decode(welcome[4]).sealed:sub(1, 4) == "SSS1", "sealed")
-- both computers' Autostart ticks (every 2 s), in turn, until Jo's can play the song
local jb, st, rounds, bytes0 = nil, nil, 1, 0
for _, x in ipairs(wire) do bytes0 = bytes0 + #x end
repeat
  band, joins = use(J)
  jb = require("joinboot")
  clock = clock + 2
  joins.tick(now + 2 * rounds)
  st = jb.state(ROOT_J)
  if st and st.playable then break end
  band, joins = use(A)
  joins.tick(now + 2 * rounds + 1)
  rounds = rounds + 1
until rounds > 20
local took = os.clock() - t0
check(st and st.playable, "Jo's computer has the song playable: " .. band.json_encode(st or {}))
check(said(J, "is ready to play"), "and says so")
local bytes = 0
for _, x in ipairs(wire) do bytes = bytes + #x end
local c0 = os.clock()
local compacted = #require("joinboot").compact(all)
local compact_s = os.clock() - c0
print(string.format("time to playable (stand-in song: %d changes kept of %d, 12 media files; %d KB over the link): let-in plus %d tick rounds " ..
  "(Autostart's 2 s: ~%d s plus the link's transfer time), %.2f s of work here with the stand-ins (Ed25519 in Python); compacting %d changes " ..
  "to %d: %.3f s", st.events, #all, bytes // 1024, rounds, 2 * rounds, took, #all, compacted, compact_s))
band, joins = use(A)
clock = clock + 2
joins.tick(now + 2 * rounds + 3) -- (its last tick: the streams it started are done)
check(require("joinboot").jobs[tok.id] == nil and said(A, "the first copy of 'Song' went"), "all of it went: " .. tostring(said(A, "first copy")))
band, joins = use(J)
check(joins.state(ROOT_J) == "in" and not band.ext_json(band.SECTION, "joins pending")[ROOT_J], "the invitation is used up here: let in")

for _, rel in ipairs({ "_band/band.json", "_band/band.json.sig", "_band/roles.json", "_band/devices/Bo.json", "_band/devices/Bo.json.sig", "_band/removed/Moe.json",
  "_band/names.json", SONG .. "/session.json", SONG .. "/rooms/main/mode.json", SONG .. "/rooms/main/mode.json.sig" }) do
  check(band.read(ROOT_J .. "/" .. rel) == read(ROOT_A .. "/" .. rel), "Jo reads Ann's " .. rel)
  check(not read(ROOT_J .. "/" .. rel), "and nothing of it is in Jo's folder: " .. rel)
end
check(band.read(ROOT_J .. "/_band/joins/" .. tok.id .. ".json") == nil, "only the files a welcome may carry")
check(not waiting(), "Jo's studio isn't waiting any more")
check(band.info(ROOT_J).name == "Joinlink" and band.read_json(ROOT_J .. "/_band/band.json").sonobus == SECRET, "band.info and the studio's secret read from it")
local songs = band.songs({ root = ROOT_J })
check(#songs == 1 and songs[1] == SONG, "the song is on Jo's Projects list")
local s1, side1, linked = require("signed").current(ROOT_J, "_band/band.json")
check(s1 == read(ROOT_A .. "/_band/band.json") and side1 == read(ROOT_A .. "/_band/band.json.sig") and linked,
  "signed.current sees the copy and its signature, as one Syncthing knows nothing of")
-- Jo's trust: each boot copy by its signature and the keys the welcome brought (never by Syncthing's silence)
local trust, signed = require("trust"), require("signed")
check(signed.computer_of(ROOT_J, sw.device_id(BO_PUB)) == BO_DEV and signed.computer_of(ROOT_J, sw.device_id(py_key(sr, A.kp))) == ANN_DEV,
  "the welcome's keys: Ann's computer's own, and Bo's as Ann's computer knows it")
check(signed.seed_keys(ROOT_J, { [BO_DEV] = sw.device_id(py_key(sr, E.kp)) }) == 0 and signed.computer_of(ROOT_J, sw.device_id(BO_PUB)) == BO_DEV,
  "a key already noted is never replaced by a welcome's")
local owner, admins = trust.roles(ROOT_J, band.read_json(ROOT_J .. "/_band/band.json"))
check(owner == "Ann" and admins[1] == "Bo" and not trust.held(ROOT_J), "first look: band.json, signed by the computer that let Jo in, is believed: " .. tostring(owner))
check(trust.device_ok(ROOT_J, "Bo", BO_DEV) == true, "Bo's devices file, signed by Bo's computer: believed")
check(trust.device_ok(ROOT_J, "Mallory", ANN_DEV) == false, "a devices file naming Ann's computer, signed by Bo's: set aside")
owner = trust.roles(ROOT_J, band.read_json(ROOT_J .. "/_band/band.json"))
check(owner == "Ann", "roles.json from an admin's computer making himself owner: set aside, as Syncthing's copy would be")
check((J.asked or 0) == 0, "and Syncthing was never asked about a boot copy")

-- the song's state: each object's newest change, every change of the one edited apart, the newest tempo map, no cues
local inbox = band.home() .. "/direct/" .. STUDIO .. "/" .. SONG .. "/rooms/main/events/"
local have = {}
for f in tostring(list_of(inbox, false)):gmatch("[^\n]+") do have[f:sub(1, -6)] = band.json_decode(read(inbox .. f)) end
local mirror = require("mirror")
local function newest(list, oid)
  local top
  for _, e in pairs(list) do
    if e.type == "obj" and e.oid == oid and (not top or mirror.newer({ rev = e.rev, time = mirror.order_of(e), user = e.user }, { rev = top.rev, time = mirror.order_of(top), user = top.user })) then top = e end
  end
  return top
end
local oids, n_obj = {}, 0
for _, e in ipairs(all) do if e.type == "obj" and not oids[e.oid] then oids[e.oid] = true; n_obj = n_obj + 1 end end
for oid in pairs(oids) do check(newest(have, oid) and newest(have, oid).id == newest(all, oid).id, "Jo's newest change of " .. oid .. " is everyone's") end
local rivals = 0
for _, e in pairs(have) do if e.oid == "I-ANN-20261101-9999" then rivals = rivals + 1 end end
check(rivals == 3, "the item two people edited apart: all three of its changes (receive merges them as everyone's did)")
local tl, cues, other = 0, 0, 0
for _, e in pairs(have) do
  if e.type == "timeline" then tl = tl + 1; check(e.tempo[1].bpm == 103, "the newest tempo map") end
  if e.type == "start" or e.type == "stop" then cues = cues + 1 end
  if e.type == "note" or e.type == "driver" then other = other + 1 end
end
check(tl == 1 and cues == 0 and other == 2, "one tempo map, no cues, the note and the driver change")
local kept = 0
for _ in pairs(have) do kept = kept + 1 end
check(kept == n_obj - 1 + 3 + 1 + 2 and kept < #all / 3, "compact: " .. kept .. " of " .. #all .. " changes")
for f, bytes in pairs(MEDIA) do check(read(ROOT_J .. "/" .. SONG .. "/rooms/main/media/" .. f) == bytes, "media placed byte for byte: " .. f) end
check(not read(ROOT_J .. "/" .. SONG .. "/rooms/main/media/gone.flac"), "a deleted item's media isn't sent")
local boot_rel = band.home() .. "/direct/" .. STUDIO .. "/" .. SONG .. "/rooms/main/.boot"
check(read(boot_rel), "the inbox keeps these past its day (the link's prune)")
local direct = require("direct")
direct.prune({ root = ROOT_J })
local still = 0
for _ in tostring(list_of(inbox, false)):gmatch("[^\n]+") do still = still + 1 end
check(still == kept, "pruned: the first copy's old changes stay until Syncthing's copies come")

-- ---- the secret: sealed, never in the clear ------------------------------------------------------------------------------------------------
for _, w in ipairs(wire) do check(not tostring(w):find(SECRET, 1, true), "the studio's secret never goes over the link in the clear") end
local sealed = band.json_decode(welcome[4]).sealed
check(reaper.StudioSync_Unseal(J.natkey, sealed):find(SECRET, 1, true), "Jo's key opens the welcome (the secret is in it)")
check(reaper.StudioSync_Unseal(E.natkey, sealed) == "", "Eve's key doesn't")
band, joins = use(E) -- (Eve holds the token too, and puts it in her own pending: the sealed welcome isn't hers)
E.ext.user = "Eve"
local pe = { token = text, nonce = pend.nonce }
local w, why = require("joinboot").take(E.root, joins.parse(text), pe, sealed)
check(not w and why:find("not sealed to this computer"), "Eve can't take Jo's welcome: " .. tostring(why))

-- ---- refusals ------------------------------------------------------------------------------------------------------------------------------
-- a replayed welcome: after it was taken (no ask pending), and to a later ask of Jo's (another nonce)
band, joins = use(J)
local logs0 = #J.logs
check(joins.on_welcome(tok.id, band.json_decode(welcome[4])) == false, "a replayed welcome after it was taken: nothing")
band.set_ext_json(band.SECTION, "joins pending", { [ROOT_J] = { token = text, nonce = string.rep("ab", 16) } }, true)
check(joins.on_welcome(tok.id, band.json_decode(welcome[4])) == false and said(J, "replayed welcome"), "replayed to a later ask: refused")
band.set_ext_json(band.SECTION, "joins pending", {}, true)
check(#J.logs > logs0, "and said")

-- another computer with the used token; an ask naming Jo's device with another key: nothing sent anywhere (another invitation open on
-- Ann's computer, so asks are read at all)
band, joins = use(A)
check(joins.make(ROOT_A, "member", now), "a second invitation, still open")
local ask_at = now + 4
local function ask_from(c, dev, key)
  local before = #wire
  c.seq = c.seq
  A.seq = A.seq + 1
  A.polls[#A.polls + 1] = { A.seq, joins.CHANNEL, "join", band.json_encode({ token = text, device = dev, name = "x", reply = c.ts, key = key, nonce = string.rep("cd", 16) }) }
  clock, ask_at = clock + 2, ask_at + 20 -- (a refusal is said at most every 10 s)
  joins.tick(ask_at)
  return #wire - before
end
local lets = A.let
check(ask_from(E, EVE_DEV, nat_pub(E.natkey)) == 0 and A.let == lets and said(A, "used already"), "another computer with Jo's used invitation: refused, nothing sent")
check(ask_from(E, JO_DEV, nat_pub(E.natkey)) == 0 and said(A, "replayed ask"), "Jo's device named with Eve's key (to Eve's address): refused, nothing sent")
check(ask_from(J, JO_DEV, nat_pub(J.natkey)) == 1, "Jo asking again with its own key: the welcome again (one message), to Jo")
-- Jo taken out: asking again gets nothing; a first copy still going stops
A.outs[JO_DEV] = "Jo"
clock = clock + 10
check(ask_from(J, JO_DEV, nat_pub(J.natkey)) == 0 and said(A, "taken out since"), "taken out: Jo asking again gets nothing (never the secret)")
local jb_a = require("joinboot")
jb_a.jobs.x = { root = ROOT_A, song = SONG, channel = "join-" .. tok.id, peer = J.ts .. ":47281", device = JO_DEV, made = now, events = { { ev = all[1], path = EV .. all[1].id .. ".json" } }, media = {}, ei = 1, mi = 1, at = clock }
local before = #wire
jb_a.maker_tick()
check(jb_a.jobs.x == nil and #wire == before and said(A, "stopped sending"), "a first copy still going to a computer taken out stops")
A.outs[JO_DEV] = nil
-- no sealing on the maker (an older extension): today's welcome, no first copy
local seal = reaper.StudioSync_Seal
reaper.StudioSync_Seal = nil
local r0 = { token = text, device = JO_DEV, name = "Jo", reply = J.ts, key = nat_pub(J.natkey), nonce = string.rep("ef", 16) }
check(jb_a.send(ROOT_A, joins.parse(text), r0, { made = now }, now + 100) == false, "without the extension's sealing: no first copy (today's welcome then)")
reaper.StudioSync_Seal = seal
r0.key = nil
check(jb_a.send(ROOT_A, joins.parse(text), r0, { made = now }, now + 200) == false, "an ask without a key (an older joiner): no first copy")

-- ---- Syncthing arrives: a no-op ------------------------------------------------------------------------------------------------------------
band, joins = use(J)
jb = require("joinboot")
local seen = {}
for _, rel in ipairs({ "_band/band.json", "_band/roles.json", SONG .. "/session.json", SONG .. "/rooms/main/mode.json" }) do seen[rel] = band.read(ROOT_J .. "/" .. rel) end
local songs_before = band.json_encode(band.songs({ root = ROOT_J }))
local function copy_tree(from, to)
  for f in tostring(list_of(from, false)):gmatch("[^\n]+") do if not read(to .. "/" .. f) then write(to .. "/" .. f, read(from .. "/" .. f)) end end
  for d in tostring(list_of(from, true)):gmatch("[^\n]+") do copy_tree(from .. "/" .. d, to .. "/" .. d) end
end
copy_tree(ROOT_A, ROOT_J)
clock = clock + 20
for rel, was in pairs(seen) do check(band.read(ROOT_J .. "/" .. rel) == was, "Syncthing's copy reads the same: " .. rel) end
check(band.json_encode(band.songs({ root = ROOT_J })) == songs_before and not waiting(), "the same Projects list, not waiting")
jb.joiner_tick(os.time())
local bdir = jb.dir(STUDIO)
check(not read(bdir .. "/_band/band.json") and not read(bdir .. "/" .. SONG .. "/session.json"), "the boot copies go once Syncthing's are here")
direct.prune({ root = ROOT_J })
check(tostring(list_of(inbox, false)) == "", "the inbox's copies go too (Syncthing's are the record)")
for f, bytes in pairs(MEDIA) do check(read(ROOT_J .. "/" .. SONG .. "/rooms/main/media/" .. f) == bytes, "media untouched: " .. f) end
check(jb.state(ROOT_J).playable, "still playable")
jb.joiner_tick(os.time() + jb.GRACE + 1)
check(band.ext_json(band.SECTION, "join boots")[ROOT_J] == nil and band.read(ROOT_J .. "/_band/band.json") == read(ROOT_A .. "/_band/band.json"),
  "the store retires a while after Syncthing brought band.json; the folder's copy reads on")
-- a boot copy is never read past KEEP, and never for a file outside what a welcome may carry
check(jb.rel_ok("_band/band.json.sig") and not jb.rel_ok("_band/joins/x.json") and not jb.rel_ok("../x/session.json") and not jb.rel_ok("Song/rooms/main/events/x.json"),
  "what a boot copy may be")

clean()
print("ok")
