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

-- May a change from the computer `by` (7 characters of its ID) stand, with these pins? Your own computer's changes do: its panel checked first.
-- Pure. pins = { owner, admins = { names }, devices = { name = { ids } } }.
function trust.from_manager(pins, by, mine)
  if type(by) ~= "string" or by == "" then return false end
  if mine and by == mine:sub(1, 7) then return true end
  local managers = { [pins.owner or ""] = true }
  for _, a in ipairs(pins.admins) do managers[a] = true end
  for user, ids in pairs(pins.devices or {}) do
    if managers[user] then for _, id in ipairs(ids) do if id:sub(1, 7) == by then return true end end end
  end
  return false
end
-- Was this change from the computers pinned as `user`'s? Pure. (A claim names who gave it: lib/sync.lua)
function trust.from_user(pins, by, user)
  for _, id in ipairs(type(by) == "string" and by ~= "" and pins.devices[user] or {}) do if id:sub(1, 7) == by then return true end end
  return false
end
-- The pins after accepting roles: everyone already pinned keeps their computers; someone new in charge gets the computers the accepted band.json
-- lists as theirs (`listed`, its "managers": what the computer that wrote it had pinned, 0.58.78), else the one they've said is theirs. Pure.
function trust.repin(old, owner, admins, device_of, listed)
  local p = { owner = owner, admins = admins, devices = {} }
  for user, ids in pairs(old and old.devices or {}) do p.devices[user] = ids end
  local list = { table.unpack(admins) }
  if owner then list[#list + 1] = owner end
  local is_id = require("services").is_device_id
  for _, u in ipairs(list) do
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
  local p = band.json_decode(reaper.GetExtState(band.SECTION, key(root)))
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

local verdicts, said, asked = {}, {}, {}
-- Which computer changed it, from Syncthing. After no answer, not asked again for 30 s (the panel asks each frame); an answer is cached by the caller.
local function changed_by(root, rel)
  local k = root .. rel
  if asked[k] and reaper.time_precise() - asked[k] < 30 then return nil end
  local by = require("services").modified_by(band.info(root).id, rel)
  asked[k] = not by and reaper.time_precise() or nil
  return by
end

-- A devices file says which computer is someone's, and anyone could write one naming any computer: it counts only when Syncthing says the
-- computer it names wrote it (each computer writes its own: removal.publish). So nobody can have someone else's computer pinned as a person's,
-- or cut off in that person's place. A computer can still claim any name for itself: identity is a chosen name. Security review, 0.58.78.
-- Pure: `by` is Syncthing's modifiedBy; "" is a file it doesn't hold (believed, as everywhere here).
function trust.wrote_itself(device, by) return by == "" or (type(device) == "string" and type(by) == "string" and by ~= "" and device:sub(1, 7) == by) end
local devs = {}
-- -> true, false, or nil (Syncthing didn't say: ask again later). Asked once per name and computer.
function trust.device_ok(root, user, device)
  local j = band.read_json(root .. "/_band/band.json")
  -- (a studio from before owners: anyone in it may take anyone out, so a file naming the wrong computer gains nobody anything)
  if not trust.pins(root) and not (type(j) == "table" and type(j.owner) == "string") then return true end
  local rel = "_band/devices/" .. user_file(user)
  local k = root .. rel .. tostring(device)
  if devs[k] == nil then
    local by = changed_by(root, rel)
    if not by then return nil end
    devs[k] = trust.wrote_itself(device, by)
    if not devs[k] then band.log(string.format("%s: %s names a computer (%s) that didn't write it, so it was set aside", band.info(root).name, rel, tostring(device):sub(1, 7))) end
  end
  return devs[k]
end
local function device_of(root)
  return function(u)
    local d = band.read_json(root .. "/_band/devices/" .. user_file(u))
    local id = type(d) == "table" and require("services").is_device_id(d.device) and d.device or nil
    return id and trust.device_ok(root, u, id) and id or nil
  end
end
function trust.pin(root, owner, admins, listed)
  local p = trust.repin(trust.pins(root), owner, admins, device_of(root), listed)
  reaper.SetExtState(band.SECTION, key(root), band.json_encode(p), true)
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
  reaper.SetExtState(band.SECTION, key(root), band.json_encode({ owner = who, admins = {}, devices = { [who] = { inv } }, held = true }), true)
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
  return trust.from_manager(pins, by, not pins.held and services.my_device_id() or nil), by
end
-- Is this an invited computer still waiting for its inviter's writing of the roles (trust.roles' first look)? Then it goes by the inviter alone.
function trust.held(root)
  local p = trust.pins(root)
  if p then return p.held == true end
  local j = band.read_json(root .. "/_band/band.json")
  return trust.inviter(root) ~= nil and type(j) == "table" and type(j.owner) == "string" -- (no owner: a studio from before owners, open to all)
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
    if not owner then return owner, admins end
    local inv = trust.inviter(root)
    if inv then return first_look(root, j, owner, admins, inv) end
    trust.pin(root, owner, admins, j.managers) -- (the first look, joined before 0.58.78 or started here: what's there now is what this computer knows)
    return owner, admins
  end
  if trust.same(pins, owner, admins) then return owner, admins end
  local v = trust.version(j, owner, admins)
  if verdicts[root .. v] == nil then
    local ok, by = trust.from_manager_file(root, "_band/band.json", pins)
    if ok == nil then return pins.owner, pins.admins end
    verdicts[root .. v] = ok
    if not ok and not said[root .. v] then
      said[root .. v] = true
      band.log(string.format("%s's roles were changed from a computer (%s) that isn't the owner's or an admin's: StudioSync kept the ones it had",
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
  local ok = by == "" or trust.from_manager(pins, by, services.my_device_id()) or (m.left == true and type(m.device) == "string" and m.device:sub(1, 7) == by)
  -- (a mark written here a moment ago: Syncthing may not have looked at it yet, and still names whoever wrote the file before)
  if not ok and os.time() - (tonumber(m.at) or 0) < 120 then return nil end
  marks[k] = ok
  if not ok then band.log(string.format("%s: %s came from a computer (%s) that isn't the owner's or an admin's, so it was set aside", band.info(root).name, rel, services.device_name(by))) end
  return ok
end

-- A claim an admin gave (<song>/rooms/<room>/claims/given-*.json) says who gave it, and anyone could write one saying an admin did: it counts
-- only when Syncthing says that person's pinned computer wrote it, or this one (its panel lets only someone in charge give). Asked once per file
-- and time. Security review, 0.58.78. -> true, false, or nil (not yet: ask again later).
local claims = {}
function trust.claim_ok(root, rel, c)
  local k = root .. rel .. tostring(c.time) .. "\0" .. band.json_encode(c) -- (the claim as read, as for marks above)
  if claims[k] ~= nil then return claims[k] end
  local pins = trust.pins(root)
  if not pins then if trust.held(root) then return nil end return true end -- (as trust.mark_ok)
  local services = require("services")
  local by = changed_by(root, rel)
  if not by then return nil end
  local mine = services.my_device_id()
  local ok = by == "" or (mine ~= nil and by == mine:sub(1, 7)) or trust.from_user(pins, by, c.by)
  claims[k] = ok
  if not ok then band.log(string.format("%s: a claim said to be given by %s came from another computer (%s), so it was set aside", band.info(root).name, tostring(c.by), services.device_name(by))) end
  return ok
end

return trust
