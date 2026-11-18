# Cross-computer test

`cross_test.lua` runs the same scenario on every computer of a studio at once, through the real Live sync and Syncthing:

1. The desktop clears the project from an earlier run; each computer adds a track with a part (desktop, laptop, Mac in turn), and the others wait for it to arrive.
2. The Mac sets the tempo to 100, then the desktop sets 130 after it: the newest map has to win everywhere.
3. The laptop moves the desktop's part; the desktop deletes the laptop's track.
4. Each computer writes the project's shape (tracks, parts, tempo), and the desktop compares them.

Results go to `<studio>/_crosstest/<run>/` (one file per computer per step), and the desktop writes `summary.md` there:
how long each change took to arrive, anything that never did, and whether every computer ended with the same project.

Roles come from StudioSync names: `James` = A (desktop, shares the "Cross Test" project the first time), `James-Laptop` = B,
`Chilio-Mac` = C. The studio is Smiley Studios. A computer that hasn't started within 3 minutes is left out and its steps skipped.

## Running it

- Start the desktop first: it makes the run. Then the others, within 3 minutes.
- On a computer with the dev hook: `return dofile("<StudioSync folder>/tests/cross/cross_test.lua")`.
- By hand (the Mac): REAPER > Actions > Show action list > New action > Load ReaScript, pick
  `~/Library/Application Support/REAPER/Scripts/StudioSync/StudioSync/tests/cross/cross_test.lua`, then Run.
  Its progress shows in REAPER's console.

Everyone should be on the same StudioSync (Settings > Health), with the clocks set automatically.
