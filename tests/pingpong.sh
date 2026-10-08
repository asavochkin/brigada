#!/usr/bin/env bash
# Two scripted "agents" (no LLM) bounce a counter
# through brg — wait → send n+1 — with periodic takeovers (a wait left behind
# plus a new one), killed waits (SIGKILL at a random moment) and slow "work"
# longer than the other side's wait timeout.
# Checks: brg tail shows 1..N without holes or duplicates; no pause between the
# end of one wait and the start of the next (same agent) longer than 60 s.
# Usage: bash tests/pingpong.sh [-n N] [-t WAIT_TIMEOUT] [--keep]   (exit 0 = pass)

N=200
WT=2
KEEP=
while [ $# -gt 0 ]; do
  case $1 in
    -n) N=$2; shift 2 ;;
    -t) WT=$2; shift 2 ;;
    --keep) KEEP=1; shift ;;
    *) echo "Использование: bash tests/pingpong.sh [-n N] [-t WAIT_TIMEOUT] [--keep]" >&2; exit 2 ;;
  esac
done
case ${BASH_SOURCE[0]} in */*) _here=${BASH_SOURCE[0]%/*} ;; *) _here=. ;; esac
REPO=$(cd "$_here/.." && pwd)
export BRG_TICK=${BRG_TICK:-0.05}
unset BRG_AS BRG_PLATFORM
MAX_PAUSE=60
LIMIT=$((N * 2 + 120)) # whole run, seconds

tmp=${TMPDIR:-/tmp}
tmp=${tmp%/}
while :; do
  P=$tmp/brg-pingpong.$$.$RANDOM
  mkdir "$P" 2>/dev/null && break
done
B=$P/.brigada
BRG=$B/bin/brg
PIDS=

cleanup() {
  local p
  for p in $PIDS; do kill -TERM "$p" 2>/dev/null; done
  [ -d "$B/run" ] && : >"$B/run/stopped" # any wait left exits on its next tick
  sleep 0.3
  for p in $PIDS; do kill -KILL "$p" 2>/dev/null; done
  if [ -n "$KEEP" ]; then echo "каталог прогона сохранён: $P"; else rm -rf "$P"; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

bash "$REPO/bin/brg" init "$P" >/dev/null || exit 1
cat >"$B/config" <<EOF
wait_timeout.default: $WT
heartbeat: 1
lock_stale: 10
EOF
join() { bash "$BRG" join --harness pp --model script | sed -n 's/^── подключён: \([^ ]*\) .*/\1/p'; }
A1=$(join)
A2=$(join)
[ -n "$A1" ] && [ -n "$A2" ] || { echo "join не удался" >&2; exit 1; }
# full names (base.key) for --as; output, tail and metrics show the base names
N1=${A1%%.*}
N2=${A2%%.*}

# agent ME OTHER FIRST — plays one side; FIRST=1 sends 1.
agent() {
  local me=$1 other=$2 last=0 i=0 o bg k
  note() { printf '%s\n' "$*" >>"$P/events.$me"; }
  # handle FILE — act on the numbers from OTHER found in a wait output
  handle() {
    local n
    for n in $(awk -v o="${other%%.*}" '/^#[0-9]+ / { t = ($2 == o); next } t && /^  [0-9]+$/ { print $1 }' "$1"); do
      if [ "$n" -le "$last" ]; then
        note dup "$n"
        continue
      fi
      if [ "$n" -ne $((last + 1)) ]; then
        echo "$me: дыра — получил $n после $last" >>"$P/errors"
        continue
      fi
      if [ "$n" -ge "$N" ]; then
        : >"$P/done.$me"
        return
      fi
      [ $((n % 37)) -eq 0 ] && sleep $((WT + 1)) && note slow "$n" # "work" longer than the other's wait
      printf '%s\n' $((n + 1)) | bash "$BRG" send --as "$me" --to "$other" >/dev/null ||
        echo "$me: send $((n + 1)) не удался" >>"$P/errors"
      last=$((n + 1))
      if [ "$last" -ge "$N" ]; then
        : >"$P/done.$me"
        return
      fi
    done
  }
  if [ "$3" = 1 ]; then
    printf '1\n' | bash "$BRG" send --as "$me" --to "$other" >/dev/null || echo "$me: send 1" >>"$P/errors"
    last=1
  fi
  while [ ! -e "$P/done.$me" ]; do
    i=$((i + 1))
    o=$P/out.$me.$i
    if [ $((i % 7)) -eq 0 ]; then
      # takeover: the previous wait is left running (harness moved it to the
      # background), a new one starts; both outputs are read
      bash "$BRG" wait --as "$me" >"$o.bg" 2>&1 &
      bg=$!
      sleep 0.$((RANDOM % 3))
      bash "$BRG" wait --as "$me" >"$o" 2>&1
      wait $bg
      case $(cat "$o.bg") in *SUPERSEDED*) note superseded ;; esac
      handle "$o.bg"
      handle "$o"
    elif [ $((i % 5)) -eq 0 ]; then
      # a wait killed with SIGKILL at a random moment; whatever it printed is read
      bash "$BRG" wait --as "$me" >"$o" 2>&1 &
      k=$!
      sleep 0.$((RANDOM % 4))
      kill -KILL $k 2>/dev/null && note killed
      wait $k 2>/dev/null
      handle "$o"
    else
      bash "$BRG" wait --as "$me" >"$o" 2>&1
      handle "$o"
    fi
  done
}

T0=$(date -u +%s)
agent "$A1" "$A2" 1 &
PIDS="$PIDS $!"
agent "$A2" "$A1" 0 &
PIDS="$PIDS $!"
ok=1
while :; do
  alive=
  for p in $PIDS; do kill -0 "$p" 2>/dev/null && alive=1; done
  [ -n "$alive" ] || break
  if [ $(($(date -u +%s) - T0)) -gt "$LIMIT" ]; then
    echo "FAIL: не уложились в $LIMIT с (цикл встал?)"
    ok=
    break
  fi
  sleep 0.5
done
T1=$(date -u +%s)

# 1. the conversation, as the human sees it in tail: 1..N, no holes or duplicates
seqcheck=$(bash "$BRG" tail lobby | awk -v a="$N1" -v b="$N2" -v n="$N" '
  /^#[0-9]+ / { t = ($2 == a || $2 == b); next }
  t && /^  [0-9]+$/ { k++; if ($1 + 0 != k) { print "позиция " k ": " $1; bad++ } }
  END { if (k != n) print "сообщений " k ", ожидалось " n; else if (!bad) print "OK" }')
# 2. pauses end→start between waits of one agent (metrics.log)
pauses=$(awk -v a="$N1" -v b="$N2" -v m="$MAX_PAUSE" '
  $2 != a && $2 != b { next }
  $3 == "wait.start" { starts[$2]++; if ($2 in e) { p = $1 - e[$2]; if (p > mx[$2]) mx[$2] = p; if (p > m) big++; delete e[$2] } }
  $3 == "wait" { e[$2] = $1; ends[$2]++; for (i = 4; i <= NF; i++) if ($i ~ /^result=/) r[$2 " " substr($i, 8)]++ }
  END {
    for (x in starts) {
      line = x ": wait " starts[x] ", завершилось " ends[x] ", макс. пауза end→start " mx[x] + 0 " с;"
      for (k in r) { split(k, q, " "); if (q[1] == x) line = line " " q[2] "=" r[k] }
      print line
    }
    print (big ? "FAIL " big " пауз > " m " с" : "OK")
  }' "$B/run/metrics.log")
ev() { cat "$P"/events.* 2>/dev/null | awk -v k="$1" '$1 == k' | wc -l | tr -d ' '; }

echo "── pingpong: N=$N, wait_timeout=$WT с, тик ${BRG_TICK} с, прогон $((T1 - T0)) с"
printf '%s\n' "$pauses" | sed '$d'
killed=$(awk -v a="$N1" -v b="$N2" '($2 == a || $2 == b) && $3 == "wait.start" { s++ } ($2 == a || $2 == b) && $3 == "wait" { e++ } END { print s - e }' "$B/run/metrics.log")
echo "takeover (SUPERSEDED): $(ev superseded), SIGKILL: $(ev killed) (из них убито до записи end: $killed), дубликатов получено (at-least-once): $(ev dup), медленных шагов: $(ev slow)"
echo "последовательность в tail: $seqcheck"
echo "паузы > $MAX_PAUSE с: $(printf '%s\n' "$pauses" | tail -n 1)"
if [ -s "$P/errors" ]; then
  echo "ошибки агентов:"
  sed 's/^/  /' "$P/errors"
  ok=
fi
[ "$seqcheck" = OK ] || ok=
[ "$(printf '%s\n' "$pauses" | tail -n 1)" = OK ] || ok=
if [ -n "$ok" ]; then
  echo "── PASS"
  exit 0
fi
echo "── FAIL"
KEEP=1
exit 1
