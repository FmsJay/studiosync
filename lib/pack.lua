-- The studio's plug-in pack and its extras, from inside StudioSync (James, 0.59.22: "maybe have some sort of link or installer for these
-- in another tab"). What this computer has of them, what others in the studio have that it doesn't, and Get: the installer of this very
-- release, in plug-ins-only mode (install_windows.ps1 -PluginsOnly, install_mac.sh / install_linux.sh BS_PLUGINS_ONLY=1), in a window of
-- its own, where Windows' permission box or the Mac's password can be answered. The installers keep the real list and how each installs;
-- this one only names them, to say what's here.
local band = require("band")
local plugins = require("plugins")
local pack = {}

-- name, what it is, the start of its plug-in key (plugins.key: "surge xt (surge synth team)"), extra
pack.ITEMS = {
  { "Surge XT", "synth and effects", "surge xt (" },
  { "Dexed", "FM synth", "dexed (" },
  { "OB-Xf", "Oberheim-style poly synth", "ob-xf" },
  { "Airwindows Consolidated", "hundreds of effects", "airwindows consolidated" },
  { "Dragonfly Reverb", "rooms, halls, plates", "dragonfly " },
  { "Chow Tape Model", "tape", "chowtapemodel" },
  { "BYOD", "guitar and bass amps, tuner", "byod (" },
  { "ZL Equalizer 2", "EQ", "zl equalizer" },
  { "ZL Compressor", "compressor", "zl compressor" },
  { "ChowMatrix", "delay", "chowmatrix" },
  { "CloudReverb", "ambient reverb", "cloudreverb" },
  { "Neural Amp Modeler", "amp captures", "neuralampmodeler", true },
  { "AIDA-X", "amp captures", "aida-x", true },
  { "Odin 2", "synth", "odin2", true },
  { "SnapTune", "vocal tuning", "snaptune", true },
  { "JC303", "303 bass", "jc303", true },
  { "RipplerX", "mallets, bells, plucks", "ripplerx", true },
  { "Monique", "mono synth", "monique", true },
  { "sforzando", "plays the piano and drum kit", "sforzando", true },
}

-- Is item `it` in a set of plug-in keys? Pure.
function pack.has(keys, it)
  for k in pairs(keys) do if k:sub(1, #it[3]) == it[3] then return true end end
  return false
end

-- -> { pack = {have, total, missing = {names}}, extras = {...}, others = { name -> {who} } (what bandmates have that this computer
-- doesn't) }. Looked at every 10 s: REAPER's plug-in list is long.
local cached, cached_at, cached_root = nil, -math.huge, nil
function pack.status(cfg)
  if cached and reaper.time_precise() - cached_at < 10 and cached_root == (cfg and cfg.root) then return cached end
  local mine = {}
  for _, p in ipairs(plugins.installed()) do mine[plugins.key(p.name)] = true end
  local lists = {}
  if cfg and cfg.root then
    local ok, l = pcall(plugins.lists, cfg)
    if ok then for _, x in ipairs(l) do if x.user ~= cfg.user then
      local set = {}
      for _, k in ipairs(x.names) do set[k] = true end
      lists[#lists + 1] = { user = x.user, set = set }
    end end end
  end
  local s = { pack = { have = 0, total = 0, missing = {} }, extras = { have = 0, total = 0, missing = {} }, others = {}, here = {} }
  for _, it in ipairs(pack.ITEMS) do
    local g = it[4] and s.extras or s.pack
    g.total = g.total + 1
    if pack.has(mine, it) then g.have, s.here[it[1]] = g.have + 1, true
    else
      g.missing[#g.missing + 1] = it[1]
      for _, l in ipairs(lists) do
        if pack.has(l.set, it) then s.others[it[1]] = s.others[it[1]] or {}; table.insert(s.others[it[1]], l.user) end
      end
    end
  end
  cached, cached_at, cached_root = s, reaper.time_precise(), cfg and cfg.root
  return s
end
function pack.forget() cached = nil end

-- The installer of this release (its tag: what's run is what was released, as an invitation's line is. services.invite_text)
local function base() return "https://raw.githubusercontent.com/FmsJay/studiosync/v" .. band.VERSION .. "/installer/" end

-- The script that gets them, for this system. `extras`: the extras too. `test` (Windows): the installer's own no-installs run (-NoApps).
-- -> file name, its text. Pure but for REAPER's resource folder.
function pack.script(extras, test)
  local res = reaper.GetResourcePath()
  if band.WIN then
    local ps = function(s) return "'" .. s:gsub("'", "''") .. "'" end -- (inside PowerShell's single quotes)
    local cmd = function(s) return (s:gsub("%%", "%%%%")) end -- (a % in a .cmd file is a variable)
    local line = "$ProgressPreference='SilentlyContinue'; $f=Join-Path $env:TEMP 'studiosync_plugins.ps1'; " ..
      "try { iwr -UseBasicParsing " .. ps(base() .. "install_windows.ps1") .. " -OutFile $f } catch { Write-Host ('The installer did not download: ' + $_); Read-Host 'Press Enter to close'; exit 1 }; " ..
      "& $f -PluginsOnly -ResPath " .. ps(res:gsub("/", "\\")) .. " -Extras " .. (extras and "yes" or "no") .. (test and " -NoApps" or "")
    return "Get plug-ins.cmd", table.concat({ "@echo off", "chcp 65001 >nul", "title StudioSync: plug-ins",
      'powershell -NoProfile -ExecutionPolicy Bypass -Command "' .. cmd(line) .. '"', '(goto) 2>nul & del "%~f0"', "" }, "\r\n")
  end
  local sh = function(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
  local name = band.MAC and "install_mac.sh" or "install_linux.sh"
  return band.MAC and "Get plug-ins.command" or "get-plugins.sh", table.concat({ "#!/bin/bash", "cd \"$HOME\"",
    "curl -fsSL " .. sh(base() .. name) .. " | BS_PLUGINS_ONLY=1 BS_EXTRAS=" .. (extras and "y" or "n") .. " bash",
    "echo", "read -r -p 'Press Return to close this window. ' _ </dev/tty", "rm -f \"$0\"", "" }, "\n")
end

-- Opens it in a window of its own. -> true, or false and why.
function pack.get(extras)
  local name, text = pack.script(extras)
  local path = band.home() .. "/" .. name
  local ok, err = pcall(band.write_atomic, path, text)
  if not ok then return false, "couldn't write " .. path .. ": " .. tostring(err) end
  pack.forget()
  if band.WIN or band.MAC then
    if band.MAC then os.execute("chmod +x '" .. path:gsub("'", "'\\''") .. "'") end
    band.open_url(path) -- (a .cmd runs in a console window; a .command opens in Terminal)
    return true
  end
  -- Linux: the first terminal there is
  local q = "'" .. path:gsub("'", "'\\''") .. "'"
  os.execute("chmod +x " .. q)
  local run = "(command -v gnome-terminal >/dev/null && gnome-terminal -- bash " .. q .. ") || (command -v konsole >/dev/null && konsole -e bash " .. q ..
    ") || (command -v xfce4-terminal >/dev/null && xfce4-terminal -x bash " .. q .. ") || (command -v x-terminal-emulator >/dev/null && x-terminal-emulator -e bash " .. q ..
    ") || (command -v xterm >/dev/null && xterm -e bash " .. q .. ")"
  if os.execute(run .. " >/dev/null 2>&1 &") then return true end
  return false, "no terminal found: run " .. path .. " in one"
end

-- The section: on Settings > Plug-ins and the Plugins page.
local said
function pack.draw(ctx, ImGui, cfg)
  local s = pack.status(cfg)
  ImGui.PushTextWrapPos(ctx, 0)
  ImGui.TextDisabled(ctx, "Free, open-source plug-ins, each from its maker's own release, so a part made with one plays and can be changed on every " ..
    "computer in the studio. Get opens StudioSync's installer in a window of its own: only the plug-ins, nothing else.")
  local function row(label, g, extras)
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, string.format("%s: %d of %d here", label, g.have, g.total))
    if #g.missing > 0 then ImGui.SetItemTooltip(ctx, "Not here: " .. table.concat(g.missing, ", ")) end
    ImGui.SameLine(ctx)
    if #g.missing == 0 and (not extras or #s.pack.missing == 0) then ImGui.TextDisabled(ctx, "all here")
    elseif ImGui.Button(ctx, extras and "Get the extras" or "Get the pack") then
      local ok, why = pack.get(extras)
      said = ok and ("The installer opened in its own window" .. (band.WIN and " (Windows asks for permission once)" or band.MAC and " (it may ask for your Mac password)" or "") ..
        ". When it's done, restart REAPER.") or why
      band.log(said)
    end
    if extras then ImGui.SetItemTooltip(ctx, "The extras, and whatever of the pack isn't here. About 1.3 GB, most of it a grand piano and a drum kit.") end
  end
  row("Plug-in pack", s.pack, false)
  row("Extras", s.extras, true)
  local lack = {}
  for _, it in ipairs(pack.ITEMS) do if s.others[it[1]] then lack[#lack + 1] = it[1] .. " (" .. table.concat(s.others[it[1]], ", ") .. ")" end end
  if #lack > 0 then
    ImGui.TextColored(ctx, require("theme").YELLOW, "Others in the studio have " .. table.concat(lack, ", ") .. ". Without them you hear those parts, " ..
      "but can't play or change them.")
  end
  if said then ImGui.TextDisabled(ctx, said) end
  if ImGui.TreeNode(ctx, "What's in them") then
    for _, it in ipairs(pack.ITEMS) do
      ImGui.Text(ctx, (s.here[it[1]] and "  here   " or "  -      ") .. it[1])
      ImGui.SameLine(ctx); ImGui.TextDisabled(ctx, it[2] .. (it[4] and " (extras)" or ""))
    end
    ImGui.TreePop(ctx)
  end
  ImGui.PopTextWrapPos(ctx)
end

return pack
