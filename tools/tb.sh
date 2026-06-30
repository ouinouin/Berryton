#!/usr/bin/env bash
# Drive the test-bench ESP32 (testberry.lan) over Tasmota HTTP. Centralizes every bench interaction
# behind a single command so it can be allowlisted once (no curl prompt per call).
# Requires SetOption128 1 on the device (enables the /cm HTTP command API).
#
# Usage:
#   tools/tb.sh run   "<berry code>"   # eval Berry via the RunBerry autoexec command, prints the result
#   tools/tb.sh cmnd  "<tasmota cmd>"  # run any Tasmota console command (e.g. "Publish topic payload")
#   tools/tb.sh log   [n]              # last n console log lines (default 40)
#   tools/tb.sh upload <file.be>       # UFS-upload a file to the device
#   tools/tb.sh reload                 # BrRestart (reload the Berry VM ; full Restart needed if OOM)
set -uo pipefail
HOST="${TB_HOST:-testberry.lan}"
cmd="${1:-}"; shift || true
case "$cmd" in
  run)    curl -s --max-time 12 --data-urlencode "cmnd=RunBerry $*" --get "http://$HOST/cm"; echo ;;
  cmnd)   curl -s --max-time 12 --data-urlencode "cmnd=$*" --get "http://$HOST/cm"; echo ;;
  log)    curl -s --max-time 12 "http://$HOST/cs?c2=0" | tr -d '\r' | tail -"${1:-40}" ;;
  upload) f="$1"; curl -s --max-time 25 -F "ufsu=@$f" "http://$HOST/ufsu?fsz=$(stat -c%s "$f")" -o /dev/null -w "upload %{http_code}\n" ;;
  reload) curl -s --max-time 12 --data-urlencode "cmnd=BrRestart" --get "http://$HOST/cm"; echo ;;
  *)      echo "usage: tb.sh {run <berry>|cmnd <tasmota>|log [n]|upload <file>|reload}"; exit 2 ;;
esac
