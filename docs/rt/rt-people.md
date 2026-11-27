# rt-people: unread, join asks, Online now, and a person's computers as one

James's findings of 2026-11-27 (`docs/rt/findings-2026-11-27.md`): three bugs and big item 9. Tests: `tests/test_0_60_rt_people.lua`
(each part fails on the code before it).

## 1. Messages shown as unread after being read

**Where "read" lives:** per computer, in REAPER's ExtState, one key per conversation: `chat seen room <song> <room>`, `chat seen song <song>`,
`chat seen band `, `chat seen dm:<id>`, `chat seen ch:<id>`. Each holds the newest message name (its UTC stamp) read there. The counts
(`page_chat.unread_in`) count the files in that conversation's *own* folder newer than its key.

**Causes:**
- **A view showed more than it marked.** This project (where Chat starts, on the panel and the web) shows every room's chat too, and Studio shows
  every project's and room's. Reading them moved only their own key, so the room's messages you had just read still counted on the panel's tab,
  Home, the web's list and the phone. Now `chat.mark_seen` carries the newest to the scopes the view covers (This project: each room of the song;
  Studio: each project and room), once per new message. The panel's Messages tab goes through the same function.
- **The page skipped saying it read.** `chat.js` sent "seen" only while the conversation list said the conversation had unread messages; that list
  trails new messages by up to 5 s, and the page remembered it had "handled" the newest, so a message that arrived just before the list caught up
  stayed unread for good. It now always says so once per newest message (and tries again if the call fails).
- **Newest by time, not by name.** The newest was the last message by the time its writer's clock put in it; the counts compare names. One from a
  bandmate whose clock ran behind could stay unread. Now the newest name.
- **Home's count lagged** up to 25 s after a read (it re-read the chat every 15 s). `chat.seen_gen` moves on each read and Home builds again at once.
- **Your other computer.** With computers folded (item 9): what you read on one counts on the others (`_band/seen/<name>.json`, below), and your own
  messages from your other computer aren't unread to you.

## 2. Asking someone to join a project they're already in

**Cause:** Home put "Ask to join" on every chip in Online now, including people already in your project and room (and your own other computer),
and `invite.ask` sent it without looking. The receiver was offered Join for a project they had open.

**Now:** `invite.ask` refuses when the person (any of their computers, `rooms.people`'s rule: a status under 45 s old, or this computer's open
tab) is in that project and room already, and when it's one of your own computers. The invite topic carries `inside` (who's in your project
now) and leaves your own computers out of `people`; `invite.js` offers no Ask on them. On the receiving side `invite.pending` drops a request for
a project you're in already (here or on another of your computers), and a join message in the chat shows "You're in X already" in place of
Join (`chat_model`'s `inside`).

## 3. Online now: duplicates, and staying after the project was closed

**Causes:**
- Home built one entry per project and room each person had a status in (and each of a person's computers apart), so someone with two projects
  open showed twice. Now `webhome.fold` makes one entry per person: their most telling place shown (yours first; then recording, playing, in
  front, in your project), every other place and computer under it ("also James-Main: T"). Project faces fold the same way.
- Home's freshness went by the writer's own clock (`band.age(st.time) < 45`): a computer whose clock ran ahead stayed "online" for as long as it
  was ahead after closing. Now `webhome.fresh`: gone 45 s after its stamp last changed *here* (presence.peers' rule), so the normal timeout holds
  whatever the clocks say; a clock running behind but still writing stays.

The normal timeout itself is unchanged: a status is fresh 45 s; with the direct link the file is written every 30 s, so someone who closes the
project or REAPER leaves Home within about 15-55 s (Home is built every 10 s while a page shows it).

## 9. A person's computers folded together in a studio

**How a computer maps to a person today:** it doesn't. Every computer is its own studio name (`ExtState "user"`: "James-Laptop", "James-Main"),
with its own status files, events, claims and `_band/devices/<name>.json` (its Syncthing device id, Tailscale name, NAT and signing keys), each
believed only when Syncthing (or its signature) says that computer wrote it (`trust.device_ok`). Nothing linked two names; "James" and
"James-Laptop" were even kept apart on purpose (`sync.is_mine`).

**The link (`lib/persons.lua`):** each computer lists the device ids of its person's other computers in its own devices file (`same`, written by
`removal.publish`). Two names are one person only when **both** files list each other, and each file counts only when its own computer wrote it.
So nobody can fold themselves into someone else (that person's computer would have to name theirs), and trust is not loosened: it is the same
check every devices file already gets. A third computer linked to either joins. A computer's list is `ExtState "my computers"` (kept), and in a
studio it publishes only ids that studio already has a devices file for (a personal computer never goes into a studio it isn't in).

**How to use it:** Home > Online now > "Your computers": each of the studio's computers with "Mine too" (or "Not mine"). Press Mine too for
James-Main on James-Laptop, and for James-Laptop on James-Main; within a devices-file round (30 s, sooner after the press) and a Syncthing hop both
show as one person. A computer that says it's yours shows "says it's yours" and the box opens by itself.

**A person's name:** the first display name any of their computers set (profile), else what their names share before a dash ("James"), else the
first name. Key: their first name sorted.

**Where it shows:**
- Home: Online now (one chip, "(you, on James-Main)" for your own other computer, its places listed), project faces, Your computers.
- Who's here (web, `webui.presence_model`): one entry, "on James-Laptop, James-Main", driver badge if either drives, armed tracks of both.
- Profiles topic: each computer without a display name of its own takes the person's name, the first picture among them and the key's colour, so
  chat authors, claims, mentions and avatars read "James". `@James` mentions both computers.
- Claims (web): "James (James-Main): track Bass".
- Panel's Who's here: cards keep one per computer (follow, listen and produce act on a computer), labelled "James (James-Main)", or "you, on
  James-Main" for your own other computer.
- Health: the direct link's speed line names "James (James-Main)".
- Follow targets: through the profiles names on the web; the panel's follow buttons are rt-follow's (`persons.label(root, user, me)` is there
  for them).

**Read on one, read on all:** a computer that has other computers writes `_band/seen/<name>.json` ({ user, at, seen = { key = stamp } }, at most
300 keys) when it marks something read; its other computers take the newest of their own and these, each file counted only when its own computer
wrote it (`trust.own_file_ok`).

## Files

New: `lib/persons.lua`, `tests/test_0_60_rt_people.lua`, this doc. Mine: `lib/page_chat.lua`, `lib/webhome.lua`, `lib/invite.lua`,
`lib/webui/home.js`, `lib/webui/invite.js`, `lib/webui/chat.js`, `lib/profile.lua`. Small additive edits in shared files: `lib/removal.lua`
(publish `same`), `lib/webui.lua` (presence_model's optional `key_of`, and its call), `lib/webui/app.js` (Who's here names, devices, claims),
`StudioSync - Panel.lua` (a card's `label`), `lib/direct.lua` (speed line names). `lib/files.txt` needs `lib/persons.lua` at release
(tools/make_index.py).

## Re-checks on the real computers

REAPER (James-Laptop and James-Main, one studio, a project open on each):
1. Chat: on the laptop, have someone (or the desktop) post in This room, then open Chat on This project. The panel's Messages count and the web
   Home's "For you" drop to 0 within a few seconds and stay there. Same with Studio. Restart REAPER: still 0.
2. Home > Online now > Your computers: press Mine too for James-Main on the laptop ("waiting"), then for James-Laptop on the desktop. Within about
   a minute both show "yours: shows as you"; `_band/devices/James-Laptop.json` and `James-Main.json` each have a `same` list with the other's id.
3. On a third computer (or the phone's web UI on it): Online now shows "James" once, with the other computer under it; Who's here shows "James
   ... on James-Laptop, James-Main"; chat messages from either read "James"; the panel's cards read "James (James-Main)".
4. On the laptop, read a new message; on the desktop the count drops within ~10 s plus Syncthing's hop (`_band/seen/James-Laptop.json`).
5. Ask to join: Online now has no "Ask to join" on someone already in your project and room, nor on your own other computer. Pick "Ask..." on a
   project row for someone who is in it: Home says they're in it already. Send an ask for project T to someone whose other computer is in T: they
   see no Join bar; their chat shows "You're in T already".
6. Online now duplicates: open two projects on one computer; another computer's Home shows that person once ("also ..."). Close one project:
   the "also" goes within a minute; quit REAPER there: the person goes within about a minute.

Browser: Home's Online now chips, the Your computers box (closed unless a computer says it's yours), Who's here's "on ..." line, the chat author
names. Not run in Chromium here (no stand-in server run for these pages this round).

## Untested / limits

- Not run in REAPER or a browser: the tests drive the Lua over a stand-in folder; the JS edits are small and checked only by reading.
- The panel keeps one card per computer (labelled); folding the cards themselves is item 1's (UI moved to the web) to decide.
- Claims, grants, follow and listen still act per computer: James-Main can't edit a track James-Laptop claimed without asking, as before.
- A display name set on one computer is the person's name only while the other has none; profiles stay per computer.
- Renaming a computer leaves its old `_band/seen` file behind (harmless; not tidied).

## Review later (security)

- `same` lists in devices files tell the studio which computers are one person (device ids it already has). Nothing grants anything on it.
- `_band/seen/<name>.json` shows the studio when a person read which conversation (DM ids included), in the shared folder anyone in the studio can
  read; written only by computers that have other computers. A forged one counts only on the named person's computers if Syncthing says its own
  computer wrote it.
- A person's computers folded by both saying so: someone with access to both of your computers could fold a third of theirs into you only from
  both of yours.
