# StudioSync test plan: laptop, Mac, Linux, then a band

Written 2026-11-15 for 0.58.68, from four review passes (code, a first band session on paper, Mac/Linux, security) and the clean-VM run.
Hand a section to whoever (or whatever AI) is at that computer. Anything that fails: note the step, what the screen said, and the
installer log (Windows: the console; Mac: the Terminal window), plus StudioSync's Console page.

## 1. Windows laptop (a second real computer)

1. Update REAPER to 7.86 first (StudioSync's Settings > Updates, or REAPER's own notice), so both PCs match.
2. On the desktop: Studios > Invite on a throwaway studio. Send the message to the laptop by email or Discord (not iMessage: it can change quotes).
3. On the laptop: run the Windows line from the invitation. Watch for: Windows permission prompts, the Syncthing firewall prompt
   (press **Allow**: this is a real computer), REAPER's first-start questions.
4. Desktop: press **Let them in** (not *Guest, for a day*). Laptop: the studio card goes from "Waiting to be let in" to its projects.
5. Health on both: every row green, and **Connections to the others are direct**. If it says *relay*, a firewall is in the way.
6. Share a song on the desktop; open it on the laptop. Record 30 s on the laptop; time how long until the desktop has it.
7. Edit on the laptop while the desktop drives (the project starts on *Anyone*); then Take control on the laptop.
8. Real time mode with headphones: can each hear the other? Talk button.
9. Sync and exit on the laptop; reopen; it catches up.
10. Desktop: Render current mix. The laptop's Mixes tab shows it.

## 2. Mac (the first real Mac run)

Before: `sw_vers`, `uname -m`, `xcode-select -p` (developer tools or not), `ls /Applications | grep -i -e tailscale -e reaper`.
Remove an App Store Tailscale if there is one (the installer adds the standalone one; Tailscale says never both).

1. Run the Mac line from an invitation (or `curl ... install_mac.sh | bash` and press Return for "later"). Watch and note each macOS prompt:
   your password, REAPER's disk image licence (agree in the Terminal), Syncthing's *Local Network*, Tailscale's system extension and VPN
   configuration, REAPER's microphone.
2. Pick a ReaPersona DAW. With developer tools installed, REAPER quits and comes back by itself with that DAW's shortcuts (this was broken
   on Macs until 0.58.68: if REAPER does not come back, open it by hand and say so). Without them, the end list says ReaPersona's Home has
   one step.
3. Panel: Health green; the studio card; Let them in from the PC.
4. Record a take: no "save recorded media?" box should appear (0.58.68 turns it off). It reaches the PC.
5. A print (a MIDI part through a plug-in): `~/Library/Caches/StudioSync/` gets a REAPER-render copy, no window flashes, the print lands.
   If not: Console.app, filter REAPER, look for codesign or dyld.
6. Play/Jam as host (Tailscale signed in): `pgrep ninjamsrv`; the PC connects.
7. Listening page: Mixes tab > share; open it on the phone over Tailscale; seek inside a mix.
8. Projects > free up space on a song: with and without Full Disk Access, the Trash message is honest.
9. Quit REAPER with a studio tab open; reopen: tabs come back with no boxes.
10. Run the installer again: "already installed", nothing redone.

## 3. Linux (supported from 0.58.74)

Tested in a VMware Ubuntu 24.04 VM (`J:\VMs\LinuxBox`, REAPER 7.86 portable, distro Syncthing 1.27): `install_linux.sh` with an
invitation, Let them in, the song matching the PC and Mac byte for byte, takes both ways in ~5 s, a claimed track's rename going in as
a suggestion, NINJAM server + relay + ReaNINJAM, the listening page (range requests, no symlinks or `..`), the Trash (`gio trash`),
reopening tabs after a quit, the View/Extensions menus, Ctrl+Z, ReaPersona with its shortcut install and relaunch, the installer run
again ("already in"), and being taken out of the studio. No Google Drive client on Linux (the Drive tickbox says so).
Known gaps: needs netcat for NINJAM checks (Ubuntu has it), distro Syncthing older than 1.27 keeps its config where StudioSync doesn't
look, Flatpak/AppImage REAPER isn't detected, background prints are off (prints render in front), NINJAM binaries need glibc 2.34+.

## 4. Before the band test

Host: REAPER 7.86 (what the installer fetches); a studio made; the test song built only from the plug-in pack and REAPER's own plug-ins
(anyone without a commercial plug-in gets it offline); Syncthing allowed in the firewall; REAPER and the panel left open while everyone
installs; **Let them in**, never *Guest, for a day*, for band members.

Everyone: wired internet if possible, headphones, the audio interface plugged in before running the line; Windows 11 (or 10 with App
Installer); Mac password ready; press Allow on Local Network, Microphone and Firewall; after REAPER's "audio device?" question, pick the
interface in Preferences > Audio; skip Tailscale and Google Drive sign-in unless asked; plug-in pack: yes. Use Discord or Zoom to talk
(the panel's Call button), Real time mode for hearing each other play, Play/Jam off. On Windows with REAPER on ASIO, Discord may lose the
interface: Health says so, and Settings > Advanced > Calls lists the ways round it (Talk in Real time mode first).

Feedback (0.58.79): the panel's **Feedback** button (top bar, and on the start screen) takes a bug report, feedback or a feature request,
with a subject and/or a body. It saves to the studio's `_band/feedback/` (one Markdown file each, with versions and the last activity
lines) and/or opens a filled-in GitHub issue for the person to submit. After the test, those files are what gets read and worked through.

Before anyone opens the song: every computer on the newest StudioSync (Health shows each person's version; an older one replays the
tempo map on every open and resends beat-timebase items). Claim your track before recording on it, arm it to be heard in Real time mode,
and on a Mac pick a plug-in's VST3 (or CLAP) rather than its AU, so Windows and Linux count it as the same plug-in.

Agree beforehand: who drives, who records first, that the driver doesn't render a mix mid-session (rendering holds up their REAPER and
others are told the driver's away), that "put back" banners mean someone else owns that part.

Watch and write down: install time per computer and where it stalled; seconds from stopping a recording to the take landing elsewhere,
and whether Health said *direct* or *relay*; every "put back" banner and whether its person understood it; SonoBus joins and latency; a
deliberate REAPER kill mid-session and the recovery; Sync and exit times; any `.sync-conflict` file; everything a newcomer asked aloud.

## 0.58.79, 2026-11-16 (James's requests)

Home no longer lists "You made these": tracks you made that nobody claimed go onto your claims (not while you drive, not in Driver only
or Admins only; letting one go with its x or Release all claims sticks, P_EXT:band_let_go). Chat: Notes and Likes are tabs of their own;
Draw and Hide drawings are buttons beside the radio buttons and the Everyone box. Track colours: Studio colours with Show who's working
and Show what's new, both on by default; what's new shows a bandmate's change briefly (20 s full, gone by 2 min) and keeps what came while
you were away until OK on "Since you were last here". Cloud copy: Google Drive, Dropbox, OneDrive, iCloud Drive or Box (Settings >
Cloud copy). Call apps beside REAPER: Health row and Settings > Advanced > Calls. Feedback button. 46 suites pass.

## 0.58.80-81, 2026-11-16 (James's requests)

0.58.80: Settings > Studio > Sync through Tailscale: each computer publishes its Tailscale name per network in _band/devices, and Syncthing
reaches the studio's computers only at those names (lib/services.lua pin_tailnet). Smiley Studios (James's personal tailnet) and Chilio
(chiliocosm01) both on; switching Tailscale accounts switches which studio syncs.

0.58.81: an empty take lane ("TAKE NULL") no longer stops sharing or Live sync (band.take_ext nil-safe; suite empty_takes). Everyone records
24-bit FLAC at the project's shared sample rate (Live sync puts it back every 10 s; Health warns when the interface runs at another rate).
The sync status is a button of its own after a divider: outlined while running, a pulsing red "Sync off - click to start" that starts it
(no Start button). "Control your own mix" is back. Chat has an All tab (filters; Go for notes, likes and drawings). Settings: a StudioSync
button on REAPER's main toolbar (menu extension 1.0.2 adds it when REAPER builds the default toolbar; image lib/toolbar_icons, Helgobox's
style). Change name renames you in every studio, and the old name's devices, plug-in list and colour files go.

## Results, 2026-11-15 (0.58.68; fixes in 0.58.69 and ReaPersona 5.8.2)

Laptop (Windows, REAPER updated 7.85 -> 7.86, silently): take on the desktop 4 s after stopping; a rename ~5 s; Take control ~5 s;
Real time mode joined; Sync and exit 15 s and caught up on reopen within 6 s; a rendered mix on the laptop within seconds; every
connection direct. Found: running the invitation again moved a member onto a new, empty folder (fixed: the folder Syncthing already
has is used); REAPER's installer leaves a public desktop shortcut (removed by hand).

Mac (macOS 26.5.1, arm64, REAPER 7.84): update and installer re-run pass; Health all green, direct; a take reached the PC's
index the same second; no "save recorded media?" box; a print with no window shown. Found and fixed: setup looked for ReaPersona
before ReaPack had brought it; ReaPersona never found Python on a Mac (REAPER runs a bare `python3` as nothing: full paths now);
quitting with studio tabs open lost the reopen plan (tabs closed one by one with scripts running); a re-run opened Tailscale's page
every time, told a member to be let in, and printed the Google account. REAPER's own "new version" box held the first update sync.

## Known and left for after the test

- Fixed in 0.58.69: roles, removals and closing count only from the owner's or an admin's computer, as Syncthing records who changed the
  file (`lib/trust.lua`; the Console says when one is set aside). Left: someone in charge on a computer nobody has pinned yet (a new one
  of theirs) isn't believed until they act from a known one; identity is still a chosen name. (0.58.78: claims checked too; see below.)
- Fixed in 0.58.69: joiners pair with the inviter as an *introducer* without auto-accept (existing computers switch it off at the next
  Live sync start), so nobody can add a folder to someone else's computer unasked.
- Fixed in 0.58.69: the Tailscale API token is encrypted for the Windows account (DPAPI) or kept in the Mac Keychain; Linux keeps it in
  REAPER's settings.
- Fixed in 0.58.69: taking someone out gives the phone alerts a new channel; everyone else's StudioSync says to subscribe again.
- A take marker's length may be dropped by a collaborator on REAPER 7.85 or older when they re-save that item. Left: restoring it on
  7.86 would make the item differ between the two versions and risk the item syncing back and forth; everyone on 7.86 avoids it.
- ReaPersona 5.8.1 fixed its own Install button's Mac relaunch; 5.8.2 finds Python on a Mac.

## Reviews, 2026-11-16 (0.58.75; fixes in 0.58.76 and ReaPersona 5.9.3)

Seven read-only reviews (UX, ReaPersona, sync engine, plug-ins and data, security, installers, cross-platform) and a Linux stress test.
Fixed: the Windows installer couldn't start or join a studio (a comment swallowed the folder line, 0.58.69) and fetched a release that
doesn't exist (the menus package's 1.0.1); removals, roles and closing never counted on Syncthing 1.27 (REST now); a recording on a
track nobody claimed stayed "(yours, not sent)"; older tempo maps replayed during catch-up and went out as item edits; held changes
undone by a landing item or a heal; two edits made alone outvoted a claimant's own; FX containers read as loaded whatever was inside;
window and lane-view lines inside containers and FX envelopes counted as chain edits; plug-in files under AppData/Library could be
copied out, or written by a bandmate's event; an invitation could name any Syncthing folder; curly quotes in a file name could run
code in the Recycle Bin script; rescans of songs with spaces on Windows; Trim Volume applied twice on prints; preload saved every
open; the Mac and Linux installers ran when the whole invitation was pasted on the other system, a Mac guest's Tailscale key was tried
before macOS let Tailscale run, and plug-ins already installed still used up GitHub lookups. Put-backs now say what differed.

Left for after the test (by area):
- Plug-ins: AU and VST3 of one plug-in count as the same (prints and stand-ins miss it); installed-but-missing content (a Kontakt
  library, an EZX) can make a silent print; prints lose multi-out instruments and sidechains; automation items on plug-in parameters
  point at each machine's own pool; take FX get none of the restless/readback protections; ReaInsert and ReaStream travel live;
  offline-by-choice plug-ins block printing; media files edited in place, subprojects and video are copied once and whole.
- Security (matters for strangers, not a trusted band): fixed on the `left-security` branch (0.58.78, not released); see "Security
  items, 0.58.78" below.
- Installers: GitHub's 60-requests-an-hour limit (plug-ins already installed no longer ask; Syncthing and SonoBus still do); an existing Syncthing with its
  config elsewhere (SyncTrayzor, snap, Homebrew); REAPER in a custom or portable folder; Windows without winget; macOS 11 and older;
  the 6-minute wait for REAPER's first plug-in scan; non-English letters in names.
- Cross-platform: non-ASCII Windows user names in `.cmd` files; Linux without netcat, older distro Syncthing, Flatpak/AppImage REAPER.
- ReaPersona: no uninstall (its startup block errors once removed); built-in personas share key layers with your own; trimming the
  Actions list doesn't look at mouse modifiers or SWS cycle actions; Linux can't open .zip/.rar theme packs.

## Linux stress test, 2026-11-16 (0.58.75/76; fixes in 0.58.77)

On the LinuxBox VM: the 43 REAPER suites (756 pass; every failure a test assumption: no Melodyne, background prints off on Linux, timing,
a test mock written for Windows), two-tab round trips of JSFX, Cockos plug-ins, an FX container, take FX, offline and bypassed FX, parameter
links and envelopes, RS5K samples, missing VST2/VST3/AU/CLAP chunks, 2,000 notes and CCs with SysEx and lyrics, stretch and take markers,
automation items, fixed lanes, sends, non-ASCII and very long names: all matched with no echo or put-back. 5,460 events sent in 12 s;
catch-up ~70 s; StudioSync's own memory levelled at 380–620 MB.
Fixed in 0.58.77: the 7.4 GB crash (the installer opened the panel while ReaPack's Transaction report was up, and its frames never ended:
the installer now waits, and the panel draws nothing while frames stand still); a knob turned with no plug-in window open (control surface,
MIDI learn) in the minute after a chain landed or the song opened was never sent; a subproject item crashed a freshly started REAPER when
pointed at its shared copy (subprojects are held back now, with a word: glue them); Syncthing's API key sat in a /tmp script anyone could
read (Linux uses the per-user runtime folder; the scripts delete themselves first); a short base64 line in a plug-in's data read as text;
a song reopened in the same tab looked fully applied to a long-running script; "The plug-ins is back".
Left: a change made while StudioSync wasn't running is taken as the plug-in loading; LFO/modulated plug-ins never hash the same on two
machines (a lasting "differs", no re-send); frozen tracks arrive frozen, without unfreeze data; hardware outputs aren't sent; plug-in sample
copies keep accented names; a track template with a missing plug-in brings up REAPER's load warning, which blocks scripts; the Linux test
assumptions above.

## Left items, 2026-11-16 (0.58.78 and ReaPersona 5.9.4)

Windows installer, real run (0.58.77, Windows Sandbox on the laptop, a plain invitation): REAPER 7.86, Syncthing, SonoBus, Tailscale, the four
extensions, the studio folder and pairing all installed; StudioSync arrived through ReaPack with autostart, the short Actions list (7) and the
menu extension. It printed "REAPER didn't run the setup step" while REAPER's first-start windows were still up (behind Tailscale's welcome and
a firewall prompt); once answered, setup finished by itself and the panel opened after ReaPack's Transaction report closed. Mac: 0.58.77 and
ReaPersona 5.9.3 through ReaPack, the menu items in Extensions and View.

Fixed (plug-ins and data): a plug-in with an LFO or audio control on a knob stays out of the hash and its other knobs count (a fast LFO's chain
never went out at all before); a knob turned while StudioSync wasn't running goes out at the next open (each chain's knobs are kept in the
project, as of the last time this machine agreed with the band); frozen tracks carry what unfreezing needs, so anyone can unfreeze them;
plug-in sample copies get plain-letter names; an AU counts as missing where the studio has a Windows or Linux computer (DirectX likewise off
Windows), so its parts get prints; a print of notes that comes out silent (an instrument whose library isn't installed) isn't used, and the log
says why; a plug-in offline by choice no longer holds its track's prints back; restless or modulated take FX stay out of item hashes; a landed
chain with ReaInsert or ReaStream is mentioned once; audio buffers are cleared before reads.
Fixed (Linux): the suites' Windows assumptions; background prints work on Linux when switched on (lowercase `reaper`); the installer hands
REAPER the setup step in REAPER's own login session (XDG_SESSION_ID picks REAPER's instance pipe: from another session it started a second).
Fixed (installers): GitHub's hourly limit (Syncthing's and SonoBus's own servers, Homebrew, a cached lookup, the release page as fallback);
a Syncthing already running with its settings elsewhere is used (`--home`; SyncTrayzor is named and has to be quit); REAPER in a custom or
portable folder; Windows without winget; macOS 11 and older told at the start; the first plug-in scan is waited for (up to 45 minutes while
REAPER is open) and a timeout no longer says to run it again; non-English letters (transliterated names, `chcp 65001` in written .cmd files);
Flatpak and AppImage REAPER; Syncthing older than 1.19 skipped; the studio's name shows before its band.json arrives.
ReaPersona 5.9.4: Remove ReaPersona (Settings) and a startup block that finds any older wording; your own personas get layers of their own
(and "Make them its own" for one borrowing a DAW's); the Actions-list trim counts mouse modifiers and SWS cycle actions; Linux unpacks .zip/.rar
theme packs with unzip, unrar, bsdtar or 7z.

Left, by choice: hardware outputs and ReaInsert's channels stay each computer's own (their interfaces differ); REAPER's own warning when a
track template has a missing plug-in (the person inserting it answers it); prints of multi-out instruments and sidechains render the track
alone; automation items on plug-in knobs use each computer's own pool; a media file edited in place under the same name isn't sent again;
frozen audio tracks unfrozen elsewhere point at the freezer's own files; a knob turned on a restless take FX goes out with the item's next
change. Not tried for real: the new installer paths (no winget, SyncTrayzor, portable REAPER, macOS 11, Flatpak/AppImage, snap Syncthing).

Invite and Let them in, real run (0.58.78, Windows Sandbox on the laptop, a throwaway studio on the PC): the invitation fetched the
installer from the v0.58.78 tag; the installer waited through REAPER's first start with its new messages and ended with "Done" (no
false "didn't run"); the panel showed the studio's own name before and after. Let them in (device, then folder) wrote band.json out
again with `managers` and `roles_at`; the joiner kept who invited it and the studio's id, pinned James's PC as owner, switched the
introducer off, and connected directly; a file each way arrived within 15 s. The Sandbox test script now answers commands while the
installer runs (it waits up to 45 minutes for the first-start windows).

## Security items, 0.58.78

The six left from the 2026-11-16 security review, plus given claims and the new-computer question. Everything Syncthing is asked comes
through `lib/trust.lua` (modifiedBy); "" (a folder or file Syncthing doesn't hold) is still believed, as since 0.58.69.
- `band.json` id: never followed once known. The id comes from this computer's own start or join, the invitation the installer ran
  (`studiosync_setup.lua` gets it from the installers now), else the first band.json seen. A rewritten id used to point every Syncthing
  question at a folder it doesn't have, whose empty answer was believed, and at an empty set of role pins. The Console says when they differ.
  (A modifiedBy check can't do it: members write band.json legitimately, for the tailnet, private audio and alerts.)
- Devices files: count only when Syncthing says the computer each names wrote it (removal, role pins, meeting others). Left: a computer
  can still claim any name for itself; identity is a chosen name.
- First use: an invited computer believes band.json's roles only if the inviter's computer (its device ID is in the invitation) wrote
  it; whoever lets someone in writes band.json out again, with `managers` (the computers it has pinned for whoever's in charge) and
  `roles_at`. Written by anyone else, the inviter alone is in charge on that computer until the inviter's computer writes the roles.
  Computers joined before 0.58.78 (no inviter recorded) keep the old first look.
- Listening page: served from `<REAPER>/StudioSync/listen-<id>.html`, written only by StudioSync; still asked for as `_band/listen.html`,
  so shared addresses keep working. A server started by an older version quits within two minutes (its heartbeat file was renamed).
- Introducer: switched off once this computer is let in (no studio of its waiting, except that one's inviter). Someone let in later is
  met directly when they ask to connect, if their own devices file (written by their computer) is in one of this computer's studios and no
  mark has taken them out. Without that, later joiners synced with earlier ones only through a third computer.
- Invitation: the installer lines fetch `raw.githubusercontent.com/FmsJay/studiosync/v<version>/installer/...`, cache-buster kept. Left:
  the installer still reads `index.xml` from main to pick the newest release (what ReaPack serves anyway).
- Guest invitation: reads the tailnet policy first. Tailscale's starting policy (guests reach everything) asks Yes (set up the tags, then
  invite) / No (invite anyway) / Cancel; a policy with its own rules, or one that can't be read, says so and asks to go on.
- Claims (`given-*`): count, and are folded in by the person given them, only when written by the giver's pinned computer (or this one).
- Someone in charge on a new computer of theirs: still not believed until they act from a known one. Accepted for now: the only automatic
  fix would take a devices file naming them, and anyone can write one claiming their name, so it would hand control to whoever claims it
  first. The safe fix is a vouch: on a computer of theirs already known, the person confirms "this new computer is mine", and that writing
  of band.json (with `managers`) would carry it to everyone (`trust.repin` would then add listed computers to someone already pinned, not
  only to someone new). It needs a confirmation in the panel, so it waits for after the test.

0.58.82: Who can edit is the studio owner's or an admin's to pick, and reads Claims (the default: anyone, except on what someone else
claimed, the driver too), Driver + claims (the driver over claims), Driver only, Everyone (claims don't hold) and Admins only. Nothing is
claimed by itself any more (not when sharing, not tracks you make). Event ids are matched by name then date everywhere (sync.is_mine):
"James" took "James-Laptop"'s changes for its own and said you'd both changed something. Guests: Invite a guest picks how long they stay
(or a date), the invitation leaves a note in the studio, Let them in gives them that long, and Who's here lists guests with End now and
Longer; Tailscale guests are taken off at the same time. Follow takes on the followed person's faders, pan and solos (Control your own
mix on meanwhile) and gives yours back when you stop. In Real time mode the per-person switch is Mute/Muted and Listen is Solo. Health
says when Voicemeeter sends REAPER's output back into its input (the echo; lib/vmloop.ps1 reads its routing, read only). Your colour is
the same in every studio you're in. The toolbar button is on by default (Settings > Options > Look). Opening a project catches up a
second per pass, then builds missing peaks. The minimized box's count is small.

0.58.83: the toolbar button is the StudioSync logo in a button frame like the toolbar's own (tools/make_toolbar_icon.py; normal, hover,
on). Menu extension 1.0.3 adds it to whatever main toolbar there is, customized or not, through REAPER's AddCustomMenuOrToolbarItem (7.11
on, not saved into the toolbar), a second after REAPER starts and whenever the setting changes; one added by hand isn't doubled.

0.58.84: menu extension 1.0.4: the toolbar button shows "on" while the panel is open however it opened (the panel's own action, at start),
not only after the button was clicked; the extension finds the panel's script itself and refreshes the button when it opens or closes.

0.58.85: which take an item plays travels (BANDTAKE in mirror's item state, for items with two or more real takes; prints stay each
machine's choice): a take comp (split pieces, a take picked in each) now reaches everyone, and an item arriving new plays the sender's
pick, not its first take (Nostalgia's Track 8 and 10: their comp lanes held the first take and silences). A version from before reads as
the same item: its author sends the pick, anyone else keeps theirs. Takes becoming lanes keep the pick by its place, not a take pointer
(deleting a print take could leave it dangling); in a track already in lanes each take gets one lane shared by every piece. Prepare no
longer removes a piece that plays an empty take on purpose (with real takes in it). Suite take_comps: what plays at every moment, before
and after, on a plain track, empty takes, a track in lanes, mirror apply and Prepare's lanes. Prints rendered in front hold the screen
still (no parts flashing selected one after another). "SonoBus-only singer" is "SonoBus Guest". The Voicemeeter Health row is gone.

0.58.86: a log on disk as it goes: every Console line and every error with its traceback in <StudioSync home>/logs/studiosync-YYYY-MM-DD.log
(14 days kept), each line naming its script (panel, live <song>, autostart); the panel and Autostart write their error before REAPER's
box, Live sync every error (the Console still says it once in 30 s); the Console starts from today's file after a restart; Console > Log files
opens the folder. The background print renderer keeps trying until 5 fail with none done (was 2), says how it's going under Settings >
Options, and Health shows a row with "Try in the background again" once it gives up. Nostalgia's Track 8 and 10 comps rebuilt from the
"before StudioSync" copy (1168 points checked against it).

0.58.87 (after a four-reviewer pass; what's still open is in docs/REVIEW-2026-11-16.md):
- Panel: "When you click REAPER, the panel" goes behind it (default; its own window, ConfigVar_ViewportsNoDefaultParent), stays in front, or
  shrinks to the tiny box. The action and toolbar button are called just "StudioSync" (menu extension 1.0.5 relabels a button added by hand).
- SonoBus: Settings > Advanced > What you send (Opus 96 default, Opus 256, PCM 16, PCM 24) as defsendqual and every person's sendformat;
  Home: Invite a SonoBus guest (one message with SonoBus's download and the join link; Real time and SonoBus Guest on).
- Takes to lanes: an item keeps its own lane; a track with a bandmate's takes or prints, or a locked item with takes, isn't converted here;
  bounded delete loop; the screen held still (the likely "MIDI items flashing"). Prepare's lanes go through REAPER's explode with comp areas.
- Mirror: empty takes travel as "TAKE NULL" (they arrived as a real empty-source take); the first send of an item keeps its pick, selection
  and group; a marker or notes change no longer opens the 15 s tempo window that swallowed nudges, fades and automation.
- Prepare: originals stay where they are when converted to FLAC; clutter spares items with notes, non-file sources or take FX; slivers are
  a row of their own, unticked. Recording format put back only while stopped. Print renders always put the track back.
- Same song name in two studios: matched by studio too (open, Live sync, driver history); new local projects go in a folder per studio.
- Opening a project keeps your own mix; nothing comes in before Live sync's first look; extra-tab launchers rewritten when stale; the update
  question waits until nothing plays; the panel reads band.lua once in 3 s.
- Security: chat overview's Open asks for anything not a web link; Syncthing settings changed only for studio peers; devices files carry
  only the studio's own Tailscale name; outward studio settings only from an owner's or admin's band.json; guest invitations refuse a
  token for another network, keys last two days, guest notes only count from someone in charge, and Tailscale guests are swept by Autostart.
- Bare pcalls in Live sync and Autostart log their failures (band.try). New tests: test_trusted, take_comps empty-take case.

0.58.88: the panel stopped on opening in 0.58.87: ReaImGui 0.10.0.5 has no ConfigVar_ViewportsNoDefaultParent, and its compatibility
layer throws even to look a name up (the new log file caught it). Looked up through pcall now; where it's missing, "When you click REAPER"
offers Shrinks to the tiny box (the default) and Stays in front. The panel opened and ran on the PC afterwards.

0.58.89 (the rest of the 2026-11-16 review, and guests who see only some projects):
- Guests: an invitation can name the projects they see ("Only these"), and Guests > Projects changes it later (_band/guest-access/<id>.json,
  believed only from an owner's or admin's computer: lib/access.lua). On the guest's computer the others aren't listed anywhere in
  StudioSync, and its Syncthing ignore file brings only the band-wide folders and their projects, not even another project's listing
  (songsync.block_guest; Autostart keeps every studio's ignore file in step every 30 s). Hidden, not locked: one shared folder goes to
  every computer in it, so it's left out on the guest's side.
- Mirror: looped, rate-changed and trimmed automation items rebuild as they were (the pool's length in beats travels, points as one pass of
  the pool); automation items on a send's envelopes travel (in the sends part); a plug-in envelope's items travel in the automation part,
  each with a pool of its own here (the sender's pool number no longer travels) and kept through an incoming chain change; a new item's
  own default point is removed before the sent points go in. Inside a container, only a modulated plug-in's data is out of the hash, not
  its neighbours'. A chain change with no window open and no knob moved still goes out if a plug-in's preset changed (a script's or an
  action's preset load).
- Project defaults travel with the project settings: pan law, pan mode, pan law flags, item mixing, default pitch-shift mode.
- Updates from the shared folder wait until every file of the release has arrived whole (lib/files.txt, written by tools/make_index.py).
- The studios list, folder in use, your name, this computer's id and each studio's role pins and inviter are kept in
  <StudioSync home>/settings.json too, and put back from there when REAPER comes up without them (a crash loses persisted ExtState).
- Health: a bandmate's clock more than 90 s off from this computer's (status files carry the sender's clock; one behind by more than
  45 s also read as gone); a track group holding tracks made by different people (two people numbering a group alike). Both dismissable.
- New tests: test_access, test_clock_groups, songsync guest block, container neighbour hash; REAPER suite auto_items (17 checks).

0.58.90: the master's FX button travels (in E-MASTER as "BANDFXEN 0" while off). A computer with SonoBus or NINJAM on its master keeps
the button on, says so once, and holds the band's setting so it isn't sent back. auto_items checks it (21 checks).

0.58.91 (the review's sync-behaviour and robustness items):
- A modulated or restless plug-in's chain goes out when its window closes with its text changed (a patch or IR loaded inside it moves no
  knob and its data is out of the hash). With an LFO running, closing it always sends once. modulated_fx checks it.
- Markers and regions are changed in place by number (band.match_markers: kind, then position and name, then name, then position), so
  they keep their numbers and render-matrix places; new ones get the next free number. markers_keep, test_markers.
- A refused edit to someone else's item leaves a copy of yours on "<track> (yours, not sent)". Local item groups survive incoming updates.
- Someone else's start or stop together doesn't cut a recording you started yourself (one started together can be stopped together), and
  a record cue doesn't pull you off another tab that's playing; switching tabs to record is said. (Live sync: not covered by a suite.)
- Ctrl+Z on "takes became lanes" sticks: the track keeps its takes until none has two (band_keep_takes). take_comps checks it.
- Take envelopes' view lines (shown, height, armed, EGUID) are left out of items: those items read differently once after updating.
- Catching up reads within the pass's budget and applies only once everything is read; "Since you were last here" reads only events
  named after then; the quick cue listing runs every 0.25 s only while someone else is here (2 s alone).
- An older kind of change refused here waits a minute from when it arrived, then lands, as object changes do.
- History archive: across drives the original is removed once the copy is there; a shared folder at a drive's top archives into
  StudioSync's own folder. An older ReaImGui gets a message instead of REAPER's error box (band.imgui).

0.58.92 (the second review, docs/REVIEW-2026-11-17.md):
- Pure: test_review92 (prints a change names, in one room or any, raw or decoded; any run of empty takes; the newest tempo map wins, ours
  included). test_installer: a --home's quotes are escaped inside PowerShell's outer ones.
- REAPER suites: the full run (suites52.sh) after the fixes. Not covered by a suite: Live sync's heartbeat during a take, the stop-reading
  count, together_take; Tailscale auto-admit; the guest list failing closed; the Syncthing back-off; Drive; the print archive in trim.run;
  Prepare's backup of an unsaved project; the local-copy re-check. Each is small and read against the code; first real use is their test.

0.58.93 (the second look, docs/REVIEW-2026-11-17.md): test_review93 (together.count_reading / leave_alone / heartbeat_due, drive.mine with
longer names, drive.arriving, localcopy.still_confirmed, access.get/mine/read failing closed and keeping verdicts, the back-off including
Windows' "259" and changes going through, the curl key file), test_review92 (sync.newest_map with a slow clock's order, mirror.older_form,
the older {media} form), REAPER suites removal (may_auto_admit), prepare_backup, print_archive, and the full run.
