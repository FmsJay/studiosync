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
  -- Colour: how the same project colours look (James, rt: "everyone should share the same colors for tracks and everything"). They were
  -- "never shared" as personal look; colour parity moves them to shared, while theme choice, layout and zoom stay each person's own. In force
  -- only while the studio's Colour parity is on (sp.studio). Names from REAPER 7.79's config table (reaper.exe) and Mespotine's reference:
  -- tinttcp's bits are the track label background, tinting track panels, tinting item peaks and backgrounds by track/item/take colour, and
  -- auto-colouring new takes and pooled MIDI items (Preferences > Track Control Panels and > Peaks/Waveforms). `differs`: Health's words.
  { "tinttcp", "i", "Track colours: tint track panels, labels and items (and colour new takes)", group = "colour", differs = "tints track panels and items differently" },
  { "selitem_tintalpha", "i", "Tint strength of selected items", group = "colour", differs = "tints selected items more or less strongly" },
  { "unselitem_tintalpha", "i", "Tint strength of unselected items", group = "colour", differs = "tints unselected items more or less strongly" },
  { "specpeak_huel", "d", "Spectral peaks: colour at the low end", group = "colour", differs = "draws spectral peaks in other colours" },
  { "specpeak_hueh", "d", "Spectral peaks: colour at the high end", group = "colour", differs = "draws spectral peaks in other colours" },
}
-- Never shared, whatever band.json says: this computer's own (as ReaPersona's PREF_HERE, plus the look). A key on the list above can't match.
-- ("colou?r" stays: a colour pref only ever comes from the list above, which names none that matches it. James, rt)
sp.NEVER = { "^audio", "^asio", "^wasapi", "^dsound", "^coreaudio", "^alsa", "^jack", "^pulse", "^ks_", "bsize", "bufsize", "latency", "lat[io][nu]t?$",
  "^midiins", "^midiouts", "^midilat", "path", "dir$", "theme", "colou?r", "zoom", "layout", "font", "uiscale", "^dock", "wnd", "_vis$", "_dock$",
  "workthreads", "renderthreads" }
local INFO = {}
for _, x in ipairs(sp.PREFS) do INFO[x[1]] = x end
function sp.info(k)
  if tostring(k):sub(1, 6) == "theme:" then return { k, "t", "the theme's " .. k:sub(7), group = "colour", differs = "sets the theme's " .. k:sub(7) .. " differently" } end
  return INFO[k]
end
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
-- What the owner chose (band.json), colour ones included whether or not Colour parity is on: what Settings > Studio shows and saves.
function sp.chosen(root) return sp.clean(require("groups").trusted(root).shared_prefs) end

-- ---- the theme's colour settings ------------------------------------------------------------------------------------------------------
-- A theme's parameters (WALTER define_parameter, ThemeLayout_GetParameter) are that theme's own names, so the studio's are shared only with a
-- computer on the same theme, and only the ones about how track colours show: tint strengths, coloured names, custom colour strength (not
-- panel background colours, which are the theme's look). Set with persist off: reaper-themeconfig.ini is never written, so a crash or quit
-- leaves the theme as it was. (James, rt)
-- "J:/x/Reapertips Theme.ReaperThemeZip" -> "reapertips theme". Pure.
function sp.theme_name(path)
  local n = tostring(path or ""):match("([^/\\]+)$") or ""
  return (n:gsub("%.[Rr]eaper[Tt]heme[Zz]?[Ii]?[Pp]?$", ""):lower())
end
-- Is a theme parameter about how track colours show? `cfg`: its name, `desc`: its description. Pure.
function sp.theme_colour_param(cfg, desc)
  local t = (tostring(cfg or "") .. " " .. tostring(desc or "")):lower()
  return t:find("tint") ~= nil or t:find("custom ?colou?r") ~= nil or t:find("colou?red") ~= nil
end
-- band.json's theme_colours made safe (pure): a theme name and colour parameters with whole-number values, or nil.
function sp.theme_clean(t)
  if type(t) ~= "table" or type(t.theme) ~= "string" or t.theme == "" or type(t.params) ~= "table" then return nil end
  local out, n = {}, 0
  for k, v in pairs(t.params) do
    local x = math.tointeger(tonumber(v))
    if type(k) == "string" and k:match("^[%w_]+$") and #k < 64 and sp.theme_colour_param(k, "") and x and math.abs(x) < 1e6 then out[k], n = x, n + 1 end
  end
  return n > 0 and { theme = sp.theme_name(t.theme), params = out } or nil
end
local tp = { at = -math.huge }
-- This REAPER's theme colour parameters: cfg -> { idx, value, desc }, and its theme's name. Looked up again every 5 s or when the theme changes.
function sp.theme_params()
  local path = reaper.GetLastColorThemeFile and reaper.GetLastColorThemeFile() or ""
  local t = reaper.time_precise()
  if tp.path == path and t - tp.at < 5 and t >= tp.at then return tp.map, sp.theme_name(path) end
  local map = {}
  if reaper.ThemeLayout_GetParameter then
    for i = 0, 2000 do
      local cfg, desc, val = reaper.ThemeLayout_GetParameter(i)
      if cfg == nil or cfg == "" then break end
      if sp.theme_colour_param(cfg, desc) and math.tointeger(tonumber(val)) then map[cfg] = { i, math.tointeger(tonumber(val)), desc } end
    end
  end
  tp.at, tp.path, tp.map = t, path, map
  return map, sp.theme_name(path)
end

-- What's in force for the studio (pure but for reading band.json and this REAPER's theme): its chosen preferences, the colour ones only
-- while Colour parity is on, and then the theme's colour settings too where this computer uses the same theme ("theme:<cfg>" keys).
function sp.studio(root)
  local groups = require("groups")
  local out = sp.chosen(root)
  if not groups.colour_parity(root) then
    for k in pairs(out) do if INFO[k].group == "colour" then out[k] = nil end end
  else
    local tc = sp.theme_clean(groups.trusted(root).theme_colours)
    if tc then
      local have, mine = sp.theme_params()
      if mine == tc.theme then for k, v in pairs(tc.params) do if have[k] then out["theme:" .. k] = v end end end
    end
  end
  return out
end

-- ---- this REAPER's live values --------------------------------------------------------------------------------------------------------
local NO1, NO2 = -2147480001, -2147480002 -- (two error values: SWS answers its error value for a name it doesn't know or a size it won't read)
function sp.read(k)
  if tostring(k):sub(1, 6) == "theme:" then local p = sp.theme_params()[k:sub(7)]; return p and p[2] end
  local x = INFO[k]
  if not x then return nil end
  local get = x[2] == "d" and reaper.SNM_GetDoubleConfigVar or reaper.SNM_GetIntConfigVar
  if not get then return nil end
  local a = get(k, NO1)
  if type(a) ~= "number" or a ~= get(k, NO2) then return nil end -- (not here, or not that size: left alone)
  return a
end
function sp.write(k, v)
  if tostring(k):sub(1, 6) == "theme:" then
    local p, n = sp.theme_params()[k:sub(7)], math.tointeger(tonumber(v))
    if not (p and n and reaper.ThemeLayout_SetParameter) then return false end
    local ok = reaper.ThemeLayout_SetParameter(p[1], n, false) -- (persist off: reaper-themeconfig.ini keeps the person's own)
    p[2] = n
    if reaper.ThemeLayout_RefreshAll then reaper.ThemeLayout_RefreshAll() end
    return ok
  end
  local x = INFO[k]
  if not x or sp.read(k) == nil then return false end -- (only what reads back in its size is ever set)
  local ok
  if x[2] == "d" then ok = reaper.SNM_SetDoubleConfigVar(k, tonumber(v))
  else
    local n = math.tointeger(tonumber(v))
    ok = n ~= nil and reaper.SNM_SetIntConfigVar(k, n)
  end
  if ok and x.group == "colour" then reaper.UpdateArrange(); reaper.TrackList_AdjustWindows(false) end -- (seen at once, not at the next redraw)
  return ok
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
        band.log("you changed " .. (sp.info(k)[3]) .. " while the studio's was in: yours stands, and isn't put back")
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
  if x[2] == "d" then return string.format(x.group == "colour" and "%g" or "%g s", n) end
  if k:find("shape$") then return "Shape " .. (math.floor(n) + 1) end
  return tostring(math.tointeger(n) or n)
end
-- The ticks for one group of the list (nil: recording and editing; "colour": Colour parity's card, lib/colours.lua parity_ui).
function sp.rows_ui(ctx, ImGui, cfg, may, group)
  local set, groups = sp.chosen(cfg.root), require("groups")
  for _, x in ipairs(sp.PREFS) do
    local k, on = x[1], set[x[1]] ~= nil
    if x.group == group then
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
  end
  if may then
    if ImGui.SmallButton(ctx, "Use mine as the studio's##spmine" .. (group or "")) then
      for k in pairs(set) do local m = sp.mine(k); if m ~= nil and INFO[k].group == group then set[k] = m end end
      groups.set_shared_prefs(cfg.root, set)
      band.log("the studio's shared preferences are this computer's own now")
    end
    ImGui.SetItemTooltip(ctx, "Owner and admins. The ticked preferences take this computer's own values (not the studio's that may be in force here).")
  end
end
function sp.studio_ui(ctx, ImGui, cfg, may)
  ImGui.SeparatorText(ctx, "Shared preferences")
  ImGui.TextDisabled(ctx, "REAPER preferences that shape recording and editing, the same on every computer while a song of this studio is in front; " ..
    "each computer's own come back after, and when REAPER quits. Never shared: audio device, buffer, latency, paths, theme, layout, zoom. " ..
    "Colour settings: under Colour parity.")
  sp.rows_ui(ctx, ImGui, cfg, may, nil)
end

return sp
