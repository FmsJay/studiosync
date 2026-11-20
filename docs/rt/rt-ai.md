# AI tools from the web UI (rt-ai, 2026-11-20)

The roadmap's "AI as an optional add-on (James, 2026-11-19)": optional, asks before every use. Lua tests with stand-in programs, the
extension's native web UI test, the real job script run with stand-in programs, and headless Chromium against a stand-in server only. **No
model, local or cloud, was run, loaded or called.** Not run in REAPER yet.

## What it is
- `lib/ai.lua`: the gate, the providers, the background jobs and the result paths, for the web UI's new **AI** page and the panel's
  **Settings > Studio > AI** card. It contains no model code, installs nothing and downloads nothing: it starts only programs the person
  installed and pointed at, and only after a yes. The add-on in `addons/ai/` (REAPER action, Python helper, consent tokens) is unchanged;
  `lib/ai.lua` reuses its mix analysis (`addons/ai/lib/ai_mix.lua`) when that folder is there.
- **Providers**, per feature (`ai.provider`):
  - **tool**: a command-line program on this computer, by path: `demucs` (stems), whisper.cpp's `whisper-cli` plus its `ggml-*.bin` model
    (words), `basic-pitch` (a part to MIDI). Audio stays on this computer.
  - **chat**: an OpenAI-compatible endpoint by address (e.g. the AI Hub, `http://127.0.0.1:4000`; `/v1/chat/completions` is added) and model
    name. Only text goes. "This computer" when the host is 127.x / localhost / ::1, "sent away" otherwise.
  - **none**: not set up; the page says why and the feature can't be asked for.
- **Features:**
  - **Split into stems** of a take (its whole source file) or the project's newest mix (`<Project>/mixes`, as the phone app picks it):
    `demucs -n htdemucs -o <job>/out <file>`; the WAVs are copied to `<Project>/stems/<date> AI <name>/` (where Render stems puts stems;
    Syncthing carries them) and, if ticked, put in as new tracks lined up with the take (same position, length and start in the file), one
    undo step.
  - **Lyrics from a vocal take**: `whisper-cli -m <model> -f <file> -otxt -of <job>/lyrics -np`; the text goes on the **Sheet** page as a new
    hand-added section "Lyrics: <take> (AI)" at the take's bar, through `songsheet.action` (exactly as if typed on the page: your sheet file,
    sent live). Never written over an existing section.
  - **A part to MIDI**: `basic-pitch <job>/out <file>`; the .mid goes to the stems folder and in as a new track at the take's place.
  - **Mix feedback**: the newest mix's numbers (REAPER's LUFS-I, RMS, peak, true peak, crest; plus `ai_mix`'s phase coherence, width,
    spectrum split, tilt, DC and its rule notes when the add-on folder is there and the mix is a WAV) sent as JSON to the chat model; the
    answer goes in the project's chat as "AI (<model>, mix feedback; suggestions only): ...". Nothing is applied.
  - **Session recap** (the last recap's lines, `lib/recap.lua`) and **Take name ideas** (the audio takes' names, places, tracks and sections):
    the same chat path behind the same yes; answers go in the chat, nothing is renamed.
- **The yes** (`ai.ask`, `ai.answer`): asking only makes an ask, with a one-time 16-hex id, good for 2 minutes, listing what goes where
  (file and size, or the exact text sent, up to 1500 characters shown), where it runs, and what comes back. A run starts only on a yes naming
  that id, and only if:
  - the studio's switch is on, at the ask and at the yes (band.json `ai`, off unless true, owner and admins, trusted like every outward
    setting: `groups.ai`, `groups.set_ai`);
  - the yes came from the panel (ExtState, this computer only), or a page on this computer, or, only when this computer allows it ("A yes
    from a phone counts here", off by default), a phone or another device;
  - this computer's AI settings for that feature haven't changed since the ask (else "ask again").
  A yes is used up; every run needs its own. At most 5 asks wait at once.
- **Where a yes came from:** the extension now says whether the action it handed out came from a page on this computer (loopback, not
  through `tailscale serve`): `StudioSync_WebUIPollHere` (extension/webui.cpp, additive). With an older extension every page counts as
  "away", so the yes has to come from the panel (or phones allowed) until the new build ships. No EXT_VERSION bump made (lead's call).
- **Jobs** (`ai.start`, `ai.poll`, `ai.cancel`): each run gets `<StudioSync home>/ai/jobs/<date>-<feature>-<id>/` (this computer's own,
  never the shared folder) and a script there, started hidden through `services.run_hidden`: on Windows PowerShell `Start-Process
  -PassThru` writing `pid.txt` then `exit.txt` (its exit code), stdout/stderr to `out.txt`/`err.txt`, or `pid.txt` = `failed` when it can't
  start; elsewhere `/bin/sh` with `$!` and `wait`. Polled each tick of the tab in front (looking or not): done (results imported in a
  pcall: a bad result fails the job, not the tick), failed (exit code and the error output's last line, addresses shorn of name and
  password), past its time (stems/lyrics 30 min, MIDI 15, chat 5.5; curl's own `-m 300`) stopped, or cancelled (`taskkill /PID n /T /F`;
  `pkill -P n; kill n`; a cancel before the pid exists ends it once the pid appears). The 10 newest finished runs stay listed.
- **Chat requests** are curl (`curl.exe` on Windows 10+, `/usr/bin/curl`): `request.json` posted, `reply.json` and the HTTP status read back
  (2 MB at most), the answer's control characters removed, 4000 characters kept.

## Using it
1. Panel: Settings > Studio > **AI (optional)**. The owner or an admin ticks "AI tools for this studio".
2. Each computer that will run tools sets its own (only in the panel, never from a page): chat model address and name, and/or the paths to
   demucs, whisper-cli + model file, basic-pitch. The card says whether the address is local or sent away.
3. Web UI: **AI** tab. Pick a take (or the newest mix for stems), press **Ask...**. The ask appears with what goes where; **Yes, run it** on
   this computer (or in the panel card's list), or No. Runs show with Cancel; results go where each feature says.

## Files and edits
- New: `lib/ai.lua`, `lib/webui/ai.js`, `lib/webui/ai.css`, `tests/test_0_60_rt_ai.lua`, this doc.
- Shared, small additive edits: `lib/webui.lua` (`ACTIONS.ai`; the `ai` branch in the poll loop passing `StudioSync_WebUIPollHere`; one
  `require("ai").tick(...)` line after `chat.web_tick`), `lib/groups.lua` (`"ai"` in SETTINGS; `groups.ai`, `groups.set_ai`),
  `StudioSync - Panel.lua` (one card in `settings_studio`), `lib/webui/index.html` (ai.css, ai.js), `extension/webui.cpp` / `webui.h`
  (`proxied_req` pulled out of `webui_auth` unchanged; each queued action remembers `local && !proxied`; `webui_poll_here`;
  `StudioSync_WebUIPollHere`), `tests/webui_test.cpp` (three checks).
- Topic `ai`: `{ on, may, me, features = { id, label, input, provider, why, where }, asks = { id, label, sends, to, here, result }, jobs =
  { id, label, state, msg, secs }, note, phone_yes, here_known, takes, mix }` (takes and mix only while a page shows the AI tab). No countdown
  in it, so it doesn't change every tick. Actions on `ai`: `want`, `ask = { feature, take, mix, tracks }`, `yes`, `no`, `cancel`. ExtState
  (this computer): `ai url`, `ai model`, `ai demucs`, `ai whisper`, `ai whisper model`, `ai basic pitch`, `ai phone yes` (kept); `ai asks`
  (Live sync -> panel) and `ai answer` ("<id> yes|no|cancel", panel -> Live sync).

## Tests
- `tests/test_0_60_rt_ai.lua` (stand-in REAPER project, real temp folders, every program played by the test writing pid/exit/output files):
  addresses (local vs sent away, `localhost.evil.com`, `localhost@evil.com`, redaction), provider choice for every feature, the yes rule,
  demucs/whisper-cli/basic-pitch/curl command lines, PowerShell and sh quoting (spaces, apostrophes, trailing backslash), job states, chat
  replies (ok, HTTP error with reason, nothing, junk, too long, too big), error lines; the gate (studio off by default, not set up, unknown/
  MIDI/silly take, an ask runs nothing, a phone's yes refused and the ask kept, unknown id, run out, settings changed, studio switched off
  between ask and yes, no, ASKS_MAX, a phone may ask but not say yes, this computer's page's yes runs, a yes used up, phones allowed, the
  panel's yes through ExtState); jobs (started hidden with the right script, running, done, failed with a redacted reason, failed to start,
  past its time and killed, cancelled with and before a pid, macOS sh and kill, an unreadable result, the list trimmed); results (4 stems
  copied and 4 aligned tracks in one undo, lyrics as a hand section at the take's bar, empty words refused, MIDI track named and placed,
  stems of the newest mix, feedback's request holding only numbers, no password or content in the log, the answer as a chat message, HTTP
  503, curl failing to connect, sent away worded); the page's topic (features, takes, mix, a refusal said, no countdown, stable between
  ticks, quiet when idle).
- `tests/webui_test.cpp`: a link POST is marked not here, this computer's page here, a proxied local one not here (run on spare ports in a
  copy: another agent's server held 47391 at the time). `all ok`.
- The real PowerShell job script, run with stand-in programs (scratch only): arguments with spaces and apostrophes arrive intact, exit 0 and
  3 recorded, a missing program gives `pid.txt` = failed with Windows' reason, a slow one killed with `taskkill /T /F` records exit 1.
- Headless Chromium (phone width, then desktop) against a stand-in server: the AI tab, want with X-StudioSync, the privacy words, a tool not
  set up, local vs sent away badges, the newest mix and takes, no sideways scroll, Ask sends feature/take/tracks and no yes, the ask shows
  what goes where, the pick survives redraws, a phone's yes refused and said with the ask kept, this computer's yes runs, Cancel, No, no page
  errors.
- `python tests/run.py --no-luals`: see the report (other agents' uncommitted work failed two tests in the shared tree at one point; checked
  on HEAD plus these files).

## Untested
REAPER at all; the panel card (compiles only); a real demucs, whisper-cli, basic-pitch or curl run (stand-ins only; no model was started);
the AI Hub's answer shape (OpenAI's `choices[0].message.content` assumed); whisper.cpp builds that only read 16 kHz WAV (recent builds
read WAV/FLAC/MP3 at any rate; an older one fails with its own error); `PCM_Source_CreateFromFile` on a .mid in REAPER; macOS/Linux scripts
beyond their text; `StudioSync_WebUIPollHere` inside REAPER (native test only).

## Review later (security)
- **Project audio to a program:** a tool gets the take's whole source file (beyond the item's trim). Paths are this computer's own, set only
  in the panel, but any program at that path runs with the user's rights, and its output files are imported and synced to the band.
- **Text sent away:** a non-local address over plain `http://` is unencrypted (mix numbers, take and people's names, recap lines). Consider
  requiring https for anything not local.
- **Credentials in the address:** `http://user:pw@host` is redacted in the log, asks and errors, but sits in `run.ps1` on disk and on curl's
  command line (visible to other processes). A key file passed with `-H @file` would be better; no key support was added.
- **Who may ask:** the web token is studio-wide, so any member's phone can reach this computer's AI page and make asks (rate-limited to 5);
  the ask ids are in the `ai` topic every page sees, which matters only when "a yes from a phone counts here" is on. Stems/MIDI tracks added
  by a yes don't go through per-room claims or driver rules (`dawview.may_*`).
- **Answers in the chat** go through `chat.post`, so the studio's alerts (phones, the alerts server) and the API event carry the model's text,
  and a reply naming someone with @ could ping them.
- **Job folders** keep requests, replies and stem copies under `<StudioSync home>/ai/jobs` with no pruning.
- **Add-on code:** `ai_mix.lua` is loaded with `dofile` from `addons/ai/lib` when present (the same trust as StudioSync's own folder).
- With an older extension, no page counts as this computer, so a yes needs the panel (or phones allowed): safe, but say so in Health later.

## REAPER checks (James)
1. After a build with `StudioSync_WebUIPollHere`: web UI AI tab shows "Off for this studio"; panel Settings > Studio > AI: tick it (owner).
   Another member sees the card read-only and the tab says On.
2. Without setting anything: every feature reads "not set up" with its reason; Ask is impossible.
3. Set the demucs path to a program that isn't there, Ask on a take, Yes: the run fails with Windows' "cannot find the file" reason, and
   nothing else happens. Settings changed between Ask and Yes: "ask again".
4. From a phone on the studio link: Ask works, Yes is refused ("doesn't count on <you>'s computer"); the same ask is in the panel card and
   its Yes there runs it. Tick "A yes from a phone counts here": the phone's Yes runs.
5. Only when you choose to run a model (James's rule for local GPU models): set demucs (or whisper-cli + model, basic-pitch) and run each
   once on a short take: stems in `<Project>/stems/<date> AI <take>` and as tracks lined up under the take (one undo); lyrics on the Sheet
   page as a new section at the take's bar; a MIDI track at the take. Cancel a long stems run: the demucs process is gone (Task Manager).
6. Chat model: set `http://127.0.0.1:4000` and a model name; the card says Local. Render a mix, Mix feedback > Ask: the ask shows the JSON
   numbers, no audio; Yes: an "AI (model, mix feedback; suggestions only)" chat message, nothing in the project changed. Set a tailnet
   address: the ask says it leaves this computer.
