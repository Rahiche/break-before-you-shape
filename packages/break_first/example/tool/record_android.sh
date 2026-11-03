#!/bin/sh
# Records the autoplay tour on a connected Android device or emulator.
# usage: tool/record_android.sh <apk> <out-dir>   (build the apk with --dart-define=AUTOPLAY=true)
# Writes <out-dir>/demo.mp4 and <out-dir>/demo_log.txt (the numbers the app measured).
set -e
apk="$1"; out="$2"; seconds="${3:-45}"
mkdir -p "$out"
adb install -r "$apk" >/dev/null
adb shell am force-stop dev.breakfirst.break_first_example
adb logcat -c
adb shell rm -f /sdcard/demo.mp4
adb shell screenrecord --time-limit "$seconds" --bit-rate 8000000 /sdcard/demo.mp4 &
rec=$!
sleep 1
adb shell am start -W -n dev.breakfirst.break_first_example/.MainActivity >/dev/null
wait $rec
sleep 2 # let screenrecord finish writing the file
adb pull /sdcard/demo.mp4 "$out/demo.mp4" >/dev/null
adb logcat -d -s flutter | grep "DEMO " > "$out/demo_log.txt" || true
cat "$out/demo_log.txt"
