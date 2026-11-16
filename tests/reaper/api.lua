-- Run inside REAPER (ReaScript). The API for other scripts (lib/api.lua, 0.58.64): the state as a script reads it, loaded the way a script
-- loads it (dofile of the published path), the event feed, and requests (a known verb goes to the panel, anything else is refused).
-- Only ExtState, which is put back as it was at the end; nothing is opened or saved.
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
for _, m in ipairs({ "band", "api" }) do package.loaded[m] = nil end
local band, api = require("band"), require("api")
local out, fails = {}, 0
local function check(ok, what) if not ok then fails = fails + 1 end; out[#out + 1] = (ok and "PASS " or "FAIL ") .. what end
local S = api.SECTION
local saved = {}
for _, k in ipairs({ "state", "beat", "events", "event_seq", "request", "path" }) do saved[k] = reaper.GetExtState(S, k) end

local ok, err = pcall(function()
  local proj = reaper.EnumProjects(-1)
  api.publish(proj, { song = "API Lab", room = "main", me = "James", driver = "Bee", mode = "open", alone = false, others = { "Bee" },
    tracks = { bass = { user = "James", name = "Bass" } }, hold = false, local_mix = true, held = "0" })
  local path = reaper.GetExtState(S, "path")
  check(reaper.file_exists(path), "the path a script loads the API from is there: " .. path)
  package.loaded.api = nil
  local ss = dofile(path) -- (as another script does it)
  local st = ss.state()
  check(st and st.song == "API Lab" and st.driver == "Bee" and st.driving == false, "a script reads who drives")
  check(st and st.claims[1].user == "James" and st.claims[1].tracks[1] == "Bass" and st.local_mix == true and st.mode == "open", "and the claims, local mixing and the mode")
  api.publish(reaper.EnumProjects(-1) == proj and {} or proj, { song = "Other" }) -- (not the project in front: nothing written)
  check(ss.state().song == "API Lab", "only the project in front publishes")
  reaper.SetExtState(S, "beat", tostring(reaper.time_precise() - 30), false)
  check(ss.state() == nil, "nobody keeping it up to date: no state, rather than an old one")

  local seq = ss.newest()
  api.event("driver", { from = "Bee", to = "James", song = "API Lab" })
  api.event("sent", { n = 4, song = "API Lab" })
  local evs, newest = ss.events_since(seq)
  check(#evs == 2 and evs[1].kind == "driver" and evs[1].to == "James" and evs[2].n == 4, "a script gets the events since it last looked, in order")
  check(newest == seq + 2 and #ss.events_since(newest) == 0, "and nothing twice")
  for i = 1, api.KEEP + 5 do api.event("received", { n = i }) end
  check(#(band.json_decode(reaper.GetExtState(S, "events")) or {}) == api.KEEP, "only the last " .. api.KEEP .. " are kept")

  reaper.SetExtState(S, "request", "claim", false)
  check(api.take_request() == "claim" and reaper.GetExtState(S, "request") == "", "a known verb is taken for the panel, once")
  reaper.SetExtState(S, "request", "chat hello there", false)
  check(api.take_request() == "chat hello there", "chat keeps its words")
  reaper.SetExtState(S, "request", "format c:", false)
  check(api.take_request() == nil, "anything else is refused")
end)
if not ok then check(false, "ERROR " .. tostring(err)) end
for k, v in pairs(saved) do if v ~= "" then reaper.SetExtState(S, k, v, false) else reaper.DeleteExtState(S, k, false) end end
out[#out + 1] = string.format("api: fails %d of %d", fails, #out)
return table.concat(out, "\n")
