#!/bin/bash
# StudioSync setup for macOS: installs and sets up everything StudioSync needs, skipping whatever is already there.
# Run it with "Install StudioSync (Mac).command" (if macOS blocks it: System Settings > Privacy & Security > Open Anyway), or in Terminal:
#   curl -fsSL "https://raw.githubusercontent.com/FmsJay/studiosync/main/installer/install_mac.sh?$(date +%s)" | bash
# (the ?<time>: GitHub's cache handed out the previous installer for minutes after a release, 2026-10-31)
# REAPER, ReaPack, ReaImGui, Syncthing (the shared folder), StudioSync's scripts (through ReaPack), SonoBus + Tailscale
# (hearing each other) and Google Drive for desktop (the band's copy). Every app comes from its official source.
# Uses only tools a stock Mac has (curl, hdiutil, ditto, installer): nothing here triggers the Xcode tools prompt.
# Answers can be given up front as environment variables: BS_USER, BS_HOSTING (yes: the first one set up), BS_HOST_ID (a set-up bandmate's Syncthing ID), BS_ROOT,
# BS_LIVE / BS_SOLO (no: leave out SonoBus + Tailscale / Google Drive; both go in unless said), BS_SCRIPTS (reapack/folder/verify), BS_TAG,
# BS_BAND_ID / BS_BAND_NAME (the band an invitation is for: its Syncthing folder id and name; the first band is "bandsync"),
# BS_TS_KEY (a guest invitation's Tailscale key: on the inviter's Tailscale network until the invitation ends, no account; lib/services.lua).
# A bandmate's panel (Invite a collaborator) hands out the curl line above with BS_HOST_ID already in it.
# Testing: BS_SYNCTHING_HOME drives a separate Syncthing instance, BS_NO_REAPER stops before anything happens inside REAPER.
# First run on a Mac 2026-10-28 (fixes in c2639a5); reviewed again for 0.34 (2026-10-31).
set -u
# (the whole invitation pasted at once runs every line: the Linux one after this. Installer review, 0.58.76)
[ "$(uname -s)" = Darwin ] || { echo "This is the Mac setup. On Linux, use the invitation's Linux line; on Windows, its Windows line."; exit 1; }
# (macOS 11 and older: the Syncthing, Tailscale and Google Drive this sets up no longer support them, and setup failed half way through.
# Said first, before anything is installed. Installer review, 0.58.78)
MACOS="$(sw_vers -productVersion 2>/dev/null)"
if [ -n "$MACOS" ] && [ "${MACOS%%.*}" -lt 12 ] 2>/dev/null; then
  echo "This Mac runs macOS $MACOS. StudioSync needs macOS 12 (Monterey) or newer: the Syncthing, Tailscale and Google Drive it sets up no longer"
  echo "support older versions. Update macOS if this Mac can (Apple menu > About This Mac > Software Update), or set StudioSync up on another computer."
  exit 1
fi
REPO="FmsJay/studiosync"
TAG="${BS_TAG:-main}"
REAIMGUI="0.10.0.5"   # shortcut: pinned, like the Windows installer
REAPACK="v1.2.6"
# arm64 or x86_64, which is also how the extensions name their builds. (Not uname -m: a Terminal running under
# Rosetta says x86_64 on an Apple Silicon Mac, and those builds don't load in REAPER there.)
ARCH="x86_64"; [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ] && ARCH="arm64"
RES="$HOME/Library/Application Support/REAPER"
WORK="$(mktemp -d /tmp/studiosync_setup.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT # (also when it stops early)

say()  { printf '\033[36m%s\033[0m\n' "$*"; }
ok()   { printf '\033[32m  OK  %s\033[0m\n' "$*"; }
warn() { printf '\033[33m  !!  %s\033[0m\n' "$*"; }
ask()  { local a; read -e -r -p "$1${2:+ [$2]} " a </dev/tty; echo "${a:-${2:-}}"; } # (-e: arrow keys edit, not type escape codes)
# Plain letters, as StudioSync's band.clean makes them, letter by letter: accents dropped, Ø -> O, Æ -> AE, ß -> ss, Þ -> Th ("CHILIØ" -> "CHILIO").
# (perl, not iconv: macOS's iconv mangles whole names, "Łódź Ñandú" -> "Lozo Nanu", where each letter alone comes out right. 0.59.19)
plain() {
  local t
  t="$(printf '%s' "$1" | perl -CS -MUnicode::Normalize -e 'my %m = (0xC6,"AE",0xE6,"ae",0xD8,"O",0xF8,"o",0xDF,"ss",0xDE,"Th",0xFE,"th",0xD7,"x",0xD0,"D",0xF0,"d",0x152,"OE",0x153,"oe",0x141,"L",0x142,"l",0x110,"D",0x111,"d",0x126,"H",0x127,"h",0x131,"i",0x132,"IJ",0x133,"ij",0x138,"k",0x13F,"L",0x140,"l",0x149,"n",0x14A,"N",0x14B,"n",0x166,"T",0x167,"t",0x17F,"s"); local $/; $_ = NFD(<STDIN>); s/\p{Mn}//g; s{([^\x00-\x7f])}{$m{ord $1} // ""}ge; print' 2>/dev/null)" ||
    t="$(printf '%s' "$1" | iconv -f UTF-8 -t ASCII//TRANSLIT 2>/dev/null)"
  printf '%s' "$t" | LC_ALL=C tr -cd 'A-Za-z0-9 _-' | sed 's/^ *//; s/ *$//'
}
yes()  { case "$1" in [yY]*) return 0;; *) return 1;; esac; }
# (the whole invitation pasted instead of its one line: the lines after it waited and answered the questions below. 0.59.10)
{ while IFS= read -r -t 1 _ </dev/tty; do :; done; } 2>/dev/null # (whole seconds: macOS's bash 3.2 refuses -t 0.3, and the loop ended at once. Mac review, 0.59.14)

say "StudioSync setup"
echo "This installs what StudioSync needs and sets it up. It asks a few questions first (unless they were given up"
echo "front); macOS asks for your password to install some apps, and to allow a few things (all explained as they"
echo "come). Nothing already installed is changed."
echo

# ---------- 0. questions ----------
# (names are plain letters, digits, spaces, - and _: the default is shown already cleaned, and a typed name that
# changes when cleaned is said, not changed silently)
say "A studio is the people you make music with: StudioSync shares your projects with them as you work."
# Pairing: with whoever in the band is already set up (any of them: every machine passes the folder on). "Host" is
# a song's, not a machine's: anyone can host a song (James, 2026-10-31: "are you the band's host" read as a role).
# Joining or starting comes from the invitation: pasted (or already in the line it gave), you join; none, you start a studio. ("Starting or
# joining?" was still a question a newcomer could get wrong: James, 0.58.64.) Asked first, so a pasted message can't answer the others.
ID_RE='^[A-Z0-9]{7}(-[A-Z0-9]{7}){7}$'
# What was pasted (the invitation message, its studiosync-join line, its install line, or a bare device ID) -> INV_ID, INV_BAND, INV_NAME,
# INV_KEY; false when it's none of them. (as lib/services.lua parse_join reads it)
read_invite() {
  local re1='studiosync-join:([A-Z0-9-]+):([A-Za-z0-9-]+):([^[:cntrl:]]*)'
  local re2="-HostId[[:space:]]+([A-Z0-9-]+)[[:space:]]+-BandId[[:space:]]+([A-Za-z0-9-]+)[[:space:]]+-BandName[[:space:]]+'([^']*)'"
  local re3="BS_HOST_ID=([A-Z0-9-]+)[[:space:]]+BS_BAND_ID=([A-Za-z0-9-]+)[[:space:]]+BS_BAND_NAME='([^']*)'"
  local line bare
  INV_ID=""; INV_BAND=""; INV_NAME=""; INV_KEY="$(printf '%s' "$1" | grep -o 'tskey-auth-[A-Za-z0-9-]*' | head -1)"
  while IFS= read -r line; do
    if [[ "$line" =~ $re1 ]] || [[ "$line" =~ $re2 ]] || [[ "$line" =~ $re3 ]]; then
      echo "${BASH_REMATCH[1]}" | grep -Eq "$ID_RE" && { INV_ID="${BASH_REMATCH[1]}"; INV_BAND="${BASH_REMATCH[2]}"; INV_NAME="${BASH_REMATCH[3]}"; return 0; }
    fi
  done <<< "$1"
  bare="$(printf '%s' "$1" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"
  echo "$bare" | grep -Eq "$ID_RE" && { INV_ID="$bare"; return 0; }
  return 1
}
# No invitation and no studio of your own yet: everything installs, and the studio waits (James, 0.58.64: you might not need one yet, or get the
# invitation later). The panel then opens on Start a studio / Paste join code. BS_HOSTING=later says so up front.
LATER=""
if [ "${BS_HOSTING:-}" = later ]; then HOSTING=n; LATER=1
elif [ -n "${BS_HOSTING:-}" ]; then HOSTING="$BS_HOSTING" # (the old way of saying "I'm the first")
elif [ -n "${BS_HOST_ID:-}" ]; then HOSTING=n # (an invitation's line: someone is set up, and that's their ID)
else
  say "Did someone send you an invitation to their studio? Paste it here (all of it, or just its line starting studiosync-join)."
  say "Starting a studio of your own right now? Type s. Neither yet? Just press Return: start one or join one later, from StudioSync's panel."
  HOSTING=n
  while :; do
    text=""; read -e -r -p "Invitation: " text </dev/tty
    # (a whole message pasted is several lines: the rest are read here too, or they'd answer the next questions)
    while IFS= read -r -t 1 l </dev/tty; do text="$text"$'\n'"$l"; done
    trimmed="$(printf '%s' "$text" | tr -d '[:space:]')"
    [ -z "$trimmed" ] && { LATER=1; break; }
    case "$trimmed" in s|S|start|Start) HOSTING=y; break;; esac
    if read_invite "$text"; then
      BS_HOST_ID="$INV_ID"; BS_BAND_ID="$INV_BAND"; BS_BAND_NAME="$INV_NAME"; [ -n "$INV_KEY" ] && [ -z "${BS_TS_KEY:-}" ] && BS_TS_KEY="$INV_KEY"
      ok "Joining ${INV_NAME:-their studio}"; break
    fi
    warn "That isn't an invitation. Paste it again (the line starting studiosync-join is enough), type s to start a studio, or press Return for later."
  done
fi
JOINING=""; ! yes "$HOSTING" && [ -z "$LATER" ] && JOINING=1
HOST_ID="$(echo "${BS_HOST_ID:-}" | tr '[:lower:]' '[:upper:]')"
if [ -n "$JOINING" ]; then
  echo "$HOST_ID" | grep -Eq "$ID_RE" || { warn "The invitation's device ID isn't a whole one: ask for a new invitation."; exit 1; }
elif [ -n "$LATER" ]; then
  say "No studio yet: when you want one, StudioSync's panel has Start a studio and Paste join code."
else
  say "Starting a studio: at the end, StudioSync's panel has Invite, which makes the message to send each collaborator."
fi
USERNAME_BS="$(plain "${BS_USER:-}")"
while [ -z "$USERNAME_BS" ]; do
  typed="$(ask "Your name, as the studio will see it (you can change it later)" "$(plain "$(id -F 2>/dev/null | cut -d' ' -f1)")")"
  USERNAME_BS="$(plain "$typed")"
  [ -n "$USERNAME_BS" ] && [ "$USERNAME_BS" != "$typed" ] && say "Using the name '$USERNAME_BS' (plain letters only)."
  # (a name in another alphabet cleans to nothing, and the question came back with no word why. Installer review, 0.58.78)
  [ -z "$USERNAME_BS" ] && [ -n "$typed" ] && warn "Names here are in Latin letters (A to Z), digits, spaces, - and _: type yours that way."
done
# the band (docs/bands-design.md): each its own shared folder. An invitation names it; the first one set up names it.
FOLDER_ID="$(printf '%s' "${BS_BAND_ID:-}" | LC_ALL=C tr 'A-Z' 'a-z' | LC_ALL=C tr -cd 'a-z0-9-')"
if [ -n "$JOINING" ] && [ -z "$FOLDER_ID" ]; then # (someone's device ID typed in by hand, no invitation)
  FOLDER_ID="$(ask "The studio's ID, if whoever set it up gave you one (press Return if not)" bandsync | LC_ALL=C tr -cd 'a-z0-9-')"
  [ -n "$FOLDER_ID" ] || FOLDER_ID=bandsync
fi
# (only a StudioSync studio's folder: an invitation naming one you already have, like Syncthing's "default", would share
# it with whoever sent it. Security review, 0.58.76)
case "$FOLDER_ID" in bandsync|bandsync-*|studiosync-*|"") ;; *) warn "That studio ID ($FOLDER_ID) isn't a StudioSync one: ask for a new invitation."; exit 1 ;; esac
BAND_NAME="$(plain "${BS_BAND_NAME:-}")"
if yes "$HOSTING" && [ -z "$BAND_NAME" ]; then
  while [ -z "$BAND_NAME" ]; do
    typed="$(ask "Name your studio" "My studio")"; BAND_NAME="$(plain "$typed")"
    [ -z "$BAND_NAME" ] && warn "Names here are in Latin letters (A to Z), digits, spaces, - and _: type it that way."
  done
fi
[ -n "$BAND_NAME" ] || BAND_NAME="the studio"
DEF_ROOT="$HOME/StudioSync"; [ -d "$HOME/BandSync" ] && DEF_ROOT="$HOME/BandSync" # (the first studio, id bandsync: a computer set up before the rename keeps its BandSync folder)
if [ "$FOLDER_ID" != bandsync ]; then DEF_ROOT="$HOME/StudioSync $BAND_NAME"; fi
# (later: an empty StudioSync folder, so a studio started or joined from the panel goes beside it, in your home folder: services.new_band)
[ -n "$LATER" ] && DEF_ROOT="$HOME/StudioSync"
while :; do
  # (not asked: nobody new knows what to answer. Beginner review, 0.58.62)
  ROOT="${BS_ROOT:-$DEF_ROOT}"
  ROOT="$(printf '%s' "$ROOT" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/\\\(.\)/\1/g')" # (dragged in from Finder: "\ " and a trailing space)
  ROOT="${ROOT/#\~/$HOME}"
  ROOT="${ROOT%/}"
  case "$ROOT" in /*) break;; esac
  warn "BS_ROOT isn't a full folder path (it should start with / or ~): using $DEF_ROOT instead."
  BS_ROOT=""
done
[ -z "$LATER" ] && say "$BAND_NAME's shared folder: $ROOT"
# The first one set up: an ID of the group's own. They all used to get "bandsync", so someone in two such groups had the two
# folders treated as one and their files mixed. Run again on the same folder, it keeps the ID it has; a folder from before
# groups had IDs, with no band.json yet, is "bandsync" (lib/band.lua band.info).
if [ -z "$FOLDER_ID" ] && [ -z "$LATER" ]; then
  if [ -f "$ROOT/_band/band.json" ]; then FOLDER_ID="$(sed -n 's/.*"id"[^"]*"\([^"]*\)".*/\1/p' "$ROOT/_band/band.json" | head -1)"
  elif [ -n "$(ls -A "$ROOT" 2>/dev/null)" ]; then FOLDER_ID=bandsync; fi
  if [ -z "$FOLDER_ID" ]; then
    SLUG="$(printf '%s' "$BAND_NAME" | tr '[:upper:]' '[:lower:]' | LC_ALL=C sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
    FOLDER_ID="studiosync-${SLUG:-group}-$(printf '%04x' $((RANDOM * 2)))"
  fi
fi
DRIVE_NAME="StudioSync"; [ "$FOLDER_ID" != bandsync ] && DRIVE_NAME="StudioSync - $BAND_NAME" # (the first studio's Drive folder was renamed StudioSync)
# SonoBus + Tailscale (hearing each other) and Google Drive (the group's copy) are part of StudioSync, not asked. Tailscale left in 0.50 and came back
# (James, 2026-11-04: "should not be optional"): the NINJAM route needs it, and it gets round a router that stops SonoBus.
# (James, 2026-10-31: "it feels like a core feature"); BS_LIVE=no / BS_SOLO=no still leave them out.
LIVE="${BS_LIVE:-y}"
SOLO="${BS_SOLO:-y}"
if [ -z "${BS_PLUGINS:-}" ]; then
  say "The free plug-in pack (about 350 MB): synths, guitar and bass amps, a tuner, EQ, compressor, reverb, delay, tape,"
  say "drum kits and keys (Surge XT, Dexed, Airwindows, Dragonfly, Chow, BYOD, ZL and more), so everyone hears the same sounds."
fi
PLUGINS="${BS_PLUGINS:-$(ask "Install it? (recommended) (y/n)" y)}"
EXTRAS="${BS_EXTRAS:-n}"
# (extras only asked of whoever starts the studio: 1.2 GB is a lot for a joiner to decide on blind. Beginner review, 0.58.62)
if yes "$PLUGINS" && [ -z "$JOINING" ] && [ -z "${BS_EXTRAS:-}" ]; then
  say "The bigger extras (about 1.2 GB): a grand piano, a real drum kit, amp capture players and the Odin 2 synth."
  EXTRAS="$(ask "Install the extras too? (y/n)" n)"
fi
# ReaPersona: which app you're used to, as one question, and it's set up as that DAW in the same run (James, 0.58.64: yes/no installed it and
# left the picking for later). BS_REAPERSONA: a DAW id (ReaPersona's own, styles.json), yes or no.
PERSONA_IDS="pro_tools pro_tools_intro logic garageband ableton fl_studio cubase nuendo studio_one bitwig cakewalk reason audacity audition"
PERSONA=""
case "${BS_REAPERSONA:-}" in
  [yY]*|[nN]|[nN][oO]) ;;
  "")
    say "Used to another music app? REAPER can take on its shortcuts, mouse and look (ReaPersona, free; switch back any time):"
    i=0; for n in "Pro Tools" "Pro Tools Intro (the free one)" "Logic Pro" "GarageBand" "Ableton Live" "FL Studio" "Cubase" "Nuendo" "Studio One or Fender Studio Pro" "Bitwig Studio" "Cakewalk or Sonar" "Reason" "Audacity" "Adobe Audition"; do
      i=$((i + 1)); printf '  %2d) %s\n' "$i" "$n"; done
    while :; do
      n="$(ask "Its number, or Return for none")"
      [ -z "$n" ] && break
      case "$n" in *[!0-9]*) ;; *) [ "$n" -ge 1 ] && [ "$n" -le 14 ] && { PERSONA="$(echo $PERSONA_IDS | cut -d' ' -f"$n")"; break; };; esac
      warn "A number from the list, or Return."
    done;;
  *) PERSONA="$(printf '%s' "$BS_REAPERSONA" | tr '[:upper:]' '[:lower:]' | LC_ALL=C tr -cd 'a-z0-9_')";;
esac
REAPERSONA=n; { [ -n "$PERSONA" ] || yes "${BS_REAPERSONA:-n}"; } && REAPERSONA=y
echo

say "Downloads show no progress here: a pause of a few minutes on a big one is normal."
# ---------- 1. apps ----------
# Mount a disk image, then install the .app or .pkg inside it. Disk images with a license show it first: that's yours to agree to.
from_dmg() { # url name app-name
  local dmg="$WORK/$2.dmg" mnt="$WORK/mnt_$2"
  curl -fsSL "$1" -o "$dmg" || { warn "$2: download failed"; return 1; }
  mkdir -p "$mnt"
  # (a disk image with a licence shows it here, and waits for you to agree: it used to go to /dev/null and look hung)
  PAGER=cat hdiutil attach -noverify -nobrowse -mountpoint "$mnt" "$dmg" </dev/tty | grep -v '^/dev/' || true
  [ -d "$mnt" ] && [ -n "$(ls -A "$mnt" 2>/dev/null)" ] || { warn "$2: couldn't open the disk image"; return 1; }
  local pkg app
  pkg="$(find "$mnt" -maxdepth 1 -name '*.pkg' | head -1)"
  app="$(find "$mnt" -maxdepth 1 -name "${3:-*}.app" | head -1)"
  local rc=1 # neither a .pkg nor an .app in the image: not installed
  if [ -n "$pkg" ]; then password_note; sudo installer -pkg "$pkg" -target / >/dev/null; rc=$?
  elif [ -n "$app" ]; then ditto "$app" "/Applications/$(basename "$app")"; rc=$?
  fi
  hdiutil detach "$mnt" -quiet
  [ $rc -eq 0 ] && ok "$2 installed" || warn "$2 didn't install: install it by hand"
}
# GitHub's release lookups: each is one of the 60 an hour GitHub allows a network that isn't signed in, and a band installing in one room ran
# out. So each answer is kept for an hour (a second run asks nothing), and once the limit is reached (403, X-RateLimit-Remaining: 0) the
# release's own web page is read instead, which isn't counted; said once, with when the limit resets. (Installer review, 0.58.78)
GH_CACHE="$HOME/Library/Caches/StudioSync/github"
gh_release() { # repo latest|tags/<tag> -> that release's download URLs, one a line
  local c h tag at
  c="$GH_CACHE/$(printf '%s_%s' "$1" "$2" | tr -c 'A-Za-z0-9._-' '_')"; h="$WORK/gh_headers"
  if [ -s "$c" ] && [ -z "$(find "$c" -mmin +60 2>/dev/null)" ]; then cat "$c"; return 0; fi
  mkdir -p "$GH_CACHE"; : > "$h"
  curl -fsSL -D "$h" "https://api.github.com/repos/$1/releases/$2" 2>/dev/null | grep -o '"browser_download_url": *"[^"]*"' | sed 's/.*"\(http[^"]*\)"/\1/' > "$c.part"
  if [ ! -s "$c.part" ]; then
    if tr -d '\r' < "$h" | grep -qi '^x-ratelimit-remaining: *0$' && [ ! -f "$WORK/gh_told" ]; then
      : > "$WORK/gh_told"; # (a file: every lookup runs in a $(...) of its own)
      at="$(tr -d '\r' < "$h" | sed -n 's/^[Xx]-[Rr]ate[Ll]imit-[Rr]eset: *//p' | head -1)"
      at="$(date -d "@$at" +%H:%M 2>/dev/null || date -r "$at" +%H:%M 2>/dev/null)"
      warn "GitHub's limit of 60 lookups an hour from this network is used up${at:+ (until $at)}: several computers installing at once? Reading GitHub's download pages instead." >&2 # (stderr: the URLs go to a pipe)
    fi
    tag="${2#tags/}"
    [ "$2" = latest ] && tag="$(curl -fsSI "https://github.com/$1/releases/latest" 2>/dev/null | tr -d '\r' | sed -n 's#^[Ll]ocation: .*/releases/tag/##p' | tail -1)"
    [ -n "$tag" ] && curl -fsSL "https://github.com/$1/releases/expanded_assets/$tag" 2>/dev/null | grep -o 'href="/[^"]*/releases/download/[^"]*"' | sed 's#^href="#https://github.com#; s#"$##' > "$c.part"
  fi
  [ -s "$c.part" ] && mv -f "$c.part" "$c" && cat "$c" && return 0
  rm -f "$c.part"; return 1
}
gh_asset() { # repo regex -> download URL of the latest release asset matching it
  gh_release "$1" latest | grep -E -e "$2" | head -1
}
have() { [ -d "/Applications/$1.app" ]; }
gh_asset_tag() { # repo tag regex -> download URL of that release's asset matching it
  gh_release "$1" "tags/$2" | grep -E -e "$3" | head -1
}
# A plug-in's disk image: its .pkg if it has one, else its plug-in bundles copied into your own Plug-Ins folders
# (no password needed). `pattern`: a glob that's there once it's installed, in /Library or ~/Library.
plugin_found() { find /Library/Audio/Plug-Ins "$HOME/Library/Audio/Plug-Ins" -maxdepth 2 -name "$1" 2>/dev/null | grep -q .; }
# (looked for before its download is: every lookup is a GitHub API call, 60 an hour per network, and a band installing in one room
# ran out, so Syncthing's own download failed. Installer review, 0.58.76)
have_plugin() { plugin_found "$2" && ok "$1 is already installed"; }
plugin_dmg() { # url name pattern
  [ -n "$1" ] || { warn "$2: no download found, skipped"; return 1; }
  if plugin_found "$3"; then ok "$2 is already installed"; return 0; fi
  local dmg="$WORK/$2.dmg" mnt="$WORK/mnt_plugin"
  say "Installing $2 ..."
  curl -fsSL "$1" -o "$dmg" || { warn "$2: download failed"; return 1; }
  mkdir -p "$mnt"
  PAGER=cat hdiutil attach -noverify -nobrowse -mountpoint "$mnt" "$dmg" </dev/tty | grep -v '^/dev/' || true
  [ -d "$mnt" ] && [ -n "$(ls -A "$mnt" 2>/dev/null)" ] || { warn "$2: couldn't open the disk image"; return 1; }
  local pkg; pkg="$(find "$mnt" -maxdepth 2 -name '*.pkg' | head -1)"
  if [ -n "$pkg" ]; then password_note; sudo installer -pkg "$pkg" -target / >/dev/null
  else
    local d="$HOME/Library/Audio/Plug-Ins"
    mkdir -p "$d/VST3" "$d/Components" "$d/CLAP"
    find "$mnt" -maxdepth 3 -name '*.vst3' -prune | while read -r b; do ditto "$b" "$d/VST3/$(basename "$b")"; done
    find "$mnt" -maxdepth 3 -name '*.component' -prune | while read -r b; do ditto "$b" "$d/Components/$(basename "$b")"; done
    find "$mnt" -maxdepth 3 -name '*.clap' -prune | while read -r b; do ditto "$b" "$d/CLAP/$(basename "$b")"; done
  fi
  hdiutil detach "$mnt" -quiet
  plugin_found "$3" && ok "$2 installed" || warn "$2 didn't install: install it by hand"
}
told_pw=""
password_note() { # before the first sudo: a bare "Password:" looks like something's wrong
  [ -n "$told_pw" ] && return
  told_pw=1
  say "Installing apps needs your Mac password (the one you log in with). Type it at 'Password:' below: nothing shows"
  say "while you type, that's normal. It's asked once and used only to install."
}

# REAPER.app: the running one (a portable REAPER in a folder of its own, REAPER64.app), then the usual places, then Spotlight. BS_REAPER, or
# the answer when none is found, names another. (Installer review, 0.58.78)
find_reaper_app() {
  local p c
  p="$(pgrep -x REAPER | head -1)"
  [ -n "$p" ] && c="$(ps -o comm= -p "$p" 2>/dev/null | sed -n 's#^\(.*\.app\)/Contents/MacOS/.*#\1#p')" && [ -d "$c" ] && { echo "$c"; return 0; }
  for c in "${BS_REAPER:-/-}" "${BS_REAPER:-/-}/REAPER.app" /Applications/REAPER.app /Applications/REAPER64.app "$HOME/Applications/REAPER.app"; do
    case "$c" in *.app) [ -d "$c/Contents/MacOS" ] && { echo "$c"; return 0; };; esac
  done
  c="$(mdfind 'kMDItemCFBundleIdentifier == "com.cockos.reaper"' 2>/dev/null | head -1)"; [ -n "$c" ] && [ -d "$c" ] && { echo "$c"; return 0; }
  return 1
}
if ! find_reaper_app >/dev/null && [ -z "${BS_REAPER:-}" ]; then
  # (a REAPER somewhere this doesn't look is asked for, rather than a second one installed beside it)
  BS_REAPER="$(ask "REAPER wasn't found. If it's somewhere else (a portable copy), drag its folder or REAPER.app here; or press Return to install it")"
  BS_REAPER="$(printf '%s' "$BS_REAPER" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/\\\(.\)/\1/g')"; BS_REAPER="${BS_REAPER/#\~/$HOME}"; BS_REAPER="${BS_REAPER%/}"
  [ -n "$BS_REAPER" ] && ! find_reaper_app >/dev/null && warn "No REAPER in $BS_REAPER: installing one."
fi
if REAPER_APP="$(find_reaper_app)"; then ok "REAPER is already installed ($REAPER_APP)"
else
  say "Installing REAPER (a 60-day evaluation; see reaper.fm for the license) ..."
  dmg="$(curl -fsSL https://www.reaper.fm/download.php | grep -o 'files/[0-9.x]*/reaper[0-9]*_universal\.dmg' | head -1)"
  from_dmg "https://www.reaper.fm/$dmg" REAPER REAPER
fi
# An existing Syncthing, wherever it came from: the running one (its own binary, and its --home when it was given one), the app, Homebrew's.
# Then Homebrew where it's there, and the app's own download last (a GitHub lookup). Never a second Syncthing beside one already set up.
# (Installer review, 0.58.78)
ST=""; ST_RUN_HOME=""
p="$(pgrep -x syncthing | head -1)"
if [ -n "$p" ]; then
  ST="$(ps -o comm= -p "$p" 2>/dev/null)"; [ -x "$ST" ] || ST=""
  ST_RUN_HOME="$(ps -o args= -p "$p" 2>/dev/null | sed -E -n 's/.*--?(home|config)[= ]+(.*)$/\2/p' | sed -E 's/ --?[a-z].*$//; s/^"(.*)"$/\1/')"
  [ -f "$ST_RUN_HOME/config.xml" ] || ST_RUN_HOME=""
fi
if [ -z "$ST" ]; then
  for c in /Applications/Syncthing.app/Contents/Resources/syncthing/syncthing "$(command -v syncthing 2>/dev/null)" /opt/homebrew/bin/syncthing /usr/local/bin/syncthing; do
    [ -n "$c" ] && [ -x "$c" ] && { ST="$c"; break; }
  done
fi
if [ -n "$ST" ]; then ok "Syncthing is already installed"
elif command -v brew >/dev/null && say "Installing Syncthing (Homebrew) ..." && brew install --cask syncthing-app </dev/null >/dev/null 2>&1 && have Syncthing; then ok "Syncthing installed"
else say "Installing Syncthing ..."; from_dmg "$(gh_asset syncthing/syncthing-macos '\.dmg$')" Syncthing Syncthing; fi
if yes "$LIVE"; then
  if have SonoBus && { [ -d /Library/Audio/Plug-Ins/VST3/SonoBus.vst3 ] || [ -d "$HOME/Library/Audio/Plug-Ins/VST3/SonoBus.vst3" ]; }; then ok "SonoBus is already installed"
  elif command -v brew >/dev/null && say "Installing SonoBus (Homebrew; may ask for your password) ..." && brew install --cask sonobus </dev/null >/dev/null 2>&1 && have SonoBus; then ok "SonoBus installed"
  else
    say "Installing SonoBus (may ask for your password) ..."
    # (sonobus.net's own download first: not one of GitHub's 60 lookups an hour)
    sb="$(curl -fsSL https://www.sonobus.net/ 2>/dev/null | grep -o 'releases/sonobus-[0-9.]*-mac\.dmg' | head -1)"
    from_dmg "$([ -n "$sb" ] && echo "https://www.sonobus.net/$sb" || gh_asset sonosaurus/sonobus 'mac\.dmg$')" SonoBus SonoBus
  fi
  if have Tailscale; then ok "Tailscale is already installed"
  else
    say "Installing Tailscale (asks for your password) ..."
    password_note
    curl -fsSL https://pkgs.tailscale.com/stable/Tailscale-latest-macos.pkg -o "$WORK/Tailscale.pkg" && sudo installer -pkg "$WORK/Tailscale.pkg" -target / >/dev/null && ok "Tailscale installed" || warn "Tailscale didn't install: get it from tailscale.com/download"
  fi
fi
if yes "$SOLO"; then
  if have "Google Drive"; then ok "Google Drive is already installed"
  else say "Installing Google Drive for desktop (asks for your password) ..."; from_dmg https://dl.google.com/drive-file-stream/GoogleDrive.dmg GoogleDrive "Google Drive"; fi
fi
# Tailscale sign-in as a tagged group machine: a tagged machine's key never expires, so nobody has to sign in again
# before a session (untagged ones sign out every 180 days). Needs the host's one-time tagOwners line (see the end).
TS="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
TS_TAGGED=""
if yes "$LIVE" && [ -x "$TS" ]; then
  open -a Tailscale
  # (a new install runs only once macOS approves its system extension: System Settings > General > Login Items &
  # Extensions, and "Allow" for its VPN configuration. Until then every command fails, and a reset was done for nothing)
  # (a joiner without an invitation key doesn't wait; a guest does, or a new Tailscale refused the key before macOS let it run: installer review, 0.58.76)
  for i in $(seq 1 "$({ yes "$HOSTING" || [ -n "${BS_TS_KEY:-}" ]; } && echo 120 || echo 5)"); do
    "$TS" status --json 2>/dev/null | grep -q '"BackendState"' && break
    [ $i -eq 5 ] && say "Waiting for Tailscale: if macOS asks, allow its system extension (System Settings > General > Login Items & Extensions) and its VPN configuration."
    sleep 1
  done
  tsst="$("$TS" status --json 2>/dev/null | tr -d '\n ')"
  TS_RUNNING=""; echo "$tsst" | grep -q '"BackendState":"Running"' && TS_RUNNING=1
  if [ -n "${BS_TS_KEY:-}" ]; then # a guest: `login` adds the inviter's network beside any of their own (switch back from Tailscale's menu)
    if "$TS" status --json --peers=false 2>/dev/null | tr -d '\n ' | grep -q '"tag:bandsync-guest"'; then ok "Tailscale is already on the studio's network as a guest"
    # (run again, the used key always failed and said to ask for a new invitation, with the computer already on. Review, 0.58.97)
    elif "$TS" login --authkey="$BS_TS_KEY" --timeout=120s >/dev/null 2>&1; then ok "Tailscale joined the studio's network as a guest, until your invitation ends"
    else warn "Tailscale couldn't join with the invitation's key (it works once, within 2 days of the invitation): ask for a new invitation."; fi
    TS_TAGGED=1
  elif echo "$tsst" | grep -q '"Tags":\["tag:bandsync"' || { [ -n "$TS_RUNNING" ] && ! echo "$tsst" | grep -q '"KeyExpiry"'; }; then
    ok "Tailscale signed in, and stays signed in"; TS_TAGGED=1 # tagged, or its key expiry was turned off by hand
  elif [ -n "$TS_RUNNING" ]; then
    # already signed in: left exactly as it is. Re-signing in with the tag logged a Mac OUT when the tag wasn't allowed
    # yet, and the refused tag stuck in its settings so signing in again kept failing (2026-10-28)
    ok "Tailscale is signed in (it signs out by itself every few months: see the end to keep it signed in)"
  elif ! yes "$HOSTING"; then
    # (a joiner waited minutes on a sign-in page before their first song: syncing needs no Tailscale, only Play/Jam and the call do. Beginner review, 0.58.62)
    TS_TAGGED=1; TS_LATER=1
  elif [ -z "$tsst" ]; then
    # (Tailscale isn't answering yet: its system extension waits for the person to allow it. Trying to sign in now only failed with a
    # misleading "sign-in didn't finish": the wait below takes over instead. Mac review, 0.58.62)
    say "Tailscale needs its system extension allowed first: System Settings > General > Login Items & Extensions (and its VPN configuration)."
  else
    say "Signing in to Tailscale: a browser page opens; sign in there (a free account: the one your studio's Tailscale uses, if it has one). (macOS may first ask"
    say "to allow Tailscale's VPN configuration: click Allow.)"
    out="$WORK/ts_up.txt"; : > "$out"
    # (plainly: the studio tag needs Settings > Advanced > Set up the tags, done after this, so on a new network asking for it was always
    # refused and a second sign-in page followed. --reset clears a tag a run before left behind. Review, 0.58.97)
    "$TS" up --reset --timeout=300s >"$out" 2>&1 &
    pid=$!; url=""
    for i in $(seq 1 30); do url="$(grep -o 'https://login.tailscale.com/[^ ]*' "$out" | head -1)"; [ -n "$url" ] && break; kill -0 $pid 2>/dev/null || break; sleep 1; done
    [ -n "$url" ] && open "$url"
    if wait $pid; then ok "Tailscale signed in"
    else warn "Tailscale sign-in didn't finish: open Tailscale (in Applications, or its menu-bar icon) and sign in."; fi
  fi
  # what still needs a person, waited for here (James, 2026-10-31: "the installer should wait for you to sign in"):
  # signed in at all, then key expiry off, so it doesn't sign out by itself every few months. Return skips either.
  # (plutil reads the JSON: this Mac's own KeyExpiry, not a bandmate's; a grep can't tell them apart)
  # (plutil's raw output is macOS 12 and later: on an older Mac the waits never ended. Then --peers=false and a grep, which only sees this Mac.
  # Mac review, 0.58.62)
  ts_running() {
    local v; v="$("$TS" status --json 2>/dev/null | plutil -extract BackendState raw -o - - 2>/dev/null)" ||
      v="$("$TS" status --json --peers=false 2>/dev/null | tr -d '\n ' | grep -o '"BackendState":"[A-Za-z]*"' | cut -d'"' -f4)"
    [ "$v" = Running ]
  }
  ts_expires() {
    if plutil -help 2>&1 | grep -q raw; then "$TS" status --json 2>/dev/null | plutil -extract Self.KeyExpiry raw -o - - >/dev/null 2>&1
    else "$TS" status --json --peers=false 2>/dev/null | grep -q '"KeyExpiry"'; fi
  }
  if [ -z "$TS_TAGGED" ] && ! ts_running; then
    say "Sign in to Tailscale now (its menu-bar icon > Log in). Waiting for it; press Return to skip and do it later."
    while ! ts_running; do read -t 3 -r </dev/tty && break; done
    ts_running && ok "Tailscale signed in"
  fi
  # (asked once: run again, it opened the page and waited for someone every time. Mac test, 0.58.69. The end list still says it)
  TS_ASKED="$HOME/Library/Application Support/StudioSync/tailscale-expiry-asked"
  if [ -z "$TS_TAGGED" ] && ts_running && ts_expires && [ ! -f "$TS_ASKED" ]; then
    mkdir -p "$(dirname "$TS_ASKED")" && touch "$TS_ASKED"
    say "One click keeps this Mac signed in to Tailscale for good. In the page that opens: this Mac's ... menu >"
    say "Disable key expiry. Waiting for it; press Return to skip (it then signs out by itself every few months)."
    open "https://login.tailscale.com/admin/machines"
    while ts_expires; do read -t 3 -r </dev/tty && break; done
    ts_expires || { ok "Tailscale stays signed in"; TS_TAGGED=1; }
  fi
fi
# Google Drive: signed in, and the band's StudioSync folder in My Drive (the first one makes it; everyone else adds
# the shared one as a shortcut: Drive has no way to do that for you, so its page opens and this waits). Return skips.
if yes "$SOLO" && have "Google Drive"; then
  # (one My Drive per Google account signed in; with several, the one that has StudioSync is the band's, as StudioSync
  # itself looks: lib/drive.lua. Mac 0.34.4: a personal and a band account, and head -1 watched the wrong one.)
  drives() { ls -d "$HOME"/Library/CloudStorage/GoogleDrive-*/"My Drive" 2>/dev/null; }
  mydrive() {
    [ -n "${PICKED:-}" ] && [ -d "$PICKED" ] && { echo "$PICKED"; return; }
    local d; while IFS= read -r d; do [ -d "$d/$DRIVE_NAME" ] && { echo "$d"; return; }; done < <(drives)
    drives | head -1
  }
  account() { echo "$1" | sed -n 's#.*/GoogleDrive-\([^/]*\)/My Drive$#\1#p'; } # the account's e-mail, from its folder
  if [ -n "$LATER" ]; then DRIVE_OK=1 # (no studio yet, so no studio folder to make or add: the panel asks when you start one)
  elif ! yes "$HOSTING" && ! { [ -n "$(mydrive)" ] && [ -d "$(mydrive)/$DRIVE_NAME" ]; }; then
    # (as Tailscale above: a joiner's songs arrive without it, and the folder usually isn't shared with them yet. Beginner review, 0.58.62)
    DRIVE_LATER=1
  elif [ -z "$(mydrive)" ]; then
    open -a "Google Drive"
    say "Sign in to Google Drive in its window, with the Google account the studio's Drive folder is shared with (yours,"
    say "or the studio's own account if you have one). Allow its extension if macOS asks."
    say "Waiting for it; press Return to skip and do it later."
    while [ -z "$(mydrive)" ]; do read -t 3 -r </dev/tty && break; done
  fi
  MD="$(mydrive)"; { [ -n "${DRIVE_LATER:-}" ] || [ -n "$LATER" ]; } && MD=""
  if [ -n "$MD" ] && [ ! -d "$MD/$DRIVE_NAME" ] && [ "$(drives | wc -l)" -gt 1 ]; then
    say "Google Drive has several accounts signed in here. Which one is the studio's (it gets the studio's folder)?"
    i=0; while IFS= read -r d; do i=$((i + 1)); echo "    $i) $(account "$d")"; done < <(drives)
    n="$(ask "Number" 1)"
    PICKED="$(drives | sed -n "${n}p")"; [ -n "$PICKED" ] && MD="$PICKED"
  fi
  if [ -n "$MD" ] && [ -d "$MD/$DRIVE_NAME" ]; then ok "Google Drive: the studio's '$DRIVE_NAME' folder is there"; DRIVE_OK=1 # (not the account's e-mail: installer logs get pasted into bug reports. Mac test, 0.58.69)
  elif [ -n "$MD" ] && yes "$HOSTING"; then
    mkdir -p "$MD/$DRIVE_NAME" && ok "Google Drive: made '$DRIVE_NAME' in your My Drive (share it at the end)"; DRIVE_OK=1
  elif [ -n "$MD" ]; then
    say "Add the studio's Drive folder: in the page that opens, right-click '$DRIVE_NAME' > Organize > Add shortcut > My Drive."
    say "(If it isn't there yet, whoever set up first shares it with you.) Waiting; press Return to skip."
    open "https://drive.google.com/drive/shared-with-me?authuser=$(account "$MD")" # (in that account, not whichever the browser has)
    while [ ! -d "$MD/$DRIVE_NAME" ]; do read -t 3 -r </dev/tty && break; done
    [ -d "$MD/$DRIVE_NAME" ] && { ok "Google Drive: the studio's '$DRIVE_NAME' folder is there"; DRIVE_OK=1; }
  fi
fi
# the band plug-in pack (optional): free, open-source plug-ins every bandmate can have, each from its official release
# (never bundled here); what everyone has shows in REAPER's FX browser folder "StudioSync (everyone has)"
if yes "$PLUGINS"; then
  have_plugin "Surge XT" "Surge XT*" || plugin_dmg "$(gh_asset surge-synthesizer/releases-xt 'macOS-[0-9.]+\.dmg$')" "Surge XT" "Surge XT*"
  have_plugin "Dexed" "Dexed*" || plugin_dmg "$(gh_asset asb2m10/dexed 'macOS\.dmg$')" "Dexed" "Dexed*"
  have_plugin "Airwindows Consolidated" "Airwindows*" || plugin_dmg "$(gh_asset_tag baconpaul/airwin2rack DAWPlugin 'macOS.*\.dmg$')" "Airwindows Consolidated" "Airwindows*"
  have_plugin "Dragonfly Reverb" "Dragonfly*" || plugin_dmg "$(gh_asset michaelwillis/dragonfly-reverb 'macos-universal\.dmg$')" "Dragonfly Reverb" "Dragonfly*"
  have_plugin "Chow Tape Model" "CHOW*" || plugin_dmg "$(gh_asset jatinchowdhury18/AnalogTapeModel 'Mac.*\.dmg$')" "Chow Tape Model" "CHOW*"
  have_plugin "BYOD" "BYOD*" || plugin_dmg "$(gh_asset Chowdhury-DSP/BYOD 'Mac-.*\.dmg$')" "BYOD" "BYOD*"
  arch="$( [ "$ARCH" = arm64 ] && echo arm64 || echo x86-64 )"
  have_plugin "ZL Equalizer 2" "ZL Equalizer*" || plugin_dmg "$(gh_asset ZL-Audio/ZLEqualizer "macOS-$arch\.dmg$")" "ZL Equalizer 2" "ZL Equalizer*"
  have_plugin "ZL Compressor" "ZL Compressor*" || plugin_dmg "$(gh_asset ZL-Audio/ZLCompressor "macOS-$arch\.dmg$")" "ZL Compressor" "ZL Compressor*"
  have_plugin "ChowMatrix" "ChowMatrix*" || plugin_dmg "$(gh_asset Chowdhury-DSP/ChowMatrix 'Mac-.*\.dmg$')" "ChowMatrix" "ChowMatrix*"
  if yes "$EXTRAS"; then
    # NAM: v0.7.14 and later have no release files; 0.7.13 is the newest that does
    have_plugin "Neural Amp Modeler" "NeuralAmpModeler*" || plugin_dmg "$(gh_asset_tag sdatkinson/NeuralAmpModelerPlugin v0.7.13 'mac\.dmg$')" "Neural Amp Modeler" "NeuralAmpModeler*"
    have_plugin "AIDA-X" "AIDA-X*" || plugin_dmg "$(gh_asset AidaDSP/AIDA-X 'macos-universal.*\.dmg$')" "AIDA-X" "AIDA-X*"
    odin="$(gh_asset_tag TheWaveWarden/odin2 NightlyDevel 'MacInstaller\.pkg$')"
    if plugin_found "Odin2*"; then ok "Odin 2 is already installed"
    elif [ -n "$odin" ] && curl -fsSL "$odin" -o "$WORK/odin2.pkg"; then password_note; sudo installer -pkg "$WORK/odin2.pkg" -target / >/dev/null && ok "Odin 2 installed"
    else warn "Odin 2 didn't download: install it by hand"; fi
    piano="$HOME/Documents/StudioSync Instruments/Salamander Grand Piano"
    if [ -d "$piano" ]; then ok "Salamander Grand piano is already there"
    else
      say "Downloading the Salamander Grand piano (about 715 MB) ..."
      mkdir -p "$(dirname "$piano")"
      if curl -fsSL "https://github.com/sfzinstruments/SalamanderGrandPiano/archive/refs/heads/master.zip" -o "$WORK/salamander.zip" &&
         ditto -x -k "$WORK/salamander.zip" "$(dirname "$piano")" && mv "$(dirname "$piano")/SalamanderGrandPiano-master" "$piano"; then
        ok "Salamander Grand piano in $piano: play it with sforzando (free, plogue.com/products/sforzando.html)"
      else warn "the piano didn't download"; fi
    fi
    # a drum kit everyone has (DrumGizmo's MuldjordKit as SFZ, CC BY 4.0, ported by sfzinstruments): plays in the same sforzando
    drums="$HOME/Documents/StudioSync Instruments/MuldjordKit drums"
    if [ -d "$drums" ]; then ok "MuldjordKit drums are already there"
    else
      say "Downloading the MuldjordKit drums (about 330 MB) ..."
      mkdir -p "$(dirname "$drums")"
      if curl -fsSL "https://github.com/sfzinstruments/DrumGizmo.MuldjordKit/archive/refs/heads/master.zip" -o "$WORK/muldjordkit.zip" &&
         ditto -x -k "$WORK/muldjordkit.zip" "$(dirname "$drums")" && mv "$(dirname "$drums")/DrumGizmo.MuldjordKit-master" "$drums"; then
        ok "MuldjordKit drums in $drums: load its .sfz file in sforzando"
      else warn "the drums didn't download"; fi
    fi
    TELL_DECENT=1
  fi
fi
REAPER_APP="$(find_reaper_app)" || { warn "REAPER isn't installed: get it from reaper.fm and run this again."; exit 1; }
# (a portable REAPER keeps its settings beside REAPER.app when that folder has a reaper.ini. Installer review, 0.58.78)
[ -f "$(dirname "$REAPER_APP")/reaper.ini" ] && RES="$(dirname "$REAPER_APP")"
ok "REAPER: $REAPER_APP (settings in $RES)"

# ---------- 2. REAPER extensions: ReaPack and ReaImGui ----------
PLUG="$RES/UserPlugins"
need=""
[ -f "$PLUG/reaper_reapack-$ARCH.dylib" ] || need="$need reaper_reapack-$ARCH.dylib=https://github.com/cfillion/reapack/releases/download/$REAPACK/reaper_reapack-$ARCH.dylib"
[ -f "$PLUG/reaper_imgui-$ARCH.dylib" ] || need="$need reaper_imgui-$ARCH.dylib=https://github.com/cfillion/reaimgui/releases/download/v$REAIMGUI/reaper_imgui-$ARCH.dylib"
# js_ReaScriptAPI (drawing on the tracks, window placement, ReaNINJAM's mode) and SWS (links, a few actions), from the
# files ReaPack's ReaTeam Extensions index points at (both MIT); skipped when any copy of them is there already
JSF="reaper_js_ReaScriptAPI64.dylib"; [ "$ARCH" = arm64 ] && JSF="reaper_js_ReaScriptAPI64ARM.dylib"
ls "$PLUG"/reaper_js_ReaScriptAPI* >/dev/null 2>&1 || need="$need $JSF=https://github.com/juliansader/ReaExtensions/raw/master/js_ReaScriptAPI/v1.310/$JSF"
ls "$PLUG"/reaper_sws* >/dev/null 2>&1 || need="$need reaper_sws-$ARCH.dylib=https://github.com/reaper-oss/sws/releases/download/v2.14.0.7/reaper_sws-$ARCH.dylib"
if [ -n "$need" ]; then
  if pgrep -x REAPER >/dev/null; then
    say "REAPER has to restart to load its new extensions: quit REAPER now (Cmd+Q; save if it asks). It's reopened"
    say "afterwards, with your project."
    REOPEN=true
    waited=0
    while pgrep -x REAPER >/dev/null; do
      sleep 1; waited=$((waited + 1))
      [ $((waited % 30)) -eq 0 ] && say "Still waiting for REAPER to close (answer its save question if it asked one) ..."
    done
  fi
  mkdir -p "$PLUG"
  # (to a .part file first: one cut off half way stayed there, broken, and a second run said it was already installed)
  for n in $need; do
    f="$PLUG/${n%%=*}"
    if curl -fsSL "${n#*=}" -o "$f.part" && [ -s "$f.part" ] && mv -f "$f.part" "$f"; then ok "${n%%=*} installed"
    else rm -f "$f.part"; warn "${n%%=*} didn't download"; fi
  done
else ok "ReaPack, ReaImGui, js_ReaScriptAPI and SWS are already installed"; fi
API="$RES/Scripts/ReaTeam Extensions/API"
if [ ! -f "$API/imgui.lua" ]; then
  mkdir -p "$API" && curl -fsSL "https://codeberg.org/cfillion/reaimgui/raw/v$REAIMGUI/shims/imgui.lua" -o "$API/imgui.lua" && ok "ReaImGui shim installed"
fi

# ---------- 3. Syncthing: the shared folder ----------
[ -n "$ST" ] && [ -x "$ST" ] || ST="/Applications/Syncthing.app/Contents/Resources/syncthing/syncthing"
STHOME="${BS_SYNCTHING_HOME:-${ST_RUN_HOME:-$HOME/Library/Application Support/Syncthing}}"
ST_HOME_TOLD=""; [ -z "${BS_SYNCTHING_HOME:-}" ] && [ "$STHOME" != "$HOME/Library/Application Support/Syncthing" ] && ST_HOME_TOLD="$STHOME" # (studiosync_setup.lua keeps it)
[ -x "$ST" ] || { warn "Syncthing wasn't found: install it from syncthing.net and run this again."; exit 1; }
stcli() { "$ST" cli --home "$STHOME" "$@" 2>&1; }
if [ -n "${BS_SYNCTHING_HOME:-}" ]; then
  [ -f "$STHOME/config.xml" ] || "$ST" generate --home "$STHOME" >/dev/null
  "$ST" serve --no-browser --home "$STHOME" >/dev/null 2>&1 &
elif ! pgrep -x syncthing >/dev/null; then
  say "Starting Syncthing. macOS asks to let it find devices on your local network: click Allow."
  case "$ST" in
    */Syncthing.app/*) open -a "${ST%%/Contents/*}";;
    *) [ -f "$STHOME/config.xml" ] || "$ST" generate --home "$STHOME" >/dev/null # (Homebrew's: no app to start it)
       nohup "$ST" serve --no-browser --home "$STHOME" >/dev/null 2>&1 </dev/null & ;;
  esac
fi
up=""; for i in $(seq 1 60); do stcli show system >/dev/null && { up=1; break; }; sleep 1; done
[ -n "$up" ] || { warn "Syncthing didn't answer; finish its setup by hand (see installer/SKILL.md)"; exit 1; }
# (an older Syncthing (Homebrew's can lag) has no device-id: the running one's API answers either way. As install_linux.sh, 0.58.78)
is_id() { [[ "$1" =~ ^[A-Z0-9]{7}(-[A-Z0-9]{7}){7}$ ]]; }
MY_ID="$("$ST" device-id --home "$STHOME" 2>/dev/null | tail -1 | tr -d '[:space:]')"
is_id "$MY_ID" || MY_ID="$(stcli show system 2>/dev/null | sed -n 's/.*"myID": *"\([A-Z0-9-]*\)".*/\1/p' | head -1)"
# (run again by someone already in: the folder Syncthing already has for this studio, not the default. Laptop test, 0.58.69: an invitation run
# again moved a member onto a new, empty folder)
if [ -z "${BS_ROOT:-}" ] && [ -n "${FOLDER_ID:-}" ] && HAD="$(stcli config folders "$FOLDER_ID" path get)" && [ -d "$HAD" ] && [ "$HAD" != "$ROOT" ]; then
  ROOT="${HAD%/}"; say "$BAND_NAME's shared folder is already here: $ROOT"
fi
mkdir -p "$ROOT"
if yes "$HOSTING" && [ ! -f "$ROOT/_band/band.json" ]; then # (who this folder is: lib/band.lua band.info; names are plain)
  mkdir -p "$ROOT/_band"
  printf '{ "name": "%s", "id": "%s", "drive": "%s", "owner": "%s" }\n' "$BAND_NAME" "$FOLDER_ID" "$DRIVE_NAME" "$USERNAME_BS" > "$ROOT/_band/band.json"
fi
# per-song sync (lib/songsync.lua writes the same block): a new bandmate gets every song's listing, and a song in
# full once they open it, so the first sync isn't the whole library. The first one set up keeps everything.
if [ -n "$JOINING" ] && ! grep -q -e '^// StudioSync end$' -e '^// BandSync end$' "$ROOT/.stignore" 2>/dev/null; then
  printf '%s\n' '// StudioSync: what this computer downloads (written by StudioSync, up to the line below)' '!/_*' '!/plugins' '!/drummaps' '!/*/session.json' '!/*/folder.json' '!/*/live.json' '!/*/invites' '!/*/inbox' '!/*/rooms/*/room.json' '!/*/rooms/*/summary' '!/*/rooms/*/status' '(?d)/*/*' '// StudioSync end' >> "$ROOT/.stignore" && ok "this computer gets each song in full once it's opened (the rest: their listing)"
fi
LABEL="StudioSync $BAND_NAME"
if [ -n "$LATER" ]; then : # (no studio folder yet: the panel makes it when you start or join one)
elif stcli config folders list | grep -qx "$FOLDER_ID"; then ok "$BAND_NAME's shared folder is already set up"
else
  stcli config folders list | grep -q . || stcli config defaults folder path set "$(dirname "$ROOT")" >/dev/null # (fresh setup: new folders land beside it)
  stcli config folders add --id "$FOLDER_ID" --label "$LABEL" --path "$ROOT" >/dev/null && ok "$BAND_NAME's shared folder -> $ROOT"
fi
if [ -z "$LATER" ]; then
  stcli config folders "$FOLDER_ID" order set smallestFirst >/dev/null
  stcli config folders "$FOLDER_ID" fswatcher-delays set 1 >/dev/null  # the default 10 s delay added 10 s to every take
fi
stcli config devices "$MY_ID" name set "$USERNAME_BS" >/dev/null
if [ -n "$JOINING" ]; then
  stcli config devices list | grep -qx "$HOST_ID" || stcli config devices add --device-id "$HOST_ID" --name "Collaborator" --introducer >/dev/null
  stcli config folders "$FOLDER_ID" devices list | grep -qx "$HOST_ID" || stcli config folders "$FOLDER_ID" devices add --device-id "$HOST_ID" >/dev/null
  CONNECTED=""
  stcli show connections 2>/dev/null | tr -d '\n ' | grep -q "\"$HOST_ID\":{[^}]*\"connected\":true" && CONNECTED=1
  if [ -n "$CONNECTED" ]; then ok "paired with your collaborator, and connected"
  else ok "paired with your collaborator (they still have to let you in: see the end)"; fi
fi

[ -n "${BS_NO_REAPER:-}" ] && { ok "stopping before REAPER, as asked. This computer's Syncthing ID: $MY_ID"; exit 0; }

# ---------- 4. StudioSync scripts, inside REAPER ----------
if [ "$TAG" = main ]; then # the newest released version (what ReaPack serves), as Windows does: main's setup could be ahead of any release
  V="$(curl -fsSL "https://github.com/$REPO/raw/main/index.xml" 2>/dev/null | awk '/<reapack name="StudioSync.lua"/{f=1} f&&/<\/reapack>/{f=0} f' |
    grep -o 'version name="[0-9.]*"' | grep -o '[0-9][0-9.]*' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
  [ -n "$V" ] && TAG="v$V"
fi
ZREF="heads/main"; [ "$TAG" != main ] && ZREF="tags/$TAG"
curl -fsSL "https://codeload.github.com/$REPO/zip/refs/$ZREF" -o "$WORK/bandsync.zip" && ditto -x -k "$WORK/bandsync.zip" "$WORK/src"
HELPER="$(find "$WORK/src" -path '*/installer/studiosync_setup.lua' | head -1)"
[ -n "$HELPER" ] || { warn "StudioSync's setup files didn't download: check the internet connection, then run this again."; exit 1; }
HDIR="$(dirname "$HELPER")"
request() { # mode -> runs the helper in REAPER, leaves its JSON result in $HDIR/studiosync_setup_result.json
  local panel=false; [ "$1" = verify ] && panel=true
  local jsfx=false; yes "$PLUGINS" && jsfx=true
  local persona=false; yes "$REAPERSONA" && persona=true
  local js='s/\\/\\\\/g; s/"/\\"/g' # (a " or \ in a path broke the JSON)
  local bid="" bname="" inv=""; [ -n "$JOINING" ] && { bid="$FOLDER_ID"; bname="$BAND_NAME"; inv="$(printf '%s' "$HOST_ID" | LC_ALL=C tr -cd 'A-Z0-9-')"; } # (the studio's name till its band.json arrives: studiosync_setup.lua)
  printf '{"sync_root":"%s","user":"%s","mode":"%s","repo_url":"https://github.com/%s/raw/main/index.xml","open_panel":%s,"jsfx":%s,"reapersona":%s,"persona":"%s","syncthing_path":"%s","syncthing_home":"%s","band_id":"%s","band_name":"%s","host_id":"%s"}' \
    "$(printf '%s' "$ROOT" | sed -e "$js")" "$USERNAME_BS" "$1" "$REPO" "$panel" "$jsfx" "$persona" "$PERSONA" "$(printf '%s' "$ST" | sed -e "$js")" "$(printf '%s' "$ST_HOME_TOLD" | sed -e "$js")" "$bid" "$bname" "$inv" > "$HDIR/studiosync_setup.json"
  rm -f "$HDIR/studiosync_setup_result.json" "$HDIR/studiosync_setup_started"
  if [ -n "${REOPEN:-}" ] && ! pgrep -x REAPER >/dev/null; then
    # we quit REAPER: start it the way you do, so it reopens your project tabs as it always does (started WITH the
    # helper it came back with one tab, 2026-10-28), then hand it the helper once it's up
    open -a "$REAPER_APP"
    for i in $(seq 1 60); do pgrep -x REAPER >/dev/null && break; sleep 1; done
    sleep 8
  fi
  # Any Apple Event ("open -a") reaching REAPER while ReaPack's report window is open crashes it on macOS
  # (2026-10-28). A REAPER running StudioSync's background loop (Autostart, from __startup.lua) gets a request FILE
  # instead; only a REAPER that isn't running is started with the helper.
  local HOME_DIR="$RES/StudioSync" HANDED=""; [ -d "$RES/BandSync" ] && HOME_DIR="$RES/BandSync" # (lib/band.lua band.home)
  local REQ="$HOME_DIR/install-request"
  if pgrep -x REAPER >/dev/null && grep -q "BandSync autostart" "$RES/Scripts/__startup.lua" 2>/dev/null; then
    mkdir -p "$HOME_DIR"; printf '%s' "$HELPER" > "$REQ"
    for i in $(seq 1 20); do [ -f "$REQ" ] || { HANDED=1; break; }; sleep 1; done
    rm -f "$REQ" # not picked up (an older StudioSync, or a window holding REAPER): asked the other way below
  fi
  if [ -z "$HANDED" ]; then
    if pgrep -x REAPER >/dev/null; then
      say "REAPER is about to run StudioSync's setup step. First close any ReaPack window in REAPER (like its"
      say "'Transaction report'): one left open makes REAPER quit. Then press Return."
      read -r </dev/tty
    fi
    open -a "$REAPER_APP" "$HELPER" # ONE request: the helper waits inside REAPER for ReaPack itself
  fi
  GONE=""
  # (a REAPER's first start scans every plug-in before it runs anything: 6 minutes and more with a big collection, and the 6 minutes this
  # waited ran out first. Until the helper starts (its first act writes studiosync_setup_started), this waits while REAPER is open, and says
  # what's happening; once it has, the 4 minutes the helper gives ReaPack and the 2.5 it gives ReaPersona. Installer review, 0.58.78)
  local i=0 at=""
  while [ ! -f "$HDIR/studiosync_setup_result.json" ]; do
    i=$((i + 1))
    [ -z "$at" ] && [ -f "$HDIR/studiosync_setup_started" ] && at=$i
    if [ -n "$at" ]; then [ $((i - at)) -gt 420 ] && break; elif [ $i -gt 2700 ]; then break; fi
    if [ $i -gt 15 ] && ! pgrep -x REAPER >/dev/null; then GONE=1; break; fi
    [ $i -eq 30 ] && say "Waiting for StudioSync to arrive through ReaPack. ReaPack opens its own windows on a first run (Manage repositories, Notice, Transaction report): press OK on them (another window may be covering them)."
    [ -z "$at" ] && [ $i -gt 90 ] && [ $((i % 120)) -eq 0 ] && say "Still waiting ($((i / 60)) minutes). A first start scans every plug-in on this Mac before anything else runs: 10 minutes or more with a big collection (REAPER's window names each one). Nothing is stuck while REAPER is open."
    sleep 1
  done
  [ -f "$HDIR/studiosync_setup_result.json" ]
}
say "Setting up StudioSync inside REAPER. REAPER opens now; the first time, it scans your plug-ins (a while) and asks a few things:"
say "  'Select your audio device now?': No is fine for now (pick your audio interface in Settings > Audio before you play). ReaPack's 'Manage repositories' and 'Transaction report': OK."
say "macOS may ask to let REAPER use the microphone: click Allow, or your takes record silence."
if request "${BS_SCRIPTS:-reapack}"; then
  if grep -q '"ok": *false' "$HDIR/studiosync_setup_result.json"; then warn "REAPER setup step had problems:"; cat "$HDIR/studiosync_setup_result.json"
  else ok "REAPER: name, shared folder and StudioSync repository set"; fi
elif [ -n "$GONE" ]; then warn "REAPER closed unexpectedly during setup. Open REAPER (and your project: File > Recent projects), then run this again."; exit 1
else
  # (REAPER still on its own first-start windows, often behind another one, or ReaPack still bringing StudioSync: the setup step carries on by
  # itself once they're answered, so its files stay and the rest of this runs. "Didn't run the setup step ... run this again" was wrong:
  # Windows Sandbox run, 0.58.78)
  PENDING=1; trap - EXIT
  if [ -f "$HDIR/studiosync_setup_started" ]; then warn "StudioSync's setup step is still running inside REAPER (ReaPack is taking its time): it finishes by itself, and StudioSync's panel opens when it's done."
  else warn "REAPER hasn't got to StudioSync's setup step yet: it's still on its first-start windows (the audio device, ReaPack's Manage repositories, Notice and Transaction report), which other windows may be hiding. Answer them: setup then carries on by itself, and StudioSync's panel opens when it's done."; fi
  warn "Run this again only if the panel never appears."
fi
if [ -z "${PENDING:-}" ]; then
  count="$(grep -o '"registered_actions": *[0-9]*' "$HDIR/studiosync_setup_result.json" | grep -o '[0-9]*$')"
  bver="$(grep -o '"version": *"[^"]*"' "$HDIR/studiosync_setup_result.json" | sed 's/.*"\([^"]*\)"$/\1/')"
  [ "${count:-0}" -ge 5 ] && ok "StudioSync ${bver:-} installed: $count actions (the StudioSync panel opens in REAPER)" || warn "StudioSync's scripts haven't arrived yet: in REAPER, Extensions > ReaPack > Synchronize packages"
fi

# ---------- 5. what's left for a human ----------
echo
say "Done. What's left (these need you):"
pnote="$(grep -o '"persona_note": *"[^"]*"' "$HDIR/studiosync_setup_result.json" 2>/dev/null | sed -e 's/^"persona_note": *"//' -e 's/"$//')"
[ -n "$pnote" ] && echo "  - $pnote" # (ReaPersona set up as your DAW: what it did, and the one step left without Python)
[ -n "${TELL_DECENT:-}" ] && echo "  - Decent Sampler (free sampler with lots of free instruments) can't be installed for you: its maker asks for an email address first. Get it at decentsamples.com/product/decent-sampler-plugin."
if yes "$HOSTING"; then
  echo "  - To bring in a collaborator: StudioSync panel > Invite a collaborator, and send them what it copies (their installer is"
  echo "    then already paired with you). When they've run it, the panel shows 'Let them in': press it."
  echo "    (Your Syncthing device ID, if they ask for it:  $MY_ID)"
fi # (a joiner's note is the last one: two said the same thing. AgentBox, 0.58.65)
if yes "$LIVE" && [ -z "$TS_TAGGED" ] && ts_running 2>/dev/null; then # (signed in: only the expiry is left)
  echo "  - Tailscale: at login.tailscale.com/admin/machines > this Mac > ... > Disable key expiry (otherwise it signs out every"
  echo "    few months, maybe right before a session)."
elif yes "$LIVE" && [ -z "$TS_TAGGED" ]; then
  echo "  - Tailscale (skipped above): sign in from its menu-bar icon, then at login.tailscale.com/admin/machines > this"
  echo "    Mac > ... > Disable key expiry (otherwise it signs out every few months, maybe right before a session)."
fi
if yes "$LIVE" && yes "$HOSTING"; then # the first one's job, once: then bandmates' installers sign their machines in for good
  echo "  - Tailscale, once for the whole studio (if not done yet): in REAPER, StudioSync's panel > Settings > Advanced: add a"
  echo "    Tailscale access token, then press Set up the tags (it adds the policy line for you)."
  echo "    Then each collaborator's installer signs their machine in as a studio machine that never has to sign in again."
fi
if yes "$SOLO" && yes "$HOSTING" && [ -n "${DRIVE_OK:-}" ]; then
  echo "  - Google Drive: share the '$DRIVE_NAME' folder in your My Drive with each collaborator (Editor), at drive.google.com."
elif yes "$SOLO" && [ -n "${DRIVE_LATER:-}" ]; then
  echo "  - Google Drive (the studio's backup copy, optional): once it's shared with you, at drive.google.com: Shared with me >"
  echo "    right-click '$DRIVE_NAME' > Organize > Add shortcut > My Drive."
elif yes "$SOLO" && [ -z "${DRIVE_OK:-}" ]; then
  echo "  - Google Drive (skipped above): sign in, then at drive.google.com: Shared with me > right-click '$DRIVE_NAME' >"
  echo "    Organize > Add shortcut > My Drive."
fi
if yes "$HOSTING"; then
  echo "  - In REAPER, open your song's project: the StudioSync panel offers 'Share this project with the studio'."
elif [ -n "$LATER" ]; then
  echo "  - When you want a studio: REAPER's StudioSync panel has Start a studio, and Paste join code for an invitation someone sends you."
  [ -n "${TS_LATER:-}" ] && echo "  - Tailscale (only for Time-sync and Play along; Real time mode and the call don't need it): ask whoever runs the studio for an invitation to its Tailscale network, then sign in from its menu-bar icon."
elif [ -f "$ROOT/_band/band.json" ]; then # (run again by someone already in: nobody has to let them in. Mac test, 0.58.69)
  echo "  - You're already in $BAND_NAME: nothing more to do here. In StudioSync's panel, open Projects and double-click one."
else
  echo "  - Tell whoever invited you that you're set up: they press 'Let $USERNAME_BS in' in their panel (or add your Syncthing ID"
  echo "    by hand: $MY_ID). Then the studio's projects arrive by themselves: in StudioSync's panel, open Projects and double-click one."
  [ -n "${TS_LATER:-}" ] && echo "  - Tailscale (only for Time-sync and Play along; Real time mode and the call don't need it): ask whoever runs the studio for an invitation to its Tailscale network, then sign in from its menu-bar icon."
fi
