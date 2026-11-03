#!/bin/sh
# Right-to-left check for one Hebrew font: certifies it four ways (right-to-left
# and left-to-right, with and without ligatures), then runs test/rtl_test.dart on
# the Hebrew UI corpus. usage: tool/rtl_check.sh <font file> <out.json> [python]
set -e
cd "$(dirname "$0")/.."
font="$1"; out="$2"; py="${3:-python3}"
tmp="$(mktemp -d)"
freq=$(ls ../corpus.txt ../corpora/*.txt 2>/dev/null | tr '\n' ':' | sed 's/:$//')
CERTIFY_SCRIPTS=latin+hebrew CERTIFY_DIRECTION=rtl CERTIFY_FREQ_FILES=../corpora/ui_he.txt "$py" ../certify.py "$font" "$tmp/rtl.cert" 4 | tail -1
CERTIFY_SCRIPTS=latin+hebrew CERTIFY_DIRECTION=rtl CERTIFY_FEATURES_OFF=liga,clig,calt CERTIFY_FREQ_FILES=../corpora/ui_he.txt \
  "$py" ../certify.py "$font" "$tmp/rtl.nolig" 4 | tail -1
CERTIFY_SCRIPTS=latin+greek+cyrillic CERTIFY_FREQ_FILES="$freq" "$py" ../certify.py "$font" "$tmp/ltr.cert" 4 | tail -1
CERTIFY_SCRIPTS=latin+greek+cyrillic CERTIFY_FEATURES_OFF=liga,clig,calt CERTIFY_FREQ_FILES="$freq" \
  "$py" ../certify.py "$font" "$tmp/ltr.nolig" 4 | tail -1
RTL_FONT="$font" RTL_CERT="$tmp/rtl.cert" RTL_NOLIG="$tmp/rtl.nolig" RTL_LTR_CERT="$tmp/ltr.cert" RTL_LTR_NOLIG="$tmp/ltr.nolig" \
  RTL_CORPUS=../corpora/ui_he.txt RTL_OUT="$out" flutter test test/rtl_test.dart
