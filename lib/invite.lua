-- Asking someone to join a project (James, rt: "Ask someone to join a project while they're inside or outside REAPER, one click to open and
-- join, or an invite link that opens their REAPER to the project and StudioSync").
--  1. Ask to join (a studio member): a direct message from you to them (lib/page_chat.lua: over the direct link to their computer at once,
--     the shared folder behind it) carrying `join = { song, room }`. On their side it shows in the chat with Join and Decline, on the web UI's
--     Home and in the panel (invite.pending), and as a line on the studio's phone alerts (lib/alerts.lua). Join opens that project and room
--     here the Home page's way (webhome.open: its tab, or Open session in a new tab, which starts Live sync). Asks are rate-limited.
--  2. Links: studiosync://join?s=<studio>&p=<project>&r=<room> for a member (names only, nothing secret), and for someone not in the studio
--     yet studiosync://join?s=<studio>&n=<name>&h=<inviter's Tailscale name>&c=<code>: a short-lived (CODE_LIFE), single-use code that this
--     computer exchanges, over the studio's Tailscale network, for a signed invitation (lib/joins.lua) made when the link was. Everything after
--     that is the pasted invitation's path: its record, the owner's or admin's signature, one computer, the refused-asks log. The link carries no
--     invitation, key or token. The same query on http://127.0.0.1:<port>/join.html (the web UI's own page) is the fallback without a handler.
--     lib/urlhandler.lua puts the handler in, only when the person ticks it in Settings.
-- GPL-3.0-or-later.
local band = require("band")
local invite = {}
invite.LINK_MAX = 600          -- bytes of a link read at all
invite.CODE_LEN = 24           -- hex characters of a code (96 bits)
invite.CODE_LIFE = 86400       -- seconds a code works (never past its invitation's own end)
invite.ASK_LIFE = 1800         -- seconds a join request can be answered
invite.ASK_GAP = 60            -- seconds between two asks to the same person
invite.ASK_MAX, invite.ASK_WINDOW = 10, 3600 -- asks from this computer per window
invite.REDEEM_FOR, invite.RESEND = 120, 10   -- the joiner asks for its invitation this long, this often
invite.FAIL_MAX, invite.FAIL_WINDOW = 30, 600 -- refused code asks before this computer stops listening to them for a window
invite.LINK_EVERY = 2          -- seconds between two links handled (a page or a launcher repeating one)
invite.QUEUE_MAX = 20          -- links clicked and waiting to be read (the launcher's files, oldest first); more are dropped
local SECRET = "StudioSync join link v1\n" -- (the reply channel's key: this plus the code, which only the two computers know)

local function me() return reaper.GetExtState(band.SECTION, "user") end
local pending_at, pending_v = -math.huge, {} -- (invite.pending's 5 s copy)
local function now_iso(t) return os.date("!%Y-%m-%dT%H:%M:%SZ", t) end
local function inbox() return band.home() .. "/direct/join" end

-- ---- pure: links ---------------------------------------------------------------------------------------------------------------------
function invite.pct(s) -- (not %w: on Windows it matches some bytes past ASCII)
  return (tostring(s):gsub("[^A-Za-z0-9%-%._~]", function(c) return string.format("%%%02X", c:byte()) end))
end
-- %XX decoded; nil when a % isn't followed by two hex digits. ("+" stays "+": links are built with %20.)
function invite.pct_decode(s)
  if s:find("%%%X") or s:find("%%%x%X") or s:find("%%$") or s:find("%%%x$") then return nil end
  return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end
local function plain(s) return require("direct").plain(s) end
local function studio_ok(s)
  s = type(s) == "string" and #s <= 80 and s:lower() or nil
  return s and s:match("^[%w%-]+$") and (s == "bandsync" or s:match("^bandsync%-") or s:match("^studiosync%-")) and s or nil
end
-- A link -> { kind = "member", studio, song, room } or { kind = "code", studio, name, host, code }, or nil + why. Takes studiosync://join?...,
-- studiosync:join?... and studiosync://join/?... (what some systems hand over), and the web UI's http://127.0.0.1:<port>/join.html?...
-- Strict: every key known, each once, nothing hidden (control characters, bytes past ASCII), each value to its own rule. Pure.
local KEYS = { s = true, p = true, r = true, n = true, h = true, c = true }
function invite.parse_link(text)
  if type(text) ~= "string" then return nil, "not a link" end
  if #text > invite.LINK_MAX then return nil, "too long" end
  text = text:match("^%s*(.-)%s*$")
  if text:find("[^\33-\126]") then return nil, "it holds characters a link can't" end
  local q = text:match("^[Ss][Tt][Uu][Dd][Ii][Oo][Ss][Yy][Nn][Cc]:/?/?[Jj][Oo][Ii][Nn]/?%?(.*)$")
    or text:match("^http://127%.0%.0%.1:%d+/join%.html%?(.*)$") or text:match("^http://localhost:%d+/join%.html%?(.*)$")
  if not q then return nil, "not a StudioSync join link" end
  q = q:gsub("#.*$", "")
  local v = {}
  for part in (q .. "&"):gmatch("([^&]*)&") do
    if part ~= "" then
      local k, x = part:match("^(%a)=(.*)$")
      if not k or not KEYS[k] then return nil, "it holds something a join link doesn't" end
      if v[k] then return nil, "it says " .. k .. " twice" end
      x = invite.pct_decode(x)
      if not x or x:find("%c") or x:find("[\128-\255]") and not utf8.len(x) then return nil, "a part of it doesn't read" end
      v[k] = x
    end
  end
  local studio = studio_ok(v.s)
  if not studio then return nil, "it doesn't name a studio" end
  if v.c or v.h then
    if v.p or v.r then return nil, "it mixes a project with an invitation" end
    local code, host = v.c and v.c:lower(), v.h and v.h:lower()
    if not (code and #code == invite.CODE_LEN and code:match("^%x+$")) then return nil, "its code isn't one" end
    if not (host and #host <= 253 and host:match("^[%w%-]+%.[%w%.%-]+$") and not host:find("%.%.")) then return nil, "it doesn't name a computer" end
    local name = band.clean(tostring(v.n or "")):sub(1, 60)
    return { kind = "code", studio = studio, code = code, host = host, name = name ~= "" and name or studio }
  end
  if v.n then return nil, "it holds something a join link doesn't" end
  if not plain(v.p) then return nil, "it doesn't name a project" end
  local room = v.r or "main"
  if not plain(room) then return nil, "it doesn't name a room" end
  return { kind = "member", studio = studio, song = v.p, room = room }
end
function invite.member_link(studio, song, room)
  return "studiosync://join?s=" .. invite.pct(studio) .. "&p=" .. invite.pct(song) .. ((room and room ~= "main") and ("&r=" .. invite.pct(room)) or "")
end
function invite.code_link(studio, name, host, code)
  return "studiosync://join?s=" .. invite.pct(studio) .. "&n=" .. invite.pct(name) .. "&h=" .. invite.pct(host) .. "&c=" .. code
end
function invite.web_link(link, port) return "http://127.0.0.1:" .. math.floor(tonumber(port) or 47281) .. "/join.html?" .. (link:match("%?(.*)$") or "") end

-- ---- pure: asks ----------------------------------------------------------------------------------------------------------------------
-- A message's `join` (another computer's file) -> { song, room }, or nil. Pure.
function invite.join_ok(j)
  if type(j) ~= "table" or not plain(j.song) then return nil end
  local room = j.room == nil and "main" or j.room
  if not plain(room) then return nil end
  return { song = j.song, room = room }
end
-- May this computer ask `to` now? list: { { to, at } } (its asks lately). -> true, or false + why. Pure.
function invite.rate_ok(list, to, now)
  local n = 0
  for _, a in ipairs(type(list) == "table" and list or {}) do
    if type(a) == "table" and tonumber(a.at) and now - a.at < invite.ASK_WINDOW then
      n = n + 1
      if a.to == to and now - a.at < invite.ASK_GAP then return false, "you asked " .. to .. " a moment ago: give them a minute" end
    end
  end
  if n >= invite.ASK_MAX then return false, "that's " .. n .. " asks this hour: wait a while before asking again" end
  return true
end
-- Is a code's record good for `device` now? -> true (and "again" for the computer that used it already), or false + why. Pure.
function invite.code_check(rec, device, now)
  if type(rec) ~= "table" or type(rec.token) ~= "string" then return false, "no such link here (used, run out, revoked or never made here)" end
  if not tonumber(rec.ends) or now >= rec.ends then return false, "the link has run out" end
  if rec.used_by and rec.used_by ~= device then return false, "the link has been used already" end
  return true, rec.used_by and "again" or nil
end

-- ---- asking a bandmate ---------------------------------------------------------------------------------------------------------------
-- Is `song` (and `room`) one of this studio's, as this computer sees it (a guest's own list)?
function invite.known(cfg, song, room)
  local ok = false
  for _, s in ipairs(band.songs(cfg)) do ok = ok or s == song end
  if not ok then return false end
  if room == "main" then return true end
  for _, r in ipairs(band.subdirs(band.song_dir(cfg, song) .. "/rooms")) do if r == room then return true end end
  return false
end
local function asks_list() return band.ext_json(band.SECTION, "invite asks") or {} end
-- Ask `to` to join song/room. -> true + words, or nil + why.
function invite.ask(cfg, b, to, song, room, now)
  now = now or os.time()
  local chat = require("page_chat")
  local j = invite.join_ok({ song = song, room = room })
  if type(to) ~= "string" or to == cfg.user or not chat.has(chat.people(cfg), to) then return nil, "only someone in the studio can be asked to join" end
  if not j or not invite.known(cfg, j.song, j.room) then return nil, "no such project or room here" end
  local list = asks_list()
  local ok, why = invite.rate_ok(list, to, now)
  if not ok then return nil, why end
  local id, dwhy = chat.dm_open(cfg, { to })
  if not id then return nil, dwhy end
  local where = j.song .. (j.room ~= "main" and (" (room " .. j.room .. ")") or "")
  chat.post(cfg, b or {}, "asks you to join " .. where, "dm:" .. id, { join = j })
  local keep = {}
  for _, a in ipairs(list) do if type(a) == "table" and tonumber(a.at) and now - a.at < invite.ASK_WINDOW then keep[#keep + 1] = a end end
  keep[#keep + 1] = { to = to, at = now }
  band.set_ext_json(band.SECTION, "invite asks", keep, false) -- (shared by Live sync and the panel, not kept past REAPER)
  pcall(require("alerts").send, cfg, "join", "StudioSync: " .. j.song, cfg.user .. " asks " .. to .. " to join") -- (names only: the alert channel is the studio's)
  pending_at = -math.huge
  return true, "asked " .. to .. " to join " .. where
end
-- Answered here (so Join and Decline go): ExtState "invite answered" { [message id] = when }, kept a day.
local function answered() return band.ext_json(band.SECTION, "invite answered") or {} end
function invite.answered(id) return answered()[id] ~= nil end
local function mark_answered(id, now)
  local a, out = answered(), {}
  for k, t in pairs(a) do if tonumber(t) and now - t < 86400 then out[k] = t end end
  out[id] = now
  band.set_ext_json(band.SECTION, "invite answered", out, true)
end
-- Open song/room here: its tab, or Open session in a new tab (Live sync starts there). -> words for the log.
function invite.open_here(cfg, song, room)
  return require("webhome").open(cfg, { song = song, room = room })
end
-- Answer the join request `id` in the DM `sc` (go: Join, else Decline). -> words for the log.
function invite.answer(cfg, b, sc, id, go, now)
  now = now or os.time()
  local chat = require("page_chat")
  if chat.conv_of(sc) ~= "dm" then return "a join request is answered in its direct message only" end
  local m = chat.find(cfg, b or {}, sc, "msgs", id)
  local j = m and invite.join_ok(m.join)
  if not j or m.user == cfg.user then return "no such join request for you" end
  if invite.answered(id) then return "that join request was answered already" end
  if type(m.time) ~= "string" or m.time < now_iso(now - invite.ASK_LIFE) or m.time > now_iso(now + 300) then
    return m.user .. "'s join request has run out: ask them to send it again"
  end
  mark_answered(id, now)
  pending_at = -math.huge
  chat.post(cfg, b or {}, go and ("is joining " .. j.song) or "can't join right now", sc, { join_answer = { id = id, go = go == true } })
  if not go then return "declined " .. m.user .. "'s request to join " .. j.song end
  return invite.open_here(cfg, j.song, j.room)
end
-- Join requests waiting for you: { { scope, id, user, song, room, time } }, newest per person, newest first. Read from your DMs' newest files
-- (only names stamped within ASK_LIFE are opened), kept 5 s.
function invite.pending(cfg, now)
  now = now or os.time()
  if reaper.time_precise() - pending_at < 5 then return pending_v end
  local chat, from, by = require("page_chat"), os.date("!%Y%m%d-%H%M%S", now - invite.ASK_LIFE), {}
  local done = answered()
  for _, d in ipairs(chat.dms(cfg)) do
    local dir = cfg.root .. "/_band/dm/" .. d.id .. "/msgs"
    for _, f in ipairs(band.files(dir, ".json")) do
      local id = f:sub(1, -6)
      if id:sub(1, 15) >= from and id:match("^%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-") and not done[id] then
        local v = band.read_json(dir .. "/" .. f)
        local j = type(v) == "table" and invite.join_ok(v.join)
        if j and type(v.user) == "string" and v.user ~= cfg.user and chat.has(d.members, v.user) and type(v.time) == "string"
          and v.time >= now_iso(now - invite.ASK_LIFE) and (not by[v.user] or by[v.user].time < v.time) then
          by[v.user] = { scope = "dm:" .. d.id, id = id, user = v.user, song = j.song, room = j.room, time = v.time }
        end
      end
    end
  end
  local out = {}
  for _, x in pairs(by) do out[#out + 1] = x end
  table.sort(out, function(a, z) return a.time > z.time end)
  pending_at, pending_v = reaper.time_precise(), out
  return out
end
-- A chat message's join part for the pages (lib/webui.lua chat_model): { song, room, mine, answered, expired }, or nil.
function invite.chat_model(m)
  local j = type(m) == "table" and invite.join_ok(m.join)
  if not j then return nil end
  local id = type(m.file) == "string" and m.file:match("([^/\\]+)%.json$") or ""
  local old = type(m.time) ~= "string" or m.time < now_iso(os.time() - invite.ASK_LIFE)
  return { song = j.song, room = j.room, mine = m.user == me() or nil, answered = invite.answered(id) or nil, expired = old or nil }
end

-- ---- links: this computer's end ------------------------------------------------------------------------------------------------------
function invite.pending_path() return band.home() .. "/link/pending.txt" end
-- The launcher's files (lib/urlhandler.lua): each click its own pending-<time>-<n>.txt, so a second click before StudioSync reads the first
-- no longer replaces it (rt-p10); pending.txt is an older launcher's. The oldest is read once and gone at once; past QUEUE_MAX waiting, the
-- newest go. -> its text, or nil.
function invite.take_pending()
  local dir, q = band.home() .. "/link", {}
  if reaper.file_exists(invite.pending_path()) then q[1] = "pending.txt" end
  local queued = {}
  for _, f in ipairs(band.files(dir, ".txt")) do if f:match("^pending%-%d+%-%d+%.txt$") then queued[#queued + 1] = f end end
  -- shortcut: ordered by name (the second it was clicked, then a random number): two clicks in one second may swap
  table.sort(queued, function(a, z) local ta, tz = tonumber(a:match("^pending%-(%d+)")), tonumber(z:match("^pending%-(%d+)")); if ta ~= tz then return ta < tz end return a < z end)
  for _, f in ipairs(queued) do if #q < invite.QUEUE_MAX then q[#q + 1] = f else os.remove(dir .. "/" .. f) end end
  if #q == 0 then return nil end
  local p = dir .. "/" .. q[1]
  local n = band.size(p)
  local s = n and n <= invite.LINK_MAX * 4 and band.read(p) or ""
  os.remove(p)
  return s
end
local function member_root(studio)
  -- (not one this computer left or was taken out of: its copy stays, but a code link for it joins again. rt-fix7)
  local groups = require("groups")
  for _, x in ipairs(band.bands()) do if x.id == studio and not x.waiting and not groups.is_old(x.root) then return x.root end end
end
invite.confirm = function(text) return reaper.MB(text, "StudioSync", 4) == 6 end -- (tests stand in)
invite.say = function(text) band.msg(text) end
local link_at = -math.huge
-- A link clicked or pasted. -> true + words, or false + why (said in the log, and in a box when someone clicked it).
function invite.handle_link(text, now)
  now = now or os.time()
  local t0 = reaper.time_precise()
  if t0 - link_at < invite.LINK_EVERY then return false, "a link a moment ago: this one waits" end
  link_at = t0
  local t, why = invite.parse_link(text)
  if not t then band.log("a StudioSync link was refused: " .. why); return false, why end
  local root = member_root(t.studio)
  if t.kind == "member" then
    if not root then
      invite.say("That link is for a studio this computer isn't in. Ask whoever sent it for an invitation.")
      return false, "not a studio here"
    end
    if reaper.GetExtState(band.SECTION, "sync_root") ~= root then band.use_band(root) end
    local cfg = band.settings()
    if not cfg then return false, "StudioSync isn't set up here" end
    local said = invite.open_here(cfg, t.song, t.room)
    band.log(tostring(said) .. " (a link)")
    return true, said
  end
  if root then invite.say("You're already in " .. band.info(root).name .. "."); return false, "already in it" end
  -- (a code link only works on the inviter's Tailscale network: off it (no Tailscale, or another network), say so now, before the Yes box,
  -- not after two minutes of asking. rt-p10)
  local mine = tostring(require("services").my_tailscale_name() or ""):gsub("%.$", ""):lower()
  local function net(h) return h:match("^[^.]+%.(.+)$") end
  if not net(mine) or net(mine) ~= net(t.host) then
    invite.say("This link only works on " .. t.host .. "'s Tailscale network, and this computer isn't on it. Ask them for the invitation message " ..
      "(Invite a collaborator) and paste it with Paste join code: when their studio has a Tailscale key set up, it brings this computer onto their network too.")
    return false, "not on their Tailscale network"
  end
  if not invite.confirm("Join the studio '" .. t.name .. "'?\n\nThis link asks " .. t.host .. " to let this computer in. Only say Yes to a link from " ..
      "someone you know: it connects your computer to theirs and their files come here.") then
    return false, "not accepted"
  end
  return invite.redeem(t, now)
end

-- ---- codes: the inviter's computer -----------------------------------------------------------------------------------------------------
-- This computer's codes: ExtState "invite links" { [code] = { token, id, root, ends, used_by, used_at } }, kept here only (never in a synced
-- folder), pruned as they run out.
local function codes(now)
  local all, out, changed = band.ext_json(band.SECTION, "invite links") or {}, {}, false
  for c, r in pairs(all) do
    if type(r) == "table" and tonumber(r.ends) and r.ends > now then out[c] = r else changed = true end
  end
  if changed then band.set_ext_json(band.SECTION, "invite links", out, true) end
  return out
end
-- A new invite link to `root` for a "member" or "guest" (owner and admins, where joins.make can: the link and Tailscale up). -> the link,
-- or nil + why.
function invite.make_code(root, role, now)
  now = now or os.time()
  local text, tok = require("joins").make(root, role, now)
  if not text then return nil, "this computer can't make invitations now (owner or admin, StudioSync's extension, the direct link and Tailscale)" end
  local code = band.secret(invite.CODE_LEN)
  local all = codes(now)
  all[code] = { token = text, id = tok.id, root = root, ends = math.min(now + invite.CODE_LIFE, tok.ends) }
  band.set_ext_json(band.SECTION, "invite links", all, true)
  return invite.code_link(tok.studio, tok.name, tok.host, code)
end
local fails = {} -- when each refused code ask came
local function too_many(now)
  local keep = {}
  for _, t in ipairs(fails) do if now - t < invite.FAIL_WINDOW then keep[#keep + 1] = t end end
  fails = keep
  return #fails >= invite.FAIL_MAX
end
-- A "redeem" ask on the join channel: { code, device, name, reply }. -> true (the invitation sent back), or false + why (said in the log as a
-- refused invitation ask: joins.say_refused).
function invite.on_redeem(d, now)
  now = now or os.time()
  local joins, groups = require("joins"), require("groups")
  if too_many(now) then return false, "too many refused link asks lately" end
  local r = type(d) == "table" and joins.valid_request({ token = "-", device = d.device, name = d.name, reply = d.reply })
  local code = r and type(d.code) == "string" and #d.code == invite.CODE_LEN and d.code:match("^%x+$") and d.code:lower()
  local all = codes(now)
  local rec = code and all[code]
  local ok, why = invite.code_check(rec, r and r.device, now)
  if ok and not groups.may_manage(rec.root, me()) then ok, why = false, "only the owner or an admin lets people in" end
  if ok and not reaper.file_exists(rec.root .. "/_band/joins/" .. rec.id .. ".json") then ok, why = false, "its invitation was revoked" end
  local t = ok and groups.tailnet(rec.root)
  if ok and not (r.reply and t and r.reply:sub(-#t.suffix - 1) == "." .. t.suffix:lower()) then ok, why = false, "it came from outside the studio's Tailscale network" end
  if not ok then
    fails[#fails + 1] = now
    joins.say_refused(r or {}, "invite link: " .. why, now)
    return false, why
  end
  if not rec.used_by then
    rec.used_by, rec.used_at = r.device, now
    band.set_ext_json(band.SECTION, "invite links", all, true)
    band.log(string.format("%s's computer (%s) used an invite link: its invitation went to it", r.name, r.device:sub(1, 7)))
  end
  local ch = "joinlink-" .. band.code_hash(code)
  reaper.StudioSync_DirectStart(ch, SECRET .. code, inbox(), -1)
  return reaper.StudioSync_DirectMsg(ch, "token", band.json_encode({ token = rec.token }), r.reply .. ":" .. require("direct").port()) == 1
end

-- ---- codes: the joiner's computer ------------------------------------------------------------------------------------------------------
local sent_at = {}
local function redeems() return band.ext_json(band.SECTION, "invite redeem") or {} end
local function send_redeem(h, p)
  local services, direct, joins = require("services"), require("direct"), require("joins")
  local dev, reply = services.my_device_id(), services.my_tailscale_name()
  if not (dev and reply and reaper.StudioSync_DirectStart and reaper.StudioSync_DirectMsg) then return false end
  sent_at[h] = reaper.time_precise()
  reaper.StudioSync_DirectStart(joins.CHANNEL, joins.CHANNEL_SECRET, inbox(), -1)
  -- (listening for the answer where it can: on Windows only with the firewall rule, as the welcome does)
  reaper.StudioSync_DirectStart("joinlink-" .. h, SECRET .. p.code, inbox(), direct.firewall_ok() and direct.port() or -1)
  local data = band.json_encode({ code = p.code, device = dev, name = me(), reply = (reply:gsub("%.$", "")) })
  return reaper.StudioSync_DirectMsg(joins.CHANNEL, "redeem", data, p.host .. ":" .. direct.port()) == 1
end
-- Ask t.host for the invitation behind t.code (kept, and asked again every RESEND s for REDEEM_FOR s). -> true + words, or false + why.
function invite.redeem(t, now)
  now = now or os.time()
  local services = require("services")
  if not (reaper.StudioSync_DirectMsg and services.my_device_id() and services.my_tailscale_name()) then
    invite.say("This link needs StudioSync's extension, Syncthing and Tailscale on this computer. Ask whoever sent it for the invitation message instead, " ..
      "and paste it with Paste join code.")
    return false, "no direct link here"
  end
  -- (the invitation comes back over the link, which Windows lets in only with the firewall rule: without it, say so rather than ask. rt-p10)
  if band.WIN and not require("direct").firewall_ok() then
    invite.say("This computer can't hear " .. t.host .. "'s answer yet: Windows' firewall rule for StudioSync's direct link isn't on. Press the firewall " ..
      "button on Health's direct-link row (one Windows prompt), then open the link again. Or ask them for the invitation message and paste it with Paste join code.")
    return false, "no firewall rule here"
  end
  local h = band.code_hash(t.code)
  local all = redeems()
  all[h] = { code = t.code, studio = t.studio, name = t.name, host = t.host, ends = now + invite.REDEEM_FOR }
  band.set_ext_json(band.SECTION, "invite redeem", all, true)
  send_redeem(h, all[h])
  band.log("asking " .. t.host .. " for the invitation to " .. t.name .. " (an invite link)")
  return true, "asking " .. t.host
end
-- The invitation back on joinlink-<h>: from here on exactly what Paste join code does with it (lib/page_groups.lua).
function invite.on_token(h, d, now)
  local all = redeems()
  local p = all[h]
  if not p or type(d) ~= "table" or type(d.token) ~= "string" or #d.token > 1024 then return false end
  local services = require("services")
  local code = services.parse_join(d.token)
  if not (code and code.invite and code.invite.studio == p.studio and code.invite.host == p.host) then
    band.log("an answer to an invite link didn't hold an invitation to " .. p.name .. ": ignored")
    return false
  end
  all[h] = nil
  band.set_ext_json(band.SECTION, "invite redeem", all, true)
  local cfg = band.settings()
  local root, why
  if cfg then root, why = services.join_band(cfg, code) end -- (not `cfg and join_band(...)`: that keeps only its first value, and lost why)
  if not root then band.log("the invite link to " .. p.name .. " didn't join: " .. tostring(why or "StudioSync isn't set up here")); return false end
  local asking = why == "back" or not reaper.file_exists(root .. "/_band/band.json") -- ("back": a copy kept from before. rt-fix7)
  if asking then require("joins").request(root, code.invite) end
  band.log("joined " .. p.name .. " from an invite link" .. (asking and ": their computer lets you in over Tailscale, then the projects arrive" or ""))
  return true
end

-- ---- each tick (from joins.tick: Autostart and the panel; from Live sync while Autostart isn't running: invite.live_tick) ----------------
-- Live sync's: a clicked link (lib/urlhandler.lua's file) is read in a REAPER without Autostart too, where it waited for the panel (rt-r2:
-- LinuxBox's launcher left two files nobody read). Not while Autostart beats (every 2 s, "autostart beat"), which reads them. rt-fix7
function invite.live_tick(now)
  local beat = tonumber(reaper.GetExtState(band.SECTION, "autostart beat"))
  if beat and reaper.time_precise() - beat < 20 and reaper.time_precise() >= beat then return end
  return invite.tick(now)
end
local tick_at = -math.huge
function invite.tick(now)
  local t = reaper.time_precise()
  if t - tick_at < 1 and t >= tick_at then return end
  tick_at, now = t, now or os.time()
  -- (one link each LINK_EVERY s: taken sooner, handle_link would refuse it as "a moment ago" and it was lost. rt-p10)
  local s = t - link_at >= invite.LINK_EVERY and invite.take_pending()
  if s then band.try("invite.handle_link", invite.handle_link, s, now) end
  local all, changed = redeems(), false
  for h, p in pairs(all) do
    if type(p) ~= "table" or not tonumber(p.ends) or now >= p.ends then
      all[h], changed = nil, true
      if type(p) == "table" then band.log("no answer from " .. tostring(p.host) .. " to the invite link: ask them for the invitation message and paste it with Paste join code") end
    elseif t - (sent_at[h] or -math.huge) >= invite.RESEND then send_redeem(h, p) end
  end
  if changed then band.set_ext_json(band.SECTION, "invite redeem", all, true) end
end

-- ---- the web UI (lib/webui.lua: topic "invite") ------------------------------------------------------------------------------------
local W = { last = nil, at = -math.huge }
-- a: { ask = { to, song, room } } | { answer = { scope, id, go } } | { link = "studiosync://..." } (join.html). -> words for the log.
function invite.action(proj, cfg, b, a)
  W.at = -math.huge
  if type(a.ask) == "table" then
    local ok, said = invite.ask(cfg, b, a.ask.to, a.ask.song, a.ask.room)
    W.last = { ok = ok == true, text = said, to = type(a.ask.to) == "string" and a.ask.to:sub(1, 64) or nil, at = os.time() }
    return said
  end
  if type(a.answer) == "table" and type(a.answer.scope) == "string" then
    return invite.answer(cfg, b, a.answer.scope, a.answer.id, a.answer.go == true)
  end
  if type(a.link) == "string" then
    local ok, said = invite.handle_link(a.link)
    W.last = { ok = ok == true, text = said, at = os.time() }
    return said
  end
end
function invite.model(cfg, b, now)
  local direct = require("direct")
  return { me = cfg.user, studio = band.info(cfg.root).id, port = direct.port(), people = require("page_chat").people(cfg),
    asks = invite.pending(cfg, now), last = W.last, song = b and b.song, room = b and b.room or "main" }
end
function invite.web_tick(proj, cfg, b, publish, now)
  if now - W.at < 3 then return end
  W.at = now
  local ok, m = pcall(invite.model, cfg, b, os.time())
  publish("invite", ok and m or { me = cfg.user, error = tostring(m) })
end

-- ---- the panel ---------------------------------------------------------------------------------------------------------------------
-- Join requests for you, on the panel's Home: who, which project, Join and Decline. Nothing drawn when there are none.
function invite.panel_ui(ctx, ImGui, cfg)
  if not cfg then return end
  local list = invite.pending(cfg, os.time())
  if #list == 0 then return end
  local b = band.binding(0)
  for _, x in ipairs(list) do
    ImGui.Text(ctx, string.format("%s asks you to join %s%s", x.user, x.song, x.room ~= "main" and (" (" .. x.room .. ")") or ""))
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, "Join##ask" .. x.id) then band.log(tostring(invite.answer(cfg, b, x.scope, x.id, true))) end
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, "Decline##ask" .. x.id) then band.log(tostring(invite.answer(cfg, b, x.scope, x.id, false))) end
  end
  ImGui.Separator(ctx)
end
function invite.count(cfg) return cfg and #invite.pending(cfg, os.time()) or 0 end

-- ---- Settings (under Invitations: lib/joins.lua studio_ui) ---------------------------------------------------------------------------
local shown_link, handler_note
local function scripts_dir() return debug.getinfo(1, "S").source:match("^@?(.*)[/\\]lib[/\\][^/\\]+$") or "." end
function invite.studio_ui(ctx, ImGui, cfg, may)
  if may then
    for _, role in ipairs({ "member", "guest" }) do
      if role == "guest" then ImGui.SameLine(ctx) end
      if ImGui.SmallButton(ctx, "Copy invite link (" .. role .. ")##invlink" .. role) then
        local link, why = invite.make_code(cfg.root, role)
        shown_link = link or why
        if link then ImGui.SetClipboardText(ctx, link); band.log("an invite link to " .. band.info(cfg.root).name .. " was copied: it works once, within a day") end
      end
    end
    ImGui.SetItemTooltip(ctx, "A studiosync:// link that lets one computer in, once, within a day. It works for someone already on the studio's Tailscale " ..
      "network with StudioSync's link handler; anyone else needs Invite a collaborator's message. The link holds no key: it asks this computer for the invitation.")
    if shown_link then ImGui.TextWrapped(ctx, shown_link) end
  end
  local uh = require("urlhandler")
  local o, rio = uh.here(scripts_dir()), uh.real_io()
  local on = reaper.GetExtState(band.SECTION, "link handler") == "1"
  local ch, v = ImGui.Checkbox(ctx, "Open StudioSync links on this computer##linkhandler", on)
  ImGui.SetItemTooltip(ctx, "Lets a studiosync:// link in a browser or chat app start REAPER and open the project (or ask to join). Installs a small " ..
    "handler for your user only; untick to take it away.")
  if ch then
    local ok, why
    if v then ok, why = uh.install(o, rio) else ok, why = uh.uninstall(o, rio) end
    if ok then reaper.SetExtState(band.SECTION, "link handler", v and "1" or "", true) end
    handler_note = ok and (v and "StudioSync links open here now." or "The link handler is gone.") or ("Not done: " .. tostring(why))
    band.log(handler_note)
  end
  if handler_note then ImGui.TextDisabled(ctx, handler_note) end
end

return invite
