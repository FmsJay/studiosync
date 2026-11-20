-- Joining without Syncthing's device approval step (lib/joins.lua, docs/realtime-roadmap.md "More big ideas" 6): the signed token (made,
-- parsed, every field covered by the signature), the check (another key, a changed field, run out, too long, used by another computer, the same
-- computer again), the whole ask on the computer that made it against a stand-in Syncthing (its command line, which StudioSync drives the
-- config through: the device added and the folder shared only for a valid invitation; nothing on a replay, a revoked or run-out one, a record
-- no manager wrote, someone no longer in charge, someone taken out since; a failed share leaves it unused), the welcome keyed with the
-- signature, the joiner's ask and welcome, joins.admitted for the others. Ed25519 is tools/sign_release.py's (the extension's twin, checked
-- against it by tests/sign_cross.py), through lupa's `python`. Lupa, repo root.
package.path = "lib/?.lua;" .. package.path
local SEP = package.config:sub(1, 1)
local T = (os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"):gsub("\\", "/") .. "/ss_joins_" .. os.time() .. "_" .. math.random(100000, 999999)
local function clean() os.execute(SEP == "\\" and ('rmdir /s /q "' .. T:gsub("/", "\\") .. '" 2>nul') or ("rm -rf '" .. T .. "'")) end

python.eval("__import__('sys').path.insert(0, 'tools')")
local sr = python.eval("__import__('sign_release')")
local py_sign = python.eval("lambda sr, kp, m: sr.sign(sr.load_seed(kp), m.encode('utf-8')).hex()")
local py_key = python.eval("lambda sr, kp: sr.public_key(sr.new_key(kp)).hex()")
local py_verify = python.eval("lambda sr, s, m, k: sr.verify(bytes.fromhex(k), m.encode('utf-8'), bytes.fromhex(s))")

-- the stand-in Syncthing: its config as `syncthing cli config ...` changes and reads it
local st = { devices = {}, folders = { ["studiosync-r-0001"] = {} }, fail_share = false, calls = 0 }
local function syncthing(cmd)
  st.calls = st.calls + 1
  local id, name = cmd:match(' cli config devices add %-%-device%-id ([%u%d%-]+) %-%-name "([^"]*)"')
  if not id then id = cmd:match(" cli config devices add %-%-device%-id ([%u%d%-]+)$") end
  if id then
    if st.devices[id] then return "1\ndevice already exists" end
    st.devices[id] = name or ""
    return "0\n"
  end
  local f, dev = cmd:match(" cli config folders ([%w%-]+) devices add %-%-device%-id ([%u%d%-]+)")
  if f then
    if st.fail_share or not st.folders[f] or not st.devices[dev] then return "1\nno such device or folder" end
    st.folders[f][dev] = true
    return "0\n"
  end
  return "1\nnot in the stand-in: " .. cmd
end

local ext, clock, logs, sent, started, stopped, polls = {}, 1000, {}, {}, {}, {}, {}
local function guid() local t = {}; for i = 1, 32 do t[i] = string.format("%x", math.random(0, 15)) end; return "{" .. table.concat(t) .. "}" end
reaper = setmetatable({
  GetOS = function() return "Win64" end,
  time_precise = function() return clock end,
  GetExtState = function(_, k) return ext[k] or "" end, SetExtState = function(_, k, v) ext[k] = v end, DeleteExtState = function(_, k) ext[k] = nil end,
  genGuid = guid,
  RecursiveCreateDirectory = function() return 1 end,
  ExecProcess = function(cmd) return syncthing(cmd) end,
  StudioSync_KeyCreate = function(kp) return py_key(sr, kp) end,
  StudioSync_Sign = function(kp, m) return py_sign(sr, kp, m) end,
  StudioSync_Verify = function(s, m, k) local ok, r = pcall(py_verify, sr, s, m, k); return ok and r and 1 or 0 end,
  StudioSync_DirectStart = function(studio, secret, inbox, port) started[studio] = { secret = secret, port = port }; return 1 end,
  StudioSync_DirectStop = function(studio) stopped[#stopped + 1] = studio; started[studio] = nil end,
  StudioSync_DirectMsg = function(studio, kind, data, peers) sent[#sent + 1] = { studio = studio, kind = kind, data = data, peers = peers }; return 1 end,
  StudioSync_DirectMsgPoll = function(after) for _, m in ipairs(polls) do if m[1] > after then return table.concat(m, "\t") end end; return "" end,
}, { __index = function() return function() return "" end end })

local band = require("band")
local fs = {}
band.log = function(s) logs[#logs + 1] = s end
band.read_json = function(p) local v = fs[p]; return type(v) == "table" and band.json_decode(band.json_encode(v)) or nil end
band.write_json = function(p, t) fs[p] = band.json_decode(band.json_encode(t)) end
band.remove = function(p) fs[p] = nil end
band.files = function(d, ext_) local out = {}; for p in pairs(fs) do local dir, n = p:match("^(.*)/([^/]+)$"); if dir == d and (not ext_ or n:sub(-#ext_) == ext_) then out[#out + 1] = n end end; table.sort(out); return out end
band.subdirs = function(d) if d == "/r" then return { "_band", "Song A", "Song B", "Notes" } end return {} end
local ST = T .. "/syncthing.exe"
reaper.file_exists = function(p) return p == ST or fs[p] ~= nil end
ext["syncthing_path"] = ST
local ROOT, ID = "/r", "studiosync-r-0001"
local bands = { { root = ROOT, id = ID, name = "R" } }
band.bands = function() return bands end
fs[ROOT .. "/_band/band.json"] = { name = "R", id = ID, owner = "James", admins = { "Bo" }, sonobus = "the-studio-secret" }
fs[ROOT .. "/Song A/session.json"], fs[ROOT .. "/Song B/session.json"] = {}, {}

local manage, trusted, outs, lets, fw = { James = true }, {}, {}, {}, true
package.loaded.direct = { available = function() return true end, live_available = function() return true end, enabled = function() return true end,
  firewall_ok = function() return fw end, port = function() return 47281 end,
  parse_msg = function(s) local q, a, b, c = tostring(s or ""):match("^(%d+)\t([^\t]+)\t([^\t]+)\t(.*)$"); return tonumber(q), a, b, c end }
package.loaded.groups = { may_manage = function(_, u) return manage[u] == true end, is_old = function() return false end,
  tailnet = function() return { name = "studio", suffix = "tail1234.ts.net" } end }
package.loaded.trust = { from_manager_file = function(_, rel) if trusted[rel] == nil then return true end return trusted[rel] end }
package.loaded.removal = { out_since = function(_, id) return outs[id] end, when = function() return "soon" end }
package.loaded.access = { read = function() return nil end, shows = function(s, song) return not s or s[song] == true end }
local services = require("services")
package.loaded.tools = { let_in = function(d, me, ends) local ok, why = services.share_folder(d.folder, d.id); lets[#lets + 1] = { d = d, me = me, ends = ends, ok = ok }; return ok, why end }
local joins = require("joins")

local HOST_DEV = "HOSTAAA-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG-HHHHHHH"
local BO_DEV = "BOBOBOB-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG-HHHHHHH"
local EVE_DEV = "EVEEVEE-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG-HHHHHHH"
ext["user"] = "James"
services.my_device_id = function() return HOST_DEV end
services.my_tailscale_name = function() return "desktop.tail1234.ts.net." end
joins.key_path = function() return T .. "/home/.studiosync/invite-key" end
local function check(cond, what) if not cond then clean(); error(what, 2) end end
local function ask(tok, dev, name, reply) return { token = type(tok) == "string" and tok or joins.encode(tok), device = dev, name = name, reply = reply } end
local now = 1800000000

-- ---- the token ---------------------------------------------------------------------------------------------------------------------------
local text, tok = joins.make(ROOT, "member", now)
check(text and text:sub(1, #joins.PREFIX) == joins.PREFIX, "an invitation is made: " .. tostring(text))
local p = joins.parse("Join R on StudioSync. Paste this:\n" .. text .. "\nthanks")
check(p and p.studio == ID and p.id == tok.id and p.role == "member" and p.ends == now + joins.LIFE and p.host == "desktop.tail1234.ts.net"
  and p.device == HOST_DEV and p.sig == tok.sig and p.name == "R", "it parses out of a whole message, every field as made (the host without its last dot)")
check(joins.encode(p) == text, "and encodes back the same")
local rec = fs[ROOT .. "/_band/joins/" .. tok.id .. ".json"]
local my_key = py_key(sr, T .. "/home/.studiosync/invite-key")
check(rec and rec.key == my_key and rec.made == now and rec.ends == now + joins.LIFE and rec.by == "James" and rec.dev == HOST_DEV and rec.role == "member"
  and not rec.secret and not rec.sig, "its record holds the public key and the grant, never the signature (the bearer part)")
check((band.ext_json(band.SECTION, "joins open") or {})[tok.id], "it's among this computer's open invitations")
local function swap(s_, a_, b_) local i, j = s_:find(a_, 1, true); return s_:sub(1, i - 1) .. b_ .. s_:sub(j + 1) end
check(not joins.parse(swap(text, ID, "default")) and not joins.parse(swap(text, ":member:", ":owner:")) and not joins.parse("studiosync-invite:garbage"),
  "not a StudioSync folder, a role that isn't member or guest, or a broken token: nothing")
local sp = services.parse_join("hello\n" .. text)
check(sp and sp.invite and sp.id == HOST_DEV and sp.band == ID and sp.name == "R", "services.parse_join takes an invitation: pairs with the computer that made it")
local has = services.invite_text(HOST_DEV, { id = ID, name = "R" }, nil, "has", text)
check(has:find(text, 1, true) and not has:find("studiosync-join:", 1, true) and has:find("by itself", 1, true), "the 'has StudioSync' message carries the invitation in place of the join code")
check(services.invite_text(HOST_DEV, { id = ID, name = "R" }, nil, "has"):find("studiosync-join:", 1, true), "without one, the join code as before")

-- ---- the check (pure) --------------------------------------------------------------------------------------------------------------------
local function verify(s, m, k) return reaper.StudioSync_Verify(s, m, k) == 1 end
local function variant(field, v) local t = {}; for k, x in pairs(p) do t[k] = x end; t[field] = v; return t end
check(joins.check(p, rec, now + 10, my_key, nil, BO_DEV, verify) == true, "a fresh invitation holds")
local okr, why = joins.check(variant("role", "guest"), rec, now + 10, my_key, nil, BO_DEV, verify)
check(not okr and why:find("match"), "a member's turned into a guest's: doesn't match its record")
okr, why = joins.check(variant("name", "Other"), rec, now + 10, my_key, nil, BO_DEV, verify)
check(not okr and why:find("signature"), "the name changed: the signature doesn't check")
okr, why = joins.check(variant("host", "evil.tail1234.ts.net"), rec, now + 10, my_key, nil, BO_DEV, verify)
check(not okr and why:find("signature"), "the host changed: the signature doesn't check")
local flipped = p.sig:sub(1, 10) .. (p.sig:sub(11, 11) == "0" and "1" or "0") .. p.sig:sub(12)
okr, why = joins.check(variant("sig", flipped), rec, now + 10, my_key, nil, BO_DEV, verify)
check(not okr and why:find("signature"), "one digit of the signature changed: refused")
local other = py_key(sr, T .. "/other-key")
okr, why = joins.check(p, rec, now + 10, other, nil, BO_DEV, verify)
check(not okr and why:find("another computer"), "a record made under another computer's key: only that computer lets anyone in with it")
okr, why = joins.check(p, rec, now + joins.LIFE, my_key, nil, BO_DEV, verify)
check(not okr and why:find("run out"), "at its end: run out")
local long = { id = rec.id, studio = rec.studio, role = rec.role, ends = rec.ends, made = now - joins.MAX_LIFE, key = rec.key }
okr, why = joins.check(p, long, now + 10, my_key, nil, BO_DEV, verify)
check(not okr and why:find("longer"), "a record saying it was made over a week before its end: not believed")
okr, why = joins.check(p, rec, now + 10, my_key, EVE_DEV, BO_DEV, verify)
check(not okr and why:find("used"), "used by another computer already: refused (one use)")
okr, why = joins.check(p, rec, now + 10, my_key, BO_DEV, BO_DEV, verify)
check(okr and why == "again", "the same computer asking again: holds, as 'again' (only the welcome goes)")
check(not joins.valid_request({ token = text, device = "nope" }) and not joins.valid_request({ device = BO_DEV }) and not joins.valid_request("x"),
  "an ask without a device id or a token: nothing")
check(joins.valid_request({ token = text, device = BO_DEV, name = "$(rm -rf /)", reply = "bo laptop" }).reply == nil, "a reply that isn't a plain name is dropped")

-- ---- the ask, on the computer that made it, against the stand-in Syncthing ---------------------------------------------------------------
local ok
ok, why = joins.on_request(ask(text, BO_DEV, "Bo", "bo-laptop.tail1234.ts.net"), now + 30)
check(ok and why == nil, "a valid ask is let in: " .. tostring(why))
check(st.devices[BO_DEV] == "Bo" and st.folders[ID][BO_DEV], "the stand-in Syncthing has the joiner's device, named, and the studio's folder shared with it")
check(#lets == 1 and lets[1].d.folder == ID and lets[1].d.root == ROOT and lets[1].ends == nil and lets[1].me == "James", "let in as a member the way Let them in does")
check(ext["join used " .. tok.id] == BO_DEV and fs[ROOT .. "/_band/joins/" .. tok.id .. ".json"].used.device == BO_DEV, "marked used, here and in its record (the others meet them by it)")
local w = sent[#sent]
check(w and w.studio == "join-" .. tok.id and w.kind == "welcome" and w.peers == "bo-laptop.tail1234.ts.net:47281" and started["join-" .. tok.id].secret == tok.sig,
  "the welcome goes to the joiner's Tailscale name, keyed with the token's signature")
local wd = band.json_decode(w.data)
check(wd.name == "R" and wd.owner == "James" and #wd.songs == 2 and wd.songs[1] == "Song A" and not w.data:find("the-studio-secret", 1, true),
  "it says who's in charge and the projects, never the studio's secrets")
local nsent, ncalls = #sent, st.calls
ok, why = joins.on_request(ask(text, EVE_DEV, "Eve", "eve.tail1234.ts.net"), now + 40)
check(not ok and why:find("used") and not st.devices[EVE_DEV] and #sent == nsent and #lets == 1, "the same token from another computer (a replay): refused, nothing added, nothing sent")
ok, why = joins.on_request(ask(text, BO_DEV, "Bo", "bo-laptop.tail1234.ts.net"), now + 32)
check(ok and why == "again" and #lets == 1 and #sent == nsent, "the joiner asking again within 5 s: no second let-in, no second welcome")
ok, why = joins.on_request(ask(text, BO_DEV, "Bo", "bo-laptop.tail1234.ts.net"), now + 45)
check(ok and why == "again" and #lets == 1 and #sent == nsent + 1, "later: the welcome again (a lost one), still no second let-in")
check(st.calls - ncalls == 0, "and Syncthing's config isn't touched for a refused or repeated ask")
ok = joins.on_request(ask(text, BO_DEV, "Bo", "bo.example.com"), now + 60)
check(ok and #sent == nsent + 1, "a reply outside the studio's Tailscale network gets no welcome")

-- run out, revoked, a record no manager wrote, no longer in charge, taken out since, another key's token
local t2, k2 = joins.make(ROOT, "member", now)
ok, why = joins.on_request(ask(t2, EVE_DEV, "Eve"), now + joins.LIFE + 1)
check(not ok and why:find("run out") and not st.devices[EVE_DEV], "a run-out invitation lets nobody in")
local t3, k3 = joins.make(ROOT, "member", now)
joins.revoke(ROOT, k3.id)
ok, why = joins.on_request(ask(t3, EVE_DEV, "Eve"), now + 10)
check(not ok and why:find("no such") and not st.devices[EVE_DEV], "a revoked invitation (its record gone) lets nobody in")
local t4, k4 = joins.make(ROOT, "member", now)
trusted["_band/joins/" .. k4.id .. ".json"] = false
ok, why = joins.on_request(ask(t4, EVE_DEV, "Eve"), now + 10)
check(not ok and why:find("owner or admin") and not st.devices[EVE_DEV], "a record Syncthing says a member wrote: refused")
trusted["_band/joins/" .. k4.id .. ".json"] = nil
manage.James = false
ok, why = joins.on_request(ask(t4, EVE_DEV, "Eve"), now + 10)
check(not ok and why:find("owner or an admin") and not st.devices[EVE_DEV], "made while an admin, used after they no longer are: refused")
manage.James = true
outs[EVE_DEV] = "Eve"
ok, why = joins.on_request(ask(t4, EVE_DEV, "Eve"), now + 10)
check(not ok and why:find("taken out") and not st.devices[EVE_DEV] and ext["join used " .. k4.id] == nil, "someone taken out since it was made: refused, and it stays unused")
outs[EVE_DEV] = nil
local forged = { studio = ID, id = k4.id, role = "member", ends = k4.ends, host = k4.host, device = HOST_DEV, name = "R" }
forged.sig = py_sign(sr, T .. "/other-key", joins.message(forged))
ok, why = joins.on_request(ask(forged, EVE_DEV, "Eve"), now + 10)
check(not ok and why:find("signature") and not st.devices[EVE_DEV], "the record's id with a token signed by another key: refused")
-- a share that fails leaves it unused, so the next ask (10 s on) tries again
st.fail_share = true
ok = joins.on_request(ask(t4, EVE_DEV, "Eve"), now + 10)
check(not ok and ext["join used " .. k4.id] == nil and not fs[ROOT .. "/_band/joins/" .. k4.id .. ".json"].used, "Syncthing didn't share it: not marked used")
st.fail_share = false
ok = joins.on_request(ask(t4, EVE_DEV, "Eve"), now + 20)
check(ok and st.folders[ID][EVE_DEV] and ext["join used " .. k4.id] == EVE_DEV, "the next ask goes through (the device known from the try before)")
-- a guest's invitation lets them in as a guest, with its time
local t5, k5 = joins.make(ROOT, "guest", now)
local G_DEV = "GUESTGU-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG-HHHHHHH"
ok = joins.on_request(ask(t5, G_DEV, "Gil"), now + 10)
check(ok and lets[#lets].ends == k5.ends and k5.role == "guest", "a guest's invitation: let in as a guest (the guest note's time wins in let_in, else the invitation's end)")

-- ---- the others in the studio: joins.admitted --------------------------------------------------------------------------------------------
check(joins.admitted(ROOT, BO_DEV, now + 100) == "Bo", "a used record a manager wrote names the joiner: the others add it when it asks")
check(joins.admitted(ROOT, "ZZZZZZZ-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG-HHHHHHH", now + 100) == nil, "another computer: nobody")
trusted["_band/joins/" .. tok.id .. ".json"] = false
check(joins.admitted(ROOT, BO_DEV, now + 100) == nil, "a record a member rewrote naming someone: not believed")
trusted["_band/joins/" .. tok.id .. ".json"] = nil
check(joins.admitted(ROOT, BO_DEV, now + 30 + joins.KEEP_USED) == nil, "a week on: no longer (their own devices file does it by then)")

-- ---- no link to hear it: no invitation (today's join code) ------------------------------------------------------------------------------
fw = false
check(joins.make(ROOT, "member", now) == nil, "no firewall rule here (Windows): nothing made, the plain join code goes")
fw = true
manage.James = false
check(joins.make(ROOT, "member", now) == nil, "a member can't make one")
manage.James = true

-- ---- the tick on the computer that made them: the ask channel, an ask from the link -------------------------------------------------------
local t6, k6 = joins.make(ROOT, "member", now)
local K_DEV = "KIMKIMK-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG-HHHHHHH"
polls[#polls + 1] = { 1, joins.CHANNEL, "join", band.json_encode(ask(t6, K_DEV, "Kim", "kim.tail1234.ts.net")) }
local N_DEV = "NEWNEWN-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG-HHHHHHH"
polls[#polls + 1] = { 2, "studiosync-other", "join", band.json_encode(ask(t2, N_DEV, "Nat")) }
clock = clock + 5
joins.tick(now + 50)
check(started[joins.CHANNEL] and started[joins.CHANNEL].secret == joins.CHANNEL_SECRET and started[joins.CHANNEL].port == 47281, "open invitations: the ask channel listens")
check(st.folders[ID][K_DEV] and not st.devices[N_DEV], "an ask on the channel is let in; the same words under another studio's name aren't read as one")

-- ---- the joiner -------------------------------------------------------------------------------------------------------------------------
-- (another computer: its own device and name; the studio not here yet)
services.my_device_id = function() return BO_DEV end
services.my_tailscale_name = function() return "bo-laptop.tail1234.ts.net." end
ext["user"] = "Bo"
local JR = "/joined"
local t7, k7 = text, tok
nsent = #sent
check(joins.request(JR, joins.parse(t7)), "the joiner's ask is queued")
local a = sent[#sent]
local ad = band.json_decode(a.data)
check(a.studio == joins.CHANNEL and a.kind == "join" and a.peers == "desktop.tail1234.ts.net:47281" and ad.token == t7 and ad.device == BO_DEV and ad.reply == "bo-laptop.tail1234.ts.net",
  "to the computer the token names, on the ask channel: the token, this computer's device and Tailscale name")
check(started["join-" .. k7.id] and started["join-" .. k7.id].secret == k7.sig, "it listens for the welcome keyed with the signature")
check(joins.state(JR) == "asking", "the Studios page says it's asking")
check(not joins.on_welcome(k7.id, { studio = "studiosync-x", id = k7.id }) and joins.state(JR) == "asking", "a welcome for another studio: ignored")
check(joins.on_welcome(k7.id, { studio = ID, id = k7.id, songs = { "Song A", "Song B" }, owner = "James" }) and joins.state(JR) == "in", "the welcome: in")
check((band.ext_json(band.SECTION, "joins pending") or {})[JR] == nil, "and it no longer asks")
-- asking again until it's in, then stopping; run out: said
joins.request(JR, joins.parse(t7))
nsent = #sent
clock = clock + 5
joins.tick(now + 100)
check(#sent == nsent, "within RESEND: not asked again")
clock = clock + joins.RESEND
joins.tick(now + 110)
check(#sent == nsent + 1 and sent[#sent].kind == "join", "after RESEND s: asked again")
fs[JR .. "/_band/band.json"] = { name = "R", id = ID }
clock = clock + joins.RESEND
joins.tick(now + 130)
check(#sent == nsent + 1 and (band.ext_json(band.SECTION, "joins pending") or {})[JR] == nil, "band.json arrived (Syncthing let it in): it stops asking")
fs[JR .. "/_band/band.json"] = nil
joins.request(JR, joins.parse(t7))
clock = clock + joins.RESEND
joins.tick(k7.ends + 1)
check((band.ext_json(band.SECTION, "joins pending") or {})[JR] == nil and logs[#logs]:find("ran out"), "run out before it got through: dropped, and said")

clean()
print("ok joins: token, check, ask against a stand-in Syncthing, replay/expiry/revoke, welcome, joiner")
