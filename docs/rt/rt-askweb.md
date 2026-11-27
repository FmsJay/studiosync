# rt-askweb: StudioSync's own asks (the big deletion, Undo) on the web view

## Summary for James
Until now only the REAPER panel's bar could answer "Delete 2 of the song's 3 tracks for everyone?" and StudioSync's Undo ask. Someone working from the web page with REAPER's window hidden saw nothing: no answer kept the tracks (safe), but it was confusing. Now the web page's Session > Who's here lists both asks beside the claim asks (Release / Keep), with the same words and a countdown, and a page on this computer can answer Yes or No. A phone or another device sees the words and "Answer this in StudioSync on the computer itself", with no buttons, and the computer would refuse an answer from it anyway (they change the studio for everyone).

## Commits
See `git log` for "rt-askweb". One commit: lib/claimask.lua, lib/webui.lua (two lines of mine only; the other agent's uncommitted reorder of two ACTIONS lines stays uncommitted), lib/webui/play.js, the two tests and this file.

## What was built
- `claimask.local_asks(proj)`: the pending delete ask (`big_pending`) and Undo ask (`undo.pending`) as `[{ kind = "delete"|"undo", id, text, till }]` (`till` is an os.time(), as the claim asks'; the page counts down). An ask past its time is not listed.
- `claimask.web_local(proj, a, here)`, reached through `claimask.web_action(cfg, b, a, proj, here)` when the action carries `ask`: payload `{ topic = "claimask", ask = "delete"|"undo", id, yes }`. It writes the very ExtState the panel's bar writes (`delete answer <proj>` / `undo answer <proj>` `{ id, yes }`; Undo's No is `undo.clear`, as the bar's), which Live sync's `claimask.tick` carries out. So the panel and the page are one path: whichever answers first wins (an answer already written is not replaced: "it was answered already"), and the other UI clears when Live sync resolves it and the ask leaves ExtState (the presence topic is rebuilt every second).
- Refusals, all said in the log, nothing written: not a page on this computer (`reaper.StudioSync_WebUIPollHere() == 1`, passed from lib/webui.lua; unknown counts as not here); the ask has run out or the id is another ask's; a kind that isn't one. Only `yes == true` is Yes.
- lib/webui.lua: the presence build adds `pm.asks.local_asks`; the `claimask` action passes `proj` and the here flag.
- lib/webui/play.js `asks()`: after the claim asks, one `li.ask.localask` per local ask with the countdown (the existing `askTill`) and Yes / No (disabled once pressed, enabled again if the POST fails); on `ssEnv.where === 'remote'` the text plus the "answer on the computer" line, no buttons.

## Not done: the strip
The claim asks don't show on the strip or the top bar today (only on Session > Who's here), so the local asks don't either. A person on another page (Project, Mixer) does not see the ask until they open Session; the 30 s ask waits and no answer keeps the tracks.

## Tests
- `tests/test_0_60_rt_askweb.lua` (in `tests/run.py`): the list (empty, delete, Undo, expiry), a phone refused (false and unknown), another id and a bad kind ignored, a text "true" is No, Yes to the delete ask written once (a second answer refused) and carried out by `claimask.tick` into `big_delete == true`, No into `false`, Undo Yes written and No clearing the ask, answers after the time ignored, and the wiring in lib/webui.lua and play.js.
- `tests/rt_askweb_browser.mjs` (needs Chrome; two pages): on this computer both asks listed with the claim ask, the words, Yes / No, the countdown, Yes to the deletion and No to Undo sent with their ids, an ask answered elsewhere leaves the list; on a phone page (remote host) the words and the "computer itself" line, no buttons, nothing sent.

## Checks for James (on the real computers)
1. On the desktop, open the web page in a browser on the desktop (Session > Who's here), hide or minimise REAPER's StudioSync panel. In a 3-track song with a bandmate in the room, select 2 tracks in REAPER and delete them: the page lists "Delete 2 of the song's 3 tracks for everyone?" with a countdown, Yes and No. Press Yes: the tracks are gone for the bandmate. Repeat and press No: they come back on yours. Repeat and press nothing: back after 30 s.
2. Press the panel's Yes/No on one ask and watch the web page: the line leaves the list within a second or two. Press the page's button, then check the panel's bar clears.
3. StudioSync's Undo (ctrl+Z script, or the panel's Undo) when a bandmate changed the same thing since: the page lists the Undo question; Yes does the Undo, No leaves everything as it was.
4. Open the page on the phone (over the tailnet) during one of those asks: it shows the question and "Answer this in StudioSync on the computer itself", with no buttons.
5. Open the page from the laptop's browser to the desktop's address: same as the phone (no buttons).

## Recommendations
1. Show a "question waiting" mark on the strip and the top bar for every ask (claim, delete, Undo) so a person on the Project page sees it; one `T.presence.asks` count in `stripWords` would do.
2. Floor for the big-deletion ask (James to decide, rt-sync2c recommendation 4): with one or two tracks any deletion is "half".
3. The Undo ask's text on the page doesn't say which key repeats it (the panel's log line does); not needed on the web.
