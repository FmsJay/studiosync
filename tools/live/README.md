# tools/live: StudioSync's live checks, run by agents

James (2026-11-27): "For anything like that you need to build a way to check without me, I shouldn't be needed for anything." A round's
"REAPER checks for James" become **scenarios** here: steps per computer through each real REAPER's dev eval hook, waits on "everything
quiet", read-backs and assertions, a pass/fail table and a JSON report. Results of the first runs: `docs/rt/rt-live.md`.

## Run a set (one command)

```bash
python tools/live/live.py run sync2c          # or sync2d, sync2e, askweb; -k NAME runs only scenarios whose name contains NAME
```

It prints each scenario as it goes, then a table, and writes `tools/live/reports/<set>-<time>.json` (not committed). Exit code 0 when
nothing failed. `--retries N` (default 1) runs a failed scenario again (timing checks under the orchestrator's CPU soaks); the report keeps
every failed try's reason in `retried`.

Before a run:

```bash
python tools/live/live.py up --song "LV Checks"   # who answers, which StudioSync each has on disk, live audio muted/deafened, the song open
python tools/live/live.py song                    # opens the test song everywhere (the desktop makes it the first time; room set to Open)
python tools/live/live.py sets                    # every set and scenario
python tools/live/live.py restart                 # every REAPER restarted at once, never saving (onto a new build); then `song` again
```

`--on d,x` runs without the laptop: a scenario needs the computers in its `needs` and uses those in `wants` when they're there; the
bandmate who edits against the desktop is the laptop when present, else LinuxBox (`B(ctx)` in sets/_lv.py).

After the runs: `python tools/live/live.py song --close` closes the song's tab everywhere without saving and puts back the studio each
computer worked in before (the desktop's is Chilio's). Then suspend LinuxBox: `tools/lab/lab.sh stop x` (or `vmrun suspend`).

## The computers

| Key | Computer | How it's reached | REAPER started by |
|---|---|---|---|
| `d` | desktop (James) | the dev hook's folder on J: | already running (never computer-use `open_application`; `bandtest/deskrun.ps1` puts a REAPER on the hidden desktop StudioSyncQA) |
| `l` | laptop (James-Laptop) | `ssh laptop`, `live_eval.ps1` copied beside the hook | `tools/live/start_laptop.ps1` (`-Restart` to restart it): minimised, no focus, never clicks, the hook with `-nonewinst` once REAPER is up, a stray second REAPER stopped |
| `x` | LinuxBox (the Mac's stand-in) | `ssh studio@<ip>` (`tools/lab/lab.sh ip x`, or `X_IP`), `live_eval.sh` beside the hook | `tools/lab/lab.sh start x`; REAPER: `pkill -TERM -x reaper; ~/start-reaper.sh -new` (no save); its `__startup.lua` starts the hook |

Every transport takes the hook's `dev/.evallock` (shared with every other runner on that computer: `bandtest/run.sh`, `lap_eval.sh`,
`reval.sh`; a lock older than 10 minutes is a dead holder's), waits for a pending `eval.lua`, drops its own with an atomic rename and waits
for `result.txt`. **No answer** in time: it takes its `eval.lua` back (so a REAPER blocked by a dialog doesn't run a stale step later) and the
scenario reads `no answer` in the table, with why (not running, a dialog, the hook stopped, ssh down). Never a pass.

Exactly one reaper.exe per computer. The desktop's StudioSync actions run from its main checkout (`SCRIPTS` in live.py, or
`SS_DESKTOP_SCRIPTS`); the laptop's and LinuxBox's from the studio folder's `_tools/studiosync`.

## Safety, built in

- **Live audio muted and deafened** on every computer before a song opens (`song` sets both, persistently: Live sync turns live audio on as
  it starts, and a VM's input may be the desktop's microphone). Every scenario's setup refuses to run if either is off.
- **The song's room is Open** (claims off): every scenario's setup refuses to run otherwise. Scenarios edit as bandmates with nobody
  answering asks, so in Claims mode an edit to what another computer just changed asks for its auto-claim and is put back 30 s later
  (sync2i ran in "SS Test Project 112326", a Claims room, until rt-fixlive3: a set that doesn't import `SONG` now runs in "LV Checks").
- **Never saves a project.** A tab is left with `Main_openProject("noprompt:...")` (an empty project of this tool's, then the clean tab
  closed); an "older file" is a copy beside the song's own file with a track taken out, deleted afterwards.
- **Cleans up after itself.** Every scenario's tracks are named `LV <scenario> <name>`; after each scenario (pass or fail) they're deleted on
  the first computer, the deletion is waited for everywhere (90 s), and anything still left is deleted where it is. Registered clean-ups
  (Syncthing resumed, the VM's network rules undone, transport stopped, metronome put back) run first.
- **Network and Syncthing only inside the VM**: `sets/_lv.py` `x_syncthing(paused)` (LinuxBox's REST API) and `x_cut(on)`
  (`tools/lab/netlab.sh` block / undo of the desktop's and laptop's Tailscale addresses). Never a real PC's firewall, Tailscale or
  Syncthing settings.
- **Sound**: no scenario plays sound. A "recorded take" is a WAV this tool writes (440 Hz at -30 dBFS) into the project's recording folder,
  placed as REAPER's recording leaves it. The one transport check (c11) plays at 5000 s, past everything, with the metronome off.
- **The web page** is driven with the installed Chrome headless (Playwright `channel="chrome"`, nothing downloaded) with fake media
  devices: no camera or microphone is ever opened. The phone-link token is read in the runner and never printed.

## Writing scenarios

A set is `tools/live/sets/<name>.py`; its docstring's first line is its title. A scenario:

```python
from live import scenario, Skip, Fail, lua_str
from sets._lv import SONG, setup, T, names, add, order, quiet_order, ask_of, answer, ss_undo, sleep

@scenario("c6 two moves at once", "sync2c 6", needs=("d", "l", "x"))
def two_moves(ctx):
    add(ctx, "d", "Drums", "Bass", "Gtr", "Keys")          # tracks "LV c6twomovesat Drums" ... on the desktop, "Insert new track"
    ctx.quiet()                                            # every computer reads the same, unchanged for 6 s
    sleep(17)                                              # past presence.HOLD (15 s): a bandmate's edit to what you just changed is put back by design
    ctx.at_once({                                          # one moment on the studio's shared link clock (direct.shared_now)
        "d": f"LV.move_tracks(P, {names(ctx, 'Keys')}, {lua_str(T(ctx, 'Drums'))}) return true",
        "l": f"LV.move_tracks(P, {names(ctx, 'Drums')}, nil) return true",
    })
    got = quiet_order(ctx)
    ctx.check(got == ["Keys", "Bass", "Gtr", "Drums"], f"order after both moves: {got}")
```

- `ctx.do(w, lua)`: Lua in w's REAPER with `LV` (lua/live.lua) loaded and `P` the song's tab; end with `return LV.out(value)` (JSON back).
- `ctx.quiet()`, `ctx.wait(what, fn, timeout)`, `ctx.at_once({w: lua})`, `ctx.log_marks()` / `ctx.log_since(w, marks)`, `ctx.check(cond, msg)`,
  `ctx.note(text)` (goes in the report), `ctx.cleanups.append(fn)`.
- `raise Skip("why")` for a check that can't be automated or doesn't apply: it reads "couldn't automate" with the reason. Keep that rare and
  specific (what physical thing it needs).
- Edits go through `LV` in undo blocks named as REAPER's own actions name them ("Insert new track", "Remove tracks", "Reorder tracks",
  "Recorded media" ...), so Live sync reads them as a person's. REAPER's actions on selected tracks: `LV.action_on(P, names, cmd)`.
- StudioSync's asks: `LV.asks(P)` (claimask.local_asks), `LV.answer(P, kind, yes)` writes exactly what the panel's bar writes.
- StudioSync's Undo / Redo: `ss_undo(ctx, w[, redo=True])` runs the real Ctrl+Z / Ctrl+Shift+Z scripts on the tab in front (setup puts the
  song in front on every computer).

## Pointing a computer at a newer build

Deploys are the orchestrator's (`bandtest/rt_deploy.sh`: signed, into the studio folder, Syncthing carries it). A REAPER that started before
the files changed refuses to load them ("it changed in the shared folder since you said yes"): restart that REAPER (`start_laptop.ps1
-Restart`; LinuxBox's `pkill -TERM` + `start-reaper.sh`), then `live.py song` again. `live.py up` shows the version on disk; the running
Live sync's version is in its log ("the panel opened (StudioSync x.y.z ...)").

## Files

| File | What |
|---|---|
| `live.py` | the runner: transports, `Ctx`, `up` / `eval` / `song` / `sets` / `run` |
| `lua/live.lua` | the Lua helpers (read the song as data, edits in named undo blocks, logs, events, asks, timed steps, a generated WAV) |
| `sets/_lv.py` | what every set shares: the song, setup, small steps, LinuxBox's Syncthing and network |
| `sets/sync2c.py`, `sync2d.py`, `sync2e.py`, `askweb.py` | the check lists of docs/rt/rt-sync2c.md, rt-sync2d.md, rt-sync2e.md, rt-askweb.md |
| `sets/floor.py` | rt-floor's Live checks (docs/rt/rt-floor.md); refuses to run below the floor build; deletes any test floor file first and after |
| `start_laptop.ps1` | the laptop's REAPER and hook, quietly (`-Restart`) |
| `restart/` | the desktop's restart (`restart_desktop.ps1`, ReaPersona's restart pair from the 11-19/20 rounds: unsaved test projects discarded, never saved) |
