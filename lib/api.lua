-- StudioSync's API for other scripts (James, 0.58.64): what a toolbar light, a Stream Deck page, a ReaLearn mapping or a render pipeline
-- needs to know about the session, and a way to ask StudioSync to do things. Everything goes through REAPER's ExtState (section
-- "StudioSync API", never saved), so a script in Lua, EEL or Python can use it without loading anything of ours:
--   state      JSON: the studio project in front (see api.state_of). Live sync for that project rewrites it when something changes.
--   beat       reaper.time_precise() of Live sync's last look at it: older than 10 s, nobody is keeping the state up to date.
--   events     JSON list of the last 50 events, oldest first: { seq, kind, time, ... } (see api.KINDS); event_seq is the newest seq.
--   request    one verb (api.VERBS) for the panel to carry out, as its own buttons do (it asks first where they ask). Taken, it's cleared.
--   path       this file, for Lua scripts: local ss = dofile(reaper.GetExtState("StudioSync API", "path"))
-- Reading is free. A request changes the session for everyone, exactly as the panel's control would: nothing a script can't do there.
-- The fields and verbs only ever grow (api.VERSION goes up when one is added); none is renamed or removed without a new section name.
local here = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
if here and not package.path:find(here .. "/?.lua", 1, true) then package.path = here .. "/?.lua;" .. package.path end
local band = require("band")
local api = { VERSION = 1, SECTION = "StudioSync API", KEEP = 50 }
-- driver: someone else drives now (from, to). people: who's here changed (joined, left). sent / received: changes went out / came in (n).
-- chat: a message from you (text). take: you recorded something. mix: a mix was rendered (file). hold: Hold my changes (on).
api.KINDS = { "driver", "people", "sent", "received", "chat", "take", "mix", "hold" }
-- What a request may ask: each is what its control on the panel does. "chat <text>" posts to the project's chat as you.
api.VERBS = { "undo", "redo", "realtime", "chat", "history", "hold", "claim", "localmix", "keeplocal", "takecontrol", "timesync" }

-- The state as it's published, from what Live sync knows. Pure. t = { song, room, me, driver, mode, alone, others = { names },
-- tracks = who.tracks (lower name -> { user, name }), hold, local_mix, held }. -> the table that goes out as JSON.
function api.state_of(t)
  -- claims: a list of { user, tracks }, by user, each user's tracks sorted. (A list, not an object keyed by name: an empty Lua table goes out as
  -- [], so a script got a list with no claims and an object with some. Review, 0.58.67)
  local by = {}
  for _, c in pairs(t.tracks or {}) do
    if type(c) == "table" and c.user then by[c.user] = by[c.user] or {}; table.insert(by[c.user], c.name) end
  end
  local claims = {}
  for user, list in pairs(by) do table.sort(list); claims[#claims + 1] = { user = user, tracks = list } end
  table.sort(claims, function(a, z) return a.user < z.user end)
  local here_now = {}
  for _, n in ipairs(t.others or {}) do here_now[#here_now + 1] = n end
  table.sort(here_now)
  return { api = api.VERSION, version = band.VERSION, song = t.song, room = t.room, me = t.me, driver = t.driver, driving = t.driver == t.me,
    mode = t.mode or require("sync").DEFAULT_MODE, alone = t.alone == true, here = here_now, claims = claims, hold = t.hold == true, local_mix = t.local_mix == true,
    held = tonumber(t.held) or 0 }
end

-- An event onto the list: numbered, stamped, the oldest dropped past `keep`. Pure. -> the list, the new seq.
function api.push(list, seq, ev, keep, now)
  seq = (tonumber(seq) or 0) + 1
  ev.seq, ev.time = seq, ev.time or now
  list[#list + 1] = ev
  while #list > (keep or api.KEEP) do table.remove(list, 1) end
  return list, seq
end

-- ---- what StudioSync calls ----
local last_state
-- Live sync, for the project in front: the state, written only when it changed, and the beat every time.
function api.publish(proj, t)
  if proj ~= reaper.EnumProjects(-1) then return end
  reaper.SetExtState(api.SECTION, "beat", tostring(reaper.time_precise()), false)
  local s = band.json_encode(api.state_of(t))
  if s ~= last_state or reaper.GetExtState(api.SECTION, "state") ~= s then
    last_state = s
    reaper.SetExtState(api.SECTION, "state", s, false)
    reaper.SetExtState(api.SECTION, "path", (here or "") .. "/api.lua", false)
  end
end
function api.event(kind, fields)
  local ev = fields or {}
  ev.kind = kind
  local list = band.json_decode(reaper.GetExtState(api.SECTION, "events")) or {}
  local seq
  list, seq = api.push(list, reaper.GetExtState(api.SECTION, "event_seq"), ev, api.KEEP, os.date("!%Y-%m-%dT%H:%M:%SZ"))
  reaper.SetExtState(api.SECTION, "events", band.json_encode(list), false)
  reaper.SetExtState(api.SECTION, "event_seq", tostring(seq), false)
end
-- The panel, every frame: a script's request, handed to the same "panel do" its own controls and the bindable actions use. -> the verb, or nil.
function api.take_request()
  local r = reaper.GetExtState(api.SECTION, "request")
  if r == "" then return nil end
  reaper.DeleteExtState(api.SECTION, "request", false)
  local verb = r:match("^(%S+)")
  for _, v in ipairs(api.VERBS) do if v == verb then return r end end
  band.log("a script asked StudioSync for '" .. r:sub(1, 40) .. "', which it doesn't do (the API's verbs: " .. table.concat(api.VERBS, ", ") .. ")")
end

-- ---- for other scripts (Lua): local ss = dofile(reaper.GetExtState("StudioSync API", "path")) ----
-- The studio project in front, or nil (none in front, or Live sync isn't keeping it up to date).
function api.state()
  local beat = tonumber(reaper.GetExtState(api.SECTION, "beat"))
  if not (beat and reaper.time_precise() - beat < 10) then return nil end
  return band.json_decode(reaper.GetExtState(api.SECTION, "state"))
end
-- Events newer than `seq` (0 or nil: all that are kept), oldest first, and the newest seq to pass next time. In a defer loop:
--   local seq = ss.newest(); local function loop() local evs; evs, seq = ss.events_since(seq); ... reaper.defer(loop) end
function api.events_since(seq)
  seq = tonumber(seq) or 0
  local out = {}
  for _, ev in ipairs(band.json_decode(reaper.GetExtState(api.SECTION, "events")) or {}) do if (ev.seq or 0) > seq then out[#out + 1] = ev end end
  return out, math.max(seq, tonumber(reaper.GetExtState(api.SECTION, "event_seq")) or 0)
end
function api.newest() return tonumber(reaper.GetExtState(api.SECTION, "event_seq")) or 0 end
-- Ask the panel to do something (api.VERBS; "chat <text>"): the panel opens if it was closed.
function api.request(verb)
  reaper.SetExtState(api.SECTION, "request", tostring(verb), false)
  local beat = tonumber(reaper.GetExtState(band.SECTION, "panel alive"))
  if not (beat and reaper.time_precise() - beat < 10) and here then band.panel_do(here:match("^(.*)[/\\]lib$") or here, "") end
end

return api
