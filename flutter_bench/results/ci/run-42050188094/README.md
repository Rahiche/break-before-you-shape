# Benchmarks on GitHub Actions

Run [42050188094](https://github.com/Rahiche/break-before-you-shape/actions/runs/42050188094) of `bench.yml`, 2026-11-05, on 7061092 (the 1.9× faster breaker), Flutter 3.47.5. Each job generated its corpora from its own runner's files, so the paragraphs differ from the paper's (and between platforms).

Machines: macOS jobs on Apple M1 (Virtual) (3 cores, macOS 15.8.2); Linux on AMD EPYC 7763 (4 vCPUs, Ubuntu 24.04.5 LTS); Android API 35 x86_64 emulator on Linux with KVM; iOS simulator on the macOS runner (debug build, exactness only).

## Exactness: line breaks and heights vs Flutter's own layout

| Run | Platform | Corpora | Identical | Different | Deferred | Lines | Heights equal | Canary | Size quantized |
|---|---|---|---|---|---|---|---|---|---|
| android_emu | android | 9 | 190,348 | **0** | 3,836 | 633,953 | 190,348 of 190,348 | pass (0 px) | True |
| ios_sim | ios | 9 | 192,168 | **0** | 1,872 | 596,227 | 192,168 of 192,168 | pass (0 px) | False |
| linux_host | linux | 9 | 76,196 | **0** | 1,420 | 239,319 | 76,196 of 76,196 | pass (0 px) | True |
| linux_release | linux | 9 | 2,475,208 | **0** | 43,568 | 7,705,097 | 2,475,208 of 2,475,208 | pass (0 px) | True |
| macos_host | macos | 9 | 76,836 | **0** | 852 | 237,515 | 76,836 of 76,836 | pass (0 px) | False |
| macos_release | macos | 9 | 2,518,525 | **0** | 22,283 | 7,129,715 | 2,518,525 of 2,518,525 | pass (0 px) | False |

## Style options and hard line breaks: line breaks and heights vs Flutter

| Run | Option | Identical | Different | Deferred | Heights equal |
|---|---|---|---|---|---|
| android_styles | hard breaks | 125,135 | **0** | 4,465 | 125,135 of 125,135 |
| android_styles | letterSpacing 0.5 | 124,184 | **0** | 5,416 | 124,184 of 124,184 |
| android_styles | letterSpacing -0.3 | 123,595 | **0** | 6,005 | 123,595 of 123,595 |
| android_styles | wordSpacing 2 | 125,201 | **0** | 4,399 | 125,201 of 125,201 |
| android_styles | height 1.3 | 125,135 | **0** | 4,465 | 125,135 of 125,135 |
| android_styles | maxLines 3 | 125,135 | **0** | 4,465 | 125,135 of 125,135 |
| android_styles | combined | 121,811 | **0** | 7,789 | 121,811 of 121,811 |
| android_styles | strut 20 px, forced | 125,135 | **0** | 4,465 | 125,135 of 125,135 |
| android_styles | strut height 1.6, leading 0.4 | 125,135 | **0** | 4,465 | 125,135 of 125,135 |
| android_styles | height 1.5, no first ascent or last descent | 125,135 | **0** | 4,465 | 125,135 of 125,135 |
| android_styles | height 1.4, even leading | 125,135 | **0** | 4,465 | 125,135 of 125,135 |
| ios_styles | hard breaks | 125,491 | **0** | 4,109 | 125,491 of 125,491 |
| ios_styles | letterSpacing 0.5 | 125,392 | **0** | 4,208 | 125,392 of 125,392 |
| ios_styles | letterSpacing -0.3 | 123,199 | **0** | 6,401 | 123,199 of 123,199 |
| ios_styles | wordSpacing 2 | 125,458 | **0** | 4,142 | 125,458 of 125,458 |
| ios_styles | height 1.3 | 125,491 | **0** | 4,109 | 125,491 of 125,491 |
| ios_styles | maxLines 3 | 125,491 | **0** | 4,109 | 125,491 of 125,491 |
| ios_styles | combined | 122,563 | **0** | 7,037 | 122,563 of 122,563 |
| ios_styles | strut 20 px, forced | 125,491 | **0** | 4,109 | 125,491 of 125,491 |
| ios_styles | strut height 1.6, leading 0.4 | 125,491 | **0** | 4,109 | 125,491 of 125,491 |
| ios_styles | height 1.5, no first ascent or last descent | 125,491 | **0** | 4,109 | 125,491 of 125,491 |
| ios_styles | height 1.4, even leading | 125,491 | **0** | 4,109 | 125,491 of 125,491 |
| linux_styles | hard breaks | 641,711 | **0** | 31,009 | 641,711 of 641,711 |
| linux_styles | letterSpacing 0.5 | 636,879 | **0** | 35,841 | 636,879 of 636,879 |
| linux_styles | letterSpacing -0.3 | 631,661 | **0** | 41,059 | 631,661 of 631,661 |
| linux_styles | wordSpacing 2 | 642,094 | **0** | 30,626 | 642,094 of 642,094 |
| linux_styles | height 1.3 | 641,711 | **0** | 31,009 | 641,711 of 641,711 |
| linux_styles | maxLines 3 | 641,711 | **0** | 31,009 | 641,711 of 641,711 |
| linux_styles | combined | 621,740 | **0** | 50,980 | 621,740 of 621,740 |
| linux_styles | strut 20 px, forced | 641,711 | **0** | 31,009 | 641,711 of 641,711 |
| linux_styles | strut height 1.6, leading 0.4 | 641,711 | **0** | 31,009 | 641,711 of 641,711 |
| linux_styles | height 1.5, no first ascent or last descent | 641,711 | **0** | 31,009 | 641,711 of 641,711 |
| linux_styles | height 1.4, even leading | 641,711 | **0** | 31,009 | 641,711 of 641,711 |
| macos_styles | hard breaks | 653,098 | **0** | 20,966 | 653,098 of 653,098 |
| macos_styles | letterSpacing 0.5 | 650,604 | **0** | 23,460 | 650,604 of 650,604 |
| macos_styles | letterSpacing -0.3 | 642,042 | **0** | 32,022 | 642,042 of 642,042 |
| macos_styles | wordSpacing 2 | 652,761 | **0** | 21,303 | 652,761 of 652,761 |
| macos_styles | height 1.3 | 653,098 | **0** | 20,966 | 653,098 of 653,098 |
| macos_styles | maxLines 3 | 653,098 | **0** | 20,966 | 653,098 of 653,098 |
| macos_styles | combined | 637,050 | **0** | 37,014 | 637,050 of 637,050 |
| macos_styles | strut 20 px, forced | 653,098 | **0** | 20,966 | 653,098 of 653,098 |
| macos_styles | strut height 1.6, leading 0.4 | 653,098 | **0** | 20,966 | 653,098 of 653,098 |
| macos_styles | height 1.5, no first ascent or last descent | 653,098 | **0** | 20,966 | 653,098 of 653,098 |
| macos_styles | height 1.4, even leading | 653,098 | **0** | 20,966 | 653,098 of 653,098 |

## Right-to-left, mixed-direction and CJK paragraphs (UI strings)

| Run | Case | Identical | Different | Deferred | Heights equal |
|---|---|---|---|---|---|
| linux_cjk_ipagothic | ui_ja messages | 7,764 | **0** | 10,236 | 7,764 |
| linux_cjk_ipagothic | ui_ja joined with hard breaks | 738 | **0** | 5,256 | 738 |
| linux_cjk_ipagothic | ui_ja letterSpacing 0.5, wordSpacing 1 | 1,047 | **0** | 16,953 | 1,047 |
| linux_cjk_ipagothic | ui_zh_CN messages | 1,999 | **0** | 16,001 | 1,999 |
| linux_cjk_ipagothic | ui_zh_CN joined with hard breaks | 0 | **0** | 5,994 | 0 |
| linux_cjk_ipagothic | ui_zh_CN letterSpacing 0.5, wordSpacing 1 | 1,999 | **0** | 16,001 | 1,999 |
| linux_cjk_ipagothic | ui_ko messages | 312 | **0** | 17,688 | 312 |
| linux_cjk_ipagothic | ui_ko joined with hard breaks | 0 | **0** | 5,994 | 0 |
| linux_cjk_ipagothic | ui_ko letterSpacing 0.5, wordSpacing 1 | 312 | **0** | 17,688 | 312 |
| linux_cjk_nanumgothic | ui_ja messages | 10,055 | **0** | 7,945 | 10,055 |
| linux_cjk_nanumgothic | ui_ja joined with hard breaks | 1,442 | **0** | 4,552 | 1,442 |
| linux_cjk_nanumgothic | ui_ja letterSpacing 0.5, wordSpacing 1 | 10,001 | **0** | 7,999 | 10,001 |
| linux_cjk_nanumgothic | ui_zh_CN messages | 828 | **0** | 17,172 | 828 |
| linux_cjk_nanumgothic | ui_zh_CN joined with hard breaks | 0 | **0** | 5,994 | 0 |
| linux_cjk_nanumgothic | ui_zh_CN letterSpacing 0.5, wordSpacing 1 | 833 | **0** | 17,167 | 833 |
| linux_cjk_nanumgothic | ui_ko messages | 17,638 | **0** | 362 | 17,638 |
| linux_cjk_nanumgothic | ui_ko joined with hard breaks | 5,645 | **0** | 349 | 5,645 |
| linux_cjk_nanumgothic | ui_ko letterSpacing 0.5, wordSpacing 1 | 17,597 | **0** | 403 | 17,597 |
| linux_cjk_wqy_microhei | ui_ja messages | 17,292 | **0** | 708 | 17,292 |
| linux_cjk_wqy_microhei | ui_ja joined with hard breaks | 5,014 | **0** | 980 | 5,014 |
| linux_cjk_wqy_microhei | ui_ja letterSpacing 0.5, wordSpacing 1 | 17,561 | **0** | 439 | 17,561 |
| linux_cjk_wqy_microhei | ui_zh_CN messages | 17,434 | **0** | 566 | 17,434 |
| linux_cjk_wqy_microhei | ui_zh_CN joined with hard breaks | 5,285 | **0** | 709 | 5,285 |
| linux_cjk_wqy_microhei | ui_zh_CN letterSpacing 0.5, wordSpacing 1 | 17,545 | **0** | 455 | 17,545 |
| linux_cjk_wqy_microhei | ui_ko messages | 17,706 | **0** | 294 | 17,706 |
| linux_cjk_wqy_microhei | ui_ko joined with hard breaks | 5,682 | **0** | 312 | 5,682 |
| linux_cjk_wqy_microhei | ui_ko letterSpacing 0.5, wordSpacing 1 | 17,590 | **0** | 410 | 17,590 |
| linux_rtl_noto_sans_hebrew | messages | 14,291 | **0** | 57,709 | 14,291 |
| linux_rtl_noto_sans_hebrew | messages joined with hard breaks | 2,127 | **0** | 21,867 | 2,127 |
| linux_rtl_noto_sans_hebrew | letterSpacing 0.5, wordSpacing 1 | 14,210 | **0** | 57,790 | 14,210 |
| linux_rtl_noto_sans_hebrew | mixed: RTL paragraphs | 14,276 | **0** | 57,724 | 14,276 |
| linux_rtl_noto_sans_hebrew | mixed: RTL paragraphs with hard breaks | 2,127 | **0** | 21,867 | 2,127 |
| linux_rtl_noto_sans_hebrew | mixed: RTL paragraphs, spaced | 14,195 | **0** | 57,805 | 14,195 |
| linux_rtl_noto_sans_hebrew | mixed: LTR paragraphs | 14,276 | **0** | 57,724 | 14,276 |
| macos_cjk_hiragino | ui_ja messages | 56,613 | **0** | 15,387 | 56,613 |
| macos_cjk_hiragino | ui_ja joined with hard breaks | 11,481 | **0** | 12,513 | 11,481 |
| macos_cjk_hiragino | ui_ja letterSpacing 0.5, wordSpacing 1 | 68,594 | **0** | 3,406 | 68,594 |
| macos_cjk_hiragino | ui_zh_CN messages | 59,796 | **0** | 12,204 | 59,796 |
| macos_cjk_hiragino | ui_zh_CN joined with hard breaks | 13,665 | **0** | 10,329 | 13,665 |
| macos_cjk_hiragino | ui_zh_CN letterSpacing 0.5, wordSpacing 1 | 68,606 | **0** | 3,394 | 68,606 |
| macos_cjk_hiragino | ui_ko messages | 15,822 | **0** | 56,178 | 15,822 |
| macos_cjk_hiragino | ui_ko joined with hard breaks | 2,565 | **0** | 21,429 | 2,565 |
| macos_cjk_hiragino | ui_ko letterSpacing 0.5, wordSpacing 1 | 14,692 | **0** | 57,308 | 14,692 |
| macos_cjk_sdgothic | ui_ja messages | 53,295 | **0** | 18,705 | 53,295 |
| macos_cjk_sdgothic | ui_ja joined with hard breaks | 10,470 | **0** | 13,524 | 10,470 |
| macos_cjk_sdgothic | ui_ja letterSpacing 0.5, wordSpacing 1 | 53,012 | **0** | 18,988 | 53,012 |
| macos_cjk_sdgothic | ui_zh_CN messages | 13,503 | **0** | 58,497 | 13,503 |
| macos_cjk_sdgothic | ui_zh_CN joined with hard breaks | 1,272 | **0** | 22,722 | 1,272 |
| macos_cjk_sdgothic | ui_zh_CN letterSpacing 0.5, wordSpacing 1 | 13,435 | **0** | 58,565 | 13,435 |
| macos_cjk_sdgothic | ui_ko messages | 71,098 | **0** | 902 | 71,098 |
| macos_cjk_sdgothic | ui_ko joined with hard breaks | 23,153 | **0** | 841 | 23,153 |
| macos_cjk_sdgothic | ui_ko letterSpacing 0.5, wordSpacing 1 | 70,925 | **0** | 1,075 | 70,925 |
| macos_rtl_arial | messages | 36,993 | **0** | 35,007 | 36,993 |
| macos_rtl_arial | messages joined with hard breaks | 7,395 | **0** | 16,599 | 7,395 |
| macos_rtl_arial | letterSpacing 0.5, wordSpacing 1 | 36,924 | **0** | 35,076 | 36,924 |
| macos_rtl_arial | mixed: RTL paragraphs | 62,944 | **0** | 9,056 | 62,944 |
| macos_rtl_arial | mixed: RTL paragraphs with hard breaks | 17,838 | **0** | 6,156 | 17,838 |
| macos_rtl_arial | mixed: RTL paragraphs, spaced | 55,236 | **0** | 16,764 | 55,236 |
| macos_rtl_arial | mixed: LTR paragraphs | 66,329 | **0** | 5,671 | 66,329 |

## Speed vs TextPainter (median over runs)

| Platform | Runs | Docs | Chat | Re-wrap docs | Re-wrap chat | List extents (break-first / TextPainter) |
|---|---|---|---|---|---|---|
| android_emu | 1 | 41.5× | 37.1× | 17.2× | 16.3× | 82 ms / 1681 ms (20.4×) |
| linux | 3 | 19.1× | 26.7× | 13.4× | 10.4× | 73 ms / 1159 ms (15.9×) |
| macos | 3 | 23.4× | 31.7× | 14.9× | 16.8× | 48 ms / 935 ms (19.7×) |

List-extents demo recorded on the Android emulator job ([numbers](android_demo_measured.txt)): the stock ListView asked for #2,500 lands on #1,969 (553 ms frame); with break-first extents it lands on #2,500 (13 ms frame); 10,000 of 10,000 extents equal TextPainter's.
