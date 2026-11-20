-- Presets and small content (docs/realtime-roadmap.md, rt): the files a song's plug-ins load or show that are yours to pass on (an impulse
-- response, an amp capture or model, a preset) go to the bandmates who need them for the song; never a program, never a paid library.
-- The carrying was lib/fxfiles.lua's already: copied into the room's "plugin files/", sent over the link at once where the extension takes
-- the kind (lib/streams.lua offer_media), by Syncthing anyway, and put back where the plug-in looks. This adds:
--   - the rules for what may leave this computer (content.allowed: a list of kinds, a size cap, never anything inside a paid library's or
--     a program's folder), and the studio's switch for it (band.json "content", owner and admins, on unless false);
--   - presets: the VST3 preset REAPER shows for a plug-in (TrackFX_GetPreset gives its .vstpreset file's path) goes too, from your own preset
--     folder only, and lands in the bandmate's own preset folder (VST3's documented places: Documents/VST3 Presets on Windows,
--     ~/Library/Audio/Presets on a Mac, ~/.vst3/presets on Linux, then <vendor>/<plug-in>/...), where their REAPER's preset list finds it;
--     an AU preset (.aupreset, ~/Library/Audio/Presets) from Mac to Mac the same way;
--   - Health: who lacks which of the song's files (lib/libraries.lua's reports).
-- What it can't do: a plug-in's state is its own binary and is never rewritten, so an IR or a capture reaches a bandmate's plug-in only where
-- the same path can exist there (fxfiles.fetch); elsewhere the copy waits in "plugin files/" and the log says which plug-in wants it.
-- REAPER's own presets (presets/*.ini, one file per plug-in holding all of a person's presets) aren't sent: the chain carries the sound itself,
-- and writing into a bandmate's file would mean merging theirs. Drum maps: StudioSync's are in the shared folder already (lib/drummap.lua),
-- and REAPER's note names travel in the track.
local band = require("band")
local content = { MAX = 64 * 1024 * 1024 } -- (bigger isn't small content: a sampler's part that needs it prints instead, lib/libraries.lua)
content.PRESET = { vstpreset = true, aupreset = true, fxp = true, fxb = true }
-- Never, whatever list a kind is on: programs, plug-ins themselves, installers, scripts.
content.NEVER = {}
for e in ("dll vst vst3 component clap aaxplugin so dylib exe app bundle msi pkg dmg lua eel jsfx py sh bat cmd ps1 js vbs reg scpt command"):gmatch("%S+") do content.NEVER[e] = true end
-- Folders a paid library or a program lives in, by a whole word in a folder's name (a sampler vendor's installs, sample stores,
-- Program Files): nothing in one leaves this computer. (shortcut: by name; a library installed under a folder of the user's own naming is only
-- caught by its kind, which is the sampler's own format and not on the list. A library marker file (.nicnt) would catch more)
content.PAID = { "native instruments", "kontakt", "komplete", "toontrack", "superior drummer", "ezdrummer", "ezkeys", "ezbass", "spitfire",
  "xln audio", "addictive drums", "addictive keys", "fxpansion", "bfd2", "bfd3", "ik multimedia", "sampletank", "eastwest", "east west",
  "vienna symphonic", "orchestral tools", "heavyocity", "8dio", "cinesamples", "embertone", "soundiron", "impact soundworks", "best service",
  "ueberschall", "halion", "splice", "loopmasters", "program files", "common files", "applications" }

local function ext_of(p) return (tostring(p or ""):match("%.(%w+)$") or ""):lower() end
local function key(p) return require("fxfiles").key(p) end

-- ---- pure ----------------------------------------------------------------------------------------------------------------------------
-- "preset", "file" (a kind lib/fxfiles.lua carries: samples, IRs, captures and models) or nil. Pure.
function content.kind(path)
  local e = ext_of(path)
  if content.NEVER[e] then return nil end
  if content.PRESET[e] then return "preset" end
  return require("fxfiles").EXT[e] and "file" or nil
end
-- Is the file inside a paid library's or a program's folder (content.PAID, a folder's name only, not the file's)? Pure.
function content.paid(path)
  local segs = {}
  for s in tostring(path or ""):gsub("\\", "/"):lower():gmatch("[^/]+") do segs[#segs + 1] = s end
  for k = 1, #segs - 1 do
    for _, w in ipairs(content.PAID) do
      local a = segs[k]:find(w, 1, true)
      if a and (a == 1 or not segs[k]:sub(a - 1, a - 1):match("%w")) and not segs[k]:sub(a + #w, a + #w):match("%a") then return true end
    end
  end
  return false
end
-- May this file go to bandmates: a kind on the list, never a program, at most MAX bytes, not in a paid library's folder. Pure.
function content.allowed(path, size)
  if not content.kind(path) then return false end
  if type(size) ~= "number" or size < 0 or size > content.MAX then return false end
  return not content.paid(path)
end
-- A preset in a person's own preset folder -> its place there ("<vendor>/<plug-in>/<preset>.vstpreset", sub-folders allowed), else nil.
-- Only under a home folder: the factory presets in ProgramData or /Library are the vendor's, never sent. Each part a plain name (nothing
-- climbing out, nothing hidden). Pure.
content.ANCHORS = { "/vst3 presets/", "/library/audio/presets/", "/.vst3/presets/" }
function content.preset_tail(path)
  local p = tostring(path or ""):gsub("\\", "/")
  local e = ext_of(p)
  if e ~= "vstpreset" and e ~= "aupreset" then return nil end
  local low = p:lower()
  if not (low:match("^%a:/users/[^/]+/") or low:match("^/users/[^/]+/") or low:match("^/home/[^/]+/")) then return nil end
  for _, a in ipairs(content.ANCHORS) do
    local _, z = low:find(a, 1, true)
    if z then
      local tail, n = p:sub(z + 1), 0
      for seg in tail:gmatch("[^/]*") do
        if seg ~= "" then n = n + 1; if not require("direct").plain(seg) or seg == ".." then return nil end end
      end
      return n >= 3 and n <= 6 and not tail:find("//", 1, true) and tail or nil
    end
  end
end
-- This computer's preset folder for a preset of kind `e`: o (plugins.system's "win", "mac", "linux"), home (its home folder, "/"),
-- exists(dir) -> whether a folder is there (Windows: Documents, or OneDrive's Documents when only that has one). nil: no such place here
-- (an AU preset off a Mac). Pure but for `exists`.
-- (shortcut: Documents found by name, not by Windows' known-folder lookup; a Documents moved elsewhere gets a VST3 Presets folder in the usual
-- place, which REAPER may not look in)
function content.preset_dir(e, o, home, exists)
  if not home or home == "" then return nil end
  home = home:gsub("\\", "/"):gsub("/+$", "")
  if e == "aupreset" then return o == "mac" and home .. "/Library/Audio/Presets" or nil end
  if e ~= "vstpreset" then return nil end
  if o == "win" then
    local one = home .. "/OneDrive/Documents/VST3 Presets"
    if exists and not exists(home .. "/Documents/VST3 Presets") and exists(one) then return one end
    return home .. "/Documents/VST3 Presets"
  end
  return o == "mac" and home .. "/Library/Audio/Presets" or home .. "/.vst3/presets"
end
-- A room's media folder (<root>/<song>/rooms/<room>/media) -> the studio's folder. Pure.
function content.root_of(media_dir) return (tostring(media_dir or ""):gsub("\\", "/"):match("^(.*)/[^/]+/rooms/[^/]+/media/?$")) end

-- ---- this computer ---------------------------------------------------------------------------------------------------------------------
function content.on(root)
  local ok, t = pcall(function() return require("groups").trusted(root) end)
  return not (ok and type(t) == "table" and t.content == false)
end
function content.set(root, on) return require("groups").edit(root, function(j) if on then j.content = nil else j.content = false end end) end
local function exists_dir(d) return reaper.EnumerateSubdirectories(d, 0) ~= nil or reaper.EnumerateFiles(d, 0) ~= nil end
function content.my_preset_dir(e)
  return content.preset_dir(e, require("plugins").system(reaper.GetOS()), os.getenv(band.WIN and "USERPROFILE" or "HOME"), exists_dir)
end
-- An id for lib/libraries.lua's reports: a preset's by its place in the preset folder (the same preset sits under each person's own home),
-- anything else's by its path.
function content.id(path)
  local tail = content.preset_tail(path)
  return tail and require("mirror").hash("preset:" .. tail:lower()) or require("libraries").id(path)
end
-- Has this computer the file: where the plug-in looks, or for a preset, in its own preset folder.
function content.here(path)
  if reaper.file_exists(path) then return true end
  local tail, d = content.preset_tail(path), nil
  d = tail and content.my_preset_dir(ext_of(path))
  return d ~= nil and reaper.file_exists(d .. "/" .. tail)
end
-- Presets placed here from a bandmate this session (fxfiles.key): never offered back from here.
content.placed = {}
-- lib/fxfiles.lua share's gate, for each file it would copy out: allowed, the studio's switch on, and not a preset a bandmate gave us.
function content.may_send(path, size, media_dir)
  if content.placed[key(path)] or not content.allowed(path, size) then return false end
  local root = content.root_of(media_dir)
  return not root or content.on(root)
end
-- The sender, as a track's chain goes out (lib/mirror.lua): the presets REAPER shows on it that are files in your own preset folder, as lines
-- added to the text fxfiles.share looks through (never to the event itself). "" when there are none, or the studio has it off.
function content.preset_text(tr, media_dir)
  if not tr or not reaper.ValidatePtr(tr, "MediaTrack*") then return "" end
  local root = content.root_of(media_dir)
  if root and not content.on(root) then return "" end
  local out = {}
  for _, i in ipairs(require("prints").fx_all(tr)) do
    local _, p = reaper.TrackFX_GetPreset(tr, i)
    if content.preset_tail(p) and reaper.file_exists(p) then out[#out + 1] = p end
  end
  return #out > 0 and ("\n" .. table.concat(out, "\n") .. "\n") or ""
end
-- The receiver, before the chain loads (fxfiles.fetch): each preset in the event's files goes to this computer's own preset folder, at its
-- place there, if it isn't there already. -> set of the entries' paths that were presets (fxfiles.fetch leaves those alone: it would make
-- the bandmate's own home folder here).
function content.fetch(list, media_dir)
  local done = {}
  for _, f in ipairs(type(list) == "table" and list or {}) do
    local tail = type(f) == "table" and type(f.copy) == "string" and content.preset_tail(f.path)
    if tail then
      done[f.path] = true
      local d = content.my_preset_dir(ext_of(f.path))
      local dst, src = d and (d .. "/" .. tail), media_dir .. "/" .. f.copy
      -- (the copy from plugin files/ itself, as fxfiles.safe asks: no other folder, no "..")
      local ok = dst and f.copy:match("^plugin files/[^/\\]+$") and not f.copy:find("..", 1, true)
      if ok and not reaper.file_exists(dst) and reaper.file_exists(src) and (band.size(src) or math.huge) <= content.MAX then
        reaper.RecursiveCreateDirectory(dst:match("^(.*)/[^/]+$"), 0)
        pcall(band.copy_atomic, src, dst)
        if reaper.file_exists(dst) then
          content.placed[key(dst)] = true
          band.log("a bandmate's preset for the project is in your preset list now: " .. tail)
        end
      end
    end
  end
  return done
end

-- Health's rows: the switch, then who lacks what (lib/libraries.lua).
function content.health_rows(cfg)
  local on = content.on(cfg.root)
  local rows = { { "content", true, "grey", on and ("Presets and small content: on. Presets, IRs and captures this project's plug-ins load go to bandmates " ..
    "who need them (up to " .. math.floor(content.MAX / 1048576) .. " MB each; never programs, nor anything in a paid library's folder).") or
    "Presets and small content: off for the studio. Files plug-ins load stay on each computer; a sampler's part someone lacks the sounds for still prints.", "" } }
  local ok, row = pcall(require("libraries").health_row, cfg)
  if ok and row then rows[#rows + 1] = row end
  return rows
end
-- Settings > Studio: the switch (owner and admins).
function content.studio_ui(ctx, ImGui, cfg, may)
  ImGui.SeparatorText(ctx, "Presets and small content")
  local on = content.on(cfg.root)
  ImGui.TextDisabled(ctx, on and ("On: a preset, impulse response, amp capture or model a project's plug-in loads goes to the bandmates who lack it, " ..
    "into their own preset folder, or where the plug-in looks when that folder can exist on their computer. Small files only; never a program " ..
    "or anything from a paid library.") or "Off: files plug-ins load stay on each computer. A sampler's part someone lacks the sounds for still prints.")
  if may then
    local ch, v = ImGui.Checkbox(ctx, "Send presets and small content##studiocontent", on)
    if ch then
      content.set(cfg.root, v)
      band.log(v and "presets and small content go to bandmates who need them again (Settings > Studio)" or "presets and small content stay on each computer from now on (Settings > Studio)")
    end
    ImGui.SetItemTooltip(ctx, "Owner and admins. Kinds: presets (.vstpreset, .aupreset, .fxp, .fxb), IRs and samples, NAM and AIDA-X captures, SFZ and SoundFonts.\n" ..
      "Up to " .. math.floor(content.MAX / 1048576) .. " MB each. Never .dll, .vst3, .component, .so, .exe or other programs, nor anything in a sample vendor's or Program Files folder.")
  end
end

return content
