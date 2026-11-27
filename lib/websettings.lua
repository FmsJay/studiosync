-- Settings in the web UI (docs/rt/ui-web-plan.md Phase 10b, 2.9; James's decisions 2026-11-27; rt-ui10b). The "settings" topic: This computer
-- (Window, Sync, Audio), Studio, Devices and Advanced as rows the page draws one way, each read and written through its module's own getters
-- and setters (lib/groups.lua's studio switches, lib/streams.lua, lib/prints.lua, lib/liveaudio.lua, lib/phonerec.lua, lib/ablink.lua,
-- lib/tools.lua, lib/audience.lua, lib/alerts.lua, lib/persons.lua) or, for the REAPER window's own keys (extension/webui_dock.cpp reads them),
-- the ExtState here. You is the page's own (profile.js and env's studios). Built only while a page shows Settings (it says so every 10 s).
-- Who may change what:
--   * nothing from another device or a phone (decision 4: a phone may not change studio settings; This computer, Devices and Advanced are this
--     computer's own): only a page on this computer (StudioSync_WebUIPollHere) changes anything;
--   * Studio rows: the owner and admins, as the panel (groups.may_manage); Public links: the owner only (audience.set_public checks it again).
-- Every value from the page is checked against its row (a choice from its list, a number clamped, text by its module's own check) before
-- anything is written. GPL-3.0-or-later. (James, rt)
local band = require("band")
local websettings = {}
websettings.WANT_FOR = 30 -- seconds a page counts as showing Settings after it last said so
websettings.EVERY = 2     -- seconds between builds while it shows
websettings.PHONE_FOR = 60 -- seconds the phone link stays in the topic after this computer's page asked for it
websettings.TEXT_MAX = 300

local S = { want = -math.huge, at = -math.huge, phone = -math.huge, said = nil }
local function ext(k) return reaper.GetExtState(band.SECTION, k) end
local function put(k, v) reaper.SetExtState(band.SECTION, k, v, true) end
local function groups() return require("groups") end
-- (the scripts' folder, for REAPER's Actions list: this file is <dir>/lib/websettings.lua)
local DIR = (debug.getinfo(1, "S").source:match("^@?(.*)[/\\]lib[/\\][^/\\]+$")) or "."

-- A choice's value as one of its own, else the default. Pure.
local function pick(v, choices, default)
  for _, c in ipairs(choices) do if c[1] == v or tostring(c[1]) == v then return c[1] end end
  return default
end

-- The REAPER window's focus rule (extension/webui_dock.cpp, ExtState "web ui focus"): strip by default (decision 2).
websettings.FOCUS = { { "strip", "Shrink to the strip" }, { "button", "Shrink to the button" }, { "stay", "Stay as it is" },
  { "behind", "Go behind REAPER" }, { "fade", "Fade" } }
websettings.BUTTON = { { 22, "Small" }, { 28, "Medium" }, { 40, "Large" }, { 56, "Big" } }
local PARTS = { { "auto", "Auto" }, { "notes", "Dry (my plug-ins)" }, { "sound", "Wet (studio's print)" } }
local STREAM = { { "as_it_comes", "As it comes" }, { "in_time", "In time (NINJAM style)" }, { "show", "Show only (muted)" } }
local HUB = { { 3, "From 3 people" }, { 4, "From 4 people (default)" }, { 5, "From 5 people" }, { 6, "From 6 people" }, { 8, "From 8 people" },
  { 0, "Never (peer to peer)" } }

-- The talk mic's inputs: REAPER's, each naming the tracks that record from it (liveaudio.talk_advice). -> choices, note, fix.
local function talk(c)
  local la = require("liveaudio")
  local first, nch = la.mine()
  local n = reaper.GetNumAudioInputs and math.floor(tonumber(reaper.GetNumAudioInputs()) or 0) or 0
  local tracks, proj = {}, c.proj
  for i = 0, (proj and reaper.CountTracks(proj) or 0) - 1 do
    local tr = reaper.GetTrack(proj, i)
    local tag = band.track_ext(tr, "band_local")
    if tag == "" or tag == "yours" then -- (StudioSync's own helper tracks aren't anyone's input)
      tracks[#tracks + 1] = { name = select(2, reaper.GetTrackName(tr)), inp = reaper.GetMediaTrackInfo_Value(tr, "I_RECINPUT"),
        armed = reaper.GetMediaTrackInfo_Value(tr, "I_RECARM") == 1 }
    end
  end
  local users, clash, free = la.talk_advice(first, nch, n, tracks)
  local name = function(i) local s = reaper.GetInputChannelName and reaper.GetInputChannelName(i); return type(s) == "string" and s ~= "" and s or ("Input " .. (i + 1)) end
  local out = {}
  for i = 0, math.min(n, 64) - 1 do out[#out + 1] = { i, name(i) .. (users[i] and ("  ·  " .. users[i]) or "") } end
  local note = n == 0 and "No audio inputs: pick your interface in REAPER's Preferences > Audio > Device." or
    clash and ("Your talk mic is what " .. clash .. " records from: while it's armed, your talk goes as part of its playing, not on its own.") or nil
  return out, note, clash and free and { label = "Talk on " .. name(free) .. " instead", value = free } or nil
end

-- The rows. id, sec (computer, studio, devices, advanced), grp (its heading), kind (bool, choice, number, text, button), label, help,
-- get(c) / set(c, v, sure) (set -> words for the log, or nil and why), choices (or choices(c) -> list, note, fix), lo / hi, studio (owner and
-- admins), owner (the owner only), confirm_on / confirm_off (the page asks first; a set without `sure` is refused), shown(c), note(c).
websettings.ROWS = {
  -- This computer > Window (extension/webui_dock.cpp reads these keys; rt-ui8)
  { id = "focus", sec = "computer", grp = "Window", kind = "choice", label = "When REAPER takes the focus", choices = websettings.FOCUS,
    help = "What the floating StudioSync window does when you click REAPER under it. Back with a click on the strip or button, or the toolbar button.",
    get = function() return pick(ext("web ui focus"), websettings.FOCUS, "strip") end,
    set = function(_, v) put("web ui focus", v); return "the StudioSync window, when REAPER takes the focus: " .. v end },
  { id = "button_size", sec = "computer", grp = "Window", kind = "choice", label = "The button's size", choices = websettings.BUTTON,
    get = function() return pick(tonumber(ext("web ui button size")), websettings.BUTTON, 28) end,
    set = function(_, v) put("web ui button size", tostring(v)); return "the StudioSync button's size: " .. v .. " px" end },
  { id = "lock", sec = "computer", grp = "Window", kind = "bool", label = "Lock the strip and button where they are",
    get = function() return ext("web ui lock") == "1" end,
    set = function(_, v) put("web ui lock", v and "1" or ""); return v and "the strip and button stay where they are" or "the strip and button can be dragged again" end },
  { id = "ui_web", sec = "computer", grp = "Window", kind = "bool", label = "REAPER's StudioSync button opens this view (not the panel)",
    help = "The panel stays as it is otherwise (Classic panel until the band test).",
    get = function() return ext("ui") == "web" end,
    set = function(_, v)
      if v then put("ui", "web") else reaper.DeleteExtState(band.SECTION, "ui", true) end
      return v and "the StudioSync toolbar button opens the web view" or "the StudioSync toolbar button opens the panel again"
    end },
  { id = "toolbar_button", sec = "computer", grp = "Window", kind = "bool", label = "StudioSync button on REAPER's toolbar",
    get = function() return require("tools").toolbar_button() end,
    set = function(_, v)
      local ok, why = require("tools").set_toolbar_button(v)
      if not ok then return nil, why end
      return v and "the StudioSync button joins the main toolbar" or "the StudioSync button leaves the main toolbar"
    end,
    note = function() local t = require("tools"); return t.toolbar_button() and t.toolbar_button_blocked() or nil end },
  -- This computer > Sync (the panel's Settings > Options)
  { id = "parts_play", sec = "computer", grp = "Sync", kind = "choice", label = "Parts play (MIDI and audio)", choices = PARTS,
    help = "Dry: through your own plug-ins. Wet: the studio's print. Auto: dry when every plug-in loads here. Only on this computer.",
    get = function() return pick(require("prints").mode(), PARTS, "auto") end,
    set = function(c, v)
      put("midi_plays", v)
      local prints = require("prints")
      for i = 0, (c.proj and reaper.CountMediaItems(c.proj) or 0) - 1 do prints.choose(reaper.GetMediaItem(c.proj, i)) end
      return "parts play " .. v .. " on this computer"
    end },
  { id = "stream_listen", sec = "computer", grp = "Sync", kind = "choice", label = "Bandmates' takes while they record", choices = STREAM,
    get = function() return require("streams").mode() end,
    set = function(_, v) put("stream listen", v); return "bandmates' takes while they record: " .. v end },
  { id = "stream_bars", sec = "computer", grp = "Sync", kind = "number", label = "Bars behind (In time)", lo = 1, hi = 16,
    shown = function() return require("streams").mode() == "in_time" end,
    get = function() return require("streams").bars() end,
    set = function(_, v) put("stream bars", tostring(v)); return "In time runs " .. v .. " bar(s) behind" end },
  { id = "record_wav", sec = "computer", grp = "Sync", kind = "bool", label = "Record 24-bit WAV (off: FLAC)",
    help = "WAV takes reach bandmates listening in time under a second behind; FLAC is smaller and arrives in 2-5 s steps.",
    get = function() return require("streams").record_wav() end,
    set = function(c, v)
      local streams = require("streams")
      if c.proj then streams.use_wav(c.proj, v) else put("record wav", v and "1" or "0") end
      return v and "this computer records 24-bit WAV" or "this computer records FLAC"
    end },
  { id = "live_set", sec = "computer", grp = "Sync", kind = "bool", label = "Live set: pause syncing while playing",
    help = "While REAPER plays nothing is sent or taken in; everything catches up when you stop.",
    get = function() return ext("live set") == "on" end,
    set = function(_, v) put("live set", v and "on" or ""); return v and "live set: syncing pauses while REAPER plays" or "live set off" end },
  -- This computer > Audio
  { id = "ablink", sec = "computer", grp = "Audio", kind = "bool", label = "Join Ableton Link on this computer",
    shown = function() local a = require("ablink"); return a.available() or a.on() end,
    get = function() return require("ablink").on() end,
    set = function(_, v) put(require("ablink").KEY, v and "1" or ""); return v and "Ableton Link: on for this computer" or "Ableton Link: off for this computer" end },
  -- Devices: the talk mic (findings small item), the phone's secure link
  { id = "talk_input", sec = "devices", grp = "Talk mic", kind = "choice", label = "Talk mic", choices = talk,
    help = "The input you talk into, only on this computer. Pick one no track records from and your talk stays separate when you arm a track.",
    get = function() return (require("liveaudio").mine()) end,
    set = function(_, v) require("liveaudio").set_mine(v); return "the talk mic is input " .. (v + 1) .. " now" end },
  { id = "talk_stereo", sec = "devices", grp = "Talk mic", kind = "bool", label = "Stereo pair",
    get = function() return select(2, require("liveaudio").mine()) >= 2 end,
    set = function(_, v) require("liveaudio").set_mine(nil, v and 2 or 1); return v and "the talk mic is a stereo pair" or "the talk mic is mono" end },
  { id = "talk_kbps", sec = "devices", grp = "Talk mic", kind = "number", label = "What you send (kbit/s)", lo = 64, hi = 256,
    get = function() return select(3, require("liveaudio").mine()) end,
    set = function(_, v) require("liveaudio").set_mine(nil, nil, v); return "live audio sends " .. v .. " kbit/s" end },
  { id = "phone_auto", sec = "devices", grp = "Phone", kind = "bool", label = "Set up the phone's secure link by itself",
    help = "When a phone opens the Record page, StudioSync asks Tailscale for the https address its microphone needs, once a session.",
    get = function() return require("phonerec").auto_on() end,
    set = function(_, v) put(require("phonerec").AUTO_KEY, v and "" or "0"); return v and "the phone's secure link sets itself up" or "the phone's secure link waits for the Record page's button" end },
  -- Advanced
  { id = "all_actions", sec = "advanced", grp = "Advanced", kind = "bool", label = "Every StudioSync action in REAPER's Actions list",
    get = function() return band.all_actions() end,
    set = function(_, v)
      put("all actions", v and "1" or "")
      local listed, out = band.sync_actions(DIR)
      return string.format("the Actions list has %d StudioSync action(s) now%s", listed or 0, (out or 0) > 0 and (" (" .. out .. " taken out)") or "")
    end },
  { id = "show_advanced", sec = "advanced", grp = "Advanced", kind = "bool", label = "Show advanced controls (the panel)",
    get = function() return ext("show advanced") == "1" end,
    set = function(_, v) put("show advanced", v and "1" or "0"); return v and "the panel shows advanced controls" or "the panel hides advanced controls" end },
  { id = "show_play", sec = "advanced", grp = "Advanced", kind = "bool", label = "Show the Play/Jam tab (outside NINJAM server, the panel)",
    get = function() return ext("show play") == "1" end,
    set = function(_, v) put("show play", v and "1" or ""); return v and "the panel shows Play/Jam" or "the panel hides Play/Jam" end },
  { id = "debug_report", sec = "advanced", grp = "Debug", kind = "button", label = "Save a debug report now",
    help = "This computer's report, log and errors into the studio's _debug folder.",
    get = function() return false end,
    set = function(c) return "debug report saved: " .. tostring(require("debugmode").write(c.cfg, c.proj, c.b)) end },
  -- Studio (owner and admins; the panel's Settings > Studio cards that are a switch or a choice)
  { id = "public_links", sec = "studio", grp = "Public links", kind = "bool", owner = true, label = "Public links (listening and guests)",
    help = "The owner only. It turns itself off after 6 hours, and off ends every public link and guest.",
    confirm_on = function() return require("audience").WARNING end,
    get = function() return require("audience").public_on() ~= nil end,
    set = function(c, v, sure) return require("audience").set_public(c.cfg, v, sure) end },
  { id = "ai", sec = "studio", grp = "Studio", kind = "bool", studio = true, label = "AI tools (each run asks first)",
    get = function(c) return groups().ai(c.cfg.root) end,
    set = function(c, v) groups().set_ai(c.cfg.root, v); return v and "AI tools are on for the studio" or "AI tools are off for the studio" end },
  { id = "live_audio", sec = "studio", grp = "Live audio", kind = "bool", studio = true, label = "Live audio",
    get = function(c) return groups().live_audio(c.cfg.root) end,
    set = function(c, v) groups().set_live_audio(c.cfg.root, v); return v and "live audio is on for the studio" or "live audio is off for the studio" end },
  { id = "live_hub", sec = "studio", grp = "Live audio", kind = "choice", studio = true, label = "The project's hub mixes it", choices = HUB,
    shown = function(c) return groups().live_audio(c.cfg.root) end,
    get = function(c) return pick(require("liveaudio").hub_from(c.cfg.root), HUB, 4) end,
    set = function(c, v) groups().set_live_hub(c.cfg.root, v ~= require("liveaudio").HUB_FROM and v or nil); return "live audio: the project's hub mixes it from " .. v .. " people (0: never)" end },
  { id = "direct", sec = "studio", grp = "Connection", kind = "bool", studio = true, label = "The direct link",
    get = function(c) return require("direct").enabled(c.cfg.root) end,
    set = function(c, v) groups().set_direct(c.cfg.root, v); return v and "the direct link is on for the studio" or "the direct link is off for the studio" end },
  { id = "nat", sec = "studio", grp = "Connection", kind = "bool", studio = true, label = "Connect without Tailscale too",
    get = function(c) return require("nat").enabled(c.cfg.root) end,
    set = function(c, v) groups().set_nat(c.cfg.root, v); return v and "the studio connects without Tailscale too" or "the studio connects only through Tailscale" end },
  { id = "tailscale_only", sec = "studio", grp = "Connection", kind = "bool", studio = true, label = "Sync only through Tailscale",
    confirm_on = function(c) local t = groups().tailnet(c.cfg.root); return "Sync only through Tailscale (" .. (t and t.name or "?") .. ")?\n\nAnyone in the studio who isn't on that Tailscale network stops syncing until they join it." end,
    shown = function(c) return groups().tailnet(c.cfg.root) ~= nil end,
    get = function(c) return groups().tailscale_only(c.cfg.root) end,
    set = function(c, v) groups().set_tailscale_only(c.cfg.root, v); return v and "the studio syncs only through Tailscale" or "the studio syncs however Syncthing finds everyone again" end },
  { id = "takes_to_lanes", sec = "studio", grp = "Takes", kind = "bool", studio = true, label = "Takes become lanes",
    get = function(c) return groups().takes_to_lanes(c.cfg.root) end,
    set = function(c, v) groups().set_takes_to_lanes(c.cfg.root, v); return v and "takes become lanes for the studio" or "takes stay takes for the studio" end },
  { id = "print_hops", sec = "studio", grp = "Takes", kind = "choice", studio = true, label = "Plug-in hand-overs for prints", choices = function() return require("prints").HOPS end,
    get = function(c) local p = require("prints"); local cap = p.hops_cap(groups().trusted(c.cfg.root).print_hops); for _, o in ipairs(p.HOPS) do if p.hops_cap(o[1]) == cap then return o[1] end end; return 2 end,
    set = function(c, v) groups().set_print_hops(c.cfg.root, v ~= 2 and v or nil); return "plug-in hand-overs for prints: " .. tostring(v) .. " for everyone in the studio" end },
  { id = "colour_parity", sec = "studio", grp = "Look", kind = "bool", studio = true, label = "Everyone sees the project's own colours",
    get = function(c) return groups().colour_parity(c.cfg.root) end,
    set = function(c, v) groups().set_colour_parity(c.cfg.root, v); return v and "colour parity is on for the studio" or "colour parity is off for the studio" end },
  { id = "alerts", sec = "studio", grp = "Phone alerts", kind = "bool", studio = true, label = "Phone alerts (ntfy)",
    confirm_off = function() return "Turn phone alerts off for the studio?\n\nTurning them on again makes a new channel: everyone has to subscribe again." end,
    get = function(c) return require("alerts").channel(c.cfg.root) ~= nil end,
    set = function(c, v) require("alerts").set(c.cfg.root, v); return v and "phone alerts are on for the studio" or "phone alerts are off for the studio" end,
    note = function(c) local ch = require("alerts").channel(c.cfg.root); return ch and ("In the ntfy app, tap + and add this channel: " .. ch) or nil end },
  { id = "call", sec = "studio", grp = "Studio call", kind = "text", studio = true, label = "The studio's call link (Discord, Zoom, Meet)",
    valid = function(v) return v == "" or require("alerts").call_ok(v) end,
    get = function(c) return require("alerts").call_link(c.cfg.root) or "" end,
    set = function(c, v) require("alerts").set_call(c.cfg.root, v); return v == "" and "the studio's call link is gone" or "the studio's call link is set" end },
  { id = "debug", sec = "studio", grp = "Debug and updates", kind = "bool", studio = true, label = "Debug mode for everyone",
    get = function(c) return require("debugmode").on(c.cfg.root) == true end,
    set = function(c, v) groups().set_debug(c.cfg.root, v); return v and "debug mode is on for the studio" or "debug mode is off for the studio" end },
  { id = "folder_updates", sec = "studio", grp = "Debug and updates", kind = "bool", studio = true, label = "Everyone runs StudioSync from the studio's folder",
    get = function(c) return require("fromfolder").on(c.cfg.root) == true end,
    set = function(c, v) groups().set_folder_updates(c.cfg.root, v); return v and "the studio's computers run StudioSync from its folder" or "the studio's computers update StudioSync themselves again" end },
}
local BY = {}
for _, r in ipairs(websettings.ROWS) do BY[r.id] = r end

-- Who's this: role in the studio ("owner", "admin", "member", "open"). -> may (change studio rows), owner.
local function rights(cfg)
  local ok, role = pcall(function() return groups().role(cfg.root, cfg.user) end)
  role = ok and role or "member"
  return role ~= "member", role == "owner" or role == "open", role
end

-- c: { proj, cfg, b }. -> the topic. Each row's get / shown is pcall'd: one module's trouble leaves the others.
function websettings.model(c, now)
  local may, owner, role = rights(c.cfg)
  local rows = {}
  for _, r in ipairs(websettings.ROWS) do
    local okshow, show = true, true
    if r.shown then okshow, show = pcall(r.shown, c) end
    if okshow and show then
      local ok, v = pcall(r.get, c)
      local row = { id = r.id, sec = r.sec, grp = r.grp, kind = r.kind, label = r.label, help = r.help, lo = r.lo, hi = r.hi,
        may = (not r.studio or may) and (not r.owner or owner) or nil }
      if ok then row.value = v else row.error = "couldn't be read here" end
      if type(r.choices) == "function" then
        local okc, list, note, fix = pcall(r.choices, c)
        if okc then row.choices, row.note, row.fix = list, note, fix end
      else row.choices = r.choices end
      if r.note then local okn, n = pcall(r.note, c); if okn and n then row.note = n end end
      if r.confirm_on then local okc, t = pcall(r.confirm_on, c); row.confirm_on = okc and t or nil end
      if r.confirm_off then local okc, t = pcall(r.confirm_off, c); row.confirm_off = okc and t or nil end
      rows[#rows + 1] = row
    end
  end
  local m = { v = 1, user = c.cfg.user, studio = band.info(c.cfg.root).name, role = role, may = may or nil, owner = owner or nil, rows = rows }
  local okp, computers = pcall(require("persons").computers, c.cfg.root, c.cfg.user)
  m.computers = okp and computers or {}
  local okt, ts = pcall(require("services").my_tailscale_name)
  m.tailnet = okt and ts or nil
  if (now or 0) < S.phone then
    local url, why = require("webui").phone_link(c.cfg)
    m.phone = url or nil
    m.phone_why = not url and why or nil
  end
  m.said = S.said
  return m
end

-- Is v right for row r? -> the value to set (a number clamped and whole), or nil and why. Pure but for a text row's own check.
function websettings.check(r, v, c)
  if r.kind == "bool" or r.kind == "button" then
    if type(v) ~= "boolean" then return nil, "not a yes or no" end
    return v
  elseif r.kind == "choice" then
    local list = r.choices
    if type(list) == "function" then list = select(1, list(c)) end
    for _, o in ipairs(list or {}) do if o[1] == v then return o[1] end end
    return nil, "not one of its choices"
  elseif r.kind == "number" then
    v = tonumber(v)
    if not v or v ~= v then return nil, "not a number" end
    return math.max(r.lo, math.min(r.hi, math.floor(v + 0.5)))
  elseif r.kind == "text" then
    if type(v) ~= "string" or #v > websettings.TEXT_MAX then return nil, "too long" end
    v = v:match("^%s*(.-)%s*$")
    if r.valid and not r.valid(v) then return nil, "that isn't a plain https:// link" end
    return v
  end
  return nil, "unknown"
end

-- a: the page's { want } | { set = { id, value, sure } } | { computer = { user, on } } | { phone = true }; here: the page is on this
-- computer (StudioSync_WebUIPollHere). -> words for the log, or nil.
function websettings.action(c, a, here, now)
  if type(a) ~= "table" then return end
  if a.want then S.want, S.at = now + websettings.WANT_FOR, -math.huge end
  local function said(text, bad) S.said = { text = text, bad = bad or nil, at = os.time() }; S.at = -math.huge; return text end
  if a.set == nil and a.computer == nil and a.phone == nil then return end
  -- (decision 4: a phone, or any other device, changes nothing here; the page shows these read only there)
  if not here then return said("the web page's settings change was refused: only from this computer's own page (not a phone or another device)", true) end
  if a.phone then S.phone = now + websettings.PHONE_FOR; S.at = -math.huge; return end
  if type(a.computer) == "table" then
    local ok, w, why = pcall(require("persons").set, c.cfg.root, a.computer.user, a.computer.on == true)
    if not ok then return said("Your computers couldn't be changed: " .. tostring(w), true) end
    return w and said(w) or said("Your computers wasn't changed: " .. tostring(why), true)
  end
  local s = a.set
  local r = type(s) == "table" and type(s.id) == "string" and BY[s.id]
  if not r then return said("the web page asked for a setting StudioSync doesn't know: left alone", true) end
  local may, owner = rights(c.cfg)
  if r.owner and not owner then return said(r.label .. ": only the studio's owner can change that", true) end
  if r.studio and not may then return said(r.label .. ": only the studio's owner or an admin can change that", true) end
  local v, why = websettings.check(r, s.value, c)
  if v == nil then return said(r.label .. ": not changed (" .. tostring(why) .. ")", true) end
  if (r.confirm_on and v == true or r.confirm_off and v == false) and s.sure ~= true then return said(r.label .. ": not changed (it needs a yes first)", true) end
  local ok, w, bad = pcall(r.set, c, v, s.sure == true)
  if not ok then return said(r.label .. ": couldn't be changed: " .. tostring(w), true) end
  if not w then return said(r.label .. ": not changed: " .. tostring(bad), true) end
  return said(w)
end

function websettings.tick(c, publish, now)
  if S.want <= now or now - S.at < websettings.EVERY then return end
  S.at = now
  publish("settings", websettings.model(c, now))
end

function websettings._reset() S = { want = -math.huge, at = -math.huge, phone = -math.huge, said = nil } end
return websettings
