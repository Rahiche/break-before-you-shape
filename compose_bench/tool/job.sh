#!/bin/sh
# Runs one harness job on the connected emulator: job.sh <job.json> <out.json>.
# The app reads files/job.json from its external files dir and writes files/out.json.
set -e
PATH=$HOME/Library/Android/sdk/platform-tools:$PATH
PKG=dev.breakfirst.compose
DIR=/sdcard/Android/data/$PKG/files
adb shell mkdir -p $DIR
adb shell rm -f $DIR/out.json
adb push "$1" $DIR/job.json > /dev/null
adb shell am force-stop $PKG
adb shell am start -W -n $PKG/.MainActivity > /dev/null
until adb shell test -f $DIR/out.json; do sleep 1; done
adb pull $DIR/out.json "$2" > /dev/null
grep -q '"error"' "$2" && { cat "$2"; exit 1; } || true
