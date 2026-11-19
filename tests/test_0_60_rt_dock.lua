-- The docked web UI's Lua side and its pages (extension/webui_dock.cpp is tested by tests/webui_dock_test.cpp): the panel's Web UI button
-- (webui.dock: the docked window, the browser with Shift, with an older extension or when the window can't open, saying why), the pages'
-- folder noted for the extension's own action, and a link check of lib/webui (every file the page loads is there, every element app.js
-- looks up is in the page, the Dock / Undock button and the view's channels). (James, rt)
package.path = "lib/?.lua;" .. package.path
local ext, opened, logged, docks, started = {}, {}, {}, {}, 0
reaper = setmetatable({
  time_precise = function() return 1000 end,
  GetOS = function() return "Win64" end,
  GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
  SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
  GetExePath = function() return "C:/REAPER" end,
  GetResourcePath = function() return "C:/res" end,
}, { __index = function(_, k) if not tostring(k):find("^StudioSync_") then return function() return "" end end end })
local band = require("band")
band.open_url = function(u) opened[#opened + 1] = u end
band.log = function(s) logged[#logged + 1] = s end
package.loaded.groups = { sonobus_secret = function() return "sek" end }
package.loaded.direct = { port = function() return 47281 end }
local webui = require("webui")
reaper.StudioSync_WebUIStart = function() started = started + 1; return 1 end
reaper.StudioSync_WebUIPublish = function() end
reaper.StudioSync_WebUIPoll = function() return "" end
reaper.StudioSync_WebUIStatus = function() return '{"listening":true,"port":47281}' end
local cfg = { root = "C:/Studio" }

-- An extension without the docked window: the browser, as before
assert(webui.dock(cfg) == true and opened[1] == "http://127.0.0.1:47281/", "older extension: the browser")
assert(ext["BandSync/web ui folder"] == webui.folder(), "the pages' folder noted for the extension's action")

-- The docked window
local answer = 1
reaper.StudioSync_WebUIDock = function(mode) docks[#docks + 1] = mode; return answer end
opened = {}
assert(webui.dock(cfg) == true and docks[1] == 1 and #opened == 0, "opens the docked window, not the browser")
assert(webui.dock(cfg, true) == true and #docks == 1 and opened[1] == "http://127.0.0.1:47281/", "Shift: the browser, not the window")
answer, opened = -1, {}
ext["BandSync/web ui dock error"] = "The Microsoft Edge WebView2 Runtime isn't installed here"
assert(webui.dock(cfg) == true and opened[1] == "http://127.0.0.1:47281/", "the window can't open: the browser instead")
assert(logged[#logged]:find("WebView2 Runtime isn't installed", 1, true), "and the log says why: " .. tostring(logged[#logged]))
reaper.StudioSync_WebUIStart = function() return 0 end
reaper.StudioSync_WebUIStatus = function() return '{"listening":false,"error":"can\'t listen"}' end
package.loaded.webui = nil
webui = require("webui")
local n = #docks
assert(webui.dock(cfg) == false and #docks == n, "no server: nothing opens, the window isn't asked")
assert(logged[#logged]:find("can't listen", 1, true), "and the log says why")

-- The pages: a link check
local function read(p) local f = assert(io.open(p, "rb"), p); local s = f:read("a"); f:close(); return s end
local html, js, css = read("lib/webui/index.html"), read("lib/webui/app.js"), read("lib/webui/style.css")
local refs = 0
for attr, ref in html:gmatch('%s(%a+)="([^"]+)"') do
  if (attr == "href" or attr == "src") and not ref:find("^%a+:") then
    refs = refs + 1
    local f = io.open("lib/webui/" .. ref, "rb")
    assert(f, "the page loads a file that's there: " .. ref)
    f:close()
  end
end
assert(refs >= 2, "the page's style.css and app.js found: " .. refs)
local ids = {}
for id in html:gmatch('id="([^"]+)"') do assert(not ids[id], "one element per id: " .. id); ids[id] = true end
for id in js:gmatch("%$%('([^']+)'%)") do assert(ids[id], "app.js looks up an element the page has: " .. id) end
assert(ids.dock and html:find('<button id="dock" type="button" hidden>', 1, true), "the Dock / Undock button, hidden in a browser")
assert(js:find("window.chrome.webview", 1, true) and js:find("messageHandlers.studiosync", 1, true), "both views' channels (WebView2, WKWebView)")
assert(js:find("'key:' + e.keyCode + ':'", 1, true) and js:find("send('dock')", 1, true), "the messages extension/webui_dock.cpp takes")
assert(js:find("get('host')", 1, true), "the window says docked or floating in ?host=")
assert(css:find("@media (max-width: 320px)", 1, true), "a compact layout for docker widths")
print("ok")
