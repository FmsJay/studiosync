**Repo:** `J:\Portable Workstation\DAW\Utility\studiosync-realtime`, branch `realtime`. This is StudioSync, a REAPER collaboration tool: Lua scripts (`StudioSync - Live sync.lua`, `lib/*.lua`), a native extension (`extension/*.cpp`, Windows/Mac/Linux), and a web UI served by the extension (`lib/webui/*`, pages built by `lib/web*.lua` / `lib/page_*.lua`). `docs/realtime-roadmap.md` is the plan; read the sections named in your task first.

**Your doc:** write what you built, how to use it, what's untested and review-later security items to a NEW file `docs/rt/<your-name>.md`. Do NOT edit `docs/realtime-roadmap.md`; I link your file into it.

**Tests:**
- `python tests/run.py --no-luals` must end `fails 0`. Add tests for new logic: Lua tests in `tests/test_0_60_rt_<name>.lua`, native ones beside the existing `tests/*_test.cpp`.
- Web pages: test with the existing stand-in server pattern (see other `tests/test_0_60_rt_*.lua` and how earlier agents ran Chromium/Playwright against a stand-in). Use Chromium fake devices only; never a real microphone or camera.
- Native build (if you touch C++): from PowerShell, `Push-Location extension; & ".\build_windows.cmd"`. It rewrites the tracked `extension/reaper_studiosync-x64.dll`; never commit that file.
- Push, then `gh run watch` CI. GitHub's Mac runner sometimes fails timing tests (rerun with `gh run rerun --failed`).

**Hard rules:**
- Several agents share this worktree. Commit ONLY through a private git index:
  0. Every scratch file you make (private index, commit-message file, temp copies) goes in your OWN folder, `<scratchpad>/<your-name>/`, and carries your name. Agents share the scratchpad: generic names like `idx` or `msg.txt` got overwritten by another agent and a commit went out under the wrong message. Never delete files outside your own folder.
  1. `export GIT_INDEX_FILE=<scratchpad>/<your-name>/index; git read-tree HEAD`
  2. Add only your own changes. Where a shared file has other agents' uncommitted edits, build your blob from `git show HEAD:<file>` plus your hunk (`git hash-object -w` + `git update-index --cacheinfo`).
  2b. **Re-read HEAD right before staging.** For every shared file you change, rebuild your blob from the CURRENT `git show HEAD:<file>` plus your hunk, not from a copy you made earlier. Twice on 2026-11-20 an agent's commit silently dropped another agent's lines by staging a file built from a stale HEAD. After committing, run `git show --numstat HEAD` and check that every deletion in a shared file is yours.
  3. `git write-tree`, then `git commit-tree -p HEAD`.
  4. `git update-ref refs/heads/realtime <new> <old>`; retry from step 1 on a race.
  5. Check `git show --stat`, then push.
  6. Then `unset GIT_INDEX_FILE; git reset -q HEAD -- <exactly the files you committed>`. This keeps the shared index in step; never reset it wholesale.
  
  Never plain `git add`/`git commit`/`git stash`/`git checkout -- <file>`, and never `--no-verify`.
- **Safe file writes:** read a file completely BEFORE opening it for writing. Write the new content to a temp file and `os.replace` it in. Never write a file whose new content is empty or much shorter than before unless deleting it is the point. Example of the bug that emptied the roadmap: `open(w,'wb').write(f(open(w,'rb').read()))` truncates before the read. Prefer the Edit tool for edits.
- Stay in your own files. In shared files (`StudioSync - Live sync.lua`, `lib/webui.lua`, `lib/webui/app.js`, `lib/webui/tabs.js`, `lib/page_health.lua`) make only small additive edits, and say which in your report.
- Don't bump EXT_VERSION / tools.EXT_WANT, commit binaries, install, deploy, or restart REAPER. I release and test in REAPER on the real computers.
- Never drive REAPER on the real computers, click any screen, change firewall/Tailscale/Syncthing settings, or use real mic/camera — unless your task explicitly grants read-only probes. Then every probe is pcall-wrapped AND calls each REAPER/extension function with its full required arguments (check the registration in extension/*.cpp first): an argument-count error shows a modal "ReaScript Error" even inside pcall and blocks that REAPER for everyone.
- Keep the designed security: tailnet-only links, signed messages, per-room permissions (`dawview.may_*`, claims), and size limits on anything received. Don't weaken any check. Security reviews come after all features, so list review-later concerns in your doc instead of redesigning.
- No new third-party dependencies without a strong reason (state the licence).
- Commit message ends with: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`

**Report (short):** what you built, commits, test/CI results, the exact REAPER checks I should run on the real computers, and what's left.
