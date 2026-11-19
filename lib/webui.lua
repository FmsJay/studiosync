-- The web UI (docs/realtime-roadmap.md "A new interface: web UI"; the server is extension/webui.cpp, the pages lib/webui/). The engine stays
-- here: Live sync's tab in front publishes who's here, claims and the project's chat as JSON topics each tick (only when they change), and
-- applies what the pages send (a chat message, through the Chat page's own store: lib/page_chat.lua). On this computer the pages are at
-- http://127.0.0.1:47281/ with no token; a phone on the studio's Tailscale uses this computer's name on the same port (the direct link's,
-- so its one firewall rule covers it) with the studio's web token, which the extension derives from the studio's secret. Nothing here
-- does anything with an older extension. (James, rt)
local band = require("band")
local webui = {}
webui.START_EVERY = 10   -- seconds between refreshing the server's folder, token and port (a re-keyed studio's token changes)
webui.PRESENCE_EVERY = 1 -- seconds between presence builds (each reads the status and claims files' caches)
webui.CHAT_EVERY = 2     -- seconds between chat reads (page_chat keeps its own read 3 s)
webui.CHAT_MAX = 100     -- messages the pages get: the newest
webui.TEXT_MAX = 2000    -- bytes in one message from a page
webui.LOOK_GRACE = 30    -- seconds a page counts as looking after its last request (one polling /api/state holds no connection open)

function webui.available()
  return reaper.StudioSync_WebUIStart ~= nil and reaper.StudioSync_WebUIPublish ~= nil and reaper.StudioSync_WebUIPoll ~= nil and reaper.StudioSync_WebUIStatus ~= nil
end
function webui.folder() return (debug.getinfo(1, "S").source:match("^@?(.*)[/\\]") or ".") .. "/webui" end

-- Started (or its folder, token and port refreshed) at most every START_EVERY seconds. -> true when it's listening.
local started = { at = -math.huge }
function webui.start(cfg)
  if not (cfg and cfg.root and webui.available()) then return false end
  local now = reaper.time_precise()
  if started.root == cfg.root and now - started.at < webui.START_EVERY then return started.ok end
  -- (no secret, no token: only this computer gets in)
  local secret = select(2, pcall(require("groups").sonobus_secret, cfg.root))
  -- (noted for the extension's "StudioSync: Web UI (docked)" action, which starts the server itself when it's run before Live sync or the panel)
  if reaper.GetExtState(band.SECTION, "web ui folder") ~= webui.folder() then reaper.SetExtState(band.SECTION, "web ui folder", webui.folder(), true) end
  started = { root = cfg.root, at = now,
    ok = reaper.StudioSync_WebUIStart(webui.folder(), type(secret) == "string" and secret or "", require("direct").port()) == 1 }
  return started.ok
end
function webui.status() return webui.available() and band.json_decode(reaper.StudioSync_WebUIStatus()) or {} end

-- Addresses. Pure.
function webui.local_url(port) return "http://127.0.0.1:" .. math.floor(tonumber(port) or 47281) .. "/" end
function webui.phone_url(name, port, token)
  if type(name) ~= "string" or not name:match("^[%w][%w%.%-]*$") or type(token) ~= "string" or not token:match("^%x+$") then return nil end
  return "http://" .. name .. ":" .. math.floor(tonumber(port) or 47281) .. "/?t=" .. token
end

-- The panel's buttons (lib/page_chat.lua). -> true when the browser was asked to open it.
function webui.open(cfg)
  if not webui.start(cfg) then
    local st = webui.status()
    band.log("the web UI couldn't start: " .. (st.error ~= nil and st.error ~= "" and st.error or "the StudioSync extension is older (Extensions > ReaPack > Synchronize packages)"))
    return false
  end
  band.open_url(webui.local_url(webui.status().port))
  return true
end
-- The panel's Web UI button: the docked REAPER window (extension/webui_dock.cpp), or the browser with Shift, with an older extension, or
-- where the window can't open (Linux for now, no WebView2 runtime: the log says why). -> true when either opened.
function webui.dock(cfg, browser)
  if browser or not reaper.StudioSync_WebUIDock then return webui.open(cfg) end
  if not webui.start(cfg) then return webui.open(cfg) end -- (which logs why)
  if reaper.StudioSync_WebUIDock(1) >= 0 then return true end
  local why = reaper.GetExtState(band.SECTION, "web ui dock error")
  band.log("the docked web UI couldn't open" .. (why ~= "" and ": " .. why or "") .. "; opening it in the browser instead")
  return webui.open(cfg)
end
-- -> the link for a phone or another computer in the studio, or nil and why not.
function webui.phone_link(cfg)
  if not webui.start(cfg) then return nil, "the web UI isn't running here" end
  local st = webui.status()
  if (st.token or "") == "" then return nil, "this studio has no shared secret yet" end
  local ds = reaper.StudioSync_DirectStatus and band.json_decode(reaper.StudioSync_DirectStatus()) or {}
  if not ds.listening then return nil, "the direct link isn't listening here (Setup > Health, its row)" end
  local name = require("services").my_tailscale_name()
  local url = webui.phone_url(name, st.port, st.token)
  if not url then return nil, "Tailscale has no name for this computer (MagicDNS off?)" end
  return url
end

-- ---- what the pages show (pure) ---------------------------------------------------------------------------------------------------------
-- me: { user, playing, recording, armed }; peers: presence.peers' statuses; who: sync.authority's second answer (or nil).
-- -> { song, room, driver, mode, people = { { user, me, playing, recording, armed, live, call } }, claims = { { user, kind, name, from, to } } }
local function person(st, me)
  local armed = {}
  for _, a in ipairs(type(st.armed) == "table" and st.armed or {}) do if type(a) == "string" then armed[#armed + 1] = a end end
  return { user = st.user, me = me or nil, playing = st.playing == true or nil, recording = st.recording == true or nil, armed = armed,
    live = type(st.live) == "string" and st.live or nil, call = st.call and true or nil }
end
function webui.presence_model(song, room, me, peers, who)
  local people = { person(me, true) }
  local others = {}
  for _, st in ipairs(peers or {}) do if type(st) == "table" and type(st.user) == "string" and st.user ~= me.user then others[#others + 1] = person(st) end end
  table.sort(others, function(a, z) return a.user:lower() < z.user:lower() end)
  for _, p in ipairs(others) do people[#people + 1] = p end
  local claims = {}
  if type(who) == "table" then
    for kind, list in pairs({ track = who.tracks, region = who.regions }) do
      for _, c in pairs(type(list) == "table" and list or {}) do
        if type(c) == "table" and type(c.user) == "string" then claims[#claims + 1] = { user = c.user, kind = kind, name = tostring(c.name or "") } end
      end
    end
    for _, t in ipairs(type(who.times) == "table" and who.times or {}) do
      if type(t.user) == "string" and tonumber(t.from) and tonumber(t.to) then claims[#claims + 1] = { user = t.user, kind = "time", from = t.from, to = t.to } end
    end
  end
  table.sort(claims, function(a, z)
    if a.user ~= z.user then return a.user < z.user end
    if a.kind ~= z.kind then return a.kind < z.kind end
    return (a.name or tostring(a.from)) < (z.name or tostring(z.from))
  end)
  return { song = song, room = room, driver = type(who) == "table" and who.driver or nil, mode = type(who) == "table" and who.mode or nil,
    people = people, claims = claims }
end
-- msgs: page_chat's, oldest first; where_of(where) -> a label or nil. -> { scope, msgs = the newest `max`, oldest first }
function webui.chat_model(msgs, where_of, max)
  local out, first = {}, math.max(1, #(msgs or {}) - (max or webui.CHAT_MAX) + 1)
  for i = first, #(msgs or {}) do
    local m = msgs[i]
    if type(m) == "table" and type(m.text) == "string" then
      out[#out + 1] = { user = tostring(m.user or "?"), text = m.text, time = type(m.time) == "string" and m.time or nil, where = where_of and where_of(m.where) or nil }
    end
  end
  return { scope = "song", msgs = out }
end
-- A message from a page: control characters become spaces, ends trimmed; nil when empty or over TEXT_MAX bytes.
function webui.clean_text(t)
  if type(t) ~= "string" then return nil end
  t = t:gsub("%c", " "):match("^%s*(.-)%s*$")
  if t == "" or #t > webui.TEXT_MAX or not utf8.len(t) then return nil end
  return t
end
-- An action's JSON (StudioSync_WebUIPoll) -> its topic and the table, or nil. Only the topics the pages may send.
webui.ACTIONS = { chat = true, rtc = true } -- (rtc: a video call or screen share's setup, lib/webcall.lua)
function webui.parse_action(s)
  local a = type(s) == "string" and s ~= "" and band.json_decode(s)
  if type(a) ~= "table" or type(a.topic) ~= "string" or not webui.ACTIONS[a.topic] then return nil end
  return a.topic, a
end

-- ---- Live sync's tick -------------------------------------------------------------------------------------------------------------------
local published, pres_at, chat_at, rtc_at, was_front, was_looking = {}, -math.huge, -math.huge, -math.huge, false, false
-- Is a page open? An open event stream is a client; a page polling /api/state (no EventSource) shows as the served count moving. The
-- status is a short string and only two numbers are wanted, so no JSON decode each tick. (The first read counts as a request: the grace
-- covers a page already open when Live sync starts.) (James, rt)
local seen = { served = false, at = -math.huge }
local function looking(now)
  local s = reaper.StudioSync_WebUIStatus() or ""
  local served = s:match('"served":(%d+)')
  if served ~= seen.served then seen.served, seen.at = served, now end
  return (tonumber(s:match('"clients":(%d+)')) or 0) > 0 or now - seen.at < webui.LOOK_GRACE
end
local function publish(topic, t)
  local s = band.json_encode(t)
  if published[topic] ~= s then published[topic] = s; reaper.StudioSync_WebUIPublish(topic, s) end
end
-- handlers: Live sync's direct-link handlers (live_handlers), so a bandmate's chat message shows before its file arrives (Live sync's own
-- direct.messages took it: a second reader here would steal the others' presence and cues).
function webui.tick(proj, cfg, b, handlers)
  if not webui.available() or not (b and b.song) then return end
  -- (one tab at a time: the one in front. Coming back to the front, everything goes again: another tab's may be showing)
  local front = reaper.EnumProjects(-1) == proj
  if front ~= was_front then was_front, published, pres_at, chat_at = front, {}, -math.huge, -math.huge end
  if not front or not webui.start(cfg) then return end
  local chat = require("page_chat")
  local webcall = require("webcall")
  if type(handlers) == "table" and not handlers.chat then handlers.chat = function(d) chat.from_msg(cfg, d) end end
  if type(handlers) == "table" and not handlers.rtc then handlers.rtc = function(d) webcall.link(cfg, b, d) end end
  for _ = 1, 20 do
    local topic, a = webui.parse_action(reaper.StudioSync_WebUIPoll())
    if not topic then break end
    local text = topic == "chat" and webui.clean_text(a.text)
    if text then chat.post(cfg, b, text, "song"); chat_at = -math.huge end
    if topic == "rtc" then webcall.page(cfg, b, a) end
  end
  local now = reaper.time_precise()
  -- Nobody looking: no presence (sync.authority reads every claims file) and no chat built. A page arriving gets both on this tick, so the
  -- server's older copy shows for one tick at most. (James, rt)
  local look = looking(now)
  if look and not was_looking then pres_at, chat_at = -math.huge, -math.huge end
  was_looking = look
  if not look then return end
  if now - pres_at >= webui.PRESENCE_EVERY then
    pres_at = now
    local ps = reaper.GetPlayStateEx(proj)
    local me, live = { user = cfg.user, playing = ps & 1 == 1, recording = ps & 4 == 4, armed = {} }, require("live")
    for i = 0, reaper.CountTracks(proj) - 1 do
      local tr = reaper.GetTrack(proj, i)
      if live.armed(tr) then me.armed[#me.armed + 1] = select(2, reaper.GetTrackName(tr)) end
    end
    local sync = require("sync")
    local _, who = sync.authority(cfg, b.song, b.room)
    publish("presence", webui.presence_model(b.song, b.room, me, require("presence").peers(cfg, b.song, b.room), who))
  end
  -- (video calls: a message in or out shows at once; who's open is looked at again every second, as their "here"s age out)
  if webcall.dirty() or now - rtc_at >= 1 then rtc_at = now; publish("rtc", webcall.model(webcall.me(cfg), os.time())) end
  if now - chat_at >= webui.CHAT_EVERY then
    chat_at = now
    local t = chat.read(cfg, b, "song")
    publish("chat", webui.chat_model(t.msgs, function(w) return chat.where_label(w, b, "song") end))
  end
end

return webui
