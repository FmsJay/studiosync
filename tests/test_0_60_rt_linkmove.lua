-- More of the studio's small files over the direct link first, signed (lib/signed.lua, lib/trust.lua file_ok, docs/rt/rt-linkmove.md): given
-- claims, a driver's or manager's releases, a person's track order, their handovers of a song's hub, a song's session.json, a profile's
-- picture, and the welcome's newest sequence numbers. The rig is tests/test_0_60_rt_linkfirst.lua's: stand-in computers in one Lua state,
-- each with its own folder, saved state, Syncthing answers and copy of every module. Olive owns the studio, Ann is an admin, Bee and Moe
-- are members; Cy's computer is on an older build. For each file: it arrives by the link first and counts at once with nothing written
-- into the folder, Syncthing's copy arriving later changes nothing, it still works by Syncthing alone (unsigned, from an older build), and
-- a bad signature, someone else's signature and an older replay are refused. Ed25519 is tools/sign_release.py's. Lupa, repo root.
package.path = "lib/?.lua;" .. package.path
local T = (os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"):gsub("\\", "/") .. "/ss_linkmove_" .. os.time() .. "_" .. math.random(100000, 999999)
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
local function stid(a) return (a .. ("-" .. a:sub(1, 1):rep(7)):rep(7)) end
local STUDIO, SONG, ROOM = "studio-lm1", "Song", "main"
local RDIR = SONG .. "/rooms/" .. ROOM
local clock = 1000

local function person(name, letter)
  local kp = T .. "/" .. name .. "-key"
  local pub = py_key(sr, kp)
  return { name = name, kp = kp, pub = pub, dev = stid(letter:rep(7)), sign = function(m) return py_sign(sr, kp, m) end }
end
local olive, ann, moe, bee, cy = person("Olive", "O"), person("Ann", "A"), person("Moe", "M"), person("Bee", "B"), person("Cy", "C")
local everyone = { olive, ann, moe, bee, cy }

local base = {}
for k in pairs(package.loaded) do base[k] = true end
local function computer(who)
  local c = { who = who, root = T .. "/" .. who.name .. "/studio", ext = {}, by_file = {}, gone = {}, asked = 0, mods = {}, sent = {} }
  c.cfg = { root = c.root, user = who.name }
  c.reaper = setmetatable({
    time_precise = function() return clock end, GetOS = function() return "Win64" end,
    GetResourcePath = function() return c.res or (T .. "/" .. who.name .. "/res") end, -- (this computer's own folder: band.home, never synced)
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
  -- (the link: everything this computer sends, kept for the test to hand over)
  c.direct = { peers = function() return { "peer:47281" }, {}, { ["peer:47281"] = "Peer" } end, forget_devices = function() end,
    studio_peers = function() return {}, {} end, -- (studio-wide files to the studio's other computers too: tests/test_0_60_rt_linkmove6.lua)
    send_live = function(_, kind, d, song, room, _, to) c.sent[#c.sent + 1] = { kind = kind, d = d, song = song, room = room, to = to }; return true end }
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
    package.loaded.direct = c.direct
    reaper, current = c.reaper, c
  end
  local band = require("band")
  band.log = function(s) c.logged = s end
  require("signed").key_path = function() return c.who.kp end
  return band
end
local function json(t) return require("band").json_encode(t) end
local function pins_key(root) return "role pins " .. STUDIO .. " " .. root:gsub("\\", "/"):gsub("/+$", ""):lower() end
-- A computer in the studio: the roles pinned, everyone's devices file (each with its key) there and vouched for by Syncthing; `learn`: the
-- keys learnt the usual way (trust.device_ok), as a computer on this build has them a minute after it starts.
local function studio(c, learn)
  local band = use(c)
  write(c.root .. "/_band/band.json", json({ id = STUDIO, name = "LM", owner = "Olive", admins = { "Ann" } }))
  for _, p in ipairs(everyone) do
    write(c.root .. "/_band/devices/" .. p.name .. ".json", json({ user = p.name, device = p.dev, key = p.pub }))
    c.by_file["_band/devices/" .. p.name .. ".json"] = p.dev:sub(1, 7)
  end
  write(c.root .. "/" .. RDIR .. "/mode.json", json({ mode = "open", by = "Olive" }))
  write(c.root .. "/" .. RDIR .. "/driver.json", json({ driver = "Olive" }))
  band.set_ext_json(band.SECTION, pins_key(c.root), { owner = "Olive", admins = { "Ann" }, devices = { Olive = { olive.dev }, Ann = { ann.dev } } }, true)
  c.ext.user = c.who.name
  if learn then for _, p in ipairs(everyone) do if p ~= c.who then check(require("trust").device_ok(c.root, p.name, p.dev) == true, p.name .. "'s devices file") end end end
  c.asked = 0
  return c
end
local A, B, O = studio(computer(ann), true), studio(computer(bee), true), studio(computer(olive), true)

-- What computer `c` wrote since the last look, as the link carries it: its outbox emptied (signed.drain), the messages for `rel` (or all).
local function drained(c, rel)
  use(c)
  c.sent = {}
  require("signed").drain(c.cfg, SONG, ROOM)
  local out = {}
  for _, m in ipairs(c.sent) do if m.kind == "signed" and (not rel or m.d.rel == rel) then out[#out + 1] = m.d end end
  return out
end
-- Hand a message to computer `c` through the real direct.dispatch's shape: -> signed.on_msg's answer.
local function deliver(c, d) use(c); return require("signed").on_msg(c.cfg, d) end
-- Syncthing brings the writer's file and its signature file into `c`'s folder.
local function syncthing(c, from, rel)
  local body, side = read(from.root .. "/" .. rel), read(from.root .. "/" .. rel .. ".sig")
  if body then write(c.root .. "/" .. rel, body) else os.remove(c.root .. "/" .. rel) end
  if side then write(c.root .. "/" .. rel .. ".sig", side) end
  clock = clock + 1
end
local function overlaid(c, rel) use(c); return require("band").overlay_of(c.root .. "/" .. rel) ~= nil end
local function owner_of(c, track)
  use(c)
  local _, who = require("sync").authority(c.cfg, SONG, ROOM, nil)
  local t = who.tracks[track:lower()]
  return t and t.user or nil
end
local sw = require("signedwrites")
local function resign(signer, rel, body, seq) return sw.make(signer.sign, signer.pub, STUDIO, rel, seq, body) end
local FAR = (os.time() + 3600) * 1000 -- (a number after anything written during the test)

-- ==== 1. A given claim ==========================================================================================================================
use(A)
require("sync").give_claims(A.cfg, SONG, ROOM, "Cy", { "Bass" })
local given = drained(A)
check(#given == 1 and given[1].rel:find("^" .. RDIR .. "/claims/given%-Cy%-") and given[1].side, "Ann's given claim goes over the link, signed: " .. #given)
local GV = given[1].rel
-- a third computer (Olive's): it counts at once, nothing in the folder
check(owner_of(O, "Bass") == nil, "before: nobody's")
O.asked = 0
local ok, why = deliver(O, given[1])
check(ok == true and owner_of(O, "Bass") == "Cy" and O.asked == 0, "the given claim counts on Olive's computer at once, by its signature: " .. tostring(why))
check(read(O.root .. "/" .. GV) == nil, "nothing written into the shared folder")
-- the same message again: once only (a given claim's file is deleted without a word when it's folded in; a replay would bring it back)
local again, why_again = deliver(O, given[1])
check(again == false, "the same message again changes nothing (" .. tostring(why_again) .. ")")
-- Syncthing's copy arrives later: nothing changes
syncthing(O, A, GV)
check(owner_of(O, "Bass") == "Cy" and not overlaid(O, GV), "Syncthing's copy takes over and the claim stands")
-- Cy folded it in and deleted it (sync.follow_claims, on his computer): gone here too, and a replay of the link's message doesn't bring it back
os.remove(O.root .. "/" .. GV); os.remove(O.root .. "/" .. GV .. ".sig")
clock = clock + 1
ok, why = deliver(O, given[1])
check(ok == false and why:find("older") and owner_of(O, "Bass") == nil, "a replay after it was folded in and deleted: refused (" .. tostring(why) .. ")")

-- on a computer the file never reaches (folded and deleted before Syncthing brought it): the link's copy counts for GIVEN_KEEP seconds
use(A)
require("sync").give_claims(A.cfg, SONG, ROOM, "Bee", { "Keys" })
local given2 = drained(A)[1]
check(given2 and given2.rel ~= GV, "a second given claim")
check(deliver(O, given2) == true and owner_of(O, "Keys") == "Bee", "taken on Olive's computer")
clock = clock + require("signed").GIVEN_KEEP - 5
drained(O)
check(owner_of(O, "Keys") == "Bee", "still counted inside its minute")
clock = clock + 10
drained(O) -- (Live sync's tick: signed.drain tidies)
check(owner_of(O, "Keys") == nil and not overlaid(O, given2.rel), "and let go after it, where no file ever came")

-- the person it's for: only where lib/sync.lua's follow_claims leaves the link's copy alone (sync.GIVEN_WAITS), or it would fold it every pass
use(B)
local was_waits = require("sync").GIVEN_WAITS
require("sync").GIVEN_WAITS = nil
ok, why = deliver(B, given2)
check(ok == false and why:find("Syncthing") and owner_of(B, "Keys") == nil, "without the hook, Bee's own computer waits for Syncthing's copy (" .. tostring(why) .. ")")
require("sync").GIVEN_WAITS = true
ok, why = deliver(B, given2)
check(ok == true and owner_of(B, "Keys") == "Bee", "with it, Bee's own computer counts her given claim at once: " .. tostring(why))
clock = clock + require("signed").GIVEN_KEEP + 30
drained(B)
check(owner_of(B, "Keys") == "Bee", "and keeps it until the folder's copy comes (hers to fold in), however long")
-- (rt-edits, the hook in lib/sync.lua: follow_claims never folds the link's copy in, so it isn't folded again on every pass; the folder's
-- file is folded in once, and its signature file goes with it)
check(require("sync").GIVEN_WAITS == true or was_waits == true, "lib/sync.lua says its follow_claims leaves a link copy alone")
local function follow(c)
  local band = use(c)
  local sync, proj, said = require("sync"), {}, 0
  sync.loading[tostring(proj)] = true -- (only the given claims' part: the rest follows a project's tracks)
  band.log = function(s) if tostring(s):find("gave you", 1, true) then said = said + 1 end end
  sync.follow_claims(proj, c.cfg, SONG, ROOM)
  return said
end
local BEE_CLAIMS = B.root .. "/" .. RDIR .. "/claims/Bee.json"
check(follow(B) == 0 and follow(B) == 0 and read(BEE_CLAIMS) == nil, "the link's copy is never folded into Bee's own claims")
check(owner_of(B, "Keys") == "Bee" and overlaid(B, given2.rel), "and still counts, as the link's copy")
syncthing(B, A, given2.rel)
check(owner_of(B, "Keys") == "Bee" and not overlaid(B, given2.rel), "Syncthing's copy takes over on Bee's computer")
check(read(B.root .. "/" .. given2.rel) and read(B.root .. "/" .. given2.rel .. ".sig"), "(the folder's file and its signature file are here)")
check(follow(B) == 1, "the folder's file is folded into Bee's claims, with a word")
check((read(BEE_CLAIMS) or ""):find('"Keys"', 1, true), "her own claims file has the track")
check(read(B.root .. "/" .. given2.rel) == nil and read(B.root .. "/" .. given2.rel .. ".sig") == nil, "the given file goes, and its signature file with it")
check(follow(B) == 0, "once: not again on the next pass")
clock = clock + 3
check(owner_of(B, "Keys") == "Bee", "and it's hers, by her own claims now")
require("sync").GIVEN_WAITS = was_waits

-- refused: unsigned, a byte changed, a member's, a member signing in an admin's name, a name that isn't its person's
local GM = RDIR .. "/claims/given-Moe-20990101-000000.json"
local gm = json({ user = "Moe", by = "Ann", tracks = { "Drums" }, regions = {}, times = {}, since = {}, time = "2099-01-01T00:00:00Z", given = true })
check(deliver(O, { rel = GM, body = gm }) == false, "unsigned: refused")
check(deliver(O, { rel = GM, body = gm:gsub("Drums", "Drumz"), side = resign(ann, GM, gm, FAR) }) == false, "a byte changed: refused")
ok, why = deliver(O, { rel = GM, body = gm, side = resign(moe, GM, gm, FAR) })
check(ok == false and owner_of(O, "Drums") == nil and not overlaid(O, GM), "Moe signing a claim in Ann's name: refused (" .. tostring(why) .. ")")
local gm2 = gm:gsub('"by":"Ann"', '"by":"Moe"')
check(deliver(O, { rel = GM, body = gm2, side = resign(moe, GM, gm2, FAR + 1) }) == false and owner_of(O, "Drums") == nil, "Moe giving himself a claim: refused")
local GX = RDIR .. "/claims/given-Bee-20990101-000000.json"
check(deliver(O, { rel = GX, body = gm, side = resign(ann, GX, gm, FAR) }) == false, "a given claim under another person's name: refused")
check(deliver(O, { rel = GM, body = gm, side = resign(ann, GM, gm, FAR + 2) }) == true and owner_of(O, "Drums") == "Moe", "(Ann's own, the same claim: taken)")

-- ==== 1. A release =================================================================================================================================
local REL = RDIR .. "/released/Ann.json"
for _, c in ipairs({ B, O }) do -- Moe's claim on Lead, on both
  write(c.root .. "/" .. RDIR .. "/claims/Moe.json", json({ user = "Moe", tracks = { "Lead" }, regions = {}, times = {}, time = "2020-01-01T00:00:00Z" }))
end
clock = clock + 3 -- (a folder's listing is kept a moment)
check(owner_of(B, "Lead") == "Moe", "Moe holds Lead")
use(A)
require("sync").release_claims(A.cfg, SONG, ROOM, "Moe")
check(read(A.root .. "/" .. REL .. ".sig"), "a release is signed as it's written")
local rel1 = drained(A, REL)[1]
check(rel1 and rel1.side, "and goes over the link")
B.asked = 0
ok, why = deliver(B, rel1)
check(ok == true and owner_of(B, "Lead") == nil and B.asked == 0, "Ann's release counts on Bee's computer at once: " .. tostring(why))
check(read(B.root .. "/" .. REL) == nil, "nothing written into the shared folder")
syncthing(B, A, REL)
check(owner_of(B, "Lead") == nil and not overlaid(B, REL), "Syncthing's copy arrives: nothing changes")
-- a newer release, then the older one replayed
use(A)
clock = clock + 2
require("sync").release_claims(A.cfg, SONG, ROOM, "Cy")
local rel2 = drained(A, REL)[1]
check(deliver(B, rel2) == true and require("sync").released(B.cfg, SONG, ROOM).Cy ~= nil, "her next release, at once")
ok, why = deliver(B, rel1)
check(ok == false and why:find("older") and require("sync").released(B.cfg, SONG, ROOM).Cy ~= nil, "the older one replayed: refused (" .. tostring(why) .. ")")
-- a newer file already in the folder that no check has looked at yet: an older link copy is never read over it
syncthing(O, A, REL)
ok, why = deliver(O, rel1)
check(ok == false and why:find("older") and require("sync").released(O.cfg, SONG, ROOM).Cy ~= nil, "older than the folder's copy: refused (" .. tostring(why) .. ")")
-- Syncthing brings a newer signature file ahead of its file: the link's copy is let go (signed.drain's tidy), the folder's read again
local M = studio(computer(moe), true)
check(deliver(M, rel1) == true and overlaid(M, REL), "(Moe's computer takes the first release from the link)")
write(M.root .. "/" .. REL .. ".sig", rel2.side)
clock = clock + 2
drained(M)
check(not overlaid(M, REL), "a newer signature file in the folder: the link's older copy goes")
-- who may: a member who isn't the room's driver may not (nothing checks a release Syncthing brings; over the link it's the driver's or a manager's)
local RM = RDIR .. "/released/Moe.json"
local rm = json({ Ann = "2099-01-01T00:00:00Z" })
ok, why = deliver(B, { rel = RM, body = rm, side = resign(moe, RM, rm, FAR) })
check(ok == false and require("sync").released(B.cfg, SONG, ROOM).Ann == nil, "Moe (a member, not the driver) releasing Ann's claims: refused (" .. tostring(why) .. ")")
check(deliver(B, { rel = REL, body = rm, side = resign(moe, REL, rm, FAR) }) == false, "Moe signing a release under Ann's name: refused")
check(deliver(B, { rel = RM, body = rm }) == false, "unsigned: refused")
write(B.root .. "/" .. RDIR .. "/driver.json", json({ driver = "Moe" }))
ok, why = deliver(B, { rel = RM, body = rm, side = resign(moe, RM, rm, FAR + 1) })
check(ok == true and require("sync").released(B.cfg, SONG, ROOM).Ann ~= nil, "Moe as the room's driver: his release is taken: " .. tostring(why))

-- ==== 2. A song's hub handovers and its session.json ==================================================================================================
local HUB, SES = SONG .. "/hub/Ann.json", SONG .. "/session.json"
local band = use(A)
mkdirs(A.root .. "/" .. SONG .. "/hub")
band.write_json(A.root .. "/" .. SES, { host = "Ann", song = SONG, published = os.date("!%Y-%m-%dT%H:%M:%SZ"), tempo = { { 0, 120 } } })
band.write_json(A.root .. "/" .. HUB, { user = "Ann", transfers = { { to = "Bee", at = os.time() } } })
check(sw.signer(verify, STUDIO, HUB, read(A.root .. "/" .. HUB), read(A.root .. "/" .. HUB .. ".sig")) == sw.device_id(ann.pub), "a hub handover is signed by its computer")
check(sw.signer(verify, STUDIO, SES, read(A.root .. "/" .. SES), read(A.root .. "/" .. SES .. ".sig")) == sw.device_id(ann.pub), "and so is session.json")
mkdirs(T .. "/elsewhere/Song")
band.write_json(T .. "/elsewhere/Song/session.json", { host = "Ann" })
check(read(T .. "/elsewhere/Song/session.json.sig") == nil, "a session.json outside a studio's folder isn't signed")
local msgs = drained(A)
local hub1, ses1
for _, d in ipairs(msgs) do if d.rel == HUB then hub1 = d elseif d.rel == SES then ses1 = d end end
check(hub1 and ses1 and #msgs == 2, "both go over the link: " .. #msgs)
band = use(B)
B.asked = 0
ok, why = deliver(B, hub1)
check(ok == true and band.read_json(B.root .. "/" .. HUB).transfers[1].to == "Bee", "the handover is read on Bee's computer at once: " .. tostring(why))
check(require("trust").own_file_ok(B.root, HUB, "Ann", os.time()) == true and B.asked == 0, "and it's Ann's own by its signature (what lib/hub.lua asks), Syncthing not asked")
check(deliver(B, ses1) == true and require("trust").own_file_ok(B.root, SES, "Ann", os.time()) == true and B.asked == 0, "session.json the same")
check(read(B.root .. "/" .. HUB) == nil and read(B.root .. "/" .. SES) == nil, "nothing written into the shared folder")
syncthing(B, A, HUB); syncthing(B, A, SES)
check(not overlaid(B, HUB) and require("trust").own_file_ok(B.root, HUB, "Ann", os.time()) == true and band.read_json(B.root .. "/" .. SES).host == "Ann", "Syncthing's copies arrive: nothing changes")
-- someone else's hand in Ann's file, a file under another name, session.json from someone who didn't share the song
local hb = json({ user = "Ann", transfers = { { to = "Moe", at = os.time() } } })
ok, why = deliver(B, { rel = HUB, body = hb, side = resign(moe, HUB, hb, FAR) })
check(ok == false and band.read_json(B.root .. "/" .. HUB).transfers[1].to == "Bee", "Moe signing a handover in Ann's file: refused (" .. tostring(why) .. ")")
check(B.logged == nil or not tostring(B.logged):find("set aside"), "and no verdict is kept from a copy that came by the link")
check(deliver(B, { rel = SONG .. "/hub/Olive.json", body = hb, side = resign(ann, SONG .. "/hub/Olive.json", hb, FAR) }) == false, "a handover file under another name than its person's: refused")
check(deliver(B, { rel = HUB, body = hb:gsub("Moe", "Mox"), side = resign(ann, HUB, hb, FAR) }) == false, "a byte changed: refused")
local sb = json({ host = "Ann", song = SONG, published = "2099-01-01T00:00:00Z" })
check(deliver(B, { rel = SES, body = sb, side = resign(moe, SES, sb, FAR) }) == false and band.read_json(B.root .. "/" .. SES).published ~= "2099-01-01T00:00:00Z",
  "session.json from a computer that isn't its sharer's: refused over the link (Syncthing still carries it)")
check(deliver(B, { rel = "_band/session.json", body = sb, side = resign(ann, "_band/session.json", sb, FAR) }) == false, "only a song's session.json")
check(deliver(B, hub1) == false, "the first handover replayed: refused")

-- ==== 4. A person's track order, and a profile's picture ============================================================================================
local ORD = RDIR .. "/order/Ann.json"
band = use(A)
mkdirs(A.root .. "/" .. RDIR .. "/order")
band.write_json(A.root .. "/" .. ORD, { list = { "t1", "t2" }, time = "2026-11-20T10:00:00Z", by = "Ann" })
local ord1 = drained(A, ORD)[1]
check(ord1 and ord1.side, "a track order is signed and goes over the link")
band = use(B)
ok, why = deliver(B, ord1)
check(ok == true and band.read_json(B.root .. "/" .. ORD).list[2] == "t2" and #band.files(B.root .. "/" .. RDIR .. "/order", ".json") == 1, "read on Bee's computer at once: " .. tostring(why))
local ob = json({ list = { "t2", "t1" }, time = "2099-01-01T00:00:00Z", by = "Ann" })
check(deliver(B, { rel = ORD, body = ob, side = resign(moe, ORD, ob, FAR) }) == false and band.read_json(B.root .. "/" .. ORD).list[1] == "t1", "Moe's order in Ann's name: refused")
check(deliver(B, { rel = ORD, body = ob }) == false, "unsigned: refused")
syncthing(B, A, ORD)
check(band.read_json(B.root .. "/" .. ORD).list[1] == "t1" and not overlaid(B, ORD), "Syncthing's copy arrives: nothing changes")

-- a picture: a whole 8x8 PNG as lib/profile.lua checks one, NUL bytes and all (signed and sent as base64)
local function be32(n) return string.char((n >> 24) & 255, (n >> 16) & 255, (n >> 8) & 255, n & 255) end
local PNG = "\137PNG\r\n\26\n" .. "\0\0\0\13IHDR" .. be32(8) .. be32(8) .. "\8\2\0\0\0" .. "CRC!" .. "\0\0\0\1IDAT\0crc!" .. "\0\0\0\0IEND\174\66\96\130"
local PJ, PP = "_band/profiles/Ann.json", "_band/profiles/Ann.png"
band = use(A)
check(require("profile").image_info(PNG) == "image/png", "(the stand-in picture is one lib/profile.lua takes)")
mkdirs(A.root .. "/_band/profiles")
band.write_atomic(A.root .. "/" .. PP, PNG) -- (as profile.action: the picture, then its profile)
band.write_json(A.root .. "/" .. PJ, { user = "Ann", name = "Ann A", pic = "png", time = "2026-11-20T10:00:00Z" })
msgs = drained(A)
check(#msgs == 2 and msgs[1].rel == PJ and msgs[2].rel == PP and msgs[2].side and msgs[2].body == require("profile").base64(PNG), "the profile, then its picture, signed, as base64")
band = use(B)
check(deliver(B, msgs[2]) == false, "a picture no profile here names yet: refused")
check(deliver(B, msgs[1]) == true, "the profile")
ok, why = deliver(B, msgs[2])
check(ok == true and band.read(B.root .. "/" .. PP) == PNG and band.size(B.root .. "/" .. PP) == #PNG, "then the picture, read whole here at once: " .. tostring(why))
local people = require("profile").all(B.root)
check(people.Ann and people.Ann.pic == "data:image/png;base64," .. require("profile").base64(PNG), "and on the profile the pages get")
check(read(B.root .. "/" .. PP) == nil, "nothing written into the shared folder")
check(deliver(B, { rel = PP, body = msgs[2].body }) == false, "a picture unsigned: refused")
local other = require("profile").base64(PNG:gsub("CRC!", "CRC?"))
check(deliver(B, { rel = PP, body = other, side = resign(moe, PP, other, FAR) }) == false and band.read(B.root .. "/" .. PP) == PNG, "Moe's picture for Ann: refused")
local junk = require("profile").base64(("x"):rep(60))
check(deliver(B, { rel = PP, body = junk, side = resign(ann, PP, junk, FAR) }) == false, "not a picture: refused, even signed by its person")
check(deliver(B, { rel = "_band/profiles/Ann.jpg", body = msgs[2].body, side = resign(ann, "_band/profiles/Ann.jpg", msgs[2].body, FAR) }) == false, "a PNG under a .jpg name: refused")
syncthing(B, A, PJ); syncthing(B, A, PP)
clock = clock + 11 -- (profiles are read again every 10 s)
check(require("profile").all(B.root).Ann.pic == people.Ann.pic and not overlaid(B, PP), "Syncthing's copies arrive: nothing changes")

-- ==== 5. The welcome's newest sequence numbers ============================================================================================================
-- Ann lets Bee edit, then takes it back: two numbers for one grants file. A computer new to the studio is handed the first grant again.
local GR = RDIR .. "/grants/Ann.json"
use(A)
write(A.root .. "/" .. RDIR .. "/mode.json", json({ mode = "admins", by = "Olive" }))
check(require("grants").set(A.cfg, SONG, ROOM, "Bee", true), "Ann lets Bee edit")
local g1 = drained(A, GR)[1]
clock = clock + 2
check(require("grants").set(A.cfg, SONG, ROOM, "Bee", false), "and takes it back")
local g2 = drained(A, GR)[1]
local seqs = require("signed").known_seqs(A.root, 8000)
local has
for _, e in ipairs(seqs) do has = has or (e[1] == GR and e) end
check(has and math.type(has[2]) == "integer" and #has[3] == 16, "the inviter's computer knows the grants file's newest number")
check(seqs[1][1]:sub(1, 6) == "_band/" and #require("signed").known_seqs(A.root, 60) == 0 and #json(require("signed").known_seqs(A.root, 300)) <= 300, "the studio's own files first, and within the room the welcome has left")
-- (the welcome carries them, lib/joinboot.lua: through JSON and back, as the sealed welcome does)
seqs = require("band").json_decode(json(seqs))
-- without them: a computer that never saw the file takes the first validly signed copy it's handed, however old (first use)
local J0 = studio(computer(cy), true)
write(J0.root .. "/" .. RDIR .. "/mode.json", json({ mode = "admins", by = "Olive" }))
check(deliver(J0, g1) == true and require("grants").list(J0.cfg, SONG, ROOM).Bee ~= nil, "without the welcome's numbers, the replayed first grant is taken (first use)")
-- with them
local J = studio(computer(cy), true)
write(J.root .. "/" .. RDIR .. "/mode.json", json({ mode = "admins", by = "Olive" }))
use(J)
local signed = require("signed")
check(signed.seed_seqs(J.root, seqs) == #seqs, "the joiner takes the welcome's numbers")
ok, why = deliver(J, g1)
check(ok == false and why:find("older") and require("grants").list(J.cfg, SONG, ROOM).Bee == nil, "with them, the replayed first grant is refused (" .. tostring(why) .. ")")
-- and put into the folder instead: not the signature's word, so Syncthing is asked (who put it there), as for any older copy put back
write(J.root .. "/" .. GR, g1.body); write(J.root .. "/" .. GR .. ".sig", g1.side)
J.by_file[GR] = moe.dev:sub(1, 7)
J.asked = 0
clock = clock + 3
check(require("grants").list(J.cfg, SONG, ROOM).Bee == nil and J.asked >= 1, "the old grant put into the folder by Moe's computer: Syncthing asked, refused")
os.remove(J.root .. "/" .. GR); os.remove(J.root .. "/" .. GR .. ".sig")
clock = clock + 31
ok, why = deliver(J, g2)
check(ok == true, "the newest copy, the very one the numbers name, still goes in: " .. tostring(why))
-- the numbers only ever raise a floor, and never one dated more than a day ahead (it would shut the real file out)
check(signed.seed_seqs(J.root, { { GR, 5, ("0"):rep(16) } }) == 0, "a lower number changes nothing")
check(signed.seed_seqs(J.root, { { REL, (os.time() + 3 * 86400) * 1000, ("0"):rep(16) } }) == 0, "a number three days ahead isn't taken")
check(signed.seed_seqs(J.root, { { "../x/_band/band.json", 9, ("0"):rep(16) }, { GR, "9", "x" }, "junk", { "_band/profiles/Ann.json", 9, ("0"):rep(16) } }) == 0, "nor anything that isn't a signed studio file's number")
check(signed.seed_seqs(J.root, nil) == 0, "no numbers in the welcome (an older inviter): nothing, as before")

-- ==== The studio's timeline, one file per computer (sync.session_timeline, sync.studio_timeline; rt-edits, 0ae5fbf) ================================
-- Each computer keeps the last tempo map and markers it sent in rooms/<room>/timeline/<person>.json; the newest stamp among them is the
-- studio's. The map itself travels as a "timeline" event; the file is what a computer opening the song, or checking what it holds, reads.
local TL, TLO = RDIR .. "/timeline/Ann.json", RDIR .. "/timeline/Olive.json"
local S1, S2, S0 = "2026-11-20T10:00:00Zann-1", "2026-11-20T10:05:00Zann-2", "2026-11-20T09:00:00Zolive-1"
local function studio_order(c) use(c); local t = require("sync").studio_timeline(c.cfg, SONG, ROOM); return t and t.timeline_order, t and t.by end
use(A)
require("sync").session_timeline(A.cfg, SONG, { { 0, 120 } }, { { "m", 1 } }, S1, nil, ROOM)
check(sw.signer(verify, STUDIO, TL, read(A.root .. "/" .. TL), read(A.root .. "/" .. TL .. ".sig")) == sw.device_id(ann.pub), "a timeline file is signed by the computer that wrote it")
local tl1 = drained(A, TL)
check(#tl1 == 1 and tl1[1].side, "and goes over the link, once: " .. #tl1)
tl1 = tl1[1]
check(#drained(A, TL) == 0, "nothing more to send until it's written again")
check(studio_order(B) == nil, "before: Bee's computer has no stamped timeline for the room")
B.asked = 0
B.ext["signed outbox"] = nil
ok, why = deliver(B, tl1)
local o1, by1 = studio_order(B)
check(ok == true and o1 == S1 and by1 == "Ann" and B.asked == 0, "Ann's timeline is the studio's on Bee's computer at once, by its signature: " .. tostring(why) .. " " .. tostring(o1))
check(read(B.root .. "/" .. TL) == nil, "nothing written into the shared folder")
check(deliver(B, tl1) == false and (B.ext["signed outbox"] or "") == "" and #drained(B, TL) == 0, "the same message again is not taken twice, and Bee's computer sends nothing on")
syncthing(B, A, TL)
check(studio_order(B) == S1 and not overlaid(B, TL) and (B.ext["signed outbox"] or "") == "", "Syncthing's copy arrives: the same timeline, nothing sent")
-- a newer stamp, then the older file replayed: over the link, and against a newer file in the folder no check has looked at yet
use(A)
clock = clock + 2
require("sync").session_timeline(A.cfg, SONG, { { 0, 90 } }, { { "m", 1 } }, S2, nil, ROOM)
local tl2 = drained(A, TL)[1]
check(deliver(B, tl2) == true and studio_order(B) == S2, "her next timeline, at once")
ok, why = deliver(B, tl1)
check(ok == false and why:find("older") and studio_order(B) == S2, "the older file replayed: refused, the newer stamp stays (" .. tostring(why) .. ")")
syncthing(O, A, TL)
ok, why = deliver(O, tl1)
check(ok == false and why:find("older") and studio_order(O) == S2, "nor read over a newer file Syncthing brought: " .. tostring(why))
-- another person's file with an older stamp: taken as theirs, and the newest stamp among the files is still the studio's
local ob0 = json({ user = "Olive", at = os.time(), order = S0, tempo = { { 0, 60 } }, markers = {} })
check(deliver(B, { rel = TLO, body = ob0, side = resign(olive, TLO, ob0, FAR) }) == true and studio_order(B) == S2, "Olive's older timeline doesn't replace Ann's newer stamp")
-- refused: unsigned, a byte changed, someone else's signature, a file not named for who it says
local fb = json({ user = "Ann", at = os.time(), order = "2099-01-01T00:00:00Zforged", tempo = { { 0, 200 } }, markers = {} })
check(deliver(B, { rel = TL, body = fb }) == false, "unsigned: refused")
check(deliver(B, { rel = TL, body = fb, side = tl2.side }) == false, "another file under Ann's signature: refused")
check(deliver(B, { rel = TL, body = fb, side = resign(moe, TL, fb, FAR) }) == false, "Moe signing Ann's timeline file: refused")
check(deliver(B, { rel = TLO, body = fb, side = resign(ann, TLO, fb, FAR + 1) }) == false, "a file named for Olive that says it's Ann's: refused")
check(studio_order(B) == S2 and overlaid(B, TL), "and the studio's timeline is still Ann's newest, read from the link's copy")
-- the file that only says "this computer reads these" (sync.timeline_reads) goes the same way
use(B)
require("sync").timeline_reads(B.cfg, SONG, ROOM)
local tlb = drained(B, RDIR .. "/timeline/Bee.json")[1]
check(tlb and tlb.side and deliver(A, tlb) == true and require("band").read_json(A.root .. "/" .. RDIR .. "/timeline/Bee.json").reads == true, "Bee's own (reads only) is on Ann's computer at once")
-- Syncthing alone, unsigned, as a computer on an older build writes it: judged by Syncthing's word, as today
local Q = studio(computer(cy), false)
write(Q.root .. "/" .. TL, json({ user = "Ann", at = 0, order = S1, tempo = { { 0, 120 } }, markers = {} }))
Q.by_file[TL] = ann.dev:sub(1, 7)
clock = clock + 3
check(studio_order(Q) == S1 and Q.asked >= 1, "an unsigned timeline file, Syncthing says Ann's computer: the studio's, as before")
write(Q.root .. "/" .. TLO, json({ user = "Olive", at = 0, order = "2099-01-01T00:00:00Zx", tempo = { { 0, 60 } }, markers = {} }))
Q.by_file[TLO] = moe.dev:sub(1, 7)
clock = clock + 3
check(studio_order(Q) == S1, "and one Syncthing says Moe's computer wrote under Olive's name: left out, as before")

-- ==== Another script on the same computer (the ImGui panel beside Live sync) reads the link's copies too ============================================
-- Live sync took them from the link; the panel is a script of its own, with its own modules and its own band.overlay, the same folder,
-- saved state and home. `other(c)`: such a script on c's computer.
local function other(c)
  local p = computer(c.who)
  p.root, p.cfg, p.ext, p.by_file, p.services = c.root, c.cfg, c.ext, c.by_file, c.services
  return p
end
local W = studio(computer(cy), true) -- (Cy's computer: Live sync)
write(W.root .. "/" .. RDIR .. "/mode.json", json({ mode = "admins", by = "Olive" }))
use(A)
clock = clock + 2
check(require("grants").set(A.cfg, SONG, ROOM, "Moe", true), "Ann lets Moe edit")
local gp = drained(A, GR)[1]
use(A)
require("sync").give_claims(A.cfg, SONG, ROOM, "Olive", { "Pads" })
local gvp = drained(A)[1]
check(gp and gvp and gvp.rel:find("given%-Olive%-"), "(a grant and a given claim from Ann)")
check(deliver(W, gp) == true and deliver(W, gvp) == true, "Cy's Live sync takes both from the link")
check((W.ext["linked files"] or ""):find(GR, 1, true) and (W.ext["linked files"] or ""):find(gvp.rel, 1, true), "and lists them for the other scripts on this computer")
local store = W.reaper.GetResourcePath() .. "/StudioSync/direct/" .. STUDIO .. "/.linked/"
check(read(store .. GR) == gp.body and read(store .. GR .. ".sig") == gp.side and read(W.root .. "/" .. GR) == nil, "kept in this computer's own folder, not the synced one")
local WP = other(W)
WP.asked = 0
use(WP)
check(next(require("band").overlay) == nil, "(the panel script starts with no link copies of its own)")
check(require("grants").list(WP.cfg, SONG, ROOM).Moe ~= nil and WP.asked == 0, "the panel shows the grant at once, by its signature (Syncthing not asked)")
check(owner_of(WP, "Pads") == "Olive", "and the given claim")
check(overlaid(WP, GR) and read(W.root .. "/" .. GR) == nil, "from its own overlay: nothing in the synced folder")
-- the same checks in the panel: a copy put into the shared place by hand is not believed
local fgr = RDIR .. "/grants/Moe.json"
local fg = json({ by = "Moe", users = { Cy = { on = true, at = "2099-01-01T00:00:00Z" } } })
write(store .. fgr, fg); write(store .. fgr .. ".sig", resign(moe, fgr, fg, FAR))
W.ext["linked files"] = W.ext["linked files"] .. "\n" .. table.concat({ W.root, fgr, "9.9", "-", "", "" }, "\t")
check(require("grants").list(WP.cfg, SONG, ROOM).Cy == nil and not overlaid(WP, fgr), "a member's grant slipped into the shared place: refused by the same check")
-- nor one the folder has moved on from: Syncthing's file is there now, and it's the one read
local og = json({ by = "Olive", users = { Cy = { on = true, at = "2099-01-01T00:00:00Z" } } })
local ogr = RDIR .. "/grants/Olive.json"
write(store .. ogr, og); write(store .. ogr .. ".sig", resign(olive, ogr, og, FAR))
write(W.root .. "/" .. ogr, json({ by = "Olive", users = {} }))
W.ext["linked files"] = W.ext["linked files"] .. "\n" .. table.concat({ W.root, ogr, "9.10", "-", "", "" }, "\t")
clock = clock + 3
check(require("grants").list(WP.cfg, SONG, ROOM).Cy == nil and not overlaid(WP, ogr), "a copy from before the folder's file changed isn't read over it")
os.remove(W.root .. "/" .. ogr)
-- Live sync reloaded (an update): the new script has them again
local W2 = other(W)
use(W2)
check(require("grants").list(W2.cfg, SONG, ROOM).Moe ~= nil and owner_of(W2, "Pads") == "Olive", "a reloaded Live sync reads the link's copies again")
-- Syncthing's copy of the grant arrives: Live sync lets its copy go and takes it off the list; the panel reads the folder's, the same grant
syncthing(W, A, GR)
drained(W)
check(not (W.ext["linked files"] or ""):find("\t" .. GR .. "\t", 1, true) and read(store .. GR) == nil, "Syncthing's copy arrives: off the list, out of this computer's folder")
use(WP)
check(require("grants").list(WP.cfg, SONG, ROOM).Moe ~= nil and not overlaid(WP, GR), "the panel reads the folder's file now, and the grant stands")
-- the given claim's minute is up (no file ever came here): gone in Live sync, and in the panel with it
clock = clock + require("signed").GIVEN_KEEP + 5
drained(W)
check(owner_of(W, "Pads") == nil and owner_of(WP, "Pads") == nil and not overlaid(WP, gvp.rel), "a given claim's minute ends in the panel when it ends in Live sync")
check(deliver(W, gvp) == false, "and the same given claim again is still refused (taken once)")
-- Live sync quiet since (stopped, or busy): the panel ends a given claim's minute by itself
use(A)
clock = clock + 2
require("sync").give_claims(A.cfg, SONG, ROOM, "Olive", { "Drums" })
local gv3 = drained(A)[1]
check(gv3 and deliver(W, gv3) == true, "(another given claim, taken by Cy's Live sync)")
check(owner_of(WP, "Drums") == "Olive", "the panel shows it")
clock = clock + require("signed").GIVEN_KEEP + 5
check(owner_of(WP, "Drums") == nil and not (W.ext["linked files"] or ""):find(gv3.rel, 1, true), "with no Live sync tick since, the panel ends its minute and takes it off the list")

-- ==== The roles: a refused link copy never gets the owner's own file refused after it (trust.roles' verdicts) =======================================
-- Olive (the owner) makes Bee an admin. Ann (an admin) re-signs those very words and gets them to Moe's computer first.
local BJ = "_band/band.json"
local R = studio(computer(moe), true)
local newroles = json({ id = STUDIO, name = "LM", owner = "Olive", admins = { "Ann", "Bee" }, roles_at = 5 })
local function admins_on(c) use(c); local _, a = require("trust").roles(c.root, require("band").read_json(c.root .. "/" .. BJ)); return table.concat(a, ",") end
check(admins_on(R) == "Ann", "before: Ann alone is an admin")
R.logged = nil
ok, why = deliver(R, { rel = BJ, body = newroles, side = resign(ann, BJ, newroles, FAR) })
check(ok == false and admins_on(R) == "Ann" and not overlaid(R, BJ), "an admin's copy that changes who's in charge isn't taken over the link (" .. tostring(why) .. ")")
check(R.logged == nil or not tostring(R.logged):find("roles were changed", 1, true), "and nothing is said or kept about it")
ok, why = deliver(R, { rel = BJ, body = newroles, side = resign(olive, BJ, newroles, FAR + 1) })
check(ok == true and admins_on(R) == "Ann,Bee", "the owner's own file, the same roles and date, is taken after it: " .. tostring(why) .. " " .. admins_on(R))
local setting = json({ id = STUDIO, name = "LM", owner = "Olive", admins = { "Ann", "Bee" }, roles_at = 5, direct = true })
check(deliver(R, { rel = BJ, body = setting, side = resign(ann, BJ, setting, FAR + 2) }) == true, "an admin's band.json that leaves the roles as they are still goes in at once")

-- ==== A person's own claims file (rooms/<room>/claims/<person>.json): signed, and over the link first (rt-linkmove3) ==================================
-- The finding (three computers): Bee let go of a claim given to her, from the panel; Live sync elsewhere had it at once (the "claim"
-- message), but the panel on a third computer read it only when Syncthing brought her claims file. Now her file is a signed own file:
-- Cy's Live sync takes it from the link and the panel beside it reads it at once.
do
  local CL = RDIR .. "/claims/Bee.json"
  syncthing(W, B, CL) -- (Cy's computer has Bee's claims as Syncthing last brought them: Keys, given to her and folded in above)
  clock = clock + 3
  check(owner_of(WP, "Keys") == "Bee", "before: the panel on Cy's computer shows Keys as Bee's")
  local before = read(W.root .. "/" .. CL)
  -- she lets it go
  use(B)
  clock = clock + 2
  require("sync").set_claims(B.cfg, SONG, ROOM, { tracks = {}, regions = {}, times = {} })
  check(read(B.root .. "/" .. CL .. ".sig"), "a person's claims file is signed as it's written")
  local cl1 = drained(B, CL)[1]
  check(cl1 and cl1.side, "and goes over the link")
  W.asked = 0
  ok, why = deliver(W, cl1)
  check(ok == true and owner_of(W, "Keys") == nil and W.asked == 0, "her release counts in Cy's Live sync at once, by its signature: " .. tostring(why))
  check(owner_of(WP, "Keys") == nil and read(W.root .. "/" .. CL) == before, "and in the panel, before Syncthing's copy (nothing written into the folder)")
  -- she claims something
  use(B)
  clock = clock + 2
  require("sync").set_claims(B.cfg, SONG, ROOM, { tracks = { "Horns" }, regions = {}, times = {} })
  local cl2 = drained(B, CL)[1]
  ok, why = deliver(W, cl2)
  check(ok == true and owner_of(WP, "Horns") == "Bee" and WP.asked == 0, "a claim she makes: in the panel at once: " .. tostring(why))
  -- an older replay: refused against the number taken, and against a newer file in the folder no check has looked at yet
  ok, why = deliver(W, cl1)
  check(ok == false and why:find("older") and owner_of(WP, "Horns") == "Bee", "her release replayed after her new claim: refused (" .. tostring(why) .. ")")
  syncthing(O, B, CL)
  ok, why = deliver(O, cl1)
  check(ok == false and why:find("older") and owner_of(O, "Horns") == "Bee", "older than the folder's copy: refused (" .. tostring(why) .. ")")
  -- her file back to words it had before (a "yes" kept by the words, trust.own_file_ok): its number is taken all the same, so the copy in
  -- between can't be replayed over it
  local wp = json({ user = "Bee", tracks = { "Sax" }, regions = {}, times = {}, time = "2098-01-01T00:00:00Z" })
  local wq = json({ user = "Bee", tracks = {}, regions = {}, times = {}, time = "2098-01-01T00:00:01Z" })
  local q = { rel = CL, body = wq, side = resign(bee, CL, wq, FAR + 11) }
  check(deliver(O, { rel = CL, body = wp, side = resign(bee, CL, wp, FAR + 10) }) == true and deliver(O, q) == true, "(two more of hers)")
  check(deliver(O, { rel = CL, body = wp, side = resign(bee, CL, wp, FAR + 12) }) == true and owner_of(O, "Sax") == "Bee", "her file back to its earlier words")
  ok, why = deliver(O, q)
  check(ok == false and owner_of(O, "Sax") == "Bee", "the copy in between, replayed: refused (" .. tostring(why) .. ")")
  -- refused: unsigned, another file under her signature, someone else's signature, a file not named for who it says, a given claim's words
  local fc = json({ user = "Bee", tracks = { "Lead" }, regions = {}, times = {}, time = "2099-01-01T00:00:00Z" })
  check(deliver(W, { rel = CL, body = fc }) == false, "unsigned: refused")
  check(deliver(W, { rel = CL, body = fc, side = cl2.side }) == false, "another file under Bee's signature: refused")
  ok, why = deliver(W, { rel = CL, body = fc, side = resign(moe, CL, fc, FAR) })
  check(ok == false and owner_of(WP, "Lead") == nil and owner_of(W, "Horns") == "Bee", "Moe signing Bee's claims: refused, her real ones still read (" .. tostring(why) .. ")")
  local CM = RDIR .. "/claims/Moe.json"
  check(deliver(W, { rel = CM, body = fc, side = resign(bee, CM, fc, FAR) }) == false and owner_of(W, "Lead") == nil, "a file named for Moe that says it's Bee's: refused")
  local fg = json({ user = "Bee", tracks = { "Lead" }, regions = {}, times = {}, time = "2099-01-01T00:00:00Z", given = true })
  check(deliver(W, { rel = CL, body = fg, side = resign(bee, CL, fg, FAR) }) == false, "a given claim's words in her own file: refused")
  check(owner_of(W, "Horns") == "Bee" and owner_of(WP, "Horns") == "Bee", "(and her real claims stand everywhere here)")
  -- Syncthing's copy arrives later: nothing changes, the link's copy goes, off the shared list, nothing sent on
  syncthing(W, B, CL)
  drained(W)
  check(owner_of(W, "Horns") == "Bee" and owner_of(WP, "Horns") == "Bee" and not overlaid(W, CL) and not overlaid(WP, CL) and #W.sent == 0,
    "Syncthing's copy takes over in Live sync and the panel, and the claim stands")
  check(not (W.ext["linked files"] or ""):find("\t" .. CL .. "\t", 1, true), "and the copy is off the shared list")
  -- an older build rewrites her file (unsigned, the old signature file left beside it): read as before, and judged by Syncthing's word
  write(W.root .. "/" .. CL, json({ user = "Bee", tracks = { "Organ" }, regions = {}, times = {}, time = "2030-01-01T00:00:00Z" }))
  W.by_file[CL] = bee.dev:sub(1, 7)
  clock = clock + 3
  W.asked = 0
  check(owner_of(WP, "Organ") == "Bee", "an older build's unsigned claims file reads as before")
  check(require("trust").own_file_ok(W.root, CL, "Bee", 0) == true and W.asked >= 1, "a stale signature file: Syncthing's word, as before")
  -- a computer with no keys learnt (the Syncthing path alone): an unsigned file counts by its name, as it always has
  local P2 = studio(computer(moe), false)
  write(P2.root .. "/" .. CL, json({ user = "Bee", tracks = { "Organ" }, regions = {}, times = {}, time = "2030-01-01T00:00:00Z" }))
  check(owner_of(P2, "Organ") == "Bee", "an unsigned claims file from Syncthing counts, as before")
  -- receiving on an older build: not a kind its link takes, refused without a word
  local OLD2 = studio(computer(moe), true)
  use(OLD2)
  require("signed").LINK.claims = nil
  OLD2.logged = nil
  local took, said = deliver(OLD2, cl2)
  check(took == false and said:find("link") and OLD2.logged == nil and not overlaid(OLD2, CL), "an older build ignores a claims file over the link (" .. tostring(said) .. ")")
end

-- ==== a computer on an older build ====================================================================================================================
-- receiving (36f90ae: these kinds aren't ones its link takes): refused without a word, and Syncthing's copy works as before
local OLD = studio(computer(cy), true)
use(OLD)
signed = require("signed")
for _, k in ipairs({ "given", "released", "order", "hub", "session", "pic", "timeline" }) do signed.LINK[k] = nil end
OLD.logged = nil
for _, d in ipairs({ rel2, hub1, ses1, ord1, msgs[2], given2, tl2 }) do
  local took, said = deliver(OLD, d)
  check(took == false and said:find("link"), d.rel .. " on an older build: not taken (" .. tostring(said) .. ")")
end
check(OLD.logged == nil and next(require("band").overlay) == nil, "nothing logged, nothing kept")
-- sending (it signs none of these, and sends none): Syncthing brings the plain files, judged as they always were
local P = studio(computer(cy), false) -- (no keys learnt either: the Syncthing path alone)
band = use(P)
write(P.root .. "/" .. REL, json({ Moe = "2030-01-01T00:00:00Z" }))
check(require("sync").released(P.cfg, SONG, ROOM).Moe == "2030-01-01T00:00:00Z", "an unsigned release from Syncthing counts, as before")
write(P.root .. "/" .. HUB, hb)
P.by_file[HUB] = ann.dev:sub(1, 7)
check(require("trust").own_file_ok(P.root, HUB, "Ann", 0) == true and P.asked >= 1, "an unsigned hub handover: Syncthing says Ann's computer wrote it, taken as before")
write(P.root .. "/" .. SONG .. "/hub/Olive.json", json({ user = "Olive", transfers = {} }))
P.by_file[SONG .. "/hub/Olive.json"] = moe.dev:sub(1, 7)
check(require("trust").own_file_ok(P.root, SONG .. "/hub/Olive.json", "Olive", 0) == false, "and one Syncthing says Moe's computer wrote: set aside as before")
write(P.root .. "/" .. GM, gm)
P.by_file[GM] = ann.dev:sub(1, 7)
check(owner_of(P, "Drums") == "Moe", "an unsigned given claim, Syncthing says Ann's computer: counts as before")
write(P.root .. "/" .. ORD, ob)
check(require("band").read_json(P.root .. "/" .. ORD).list[1] == "t2", "an unsigned track order reads as before")

-- ==== rt-p3 (round 6): studio-wide files beyond the room, files over 32 KB in parts, driver.json, an older folder copy ===================
do
  -- studio-wide and song-wide files go to every studio computer the link may send to (direct.studio_peers), room files to the room
  local band = use(A)
  local asked_song
  A.direct.studio_peers = function(_, song) asked_song = song; return { "far:47281", "moe:47281" }, { ["far:47281"] = "Far", ["moe:47281"] = "Moe" } end
  write(A.root .. "/_band/removed/Moe.json", json({ user = "Moe", device = moe.dev, by = "Ann", at = os.time() }))
  band.write_json(A.root .. "/_band/band.json", { id = STUDIO, name = "LM", owner = "Olive", admins = { "Ann" }, sonobus = "secret-p3" })
  local bj = drained(A, "_band/band.json")[1]
  local to = table.concat(A.sent[#A.sent].to, " ")
  check(bj and to == "peer:47281 far:47281", "band.json: to the room and to a computer in another room, never to one with a removal mark: " .. to)
  os.remove(A.root .. "/_band/removed/Moe.json")
  band.write_json(A.root .. "/" .. SONG .. "/session.json", { host = "Ann", song = SONG, v = 0 })
  drained(A)
  check(asked_song == SONG and table.concat(A.sent[#A.sent].to, " ") == "peer:47281 far:47281 moe:47281", "a song's session.json: its song's computers, wherever they are")
  require("grants").set(A.cfg, SONG, ROOM, "Moe", true)
  drained(A)
  check(table.concat(A.sent[#A.sent].to, " ") == "peer:47281", "a room's file: the room's computers only, as before")
  A.direct.studio_peers = function() return {}, {} end

  -- driver.json: from the driver's own computer, at once (the panel reads the file; Live sync had the "driver" event already)
  local DRV = RDIR .. "/driver.json"
  use(A)
  require("sync").set_driver(A.cfg, SONG, ROOM, "Ann")
  local dv = drained(A, DRV)[1]
  check(dv and dv.side, "Take control: driver.json goes over the link, signed")
  B.asked = 0
  ok, why = deliver(B, dv)
  use(B)
  check(ok == true and require("sync").driver(B.cfg, SONG, ROOM) == "Ann" and B.asked == 0, "Bee's computer has Ann as the driver at once: " .. tostring(why))
  local db = json({ driver = "Ann" })
  ok = deliver(B, { rel = DRV, body = db, side = resign(moe, DRV, db, FAR + 50) })
  check(ok == false, "Moe's computer naming Ann the driver: refused (only the driver's own computer)")
  syncthing(B, A, DRV)
  use(B)
  check(not overlaid(B, DRV) and require("sync").driver(B.cfg, SONG, ROOM) == "Ann", "Syncthing's copy: nothing changes")

  -- a file over 32 KB: in parts, put together, checked as one
  band = use(A)
  local S2 = SONG .. "/session.json"
  local big = {}
  for i = 1, 3000 do big[i] = { i, "marker " .. i .. " \"quoted\"" } end
  band.write_json(A.root .. "/" .. S2, { host = "Ann", song = SONG, markers = big })
  local body = read(A.root .. "/" .. S2)
  check(#body > require("signed").BODY_MAX * 2, "a session.json of " .. #body .. " bytes")
  A.sent = {}
  require("signed").drain(A.cfg, SONG, ROOM)
  local parts = {}
  for _, m in ipairs(A.sent) do if m.kind == "signed" and m.d.part then parts[#parts + 1] = m.d end end
  local n = math.ceil(#body / require("signed").PART)
  check(#parts == n and parts[n].side and not parts[1].side and parts[1].rel == nil, "sent in " .. #parts .. " parts, the signature file with the last, no rel (an older build: \"not a signed file\")")
  for _, m in ipairs(A.sent) do check(#json({ song = SONG, room = ROOM, d = m.d }) <= 65536, "each part fits the link's 64 KB a message") end
  B.asked = 0
  for i = n, 2, -1 do ok, why = deliver(B, parts[i]); check(ok == false and tostring(why):find("^part"), "part " .. i .. " alone: kept, not taken") end
  ok, why = deliver(B, parts[1])
  band = use(B)
  check(ok == true and #band.read_json(B.root .. "/" .. S2).markers == 3000 and B.asked == 0, "the last part in: the whole file taken by its signature: " .. tostring(why))
  check(read(B.root .. "/" .. S2) ~= body, "nothing written into the shared folder")
  -- a part changed, a part missing past PARTS_KEEP, junk
  local bad = { part = { S2, 1, n, parts[1].part[4] }, data = require("profile").base64(("x"):rep(require("signed").PART)) }
  for i = 2, n do deliver(O, parts[i]) end
  ok, why = deliver(O, bad)
  check(ok == false and tostring(why):find("add up") and not overlaid(O, S2), "a changed part: refused (" .. tostring(why) .. ")")
  for i = 2, n do deliver(O, parts[i]) end
  clock = clock + require("signed").PARTS_KEEP + 1
  ok, why = deliver(O, parts[1])
  check(ok == false and not overlaid(O, S2), "a part that comes after the rest were dropped (PARTS_KEEP): nothing taken (" .. tostring(why) .. ")")
  check(deliver(O, { part = { S2, 1, 99, "x" }, data = "AAAA" }) == false, "more parts than FILE_MAX allows: refused")
  check(deliver(O, { part = { "../x/session.json", 1, 2, "x" }, data = "AAAA" }) == false, "a path outside the studio: refused")
  check(deliver(O, { part = { S2, 1, 2, "x" }, data = "not base64!" }) == false, "not base64: refused")
  -- over FILE_MAX: stays on Syncthing
  band = use(A)
  for i = 1, 12000 do big[i] = { i, "marker " .. i .. " with a longer name" } end
  band.write_json(A.root .. "/" .. S2, { host = "Ann", song = SONG, markers = big })
  check(#read(A.root .. "/" .. S2) > require("signed").FILE_MAX and #drained(A) == 0 and #A.sent == 0, "over FILE_MAX: nothing over the link, Syncthing carries it")

  -- an older folder copy after a newer link copy: the link's copy goes back in (tidy) while the folder's is signed and numbered before it
  band = use(A)
  band.write_json(A.root .. "/" .. S2, { host = "Ann", song = SONG, v = 1 })
  local v1, v1sig = read(A.root .. "/" .. S2), read(A.root .. "/" .. S2 .. ".sig")
  drained(A)
  band = use(A)
  band.write_json(A.root .. "/" .. S2, { host = "Ann", song = SONG, v = 2 })
  local m2 = drained(A, S2)[1]
  check(m2 and deliver(B, m2) == true, "Bee's computer takes v2 from the link")
  write(B.root .. "/" .. S2, v1); write(B.root .. "/" .. S2 .. ".sig", v1sig)
  band = use(B)
  check(band.read_json(B.root .. "/" .. S2).v == 1, "(Syncthing brings v1 late: band.read reads the folder's changed file)")
  clock = clock + 2
  drained(B)
  band = use(B)
  check(band.read_json(B.root .. "/" .. S2).v == 2 and overlaid(B, S2), "the next tidy: v1 is numbered before the link's v2, so v2 is read again")
  check(read(B.root .. "/" .. S2) == v1, "(nothing written into the folder)")
  -- an older build rewrites it unsigned (the signature file stale): read, as before
  write(B.root .. "/" .. S2, json({ host = "Ann", song = SONG, v = 9 }))
  clock = clock + 2
  drained(B)
  band = use(B)
  check(band.read_json(B.root .. "/" .. S2).v == 9 and not overlaid(B, S2), "an unsigned rewrite isn't \"older\": the folder's file is read")
  -- the newest by Syncthing after a restore: the link's copy is let go
  write(B.root .. "/" .. S2, v1); write(B.root .. "/" .. S2 .. ".sig", v1sig)
  band = use(A)
  band.write_json(A.root .. "/" .. S2, { host = "Ann", song = SONG, v = 3 })
  local m3 = drained(A, S2)[1]
  check(deliver(B, m3) == true, "v3 from the link over the folder's v1")
  syncthing(B, A, S2)
  clock = clock + 2
  drained(B)
  band = use(B)
  check(band.read_json(B.root .. "/" .. S2).v == 3 and not overlaid(B, S2), "Syncthing brings v3 itself: the link's copy is let go")
end

clean()
print("ok link-first: given claims, releases, track order, hub handovers, session.json, profile pictures, the welcome's numbers")
