-- Claims mode (the room mode "open", the default): what you edit that nobody has claimed becomes yours, and an edit to what someone else has
-- claimed asks them for it. James, 2026-11-20: "when working into something unclaimed, auto claims it in claims mode, and when trying to edit
-- something someone else has claims, asks the person who claimed it to release, if released the change goes through to everyone and the
-- person who tried the edit takes the claim".
--   Auto-claims: an edit that goes out (mirror.watch's W.send, reported through opts.sent) claims its track, or, when one look sent items on
--     TIME_TRACKS tracks or more and nothing else, the stretch of time they cover. Only with a bandmate here (alone, nobody needs keeping out).
--     They're ordinary claims (sync.set_claims, then over the link at once) marked in the claims file's `auto` (tracks/regions) or the time
--     entry's own `auto`: the time of your last edit to it. One lasts until you release it, leave the room (Live sync stops), or go
--     sync.AUTO_IDLE seconds without editing it; sync.authority stops counting it then on every computer, and your own Live sync drops it.
--     Claiming it yourself makes it a lasting one.
--   Asking: an edit to someone else's claim (mirror.watch's W.refuse, through opts.ask) is held here, not sent and not put back, and they get
--     "<you> wants to edit <it>: Release / Keep" in the panel, the web page and a phone alert. Release: they let go of it, you take it (as
--     lasting as theirs was), and your held edit goes out on the next look. Keep, or no answer in ASK_WAIT s: it's put back, with a copy of an
--     item kept as any refused edit's is. Someone not here can't be asked: their claim stands (an admin or the driver can release it).
-- The asks travel over the direct link (claim_ask, claim_answer); with no link to them the edit is put back and says so.
local band = require("band")
local claimask = {}

claimask.ASK_WAIT = 30    -- seconds an ask waits for its answer (and stays up on the claimer's side)
claimask.COOLDOWN = 60    -- seconds after a Keep or no answer before the same thing is asked for again (edits to it are put back meanwhile)
claimask.RELEASE_WAIT = 10 -- seconds a released claim may take to become yours here before the hold gives up and asks again
claimask.MAX_IN = 5       -- asks waiting on you at once (more are answered Keep)
claimask.MAX_OUT = 3      -- your asks waiting at once
claimask.TIME_TRACKS = 3  -- items on this many tracks or more in one look: a time claim, not a claim on each track
claimask.TOUCH_EVERY = 60 -- seconds between rewrites of an auto-claim's last-edit time

local out, inq = {}, {} -- out: song/room \0 key -> my ask; inq: id -> an ask waiting on me
local sent_now = {}     -- what this look sent (opts.sent), for flush
local seq = 0

local function iso(t) return os.date("!%Y-%m-%dT%H:%M:%SZ", t or os.time()) end
local function mmss(s) s = math.max(0, math.floor(s + 0.5)); return string.format("%d:%02d", s // 60, s % 60) end
local function base(name) return require("sync").base_name(name) end

-- ---- pure ------------------------------------------------------------------------------------------------------------------------------
-- Which claim decides who owns `name` at `pos`, as sync.authority's owner() looks: a track claim, else the newest time claim over it, else
-- the claim on the named region it's in. who: sync.authority's second answer. -> { kind = "tracks"|"times"|"regions", name | from, to, user }
function claimask.which(who, name, pos)
  local t = base(name)
  local c = t and t ~= "" and who.tracks and who.tracks[t:lower()]
  if c then return { kind = "tracks", name = c.name or t, user = c.user, auto = c.auto } end
  for _, x in ipairs(pos and who.times or {}) do
    if pos >= x.from and pos < x.to then return { kind = "times", from = x.from, to = x.to, user = x.user, auto = x.auto } end
  end
  for _, sp in ipairs(pos and who.spans or {}) do
    local r = pos >= sp.from and pos < sp.to and who.regions and who.regions[sp.name]
    if r then return { kind = "regions", name = r.name or sp.name, user = r.user } end
  end
end
-- Someone else's auto-claim decides `name` at `pos` (not `user`'s, not a lasting one): its claimer, else nil. Such a claim asks only for an edit
-- that clashes with the claimer's own change to the same thing; one that merges with it goes through (James, 2026-11-20: "2 people can edit a
-- midi item at the same time, adding different notes". mirror.watch's opts.soft, sync.receive's sync.soft. rt-merge)
function claimask.soft(who, name, pos, user)
  if type(who) ~= "table" or who.mode ~= "open" or not (who.is_claimed and who.is_claimed(name, pos)) then return nil end
  local th = claimask.which(who, name, pos)
  return th and th.auto and th.user ~= user and th.user or nil
end
function claimask.key(th)
  if th.kind == "times" then return string.format("times:%.3f-%.3f", th.from, th.to) end
  return th.kind .. ":" .. th.name:lower()
end
function claimask.words(th)
  if th.kind == "times" then return "the time from " .. mmss(th.from) .. " to " .. mmss(th.to) end
  return (th.kind == "regions" and "the region " or "") .. th.name
end
-- A thing as it came over the link -> a clean copy, or nil. (A bandmate's message: only these fields, names short, times real numbers.)
function claimask.clean(th)
  if type(th) ~= "table" then return nil end
  if th.kind == "times" then
    local a, z = tonumber(th.from), tonumber(th.to)
    if not (a and z and a == a and z == z and z > a and a > -1e7 and z < 1e7) then return nil end
    return { kind = "times", from = a, to = z }
  end
  if (th.kind ~= "tracks" and th.kind ~= "regions") or type(th.name) ~= "string" or th.name == "" or #th.name > 200 or th.name:find("%c") then return nil end
  return { kind = th.kind, name = th.name }
end
local function same_time(a, b) return math.abs(a.from - b.from) < 1e-3 and math.abs(a.to - b.to) < 1e-3 end
-- Take `th` out of claims table c. -> found, whether it was an auto-claim. Pure.
function claimask.remove(c, th)
  local list, keep, found, auto = c[th.kind] or {}, {}, false, false
  for _, n in ipairs(list) do
    local hit = th.kind == "times" and type(n) == "table" and same_time(n, th) or th.kind ~= "times" and type(n) == "string" and n:lower() == th.name:lower()
    if hit then found, auto = true, auto or (th.kind == "times" and n.auto ~= nil) else keep[#keep + 1] = n end
  end
  c[th.kind] = keep
  if th.kind ~= "times" and c.auto and c.auto[claimask.key(th)] then auto = true; c.auto[claimask.key(th)] = nil end
  return found, auto
end
-- Put `th` in claims table c, an auto-claim touched at `at` when `auto` (else a lasting one: a manual claim of an auto one makes it lasting).
-- -> whether c changed. Pure.
function claimask.add(c, th, auto, at)
  c[th.kind] = c[th.kind] or {}
  for _, n in ipairs(c[th.kind]) do
    if th.kind == "times" and type(n) == "table" and same_time(n, th) then
      if auto then n.auto = at elseif n.auto then n.auto = nil; return true end
      return auto
    end
    if th.kind ~= "times" and type(n) == "string" and n:lower() == th.name:lower() then
      local k = claimask.key(th)
      if auto and c.auto and c.auto[k] then c.auto[k] = at; return true end
      if not auto and c.auto and c.auto[k] then c.auto[k] = nil; return true end
      return false
    end
  end
  if th.kind == "times" then c.times[#c.times + 1] = { from = th.from, to = th.to, auto = auto and at or nil }
  else
    c[th.kind][#c[th.kind] + 1] = th.name
    if auto then c.auto = c.auto or {}; c.auto[claimask.key(th)] = at end
  end
  return true
end
-- Auto-claims in c last edited before `cut` (an ISO time) taken out. -> the words for each. Pure.
function claimask.lapse(c, cut)
  local gone = {}
  for k, at in pairs(c.auto or {}) do
    if type(at) ~= "string" or at < cut then
      local kind, name = k:match("^(%a+):(.*)$")
      for _, n in ipairs(kind and c[kind] or {}) do
        if type(n) == "string" and n:lower() == name then claimask.remove(c, { kind = kind, name = n }); gone[#gone + 1] = claimask.words({ kind = kind, name = n }) end
      end
      if c.auto then c.auto[k] = nil end
    end
  end
  local keep = {}
  for _, t in ipairs(c.times or {}) do
    if type(t) == "table" and t.auto ~= nil and (type(t.auto) ~= "string" or t.auto < cut) then gone[#gone + 1] = claimask.words({ kind = "times", from = t.from, to = t.to })
    else keep[#keep + 1] = t end
  end
  c.times = keep
  table.sort(gone)
  return gone
end
-- What one look sent -> the things to claim: a time claim when items on TIME_TRACKS tracks or more went and nothing else did, else each
-- track. list: { { name, pos, len, kind } }. Pure.
function claimask.plan(list)
  local names, order, items_only, lo, hi = {}, {}, true, math.huge, -math.huge
  for _, s in ipairs(list) do
    local k = s.name:lower()
    if not names[k] then names[k] = s.name; order[#order + 1] = s.name end
    if s.kind ~= "item" or not s.pos then items_only = false
    else lo, hi = math.min(lo, s.pos), math.max(hi, s.pos + math.max(s.len or 0, 0.001)) end
  end
  if items_only and #order >= claimask.TIME_TRACKS then return { { kind = "times", from = lo, to = hi } } end
  local th = {}
  for _, n in ipairs(order) do th[#th + 1] = { kind = "tracks", name = n } end
  return th
end

-- ---- what the others see -----------------------------------------------------------------------------------------------------------------
local function room_of(b) return b.song .. "/" .. b.room end
-- The asks for this room: { incoming = { { id, from, what, till } }, waiting = { { to, what, till } } } (till: os.time() it runs out)
function claimask.model(b)
  local m, now, clock = { incoming = {}, waiting = {} }, reaper.time_precise(), os.time()
  local r = room_of(b)
  for id, q in pairs(inq) do
    if q.room == r then m.incoming[#m.incoming + 1] = { id = id, from = q.from, what = claimask.words(q.thing), till = clock + math.max(0, math.floor(claimask.ASK_WAIT - (now - q.at))) } end
  end
  for _, a in pairs(out) do
    if a.room == r and a.state == "asked" then m.waiting[#m.waiting + 1] = { to = a.to, what = claimask.words(a.thing), till = clock + math.max(0, math.floor(claimask.ASK_WAIT - (now - a.at))) } end
  end
  table.sort(m.incoming, function(x, y) return x.id < y.id end)
  table.sort(m.waiting, function(x, y) return x.what < y.what end)
  return m
end
local published = {}
local function publish(proj, b)
  if not proj then return end
  local m = claimask.model(b)
  local s = (#m.incoming + #m.waiting > 0) and band.json_encode(m) or ""
  if published[tostring(proj)] ~= s then published[tostring(proj)] = s; reaper.SetExtState(band.SECTION, "claim asks " .. tostring(proj), s, false) end
end
claimask.proj = nil -- the tab whose asks the panel shows (Live sync's, set by tick)

-- ---- asking (the editor's side) --------------------------------------------------------------------------------------------------------
-- Is `user` here (their presence within 45 s)? Tests replace it.
function claimask.present(cfg, b, user)
  for _, u in ipairs(require("presence").here(cfg, b.song, b.room, 45)) do if u == user then return true end end
  return false
end
-- Would an edit to `name` at `pos` ask its claimer instead of being refused? -> the claimer, or nil. (The web pages' refusal: lib/dawedit.lua)
function claimask.askable(cfg, b, who, name, pos)
  if type(who) ~= "table" or who.mode ~= "open" or not (who.is_claimed and who.is_claimed(name, pos)) then return nil end
  local th = claimask.which(who, name, pos)
  if not th or th.user == cfg.user or not claimask.present(cfg, b, th.user) then return nil end
  local a = out[room_of(b) .. "\0" .. claimask.key(th)]
  if a and (a.state == "kept" or a.state == "timeout") and reaper.time_precise() - a.done_at < claimask.COOLDOWN then return nil end
  return th.user
end
-- mirror.watch's W.refuse asks this before refusing (opts.ask). -> true: held (nothing sent, nothing put back, the band's changes to it wait);
-- a string: put it back with these words; nil: not a claim this asks about (refused as before). After a Keep or no answer, a second value:
-- true when these words were just said for that answer (the rest of the same put-back: one Keep of a track logged its words 10 times), so
-- the put-back needn't say them again. A new edit in the COOLDOWN after it is told why it wasn't asked, and when it can be. REAPER recheck,
-- 0.59.49.79, rt-edits round 6
claimask.SAID_GAP = 5 -- seconds: put-backs for one answer within this of each other are one put-back, said once
function claimask.hold(cfg, b, who, name, pos)
  if type(who) ~= "table" or who.mode ~= "open" or not (who.is_claimed and who.is_claimed(name, pos)) then return nil end
  local th = claimask.which(who, name, pos)
  if not th or th.user == cfg.user then return nil end
  local k, now = room_of(b) .. "\0" .. claimask.key(th), reaper.time_precise()
  local a, what = out[k], claimask.words(th)
  if a then
    if a.state == "asked" and now - a.at > claimask.ASK_WAIT then a.state, a.done_at = "timeout", now end
    if a.state == "released" and now - a.done_at > claimask.RELEASE_WAIT then out[k], a = nil, nil -- (it never became ours: ask again)
    elseif a.state ~= "asked" and a.state ~= "released" and now - a.done_at > claimask.COOLDOWN then out[k], a = nil, nil end
  end
  if a then
    if a.state == "asked" or a.state == "released" then require("mirror").unsettled = true; return true end -- (Live sync looks again soon)
    local quiet = a.said_at ~= nil and now - a.said_at < claimask.SAID_GAP
    local later = a.said_at ~= nil and not quiet -- (a new edit since the answer's own put-back)
    a.said_at = now
    if later then
      local ago, left = math.floor(now - a.done_at + 0.5), math.max(1, math.ceil(claimask.COOLDOWN - (now - a.done_at)))
      return string.format("Not sent: %s %s %s %d s ago, so they aren't asked again yet: edit it again in %d s to ask. Your edit is put back", th.user,
        a.state == "kept" and "kept" or "didn't answer about", what, ago, left), false
    end
    if a.state == "kept" then return "Not sent: " .. th.user .. " kept " .. what .. ". Your edit is put back", quiet end
    return "Not sent: " .. th.user .. " didn't answer about " .. what .. " in " .. claimask.ASK_WAIT .. " s. Your edit is put back (edit it again to ask again in a minute)", quiet
  end
  if not claimask.present(cfg, b, th.user) then
    return "Not sent: " .. th.user .. " has claimed " .. what .. " and isn't here to release it. Your edit is put back (the driver or an admin can release their claims)"
  end
  local n = 0
  for _, x in pairs(out) do if x.state == "asked" then n = n + 1 end end
  if n >= claimask.MAX_OUT then return "Not sent: " .. what .. " is " .. th.user .. "'s, and " .. n .. " of your asks are still waiting. Your edit is put back" end
  seq = seq + 1
  local id = require("mirror").user_tag(cfg.user) .. "-" .. os.date("!%Y%m%d%H%M%S") .. "-" .. seq
  local wire = th.kind == "times" and { kind = "times", from = th.from, to = th.to } or { kind = th.kind, name = th.name }
  if not require("direct").send_live(cfg, "claim_ask", { id = id, from = cfg.user, to = th.user, thing = wire }, b.song, b.room) then
    return "Not sent: " .. what .. " is " .. th.user .. "'s, and the direct link can't reach them right now to ask. Your edit is put back"
  end
  out[k] = { id = id, to = th.user, thing = th, at = now, state = "asked", room = room_of(b) }
  band.log("asked " .. th.user .. " to release " .. what .. ": your edit waits here for their answer (up to " .. claimask.ASK_WAIT .. " s)")
  publish(claimask.proj, b)
  require("mirror").unsettled = true
  return true
end
-- Their answer, over the link (claim_answer): { id, from, to, answer = "release"|"keep", auto }.
function claimask.on_answer(cfg, b, d)
  if type(d) ~= "table" or d.to ~= cfg.user or type(d.id) ~= "string" then return false end
  local sync = require("sync")
  for k, a in pairs(out) do
    if a.id == d.id and a.to == d.from and a.state == "asked" and a.room == room_of(b) then
      local what = claimask.words(a.thing)
      if d.answer == "release" then
        local c, why = sync.my_claims(cfg, b.song, b.room)
        if not c then
          a.state, a.done_at = "timeout", reaper.time_precise()
          band.log(a.to .. " released " .. what .. ", but " .. tostring(why))
        else
          claimask.add(c, a.thing, d.auto == true, iso())
          sync.set_claims(cfg, b.song, b.room, c)
          a.state, a.done_at = "released", reaper.time_precise()
          band.log(a.to .. " released " .. what .. ": it's yours now, and your edit goes to everyone")
        end
      else
        a.state, a.done_at = "kept", reaper.time_precise()
        band.log(a.to .. " kept " .. what .. ": your edit is put back")
      end
      out[k] = a
      publish(claimask.proj, b)
      require("mirror").unsettled = true
      return true
    end
  end
  return false
end

-- ---- being asked (the claimer's side) ---------------------------------------------------------------------------------------------------
local function has(c, th)
  for _, n in ipairs(c[th.kind] or {}) do
    if th.kind == "times" and type(n) == "table" and tonumber(n.from) and tonumber(n.to) and same_time(n, th) then return true end
    if th.kind ~= "times" and type(n) == "string" and n:lower() == th.name:lower() then return true end
  end
  return false
end
local function reply(cfg, b, id, to, yes, auto)
  return require("direct").send_live(cfg, "claim_answer", { id = id, from = cfg.user, to = to, answer = yes and "release" or "keep", auto = auto or nil }, b.song, b.room)
end
-- An ask over the link (claim_ask): { id, from, to, thing }. Not one of my claims (any more): answered Release at once, nothing to let go of.
function claimask.on_ask(cfg, b, d)
  if type(d) ~= "table" or d.to ~= cfg.user or type(d.from) ~= "string" or d.from == cfg.user or #d.from > 64 or d.from:find("%c")
      or type(d.id) ~= "string" or #d.id > 80 or not d.id:match("^[%w%-_]+$") then return false end
  local th = claimask.clean(d.thing)
  if not th then return false end
  local c = require("sync").my_claims(cfg, b.song, b.room)
  if c and not has(c, th) then reply(cfg, b, d.id, d.from, true); return true end
  local n = 0
  for id, q in pairs(inq) do
    if q.room == room_of(b) and q.from == d.from and claimask.key(q.thing) == claimask.key(th) then inq[id] = nil else n = n + 1 end
  end
  if n >= claimask.MAX_IN then reply(cfg, b, d.id, d.from, false); return false end
  inq[d.id] = { from = d.from, thing = th, at = reaper.time_precise(), room = room_of(b) }
  local what = claimask.words(th)
  band.log(d.from .. " wants to edit " .. what .. ": Release or Keep (StudioSync, or the web page) within " .. claimask.ASK_WAIT .. " s")
  pcall(require("alerts").send, cfg, "claim ask", "StudioSync: " .. d.from .. " asks for " .. what,
    d.from .. " wants to edit " .. what .. " in '" .. b.song .. "'. Release or Keep it in StudioSync within " .. claimask.ASK_WAIT .. " s") -- (one a minute)
  publish(claimask.proj, b)
  return true
end
-- Release (yes) or Keep an ask waiting on me. -> words for the log, or nil and why.
function claimask.answer(cfg, b, id, yes)
  local q = inq[id]
  if not q or q.room ~= room_of(b) then return nil, "that ask has run out" end
  local what, auto = claimask.words(q.thing), false
  if yes then
    local sync = require("sync")
    local c, why = sync.my_claims(cfg, b.song, b.room)
    if not c then return nil, why end
    local found
    found, auto = claimask.remove(c, q.thing)
    if found then sync.set_claims(cfg, b.song, b.room, c) end
  end
  inq[id] = nil
  reply(cfg, b, id, q.from, yes, auto)
  publish(claimask.proj, b)
  return yes and ("released " .. what .. " to " .. q.from .. ": their edit goes to everyone") or ("kept " .. what .. ": " .. q.from .. "'s edit is put back")
end
-- The web page's Release / Keep (topic "claimask": { id, answer }).
function claimask.web_action(cfg, b, a)
  if type(a) ~= "table" or type(a.id) ~= "string" or (a.answer ~= "release" and a.answer ~= "keep") then return nil end
  local said, why = claimask.answer(cfg, b, a.id, a.answer == "release")
  return said and ("the web page: " .. said) or ("the web page's answer: " .. tostring(why))
end

-- ---- auto-claims -------------------------------------------------------------------------------------------------------------------------
-- mirror.watch's W.send, for each change that went (opts.sent).
function claimask.on_sent(o, name, ev)
  if type(ev) ~= "table" or ev.auto or type(name) ~= "string" or name == "" or #sent_now >= 500 then return end
  local len = o.kind == "item" and type(o.state) == "string" and tonumber(o.state:match("\nLENGTH ([%d%.e%-]+)")) or nil
  sent_now[#sent_now + 1] = { name = base(name), pos = tonumber(ev.pos), len = len, kind = o.kind }
end
-- After mirror.watch: what went that nobody had claimed becomes mine; my own auto-claims it touched are touched again. who: the room's.
function claimask.flush(cfg, b, who, alone)
  local list = sent_now
  sent_now = {}
  if alone or type(who) ~= "table" or who.mode ~= "open" or #list == 0 then return 0 end
  local sync = require("sync")
  local free, mine = {}, {}
  for _, s in ipairs(list) do
    if not (who.is_claimed and who.is_claimed(s.name, s.pos)) then free[#free + 1] = s
    else
      local th = claimask.which(who, s.name, s.pos)
      if th and th.user == cfg.user then mine[claimask.key(th)] = th end
    end
  end
  local c = (#free > 0 or next(mine)) and sync.my_claims(cfg, b.song, b.room)
  if not c then return 0 end
  local now, changed, made = os.time(), false, {}
  for k, th in pairs(mine) do -- (touched again: at most once a TOUCH_EVERY, and only an auto one)
    local at
    if th.kind == "times" then for _, t in ipairs(c.times or {}) do if type(t) == "table" and same_time(t, th) then at = t.auto end end
    else at = c.auto and c.auto[k] end
    if type(at) == "string" and at < iso(now - claimask.TOUCH_EVERY) then changed = claimask.add(c, th, true, iso(now)) or changed end
  end
  for _, th in ipairs(#free > 0 and claimask.plan(free) or {}) do
    if claimask.add(c, th, true, iso(now)) then changed = true; made[#made + 1] = claimask.words(th) end
  end
  if not changed then return 0 end
  sync.set_claims(cfg, b.song, b.room, c)
  if #made > 0 then
    band.log("claimed " .. table.concat(made, ", ") .. " for you as you edit (it lets go after " .. (sync.AUTO_IDLE // 60) .. " minutes without an edit, when you leave, or with Release)")
  end
  return #made
end
-- My auto-claims all let go (Live sync stopping: leaving the room).
function claimask.leave(cfg, b)
  local sync = require("sync")
  local c = sync.my_claims(cfg, b.song, b.room)
  if not c then return 0 end
  local gone = claimask.lapse(c, "\255") -- (every one is "before" that)
  if #gone > 0 then sync.set_claims(cfg, b.song, b.room, c) end
  return #gone
end

-- ---- Live sync's tick --------------------------------------------------------------------------------------------------------------------
local lapse_at = -math.huge
function claimask.tick(proj, cfg, b)
  claimask.proj = proj
  local now = reaper.time_precise()
  local raw = reaper.GetExtState(band.SECTION, "claim answer " .. tostring(proj)) -- (the panel's Release / Keep)
  if raw ~= "" then
    reaper.DeleteExtState(band.SECTION, "claim answer " .. tostring(proj), false)
    local a = band.json_decode(raw)
    if type(a) == "table" and type(a.id) == "string" then
      local said, why = claimask.answer(cfg, b, a.id, a.yes == true)
      band.log(said or ("couldn't answer: " .. tostring(why)))
    end
  end
  for id, q in pairs(inq) do if now - q.at > claimask.ASK_WAIT then inq[id] = nil end end -- (they've put it back by now)
  for k, a in pairs(out) do
    if a.state == "asked" and now - a.at > claimask.ASK_WAIT then a.state, a.done_at = "timeout", now; require("mirror").unsettled = true end
    if a.state ~= "asked" and now - a.done_at > claimask.COOLDOWN then out[k] = nil end
  end
  if now - lapse_at > 60 then -- (my auto-claims gone idle: sync.authority already stopped counting them, so they go from the lists too)
    lapse_at = now
    local sync = require("sync")
    local c = sync.my_claims(cfg, b.song, b.room)
    local gone = c and claimask.lapse(c, iso(os.time() - sync.AUTO_IDLE)) or {}
    if #gone > 0 then
      sync.set_claims(cfg, b.song, b.room, c)
      band.log("let go of " .. table.concat(gone, ", ") .. ": " .. (sync.AUTO_IDLE // 60) .. " minutes without an edit")
    end
  end
  publish(proj, b)
end

-- ---- the panel's bar ---------------------------------------------------------------------------------------------------------------------
-- Asks waiting on you (Release / Keep) and yours waiting on others, for the front tab. Answers go to its Live sync (ExtState).
function claimask.bar(ctx, ImGui, proj)
  local raw = reaper.GetExtState(band.SECTION, "claim asks " .. tostring(proj))
  local m = raw ~= "" and band.json_decode(raw)
  if type(m) ~= "table" then return end
  local clock = os.time()
  for _, q in ipairs(type(m.incoming) == "table" and m.incoming or {}) do
    if type(q) == "table" and type(q.id) == "string" and (tonumber(q.till) or 0) >= clock then
      ImGui.AlignTextToFramePadding(ctx)
      ImGui.TextColored(ctx, 0xFFD040FF, string.format("%s wants to edit %s (%d s)", tostring(q.from), tostring(q.what), (tonumber(q.till) or clock) - clock))
      for _, yes in ipairs({ true, false }) do
        ImGui.SameLine(ctx)
        if ImGui.SmallButton(ctx, (yes and "Release##ca" or "Keep##ca") .. q.id) then
          reaper.SetExtState(band.SECTION, "claim answer " .. tostring(proj), band.json_encode({ id = q.id, yes = yes }), false)
        end
        ImGui.SetItemTooltip(ctx, yes and ("Let go of it: their edit goes to everyone and it's " .. tostring(q.from) .. "'s claim now.")
          or "Keep your claim: their edit is put back on their computer.")
      end
    end
  end
  for _, a in ipairs(type(m.waiting) == "table" and m.waiting or {}) do
    if type(a) == "table" and (tonumber(a.till) or 0) >= clock then
      ImGui.TextDisabled(ctx, string.format("Asked %s for %s: your edit waits for their answer (%d s)", tostring(a.to), tostring(a.what), (tonumber(a.till) or clock) - clock))
    end
  end
end

-- (tests)
function claimask._reset() out, inq, sent_now, published = {}, {}, {}, {} end
claimask._out, claimask._inq = function() return out end, function() return inq end

return claimask
