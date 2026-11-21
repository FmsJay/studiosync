-- A guest who joins from a browser, with no REAPER and no StudioSync (docs/rt/rt-browserjoin.md; James: "Quick invite for people without
-- reaper ... needs audio interface and asio support for all platforms"). The owner or an admin makes a guest link on the web UI's Home
-- (lib/webui/guesthost.js): a short-lived, single-use code for this project and room, opened through the studio's secure phone link
-- (`tailscale serve`, https://<this computer>:8443/guest.html?g=<code>, the same tailnet-only path as the phone app). The first browser that
-- opens it gets a session cookie for this guest alone (extension/webui.cpp: the guest's own page, event stream, live socket, actions and
-- uploads; never the studio's token, other topics or files). On the guest page (lib/webui/guest.js) they:
--   * hear the session live: this computer's REAPER mix with every bandmate live audio hears, 16-bit over a WebSocket, never their own sound;
--   * are heard live: their interface's input, 16-bit, mixed into what this computer hears and into the Talk it sends the bandmates;
--   * record takes on their interface (raw input: no echo cancellation, noise suppression or gain control) while this computer plays: each
--     goes in as an ordinary take on "<name> (guest)" through the phone-take path (lib/phonerec.lua), placed by the link clock the session
--     mix carried, less the round trip their loopback test measured.
-- This file is the engine side: making, listing, kicking and running out guests (StudioSync_WebUIGuest), the guest's topic
-- ("guest-<gid>": where the song is on the link clock, what was said to them), and their takes. Guests are untrusted: every action is
-- checked again here, takes go only onto their own track under this computer's user's room rules, and one take per guest at a time.
local band = require("band")
local guestweb = {}
guestweb.CODE_LIFE = 30 * 60        -- seconds a guest link can be opened in
guestweb.SESSION = 4 * 3600         -- seconds a guest's session lasts, unless the link asks for less (MIN_SESSION .. SESSION_MAX)
guestweb.MIN_SESSION, guestweb.SESSION_MAX = 10 * 60, 12 * 3600
guestweb.MAX = 4                    -- guests at a time on this computer (the extension takes 8, and four live at once, hearing each other: rt-p11)
guestweb.MAKE_GAP, guestweb.MAKE_HOUR = 5, 12 -- seconds between links, links an hour
guestweb.PUBLISH_EVERY = 0.1        -- seconds between a guest's topic (the page reads where the song is from it)
guestweb.STATUS_EVERY = 0.5         -- seconds between reading the extension's guests (live, level)
guestweb.TAKE_GAP = 3               -- seconds between one guest's takes
guestweb.READ_FOR = 120             -- seconds the play readings go on after a guest was last live (their take arrives after the stop)
guestweb.KEY = "browser guests"     -- ExtState: the guests (never their codes)
guestweb.PORT = 8443                -- the secure link's port (lib/phonerec.lua HTTPS_PORT)

-- ---- pure -------------------------------------------------------------------------------------------------------------------------------
-- The guest link: this computer's MagicDNS name on the secure port. nil from a bad name or code.
function guestweb.link(name, code, port)
  if type(name) ~= "string" or type(code) ~= "string" or not code:match("^%x+$") then return nil end
  name = name:gsub("%.$", "")
  if not name:match("^[%w][%w%.%-]*$") then return nil end
  return "https://" .. name .. ":" .. math.floor(tonumber(port) or guestweb.PORT) .. "/guest.html?g=" .. code
end
local function hex(v, lo, hi) return type(v) == "string" and #v >= lo and #v <= hi and v:match("^%x+$") ~= nil end
local function num(v, lo, hi) v = tonumber(v); return v and v == v and v >= lo and v <= hi and v or nil end
-- A host page's action -> { make = { name, minutes }, kick = gid, gain = { gid, v } }, checked. Pure.
function guestweb.parse_host(a)
  if type(a) ~= "table" then return nil end
  local out = {}
  if type(a.make) == "table" then
    local name = require("phonerec").clean_name(a.make.name)
    if name then out.make = { name = name, minutes = num(a.make.minutes, guestweb.MIN_SESSION / 60, guestweb.SESSION_MAX / 60) } end
  end
  if hex(a.kick, 16, 16) then out.kick = a.kick end
  if type(a.gain) == "table" and hex(a.gain.gid, 16, 16) and num(a.gain.v, 0, 4) then out.gain = { gid = a.gain.gid, v = num(a.gain.v, 0, 4) } end
  return next(out) and out or nil
end
-- A guest's action (inside the extension's wrapper: the gid is the server's, never the guest's word) -> { leave, take = { id, t0, len, err,
-- cid, title } }, checked: the upload id must be one of this guest's (starts with their gid). Pure.
function guestweb.parse_guest(gid, a)
  if not hex(gid, 16, 16) or type(a) ~= "table" then return nil end
  local out = { leave = a.leave == true or nil }
  local t = a.take
  if type(t) == "table" and hex(t.id, 32, 32) and t.id:sub(1, 16) == gid then
    local t0, len = num(t.t0, 1, math.huge), num(t.len, 0.05, require("phonerec").KEEP)
    if t0 and t0 < math.huge and len then
      local err = num(t.err, 0, 9999)
      out.take = { id = t.id, t0 = t0, len = len, err = err and math.floor(err + 0.5) or nil, cid = hex(t.cid, 1, 32) and t.cid or nil,
        title = require("phonerec").clean_name(t.title) }
    end
  end
  return (out.leave or out.take) and out or nil
end
-- The guests still on: run-out ones and ones the extension no longer knows (REAPER restarted) left out. known: the extension's guests (its
-- status), nil when it couldn't be read (then only the time decides). Pure.
function guestweb.alive(list, now, known)
  local out = {}
  for _, g in ipairs(type(list) == "table" and list or {}) do
    if type(g) == "table" and hex(g.gid, 16, 16) and (tonumber(g.ends) or 0) > now and (not known or known[g.gid]) then out[#out + 1] = g end
  end
  return out
end
-- The guest's own track's name.
function guestweb.track_name(name) return name .. " (guest)" end
-- May another link be made now? stamps: when the last ones were made. -> true, or false and why. Pure.
function guestweb.may_make(stamps, n, now)
  if n >= guestweb.MAX then return false, guestweb.MAX .. " guests already: end one first" end
  local hour = 0
  for _, t in ipairs(stamps) do
    if now - t < guestweb.MAKE_GAP then return false, "one guest link every " .. guestweb.MAKE_GAP .. " s" end
    if now - t < 3600 then hour = hour + 1 end
  end
  if hour >= guestweb.MAKE_HOUR then return false, guestweb.MAKE_HOUR .. " guest links an hour at most" end
  return true
end

-- ---- REAPER -----------------------------------------------------------------------------------------------------------------------------
function guestweb.available() return reaper.StudioSync_WebUIGuest ~= nil and reaper.StudioSync_WebUISaveUpload ~= nil and reaper.StudioSync_DirectNow ~= nil end
local S = { stamps = {}, readings = {}, said = {}, take_at = {}, links = {}, done = {} }
function guestweb.reset() S = { stamps = {}, readings = {}, said = {}, take_at = {}, links = {}, done = {} } end -- (tests)
local function list() return guestweb.alive(band.ext_json(band.SECTION, guestweb.KEY), os.time(), nil) end
local function save(l) band.set_ext_json(band.SECTION, guestweb.KEY, l, true) end
local function find(gid) for _, g in ipairs(list()) do if g.gid == gid then return g end end end
local function tell(gid, text) S.said[gid] = { text = text, at = math.max(((S.said[gid] or {}).at or 0) + 1, os.time() * 1000) }; return text end
local function may_manage(cfg) return require("groups").may_manage(cfg.root, cfg.user) end

-- A new guest for this project and room. -> the link and words, or nil and why.
function guestweb.make(cfg, b, d, now)
  now = now or os.time()
  if not guestweb.available() then return nil, "this computer's StudioSync extension is older: update it for browser guests" end
  if not may_manage(cfg) then return nil, "only the owner or an admin can invite a browser guest" end
  local l = list()
  local ok, why = guestweb.may_make(S.stamps, #l, now)
  if not ok then return nil, why end
  local name = require("services").my_tailscale_name()
  local gid, code = band.secret(16), band.secret(24)
  local link = guestweb.link(name, code, guestweb.PORT)
  if not link then return nil, "Tailscale has no name for this computer (MagicDNS off?): a guest link needs it" end
  local session = math.floor((d.minutes or guestweb.SESSION / 60) * 60)
  if reaper.StudioSync_WebUIGuest(gid, code, guestweb.CODE_LIFE, session) ~= 1 then return nil, "the extension refused the guest (too many?)" end
  S.stamps[#S.stamps + 1] = now
  while #S.stamps > guestweb.MAKE_HOUR do table.remove(S.stamps, 1) end
  l[#l + 1] = { gid = gid, name = d.name, song = b.song, room = b.room or "main", by = cfg.user, made = now, ends = now + session }
  save(l)
  S.links[gid] = { link = link, until_at = now + guestweb.CODE_LIFE } -- (shown to the host until it's used or runs out; never saved)
  local phonerec = require("phonerec")
  if phonerec.auto_on() then pcall(phonerec.auto_link) end -- (the secure link set up, as the phone app does: in the background, with HTTPS certificates on)
  return link, string.format("a browser guest link for %s (%s, %s): works once within %d minutes, the session %d minutes%s", d.name, b.song,
    b.room or "main", guestweb.CODE_LIFE // 60, session // 60, phonerec.auto_on() and "" or " (the secure link is off in Settings > Advanced: set it up on the Record page)")
end
-- A guest ended (kicked, left, run out): the extension forgets them at once (socket, stream, cookie). -> words.
function guestweb.kick(gid, why)
  local out, g = {}, nil
  for _, x in ipairs(band.ext_json(band.SECTION, guestweb.KEY) or {}) do -- (as kept, run-out ones too: the one running out is found)
    if type(x) == "table" and x.gid == gid then g = x elseif type(x) == "table" and hex(x.gid, 16, 16) and (tonumber(x.ends) or 0) > os.time() then out[#out + 1] = x end
  end
  if reaper.StudioSync_WebUIGuest then reaper.StudioSync_WebUIGuest(gid, "", 0, 0) end
  S.links[gid], S.said[gid], S.take_at[gid] = nil, nil, nil
  if not g then return end
  save(out)
  return "browser guest " .. g.name .. " " .. (why or "ended")
end

-- Their own track, made at the end of the project when it isn't there (this computer's user's room rules decide, as for a phone's take).
local function guest_track(proj, cfg, b, name)
  local want = guestweb.track_name(name)
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    if select(2, reaper.GetTrackName(tr)) == want then return tr end
  end
  local can = require("sync").authority(cfg, b.song, b.room, band.read_json(band.session_path(cfg, b.song)))
  if not can(cfg.user, want, 0) then return nil, "this room's rules don't let " .. tostring(cfg.user) .. " add the guest's track" end
  reaper.Undo_BeginBlock2(proj)
  local n = reaper.CountTracks(proj)
  reaper.InsertTrackAtIndex(n, true)
  local tr = reaper.GetTrack(proj, n)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", want, true)
  reaper.Undo_EndBlock2(proj, "StudioSync: a browser guest's track", -1)
  return tr
end

local function guest_action(proj, cfg, b, gid, a)
  local g = find(gid)
  if not g then return end -- (ended meanwhile: what was queued is nothing now)
  local d = guestweb.parse_guest(gid, a)
  if not d then return end
  if d.leave then return guestweb.kick(gid, "left") end
  local t = d.take
  if t.cid and S.done[t.cid] then return tell(gid, S.done[t.cid] .. " (already in)") end
  local now = reaper.time_precise()
  if now - (S.take_at[gid] or -math.huge) < guestweb.TAKE_GAP then return tell(gid, "one take every " .. guestweb.TAKE_GAP .. " s: send it again") end
  S.take_at[gid] = now
  if g.song ~= b.song or (g.room or "main") ~= (b.room or "main") then return tell(gid, "the take waits: the host has another project or room in front (send it again later)") end
  local tr, why = guest_track(proj, cfg, b, g.name)
  if not tr then return tell(gid, "the take wasn't put in: " .. why) end
  local phonerec = require("phonerec")
  local said, ok = phonerec.put_with(proj, cfg, b, { id = t.id, track = reaper.GetTrackGUID(tr), t0 = t.t0, len = t.len, kind = "wav", name = g.name,
    err = t.err, song = g.song, title = t.title }, S.readings)
  said = tostring(said or ""):gsub("the phone's", "the guest's"):gsub("from a phone", "from a browser guest")
  if ok and t.cid then S.done[t.cid] = said end
  tell(gid, said)
  return "browser guest " .. g.name .. ": " .. said
end

-- An action from a page: a guest's (wrapped by the extension: a.gid, a.a) or the host's. -> words for the log, or nil.
function guestweb.action(proj, cfg, b, a)
  if type(a) ~= "table" then return end
  if a.gid ~= nil then return guest_action(proj, cfg, b, a.gid, a.a) end
  local d = guestweb.parse_host(a)
  if not d then return end
  if not may_manage(cfg) then return "only the owner or an admin can invite or end browser guests" end
  if d.make then
    local link, said = guestweb.make(cfg, b, d.make)
    S.last = link and { text = said, at = os.time() } or { text = said, at = os.time(), bad = true }
    return said
  end
  if d.kick then return guestweb.kick(d.kick, "ended by " .. tostring(cfg.user)) end
  if d.gain and find(d.gain.gid) and reaper.StudioSync_WebUIGuestGain then
    reaper.StudioSync_WebUIGuestGain(d.gain.gid, d.gain.v)
    local l = list()
    for _, g in ipairs(l) do if g.gid == d.gain.gid then g.gain = d.gain.v end end
    save(l)
  end
end

-- Each tick in front (lib/webui.lua): guests run out or gone from the extension ended, play readings while one is live, each guest's topic,
-- and the host's (guests, the link just made).
function guestweb.tick(proj, cfg, b, publish, now)
  if not guestweb.available() then return end
  local l = list()
  if now - (S.st_at or -math.huge) >= guestweb.STATUS_EVERY then
    S.st_at = now
    local st = require("webui").status()
    S.st = type(st.guests) == "table" and st.guests or {}
    local keep = guestweb.alive(band.ext_json(band.SECTION, guestweb.KEY), os.time(), S.st)
    if #keep ~= #(band.ext_json(band.SECTION, guestweb.KEY) or {}) then
      local on = {}
      for _, g in ipairs(keep) do on[g.gid] = true end
      for _, g in ipairs(band.ext_json(band.SECTION, guestweb.KEY) or {}) do
        if type(g) == "table" and hex(g.gid, 16, 16) and not on[g.gid] then band.log(guestweb.kick(g.gid, "ran out") or "") end
      end
      l = list()
    end
    for _, v in pairs(S.st) do if type(v) == "table" and v.live then S.live_at = now end end
  end
  local ps = reaper.GetPlayStateEx(proj)
  local t = reaper.StudioSync_DirectNow()
  local pos = ps & 1 == 1 and reaper.GetPlayPositionEx(proj) or reaper.GetCursorPositionEx(proj)
  local rate = reaper.Master_GetPlayRate(proj)
  if now - (S.live_at or -math.huge) < guestweb.READ_FOR then -- (where the song was on the link clock: a guest's take is placed by these)
    local phonerec = require("phonerec")
    if S.proj ~= proj then S.proj, S.readings = proj, {} end
    phonerec.add_reading(S.readings, t, pos, rate, ps & 1 == 1)
    if #S.readings > 2000 and S.readings[1].t < t - phonerec.KEEP then phonerec.prune(S.readings, t, phonerec.KEEP) end
  end
  if now - (S.pub_at or -math.huge) < guestweb.PUBLISH_EVERY then return end
  S.pub_at = now
  local outlat = reaper.GetOutputLatency and reaper.GetOutputLatency() or 0
  local _, srate = reaper.GetAudioDeviceInfo("SRATE")
  local host = {}
  for _, g in ipairs(l) do
    local here = g.song == b.song and (g.room or "main") == (b.room or "main")
    local said = S.said[g.gid] or {}
    publish("guest-" .. g.gid, { name = g.name, song = g.song, room = g.room, here = here or nil, host = g.by, ends = g.ends,
      playing = here and ps & 1 == 1 or nil, rec = here and ps & 4 == 4 or nil, pos = here and math.floor(pos * 1000 + 0.5) / 1000 or nil,
      at = here and t or nil, rate = here and rate or nil, bar = here and reaper.format_timestr_pos(pos, "", 2) or nil,
      outlat = math.floor((tonumber(outlat) or 0) * 10000 + 0.5) / 10000, srate = tonumber(srate), said = said.text, said_at = said.at })
    local s = S.st and S.st[g.gid] or {}
    local lk = S.links[g.gid]
    if lk and (s.redeemed or os.time() >= lk.until_at) then S.links[g.gid], lk = nil, nil end -- (used or run out: the link isn't shown again)
    host[#host + 1] = { gid = g.gid, name = g.name, song = g.song, room = g.room, ends = g.ends, by = g.by, here = here or nil,
      joined = s.redeemed or nil, live = s.live or nil, peak = s.peak, under = s.under, drops = s.drops, gain = g.gain or 1, link = lk and lk.link or nil }
  end
  publish("guestweb", { may = may_manage(cfg) or nil, ok = true, song = b.song, room = b.room or "main", guests = host, last = S.last,
    max = guestweb.MAX })
end

return guestweb
