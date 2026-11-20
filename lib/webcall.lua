-- Video calls and screen share in the web UI (docs/realtime-roadmap.md step 5; the pages' side is lib/webui/call.js). The browser (or the
-- docked view) does the media itself, peer to peer over WebRTC; this file only carries the setup between computers, with no server: a page
-- posts an offer or answer (POST /api/action, topic "rtc") -> Live sync's tick hands it here -> direct.send_live(cfg, "rtc", ...) to that one
-- bandmate's computer over the signed link -> their Live sync gives it to their copy of this file -> their pages read it in the "rtc" topic.
-- ICE candidates travel inside the offer and answer (the page waits for gathering to finish: with no STUN or TURN only host candidates, so
-- it's quick), so one message each way sets a call up. A page that can do video says "here" every 10 s; that goes to everyone in the room,
-- which is how the others know whose web UI is open and offer "Call" and "Share screen". Everything from the link is checked again here
-- before a page sees it: the kind of message, the call id, who it's for (this computer), who it's from (a computer in the room now), sizes.
-- (James, rt)
local band = require("band")
local webcall = {}
webcall.SDP_MAX = 12000  -- bytes in one offer or answer (the server takes 16 KB per POST; camera + data channel with host candidates is ~4-6 KB)
webcall.KEEP = 16        -- signalling messages the pages are shown, the newest (each may hold an SDP: the topic stays small)
webcall.KEEP_FOR = 30    -- seconds one is shown (setup takes a second or two; a ring nobody answers is over by then)
webcall.OPEN_FOR = 25    -- seconds a bandmate's page counts as open after its last "here" (pages say it every 10 s)
webcall.HERE_EVERY = 5   -- seconds between "here"s this computer passes on (several pages open here each say it)
webcall.NAME_MAX = 64

local KINDS = { call = true, screen = true }       -- an offer's: a video call, or a screen share (the caller shares, the other watches)
local TO_ONE = { offer = true, answer = true, bye = true, busy = true } -- to one computer; "here" goes to everyone in the room

local function dev_ok(s) return require("services").is_device_id(s) end
local function call_ok(s) return type(s) == "string" and #s >= 8 and #s <= 64 and s:match("^[%w%-]+$") ~= nil end
local function name_ok(s) return type(s) == "string" and #s >= 1 and #s <= webcall.NAME_MAX and not s:find("%c") end

-- ---- checks (pure) ------------------------------------------------------------------------------------------------------------------------
-- A message from a page here: a = the action's table; me = { user, dev } (this computer). -> what goes over the link, or nil and why.
function webcall.from_page(a, me)
  if type(a) ~= "table" or type(me) ~= "table" or not name_ok(me.user) or not dev_ok(me.dev) then return nil, "not a message" end
  if a.t == "here" then return { t = "here", user = me.user, dev = me.dev } end
  if not TO_ONE[a.t] then return nil, "not a kind of call message" end
  if not dev_ok(a.to) or a.to == me.dev then return nil, "not to a bandmate's computer" end
  if not call_ok(a.call) then return nil, "no call id" end
  local m = { t = a.t, call = a.call, to = a.to, user = me.user, dev = me.dev }
  if a.t == "offer" then
    if not KINDS[a.kind] then return nil, "neither a call nor a screen share" end
    m.kind, m.audio = a.kind, a.audio == true or nil
  end
  if a.t == "offer" or a.t == "answer" then
    if type(a.sdp) ~= "string" or #a.sdp > webcall.SDP_MAX or a.sdp:sub(1, 4) ~= "v=0\r" and a.sdp:sub(1, 4) ~= "v=0\n" then return nil, "no session description, or too big" end
    m.sdp = a.sdp
  end
  return m
end
-- A message from a bandmate's computer (direct.send_live's d): checked as a page's would be, as from them, and then: for this computer (or
-- "here", for everyone), from a computer in the room now (known: device id -> its peer, from direct.peers; a forged sender outside the room
-- gets nowhere). -> the message, or nil.
function webcall.from_link(d, me, known)
  if type(d) ~= "table" or type(me) ~= "table" or d.dev == me.dev or type(known) ~= "table" or not known[d.dev] then return nil end
  local m = webcall.from_page(d, { user = d.user, dev = d.dev })
  if not m or (m.t ~= "here" and m.to ~= me.dev) then return nil end
  return m
end
-- peers, dev_of: direct.peers' two answers. -> device id -> peer ("name:port").
function webcall.known(peers, dev_of)
  local k = {}
  for _, p in ipairs(peers or {}) do local d = (dev_of or {})[p]; if type(d) == "string" then k[d] = p end end
  return k
end
local function host_of(peer) return type(peer) == "string" and peer:match("^([^%.:]+)") or nil end

-- ---- what the pages see ---------------------------------------------------------------------------------------------------------------
-- (one queue for this computer: the studio in front's, as the rest of the web UI. boot: the pages start counting again when it changes)
local q, seq, open, dirty = {}, 0, {}, true
webcall.boot = tostring(os.time())
local function push(m, now)
  seq = seq + 1
  m.seq, m.time = seq, now
  q[#q + 1] = m
  while #q > webcall.KEEP do table.remove(q, 1) end
  dirty = true
end
-- -> { boot, me = { user, dev }, open = { { user, dev, host } } (by name), msgs = the newest, oldest first, live }. now: os.time().
-- live: StudioSync's live audio runs here, so a page leaves call audio unticked until someone ticks it (it carries the music already).
function webcall.model(me, now, live)
  local list, msgs = {}, {}
  for dev, o in pairs(open) do
    if now - o.at < webcall.OPEN_FOR then list[#list + 1] = { user = o.user, dev = dev, host = o.host } else open[dev] = nil end
  end
  table.sort(list, function(a, z) if a.user:lower() ~= z.user:lower() then return a.user:lower() < z.user:lower() end return a.dev < z.dev end)
  for i = #q, 1, -1 do if now - q[i].time >= webcall.KEEP_FOR then table.remove(q, i) end end
  for _, m in ipairs(q) do msgs[#msgs + 1] = m end
  dirty = false
  return { boot = webcall.boot, me = me, open = list, msgs = msgs, live = live and true or nil }
end
function webcall.dirty() return dirty end
function webcall.reset() q, seq, open, dirty = {}, 0, {}, true end -- (tests)

-- ---- Live sync's side (lib/webui.lua's tick) ---------------------------------------------------------------------------------------------
function webcall.me(cfg) return { user = cfg.user, dev = require("services").my_device_id() } end
-- A page's action. -> true when it went over the link. A message to a computer the link can't reach now, or that the link wouldn't take,
-- comes back to the pages as { t = "error", call, why }; what went out is shown to the other pages here (no SDP) as { out = true, ... }, so
-- a ring on a second window stops when one answers.
local here_at = -math.huge
function webcall.page(cfg, b, a, now)
  now = now or os.time()
  local m = webcall.from_page(a, webcall.me(cfg))
  if not m then return false end
  local direct = require("direct")
  if m.t == "here" then
    if now - here_at < webcall.HERE_EVERY then return false end
    here_at = now
    return direct.send_live(cfg, "rtc", m, b.song, b.room)
  end
  local peer = webcall.known(direct.peers(cfg, b.song, b.room))[m.to]
  local ok = peer ~= nil and direct.send_live(cfg, "rtc", m, b.song, b.room, nil, { peer })
  if ok then push({ t = m.t, call = m.call, to = m.to, out = true }, now)
  else push({ t = "error", call = m.call, why = peer and "the direct link didn't take it" or "that computer isn't reachable over the direct link now" }, now) end
  return ok
end
-- A bandmate's message (Live sync's handlers.rtc). -> true when the pages will see it.
function webcall.link(cfg, b, d, now)
  now = now or os.time()
  local direct = require("direct")
  local known = webcall.known(direct.peers(cfg, b.song, b.room))
  local m = webcall.from_link(d, webcall.me(cfg), known)
  if not m then return false end
  local o = open[m.dev]
  if not o or o.user ~= m.user then dirty = true end
  open[m.dev] = { user = m.user, host = host_of(known[m.dev]), at = now } -- (any message from them says their page is open)
  if m.t ~= "here" then push(m, now) end
  return true
end

return webcall
