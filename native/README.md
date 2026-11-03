# Native breaker experiment (C through dart:ffi)

Is moving the breaker from Dart to native code worth an FFI boundary? `break_first.c` is a line-for-line port of
[width_model.dart](../packages/break_first/lib/src/width_model.dart): same tables, same float arithmetic in the same
order (multiply-add fusion off), same rules. The bench app runs both in one release build (`BF_MODE=native`). It first
checks that every answer matches, then times the same work both ways. The C timings include copying the paragraphs
into native memory.

```sh
cc -O3 -std=c11 -ffp-contract=off -shared -fPIC -o libbreak_first.dylib native/break_first.c
cd flutter_bench && flutter build macos --release --dart-define=BF_MODE=native
BF_NATIVE_LIB=$PWD/../libbreak_first.dylib build/macos/Build/Products/Release/bf_bench.app/Contents/MacOS/bf_bench
```

## Results

Exactness: the line starts match the Dart breaker in 2,552,760 of 2,552,760 checks (9 corpora, 6 sizes, 12 widths) on
macOS, and in 194,400 of 194,400 on the Android emulator. CI repeats the check on Linux and macOS
(`test/native_exact_test.dart`).

Speed: macOS is the median of 3 runs on an Apple M3 ([native_macos.json](../flutter_bench/results/native_macos.json)).
The Android emulator (arm64, on the same Mac) is one run ([native_android_emu.json](../flutter_bench/results/native_android_emu.json)).

| | macOS: Dart → C | Android emulator: Dart → C |
|---|---|---|
| Breaker, docs (5,170 paragraphs) | 12.8 → 6.5 ms (2.0×) | 30.3 → 14.7 ms (2.1×) |
| Breaker, chat (24,000 messages) | 22.2 → 9.7 ms (2.3×) | 22.9 → 9.9 ms (2.3×) |
| Re-wrap at a new width, docs / chat | 2.9× / 2.4× | 4.5× / 2.9× |
| Heights end to end, chat (fallbacks to Flutter included) | 2.2× | 2.5× |
| TextPainter for the same chat heights | 595 ms | 1,100 ms |

Copying the text into native memory costs about 0.7 ns per code unit. Calling once per paragraph costs about the same
as one batched call. In C the width pass takes about 3.5 ns per code unit, finding break opportunities 2.4, and wrapping
0.5.

## Verdict

The native port is consistently about 2× faster, and exact. But the breaker is already 25–45× cheaper than
`TextPainter` on the same work. For 24,000 chat messages, C saves about 13 ms on the Mac and about 16 ms on the emulator.
The package therefore keeps the Dart breaker, which also runs on the web, where `dart:ffi` does not exist. This port
stays as a measured, exactness-checked option.
