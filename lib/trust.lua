-- Who may say who runs a studio (0.58.69). Roles (_band/band.json owner and admins), taking someone out (_band/removed) and closing it
-- (_band/closed.json) are files anyone in the studio could write, and each says by whom itself. So each computer asks its own Syncthing which
-- computer last changed the file (its version vector's modifiedBy: what that computer's Syncthing signs its changes with, not what the file
-- says), and believes a change only from a computer it already knows as the owner's or an admin's. Those computers are pinned the first time
-- this computer sees the studio's roles, from _band/devices (the computer each person says is theirs), and grow when an accepted change names
-- someone new. A change from anyone else is set aside, and this computer keeps the roles it had.
-- (0.58.78, security review) The devices files, the band.json id and claims given by an admin are checked too, and a computer that was
-- invited believes the roles on first use only from the computer that invited it (its device ID is in the invitation), not whatever is on disk.
-- shortcut: someone in charge on a computer nobody here has pinned (a new one of theirs) isn't believed until they act from a known one;
-- a forged Syncthing client could still lie about modifiedBy. Signed files would close both. (A vouch from a known computer, confirmed by its
-- person, would close the first: a devices file naming them can't, as anyone can claim a name. docs/TEST-PLAN.md)
local band = require("band")
local trust = {}

-- (by the folder too: a test's scratch studio with a real one's ID pinned its own roles over the real one's)
local function norm(root) return (root:gsub("\\", "/"):gsub("/+$", ""):lower()) end
local function key(root) return "role pins " .. band.info(root).id .. " " .. norm(root) end
function trust.forget(root) reaper.DeleteExtState(band.SECTION, key(root), true) end
local function user_file(user) return (tostring(user):gsub("[^%w%-_ ]", "")) .. ".json" end

-- The roles in a band.json table, comparable. Pure.
function trust.roles_of(j)
  local admins = {}
  for _, a in ipairs(type(j.admins) == "table" and j.admins or {}) do if type(a) == "string" then admins[#admins + 1] = a end end
  table.sort(admins)
  return type(j.owner) == "string" and j.owner or nil, admins
end
function trust.same(p, owner, admins) return p.owner == owner and table.concat(p.admins, "\n") == table.concat(admins, "\n") end

-- Is `by` the computer `id`? `by` is Syncthing's modifiedBy (7 characters: all Syncthing says) or, from a good signature (lib/signed.lua), a
-- whole id, compared whole: a made-up id sharing a manager's first 7 characters is nobody's. Pure. (rt-linkfirst)
local function is(id, by)
  if type(id) ~= "string" or type(by) ~= "string" or by == "" then return false end
  if #by > 7 then return id == by end
  return id:sub(1, 7) == by
end
trust.is = is
-- May a change from the computer `by` (7 characters of its ID, or the whole ID) stand, with these pins? Your own computer's changes do: its
-- panel checked first. Pure. pins = { owner, admins = { names }, devices = { name = { ids } } }.
function trust.from_manager(pins, by, mine)
  if type(by) ~= "string" or by == "" then return false end
  if mine and is(mine, by) then return true end
  local managers = { [pins.owner or ""] = true }
  for _, a in ipairs(pins.admins) do managers[a] = true end
  for user, ids in pairs(pins.devices or {}) do
    if managers[user] then for _, id in ipairs(ids) do if is(id, by) then return true end end end
  end
  return false
end
-- Was this change from the computers pinned as `user`'s? Pure. (A claim names who gave it: lib/sync.lua)
function trust.from_user(pins, by, user)
  for _, id in ipairs(type(by) == "string" and by ~= "" and user and pins.devices[user] or {}) do if is(id, by) then return true end end
  return false
end
-- Is this change of the roles an admin renaming themselves, from their own computer (band.rename)? The owner the same, one admin's name swapped
-- for the one names.json (`names`: band.names) says they go by now. Pure. (Round 1 review, 0.59.45)
-- (Round 2 review, 0.59.46: and not onto a name whose devices file names another computer than theirs (`new_device`: that file's device, or nil):
-- renaming onto a member's name handed that name the admin role. -> ok, and "names" when only names.json didn't say so yet: not kept.)
local function tag(u) return (tostring(u):gsub("[^%w]", "_")):upper() end -- (band.rename's names.json key)
function trust.self_rename(pins, owner, admins, by, names, new_device)
  if owner ~= pins.owner then return false end
  local was, now = {}, {}
  for _, a in ipairs(pins.admins) do was[a] = true end
  for _, a in ipairs(admins) do now[a] = true end
  local old, new, n_old, n_new = nil, nil, 0, 0
  for a in pairs(was) do if not now[a] then old, n_old = a, n_old + 1 end end
  for a in pairs(now) do if not was[a] then new, n_new = a, n_new + 1 end end
  if n_old ~= 1 or n_new ~= 1 or not trust.from_user(pins, by, old) then return false end
  if new_device ~= nil then
    local theirs = false
    for _, id in ipairs(pins.devices[old] or {}) do theirs = theirs or id == new_device end -- (whole ids: both are a file's. rt-linkfirst)
    if not theirs then return false end
  end
  if not (type(names) == "table" and names[tag(old)] == new) then return false, "names" end
  return true
end
-- The pins after accepting roles: everyone already pinned keeps their computers; someone new in charge gets the computers the accepted band.json
-- lists as theirs (`listed`, its "managers": what the computer that wrote it had pinned, 0.58.78), else the one they've said is theirs. Pure.
-- (and someone in charge who renamed themselves keeps the computers pinned under the old name (`names`: names.json): they were pinned anew
-- only if their devices file could be checked at that moment, and never again, which locked an owner out on that computer. Round 2 review, 0.59.46)
function trust.repin(old, owner, admins, device_of, listed, names)
  local p = { owner = owner, admins = admins, devices = {} }
  for user, ids in pairs(old and old.devices or {}) do p.devices[user] = ids end
  local list = { table.unpack(admins) }
  if owner then list[#list + 1] = owner end
  local is_id = require("services").is_device_id
  for _, u in ipairs(list) do
    if not p.devices[u] and type(names) == "table" then
      for was, ids in pairs(old and old.devices or {}) do if was ~= u and names[tag(was)] == u then p.devices[u] = ids end end
    end
    if not p.devices[u] then
      local ids = {}
      for _, id in ipairs(type(listed) == "table" and type(listed[u]) == "table" and listed[u] or {}) do if is_id(id) then ids[#ids + 1] = id end end
      if #ids == 0 then local d = device_of(u); if d then ids[1] = d end end
      if #ids > 0 then p.devices[u] = ids end
    end
  end
  return p
end
-- band.json's "managers": whoever's in charge, and the computers this one has pinned as theirs (its own too, if it's one of them), for a
-- computer that's new to the studio to pin from (trust.repin) rather than from devices files, where anyone can claim a name. Pure.
function trust.managers_of(pins, owner, admins, me, mine)
  local out, list = {}, { table.unpack(admins or {}) }
  if owner then list[#list + 1] = owner end
  for _, u in ipairs(list) do
    local ids, has = {}, false
    for _, id in ipairs(pins and pins.devices[u] or {}) do ids[#ids + 1] = id; has = has or id == mine end
    if u == me and mine and not has then ids[#ids + 1] = mine end
    if #ids > 0 then out[u] = ids end
  end
  return next(out) and out or nil
end

function trust.pins(root)
  local p = band.ext_json(band.SECTION, key(root))
  if type(p) ~= "table" or type(p.admins) ~= "table" or type(p.devices) ~= "table" then return nil end
  return p
end
function trust.managers(root, owner, admins)
  local services = require("services")
  return trust.managers_of(trust.pins(root), owner, admins, reaper.GetExtState(band.SECTION, "user"), services.my_device_id())
end

-- Who invited this computer into the studio: the device ID in the invitation it joined from (services.join_band, or the installer through
-- installer/studiosync_setup.lua, which writes the same key). Security review, 0.58.78.
function trust.set_inviter(root, id) if require("services").is_device_id(id) then reaper.SetExtState(band.SECTION, "invited by " .. norm(root), id, true) end end
function trust.inviter(root)
  local id = reaper.GetExtState(band.SECTION, "invited by " .. norm(root))
  return require("services").is_device_id(id) and id or nil
end

local verdicts, said, asked, names_wait = {}, {}, {}, {}
-- trust.file_ok is asking about a copy that came by the direct link: a "no" is neither kept nor said. The caches below go by what a file
-- says, not by who signed it, so a member's copy of someone's file, refused, would have had the real one refused after it. (rt-linkmove)
local probing = false
-- Which computer changed it: the one whose key signed it as it reads now (lib/signed.lua: a good signature, a key this computer knows as that
-- computer's, a number not older than one taken), as its whole ID; else Syncthing's modifiedBy, as before (an unsigned file, one an older
-- StudioSync rewrote, a key not known yet). A copy that came over the direct link has no Syncthing answer: its signature or "not yet".
-- After no answer from Syncthing, not asked again for 30 s (the panel asks each frame); an answer is cached by the caller.
local function changed_by(root, rel)
  local oks, dev, linked = pcall(function() return require("signed").computer(root, rel) end)
  if oks and dev then return dev end
  if oks and linked then return nil end
  local k = root .. rel
  if asked[k] and reaper.time_precise() - asked[k] < 30 then return nil end
  local by = require("services").modified_by(band.info(root).id, rel)
  asked[k] = not by and reaper.time_precise() or nil
  return by
end
-- A check said yes to a file a signature said who wrote: its sequence number is taken (an older copy is never a signature's word again). -> ok.
local function took(root, rel, ok, by)
  if ok == true and type(by) == "string" and #by > 7 then pcall(function() require("signed").taken(root, rel) end) end
  return ok
end

-- A devices file says which computer is someone's, and anyone could write one naming any computer: it counts only when Syncthing says the
-- computer it names wrote it (each computer writes its own: removal.publish). So nobody can have someone else's computer pinned as a person's,
-- or cut off in that person's place. A computer can still claim any name for itself: identity is a chosen name. Security review, 0.58.78.
-- Pure: `by` is Syncthing's modifiedBy; "" is a file it doesn't hold (believed, as everywhere here).
function trust.wrote_itself(device, by) return by == "" or is(device, by) end
local devs, devs_said = {}, {}
trust.user_file = user_file
-- -> true, false, or nil (Syncthing didn't say: ask again later). Asked once per name, computer and the file's text (by the computer alone, a
-- file rewritten by its own computer after a forged one stayed refused until REAPER restarted); a "no" is asked again after two minutes (the
-- answer can trail a rewrite by a moment). Round 1 review, 0.59.45.
function trust.device_ok(root, user, device)
  local j = band.read_json(root .. "/_band/band.json")
  -- (a studio from before owners: anyone in it may take anyone out, so a file naming the wrong computer gains nobody anything)
  -- (but not on an invited computer still held: band.json without an owner made any devices file count as its computer's. Round 4 review, 0.59.49)
  if not trust.pins(root) and not (type(j) == "table" and type(j.owner) == "string") and not trust.held(root) then return true end
  local rel = "_band/devices/" .. user_file(user)
  local k = root .. rel .. tostring(device) .. "\0" .. tostring(band.read(root .. "/" .. rel))
  local c = devs[k]
  if c == nil or (c.ok == false and os.time() - c.at > 120) then
    local by = changed_by(root, rel)
    if not by then return c and c.ok end
    c = { ok = took(root, rel, trust.wrote_itself(device, by), by), at = os.time() }
    if probing and not c.ok then return false end
    devs[k] = c
    -- (believed as always, Syncthing saying its own computer wrote it: the key it carries is that computer's from now on, lib/signed.lua. Never
    -- from a signature: a key is only ever learnt this way. rt-linkfirst)
    if c.ok and #by <= 7 then
      local d = band.read_json(root .. "/" .. rel)
      if type(d) == "table" and d.device == device and type(d.key) == "string" then pcall(function() require("signed").note_key(root, device, d.key) end) end
    end
    if not c.ok and not devs_said[k] then
      devs_said[k] = true
      band.log(string.format("%s: %s names a computer (%s) that didn't write it, so it was set aside", band.info(root).name, rel, tostring(device):sub(1, 7)))
    end
  end
  return c.ok
end
local function device_of(root)
  return function(u)
    local d = band.read_json(root .. "/_band/devices/" .. user_file(u))
    local id = type(d) == "table" and require("services").is_device_id(d.device) and d.device or nil
    return id and trust.device_ok(root, u, id) and id or nil
  end
end
function trust.pin(root, owner, admins, listed)
  local p = trust.repin(trust.pins(root), owner, admins, device_of(root), listed, band.read_json(root .. "/_band/names.json"))
  band.set_ext_json(band.SECTION, key(root), p, true)
  return p
end

-- The name the inviter's computer goes by here: the person whose devices file names it, and which it wrote itself. -> it, or nil.
local function name_of(root, id)
  for _, f in ipairs(band.files(root .. "/_band/devices", ".json")) do
    local d = band.read_json(root .. "/_band/devices/" .. f)
    if type(d) == "table" and d.device == id and type(d.user) == "string" and user_file(d.user) == f and trust.device_ok(root, d.user, id) then return d.user end
  end
end
trust.INVITER = "(whoever invited you)" -- (no one's name: names are letters, digits, - _ and spaces)
-- An invited computer's first look at the roles. band.json's are believed only if the inviter's computer wrote it (whoever lets someone in writes
-- it out again then: tools.let_in), and the computers pinned are the ones it lists. Written by anyone else, it's set aside, and the inviter
-- alone is taken as in charge until their computer writes it. Security review, 0.58.78. -> owner, admins.
local function first_look(root, j, owner, admins, inv)
  local by = changed_by(root, "_band/band.json")
  if by and trust.wrote_itself(inv, by) then trust.pin(root, owner, admins, j.managers); return owner, admins end
  local who = name_of(root, inv) or trust.INVITER
  if not by then return who, {} end -- (Syncthing didn't say yet: asked again in 30 s)
  band.set_ext_json(band.SECTION, key(root), { owner = who, admins = {}, devices = { [who] = { inv } }, held = true }, true)
  said[root .. trust.version(j, owner, admins)] = true -- (said here: the set-aside that follows needn't say it again)
  band.log(string.format("%s's roles were last written by a computer (%s) that isn't the one that invited you: StudioSync takes %s as in charge until theirs writes them",
    band.info(root).name, require("services").device_name(by), who))
  return who, {}
end
-- Did a file in the studio's folder come from the owner's or an admin's computer? -> true, false, or nil (Syncthing didn't say: ask again later).
function trust.from_manager_file(root, rel, pins)
  pins = pins or trust.pins(root)
  if not pins then return nil end
  local services = require("services")
  local by = changed_by(root, rel)
  if not by then return nil end
  if by == "" then return true, by end -- (Syncthing doesn't hold it: a studio synced another way is believed, as before 0.58.69)
  -- (this computer's own writing counts, but not while it's held: it wrote back roles it doesn't go by, groups save. 0.58.78)
  return took(root, rel, trust.from_manager(pins, by, not pins.held and services.my_device_id() or nil), by), by
end
-- Is this an invited computer still waiting for its inviter's writing of the roles (trust.roles' first look)? Then it goes by the inviter alone.
-- (an invited computer with no pins yet is held whatever band.json says: a member who took "owner" out of it had every new joiner take anyone's
-- removal marks. A studio from before owners stays closed to a joiner then. James's decision, Round 3 review, 0.59.48)
function trust.held(root)
  local p = trust.pins(root)
  if p then return p.held == true end
  return trust.inviter(root) ~= nil
end
-- A verdict cache whose "no", given while held, lasts only while held: kept by the file's content alone, a verdict made against the inviter
-- alone (an owner's claim, guest list or closed.json) stood after the real pins came, until REAPER restarted. trust.held is read only for a "no".
-- (Round 4 review, 0.59.49)
function trust.cached(cache, k, root)
  local v = cache[k]
  if v ~= "held" then return v end
  if trust.held(root) then return false end
  cache[k] = nil
  return nil
end
function trust.cache(cache, k, ok, root)
  if ok == false and probing then return ok end
  if ok == false and trust.held(root) then cache[k] = "held" else cache[k] = ok end
  return ok
end

-- Which writing of the roles a verdict is for: the roles, and when they were written out (band.json "roles_at", every groups save: 0.58.78).
-- Keyed by the roles alone, a set-aside set stayed set aside when someone in charge wrote the same ones later, and an invited computer that
-- looked before its inviter's writing arrived never took it. Pure.
function trust.version(j, owner, admins) return tostring(owner) .. "\0" .. table.concat(admins, "\n") .. "\0" .. tostring(j.roles_at) end
-- The roles to go by: band.json's when they're the ones pinned, or a change from someone in charge; otherwise the pinned ones. -> owner, admins.
function trust.roles(root, j)
  local owner, admins = trust.roles_of(j)
  local pins = trust.pins(root)
  if not pins then
    local inv = trust.inviter(root)
    -- (an invited computer with no owner in band.json yet: the inviter alone, as held, not "open" to everyone: a member who kept "owner" out of
    -- band.json had every name able to manage, let people in and take edits in an admins room. Round 4 review, 0.59.49)
    if not owner then if inv then return trust.INVITER, {} end return owner, admins end
    if inv then return first_look(root, j, owner, admins, inv) end
    trust.pin(root, owner, admins, j.managers) -- (the first look, joined before 0.58.78 or started here: what's there now is what this computer knows)
    return owner, admins
  end
  -- (the roles go by _band/roles.json where there is one: only the owner's computer writes it (groups save), so an admin's band.json save,
  -- which carries the roles as that computer had them, can't mask the owner's change. band.json keeps the roles for older versions. James's
  -- decision, Round 2 review, 0.59.46)
  -- (not while held: the roles file comes only from the owner's computer, which held pins don't know, so an invited computer that looked
  -- before its inviter's writing never left held and took the inviter as owner for good. By band.json then, as before 0.59.46. Round 3 review, 0.59.48)
  local rel = "_band/band.json"
  local r = not pins.held and band.read_json(root .. "/_band/roles.json")
  if type(r) == "table" and type(r.owner) == "string" then j, rel = r, "_band/roles.json"; owner, admins = trust.roles_of(r) end
  if trust.same(pins, owner, admins) then return owner, admins end
  local v = (rel == "_band/band.json" and "" or "roles.json\0") .. trust.version(j, owner, admins) -- (band.json's key as first_look writes it)
  -- (a "no" only for want of names.json is asked again after a minute, not every look. Round 3 review, 0.59.48)
  if verdicts[root .. v] == nil and os.time() - (names_wait[root .. v] or -math.huge) < 60 then return pins.owner, pins.admins end
  if verdicts[root .. v] == nil then
    local ok, by = trust.from_manager_file(root, rel, pins)
    if ok == nil then return pins.owner, pins.admins end
    -- (who's in charge changes only from the owner's computer, or this one (its panel let only the owner): an admin's computer is a manager's,
    -- and an admin who wrote owner = themselves into band.json was believed everywhere. Allowed: an admin renaming themselves, which writes
    -- the roles too (band.rename). Round 1 review, 0.59.45)
    local mine = require("services").my_device_id()
    if ok and by ~= "" and not (not pins.held and mine and is(mine, by)) and not trust.from_user(pins, by, pins.owner) then
      -- (names.json read now, not band.names' 10 s copy; a "no" only for want of it is asked again: Round 2 review, 0.59.46)
      local why
      local newd
      for _, a in ipairs(admins) do
        local d = not pins.devices[a] and band.read_json(root .. "/_band/devices/" .. user_file(a))
        if type(d) == "table" and d.device then newd = d.device end
      end
      ok, why = trust.self_rename(pins, owner, admins, by, band.read_json(root .. "/_band/names.json"), newd)
      if why == "names" then names_wait[root .. v] = os.time(); return pins.owner, pins.admins end
    end
    verdicts[root .. v] = ok
    if not ok and not said[root .. v] then
      said[root .. v] = true
      band.log(string.format("%s's roles were changed from a computer (%s) that isn't the owner's: StudioSync kept the ones it had",
        band.info(root).name, require("services").device_name(by)))
    end
  end
  if verdicts[root .. v] then trust.pin(root, owner, admins, j.managers); return owner, admins end
  return pins.owner, pins.admins
end

-- A removal or closing file: from someone in charge (or, for someone leaving, from their own computer)? Asked once per file and date. -> true/false/nil.
local marks = {}
function trust.mark_ok(root, rel, m)
  local k = root .. rel .. tostring(m.at) .. "\0" .. tostring(m.user) .. "\0" .. tostring(m.device) .. "\0" .. tostring(m.by) -- (the mark as read: rewritten with the
  -- same time, another person's mark took the verdict cached for the first. Review, 0.58.92)
  if marks[k] ~= nil then return marks[k] end
  local pins = trust.pins(root)
  -- (a studio from before owners: everyone in it may. An invited computer still waiting for its first look: not yet. 0.58.78)
  if not pins then if trust.held(root) then return nil end return true end
  local services = require("services")
  local by = changed_by(root, rel)
  if not by then return nil end
  -- ("": Syncthing doesn't hold it, believed as above)
  local ok = by == "" or trust.from_manager(pins, by, services.my_device_id()) or (m.left == true and is(m.device, by))
  -- (a mark written here a moment ago: Syncthing may not have looked at it yet, and still names whoever wrote the file before)
  if not ok and os.time() - (tonumber(m.at) or 0) < 120 then return nil end
  if probing and not ok then return false end
  marks[k] = took(root, rel, ok, by)
  if not ok then band.log(string.format("%s: %s came from a computer (%s) that isn't the owner's or an admin's, so it was set aside", band.info(root).name, rel, services.device_name(by))) end
  return ok
end

-- Was a file deleted from the owner's or an admin's computer, as Syncthing's record of the deletion says? -> true, false, or nil (no answer,
-- or the record isn't a deletion yet: a file removed here is scanned a moment later). For a removal or guest mark this computer keeps after its
-- file went (lib/removal.lua). Round 1 review, 0.59.45.
function trust.deleted_by_manager(root, rel)
  local pins = trust.pins(root)
  if not pins then return nil end
  local services = require("services")
  -- (a signed tombstone from a computer whose key is known here: its word, whole ID; one that came over the link has no Syncthing record.
  -- lib/signed.lua, rt-linkfirst)
  local okd, dev, linked = pcall(function() return require("signed").deleted_by(root, rel) end)
  if okd and dev then return took(root, rel, trust.from_manager(pins, dev, not pins.held and services.my_device_id() or nil), dev) end
  if okd and linked then return nil end
  local by, gone = services.modified_by(band.info(root).id, rel)
  if by == "" then return true end -- (Syncthing holds no record of it: believed, as everywhere here)
  if not by or not gone then return nil end
  return trust.from_manager(pins, by, not pins.held and services.my_device_id() or nil)
end
-- Did a file come from the pinned owner's computer, or this one while its person is the owner? -> true, false, or nil (Syncthing didn't say yet).
-- For closing a studio (lib/groups.lua closed_ok): any member could write closed.json naming the owner, with "left" and their own device, and
-- mark_ok's leaving branch let it through, so every computer left the studio. Never that branch here. Round 1 review, 0.59.45.
function trust.from_owner_file(root, rel)
  local pins = trust.pins(root)
  if not pins or not pins.owner then return false end
  local by = changed_by(root, rel)
  if not by then return nil end
  if by == "" then return true end -- (Syncthing holds no record of it: believed, as everywhere here; a file from another computer always has one)
  local mine = require("services").my_device_id()
  if mine and is(mine, by) and not pins.held and reaper.GetExtState(band.SECTION, "user") == pins.owner then return took(root, rel, true, by) end
  return took(root, rel, trust.from_user(pins, by, pins.owner), by)
end

-- A claim an admin gave (<song>/rooms/<room>/claims/given-*.json) says who gave it, and anyone could write one saying an admin did: it counts
-- only when Syncthing says that person's pinned computer wrote it, or this one (its panel lets only someone in charge give). Asked once per file
-- and time. Security review, 0.58.78. -> true, false, or nil (not yet: ask again later).
local claims = {}
function trust.claim_ok(root, rel, c)
  local k = root .. rel .. tostring(c.time) .. "\0" .. band.json_encode(c) -- (the claim as read, as for marks above)
  local was = trust.cached(claims, k, root)
  if was ~= nil then return was end
  local pins = trust.pins(root)
  if not pins then if trust.held(root) then return nil end return true end -- (as trust.mark_ok)
  local services = require("services")
  local by = changed_by(root, rel)
  if not by then return nil end
  local mine = services.my_device_id()
  local ok = by == "" or (mine ~= nil and is(mine, by)) or trust.from_user(pins, by, c.by)
  trust.cache(claims, k, took(root, rel, ok, by), root)
  if not ok and not probing then band.log(string.format("%s: a claim said to be given by %s came from another computer (%s), so it was set aside", band.info(root).name, tostring(c.by), services.device_name(by))) end
  return ok
end

-- A file a person writes for themselves alone (a song's session.json, which names who shared it; <song>/hub/<person>.json, their handovers of
-- the song's hub: lib/hub.lua) counts only when Syncthing says that person's own computer wrote it: the one their devices file names (and wrote
-- itself: trust.device_ok), or this one when it's this person's. No new step for anyone: every computer already writes its own devices file.
-- at: when the file says it was written (os.time): a "no" within 2 minutes of it is asked again (Syncthing may not have scanned it yet, as
-- trust.mark_ok). -> true, false, or nil (not known yet: ask again later). (James, rt)
local own = {}
function trust.own_file_ok(root, rel, user, at)
  local k = root .. rel .. "\0" .. tostring(user) .. "\0" .. tostring(band.read(root .. "/" .. rel)) -- (the file as read, as for claims)
  local was = trust.cached(own, k, root)
  if was ~= nil then return was end
  local pins = trust.pins(root)
  if not pins then if trust.held(root) then return nil end return true end -- (as trust.mark_ok)
  local services = require("services")
  local by = changed_by(root, rel)
  if not by then return nil end
  local mine, ok = services.my_device_id(), by == "" -- ("": Syncthing doesn't hold it, believed as everywhere here)
  if not ok and mine and is(mine, by) then ok = user == reaper.GetExtState(band.SECTION, "user") -- (this computer writes only its person's)
  elseif not ok then
    local d = band.read_json(root .. "/_band/devices/" .. user_file(user))
    local dev = type(d) == "table" and services.is_device_id(d.device) and d.device or nil
    local said = dev and trust.device_ok(root, user, dev)
    if dev and said == nil then return nil end
    ok = said == true and is(dev, by)
  end
  if not ok and os.time() - (tonumber(at) or 0) < 120 then return nil end
  trust.cache(own, k, took(root, rel, ok, by), root)
  if not ok and not probing then band.log(string.format("%s: %s says it's %s's, but another computer (%s) wrote it, so it was set aside", band.info(root).name, rel, tostring(user), services.device_name(by))) end
  return ok
end

-- A copy that came over the direct link (lib/signed.lua on_msg, already in band.overlay while this asks): does the check its readers make say
-- yes now? By its kind, the same check as when Syncthing brings it; a room's mode.json, which nothing checks then, must be a manager's here.
-- -> true, or false/nil (left out). (rt-linkfirst)
local function file_ok(root, rel)
  local kind = require("signed").kind(rel)
  local j = band.read_json(root .. "/" .. rel)
  if kind == "band" or kind == "guests" or kind == "mode" then return (trust.from_manager_file(root, rel)) end
  if kind == "closed" then return trust.from_owner_file(root, rel) end
  if kind == "removed" then
    if band.read(root .. "/" .. rel) == nil then return trust.deleted_by_manager(root, rel) end
    return type(j) == "table" and trust.mark_ok(root, rel, j) or false
  end
  if kind == "devices" then
    return type(j) == "table" and type(j.user) == "string" and "_band/devices/" .. user_file(j.user) == rel and trust.device_ok(root, j.user, j.device) or false
  end
  if kind == "grants" then
    return type(j) == "table" and type(j.by) == "string" and user_file(j.by) == rel:match("([^/]+)$") and require("groups").may_manage(root, j.by)
      and trust.claim_ok(root, rel, j) or false
  end
  -- (a claim someone in charge gave, as sync.authority's given_ok, and under the name its writer gives it: given-<who it's for>-<when>. rt-linkmove)
  if kind == "given" then
    local pre = "given-" .. user_file(type(j) == "table" and j.user or ""):sub(1, -6) .. "-"
    return type(j) == "table" and type(j.by) == "string" and type(j.user) == "string" and rel:match("([^/]+)$"):sub(1, #pre) == pre
      and require("groups").may_manage(root, j.by) and trust.claim_ok(root, rel, j) or false
  end
  -- (one person's own file, lib/signed.lua owner: from that person's own computer, as its readers ask of Syncthing's copy, or as nothing asks
  -- of it then (a release, a track order). rt-linkmove)
  local who = require("signed").owner(root, rel, kind, j)
  if who then return trust.own_file_ok(root, rel, who) end
  return false
end
function trust.file_ok(root, rel)
  probing = true
  local ok, said_ = pcall(file_ok, root, rel)
  probing = false
  if not ok then error(said_, 0) end
  return said_
end

return trust
