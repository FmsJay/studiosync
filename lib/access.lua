-- Guests who see only some projects (James, 0.58.89: "can it be built so the guest simply wouldn't see the other projects unless given
-- access to another project directly? They can still exist, just not visible on StudioSync"). Whoever invites a guest picks which
-- projects (all, or some), and can give them another later: _band/guest-access/<their computer>.json = { device, songs = { ... }, by, at }.
-- It counts only when Syncthing says the owner's or an admin's computer wrote it (lib/trust.lua), or this computer just did.
-- On the guest's computer, StudioSync then leaves the others out entirely: they aren't listed anywhere in StudioSync, and Syncthing's
-- ignore file there (lib/songsync.lua) doesn't fetch them, not even their listing. What this is and isn't: the projects are hidden from
-- the guest, not locked. One shared folder goes to every computer in it, and Syncthing can't send different files to different
-- computers, so the leaving out happens on the guest's computer: someone who knows Syncthing could undo it there. A guest with no
-- list (an invitation for all projects, or from before 0.58.89) sees everything, as before.
local band = require("band")
local access = {}

local function dir(root) return root .. "/_band/guest-access" end
local function file_name(device) return (tostring(device):sub(1, 7):gsub("[^%w]", "")) .. ".json" end

function access.set(root, device, songs, by)
  local list = {}
  for _, s in ipairs(songs or {}) do if type(s) == "string" and s ~= "" then list[#list + 1] = s end end
  table.sort(list)
  reaper.RecursiveCreateDirectory(dir(root), 0)
  band.write_json(dir(root) .. "/" .. file_name(device), { device = device, songs = list, by = by, at = os.time() })
  access.forget()
end
function access.clear(root, device)
  os.remove(dir(root) .. "/" .. file_name(device))
  access.forget()
end

-- A guest's projects, as someone in charge set them: a set of song names, or nil (no list: every project).
function access.get(root, device)
  local rel = "_band/guest-access/" .. file_name(device)
  local v = band.read_json(root .. "/" .. rel)
  if not (type(v) == "table" and v.device == device and type(v.songs) == "table") then return nil end
  local okt, ok = pcall(require("trust").from_manager_file, root, rel)
  if okt and ok == false then return nil end
  if okt and ok == nil and v.by ~= reaper.GetExtState(band.SECTION, "user") then return nil end -- (not looked at by Syncthing yet: only this computer's own)
  local set = {}
  for _, s in ipairs(v.songs) do if type(s) == "string" then set[s] = true end end
  return set
end

-- This computer's projects in a studio where it's a guest with a list, or nil (not a guest, or no list). Looked at every 5 s at most.
local cache = {}
function access.forget() cache = {} end
function access.mine(root)
  local c = cache[root]
  local now = reaper.time_precise() or 0
  if c and now - c.at < 5 then return c.set end
  local set
  local me = require("services").my_device_id()
  if me then
    local guest = false
    for _, g in ipairs(require("removal").guests(root, os.time())) do guest = guest or g.device == me end
    if guest then set = access.get(root, me) end
  end
  cache[root] = { at = now, set = set }
  return set
end
-- Whether a song shows here. Pure over `set`.
function access.shows(set, song) return not set or set[song] == true end
-- The songs left out here, given every song folder in the studio (`all`), or nil when nothing is. Pure over its arguments.
function access.left_out(set, all)
  if not set then return nil end
  local out = {}
  for _, s in ipairs(all) do if not set[s] then out[s] = true end end
  return out
end

return access
