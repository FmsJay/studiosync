-- Health > Log in the web UI (was the panel's Settings > Console; docs/rt/ui-web-plan.md Phase 4, 2.8; rt-ui4). The "log" topic: StudioSync's
-- own activity lines, newest first (band.activity: what the panel's Console lists, every script's), built only while a page shows the Log (it
-- says so every 10 s on the health topic: lib/webpages.lua hands it here) and published only when it changed. Copy is the page's own. Log
-- files opens the folder of daily log files on this computer, from this computer's page only. GPL-3.0-or-later. (James, rt)
local band = require("band")
local weblog = {}
weblog.WANT_FOR = 30 -- seconds a page counts as showing the Log after it last said so
weblog.EVERY = 1     -- seconds between builds while it shows

local S = { want = -math.huge, at = -math.huge }

-- lines: band.activity()'s, newest first. -> the topic. Pure.
function weblog.model(lines, days)
  local out = {}
  for i, l in ipairs(lines or {}) do if i > band.LOG_MAX then break end; out[#out + 1] = tostring(l) end
  return { lines = out, days = days }
end

-- a: "want" | "files"; here: the page is on this computer (StudioSync_WebUIPollHere). -> words for the log, or nil.
function weblog.action(a, here, now)
  if a == "want" then S.want, S.at = now + weblog.WANT_FOR, -math.huge; return end
  if a == "files" then
    if not here then return "the web page's Log files was refused: only from this computer's own page" end
    reaper.RecursiveCreateDirectory(band.log_dir(), 0)
    band.open_url(band.log_dir())
    return "opened the folder of log files, from the web page"
  end
end

function weblog.tick(publish, now)
  if S.want <= now or now - S.at < weblog.EVERY then return end
  S.at = now
  publish("log", weblog.model(band.activity(), band.LOG_DAYS))
end

function weblog._reset() S = { want = -math.huge, at = -math.huge } end
return weblog
