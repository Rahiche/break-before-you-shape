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
     P/K glyphs only. AAT: from every reachable state an S class either behaves
     as from the start state or is a pure reset (DontAdvance back to a start
     state); both start states agree on P/K classes; end of text has no effect;
     and no action inside a run of <= m glyphs reaches a ligature component or
     mark set before the run;
  3. positioning on every glyph that can occur is pair-additive: SinglePos, or
     PairPos with ValueFormat2 == 0 (otherwise the next pair is skipped), or
     kern format 0. Cursive, mark and contextual positioning are blocked.

A contextual rule (GSUB 5/6/8, GPOS 7/8) can fire only if every position can
match some glyph that can occur; for each live rule, the characters of its
cheapest position (weighted by English letter frequency) are made unsafe, which
makes the rule unmatchable on any certified line.

The analysis over-approximates what HarfBuzz enables: all scripts and language
systems, every feature HarfBuzz may turn on for horizontal Latin text, all
feature variations, and every AAT subtable enabled by default flags or by any
ligature / contextual-alternate selector. Over-approximating only adds U.

bfl.c then checks the model exhaustively on every island up to length m in every
S context, and checks that no model term spans an island with S on both sides.

usage: certify.py font[:index] out.cert [m] [hb|all]
"""
import itertools
import os
import sys
import unicodedata

from fontTools.ttLib import TTFont

RANGES = [(0x20, 0x7E), (0xA0, 0x24F), (0x2B0, 0x2FF), (0x2010, 0x2027), (0x2030, 0x205E), (0x20AC, 0x20AC),
          (0x2122, 0x2122)]
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
make_unsafe([cp for cp in chars if gdef_class.get(nominal[cp]) == 3], "GDEF mark")


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


def active_lookups(tag):
    """Lookups HarfBuzz applies for the scripts in SCRIPT_TAGS (each falling back to
    DFLT), language en, default variation coordinates. With SELECT == "all", every
    script, language system and feature variation instead (a strict
    over-approximation)."""
    t = font[tag].table
    if not t.FeatureList:
        return t, []
    feats = list(t.FeatureList.FeatureRecord)
    tables = {i: fr.Feature for i, fr in enumerate(feats)}
    fv = getattr(t, "FeatureVariations", None)
    if fv:
        def holds(rec):
            return all(c.FilterRangeMinValue <= 0 <= c.FilterRangeMaxValue for c in rec.ConditionSet.ConditionTable)
        recs = fv.FeatureVariationRecord if SELECT == "all" else [r for r in fv.FeatureVariationRecord if holds(r)][:1]
        for rec in recs:
            for sub in rec.FeatureTableSubstitution.SubstitutionRecord:
                if SELECT == "all":
                    tables.setdefault(("alt", sub.FeatureIndex, id(sub)), sub.Feature)
                    feats.append(type("F", (), {"FeatureTag": feats[sub.FeatureIndex].FeatureTag})())
                    tables[len(feats) - 1] = sub.Feature
                else:
                    tables[sub.FeatureIndex] = sub.Feature
    langsys = []
    scripts = {sr.ScriptTag: sr.Script for sr in (t.ScriptList.ScriptRecord if t.ScriptList else [])}
    if SELECT == "all":
        for sc in scripts.values():
            langsys += [sc.DefaultLangSys] + [r.LangSys for r in sc.LangSysRecord]
    else:
        for tag in SCRIPT_TAGS:
            sc = scripts.get(tag) or scripts.get("DFLT") or scripts.get("dflt")
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
            if SELECT == "all":
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


def run_round():
    """One pass of the analysis given the current unsafe set. Returns
    (status per char, new unsafe reasons, notes)."""
    live = [cp for cp in chars if cp not in unsafe]
    status = {cp: "S" for cp in live}
    blocked = {}
    notes = []

    def promote(cps, cls):
        for cp in cps:
            if cp in status and (cls == "P" or status[cp] == "S"):
                status[cp] = cls

    # Current glyph per character after context-free AAT substitutions.
    cur = dict(nominal)
    outputs = set()       # glyphs substitutions can produce
    island_lemma = True
    font_wide_fail = None

    # ---------------- GSUB: which ligatures can form at all
    ot_ligs = []
    gsub_lookups = active_lookups("GSUB")[1] if "GSUB" in font else []
    for lk in gsub_lookups:
        for typ, st in subtables(lk, 7):
            if typ == 4:
                for head, ligs in st.ligatures.items():
                    for lig in ligs:
                        ot_ligs.append((head, list(lig.Component), lig.LigGlyph))
    present = {nominal[cp] for cp in live}
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
        promote([cp for cp in live if nominal[cp] == head], "P")
        promote([cp for cp in live if nominal[cp] in comps], "K")

    # ---------------- morx
    if "morx" in font:
        for chain in font["morx"].table.MorphChain:
            flags = chain.DefaultFlags
            for fe in chain.MorphFeature:
                if (fe.FeatureType, fe.FeatureSetting) in AAT_DEFAULT_SELECTORS or \
                        (SELECT == "all" and fe.FeatureType in AAT_FEATURE_TYPES):
                    flags |= fe.EnableFlags
            for st in chain.MorphSubtable:
                if not (st.SubFeatureFlags & flags) or st.TextDirection == "Vertical":
                    continue
                ss = st.SubStruct
                if st.MorphType == 4:
                    mp = ss.Substitution
                    for cp in live:
                        cur[cp] = mp.get(cur[cp], cur[cp])
                    outputs |= {mp[g] for g in outputs if g in mp}
                    continue
                if st.MorphType in (0, 5):
                    # Rearrangement and insertion: identity unless an action can be
                    # reached over the alphabet; otherwise not analysed further.
                    stt0 = ss.StateTable
                    gc0 = stt0.GlyphClasses

                    def act0(e, t=st.MorphType):
                        return e.Verb != 0 if t == 0 else bool(e.CurrentInsertionAction or e.MarkedInsertionAction)

                    alpha0 = {gc0.get(cur[cp], 1) for cp in live} | {gc0.get(g, 1) for g in outputs} | {DELETED}
                    reach0, todo0 = {0, 1}, [0, 1]
                    while todo0:
                        s0 = todo0.pop()
                        for k in alpha0:
                            ns = stt0.States[s0].Transitions[k].NewState
                            if ns not in reach0:
                                reach0.add(ns)
                                todo0.append(ns)
                    if any(act0(stt0.States[s0].Transitions[k]) for s0 in reach0 for k in alpha0 | {EOT}):
                        font_wide_fail = f"morx subtable type {st.MorphType} can act on this alphabet"
                    continue
                if st.MorphType not in (1, 2) or st.ProcessingOrder != "LayoutOrder":
                    font_wide_fail = f"unsupported morx subtable type {st.MorphType}"
                    continue
                stt = ss.StateTable
                gc = stt.GlyphClasses
                lig = st.MorphType == 2

                def cls(g):
                    return gc.get(g, 1)

                def entry(s, k):
                    return stt.States[s].Transitions[k]

                def key(e):
                    if lig:
                        return (e.NewState, e.SetComponent, e.DontAdvance, repr(e.Actions))
                    return (e.NewState, e.SetMark, e.DontAdvance, e.MarkIndex, e.CurrentIndex)

                def acts(e):
                    # Substitutes something. Pushing a component or setting a mark only
                    # stores state; the bounded check below shows no action inside an
                    # island ever reaches state stored before the island.
                    if lig:
                        return bool(e.Actions)
                    return e.MarkIndex != 0xFFFF or e.CurrentIndex != 0xFFFF

                def eot_acts(e):
                    return bool(e.Actions) if lig else (e.MarkIndex != 0xFFFF or e.CurrentIndex != 0xFFFF)

                alphabet = {cls(cur[cp]) for cp in live} | {cls(g) for g in outputs} | {DELETED}
                reach, todo = {0, 1}, [0, 1]
                while todo:
                    s = todo.pop()
                    for k in alphabet:
                        ns = entry(s, k).NewState
                        if ns not in reach:
                            reach.add(ns)
                            todo.append(ns)
                # A subtable whose actions cannot be reached over this alphabet (for
                # example a composition machine waiting for combining marks that are not
                # in the repertoire) is the identity on every string we certify.
                live_action = any(acts(entry(s, k)) for s in reach for k in alphabet) or \
                    any(eot_acts(entry(s, EOT)) for s in reach)
                if not live_action:
                    continue
                if any(eot_acts(entry(s, EOT)) for s in (0, 1)):
                    font_wide_fail = "end-of-text acts from a start state"
                if any(eot_acts(entry(s, EOT)) for s in reach):
                    island_lemma = False
                    notes.append("end-of-text acts after an island")
                for cp in live:
                    k = cls(cur[cp])
                    # From each start state: no substitution, stay in a start state.
                    quiet = all(not acts(entry(s, k)) and not entry(s, k).DontAdvance and entry(s, k).NewState in (0, 1)
                                for s in (0, 1))
                    # From every reachable state: no substitution, and either back to a
                    # start state or a pure reset (DontAdvance into a start state, after
                    # which the quiet start transition applies).
                    if quiet and all(not acts(entry(s, k)) and entry(s, k).NewState in (0, 1) for s in reach):
                        continue
                    promote([cp], "K" if quiet else "P")
                island_cls = {cls(cur[cp]) for cp in live if status[cp] != "S"} | {cls(g) for g in outputs} | {DELETED}
                if any(key(entry(0, k)) != key(entry(1, k)) for k in island_cls | {EOT}):
                    island_lemma = False
                    notes.append("start states disagree on island classes")
                # Bounded check: no action inside a run of <= m island glyphs reaches
                # state set before the run.
                for n in range(1, M_ISLAND + 1):
                    if not island_lemma:
                        break
                    for seq in itertools.product(sorted(island_cls), repeat=n):
                        s, fresh, last_push, mark_set, pos, guard = 0, 0, -1, False, 0, 0
                        while pos < n:
                            e = entry(s, seq[pos])
                            if lig:
                                if e.SetComponent and last_push != pos:
                                    fresh, last_push = fresh + 1, pos
                                if e.Actions:
                                    if len(e.Actions) > fresh:
                                        island_lemma = False
                                        notes.append("ligature action may reach an earlier component")
                                        break
                                    fresh -= len(e.Actions)
                            else:
                                if e.MarkIndex != 0xFFFF and not mark_set:
                                    island_lemma = False
                                    notes.append("contextual action may reach an earlier mark")
                                    break
                                mark_set = mark_set or e.SetMark
                            s = e.NewState
                            if e.DontAdvance:
                                guard += 1
                                if guard > 8:
                                    island_lemma = False
                                    notes.append("DontAdvance loop")
                                    break
                            else:
                                pos, guard = pos + 1, 0
                        if not island_lemma:
                            break
                if lig:
                    outputs |= set(stt.Ligatures)
                else:
                    for table in stt.PerGlyphLookups:
                        outputs |= set(table.values())

    island_chars = [cp for cp in live if status[cp] != "S"]
    if font_wide_fail:
        for cp in live:
            blocked.setdefault(cp, font_wide_fail)
    if not island_lemma:
        for cp in island_chars:
            blocked.setdefault(cp, "island lemma fails: " + "; ".join(sorted(set(notes))))

    gstar = {cur[cp] for cp in live} | outputs
    glyph_chars = {}
    for cp in live:
        glyph_chars.setdefault(cur[cp], []).append(cp)

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
        block_glyphs(min(live_sets, key=weight), reason)

    # ---------------- GSUB: everything but ligatures that can fire on present glyphs
    for lk in gsub_lookups:
        for typ, st in subtables(lk, 7):
            if typ in (1, 2):
                block_glyphs(st.mapping, "GSUB single/multiple substitution")
            elif typ == 3:
                block_glyphs(st.alternates, "GSUB alternate substitution")
            elif typ in (5, 6, 8):
                for pos in rule_positions(st, {5: "context", 6: "chain", 8: "reverse"}[typ]):
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
                elif typ == 3:
                    cov = st.Coverage.glyphs
                    block_glyphs(cov, "cursive attachment")
                elif typ in (4, 5):
                    cov = st.MarkCoverage.glyphs
                    block_glyphs(cov, "mark attachment")
                elif typ == 6:
                    cov = st.Mark1Coverage.glyphs
                    block_glyphs(cov, "mark attachment")
                elif typ in (7, 8):
                    for pos in rule_positions(st, "context" if typ == 7 else "chain"):
                        block_rule(pos, f"GPOS contextual rule (type {typ})")
                elif typ != 1:
                    raise SystemExit(f"unknown GPOS lookup type {typ}")
                if typ != 1 and lk.LookupFlag & 0x2:
                    block_glyphs(cov, "lookup ignores base glyphs")
                if typ != 1 and lk.LookupFlag & 0x4 and any(gdef_class.get(g) == 2 for g in gstar):
                    block_glyphs(cov, "lookup ignores ligatures")
    if "kern" in font:
        for kt in font["kern"].kernTables:
            if getattr(kt, "format", None) != 0:
                for cp in live:
                    blocked.setdefault(cp, "kern subtable is not format 0")
    if "kerx" in font:
        # fontTools does not parse kerx; read the subtable headers directly. Pair
        # formats (0, 2, 6) are pair-additive; state-machine formats (1, 4) are not.
        data = font.getTableData("kerx")
        n = int.from_bytes(data[4:8], "big")
        off, bad = 8, None
        for _ in range(n):
            length = int.from_bytes(data[off:off + 4], "big")
            coverage = int.from_bytes(data[off + 4:off + 8], "big")
            fmt = coverage & 0xFF
            if coverage & 0xC0000000:
                pass  # vertical or cross-stream: no effect on horizontal advances
            elif fmt not in (0, 2, 6):
                bad = fmt
            off += length
        if bad is not None:
            for cp in live:
                blocked.setdefault(cp, f"kerx format {bad} is a state machine")
    return status, blocked, notes


for rounds in range(1, 50):
    status, blocked, notes = run_round()
    if not blocked:
        break
    for cp, why in blocked.items():
        unsafe.setdefault(cp, why)

final = {cp: ("U" if cp in unsafe else status[cp]) for cp in chars}


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


with open(out_path, "w") as fp:
    free = pair_free()
    fp.write(f"# {font['name'].getDebugName(4)} m={M_ISLAND}{' pairs=none' if free else ''}\n")
    # A fourth column says whether the character's glyph can be the first (f) or
    # second (s) glyph of a pair adjustment; the distiller measures only those
    # pairs. P and K characters are marked both ways (their substitutes may pair).
    # The column covers pairs of characters that are not combining marks: the
    # breaker never accepts those (they are outside its line-break table).
    p1, p2 = (set(), set()) if free else pair_sets()
    for cp in chars:
        g = nominal[cp]
        # Combining marks too: HarfBuzz sets their advance by Unicode category, so
        # the character before one can change width with it (measured: Roboto's
        # U+0387 next to U+0488).
        island = final[cp] in ("P", "K") or unicodedata.category(chr(cp)).startswith("M")
        f = "f" if island or p1 is None or g in p1 else ""
        s2 = "s" if island or p2 is None or g in p2 else ""
        fp.write(f"{cp:04X} {gid[g]} {final[cp]} {f + s2 or '-'}\n")

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
