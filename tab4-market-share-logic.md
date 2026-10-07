# Tab 4 — Market Share Logic (Opportunity Engine)

How Tab 4 turns raw market data into a **Category Opportunity Score** and a
**Keep / Develop / Test / Stop** action — computed, not hand-set.

File: `npl-atomic-cockpit.html` · functions `catOpp()`, `catAction()`, `nplCatScore()`,
`verdictCard()`.

---

## 1. Inputs — the signals

Each **flavour × market** cell carries four raw signals:

| Signal | Meaning | Scale |
|---|---|---|
| `g` | flavour / category growth (MAT) | % (e.g. −27.6 … +342) |
| `size` | flavour's share of category value | % of category (0 … ~45) |
| `nab` | Nabati's equity / strength in that flavour | 0–5 (0 = absent, 5 = dominant) |
| `kind` | optional `'inno'` = innovation bet (dark choc, matcha) | flag |

A cell with no data (flavour not material in that market) is `null` → shown as `—`.

## 2. Market stance

Each market is scored through a **stance** that reflects its business problem:

| Market | Stance | Meaning | Growth weight `mf` |
|---|---|---|---|
| 🇮🇩 Indonesia | `opportunity` | flat market → **gain share** | 1.00 |
| 🇲🇾 Malaysia | `capture` | booming → **capture growth** | 1.15 |
| 🇨🇳 China | `defend` | contracting → **defend equity** | 0.75 |

## 3. Category Opportunity Score (0–100)

```
gN    = clamp((g + 30) / 70, 0, 1)             # growth −30%…+40% → 0…1
sizeN = clamp(size / 45, 0, 1)                 # category share 0…45% → 0…1
nabN  = clamp(nab / 5, 0, 1)                    # Nabati equity 0…5 → 0…1

A = clamp((0.6*gN + 0.4*sizeN) * mf, 0, 1)      # Attractiveness  (market pull)
E = nabN                                         # Equity          (right-to-win)

score = round( (0.55*A + 0.45*E) * 100 )
```

- **A (Attractiveness)** — is the market/flavour worth playing in? Growth-led (60%) plus
  size (40%), scaled by the market's stance.
- **E (Equity)** — does Nabati have a right to win here already?
- Final score weights **Attractiveness 55% / Equity 45%**.

## 4. Action classifier (first match wins)

```
1. Stop     if  g ≤ −20  AND  nab ≤ 1                      # declining + no equity
2. Keep     if  stance = defend       AND nab ≥ 4
            or  stance = opportunity  AND nab ≥ 4 AND size ≥ 20
            or  stance = capture      AND nab ≥ 4 AND size ≥ 30 AND g ≥ 10
3. Develop  if  kind = 'inno'  AND g > −20  AND size ≥ 2    # innovation bet with real size
            or  ( g ≥ 10  or  [stance=capture AND size ≥ 20 AND g ≥ 0] )
                 AND size ≥ 1  AND nab ≤ 3                   # growing, room to gain
4. Test     otherwise                                       # small / unproven / stuck
```

Reading of the four actions:
- **Keep** — Nabati already owns a meaningful flavour → protect it.
- **Develop** — attractive growth with room to gain, or a sized innovation bet → invest.
- **Test** — small, emerging or stuck → pilot before committing.
- **Stop** — declining with no equity → do not chase (e.g. Goguma).

## 5. Computed result (current signals)

Badge = action · number = Category Opportunity Score.

| Flavour platform | 🇮🇩 Indonesia | 🇲🇾 Malaysia | 🇨🇳 China |
|---|---|---|---|
| Chocolate | **Keep** · 70 | **Develop** · 77 | **Keep** · 53 |
| Dark / Intense Chocolate | **Develop** · 54 | **Develop** · 40 | **Develop** · 27 |
| Cheese | **Keep** · 76 | **Test** · 62 | **Keep** · 60 |
| Strawberry Cheese | **Develop** · 55 | **Develop** · 40 | **Keep** · 40 |
| Hazelnut | **Test** · 27 | **Develop** · 42 | **Test** · 15 |
| Matcha | **Test** · 42 | **Test** · 38 | — |
| Goguma | **Stop** · 9 | **Stop** · 2 | — |

Notes that fall straight out of the logic:
- **Chocolate** keeps/develops everywhere → the safest scalable platform.
- **Cheese** is Keep in ID/CN (equity) but **Test** in MY — booming market, but cheese
  isn't where the growth is, so don't over-defend it.
- **Hazelnut** is **Develop** only in MY — the white-space signal (26% of a booming
  market, +21%, Nabati absent).
- **Goguma** stops in both markets it appears in → novelty fade.

## 6. Per-NPL verdict (same engine)

`verdictCard()` scores each NPL from its mapped Indonesia category:

```
signal = { g: category.chg, size: min(category.cont * 2, 45), nab: 4 }   # SIIP's own product → solid equity
score  = catOpp(signal, 'opportunity').score

verdict = RIDE   if score ≥ 60
          WATCH  if score ≥ 45
          AVOID  otherwise
# override: a declining category (chg < 0) or a white-space (no category) → AVOID
```

Current NPLs:

| NPL | Category | Score | Verdict |
|---|---|---|---|
| SIIP Nori | Seaweed (Nori), +20.2%, 7.1% | **67** | **RIDE** |
| SIIP Karaage | Kaldu Ayam, −1.1% | 51 | **AVOID** (declining override) |
| SIIP Kari | white space | 18 | **AVOID** |

## 7. How to tune it

- Change a cell's **signals** (`g`, `size`, `nab`, `kind`) in `OPPMATRIX` → its score and
  action recompute automatically.
- Change the **stance factor** `mf`, the **A/E weights** (0.55 / 0.45), or the **growth /
  size weights** (0.6 / 0.4) in `catOpp()` to re-balance growth vs. equity.
- Change the **thresholds** in `catAction()` (e.g. the `size ≥ 20` for Keep, the `g ≥ 10`
  for Develop) to make the matrix stricter or looser.
- Change the **verdict bands** (60 / 45) in `verdictCard()`.

All numbers are transparent and live in the one HTML file; nothing is pre-baked.

---

*Repository `sialdyy/Ngoreng`, branch `claude/practical-bohr-g4dwc9`. Generated by Claude Code.*
