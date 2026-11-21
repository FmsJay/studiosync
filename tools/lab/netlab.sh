#!/bin/bash
# StudioSync lab: network recipes. Runs INSIDE a lab VM (LinuxBox, LinuxBox2), never on the real PCs. Run it through lab.sh from the desktop:
#   lab.sh net x2 block 192.168.86.129 [47281[/udp]] [--dir in|out|both]
#   lab.sh net x2 unblock 192.168.86.129 [47281[/udp]] [--dir ...]
#   lab.sh net x2 shape 192.168.86.129[,10.0.0.5] [--dev ens192] [--delay MS] [--jitter MS] [--loss PCT] [--rate KBIT] [--reorder PCT]
#   lab.sh net x2 undo        (every rule and qdisc this script made; safe to run any time, any number of times)
#   lab.sh net x2 status
# Idempotent: a repeat prints "already ..." and changes nothing. Every change prints a line starting "changed:".
# block: iptables chain LAB_NET, hooked once into INPUT and OUTPUT. Matches the peer's IPv4 address, so it works on any interface
#        (the LAN address and, on LinuxBox, the 100.x Tailscale address are two addresses: block each you want cut).
# shape: tc netem on the egress of --dev (default: the interface the route to the first peer uses). Peers given: only traffic to those
#        addresses is shaped (prio qdisc + u32 filters); "all": the whole interface. Each call REPLACES the previous shaping.
#        Egress only: for a symmetric link run it on both VMs (round trip = the two delays added).
set -u
[ "$(id -u)" = 0 ] || exec sudo -E bash "$0" "$@"
CH=LAB_NET
say() { echo "$*"; }
ip4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
need() { command -v "$1" >/dev/null || { say "missing tool: $1"; exit 2; }; }
need iptables; need tc; need ip

hook() { # hook the chain once
  iptables -nL $CH >/dev/null 2>&1 || { iptables -N $CH; say "changed: created chain $CH"; }
  for h in INPUT OUTPUT; do
    iptables -C $h -j $CH 2>/dev/null || { iptables -I $h 1 -j $CH; say "changed: $h now jumps to $CH"; }
  done
}
rules() { # peer port/proto dir -> prints one iptables arg line per rule
  local peer="$1" pp="$2" dir="$3" port="${2%%/*}" protos
  if [ -z "$pp" ]; then protos=""; else [[ "$pp" == */* ]] && protos="${pp##*/}" || protos="tcp udp"; fi
  local p
  for p in ${protos:-any}; do
    local m=""; [ "$p" != any ] && m="-p $p"
    if [ "$dir" != out ]; then
      [ -z "$pp" ] && echo "INPUT -s $peer -j DROP" || { echo "INPUT -s $peer $m --dport $port -j DROP"; echo "INPUT -s $peer $m --sport $port -j DROP"; }
    fi
    if [ "$dir" != in ]; then
      [ -z "$pp" ] && echo "OUTPUT -d $peer -j DROP" || { echo "OUTPUT -d $peer $m --dport $port -j DROP"; echo "OUTPUT -d $peer $m --sport $port -j DROP"; }
    fi
  done
}
# the rules sit in $CH, so strip the INPUT/OUTPUT word and add to the chain
block_one() { # $1 add|del  $2 peer $3 port $4 dir
  local act="$1" line spec n=0
  while read -r line; do
    spec="${line#* }"
    if [ "$act" = add ]; then
      iptables -C $CH $spec 2>/dev/null && say "already: $CH $spec" || { iptables -A $CH $spec; say "changed: added $CH $spec"; }
    else
      if iptables -C $CH $spec 2>/dev/null; then iptables -D $CH $spec; say "changed: removed $CH $spec"; else say "already absent: $CH $spec"; fi
    fi
  done < <(rules "$2" "$3" "$4")
}
parse_bd() { PEER="${1:-}"; shift || true; PORT=""; DIR=both
  ip4 "$PEER" || { say "need a peer IPv4 address, got '$PEER'"; exit 2; }
  while [ $# -gt 0 ]; do case "$1" in --dir) DIR="$2"; shift 2;; *) PORT="$1"; shift;; esac; done
  case "$DIR" in in|out|both) ;; *) say "--dir is in, out or both"; exit 2;; esac
}
undo_shape() { local d
  for d in $(ip -o link | awk -F': ' '{print $2}' | cut -d@ -f1); do
    if tc qdisc show dev "$d" 2>/dev/null | grep -q "qdisc \(netem\|prio\) .*root"; then tc qdisc del dev "$d" root && say "changed: removed shaping on $d"; fi
  done
}
cmd="${1:-}"; shift || true
case "$cmd" in
  block)   parse_bd "$@"; hook; block_one add "$PEER" "$PORT" "$DIR";;
  unblock) parse_bd "$@"; block_one del "$PEER" "$PORT" "$DIR";;
  shape)
    peers="${1:-}"; shift || true; DEV=""; DELAY=""; JIT=""; LOSS=""; RATE=""; REORD=""
    while [ $# -gt 0 ]; do case "$1" in --dev) DEV="$2";; --delay) DELAY="$2";; --jitter) JIT="$2";; --loss) LOSS="$2";; --rate) RATE="$2";; --reorder) REORD="$2";; *) say "unknown option $1"; exit 2;; esac; shift 2; done
    [ -n "$peers" ] || { say "shape needs peers (comma list) or 'all'"; exit 2; }
    [ -n "$DELAY$LOSS$RATE" ] || { say "give at least one of --delay --loss --rate"; exit 2; }
    [ -z "$JIT" ] || [ -n "$DELAY" ] || { say "--jitter needs --delay"; exit 2; }
    if [ "$peers" != all ]; then IFS=, read -ra PL <<<"$peers"; for p in "${PL[@]}"; do ip4 "$p" || { say "bad peer $p"; exit 2; }; done
      [ -n "$DEV" ] || DEV=$(ip -4 route get "${PL[0]}" | grep -o 'dev [^ ]*' | head -1 | cut -d' ' -f2)
    else [ -n "$DEV" ] || DEV=$(ip -4 route show default | grep -o 'dev [^ ]*' | head -1 | cut -d' ' -f2); fi
    [ -n "$DEV" ] || { say "can't find the interface; give --dev"; exit 2; }
    ne="netem"; [ -n "$DELAY" ] && ne="$ne delay ${DELAY}ms${JIT:+ ${JIT}ms distribution normal}"; [ -n "$LOSS" ] && ne="$ne loss ${LOSS}%"
    [ -n "$REORD" ] && ne="$ne reorder ${REORD}% 50%"; [ -n "$RATE" ] && ne="$ne rate ${RATE}kbit"
    undo_shape >/dev/null   # replace, not stack: the same call twice leaves the same state
    if [ "$peers" = all ]; then tc qdisc add dev "$DEV" root $ne
    else
      tc qdisc add dev "$DEV" root handle 1: prio bands 3 priomap 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1
      tc qdisc add dev "$DEV" parent 1:3 handle 30: $ne
      n=0; for p in "${PL[@]}"; do n=$((n+1)); tc filter add dev "$DEV" parent 1: protocol ip prio $n u32 match ip dst "$p"/32 flowid 1:3; done
    fi
    say "changed: shaping on $DEV for $peers: $ne";;
  undo)
    for h in INPUT OUTPUT; do while iptables -D $h -j $CH 2>/dev/null; do say "changed: unhooked $CH from $h"; done; done
    if iptables -nL $CH >/dev/null 2>&1; then iptables -F $CH; iptables -X $CH; say "changed: deleted chain $CH"; fi
    undo_shape; say "undo done: no $CH, no netem/prio qdisc left";;
  status)
    say "== iptables $CH"; iptables -nL $CH >/dev/null 2>&1 && iptables -S $CH | sed 's/^/  /'; { iptables -S INPUT; iptables -S OUTPUT; } | grep "$CH" | sed 's/^/  /'
    say "== tc"; tc qdisc show | grep -v "noqueue\|fq_codel\|pfifo_fast\|mq 0" | sed 's/^/  /'; tc filter show dev "$(ip -4 route show default | grep -o 'dev [^ ]*' | head -1 | cut -d' ' -f2)" parent 1: 2>/dev/null | grep -o 'match [^ ]*\|flowid [^ ]*' | paste - - | sed 's/^/  /';;
  *) sed -n '2,16p' "$0"; exit 2;;
esac
