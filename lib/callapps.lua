-- Call apps beside REAPER (James, 0.58.79: "there might be issues with using Discord and other call apps with something like REAPER
-- running"). On Windows, REAPER on ASIO (or WASAPI exclusive) holds the audio interface for itself, and most ASIO drivers then refuse
-- anyone else: Discord loses its microphone or its sound, or takes the interface back and REAPER goes silent. On a Mac Core Audio shares
-- the interface, so the usual trouble there is the call's echo cancelling and noise suppression chewing up the music, and the music
-- going out twice when Real time mode carries it too.
-- What StudioSync does about it: says so in Health when a call app runs beside REAPER this way (one background process list every
-- 20 s), and gives the ways round it in Settings > Advanced > Calls, the first being to talk through StudioSync itself (Real time mode's
-- Talk), which goes through REAPER's own audio, so there's nothing to fight over.
local band = require("band")
local callapps = {}

-- { name, Windows process, macOS process }
callapps.APPS = { { "Discord", "discord.exe", "Discord" }, { "Zoom", "zoom.exe", "zoom.us" }, { "Teams", "ms-teams.exe", "MSTeams" },
  { "Teams", "teams.exe", "Microsoft Teams" }, { "Skype", "skype.exe", "Skype" }, { "Slack", "slack.exe", "Slack" },
  { "WhatsApp", "whatsapp.exe", "WhatsApp" }, { "FaceTime", nil, "FaceTime" }, { "Google Meet", nil, nil } }

-- The call apps in a process list (`tasklist /FO CSV /NH` on Windows, `ps -axco command` on a Mac or Linux, with a line
-- break before and after). -> names, sorted. Pure.
function callapps.in_list(text, win)
  local found, seen = {}, {}
  local lower = (text or ""):lower()
  for _, a in ipairs(callapps.APPS) do
    local exe = win and a[2] or a[3]
    if exe and not seen[a[1]] then
      local hit = win and lower:find('"' .. exe:lower() .. '"', 1, true) or not win and lower:find("\n" .. exe:lower() .. "\n", 1, true)
      if hit then seen[a[1]] = true; found[#found + 1] = a[1] end
    end
  end
  table.sort(found)
  return found
end

-- Does REAPER's audio mode keep the interface to itself? `mode`: GetAudioDeviceInfo("MODE") ("ASIO", "WASAPI", "WaveOut", "CoreAudio",
-- "JACK"...); `exclusive`: WASAPI's exclusive mode is on. Pure.
function callapps.holds_device(mode, win, exclusive)
  mode = (mode or ""):upper()
  if not win then return false end
  if mode:find("ASIO", 1, true) then return true end
  return mode:find("WASAPI", 1, true) ~= nil and exclusive == true
end

-- The call apps running now (from the last background look: up to 20 s old). -> names.
function callapps.running()
  local services = require("services")
  local out = services.background("callapps", band.WIN and "tasklist /FO CSV /NH" or "ps -axco command", 20)
  return callapps.in_list(out and ("\n" .. out .. "\n") or "", band.WIN)
end

function callapps.mode()
  local ok, have, mode = pcall(reaper.GetAudioDeviceInfo, "MODE")
  return ok and have and mode or ""
end
local function wasapi_exclusive() return false end -- (shortcut: WASAPI is taken as shared, REAPER's default; exclusive isn't readable here)

-- For Health: a row's words when a call app runs and may clash with REAPER here, or nil.
function callapps.health_words()
  local apps = callapps.running()
  if #apps == 0 then return nil end
  local list = table.concat(apps, " and ")
  if callapps.holds_device(callapps.mode(), band.WIN, wasapi_exclusive()) then
    return list .. " is running, and REAPER has your audio interface over " .. callapps.mode() .. ", which most drivers give to one app only: " ..
      "the call may lose its microphone or sound, or take the interface from REAPER. Settings > Advanced > Calls has the ways round it."
  end
  return list .. " is running beside REAPER: mute its microphone while you play, and turn off its noise suppression and echo cancellation " ..
    "for music (Settings > Advanced > Calls)."
end

-- Settings > Advanced: the ways round it, in the order to try them.
function callapps.card(ctx, ImGui, go_real_time)
  ImGui.SeparatorText(ctx, "Calls (Discord, Zoom, Teams...)")
  local apps = callapps.running()
  local mode = callapps.mode()
  local holds = callapps.holds_device(mode, band.WIN, wasapi_exclusive())
  ImGui.TextDisabled(ctx, (#apps > 0 and ("Running now: " .. table.concat(apps, ", ") .. ". ") or "No call app running now. ") ..
    "REAPER's audio: " .. (mode ~= "" and mode or "?") .. (holds and " (keeps the interface to itself)" or ""))
  ImGui.TextWrapped(ctx, "1. Talk through StudioSync instead: Real time mode's Talk button sends your voice to the others through REAPER's own audio, " ..
    "so nothing fights over the interface, and it goes quiet by itself while anyone records.")
  if go_real_time and ImGui.SmallButton(ctx, "Go to Real time mode") then go_real_time() end
  ImGui.TextWrapped(ctx, "2. Keep the call app, on other sound: set its microphone and speaker to your computer's own (or a headset or webcam " ..
    "mic) rather than the interface REAPER uses. Some interfaces' drivers let two apps share them (multi-client ASIO): then the call can use it too.")
  if band.WIN then
    ImGui.TextWrapped(ctx, "3. Or let REAPER share the interface: Preferences > Audio > Device, Audio system WASAPI, Shared mode. A little more " ..
      "latency, and every app can use the interface at once.")
    if ImGui.SmallButton(ctx, "Open REAPER's audio settings") then reaper.Main_OnCommand(40099, 0) end
  end
  ImGui.TextWrapped(ctx, (band.WIN and "4." or "3.") .. " In the call app: mute its microphone while you play, and turn off noise suppression, echo " ..
    "cancellation and automatic gain (they treat music as noise). With Real time mode on too, the music already goes to the others: " ..
    "two copies echo.")
  ImGui.TextWrapped(ctx, (band.WIN and "5." or "4.") .. " To play REAPER into the call (a listener who isn't in the studio): a virtual cable, " ..
    (band.WIN and "VB-CABLE (vb-audio.com) or Voicemeeter," or "BlackHole (existential.audio)," ) ..
    " as the call's microphone, with REAPER's master sent to it. The listening page (Mixes) is simpler for that.")
end

return callapps
