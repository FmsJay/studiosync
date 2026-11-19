-- Live audio over the link (docs/realtime-roadmap.md step 4: StudioSync's own, replacing SonoBus in time). The extension does the work
-- (extension/rtaudio.cpp: AOO + Opus over Tailscale UDP on the link's port, a jitter buffer per bandmate, mixed into this computer's
-- first output pair, never recorded); this file decides when it runs and shows it:
--  - the studio's setting (band.json "live_audio", owner and admins: off unless they turn it on), Settings > Studio under the direct link;
--  - this computer's own choice (ExtState, kept): which inputs it sends, mono or stereo, and Opus's rate;
--  - Live sync's tick starts it with the studio secret (the direct link's key) for the bandmates here (direct.peers), and stops it when the
--    studio turns it off; the song in front drives it (one engine per computer), and the tab that started it stops it when its Live sync ends;
--  - Health's row: latency, jitter buffer and loss per bandmate, and Set up live audio on Windows (the UDP twin of the link's firewall rule);
--  - the panel's Chat > Call: each bandmate's level, volume and mute in what you hear (the cue mix), kept per bandmate.
-- (James, rt)
local band = require("band")
local liveaudio = { KBPS = 128, EVERY = 0.5, RETRY = 10 }
local S = { at = -math.huge, json = nil, fail_at = -math.huge } -- (this script's state: the JSON last handed over, the last start that failed)
liveaudio.S = S

function liveaudio.available()
  return reaper.StudioSync_LiveAudioStart ~= nil and reaper.StudioSync_LiveAudioStop ~= nil and reaper.StudioSync_LiveAudioPeers ~= nil
    and reaper.StudioSync_LiveAudioStatus ~= nil and reaper.StudioSync_LiveAudioPeerSet ~= nil
end
function liveaudio.enabled(root)
  local ok, on = pcall(function() return require("groups").live_audio(root) end)
  return ok and on == true
end

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

-- The cue mix, kept on this computer: peer -> { gain (linear), mute }.
function liveaudio.mix() local m = band.ext_json(band.SECTION, "live audio mix"); return type(m) == "table" and m or {} end
function liveaudio.set_peer(peer, gain, mute)
  local m = liveaudio.mix()
  m[peer] = { gain = math.max(0, math.min(4, tonumber(gain) or 1)), mute = mute == true }
  band.set_ext_json(band.SECTION, "live audio mix", m, true)
  if liveaudio.available() then reaper.StudioSync_LiveAudioPeerSet(peer, m[peer].gain, m[peer].mute and 1 or 0) end
end

-- What the extension takes (StudioSync_LiveAudioPeers): the studio secret, this computer's port, the bandmates' "name:port". Pure.
function liveaudio.peers_json(secret, port, peers) return band.json_encode({ secret = secret, port = math.floor(port), peers = peers or {} }) end
function liveaudio.status()
  if not liveaudio.available() then return {} end
  local st = band.json_decode(reaper.StudioSync_LiveAudioStatus())
  return type(st) == "table" and st or {}
end

-- Why it isn't running for this studio here, or nil when it may. Pure apart from what it's handed.
function liveaudio.why_not(on, available, secret, firewall)
  if not on then return "off for this studio" end
  if not available then return "needs StudioSync's extension with live audio (Extensions > ReaPack > Synchronize packages, then restart REAPER)" end
  if not secret then return "needs the studio on Tailscale with its secret (Settings > Studio)" end
  if not firewall then return "Windows needs its firewall rule first: press Set up live audio in Health" end
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
  S.why = liveaudio.why_not(on, avail, secret, not on or direct.firewall_ok("UDP"))
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
  local json = liveaudio.peers_json(secret, direct.port(), (direct.peers(cfg, b and b.song, b and b.room)))
  if json ~= S.json or not st.running then reaper.StudioSync_LiveAudioPeers(json); S.json = json end
  local first, nch, kbps = liveaudio.mine()
  if st.running and (tonumber(st.first) ~= first or tonumber(st.nch) ~= nch or tonumber(st.kbps) ~= kbps) then -- (a new choice here: start again with it)
    reaper.StudioSync_LiveAudioStop()
    st.running = false
  end
  if not st.running and now - S.fail_at > liveaudio.RETRY then
    if reaper.StudioSync_LiveAudioStart(first, nch, kbps) == 1 then
      reaper.SetExtState(band.SECTION, "live audio by", tostring(proj), false)
      band.log(string.format("live audio on: sending input %d%s at %d kbit/s to the others here; theirs comes out of your first output pair", first + 1,
        nch > 1 and ("-" .. (first + nch)) or "", kbps))
    else
      S.fail_at = now
      band.log("live audio didn't start: " .. tostring(liveaudio.status().error or "?"))
    end
    return
  end
  -- (the cue mix kept here, put back on each bandmate the extension knows: a new peer, or after a restart, starts at full level)
  for peer, p in pairs(type(st.peers) == "table" and st.peers or {}) do
    local want = liveaudio.mix()[peer]
    if want and type(p) == "table" and (math.abs((tonumber(p.gain) or 1) - want.gain) > 0.005 or (p.mute == true) ~= (want.mute == true)) then
      reaper.StudioSync_LiveAudioPeerSet(peer, want.gain, want.mute and 1 or 0)
    end
  end
end
-- Live sync ending in this tab: the engine stops if this tab started it.
function liveaudio.on_exit(proj)
  if not liveaudio.available() or reaper.GetExtState(band.SECTION, "live audio by") ~= tostring(proj) then return end
  reaper.StudioSync_LiveAudioStop()
  reaper.DeleteExtState(band.SECTION, "live audio by", false)
end

local function who(peer) return tostring(peer):match("^([^%.:]+)") or tostring(peer) end
liveaudio.who = who
-- Health's words from the extension's status: ok (everyone heard, loss under 5%), text. Pure.
function liveaudio.health_text(st)
  local each, ok = {}, true
  for peer, p in pairs(type(st.peers) == "table" and st.peers or {}) do
    if type(p) == "table" then
      if not p.resolved then each[#each + 1] = who(peer) .. ": can't reach (" .. tostring(p.error) .. ")"; ok = false
      elseif not p.streaming then each[#each + 1] = who(peer) .. ": not heard yet"; ok = false
      else
        local loss = (tonumber(p.loss) or 0) * 100
        if loss >= 5 then ok = false end
        each[#each + 1] = string.format("%s %.0f ms (buffer %.0f ms, loss %.1f%%)", who(peer), tonumber(p.latency_ms) or -1, tonumber(p.buffer_ms) or -1, loss)
      end
    end
  end
  table.sort(each)
  local nch = tonumber(st.nch) or 1
  local text = string.format("Live audio: sending %s at %d kbit/s", nch > 1 and (nch .. " inputs") or "1 input", tonumber(st.kbps) or 0)
  text = text .. (#each > 0 and ("; " .. table.concat(each, ", ")) or "; nobody else here yet")
  if (tonumber(st.rejected) or 0) > 0 then text = text .. string.format("; refused %d (last: %s)", st.rejected, tostring(st.last_reject)) end
  return ok and #each > 0, text
end
-- Health's row (lib/direct.lua health_rows): nil while the studio has live audio off.
function liveaudio.health_row(cfg)
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
  local ok, text = liveaudio.health_text(st)
  return { "live audio", ok, "yellow", text, text }
end

-- Settings > Studio, under the direct link: the studio's switch (owner and admins) and this computer's inputs.
function liveaudio.studio_ui(ctx, ImGui, cfg, may)
  ImGui.SeparatorText(ctx, "Live audio")
  local on = liveaudio.enabled(cfg.root)
  ImGui.TextDisabled(ctx, on and "On: while Live sync runs, each computer sends its chosen inputs to the others here over Tailscale (Opus, about " ..
    "40 ms plus the network) and hears theirs out of its first output pair. Never recorded. Chat > Call has each person's volume and mute." or
    "Off: StudioSync's own live audio isn't used (SonoBus carries Real time mode).")
  if may then
    local ch, v = ImGui.Checkbox(ctx, "Live audio##studiolive", on)
    if ch then
      require("groups").set_live_audio(cfg.root, v)
      band.log(v and "live audio is on for the studio" or "live audio is off for the studio")
    end
    ImGui.SetItemTooltip(ctx, "Owner and admins. Each computer needs StudioSync's extension with live audio, Tailscale, and on Windows the firewall rule (Health).")
  end
  if not on then return end
  local first, nch, kbps = liveaudio.mine()
  local n = reaper.GetNumAudioInputs and reaper.GetNumAudioInputs() or 0
  local function name(i) return (reaper.GetInputChannelName and reaper.GetInputChannelName(i)) or ("Input " .. (i + 1)) end
  ImGui.SetNextItemWidth(ctx, 220)
  if ImGui.BeginCombo(ctx, "This computer sends##liveaudioin", n > 0 and (name(first) .. (nch > 1 and (" + " .. (nch - 1) .. " more") or "")) or "no inputs") then
    for i = 0, n - 1 do
      if ImGui.Selectable(ctx, name(i) .. "##lai" .. i, i == first) then liveaudio.set_mine(i) end
    end
    ImGui.EndCombo(ctx)
  end
  ImGui.SetItemTooltip(ctx, "Only on this computer. Your mic or instrument input (the first of a stereo pair). Changing it restarts live audio within a second.")
  local sch, stereo = ImGui.Checkbox(ctx, "Stereo pair##liveaudiost", nch >= 2)
  if sch then liveaudio.set_mine(nil, stereo and 2 or 1) end
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, 140)
  local kch, k = ImGui.SliderInt(ctx, "kbit/s##liveaudiokbps", kbps, 64, 256)
  if kch then liveaudio.set_mine(nil, nil, k) end
  ImGui.SetItemTooltip(ctx, "Opus's rate for what you send. 128 is plenty for a voice or an instrument; more for a stereo mix.")
  if S.why and S.why ~= "off for this studio" then ImGui.TextDisabled(ctx, "Not running here: " .. S.why .. ".") end
end

-- Chat > Call: each bandmate you hear, their level, volume and mute (only for you: the cue mix). Nothing while it isn't running here.
function liveaudio.call_ui(ctx, ImGui, cfg)
  if not (cfg and liveaudio.enabled(cfg.root)) then return end
  ImGui.SeparatorText(ctx, "Live audio (StudioSync)")
  local st = liveaudio.status()
  if not st.running then ImGui.TextDisabled(ctx, "Starts while Live sync runs with a studio song in front (Health says what's missing)."); return end
  ImGui.ProgressBar(ctx, math.min(1, tonumber(st.level) or 0), -1, 6, "")
  ImGui.SetItemTooltip(ctx, "What you send.")
  local peers = {}
  for peer in pairs(type(st.peers) == "table" and st.peers or {}) do peers[#peers + 1] = peer end
  table.sort(peers)
  if #peers == 0 then ImGui.TextDisabled(ctx, "Nobody else here yet.") end
  local cw = require("callwin")
  for _, peer in ipairs(peers) do
    local p = st.peers[peer]
    ImGui.Text(ctx, who(peer) .. (p.streaming and "" or " (not heard yet)"))
    ImGui.ProgressBar(ctx, math.min(1, tonumber(p.level) or 0), -1, 6, "")
    local gain, mute = tonumber(p.gain) or 1, p.mute == true
    local db = cw.db_of(gain)
    ImGui.SetNextItemWidth(ctx, -70)
    local ch, v = ImGui.SliderDouble(ctx, "##lavol" .. peer, math.max(-60, math.min(12, db)), -60, 12, db <= -60 and "off" or "%.1f dB")
    if ch then liveaudio.set_peer(peer, cw.vol_of(v), mute) end
    ImGui.SetItemTooltip(ctx, "How loud " .. who(peer) .. " comes in, only for you. Ctrl+click to type a value.")
    ImGui.SameLine(ctx)
    local mch, m = ImGui.Checkbox(ctx, "Mute##lamute" .. peer, mute)
    if mch then liveaudio.set_peer(peer, gain, m) end
  end
end

return liveaudio
