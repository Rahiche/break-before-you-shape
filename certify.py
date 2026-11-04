"""Static certificate for break-first widths.

Reads a font's layout tables (GSUB/GPOS/GDEF, morx, kern, kerx) and sorts every
repertoire character into one of four classes:

  S  safe       no substitution can change or consume its glyph, and it resets
                every AAT state machine without side effects
  P  primer     can start a substitution (first component of a ligature that can
                form, or an AAT transition with an effect from the start state)
  K  passive    can be consumed by a substitution a primer started, but does
                nothing on its own
  U  unsafe     anything else

Claim checked downstream by bfl.c: for any line with no U character, in which
every maximal P/K run containing a P has at most m characters, the shaped width
equals the distilled model's width. The proof needs three properties, which this
script establishes from the tables:

  1. substitution is the identity on S glyphs;
  2. the output glyphs of a P/K run depend only on the run. OpenType: the only
     substitutions that can fire on P/K glyphs are ligatures, and those consume
     P/K glyphs only. AAT: every morx subtable (rearrangement, contextual,
     ligature, insertion; forward or reversed) and every kerx / kern format 1
     state machine is emulated as HarfBuzz 15 runs it. From every reachable
     state an S class changes nothing and returns to a start state (directly or
     by a DontAdvance reset); K classes are quiet from the start states; end of
     text after an S or K glyph changes nothing; and every P/K run of <= m
     glyphs, run on its own from each start state with all machine state stored
     before it (mark, rearrangement bounds, ligature and kerning stacks) marked
     stale, never touches that state and yields the same glyphs and kerning
     whatever precedes or follows it;
  3. positioning on every glyph that can occur is pair-additive: SinglePos, or
     PairPos with ValueFormat2 == 0 (otherwise the next pair is skipped), or
     kern formats 0/2/3 and kerx formats 0/2/6 (hb_kern_machine_t), or confined
     to islands (kerx / kern format 1, checked as in 2). kerx format 4 and
     cross-stream kerning only move glyph offsets. Cursive, mark and contextual
     positioning are blocked.

A contextual rule (GSUB 5/6/8, GPOS 7/8) can fire only if every position can
match some glyph that can occur; for each live rule, the characters of its
cheapest position (weighted by English letter frequency) are made unsafe, which
makes the rule unmatchable on any certified line.

The analysis over-approximates what HarfBuzz enables: all scripts and language
systems, every feature HarfBuzz may turn on for horizontal Latin text, and all
feature variations. AAT chains are analysed under their default flags (what
HarfBuzz 15 runs without user features) and under the flags its default
ligature / contextual-alternate selectors would give; the proof must hold for
both. GSUB, GPOS, morx, kern and kerx are all analysed even where HarfBuzz
applies only some of them. Over-approximating only adds U.

When an AAT machine is context-dependent on common letters (smart quotes,
spacing-accent composition), the characters it acts on may be made U instead,
if that raises the estimated share of certified lines.

bfl.c then checks the model exhaustively on every island up to length m in every
S context, and checks that no model term spans an island with S on both sides.

usage: certify.py font[:index] out.cert [m] [hb|all]
"""
import itertools
import random
import os
import sys
import unicodedata

from fontTools.ttLib import TTFont

RANGES = [(0x20, 0x7E), (0xA0, 0x24F), (0x2B0, 0x2FF), (0x300, 0x36F), (0x2010, 0x2027), (0x2030, 0x205E),
          (0x20AC, 0x20AC), (0x2122, 0x2122)]
if "greek" in os.environ.get("CERTIFY_SCRIPTS", ""):
    RANGES.append((0x370, 0x3FF))
if "cyrillic" in os.environ.get("CERTIFY_SCRIPTS", ""):
    RANGES.append((0x400, 0x4FF))
if "hebrew" in os.environ.get("CERTIFY_SCRIPTS", ""):
    RANGES.append((0x590, 0x5FF))
if "arabic" in os.environ.get("CERTIFY_SCRIPTS", ""):
    RANGES.append((0x600, 0x6FF))
if "cjk" in os.environ.get("CERTIFY_SCRIPTS", ""):
    # CJK punctuation, kana, Han (with extension A and compatibility), Hangul
    # syllables, fullwidth forms.
    RANGES += [(0x3000, 0x30FF), (0x3400, 0x4DBF), (0x4E00, 0x9FFF), (0xAC00, 0xD7A3), (0xF900, 0xFAFF),
               (0xFF00, 0xFFEF)]
# OpenType scripts HarfBuzz shapes these characters with: the lookups of all of them
# count (Common characters take the script of the run they are in).
SCRIPT_TAGS = ["latn"] + [tag for name, tags in (("greek", ["grek"]), ("cyrillic", ["cyrl"]), ("hebrew", ["hebr"]),
                                                  ("arabic", ["arab"]), ("cjk", ["hani", "kana", "hang"]))
                          if name in os.environ.get("CERTIFY_SCRIPTS", "") for tag in tags]
# Every feature HarfBuzz turns on for all of a horizontal Latin buffer. frac/numr/dnom
# are applied only around U+2044 FRACTION SLASH, which is classified U below.
FEATURES = {"rvrn", "ltra", "ltrm", "rand", "ccmp", "locl", "rlig", "calt", "clig", "liga", "rclt", "abvm",
            "blwm", "mark", "mkmk", "curs", "dist", "kern", "trak"}
# Features the engine switches off, e.g. CERTIFY_FEATURES_OFF=liga,clig,calt for
# Flutter text with letter spacing (measured: it disables ligatures).
FEATURES -= set(f for f in os.environ.get("CERTIFY_FEATURES_OFF", "").split(",") if f)
# Features the app turns on for the whole text (Flutter's fontFeatures), e.g.
# CERTIFY_FEATURES_ON=tnum,smcp. HarfBuzz applies them to every character.
FEATURES_ON = set(f for f in os.environ.get("CERTIFY_FEATURES_ON", "").split(",") if f)
FEATURES |= FEATURES_ON
# Right-to-left paragraphs (CERTIFY_DIRECTION=rtl): HarfBuzz applies rtla/rtlm instead
# of ltra/ltrm.
if os.environ.get("CERTIFY_DIRECTION") == "rtl":
    FEATURES = (FEATURES - {"ltra", "ltrm"}) | {"rtla", "rtlm"}
# AAT selectors HarfBuzz switches on for its default features (rlig, liga, clig, calt):
# (feature type, selector). In "all" mode, every selector of these two types.
AAT_DEFAULT_SELECTORS = {(1, 0), (1, 2), (1, 18), (36, 0)}
# The same switch for AAT: HarfBuzz maps rlig, liga, clig, calt to these selectors.
AAT_DEFAULT_SELECTORS -= {sel for tag, sel in {"rlig": (1, 0), "liga": (1, 2), "clig": (1, 18), "calt": (36, 0)}.items()
                          if tag not in FEATURES}
AAT_FEATURE_TYPES = {1, 36}
EOT, DELETED = 0, 2          # AAT classes
LETTER_FREQ = dict(zip("etaoinshrdlcumwfgypbvkjxqz",
                       [12.7, 9.1, 8.2, 7.5, 7.0, 6.7, 6.3, 6.1, 6.0, 4.3, 4.0, 2.8, 2.8, 2.4, 2.4, 2.2, 2.0, 2.0,
                        1.9, 1.5, 1.0, 0.8, 0.15, 0.15, 0.1, 0.07]))


# Optional: weight characters by their frequency in the target text instead of
# English letter frequencies (CERTIFY_FREQ_FILES=a.txt:b.txt).
CORPUS_FREQ = {}
if os.environ.get("CERTIFY_FREQ_FILES"):
    for p in os.environ["CERTIFY_FREQ_FILES"].split(":"):
        for ch in open(p, encoding="utf-8").read():
            CORPUS_FREQ[ord(ch)] = CORPUS_FREQ.get(ord(ch), 0) + 1
    _total = sum(CORPUS_FREQ.values())
    CORPUS_FREQ = {k: 100.0 * v / _total for k, v in CORPUS_FREQ.items()}


def freq(cp):
    if cp >= 0x100000:
        cp = (cp - 0x100000) // 4
    if CORPUS_FREQ:
        return CORPUS_FREQ.get(cp, 0.0) + 1e-6
    ch = chr(cp)
    if ch == " ":
        return 18.0
    if ch.lower() in LETTER_FREQ and ch.isascii():
        return LETTER_FREQ[ch.lower()] * (1.0 if ch.islower() else 0.15)
    if ch.isdigit():
        return 0.5
    if ch in ".,;:()'\"-_/":
        return 1.0
    return 0.01


path, index = sys.argv[1], 0
if ":" in path and path.rsplit(":", 1)[1].isdigit():
    path, index = path.rsplit(":", 1)
    index = int(index)
out_path = sys.argv[2]
M_ISLAND = int(sys.argv[3]) if len(sys.argv) > 3 else 4
SELECT = sys.argv[4] if len(sys.argv) > 4 else "hb"  # "hb" (what HarfBuzz applies) or "all"

font = TTFont(path, fontNumber=index)
gid = {g: i for i, g in enumerate(font.getGlyphOrder())}
cmap = font.getBestCmap()
chars = [cp for lo, hi in RANGES for cp in range(lo, hi + 1) if cp in cmap and cmap[cp] != ".notdef"]
nominal = {cp: cmap[cp] for cp in chars}
gdef_class = {}
if "GDEF" in font and font["GDEF"].table.GlyphClassDef:
    gdef_class = font["GDEF"].table.GlyphClassDef.classDefs

unsafe = {}  # cp -> first reason

# Arabic joining forms. HarfBuzz picks each letter's form (isolated, initial,
# medial, final) from the Unicode joining types of its neighbours and applies the
# font's isol/init/medi/fina feature to it. Each (letter, form) becomes a virtual
# character VBASE + 4 * cp + form whose glyph is that feature's substitute; the
# letter itself is not used directly. Forms whose feature is not a plain single
# substitution, or letters an earlier lookup (ccmp, locl) touches, are unsafe.
VBASE = 0x100000
FORMS = ("isol", "init", "medi", "fina")
# Joining types: D (dual-joining) has all four forms, R (right-joining) isol and fina.
ARABIC_R = set(range(0x622, 0x626)) | {0x627, 0x629} | set(range(0x62F, 0x633)) | {0x648} | set(range(0x671, 0x674)) | \
    set(range(0x675, 0x678)) | set(range(0x688, 0x69A)) | {0x6C0} | set(range(0x6C3, 0x6CC)) | {0x6CD, 0x6CF, 0x6D2, 0x6D3,
                                                                                                0x6D5, 0x6EE, 0x6EF}
ARABIC_D = ({0x626, 0x628} | set(range(0x62A, 0x62F)) | set(range(0x633, 0x640)) | set(range(0x641, 0x648)) | {0x649, 0x64A,
            0x66E, 0x66F, 0x678} | set(range(0x679, 0x688)) | set(range(0x69A, 0x6C0)) | {0x6C1, 0x6C2, 0x6CC, 0x6CE, 0x6D0,
                                                                                         0x6D1} | set(range(0x6FA, 0x6FD))
            | {0x6FF, 0x640})  # tatweel is join-causing: HarfBuzz joins it like a dual-joining letter
arabic_forms = {}  # virtual cp -> (letter, form index)


def make_unsafe(cps, reason):
    for cp in cps:
        unsafe.setdefault(cp, reason)


make_unsafe([cp for cp in chars if cp == 0x2044], "fraction slash triggers frac/numr/dnom")
# Combining marks (class M): non-spacing marks the font classes as marks in GDEF.
# HarfBuzz composes a base and a following mark into the precomposed character the
# font has (normalization, before any lookup; COMPOSE lists the font's), and zeroes
# the advance of every GDEF mark after positioning: a mark left uncomposed takes
# no width. Kerning either skips it or stops at it, by lookup flags (mark_mode).
MARKS = {cp for cp in chars if gdef_class.get(nominal[cp]) == 3 and unicodedata.category(chr(cp)) in ("Mn", "Me")}
make_unsafe([cp for cp in chars if gdef_class.get(nominal[cp]) == 3 and cp not in MARKS], "GDEF mark")
# Combining diacritics the font does not class as marks (no GDEF, as in most AAT fonts):
# not modelled, as before this range was certified at all.
make_unsafe([cp for cp in chars if 0x300 <= cp <= 0x36F and cp not in MARKS], "combining mark without a GDEF class")
# Hebrew: without GPOS mark positioning HarfBuzz composes points into presentation
# forms instead (not modelled).
if "hebrew" in os.environ.get("CERTIFY_SCRIPTS", "") and not (
        "GPOS" in font and font["GPOS"].table.FeatureList and
        any(fr.FeatureTag == "mark" for fr in font["GPOS"].table.FeatureList.FeatureRecord)):
    make_unsafe([cp for cp in MARKS if 0x591 <= cp <= 0x5C7], "Hebrew points without GPOS mark")
# Marks in an AAT font are not modelled: left out from the start, so the morx analysis
# never sees them (their ligatures with letters would make the letters islands).
if "morx" in font or "kerx" in font:
    make_unsafe(sorted(MARKS), "mark in an AAT font")
MARK_GLYPHS = {nominal[cp] for cp in MARKS}
COMPOSE = []
for _c in sorted(cmap):
    _d = unicodedata.decomposition(chr(_c))
    if _d and not _d.startswith("<"):
        _parts = [int(x, 16) for x in _d.split()]
        if len(_parts) == 2 and _parts[1] in MARKS and _parts[0] in cmap and \
                unicodedata.normalize("NFC", chr(_parts[0]) + chr(_parts[1])) == chr(_c):
            COMPOSE.append((_parts[0], _parts[1], _c))


def form_substitutes():
    """For each joining form, the glyph map of its feature in script arab (single
    substitutions applied in lookup order), and the glyphs a lookup of another type
    in that feature covers (unsafe)."""
    maps, blocked = {f: {} for f in FORMS}, set()
    if "GSUB" not in font or not font["GSUB"].table.ScriptList:
        return maps, blocked
    t = font["GSUB"].table
    scripts = {sr.ScriptTag: sr.Script for sr in t.ScriptList.ScriptRecord}
    sc = scripts.get("arab")
    if not sc or not sc.DefaultLangSys:
        return maps, blocked
    feats = t.FeatureList.FeatureRecord
    for i in sc.DefaultLangSys.FeatureIndex:
        tag = feats[i].FeatureTag
        if tag not in FORMS:
            continue
        for li in sorted(feats[i].Feature.LookupListIndex):
            lk = t.LookupList.Lookup[li]
            for typ, st in subtables(lk, 7):
                if typ == 1:
                    for g, r in st.mapping.items():
                        maps[tag].setdefault(g, r)
                else:
                    blocked.update(getattr(getattr(st, "Coverage", None), "glyphs", []) or [])
    return maps, blocked


def active_lookups(tag, script_tags=None):
    """Lookups HarfBuzz applies for the scripts in SCRIPT_TAGS (or [script_tags]; each
    falling back to DFLT, dflt, then latn, as HarfBuzz does; "DFLT" is a run of Common
    characters alone), language en, default variation coordinates. With SELECT ==
    "all" and no [script_tags], every script, language system and feature variation
    instead (a strict over-approximation)."""
    select = "one" if script_tags else SELECT
    t = font[tag].table
    if not t.FeatureList:
        return t, []
    feats = list(t.FeatureList.FeatureRecord)
    tables = {i: fr.Feature for i, fr in enumerate(feats)}
    fv = getattr(t, "FeatureVariations", None)
    if fv:
        def holds(rec):
            return all(c.FilterRangeMinValue <= 0 <= c.FilterRangeMaxValue for c in rec.ConditionSet.ConditionTable)
        recs = fv.FeatureVariationRecord if select == "all" else [r for r in fv.FeatureVariationRecord if holds(r)][:1]
        for rec in recs:
            for sub in rec.FeatureTableSubstitution.SubstitutionRecord:
                if select == "all":
                    tables.setdefault(("alt", sub.FeatureIndex, id(sub)), sub.Feature)
                    feats.append(type("F", (), {"FeatureTag": feats[sub.FeatureIndex].FeatureTag})())
                    tables[len(feats) - 1] = sub.Feature
                else:
                    tables[sub.FeatureIndex] = sub.Feature
    langsys = []
    scripts = {sr.ScriptTag: sr.Script for sr in (t.ScriptList.ScriptRecord if t.ScriptList else [])}
    if select == "all":
        for sc in scripts.values():
            langsys += [sc.DefaultLangSys] + [r.LangSys for r in sc.LangSysRecord]
    else:
        for stag in script_tags or SCRIPT_TAGS:
            sc = scripts.get(stag) or scripts.get("DFLT") or scripts.get("dflt") or scripts.get("latn")
            if sc:
                eng = [r.LangSys for r in sc.LangSysRecord if r.LangSysTag == "ENG "]
                langsys += eng[:1] or [sc.DefaultLangSys]
    idx = set()
    for ls in langsys:
        if ls is None:
            continue
        chosen = [i for i in ls.FeatureIndex if feats[i].FeatureTag in FEATURES]
        if ls.ReqFeatureIndex != 0xFFFF:
            chosen.append(ls.ReqFeatureIndex)
        for i in chosen:
            idx.update(tables[i].LookupListIndex)
            if select == "all":
                for j, fr in enumerate(feats):
                    if j >= len(t.FeatureList.FeatureRecord) and fr.FeatureTag == feats[i].FeatureTag:
                        idx.update(tables[j].LookupListIndex)
    return t, [t.LookupList.Lookup[i] for i in sorted(idx)]


def subtables(lookup, ext_type):
    for st in lookup.SubTable:
        if lookup.LookupType == ext_type:
            yield st.ExtensionLookupType, st.ExtSubTable
        else:
            yield lookup.LookupType, st


def rule_records(st, typ):
    """For every rule of a context / chain context subtable: (glyph sets of its input
    positions, its (sequence index, lookup index) records). ('not', S) as in
    rule_positions."""
    chain = typ == "chain"
    recs = lambda r: [(x.SequenceIndex, x.LookupListIndex)
                      for x in (getattr(r, "SubstLookupRecord", None) or getattr(r, "PosLookupRecord", None) or [])]
    if st.Format == 1:
        for g, rs in zip(st.Coverage.glyphs, first(st, "ChainSubRuleSet", "ChainPosRuleSet", "SubRuleSet", "PosRuleSet")):
            for r in (first(rs, "ChainSubRule", "ChainPosRule", "SubRule", "PosRule") if rs else []):
                yield [{g}] + [{x} for x in r.Input], recs(r)
    elif st.Format == 2:
        icd = st.InputClassDef if chain else st.ClassDef
        d = icd.classDefs if icd else {}
        members = lambda k: ("not", set(d)) if k == 0 else {g for g, c in d.items() if c == k}
        sets = first(st, "ChainSubClassSet", "ChainPosClassSet", "SubClassSet", "PosClassSet")
        for k, cs in enumerate(sets):
            head = {g for g in st.Coverage.glyphs if d.get(g, 0) == k}
            for r in (first(cs, "ChainSubClassRule", "ChainPosClassRule", "SubClassRule", "PosClassRule") if cs else []):
                yield [head] + [members(c) for c in (r.Input if chain else r.Class)], recs(r)
    else:
        cov = st.InputCoverage if chain else st.Coverage
        yield [set(c.glyphs) for c in cov], recs(st)


def marks_only(st, typ, tag):
    """A context subtable whose nested lookups act only at positions that hold GDEF
    marks, and only on those marks (a mark substituted by a mark, or a mark's
    position or advance): it cannot change a width, as mark advances are zeroed after
    positioning (Hebrew points, Arabic harakat)."""
    if typ == "reverse":
        return False
    table = font[tag].table
    for inputs, recs in rule_records(st, typ):
        for seq, li in recs:
            if seq >= len(inputs) or isinstance(inputs[seq], tuple):
                return False
            at = inputs[seq]
            if not at or any(gdef_class.get(g) != 3 for g in at):
                return False
            lk = table.LookupList.Lookup[li]
            for t2, s2 in subtables(lk, 7 if tag == "GSUB" else 9):
                if tag == "GSUB":
                    if t2 != 1 or any(gdef_class.get(s2.mapping[g]) != 3 for g in at if g in s2.mapping):
                        return False
                elif t2 == 2:
                    if s2.ValueFormat2:
                        return False
                elif t2 not in (1, 4, 5, 6):
                    return False
    return True


def first(obj, *names):
    for n in names:
        v = getattr(obj, n, None)
        if v is not None:
            return v
    return []


def rule_positions(st, typ):
    """For every rule of a context / chain context / reverse chain subtable, the glyph
    sets its positions must match. ('not', S) stands for every glyph outside S."""
    chain = typ in ("chain", "reverse")
    if typ == "reverse":
        yield [set(st.Coverage.glyphs)] + [set(c.glyphs) for c in st.BacktrackCoverage] + \
              [set(c.glyphs) for c in st.LookAheadCoverage]
        return
    if st.Format == 1:
        for g, rs in zip(st.Coverage.glyphs, first(st, "ChainSubRuleSet", "ChainPosRuleSet", "SubRuleSet", "PosRuleSet")):
            if rs is None:
                continue
            for r in first(rs, "ChainSubRule", "ChainPosRule", "SubRule", "PosRule"):
                pos = [{g}] + [{x} for x in r.Input]
                if chain:
                    pos += [{x} for x in r.Backtrack] + [{x} for x in r.LookAhead]
                yield pos
    elif st.Format == 2:
        icd = st.InputClassDef if chain else st.ClassDef

        def members(cd, k):
            d = cd.classDefs if cd else {}
            return ("not", set(d)) if k == 0 else {g for g, c in d.items() if c == k}

        sets = first(st, "ChainSubClassSet", "ChainPosClassSet", "SubClassSet", "PosClassSet")
        for k, cs in enumerate(sets):
            if cs is None:
                continue
            head = {g for g in st.Coverage.glyphs if icd.classDefs.get(g, 0) == k}
            for r in first(cs, "ChainSubClassRule", "ChainPosClassRule", "SubClassRule", "PosClassRule"):
                pos = [head] + [members(icd, c) for c in (r.Input if chain else r.Class)]
                if chain:
                    pos += [members(st.BacktrackClassDef, c) for c in r.Backtrack]
                    pos += [members(st.LookAheadClassDef, c) for c in r.LookAhead]
                yield pos
    else:
        if chain:
            yield [set(c.glyphs) for c in st.InputCoverage] + [set(c.glyphs) for c in st.BacktrackCoverage] + \
                  [set(c.glyphs) for c in st.LookAheadCoverage]
        else:
            yield [set(c.glyphs) for c in st.Coverage]


if "arabic" in os.environ.get("CERTIFY_SCRIPTS", ""):
    maps, form_blocked = form_substitutes()
    # Glyphs any other active GSUB lookup covers: if a letter's own glyph is one of
    # them, a lookup before the forms (ccmp, locl) may change what the form sees.
    early = set()
    if "GSUB" in font:
        for lk in active_lookups("GSUB")[1]:
            for typ, st in subtables(lk, 7):
                early.update(getattr(getattr(st, "Coverage", None), "glyphs", []) or [])
    for cp in [c for c in chars if c in ARABIC_D or c in ARABIC_R]:
        g = nominal[cp]
        make_unsafe([cp], "Arabic letter: modelled by its joining forms")
        for k, f in enumerate(FORMS):
            if cp in ARABIC_R and f in ("init", "medi"):
                continue
            v = VBASE + 4 * cp + k
            arabic_forms[v] = (cp, k)
            chars.append(v)
            nominal[v] = maps[f].get(g, g)
            if g in form_blocked:
                make_unsafe([v], f"{f} is not a single substitution")
            elif g in early and nominal[v] != g:
                make_unsafe([v], "a lookup before the joining forms touches the letter")


# ---------------------------------------------------------------- AAT state machines
#
# morx subtables of every kind (rearrangement, contextual, ligature, insertion), in any processing
# order, and the kerning state machines (kerx format 1, kern format 1) are analysed by emulating
# HarfBuzz 15: StateTableDriver::drive and each subtable's transition (hb-aat-layout-common.hh,
# hb-aat-layout-morx-table.hh, hb-aat-layout-kerx-table.hh, hb-ot-kern-table.hh). Noncontextual
# subtables are a glyph map. Pair kerning (kerx 0/2/6, kern 0/2/3) goes through hb_kern_machine_t and
# is pair-additive. kerx format 4 (anchor / control-point attachment) and cross-stream kerning only
# write glyph offsets and attachment chains, never advances, so they cannot change a width.
#
# Class level, per subtable, over every state reachable on the glyph alphabet (the glyphs of the
# repertoire plus every glyph an island can hold at that subtable):
#   S  from every reachable state the class changes nothing and moves to a start state, directly or
#      by a DontAdvance reset into one; from the start states it is quiet (no change, no DontAdvance,
#      stays in a start state). Storing state (a mark, a component, a kerning push) is allowed.
#   K  quiet from the start states only.   P  anything else.
#   End of text after an S or K glyph changes nothing.
# Island level: every P/K string with a primer, up to the island bound, runs through the whole chain
# on its own, from every start state, followed by end of text or by an S glyph, with all machine
# state stored before it (mark, rearrangement bounds, ligature and kerning stacks) marked stale. The
# island lemma holds when no run touches stale state and all runs agree: then an island's glyphs
# and kerning depend on the island alone, and bfl measures them. An island that fails makes its
# cheapest character unsafe. The alphabet and the islands' glyphs are iterated to a fixed point.

DELETED = "\0deleted"   # HarfBuzz's DELETED_GLYPH (0xFFFF), class 2
STALE = "\0stale"       # a mark, bound or stack entry stored before the island
UNKNOWN = "\0unknown"   # contextual mark_set when a mark may have been set before the island
REARRANGE = [0x00, 0x10, 0x01, 0x11, 0x20, 0x30, 0x02, 0x03, 0x12, 0x13, 0x21, 0x31, 0x22, 0x32, 0x23, 0x33]
CONTEXT_MAX = 16        # below HB_MAX_CONTEXT_LENGTH: rearrangement spans and ligature stacks we model
STALL_MAX = 16          # consecutive DontAdvance transitions before giving up
ISLAND_BUDGET = 40000   # island strings simulated per round; the island bound shrinks to fit
DEBUG = bool(os.environ.get("CERTIFY_DEBUG"))
ISLAND_DUMP = {}        # island string -> chain output per sequence (CERTIFY_DUMP=file writes it, for tests)
LAST_AAT = []           # (machine, step facts, cp -> glyphs) of the live machines in the last analysis
glyph_order = font.getGlyphOrder()


class Unprovable(Exception):
    pass


def glyph_id(g):
    """Glyph id of a glyph name. Tables may hold ids past the glyph count (HarfBuzz keeps them, for
    example as an insertion placeholder that a later ligature consumes); fontTools names them glyphNNNNN."""
    if g == DELETED:
        return 0xFFFF
    if g in gid:
        return gid[g]
    if g.startswith("glyph") and g[5:].isdigit() and int(g[5:]) <= 0xFFFF:
        return int(g[5:])
    raise Unprovable(f"unknown glyph {g!r}")


class StaleAccess(Unprovable):
    pass


class Machine:
    """One AAT state machine. kind: rearr, ctx, lig, ins (morx types 0, 1, 2, 5) or kern (kerx or
    kern format 1). states(s, k) returns the entry for state s and class k."""

    def __init__(self, kind, name, reverse, ncls, classes, states, nstates):
        self.kind, self.name, self.reverse = kind, name, reverse
        self.ncls, self.classes, self.states, self.nstates = ncls, classes, states, nstates
        self.memo = {}

    def cls(self, g):
        if g == DELETED:
            return 2
        k = self.classes.get(g, 1)
        return k if k < self.ncls else 1   # HarfBuzz: a class beyond nClasses reads as out-of-bounds

    def entry(self, s, k):
        e = self.memo.get((s, k))
        if e is None:
            if not 0 <= s < self.nstates:
                raise Unprovable(f"{self.name}: state {s} out of range")
            e = self.memo[(s, k)] = self.states(s, k if k < self.ncls else 1)
        return e

    def initiable(self, e):   # HarfBuzz's is_action_initiable
        return getattr(e, {"rearr": "MarkFirst", "ctx": "SetMark", "lig": "SetComponent", "ins": "SetMark",
                           "kern": "Push"}[self.kind])

    def actionable(self, e):
        k = self.kind
        if k == "rearr":
            return e.Verb != 0
        if k == "ctx":
            return e.MarkIndex != 0xFFFF or e.CurrentIndex != 0xFFFF
        if k == "lig":
            return bool(e.Actions)
        if k == "ins":
            return bool(e.CurrentInsertionAction or e.MarkedInsertionAction)
        return e.KernIndex is not None

    def sure_first_set(self):
        """Glyphs certainly in HarfBuzz's per-subtable glyph set (collect_initial_glyphs: classes whose
        start-of-text entry moves, initiates or acts). HarfBuzz skips a subtable when no buffer glyph is in
        that set, so an island holding one of these always runs it."""
        keep = {k for k in range(self.ncls) if self.entry(0, k).NewState != 0 or self.initiable(self.entry(0, k))
                or self.actionable(self.entry(0, k))}
        out = {g for g, k in self.classes.items() if k < self.ncls and k in keep}
        if 2 in keep:
            out.add(DELETED)
        return out


def _u(data, o, n):
    if o < 0 or o + n > len(data):
        raise Unprovable("table read out of range")
    return int.from_bytes(data[o:o + n], "big")


def aat_lookup16(data, off):
    """An AAT lookup table of 16-bit values (formats 0, 2, 4, 6, 8, 10), as {glyph name: value}."""
    fmt, res, n_gl = _u(data, off, 2), {}, len(glyph_order)
    if fmt == 0:
        for g in range(n_gl):
            res[g] = _u(data, off + 2 + 2 * g, 2)
    elif fmt in (2, 4, 6):
        unit, n, prev = _u(data, off + 2, 2), _u(data, off + 4, 2), -1
        if unit < (4 if fmt == 6 else 6):
            raise Unprovable("bad lookup unit size")
        for i in range(n):
            o = off + 12 + i * unit
            if fmt == 6:
                g = _u(data, o, 2)
                if g == 0xFFFF:
                    continue
                if g <= prev:
                    raise Unprovable("unsorted lookup")
                res[g], prev = _u(data, o + 2, 2), g
                continue
            last, first = _u(data, o, 2), _u(data, o + 2, 2)
            if last == 0xFFFF and first == 0xFFFF:
                continue
            if first > last or first <= prev:
                raise Unprovable("unsorted lookup")
            prev = last
            for g in range(first, last + 1):
                res[g] = _u(data, o + 4, 2) if fmt == 2 else _u(data, off + _u(data, o + 4, 2) + 2 * (g - first), 2)
    elif fmt == 8:
        first, n = _u(data, off + 2, 2), _u(data, off + 4, 2)
        for i in range(n):
            res[first + i] = _u(data, off + 6 + 2 * i, 2)
    elif fmt == 10:
        size, first, n = _u(data, off + 2, 2), _u(data, off + 4, 2), _u(data, off + 6, 2)
        if size not in (1, 2):
            raise Unprovable("lookup format 10 value size")
        for i in range(n):
            res[first + i] = _u(data, off + 8 + size * i, size)
    else:
        raise Unprovable(f"AAT lookup format {fmt}")
    return {glyph_order[g]: v for g, v in res.items() if g < n_gl}


class KernEntry:
    __slots__ = ("NewState", "DontAdvance", "Push", "Reset", "KernIndex")


def kerx1_machine(name, data, st, rng, tuple_count, reverse):
    """kerx format 1 (extended state table). st: start of the state machine (after the 12-byte header)."""
    ncls = _u(data, st, 4)
    cls_off, sa, et, ka = (st + _u(data, st + o, 4) for o in (4, 8, 12, 16))
    classes = aat_lookup16(data, cls_off)

    def states(s, k):
        o = et + 6 * _u(data, sa + 2 * (s * ncls + k), 2)
        e, flags, idx = KernEntry(), _u(data, o + 2, 2), _u(data, o + 4, 2)
        e.NewState, e.DontAdvance, e.Push, e.Reset = _u(data, o, 2), bool(flags & 0x4000), bool(flags & 0x8000), \
            bool(flags & 0x2000)
        e.KernIndex = None if idx == 0xFFFF else idx
        return e
    m = Machine("kern", name, reverse, ncls, classes, states, 1 << 16)
    # HarfBuzz: kern_idx = ExtendedTypes::byteOffsetToIndex (kernActionIndex) = kernActionIndex / 2,
    # into the FWORD array at kernAction (an offset from the state machine).
    m.value_addr = lambda i: ka + 2 * (i // 2)
    m.data, m.rng, m.tuple_count = data, rng, max(1, tuple_count)
    return m


def kern1_machine(name, data, mst, rng):
    """kern format 1 (obsolete state table: byte classes and states, newState as a byte offset)."""
    ncls = _u(data, mst, 2)
    ct, sa, et, vt = mst + _u(data, mst + 2, 2), _u(data, mst + 4, 2), mst + _u(data, mst + 6, 2), _u(data, mst + 8, 2)
    if ncls == 0:
        raise Unprovable("kern format 1 with no classes")
    first, n = _u(data, ct, 2), _u(data, ct + 2, 2)
    classes = {glyph_order[first + i]: _u(data, ct + 4 + i, 1) for i in range(n) if first + i < len(glyph_order)}

    def states(s, k):
        o = et + 4 * _u(data, mst + sa + s * ncls + k, 1)
        e, flags, diff = KernEntry(), _u(data, o + 2, 2), _u(data, o, 2) - sa
        e.NewState = (abs(diff) // ncls) * (1 if diff >= 0 else -1)   # C division: (newState - stateArray) / nClasses
        e.DontAdvance, e.Push, e.Reset = bool(flags & 0x4000), bool(flags & 0x8000), False
        e.KernIndex = (flags & 0x3FFF) or None
        return e
    m = Machine("kern", name, False, ncls, classes, states, 1 << 16)
    # HarfBuzz: ObsoleteTypes::byteOffsetToIndex (offset, machine, kernAction) = (offset - valueTable) / 2,
    # or an index the sanitizer rejects when offset < valueTable.
    m.value_addr = lambda off: None if off < vt else mst + vt + 2 * ((off - vt) // 2)
    m.data, m.rng, m.tuple_count = data, rng, 1
    return m


def morx_machine(ci, si, st):
    stt = st.SubStruct.StateTable
    kind = {0: "rearr", 1: "ctx", 2: "lig", 5: "ins"}[st.MorphType]
    m = Machine(kind, f"morx type {st.MorphType} (chain {ci}, subtable {si})",
                st.ProcessingOrder in ("ReversedLayoutOrder", "ReversedLogicalOrder"), stt.GlyphClassCount,
                stt.GlyphClasses, lambda s, k: stt.States[s].Transitions[k], len(stt.States))
    if kind == "lig":
        m.components, m.ligatures = list(stt.LigComponents), list(stt.Ligatures)
    if kind == "ctx":
        m.lookups = stt.PerGlyphLookups
    return m


def build_configs():
    """The subtable sequences HarfBuzz may run, each as a list of ("map", mapping) and ("sm", Machine).
    HarfBuzz 15 adds no default features to the AAT map, so its chain flags are the default flags; the
    flags its default ligature / contextual-alternate selectors would give (hb_aat_map_builder_t:
    flags &= disable; flags |= enable, in feature order) are analysed too, and in "all" mode also every
    selector of those types OR-ed in. The analysis must hold for each sequence."""
    if "morx" not in font:
        return [[]]
    chains = font["morx"].table.MorphChain
    variants = []
    for mode in ("default", "selectors") + (("union",) if SELECT == "all" else ()):
        flags = []
        for chain in chains:
            f = chain.DefaultFlags
            for fe in chain.MorphFeature:
                sel = (fe.FeatureType, fe.FeatureSetting)
                if mode == "selectors" and sel in AAT_DEFAULT_SELECTORS:
                    f = (f & fe.DisableFlags) | fe.EnableFlags
                elif mode == "union" and (sel in AAT_DEFAULT_SELECTORS or fe.FeatureType in AAT_FEATURE_TYPES):
                    f |= fe.EnableFlags
            flags.append(f)
        keys = tuple((ci, si) for ci, chain in enumerate(chains) for si, st in enumerate(chain.MorphSubtable)
                     if st.SubFeatureFlags & flags[ci] and st.TextDirection != "Vertical")
        if keys not in variants:
            variants.append(keys)
    machines, configs = {}, []
    for keys in variants:
        cfg = []
        for ci, si in keys:
            st = chains[ci].MorphSubtable[si]
            if st.MorphType == 4:
                cfg.append(("map", st.SubStruct.Substitution))
            else:
                if (ci, si) not in machines:
                    machines[(ci, si)] = morx_machine(ci, si, st)
                cfg.append(("sm", machines[(ci, si)]))
        configs.append(cfg)
    return configs


def build_pos_machines():
    """kerx / kern state machines (format 1) that can change horizontal advances. Returns (machines,
    reason the tables cannot be analysed or None)."""
    machines = []
    try:
        if "kerx" in font:
            data = font.getTableData("kerx")
            n, off = _u(data, 4, 4), 8
            for i in range(n):
                length, cov, tup = _u(data, off, 4), _u(data, off + 4, 4), _u(data, off + 8, 4)
                fmt = cov & 0xFF
                # Vertical subtables are skipped for horizontal text; cross-stream ones write y offsets.
                if not cov & 0xC0000000 and fmt not in (0, 2, 4, 6):
                    if fmt != 1:
                        return machines, f"kerx format {fmt} not analysed"
                    rng = (off, off + length) if i < n - 1 else (0, len(data))   # last one: whole blob
                    machines.append(kerx1_machine(f"kerx format 1 (subtable {i})", data, off + 12, rng, tup,
                                                  bool(cov & 0x10000000)))
                off += length
        if "kern" in font:
            formats = [getattr(kt, "format", None) for kt in font["kern"].kernTables]
            if any(f not in (0, 1, 2, 3) for f in formats):
                return machines, f"kern subtable format {formats} not analysed"
            if 1 in formats:
                data = font.getTableData("kern")
                aat = _u(data, 0, 2) == 1
                n, off = (_u(data, 4, 4), 8) if aat else (_u(data, 2, 2), 4)
                for i in range(n):
                    if aat:
                        length, cov, fmt, hdr = _u(data, off, 4), _u(data, off + 4, 1), _u(data, off + 5, 1), 8
                        skip = cov & 0xE0           # vertical, cross-stream, or variation (skipped)
                    else:
                        length, fmt, cov, hdr = _u(data, off + 2, 2), _u(data, off + 4, 1), _u(data, off + 5, 1), 6
                        skip = not cov & 0x01 or cov & 0x04   # not horizontal, or cross-stream
                    if fmt == 1 and not skip:
                        rng = (off, off + length) if i < n - 1 else (0, len(data))
                        machines.append(kern1_machine(f"kern format 1 (subtable {i})", data, off + hdr, rng))
                    off += length
    except Unprovable as e:
        return machines, f"kerx/kern state machine not parsed: {e}"
    return machines, None


try:
    CONFIGS = build_configs()
    CONFIG_FAIL = None
except Unprovable as e:
    CONFIGS, CONFIG_FAIL = [[]], f"morx not parsed: {e}"
POS_MACHINES, POS_FAIL = build_pos_machines()
if "mort" in font and "morx" not in font:
    CONFIG_FAIL = "mort table not analysed"
if FEATURES_ON and "morx" in font and "GSUB" not in font:
    CONFIG_FAIL = "features turned on for an AAT font (not mapped to selectors)"


class Step:
    """Per (sequence, subtable) facts of one fixed-point iteration."""
    present = reach = starts = cur = None
    live = False
    can_set_mark = True
    depths = (0,)


def acts(m, cx, e, current, eot=False):
    """Can transition e change a glyph or an advance, when the current glyph is one of `current`?
    A mark or stack entry may hold any glyph present."""
    k = m.kind
    if k == "ctx":
        if eot and not cx.can_set_mark:
            return False   # HarfBuzz: no end-of-text substitution unless a mark was set
        for idx, pool in ((e.MarkIndex, cx.present), (e.CurrentIndex, current)):
            if idx != 0xFFFF:
                if idx >= len(m.lookups):
                    return True
                lk = m.lookups[idx]
                if any(lk.get(g, g) != g for g in pool):
                    return True
        return False
    if k == "lig":
        return bool(e.Actions) and not eot   # HarfBuzz ignores ligature actions at end of text
    return m.actionable(e)


def entry_label(m, e):
    """Everything in an entry but its next state (HarfBuzz ignores the kashida-like insertion flags)."""
    k = m.kind
    if k == "rearr":
        return e.MarkFirst, e.MarkLast, e.DontAdvance, e.Verb
    if k == "ctx":
        return e.SetMark, e.DontAdvance, e.MarkIndex, e.CurrentIndex
    if k == "lig":
        return e.SetComponent, e.DontAdvance, tuple((a.Store, a.GlyphIndexDelta) for a in e.Actions)
    if k == "ins":
        return (e.SetMark, e.DontAdvance, e.CurrentInsertBefore, e.MarkedInsertBefore, tuple(e.CurrentInsertionAction),
                tuple(e.MarkedInsertionAction))
    return e.Push, e.Reset, e.DontAdvance, e.KernIndex


def classify(m, cx, live, curset, status):
    """Class-level pass for machine m: reachable states over the alphabet, whether m can act at all,
    and S/K/P promotion of every live character (curset: cp -> glyphs it can have here)."""
    by_class = {}
    for g in cx.present:
        by_class.setdefault(m.cls(g), set()).add(g)
    reach, todo = {0}, [0]
    while todo:
        s = todo.pop()
        for k in by_class:
            ns = m.entry(s, k).NewState
            if ns not in reach:
                m.entry(ns, 0)
                reach.add(ns)
                todo.append(ns)
    cx.reach, cx.starts = reach, [0, 1] if 1 in reach else [0]
    if m.kind == "ctx":
        cx.can_set_mark = any(m.entry(s, k).SetMark for s in reach for k in by_class)
    cx.live = any(acts(m, cx, m.entry(s, k), gs) for s in reach for k, gs in by_class.items()) or \
        any(acts(m, cx, m.entry(s, 0), cx.present, eot=True) for s in reach)
    if not cx.live:
        # No transition can change anything; only an endless DontAdvance loop (which burns HarfBuzz's
        # max_ops budget) could still matter.
        for s0 in reach:
            for k in by_class:
                s, seen = s0, set()
                while m.entry(s, k).DontAdvance:
                    if s in seen:
                        cx.live = True
                        break
                    seen.add(s)
                    s = m.entry(s, k).NewState
    if not cx.live:
        return
    # States that behave exactly like a start state on every glyph of the alphabet and at end of text
    # (same entry flags and action data, equivalent next states: Moore's partition refinement) count as
    # that start state. Island runs over the alphabet are identical from equivalent states.
    alpha = sorted(by_class)
    states = sorted(reach)
    block = {s: (tuple(entry_label(m, m.entry(s, k)) for k in alpha), entry_label(m, m.entry(s, 0))) for s in states}
    while True:
        ids = {}
        block = {s: ids.setdefault(b, len(ids)) for s, b in block.items()}
        refined = {s: (block[s], tuple(block[m.entry(s, k).NewState] for k in alpha)) for s in states}
        if len(set(refined.values())) == len(ids):
            break
        block = refined
    start_blocks = {block[s] for s in cx.starts}
    for cp in live:
        quiet = safe = True
        for g in curset[cp]:
            k = m.cls(g)
            for s in reach:
                e = m.entry(s, k)
                ok = not acts(m, cx, e, (g,)) and block[e.NewState] in start_blocks
                if block[s] in start_blocks and not (ok and not e.DontAdvance):
                    quiet = False
                safe = safe and ok
        if not (quiet and safe) and cp in status:
            if DEBUG and status[cp] == "S":
                print(f"debug: {m.name}: {chr(cp)!r} -> {'K' if quiet else 'P'}", file=sys.stderr)
            if not quiet:
                status[cp] = "P"
            elif status[cp] == "S":
                status[cp] = "K"


def simulate(m, cx, glyphs, start, eot, depth0=0, consumed=0, whole=False):
    """HarfBuzz's StateTableDriver::drive plus m's transition, over `glyphs` (in processing order) on
    their own: every mark, bound or stack entry from before them is STALE (depth0 stale kerning
    entries). With eot False the run stops where the next glyph, an S glyph, would be read: S glyphs
    are quiet. consumed glyphs count as already processed. whole: glyphs are the entire buffer, with
    HarfBuzz's initial machine state (self-test only). Returns (glyphs, advance deltas, final state,
    kerning stack depth, ops, glyphs read)."""
    kind, read = m.kind, set()
    inplace = kind in ("rearr", "ctx", "kern")
    info, idx = list(glyphs), consumed
    out, pend = list(glyphs[:consumed]), list(glyphs[consumed:])
    mark = r_start = r_end = 0 if whole else STALE
    mark_set = False if whole else UNKNOWN if cx.can_set_mark else False
    stack = [STALE] * depth0 if kind == "kern" else []
    deltas = [0] * len(glyphs)
    state, stall, steps, ops = start, 0, 0, 0

    def move_to(i):   # hb_buffer_t::move_to on the output buffer
        lo = len(out)
        if i > lo:
            if i - lo > len(pend):
                raise Unprovable(f"{m.name}: move past the end")
            out.extend(pend[:i - lo])
            del pend[:i - lo]
        elif i < lo:
            pend[:0] = out[i:]
            del out[i:]

    def check(g):   # a glyph the subtable writes; glyph 0xFFFF is HarfBuzz's DELETED_GLYPH
        if glyph_id(g) == 0xFFFF:
            g = DELETED
        read.add(g)
        return g

    while True:
        at_end = idx >= len(info) if inplace else not pend
        if at_end and not eot:
            break
        if at_end:
            k = 0
        else:
            g = info[idx] if inplace else pend[0]
            read.add(g)
            k = m.cls(g)
        e = m.entry(state, k)
        if kind == "rearr":
            n = len(info)
            if e.MarkFirst:
                r_start = idx
            if e.MarkLast:
                r_end = min(idx + 1, n)
            if e.Verb:
                if r_start is STALE:
                    raise StaleAccess(f"{m.name}: rearrangement from a glyph marked before the island")
                # A stale end lies at or before the island's first glyph, so start < end fails.
                if r_end is not STALE and r_start < r_end:
                    s0, t0 = r_start, r_end
                    mp = REARRANGE[e.Verb]
                    lw, rw = min(2, mp >> 4), min(2, mp & 0xF)
                    if t0 - s0 > CONTEXT_MAX and not whole:
                        raise Unprovable(f"{m.name}: long rearrangement")
                    if lw + rw <= t0 - s0 <= 64:   # HB_MAX_CONTEXT_LENGTH
                        a, b = info[s0:s0 + lw], info[t0 - rw:t0]
                        if lw != rw:
                            info[s0 + rw:t0 - lw] = info[s0 + lw:t0 - rw]
                        info[s0:s0 + rw] = b
                        info[t0 - lw:t0] = a
                        if mp >> 4 == 3:
                            info[t0 - 1], info[t0 - 2] = info[t0 - 2], info[t0 - 1]
                        if mp & 0xF == 3:
                            info[s0], info[s0 + 1] = info[s0 + 1], info[s0]
        elif kind == "ctx":
            n = len(info)
            if not (at_end and mark_set is False):
                if e.MarkIndex != 0xFFFF:
                    if e.MarkIndex >= len(m.lookups):
                        raise Unprovable(f"{m.name}: substitution table out of range")
                    lk = m.lookups[e.MarkIndex]
                    if mark is STALE:
                        if any(lk.get(g, g) != g for g in cx.present):
                            raise StaleAccess(f"{m.name}: substitutes a glyph marked before the island")
                    elif lk.get(info[mark], info[mark]) != info[mark]:
                        info[mark] = check(lk[info[mark]])
                if e.CurrentIndex != 0xFFFF:
                    if e.CurrentIndex >= len(m.lookups):
                        raise Unprovable(f"{m.name}: substitution table out of range")
                    lk, i = m.lookups[e.CurrentIndex], min(idx, n - 1)
                    if lk.get(info[i], info[i]) != info[i]:
                        if at_end and mark_set is UNKNOWN:
                            raise Unprovable(f"{m.name}: end of text substitutes when a mark was set earlier")
                        info[i] = check(lk[info[i]])
            if e.SetMark:
                mark_set, mark = True, idx
        elif kind == "lig":
            if e.SetComponent:
                if stack and stack[-1] == len(out):   # never mark the same position twice
                    stack.pop()
                stack.append(len(out))
                if len(stack) > CONTEXT_MAX and not whole:
                    raise Unprovable(f"{m.name}: deep ligature stack")
            if e.Actions and not at_end and (stack or not whole):   # HarfBuzz: nothing at end of text
                if not stack:
                    raise StaleAccess(f"{m.name}: ligature action reaches a component set before the island")
                end, cursor, lig_idx = len(out), len(stack), 0
                for j, a in enumerate(e.Actions):
                    if cursor == 0:
                        if whole:
                            stack.clear()   # HarfBuzz: stack underflow clears the stack
                            break
                        raise StaleAccess(f"{m.name}: ligature action reaches a component set before the island")
                    cursor -= 1
                    move_to(stack[cursor])
                    if not pend:
                        raise Unprovable(f"{m.name}: ligature component past the end")
                    comp = glyph_id(pend[0]) + a.GlyphIndexDelta
                    if not 0 <= comp < len(m.components):
                        raise Unprovable(f"{m.name}: ligature component index out of range")
                    lig_idx += m.components[comp]
                    if a.Store or j == len(e.Actions) - 1:
                        if not 0 <= lig_idx < len(m.ligatures):
                            raise Unprovable(f"{m.name}: ligature index out of range")
                        out.append(check(m.ligatures[lig_idx]))   # replace_glyph
                        pend.pop(0)
                        lig_end = stack[-1] + 1
                        while len(stack) - 1 > cursor:   # delete the later components
                            move_to(stack.pop())
                            if not pend:
                                raise Unprovable(f"{m.name}: ligature component past the end")
                            out.append(DELETED)
                            read.add(DELETED)
                            pend.pop(0)
                        move_to(lig_end)
                move_to(end)
        elif kind == "ins":
            mark_loc = len(out)
            for glyphs_in, before, current in ((e.MarkedInsertionAction, e.MarkedInsertBefore, False),
                                               (e.CurrentInsertionAction, e.CurrentInsertBefore, True)):
                if current and e.SetMark:
                    mark = mark_loc
                if not glyphs_in:
                    continue   # no index, or a count of zero: a no-op
                if not current and mark is STALE:
                    raise StaleAccess(f"{m.name}: inserts at a glyph marked before the island")
                gl = [check(g) for g in glyphs_in]
                ops += len(gl)
                end = len(out)
                if not current:
                    move_to(mark)
                if pend and not before:
                    out.append(pend[0])   # copy_glyph
                out.extend(gl)
                if pend and not before:
                    pend.pop(0)           # skip_glyph
                move_to(end + len(gl) if not current or not e.DontAdvance else end)
        else:
            n = len(info)
            if e.Reset:
                stack.clear()
            if e.Push:
                if len(stack) < 8:
                    stack.append(idx)
                else:
                    stack.clear()   # HarfBuzz: overflow resets the stack
            if e.KernIndex is not None and stack:
                addr, (lo, hi) = m.value_addr(e.KernIndex), m.rng
                if addr is None or addr < lo or addr >= hi:
                    stack.clear()   # the sanitizer rejects the value array
                elif addr + 2 * len(stack) * m.tuple_count > hi:
                    raise Unprovable(f"{m.name}: kerning values run past the subtable")
                else:
                    last, j = False, 0
                    while not last and stack:
                        p = stack.pop()
                        v = _u(m.data, addr + 2 * m.tuple_count * j, 2)
                        v, j = v - 0x10000 if v & 0x8000 else v, j + 1
                        if p is STALE:
                            raise StaleAccess(f"{m.name}: kerning pops a glyph pushed before the island")
                        if p >= n:
                            continue
                        last = bool(v & 1)
                        deltas[p] += v & ~1
        state = e.NewState
        if idx >= len(info) if inplace else not pend:
            break
        if e.DontAdvance:
            stall, ops = stall + 1, ops + 1
            if stall > STALL_MAX:
                raise Unprovable(f"{m.name}: DontAdvance loop")
        else:
            stall = 0
            if inplace:
                idx += 1
            else:
                out.append(pend.pop(0))
        steps += 1
        if steps > 64 * (len(glyphs) + 4):
            raise Unprovable(f"{m.name}: too many transitions")
    return (info if inplace else out + pend), deltas, state, len(stack), ops, read


if os.environ.get("CERTIFY_SELFTEST"):
    # Self-test: run each line of the file through the emulated chain (default flags) as a whole buffer
    # and print the glyph ids, to compare with hb-shape --no-glyph-names.
    for line in open(os.environ["CERTIFY_SELFTEST"], encoding="utf-8").read().splitlines():
        buf = [cmap.get(ord(c), ".notdef") for c in line]
        try:
            for kind, obj in CONFIGS[0]:
                if kind == "map":
                    buf = [obj.get(g, g) if g != DELETED else g for g in buf]
                    continue
                proc = buf[::-1] if obj.reverse else buf
                res = simulate(obj, Step(), proc, 0, True, whole=True)[0]
                if DEBUG and res != proc:
                    print(f"debug: changed by {obj.name}{' reversed' if obj.reverse else ''}", file=sys.stderr)
                buf = res[::-1] if obj.reverse else res
            kern = []
            for m in POS_MACHINES:   # on the chain output with deleted glyphs kept, as HarfBuzz runs kerx
                proc = buf[::-1] if m.reverse else buf
                dl = simulate(m, Step(), proc, 0, True, whole=True)[1]
                kern.append(m.name + "=" + ",".join(map(str, dl[::-1] if m.reverse else dl)))
            print("|".join(str(glyph_id(g)) for g in buf if g != DELETED) + "".join("\t" + k for k in kern))
        except Unprovable as e:
            print(f"error: {e}")
    sys.exit(0)


def run_machine(m, cx, buf):
    """Runs one island (logical order) through machine m from every start state, followed by an S
    glyph or by end of text, with every possible stale kerning depth. All runs must agree. Returns
    (glyphs, advance deltas, ops, glyphs read, kerning depths left for the next island)."""
    proc = buf[::-1] if m.reverse else list(buf)
    results, ops, read, left = set(), 0, set(), set()
    for s0 in cx.starts:
        for eot in (False, True):
            for d in cx.depths:
                g, dl, _, depth, o, r = simulate(m, cx, proc, s0, eot, d)
                results.add((tuple(g), tuple(dl)))
                ops, read = max(ops, o), read | r
                if not eot:
                    left.add(depth)
    if len(results) > 1:
        raise Unprovable(f"{m.name}: the island's result depends on what precedes or follows it")
    g, dl = results.pop()
    if m.reverse:
        g, dl = g[::-1], dl[::-1]
    if not hasattr(m, "sure_first"):
        m.sure_first = m.sure_first_set()
    if not set(buf) & m.sure_first and (list(g) != list(buf) or any(dl)):
        raise Unprovable(f"{m.name}: changes an island on which HarfBuzz may skip the subtable")
    return list(g), list(dl), ops, read, left


def analyse_aat(live, status, formed):
    """The AAT part of a round. Promotes characters in `status` and returns (blocked cp -> reason, font-wide
    failure or None, glyphs islands can produce, cp -> glyphs it can have, island bound)."""
    blocked, glyphs_of = {}, {cp: {nominal[cp]} for cp in live}
    LAST_AAT.clear()
    fail = CONFIG_FAIL or POS_FAIL
    if fail:
        return blocked, fail, set(), glyphs_of, M_ISLAND
    island_glyphs, m_eff = {}, M_ISLAND
    try:
        while True:
            st = dict(status)
            steps, curs = {}, []
            for ci, cfg in enumerate(CONFIGS):
                cur = {cp: nominal[cp] for cp in live}
                for si, (kind, obj) in enumerate(cfg):
                    if kind == "map":
                        cur = {cp: obj.get(g, g) for cp, g in cur.items()}
                        continue
                    cx = steps[(ci, si)] = Step()
                    cx.cur, cx.present = cur, set(cur.values()) | island_glyphs.get((ci, si), set())
                    classify(obj, cx, live, {cp: (g,) for cp, g in cur.items()}, st)
                curs.append(cur)
            final = {cp: {c[cp] for c in curs} for cp in live}
            pos = []
            for j, m in enumerate(POS_MACHINES):
                cx = Step()
                cx.present = set().union(*final.values()) | island_glyphs.get(("pos", j), set())
                classify(m, cx, live, final, st)
                if cx.live:
                    if formed and "morx" not in font:
                        return blocked, f"{m.name} after OpenType ligatures", set(), glyphs_of, M_ISLAND
                    pushes = any(m.entry(s, m.cls(g)).Push for cp in live if st[cp] != "P" for g in final[cp]
                                 for s in (cx.reach if st[cp] == "S" else cx.starts))
                    cx.depths = tuple(range(9)) if pushes else (0,)
                pos.append((j, m, cx))
            islands = sorted(cp for cp in live if st[cp] != "S")
            primers = {cp for cp in islands if st[cp] == "P"}
            sims = any(cx.live for cx in steps.values()) or any(cx.live for _, _, cx in pos)
            new, fails, produced, island_ops = {}, [], set(), 0
            if sims and primers:
                m_eff = M_ISLAND
                while m_eff > 1 and sum(len(islands) ** n for n in range(1, m_eff + 1)) > ISLAND_BUDGET:
                    m_eff -= 1
                finals = {}
                for n in range(1, m_eff + 1):
                    for w in itertools.product(islands, repeat=n):
                        if not primers.intersection(w):
                            continue
                        own = {g for cp in w for g in final[cp]}
                        bufs, reason, ops_w = [], None, 0
                        for ci, cfg in enumerate(CONFIGS):
                            buf, ops_c = [nominal[cp] for cp in w], 0
                            for si, (kind, obj) in enumerate(cfg):
                                new.setdefault((ci, si), set()).update(buf)
                                if kind == "map":
                                    buf = [obj.get(g, g) if g != DELETED else g for g in buf]
                                    continue
                                cx = steps[(ci, si)]
                                if not cx.live:
                                    continue
                                try:
                                    buf, _, o, read, _ = run_machine(obj, cx, buf)
                                except Unprovable as e:
                                    reason = str(e)
                                    break
                                ops_c += o
                                new[(ci, si)].update(read)
                            if reason:
                                break
                            produced.update(set(buf) - own)   # what positioning sees
                            bufs.append(buf)
                            ops_w = max(ops_w, ops_c)
                        if reason:
                            fails.append((w, reason))
                            continue
                        finals[w] = bufs
                        island_ops = max(island_ops, ops_w)
                ISLAND_DUMP.clear()
                ISLAND_DUMP.update(finals)
                # Kerning state machines see the chain's output, with HarfBuzz's deleted glyphs removed
                # (and, to be safe, also kept). Stale depths grow to a fixed point over island leftovers.
                for j, m, cx in pos:
                    seen = new.setdefault(("pos", j), set())
                    for bs in finals.values():
                        for b in bs:
                            seen.update(b)
                    if not cx.live:
                        continue
                    while True:
                        left_all, bad, ops_j = set(), {}, 0
                        for w, bs in finals.items():
                            variants = {tuple(g for g in b if g != DELETED) for b in bs} | {tuple(b) for b in bs}
                            try:
                                for b in variants:
                                    _, _, o, read, left = run_machine(m, cx, list(b))
                                    seen.update(read)
                                    left_all |= left
                                    ops_j = max(ops_j, o)
                            except Unprovable as e:
                                bad[w] = str(e)
                        if left_all <= set(cx.depths):
                            break
                        cx.depths = tuple(sorted(set(cx.depths) | left_all))
                    island_ops += ops_j
                    fails += list(bad.items())
                    finals = {w: bs for w, bs in finals.items() if w not in bad}
            if all(gs <= island_glyphs.get(key, set()) for key, gs in new.items()):
                break
            for key, gs in new.items():
                island_glyphs.setdefault(key, set()).update(gs)
        # HarfBuzz's max_ops budget (at least 64 per glyph) must never run out on a certified line:
        # every DontAdvance and every inserted glyph costs one op. Each S glyph costs at most one per
        # subtable where an S class can DontAdvance, each island (one per two glyphs at most) island_ops.
        s_stalls = len(pos)
        for ci, cfg in enumerate(CONFIGS):
            n_stall = 0
            for si, (kind, m) in enumerate(cfg):
                cx = steps.get((ci, si))
                if cx and cx.live and any(m.entry(s, m.cls(cx.cur[cp])).DontAdvance
                                          for cp in live if st[cp] == "S" for s in cx.reach):
                    n_stall += 1
            s_stalls = max(s_stalls, n_stall + len(pos))
        if s_stalls + island_ops / 2 > 16:
            return blocked, "AAT DontAdvance / insertion budget", set(), glyphs_of, m_eff
        # End of text after an S or K glyph must change nothing.
        checks = [(m, cx, {cp: {cx.cur[cp]} for cp in live}) for (ci, si), cx in steps.items()
                  for m in [CONFIGS[ci][si][1]] if cx.live]
        checks += [(m, cx, final) for _, m, cx in pos if cx.live]
        LAST_AAT[:] = checks
        for m, cx, gl in checks:
            for cp in live:
                if st[cp] == "P" or cp in blocked:
                    continue
                for g in gl[cp]:
                    for s0 in cx.starts:
                        for d in cx.depths:
                            try:
                                out, dl = simulate(m, cx, [g], s0, True, d, consumed=1)[:2]
                                if out != [g] or any(dl):
                                    blocked.setdefault(cp, f"{m.name}: end of text changes this glyph")
                            except StaleAccess as e:
                                return blocked, f"{e} (at end of text)", set(), glyphs_of, m_eff
                            except Unprovable as e:
                                blocked.setdefault(cp, f"{e} (at end of text)")
    except Unprovable as e:
        return blocked, str(e), set(), glyphs_of, M_ISLAND
    # Each failing island string loses its cheapest character (greedy hitting set).
    while fails:
        count = {}
        for w, _ in fails:
            for cp in set(w):
                count[cp] = count.get(cp, 0) + 1
        best = min(count, key=lambda cp: (freq(cp) / count[cp], cp))
        blocked.setdefault(best, "island lemma fails: " + next(r for w, r in fails if best in w))
        fails = [(w, r) for w, r in fails if best not in w]
    status.update(st)
    for cp in live:
        glyphs_of[cp] |= final[cp]
    return blocked, None, produced, glyphs_of, m_eff


def single_reach():
    """Glyphs each glyph can become under the active single substitutions (GSUB type 1
    lookups a feature applies to every glyph they cover: context-free, so a character
    keeps one glyph wherever it stands, and its measured width is that glyph's). The
    identity plus every image, closed under repeated application in any order (a
    superset of what the lookup order allows)."""
    if "GSUB" not in font or "morx" in font:
        return {}
    maps = [st.mapping for lk in active_lookups("GSUB")[1] for typ, st in subtables(lk, 7) if typ == 1]
    reach = {}
    for g in set(nominal.values()):
        seen, todo = {g}, [g]
        while todo:
            x = todo.pop()
            for m in maps:
                y = m.get(x)
                if y is not None and y not in seen:
                    seen.add(y)
                    todo.append(y)
        reach[g] = seen
    return reach


REACH = single_reach()


def reach_of(cp):
    return REACH.get(nominal[cp], {nominal[cp]})


MARK_INFO = {}  # mark -> (kerning modes, exclusions), from the last round


def run_round():
    """One pass of the analysis given the current unsafe set. Returns
    (status per char, new unsafe reasons, island bound)."""
    live = [cp for cp in chars if cp not in unsafe]
    status = {cp: "S" for cp in live}
    blocked = {}

    def promote(cps, cls):
        for cp in cps:
            if cp in status and (cls == "P" or status[cp] == "S"):
                status[cp] = cls

    outputs = set()       # glyphs substitutions can produce

    # ---------------- GSUB: which ligatures can form at all
    ot_ligs = []
    mark_ligs = []  # (head, first mark): a base and an uncomposed mark the font joins
    mark_only_ligs = []  # (marks, mark glyph): marks the font joins into one mark
    gsub_lookups = active_lookups("GSUB")[1] if "GSUB" in font else []
    for lk in gsub_lookups:
        for typ, st in subtables(lk, 7):
            if typ == 4:
                for head, ligs in st.ligatures.items():
                    for lig in ligs:
                        comps = list(lig.Component)
                        if head not in MARK_GLYPHS and comps and comps[0] in MARK_GLYPHS:
                            mark_ligs.append((head, comps[0]))
                        elif head in MARK_GLYPHS and all(c in MARK_GLYPHS for c in comps) and \
                                gdef_class.get(lig.LigGlyph) == 3:
                            # Marks joined into one mark (shadda and a vowel): no width
                            # either way; kerning must treat the result as its parts.
                            mark_only_ligs.append(([head] + comps, lig.LigGlyph))
                        else:
                            ot_ligs.append((head, comps, lig.LigGlyph))
    present = {g for cp in live for g in reach_of(cp)}
    formed = []
    changed = True
    while changed:
        changed = False
        for head, comps, out in ot_ligs:
            if out not in outputs and head in present | outputs and all(c in present | outputs for c in comps):
                outputs.add(out)
                formed.append((head, comps, out))
                changed = True
    for head, comps, out in formed:
        promote([cp for cp in live if head in reach_of(cp)], "P")
        promote([cp for cp in live if reach_of(cp) & set(comps)], "K")
    for cp in live:
        if cp in MARKS and (status[cp] != "S" or any(g not in MARK_GLYPHS for g in reach_of(cp))):
            blocked.setdefault(cp, "mark in a ligature or substituted to a non-mark")
    excl = {}  # mark -> characters next to which a rule can fire on it (left uncomposed)
    mode = {}  # mark -> set of: kerning skips it (True), stops at it (False)
    # A ligature of a base and a mark (ccmp: the font's own compositions, also for
    # pairs Unicode has no composite for). HarfBuzz composes the pairs the cmap has
    # first; the rest reach the ligature, so the breaker leaves those to Flutter.
    for head, mk in mark_ligs:
        bases = [cp for cp in live if head in reach_of(cp)]
        for cp in live:
            if mk in reach_of(cp):
                excl.setdefault(cp, set()).update(bases)

    # ---------------- AAT: morx, and the kerx / kern state machines
    aat_blocked, font_wide_fail, aat_outputs, glyphs_of, m_eff = analyse_aat(live, status, formed)
    outputs |= aat_outputs
    for cp in live:
        glyphs_of[cp] = set(glyphs_of[cp]) | reach_of(cp)
    for cp, why in aat_blocked.items():
        blocked.setdefault(cp, why)
    island_chars = [cp for cp in live if status[cp] != "S"]
    if font_wide_fail:
        for cp in live:
            blocked.setdefault(cp, font_wide_fail)

    # Every glyph a character can have where GSUB or GPOS sees it (nominal, or after the morx chain).
    gstar = {g for cp in live for g in glyphs_of[cp]} | outputs
    glyph_chars = {}
    for cp in live:
        for g in glyphs_of[cp]:
            glyph_chars.setdefault(g, []).append(cp)

    def block_glyphs(glyphs, reason):
        hit = set(glyphs) & gstar
        for g in hit:
            for cp in glyph_chars.get(g, []):
                blocked.setdefault(cp, reason)
        if hit & outputs:
            for cp in island_chars:
                blocked.setdefault(cp, reason + " (on a substitution output)")

    def weight(gs):
        w = sum(freq(cp) for g in gs for cp in glyph_chars.get(g, []))
        if gs & outputs:
            w += sum(freq(cp) for cp in island_chars)
        return w

    def block_rule(pos, reason):
        live_sets = []
        for s in pos:
            gs = (gstar - s[1]) if isinstance(s, tuple) else (s & gstar)
            if not gs:
                return  # some position can never match: the rule cannot fire
            live_sets.append(gs)
        # Positions that hold only marks, and others that hold only other characters
        # (a few): the rule can fire only on a mark left uncomposed in a cluster whose
        # base, or the base after it, is one of those characters (they are the only
        # non-marks it can match). The breaker hands such clusters to Flutter (the
        # mark's exclusions) instead.
        mark_pos = [x for x in live_sets if x & MARK_GLYPHS]
        other_pos = [x for x in live_sets if not x & MARK_GLYPHS]
        others = set().union(*other_pos) if other_pos else set()
        if mark_pos and other_pos and len(others) <= 256 and not others & outputs:
            near = {c for g in others for c in glyph_chars.get(g, [])}
            rest = set()
            for ms in mark_pos:
                for g in ms & MARK_GLYPHS:
                    for cp in glyph_chars.get(g, []):
                        excl.setdefault(cp, set()).update(near)
                rest |= ms - MARK_GLYPHS  # glyphs in a mark position that are not GDEF marks
            if rest:
                block_glyphs(min([rest, others], key=weight), reason)
            return
        block_glyphs(min(live_sets, key=weight), reason)

    def skips(lk, g):
        """Whether lookup lk skips mark glyph g when it looks for the next glyph."""
        flag = lk.LookupFlag
        if flag & 0x8:
            return True
        if flag & 0x10 and "GDEF" in font and font["GDEF"].table.MarkGlyphSetsDef:
            sets = font["GDEF"].table.MarkGlyphSetsDef.Coverage
            return lk.MarkFilteringSet >= len(sets) or g not in set(sets[lk.MarkFilteringSet].glyphs)
        if flag & 0xFF00 and "GDEF" in font and font["GDEF"].table.MarkAttachClassDef:
            return font["GDEF"].table.MarkAttachClassDef.classDefs.get(g, 0) != flag >> 8
        return False

    # ---------------- GSUB: everything but ligatures that can fire on present glyphs
    for lk in gsub_lookups:
        for typ, st in subtables(lk, 7):
            if typ == 1:
                pass  # in glyphs_of: each character's glyph is fixed (single_reach)
            elif typ == 2:
                block_glyphs(st.mapping, "GSUB multiple substitution")
            elif typ == 3:
                block_glyphs(st.alternates, "GSUB alternate substitution")
            elif typ in (5, 6, 8):
                kind = {5: "context", 6: "chain", 8: "reverse"}[typ]
                if marks_only(st, kind, "GSUB"):
                    continue
                for pos in rule_positions(st, kind):
                    block_rule(pos, f"GSUB contextual rule (type {typ})")
            elif typ != 4:
                raise SystemExit(f"unknown GSUB lookup type {typ}")

    # ---------------- positioning
    if "GPOS" in font:
        for lk in active_lookups("GPOS")[1]:
            for typ, st in subtables(lk, 9):
                cov = []
                if typ == 2:
                    cov = st.Coverage.glyphs
                    if st.ValueFormat2:
                        block_glyphs(cov, "PairPos with ValueFormat2 skips the next pair")
                    # Marks: skipped, or the pair stops at them; never kerned themselves.
                    if st.Format == 1:
                        second = {r.SecondGlyph for ps in st.PairSet for r in ps.PairValueRecord}
                        every2 = False
                    else:
                        second = set((st.ClassDef2.classDefs if st.ClassDef2 else {}).keys())
                        every2 = any(c1.Class2Record[0].Value1 is not None and
                                     any(getattr(c1.Class2Record[0].Value1, a, 0) for a in c1.Class2Record[0].Value1.__dict__)
                                     for c1 in st.Class1Record)
                    for g in MARK_GLYPHS & gstar:
                        sk = skips(lk, g)
                        for cp in glyph_chars.get(g, []):
                            mode.setdefault(cp, set()).add(sk)
                        if not sk and (g in cov or g in second or every2):
                            block_glyphs([g], "a mark in pair kerning")
                    for parts, out in mark_only_ligs:
                        sk = skips(lk, out)
                        if (not sk and (out in cov or out in second or every2)) or \
                                any(skips(lk, g) != sk for g in parts):
                            block_glyphs(parts, "marks joined into a mark kerning differently")
                elif typ == 3:
                    cov = st.Coverage.glyphs
                    block_glyphs(cov, "cursive attachment")
                elif typ in (4, 5):
                    # Mark attachment moves marks, never advances; GDEF marks' advances are
                    # zeroed after positioning. Only glyphs that are not GDEF marks matter.
                    cov = [g for g in st.MarkCoverage.glyphs if gdef_class.get(g) != 3]
                    block_glyphs(cov, "mark attachment")
                elif typ == 6:
                    cov = [g for g in st.Mark1Coverage.glyphs if gdef_class.get(g) != 3]
                    block_glyphs(cov, "mark attachment")
                elif typ in (7, 8):
                    kind = "context" if typ == 7 else "chain"
                    if marks_only(st, kind, "GPOS"):
                        continue
                    for pos in rule_positions(st, kind):
                        block_rule(pos, f"GPOS contextual rule (type {typ})")
                elif typ != 1:
                    raise SystemExit(f"unknown GPOS lookup type {typ}")
                if typ != 1 and lk.LookupFlag & 0x2:
                    block_glyphs(cov, "lookup ignores base glyphs")
                if typ != 1 and lk.LookupFlag & 0x4 and any(gdef_class.get(g) == 2 for g in gstar):
                    block_glyphs(cov, "lookup ignores ligatures")
    # kern formats 0, 2, 3 and kerx formats 0, 2, 6 are pair kerning (hb_kern_machine_t); kerx format 4
    # and cross-stream subtables only move offsets. Format 1 state machines are analysed above.
    # HarfBuzz's kern machine skips marks; marks in an AAT font are not modelled.
    if "kerx" in font or "morx" in font:
        block_glyphs(MARK_GLYPHS, "mark in an AAT font")
    elif "kern" in font:
        kerned = set()
        for kt in font["kern"].kernTables:
            if getattr(kt, "format", None) == 0:
                kerned |= {g for pair in kt.kernTable for g in pair}
            else:
                kerned |= MARK_GLYPHS
        block_glyphs(MARK_GLYPHS & kerned, "a mark in kern table pairs")
        for cp in live:
            if cp in MARKS:
                mode.setdefault(cp, set()).add(True)
    for cp, m in mode.items():
        if len(m) > 1:
            blocked.setdefault(cp, "kerning lookups disagree on skipping the mark")
    MARK_INFO.clear()
    MARK_INFO.update({cp: (mode.get(cp, {True}), excl.get(cp, set())) for cp in live if cp in MARKS})
    return status, blocked, m_eff


def certify(extra):
    """Rounds until one blocks nothing (only such a round is a proof; each round removes characters, so
    this terminates), starting from the fixed unsafe set plus `extra`. Returns (unsafe, final classes,
    island bound, rounds, live AAT machines of the last round)."""
    unsafe.clear()
    unsafe.update(BASE_UNSAFE)
    for cp, why in extra.items():
        unsafe.setdefault(cp, why)
    n = 0
    while True:
        n += 1
        status, blocked, m_last = run_round()
        if not blocked:
            break
        for cp, why in blocked.items():
            unsafe.setdefault(cp, why)
    return dict(unsafe), {cp: ("U" if cp in unsafe else status[cp]) for cp in chars}, m_last, n, list(LAST_AAT)


SAMPLE = random.Random(20261103).choices(chars, [freq(cp) for cp in chars], k=40 * 1500) if chars else []


def score(classes, m):
    """Share of 40-character pseudo-lines, drawn from the character frequencies, that the theorem
    covers: no U character, and every P/K run holding a primer at most m long."""
    ok = 0
    for i in range(0, len(SAMPLE), 40):
        run, primer, good = 0, False, True
        for cp in SAMPLE[i:i + 40] + [None]:
            c = classes[cp] if cp is not None else "S"
            if c == "U":
                good = False
                break
            if c in "PK":
                run, primer = run + 1, primer or c == "P"
                continue
            if primer and run > m:
                good = False
                break
            run, primer = 0, False
        ok += good
    return ok / max(1, len(SAMPLE) // 40)


def trigger_sets(classes, machines, m_isl):
    """Characters to make unsafe so that a live AAT machine stops making other characters P/K: for each
    machine, the characters of each class it can act on, and all of them together, ranked by the
    estimated gain in score() from that machine alone."""
    live = [cp for cp in chars if classes[cp] != "U"]
    base, out = score(classes, m_isl), []
    for m, cx, curset in machines:
        by_class = {}
        for g in cx.present:
            by_class.setdefault(m.cls(g), set()).add(g)
        acting = {k for k, gs in by_class.items() if any(acts(m, cx, m.entry(s, k), gs) for s in cx.reach)}
        groups = [{cp for cp in live if any(m.cls(g) == k for g in curset[cp])} for k in acting]

        def not_s(cps, present):
            cx2, st = Step(), {cp: "S" for cp in cps}
            cx2.present = present
            classify(m, cx2, cps, curset, st)
            return {cp for cp in cps if st[cp] != "S"}
        before = not_s(live, cx.present)
        for t in [set().union(*groups)] + groups if groups else []:
            rest = [cp for cp in live if cp not in t]
            present = (cx.present - {g for cp in t for g in curset[cp]}) | {g for cp in rest for g in curset[cp]}
            est = dict(classes)
            est.update({cp: "U" for cp in t})
            est.update({cp: "S" for cp in before - not_s(rest, present) - t})
            gain = score(est, m_isl) - base
            if t and gain > 0:
                out.append((gain, sorted(t), m.name))
    return sorted(out, reverse=True)


# A machine that is context-dependent on common letters (smart quotes, accent composition) can make
# almost every character P/K. Making its trigger characters U instead is always sound; keep it when
# the frequency-weighted share of S characters grows.
BASE_UNSAFE = dict(unsafe)
extra = {}
unsafe_now, final, m_final, rounds, machines = certify(extra)
for _ in range(4):
    for gain, t, name in trigger_sets(final, machines, m_final)[:3]:
        trial = dict(extra)
        trial.update({cp: f"triggers {name}, which would make common letters P/K" for cp in t})
        result = certify(trial)
        if score(result[1], result[2]) > score(final, m_final) + 1e-9:
            extra, (unsafe_now, final, m_final, rounds, machines) = trial, result
            break
    else:
        break
unsafe.clear()
unsafe.update(unsafe_now)
def pair_free():
    """True when no positioning depends on the neighbouring glyph: no active GPOS
    pair, cursive or contextual positioning lookup, and no kern or kerx table.
    Every pair term is then zero, and the distiller need not measure pairs (CJK
    fonts with tens of thousands of characters)."""
    if "kern" in font or "kerx" in font:
        return False
    if "GPOS" in font:
        for lk in active_lookups("GPOS")[1]:
            if any(typ in (2, 3, 7, 8) for typ, _ in subtables(lk, 9)):
                return False
    return True


def pair_sets():
    """Glyphs that can be the first, and the second, glyph of a pair adjustment:
    GPOS pair positioning (first: its coverage; second: the listed second glyphs
    or ClassDef2 classes, or every glyph when class 0 carries a value), cursive
    attachment (its coverage, both sides), kern format 0 pairs. None means every
    glyph: contextual positioning, kerx, other kern formats."""
    first, second, every2 = set(), set(), False
    if "kerx" in font:
        return None, None
    if "kern" in font:
        for kt in font["kern"].kernTables:
            if getattr(kt, "format", None) != 0:
                return None, None
            for left, right in kt.kernTable:
                first.add(left)
                second.add(right)
    if "GPOS" in font:
        for lk in active_lookups("GPOS")[1]:
            for typ, st in subtables(lk, 9):
                if typ == 2:
                    first.update(st.Coverage.glyphs)
                    if st.Format == 1:
                        for ps in st.PairSet:
                            second.update(r.SecondGlyph for r in ps.PairValueRecord)
                    else:
                        second.update((st.ClassDef2.classDefs if st.ClassDef2 else {}).keys())
                        for c1 in st.Class1Record:
                            v = c1.Class2Record[0].Value1
                            if v is not None and any(getattr(v, a, 0) for a in v.__dict__):
                                every2 = True
                elif typ == 3:
                    first.update(st.Coverage.glyphs)
                    second.update(st.Coverage.glyphs)
                elif typ in (7, 8):
                    return None, None
    return first, (None if every2 else second)


# Common characters (spaces, digits, punctuation; the breaker's scriptOf) take the
# script of the run they are in, and a run of them alone is shaped with DFLT. The
# sidecar measures them under the main script's lookups (a run of them alone is
# measured next to a letter of it when DFLT differs). For each other script whose
# lookups differ, the Common characters and Common pairs a differing lookup can
# change: the breaker hands those to the engine in a run of that script. Mark
# attachment never changes an advance, and AAT and kern tables do not depend on
# the script.
def is_common(cp):
    if (cp | 0x20) >= 0x61 and (cp | 0x20) <= 0x7A:
        return False
    if cp < 0xC0:
        return cp not in (0xAA, 0xBA)
    if cp < 0x250:
        return cp in (0xD7, 0xF7)
    if 0x370 <= cp < 0x400:
        return cp in (0x374, 0x37E, 0x385, 0x387)
    if 0x400 <= cp < 0x500 or 0x590 <= cp < 0x600:
        return False
    if 0x600 <= cp < 0x700:
        return cp in (0x60C, 0x61B, 0x61F, 0x640)
    return not (0x3041 <= cp <= 0x309A or 0x30A1 <= cp <= 0x30FA or cp in (0x3005, 0x3007) or 0x3021 <= cp <= 0x3029
                or 0x3400 <= cp <= 0x9FFF or 0xF900 <= cp <= 0xFAFF or 0xAC00 <= cp <= 0xD7A3)


def script_variance():
    main = "latn" if os.environ.get("CERTIFY_DIRECTION") != "rtl" else ("hebr" if "hebr" in SCRIPT_TAGS else "arab")
    others = ["DFLT"] if main != "latn" else ["DFLT"] + [t for t in SCRIPT_TAGS if t != "latn"]
    common = [cp for cp in chars if is_common(cp)]
    owner = {}
    for cp in common:
        for g in reach_of(cp):
            owner.setdefault(g, set()).add(cp)
    cg = set(owner)

    def nz(v):
        return v is not None and any(getattr(v, k, 0) for k in ("XPlacement", "YPlacement", "XAdvance", "YAdvance",
                                                                  "XPlaDevice", "XAdvDevice"))

    def touched(lk, T):
        singles, pairs = set(), set()
        for typ, st in subtables(lk, 7 if T == "GSUB" else 9):
            cov = set(st.Coverage.glyphs) if getattr(st, "Coverage", None) else set()
            if T == "GPOS" and typ in (4, 5, 6):
                continue  # attachment: offsets only
            if T == "GPOS" and typ == 1:
                vals = [st.Value] * len(st.Coverage.glyphs) if st.Format == 1 else st.Value
                singles |= {g for g, v in zip(st.Coverage.glyphs, vals) if g in cg and nz(v)}
            elif T == "GPOS" and typ == 2:
                if st.Format == 1:
                    for g, ps in zip(st.Coverage.glyphs, st.PairSet):
                        if g in cg:
                            pairs |= {(g, r.SecondGlyph) for r in ps.PairValueRecord
                                      if r.SecondGlyph in cg and (nz(r.Value1) or nz(r.Value2))}
                else:
                    c1, c2 = st.ClassDef1.classDefs if st.ClassDef1 else {}, st.ClassDef2.classDefs if st.ClassDef2 else {}
                    for g in cov & cg:
                        row = st.Class1Record[c1.get(g, 0)].Class2Record
                        pairs |= {(g, h) for h in cg if nz(row[c2.get(h, 0)].Value1) or nz(row[c2.get(h, 0)].Value2)}
            elif T == "GSUB" and typ == 1:
                singles |= {g for g, r in st.mapping.items() if g in cg and r != g}
            elif T == "GSUB" and typ in (2, 3):
                singles |= {g for g in (st.mapping if typ == 2 else st.alternates) if g in cg}
            elif T == "GSUB" and typ == 4:
                for g, ligs in st.ligatures.items():
                    for lg in ligs:
                        if g in cg and all(c in cg for c in lg.Component):
                            singles |= {g, *lg.Component}
            else:
                # Contextual, chaining, reverse, cursive: every Common glyph it covers,
                # or every Common glyph when its coverage is by class.
                seen = set(cov)
                for name in ("InputCoverage", "LookAheadCoverage", "BacktrackCoverage", "EntryExitRecord"):
                    for c in (getattr(st, name, None) or []):
                        seen |= set(getattr(c, "glyphs", []))
                singles |= (seen & cg) if seen else set(cg)
        return singles, pairs

    out = {}
    for tag in others:
        chars_, pairs_ = set(), set()
        for T in ("GSUB", "GPOS"):
            if T not in font or not font[T].table.ScriptList:
                continue
            t, lm = active_lookups(T, [main])
            _, lo = active_lookups(T, [tag])
            ids_m = {id(x) for x in lm}
            ids_o = {id(x) for x in lo}
            for lk in [x for x in lm if id(x) not in ids_o] + [x for x in lo if id(x) not in ids_m]:
                si, pa = touched(lk, T)
                chars_ |= {cp for g in si for cp in owner[g]}
                pairs_ |= {(a, b) for g, h in pa for a in owner[g] for b in owner[h]}
        if chars_ or pairs_:
            out[tag] = (chars_, pairs_ - {(a, b) for a, b in pairs_ if a in chars_ or b in chars_})
    return out


SCRIPT_VARIANCE = {} if "morx" in font else script_variance()

with open(out_path, "w") as fp:
    free = pair_free()
    fp.write(f"# {font['name'].getDebugName(4)} m={m_final}{' pairs=none' if free else ''}\n")
    # A fourth column says whether the character's glyph can be the first (f) or
    # second (s) glyph of a pair adjustment; the distiller measures only those
    # pairs. P and K characters are marked both ways (their substitutes may pair).
    # The column covers pairs of characters that are not combining marks: the
    # breaker never accepts those (they are outside its line-break table).
    p1, p2 = (set(), set()) if free else pair_sets()
    # Compositions HarfBuzz makes (base, mark, composite in the font), for the breaker.
    for b, mk, c in COMPOSE:
        fp.write(f"# compose {b:04X} {mk:04X} {c:04X}\n")
    for tag, (cs, ps) in sorted(SCRIPT_VARIANCE.items()):
        fp.write(f"# script {tag} chars {' '.join(f'{cp:04X}' for cp in sorted(cs)) or '-'}"
                 f" pairs {' '.join(f'{a:04X}:{b:04X}' for a, b in sorted(ps)) or '-'}\n")
    for cp in chars:
        g = nominal[cp]
        gs = reach_of(cp)
        # Combining marks too: HarfBuzz sets their advance by Unicode category, so
        # the character before one can change width with it (measured: Roboto's
        # U+0387 next to U+0488).
        island = final[cp] in ("P", "K") or unicodedata.category(chr(cp)).startswith("M")
        f = "f" if island or p1 is None or gs & p1 else ""
        s2 = "s" if island or p2 is None or gs & p2 else ""
        if cp in MARKS and final[cp] == "S":
            # A mark: combining class, whether kerning skips it, and characters next to
            # which it must not be left uncomposed.
            modes, near = MARK_INFO.get(cp, ({True}, set()))
            fp.write(f"{cp:04X} {gid[g]} M {unicodedata.combining(chr(cp))} {'skip' if True in modes else 'break'} "
                     f"{','.join(f'{x:04X}' for x in sorted(near)) or '-'}\n")
            continue
        fp.write(f"{cp:04X} {gid[g]} {final[cp]} {f + s2 or '-'}\n")

if os.environ.get("CERTIFY_DUMP"):
    # One line per simulated island: its text, then the chain's output glyphs under each subtable
    # sequence (deleted glyphs dropped, as HarfBuzz does before positioning).
    with open(os.environ["CERTIFY_DUMP"], "w", encoding="utf-8") as fp:
        for w, bufs in ISLAND_DUMP.items():
            fp.write("".join(chr(cp) for cp in w) + "\t" + "\t".join(
                "|".join(str(glyph_id(g)) for g in b if g != DELETED) for b in bufs) + "\n")

counts = {c: sum(1 for cp in chars if final[cp] == c) for c in "SPKU"}
top_u = max((cp for cp in chars if final[cp] == "U"), key=freq, default=None)
if top_u is not None:
    print(f"top unsafe: U+{top_u:04X} {unsafe[top_u]}")
cover = sum(freq(cp) for cp in chars if final[cp] != "U") / sum(freq(cp) for cp in chars)
print(f"{font['name'].getDebugName(4)}: S {counts['S']}  P {counts['P']}  K {counts['K']}  U {counts['U']}"
      f"  (rounds {rounds}, non-U share of English text ~{100 * cover:.1f}%)")
for c in "PKU":
    group = [cp for cp in chars if final[cp] == c]
    if group:
        shown = sorted(group, key=lambda cp: -freq(cp))[:20]
        reasons = sorted({unsafe[cp] for cp in shown}) if c == "U" else []
        print(f"  {c}: " + "".join(chr(cp) for cp in shown) + ("…" if len(group) > 20 else "")
              + (("   [" + " | ".join(reasons)[:220] + "]") if reasons else ""))
