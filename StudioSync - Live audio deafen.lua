-- @description StudioSync: live audio, deafen on or off (hear nobody and send nothing; kept on this computer)
-- Silences every bandmate coming in over live audio, and what you send, until run again, as the panel's Deafen does.
-- Bind it to a key (Actions list > "StudioSync - Live audio deafen" > Add shortcut) or a toolbar button: the button lights while you're deafened.
-- (James, rt: lib/liveaudio.lua)
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = dir .. "/lib/?.lua;" .. package.path
if require("fromfolder").handoff(debug.getinfo(1, "S").source) then return end -- (an old copy's button or key: the copy this computer runs from now)
require("liveaudio").action_toggle("deaf")
