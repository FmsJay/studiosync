# rt-hopvst: try a plug-in you don't have, plus the Hop's limits

James: "VSTs actually loaded to another computer through our plug-in or separate plug-in for testing and trying instruments, changing VST
settings. On a system without the VST they could experiment with it and change the actual VST and plug-in settings." Tracker: "Live hops:
dry instead of silence on a lost frame; bigger budget for long links (both need a Hop plug-in build)".

Native tests, Lua tests with a stand-in REAPER, and headless Chrome against a stand-in server only. **Not run in REAPER; no real plug-in was
loaded and no plug-in window opened anywhere.** Needs a new Hop plug-in build (0.2.0) and a new extension together (see "Pairing").

## What it is

### Try a bandmate's plug-in (`lib/hoptry.lua`, `hops.try` in `lib/hops.lua`)
- **You:** the web UI's new **Try** tab (or the action **StudioSync - Try a bandmate's plug-in**) searches the plug-ins bandmates on the link
  have and you don't (their published lists, `<shared>/plugins/<user>.json`). Pick one: a StudioSync Hop goes at the **end** of the selected
  track (this computer's own FX, never sent), and the bandmate is asked over the direct link (`hop` message, `op = "serve", try = true`).
  - At the end of the chain the track's MIDI reaches the Hop, so an **instrument** works the same as an effect: the MIDI goes with the
    audio and the instrument's sound comes back, in time (see MIDI below).
  - Its **knobs** show on the Try tab as a plain list (name, slider 0..1, the value as the plug-in writes it, a filter box), the first 256.
    Moving one sends `op = "set"` to the owner, who sets it on their copy; the owner's copy sends its knobs back once a second while they
    change (`op = "params"`, also every 5 s anyway). The plug-in's own window exists only on the owner's computer.
  - **Print** records what comes back onto a new track ("<track> - <plug-in> print", fed post-FX from the track) over the time selection
    (or the track's items), playing from 2 s before so the hop is running, with REAPER's time-selection auto-punch; other armed tracks are
    held off and the record mode put back after. The take is named "<plug-in> (via <user>'s computer)". It's ordinary audio in the project.
  - **Stop** takes the Hop out and the owner's hidden track goes.
- **The owner:** nothing loads until they say yes, per bandmate and plug-in, **for this Live sync session** (cleared when Live sync stops).
  The ask shows as a log line, a Health row with **Allow for this session**, and on the Try tab (**Allow** / **No**). Once allowed, the next
  ask (every 3 s) loads it on a hidden track (Hop X, the plug-in by its installed name (VST3 first, then CLAP, VST, AU, LV2, JS), Hop Y), the
  same hidden-track machinery as live hops. **Who is trying which of your plug-ins** shows on the Try tab and in Health, each with **Stop**
  (the yes goes with it; that try is refused from then on, and the requester's try ends and says why).
- Only audio, MIDI and knob values travel. No plug-in file or licence is ever copied anywhere.

### Hop limits (plug-in 0.2.0, `plugin/`, `extension/hopnet.cpp`)
- **A lost frame plays dry**, not silence, when the Hop's "Dry when late" is on: the plug-in publishes it as `dry_lost` in the mapping; the
  network leg fills a lost frame from the send ring (the input) and crossfades back to the return over 64 frames. Hops made by "Run plug-in
  on a bandmate" and tries now set Dry when late on (they were silent).
- **Bigger budget for long links:** the Hop's Latency budget now goes to 32768 samples (680 ms at 48 kHz; was 8192). Live sync raises a hop's
  budget by itself when its measured need is over the budget less 20 ms: to the need + 20 ms in 1024s, only while REAPER is stopped (a PDC
  change mid-play can glitch), kept in the hop's record, logged. Health says so ("gets a bigger budget the next time playback stops", or that
  the link needs more than the most a Hop can wait). An older Hop (max 8192) is detected by reading the knob back and set on its own range.
- **MIDI over a hop:** the plug-in now takes MIDI in and gives MIDI out. Its MIDI goes into `send_midi` under the frame it came at; the network
  leg sends events (short messages only) in their own packets (`T_MIDI`), each at least twice (the next packet's window, or again 20 ms on);
  the remote takes each number once and writes it into Hop X's `ret_midi` at X frame f + A; X plays it with that frame's audio, so the
  instrument after X is driven exactly where the audio would be and its sound comes back under the same frame numbers.

## Pairing
`plugin/hop_shm.h` is version 2 (MIDI rings appended, `dry_lost` in the old reserved space): a 0.1 Hop and a new extension (or the other way)
don't pair, and the hop plays dry. Ship the Hop plug-in build and the extension together, and restart REAPER after installing both.

## Files
- New: `lib/hoptry.lua`, `lib/webui/tryfx.js`, `lib/webui/tryfx.css`, `StudioSync - Try a bandmate's plug-in.lua`,
  `tests/test_0_60_rt_hoptry.lua`, this file.
- Changed (mine): `plugin/hop_shm.h`, `plugin/hop_core.h`, `plugin/HopPlugin.cpp`, `plugin/DistrhoPluginInfo.h`, `extension/hopnet.cpp`,
  `lib/hops.lua`, `tests/hop_test.cpp`, `tests/hopnet_test.cpp`, `tests/test_0_60_rt_hops.lua` (new expectations: dry when late, the Health text).
- Shared, small additive edits: `lib/webui.lua` (`ACTIONS.tryfx`, its action branch, `hoptry.web_tick`), `lib/webui/index.html` (the two
  links).

## Tests
- `tests/hop_test.cpp`: the biggest latency at 32768 with 6000-frame blocks; `dry_lost` follows Dry when late; MIDI in (frames, sizes, a
  SysEx and an out-of-block event left out, published before send_w); MIDI out (at f - off + L to the sample; a late one at its block's start;
  one from before the instance attached never).
- `tests/hopnet_test.cpp` (two endpoints on localhost through the lossy wire): 2% loss each way with Dry when late: no silent frame, every
  lost one dry or fading, nothing wrong; a 300 ms round trip inside a 500 ms budget: 100% exact; MIDI notes every 100 ms through a fake
  instrument that clicks on each note out of Hop X: 26/26 clicks back on their exact frame + L, the remote takes each once; with 2% loss 24/26
  (the other two lost their audio frame). Existing scenarios unchanged; the spike scenario's "no slip" failed once on this loaded desktop and
  passed on the rerun (timing, not this change).
- `tests/test_0_60_rt_hoptry.lua`: search, ranking, knob cleaning, `budget_for`; a try made (Hop at the end, dry); nothing loads before the
  yes (the wait shown on both sides, the Health row's Allow); loaded after it (the VST3, an instrument); knobs out and back (only from the
  requester, only real knobs, 0..1; the song never overwrites them); the page's search, try, stop; the long-link raise only while stopped;
  Print (no selection, not while playing, the track/send/arming/auto-punch, the stop at the end, everything put back, the take's name); the
  owner's Stop and No; a yes ends with Live sync; the page files (links, no innerHTML, no eval, nothing remote).
- Headless Chrome against a stand-in server (1280 light, 390 dark, 300 light): no sideways scroll; the matches, two tries (one waiting), the
  knobs and filter, the asks and uses; each button and a dragged knob send the right action with X-StudioSync.
- `plugin/build_windows.cmd` builds VST3 and CLAP with MIDI in/out on DPF (MSVC); `python tests/run.py --no-luals`: mine all pass (other
  agents' in-progress tests in the worktree fail on their own).

## Check in REAPER (real computers)
1. Install the new Hop (VST3 and CLAP) and the new extension on both, restart REAPER. The Hop's Latency budget goes up to 32768.
2. Desktop: select an empty MIDI track with a few notes; web UI > Try > type part of a laptop-only instrument's name > Try. The laptop logs the
   ask and shows it in Health and the Try tab; nothing loads until Allow. After Allow (within ~3 s) the laptop's hidden track appears
   (Show all tracks): Hop X, the instrument, Hop Y. Play on the desktop: the instrument sounds, in time with the rest (a dry copy of a click
   track lines up).
3. Move knobs on the desktop's Try tab: heard after the round trip, and the laptop's plug-in window (opened there by hand) shows them. Turn a
   knob in that window: the desktop's slider follows within ~1 s.
4. Same with an effect on an audio track.
5. Print over a 10 s time selection: a new "... print" track with one take; it lines up with the source when both play (no comb with the
   Hop's output summed inverted). If it's off by the Hop's latency, the send's PDC isn't what I assumed (see below).
6. Laptop: Stop on the Try tab: the hidden track goes; the desktop's try ends with "Bo stopped it". Ask again: refused at once. Restart Live
   sync on the laptop: asked again.
7. Long link: on a link whose round trip is over ~120 ms, Health's hop row should say a bigger budget comes at the next stop; stop playback and
   the Hop's Latency budget goes up (log line), the row goes green.
8. Lost frames: with a little loss, a dropout is heard as the dry signal for a moment, not a gap.

## Not done / limits
- Print records the track's output through a post-FX send in real time; REAPER's PDC on that send path isn't checked in REAPER (step 5).
  A selection starting at 0 has no lead-in, so its first ~0.5 s plays dry (the hop's play-start pre-roll).
- The Hop doesn't pass its own MIDI input on, and a local instrument before it on the track takes the MIDI first. Short messages only (no
  SysEx). A note-off lost twice in a row can hang a note until the try stops (the hidden track goes).
- Knobs: the first 256 only; values are REAPER's normalized 0..1 (a stepped knob moves in steps there). Parameter lists of plug-ins that
  write meters as parameters change every second and are sent every second (~25 KB).
- One Lua state per computer: a try's hidden track lives in the project in front, like live hops (switching tabs on the owner's computer
  drops it; the next ask rebuilds it).
- The search reads plug-in names from the published lists (lower-case keys, no format); a key that maps to several installed names loads
  the VST3 first.
- MIDI pass-through and stereo-only stay as before; two tries on one track run in series.

## Review later (security)
- `op = "set"` and `op = "params"` trust the `user` field inside a studio-signed message, as live hops already do: any studio member could
  claim to be the requester and turn knobs of a try in progress (not load anything: loading needs the owner's yes for that user and plug-in).
- The owner's yes is keyed by the claimed user name and plug-in key; a guest's asks aren't treated differently (the owner decides).
- Param names and values from the owner are clipped, control characters removed and shown as text only; up to 256 entries and the
  direct link's 64 KB message cap.
- MIDI from the network goes straight to the hidden track's instrument (after numbering and the HMAC tag); only lengths 1-3 are taken.

## Note for the coordinator
The `reaper.StudioSync_HopStatus()` probe in the real REAPERs wasn't from this task: I never ran anything there (no run.sh / lap_eval.sh).
