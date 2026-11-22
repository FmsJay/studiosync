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
local view_until, view_at = -math.huge, -math.huge -- (rt-share: this computer sharing until; its arrange view last published at)
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
  return { boot = webcall.boot, me = me, open = list, msgs = msgs, live = live and true or nil, ice = webcall.ice() }
end
-- (P13, backlog 3.2 A) The pages' ICE servers: with the studio's connection without Tailscale on, its STUN servers and the studio's relay as
-- TURN (lib/nat.lua ice), so two browsers that aren't on each other's Tailscale or network still meet; nil otherwise (host candidates only,
-- as over Tailscale). For the studio webcall.me was last asked about (lib/webui.lua's tick asks it right before the model).
local ice_root
function webcall.ice()
  local ok, list = pcall(function() return ice_root and require("nat").ice(ice_root) end)
  return ok and list or nil
end
function webcall.dirty() return dirty end
function webcall.reset() q, seq, open, dirty, view_until, view_at = {}, 0, {}, true, -math.huge, -math.huge end -- (tests)

-- ---- Live sync's side (lib/webui.lua's tick) ---------------------------------------------------------------------------------------------
function webcall.me(cfg) ice_root = cfg.root; return { user = cfg.user, dev = require("services").my_device_id() } end
-- ---- a screen share's extras (rt-share; lib/webui/call.js) -------------------------------------------------------------------------------
-- Two of a page's messages stay on this computer: "duck" (watching a bandmate's share with its sound: their live Play is in that mix, so it's
-- muted here meanwhile, lib/liveaudio.lua ducks) and "view" (this computer is sharing its screen: Live sync publishes REAPER's arrange view
-- as the "rtview" topic, so the page can keep watchers' notes on the timeline). Both run out unless the page says them again.
webcall.DUCK_FOR = 25   -- seconds a duck lasts (pages say it every 10 s)
webcall.VIEW_FOR = 6    -- seconds a "view" lasts (pages say it every 2 s while sharing)
webcall.VIEW_EVERY = 0.1
webcall.TRACKS_MAX = 256
-- -> true when done. clock: reaper.time_precise().
function webcall.local_msg(a, clock)
  if a.t == "view" then view_until = clock + webcall.VIEW_FOR; return true end
  if a.t ~= "duck" or not dev_ok(a.to) then return false end
  local o = open[a.to] -- (a bandmate whose page is open: their name is what live audio's cue mix goes by)
  if not o then return false end
  local la = require("liveaudio")
  la.ducks = la.ducks or {}
  -- (by their computer's peer, so a bandmate's other computer in the room isn't muted too: rt-p11, backlog 1.24; by name only when unknown)
  la.ducks[o.peer or o.user] = a.on == true and clock + webcall.DUCK_FOR or nil
  pcall(la.apply)
  return true
end
function webcall.viewing(clock) return clock < view_until end

-- A window's rect, y downward on every system (macOS counts up from the bottom: flipped, as only differences are used). JS_ReaScriptAPI, else
-- SWS. -> { x, y, w, h } or nil.
local function rect_of(hwnd, client)
  if not hwnd then return nil end
  local ok, l, t, r, b
  if client and reaper.JS_Window_GetClientRect then ok, l, t, r, b = reaper.JS_Window_GetClientRect(hwnd)
  elseif reaper.JS_Window_GetRect then ok, l, t, r, b = reaper.JS_Window_GetRect(hwnd)
  elseif reaper.BR_Win32_GetWindowRect then ok, l, t, r, b = reaper.BR_Win32_GetWindowRect(hwnd) end
  if not ok or not (tonumber(l) and tonumber(t) and tonumber(r) and tonumber(b)) then return nil end
  if reaper.GetOS():find("OSX") or reaper.GetOS():find("mac") then t, b = -t, -b end
  return { x = math.floor(l), y = math.floor(math.min(t, b)), w = math.floor(r - l), h = math.floor(math.abs(b - t)) }
end
local function trackview(main)
  if reaper.JS_Window_FindChildByID then return reaper.JS_Window_FindChildByID(main, 1000) end -- (REAPER's arrange view, id 1000)
  if reaper.BR_Win32_FindWindowEx and reaper.BR_Win32_HwndToString then
    return reaper.BR_Win32_FindWindowEx(reaper.BR_Win32_HwndToString(main), "0", "REAPERTrackListWindow", "", true, false)
  end
end
-- REAPER's arrange view as this computer shows it: { on, t0, t1 (the time it shows), arr (its rect on screen), win (REAPER's main window),
-- mon (the screen it's on; not on macOS), tracks = { { id, y, h, name } } (each shown track's place from the arrange view's top, scrolled as
-- shown; id: 8 characters of its GUID) }. No arr without JS_ReaScriptAPI or SWS: watchers then point at the picture, not the timeline.
function webcall.view_model(proj)
  local t0, t1 = reaper.GetSet_ArrangeView2(proj, false, 0, 0, 0, 0)
  local v = { on = true, t0 = math.floor((t0 or 0) * 10000 + 0.5) / 10000, t1 = math.floor((t1 or 0) * 10000 + 0.5) / 10000, tracks = {} }
  local main = reaper.GetMainHwnd()
  v.arr, v.win = rect_of(trackview(main), true), rect_of(main, false)
  if v.arr and reaper.my_getViewport and not (reaper.GetOS():find("OSX") or reaper.GetOS():find("mac")) then
    local ok, l, t, r, b = pcall(reaper.my_getViewport, 0, 0, 0, 0, v.arr.x, v.arr.y, v.arr.x + v.arr.w, v.arr.y + v.arr.h, false)
    if ok and tonumber(l) and tonumber(r) and r > l and b > t then v.mon = { x = l, y = t, w = r - l, h = b - t } end
  end
  for i = 0, math.min(reaper.CountTracks(proj), webcall.TRACKS_MAX) - 1 do
    local tr = reaper.GetTrack(proj, i)
    local h = math.floor(reaper.GetMediaTrackInfo_Value(tr, "I_TCPH") or 0)
    if h > 0 then
      local _, name = reaper.GetTrackName(tr)
      v.tracks[#v.tracks + 1] = { (reaper.GetTrackGUID(tr) or ""):gsub("[{}%-]", ""):sub(1, 8), math.floor(reaper.GetMediaTrackInfo_Value(tr, "I_TCPY") or 0), h,
        tostring(name or ""):sub(1, 64) }
    end
  end
  return v
end
-- Live sync's tick (lib/webui.lua): while this computer shares, its arrange view every VIEW_EVERY s (published only when it changed).
function webcall.view_tick(proj, publish, clock)
  if clock >= view_until then
    if view_at > -math.huge then view_at = -math.huge; publish("rtview", { on = false }) end
    return
  end
  if clock - view_at < webcall.VIEW_EVERY then return end
  view_at = clock
  publish("rtview", webcall.view_model(proj))
end

-- A page's action. -> true when it went over the link. A message to a computer the link can't reach now, or that the link wouldn't take,
-- comes back to the pages as { t = "error", call, why }; what went out is shown to the other pages here (no SDP) as { out = true, ... }, so
-- a ring on a second window stops when one answers.
local here_at = -math.huge
function webcall.page(cfg, b, a, now)
  now = now or os.time()
  if type(a) == "table" and (a.t == "duck" or a.t == "view") then return webcall.local_msg(a, reaper.time_precise()) and false end -- (this computer only)
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
  open[m.dev] = { user = m.user, host = host_of(known[m.dev]), peer = known[m.dev], at = now } -- (any message from them says their page is open)
  if m.t ~= "here" then push(m, now) end
  return true
end

return webcall
