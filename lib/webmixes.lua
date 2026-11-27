-- History > Mixes in the web UI (rt-ui3: docs/rt/ui-web-plan.md 2.5 and Phase 3): the panel's Mixes page (lib/page_restore.lua section_mixes)
-- for any page. Every mix and stems folder with who and when; Render current mix and Export stems / Dry stems (REAPER's Render window, set up
-- for the studio: StudioSync - Final mix.lua, lib/extras.lua); on the idle computers (lib/bounces.lua: stems per track or folder, the mix on
-- the hub, time selection only); Credits draft; Save as studio template; Save a copy outside the studio (lib/export.lua); Compare two mixes
-- (A/B: the same loudness, from the same place, through REAPER's own output with SWS's player, lib/histhear.lua's).
-- What opens a window or plays on this computer (Render, stems, the copy's folder picker, A/B) only from a page on this computer; the idle
-- computers, credits and a template from any. Topic "hmixes", built while a page shows Mixes (it says so every 10 s).
local band = require("band")
local webmixes = {}
webmixes.WANT_FOR = 30
webmixes.BUILD_EVERY = 5
webmixes.LIST_MAX = 60      -- mixes, and stems folders, listed at most (newest first)
webmixes.NAME_MAX = 80      -- a template's name
webmixes.LUFS = -16         -- A/B's common loudness (lib/extras.lua's)

local function scripts_dir() return debug.getinfo(1, "S").source:match("^@?(.*)[/\\]lib[/\\][^/\\]+$") or "." end
local function mixes_dir(cfg, b) return band.song_dir(cfg, b.song) .. "/mixes" end

-- ---- pure ------------------------------------------------------------------------------------------------------------------------------
-- Mix files and stems folders -> rows newest first, at most LIST_MAX each: { name, who, t }. parse: webhome.mix_of / stems_of. Pure.
function webmixes.list(names, parse)
  local out = {}
  for _, n in ipairs(names) do
    local r = parse(n)
    if r then out[#out + 1] = { name = r.name, who = r.user, t = r.time } end
  end
  table.sort(out, function(a, z) return (a.t or 0) > (z.t or 0) or ((a.t or 0) == (z.t or 0) and a.name > z.name) end)
  while #out > webmixes.LIST_MAX do out[#out] = nil end
  return out
end
-- A file a page names: one of the listed mixes exactly, never a path. Pure.
function webmixes.pick(rows, name)
  if type(name) ~= "string" then return nil end
  for _, r in ipairs(rows) do if r.name == name then return name end end
end

-- ---- Live sync's side -------------------------------------------------------------------------------------------------------------------
local S = { want_until = -math.huge, at = -math.huge, gain = {} }
webmixes.S = S -- (tests)
local function rows(cfg, b)
  local webhome = require("webhome")
  return webmixes.list(band.files(mixes_dir(cfg, b)), webhome.mix_of),
    webmixes.list(band.subdirs(band.song_dir(cfg, b.song) .. "/stems"), webhome.stems_of)
end
local HERE_ONLY = { render = true, stems = true, copy = true, ab = true }

-- A page's { mixes = {...} }: { want }, { render = true }, { stems = { dry } }, { bounce = { what = "track" | "folder" | "mix", sel } },
-- { credits = true }, { template = { name } }, { copy = { wav } }, { ab = { play = "a" | "b", a, b } | { stop = true } }. -> words for the log, or nil.
function webmixes.action(proj, cfg, b, a, here)
  if a.want ~= nil then S.want_until = a.want == true and reaper.time_precise() + webmixes.WANT_FOR or -math.huge; return nil end
  S.at = -math.huge
  for k in pairs(HERE_ONLY) do
    if a[k] ~= nil and not here then S.said = "That opens or plays in REAPER on the studio's computer: do it there."; return nil end
  end
  if a.render == true then
    local id = reaper.AddRemoveReaScript(true, 0, scripts_dir() .. "/StudioSync - Final mix.lua", true)
    if id > 0 then reaper.Main_OnCommand(id, 0); S.said = nil else S.said = "Couldn't start Render current mix (is the Scripts folder read-only?)." end
    return nil
  end
  if type(a.stems) == "table" then
    local dry = a.stems.dry == true
    local out, n = require("extras").stems(proj, cfg, b, dry)
    if not out then S.said = tostring(n); return nil end
    S.said = string.format("%d %sstem(s) in %s, for everyone.", n, dry and "dry " or "", out:match("[^/]+/stems/.*$") or out)
    if not dry then
      pcall(function() require("page_chat").post(cfg, b, string.format("Stems for whoever mixes: %d file(s) in the shared folder's %s", n, out:match("[^/]+/stems/.*$") or out)) end)
    end
    return "History page: " .. S.said
  end
  if type(a.bounce) == "table" then
    local what = a.bounce.what
    if what ~= "track" and what ~= "folder" and what ~= "mix" then return nil end
    require("bounces").ask(proj, what, a.bounce.sel == true)
    S.said = "Asked the idle computers: progress shows here and in Health."
    return nil
  end
  if a.credits == true then
    local path = require("extras").credits(cfg, b)
    S.said = "Credits draft written for everyone: " .. (path:match("[^/]+/[^/]+$") or path)
    if here then band.open_url(path) end
    return "History page: " .. S.said
  end
  if type(a.template) == "table" then
    local name = type(a.template.name) == "string" and require("webui").clean_text(a.template.name)
    if not name or #name > webmixes.NAME_MAX then S.said = "Give the template a name (up to 80 letters)."; return nil end
    local path, why = require("extras").save_template(proj, cfg, name)
    S.said = path and ("Saved '" .. name .. "' as a template for everyone in the studio: Studio > New from template.") or tostring(why)
    return path and "History page: " .. S.said or nil
  end
  if type(a.copy) == "table" then
    local file = require("export").ask(proj, b.song, a.copy.wav == true) -- (its folder picker, then the copy: lib/export.lua)
    S.said = file and ("Saved a plain copy: " .. file) or nil
    return nil
  end
  if type(a.ab) == "table" then
    local histhear = require("histhear")
    if a.ab.stop == true then histhear.rp_stop(); return nil end
    if not histhear.rp_can() then S.said = "Comparing mixes needs SWS (Extensions > ReaPack, or sws-extension.org)."; return nil end
    local side = a.ab.play == "b" and "b" or "a"
    local mixes = rows(cfg, b)
    S.a, S.b = webmixes.pick(mixes, a.ab.a) or S.a, webmixes.pick(mixes, a.ab.b) or S.b
    local file = S[side]
    if not file then S.said = "Pick the two mixes first."; return nil end
    local path = mixes_dir(cfg, b) .. "/" .. file
    if not S.gain[path] then -- (measured once a file: it reads the whole render)
      local src = reaper.PCM_Source_CreateFromFile(path)
      S.gain[path] = src and reaper.CalculateNormalization(src, 0, webmixes.LUFS, 0, 0) or 1
      if src then reaper.PCM_Source_Destroy(src) end
    end
    local P = histhear.P
    local pos = (P.key == "a" or P.key == "b") and histhear.rp_pos() or 0 -- (switching keeps the place: what A/B is for)
    local why = histhear.rp_play(path, pos, side, S.gain[path])
    S.said = why and ("Couldn't play it: " .. why .. ".") or nil
    return nil
  end
end

function webmixes.tick(proj, cfg, b, publish, now)
  local key = b.song .. "/" .. b.room
  if S.key ~= key then S.key, S.a, S.b, S.said, S.at = key, nil, nil, nil, -math.huge end
  if now >= S.want_until then return end
  local histhear = require("histhear")
  local rp = histhear.rp_model()
  local playing = rp and (rp.key == "a" or rp.key == "b") and rp or nil
  local on = playing and playing.on
  if not on and not S.was_on and now - S.at < webmixes.BUILD_EVERY then return end -- (playing: where it is, every tick; and once as it stops)
  S.was_on = on
  if now - S.at >= webmixes.BUILD_EVERY then S.at, S.mixes, S.stems = now, rows(cfg, b) end
  local ok, line = pcall(require("bounces").panel_line, cfg)
  publish("hmixes", { key = key, mixes = S.mixes, stems = S.stems, bounce = ok and line or nil, sws = histhear.rp_can() or nil,
    ab = { a = S.a, b = S.b, play = playing and playing.key or nil, pos = playing and playing.pos or nil, len = playing and playing.len or nil,
      on = playing and playing.on or nil }, said = S.said })
end

return webmixes
