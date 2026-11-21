# rt-p10: joining (2026-11-21)

Backlog package P10 (`docs/rt/backlog.md`, "Plan to finish"): items 1.29, 1.33 and 3.2 (seal). Offline build and tests only; nothing ran in
REAPER. The details, tests and REAPER checks are new rounds in the source docs:

- `docs/rt/rt-joinlink.md` round 2: every room, files over 30 KB, the firewall and Tailscale notes, a new secret sealed.
- `docs/rt/rt-invite.md` round 2: the honest message for a code link that can't work, one link per click, the xdg-mime default.

## Per item

| Item | Result |
|---|---|
| 1.29 The first copy for the current song's main room only | **Fixed**: every room of the song (main, then side rooms not binned), each into its own inbox, the media of all of them once each. Other songs still come with Syncthing. |
| 1.29 band.json and session.json must fit in 30 KB | **Fixed** for a joiner on this build: a welcome up to 240 KB, files up to 256 KB, sealed and sent in rt-p3's parts (`signed.pieces` / `signed.collect`). An older joiner: 30 KB, as before. |
| 1.29 A Windows joiner without the firewall rule hears nothing | **A note**, once, naming Health's direct-link row (the joiner is let in all the same; Syncthing brings the studio). Also a note for a joiner off the inviter's Tailscale network (LinuxBox2 in `nat` mode), which was silent for 2 days. Hearing the answer without the rule isn't possible (the link listens only with it). |
| 3.2 The secret sealed again after a removal | **Built**: for 10 minutes after a computer first sends a changed secret, band.json goes over the link sealed to each computer's own key (`nat.pub` in its devices file) and to no computer without one (Syncthing). **Limit:** devices files carry `nat.pub` only with "Connect without Tailscale" on; with it off (the default) a new secret goes by Syncthing only. Publishing a key always needs `lib/removal.lua` / `lib/nat.lua`. |
| 1.33 Invite links only for someone already on the studio's Tailscale | **An honest message** (a link can't carry a Tailscale key): before the Yes box, off the inviter's network (no Tailscale or another network), a box says to ask for the invitation message. Same line on join.html. Windows without the firewall rule: a box instead of a two-minute wait. |
| 1.33 One pending link at a time | **Fixed**: each click its own `pending-<seconds>-<n>.txt`, read oldest first one each 2 s (up to 20 waiting); a link read within 2 s of another is no longer lost. |
| 1.33 Linux keeps the `xdg-mime` default after untick | **Fixed**: untick takes our entry out of `mimeapps.list` (`$XDG_CONFIG_HOME` or `~/.config`, and `~/.local/share/applications`). |

Defaults taken (section 4 has no question on these): the honest message rather than a link that carries a key; the new secret by Syncthing
where no key is known, rather than in the clear.

## Files

Mine: `lib/joinboot.lua`, `lib/joins.lua`, `lib/invite.lua`, `lib/urlhandler.lua`, `lib/webui/join.js`, `tests/test_0_60_rt_joinlink.lua`,
`tests/test_0_60_rt_invite.lua`. Shared, small: `lib/signed.lua` (P3's): `signed.pieces` and `signed.collect` added, `on_part` and `drain`'s parts
now use them (same behaviour, one difference: a set of parts complete but missing its signature file is refused "not signed" instead of being
held until dropped), and `signed.seal_secret` plus five lines in `drain` and seven in `on_msg`. `lib/band.lua`: not changed (its join parts
needed nothing).

## Review later (security)

Listed in each round's own section: sealing keys from devices files; "new secret" as this computer's own memory; the sealed band.json still in
a frame keyed with the old link key; welcome pieces held in memory; a bigger boot store; up to 20 waiting links; mimeapps.list rewritten.
