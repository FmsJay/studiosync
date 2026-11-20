-- @description StudioSync: live audio, talkback (hold to talk to one bandmate only; the others don't hear it)
-- The producer's cue to the player: while the key is held, only the bandmate you last held Talk beside in Chat > Call hears you. Bind it to
-- a key (Actions list > "StudioSync - Live audio talkback" > Add shortcut). From a toolbar button or a pad it latches until run again.
-- (James, rt: lib/liveaudio.lua)
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = dir .. "/lib/?.lua;" .. package.path
if require("fromfolder").handoff(debug.getinfo(1, "S").source) then return end -- (an old copy's button or key: the copy this computer runs from now)
require("liveaudio").action_hold("talkback")
