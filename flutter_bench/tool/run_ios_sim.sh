#!/bin/sh
# Runs the bench app (a simulator build) on an iOS simulator and copies its JSON
# result out of the app's container. usage: tool/run_ios_sim.sh <Runner.app> <out.json> [udid]
set -e
app="$1"; out="$2"; udid="$3"
bundle=dev.breakfirst.bfBench
if [ -z "$udid" ]; then
  udid=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devs = [d for rt, ds in json.load(sys.stdin)["devices"].items() if "iOS" in rt for d in ds if "iPhone" in d["name"]]
booted = [d for d in devs if d["state"] == "Booted"]
print((booted or devs)[0]["udid"])')
fi
xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b >/dev/null
xcrun simctl install "$udid" "$app"
xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
data=$(xcrun simctl get_app_container "$udid" "$bundle" data)
rm -f "$data/tmp/bf_results.json"
xcrun simctl launch "$udid" "$bundle" >/dev/null
start=$(date +%s)
# The app writes the file when it is done, then exits.
until [ -s "$data/tmp/bf_results.json" ] && ! xcrun simctl spawn "$udid" launchctl list 2>/dev/null | grep -q "$bundle"; do
  [ $(( $(date +%s) - start )) -gt 3600 ] && { echo "timed out"; exit 1; }
  sleep 5
done
cp "$data/tmp/bf_results.json" "$out"
echo "wrote $out ($(xcrun simctl list devices | grep "$udid" | sed 's/^ *//'))"
