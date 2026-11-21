-- Signed writes, wired in beside Syncthing's check, and those files sent over the direct link the moment they're written (docs/rt/rt-linkfirst.md;
-- the pure part, signatures and sequence numbers, is lib/signedwrites.lua from docs/rt/rt-lite.md stage B).
--  - Each computer has its own Ed25519 key (~/.studiosync/device-key, the extension's StudioSync_KeyCreate/Sign/Verify, as invitations use).
--    Every write of a manager-only file (band.json, roles.json, closed.json, removal and guest marks, guest lists, invitation records, devices
--    files, a room's mode.json, driver.json and room.json, grants, given claims) puts a signature beside it, <file>.sig (band.write_json's hook);
--    deleting a removal mark leaves a signed tombstone (band.remove's).
--  - Which key is whose computer: each devices file carries its computer's public key (`key`, lib/removal.lua publish). When lib/trust.lua
--    believes a devices file the way it always has (Syncthing says the computer it names wrote it), this computer notes that key as that
--    computer's ("signed keys <studio id>", kept). After that a valid signature by the key says that computer wrote the file, compared by the
--    whole id, without asking Syncthing (lib/trust.lua changed_by). An unsigned file, a stale signature (an older StudioSync wrote the file
--    since) or a key not known here yet: Syncthing's word, as before (the migration).
--  - Rollback: the highest sequence number taken per file is kept ("signed seqs <studio id>"); an older one is never a signature's word. Only
--    a signer some check accepted moves it (trust's took).
--  - The direct link: a signed file of LINK's kinds goes to the bandmates here as soon as it's written (an outbox Live sync empties each tick).
--    The receiver checks the signature, the key and the number, then puts it in band.overlay so this script reads it at once, and keeps it only
--    when the same trust check its readers make says yes. The Syncthing file stays the record: the copy that came by the link is dropped as soon
--    as the folder's file changes (band.read). Profiles and recaps, which no check guards today, go the same way unsigned (OWN).
-- Unreviewed (security reviews come after all features, James 2026-11-19). Review-later list: docs/rt/rt-linkfirst.md.
local band = require("band")
local sw = require("signedwrites")
local signed = { BODY_MAX = 32768, SEQS_MAX = 600 }

-- Which files are signed, by the path inside the studio: kind, or nil. Pure.
local KINDS = {
  { "^_band/band%.json$", "band" }, { "^_band/roles%.json$", "band" }, { "^_band/closed%.json$", "closed" },
  { "^_band/removed/[^/]+%.json$", "removed" }, { "^_band/guest%-access/[^/]+%.json$", "guests" },
  { "^_band/guest%-invites/[^/]+%.json$", "guests" }, { "^_band/joins/[^/]+%.json$", "joins" }, { "^_band/devices/[^/]+%.json$", "devices" },
  { "^[^/]+/rooms/[^/]+/mode%.json$", "mode" }, { "^[^/]+/rooms/[^/]+/driver%.json$", "room" }, { "^[^/]+/rooms/[^/]+/room%.json$", "room" },
  { "^[^/]+/rooms/[^/]+/grants/[^/]+%.json$", "grants" }, { "^[^/]+/rooms/[^/]+/claims/given%-[^/]+%.json$", "given" },
  -- (unsigned: files nobody checks today, each one person's; over the link only to be there sooner)
  { "^_band/profiles/[^/]+%.json$", "profile" }, { "^_band/colours/[^/]+%.json$", "colour" }, { "^[^/]+/rooms/[^/]+/recaps/[^/]+%.json$", "recap" },
  -- (one person's own files, signed, and over the link only from that person's own computer, signed.owner: the claims a driver or manager
  -- released, a person's track order, their handovers of a song's hub, a song's session.json, a profile's picture. rt-linkmove)
  { "^[^/]+/rooms/[^/]+/released/[^/]+%.json$", "released" }, { "^[^/]+/rooms/[^/]+/order/[^/]+%.json$", "order" },
  { "^[^_/][^/]*/hub/[^/]+%.json$", "hub" }, { "^[^_/][^/]*/session%.json$", "session" },
  { "^_band/profiles/[^/]+%.jpg$", "pic" }, { "^_band/profiles/[^/]+%.png$", "pic" },
}
signed.OWN = { profile = true, colour = true, recap = true }
-- What goes over the link the moment it's written. (Not: invitation records, driver.json (a "driver" event goes already) and room.json:
-- signed, and Syncthing carries them.)
signed.LINK = { band = true, closed = true, removed = true, guests = true, devices = true, mode = true, grants = true, profile = true, colour = true,
  recap = true, given = true, released = true, order = true, hub = true, session = true, pic = true }
-- A given claim is over once the person it's for folds it into their own claims and deletes it (sync.follow_claims), which another computer
-- may never see as a file: there the link's copy counts this long at most. shortcut: a minute, not "until their own claims carry it"; with
-- Syncthing slower than that on both computers the claim waits for the file, as before this.
signed.GIVEN_KEEP = 60
function signed.kind(rel)
  if not sw.rel_ok(rel) then return nil end
  for _, k in ipairs(KINDS) do if rel:find(k[1]) then return k[2] end end
  return nil
end
-- A written path -> the studio's folder, the path inside it, its kind; nil when it isn't one of KINDS. Pure.
function signed.locate(path)
  local p = tostring(path):gsub("\\", "/")
  local root, rest = p:match("^(.+)/(_band/.+)$")
  if not root then root, rest = p:match("^(.+)/([^/]+/rooms/[^/]+/.+)$") end
  if not root then -- (a song's own files, only in a folder that is a studio's: any folder may hold a session.json. rt-linkmove)
    root, rest = p:match("^(.+)/([^/]+/hub/[^/]+)$")
    if not root then root, rest = p:match("^(.+)/([^/]+/session%.json)$") end
    if root and band.read(root .. "/_band/band.json") == nil then return nil end
  end
  local kind = rest and signed.kind(rest)
  if not kind then return nil end
  return root, rest, kind
end

-- ---- this computer's key ---------------------------------------------------------------------------------------------------------------
function signed.key_path()
  local home = os.getenv("USERPROFILE") or os.getenv("HOME")
  return home and home ~= "" and (band.norm(home) .. "/.studiosync/device-key") or nil
end
local key_of = {}
-- -> this computer's public key (64 hex) and its key file, or nil (no extension 1.0.9, no home folder).
function signed.key()
  local p = signed.key_path()
  if not (p and reaper.StudioSync_KeyCreate and reaper.StudioSync_Sign) then return nil end
  if key_of[p] == nil then
    reaper.RecursiveCreateDirectory(p:match("^(.*)/[^/]+$"), 0)
    local k = tostring(reaper.StudioSync_KeyCreate(p) or ""):lower()
    key_of[p] = #k == 64 and k:match("^%x+$") and k or false
  end
  return key_of[p] or nil, p
end
function signed.my_id() local k = signed.key(); return k and sw.device_id(k) or nil end
local function verify(sig, msg, key) return reaper.StudioSync_Verify ~= nil and reaper.StudioSync_Verify(sig, msg, key) == 1 end
-- A profile's picture is bytes, and the extension signs text: what's signed, and what a message carries, is its base64. (rt-linkmove)
local function is_pic(rel) return rel:find("^_band/profiles/[^/]+%.[jp][pn]g$") ~= nil end
local function as_signed(rel, bytes) if bytes and is_pic(rel) then return require("profile").base64(bytes) end return bytes end

-- ---- kept per studio: whose key is which computer, and the numbers taken -------------------------------------------------------------------
local function ext_key(what, root) return "signed " .. what .. " " .. tostring(band.info(root).id) end
local function load(what, root) local t = band.ext_json(band.SECTION, ext_key(what, root)); return type(t) == "table" and t or {} end
local function save(what, root, t) band.set_ext_json(band.SECTION, ext_key(what, root), t, true) end
-- The computer (its Syncthing id, whole) whose key `id` (a key-made id) is, as noted here; or nil.
function signed.computer_of(root, id)
  if type(id) ~= "string" then return nil end
  if id == signed.my_id() then return require("services").my_device_id() end
  for dev, k in pairs(load("keys", root)) do if k == id then return dev end end
  return nil
end
-- lib/trust.lua believed the devices file naming `device`, which carries `pub`: that key is that computer's from now on. Never from a signature.
function signed.note_key(root, device, pub)
  local id = sw.device_id(type(pub) == "string" and pub:lower() or nil)
  if not (id and require("services").is_device_id(device)) then return end
  local t = load("keys", root)
  if t[device] ~= id then t[device] = id; save("keys", root, t) end
end
-- For a computer an invitation lets in (lib/joinboot.lua, rt-joinlink): the keys this one has noted, and its own. { [device] = key id }.
function signed.known_keys(root)
  local t = {}
  for dev, k in pairs(load("keys", root)) do t[dev] = k end
  local mine, dev = signed.my_id(), require("services").my_device_id()
  if mine and dev then t[dev] = mine end
  return t
end
-- The keys in the sealed welcome from the computer that let this one in (the one whose writing of the roles an invited computer believes
-- first, lib/trust.lua): each taken only where no key is noted for that computer yet, never replacing one. -> how many were taken.
function signed.seed_keys(root, keys)
  local t, n = load("keys", root), 0
  for dev, id in pairs(type(keys) == "table" and keys or {}) do
    if n < 500 and require("services").is_device_id(dev) and sw.key_of(id) and t[dev] == nil then t[dev], n = id, n + 1 end
  end
  if n > 0 then save("keys", root, t) end
  return n
end
local function short(sig) return tostring(sig):sub(1, 16) end
-- For a computer an invitation lets in (lib/joinboot.lua): the newest number this computer has taken per signed file, so the joiner never
-- takes an older copy put back as its first (rt-lite stage B, "first use"). -> { { rel, seq, sig's first 16 } }, the studio's own files
-- first, then the newest, within `max` bytes of JSON. (rt-linkmove)
function signed.known_seqs(root, max)
  local list, out, size = {}, {}, 2
  for rel, v in pairs(load("seqs", root)) do
    if type(v) == "table" and math.type(v[1]) == "integer" and type(v[2]) == "string" then list[#list + 1] = { rel, v[1], v[2] } end
  end
  table.sort(list, function(a, b)
    local sa, sb = a[1]:sub(1, 6) == "_band/", b[1]:sub(1, 6) == "_band/"
    if sa ~= sb then return sa end
    if a[2] ~= b[2] then return a[2] > b[2] end
    return a[1] < b[1]
  end)
  for _, e in ipairs(list) do
    local n = #band.json_encode(e) + 1
    if size + n > (max or 0) then break end
    out[#out + 1], size = e, size + n
  end
  return out
end
-- The welcome's numbers, from the computer that let this one in: each a floor for its file, only ever raising what's kept here, never one
-- dated more than a day ahead (it would shut the real file out). The file with that very number and signature still passes. -> how many.
function signed.seed_seqs(root, seqs)
  local t, n, count = load("seqs", root), 0, 0
  for _ in pairs(t) do count = count + 1 end
  local ahead = (os.time() + 86400) * 1000
  for _, e in ipairs(type(seqs) == "table" and seqs or {}) do
    local rel, seq, sig = type(e) == "table" and e[1], type(e) == "table" and e[2], type(e) == "table" and e[3]
    local kind = type(rel) == "string" and signed.kind(rel)
    local was = kind and t[rel]
    if kind and not signed.OWN[kind] and math.type(seq) == "integer" and seq >= 0 and seq <= ahead and type(sig) == "string" and #sig == 16
        and sig:match("^%x+$") and (type(was) ~= "table" or (tonumber(was[1]) or 0) < seq) and (was or count < signed.SEQS_MAX) then
      if not was then count = count + 1 end
      t[rel], n = { seq, sig }, n + 1
    end
  end
  if n > 0 then save("seqs", root, t) end
  return n
end
-- Would (seq, sig) be news for `rel`, not a rollback? Pure but for the kept numbers.
local function fresh_ok(root, rel, seq, sig)
  local was = load("seqs", root)[rel]
  return sw.fresh(type(was) == "table" and { [rel] = { seq = tonumber(was[1]) or 0, sig = was[2] } } or {}, rel, seq, short(sig), os.time())
end
local function take(root, rel, seq, sig)
  local t = load("seqs", root)
  local was = t[rel]
  if type(was) == "table" and tonumber(was[1]) == seq and was[2] == short(sig) then return end
  t[rel] = { seq, short(sig) }
  local n, oldest, okey = 0, math.huge, nil
  for k, v in pairs(t) do n = n + 1; if type(v) ~= "table" or (tonumber(v[1]) or 0) < oldest then oldest, okey = type(v) == "table" and tonumber(v[1]) or -1, k end end
  if n > signed.SEQS_MAX and okey then t[okey] = nil end -- shortcut: past SEQS_MAX files the oldest number is forgotten (first use again for it)
  save("seqs", root, t)
end

-- ---- reading ----------------------------------------------------------------------------------------------------------------------------
-- The file as this script reads it now (band.read: the link's copy while the folder's hasn't changed) and its signature file. -> bytes, sidecar.
function signed.current(root, rel)
  local path = root .. "/" .. rel
  local bytes = band.read(path)
  local o = band.overlay_of(path)
  if o then return as_signed(rel, o.bytes), o.side, true end
  -- (not in the folder: a copy a join's welcome brought, band.boot_copy, which Syncthing knows nothing of either: its signature or not yet.
  -- lib/joinboot.lua, rt-joinlink)
  if bytes ~= nil and band.read_raw(path) == nil and band.boot_copy(path) == bytes then return bytes, band.read(path .. ".sig"), true end
  return as_signed(rel, bytes), band.read(path .. ".sig"), false
end
-- Which computer signed `rel` as it reads now: its Syncthing id (whole), when the signature is good, its key is a known computer's and its
-- number isn't older than one taken; else nil and whether the copy came by the link (then Syncthing knows nothing of it: no fallback).
local pending = {}
function signed.computer(root, rel)
  local bytes, side, linked = signed.current(root, rel)
  if not side then return nil, linked end
  local by, seq, sig = sw.signer(verify, tostring(band.info(root).id), rel, bytes, side)
  if not by or not fresh_ok(root, rel, seq, sig) then return nil, linked end
  local dev = signed.computer_of(root, by)
  if dev then pending[root .. "\0" .. rel] = { seq, sig } end
  return dev, linked
end
-- Some check accepted the file signed.computer just named a writer for: its number is taken.
function signed.taken(root, rel)
  local p = pending[root .. "\0" .. rel]
  if p then pending[root .. "\0" .. rel] = nil; take(root, rel, p[1], p[2]) end
end
-- Is `rel` a signed tombstone by a known computer? -> its Syncthing id, or nil.
function signed.deleted_by(root, rel)
  local _, side, linked = signed.current(root, rel)
  if band.read(root .. "/" .. rel) ~= nil or not side then return nil, linked end
  local by, seq, sig, deleted = sw.signer(verify, tostring(band.info(root).id), rel, nil, side)
  if not (by and deleted) or not fresh_ok(root, rel, seq, sig) then return nil, linked end
  local dev = signed.computer_of(root, by)
  if dev then pending[root .. "\0" .. rel] = { seq, sig } end
  return dev, linked
end

-- ---- writing (band.write_json's and band.remove's hooks) ------------------------------------------------------------------------------------
local OUTBOX = "signed outbox"
local function queue(root, rel)
  local q = reaper.GetExtState(band.SECTION, OUTBOX)
  local line = root .. "\t" .. rel
  for l in q:gmatch("[^\n]+") do if l == line then return end end
  reaper.SetExtState(band.SECTION, OUTBOX, (q ~= "" and q .. "\n" or "") .. line, false)
end
local function sign_side(root, rel, bytes, deleted)
  local pub, kp = signed.key()
  if not pub then return nil end
  local old = band.json_decode(band.read_raw(root .. "/" .. rel .. ".sig") or "") -- (its last number, whoever's: the next goes after it)
  local kept = load("seqs", root)[rel]
  local prev = math.max(type(old) == "table" and tonumber(old.seq) or 0, type(kept) == "table" and tonumber(kept[1]) or 0)
  local seq = sw.next_seq(prev, os.time())
  local side = sw.make(function(m) return reaper.StudioSync_Sign(kp, m) end, pub, tostring(band.info(root).id), rel, seq, bytes, deleted)
  if not side then return nil end
  band.write_atomic(root .. "/" .. rel .. ".sig", side)
  local t = band.json_decode(side)
  take(root, rel, seq, t and t.sig)
  return side
end
function signed.on_write(path)
  local root, rel, kind = signed.locate(path)
  if not kind then return end
  if not signed.OWN[kind] then
    local bytes = band.read(path)
    if not bytes or not sign_side(root, rel, bytes, false) then return end
  end
  if signed.LINK[kind] then queue(root, rel) end
  if kind == "profile" then -- (and its picture, written just before it by lib/profile.lua: signed as its person's, after the profile in the queue)
    local p = band.json_decode(band.read_raw(path) or "")
    local prel = type(p) == "table" and (p.pic == "jpg" or p.pic == "png") and rel:gsub("%.json$", "." .. p.pic)
    local raw = prel and band.read_raw(root .. "/" .. prel)
    if raw and #raw <= require("profile").PIC_MAX and sign_side(root, prel, as_signed(prel, raw), false) then queue(root, prel) end
  end
end
function signed.on_remove(path)
  local root, rel, kind = signed.locate(path)
  if kind ~= "removed" then return end
  if sign_side(root, rel, nil, true) then queue(root, rel) end
end

-- ---- the direct link ---------------------------------------------------------------------------------------------------------------------
-- Live sync's tick: what this computer wrote since, to the bandmates here (and those in the file's own room) now. Other studios' stay queued.
-- The link's copies still read here (band.overlay), as signed.on_msg put them in: path -> { root, kind, seq, till }.
local linked, tidied = {}, -math.huge
local forget
-- About once a second: a link's copy goes when the folder's signature file is numbered after it (Syncthing brought a newer one's signature
-- before its file, or the link's copy came late: never an older copy over a newer one), or when its time is up (a given claim: GIVEN_KEEP).
local function tidy()
  local now = reaper.time_precise()
  if next(linked) == nil or math.abs(now - tidied) < 1 then return end
  tidied = now
  for path, l in pairs(linked) do
    if not band.overlay_of(path) then linked[path] = nil
    else
      local have = l.seq and band.json_decode(band.read_raw(path .. ".sig") or "")
      if (l.till and now > l.till) or (type(have) == "table" and (tonumber(have.seq) or 0) > l.seq) then
        band.set_overlay(path, nil, nil, true)
        forget(l.root, l.kind)
        linked[path] = nil
      end
    end
  end
end
function signed.drain(cfg, song, room)
  tidy()
  local q = reaper.GetExtState(band.SECTION, OUTBOX)
  if q == "" then return 0 end
  local direct, keep, n = require("direct"), {}, 0
  for line in q:gmatch("[^\n]+") do
    local root, rel = line:match("^(.-)\t(.+)$")
    if root ~= cfg.root then keep[#keep + 1] = line
    else
      local path = root .. "/" .. rel
      local body, side = as_signed(rel, band.read_raw(path)), band.read_raw(path .. ".sig")
      if (body or side) and #(body or "") <= signed.BODY_MAX then
        local to, seen = {}, {}
        local fsong, froom = rel:match("^([^/]+)/rooms/([^/]+)/")
        local peers, _, users = direct.peers(cfg, song, room)
        -- (band.json holds the studio's secret, made new when someone is taken out: never to a bandmate with a removal mark, nor to one this
        -- script can't name. Syncthing stops syncing with them; the link mustn't hand it over meanwhile)
        local secret = rel == "_band/band.json"
        for _, p in ipairs(peers) do
          local u = users and users[p]
          if not seen[p] and not (secret and (type(u) ~= "string" or require("removal").mark(root, u))) then seen[p] = true; to[#to + 1] = p end
        end
        if fsong and not (fsong == song and froom == room) then
          for _, p in ipairs(direct.peers(cfg, fsong, froom)) do if not seen[p] then seen[p] = true; to[#to + 1] = p end end
        end
        if #to > 0 and direct.send_live(cfg, "signed", { rel = rel, body = body, side = side }, song, room, nil, to) then n = n + 1 end
      end
    end
  end
  reaper.SetExtState(band.SECTION, OUTBOX, table.concat(keep, "\n"), false)
  return n
end

-- Caches that hold what these files said, emptied when the link's copy goes in or out.
function forget(root, kind)
  band.forget_info()
  pcall(function() require("groups").forget_trusted(root) end)
  if kind == "devices" then pcall(function() require("direct").forget_devices(root) end) end
  if kind == "profile" or kind == "pic" then pcall(function() require("profile").forget(root) end) end
  if kind == "colour" then pcall(function() require("people").forget(root) end) end
end
-- The file name an OWN kind's file must have for the person it says it's for (as its writer names it). Pure.
local function own_name(kind, t)
  if type(t) ~= "table" then return nil end
  if kind == "colour" then return type(t.user) == "string" and (t.user:gsub("[^%w%-_ ]", "")) or nil end
  local who = kind == "profile" and t.user or type(t.recaps) == "table" and type(t.recaps[1]) == "table" and t.recaps[1].by
  return type(who) == "string" and require("sync").id_user(who) or nil
end
-- Whose file a person's own signed file is, by what it says and its name (as its readers check that), for lib/trust.lua file_ok to ask
-- trust.own_file_ok about: -> the person, or nil (not one of these, or not a file that person's may be). j: the file, decoded. (rt-linkmove)
local function ufile(u) return (tostring(u):gsub("[^%w%-_ ]", "")) .. ".json" end -- (trust.user_file, sync's claims and releases)
function signed.owner(root, rel, kind, j)
  local f = rel:match("([^/]+)$")
  if kind == "pic" then -- (the picture its person's profile names: lib/profile.lua)
    local p = band.read_json(root .. "/" .. rel:gsub("%.%a+$", ".json"))
    local name = own_name("profile", p)
    return name and p.pic == rel:match("%.(%a+)$") and name .. "." .. p.pic == f and p.user or nil
  end
  if kind == "released" then -- ({ [person] = when }, named for whoever released: the room's driver, or someone in charge. lib/sync.lua)
    local dev = band.read_json(root .. "/_band/devices/" .. f)
    local who = type(dev) == "table" and type(dev.user) == "string" and ufile(dev.user) == f and dev.user or nil
    if not who or type(j) ~= "table" then return nil end
    local song, room = rel:match("^([^/]+)/rooms/([^/]+)/")
    if require("groups").may_manage(root, who) then return who end
    local ok, driver = pcall(function() return require("sync").driver({ root = root }, song, room, band.read_json(root .. "/" .. song .. "/session.json")) end)
    return ok and driver == who and who or nil
  end
  if type(j) ~= "table" then return nil end
  if kind == "hub" then return type(j.user) == "string" and ufile(j.user) == f and type(j.transfers) == "table" and j.user or nil end -- (lib/hub.lua)
  if kind == "session" then return type(j.host) == "string" and j.host or nil end -- (whoever shared the song: lib/hub.lua transfers)
  if kind == "order" then return type(j.by) == "string" and j.by:gsub("[^%w%-_ ]", "_") .. ".json" == f and type(j.list) == "table" and j.by or nil end -- (lib/mirror.lua)
  return nil
end
-- A message "signed": { rel, body (nil: a tombstone), side }. -> true when it went in, or false and why.
function signed.on_msg(cfg, d)
  if type(d) ~= "table" or type(d.rel) ~= "string" or (d.body ~= nil and type(d.body) ~= "string") or (d.side ~= nil and type(d.side) ~= "string") then
    return false, "not a signed file"
  end
  local root, rel = cfg.root, d.rel
  local kind = signed.kind(rel)
  if not (kind and signed.LINK[kind]) then return false, "not a file that comes over the link" end
  if #(d.body or "") > signed.BODY_MAX or #(d.side or "") > sw.SIDE_MAX then return false, "too big" end
  local path = root .. "/" .. rel
  local body, seq = d.body, nil -- (body: the file's own bytes; d.body: what's signed, a picture's base64)
  if kind == "pic" then
    local profile = require("profile")
    body = d.body and profile.unbase64(d.body)
    local mime = body and profile.image_info(body)
    if not (mime and (mime == "image/png" and "png" or "jpg") == rel:match("%.(%a+)$")) then return false, "not a profile picture" end
  end
  local here = band.overlay_of(path) -- (the same message again, while its copy is the one read: nothing to check twice)
  if band.read(path) == body and (signed.OWN[kind] or (here and here.side or band.read(path .. ".sig")) == d.side) then return false, "already here" end
  -- (a claim given to this computer's person is folded into their own claims by sync.follow_claims, which must leave the link's copy alone
  -- until the folder's comes, or it folds it on every pass: taken here only where lib/sync.lua says it does, sync.GIVEN_WAITS. rt-linkmove)
  if kind == "given" then
    local g = band.json_decode(d.body or "")
    if type(g) == "table" and g.user == cfg.user and require("sync").GIVEN_WAITS ~= true then return false, "given to you: it counts when Syncthing brings it" end
  end
  if signed.OWN[kind] then -- (each one person's, checked by nobody today: only its shape, as its readers check it)
    local name = own_name(kind, d.body and band.json_decode(d.body))
    if not (name and name == rel:match("([^/]+)%.json$")) then return false, "not that person's file" end
  else
    if not d.side then return false, "not signed" end
    local by, n, sig, deleted = sw.signer(verify, tostring(band.info(root).id), rel, d.body, d.side)
    if not by then return false, n end
    if deleted and kind ~= "removed" then return false, "only a removal mark is taken back" end
    if not fresh_ok(root, rel, n, sig) then return false, "older than one already taken" end
    -- (nor older than the folder's own signature file, whoever wrote it and whether or not a check has taken it yet: the link's copy would be
    -- read over a newer file. rt-linkmove)
    local have = band.json_decode(band.read_raw(path .. ".sig") or "")
    if type(have) == "table" and (tonumber(have.seq) or 0) > n then return false, "older than the folder's copy" end
    if not signed.computer_of(root, by) then return false, "signed by a key no computer here is known by yet" end
    seq = n
  end
  band.set_overlay(path, body, d.side)
  forget(root, kind)
  if signed.OWN[kind] then return true end
  local ok, said = pcall(require("trust").file_ok, root, rel)
  if ok and said == true then
    local g = kind == "given" and band.json_decode(d.body or "")
    -- (a given claim's link copy is taken once on a computer: its file goes without a word when its person folds it in, and the same
    -- message again would bring the claim back. Its number is spent; Syncthing's copy of it is judged by Syncthing, as before signing)
    if g then take(root, rel, seq + 1, "") end
    linked[path] = { root = root, kind = kind, seq = seq, till = g and g.user ~= cfg.user and reaper.time_precise() + signed.GIVEN_KEEP or nil }
    return true
  end
  band.set_overlay(path, nil, nil, true)
  -- (the link's copy that was read here before this one stays: a refused message took a good one out with it. rt-linkmove)
  if here then band.set_overlay(path, here.bytes, here.side) end
  forget(root, kind)
  return false, ok and "not from someone who may" or tostring(said)
end

return signed
