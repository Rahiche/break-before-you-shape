**Accuracy** (share of paragraphs whose breaks equal ground truth)

| Font | glyph-changing pairs / width residuals | model KB | distill s | model widths exact | break-first | hybrid (decisions shaped) | shape-first | word cache |
|---|--:|--:|--:|--:|--:|--:|--:|--:|
| Helvetica | 2 / 2 | 6.8 | 0.43 | 100% | 100% | 100% (0.000%) | 99.932% | 99.268% |
| Helvetica Neue | 3 / 4 | 7.2 | 0.40 | 100% | 100% | 100% (0.000%) | 100% | 100% |
| System Font | 13294 / 275 | 81.4 | 12.02 | 100% | 100% | 100% (0.004%) | 99.468% | 96.441% |
| New York | 15 / 0 | 21.8 | 0.56 | 100% | 100% | 100% (0.000%) | 99.994% | 99.965% |
| Avenir Next Bold | 2 / 0 | 23.4 | 0.42 | 100% | 100% | 100% (0.000%) | 99.458% | 97.682% |
| Palatino | 2 / 2 | 5.9 | 0.42 | 100% | 100% | 100% (0.000%) | 99.987% | 99.684% |
| Georgia | 0 / 0 | 3.6 | 0.23 | 100% | 100% | 100% (0.000%) | 100% | 100% |
| Times New Roman | 0 / 0 | 6.9 | 0.41 | 100% | 100% | 100% (0.004%) | 99.939% | 99.31% |
| Baskerville | 2 / 3 | 16.5 | 0.67 | 100% | 100% | 100% (0.000%) | 99.626% | 94.61% |
| Hoefler Text | 14 / 109 | 15.1 | 0.52 | 100% | 100% | 100% (0.000%) | 99.894% | 98.897% |
| Charter Roman | 0 / 0 | 7.5 | 0.29 | 100% | 100% | 100% (0.000%) | 100% | 99.987% |
| Didot | 2 / 0 | 9.7 | 0.50 | 100% | 100% | 100% (0.000%) | 99.594% | 94.72% |
| Gill Sans | 2 / 2 | 9.1 | 0.39 | 100% | 100% | 100% (0.000%) | 98.839% | 90.358% |
| Futura Medium | 2 / 14 | 29.6 | 0.48 | 100% | 100% | 100% (0.052%) | 100% | 99.994% |
| Zapfino | 31 / 579 | 30.0 | 1.15 | 77.2688% | 85.048% | 99.994% (13.473%) | 97.927% | 85.048% |

**Speed** (ns per byte of UTF-8 input, one M3 core)

| Font | break-first | shape-first (no reshape) | warm word cache | rewrap (pass C only) | vs shape-first |
|---|--:|--:|--:|--:|--:|
| Helvetica | 1.89 | 56.0 | 4.0 | 0.265 | 30x |
| Helvetica Neue | 1.96 | 51.9 | 4.1 | 0.267 | 26x |
| System Font | 1.72 | 87.4 | 4.1 | 0.301 | 51x |
| New York | 1.64 | 59.8 | 4.0 | 0.249 | 36x |
| Avenir Next Bold | 1.90 | 52.9 | 4.0 | 0.282 | 28x |
| Palatino | 1.94 | 57.4 | 4.0 | 0.263 | 30x |
| Georgia | 1.62 | 16.3 | 4.1 | 0.263 | 10x |
| Times New Roman | 1.75 | 32.0 | 4.0 | 0.264 | 18x |
| Baskerville | 1.87 | 92.0 | 4.0 | 0.248 | 49x |
| Hoefler Text | 1.93 | 81.2 | 4.0 | 0.271 | 42x |
| Charter Roman | 1.68 | 21.9 | 4.1 | 0.264 | 13x |
| Didot | 1.89 | 73.8 | 4.1 | 0.281 | 39x |
| Gill Sans | 1.89 | 56.0 | 4.0 | 0.251 | 30x |
| Futura Medium | 2.60 | 65.8 | 4.3 | 0.596 | 25x |
| Zapfino | 191.32 | 199.5 | 4.1 | 197.258 | 1x |
