-- @description StudioSync: live audio, hold to talk (the bandmates hear you while the key is held, even muted or on push-to-talk)
-- Bind it to a key (Actions list > "StudioSync - Live audio hold to talk" > Add shortcut): you're heard while it's held and a quarter of a
-- second after, so the last word isn't cut. Its toolbar button lights meanwhile. Run from a toolbar button or a pad (or without
-- js_ReaScriptAPI, which sees the key let go), it latches: heard until run again. (James, rt: lib/liveaudio.lua)
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = dir .. "/lib/?.lua;" .. package.path
if require("fromfolder").handoff(debug.getinfo(1, "S").source) then return end -- (an old copy's button or key: the copy this computer runs from now)
require("liveaudio").action_hold("talking")
