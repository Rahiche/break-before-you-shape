"""Altered copies of the bundled Roboto, for test/failsafe_test.dart: what the
shipped sidecar does when the font it meets is not the one it was built from.

  same.ttf    a byte-for-byte copy (control)
  wider.ttf   every advance 1% wider (another version or weight of the font)
  eacute.ttf  only é 60 units wider (a small fix in a font update; é is in no
              canary string)

usage: failsafe_fonts.py out_dir
"""
import os
import shutil
import sys

from fontTools.ttLib import TTFont

out = sys.argv[1]
os.makedirs(out, exist_ok=True)
src = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "Roboto-Regular.ttf")

shutil.copyfile(src, os.path.join(out, "same.ttf"))

f = TTFont(src)
for g, (adv, lsb) in list(f["hmtx"].metrics.items()):
    f["hmtx"].metrics[g] = (round(adv * 1.01), lsb)
f.save(os.path.join(out, "wider.ttf"))

f = TTFont(src)
g = f.getBestCmap()[0xE9]
adv, lsb = f["hmtx"].metrics[g]
f["hmtx"].metrics[g] = (adv + 60, lsb)
f.save(os.path.join(out, "eacute.ttf"))
print("fonts in", out)
