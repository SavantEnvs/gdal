#!/usr/bin/env bash
#
# mayhem/test.sh — known-answer oracle over the CLI tools mayhem/build.sh built with normal flags.
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=/mayhem}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# Known-answer probes: each runs a real GDAL tool on a tiny generated input and compares its output with
# a value fixed by hand (pixel statistics, checksums, geotransform, reprojected coordinates, SQL results,
# PROJ strings). A tool that exits 0 without doing the work, or a patch that breaks a code path, fails.
BIN="$SRC/mayhem/build-tests/apps"
for t in gdalinfo ogrinfo gdal_translate ogr2ogr gdalsrsinfo gdaltransform; do
  [ -x "$BIN/$t" ] || { echo "missing $BIN/$t — mayhem/build.sh should have built it" >&2; emit_ctrf gdal-kat 0 1 0; exit 1; }
done
W="$(mktemp -d "${TMPDIR:-/tmp}/gdal-kat.XXXXXX")"; trap 'rm -rf "$W"' EXIT
cd "$W"
passed=0; failed=0
check() {  # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then passed=$((passed+1)); echo "ok   $1"
  else failed=$((failed+1)); echo "FAIL $1: expected [$2] got [$3]" >&2; fi
}

printf 'ncols 3\nnrows 3\nxllcorner 0\nyllcorner 0\ncellsize 1\nNODATA_value -9999\n1 2 3\n4 5 6\n7 8 9\n' > g.asc
"$BIN/gdal_translate" -q -of GTiff -co COMPRESS=DEFLATE g.asc g.tif >/dev/null 2>&1
info="$("$BIN/gdalinfo" -json -stats -checksum g.tif 2>/dev/null)"
field() { printf '%s' "$info" | python3 -c "import json,sys
try:
    j=json.load(sys.stdin); b=j['bands'][0]; print($1)
except Exception: print('ERR')"; }
check raster-size "[3, 3]" "$(field "j['size']")"
check raster-stats "1.0 9.0 5.0" "$(field "b['minimum'], b['maximum'], b['mean']")"
check raster-checksum "45" "$(field "b['checksum']")"
check raster-geotransform "[0.0, 1.0, 0.0, 3.0, 0.0, -1.0]" "$(field "j['geoTransform']")"
check raster-window "xll=1.000000000000 yll=1.000000000000 v=5" "$("$BIN/gdal_translate" -q -srcwin 1 1 1 1 -of AAIGRID g.tif /vsistdout/ 2>/dev/null | awk '/^xllcorner/{x=$2} /^yllcorner/{y=$2} /^[0-9]+ *$/{v=$1} END{print "xll=" x " yll=" y " v=" v}')"

printf 'id,v,WKT\n1,10,"POINT (1 2)"\n2,32,"POINT (3 4)"\n' > p.csv
"$BIN/ogr2ogr" -q -f "ESRI Shapefile" out.shp p.csv -s_srs EPSG:4326 -t_srs EPSG:3857 >/dev/null 2>&1
al="$("$BIN/ogrinfo" -al out.shp 2>/dev/null)"
check vector-feature-count "2" "$(printf '%s\n' "$al" | sed -n 's/^Feature Count: //p')"
check vector-reprojected "POINT (111319.490793274 222684.208505544)|POINT (333958.472379821 445640.109656026)" \
  "$(printf '%s\n' "$al" | sed -n 's/^ *\(POINT ([0-9. ]*)\)$/\1/p' | paste -sd'|')"
sql="$("$BIN/ogrinfo" -q -dialect SQLite -sql "SELECT SUM(v) AS s, ST_Area(ST_GeomFromText('POLYGON((0 0,2 0,2 3,0 3,0 0))')) AS a FROM p" p.csv 2>/dev/null | sed -n 's/^ *\([sa]\) (.*) = /\1=/p' | paste -sd' ')"
check vector-sql "s=42 a=6" "$sql"

check srs-proj4 "+proj=utm +zone=31 +datum=WGS84 +units=m +no_defs" "$("$BIN/gdalsrsinfo" -o proj4 EPSG:32631 2>/dev/null | tr -d '\n' | sed 's/ *$//')"
check transform "111319.490793274 222684.208505544 0" "$(echo '1 2' | "$BIN/gdaltransform" -s_srs EPSG:4326 -t_srs EPSG:3857 2>/dev/null)"

cd "$SRC"
emit_ctrf gdal-kat "$passed" "$failed" 0
