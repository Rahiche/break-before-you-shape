# Benchmarks on GitHub Actions

Run [41614792200](https://github.com/Rahiche/break-before-you-shape/actions/runs/41614792200) of `bench.yml`, 2026-11-03, Flutter 3.47.5. Each job generated its corpora from its own runner's files, so the paragraphs differ from the paper's (and between platforms).

Machines: macOS jobs on Apple M1 (Virtual) (3 cores, macOS 15.8.2); Linux on AMD EPYC 7763 64-Core Processor (4 vCPUs, Ubuntu 24.04.5 LTS); Android API 35 x86_64 emulator on Linux with KVM; iOS simulator on the macOS runner (debug build, exactness only).

## Exactness: line breaks and heights vs Flutter's own layout

| Run | Platform | Corpora | Identical | Different | Deferred | Lines | Heights equal | Canary | Size quantized |
|---|---|---|---|---|---|---|---|---|---|
| android_emu | android | 9 | 190,348 | **0** | 3,836 | 633,953 | 190,348 of 190,348 | pass (0 px) | True |
| ios_sim | ios | 9 | 192,168 | **0** | 1,872 | 596,227 | 192,168 of 192,168 | pass (0 px) | False |
| linux_host | linux | 9 | 76,095 | **0** | 1,449 | 241,629 | 76,095 of 76,095 | pass (0 px) | True |
| linux_release | linux | 9 | 2,475,396 | **0** | 43,524 | 7,704,293 | 2,475,396 of 2,475,396 | pass (0 px) | True |
| macos_host | macos | 9 | 76,836 | **0** | 852 | 237,515 | 76,836 of 76,836 | pass (0 px) | False |
| macos_release | macos | 9 | 2,518,521 | **0** | 22,287 | 7,129,655 | 2,518,521 of 2,518,521 | pass (0 px) | False |

## Speed vs TextPainter (median over runs)

| Platform | Runs | Docs | Chat | Re-wrap docs | Re-wrap chat | List extents (break-first / TextPainter) |
|---|---|---|---|---|---|---|
| android_emu | 1 | 24.5× | 38.6× | 9.6× | 11.0× | 78 ms / 1308 ms (16.7×) |
| linux | 3 | 18.9× | 24.7× | 9.3× | 7.1× | 75 ms / 1168 ms (15.5×) |
| macos | 3 | 26.0× | 27.6× | 9.5× | 10.5× | 76 ms / 1413 ms (18.6×) |

List-extents demo recorded on the Android emulator job ([numbers](android_demo_measured.txt)): the stock ListView asked for #2,500 lands on #1,969 (440 ms frame); with break-first extents it lands on #2,500 (12 ms frame); 10,000 of 10,000 extents equal TextPainter's.
