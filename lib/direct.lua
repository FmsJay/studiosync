-- The direct link (docs/direct-link-design.md, James, 0.59.50): each new event file goes straight to the others in the studio over
-- Tailscale too, so it lands in well under a second (through Syncthing alone, 2.6-3.3 s a change). Syncthing still carries every file and
-- its copy is the record; the direct copy only gets there first, into an inbox outside the shared folder (<home>/direct/<studio id>/...),
-- which Syncthing never sees. The sockets are the extension's (extension/direct.cpp, 1.0.7: reaper.StudioSync_Direct*). Missing or older
-- extension, Tailscale off, no studio network or secret, the setting off, a computer that can't be reached: Syncthing alone. (The extension is
-- mandatory: a missing or older one is a red Health row, direct.health_rows. James, 0.60.0-rt)
local band = require("band")
local direct = { PORT = 47281, KEEP_SECS = 86400, RULE = "StudioSync direct link", START_EVERY = 10, PRUNE_EVERY = 10 }

-- ---- pure ----------------------------------------------------------------------------------------------------------------------------
-- A plain folder name, as the extension's rule (direct.cpp seg_ok).
local function seg_ok(s)
  return type(s) == "string" and #s > 0 and #s <= 200 and s:sub(1, 1) ~= "." and not s:find("[%. ]$") and not s:find('[%c/\\:%*%?"<>|\127]')
end
direct.plain = seg_ok -- (a song or room name in a message, before it names a path: lib/page_chat.lua. James, 0.60.0-rt)
-- Is `rel` (relative to the studio's folder) an event file's path: <song>/rooms/<room>/events/<id>.json? Only those go, or are taken.
function direct.rel_ok(rel)
  if type(rel) ~= "string" or #rel > 512 then return false end
  local song, room, name = rel:match("^([^/]+)/rooms/([^/]+)/events/([^/]+)$")
  return song ~= nil and seg_ok(song) and seg_ok(room) and #name <= 200 and name:match("^[%w%-_]+%.json$") ~= nil
end
local function norm(p) return (tostring(p):gsub("\\", "/"):gsub("/+$", "")) end
-- A file's path in the studio (`root`) -> its relative path, when it's an event file's; else nil.
function direct.rel_of(root, path)
  local r, p = norm(root), norm(path)
  if p:sub(1, #r + 1):lower() ~= (r .. "/"):lower() then return nil end
  local rel = p:sub(#r + 2)
  return direct.rel_ok(rel) and rel or nil
end
-- The computers to send to, as "name:port", sorted. devices: { { user, device, ts = { [suffix] = name } } } (the _band/devices files);
-- suffix: the studio's Tailscale network ("tail1234.ts.net"); me: this computer's Syncthing id; present: set of users here now (nil: anyone);
-- ok(d): may this one have it (its own computer wrote its file, a guest's list has the song). Names only, never 100.x addresses.
function direct.peers_from(devices, suffix, me, port, present, ok)
  local out, seen = {}, {}
  for _, d in ipairs(devices or {}) do
    local name = type(d) == "table" and type(d.ts) == "table" and d.ts[suffix]
    if type(name) == "string" and name:match("^[%w%-%.]+$") and name:sub(-#suffix - 1) == "." .. suffix and d.device ~= me
      and (not present or present[d.user]) and (not ok or ok(d)) then
      local peer = name .. ":" .. math.floor(port)
      if not seen[peer] then seen[peer] = d.device or true; out[#out + 1] = peer end
    end
  end
  table.sort(out)
  return out, seen -- (seen: peer -> its computer's device id, for the clock's reference)
end
-- When an event was made, from its id (<user>-YYYYMMDD-HHMMSSZ-...): seconds since 1970, UTC; nil if the name isn't one.
function direct.id_time(name)
  local y, mo, d, h, mi, s = tostring(name):match("%-(%d%d%d%d)(%d%d)(%d%d)%-(%d%d)(%d%d)(%d%d)Z%-")
  if not y then return nil end
  local t = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = tonumber(h), min = tonumber(mi), sec = tonumber(s), isdst = false })
  local now = os.time()
  return t + (os.time(os.date("*t", now)) - os.time(os.date("!*t", now))) -- (os.time reads the table as local time)
end
-- The Windows firewall rule's netsh words (run elevated): reaper.exe, that port, from Tailscale's addresses only. proto: "TCP" (the link, the
-- default) or "UDP" (live audio's twin on the same port, lib/liveaudio.lua. James, rt).
function direct.firewall_command(exe, port, proto)
  return string.format('advfirewall firewall add rule name="%s" dir=in action=allow program="%s" protocol=%s localport=%d remoteip=100.64.0.0/10 profile=any enable=yes',
    direct.RULE, exe, proto or "TCP", math.floor(port))
end
-- From `netsh advfirewall firewall show rule name=... verbose`: is our rule there, for this reaper.exe and port? (The rule's name only shows
-- when it exists, whatever Windows' language.) proto ("UDP"): and one of that protocol among them (the word itself isn't translated).
function direct.firewall_in(out, exe, port, proto)
  out = tostring(out or ""):lower()
  return out:find(direct.RULE:lower(), 1, true) ~= nil and out:find(tostring(exe):lower(), 1, true) ~= nil and out:find("%f[%d]" .. math.floor(port) .. "%f[%D]") ~= nil
    and (not proto or out:find("%f[%a]" .. proto:lower() .. "%f[%A]") ~= nil)
end

-- ---- the extension -------------------------------------------------------------------------------------------------------------------
function direct.available() return reaper ~= nil and reaper.StudioSync_DirectStart ~= nil and reaper.StudioSync_DirectSend ~= nil and reaper.StudioSync_DirectStatus ~= nil end
-- The studio's setting (band.json "direct", owner and admins: lib/groups.lua's trusted settings): on unless it's false.
function direct.enabled(root)
  local ok, t = pcall(function() return require("groups").trusted(root) end)
  return not (ok and type(t) == "table" and t.direct == false)
end
-- Every computer in a studio uses the same port: 47281, or ExtState "direct port".
function direct.port()
  local p = tonumber(reaper.GetExtState(band.SECTION, "direct port"))
  return p and p >= 1024 and p <= 65535 and math.floor(p) or direct.PORT
end
function direct.inbox(root) return band.home() .. "/direct/" .. band.info(root).id end
local function exe_path() return ((reaper.GetExePath() .. "/reaper.exe"):gsub("/", "\\")) end

-- Is the Windows firewall rule there? (Not Windows: true.) Asked in the background every minute, every 5 s for two minutes after setting it up.
local fw_fast_until = -math.huge
-- proto: nil for the link's TCP rule; "UDP" for live audio's twin (lib/liveaudio.lua).
function direct.firewall_ok(proto)
  if not band.WIN then return true end
  local every = reaper.time_precise() < fw_fast_until and 5 or 60
  local out = require("services").run_hidden("direct-fw", 'netsh advfirewall firewall show rule name="' .. direct.RULE .. '" verbose', every)
  return direct.firewall_in(out, exe_path(), direct.port(), proto)
end
-- Adds the rule, through Windows' own UAC prompt (one, for removing an older rule and adding this one). -> true, or nil + why.
-- The button: Health's direct-link row, while direct.firewall_ok() is false on Windows.
function direct.setup_firewall()
  if not band.WIN then
    return nil, band.MAC and "On a Mac, allow REAPER when macOS asks about incoming connections (only with its firewall on)."
      or "On Linux nothing is usually needed; with ufw or firewalld on, allow TCP and UDP " .. direct.port() .. " from 100.64.0.0/10."
  end
  local exe = exe_path()
  if exe:find('["%c]') then return nil, "REAPER's folder has a character the firewall rule can't hold" end
  local services = require("services")
  -- (and its UDP twin on the same port, for live audio: one UAC for both, and the delete clears any older pair. James, rt)
  local args = string.format('/c netsh advfirewall firewall delete rule name="%s" >nul & netsh %s & netsh %s', direct.RULE,
    direct.firewall_command(exe, direct.port()), direct.firewall_command(exe, direct.port(), "UDP"))
  local ps1 = services.TMP .. "/bandsync-direct-fw.ps1"
  -- (PowerShell's single quotes: ' is written ''. Start-Process hands a single ArgumentList string over as it is)
  band.write_atomic(ps1, "Start-Process -FilePath cmd.exe -Verb RunAs -WindowStyle Hidden -Wait -ArgumentList '" .. args:gsub("'", "''") .. "'\r\n")
  services.run_hidden("direct-fw-setup", 'powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' .. ps1:gsub("/", "\\") .. '"', 0)
  fw_fast_until = reaper.time_precise() + 120
  return true
end

-- Started for a studio (and the secret, address and listening refreshed) at most every START_EVERY seconds. -> true when it can send.
local started = {} -- root -> { at, ok }
direct.started = started
function direct.ensure(cfg)
  local root = cfg and cfg.root
  if not root or not direct.available() then return false end
  local s, now = started[root], reaper.time_precise()
  if s and now - s.at < direct.START_EVERY then return s.ok end
  local id = band.info(root).id
  local groups = require("groups")
  local secret = direct.enabled(root) and groups.tailnet(root) and groups.sonobus_secret(root)
  if not secret then
    if s and s.ok then reaper.StudioSync_DirectStop(id) end
    started[root] = { at = now, ok = false }
    return false
  end
  -- (no firewall rule yet on Windows: send only. Listening without it brings Windows' own box up in REAPER's face)
  reaper.StudioSync_DirectStart(id, secret, direct.inbox(root), direct.firewall_ok() and direct.port() or -1)
  started[root] = { at = now, ok = true }
  return true
end

-- The computers in the studio to send `song`/`room`'s changes to now: those here (presence), from their own devices files.
local dev_cache = {} -- root -> { at, list }
local function devices(root)
  local c = dev_cache[root]
  if c and reaper.time_precise() - c.at < 30 then return c.list end
  local trust, services, list = require("trust"), require("services"), {}
  for _, f in ipairs(band.files(root .. "/_band/devices", ".json")) do
    local d = band.read_json(root .. "/_band/devices/" .. f)
    if type(d) == "table" and type(d.user) == "string" and services.is_device_id(d.device) and trust.user_file(d.user) == f then list[#list + 1] = d end
  end
  dev_cache[root] = { at = reaper.time_precise(), list = list }
  return list
end
-- (from a cache made on the Live sync tick, never at send time: a computer's first trust.device_ok asks Syncthing, a call that can block for
-- seconds, and it held up sync.post. Computers not asked before are asked only while the refresh has taken under 50 ms: the rest at the next
-- one. Other scripts (the panel's Play together, chat) read the list Live sync made last, from ExtState. James, 0.60.0-rt)
direct.PEERS_EVERY = 2
local peer_cache, asked_dev = {}, {} -- root\nsong\nroom -> { at, list, dev_of }; root\0user\0device -> true once trust.device_ok answered
local function peers_ext(cfg, song, room) return "direct peers " .. tostring(band.info(cfg.root).id) .. " " .. tostring(song) .. "/" .. tostring(room) end
function direct.refresh_peers(cfg, song, room) -- -> the list, and peer -> device id
  local key, now = cfg.root .. "\n" .. tostring(song) .. "\n" .. tostring(room), reaper.time_precise()
  local c = peer_cache[key]
  if c and now - c.at < direct.PEERS_EVERY then return c.list, c.dev_of end
  local t, list, dev_of = require("groups").tailnet(cfg.root), {}, {}
  if t then
    local present = {}
    for _, st in ipairs(require("presence").peers(cfg, song, room)) do present[st.user] = true end
    local access, trust = require("access"), require("trust")
    list, dev_of = direct.peers_from(devices(cfg.root), t.suffix, require("services").my_device_id(), direct.port(), present, function(d)
      -- (only a file its own computer wrote, as services.pin_tailnet: a rewritten one would point the studio's changes somewhere else. Asked
      -- only for those here, and Syncthing's answer is kept by lib/trust.lua; not known yet is not yet)
      local k = cfg.root .. "\0" .. tostring(d.user) .. "\0" .. tostring(d.device)
      if not asked_dev[k] and reaper.time_precise() - now > 0.05 then return false end -- (the next refresh asks it)
      local ok, said = pcall(trust.device_ok, cfg.root, d.user, d.device)
      if ok and said ~= nil then asked_dev[k] = true end
      return ok and said == true and access.shows(access.read(cfg.root, d.device), song) -- (a guest whose list leaves the song out: a narrowing only)
    end)
  end
  peer_cache[key] = { at = now, list = list, dev_of = dev_of or {} }
  reaper.SetExtState(band.SECTION, peers_ext(cfg, song, room), table.concat(list, " "), false)
  return list, dev_of or {}
end
function direct.peers(cfg, song, room) -- -> the list, and peer -> device id (this script's cache; else Live sync's list, without ids)
  local c = peer_cache[cfg.root .. "\n" .. tostring(song) .. "\n" .. tostring(room)]
  if c then return c.list, c.dev_of end
  local list = {}
  for p in reaper.GetExtState(band.SECTION, peers_ext(cfg, song, room)):gmatch("%S+") do list[#list + 1] = p end
  return list, {}
end

-- After an event file is written (sync.post): it goes to the others here now. -> true when queued. Never raises.
function direct.offer(cfg, path)
  local ok, r = pcall(function()
    if not direct.ensure(cfg) then return false end
    local rel = direct.rel_of(cfg.root, path)
    if not rel then return false end
    local song, room = rel:match("^([^/]+)/rooms/([^/]+)/")
    local peers = direct.peers(cfg, song, room)
    return #peers > 0 and reaper.StudioSync_DirectSend(band.info(cfg.root).id, rel, path, table.concat(peers, " ")) == 1
  end)
  return ok and r or false
end

-- ---- what arrived --------------------------------------------------------------------------------------------------------------------
-- The inbox folder for a room's events folder (dir: <root>/<song>/rooms/<room>/events). nil if dir isn't one.
function direct.inbox_dir(cfg, dir)
  local r, d = norm(cfg.root), norm(dir)
  if d:sub(1, #r + 1):lower() ~= (r .. "/"):lower() then return nil end
  local rel = d:sub(#r + 2)
  if not rel:match("^[^/]+/rooms/[^/]+/events$") then return nil end
  return direct.inbox(cfg.root) .. "/" .. rel
end
-- Event files received for a room's events folder (names).
function direct.inbox_files(cfg, dir)
  -- (never in receive's way: an inbox that can't be worked out is no inbox. James, 0.60.0-rt)
  local ok, idir = pcall(function() return direct.available() and direct.inbox_dir(cfg, dir) end)
  return ok and idir and band.files(idir, ".json") or {}
end
-- A listing of the events folder (`names`: band.listing's or band.raw_listing's, shared: never changed) with the names only in the inbox
-- added; and those -> their paths. With nothing in the inbox, `names` itself and nil, at no cost.
function direct.merge(cfg, dir, names)
  local extra = direct.inbox_files(cfg, dir)
  if #extra == 0 then return names, nil end
  local have, out, from = {}, {}, {}
  for i, f in ipairs(names) do have[f] = true; out[i] = f end
  local idir = direct.inbox_dir(cfg, dir)
  for _, f in ipairs(extra) do
    if not have[f] then out[#out + 1] = f; from[f] = idir .. "/" .. f end
  end
  return out, next(from) and from or nil
end
function direct.listing(cfg, dir, ext) return direct.merge(cfg, dir, band.listing(dir, ext or ".json")) end
-- One event file's path: the shared folder's when it's there, else the inbox's. `cfg` nil (mirror's plain_event has only the folder):
-- the inbox of any studio this script started the link for.
function direct.path(cfg, dir, f)
  local p = dir .. "/" .. f
  if not direct.available() or reaper.file_exists(p) then return p end
  for root in pairs(cfg and { [cfg.root] = true } or direct.started) do
    local idir = direct.inbox_dir({ root = root }, dir)
    local q = idir and idir .. "/" .. f
    if q and reaper.file_exists(q) then return q end
  end
  return p
end

-- The inbox tidied: a file whose Syncthing copy has arrived goes, and any older than KEEP_SECS (a song not downloaded here, a change
-- trimmed away). -> how many went.
function direct.prune(cfg)
  local base, n, now = direct.inbox(cfg.root), 0, os.time()
  for _, song in ipairs(band.subdirs(base)) do
    for _, room in ipairs(band.subdirs(base .. "/" .. song .. "/rooms")) do
      local rel = song .. "/rooms/" .. room .. "/events"
      for _, f in ipairs(band.files(base .. "/" .. rel)) do
        local made = direct.id_time(f)
        -- (.json only: a .part file may be one the extension is writing this moment)
        if f:match("%.json$") and (reaper.file_exists(cfg.root .. "/" .. rel .. "/" .. f) or (made and now - made > direct.KEEP_SECS)) then
          if os.remove(base .. "/" .. rel .. "/" .. f) then n = n + 1 end
        end
      end
    end
  end
  return n
end

-- Each Live sync tick: keeps the link up, tidies the inbox, and says how many files arrived since this script last asked (a pass of
-- receive then, not in up to 2 s). Every script keeps its own place in the extension's list: none takes another's.
local last_seq, pruned_at = 0, -math.huge
function direct.tick(cfg)
  if not direct.available() then return 0 end
  direct.ensure(cfg)
  local n = 0
  for _ = 1, 300 do
    local s = reaper.StudioSync_DirectPoll(last_seq)
    local seq = s ~= "" and tonumber(s:match("^(%d+)\t"))
    if not seq then break end
    last_seq, n = seq, n + 1
  end
  if reaper.time_precise() - pruned_at > direct.PRUNE_EVERY then
    pruned_at = reaper.time_precise()
    pcall(direct.prune, cfg)
  end
  return n
end

-- Which way Tailscale takes to each computer, from `tailscale status --json`: { [its name, lower case, no last dot] = { path = "direct" |
-- "relay" (a Tailscale DERP server: `region`) | "peer relay" } }. A computer Tailscale isn't talking to just now (not Active) has no CurAddr
-- whichever way it would take: left out. Pure. (James, rt: link speed per bandmate)
function direct.paths_in(json)
  local out, j = {}, band.json_decode(tostring(json or ""))
  for _, p in pairs(type(j) == "table" and type(j.Peer) == "table" and j.Peer or {}) do
    local name = type(p) == "table" and type(p.DNSName) == "string" and p.DNSName:gsub("%.$", ""):lower()
    local cur, peer_relay, relay = type(p) == "table" and p.CurAddr or "", type(p) == "table" and p.PeerRelay or "", type(p) == "table" and p.Relay or ""
    if name and name ~= "" then
      if type(cur) == "string" and cur ~= "" then out[name] = { path = "direct" }
      elseif type(peer_relay) == "string" and peer_relay ~= "" then out[name] = { path = "peer relay" }
      elseif p.Active == true and type(relay) == "string" and relay ~= "" then out[name] = { path = "relay", region = relay } end
    end
  end
  return out
end
-- The same, from a background `tailscale status --json` every 30 s ({} before the first answer, or without Tailscale).
local paths_seen = { text = nil, map = {} }
function direct.paths()
  local services = require("services")
  local exe = services.tailscale_exe and services.tailscale_exe()
  local out = exe and services.run_hidden("ts-peers", '"' .. exe .. '" status --json', 30)
  if out and out ~= paths_seen.text and out:find("}%s*$") then paths_seen.text, paths_seen.map = out, direct.paths_in(out) end -- (a half-written answer: the last whole one)
  return paths_seen.map
end
-- Whose computer a peer ("name:port") is: the person's name from the studio's devices files, else the computer's first name. Pure.
function direct.who_of(devs, peer)
  local host = tostring(peer):match("^(.-):%d+$") or tostring(peer)
  for _, d in ipairs(devs or {}) do
    for _, name in pairs(type(d) == "table" and type(d.ts) == "table" and d.ts or {}) do
      if type(name) == "string" and name:lower() == host:lower() and type(d.user) == "string" then return d.user end
    end
  end
  return host:match("^([^%.]+)") or host
end

-- For Health: { available, enabled, firewall, listening, bind, error, received, rejected, last_reject, peers = { { peer, ok, ms, error, at,
-- sent, rate (bytes/s the last streams went at; 0: none yet), rate_at, rtt_ms (the way's round trip), window, path ("direct", "relay",
-- "peer relay", or nil: not known), region (a relay's) } } }, and a line to show: ok (true, false, or nil: off, nothing to say), text.
function direct.status(cfg)
  local s = { available = direct.available(), enabled = cfg and direct.enabled(cfg.root) or false, firewall = direct.firewall_ok(), peers = {} }
  if s.available then
    local j = band.json_decode(reaper.StudioSync_DirectStatus()) or {}
    for _, k in ipairs({ "listening", "bind", "error", "received", "rejected", "last_reject" }) do s[k] = j[k] end
    local ok_paths, paths = pcall(direct.paths)
    for peer, p in pairs(type(j.peers) == "table" and j.peers or {}) do
      local way = ok_paths and paths[(tostring(peer):match("^(.-):%d+$") or ""):lower()] or {}
      s.peers[#s.peers + 1] = { peer = peer, ok = p.ok == true, ms = tonumber(p.ms), error = p.error, at = tonumber(p.at), sent = tonumber(p.sent),
        rate = tonumber(p.rate) or 0, rate_at = tonumber(p.rate_at), rtt_ms = tonumber(p.rtt_ms), window = tonumber(p.window), path = way.path, region = way.region }
    end
    table.sort(s.peers, function(a, b) return a.peer < b.peer end)
  end
  return s
end
function direct.health_line(cfg)
  local s = direct.status(cfg)
  if not s.available or not direct.live_available() then return nil, "Direct link: needs StudioSync's extension " .. direct.WANT .. " (Extensions > ReaPack > Synchronize packages, or StudioSync's installer, then restart REAPER). Changes come through Syncthing meanwhile." end
  if not s.enabled then return nil, "Direct link: turned off for this studio. Changes come through Syncthing." end
  local reached, failed, ms = {}, {}, nil
  for _, p in ipairs(s.peers) do
    local who = p.peer:match("^([^%.:]+)")
    if p.ok then reached[#reached + 1] = who; ms = ms and math.min(ms, p.ms or ms) or p.ms
    else failed[#failed + 1] = who .. " (" .. tostring(p.error) .. ")" end
  end
  local text = "Direct link: " .. (s.listening and ("listening on " .. tostring(s.bind)) or ("sending only" .. (not s.firewall and ": press Set up direct link so the others' changes reach you directly too" or (s.error and s.error ~= "" and (": " .. s.error) or ""))))
  if #reached > 0 then text = text .. "; reaches " .. table.concat(reached, ", ") .. string.format(" (%.0f ms)", ms or 0) end
  if #failed > 0 then text = text .. "; can't reach " .. table.concat(failed, ", ") .. " (Syncthing carries theirs)" end
  if (tonumber(s.rejected) or 0) > 0 then text = text .. string.format("; refused %d (last: %s)", s.rejected, tostring(s.last_reject)) end
  return s.listening and #failed == 0, text
end

-- Link speed per bandmate (extension 1.0.12), so people know before recording together what the link carries to each: "Bo: 4.1 MB/s
-- direct, 18 ms". peers: direct.status's; who(peer) -> a name. -> ok (no relayed way), text; nil when the link reaches nobody. Pure.
local function per_sec(r) return r >= 1e6 and string.format("%.1f MB/s", r / 1e6) or string.format("%.0f KB/s", r / 1e3) end
function direct.speed_line_of(peers, who)
  local each, relayed = {}, false
  for _, p in ipairs(peers or {}) do
    if p.ok then
      local way = p.path == "relay" and ("relayed by Tailscale" .. (p.region and (" (" .. p.region .. ")") or "")) or p.path == "peer relay" and "through a peer relay" or p.path
      relayed = relayed or p.path == "relay" or p.path == "peer relay"
      local what = ((p.rate or 0) > 0 and per_sec(p.rate) or "") .. ((p.rate or 0) > 0 and way and " " or "") .. (way or "")
      local rtt = (p.rtt_ms or 0) > 0 and p.rtt_ms or p.ms
      local ms = rtt and rtt >= 0 and string.format("%.0f ms", rtt) or nil
      each[#each + 1] = who(p.peer) .. ": " .. what .. (what ~= "" and ms and ", " or "") .. (ms or "")
    end
  end
  if #each == 0 then return nil end
  table.sort(each)
  return not relayed, "Link speed: " .. table.concat(each, "; ") ..
    (relayed and ". A relayed way is slower: for listening in time, use more bars, or record WAV." or "")
end
function direct.speed_line(cfg)
  local devs = devices(cfg.root)
  return direct.speed_line_of(direct.status(cfg).peers, function(peer) return direct.who_of(devs, peer) end)
end

-- ---- the live layer (extension 1.0.8, docs/realtime-roadmap.md steps 1-2) -------------------------------------------------------------
-- Small messages (presence, claims, chat, cues, start/stop, live MIDI notes), a shared clock, and takes streamed while they're recorded.
-- All of it is extra: with an older extension, nothing here does anything and the files-through-Syncthing paths carry on as they are.
function direct.live_available() return reaper.StudioSync_DirectMsg ~= nil and reaper.StudioSync_DirectClock ~= nil and reaper.StudioSync_DirectStream ~= nil end
direct.MSG_MAX = 65536

-- "seq\tstudio\tkind\tdata" (StudioSync_DirectMsgPoll) -> seq, studio, kind, data (data may hold tabs); nil if it isn't one.
function direct.parse_msg(s)
  local seq, studio, kind, data = tostring(s or ""):match("^(%d+)\t([^\t]+)\t([^\t]+)\t(.*)$")
  return tonumber(seq), studio, kind, data
end
-- A message to the others in the room now. data: a table (sent as JSON) or text, up to 64 KB. -> true when queued. Never raises.
-- to: only these peers (a catch-up's ask and answer go to one computer: lib/streams.lua catchup_tick. James, rt)
function direct.msg(cfg, kind, data, song, room, to)
  local ok, r = pcall(function()
    if not direct.live_available() or not direct.ensure(cfg) then return false end
    local text = type(data) == "table" and band.json_encode(data) or tostring(data)
    local peers = to or direct.peers(cfg, song, room)
    return #peers > 0 and #text <= direct.MSG_MAX and reaper.StudioSync_DirectMsg(band.info(cfg.root).id, kind, text, table.concat(peers, " ")) == 1
  end)
  return ok and r or false
end
-- The messages for this studio that arrived since this script last asked: { { seq, kind, data (a table when it was JSON), text } }.
-- Every script keeps its own place, as direct.tick does for files; the extension keeps the last 512.
local msg_seq = 0
function direct.messages(cfg)
  local out = {}
  if not direct.live_available() then return out end
  local id = band.info(cfg.root).id
  for _ = 1, 600 do
    local seq, studio, kind, text = direct.parse_msg(reaper.StudioSync_DirectMsgPoll(msg_seq))
    if not seq then break end
    msg_seq = seq
    if studio == id then out[#out + 1] = { seq = seq, kind = kind, text = text, data = text:sub(1, 1) == "{" and band.json_decode(text) or nil } end
  end
  return out
end

-- The shared clock. Each computer pings the others in the room (StudioSync_DirectPeers) and keeps NTP's estimate of each one's offset.
-- The studio's reference clock is the computer with the lowest Syncthing device id among this one and the others here that the link
-- reaches with an estimate: every computer picks the same one from the same view, and nobody's clock is "set". Shared now = this
-- computer's link clock + the reference's offset. (Two computers whose views differ for a moment, one reaching a computer the other can't,
-- can pick different references until the next estimate: Health shows each one's.)
local clock_view = { at = -math.huge, dev_of = {}, key = nil } -- the last peers handed to the extension, and their device ids
function direct.keep_clock(cfg, song, room)
  if not direct.live_available() or not direct.ensure(cfg) then return false end
  local now = reaper.time_precise()
  local peers, dev_of = direct.peers(cfg, song, room)
  -- (and again as soon as who's here changes: the peer list is cached, so asking costs nothing. James, 0.60.0-rt)
  local key = cfg.root .. "\n" .. tostring(song) .. "\n" .. tostring(room) .. "\n" .. table.concat(peers, " ")
  if not (clock_view.key == key and now - clock_view.at < direct.START_EVERY) then
    reaper.StudioSync_DirectPeers(band.info(cfg.root).id, table.concat(peers, " "))
    clock_view.at, clock_view.dev_of, clock_view.key = now, dev_of or {}, key
  end
  -- (the reference, published for the other scripts here (the panel, a test) at every tick: it was only written when Live sync itself asked
  -- the time, so every other script took its own computer as the reference: the laptop's times 365 ms off the desktop's in the first
  -- three-computer run. One non-persisted ExtState, written only when it changes. James, rt)
  local j = band.json_decode(reaper.StudioSync_DirectClock()) or {}
  local peer, dev = direct.clock_reference(require("services").my_device_id(), clock_view.dev_of, j.peers)
  local v = (peer or "") .. "\t" .. tostring(dev or "")
  if v ~= clock_view.published then reaper.SetExtState(band.SECTION, "direct reference", v, false); clock_view.published = v end
  return true
end
-- me: this computer's device id; dev_of: peer -> device id; est: StudioSync_DirectClock's peers. -> the reference's peer (nil: this
-- computer), its device id.
function direct.clock_reference(me, dev_of, est)
  local best_peer, best_dev = nil, type(me) == "string" and me or nil
  for peer, dev in pairs(dev_of or {}) do
    local e = type(est) == "table" and est[peer]
    if type(dev) == "string" and type(e) == "table" and (tonumber(e.samples) or 0) >= 4 and (e.error or "") == "" and (not best_dev or dev < best_dev) then
      best_peer, best_dev = peer, dev
    end
  end
  return best_peer, best_dev
end
-- -> seconds since 1970 on the studio's shared clock, the reference's device id, how far off it can be (ms: half the best round trip), and
-- the reference's peer (nil: this computer); nil when the extension can't (older, not started): callers keep their own clock then.
-- (a script that keeps no clock itself, the panel's Play together, goes by the reference Live sync picked, from ExtState: its own pick from no
-- view at all was this computer, 322 ms off the laptop's. shortcut: one "direct reference" for all studios, fine while one is open at a time.
-- James, 0.60.0-rt)
function direct.shared_now()
  if not direct.live_available() then return nil end
  local j = band.json_decode(reaper.StudioSync_DirectClock()) or {}
  local now, me = reaper.StudioSync_DirectNow(), require("services").my_device_id()
  local peer, dev
  if clock_view.key then
    peer, dev = direct.clock_reference(me, clock_view.dev_of, j.peers)
    reaper.SetExtState(band.SECTION, "direct reference", (peer or "") .. "\t" .. tostring(dev or ""), false)
  else
    local p, d = reaper.GetExtState(band.SECTION, "direct reference"):match("^([^\t]*)\t(.*)$")
    if not p then return nil end -- (Live sync hasn't picked one here: unknown, not "this computer". James, rt)
    if p == "" then dev = d -- (Live sync picked this computer)
    else
      local e = type(j.peers) == "table" and j.peers[p]
      if not (type(e) == "table" and (tonumber(e.samples) or 0) >= 4 and (e.error or "") == "") then return nil end -- (its estimate went stale)
      peer, dev = p, d
    end
  end
  if not peer then return now, dev, 0, nil end
  local e = j.peers[peer]
  return now + (tonumber(e.offset_ms) or 0) / 1000, dev, (tonumber(e.rtt_ms) or 0) / 2, peer
end

-- ---- the live layer's wiring (roadmap step 1; James, 0.60.0-rt) -------------------------------------------------------------------------
-- Messages are studio-wide on the link: each one says its song and room, and an id when it stands for a file (a cue's event, a chat message,
-- a live MIDI file), so a receiver takes whichever comes first once. The file is still written and stays the record and the fallback.
function direct.send_live(cfg, kind, d, song, room, id, to)
  return direct.msg(cfg, kind, { song = song, room = room, id = id, d = d }, song, room, to)
end
-- msgs (direct.messages) handed to handlers[kind](d, msg), only this song's and room's (nil: any), each kind and id once. -> how many.
local seen_ids, seen_n = {}, 0
function direct.dispatch(msgs, song, room, handlers)
  local n = 0
  for _, m in ipairs(msgs or {}) do
    local w, h = m.data, handlers[m.kind]
    if h and type(w) == "table" and (song == nil or w.song == song) and (room == nil or w.room == room) then
      local id = type(w.id) == "string" and (m.kind .. "\0" .. w.id) or nil
      if not (id and seen_ids[id]) then
        if id then
          if seen_n > 5000 then seen_ids, seen_n = {}, 0 end -- shortcut: a whole flush past 5,000 ids; the receivers' own file checks still hold
          seen_ids[id], seen_n = true, seen_n + 1
        end
        local ok, e = pcall(h, w.d, m)
        if ok then n = n + 1 else band.log("direct link, " .. m.kind .. ": " .. tostring(e)) end
      end
    end
  end
  return n
end
-- Does the link reach everyone here now (each peer's last send answered)? Live MIDI's 1-second files are only the fallback then (lib/livemidi.lua).
-- Asked at most once a second. (James, rt)
local reach_at, reach_ok = -math.huge, false
function direct.reaches_all(cfg, song, room)
  local now = reaper.time_precise()
  if now - reach_at < 1 then return reach_ok end
  reach_at, reach_ok = now, false
  if not direct.live_available() then return false end
  local peers = direct.peers(cfg, song, room)
  local j = band.json_decode(reaper.StudioSync_DirectStatus()) or {}
  local st = type(j.peers) == "table" and j.peers or {}
  reach_ok = #peers > 0
  for _, p in ipairs(peers) do reach_ok = reach_ok and type(st[p]) == "table" and st[p].ok == true end
  return reach_ok
end
-- Live sync's tick: files that arrived (-> how many: a receive pass then), who to send to, the clock, a heartbeat, and the messages by kind.
direct.HEARTBEAT = 5
local beat_at = -math.huge
-- The stream trace (ExtState "stream trace" = "1", for testing): the extension logs every stream pass to <home>/direct/stream_trace.log, and
-- lib/streams.lua its own steps there. Handed over only when it changes. (James, rt)
local trace_set
function direct.trace_path() return reaper.GetExtState(band.SECTION, "stream trace") == "1" and band.home() .. "/direct/stream_trace.log" or "" end
local function trace_tick()
  local p = direct.trace_path()
  if p ~= trace_set and reaper.StudioSync_DirectTrace then
    if p ~= "" then reaper.RecursiveCreateDirectory(band.home() .. "/direct", 0) end
    reaper.StudioSync_DirectTrace(p)
    trace_set = p
  end
end
function direct.live_tick(cfg, song, room, handlers)
  local n = direct.tick(cfg)
  if not direct.available() then return n end
  trace_tick()
  direct.refresh_peers(cfg, song, room)
  if direct.live_available() then
    direct.keep_clock(cfg, song, room)
    local now = reaper.time_precise()
    if now - beat_at >= direct.HEARTBEAT and #direct.peers(cfg, song, room) > 0 then
      beat_at = now
      direct.send_live(cfg, "heartbeat", { user = cfg.user, time = os.date("!%Y-%m-%dT%H:%M:%SZ"), room = room }, song, room)
    end
    direct.dispatch(direct.messages(cfg), song, room, handlers)
  end
  return n
end

-- ---- the extension is mandatory (James, 2026-11-19) ---------------------------------------------------------------------------------------
direct.WANT = "1.0.12" -- (the direct link's messages, clock and streams; 1.0.12: several frames in flight, send anything, link speed. lib/tools.lua EXT_WANT says the same)
-- Why the extension can't carry the link here (missing, or older than WANT), or nil. Its version as the panel reads it: ExtState "menu extension".
function direct.ext_problem()
  local have = reaper.GetExtState(band.SECTION, "menu extension")
  local fix = "Fix: Extensions > ReaPack > Synchronize packages (or run StudioSync's installer again), then restart REAPER. StudioSync running from a " ..
    "studio's folder puts the new one in by itself: restart REAPER."
  if not direct.available() or have == "" then
    return "StudioSync's extension isn't loaded here, so the direct link (changes in about 30 ms, the shared clock for Play and Record together, live " ..
      "presence, claims and chat) is off and everything waits for Syncthing. " .. fix
  end
  if band.compare_versions(have, direct.WANT) < 0 or not direct.live_available() then
    return "StudioSync's extension here is " .. have .. ", older than the " .. direct.WANT .. " this StudioSync needs: no shared clock, live presence, claims or " ..
      "chat over the direct link. " .. fix
  end
end
-- The shared clock for Health: ok (an estimate to go by), text.
function direct.clock_line()
  if not direct.live_available() then return false, "Shared clock: needs StudioSync's extension " .. direct.WANT .. "." end
  local j = band.json_decode(reaper.StudioSync_DirectClock()) or {}
  local _, dev, err, peer = direct.shared_now()
  local each = {}
  for p, e in pairs(type(j.peers) == "table" and j.peers or {}) do
    local who = p:match("^([^%.:]+)") or p
    if type(e) == "table" and (e.error or "") ~= "" then each[#each + 1] = who .. ": " .. tostring(e.error)
    elseif type(e) == "table" and (tonumber(e.samples) or 0) >= 4 then
      each[#each + 1] = string.format("%s %+.1f ms (round trip %.0f ms)", who, tonumber(e.offset_ms) or 0, tonumber(e.rtt_ms) or 0)
    else each[#each + 1] = who .. ": measuring" end
  end
  table.sort(each)
  if not peer then
    return #each > 0, "Shared clock: this computer is the reference" .. (#each > 0 and ("; " .. table.concat(each, ", ")) or
      " (nobody here to share it with: Play and Record together go by this computer's clock)")
  end
  return true, string.format("Shared clock: the reference is %s (%s), within %.0f ms; %s", peer:match("^([^%.:]+)") or peer, tostring(dev):sub(1, 7), err or 0, table.concat(each, ", "))
end
-- Health's rows for the link (lib/page_health.lua): { id, ok, colour, text when ok, text when not, action = { label, fn, tooltip } }.
function direct.health_rows(cfg)
  local why = direct.ext_problem()
  if why then return { { "menu ext", false, "red", "", why } } end
  local ok, text = direct.health_line(cfg)
  local row = { "direct", ok == true, ok == nil and "grey" or "yellow", text, text }
  if band.WIN and ok ~= nil and not direct.firewall_ok() then
    row.action = { "Set up direct link", function()
      local done, why2 = direct.setup_firewall()
      band.log(done and "direct link: Windows asks once (UAC) to let REAPER take the others' changes directly; Health turns green within a minute" or ("direct link: " .. tostring(why2)))
    end, "Adds a Windows Firewall rule for reaper.exe, TCP and UDP " .. direct.port() .. ", from Tailscale's addresses only (100.64.0.0/10). Windows asks once." }
  end
  local cok, ctext = direct.clock_line()
  local rows = { row, { "direct clock", cok, "grey", ctext, ctext } }
  local vok, vgood, vtext = pcall(direct.speed_line, cfg) -- (link speed per bandmate, 1.0.12. James, rt)
  if vok and vtext then rows[#rows + 1] = { "direct speed", vgood, "yellow", vtext, vtext } end
  local sok, srow = pcall(function() return require("streams").health_row(cfg) end) -- (takes streaming in and out: lib/streams.lua. James, rt)
  if sok and srow then rows[#rows + 1] = srow end
  local aok, arow = pcall(function() return require("ablink").health_row() end) -- (Ableton Link, when it's on here: lib/ablink.lua. James, rt)
  if aok and arow then rows[#rows + 1] = arow end
  local lok, lrow = pcall(function() return require("liveaudio").health_row(cfg) end) -- (live audio per bandmate, when the studio has it on: lib/liveaudio.lua. James, rt)
  if lok and lrow then rows[#rows + 1] = lrow end
  return rows
end

-- Settings > Studio: the studio's Direct link switch (band.json "direct": owner and admins; on unless it's false).
function direct.studio_ui(ctx, ImGui, cfg, may)
  ImGui.SeparatorText(ctx, "Direct link")
  local on = direct.enabled(cfg.root)
  ImGui.TextDisabled(ctx, on and "On: each change, presence, claim, chat message and Play/Record together goes straight to the others here over Tailscale " ..
    "(about 30 ms), and through Syncthing as well, which stays the record." or "Off: everything goes through Syncthing alone (a few seconds a change).")
  if may then
    local ch, v = ImGui.Checkbox(ctx, "Direct link##studiodirect", on)
    if ch then
      require("groups").set_direct(cfg.root, v)
      band.log(v and "the direct link is on for the studio" or "the direct link is off for the studio: changes go through Syncthing alone")
    end
    ImGui.SetItemTooltip(ctx, "Owner and admins. Needs StudioSync's extension " .. direct.WANT .. " and Tailscale on each computer (Health says what's missing).")
  end
  require("liveaudio").studio_ui(ctx, ImGui, cfg, may) -- (live audio over the link, off unless the studio turns it on: lib/liveaudio.lua. James, rt)
  -- (signed updates: the owner signs each version with a key kept on their computer, and every computer checks it before it runs. James, rt)
  ImGui.SeparatorText(ctx, "Signed updates")
  local key = band.studio_update_key and band.studio_update_key(cfg.root)
  ImGui.TextDisabled(ctx, key and "On: StudioSync runs here only in a version the owner signed. Changed or unsigned code is refused (no question), and the last good copy runs." or
    "Off: a new version in the studio's folder is used when you've said yes to it (or the studio updates through its folder).")
  if not key and require("groups").role(cfg.root, reaper.GetExtState(band.SECTION, "user")) == "owner" then
    if ImGui.Button(ctx, "Turn on signed updates##studiosign") then
      local ok, res = require("fromfolder").create_update_key(cfg.root)
      direct.sign_note = ok and "Signed updates are on. Keep the key file safe: it stays on this computer only." or tostring(res)
      band.log(ok and "signed updates turned on for the studio" or ("signed updates weren't turned on: " .. tostring(res)))
    end
    ImGui.SetItemTooltip(ctx, "Owner only. Makes a key on this computer (never in a shared folder), signs the studio's copy and tells everyone's computer to check it.\nEvery computer needs StudioSync's extension 1.0.9 first: one without it keeps running its last good copy.")
  end
  if direct.sign_note then ImGui.TextWrapped(ctx, direct.sign_note) end
end

-- Streams: a take sent while it's recorded. Its name on the link is "<song>/<file name>" (the extension's rule: a plain song folder name,
-- a plain file name with an extension on its list); the others get it in <inbox>/.streams/<song>/<file>, outside the shared folder.
-- The list (extension 1.0.12, "send anything"): audio and MIDI, and the other files a studio passes round: video references, PDF charts,
-- pictures, notes, plug-in presets and patches, Ableton sets, zips. Never anything that runs (exe, dll, dylib, so, lua, py, sh, bat, cmd, ps1,
-- js): they're simply not on it. The same as extension/direct.cpp direct_stream_rel_ok. (James, rt)
local STREAM_EXT = { wav = true, w64 = true, flac = true, aif = true, aiff = true, ogg = true, opus = true, mp3 = true, mid = true,
  mp4 = true, mov = true, webm = true, pdf = true, png = true, jpg = true, jpeg = true, txt = true, md = true,
  fxp = true, fxb = true, vstpreset = true, nam = true, sfz = true, als = true, zip = true }
function direct.stream_ext(name) local e = tostring(name or ""):match("%.(%w+)$"); return e ~= nil and STREAM_EXT[e:lower()] == true end
local function plain(s) return type(s) == "string" and #s > 0 and #s <= 200 and s:sub(1, 1) ~= "." and not s:find("[%. ]$") and not s:find('[%c/\\:%*%?"<>|\127]') end
function direct.stream_rel(song, path)
  local name = tostring(path or ""):match("([^/\\]+)$")
  if not (plain(song) and plain(name) and direct.stream_ext(name)) then return nil end
  local rel = song .. "/" .. name
  return #rel <= 512 and rel or nil
end
function direct.stream_path(cfg, rel) return direct.inbox(cfg.root) .. "/.streams/" .. rel end
-- Start streaming a file being written (REAPER recording a take) to the others in the room, every interval_ms (0: 250). -> rel, or nil.
-- `name`: its name on the link, when not the file's own (lib/streams.lua: <room>~<user>~<file>, so two people's takes never share one. James, rt)
-- `to`: only these peers (a catch-up file goes to the computer that asked for it alone. James, rt)
function direct.stream_start(cfg, path, song, room, interval_ms, name, to)
  local ok, r = pcall(function()
    local rel = direct.stream_rel(song, name or path)
    if not rel or not direct.live_available() or not direct.ensure(cfg) then return nil end
    local peers = to or direct.peers(cfg, song, room)
    return #peers > 0 and reaper.StudioSync_DirectStream(band.info(cfg.root).id, rel, path, table.concat(peers, " "), math.floor(interval_ms or 0)) == 1 and rel or nil
  end)
  return ok and r or nil
end
-- Recording stopped and REAPER has closed the file: the rest goes, then its length and SHA-256.
function direct.stream_end(cfg, rel)
  return rel ~= nil and direct.live_available() and reaper.StudioSync_DirectStreamEnd(band.info(cfg.root).id, rel) == 1
end
-- This studio's streams: { out = { { rel, size, ended, finished, peers = { [peer] = { sent, done, error } } } },
-- inn = { { rel, path, bytes, total, done, ok, playable } } }.
function direct.streams(cfg)
  local s = { out = {}, inn = {} }
  if not direct.live_available() then return s end
  local id, j = band.info(cfg.root).id, band.json_decode(reaper.StudioSync_DirectStreams()) or {}
  for _, o in ipairs(type(j.out) == "table" and j.out or {}) do if o.studio == id then s.out[#s.out + 1] = o end end
  for _, i in ipairs(type(j["in"]) == "table" and j["in"] or {}) do if i.studio == id then s.inn[#s.inn + 1] = i end end
  return s
end

return direct
