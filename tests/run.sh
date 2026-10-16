#!/bin/zsh
# Runs gfxtest for every renderer, API and bitness in a throwaway bottle; prints a result table.
# Usage: tests/run.sh [path/to/barrel]
set -uo pipefail
here=${0:A:h}
barrel=${1:-$here/../cli/barrel}
bottle=barrel-test

[[ -d "${BARREL_HOME:-$HOME/Library/Application Support/Barrel}/bottles/$bottle" ]] || $barrel new $bottle >/dev/null

# run_one <exe> <api>: prints the test's result line (30 s limit; the first run compiles shaders)
run_one() {
  local out=$(mktemp) pid
  $barrel run $bottle "$here/$1" $2 > "$out" 2>/dev/null & pid=$!
  ( sleep 30; kill $pid 2>/dev/null ) & local timer=$!
  wait $pid 2>/dev/null
  kill $timer 2>/dev/null
  grep -m1 -E '^(OK|FAIL)' "$out" || print "FAIL $2 (no result: crashed or timed out)"
  rm -f "$out"
}

failed=0
if $barrel run $bottle "$here/fonttest.exe" 2>/dev/null | grep FAIL; then failed=1; else print "fonts     fonttest.exe   OK all Windows fonts found"; fi
for r in d3dmetal dxmt dxvk wined3d; do
  $barrel set $bottle renderer $r >/dev/null
  for t in "gfxtest64.exe d3d12" "gfxtest64.exe d3d11" "gfxtest32.exe d3d11" "gfxtest64.exe d3d9" "gfxtest32.exe d3d9"; do
    # Combinations the renderer doesn't provide: DX12 is D3DMetal only, wined3d has no DX11 on macOS OpenGL.
    if [[ $r:${t##* } == (dxmt|dxvk|wined3d):d3d12 || $r:${t##* } == wined3d:d3d11 ]]; then
      line="-  not supported"
    else
      line=$(run_one ${=t})
      [[ $line == OK* ]] || failed=1
    fi
    printf '%-9s %-14s %s\n' $r "${t%% *}" "$line"
  done
  $barrel kill $bottle >/dev/null 2>&1
done
exit $failed
