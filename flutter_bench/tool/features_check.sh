#!/bin/sh
# Font features check for the bundled Roboto: certifies it once per feature set
# (with and without ligatures), then runs test/features_test.dart.
# usage: tool/features_check.sh <out.json> [python] [sets]
# Sets are space-separated; '+' joins features, a leading '-' turns one off.
set -e
cd "$(dirname "$0")/.."
out="$1"; py="${2:-python3}"; sets="${3:-tnum smcp onum+ss01 dlig -liga frac c2sc+smcp}"
tmp="$(mktemp -d)"
freq=$(ls ../corpus.txt ../corpora/*.txt 2>/dev/null | grep -v -e ui_he -e ui_ar -e ui_ja -e ui_zh -e ui_ko | tr '\n' ':' | sed 's/:$//')
for set in $sets; do
  on=$(echo "$set" | tr '+' '\n' | grep -v '^-' | tr '\n' ',' | sed 's/,$//')
  off=$(echo "$set" | tr '+' '\n' | grep '^-' | sed 's/^-//' | tr '\n' ',' | sed 's/,$//')
  CERTIFY_SCRIPTS=latin+greek+cyrillic CERTIFY_FREQ_FILES="$freq" CERTIFY_FEATURES_ON="$on" CERTIFY_FEATURES_OFF="$off" \
    "$py" ../certify.py assets/Roboto-Regular.ttf "$tmp/$set.cert" 4 | tail -1
  CERTIFY_SCRIPTS=latin+greek+cyrillic CERTIFY_FREQ_FILES="$freq" CERTIFY_FEATURES_ON="$on" \
    CERTIFY_FEATURES_OFF="liga,clig,calt${off:+,$off}" "$py" ../certify.py assets/Roboto-Regular.ttf "$tmp/$set.nolig" 4 | tail -1
done
FEATURE_DIR="$tmp" FEATURE_OUT="$out" flutter test test/features_test.dart
