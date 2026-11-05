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

<!-- native -->
Exactness: the line starts match the Dart breaker in 2,552,760 of 2,552,760 checks (9 corpora, 6 sizes, 12 widths) on macOS, and in 2,552,760 of 2,552,760 on the Android emulator. CI repeats the check on Linux and macOS (`test/native_exact_test.dart`).

Speed: macOS is the median of 3 runs on an Apple M3 ([native_macos.json](../flutter_bench/results/native_macos.json)). The Android emulator (arm64, on the same Mac) is 1 run ([native_android_emu.json](../flutter_bench/results/native_android_emu.json)).

|  | macOS: Dart → C | Android emulator: Dart → C |
|---|---|---|
| Breaker, docs (5,170 paragraphs) | 23.3 → 6.7 ms (3.5×) | 24.0 → 7.0 ms (3.4×) |
| Breaker, chat (24,000 messages) | 40.5 → 10.0 ms (4.0×) | 40.8 → 11.8 ms (3.5×) |
| Re-wrap at a new width, docs / chat | 4.9× / 3.7× | 6.6× / 2.8× |
| Heights end to end, chat (fallbacks to Flutter included) | 3.7× | 4.1× |
| TextPainter for the same chat heights | 570 ms | 1,041 ms |

Per code unit on the Mac, the Dart breaker takes 29.6 ns and C 7.3 ns (chat), copying the text into native memory included (0.9 ns). One call per paragraph costs 9.9 ms against 10.0 ms batched.

## Verdict

C is 3.5× (docs) and 4.0× (chat) faster than the Dart breaker on the Mac, and exact. The Dart breaker is itself 10× (docs) and 14× (chat) cheaper than `TextPainter` on the same work; for 24,000 chat messages, C saves another 31 ms on the Mac and 36 ms on the emulator. The package keeps the Dart breaker, which runs on the web (no `dart:ffi` there) and in any isolate with no native build per platform. This port stays as a measured, exactness-checked option.
<!-- /native -->
