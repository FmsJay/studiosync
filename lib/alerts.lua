-- Phone alerts (research of other tools, 0.58.53: "since you were last here" only showed once you opened the project, so a bandmate waiting
-- on a take never knew it had landed). The studio's owner turns them on: the studio gets a channel name nobody could guess, kept in
-- _band/band.json, and whoever does something (a message, a recording, a new mix) sends one line to it at ntfy.sh, from their own REAPER.
-- Everyone who wants them subscribes to that channel in the free ntfy app, so they arrive even with REAPER closed. Nothing else is sent:
-- no audio, no project. Anyone who learns the channel name could read the lines, so it's long and random. Another ntfy server can be named
-- (band.json "alerts_server").
local band = require("band")
local alerts = {}

function alerts.channel(root)
  local j = require("groups").trusted(root) -- (only as someone in charge set it: lib/groups.lua)
  return type(j) == "table" and type(j.alerts) == "string" and j.alerts:match("^[%w%-_]+$") and j.alerts or nil
end
function alerts.server(root)
  local j = require("groups").trusted(root) -- (a member pointed everyone's alerts at their own server: review, 0.58.87)
  local s = type(j) == "table" and type(j.alerts_server) == "string" and j.alerts_server or ""
  return s:match("^https://[%w%.%-]+[%w/%-]*$") and s:gsub("/+$", "") or "https://ntfy.sh"
end

-- What's sent, as ntfy's JSON form takes it (title and message as they are, not in a URL). Pure.
function alerts.body(channel, title, message)
  return band.json_encode({ topic = channel, title = title, message = message, tags = { "musical_note" } })
end

-- At most `n` bytes, never half a character: cut inside an accent or emoji, the JSON didn't parse and ntfy dropped the alert. Review, 0.58.62. Pure.
function alerts.cut(s, n)
  if #s <= n then return s end
  local ok, at = pcall(utf8.offset, s, 0, n + 1) -- (where the character holding byte n+1 starts)
  return s:sub(1, ((ok and at) or (n + 1)) - 1)
end
local last_sent = {} -- kind -> when: at most one of each kind a minute from this computer
-- kind: "chat", "take", "mix" (one a minute each). Returns true when one went.
function alerts.send(cfg, kind, title, message)
  local channel = cfg and cfg.root and alerts.channel(cfg.root)
  if not channel then return false end
  local now = reaper.time_precise()
  if last_sent[kind] and now - last_sent[kind] < 60 then return false end
  last_sent[kind] = now
  local services = require("services")
  local file = services.TMP .. "/bandsync-alert-" .. kind .. ".json"
  local ok = pcall(band.write_atomic, file, alerts.body(channel, title, alerts.cut(message, 300)))
  if not ok then return false end
  local url = alerts.server(cfg.root)
  local win = reaper.GetOS():match("^Win") ~= nil
  services.background("alert-" .. kind, win and string.format('curl -s -m 15 --data-binary @"%s" %s & del "%s"', file, url, (file:gsub("/", "\\")))
    or string.format("curl -s -m 15 --data-binary @'%s' %s; rm -f '%s'", file, url, file), 0)
  return true
end

-- The studio's call link (band.json "call"), set by its owner or an admin: a Discord channel, a Zoom or Meet room. Only a plain https address,
-- since it's opened on everyone's computer: no quotes, spaces, & or % that a shell would read. -> it, or nil. Pure but for the read.
function alerts.call_ok(url)
  return type(url) == "string" and #url < 300 and url:match("^https://[%w%-%._~:/%?#=@+]+$") ~= nil
end
function alerts.call_link(root)
  local j = root and require("groups").trusted(root)
  return type(j) == "table" and alerts.call_ok(j.call) and j.call or nil
end
function alerts.set_call(root, url)
  require("groups").edit(root, function(j) j.call = (url ~= "" and alerts.call_ok(url)) and url or nil end)
end

-- The owner's switch: a new random channel, or none.
function alerts.set(root, on)
  local chars, t = "abcdefghjkmnpqrstuvwxyz23456789", {}
  math.randomseed(os.time() + math.floor(reaper.time_precise() * 1000) % 100000)
  for i = 1, 20 do local k = math.random(#chars); t[i] = chars:sub(k, k) end
  require("groups").edit(root, function(j) j.alerts = on and ("studiosync-" .. table.concat(t)) or nil end)
end

return alerts
