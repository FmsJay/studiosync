-- Who may say who runs a studio (0.58.69). Roles (_band/band.json owner and admins), taking someone out (_band/removed) and closing it
-- (_band/closed.json) are files anyone in the studio could write, and each says by whom itself. So each computer asks its own Syncthing which
-- computer last changed the file (its version vector's modifiedBy: what that computer's Syncthing signs its changes with, not what the file
-- says), and believes a change only from a computer it already knows as the owner's or an admin's. Those computers are pinned the first time
-- this computer sees the studio's roles, from _band/devices (the computer each person says is theirs), and grow when an accepted change names
-- someone new. A change from anyone else is set aside, and this computer keeps the roles it had.
-- shortcut: someone in charge on a computer nobody here has pinned (a new one of theirs) isn't believed until they act from a known one;
-- a forged Syncthing client could still lie about modifiedBy. Signed files would close both.
local band = require("band")
local trust = {}

-- (by the folder too: a test's scratch studio with a real one's ID pinned its own roles over the real one's)
local function key(root) return "role pins " .. band.info(root).id .. " " .. (root:gsub("\\", "/"):gsub("/+$", ""):lower()) end
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
-- The pins after accepting roles: everyone already pinned keeps their computers; someone new in charge gets the one they've said is theirs. Pure.
function trust.repin(old, owner, admins, device_of)
  local p = { owner = owner, admins = admins, devices = {} }
  for user, ids in pairs(old and old.devices or {}) do p.devices[user] = ids end
  local list = { table.unpack(admins) }
  if owner then list[#list + 1] = owner end
  for _, u in ipairs(list) do
    if not p.devices[u] then local d = device_of(u); if d then p.devices[u] = { d } end end
  end
  return p
end

function trust.pins(root)
  local p = band.json_decode(reaper.GetExtState(band.SECTION, key(root)))
  if type(p) ~= "table" or type(p.admins) ~= "table" or type(p.devices) ~= "table" then return nil end
  return p
end
local function device_of(root)
  return function(u)
    local d = band.read_json(root .. "/_band/devices/" .. user_file(u))
    return type(d) == "table" and require("services").is_device_id(d.device) and d.device or nil
  end
end
function trust.pin(root, owner, admins)
  local p = trust.repin(trust.pins(root), owner, admins, device_of(root))
  reaper.SetExtState(band.SECTION, key(root), band.json_encode(p), true)
  return p
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
-- Did a file in the studio's folder come from the owner's or an admin's computer? -> true, false, or nil (Syncthing didn't say: ask again later).
function trust.from_manager_file(root, rel, pins)
  pins = pins or trust.pins(root)
  if not pins then return nil end
  local services = require("services")
  local by = changed_by(root, rel)
  if not by then return nil end
  if by == "" then return true, by end -- (Syncthing doesn't hold it: a studio synced another way is believed, as before 0.58.69)
  return trust.from_manager(pins, by, services.my_device_id()), by
end

-- The roles to go by: band.json's when they're the ones pinned, or a change from someone in charge; otherwise the pinned ones. -> owner, admins.
function trust.roles(root, j)
  local owner, admins = trust.roles_of(j)
  local pins = trust.pins(root)
  if not pins then
    if owner then trust.pin(root, owner, admins) end -- (the first look: what's there now is what this computer knows)
    return owner, admins
  end
  if trust.same(pins, owner, admins) then return owner, admins end
  local v = tostring(owner) .. "\0" .. table.concat(admins, "\n")
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
  if verdicts[root .. v] then trust.pin(root, owner, admins); return owner, admins end
  return pins.owner, pins.admins
end

-- A removal or closing file: from someone in charge (or, for someone leaving, from their own computer)? Asked once per file and date. -> true/false/nil.
local marks = {}
function trust.mark_ok(root, rel, m)
  local k = root .. rel .. tostring(m.at)
  if marks[k] ~= nil then return marks[k] end
  local pins = trust.pins(root)
  if not pins then return true end -- (a studio from before owners: everyone in it may)
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

return trust
