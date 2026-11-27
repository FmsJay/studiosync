-- Health and Log in the web UI (rt-ui4: docs/rt/ui-web-plan.md Phase 4, 2.8; findings item 16). Covers: which rows the page shows with each
-- switch (Show hidden, Show messages about other scripts; red ones always) and what lights Health's dot; a row's button label and whether only
-- this computer may press it; lib/compat.lua's rows marked other; page_health.web_act running the panel's own functions and refusing unknown
-- ids, and ids a phone may not press (nothing runs); the health topic's Hide / Show again, the switch, Send feedback (this computer only, size
-- limits) and Log (the log topic, Log files from this computer only). No REAPER: a stand-in. Lupa, repo root.
package.path = "lib/?.lua;" .. package.path
local clock, ext, here = 1000, {}, true
local ran, opened, cmds = {}, {}, {}
reaper = setmetatable({
  time_precise = function() return clock end,
  GetOS = function() return "Win64" end,
  GetAppVersion = function() return "7.27/win64" end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  DeleteExtState = function(s, k) ext[s .. "/" .. k] = nil end,
  GetResourcePath = function() return "C:/res" end,
  RecursiveCreateDirectory = function() return 1 end,
  StudioSync_WebUIPollHere = function() return here and 1 or 0 end,
  AddRemoveReaScript = function(add, sec, path) cmds[#cmds + 1] = path; return 4242 end,
  Main_OnCommand = function(id) ran[#ran + 1] = "command " .. id end,
}, { __index = function(_, k) return function() return "" end end })
local band = require("band")
local logged = {}
band.log = function(s) logged[#logged + 1] = s end
band.open_url = function(u) opened[#opened + 1] = u end

-- ---- 1. which rows show with each switch, and Health's dot ----------------------------------------------------------------------------------
local webpages = require("webpages")
local shows = webpages.health_shows
local R = { plain = {}, hidden = { hidden = true }, other = { other = true, level = "yellow" }, redother = { other = true, level = "red" },
  okother = { other = true, ok = true } }
local want = { -- show_hidden, show_other -> plain, hidden, other, redother, okother
  { false, true, { true, false, true, true, true } },
  { true, true, { true, true, true, true, true } },
  { false, false, { true, false, false, true, false } },
  { true, false, { true, true, false, true, false } },
}
for _, w in ipairs(want) do
  for i, k in ipairs({ "plain", "hidden", "other", "redother", "okother" }) do
    assert(shows(R[k], w[1], w[2]) == w[3][i], string.format("%s with Show hidden %s, other scripts %s", k, tostring(w[1]), tostring(w[2])))
  end
end
assert(shows({ hidden = true, other = true }, true, false), "a hidden row of another script's: Show hidden shows it (with Show again)")

package.loaded.sync, package.loaded.services, package.loaded.theme = {}, {}, { GREEN = 1, YELLOW = 2, GREY = 3, RED = 4 }
local setup_calls = {}
package.loaded.setup = { all = function(cfg, b, proj, st, start, play) setup_calls[#setup_calls + 1] = { cfg = cfg, proj = proj, st = st, play = play }; return { "Syncthing started" } end }
package.loaded.undo = { key_name = function() return "Ctrl+Z" end, bind_keys = function(dir) ran[#ran + 1] = "keys " .. tostring(dir) end }
package.loaded.tools = { update_reaper = function() ran[#ran + 1] = "update reaper"; return "opened the REAPER Update Utility" end }
local H = require("page_health")
local function a(name) return { name, function() ran[#ran + 1] = name end, "tip" } end
local ROWS = {
  { "audio", true, "red", "Audio device is running", "closed" },
  { "folder", false, "red", "fine", "Syncthing isn't running" },
  { "conflicts", false, "yellow", "", "2 files", action = a("Show it") },
  { "skipped", false, "yellow", "", "1 change", action = a("Try again") },
  { "colours", false, "yellow", "", "alike", action = a("Pick one for me") },
  { "keys", false, "yellow", "", "Ctrl+Z rolls back" },
  { "tailnet", false, "yellow", "", "another network", action = a("Switch to Chilio") },
  { "relay", false, "yellow", "", "through a relay" },
  { "compat", true, "yellow", "checks pass", "need a look", ok_action = a("Check again"), other = true },
  { "compat script X", false, "yellow", "", "X clashes", other = true },
  { "compat red", false, "red", "", "X breaks sync", other = true },
  { "connected", false, "grey", "", "nobody online" },
}
local cfg, b = { root = "S", user = "James" }, { song = "Song", room = "main" }
H.init({ b = function() return b end, cfg = function() return cfg end, proj = function() return "P1" end, view = function() return {} end,
  wide = function() return false end, dir = "C:/scripts", ui = { play_shown = function() return false end } })
H.build_rows = function() return ROWS end

local o = { button = H.web_button, remote = H.WEB_REMOTE }
local m = webpages.health_model(ROWS, { relay = true, folder = true }, "0.60.1", "1.0.40", o)
local by = {}
for _, r in ipairs(m.rows) do by[r.id] = r end
assert(m.rows[1].id == "folder" and m.rows[#m.rows].id == "compat", "red first, as the panel lists them; the fine ones last")
assert(by.relay.hidden and not by.folder.hidden and m.hidden == 1, "a dismissed amber row is hidden; a dismissed red one never")
assert(by["compat script X"].other and by.compat.other and by["compat red"].other and not by.relay.other, "other scripts' rows marked")
assert(m.show_other == true and m.other == 0 and m.worst == "red", "switch on: nothing switched off")
assert(by.conflicts.act == "Show it" and by.conflicts.here and by.skipped.act == "Try again" and not by.skipped.here, "a row's button, and only this computer's page may press it")
assert(by.keys.act == "Set Ctrl+Z" and by.keys.here and by.compat.act == "Check again" and not by.compat.here and by.relay.act == nil and by.audio.act == nil,
  "the panel's own buttons: keys' Set, a fine row's Check again; none on a row without one")
local count = function(mm, sh, so) local n = 0; for _, r in ipairs(mm.rows) do if shows(r, sh, so) then n = n + 1 end end; return n end
assert(count(m, false, true) == #ROWS - 1 and count(m, true, true) == #ROWS, "switch on: all but the hidden one; Show hidden: all")
m = webpages.health_model(ROWS, { relay = true }, "v", "x", { other_off = true })
assert(m.show_other == false and m.other == 2 and count(m, false, false) == #ROWS - 3, "switch off: the two amber or fine other rows go (counted); the red one stays")
-- (the dot: without the hidden and switched-off ones)
local amber = { { "compat script X", false, "yellow", "", "X", other = true }, { "relay", false, "yellow", "", "r" } }
assert(webpages.health_model(amber, {}, "v", "").worst == "yellow", "amber rows: amber dot")
assert(webpages.health_model(amber, { relay = true }, "v", "", { other_off = true }).worst == nil, "hidden, and the other script's switched off: no dot")
assert(webpages.health_model({ { "compat red", false, "red", "", "r", other = true } }, {}, "v", "", { other_off = true }).worst == "red", "a red other row lights it anyway")

-- lib/compat.lua's rows are all marked other
local compat = require("compat")
local crows = compat.rows_from({ at = os.time(), items = { { id = "hook", ok = true }, { id = "first", ok = false, level = "yellow", text = "t" } },
  clash = { { name = "Grid.lua", kinds = { grid = { "grid", "fix" } } } } }, { events = {} }, nil, os.time(), {})
assert(#crows >= 3, "the self-check's rows")
for _, r in ipairs(crows) do assert(r.other == true, "other: " .. tostring(r[1])) end

-- ---- 2. web_act: the panel's own functions; unknown ids and a phone's unsafe ones refused ---------------------------------------------------
local function refused(id, h, why)
  local n = #ran
  local said, w = H.web_act(id, h)
  assert(said == nil and w and w:find(why, 1, true) and #ran == n and #setup_calls == 0, tostring(id) .. ": refused (" .. tostring(w) .. ")")
end
for _, bad in ipairs({ "nope", "relay", "audio" }) do refused(bad, true, bad == "nope" and "no such row" or "no button") end
refused(nil, true, "not a button"); refused(5, true, "not a button"); refused("", true, "not a button"); refused(("x"):rep(201), true, "not a button")
for _, id in ipairs({ "conflicts", "keys", "tailnet", "@setup", "@update", "@update reaper", "nope", "compat script X" }) do refused(id, false, "only from this computer") end
assert(#cmds == 0, "nothing registered for a phone's Update")
for id, label in pairs({ skipped = "Try again", colours = "Pick one for me", compat = "Check again" }) do
  H.maint_at = 5
  local said = H.web_act(id, false)
  assert(said == label and ran[#ran] == label and H.maint_at == 0, id .. ": a phone may press it, and it ran (built again after)")
end
assert(H.web_act("conflicts", true) == "Show it" and ran[#ran] == "Show it", "this computer: any row's button")
assert(H.web_act("keys", true) == "Set Ctrl+Z" and ran[#ran] == "keys C:/scripts", "keys: Set binds them, as the panel's button")
local said = H.web_act("@setup", true)
assert(said == "Set up: Syncthing started" and #setup_calls == 1 and setup_calls[1].proj == "P1" and setup_calls[1].cfg == cfg and setup_calls[1].play == false,
  "Set up everything I can: setup.all with the tab in front")
assert(H.web_act("@update reaper", true) == "opened the REAPER Update Utility" and ran[#ran] == "update reaper", "Update REAPER")
assert(H.web_act("@update", true) == "Update StudioSync" and cmds[1] == "C:/scripts/StudioSync - Update.lua" and ran[#ran] == "command 4242", "Update StudioSync: the script as an action")

-- ---- 3. the health topic's actions -----------------------------------------------------------------------------------------------------------
package.loaded.status = { gather = function() return { rows = {} } end }
local P = "P1"
local function act(t) t.topic = "health"; return webpages.action(P, cfg, b, t) end
here = false
local n = #ran
said = act({ act = "tailnet" })
assert(said:find("refused", 1, true) and said:find("only from this computer", 1, true) and #ran == n, "a phone's unsafe button: refused, said, nothing ran")
said = act({ act = "skipped" })
assert(said == "Try again, from the web page" and ran[#ran] == "Try again", "a phone's safe one runs")
here = true
said = act({ act = "conflicts" })
assert(said == "Show it, from the web page", "this computer's page: " .. tostring(said))
assert(act({ act = { "x" } }):find("not a button", 1, true), "not a string: refused")
-- Hide / Show again (the panel's dismissed list)
assert(webpages.dismissed_with("a|b", "c", true) == "a|b|c" and webpages.dismissed_with("a|b", "a", true) == "a|b", "hide: added once")
assert(webpages.dismissed_with("a|b|c", "b", false) == "a|c" and webpages.dismissed_with("a", true, false) == "", "show again: one, or all")
assert(webpages.dismissed_with("", "x|y", true) == nil and webpages.dismissed_with("", ("x"):rep(201), true) == nil and webpages.dismissed_with("", 5, true) == nil
  and webpages.dismissed_with("", true, true) == nil, "not an id: nothing")
local full = {}
for i = 1, webpages.HIDE_MAX do full[i] = "r" .. i end
assert(webpages.dismissed_with(table.concat(full, "|"), "more", true) == nil, "at most HIDE_MAX hidden")
act({ hide = "relay" }); act({ hide = "conflicts" })
assert(ext[band.SECTION .. "/dismissed"] == "relay|conflicts", "hidden: " .. tostring(ext[band.SECTION .. "/dismissed"]))
act({ show = "relay" })
assert(ext[band.SECTION .. "/dismissed"] == "conflicts", "shown again")
act({ hide = "a|b" })
assert(ext[band.SECTION .. "/dismissed"] == "conflicts", "an id with the separator: left alone")
act({ show = true })
assert(ext[band.SECTION .. "/dismissed"] == nil, "Show all")
act({ other = false })
assert(ext[band.SECTION .. "/health other off"] == "1", "the switch off")
-- the topic, as built: the switch off, the last words
local pubs = {}
local function publish(topic, t) pubs[#pubs + 1] = { topic, t } end
act({ want = true })
webpages.tick(P, cfg, b, publish, nil, clock)
local ht
for _, p in ipairs(pubs) do if p[1] == "health" then ht = p[2] end end
assert(ht and ht.show_other == false and ht.other == 2 and ht.said:find("not a button", 1, true) and ht.said_n == 4, "the topic: switch off (2 counted), what the last button said")
for _, r in ipairs(ht.rows) do if r.id == "compat" then assert(r.act == "Check again" and not r.here, "the topic carries the buttons") end end
act({ other = true })
assert(ext[band.SECTION .. "/health other off"] == "", "and on again")

-- Send feedback: this computer's page only, within limits (lib/feedback.lua's save)
local saved = {}
local fb = require("feedback")
fb.save = function(c, kind, title, body, extra) saved[#saved + 1] = { kind = kind, title = title, body = body, extra = extra }; return "S/_band/feedback/x.md" end
fb.system = function() return "- StudioSync test" end
band.activity = function() return { "10:01 sent", "10:00 started" } end
here = false
said = act({ feedback = { kind = "bug", subject = "Hi", body = "x" } })
assert(said:find("only from this computer", 1, true) and #saved == 0, "a phone's report: refused")
here = true
for _, bad in ipairs({ { kind = "rm", body = "x" }, { kind = "bug", subject = ("s"):rep(201) }, { kind = "bug", body = ("b"):rep(8001) },
  { kind = "bug", body = "\255\254" }, { kind = "bug", subject = " ", body = "" }, "x" }) do
  said = act({ feedback = bad })
  assert(said:find("wasn't saved", 1, true) and #saved == 0, "refused: " .. tostring(said))
end
said = act({ feedback = { kind = "feature", subject = "Pop\nout", body = "the mixer\r\nplease\0", log = true } })
assert(said:find("feedback saved in the studio's feedback folder", 1, true) and #saved == 1, "saved: " .. tostring(said))
assert(saved[1].kind == "feature" and saved[1].title == "[Feature] Pop out" and saved[1].body == "the mixer\nplease", "kind, title (no line breaks) and body (no control characters)")
assert(saved[1].extra:find("10:01 sent", 1, true) and saved[1].extra:find("StudioSync test", 1, true), "what it was doing, when asked")
act({ feedback = { kind = "bug", body = "no log" } })
assert(saved[2].extra == "" and saved[2].title == "[Bug] no log", "without it")

-- ---- 4. the Log ------------------------------------------------------------------------------------------------------------------------------
local weblog = require("weblog")
weblog._reset()
pubs = {}
clock = clock + 100
webpages.tick(P, cfg, b, publish, nil, clock)
for _, p in ipairs(pubs) do assert(p[1] ~= "log", "nobody shows the Log: no log topic") end
assert(act({ log = "want" }) == nil, "want: nothing to say")
webpages.tick(P, cfg, b, publish, nil, clock)
local lt
for _, p in ipairs(pubs) do if p[1] == "log" then lt = p[2] end end
assert(lt and lt.lines[1] == "10:01 sent" and lt.lines[2] == "10:00 started" and lt.days == band.LOG_DAYS, "the log topic: newest first, how many days the files keep")
local many = {}
for i = 1, band.LOG_MAX + 20 do many[i] = "l" .. i end
assert(#weblog.model(many, 14).lines == band.LOG_MAX, "at most LOG_MAX lines")
here = false
said = act({ log = "files" })
assert(said:find("refused", 1, true) and #opened == 0, "Log files from a phone: refused")
here = true
said = act({ log = "files" })
assert(said:find("opened", 1, true) and opened[1] == band.log_dir(), "Log files: this computer's folder of log files")
clock = clock + weblog.WANT_FOR + 1
pubs = {}
webpages.tick(P, cfg, b, publish, nil, clock)
for _, p in ipairs(pubs) do assert(p[1] ~= "log", "not asked again for WANT_FOR s: no more") end

-- ---- 5. the page file ------------------------------------------------------------------------------------------------------------------------
local f = assert(io.open("lib/webui/health.js", "rb")); local js = f:read("a"); f:close()
assert(not js:find("innerHTML") and not js:find("eval%(") and not js:find("https?://[%w]"), "health.js: no HTML from data, no eval, nothing from elsewhere")
for _, s in ipairs({ "ssTabs.sub('health', 'checks'", "ssTabs.sub('health', 'log'", "ssTabs.sub('health', 'updates'", "ssTabs.sub('health', 'hear'",
  "ssTabs.sub('health', 'feedback'", "act({ hide: r.id })", "act({ show: r.id })", "act({ other: otherBox.checked })", "act({ log: 'files' })",
  "act({ act: '@setup' })", "act({ act: '@update' })", "act({ act: '@update reaper' })" }) do
  assert(js:find(s, 1, true), "health.js: " .. s)
end
print("ok")
