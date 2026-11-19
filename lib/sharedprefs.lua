-- A studio's shared REAPER preferences (James, 2026-11-19: "a studio preference set for the global REAPER preferences that shape recording and
-- editing"). They live in each computer's reaper.ini, not the song, so they can't travel with it: the owner or an admin picks which (band.json
-- "shared_prefs" = { key = value }, read through lib/groups.lua's trusted settings), and each computer puts the studio's values in while a
-- song of that studio is the tab in front, its own saved first and put back when no song of the studio is in front, at a switch to another
-- studio (its own values, or that studio's), and when Live sync stops (REAPER quitting too).
-- Live only: each is set at once through SWS (SNM_SetIntConfigVar / SNM_SetDoubleConfigVar, after reading it back in the same size: a set
-- of the wrong size is what crashed ReaPersona 5.11.1). None on the list needs a restart; ones that would (audio/MIDI devices, threads) are left off, as everything this computer's own is.
-- With ReaPersona (its approach and key names, not its code): ReaPersona never writes a preference into a running REAPER, it queues
-- them for the next restart (pending/prefs.json), so after a restart a persona's values are simply what's live. StudioSync saves what's live
-- (yours or the persona's), puts the studio's on top, and puts back only where the value is still the studio's: one changed since (by you,
-- or by ReaPersona's restart write) is left as it is, as ReaPersona's own put-back does (want_pref compares with what's live). While the
-- studio's are in, ExtState "StudioSync"/"shared prefs held" lists them (";key;"), the way ReaPersona's "persona prefs" marks its own, so
-- capturing "My REAPER" can leave them out. Kept in ExtState "shared prefs state" (persisted): REAPER crashing or quitting with the studio's
-- in leaves them in reaper.ini, and the next start puts yours back.
local band = require("band")
local sp = { STATE = "shared prefs state", HELD = "shared prefs held" }

-- { reaper.ini key, kind ("i" int, "d" double), what }. Names checked against REAPER 7.79's own config names (reaper.exe) and ReaPersona's
-- list (Mespotine's reference). (What a new recording does over items was here; it's per project, so it travels with the song now:
-- lib/band.lua FRONT_TOGGLES rec_overlap. Measured on the desktop, James, rt)
sp.PREFS = {
  { "deffadelen", "d", "Default fade length (seconds)" },
  { "deffadeshape", "i", "Default fade shape" },
  { "defsplitxfadelen", "d", "Crossfade length on split and auto-crossfade (seconds)" },
  { "defxfadeshape", "i", "Crossfade shape" },
  { "splitautoxfade", "i", "Splitting items: auto-crossfade on split and its options" },
}
-- Never shared, whatever band.json says: this computer's own (as ReaPersona's PREF_HERE, plus the look). A key on the list above can't match.
sp.NEVER = { "^audio", "^asio", "^wasapi", "^dsound", "^coreaudio", "^alsa", "^jack", "^pulse", "^ks_", "bsize", "bufsize", "latency", "lat[io][nu]t?$",
  "^midiins", "^midiouts", "^midilat", "path", "dir$", "theme", "colou?r", "zoom", "layout", "font", "uiscale", "^dock", "wnd", "_vis$", "_dock$",
  "workthreads", "renderthreads" }
local INFO = {}
for _, x in ipairs(sp.PREFS) do INFO[x[1]] = x end
function sp.info(k) return INFO[k] end
function sp.never(k)
  local low = tostring(k):lower()
  for _, pat in ipairs(sp.NEVER) do if low:find(pat) then return true end end
  return false
end
-- A studio set as band.json may have it, made safe (pure): only keys on the list, never one of NEVER, numbers only.
function sp.clean(t)
  local out = {}
  for k, v in pairs(type(t) == "table" and t or {}) do
    local x, n = INFO[k], tonumber(v)
    if x and not sp.never(k) and n and n == n and math.abs(n) < 1e9 then
      if x[2] == "i" then out[k] = math.tointeger(n)
      else out[k] = n end
    end
  end
  return out
end
function sp.studio(root) return sp.clean(require("groups").trusted(root).shared_prefs) end

-- ---- this REAPER's live values --------------------------------------------------------------------------------------------------------
local NO1, NO2 = -2147480001, -2147480002 -- (two error values: SWS answers its error value for a name it doesn't know or a size it won't read)
function sp.read(k)
  local x = INFO[k]
  if not x then return nil end
  local get = x[2] == "d" and reaper.SNM_GetDoubleConfigVar or reaper.SNM_GetIntConfigVar
  if not get then return nil end
  local a = get(k, NO1)
  if type(a) ~= "number" or a ~= get(k, NO2) then return nil end -- (not here, or not that size: left alone)
  return a
end
function sp.write(k, v)
  local x = INFO[k]
  if not x or sp.read(k) == nil then return false end -- (only what reads back in its size is ever set)
  if x[2] == "d" then return reaper.SNM_SetDoubleConfigVar(k, tonumber(v)) end
  local n = math.tointeger(tonumber(v))
  return n ~= nil and reaper.SNM_SetIntConfigVar(k, n)
end
function sp.same(a, b) local x, y = tonumber(a), tonumber(b); return x ~= nil and y ~= nil and math.abs(x - y) < 1e-6 end

-- ---- in and out ---------------------------------------------------------------------------------------------------------------------
local looked = { at = -math.huge }
local session_seen = false -- (this REAPER's first look: what a crash or quit left in is looked at once)
-- `root`: the studio whose song is the tab in front, or nil (none: yours back). Once a second at most unless `now_too`. Each key on its own:
-- the studio's wanted and not yet in: yours saved, theirs in; in and no longer wanted: yours back, if it's still theirs; changed here while
-- theirs was in: that's yours now, not fought (until another studio's song comes in front).
function sp.tick(root, now_too)
  local t = reaper.time_precise()
  if not now_too and looked.root == root and t - looked.at < 1 and t >= looked.at then return end
  looked.at, looked.root = t, root
  local st = band.ext_json(band.SECTION, sp.STATE) or {}
  local orig, applied, yielded = type(st.orig) == "table" and st.orig or {}, type(st.applied) == "table" and st.applied or {}, type(st.yielded) == "table" and st.yielded or {}
  local changed = false
  if not session_seen then -- (left in by the last REAPER: a key changed since, by ReaPersona's restart write or by hand, is yours now)
    session_seen = true
    if reaper.GetExtState(band.SECTION, "shared prefs session") == "" then
      reaper.SetExtState(band.SECTION, "shared prefs session", "1", false)
      for k, v in pairs(applied) do
        local now = sp.read(k)
        if now == nil or not sp.same(now, v) then applied[k], orig[k], changed = nil, nil, true end
      end
      yielded = {}
    end
  end
  if st.root ~= root then yielded, changed = {}, true end
  local want = root and sp.studio(root) or {}
  for k, v in pairs(applied) do
    if want[k] == nil then
      local now = sp.read(k)
      if now ~= nil and sp.same(now, v) and orig[k] ~= nil then sp.write(k, orig[k]) end
      applied[k], orig[k], changed = nil, nil, true
    end
  end
  for k, v in pairs(want) do
    local now = sp.read(k)
    if now ~= nil and not yielded[k] then
      if applied[k] ~= nil and not sp.same(now, applied[k]) then
        yielded[k], applied[k], orig[k], changed = true, nil, nil, true
        band.log("you changed " .. (INFO[k][3]) .. " while the studio's was in: yours stands, and isn't put back")
      else
        if orig[k] == nil then orig[k], changed = now, true end
        if not sp.same(now, v) then sp.write(k, v) end
        if not sp.same(applied[k], v) then applied[k], changed = v, true end
      end
    end
  end
  if changed then
    band.set_ext_json(band.SECTION, sp.STATE, { root = root, orig = orig, applied = applied, yielded = yielded }, true)
    local held = {}
    for k in pairs(applied) do held[#held + 1] = k end
    table.sort(held)
    reaper.SetExtState(band.SECTION, sp.HELD, #held > 0 and (";" .. table.concat(held, ";") .. ";") or "", true)
  end
end
-- This computer's own value: the one saved while the studio's is in, else what's live.
function sp.mine(k)
  local st = band.ext_json(band.SECTION, sp.STATE) or {}
  local o = type(st.orig) == "table" and st.orig[k]
  if o ~= nil and o ~= false then return o end
  return sp.read(k)
end

-- ---- Settings > Studio ------------------------------------------------------------------------------------------------------------------
function sp.words(k, v) -- "0.01 s", "Shape 2"
  local x, n = INFO[k], tonumber(v)
  if not (x and n) then return "not here" end
  if x[2] == "d" then return string.format("%g s", n) end
  if k:find("shape$") then return "Shape " .. (math.floor(n) + 1) end
  return tostring(math.tointeger(n) or n)
end
function sp.studio_ui(ctx, ImGui, cfg, may)
  ImGui.SeparatorText(ctx, "Shared preferences")
  local set = sp.studio(cfg.root)
  ImGui.TextDisabled(ctx, "REAPER preferences that shape recording and editing, the same on every computer while a song of this studio is in front; " ..
    "each computer's own come back after, and when REAPER quits. Never shared: audio device, buffer, latency, paths, theme, layout, zoom, colours.")
  local groups = require("groups")
  for _, x in ipairs(sp.PREFS) do
    local k, on = x[1], set[x[1]] ~= nil
    if may then
      local ch, v = ImGui.Checkbox(ctx, x[3] .. "##sp" .. k, on)
      if ch then
        local mine = sp.mine(k)
        if v and mine == nil then band.msg("This REAPER (or its SWS) doesn't have that setting, so it can't be the studio's from here.")
        else
          set[k] = v and mine or nil
          groups.set_shared_prefs(cfg.root, set)
          band.log((v and "the studio shares " or "the studio no longer shares ") .. x[3] .. (v and (": " .. sp.words(k, mine)) or ""))
        end
      end
    elseif on then ImGui.Text(ctx, x[3]) end
    if on then ImGui.SameLine(ctx); ImGui.TextDisabled(ctx, sp.words(k, set[k])) end
  end
  if may then
    if ImGui.SmallButton(ctx, "Use mine as the studio's##spmine") then
      for k in pairs(set) do local m = sp.mine(k); if m ~= nil then set[k] = m end end
      groups.set_shared_prefs(cfg.root, set)
      band.log("the studio's shared preferences are this computer's own now")
    end
    ImGui.SetItemTooltip(ctx, "Owner and admins. The ticked preferences take this computer's own values (not the studio's that may be in force here).")
  end
end

return sp
