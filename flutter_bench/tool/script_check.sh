#!/bin/sh
# CJK check for one font face: extracts it (collections hold several), certifies
# it with and without ligatures, then runs test/script_test.dart on the Japanese,
# Chinese and Korean UI corpora. usage: tool/script_check.sh <font> <face> <out.json> [python]
set -e
cd "$(dirname "$0")/.."
font="$1"; face="$2"; out="$3"; py="${4:-python3}"
tmp="$(mktemp -d)"
"$py" -c "
import sys
from fontTools.ttLib import TTCollection, TTFont
path, i, dst = sys.argv[1], int(sys.argv[2]), sys.argv[3]
(TTCollection(path)[i] if path.lower().endswith(('.ttc', '.otc')) else TTFont(path)).save(dst)" "$font" "$face" "$tmp/face.otf"
CERTIFY_SCRIPTS=latin+cjk "$py" ../certify.py "$tmp/face.otf" "$tmp/cjk.cert" 4 | tail -1
CERTIFY_SCRIPTS=latin+cjk CERTIFY_FEATURES_OFF=liga,clig,calt "$py" ../certify.py "$tmp/face.otf" "$tmp/cjk.nolig" 4 | tail -1
SCRIPT_FONT="$tmp/face.otf" SCRIPT_CERT="$tmp/cjk.cert" SCRIPT_NOLIG="$tmp/cjk.nolig" \
  SCRIPT_CORPUS=../corpora/ui_ja.txt:../corpora/ui_zh_CN.txt:../corpora/ui_ko.txt SCRIPT_OUT="$out" flutter test test/script_test.dart
