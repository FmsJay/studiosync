-- rt-sync2c phase 3 (docs/rt/rt-sync2.md sections 6 and 7, docs/rt/rt-sync2c.md): the look and what it may delete. Lua 5.4, from the repo
-- root. Each part fails without its commit; rt-guard's tests (tests/test_0_60_rt_guard.lua) pin the rest of section 6's list (records and an
-- empty project, a first look, a reload in the tab, an older .rpp, a real delete, REAPER's Undo of a delete).
--  1. Track 1 deleted with a knob turned on another track's plug-in, inside the minute after that chain landed: the knob goes out. The
--     project's instance is told by its master track, not its first track (the soak's 5028 class: deleting track 1 read as a reopen, the
--     chain's knobs were noted afresh as loading, and the knob was never sent, on that computer alone).
package.path = "lib/?.lua;tests/fixtures/?.lua;" .. package.path
local T = 1800000000
local real_time, real_date = os.time, os.date
os.time = function(t) if t then return real_time(t) end return T end
os.date = function(fmt, t) return real_date(fmt, t or T) end
local E = require("editreaper")
local F0 = E.new("C:/A/Song.rpp")
reaper = F0.reaper
local band = require("band")
local files, logged = {}, {}
band.read_json = function(path) local v = files[path]; if type(v) == "table" then return band.json_decode(band.json_encode(v)) end end
band.write_json = function(path, v) files[path] = band.json_decode(band.json_encode(v)); return true end
band.log = function(s) logged[#logged + 1] = s end
local function list(dir) local out = {}; for p in pairs(files) do local f = p:match("^" .. dir:gsub("%p", "%%%0") .. "/([^/]+%.json)$"); if f then out[#out + 1] = f end end; table.sort(out); return out end
band.files, band.listing = list, function(dir) return list(dir) end
package.loaded.trust = { claim_ok = function() return true end }
local mirror = require("mirror")
local sync = require("sync")
require("prints").choose = function() end
local function told(pattern) for _, l in ipairs(logged) do if l:find(pattern) then return l end end end

-- ---- computers: the stand-in REAPER, each look and receive wired as Live sync wires them (as tests/test_0_60_rt_converge.lua) ---------------
local claimask = require("claimask")
local wire = {}
require("direct").send_live = function(cfg, kind, d) wire[#wire + 1] = { kind = kind, d = d, from = cfg.user }; return true end
claimask.reachable = function() return nil end
claimask.present = function() return false end
-- (plug-ins through the API, read from the chain's text as REAPER's would read: one knob per plug-in, the number in its state line. As
-- tests/test_0_60_rt_converge.lua and tools/soak/node.lua)
local function fx_api(c)
  local function blocks(tr)
    local out, cur, d = {}, nil, 0
    for l in (tr.body or ""):gmatch("[^\n]+") do
      if l == "<FXCHAIN" then d = 1
      elseif d == 1 and l:match("^BYPASS ") then cur = { l }; out[#out + 1] = cur
      elseif d >= 1 then
        if cur and not (d == 1 and l == ">") then cur[#cur + 1] = l end
        if l:sub(1, 1) == "<" then d = d + 1 elseif l == ">" then d = d - 1 end
      end
    end
    return out
  end
  local R = c.F.reaper
  rawset(R, "TrackFX_GetCount", function(tr) return #blocks(tr) end)
  rawset(R, "TrackFX_GetNumParams", function(tr, i) return blocks(tr)[i + 1] and 1 or 0 end)
  rawset(R, "TrackFX_GetParamNormalized", function(tr, i) local b = blocks(tr)[i + 1]; return b and (tonumber((b[3] or ""):match("^QUFB(%d+)")) or 0) / 1000 or 0 end)
  rawset(R, "TrackFX_GetFXName", function(tr, i) local b = blocks(tr)[i + 1]; return b ~= nil, b and b[2]:match('^<%u+ "([^"]*)"') or "" end)
  rawset(R, "TrackFX_GetPreset", function() return false, "" end)
  rawset(R, "TrackFX_GetOpen", function() return false end)
  rawset(R, "TrackFX_GetEnabled", function(tr, i) return blocks(tr)[i + 1] ~= nil end)
  rawset(R, "TrackFX_GetOffline", function() return false end)
  rawset(R, "TrackFX_GetFXGUID", function(tr, i) for _, l in ipairs(blocks(tr)[i + 1] or {}) do local g = l:match("^FXID (%S+)"); if g then return g end end end)
end
local function chain(eq)
  return "<FXCHAIN\nSHOW 0\nLASTSEL 0\nDOCKED 0\nBYPASS 0 0 0\n" .. '<VST "VST: ReaEQ (Cockos)" reaeq.dll 0 "" 1919247729<56535472656571726561657100000000> ""' ..
    "\nQUFB" .. eq .. "AAAA\n>\nFLOATPOS 0 0 0 0\nFXID {EQ-1}\nWAK 0 0\n>\n"
end
local function studio(song, mode)
  local S = { song = song, dir = "R/" .. song .. "/rooms/main", sess = { host = "James", markers = {} }, b = { song = song, room = "main" } }
  files[S.dir .. "/mode.json"] = { mode = mode or "everyone", by = "James" }
  local function as(c) reaper = c.F.reaper end
  S.as = as
  function S.computer(user)
    local c = { F = E.new("C:/" .. user .. "/" .. song .. ".rpp"), cfg = { user = user, root = "R" }, user = user }
    require("undo").confirm = function() return true end
    c.F.reaper.GetMousePosition = function() return 0, 0 end
    c.F.reaper.file_exists = function(p) return not p:find("%.json$") or files[p] ~= nil end
    c.F.reaper.SetExtState(band.SECTION, "user", user, false)
    c.edited = -1
    fx_api(c)
    return c
  end
  function S.look(c)
    as(c)
    c.F.clock = c.F.clock + 1
    local may, w = sync.authority(c.cfg, song, "main", S.sess)
    sync.driver_name, sync.room_mode = w.driver, w.mode
    mirror.watch(c.F.proj, c.cfg, song, "main", { can = may, owner_can = may, mode = w.mode, is_claimed = w.is_claimed, owner_of = w.owner_of, quick = true,
      edited_at = c.edited, soft = function(name, pos) return claimask.soft(w, name, pos, c.cfg.user) end,
      ask = function(name, pos) return claimask.hold(c.cfg, S.b, w, name, pos) end, sent = claimask.on_sent, big_delete = S.big_delete })
    claimask.flush(c.cfg, S.b, w, false)
    wire = {}
    as(c)
  end
  function S.settle(c)
    for _ = 1, 20 do
      local n = 0
      for _ in pairs(files) do n = n + 1 end
      S.look(c)
      local m = 0
      for _ in pairs(files) do m = m + 1 end
      if m == n and not mirror.more and not mirror.unsettled then return end
      mirror.unsettled = nil
    end
    error("never settled")
  end
  function S.edit(c, fn) as(c); c.F.clock = c.F.clock + 1; fn(c.F); c.edited = c.F.clock; S.settle(c) end
  function S.recv(c, no_look)
    as(c)
    sync.ev_cache = {}
    for _ = 1, 20 do
      c.F.clock = c.F.clock + 1
      local may, w = sync.authority(c.cfg, song, "main", S.sess)
      sync.room_mode = w.mode
      sync.soft = { room = "main", fn = function(name, pos, user) return claimask.soft(w, name, pos, user) end }
      local got = sync.receive(c.F.proj, c.cfg, song, "main", may)
      if (tonumber(got) or 0) == 0 and not sync.backlog and not sync.read_cut then break end
    end
    if not no_look then S.settle(c) end
  end
  function S.names(c) local t = {}; for _, tr in ipairs(c.F.tracks) do t[#t + 1] = tr.name end; return table.concat(t, ", ") end
  function S.track(c, name) for _, t in ipairs(c.F.tracks) do if t.name == name then return t end end end
  function S.events(pred) local out = {}; for p, v in pairs(files) do if p:find(S.dir .. "/events/", 1, true) and type(v) == "table" and pred(v) then out[#out + 1] = v end end; return out end
  function S.knob(c) local t = S.track(c, "Keys"); return t and (t.body or ""):match("QUFB(%d+)AAAA") end
  return S
end
-- the song both have: Drums (track 1), Keys with a ReaEQ, Gtr; Bee's chain on Keys landed just now (its minute of loading under way)
local function song(name)
  local S = studio(name)
  local A, B = S.computer("James"), S.computer("Bee")
  S.edit(A, function(F) F.add_track("Drums"); F.add_track("Keys", nil, chain(100)); F.add_track("Gtr") end)
  A.F.clock = A.F.clock + 70
  S.settle(A)
  S.recv(B)
  assert(S.names(B) == "Drums, Keys, Gtr" and S.knob(B) == "100", "the song on Bee's (" .. S.names(B) .. ", " .. tostring(S.knob(B)) .. ")")
  return S, A, B
end

-- ---- 1. track 1 deleted with a knob turned (the soak's 5028 class) -------------------------------------------------------------------------
do
  local S, A, B = song("Reopen1")
  T = T + 5
  S.edit(B, function(F)
    S.track(B, "Keys").body = chain(150) -- (her knob, from a control surface: inside the minute after the chain landed)
    reaper.DeleteTrack(S.track(B, "Drums"))
    F.changed()
  end)
  local sent = S.events(function(v) return v.obj == "fx" and v.user == "Bee" end)
  assert(#sent == 1 and sent[1].state:find("QUFB150AAAA", 1, true), "Bee's knob goes out with her deletion of track 1 (was: noted as the chain loading, never sent): " .. #sent)
  S.recv(A)
  assert(S.knob(A) == "150" and not S.track(A, "Drums"), "and lands on James's: " .. tostring(S.knob(A)) .. ", " .. S.names(A))
  print("rt-reopen 1: a knob turned as track 1 is deleted goes out (the project's instance is told by its master track)")
end

-- ---- 2. the file opened again in its tab inside the minute after a chain landed, with a knob turned since (the soak's 5010) -----------------
do
  local S, A, B = song("Reopen2")
  T = T + 5
  S.as(B)
  S.track(B, "Keys").body = chain(150) -- (turned before any look saw it, then the project saved and opened again in the same tab)
  local snap = B.F.save()
  B.F.clock = B.F.clock + 1
  B.F.load(snap)
  mirror.opened[tostring(B.F.proj)] = nil -- (REAPER gives the file a new master track)
  B.edited = B.F.clock
  S.settle(B)
  local sent = S.events(function(v) return v.obj == "fx" and v.user == "Bee" end)
  assert(#sent == 1 and sent[1].state:find("QUFB150AAAA", 1, true), "the knob in the file goes out (was: noted afresh at the opening as the plug-in loading, never sent): " .. #sent)
  S.recv(A)
  assert(S.knob(A) == "150", "and lands on James's: " .. tostring(S.knob(A)))
  -- and a chain that only reloads at the opening (its knobs as they landed) isn't sent
  T = T + 5
  S.as(A)
  local snap2 = A.F.save()
  A.F.clock = A.F.clock + 1
  A.F.load(snap2)
  mirror.opened[tostring(A.F.proj)] = nil
  A.edited = A.F.clock
  S.settle(A)
  assert(#S.events(function(v) return v.obj == "fx" and v.user == "James" end) == 1, "James's reopened chain, as it landed: nothing more sent")
  print("rt-reopen 2: a knob turned and the file opened again inside the minute after its chain landed still goes out")
end

print("ok rt-reopen")
