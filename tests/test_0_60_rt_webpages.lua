-- The web UI's Health and Play together pages (lib/webpages.lua) and its Chat's actions (lib/page_chat.lua web_action): the models, what a
-- page may send, who may start and stop (dawview.transport_refusal's rule), building only while a page shows a page, Health from
-- page_health's own build, and a chat action reaching the Chat page's store (scopes, to-dos, links, deleting only your own). Then a link
-- check of the page files. (James, rt)
package.path = "lib/?.lua;" .. package.path
local clock, ext, projext, logged = 1000, {}, {}, {}
local cursor, markers = 12, {}
reaper = setmetatable({
  time_precise = function() return clock end,
  GetOS = function() return "Win64" end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  GetProjExtState = function(p, s, k) return 1, projext[tostring(p) .. "/" .. k] or "" end,
  SetProjExtState = function(p, s, k, v) projext[tostring(p) .. "/" .. k] = v end,
  GetExePath = function() return "C:/REAPER" end,
  GetResourcePath = function() return "C:/res" end,
  GetCursorPositionEx = function() return cursor end,
  EnumProjectMarkers3 = function(_, i)
    local m = markers[i + 1]
    if not m then return 0 end
    return 1, m.rgn, m.pos, m.pos + 4, m.name
  end,
  format_timestr_pos = function(pos) return math.floor(pos / 2 + 1) .. "." .. (pos % 2 == 0 and "1" or "3") .. ".00" end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() return "" end end end })
local band = require("band")
band.log = function(s) logged[#logged + 1] = s end
local webpages = require("webpages")

-- ---- Health's model ---------------------------------------------------------------------------------------------------------------------
local rows = {
  { "audio", true, "red", "Audio device is running", "closed" },
  { "folder", false, "red", "Shared folder is syncing", "Syncthing isn't running" },
  { "relay", false, "yellow", "direct", "through a relay" },
  { "keys", false, "yellow", "", "Ctrl+Z", link = { "Open it", "https://login.tailscale.com/admin/machines" } },
  { "tailscale stays", false, "yellow", "", "signs out", link = { "Not a web link", "C:/x.exe" }, copy = "tailscale up" },
  { "connected", false, "grey", "", "nobody online" },
  "junk",
}
local h = webpages.health_model(rows, { relay = true, folder = true }, "0.59.49", "1.0.15")
local ids = {}
for _, r in ipairs(h.rows) do ids[#ids + 1] = r.id end
assert(table.concat(ids, ",") == "folder,keys,tailscale stays,connected,audio", "what needs you first, a dismissed yellow left out (never a red): " .. table.concat(ids, ","))
assert(h.hidden == 1 and h.worst == "red" and h.ver == "0.59.49" and h.ext == "1.0.15", "hidden count, the worst, the versions")
assert(h.rows[1].level == "red" and h.rows[1].text == "Syncthing isn't running" and not h.rows[1].ok, "a red row: its not-ok words")
assert(h.rows[5].ok and h.rows[5].level == nil and h.rows[5].text == "Audio device is running", "an ok row: its ok words")
assert(h.rows[2].link.url:find("^https://") and h.rows[3].link == nil and h.rows[3].copy == "tailscale up", "only web links; the line to copy")
assert(h.rows[4].level == "grey", "grey: said, not a problem")
assert(webpages.health_model({ rows[3], rows[1] }, {}, "v", "").worst == "yellow" and webpages.health_model({}, {}, "v", "").ext == nil, "worst yellow; no extension")
assert(webpages.health_model({ rows[1] }, nil, "v", "x").worst == nil, "all fine: no worst")

-- ---- Play together's model --------------------------------------------------------------------------------------------------------------
local p = webpages.play_model({ side = "2", cursor = "7", regions = { { name = "Verse", bar = "5" }, { name = "Chorus", bar = "9 beat 3" } }, due = 3.14159,
  last = "James: start", ninjam = true })
assert(p.follow == true and p.bars == 2 and p.may == true and p.why == nil and p.rt == nil, "following 2 bars behind, may start")
assert(table.concat(p.from, "|") == "the edit cursor (bar 7)|Verse (bar 5)|Chorus (bar 9 beat 3)", "start from, as the panel says it")
assert(p.due == 3.1 and p.last == "James: start" and p.ninjam and not p.sonobus, "the count-down, the last, what carries the sound")
p = webpages.play_model({ side = "", cursor = "1", rt = true, refusal = "only the driver starts and stops", due = -1, last = "" })
assert(p.follow == false and p.bars == nil and p.rt and p.may == false and p.why:find("driver") and p.due == nil and p.last == nil, "off, Real time, refused, nothing due")
assert(webpages.bars("3") == 3 and webpages.bars(2.7) == 2 and webpages.bars(-4) == 0 and webpages.bars(99) == webpages.MAX_BARS
  and webpages.bars("x") == nil and webpages.bars(nil) == nil and webpages.bars(0 / 0) == nil, "bars: whole, clamped, or nothing")

-- ---- actions and the tick, against stand-ins --------------------------------------------------------------------------------------------
local rt_on, mode, manages = false, "claims", false
package.loaded.live = { realtime_on = function() return rt_on end, fx = function(_, _, fx) if not fx then return "master", 0 end end, SONOBUS = "SonoBus" }
package.loaded.sync = { authority = function() return function() end, { mode = mode, driver = "Andie" } end }
package.loaded.groups = { may_manage = function() return manages end }
local sent = {}
local together = require("together")
together.go = function(_, _, _, ev) sent[#sent + 1] = ev end
together.bars_before = function(_, _, bars) return bars * 2 end
together.bars_after = function(_, _, bars) return bars * 2 end
local cfg, b, P = { root = "R", user = "James" }, { song = "S", room = "main" }, "P1"

-- Follow each other: the panel's project setting
assert(webpages.action(P, cfg, b, { topic = "play", follow = true }) == nil and projext["P1/side"] == "2", "on, at the panel's 2 bars")
webpages.action(P, cfg, b, { topic = "play", bars = 4 })
assert(projext["P1/side"] == "4", "bars while on: changed")
webpages.action(P, cfg, b, { topic = "play", follow = false })
assert(projext["P1/side"] == "", "off")
webpages.action(P, cfg, b, { topic = "play", bars = 3 })
assert(projext["P1/side"] == "", "bars while off: stays off")
webpages.action(P, cfg, b, { topic = "play", follow = true, bars = 0 })
assert(projext["P1/side"] == "0", "on at 0 bars")
rt_on = true
local said = webpages.action(P, cfg, b, { topic = "play", follow = false })
assert(said:find("Real time mode") and projext["P1/side"] == "0", "Real time mode on: left alone (it follows at 0)")
rt_on = false

-- Play, Record, Stop together: from a region or the cursor, with the page's count-in, click and lag; refused as the Song page's are
markers = { { rgn = false, pos = 1, name = "a marker" }, { rgn = true, pos = 20, name = "Verse" }, { rgn = true, pos = 40, name = "" } }
said = webpages.action(P, cfg, b, { topic = "play", go = "record", from = 2, countin = 2, click = false, lag = 1 })
local ev = sent[#sent]
assert(said == "Record together, from the web page" and ev.type == "start" and ev.rec == true and ev.pos == 40 and ev.countin == 4 and ev.click == nil
  and ev.lag == 2 and ev.lead == "James", "Record together from the second region: " .. band.json_encode(ev))
webpages.action(P, cfg, b, { topic = "play", go = "play", from = 9, countin = 50 })
ev = sent[#sent]
assert(ev.rec == nil and ev.pos == cursor and ev.countin == webpages.MAX_BARS * 2 and ev.click == true and ev.lag == 0, "no such region: the edit cursor; count-in clamped; the click on by default")
webpages.action(P, cfg, b, { topic = "play", go = "stop" })
assert(sent[#sent].type == "stop", "Stop together")
mode = "driver"
local n = #sent
said = webpages.action(P, cfg, b, { topic = "play", go = "play" })
assert(#sent == n and said:find("refused") and said:find("only the driver"), "a driver's room, not the driver: refused")
mode, manages = "admins", true
webpages.action(P, cfg, b, { topic = "play", go = "stop" })
assert(#sent == n + 1, "an admins' room: an admin may")
manages = false
assert(webpages.action(P, cfg, b, { topic = "play", go = "record" }):find("driver and admins") and #sent == n + 1, "an admins' room, not an admin: refused")
assert(webpages.action(P, cfg, b, { topic = "play", go = "rm -rf" }) == nil and #sent == n + 1, "anything else: nothing")
mode = "claims"

-- The tick: nothing built until a page shows a page; Health from page_health's own build, with what the panel would hand it
local inits, builds, gathered = {}, 0, 0
package.loaded.status = { gather = function() gathered = gathered + 1; return { rows = {} } end }
package.loaded.page_health = {
  init = function(env) inits[#inits + 1] = env end,
  maint_rows = function() builds = builds + 1; local e = inits[1]; return { { "same", e.b().song == "S" and e.proj() == "P1" and e.cfg().user == "James" and e.view().rows ~= nil, "red", "it sees the song", "it doesn't" } } end,
  dismissed_set = function() return {} end,
}
local pubs = {}
local function publish(topic, t) pubs[#pubs + 1] = { topic, t } end
webpages.tick(P, cfg, b, publish, nil, clock)
assert(#pubs == 0 and builds == 0, "nobody shows Health or Play together: nothing built")
webpages.action(P, cfg, b, { topic = "health", want = true })
webpages.tick(P, cfg, b, publish, nil, clock)
assert(#pubs == 1 and pubs[1][1] == "health" and pubs[1][2].rows[1].ok and pubs[1][2].rows[1].text == "it sees the song", "Health: page_health's rows, with the song in front")
assert(#inits == 1 and inits[1].wide() == false and inits[1].ui.play_shown() == false, "set up once, as the panel does")
clock = clock + 1
webpages.tick(P, cfg, b, publish, nil, clock)
assert(#pubs == 1, "built again only every HEALTH_EVERY s")
clock = clock + webpages.HEALTH_EVERY
webpages.tick(P, cfg, b, publish, nil, clock)
assert(#pubs == 2 and #inits == 1 and gathered == 2, "and then again (set up once)")
package.loaded.page_health.maint_rows = function() error("boom") end
clock = clock + webpages.HEALTH_EVERY
webpages.tick(P, cfg, b, publish, nil, clock)
assert(pubs[#pubs][2].error:find("boom"), "a build that failed says why")
clock = clock + webpages.WANT_FOR + 1
n = #pubs
webpages.tick(P, cfg, b, publish, nil, clock)
assert(#pubs == n, "not asked again for WANT_FOR s: no more")
webpages.action(P, cfg, b, { topic = "play", want = true })
projext["P1/side"], ext[band.SECTION .. "/together P1"] = "1", "James: start from bar 3"
webpages.tick(P, cfg, b, publish, { mode = "driver", driver = "James" }, clock)
local pj = pubs[#pubs]
assert(pj[1] == "play" and pj[2].follow and pj[2].bars == 1 and pj[2].may and pj[2].from[2] == "Verse (bar 11)" and pj[2].last:find("bar 3") and pj[2].ninjam, "Play together: " .. band.json_encode(pj[2]))
webpages.tick(P, cfg, b, publish, { mode = "driver", driver = "Andie" }, clock + webpages.PLAY_EVERY)
assert(pubs[#pubs][2].may == false and pubs[#pubs][2].why:find("driver"), "who may, from webui's presence build")

-- ---- the Chat page's web actions (lib/page_chat.lua), over a stand-in shared folder ----------------------------------------------------
local fs, removed = {}, {}
band.write_json = function(path, t) fs[path] = band.json_decode(band.json_encode(t)) end
band.read_json = function(path) return fs[path] and band.json_decode(band.json_encode(fs[path])) end
band.files = function(dir, ext_)
  local out = {}
  for path in pairs(fs) do local d, f = path:match("^(.*)/([^/]+)$"); if d == dir and f:sub(-#ext_) == ext_ then out[#out + 1] = f end end
  table.sort(out)
  return out
end
band.subdirs = function() return {} end
band.songs = function() return { "S" } end
os.remove = function(path) removed[#removed + 1] = path; fs[path] = nil; return true end
local live_sent = {}
package.loaded.direct = { send_live = function(_, kind, d) live_sent[#live_sent + 1] = d end, messages = function() return {} end, dispatch = function() end }
package.loaded.alerts = { send = function() end }
package.loaded.api = { event = function() end }
local chat = require("page_chat")
local function list(kind, sc) local t = {}; for path, v in pairs(fs) do if path:find("/" .. kind .. "/", 1, true) and path:find(sc == "band" and "^R/_band/chat/" or "^R/S/chat/") then t[#t + 1] = v end end; return t end
chat.web_action(cfg, b, { topic = "chat", text = "  hello\tband ", scope = "band" })
assert(#list("msgs", "band") == 1 and list("msgs", "band")[1].text == "hello band" and live_sent[1].sc == "band", "a message to the Studio scope, cleaned, over the link too")
chat.web_action(cfg, b, { topic = "chat", text = "x", scope = "../etc" })
assert(#list("msgs", "song") == 1, "a scope that isn't one: This project's")
clock = clock + 5
chat.web_action(cfg, b, { topic = "chat", todo = "retrack the bridge", scope = "song" })
chat.web_action(cfg, b, { topic = "chat", title = "Chart", url = "https://example.test/chart.pdf", scope = "song" })
chat.web_action(cfg, b, { topic = "chat", title = "no url", url = "  " })
local todo, links = list("todo", "song"), list("links", "song")
assert(#todo == 1 and todo[1].done == false and todo[1].user == "James" and #links == 1 and links[1].title == "Chart", "a to-do and a link added (a link without a url isn't)")
local m = require("webui").chat_model(chat.read(cfg, b, "song"), nil, nil, "song")
local tid = m.todo[1].id
assert(tid and tid:match("^%d+%-%d+%-James%-%d+$"), "the to-do's id: its file's name")
clock = clock + 5
fs["R/S/chat/todo/20261119-090000-chilio-1111.json"] = { user = "chilio", text = "theirs", done = false, time = "2026-11-19T09:00:00Z" }
chat.web_action(cfg, b, { topic = "chat", done = "20261119-090000-chilio-1111", on = true, scope = "song" })
assert(fs["R/S/chat/todo/20261119-090000-chilio-1111.json"].done == true and fs["R/S/chat/todo/20261119-090000-chilio-1111.json"].done_by == "James", "anyone ticks a to-do off")
clock = clock + 5
said = chat.web_action(cfg, b, { topic = "chat", delete = { kind = "todo", id = "20261119-090000-chilio-1111" }, scope = "song" })
assert(said:find("only its writer") and fs["R/S/chat/todo/20261119-090000-chilio-1111.json"], "someone else's: not deleted")
chat.web_action(cfg, b, { topic = "chat", delete = { kind = "todo", id = tid }, scope = "song" })
assert(#removed == 1 and removed[1]:find(tid, 1, true), "your own: deleted")
for _, bad in ipairs({ "../../x", "a/b", "", 5 }) do
  chat.web_action(cfg, b, { topic = "chat", delete = { kind = "msgs", id = bad }, scope = "song" })
  chat.web_action(cfg, b, { topic = "chat", done = bad, on = true, scope = "song" })
end
chat.web_action(cfg, b, { topic = "chat", delete = { kind = "../x", id = tid }, scope = "song" })
assert(#removed == 1, "a made-up id or kind touches nothing")

-- ---- the page files ---------------------------------------------------------------------------------------------------------------------
local function read(path) local f = assert(io.open(path, "rb")); local s = f:read("a"); f:close(); return s end
local index = read("lib/webui/index.html")
for _, f in ipairs({ "tabs.js", "health.js", "play.js", "chat.js", "pages.css" }) do
  assert(index:find('"' .. f .. '"', 1, true), "index.html links " .. f)
  local s = read("lib/webui/" .. f)
  assert(not s:find("innerHTML%s*=%s*[^'\"]") and not s:find("eval%(") and not s:find("https?://[%w]"), f .. ": no HTML from data, no eval, nothing fetched from elsewhere")
end
assert(read("lib/webui/tabs.js"):find("'X-StudioSync': '1'", 1, true), "tabs.js sends with the header the server wants")
for f, topic in pairs({ ["health.js"] = "health", ["play.js"] = "play", ["chat.js"] = "chat" }) do
  assert(read("lib/webui/" .. f):find("ssTabs.act('" .. topic .. "'", 1, true), f .. ": its actions on its own topic, through tabs.js")
  assert(require("webui").ACTIONS[topic], topic .. ": a topic the pages may send")
end
assert(not read("lib/webui/app.js"):find("topic: 'chat'", 1, true), "the chat is sent from chat.js only")
print("ok")
