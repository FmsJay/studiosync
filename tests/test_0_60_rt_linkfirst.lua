-- Signed writes wired in beside Syncthing's check, and those files over the direct link (lib/signed.lua, lib/trust.lua, docs/rt/rt-linkfirst.md).
-- Two stand-in computers in one Lua state, each with its own folder, saved state, Syncthing answers and copy of every module: Ann (an admin)
-- and Bee (a member). Checked: a manager's signed file taken without asking Syncthing; a member's signed file, a forged signer, a replayed
-- older number and a made-up id sharing a manager's first 7 characters refused; unsigned and stale-signed files still go by Syncthing (the
-- migration); writes signed and a removal's tombstone; Ann's grant reaching Bee over the link and counting there at once, then the Syncthing
-- copy taking over; a link copy refused unsigned, wrongly signed, from a member, from an unknown key, or older. Ed25519 is
-- tools/sign_release.py's (the extension's twin, tests/sign_cross.py), through lupa's `python`. Lupa, repo root. (rt-linkfirst)
package.path = "lib/?.lua;" .. package.path
local T = (os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"):gsub("\\", "/") .. "/ss_linkfirst_" .. os.time() .. "_" .. math.random(100000, 999999)
local SEP = package.config:sub(1, 1)
local function clean() os.execute(SEP == "\\" and ('rmdir /s /q "' .. T:gsub("/", "\\") .. '" 2>nul') or ("rm -rf '" .. T .. "'")) end
local function check(cond, what) if not cond then clean(); error(what, 2) end end

python.eval("__import__('sys').path.insert(0, 'tools')")
local sr = python.eval("__import__('sign_release')")
local py_sign = python.eval("lambda sr, kp, m: sr.sign(sr.load_seed(kp), m.encode('utf-8')).hex()")
local py_key = python.eval("lambda sr, kp: sr.public_key(sr.new_key(kp)).hex()")
local py_verify = python.eval("lambda sr, s, m, k: sr.verify(bytes.fromhex(k), m.encode('utf-8'), bytes.fromhex(s))")
local mkdirs = python.eval("lambda d: __import__('os').makedirs(d, exist_ok=True)")
local listdir = python.eval("lambda d: '\\n'.join(f for f in sorted(__import__('os').listdir(d)) if __import__('os').path.isfile(d + '/' + f)) if __import__('os').path.isdir(d) else ''")
local function verify(s, m, k) local ok, r = pcall(py_verify, sr, s, m, k); return ok and r == true end
local function read(p) local f = io.open(p, "rb"); if not f then return nil end local s = f:read("a"); f:close(); return s end
local function write(p, s) mkdirs(p:match("^(.*)/[^/]+$")); local f = assert(io.open(p, "wb")); f:write(s); f:close() end
mkdirs(T)

local ID = "^" .. ("[%u%d]"):rep(7) .. ("%-" .. ("[%u%d]"):rep(7)):rep(7) .. "$"
local function is_id(x) return type(x) == "string" and x:match(ID) ~= nil end
local function stid(a, rest) return (a .. ("-" .. (rest or a:sub(1, 1):rep(7))):rep(7)) end
local STUDIO, SONG, ROOM = "studio-lf1", "Song", "main"
local clock = 1000

-- people: each a key, a Syncthing id
local function person(name, letter)
  local kp = T .. "/" .. name .. "-key"
  local pub = py_key(sr, kp)
  return { name = name, kp = kp, pub = pub, dev = stid(letter:rep(7)), sign = function(m) return py_sign(sr, kp, m) end }
end
local olive, ann, moe, bee = person("Olive", "O"), person("Ann", "A"), person("Moe", "M"), person("Bee", "B")

-- computers: a folder, saved state, Syncthing's answers, their own modules
local base = {}
for k in pairs(package.loaded) do base[k] = true end
local function computer(who)
  local c = { who = who, root = T .. "/" .. who.name .. "/studio", ext = {}, by_file = {}, gone = {}, asked = 0, mods = {} }
  c.cfg = { root = c.root, user = who.name }
  c.reaper = setmetatable({
    time_precise = function() return clock end, GetOS = function() return "Win64" end,
    GetExtState = function(_, k) return c.ext[k] or "" end, SetExtState = function(_, k, v) c.ext[k] = tostring(v) end,
    DeleteExtState = function(_, k) c.ext[k] = nil end,
    EnumerateFiles = function(dir, i)
      if i < 0 then return nil end
      local list = {}
      for f in tostring(listdir(dir)):gmatch("[^\n]+") do list[#list + 1] = f end
      return list[i + 1]
    end,
    EnumerateSubdirectories = function() return nil end,
    RecursiveCreateDirectory = function(d) mkdirs(d); return 1 end,
    file_exists = function(p) return read(p) ~= nil end,
    StudioSync_KeyCreate = function(p) return py_key(sr, p) end,
    StudioSync_Sign = function(kp, m) return py_sign(sr, kp, m) end,
    StudioSync_Verify = function(s, m, k) return verify(s, m, k) and 1 or 0 end,
  }, { __index = function() return function() return "" end end })
  c.services = {
    is_device_id = is_id, my_device_id = function() return who.dev end, device_name = function(x) return tostring(x) end,
    modified_by = function(_, rel) c.asked = c.asked + 1; return c.by_file[rel], c.gone[rel] end,
  }
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
    package.loaded.services = package.loaded.services or c.services
    if c.direct then package.loaded.direct = c.direct end
    reaper, current = c.reaper, c
  end
  local band = require("band")
  band.log = function(s) c.logged = s end
  require("signed").key_path = function() return c.who.kp end
  return band
end
local A, B = computer(ann), computer(bee)

-- the same studio in both folders: Olive owns it, Ann is an admin; each person's devices file carries their key (older StudioSync: unsigned)
local function json(t) return require("band").json_encode(t) end
local function pins_key(root) return "role pins " .. STUDIO .. " " .. root:gsub("\\", "/"):gsub("/+$", ""):lower() end
for _, c in ipairs({ A, B }) do
  local band = use(c)
  write(c.root .. "/_band/band.json", json({ id = STUDIO, name = "LF", owner = "Olive", admins = { "Ann" } }))
  for _, p in ipairs({ olive, ann, moe, bee }) do
    write(c.root .. "/_band/devices/" .. p.name .. ".json", json({ user = p.name, device = p.dev, key = p.pub }))
    c.by_file["_band/devices/" .. p.name .. ".json"] = p.dev:sub(1, 7)
  end
  write(c.root .. "/" .. SONG .. "/rooms/" .. ROOM .. "/mode.json", json({ mode = "admins", by = "Olive" }))
  band.set_ext_json(band.SECTION, pins_key(c.root), { owner = "Olive", admins = { "Ann" }, devices = { Olive = { olive.dev }, Ann = { ann.dev } } }, true)
  c.ext.user = c.who.name
end

-- ---- keys are learnt only the way devices files have always been believed --------------------------------------------------------------------
local band = use(B)
local trust, signed, sw = require("trust"), require("signed"), require("signedwrites")
check(signed.computer_of(B.root, sw.device_id(ann.pub)) == nil, "no key is anyone's before its devices file is believed")
for _, p in ipairs({ olive, ann, moe }) do check(trust.device_ok(B.root, p.name, p.dev) == true, p.name .. "'s devices file, by Syncthing") end
check(signed.computer_of(B.root, sw.device_id(ann.pub)) == ann.dev, "and then Ann's key is Ann's computer (whole id)")
check(signed.computer_of(B.root, sw.device_id(bee.pub)) == bee.dev, "this computer's own key is this computer")

local function put(c, rel, bytes, signer, seq, deleted)
  if bytes then write(c.root .. "/" .. rel, bytes) else os.remove(c.root .. "/" .. rel) end
  if signer then write(c.root .. "/" .. rel .. ".sig", sw.make(signer.sign, signer.pub, STUDIO, rel, seq, bytes, deleted)) end
end
local NOW = os.time() * 1000

-- ---- a manager's signed file: taken by the signature, Syncthing not asked -------------------------------------------------------------------
local GA = "_band/guest-access/G1.json"
put(B, GA, json({ device = moe.dev, songs = { "Song" }, by = "Ann", at = 1 }), ann, NOW + 1)
B.asked = 0
local ok, by = trust.from_manager_file(B.root, GA)
check(ok == true and by == ann.dev and B.asked == 0, "Ann's signed guest list is a manager's, without asking Syncthing: " .. tostring(ok) .. " " .. tostring(by))
-- a member's signature (her key known): hers, so refused, whatever the file says
put(B, GA, json({ device = moe.dev, songs = { "Song", "Other" }, by = "Ann", at = 2 }), moe, NOW + 2)
ok, by = trust.from_manager_file(B.root, GA)
check(ok == false and by == moe.dev, "signed by Moe (a member): refused")
-- a forged signer: a sidecar naming Ann's id over Moe's key is no signature, so Syncthing's word (it didn't say: not yet)
local body = json({ device = moe.dev, songs = { "All" }, by = "Ann", at = 3 })
local side = sw.make(moe.sign, moe.pub, STUDIO, GA, NOW + 3, body):gsub('"by":"[^"]+"', '"by":"' .. sw.device_id(ann.pub) .. '"')
write(B.root .. "/" .. GA, body); write(B.root .. "/" .. GA .. ".sig", side)
check(trust.from_manager_file(B.root, GA) == nil, "a sidecar claiming Ann's id over another key: no signature, and Syncthing didn't say")
B.by_file[GA] = moe.dev:sub(1, 7); clock = clock + 31 -- (Syncthing's "didn't say" is asked again after 30 s)
check(trust.from_manager_file(B.root, GA) == false, "and Syncthing says Moe wrote it: refused")
-- an unknown key (nobody's devices file names it): Syncthing's word
local stranger = person("Stranger", "S")
put(B, GA, json({ device = moe.dev, songs = { "x" }, by = "Ann", at = 4 }), stranger, NOW + 4)
B.by_file[GA] = ann.dev:sub(1, 7)
check(trust.from_manager_file(B.root, GA) == true, "a key nobody's known by yet: Syncthing says Ann's computer, so taken (the migration)")
B.by_file[GA] = moe.dev:sub(1, 7)
check(trust.from_manager_file(B.root, GA) == false, "and Syncthing saying Moe: refused")

-- ---- rollback: an older number is never a signature's word ----------------------------------------------------------------------------------
local v1 = json({ device = moe.dev, songs = { "One" }, by = "Ann", at = 10 })
local v2 = json({ device = moe.dev, songs = { "Two" }, by = "Ann", at = 11 })
B.by_file[GA] = nil
put(B, GA, v1, ann, NOW + 10)
local side1 = read(B.root .. "/" .. GA .. ".sig")
check(trust.from_manager_file(B.root, GA) == true, "Ann's first writing")
put(B, GA, v2, ann, NOW + 11)
check(trust.from_manager_file(B.root, GA) == true, "her second")
write(B.root .. "/" .. GA, v1); write(B.root .. "/" .. GA .. ".sig", side1)
B.asked = 0
check(trust.from_manager_file(B.root, GA) == nil and B.asked == 1, "her first put back: not the signature's word, Syncthing asked (it didn't say)")
B.by_file[GA] = moe.dev:sub(1, 7); clock = clock + 31 -- (Syncthing's "didn't say" is asked again after 30 s)
check(trust.from_manager_file(B.root, GA) == false, "Syncthing says Moe put it back: refused")

-- ---- whole ids: a made-up computer sharing Ann's first 7 characters --------------------------------------------------------------------------
local look = stid(ann.dev:sub(1, 7), "LOOKALK")
check(trust.is(ann.dev, look:sub(1, 7)) and not trust.is(ann.dev, look), "7 characters (Syncthing's) match the prefix; a whole id must match whole")
local pins = trust.pins(B.root)
check(trust.from_manager(pins, look:sub(1, 7)) and not trust.from_manager(pins, look), "trust.from_manager: Syncthing's short id vs a whole one")
-- Moe's computer under that id, its key learnt the usual way, signs a guest list: refused, though its first 7 are Ann's
local mal = person("Mal", "L")
mal.dev = look
write(B.root .. "/_band/devices/Mal.json", json({ user = "Mal", device = mal.dev, key = mal.pub }))
B.by_file["_band/devices/Mal.json"] = mal.dev:sub(1, 7)
check(trust.device_ok(B.root, "Mal", mal.dev) == true and signed.computer_of(B.root, sw.device_id(mal.pub)) == look, "Mal's key is the lookalike computer")
B.by_file[GA] = nil
put(B, GA, json({ device = moe.dev, songs = { "Mal" }, by = "Ann", at = 20 }), mal, NOW + 20)
check(trust.from_manager_file(B.root, GA) == false, "signed by the lookalike: refused (compared whole)")

-- ---- the migration: unsigned files, and files an older StudioSync rewrote after a signature ------------------------------------------------
local GB = "_band/guest-access/G2.json"
write(B.root .. "/" .. GB, json({ device = moe.dev, songs = {}, by = "Ann", at = 30 }))
B.by_file[GB] = ann.dev:sub(1, 7)
check(trust.from_manager_file(B.root, GB) == true, "unsigned, Syncthing says Ann's computer: taken as before")
put(B, GB, json({ device = moe.dev, songs = { "a" }, by = "Ann", at = 31 }), ann, NOW + 31)
write(B.root .. "/" .. GB, json({ device = moe.dev, songs = { "b" }, by = "Ann", at = 32 })) -- (rewritten, the sidecar not)
B.asked = 0
check(trust.from_manager_file(B.root, GB) == true and B.asked == 1, "a stale signature: Syncthing's word (Ann's computer)")
B.by_file[GB] = moe.dev:sub(1, 7)
check(trust.from_manager_file(B.root, GB) == false, "a stale signature, Syncthing says Moe: refused")

-- ---- writing signs, removing leaves a tombstone ------------------------------------------------------------------------------------------
band = use(A)
trust, signed, sw = require("trust"), require("signed"), require("signedwrites")
local GW = A.root .. "/_band/guest-access/G3.json"
mkdirs(A.root .. "/_band/guest-access"); mkdirs(A.root .. "/_band/removed"); mkdirs(A.root .. "/" .. SONG .. "/rooms/" .. ROOM .. "/events")
band.write_json(GW, { device = moe.dev, songs = { "Song" }, by = "Ann", at = 40 })
local by_, seq_, _, del_ = sw.signer(verify, STUDIO, "_band/guest-access/G3.json", read(GW), read(GW .. ".sig"))
check(by_ == sw.device_id(ann.pub) and seq_ and not del_, "a write is signed by this computer's key")
check(A.ext["signed outbox"]:find("_band/guest-access/G3.json", 1, true), "and queued for the link")
local MK = A.root .. "/_band/removed/Moe.json"
band.write_json(MK, { user = "Moe", device = moe.dev, by = "Ann", at = os.time() })
local seq_mark = select(2, sw.signer(verify, STUDIO, "_band/removed/Moe.json", read(MK), read(MK .. ".sig")))
band.remove(MK)
by_, seq_, _, del_ = sw.signer(verify, STUDIO, "_band/removed/Moe.json", nil, read(MK .. ".sig"))
check(read(MK) == nil and by_ == sw.device_id(ann.pub) and del_ and seq_ > seq_mark, "removing a removal mark leaves a signed tombstone, numbered after it")
band.write_json(A.root .. "/" .. SONG .. "/rooms/" .. ROOM .. "/events/x.json", { type = "obj" })
check(read(A.root .. "/" .. SONG .. "/rooms/" .. ROOM .. "/events/x.json.sig") == nil, "an event file isn't signed (only the studio's manager-only files)")
A.ext["signed outbox"] = ""

-- ---- Ann's grant reaches Bee over the link, and counts there at once ------------------------------------------------------------------------
-- (Ann's computer sends through a stand-in link; Bee's takes it through the real direct.dispatch, from another room: signed files are studio-wide)
local sent = {}
A.direct = { peers = function() return { "bee:47281" } end, forget_devices = function() end, studio_peers = function() return {}, {} end,
  send_live = function(_, kind, d, song, room, _, to) sent[#sent + 1] = { kind = kind, d = d, song = song, room = room, to = to }; return true end }
package.loaded.direct = A.direct
use(B)
for _, p in ipairs({ olive, ann, moe }) do trust.device_ok(B.root, p.name, p.dev) end
band = use(A)
for _, p in ipairs({ olive, bee }) do require("trust").device_ok(A.root, p.name, p.dev) end
local said, why = require("grants").set(A.cfg, SONG, ROOM, "Bee", true)
check(said, "Ann lets Bee edit in the room: " .. tostring(why))
check(require("signed").drain(A.cfg, SONG, ROOM) == 1 and #sent == 1 and sent[1].kind == "signed" and sent[1].to[1] == "bee:47281", "it goes over the link at once")
local GR = SONG .. "/rooms/" .. ROOM .. "/grants/Ann.json"
check(sent[1].d.rel == GR and sent[1].d.body == read(A.root .. "/" .. GR) and sent[1].d.side == read(A.root .. "/" .. GR .. ".sig"), "the file and its signature")
-- band.json holds the studio's secret: never over the link to someone with a removal mark, nor to a peer the link can't name
A.direct.peers = function() return { "bee:47281", "moe:47281", "who:47281" }, {}, { ["bee:47281"] = "Bee", ["moe:47281"] = "Moe" } end
write(A.root .. "/_band/removed/Moe.json", json({ user = "Moe", device = moe.dev, by = "Ann", at = os.time() }))
band.write_json(A.root .. "/_band/band.json", { id = STUDIO, name = "LF", owner = "Olive", admins = { "Ann" }, sonobus = "a-new-secret" })
require("signed").drain(A.cfg, SONG, ROOM)
check(#sent == 2 and #sent[2].to == 1 and sent[2].to[1] == "bee:47281" and sent[2].d.rel == "_band/band.json", "band.json goes to Bee alone")
table.remove(sent)
os.remove(A.root .. "/_band/removed/Moe.json")
A.direct.peers = function() return { "bee:47281" } end

band = use(B)
local grants, direct = require("grants"), require("direct")
signed = require("signed")
check(grants.list(B.cfg, SONG, ROOM).Bee == nil, "before: Bee may not edit there")
local t0 = os.clock()
local took_it
local n = direct.dispatch({ { kind = "signed", data = { song = "Other", room = "elsewhere", d = sent[1].d } } }, SONG, ROOM,
  { signed = function(d) took_it = signed.on_msg(B.cfg, d) end })
local g = grants.list(B.cfg, SONG, ROOM).Bee
check(n == 1 and took_it == true and g and g.by == "Ann", "Bee's computer takes Ann's grant from the link, sent from another room")
check(os.clock() - t0 < 1, "in under a second (here, with Ed25519 in Python): " .. (os.clock() - t0))
check(read(B.root .. "/" .. GR) == nil, "nothing written into the shared folder: Syncthing's copy is the record")
-- Syncthing's copy arrives: the link's copy goes, the folder's is read, and it still counts (signed by Ann)
write(B.root .. "/" .. GR, sent[1].d.body); write(B.root .. "/" .. GR .. ".sig", sent[1].d.side)
clock = clock + 1
check(grants.list(B.cfg, SONG, ROOM).Bee ~= nil and next(band.overlay) == nil, "Syncthing's copy takes over, and the grant stands")
-- taken back: the same way
band = use(A)
require("grants").set(A.cfg, SONG, ROOM, "Bee", false)
require("signed").drain(A.cfg, SONG, ROOM)
band = use(B)
check(signed.on_msg(B.cfg, sent[2].d) == true and grants.list(B.cfg, SONG, ROOM).Bee == nil, "Ann takes it back: gone on Bee's computer at once")
-- the earlier grant again (a replay of the link's message): older, refused
local ok2, why2 = signed.on_msg(B.cfg, sent[1].d)
check(ok2 == false and why2:find("older"), "the first grant replayed: refused (" .. tostring(why2) .. ")")
check(grants.list(B.cfg, SONG, ROOM).Bee == nil, "and Bee still may not")

-- ---- a link copy refused --------------------------------------------------------------------------------------------------------------------
local GM = SONG .. "/rooms/" .. ROOM .. "/grants/Moe.json"
local gbody = json({ by = "Moe", users = { Bee = { on = true, at = "2099-01-01T00:00:00Z" } } })
check(signed.on_msg(B.cfg, { rel = GM, body = gbody }) == false, "unsigned: refused")
local gside = sw.make(moe.sign, moe.pub, STUDIO, GM, NOW + 50, gbody)
check(signed.on_msg(B.cfg, { rel = GM, body = gbody:gsub("Bee", "Bea"), side = gside }) == false, "wrongly signed (a byte changed): refused")
local okm, whym = signed.on_msg(B.cfg, { rel = GM, body = gbody, side = gside })
check(okm == false and whym:find("may"), "Moe (a member) granting: refused by the same check as the file's (" .. tostring(whym) .. ")")
check(grants.list(B.cfg, SONG, ROOM).Bee == nil and band.overlay_of(B.root .. "/" .. GM) == nil, "and nothing of it stays")
local GS = SONG .. "/rooms/" .. ROOM .. "/grants/Olive.json" -- (a file with no number taken yet: the key is what's checked)
local sbody = json({ by = "Olive", users = { Bee = { on = true, at = "2099-01-01T00:00:00Z" } } })
local oks, whys = signed.on_msg(B.cfg, { rel = GS, body = sbody, side = sw.make(stranger.sign, stranger.pub, STUDIO, GS, NOW + 60, sbody) })
check(oks == false and whys:find("known"), "a key no computer here is known by: refused (no Syncthing to fall back on over the link)")
check(signed.on_msg(B.cfg, { rel = "Song/rooms/main/events/e.json", body = "{}", side = gside }) == false, "only the studio's own files come this way")
check(signed.on_msg(B.cfg, { rel = "../x/_band/band.json", body = "{}", side = gside }) == false, "paths stay inside the studio")

-- a room's mode: a manager's goes in at once, a member's never (nothing checks mode.json when Syncthing brings it; over the link it must be a manager's)
local MR = SONG .. "/rooms/" .. ROOM .. "/mode.json"
local sync = require("sync")
check(sync.mode(B.cfg, SONG, ROOM) == "admins", "the room is Admins only")
local mb = json({ mode = "everyone", by = "Moe" })
check(signed.on_msg(B.cfg, { rel = MR, body = mb, side = sw.make(moe.sign, moe.pub, STUDIO, MR, NOW + 70, mb) }) == false and sync.mode(B.cfg, SONG, ROOM) == "admins", "Moe's mode change: refused")
local ab = json({ mode = "open", by = "Ann" })
check(signed.on_msg(B.cfg, { rel = MR, body = ab, side = sw.make(ann.sign, ann.pub, STUDIO, MR, NOW + 71, ab) }) == true and sync.mode(B.cfg, SONG, ROOM) == "open", "Ann's: at once")

-- a removal mark taken back over the link: the owner's signed tombstone counts as a manager's deletion
local RM = "_band/removed/Moe.json"
write(B.root .. "/" .. RM, json({ user = "Moe", device = moe.dev, by = "Olive", at = 1 }))
local tomb = sw.make(olive.sign, olive.pub, STUDIO, RM, NOW + 80, nil, true)
check(signed.on_msg(B.cfg, { rel = RM, side = tomb }) == true, "Olive's tombstone for Moe's mark goes in")
check(band.read(B.root .. "/" .. RM) == nil and #band.files(B.root .. "/_band/removed", ".json") == 0, "the mark reads as gone here")
check(trust.deleted_by_manager(B.root, RM) == true, "and as deleted by someone in charge")
local mtomb = sw.make(moe.sign, moe.pub, STUDIO, "_band/removed/Bee.json", NOW + 81, nil, true)
write(B.root .. "/_band/removed/Bee.json", json({ user = "Bee", device = bee.dev, by = "Olive", at = 1 }))
check(signed.on_msg(B.cfg, { rel = "_band/removed/Bee.json", side = mtomb }) == false and band.read(B.root .. "/_band/removed/Bee.json") ~= nil, "Moe's tombstone for another's mark: refused")

-- profiles (no check guards them today): over the link unsigned, only a file whose name is its person's
local PR = "_band/profiles/Moe.json"
check(signed.on_msg(B.cfg, { rel = PR, body = json({ user = "Moe", name = "Moe M" }) }) == true and band.read_json(B.root .. "/" .. PR).name == "Moe M", "a profile, at once")
check(signed.on_msg(B.cfg, { rel = PR, body = json({ user = "Ann", name = "not Moe" }) }) == false, "a profile naming someone else than its file: refused")

-- the Syncthing path alone still works on a computer with no keys learnt (a third one)
local C = computer(olive)
band = use(C)
write(C.root .. "/_band/band.json", json({ id = STUDIO, name = "LF", owner = "Olive", admins = { "Ann" } }))
band.set_ext_json(band.SECTION, pins_key(C.root), { owner = "Olive", admins = { "Ann" }, devices = { Olive = { olive.dev }, Ann = { ann.dev } } }, true)
write(C.root .. "/" .. GR, sent[2].d.body); write(C.root .. "/" .. GR .. ".sig", sent[2].d.side)
C.by_file[GR] = ann.dev:sub(1, 7)
check(require("trust").claim_ok(C.root, GR, band.read_json(C.root .. "/" .. GR)) == true and C.asked >= 1, "Syncthing's word still counts where no key is known")

clean()
print("ok link-first signed files")
