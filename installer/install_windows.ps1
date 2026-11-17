# StudioSync setup for Windows: installs and sets up everything StudioSync needs, skipping whatever is already there.
# Run it with "Install StudioSync (Windows).cmd" (double-click). Windows PowerShell 5.1 compatible.
#   REAPER, ReaPack, ReaImGui, Syncthing (the shared folder), StudioSync's scripts (through ReaPack), and optionally
#   SonoBus + Tailscale (hearing each other) and Google Drive for desktop (the group's copy): -Live no / -Solo no leave them out.
# A bandmate's panel (Invite a collaborator) hands out a one-line command that runs this with -HostId already in it.
# Each app comes from its official source (winget, or the extension's own release); each installer may show a
# Windows permission prompt. Sign-ins (Tailscale, Google Drive) stay the musician's own clicks.
# Every question can be answered up front (for an AI installer or a test run); anything not given is asked.
param(
  [string]$Tag = "main",          # which StudioSync version's helper files to use (the .cmd passes its own)
  [string]$User = "", [string]$HostId = "", [string]$Root = "",
  [string]$BandId = "", [string]$BandName = "", # the band an invitation is for: its Syncthing folder id and name
  [string]$TsKey = "",             # a guest invitation's Tailscale key: on the inviter's Tailscale network for a day, no account (lib/services.lua)
  [ValidateSet("", "yes", "no", "later")][string]$Hosting = "", [ValidateSet("", "yes", "no")][string]$Live = "", [ValidateSet("", "yes", "no")][string]$Solo = "",
  [ValidateSet("", "yes", "no")][string]$Plugins = "", # the band plug-in pack (free, open source)
  [ValidateSet("", "yes", "no")][string]$Extras = "", # the larger extras: amp modelers, Odin 2, sforzando + Salamander piano
  [string]$ReaPersona = "", # ReaPersona: REAPER set up like the DAW you came from (github.com/FmsJay/ReaPersona): a DAW (pro_tools, logic, ableton...), yes or no
  [ValidateSet("reapack", "folder", "verify")][string]$Scripts = "reapack", # folder: band-internal copy in <root>/_tools/studiosync
  [string]$SyncthingHome = "",    # testing: drive a separate Syncthing instance (--home)
  [string]$ReaperExe = "",         # testing: this REAPER, as if the installer had just put it there
  [string]$ReaperPath = "",        # a REAPER somewhere the installer doesn't look (a portable folder): its folder or reaper.exe
  [switch]$NoApps,                # testing: skip installing apps, only configure
  [switch]$NoReaper               # testing: stop before anything happens inside REAPER (the shared folder and pairing only)
)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue" # Invoke-WebRequest is 10x slower with the progress bar
$Repo = "FmsJay/studiosync"
$ReaImGuiVer = "0.10.0.5" # shortcut: pinned; ReaPack keeps it updated only if later reinstalled through ReaPack
$ReaPackVer = "v1.2.6"

# Programs started from some sandboxed apps (seen: the Claude desktop app) get a private copy of AppData, so what
# they set up (Syncthing's identity, REAPER's settings) is invisible to the same programs started normally. Seen
# 2026-10-27: Syncthing started from REAPER made a second identity that knew no other machine. The process isn't
# "packaged" (GetCurrentPackageFullName says so), so test what matters: does a write to AppData land in an app's
# sandbox? Then reopen through Explorer, which starts things outside it, with the same answers.
$probe = "bandsync_probe_" + [guid]::NewGuid().ToString("N")
Set-Content (Join-Path $env:LOCALAPPDATA $probe) "x"
$boxed = Get-ChildItem "$env:LOCALAPPDATA\Packages\*\LocalCache\Local\$probe" -ErrorAction SilentlyContinue
Remove-Item (Join-Path $env:LOCALAPPDATA $probe) -ErrorAction SilentlyContinue
if ($boxed) {
  $argv = @("-Tag", $Tag, "-Scripts", $Scripts)
  foreach ($k in "User", "HostId", "Root", "BandId", "BandName", "Hosting", "Live", "Solo", "Plugins", "Extras", "ReaPersona", "SyncthingHome", "ReaperExe", "ReaperPath", "TsKey") { $v = Get-Variable $k -ValueOnly; if ($v) { $argv += @("-$k", $v) } }
  if ($NoApps) { $argv += "-NoApps" }
  if ($NoReaper) { $argv += "-NoReaper" }
  $quoted = ($argv | ForEach-Object { if ($_ -match '^-') { $_ } else { '"' + $_ + '"' } }) -join " "
  $cmd = Join-Path $env:TEMP "bandsync_install_outside.cmd"
  # (UTF-8 with chcp 65001: written as ASCII, a user name with accents in the path, or a studio's, came out as "?" and setup never started.
  # Cross-platform review, 0.58.78)
  [IO.File]::WriteAllText($cmd, "@echo off`r`nchcp 65001 >nul`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" $quoted`r`npause`r`n", (New-Object System.Text.UTF8Encoding($false)))
  Start-Process explorer.exe -ArgumentList "`"$cmd`""
  Write-Host "This window runs inside another app's sandbox; StudioSync setup continues in a new window. If none appears, double-click 'Install StudioSync (Windows).cmd' yourself." -ForegroundColor Yellow
  exit 0
}

function Say($t) { Write-Host $t -ForegroundColor Cyan }
function Ok($t) { Write-Host "  OK  $t" -ForegroundColor Green }
function Warn($t) { Write-Host "  !!  $t" -ForegroundColor Yellow }
function Ask($q, $def) { $a = Read-Host "$q$(if ($def) { " [$def]" })"; if ($a) { $a.Trim() } else { $def } }
function YesNo($q, $def) { $a = Ask "$q (y/n)" $def; return $a -match '^[yY]' }
# Names in plain letters, as the Mac and Linux installers and StudioSync itself keep them (band.clean): accents dropped, a few letters spelled
# out. \w kept accented letters here, and StudioSync then dropped them, so "J-u-umlaut-rgen" became "Jrgen". (Cross-platform review, 0.58.78)
# (code points, not the letters: Windows PowerShell reads this file as ANSI)
$plainMap = @{ 0xF8 = 'o'; 0xD8 = 'O'; 0x142 = 'l'; 0x141 = 'L'; 0x111 = 'd'; 0x110 = 'D'; 0xDF = 'ss'; 0xE6 = 'ae'; 0xC6 = 'AE'; 0x153 = 'oe'; 0x152 = 'OE'; 0xFE = 'th'; 0xDE = 'Th' }
function Plain($s) {
  $out = foreach ($ch in "$s".Normalize([Text.NormalizationForm]::FormD).ToCharArray()) {
    if ($plainMap.ContainsKey([int]$ch)) { $plainMap[[int]$ch] } elseif ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne 'NonSpacingMark') { $ch }
  }
  (-join $out) -replace '[^A-Za-z0-9_\- ]', ''
}
$latinOnly = "Names here are in Latin letters (A to Z), digits, spaces, - and _: type it that way."

Say "StudioSync setup"
Write-Host "This installs what StudioSync needs and sets it up. It asks a few questions first (unless given up front); Windows may ask"
Write-Host "permission for each app it installs. Nothing already installed is changed."
Write-Host "A studio is the people you make music with: StudioSync shares your projects with them as you work."
Write-Host ""

# ---------- 0. questions ----------
# Pairing: with whoever in the band is already set up (any of them: every machine passes the folder on). "Host" is
# a song's, not a machine's: anyone can host a song (James, 2026-10-31: "are you the band's host" read as a role).
# Joining or starting comes from the invitation: pasted (or already in the line it gave), you join; none, you start a studio. ("Starting or
# joining?" was still a question a newcomer could get wrong: James, 0.58.64.) Asked first, so a pasted message can't answer the others.
$idPattern = '^[A-Z0-9]{7}(-[A-Z0-9]{7}){7}$'
# What was pasted: the invitation message, its studiosync-join line, its install line, or a bare device ID. -> @{ id; band; name; key } or $null.
# (as lib/services.lua parse_join reads it)
function Read-Invite($text) {
  $m = [regex]::Match($text, 'studiosync-join:([A-Z0-9-]+):([A-Za-z0-9-]+):([^\r\n]*)')
  if (-not $m.Success) { $m = [regex]::Match($text, "-HostId\s+([A-Z0-9-]+)\s+-BandId\s+([A-Za-z0-9-]+)\s+-BandName\s+'([^'\r\n]*)'") }
  if (-not $m.Success) { $m = [regex]::Match($text, "BS_HOST_ID=([A-Z0-9-]+)\s+BS_BAND_ID=([A-Za-z0-9-]+)\s+BS_BAND_NAME='([^'\r\n]*)'") }
  $k = [regex]::Match($text, 'tskey-auth-[A-Za-z0-9-]+')
  if ($m.Success -and $m.Groups[1].Value -cmatch $idPattern) { return @{ id = $m.Groups[1].Value; band = $m.Groups[2].Value; name = $m.Groups[3].Value; key = $(if ($k.Success) { $k.Value }) } }
  $bare = ($text -replace '\s', '').ToUpper()
  if ($bare -match $idPattern) { return @{ id = $bare; band = ""; name = ""; key = $null } }
  return $null
}
# No invitation and no studio of your own yet: everything installs, and the studio waits (James, 0.58.64: you might not need one yet, or get the
# invitation later). The panel then opens on Start a studio / Paste join code, so nothing here has to be decided up front.
$later = $Hosting -eq "later"
$isHost = if ($later) { $false } elseif ($Hosting) { $Hosting -eq "yes" } elseif ($HostId) { $false } else {
  # (Windows Terminal stops a pasted message with "text that contains multiple lines": said here, so nobody takes it for a problem. AgentBox, 0.58.65)
  Say "Did someone send you an invitation to their studio? Paste it here: its line starting studiosync-join is enough, or all of it (if"
  Say "Windows warns about pasting several lines, choose Paste anyway, then press Enter)."
  Say "Starting a studio of your own right now? Type s. Neither yet? Just press Enter: start one or join one later, from StudioSync's panel."
  $found = $null
  $start = $false
  while ($true) {
    $text = Read-Host "Invitation"
    # (a whole message pasted is several lines: the rest are read here too, or they'd answer the next questions)
    try { Start-Sleep -Milliseconds 400; while ([Console]::KeyAvailable) { $text += "`n" + (Read-Host) } } catch { }
    if (-not "$text".Trim()) { $later = $true; break }
    if ("$text".Trim() -match '^(s|start)$') { $start = $true; break }
    $found = Read-Invite $text
    if ($found) { break }
    Warn "That isn't an invitation. Paste it again (the line starting studiosync-join is enough), type s to start a studio, or press Enter for later."
  }
  if ($found) {
    $HostId, $BandId, $BandName = $found.id, $found.band, $found.name
    if ($found.key -and -not $TsKey) { $TsKey = $found.key }
    Ok "Joining $(if ($found.name) { $found.name } else { 'their studio' })"
  }
  $start
}
$joining = -not $isHost -and -not $later
if ($isHost -and -not $Hosting) { Say "Starting a studio: at the end, StudioSync's panel has Invite, which makes the message to send each collaborator." }
if ($later) { Say "No studio yet: when you want one, StudioSync's panel has Start a studio and Paste join code." }
$hostId = $HostId.ToUpper()
if ($joining -and $hostId -notmatch $idPattern) { Warn "The invitation's device ID isn't a whole one: ask for a new invitation."; exit 1 }
$user = Plain $User
while (-not $user) { $typed = Ask "Your name, as the studio will see it" (Plain $env:USERNAME); $user = Plain $typed; if (-not $user -and $typed) { Warn $latinOnly } }
# the band (docs/bands-design.md): each its own shared folder. An invitation names it; the first one set up names it.
$folderId = ($BandId.ToLower() -replace '[^a-z0-9-]', '')
if ($joining -and -not $folderId) { # (someone's device ID typed in by hand, no invitation)
  $folderId = ((Ask "The studio's ID, if whoever set it up gave you one (press Enter if not)" "bandsync").ToLower() -replace '[^a-z0-9-]', '')
  if (-not $folderId) { $folderId = "bandsync" }
}
# (only a StudioSync studio's folder: an invitation naming one you already have, like Syncthing's "default", would share it with whoever sent it. Security review, 0.58.76)
if ($folderId -and $folderId -notmatch '^(bandsync|bandsync-.*|studiosync-.*)$') { Warn "That studio ID ($folderId) isn't a StudioSync one: ask for a new invitation."; exit 1 }
$bandName = Plain $BandName
if ($isHost -and -not $bandName) { while (-not $bandName) { $bandName = Plain (Ask "Name your studio" "My studio"); if (-not $bandName) { Warn $latinOnly } } }
if (-not $bandName) { $bandName = "the studio" }
# (later: an empty StudioSync folder, so a studio started or joined from the panel goes beside it, in your home folder: services.new_band)
# (the old shared "bandsync" studio, set up before the rename: its folder stays)
$defRoot = if ($later) { Join-Path $env:USERPROFILE "StudioSync" } elseif ($folderId -eq "bandsync") { if (Test-Path (Join-Path $env:USERPROFILE "BandSync")) { Join-Path $env:USERPROFILE "BandSync" } else { Join-Path $env:USERPROFILE "StudioSync" } } else { Join-Path $env:USERPROFILE "StudioSync $bandName" }
# (not asked: nobody new knows what to answer, and the panel can move it later. Beginner review, 0.58.62)
$root = if ($Root) { $Root } else { $defRoot }
if (-not $later) { Say "$bandName's shared folder: $root" }
# The first one set up: an ID of the group's own. They all used to get "bandsync", so someone in two such groups had the two
# folders treated as one and their files mixed. Run again on the same folder, it keeps the ID it has; a folder from before
# groups had IDs, with no band.json yet, is "bandsync" (lib/band.lua band.info).
if (-not $folderId -and -not $later) {
  $known = Join-Path $root "_band\band.json"
  if (Test-Path $known) { try { $folderId = (Get-Content $known -Raw | ConvertFrom-Json).id } catch { } }
  elseif (Get-ChildItem $root -Force -ErrorAction SilentlyContinue | Select-Object -First 1) { $folderId = "bandsync" }
  if (-not $folderId) {
    $slug = ($bandName.ToLower() -replace '[^a-z0-9]+', '-').Trim('-'); if (-not $slug) { $slug = "group" }
    $folderId = "studiosync-$slug-" + ('{0:x4}' -f (Get-Random -Maximum 65536))
  }
}
$driveName = if ($folderId -eq "bandsync") { "StudioSync" } else { "StudioSync - $bandName" } # (the first studio's Drive folder was renamed StudioSync)
# SonoBus + Tailscale (hearing each other) and Google Drive (the group's copy) are part of StudioSync, not asked. Tailscale left in 0.50 and came back
# (James, 2026-11-04: "should not be optional"): the NINJAM route needs it, and it gets round a router that stops SonoBus.
# (James, 2026-10-31: "it feels like a core feature"); -Live no / -Solo no still leave them out.
$wantLive = $Live -ne "no"
$wantSolo = $Solo -ne "no"
$wantPlugins = if ($Plugins) { $Plugins -eq "yes" } else { Write-Host "The free plug-in pack (about 150 MB): synths, guitar and bass amps, a tuner, EQ, compressor, reverb, delay, tape, drum kits and keys"; Write-Host "(Surge XT, Dexed, Airwindows, Dragonfly, Chow, BYOD, ZL and more), so everyone in the studio hears the same sounds."; YesNo "Install it? (recommended)" "y" }
# (extras only asked of whoever starts the studio: a joiner's projects say what they use, and 1.2 GB is a lot to decide on blind. Beginner review, 0.58.62)
$wantExtras = if ($Extras) { $Extras -eq "yes" } else { -not $joining -and $wantPlugins -and (YesNo "Also the bigger extras (about 1.2 GB: a grand piano, a real drum kit, amp capture players and the Odin 2 synth)?" "n") }
# ReaPersona: which app you're used to, as one question, and it's set up as that DAW in the same run (James, 0.58.64: yes/no installed it and
# left the picking for later). The ids are ReaPersona's own (styles.json).
$personas = @(@("pro_tools", "Pro Tools"), @("logic", "Logic Pro"), @("ableton", "Ableton Live"), @("fl_studio", "FL Studio"), @("cubase", "Cubase or Nuendo"),
  @("studio_one", "Studio One"), @("bitwig", "Bitwig Studio"), @("cakewalk", "Cakewalk or Sonar"), @("reason", "Reason"), @("audacity", "Audacity"), @("audition", "Adobe Audition"))
$persona = if ($ReaPersona -eq "no" -or $ReaPersona -eq "yes") { "" } elseif ($ReaPersona) { $ReaPersona.ToLower() -replace '[^a-z0-9_]', '' } else {
  Write-Host "Used to another music app? REAPER can take on its shortcuts, mouse and look (ReaPersona, free; switch back any time):"
  for ($i = 0; $i -lt $personas.Count; $i++) { Write-Host ("  {0,2}) {1}" -f ($i + 1), $personas[$i][1]) }
  $pick = $null
  while ($null -eq $pick) {
    $n = Ask "Its number, or Enter for none" ""
    if (-not $n) { $pick = "" } elseif ($n -match '^\d+$' -and [int]$n -ge 1 -and [int]$n -le $personas.Count) { $pick = $personas[[int]$n - 1][0] } else { Warn "A number from the list, or Enter." }
  }
  $pick
}
$wantPersona = [bool]$persona -or $ReaPersona -eq "yes"
Write-Host ""

# ---------- 1. apps ----------
Say "Downloads show no progress bar here: a pause of a few minutes on a big one is normal."
$winget = Get-Command winget -ErrorAction SilentlyContinue
$script:downloads = @() # (installers fetched here: deleted at the end)
# Without winget (an older Windows 10, or App Installer removed): each app's own download, from its maker, instead. Syncthing's comes from
# its own release server and SonoBus's from sonobus.net, neither one of GitHub's 60 lookups an hour. (Installer review, 0.58.78)
function Match-Url($page, $re, $base) { $m = [regex]::Match((Invoke-WebRequest -UseBasicParsing $page).Content, $re); if ($m.Success) { $base + $m.Groups[$m.Groups.Count - 1].Value } }
$direct = @{
  "Cockos.REAPER" = { Match-Url "https://www.reaper.fm/download.php" 'files/[0-9.x]+/reaper[0-9]+_x64-install\.exe' "https://www.reaper.fm/" }
  "Syncthing.Syncthing" = { Match-Url "https://upgrades.syncthing.net/meta.json" '"url":\s*"(https://[^"]*/syncthing-windows-amd64-v[0-9.]+\.zip)"' "" }
  "Sonosaurus.SonoBus" = { Match-Url "https://www.sonobus.net/" 'releases/sonobus-[0-9.]+-win\.exe' "https://www.sonobus.net/" }
  "Tailscale.Tailscale" = { "https://pkgs.tailscale.com/stable/tailscale-setup-latest.exe" }
  "Google.GoogleDrive" = { "https://dl.google.com/drive-file-stream/GoogleDriveSetup.exe" }
  "SurgeSynth.SurgeXT" = { (Release-Asset "surge-synthesizer/releases-xt" 'win64-[0-9.]+-setup\.exe$' $null).browser_download_url }
}
# $have: where it is once installed (one place or several), looked at before winget, which is slow and only knows what it installed itself
function Install-App($id, $name, $have) {
  $ErrorActionPreference = "Continue" # winget writes to stderr (see ST below)
  if ($NoApps) { return }
  $there = { $have -and @($have | Where-Object { Test-Path $_ }).Count -gt 0 }
  if (& $there) { Ok "$name is already installed"; return }
  if (-not $winget) {
    $url = $null; if ($direct[$id]) { try { $url = & $direct[$id] } catch { } }
    if (-not $url) { Warn "$name : winget isn't available (install 'App Installer' from the Microsoft Store), install $name by hand"; return }
    $file = Join-Path $env:TEMP ([uri]::UnescapeDataString(($url -split '/')[-1]))
    Say "Downloading $name from its maker (no winget here) ..."
    try { Invoke-WebRequest -UseBasicParsing $url -OutFile $file } catch { Warn "$name didn't download: install it by hand"; return }
    $script:downloads += $file
    if ($file -match '\.zip$') { # (Syncthing: one program, put where StudioSync looks for it: lib/services.lua syncthing_path)
      $x = Join-Path $env:TEMP ("bandsync_" + [guid]::NewGuid().ToString("N"))
      Expand-Archive $file $x -Force
      $exe = Get-ChildItem $x -Recurse -Filter syncthing.exe | Select-Object -First 1
      $dest = Join-Path $env:LOCALAPPDATA "Programs\Syncthing"
      New-Item -ItemType Directory -Force $dest | Out-Null
      if ($exe) { Copy-Item $exe.FullName $dest -Force }
      Remove-Item $x -Recurse -Force -ErrorAction SilentlyContinue
    } else { Say "  $name's own installer opens: click through it (the defaults are fine)."; Start-Process $file -Wait }
    if (-not $have -or (& $there)) { Ok "$name installed" } else { Warn "$name : not found where expected afterwards ($($have -join ' or ')): install it by hand if it didn't" }
    return
  }
  & winget list --id $id --exact --accept-source-agreements *> $null
  if ($LASTEXITCODE -eq 0) { Ok "$name is already installed"; return }
  Say "Installing $name ..."
  & winget install --id $id --exact --silent --accept-package-agreements --accept-source-agreements
  if ($LASTEXITCODE -eq 0) { Ok "$name installed" } else { Warn "$name didn't install (winget exit $LASTEXITCODE): install it by hand" }
}

# (a test's -ReaperExe: only that REAPER counts. Any other is someone's real one, and this asked it to close: PC, 0.52.5)
function Get-Reaper { $all = Get-Process reaper -ErrorAction SilentlyContinue; if ($ReaperExe) { $all | Where-Object { $_.Path -eq $ReaperExe } } else { $all } }
# REAPER wherever it is: the running one, -ReaperPath (a portable folder), the usual folders, where Windows' list of installed programs says,
# what opens .rpp files, a REAPER folder at the top of a drive. (Installer review, 0.58.78)
function Find-Reaper {
  if ($ReaperExe) { return $ReaperExe }
  $p = Get-Reaper | Select-Object -First 1
  if ($p -and $p.Path) { return $p.Path }
  $c = @()
  if ($ReaperPath) { $c += $ReaperPath, (Join-Path $ReaperPath "reaper.exe") }
  $c += "$env:ProgramFiles\REAPER (x64)\reaper.exe", "$env:ProgramFiles\REAPER\reaper.exe"
  $c += Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*", "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*", "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match '^REAPER' } | ForEach-Object {
      if ($_.InstallLocation) { Join-Path $_.InstallLocation "reaper.exe" }
      if ($_.UninstallString) { Join-Path (Split-Path ($_.UninstallString -replace '"', '')) "reaper.exe" }
    }
  $type = (Get-ItemProperty "Registry::HKEY_CLASSES_ROOT\.rpp" -ErrorAction SilentlyContinue).'(default)'
  $open = if ($type) { (Get-ItemProperty "Registry::HKEY_CLASSES_ROOT\$type\shell\open\command" -ErrorAction SilentlyContinue).'(default)' }
  if ("$open" -match '"([^"]*reaper\.exe)"') { $c += $Matches[1] }
  $c += [IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady -and $_.DriveType -in 'Fixed', 'Removable' } | ForEach-Object { Join-Path $_.Name "REAPER\reaper.exe"; Join-Path $_.Name "REAPER (x64)\reaper.exe" }
  foreach ($x in $c) { if ($x -and $x -match 'reaper\.exe$' -and (Test-Path -LiteralPath $x -PathType Leaf)) { return $x } }
  return $null
}
if (-not (Find-Reaper) -and -not $ReaperPath -and -not $NoApps) {
  # (a REAPER somewhere this doesn't look is asked for, rather than a second one installed beside it)
  $ReaperPath = "$(Ask "REAPER wasn't found. If it's somewhere else (a portable copy), paste the folder it's in; or press Enter to install it" '')".Trim().Trim('"')
  if ($ReaperPath -and -not (Find-Reaper)) { Warn "No reaper.exe in $ReaperPath : installing REAPER." }
}
if (-not (Find-Reaper)) { Install-App "Cockos.REAPER" "REAPER" } else { Ok "REAPER is already installed" }
# An existing Syncthing, wherever it keeps its settings: the one running (its own copy, and its -home: SyncTrayzor starts its own copy so, as a
# scheduled task may), else an installed SyncTrayzor's copy, which uses Syncthing's own folder. That one is set up, never a second Syncthing
# with a second identity beside it. -> @{ exe; home; tray } or $null. (Installer review, 0.58.78)
function Find-Syncthing {
  $p = @(Get-CimInstance Win32_Process -Filter "Name='syncthing.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.ExecutablePath })[0]
  if ($p) {
    $m = [regex]::Match("$($p.CommandLine)", '--?(?:home|config)[= ]+(?:"([^"]+)"|(\S+))')
    $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$($p.ParentProcessId)" -ErrorAction SilentlyContinue
    return @{ exe = $p.ExecutablePath; home = $(if ($m.Success) { $m.Groups[1].Value + $m.Groups[2].Value }); tray = "$($parent.Name) $($p.ExecutablePath)" -match 'SyncTrayzor' }
  }
  $t = Join-Path $env:APPDATA "SyncTrayzor\syncthing.exe"
  if (Test-Path $t) { return @{ exe = $t; home = $null; tray = $true } }
  return $null
}
$stFound = Find-Syncthing
if ($stFound) { Ok "Syncthing is already installed$(if ($stFound.tray) { " (SyncTrayzor's)" })" }
else { Install-App "Syncthing.Syncthing" "Syncthing" (Join-Path $env:LOCALAPPDATA "Programs\Syncthing\syncthing.exe") }
if ($wantLive) { Install-App "Sonosaurus.SonoBus" "SonoBus" "$env:ProgramFiles\SonoBus\SonoBus.exe"; Install-App "Tailscale.Tailscale" "Tailscale" "$env:ProgramFiles\Tailscale\tailscale.exe" }
if ($wantSolo) { Install-App "Google.GoogleDrive" "Google Drive for desktop" "$env:ProgramFiles\Google\Drive File Stream" }

$reaper = Find-Reaper
if (-not $reaper) { Warn "REAPER wasn't found after installing: install it from reaper.fm and run this again."; exit 1 }
$exeDir = Split-Path $reaper
$res = if (Test-Path (Join-Path $exeDir "reaper.ini")) { $exeDir } else { Join-Path $env:APPDATA "REAPER" } # portable installs keep everything beside reaper.exe
Ok "REAPER: $reaper (settings in $res)"

# ---------- 1b. the band plug-in pack (optional) ----------
# Free, open-source plug-ins every bandmate can have, each from its official release (never bundled here): what
# everyone has shows in REAPER's FX browser folder "StudioSync (everyone has)". Installers that come as .exe open for
# you to click through; a .zip of VST3 bundles goes into REAPER's own plug-in folder (UserPlugins\FX, scanned by
# REAPER, no admin rights needed).
# GitHub's release lookups: each is one of the 60 an hour GitHub allows a network that isn't signed in, and a band installing in one room ran
# out. So each answer is kept for an hour (a second run asks nothing), and once the limit is reached (403, X-RateLimit-Remaining: 0) the
# release's own web page is read instead, which isn't counted; said once, with when the limit resets. (Installer review, 0.58.78)
$script:ghTold = $false
function Release-Asset($repo, $pattern, $tag) {
  $key = Join-Path $env:LOCALAPPDATA ("StudioSync\github\" + ("$repo $(if ($tag) { $tag } else { 'latest' })" -replace '[^A-Za-z0-9._-]', '_'))
  $urls = @()
  if ((Test-Path $key) -and (Get-Item $key).LastWriteTime -gt (Get-Date).AddHours(-1)) { $urls = @(Get-Content $key) }
  if (-not $urls) {
    $api = if ($tag) { "https://api.github.com/repos/$repo/releases/tags/$tag" } else { "https://api.github.com/repos/$repo/releases/latest" }
    try { $urls = @((Invoke-RestMethod $api -UseBasicParsing).assets | ForEach-Object { $_.browser_download_url }) } catch {
      $r = $_.Exception.Response
      $left = try { "$($r.Headers['X-RateLimit-Remaining'])" } catch { "" }
      if (-not $script:ghTold -and ($left -eq "0" -or (-not $left -and "$($r.StatusCode)" -match '403|429|Forbidden|TooManyRequests'))) {
        $script:ghTold = $true
        $at = try { [DateTimeOffset]::FromUnixTimeSeconds([int64]"$($r.Headers['X-RateLimit-Reset'])").LocalDateTime.ToString("HH:mm") } catch { "" }
        Warn "GitHub's limit of 60 lookups an hour from this network is used up$(if ($at) { " (until $at)" }): several computers installing at once? Reading GitHub's download pages instead."
      }
    }
    if (-not $urls) {
      try {
        $t = $tag
        if (-not $t) { # (the tag a "latest" leads to, from where GitHub's page lands)
          $w = Invoke-WebRequest -UseBasicParsing "https://github.com/$repo/releases/latest"
          $u = if ($w.BaseResponse.ResponseUri) { $w.BaseResponse.ResponseUri.AbsoluteUri } else { $w.BaseResponse.RequestMessage.RequestUri.AbsoluteUri }
          $t = ($u -split '/releases/tag/')[1]
        }
        if ($t) {
          $html = (Invoke-WebRequest -UseBasicParsing "https://github.com/$repo/releases/expanded_assets/$t").Content
          $urls = @([regex]::Matches($html, 'href="(/[^"]*/releases/download/[^"]*)"') | ForEach-Object { "https://github.com" + $_.Groups[1].Value })
        }
      } catch { }
    }
    if ($urls) { New-Item -ItemType Directory -Force (Split-Path $key) | Out-Null; Set-Content $key $urls }
  }
  # (matched on the file's name, as GitHub's own list gives it)
  foreach ($u in $urls) { $n = [uri]::UnescapeDataString(($u -split '/')[-1]); if ($n -match $pattern) { return @{ name = $n; browser_download_url = $u } } }
  return $null
}
# Every plug-in installer here that opens a wizard is an Inno Setup one (2026-11-01: Dexed, Airwindows, Chow Tape,
# BYOD, ChowMatrix, NAM, AIDA-X, Odin 2). Those run without their windows, all at the end in one go, so Windows asks
# for permission once instead of once each. Any other installer opens its own windows as before.
$script:Quiet = @()
function Is-Inno($exe) { try { (Get-Item -LiteralPath $exe).VersionInfo.Comments -match 'Inno Setup' } catch { $false } }
function Run-Installer($name, $exe, $have) {
  if (Is-Inno $exe) { $script:Quiet += @{ name = $name; exe = $exe; have = $have }; return $true }
  Say "  $name's own installer opens: click through it (the defaults are fine)."
  Start-Process $exe -Wait
  return $false
}
function Install-Quiet {
  if ($script:Quiet.Count -eq 0) { return }
  Say "Installing $($script:Quiet.Count) plug-in(s) without their setup windows: Windows asks for permission once."
  $run = ($script:Quiet | ForEach-Object { "Start-Process -Wait -FilePath '$($_.exe -replace "'", "''")' -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-'" }) -join "; "
  $asked = $true
  try { Start-Process powershell -Verb RunAs -Wait -WindowStyle Hidden -ArgumentList @("-NoProfile", "-Command", $run) } catch { $asked = $false }
  foreach ($q in $script:Quiet) {
    $there = @($q.have | Where-Object { Test-Path $_ }).Count -gt 0
    if (-not $there -and -not $asked) { # (permission declined: each one's own installer, as before)
      Say "  $($q.name)'s own installer opens: click through it (the defaults are fine)."
      Start-Process $q.exe -Wait
      $there = @($q.have | Where-Object { Test-Path $_ }).Count -gt 0
    }
    if ($there) { Ok "$($q.name) installed" } else { Warn "$($q.name) : not found where expected afterwards ($($q.have -join ' or ')); check it in REAPER's FX browser" }
  }
  $script:Quiet = @()
}
function Install-Plugin($name, $repo, $pattern, $tag, $have) {
  if ($NoApps) { return }
  # ($have: one place or several where it lands, wildcards allowed)
  $there = { @($have | Where-Object { Test-Path $_ }).Count -gt 0 }
  if (& $there) { Ok "$name is already installed"; return }
  $a = Release-Asset $repo $pattern $tag
  if (-not $a) { Warn "$name : no download found on github.com/$repo, skipped (install it by hand if you like)"; return }
  $file = Join-Path $env:TEMP $a.name
  Say "Downloading $name ($($a.name)) ..."
  try { Invoke-WebRequest $a.browser_download_url -OutFile $file -UseBasicParsing } catch { Warn "$name didn't download: $_"; return }
  $script:downloads += $file # (deleted at the end: they stayed in TEMP for good. Review, 0.58.47)
  if ($file -match '\.exe$') {
    if (Run-Installer $name $file $have) { return } # (later, with the others: Install-Quiet)
  } elseif ($file -match '\.msi$') {
    Say "  $name's installer runs (it may ask for permission)."
    Start-Process msiexec -ArgumentList "/i `"$file`" /passive" -Wait
  } else {
    $x = Join-Path $env:TEMP ("bandsync_" + [guid]::NewGuid().ToString("N"))
    Expand-Archive $file $x -Force
    $fx = Join-Path $res "UserPlugins\FX"
    New-Item -ItemType Directory -Force $fx | Out-Null
    # the bundles themselves, not the .vst3 file inside each bundle's Contents
    $vst3 = @(Get-ChildItem $x -Recurse -Filter *.vst3 | Where-Object { $_.FullName.Substring($x.Length) -notmatch '\.vst3\\.' })
    $vst3 | ForEach-Object { Copy-Item $_.FullName (Join-Path $fx $_.Name) -Recurse -Force }
    # a zip holding the plug-in's own installer instead (Neural Amp Modeler 0.7.13: "NeuralAmpModeler Installer.exe")
    $exe = Get-ChildItem $x -Recurse -Filter *.exe | Select-Object -First 1
    if ($vst3.Count -eq 0 -and $exe -and (Run-Installer $name $exe.FullName $have)) { return } # (its folder stays until then)
    Remove-Item $x -Recurse -Force -ErrorAction SilentlyContinue
  }
  if (& $there) { Ok "$name installed" } else { Warn "$name : not found where expected afterwards ($($have -join ' or ')); check it in REAPER's FX browser" }
}
if ($wantPlugins) {
  $vst3 = Join-Path $env:CommonProgramFiles "VST3"
  Install-App "SurgeSynth.SurgeXT" "Surge XT" (Join-Path $vst3 "Surge XT.vst3")
  Install-Plugin "Dexed" "asb2m10/dexed" '-win\.exe$' $null (Join-Path $vst3 "Dexed*")
  Install-Plugin "Airwindows Consolidated" "baconpaul/airwin2rack" '^(?!.*windows7).*Windows-64bit-setup\.exe$' "DAWPlugin" (Join-Path $vst3 "Airwindows*")
  Install-Plugin "Dragonfly Reverb" "michaelwillis/dragonfly-reverb" 'win64\.zip$' $null (Join-Path $res "UserPlugins\FX\Dragonfly*")
  Install-Plugin "Chow Tape Model" "jatinchowdhury18/AnalogTapeModel" 'Win-64bit.*\.exe$' $null (Join-Path $vst3 "CHOW*")
  Install-Plugin "BYOD (guitar and bass amps, tuner)" "Chowdhury-DSP/BYOD" 'Win-64bit.*\.exe$' $null (Join-Path $vst3 "BYOD*")
  Install-Plugin "ZL Equalizer 2" "ZL-Audio/ZLEqualizer" 'Windows-x86-64\.msi$' $null (Join-Path $vst3 "ZL Equalizer*")
  Install-Plugin "ZL Compressor" "ZL-Audio/ZLCompressor" 'Windows-x86-64\.msi$' $null (Join-Path $vst3 "ZL Compressor*")
  Install-Plugin "ChowMatrix (delay)" "Chowdhury-DSP/ChowMatrix" 'Win-.*\.exe$' $null (Join-Path $vst3 "ChowMatrix*")
  if ($wantExtras) {
    # NAM: v0.7.14 and later have no release files; 0.7.13 is the newest that does
    Install-Plugin "Neural Amp Modeler" "sdatkinson/NeuralAmpModelerPlugin" '-win\.zip$' "v0.7.13" @((Join-Path $res "UserPlugins\FX\NeuralAmpModeler*"), (Join-Path $env:CommonProgramFiles "VST3\NeuralAmpModeler*"))
    Install-Plugin "AIDA-X" "AidaDSP/AIDA-X" 'win64-installer\.exe$' $null (Join-Path $vst3 "AIDA-X*")
    Install-Plugin "Odin 2" "TheWaveWarden/odin2" 'WinInstaller\.exe$' "NightlyDevel" (Join-Path $vst3 "Odin2*")
    Install-App "plogue.sforzando" "sforzando (plays the piano below)"
    $piano = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "StudioSync Instruments\Salamander Grand Piano"
    if (Test-Path $piano) { Ok "Salamander Grand piano is already there" } elseif (-not $NoApps) {
      Say "Downloading the Salamander Grand piano (about 715 MB) ..."
      $zip = Join-Path $env:TEMP "salamander.zip"
      try {
        Invoke-WebRequest "https://github.com/sfzinstruments/SalamanderGrandPiano/archive/refs/heads/master.zip" -OutFile $zip -UseBasicParsing
        Expand-Archive $zip (Split-Path $piano) -Force
        Rename-Item (Join-Path (Split-Path $piano) "SalamanderGrandPiano-master") $piano -ErrorAction SilentlyContinue
        Remove-Item $zip -ErrorAction SilentlyContinue
        Ok "Salamander Grand piano in $piano (load its .sfz file in sforzando)"
      } catch { Warn "the piano didn't download: $_" }
    }
    # a drum kit everyone has, so a drum part sounds the same on every computer: DrumGizmo's MuldjordKit as SFZ, played by the same sforzando
    # (CC BY 4.0, by Lars Muldjord, ported by sfzinstruments). Windows and Mac alike, unlike DrumGizmo itself (Windows only)
    $drums = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "StudioSync Instruments\MuldjordKit drums"
    if (Test-Path $drums) { Ok "MuldjordKit drums are already there" } elseif (-not $NoApps) {
      Say "Downloading the MuldjordKit drums (about 330 MB) ..."
      $zip = Join-Path $env:TEMP "muldjordkit.zip"
      try {
        Invoke-WebRequest "https://github.com/sfzinstruments/DrumGizmo.MuldjordKit/archive/refs/heads/master.zip" -OutFile $zip -UseBasicParsing
        Expand-Archive $zip (Split-Path $drums) -Force
        Rename-Item (Join-Path (Split-Path $drums) "DrumGizmo.MuldjordKit-master") $drums -ErrorAction SilentlyContinue
        Remove-Item $zip -ErrorAction SilentlyContinue
        Ok "MuldjordKit drums in $drums (load its .sfz file in sforzando)"
      } catch { Warn "the drums didn't download: $_" }
    }
    $tellDecent = $true # (Decent Sampler: in the list of what's left, at the end)
  }
  Install-Quiet
  Ok "plug-in pack done: restart REAPER so it finds them (a re-scan in Preferences shows them, but the studio's 'everyone has' list only takes them after a restart)"
}

# ---------- 2. REAPER extensions: ReaPack and ReaImGui ----------
$userPlugins = Join-Path $res "UserPlugins"
$need = @()
if (-not (Test-Path (Join-Path $userPlugins "reaper_reapack-x64.dll"))) { $need += @{ file = "reaper_reapack-x64.dll"; url = "https://github.com/cfillion/reapack/releases/download/$ReaPackVer/reaper_reapack-x64.dll" } }
if (-not (Test-Path (Join-Path $userPlugins "reaper_imgui-x64.dll"))) { $need += @{ file = "reaper_imgui-x64.dll"; url = "https://github.com/cfillion/reaimgui/releases/download/v$ReaImGuiVer/reaper_imgui-x64.dll" } }
# js_ReaScriptAPI (drawing on the tracks, window placement, ReaNINJAM's mode) and SWS (links, a few actions), from the
# files ReaPack's ReaTeam Extensions index points at (both MIT); skipped when any copy of them is there already
if (-not (Get-ChildItem $userPlugins -Filter "reaper_js_ReaScriptAPI*" -ErrorAction SilentlyContinue)) { $need += @{ file = "reaper_js_ReaScriptAPI64.dll"; url = "https://github.com/juliansader/ReaExtensions/raw/master/js_ReaScriptAPI/v1.310/reaper_js_ReaScriptAPI64.dll" } }
if (-not (Get-ChildItem $userPlugins -Filter "reaper_sws*" -ErrorAction SilentlyContinue)) { $need += @{ file = "reaper_sws-x64.dll"; url = "https://github.com/reaper-oss/sws/releases/download/v2.14.0.7/reaper_sws-x64.dll" } }
if ($need.Count -gt 0) {
  if (Get-Reaper) {
    Say "REAPER has to restart to load its new extensions. Press Enter and REAPER is asked to close (it asks to save"
    Say "anything unsaved first; it reopens your project afterwards), or close it yourself."
    Read-Host | Out-Null
    Get-Reaper | ForEach-Object { [void]$_.CloseMainWindow() } # like clicking X: REAPER asks to save
    $script:Reopen = $true
    $waited = 0
    while (Get-Reaper) {
      Start-Sleep 1; $waited++
      if ($waited % 30 -eq 0) { # (asking again: REAPER drops a close asked for while it's busy, say scanning plug-ins for the first time)
        Get-Reaper | ForEach-Object { [void]$_.CloseMainWindow() }
        Say "Still waiting for REAPER to close (it may be scanning plug-ins, or waiting on a question: answer it if it asked one) ..."
      }
    }
  }
  New-Item -ItemType Directory -Force $userPlugins | Out-Null
  # (to a .part file first: one cut off half way stayed there, broken, and a second run said it was already installed)
  foreach ($n in $need) {
    $dest = Join-Path $userPlugins $n.file
    Invoke-WebRequest -UseBasicParsing $n.url -OutFile "$dest.part"
    if ((Get-Item "$dest.part").Length -gt 0) { Move-Item -Force "$dest.part" $dest; Ok "$($n.file) installed" }
    else { Remove-Item -Force "$dest.part"; Warn "$($n.file) didn't download" }
  }
} else { Ok "ReaPack, ReaImGui, js_ReaScriptAPI and SWS are already installed" }
$api = Join-Path $res "Scripts\ReaTeam Extensions\API"
if (-not (Test-Path (Join-Path $api "imgui.lua"))) { # ReaImGui's version shim, which scripts load with require "imgui"
  New-Item -ItemType Directory -Force $api | Out-Null
  Invoke-WebRequest -UseBasicParsing "https://codeberg.org/cfillion/reaimgui/raw/v$ReaImGuiVer/shims/imgui.lua" -OutFile (Join-Path $api "imgui.lua")
  Ok "ReaImGui shim installed"
}

# ---------- 3. Syncthing: the shared folder ----------
$st = if ($stFound) { $stFound.exe } else { Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links\syncthing.exe" } # (the one already there: Find-Syncthing)
if (-not (Test-Path $st)) { $c = Get-Command syncthing -ErrorAction SilentlyContinue; if ($c) { $st = $c.Source } }
if (-not (Test-Path $st) -and (Test-Path (Join-Path $env:LOCALAPPDATA "Programs\Syncthing\syncthing.exe"))) { $st = Join-Path $env:LOCALAPPDATA "Programs\Syncthing\syncthing.exe" } # (put there without winget)
# (a fresh Windows that can't make links gets no shortcut and no PATH entry for this window: winget's own unpacked copy, the newest. AgentBox, 0.58.60)
if (-not (Test-Path $st)) {
  $found = Get-ChildItem (Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages\Syncthing.Syncthing_*\syncthing-windows-*\syncthing.exe") -ErrorAction SilentlyContinue |
    Sort-Object { try { [version]($_.Directory.Name -replace '^.*-v', '') } catch { [version]"0.0" } } | Select-Object -Last 1
  if ($found) { $st = $found.FullName }
}
if (-not (Test-Path $st)) { Warn "Syncthing wasn't found: install it from syncthing.net and run this again."; exit 1 }
# (the running one's own settings folder when it was started with one, a portable SyncTrayzor's say: told to REAPER too, studiosync_setup.lua)
$stHome = if ($SyncthingHome) { $SyncthingHome } elseif ($stFound -and $stFound.home) { $stFound.home } else { "" }
$stHomeTold = if (-not $SyncthingHome) { $stHome } else { "" }
$homeArg = @(); if ($stHome) { $homeArg = @("--home", $stHome) }
# Windows PowerShell 5.1 turns a native program's stderr into errors, and with "Stop" above an error ends the whole
# installer (seen: Syncthing's "not up yet" while waiting for it killed the run). These calls expect stderr.
function ST { $ErrorActionPreference = "Continue"; & $st @args @homeArg 2>&1 }
function STcli { $ErrorActionPreference = "Continue"; & $st cli @homeArg @args 2>&1 }

$cfgDir = if ($stHome) { $stHome } else { Join-Path $env:LOCALAPPDATA "Syncthing" }
if (-not (Test-Path (Join-Path $cfgDir "config.xml"))) { ST generate | Out-Null; Ok "Syncthing set up for the first time" }
$running = if ($SyncthingHome) { $false } else { [bool](Get-Process syncthing -ErrorAction SilentlyContinue) }
if (-not $running) {
  $sargs = @("serve", "--no-browser"); if ($stHome) { $sargs += @("--home", "`"$stHome`"") } # (Start-Process doesn't quote a path with spaces)
  Start-Process $st -ArgumentList $sargs -WindowStyle Hidden
  Ok "Syncthing started (StudioSync's Live sync starts it from now on)"
  # (its first start asks Windows Firewall; declined, everything still syncs but only through Syncthing's slower relays. AgentBox test, 0.58.61)
  Say "Windows Firewall may ask about Syncthing: press Allow (it says Allow access on older Windows; private networks are enough). Without it, changes still sync, only slower."
}
$up = $false
$tray = $running -and $stFound -and $stFound.tray # (SyncTrayzor's: refused at once, or not at all)
for ($i = 0; $i -lt $(if ($tray) { 5 } else { 60 }) -and -not $up; $i++) { $null = STcli show system; $up = $LASTEXITCODE -eq 0; if (-not $up) { Start-Sleep 1 } }
if (-not $up -and $tray) {
  # (SyncTrayzor hands its Syncthing a new API key at every start, through the environment, where nothing else can read it. Installer review, 0.58.78)
  Warn "Syncthing here is run by SyncTrayzor, which gives it a new secret key every time it starts, so StudioSync can't talk to it. Quit SyncTrayzor (its tray icon > Exit) and untick its start with Windows (its Settings), then run this again: StudioSync then runs the same Syncthing itself, with the same folders and identity."
  exit 1
}
if (-not $up) { Warn "Syncthing didn't answer; finish its setup by hand (see installer/SKILL.md)"; exit 1 }
if ($stFound -and $stFound.tray) { $script:trayNote = $true }
# (an older Syncthing has no device-id: the running one's API answers either way. As install_linux.sh, 0.58.78)
$myId = "$(ST device-id | Select-Object -Last 1)".Trim()
if ($myId -notmatch $idPattern) { $myId = [regex]::Match("$(STcli show system | Out-String)", '"myID":\s*"([A-Z0-9-]+)"').Groups[1].Value }
# (run again by someone already in: the folder Syncthing already has for this studio, not the default. Laptop test, 0.58.69: an invitation run
# again moved a member onto a new, empty folder)
if (-not $Root -and $folderId) {
  $had = "$(STcli config folders $folderId path get | Select-Object -First 1)".Trim()
  if ($LASTEXITCODE -eq 0 -and $had -and (Test-Path $had) -and $had -ne $root) { $root = $had; Say "$bandName's shared folder is already here: $root" }
}

$root = $root.TrimEnd('\', '/')
New-Item -ItemType Directory -Force $root | Out-Null
$bj = Join-Path $root "_band\band.json"
if ($isHost -and -not (Test-Path $bj)) { # (who this folder is: lib/band.lua band.info; names are plain)
  New-Item -ItemType Directory -Force (Join-Path $root "_band") | Out-Null
  [IO.File]::WriteAllText($bj, (@{ name = $bandName; id = $folderId; drive = $driveName; owner = $user } | ConvertTo-Json -Compress))
}
# per-song sync (lib/songsync.lua writes the same block): a new bandmate gets every song's listing, and a song in
# full once they open it, so the first sync isn't the whole library. The first one set up keeps everything.
$ign = Join-Path $root ".stignore"
if ($joining -and -not ((Test-Path $ign) -and (Select-String -Path $ign -Pattern '^// (StudioSync|BandSync) end$' -Quiet))) {
  [IO.File]::AppendAllText($ign, ((@('// StudioSync: what this computer downloads (written by StudioSync, up to the line below)', '!/_*', '!/plugins', '!/drummaps', '!/*/session.json', '!/*/folder.json', '!/*/live.json', '!/*/invites', '!/*/inbox', '!/*/rooms/*/room.json', '!/*/rooms/*/summary', '!/*/rooms/*/status', '(?d)/*/*', '// StudioSync end') -join "`n") + "`n")) # (no BOM: PowerShell 5.1's -Encoding UTF8 writes one, and the block's first line then reads as something else)
  Ok "this computer gets each song in full once it's opened (the rest: their listing)"
}
$folders = @(STcli config folders list)
if (-not ($folders | Where-Object { $_ })) { STcli config defaults folder path set (Split-Path $root) | Out-Null } # fresh setup only
$label = "StudioSync $bandName"
if ($later) { } # (no studio folder yet: the panel makes it when you start or join one)
elseif ($folders -notcontains $folderId) {
  STcli config folders add --id $folderId --label $label --path $root | Out-Null
  Ok "$bandName's shared folder -> $root"
} else { Ok "$bandName's shared folder is already set up" }
if (-not $later) {
  STcli config folders $folderId order set smallestFirst | Out-Null
  STcli config folders $folderId fswatcher-delays set 1 | Out-Null  # the default 10 s delay added 10 s to every take
}
STcli config devices $myId name set $user | Out-Null
if ($joining) {
  $devices = STcli config devices list
  if ($devices -notcontains $hostId) {
    STcli config devices add --device-id $hostId --name "Collaborator" --introducer | Out-Null
  }
  $shared = STcli config folders $folderId devices list
  if ($shared -notcontains $hostId) { STcli config folders $folderId devices add --device-id $hostId | Out-Null }
  Ok "paired with your collaborator"
}

# A guest's Tailscale sign-in, before REAPER (as the Mac installer does it): it needs nothing from REAPER, and a REAPER step that doesn't finish
# stops the run before section 5, so the invitation's key went unused and the guest never reached anyone (Windows Sandbox run, 2026-11-10).
if ($wantLive -and $TsKey -and (Test-Path "$env:ProgramFiles\Tailscale\tailscale.exe")) {
  $ErrorActionPreference = "Continue"; & "$env:ProgramFiles\Tailscale\tailscale.exe" login "--authkey=$TsKey" --timeout=120s 2>$null | Out-Null; $code = $LASTEXITCODE; $ErrorActionPreference = "Stop"
  if ($code -eq 0) { Ok "Tailscale joined the studio's network as a guest, until your invitation ends" } else { Warn "Tailscale couldn't join with the invitation's key (it works once, within 2 days of the invitation): ask for a new invitation." }
}

# ---------- 4. StudioSync scripts, inside REAPER ----------
$work = Join-Path $env:TEMP "studiosync_setup"
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $work | Out-Null
if ($Tag -eq "main") { # the newest released version (what ReaPack serves), not whatever is on main right now
  try {
    $idx = (Invoke-WebRequest -UseBasicParsing "https://github.com/$Repo/raw/main/index.xml").Content
    # (StudioSync's own versions only: the menus extension's 1.0.x made this v1.0.1, a tag that doesn't exist. Installer review, 0.58.76)
    $own = [regex]::Match($idx, '(?s)<reapack name="StudioSync\.lua".*?</reapack>').Value
    $vers = [regex]::Matches($own, 'version name="([0-9.]+)"') | ForEach-Object { $_.Groups[1].Value }
    if ($vers) { $Tag = "v" + ($vers | Sort-Object { [version]$_ } | Select-Object -Last 1) }
  } catch { }
}
$zipRef = if ($Tag -eq "main") { "heads/main" } else { "tags/$Tag" }
try { Invoke-WebRequest -UseBasicParsing "https://codeload.github.com/$Repo/zip/refs/$zipRef" -OutFile (Join-Path $work "bandsync.zip") }
catch { Warn "StudioSync's scripts didn't download ($($_.Exception.Message)). Check the internet connection, then run this again."; exit 1 }
Expand-Archive (Join-Path $work "bandsync.zip") $work
$src = Get-ChildItem $work -Directory | Select-Object -First 1
$helper = Join-Path $src.FullName "installer\studiosync_setup.lua"
$utf8 = New-Object System.Text.UTF8Encoding($false) # no BOM: the Lua JSON reader wants plain UTF-8
function Request($mode) {
  # (syncthing_*: which Syncthing this set up; band_*: the invitation's studio by name till its band.json arrives. studiosync_setup.lua, 0.58.78)
  $req = @{ sync_root = ($root -replace '\\', '/'); user = $user; mode = $mode; repo_url = "https://github.com/$Repo/raw/main/index.xml"; open_panel = ($mode -eq "verify"); jsfx = [bool]$wantPlugins; reapersona = [bool]$wantPersona; persona = $persona
    syncthing_path = ($st -replace '\\', '/'); syncthing_home = ($stHomeTold -replace '\\', '/'); band_id = $(if ($joining) { $folderId } else { "" }); band_name = $(if ($joining) { $bandName } else { "" }) }
  if ($joining) { $req.host_id = $hostId } # (who invited this computer: lib/trust.lua. Security review, 0.58.78)
  $req = $req | ConvertTo-Json
  [IO.File]::WriteAllText((Join-Path (Split-Path $helper) "studiosync_setup.json"), $req, $utf8)
  $result = Join-Path (Split-Path $helper) "studiosync_setup_result.json"
  Remove-Item $result -ErrorAction SilentlyContinue
  if ($script:Reopen -and -not (Get-Reaper)) {
    # we closed REAPER: start it the way you do, so it reopens your projects as it always does (started WITH the
    # helper it came back with an empty project), then hand it the helper once it's up
    Start-Process $reaper
    for ($i = 0; $i -lt 60 -and -not (Get-Reaper | Where-Object { $_.MainWindowHandle -ne 0 }); $i++) { Start-Sleep 1 }
    Start-Sleep 5
  }
  # ONE request: the helper waits inside REAPER for ReaPack itself (asking again while ReaPack's report window was up
  # crashed REAPER on macOS, 2026-10-28)
  # (@(...) around it: an `if` hands back a one-item list as a plain string, and + then glued the path onto it: REAPER got
  # `-nonewinst"C:\...lua"`, showed its Usage box and never ran the helper. Windows Sandbox run, 2026-11-10)
  $once = @(if ($ReaperExe) { "-newinst", "-cfgfile", "`"$res\reaper.ini`"" } else { "-nonewinst" })
  $started = Join-Path (Split-Path $helper) "studiosync_setup_started" # (the helper's first act: it has the request)
  Remove-Item $started -ErrorAction SilentlyContinue
  $wasUp = -not $ReaperExe -and [bool](Get-Reaper | Where-Object { $_.MainWindowHandle -ne 0 })
  Start-Process $reaper -ArgumentList ($once + "`"$helper`"")
  $script:Gone = $false
  $asked = 1
  # (a REAPER's first start scans every plug-in and asks its questions before it runs anything: the 6 minutes this waited ran out behind them,
  # though setup then finished by itself. Windows Sandbox run, 0.58.78. Until the helper starts, this waits while REAPER is open, and says what's
  # happening; once it has, the 4 minutes the helper gives ReaPack and the 2.5 it gives ReaPersona)
  $at = $null
  for ($i = 0; -not (Test-Path $result); $i++) {
    Start-Sleep 1
    if ($null -eq $at -and (Test-Path $started)) { $at = $i }
    if ($null -ne $at) { if ($i - $at -gt 420) { break } } elseif ($i -gt 2700) { break }
    if ($null -eq $at -and $i -gt 90 -and $i % 120 -eq 0) { Say "Still waiting ($([int]($i / 60)) minutes). A first start scans every plug-in on this PC before anything else runs: 10 minutes or more with a big collection (REAPER's window names each one), and its questions may be hidden behind other windows. Nothing is stuck while REAPER is open." }
    # (a REAPER that was already open sometimes never gets the hand-off: nothing runs and this waited out its 6 minutes, though handing it
    # over again ran at once. AgentBox, 0.58.65. Again only while the helper hasn't started, so it never runs twice; never to a REAPER
    # still starting, which runs it once its first-start questions are answered)
    if ($wasUp -and $asked -lt 4 -and $i -eq 20 * $asked -and -not (Test-Path $started)) {
      Say "REAPER hasn't picked up the setup step yet: handing it over again."
      Start-Process $reaper -ArgumentList ($once + "`"$helper`"")
      $asked++
    }
    if ($i -gt 15 -and -not (Get-Reaper)) { $script:Gone = $true; break }
    # (on a first start REAPER asks about the audio device and ReaPack shows Manage repositories: until they're answered nothing runs, and Tailscale's
    # welcome window can sit on top of them. Windows Sandbox run, 2026-11-10: the setup waited out its 6 minutes behind both)
    if ($i -eq 90) { Say "Still waiting for StudioSync to arrive through ReaPack. Look in REAPER for its first-start windows and answer them: 'select your audio device now?' (No is fine: Preferences > Audio later), then OK on ReaPack's Manage repositories, Notice and Transaction report. Tailscale's welcome window or a firewall question may be covering them: close or answer it." }
  }
  if (-not (Test-Path $result)) { return $null }
  Start-Sleep -Milliseconds 300
  return Get-Content $result -Raw | ConvertFrom-Json
}
if ($NoReaper) { Ok "stopping before REAPER, as asked. This computer's Syncthing ID: $myId"; exit 0 }
Say "Setting up StudioSync inside REAPER. REAPER opens now; the first time, it scans your plug-ins and asks a few things, which need answering:"
Say "  'Select your audio device now?': No is fine for now (pick your audio interface in Preferences > Audio before you play). ReaPack's 'Manage repositories' and 'Transaction report': OK."
Say "  If Tailscale's welcome window covers them, close it. This window carries on by itself once StudioSync has arrived."
$r = Request $Scripts
$pending = $false
if (-not $r) {
  if ($script:Gone) { Warn "REAPER closed unexpectedly during setup. Open REAPER (and your project: File > Recent projects), then run this again."; exit 1 }
  # (REAPER still on its own first-start windows, often behind another one, or ReaPack still bringing StudioSync: the setup step carries on by
  # itself once they're answered, so its files stay and the rest of this runs. "Didn't run the setup step ... run this again" was wrong:
  # Windows Sandbox run, 0.58.78)
  $pending = $true
  if (Test-Path (Join-Path (Split-Path $helper) "studiosync_setup_started")) { Warn "StudioSync's setup step is still running inside REAPER (ReaPack is taking its time): it finishes by itself, and StudioSync's panel opens when it's done." }
  else { Warn "REAPER hasn't got to StudioSync's setup step yet: it's still on its first-start windows (the audio device, ReaPack's Manage repositories, Notice and Transaction report), which Tailscale's welcome window or a firewall question may be hiding. Answer them: setup then carries on by itself, and StudioSync's panel opens when it's done." }
  Warn "Run this again only if the panel never appears."
}
foreach ($s in $r.steps) { if ($s.ok) { Ok "$($s.name): $($s.detail)" } else { Warn "$($s.name): $($s.detail)" } }
$count = [int]$r.registered_actions
if ($pending) { } elseif ($count -ge 5) { Ok "StudioSync $($r.version) installed: $count actions (the StudioSync panel opens in REAPER)" } else { Warn "StudioSync's scripts haven't arrived yet: in REAPER, Extensions > ReaPack > Synchronize packages" }

# ---------- 5. what's left for a human (only what isn't done yet) ----------
$left = @()
if ($r.persona_note) { $left += $r.persona_note } # (ReaPersona set up as your DAW: what it did, and the one step left without Python)
if ($tellDecent) { $left += "Decent Sampler (free sampler with lots of free instruments) can't be installed for you: its maker asks for an email address first. Get it at decentsamples.com/product/decent-sampler-plugin." }
$peers = @()
try {
  $x = [xml](Get-Content (Join-Path $cfgDir "config.xml"))
  $c = Invoke-RestMethod -TimeoutSec 5 -Uri ("http://" + $x.configuration.gui.address + "/rest/system/connections") -Headers @{ "X-API-Key" = $x.configuration.gui.apikey }
  $peers = @($c.connections.PSObject.Properties | Where-Object { $_.Value.connected } | ForEach-Object { $_.Name })
} catch { }
# Waits for what needs a person (James, 2026-10-31: "the installer should wait for you to sign in"), instead of
# listing it at the end: true once $test passes, false if they pressed a key to skip.
function Wait-Until($test) {
  while (-not (& $test)) {
    for ($i = 0; $i -lt 30; $i++) {
      if ([Console]::KeyAvailable) { $null = [Console]::ReadKey($true); return [bool](& $test) }
      Start-Sleep -Milliseconds 100
    }
  }
  return $true
}
if ($isHost) {
  $left += "To bring in a collaborator: StudioSync panel > Invite a collaborator, and send them what it copies (their installer is then already paired with you). When they've run it, the panel shows 'Let them in': press it."
  $left += "(Your Syncthing device ID, if they ask for it:  $myId)"
} # (a joiner's note is the last one: two said the same thing. AgentBox, 0.58.65)
if ($wantLive) {
  # Any computer may end up running the NINJAM server. Windows only asks about it the first time it runs, mid-session, on that computer's screen, and until it's
  # answered nobody can connect. Asked now instead, for Tailscale addresses only (the server's own rule, lib/ninjam/bandsync.cfg). James's call, 2026-11-05.
  $oldHome = Join-Path $res "BandSync" # (as lib/band.lua's band.home: the old folder only if there's something in it)
  $srvHome = if (Test-Path "$oldHome\*") { $oldHome } else { Join-Path $res "StudioSync" }
  $srv = Join-Path $srvHome "ninjam\ninjamsrv.exe"
  $already = @(Get-NetFirewallRule -DisplayName 'StudioSync NINJAM server' -ErrorAction SilentlyContinue | Get-NetFirewallApplicationFilter | Where-Object { $_.Program -eq $srv }).Count -gt 0
  if ($already) { Ok "The NINJAM server can already accept connections over Tailscale" } else {
    $rule = "New-NetFirewallRule -DisplayName 'StudioSync NINJAM server' -Direction Inbound -Action Allow -Program '$($srv -replace "'", "''")' -RemoteAddress 100.64.0.0/10 -Profile Any -ErrorAction Stop"
    Say "Letting StudioSync's NINJAM server accept connections over Tailscale: Windows asks for permission once."
    try {
      $done = Start-Process powershell -Verb RunAs -Wait -PassThru -WindowStyle Hidden -ArgumentList @("-NoProfile", "-Command", $rule)
      if ($done.ExitCode -eq 0) { Ok "The NINJAM server can accept connections over Tailscale" } else { Warn "Windows wouldn't add that: if this computer ever runs the NINJAM server, Windows asks then. Allow it." }
    } catch { Warn "Skipped: if this computer ever runs the NINJAM server, Windows asks then. Allow it." }
  }
  $ts = "$env:ProgramFiles\Tailscale\tailscale.exe"
  # sign in as a tagged group machine: a tagged machine's key never expires, so nobody has to sign in again before a
  # session (untagged ones sign out every 180 days). Needs the host's one-time tagOwners line (below).
  $tsSt = $null
  $tagged = $false
  if ((Test-Path $ts) -and $TsKey) { # a guest: `login` adds the inviter's network beside any of their own (switch back from Tailscale's menu). Done before REAPER, above.
    $tagged = $true
  } elseif (Test-Path $ts) {
    try { $ErrorActionPreference = "Continue"; $tsSt = & $ts status --json 2>$null | ConvertFrom-Json } catch { } finally { $ErrorActionPreference = "Stop" }
    # tagged, or its key expiry was turned off by hand (then it has no KeyExpiry)
    $tagged = $tsSt -and (@($tsSt.Self.Tags) -contains "tag:bandsync" -or ($tsSt.BackendState -eq "Running" -and -not $tsSt.Self.KeyExpiry))
    if ($tagged) { Ok "Tailscale signed in, and stays signed in" }
    elseif ($tsSt -and $tsSt.BackendState -eq "Running") {
      # already signed in: left exactly as it is. Re-signing in with the tag logged a Mac OUT when the tag wasn't
      # allowed yet, and the refused tag stuck in its settings so signing in again kept failing (2026-10-28)
      Ok "Tailscale is signed in (it signs out by itself every few months: see below to keep it signed in)"
    } elseif (-not $isHost) {
      # (a joiner waited up to five minutes on a sign-in page before their first song: syncing needs no Tailscale, only Play/Jam and the call do. Beginner review, 0.58.62)
      $left += "Tailscale (for Play/Jam and hearing each other live): sign in from its taskbar icon when you need it. StudioSync's Health page shows whether it's on."
      $tagged = $true
    } else {
      function Ts-Up($argv) { # runs tailscale up, opens its sign-in page; returns the exit code
        $out = Join-Path $env:TEMP "bandsync_ts_up.txt"
        Set-Content $out ""
        $p = Start-Process -FilePath $ts -ArgumentList (@("up") + $argv) -RedirectStandardError $out -NoNewWindow -PassThru
        $null = $p.Handle # (so ExitCode is readable afterwards)
        $url = $null
        for ($i = 0; $i -lt 30 -and -not $url -and -not $p.HasExited; $i++) {
          Start-Sleep 1
          $m = Select-String -Path $out -Pattern 'https://login\.tailscale\.com/\S+' | Select-Object -First 1
          if ($m) { $url = $m.Matches[0].Value }
        }
        if ($url) { Start-Process $url }
        $p.WaitForExit()
        return $p.ExitCode
      }
      Say "Signing in to Tailscale: a browser page opens; sign in there (a free account: the one your studio's Tailscale uses, if it has one)."
      if ((Ts-Up @("--advertise-tags=tag:bandsync", "--timeout=300s")) -eq 0) { Ok "Tailscale signed in as a studio machine (it stays signed in)"; $tagged = $true }
      # the refused tag stays in Tailscale's settings and every later sign-in fails on it: clear it, then sign in plainly
      elseif ((Ts-Up @("--reset", "--advertise-tags=", "--timeout=120s")) -eq 0) { Ok "Tailscale signed in (without the studio tag: it signs out by itself every few months; see below)" }
      else { Warn "Tailscale sign-in didn't finish: open Tailscale from the Start menu (or its taskbar icon) and sign in." }
    }
  }
  if (Test-Path $ts) {
    $tsNow = { try { $ErrorActionPreference = "Continue"; & $ts status --json 2>$null | ConvertFrom-Json } catch { $null } finally { $ErrorActionPreference = "Stop" } }
    if (-not $tagged -and -not ((& $tsNow).BackendState -eq "Running")) {
      Say "Sign in to Tailscale now (its taskbar icon > Log in). Waiting for it; press any key to skip and do it later."
      if (Wait-Until { (& $tsNow).BackendState -eq "Running" }) { Ok "Tailscale signed in" }
    }
    # (asked once: run again, it opened the page and waited for someone every time. Mac test, 0.58.69. The end list still says it)
    $tsAsked = Join-Path $env:LOCALAPPDATA "StudioSync\tailscale-expiry-asked"
    if (-not $tagged -and (& $tsNow).BackendState -eq "Running" -and (& $tsNow).Self.KeyExpiry -and -not (Test-Path $tsAsked)) {
      New-Item -ItemType File -Force $tsAsked | Out-Null
      Say "One click keeps this PC signed in to Tailscale for good. In the page that opens: this PC's ... menu >"
      Say "Disable key expiry. Waiting for it; press any key to skip (it then signs out by itself every few months)."
      Start-Process "https://login.tailscale.com/admin/machines"
      if (Wait-Until { -not (& $tsNow).Self.KeyExpiry }) { Ok "Tailscale stays signed in"; $tagged = $true }
    }
  }
  if (-not $tagged -and (Test-Path $ts) -and (& $tsNow).BackendState -eq "Running") { # (signed in: only the expiry is left)
    $left += "Tailscale: at login.tailscale.com/admin/machines > this PC > ... > Disable key expiry (otherwise it signs out every few months, maybe right before a session)."
  } elseif (-not $tagged) {
    $left += "Tailscale (skipped above): sign in from its taskbar icon, then at login.tailscale.com/admin/machines > this PC > ... > Disable key expiry (otherwise it signs out every few months, maybe right before a session)."
  }
  if ($isHost) { # the host's job, once: then bandmates' installers sign their machines in for good
    $left += "Tailscale, once for the whole studio (if not done yet): in REAPER, StudioSync's panel > Settings > Advanced: add a Tailscale access token, then press Set up the tags (it adds the policy line for you)."
    $left += "  Then each collaborator's installer signs their machine in as a studio machine that never has to sign in again."
  }
}
# Google Drive: signed in, and the band's StudioSync folder in My Drive (the first one makes it; everyone else adds the
# shared one as a shortcut: Drive has no way to do that for you, so its page opens and this waits). A key skips.
if ($wantSolo) {
  # (one drive letter per Google account signed in: the one that has StudioSync is the band's, as StudioSync itself looks)
  $myDrive = {
    $all = @(foreach ($l in [char[]](67..90)) { $d = [string]$l + ":\My Drive"; if (Test-Path $d) { $d } })
    $band = @($all | Where-Object { Test-Path "$_\$driveName" })
    if ($band) { $band[0] } elseif ($all) { $all[0] } else { $null }
  }
  $driveOk = $false
  if ($later) {
    $driveOk = $true # (no studio yet, so no studio folder to make or add: the panel asks when you start one)
  }
  elseif (-not $isHost -and -not ((& $myDrive) -and (Test-Path "$(& $myDrive)\$driveName"))) {
    # (as Tailscale above: a joiner's songs arrive without it, and the folder usually isn't shared with them yet. Beginner review, 0.58.62)
    $driveOk = $true
    $left += "Google Drive (the studio's backup copy, optional): once it's shared with you, at drive.google.com: Shared with me > right-click '$driveName' > Organize > Add shortcut > My Drive."
  }
  elseif (-not (& $myDrive)) {
    Say "Sign in to Google Drive (its window, or its taskbar icon), with the Google account the studio's Drive folder is shared with (yours, or the studio's own account if you have one). Waiting for it; press any key to skip."
    $null = Wait-Until { & $myDrive }
  }
  $md = & $myDrive
  if ($driveOk) { }
  elseif ($md -and (Test-Path "$md\$driveName")) { Ok "Google Drive: the studio's '$driveName' folder is there"; $driveOk = $true }
  elseif ($md -and $isHost) { New-Item -ItemType Directory "$md\$driveName" | Out-Null; Ok "Google Drive: made '$driveName' in your My Drive"; $driveOk = $true }
  elseif ($md) {
    Say "Add the studio's Drive folder: in the page that opens, right-click '$driveName' > Organize > Add shortcut > My Drive."
    Say "(If it isn't there yet, whoever set up first shares it with you.) Waiting; press any key to skip."
    Start-Process "https://drive.google.com/drive/shared-with-me"
    if (Wait-Until { Test-Path "$md\$driveName" }) { Ok "Google Drive: the studio's '$driveName' folder is there"; $driveOk = $true }
  }
  if ($isHost -and $driveOk) { $left += "Google Drive: share the '$driveName' folder in your My Drive with each collaborator (Editor), at drive.google.com." }
  elseif (-not $driveOk) { $left += "Google Drive (skipped above): sign in, then at drive.google.com: Shared with me > right-click '$driveName' > Organize > Add shortcut > My Drive." }
}
if ($isHost) { $left += "In REAPER, open your song's project: the StudioSync panel offers 'Share this project with the studio'." }
elseif ($later) { $left += "When you want a studio: REAPER's StudioSync panel has Start a studio, and Paste join code for an invitation someone sends you." }
elseif (Test-Path (Join-Path $root "_band\band.json")) { $left += "You're already in ${bandName}: nothing more to do here. In REAPER's StudioSync panel, open Projects and double-click one." } # (run again by someone already in. Mac test, 0.58.69)
elseif ($peers -contains $hostId) { $left += "You're connected to whoever invited you: once they press 'Let you in' in their panel, the studio's projects arrive by themselves: in REAPER's StudioSync panel, open Projects and double-click one." }
else { $left += "Tell whoever invited you that you're set up: they press 'Let $user in' in their panel (or add your Syncthing ID by hand: $myId). Then the studio's projects arrive by themselves: in REAPER's StudioSync panel, open Projects and double-click one." }
if ($script:trayNote) { $left += "SyncTrayzor is installed: if it starts with Windows, the Syncthing it runs has a secret key StudioSync can't read. In SyncTrayzor's Settings, untick its start with Windows: StudioSync starts the same Syncthing itself." }
foreach ($d in $script:downloads) { Remove-Item -Force $d -ErrorAction SilentlyContinue }
if (-not $pending) { Remove-Item -Recurse -Force (Join-Path $env:TEMP "studiosync_setup") -ErrorAction SilentlyContinue } # (still waiting in REAPER: it needs its files)
Write-Host ""
Say "Done. What's left (these need you):"
foreach ($l in $left) { Write-Host "  - $l" }
