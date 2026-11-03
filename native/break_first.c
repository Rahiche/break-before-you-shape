// Experiment: the break-first breaker (packages/break_first/lib/src/width_model.dart)
// ported line for line to C, to measure whether native code is worth an FFI
// boundary. Same tables, same float arithmetic in the same order, same rules.
//
// Dart writes UTF-16 paragraphs into a buffer the model owns and calls one
// function for the whole batch, so the boundary is crossed once per batch.
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// Dart does not fuse multiply-adds; neither may this file, or near-tie fit
// decisions could differ.
#pragma STDC FP_CONTRACT OFF

#define EXPORT __attribute__((visibility("default"))) __attribute__((used))

enum { CERT_S = 0, CERT_K = 1, CERT_P = 2, CERT_U = 3 };
enum { AL, NU, SP, BA, HY, IS, EX, OP, CL, CP, QU, SY, PR, PO, IN, B2, GL, BB, XX, NLB };
enum { SC_COMMON, SC_LATIN, SC_GREEK, SC_CYRILLIC };
#define LB_MAX 0x2200
static const double DRIFT_PER_PX = 2.5e-5;

typedef struct {
  double *prefix;
  int32_t *ends, *nexts, *risky_ends, *risky_nexts;
  int32_t count, risky, cap_prefix, cap_ops, cap_risky;
} Records;

typedef struct {
  int m, n1;
  uint8_t *cert;
  double *adv, *cls, *island_w, *island_l, *island_r;
  int32_t *fc, *sc, *island_of_key;
  uint16_t *id_of;
  int8_t *island_digit;
  int64_t key_base;
  uint8_t lb[LB_MAX];
  uint8_t no_break[NLB * NLB], space_ok[NLB * NLB];
  double hundredth, tenth;
  // Buffers shared with Dart.
  uint16_t *text;
  uint32_t *offsets;
  int32_t *out;
  size_t cap_text, cap_n;
  Records scratch;
  Records *stored;
  uint8_t *stored_ok;
  size_t n_stored;
} Model;

static inline double f32r(double x) { return (double)(float)x; }

// ---------------------------------------------------------------------------
// Tables, built in the same order as the Dart ones.
static void build_tables(Model *md) {
  uint8_t *t = md->lb;
  for (int c = 0; c < LB_MAX; c++) t[c] = XX;
  for (int c = 0x21; c < 0x7F; c++) t[c] = AL;
  for (int c = 0x30; c <= 0x39; c++) t[c] = NU;
  static const int special[][2] = {
      {0x20, SP}, {0x21, EX}, {0x22, QU}, {0x24, PR}, {0x25, PO}, {0x27, QU}, {0x28, OP}, {0x29, CP}, {0x2B, PR},
      {0x2C, IS}, {0x2D, HY}, {0x2E, IS}, {0x2F, SY}, {0x3A, IS}, {0x3B, IS}, {0x3F, EX}, {0x5B, OP}, {0x5C, PR},
      {0x5D, CP}, {0x7B, OP}, {0x7C, BA}, {0x7D, CL},
      {0xA0, GL}, {0xA9, AL}, {0xAE, AL}, {0xB0, PO}, {0xB7, AL}, {0xAB, QU}, {0xBB, QU},
      {0x2013, BA}, {0x2014, B2}, {0x2018, QU}, {0x2019, QU}, {0x201C, QU}, {0x201D, QU}, {0x2026, IN},
      {0x2022, AL}, {0x20AC, PR}, {0x2122, AL},
      {0x201A, OP}, {0x201E, OP},
      {0x2010, BA}, {0x2011, GL}, {0xB4, BB},
  };
  for (int c = 0x2B0; c < 0x300; c++) t[c] = AL;
  t[0x2C8] = t[0x2CC] = t[0x2DF] = BB;
  for (size_t k = 0; k < sizeof special / sizeof special[0]; k++) t[special[k][0]] = (uint8_t)special[k][1];
  for (int c = 0xC0; c < 0x250; c++)
    if (c != 0xD7 && c != 0xF7) t[c] = AL;
  for (int c = 0x386; c < 0x3FF; c++) t[c] = AL;
  t[0x387] = XX;
  for (int c = 0x400; c < 0x500; c++)
    if (c < 0x483 || c > 0x489) t[c] = AL;

  uint8_t *nb = md->no_break;
  memset(nb, 0, NLB * NLB);
#define NO(a, x) nb[(a) * NLB + (x)] = 1
  for (int a = 0; a < NLB; a++) {
    NO(a, CL); NO(a, CP); NO(a, EX); NO(a, IS); NO(a, SY);
    NO(OP, a);
    NO(a, QU); NO(QU, a);
    NO(a, GL); NO(GL, a);
    NO(a, BA); NO(a, HY);
    NO(a, IN);
    NO(BB, a);
  }
  NO(B2, B2);
  NO(AL, NU); NO(NU, AL);
  NO(PR, AL); NO(AL, PR); NO(PO, AL); NO(AL, PO);
  NO(PR, NU); NO(PO, NU); NO(OP, NU); NO(HY, NU); NO(IS, NU);
  NO(AL, AL);
  NO(IS, AL);
  NO(AL, OP); NO(NU, OP); NO(CP, AL); NO(CP, NU);
#undef NO

  uint8_t *so = md->space_ok;
  memset(so, 1, NLB * NLB);
  for (int b = 0; b < NLB; b++) {
    so[b * NLB + CL] = so[b * NLB + CP] = so[b * NLB + EX] = so[b * NLB + IS] = so[b * NLB + SY] = 0;
    if (b == OP)
      for (int x = 0; x < NLB; x++) so[b * NLB + x] = 0;
  }
  so[B2 * NLB + B2] = 0;
}

static inline uint8_t lb_class(const Model *md, uint16_t cu) { return cu < LB_MAX ? md->lb[cu] : XX; }

static inline int script_of(uint32_t cu) {
  if ((cu | 0x20) >= 0x61 && (cu | 0x20) <= 0x7A) return SC_LATIN;
  if (cu < 0xC0) return cu == 0xAA || cu == 0xBA ? SC_LATIN : SC_COMMON;
  if (cu < 0x250) return cu == 0xD7 || cu == 0xF7 ? SC_COMMON : SC_LATIN;
  if (cu >= 0x370 && cu < 0x400) return cu == 0x374 || cu == 0x37E || cu == 0x385 || cu == 0x387 ? SC_COMMON : SC_GREEK;
  if (cu >= 0x400 && cu < 0x500) return SC_CYRILLIC;
  return SC_COMMON;
}

static inline int is_pi(uint16_t cu) { return cu == 0xAB || cu == 0x2018 || cu == 0x201C; }
static inline int is_pf(uint16_t cu) { return cu == 0xBB || cu == 0x2019 || cu == 0x201D; }

// SkParagraph's line-fit test in float32 (fitsLine in Dart).
static inline int fits_line(double width_px, double max_f32, double hundredth, double tenth) {
  double w = f32r(width_px), v = fabs(w), rounded;
  if (v < 10000) rounded = f32r(floor(f32r(w * 100)) * hundredth);
  else if (v < 100000) rounded = f32r(floor(f32r(w * 10)) * tenth);
  else rounded = floor(w);
  return !(rounded > max_f32);
}

static int exact_positions(double scale, double paragraph_px) {
  for (int bits = 0; bits <= 16; bits++) {
    double v = scale * (double)(1 << bits);
    if (v == round(v)) return paragraph_px * (double)(1 << bits) < (double)(1 << 24);
  }
  return 0;
}

// ---------------------------------------------------------------------------
static void grow_prefix(Records *r, int32_t n) {
  if (r->cap_prefix < n) {
    r->cap_prefix = n * 2;
    r->prefix = realloc(r->prefix, sizeof(double) * r->cap_prefix);
  }
}

static void grow_ops(Records *r, int32_t n) {
  if (r->cap_ops < n) {
    r->cap_ops = n * 2;
    r->ends = realloc(r->ends, sizeof(int32_t) * r->cap_ops);
    r->nexts = realloc(r->nexts, sizeof(int32_t) * r->cap_ops);
  }
}

static void push_risky(Records *r, int32_t e, int32_t nx) {
  if (r->risky == r->cap_risky) {
    r->cap_risky = r->cap_risky ? r->cap_risky * 2 : 16;
    r->risky_ends = realloc(r->risky_ends, sizeof(int32_t) * r->cap_risky);
    r->risky_nexts = realloc(r->risky_nexts, sizeof(int32_t) * r->cap_risky);
  }
  r->risky_ends[r->risky] = e;
  r->risky_nexts[r->risky++] = nx;
}

static void free_records(Records *r) {
  free(r->prefix); free(r->ends); free(r->nexts); free(r->risky_ends); free(r->risky_nexts);
  memset(r, 0, sizeof *r);
}

// Break opportunities (Dart: _opportunities).
static int opportunities(const Model *md, const uint16_t *t, int32_t len, Records *r) {
  grow_ops(r, len + 2);
  int32_t n = 0;
  r->risky = 0;
  int32_t space_start = -1, last_non_space = -1;
  int in_number = 0, closed_number = 0;
  uint8_t ca = len > 0 ? lb_class(md, t[0]) : SP;
  if (ca == XX) return 0;
  for (int32_t i = 1; i < len; i++) {
    uint16_t x = t[i];
    uint8_t cx = lb_class(md, x);
    if (cx == XX) return 0;
    int was_number = in_number;
    in_number = ca == NU || (in_number && (ca == SY || ca == IS));
    closed_number = was_number && (ca == CL || ca == CP);
    if (ca != SP) last_non_space = i - 1;
    if (cx == SP) {
      if (ca != SP) space_start = i;
      ca = cx;
      continue;
    }
    if (ca == SP) {
      if (last_non_space >= 0) {
        uint16_t b = t[last_non_space];
        int ok = md->space_ok[lb_class(md, b) * NLB + cx];
        if (is_pi(b)) {
          uint8_t pb = last_non_space > 0 ? lb_class(md, t[last_non_space - 1]) : SP;
          if (pb == SP || pb == OP || pb == QU || pb == GL) ok = 0;
        }
        if (is_pf(x)) {
          uint8_t nx = i + 1 < len ? lb_class(md, t[i + 1]) : SP;
          if (nx == SP || nx == CL || nx == CP || nx == EX || nx == IS || nx == SY || nx == QU) ok = 0;
        }
        if (ok) {
          r->ends[n] = space_start;
          r->nexts[n++] = i;
        } else {
          push_risky(r, space_start, i);
        }
      }
      ca = cx;
      continue;
    }
    int allowed = !md->no_break[ca * NLB + cx];
    if (allowed && (ca == HY || ca == BA) && cx == AL && (i < 2 || t[i - 2] == 0x20)) allowed = 0;
    if (allowed) {
      uint8_t nx = i + 1 < len ? lb_class(md, t[i + 1]) : XX;
      if ((ca == PR || ca == PO) && (cx == OP || cx == HY) && nx == NU) allowed = 0;
      if (in_number && (cx == NU || cx == SY || cx == IS || cx == CL || cx == CP)) allowed = 0;
      if ((in_number || closed_number) && (cx == PO || cx == PR)) allowed = 0;
    }
    if (allowed) {
      r->ends[n] = i;
      r->nexts[n++] = i;
    }
    ca = cx;
  }
  int32_t end = len;
  while (end > 0 && t[end - 1] == 0x20) end--;
  r->ends[n] = end;
  r->nexts[n++] = len;
  r->count = n;
  return 1;
}

// Width prefix and break opportunities (Dart: buildRecords).
static int build(const Model *md, const uint16_t *t, int32_t len, Records *r) {
  grow_prefix(r, len + 1);
  double *prefix = r->prefix;
  const int n1 = md->n1, m = md->m;
  double p = 0.0;
  int prev_id = 0;
  int64_t prev_island = -1;
  int run = SC_COMMON;
  for (int32_t q = 0; q < len && run == SC_COMMON; q++) run = script_of(t[q]);
  int32_t i = 0;
  while (i < len) {
    uint16_t cu = t[i];
    int id = md->id_of[cu];
    if (id == 0) return 0;
    uint8_t c = md->cert[id];
    if (c == CERT_U) return 0;
    int s = script_of(cu);
    if (s != SC_COMMON && s != run) {
      run = s;
      prev_id = 0;
      prev_island = -1;
    }
    if (c != CERT_S) {
      int32_t j = i;
      int64_t key = 0;
      int primer = 0;
      while (j < len) {
        int q = md->id_of[t[j]];
        int dj = md->island_digit[q];
        if (q == 0 || dj < 0) break;
        primer = primer || md->cert[q] == CERT_P;
        if (j - i < m) key = key * md->key_base + dj + 1;
        j++;
      }
      if (primer) {
        if (j - i > m) return 0;
        int32_t isl = md->island_of_key[key];
        if (isl < 0) return 0;
        if (prev_id != 0) p += md->island_l[(int64_t)isl * n1 + prev_id];
        prefix[i] = p;
        for (int32_t q = i + 1; q < j; q++) prefix[q] = NAN;
        p += md->island_w[isl];
        prev_id = 0;
        prev_island = isl;
        i = j;
        continue;
      }
      for (; i < j; i++) {
        int q = md->id_of[t[i]];
        if (prev_id != 0) p += md->cls[md->fc[prev_id] + md->sc[q]];
        else if (prev_island >= 0) p += md->island_r[prev_island * n1 + q];
        prefix[i] = p;
        p += md->adv[q];
        prev_id = q;
        prev_island = -1;
      }
      continue;
    }
    if (prev_id != 0) p += md->cls[md->fc[prev_id] + md->sc[id]];
    else if (prev_island >= 0) p += md->island_r[prev_island * n1 + id];
    prefix[i] = p;
    p += md->adv[id];
    prev_id = id;
    prev_island = -1;
    i++;
  }
  prefix[len] = p;
  if (!opportunities(md, t, len, r)) return 0;
  for (int32_t j = 0; j < r->count; j++)
    if (isnan(prefix[r->ends[j]]) || isnan(prefix[r->nexts[j]])) return 0;
  return 1;
}

typedef struct {
  double scale, max_width, max_f, rel, hundredth, tenth;
  int unsure;
} Fit;

static inline int fits(Fit *f, double start_units, double end_units) {
  double w = (end_units - start_units) * f->scale;
  double margin = 0.02 + f->rel * 2 * end_units * f->scale;
  if (w <= f->max_width - margin) return 1;
  if (w >= f->max_width + margin) return 0;
  int ok = fits_line(w, f->max_f, f->hundredth, f->tenth);
  if (f->rel > 0) {
    double d = f->rel * 2 * end_units * f->scale + 1e-4;
    if (fits_line(w - d, f->max_f, f->hundredth, f->tenth) != fits_line(w + d, f->max_f, f->hundredth, f->tenth)) f->unsure = 1;
  }
  return ok;
}

// Greedy line starts (Dart: Records.lineStarts): the line count, or -1 when
// Flutter must decide; starts are written when given.
static int32_t wrap(const Model *md, const Records *r, int32_t len, double max_width, double scale, int32_t *starts,
                    int32_t cap) {
  const double *prefix = r->prefix;
  Fit f = {scale, max_width, f32r(max_width), exact_positions(scale, prefix[len] * scale) ? 0.0 : DRIFT_PER_PX,
           md->hundredth, md->tenth, 0};
  const int32_t count = r->count;
  int32_t lines = 1, s = 0, k = 0;
  if (starts && cap > 0) starts[0] = 0;
  for (;;) {
    int32_t best = -1;
    double p0 = prefix[s];
    for (int32_t j = k; j < count; j++) {
      if (fits(&f, p0, prefix[r->ends[j]])) best = j;
      else break;
    }
    if (best < 0 || f.unsure) return -1;
    if (r->risky > 0) {
      int32_t from = r->nexts[best], to = best + 1 < count ? r->nexts[best + 1] : 1 << 30;
      for (int32_t q = 0; q < r->risky; q++)
        if (r->risky_nexts[q] > from && r->risky_nexts[q] < to && fits(&f, p0, prefix[r->risky_ends[q]])) return -1;
      if (f.unsure) return -1;
    }
    if (best == count - 1) return lines;
    s = r->nexts[best];
    if (starts && lines < cap) starts[lines] = s;
    lines++;
    k = best + 1;
  }
}

// ---------------------------------------------------------------------------
// The sidecar (BFW2): big-endian header, JSON meta, then little-endian arrays.
static size_t json_int(const char *meta, size_t len, const char *key) {
  char pat[64];
  size_t kl = strlen(key), pl = kl + 3;
  pat[0] = '"';
  memcpy(pat + 1, key, kl);
  pat[kl + 1] = '"';
  pat[kl + 2] = ':';
  for (size_t i = 0; i + pl <= len; i++)
    if (memcmp(meta + i, pat, pl) == 0) {
      size_t v = 0;
      for (size_t j = i + pl; j < len && meta[j] >= '0' && meta[j] <= '9'; j++) v = v * 10 + (size_t)(meta[j] - '0');
      return v;
    }
  return 0;
}

static uint32_t be32(const uint8_t *b) { return (uint32_t)b[0] << 24 | (uint32_t)b[1] << 16 | (uint32_t)b[2] << 8 | b[3]; }

static int32_t *read_i32(const uint8_t *b, size_t *off, size_t n) {
  int32_t *v = malloc(sizeof(int32_t) * (n ? n : 1));
  memcpy(v, b + *off, 4 * n);
  *off += 4 * n;
  return v;
}

static double *read_f32(const uint8_t *b, size_t *off, size_t n) {
  double *v = malloc(sizeof(double) * (n ? n : 1));
  for (size_t k = 0; k < n; k++) {
    float x;
    memcpy(&x, b + *off + 4 * k, 4);
    v[k] = x;
  }
  *off += 4 * n;
  return v;
}

// Native memory for Dart to fill (the sidecar bytes before bf_model_new).
EXPORT uint8_t *bf_alloc(size_t n) { return malloc(n ? n : 1); }
EXPORT void bf_release(uint8_t *p) { free(p); }

// Decodes a sidecar; NULL if it is not one. Free with bf_model_free.
EXPORT Model *bf_model_new(const uint8_t *bytes, size_t len) {
  if (len < 8 || be32(bytes) != 0x42465732) return NULL;
  size_t meta_len = be32(bytes + 4);
  const char *meta = (const char *)bytes + 8;
  size_t n1 = json_int(meta, meta_len, "n1"), ns = json_int(meta, meta_len, "nS"), nf = json_int(meta, meta_len, "nF");
  size_t ni = json_int(meta, meta_len, "islandChars"), keys = json_int(meta, meta_len, "keys");
  size_t islands = json_int(meta, meta_len, "islands");
  Model *md = calloc(1, sizeof(Model));
  md->m = (int)json_int(meta, meta_len, "m");
  md->n1 = (int)n1;
  size_t off = (8 + meta_len + 3) & ~(size_t)3;
  int32_t *cps = read_i32(bytes, &off, n1);
  md->cert = malloc(n1);
  memcpy(md->cert, bytes + off, n1);
  off = (off + n1 + 3) & ~(size_t)3;
  md->adv = read_f32(bytes, &off, n1);
  md->fc = read_i32(bytes, &off, n1);
  for (size_t a = 0; a < n1; a++) md->fc[a] *= (int32_t)ns;
  md->sc = read_i32(bytes, &off, n1);
  md->cls = read_f32(bytes, &off, nf * ns);
  int32_t *island_chars = read_i32(bytes, &off, ni);
  md->island_of_key = read_i32(bytes, &off, keys);
  md->island_w = read_f32(bytes, &off, islands);
  size_t n_safe = 0;
  for (size_t id = 1; id < n1; id++) n_safe += md->cert[id] == CERT_S;
  double *lr = read_f32(bytes, &off, islands * n_safe * 2);
  md->island_l = malloc(sizeof(double) * (islands * n1 ? islands * n1 : 1));
  md->island_r = malloc(sizeof(double) * (islands * n1 ? islands * n1 : 1));
  for (size_t k = 0; k < islands * n1; k++) md->island_l[k] = md->island_r[k] = NAN;
  size_t o = 0;
  for (size_t i = 0; i < islands; i++)
    for (size_t x = 1; x < n1; x++)
      if (md->cert[x] == CERT_S) {
        md->island_l[i * n1 + x] = lr[o++];
        md->island_r[i * n1 + x] = lr[o++];
      }
  free(lr);
  md->id_of = calloc(0x10000, sizeof(uint16_t));
  for (size_t id = 1; id < n1; id++) md->id_of[cps[id]] = (uint16_t)id;
  md->island_digit = malloc(n1);
  memset(md->island_digit, -1, n1);
  for (size_t d = 0; d < ni; d++) md->island_digit[island_chars[d]] = (int8_t)d;
  md->key_base = (int64_t)ni + 1;
  free(cps);
  free(island_chars);
  build_tables(md);
  md->hundredth = f32r(1.0 / 100);
  md->tenth = f32r(1.0 / 10);
  return md;
}

static void free_stored(Model *md) {
  for (size_t i = 0; i < md->n_stored; i++) free_records(&md->stored[i]);
  free(md->stored);
  free(md->stored_ok);
  md->stored = NULL;
  md->stored_ok = NULL;
  md->n_stored = 0;
}

EXPORT void bf_model_free(Model *md) {
  free_stored(md);
  free_records(&md->scratch);
  free(md->cert); free(md->adv); free(md->cls); free(md->island_w); free(md->island_l); free(md->island_r);
  free(md->fc); free(md->sc); free(md->island_of_key); free(md->id_of); free(md->island_digit);
  free(md->text); free(md->offsets); free(md->out);
  free(md);
}

// Room for n paragraphs of `units` UTF-16 code units in all; returns the text
// buffer. bf_offsets has n + 1 entries (paragraph i is [offsets[i], offsets[i+1])),
// bf_out n.
EXPORT uint16_t *bf_reserve(Model *md, size_t units, size_t n) {
  if (md->cap_text < units) {
    md->cap_text = units * 2;
    md->text = realloc(md->text, sizeof(uint16_t) * md->cap_text);
  }
  if (md->cap_n < n + 1) {
    md->cap_n = (n + 1) * 2;
    md->offsets = realloc(md->offsets, sizeof(uint32_t) * md->cap_n);
    md->out = realloc(md->out, sizeof(int32_t) * md->cap_n);
  }
  return md->text;
}

EXPORT uint32_t *bf_offsets(Model *md) { return md->offsets; }
EXPORT int32_t *bf_out(Model *md) { return md->out; }

// Line counts of the n paragraphs in the buffer at one width: out[i] is the
// count, or -1 when Flutter must decide.
EXPORT void bf_line_counts(Model *md, size_t n, double max_width, double scale) {
  for (size_t i = 0; i < n; i++) {
    const uint16_t *t = md->text + md->offsets[i];
    int32_t len = (int32_t)(md->offsets[i + 1] - md->offsets[i]);
    md->out[i] = build(md, t, len, &md->scratch) ? wrap(md, &md->scratch, len, max_width, scale, NULL, 0) : -1;
  }
}

// Keeps each paragraph's records for bf_rewrap; returns how many were covered.
EXPORT size_t bf_prepare(Model *md, size_t n) {
  free_stored(md);
  md->stored = calloc(n ? n : 1, sizeof(Records));
  md->stored_ok = calloc(n ? n : 1, 1);
  md->n_stored = n;
  size_t covered = 0;
  for (size_t i = 0; i < n; i++) {
    const uint16_t *t = md->text + md->offsets[i];
    int32_t len = (int32_t)(md->offsets[i + 1] - md->offsets[i]);
    md->stored_ok[i] = (uint8_t)build(md, t, len, &md->stored[i]);
    covered += md->stored_ok[i];
  }
  return covered;
}

// Line counts at a new width from the kept records, into out.
EXPORT void bf_rewrap(Model *md, double max_width, double scale) {
  for (size_t i = 0; i < md->n_stored; i++) {
    int32_t len = (int32_t)(md->offsets[i + 1] - md->offsets[i]);
    md->out[i] = md->stored_ok[i] ? wrap(md, &md->stored[i], len, max_width, scale, NULL, 0) : -1;
  }
}

// Line starts of paragraph i of the buffer into starts (capacity cap); returns
// the line count, or -1 when Flutter must decide. For checking against Dart.
EXPORT int32_t bf_line_starts(Model *md, size_t i, double max_width, double scale, int32_t *starts, int32_t cap) {
  const uint16_t *t = md->text + md->offsets[i];
  int32_t len = (int32_t)(md->offsets[i + 1] - md->offsets[i]);
  return build(md, t, len, &md->scratch) ? wrap(md, &md->scratch, len, max_width, scale, starts, cap) : -1;
}
