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
  band.remove(dir(root) .. "/" .. file_name(device))
  access.forget()
end

-- The list as written, unchecked: for the people in charge to see and change (a check still waiting read as "nothing ticked", and ticking one
-- song then cut the guest down to that one. 0.58.93). -> a set of song names, or nil (no list: every project)
function access.read(root, device)
  local v = band.read_json(root .. "/_band/guest-access/" .. file_name(device))
  if not (type(v) == "table" and v.device == device and type(v.songs) == "table") then return nil end
  local set = {}
  for _, s in ipairs(v.songs) do if type(s) == "string" then set[s] = true end end
  return set
end
-- A guest's projects, as someone in charge set them. -> a set of song names, or nil (no list: every project); and whether it's been checked.
-- A list that can't be checked yet, or wasn't written by someone in charge, shows nothing rather than everything: a guest saw every project
-- while Syncthing was slow to answer, and what came then stayed (review, 0.58.92).
local verdicts = {} -- (the file as read -> Syncthing's word, once given: asked every 5 s in every tab, it was a blocking call each time. 0.58.93)
function access.get(root, device)
  local rel = "_band/guest-access/" .. file_name(device)
  local v = band.read_json(root .. "/" .. rel)
  if not (type(v) == "table" and v.device == device and type(v.songs) == "table") then return nil end
  local set = access.read(root, device)
  local key = root .. "\0" .. rel .. "\0" .. tostring(v.at) .. "\0" .. tostring(v.by) .. "\0" .. band.json_encode(v.songs)
  local ok = verdicts[key]
  if ok == nil then
    local trust = require("trust")
    local okp, pins = pcall(trust.pins, root)
    if okp and not pins and not trust.held(root) then ok = true -- (a studio from before owners: everyone in it may, as for removal marks. 0.58.93)
    else
      local okt, r = pcall(trust.from_manager_file, root, rel)
      if not okt then return set, false end -- (the check itself failed: the list as written, a narrowing only)
      ok = r
      if ok == nil and v.by == reaper.GetExtState(band.SECTION, "user") then return set, false end -- (this computer's own, not looked at yet)
    end
    if ok ~= nil then verdicts[key] = ok end
  end
  if ok == nil then return {}, false end
  if ok == false then return {}, true end
  return set, true
end

-- This computer's projects in a studio where it's a guest with a list, or nil (not a guest, or no list). Looked at every 5 s at most.
-- A list for this computer counts whether or not its guest mark can be checked yet (a new guest's couldn't, and they saw everything); one not
-- checked yet shows the last checked list, kept across restarts; with Syncthing not answering, that one too. A guest let in as a member, or
-- invited again for every project, has theirs cleared: lib/tools.lua let_in. Review, 0.58.92-93
local cache = {}
function access.forget() cache = {} end
function access.mine(root)
  local c = cache[root]
  local now = reaper.time_precise() or 0
  if c and now - c.at < 5 then return c.set end
  local key = "guest list " .. root
  local kept
  do
    local was = band.json_decode(reaper.GetExtState(band.SECTION, key))
    if type(was) == "table" then kept = {}; for _, s in ipairs(was) do if type(s) == "string" then kept[s] = true end end end
  end
  local set
  local me = require("services").my_device_id()
  if me then
    local got, checked = access.get(root, me)
    if got == nil then
      set = nil
      if reaper.GetExtState(band.SECTION, key) ~= "" then reaper.SetExtState(band.SECTION, key, "", true) end
    elseif checked then
      set = got
      local list = {}
      for s in pairs(set) do list[#list + 1] = s end
      table.sort(list)
      local keep = band.json_encode(list)
      if reaper.GetExtState(band.SECTION, key) ~= keep then reaper.SetExtState(band.SECTION, key, keep, true) end
    else
      set = kept or got
    end
  else
    set = kept
  end
  cache[root] = { at = now, set = set }
  return set
end
-- Whether a song shows here. Pure over `set`.
function access.shows(set, song) return not set or set[song] == true end

return access
