-- Live to an audience (docs/rt/rt-audience.md; roadmap "Live to an audience" and "Listen from anywhere"): a link the band hands out that
-- plays the live session on a web page (a phone, a client, a bandmate away from REAPER), and the song's latest bounced mix when nobody plays.
-- The extension does the audio (extension/audience.cpp): the session mix (this computer's REAPER output with every bandmate live audio hears,
-- the hub's mix when it hears through one) Opus-encoded once and sent to every listener; this file makes and revokes the links, tells
-- listeners the song, who's playing and whether it's live, offers the latest mix, and keeps the owner's public switch.
--  * Tailnet links (on by themselves for the owner and admins): https://<this computer>:8443/listen/?l=<code>, the studio's secure phone link
--    (`tailscale serve`), so only the studio's tailnet reaches them, as the phone app.
--  * Public links (OFF unless the owner turns on "Public links" and confirms the warning; the same switch opens public guest links, lib/guestweb.lua): `tailscale funnel` puts a port of the
--    extension's own on the open internet, https://<this computer>:10000/listen/?l=<code>. That port serves the listening page, its script and
--    style, the live socket and the latest mix, nothing else, and only to public links; listeners there are told the song and whether it's
--    live, never names. It turns itself off after PUBLIC_HOURS, and turning it off revokes every public link.
-- Links run out (HOURS, up to HOURS_MAX), can be revoked at once, and are kept on this computer (ExtState) so they survive a REAPER restart.
local band = require("band")
local audience = {}
audience.CAP, audience.CAP_MAX = 20, 100   -- listeners at once (the extension refuses past 100)
audience.KBPS = 96                         -- Opus's rate: ~100 kbit/s up per listener from this computer (measured: tests/audience_test.cpp)
audience.HOURS, audience.HOURS_MAX = 4, 7 * 24
audience.MAX_LINKS = 4                     -- links at a time (the extension takes 8)
audience.MAKE_GAP, audience.MAKE_HOUR = 5, 12 -- seconds between links, links an hour
audience.PUBLIC_PORT = 47320               -- the public listener, 127.0.0.1 only (no firewall rule): `tailscale funnel` forwards to it
audience.FUNNEL_PORT = 10000               -- Funnel's https port (Funnel takes 443, 8443 or 10000: 8443 is the phone link's, 443 often taken)
audience.PUBLIC_HOURS = 6                  -- the public switch turns itself off after this
audience.TAILNET_PORT = 8443               -- the secure phone link's port (lib/phonerec.lua HTTPS_PORT)
audience.KEY, audience.PUB_KEY = "audience links", "audience public"
-- (one switch, "Public links", for public listening links and public guest links: rt-guestnet, James 2026-11-27)
audience.WARNING = "Public links put a port of this computer on the open internet through Tailscale Funnel. Anyone with a public listening " ..
  "link hears the session live (everything this computer hears, bandmates included) and the song's latest mix, and sees the song's name. " ..
  "Anyone with a public guest link also joins the session from a browser: they hear it, the band hears them, and their takes go onto their " ..
  "own track. It serves nothing else (no files, chat, controls or studio pages), and only public links open it. This computer's address " ..
  "(<name>.ts.net) becomes public. It turns itself off after " .. audience.PUBLIC_HOURS .. " hours, and turning it off ends every public link and guest."

-- ---- pure -------------------------------------------------------------------------------------------------------------------------------
local function hex(v, lo, hi) return type(v) == "string" and #v >= lo and #v <= hi and v:match("^[0-9a-f]+$") ~= nil end
local function num(v, lo, hi) v = tonumber(v); return v and v == v and v >= lo and v <= hi and v or nil end
-- A listening link: this computer's MagicDNS name on a port. nil from a bad name or code.
function audience.url(name, code, port)
  if type(name) ~= "string" or not hex(code, 32, 64) then return nil end
  name = name:gsub("%.$", "")
  if not name:match("^[%w][%w%.%-]*$") then return nil end
  return "https://" .. name .. ":" .. math.floor(tonumber(port) or audience.TAILNET_PORT) .. "/listen/?l=" .. code
end
-- A host page's action -> { make = { hours, public }, revoke = id, cap = n, kbps = n, public = { on, sure } }, checked. Pure.
function audience.parse(a)
  if type(a) ~= "table" then return nil end
  local out = {}
  if type(a.make) == "table" then out.make = { hours = num(a.make.hours, 0.25, audience.HOURS_MAX), public = a.make.public == true or nil } end
  if hex(a.revoke, 16, 16) then out.revoke = a.revoke end
  out.cap = num(a.cap, 1, audience.CAP_MAX) and math.floor(num(a.cap, 1, audience.CAP_MAX)) or nil
  out.kbps = num(a.kbps, 32, 256) and math.floor(num(a.kbps, 32, 256)) or nil
  if type(a.public) == "table" and type(a.public.on) == "boolean" then out.public = { on = a.public.on, sure = a.public.sure == true } end
  return next(out) and out or nil
end
-- The links still on. Pure.
function audience.alive(list, now)
  local out = {}
  for _, k in ipairs(type(list) == "table" and list or {}) do
    if type(k) == "table" and hex(k.id, 16, 16) and hex(k.code, 32, 64) and (tonumber(k.ends) or 0) > now then out[#out + 1] = k end
  end
  return out
end
-- May another link be made now? -> true, or false and why. Pure.
function audience.may_make(stamps, n, now)
  if n >= audience.MAX_LINKS then return false, audience.MAX_LINKS .. " listening links already: revoke one first" end
  local hour = 0
  for _, t in ipairs(stamps) do
    if now - t < audience.MAKE_GAP then return false, "one listening link every " .. audience.MAKE_GAP .. " s" end
    if now - t < 3600 then hour = hour + 1 end
  end
  if hour >= audience.MAKE_HOUR then return false, audience.MAKE_HOUR .. " listening links an hour at most" end
  return true
end
-- What listeners are told: the tailnet's (song, live, who's playing, the mix's name) and the public port's (song and live, and whether there's
-- a mix: never a name). -> two JSON texts under 2 KB. Pure.
function audience.info(song, live, who, mix)
  song = tostring(song or ""):gsub("[%c]", " "):sub(1, 120)
  local names = {}
  for _, n in ipairs(type(who) == "table" and who or {}) do if #names < 12 then names[#names + 1] = tostring(n):gsub("[%c]", " "):sub(1, 40) end end
  local m = mix and tostring(mix):gsub("[%c]", " "):sub(1, 120) or nil
  return band.json_encode({ song = song, live = live and true or false, who = names, mix = m }),
    band.json_encode({ song = song, live = live and true or false, mix = m and true or false })
end
-- Is the band playing? This computer's transport playing or recording, or a bandmate live audio hears making sound. Pure.
function audience.playing(play_state, la)
  if (tonumber(play_state) or 0) & 5 ~= 0 then return true end
  for _, p in pairs(type(la) == "table" and type(la.peers) == "table" and la.peers or {}) do
    if type(p) == "table" and p.streaming and math.max(tonumber(p.level) or 0, tonumber(p.play_level) or 0) > 0.003 then return true end
  end
  return false
end
-- Who's playing, by name: this computer's user while it plays or sends, each bandmate heard making sound, and (rt-p11, backlog 1.21) each
-- bandmate whose own status says their transport plays or records (sts: lib/presence.lua peers), so a bandmate playing counts while this
-- computer's live audio is off. Pure.
function audience.who(me, me_on, la, name_of, sts)
  local out, seen = {}, {}
  if me_on and me then out[#out + 1] = me; seen[me] = true end
  local peers = {}
  for peer, p in pairs(type(la) == "table" and type(la.peers) == "table" and la.peers or {}) do
    if type(p) == "table" and p.streaming and math.max(tonumber(p.level) or 0, tonumber(p.play_level) or 0) > 0.003 then
      local n = name_of(peer)
      if n and not seen[n] then peers[#peers + 1] = n; seen[n] = true end
    end
  end
  for _, n in ipairs(audience.band_playing(sts)) do if not seen[n] then peers[#peers + 1] = n; seen[n] = true end end
  table.sort(peers)
  for _, n in ipairs(peers) do out[#out + 1] = n end
  return out
end
-- Bandmates whose status (their status file or its link copy: lib/presence.lua peers, fresh ones only) says their transport plays or
-- records. -> their names. Pure.
function audience.band_playing(sts)
  local out = {}
  for _, st in ipairs(type(sts) == "table" and sts or {}) do
    if type(st) == "table" and type(st.user) == "string" and (st.playing == true or st.recording == true) then out[#out + 1] = st.user end
  end
  return out
end
-- How long a link works, in words: minutes under an hour (a 15-minute link said "0 hours"), else hours. Pure.
function audience.span(secs)
  secs = math.floor(tonumber(secs) or 0)
  if secs < 3600 then local m = math.max(1, (secs + 30) // 60); return m .. (m == 1 and " minute" or " minutes") end
  if secs % 3600 == 0 then return secs // 3600 .. (secs == 3600 and " hour" or " hours") end
  return string.format("%.1f hours", secs / 3600)
end
-- Tailscale's arguments for the public port. Pure.
function audience.funnel_args(on)
  if on then return "funnel --bg --yes --https=" .. audience.FUNNEL_PORT .. " http://127.0.0.1:" .. audience.PUBLIC_PORT end
  return "funnel --https=" .. audience.FUNNEL_PORT .. " off"
end

-- ---- REAPER -----------------------------------------------------------------------------------------------------------------------------
function audience.available()
  return reaper.StudioSync_AudienceStart ~= nil and reaper.StudioSync_AudienceLink ~= nil and reaper.StudioSync_AudienceInfo ~= nil and reaper.StudioSync_AudienceStatus ~= nil
end
local S = { stamps = {} }
function audience.reset() S = { stamps = {} } end -- (tests)
local function list() return audience.alive(band.ext_json(band.SECTION, audience.KEY), os.time()) end
local function save(l) band.set_ext_json(band.SECTION, audience.KEY, l, true) end
local function may_manage(cfg) return require("groups").may_manage(cfg.root, cfg.user) end
local function is_owner(cfg) return require("groups").role(cfg.root, cfg.user) == "owner" end
local function setting(k, d, lo, hi) return num(reaper.GetExtState(band.SECTION, "audience " .. k), lo, hi) or d end
function audience.public_on()
  local p = band.ext_json(band.SECTION, audience.PUB_KEY)
  return type(p) == "table" and (tonumber(p["until"]) or 0) > os.time() and p or nil
end
local function status()
  local ok, st = pcall(band.json_decode, reaper.StudioSync_AudienceStatus())
  return ok and type(st) == "table" and st or {}
end
local function start()
  local pub = audience.public_on()
  return reaper.StudioSync_AudienceStart(require("webui").folder(), math.floor(setting("cap", audience.CAP, 1, audience.CAP_MAX)),
    math.floor(setting("kbps", audience.KBPS, 32, 256)), pub and audience.PUBLIC_PORT or 0)
end
local function left(k) return math.max(1, math.floor((tonumber(k.ends) or 0) - os.time())) end

-- A new listening link. -> its address and words, or nil and why.
function audience.make(cfg, d, now)
  now = now or os.time()
  if not audience.available() then return nil, "this computer's StudioSync extension is older: update it for listening links" end
  if not may_manage(cfg) then return nil, "only the owner or an admin can make a listening link" end
  if d.public and not audience.public_on() then return nil, "a public link needs Public links on first (the owner's switch)" end
  local l = list()
  local ok, why = audience.may_make(S.stamps, #l, now)
  if not ok then return nil, why end
  local name = require("services").my_tailscale_name()
  local id, code = band.secret(16), band.secret(32)
  local url = audience.url(name, code, d.public and audience.FUNNEL_PORT or audience.TAILNET_PORT)
  if not url then return nil, "Tailscale has no name for this computer (MagicDNS off?): a listening link needs it" end
  local secs = math.floor((d.hours or audience.HOURS) * 3600)
  start()
  if reaper.StudioSync_AudienceLink(id, code, secs, d.public and 1 or 0) ~= 1 then return nil, "the extension refused the link (too many?)" end
  S.stamps[#S.stamps + 1] = now
  while #S.stamps > audience.MAKE_HOUR do table.remove(S.stamps, 1) end
  l[#l + 1] = { id = id, code = code, ends = now + secs, pub = d.public or nil, by = cfg.user, made = now }
  save(l)
  if not d.public then
    local phonerec = require("phonerec")
    if phonerec.auto_on() then pcall(phonerec.auto_link) end -- (the secure link set up, as the phone app and guest links do)
  end
  return url, string.format("a %s listening link for %s", d.public and "PUBLIC" or "tailnet", audience.span(secs))
end
-- A link revoked: its listeners are closed at once. -> words.
function audience.revoke(id, why)
  local out, k = {}, nil
  for _, x in ipairs(band.ext_json(band.SECTION, audience.KEY) or {}) do
    if type(x) == "table" and x.id == id then k = x elseif type(x) == "table" and hex(x.id, 16, 16) and (tonumber(x.ends) or 0) > os.time() then out[#out + 1] = x end
  end
  if reaper.StudioSync_AudienceLink then reaper.StudioSync_AudienceLink(id, "", 0, 0) end
  if not k then return end
  save(out)
  return "listening link " .. id:sub(1, 6) .. " " .. (why or "revoked")
end
-- The owner's public switch. on needs sure (the page showed the warning). -> words.
function audience.set_public(cfg, on, sure)
  if not is_owner(cfg) then return nil, "only the studio's owner can turn Public links on or off" end
  local services = require("services")
  if on then
    if not sure then return nil, "turning Public links on needs the warning confirmed" end
    if not audience.available() then return nil, "this computer's StudioSync extension is older: update it first" end
    if not services.tailscale_exe() then return nil, "Tailscale isn't installed on this computer" end
    band.set_ext_json(band.SECTION, audience.PUB_KEY, { ["until"] = os.time() + audience.PUBLIC_HOURS * 3600, by = cfg.user }, true)
    if start() ~= 1 then
      reaper.DeleteExtState(band.SECTION, audience.PUB_KEY, true); start()
      return nil, "the public port (127.0.0.1:" .. audience.PUBLIC_PORT .. ") couldn't be opened: " .. tostring(status().public_error)
    end
    local r = services.ts_exec(audience.funnel_args(true), 15000)
    if not r:match("^0\n") then
      reaper.DeleteExtState(band.SECTION, audience.PUB_KEY, true); start()
      return nil, "Tailscale didn't open Funnel (the tailnet's admin has to allow Funnel for this computer, and HTTPS certificates must be on): " ..
        r:gsub("^%d+\n", ""):sub(1, 300)
    end
    return "PUBLIC links are on for " .. audience.PUBLIC_HOURS .. " hours (Tailscale Funnel, port " .. audience.FUNNEL_PORT .. "): listening and guests"
  end
  return audience.public_off("off")
end
-- Public links off (anyone's turning off is safe: the owner's switch, or its time run out): Funnel closed, the port shut, every public
-- listening link revoked and every public guest ended (lib/guestweb.lua; the extension ends them too as the port shuts). -> words.
function audience.public_off(why)
  -- (public guests first: each live page is told its session ended before Funnel cuts the connection, so it doesn't keep reconnecting)
  local ok, n = pcall(function() return require("guestweb").end_public("ended (Public links " .. why .. ")") end)
  require("services").ts_exec(audience.funnel_args(false), 10000)
  reaper.DeleteExtState(band.SECTION, audience.PUB_KEY, true)
  for _, k in ipairs(list()) do if k.pub then audience.revoke(k.id, "revoked (Public links " .. why .. ")") end end
  if audience.available() then start() end
  return "Public links are " .. why .. "; every public link revoked" .. (ok and (tonumber(n) or 0) > 0 and ", " .. n .. " public guest" .. (n == 1 and "" or "s") .. " ended" or "")
end

function audience.action(proj, cfg, b, a)
  local d = audience.parse(a)
  if not d then return end
  if not may_manage(cfg) then return "only the owner or an admin can manage listening links" end
  local said, bad
  if d.public then said, bad = audience.set_public(cfg, d.public.on, d.public.sure)
  elseif d.make then
    local url
    url, said = audience.make(cfg, d.make)
    if not url then bad = said; said = nil end
  elseif d.revoke then said = audience.revoke(d.revoke, "revoked by " .. tostring(cfg.user))
  else
    if d.cap then reaper.SetExtState(band.SECTION, "audience cap", tostring(d.cap), true) end
    if d.kbps then reaper.SetExtState(band.SECTION, "audience kbps", tostring(d.kbps), true) end
    if audience.available() then start() end
    said = "listening: at most " .. math.floor(setting("cap", audience.CAP, 1, audience.CAP_MAX)) .. " listeners, " .. math.floor(setting("kbps", audience.KBPS, 32, 256)) .. " kbit/s"
  end
  S.last = { text = said or bad, bad = bad and true or nil, at = os.time() }
  return said or bad
end

-- The song's newest bounced mix (<Song>/mixes, renders named by date). -> path, file name; or nil.
local function latest_mix(cfg, song)
  local dir, best = band.song_dir(cfg, song) .. "/mixes", nil
  for _, f in ipairs(band.files(dir)) do
    if require("listen").AUDIO[(f:match("%.([^.]+)$") or ""):lower()] and not f:find("^%.") and (not best or f > best) then best = f end
  end
  if best then return dir .. "/" .. best, best end
end

-- Each tick in front (lib/webui.lua): the extension started with the settings, run-out links and the public switch ended, links it forgot
-- (REAPER restarted) given back, what listeners are told, and the host's topic.
function audience.tick(proj, cfg, b, publish, now)
  if not audience.available() then return end
  if now - (S.at or -math.huge) < 1 then return end
  S.at = now
  local pub = audience.public_on()
  local raw = band.ext_json(band.SECTION, audience.PUB_KEY)
  if not pub and raw ~= nil then band.log(audience.public_off("off: its " .. audience.PUBLIC_HOURS .. " hours ran out")) end
  local l = list()
  local all = band.ext_json(band.SECTION, audience.KEY)
  if type(all) == "table" and #all ~= #l then
    for _, k in ipairs(all) do if type(k) == "table" and hex(k.id, 16, 16) and (tonumber(k.ends) or 0) <= os.time() then reaper.StudioSync_AudienceLink(k.id, "", 0, 0) end end
    save(l)
  end
  start()
  local st = status()
  local known = type(st.links) == "table" and st.links or {}
  for _, k in ipairs(l) do
    if not known[k.id] and (not k.pub or pub) then reaper.StudioSync_AudienceLink(k.id, k.code, left(k), k.pub and 1 or 0) end
  end
  -- what listeners are told
  local lok, la = pcall(require("liveaudio").status)
  la = lok and type(la) == "table" and la or {}
  local ps = math.floor(tonumber(reaper.GetPlayStateEx(proj)) or 0)
  local pok, sts = pcall(require("presence").peers, cfg, b.song, b.room or "main")
  sts = pok and type(sts) == "table" and sts or {}
  local live = audience.playing(ps, la) or #audience.band_playing(sts) > 0 -- (a bandmate playing counts, live audio on or off: rt-p11)
  local names = require("liveaudio").names()
  local who = audience.who(cfg.user, ps & 5 ~= 0, la, function(p) return require("liveaudio").name_of(p, names) end, sts)
  local mpath, mname = latest_mix(cfg, b.song)
  local full, pubj = audience.info(b.song, live, who, mname)
  reaper.StudioSync_AudienceInfo(full, pubj, mpath or "")
  -- the host's view
  local name = require("services").my_tailscale_name()
  local links = {}
  for _, k in ipairs(l) do
    local x = known[k.id] or {}
    links[#links + 1] = { id = k.id, url = audience.url(name, k.code, k.pub and audience.FUNNEL_PORT or audience.TAILNET_PORT), ends = k.ends,
      pub = k.pub or nil, by = k.by, n = tonumber(x.n) or 0 }
  end
  publish("audience", { may = may_manage(cfg) or nil, owner = is_owner(cfg) or nil, ok = true, song = b.song, live = live, who = who, mix = mname,
    links = links, listeners = tonumber(st.listeners) or 0, public_listeners = tonumber(st.public) or 0,
    cap = math.floor(setting("cap", audience.CAP, 1, audience.CAP_MAX)), kbps = math.floor(setting("kbps", audience.KBPS, 32, 256)),
    enc_load = tonumber(st.enc_load), out_kbps = tonumber(st.out_kbps), refused = tonumber(st.refused), limited = tonumber(st.limited),
    public = pub and { ["until"] = pub["until"], by = pub.by, err = st.public_error ~= "" and st.public_error or nil } or nil,
    warning = audience.WARNING, last = S.last, max = audience.MAX_LINKS, cap_max = audience.CAP_MAX })
end

return audience
