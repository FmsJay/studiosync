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
local TO_ONE = { offer = true, answer = true, bye = true, busy = true, ask = true } -- to one computer; "here" goes to everyone in the room
-- (rt-share: "ask" = a borrower asks to see a plug-in's own window, what = "window", token = the try's, fx = its name; the owner's yes is
-- their screen share of that window, its offer carrying re = the ask's call id; a no is "busy")

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
    if a.re ~= nil then if not call_ok(a.re) then return nil, "not an ask's call id" end m.re = a.re end
  end
  if a.t == "ask" then
    local token = math.tointeger(tonumber(a.token))
    if a.what ~= "window" or not token or token < 1 or type(a.fx) ~= "string" then return nil, "not an ask to see a plug-in's window" end
    m.what, m.token, m.fx = "window", token, require("hoptry").clip(a.fx, 200)
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
local asks, answers, fxwins = {}, {}, {} -- (rt-share: watchers' asks for control the panel's bar shows; its answers; plug-in windows opened to share)
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
  for i = #answers, 1, -1 do if now - answers[i].time >= webcall.KEEP_FOR then table.remove(answers, i) end end
  local fw = {}
  for token, w in pairs(fxwins) do fw[#fw + 1] = { token = token, track = w.track, fxi = w.fxi, fx = w.fx } end
  table.sort(fw, function(a, z) return a.token < z.token end)
  return { boot = webcall.boot, me = me, open = list, msgs = msgs, live = live and true or nil, ice = webcall.ice(),
    answers = #answers > 0 and answers or nil, fxwin = #fw > 0 and fw or nil, la = live and webcall.la_model() or nil }
end
-- (P13, backlog 3.2 A) The pages' ICE servers: with the studio's connection without Tailscale on, its STUN servers and the studio's relay as
-- TURN (lib/nat.lua ice), so two browsers that aren't on each other's Tailscale or network still meet; nil otherwise (host candidates only,
-- as over Tailscale). For the studio webcall.me was last asked about (lib/webui.lua's tick asks it right before the model).
local ice_root
function webcall.ice()
  local ok, list = pcall(function() return ice_root and require("nat").ice(ice_root) end)
  return ok and list or nil
end
-- Live audio's Mute and Deafen for the top bar's call controls (rt-ui9): { mute, deaf, ptt }, flags true or absent; nil without live audio.
function webcall.la_model()
  local ok, s = pcall(function() return require("liveaudio").me() end)
  if not ok or type(s) ~= "table" then return nil end
  return { mute = s.mute or nil, deaf = s.deaf or nil, ptt = s.ptt or nil }
end
function webcall.dirty() return dirty end
function webcall.reset() q, seq, open, dirty, view_until, view_at, asks, answers, fxwins = {}, 0, {}, true, -math.huge, -math.huge, {}, {}, {} end -- (tests)

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
  if a.t == "la" then -- (the top bar's Mute / Deafen for live audio, as the panel's live audio bar: rt-ui9)
    if (a.k ~= "mute" and a.k ~= "deaf") or type(a.on) ~= "boolean" then return false end
    local la = require("liveaudio")
    if not (la.available and la.available()) then return false end
    la.set(a.k, a.on)
    dirty = true
    return true
  end
  if a.t == "ctlask" then return webcall.ctl_ask(a, clock) end
  if a.t == "fxwin" then -- (the owner said yes to "Show its window": it opens here, and the page shares it. rt-share)
    local token = math.tointeger(tonumber(a.token))
    local w = token and require("hoptry").show_window(token)
    if not w then return false end
    fxwins[token], dirty = w, true
    return true
  end
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

-- ---- asks for control on the panel's bar (rt-share; the page has its own Allow / Deny, lib/webui/call.js) -----------------------------------
-- The sharer's page says each ask it shows ({t = "ctlask", call, user, on}: on = false when it's answered or gone; renewed every few s, so
-- one from a closed page goes by itself); Live sync puts them in ExtState "share asks" for the panel's bar (webcall.bar) and takes the bar's
-- answer from "share answer" ({call, yes}) into the model's answers, which the page acts on. Control itself is the extension's
-- (extension/remotectl.cpp): the bar also says who controls now, with Stop (StudioSync_RemoteControlStop).
webcall.ASK_FOR = 8
local bar_s = nil
function webcall.ctl_ask(a, clock)
  if not call_ok(a.call) then return false end
  if a.on == true and name_ok(a.user) then asks[a.call] = { call = a.call, user = a.user, at = clock } else asks[a.call] = nil end
  return true
end
-- -> the asks still being shown, oldest first. clock: reaper.time_precise().
function webcall.ctl_asks(clock)
  local out = {}
  for c, x in pairs(asks) do if clock - x.at > webcall.ASK_FOR then asks[c] = nil else out[#out + 1] = { call = x.call, user = x.user, at = x.at } end end
  table.sort(out, function(a, z) return a.at < z.at end)
  for _, x in ipairs(out) do x.at = nil end
  return out
end
-- Live sync's tick (from view_tick): the bar's answer in, the asks out (only when they changed).
function webcall.asks_tick(clock, now)
  local raw = reaper.GetExtState(band.SECTION, "share answer")
  if raw ~= "" then
    reaper.DeleteExtState(band.SECTION, "share answer", false)
    local a = band.json_decode(raw)
    if type(a) == "table" and call_ok(a.call) and asks[a.call] then
      asks[a.call] = nil
      seq = seq + 1
      answers[#answers + 1] = { call = a.call, yes = a.yes == true, seq = seq, time = now }
      dirty = true
    end
  end
  local list = webcall.ctl_asks(clock)
  local s = #list > 0 and band.json_encode(list) or ""
  if s ~= bar_s then bar_s = s; reaper.SetExtState(band.SECTION, "share asks", s, false) end
end
-- The panel's bar (StudioSync - Panel.lua, through hoptry.bar): each ask with Allow / Deny, and who controls your shared window now, with Stop.
function webcall.bar(ctx, ImGui)
  local raw = reaper.GetExtState(band.SECTION, "share asks")
  local list = raw ~= "" and band.json_decode(raw)
  for _, a in ipairs(type(list) == "table" and list or {}) do
    if type(a) == "table" and call_ok(a.call) and name_ok(a.user) then
      ImGui.AlignTextToFramePadding(ctx)
      ImGui.TextColored(ctx, 0xFFD040FF, a.user .. " asks to control the window you're sharing")
      for _, yes in ipairs({ true, false }) do
        ImGui.SameLine(ctx)
        if ImGui.SmallButton(ctx, (yes and "Allow##ctlask" or "Deny##ctlask") .. a.call) then
          reaper.SetExtState(band.SECTION, "share answer", band.json_encode({ call = a.call, yes = yes }), false)
        end
        ImGui.SetItemTooltip(ctx, yes and "Their mouse and keys work inside that window only, until you move your own mouse, press Ctrl+Alt+Esc or Stop."
          or "They keep watching; nothing of theirs reaches your computer.")
      end
    end
  end
  if not reaper.StudioSync_RemoteControlStatus then return end
  local ok, st = pcall(function() return band.json_decode(reaper.StudioSync_RemoteControlStatus()) end)
  if ok and type(st) == "table" and st.on == true and type(st.who) == "string" then
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.TextColored(ctx, 0xFF6040FF, require("hoptry").clip(st.who, 64) .. " is controlling the window you're sharing")
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, "Stop##ctlstop") then reaper.StudioSync_RemoteControlStop() end
    ImGui.SetItemTooltip(ctx, "Takes control back at once (so does moving your own mouse, or Ctrl+Alt+Esc).")
  end
end

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
  webcall.asks_tick(clock, os.time()) -- (the panel's answers to asks for control: rt-share)
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
local LOCAL = { duck = true, view = true, ctlask = true, fxwin = true, la = true } -- (a page's messages that stay on this computer)
function webcall.page(cfg, b, a, now)
  now = now or os.time()
  if type(a) == "table" and LOCAL[a.t] then
    -- (opening a plug-in's window and asks for control: only from a page on this computer, the one that shares. rt-share)
    if (a.t == "fxwin" or a.t == "ctlask" or a.t == "la") and not (reaper.StudioSync_WebUIPollHere ~= nil and reaper.StudioSync_WebUIPollHere() == 1) then return false end
    return webcall.local_msg(a, reaper.time_precise()) and false -- (this computer only)
  end
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
  if m.t == "ask" and not require("hoptry").window_of(m.token, m.user) then return false end -- (only for a plug-in this computer hosts for them)
  local o = open[m.dev]
  if not o or o.user ~= m.user then dirty = true end
  open[m.dev] = { user = m.user, host = host_of(known[m.dev]), peer = known[m.dev], at = now } -- (any message from them says their page is open)
  if m.t ~= "here" then push(m, now) end
  return true
end

return webcall
