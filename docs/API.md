# StudioSync API (for your own scripts)

Your scripts, toolbars and controllers can read what's happening in the session and ask StudioSync to do things. Use it for a
toolbar light that turns red when someone else drives, a Stream Deck page with Take control / Hold / Claim, a ReaLearn
mapping, a script that renders whenever a take lands, or a bot that posts to chat.

Everything goes through REAPER's ExtState, section **`StudioSync API`** (never saved), so Lua, EEL and Python scripts can all
use it, with nothing of StudioSync's loaded. Lua scripts can also load a small helper (below).

API version 1, StudioSync 0.58.64 and later. Fields and verbs are only ever added (the `api` number goes up); none is renamed or removed.

## Reading: who drives, who's here, who claimed what

`GetExtState("StudioSync API", "state")` is a JSON object about the **studio project in front**:

| field | |
|---|---|
| `api`, `version` | the API version, and StudioSync's |
| `song`, `room` | the project and the room you're in |
| `me` | your name in the studio |
| `driver`, `driving` | who drives, and whether that's you |
| `mode` | who can edit: `driver`, `claims` (Driver + claimed tracks), `admins` or `open` (Anyone) |
| `alone` | nobody else is here (you have full control) |
| `here` | the others in the project now, sorted |
| `claims` | `[ { "user": "James", "tracks": ["Gtr", "Keys"] }, { "user": "Sam", "tracks": ["Bass"] } ]`: each person's claimed tracks (always a list, `[]` when nobody has claimed anything) |
| `hold`, `held` | Hold my changes is on, and how many changes it's holding |
| `local_mix` | Keep my mix to myself is on |

`GetExtState("StudioSync API", "beat")` is the `reaper.time_precise()` of Live sync's last look. If it's more than 10 seconds old
(no studio project in front, or Live sync stopped), the state is out of date: treat it as "no session".

## Events: what just happened

`events` is a JSON list of the last 50 events, oldest first, and `event_seq` is the newest event's number. Keep the last number
you saw and look for higher ones.

| kind | fields | |
|---|---|---|
| `driver` | `from`, `to`, `song` | someone else drives now |
| `people` | `joined`, `left`, `song` | who's here changed |
| `sent` | `n`, `song`, `room` | your changes went out |
| `received` | `n`, `song`, `room` | the others' changes came in |
| `chat` | `text`, `user`, `song` | you posted a message |
| `take` | `song`, `room` | you recorded something |
| `mix` | `file`, `song` | a mix was rendered (its file) |
| `hold` | `on`, `song` | Hold my changes was switched |

Every event also has `seq` and `time` (UTC, `2026-11-15T17:30:00Z`).

## Asking StudioSync to do something

Set `request` to one verb. The StudioSync panel carries it out exactly as its own control does, asking first where that control
asks, and opens if it was closed (from the Lua helper; a bare ExtState request waits for the panel to be open).

| verb | does |
|---|---|
| `takecontrol` | Take control |
| `hold` | Hold my changes on/off |
| `claim` | claim the selected tracks |
| `localmix` | Local mixing on/off (off asks whose mix to keep) |
| `keeplocal` | keep the selected (new) tracks on this computer, or share them again |
| `realtime` | Real time mode on/off |
| `undo`, `redo` | your own last change, for everyone (it asks first) |
| `history` | open Restore |
| `chat <text>` | post `<text>` to the project's chat, as you |

Anything else is refused and said in the panel's log. A request changes the session for everyone, just as the button would:
nothing a script can do that you couldn't do in the panel.

## The Lua helper

```lua
local ss = dofile(reaper.GetExtState("StudioSync API", "path"))  -- StudioSync's lib/api.lua (published once Live sync has run)

local s = ss.state()                 -- the table above, or nil when there's no session in front
if s and not s.driving then reaper.ShowConsoleMsg(s.driver .. " is driving\n") end

ss.request("claim")                  -- claim the selected tracks
ss.request("chat Bass is done, have a listen")

-- follow the events in a defer loop
local seq = ss.newest()
local function loop()
  local evs
  evs, seq = ss.events_since(seq)
  for _, ev in ipairs(evs) do
    if ev.kind == "mix" then reaper.ShowConsoleMsg("new mix: " .. ev.file .. "\n") end
  end
  reaper.defer(loop)
end
loop()
```

## A toolbar light (Lua)

```lua
-- On while you're driving: put this script on a toolbar button.
local _, _, sec, cmd = reaper.get_action_context()
local ss -- (loaded once, as soon as StudioSync has published where it is)
local function loop()
  if not ss then
    local path = reaper.GetExtState("StudioSync API", "path")
    if path ~= "" then local ok, m = pcall(dofile, path); ss = ok and m or nil end
  end
  local s = ss and ss.state()
  reaper.SetToggleCommandState(sec, cmd, (s and s.driving) and 1 or 0)
  reaper.RefreshToolbar2(sec, cmd)
  reaper.defer(loop)
end
reaper.atexit(function() reaper.SetToggleCommandState(sec, cmd, 0); reaper.RefreshToolbar2(sec, cmd) end)
loop()
```

## From Python or EEL

```python
import json
st = RPR_GetExtState("StudioSync API", "state")
state = json.loads(st) if st else None
RPR_SetExtState("StudioSync API", "request", "hold", False)
```
