#!/bin/sh
# Right-to-left check for one font: certifies it four ways (right-to-left and
# left-to-right, with and without ligatures), then runs test/rtl_test.dart on the
# UI corpus of RTL_SCRIPT (hebrew, the default, or arabic).
# usage: [RTL_SCRIPT=arabic] [RTL_TEXTS=file] tool/rtl_check.sh <font file> <out.json> [python]
# RTL_TEXTS: the texts to check instead of the UI corpus (e.g. with vowel marks).
set -e
cd "$(dirname "$0")/.."
font="$1"; out="$2"; py="${3:-python3}"
tmp="$(mktemp -d)"
script="${RTL_SCRIPT:-hebrew}"
case "$script" in hebrew) corpus=../corpora/ui_he.txt ;; arabic) corpus=../corpora/ui_ar.txt ;; *) echo "RTL_SCRIPT: hebrew or arabic" >&2; exit 2 ;; esac
freq=$(ls ../corpus.txt ../corpora/*.txt 2>/dev/null | tr '\n' ':' | sed 's/:$//')
CERTIFY_SCRIPTS=latin+$script CERTIFY_DIRECTION=rtl CERTIFY_FREQ_FILES=$corpus "$py" ../certify.py "$font" "$tmp/rtl.cert" 4 | tail -1
CERTIFY_SCRIPTS=latin+$script CERTIFY_DIRECTION=rtl CERTIFY_FEATURES_OFF=liga,clig,calt CERTIFY_FREQ_FILES=$corpus \
  "$py" ../certify.py "$font" "$tmp/rtl.nolig" 4 | tail -1
CERTIFY_SCRIPTS=latin+greek+cyrillic CERTIFY_FREQ_FILES="$freq" "$py" ../certify.py "$font" "$tmp/ltr.cert" 4 | tail -1
CERTIFY_SCRIPTS=latin+greek+cyrillic CERTIFY_FEATURES_OFF=liga,clig,calt CERTIFY_FREQ_FILES="$freq" \
  "$py" ../certify.py "$font" "$tmp/ltr.nolig" 4 | tail -1
RTL_FONT="$font" RTL_CERT="$tmp/rtl.cert" RTL_NOLIG="$tmp/rtl.nolig" RTL_LTR_CERT="$tmp/ltr.cert" RTL_LTR_NOLIG="$tmp/ltr.nolig" \
  RTL_CORPUS="${RTL_TEXTS:-$corpus}" RTL_OUT="$out" flutter test test/rtl_test.dart
