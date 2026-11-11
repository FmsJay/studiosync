-- The panel's live-listening controls (shown with Real time mode on): hear each bandmate or not, my time / their
-- time, and a guest who joins with only SonoBus. The mechanics are lib/hear.lua and lib/guest.lua.
local band = require("band")
local hear, guest = require("hear"), require("guest")
local page = {}

local function ext(proj, k) return select(2, reaper.GetProjExtState(proj, band.SECTION, k)) end
local function run(name)
  local script = (debug.getinfo(1, "S").source:match("^@?(.*)[/\\]lib[/\\]") or "") .. "/StudioSync - " .. name .. ".lua"
  local id = reaper.AddRemoveReaScript(true, 0, script, true)
  if id > 0 then reaper.Main_OnCommand(id, 0) end
end

-- Beside the last item if `label` (plus a box or field `extra` wide) still fits, else on the next line: the docked
-- panel's columns are narrow, and a SameLine past their edge is just cut off (laptop, 0.33.0: the hear button, "Guest").
function page.fit(ctx, ImGui, label, extra)
  ImGui.SameLine(ctx, 0, 6)
  local pad = 2 * select(1, ImGui.GetStyleVar(ctx, ImGui.StyleVar_FramePadding)) + ImGui.GetFrameHeight(ctx) + 4
  if ImGui.GetContentRegionAvail(ctx) < ImGui.CalcTextSize(ctx, label) + pad + (extra or 0) then ImGui.NewLine(ctx) end
end

-- After a bandmate's name in Who's here: "hear" / "muted". Only while Real time mode is on (SonoBus online): the live
-- mix stays on the master after, and the button stayed with it (laptop, 0.33.1).
function page.person(ctx, ImGui, proj, name)
  if not hear.mix(proj, false) then return end
  local live = require("live")
  local sm, si = live.fx(proj, false, live.SONOBUS)
  if not sm or reaper.TrackFX_GetOffline(sm, si) then return end
  local on = hear.is_on(proj, name)
  page.fit(ctx, ImGui, "muted")
  if on then
    if ImGui.SmallButton(ctx, "hear##" .. name) then hear.set_on(proj, name, false) end
  else
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, require("theme").RED)
    if ImGui.SmallButton(ctx, "muted##" .. name) then hear.set_on(proj, name, true) end
    ImGui.PopStyleColor(ctx)
  end
  ImGui.SetItemTooltip(ctx, (on and ("You hear " .. name .. " live. Click to stop hearing them (only here: they still hear you).")
    or ("You don't hear " .. name .. " live. Click to hear them again.")) ..
    (hear.own_pair(proj, name) and "" or "\n(They share one level with anyone else SonoBus has no pair for: they get their own when Real time mode next starts.)"))
end

-- Under the Real time mode switch, while it's on.
function page.realtime(ctx, ImGui, proj)
  if not hear.mix(proj, false) then return end
  local function beside(label, extra) page.fit(ctx, ImGui, label, extra) end
  local their = ext(proj, "hear their time") == "1"
  local ms = math.floor(hear.delay(proj) + 0.5)
  if ImGui.RadioButton(ctx, "My time", not their) and their then
    reaper.SetProjExtState(proj, band.SECTION, "hear their time", "")
    hear.set_delay(proj, 0)
    band.log("you hear in your own time again: your backing on time, the others as they arrive")
  end
  ImGui.SetItemTooltip(ctx, "You hear everyone as it arrives: your backing on time, them a little late (the network).")
  -- (the label says whose side moves: "Their time" alone read as their audio being delayed, on the laptop)
  beside("Their time (my backing later)")
  if ImGui.RadioButton(ctx, "Their time (my backing later)", their) and not their then
    reaper.SetProjExtState(proj, band.SECTION, "hear their time", "1")
    local want = guest.on(proj) and guest.delay(proj) or tonumber(ext(proj, "their ms")) or 100
    hear.set_delay(proj, want)
    ms = want
    band.log(string.format("you hear in their time: your backing %d ms later, so the others line up with it (listening, not playing)", want))
  end
  ImGui.SetItemTooltip(ctx, "Delays your backing so their playing lines up with it. For listening along, not for playing.\n" ..
    "The delay to set: a guest's measured one, or each collaborator's in SonoBus's window (the number after the down arrow).")
  if their then
    beside("", 90)
    ImGui.SetNextItemWidth(ctx, 90)
    local ch, v = ImGui.DragInt(ctx, "##their", ms, 1, 0, hear.MAX_MS, "%d ms")
    if ch then hear.set_delay(proj, v); reaper.SetProjExtState(proj, band.SECTION, "their ms", tostring(v)) end
    if ImGui.IsItemDeactivatedAfterEdit(ctx) then band.log(string.format("their time: your backing %d ms later", math.floor(hear.delay(proj) + 0.5))) end
    ImGui.SetItemTooltip(ctx, "How much later your backing comes. Drag, or double-click to type.")
  end
  local g = guest.on(proj)
  beside("SonoBus-only singer")
  local chg, gv = ImGui.Checkbox(ctx, "SonoBus-only singer", g) -- (not "Guest": that's the day invitation. UX review, 0.58.47)
  if chg then guest.set(proj, gv) end
  ImGui.SetItemTooltip(ctx, "Someone joining from the SonoBus app alone, a singer at home, say. They hear your mix,\n" ..
    "and their singing records on the Real time track when you record. Send them your SonoBus link (Configure SonoBus).")
  if g then
    local d = guest.delay(proj)
    beside("Swap in their own file")
    if ImGui.SmallButton(ctx, "Swap in their own file") then
      local item = reaper.GetSelectedMediaItem(proj, 0)
      local ok, path = item and reaper.GetUserFileNameForRead("", "Their own recording of this take", "")
      if not item then band.msg("Select what you recorded from them first (their item).")
      elseif ok then
        local off, why = require("extras").swap_in_file(item, path)
        band.log(off and string.format("their own recording is in as a new take, lined up by ear (%.3f s into the file)", off) or tostring(why))
      end
    end
    ImGui.SetItemTooltip(ctx, "What came over SonoBus is compressed. Their own recording (SonoBus can record on their side) is the real thing:\n" ..
      "select what you recorded from them, pick their file, and it goes in as a new take, lined up with what's there.")
    local label = d and string.format("Measure again (%d ms)", d) or "Measure their delay"
    beside(label)
    if ImGui.SmallButton(ctx, label) then run("Measure guest delay") end
    ImGui.SetItemTooltip(ctx, "They clap along to 8 clicks; StudioSync times where the claps land. Measure right before you record:\n" ..
      "the delay through SonoBus drifts as it adjusts its buffers (tested over Wi-Fi: 426-555 ms within two minutes).")
    if d then
      beside("Line up their takes")
      if ImGui.SmallButton(ctx, "Line up their takes") then
        local _, name = reaper.GetUserInputs("StudioSync: the guest's takes", 1, "Guest's name (their track)", ext(proj, "guest name"))
        if _ then
          reaper.SetProjExtState(proj, band.SECTION, "guest name", name)
          local n, label = guest.line_up(proj, name)
          band.log(n > 0 and string.format("%d take(s) moved %d ms earlier onto '%s': the others get them now", n, d, label)
            or "nothing recorded from the guest yet: record (they sing along), then line up")
        end
      end
      ImGui.SetItemTooltip(ctx, "Moves what you recorded from them onto a studio track of their own, earlier by their delay, so it sits\n" ..
        "where they sang it. The others get it like any take.")
    end
  end
end

-- Beside a person, in Who's here.
function page.produce_button(ctx, ImGui, proj, cfg, b, name)
  local producer = require("producer")
  local on = producer.who(proj) == name
  if on then ImGui.PushStyleColor(ctx, ImGui.Col_Button, require("theme").ACCENT) end
  if ImGui.SmallButton(ctx, (on and "Producing" or "Produce") .. "##produce" .. name) then
    if on then producer.stop(proj, cfg, b) else
      if producer.who(proj) then producer.stop(proj, cfg, b) end
      local ok, why = producer.start(proj, cfg, b, name)
      if not ok then band.msg(tostring(why)) end
    end
  end
  if on then ImGui.PopStyleColor(ctx) end
  ImGui.SetItemTooltip(ctx, on and ("You're producing " .. name .. ". Click to stop.") or
    ("Hear " .. name .. " record, on your grid, as it happens: your song plays a moment behind theirs, from your own copy, so they land right on it.\n" .. (producer.via(proj) == "stamp" and "You can talk to them between takes. " or "") .. "They needn't do anything."))
end

-- ReaNINJAM's window stays out of sight (lib/live.lua): what it says about its connection, here instead. Read once a second: it walks the window's controls.
local njm_at, njm_said = -math.huge, nil
function page.ninjam_line(ctx, ImGui)
  if reaper.time_precise() - njm_at > 1 then njm_at, njm_said = reaper.time_precise(), require("live").status() end
  if not njm_said then return end
  ImGui.TextDisabled(ctx, "NINJAM: " .. njm_said)
  ImGui.SetItemTooltip(ctx, "ReaNINJAM runs hidden. Show it, on the Play/Jam page (Settings > Advanced > Show the Play/Jam tab), opens its window.")
end

-- On Home, while producing or being produced.
function page.producer(ctx, ImGui, proj, cfg, b, rows)
  local producer, theme = require("producer"), require("theme")
  local by = reaper.GetExtState(band.SECTION, "produced by " .. tostring(proj))
  if by ~= "" then
    ImGui.TextColored(ctx, theme.ACCENT, by .. " is producing you")
    ImGui.SetItemTooltip(ctx, "They hear what you record on their grid, a moment behind you. Nothing changes for you: record as usual.")
    local ch, on = ImGui.Checkbox(ctx, "Let them start and stop my transport##letdrive", producer.lets() == by)
    if ch then producer.set_lets(on and by or nil); band.log(on and (by .. " can now play, record and stop your transport from their panel") or "only you start and stop your transport now") end
    ImGui.SetItemTooltip(ctx, "Gives " .. by .. " Play, Record and Stop for your REAPER, from their cursor: handy when your hands are on an instrument.\n" ..
      "Only " .. by .. ", only while they produce you. Remembered on this computer.")
    page.ninjam_line(ctx, ImGui)
    for _, st in ipairs(require("presence").peers(cfg, b.song, b.room)) do
      if st.produce == cfg.user and st.playing and reaper.GetPlayStateEx(proj) & 1 == 0 then
        ImGui.TextDisabled(ctx, st.user .. " is still listening to the end of that")
      end
    end
  end
  local name = producer.who(proj)
  if not name then return end
  local them
  for _, r in ipairs(rows) do if r.user == name or r.name == name then them = r end end
  local playing = reaper.GetPlayStateEx(proj) & 1 == 1
  if select(2, ImGui.GetContentRegionAvail(ctx)) > 130 then ImGui.SeparatorText(ctx, "Producing") end -- (in a short docker, its row is the one Talk and Stop need; "Following..." says it)
  local colour = { ok = theme.GREEN, wait = theme.YELLOW, bad = theme.RED }
  for _, l in ipairs(producer.lines(proj, name, them, require("stamp").status(), playing)) do ImGui.TextColored(ctx, colour[l[2]] or theme.GREEN, l[1]) end
  -- (first in the row, under a line either route has: it moved from under the pointer otherwise, onto the lag drag. Mac, 0.58.10)
  if producer.via(proj) == "ninjam" then page.ninjam_line(ctx, ImGui) end
  local via = producer.via(proj)
  if ImGui.SmallButton(ctx, via == "stamp" and "Through SonoBus" or "Through a NINJAM server") then
    producer.talk(proj, false)
    local name = producer.who(proj)
    producer.stop(proj, cfg, b) -- (it took effect only on the next Produce, with the old route still running: Mac, 0.58.7)
    producer.set_via(proj, via == "stamp" and "ninjam" or "stamp")
    local ok, why = producer.start(proj, cfg, b, name)
    if not ok then band.msg(why) end
  end
  ImGui.SetItemTooltip(ctx, "How their sound reaches you. SonoBus needs no server. A NINJAM server is a steadier route with no talkback, reached over Tailscale; StudioSync starts the server if nobody has. ReaNINJAM connects by itself on both computers.")
  page.fit(ctx, ImGui, "No talkback")
  if producer.via(proj) == "stamp" then
    local talking = producer.talking(proj)
    if talking then ImGui.PushStyleColor(ctx, ImGui.Col_Button, theme.RED) end
    if ImGui.SmallButton(ctx, talking and "Talking" or "Talk") then producer.talk(proj, not talking) end
    if talking then ImGui.PopStyleColor(ctx) end
    ImGui.SetItemTooltip(ctx, "Your first input goes to " .. name .. " right away, while you press this. It reaches them in a moment, even mid-take: \"hold on\" stops them.")
  else
    ImGui.TextDisabled(ctx, "No talkback")
    ImGui.SetItemTooltip(ctx, "A NINJAM server only plays sound as each song reaches it, so talking between takes needs the SonoBus route.")
  end
  page.fit(ctx, ImGui, "", 110)
  ImGui.SetNextItemWidth(ctx, 110)
  local ch, v = ImGui.DragDouble(ctx, "##producelag", producer.lag(proj), 0.05, producer.MIN_LAG, producer.MAX_LAG, "%.1f s behind")
  if ch then producer.set_lag(proj, v) end
  ImGui.SetItemTooltip(ctx, "How far behind them your song runs. More gives a bad connection room; less is closer to them. It takes effect on their next start.")
  page.fit(ctx, ImGui, "Stop")
  if ImGui.SmallButton(ctx, "Stop") then producer.stop(proj, cfg, b) end
  ImGui.SetItemTooltip(ctx, "Back to your own transport.")
  -- their transport, from here, if they let you (lib/producer.lua producer.remote)
  if them and producer.has(them.lets, cfg.user) then
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.TextDisabled(ctx, name .. "'s transport:")
    local armed = #(them.armed or {}) > 0
    for _, btn in ipairs({ { "Play##rplay", "start", false, "Plays " .. name .. "'s song from your cursor. Yours follows a moment behind, as always." },
        { "Record##rrec", "start", true, armed and ("Records " .. name .. " from your cursor, on what they have armed (" .. table.concat(them.armed, ", ") .. ").")
          or ("Nothing is armed on " .. name .. "'s side, so this records nothing. Ask them to arm a track.") },
        { "Stop##rstop", "stop", false, "Stops " .. name .. "'s transport." } }) do
      page.fit(ctx, ImGui, btn[1]:match("^[^#]+"))
      if ImGui.SmallButton(ctx, btn[1]) then
        local ok, why = producer.remote(proj, cfg, b, btn[2], btn[3])
        if not ok then band.log(tostring(why)) end
      end
      ImGui.SetItemTooltip(ctx, btn[4])
    end
    if not armed then ImGui.SameLine(ctx); ImGui.TextDisabled(ctx, "(nothing armed)") end
  elseif them then
    ImGui.TextDisabled(ctx, name .. " can let you start and stop their transport (on their Home)")
  end
end

return page
