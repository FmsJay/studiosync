# StudioSync's listening page server (lib/listen.lua starts it; Windows). Serves, to this computer only (127.0.0.1), the studio's page
# (_band/listen.html) and its songs' mixes (<song>/mixes/<audio file>), nothing else; Tailscale forwards the tailnet to it. Read-only, GET and
# HEAD only, with byte ranges (phones seek that way). Quits by itself once the heartbeat file is over 2 minutes old: REAPER closed, or the
# sharing stopped, so it's never left running.
param([string]$Root, [int]$Port, [string]$Beat, [string]$Prefix)
$ErrorActionPreference = "Stop"
$types = @{ ".html" = "text/html; charset=utf-8"; ".wav" = "audio/wav"; ".flac" = "audio/flac"; ".mp3" = "audio/mpeg"; ".ogg" = "audio/ogg";
  ".m4a" = "audio/mp4"; ".aif" = "audio/aiff"; ".aiff" = "audio/aiff" }
$l = New-Object Net.HttpListener
$l.Prefixes.Add("http://127.0.0.1:$Port/")
$l.Start()
$rootFull = [IO.Path]::GetFullPath($Root)
function Alive { (Test-Path -LiteralPath $Beat) -and (((Get-Date) - (Get-Item -LiteralPath $Beat).LastWriteTime).TotalSeconds -lt 120) }
$task = $l.GetContextAsync()
while (Alive) {
  if (-not $task.Wait(5000)) { continue }
  $c = $task.Result
  $task = $l.GetContextAsync()
  $res = $c.Response
  try {
    $path = [Uri]::UnescapeDataString($c.Request.Url.AbsolutePath)
    if ($Prefix -and $path.StartsWith($Prefix)) { $path = $path.Substring($Prefix.Length) }
    $path = $path.TrimStart('/')
    $ok = ($c.Request.HttpMethod -eq "GET" -or $c.Request.HttpMethod -eq "HEAD") -and $path -notmatch '\.\.' -and $path -notmatch '[:\\]' -and
      ($path -eq "_band/listen.html" -or $path -match '^[^/]+/mixes/[^/]+\.(wav|flac|mp3|ogg|m4a|aif|aiff)$')
    $file = if ($ok) { [IO.Path]::GetFullPath((Join-Path $rootFull $path)) } else { $null }
    if (-not $ok -or -not $file.StartsWith($rootFull) -or -not (Test-Path -LiteralPath $file -PathType Leaf)) {
      $res.StatusCode = 404; $res.Close(); continue
    }
    $len = (Get-Item -LiteralPath $file).Length
    $from, $to = 0, ($len - 1)
    $range = $c.Request.Headers["Range"]
    if ($range -match '^bytes=(\d*)-(\d*)$') {
      if ($Matches[1] -ne "") { $from = [int64]$Matches[1]; if ($Matches[2] -ne "") { $to = [Math]::Min([int64]$Matches[2], $len - 1) } }
      elseif ($Matches[2] -ne "") { $from = [Math]::Max(0, $len - [int64]$Matches[2]) }
      if ($from -gt $to) { $res.StatusCode = 416; $res.AddHeader("Content-Range", "bytes */$len"); $res.Close(); continue }
      $res.StatusCode = 206
      $res.AddHeader("Content-Range", "bytes $from-$to/$len")
    }
    $res.AddHeader("Accept-Ranges", "bytes")
    $ext = [IO.Path]::GetExtension($file).ToLower()
    $res.ContentType = $types[$ext]
    $res.ContentLength64 = $to - $from + 1
    if ($c.Request.HttpMethod -eq "GET") {
      $fs = [IO.File]::Open($file, 'Open', 'Read', 'ReadWrite')
      try {
        $fs.Seek($from, 'Begin') | Out-Null
        $left = $to - $from + 1; $buf = New-Object byte[] 65536
        while ($left -gt 0) {
          $n = $fs.Read($buf, 0, [Math]::Min($buf.Length, $left)); if ($n -le 0) { break }
          $res.OutputStream.Write($buf, 0, $n); $left -= $n
        }
      } finally { $fs.Close() }
    }
    $res.Close()
  } catch { try { $res.Abort() } catch {} }
}
$l.Stop()
