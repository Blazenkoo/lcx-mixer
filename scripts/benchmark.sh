#!/bin/bash
# Measures how much CPU and memory the running LCX Mixer uses, the way the numbers in
# docs/SPEC.md (Performance) were taken: macOS's `top`, one sample every 2 seconds.
#
# Usage: ./scripts/benchmark.sh <state> [seconds]
#   state    a name for what's on screen while it runs, e.g. closed, mixer or about
#   seconds  how long to sample; default 300 (5 minutes)
#
# Set things up first (sources playing, the window you want open), then run it and leave the Mac
# alone until it finishes. It prints one table row:
#   | state | average CPU | highest CPU | memory at the end | samples |
set -euo pipefail

state="${1:-}"
seconds="${2:-300}"
if [ -z "$state" ]; then
  echo "Name the state you're measuring, e.g.: ./scripts/benchmark.sh closed" >&2
  exit 2
fi

# The app itself, not the small bridge processes the browsers start (same executable, other path).
pid="$(pgrep -f "LCX Mixer.app/Contents/MacOS/LCXMixer$" | head -1 || true)"
if [ -z "$pid" ]; then
  echo "LCX Mixer isn't running." >&2
  exit 1
fi

samples=$(( seconds / 2 + 1 ))
echo "Sampling LCX Mixer (pid $pid) for $seconds s as \"$state\"..." >&2

top -l "$samples" -s 2 -pid "$pid" -stats pid,cpu,mem 2>/dev/null | awk -v pid="$pid" -v state="$state" '
  # Memory as top prints it (e.g. 36M, 4145K, 1.2G, with a trailing + or -), in MB.
  function megabytes(text,   unit, n) {
    gsub(/[+-]$/, "", text)
    unit = substr(text, length(text), 1)
    n = substr(text, 1, length(text) - 1) + 0
    if (unit == "K") return n / 1024
    if (unit == "G") return n * 1024
    if (unit == "B") return n / 1048576
    return n
  }
  $1 == pid {
    seen++
    if (seen == 1) next   # the first sample has no CPU history yet
    cpu += $2; n++
    if ($2 > peak) peak = $2
    mem = megabytes($3)
  }
  END {
    if (n == 0) { print "No samples: did LCX Mixer quit?" > "/dev/stderr"; exit 1 }
    printf "| %s | %.1f%% | %.1f%% | %.0f MB | %d |\n", state, cpu / n, peak, mem, n
  }'
