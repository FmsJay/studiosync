-- Signed writes: who wrote a studio file, without Syncthing (docs/rt/rt-lite.md, a spike: nothing in the shipped flow calls this yet).
-- Today lib/trust.lua believes a roles, removal, claim or devices file by asking Syncthing which computer last changed it (its modifiedBy,
-- services.modified_by). Without Syncthing there is no such record, and the file may have come by the link, the hub or the cloud copy, any
-- of which a member could write into. Here the computer that writes such a file signs it instead, in a sidecar beside it (<file>.sig), so
-- any carrier will do and every computer checks the same thing:
--  - each computer has its own Ed25519 key (the extension's StudioSync_KeyCreate/Sign/Verify, as invitations and signed updates use), and its
--    device id is made from that key (sw.device_id: Syncthing's shape, so services.is_device_id and every place that stores ids take it), so
--    a devices file proves itself: it's good only when signed by the key its own `device` names (what trust.wrote_itself asks Syncthing);
--  - the signature covers the studio, the file's path, a sequence number and the file's bytes: a file can't be moved to another path or
--    studio, and a computer that has taken a newer one refuses an older one put back (Syncthing would have named whoever put it back);
--  - a deletion is a signed tombstone (the sidecar alone, `deleted`), for trust.deleted_by_manager.
-- Compare ids in full here: Syncthing's modifiedBy is 7 characters, so lib/trust.lua compares 7-character prefixes, which a made-up key
-- could match; sw.from_manager is trust.from_manager with whole ids.
-- shortcut: a computer that has never seen a file takes the first validly signed copy it's handed, however old (trust on first use, as the
-- pins); the hub or the inviter's welcome would hand over the newest sequence numbers to close that. Unreviewed (security reviews come after
-- all features, James 2026-11-19).
local json = require("band").json -- (StudioSync's own: lib/band.lua)
local sw = { LABEL = "StudioSync signed file v1\n", SIDE_MAX = 2048, FUTURE_MS = 86400 * 1000, TAG = "SSK" }

local B32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
local function hex_bytes(h) return (h:gsub("%x%x", function(x) return string.char(tonumber(x, 16)) end)) end
local function bytes_hex(b) return (b:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end
local function b32(bytes)
  local out, acc, bits = {}, 0, 0
  for i = 1, #bytes do
    acc, bits = ((acc << 8) | bytes:byte(i)) & 0xFFFF, bits + 8
    while bits >= 5 do bits = bits - 5; out[#out + 1] = B32:sub(((acc >> bits) & 31) + 1, ((acc >> bits) & 31) + 1) end
  end
  if bits > 0 then out[#out + 1] = B32:sub(((acc << (5 - bits)) & 31) + 1, ((acc << (5 - bits)) & 31) + 1) end
  return table.concat(out)
end
local function unb32(s)
  local out, acc, bits = {}, 0, 0
  for i = 1, #s do
    local v = B32:find(s:sub(i, i), 1, true)
    if not v then return nil end
    acc, bits = ((acc << 5) | (v - 1)) & 0xFFFF, bits + 5
    if bits >= 8 then bits = bits - 8; out[#out + 1] = string.char((acc >> bits) & 255) end
  end
  return table.concat(out)
end
local function hex64(s) return type(s) == "string" and #s == 64 and s:match("^%x+$") ~= nil end

-- ---- pure ----------------------------------------------------------------------------------------------------------------------------
-- A computer's device id from its public key (64 hex): base32 of the key and "SSK", 56 characters in Syncthing's 8 groups of 7. Pure.
function sw.device_id(pub)
  if not hex64(pub) then return nil end
  local s = b32(hex_bytes(pub:lower()) .. sw.TAG)
  return (s:gsub("(.......)", "%1-"):sub(1, -2))
end
-- The public key a key-made device id carries (64 hex), or nil (a Syncthing id, or not an id). Pure.
function sw.key_of(id)
  if type(id) ~= "string" or not id:match("^" .. ("[%u%d]"):rep(7) .. ("%-" .. ("[%u%d]"):rep(7)):rep(7) .. "$") then return nil end
  local b = unb32((id:gsub("%-", "")))
  if not b or #b ~= 35 or b:sub(33) ~= sw.TAG then return nil end
  return bytes_hex(b:sub(1, 32))
end
-- A path inside the studio's folder that a sidecar may name: forward slashes, no "..", not absolute, not a sidecar. Pure.
function sw.rel_ok(rel)
  return type(rel) == "string" and #rel > 0 and #rel <= 400 and not rel:find("\\", 1, true) and not rel:find("^/") and not rel:find("%.%.")
    and not rel:find("%.sig$") and not rel:find("%c")
end
-- What the signature covers. Pure.
function sw.message(studio, rel, seq, deleted, bytes)
  return sw.LABEL .. studio .. "\n" .. rel .. "\n" .. string.format("%d", seq) .. "\n" .. (deleted and "deleted" or "file") .. "\n" .. (deleted and "" or bytes)
end
-- The next sequence number for a file: milliseconds, and always past the last one seen for it (`prev`), so a later writer with a slow clock
-- still goes after. Pure.
function sw.next_seq(prev, now) return math.max(math.floor((tonumber(prev) or 0) + 1), math.floor(now * 1000)) end
-- The sidecar for `bytes` at `rel` (deleted: a tombstone, bytes ignored), signed by `sign(message)` -> 128 hex. -> its text, or nil. Pure.
function sw.make(sign, pub, studio, rel, seq, bytes, deleted)
  if not (hex64(pub) and sw.rel_ok(rel) and type(studio) == "string" and math.type(seq) == "integer" and seq >= 0) then return nil end
  if not deleted and type(bytes) ~= "string" then return nil end
  local sig = tostring(sign(sw.message(studio, rel, seq, deleted, bytes)) or ""):lower()
  if #sig ~= 128 or not sig:match("^%x+$") then return nil end
  return json.encode({ v = 1, by = sw.device_id(pub), key = pub:lower(), seq = seq, deleted = deleted and true or nil, sig = sig })
end
-- Who signed `bytes` (nil: the file isn't there) at `rel`, as its sidecar's text says. verify(sig, message, key) -> true/false.
-- -> the signer's device id, seq, sig, deleted; or nil + why (not signed, or not matching yet: the file and its sidecar arrive separately,
-- so callers keep what they had, as trust.lua does with Syncthing's "didn't say"); or false + why (malformed: never good). Pure.
function sw.signer(verify, studio, rel, bytes, side)
  if type(side) ~= "string" then return nil, "not signed" end
  if #side > sw.SIDE_MAX then return false, "signature file too big" end
  local ok, t = pcall(json.decode, side)
  if not ok or type(t) ~= "table" or t.v ~= 1 then return false, "not a signature file" end
  if not (hex64(t.key) and type(t.sig) == "string" and #t.sig == 128 and t.sig:match("^%x+$") and math.type(t.seq) == "integer" and t.seq >= 0
    and t.seq < 2 ^ 53) then return false, "not a signature file" end
  if t.by ~= sw.device_id(t.key) then return false, "the signer's id isn't its key's" end
  if not sw.rel_ok(rel) then return false, "not a studio path" end
  local deleted = t.deleted == true
  if deleted and bytes ~= nil then return nil, "the file is back but its signature says deleted" end
  if not deleted and bytes == nil then return nil, "the file isn't here yet" end
  if not verify(t.sig:lower(), sw.message(studio, rel, t.seq, deleted, bytes), t.key:lower()) then return nil, "doesn't match its signature" end
  return t.by, t.seq, t.sig:lower(), deleted
end
-- Has this computer taken this copy of `rel` before, or is it newer than any it took? state: rel -> { seq, sig } (kept per studio by the
-- caller). Call only for a signer the caller accepts, so nobody else can move the mark. -> true (recorded), or false + why. Pure but for state.
function sw.fresh(state, rel, seq, sig, now)
  if seq > math.floor(now * 1000) + sw.FUTURE_MS then return false, "dated more than a day ahead" end
  local was = state[rel]
  if was and seq < was.seq then return false, "older than one already taken" end
  if was and seq == was.seq and sig ~= was.sig then return false, "a different file with the same number" end
  state[rel] = { seq = seq, sig = sig }
  return true
end
-- trust.from_manager with whole ids. pins = { owner, admins, devices = { name = { ids } } }; mine: this computer's id. Pure.
function sw.from_manager(pins, id, mine)
  if type(id) ~= "string" or id == "" then return false end
  if id == mine then return true end
  local managers = { [pins.owner or ""] = true }
  for _, a in ipairs(pins.admins or {}) do managers[a] = true end
  for user, ids in pairs(pins.devices or {}) do
    if managers[user] then for _, d in ipairs(ids) do if d == id then return true end end end
  end
  return false
end
-- The whole check for a file only someone in charge may write (band.json's roles, roles.json, removals, closed.json, given claims).
-- -> true, signer; false, why; or nil, why (not yet). Pure but for state.
function sw.manager_ok(verify, state, pins, mine, studio, rel, bytes, side, now)
  local by, seq, sig = sw.signer(verify, studio, rel, bytes, side)
  if not by then return by, seq end
  if not sw.from_manager(pins, by, mine) then return false, "signed by a computer that isn't the owner's or an admin's" end
  local ok, why = sw.fresh(state, rel, seq, sig, now)
  if not ok then return false, why end
  return true, by
end
-- A devices file (_band/devices/<user>.json) proves itself: good when signed by the key its own `device` is made from, for the user its
-- name says. user_file: trust.user_file. -> true, device id; false, why; nil, why. Pure but for state.
function sw.device_file_ok(verify, state, studio, rel, bytes, side, now, user_file)
  local by, seq, sig = sw.signer(verify, studio, rel, bytes, side)
  if not by then return by, seq end
  local ok, d = pcall(json.decode, bytes)
  if not ok or type(d) ~= "table" or type(d.user) ~= "string" then return false, "not a devices file" end
  if rel ~= "_band/devices/" .. user_file(d.user) then return false, "a devices file under another name" end
  if d.device ~= by then return false, "names a computer that didn't sign it" end
  local fresh, why = sw.fresh(state, rel, seq, sig, now)
  if not fresh then return false, why end
  return true, by
end

return sw
