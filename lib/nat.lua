-- The connection without Tailscale, stage 1 (docs/realtime-roadmap.md "Without Tailscale: design"): live audio reaches the bandmates the
-- studio's tailnet doesn't, through the extension's own NAT traversal (extension/nat.cpp: ICE with libjuice, signed rendezvous files in the
-- shared folder, every datagram sealed). This file decides when and to whom:
--  - the studio's setting (band.json "nat", owner and admins: off unless true) and its STUN list ("nat_stun", else a public one);
--  - this computer's static key: the private half in ~/.studiosync/nat-key (as the update key, never in a synced folder), the public half
--    in its devices file with whether it's on the studio's tailnet now (lib/removal.lua publish: nat = { pub, tailnet });
--  - which pairs need it, from what both sides read the same: both devices files (pair_needs). Tailscale stays the way for everyone it
--    reaches; a pair goes this way only when one of the two isn't on the studio's tailnet;
--  - the setup handed to the extension (StudioSync_NatSetup) for the bandmates in the room now whose own computer wrote their file, and
--    the "nat:<device>" peers live audio adds for them (lib/liveaudio.lua tick);
--  - Health: a row per such bandmate (direct through both NATs, relayed, connecting, why not), a strict-NAT or blocked-UDP warning, and on
--    Windows the firewall rule for UDP 47282-47297 (asked through Windows' own UAC prompt, only when someone presses the button).
-- Stage 3 (docs/rt/rt-nat3.md): the studio hub (lib/hub.lua's choice) runs a relay (STUN/TURN on UDP 47298, relayed addresses on
-- 47299-47314; passwords from the studio secret) for pairs whose NATs can't meet, and puts its address in its devices file; the others use
-- it from there. Its router has to forward those ports: Health says so, nothing here touches a router or firewall.
-- shortcut: the handshake under it is unreviewed (James deferred security reviews until every feature is in, 2026-11-19); review it before
-- the setting is on by default. (James, rt)
local band = require("band")
local nat = { PORT = 47282, PORTS = 16, RELAY_PORT = 47298, RELAY_PORTS = 16, EVERY = 2, DEVICES_EVERY = 30, RULE = "StudioSync connection without Tailscale",
  STUN = { "stun.cloudflare.com:3478", "stun.l.google.com:19302" } }
local S = { json = nil, at = -math.huge, peers = {}, users = {}, devs = {}, set = false } -- (the setup last handed over, and what it gave)
nat.S = S

function nat.available() return reaper.StudioSync_NatSetup ~= nil and reaper.StudioSync_NatKey ~= nil and reaper.StudioSync_NatStatus ~= nil end
function nat.enabled(root)
  if not root then return false end
  local ok, t = pcall(function() return require("groups").trusted(root) end)
  return ok and type(t) == "table" and t.nat == true
end
-- "host:port host:port" -> { "host:port", ... }; nothing usable: the public list. Pure.
function nat.stun_list(s)
  local out = {}
  for w in tostring(s or ""):gmatch("%S+") do if w:match("^[%w%.%-]+:%d+$") then out[#out + 1] = w end end
  return #out > 0 and out or nat.STUN
end
function nat.stun(root)
  local ok, t = pcall(function() return require("groups").trusted(root) end)
  return nat.stun_list(ok and type(t) == "table" and t.nat_stun or nil)
end
-- This computer's key file: $STUDIOSYNC_NAT_KEY, else ~/.studiosync/nat-key (beside the update key, outside every synced folder).
function nat.key_path()
  local p = os.getenv("STUDIOSYNC_NAT_KEY")
  if p and p ~= "" then return band.norm(p) end
  local home = os.getenv("USERPROFILE") or os.getenv("HOME")
  return home and home ~= "" and (band.norm(home) .. "/.studiosync/nat-key") or nil
end
local pub_cache
function nat.public_key()
  if pub_cache then return pub_cache end
  local path = nat.available() and nat.key_path()
  local pub = path and reaper.StudioSync_NatKey(path) or ""
  if pub:match("^%x+$") and #pub == 64 then pub_cache = pub end
  return pub_cache
end
-- What this computer puts in its devices file for a studio (lib/removal.lua publish): nil while the studio has it off. Pure but for the key.
function nat.entry(root, on_tailnet)
  if not nat.enabled(root) then return nil end
  local pub = nat.public_key()
  if not pub then return nil end
  local e = { pub = pub, tailnet = on_tailnet and true or false }
  -- (stage 3: the studio hub's relay, at the public address its STUN probe found: what the others use)
  local ip = S.relay_on and S.root == root and tostring(nat.status().public or ""):match("^(%d+%.%d+%.%d+%.%d+):%d+$")
  if ip then e.relay = ip .. ":" .. nat.RELAY_PORT end
  return e
end
local function pub_ok(d) return type(d) == "table" and type(d.nat) == "table" and type(d.nat.pub) == "string" and #d.nat.pub == 64 and d.nat.pub:match("^%x+$") ~= nil end
local function named(d, suffix) return suffix and type(d.ts) == "table" and type(d.ts[suffix]) == "string" end
-- Does the pair (two devices files) go this way? Both have a key, and one of them isn't reachable on the studio's tailnet: the studio has
-- none (suffix nil), one has no name on it, or one says it's off it now. Both computers read the same two files, so they agree. Pure.
function nat.pair_needs(mine, theirs, suffix)
  if not (pub_ok(mine) and pub_ok(theirs)) then return false end
  return not (named(mine, suffix) and named(theirs, suffix) and mine.nat.tailnet ~= false and theirs.nat.tailnet ~= false)
end
-- The extension's setup (extra: stage 3's relay = { port, users } and turn = "ip:port"). Pure.
function nat.setup_json(folder, me, secret, key, port, stun, peers, extra)
  local list = {}
  for _, p in ipairs(peers or {}) do list[#list + 1] = { device = p.device, pub = p.pub } end
  local t = { folder = folder, me = me, secret = secret, key = key, port = port, stun = stun, peers = list }
  for k, v in pairs(extra or {}) do t[k] = v end
  return band.json_encode(t)
end
-- Stage 3: who relays. The studio hub (the same choice on every computer: lib/hub.lua) runs it; the others use the address in the hub's
-- devices file, only one its own computer wrote (ok_dev). -> this computer runs it, then the relay's "ip:port" and whose it is. Pure.
function nat.relay_plan(me_user, hub_user, list, ok_dev)
  if not hub_user then return false end
  if hub_user == me_user then return true end
  for _, d in ipairs(list or {}) do
    if d.user == hub_user and pub_ok(d) and type(d.nat.relay) == "string" and d.nat.relay:match("^%d+%.%d+%.%d+%.%d+:%d+$") and ok_dev(d) then
      return false, d.nat.relay, d.user
    end
  end
  return false
end
-- Live audio's peer list with these bandmates' Tailscale entries (dev_of: peer -> device) swapped for "nat:<device>". Pure.
function nat.merge(list, dev_of, users, nlist, nusers, ndevs)
  local out, u = {}, {}
  for _, p in ipairs(list or {}) do
    local d = (dev_of or {})[p]
    if not (d and ndevs[d]) then out[#out + 1] = p; u[p] = (users or {})[p] end
  end
  for _, p in ipairs(nlist or {}) do out[#out + 1] = p; u[p] = (nusers or {})[p] end
  return out, u
end

-- Stage 2: the direct link's peers (lib/direct.lua refresh_peers). Its Tailscale list with each bandmate whose link without Tailscale is up
-- now (st: StudioSync_NatStatus's) swapped for "nat:<device>"; one whose link isn't up keeps its Tailscale entry, if it has one: today's
-- path (Tailscale where it reaches, else Syncthing). -> the list (sorted), peer -> device id, peer -> user. Pure.
function nat.direct_merge(list, dev_of, users, nlist, nusers, st)
  local up = {}
  for dev, p in pairs(type(st) == "table" and type(st.peers) == "table" and st.peers or {}) do
    if type(p) == "table" and p.state == "up" then up[dev] = true end
  end
  local ul, uu, ud = {}, {}, {}
  for _, p in ipairs(nlist or {}) do
    local d = tostring(p):sub(5)
    if up[d] then ul[#ul + 1] = p; uu[p] = (nusers or {})[p]; ud[d] = true end
  end
  local out, u = nat.merge(list, dev_of, users, ul, uu, ud)
  local dv = {}
  for k, v in pairs(dev_of or {}) do dv[k] = v end
  for _, p in ipairs(ul) do dv[p] = p:sub(5) end
  table.sort(out)
  return out, dv, u
end

-- The studio's devices files (each person's, written by their own computer: trust.user_file names it), every DEVICES_EVERY s.
local dev_cache = {}
local function devices(root)
  local c = dev_cache[root]
  if c and reaper.time_precise() - c.at < nat.DEVICES_EVERY then return c.list end
  local trust, services, list = require("trust"), require("services"), {}
  for _, f in ipairs(band.files(root .. "/_band/devices", ".json")) do
    local d = band.read_json(root .. "/_band/devices/" .. f)
    if type(d) == "table" and type(d.user) == "string" and services.is_device_id(d.device) and trust.user_file(d.user) == f then list[#list + 1] = d end
  end
  dev_cache[root] = { at = reaper.time_precise(), list = list }
  return list
end
nat.devices = devices
local asked = {} -- root\0user\0device -> true once trust.device_ok answered (it can ask Syncthing: only while this pass is quick)

local function stop()
  if S.set and reaper.StudioSync_NatStop then reaper.StudioSync_NatStop() end
  S.set, S.json, S.peers, S.users, S.devs = false, nil, {}, {}, {}
  S.relay_on, S.turn, S.relay_name = false, nil, nil
end
-- Live sync's tick (through lib/liveaudio.lua, and stage 2 lib/direct.lua's refresh_peers with by "direct"): the extension set up for the
-- bandmates in the room who need this way. -> the "nat:<device>" peers, peer -> user, and the set of their devices (for nat.merge). Nothing
-- while the studio has it off. (stage 2: live audio off asks it to stop, cfg nil, every tick; while the direct link has asked in the last
-- few seconds, that's ignored: the links carry its changes, chat and clock too. James, rt)
nat.HOLD = 6
nat.ME = tostring(math.random(1, 1 << 30)) .. tostring(S):sub(-6) -- (this script's own, for the claim)
-- May this script set up the computer's hub now? ExtState "nat setup by" = "<script>\t<time>". strong: yes regardless. Takes it when yes.
function nat.claim(now, strong)
  local who, at = reaper.GetExtState(band.SECTION, "nat setup by"):match("^(.-)\t(.+)$")
  at = tonumber(at)
  if not (strong or not who or who == nat.ME or not at or now - at > nat.HOLD) then return false end
  reaper.SetExtState(band.SECTION, "nat setup by", nat.ME .. "\t" .. now, false)
  return true
end
function nat.peers(cfg, b, by)
  local root = cfg and cfg.root
  local now = reaper.time_precise()
  if by == "direct" then S.direct_at = now
  elseif not root and now - (S.direct_at or -math.huge) < nat.HOLD then return S.peers, S.users, S.devs end
  if not (root and nat.available() and nat.enabled(root)) then stop(); return {}, {}, {} end
  if now - S.at < nat.EVERY then return S.peers, S.users, S.devs end
  S.at = now
  local services, groups, trust, access = require("services"), require("groups"), require("trust"), require("access")
  local me, secret, key = services.my_device_id(), groups.sonobus_secret(root), nat.key_path()
  if not (me and secret and key) then stop(); return {}, {}, {} end
  local t = groups.tailnet(root)
  local suffix = t and t.suffix or nil
  local list = devices(root)
  local mine
  for _, d in ipairs(list) do if d.device == me then mine = d end end
  local present = {}
  if b and b.song then
    for _, st in ipairs(require("presence").peers(cfg, b.song, b.room or "main")) do present[st.user] = true end
  end
  local want, peers, users, devs = {}, {}, {}, {}
  local function dev_ok(d) -- (its own computer wrote it: trust.device_ok, which may ask Syncthing, so only while this pass is quick)
    local k = root .. "\0" .. d.user .. "\0" .. d.device
    local okd, said = true, nil
    if asked[k] or reaper.time_precise() - now < 0.05 then okd, said = pcall(trust.device_ok, root, d.user, d.device) end
    if okd and said ~= nil then asked[k] = true end
    return okd and said == true
  end
  -- (stage 3: the studio hub relays; the others use its relay)
  local okh, hv = pcall(function() return b and b.song and require("hub").view(cfg, b.song) end)
  local relay_on, turn, relay_name = nat.relay_plan(cfg.user, okh and type(hv) == "table" and hv.studio or nil, list, dev_ok)
  S.root, S.relay_on, S.turn, S.relay_name = root, relay_on, turn, relay_name or (relay_on and cfg.user) or nil
  local relay_users = {}
  if relay_on then for _, d in ipairs(list) do if pub_ok(d) then relay_users[#relay_users + 1] = d.device end end; table.sort(relay_users) end
  for _, d in ipairs(list) do
    if d.device ~= me and present[d.user] and mine and nat.pair_needs(mine, d, suffix) then
      if dev_ok(d) and access.shows(access.read(root, d.device), b.song) then
        want[#want + 1] = { device = d.device, pub = d.nat.pub }
        local p = "nat:" .. d.device
        peers[#peers + 1] = p; users[p] = d.user; devs[d.device] = true
      end
    end
  end
  table.sort(want, function(x, y) return x.device < y.device end)
  table.sort(peers)
  local json = nat.setup_json(root .. "/_band/nat", me, secret, key, nat.PORT, nat.stun(root), want,
    { relay = relay_on and { port = nat.RELAY_PORT, users = relay_users } or nil, turn = turn })
  -- (one hub per computer: another Live sync tab, in another song, that set it up in the last few seconds keeps it, unless this call is live
  -- audio's (the song in front: stage 1's rule). A tab that doesn't hold it sets nothing up and stops nothing. rt-nat2)
  if not nat.claim(now, by ~= "direct") then
    S.set, S.json, S.peers, S.users, S.devs = false, nil, {}, {}, {}
    return {}, {}, {}
  end
  if #want == 0 and not relay_on then
    stop()
  elseif json ~= S.json then
    local n = reaper.StudioSync_NatSetup(json)
    if n < 0 then band.log("connection without Tailscale: " .. tostring(nat.status().error or "?")) end
    S.json, S.set = json, n >= 0
  end
  S.peers, S.users, S.devs = peers, users, devs
  return peers, users, devs
end
function nat.status()
  local ok, t = pcall(band.json_decode, nat.available() and reaper.StudioSync_NatStatus() or "")
  return ok and type(t) == "table" and t or {}
end
-- This computer isn't on the studio's tailnet now (live audio then needs neither Tailscale nor its firewall rule to start).
function nat.off_tailnet(root)
  if not nat.enabled(root) then return false end
  local t = require("groups").tailnet(root)
  local ok, _, suffix = pcall(require("services").tailnet_now)
  return not (t and ok and suffix == t.suffix)
end

-- ---- the Windows firewall rule: reaper.exe, UDP 47282-47297, from anywhere (the hole punch's first packets can arrive before ours) ------
local function exe_path() return ((reaper.GetExePath() .. "/reaper.exe"):gsub("/", "\\")) end
-- (relay: the studio hub's rule covers its relay's ports too, 47282-47314; a wider rule does for a computer that isn't the hub now)
function nat.ports(relay) return string.format("%d-%d", nat.PORT, relay and (nat.RELAY_PORT + nat.RELAY_PORTS) or (nat.PORT + nat.PORTS - 1)) end
function nat.firewall_command(exe, relay) -- Pure.
  return string.format('advfirewall firewall add rule name="%s" dir=in action=allow program="%s" protocol=UDP localport=%s profile=any enable=yes',
    nat.RULE, exe, nat.ports(relay))
end
function nat.firewall_in(out, exe, relay) -- From `netsh advfirewall firewall show rule name=... verbose`. Pure.
  out = tostring(out or ""):lower()
  return out:find(nat.RULE:lower(), 1, true) ~= nil and out:find(tostring(exe):lower(), 1, true) ~= nil and
    (out:find(nat.ports(true), 1, true) ~= nil or (not relay and out:find(nat.ports(), 1, true) ~= nil))
end
local fw_fast_until = -math.huge
function nat.firewall_ok(relay)
  if not band.WIN then return true end
  local every = reaper.time_precise() < fw_fast_until and 5 or 60
  return nat.firewall_in(require("services").run_hidden("nat-fw", 'netsh advfirewall firewall show rule name="' .. nat.RULE .. '" verbose', every), exe_path(), relay)
end
-- Only from Health's button: Windows asks (UAC) before anything is added. -> true, or nil and why.
function nat.setup_firewall(relay)
  if not band.WIN then
    return nil, band.MAC and "On a Mac, allow REAPER when macOS asks about incoming connections (only with its firewall on)."
      or "On Linux nothing is usually needed; with ufw or firewalld on, allow UDP " .. nat.ports(relay) .. "."
  end
  local exe = exe_path()
  if exe:find('["%c]') then return nil, "REAPER's folder has a character the firewall rule can't hold" end
  local services = require("services")
  local args = string.format('/c netsh advfirewall firewall delete rule name="%s" >nul & netsh %s', nat.RULE, nat.firewall_command(exe, relay))
  local ps1 = services.TMP .. "/bandsync-nat-fw.ps1"
  band.write_atomic(ps1, "Start-Process -FilePath cmd.exe -Verb RunAs -WindowStyle Hidden -Wait -ArgumentList '" .. args:gsub("'", "''") .. "'\r\n")
  services.run_hidden("nat-fw-setup", 'powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' .. ps1:gsub("/", "\\") .. '"', 0)
  fw_fast_until = reaper.time_precise() + 120
  return true
end

-- ---- Health -----------------------------------------------------------------------------------------------------------------------------
-- One bandmate's line from the extension's status: ok, text. Pure.
-- (stage 3: "relayed by <hub>", "direct (through both NATs)", "no path": the last try met but found no way through both NATs)
function nat.peer_text(p, name, relay_name)
  name = tostring(name or "?")
  if type(p) ~= "table" then return false, name .. ": not set up yet" end
  if p.state == "up" then
    return true, name .. ": " .. (p.path == "relayed" and ("relayed by " .. tostring(relay_name or "the studio hub")) or "direct (through both NATs)") ..
      string.format(", up %ds", math.floor(tonumber(p.up_s) or 0))
  end
  local why = p.why and p.why ~= "" and (" (" .. p.why .. ")") or ""
  if p.nopath == true then
    return false, name .. ": no path" .. (relay_name and (" (not even through " .. tostring(relay_name) .. "'s relay)") or
      " (both networks' NATs are strict and the studio hub runs no relay that answers)") .. "; trying again shortly"
  end
  if p.state == "connecting" then return false, name .. ": connecting" .. why end
  if p.state == "waiting for them" then return false, name .. ": waiting for their computer to offer" .. why end
  return false, name .. ": trying again shortly" .. why
end
-- Health's rows: { id, ok, colour, text when ok, text when not, action }. Pure over the status, names (device -> user), the firewall's
-- state and (stage 3) the relay: relay_name, whose relay this computer uses (or runs).
function nat.relay_ports() return string.format("UDP %d-%d", nat.RELAY_PORT, nat.RELAY_PORT + nat.RELAY_PORTS) end
function nat.rows_from(st, names, win, fw_ok, relay_name)
  local rows, each, all = {}, {}, true
  local devs = {}
  local relay = type(st.relay) == "table" and st.relay or {}
  for dev in pairs(type(st.peers) == "table" and st.peers or {}) do devs[#devs + 1] = dev end
  table.sort(devs)
  for _, dev in ipairs(devs) do
    local ok, text = nat.peer_text(st.peers[dev], (names or {})[dev] or tostring(dev):sub(1, 7), relay_name)
    all = all and ok
    each[#each + 1] = text
  end
  if #devs > 0 then
    local text = "Without Tailscale: " .. table.concat(each, "; ")
    rows[#rows + 1] = { "nat peers", all, "yellow", text, text }
  end
  if st.error and st.error ~= "" then rows[#rows + 1] = { "nat error", false, "yellow", "", "Without Tailscale: " .. st.error } end
  if relay.on == true then -- (this computer is the studio hub: it relays)
    local ok = relay.running == true and (relay.error or "") == ""
    local text = "Without Tailscale: this computer is the studio's relay (STUN/TURN for bandmates whose networks can't meet, " .. nat.relay_ports() ..
      (ok and string.format("; %.1f MB relayed, %d datagrams over its caps dropped", (tonumber(relay.bytes) or 0) / 1048576, math.floor(tonumber(relay.over_cap) or 0)) or
        (": " .. tostring(relay.error ~= "" and relay.error or "starting"))) ..
      "). Bandmates outside this network reach it only if this network's router forwards " .. nat.relay_ports() .. " to this computer: set that up in the router (StudioSync never changes a router or firewall)."
    rows[#rows + 1] = { "nat relay", ok, "yellow", text, text }
  elseif st.turn and st.turn ~= "" and st.relay_ok ~= true then
    rows[#rows + 1] = { "nat relay", false, "yellow", "", "Without Tailscale: the studio hub's relay (" .. tostring(relay_name or "the hub") .. ", " .. tostring(st.turn) ..
      ") doesn't answer: its router may not forward " .. nat.relay_ports() .. " to it yet, so a bandmate behind another strict NAT can't be reached" }
  end
  if st.nat == "strict" then
    local via = st.relay_ok == true and (" (" .. tostring(relay_name or "the studio hub") .. "'s relay answers, so that works)")
      or relay.on == true and " (this computer's own relay carries it)"
      or " (none answers yet: the studio hub runs one once its router forwards " .. nat.relay_ports() .. " to it)"
    rows[#rows + 1] = { "nat strict", false, "yellow", "", "Without Tailscale: this network maps each destination to a new port (a strict NAT), so this computer needs a relay: " ..
      "bandmates on ordinary home networks are reached directly, another strict one only through the studio hub's relay" .. via }
  elseif st.nat == "blocked" then
    rows[#rows + 1] = { "nat strict", false, "yellow", "", "Without Tailscale: no answer from the STUN servers, so UDP may be blocked on this network" }
  end
  if win and not fw_ok and (#devs > 0 or relay.on == true) then
    rows[#rows + 1] = { "nat firewall", false, "yellow", "", "Without Tailscale: Windows may drop a bandmate's first packets until REAPER has its firewall rule (UDP " .. nat.ports(relay.on == true) .. ")." }
  end
  return rows
end
function nat.health_rows(cfg)
  if not (cfg and nat.enabled(cfg.root)) then return {} end
  if not nat.available() then return { { "nat", false, "yellow", "", "The connection without Tailscale is on for the studio, but this extension doesn't have it (update StudioSync's extension)." } } end
  local names = {}
  for p, u in pairs(S.users) do names[p:sub(5)] = u end
  local relay = S.relay_on == true
  local rows = nat.rows_from(nat.status(), names, band.WIN, nat.firewall_ok(relay), S.relay_name)
  for _, r in ipairs(rows) do
    if r[1] == "nat firewall" then
      r.action = { "Set up connection without Tailscale", function()
        local done, why = nat.setup_firewall(relay)
        band.log(done and "connection without Tailscale: Windows asks once (UAC) to let bandmates' packets in; Health turns green within a minute" or ("connection without Tailscale: " .. tostring(why)))
      end, "Adds a Windows Firewall rule for reaper.exe, UDP " .. nat.ports(relay) .. ", from any address (every packet is sealed: anything that doesn't open is dropped). Windows asks once." }
    end
  end
  return rows
end

-- Settings > Studio: the switch (owner and admins).
function nat.studio_ui(ctx, ImGui, cfg, may)
  local on = nat.enabled(cfg.root)
  ImGui.TextDisabled(ctx, on and "Connect without Tailscale: on. Live audio, changes, chat, claims and the shared clock reach bandmates who aren't on the studio's Tailscale through StudioSync's own connection (Tailscale stays the way for everyone it reaches)."
    or "Connect without Tailscale: off. The direct link and live audio reach bandmates on the studio's Tailscale only.")
  if may then
    local ch, v = ImGui.Checkbox(ctx, "Connect without Tailscale##studionat", on)
    if ch then
      require("groups").set_nat(cfg.root, v)
      band.log(v and "connect without Tailscale is on for the studio: changes, chat, the clock and live audio reach bandmates without Tailscale too" or "connect without Tailscale is off for the studio")
    end
    ImGui.SetItemTooltip(ctx, "Owner and admins. For bandmates who won't install Tailscale: their computer and the others find a path through both home networks (a public STUN server tells each its own address; nothing of the music goes through it). Where two strict networks can't meet, the studio hub relays (everything still sealed end to end), once its router forwards " .. nat.relay_ports() .. " to it. Needs StudioSync's extension with it on each computer.")
  end
end

return nat
