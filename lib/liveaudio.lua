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
-- Talk and Play (below): the call mic, and every armed track post-FX through a hidden live out track, two streams so each listener has a
-- Talk and a Play volume per bandmate (StudioSync_LiveAudioPlay / PeerPlay, extension after 1.0.15; without them, Talk alone as before).
-- Mute, push-to-talk and talkback use StudioSync_LiveAudioSend (the extension after 1.0.13). Without it Mute me restarts live audio on a
-- silent input (a moment's gap in what you hear), and push-to-talk and talkback wait for the newer extension.
-- The hub's live mix (below, hub_plan): from HUB_FROM people in a room (a studio setting), the song's hub mixes everyone's live audio, one
-- stream each way per person instead of one to and from everyone (StudioSync_LiveAudioHub, extension after 1.0.18).
local band = require("band")
local liveaudio = { KBPS = 128, EVERY = 0.5, RETRY = 10, HELD = 0.6, TAIL = 0.25, SILENT = 1023, ECHO_LEVEL = 0.05,
  -- (each bandmate's jitter buffer, ms: the extension's defaults; WIFI: this far above the floor, Health says why. CEILING was 150: a link
  -- that holds packets longer than that ran dry at every hold, rt-r5; past 150 ms nobody plays along, hearing each other whole counts)
  FLOOR = 30, CEILING = 400, WIFI = 30,
  -- (the hub's live mix, below: from 4 people; its share of a core, recording; s paused; s a room stays "big" after it was, and must be
  -- before it counts: hub_n. HUB_KEEP was 60: rt-r6, one computer restarted its Live sync, 63 s off the list, and the room went peer to
  -- peer one second before it was back, then to the mix again 60 s later. Now as long as a stopped computer stays in the room: hub.VOUCH)
  HUB_FROM = 4, HUB_BUDGET = 0.25, HUB_REC_BUDGET = 0.10, HUB_COOL = 120, HUB_KEEP = 150, HUB_SETTLE = 60 }
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
function liveaudio.set_peer(peer, gain, mute, play) -- (play: their Play level, linear; nil keeps the one set)
  local m, name = liveaudio.mix(), liveaudio.name_of(peer)
  local old = m[name] or m[peer] or {}
  m[name] = { gain = math.max(0, math.min(4, tonumber(gain) or 1)), mute = mute == true, play = tonumber(play or old.play) and math.max(0, math.min(4, tonumber(play or old.play))) or nil }
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

-- ---- Talk and Play (James, rt: "hear what a bandmate plays when they arm"; docs/realtime-roadmap.md step 4) ----------------------------
-- Two sources per computer: Talk (the call mic, as before) and Play (every armed track's sound after its FX: amp sims, synths, MIDI
-- instruments; never the master, so the others' audio is never in it). The armed tracks send post-FX to a hidden "live out" track whose
-- StudioSync Hop the extension reads (step 4b's tap); Play is its own stream, so each listener has a Talk and a Play volume per bandmate.
-- What goes, per computer (ExtState "live audio source", kept): Auto (nothing armed: Talk; a track armed: Play, plus Talk unless the call mic
-- is an armed track's input, then it goes once, as Play, never twice), Talk only, Play only, Both (the same never-twice guard).
-- Mute me and Deafen silence both (they mean "the others don't hear you"); push-to-talk and talkback are Talk's (arming is the ask for Play,
-- and talkback stays a cue to one bandmate, quiet while recording); held talk opens Talk even in Play only, unless the mic already goes as
-- Play, where it opens that instead of sending the voice twice.
liveaudio.MODES = { auto = "Auto", talk = "Talk only", play = "Play only", both = "Both" }
liveaudio.MODE_ORDER = { "auto", "talk", "play", "both" }
liveaudio.LIVE_OUT, liveaudio.LIVE_OUT_TAG = "StudioSync live out", "liveout"
function liveaudio.can_play() return reaper.StudioSync_LiveAudioPlay ~= nil and reaper.StudioSync_LiveAudioPeerPlay ~= nil end
function liveaudio.source_mode() local m = ext("source"); return liveaudio.MODES[m] and m or "auto" end
function liveaudio.set_source_mode(m)
  if not liveaudio.MODES[m] then return end
  if m == "auto" then reaper.DeleteExtState(band.SECTION, "live audio source", true) else reaper.SetExtState(band.SECTION, "live audio source", m, true) end
  band.log("live audio sends: " .. liveaudio.MODES[m])
  S.at = -math.huge -- (Live sync's next tick looks at the tracks again at once)
end
-- -> talk, play: which sources this computer sends. armed: a track armed here; folded: the call mic is an armed track's input; can_play:
-- Play can go (the extension has it, the live out track is there). Pure.
function liveaudio.source_plan(mode, armed, folded, can_play)
  if mode == "talk" then return true, false end
  local play = can_play == true and (mode ~= "auto" or armed == true)
  if mode == "play" then return false, play end
  return not (play and folded), play
end
-- The plan with the mic's state (me()): -> talk_on, only (talkback's bandmate, Talk only), play_on. Pure.
function liveaudio.mic_plan(s, gate, talk, play, folded)
  local on, only = liveaudio.send_plan(s, gate)
  local doubled = play and folded -- (the call mic already goes, as Play)
  local asked = s.talking or s.talkback ~= nil
  return on and (talk or (asked and not doubled)), only, play and (not (s.mute or s.deaf) or (doubled and s.talking == true))
end
-- Watching a bandmate's screen share with its sound (lib/webcall.lua local_msg, rt-share): their Play is in that mix already, so it's silent
-- here until the time given (reaper.time_precise()), by bandmate name. Their Talk stays: they can still talk over it.
liveaudio.ducks = liveaudio.ducks or {}
-- What a listener's Play volume comes to: their kept Play level (linear, 1 unless set) times the master. Pure.
function liveaudio.play_gain(want, s) return math.max(0, math.min(4, (type(want) == "table" and tonumber(want.play) or 1) * (s.volume or 1))) end
-- What this computer sends, for its status file (others' Chat > Call): "talk", "play", "both", "none", or nil while live audio isn't running.
function liveaudio.my_src()
  local x = S.sending
  if not x then return nil end
  return x.talk and x.play and "both" or x.talk and "talk" or x.play and "play" or "none"
end
liveaudio.SRC_WORDS = { talk = "Talk", play = "Play", both = "Talk + Play", none = "nothing (muted)" }
-- A bandmate's sources, for Chat > Call: from their status word (my_src), else from what arrives (Play's stream is up only while they send it). Pure.
function liveaudio.their_src(code, p)
  if liveaudio.SRC_WORDS[code] then return liveaudio.SRC_WORDS[code] end
  if type(p) ~= "table" or not p.streaming then return nil end
  return p.play_streaming and "Talk + Play" or "Talk"
end
-- Each bandmate's status word (my_src, "lsrc" in their status file) by name, looked at once a second for Chat > Call. {} until Live sync's
-- tick has said which song and room this tab is in.
function liveaudio.their_srcs(cfg)
  local now = reaper.time_precise()
  if S.srcs and now - S.srcs_at < 1 then return S.srcs end
  S.srcs, S.srcs_at, S.caps, S.las = {}, now, {}, {}
  local b = S.b
  if not (cfg and b and b.song) then return S.srcs end
  local ok, sts = pcall(require("presence").peers, cfg, b.song, b.room or "main")
  for _, x in ipairs(ok and type(sts) == "table" and sts or {}) do
    -- (lhub: their extension mixes at a hub; la: their live audio's own word, my_la: one that can't run never mixes for the room. hub_plan)
    if type(x) == "table" and x.user then S.srcs[x.user], S.caps[x.user], S.las[x.user] = x.lsrc, x.lhub == true, x.la end
  end
  return S.srcs
end
-- Health's words for what this computer sends (src: S.src; sending: S.sending; st: the extension's status). Pure.
function liveaudio.sends_text(src, sending, st)
  if type(src) ~= "table" then return nil end
  local parts = {}
  if sending and sending.talk then parts[#parts + 1] = "Talk" end
  if sending and sending.play then
    local armed = #(src.armed or {}) > 0 and (" (" .. table.concat(src.armed, ", ") .. ")") or " (nothing armed: silence)"
    parts[#parts + 1] = "Play" .. armed .. (type(st) == "table" and st.play_alive == false and ": the live out track isn't running" or "")
  end
  local text = "sends " .. (#parts > 0 and table.concat(parts, " + ") or "nothing") .. " [" .. (liveaudio.MODES[src.mode] or "Auto") .. "]"
  if src.play and src.folded and not (sending and sending.talk) then text = text .. "; the call mic is an armed track's input, so it goes once, as Play" end
  if src.why then text = text .. "; Play " .. src.why end
  return text
end
local function plan_key(s, gate)
  local on, only = liveaudio.send_plan(s, gate)
  local src = S.src or {}
  return table.concat({ tostring(on), tostring(only), tostring(s.deaf), tostring(s.volume), tostring(s.mute), tostring(s.talking), tostring(src.talk), tostring(src.play), tostring(src.folded), tostring(src.hop) }, "|")
end

-- Puts this computer's mic and cue mix on the running engine (idempotent: Live sync's tick runs it each time, the panel and actions at once).
function liveaudio.apply(st)
  if not liveaudio.available() then return end
  local s, gate = liveaudio.me(), liveaudio.can_gate()
  S.key = plan_key(s, gate)
  st = st or liveaudio.status()
  if not st.running then S.sending = nil; return end
  local src, can_play = S.src or { talk = true, play = false }, liveaudio.can_play()
  local on, only, play_on = liveaudio.mic_plan(s, gate, src.talk, src.play and can_play, src.folded)
  if gate then reaper.StudioSync_LiveAudioSend("", on and 1 or 0) end
  local hop = src.play and can_play and src.hop or 0
  if can_play and ((st.play_send == true) ~= (play_on == true) or S.play_asked ~= hop .. tostring(play_on)) then
    reaper.StudioSync_LiveAudioPlay(hop, play_on and 1 or 0)
    S.play_asked = hop .. tostring(play_on) -- (the extension opens the hop's mapping on its send thread: asked once, not every tick while it does)
  end
  S.sending = { talk = on == true, play = play_on == true and hop > 0 }
  local names, mix, bufs, can_buf = liveaudio.names(), liveaudio.mix(), liveaudio.buffers(), liveaudio.can_buffer()
  local solo = require("livex").solo_in(st.peers, names, ext("solo") ~= "" and ext("solo") or nil) -- (Solo: only them, while they're here. rt-sonox)
  for peer, p in pairs(type(st.peers) == "table" and st.peers or {}) do
    if type(p) == "table" then
      local name = names[peer] or who(peer)
      if gate then reaper.StudioSync_LiveAudioSend(peer, (not only or name == only) and 1 or 0) end
      local g, m = liveaudio.hear_plan(mix[name] or mix[peer], s)
      if solo and name ~= solo then m = true end
      if math.abs((tonumber(p.gain) or 1) - g) > 0.005 or (p.mute == true) ~= m then reaper.StudioSync_LiveAudioPeerSet(peer, g, m and 1 or 0) end
      local pg = liveaudio.play_gain(mix[name] or mix[peer], s)
      if (liveaudio.ducks[peer] or liveaudio.ducks[name] or -math.huge) > reaper.time_precise() then pg = 0 end -- (rt-share: their share's sound carries it; by computer, rt-p11)
      if name == ext("duck play") then pg = 0 end -- (producing them: their take streams on your grid instead. lib/producer.lua, rt-sonox)
      if can_play and math.abs((tonumber(p.play_gain) or 1) - pg) > 0.005 then reaper.StudioSync_LiveAudioPeerPlay(peer, pg) end
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

-- ---- Play's tracks: the armed ones, and the hidden live out track they send to ----------------------------------------------------------
-- The tracks that feed Play: armed here, and the song's or your own ("yours"), never StudioSync's helpers (Talk's, the click, hops, live out).
-- -> { track }, names, folded (the call mic first..first+nch-1 is one of their inputs).
function liveaudio.armed_tracks(proj, first, nch)
  local feed, names, folded = {}, {}, false
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    local tag = band.track_ext(tr, "band_local")
    if (tag == "" or tag == "yours") and reaper.GetMediaTrackInfo_Value(tr, "I_RECARM") == 1 then
      feed[#feed + 1] = tr
      names[#names + 1] = select(2, reaper.GetTrackName(tr))
      folded = folded or liveaudio.input_overlaps(reaper.GetMediaTrackInfo_Value(tr, "I_RECINPUT"), first, nch)
    end
  end
  return feed, names, folded
end
-- The live out track: hidden, this computer's own (band_local "liveout", never sent to the others), no master send (heard by nobody here),
-- real time (no anticipative FX), a StudioSync Hop whose send ring the extension reads, its chain's PDC "ignore" so the Hop's reported latency
-- delays nothing. add: make it when missing. -> track, hop id; or nil, nil, why.
function liveaudio.live_out(proj, add)
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    if band.track_ext(tr, "band_local") == liveaudio.LIVE_OUT_TAG then
      local id = math.tointeger(tonumber(band.track_ext(tr, "band_liveout_hop")))
      if id and reaper.TrackFX_GetCount(tr) > 0 then return tr, id end
      reaper.DeleteTrack(tr) -- (its Hop gone, a copy from another computer's project: made again below)
      break
    end
  end
  if not add then return nil end
  if S.out_fail_at and reaper.time_precise() - S.out_fail_at < 300 then return nil, nil, S.out_why end
  local hops = require("hops")
  local id = hops.free_id(hops.used_ids(proj), 64, 1)
  if not id then return nil, nil, "needs a free hop id (all 64 are taken)" end
  reaper.PreventUIRefresh(1)
  local tr = require("mirror").add_local_track(proj, liveaudio.LIVE_OUT, liveaudio.LIVE_OUT_TAG)
  reaper.SetMediaTrackInfo_Value(tr, "B_SHOWINTCP", 0)
  reaper.SetMediaTrackInfo_Value(tr, "B_SHOWINMIXER", 0)
  reaper.SetMediaTrackInfo_Value(tr, "B_MAINSEND", 0)
  reaper.SetMediaTrackInfo_Value(tr, "I_PERFFLAGS", math.floor(reaper.GetMediaTrackInfo_Value(tr, "I_PERFFLAGS")) | 2)
  local ok = hops.add_hop(tr, 0, id, 256, 0) ~= nil
  if ok then reaper.TrackFX_SetNamedConfigParm(tr, 0, "chain_pdc_mode", "2"); band.set_track_ext(tr, "band_liveout_hop", tostring(id)) end
  if not ok then reaper.DeleteTrack(tr) end
  reaper.TrackList_AdjustWindows(false)
  reaper.PreventUIRefresh(-1)
  if not ok then
    S.out_fail_at, S.out_why = reaper.time_precise(), "needs the StudioSync Hop plug-in here (run StudioSync's installer, then rescan plug-ins)"
    return nil, nil, S.out_why
  end
  return tr, id
end
-- The live out track's receives = exactly `feed`, each post-FX (I_SENDMODE 3: what you hear when you monitor it, before its fader). The
-- receives are read off its chunk's AUXRECV lines, as live.rt_sends does (core REAPER can't hand a send's track to Lua without SWS).
function liveaudio.play_sends(proj, out, feed)
  local want = {}
  for _, tr in ipairs(feed) do want[tr] = true end
  local _, chunk = reaper.GetTrackStateChunk(out, "", false)
  local from, fed = {}, {}
  for idx in chunk:gmatch("\n%s*AUXRECV (%d+)") do from[#from + 1] = tonumber(idx) end
  for r = #from, 1, -1 do -- (from the end, so the receive numbers stay right while removing)
    local src = reaper.GetTrack(proj, from[r])
    if src and want[src] and not fed[src] then fed[src] = true else reaper.RemoveTrackSend(out, -1, r - 1) end
  end
  for _, tr in ipairs(feed) do
    if not fed[tr] then
      local s = reaper.CreateTrackSend(tr, out)
      if s >= 0 then reaper.SetTrackSendInfo_Value(tr, 0, s, "I_SENDMODE", 3) end
    end
  end
end
-- Which sources go now, and the live out track kept in step (Live sync's tick). -> S.src: { mode, talk, play, folded, hop, armed (names), why }.
function liveaudio.update_sources(proj)
  local mode = liveaudio.source_mode()
  local src = { mode = mode, talk = true, play = false, folded = false, hop = 0, armed = {} }
  if not liveaudio.can_play() then
    src.why = mode ~= "auto" and mode ~= "talk" and "needs a newer StudioSync extension" or nil
    S.src = src
    return src
  end
  proj = proj or reaper.EnumProjects(-1)
  local first, nch = liveaudio.mine()
  local feed, names, folded = liveaudio.armed_tracks(proj, first, nch)
  local _, wants = liveaudio.source_plan(mode, #feed > 0, folded, true)
  local out, hop, why = liveaudio.live_out(proj, wants)
  local sends = wants and feed or {}
  local key = tostring(out)
  for _, tr in ipairs(sends) do key = key .. "|" .. tostring(tr) end
  if out and key ~= S.feed_key then liveaudio.play_sends(proj, out, sends); S.feed_key = key end -- (only when what's armed changes)
  src.talk, src.play = liveaudio.source_plan(mode, #feed > 0, folded, hop ~= nil)
  src.folded, src.hop, src.armed, src.why = folded, hop or 0, names, wants and why or nil
  S.src = src
  return src
end
-- The live out track goes (Live sync ends, the studio turns live audio off): Play stops first.
function liveaudio.drop_live_out(proj)
  if liveaudio.can_play() then reaper.StudioSync_LiveAudioPlay(0, 0) end
  S.play_asked, S.feed_key = nil, nil
  local out = liveaudio.live_out(proj or reaper.EnumProjects(-1), false)
  if out then reaper.DeleteTrack(out) end
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
  -- (what Talk sends: with the call mic going as Play instead, monitoring it is the point, not an echo)
  local talk_on = S.sending and S.sending.talk or (not S.sending and (liveaudio.send_plan(liveaudio.me(), liveaudio.can_gate())))
  local why = liveaudio.echo_why(names, mon, liveaudio.recent_level(), talk_on)
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
-- off), "ext", "tailscale", "firewall", "down" (it may run here but didn't start: no Tailscale address, its port taken), else "on", "muted",
-- "deaf" or "ptt". The first four are lib/hub.lua's NO_LA: such a computer hosts nobody's live mix and isn't elected a hub while another
-- can (LinuxBox2, off the tailnet, said "on" while its engine never started, and "you're the hub". rt-audio3).
function liveaudio.my_la()
  if S.code == "off" then return nil end
  if S.code then return S.code end
  if S.fail_why then return "down" end
  local s = liveaudio.me()
  return s.deaf and "deaf" or s.mute and "muted" or s.ptt and "ptt" or "on"
end

-- ---- The hub's live mix (docs/realtime-roadmap.md "More big ideas" 1; James, rt) --------------------------------------------------------
-- Peer to peer, each of N people sends N-1 streams and hears N-1. From the studio's threshold (band.json "live_hub", HUB_FROM people unless the
-- owner or an admin set it; 0 never) the song's hub (lib/hub.lua: whoever shared the song, it's in the room) mixes: each sends its Talk and
-- Play to it alone and hears one stream, built at the hub from that listener's own Talk/Play volumes (the cue mix travels with the request).
-- The extension does it (extension/rtaudio.cpp: the mixing on the hub's send thread, never REAPER's audio thread past a copy), and falls back to
-- everyone's own streams by itself within about a jitter buffer when the hub's mix stops (the hub dropping, handing on, pausing); Lua only
-- says who mixes. Nobody waits for anyone's extension (rt-hubfix: "waiting for Chilio-Mac to have the newer StudioSync extension" came and went
-- with the Mac's status file, and the whole room's audio switched with it): a computer whose extension is older than the hub's jobs need
-- (lib/hub.lua EXT) isn't elected hub and doesn't ask for a mix; it keeps its own streams with everyone, which the extension handles per peer.
function liveaudio.can_hub() return reaper.StudioSync_LiveAudioHub ~= nil end
function liveaudio.my_lhub() return liveaudio.can_hub() or nil end -- (for this computer's status file: "lhub")
-- This computer's extension takes part in the hub's mix: it has it, and it's new enough (the extension says its version in "menu extension").
function liveaudio.hub_fit()
  if not liveaudio.can_hub() then return false end
  local ok, fit = pcall(function() return require("hub").fit(reaper.GetExtState(band.SECTION, "menu extension")) end)
  return ok and fit == true
end
-- The room's size for the threshold, held: big enough once, it counts as big enough until it has been smaller for HUB_KEEP s (someone's
-- status coming late took them off the list for a moment, and everyone's audio switched to their own streams and back). mem: kept. Pure.
-- (rt-audio3: and it counts as big enough only once it has been so for HUB_SETTLE s. rt-r5: the Mac, asleep, came onto the link for 43 s,
-- a room of three was four, and everyone's audio went to the desktop's mix for 103 s and back in the middle of a sound test: two switches
-- for one computer passing by. Also used for how many of them send, below.)
function liveaudio.hub_n(mem, n, from, now)
  local held = mem.big_at ~= nil and now - mem.big_at < liveaudio.HUB_KEEP
  if n >= from then
    mem.since = mem.since or now
    if held or now - mem.since >= liveaudio.HUB_SETTLE then mem.big_at = now; return n end
    return math.min(n, from - 1)
  end
  mem.since = nil
  return held and from or n
end
-- How many computers in the room send live audio, this one too: all but those whose own word says they don't (muted or deafened, both
-- silence Talk and Play; live audio that can't run, lib/hub.lua NO_LA). A computer that hasn't said counts: it may be sending. las: user ->
-- their status's word (their_srcs); users: peer -> name of those here; mine: my_la(). Pure.
function liveaudio.senders(las, users, mine)
  local no, seen, n = require("hub").NO_LA or {}, {}, 0
  local function sends(w) return not (w == "muted" or w == "deaf" or no[w]) end
  if sends(mine) then n = 1 end
  for _, name in pairs(users or {}) do
    if not seen[name] then
      seen[name] = true
      if sends((las or {})[name]) then n = n + 1 end
    end
  end
  return n
end
function liveaudio.hub_from(root)
  local ok, v = pcall(function() return require("groups").live_hub(root) end)
  return ok and tonumber(v) or liveaudio.HUB_FROM
end
-- -> peer (the hub's "name:port", "" for peer to peer), serve (this computer mixes), why (Health's words when the room is big enough but it
-- isn't used, else nil). o: n (people here, me too), from (the threshold), hub (this song's hub), me, users (peer -> name: those here), can
-- (this computer's extension takes part: hub_fit), hub_fit (false: the hub's own extension is too old to mix, lib/hub.lua's view), budget
-- (false: this computer's mixing is paused, budget_why says why), running (false: live audio isn't running here), hub_la (the hub's own
-- word for its live audio, my_la in its status), senders (how many computers here send, liveaudio.senders held by hub_n; nil: not asked).
-- Pure.
-- (rt-audio3, from rt-r5: a room where only one computer sends has nothing to mix: through the hub its one stream is decoded, mixed with
-- nothing and encoded again for each listener, a hop and a codec more for the same sound. Peer to peer then, however big the room.)
-- (rt-audio3: a computer whose live audio can't run never mixes for the room, whoever elected it: here its own engine not running, there
-- its status's word, lib/hub.lua NO_LA. LinuxBox2, off the tailnet, was told to mix for the room between its failed starts.)
function liveaudio.hub_plan(o)
  local from = tonumber(o.from) or liveaudio.HUB_FROM
  if from <= 0 or (tonumber(o.n) or 1) < from then return "", false, nil end
  if o.senders and o.senders < 2 then return "", false, nil end
  if not o.can then return "", false, "needs a newer StudioSync extension here" end
  if not o.hub then return "", false, "this song has no hub here" end
  if o.hub == o.me and o.running == false then return "", false, "live audio isn't running on this computer, so it can't mix it for the room" end
  if o.hub ~= o.me and o.hub_la and require("hub").NO_LA[o.hub_la] then return "", false, o.hub .. "'s live audio isn't running, so its computer can't mix it for the room" end
  if o.hub ~= o.me and o.hub_fit == false then return "", false, o.hub .. "'s StudioSync extension is too old to mix it (REAPER there needs a restart after the update)" end
  local peer
  for p, name in pairs(o.users or {}) do if name == o.hub then peer = p end end
  if o.hub == o.me then return "", o.budget ~= false, o.budget == false and o.budget_why or nil end
  if not peer then return "", false, o.hub .. " (this song's hub) isn't on the direct link here" end
  return peer, false, nil
end
-- The hub is someone's working REAPER, so its mixing keeps to a budget: -> ok, why. h: the extension's status "hub"; recording: this REAPER
-- records; mem: kept between calls. Past HUB_REC_BUDGET of a core while it records: paused until the take ends; past HUB_BUDGET, or blocks
-- skipped (the mixing fell behind REAPER): paused HUB_COOL s. Paused, everyone goes back to their own streams (the extension does). Pure.
function liveaudio.hub_budget(h, recording, mem, now)
  h = type(h) == "table" and h or {}
  local load, skipped, serving = tonumber(h.load) or 0, tonumber(h.skipped) or 0, (tonumber(h.serving) or 0) > 0
  local fell = mem.skipped ~= nil and skipped > mem.skipped
  mem.skipped = skipped
  if mem.rec then
    if recording then return false, mem.why end
    mem.rec = nil
  end
  if mem.till and now < mem.till then return false, mem.why end
  mem.till = nil
  if serving and recording and load > liveaudio.HUB_REC_BUDGET then
    mem.rec, mem.why = true, string.format("paused while you record: mixing took %d%% of a core (%d%% allowed while recording)", math.floor(load * 100 + 0.5),
      math.floor(liveaudio.HUB_REC_BUDGET * 100 + 0.5))
    return false, mem.why
  end
  if serving and (load > liveaudio.HUB_BUDGET or fell) then
    mem.till = now + liveaudio.HUB_COOL
    mem.why = fell and "paused for a while: the mixing fell behind REAPER (blocks skipped)" or
      string.format("paused for a while: mixing took %d%% of a core (%d%% allowed)", math.floor(load * 100 + 0.5), math.floor(liveaudio.HUB_BUDGET * 100 + 0.5))
    return false, mem.why
  end
  return true, nil
end
-- Live sync's tick, after the engine is running: who mixes, handed to the extension when it changes.
function liveaudio.hub_tick(cfg, b, list, users, st)
  if not liveaudio.can_hub() then S.hub = nil; return end
  liveaudio.their_srcs(cfg) -- (their status words once a second: S.caps)
  local okv, v = pcall(function() return require("hub").view(cfg, b.song) end)
  S.hub_mem = S.hub_mem or {}
  local ok_b, why_b = liveaudio.hub_budget(st.hub, liveaudio.me().recording, S.hub_mem, reaper.time_precise())
  local hub = okv and type(v) == "table" and v.hub or nil
  -- (while shared CPU runs in the room, the best-connected computer mixes instead of the song's hub: lib/livex.lua, rt-sonox)
  local okx, xhub, pick, wait = pcall(require("livex").mix_host, cfg, b, hub, users, st, S)
  if okx then hub = xhub end
  local from = liveaudio.hub_from(cfg.root)
  local unfit = okv and type(v) == "table" and hub == v.hub and v.hub_fit == false -- (the song's hub itself: lib/livex.lua picks only one that can)
  S.hub_mem.send = S.hub_mem.send or {}
  local peer, serve, why = liveaudio.hub_plan({ n = liveaudio.hub_n(S.hub_mem, #(list or {}) + 1, from, reaper.time_precise()), from = from, hub = hub,
    me = cfg.user, users = users, can = liveaudio.hub_fit(), hub_fit = not unfit, budget = ok_b, budget_why = why_b,
    running = st.running ~= false, hub_la = hub and (S.las or {})[hub] or nil,
    senders = liveaudio.hub_n(S.hub_mem.send, liveaudio.senders(S.las, users, liveaudio.my_la()), 2, reaper.time_precise()) })
  if okx and wait and not hub and why then why = wait end
  S.hub = { peer = peer, serve = serve, why = why, user = hub, pick = okx and (peer ~= "" or serve) and pick or nil }
  local key = peer .. "|" .. tostring(serve)
  if key == S.hub_asked then return end
  reaper.StudioSync_LiveAudioHub(peer, serve and 1 or 0)
  local first = S.hub_asked == nil
  S.hub_asked = key
  if first and peer == "" and not serve then return end -- (a new engine in a small room: nothing to say)
  band.log(serve and "live audio: you mix it for the others here (each sends you one stream and hears one from you; Health shows the load)"
    or peer ~= "" and ("live audio: " .. tostring(hub) .. "'s computer mixes it for the room (you send one stream and hear one)")
    or ("live audio: peer to peer" .. (why and (" (the hub's mix: " .. why .. ")") or "")))
end

-- ---- a studio computer that sends here before this room lists it (rt-roomlist) ---------------------------------------------------------
-- Its live audio comes (tagged with the studio's secret) because its room lists this computer; this room lists it later (its status read
-- late here: Syncthing behind, its Live sync held by a dialog, the quiet status file) or not at all, and meanwhile the audio was one-way
-- (rt-small's not_here; the Mac's mix without the desktop, rt-hubfix). So such a computer is on the list here while it keeps sending (heard
-- within HEARD_S: it stops once its room drops this one), whether this room lists it yet or not. Never one that isn't a studio computer
-- trusted here: direct.studio_peer, as the room's own list.
liveaudio.HEARD_S = 15
-- Pure. list: the room's peers here; st: the extension's status (not_here_peers: address -> { ago }; peers[peer].heard_ago); peer_of(addr) ->
-- the peer ("name:port") and its user when it's a studio computer trusted here, else nil; kept: peer -> { at, user } (kept between calls,
-- changed here); now; near: user -> true while that computer is still in the room here (its status under hub.VOUCH s old: late, not gone),
-- nil: nobody. -> the list with the heard ones added (new, sorted), and peer -> user for those.
-- (rt-hubsmall: one heard once stays while it's near, silent or not. A sender whose talkback goes to someone else sends this computer nothing,
-- so it dropped off after HEARD_S though it was in the room all along, and came back only with its next word to everyone.)
function liveaudio.heard_merge(list, st, peer_of, kept, now, near)
  local listed, out, users = {}, {}, {}
  for _, p in ipairs(list or {}) do listed[p] = true; out[#out + 1] = p end
  for addr, e in pairs(type(st.not_here_peers) == "table" and st.not_here_peers or {}) do
    local ago = type(e) == "table" and tonumber(e.ago)
    if ago and ago < liveaudio.HEARD_S then
      local peer, user = peer_of(addr)
      if peer and not listed[peer] then kept[peer] = { at = math.max(now - ago, kept[peer] and kept[peer].at or -math.huge), user = user } end
    end
  end
  for peer, k in pairs(kept) do
    local p = type(st.peers) == "table" and st.peers[peer]
    local ago = type(p) == "table" and tonumber(p.heard_ago)
    if ago then k.at = math.max(k.at, now - ago) end
    if listed[peer] or (now - k.at > liveaudio.HEARD_S and not (near and near[k.user])) then kept[peer] = nil else out[#out + 1] = peer; users[peer] = k.user end
  end
  table.sort(out)
  return out, users
end
-- A computer neither side lists (rt-hubsmall; rt-roomlist left it): each one's status is late at the other (Syncthing behind, a dialog
-- holding Live sync), so neither sends audio or link messages to the other, and heard_merge has nothing to go by. What the link does carry
-- here: the statuses of the others, each with whom its own direct link reaches now (hub.sees, as lib/hub.lua vouches for a late computer).
-- So one whose status here is late but under hub.VOUCH s (near) while a computer whose status is fresh here (fresh: presence.peers) says
-- its link reaches it now goes on the list: this computer sends to it, its audio then reaches that one, whose heard_merge adds this one in
-- turn, and both hear each other until a status lands. A guest's word isn't counted (guests: name -> true), as for the song's hub.
-- Pure. list, users: the room's peers here and peer -> user; peer_of(user) -> its peer when it's a studio computer trusted here (as the room's
-- own list asks), else nil. -> the list with those added (new, sorted), and peer -> user for those.
function liveaudio.vouch_merge(list, users, fresh, near, peer_of, guests)
  local listed, have, by = {}, {}, {}
  for _, p in ipairs(list or {}) do listed[p] = true end
  for _, u in pairs(users or {}) do have[u] = true end
  for _, st in ipairs(fresh or {}) do
    if type(st) == "table" and type(st.user) == "string" and not (guests or {})[st.user] then
      have[st.user] = have[st.user] or false -- (fresh here: the room's own list has it, or can't have it (no Tailscale name): not this rule's)
      for u in pairs(require("hub").seen(st)) do by[u] = by[u] or st.user end
    end
  end
  local out, added = {}, {}
  for _, p in ipairs(list or {}) do out[#out + 1] = p end
  for user in pairs(near or {}) do
    if by[user] and have[user] == nil then
      local peer = peer_of(user)
      if peer and not listed[peer] then listed[peer] = true; out[#out + 1] = peer; added[peer] = user end
    end
  end
  table.sort(out)
  return out, added, by
end
-- What the two merges above read, as one string (rt-p12): the room's peers here, the addresses heard that it doesn't list, who's near, each
-- fresh status's time and whom its link reaches, and the heard ones kept. A change starts the merges again; else their last answer stands for
-- MERGE_HOLD s (the time-based parts, HEARD_S and hub.VOUCH, catch up within it). Pure.
liveaudio.MERGE_HOLD = 2
function liveaudio.merge_sig(list, st, near, fresh, heard)
  local addrs, sts, kept = {}, {}, {}
  for addr, e in pairs(type(st) == "table" and type(st.not_here_peers) == "table" and st.not_here_peers or {}) do
    if type(e) == "table" and tonumber(e.ago) and tonumber(e.ago) < liveaudio.HEARD_S then addrs[#addrs + 1] = tostring(addr) end
  end
  for _, s in ipairs(fresh or {}) do
    if type(s) == "table" then
      local seen = {} -- (whom its link reaches: hub.seen's st.hub.sees)
      for _, u in ipairs(type(s.hub) == "table" and type(s.hub.sees) == "table" and s.hub.sees or {}) do seen[#seen + 1] = tostring(u) end
      table.sort(seen)
      sts[#sts + 1] = tostring(s.user) .. "@" .. tostring(s.time) .. ":" .. table.concat(seen, ",")
    end
  end
  for p in pairs(heard or {}) do kept[#kept + 1] = tostring(p) end
  table.sort(addrs); table.sort(sts); table.sort(kept)
  return table.concat(list or {}, " ") .. "|" .. table.concat(addrs, " ") .. "|" .. table.concat(near or {}, " ") .. "|" .. table.concat(sts, " ") .. "|" .. table.concat(kept, " ")
end
-- A studio computer by its person's name: its devices file's Tailscale name, then direct.studio_peer (its own computer wrote that file, a
-- guest's list has the song), as heard_merge's address -> computer. -> its peer, or nil.
function liveaudio.peer_of_user(cfg, song, user)
  local t = require("groups").tailnet(cfg.root)
  local d = t and band.read_json(cfg.root .. "/_band/devices/" .. require("trust").user_file(user))
  local name = type(d) == "table" and d.user == user and type(d.ts) == "table" and d.ts[t.suffix]
  if type(name) ~= "string" then return nil end
  local direct = require("direct")
  local peer, u = direct.studio_peer(cfg, song, name .. ":" .. direct.port())
  return u == user and peer or nil
end
-- A not_here address ("100.x.y.z:port") -> the studio computer's peer and user, or nil: its Tailscale name from `tailscale status`, then the
-- studio's devices files (direct.studio_peer). The connection without Tailscale's synthetic addresses aren't looked up (lib/nat.lua lists those).
function liveaudio.peer_of_addr(cfg, song, addr)
  local direct = require("direct")
  local ip, port = tostring(addr):match("^(%d+%.%d+%.%d+%.%d+):(%d+)$")
  local name = ip and tonumber(port) == direct.port() and direct.ip_names()[ip]
  if not name then return nil end
  return direct.studio_peer(cfg, song, name .. ":" .. port)
end

-- Live sync's tick (the song in front drives it: one engine per computer). Never raises (band.try around it).
-- The output pair REAPER's master plays out of (rt-p11, backlog 1.24): dsts, its hardware outputs' I_DSTCHAN (first channel, &1024 mono,
-- &512 ReaRoute, not a device output). -> the first device output's first channel, 0-based; 0 (the first pair) when it has none. Pure.
function liveaudio.out_pair(dsts)
  for _, d in ipairs(type(dsts) == "table" and dsts or {}) do
    d = math.floor(tonumber(d) or -1)
    if d >= 0 and d & 512 == 0 then return d & 1023 end
  end
  return 0
end
-- Tells the extension the master's pair when it changes (a master routed to outputs 3/4: live audio mixes the bandmates there, and a share's
-- sound, guests and listeners take REAPER's mix from there).
local function tell_out_pair(proj)
  if not reaper.StudioSync_LiveAudioOutPair then return end
  local m = reaper.GetMasterTrack(proj or 0)
  local dsts = {}
  for i = 0, (m and reaper.GetTrackNumSends(m, 1) or 0) - 1 do dsts[#dsts + 1] = reaper.GetTrackSendInfo_Value(m, 1, i, "I_DSTCHAN") end
  local first = liveaudio.out_pair(dsts)
  if first ~= S.out_pair then S.out_pair = first; reaper.StudioSync_LiveAudioOutPair(first) end
end
function liveaudio.tick(cfg, b, proj)
  local now = reaper.time_precise()
  if now - S.at < liveaudio.EVERY then return end
  S.at = now
  if proj and reaper.EnumProjects(-1) ~= proj then return end
  pcall(tell_out_pair, proj)
  local direct, groups = require("direct"), require("groups")
  local on = cfg ~= nil and liveaudio.enabled(cfg.root)
  local avail = liveaudio.available()
  -- (the connection without Tailscale, lib/nat.lua: a studio with it on needs no tailnet, and a computer off the tailnet no Tailscale rule)
  local nat = require("nat")
  local secret = on and (groups.tailnet(cfg.root) or nat.enabled(cfg.root)) and groups.sonobus_secret(cfg.root) or nil
  S.why, S.code = liveaudio.why_not(on, avail, secret, not on or direct.firewall_ok("UDP") or nat.off_tailnet(cfg.root))
  -- (REAPER's audio device closed, as on the Mac after a restart: live audio sent and heard nothing until someone opened it. Opened once a
  -- session, 5 s in, so a device someone closes on purpose later stays closed. James: "a lot of things should happen automatically", rt)
  if on and not S.why and not S.reopened and reaper.Audio_IsRunning and reaper.Audio_IsRunning() ~= 1 then
    S.down_at = S.down_at or now
    if now - S.down_at >= 5 and reaper.Audio_Init then
      S.reopened = true
      reaper.Audio_Init()
      band.log("REAPER's audio device wasn't running, so live audio and recording couldn't work: opened it again" .. (reaper.Audio_IsRunning() == 1 and "" or " (it didn't start: look at Options > Preferences > Audio > Device)"))
    end
  else
    S.down_at = nil
  end
  local st = liveaudio.status()
  if S.why then
    if st.running and reaper.GetExtState(band.SECTION, "live audio by") ~= "" then -- (ours, from this tab or another: the studio's choice wins)
      reaper.StudioSync_LiveAudioStop()
      reaper.DeleteExtState(band.SECTION, "live audio by", false)
      band.log("live audio stopped: " .. S.why)
    end
    if S.src and S.src.hop ~= 0 then liveaudio.drop_live_out(proj) end -- (Play's hidden track goes with it)
    pcall(nat.peers, nil) -- (and the links without Tailscale: nothing carries them yet but live audio)
    S.json, S.src, S.sending, S.hub, S.hub_asked = nil, nil, nil, nil, nil
    return
  end
  S.b = b -- (the tab's song and room: Chat > Call reads the bandmates' statuses with it)
  local list, dev_of, users = direct.peers(cfg, b and b.song, b and b.room)
  local nok, nlist, nusers, ndevs = pcall(nat.peers, cfg, b) -- (bandmates the tailnet doesn't reach: "nat:<device>" in place of their Tailscale name)
  if nok and type(nlist) == "table" and #nlist > 0 then list, users = nat.merge(list, dev_of, users, nlist, nusers, ndevs) end
  if b and b.song then -- (and those whose live audio comes here though this room doesn't list them yet: rt-roomlist)
    S.heard = S.heard or {}
    local presence, room = require("presence"), b.room or "main"
    local okn, nl = pcall(presence.here, cfg, b.song, room, require("hub").VOUCH) -- (still in the room here: late, not gone. rt-hubsmall)
    local near = {}
    for _, u in ipairs(okn and type(nl) == "table" and nl or {}) do near[u] = true end
    local okf, fresh = pcall(presence.peers, cfg, b.song, room)
    -- (rt-p12, P8's rt-perfcut4 section 4: the merges below cost 2.2 ms a run, 42 ms at worst. Their answer is kept while what they read is
    -- the same, the floor MERGE_HOLD s, so an idle tick skips both merges and the peer lookups)
    local sig = liveaudio.merge_sig(list, st, okn and type(nl) == "table" and nl or {}, okf and type(fresh) == "table" and fresh or {}, S.heard)
    local mc = S.merged
    if mc and mc.sig == sig and now - mc.at < liveaudio.MERGE_HOLD then list, users = mc.list, mc.users
    else
      local hl, hu = liveaudio.heard_merge(list, st, function(addr) return liveaudio.peer_of_addr(cfg, b.song, addr) end, S.heard, now, near)
      -- (and those neither side lists while a computer here reaches them: rt-hubsmall. Their peer looked up at most every 10 s each)
      local u = {}
      for k, v in pairs(users or {}) do u[k] = v end
      for k, v in pairs(hu) do u[k] = v end
      S.vpeer = S.vpeer or {}
      local okv, vl, vu, by = pcall(liveaudio.vouch_merge, hl, u, okf and type(fresh) == "table" and fresh or {}, near, function(user)
        local c = S.vpeer[user]
        if not (c and now - c.at < 10) then local okp, p = pcall(liveaudio.peer_of_user, cfg, b.song, user); c = { at = now, peer = okp and p or nil }; S.vpeer[user] = c end
        return c.peer
      end, require("livex").guests(cfg.root))
      if not okv then vl, vu, by = hl, {}, {} end
      if #vl > #list then
        S.heard_said = S.heard_said or {}
        for k, v in pairs(hu) do
          if not S.heard_said[k] then
            S.heard_said[k] = true
            band.log("live audio: " .. tostring(v) .. "'s computer sends here before this room lists it (its status is late here), so it's heard and hears you meanwhile")
          end
        end
        for k, v in pairs(vu) do
          u[k] = v
          if not S.heard_said[k] then
            S.heard_said[k] = true
            band.log("live audio: " .. tostring(v) .. "'s status is late here, but " .. tostring(by[v]) .. "'s computer reaches it, so you send to it meanwhile (it then hears you, and you it)")
          end
        end
        list, users = vl, u
      end
      S.merged = { sig = sig, at = now, list = list, users = users }
    end
  end
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
      S.fail_why = nil -- (started: the next failure is said again)
      reaper.SetExtState(band.SECTION, "live audio by", tostring(proj), false)
      S.play_asked, S.hub_asked = nil, nil -- (a new engine: Play and the hub's mix asked for again)
      liveaudio.update_sources(proj)
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
      local why = tostring(liveaudio.status().error or "?")
      if liveaudio.fail_new(why) then band.log("live audio didn't start: " .. why) end -- (once, then on change: LinuxBox2 without Tailscale logged it every 10 s. rt-fix6b)
    end
    return
  end
  liveaudio.update_sources(proj) -- (Talk and Play: what's armed now)
  liveaudio.apply(st) -- (the mic and the cue mix kept here, put back on each bandmate: a new peer, or after a restart, starts at full level)
  if b and b.song then liveaudio.hub_tick(cfg, b, list, users, st) end -- (who mixes: the song's hub from the studio's threshold)
  if proj then pcall(require("livex").their_tick, proj, st) end -- (Their time's delay follows the measurement: rt-sonox)
end
-- A failed start's reason: true when it's new (said once, then only when it changes); kept for Health. rt-fix6b
function liveaudio.fail_new(why)
  if why == S.fail_why then return false end
  S.fail_why = why
  return true
end
-- Live sync ending in this tab: the engine stops if this tab started it.
function liveaudio.on_exit(proj)
  if liveaudio.can_play() and S.src and S.src.hop ~= 0 then pcall(liveaudio.drop_live_out, proj) end -- (Play's hidden track goes with this tab's Live sync)
  if not liveaudio.available() or reaper.GetExtState(band.SECTION, "live audio by") ~= tostring(proj) then return end
  reaper.StudioSync_LiveAudioStop()
  reaper.DeleteExtState(band.SECTION, "live audio by", false)
  pcall(require("nat").peers, nil) -- (the links without Tailscale go with it)
end

-- Why a bandmate isn't heard, from the word in their status (my_la). %s: the extension StudioSync wants.
liveaudio.THEM = { ext = "needs extension %s", tailscale = "not on the studio's Tailscale", firewall = "needs Windows' firewall rule (Set up live audio, in their Health)",
  down = "live audio didn't start there (their Health says why)" }
liveaudio.THEIR_MIC = { muted = "muted", deaf = "deafened", ptt = "push-to-talk" }
local function them(code)
  local t = liveaudio.THEM[code]
  if not t then return nil end
  local ok, tools = pcall(require, "tools")
  return (t:gsub("%%s", ok and type(tools) == "table" and tools.EXT_WANT or "1.0.13"))
end
-- Health's words for the hub's mix, or nil: through whose mix you hear and what its hop adds (the extension measures both ways: through the
-- hub now, and each stream's own before), or how many you mix for and its share of a core; fallbacks; why it isn't used. h: the extension's
-- status "hub"; names: peer -> bandmate; hubp: S.hub. Pure.
function liveaudio.hub_text(h, names, hubp)
  h = type(h) == "table" and h or {}
  local out = ""
  local hname = h.peer and h.peer ~= "" and ((names or {})[h.peer] or who(h.peer)) or nil
  local serving = tonumber(h.serving) or 0
  if h.serve and serving > 0 then
    out = string.format(" (you mix it for %d here: one stream each way per person; %d%% of a core)", serving, math.floor((tonumber(h.load) or 0) * 100 + 0.5))
  elseif h.serve then out = " (you mix it for the others here once they ask)"
  elseif h.state == "hub" and hname then
    local lat, dir = tonumber(h.latency_ms) or -1, tonumber(h.direct_ms) or -1
    out = " through " .. hname .. "'s mix" .. (lat >= 0 and string.format(", %.0f ms", lat) or "") ..
      (lat >= 0 and dir >= 0 and string.format(" (%.0f ms directly: +%.0f ms for the hub's hop)", dir, math.max(0, lat - dir)) or "")
  elseif h.state == "joining" and hname then out = "; joining " .. hname .. "'s mix"
  end
  -- (asked and no mix came in 5 s: that hub doesn't list this computer yet or isn't mixing; everyone's own streams meanwhile. rt-hubfix)
  local jf = tonumber(h.join_fails) or 0
  if jf > 0 and hname and h.state == "direct" and not h.serve then
    out = out .. string.format("; %s's mix didn't come when asked (%d time%s), so you hear everyone's own streams; asked again every 10 s", hname, jf, jf == 1 and "" or "s")
  end
  local fb = tonumber(h.fallbacks) or 0
  if fb > 0 then out = out .. string.format("; back to everyone's own streams %d time%s when the hub's mix stopped", fb, fb == 1 and "" or "s") end
  if type(hubp) == "table" and hubp.why then out = out .. "; the hub's mix: " .. hubp.why end
  if type(hubp) == "table" and hubp.pick then out = out .. "; " .. hubp.pick end -- (who mixes while shared CPU runs, and why: rt-sonox)
  return out ~= "" and out or nil
end
-- Health's words from the extension's status: ok (everyone heard, loss under 5%), text. names: peer -> bandmate; theirs: bandmate -> the word
-- in their status (my_la); s: this computer's mic (me()); src, sending: Talk and Play here (S.src, S.sending); hubp: the hub's mix (S.hub). Pure.
function liveaudio.health_text(st, names, theirs, s, src, sending, hubp)
  names, theirs = names or {}, theirs or {}
  local heard, each, ok, seen, bursty = {}, {}, true, {}, false
  for peer, p in pairs(type(st.peers) == "table" and st.peers or {}) do
    if type(p) == "table" then
      local name = names[peer] or who(peer)
      seen[name] = true
      local why = them(theirs[name])
      if not p.resolved then each[#each + 1] = name .. ": can't reach (" .. tostring(p.error) .. ")"; ok = false
      elseif p.via_hub then heard[#heard + 1] = name -- (in the hub's mix: its latency is the hub's, below)
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
          wifi and " (Wi-Fi?)" or "", loss, mic and (", " .. mic) or "") .. (p.play_streaming and ", playing" or "")
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
  local sends = liveaudio.sends_text(src, sending, st)
  if sends then text = text .. "; this computer " .. sends end
  if #heard > 0 then text = text .. "; hearing " .. table.concat(heard, ", ") end
  local hub = liveaudio.hub_text(st.hub, names, hubp)
  if hub then text = text .. hub end
  if bursty then text = text .. " (a buffer that grew means packets come in bursts, as over Wi-Fi: a wired network lowers it)" end
  if #each > 0 then text = text .. "; " .. table.concat(each, ", ") end
  if #heard + #each == 0 then text = text .. "; nobody else here yet" end
  if (tonumber(st.rejected) or 0) > 0 then
    local from = type(st.last_reject_from) == "string" and st.last_reject_from ~= "" and (" from " .. st.last_reject_from) or ""
    text = text .. string.format("; refused %d (last: %s%s)", st.rejected, tostring(st.last_reject), from)
  end
  -- (the studio's secret, but not on this computer's list for the room: it hears you, you don't take it in. Not a refusal: rt-small)
  local nh_now = type(st.not_here_peers) ~= "table" -- (an extension from before not_here_peers: the count alone, as before. rt-roomlist)
  for _, e in pairs(type(st.not_here_peers) == "table" and st.not_here_peers or {}) do nh_now = nh_now or (type(e) == "table" and (tonumber(e.ago) or math.huge) < 5) end
  if nh_now and (tonumber(st.not_here) or 0) > 0 and type(st.not_here_from) == "string" and st.not_here_from ~= "" then
    text = text .. "; " .. st.not_here_from .. " sends here but isn't in this room here yet (its status may be old here), so it isn't heard"
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
    if err == "" and S.fail_why then err = "didn't start: " .. S.fail_why end -- (the last failed start, said once in the log: rt-fix6b)
    return { "live audio", err == "", err == "" and "grey" or "yellow", "Live audio: starts while Live sync runs with a studio project in front.", "Live audio: " .. err }
  end
  local theirs = {}
  if b and b.song then
    local ok, sts = pcall(require("presence").peers, cfg, b.song, b.room or "main")
    for _, x in ipairs(ok and type(sts) == "table" and sts or {}) do if type(x) == "table" and x.user then theirs[x.user] = x.la end end
  end
  local ok, text = liveaudio.health_text(st, liveaudio.names(), theirs, liveaudio.me(), S.src, S.sending, S.hub)
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

-- The talk mic (James, findings 2026-11-27: "set the talk mic to the correct input, which could avoid switching when armed"). Live audio's Talk
-- is the input picked here; Auto sends an armed track as Play and, when the talk mic is that track's input, the mic goes once, as Play, so your
-- talk "switches" into the track as you arm it. The picker names the tracks that record from each input, says when the talk mic is an armed
-- track's, and offers the first input no track records from. tracks: { { name, inp = I_RECINPUT, armed } }; n: REAPER's input count.
-- -> users (0-based input -> "Guitar (armed), Bass"), clash (the armed track the talk mic folds into, or nil), free (the first input nobody
-- records from, outside the talk mic, or nil). Pure. (A second audio device, a USB headset beside the interface, needs the extension: it reads
-- only REAPER's own device's inputs. docs/rt/rt-setup.md has the plan. rt-setup)
function liveaudio.talk_advice(first, nch, n, tracks)
  local users, used, clash = {}, {}, nil
  for _, t in ipairs(tracks or {}) do
    local inp = math.floor(tonumber(t.inp) or -1)
    if inp >= 0 and inp & 4096 == 0 then
      local ch, w = inp & 1023, inp & 1024 ~= 0 and 2 or 1
      for c = ch, ch + w - 1 do
        used[c] = true
        local l = users[c] or {}
        users[c] = l
        l[#l + 1] = t.armed and (tostring(t.name) .. " (armed)") or tostring(t.name)
      end
      if t.armed and not clash and liveaudio.input_overlaps(inp, first, nch) then clash = tostring(t.name) end
    end
  end
  local free
  for i = 0, (n or 0) - nch do
    local ok = not (i < first + nch and first < i + nch)
    for c = i, i + nch - 1 do if used[c] then ok = false end end
    if ok then free = i; break end
  end
  local words = {}
  for c, l in pairs(users) do words[c] = table.concat(l, ", ") end
  return words, clash, free
end
local function advice(first, nch, n) -- (the project in front's tracks, read once a second: the picker draws every frame)
  local now = reaper.time_precise()
  local key = first .. ":" .. nch .. ":" .. n
  if S.advice and S.advice.key == key and now - S.advice.at < 1 then return S.advice.users, S.advice.clash, S.advice.free end
  local proj, tracks = reaper.EnumProjects(-1), {}
  for i = 0, (proj and reaper.CountTracks(proj) or 0) - 1 do
    local tr = reaper.GetTrack(proj, i)
    local tag = band.track_ext(tr, "band_local")
    if tag == "" or tag == "yours" then -- (StudioSync's own helper tracks aren't anyone's input)
      tracks[#tracks + 1] = { name = select(2, reaper.GetTrackName(tr)), inp = reaper.GetMediaTrackInfo_Value(tr, "I_RECINPUT"),
        armed = reaper.GetMediaTrackInfo_Value(tr, "I_RECARM") == 1 }
    end
  end
  local users, clash, free = liveaudio.talk_advice(first, nch, n, tracks)
  S.advice = { key = key, at = now, users = users, clash = clash, free = free }
  return users, clash, free
end
-- The talk mic: a list of REAPER's inputs, each with the tracks that record from it. -> changed
function liveaudio.input_picker(ctx, ImGui, id, width)
  local first, nch = liveaudio.mine()
  local n = reaper.GetNumAudioInputs and reaper.GetNumAudioInputs() or 0
  local users, clash, free = advice(first, nch, n)
  ImGui.SetNextItemWidth(ctx, width)
  local changed = false
  if ImGui.BeginCombo(ctx, id, n > 0 and (input_name(first) .. (nch > 1 and (" + " .. (nch - 1) .. " more") or "")) or "no inputs") then
    for i = 0, n - 1 do
      if ImGui.Selectable(ctx, input_name(i) .. (users[i] and ("  ·  " .. users[i]) or "") .. "##lai" .. i, i == first) then liveaudio.set_mine(i); changed = true end
    end
    if n == 0 then ImGui.TextDisabled(ctx, "No audio inputs: pick your interface in REAPER's Preferences > Audio > Device.") end
    ImGui.EndCombo(ctx)
  end
  ImGui.SetItemTooltip(ctx, "Your talk mic, only on this computer: the input you talk into (the first of a stereo pair). Pick one no track records " ..
    "from (a mic of its own, a spare input), and your talk stays separate when you arm a track. Changing it restarts live audio within a second.")
  if clash then
    ImGui.PushTextWrapPos(ctx, 0)
    ImGui.TextColored(ctx, require("theme").YELLOW, "Your talk mic is what " .. clash .. " records from: while it's armed, your talk goes as part of its " ..
      "playing, not on its own.")
    ImGui.PopTextWrapPos(ctx)
    if free and ImGui.SmallButton(ctx, "Talk on " .. input_name(free) .. " instead##lafree") then liveaudio.set_mine(free); changed = true end
    if free then ImGui.SetItemTooltip(ctx, "The first input no track records from. Plug the mic you talk into there (or pick another above).") end
  end
  if changed then S.advice = nil end
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
  local from = liveaudio.hub_from(cfg.root)
  local word = function(n) return n <= 0 and "never (peer to peer)" or ("from " .. n .. " people" .. (n == liveaudio.HUB_FROM and " (default)" or "")) end
  if may then
    ImGui.SetNextItemWidth(ctx, 200)
    if ImGui.BeginCombo(ctx, "The song's hub mixes it##livehub", word(from)) then
      for _, n in ipairs({ 3, 4, 5, 6, 8, 0 }) do
        if ImGui.Selectable(ctx, word(n), n == from) then
          require("groups").set_live_hub(cfg.root, n ~= liveaudio.HUB_FROM and n or nil)
          band.log("live audio: the song's hub mixes it " .. word(n))
        end
      end
      ImGui.EndCombo(ctx)
    end
    ImGui.SetItemTooltip(ctx, "Owner and admins. In a room this big, the song's hub (whoever shared it) mixes everyone's live audio: each computer sends " ..
      "one stream and hears one, at its own volumes, instead of one to and from everyone. It adds the hub's hop (Health shows how much), pauses while " ..
      "the hub records if it costs too much, and falls back to everyone's own streams within a jitter buffer when the hub drops.")
  else ImGui.TextDisabled(ctx, "The song's hub mixes it " .. word(from) .. ".") end
  local _, nch, kbps = liveaudio.mine()
  liveaudio.input_picker(ctx, ImGui, "Talk mic##liveaudioin", 220)
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
  if liveaudio.can_play() then -- (Talk and Play: what this computer sends, its own choice)
    local mode = liveaudio.source_mode()
    ImGui.SetNextItemWidth(ctx, 130)
    if ImGui.BeginCombo(ctx, "##lasrc", "Send: " .. liveaudio.MODES[mode]) then
      for _, m in ipairs(liveaudio.MODE_ORDER) do if ImGui.Selectable(ctx, liveaudio.MODES[m] .. "##lasrc" .. m, m == mode) then liveaudio.set_source_mode(m) end end
      ImGui.EndCombo(ctx)
    end
    ImGui.SetItemTooltip(ctx, "Only on this computer. Talk: your call mic. Play: every armed track as you hear it monitored (amp sims, synths, MIDI " ..
      "instruments). Auto: Talk until you arm a track, then Play, plus Talk unless your call mic is that track's input (then it goes once, as Play).")
    ImGui.SameLine(ctx)
    local sends = liveaudio.sends_text(S.src, S.sending, st)
    ImGui.TextDisabled(ctx, sends and (sends:gsub(" %[.-%]", "")) or "sends Talk")
  end
  ImGui.ProgressBar(ctx, math.min(1, liveaudio.recent_level()), -1, 6, "")
  ImGui.SetItemTooltip(ctx, "Your input's level" .. ((liveaudio.send_plan(s, gate)) and ", as it goes out." or ": muted, nothing goes out."))
  local mdb = cw.db_of(s.volume)
  ImGui.SetNextItemWidth(ctx, -1)
  local vch, vv = ImGui.SliderDouble(ctx, "##lamaster", math.max(-60, math.min(12, mdb)), -60, 12, mdb <= -60 and "Everyone: off" or "Everyone: %.1f dB")
  if vch then liveaudio.set_volume(cw.vol_of(vv)) end
  ImGui.SetItemTooltip(ctx, "How loud everyone comes in, only for you (each person's own volume is below). Ctrl+click to type a value.")
  if not st.running then ImGui.TextDisabled(ctx, "Starts while Live sync runs with a studio project in front (Health says what's missing)."); return end
  local peers = {}
  for peer in pairs(type(st.peers) == "table" and st.peers or {}) do peers[#peers + 1] = peer end
  table.sort(peers)
  if #peers == 0 then ImGui.TextDisabled(ctx, "Nobody else here yet.") end
  local names, mix, tb_to, can_play = liveaudio.names(), liveaudio.mix(), ext("talkback to"), liveaudio.can_play()
  local srcs = can_play and liveaudio.their_srcs(cfg) or {}
  for _, peer in ipairs(peers) do
    local p, name = st.peers[peer], liveaudio.name_of(peer, names)
    local want = mix[name] or mix[peer] or {}
    local theirs = can_play and liveaudio.their_src(srcs[name], p)
    ImGui.Text(ctx, name .. (p.streaming and "" or " (not heard yet)") .. (theirs and (": " .. theirs) or ""))
    ImGui.ProgressBar(ctx, math.min(1, math.max(tonumber(p.level) or 0, tonumber(p.play_level) or 0)), -1, 6, "")
    local gain, mute = tonumber(want.gain) or 1, want.mute == true
    local db = cw.db_of(gain)
    ImGui.SetNextItemWidth(ctx, -130)
    local ch, v = ImGui.SliderDouble(ctx, "##lavol" .. peer, math.max(-60, math.min(12, db)), -60, 12, db <= -60 and (can_play and "Talk: off" or "off") or (can_play and "Talk: %.1f dB" or "%.1f dB"))
    if ch then liveaudio.set_peer(peer, cw.vol_of(v), mute) end
    ImGui.SetItemTooltip(ctx, "How loud " .. name .. (can_play and "'s Talk (their call mic)" or "") .. " comes in, only for you, kept for " .. name .. ". Ctrl+click to type a value.")
    if can_play then -- (the personal monitor mix: their playing apart from their talking, never the song's mix. James, rt)
      local pdb = cw.db_of(tonumber(want.play) or 1)
      ImGui.SetNextItemWidth(ctx, -130)
      local pch, pv = ImGui.SliderDouble(ctx, "##laplay" .. peer, math.max(-60, math.min(12, pdb)), -60, 12, pdb <= -60 and "Play: off" or "Play: %.1f dB")
      if pch then liveaudio.set_peer(peer, gain, mute, cw.vol_of(pv)) end
      ImGui.SetItemTooltip(ctx, "How loud " .. name .. "'s Play (their armed tracks, as they monitor them) comes in, only for you, kept for " .. name .. ". Ctrl+click to type a value.")
    end
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
