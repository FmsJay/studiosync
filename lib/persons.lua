-- A person's computers, folded together in a studio (James, 2026-11-27, findings item 9: "James-Laptop and James-Main" read as one person,
-- "James", so it isn't confusing for others). Each computer is still its own studio name (its status, claims, events, devices file), and
-- every check stays per computer; this only says which names are one person, for what people see.
--   Which computers are one person: each computer lists the others it says are its person's in its own devices file (`same`: their device
--   ids, lib/removal.lua publish), and two names are one person only when BOTH say so: A's file lists B's computer and B's file lists A's.
--   Each file counts only when Syncthing (or its signature) says its own computer wrote it (trust.device_ok, as every devices file), so
--   nobody can fold themselves into someone else: that person's own computer would have to name theirs. A third computer linked to either
--   one joins the person the same way (both of that pair say so).
--   What this computer says: ExtState "my computers" (device ids, kept), set from Home's "Your computers" (lib/webhome.lua). Published in a
--   studio only for computers that studio already has a devices file for (a personal computer's id never goes into a studio it isn't in).
--   A person's name: the first display name any of their computers set (lib/profile.lua), else what all their names share before a "-"
--   ("James-Laptop", "James-Main": "James"), else the first name. Their key: the first of their names, sorted (the same on every computer).
-- GPL-3.0-or-later.
local band = require("band")
local persons = {}
persons.KEY = "my computers" -- (ExtState: this computer's list of its person's other computers, by device id; kept)
persons.MAX = 8              -- computers one person may list (more are dropped when read)
persons.EVERY = 10           -- seconds a studio's persons are kept

local function is_id(s) return require("services").is_device_id(s) end
local function user_file(u) return (tostring(u):gsub("[^%w%-_ ]", "")) .. ".json" end

-- ---- pure ------------------------------------------------------------------------------------------------------------------------------
-- A devices file's `same` (another computer's) -> the device ids in it, at most MAX, or {}. Pure but for the id check.
function persons.same_of(d)
  local out = {}
  for _, v in ipairs(type(d) == "table" and type(d.same) == "table" and d.same or {}) do
    if #out >= persons.MAX then break end
    if is_id(v) then out[#out + 1] = v end
  end
  return out
end
-- The studio's people folded: devs = { { user, device, same } } (believed files only); -> user -> { key, users (sorted) } for each name
-- linked to at least one other, both ways. Pure.
function persons.groups(devs)
  local by_dev, says = {}, {}
  for _, d in ipairs(devs or {}) do
    if type(d) == "table" and type(d.user) == "string" and type(d.device) == "string" then
      by_dev[d.device] = d.user
      says[d.user] = {}
      for _, id in ipairs(persons.same_of(d)) do says[d.user][id] = true end
    end
  end
  local dev_of = {}
  for dev, u in pairs(by_dev) do dev_of[u] = dev end
  local parent = {}
  for u in pairs(says) do parent[u] = u end
  local function find(u) while parent[u] ~= u do u = parent[u] end return u end
  for u, list in pairs(says) do
    for id in pairs(list) do
      local v = by_dev[id]
      if v and v ~= u and says[v][dev_of[u]] then -- (both ways)
        local a, z = find(u), find(v)
        if a < z then parent[z] = a elseif z < a then parent[a] = z end
      end
    end
  end
  local members = {}
  for u in pairs(parent) do local r = find(u); members[r] = members[r] or {}; table.insert(members[r], u) end
  local out = {}
  for _, list in pairs(members) do
    if #list > 1 then
      table.sort(list)
      for _, u in ipairs(list) do out[u] = { key = list[1], users = list } end
    end
  end
  return out
end
-- A person's name: names = display names by user (lib/profile.lua's). Pure.
function persons.name_of(users, names)
  for _, u in ipairs(users) do
    local n = type(names) == "table" and type(names[u]) == "table" and names[u].name
    if type(n) == "string" and n ~= "" then return n end
  end
  local first
  for _, u in ipairs(users) do
    local p = tostring(u):match("^(.-)%-") or tostring(u)
    if first == nil then first = p elseif p ~= first then first = false end
  end
  return (first and first ~= "") and first or users[1]
end

-- Who's here's people (lib/webui.lua presence_model: { { user, me, playing, recording, armed, live, call } }, you first) with one entry a person:
-- the first of their computers here (you: this one) stands for them, with each computer's own entry in `devices` (more than one only);
-- playing, recording and call when any is, armed all of theirs. key_of(user) -> their person. Pure.
function persons.fold_people(people, key_of)
  local out, at = {}, {}
  for _, p in ipairs(people or {}) do
    local k = key_of(p.user)
    local i = at[k]
    if not i then out[#out + 1] = p; at[k] = #out
    else
      local e = out[i]
      if not e.devices then
        local first = {}
        for kk, v in pairs(e) do first[kk] = v end
        local merged = {}
        for kk, v in pairs(e) do merged[kk] = v end
        merged.armed, merged.devices = {}, { first }
        for _, a in ipairs(e.armed or {}) do merged.armed[#merged.armed + 1] = a end
        out[i], e = merged, merged
      end
      e.devices[#e.devices + 1] = p
      e.playing, e.recording, e.call, e.live = e.playing or p.playing, e.recording or p.recording, e.call or p.call, e.live or p.live
      for _, a in ipairs(p.armed or {}) do e.armed[#e.armed + 1] = a end
    end
  end
  return out
end

-- ---- reading a studio --------------------------------------------------------------------------------------------------------------------
local cache = {} -- root -> { at, map }
-- The studio's devices files that count (each written by its own computer: trust.device_ok). -> { { user, device, same } }
function persons.devices(root)
  local trust, out = require("trust"), {}
  for _, f in ipairs(band.files(root .. "/_band/devices", ".json")) do
    local d = band.read_json(root .. "/_band/devices/" .. f)
    if type(d) == "table" and type(d.user) == "string" and user_file(d.user) == f and is_id(d.device) then
      local ok, said = pcall(trust.device_ok, root, d.user, d.device)
      if ok and said == true then out[#out + 1] = { user = d.user, device = d.device, same = d.same } end
    end
  end
  return out
end
-- user -> { key, name, users } for every name folded with another; kept EVERY s.
function persons.map(root)
  local c = cache[root]
  if c and reaper.time_precise() - c.at < persons.EVERY then return c.map end
  local ok, devs = pcall(persons.devices, root)
  local map = persons.groups(ok and devs or {})
  local okp, names = pcall(function() return require("profile").all(root) end)
  local named = {}
  for _, p in pairs(map) do
    if not named[p.key] then named[p.key] = persons.name_of(p.users, okp and names or {}) end
    p.name = named[p.key]
  end
  cache[root] = { at = reaper.time_precise(), map = map }
  return map
end
function persons.forget(root) if root then cache[root] = nil else cache = {} end end
-- Whose person a name is: their key (the name itself when it isn't folded with another).
function persons.of(root, user)
  local p = root and persons.map(root)[user]
  return p and p.key or user
end
-- Are two names one person (the same name too)?
function persons.same(root, a, z) return a == z or (a ~= nil and z ~= nil and persons.of(root, a) == persons.of(root, z)) end
-- A name as others should read it: "James (James-Main)" for a folded one, "you, on James-Main" for another of `me`'s computers, else the name.
function persons.label(root, user, me)
  local p = root and persons.map(root)[user]
  if not p then return tostring(user) end
  if me and user ~= me and persons.same(root, user, me) then return "you, on " .. user end
  return p.name == user and user or (p.name .. " (" .. user .. ")")
end

-- ---- this computer's side ---------------------------------------------------------------------------------------------------------------
function persons.mine()
  local out = {}
  for _, id in ipairs(band.ext_json(band.SECTION, persons.KEY) or {}) do if #out < persons.MAX and is_id(id) then out[#out + 1] = id end end
  return out
end
-- What this computer's devices file in `root` says (lib/removal.lua publish): its ids that the studio has a devices file for, sorted; nil: none.
function persons.same_for(root)
  local mine = persons.mine()
  if #mine == 0 then return nil end
  local have = {}
  for _, f in ipairs(band.files(root .. "/_band/devices", ".json")) do
    local d = band.read_json(root .. "/_band/devices/" .. f)
    if type(d) == "table" and type(d.device) == "string" then have[d.device] = true end
  end
  local out = {}
  for _, id in ipairs(mine) do if have[id] then out[#out + 1] = id end end
  table.sort(out)
  return #out > 0 and out or nil
end
-- The studio's computers as Home's "Your computers" shows them: { { user, state } } with state "this" (this computer), "yours" (both say
-- so), "waiting" (you said so, it hasn't yet), "asks" (it says it's yours, you haven't) or "other". me: this computer's name. Pure but for
-- the files and ExtState.
function persons.computers(root, me)
  local mine, out = {}, {}
  for _, id in ipairs(persons.mine()) do mine[id] = true end
  local ok, devs = pcall(persons.devices, root)
  local my_dev
  for _, d in ipairs(ok and devs or {}) do if d.user == me then my_dev = d.device end end
  local map = persons.map(root)
  for _, d in ipairs(ok and devs or {}) do
    local state = "other"
    if d.user == me then state = "this"
    elseif map[d.user] and persons.same(root, d.user, me) then state = "yours"
    elseif mine[d.device] then state = "waiting"
    else
      for _, id in ipairs(persons.same_of(d)) do if id == my_dev then state = "asks" end end
    end
    out[#out + 1] = { user = d.user, state = state }
  end
  table.sort(out, function(a, z) return a.user < z.user end)
  return out
end
-- Home's "This one's mine too" / "Not mine": the computer that writes `user`'s devices file in `root` goes on or off this computer's list.
-- Only a computer whose own file names it (trust.device_ok). The devices file is written again at the next publish (now, not 30 s on).
-- -> words for the log, or nil and why.
function persons.set(root, user, on)
  if type(user) ~= "string" then return nil, "no such computer" end
  local id
  for _, d in ipairs(persons.devices(root)) do if d.user == user then id = d.device end end
  if not id then return nil, user .. " isn't a computer in this studio (or its devices file isn't checked yet)" end
  if id == require("services").my_device_id() then return nil, "that's this computer" end
  local list, out = persons.mine(), {}
  for _, x in ipairs(list) do if x ~= id then out[#out + 1] = x end end
  if on then
    if #out >= persons.MAX then return nil, "at most " .. persons.MAX .. " computers" end
    out[#out + 1] = id
  end
  band.set_ext_json(band.SECTION, persons.KEY, out, true)
  reaper.SetExtState(band.SECTION, require("removal").PUBLISH_KEY, "0", false) -- (the devices file goes out at the next look)
  persons.forget(root)
  return on and (user .. " is one of your computers now: it shows as you once it says the same about this one")
    or (user .. " is no longer one of your computers")
end

return persons
