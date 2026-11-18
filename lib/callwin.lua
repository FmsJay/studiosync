-- The call in a window of its own (James, 0.59.14: "a pop-out window for the call with usual mute and unmute controls along with the others
-- we built and any other useful controls for in-studio calls"). It floats over REAPER, stays while the panel is shrunk to its box, and
-- remembers being open (ExtState "call window"). Join or leave, mute and unmute (Talk), hold to talk, the mic and its level, how loud
-- you go out and how loud everyone comes in, deafen, who's in the call, each person's volume (SonoBus's window) and the studio's video call.
local band = require("band")
local cw = {}

function cw.is_open() return reaper.GetExtState(band.SECTION, "call window") == "1" end
function cw.set_open(on) reaper.SetExtState(band.SECTION, "call window", on and "1" or "", true) end

local function db_of(vol) return vol > 0 and 20 * math.log(vol, 10) or -150 end
local function vol_of(db) return db <= -60 and 0 or 10 ^ (db / 20) end
cw.db_of, cw.vol_of = db_of, vol_of

local held -- (Hold to talk: Talk was off when it was pressed, so letting go mutes again)

-- A track's volume as a dB slider. -> whether it changed
local function volume(ctx, ImGui, label, tr, tip)
  local db = db_of(reaper.GetMediaTrackInfo_Value(tr, "D_VOL"))
  ImGui.SetNextItemWidth(ctx, -1)
  local ch, v = ImGui.SliderDouble(ctx, label, math.max(-60, math.min(12, db)), -60, 12, db <= -60 and "off" or "%.1f dB")
  if ch then reaper.SetMediaTrackInfo_Value(tr, "D_VOL", vol_of(v)) end
  if tip then ImGui.SetItemTooltip(ctx, tip .. " Ctrl+click to type a value.") end
  return ch
end

-- e: { ctx, ImGui, proj, b (the studio project in front, or nil), call_on(), set_call(v), sonobus_open(), people() -> names in the call,
-- call_link() -> the studio's video call link or nil }
function cw.draw(e)
  if not cw.is_open() then return end
  local ctx, ImGui, proj = e.ctx, e.ImGui, e.proj
  ImGui.SetNextWindowSize(ctx, 300, 0, ImGui.Cond_Always)
  local flags = ImGui.WindowFlags_NoCollapse | ImGui.WindowFlags_AlwaysAutoResize | ImGui.WindowFlags_NoDocking
  local visible, open = ImGui.Begin(ctx, "StudioSync call###studiosync_call", true, flags)
  if visible then
    local ok, err = pcall(function() -- (whatever happens inside, End must still be reached)
      if not e.b then ImGui.TextDisabled(ctx, "Open a studio project to talk."); return end
      local live = require("live")
      local on = e.call_on()
      local w = ImGui.GetContentRegionAvail(ctx)
      if on then ImGui.PushStyleColor(ctx, ImGui.Col_Button, 0x8A2B2BFF) end
      if ImGui.Button(ctx, (on and "Leave the call" or "Join the call") .. "##cwjoin", w, 0) then e.set_call(not on) end
      if on then ImGui.PopStyleColor(ctx) end
      if not on then
        ImGui.TextDisabled(ctx, "Talk to everyone in the studio with your talk mic, whatever Real time mode is doing. Never recorded.")
      else
        local talking = live.talking(proj)
        -- mute and unmute: Talk off is muted
        ImGui.PushStyleColor(ctx, ImGui.Col_Button, talking and 0x2E7D4FFF or 0x5A5F6AFF)
        if ImGui.Button(ctx, (talking and "Mic on  -  click to mute" or "Muted  -  click to talk") .. "##cwmute", w, ImGui.GetFrameHeight(ctx) * 1.6) then
          held = nil; live.talk(proj, not talking)
        end
        ImGui.PopStyleColor(ctx)
        ImGui.SetItemTooltip(ctx, "Your talk mic to everyone in the call. It goes quiet by itself only while a track here records from that same mic.")
        -- hold to talk: on while pressed, back to muted when let go
        ImGui.Button(ctx, "Hold to talk##cwhold", w, 0)
        if ImGui.IsItemActivated(ctx) and not talking then held = true; live.talk(proj, true) end
        if held and ImGui.IsItemDeactivated(ctx) then held = nil; live.talk(proj, false) end
        ImGui.SetItemTooltip(ctx, "Talks while you hold the button, mutes when you let go.")
        -- the mic and its level
        local tt = live.talk_track(proj, false)
        if tt then
          local peak = math.max(reaper.Track_GetPeakInfo(tt, 0), reaper.Track_GetPeakInfo(tt, 1))
          ImGui.ProgressBar(ctx, talking and math.min(1, peak) or 0, w, 6, "")
          ImGui.SetItemTooltip(ctx, talking and "Your mic's level, as it goes out." or "Muted: nothing goes out.")
        end
        local inputs, cur = live.talk_inputs(), live.talk_input()
        local mic = "input " .. (cur + 1)
        for _, i in ipairs(inputs) do if i[1] == cur then mic = i[2] end end
        ImGui.SetNextItemWidth(ctx, w)
        if ImGui.BeginCombo(ctx, "##cwmic", "Mic: " .. mic) then
          for _, i in ipairs(inputs) do
            if ImGui.Selectable(ctx, i[2] .. "##cwmic" .. i[1], i[1] == cur) then live.set_talk_input(proj, i[1]); band.log("Talk uses " .. i[2] .. " now") end
          end
          if #inputs == 0 then ImGui.TextDisabled(ctx, "No audio inputs: pick your interface in REAPER's Preferences > Audio > Device.") end
          ImGui.EndCombo(ctx)
        end
        if tt then volume(ctx, ImGui, "##cwout", tt, "How loud you go out to the others.") end
        -- everyone coming in: the Real time track, where SonoBus brings the others in
        local rt = live.rt_track(proj, false)
        if rt then
          ImGui.Text(ctx, "Everyone")
          volume(ctx, ImGui, "##cwin", rt, "How loud everyone in the call (and in Real time mode) comes in, only for you.")
          local deaf = reaper.GetMediaTrackInfo_Value(rt, "B_MUTE") == 1
          local dch, dv = ImGui.Checkbox(ctx, "Deafen (hear nobody)##cwdeaf", deaf)
          if dch then reaper.SetMediaTrackInfo_Value(rt, "B_MUTE", dv and 1 or 0) end
          ImGui.SetItemTooltip(ctx, "Silences everyone coming in, for you only. They still hear you if your mic is on.")
          if ImGui.SmallButton(ctx, "Each person's volume##cweach") then e.sonobus_open() end
          ImGui.SetItemTooltip(ctx, "SonoBus's own window: a level and a mute for each person you hear, only for you.")
        end
        local names = e.people()
        ImGui.Spacing(ctx)
        ImGui.SeparatorText(ctx, #names > 0 and ("In the call (" .. #names .. ")") or "In the call")
        if #names == 0 then ImGui.TextDisabled(ctx, "Nobody else yet.") end
        for _, n in ipairs(names) do ImGui.BulletText(ctx, n) end
      end
      local link = e.call_link()
      if link then
        ImGui.Spacing(ctx)
        if ImGui.SmallButton(ctx, "Video call##cwvideo") then band.open_url(link) end
        ImGui.SetItemTooltip(ctx, "Opens the studio's video call (" .. link .. "). Mute its microphone: this call already carries your voice.")
      end
    end)
    if not ok then
      ImGui.TextDisabled(ctx, "Something went wrong here: Settings > Console has the details.")
      if cw.said ~= tostring(err) then cw.said = tostring(err); band.log("call window: " .. cw.said) end -- (once, not every frame)
    end
  end
  ImGui.End(ctx)
  if not open then held = nil; cw.set_open(false) end
end

return cw
