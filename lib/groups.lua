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
local SETTINGS = { "alerts", "alerts_server", "call", "sonobus_server", "tailnet", "tailscale_only", "colours", "debug", "updates", -- ("updates": lib/fromfolder.lua, 0.59.25)
  "print_hops" } -- ("print_hops": chained prints, lib/prints.lua hops_cap. James, 0.59.49)
-- (Round 2 review, 0.59.46: Syncthing is asked again only when band.json or this computer's pins changed, or the last answer was "not known",
-- and the kept settings are written only when they differ: it was a blocking call and a saved-state write every 5 s per script and studio,
-- and the Debug pill made the panel do it for every studio. -> the settings, and false when they're held back only because nothing is checked
-- yet (groups save leaves the file's own values then).)
local trusted_at, trusted_asked = {}, {}
local function pins_of(root) local ok, p = pcall(require("trust").pins, root); return ok and p or nil end
local function pinned(root) return pins_of(root) ~= nil end
local function invited(root) local ok, i = pcall(function() return require("trust").inviter(root) end); return ok and i ~= nil end
-- (and a third answer, `checked`: false while nothing is verified here (no answer from Syncthing, or "not from a manager" with nothing kept),
-- for groups save. Round 3 review, 0.59.48)
groups.RECHECK = 120 -- (seconds before a "not from a manager" answer is asked again: Round 3 review, 0.59.48)
function groups.trusted(root)
  local c, now = trusted_at[root], reaper.time_precise() or 0
  if c and now - c.at < 5 and now >= c.at then return c.j, c.sure, c.checked end
  local j = json_of(root)
  local p = pins_of(root)
  local sig = band.json_encode(j) .. "\0" .. (p and band.json_encode(p) or "")
  local a = trusted_asked[root]
  local okt, ok
  -- (a "no" is kept too, and asked again after RECHECK: `okt and ok or nil` made it nil, so a band.json last written from a computer not pinned
  -- as a manager's was asked about every 5 s by every script. Round 3 review, 0.59.48)
  if a and a.sig == sig and a.ok ~= nil and (a.ok or (now - a.at < groups.RECHECK and now >= a.at)) then okt, ok = true, a.ok
  else
    okt, ok = pcall(require("trust").from_manager_file, root, "_band/band.json")
    if okt and ok ~= nil then trusted_asked[root] = { sig = sig, ok = ok, at = now } else trusted_asked[root] = { sig = sig } end
  end
  local key = "trusted settings " .. band.norm(root):lower()
  local out, sure, checked = {}, true, true
  local stored = band.ext_json(band.SECTION, key)
  -- (not known yet, Syncthing slow or held back: the last checked settings, not the file as anyone wrote it. Review, 0.58.98)
  if okt and ok == false then
    out, checked = stored or {}, type(stored) == "table"
  elseif not (okt and ok == true) and type(stored) == "table" then
    out = stored
  -- (an invited computer with no pins yet too, whatever band.json's owner says: a member who took "owner" out of band.json had every new
  -- joiner believe her settings, "updates" included. James's decision, Round 3 review, 0.59.48)
  elseif not (okt and ok == true) and (type(j.owner) == "string" or pinned(root) or invited(root)) then
    -- (an owner named and nothing checked yet here: nothing, until Syncthing says who wrote it. Believed as written, a member could switch a new
    -- joiner to folder code in a studio that never chose it. The inviter writes band.json again at Let in, so the answer comes within seconds.
    -- A studio from before owners: as written, as before. Round 1 review, 0.59.45)
    out, sure, checked = {}, false, false
  else
    for _, k in ipairs(SETTINGS) do out[k] = j[k] end
    if okt and ok == true and band.json_encode(out) ~= band.json_encode(stored or false) then band.set_ext_json(band.SECTION, key, out, true) end
  end
  trusted_at[root] = { at = now, j = out, sure = sure, checked = checked }
  return out, sure, checked
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
-- -> false when it wasn't made (nothing verified here yet: the callers said it was, and a removal never changed it. Round 4 review, 0.59.49)
function groups.new_sonobus_secret(root)
  return save(root, function(j) j.sonobus = band.secret(24) end, nil, true) ~= false -- (no click: groups.tick and lib/removal.lua)
end

-- (`quiet`: a save nobody clicked for (removal.tick, groups.tick, set_tailnet). While nothing is verified here it isn't made: it wrote empty
-- settings as a manager's, which everyone took, or a member's planted ones. Round 3 review, 0.59.48) -> false when it wasn't made.
save = function(root, change, owner_said, quiet)
  trusted_at[root] = nil -- (a setting changed here shows at once)
  -- (the outward settings as last trusted, not as the file has them: written back from a manager's computer, a call link or alerts server a
  -- member or guest slipped into band.json became trusted, and some saves need no click (removal.tick, groups.tick, set_tailnet). Review, 0.59.14)
  -- (nothing checked here yet, with Syncthing not answering: the file's own values, not the empty ones this computer goes by meanwhile,
  -- which wiped every outward setting for everyone, "updates" too. Round 2 review, 0.59.46)
  local t, sure, checked = groups.trusted(root)
  if quiet and not owner_said and checked == false then return false end
  local info, j = band.info(root), json_of(root)
  j.name, j.id, j.drive = info.name, info.id, info.drive
  if sure ~= false then for _, k in ipairs(SETTINGS) do j[k] = t[k] end end
  -- (the roles this computer goes by, not a change it set aside: written back as they were, it would reach everyone as this computer's own)
  local trust = require("trust")
  local owner, admins = trust.roles(root, j)
  -- (an invited computer still waiting for its inviter's writing goes by the inviter alone: the roles on disk go back as they were, and
  -- aren't pinned as this computer's own. lib/trust.lua, Security review, 0.58.78)
  local held = trust.held(root)
  if not held then j.owner, j.admins = owner, #admins > 0 and admins or nil end
  -- (`owner_said`: set_admin or hand_over, which checked the owner said it; else this computer's person is the owner)
  local by_owner = not held and owner ~= nil and (owner_said or owner == reaper.GetExtState(band.SECTION, "user"))
  change(j)
  if j.owner and not held then trust.pin(root, trust.roles_of(j)) end -- (this computer's own change: its panel checked who may first)
  -- (and, written out with the roles, the computers this one has pinned as whoever's in charge, and when: a computer new to the studio pins
  -- from these, not from devices files, where anyone can claim a name; and a writing of the same roles is a new one. Security review, 0.58.78)
  if j.owner and not held then j.managers = trust.managers(root, trust.roles_of(j)) end
  j.roles_at = os.time()
  reaper.RecursiveCreateDirectory(root .. "/_band", 0)
  band.write_json(root .. "/_band/band.json", j)
  -- (and the roles file the others go by, from the owner's computer only, when its roles changed: an admin's save can't mask the owner's change
  -- any more (lib/trust.lua roles). James's decision, Round 2 review, 0.59.46)
  if by_owner and j.owner then
    local was = band.read_json(root .. "/_band/roles.json")
    local now_roles = { owner = j.owner, admins = j.admins, managers = j.managers }
    if not (type(was) == "table" and band.json_encode({ owner = was.owner, admins = was.admins, managers = was.managers }) == band.json_encode(now_roles)) then
      now_roles.roles_at = j.roles_at
      band.write_json(root .. "/_band/roles.json", now_roles)
    end
  end
  seen[root], trusted_at[root] = nil, nil
end
-- (`quiet`: as save's, for a change nobody clicked (lib/removal.lua's new alerts channel) -> false when it wasn't made. Round 4 review, 0.59.49)
function groups.edit(root, change, quiet) return save(root, change, nil, quiet) ~= false end -- (lib/alerts.lua's channel)
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
  save(root, function(j) j.tailnet = { name = name, suffix = suffix } end, nil, true)
  return true
end
-- Does the studio sync only through its Tailscale network (band.json "tailscale_only": services.pin_tailnet)? Set by the owner or an admin.
function groups.tailscale_only(root) return groups.trusted(root).tailscale_only == true and groups.tailnet(root) ~= nil end
function groups.set_tailscale_only(root, on) save(root, function(j) j.tailscale_only = on and true or nil end) end
-- The studio's look (0.58.98): { scheme, palette, from, to }, what a new project is coloured in (lib/colours.lua auto). Owner and admins.
function groups.colours(root) local c = groups.trusted(root).colours; return type(c) == "table" and type(c.scheme) == "string" and c or nil end
function groups.set_colours(root, c) save(root, function(j) j.colours = c end) end
function groups.set_debug(root, on) save(root, function(j) j.debug = on and true or nil end) end -- (lib/debugmode.lua: owner and admins)
function groups.set_folder_updates(root, on) save(root, function(j) j.updates = on and "folder" or nil end) end -- (lib/fromfolder.lua: owner and admins)
-- Plug-in hand-overs a chained print may take (lib/prints.lua hops_cap: 0, 1, 3 or "any"; nil is the default, 2). Owner and admins.
function groups.set_print_hops(root, v) save(root, function(j) j.print_hops = v end) end

-- The owner makes someone an admin or a member again. -> true, or nil + why.
function groups.set_admin(root, actor, target, on)
  if groups.role(root, actor) ~= "owner" then return nil, "Only the owner can do that." end
  save(root, function(j)
    local list = {}
    for _, a in ipairs(type(j.admins) == "table" and j.admins or {}) do if a ~= target then list[#list + 1] = a end end
    if on then list[#list + 1] = target end
    j.admins = #list > 0 and list or nil
  end, true)
  return true
end
-- The owner hands the group to someone. They were an admin or not; the old owner stays on as an admin.
function groups.hand_over(root, actor, target)
  if groups.role(root, actor) ~= "owner" or actor == target then return nil, "Only the owner can do that." end
  save(root, function(j)
    local list = { actor }
    for _, a in ipairs(type(j.admins) == "table" and j.admins or {}) do if a ~= target and a ~= actor then list[#list + 1] = a end end
    j.owner, j.admins = target, list
  end, true)
  return true
end

-- Everyone sees the new name. The ID and the folder names, here and on Drive, stay: changing those would sync it all again.
function groups.rename(root, name, by)
  if not groups.may_manage(root, by) then return nil, "Only the owner or an admin can do that." end
  local problem = band.name_problem(name) -- (another alphabet, or a name Windows keeps: Round 1 review, 0.59.45)
  if problem then return nil, problem end
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
  local t = band.ext_json(band.SECTION, "old groups")
  return type(t) == "table" and t or {}
end
function groups.remember_old(root, name, id)
  local t = groups.old()
  for _, o in ipairs(t) do if o.root == root then return end end
  t[#t + 1] = { root = root, name = name, id = id, at = os.time() }
  band.set_ext_json(band.SECTION, "old groups", t, true)
end
-- A folder taken off the list: the copy was deleted, or it stays and nobody needs telling.
function groups.forget_old(root)
  local t = {}
  for _, o in ipairs(groups.old()) do if o.root ~= root then t[#t + 1] = o end end
  band.set_ext_json(band.SECTION, "old groups", t, true)
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
  local leaving = band.ext_json(band.SECTION, "leaving")
  leaving = type(leaving) == "table" and leaving or {}
  leaving[#leaving + 1] = { id = info.id, at = os.time() }
  band.set_ext_json(band.SECTION, "leaving", leaving, true)
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

-- Does the studio's closed.json count: naming the owner, and written (as Syncthing says) by the pinned owner's computer, or this one while its
-- person is the owner? -> true and the file's table, or false. The answer is kept per file as read; "not yet" is asked again after 30 s
-- (lib/trust.lua). The Studios page goes by this too: a closed.json anyone wrote hid the studio there. Round 1 review, 0.59.45.
local closed_seen = {}
function groups.closed_ok(root)
  local e = band.read_json(root .. "/_band/closed.json")
  if not (type(e) == "table" and type(e.by) == "string") then return false end
  local k = root .. "\0" .. e.by .. "\0" .. tostring(e.at)
  -- (a "no" given while held lasts only while held: Round 4 review, 0.59.49)
  if require("trust").cached(closed_seen, k, root) == nil then
    local ok = groups.role(root, e.by) == "owner" and require("trust").from_owner_file(root, "_band/closed.json")
    if ok == nil then return false end
    require("trust").cache(closed_seen, k, ok == true, root)
    if not ok then band.log(string.format("%s: a closed.json not from the owner's computer was set aside", band.info(root).name)) end
  end
  return closed_seen[k] == true, e
end

-- Run from removal.tick, every 30 s or so: Syncthing lets go of what this computer left, a closed group is over here too, and a group
-- nobody's been seen in for a week gets a word (closed or removed while this computer was off: nothing can reach it to say so).
local said_quiet, backfilled = {}, {}
function groups.tick(now)
  local services = require("services")
  local leaving = band.ext_json(band.SECTION, "leaving")
  if type(leaving) == "table" and #leaving > 0 then
    local still = {}
    for _, l in ipairs(leaving) do
      if now - (tonumber(l.at) or 0) < groups.WAIT or not services.forget_folder(l.id) then still[#still + 1] = l end
    end
    local text = #still > 0 and band.json_encode(still) or ""
    if text ~= reaper.GetExtState(band.SECTION, "leaving") then reaper.SetExtState(band.SECTION, "leaving", text, true) end -- (written only when it changed: Round 2 review, 0.59.46)
  end
  local me = reaper.GetExtState(band.SECTION, "user")
  for _, g in ipairs(band.bands()) do
    -- (the owner's computer gives a studio from before 0.58.52 its SonoBus secret: only the owner, so two computers can't make two)
    if me ~= "" and groups.role(g.root, me) == "owner" and not groups.sonobus_secret(g.root) and not groups.is_old(g.root) then
      -- (said only when made: skipped while nothing is verified, it was said every removal tick. Round 4 review, 0.59.49)
      if groups.new_sonobus_secret(g.root) then
        band.log(g.name .. "'s live audio has a password of its own now (everyone's SonoBus picks it up the next time Real time mode connects)")
      end
    elseif me ~= "" and not backfilled[g.root] and not groups.is_old(g.root) and not reaper.file_exists(g.root .. "/_band/roles.json")
        and groups.role(g.root, me) == "owner" and not require("trust").held(g.root) then
      -- (a studio from before the roles file: the owner's computer writes it once (Round 2 review, 0.59.46). Once per studio and session, and a
      -- failure logged: a roles file that couldn't be written, or one someone deleted, rewrote band.json for everyone on every removal tick.
      -- Round 3 review, 0.59.48)
      local ok, made = band.try("groups roles file", save, g.root, function() end, nil, true)
      backfilled[g.root] = not (ok and made == false) -- (not made as nothing is verified yet: tried again)
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
      local ok_closed, e = groups.closed_ok(g.root)
      if ok_closed then
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
  local leaving = band.ext_json(band.SECTION, "leaving")
  for _, l in ipairs(type(leaving) == "table" and leaving or {}) do if l.id == id then return true end end
  return false
end
return groups
