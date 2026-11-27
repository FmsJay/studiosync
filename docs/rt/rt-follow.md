# rt-follow: one Follow, the exact view, and "said following but wasn't"

Findings 2026-11-27 items 5 and 12, and the bug "Said 'following' but wasn't actually following for a while". Offline only: nothing was
run on the test computers.

## 1. One Follow (item 12)

Start together / Record together / Stop together, "Play and stop together" and "Watch <name>" are folded into one **Follow**, on the panel's
Play page, the web Play page, and the Follow button on each person's card in Who's here.

You follow one of:

- **Nobody**: your play, stop and view are your own.
- **A person**: their transport (play, pause, stop, jumps while playing, REAPER's Play (skip time selection), Record with your own pre-roll)
  and their view (section 2) and mix (as before). A person's computers are one choice (rt-people's `lib/persons.lua`: two computers are one
  person only when both say so). You follow **their active computer** (the one recording or playing, else the one with the project in front,
  else the latest active; you stay on the one you're on while it still plays), or pick one of theirs (pinned).
- **Everyone (whoever plays)**: the project's "side", with its bars behind (Time-sync, In time, Jam and Real time still set this themselves;
  picking a person or Nobody leaves theirs alone).
- **The driver**: "Always follow the driver", as before.

**Recording together.** The one you follow arms and presses Record (REAPER's own Record, with its own count-in or pre-roll). Everyone
following them **who has a track armed records with them** on their armed tracks, starting where the leader's playhead is now (with their own
record pre-roll counted, as Record together had it: rt-fix6b); anyone with nothing armed plays along and is told so (rt-fix5's NO_ARM line, no
REAPER box). A box, "Record with them on my armed tracks" (on by default; this computer's, kept), makes you always play along instead: a track
armed only for monitoring would otherwise record a take. Stopping: the leader's Stop ends the takes started with them (by position, as
before); your own take is never cut by someone else's start or stop.

**Kept protections.** No modal on a computer with nothing armed (together.armed first); your own time selection comes back at stop after a
skip (together.restore_own); a take you started yourself is left alone; a cue more than 30 s old is ignored.

**Stored in the old keys, so older computers read it as before**: "follow <proj>" holds the computer followed (older leaders see
`st.follow == them` in the status and send their presses and view), "follow driver" and the project's "side" are unchanged. New, read only
by this build: "follow person <proj>", "follow pinned <proj>", "follow state <proj>", "follow no rec". A follow set by an older build (a
computer's name alone) becomes that person's, pinned to that computer, so it stays exactly as it was.

**Old messages are still read.** Start and stop cues from an older computer's Start/Record/Stop together (no `follow` field) fire as they
always did; an older web page's `mate`, `follow`/`bars`, `go` and `skip` are still taken by `webpages.action` (`mate` now goes through the
same Follow); the Song page's Play/Stop (dawview) still sends a band start/stop. Only the buttons are gone from the two Play pages.

## 2. The exact view (item 5)

A view message (over the direct link, `lib/follow.lua send_view`) now also carries, each optional and checked on arrival (`clean_view`):

| field | what | applied on the follower |
|---|---|---|
| `v` | arrange start/end (horizontal zoom and scroll) | as before |
| `vz` | vertical zoom (`vzoom2`, SWS) | `SNM_SetIntConfigVar` + `TrackList_AdjustWindows(true)` |
| `top` | the top track in view and its I_TCPY (px scrolled past) | the arrange's scrollbar (js_ReaScriptAPI, child 1000) moved so that track sits at the same px |
| `ed` | the item open in the MIDI editor | that item opened (40153, selected alone for it), closed (MIDI editor action 2) when theirs closes or you stop following, only if following opened it; never counted as "you are editing" |
| `c`, `p`, `tr`, `it`, `w` | cursors, selection, words | as before (REAPER's "scroll selected tracks into view" only for an older sender without `top`) |
| `ps`, `sn` | play state bits, the shared clock when `p` was read | the first sync (section 3) |
| `fw` | who the sender knows follows it | following is said only when you're in it (section 3) |

**Throttle.** At most 10 a second (`follow.EVERY` 0.1 s), and only on a change; a refresh every second (`KEEP`) for a new follower. Sent only
while someone follows you **or a web page's Project view watches you** (`follow.followers`: status `follow`, `follow_driver` while you drive,
or the new status `watch`).

**Your own input pauses it.** Stopped: a scroll or zoom (as before). Playing: a zoom (REAPER's own scrolling moves the view while playing, so
a plain scroll can't be told from it). Any vertical scroll of yours (REAPER never scrolls vertically by itself). Their play and stop still
come while the view is paused; **Resume** on either Play page or the card's button goes straight back to theirs and syncs the transport again.

**The web Project page.** Its "View" select (Watch <name>) tells Live sync whose view it follows (`{ watch }` on the daw topic, kept like
"I'm looking"); Live sync puts it in the status (`watch`), so that bandmate sends its view over the link; `dawview.cursor_model` uses the fresh
link view over the status file's (a few times a second instead of every Syncthing round) and gives the top track's place, so the page scrolls
vertically to the same track. Horizontal zoom and scroll were already mirrored there.

## 3. The bug: "said following but wasn't actually following for a bit"

Causes found:

1. The panel's button turned to **Following** the moment it was clicked. The leader only sends its view, and posts a cue for each press, once
   it sees in the follower's status that someone follows it; that status takes a link round (or a Syncthing round without the link). Presses
   in that gap never came, while the button said Following.
2. Nothing put the follower's transport **where the leader's already was**: following someone already playing did nothing until their next
   press, so "Following" sat over a stopped REAPER.
3. "follow seen" (the line under their card and on the web page) was filled from any fresh view of theirs, including one sent for someone
   else.

Fix (`follow.state`, `follow.first_cue`, `apply_follow`):

- State is one of off / **waiting** / **live** / paused / slow. **Live** only once their view arrives with your name in `fw` (an older
  StudioSync without `fw`: its view arriving is the sign) **and** your transport has been synced. Until then the panel's button reads
  **Connecting...** (yellow) and both Play pages say "Connecting to <name>... until it does, you aren't following".
- The first sync: their view says they play and you don't: a follow start cue from their position now (on the shared clock, `sn`), through
  Live sync's own cue path; they're stopped and you play: a stop. Never into a take of yours; joining their take mid-way plays along (recording
  together starts with their next Record). Synced again after the link was quiet for 3 s, and after Resume.
- **Slow**: no link view, but their status file carries a view: following over the shared folder, said as such.

## Tests

- `tests/test_0_60_rt_follow2.lua` (new; fails on HEAD: no `follow.fold`/`people`/`set_choice`/`state`, no new view fields): message
  fields and checks; followers incl. a web page's watch; a person's computers folded, the active one; the choice in the old keys, Real time
  left alone; sending with `vz`/`top`/`ed`/`fw`/`sn`; Connecting until they name you, the first sync start then Following, no second sync,
  quiet link -> waiting, slow, back -> stop sync; an older sender; vertical zoom and scroll applied exactly, no 40913, the MIDI editor opened and
  closed, never your editing; pause on your zoom while playing / your vertical scroll, Resume; migration of an older follow and unpinning;
  Live sync's record-with-them and status `watch`; dawview's `watch`, `watched_user` and live views with the top place; the play topic and
  web actions; neither Play page has Start/Record/Stop together.
- Updated for the new model: `test_0_60_rt_follow.lua` (followers by status, fake REAPER calls, "following Bo"), `test_0_60_rt_p7.lua`
  (wording), `test_0_60_rt_answers_skip.lua` (the panel's Play together is gone; an older page's skip still taken),
  `test_0_60_rt_dawview.lua` (the page's want carries `watch`), `test_0_60_rt_fix6b.lua` (pre-roll for a follower who records),
  `test_0_60_rt_webpages.lua` (presence stub for the play topic).

## REAPER and browser re-checks for James

1. **Follow a person.** Desktop: Play page > Follow > pick the laptop's person. The line reads "Connecting to ..." (yellow button on the card)
   for a moment, then "Following ...". With the laptop already playing when you pick it: the desktop starts at the laptop's spot within a
   second. Stop on the laptop: desktop stops at the same spot.
2. **Both of James's computers.** With rt-people's folding on (Home > Your computers), the Follow list shows "James" once, with a second list
   "Their active computer (James-Main) / James-Laptop / James-Main". Press play on the other computer: the follow moves to it (log: "following
   James on ... now"). Pick one: it stays there.
3. **Record together.** Leader arms a track, presses Record (try with REAPER's pre-roll on, and with its count-in on). A follower with an armed
   track records from where the leader's playhead is (take lines up on the timeline); a follower with nothing armed plays along with the NO_ARM
   line and no REAPER box; untick "Record with them on my armed tracks": that follower plays along. Leader stops: all takes end. Check what
   REAPER's own count-in does to the play position the follower sees (not checked offline: GetPlayPosition during REAPER's count-in).
4. **View.** Leader zooms horizontally and vertically, scrolls down to the last tracks, opens a MIDI item: the follower's arrange matches
   (same top track, same track heights), and the same item opens in its MIDI editor; closing it on the leader closes it on the follower. Needs
   SWS (vertical zoom) and js_ReaScriptAPI (vertical scroll) on the follower; without them only those two don't follow.
5. **Pause.** On the follower, scroll vertically, or zoom while playing: "your view is paused"; leader's stop still stops you. Resume: back to
   theirs. A plain horizontal scroll while playing doesn't pause (REAPER's own scrolling).
6. **Web.** Web Play page: the same Follow list, computer list, box and line; no Play/Record/Stop together buttons. Project page > View >
   Watch <name>: the canvas follows their zoom and scroll (vertical to the same track) a few times a second.
7. **Older computer.** Follow a computer still on 0.60.1: Following once its view arrives; its Start together still starts you.

## Untested / limits

- `vzoom2` is set through SWS's config-var setter; whether REAPER 7 keeps vertical zoom per project or as a preference here wasn't checked
  on disk (the corpus's vertical-zoom scripts use exactly this). The MIDI editor's own zoom and scroll aren't mirrored (no API reads them);
  only which item is open.
- Pausing on a horizontal scroll while playing isn't detectable without a mouse/wheel hook (shortcut noted in the code).
- The follower's selection is set to the leader's (as before); a change of yours then reads as editing that selection.
- `follow.fold` uses `lib/persons.lua` when it's there (rt-people's, not committed when this was written); without it each computer is its
  own person.

## Review-later (security)

- View messages now carry the top track's oid, the MIDI editor's item oid, play state and the names of followers; all size- and type-checked
  in `clean_view`; only applied when you chose to follow that computer.
- A followed computer can open a MIDI editor on the follower's REAPER (an item that exists there, by oid) and change its vertical zoom and
  scroll: only while you follow it, and you can stop or pause.
- The first sync fires a start or stop from a followed computer's view message (the same trust as its follow cues today).
- Status `watch` tells bandmates whose view a web page follows; it makes that bandmate send its view over the link.

## Files

Mine: `lib/follow.lua`, `lib/page_play.lua`, `lib/webui/play.js`, `lib/webpages.lua` (the Play topic's model and actions only), the view
parts of `lib/dawview.lua` (`parse` watch, `watched_user`, `cursor_model` live views, the tick's live check) and `lib/webui/daw.js` (watch,
vertical follow), `tests/test_0_60_rt_follow2.lua`, the test updates above, this doc. Small additive edits: `StudioSync - Live sync.lua`
(record with the one you follow, status `watch`, the new follow keys cleared at tab close), `StudioSync - Panel.lua` (the card's Follow
button: through `follow.set_choice`, "Connecting..." until it really follows; its tooltip).
