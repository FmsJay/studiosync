#!/bin/bash
# StudioSync setup for Linux: installs and sets up everything StudioSync needs, skipping whatever is already there.
# Run it in a terminal on the computer's own desktop (not over SSH: REAPER has to open):
#   curl -fsSL "https://raw.githubusercontent.com/FmsJay/studiosync/main/installer/install_linux.sh?$(date +%s)" | bash
# (the ?<time>: GitHub's cache handed out the previous installer for minutes after a release, 2026-10-31)
# The Linux twin of install_mac.sh: same questions, same answers up front, same steps. REAPER, ReaPack, ReaImGui, js_ReaScriptAPI, SWS,
# Syncthing (the shared folder), StudioSync's scripts (through ReaPack), SonoBus + Tailscale (hearing each other). Every app comes
# from its official source, and goes in for you only (your home folder): no sudo, except Tailscale, which is system-wide by
# nature (asked first; say no and it's a note at the end). Google Drive has no Linux app: skipped, with a note.
# Answers can be given up front as environment variables: BS_USER, BS_HOSTING (yes: the first one set up; later: no studio yet),
# BS_HOST_ID (a set-up bandmate's Syncthing ID), BS_ROOT, BS_LIVE / BS_SOLO (no: leave out SonoBus + Tailscale / the Google Drive note),
# BS_SCRIPTS (reapack/folder/verify), BS_TAG, BS_BAND_ID / BS_BAND_NAME (the band an invitation is for: its Syncthing folder id and
# name; the first band is "bandsync"), BS_TS_KEY (a guest invitation's Tailscale key: on the inviter's Tailscale network until the invitation ends,
# no account; lib/services.lua), BS_PLUGINS, BS_EXTRAS, BS_REAPERSONA (a DAW id, yes or no), and BS_SUDO (yes/no: the sudo steps).
# A bandmate's panel (Invite a collaborator) hands out the curl line above with BS_HOST_ID already in it.
# Testing: BS_SYNCTHING_HOME drives a separate Syncthing instance, BS_NO_REAPER stops before anything happens inside REAPER.
set -u
REPO="FmsJay/studiosync"
TAG="${BS_TAG:-main}"
REAPER_VERSION="7.86" # as the other installers; the tarball is reaper786_linux_<arch>.tar.xz
REAIMGUI="0.10.0.5"   # shortcut: pinned, like the Windows and Mac installers
REAPACK="v1.2.6"
SWS="v2.14.0.7"
JSAPI="v1.310"
# REAPER and the extensions name their Linux builds x86_64, aarch64 and armv7l (32-bit ARM)
case "$(uname -m)" in
  x86_64|amd64) ARCH=x86_64;;
  aarch64|arm64) ARCH=aarch64;;
  armv7*|armv8l|armhf) ARCH=armv7l;;
  *) echo "StudioSync's Linux setup runs on x86_64, aarch64 or armv7l computers; this one is $(uname -m)."; exit 1;;
esac
[ "$ARCH" = aarch64 ] && [ "$(getconf LONG_BIT 2>/dev/null)" = 32 ] && ARCH=armv7l # (a 64-bit kernel under a 32-bit system, as Raspberry Pi OS: 32-bit builds)
case "$ARCH" in x86_64) GOARCH=amd64; DEBARCH=amd64;; aarch64) GOARCH=arm64; DEBARCH=arm64;; *) GOARCH=arm; DEBARCH=armhf;; esac
CFG="${XDG_CONFIG_HOME:-$HOME/.config}"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}"
BIN="$HOME/.local/bin"
# (the whole invitation pasted at once runs every line: a Mac ran this one after its own. Installer review, 0.58.76)
[ "$(uname -s)" = Linux ] || { echo "This is the Linux setup. On a Mac, use the invitation's Mac line; on Windows, its Windows line."; exit 1; }
[ "$(id -u)" = 0 ] && { echo "Run this as yourself, not as root (no sudo in front of it): everything goes in your own home folder, and it asks before the one step that needs sudo."; exit 1; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/studiosync_setup.XXXXXX")"
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
{ while IFS= read -r -t 0.3 _ </dev/tty; do :; done; } 2>/dev/null
# (curl | bash: bash reads the rest of this script from stdin, so nothing started here may read it: </dev/null)
detach() { setsid "$@" >/dev/null 2>&1 </dev/null & }
browse() { say "  Opening $1"; command -v xdg-open >/dev/null && detach xdg-open "$1"; } # (said too: no browser on some desktops)
told_pw=""
sudo_ok() { # what -> true once the person says yes to a sudo step (BS_SUDO answers it up front)
  command -v sudo >/dev/null || { warn "$1 needs sudo, which this computer doesn't have: skipped"; return 1; }
  case "${BS_SUDO:-}" in
    [yY]*) ;;
    [nN]*) return 1;;
    *) yes "$(ask "$1 needs your password (sudo: it installs system-wide). Do it now? (y/n)" y)" || return 1;;
  esac
  [ -n "$told_pw" ] && return 0
  told_pw=1 # (before the first sudo: a bare password prompt looks like something's wrong)
  say "Type your login password when sudo asks: nothing shows while you type, that's normal. It's used only to install."
}

say "StudioSync setup"
echo "This installs what StudioSync needs and sets it up. It asks a few questions first (unless they were given up front)."
echo "Everything goes in for you only, in your home folder; the one thing that needs your password (sudo) is asked first,"
echo "and can be skipped. Nothing already installed is changed."
echo

# Only the plug-ins (BS_PLUGINS_ONLY=1, and BS_EXTRAS=y for the extras: the panel's Plugins page, Get the plug-in pack. 0.59.22): the
# questions, the apps and everything after the plug-in pack are skipped; the helpers they share still load.
if [ -n "${BS_PLUGINS_ONLY:-}" ]; then
  PLUGINS=y; EXTRAS="${BS_EXTRAS:-n}"
  say "Getting StudioSync's plug-in pack$(yes "$EXTRAS" && echo ' and the extras') ..."
else
# ---------- 0. questions ----------
# (names are plain letters, digits, spaces, - and _: the default is shown already cleaned, and a typed name that
# changes when cleaned is said, not changed silently)
say "A studio is the people you make music with: StudioSync shares your projects with them as you work."
# Joining or starting comes from the invitation: pasted (or already in the line it gave), you join; none, you start a studio.
# Asked first, so a pasted message can't answer the others. (as install_mac.sh)
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
# No invitation and no studio of your own yet: everything installs, and the studio waits. BS_HOSTING=later says so up front.
LATER=""
if [ "${BS_HOSTING:-}" = later ]; then HOSTING=n; LATER=1
elif [ -n "${BS_HOSTING:-}" ]; then HOSTING="$BS_HOSTING" # (the old way of saying "I'm the first")
elif [ -n "${BS_HOST_ID:-}" ]; then HOSTING=n # (an invitation's line: someone is set up, and that's their ID)
else
  say "Did someone send you an invitation to their studio? Paste it here (all of it, or just its line starting studiosync-join)."
  say "Starting a studio of your own right now? Type s. Neither yet? Just press Enter: start one or join one later, from StudioSync's panel."
  HOSTING=n
  while :; do
    text=""; read -r -p "Invitation: " text </dev/tty # (no -e: with bash 5.2's bracketed paste a pasted invitation kept only its first line)
    # (a whole message pasted is several lines: the rest are read here too, or they'd answer the next questions)
    while IFS= read -r -t 1 l </dev/tty; do text="$text"$'\n'"$l"; done
    trimmed="$(printf '%s' "$text" | tr -d '[:space:]')"
    [ -z "$trimmed" ] && { LATER=1; break; }
    case "$trimmed" in s|S|start|Start) HOSTING=y; break;; esac
    if read_invite "$text"; then
      BS_HOST_ID="$INV_ID"; BS_BAND_ID="$INV_BAND"; BS_BAND_NAME="$INV_NAME"; [ -n "$INV_KEY" ] && [ -z "${BS_TS_KEY:-}" ] && BS_TS_KEY="$INV_KEY"
      ok "Joining ${INV_NAME:-their studio}"; break
    fi
    warn "That isn't an invitation. Paste it again (the line starting studiosync-join is enough), type s to start a studio, or press Enter for later."
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
  full="$(getent passwd "$USER" 2>/dev/null | cut -d: -f5 | cut -d, -f1 | cut -d' ' -f1)"
  typed="$(ask "Your name, as the studio will see it (you can change it later)" "$(plain "${full:-$USER}")")"
  USERNAME_BS="$(plain "$typed")"
  [ -n "$USERNAME_BS" ] && [ "$USERNAME_BS" != "$typed" ] && say "Using the name '$USERNAME_BS' (plain letters only)."
  # (a name in another alphabet cleans to nothing, and the question came back with no word why. Installer review, 0.58.78)
  [ -z "$USERNAME_BS" ] && [ -n "$typed" ] && warn "Names here are in Latin letters (A to Z), digits, spaces, - and _: type yours that way."
done
# the band (docs/bands-design.md): each its own shared folder. An invitation names it; the first one set up names it.
FOLDER_ID="$(printf '%s' "${BS_BAND_ID:-}" | LC_ALL=C tr 'A-Z' 'a-z' | LC_ALL=C tr -cd 'a-z0-9-')"
if [ -n "$JOINING" ] && [ -z "$FOLDER_ID" ]; then # (someone's device ID typed in by hand, no invitation)
  FOLDER_ID="$(ask "The studio's ID, if whoever set it up gave you one (press Enter if not)" bandsync | LC_ALL=C tr -cd 'a-z0-9-')"
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
DEF_ROOT="$HOME/StudioSync"; [ -d "$HOME/BandSync" ] && DEF_ROOT="$HOME/BandSync" # (the first studio, id bandsync: set up before the rename keeps its BandSync folder)
if [ "$FOLDER_ID" != bandsync ]; then DEF_ROOT="$HOME/StudioSync $BAND_NAME"; fi
# (later: an empty StudioSync folder, so a studio started or joined from the panel goes beside it, in your home folder: services.new_band)
[ -n "$LATER" ] && DEF_ROOT="$HOME/StudioSync"
while :; do
  # (not asked: nobody new knows what to answer. Beginner review, 0.58.62)
  ROOT="${BS_ROOT:-$DEF_ROOT}"
  ROOT="$(printf '%s' "$ROOT" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e "s/^'\(.*\)'$/\1/")" # (dragged in from a file manager: quoted, with a trailing space)
  ROOT="${ROOT/#\~/$HOME}"
  ROOT="${ROOT%/}"
  case "$ROOT" in /*) break;; esac
  warn "BS_ROOT isn't a full folder path (it should start with / or ~): using $DEF_ROOT instead."
  BS_ROOT=""
done
[ -z "$LATER" ] && say "$BAND_NAME's shared folder: $ROOT"
# The first one set up: an ID of the group's own. Run again on the same folder, it keeps the ID it has; a folder from before
# groups had IDs, with no band.json yet, is "bandsync" (lib/band.lua band.info).
if [ -z "$FOLDER_ID" ] && [ -z "$LATER" ]; then
  if [ -f "$ROOT/_band/band.json" ]; then FOLDER_ID="$(sed -n 's/.*"id"[^"]*"\([^"]*\)".*/\1/p' "$ROOT/_band/band.json" | head -1)"
  elif [ -n "$(ls -A "$ROOT" 2>/dev/null)" ]; then FOLDER_ID=bandsync; fi
  if [ -z "$FOLDER_ID" ]; then
    SLUG="$(printf '%s' "$BAND_NAME" | tr '[:upper:]' '[:lower:]' | LC_ALL=C sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
    FOLDER_ID="studiosync-${SLUG:-group}-$(printf '%04x' $((RANDOM * 2)))"
  fi
fi
DRIVE_NAME="StudioSync"; [ "$FOLDER_ID" != bandsync ] && DRIVE_NAME="StudioSync - $BAND_NAME" # (band.json keeps it: a bandmate on Windows or a Mac uses it)
# SonoBus + Tailscale (hearing each other) and the Google Drive copy are part of StudioSync, not asked; BS_LIVE=no / BS_SOLO=no leave them out.
LIVE="${BS_LIVE:-y}"
SOLO="${BS_SOLO:-y}"
if [ -z "${BS_PLUGINS:-}" ]; then
  say "The free plug-in pack: synths, guitar and bass amps, a tuner, EQ, compressor, reverb, delay, tape, drum kits and keys"
  say "(Surge XT, Dexed, OB-Xf, Airwindows, Dragonfly, Chow, BYOD, ZL and more: the ones with a Linux version), so everyone hears the same sounds."
fi
PLUGINS="${BS_PLUGINS:-$(ask "Install it? (recommended) (y/n)" y)}"
EXTRAS="${BS_EXTRAS:-n}"
# (asked of everyone: asked only of whoever started the studio (beginner review, 0.58.62), a joiner could hear those parts through their
# prints but not play or change them. James, 0.59.22. Also any time later: the panel's Plugins page.)
if yes "$PLUGINS" && [ -z "${BS_EXTRAS:-}" ]; then
  say "The bigger extras (about 1.2 GB): a grand piano, a real drum kit, an amp capture player, vocal tuning, a 303 bass, mallets, and the Odin 2 and Monique synths."
  [ -n "$JOINING" ] && say "Without them you still hear parts made with them, but can't play or change those sounds. You can add them later: StudioSync's Plugins page."
  EXTRAS="$(ask "Install the extras too? (y/n)" n)"
fi
# ReaPersona: which app you're used to, as one question, and it's set up as that DAW in the same run. BS_REAPERSONA: a DAW id
# (ReaPersona's own, styles.json), yes or no.
PERSONA_IDS="pro_tools pro_tools_intro logic garageband ableton fl_studio cubase nuendo studio_one bitwig cakewalk reason audacity audition"
PERSONA=""
case "${BS_REAPERSONA:-}" in
  [yY]*|[nN]|[nN][oO]) ;;
  "")
    say "Used to another music app? REAPER can take on its shortcuts, mouse and look (ReaPersona, free; switch back any time):"
    i=0; for n in "Pro Tools" "Pro Tools Intro (the free one)" "Logic Pro" "GarageBand" "Ableton Live" "FL Studio" "Cubase" "Nuendo" "Studio One or Fender Studio Pro" "Bitwig Studio" "Cakewalk or Sonar" "Reason" "Audacity" "Adobe Audition"; do
      i=$((i + 1)); printf '  %2d) %s\n' "$i" "$n"; done
    while :; do
      n="$(ask "Its number, or Enter for none")"
      [ -z "$n" ] && break
      case "$n" in *[!0-9]*) ;; *) [ "$n" -ge 1 ] && [ "$n" -le 14 ] && { PERSONA="$(echo "$PERSONA_IDS" | cut -d' ' -f"$n")"; break; };; esac
      warn "A number from the list, or Enter."
    done;;
  *) PERSONA="$(printf '%s' "$BS_REAPERSONA" | tr '[:upper:]' '[:lower:]' | LC_ALL=C tr -cd 'a-z0-9_')";;
esac
REAPERSONA=n; { [ -n "$PERSONA" ] || yes "${BS_REAPERSONA:-n}"; } && REAPERSONA=y
echo

fi # (BS_PLUGINS_ONLY: the questions)
say "Downloads show no progress here: a pause of a few minutes on a big one is normal."
# ---------- 1. apps ----------
# GitHub's release lookups: each is one of the 60 an hour GitHub allows a network that isn't signed in, and a band installing in one room ran
# out. So each answer is kept for an hour (a second run asks nothing), and once the limit is reached (403, X-RateLimit-Remaining: 0) the
# release's own web page is read instead, which isn't counted; said once, with when the limit resets. (Installer review, 0.58.78)
GH_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/studiosync/github"
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
gh_asset_tag() { # repo tag regex -> download URL of that release's asset matching it
  gh_release "$1" "tags/$2" | grep -E -e "$3" | head -1
}
unpack() { # archive dir: a .deb is only unpacked (dpkg-deb -x needs no root), never installed system-wide
  mkdir -p "$2"
  case "$1" in
    *.deb) if command -v dpkg-deb >/dev/null; then dpkg-deb -x "$1" "$2"
           else (cd "$2" && ar x "$1" && tar -xf data.tar.* && rm -f data.tar.* control.tar.* debian-binary); fi;;
    *.zip) if command -v unzip >/dev/null; then unzip -q -o "$1" -d "$2" </dev/null; else python3 -I -m zipfile -e "$1" "$2"; fi;;
    *) tar -xf "$1" -C "$2";;
  esac
}
# REAPER: the running one first (as the Windows installer), then the usual places. Its own install script puts it in ~/opt/REAPER.
# A Flatpak REAPER (Flathub's fm.reaper.Reaper) answers "flatpak", an AppImage its own file: each starts differently and keeps its settings
# elsewhere (below). BS_REAPER, or the answer when none is found: a folder holding a portable REAPER. (Cross-platform review, 0.58.78)
find_reaper() {
  local p c
  p="$(pgrep -x reaper | head -1)"
  if [ -n "$p" ]; then
    [ -f "/proc/$p/root/.flatpak-info" ] && { echo flatpak; return 0; }
    c="$(tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | sed -n 's/^APPIMAGE=//p' | head -1)"; [ -n "$c" ] && [ -x "$c" ] && { echo "$c"; return 0; }
    c="$(readlink -f "/proc/$p/exe" 2>/dev/null)"; [ -x "$c" ] && { echo "$c"; return 0; }
  fi
  if [ -n "${BS_REAPER:-}" ]; then
    for c in "$BS_REAPER" "$BS_REAPER/reaper"; do [ -f "$c" ] && [ -x "$c" ] && { echo "$c"; return 0; }; done
  fi
  c="$(command -v reaper 2>/dev/null)" && c="$(readlink -f "$c")" && [ -x "$c" ] && { echo "$c"; return 0; }
  for c in "$HOME/opt/REAPER/reaper" /opt/REAPER/reaper "$HOME/REAPER/reaper"; do [ -x "$c" ] && { echo "$c"; return 0; }; done
  command -v flatpak >/dev/null && flatpak info fm.reaper.Reaper >/dev/null 2>&1 && { echo flatpak; return 0; }
  for c in "$HOME"/Applications/*[Rr][Ee][Aa][Pp][Ee][Rr]*.AppImage "$HOME"/*[Rr][Ee][Aa][Pp][Ee][Rr]*.AppImage "$HOME"/Downloads/*[Rr][Ee][Aa][Pp][Ee][Rr]*.AppImage; do
    [ -f "$c" ] && [ -x "$c" ] && { echo "$c"; return 0; }
  done
  return 1
}

if [ -z "${BS_PLUGINS_ONLY:-}" ]; then # (BS_PLUGINS_ONLY: not the apps)
if ! find_reaper >/dev/null && [ -z "${BS_REAPER:-}" ]; then
  # (a REAPER somewhere this doesn't look is asked for, rather than a second one installed beside it. Installer review, 0.58.78)
  BS_REAPER="$(ask "REAPER wasn't found. If it's somewhere else (a portable copy), type the folder it's in; or press Enter to install it")"
  BS_REAPER="$(printf '%s' "$BS_REAPER" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e "s/^'\(.*\)'$/\1/")"; BS_REAPER="${BS_REAPER/#\~/$HOME}"
  [ -n "$BS_REAPER" ] && ! find_reaper >/dev/null && warn "No REAPER in $BS_REAPER: installing one."
fi
if REAPER_BIN="$(find_reaper)"; then ok "REAPER is already installed ($REAPER_BIN)"
else
  say "Installing REAPER $REAPER_VERSION into ~/opt/REAPER (a 60-day evaluation; see reaper.fm for the license) ..."
  rtar="$WORK/reaper.tar.xz"
  if curl -fsSL "https://www.reaper.fm/files/${REAPER_VERSION%%.*}.x/reaper${REAPER_VERSION//./}_linux_$ARCH.tar.xz" -o "$rtar" && tar -xJf "$rtar" -C "$WORK"; then
    # (its own script: --install copies to ~/opt/REAPER, --integrate-user-desktop adds the menu entry and .rpp files for you only)
    sh "$WORK/reaper_linux_$ARCH/install-reaper.sh" --install "$HOME/opt" --integrate-user-desktop --quiet >"$WORK/reaper_install.log" 2>&1 </dev/null
    if [ -x "$HOME/opt/REAPER/reaper" ]; then
      mkdir -p "$BIN"; [ -e "$BIN/reaper" ] || ln -s "$HOME/opt/REAPER/reaper" "$BIN/reaper"
      ok "REAPER installed (in your applications menu, and as 'reaper' in a new terminal)"
    else warn "REAPER didn't install:"; tail -5 "$WORK/reaper_install.log"; fi
    rm -rf "$rtar" "$WORK/reaper_linux_$ARCH"
  else warn "REAPER didn't download: get it from reaper.fm"; fi
fi
# An existing Syncthing's settings folder, wherever it keeps them: the running one's --home or --config (a systemd unit, a script), its
# STHOMEDIR, or the default under its own HOME and XDG folders (a snap's are under ~/snap/syncthing). That one is set up, never a second
# Syncthing with a second identity beside it. -> the folder, or nothing. (Installer review, 0.58.78)
st_running_home() {
  local p v e h d best=""
  for p in $(pgrep -x syncthing); do
    v="$(tr '\0' '\n' < "/proc/$p/cmdline" 2>/dev/null | awk 'f { print; exit } /^--?(home|config)=/ { sub(/^[^=]*=/, ""); print; exit } /^--?(home|config)$/ { f = 1 }')"
    e="$(tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null)"
    [ -n "$v" ] || v="$(printf '%s\n' "$e" | sed -n 's/^ST\(HOME\|CONF\)DIR=//p' | head -1)"
    if [ -z "$v" ]; then # (both defaults can have a config.xml: Syncthing rewrites its own at every start, so the newer one is the one in use)
      h="$(printf '%s\n' "$e" | sed -n 's/^HOME=//p' | head -1)"; h="${h:-$HOME}"
      for d in "$(printf '%s\n' "$e" | sed -n 's/^XDG_STATE_HOME=//p' | head -1)" "$h/.local/state" "$(printf '%s\n' "$e" | sed -n 's/^XDG_CONFIG_HOME=//p' | head -1)" "$h/.config"; do
        [ -n "$d" ] && [ -f "$d/syncthing/config.xml" ] && { [ -z "$best" ] || [ "$d/syncthing/config.xml" -nt "$best/config.xml" ]; } && best="$d/syncthing"
      done
      v="$best"
    fi
    [ -n "$v" ] && [ -f "$v/config.xml" ] && { echo "$v"; return 0; }
  done
  return 1
}
# (a distro's Syncthing before 1.19 (Ubuntu 22.04 has 1.18) has no serve, generate or device-id: one that isn't already running is passed
# over for the current release, in your home folder. Cross-platform review, 0.58.78)
st_old() { "$1" --version 2>/dev/null | head -1 | grep -Eq ' v(0\.|1\.([0-9]|1[0-8])\.)'; }
ST="$(command -v syncthing 2>/dev/null)"; [ -z "$ST" ] && [ -x "$BIN/syncthing" ] && ST="$BIN/syncthing"
ST_RUN_HOME="$(st_running_home)"
p="$(pgrep -x syncthing | head -1)"; [ -z "$ST" ] && [ -n "$p" ] && c="$(readlink -f "/proc/$p/exe" 2>/dev/null)" && [ -x "$c" ] && ST="$c"
if [ -n "$ST" ] && [ -z "$ST_RUN_HOME" ] && st_old "$ST"; then
  warn "This computer's Syncthing ($("$ST" --version 2>/dev/null | head -1 | cut -d' ' -f2)) is too old for StudioSync: the current one goes in your home folder beside it."
  ST=""; [ -x "$BIN/syncthing" ] && ! st_old "$BIN/syncthing" && ST="$BIN/syncthing"
fi
if [ -n "$ST" ]; then ok "Syncthing is already installed${ST_RUN_HOME:+ (and running, with its settings in $ST_RUN_HOME)}"
else
  say "Installing Syncthing ..."
  # Homebrew first where it's there (it keeps it updated); then Syncthing's own release server (what Syncthing's own upgrades use: not GitHub,
  # so not one of its 60 lookups an hour), then GitHub's; the distribution's package last, as it needs sudo and is often years old (1.18, 1.27)
  if command -v brew >/dev/null && brew install syncthing </dev/null >/dev/null 2>&1 && [ -x "$(brew --prefix)/bin/syncthing" ]; then
    ST="$(brew --prefix)/bin/syncthing"; ok "Syncthing installed (Homebrew)"
  else
    url="$(curl -fsSL https://upgrades.syncthing.net/meta.json 2>/dev/null | grep -o "\"url\": *\"https://[^\"]*/syncthing-linux-$GOARCH-v[0-9.]*\.tar\.gz\"" | head -1 | sed 's/.*"\(https[^"]*\)"$/\1/')"
    [ -n "$url" ] || url="$(gh_asset syncthing/syncthing "syncthing-linux-$GOARCH-v[0-9.]+\.tar\.gz$")"
    if [ -n "$url" ] && curl -fsSL "$url" | tar -xz -C "$WORK" && mkdir -p "$BIN" && install -m 755 "$WORK"/syncthing-linux-*/syncthing "$BIN/syncthing"; then
      ST="$BIN/syncthing"; ok "Syncthing installed (into ~/.local/bin)"
    else
      pm=""; for c in apt-get dnf zypper pacman; do command -v $c >/dev/null && { pm=$c; break; }; done
      if [ -n "$pm" ] && sudo_ok "Syncthing from your distribution (its download didn't work)"; then
        case "$pm" in pacman) sudo pacman -S --noconfirm syncthing;; *) sudo "$pm" install -y syncthing;; esac </dev/null >/dev/null 2>&1
        ST="$(command -v syncthing 2>/dev/null)"
      fi
      [ -n "$ST" ] && ok "Syncthing installed" || warn "Syncthing didn't install: get it from syncthing.net"
    fi
  fi
fi
SONO_LIBS=""
if yes "$LIVE"; then
  if command -v sonobus >/dev/null || [ -x "$BIN/sonobus" ] || ls -d "$HOME/.vst3/SonoBus.vst3" /usr/lib/vst3/SonoBus.vst3 /usr/local/lib/vst3/SonoBus.vst3 >/dev/null 2>&1; then
    ok "SonoBus is already installed"
  else
    # sonobus.net's own Debian package (there's no other Linux download), unpacked for you only and checked against its index's SHA256
    say "Installing SonoBus (for you only, no password) ..."
    pk="$(curl -fsSL "https://pkg.sonobus.net/apt/dists/stable/main/binary-$DEBARCH/Packages" | awk '/^Filename:/{f=$2} /^SHA256:/{s=$2} END{print f, s}')"
    deb="$WORK/sonobus.deb"; x="$WORK/sonobus"
    if [ -n "${pk% *}" ] && curl -fsSL "https://pkg.sonobus.net/apt/${pk% *}" -o "$deb" && [ "$(sha256sum "$deb" | cut -d' ' -f1)" = "${pk#* }" ] && unpack "$deb" "$x"; then
      mkdir -p "$BIN" "$HOME/.vst3"
      install -m 755 "$x/usr/bin/sonobus" "$BIN/sonobus" && cp -rf "$x"/usr/lib/vst3/*.vst3 "$HOME/.vst3/" && ok "SonoBus installed (the app in ~/.local/bin, the plug-in in ~/.vst3)"
      # its libraries (JACK, Opus) are the system's: missing ones are installed only with a yes
      if ldd "$BIN/sonobus" 2>/dev/null | grep -q 'not found'; then
        if command -v apt-get >/dev/null && sudo_ok "SonoBus's audio libraries (libjack-jackd2-0, libopus0)"; then
          sudo apt-get install -y libjack-jackd2-0 libopus0 </dev/null >/dev/null && ok "SonoBus's libraries installed"
        fi
        ldd "$BIN/sonobus" 2>/dev/null | grep -q 'not found' && SONO_LIBS="$(ldd "$BIN/sonobus" | awk '/not found/{print $1}' | tr '\n' ' ')"
      fi
    else warn "SonoBus didn't install: see sonobus.net/linux.html"; fi
    rm -rf "$deb" "$x"
  fi
  if command -v tailscale >/dev/null; then ok "Tailscale is already installed"
  elif sudo_ok "Tailscale (hearing each other live, and Play/Jam)"; then
    say "Installing Tailscale with its official script (tailscale.com/install.sh) ..."
    # (operator: so you, and StudioSync, can sign in and check it without sudo from now on)
    if curl -fsSL https://tailscale.com/install.sh | sh && sudo tailscale set --operator="$USER" </dev/null; then ok "Tailscale installed"
    else warn "Tailscale didn't install: see tailscale.com/download/linux"; fi
  fi
fi
# Tailscale sign-in as a tagged group machine: a tagged machine's key never expires, so nobody has to sign in again
# before a session (untagged ones sign out every 180 days). Needs the host's one-time tagOwners line (see the end).
TS="$(command -v tailscale 2>/dev/null)"
TS_TAGGED=""
TS_OP_ASKED=""
ts_operator() { # once: lets this user run tailscale up/login without sudo (a Tailscale installed before, without it)
  [ -n "$TS_OP_ASKED" ] && return 1
  TS_OP_ASKED=1
  sudo_ok "Letting you sign in to Tailscale without sudo (tailscale set --operator=$USER)" && sudo "$TS" set --operator="$USER" </dev/null
}
ts_run() { # out-file tailscale-args... -> runs it, opens a sign-in page it prints; its exit code. Refused for want of rights: once more after ts_operator
  local out="$1" pid url i; shift
  : > "$out"
  "$TS" "$@" >"$out" 2>&1 </dev/null &
  pid=$!; url=""
  for i in $(seq 1 30); do url="$(grep -o 'https://login.tailscale.com/[^ ]*' "$out" | head -1)"; [ -n "$url" ] && break; kill -0 $pid 2>/dev/null || break; sleep 1; done
  [ -n "$url" ] && browse "$url"
  wait $pid && return 0
  grep -qi 'access denied' "$out" && ts_operator && ts_run "$out" "$@"
}
# (--peers=false: this computer's own state only; a bandmate's KeyExpiry would otherwise read as this one's)
ts_running() { "$TS" status --json --peers=false 2>/dev/null | tr -d '\n ' | grep -q '"BackendState":"Running"'; }
ts_expires() { "$TS" status --json --peers=false 2>/dev/null | grep -q '"KeyExpiry"'; }
if yes "$LIVE" && [ -n "$TS" ]; then
  for i in 1 2 3 4 5; do "$TS" status --json 2>/dev/null | grep -q '"BackendState"' && break; sleep 1; done
  tsst="$("$TS" status --json --peers=false 2>/dev/null | tr -d '\n ')"
  TS_RUNNING=""; echo "$tsst" | grep -q '"BackendState":"Running"' && TS_RUNNING=1
  out="$WORK/ts.txt"
  if [ -n "${BS_TS_KEY:-}" ]; then # a guest: `login` adds the inviter's network beside any of their own (switch back with tailscale switch)
    if "$TS" status --json --peers=false 2>/dev/null | tr -d '\n ' | grep -q '"tag:bandsync-guest"'; then ok "Tailscale is already on the studio's network as a guest"
    # (run again, the used key always failed and said to ask for a new invitation, with the computer already on. Review, 0.58.97)
    elif ts_run "$out" login --authkey="$BS_TS_KEY" --timeout=120s; then ok "Tailscale joined the studio's network as a guest, until your invitation ends"
    else warn "Tailscale couldn't join with the invitation's key (it works once, within 2 days of the invitation): ask for a new invitation."; fi
    TS_TAGGED=1
  elif echo "$tsst" | grep -q '"Tags":\["tag:bandsync"' || { [ -n "$TS_RUNNING" ] && ! echo "$tsst" | grep -q '"KeyExpiry"'; }; then
    ok "Tailscale signed in, and stays signed in"; TS_TAGGED=1 # tagged, or its key expiry was turned off by hand
  elif [ -n "$TS_RUNNING" ]; then
    # already signed in: left exactly as it is (re-signing in with a tag not allowed yet logged a Mac out, 2026-10-28)
    ok "Tailscale is signed in (it signs out by itself every few months: see the end to keep it signed in)"
  elif ! yes "$HOSTING"; then
    # (a joiner's songs sync without Tailscale: only Play/Jam and the call need it. Beginner review, 0.58.62)
    TS_TAGGED=1; TS_LATER=1
  else
    say "Signing in to Tailscale: a browser page opens; sign in there (a free account: the one your studio's Tailscale uses, if it has one)."
    # (plainly: the studio tag needs Settings > Advanced > Set up the tags, done after this, so on a new network asking for it was always
    # refused and a second sign-in page followed. --reset clears a tag a run before left behind. Review, 0.58.97)
    if ts_run "$out" up --reset --timeout=300s; then ok "Tailscale signed in"
    else warn "Tailscale sign-in didn't finish: run  tailscale up  in a terminal and sign in on the page it shows."; fi
  fi
  # what still needs a person, waited for here: signed in at all, then key expiry off. Enter skips either.
  if [ -z "$TS_TAGGED" ] && ! ts_running; then
    say "Sign in to Tailscale now: in another terminal run  tailscale up  and sign in on the page it shows. Waiting for it; press Enter to skip and do it later."
    while ! ts_running; do read -t 3 -r </dev/tty && break; done
    ts_running && ok "Tailscale signed in"
  fi
  # (asked once: run again, it opened the page and waited for someone every time. Mac test, 0.58.69. The end list still says it)
  TS_ASKED="$STATE/StudioSync/tailscale-expiry-asked"
  if [ -z "$TS_TAGGED" ] && ts_running && ts_expires && [ ! -f "$TS_ASKED" ]; then
    mkdir -p "$(dirname "$TS_ASKED")" && touch "$TS_ASKED"
    say "One click keeps this computer signed in to Tailscale for good. In the page that opens: this computer's ... menu >"
    say "Disable key expiry. Waiting for it; press Enter to skip (it then signs out by itself every few months)."
    browse "https://login.tailscale.com/admin/machines"
    while ts_expires; do read -t 3 -r </dev/tty && break; done
    ts_expires || { ok "Tailscale stays signed in"; TS_TAGGED=1; }
  fi
fi
# Google Drive for desktop has no Linux version: the studio's backup copy is a note at the end (DRIVE_NAME still goes in band.json for the others).

fi # (BS_PLUGINS_ONLY: the apps)
# the band plug-in pack (optional): free, open-source plug-ins every bandmate can have, each from its official release
# (never bundled here), unpacked for you only into ~/.vst3 and ~/.clap (~/.lv2 when that's all a plug-in has), which REAPER scans.
# Only the ones with a Linux build of their own; what everyone has shows in REAPER's FX browser folder "StudioSync (everyone has)"
PLUG_SKIPPED=""
skip_plugin() { PLUG_SKIPPED="${PLUG_SKIPPED:+$PLUG_SKIPPED; }$1"; }
plugin_found() { find "$HOME/.vst3" "$HOME/.clap" "$HOME/.lv2" /usr/lib/vst3 /usr/local/lib/vst3 /usr/lib/clap /usr/lib/lv2 /usr/local/lib/lv2 -maxdepth 1 -name "$1" 2>/dev/null | grep -q .; }
# (looked for before its download is: every lookup is a GitHub API call, 60 an hour per network, and a band installing in one room
# ran out, so Syncthing's own download failed. Installer review, 0.58.76)
have_plugin() { plugin_found "$2" && ok "$1 is already installed"; }
plugin_pkg() { # url name pattern (`pattern`: a glob that's there once it's installed)
  if plugin_found "$3"; then ok "$2 is already installed"; return 0; fi
  [ -n "$1" ] || { warn "$2: no Linux download found, skipped"; skip_plugin "$2 (no download found)"; return 1; }
  local f="$WORK/plugin_${1##*/}" x="$WORK/plugin_x" b n=0
  say "Installing $2 ..."
  curl -fsSL "$1" -o "$f" || { warn "$2: download failed"; rm -f "$f"; return 1; }
  rm -rf "$x"; unpack "$f" "$x" || { warn "$2: couldn't unpack it"; rm -rf "$f" "$x"; return 1; }
  mkdir -p "$HOME/.vst3" "$HOME/.clap"
  while IFS= read -r b; do cp -rf "$b" "$HOME/.vst3/"; n=$((n + 1)); done < <(find "$x" -name '*.vst3' -prune)
  while IFS= read -r b; do cp -rf "$b" "$HOME/.clap/"; n=$((n + 1)); done < <(find "$x" -name '*.clap' -prune)
  if [ $n -eq 0 ]; then mkdir -p "$HOME/.lv2"; while IFS= read -r b; do cp -rf "$b" "$HOME/.lv2/"; done < <(find "$x" -name '*.lv2' -type d -prune); fi
  # what a package puts in /usr/share for the plug-in goes to your own ~/.local/share (Surge XT's patches and wavetables: it looks there)
  for b in "$x"/usr/share/*/; do
    [ -d "$b" ] || continue
    case "$(basename "$b")" in doc|applications|icons|pixmaps|man|metainfo|mime|lintian) ;; *) mkdir -p "$HOME/.local/share" && cp -rf "${b%/}" "$HOME/.local/share/";; esac
  done
  rm -rf "$f" "$x"
  plugin_found "$3" && ok "$2 installed" || warn "$2 didn't install: install it by hand"
}
fetch_tgz() { # url name dir dir-in-archive -> dir, from a GitHub source tarball (streamed: nothing big left behind)
  if [ -d "$3" ]; then ok "$2 is already there"; return 0; fi
  mkdir -p "$(dirname "$3")"
  if curl -fsSL "$1" | tar -xz -C "$(dirname "$3")" && mv "$(dirname "$3")/$4" "$3"; then return 0; fi
  rm -rf "$(dirname "$3")/${4:?}"; warn "$2 didn't download"; return 1
}
if yes "$PLUGINS"; then
  # (the Linux builds there are: some are x86_64 only, and Neural Amp Modeler has none)
  DA="$ARCH"; [ "$ARCH" = aarch64 ] && DA=arm64; [ "$ARCH" = armv7l ] && DA=armhf # (Dragonfly's and AIDA-X's names)
  ZA=""; [ "$ARCH" = x86_64 ] && ZA=x86-64; [ "$ARCH" = aarch64 ] && ZA=arm64      # (ZL's: not AVX2, which older CPUs lack)
  if [ "$ARCH" = x86_64 ]; then
    have_plugin "Surge XT" "Surge XT*" || plugin_pkg "$(gh_asset surge-synthesizer/releases-xt 'linux-x64-[0-9.]+\.deb$')" "Surge XT" "Surge XT*"
    have_plugin "Dexed" "Dexed*" || plugin_pkg "$(gh_asset asb2m10/dexed '-lnx\.zip$')" "Dexed" "Dexed*"
    have_plugin "Airwindows Consolidated" "Airwindows*" || plugin_pkg "$(gh_asset_tag baconpaul/airwin2rack DAWPlugin 'Linux\.zip$')" "Airwindows Consolidated" "Airwindows*"
    have_plugin "Chow Tape Model" "CHOW*" || plugin_pkg "$(gh_asset jatinchowdhury18/AnalogTapeModel 'Linux-x64.*\.deb$')" "Chow Tape Model" "CHOW*"
    have_plugin "BYOD" "BYOD*" || plugin_pkg "$(gh_asset Chowdhury-DSP/BYOD 'Linux-x64.*\.deb$')" "BYOD" "BYOD*"
    have_plugin "ChowMatrix" "ChowMatrix*" || plugin_pkg "$(gh_asset Chowdhury-DSP/ChowMatrix 'Linux-x64.*\.deb$')" "ChowMatrix" "ChowMatrix*"
    have_plugin "CloudReverb" "CloudReverb*" || plugin_pkg "$(gh_asset xunil-cloud/CloudReverb 'CloudReverb-v[0-9.]+-Linux-x86_64\.zip$')" "CloudReverb" "CloudReverb*" # (0.59.21)
    have_plugin "OB-Xf" "OB-Xf*" || plugin_pkg "$(gh_asset surge-synthesizer/OB-Xf 'ob-xf-Linux-v[0-9.]+\.deb$')" "OB-Xf" "OB-Xf*" # (0.59.20)
  else skip_plugin "Surge XT, Dexed, Airwindows, Chow Tape Model, BYOD, ChowMatrix, OB-Xf and CloudReverb (no $ARCH build)"; fi
  have_plugin "Dragonfly Reverb" "Dragonfly*" || plugin_pkg "$(gh_asset michaelwillis/dragonfly-reverb "linux-$DA\.tar\.xz$")" "Dragonfly Reverb" "Dragonfly*"
  if [ -n "$ZA" ]; then
    have_plugin "ZL Equalizer 2" "ZL Equalizer*" || plugin_pkg "$(gh_asset ZL-Audio/ZLEqualizer "Linux-$ZA\.zip$")" "ZL Equalizer 2" "ZL Equalizer*"
    have_plugin "ZL Compressor" "ZL Compressor*" || plugin_pkg "$(gh_asset ZL-Audio/ZLCompressor "Linux-$ZA\.zip$")" "ZL Compressor" "ZL Compressor*"
  else skip_plugin "ZL Equalizer 2 and ZL Compressor (no $ARCH build)"; fi
  if yes "$EXTRAS"; then
    skip_plugin "Neural Amp Modeler (no Linux build: AIDA-X plays amp captures instead)"
    have_plugin "AIDA-X" "AIDA-X*" || plugin_pkg "$(gh_asset AidaDSP/AIDA-X "linux-$DA\.tar\.xz$")" "AIDA-X" "AIDA-X*"
    if [ "$ARCH" = x86_64 ]; then plugin_pkg "$(gh_asset_tag TheWaveWarden/odin2 NightlyDevel '\.deb$')" "Odin 2" "Odin2*"
    else skip_plugin "Odin 2 (no $ARCH build)"; fi
    # (vocal tuning, a 303 bass, mallets and bells, Monique: 0.59.21. SnapTune has an arm64 build too; Monique's Nightly is its only release)
    if [ "$ARCH" = x86_64 ]; then
      have_plugin "SnapTune" "SnapTune*" || plugin_pkg "$(gh_asset NicoFerni/snaptune 'SnapTune-[0-9.]+-Linux\.tar\.gz$')" "SnapTune" "SnapTune*"
      have_plugin "JC303" "JC303*" || plugin_pkg "$(gh_asset midilab/jc303 'jc303-[0-9.]+-linux_x64-plugins\.zip$')" "JC303" "JC303*"
      have_plugin "RipplerX" "RipplerX*" || plugin_pkg "$(gh_asset tiagolr/ripplerx 'ripplerx-linux-v[0-9.]+\.zip$')" "RipplerX" "RipplerX*"
      have_plugin "Monique" "Monique*" || plugin_pkg "$(gh_asset_tag surge-synthesizer/monique-monosynth Nightly '-Linux\.zip$')" "Monique" "Monique*"
    elif [ "$ARCH" = aarch64 ]; then
      have_plugin "SnapTune" "SnapTune*" || plugin_pkg "$(gh_asset NicoFerni/snaptune 'SnapTune-[0-9.]+-Linux-arm64\.tar\.gz$')" "SnapTune" "SnapTune*"
      skip_plugin "JC303, RipplerX and Monique (no $ARCH build)"
    else skip_plugin "SnapTune, JC303, RipplerX and Monique (no $ARCH build)"; fi
    DOCS="$(xdg-user-dir DOCUMENTS 2>/dev/null)"; { [ -n "$DOCS" ] && [ "$DOCS" != "$HOME" ]; } || DOCS="$HOME/Documents"
    piano="$DOCS/StudioSync Instruments/Salamander Grand Piano"
    [ -d "$piano" ] || say "Downloading the Salamander Grand piano (about 715 MB) ..."
    fetch_tgz "https://codeload.github.com/sfzinstruments/SalamanderGrandPiano/tar.gz/refs/heads/master" "the Salamander Grand piano" "$piano" SalamanderGrandPiano-master &&
      ok "Salamander Grand piano in $piano"
    # a drum kit everyone has (DrumGizmo's MuldjordKit as SFZ, CC BY 4.0, ported by sfzinstruments)
    drums="$DOCS/StudioSync Instruments/MuldjordKit drums"
    [ -d "$drums" ] || say "Downloading the MuldjordKit drums (about 330 MB) ..."
    fetch_tgz "https://codeload.github.com/sfzinstruments/DrumGizmo.MuldjordKit/tar.gz/refs/heads/master" "the MuldjordKit drums" "$drums" DrumGizmo.MuldjordKit-master &&
      ok "MuldjordKit drums in $drums"
    TELL_DECENT=1; TELL_SFIZZ=1
  fi
  [ -n "$PLUG_SKIPPED" ] && warn "Not on Linux here: $PLUG_SKIPPED"
fi
if [ -n "${BS_PLUGINS_ONLY:-}" ]; then # (only the plug-ins: done here)
  [ -n "${TELL_DECENT:-}" ] && say "Decent Sampler (free, lots of free instruments) can't be installed for you: its maker asks for an email address first. decentsamples.com/product/decent-sampler-plugin"
  ok "Done: restart REAPER so it finds them."
  exit 0
fi
REAPER_BIN="$(find_reaper)" || { warn "REAPER isn't installed: get it from reaper.fm and run this again."; exit 1; }
# REAPER's resource folder, found the way REAPER finds it: a reaper.ini beside the program makes it portable (everything there),
# else ~/.config/REAPER (XDG_CONFIG_HOME, if set), or an old ~/.REAPER that already has its settings
# (a Flatpak REAPER starts through flatpak, and keeps its settings in its own folder under ~/.var/app: not the ~/.config/REAPER it
# would never read. Cross-platform review, 0.58.78)
FLATPAK_APP="$HOME/.var/app/fm.reaper.Reaper"
EXE_DIR="$(dirname "$REAPER_BIN")"
REAPER_RUN=("$REAPER_BIN")
if [ "$REAPER_BIN" = flatpak ]; then REAPER_RUN=(flatpak run fm.reaper.Reaper); RES="$FLATPAK_APP/config/REAPER"
elif [ -f "$EXE_DIR/reaper.ini" ]; then RES="$EXE_DIR"
elif [ -f "$CFG/REAPER/reaper.ini" ]; then RES="$CFG/REAPER"
elif [ -f "$HOME/.REAPER/reaper.ini" ]; then RES="$HOME/.REAPER"
else RES="$CFG/REAPER"; fi
ok "REAPER: $REAPER_BIN (settings in $RES)"

# ---------- 2. REAPER extensions: ReaPack, ReaImGui, js_ReaScriptAPI and SWS ----------
PLUG="$RES/UserPlugins"
need=""
[ -f "$PLUG/reaper_reapack-$ARCH.so" ] || need="$need reaper_reapack-$ARCH.so=https://github.com/cfillion/reapack/releases/download/$REAPACK/reaper_reapack-$ARCH.so"
[ -f "$PLUG/reaper_imgui-$ARCH.so" ] || need="$need reaper_imgui-$ARCH.so=https://github.com/cfillion/reaimgui/releases/download/v$REAIMGUI/reaper_imgui-$ARCH.so"
# js_ReaScriptAPI (drawing on the tracks, window placement, ReaNINJAM's mode) and SWS (links, a few actions), from the
# files ReaPack's ReaTeam Extensions index points at (both MIT); skipped when any copy of them is there already.
# (js_ReaScriptAPI's only Linux build is x86_64)
JS_NONE=""
if ! ls "$PLUG"/reaper_js_ReaScriptAPI* >/dev/null 2>&1; then
  if [ "$ARCH" = x86_64 ]; then need="$need reaper_js_ReaScriptAPI64.so=https://github.com/juliansader/ReaExtensions/raw/master/js_ReaScriptAPI/$JSAPI/reaper_js_ReaScriptAPI64.so"
  else JS_NONE=1; fi
fi
ls "$PLUG"/reaper_sws* >/dev/null 2>&1 || need="$need reaper_sws-$ARCH.so=https://github.com/reaper-oss/sws/releases/download/$SWS/reaper_sws-$ARCH.so"
if [ -n "$need" ]; then
  if pgrep -x reaper >/dev/null; then
    say "REAPER has to restart to load its new extensions: quit REAPER now (File > Quit, or Ctrl+Q; save if it asks). It's reopened"
    say "afterwards, with your project."
    REOPEN=true
    waited=0
    while pgrep -x reaper >/dev/null; do
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
if [ ! -f "$API/imgui.lua" ]; then # ReaImGui's version shim, which scripts load with require "imgui"
  mkdir -p "$API" && curl -fsSL "https://codeberg.org/cfillion/reaimgui/raw/v$REAIMGUI/shims/imgui.lua" -o "$API/imgui.lua" && ok "ReaImGui shim installed"
fi

# ---------- 3. Syncthing: the shared folder ----------
[ -n "$ST" ] && [ -x "$ST" ] || { warn "Syncthing wasn't found: install it from syncthing.net and run this again."; exit 1; }
# its config home: ~/.local/state/syncthing, or ~/.config/syncthing where an older Syncthing set up already (Syncthing keeps using that one)
# (the one already running: its own, wherever that is. A snap's Syncthing can't write outside ~/snap/syncthing. Installer review, 0.58.78)
SNAP_ST="$HOME/snap/syncthing/current"
if [ -n "${BS_SYNCTHING_HOME:-}" ]; then STHOME="$BS_SYNCTHING_HOME"
elif [ -n "$ST_RUN_HOME" ]; then STHOME="$ST_RUN_HOME"
elif case "$ST" in /snap/*) true;; *) false;; esac; then
  STHOME="$SNAP_ST/.local/state/syncthing"; [ -f "$SNAP_ST/.config/syncthing/config.xml" ] && [ ! -f "$STHOME/config.xml" ] && STHOME="$SNAP_ST/.config/syncthing"
elif [ -f "$CFG/syncthing/config.xml" ] && [ ! -f "$STATE/syncthing/config.xml" ]; then STHOME="$CFG/syncthing"
else STHOME="$STATE/syncthing"; fi
# StudioSync's own `syncthing cli` calls are told this folder when Syncthing wouldn't find it by itself: anywhere but the two defaults, or always
# from a Flatpak REAPER, whose sandbox moves the XDG folders (studiosync_setup.lua keeps it)
ST_HOME_TOLD=""; [ -z "${BS_SYNCTHING_HOME:-}" ] && { [ "$REAPER_BIN" = flatpak ] || { [ "$STHOME" != "$STATE/syncthing" ] && [ "$STHOME" != "$CFG/syncthing" ]; }; } && ST_HOME_TOLD="$STHOME"
stcli() { "$ST" cli --home "$STHOME" "$@" 2>&1; }
[ -f "$STHOME/config.xml" ] || { "$ST" generate --home "$STHOME" >/dev/null 2>&1 && ok "Syncthing set up for the first time"; }
if [ -n "${BS_SYNCTHING_HOME:-}" ]; then
  detach "$ST" serve --no-browser --home "$STHOME"
elif ! pgrep -x syncthing >/dev/null; then
  started=""
  # a systemd user service where there is one: it starts whenever you log in, and restarts it if it stops
  if systemctl --user show-environment >/dev/null 2>&1; then
    if ! systemctl --user cat syncthing.service >/dev/null 2>&1; then # (a distribution's own unit, if it has one, is used as it is)
      mkdir -p "$CFG/systemd/user"
      printf '%s\n' '[Unit]' 'Description=Syncthing (StudioSync'"'"'s shared folder)' 'Documentation=man:syncthing(1)' 'StartLimitIntervalSec=60' 'StartLimitBurst=4' '' \
        '[Service]' "ExecStart=\"$ST\" serve --no-browser --no-restart \"--home=$STHOME\"" 'Restart=on-failure' 'RestartSec=1' 'SuccessExitStatus=3 4' 'RestartForceExitStatus=3 4' '' \
        '[Install]' 'WantedBy=default.target' > "$CFG/systemd/user/syncthing.service"
      systemctl --user daemon-reload </dev/null
    fi
    systemctl --user enable --now syncthing.service >/dev/null 2>&1 </dev/null && { started=1; ok "Syncthing started (and starts by itself whenever you log in)"; }
  fi
  [ -n "$started" ] || { detach "$ST" serve --no-browser --home "$STHOME"; ok "Syncthing started (StudioSync's Live sync starts it from now on)"; }
fi
up=""; for i in $(seq 1 60); do stcli show system >/dev/null && { up=1; break; }; sleep 1; done
[ -n "$up" ] || { warn "Syncthing didn't answer; finish its setup by hand (see installer/SKILL.md)"; exit 1; }
# (a distro's Syncthing can be older than `device-id`: Ubuntu 24.04's 1.27 has only --device-id, and the running one's API answers either way.
# The ID came out empty there, and with it the device's name. Linux VM, 0.58.75)
MY_ID="$("$ST" device-id --home "$STHOME" 2>/dev/null | tail -1 | tr -d '[:space:]')"
is_id() { [[ "$1" =~ ^[A-Z0-9]{7}(-[A-Z0-9]{7}){7}$ ]]; }
is_id "$MY_ID" || MY_ID="$("$ST" --device-id --home "$STHOME" 2>/dev/null | tail -1 | tr -d '[:space:]')"
is_id "$MY_ID" || MY_ID="$(stcli show system 2>/dev/null | sed -n 's/.*"myID": *"\([A-Z0-9-]*\)".*/\1/p' | head -1)"
is_id "$MY_ID" || warn "couldn't read this computer's Syncthing ID (it's in Syncthing's web page: Actions > Show ID)"
# (run again by someone already in: the folder Syncthing already has for this studio, not the default. Laptop test, 0.58.69)
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
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { warn "There's no desktop here (over SSH?): REAPER can't open. Run this again in a terminal on the computer's own desktop."; exit 1; }

# ---------- 4. StudioSync scripts, inside REAPER ----------
if [ "$TAG" = main ]; then # the newest released version (what ReaPack serves), as Windows does: main's setup could be ahead of any release
  V="$(curl -fsSL "https://github.com/$REPO/raw/main/index.xml" 2>/dev/null | awk '/<reapack name="StudioSync.lua"/{f=1} f&&/<\/reapack>/{f=0} f' |
    grep -o 'version name="[0-9.]*"' | grep -o '[0-9][0-9.]*' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
  [ -n "$V" ] && TAG="v$V"
fi
ZREF="heads/$TAG"; case "$TAG" in v[0-9]*) ZREF="tags/$TAG";; esac # (a vN tag, else a branch: BS_TAG=<branch> for a test)
# (a Flatpak REAPER has a /tmp of its own and can't see this one: the setup files go in its own folder instead. Cross-platform review, 0.58.78)
SRC="$WORK/src"; [ "$REAPER_BIN" = flatpak ] && { SRC="$FLATPAK_APP/cache/studiosync_setup"; rm -rf "$SRC"; trap 'rm -rf "$WORK" "$SRC"' EXIT; }
mkdir -p "$SRC"
curl -fsSL "https://codeload.github.com/$REPO/tar.gz/refs/$ZREF" | tar -xz -C "$SRC"
HELPER="$(find "$SRC" -path '*/installer/studiosync_setup.lua' | head -1)"
[ -n "$HELPER" ] || { warn "StudioSync's setup files didn't download: check the internet connection, then run this again."; exit 1; }
HDIR="$(dirname "$HELPER")"
# The StudioSync Hop plug-in (plays a bandmate's plug-ins and live audio's Play: docs/rt/rt-hop2.md), from this StudioSync's own download
# (plugin/dist), into ~/.clap and ~/.vst3, which REAPER scans; copied again only when it changed. (rt-installer, 2026-11-22: no installer put it in)
install_hop() { # <the download's plugin/dist/<platform> folder> <CLAP folder> <VST3 folder>
  local from="$1" n=0 k dest
  [ -e "$from/StudioSync Hop.clap" ] || { warn "The StudioSync Hop plug-in isn't in this StudioSync download (plugin/dist): playing a bandmate's plug-ins needs it."; return 0; }
  for k in "clap:$2" "vst3:$3"; do
    dest="${k#*:}/StudioSync Hop.${k%%:*}"
    [ -e "$from/StudioSync Hop.${k%%:*}" ] || continue
    diff -rq "$from/StudioSync Hop.${k%%:*}" "$dest" >/dev/null 2>&1 && continue
    mkdir -p "${k#*:}" && rm -rf "$dest" && cp -R "$from/StudioSync Hop.${k%%:*}" "$dest" || { warn "StudioSync Hop couldn't be put in ${k#*:}: run this again."; return 0; }
    n=$((n + 1))
  done
  [ $n -gt 0 ] && ok "StudioSync Hop plug-in installed (restart REAPER, or rescan plug-ins, so it finds it)" || ok "StudioSync Hop plug-in is already installed"
}
case "$ARCH" in x86_64|aarch64) install_hop "$(dirname "$HDIR")/plugin/dist/linux-$ARCH" "$HOME/.clap" "$HOME/.vst3";;
  *) warn "There's no StudioSync Hop plug-in for $ARCH: everything else works; playing a bandmate's plug-ins doesn't.";; esac
# REAPER -nonewinst <file>: to the REAPER that's running, or a new one when none is. On Linux a REAPER finds the running one by a
# pipe in XDG_RUNTIME_DIR whose name comes from XDG_SESSION_ID (reaperctl.<hash>), so started from another login session (a terminal
# over SSH, or one the desktop started apart from REAPER) it found none and opened a second REAPER, and each hand-over again opened
# one more. So it's started with the running REAPER's own session, or none if it has none (REAPER 7.86, Linux VM, 0.58.77)
handoff() {
  local p sid
  p="$(pgrep -x reaper | head -1)"
  if [ -z "$p" ] || [ ! -r "/proc/$p/environ" ]; then detach "${REAPER_RUN[@]}" -nonewinst "$1"; return; fi
  sid="$(tr '\0' '\n' < "/proc/$p/environ" | sed -n 's/^XDG_SESSION_ID=//p' | head -1)"
  if [ -n "$sid" ]; then detach env XDG_SESSION_ID="$sid" "${REAPER_RUN[@]}" -nonewinst "$1"
  else detach env -u XDG_SESSION_ID "${REAPER_RUN[@]}" -nonewinst "$1"; fi
}
request() { # mode -> runs the helper in REAPER, leaves its JSON result in $HDIR/studiosync_setup_result.json
  local panel=false; [ "$1" = verify ] && panel=true
  local jsfx=false; yes "$PLUGINS" && jsfx=true
  local persona=false; yes "$REAPERSONA" && persona=true
  local js='s/\\/\\\\/g; s/"/\\"/g' # (a " or \ in a path broke the JSON)
  local bid="" bname="" inv=""; [ -n "$JOINING" ] && { bid="$FOLDER_ID"; bname="$BAND_NAME"; inv="$(printf '%s' "$HOST_ID" | LC_ALL=C tr -cd 'A-Z0-9-')"; } # (the studio's name till its band.json arrives: studiosync_setup.lua)
  printf '{"sync_root":"%s","user":"%s","mode":"%s","repo_url":"https://github.com/%s/raw/main/index.xml","open_panel":%s,"jsfx":%s,"reapersona":%s,"persona":"%s","syncthing_path":"%s","syncthing_home":"%s","band_id":"%s","band_name":"%s","host_id":"%s"}' \
    "$(printf '%s' "$ROOT" | sed -e "$js")" "$USERNAME_BS" "$1" "$REPO" "$panel" "$jsfx" "$persona" "$PERSONA" "$(printf '%s' "$ST" | sed -e "$js")" "$(printf '%s' "$ST_HOME_TOLD" | sed -e "$js")" "$bid" "$bname" "$inv" > "$HDIR/studiosync_setup.json"
  local result="$HDIR/studiosync_setup_result.json" started="$HDIR/studiosync_setup_started" was_up="" asked=1 i=0 at=""
  rm -f "$result" "$started"
  if [ -n "${REOPEN:-}" ] && ! pgrep -x reaper >/dev/null; then
    # we had REAPER quit: start it the way you do, so it reopens your project tabs as it always does (started WITH the
    # helper it came back with one tab, Mac 2026-10-28), then hand it the helper once it's up
    detach "${REAPER_RUN[@]}"
    for i in $(seq 1 60); do pgrep -x reaper >/dev/null && break; sleep 1; done
    sleep 8; i=0
  fi
  # ONE request: the helper waits inside REAPER for ReaPack itself. -nonewinst hands it to the REAPER that's running, or
  # starts REAPER with it when none is
  pgrep -x reaper >/dev/null && was_up=1
  handoff "$HELPER"
  GONE=""
  # (a REAPER's first start scans every plug-in before it runs anything: 6 minutes and more with a big collection, and the 6 minutes this
  # waited ran out first. Until the helper starts, this waits while REAPER is open, and says what's happening; once it has, the 4 minutes the
  # helper gives ReaPack and the 2.5 it gives ReaPersona. Installer review, 0.58.78)
  while [ ! -f "$result" ]; do
    i=$((i + 1))
    [ -z "$at" ] && [ -f "$started" ] && at=$i
    if [ -n "$at" ]; then [ $((i - at)) -gt 420 ] && break; elif [ "$i" -gt 2700 ]; then break; fi
    # (a REAPER that was already open sometimes never gets the hand-off: handed over again, only while the helper hasn't
    # started (its first act writes studiosync_setup_started), so it never runs twice. As install_windows.ps1, AgentBox 0.58.65)
    if [ -n "$was_up" ] && [ $asked -lt 4 ] && [ "$i" -eq $((20 * asked)) ] && [ ! -f "$started" ]; then
      say "REAPER hasn't picked up the setup step yet: handing it over again."
      handoff "$HELPER"
      asked=$((asked + 1))
    fi
    if [ "$i" -gt 15 ] && ! pgrep -x reaper >/dev/null; then GONE=1; break; fi
    [ "$i" -eq 90 ] && say "Still waiting for StudioSync to arrive through ReaPack. Look in REAPER for its first-start windows and answer them: the audio device question, then OK on ReaPack's Manage repositories, Notice and Transaction report (another window may be covering them)."
    [ -z "$at" ] && [ "$i" -gt 90 ] && [ $((i % 120)) -eq 0 ] && say "Still waiting ($((i / 60)) minutes). A first start scans every plug-in on this computer before anything else runs: 10 minutes or more with a big collection (REAPER's window names each one). Nothing is stuck while REAPER is open."
    sleep 1
  done
  [ -f "$result" ]
}
say "Setting up StudioSync inside REAPER. REAPER opens now; the first time, it scans your plug-ins (a while) and asks a few things:"
say "  the audio device: ALSA, or JACK if you use it (PipeWire's works); set it in Options > Preferences > Audio > Device before you play."
say "  ReaPack's 'Manage repositories' and 'Transaction report': OK. A new REAPER shows its evaluation reminder first: wait for it, then Still evaluating."
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
[ -n "${PLUG_SKIPPED:-}" ] && echo "  - The plug-in pack, without what has no Linux version: $PLUG_SKIPPED. A project that uses one shows it as offline here."
[ -n "${TELL_SFIZZ:-}" ] && echo "  - The piano and drums are SFZ instruments: play them with sfizz (free, Linux packages for most distributions: sfz.tools/sfizz/downloads). sforzando has no Linux version."
[ -n "${TELL_DECENT:-}" ] && echo "  - Decent Sampler (free sampler with lots of free instruments, Linux included) can't be installed for you: its maker asks for an email address first. Get it at decentsamples.com/product/decent-sampler-plugin."
# (said, not hidden: the sandbox runs StudioSync's checks where the programs outside it can't be seen. Cross-platform review, 0.58.78)
[ "$REAPER_BIN" = flatpak ] && echo "  - This REAPER is the Flatpak one: StudioSync runs inside its sandbox, which can't see programs running outside it. If StudioSync's Health page says Syncthing isn't running when it is, use REAPER from reaper.fm instead (move the Flatpak one aside and run this again: it installs that one in ~/opt/REAPER)."
[ -n "$JS_NONE" ] && echo "  - js_ReaScriptAPI has no $ARCH build: StudioSync works without it, minus drawing on the tracks and ReaNINJAM's window mode."
[ -n "$SONO_LIBS" ] && echo "  - SonoBus needs these system libraries before it runs: $SONO_LIBS(on Ubuntu or Debian: sudo apt install libjack-jackd2-0 libopus0)."
if yes "$HOSTING"; then
  echo "  - To bring in a collaborator: StudioSync panel > Invite a collaborator, and send them what it copies (their installer is"
  echo "    then already paired with you). When they've run it, the panel shows 'Let them in': press it."
  echo "    (Your Syncthing device ID, if they ask for it:  $MY_ID)"
fi # (a joiner's note is the last one: two said the same thing. AgentBox, 0.58.65)
if yes "$LIVE" && [ -z "$TS" ]; then
  echo "  - Tailscale (hearing each other live, Play/Jam) isn't installed: it needs sudo. When you want it:"
  echo "    curl -fsSL https://tailscale.com/install.sh | sh   then   sudo tailscale set --operator=\$USER   then run this installer again."
elif yes "$LIVE" && [ -z "$TS_TAGGED" ] && ts_running; then # (signed in: only the expiry is left)
  echo "  - Tailscale: at login.tailscale.com/admin/machines > this computer > ... > Disable key expiry (otherwise it signs out"
  echo "    every few months, maybe right before a session)."
elif yes "$LIVE" && [ -z "$TS_TAGGED" ]; then
  echo "  - Tailscale (skipped above): run  tailscale up  in a terminal and sign in, then at login.tailscale.com/admin/machines >"
  echo "    this computer > ... > Disable key expiry (otherwise it signs out every few months, maybe right before a session)."
fi
if yes "$LIVE" && yes "$HOSTING"; then # the first one's job, once: then bandmates' installers sign their machines in for good
  echo "  - Tailscale, once for the whole studio (if not done yet): in REAPER, StudioSync's panel > Settings > Advanced: add a"
  echo "    Tailscale access token, then press Set up the tags (it adds the policy line for you)."
  echo "    Then each collaborator's installer signs their machine in as a studio machine that never has to sign in again."
fi
if yes "$SOLO" && [ -z "$LATER" ]; then
  echo "  - Google Drive (the studio's backup copy, optional) has no Linux app, so it's skipped here; rclone (rclone.org/drive) can stand in."
  yes "$HOSTING" && echo "    At drive.google.com you can still make '$DRIVE_NAME' in My Drive and share it with each collaborator (Editor)."
fi
if yes "$HOSTING"; then
  echo "  - In REAPER, open your song's project: the StudioSync panel offers 'Share this project with the studio'."
elif [ -n "$LATER" ]; then
  echo "  - When you want a studio: REAPER's StudioSync panel has Start a studio, and Paste join code for an invitation someone sends you."
  [ -n "${TS_LATER:-}" ] && echo "  - Tailscale (for Play/Jam and hearing each other live): run  tailscale up  in a terminal when you need it."
elif [ -f "$ROOT/_band/band.json" ]; then # (run again by someone already in: nobody has to let them in. Mac test, 0.58.69)
  echo "  - You're already in $BAND_NAME: nothing more to do here. In StudioSync's panel, open Projects and double-click one."
else
  echo "  - Tell whoever invited you that you're set up: they press 'Let $USERNAME_BS in' in their panel (or add your Syncthing ID"
  echo "    by hand: $MY_ID). Then the studio's projects arrive by themselves: in StudioSync's panel, open Projects and double-click one."
  [ -n "${TS_LATER:-}" ] && echo "  - Tailscale (for Play/Jam and hearing each other live): run  tailscale up  in a terminal when you need it."
fi
