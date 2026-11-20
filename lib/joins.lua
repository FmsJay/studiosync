-- Joining without Syncthing's device approval step (docs/realtime-roadmap.md "More big ideas" 6, James, rt). An invitation the owner or an
-- admin makes is a signed token (studiosync-invite:...): the joiner pastes it (Paste join code), and over Tailscale the direct link takes it to
-- the computer that made it, which checks it and lets the joiner's computer in at once: its Syncthing device added and the studio's folder
-- shared with it, with no "Let them in" on either side. The others in the studio meet it from the invitation's record (removal.admitted). A
-- welcome comes back over the link (who's in charge, the projects), and Syncthing brings the files.
-- Safe by default: an invitation runs out (2 days), lets one computer in, can be revoked (Settings > Studio > Direct link), and nothing without
-- one is ever added by it. Without the link (no extension, Tailscale or firewall rule, the studio's direct setting off), an invitation is
-- today's join code and Let them in.
local band = require("band")
local joins = {}

joins.PREFIX = "studiosync-invite:"
joins.LIFE = 2 * 86400 -- (as a Tailscale guest key: once, within 2 days)
joins.MAX_LIFE = 7 * 86400 -- (a record saying longer isn't believed: removal.INVITE_KEEPS)
joins.KEEP_USED = 7 * 86400 -- (a used record names the joiner for the others this long: removal.admitted)
joins.RESEND = 10 -- (the joiner asks again this often until it's in: the link may not be up the moment the code is pasted)
-- The asks travel on a channel of their own, under a public key: whoever asks has no secret of the studio's yet, and the signed token is what
-- lets them in. The welcome goes back keyed with the token's signature, which only the joiner and the computer that made it know.
joins.CHANNEL, joins.CHANNEL_SECRET = "studiosync-join", "StudioSync join v1"
local SIGNED = "StudioSync invite v1\n"

local function me() return reaper.GetExtState(band.SECTION, "user") end
local function record_path(root, id) return root .. "/_band/joins/" .. id .. ".json" end
local function inbox() return band.home() .. "/direct/join" end
local sent_at = {} -- root -> when this computer last asked to be let in there

-- ---- pure -------------------------------------------------------------------------------------------------------------------------------
-- What the signature covers: every field but the signature itself.
function joins.message(t)
  return SIGNED .. table.concat({ t.studio, t.id, t.role, tostring(t.ends), t.host, t.device, t.name }, "\n")
end
function joins.encode(t)
  return joins.PREFIX .. table.concat({ t.studio, t.id, t.role, tostring(t.ends), t.host, t.device, t.sig, t.name }, ":")
end
-- The token in a pasted message -> { studio, id, role, ends, host, device, sig, name }, or nil. Only a StudioSync studio's folder (as
-- services.parse_join), a plain Tailscale name, a Syncthing device id; the name last (band.clean keeps no ':').
function joins.parse(text)
  local s, id, role, ends, host, dev, sig, name = tostring(text or ""):match(
    "studiosync%-invite:([%w%-]+):(%x+):(%a+):(%d+):([%w%.%-]+):([%u%d%-]+):(%x+):([^\r\n]*)")
  if not s then return nil end
  s = s:lower()
  if not (s == "bandsync" or s:match("^bandsync%-") or s:match("^studiosync%-")) then return nil end
  if #id ~= 32 or #sig ~= 128 or #host > 253 or not (role == "member" or role == "guest") then return nil end
  if not require("services").is_device_id(dev) then return nil end
  return { studio = s, id = id:lower(), role = role, ends = tonumber(ends), host = host:lower(), device = dev, sig = sig:lower(),
    name = (name:gsub("[^%w%-_ ]", ""):match("^%s*(.-)%s*$")) }
end
-- Does this invitation let `device` in now? rec: its record in the studio (believed only from an owner's or admin's computer: the caller asks);
-- my_key: this computer's invitation key (only the computer that made one lets anyone in with it, so one use is one use); used: the device
-- this computer already let in with it; verify(sig, msg, key) -> true. -> true (and "again" when it's that same computer asking again: only the
-- welcome goes), or false + why.
function joins.check(tok, rec, now, my_key, used, device, verify)
  if type(tok) ~= "table" or type(rec) ~= "table" or rec.id ~= tok.id then return false, "no such invitation here (revoked, or never made here)" end
  if type(my_key) ~= "string" or rec.key ~= my_key then return false, "made on another computer" end
  if rec.studio ~= tok.studio or rec.role ~= tok.role or tonumber(rec.ends) ~= tok.ends then return false, "it doesn't match its record" end
  if not verify(tok.sig, joins.message(tok), my_key) then return false, "the signature doesn't check" end
  if not tonumber(now) or now >= tok.ends then return false, "it has run out" end
  if tok.ends - (tonumber(rec.made) or -math.huge) > joins.MAX_LIFE then return false, "it says it lasts longer than an invitation can" end
  local by = used or (type(rec.used) == "table" and rec.used.device) or nil
  if by and by ~= device then return false, "it has been used already" end
  return true, by and "again" or nil
end
-- A "join" ask checked: { token, device, name, reply }, or nil. reply: the joiner's Tailscale name, for the welcome (optional).
function joins.valid_request(d)
  if type(d) ~= "table" or type(d.token) ~= "string" or #d.token > 1024 then return nil end
  if not require("services").is_device_id(d.device) then return nil end
  local name = band.clean(tostring(d.name or "")):sub(1, 60)
  local reply = type(d.reply) == "string" and #d.reply <= 253 and d.reply:match("^[%w%-]+%.[%w%.%-]+$") and d.reply:lower() or nil
  return { token = d.token, device = d.device, name = name ~= "" and name or "a collaborator", reply = reply }
end

-- ---- this computer's key and what it can make -------------------------------------------------------------------------------------------
-- This computer's invitation key (Ed25519, extension 1.0.9's StudioSync_KeyCreate/Sign), beside the update key and as private: outside every
-- synced folder. Its own key, not the owner's update key: admins invite too, and signing code stays with the owner.
function joins.key_path()
  local home = os.getenv("USERPROFILE") or os.getenv("HOME")
  return home and home ~= "" and (band.norm(home) .. "/.studiosync/invite-key") or nil
end
local key_of = {} -- path -> public key
local function my_key()
  local p = joins.key_path()
  if not (p and reaper.StudioSync_KeyCreate) then return nil end
  if not key_of[p] then
    reaper.RecursiveCreateDirectory(p:match("^(.*)/[^/]+$"), 0)
    local k = tostring(reaper.StudioSync_KeyCreate(p) or ""):lower()
    key_of[p] = #k == 64 and k:match("^%x+$") and k or nil
  end
  return key_of[p], p
end
-- Can this computer make invitations for `root` now: someone who lets people in, the link able to hear the ask (the extension, the studio's
-- direct setting, its Tailscale network with this computer on it, the firewall rule on Windows)? -> its Tailscale name and device id, or nil.
function joins.can_make(root)
  if not (reaper.StudioSync_Sign and reaper.StudioSync_Verify and reaper.StudioSync_DirectMsgPoll) then return nil end
  local direct, groups, services = require("direct"), require("groups"), require("services")
  if not (direct.available() and direct.live_available() and direct.enabled(root)) or not groups.may_manage(root, me()) then return nil end
  local t, host = groups.tailnet(root), services.my_tailscale_name()
  host = host and host:gsub("%.$", ""):lower()
  if not (t and host and host:sub(-#t.suffix - 1) == "." .. t.suffix:lower()) or not direct.firewall_ok() then return nil end
  local dev = services.my_device_id()
  return dev and host or nil, dev
end
-- Invitations this computer made and nobody has used yet: ExtState "joins open" { [id] = { root, ends } }, kept. -> them, pruned.
local function open_invites(now)
  local open, out, changed = band.ext_json(band.SECTION, "joins open") or {}, {}, false
  for id, v in pairs(open) do
    if type(v) == "table" and tonumber(v.ends) and v.ends > now and reaper.GetExtState(band.SECTION, "join used " .. id) == "" then out[id] = v
    else changed = true end
  end
  if changed then band.set_ext_json(band.SECTION, "joins open", out, true) end
  return out
end
-- A new invitation to `root` for a "member" or "guest": its record written in the studio (read by the computer it's let in on, and by the others
-- once it's used), the token handed back. -> the token's text and fields, or nil (this computer can't make one: the plain join code then).
function joins.make(root, role, now)
  now = now or os.time()
  -- (a studio just started has no Tailscale network yet, and every invitation to it was the plain join code: the inviter's, as a guest
  -- invitation sets it. LinuxBox join test, rt)
  local groups = require("groups")
  if not groups.tailnet(root) and groups.may_manage(root, me()) then pcall(groups.set_tailnet, root) end
  local host, dev = joins.can_make(root)
  local key, kp = my_key()
  if not (host and key) then return nil end
  local info = band.info(root)
  local t = { studio = info.id, id = band.secret(32), role = role == "guest" and "guest" or "member", ends = now + joins.LIFE, host = host,
    device = dev, name = band.clean(tostring(info.name)) }
  local sig = tostring(reaper.StudioSync_Sign(kp, joins.message(t)) or ""):lower()
  if #sig ~= 128 then return nil end
  t.sig = sig
  reaper.RecursiveCreateDirectory(root .. "/_band/joins", 0)
  band.write_json(record_path(root, t.id), { id = t.id, studio = t.studio, role = t.role, made = now, ends = t.ends, by = me(), dev = dev, key = key })
  local open = open_invites(now)
  open[t.id] = { root = root, ends = t.ends }
  band.set_ext_json(band.SECTION, "joins open", open, true)
  return joins.encode(t), t
end
-- The same, from a studio's band.info (the invitation window has that, not the folder). -> the token, or nil.
function joins.make_for(info, role)
  for _, x in ipairs(band.bands()) do
    if x.id == (info or {}).id and not x.waiting then return (joins.make(x.root, role)) end
  end
end

-- ---- the computer that made it: an ask comes in ----------------------------------------------------------------------------------------
-- The welcome: who's in charge and the projects they'll see, never the studio's secrets (those come with Syncthing's band.json, which the
-- trust checks cover). Keyed with the token's signature, to the joiner's Tailscale name on the studio's network only.
function joins.welcome(root, tok, r, now)
  local t = require("groups").tailnet(root)
  if not (r.reply and t and r.reply:sub(-#t.suffix - 1) == "." .. t.suffix:lower()) then return false end
  local k = "join welcomed " .. tok.id
  if now - (tonumber(reaper.GetExtState(band.SECTION, k)) or -math.huge) < 5 then return false end -- (two scripts reading the same ask)
  reaper.SetExtState(band.SECTION, k, tostring(now), false)
  local access = require("access")
  local shown, songs = access.read(root, r.device), {}
  for _, s in ipairs(band.subdirs(root)) do
    if #songs < 200 and reaper.file_exists(root .. "/" .. s .. "/session.json") and access.shows(shown, s) then songs[#songs + 1] = s end
  end
  local j = band.read_json(root .. "/_band/band.json") or {}
  local data = band.json_encode({ studio = tok.studio, id = tok.id, name = band.info(root).name, owner = j.owner, admins = j.admins, role = tok.role, songs = songs })
  reaper.StudioSync_DirectStart("join-" .. tok.id, tok.sig, inbox(), -1)
  return reaper.StudioSync_DirectMsg("join-" .. tok.id, "welcome", data, r.reply .. ":" .. require("direct").port()) == 1
end
-- A refused ask, said in the log: once per reason and asking computer every REFUSED_EVERY s (the joiner asks again every RESEND s), and never
-- closer than REFUSED_GAP s apart (a forged ask can name any device id). Only the asker's short device id and name: never the token, its
-- signature or a key. A revoked or forged ask was refused with nothing said (VM test, rt). -> true when said.
joins.REFUSED_EVERY, joins.REFUSED_GAP = 600, 10
local refused_at, refused_n, refused_last = {}, 0, -math.huge
function joins.say_refused(r, why, now)
  local dev = type(r) == "table" and type(r.device) == "string" and r.device:sub(1, 7) or "unknown"
  local k = tostring(why) .. "\0" .. dev
  if now - (refused_at[k] or -math.huge) < joins.REFUSED_EVERY or now - refused_last < joins.REFUSED_GAP then return false end
  if refused_n > 500 then refused_at, refused_n = {}, 0 end -- shortcut: forgotten wholesale past 500; REFUSED_GAP still paces the log
  refused_at[k], refused_n, refused_last = now, refused_n + 1, now
  local name = type(r) == "table" and type(r.name) == "string" and r.name or "someone"
  band.log(string.format("an invitation ask from %s (computer %s) was refused: %s", name, dev, tostring(why)))
  return true
end
local ask
-- A "join" ask, checked and, when it holds, the joiner let in: its device added, the folder shared (tools.let_in: the roles written out again
-- from here, a guest's mark, a restore point), the record rewritten naming it, the welcome sent. -> true (and "again"), or false + why (said
-- in the log: joins.say_refused).
function joins.on_request(d, now)
  now = now or os.time()
  local r = joins.valid_request(d)
  local ok, why = ask(r, now)
  if not ok then joins.say_refused(r, why, now) end
  return ok, why
end
function ask(r, now)
  local tok = r and joins.parse(r.token)
  if not tok then return false, "not an invitation" end
  local root
  for _, x in ipairs(band.bands()) do if x.id == tok.studio and not x.waiting then root = x.root end end
  local groups = require("groups")
  if not root or groups.is_old(root) then return false, "not a studio here" end
  if not groups.may_manage(root, me()) then return false, "only the owner or an admin lets people in" end
  local rec = band.read_json(record_path(root, tok.id))
  if type(rec) ~= "table" then return false, "no such invitation here (revoked, or never made here)" end
  -- (a record anyone in the studio could have written: only one from an owner's or admin's computer, as Syncthing says, lets anyone in)
  local okt, trusted = pcall(require("trust").from_manager_file, root, "_band/joins/" .. tok.id .. ".json")
  if not (okt and trusted == true) then return false, "its record isn't one an owner or admin wrote" end
  local used = reaper.GetExtState(band.SECTION, "join used " .. tok.id)
  local ok, why = joins.check(tok, rec, now, my_key(), used ~= "" and used or nil, r.device,
    function(sig, msg, key) return reaper.StudioSync_Verify(sig, msg, key) == 1 end)
  if not ok then return false, why end
  if why ~= "again" then
    -- (taken out after the invitation was made: not back in with it)
    local out = require("removal").out_since(root, r.device, rec.made)
    if out then return false, "taken out since the invitation was made" end
    require("services").add_device(r.device, r.name) -- (known here already: it says so, and the sharing below still goes)
    local lok, lwhy = require("tools").let_in({ id = r.device, name = r.name, folder = tok.studio, band = band.info(root).name, root = root }, me(),
      tok.role == "guest" and tok.ends or nil)
    if not lok then return false, tostring(lwhy) end -- (not marked used: their next ask, 10 s on, tries again)
    reaper.SetExtState(band.SECTION, "join used " .. tok.id, r.device, true)
    rec.used = { device = r.device, name = r.name, at = now }
    band.write_json(record_path(root, tok.id), rec)
    band.log(string.format("%s's computer (%s) came in with an invitation: no Let them in needed", r.name, r.device:sub(1, 7)))
  end
  joins.welcome(root, tok, r, now)
  return true, why
end

-- ---- the joiner -------------------------------------------------------------------------------------------------------------------------
-- The ask, to the computer the token names. -> true when queued.
function joins.send(tok)
  local services, direct = require("services"), require("direct")
  local dev = services.my_device_id()
  if not (dev and reaper.StudioSync_DirectStart and reaper.StudioSync_DirectMsg) then return false end
  reaper.StudioSync_DirectStart(joins.CHANNEL, joins.CHANNEL_SECRET, inbox(), -1)
  -- (listening for the welcome where it can: on Windows only with the firewall rule; without it the welcome is missed and Syncthing says so)
  reaper.StudioSync_DirectStart("join-" .. tok.id, tok.sig, inbox(), direct.firewall_ok() and direct.port() or -1)
  local reply = services.my_tailscale_name()
  local data = band.json_encode({ token = joins.encode(tok), device = dev, name = me(), reply = reply and reply:gsub("%.$", "") or nil })
  return reaper.StudioSync_DirectMsg(joins.CHANNEL, "join", data, tok.host .. ":" .. direct.port()) == 1
end
-- Joined `root` (services.join_band) with an invitation: asked now, and again every RESEND s from joins.tick until it's in. -> true when asked.
-- (the token is kept in this computer's own settings until then: it's this computer's to use)
function joins.request(root, tok)
  local pending = band.ext_json(band.SECTION, "joins pending") or {}
  pending[root] = { token = joins.encode(tok) }
  band.set_ext_json(band.SECTION, "joins pending", pending, true)
  sent_at[root] = reaper.time_precise()
  return joins.send(tok)
end
function joins.on_welcome(id, d)
  local pending = band.ext_json(band.SECTION, "joins pending") or {}
  for root, p in pairs(pending) do
    local tok = type(p) == "table" and joins.parse(p.token)
    if tok and tok.id == id and type(d) == "table" and d.studio == tok.studio and d.id == id then
      pending[root] = nil
      band.set_ext_json(band.SECTION, "joins pending", pending, true)
      local n = type(d.songs) == "table" and #d.songs or 0
      band.set_ext_json(band.SECTION, "join welcome " .. band.norm(root):lower(), { n = n, owner = type(d.owner) == "string" and d.owner or nil }, false)
      band.log(string.format("you're in %s: let in by the invitation; %d project%s on the way through Syncthing", tok.name, n, n == 1 and "" or "s"))
      return true
    end
  end
  return false
end
-- For the Studios page while a joined studio waits: "in" (welcomed), "asking" (an invitation out), or nil (today's Let them in).
function joins.state(root)
  if band.ext_json(band.SECTION, "join welcome " .. band.norm(root):lower()) then return "in" end
  local p = (band.ext_json(band.SECTION, "joins pending") or {})[root]
  return p and "asking" or nil
end

-- ---- each tick (Autostart every 2 s, the panel's frame: at most once a second) ------------------------------------------------------------
local last_seq, tick_at, channel_on, tidy_at = 0, -math.huge, false, -math.huge
function joins.tick(now)
  band.try("invite.tick", require("invite").tick, now) -- (a studiosync:// link clicked, an invite link's answer awaited: lib/invite.lua, rt-invite)
  if not (reaper.StudioSync_DirectMsgPoll and reaper.StudioSync_DirectStart) then return end
  local t = reaper.time_precise()
  if t - tick_at < 1 and t >= tick_at then return end
  tick_at, now = t, now or os.time()
  local direct = require("direct")
  local open, pending = open_invites(now), band.ext_json(band.SECTION, "joins pending") or {}
  -- (the ask channel only while there's something to hear or say on it: a public key, so no longer than that)
  if next(open) then reaper.StudioSync_DirectStart(joins.CHANNEL, joins.CHANNEL_SECRET, inbox(), direct.firewall_ok() and direct.port() or -1)
  elseif next(pending) then reaper.StudioSync_DirectStart(joins.CHANNEL, joins.CHANNEL_SECRET, inbox(), -1)
  elseif channel_on then reaper.StudioSync_DirectStop(joins.CHANNEL) end
  channel_on = next(open) ~= nil or next(pending) ~= nil
  for _ = 1, 50 do
    local seq, studio, kind, data = direct.parse_msg(reaper.StudioSync_DirectMsgPoll(last_seq))
    if not seq then break end
    last_seq = seq
    if studio == joins.CHANNEL and kind == "join" and next(open) then band.try("joins.on_request", joins.on_request, band.json_decode(data or ""), now)
    elseif studio == joins.CHANNEL and kind == "join" then -- (none open here: revoked, run out or used, while the channel was still up)
      joins.say_refused(joins.valid_request(band.json_decode(data or "")), "no invitation is open on this computer (revoked, run out or used)", now)
    elseif studio == joins.CHANNEL and kind == "redeem" then band.try("invite.on_redeem", require("invite").on_redeem, band.json_decode(data or ""), now) -- (an invite link's code: lib/invite.lua)
    elseif kind == "token" and studio:match("^joinlink%-%x+$") then band.try("invite.on_token", require("invite").on_token, studio:sub(10), band.json_decode(data or ""), now)
    elseif kind == "welcome" and studio:match("^join%-%x+$") then band.try("joins.on_welcome", joins.on_welcome, studio:sub(6), band.json_decode(data or "")) end
  end
  local changed = false
  for root, p in pairs(pending) do
    local tok = type(p) == "table" and joins.parse(p.token)
    local waiting = not reaper.file_exists(root .. "/_band/band.json")
    if not tok or now >= tok.ends or not waiting then
      pending[root], changed = nil, true
      if tok and waiting then band.log("the invitation to " .. tok.name .. " ran out before it reached their computer: ask them to let you in from their panel") end
    elseif t - (sent_at[root] or -math.huge) >= joins.RESEND then
      sent_at[root] = t
      joins.send(tok)
    end
  end
  if changed then band.set_ext_json(band.SECTION, "joins pending", pending, true) end
  if t - tidy_at > 3600 then tidy_at = t; band.try("joins.tidy", joins.tidy, now) end
end
-- This computer's own records, once nobody needs them (run out, and a used one's KEEP_USED over).
function joins.tidy(now)
  -- (only where there's a key: my_key makes one, and every computer running Autostart got a private key and ~/.studiosync it never used.
  -- LinuxBox join test, rt)
  local p = joins.key_path()
  if not (p and reaper.file_exists(p)) then return end
  local key = my_key()
  for _, x in ipairs(key and band.bands() or {}) do
    for _, f in ipairs(band.files(x.root .. "/_band/joins", ".json")) do
      local rec = band.read_json(x.root .. "/_band/joins/" .. f)
      if type(rec) == "table" and rec.key == key and tonumber(rec.ends) and now > rec.ends + joins.KEEP_USED then band.remove(x.root .. "/_band/joins/" .. f) end
    end
  end
end

-- ---- the others in the studio, and Settings ----------------------------------------------------------------------------------------------
-- Was `id` let in with an invitation lately, by an owner's or admin's computer (its record rewritten there, naming it)? -> their name, or nil.
-- (removal.admitted: the others add it without a click when it asks, before its own devices file has reached them)
function joins.admitted(root, id, now)
  now = now or os.time()
  for _, f in ipairs(band.files(root .. "/_band/joins", ".json")) do
    local rec = band.read_json(root .. "/_band/joins/" .. f)
    local u = type(rec) == "table" and type(rec.used) == "table" and rec.used
    if u and u.device == id and tonumber(u.at) and now - u.at < joins.KEEP_USED and now >= u.at - 300 then
      local okt, trusted = pcall(require("trust").from_manager_file, root, "_band/joins/" .. f)
      if okt and trusted == true then return band.clean(tostring(u.name or "")) ~= "" and band.clean(tostring(u.name)) or "a collaborator" end
    end
  end
end
-- Revoked: its record goes, so the computer that made it finds none and refuses it. Owner and admins (Settings).
function joins.revoke(root, id)
  if not tostring(id):match("^%x+$") then return end
  band.remove(record_path(root, id))
  -- (and out of this computer's open ones: kept there, the public ask channel stayed open up to 2 days for nothing. LinuxBox join test, rt)
  local open = band.ext_json(band.SECTION, "joins open") or {}
  if open[id] then open[id] = nil; band.set_ext_json(band.SECTION, "joins open", open, true) end
end
-- Open invitations and those used lately, for Settings: { { id, role, by, ends, used } }, read at most every 5 s. (Shown as written: whether
-- one lets anyone in is decided where it's used, from its record as Syncthing says who wrote it.)
local list_at, list_of = {}, {}
function joins.list(root, now)
  if list_at[root] and reaper.time_precise() - list_at[root] < 5 then return list_of[root] end
  local out = {}
  for _, f in ipairs(band.files(root .. "/_band/joins", ".json")) do
    local rec = band.read_json(root .. "/_band/joins/" .. f)
    if type(rec) == "table" and type(rec.id) == "string" and tonumber(rec.ends) then
      local u = type(rec.used) == "table" and rec.used or nil
      if (not u and rec.ends > now) or (u and tonumber(u.at) and now - u.at < joins.KEEP_USED) then
        out[#out + 1] = { id = rec.id, role = tostring(rec.role), by = tostring(rec.by or "someone"), ends = rec.ends, used = u }
      end
    end
  end
  table.sort(out, function(a, b) return a.ends > b.ends end)
  list_at[root], list_of[root] = reaper.time_precise(), out
  return out
end
function joins.studio_ui(ctx, ImGui, cfg, may)
  ImGui.SeparatorText(ctx, "Invitations")
  ImGui.PushTextWrapPos(ctx, 0)
  ImGui.TextDisabled(ctx, "Invite a collaborator puts a signed invitation in the message when the link can hear it: pasted within 2 days, it lets " ..
    "one computer in by itself over Tailscale, without Let them in. Revoke one to stop it working.")
  ImGui.PopTextWrapPos(ctx)
  local now = os.time()
  local list = joins.list(cfg.root, now)
  if #list == 0 then ImGui.TextDisabled(ctx, "None open.") end
  for _, r in ipairs(list) do
    if r.used then
      ImGui.TextDisabled(ctx, string.format("%s's, for a %s: used by %s", r.by, r.role, band.clean(tostring(r.used.name or "")) ~= "" and band.clean(tostring(r.used.name)) or "a collaborator"))
    else
      ImGui.Text(ctx, string.format("%s's, for a %s: open until %s", r.by, r.role, require("removal").when(r.ends, now)))
      if may then
        ImGui.SameLine(ctx)
        if ImGui.SmallButton(ctx, "Revoke##join" .. r.id) then
          joins.revoke(cfg.root, r.id)
          list_at[cfg.root] = nil
          band.log("an invitation to " .. band.info(cfg.root).name .. " was revoked: it lets nobody in now")
        end
      end
    end
  end
  require("invite").studio_ui(ctx, ImGui, cfg, may) -- (invite links and this computer's studiosync:// handler: lib/invite.lua, rt-invite)
end

return joins
