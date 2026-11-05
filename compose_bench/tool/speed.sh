#!/bin/sh
# Compose against break-first on the connected emulator, for the heights of a
# chat list: CACHE_DIR=<dir> tool/speed.sh [size px] [width px].
set -e
PATH=$HOME/Library/Android/sdk/platform-tools:$PATH
cd "$(dirname "$0")/.."
SIZE=${1:-42.0}; WIDTH=${2:-735}; CACHE=${CACHE_DIR:?set CACHE_DIR}
# Compose's widths at this size (compose_check.dart keeps them in CACHE_DIR).
[ -f $CACHE/widths_$SIZE.json ] || SIZES=$SIZE CACHE_DIR=$CACHE dart run tool/compose_check.dart $CACHE/check_$SIZE.json 20
mkdir -p speed_app/assets
cp ../flutter_bench/assets/roboto.cert speed_app/assets/
cp $CACHE/widths_$SIZE.json speed_app/assets/widths.json
for c in ui_en ui_de ui_fr ui_ru ui_uk ui_el; do cp ../flutter_bench/assets/$c.txt speed_app/assets/; done
(cd speed_app && flutter build apk --release --dart-define=SIZE=$SIZE --dart-define=WIDTH=$WIDTH)
adb install -r speed_app/build/app/outputs/flutter-apk/app-release.apk > /dev/null
# Both apps compiled ahead of time (as with a baseline profile), and the
# system's background compilation done, before anything is timed.
adb shell cmd package compile -m speed -f dev.breakfirst.compose > /dev/null
adb shell cmd package compile -m speed -f dev.breakfirst.bf_speed > /dev/null
adb shell cmd package bg-dexopt-job > /dev/null || true
adb logcat -c
adb shell am start -n dev.breakfirst.bf_speed/.MainActivity > /dev/null
until adb logcat -d -s flutter | grep -q BFSPEED; do sleep 2; done
adb logcat -d -s flutter | grep BFSPEED | sed 's/.*BFSPEED //' > $CACHE/bf_speed.json
adb shell am force-stop dev.breakfirst.bf_speed
dart run tool/compose_speed.dart $CACHE $SIZE $WIDTH results/compose_speed.json
