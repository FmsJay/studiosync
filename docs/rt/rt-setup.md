# rt-setup: loading safely, the talk mic, missing waveforms, WAV by default, studios with no project open

From James's findings of 2026-11-27 (`docs/rt/findings-2026-11-27.md`): item 14, the talk mic small change, the issue "waveforms not
showing on some tracks", and three "still open" items (REAPER's default recording format, ReaPersona's templates, switching studio with no
project open). Offline only: nothing was run on the test computers and no REAPER was driven. Every REAPER behaviour this relies on is listed
under "REAPER re-checks" below.

## 1. Loading a project safely (item 14)

**What StudioSync did while a project loaded.** Autostart looked at the tabs every 2 s and, for a studio tab it saw for the first time,
switched its live audio off at once (`live.all_off`: deletes ReaNINJAM from the master, takes SonoBus offline) and started its Live sync.
Live sync, as it started, walked every item to set tempo following (`sync.audio_follow_tempo`), and its first tick ran straight away: the
first look (`mirror.watch` over every track), the first catch-up (a second of applying per pass while `sync.loading`), the web UI's reads of
the project, live audio, hops. REAPER's own start reopened every studio tab and preloaded each one in turn (`sync.preload`: up to 20 s a tab
with the screen held). After a first catch-up it ran REAPER's "Peaks: Build any missing peaks" (40047), a modal build of every missing
waveform, front tab only. None of it asked whether REAPER was still loading or saving a project, so on a big session clicked around in as it
opened, StudioSync could read and write a project REAPER was still building (tracks still arriving, its EXTSTATE not read yet), and REAPER
spent long stretches held by a preload or a modal peak build. A look at a half-loaded tab is also docs/rt/rt-reopen.md's candidate A for the
track-deletion bug (records present, tracks not yet).

**Now** (`lib/loadguard.lua`, new):
- `loadguard.busy()`: REAPER is loading or saving a project, any tab (`GetCurrentProjectInLoadSave()` answers then; scripts can run while
  REAPER pumps messages during a big load). Nothing below acts while it's true.
- A tab settles once it has been open `SETTLE` (1.5 s) with REAPER's change count and track count still for `QUIET` (1 s) and the mouse up;
  someone clicking all the time holds it `MAX` (20 s) at most. A load or save while Live sync runs, or another file opened into the tab,
  starts it over. `loadguard.reloaded(proj)` is true once a tab has settled a second time under the same Live sync (something loaded into it
  meanwhile: a revert, the same file opened again) and `loadguard.loaded_at[tostring(proj)]` says when it last settled. **For rt-guard:**
  that's the signal for `W.gone` to treat the next look as a first look (no deletions from it).
- **Live sync** (`StudioSync - Live sync.lua`, small edits): its tick asks `loading()` first and does nothing else until the tab settles
  (its heartbeat goes on, so Autostart doesn't start a second one); the first look, the catch-up, the web UI, live audio and peaks all wait.
  `sync.audio_follow_tempo` moved from Live sync's start to the moment the tab settles (and again after a reload). The 40047 call is gone.
- **Autostart** (`StudioSync - Autostart.lua`, small edits): its look returns early while REAPER is busy; a studio tab is left alone (live
  audio off, Live sync start) until it has been open one look (2 s).
- **REAPER's start** (`lib/startup.lua`): `on_start` waits (deferred) while REAPER is busy, and preloads only the tab that will be in front
  (`startup.preload_this`); the others catch up in their own Live sync once loaded, a second's worth a pass with REAPER free in between.
- **Peaks** (`lib/peaks.lua`, new): built a step a tick in any tab, one take at a time (below, 3).

`StudioSync - Open session.lua` still preloads the song it opens (you asked for it and wait for it; `Main_openProject` has finished loading by
then).

## 2. The talk mic

**Today.** Live audio's Talk is one of REAPER's own device inputs: ExtState `live audio input` (first, 0-based) and `live audio channels`,
read by the extension's audio hook from REAPER's hardware buffers (`extension/rtaudio.cpp`, `on_audio` pre). In Auto, an armed track goes as
Play, and when the talk mic is that track's input the mic goes once, as Play: arming the track your talk mic records into "switches" your talk
into it. The picker was a bare list of inputs labelled "This computer sends".

**Now** (`lib/liveaudio.lua`): the picker is called "Talk mic" (Settings > Studio, and Chat > Call), and each input names the tracks that
record from it ("Input 1 · Guitar (armed)"). When the talk mic is an armed track's input it says so ("your talk goes as part of its playing,
not on its own") with one button, "Talk on Input N instead", for the first input no track records from (outside the talk mic; a stereo talk
mic needs a free pair). `liveaudio.talk_advice` is the pure part; the project's tracks are read once a second for it.

**A second audio device (a USB headset while recording through the interface) needs extension work.** The extension only reads REAPER's own
device. Plan, not built:
1. `extension/rtaudio.cpp`: a capture-only stream on a second device through miniaudio (single header, public domain / MIT-0): WASAPI shared
   mode on Windows (so it sits beside an ASIO interface), Core Audio on macOS, PulseAudio/ALSA on Linux. Its callback writes frames into a
   lock-free single-producer ring.
2. The audio hook (pre) pulls Talk's samples from that ring instead of REAPER's inputs, through an adaptive resampler: the two devices'
   clocks drift (tens to a few hundred ppm), so the ratio is steered by the ring's fill level to keep it near half full; underruns play
   silence and are counted. Play is unchanged (REAPER's armed tracks).
3. API: `StudioSync_LiveAudioDevices()` (JSON: id, name, channels, rate) and `StudioSync_LiveAudioTalkDevice(id, first, nch)` ("" = REAPER's
   device, as today). Status adds the device's rate, drift and underruns for Health.
4. Lua: ExtState `live audio device`; the Talk mic picker lists devices first, then that device's inputs; a device that goes away falls back
   to REAPER's input, said once in the log.
5. Tests: `tests/rtaudio_test.cpp` with a fake device at 48 kHz + 150 ppm feeding the ring for ten simulated minutes: no underruns after the
   first second, fill held within a band. Then REAPER: a USB headset beside an ASIO interface on the desktop, talk heard by a bandmate while a
   track on the interface records, with the round trip measured as rt-audio3 does.
   Risks: shared-mode capture adds about 10-20 ms; the Mac asks for the microphone again only if REAPER doesn't already have it.

## 3. Waveforms not showing on some tracks

Three causes in the code, each fixed:

1. **The web view's Project page kept a take's "no peaks yet" as its waveform for good.** `lib/dawview.lua` `take_peaks` caches each take's
   peaks by take and a signature (file, offset, rate, length). What REAPER answers for a file whose peaks aren't built yet is silence (all
   zeros), and that was cached like a real answer: the take stayed a flat line at every look after, P8's partial read or a whole one, until
   the item itself changed. Now an all-silent answer counts as none (`dawview.flat`), asked again after 5 s, then 10, 20, 40, and every 60 s
   (a take that really is silent costs one read a minute); and the signature includes the source's length, so a take whose file grew or
   came back online under the same name is read again.
2. **REAPER's peak files went through Syncthing.** They're written beside the media in the shared folder (`rooms/<room>/media/peaks/*.reapeaks`
   on the desktop's Cross Test, 11 of them) and nothing ignored them, so every computer's build of the same take met in the shared folder:
   two building at once, one half-written when Syncthing picked it up, Syncthing replacing one REAPER had open. A take could keep a waveform
   built from part of the file, or none, and REAPER doesn't rebuild a peak file it takes for valid. `lib/songsync.lua` now puts
   `(?d)*.reapeaks` first in each block it writes (studio, keep-all-but, guest), so each computer keeps its own; `peaks.purge_once` deletes,
   once per studio on each computer, the peak files already in the studios' project folders (`<studio>/<project>/...`, four levels down,
   never `_band`, `_tools` or anything that isn't `.reapeaks`), from Autostart before any project opens. REAPER builds its own again.
   (A computer keeping every project with none deleted writes no block at all, as before, so its own peak files still go out; nobody else
   takes them now.)
3. **Missing peaks were built by REAPER's modal "Build any missing peaks", front tab only.** After a first catch-up (`sync.receive`) and on
   a computer with no audio device running (Live sync), so a tab behind kept blank boxes and a big song held REAPER in a box. `lib/peaks.lua`
   asks each audio take whether its peaks are missing (`PCM_Source_BuildPeaks` 0, 16 takes a tick) and builds one at a time, a step a tick
   (1 until 0, then 2), in whichever tab asked. The take being built is checked (`ValidatePtr2`, same source) before every step: one deleted by
   a bandmate's change meanwhile is let go, its source never touched again.

## 4. 24-bit WAV for new projects, and ReaPersona's templates

**Where REAPER keeps it.** `reaper.ini`, `[reaper]` section, `reccfg=`: the recording sink's bytes in hex followed by a checksum byte (their
sum's low byte, Windows' WritePrivateProfileStruct format). On the desktop it's `65766177180001CC` ("evaw", 24 bits = base64 `ZXZhdxgAAQ==`).
16-bit FLAC is `63616C661000000005000000AB`. It's a project default (ReaPersona's PROJECT_VARS lists it): asking REAPER for it answers for the
project in front, so it's read from the file.

**Now** (`lib/recformat.lua`, new): set to 24-bit WAV only over nothing or FLAC (another format someone chose stays), and never where this
computer chose FLAC (ExtState `record wav` = "0", Settings > Options > Parts play). Through `set_config_var_string("reccfg", hex, 2)`
(REAPER 7.74 on: persist 2 writes the project default to reaper.ini); the project in front keeps its own format (setting a project default
also sets it in memory). An older REAPER: SWS's `BR_Win32_WritePrivateProfileString`, which REAPER reads at its next start. Run by the
installer's step inside REAPER (`installer/studiosync_setup.lua`, a "recording format for new projects" step, so all three installers) and
once from Autostart (ExtState `default format set`): a FLAC default chosen afterwards stays.

Also: StudioSync's own first open of a song (`StudioSync - Open session.lua`) and its publish (`StudioSync - Publish session.lua`) set FLAC
into the project; both now set `streams.record_want()` (WAV, or FLAC where the computer chose it), as Live sync's `prep.keep_format` already
put it back.

**ReaPersona** (`J:\Portable Workstation\DAW\Utility\reapersona`, local commit `5db1b8d`, no release, no version bump): the 11 DAW
templates (`ReaPersona/templates/*.RPP`) each carried a 16-bit FLAC `RECORD_CFG`, and "New project like ..." opens them with REAPER's
`template:` prefix, so every project made from one recorded FLAC. The block is removed from all 11, `make_templates.lua` strips it after
saving, and `template_from_rpp` drops it from a persona's captured project template (`TEMPLATE_DROP`). A new project from either records as
REAPER's default for new projects does. Left as it was: the "My REAPER's synced look" preference sync still carries `reccfg` between your
computers (a deliberate choice its test holds); with StudioSync setting WAV on each, what it carries is WAV. CHANGELOG has an Unreleased entry.

## 5. Switching studio with no project open

The panel's Studios page (`lib/page_groups.lua` `draw_groups`) and Open on a studio's card already worked in an empty REAPER (the test
draws them: Open on another studio switches `sync_root` and shows its projects). What was missing: on the Projects page with no project open,
the only way back to Your studios was the studio pill at the top, which the panel hides once the studio you were working in is left or
closed, so another studio couldn't be picked. The Projects page now has its own "Your studios" button whenever no project is open, and says
"You've left <studio>, or it was closed" for a studio that's gone. (The web UI has no Studios page and runs only beside a Live sync.)

## Tests (all fail on HEAD before these commits)

- `tests/test_0_60_rt_setup_load.lua`: the guard on tools/bigproject.lua's big project (150 tracks, 4,000 items) through
  tests/fixtures/bigreaper.lua: held while REAPER loads with tracks arriving, through an early click and a held mouse, settled once,
  edits don't hold it after, a save or another file in the tab starts it over (`reloaded`), MAX holds, two cheap calls a tick once settled,
  an older REAPER is never busy; the wiring in Live sync, Autostart and startup; REAPER's start with three studio tabs preloads one; no 40047.
- `tests/test_0_60_rt_setup_mic.lua`: `talk_advice` (who records from each input, the fold, the free input, stereo, MIDI, unarmed) and the
  picker's warning and one-click move.
- `tests/test_0_60_rt_setup_peaks.lua`: silence not kept and asked again with its back-off, a real waveform kept, a new source length read
  again; `(?d)*.reapeaks` first in every block and before the songs in the written file; the purge (what goes, what stays); the peak builder
  (one at a time, steps, MIDI skipped, a take deleted mid-build let go).
- `tests/test_0_60_rt_setup_format.lua`: the ini parse, checksum, kind, decision; set through the API with the project's own format kept,
  through SWS on an older REAPER, a FLAC choice kept, once only; the installer step, Autostart, Open session and Publish.
- `tests/test_0_60_rt_setup_studios.lua`: Your studios and Projects in an empty REAPER on a stand-in ImGui: both studios listed, Open
  switches, the way back, a left studio said.
- ReaPersona `tests/test_core.lua`: a template drops RECORD_CFG; none of the 11 shipped templates has one.

## REAPER re-checks (James, on the real computers)

1. **Load guard.** Open a big studio song (tools/bigproject.lua's, or Cross Test) and click around in the arrange view while it loads. Expect
   no crash; the log's first "live sync for ..." line, then nothing from Live sync for 1.5-2.5 s after REAPER finishes loading. With the
   dev-eval hook, read `reaper.GetCurrentProjectInLoadSave()` during a long load of a big project from another script's defer loop: it
   should answer the project (if defer callbacks never run during a load on that platform, the guard's busy test simply never fires and the
   settle still holds the first look).
2. **Reload under Live sync.** With a song open and Live sync running, File > Revert (or open the same .rpp again): the log says "'<song>' was
   loaded again in its tab: Live sync carries on now it has loaded", and no tracks are sent as deleted.
3. **REAPER's start with several studio tabs.** Close REAPER with three studio songs open; at its start the front one opens caught up
   ("'<song>' is ready: ..."), REAPER answers clicks as soon as the tabs are open, and the tabs behind catch up within their first seconds.
4. **Talk mic.** Settings > Studio > Live audio: the picker is "Talk mic" and names the tracks per input. Arm a track on the talk mic's input:
   the yellow line and "Talk on Input N instead" show; press it; Chat > Call shows Talk and Play going separately.
5. **Peak builder.** On a computer with REAPER's audio device closed (or right after a first catch-up), a bandmate's new take gets its
   waveform within seconds in a tab behind as well as in front, with no modal "Building peaks" box. Read the item's waveform in REAPER.
6. **Peak files.** After the update, the studio's `.stignore` has `(?d)*.reapeaks` right under the block's first line; the log says how many
   peak files were deleted ("peak file(s) that had come from other computers deleted"), once per studio; REAPER redraws those waveforms.
   Syncthing's web UI shows no `.reapeaks` going out afterwards.
7. **Project page.** Open the web UI's Project page while a bandmate records a take: once REAPER has its peaks, the take's waveform appears
   within 10 s (it stayed a flat line before).
8. **WAV for new projects.** After the update starts (or the installer runs), File > New project > Project settings > Media: Recording format
   24-bit WAV. `reaper.ini` `[reaper]` `reccfg=65766177180001CC`. Quit and start REAPER: still WAV (if it went back to FLAC, REAPER rewrote
   its ini from memory and the API call didn't take: tell rt-setup). On a computer set to FLAC in StudioSync (Parts play), nothing changes.
   Check that `set_config_var_string("reccfg", "65766177180001CC", 2)` returns 2 on 7.74+; if it returns 0 (binary config vars refused),
   the SWS path is what set it and takes effect at the next start.
9. **ReaPersona.** Personas > New project like Pro Tools: Project settings > Media shows the default (24-bit WAV), not 16-bit FLAC.
10. **Studios with no project.** Close every project tab (an empty untitled one left), open the panel: Projects shows "Your studios"; it goes
    to the studio cards; Open on another studio shows its projects. Leave a studio you're working in: Projects says so, and Your studios is
    there.

## Untested / left

- Everything above is offline: no REAPER ran. The REAPER behaviours assumed: `GetCurrentProjectInLoadSave` answers during a load or save
  seen from a defer callback; `PCM_Source_BuildPeaks` builds peaks with no audio device running; `set_config_var_string` takes the hex
  `reccfg` value with persist 2; REAPER reads a missing `RECORD_CFG` in a template as the project default.
- The track-deletion guard itself is rt-guard's (`W.gone`); `loadguard.reloaded` is there for it.
- REAPER's own background peak builder (audio running) still runs beside lib/peaks.lua after a catch-up, as it ran beside 40047 before.

## Review later (security)

- `peaks.purge_once` deletes files in the shared folder: only names ending `.reapeaks`, only under a project folder of a studio this computer
  is in, four levels down, once per studio. Syncthing carries those deletions to computers that don't ignore peak files yet (they rebuild).
- `recformat.apply` writes `reaper.ini` through SWS when the API can't: one key in `[reaper]`, a fixed value.

## Shared files touched (small, additive)

- `StudioSync - Live sync.lua`: `loading()` before the tick, tempo following moved into it, peaks' want/tick in place of 40047.
- `lib/sync.lua`: the 40047 call after a first catch-up became `peaks.want` (4 lines).
- `lib/dawview.lua`: `take_peaks` only (rt-follow has uncommitted edits elsewhere in the file; not staged).
- `lib/songsync.lua`: `songsync.PEAKS` first in each block.
- `StudioSync - Publish session.lua`: one line (record format).
