# Installing this build (rt-installer, 2026-11-22)

Once this branch becomes `main` on GitHub (old main kept as `legacy/mirror-sync`), the normal install lines in README "Install" install
it: they read `main/index.xml`, take its newest StudioSync version, download that version's tag, and ReaPack installs the scripts and
the menu extension from the same index. Nothing in the installers names a branch, so nothing changes there at the swap.
What the installers needed, and got: the Hop plug-in (no installer put it in), Mac quarantine marks cleared, and two broken index entries
removed. Plug-in pack, extras and ReaPersona are as before.

## 1. Release it first (James)

The install lines only see a released version. Until then, a fresh install gets old main's 0.59.49.

1. `lib/band.lua`: `VERSION = "0.60.0"`. It has to have three numbers and be above every test build (the test computers run 0.59.49.97),
   and above old main's 0.59.49, so old copies take it as an update. (0.59.49.N stays the test-build form.)
2. Extension: if 1.0.39 lands first, raise it in all three places (`extension/reaper_menu.cpp`, `tools/make_index.py`, `tools.EXT_WANT`)
   and commit all four builds. Now all four binaries are 1.0.38.
3. Hop 0.2.1 builds into `plugin/dist/` (the installers copy them from there; `plugin/build/` stays ignored):
   - `plugin/dist/windows-x64/`: `StudioSync Hop.clap` and the `StudioSync Hop.vst3` folder from `plugin\build_windows.cmd` (`plugin\build\bin`).
   - `plugin/dist/mac/`, `plugin/dist/linux-x86_64/`, `plugin/dist/linux-aarch64/`: the `hop-mac`, `hop-linux-x86_64`, `hop-linux-aarch64`
     artifacts of the latest `plugin` workflow run (`gh run download <run> -n hop-mac -D plugin/dist/mac`, and so on).
4. `python tools/make_index.py --changelog "..."`, then `python tools/release_check.py` must say `ready to release`. It checks the version,
   the extension's three numbers and four binaries, that `lib/files.txt` matches, the Hop builds, and that every index entry points at a
   tag that exists. (make_index signs `lib/files.txt` with `~/.studiosync/update-key` if that file is there. `files.txt.sig` isn't committed
   or served through ReaPack, so this does no harm.)
5. Commit, tag `v0.60.0`, push the tag and the branch. `python tests/run.py --release --no-luals` runs both checks too.

## 2. James's quick test (a fresh computer: Windows Sandbox, a new VM, LinuxBox2's clean snapshot)

1. Run the README install line for that system. Answer: your name; Enter for no invitation (or `s` to start a test studio); plug-in pack
   yes; extras yes; a DAW for ReaPersona (any number).
2. Click through what it says: Windows permission prompts, REAPER's first start ("select audio device": No), ReaPack's windows (OK).
   Sign-ins (Tailscale, Google Drive) can be skipped with a key on a test computer.
3. Restart REAPER once at the end. ReaPack's menu extension and the Hop plug-in load only on the next start.
4. Check: the install window ends `StudioSync 0.60.0 installed`; panel > Settings > Updates shows 0.60.0, and Health has no
   "menu extension older" line (1.0.38); the FX browser finds **StudioSync Hop** (CLAP and VST3); Extensions > ReaPack > Browse packages
   shows ReaPersona 5.47.0 (once it's published) and the three JSFX repositories; the extras show in the FX browser.

## 3. Chilio (MacBook)

- **New to this build, joining a studio:** James sends an invitation from the panel (Invite a collaborator). Chilio copies its **Mac line**
  into Terminal (Cmd+Space, "Terminal") and presses Return. The installer skips everything already installed, adds the Hop plug-in, and pairs
  the studio. macOS asks for his password for some apps and to let REAPER use the microphone: Allow. Then he quits and reopens REAPER.
- **Already set up (his Chilio studio):** see 5. He doesn't need to reinstall. Running the Mac line once more adds the Hop plug-in, which
  ReaPack can't install. Use `BS_HOSTING=later`, so it doesn't ask about a studio:
  `curl -fsSL "https://raw.githubusercontent.com/FmsJay/studiosync/main/installer/install_mac.sh?$(date +%s)" | BS_HOSTING=later bash`
- **Check:** as in 2.4. Hop in the FX browser, Health without red lines.

## 4. What each installer installs

| | Windows | Mac (Apple Silicon or Intel) | Linux (x86_64, aarch64) |
|---|---|---|---|
| Apps | REAPER, Syncthing, SonoBus, Tailscale, Google Drive (winget, else each maker's download) | the same (each maker's .dmg/.pkg) | REAPER, Syncthing, SonoBus, Tailscale (no Drive app) |
| REAPER extensions | ReaPack 1.2.6, ReaImGui 0.10.0.5 + shim, js_ReaScriptAPI 1.310, SWS 2.14.0.7, into `UserPlugins` | the same, `~/Library/Application Support/REAPER/UserPlugins`, quarantine cleared | the same, REAPER's resource folder |
| StudioSync | ReaPack, from `main/index.xml`: the scripts, `lib/` with `webui`, `listen`, `ninjam`, toolbar icons, and **StudioSync menus.ext** (the extension, 1.0.38) | the same (+ `lib/mac` helpers) | the same |
| Hop plug-in (new) | `%LOCALAPPDATA%\Programs\Common\CLAP` and `\VST3` (no admin) | `~/Library/Audio/Plug-Ins/CLAP` and `VST3` | `~/.clap`, `~/.vst3` (none on 32-bit ARM) |
| Plug-in pack / extras | as before: 11 open-source plug-ins; extras NAM, AIDA-X, Odin 2, SnapTune, JC303, RipplerX, Monique, sforzando + Salamander piano + MuldjordKit drums | the same, but sforzando isn't installed (a note says where to get it) | the same where Linux builds exist (no NAM: AIDA-X instead); the piano and drums play in sfizz (a note) |
| ReaPersona | ReaPack repository, set up as the DAW picked | the same | the same |
| Not installed | `tools/` (ears, soak, lab, devices...), `tests/`, `addons/ai` (optional add-on, by hand: its README), `plugin/` sources | | |

## 5. Studios: updates through the folder, signed updates, an old-main install

- **How a computer gets code:** through ReaPack, unless its studio has "Everyone runs StudioSync from the studio's folder" on (Settings >
  Studio). Then every member runs `<studio>/_tools/studiosync`, and whatever version the owner puts there reaches everyone.
  **Chilio's studio has it on, with 0.59.49 in its folder.** So a ReaPack update to 0.60.0 on his Mac changes nothing he runs until James
  puts 0.60.0 in that folder. A newer menu extension does reach him from ReaPack, and also from a folder copy that has it
  (`lib/fromfolder.lua` extension_tick, at his next REAPER restart).
- **Putting a release into a studio's folder** (James, as owner; the folder syncs it to everyone):
  `git archive v0.60.0 | tar -x -C "<studio>/_tools/studiosync"`, then
  `python tools/sign_release.py "<studio>/_tools/studiosync"` for a studio with signed updates (your key in `~/.studiosync/update-key`
  must be the studio's), or add `--unsigned` for one without (Chilio's). Files the old copy had and the new one doesn't stay there:
  delete them by hand if you like (they're unlisted, so they're never loaded as an update).
- **Signed updates for a new studio:** Settings > Studio > Signed updates > Turn on signed updates (owner only, extension 1.0.9 or newer
  on every member). It makes your key, signs the folder copy, and puts the public key in band.json. After that, put each new copy in with
  `sign_release.py`. Smiley Studios already has one. Chilio's studio has none.
- **Old main to this build, on Chilio's computer:** studio folder, `_band`, songs and settings stay as they are (both builds are
  FORMAT 1, same ExtState section `BandSync`). The new extension may load under his old 0.59.49 scripts for a while (ReaPack's 1.0.38,
  before the folder copy changes). 1.0.6 registers no functions for scripts to call (only the menus and the
  toolbar button), so the old scripts don't depend on it. Low risk, but not tested.

## 6. Going back to old main (`legacy/mirror-sync`)

- **A ReaPack install:** Extensions > ReaPack > Browse packages > right-click **StudioSync** > Versions > 0.59.49, and the same for
  **StudioSync menus.ext** > 1.0.6, then Apply and restart REAPER. Right-click > Pin keeps it there. The old versions stay in `index.xml`
  and their tags exist. ReaPack never moves down by itself: 0.60.0 is newer.
- **A studio that runs from its folder:** the owner puts the old build in the folder (`git archive v0.59.49 | tar -x -C ...` and
  `sign_release.py`, as above). Members take a changed folder copy without asking. I didn't test whether they also take an older one
  (Autostart compares "different", not "newer").
