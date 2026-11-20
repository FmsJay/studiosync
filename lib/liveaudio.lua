-- Live audio over the link (docs/realtime-roadmap.md step 4: StudioSync's own, replacing SonoBus in time). The extension does the work
-- (extension/rtaudio.cpp: AOO + Opus over Tailscale UDP on the link's port, a jitter buffer per bandmate, mixed into this computer's
-- first output pair, never recorded); this file decides when it runs and shows it:
--  - the studio's setting (band.json "live_audio", owner and admins: on unless they turn it off, James: the point of this scope),
--    Settings > Studio under the direct link;
--  - this computer's own choice (ExtState, kept): which inputs it sends, mono or stereo, and Opus's rate;
--  - Live sync's tick starts it with the studio secret (the direct link's key) for the bandmates here (direct.peers), and stops it when the
--    studio turns it off; the song in front drives it (one engine per computer), and the tab that started it stops it when its Live sync ends;
--  - Health's row: latency, jitter buffer and loss per bandmate by name, why a bandmate isn't heard (from their status: "needs extension
--    1.0.13"), and Set up live audio on Windows (the UDP twin of the link's firewall rule);
--  - the panel's Chat > Call: each bandmate's level, volume and mute in what you hear (the cue mix), kept per bandmate by name.
-- (James, rt)
-- My mic (James, rt: live audio is on for everyone now, so it has to be pleasant and safe):
--  - Mute me and Deafen, kept per computer, in the panel's top bar, Chat > Call and as REAPER actions (StudioSync - Live audio mute me /
--    deafen). Deafen also stops sending, as call apps do. The top bar says Muted while you are, and "you're talking" when the input moves.
--  - Push-to-talk (Chat > Call): sending only while Hold to talk or the "StudioSync - Live audio hold to talk" key is held, with a short tail
--    so the last word isn't cut. Holding talk also opens a muted mic for as long as it's held.
--  - Talkback: hold Talk beside a bandmate (or the "StudioSync - Live audio talkback" key, to the last one) and only they hear you.
--  - Defaults: hearing others on, sending on (the point of a live studio; muted by default reads as "it's broken"), with a first-run note in
--    the top bar and an echo warning (a loopback input, or REAPER monitoring the input you send) that offers to mute.
--  - A master volume for everyone you hear, and the cue mix kept by bandmate name (their computer's address changes).
-- Mute, push-to-talk and talkback use StudioSync_LiveAudioSend (the extension after 1.0.13). Without it Mute me restarts live audio on a
-- silent input (a moment's gap in what you hear), and push-to-talk and talkback wait for the newer extension.
local band = require("band")
local liveaudio = { KBPS = 128, EVERY = 0.5, RETRY = 10, HELD = 0.6, TAIL = 0.25, SILENT = 1023, ECHO_LEVEL = 0.05,
  FLOOR = 30, CEILING = 150, WIFI = 30 } -- (each bandmate's jitter buffer, ms: the extension's defaults; WIFI: this far above the floor, Health says why)
local S = { at = -math.huge, json = nil, fail_at = -math.huge } -- (this script's state: the JSON last handed over, the last start that failed)
liveaudio.S = S

function liveaudio.available()
  return reaper.StudioSync_LiveAudioStart ~= nil and reaper.StudioSync_LiveAudioStop ~= nil and reaper.StudioSync_LiveAudioPeers ~= nil
    and reaper.StudioSync_LiveAudioStatus ~= nil and reaper.StudioSync_LiveAudioPeerSet ~= nil
end
function liveaudio.can_gate() return reaper.StudioSync_LiveAudioSend ~= nil end -- (mute without a restart, push-to-talk, talkback)
function liveaudio.enabled(root)
  local ok, on = pcall(function() return require("groups").live_audio(root) end)
  return ok and on == true
end
local function ext(k) return reaper.GetExtState(band.SECTION, "live audio " .. k) end
local function who(peer) return tostring(peer):match("^([^%.:]+)") or tostring(peer) end
liveaudio.who = who

-- This computer's choice: the first input sent (0-based, as REAPER numbers them), how many (1 mono, 2 a stereo pair; up to 8), Opus's total rate.
function liveaudio.mine()
  local function num(k, d, lo, hi) local v = math.floor(tonumber(reaper.GetExtState(band.SECTION, k)) or d); return math.max(lo, math.min(hi, v)) end
  return num("live audio input", 0, 0, 1023), num("live audio channels", 1, 1, 8), num("live audio kbps", liveaudio.KBPS, 16, 512)
end
function liveaudio.set_mine(first, nch, kbps)
  if first then reaper.SetExtState(band.SECTION, "live audio input", tostring(math.floor(first)), true) end
  if nch then reaper.SetExtState(band.SECTION, "live audio channels", tostring(math.floor(nch)), true) end
  if kbps then reaper.SetExtState(band.SECTION, "live audio kbps", tostring(math.floor(kbps)), true) end
end

-- Who each peer is: peer -> bandmate name, from the studio's device files (Live sync's tick keeps it in ExtState for the panel and the actions).
function liveaudio.names() local m = band.ext_json(band.SECTION, "live audio names"); return type(m) == "table" and m or {} end
function liveaudio.name_of(peer, names) return (names or liveaudio.names())[peer] or who(peer) end

-- The cue mix, kept on this computer: bandmate name -> { gain (linear), mute }. (A mix kept by peer address before still counts.)
function liveaudio.mix() local m = band.ext_json(band.SECTION, "live audio mix"); return type(m) == "table" and m or {} end
function liveaudio.set_peer(peer, gain, mute)
  local m, name = liveaudio.mix(), liveaudio.name_of(peer)
  m[name] = { gain = math.max(0, math.min(4, tonumber(gain) or 1)), mute = mute == true }
  m[peer] = nil
  band.set_ext_json(band.SECTION, "live audio mix", m, true)
  liveaudio.apply()
end
-- Each bandmate's jitter buffer bounds (advanced, kept on this computer by name): { floor, ceiling } in ms. The extension's buffer starts at
-- the floor, grows when their packets come in bursts (Wi-Fi) up to the ceiling, and shrinks back after a steady spell. (James, rt)
function liveaudio.can_buffer() return reaper.StudioSync_LiveAudioPeerBuffer ~= nil end
function liveaudio.buffers() local m = band.ext_json(band.SECTION, "live audio buffer"); return type(m) == "table" and m or {} end
-- -> floor, ceiling for a bandmate (the defaults when not set), kept within what the extension takes. Pure.
function liveaudio.bounds(b)
  local f = math.max(10, math.min(300, math.floor(tonumber(type(b) == "table" and b.floor) or liveaudio.FLOOR)))
  return f, math.max(f, math.min(500, math.floor(tonumber(type(b) == "table" and b.ceiling) or liveaudio.CEILING)))
end
function liveaudio.set_buffer(peer, floor, ceiling)
  local m, name = liveaudio.buffers(), liveaudio.name_of(peer)
  local f, c = liveaudio.bounds({ floor = floor, ceiling = ceiling })
  m[name] = (f ~= liveaudio.FLOOR or c ~= liveaudio.CEILING) and { floor = f, ceiling = c } or nil
  band.set_ext_json(band.SECTION, "live audio buffer", m, true)
  liveaudio.apply()
end

-- ---- my mic -----------------------------------------------------------------------------------------------------------------------------
-- A held talk key or button ("live audio talking" / "live audio talkback", not kept): "<time>[ name]" while held (refreshed; a dead script's
-- runs out after HELD seconds, so a crash never leaves the mic open), "latch[ name]" until pressed again. -> on, name. Pure.
function liveaudio.held(v, now)
  local t, name = tostring(v or ""):match("^(%S+) ?(.*)$")
  if not t then return false, nil end
  local on = t == "latch" or (tonumber(t) ~= nil and now - tonumber(t) < liveaudio.HELD)
  return on, on and name ~= "" and name or nil
end
-- This computer's mic, from ExtState: mute, deaf, ptt (kept), talking, talkback (a name, while held), volume (everyone you hear, linear),
-- and recording (this computer's transport records).
function liveaudio.me()
  local now = reaper.time_precise()
  local talking = liveaudio.held(ext("talking"), now)
  local tb, tb_name = liveaudio.held(ext("talkback"), now)
  return { mute = ext("mute") == "1", deaf = ext("deaf") == "1", ptt = ext("ptt") == "1", talking = talking, talkback = tb and tb_name or nil,
    volume = math.max(0, math.min(4, tonumber(ext("volume")) or 1)), recording = (math.floor(tonumber(reaper.GetPlayState()) or 0) & 4) == 4 }
end
-- What this computer sends: on, and to whom only (a bandmate name: talkback), or nil for everyone. Held talk (and talkback) wins over Mute
-- and Deafen for as long as it's held: holding is asking. Talkback without the extension's per-bandmate send sends nothing rather than
-- reaching everyone, and talkback goes quiet while recording (James's pick, docs/realtime-roadmap.md: a cue never lands on a take). Pure.
function liveaudio.send_plan(s, gate)
  if s.talkback then return gate == true and not s.recording, s.talkback end
  if s.talking then return true, nil end
  return not (s.mute or s.deaf or s.ptt), nil
end
-- What you hear of one bandmate: their kept level times the master, all of them off while deafened. -> gain, mute. Pure.
function liveaudio.hear_plan(want, s)
  local g = (type(want) == "table" and tonumber(want.gain) or 1) * (s.volume or 1)
  return math.max(0, math.min(4, g)), s.deaf == true or (type(want) == "table" and want.mute == true)
end
local function plan_key(s, gate) local on, only = liveaudio.send_plan(s, gate); return table.concat({ tostring(on), tostring(only), tostring(s.deaf), tostring(s.volume) }, "|") end

-- Puts this computer's mic and cue mix on the running engine (idempotent: Live sync's tick runs it each time, the panel and actions at once).
function liveaudio.apply(st)
  if not liveaudio.available() then return end
  local s, gate = liveaudio.me(), liveaudio.can_gate()
  S.key = plan_key(s, gate)
  st = st or liveaudio.status()
  if not st.running then return end
  local on, only = liveaudio.send_plan(s, gate)
  if gate then reaper.StudioSync_LiveAudioSend("", on and 1 or 0) end
  local names, mix, bufs, can_buf = liveaudio.names(), liveaudio.mix(), liveaudio.buffers(), liveaudio.can_buffer()
  for peer, p in pairs(type(st.peers) == "table" and st.peers or {}) do
    if type(p) == "table" then
      local name = names[peer] or who(peer)
      if gate then reaper.StudioSync_LiveAudioSend(peer, (not only or name == only) and 1 or 0) end
      local g, m = liveaudio.hear_plan(mix[name] or mix[peer], s)
      if math.abs((tonumber(p.gain) or 1) - g) > 0.005 or (p.mute == true) ~= m then reaper.StudioSync_LiveAudioPeerSet(peer, g, m and 1 or 0) end
      local f, c = liveaudio.bounds(bufs[name])
      if can_buf and (tonumber(p.floor_ms) ~= f or tonumber(p.ceiling_ms) ~= c) then reaper.StudioSync_LiveAudioPeerBuffer(peer, f, c) end
    end
  end
end
-- Applies when what's held, muted or deafened has changed (the panel each frame: a let-go hold's tail ends on time).
function liveaudio.poll() if plan_key(liveaudio.me(), liveaudio.can_gate()) ~= S.key then liveaudio.apply() end end

liveaudio.WORDS = { mute = { "muted: the others don't hear you", "unmuted: the others hear you" },
  deaf = { "deafened: you hear nobody, and they don't hear you", "hearing everyone again" },
  ptt = { "push-to-talk: you're heard only while you hold Hold to talk or its key", "push-to-talk off: the others hear you" } }
-- Mute me, Deafen, push-to-talk (kept per computer). The action's toolbar button follows (its command id is kept by the action).
function liveaudio.set(k, on)
  if on then reaper.SetExtState(band.SECTION, "live audio " .. k, "1", true) else reaper.DeleteExtState(band.SECTION, "live audio " .. k, true) end
  local sec, id = ext(k .. " cmd"):match("^(%-?%d+):(%d+)$")
  if id and reaper.SetToggleCommandState then
    reaper.SetToggleCommandState(tonumber(sec), tonumber(id), on and 1 or 0)
    reaper.RefreshToolbar2(tonumber(sec), tonumber(id))
  end
  band.log("live audio: " .. (liveaudio.WORDS[k] or { k .. " on", k .. " off" })[on and 1 or 2])
  liveaudio.apply()
end
function liveaudio.toggle(k) local on = ext(k) ~= "1"; liveaudio.set(k, on); return on end
function liveaudio.set_volume(v) reaper.SetExtState(band.SECTION, "live audio volume", string.format("%.4f", math.max(0, math.min(4, v))), true); liveaudio.apply() end
-- A talk key or button: how true (held: again while held), "tail" (let go: TAIL more seconds), "latch" (until pressed again), nil (off).
function liveaudio.hold(kind, how, name)
  local now = reaper.time_precise()
  if how then
    local t = how == "latch" and "latch" or string.format("%.3f", how == "tail" and now - liveaudio.HELD + liveaudio.TAIL or now)
    reaper.SetExtState(band.SECTION, "live audio " .. kind, t .. (name and (" " .. name) or ""), false)
  else reaper.DeleteExtState(band.SECTION, "live audio " .. kind, false) end
  liveaudio.poll()
end

-- The keys down when a hold action started (js_ReaScriptAPI), or nil: started by a toolbar button, a pad, or no way to see a key let go.
-- (A 30 s cutoff: REAPER before 7.31 runs the action again on the key's repeat, and the new one has to find the same key still down.)
function liveaudio.keys_down(t0)
  if not reaper.JS_VKeys_GetState then return nil end
  local st, keys = reaper.JS_VKeys_GetState(t0 - 30), {}
  for i = 1, #st do if st:byte(i) ~= 0 then keys[#keys + 1] = i end end
  return #keys > 0 and keys or nil
end
function liveaudio.still_down(keys, t0)
  local st = reaper.JS_VKeys_GetState(t0 - 30)
  for _, i in ipairs(keys) do if st:byte(i) ~= 0 then return true end end
  return false
end
-- StudioSync - Live audio mute me / deafen: toggles, and keeps the action's id so its toolbar button follows the panel's clicks too.
function liveaudio.action_toggle(k)
  local _, _, sec, cmd = reaper.get_action_context()
  if cmd and cmd > 0 then reaper.SetExtState(band.SECTION, "live audio " .. k .. " cmd", sec .. ":" .. cmd, true) end
  liveaudio.toggle(k)
end
-- StudioSync - Live audio hold to talk / talkback: sends while the key is held (and TAIL after), its toolbar button lit meanwhile; started
-- without a key to watch, a latch: on until run again.
function liveaudio.action_hold(kind)
  local name
  if kind == "talkback" then
    name = ext("talkback to")
    if name == "" then return band.msg("Talkback goes to one bandmate: hold Talk beside their name in Chat > Call once, and this key goes to them from then on.") end
  end
  if not liveaudio.can_gate() then return band.msg("Hold to talk and talkback need a newer StudioSync extension: Extensions > ReaPack > Synchronize packages, then restart REAPER.") end
  local _, _, sec, cmd = reaper.get_action_context()
  local function lit(on) if cmd and cmd > 0 then reaper.SetToggleCommandState(sec, cmd, on and 1 or 0); reaper.RefreshToolbar2(sec, cmd) end end
  local t0 = reaper.time_precise()
  local keys = liveaudio.keys_down(t0)
  if not keys then
    local latched = ext(kind):match("^latch") ~= nil
    liveaudio.hold(kind, not latched and "latch" or nil, name)
    lit(not latched)
    band.log("live audio: " .. (latched and "talk latch off" or ("talking" .. (name and (" to " .. name .. " only") or "") .. " until you run it again")))
    return
  end
  if reaper.set_action_options then reaper.set_action_options((tonumber(reaper.GetAppVersion():match("^(%d+%.%d+)")) or 0) >= 7.31 and 2 or 1) end
  liveaudio.hold(kind, true, name)
  lit(true)
  local let_go
  local function loop()
    local now = reaper.time_precise()
    if not let_go and not liveaudio.still_down(keys, t0) then let_go = now end
    if let_go and now - let_go >= liveaudio.TAIL then liveaudio.hold(kind, nil); lit(false); return end
    if not let_go then liveaudio.hold(kind, true, name) end
    reaper.defer(loop)
  end
  reaper.atexit(function() -- (ended any other way: off, unless a new run of this action took over the held key)
    if ext(kind):match("^latch") or liveaudio.still_down(keys, t0) then return end
    liveaudio.hold(kind, nil); lit(false)
  end)
  reaper.defer(loop)
end

-- ---- echo: this computer feeding its own output back --------------------------------------------------------------------------------
liveaudio.LOOPBACK = { "loopback", "stereo mix", "what u hear", "wave out", "monitor of", "blackhole", "soundflower", "cable output" }
-- Is REAPER's track input `inp` (I_RECINPUT) one of the inputs sent? Pure.
function liveaudio.input_overlaps(inp, first, nch)
  inp = math.floor(tonumber(inp) or -1)
  if inp < 0 or inp & 4096 ~= 0 then return false end -- (none, or MIDI)
  local ch, n = inp & 1023, inp & 1024 ~= 0 and 2 or 1
  return ch < first + nch and first < ch + n
end
-- Why what this computer sends may carry what it plays, or nil. names: the sent inputs' names; monitored: a track REAPER monitors one of
-- them on, or nil; level: what's sent lately; sending: not muted. Pure.
function liveaudio.echo_why(names, monitored, level, sending)
  if not sending then return nil end
  for _, n in ipairs(names or {}) do
    local l = tostring(n):lower()
    for _, w in ipairs(liveaudio.LOOPBACK) do
      if l:find(w, 1, true) then return "You send " .. n .. ", which looks like a loopback of what this computer plays: the others would hear themselves back." end
    end
  end
  if monitored and (tonumber(level) or 0) >= liveaudio.ECHO_LEVEL then
    return "REAPER monitors the input you send (track " .. monitored .. ") while it's live: through speakers that feeds back. Use headphones, or mute."
  end
end
local function input_name(i) return (reaper.GetInputChannelName and reaper.GetInputChannelName(i)) or ("Input " .. (i + 1)) end
-- The echo warning for the panel (looked at once a second): { why, sig } or nil; sig is what "It's headphones" dismisses.
function liveaudio.echo(proj)
  local now = reaper.time_precise()
  if S.echo_at and now - S.echo_at < 1 then return S.echo end
  S.echo_at = now
  local first, nch = liveaudio.mine()
  local names, mon = {}, nil
  for i = first, first + nch - 1 do names[#names + 1] = input_name(i) end
  for i = 0, (proj and reaper.CountTracks(proj) or 0) - 1 do
    local tr = reaper.GetTrack(proj, i)
    if not mon and reaper.GetMediaTrackInfo_Value(tr, "I_RECARM") == 1 and reaper.GetMediaTrackInfo_Value(tr, "I_RECMON") > 0
      and liveaudio.input_overlaps(reaper.GetMediaTrackInfo_Value(tr, "I_RECINPUT"), first, nch) then mon = select(2, reaper.GetTrackName(tr)) end
  end
  local why = liveaudio.echo_why(names, mon, liveaudio.recent_level(), (liveaudio.send_plan(liveaudio.me(), liveaudio.can_gate())))
  local sig = first .. ":" .. (mon or "")
  S.echo = why and ext("echo ok") ~= sig and { why = why, sig = sig } or nil
  return S.echo
end

-- What the extension takes (StudioSync_LiveAudioPeers): the studio secret, this computer's port, the bandmates' "name:port". Pure.
function liveaudio.peers_json(secret, port, peers) return band.json_encode({ secret = secret, port = math.floor(port), peers = peers or {} }) end
function liveaudio.status()
  if not liveaudio.available() then return {} end
  local st = band.json_decode(reaper.StudioSync_LiveAudioStatus())
  st = type(st) == "table" and st or {}
  local now = reaper.time_precise() -- (level is the peak since the last ask, and several ask: the loudest over the last second or two)
  if now - (S.lv_at or -math.huge) > 1 then S.lv_at, S.lv_prev, S.lv = now, S.lv or 0, 0 end
  S.lv = math.max(S.lv or 0, tonumber(st.level) or 0)
  return st
end
function liveaudio.recent_level() return math.max(S.lv or 0, S.lv_prev or 0) end

-- Why it isn't running for this studio here, or nil when it may; and a word for it that the bandmates' Health reads (status "la"). Pure apart
-- from what it's handed.
function liveaudio.why_not(on, available, secret, firewall)
  if not on then return "off for this studio", "off" end
  if not available then return "needs StudioSync's extension with live audio (Extensions > ReaPack > Synchronize packages, then restart REAPER)", "ext" end
  if not secret then return "needs the studio on Tailscale with its secret (Settings > Studio)", "tailscale" end
  if not firewall then return "Windows needs its firewall rule first: press Set up live audio in Health", "firewall" end
end
-- This computer's live audio for its status file (Live sync), so the others' Health can say why they don't hear it: nil (the studio has it
-- off), "ext", "tailscale", "firewall", else "on", "muted", "deaf" or "ptt".
function liveaudio.my_la()
  if S.code == "off" then return nil end
  if S.code then return S.code end
  local s = liveaudio.me()
  return s.deaf and "deaf" or s.mute and "muted" or s.ptt and "ptt" or "on"
end

-- Live sync's tick (the song in front drives it: one engine per computer). Never raises (band.try around it).
function liveaudio.tick(cfg, b, proj)
  local now = reaper.time_precise()
  if now - S.at < liveaudio.EVERY then return end
  S.at = now
  if proj and reaper.EnumProjects(-1) ~= proj then return end
  local direct, groups = require("direct"), require("groups")
  local on = cfg ~= nil and liveaudio.enabled(cfg.root)
  local avail = liveaudio.available()
  local secret = on and groups.tailnet(cfg.root) and groups.sonobus_secret(cfg.root) or nil
  S.why, S.code = liveaudio.why_not(on, avail, secret, not on or direct.firewall_ok("UDP"))
  local st = liveaudio.status()
  if S.why then
    if st.running and reaper.GetExtState(band.SECTION, "live audio by") ~= "" then -- (ours, from this tab or another: the studio's choice wins)
      reaper.StudioSync_LiveAudioStop()
      reaper.DeleteExtState(band.SECTION, "live audio by", false)
      band.log("live audio stopped: " .. S.why)
    end
    S.json = nil
    return
  end
  local list, _, users = direct.peers(cfg, b and b.song, b and b.room)
  if type(users) == "table" then -- (who each peer is, for the panel and the actions: the cue mix and talkback go by name)
    local names = band.json_encode(users)
    if names ~= S.names then reaper.SetExtState(band.SECTION, "live audio names", names, false); S.names = names end
  end
  local json = liveaudio.peers_json(secret, direct.port(), list)
  if json ~= S.json or not st.running then reaper.StudioSync_LiveAudioPeers(json); S.json = json end
  local first, nch, kbps = liveaudio.mine()
  -- (muted with an extension that can't send silence: the same stream from an input that isn't there. Its restart is the price)
  if not liveaudio.can_gate() and not liveaudio.send_plan(liveaudio.me(), false) then first = liveaudio.SILENT end
  if st.running and (tonumber(st.first) ~= first or tonumber(st.nch) ~= nch or tonumber(st.kbps) ~= kbps) then -- (a new choice here: start again with it)
    reaper.StudioSync_LiveAudioStop()
    st.running = false
  end
  if not st.running and now - S.fail_at > liveaudio.RETRY then
    if reaper.StudioSync_LiveAudioStart(first, nch, kbps) == 1 then
      reaper.SetExtState(band.SECTION, "live audio by", tostring(proj), false)
      liveaudio.apply() -- (at once: a muted computer never sends its first half second)
      if first ~= liveaudio.SILENT then
        band.log(string.format("live audio on: sending input %d%s at %d kbit/s to the others here; theirs comes out of your first output pair", first + 1,
          nch > 1 and ("-" .. (first + nch)) or "", kbps))
      end
      if ext("first said") ~= "1" and not S.first_logged then
        S.first_logged = true
        band.log("live audio is on for this studio: the others here hear your input while Live sync runs. Mute me and Deafen are in the panel's top bar; headphones stop echo")
      end
    else
      S.fail_at = now
      band.log("live audio didn't start: " .. tostring(liveaudio.status().error or "?"))
    end
    return
  end
  liveaudio.apply(st) -- (the mic and the cue mix kept here, put back on each bandmate: a new peer, or after a restart, starts at full level)
end
-- Live sync ending in this tab: the engine stops if this tab started it.
function liveaudio.on_exit(proj)
  if not liveaudio.available() or reaper.GetExtState(band.SECTION, "live audio by") ~= tostring(proj) then return end
  reaper.StudioSync_LiveAudioStop()
  reaper.DeleteExtState(band.SECTION, "live audio by", false)
end

-- Why a bandmate isn't heard, from the word in their status (my_la). %s: the extension StudioSync wants.
liveaudio.THEM = { ext = "needs extension %s", tailscale = "not on the studio's Tailscale", firewall = "needs Windows' firewall rule (Set up live audio, in their Health)" }
liveaudio.THEIR_MIC = { muted = "muted", deaf = "deafened", ptt = "push-to-talk" }
local function them(code)
  local t = liveaudio.THEM[code]
  if not t then return nil end
  local ok, tools = pcall(require, "tools")
  return (t:gsub("%%s", ok and type(tools) == "table" and tools.EXT_WANT or "1.0.13"))
end
-- Health's words from the extension's status: ok (everyone heard, loss under 5%), text. names: peer -> bandmate; theirs: bandmate -> the word
-- in their status (my_la); s: this computer's mic (me()). Pure.
function liveaudio.health_text(st, names, theirs, s)
  names, theirs = names or {}, theirs or {}
  local heard, each, ok, seen, bursty = {}, {}, true, {}, false
  for peer, p in pairs(type(st.peers) == "table" and st.peers or {}) do
    if type(p) == "table" then
      local name = names[peer] or who(peer)
      seen[name] = true
      local why = them(theirs[name])
      if not p.resolved then each[#each + 1] = name .. ": can't reach (" .. tostring(p.error) .. ")"; ok = false
      elseif not p.streaming then each[#each + 1] = name .. (why and (" not connected: " .. why) or ": not heard yet"); ok = false
      else
        local loss = (tonumber(p.loss) or 0) * 100
        if loss >= 5 then ok = false end
        local mic = liveaudio.THEIR_MIC[theirs[name]]
        -- (the buffer grown well past its floor: their packets come in bursts, Wi-Fi's way. It shrinks back on its own once they stop. James, rt)
        local target, floor = tonumber(p.target_ms), tonumber(p.floor_ms)
        local wifi = target and floor and target >= floor + liveaudio.WIFI
        bursty = bursty or wifi
        heard[#heard + 1] = string.format("%s %.0f ms (buffer %.0f ms%s, loss %.1f%%)%s", name, tonumber(p.latency_ms) or -1, tonumber(p.buffer_ms) or -1,
          wifi and " (Wi-Fi?)" or "", loss, mic and (", " .. mic) or "")
      end
    end
  end
  for name, code in pairs(theirs) do -- (here, but not even on the list: no Tailscale name, say)
    local why = them(code)
    if why and not seen[name] then each[#each + 1] = name .. " not connected: " .. why; ok = false end
  end
  table.sort(heard)
  table.sort(each)
  local nch = tonumber(st.nch) or 1
  local text = string.format("Live audio: sending %s at %d kbit/s", nch > 1 and (nch .. " inputs") or "1 input", tonumber(st.kbps) or 0)
  if s then
    local on, only = liveaudio.send_plan(s, true)
    if only then text = text .. " (talkback to " .. only .. ")"
    elseif s.deaf then text = text .. " (deafened: you hear nobody)"
    elseif not on then text = text .. (s.ptt and not s.mute and " (push-to-talk)" or " (muted)") end
  end
  if #heard > 0 then text = text .. "; hearing " .. table.concat(heard, ", ") end
  if bursty then text = text .. " (a buffer that grew means packets come in bursts, as over Wi-Fi: a wired network lowers it)" end
  if #each > 0 then text = text .. "; " .. table.concat(each, ", ") end
  if #heard + #each == 0 then text = text .. "; nobody else here yet" end
  if (tonumber(st.rejected) or 0) > 0 then
    local from = type(st.last_reject_from) == "string" and st.last_reject_from ~= "" and (" from " .. st.last_reject_from) or ""
    text = text .. string.format("; refused %d (last: %s%s)", st.rejected, tostring(st.last_reject), from)
  end
  return ok and #heard + #each > 0, text
end
-- Health's row (lib/direct.lua health_rows): nil while the studio has live audio off. b: the tab's song and room, for the bandmates' statuses.
function liveaudio.health_row(cfg, b)
  if not (cfg and liveaudio.enabled(cfg.root)) then return nil end
  if not liveaudio.available() then
    return { "live audio", false, "yellow", "", "Live audio is on for the studio, but " .. liveaudio.why_not(true, false) .. "." }
  end
  local direct = require("direct")
  if band.WIN and not direct.firewall_ok("UDP") then
    local row = { "live audio", false, "yellow", "", "Live audio is on for the studio: Windows needs its firewall rule before the others can be heard here." }
    row.action = { "Set up live audio", function()
      local done, why = direct.setup_firewall()
      band.log(done and "live audio: Windows asks once (UAC) to let REAPER hear the others; Health turns green within a minute" or ("live audio: " .. tostring(why)))
    end, "Adds the direct link's Windows Firewall rules for reaper.exe, TCP and UDP " .. direct.port() .. ", from Tailscale's addresses only (100.64.0.0/10). Windows asks once." }
    return row
  end
  local st = liveaudio.status()
  if not st.running then
    local err = tostring(st.error or "")
    return { "live audio", err == "", err == "" and "grey" or "yellow", "Live audio: starts while Live sync runs with a studio song in front.", "Live audio: " .. err }
  end
  local theirs = {}
  if b and b.song then
    local ok, sts = pcall(require("presence").peers, cfg, b.song, b.room or "main")
    for _, x in ipairs(ok and type(sts) == "table" and sts or {}) do if type(x) == "table" and x.user then theirs[x.user] = x.la end end
  end
  local ok, text = liveaudio.health_text(st, liveaudio.names(), theirs, liveaudio.me())
  return { "live audio", ok, "yellow", text, text }
end

-- ---- the panel --------------------------------------------------------------------------------------------------------------------------
local GREEN, RED, GREY, ORANGE, AMBER, BLUE = 0x2E7D4FFF, 0x8A2B2BFF, 0x5A5F6AFF, 0xB0601EFF, 0x8C6D12FF, 0x2D5D8AFF
local function button(ctx, ImGui, label, colour, small, w, h)
  ImGui.PushStyleColor(ctx, ImGui.Col_Button, colour)
  local clicked
  if small then clicked = ImGui.SmallButton(ctx, label) else clicked = ImGui.Button(ctx, label, w or 0, h or 0) end
  ImGui.PopStyleColor(ctx)
  return clicked
end
-- What the mic button says and its colour, from me() and the plan. Pure.
function liveaudio.mic_label(s, gate, level)
  local on, only = liveaudio.send_plan(s, gate)
  if only then return s.recording and "Talkback off: recording" or ("Talkback: " .. only), ORANGE end
  if s.deaf then return "Deafened", RED end
  if on then return (s.talking and (s.mute or s.ptt)) and "Talking" or "Mic live", GREEN end
  if s.ptt and not s.mute then return "Push to talk", GREY end
  return (tonumber(level) or 0) >= liveaudio.ECHO_LEVEL and "Muted (you're talking)" or "Muted", RED
end
liveaudio.FIRST_RUN = "Live audio is on for this studio: while Live sync runs, the others here hear your input and you hear theirs out of your " ..
  "first output pair (never recorded). Mute me and Deafen are here, in Chat > Call, and as REAPER actions for a key or toolbar. " ..
  "Headphones stop echo. Click: got it."
-- The panel's top bar (StudioSync - Panel.lua, F.top_bar): the mic, Deafen, an echo warning and the first-run note, while it runs.
-- at_row(label): the bar's own placing.
function liveaudio.bar_ui(ctx, ImGui, cfg, at_row, proj)
  if not (cfg and liveaudio.enabled(cfg.root) and liveaudio.available()) then return end
  local now = reaper.time_precise() -- (the extension's status four times a second, not every frame of the panel)
  if not S.bar_at or now - S.bar_at > 0.25 or now < S.bar_at then S.bar_at, S.bar_run = now, liveaudio.status().running end
  if not S.bar_run then return end
  liveaudio.poll()
  local s, gate = liveaudio.me(), liveaudio.can_gate()
  local label, colour = liveaudio.mic_label(s, gate, liveaudio.recent_level())
  at_row(label)
  if button(ctx, ImGui, label .. "##lamic", colour, true) then if s.deaf then liveaudio.set("deaf", false) else liveaudio.toggle("mute") end end
  ImGui.SetItemTooltip(ctx, (s.deaf and "Deafened: you hear nobody and they don't hear you. Click: hear and be heard again." or
    s.mute and "Muted: the others don't hear you. Click: unmute." or "Live audio: the others here hear your input. Click: mute me.") ..
    "\nHold to talk, push-to-talk and talkback: Chat > Call. As keys: the StudioSync - Live audio actions.")
  at_row(s.deaf and "Hear" or "Deafen")
  if ImGui.SmallButton(ctx, (s.deaf and "Hear" or "Deafen") .. "##ladeaf") then liveaudio.toggle("deaf") end
  ImGui.SetItemTooltip(ctx, s.deaf and "Hear everyone again (and be heard, unless you'd muted)." or "Hear nobody, and send nothing, until you click again.")
  local e = liveaudio.echo(proj)
  if e then
    at_row("Echo?")
    if button(ctx, ImGui, "Echo?##laecho", AMBER, true) then liveaudio.set("mute", true) end
    if ImGui.IsItemClicked(ctx, 1) then reaper.SetExtState(band.SECTION, "live audio echo ok", e.sig, true); S.echo_at = nil end
    ImGui.SetItemTooltip(ctx, e.why .. "\nClick: mute me. Right-click: it's headphones, don't warn again for this input.")
  end
  if ext("first said") ~= "1" then
    at_row("Live audio is on")
    if button(ctx, ImGui, "Live audio is on##lafirst", BLUE, true) then reaper.SetExtState(band.SECTION, "live audio first said", "1", true) end
    ImGui.SetItemTooltip(ctx, liveaudio.FIRST_RUN)
  end
end

-- The input this computer sends: a list of REAPER's inputs. -> changed
function liveaudio.input_picker(ctx, ImGui, id, width)
  local first, nch = liveaudio.mine()
  local n = reaper.GetNumAudioInputs and reaper.GetNumAudioInputs() or 0
  ImGui.SetNextItemWidth(ctx, width)
  local changed = false
  if ImGui.BeginCombo(ctx, id, n > 0 and (input_name(first) .. (nch > 1 and (" + " .. (nch - 1) .. " more") or "")) or "no inputs") then
    for i = 0, n - 1 do
      if ImGui.Selectable(ctx, input_name(i) .. "##lai" .. i, i == first) then liveaudio.set_mine(i); changed = true end
    end
    if n == 0 then ImGui.TextDisabled(ctx, "No audio inputs: pick your interface in REAPER's Preferences > Audio > Device.") end
    ImGui.EndCombo(ctx)
  end
  ImGui.SetItemTooltip(ctx, "Only on this computer. Your mic or instrument input (the first of a stereo pair). Changing it restarts live audio within a second.")
  return changed
end

-- Settings > Studio, under the direct link: the studio's switch (owner and admins) and this computer's inputs.
function liveaudio.studio_ui(ctx, ImGui, cfg, may)
  ImGui.SeparatorText(ctx, "Live audio")
  local on = liveaudio.enabled(cfg.root)
  ImGui.TextDisabled(ctx, on and "On: while Live sync runs, each computer sends its chosen inputs to the others here over Tailscale (Opus, about " ..
    "40 ms plus the network) and hears theirs out of its first output pair. Never recorded. Chat > Call has mute, deafen, push-to-talk and each person's volume." or
    "Off for this studio: StudioSync's own live audio isn't used (SonoBus carries Real time mode). It's on unless turned off here.")
  if may then
    local ch, v = ImGui.Checkbox(ctx, "Live audio##studiolive", on)
    if ch then
      require("groups").set_live_audio(cfg.root, v)
      band.log(v and "live audio is on for the studio" or "live audio is off for the studio")
    end
    ImGui.SetItemTooltip(ctx, "Owner and admins. Each computer needs StudioSync's extension with live audio, Tailscale, and on Windows the firewall rule (Health).")
  end
  if not on then return end
  local _, nch, kbps = liveaudio.mine()
  liveaudio.input_picker(ctx, ImGui, "This computer sends##liveaudioin", 220)
  local sch, stereo = ImGui.Checkbox(ctx, "Stereo pair##liveaudiost", nch >= 2)
  if sch then liveaudio.set_mine(nil, stereo and 2 or 1) end
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, 140)
  local kch, k = ImGui.SliderInt(ctx, "kbit/s##liveaudiokbps", kbps, 64, 256)
  if kch then liveaudio.set_mine(nil, nil, k) end
  ImGui.SetItemTooltip(ctx, "Opus's rate for what you send. 128 is plenty for a voice or an instrument; more for a stereo mix.")
  if S.why and S.why ~= "off for this studio" then ImGui.TextDisabled(ctx, "Not running here: " .. S.why .. ".") end
end

-- A hold button: while it's held, kind ("talking" or "talkback", to name) is on; let go, it stays TAIL more seconds (poll ends it).
local function hold_button(ctx, ImGui, label, kind, name, w)
  ImGui.Button(ctx, label, w or 0, 0)
  if ImGui.IsItemActive(ctx) then liveaudio.hold(kind, true, name)
  elseif ImGui.IsItemDeactivated(ctx) then liveaudio.hold(kind, "tail", name) end
end

-- Chat > Call: my mic (mute, deafen, hold to talk, push-to-talk, the input and its meter), the master volume, then each bandmate you hear:
-- their level, volume, mute (only for you: the cue mix) and Talk (talkback: only they hear you while it's held).
function liveaudio.call_ui(ctx, ImGui, cfg)
  if not (cfg and liveaudio.enabled(cfg.root)) then return end
  ImGui.SeparatorText(ctx, "Live audio (StudioSync)")
  local cw, gate = require("callwin"), liveaudio.can_gate()
  liveaudio.poll()
  local st, s = liveaudio.status(), liveaudio.me()
  local w = ImGui.GetContentRegionAvail(ctx)
  local fh = ImGui.GetFrameHeight(ctx) * 1.4
  local label, colour = liveaudio.mic_label(s, gate, liveaudio.recent_level())
  if button(ctx, ImGui, label .. (s.deaf and "  -  click to hear" or s.mute and "  -  click to unmute" or "  -  click to mute") .. "##lacmic", colour, false, w * 0.62, fh) then
    if s.deaf then liveaudio.set("deaf", false) else liveaudio.toggle("mute") end
  end
  ImGui.SetItemTooltip(ctx, "Mute me: the others don't hear you. Kept on this computer. A key or toolbar button: StudioSync - Live audio mute me.")
  ImGui.SameLine(ctx)
  if button(ctx, ImGui, (s.deaf and "Hear" or "Deafen") .. "##lacdeaf", s.deaf and RED or GREY, false, -1, fh) then liveaudio.toggle("deaf") end
  ImGui.SetItemTooltip(ctx, "Deafen: hear nobody, and send nothing, until you click again. A key or toolbar button: StudioSync - Live audio deafen.")
  ImGui.BeginDisabled(ctx, not gate)
  hold_button(ctx, ImGui, "Hold to talk##lachold", "talking", nil, w)
  ImGui.EndDisabled(ctx)
  ImGui.SetItemTooltip(ctx, "Heard while you hold it (and a moment after), even when muted or on push-to-talk. A key: StudioSync - Live audio hold to talk.")
  ImGui.BeginDisabled(ctx, not gate and not s.ptt) -- (an older extension: it can't be turned on, but one left on can always be turned off)
  local pch, pv = ImGui.Checkbox(ctx, "Push-to-talk##laptt", s.ptt)
  ImGui.EndDisabled(ctx)
  if pch then liveaudio.set("ptt", pv) end
  ImGui.SetItemTooltip(ctx, gate and "Only heard while you hold Hold to talk or the StudioSync - Live audio hold to talk key. Kept on this computer." or
    "Hold to talk, push-to-talk and talkback need a newer StudioSync extension: Extensions > ReaPack > Synchronize packages, then restart REAPER.")
  local e = liveaudio.echo(reaper.EnumProjects(-1))
  if e then
    ImGui.TextColored(ctx, 0xE0B040FF, e.why)
    if ImGui.SmallButton(ctx, "Mute me##laecm") then liveaudio.set("mute", true) end
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, "It's headphones##laecok") then reaper.SetExtState(band.SECTION, "live audio echo ok", e.sig, true); S.echo_at = nil end
  end
  if ext("first said") ~= "1" then
    ImGui.TextDisabled(ctx, (liveaudio.FIRST_RUN:gsub(" Click: got it%.$", "")))
    if ImGui.SmallButton(ctx, "Got it##lafirstok") then reaper.SetExtState(band.SECTION, "live audio first said", "1", true) end
  end
  liveaudio.input_picker(ctx, ImGui, "##lacin", w)
  ImGui.ProgressBar(ctx, math.min(1, liveaudio.recent_level()), -1, 6, "")
  ImGui.SetItemTooltip(ctx, "Your input's level" .. ((liveaudio.send_plan(s, gate)) and ", as it goes out." or ": muted, nothing goes out."))
  local mdb = cw.db_of(s.volume)
  ImGui.SetNextItemWidth(ctx, -1)
  local vch, vv = ImGui.SliderDouble(ctx, "##lamaster", math.max(-60, math.min(12, mdb)), -60, 12, mdb <= -60 and "Everyone: off" or "Everyone: %.1f dB")
  if vch then liveaudio.set_volume(cw.vol_of(vv)) end
  ImGui.SetItemTooltip(ctx, "How loud everyone comes in, only for you (each person's own volume is below). Ctrl+click to type a value.")
  if not st.running then ImGui.TextDisabled(ctx, "Starts while Live sync runs with a studio song in front (Health says what's missing)."); return end
  local peers = {}
  for peer in pairs(type(st.peers) == "table" and st.peers or {}) do peers[#peers + 1] = peer end
  table.sort(peers)
  if #peers == 0 then ImGui.TextDisabled(ctx, "Nobody else here yet.") end
  local names, mix, tb_to = liveaudio.names(), liveaudio.mix(), ext("talkback to")
  for _, peer in ipairs(peers) do
    local p, name = st.peers[peer], liveaudio.name_of(peer, names)
    local want = mix[name] or mix[peer] or {}
    ImGui.Text(ctx, name .. (p.streaming and "" or " (not heard yet)"))
    ImGui.ProgressBar(ctx, math.min(1, tonumber(p.level) or 0), -1, 6, "")
    local gain, mute = tonumber(want.gain) or 1, want.mute == true
    local db = cw.db_of(gain)
    ImGui.SetNextItemWidth(ctx, -130)
    local ch, v = ImGui.SliderDouble(ctx, "##lavol" .. peer, math.max(-60, math.min(12, db)), -60, 12, db <= -60 and "off" or "%.1f dB")
    if ch then liveaudio.set_peer(peer, cw.vol_of(v), mute) end
    ImGui.SetItemTooltip(ctx, "How loud " .. name .. " comes in, only for you, kept for " .. name .. ". Ctrl+click to type a value.")
    ImGui.SameLine(ctx)
    local mch, m = ImGui.Checkbox(ctx, "Mute##lamute" .. peer, mute)
    if mch then liveaudio.set_peer(peer, gain, m) end
    ImGui.SameLine(ctx)
    ImGui.BeginDisabled(ctx, not gate)
    hold_button(ctx, ImGui, "Talk##latb" .. peer, "talkback", name)
    if ImGui.IsItemActivated(ctx) and tb_to ~= name then reaper.SetExtState(band.SECTION, "live audio talkback to", name, true) end
    ImGui.EndDisabled(ctx)
    ImGui.SetItemTooltip(ctx, "Talkback: hold to talk to " .. name .. " only; the others don't hear it." ..
      (tb_to == name and (" The StudioSync - Live audio talkback key goes to " .. name .. ".") or (" Holding it also points the StudioSync - Live audio talkback key at " .. name .. ".")))
  end
  -- (advanced: each bandmate's jitter buffer bounds. The defaults suit everyone; a lower floor for a wired bandmate, a higher one for a
  -- network that never settles. James, rt)
  if #peers > 0 and liveaudio.can_buffer() and ImGui.TreeNode(ctx, "Jitter buffer (advanced)##labuf") then
    local bufs = liveaudio.buffers()
    for _, peer in ipairs(peers) do
      local p, name = st.peers[peer], liveaudio.name_of(peer, names)
      local f, c = liveaudio.bounds(bufs[name])
      ImGui.Text(ctx, string.format("%s: %.0f ms now", name, tonumber(p.target_ms) or f))
      ImGui.SetNextItemWidth(ctx, 140)
      local fch, nf = ImGui.SliderInt(ctx, "floor##labf" .. peer, f, 10, 150, "%d ms")
      ImGui.SameLine(ctx)
      ImGui.SetNextItemWidth(ctx, 140)
      local cch, nc = ImGui.SliderInt(ctx, "ceiling##labc" .. peer, c, 30, 500, "%d ms")
      if fch or cch then liveaudio.set_buffer(peer, nf, math.max(nf, nc)) end
      ImGui.SetItemTooltip(ctx, "Only for you. " .. name .. "'s buffer starts at the floor, grows when their packets come in bursts (Wi-Fi) up to the " ..
        "ceiling, and shrinks back after a steady spell, in a quiet moment. A lower floor is less delay; too low and you hear dropouts.")
    end
    ImGui.TreePop(ctx)
  end
end

return liveaudio
