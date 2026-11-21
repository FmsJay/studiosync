-- SonoBus's extras rebuilt on the studio's own live audio (rt-sonox, James 2026-11-20: "rebuild the useful ones on built-in audio"), and who
-- mixes the live audio while shared CPU runs (James: the hub's live mix goes to the best-connected computer "only when on shared cpu mode").
--  - Solo: only one bandmate in your ears, through the cue mix the extension already has (their Talk and Play muted for everyone else, here
--    only; the hub's mix takes the same mutes with each listener's request). Not kept: it ends with REAPER, or when they leave.
--  - Their time: your backing later by the latency of the bandmate you're lined up with (the extension measures each stream: half the round
--    trip, the jitter buffer and both ends' codec), so what they play to their copy lines up with yours. Play together (0 bars behind, on the
--    shared clock) carries the transport; the delay is StudioSync's live mix on your master (lib/hear.lua, never sent: mirror.live_fx).
--  - A guest without Tailscale: a REAPER guest by invitation, reached through the connection without Tailscale (lib/nat.lua: NAT links,
--    the studio hub's relay), with every guest limit as before (lib/removal.lua's end date and projects, never a hub, never anyone's shared CPU).
--  - Produce: lib/producer.lua's "live" route (no SonoBus, no stamps): their takes stream on your grid (lib/streams.lua), Talk stays live.
--  - The live mix's host while shared CPU (lib/hops.lua offloads) runs anywhere in the room: wired over Wi-Fi, the lowest round trip to the
--    others, CPU headroom by the `cpu` every computer already publishes; never a guest or a computer handed on. The same answer on every
--    computer from the same status files; the one mixing now keeps it unless another is clearly better. Otherwise the song's hub (lib/hub.lua).
local band = require("band")
local livex = { THEIR_EVERY = 2, THEIR_STEP = 10, THEIR_START = 100, NUDGE = 300, RTT_STEP = 20, BUSY = 75, SETTLE = 4, NET_EVERY = 300, GUESTS_EVERY = 10,
  LRTT_FLOOR = 10 } -- (NET_EVERY: the network probe starts a hidden PowerShell on Windows; a network type rarely changes. LRTT_FLOOR: livex.lrtt)
local S = { their_at = -math.huge }
livex.S = S

-- ---- Solo -------------------------------------------------------------------------------------------------------------------------------
local SOLO = "live audio solo"
function livex.solo() local v = reaper.GetExtState(band.SECTION, SOLO); return v ~= "" and v or nil end
function livex.set_solo(name)
  if name then reaper.SetExtState(band.SECTION, SOLO, name, false) else reaper.DeleteExtState(band.SECTION, SOLO, false) end
  band.log(name and ("live audio: only " .. name .. " in your ears (Solo; only for you)") or "live audio: everyone in your ears again")
  pcall(require("liveaudio").apply)
end
-- The soloed bandmate, only while they're one of the live audio's peers here (someone who left doesn't silence everyone). peers: the
-- extension's status peers; names: peer -> name; solo: livex.solo(). Pure.
function livex.solo_in(peers, names, solo)
  if not solo then return nil end
  for peer in pairs(type(peers) == "table" and peers or {}) do
    if ((names or {})[peer] or tostring(peer):match("^([^%.:]+)")) == solo then return solo end
  end
  return nil
end

-- ---- Their time -------------------------------------------------------------------------------------------------------------------------
local function px(proj, k) return select(2, reaper.GetProjExtState(proj, band.SECTION, k)) end
local function setpx(proj, k, v) reaper.SetProjExtState(proj, band.SECTION, k, v) end
function livex.their_on(proj) return proj ~= nil and px(proj, "their time live") == "1" end
function livex.nudge(proj) return math.max(-livex.NUDGE, math.min(livex.NUDGE, math.floor(tonumber(px(proj, "their nudge")) or 0))) end
function livex.set_nudge(proj, ms) setpx(proj, "their nudge", tostring(math.max(-livex.NUDGE, math.min(livex.NUDGE, math.floor(ms))))); S.their_at = -math.huge end
-- Whom to line up with and how late they arrive (ms): the soloed one; else the latest of those sending Play (playing an armed track), else
-- the latest of everyone heard. In the hub's mix a bandmate arrives as late as the mix does. st: the extension's status. -> ms, name; or nil. Pure.
function livex.their_ms(st, names, solo)
  st = type(st) == "table" and st or {}
  local hub = type(st.hub) == "table" and tonumber(st.hub.latency_ms) or -1
  local best, who, play
  for peer, p in pairs(type(st.peers) == "table" and st.peers or {}) do
    if type(p) == "table" then
      local name = (names or {})[peer] or tostring(peer):match("^([^%.:]+)")
      local lat = p.via_hub and hub or (p.streaming and tonumber(p.latency_ms)) or -1
      if lat > 0 and (not solo or name == solo) then
        local pl = p.play_streaming == true
        -- (a Play sender outranks anyone only talking; among the same kind, the latest)
        if not best or (pl and not play) or (pl == play and (lat > best or (lat == best and name < who))) then best, who, play = lat, name, pl end
      end
    end
  end
  if not best then return nil end
  return math.floor(best + 0.5), who
end
-- The delay to set, or nil when it needn't move (a step under THEIR_STEP ms isn't worth the click a delay change makes). Pure.
function livex.their_next(measured, nudge, cur)
  if not measured then return nil end
  local t = math.max(0, math.min(require("hear").MAX_MS, measured + (nudge or 0)))
  if cur and math.abs(t - cur) < livex.THEIR_STEP then return nil end
  return t
end
function livex.set_their(proj, on)
  local hear = require("hear")
  if on then
    if not hear.mix(proj, true) then return nil, "couldn't put StudioSync's live mix on the master (it delays your backing)" end
    if px(proj, "side before their") == "" then setpx(proj, "side before their", px(proj, "side") ~= "" and px(proj, "side") or "none") end
    setpx(proj, "side", "0") -- (Play together: everyone's transport starts at the same moment on the shared clock)
    setpx(proj, "their time live", "1")
    local m = band.ext_json(band.SECTION, "their measured " .. tostring(proj))
    local ms = livex.their_next(type(m) == "table" and tonumber(m.ms) or livex.THEIR_START, livex.nudge(proj), nil)
    hear.set_delay(proj, ms)
    S.their_at = -math.huge
    band.log(string.format("Their time on: your backing %d ms later, so whoever plays reaches you in time with it (measured as you play together)", ms))
    return true
  end
  if not livex.their_on(proj) then return true end
  local was = px(proj, "side before their")
  if px(proj, "side") == "0" then setpx(proj, "side", was == "none" and "" or was) end
  setpx(proj, "side before their", "")
  setpx(proj, "their time live", "")
  hear.set_delay(proj, 0)
  band.log("Their time off: your backing on time again")
  return true
end
-- Live sync's tick (after live audio's): the delay follows the measurement. Play together turned off another way (another Real time way, a
-- project reopened: lib/live.lua all_off clears "side") turns Their time off with it.
function livex.their_tick(proj, st)
  if not livex.their_on(proj) or reaper.time_precise() - S.their_at < livex.THEIR_EVERY then return end
  S.their_at = reaper.time_precise()
  if px(proj, "side") ~= "0" then
    setpx(proj, "side before their", ""); setpx(proj, "their time live", ""); require("hear").set_delay(proj, 0)
    return band.log("Their time off: Play together went off")
  end
  local la = require("liveaudio")
  local ms, who = livex.their_ms(st, la.names(), livex.solo_in(st and st.peers, la.names(), livex.solo()))
  band.set_ext_json(band.SECTION, "their measured " .. tostring(proj), ms and { ms = ms, who = who } or {}, false)
  local hear = require("hear")
  local t = livex.their_next(ms, livex.nudge(proj), hear.delay(proj))
  if t then hear.set_delay(proj, t) end
end
-- Home's words under Their time: -> the delay line. m: the last measurement ({ ms, who }), delay: the live mix's now, nudge. Pure.
function livex.their_line(m, delay, nudge)
  m = type(m) == "table" and m or {}
  local d = math.floor((tonumber(delay) or 0) + 0.5)
  local base = tonumber(m.ms) and string.format("%s arrives %d ms late", tostring(m.who), m.ms) or "measured once someone plays with you"
  return string.format("Your backing %d ms later: %s%s", d, base, (nudge or 0) ~= 0 and string.format(", %+d ms nudge", nudge) or "")
end
livex.THEIR_TIP = "Your backing plays later by how late the others reach you, so what they play to their copy lines up with yours. Everyone's " ..
  "transport goes together (Play together, on the shared clock). Measured all the time from the studio's live audio: the soloed bandmate, else " ..
  "whoever plays an armed track, else the latest. For playing along to them: they hear you a round trip late, as the network makes it, so " ..
  "lead/follow works, everyone-at-once doesn't (In time does that). What you record lands this much late on your grid (move it earlier by " ..
  "the delay, or record in My time). The metronome isn't delayed."
-- Home, under Their time while it's on.
function livex.their_ui(ctx, ImGui, proj)
  local line = livex.their_line(band.ext_json(band.SECTION, "their measured " .. tostring(proj)), require("hear").delay(proj), livex.nudge(proj))
  ImGui.TextDisabled(ctx, line)
  ImGui.SetItemTooltip(ctx, livex.THEIR_TIP)
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, 90)
  local ch, v = ImGui.DragInt(ctx, "##theirnudge", livex.nudge(proj), 1, -livex.NUDGE, livex.NUDGE, "%+d ms")
  if ch then livex.set_nudge(proj, v) end
  ImGui.SetItemTooltip(ctx, "A nudge on top of the measurement, for what it can't see (their interface's own latency, say). Drag, or double-click to type.")
end

-- ---- Real time ways on Home ------------------------------------------------------------------------------------------------------------
-- The ways Home offers: SonoBus's only without the studio's own live audio (or while one is still on and has no built-in twin); the built-in
-- ones (`builtin = true`) only with it. Pure.
function livex.offered(kinds, builtin, now)
  local twin, out = {}, {}
  for _, k in ipairs(kinds) do if k.builtin then twin[k[1]] = true end end
  for _, k in ipairs(kinds) do
    if k.builtin then if builtin then out[#out + 1] = k end
    elseif k.sonobus and builtin then if now == k[1] and not twin[k[1]] then out[#out + 1] = k end
    else out[#out + 1] = k end
  end
  return out
end

-- ---- A guest without Tailscale -----------------------------------------------------------------------------------------------------------
-- Can a guest reach this studio without its Tailscale? -> ok, why not. nat_on: the studio's "Connect without Tailscale"; nat_here: this
-- extension has it; may: owner or admin. Pure.
function livex.guest_ready(nat_on, nat_here, may)
  if not nat_here then return false, "this computer's StudioSync extension doesn't have the connection without Tailscale yet (Extensions > ReaPack > Synchronize packages)" end
  if not nat_on then return false, may and "off" or "the studio's Connect without Tailscale is off: the owner or an admin turns it on (Settings > Studio)" end
  return true
end
livex.GUEST_TIP = "For a guest who won't install Tailscale: the invitation installs REAPER and StudioSync, and once you've let them in they " ..
  "hear and are heard through the studio's own live audio over StudioSync's connection without Tailscale (straight through both home networks, " ..
  "or relayed by the studio hub). Guest limits as ever: in until the day you pick, only the projects you tick, never a hub or the live mix, " ..
  "never anyone's shared CPU, and the room's rules for what they may change. (Browser guests, from the web UI, still need the studio's Tailscale.)"
-- Who's here, in place of SonoBus's guest invitation while the studio's own live audio runs: the guest invitation (lib/tools.lua) without a
-- Tailscale key, after "Connect without Tailscale" is on (asked once, owner and admins).
function livex.guest_button(ctx, ImGui, cfg, my_id)
  ImGui.BeginDisabled(ctx, not my_id)
  if ImGui.SmallButton(ctx, "Invite a guest without Tailscale") then
    local groups, nat = require("groups"), require("nat")
    local may = groups.may_manage(cfg.root, cfg.user)
    local ok, why = livex.guest_ready(nat.enabled(cfg.root), nat.available(), may)
    if not ok and why == "off" then
      if reaper.MB("A guest without Tailscale needs the studio's \"Connect without Tailscale\" (Settings > Studio). Turn it on for the studio now?\n\n" ..
          "Live audio, changes and chat then reach bandmates who aren't on the studio's Tailscale through StudioSync's own sealed connection.",
          "StudioSync: guest without Tailscale", 4) == 6 then
        groups.set_nat(cfg.root, true)
        band.log("connect without Tailscale is on for the studio: a guest without Tailscale can hear and be heard")
        ok = true
      end
    elseif not ok then band.msg("A guest without Tailscale can't be reached yet: " .. why .. ".") end
    if ok then require("tools").open_guest_invite(ctx, ImGui, cfg.root, true) end
  end
  ImGui.EndDisabled(ctx)
  ImGui.SetItemTooltip(ctx, my_id and livex.GUEST_TIP or "Waiting for Syncthing (it has to be running).")
end

-- ---- The live mix's host while shared CPU runs ------------------------------------------------------------------------------------------
-- This computer's network: from the background probe's output (Windows: the default route's adapter type; macOS: its hardware port; Linux:
-- whether its interface is wireless). -> "wired", "wifi", or nil (not known). Pure.
function livex.net_parse(out)
  out = tostring(out or "")
  if out:find("802%.11") or out:find("Wi%-Fi") or out:find("AirPort") or out:find("linux wifi", 1, true) or out:find("Wireless") then return "wifi" end
  if out:find("802%.3") or out:find("Hardware Port:", 1, true) or out:find("linux wired", 1, true) then return "wired" end
  return nil
end
-- The adapter of the route this computer's traffic takes now (rt-hubsmall: with Ethernet and Wi-Fi both up, the first default route listed,
-- or Windows' lowest RouteMetric alone (both 0 on the desktop: it's the interface metric, 25 against 30, that sends traffic over Ethernet),
-- could name the one not in use). The system's own route choice for a public address (nothing is sent):
--  - Windows: Find-NetRoute (the route and interface metrics together, as Windows picks), then that adapter's PhysicalMediaType; through a
--    VPN or a Tailscale exit node (no physical medium), the physical adapter with the lowest route + interface metric;
--  - macOS: `route -n get default` (the primary service's interface), then its hardware port; through a VPN's utun, the first interface in
--    `scutil --nwi`'s order that is a hardware port;
--  - Linux: `ip route get` (the kernel's choice, metrics and policy rules included), then whether that interface is wireless; through
--    Tailscale, WireGuard or a tunnel, the default route with the lowest metric that isn't one.
-- Anything else: not known (nil), ranked as not wired, Health says "network not known". Built-in tools only.
livex.NET_WIN = 'powershell -NoProfile -Command "$i=(Find-NetRoute -RemoteIPAddress 1.1.1.1 -ErrorAction SilentlyContinue | Select-Object -First 1).InterfaceIndex; ' ..
  '$a=$null; if ($i) { $a=Get-NetAdapter -InterfaceIndex $i -ErrorAction SilentlyContinue }; if (-not $a -or $a.PhysicalMediaType -eq \'Unspecified\') { ' ..
  '$a=Get-NetRoute -DestinationPrefix 0.0.0.0/0 -ErrorAction SilentlyContinue | ForEach-Object { $p=Get-NetAdapter -InterfaceIndex $_.ifIndex -Physical -ErrorAction SilentlyContinue; ' ..
  'if ($p) { [pscustomobject]@{ a=$p; m=$_.RouteMetric+(Get-NetIPInterface -InterfaceIndex $_.ifIndex -AddressFamily IPv4).InterfaceMetric } } } | ' ..
  'Sort-Object m | Select-Object -First 1 | ForEach-Object { $_.a } }; if ($a) { $a.PhysicalMediaType }"'
livex.NET_UNIX = [[if [ "$(uname)" = Darwin ]; then ports=$(networksetup -listallhardwareports 2>/dev/null); port() { printf '%s\n' "$ports" | awk -v d="$1" '/Hardware Port:/{p=$0} /Device:/{if ($2==d) print p}'; }; ]] ..
  [[p=$(port "$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"); if [ -z "$p" ]; then for d in $(scutil --nwi 2>/dev/null | awk '/Network interfaces:/{for(i=3;i<=NF;i++) print $i}'); do p=$(port "$d"); [ -n "$p" ] && break; done; fi; echo "$p"; ]] ..
  [[else d=$(ip -o route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}'); ]] ..
  [[case "$d" in ""|tailscale*|wg*|tun*) d=$(ip route show default 2>/dev/null | awk '{m=0; v=""; for(i=1;i<NF;i++){if($i=="dev")v=$(i+1); if($i=="metric")m=$(i+1)} if(v!~/^(tailscale|wg|tun)/) print m, v}' | sort -n | awk 'NR==1{print $2}');; esac; ]] ..
  [[if [ -n "$d" ]; then if [ -d "/sys/class/net/$d/wireless" ] || [ -e "/sys/class/net/$d/phy80211" ]; then echo "linux wifi"; else echo "linux wired"; fi; fi; fi]]
function livex.net_now()
  local win = reaper.GetOS():find("Win") ~= nil
  return livex.net_parse(require("services").run_hidden("netkind", win and livex.NET_WIN or livex.NET_UNIX, livex.NET_EVERY))
end
-- This computer's round trip to those it hears (ms, the mean of the extension's per-stream round trips), or nil. Pure.
function livex.rtt_of(st)
  local sum, n = 0, 0
  for _, p in pairs(type(st) == "table" and type(st.peers) == "table" and st.peers or {}) do
    local r = type(p) == "table" and tonumber(p.rtt_ms)
    if r and r >= 0 then sum, n = sum + r, n + 1 end
  end
  return n > 0 and math.floor(sum / n + 0.5) or nil
end
-- The same in tens of ms, as it goes in the status (and as this computer counts itself, so every computer ranks the same numbers): `cpu` is
-- in tens too, and a status that changes is sent again, while a round trip moves by a few ms every second. Pure.
function livex.rtt_tens(st) local r = livex.rtt_of(st); return r and math.floor(r / 10 + 0.5) * 10 or nil end
-- What the status says (and this computer ranks itself by): the round trip in tens, held until it has moved RTT_STEP ms or more from what it
-- says (the pick's own band, mix_better) and at most every LRTT_FLOOR s. (rt-hubsmall: a mean of round trips crosses a tens boundary every
-- few seconds, so the status changed nearly every pass, and a computer the link didn't reach everywhere rewrote its status file every 2 s
-- for Syncthing to carry: rt-hubfix part 2.) nil while live audio measures nothing. Pure but for its memory (S.lrtt).
function livex.lrtt(st, now)
  local r = livex.rtt_tens(st)
  if not r then S.lrtt = nil; return nil end
  local h = S.lrtt
  if not h or (math.abs(r - h.v) >= livex.RTT_STEP and now - h.at >= livex.LRTT_FLOOR) then h = { v = r, at = now }; S.lrtt = h end
  return h.v
end
-- Shared CPU in use from this computer: one of this song's tracks has its effects offloaded to a bandmate (lib/hops.lua records).
function livex.scpu_here(proj)
  local ok, recs = pcall(function() return require("hops").records(proj) end)
  for _, r in pairs(ok and type(recs) == "table" and recs or {}) do if type(r) == "table" and r.offload then return true end end
  return false
end
-- What goes in this computer's status for the others' pick (Live sync's P.status): net, lrtt, scpu, lmix (it mixes the live audio now).
function livex.status_part(proj)
  local la = require("liveaudio")
  local okn, net = pcall(livex.net_now)
  return { net = okn and net or nil, lrtt = la.available() and livex.lrtt(la.status(), reaper.time_precise()) or nil, scpu = livex.scpu_here(proj) or nil,
    lmix = type(la.S.hub) == "table" and la.S.hub.serve == true or nil }
end

-- The ranking: the one the most others in the room reach, then the one that reaches the most of them (lib/hub.lua reach: a computer two
-- bandmates can't reach can't mix for them, however fast its network. rt-hubrank), then wired, then the lower round trip (in RTT_STEP ms
-- bands, so a few ms of jitter doesn't reorder), then more CPU headroom, then the song's hub, then the name.
-- c: { user, miss, blind, net, rtt, cpu, home }. Pure.
local function band_of(c) return tonumber(c.rtt) and math.floor(c.rtt / livex.RTT_STEP) or math.huge end
function livex.mix_better(a, b)
  local ma, mb = tonumber(a.miss) or 0, tonumber(b.miss) or 0
  if ma ~= mb then return ma < mb end
  ma, mb = tonumber(a.blind) or 0, tonumber(b.blind) or 0
  if ma ~= mb then return ma < mb end
  if (a.net == "wired") ~= (b.net == "wired") then return a.net == "wired" end
  if band_of(a) ~= band_of(b) then return band_of(a) < band_of(b) end
  local ca, cb = tonumber(a.cpu) or 100, tonumber(b.cpu) or 100
  if ca ~= cb then return ca < cb end
  if (a.home == true) ~= (b.home == true) then return a.home == true end
  return tostring(a.user) < tostring(b.user)
end
-- Who mixes while shared CPU runs. cands: { user, net, rtt, cpu, can (its extension mixes), guest, off (handed the hub role on), lmix (mixes
-- now), home (the song's hub), miss, blind (mix_cands) }. The one mixing now keeps it unless another is clearly better: reached by more of
-- the others, wired against its Wi-Fi, a round trip RTT_STEP ms lower, or it's busy (cpu past BUSY: shared CPU's own line) while another
-- isn't. -> user, why ("best", "kept", "busy", or "reach": it replaces the one mixing only by being reached by more), or nil. Pure.
function livex.mix_pick(cands)
  local ok, idle = {}, {}
  for _, c in ipairs(cands or {}) do
    if c.can and not c.guest and not c.off then ok[#ok + 1] = c; if not ((tonumber(c.cpu) or 0) > livex.BUSY) then idle[#idle + 1] = c end end
  end
  local pool = #idle > 0 and idle or ok
  local best, holder
  for _, c in ipairs(pool) do
    if not best or livex.mix_better(c, best) then best = c end
    if c.lmix and (not holder or livex.mix_better(c, holder)) then holder = c end
  end
  if not best then return nil end
  if holder and holder ~= best then
    local reach = (tonumber(holder.miss) or 0) > (tonumber(best.miss) or 0)
    local faster = (best.net == "wired" and holder.net ~= "wired") or (tonumber(best.rtt) and tonumber(holder.rtt) and holder.rtt - best.rtt >= livex.RTT_STEP)
    if not (reach or faster) then return holder, "kept" end
    if not faster then return best, "reach" end -- (better reached alone: mix_decide waits the song hub's REACH_SETTLE, as a link drop moves it)
  end
  return best, (#idle == 0 and "busy") or "best"
end
-- Health's words for the pick: why this computer mixes. c: the pick; me. Pure.
function livex.mix_words(c, why, me)
  if not c then return nil end
  local parts = {}
  parts[#parts + 1] = c.net == "wired" and "wired" or c.net == "wifi" and "on Wi-Fi" or "network not known"
  if tonumber(c.rtt) then parts[#parts + 1] = string.format("%d ms round trip to the others", c.rtt) end
  if tonumber(c.cpu) then parts[#parts + 1] = string.format("CPU %d%%", c.cpu) end
  if (tonumber(c.miss) or 0) > 0 then parts[#parts + 1] = string.format("%d here can't reach it directly", c.miss) end
  local whose = c.user == me and "you mix" or (tostring(c.user) .. " mixes")
  local tail = why == "kept" and "it was mixing already and nobody here is clearly better connected" or why == "busy" and
    "every computer here is busy, so the best-connected of them" or "the best-connected computer here"
  return string.format("shared CPU is on in this room, so %s the live audio: %s (%s)", whose, table.concat(parts, ", "), tail)
end

local guests_c = { at = -math.huge }
local function guests(root)
  if reaper.time_precise() - guests_c.at < livex.GUESTS_EVERY and guests_c.root == root then return guests_c.set end
  local ok, set = pcall(function() return require("removal").guest_names(root) end)
  guests_c = { at = reaper.time_precise(), root = root, set = ok and type(set) == "table" and set or guests_c.set or {} }
  return guests_c.set
end
livex.guests = guests -- (the studio's guests' names, read every GUESTS_EVERY s: lib/liveaudio.lua's vouch_merge too)
-- The candidates from the room's statuses (presence.peers: those here) and this computer as it is now; users: peer -> name of those live
-- audio reaches here (only they can be mixed for). -> list, shared CPU on anywhere in the room. Pure but for its arguments.
-- Each one's miss and blind (who reaches whom: lib/hub.lua reach) count everyone in the room by the statuses, not only those on the link
-- here, so every computer ranks the same numbers; a guest's word isn't counted, as for the song's hub. me.hub: this computer's own
-- (hub.status_part: ext, sees). rt-hubrank
function livex.mix_cands(sts, users, me, home, gs)
  local on_link, list, scpu = {}, {}, me.scpu == true
  local hubm, room, at = require("hub"), {}, {}
  local function person(st)
    if gs[st.user] then return end
    at[st.user] = { user = st.user, ext = type(st.hub) == "table" and st.hub.ext or nil, songs = { here = { sees = hubm.seen(st) } } }
    room[#room + 1] = at[st.user]
  end
  for _, st in ipairs(sts or {}) do if type(st) == "table" and type(st.user) == "string" then person(st) end end
  person(me)
  hubm.reach(room, "here")
  for _, name in pairs(users or {}) do on_link[name] = true end
  for _, st in ipairs(sts or {}) do
    if type(st) == "table" and type(st.user) == "string" and on_link[st.user] then
      local h = type(st.hub) == "table" and st.hub or {}
      -- (can: its extension mixes, and is new enough for the hub's jobs: lib/hub.lua EXT, as the song's hub election. rt-hubfix)
      list[#list + 1] = { user = st.user, net = st.net, rtt = tonumber(st.lrtt), cpu = tonumber(st.cpu), can = st.lhub == true and require("hub").fits(h.ext), guest = gs[st.user] == true,
        off = h.off == true, lmix = st.lmix == true, home = st.user == home }
      scpu = scpu or st.scpu == true
    end
  end
  list[#list + 1] = { user = me.user, net = me.net, rtt = me.rtt, cpu = me.cpu, can = me.can, guest = gs[me.user] == true, off = me.off, lmix = me.lmix, home = me.user == home }
  for _, c in ipairs(list) do if at[c.user] then c.miss, c.blind = at[c.user].miss, at[c.user].blind end end
  return list, scpu
end
-- liveaudio.hub_tick: who mixes. hub: the song's hub (lib/hub.lua's view). -> the host to use (nil: nobody yet: everyone's own streams), Health's
-- words, and why it waits (a handover: the new host's status doesn't say it mixes yet, so listeners stay on their own streams meanwhile rather
-- than ask a computer that isn't mixing and wait out the 5 s join fallback).
function livex.mix_host(cfg, b, hub, users, st, laS)
  local okp, sts = pcall(require("presence").peers, cfg, b.song, b.room or "main")
  sts = okp and type(sts) == "table" and sts or {}
  local okc, cpu = pcall(function() return require("hops").cpu_now() end)
  local okn, net = pcall(livex.net_now)
  local me = { user = cfg.user, net = okn and net or nil, rtt = livex.lrtt(st, reaper.time_precise()), cpu = okc and cpu or nil, can = require("liveaudio").hub_fit(),
    off = require("hub").off(cfg.root), lmix = type(laS.hub) == "table" and laS.hub.serve == true, scpu = livex.scpu_here(reaper.EnumProjects(-1)),
    hub = require("hub").status_part(cfg, b) } -- (its ext and sees, as its status says them: who reaches whom, mix_cands)
  local list, scpu = livex.mix_cands(sts, users, me, hub, guests(cfg.root))
  S.mix = S.mix or {}
  return livex.mix_decide(S.mix, list, scpu, hub, cfg.user, reaper.time_precise())
end
-- The pick held steady: a new host is taken once it has been the pick for SETTLE s (statuses arrive at different moments on each computer),
-- at once when the one before can't mix any more. mem: kept between calls. -> host, words, wait. Pure.
function livex.mix_decide(mem, list, scpu, hub, me, now)
  if not scpu then mem.cur, mem.cand, mem.since = nil, nil, nil; return hub, nil, nil end
  local c, why = livex.mix_pick(list)
  if not c then return nil, nil, "shared CPU is on, but no computer here can mix the live audio" end
  if mem.cur == c.user then mem.cand, mem.since = nil, nil
  else
    local cur_ok = false
    for _, x in ipairs(list) do if x.user == mem.cur and x.can and not x.guest and not x.off then cur_ok = true end end
    if mem.cand ~= c.user then mem.cand, mem.since = c.user, now end
    -- (rt-hubsmall: a move only because more of the others reach it waits as long as the song's hub does for the same reason, hub.REACH_SETTLE:
    -- a link that drops for a moment takes a name out of `sees` for LINK_GONE s and moved the mix after 4. Wired, round trip and busy come
    -- from status values that change seldom (lrtt is held), so SETTLE only covers statuses arriving at different moments.)
    if cur_ok and now - mem.since < (why == "reach" and require("hub").REACH_SETTLE or livex.SETTLE) then c = nil end
    if c then mem.cur, mem.cand, mem.since = c.user, nil, nil end
  end
  local host
  for _, x in ipairs(list) do if x.user == mem.cur then host = x end end
  if not host then return nil, nil, "shared CPU is on: choosing the best-connected computer to mix" end
  local words = livex.mix_words(host, mem.cur == (c and c.user) and why or "kept", me)
  if host.user ~= me and not host.lmix then
    return nil, words, "handing the live mix to " .. host.user .. " (the best-connected computer while shared CPU is on): your own streams until it mixes"
  end
  return host.user, words, nil
end

return livex
