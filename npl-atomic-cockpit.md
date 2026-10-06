# NPL Launch Decision Engine — Prototype Specification

Documentation of the **final** web prototype: `npl-atomic-cockpit.html`.

- **Product:** an interactive decision cockpit for SIIP (Nabati) New Product Launches (NPL).
- **Audience:** CEO / leadership — formal but readable.
- **Delivery:** one self-contained `.html` file, opened locally in a browser and shared
  via Teams. Not a hosted web app.
- **Everything is client-side:** no server, no build step. Data lives in the file and in
  the browser's `localStorage`.
- **Bilingual** English / Indonesian (toggle in the header) · **light/dark/system** theme.

---

## How to use it

1. Open `npl-atomic-cockpit.html` in any modern browser (Chrome/Edge recommended).
2. Use the top navigation to move across the **5 tabs**.
3. Header controls:
   - **Data** — upload a workbook (`.xlsx`) to replace the demo numbers (SheetJS).
   - **EN / ID** — switch language.
   - **System / Light / Dark** — switch theme.
4. Edits (numbers, fees, added NPLs, photos) are saved to the browser automatically and
   persist on reload on the same device/browser.

---

## The five tabs

### 1 · Concepts
Stage-1 NPL concepts that passed the taste gate.
- Each concept card shows: **prototype photo** (insertable), **brand**, **Nielsen
  flavour category**, category demand trend, **COGM/ctn**, **market selling price**, and
  **GP% at full capacity**.
- **Add / Edit / Delete** NPLs; the add/edit form captures name, brand, flavour
  category, RM cost, selling price and a photo (stored as a data URL in the browser).
- Demo SKUs: SIIP Nori (Rp102,000), SIIP Karaage (Rp108,000), SIIP Kari (Rp98,000).

### 2 · COGM
Cost-of-Goods-Manufactured engine.
- **Layout:** NPLs are **columns**, cost components are **rows** (Depreciation, OMC,
  Direct Labour, Electricity, Gas, RM, PM).
- Depreciation & OMC are flagged **fixed/month** — they "balloon" per carton when the
  operating volume is below full capacity.
- Shows DBP (base price), full capacity, **COGM/carton at full capacity** and **GP%**,
  then a second block for **operating volume**, COGM-at-volume and GP%-at-volume.
- All inputs are editable; the engine recomputes live.

**COGM capacity formula** (reproduces the three SIIP NPL COGMs exactly):
```
COGM(vol) = (RM + PM + DL + Listrik + Gas)/ctn  +  (DepreMonthly + OMCMonthly)/vol
```

### 3 · Small but Confounding
Full per-SKU P&L down to EBT (same matrix shape as COGM: NPLs by column, lines by row).
- Selectors: **baseline country**, **channel (GT/MT)**, **MT account**.
- Lines: Operating volume → Net Sales (NSAR) → COGM → **GP1** → SM1–4 → **GP2** →
  GA1–3 → **Listing fee** → **Trading term** → **VAT/PPN** → **EBT** → **EBT % of NSAR**.
- **Fees per MT account:** **Listing fee** and **VAT/PPN** are entered as **absolute Rp
  amounts** (not percentages); **Trading term stays a %**. VAT/PPN is pass-through (it
  does not reduce EBT).
- Teaching point: EBT = 0 is break-even, not success — MT listing + trading terms are
  what typically push a new NPL's EBT negative.

### 4 · Market Share  (Indonesia · Malaysia · China)
Combines the Indonesia category audit with a Malaysia/China adjacent-category benchmark.

> **Caveat shown in-app:** Indonesia data = **Wafer ROLL** (to Aug-26); Malaysia & China
> = **Wafer FLAT** (to Jun-26). Market size & share for MY/CN must **not** be summed or
> compared directly with Indonesia Roll — they are a benchmark for flavour, pack,
> distribution and consumer preference.

- **Executive picture** — three markets, three roles / three business problems:

  | Market | Category | Condition | Nabati position | Problem |
  |---|---|---|---|---|
  | 🇮🇩 Indonesia | Wafer Roll | Flat −0.9% | Challenger | Opportunity |
  | 🇲🇾 Malaysia | Wafer Flat | +14.4% MAT | #2, 28.7% | Competitive capture |
  | 🇨🇳 China | Wafer Flat | −23.1% MAT | #1, 46.8% | Category / demand |

- **Country switcher (🇮🇩 / 🇲🇾 / 🇨🇳):**
  - **Indonesia** → the Roll GT/MT split **plus the full category audit** (Top Flavour,
    Top Brand, Top SKU, Segment Performance, Value/ND/WD by Segment, SIIP-vs-MOMOGI
    Sales Comparison charts) sourced from *Market Update Domestic - Snack.pdf*.
  - **Malaysia / China** → role tiles, brand ranking, flavour structure (SKU proxy),
    top SKUs with ND/WD, and a channel distribution-vs-demand table (China's Hypermarket
    flagged as the "smoking gun", CVS as resilient).
- **Flavour architecture** — cross-market read per flavour (Chocolate = safest platform;
  Cheese = strong equity but not a universal growth engine; Strawberry Cheese = strong
  cross-market candidate; Hazelnut = Malaysia white-space; Goguma = hype ≠ repeat).
- **Regional Rolls Opportunity Matrix** — **Keep / Develop / Test / Stop** per flavour,
  per country.
- **Country strategy** grid and a **management conclusion** callout.

### 5 · Launch Ranking
Where each SKU should launch, scored by the concept-book method.
- Candidates across **SKU × country × channel × account** (single + Core+Halo combos).
- Columns: Opportunity, Probability, Risk band, Confidence, EBT @ scale, Decision
  (**GO / PILOT / HOLD / NO-GO**).
- **Map (globe.gl, with SVG fallback):** click a country → a **"Why" popup opens on the
  left** (market size, capturable market, expected EBT, probability, risk, confidence,
  drill-down) with a close button.
- **Row click → modal** with the full per-NPL scenario: the 6 Opportunity dimensions and
  8 Risk dimensions (each with a note), decision rationale and expected EBT at scale.
- **Risk is linked to COGM:** the RM & Cost Volatility dimension reads the lowest GP@full.

---

## Scoring engine (concept-book method)

- **Opportunity Score** — 6 weighted dimensions minus a risk penalty:
  market attractiveness (25%), product-market fit (20%), channel/account fit (15%),
  financial sustainability (20%), execution readiness (10%), evidence strength (10%).
- **Risk Engine** — 8 dimensions rated 1–5 (market, RM & cost, channel/account,
  execution, supply, regulatory, competitive, cannibalisation); bands Low 0–34 /
  Medium 35–64 / High 65–100.
- **Probability** = readiness × confidence factor. **Confidence** banded separately.
- **Hard guardrail:** Required Sales ≤ Capturable Market.
- **Calibration:** within the capturable market, only **Nori · Indonesia · GT** reaches
  positive EBT (~+1.5%) — the honest "EBT kills the NPL" story.

---

## Data & technical notes

- **Libraries:** globe.gl (jsDelivr) for the map, SheetJS/xlsx (cdnjs) for workbook
  upload. Both load from CDN and work in a real browser; in a locked-down sandbox the
  map falls back to an inline SVG.
- **i18n:** `t(key, vars)` for strings, `L({en,id})` for bilingual objects.
- **Theme:** CSS custom-property tokens with light/dark variants; explicit body
  background.
- **Persistence:** `localStorage` (numbers, fees, added NPLs, photos, language, theme).
- **Market-share sourcing:** Nielsen/NIQ snack audits — Indonesia Wafer Roll (to Aug-26),
  Malaysia & China Wafer Flat (to Jun-26). MY/CN flavour figures are **SKU-description
  proxies** (~92–96% of value classified), not the official Nielsen FLAVOR dimension.
  Directional context: Euromonitor, NIQ, and marketplace/social signals (Shopee MY,
  Reddit, SMZDM, JD, Nabati Food CN).

---

## Possible next step

Link the Tab-4 Opportunity Matrix to the Tab-5 ranking so a "Develop/Keep" flavour per
country lifts its NPL score and "Stop" lowers it; and tune the xlsx parser to the real
"PnL by country" workbook when it is provided.

---

*Repository `sialdyy/Ngoreng`, branch `claude/practical-bohr-g4dwc9`. Generated by Claude Code.*
