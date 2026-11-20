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
}
signed.OWN = { profile = true, colour = true, recap = true }
-- What goes over the link the moment it's written. (Not: invitation records, given claims, driver.json (a "driver" event goes already) and
-- room.json: signed, and Syncthing carries them.)
signed.LINK = { band = true, closed = true, removed = true, guests = true, devices = true, mode = true, grants = true, profile = true, colour = true,
  recap = true }
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
  if o then return o.bytes, o.side, true end
  -- (not in the folder: a copy a join's welcome brought, band.boot_copy, which Syncthing knows nothing of either: its signature or not yet.
  -- lib/joinboot.lua, rt-joinlink)
  if bytes ~= nil and band.read_raw(path) == nil and band.boot_copy(path) == bytes then return bytes, band.read(path .. ".sig"), true end
  return bytes, band.read(path .. ".sig"), false
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
end
function signed.on_remove(path)
  local root, rel, kind = signed.locate(path)
  if kind ~= "removed" then return end
  if sign_side(root, rel, nil, true) then queue(root, rel) end
end

-- ---- the direct link ---------------------------------------------------------------------------------------------------------------------
-- Live sync's tick: what this computer wrote since, to the bandmates here (and those in the file's own room) now. Other studios' stay queued.
function signed.drain(cfg, song, room)
  local q = reaper.GetExtState(band.SECTION, OUTBOX)
  if q == "" then return 0 end
  local direct, keep, n = require("direct"), {}, 0
  for line in q:gmatch("[^\n]+") do
    local root, rel = line:match("^(.-)\t(.+)$")
    if root ~= cfg.root then keep[#keep + 1] = line
    else
      local path = root .. "/" .. rel
      local body, side = band.read_raw(path), band.read_raw(path .. ".sig")
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
local function forget(root, kind)
  band.forget_info()
  pcall(function() require("groups").forget_trusted(root) end)
  if kind == "devices" then pcall(function() require("direct").forget_devices(root) end) end
  if kind == "profile" then pcall(function() require("profile").forget(root) end) end
  if kind == "colour" then pcall(function() require("people").forget(root) end) end
end
-- The file name an OWN kind's file must have for the person it says it's for (as its writer names it). Pure.
local function own_name(kind, t)
  if type(t) ~= "table" then return nil end
  if kind == "colour" then return type(t.user) == "string" and (t.user:gsub("[^%w%-_ ]", "")) or nil end
  local who = kind == "profile" and t.user or type(t.recaps) == "table" and type(t.recaps[1]) == "table" and t.recaps[1].by
  return type(who) == "string" and require("sync").id_user(who) or nil
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
  if band.read(path) == d.body and (signed.OWN[kind] or band.read(path .. ".sig") == d.side) then return false, "already here" end
  if signed.OWN[kind] then -- (each one person's, checked by nobody today: only its shape, as its readers check it)
    local name = own_name(kind, d.body and band.json_decode(d.body))
    if not (name and name == rel:match("([^/]+)%.json$")) then return false, "not that person's file" end
  else
    if not d.side then return false, "not signed" end
    local by, seq, sig, deleted = sw.signer(verify, tostring(band.info(root).id), rel, d.body, d.side)
    if not by then return false, seq end
    if deleted and kind ~= "removed" then return false, "only a removal mark is taken back" end
    if not fresh_ok(root, rel, seq, sig) then return false, "older than one already taken" end
    if not signed.computer_of(root, by) then return false, "signed by a key no computer here is known by yet" end
  end
  band.set_overlay(path, d.body, d.side)
  forget(root, kind)
  if signed.OWN[kind] then return true end
  local ok, said = pcall(require("trust").file_ok, root, rel)
  if ok and said == true then return true end
  band.set_overlay(path, nil, nil, true)
  forget(root, kind)
  return false, ok and "not from someone who may" or tostring(said)
end

return signed
