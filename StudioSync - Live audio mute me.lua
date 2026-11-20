-- @description StudioSync: live audio, mute me on or off (the others stop hearing you; kept on this computer)
-- Live audio is on in every studio: this stops (or starts again) what this computer sends to the bandmates, as the panel's mic button does.
-- Bind it to a key (Actions list > "StudioSync - Live audio mute me" > Add shortcut) or a toolbar button: the button lights while you're muted.
-- (James, rt: lib/liveaudio.lua)
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = dir .. "/lib/?.lua;" .. package.path
if require("fromfolder").handoff(debug.getinfo(1, "S").source) then return end -- (an old copy's button or key: the copy this computer runs from now)
require("liveaudio").action_toggle("mute")
