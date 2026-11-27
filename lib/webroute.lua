-- The web UI's action router for when no Live sync answers (docs/rt/ui-web-plan.md 3.2; Phase 2, rt-ui2). A poll takes an action off the
-- extension's queue, so it can't be left for another script: whoever polls must know every topic. Live sync's front tab polls while it runs
-- (lib/webui.lua's tick, its own dispatch); with no studio project in front Autostart polls (lib/weblobby.lua) and runs the action here:
--   the topics that work with no project (FREE) run, the rest of webui.ACTIONS are a project's ("needs a studio project open here"), and
--   anything else is unknown. webui.parse_action drops an unknown topic silently; this says so in the log, once per topic each time
--   Autostart takes over (a page asks for Health or the call every few seconds, and the log isn't for that). (James, rt-ui2)
local band = require("band")
local webroute = {}
-- (Studio: projects, what's new, studios, pins and stages through "home"; your profile; Ask..., Link and join requests; Open in REAPER / the browser)
webroute.FREE = { home = true, profile = true, invite = true, nav = true }

-- topic: an action's topic; live: a Live sync runs for the front tab. -> "run", "project" (it needs a project and there's none) or "unknown". Pure
-- but for webui.ACTIONS, the topics Live sync takes.
function webroute.rule(topic, live)
  if type(topic) ~= "string" then return "unknown" end
  if webroute.FREE[topic] then return "run" end
  if require("webui").ACTIONS[topic] then return live and "run" or "project" end
  return "unknown"
end

local said = {}
function webroute.reset() said = {} end
-- s: StudioSync_WebUIPoll's JSON; c: { proj, cfg, b, url } (b with no song). -> words for the log, or nil.
function webroute.run(s, c)
  local a = type(s) == "string" and s ~= "" and band.json_decode(s)
  local topic = type(a) == "table" and type(a.topic) == "string" and a.topic:sub(1, 32) or nil
  local r = webroute.rule(topic, false)
  if r == "run" then
    if topic == "nav" then
      return require("webenv").nav_action(a, reaper.StudioSync_WebUIPollHere ~= nil and reaper.StudioSync_WebUIPollHere() == 1, c.url)
    end
    if topic == "invite" then return require("invite").action(c.proj, c.cfg, c.b, a) end
    return require("webhome").action(c.proj, c.cfg, c.b, a)
  end
  local k = r .. "\0" .. tostring(topic)
  if said[k] then return nil end
  said[k] = true
  if r == "project" then return "the web page's '" .. topic .. "' needs a studio project open here: nothing done (open one from the Studio tab)" end
  return "the web page sent an action StudioSync doesn't know ('" .. (topic and topic:gsub("[^%w_%-]", "?") or "no topic") .. "'): left alone"
end

return webroute
