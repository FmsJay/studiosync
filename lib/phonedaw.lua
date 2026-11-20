-- StudioSync on the phone, stage 2 (docs/realtime-roadmap.md "StudioSync on the phone"; the page is lib/webui/phonedaw.js inside the phone
-- app, record.html). The phone's Project view draws the Project page's own topics as they are (lib/dawview.lua: daw, dawc<k>); this adds the
-- little it needs beyond them, as the topic phonedaw, built only while a phone says it's looking (an action "want", every 10 s):
--   lanes   each shown track (dawview.shown, in the same order as the daw topic's tracks) with its GUID (the phone's takes name their track by
--           it, so they're drawn in place) and its oid (the Mixer page's strips name a track by it: lib/webmixer.lua)
--   takes   "lane:idx" -> { a = the active take (0-based), n = the takes' names } for each shown item with more than one take
--   reply   the last pick's answer ({ id, ok | why }), so the phone that sent it snaps back on a refusal
-- and the one band change it makes itself: which take of an item plays (comp-lite: the active take), checked as this computer's own edits are
-- before they go out (lib/dawedit.lua's rule: the room's for the track's name and the spot, or its maker's while nobody has claimed it, and
-- not while a bandmate is editing the item), then made here in one undo point, so the normal sync carries it on: no second sync path. A
-- track's volume and mute go through the Mixer page's own checked moves (topic mixer, lib/webmixer.lua). The phone's personal monitor mix (its
-- levels for the mix and its own takes, a reverb and an EQ in its headphones) never comes here: it lives on the phone. (James, rt)
local band = require("band")
local phonedaw = {}
phonedaw.WANT_FOR = 30     -- seconds a phone's "I'm looking" lasts (it says so every 10 s)
phonedaw.LOOK_EVERY = 0.5  -- seconds between looks at REAPER's change count
phonedaw.FLOOR = 10        -- a whole look at least this often
phonedaw.TAKES_MAX = 16    -- takes listed per item (the first ones)
phonedaw.NAME_MAX = 40     -- characters of a take's name
phonedaw.TOL = 0.002       -- seconds: an item still where the phone drew it (positions go rounded to ms)

-- ---- pure ------------------------------------------------------------------------------------------------------------------------------
local function num(x) x = tonumber(x); return x and x == x and x > -1e7 and x < 1e7 and x or nil end
local function int(x) x = tonumber(x); return x and x >= 0 and x < 1e6 and math.floor(x) == x and math.floor(x) or nil end
-- An action from the phone (a trust boundary: a phone with the studio's token is one) -> what it asks for, checked: { want, id, take = { lane,
-- idx, p, l, k } }, or nil, why and the id (so the phone still hears why).
function phonedaw.parse(a)
  if type(a) ~= "table" then return nil, "not an action" end
  local id = type(a.id) == "string" and #a.id <= 40 and a.id:match("^[%w%-]+$") and a.id or nil
  local out = { want = a.want == true or nil, id = id }
  if a.take ~= nil then
    local t = type(a.take) == "table" and a.take or {}
    out.take = { lane = int(t.lane), idx = int(t.idx), p = num(t.p), l = num(t.l), k = int(t.k) }
    if not (out.take.lane and out.take.idx and out.take.p and out.take.l and out.take.k) then return nil, "that isn't a take the phone showed", id end
  end
  return out
end

-- ---- reading and changing REAPER --------------------------------------------------------------------------------------------------------
local function shown_tracks(proj)
  local dawview, out = require("dawview"), {}
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    if dawview.shown(tr) then out[#out + 1] = tr end
  end
  return out
end
-- The topic's lanes and takes for the project in front.
function phonedaw.read(proj)
  local dawview, mirror = require("dawview"), require("mirror")
  local lanes, takes = {}, {}
  for li, tr in ipairs(shown_tracks(proj)) do
    local o = mirror.track_oid(tr)
    lanes[li] = { g = reaper.GetTrackGUID(tr), o = o ~= "" and o or nil }
    for j, it in ipairs(dawview.items_of(tr)) do
      local n = reaper.CountTakes(it)
      if n > 1 then
        local names, active = {}, reaper.GetActiveTake(it)
        local a = 0
        for k = 0, math.min(n, phonedaw.TAKES_MAX) - 1 do
          local tk = reaper.GetTake(it, k)
          names[#names + 1] = tk and reaper.GetTakeName(tk):sub(1, phonedaw.NAME_MAX) or ""
          if tk and tk == active then a = k end
        end
        takes[(li - 1) .. ":" .. (j - 1)] = { a = a, n = names }
      end
    end
  end
  return lanes, takes
end
-- One undo point, closed whatever happens. -> nil, or what went wrong.
local function in_undo(proj, label, fn)
  reaper.Undo_BeginBlock2(proj)
  local ok, err = pcall(fn)
  reaper.Undo_EndBlock2(proj, "StudioSync phone: " .. label, -1)
  reaper.UpdateArrange()
  if not ok then return tostring(err) end
end
local function track_name(tr) return select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)) end
-- -> nil when done, or why not.
local function apply(proj, cfg, b, d)
  local sync, mirror, dawedit = require("sync"), require("mirror"), require("dawedit")
  local can, who = sync.authority(cfg, b.song, b.room, band.read_json(band.session_path(cfg, b.song)))
  local t = d.take
  local tr = shown_tracks(proj)[t.lane + 1]
  local it = tr and require("dawview").items_of(tr)[t.idx + 1]
  if not it or math.abs(reaper.GetMediaItemInfo_Value(it, "D_POSITION") - t.p) > phonedaw.TOL
    or math.abs(reaper.GetMediaItemInfo_Value(it, "D_LENGTH") - t.l) > phonedaw.TOL then return "that item changed meanwhile" end
  local tk = t.k < reaper.CountTakes(it) and reaper.GetTake(it, t.k)
  if not tk then return "that take isn't there any more" end
  local ioid = mirror.item_oid(it)
  local holder = ioid ~= "" and require("presence").holder(require("presence").peers(cfg, b.song, b.room), ioid)
  if holder and holder ~= cfg.user then return tostring(holder) .. " is editing that item right now: try again in a few seconds" end
  local why = dawedit.item_refusal(can, who, cfg.user, track_name(tr), mirror.track_oid(tr), ioid ~= "" and ioid or nil, t.p)
  if why then return why end
  return in_undo(proj, "pick take", function() reaper.SetActiveTake(tk) end)
end

-- ---- Live sync's tick (through lib/webui.lua) -------------------------------------------------------------------------------------------
local S = { want_until = -math.huge }
function phonedaw.reset() S = { want_until = -math.huge } end -- (tests)

-- An action the phone sent. -> words for the log, or nil.
function phonedaw.action(proj, cfg, b, a)
  if a.keys ~= nil then return require("livekeys").action(proj, cfg, b, a.keys) end -- (the Play view's notes, live on a track: lib/livekeys.lua)
  local d, why, id = phonedaw.parse(a)
  if d then
    if d.want then S.want_until = reaper.time_precise() + phonedaw.WANT_FOR end
    if not d.take then return end
    id = d.id
    why = apply(proj, cfg, b, d)
  end
  S.reply, S.looked = { id = id, ok = not why or nil, why = why }, nil -- (looked again at once: the phone sees its change)
  if why then return "the phone's take pick wasn't made: " .. why end
  return "the phone picked take " .. (d.take.k + 1) .. " of an item"
end

-- Each tick in front, while a phone looks. publish(topic, table) is lib/webui.lua's (sends only what changed).
function phonedaw.tick(proj, cfg, b, publish, now)
  if now >= S.want_until then return end
  local key, cc = b.song .. "/" .. b.room, reaper.GetProjectStateChangeCount(proj)
  if S.key ~= key then S.key, S.looked = key, nil end -- (another project in front: looked at at once, not up to FLOOR s later)
  if S.looked and (now - S.looked < phonedaw.LOOK_EVERY or (cc == S.cc and now - S.looked < phonedaw.FLOOR)) then return end
  S.looked, S.cc = now, cc
  local lanes, takes = phonedaw.read(proj)
  publish("phonedaw", { key = key, lanes = lanes, takes = next(takes) and takes or nil, reply = S.reply })
end

return phonedaw
