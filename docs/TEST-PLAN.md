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
