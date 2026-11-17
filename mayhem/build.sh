#!/usr/bin/env bash
#
# mayhem/build.sh — builds GDAL twice (sanitized shared libgdal for the fuzz harnesses, plain Release
# build with the CLI tools for mayhem/test.sh), then every fuzz harness as a libFuzzer binary and a
# `-standalone` run-once reproducer in /mayhem. All dependencies are apt -dev packages, so a re-run
# works offline.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) so an explicit empty SANITIZER_FLAGS builds with no sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${SRC:=/mayhem}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
FB="$SRC/mayhem/build-fuzz"      # sanitized, shared libgdal
TB="$SRC/mayhem/build-tests"     # normal flags, used by mayhem/test.sh
OBJ="$FB/harness-obj"

# The drivers the harnesses exercise (everything the OSS-Fuzz / in-tree fuzzers register).
OGR_DRIVERS="PGDUMP GML GMLAS GPKG SQLITE DXF OPENFILEGDB SHAPE CSV WASP XLSX ODS LVBAG AVC FLATGEOBUF S101 MIRAMON CAD MITAB GEOJSON GPX KML OSM"
GDAL_DRIVERS="GTIFF HFA ADRG SRP RAW AIGRID AAIGRID BMP NITF GRIB PCIDSK RRASTER MRF VRT ERS ZARR DIMAP MIRAMON LIBERTIFF JPEG PNG GIF"

configure() {   # <builddir> <build-type> <apps> <extra c/c++ flags>
    local dir="$1" type="$2" apps="$3" flags="$4" opts=() d
    for d in $OGR_DRIVERS; do opts+=("-DOGR_ENABLE_DRIVER_$d=ON"); done
    for d in $GDAL_DRIVERS; do opts+=("-DGDAL_ENABLE_DRIVER_$d=ON"); done
    cmake -S "$SRC" -B "$dir" -G Ninja -DCMAKE_BUILD_TYPE="$type" -DBUILD_SHARED_LIBS=ON \
        -DBUILD_APPS="$apps" -DBUILD_TESTING=OFF \
        -DBUILD_PYTHON_BINDINGS=OFF -DBUILD_JAVA_BINDINGS=OFF -DBUILD_CSHARP_BINDINGS=OFF \
        -DGDAL_BUILD_OPTIONAL_DRIVERS=OFF -DOGR_BUILD_OPTIONAL_DRIVERS=OFF "${opts[@]}" \
        -DGDAL_USE_TIFF_INTERNAL=ON -DGDAL_USE_GEOTIFF_INTERNAL=ON \
        -DGDAL_USE_PNG_INTERNAL=ON -DGDAL_USE_GIF_INTERNAL=ON \
        -DEMBED_RESOURCE_FILES=ON -DUSE_ONLY_EMBEDDED_RESOURCE_FILES=ON \
        -DCMAKE_C_FLAGS="$flags" -DCMAKE_CXX_FLAGS="$flags"
}

# 1) The project itself, instrumented: SanCov (fuzzer-no-link) + sanitizers + DWARF 3 line tables, so
#    the fuzzed library code is what libFuzzer measures and what ASan/UBSan check.
LIBFLAGS="-O1 $SANITIZER_FLAGS -gdwarf-3 -gline-tables-only -fsanitize=fuzzer-no-link -DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION"
configure "$FB" Release OFF "$LIBFLAGS"
cmake --build "$FB" -j"$MAYHEM_JOBS" --target GDAL

# 2) Harnesses: compile each variant once, link it twice (libFuzzer engine / standalone driver).
mkdir -p "$OBJ"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$OBJ/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$OBJ/standalone_main.o"

INCS=()
for d in port gcore gcore/multidim alg apps ogr ogr/ogrsf_frmts ogr/ogrsf_frmts/sqlite; do INCS+=("-I$SRC/$d"); done
for d in port gcore; do INCS+=("-I$FB/$d"); done
HF="$SRC/fuzzers"

# gdal_algorithm_fuzzer runs input-chosen algorithms (`vsi delete`, --output <path>, /vsistdin/), so it
# also links this: the real filesystem is read-only to GDAL and /vsistdin/ + /vsistdout/ are disabled.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -O1 -std=c++17 "${INCS[@]}" -c "$SRC/mayhem/vsi_contain.cc" -o "$OBJ/vsi_contain.o"

fail=0
build_one() {   # <name> <source.cpp> [-D…]…
    local name="$1" src="$2" extra=() ; shift 2
    [ "$name" != gdal_algorithm_fuzzer ] || extra=("$OBJ/vsi_contain.o")
    $CXX $SANITIZER_FLAGS $DEBUG_FLAGS -O1 -std=c++17 "${INCS[@]}" "$@" -c "$HF/$src" -o "$OBJ/$name.o"
    $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$OBJ/$name.o" "$OBJ/lsan_off.o" "${extra[@]}" \
        -L"$FB" -lgdal -Wl,-rpath,"$FB" -o "$SRC/$name"
    $CXX $SANITIZER_FLAGS $DEBUG_FLAGS "$OBJ/$name.o" "$OBJ/standalone_main.o" "$OBJ/lsan_off.o" "${extra[@]}" \
        -L"$FB" -lgdal -Wl,-rpath,"$FB" -o "$SRC/$name-standalone"
}
queue() {
    while [ "$(jobs -rp | wc -l)" -ge "$MAYHEM_JOBS" ]; do wait -n || fail=1; done
    build_one "$@" &
}

# --- plain harnesses (upstream's own entry points) -------------------------------------------------
for f in filename gdal gdal_translate gdal_vector_translate get_jpeg2000_structure gml_geom_import ogr \
         osr_set_from_user_input spatialite_geom_import wkb_import wkt_import gdal_algorithm; do
    queue "${f}_fuzzer" "${f}_fuzzer.cpp"
done
queue gtiff_mmap gdal_fuzzer.cpp -DREGISTER_FUNC=GDALRegister_GTiff -DGTIFF_USE_MMAP
queue libertiff_fuzzer gdal_fuzzer.cpp -DREGISTER_FUNC=GDALRegister_LIBERTIFF '-DDRIVER_NAME="LIBERTIFF"'
queue gdal_filesystem_fuzzer gdal_fuzzer.cpp -DUSE_FILESYSTEM
queue ogr_filesystem_fuzzer ogr_fuzzer.cpp -DUSE_FILESYSTEM

# --- one OGR driver per harness: <name> <register func> <mem file> <gdal file> -----------------------
ogr() { queue "$1_fuzzer" ogr_fuzzer.cpp "-DREGISTER_FUNC=$2" "-DMEM_FILENAME=\"$3\"" "-DGDAL_FILENAME=\"$4\"" '-DOGR_SKIP="CAD"'; }
ogr dxf RegisterOGRDXF /vsimem/test /vsimem/test
ogr openfilegdb RegisterOGROpenFileGDB /vsimem/test.gdb.tar /vsimem/test.gdb.tar
ogr shape OGRRegisterAll /vsimem/test.tar /vsitar//vsimem/test.tar/my.shp
ogr mitab_mif OGRRegisterAll /vsimem/test.tar /vsitar//vsimem/test.tar/my.mif
ogr mitab_tab OGRRegisterAll /vsimem/test.tar /vsitar//vsimem/test.tar/my.tab
ogr csv RegisterOGRCSV /vsimem/test.csv /vsimem/test.csv
ogr wasp RegisterOGRWAsP /vsimem/test.map /vsimem/test.map
ogr xlsx RegisterOGRXLSX /vsimem/test.xlsx "/vsitar/{/vsimem/test.xlsx}"
ogr ods RegisterOGRODS /vsimem/test.ods "/vsitar/{/vsimem/test.ods}"
ogr lvbag RegisterOGRLVBAG /vsimem/test.xml /vsimem/test.xml
ogr avce00 RegisterOGRAVCE00 /vsimem/test.e00 /vsimem/test.e00
ogr avcbin RegisterOGRAVCBin /vsimem/test.tar "/vsitar/{/vsimem/test.tar}/testavc"
ogr gml RegisterOGRGML /vsimem/test.tar /vsitar//vsimem/test.tar/test.gml
ogr gmlas RegisterOGRGMLAS /vsimem/test.tar "GMLAS:/vsitar//vsimem/test.tar/test.gml"
ogr fgb RegisterOGRFlatGeobuf /vsimem/test.fgb /vsimem/test.fgb
ogr geojson RegisterOGRGeoJSON /vsimem/test.json /vsimem/test.json
ogr gpx RegisterOGRGPX /vsimem/test.gpx /vsimem/test.gpx
ogr kml RegisterOGRKML /vsimem/test.kml /vsimem/test.kml
ogr osm RegisterOGROSM /vsimem/test.osm /vsimem/test.osm
ogr s101 RegisterOGRS101 /vsimem/test.tar /vsitar//vsimem/test.tar/test.000
queue ogr_miramon_fuzzer ogr_fuzzer.cpp -DREGISTER_FUNC=RegisterOGRMiraMon '-DMEM_FILENAME="/vsimem/test.tar"' -DFOR_OGR_MIRAMON
queue cad_fuzzer ogr_fuzzer.cpp -DREGISTER_FUNC=RegisterOGRCAD

# --- one raster driver per harness ------------------------------------------------------------------
gdalfmt() { queue "$1_fuzzer" gdal_fuzzer.cpp "-DREGISTER_FUNC=$2" "-DMEM_FILENAME=\"$3\"" "-DGDAL_FILENAME=\"$4\""; }
gdalfmt gtiff GDALRegister_GTiff /vsimem/test /vsimem/test
gdalfmt hfa GDALRegister_HFA /vsimem/test /vsimem/test
gdalfmt adrg GDALRegister_ADRG /vsimem/test.tar /vsitar//vsimem/test.tar/ABCDEF01.GEN
gdalfmt srp GDALRegister_SRP /vsimem/test.tar /vsitar//vsimem/test.tar/FKUSRP01.IMG
gdalfmt envi GDALRegister_ENVI /vsimem/test.tar /vsitar//vsimem/test.tar/my.dat
gdalfmt ehdr GDALRegister_EHdr /vsimem/test.tar /vsitar//vsimem/test.tar/my.dat
gdalfmt genbin GDALRegister_GenBin /vsimem/test.tar /vsitar//vsimem/test.tar/my.bil
gdalfmt isce GDALRegister_ISCE /vsimem/test.tar /vsitar//vsimem/test.tar/isce.slc
gdalfmt roipac GDALRegister_ROIPAC /vsimem/test.tar /vsitar//vsimem/test.tar/srtm.dem
gdalfmt rraster GDALRegister_RRASTER /vsimem/test.tar /vsitar//vsimem/test.tar/my.grd
gdalfmt aig GDALRegister_AIGrid /vsimem/test.tar /vsitar//vsimem/test.tar/hdr.adf
gdalfmt mrf "GDALRegister_MRF();GDALRegister_GTiff" /vsimem/test.tar /vsitar//vsimem/test.tar/byte.mrf
gdalfmt gdal_vrt GDALAllRegister /vsimem/test.tar /vsitar//vsimem/test.tar/test.vrt
gdalfmt ers GDALRegister_ERS /vsimem/test.tar /vsitar//vsimem/test.tar/test.ers
gdalfmt zarr GDALRegister_Zarr /vsimem/test.tar /vsitar//vsimem/test.tar
gdalfmt dimap "GDALRegister_DIMAP();GDALRegister_GTiff" /vsimem/test.tar /vsitar//vsimem/test.tar
gdalfmt gdal_miramon GDALRegister_MiraMon /vsimem/test.tar /vsitar//vsimem/test.tar/byte_2x3_6_categs_RLEI.rel

while [ "$(jobs -rp | wc -l)" -gt 0 ]; do wait -n || fail=1; done
[ "$fail" -eq 0 ] || { echo "a harness failed to build" >&2; exit 1; }

# 3) The test build: normal flags (no sanitizers), plus the CLI tools mayhem/test.sh drives.
configure "$TB" Release ON "$COVERAGE_FLAGS"
cmake --build "$TB" -j"$MAYHEM_JOBS" --target gdalinfo ogrinfo gdal_translate ogr2ogr gdalsrsinfo gdaltransform
