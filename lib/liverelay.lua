-- The live-audio relay's gate, order and tick (rt-audio4, docs/rt/rt-audio4.md sections 3.5 and 4). In place of the hub's mix, the hub
-- forwards each bandmate's packets and every listener mixes them itself; the role is a lease the extension keeps among the computers
-- (StudioSync_LiveAudioRelay, extension/rtaudio.cpp). Lua says only whether the room uses it, whether everything goes through it, and who
-- should hold it first:
--   - the gate: every computer on the live-audio list here says "lrelay" in its status (this module's mine(), written by Live sync beside
--     "lhub"). One that doesn't (an older extension, or one heard before its status came) closes it, and the room runs exactly what it ran
--     before: the elected song hub mixes from the studio's threshold, peer to peer below it (lib/liveaudio.lua hub_plan, unchanged);
--   - all: the room relays everything when the mix would have run (big enough and two or more sending: hub_plan's own answer), else the relay
--     only carries the bandmates a listener gets nothing from directly;
--   - the order: the hub hub_tick would have used (the song's, or the shared-CPU pick) first, then wired computers, then by name.
-- GPL-3.0-or-later.
local band = require("band")
local liverelay = { EVERY = 1 } -- (s: the room's statuses looked at at most this often)

function liverelay.can() return reaper.StudioSync_LiveAudioRelay ~= nil end
function liverelay.mine() return liverelay.can() or nil end -- (this computer's status file: "lrelay")

-- Open only when this computer has it and every computer on its live-audio list says lrelay. sts: user -> that computer's status; users:
-- peer -> user (those on the list here). Pure.
function liverelay.gate(sts, users, mine)
  if not mine then return false end
  for _, u in pairs(users or {}) do
    local x = (sts or {})[u]
    if type(x) ~= "table" or x.lrelay ~= true then return false end
  end
  return true
end

-- Who should hold the lease, first to last, as the extension takes it: each computer's peer ("name:port"), this one as "". The hub first,
-- then wired computers (the relay's uplink carries the fan-out), then by name, so every computer works out the same list from the same
-- statuses. The extension resolves a disagreement anyway (a higher term wins, then the lower address). nets: user -> its status's net. Pure.
function liverelay.order(hub, me, users, nets)
  local peer_of, names = {}, { me }
  for p, u in pairs(users or {}) do if u ~= me and (not peer_of[u] or p < peer_of[u]) then peer_of[u] = p end end
  for u in pairs(peer_of) do names[#names + 1] = u end
  nets = nets or {}
  table.sort(names, function(a, b)
    if (a == hub) ~= (b == hub) then return a == hub end
    if (nets[a] == "wired") ~= (nets[b] == "wired") then return nets[a] == "wired" end
    return tostring(a) < tostring(b)
  end)
  local out = {}
  for _, u in ipairs(names) do out[#out + 1] = u == me and "" or peer_of[u] end
  return out
end

function liverelay.json(on, all, order) return band.json_encode({ on = on and 1 or 0, all = (on and all) and 1 or 0, order = order or {} }) end

-- Live sync's tick, from lib/liveaudio.lua hub_tick with what it worked out: o.all (the mix would have run), o.hub, o.me; mem: kept between
-- calls. -> true when the relay carries the room (hub_tick then asks the extension for no mix). Tells the extension only on a change.
function liverelay.tick(cfg, b, users, o, mem)
  mem = mem or {}
  if not liverelay.can() then return false end
  local now = reaper.time_precise()
  if not mem.rsts or now - (mem.rsts_at or -math.huge) >= liverelay.EVERY then
    local ok, sts = pcall(require("presence").peers, cfg, b.song, b.room or "main")
    mem.rsts, mem.rnets, mem.rsts_at = {}, {}, now
    for _, x in ipairs(ok and type(sts) == "table" and sts or {}) do
      if type(x) == "table" and x.user then mem.rsts[x.user] = x; mem.rnets[x.user] = x.net end
    end
  end
  local on = liverelay.gate(mem.rsts, users, true)
  local json = liverelay.json(on, o.all, liverelay.order(o.hub, o.me, users, mem.rnets))
  if json ~= mem.relay_json then
    reaper.StudioSync_LiveAudioRelay(json)
    local was = mem.relay_said
    mem.relay_json = json
    mem.relay_said = (on and (o.all and "all" or "gaps")) or "off"
    if was and was ~= mem.relay_said or (not was and on) then
      band.log(mem.relay_said == "all" and "live audio: through the room's relay (each sends one stream to it, it forwards each one's stream to the others, and you mix them here)"
        or mem.relay_said == "gaps" and "live audio: peer to peer, and the room's relay carries any bandmate whose stream can't reach you directly"
        or "live audio: the room's relay is off (a computer here has an older StudioSync extension), so it's as before")
    end
  end
  return on
end

-- Health's words for the relay, from the extension's status "relay" (names: peer -> name). nil when it's off. Pure.
function liverelay.text(r, names)
  if type(r) ~= "table" or r.on ~= true then return nil end
  names = names or {}
  local h = r.holder
  local who = h == "me" and "this computer" or (type(h) == "string" and h ~= "" and ((names[h] or h:match("^([^:]+)") or h) .. "'s computer")) or nil
  local text = "; the room's relay" .. (who and (": " .. who .. " holds it") or ": nobody holds it yet")
  if h == "me" then text = text .. string.format(" (forwarding %d kbit/s to %d)", math.floor((tonumber(r.fwd_kbps) or 0) + 0.5), tonumber(r.asking) or 0) end
  local n = tonumber(r.relayed) or 0
  if n > 0 then text = text .. string.format(", %d bandmate%s reach%s you through it", n, n == 1 and "" or "s", n == 1 and "es" or "") end
  return text
end

return liverelay
