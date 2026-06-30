#!/usr/bin/env bash
# Compile-check Berry files without an ESP32.
#
# It only runs Berry's compile() (parse + strict-mode checks) on each file, never executes it, so no
# hardware/Tasmota call is triggered : safe to run after any edit/re-indent. The Tasmota-provided globals
# that are absent in the standalone interpreter (serial / tasmota / webclient) are declared as stubs so
# strict mode does not flag them as undeclared.
#
# Usage:
#   tools/bcheck.sh                 # check every *.be in the repo root
#   tools/bcheck.sh Berryton.be ...  # check the given files
#
# The standalone interpreter is expected at $BERRY (default /tmp/berry/berry) and is built on first use.
set -uo pipefail
BERRY="${BERRY:-/tmp/berry/berry}"

if [ ! -x "$BERRY" ]; then
  echo "berry interpreter missing -> building at /tmp/berry (one-off) ..."
  rm -rf /tmp/berry
  git clone --depth 1 https://github.com/berry-lang/berry /tmp/berry >/dev/null 2>&1 || { echo "clone failed"; exit 2; }
  make -C /tmp/berry -j4 >/tmp/berry/build.log 2>&1 || { echo "build failed, see /tmp/berry/build.log"; exit 2; }
  BERRY=/tmp/berry/berry
fi

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
files=("$@")
if [ ${#files[@]} -eq 0 ]; then files=(*.be); fi

status=0
for f in "${files[@]}"; do
  out=$("$BERRY" -e "var fh=open('$f','r') var s=fh.read() fh.close() try compile('var serial, tasmota, webclient\n'+s) print('OK   : $f') except .. as e,m print('FAIL : $f') print('  ',e,' : ',m) end" 2>&1)
  echo "$out"
  echo "$out" | grep -q '^FAIL' && status=1
done
exit $status
