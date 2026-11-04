#!/bin/sh
# Every local check against Flutter's own layout, on macOS (system fonts are read
# in place, never copied into the repository). Results go to results/.
# Needs the corpora (tool/prepare_assets.sh, ../make_corpora.py ../corpora sea, then
# ../make_test_texts.py) and
# fontTools. usage: tool/validate_all.sh [python]
set -e
cd "$(dirname "$0")/.."
py="${1:-python3}"
tmp="$(mktemp -d)"
lgc=$(ls ../corpus.txt ../corpora/*.txt | grep -v -e ui_he -e ui_ar -e ui_ja -e ui_zh -e ui_ko -e ui_hi -e ui_bn -e ui_ta \
  -e _nfd -e _vowelled -e _pointed | tr '\n' ':' | sed 's/:$//')
sup=/System/Library/Fonts/Supplemental
lgc_cert() { # font, name: certificates for Latin, Greek and Cyrillic, with and without ligatures
  CERTIFY_SCRIPTS=latin+greek+cyrillic CERTIFY_FREQ_FILES="$lgc" "$py" ../certify.py "$1" "$tmp/$2.cert" 4 | tail -1
  CERTIFY_SCRIPTS=latin+greek+cyrillic CERTIFY_FREQ_FILES="$lgc" CERTIFY_FEATURES_OFF=liga,clig,calt \
    "$py" ../certify.py "$1" "$tmp/$2.nolig" 4 | tail -1
}
lgc_cert "$sup/Arial.ttf" arial
lgc_cert "$sup/Times New Roman.ttf" tnr
lgc_cert "$sup/Georgia.ttf" georgia
"$py" -c "
from fontTools.ttLib import TTCollection
TTCollection('/System/Library/Fonts/Hiragino Sans GB.ttc')[0].save('$tmp/hiragino.otf')
TTCollection('/System/Library/Fonts/AppleSDGothicNeo.ttc')[0].save('$tmp/sdgothic.otf')"
for f in hiragino sdgothic; do
  CERTIFY_SCRIPTS=latin+cjk "$py" ../certify.py "$tmp/$f.otf" "$tmp/$f.cert" 4 | tail -1
done

echo "== style options, struts and hard breaks (flutter_tester)"
BF_MODE=styles BF_SAMPLE=600 flutter test test/validate_host_test.dart
echo "== font features"
tool/features_check.sh "$PWD/results/features_roboto.json" "$py"
echo "== rich text"
RICH_FONTS="$sup/Arial.ttf:$tmp/arial.cert:$tmp/arial.nolig;$sup/Times New Roman.ttf:$tmp/tnr.cert:$tmp/tnr.nolig;$sup/Georgia.ttf:$tmp/georgia.cert:$tmp/georgia.nolig" \
  RICH_SAMPLE=400 RICH_OUT="$PWD/results/rich.json" flutter test test/rich_test.dart
echo "== font fallback (bundled CJK fonts)"
FALLBACK_FONTS="$tmp/hiragino.otf:$tmp/hiragino.cert;$tmp/sdgothic.otf:$tmp/sdgothic.cert" \
  FALLBACK_OUT="$PWD/results/fallback_cjk.json" flutter test test/fallback_test.dart
echo "== combining marks (NFD text)"
MARKS_FONTS="$PWD/assets/Roboto-Regular.ttf:$PWD/assets/roboto.cert:$PWD/assets/roboto.nolig.cert;$sup/Arial.ttf:$tmp/arial.cert:$tmp/arial.nolig" \
  MARKS_CORPUS=$(ls ../corpora/ui_*_nfd.txt | tr '\n' ':' | sed 's/:$//') MARKS_OUT="$PWD/results/marks_nfd.json" \
  flutter test test/marks_test.dart
echo "== emoji and Brahmic scripts from the device's fallback fonts"
EMOJI_OUT="$PWD/results/emoji_device.json" flutter test test/emoji_test.dart
INDIC_CORPUS=../corpora/ui_hi.txt:../corpora/ui_bn.txt:../corpora/ui_ta.txt INDIC_OUT="$PWD/results/indic_device.json" \
  flutter test test/indic_test.dart
echo "== Thai, Lao, Khmer and Burmese (ICU's dictionaries), from the device's fonts"
DICT_OUT="$PWD/results/dictionary_break.json" flutter test test/dictionary_break_test.dart
SEA_CORPUS=$(ls ../corpora/ui_th.txt ../corpora/names_*.txt ../corpora/vocab_*.txt | tr '\n' ':' | sed 's/:$//') \
  SEA_OUT="$PWD/results/dictionary_scripts.json" flutter test test/dictionary_scripts_test.dart
echo "== right to left: Hebrew and Arabic, with spacing and mixed direction; points and harakat"
for f in Arial "Times New Roman"; do
  n=$(echo "$f" | tr 'A-Z ' 'a-z_')
  RTL_SAMPLE=1500 tool/rtl_check.sh "$sup/$f.ttf" "$PWD/results/rtl_$n.json" "$py"
  RTL_SAMPLE=1500 RTL_SCRIPT=arabic tool/rtl_check.sh "$sup/$f.ttf" "$PWD/results/rtl_arabic_$n.json" "$py"
  RTL_SAMPLE=1000 RTL_TEXTS=../corpora/ui_he_pointed.txt tool/rtl_check.sh "$sup/$f.ttf" "$PWD/results/rtl_pointed_$n.json" "$py"
  RTL_SAMPLE=1000 RTL_SCRIPT=arabic RTL_TEXTS=../corpora/ui_ar_vowelled.txt \
    tool/rtl_check.sh "$sup/$f.ttf" "$PWD/results/rtl_vowelled_$n.json" "$py"
done
echo "== Japanese, Chinese and Korean"
tool/script_check.sh "/System/Library/Fonts/Hiragino Sans GB.ttc" 0 "$PWD/results/cjk_hiragino_sans_gb.json" "$py"
tool/script_check.sh /System/Library/Fonts/AppleSDGothicNeo.ttc 0 "$PWD/results/cjk_apple_sd_gothic_neo.json" "$py"
echo "all checks done"
