// bfl.c — "break-first" line breaking prototype.
//
// 1. Distill: treat HarfBuzz as a black-box oracle and compile a font's shaping
//    behaviour into a k-gram width model: unigram advances, a pair-delta matrix
//    (kerning + 2-char ligatures, compressed into first/second-position classes),
//    and sparse 3/4-gram residuals around pairs whose glyphs change (ligatures,
//    contextual alternates). Random 3/4-gram probes and dictionary-word probes
//    measure what the model still misses; any miss becomes a per-pair error bound.
// 2. Break (model_break2): pass A builds a width prefix, pass B finds break
//    opportunities with NEON and records each line end / line-start origin, pass C
//    makes greedy decisions in O(1) per candidate. A decision is certified when W
//    lies outside [width - eps, width + eps]; otherwise (hybrid mode) only that one
//    candidate line is shaped. model_break is the simpler single-pass version,
//    kept as a cross-check.
// 3. Validate against exact greedy breaking that reshapes every candidate line,
//    and benchmark against shape-first and word-cache baselines.

#include <hb.h>
#include <hb-ot.h>
#include <arm_neon.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define MAXN 2048
#define BIG (1LL << 40)

static double now(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec + ts.tv_nsec * 1e-9;
}

static inline uint32_t dec(const uint8_t *t, uint32_t i, uint32_t *cp) {
  uint8_t c = t[i];
  if (c < 0x80) { *cp = c; return i + 1; }
  if (c < 0xE0) { *cp = ((c & 0x1F) << 6) | (t[i + 1] & 0x3F); return i + 2; }
  if (c < 0xF0) { *cp = ((c & 0x0F) << 12) | ((t[i + 1] & 0x3F) << 6) | (t[i + 2] & 0x3F); return i + 3; }
  *cp = ((c & 0x07) << 18) | ((t[i + 1] & 0x3F) << 12) | ((t[i + 2] & 0x3F) << 6) | (t[i + 3] & 0x3F);
  return i + 4;
}
static inline int isal(uint32_t c) { return (c | 0x20) - 'a' < 26; }

/* ---------------- sparse residual map ---------------- */

typedef struct { uint64_t key; int32_t val; } HEnt;
typedef struct { HEnt *e; uint64_t mask; uint32_t n; } HMap;

static inline uint64_t mix64(uint64_t x) {
  x ^= x >> 33; x *= 0xff51afd7ed558ccdULL; x ^= x >> 33; x *= 0xc4ceb9fe1a85ec53ULL; x ^= x >> 33;
  return x;
}
static void hm_init(HMap *h, int bits) {
  h->e = calloc(1ull << bits, sizeof(HEnt)); h->mask = (1ull << bits) - 1; h->n = 0;
}
static inline int32_t hm_get(const HMap *h, uint64_t k) {
  for (uint64_t i = mix64(k) & h->mask;; i = (i + 1) & h->mask) {
    if (h->e[i].key == k) return h->e[i].val;
    if (!h->e[i].key) return 0;
  }
}
static void hm_put(HMap *h, uint64_t k, int32_t v);
static void hm_grow(HMap *h) {
  HMap o = *h;
  hm_init(h, __builtin_ctzll(o.mask + 1) + 1);
  for (uint64_t i = 0; i <= o.mask; i++) if (o.e[i].key) hm_put(h, o.e[i].key, o.e[i].val);
  free(o.e);
}
static void hm_put(HMap *h, uint64_t k, int32_t v) {
  if (2 * (h->n + 1) > h->mask) hm_grow(h);
  uint64_t i = mix64(k) & h->mask;
  while (h->e[i].key && h->e[i].key != k) i = (i + 1) & h->mask;
  if (!h->e[i].key) h->n++;
  h->e[i].key = k; h->e[i].val = v;
}
#define K3(a, b, c) ((3ULL << 60) | ((uint64_t)(a) << 24) | ((uint64_t)(b) << 12) | (uint64_t)(c))
#define K4(z, a, b, c) ((4ULL << 60) | ((uint64_t)(z) << 36) | ((uint64_t)(a) << 24) | ((uint64_t)(b) << 12) | (uint64_t)(c))

/* ---------------- HarfBuzz helpers ---------------- */

static hb_buffer_t *B;
static hb_language_t LANG_EN;

static void props(void) {
  hb_buffer_set_direction(B, HB_DIRECTION_LTR);
  hb_buffer_set_script(B, HB_SCRIPT_LATIN);
  hb_buffer_set_language(B, LANG_EN);
}
static int32_t hb_w32(hb_font_t *f, const uint32_t *cps, int n, unsigned *ng, hb_codepoint_t *g) {
  hb_buffer_clear_contents(B);
  hb_buffer_add_utf32(B, cps, n, 0, n);
  props();
  hb_shape(f, B, NULL, 0);
  unsigned len;
  hb_glyph_info_t *inf = hb_buffer_get_glyph_infos(B, &len);
  hb_glyph_position_t *pos = hb_buffer_get_glyph_positions(B, &len);
  int32_t w = 0;
  for (unsigned i = 0; i < len; i++) w += pos[i].x_advance;
  if (ng) { *ng = len; for (unsigned i = 0; i < len && i < 4; i++) g[i] = inf[i].codepoint; }
  return w;
}
static __attribute__((noinline)) int32_t hb_w8(hb_font_t *f, const uint8_t *t, uint32_t n) {
  hb_buffer_clear_contents(B);
  hb_buffer_add_utf8(B, (const char *)t, n, 0, n);
  props();
  hb_shape(f, B, NULL, 0);
  unsigned len;
  hb_glyph_position_t *pos = hb_buffer_get_glyph_positions(B, &len);
  int32_t w = 0;
  for (unsigned i = 0; i < len; i++) w += pos[i].x_advance;
  return w;
}

/* ---------------- the model ---------------- */

typedef struct {
  char name[128];
  hb_font_t *font;
  int upem, N;                  // ids 1..N; id 0 = no neighbour / unknown char
  uint16_t idOf[0x10000];
  uint32_t cpOf[MAXN];
  int32_t adv[MAXN];
  uint16_t fc[MAXN], sc[MAXN];  // first/second-position pair classes
  int nF, nS;
  int32_t *M;                   // nF*nS cells: delta<<16 | eps<<1 | flag
  HMap R;                       // 3/4-gram residuals
  int32_t *pd; uint8_t *pf; uint16_t *pe;  // dense (N+1)^2 tables, distillation only
  int nFlagged; long nProbe3, nProbe4, nMiss3, nMiss4; int maxEps; double distillSec;
  // Proven mode: per-id certificate class (CERT_S/K/P/U, from certify.py) and the
  // longest island the exhaustive check covers.
  int proven, mIsl;
  uint8_t cert[MAXN];
  long islandsChecked, islandShapes, certDemoted;
  // Island tables (proven mode): every island I up to mIsl, measured alone and
  // next to every S character. Exact by construction, as in the Flutter version.
  int nI, islBase, nIsl;
  int8_t islDigit[MAXN];
  int32_t *islOfKey, *islW, *islL, *islR;  // islL/islR: island * (N+1) + neighbour id
} Model;
enum { CERT_S, CERT_K, CERT_P, CERT_U };

static int32_t mw_dense(const Model *m, const uint16_t *ids, int n) {
  int N1 = m->N + 1;
  int32_t w = 0;
  uint32_t z = 0, a = 0, b = 0;
  int fza = 0, fab = 0;
  for (int i = 0; i < n; i++) {
    uint32_t c = ids[i];
    int fbc = m->pf[b * N1 + c];
    int32_t inc = m->adv[c] + m->pd[b * N1 + c];
    if (fab | fbc) {
      inc += hm_get(&m->R, K3(a, b, c));
      if (fza + fab + fbc >= 2) inc += hm_get(&m->R, K4(z, a, b, c));
    }
    w += inc; z = a; a = b; b = c; fza = fab; fab = fbc;
  }
  return w;
}

static int32_t shape_ids(Model *m, const uint16_t *ids, int n) {
  uint32_t cps[8];
  for (int i = 0; i < n; i++) cps[i] = m->cpOf[ids[i]];
  return hb_w32(m->font, cps, n, NULL, NULL);
}

static uint64_t rng = 0x9E3779B97F4A7C15ULL;
static inline uint64_t rnd(void) { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return rng; }

static const uint32_t RANGES[][2] = {
  {0x20, 0x7E}, {0xA0, 0x24F}, {0x2010, 0x2027}, {0x2030, 0x205E}, {0x20AC, 0x20AC}, {0x2122, 0x2122}};

// Group identical rows (or columns) of the packed pair matrix into classes.
static int classify(const Model *m, const int32_t *P, int N1, int byRow, uint16_t *cls) {
  uint64_t *h = malloc(N1 * 8);
  int *rep = malloc(N1 * sizeof(int));
  int nc = 0;
  for (int a = 0; a < N1; a++) {
    uint64_t x = 1469598103934665603ULL;
    for (int b = 0; b < N1; b++) x = (x ^ (uint32_t)(byRow ? P[a * N1 + b] : P[b * N1 + a])) * 1099511628211ULL;
    h[a] = x;
    int found = -1;
    for (int c = 0; c < nc && found < 0; c++) {
      int r = rep[c];
      if (h[r] != x) continue;
      int same = 1;
      for (int b = 0; b < N1 && same; b++)
        same = byRow ? P[a * N1 + b] == P[r * N1 + b] : P[b * N1 + a] == P[b * N1 + r];
      if (same) found = c;
    }
    if (found < 0) { rep[nc] = a; found = nc++; }
    cls[a] = found;
  }
  free(h); free(rep);
  return nc;
}

typedef struct { const uint8_t *p; uint32_t n; } Para;
static Para *DICT;
static int NDICT;
static long WORDPROBES, WORDMISS;

static void distill(Model *m, long probes3, long probes4) {
  double t0 = now();
  memset(m->idOf, 0, sizeof m->idOf);
  m->N = 0;
  for (size_t r = 0; r < sizeof RANGES / sizeof RANGES[0]; r++)
    for (uint32_t cp = RANGES[r][0]; cp <= RANGES[r][1]; cp++) {
      hb_codepoint_t g;
      if (hb_font_get_nominal_glyph(m->font, cp, &g) && g && m->N < MAXN - 1) {
        m->idOf[cp] = ++m->N; m->cpOf[m->N] = cp;
      }
    }
  int N = m->N, N1 = N + 1;
  static hb_codepoint_t g1[MAXN];
  m->adv[0] = 0;
  for (int i = 1; i <= N; i++) {
    unsigned ng; hb_codepoint_t gg[4];
    m->adv[i] = hb_w32(m->font, &m->cpOf[i], 1, &ng, gg);
    g1[i] = ng == 1 ? gg[0] : 0xFFFFFFFFu;
  }
  m->pd = calloc(N1 * N1, 4); m->pf = calloc(N1 * N1, 1); m->pe = calloc(N1 * N1, 2);
  hm_init(&m->R, 12);

  // Pairs: kerning and 2-char ligatures, exactly.
  int *fl = malloc(sizeof(int) * N1 * N1), nf = 0;
  for (int a = 1; a <= N; a++)
    for (int b = 1; b <= N; b++) {
      uint32_t s[2] = {m->cpOf[a], m->cpOf[b]};
      unsigned ng; hb_codepoint_t gg[4];
      int32_t w = hb_w32(m->font, s, 2, &ng, gg);
      m->pd[a * N1 + b] = w - m->adv[a] - m->adv[b];
      if (!(ng == 2 && gg[0] == g1[a] && gg[1] == g1[b])) { m->pf[a * N1 + b] = 1; fl[nf++] = a * N1 + b; }
    }
  m->nFlagged = nf;

  // 3-grams around every glyph-changing pair (ligature -> next kern, ffi, calt...).
  uint16_t s[4];
  for (int k = 0; k < nf; k++) {
    int a = fl[k] / N1, b = fl[k] % N1;
    for (int x = 1; x <= N; x++) {
      s[0] = x; s[1] = a; s[2] = b;
      int32_t r = shape_ids(m, s, 3) - mw_dense(m, s, 3);
      if (r) hm_put(&m->R, K3(x, a, b), r);
      s[0] = a; s[1] = b; s[2] = x;
      r = shape_ids(m, s, 3) - mw_dense(m, s, 3);
      if (r) hm_put(&m->R, K3(a, b, x), r);
    }
  }
  // 4-grams where two glyph-changing pairs interact (chains like f-f-i, or adjacent pairs).
  long budget = 4000000;
  for (int k = 0; k < nf && budget > 0; k++) {
    int a = fl[k] / N1, b = fl[k] % N1;
    for (int c = 1; c <= N && budget > 0; c++) {
      if (!m->pf[b * N1 + c]) continue;
      for (int x = 1; x <= N; x++, budget -= 2) {
        s[0] = x; s[1] = a; s[2] = b; s[3] = c;
        int32_t r = shape_ids(m, s, 4) - mw_dense(m, s, 4);
        if (r) hm_put(&m->R, K4(x, a, b, c), r);
        s[0] = a; s[1] = b; s[2] = c; s[3] = x;
        r = shape_ids(m, s, 4) - mw_dense(m, s, 4);
        if (r) hm_put(&m->R, K4(a, b, c, x), r);
      }
    }
    for (int k2 = 0; k2 < nf && budget > 0; k2++, budget--) {
      s[0] = a; s[1] = b; s[2] = fl[k2] / N1; s[3] = fl[k2] % N1;
      int32_t r = shape_ids(m, s, 4) - mw_dense(m, s, 4);
      if (r) hm_put(&m->R, K4(s[0], s[1], s[2], s[3]), r);
    }
  }

  // Probes: random 3/4-grams (biased toward ASCII). Anything the model misses
  // becomes an error bound on every pair inside the probe.
  int nascii = 0;
  for (int i = 1; i <= N; i++) if (m->cpOf[i] <= 0x7E) nascii = i;
  m->nProbe3 = probes3; m->nProbe4 = probes4; m->nMiss3 = m->nMiss4 = 0; m->maxEps = 0;
  for (long p = 0; p < probes3 + probes4; p++) {
    int n = p < probes3 ? 3 : 4;
    for (int i = 0; i < n; i++) s[i] = 1 + rnd() % ((rnd() & 3) ? nascii : N);
    int32_t r = shape_ids(m, s, n) - mw_dense(m, s, n);
    if (!r) continue;
    if (n == 3) m->nMiss3++; else m->nMiss4++;
    int e = r < 0 ? -r : r;
    if (e > 32767) e = 32767;
    if (e > m->maxEps) m->maxEps = e;
    for (int i = 0; i + 1 < n; i++) {
      uint16_t *pe = &m->pe[s[i] * N1 + s[i + 1]];
      if (*pe < e) *pe = e;
    }
  }

  // Word probes: shape real dictionary words (and some with trailing punctuation).
  // Random n-grams cannot see long contextual substitutions; real words can.
  WORDPROBES = WORDMISS = 0;
  for (int w = 0; w < NDICT; w++) {
    uint16_t ids[64];
    uint8_t buf[72];
    int variants = (w & 7) ? 1 : 3;
    for (int v = 0; v < variants; v++) {
      uint32_t n = DICT[w].n;
      if (n + 1 > sizeof buf || n > 60) break;
      memcpy(buf, DICT[w].p, n);
      if (v) buf[n++] = v == 1 ? '.' : ',';
      int k = 0, ok = 1;
      for (uint32_t i = 0; i < n && ok;) {
        uint32_t cp;
        i = dec(buf, i, &cp);
        ids[k] = cp < 0x10000 ? m->idOf[cp] : 0;
        ok = ids[k++] != 0;
      }
      if (!ok || k < 2) continue;
      WORDPROBES++;
      int32_t r = hb_w8(m->font, buf, n) - mw_dense(m, ids, k);
      if (!r) continue;
      WORDMISS++;
      int e = r < 0 ? -r : r;
      if (e > 32767) e = 32767;
      if (e > m->maxEps) m->maxEps = e;
      for (int i = 0; i + 1 < k; i++) {
        uint16_t *pe = &m->pe[ids[i] * N1 + ids[i + 1]];
        if (*pe < e) *pe = e;
      }
    }
  }

  // Compress the pair matrix into classes.
  int32_t *P = malloc(N1 * N1 * 4);
  for (int i = 0; i < N1 * N1; i++) {
    int d = m->pd[i];
    if (d < -32768 || d > 32767) { fprintf(stderr, "pair delta overflow\n"); exit(1); }
    P[i] = (int32_t)(((uint32_t)(uint16_t)d << 16) | ((uint32_t)m->pe[i] << 1) | m->pf[i]);
  }
  m->nF = classify(m, P, N1, 1, m->fc);
  m->nS = classify(m, P, N1, 0, m->sc);
  m->M = malloc(m->nF * m->nS * 4);
  for (int a = 0; a < N1; a++)
    for (int b = 0; b < N1; b++) m->M[m->fc[a] * m->nS + m->sc[b]] = P[a * N1 + b];
  for (int a = 0; a < N1; a++)
    for (int b = 0; b < N1; b++)
      if (m->M[m->fc[a] * m->nS + m->sc[b]] != P[a * N1 + b]) { fprintf(stderr, "class compression bug\n"); exit(1); }
  free(P); free(fl);
  m->distillSec = now() - t0;
}

/* ---------------- certificate (proven mode) ---------------- */

static int load_cert(Model *m, const char *path) {
  FILE *fp = fopen(path, "r");
  if (!fp) return 0;
  memset(m->cert, CERT_U, sizeof m->cert);
  char line[256];
  m->mIsl = 0;
  while (fgets(line, sizeof line, fp)) {
    if (line[0] == '#') {
      char *q = strstr(line, "m=");
      if (q) m->mIsl = atoi(q + 2);
      continue;
    }
    unsigned cp, gid; char c;
    if (sscanf(line, "%x %u %c", &cp, &gid, &c) != 3 || cp >= 0x10000) continue;
    uint32_t id = m->idOf[cp];
    hb_codepoint_t g;
    // The certificate is about the glyph HarfBuzz will use; any disagreement is U.
    if (!id || !hb_font_get_nominal_glyph(m->font, cp, &g) || g != gid) continue;
    m->cert[id] = c == 'S' ? CERT_S : c == 'K' ? CERT_K : c == 'P' ? CERT_P : CERT_U;
  }
  fclose(fp);
  m->cert[0] = CERT_U;
  return 1;
}

static int in_island(const Model *m, uint32_t id) { return m->cert[id] == CERT_K || m->cert[id] == CERT_P; }

// Checks the two facts the proof takes from the model rather than the font:
//  (a) no model term reaches across an S character into another island or spans an
//      island with S on both sides, and no term lives on S characters alone;
//  (b) on every island I of length <= m (P/K string with a primer) and every S
//      neighbour x, y: model(I) = W(I), model(xI) = W(xI), model(Iy) = W(Iy).
// Violations shrink the certificate (S -> U, or a smaller m); they never widen it.
static void verify_certificate(Model *m) {
  int N = m->N, N1 = N + 1;
  // Glyph-changing pairs must not involve S characters. Pairs and residual windows
  // containing a U character never occur on a certified line, so they are skipped.
  for (int a = 1; a <= N; a++)
    for (int b = 1; b <= N; b++)
      if (m->pf[a * N1 + b] && m->cert[a] != CERT_U && m->cert[b] != CERT_U &&
          (m->cert[a] == CERT_S || m->cert[b] == CERT_S)) {
        if (m->cert[a] == CERT_S) { m->cert[a] = CERT_U; m->certDemoted++; }
        if (m->cert[b] == CERT_S) { m->cert[b] = CERT_U; m->certDemoted++; }
      }
  for (uint64_t i = 0; i <= m->R.mask; i++) {
    uint64_t k = m->R.e[i].key;
    if (!k) continue;
    int n = (int)(k >> 60);
    uint32_t ids[4];
    int hasU = 0;
    for (int j = 0; j < n; j++) {
      ids[j] = (uint32_t)(k >> (12 * (n - 1 - j))) & 0xFFF;
      hasU |= m->cert[ids[j]] == CERT_U;
    }
    if (hasU) continue;
    int segs = 0, first = -1, last = -1;
    for (int j = 0; j < n; j++)
      if (in_island(m, ids[j])) {
        if (j == 0 || !in_island(m, ids[j - 1])) segs++;
        if (first < 0) first = j;
        last = j;
      }
    if (segs == 0 || segs > 1) {
      for (int j = 0; j < n; j++)
        if (m->cert[ids[j]] == CERT_S && (segs == 0 || (j > first && j < last))) { m->cert[ids[j]] = CERT_U; m->certDemoted++; }
    } else if (first > 0 && last < n - 1 && m->cert[ids[0]] == CERT_S && m->cert[ids[n - 1]] == CERT_S) {
      if (m->mIsl > last - first) m->mIsl = last - first;
    }
  }
  uint16_t S[MAXN], I[MAXN];
  int nS = 0, nI = 0;
  for (int id = 1; id <= N; id++) {
    if (m->cert[id] == CERT_S) S[nS++] = id;
    else if (in_island(m, id)) I[nI++] = id;
  }
  // Keep the exhaustive check affordable: lower m until it fits the budget.
  for (;;) {
    double shapes = 0, combos = 1;
    for (int L = 1; L <= m->mIsl; L++) { combos *= nI; shapes += combos * (1 + 2.0 * nS); }
    if (shapes <= 3e6 || m->mIsl == 0) break;
    m->mIsl--;
  }
  m->islandsChecked = m->islandShapes = 0;
  m->nI = nI;
  m->islBase = nI + 1;
  memset(m->islDigit, -1, sizeof m->islDigit);
  for (int d = 0; d < nI; d++) m->islDigit[I[d]] = d;
  long keys = 1;
  for (int L = 0; L <= m->mIsl; L++) keys *= m->islBase;
  m->islOfKey = malloc(sizeof(int32_t) * keys);
  for (long k = 0; k < keys; k++) m->islOfKey[k] = -1;
  long maxIsl = keys;
  m->islW = malloc(sizeof(int32_t) * maxIsl);
  m->islL = malloc(sizeof(int32_t) * maxIsl * (N + 1));
  m->islR = malloc(sizeof(int32_t) * maxIsl * (N + 1));
  m->nIsl = 0;
  uint16_t seq[8];
  for (int L = 1; L <= m->mIsl; L++) {
    long combos = 1;
    for (int j = 0; j < L; j++) combos *= nI;
    for (long c = 0; c < combos; c++) {
      long x = c, key = 0;
      int primer = 0;
      for (int j = 0; j < L; j++) {
        int d = (int)(x % nI);
        x /= nI;
        seq[1 + j] = I[d];
        key = key * m->islBase + d + 1;
        primer |= m->cert[I[d]] == CERT_P;
      }
      if (!primer) continue;
      int idx = m->nIsl++;
      m->islOfKey[key] = idx;
      int32_t wI = shape_ids(m, seq + 1, L);
      m->islW[idx] = wI;
      for (int s = 0; s < nS; s++) {
        seq[0] = S[s];
        m->islL[(long)idx * N1 + S[s]] = shape_ids(m, seq, L + 1) - m->adv[S[s]] - wI;
        seq[1 + L] = S[s];
        m->islR[(long)idx * N1 + S[s]] = shape_ids(m, seq + 1, L + 1) - wI - m->adv[S[s]];
      }
      m->islandsChecked++;
      m->islandShapes += 1 + 2L * nS;
    }
  }
}

// Width of t[s..e) shaped on its own, from unigrams, pairs and island tables.
// *certified is 1 when the theorem covers the line (no U character, every island
// with a primer at most m long, every character in the model).
static int64_t island_range(const Model *m, const uint8_t *t, uint32_t s, uint32_t e, int *certified) {
  int N1 = m->N + 1;
  int64_t P = 0;
  uint32_t prev = 0;
  int prevIsl = -1;
  *certified = 1;
  uint32_t i = s;
  while (i < e) {
    uint32_t cp, ni = dec(t, i, &cp);
    uint32_t c = cp < 0x10000 ? m->idOf[cp] : 0;
    if (!c || m->cert[c] == CERT_U) { *certified = 0; return 0; }
    if (m->cert[c] != CERT_S) {
      // The maximal island run from here, and whether it has a primer.
      uint32_t j = i, key = 0, len = 0;
      int primer = 0, overflow = 0;
      while (j < e) {
        uint32_t cq, nj = dec(t, j, &cq);
        uint32_t q = cq < 0x10000 ? m->idOf[cq] : 0;
        if (!q || m->islDigit[q] < 0) break;
        primer |= m->cert[q] == CERT_P;
        if (++len > (uint32_t)m->mIsl) overflow = 1;
        else key = key * m->islBase + m->islDigit[q] + 1;
        j = nj;
      }
      if (primer) {
        if (overflow || m->islOfKey[key] < 0) { *certified = 0; return 0; }
        int idx = m->islOfKey[key];
        if (prev) P += m->islL[(long)idx * N1 + prev];
        P += m->islW[idx];
        prev = 0;
        prevIsl = idx;
        i = j;
        continue;
      }
    }
    // An S character, or a K character in a run without a primer.
    if (prev) P += m->pd[prev * N1 + c];
    else if (prevIsl >= 0) P += m->islR[(long)prevIsl * N1 + c];
    P += m->adv[c];
    prev = c;
    prevIsl = -1;
    i = ni;
  }
  return P;
}

static size_t model_bytes(const Model *m) {
  // Runtime footprint, excluding the codepoint map (2 bytes per BMP codepoint here,
  // a few KB as a two-level table).
  return (size_t)(m->N + 1) * (4 + 2 + 2) + (size_t)m->nF * m->nS * 4 + (size_t)m->R.n * 12;
}

/* ---------------- break opportunities (shared by baselines) ---------------- */

typedef struct { uint32_t end, next; } Opp;

// Simplified UAX #14 for Latin prose: after a run of spaces (line ends before the
// run), and after a hyphen between letters. The paragraph end is the final opportunity.
static int find_opps(const uint8_t *t, uint32_t len, Opp *o) {
  int n = 0, inSpace = 0, seen = 0, hy = 0;
  uint32_t i = 0, prev = 0, sp = 0, hyEnd = 0;
  while (i < len) {
    uint32_t cp, ni = dec(t, i, &cp);
    if (cp == ' ') { if (!inSpace) { inSpace = 1; sp = i; } hy = 0; }
    else {
      if (inSpace) { inSpace = 0; if (seen) o[n++] = (Opp){sp, i}; }
      else if (hy) { hy = 0; if (isal(cp)) o[n++] = (Opp){hyEnd, hyEnd}; }
      seen = 1;
    }
    if (cp == '-' && isal(prev)) { hy = 1; hyEnd = ni; }
    prev = cp; i = ni;
  }
  o[n++] = (Opp){inSpace ? sp : len, len};
  return n;
}

typedef struct { long fallbacks, decisions; } Stats;

/* ---------------- break-first v1: single fused pass (reference) ---------------- */

// Greedy: take the last opportunity whose line fits; if none fits, the first one.
// hybrid=0 trusts the model blindly; hybrid=1 shapes a candidate line only when its
// fit decision is not certified by the model's error bound.
static int model_break(const Model *m, const uint8_t *t, uint32_t len, int32_t W, uint32_t *out,
                       int hybrid, Stats *st) {
  const int32_t *adv = m->adv, *M = m->M;
  const uint16_t *fc = m->fc, *sc = m->sc, *idOf = m->idOf;
  const int nS = m->nS;
  int nl = 0;
  uint32_t s = 0;
restart:;
  int64_t P = 0, U = 0, Psp = 0, Usp = 0, Phy = 0, Uhy = 0;
  uint32_t z = 0, a = 0, b = 0, fza = 0, fab = 0, prev = 0, sp = 0, hyEnd = 0, fitEnd = 0, fitNext = 0;
  int inSpace = 0, hy = 0, haveFit = 0;
  uint32_t i = s;

#define DECIDE(END, NEXT, PW, UW, FINAL)                                              \
  do {                                                                                \
    int fit;                                                                          \
    st->decisions++;                                                                  \
    if ((PW) + (UW) <= W) fit = 1;                                                    \
    else if ((PW) - (UW) > W) fit = 0;                                                \
    else if (hybrid) { st->fallbacks++; fit = hb_w8(m->font, t + s, (END) - s) <= W; } \
    else fit = (PW) <= W;                                                             \
    if (fit) {                                                                        \
      if (FINAL) { out[nl++] = (END); return nl; }                                    \
      haveFit = 1; fitEnd = (END); fitNext = (NEXT);                                  \
    } else if (haveFit) { out[nl++] = fitEnd; s = fitNext; goto restart; }            \
    else { out[nl++] = (END); if (FINAL) return nl; s = (NEXT); goto restart; }       \
  } while (0)

  while (i < len) {
    uint32_t cp, ni;
    if (t[i] < 0x80) { cp = t[i]; ni = i + 1; } else ni = dec(t, i, &cp);
    if (cp == ' ') {
      if (!inSpace) { inSpace = 1; sp = i; Psp = P; Usp = U; }
      hy = 0;
    } else if (inSpace) {
      inSpace = 0;
      if (sp > s) DECIDE(sp, i, Psp, Usp, 0);
    } else if (hy) {
      hy = 0;
      if (isal(cp)) DECIDE(hyEnd, hyEnd, Phy, Uhy, 0);
    }
    uint32_t c = cp < 0x10000 ? idOf[cp] : 0;
    int32_t mv = M[fc[b] * nS + sc[c]];
    uint32_t fbc = mv & 1;
    int64_t inc = adv[c] + (mv >> 16);
    if (fab | fbc) {
      inc += hm_get(&m->R, K3(a, b, c));
      if (fza + fab + fbc >= 2) inc += hm_get(&m->R, K4(z, a, b, c));
    }
    P += inc;
    U += c ? (mv >> 1 & 0x7FFF) : BIG;
    z = a; a = b; b = c; fza = fab; fab = fbc;
    if (cp == '-' && isal(prev)) { hy = 1; hyEnd = ni; Phy = P; Uhy = U; }
    prev = cp; i = ni;
  }
  if (inSpace) DECIDE(sp, len, Psp, Usp, 1);
  else DECIDE(len, len, P, U, 1);
  return nl;
#undef DECIDE
}

/* ---------------- break-first, two-pass (branch-light) ---------------- */

// Pass 1 walks the paragraph once with no data-dependent branches on the common
// path and emits one record per break opportunity: where the line would end and
// its global width there (Pend), and where the next line would start and the
// width origin for that line (Pstart = global width there, corrected for the
// pair/residual terms that straddle the line start). Pass 2 is greedy over the
// records only: a line's width is Pend - Pstart, so breaking costs O(words).
typedef struct { uint32_t end, next; int64_t Pend, Pstart, Uend, Ustart; } ORec;
static inline int popcount_ge2(uint32_t f) { return __builtin_popcount(f) >= 2; }

enum { K_OTHER, K_SPACE, K_LETTER, K_HYPHEN };
static uint8_t KIND[MAXN];

// Per-codepoint record, one load per character:
//   adv:16 | id:12 | second-position class:12 | first-position row offset (fc*nS):20 | kind:2 |
//   certificate class:2 (always S outside proven mode)
static uint64_t CPREC[0x10000];
// Opportunity state machine. State bits: inSpace 1, seen 2, hyphenPending 4, prevLetter 8.
// Entry [state<<2 | kind] = newState | emitAfterSpaces<<4 | emitAfterHyphen<<5 | spaceRunStart<<6.
static uint8_t OPPST[64];

static void model_prepare(Model *m) {
  for (int i = 0; i <= m->N; i++) {
    uint32_t cp = m->cpOf[i];
    KIND[i] = i == 0 ? K_OTHER : cp == ' ' ? K_SPACE : isal(cp) ? K_LETTER : cp == '-' ? K_HYPHEN : K_OTHER;
  }
  for (uint32_t cp = 0; cp < 0x10000; cp++) {
    uint32_t id = m->idOf[cp];
    if (m->adv[id] < 0 || m->adv[id] > 0xFFFF || (uint64_t)m->fc[id] * m->nS >= (1u << 20)) {
      fprintf(stderr, "record overflow\n"); exit(1);
    }
    CPREC[cp] = (uint64_t)m->adv[id] | (uint64_t)id << 16 | (uint64_t)m->sc[id] << 28 |
                (uint64_t)(m->fc[id] * m->nS) << 40 | (uint64_t)KIND[id] << 60 |
                (uint64_t)(m->proven ? m->cert[id] : CERT_S) << 62;
  }
  // Proven mode certifies with the certificate alone: drop the empirical bounds.
  if (m->proven)
    for (int i = 0; i < m->nF * m->nS; i++) m->M[i] &= ~0xFFFE;
  for (uint32_t s = 0; s < 16; s++)
    for (uint32_t k = 0; k < 4; k++) {
      uint32_t inSpace = s & 1, seen = s >> 1 & 1, hy = s >> 2 & 1, prevL = s >> 3 & 1;
      uint32_t isSp = k == K_SPACE, isL = k == K_LETTER, isHy = k == K_HYPHEN;
      uint32_t ns = isSp | (seen | !isSp) << 1 | (isHy & prevL) << 2 | isL << 3;
      OPPST[s << 2 | k] = ns | ((!isSp) & inSpace & seen) << 4 | (hy & isL) << 5 | (isSp & !inSpace) << 6;
    }
}

// Three passes, none of which shapes anything:
//   A. width prefix: P[i] = model width of t[0..i), ~15 instructions per character;
//   B. break opportunities, found 16 bytes at a time with NEON, each turned into a
//      record (line end, its width; next line start, its width origin);
//   C. greedy decisions over the records only (below).
// Rare events (glyph-changing pairs needing 3/4-gram residuals, pairs with a
// nonzero error bound, characters outside the model) are noted as patches in A
// and folded into the records after B, so A stays branch-free and call-free.
typedef struct { uint32_t pos, f; int32_t mv; uint32_t unk; uint64_t h; } Patch;

static inline int32_t cross_mv(const Model *m, const uint8_t *t, uint32_t next) {
  // Pair cell for (character before next, character at next).
  uint32_t cp = t[next];
  if (cp >= 0x80) { uint32_t c; dec(t, next, &c); cp = c < 0x10000 ? c : 0xFFFF; }
  uint32_t row = (uint32_t)(CPREC[t[next - 1]] >> 40 & 0xFFFFF);
  return m->M[row + (uint32_t)(CPREC[cp] >> 28 & 0xFFF)];
}

// Passes A and B (and the patch fold-in) do not depend on the line width: their
// records can be kept per paragraph, and a resize re-runs only pass C.
static int model_records(const Model *m, const uint8_t *t, uint32_t len, ORec *o, Patch *pt, int32_t *Pa) {
  const int32_t *M = m->M;
  const uint64_t *rec = CPREC;

  // Pass A.
  int32_t P = 0;
  uint64_t h = 0;          // last four ids, 12 bits each
  uint32_t f = 0;          // glyph-changing flags of the last three pairs
  uint32_t row = m->fc[0] * m->nS;
  uint32_t run = 0, prim = 0;  // current island run length, and whether it has a primer
  const uint32_t misl = (uint32_t)m->mIsl;
  int np = 0;
#define STEP(I, CP)                                                                        \
  do {                                                                                     \
    uint64_t r = rec[CP];                                                                  \
    uint32_t id = r >> 16 & 0xFFF;                                                         \
    int32_t mv = M[row + (uint32_t)(r >> 28 & 0xFFF)];                                     \
    Pa[I] = P;                                                                             \
    P += (int32_t)(r & 0xFFFF) + (mv >> 16);                                               \
    h = (h << 12 | id) & 0xFFFFFFFFFFFFULL;                                                \
    f = (f << 1 | (mv & 1)) & 7;                                                           \
    uint32_t cc = (uint32_t)(r >> 62), isl = cc - 1u < 2u;                                 \
    run = isl ? run + 1 : 0;                                                               \
    prim = isl & (prim | (cc == CERT_P));                                                  \
    uint32_t bad = (cc == CERT_U) | (prim & (run > misl));                                 \
    if (__builtin_expect((mv & 0xFFFF) | (f & 2) | !id | bad, 0))                          \
      pt[np++] = (Patch){I, f, mv, !id | bad, h};                                          \
    row = (uint32_t)(r >> 40 & 0xFFFFF);                                                   \
  } while (0)
  // All-ASCII blocks run at a fixed stride, so the next index never waits on a load.
  for (uint32_t i = 0; i < len;) {
    if (i + 16 <= len && vmaxvq_u8(vld1q_u8(t + i)) < 0x80) {
      for (uint32_t e = i + 16; i < e; i++) STEP(i, t[i]);
      continue;
    }
    uint32_t cp = t[i], ni = i + 1;
    if (cp >= 0x80) {
      uint32_t c1 = t[i + 1] & 0x3F;
      if (cp < 0xE0) { cp = (cp & 0x1F) << 6 | c1; ni = i + 2; }
      else if (cp < 0xF0) { cp = (cp & 0x0F) << 12 | c1 << 6 | (t[i + 2] & 0x3F); ni = i + 3; }
      else { cp = 0xFFFF; ni = i + 4; }  // astral: outside the model (U+FFFF has no id)
    }
    STEP(i, cp);
    i = ni;
  }
#undef STEP
  Pa[len] = P;

  // Pass B. Opportunities: after a space run that has text on both sides (the line
  // ends before the run), and after a hyphen between ASCII letters.
  int n = 0;
  uint32_t sp = 0;
  const uint8x16_t vsp = vdupq_n_u8(' '), vhy = vdupq_n_u8('-');
#define OPP_AT(POS)                                                                         \
  do {                                                                                      \
    uint32_t p_ = (POS);                                                                    \
    if (t[p_] == ' ') {                                                                     \
      if (p_ == 0 || t[p_ - 1] != ' ') sp = p_;                                             \
      if (p_ + 1 < len && t[p_ + 1] != ' ' && sp > 0) {                                     \
        int32_t mv_ = cross_mv(m, t, p_ + 1);                                               \
        o[n++] = (ORec){sp, p_ + 1, Pa[sp], Pa[p_ + 1] + (mv_ >> 16), 0, mv_ >> 1 & 0x7FFF}; \
      }                                                                                     \
    } else if (p_ > 0 && p_ + 1 < len && isal(t[p_ - 1]) && isal(t[p_ + 1])) {              \
      int32_t mv_ = cross_mv(m, t, p_ + 1);                                                 \
      o[n++] = (ORec){p_ + 1, p_ + 1, Pa[p_ + 1], Pa[p_ + 1] + (mv_ >> 16), 0, mv_ >> 1 & 0x7FFF}; \
    }                                                                                       \
  } while (0)
  // One bit per byte for 64 bytes, so the bit loop exits once per 64 bytes.
  const uint8x16_t bitw = {1, 2, 4, 8, 16, 32, 64, 128, 1, 2, 4, 8, 16, 32, 64, 128};
  uint32_t i = 0;
  for (; i + 64 <= len; i += 64) {
    uint8x16_t m4[4];
    for (int q = 0; q < 4; q++) {
      uint8x16_t v = vld1q_u8(t + i + 16 * q);
      m4[q] = vandq_u8(vorrq_u8(vceqq_u8(v, vsp), vceqq_u8(v, vhy)), bitw);
    }
    uint8x16_t s = vpaddq_u8(vpaddq_u8(m4[0], m4[1]), vpaddq_u8(m4[2], m4[3]));
    s = vpaddq_u8(s, s);
    uint64_t bits = vgetq_lane_u64(vreinterpretq_u64_u8(s), 0);
    while (bits) {
      OPP_AT(i + __builtin_ctzll(bits));
      bits &= bits - 1;
    }
  }
  for (; i < len; i++)
    if (t[i] == ' ' || t[i] == '-') OPP_AT(i);
#undef OPP_AT
  uint32_t endb = len;
  if (len && t[len - 1] == ' ') endb = sp;  // trailing spaces hang
  o[n++] = (ORec){endb, len, Pa[endb], 0, 0, 0};

  // Fold patches in: a residual at byte pos shifts every width measured after pos;
  // error bounds accumulate the same way; and residuals in a word's first three
  // characters that reach back across the word start move that word's line origin.
  if (np) {
    int64_t CP = 0, CU = 0;
    int ws = -1;
    for (int j = 0, q = 0; j < n; j++) {
      for (int pass = 0; pass < 2; pass++) {
        uint32_t lim = pass ? o[j].next : o[j].end;
        for (; q < np && pt[q].pos < lim; q++) {
          const Patch *p = &pt[q];
          int32_t r3 = 0, r4 = 0;
          if (p->f & 3) {
            r3 = hm_get(&m->R, (3ULL << 60) | (p->h & 0xFFFFFFFFFULL));
            if (popcount_ge2(p->f)) r4 = hm_get(&m->R, (4ULL << 60) | p->h);
          }
          CP += r3 + r4;
          CU += (p->mv >> 1 & 0x7FFF) + (p->unk ? BIG : 0);
          if (ws >= 0 && (r3 | r4)) {
            uint32_t wp = 0;
            for (uint32_t x = o[ws].next + 1; x <= p->pos && wp < 3; x++) wp += (t[x] & 0xC0) != 0x80;
            if (wp <= 2) o[ws].Pstart += (wp < 2 ? r3 : 0) + r4;
          }
        }
        if (pass) { o[j].Pstart += CP; o[j].Ustart += CU; }
        else { o[j].Pend += CP; o[j].Uend = CU; }
      }
      ws = j;
    }
  }

  return n;
}

// Pass C: greedy over the records. A decision is certified when W is outside
// [w - u, w + u]; otherwise hybrid mode shapes just that candidate line.
static int model_greedy(const Model *m, const uint8_t *t, const ORec *o, int n, int32_t W, uint32_t *out,
                        int hybrid, Stats *st) {
  int nl = 0, k = 0;
  int64_t P0 = 0, U0 = 0;
  uint32_t s = 0;
  for (;;) {
    int best = -1;
    for (int j = k; j < n; j++) {
      int64_t w = o[j].Pend - P0, u = o[j].Uend - U0;
      int fit;
      st->decisions++;
      if (w + u <= W) fit = 1;
      else if (w - u > W) fit = 0;
      else if (hybrid) { st->fallbacks++; fit = hb_w8(m->font, t + s, o[j].end - s) <= W; }
      else fit = w <= W;
      if (fit) best = j; else break;
    }
    if (best < 0) best = k;
    out[nl++] = o[best].end;
    if (best == n - 1) return nl;
    P0 = o[best].Pstart; U0 = o[best].Ustart; s = o[best].next; k = best + 1;
  }
}

static int model_break2(const Model *m, const uint8_t *t, uint32_t len, int32_t W, uint32_t *out, int hybrid,
                        Stats *st, ORec *o, Patch *pt, int32_t *Pa) {
  int n = model_records(m, t, len, o, pt, Pa);
  return model_greedy(m, t, o, n, W, out, hybrid, st);
}

// Model width of one byte range (for checking the width oracle line by line).
static int64_t model_range(const Model *m, const uint8_t *t, uint32_t s, uint32_t e, int64_t *Uout, int *unknown) {
  int64_t P = 0, U = 0;
  uint32_t z = 0, a = 0, b = 0, fza = 0, fab = 0, run = 0, prim = 0;
  *unknown = 0;
  for (uint32_t i = s; i < e;) {
    uint32_t cp;
    i = dec(t, i, &cp);
    uint32_t c = cp < 0x10000 ? m->idOf[cp] : 0;
    *unknown |= !c;
    if (m->proven) {
      uint32_t cc = m->cert[c], isl = cc == CERT_K || cc == CERT_P;
      run = isl ? run + 1 : 0;
      prim = isl && (prim || cc == CERT_P);
      if (cc == CERT_U || (prim && run > (uint32_t)m->mIsl)) U += BIG;
    }
    int32_t mv = m->M[m->fc[b] * m->nS + m->sc[c]];
    uint32_t fbc = mv & 1;
    int64_t inc = m->adv[c] + (mv >> 16);
    if (fab | fbc) {
      inc += hm_get(&m->R, K3(a, b, c));
      if (fza + fab + fbc >= 2) inc += hm_get(&m->R, K4(z, a, b, c));
    }
    P += inc; U += c ? (mv >> 1 & 0x7FFF) : BIG;
    z = a; a = b; b = c; fza = fab; fab = fbc;
  }
  *Uout = U;
  return P;
}

/* ---------------- ground truth: reshape every candidate line ---------------- */

static int exact_break(hb_font_t *f, const uint8_t *t, uint32_t len, int32_t W, uint32_t *out, Opp *o) {
  int n = find_opps(t, len, o), nl = 0, k = 0;
  uint32_t s = 0;
  for (;;) {
    int best = -1;
    for (int j = k; j < n; j++) {
      if (hb_w8(f, t + s, o[j].end - s) <= W) best = j; else break;
    }
    if (best < 0) best = k;
    out[nl++] = o[best].end;
    if (best == n - 1) return nl;
    s = o[best].next; k = best + 1;
  }
}

/* ---------------- baseline 1: shape paragraph once, break on shaped advances ---------------- */

static int shapefirst_break(hb_font_t *f, const uint8_t *t, uint32_t len, int32_t W, uint32_t *out, Opp *o,
                            int32_t *cum) {
  int n = find_opps(t, len, o), nl = 0, k = 0;
  hb_buffer_clear_contents(B);
  hb_buffer_add_utf8(B, (const char *)t, len, 0, len);
  props();
  hb_shape(f, B, NULL, 0);
  unsigned gl;
  hb_glyph_info_t *inf = hb_buffer_get_glyph_infos(B, &gl);
  hb_glyph_position_t *pos = hb_buffer_get_glyph_positions(B, &gl);
  memset(cum, 0, (len + 1) * 4);
  for (unsigned g = 0; g < gl; g++) cum[inf[g].cluster + 1] += pos[g].x_advance;
  for (uint32_t i = 0; i < len; i++) cum[i + 1] += cum[i];
  uint32_t s = 0;
  for (;;) {
    int best = -1;
    for (int j = k; j < n; j++) {
      if (cum[o[j].end] - cum[s] <= W) best = j; else break;
    }
    if (best < 0) best = k;
    out[nl++] = o[best].end;
    if (best == n - 1) return nl;
    s = o[best].next; k = best + 1;
  }
}

/* ---------------- baseline 2: per-word width cache (Minikin / Pretext style) ---------------- */

typedef struct { uint64_t h; const uint8_t *p; uint32_t n; int32_t w; } WEnt;
static WEnt *WC;
static uint64_t WCmask;

static int32_t word_w(hb_font_t *f, const uint8_t *p, uint32_t n) {
  uint64_t h = 1469598103934665603ULL;
  for (uint32_t i = 0; i < n; i++) h = (h ^ p[i]) * 1099511628211ULL;
  h |= 1;
  for (uint64_t i = h & WCmask;; i = (i + 1) & WCmask) {
    WEnt *e = &WC[i];
    if (e->h == h && e->n == n && !memcmp(e->p, p, n)) return e->w;
    if (!e->h) { e->h = h; e->p = p; e->n = n; e->w = hb_w8(f, p, n); return e->w; }
  }
}

static int wordcache_break(hb_font_t *f, const uint8_t *t, uint32_t len, int32_t W, uint32_t *out, Opp *o,
                           int32_t *segw, int32_t spaceW) {
  int n = find_opps(t, len, o), nl = 0, k = 0;
  for (int j = 0; j < n; j++) {
    uint32_t st = j ? o[j - 1].next : 0;
    segw[j] = word_w(f, t + st, o[j].end - st);
  }
  uint32_t s = 0;
  for (;;) {
    int best = -1;
    int64_t w = 0;
    for (int j = k; j < n; j++) {
      w += segw[j] + (j > k ? (int64_t)(o[j - 1].next - o[j - 1].end) * spaceW : 0);
      if (w <= W) best = j; else break;
    }
    if (best < 0) best = k;
    out[nl++] = o[best].end;
    if (best == n - 1) return nl;
    s = o[best].next; k = best + 1;
  }
  (void)s;
}

/* ---------------- driver ---------------- */

static int same(const uint32_t *x, int nx, const uint32_t *y, int ny) {
  return nx == ny && !memcmp(x, y, nx * 4);
}

int main(int argc, char **argv) {
  if (argc < 3) { fprintf(stderr, "usage: %s corpus.txt font[:index]...\n", argv[0]); return 1; }
  FILE *fp = fopen(argv[1], "rb");
  fseek(fp, 0, SEEK_END); long sz = ftell(fp); fseek(fp, 0, SEEK_SET);
  uint8_t *txt = malloc(sz + 1);
  fread(txt, 1, sz, fp); fclose(fp);
  Para *paras = malloc(sizeof(Para) * (sz / 2 + 1));
  int np = 0;
  uint32_t maxlen = 0;
  for (long i = 0, st = 0; i <= sz; i++)
    if (i == sz || txt[i] == '\n') {
      if (i > st) { paras[np++] = (Para){txt + st, (uint32_t)(i - st)}; if (i - st > maxlen) maxlen = i - st; }
      st = i + 1;
    }
  // Census switches: BFL_LIMIT=n paragraphs, BFL_WIDTHS=em,em,..., BFL_NOPROBE, BFL_NOBENCH.
  if (getenv("BFL_LIMIT") && atoi(getenv("BFL_LIMIT")) < np) np = atoi(getenv("BFL_LIMIT"));
  long totalBytes = 0;
  for (int p = 0; p < np; p++) totalBytes += paras[p].n;

  {
    FILE *df = fopen("/usr/share/dict/words", "rb");
    if (df) {
      fseek(df, 0, SEEK_END); long dsz = ftell(df); fseek(df, 0, SEEK_SET);
      uint8_t *d = malloc(dsz);
      fread(d, 1, dsz, df); fclose(df);
      DICT = malloc(sizeof(Para) * (dsz / 2 + 1));
      for (long i = 0, st = 0; i < dsz; i++)
        if (d[i] == '\n') { if (i > st) DICT[NDICT++] = (Para){d + st, (uint32_t)(i - st)}; st = i + 1; }
    }
  }
  B = hb_buffer_create();
  LANG_EN = hb_language_from_string("en", -1);
  Opp *o = malloc(sizeof(Opp) * (maxlen + 2));
  uint32_t *b0 = malloc(4 * (maxlen + 2)), *b1 = malloc(4 * (maxlen + 2));
  int32_t *cum = malloc(4 * (maxlen + 2)), *segw = malloc(4 * (maxlen + 2));
  ORec *orec = malloc(sizeof(ORec) * (maxlen + 2));
  Patch *patch = malloc(sizeof(Patch) * (maxlen + 2));
  int32_t *pa = malloc(sizeof(int32_t) * (maxlen + 2));
  WCmask = (1 << 21) - 1;
  WC = malloc(sizeof(WEnt) * (WCmask + 1));
  double widthsEm[16] = {9.5, 14, 19.25, 26, 33.3, 41};
  int NW = 6;
  if (getenv("BFL_WIDTHS")) {
    NW = 0;
    for (char *q = getenv("BFL_WIDTHS"); *q && NW < 16;) {
      widthsEm[NW++] = strtod(q, &q);
      if (*q == ',') q++;
    }
  }
  if (getenv("BFL_NOPROBE")) NDICT = 0;

  printf("corpus: %d paragraphs, %.2f MB\n", np, totalBytes / 1e6);
  for (int fi = 2; fi < argc; fi++) {
    char path[1024]; int idx = 0;
    strncpy(path, argv[fi], sizeof path - 1); path[sizeof path - 1] = 0;
    char *certPath = strchr(path, '@');
    if (certPath) *certPath++ = 0;
    char *colon = strrchr(path, ':');
    if (colon) { idx = atoi(colon + 1); *colon = 0; }
    hb_blob_t *blob = hb_blob_create_from_file_or_fail(path);
    if (!blob) { fprintf(stderr, "cannot open %s\n", path); continue; }
    hb_face_t *face = hb_face_create(blob, idx);
    static Model mm; Model *m = &mm;
    memset(m, 0, sizeof *m);
    m->font = hb_font_create(face);
    m->upem = hb_face_get_upem(face);
    unsigned nlen = sizeof m->name;
    hb_ot_name_get_utf8(face, HB_OT_NAME_ID_FULL_NAME, HB_LANGUAGE_INVALID, &nlen, m->name);
    distill(m, getenv("BFL_NOPROBE") ? 0 : 300000, getenv("BFL_NOPROBE") ? 0 : 150000);
    if (certPath) {
      if (!load_cert(m, certPath)) { fprintf(stderr, "cannot read %s\n", certPath); return 1; }
      m->proven = 1;
      double tv = now();
      verify_certificate(m);
      int cnt[4] = {0};
      for (int id = 1; id <= m->N; id++) cnt[m->cert[id]]++;
      printf("\n== %s [proven]\n   certificate: S %d  P %d  K %d  U %d | islands up to m=%d verified: %ld islands, "
             "%ld shapes, %.2fs | demoted %ld\n",
             m->name, cnt[CERT_S], cnt[CERT_P], cnt[CERT_K], cnt[CERT_U], m->mIsl, m->islandsChecked, m->islandShapes,
             now() - tv, m->certDemoted);
    }
    model_prepare(m);

    printf("\n== %s (upem %d)\n", m->name, m->upem);
    printf("   distill %.2fs | repertoire %d | glyph-changing pairs %d | residuals %u | classes %dx%d | model %.1f KB\n",
           m->distillSec, m->N, m->nFlagged, m->R.n, m->nF, m->nS, model_bytes(m) / 1024.0);
    printf("   probes missed: 3-gram %ld/%ld, 4-gram %ld/%ld, words %ld/%ld, max eps %d units\n", m->nMiss3, m->nProbe3,
           m->nMiss4, m->nProbe4, WORDMISS, WORDPROBES, m->maxEps);

    // Validation.
    long lines = 0, exactW = 0, certLines = 0, certWrong = 0, unk = 0, tabLines = 0, tabCert = 0, tabWrong = 0;
    int64_t tabMaxErr = 0;
    int64_t maxErr = 0;
    long agreeModel = 0, agreeModel2 = 0, agreeHybrid = 0, agreeSF = 0, agreeWC = 0, decisions = 0, fallbacks = 0, tot = 0;
    hb_codepoint_t sg; hb_font_get_nominal_glyph(m->font, ' ', &sg);
    int32_t spaceW = hb_w8(m->font, (const uint8_t *)" ", 1);
    for (int wi = 0; wi < (getenv("BENCH_ONLY") ? 0 : NW); wi++) {
      int32_t W = (int32_t)(widthsEm[wi] * m->upem);
      memset(WC, 0, sizeof(WEnt) * (WCmask + 1));
      for (int p = 0; p < np; p++) {
        const uint8_t *t = paras[p].p; uint32_t len = paras[p].n;
        int ng = exact_break(m->font, t, len, W, b0, o);
        // Width oracle check on every ground-truth line.
        uint32_t s = 0;
        for (int l = 0; l < ng; l++) {
          int unknownChar;
          int64_t U, pw = model_range(m, t, s, b0[l], &U, &unknownChar);
          int32_t hw = hb_w8(m->font, t + s, b0[l] - s);
          lines++;
          if (m->proven) {
            int cert;
            int64_t tw = island_range(m, t, s, b0[l], &cert);
            tabLines++;
            if (cert) {
              tabCert++;
              int64_t err = tw > hw ? tw - hw : hw - tw;
              if (err) tabWrong++;
              if (err > tabMaxErr) tabMaxErr = err;
            }
          }
          if (unknownChar) unk++;
          else {
            int64_t err = pw > hw ? pw - hw : hw - pw;
            if (!err) exactW++;
            if (err > maxErr) maxErr = err;
            if (U == 0) { certLines++; if (err) certWrong++; }
          }
          // next line start: skip spaces after b0[l]
          s = b0[l];
          while (s < len && t[s] == ' ') s++;
        }
        Stats st0 = {0}, st1 = {0}, st2 = {0};
        int n1 = model_break(m, t, len, W, b1, 0, &st0);
        agreeModel += same(b0, ng, b1, n1);
        n1 = model_break2(m, t, len, W, b1, 0, &st2, orec, patch, pa);
        agreeModel2 += same(b0, ng, b1, n1);
        n1 = model_break2(m, t, len, W, b1, 1, &st1, orec, patch, pa);
        agreeHybrid += same(b0, ng, b1, n1);
        decisions += st1.decisions; fallbacks += st1.fallbacks;
        n1 = shapefirst_break(m->font, t, len, W, b1, o, cum);
        agreeSF += same(b0, ng, b1, n1);
        n1 = wordcache_break(m->font, t, len, W, b1, o, segw, spaceW);
        agreeWC += same(b0, ng, b1, n1);
        tot++;
      }
    }
    printf("   lines checked %ld (x%d widths) | model width exact %.4f%% | max err %lld units | unknown-char lines %ld\n",
           lines, NW, 100.0 * exactW / (lines - unk), (long long)maxErr, unk);
    printf("   eps=0 (certified) lines %.2f%%, of which wrong %ld\n", 100.0 * certLines / lines, certWrong);
    if (m->proven)
      printf("   island-table certified lines %ld/%ld (%.2f%%), of which wrong %ld, max err %lld units\n", tabCert, tabLines,
             100.0 * tabCert / tabLines, tabWrong, (long long)tabMaxErr);
    printf("   paragraphs with identical breaks: model v1 %.3f%% v2 %.3f%% | hybrid %.3f%% (shaped %.3f%% of decisions) | "
           "shape-first %.3f%% | word-cache %.3f%%\n",
           100.0 * agreeModel / tot, 100.0 * agreeModel2 / tot, 100.0 * agreeHybrid / tot, 100.0 * fallbacks / decisions, 100.0 * agreeSF / tot,
           100.0 * agreeWC / tot);

    if (getenv("BFL_NOBENCH")) goto done;
    // Benchmark at ~19 em (about 40 characters per line).
    int32_t W = (int32_t)(19.25 * m->upem);
    Stats st = {0};
    double tm, tm1, tsf, twc;
    long reps = 0, nlines = 0;
    double t0 = now();
    do { for (int p = 0; p < np; p++) model_break(m, paras[p].p, paras[p].n, W, b1, 1, &st); reps++; }
    while ((tm1 = now() - t0) < 1.0);
    tm1 /= reps;
    reps = 0; t0 = now();
    do { for (int p = 0; p < np; p++) nlines += model_break2(m, paras[p].p, paras[p].n, W, b1, 1, &st, orec, patch, pa); reps++; }
    while ((tm = now() - t0) < 1.0);
    tm /= reps; nlines /= reps;
    reps = 0; t0 = now();
    do { for (int p = 0; p < np; p++) shapefirst_break(m->font, paras[p].p, paras[p].n, W, b1, o, cum); reps++; }
    while ((tsf = now() - t0) < 1.0);
    tsf /= reps;
    memset(WC, 0, sizeof(WEnt) * (WCmask + 1));
    for (int p = 0; p < np; p++) wordcache_break(m->font, paras[p].p, paras[p].n, W, b1, o, segw, spaceW);
    reps = 0; t0 = now();
    do { for (int p = 0; p < np; p++) wordcache_break(m->font, paras[p].p, paras[p].n, W, b1, o, segw, spaceW); reps++; }
    while ((twc = now() - t0) < 1.0);
    twc /= reps;
    // Resize: records are width-independent, so re-wrapping is pass C only.
    long totRec = 0;
    for (int p = 0; p < np; p++) totRec += paras[p].n / 2 + 2;
    ORec *pool = malloc(sizeof(ORec) * totRec);
    int *pn = malloc(sizeof(int) * np);
    long *poff = malloc(sizeof(long) * np);
    for (int p = 0, off = 0; p < np; p++) {
      poff[p] = off;
      pn[p] = model_records(m, paras[p].p, paras[p].n, pool + off, patch, pa);
      off += pn[p];
    }
    double trw;
    int sweeps = 0;
    t0 = now();
    do {
      for (int wv = 0; wv < 32; wv++) {
        int32_t Wv = (int32_t)((8 + wv) * m->upem);
        for (int p = 0; p < np; p++) model_greedy(m, paras[p].p, pool + poff[p], pn[p], Wv, b1, 1, &st);
      }
      sweeps += 32;
    } while ((trw = now() - t0) < 1.0);
    trw /= sweeps;
    free(pool); free(pn); free(poff);
    printf("   rewrap at a new width (pass C only): %.3f ns/char, %.0f us for the whole corpus\n",
           1e9 * trw / totalBytes, 1e6 * trw);
    printf("   speed (%ld lines): break-first v2 %.2f ns/char (%.0f MB/s, %.0f ns/line; v1 %.2f) | shape-first %.1f ns/char | "
           "warm word-cache %.1f ns/char | speedup %.0fx / %.1fx\n",
           nlines, 1e9 * tm / totalBytes, totalBytes / tm / 1e6, 1e9 * tm / nlines, 1e9 * tm1 / totalBytes, 1e9 * tsf / totalBytes,
           1e9 * twc / totalBytes, tsf / tm, twc / tm);
    fflush(stdout);
  done:
    free(m->pd); free(m->pf); free(m->pe); free(m->M); free(m->R.e);
    hb_font_destroy(m->font); hb_face_destroy(face); hb_blob_destroy(blob);
  }
  return 0;
}
