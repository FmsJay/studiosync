# Runs at logon inside Windows Sandbox (a throwaway Windows that's wiped when its window closes): a new bandmate on a clean PC.
# 1. winget (Sandbox has none) through Microsoft's own PowerShell module. 2. The guest invitation's Windows line, exactly as a bandmate
# pastes it, plus answers to the installer's questions. 3. A status report every 20 s in C:\ss (mapped to the laptop) until closed.
$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"
$ss = "C:\ss"
Start-Transcript -Path "$ss\log.txt" -Force | Out-Null
function Note($m) { "$(Get-Date -Format HH:mm:ss) $m" | Tee-Object -FilePath "$ss\steps.txt" -Append }
Note "sandbox up: $env:COMPUTERNAME, $([Environment]::OSVersion.VersionString)"

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
  Note "installing winget"
  try {
    Install-PackageProvider -Name NuGet -Force -Scope AllUsers | Out-Null
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    Install-Module Microsoft.WinGet.Client -Force -Scope AllUsers -AllowClobber
    Import-Module Microsoft.WinGet.Client
    Repair-WinGetPackageManager -AllUsers -Latest -Force
  } catch { Note "winget module route failed: $_" }
  $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User") + ";$env:LOCALAPPDATA\Microsoft\WindowsApps"
}
$wg = Get-Command winget -ErrorAction SilentlyContinue
Note "winget: $(if ($wg) { & winget --version } else { 'MISSING' })"

$line = (Get-Content "$ss\invite.txt" -Raw).Trim()
Remove-Item "$ss\invite.txt" -Force # (a single-use guest key: gone from the shared folder once read)
$answers = " -User 'Sandbox Guest' -Root `"$env:USERPROFILE\StudioSync Sandbox Test`" -Live yes -Solo no -Plugins no -Extras no"
Note "running the invitation's Windows line (key hidden) with: $answers"
$run = Join-Path $env:TEMP "invite_run.ps1"
Set-Content $run ($line + $answers) -Encoding UTF8
"`n`n`n`n`n`n" | powershell -NoProfile -ExecutionPolicy Bypass -File $run *>&1 | ForEach-Object { ($_ | Out-String).TrimEnd() -replace 'tskey-[A-Za-z0-9-]+', '[hidden]' } | Tee-Object -FilePath "$ss\installer.txt"
Note "installer finished (exit $LASTEXITCODE)"
Stop-Transcript | Out-Null

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
function Shot($path) { # the Sandbox's own screen, so its windows can be seen without bringing the Sandbox forward on the laptop
  $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
  $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
  [System.Drawing.Graphics]::FromImage($bmp).CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
  $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
}
while ($true) { # what a bandmate's PC looks like now, for the laptop to read
  foreach ($c in Get-ChildItem "$ss\cmd-*.ps1" -ErrorAction SilentlyContinue) { # commands dropped in by the PC, run once each
    $o = try { & $c.FullName *>&1 | Out-String } catch { "ERROR $_" }
    Set-Content ($c.FullName -replace '\.ps1$', '.out') $o
    Remove-Item $c.FullName
  }
  try { Shot "$ss\shot.png" } catch { }
  $ts = "C:\Program Files\Tailscale\tailscale.exe"
  $st = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\*\syncthing*\syncthing.exe", "C:\Program Files*\Syncthing\syncthing.exe", "$env:LOCALAPPDATA\Programs\Syncthing\syncthing.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
  $root = "$env:USERPROFILE\StudioSync Sandbox Test"
  @(
    "time $(Get-Date -Format HH:mm:ss)"
    "tailscale: $(if (Test-Path $ts) { (& $ts status --self --peers=false 2>&1 | Out-String).Trim() } else { 'not installed' })"
    "tailscale ip: $(if (Test-Path $ts) { (cmd /c "`"$ts`" ip -4 2>&1" | Out-String).Trim() })"
    "syncthing: $(if ($st) { $st.FullName } else { 'not found' }); running: $([bool](Get-Process syncthing -ErrorAction SilentlyContinue))"
    "syncthing id: $(if ($st) { (& $st.FullName device-id 2>&1 | Out-String).Trim() })"
    "reaper running: $([bool](Get-Process reaper -ErrorAction SilentlyContinue))"
    "studio folder: $(Test-Path $root)"
    "studio files:"
    (Get-ChildItem $root -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { "  " + $_.FullName.Substring($root.Length) + " " + $_.Length })
  ) | Set-Content "$ss\status.txt"
  Start-Sleep -Seconds 10
}
