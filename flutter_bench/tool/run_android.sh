#!/bin/sh
# Runs the bench app on the connected Android device or emulator and writes its
# JSON result. usage: tool/run_android.sh <apk> <out.json> [timeout-seconds]
set -e
apk="$1"; out="$2"; limit="${3:-3600}"
here="$(dirname "$0")"
adb install -r "$apk" >/dev/null
adb shell am force-stop dev.breakfirst.bf_bench
adb logcat -c
adb shell am start -n dev.breakfirst.bf_bench/.MainActivity >/dev/null
start=$(date +%s)
until adb logcat -d -s flutter | grep -q BFDONE; do
  [ $(( $(date +%s) - start )) -gt "$limit" ] && { echo "timed out"; adb logcat -d -s flutter | tail -20; exit 1; }
  sleep 5
done
adb logcat -d -s flutter > "$out.logcat"
python3 "$here/join_chunks.py" "$out.logcat" "$out"
