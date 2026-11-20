-- Signed writes (lib/signedwrites.lua, docs/rt/rt-lite.md): trust without Syncthing's modifiedBy, a spike not wired into the shipped flow.
-- Device ids made from a key (Syncthing's shape, the key back out of it), devices files that prove themselves, a manager's band.json taken
-- and a member's refused, a file moved to another path or studio refused, a rollback and two files with one number refused, a changed byte,
-- a sidecar ahead of its file, a tombstone, and the 7-character prefix lib/trust.lua compares (fine for Syncthing's modifiedBy, forgeable
-- for a key's id) next to sw.from_manager's whole ids. Ed25519 is tools/sign_release.py's (the extension's twin, checked against it by
-- tests/sign_cross.py), through lupa's `python`. Lupa, repo root.
package.path = "lib/?.lua;" .. package.path
local SEP = package.config:sub(1, 1)
local T = (os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"):gsub("\\", "/") .. "/ss_lite_" .. os.time() .. "_" .. math.random(100000, 999999)
local function clean() os.execute(SEP == "\\" and ('rmdir /s /q "' .. T:gsub("/", "\\") .. '" 2>nul') or ("rm -rf '" .. T .. "'")) end
local function check(cond, what) if not cond then clean(); error(what, 2) end end

python.eval("__import__('sys').path.insert(0, 'tools')")
local sr = python.eval("__import__('sign_release')")
local py_sign = python.eval("lambda sr, kp, m: sr.sign(sr.load_seed(kp), m.encode('utf-8')).hex()")
local py_key = python.eval("lambda sr, kp: sr.public_key(sr.new_key(kp)).hex()")
local py_verify = python.eval("lambda sr, s, m, k: sr.verify(bytes.fromhex(k), m.encode('utf-8'), bytes.fromhex(s))")
local function verify(s, m, k) local ok, r = pcall(py_verify, sr, s, m, k); return ok and r == true end

-- (only for trust.from_manager below: lib/trust.lua needs band, band needs a reaper)
reaper = setmetatable({ GetOS = function() return "Win64" end, time_precise = os.clock }, { __index = function() return function() return "" end end })
local sw = require("signedwrites")
local trust = require("trust")
local services = require("services")

local function computer(name)
  local kp = T .. "/" .. name .. "-key"
  local pub = py_key(sr, kp)
  return { kp = kp, pub = pub, id = sw.device_id(pub), sign = function(m) return py_sign(sr, kp, m) end }
end
local owner, admin, member, bee = computer("owner"), computer("admin"), computer("member"), computer("bee")
local STUDIO, NOW = "studiosync-lite-0001", 1800000000

-- device ids from keys
check(services.is_device_id(owner.id), "a key's id is Syncthing-shaped (services.is_device_id takes it)")
check(sw.key_of(owner.id) == owner.pub, "the key comes back out of its id")
check(owner.id ~= admin.id and sw.device_id(owner.pub) == owner.id, "one id per key, the same every time")
check(sw.key_of("MFZWI3D-BONSGYC-YLTMRWG-C43ENR5-QXGZDMM-FZWI3DB-ONSGYCY-LTMRWGC") == nil, "a Syncthing id carries no key")
check(sw.key_of("nope") == nil and sw.device_id("xyz") == nil, "nonsense is nobody")

-- devices files prove themselves
local function devfile(c, user) return '{"device":"' .. c.id .. '","user":"' .. user .. '"}' end
local state = {}
local rel = "_band/devices/James.json"
local body = devfile(owner, "James")
local side = sw.make(owner.sign, owner.pub, STUDIO, rel, sw.next_seq(nil, NOW), body)
check(side and sw.device_file_ok(verify, state, STUDIO, rel, body, side, NOW, trust.user_file) == true, "a devices file signed by its own computer")
local forged = devfile(owner, "James")
local fside = sw.make(member.sign, member.pub, STUDIO, rel, sw.next_seq(NOW * 1000, NOW + 1), forged)
local ok, why = sw.device_file_ok(verify, state, STUDIO, rel, forged, fside, NOW + 1, trust.user_file)
check(ok == false and why:find("didn't sign"), "a member's devices file naming the owner's computer is refused: " .. tostring(why))
local other = "_band/devices/Bee.json"
local oside = sw.make(owner.sign, owner.pub, STUDIO, other, sw.next_seq(nil, NOW), body)
ok, why = sw.device_file_ok(verify, state, STUDIO, other, body, oside, NOW, trust.user_file)
check(ok == false and why:find("another name"), "a devices file under another person's name is refused")

-- a manager's file
local pins = { owner = "James", admins = { "Ann" }, devices = { James = { owner.id }, Ann = { admin.id }, Moe = { member.id } } }
local brel = "_band/band.json"
local seq1 = sw.next_seq(nil, NOW)
local b1 = '{"admins":["Ann"],"owner":"James","roles_at":1}'
local s1 = sw.make(owner.sign, owner.pub, STUDIO, brel, seq1, b1)
ok, why = sw.manager_ok(verify, state, pins, bee.id, STUDIO, brel, b1, s1, NOW)
check(ok == true and why == owner.id, "the owner's band.json is taken (on Bee's computer)")
local seq2 = sw.next_seq(seq1, NOW + 5)
local b2 = '{"admins":["Ann","Moe"],"owner":"James","roles_at":2}'
local s2 = sw.make(admin.sign, admin.pub, STUDIO, brel, seq2, b2)
check(sw.manager_ok(verify, state, pins, bee.id, STUDIO, brel, b2, s2, NOW + 5) == true, "an admin's later one too")
local b3 = '{"admins":["Ann"],"owner":"Moe","roles_at":3}'
local s3 = sw.make(member.sign, member.pub, STUDIO, brel, sw.next_seq(seq2, NOW + 9), b3)
ok, why = sw.manager_ok(verify, state, pins, bee.id, STUDIO, brel, b3, s3, NOW + 9)
check(ok == false and why:find("isn't the owner's"), "a member making themselves owner is refused")
check(state[brel].seq == seq2, "and a refused signer doesn't move the mark")
check(sw.manager_ok(verify, state, pins, bee.id, STUDIO, brel, b3, s3, NOW + 9) == false, "refused again")
-- but a computer's own write counts (its panel checked who may), as trust.from_manager's `mine`
check(sw.from_manager(pins, member.id, member.id) and not sw.from_manager(pins, member.id, owner.id), "this computer's own writing counts, only here")

-- rollback and equivocation
ok, why = sw.manager_ok(verify, state, pins, bee.id, STUDIO, brel, b1, s1, NOW + 20)
check(ok == false and why:find("older"), "the owner's older band.json put back is refused: " .. tostring(why))
check(sw.manager_ok(verify, state, pins, bee.id, STUDIO, brel, b2, s2, NOW + 20) == true, "the same newest copy again is fine")
local b2x = '{"admins":["Ann","Moe","Zed"],"owner":"James","roles_at":2}'
local s2x = sw.make(admin.sign, admin.pub, STUDIO, brel, seq2, b2x)
ok, why = sw.manager_ok(verify, state, pins, bee.id, STUDIO, brel, b2x, s2x, NOW + 21)
check(ok == false and why:find("same number"), "a different file under a number already taken is refused")
local far = sw.make(owner.sign, owner.pub, STUDIO, brel, (NOW + 3 * 86400) * 1000, b1)
ok, why = sw.manager_ok(verify, state, pins, bee.id, STUDIO, brel, b1, far, NOW + 22)
check(ok == false and why:find("ahead"), "a number days ahead (which would freeze everyone else's writes) is refused")
check(state[brel].seq == seq2, "the mark is still the admin's")

-- moved, changed, out of step
ok, why = sw.manager_ok(verify, {}, pins, bee.id, STUDIO, "_band/roles.json", b2, s2, NOW + 30)
check(ok == nil and why:find("match"), "a signed band.json copied to roles.json doesn't verify")
ok = sw.manager_ok(verify, {}, pins, member.id, "studiosync-other-0002", brel, b2, s2, NOW + 30)
check(ok == nil, "nor in another studio")
ok, why = sw.manager_ok(verify, {}, pins, bee.id, STUDIO, brel, b2:gsub("Moe", "Mob"), s2, NOW + 30)
check(ok == nil and why:find("match"), "a changed byte doesn't verify (not yet: the file and its sidecar may still be arriving)")
ok, why = sw.manager_ok(verify, {}, pins, bee.id, STUDIO, brel, nil, s2, NOW + 30)
check(ok == nil and why:find("isn't here"), "a sidecar ahead of its file: not yet")
ok, why = sw.manager_ok(verify, {}, pins, bee.id, STUDIO, brel, b2, nil, NOW + 30)
check(ok == nil and why:find("not signed"), "an unsigned file: not yet (the caller keeps what it had)")
ok, why = sw.signer(verify, STUDIO, brel, b2, s2:gsub('"by":"[^"]+"', '"by":"' .. owner.id .. '"'))
check(ok == false and why:find("isn't its key's"), "a sidecar claiming another computer's id over its own key is refused")
ok, why = sw.signer(verify, STUDIO, brel, b2, string.rep(" ", 3000))
check(ok == false and why:find("too big"), "an oversized sidecar is refused before it's parsed")
check(sw.signer(verify, STUDIO, "../x.json", b2, s2) == false and sw.make(owner.sign, owner.pub, STUDIO, "a/../b", 1, "x") == nil, "paths stay inside the studio")

-- deletion as a signed tombstone (trust.deleted_by_manager)
local mrel = "_band/removed/Moe.json"
local mbody = '{"at":1,"user":"Moe"}'
local ms = sw.make(owner.sign, owner.pub, STUDIO, mrel, sw.next_seq(nil, NOW), mbody)
local mstate = {}
check(sw.manager_ok(verify, mstate, pins, bee.id, STUDIO, mrel, mbody, ms, NOW) == true, "the owner's removal mark")
local gone = sw.make(member.sign, member.pub, STUDIO, mrel, sw.next_seq(mstate[mrel].seq, NOW + 1), nil, true)
ok, why = sw.manager_ok(verify, mstate, pins, bee.id, STUDIO, mrel, nil, gone, NOW + 1)
check(ok == false, "the member deleting their own removal mark is refused: " .. tostring(why))
local undone = sw.make(owner.sign, owner.pub, STUDIO, mrel, sw.next_seq(mstate[mrel].seq, NOW + 2), nil, true)
local by, _, _, deleted = sw.signer(verify, STUDIO, mrel, nil, undone)
check(by == owner.id and deleted, "the owner's tombstone names the owner and says deleted")
check(sw.manager_ok(verify, mstate, pins, bee.id, STUDIO, mrel, nil, undone, NOW + 2) == true, "and is taken")
check(sw.manager_ok(verify, mstate, pins, bee.id, STUDIO, mrel, mbody, ms, NOW + 3) == false, "the old mark put back after it is refused")

-- the 7-character compare: Syncthing's modifiedBy is 7 characters, so trust.lua compares prefixes; a made-up id sharing the owner's first 7
-- passes there, never with whole ids
local lookalike = owner.id:sub(1, 7) .. member.id:sub(8)
check(trust.from_manager(pins, lookalike:sub(1, 7), nil), "trust.from_manager goes by 7 characters (Syncthing's short id)")
check(not sw.from_manager(pins, lookalike, nil), "sw.from_manager goes by the whole id")

clean()
print("ok signed writes")
