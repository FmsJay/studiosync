-- Who runs a group, renaming one, leaving one, and closing one. _band/band.json names the owner (whoever started it) and any admins.
-- The owner does everything; admins let people in, rename and remove members; a group from before owners is open to everyone in it.
-- Leaving keeps your copy: the folder stays on this computer and the project's tab stays open as an ordinary project. A mark tells
-- the others (lib/removal.lua), and this computer's Syncthing lets go a little later, so the mark has time to reach them. Closing is
-- the owner ending it for everyone: _band/closed.json, and each computer leaves when it sees that.
-- Anyone in the group could write these files: a change to the roles, or a close, is believed only from the owner's or an admin's computer,
-- as Syncthing tells it (lib/trust.lua, 0.58.69).
local band = require("band")
local groups = { WAIT = 20, QUIET_DAYS = 7 } -- seconds the mark gets to reach the others; when nobody's been seen for this long, say so

local function json_of(root)
  local j = band.read_json(root .. "/_band/band.json")
  return type(j) == "table" and j or {}
end

-- The studio's settings that reach outside it (James's review, 0.58.87: any member could rewrite band.json): where alerts go, the call link,
-- the private live-audio server, the studio's Tailscale network and Sync only through Tailscale. Taken from band.json only when Syncthing says
-- the owner's or an admin's computer wrote it (lib/trust.lua); one from anyone else leaves the last trusted values standing (ExtState "trusted
-- settings <root>", kept). Syncthing not saying yet, or a studio from before owners: band.json as it is, as before. Read at most every 5 s.
local SETTINGS = { "alerts", "alerts_server", "call", "sonobus_server", "tailnet", "tailscale_only", "colours", "debug" }
local trusted_at = {}
function groups.trusted(root)
  local c, now = trusted_at[root], reaper.time_precise() or 0
  if c and now - c.at < 5 then return c.j end
  local j = json_of(root)
  local okt, ok = pcall(require("trust").from_manager_file, root, "_band/band.json")
  local key = "trusted settings " .. band.norm(root):lower()
  local out = {}
  local stored = band.json_decode(reaper.GetExtState(band.SECTION, key))
  -- (not known yet, Syncthing slow or held back: the last checked settings, not the file as anyone wrote it. Review, 0.58.98)
  if okt and ok == false then
    out = stored or {}
  elseif not (okt and ok == true) and type(stored) == "table" then
    out = stored
  else
    for _, k in ipairs(SETTINGS) do out[k] = j[k] end
    if okt and ok == true then reaper.SetExtState(band.SECTION, key, band.json_encode(out), true) end
  end
  trusted_at[root] = { at = now, j = out }
  return out
end

local seen = {}
local function who(root) -- read at most every few seconds: the panel asks each frame
  local c = seen[root]
  if not c or reaper.time_precise() - c.at > 5 then
    local owner, admins = require("trust").roles(root, json_of(root)) -- (who band.json says, only if someone in charge said it: lib/trust.lua)
    c = { at = reaper.time_precise(), owner = owner, admins = {} }
    for _, a in ipairs(admins) do c.admins[a] = true end
    seen[root] = c
  end
  return c
end

-- "owner", "admin", "member"; "open" in a group from before owners.
function groups.role(root, user)
  local c = who(root)
  if not c.owner then return "open" end
  return c.owner == user and "owner" or c.admins[user] and "admin" or "member"
end
-- May let people in, and rename.
function groups.may_manage(root, user) return groups.role(root, user) ~= "member" end
-- May take `target` out: the owner anyone else, an admin only members.
function groups.may_remove(root, by, target)
  if by == target then return false end
  local r, t = groups.role(root, by), groups.role(root, target)
  if r == "open" or r == "owner" then return true end
  return r == "admin" and t == "member"
end

-- The studio's SonoBus secret (band.json `sonobus`): the live audio's password is worked out from it (lib/live.lua sonobus_group). Made by the
-- owner's computer once (groups.tick), and made again when someone is taken out (lib/removal.lua), so what they knew stops working.
function groups.sonobus_secret(root)
  local j = json_of(root)
  return type(j.sonobus) == "string" and j.sonobus ~= "" and j.sonobus or nil
end
local save
function groups.new_sonobus_secret(root)
  save(root, function(j) j.sonobus = band.secret(24) end)
end

save = function(root, change)
  trusted_at[root] = nil -- (a setting changed here shows at once)
  local info, j = band.info(root), json_of(root)
  j.name, j.id, j.drive = info.name, info.id, info.drive
  -- (the roles this computer goes by, not a change it set aside: written back as they were, it would reach everyone as this computer's own)
  local trust = require("trust")
  local owner, admins = trust.roles(root, j)
  -- (an invited computer still waiting for its inviter's writing goes by the inviter alone: the roles on disk go back as they were, and
  -- aren't pinned as this computer's own. lib/trust.lua, Security review, 0.58.78)
  local held = trust.held(root)
  if not held then j.owner, j.admins = owner, #admins > 0 and admins or nil end
  change(j)
  if j.owner and not held then trust.pin(root, trust.roles_of(j)) end -- (this computer's own change: its panel checked who may first)
  -- (and, written out with the roles, the computers this one has pinned as whoever's in charge, and when: a computer new to the studio pins
  -- from these, not from devices files, where anyone can claim a name; and a writing of the same roles is a new one. Security review, 0.58.78)
  if j.owner and not held then j.managers = trust.managers(root, trust.roles_of(j)) end
  j.roles_at = os.time()
  reaper.RecursiveCreateDirectory(root .. "/_band", 0)
  band.write_json(root .. "/_band/band.json", j)
  seen[root] = nil
end
function groups.edit(root, change) save(root, change) end -- (lib/alerts.lua's channel)
-- Private live audio (research of other tools, 0.58.53: SonoBus's audio isn't encrypted, and its public server introduces everyone). One
-- member keeps SonoBus's own app open, which has a connection server built in (port 10999); everyone's SonoBus joins through that computer's
-- Tailscale name, so the band finds each other by Tailscale addresses and the audio goes inside Tailscale's encryption. band.json
-- "sonobus_server" = "<name>:<port>". -> host, port; or nil (SonoBus's public server). Pure but for the read.
function groups.server_ok(s) return type(s) == "string" and s:match("^[%w%.%-]+:%d+$") ~= nil end
function groups.sonobus_server(root)
  local s = groups.trusted(root).sonobus_server
  if not groups.server_ok(s) then return nil end
  local host, port = s:match("^(.+):(%d+)$")
  return host, tonumber(port)
end
function groups.set_sonobus_server(root, s) save(root, function(j) j.sonobus_server = groups.server_ok(s) and s or nil end) end
-- The Tailscale network the studio's Tailscale features use (band.json "tailnet": { name, suffix }): set from the computer that sets one of
-- them up (a guest invitation, private live audio, the listening page). -> it, or nil. Pure but for the read.
function groups.tailnet(root)
  local t = groups.trusted(root).tailnet
  if type(t) == "table" and type(t.name) == "string" and type(t.suffix) == "string" and t.suffix:match("^[%w%-]+%.ts%.net$") then return t end
end
function groups.set_tailnet(root)
  local name, suffix = require("services").tailnet_now()
  if not (name and suffix) then return false end
  local t = groups.tailnet(root)
  if t and t.suffix == suffix then return true end
  save(root, function(j) j.tailnet = { name = name, suffix = suffix } end)
  return true
end
-- Does the studio sync only through its Tailscale network (band.json "tailscale_only": services.pin_tailnet)? Set by the owner or an admin.
function groups.tailscale_only(root) return groups.trusted(root).tailscale_only == true and groups.tailnet(root) ~= nil end
function groups.set_tailscale_only(root, on) save(root, function(j) j.tailscale_only = on and true or nil end) end
-- The studio's look (0.58.98): { scheme, palette, from, to }, what a new project is coloured in (lib/colours.lua auto). Owner and admins.
function groups.colours(root) local c = groups.trusted(root).colours; return type(c) == "table" and type(c.scheme) == "string" and c or nil end
function groups.set_colours(root, c) save(root, function(j) j.colours = c end) end
function groups.set_debug(root, on) save(root, function(j) j.debug = on and true or nil end) end -- (lib/debugmode.lua: owner and admins)

-- The owner makes someone an admin or a member again. -> true, or nil + why.
function groups.set_admin(root, actor, target, on)
  if groups.role(root, actor) ~= "owner" then return nil, "Only the owner can do that." end
  save(root, function(j)
    local list = {}
    for _, a in ipairs(type(j.admins) == "table" and j.admins or {}) do if a ~= target then list[#list + 1] = a end end
    if on then list[#list + 1] = target end
    j.admins = #list > 0 and list or nil
  end)
  return true
end
-- The owner hands the group to someone. They were an admin or not; the old owner stays on as an admin.
function groups.hand_over(root, actor, target)
  if groups.role(root, actor) ~= "owner" or actor == target then return nil, "Only the owner can do that." end
  save(root, function(j)
    local list = { actor }
    for _, a in ipairs(type(j.admins) == "table" and j.admins or {}) do if a ~= target and a ~= actor then list[#list + 1] = a end end
    j.owner, j.admins = target, list
  end)
  return true
end

-- Everyone sees the new name. The ID and the folder names, here and on Drive, stay: changing those would sync it all again.
function groups.rename(root, name, by)
  if not groups.may_manage(root, by) then return nil, "Only the owner or an admin can do that." end
  name = band.clean(name or "")
  if name == "" then return nil, "Give it a name." end
  for _, x in ipairs(band.bands()) do
    if x.root ~= root and x.name:lower() == name:lower() then return nil, "You're already in a studio called " .. x.name .. "." end
  end
  local id = band.info(root).id
  save(root, function(j) j.name = name end)
  require("services").set_folder_label(id, "StudioSync " .. name)
  return name
end

-- The tabs of this group: { proj }.
local function tabs_of(root)
  local list = {}
  local base = { root = reaper.GetExtState(band.SECTION, "sync_root"), user = reaper.GetExtState(band.SECTION, "user") }
  for i = 0, math.huge do
    local p = reaper.EnumProjects(i)
    if not p then break end
    local b = band.binding(p)
    if b and band.for_tab(base, b).root == root then list[#list + 1] = p end
  end
  return list
end
local function recording(root)
  for _, p in ipairs(tabs_of(root)) do
    if reaper.GetPlayStateEx(p) & 4 == 4 then return true end
  end
  return false
end

-- Groups this computer has left, or that were closed: nothing syncs, the copy stays until you delete it (the Groups page).
function groups.old()
  local t = band.json_decode(reaper.GetExtState(band.SECTION, "old groups"))
  return type(t) == "table" and t or {}
end
function groups.remember_old(root, name, id)
  local t = groups.old()
  for _, o in ipairs(t) do if o.root == root then return end end
  t[#t + 1] = { root = root, name = name, id = id, at = os.time() }
  reaper.SetExtState(band.SECTION, "old groups", band.json_encode(t), true)
end
-- A folder taken off the list: the copy was deleted, or it stays and nobody needs telling.
function groups.forget_old(root)
  local t = {}
  for _, o in ipairs(groups.old()) do if o.root ~= root then t[#t + 1] = o end end
  reaper.SetExtState(band.SECTION, "old groups", band.json_encode(t), true)
end
function groups.is_old(root)
  for _, o in ipairs(groups.old()) do if o.root == root then return true end end
  return false
end

-- This computer out of a group. `over`: it's closed, or nobody's left in it, so it may be the last group here, which then stays the current one.
function groups.leave(root, me, over)
  if not over and groups.role(root, me) == "owner" then return nil, "You own this. Make someone else the owner first (their card in Who's here), or close it." end
  local others = {}
  for _, x in ipairs(band.bands()) do if x.root ~= root then others[#others + 1] = x.root end end
  if #others == 0 and not over then return nil, "This is your only studio. Start or join another first." end
  if recording(root) then return nil, "Stop recording first." end
  local info = band.info(root)
  for _, p in ipairs(tabs_of(root)) do -- (Live sync sees it isn't a group project any more, and stops)
    reaper.SetProjExtState(p, band.SECTION, "", "")
    reaper.MarkProjectDirty(p)
  end
  local id = require("services").my_device_id()
  if id then require("removal").left(root, me, id) end
  groups.remember_old(root, info.name, info.id)
  local leaving = band.json_decode(reaper.GetExtState(band.SECTION, "leaving"))
  leaving = type(leaving) == "table" and leaving or {}
  leaving[#leaving + 1] = { id = info.id, at = os.time() }
  reaper.SetExtState(band.SECTION, "leaving", band.json_encode(leaving), true)
  if #others > 0 then
    reaper.SetExtState(band.SECTION, "bands", table.concat(others, "|"), true)
    if reaper.GetExtState(band.SECTION, "sync_root") == root then reaper.SetExtState(band.SECTION, "sync_root", others[1], true) end
  end
  seen[root] = nil
  return true
end

-- The owner ends it for everyone.
function groups.close(root, me)
  if groups.role(root, me) ~= "owner" then return nil, "Only the owner can close it." end
  if recording(root) then return nil, "Stop recording first." end
  band.write_json(root .. "/_band/closed.json", { by = me, at = os.time() })
  reaper.SetExtState(band.SECTION, "group closed " .. band.info(root).id, "1", true)
  return groups.leave(root, me, true)
end

-- Run from removal.tick, every 30 s or so: Syncthing lets go of what this computer left, a closed group is over here too, and a group
-- nobody's been seen in for a week gets a word (closed or removed while this computer was off: nothing can reach it to say so).
local said_quiet = {}
function groups.tick(now)
  local services = require("services")
  local leaving = band.json_decode(reaper.GetExtState(band.SECTION, "leaving"))
  if type(leaving) == "table" and #leaving > 0 then
    local still = {}
    for _, l in ipairs(leaving) do
      if now - (tonumber(l.at) or 0) < groups.WAIT or not services.forget_folder(l.id) then still[#still + 1] = l end
    end
    reaper.SetExtState(band.SECTION, "leaving", #still > 0 and band.json_encode(still) or "", true)
  end
  local me = reaper.GetExtState(band.SECTION, "user")
  for _, g in ipairs(band.bands()) do
    -- (the owner's computer gives a studio from before 0.58.52 its SonoBus secret: only the owner, so two computers can't make two)
    if me ~= "" and groups.role(g.root, me) == "owner" and not groups.sonobus_secret(g.root) and not groups.is_old(g.root) then
      groups.new_sonobus_secret(g.root)
      band.log(g.name .. "'s live audio has a password of its own now (everyone's SonoBus picks it up the next time Real time mode connects)")
    end
    -- (the phone alerts' channel changed: someone was taken out (lib/removal.lua), or it was turned off and on. A phone on the old one hears nothing now)
    local ch, seen_key = require("alerts").channel(g.root), "alerts seen " .. g.id
    local was = reaper.GetExtState(band.SECTION, seen_key)
    if ch and was ~= "" and was ~= ch and not groups.is_old(g.root) then
      band.log(g.name .. "'s phone alerts have a new channel: to keep getting them, subscribe to it in ntfy (Settings > Studio > Phone alerts has it)")
    end
    if (ch or "") ~= was then reaper.SetExtState(band.SECTION, seen_key, ch or "", true) end
    local key = "group closed " .. g.id
    if reaper.GetExtState(band.SECTION, key) == "" and not groups.is_old(g.root) then
      local e = band.read_json(g.root .. "/_band/closed.json")
      if type(e) == "table" and e.by and groups.role(g.root, e.by) ~= "member" and require("trust").mark_ok(g.root, "_band/closed.json", e) then
        if groups.leave(g.root, me, true) then -- (not: something's recording. The next look does it)
          reaper.SetExtState(band.SECTION, key, "1", true)
          band.log(string.format("%s closed %s: nothing syncs any more, and your copy stays in %s", tostring(e.by), g.name, g.root))
        end
      elseif not said_quiet[g.id] then
        local days = services.days_quiet(g.id)
        if days and days >= groups.QUIET_DAYS then
          said_quiet[g.id] = true
          band.log(string.format("nobody in %s has been online for %d days. It may have been closed, or you taken out: you can leave it on the Studios page", g.name, days))
        end
      end
    end
  end
end

-- Is Syncthing still to let go of this folder (it was left or closed a moment ago)? Deleting the copy before that reached everyone. Review, 0.58.47.
function groups.still_leaving(id)
  local leaving = band.json_decode(reaper.GetExtState(band.SECTION, "leaving"))
  for _, l in ipairs(type(leaving) == "table" and leaving or {}) do if l.id == id then return true end end
  return false
end
return groups
