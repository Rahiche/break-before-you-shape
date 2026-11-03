#!/bin/sh
# Regenerates the text corpora the app's validation uses, from files on this Mac
# (Python standard-library docstrings, macOS man pages, licence texts, macOS
# localized UI strings), and copies them into assets/. Run from flutter_bench/.
set -e
cd "$(dirname "$0")/.."
python3 ../make_corpus.py ../corpus.txt
python3 ../make_corpora.py ../corpora
cp ../corpus.txt assets/en_docs.txt
cp ../corpora/*.txt assets/
echo "corpora copied into assets/"
