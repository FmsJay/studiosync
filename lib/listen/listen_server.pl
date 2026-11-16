#!/usr/bin/perl
# StudioSync's listening page server (lib/listen.lua starts it; macOS, whose own perl has everything this needs). Serves, to this computer
# only (127.0.0.1), the studio's page (_band/listen.html) and its songs' mixes (<song>/mixes/<audio file>), nothing else; Tailscale forwards
# the tailnet to it. Read-only, GET and HEAD only, with byte ranges (phones seek that way). Quits by itself once the heartbeat file is over
# 2 minutes old: REAPER closed, or the sharing stopped.
use strict; use warnings; use IO::Socket::INET; use IO::Select; use Cwd qw(realpath);
my ($root, $port, $beat, $prefix) = @ARGV;
my $real_root = realpath($root) // $root;
my %types = (html => "text/html; charset=utf-8", wav => "audio/wav", flac => "audio/flac", mp3 => "audio/mpeg", ogg => "audio/ogg",
  m4a => "audio/mp4", aif => "audio/aiff", aiff => "audio/aiff");
my $srv = IO::Socket::INET->new(LocalAddr => "127.0.0.1", LocalPort => $port, Listen => 8, ReuseAddr => 1) or die "listen: $!";
my $sel = IO::Select->new($srv);
# (a phone that stops a download half way closes its end: the next write raised SIGPIPE and killed the server. Each connection gets a process of
# its own, so one long download doesn't hold the page up for everyone, and one that never sends a request is dropped after 10 s. Mac review, 0.58.62)
$SIG{PIPE} = 'IGNORE';
$SIG{CHLD} = 'IGNORE';
sub alive { my @s = stat($beat); return @s && time - $s[9] < 120 }
while (alive()) {
  next unless $sel->can_read(5);
  my $c = $srv->accept or next;
  my $pid = fork();
  if (!defined $pid) { close $c; next }
  if ($pid) { close $c; next }
  close $srv;
  $c->autoflush(1);
  local $SIG{ALRM} = sub { exit 0 };
  alarm 10;
  my $req = <$c> // ""; my %h;
  while (my $line = <$c>) { last if $line =~ /^\r?\n$/; $h{lc $1} = $2 if $line =~ /^([^:]+):\s*(.*?)\r?\n$/ }
  alarm 0; # (the body below gets its own alarm: Review, 0.58.67)
  my ($method, $path) = $req =~ m{^(GET|HEAD) (\S+) HTTP} or do { print $c "HTTP/1.0 405 No\r\n\r\n"; close $c; exit 0 };
  $path =~ s/\?.*$//; $path =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
  $path = substr($path, length $prefix) if $prefix && index($path, $prefix) == 0;
  $path =~ s{^/+}{};
  my $ok = $path !~ /\.\./ && ($path eq "_band/listen.html" || $path =~ m{^[^/]+/mixes/[^/]+\.(wav|flac|mp3|ogg|m4a|aif|aiff)$}i);
  my $file = "$root/$path";
  # (Syncthing syncs symlinks on macOS: a bandmate's mixes/notes.wav pointing at ~/.ssh/... was served. The file, wherever links lead, must be
  # inside the studio. Security review, 0.58.67)
  my $real = $ok ? (realpath($file) // "") : "";
  $ok = $ok && !-l $file && index($real, "$real_root/") == 0;
  unless ($ok && -f $file) { print $c "HTTP/1.0 404 Not here\r\nContent-Length: 0\r\n\r\n"; close $c; exit 0 }
  my $len = -s $file; my ($from, $to, $status) = (0, $len - 1, "200 OK"); my $extra = "";
  if (($h{range} // "") =~ /^bytes=(\d*)-(\d*)$/) {
    if ($1 ne "") { $from = $1; $to = $2 < $len ? $2 : $len - 1 if $2 ne "" } elsif ($2 ne "") { $from = $len - $2; $from = 0 if $from < 0 }
    if ($from > $to) { print $c "HTTP/1.0 416 Range\r\nContent-Range: bytes */$len\r\n\r\n"; close $c; exit 0 }
    $status = "206 Partial Content"; $extra = "Content-Range: bytes $from-$to/$len\r\n";
  }
  alarm 600; # (a download that stalls, a phone that stopped reading: this process ends after 10 minutes. Review, 0.58.67)
  my ($ext) = $file =~ /\.(\w+)$/;
  print $c "HTTP/1.0 $status\r\nContent-Type: " . ($types{lc $ext} // "application/octet-stream") . "\r\nContent-Length: " . ($to - $from + 1) .
    "\r\nAccept-Ranges: bytes\r\n$extra\r\n";
  if ($method eq "GET" && open(my $fh, "<:raw", $file)) {
    seek($fh, $from, 0); my $left = $to - $from + 1;
    while ($left > 0) { my $n = read($fh, my $buf, $left < 65536 ? $left : 65536) or last; last unless print $c $buf; $left -= $n }
    close $fh;
  }
  close $c;
  exit 0;
}
