# NEXUS Typography

**Inter** (Latin) + **Vazirmatn** (Persian/Arabic) + **JetBrains Mono**
(metrics, code, logs). Bundled as variable fonts; `fontFamilyFallback`
chains Inter → Vazirmatn → system so mixed-script strings render correctly.

## Scale (ratio 1.25, base 14)

| Style | Size/Height | Weight | Usage |
|---|---|---|---|
| `display` | 32/40 | 650 | dashboard state word (CONNECTED) |
| `title` | 20/28 | 600 | screen titles |
| `headline` | 16/24 | 600 | card titles, section headers |
| `body` | 14/20 | 400/500 | default |
| `bodyStrong` | 14/20 | 600 | emphasized rows |
| `caption` | 12/16 | 500 | chips, secondary meta |
| `overline` | 11/14 | 600, +6% tracking | section labels |
| `metric` | mono, tabular figures | 500–650 | latency, speeds, counters |

## Rules

* All numerals in metrics/logs/IPs use JetBrains Mono with
  `FontFeature.tabularFigures()` — columns never jitter during updates.
* Persian: numerals stay Latin in metrics (per RTL rule), body text uses
  Vazirmatn; never force RTL on mono metric strings.
* Minimum body size 12; user text-scale setting multiplies the whole scale
  (accessibility) — layouts must tolerate 1.3× without overflow
  (verified in widget tests with `textScaleFactor: 1.3`).
* Line length ≤ 68ch for helper text; headings never wrap mid-word (Persian).
* Weights: only 400/500/600/650; no light weights on dark backgrounds.
