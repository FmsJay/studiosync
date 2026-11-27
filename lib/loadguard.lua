-- Loading a project safely (James, 2026-11-27, findings item 14: "Avoid crashes when loading a project, especially big ones where someone
-- clicks around early"). StudioSync does nothing to a project while REAPER loads or saves one (GetCurrentProjectInLoadSave answers then), and
-- a tab's first look waits until it has loaded and gone quiet: SETTLE s since Live sync started (or since another file opened into the tab, or
-- since a load or save ended), with REAPER's change count and track count still for QUIET s and the mouse up. Someone clicking all the time
-- doesn't hold it for ever: MAX s at most. A half-loaded project (tracks still arriving, its EXTSTATE not read yet) is never looked at, so its
-- missing tracks can't read as deletions (docs/rt/rt-reopen.md candidate A). (rt-setup)
local loadguard = { SETTLE = 1.5, QUIET = 1.0, MAX = 20 }
loadguard.loaded_at = {} -- tostring(proj) -> when its tab last settled (reaper.time_precise())
loadguard.loads = {}     -- tostring(proj) -> how many times it settled under this Live sync (2 or more: something loaded into the tab meanwhile)

-- Is REAPER loading or saving a project now (any tab)? Scripts can run then: REAPER pumps its messages while a big project loads.
function loadguard.busy()
  local f = reaper.GetCurrentProjectInLoadSave
  return f ~= nil and f() ~= nil
end

function loadguard.new(now) return { since = now, ready = false } end

-- One look at the tab: busy, its name and, until it has settled, its change count, track count and the mouse.
function loadguard.observe(st, proj)
  local o = { busy = loadguard.busy(), name = reaper.GetProjectName(proj), now = reaper.time_precise() }
  if not st.ready then
    o.cc, o.tracks = reaper.GetProjectStateChangeCount(proj), reaper.CountTracks(proj)
    o.mouse = reaper.JS_Mouse_GetState ~= nil and reaper.JS_Mouse_GetState(1) & 1 == 1
  end
  return o
end

-- The state after observation `o`. -> wait (do nothing to the project this tick), settled (it became ready just now: the first look may go,
-- and what waited for a loaded project runs). Pure.
function loadguard.step(st, o)
  if o.busy then st.ready, st.since, st.cc = false, o.now, nil; return true, false end
  if st.name ~= nil and o.name ~= st.name then st.ready, st.since, st.cc = false, o.now, nil end -- (another file opened into this tab)
  st.name = o.name
  if st.ready then return false, false end
  if o.cc == nil then return true, false end -- (observed while ready: looked at again next tick)
  if st.cc == nil or o.cc ~= st.cc or o.tracks ~= st.tracks then st.cc, st.tracks, st.quiet_from = o.cc, o.tracks, o.now end
  local age = o.now - st.since
  if (age >= loadguard.SETTLE and o.now - st.quiet_from >= loadguard.QUIET and not o.mouse) or age >= loadguard.MAX then
    st.ready = true
    return false, true
  end
  return true, false
end

-- Live sync's tick asks first: -> true while this tab must be left alone. on_settled(n) runs as it settles (n: the how-manyth time).
function loadguard.hold(st, proj, on_settled)
  local wait, settled = loadguard.step(st, loadguard.observe(st, proj))
  if settled then
    local pk = tostring(proj)
    loadguard.loaded_at[pk], loadguard.loads[pk] = reaper.time_precise(), (loadguard.loads[pk] or 0) + 1
    if on_settled then on_settled(loadguard.loads[pk]) end
  end
  return wait
end

-- Did something load into this tab after Live sync's first look (a revert, the same file opened again)? For the look's deletion guard.
function loadguard.reloaded(proj) return (loadguard.loads[tostring(proj)] or 0) > 1 end

return loadguard
