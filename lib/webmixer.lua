-- The web UI's Mixer page, the shared DAW view's stage 4 (docs/realtime-roadmap.md "Shared DAW view"; the page is lib/webui/mixer.js): the
-- studio's tracks as channel strips (volume, pan, mute, solo, a meter, the plug-ins with their bypass, the sends with their levels), the
-- master read only (each listener's own level), and your monitor mix of everyone's live audio. Plug-in windows stay in REAPER. Topics, built
-- only while a page shows the Mixer (it says so every 10 s; WANT_FOR s grace) and published only when they changed:
--   mix     the strips, STRIPS_EVERY s apart
--   mixm    each strip's peak and the master's in dB (REAPER's track meters, Track_GetPeakInfo), METER_EVERY s apart
--   mixmon  Everyone and each bandmate's Talk and Play volumes and levels (lib/liveaudio.lua's cue mix: only what you hear)
--   mixr    the last move's answer ({ id, ok | why }): a refused move snaps back on the page with why
-- A move is checked as lib/dawedit.lua checks an edit on a track (the room's rule for the track, or its maker's while nobody claimed it), or
-- not at all when it's only yours (solo, and faders and pan under Local mixing), then set here. Volume, pan and mute go through
-- controllers.web_move as moves of yours, so bandmates see them move live and a bandmate already moving that control keeps it; plug-in bypass
-- and send levels go with the normal sync only (Shared controllers don't stream them), and the normal sync confirms everything. A drag's last
-- move (done) makes one undo point, as REAPER's own fader does. (James, rt)
local band = require("band")
local webmixer = {}
webmixer.WANT_FOR = 30        -- seconds a page's "I'm looking at the Mixer" lasts (pages say it every 10 s)
webmixer.STRIPS_EVERY = 0.25  -- seconds between strip builds (a bandmate's fader moving shows)
webmixer.METER_EVERY = 0.1    -- seconds between meter readings (10 a second: REAPER's own meters decay, so nothing is missed between)
webmixer.MON_EVERY = 0.25     -- seconds between monitor mix builds (its levels move)
webmixer.AUTH_EVERY = 1       -- seconds between asking sync.authority who may change what (it reads the claims files)
webmixer.NAME_MAX = 40        -- characters of a track, plug-in or send name
webmixer.FX_MAX = 32          -- plug-ins shown per track
webmixer.SENDS_MAX = 16       -- sends shown per track
webmixer.reply = nil          -- the last move's answer

-- ---- pure ------------------------------------------------------------------------------------------------------------------------------
local function num(x, lo, hi) x = tonumber(x); return x and x == x and x >= lo and x <= hi and x or nil end
local function int(x, hi) x = tonumber(x); return x and x >= 0 and x <= hi and math.floor(x) == x and math.floor(x) or nil end
local function oid(x) return type(x) == "string" and #x <= 80 and x:match("^T%-[%w%-_]+$") and x or nil end
local function short(s) s = tostring(s or ""); return utf8.len(s) and utf8.len(s) > webmixer.NAME_MAX and s:sub(1, utf8.offset(s, webmixer.NAME_MAX + 1) - 1) .. "…" or s end
webmixer.short = short
-- A peak (linear, 1 = 0 dBFS) -> whole dB, -60 (silence) to +12.
function webmixer.db(p)
  p = tonumber(p) or 0
  if p <= 0.001 then return -60 end
  return math.max(-60, math.min(12, math.floor(20 * math.log(p, 10) + 0.5)))
end
local SET = { v = { 0, 16 }, p = { -1, 1 }, m = { 0, 1 }, s = { 0, 1 } } -- (volume up to +24 dB, as controllers.clean takes it)
-- An action a page sent ({ topic = "mixer", ... }: a trust boundary, a phone with the studio's token is one) -> what it asks for, checked:
-- { want, off, id, set = { o, k, v, done } | fx = { o, i, name, on } | send = { o, i, to, v, done } | mon = { peer, talk, play, mute } | all },
-- or nil and why.
function webmixer.parse(a)
  if type(a) ~= "table" then return nil, "not a move" end
  local out = { want = a.want == true or nil, off = a.want == false or nil,
    id = type(a.id) == "string" and #a.id <= 40 and a.id:match("^[%w%-]+$") and a.id or nil }
  if type(a.set) == "table" then
    local s, lim = a.set, SET[a.set.k]
    local v = lim and num(s.v, lim[1], lim[2])
    if not (oid(s.o) and v) then return nil, "not a control the page showed", out.id end
    out.set = { o = s.o, k = s.k, v = (s.k == "m" or s.k == "s") and (v >= 0.5 and 1 or 0) or v, done = s.done == true }
  elseif type(a.fx) == "table" then
    local f = a.fx
    if not (oid(f.o) and int(f.i, 1023) and type(f.name) == "string" and #f.name <= 400) then return nil, "not a plug-in the page showed", out.id end
    out.fx = { o = f.o, i = int(f.i, 1023), name = f.name, on = f.on == true }
  elseif type(a.send) == "table" then
    local s = a.send
    if not (oid(s.o) and int(s.i, 255) and oid(s.to) and num(s.v, 0, 16)) then return nil, "not a send the page showed", out.id end
    out.send = { o = s.o, i = int(s.i, 255), to = s.to, v = num(s.v, 0, 16), done = s.done == true }
  elseif type(a.mon) == "table" then
    local m = a.mon
    if type(m.peer) ~= "string" or #m.peer > 200 then return nil, "not a bandmate the page showed", out.id end
    out.mon = { peer = m.peer, talk = num(m.talk, 0, 4), play = num(m.play, 0, 4) }
    if type(m.mute) == "boolean" then out.mon.mute = m.mute end
  elseif a.all ~= nil then
    out.all = num(a.all, 0, 4)
    if not out.all then return nil, "not a volume", out.id end
  end
  return out
end

-- ---- reading REAPER --------------------------------------------------------------------------------------------------------------------
local function tname(tr) return select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)) end
local function local_mix(proj) return select(2, reaper.GetProjExtState(proj, band.SECTION, "local_mix")) == "1" end
local function r4(x) return math.floor((tonumber(x) or 0) * 10000 + 0.5) / 10000 end
-- The strips: the studio's tracks as the Song page shows them (dawview.shown), each by its oid (a track with none yet shows after the next
-- look). This computer's own plug-ins (translations, drum maps, live hops) and those running on a bandmate's (Shared CPU) show but can't be
-- toggled here (x); sends to this computer's own tracks (the live out track) don't show. may(tr, name, oid) -> nil, or why not.
function webmixer.read(proj, may)
  local dawview, mirror, controllers = require("dawview"), require("mirror"), require("controllers")
  local out = {}
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    local o = dawview.shown(tr) and mirror.track_oid(tr) or ""
    if o ~= "" then
      local name = tname(tr)
      local why = may and may(tr, name, o)
      local s = { o = o, name = short(name), rgb = dawview.native_rgb(band.track_colour(tr)), v = r4(reaper.GetMediaTrackInfo_Value(tr, "D_VOL")),
        p = r4(reaper.GetMediaTrackInfo_Value(tr, "D_PAN")), m = reaper.GetMediaTrackInfo_Value(tr, "B_MUTE") ~= 0 or nil,
        s = reaper.GetMediaTrackInfo_Value(tr, "I_SOLO") ~= 0 or nil, why = why, fx = {}, sends = {} }
      local lfx, guids = band.track_ext(tr, "band_local_fx"), {}
      local held = {}
      for g in lfx:gmatch("({[^}]+})held=") do held[g] = true end
      local n = reaper.TrackFX_GetCount(tr)
      for k = 0, n - 1 do guids[#guids + 1] = reaper.TrackFX_GetFXGUID(tr, k) end
      for k = 0, math.min(n, webmixer.FX_MAX) - 1 do
        local own = controllers.band_fx(guids, lfx, k) == nil or held[guids[k + 1]]
        s.fx[#s.fx + 1] = { i = k, n = short(select(2, reaper.TrackFX_GetFXName(tr, k, ""))), on = reaper.TrackFX_GetEnabled(tr, k) or nil, x = own or nil }
      end
      for k = 0, reaper.GetTrackNumSends(tr, 0) - 1 do
        if #s.sends >= webmixer.SENDS_MAX then break end
        local dest = reaper.GetTrackSendInfo_Value(tr, 0, k, "P_DESTTRACK")
        local to = dest and type(dest) ~= "number" and not mirror.local_track(dest) and mirror.track_oid(dest) or ""
        if to ~= "" then
          s.sends[#s.sends + 1] = { i = k, to = to, name = short(tname(dest)), v = r4(reaper.GetTrackSendInfo_Value(tr, 0, k, "D_VOL")),
            m = reaper.GetTrackSendInfo_Value(tr, 0, k, "B_MUTE") ~= 0 or nil }
        end
      end
      out[#out + 1] = s
    end
  end
  return out
end
local function find(proj, o)
  local dawview, mirror = require("dawview"), require("mirror")
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    if dawview.shown(tr) and mirror.track_oid(tr) == o then return tr end
  end
end
-- The monitor mix: { on, all (Everyone, linear), play (Play volumes exist), peers = { { peer, name, talk, play, mute, lt, lp, live } } }.
function webmixer.monitor(cfg)
  local la = require("liveaudio")
  if not (la.enabled(cfg.root) and la.available()) then return { on = false } end
  local st, names, mix, s = la.status(), la.names(), la.mix(), la.me()
  local out = { on = true, running = st.running == true or nil, all = r4(s.volume or 1), play = la.can_play() or nil, peers = {} }
  for peer, p in pairs(type(st.peers) == "table" and st.peers or {}) do
    if type(p) == "table" then
      local name = la.name_of(peer, names)
      local want = mix[name] or mix[peer] or {}
      out.peers[#out.peers + 1] = { peer = peer, name = name, talk = r4(tonumber(want.gain) or 1), play = r4(tonumber(want.play) or 1),
        mute = want.mute == true or nil, lt = webmixer.db(p.level), lp = webmixer.db(p.play_level), live = p.streaming == true or nil }
    end
  end
  table.sort(out.peers, function(x, y) return x.name:lower() < y.name:lower() end)
  return out
end

-- ---- applying a move ---------------------------------------------------------------------------------------------------------------------
local WORD = { v = "volume", p = "pan", m = "mute", s = "solo" }
local S = { want_until = -math.huge, at = {}, auth_at = -math.huge }
webmixer.state = S -- (tests)
-- Who may change what (sync.authority with the session's region claims, as lib/dawedit.lua asks it; at most every AUTH_EVERY s).
-- -> may(tr, name, oid): nil, or why not.
local function rules(cfg, b, now)
  if now - S.auth_at >= webmixer.AUTH_EVERY or not S.can then
    S.auth_at = now
    S.can, S.who = require("sync").authority(cfg, b.song, b.room, band.read_json(band.session_path(cfg, b.song))) -- (the session's regions: region claims hold)
  end
  local can, who = S.can, S.who
  return function(_, name, o) return require("dawedit").item_refusal(can, who, cfg.user, name, o, nil, nil) end
end
local function undo_point(proj, label) reaper.Undo_OnStateChangeEx2(proj, "StudioSync web page: " .. label, 1, -1) end
-- -> nil when done, or why not.
local function apply(proj, cfg, b, d, now)
  if d.mon then
    local la = require("liveaudio")
    local st = la.status()
    if not (type(st.peers) == "table" and st.peers[d.mon.peer]) then return "that bandmate isn't heard here now" end
    local want = la.mix()[la.name_of(d.mon.peer)] or la.mix()[d.mon.peer] or {}
    local mute = d.mon.mute
    if mute == nil then mute = want.mute == true end
    la.set_peer(d.mon.peer, d.mon.talk or tonumber(want.gain) or 1, mute, d.mon.play)
    return
  end
  if d.all then require("liveaudio").set_volume(d.all); return end
  local c = d.set or d.fx or d.send
  if not c then return end
  local tr = find(proj, c.o)
  if not tr then return "that track changed meanwhile" end
  local name = tname(tr)
  if d.set and d.set.k == "s" then -- (solo is each person's own: never sent, nothing to check)
    reaper.SetMediaTrackInfo_Value(tr, "I_SOLO", d.set.v == 1 and 2 or 0) -- (solo in place)
    return
  end
  local may = rules(cfg, b, now)
  local mine = d.set and d.set.k ~= "m" and local_mix(proj) -- (Local mixing: your faders and pan stay yours, so anyone's are yours to move)
  local why = not mine and may(tr, name, c.o)
  if why then return why end
  if d.set then
    local held = require("controllers").web_move(proj, cfg, tr, d.set.k, d.set.v)
    if held then return held .. " right now" end
    if d.set.done then undo_point(proj, name .. " " .. WORD[d.set.k]) end
    return
  end
  if d.fx then
    local lfx, guids = band.track_ext(tr, "band_local_fx"), {}
    for k = 0, reaper.TrackFX_GetCount(tr) - 1 do guids[#guids + 1] = reaper.TrackFX_GetFXGUID(tr, k) end
    local fxname = guids[d.fx.i + 1] and select(2, reaper.TrackFX_GetFXName(tr, d.fx.i, ""))
    if short(fxname) ~= d.fx.name then return "that plug-in changed meanwhile" end
    if require("controllers").band_fx(guids, lfx, d.fx.i) == nil or lfx:find(guids[d.fx.i + 1] .. "held=", 1, true) then
      return "that plug-in is this computer's own, or runs on a bandmate's: change it in REAPER"
    end
    reaper.TrackFX_SetEnabled(tr, d.fx.i, d.fx.on)
    undo_point(proj, (d.fx.on and "enable " or "bypass ") .. fxname)
    return
  end
  -- a send: it lives on the track it goes to (the receive is that track's object in the sync), so that's the one checked too
  local dest = d.send.i < reaper.GetTrackNumSends(tr, 0) and reaper.GetTrackSendInfo_Value(tr, 0, d.send.i, "P_DESTTRACK")
  if not (dest and type(dest) ~= "number" and require("mirror").track_oid(dest) == d.send.to) then return "that send changed meanwhile" end
  why = may(dest, tname(dest), d.send.to)
  if why then return why end
  reaper.SetTrackSendInfo_Value(tr, 0, d.send.i, "D_VOL", d.send.v)
  if d.send.done then undo_point(proj, name .. " send to " .. tname(dest)) end
end

-- An action a page sent (lib/webui.lua). -> words for the log, or nil (a drag's moves aren't logged; a refusal is, once a drag).
function webmixer.action(proj, cfg, b, a)
  local d, why, id = webmixer.parse(a)
  local now = reaper.time_precise()
  if d then
    id = d.id
    if d.want then S.want_until = now + webmixer.WANT_FOR end
    if d.off then S.want_until = -math.huge end
    if not (d.set or d.fx or d.send or d.mon or d.all) then return end
    why = apply(proj, cfg, b, d, now)
  end
  webmixer.reply = { id = id, ok = not why or nil, why = why }
  if why and why ~= S.said then S.said = why; return "the web page's mixer move wasn't made: " .. why end
  if not why then S.said = nil end
end

-- Each tick in front, while a page looks (lib/webui.lua). publish(topic, table) sends only what changed.
function webmixer.tick(proj, cfg, b, publish, now)
  if now >= S.want_until then S.can = nil; return end
  if webmixer.reply then publish("mixr", webmixer.reply) end
  if now - (S.at.strips or -math.huge) >= webmixer.STRIPS_EVERY then
    S.at.strips = now
    local theirs = {} -- (a bandmate moving a control right now: lib/controllers.lua's holds, by "oid|k")
    for key, th in pairs(require("controllers").state.theirs) do if not th.g then theirs[key] = th.user end end
    local strips = webmixer.read(proj, rules(cfg, b, now))
    S.tracks = {} -- (the meters read these tracks till the next build, not every track's flags again)
    for i = 0, reaper.CountTracks(proj) - 1 do
      local tr = reaper.GetTrack(proj, i)
      local o = require("dawview").shown(tr) and require("mirror").track_oid(tr) or ""
      if o ~= "" then S.tracks[#S.tracks + 1] = { tr, o } end
    end
    for _, s in ipairs(strips) do
      for k in pairs(WORD) do if theirs[s.o .. "|" .. k] then s.by = s.by or {}; s.by[k] = theirs[s.o .. "|" .. k] end end
    end
    local m = reaper.GetMasterTrack(proj)
    publish("mix", { song = b.song, me = cfg.user, local_mix = local_mix(proj) or nil, strips = strips,
      master = { v = r4(reaper.GetMediaTrackInfo_Value(m, "D_VOL")) } })
  end
  if now - (S.at.meters or -math.huge) >= webmixer.METER_EVERY then
    S.at.meters = now
    local peaks = {}
    for _, t in ipairs(S.tracks or {}) do
      local tr = t[1]
      if reaper.ValidatePtr2(proj, tr, "MediaTrack*") then peaks[t[2]] = webmixer.db(math.max(reaper.Track_GetPeakInfo(tr, 0), reaper.Track_GetPeakInfo(tr, 1))) end
    end
    local m = reaper.GetMasterTrack(proj)
    publish("mixm", { p = peaks, master = webmixer.db(math.max(reaper.Track_GetPeakInfo(m, 0), reaper.Track_GetPeakInfo(m, 1))) })
  end
  if now - (S.at.mon or -math.huge) >= webmixer.MON_EVERY then
    S.at.mon = now
    local ok, mon = pcall(webmixer.monitor, cfg)
    publish("mixmon", ok and mon or { on = false, error = tostring(mon) })
  end
end

return webmixer
